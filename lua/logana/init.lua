local api = vim.api
local fn = vim.fn
local log = require('logana.log')

local M = {}

-- for trace timings. not vim.uv.now(), that's the loop's cached time, which
-- doesn't advance during synchronous lua work
local function now_ms()
    return vim.uv.hrtime() / 1e6
end

local NS_MATCH = api.nvim_create_namespace("logana.match")

local SPLIT_DIR = { top = 'below', bottom = 'above', left = 'right', right = 'left' }

-- highlight ranges per result buffer, keyed by 0-based row:
-- {
--     match = { [row] = { {start_col, end_col}, ... } },           -- level 1, [rg]
--     hl    = { [row] = { {start_col, end_col, hl_idx}, ... } },   -- level 2, [highlight]
-- }
-- highlighted lazily via decoration provider (ephemeral extmarks) instead of eagerly,
-- since eagerly creating one extmark per match makes the first redraw of a large
-- result buffer (hundreds of thousands of matches) take seconds.
local RESULT_HIGHLIGHTS = {}
local decoration_provider_ready = false

-- level 2 draws above level 1, so a [highlight] color wins where both overlap
local PRIORITY_MATCH = 4096
local PRIORITY_HL = 4097

-- per rule buffer refresh state, used to skip levels that don't need updating:
-- { match_sig, hl_sig, result_buf, result_dirty, attached_buf, hl_input, hl_map, file_rows }
local RULE_STATE = {}

-- exposed for tests only
M._result_highlights = RESULT_HIGHLIGHTS

