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

local M = {}

-- per rule buffer refresh state, used to skip levels that don't need updating:
-- { match_sig, hl_sig, result_buf, result_dirty, attached_buf, file_rows,
--   job (level 1 run in progress), gen, writing,
--   texts (the result lines' texts, scan.open_texts), counts (count.lua) }
local RULE_STATE = {}

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

-- new [highlight] rules and folds, once level 1 is done (or didn't need to run)
local function finish_refresh(rule_buf, st, ropts, rerendered, fold_edited, t_all, on_done)
    result.show_result(rule_buf, st.result_buf)

    local hl_changed = st.hl_sig ~= ropts.hl_sig
    if hl_changed then
        highlight.reset_highlights(highlight.by_buf[st.result_buf], ropts)
        st.hl_sig = ropts.hl_sig
        -- decoration provider marks are ephemeral; force visible windows to redraw them
        pcall(api.nvim__redraw, { buf = st.result_buf, valid = false })
    end
    if hl_changed or rerendered then
        highlight.redraw_sources()
    end
    if rerendered then
        count.run(rule_buf, st, 'rg', ropts.rg_counts)
    end
    if rerendered or hl_changed then
        count.run(rule_buf, st, 'hl', ropts.hl_counts)
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
        chunks = {}, head = 1, tail = 0, rest = '', parser = level1.new_parser(),
        t0 = now_ms(), flushed = 0, parse_ms = 0, set_ms = 0, max_ms = 0,
    }
    st.job = job
    job.stop_spinner = spinner.start_spinner(rule_buf, job)
    -- an interrupted or failed run leaves a partial buffer, the next refresh reruns
    st.match_sig = nil
    -- the old counts and texts are of the old result
    count.stop_all(rule_buf, st)
    if st.texts then
        scan.close_texts(st.texts)
    end
    st.texts = config.hit_count and scan.open_texts() or nil
    job.parser.texts = st.texts ~= nil

    local function done(res)
        job.finished = true
        st.job = nil
        scan.release()
        if job.src then
            scan.close_output(job.src)
        end
        job.stop_spinner()
        if res.code == 2 then
            vim.notify(("[logana] ripgrep error for: %s"):format(res.stderr or "exit code 2"), vim.log.levels.WARN)
        end
        if not job.started then
            if res.code == 1 then
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
            -- result buffers are fully regenerated on every refresh; there's nothing
            -- worth undoing to, and snapshotting hundreds of thousands of prior lines
            -- into the undo tree before each replace made repeated refreshes take seconds.
            pcall(api.nvim_set_option_value, "undolevels", -1, { buf = result_buf })
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
            st.hl_sig = job.ropts.hl_sig
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
            pcall(job.proc.kill, job.proc, 15)
            if job.exit and job.src then
                scan.close_output(job.src) -- else the exit callback does
            end
            return
        end

        local t = now_ms()
        local p = job.parser
        -- more: there's output left to scan now. drained: rg is done and all of it scanned
        local more, drained
        if job.src then
            local exited = job.exit
            more = scan.scan_output(job.src, p, BATCH_BYTES) == BATCH_BYTES
            drained = exited and not more
        else
            local parts, size = { job.rest }, #job.rest
            while job.head <= job.tail and size < BATCH_BYTES do
                local c = job.chunks[job.head]
                job.chunks[job.head] = nil
                job.head = job.head + 1
                parts[#parts + 1] = c
                size = size + #c
            end
            local data = table.concat(parts)
            -- rg ends every line with '\n'; keep a partial last line for the next batch
            local cut = data:match('^.*()\n')
            if cut then
                job.rest = data:sub(cut + 1)
                data = data:sub(1, cut)
            else
                job.rest, data = data, ''
            end
            scan.scan_batch(p, data)
            more = job.head <= job.tail
            drained = job.exit and not more
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
            done(job.exit)
        elseif job.src or p.o > 0 then
            -- memfd: nothing tells when rg wrote more, look again shortly. pipe: rg
            -- paused, show what's collected without waiting for more
            if not job.wait_timer then
                job.wait_timer = true
                vim.defer_fn(function()
                    job.wait_timer = false
                    schedule_pump()
                end, job.src and POLL_MS or FLUSH_MS)
            end
        end
    end

    -- not text = true: its '\r\n' gsub over the whole output cost about as much as rg.
    -- a '\r' line ending stays in the line text, as it did with --json.
    -- both callbacks run in a fast event context, they only queue work for pump
    job.src = process.enabled and scan.open_output() or nil
    local ok, proc = pcall(process.system, ropts.args_common, {
        stdout_fd = job.src and job.src.fd,
        stdout = not job.src and function(_, data)
            if data and st.gen == gen then
                job.tail = job.tail + 1
                job.chunks[job.tail] = data
                schedule_pump()
            end
        end or nil,
    }, function(res)
        vim.schedule(function()
            if st.gen == gen and st.job == job then
                job.exit = res
                schedule_pump()
            elseif job.src then
                scan.close_output(job.src) -- stopped or replaced, nothing reads it
            end
        end)
    end)
    if not ok or not proc then
        if job.src then
            scan.close_output(job.src)
        end
        st.job = nil
        job.stop_spinner()
        vim.notify("[logana] failed to execute ripgrep", vim.log.levels.WARN)
        return
    end
    job.proc = proc
    if job.src then
        schedule_pump() -- it polls the memfd from now on
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

    -- level 1 is still loading the same search: let it finish, with the new
    -- [highlight] rules and [fold] applied when it does
    if st.job and st.job.sig == ropts.match_sig then
        st.job.ropts = ropts
        st.job.on_done = on_done
        return
    end
    if st.job then
        st.job.stop_spinner()
        pcall(st.job.proc.kill, st.job.proc, 15)
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

-- buf was wiped: drop what's kept for it as a rule or a result buffer, and stop
-- its level 1 run, which would apply [fold] from the wiped rule buffer at the end
local function forget(buf)
    local st = RULE_STATE[buf]
    if st and st.job then
        st.gen = st.gen + 1 -- the run's callbacks see they're stale
        st.job.stop_spinner()
        pcall(st.job.proc.kill, st.job.proc, 15)
    end
    if st then
        count.stop_all(buf, st)
        if st.texts then
            scan.close_texts(st.texts)
        end
    end
    RULE_STATE[buf] = nil
    highlight.by_buf[buf] = nil
    highlight.source_by_buf[buf] = nil
end

M.state = RULE_STATE
M.forget = forget
M.refresh_from_rule = refresh_from_rule
M.rule_state_of_result = rule_state_of_result
return M
