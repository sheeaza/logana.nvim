-- level 1 output format and parse state (scan.lua parses it)
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

-- level 1 parse state, kept across the batches of one rg run:
-- {
--     n = <buffer rows written so far>,
--     match = { first, count, cols },  -- as in highlight.lua's RESULT_HIGHLIGHTS, 0-based rows
--     file_rows = { { <1-based row of 'file: ' header>, <path> }, ... },
--     k = <matched lines so far>,
-- }
local function new_parser()
    return { n = 0, k = 0, match = { first = {}, count = {}, cols = {} }, file_rows = {},
        o = 0, cap = 0, plen = -1, pcap = 0 } -- scan_batch's output and current path
end

M.ARGS = LEVEL1_ARGS
M.new_parser = new_parser
return M
