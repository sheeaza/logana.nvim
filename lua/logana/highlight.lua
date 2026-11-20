-- drawing levels 1 and 2 with a decoration provider, and computing level 2
local api = vim.api
local config = require('logana.config')
local log = require('logana.log')
local now_ms = require('logana.util').now_ms

local M = {}

local NS_MATCH = api.nvim_create_namespace("logana.match")

-- highlight ranges per result buffer, keyed by 0-based row:
-- {
--     -- level 1, [rg]: the row's ranges are cols[first[row]], cols[first[row] + 1], ...
--     -- for count[row] pairs. only numbers, no table per row: the incremental GC
--     -- re-marks every live table while a large result streams in, which made it
--     -- cost as much as the parsing
--     match = { first = { [row] = i }, count = { [row] = n }, cols = { s1, e1, s2, e2, ... } },
--     -- level 2, [highlight], computed for rows as they're drawn, see highlight_rows.
--     -- false: asked for, or no match. replaced when the rules change
--     hl = { [row] = { {start_col, end_col, hl_idx}, ... } | false },
--     hl_rules = <rg args lists>, warned = { [rule idx] = true }, pending = <requests running>,
-- }
-- highlighted lazily via decoration provider (ephemeral extmarks) instead of eagerly,
-- since eagerly creating one extmark per match makes the first redraw of a large
-- result buffer (hundreds of thousands of matches) take seconds.
local RESULT_HIGHLIGHTS = {}
local decoration_provider_ready = false

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

-- result buffer -> rows drawn without level 2 ranges yet, asked for in on_end
local HL_WANT = {}
local highlight_rows

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
            local m = hls.match
            local i = m.first[row]
            if i then
                local cols, group = m.cols, config.hi_match_group
                for j = i, i + 2 * m.count[row] - 1, 2 do
                    draw_mark(bufnr, row, cols[j], cols[j + 1], group, PRIORITY_MATCH)
                end
            end
            local marks = hls.hl[row]
            if marks == nil and #hls.hl_rules > 0 then
                hls.hl[row] = false -- asked for once
                local want = HL_WANT[bufnr] or {}
                HL_WANT[bufnr] = want
                want[#want + 1] = row
            elseif marks then
                local names = config.hi_group_names
                for _, hi in ipairs(marks) do
                    draw_mark(bufnr, row, hi[1], hi[2], names[(hi[3] - 1) % #names + 1], PRIORITY_HL)
                end
            end
        end,
        on_end = function()
            for bufnr, rows in pairs(HL_WANT) do
                HL_WANT[bufnr] = nil
                local hls = RESULT_HIGHLIGHTS[bufnr]
                if hls then
                    -- counted here, not when it runs, so tests waiting on it can't miss it
                    hls.pending = hls.pending + 1
                    -- outside the redraw, which shouldn't start processes.
                    -- shortcut: one rg per rule per redraw with new rows, not throttled;
                    -- batch them if holding a scroll key spawns too many
                    vim.schedule(function()
                        highlight_rows(bufnr, hls, rows, function() hls.pending = hls.pending - 1 end)
                    end)
                end
            end
        end,
    })
end

-- level 2, lazily: a row gets its [highlight] ranges when it's first drawn
-- (on_line marks it false, on_end asks for it), so a refresh doesn't wait on every
-- row, and visible rows are colored while level 1 still loads. each rule runs
-- through rg over the rows' texts (stdin), so highlight patterns use the same regex
-- syntax/options as [rg]. asynchronous: the ranges go to hls.hl, then the windows
-- redraw. on_done is called either way.
highlight_rows = function(bufnr, hls, rows, on_done)
    local cache, rules = hls.hl, hls.hl_rules
    if RESULT_HIGHLIGHTS[bufnr] ~= hls or #rules == 0 or #config.hi_group_names == 0 then
        return on_done()
    end
    -- '<lnum>: <text>' rows; headers and blank lines have nothing to color
    local texts, map_row, map_delta, pos = {}, {}, {}, 0
    for _, row in ipairs(rows) do
        cache[row] = cache[row] or false
        local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        local ts = line and line:match('^%d+: ()')
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
        if RESULT_HIGHLIGHTS[bufnr] ~= hls or hls.hl ~= cache then
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
        local ok = pcall(vim.system, args, { text = true, stdin = input }, function(res)
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
    local i = m.first[row]
    if not i then
        return nil
    end
    local out = {}
    for j = i, i + 2 * m.count[row] - 1, 2 do
        out[#out + 1] = { m.cols[j], m.cols[j + 1] }
    end
    return out
end

local function setup_highlights()
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

M.by_buf = RESULT_HIGHLIGHTS
M.ensure_decoration_provider = ensure_decoration_provider
M.reset_highlights = reset_highlights
M.match_ranges = match_ranges
M.setup_highlights = setup_highlights
return M
