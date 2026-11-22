-- drawing levels 1 and 2 with a decoration provider, and computing level 2
local api = vim.api
local fn = vim.fn
local config = require('logana.config')
local log = require('logana.log')
local now_ms = require('logana.util').now_ms
local process = require('logana.proc')
local ranges = require('logana.level1').ranges

local M = {}

local NS_MATCH = api.nvim_create_namespace("logana.match")

-- highlight ranges per result buffer, keyed by 0-based row:
-- {
--     -- level 1, [rg]: in ffi arrays, see level1.lua's ranges. no table per row:
--     -- the incremental GC re-marks every live table while a large result streams
--     -- in, which made it cost as much as the parsing
--     match = { start, cols, ... },
--     -- level 2, [highlight], computed for rows as they're drawn, see highlight_rows.
--     -- false: asked for, or no match. replaced when the rules change
--     hl = { [row] = { {start_col, end_col, hl_idx}, ... } | false },
--     hl_rules = <rg args lists>, warned = { [rule idx] = true }, pending = <requests not done>,
--     busy = <a request runs>, queued = <rows for the next one>, queued_n = <requests in it>,
-- }
-- highlighted lazily via decoration provider (ephemeral extmarks) instead of eagerly,
-- since eagerly creating one extmark per match makes the first redraw of a large
-- result buffer (hundreds of thousands of matches) take seconds.
local RESULT_HIGHLIGHTS = {}
-- level 2 of the source files of a result, per source buffer: like a result's
-- hl / hl_rules / warned / pending / busy / queued, plus src = true, from = <the
-- rule buffer's state it took the rules from>, tick = <the buffer's changedtick>
local SOURCE_HIGHLIGHTS = {}
-- window -> the source highlights on_win picked for it, for on_line in the same redraw
local WIN_SOURCE = {}
-- file_rows table -> { n = <rows looked at>, set = { [full path] = true } }
local SOURCE_PATHS = setmetatable({}, { __mode = 'k' })
local decoration_provider_ready = false
-- buffers source_of found a rule buffer for once, M.on_source was called with
local SOURCE_SEEN = {}

-- level 2 draws above level 1, so a [highlight] color wins where both overlap
local PRIORITY_MATCH = 4096
local PRIORITY_HL = 4097

local function draw_mark(bufnr, row, s, e, hl_group, priority)
    api.nvim_buf_set_extmark(bufnr, NS_MATCH, row, s, {
        end_row = row,
        end_col = e,
        hl_group = hl_group,
        priority = priority,
        ephemeral = true,
    })
end

-- highlights -> { buf = <its buffer>, <rows drawn without level 2 ranges yet> },
-- asked for in on_end
local HL_WANT = {}
local highlight_rows

-- asks for level 2 of rows, outside the redraw, which shouldn't start processes.
-- one request per buffer at a time: rows drawn while it runs wait in hls.queued
-- and go in the next one together, else holding a scroll key started one rg per
-- rule per redraw
local function start_rows(bufnr, hls, rows, n)
    hls.busy = true
    vim.schedule(function()
        highlight_rows(bufnr, hls, rows, function()
            hls.pending = hls.pending - n
            local queued, queued_n = hls.queued, hls.queued_n
            hls.queued, hls.queued_n, hls.busy = nil, 0, false
            if queued then
                start_rows(bufnr, hls, queued, queued_n)
            end
        end)
    end)
end

local function request_rows(bufnr, hls, rows)
    -- counted here, not when it runs, so tests waiting on it can't miss it
    hls.pending = hls.pending + 1
    if not hls.busy then
        return start_rows(bufnr, hls, rows, 1)
    end
    hls.queued = vim.list_extend(hls.queued or {}, rows)
    hls.queued_n = (hls.queued_n or 0) + 1
end

-- the full paths of a result's 'file:' headers, extended as level 1 adds some
local function has_source(rows, path)
    local p = SOURCE_PATHS[rows]
    if not p then
        p = { n = 0, set = {} }
        SOURCE_PATHS[rows] = p
    end
    for i = p.n + 1, #rows do
        p.set[fn.fnamemodify(rows[i][2], ':p')] = true
    end
    p.n = #rows
    return p.set[path] == true
end

