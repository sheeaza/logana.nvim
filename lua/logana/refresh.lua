-- a refresh: which levels rerun, and level 1 streamed into the result buffer
local api = vim.api
local fn = vim.fn
local log = require('logana.log')
local now_ms = require('logana.util').now_ms
local level1 = require('logana.level1')
local scan = require('logana.scan')
local highlight = require('logana.highlight')
local rule = require('logana.rule')
local result = require('logana.result')
local fold = require('logana.fold')
local spinner = require('logana.spinner')
local process = require('logana.proc')
local count = require('logana.count')
local config = require('logana.config')
local chunks = require('logana.chunks')

local M = {}

-- per rule buffer refresh state, used to skip levels that don't need updating:
-- { match_sig, hl_sig, hl_rules, hl_warned (the result's level 2 rules, also for
--   its source files), bound (when last refreshed or its tab entered, see
--   bind_tab; the source files take the rules of the last one), result_buf, result_dirty, attached_buf, file_rows,
--   job (level 1 run in progress), gen, writing,
--   texts (the result lines' texts, scan.open_texts), counts (count.lua),
--   undo ({ buf, levels }: the result's 'undolevels' while level 1 rewrites it) }
local RULE_STATE = {}
local refreshes = 0

local function rule_state_of_result(result_buf)
    for rule_buf, st in pairs(RULE_STATE) do
        if st.result_buf == result_buf and api.nvim_buf_is_valid(rule_buf) then
            return rule_buf, st
        end
    end
end

-- track user edits of the result buffer (changedtick can't be used, ':w' bumps
-- it too). our own writes set st.writing around them, so they don't count.
local function attach_result(st, result_buf)
    if st.attached_buf == result_buf then
        return
    end
    st.attached_buf = result_buf
    api.nvim_buf_attach(result_buf, false, {
        on_lines = function()
            if st.attached_buf ~= result_buf then
                return true -- detach, the rule now renders elsewhere
            end
            if not st.writing then
                st.result_dirty = true
            end
        end,
        on_reload = function()
            st.result_dirty = true
        end,
        on_detach = function()
            if st.attached_buf == result_buf then
                st.attached_buf = nil
            end
        end,
    })
end

-- level 1 rewrites the result with 'undolevels' -1: with undo on, clearing the old
-- result first copied all its lines into the undo tree, which made repeated
-- refreshes take seconds. it's set back when the run ends, so edits made in the
-- result after it can be undone; the next refresh drops their history
local function undo_restore(st)
    local u = st.undo
    st.undo = nil
    if u and api.nvim_buf_is_valid(u.buf) then
        api.nvim_set_option_value('undolevels', u.levels, { buf = u.buf })
    end
end

local function undo_off(st, result_buf)
    if st.undo and st.undo.buf ~= result_buf then
        undo_restore(st)
    end
    if not st.undo then
        st.undo = { buf = result_buf, levels = api.nvim_get_option_value('undolevels', { buf = result_buf }) }
    end
    api.nvim_set_option_value('undolevels', -1, { buf = result_buf })
end

-- new [highlight] rules and folds, once level 1 is done (or didn't need to run)
local function finish_refresh(rule_buf, st, ropts, rerendered, fold_edited, t_all, on_done)
    result.show_result(rule_buf, st.result_buf)

    local hl_changed = st.hl_sig ~= ropts.hl_sig
    if hl_changed then
        local hls = highlight.by_buf[st.result_buf]
        highlight.reset_highlights(hls, ropts)
        st.hl_sig, st.hl_rules, st.hl_warned = ropts.hl_sig, hls.hl_rules, hls.warned
        -- decoration provider marks are ephemeral; force visible windows to redraw them
        pcall(api.nvim__redraw, { buf = st.result_buf, valid = false })
    end
    if hl_changed or rerendered then
        highlight.redraw_sources()
    end
    -- after a level 1 run, the marks were placed when it started (or, for
    -- [highlight], when a refresh changed it while loading)
    if hl_changed and not rerendered then
        count.place(rule_buf, st, 'hl', ropts.hl_counts)
    end
    if rerendered or hl_changed then
        count.start(rule_buf, st, 'rg')
        count.start(rule_buf, st, 'hl')
    end

    if rerendered or fold_edited then
        local t3 = now_ms()
        fold.restore_folds(rule_buf, st)
        log.trace(string.format("restore_folds took: %d ms", now_ms() - t3))
    end
    log.trace(string.format("refresh took: %d ms", now_ms() - t_all))
    if on_done then
        on_done()
    end
end

-- rg output is parsed and appended to the result buffer in batches of about this
-- many bytes, each in its own main loop callback, so neovim stays responsive and
-- the first lines show while rg is still running
local BATCH_BYTES = 1024 * 1024
-- the scanned lines go to the buffer once per BATCH_BYTES or this many ms:
-- each ':read' costs a temp file write, and a pump batch is often only what rg wrote since the last
local FLUSH_MS = 100
-- how often the pump looks for more rg output in the memfd while rg runs
local POLL_MS = 3

-- level 1, streamed: the first batch replaces the result buffer, later ones append.
-- with no match the buffer keeps its old content. job.ropts may be swapped by a
-- refresh that only changed [highlight] while this runs; finish uses the latest.
local function run_level1(rule_buf, st, ropts, fold_edited, t_all, on_done)
    local result_buf = result.get_result_buf(rule_buf)
    st.gen = (st.gen or 0) + 1
    local gen = st.gen
    local job = {
        sig = ropts.match_sig, ropts = ropts, fold_edited = fold_edited, on_done = on_done,
        chunks = {}, head = 1, tail = 0, rest = {}, rest_size = 0, parser = level1.new_parser(),
        t0 = now_ms(), flushed = 0, parse_ms = 0, set_ms = 0, max_ms = 0,
    }
    st.job = job
    job.stop_spinner = spinner.start_spinner(rule_buf, job)
    -- an interrupted or failed run leaves a partial buffer, the next refresh reruns
    st.match_sig = nil
    -- the old counts and texts are of the old result. the new marks go on the
    -- rule lines now, so they move with edits made while loading
    count.place(rule_buf, st, 'rg', ropts.rg_counts)
    count.place(rule_buf, st, 'hl', ropts.hl_counts)
    if st.texts then
        scan.close_texts(st.texts)
    end
    st.texts = config.hit_count and scan.open_texts() or nil
    job.parser.texts = st.texts ~= nil

    -- job.runs: the rg runs, read in order, job.cur the one being read:
    -- { args, proc, src (its memfd, or nil: rg writes to a pipe), exit (its result), closed }
    job.runs, job.cur = {}, 1
    local function close_run(run)
        if run.src and not run.closed then
            run.closed = true
            scan.close_output(run.src)
        end
    end
    -- stops the job: the runs still going are killed, their memfds closed when they
    -- exit (the job is no longer current then); the others' memfds now
    function job.abort()
        if job.lister and not job.listed then
            pcall(job.lister.kill, job.lister, 15)
        end
        for _, run in ipairs(job.runs) do
            if run.exit then
                close_run(run)
            elseif run.proc then
                pcall(run.proc.kill, run.proc, 15)
            end
        end
    end
    -- the runs' results as one rg's: an error in any, else a match in any
    local function result_of_runs()
        local res, errs = { code = 1 }, {}
        for _, run in ipairs(job.runs) do
            local r = run.exit
            if r.code == 2 then
                res.code = 2
            elseif r.code == 0 and res.code ~= 2 then
                res.code = 0
            end
            if r.stderr and r.stderr ~= '' then
                errs[#errs + 1] = r.stderr
            end
        end
        res.stderr = #errs > 0 and table.concat(errs, '\n') or nil
        return res
    end

    local function done(res)
        job.finished = true
        st.job = nil
        scan.release()
        for _, run in ipairs(job.runs) do
            close_run(run)
        end
        job.stop_spinner()
        if res.code == 2 then
            vim.notify(("[logana] ripgrep error for: %s"):format(res.stderr or "exit code 2"), vim.log.levels.WARN)
        end
        if not job.started then
            undo_restore(st)
            count.stop_all(rule_buf, st)
            -- 0: files given by path are searched as with --binary, a binary one
            -- matching only gives a notice line, no result line
            if res.code ~= 2 then
                vim.notify(("[logana] cmd[%s], no match found"):format(table.concat(ropts.args_common, ' ')),
                    vim.log.levels.INFO)
            end
            return
        end

        local p = job.parser
        if st.texts then
            scan.finish_texts(st.texts)
        end
        if p.cur then
            st.writing = true
            api.nvim_buf_set_lines(result_buf, -1, -1, false, { '' })
            st.writing = false
        end
        undo_restore(st)
        log.trace(string.format("first lines took: %d ms", job.first_ms))
        log.trace(string.format("parse rg output took: %d ms", job.parse_ms))
        log.trace(string.format("set lines took: %d ms", job.set_ms))
        log.trace(string.format("max batch took: %d ms", job.max_ms))
        log.trace(string.format("level 1 took: %d ms", now_ms() - job.t0))

        st.file_rows = p.file_rows
        st.match_sig = job.sig
        finish_refresh(rule_buf, st, job.ropts, true, job.fold_edited, t_all, job.on_done)
    end

    -- puts what scan_batch collected in the buffer
    local function write()
        st.writing = true
        if not job.started then
            job.started = true
            job.first_ms = now_ms() - job.t0
            undo_off(st, result_buf)
            -- disable swapfile here too, since result buffers reloaded from disk via
            -- fn.bufadd/fn.bufload bypass create_normal_buffer's swapfile=false
            pcall(api.nvim_set_option_value, "swapfile", false, { buf = result_buf })
            attach_result(st, result_buf)
            scan.read_scanned(result_buf, job.parser, true)
            st.result_buf = result_buf
            st.result_dirty = false
            highlight.ensure_decoration_provider()
            -- level 1 filled in as batches come, level 2 as rows are drawn, also while
            -- loading. if only [highlight] changes meanwhile, finish_refresh resets it
            local hls = { match = job.parser.match, pending = 0 }
            highlight.reset_highlights(hls, job.ropts)
            highlight.by_buf[result_buf] = hls
            st.hl_sig, st.hl_rules, st.hl_warned = job.ropts.hl_sig, hls.hl_rules, hls.warned
            -- the old folds don't match the new lines, they're rebuilt when done
            for _, win in ipairs(fn.win_findbuf(result_buf)) do
                api.nvim_win_call(win, function() vim.cmd('silent! normal! zE') end)
            end
            result.show_result(rule_buf, result_buf)
        else
            scan.read_scanned(result_buf, job.parser, false)
        end
        scan.write_texts(st.texts, job.parser)
        st.writing = false
    end

    local pump
    local function schedule_pump()
        if not job.pumping then
            job.pumping = true
            vim.schedule(pump)
        end
    end

    pump = function()
        job.pumping = false
        if st.gen ~= gen or job.finished then
            return
        end
        if not api.nvim_buf_is_valid(result_buf) then
            st.job = nil
            job.stop_spinner()
            job.abort()
            return
        end

        local t = now_ms()
        local p = job.parser
        -- more: there's output left to scan now. drained: rg is done and all of it scanned
        local more, drained
        local run = job.runs[job.cur]
        if run.src then
            more = scan.scan_output(run.src, p, BATCH_BYTES) == BATCH_BYTES
            if run.exit and not more then
                -- this run's files are all in, the next run's come next
                if job.cur < #job.runs then
                    close_run(run)
                    job.cur = job.cur + 1
                    -- one read buffer for all: only one is read at a time, and rg
                    -- ends its output with a whole line
                    local nxt = job.runs[job.cur].src
                    nxt.buf, nxt.cap = run.src.buf, run.src.cap
                    more = true
                else
                    drained = true
                end
            end
        else
            -- job.rest: the pieces of a partial last line, no '\n' in them. at least
            -- one chunk is taken, also when a line longer than a batch is pending
            local parts, size, nl = job.rest, job.rest_size, false
            local took = false
            while job.head <= job.tail and (size < BATCH_BYTES or not took) do
                local c = job.chunks[job.head]
                job.chunks[job.head] = nil
                job.head = job.head + 1
                parts[#parts + 1] = c
                size, took = size + #c, true
                nl = nl or c:find('\n', 1, true) ~= nil
            end
            if nl then
                local data = table.concat(parts)
                -- rg ends every line with '\n'; keep a partial last line for the next batch
                local cut = data:match('^.*()\n')
                local rest = data:sub(cut + 1)
                job.rest, job.rest_size = { rest }, #rest
                scan.scan_batch(p, data:sub(1, cut))
            else
                -- still in the same line: joined once its '\n' comes
                job.rest, job.rest_size = parts, size
            end
            more = job.head <= job.tail
            drained = run.exit and not more
        end
        local t1 = now_ms()
        if p.o > 0 and (p.o >= BATCH_BYTES or not job.started or t1 - job.flushed >= FLUSH_MS or drained) then
            write()
            job.flushed = t1
        end
        local t2 = now_ms()
        job.parse_ms = job.parse_ms + t1 - t
        job.set_ms = job.set_ms + t2 - t1
        job.max_ms = math.max(job.max_ms, t2 - t)

        if more then
            schedule_pump()
        elseif drained then
            done(result_of_runs())
        elseif run.src or p.o > 0 then
            -- memfd: nothing tells when rg wrote more, look again shortly. pipe: rg
            -- paused, show what's collected without waiting for more
            if not job.wait_timer then
                job.wait_timer = true
                vim.defer_fn(function()
                    job.wait_timer = false
                    schedule_pump()
                end, run.src and POLL_MS or FLUSH_MS)
            end
        end
    end

    local function failed()
        st.job = nil
        job.stop_spinner()
        job.abort()
        undo_restore(st)
        vim.notify("[logana] failed to execute ripgrep", vim.log.levels.WARN)
    end

    -- starts the next run of job.runs not started yet, if any: at most chunks.count()
    -- run at once, the next one starts when one exits. false if it couldn't.
    -- not text = true: its '\r\n' gsub over the whole output cost about as much as rg.
    -- a '\r' line ending is dropped by scan_batch.
    -- both callbacks run in a fast event context, they only queue work for pump
    local start_next
    start_next = function()
        local run = job.runs[job.next_run]
        if not run then
            return true
        end
        job.next_run = job.next_run + 1
        if job.chunked then
            run.src = scan.open_output()
            if not run.src then
                run.exit = {}
                return false
            end
        end
        local src = run.src
        local ok, proc = pcall(process.system, run.args, {
            stdout_fd = src and src.fd,
            stdout = not src and function(_, data)
                if data and st.gen == gen then
                    job.tail = job.tail + 1
                    job.chunks[job.tail] = data
                    schedule_pump()
                end
            end or nil,
        }, function(res)
            vim.schedule(function()
                if st.gen == gen and st.job == job then
                    run.exit = res
                    if not start_next() then
                        failed()
                        return
                    end
                    schedule_pump()
                else
                    close_run(run) -- stopped or replaced, nothing reads it
                end
            end)
        end)
        if not ok or not proc then
            run.exit = {} -- abort closes its memfd
            return false
        end
        run.proc = proc
        return true
    end

    -- the runs: an rg -j1 per chunk of files (chunks.lua), with base (the args
    -- without paths), else one rg searching them all, with output in the order its
    -- threads finish the files. by_size: split them by bytes, else by number
    local function start(files, base, by_size)
        local list = files and #files > 1 and chunks.split(base, files, by_size)
        if list and #list > 1 then
            job.chunked = true
            for k, args in ipairs(list) do
                job.runs[k] = { args = args }
            end
        else
            local src = process.enabled and scan.open_output() or nil
            job.runs[1] = { args = ropts.args_common, src = src }
        end
        job.next_run = 1
        for _ = 1, job.chunked and chunks.count() or 1 do
            if not start_next() then
                failed()
                return
            end
        end
        if job.runs[1].src then
            schedule_pump() -- it polls the memfds from now on
        end
    end

    local base, given = rule.without(ropts.search_args, 'path')
    -- chunks need posix_spawn and memfds, rg's output read from each in turn
    if not process.enabled or not scan.has_memfd() or chunks.user_ordered(base) then
        start()
    elseif ropts.opened then
        -- paths in [rg] are searched along with the opened files, by one rg as before
        start(not given and ropts.opened or nil, base, true)
    else
        -- a directory search: the files it searches, listed first
        local ok, lister = pcall(process.system, rule.files_args(ropts.search_args), {}, function(res)
            vim.schedule(function()
                job.listed = true
                if st.gen == gen and st.job == job then
                    start(res.code == 0 and chunks.parse_files(res.stdout or '') or nil, base)
                end
            end)
        end)
        if ok and lister then
            job.lister = lister
        else
            start()
        end
    end
end

-- level 1 ([rg] -> result lines) only reruns when its inputs changed, or the result
-- buffer is gone / was edited since we rendered it. level 2 ([highlight]) reruns
-- whenever level 1 did, or when the [highlight] rules changed.
-- with opened_only = false, changes to the files under cwd can't be detected, so
-- a refresh where nothing else changed reruns level 1 too.
-- level 1 runs asynchronously; on_done is called once everything is applied.
local function refresh_from_rule(rule_buf, on_done)
    local t_all = now_ms()
    local ropts, err = rule.get_runtime_opts(rule_buf)
    if err then
        return nil, "get runtime opts failed"
    end

    local st = RULE_STATE[rule_buf] or {}
    RULE_STATE[rule_buf] = st
    refreshes = refreshes + 1
    st.bound = refreshes

    -- level 1 is still loading the same search: let it finish, with the new
    -- [highlight] rules and [fold] applied when it does
    if st.job and st.job.sig == ropts.match_sig then
        st.job.ropts = ropts
        st.job.on_done = on_done
        count.place(rule_buf, st, 'hl', ropts.hl_counts)
        return
    end
    if st.job then
        st.job.stop_spinner()
        st.job.abort()
        st.job = nil
    end

    -- record the result window's folds before re-rendering, unless [fold] was
    -- edited by hand since, then that wins and is applied below
    local fold_edited = table.concat(fold.read_fold_section(rule_buf), '\n') ~= st.fold_sig
    local fold_win = st.result_buf and api.nvim_buf_is_valid(st.result_buf) and fn.bufwinid(st.result_buf) or -1
    if not fold_edited and fold_win ~= -1 then
        local t = now_ms()
        fold.save_folds(rule_buf, st, fold_win)
        log.trace(string.format("save_folds took: %d ms", now_ms() - t))
    end

    local result_intact = st.result_buf and api.nvim_buf_is_valid(st.result_buf)
        and not st.result_dirty and highlight.by_buf[st.result_buf] ~= nil

    local unchanged = st.hl_sig == ropts.hl_sig and not fold_edited
    if not result_intact or st.match_sig ~= ropts.match_sig
        or (unchanged and not ropts.opened_only) then
        run_level1(rule_buf, st, ropts, fold_edited, t_all, on_done)
        return
    end

    finish_refresh(rule_buf, st, ropts, false, fold_edited, t_all, on_done)
end

-- visual <Enter> in the result: level 2 starts over with the rule buffer's
-- [highlight], like a refresh where only it changed. nothing else reruns, even
-- with [rg] or [fold] edited (the next refresh does) or the result edited
local function refresh_highlight(rule_buf)
    local st = RULE_STATE[rule_buf]
    local ropts = rule.get_runtime_opts(rule_buf)
    if not st or not ropts then
        return
    end
    if st.job then
        -- level 1 still loading: it takes [highlight] from job.ropts, keep its [rg] and [fold]
        st.job.ropts = vim.tbl_extend('force', st.job.ropts,
            { hl_rules = ropts.hl_rules, hl_sig = ropts.hl_sig, hl_counts = ropts.hl_counts })
        count.place(rule_buf, st, 'hl', ropts.hl_counts)
        return
    end
    local hls = st.result_buf and highlight.by_buf[st.result_buf]
    if not hls or st.hl_sig == ropts.hl_sig then
        return
    end
    highlight.reset_highlights(hls, ropts)
    st.hl_sig, st.hl_rules, st.hl_warned = ropts.hl_sig, hls.hl_rules, hls.warned
    pcall(api.nvim__redraw, { buf = st.result_buf, valid = false })
    highlight.redraw_sources()
    count.place(rule_buf, st, 'hl', ropts.hl_counts)
    count.start(rule_buf, st, 'hl')
end

-- buf was wiped: drop what's kept for it as a rule or a result buffer, and stop
-- its level 1 run, which would apply [fold] from the wiped rule buffer at the end
local function forget(buf)
    local st = RULE_STATE[buf]
    if st and st.job then
        st.gen = st.gen + 1 -- the run's callbacks see they're stale
        st.job.stop_spinner()
        st.job.abort()
    end
    if st then
        undo_restore(st)
        count.stop_all(buf, st)
        if st.texts then
            scan.close_texts(st.texts)
        end
    end
    RULE_STATE[buf] = nil
    highlight.by_buf[buf] = nil
    highlight.source_by_buf[buf] = nil
    if st then
        -- its source files lose their colors, or take another rule buffer's
        vim.schedule(highlight.redraw_sources)
    end
end

-- a tab entered: the first window (in window order) of it showing a rule buffer,
-- or a result buffer (standing for its rule buffer), binds the source files to
-- that rule buffer, as if it was the last refreshed, and they're redrawn with its
-- colors. nothing for a tab with neither, or a rule buffer never refreshed
local function bind_tab()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        local buf = api.nvim_win_get_buf(win)
        local st = RULE_STATE[buf]
        if not st then
            local _
            _, st = rule_state_of_result(buf)
        end
        if st then
            if st.bound ~= refreshes then
                refreshes = refreshes + 1
                st.bound = refreshes
                highlight.redraw_sources()
            end
            return
        end
    end
end

M.state = RULE_STATE
M.bind_tab = bind_tab
M.forget = forget
M.refresh_from_rule = refresh_from_rule
M.refresh_highlight = refresh_highlight
M.rule_state_of_result = rule_state_of_result
return M
