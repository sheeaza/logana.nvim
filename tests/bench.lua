-- Headless benchmark of one refresh (<Enter> in a rule buffer), split by phase:
--   nvim --headless -u NONE -l tests/bench.lua <log file or dir> [runs] [--xl]
--       [--save <file> | --gate <file>]
--   nvim --headless -u NONE -l tests/bench.lua --gen <MB> <log file>
-- Phase times come from the plugin's log.trace timers; each refresh is waited on
-- until its streamed results are fully loaded and its hit counts are in. Each case
-- does one warmup refresh (fills the page cache, opens the result window), then
-- reports the median of [runs] refreshes (default 3). Redraw isn't measured, there
-- is no UI attached.
-- --save writes the medians of the gated columns to a baseline file, --gate reruns
-- and exits 1 if one got slower than the baseline (see GATE). --gen writes a
-- synthetic log with the cases' patterns, for a machine without the camera log.

-- print in nvim -l doesn't end the line on every system, one line each here
local function print(s)
    io.stdout:write(s, "\n")
end

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")

local USAGE = "usage: nvim --headless -u NONE -l tests/bench.lua <log file or dir> [runs] [--xl]"
    .. " [--save <file> | --gate <file>]\n"
    .. "       nvim --headless -u NONE -l tests/bench.lua --gen <MB> <log file>\n"
local function usage()
    io.stderr:write(USAGE)
    os.exit(2)
end

local target, runs, xl, save, gate, gen_mb
do
    local args, i = _G.arg, 1
    while i <= #args do
        local a = args[i]
        if a == "--xl" then
            xl = true
        elseif a == "--save" or a == "--gate" or a == "--gen" then
            local v = args[i + 1] or usage()
            i = i + 1
            if a == "--save" then
                save = v
            elseif a == "--gate" then
                gate = v
            else
                gen_mb = tonumber(v) or usage()
            end
        elseif tonumber(a) then
            runs = tonumber(a)
        else
            target = a
        end
        i = i + 1
    end
end
if not target or (save and gate) then
    usage()
end

