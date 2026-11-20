-- Headless benchmark of one refresh (<Enter> in a rule buffer), split by phase:
--   nvim --headless -u NONE -l tests/bench.lua <log file or dir> [runs] [--xl]
-- Phase times come from the plugin's log.trace timers. Each case does one warmup
-- refresh (fills the page cache, opens the result window), then reports the median
-- of [runs] refreshes (default 3). Redraw isn't measured, there is no UI attached.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")

local target, runs, xl
for _, a in ipairs(_G.arg) do
    if a == "--xl" then
        xl = true
    elseif tonumber(a) then
        runs = tonumber(a)
    else
        target = a
    end
end
runs = runs or 3
if not target or not vim.uv.fs_stat(target) then
    io.stderr:write("usage: nvim --headless -u NONE -l tests/bench.lua <log file or dir> [runs] [--xl]\n")
    os.exit(2)
end
target = vim.fn.fnamemodify(target, ":p")

-- collect "<phase> took: <n> ms" from log.trace; must be patched before the
-- plugin calls it, it looks the field up on every call
local log = require("logana.log")
local samples
log.trace = function(msg)
    local phase, ms = msg:match("^(.-) took: (%d+) ms")
    if phase and samples then
        samples[phase] = samples[phase] or {}
        table.insert(samples[phase], tonumber(ms))
    end
end

local api = vim.api
local L = require("logana")
L.setup({})

local HL = { "--smart-case", "-e 'ResourceReserve'", "-e 'start is'", "-e 'stop is'" }

-- match counts are for the camera log this was written against (~2.6M lines / 500 MB)
local CASES = {
    { name = "small", rg = { "-F", "-e 'ResourceReserve'" } }, -- ~900 matches
    { name = "medium", rg = { "-F", "-e 'DRV_COMMON'" } },     -- ~130k
    { name = "large", rg = { "-F", "-e 'CLIENT_MGR'" } },      -- ~740k
}
if xl then
    table.insert(CASES, { name = "xl", rg = { "-F", "-e 'Info  '" } }) -- ~2.5M
end

-- order of the columns, in the order they run
local PHASES = {
    { "rg", "rg" },
    { "parse rg output", "parse" },
    { "render_results set lines", "set_lines" },
    { "collect_highlights", "hl" },
    { "save_folds", "save_fold" },
    { "restore_folds", "rest_fold" },
    { "refresh", "total" },
}

local function median(t)
    if not t or #t == 0 then
        return nil
    end
    local s = vim.list_slice(t)
    table.sort(s)
    return s[math.ceil(#s / 2)]
end

local function set_rule(rule_buf, rg)
    local lines = { "[rg]" }
    vim.list_extend(lines, rg)
    -- the target goes after the patterns, as an rg path argument
    table.insert(lines, vim.fn.shellescape(target))
    vim.list_extend(lines, { "[file]", "opened_only = false", "[highlight]" })
    vim.list_extend(lines, HL)
    api.nvim_buf_set_lines(rule_buf, 0, -1, false, lines)
end

local header = { ("%-7s"):format("case"), ("%9s"):format("res_lines") }
for _, p in ipairs(PHASES) do
    table.insert(header, ("%9s"):format(p[2]))
end
table.insert(header, ("%8s"):format("rss_MB"))
print(("target: %s, median of %d runs, ms"):format(target, runs))
print(table.concat(header, " "))

for _, case in ipairs(CASES) do
    vim.cmd("silent! %bwipeout!")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.chdir(dir)
    vim.cmd("edit 0.logana_rule")
    local rule = api.nvim_get_current_buf()
    set_rule(rule, case.rg)

    samples = nil
    L.refresh(rule) -- warmup
    samples = {}
    -- with opened_only = false and nothing changed, every refresh reruns both levels
    for _ = 1, runs do
        L.refresh(rule)
    end

    local rbuf = vim.fn.bufnr("0.logana_result")
    local nlines = rbuf ~= -1 and api.nvim_buf_line_count(rbuf) or 0
    local row = { ("%-7s"):format(case.name), ("%9d"):format(nlines) }
    for _, p in ipairs(PHASES) do
        local m = median(samples[p[1]])
        table.insert(row, ("%9s"):format(m and tostring(m) or "-"))
    end
    collectgarbage("collect")
    table.insert(row, ("%8d"):format(math.floor(vim.uv.resident_set_memory() / 1048576)))
    print(table.concat(row, " "))
end

vim.cmd("qa!")
