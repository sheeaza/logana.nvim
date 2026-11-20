-- level 1 output format, and its parser in lua (scan.lua is the LuaJIT one)
local M = {}

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

-- strips the markers from a level 1 line, appending its match ranges to cols after
-- index c; returns the text and the number of ranges (0 e.g. with -v)
local function unmark(raw, cols, c)
    local a = raw:find(MARK_S, 1, true)
    if not a then
        return raw, 0
    end
    local b = raw:find(MARK_E, a + 1, true)
    -- most lines have one match, plain sub/concat is ~1/3 faster for those
    if b and not raw:find(MARK_S, b + 1, true) then
        cols[c + 1], cols[c + 2] = a - 1, b - 2
        return raw:sub(1, a - 1) .. raw:sub(a + 1, b - 1) .. raw:sub(b + 1), 1
    end
    local parts, nm, len, s = {}, 0, 0, 1
    while a do
        b = raw:find(MARK_E, a + 1, true)
        if not b then
            break
        end
        local start = len + a - s
        parts[#parts + 1] = raw:sub(s, a - 1)
        parts[#parts + 1] = raw:sub(a + 1, b - 1)
        len = start + b - a - 1
        cols[c + 1], cols[c + 2] = start, len
        c, nm = c + 2, nm + 1
        s = b + 1
        a = raw:find(MARK_S, s, true)
    end
    parts[#parts + 1] = raw:sub(s)
    return table.concat(parts), nm
end

-- level 1 parse state, kept across the batches of one rg run:
-- {
--     n = <buffer rows written so far>,
--     match = { first, count, cols },  -- as in highlight.lua's RESULT_HIGHLIGHTS, 0-based rows
--     file_rows = { { <1-based row of 'file: ' header>, <path> }, ... },
--     k = <matched lines so far>,
-- }
local function new_parser()
    return { n = 0, k = 0, match = { first = {}, count = {}, cols = {} }, file_rows = {},
        o = 0, cap = 0, plen = -1, pcap = 0 } -- scan_batch only: its output and current path
end

-- parses whole lines of level 1 output; returns the buffer lines they add
local function parse_batch(p, data)
    local out, m = {}, 0
    local n, k, cur = p.n, p.k, p.cur
    local file_rows = p.file_rows
    local first, count, cols = p.match.first, p.match.count, p.match.cols
    local c = #cols

    -- anchored on '\n' (data gets one in front): unanchored, a line that doesn't
    -- match (a context line) is retried from each of its bytes, quadratic in its length
    for path, raw in ('\n' .. data):gmatch("\n([^%z\n]*)%z(%d+: [^\n]*)") do
        if path ~= cur then
            if cur then
                m, n = m + 1, n + 1
                out[m] = ''
            end
            m, n = m + 1, n + 1
            out[m] = 'file: ' .. path
            file_rows[#file_rows + 1] = { n, path }
            cur = path
        end
        -- markers are only in the text part, so ranges are already buffer columns
        local line, nm = unmark(raw, cols, c)
        m, n, k = m + 1, n + 1, k + 1
        out[m] = line
        if nm > 0 then
            first[n - 1], count[n - 1] = c + 1, nm
            c = c + 2 * nm
        end
    end

    p.n, p.k, p.cur = n, k, cur
    return out
end

M.ARGS = LEVEL1_ARGS
M.new_parser = new_parser
M.parse_batch = parse_batch
return M