-- the source highlights of a buffer, or nil: it must be a source of a rule buffer's
-- result (a 'file:' header of it), bound to that rule buffer, not to a window: it
-- keeps its colors in any tab, also with the result closed or wiped, until the rule
-- buffer is. of several, the last refreshed rule buffer gives the rules. started
-- over when those rules change, or the buffer does (edits, :e)
-- the rule buffer and its state a buffer is a source of, as source_highlights
-- picks it, also with no [highlight] rules. nil: none, or hl_buf is off
local function source_of(bufnr)
    if not config.highlight.hl_buf or api.nvim_get_option_value('buftype', { buf = bufnr }) ~= '' then
        return nil
    end
    local path = api.nvim_buf_get_name(bufnr)
    if path == '' then
        return nil
    end
    local from, from_buf
    for rule_buf, st in pairs(require('logana.refresh').state) do -- it requires this module
        -- while level 1 loads, the headers it found so far
        local rows = st.job and st.job.parser.file_rows or st.file_rows
        if rows and st.hl_rules and (not from or st.bound > from.bound)
            and api.nvim_buf_is_valid(rule_buf) and has_source(rows, path) then
            from, from_buf = st, rule_buf
        end
    end
    if from and not SOURCE_SEEN[bufnr] and M.on_source then
        SOURCE_SEEN[bufnr] = true
        vim.schedule(function() -- not in the redraw
            if api.nvim_buf_is_valid(bufnr) then
                M.on_source(bufnr)
            end
        end)
    end
    return from_buf, from
end

local function source_highlights(bufnr)
    local _, from = source_of(bufnr)
    if not from or #from.hl_rules == 0 then
        SOURCE_HIGHLIGHTS[bufnr] = nil -- e.g. its rule buffer was wiped
        return nil
    end
    local tick = api.nvim_buf_get_changedtick(bufnr)
    local hls = SOURCE_HIGHLIGHTS[bufnr]
    if not hls or hls.from ~= from or hls.hl_rules ~= from.hl_rules or hls.tick ~= tick then
        -- warned shared with the result: a bad rule warns once
        hls = { src = true, from = from, tick = tick, hl = {}, hl_rules = from.hl_rules,
            warned = from.hl_warned, pending = 0 }
        SOURCE_HIGHLIGHTS[bufnr] = hls
    end
    return hls
end