-- the synthetic log: lines shaped like the camera log's (~200 bytes), the cases'
-- patterns at its rates. a fixed seed, so every machine gets the same file
local function gen_log(path, mb)
    local x = 2463534242 -- xorshift32
    local function rand()
        x = bit.bxor(x, bit.lshift(x, 13))
        x = bit.bxor(x, bit.rshift(x, 17))
        x = bit.bxor(x, bit.lshift(x, 5))
        return bit.band(x, 0x7fffffff) / 2 ^ 31
    end
    local TAGS = { "Display", "Wifi", "Sensor", "Audio", "NetMgr", "PowerHal", "Camera3", "ISP_PIPE" }
    local hex = {}
    for i = 1, 256 do
        hex[i] = ("%x"):format(i % 16)
    end
    hex = table.concat(hex)
    local f = assert(io.open(path, "wb"))
    local limit, size, n, buf = mb * 1048576, 0, 0, {}
    while size < limit do
        local r = rand()
        -- small ~0.034%, medium ~5%, large ~28% of the lines, as tags
        local tag = r < 0.00034 and "ResourceReserve" or r < 0.05034 and "DRV_COMMON"
            or r < 0.33034 and "CLIENT_MGR" or TAGS[math.floor(rand() * #TAGS) + 1]
        -- --xl: 'Info  ' on ~95%
        local level = rand() < 0.95 and "Info  " or "Warn  "
        -- the [highlight] rules: 'start is' and 'stop is' ~1% each
        local m = rand()
        local msg = m < 0.01 and "start is " or m < 0.02 and "stop is " or "op "
        local t = n * 0.37
        local line = ("11-20 %02d:%02d:%06.3f %5d %5d %s %s: %s%d %s\n"):format(
            math.floor(t / 3600) % 24, math.floor(t / 60) % 60, t % 60,
            math.floor(rand() * 30000), math.floor(rand() * 30000), level, tag, msg,
            math.floor(rand() * 1000), hex:sub(1, 60 + math.floor(rand() * 140)))
        n = n + 1
        size = size + #line
        buf[#buf + 1] = line
        if #buf == 10000 then
            f:write(table.concat(buf))
            buf = {}
        end
    end
    f:write(table.concat(buf))
    f:close()
    print(("wrote %s: %d lines, %d bytes"):format(path, n, size))
end

if gen_mb then
    gen_log(target, gen_mb)
    vim.cmd("qa!")
    return
end

if not vim.uv.fs_stat(target) then
    usage()
end
target = vim.fn.fnamemodify(target, ":p")

-- --gate: the baseline, its runs unless given
local base
if gate then
    local f = io.open(gate, "rb") or error("cannot read " .. gate)
    base = vim.json.decode(f:read("*a"))
    f:close()
    runs = runs or base.runs
end
runs = runs or 3
-- a baseline is of one log: the same path and size
local size = vim.uv.fs_stat(target).size
if base and (base.target ~= target or base.size ~= size) then
    print(("baseline is of another log: %s (%s bytes)"):format(base.target, tostring(base.size)))
    vim.cmd("cquit 2")
end

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
    -- large with [highlight] rules matching every line: 'Info' once on most, digits
    -- many times on each, for the level 2 and hit count costs that grow with matches
    { name = "broad", rg = { "-F", "-e 'CLIENT_MGR'" }, hl = { "-e 'Info'", "-e '[0-9]+'" } },
}
if xl then
    table.insert(CASES, { name = "xl", rg = { "-F", "-e 'Info  '" } }) -- ~2.5M
end

-- order of the columns, in the order they run
-- level 1 is streamed: first = until the first lines are in the buffer,
-- parse/set_lines = summed over its batches, max_batch = longest the UI was blocked.
-- level 2 is lazy: hl = coloring the rows on one screen (headless: 24 lines), after it
local PHASES = {
    { "first lines", "first" },
    { "parse rg output", "parse" },
    { "set lines", "set_lines" },
    { "max batch", "max_batch" },
    { "level 1", "level1" },
    { "highlight rows", "hl" },
    { "save_folds", "save_fold" },
    { "restore_folds", "rest_fold" },
    { "refresh", "total" },
    -- timed here, not by the plugin: from the refresh until the hit counts are in
    { "count", "count" },
}

-- the columns --gate checks, against the baseline: slower if over it by more than
-- both pct and abs (ms; rss in MB)
local GATE = {
    { "first", 0.15, 10 }, { "max_batch", 0.15, 10 }, { "level1", 0.15, 10 },
    { "total", 0.15, 10 }, { "count", 0.15, 10 }, { "rss_MB", 0.15, 10 },
}

local function refresh(rule)
    local t0 = vim.uv.hrtime()
    L.refresh(rule)
    vim.wait(600000, function() return not L._busy(rule) end, 1)
    -- drawing asks for level 2 of the rows on screen
    vim.cmd("redraw")
    local hls = L._result_highlights[vim.fn.bufnr("0.logana_result")]
    vim.wait(600000, function() return not hls or hls.pending == 0 end, 1)
    -- also so the next refresh doesn't stop them midway
    vim.wait(600000, function() return not L._counting(rule) end, 1)
    if samples then
        samples.count = samples.count or {}
        table.insert(samples.count, math.floor((vim.uv.hrtime() - t0) / 1e6))
    end
end

local function median(t)
    if not t or #t == 0 then
        return nil
    end
    local s = vim.list_slice(t)
    table.sort(s)
    return s[math.ceil(#s / 2)]
end

local function set_rule(rule_buf, rg, hl)
    local lines = { "[rg]" }
    vim.list_extend(lines, rg)
    -- the target goes after the patterns, as an rg path argument
    table.insert(lines, vim.fn.shellescape(target))
    vim.list_extend(lines, { "[file]", "opened_only = false", "[highlight]" })
    vim.list_extend(lines, hl or HL)
    api.nvim_buf_set_lines(rule_buf, 0, -1, false, lines)
end

local header = { ("%-7s"):format("case"), ("%9s"):format("res_lines") }
for _, p in ipairs(PHASES) do
    table.insert(header, ("%9s"):format(p[2]))
end
table.insert(header, ("%8s"):format("rss_MB"))
print(("target: %s, median of %d runs, ms"):format(target, runs))
print(table.concat(header, " "))

local results = {} -- [case name] = { res_lines, <column> = median }
for _, case in ipairs(CASES) do
    vim.cmd("silent! %bwipeout!")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.chdir(dir)
    vim.cmd("edit 0.logana_rule")
    local rule = api.nvim_get_current_buf()
    set_rule(rule, case.rg, case.hl)

    samples = nil
    refresh(rule) -- warmup
    samples = {}
    -- with opened_only = false and nothing changed, every refresh reruns both levels
    for _ = 1, runs do
        refresh(rule)
    end

    local rbuf = vim.fn.bufnr("0.logana_result")
    local nlines = rbuf ~= -1 and api.nvim_buf_line_count(rbuf) or 0
    local row = { ("%-7s"):format(case.name), ("%9d"):format(nlines) }
    local res = { res_lines = nlines }
    for _, p in ipairs(PHASES) do
        local m = median(samples[p[1]])
        res[p[2]] = m
        table.insert(row, ("%9s"):format(m and tostring(m) or "-"))
    end
    collectgarbage("collect")
    res.rss_MB = math.floor(vim.uv.resident_set_memory() / 1048576)
    table.insert(row, ("%8d"):format(res.rss_MB))
    print(table.concat(row, " "))
    results[case.name] = res
end

if save then
    local f = assert(io.open(save, "wb"))
    f:write(vim.json.encode({ target = target, size = size, runs = runs, cases = results }), "\n")
    f:close()
    print(("saved to %s"):format(save))
end

if gate then
    local slower = {}
    for _, case in ipairs(CASES) do
        local b, r = base.cases[case.name], results[case.name]
        if not b then
            print(("%s: not in the baseline"):format(case.name))
        elseif b.res_lines ~= r.res_lines then
            print(("%s: res_lines %d, baseline %d: not the same search"):format(case.name, r.res_lines, b.res_lines))
            vim.cmd("cquit 2")
        else
            for _, g in ipairs(GATE) do
                local col, pct, abs = g[1], g[2], g[3]
                local was, now = b[col], r[col]
                if type(was) == "number" and type(now) == "number"
                    and now > was * (1 + pct) and now - was > abs then
                    table.insert(slower, ("%s %s: %d, baseline %d (+%d%%)"):format(
                        case.name, col, now, was, math.floor((now - was) / math.max(was, 1) * 100)))
                end
            end
        end
    end
    if #slower > 0 then
        print("slower than the baseline (over by > 15% and 10 ms / 10 MB):")
        for _, s in ipairs(slower) do
            print("  " .. s)
        end
        vim.cmd("cquit 1")
    end
    print("gate passed")
end

vim.cmd("qa!")