local function draw_marks(bufnr, row, marks, priority)
    if not marks then
        return
    end
    local names = M.config.hi_group_names
    for _, hi in ipairs(marks) do
        local name = hi[3] and names[(hi[3] - 1) % #names + 1] or M.config.hi_match_group
        api.nvim_buf_set_extmark(bufnr, NS_MATCH, row, hi[1], {
            end_row = row,
            end_col = hi[2],
            hl_group = name,
            priority = priority,
            ephemeral = true,
        })
    end
end

local function ensure_decoration_provider()
    if decoration_provider_ready then
        return
    end
    decoration_provider_ready = true

    api.nvim_set_decoration_provider(NS_MATCH, {
        on_win = function(_, _, bufnr)
            return RESULT_HIGHLIGHTS[bufnr] ~= nil
        end,
        on_line = function(_, _, bufnr, row)
            local hls = RESULT_HIGHLIGHTS[bufnr]
            draw_marks(bufnr, row, hls.match[row], PRIORITY_MATCH)
            draw_marks(bufnr, row, hls.hl[row], PRIORITY_HL)
        end,
    })
end

local function set_buf_opts(buf, opts)
    for k, v in pairs(opts) do
        api.nvim_set_option_value(k, v, { buf = buf })
    end
end

local function create_normal_buffer(name, filetype)
    local buf = api.nvim_create_buf(true, false) -- [listed=true, scratch=false]
    set_buf_opts(buf, {
        swapfile = false,
        modifiable = true,
        readonly = false,
        filetype = filetype or "",
    })
    -- Set a readable name so users can :w to persist (writes relative to cwd if no path)
    pcall(api.nvim_buf_set_name, buf, name)
    return buf
end

local function result_open_win(result_buf, rule_win)
    if M.config.result_win.behavior == 'override' then
        api.nvim_win_set_buf(rule_win, result_buf)
        return
    end

    local split = SPLIT_DIR[M.config.layout.rule_pos] or 'left'
    local t0 = now_ms()
    local result_win = api.nvim_open_win(result_buf, false, { split = split, win = rule_win })
    log.trace(string.format("result_open_win took: %d ms", now_ms() - t0))

    -- rule and result split the space rule_win had; the +1 is the statusline
    -- or vertical separator between them
    local pct = tonumber(M.config.layout.rule_window)
    if pct and pct > 0 and pct < 100 then
        if split == 'below' or split == 'above' then
            local total = api.nvim_win_get_height(rule_win) + api.nvim_win_get_height(result_win) + 1
            api.nvim_win_set_height(rule_win, math.max(1, math.floor(total * pct / 100)))
        else
            local total = api.nvim_win_get_width(rule_win) + api.nvim_win_get_width(result_win) + 1
            api.nvim_win_set_width(rule_win, math.max(1, math.floor(total * pct / 100)))
        end
    end
end

local function split_with_quotes(str)
    local result = {}
    local current = ""
    local in_quotes = false
    local quote_char = nil

    for i = 1, #str do
        local char = str:sub(i, i)

        if (char == '"' or char == "'") and (i == 1 or str:sub(i-1, i-1) ~= "\\") then
            if not in_quotes then
                in_quotes = true
                quote_char = char
            elseif char == quote_char then
                in_quotes = false
                quote_char = nil
            else
                current = current .. char
            end
        elseif char == " " and not in_quotes then
            if current ~= "" then
                table.insert(result, current)
                current = ""
            end
        else
            current = current .. char
        end
    end

    if current ~= "" then
        table.insert(result, current)
    end

    return result
end

-- whether rg args give a pattern: a positional arg, -e/--regexp or -f/--file
-- (also inside a short flag cluster like '-ie')
local function has_pattern(args)
    for _, arg in ipairs(args) do
        if not arg:match("^%-") or arg:match("^%-%-regexp") or arg:match("^%-%-file")
            or (arg:match("^%-[^-]") and arg:match("^%-%a*[ef]")) then
            return true
        end
    end
    return false
end

local function parse_rule_buf(rule_buf)
    local rule = {}
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)

    local section = ''
    for _, line in ipairs(lines) do
        local s = line:gsub("%s+$", "")

        if s:match("^%s*$") or s:match("^%s*#") then
            -- skip comments and empty lines
        else
            local cur_section = s:match("^%s*%[(.+)%]%s*$")
            if cur_section then
                section = cur_section
                rule[section] = { lines = {} }
            elseif section ~= '' then
                local m = s:match("^%s*(.*)%s*$")
                table.insert(rule[section].lines, m or s)
            end
        end
    end

    if next(rule) == nil then
        vim.notify("[logana] Missing [rg] section. Add a [rg] section with one ripgrep regex per line.", vim.log.levels.ERROR)
        return nil, "missing_section"
    end
    if not rule.rg or next(rule.rg.lines) == nil then
        vim.notify("[logana] No patterns under [rg]. Add regex rules, one per line.", vim.log.levels.WARN)
        return nil, "empty_patterns"
    end

    rule.rg.cmd = {}
    for _, line in ipairs(rule.rg.lines) do
        for _, arg in ipairs(split_with_quotes(line)) do
            table.insert(rule.rg.cmd, arg)
        end
    end

    -- each [highlight] line with a pattern is its own rg args list, and gets its own
    -- color. lines with only flags (e.g. '--smart-case') are shared by every rule,
    -- placed first so a rule's own flags override them.
    rule.hl_rules = {}
    if rule.highlight then
        local shared = {}
        local patterns = {}
        for _, line in ipairs(rule.highlight.lines) do
            local args = split_with_quotes(line)
            if has_pattern(args) then
                table.insert(patterns, args)
            else
                vim.list_extend(shared, args)
            end
        end
        for _, args in ipairs(patterns) do
            table.insert(rule.hl_rules, vim.list_extend(vim.list_slice(shared), args))
        end
    end

    if rule.file and rule.file.lines then
        for _, line in ipairs(rule.file.lines) do
            local kb, vb = line:match("^%s*(%S-)%s*=%s*(%S-)%s*$")
            if kb == "opened_only" then
                rule.file.opened_only = (vb == "true")
            end
        end
    end

    return rule
end

-- level 1 output: '<path>\0<lnum>: <line>', each match in the line wrapped in
-- MARK_S..MARK_E via --replace, which gives the line and every match range in one
-- pass, and everything after the '\0' is already the result buffer line.
-- not --json, decoding it in lua took more than half of a large refresh.
-- context lines (-A/-B/-C) print '<lnum>-' and are skipped, like --json's
-- "context" events were. a marker byte already in a log line would shift the
-- columns after it on that line; they're ascii control chars logs don't use.
local MARK_S, MARK_E = '\30', '\31'
local LEVEL1_ARGS = { '--color', 'never', '--no-heading', '--with-filename', '--line-number',
    '--no-column', '--null', '--field-match-separator', ': ',
    '--replace', MARK_S .. '${0}' .. MARK_E }