-- the level 2 marks of a row, or asks for them once
local function draw_hl(bufnr, hls, row)
    local marks = hls.hl[row]
    if marks == nil and #hls.hl_rules > 0 then
        hls.hl[row] = false -- asked for once
        local want = HL_WANT[hls]
        if not want then
            want = { buf = bufnr }
            HL_WANT[hls] = want
        end
        want[#want + 1] = row
    elseif marks then
        local names = config.hi_group_names
        for _, hi in ipairs(marks) do
            draw_mark(bufnr, row, hi[1], hi[2], names[(hi[3] - 1) % #names + 1], PRIORITY_HL)
        end
    end
end

local function ensure_decoration_provider()
    if decoration_provider_ready then
        return
    end
    decoration_provider_ready = true

    api.nvim_set_decoration_provider(NS_MATCH, {
        on_win = function(_, win, bufnr)
            if RESULT_HIGHLIGHTS[bufnr] then
                return true
            end
            local src = source_highlights(bufnr)
            WIN_SOURCE[win] = src
            return src ~= nil
        end,
        on_line = function(_, win, bufnr, row)
            local hls = RESULT_HIGHLIGHTS[bufnr]
            if not hls then
                -- a source file: level 2 only, the [rg] color stays in the result
                return draw_hl(bufnr, WIN_SOURCE[win], row)
            end
            local m = hls.match
            local lo, hi = ranges(m, row)
            for j = lo, hi - 1, 2 do
                draw_mark(bufnr, row, m.cols[j], m.cols[j + 1], config.hi_match_group, PRIORITY_MATCH)
            end
            draw_hl(bufnr, hls, row)
        end,
        on_end = function()
            for win in pairs(WIN_SOURCE) do
                WIN_SOURCE[win] = nil
            end
            for hls, want in pairs(HL_WANT) do
                HL_WANT[hls] = nil
                request_rows(want.buf, hls, want)
            end
        end,
    })
end

-- level 2, lazily: a row gets its [highlight] ranges when it's first drawn
-- (on_line marks it false, on_end asks for it), so a refresh doesn't wait on every
-- row, and visible rows are colored while level 1 still loads. each rule runs
-- through rg over the rows' texts (stdin), so highlight patterns use the same regex
-- syntax/options as [rg]. asynchronous: the ranges go to hls.hl, then the windows
-- redraw. on_done is called either way. a source file's rows are colored the same
-- way, over their whole line.
local function live(bufnr, hls)
    return (hls.src and SOURCE_HIGHLIGHTS or RESULT_HIGHLIGHTS)[bufnr] == hls
end

highlight_rows = function(bufnr, hls, rows, on_done)
    local cache, rules = hls.hl, hls.hl_rules
    if not live(bufnr, hls) or #rules == 0 or #config.hi_group_names == 0 then
        return on_done()
    end
    -- '<lnum>: <text>' rows; headers and blank lines have nothing to color
    local texts, map_row, map_delta, pos = {}, {}, {}, 0
    for _, row in ipairs(rows) do
        cache[row] = cache[row] or false
        local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        local ts = line and (hls.src and 1 or line:match('^%d+: ()'))
        if ts then
            local i = #texts + 1
            texts[i], map_row[i], map_delta[i] = line:sub(ts), row, ts - 1 - pos
            pos = pos + #texts[i] + 1
        end
    end
    if #texts == 0 then
        return on_done()
    end
    texts[#texts + 1] = '' -- every text ends with '\n'
    local input = table.concat(texts, '\n')
    local t0 = now_ms()

    local results, left = {}, #rules
    local function apply()
        on_done()
        log.trace(string.format("highlight rows took: %d ms", now_ms() - t0))
        if not live(bufnr, hls) or hls.hl ~= cache then
            return -- level 1 reran or the rules changed meanwhile
        end
        for i, res in ipairs(results) do
            if not res or res.code == 2 then
                -- once per rule, not on every scroll
                if not hls.warned[i] then
                    hls.warned[i] = true
                    vim.notify(("[logana] highlight rule '%s' failed: %s"):format(table.concat(rules[i], ' '),
                        res and res.stderr or "failed to execute ripgrep"), vim.log.levels.WARN)
                end
            elseif res.code == 0 then
                for lnum, boff, text in res.stdout:gmatch("(%d+):(%d+):([^\n]*)") do
                    local idx = tonumber(lnum)
                    local row = map_row[idx]
                    if row then
                        local col = tonumber(boff) + map_delta[idx]
                        local marks = cache[row] or {}
                        cache[row] = marks
                        marks[#marks + 1] = { col, col + #text, i }
                    end
                end
            end
        end
        -- decoration provider marks are ephemeral; force visible windows to redraw them
        pcall(api.nvim__redraw, { buf = bufnr, valid = false })
    end

    for i, rule_args in ipairs(rules) do
        -- plain '<lnum>:<abs byte offset>:<match>' output instead of --json, since
        -- decoding json in lua dominates the cost on large result buffers
        local args = { config.rg.cmd, '--no-config', '--color', 'never', '--no-filename',
            '--line-number', '--byte-offset', '--only-matching' }
        vim.list_extend(args, rule_args)
        table.insert(args, '-')
        -- exit callbacks only run once this loop is done, left can't reach 0 in it
        local ok = pcall(process.system, args, { text = true, stdin = input }, function(res)
            results[i] = res
            left = left - 1
            if left == 0 then
                vim.schedule(apply)
            end
        end)
        if not ok then
            results[i] = false
            left = left - 1
        end
    end
    if left == 0 then
        vim.schedule(apply)
    end
end

-- starts over level 2 with these rules, rows get them as they're drawn
local function reset_highlights(hls, ropts)
    hls.hl, hls.hl_rules, hls.warned = {}, ropts.hl_rules, {}
end

-- level 1 ranges of a row as { {start_col, end_col}, ... }, or nil
local function match_ranges(bufnr, row)
    local m = RESULT_HIGHLIGHTS[bufnr].match
    local lo, hi = ranges(m, row)
    if lo == hi then
        return nil
    end
    local out = {}
    for j = lo, hi - 1, 2 do
        out[#out + 1] = { m.cols[j], m.cols[j + 1] }
    end
    return out
end

local function define_highlights()
    config.hi_match_group = "LoganaMatch"
    local match_hl = vim.tbl_extend("force", {}, config.match_color)
    match_hl.default = true
    pcall(api.nvim_set_hl, 0, config.hi_match_group, match_hl)

    config.hi_group_names = {}
    for i, spec in ipairs(config.highlight_colors) do
        local name = "LoganaHighlight" .. i
        local hl = vim.tbl_extend("force", {}, spec)
        hl.default = true
        pcall(api.nvim_set_hl, 0, name, hl)
        config.hi_group_names[i] = name
    end
end

-- :colorscheme runs :hi clear, which empties the Logana* groups: define them
-- again. Extmarks only hold the group names, so open results get their colors back
local function setup_highlights()
    define_highlights()
    api.nvim_create_autocmd("ColorScheme", {
        group = api.nvim_create_augroup("logana_highlights", { clear = true }),
        callback = define_highlights,
    })
end

-- after a refresh or a rule buffer is wiped: the windows that may show a source
-- file, for new rules or a new set of source files. decoration provider marks are ephemeral, they're only
-- redrawn when the window is
local function redraw_sources()
    if not config.highlight.hl_buf then
        return
    end
    for _, win in ipairs(api.nvim_list_wins()) do
        if not RESULT_HIGHLIGHTS[api.nvim_win_get_buf(win)] then
            pcall(api.nvim__redraw, { win = win, valid = false })
        end
    end
end

M.by_buf = RESULT_HIGHLIGHTS
M.source_by_buf = SOURCE_HIGHLIGHTS
M.redraw_sources = redraw_sources
M.source_of = source_of
M.ensure_decoration_provider = ensure_decoration_provider
M.reset_highlights = reset_highlights
M.match_ranges = match_ranges
M.setup_highlights = setup_highlights
return M