-- strips the markers from a level 1 line; returns the text and its match ranges,
-- or nil ranges when there are none (e.g. with -v)
local function unmark(raw)
    local a = raw:find(MARK_S, 1, true)
    if not a then
        return raw, nil
    end
    local b = raw:find(MARK_E, a + 1, true)
    -- most lines have one match, plain sub/concat is ~1/3 faster for those
    if b and not raw:find(MARK_S, b + 1, true) then
        return raw:sub(1, a - 1) .. raw:sub(a + 1, b - 1) .. raw:sub(b + 1), { { a - 1, b - 2 } }
    end
    local parts, matches, len, s = {}, {}, 0, 1
    while a do
        b = raw:find(MARK_E, a + 1, true)
        if not b then
            break
        end
        local start = len + a - s
        parts[#parts + 1] = raw:sub(s, a - 1)
        parts[#parts + 1] = raw:sub(a + 1, b - 1)
        len = start + b - a - 1
        matches[#matches + 1] = { start, len }
        s = b + 1
        a = raw:find(MARK_S, s, true)
    end
    parts[#parts + 1] = raw:sub(s)
    return table.concat(parts), matches
end

--[[
runs level 1 and builds the result buffer content in one pass over rg's output,
without per match line intermediate tables:
{
    lines = { 'file: <path>', '<lnum>: <text>', ..., '' , ... },  -- buffer lines
    match = { [row] = { {start_col, end_col}, ... } },            -- 0-based rows
    file_rows = { { <1-based row of 'file: ' header>, <path> }, ... },
    hl_input = '<text>\n...',  -- the matched line texts, stdin for level 2
    hl_map = { row = { [i] = row }, delta = { [i] = col - hl_input offset } },
}
--]]
local function collect_matches(ropts)
    -- not text = true: its '\r\n' gsub over the whole output cost about as much as rg.
    -- a '\r' line ending stays in the line text, as it did with --json
    local ok_sys, proc = pcall(vim.system, ropts.args_common)
    if not ok_sys or not proc then
        vim.notify("[logana] failed to execute ripgrep", vim.log.levels.WARN)
        return nil, "failed"
    end

    local t0 = now_ms()
    local res = proc:wait()
    log.trace(string.format("rg took: %d ms", now_ms() - t0))

    if res.code == 1 then
        vim.notify(("[logana] cmd[%s], no match found"):format(table.concat(ropts.args_common, ' ')), vim.log.levels.INFO)
        return nil, {}
    end
    if res.code == 2 then
        vim.notify(("[logana] ripgrep error for: %s"):format(res.stderr or ("exit code " .. tostring(res.code))), vim.log.levels.WARN)
        return nil, {}
    end

    local t1 = now_ms()
    local lines, match, file_rows, hl_texts, hl_row, hl_delta = {}, {}, {}, {}, {}, {}
    local n, k, bytes, cur = 0, 0, 0, nil

    for path, raw, lnum, text in res.stdout:gmatch("([^%z\n]*)%z((%d+): ([^\n]*))") do
        if path ~= cur then
            if cur then
                n = n + 1
                lines[n] = ''
            end
            n = n + 1
            lines[n] = 'file: ' .. path
            file_rows[#file_rows + 1] = { n, path }
            cur = path
        end
        -- markers are only in the text part, so ranges are already buffer columns
        local line, ranges = unmark(raw)
        n = n + 1
        lines[n] = line
        local off = #lnum + 2
        if ranges then
            match[n - 1] = ranges
            text = line:sub(off + 1)
        end
        k = k + 1
        hl_texts[k] = text
        hl_row[k] = n - 1
        hl_delta[k] = off - bytes
        bytes = bytes + #text + 1
    end
    if cur then
        n = n + 1
        lines[n] = ''
    end

    local hl_input = k > 0 and table.concat(hl_texts, '\n') .. '\n' or ''
    log.trace(string.format("parse rg output took: %d ms", now_ms() - t1))

    return {
        lines = lines,
        match = match,
        file_rows = file_rows,
        hl_input = hl_input,
        hl_map = { row = hl_row, delta = hl_delta },
    }
end

-- level 2: run each [highlight] rule through rg over the result line texts (stdin),
-- so highlight patterns use the same regex syntax/options as [rg].
-- hl_map maps the i-th stdin line back to the result buffer, see collect_matches.
local function collect_highlights(hl_rules, hl_input, hl_map)
    local by_row = {}
    if #hl_rules == 0 or #hl_map.row == 0 or #M.config.hi_group_names == 0 then
        return by_row
    end

    -- rules are independent, start them all before waiting on any
    local procs = {}
    for i, rule_args in ipairs(hl_rules) do
        -- plain '<lnum>:<abs byte offset>:<match>' output instead of --json, since
        -- decoding json in lua dominates the cost on large result buffers
        local args = { M.config.rg.cmd, '--no-config', '--color', 'never', '--no-filename',
            '--line-number', '--byte-offset', '--only-matching' }
        vim.list_extend(args, rule_args)
        table.insert(args, '-')
        local ok, proc = pcall(vim.system, args, { text = true, stdin = hl_input })
        procs[i] = ok and proc or false
    end

    local rows, delta = hl_map.row, hl_map.delta
    for i, proc in ipairs(procs) do
        local res = proc and proc:wait()
        if not res or res.code == 2 then
            vim.notify(("[logana] highlight rule '%s' failed: %s"):format(
                table.concat(hl_rules[i], ' '), res and res.stderr or "failed to execute ripgrep"), vim.log.levels.WARN)
        elseif res.code == 0 then
            for lnum, boff, text in res.stdout:gmatch("(%d+):(%d+):([^\n]*)") do
                local idx = tonumber(lnum)
                local row = rows[idx]
                if row then
                    local col = tonumber(boff) + delta[idx]
                    local row_marks = by_row[row]
                    if not row_marks then
                        row_marks = {}
                        by_row[row] = row_marks
                    end
                    row_marks[#row_marks + 1] = { col, col + #text, i }
                end
            end
        end
    end

    return by_row
end

local function render_results(result_buf, parsed)
    -- result buffers are fully regenerated on every refresh; there's nothing
    -- worth undoing to, and snapshotting hundreds of thousands of prior lines
    -- into the undo tree before each replace made repeated refreshes take seconds.
    pcall(api.nvim_set_option_value, "undolevels", -1, { buf = result_buf })
    -- disable swapfile here too, since result buffers reloaded from disk via
    -- fn.bufadd/fn.bufload bypass create_normal_buffer's swapfile=false
    pcall(api.nvim_set_option_value, "swapfile", false, { buf = result_buf })

    local t1 = now_ms()
    api.nvim_buf_set_lines(result_buf, 0, -1, false, parsed.lines)
    log.trace(string.format("render_results set lines took: %d ms", now_ms() - t1))

    ensure_decoration_provider()
    -- level 2 highlights are recomputed against the new lines by the caller
    RESULT_HIGHLIGHTS[result_buf] = { match = parsed.match, hl = {} }
end

local function get_valid_opened_files()
    local files = {}
    local rule_ft = M.config.naming.rule
    local result_ft = M.config.naming.result
    for _, b in ipairs(api.nvim_list_bufs()) do
        local abs_path = api.nvim_buf_get_name(b)
        if api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) and abs_path ~= "" then
            local ok, stats = pcall(vim.uv.fs_stat, abs_path)
            if ok and stats then
                local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = b })
                ft = ok_ft and ft or ""
                if ft ~= rule_ft and ft ~= result_ft then
                    table.insert(files, fn.fnamemodify(abs_path, ":."))
                end
            end
        end
    end
    return files
end

local function get_runtime_opts(rule_buf)
    local args = { M.config.rg.cmd }
    for _, a in ipairs(M.config.rg.args) do
        -- output format is fixed by LEVEL1_ARGS; drop the old default from user configs
        if a ~= '--json' then
            table.insert(args, a)
        end
    end
    vim.list_extend(args, LEVEL1_ARGS)

    -- exclude rule/result files
    table.insert(args, '-g')
    table.insert(args, '!*.' .. M.config.naming.rule)
    table.insert(args, '-g')
    table.insert(args, '!*.' .. M.config.naming.result)

    local rule, perr = parse_rule_buf(rule_buf)
    if perr then
        return nil, perr
    end
    vim.list_extend(args, rule.rg.cmd)

    if rule.file and rule.file.opened_only then
        local files = get_valid_opened_files()
        if next(files) == nil then
            vim.notify("[logana] no valid files opened", vim.log.levels.INFO)
            return nil, {}
        end
        vim.list_extend(args, files)
    end

    -- level 1 needs a rerun when the rg args change, or (for opened files) when
    -- a searched file changes on disk; with a directory search there's no cheap
    -- way to detect file changes, see refresh_from_rule
    local sig = { table.concat(args, '\0') }
    if rule.file and rule.file.opened_only then
        for _, f in ipairs(args) do
            local st = vim.uv.fs_stat(f)
            if st and st.type == 'file' then
                table.insert(sig, ('%s:%d:%d.%d'):format(f, st.size, st.mtime.sec, st.mtime.nsec))
            end
        end
    end

    local hl_sig = {}
    for _, rule_args in ipairs(rule.hl_rules) do
        table.insert(hl_sig, table.concat(rule_args, '\0'))
    end

    return {
        args_common = args,
        match_sig = table.concat(sig, '\n'),
        hl_rules = rule.hl_rules,
        hl_sig = table.concat(hl_sig, '\n'),
        opened_only = rule.file and rule.file.opened_only or false,
    }
end

local function get_result_buf(rule_buf)
    local rule_abs_path = api.nvim_buf_get_name(rule_buf)
    local rule_prefix = fn.fnamemodify(rule_abs_path, ":t:r")
    local rule_dir = fn.fnamemodify(rule_abs_path, ':p:h')
    local result_abs_path = rule_dir .. '/' .. rule_prefix .. '.' .. M.config.naming.result

    local result_buf = fn.bufnr(result_abs_path)
    if result_buf == -1 then
        local ok, stats = pcall(vim.uv.fs_stat, result_abs_path)
        if ok and stats then
            result_buf = fn.bufadd(result_abs_path)
            fn.bufload(result_buf)
        else
            result_buf = create_normal_buffer(result_abs_path, M.config.naming.result)
        end
    end
    return result_buf
end

-- folding: each 'file: ' header in a result buffer starts a fold that runs to the
-- next header. which files are folded is kept in the rule buffer's [fold] section
-- (one file per line), so it survives refreshes and is saved with the rule file.
-- folds are manual, made from the header rows recorded at render time, since
-- foldexpr is evaluated per line and made refreshing a large result ~30% slower.

local function setup_fold_win(win)
    api.nvim_set_option_value('foldmethod', 'manual', { win = win, scope = 'local' })
    api.nvim_set_option_value('foldenable', true, { win = win, scope = 'local' })
end

-- returns the [fold] lines, and the 0-based [start, end) range of its body
-- (nil when there is no [fold] section)
local function read_fold_section(rule_buf)
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local files, body_start, body_end = {}, nil, #lines
    for i, line in ipairs(lines) do
        local section = line:match("^%s*%[(.+)%]%s*$")
        if section then
            if body_start then
                body_end = i - 1
                break
            end
            if section == 'fold' then
                body_start = i
            end
        elseif body_start and not line:match("^%s*$") and not line:match("^%s*#") then
            table.insert(files, vim.trim(line))
        end
    end
    -- keep the blank line separating [fold] from a following section
    while body_start and body_end > body_start and lines[body_end]:match("^%s*$") do
        body_end = body_end - 1
    end
    return files, body_start, body_end
end

local function write_fold_section(rule_buf, files)
    local cur, body_start, body_end = read_fold_section(rule_buf)
    if vim.deep_equal(cur, files) then
        return
    end
    if body_start then
        -- comments in the section are dropped along with the old entries
        api.nvim_buf_set_lines(rule_buf, body_start, body_end, false, files)
    elseif #files > 0 then
        local new = { '', '[fold]' }
        vim.list_extend(new, files)
        api.nvim_buf_set_lines(rule_buf, -1, -1, false, new)
    end
end

-- folded files in win; nil when the rows from the last render can't be trusted
local function capture_folds(st, win)
    if st.result_dirty or not st.file_rows then
        return nil
    end
    local files = {}
    api.nvim_win_call(win, function()
        if not vim.wo.foldenable then
            return
        end
        for _, fr in ipairs(st.file_rows) do
            if fn.foldclosed(fr[1]) ~= -1 then
                table.insert(files, fr[2])
            end
        end
    end)
    return files
end

local function apply_folds(st, win, files)
    if st.result_dirty or not st.file_rows then
        return
    end
    setup_fold_win(win)
    local closed = {}
    for _, f in ipairs(files) do
        closed[f] = true
    end
    local rows = st.file_rows
    local last = api.nvim_buf_line_count(st.result_buf)
    api.nvim_win_call(win, function()
        vim.cmd('silent! normal! zE')
        for i, fr in ipairs(rows) do
            local fold_end = rows[i + 1] and rows[i + 1][1] - 1 or last
            -- ':fold' leaves the new fold closed
            vim.cmd(('silent! %d,%dfold'):format(fr[1], fold_end))
            if not closed[fr[2]] then
                vim.cmd(('silent! %dfoldopen'):format(fr[1]))
            end
        end
    end)
end

local function rule_state_of_result(result_buf)
    for rule_buf, st in pairs(RULE_STATE) do
        if st.result_buf == result_buf and api.nvim_buf_is_valid(rule_buf) then
            return rule_buf, st
        end
    end
end

-- result window -> rule buffer: record which files are folded in win
local function save_folds(rule_buf, st, win)
    local files = capture_folds(st, win)
    if files then
        write_fold_section(rule_buf, files)
        st.fold_sig = table.concat(files, '\n')
    end
end

-- rule buffer -> result windows
local function restore_folds(rule_buf, st)
    local files = read_fold_section(rule_buf)
    for _, win in ipairs(fn.win_findbuf(st.result_buf)) do
        apply_folds(st, win, files)
    end
    st.fold_sig = table.concat(files, '\n')
end

-- level 1 ([rg] -> result lines) only reruns when its inputs changed, or the result
-- buffer is gone / was edited since we rendered it. level 2 ([highlight]) reruns
-- whenever level 1 did, or when the [highlight] rules changed.
-- with opened_only = false, changes to the files under cwd can't be detected, so
-- a refresh where nothing else changed reruns level 1 too.
local function refresh_from_rule(rule_buf)
    local t_all = now_ms()
    local ropts, err = get_runtime_opts(rule_buf)
    if err then
        return nil, "get runtime opts failed"
    end

    local st = RULE_STATE[rule_buf] or {}
    RULE_STATE[rule_buf] = st

    -- record the result window's folds before re-rendering, unless [fold] was
    -- edited by hand since, then that wins and is applied below
    local fold_edited = table.concat(read_fold_section(rule_buf), '\n') ~= st.fold_sig
    local fold_win = st.result_buf and api.nvim_buf_is_valid(st.result_buf) and fn.bufwinid(st.result_buf) or -1
    if not fold_edited and fold_win ~= -1 then
        local t = now_ms()
        save_folds(rule_buf, st, fold_win)
        log.trace(string.format("save_folds took: %d ms", now_ms() - t))
    end
    local rerendered = false

    local result_intact = st.result_buf and api.nvim_buf_is_valid(st.result_buf)
        and not st.result_dirty and RESULT_HIGHLIGHTS[st.result_buf] ~= nil

    local unchanged = st.hl_sig == ropts.hl_sig and not fold_edited
    if not result_intact or st.match_sig ~= ropts.match_sig
        or (unchanged and not ropts.opened_only) then
        local t0 = now_ms()
        local parsed, merr = collect_matches(ropts)
        if merr then
            return nil, "collect_matches failed"
        end
        log.trace(string.format("collect_matches took: %d ms", now_ms() - t0))

        local result_buf = get_result_buf(rule_buf)
        local t1 = now_ms()
        render_results(result_buf, parsed)
        st.hl_input, st.hl_map, st.file_rows = parsed.hl_input, parsed.hl_map, parsed.file_rows
        log.trace(string.format("render_results took: %d ms", now_ms() - t1))

        -- track user edits of the result buffer (changedtick can't be used, ':w'
        -- bumps it too). on_lines also fires for our own set_lines in
        -- render_results above, hence resetting result_dirty after it.
        if st.attached_buf ~= result_buf then
            st.attached_buf = result_buf
            api.nvim_buf_attach(result_buf, false, {
                on_lines = function()
                    if st.attached_buf ~= result_buf then
                        return true -- detach, the rule now renders elsewhere
                    end
                    st.result_dirty = true
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
        st.result_buf = result_buf
        st.result_dirty = false
        st.match_sig = ropts.match_sig
        st.hl_sig = nil
        rerendered = true
    end

    -- show the result buffer if it isn't, e.g. first refresh or its window was closed
    if fn.bufwinid(st.result_buf) == -1 then
        local rule_win = fn.bufwinid(rule_buf)
        result_open_win(st.result_buf, rule_win ~= -1 and rule_win or api.nvim_get_current_win())
    end

    if st.hl_sig ~= ropts.hl_sig then
        local t2 = now_ms()
        RESULT_HIGHLIGHTS[st.result_buf].hl = collect_highlights(ropts.hl_rules, st.hl_input, st.hl_map)
        log.trace(string.format("collect_highlights took: %d ms", now_ms() - t2))
        st.hl_sig = ropts.hl_sig
        -- decoration provider marks are ephemeral; force visible windows to redraw them
        pcall(api.nvim__redraw, { buf = st.result_buf, valid = false })
    end

    if rerendered or fold_edited then
        local t3 = now_ms()
        restore_folds(rule_buf, st)
        log.trace(string.format("restore_folds took: %d ms", now_ms() - t3))
    end
    log.trace(string.format("refresh took: %d ms", now_ms() - t_all))
end

local function find_rg_section_end(buf)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local in_rg = false
    local last_lnum = nil
    for i, line in ipairs(lines) do
        if line:match("^%s*%[rg%]%s*$") then
            in_rg = true
        elseif in_rg and line:match("^%s*%[.+%]%s*$") then
            break
        elseif in_rg and not line:match("^%s*$") and not line:match("^%s*#") then
            last_lnum = i
        end
    end
    return last_lnum
end

-- fill an empty rule buffer with the template, however it was opened
-- (:e, :new, a session...), and put the cursor where the [rg] args go
local function initialize_rule_buffer(rule_buf)
    local curr = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    if not (#curr == 0 or (#curr == 1 and curr[1] == "")) then
        return
    end
    -- keep the template out of undo history, 'u' shouldn't empty the buffer
    local undolevels = api.nvim_get_option_value('undolevels', { buf = rule_buf })
    api.nvim_set_option_value('undolevels', -1, { buf = rule_buf })
    api.nvim_buf_set_lines(rule_buf, 0, -1, false, vim.split(M.config.rule_template, '\n'))
    api.nvim_set_option_value('undolevels', undolevels, { buf = rule_buf })

    local rg_end = find_rg_section_end(rule_buf)
    if rg_end then
        for _, win in ipairs(fn.win_findbuf(rule_buf)) do
            pcall(api.nvim_win_set_cursor, win, { rg_end, 0 })
        end
    end
end

local function result_buffer_jump()
    local line = api.nvim_get_current_line()
    local lnum_str = line:match("^(%d+):")
    if not lnum_str then
        vim.notify("[logana] not at matched line", vim.log.levels.INFO)
        return
    end
    local lnum = tonumber(lnum_str)
    local cursor = api.nvim_win_get_cursor(0)
    local col = math.max(0, cursor[2] - #lnum_str - 2) -- -2 for ':' and ' '

    -- reverse search from current line for the file header
    local fline_num = fn.search('^file: ', 'bn')
    if fline_num == 0 then
        vim.notify("[logana] did not find 'file:'", vim.log.levels.INFO)
        return
    end

    local file = fn.getline(fline_num):match("^file: (.+)$")
    if not file or file == '' then
        return
    end

    if not vim.uv.fs_stat(file) then
        vim.notify(("[logana] file: %s does not exist"):format(file), vim.log.levels.INFO)
        return
    end

    local target_buf = fn.bufnr(file)
    if target_buf == -1 then
        target_buf = fn.bufadd(file)
        fn.bufload(target_buf)
    end

    local win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, target_buf)
    pcall(api.nvim_win_set_cursor, win, { lnum, col })
end

local function setup_highlights()
    M.config.hi_match_group = "LoganaMatch"
    local match_hl = vim.tbl_extend("force", {}, M.config.match_color)
    match_hl.default = true
    pcall(api.nvim_set_hl, 0, M.config.hi_match_group, match_hl)

    M.config.hi_group_names = {}
    for i, spec in ipairs(M.config.highlight_colors) do
        local name = "LoganaHighlight" .. i
        local hl = vim.tbl_extend("force", {}, spec)
        hl.default = true
        pcall(api.nvim_set_hl, 0, name, hl)
        M.config.hi_group_names[i] = name
    end
end

local function setup_config(opts)
    local defconfig = require('logana.defconfig')
    M.config = vim.tbl_deep_extend("force", defconfig, opts or {})

    if fn.executable(M.config.rg.cmd) ~= 1 then
        error("[logana] ripgrep (" .. M.config.rg.cmd .. ") not found in PATH")
    end

    setup_highlights()

    vim.filetype.add({
        extension = {
            [M.config.naming.rule] = M.config.naming.rule,
            [M.config.naming.result] = M.config.naming.result,
        },
    })
end

local function setup_keybinding()
    if M._quit_auto then
        return
    end

    -- Suppress save prompts on quit for rule/result buffers by marking them nomodified
    M._quit_auto = api.nvim_create_augroup("logana_quit_guard", { clear = true })

    -- Disable swapfile for rule/result files regardless of how the buffer is opened
    -- (create_normal_buffer covers plugin-created buffers, but this covers e.g. a
    -- user directly `:e`-ing an existing saved rule/result file). Must run on
    -- BufReadPre/BufNewFile, before Neovim creates the swap file, not FileType.
    api.nvim_create_autocmd({ "BufNewFile", "BufReadPre" }, {
        group = M._quit_auto,
        pattern = { '*.' .. M.config.naming.rule, '*.' .. M.config.naming.result },
        command = "setlocal noswapfile",
        desc = "logana: disable swapfile for rule/result files",
    })

    api.nvim_create_autocmd("QuitPre", {
        group = M._quit_auto,
        callback = function()
            for _, b in ipairs(api.nvim_list_bufs()) do
                local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = b })
                ft = ok_ft and ft or ""
                if ft == M.config.naming.rule or ft == M.config.naming.result then
                    local abs_path = api.nvim_buf_get_name(b)
                    local ok, stats = pcall(vim.uv.fs_stat, abs_path)
                    if not (ok and stats) then
                        pcall(api.nvim_set_option_value, "modified", false, { buf = b })
                    end
                end
            end
        end,
        desc = "logana: mark rule/result buffers as nomodified on QuitPre",
    })

    api.nvim_create_autocmd("FileType", {
        group = M._quit_auto,
        pattern = M.config.naming.rule,
        callback = function(ev)
            initialize_rule_buffer(ev.buf)
            vim.keymap.set("n", M.config.key.rule_refresh, function()
                refresh_from_rule(ev.buf)
            end, { buffer = ev.buf, noremap = true, silent = true, desc = "logana: refresh results" })
        end,
        desc = "logana: template and keybinding for rule file",
    })

    api.nvim_create_autocmd("FileType", {
        group = M._quit_auto,
        pattern = M.config.naming.result,
        callback = function(ev)
            vim.keymap.set("n", M.config.key.result_jump, result_buffer_jump,
                { buffer = ev.buf, noremap = true, silent = true, desc = "logana: results jump" })

            local group = api.nvim_create_augroup("logana_fold_" .. ev.buf, { clear = true })
            api.nvim_create_autocmd("BufWinEnter", {
                group = group,
                buffer = ev.buf,
                callback = function()
                    local rule_buf, st = rule_state_of_result(ev.buf)
                    if rule_buf then
                        restore_folds(rule_buf, st)
                    else
                        for _, win in ipairs(fn.win_findbuf(ev.buf)) do
                            setup_fold_win(win)
                        end
                    end
                end,
                desc = "logana: fold result buffer by file",
            })
            api.nvim_create_autocmd("WinLeave", {
                group = group,
                buffer = ev.buf,
                callback = function()
                    local rule_buf, st = rule_state_of_result(ev.buf)
                    if rule_buf then
                        save_folds(rule_buf, st, api.nvim_get_current_win())
                    end
                end,
                desc = "logana: save result folds to the rule buffer",
            })
        end,
        desc = "logana: keybinding for jumping in result buf",
    })
end

-- same as pressing <Enter> in rule_buf
function M.refresh(rule_buf)
    return refresh_from_rule(rule_buf)
end

function M.setup(opts)
    setup_config(opts)
    setup_keybinding()
end

return M
