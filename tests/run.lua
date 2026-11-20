-- Headless test runner, no dependencies:
--   nvim --headless -u NONE -l tests/run.lua
-- Each test runs in a fresh temp dir (rule/result files are created relative to cwd).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
-- -u NONE leaves filetype detection off, rule buffers are found by filetype
vim.cmd("filetype on")

local api = vim.api
local L = require("logana")
L.setup({})

local orig_system = vim.system
local rg_calls = 0
vim.system = function(...)
    rg_calls = rg_calls + 1
    return orig_system(...)
end

local LOG = {
    "cam ERROR resource busy",
    "foo hardware ok",
    "resource Timeout retry",
    "nothing here",
}

local function setup_session()
    vim.cmd("silent! %bwipeout!")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.chdir(dir)
    vim.fn.writefile(LOG, "a.log")
    vim.cmd("edit a.log")
    vim.cmd("vsplit 0.logana_rule")
    return api.nvim_get_current_buf()
end

local function set_rule(rule_buf, rg, hl, opened_only)
    local lines = { "[rg]" }
    vim.list_extend(lines, rg)
    vim.list_extend(lines, { "[file]", "opened_only = " .. tostring(opened_only ~= false), "[highlight]" })
    vim.list_extend(lines, hl or {})
    api.nvim_buf_set_lines(rule_buf, 0, -1, false, lines)
end

-- refreshes (same as <Enter> in the rule buffer), waits for the results to
-- load, and returns how many rg processes were spawned
local function refresh(rule_buf)
    rg_calls = 0
    L.refresh(rule_buf)
    vim.wait(5000, function() return not L._busy(rule_buf) end, 1)
    return rg_calls
end

local function result_buf()
    return vim.fn.bufnr("0.logana_result")
end

local function result_lines()
    return api.nvim_buf_get_lines(result_buf(), 0, -1, false)
end

-- returns { "<level>:<row>:<text>[:<hl_idx>]", ... } for the result buffer
local function highlighted()
    local rb = result_buf()
    local hls = L._result_highlights[rb]
    local out = {}
    for row, line in ipairs(result_lines()) do
        for _, level in ipairs({ "match", "hl" }) do
            local marks = level == "match" and L._match_ranges(rb, row - 1) or hls.hl[row - 1]
            for _, m in ipairs(marks or {}) do
                local s = ("%s:%d:%s"):format(level, row - 1, line:sub(m[1] + 1, m[2]))
                table.insert(out, m[3] and (s .. ":" .. m[3]) or s)
            end
        end
    end
    return out
end

local tests = {}
local function test(name, f)
    table.insert(tests, { name = name, f = f })
end

local function eq(expected, actual, what)
    if not vim.deep_equal(expected, actual) then
        error(("%s\n  expected: %s\n  actual:   %s"):format(what or "mismatch",
            vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

test("opening a new rule file fills the template, outside undo history", function()
    setup_session()
    local rule = api.nvim_get_current_buf()
    eq(vim.split(L.config.rule_template, "\n"), api.nvim_buf_get_lines(rule, 0, -1, false), "template")
    eq("--smart-case", api.nvim_get_current_line(), "cursor on the last [rg] line")
    vim.cmd("silent! undo")
    eq(vim.split(L.config.rule_template, "\n"), api.nvim_buf_get_lines(rule, 0, -1, false), "after undo")
end)

test("opening an existing rule file keeps its content", function()
    setup_session()
    vim.fn.writefile({ "[rg]", "-e 'busy'" }, "saved.logana_rule")
    vim.cmd("edit saved.logana_rule")
    eq({ "[rg]", "-e 'busy'" }, api.nvim_buf_get_lines(0, 0, -1, false))
end)

test("refresh opens the result window, also after it was closed", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" })
    eq(-1, vim.fn.bufwinid("0.logana_result"), "not shown before the first refresh")
    refresh(rule)
    local win = vim.fn.bufwinid(result_buf())
    eq(true, win ~= -1, "shown after refresh")
    api.nvim_win_close(win, true)
    refresh(rule)
    eq(true, vim.fn.bufwinid(result_buf()) ~= -1, "shown again")
end)

test("result buffer sits next to a rule file opened from another directory", function()
    setup_session()
    vim.fn.mkdir("sub", "p")
    vim.cmd("edit sub/x.logana_rule")
    local rule = api.nvim_get_current_buf()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    local rb = vim.fn.bufnr(vim.fn.fnamemodify("sub/x.logana_result", ":p"))
    eq(true, rb ~= -1, "result named next to the rule file")
    eq(0, refresh(rule), "found again, nothing reruns")
end)

test("level 1 lists matched lines with one shared color", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'", "-e 'hardware'" })
    eq(1, refresh(rule), "rg calls")
    eq({ "file: a.log", "1: cam ERROR resource busy", "2: foo hardware ok", "3: resource Timeout retry", "" },
        result_lines())
    eq({ "match:1:resource", "match:2:hardware", "match:3:resource" }, highlighted())
end)

test("level 2 colors each [highlight] line separately, using rg syntax", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-i -e 'error'", "-e 'retry' -e 'busy'" })
    refresh(rule)
    eq({
        "match:1:resource", "hl:1:ERROR:1", "hl:1:busy:2",
        "match:2:resource", "hl:2:retry:2",
    }, highlighted())
end)

test("[highlight] flag-only lines apply to every rule, without taking a color", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e 'error'", "--smart-case", "-e 'Retry'", "-e 'retry'" })
    eq(4, refresh(rule), "rg calls")   -- level 1 + 3 highlight rules
    eq({
        "match:1:resource", "hl:1:ERROR:1",
        "match:2:resource", "hl:2:retry:3",
    }, highlighted())
end)

test("a [highlight] rule's own flags override the shared ones", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-i", "-s -e 'error'", "-e 'timeout'" })
    refresh(rule)
    eq({ "match:1:resource", "match:2:resource", "hl:2:Timeout:2" }, highlighted())
end)

test("rule window gets layout.rule_window percent of the rule/result split", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    local rule_win = vim.fn.bufwinid(rule)
    local result_win = vim.fn.bufwinid(result_buf())
    local total = api.nvim_win_get_height(rule_win) + api.nvim_win_get_height(result_win) + 1
    eq(math.floor(total * tonumber(L.config.layout.rule_window) / 100), api.nvim_win_get_height(rule_win))
end)

-- session searching a.log and b.log; returns the rule bufnr
local function setup_two_files()
    local rule = setup_session()
    vim.fn.writefile(LOG, "b.log")
    vim.fn.bufload(vim.fn.bufadd("b.log"))
    return rule
end

-- { [file] = true } for files whose fold is closed in the result window
local function folded_files()
    local out = {}
    local win = vim.fn.bufwinid(result_buf())
    api.nvim_win_call(win, function()
        for lnum, line in ipairs(result_lines()) do
            local file = line:match("^file: (.*)")
            if file and vim.fn.foldclosed(lnum) ~= -1 then
                out[file] = true
            end
        end
    end)
    return out
end

local function close_fold(file)
    local win = vim.fn.bufwinid(result_buf())
    for lnum, line in ipairs(result_lines()) do
        if line == "file: " .. file then
            api.nvim_win_call(win, function() vim.cmd(lnum .. "foldclose") end)
        end
    end
end

local function fold_section(rule_buf)
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local i = vim.fn.index(lines, "[fold]")
    return i == -1 and nil or vim.list_slice(lines, i + 2)
end

test("result buffer folds by file; folds are saved to [fold] and survive a rerender", function()
    local rule = setup_two_files()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    eq(2, #vim.tbl_filter(function(l) return l:match("^file: ") end, result_lines()), "file headers")
    eq({}, folded_files(), "all open after first render")
    close_fold("a.log")
    eq({ ["a.log"] = true }, folded_files(), "fold covers one file")
    set_rule(rule, { "-e 'resource'", "-e 'hardware'" })
    eq(1, refresh(rule), "level 1 reran")
    eq({ "a.log" }, fold_section(rule), "[fold] section")
    eq({ ["a.log"] = true }, folded_files(), "fold restored")
end)

test("editing [fold] by hand applies it without rerunning rg", function()
    local rule = setup_two_files()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    close_fold("a.log")
    refresh(rule)
    eq({ "a.log" }, fold_section(rule), "saved on refresh")
    local n = api.nvim_buf_line_count(rule)
    api.nvim_buf_set_lines(rule, n - 1, n, false, { "b.log" })
    eq(0, refresh(rule), "rg calls")
    eq({ ["b.log"] = true }, folded_files(), "rule wins")
end)

test("leaving the result window saves its folds", function()
    local rule = setup_two_files()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    api.nvim_set_current_win(vim.fn.bufwinid(result_buf()))
    vim.cmd("1foldclose")
    api.nvim_set_current_win(vim.fn.bufwinid(rule))
    eq(1, #fold_section(rule), "one file saved")
end)

test("only [highlight] changed: level 1 is skipped", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'", "-e 'retry'" })
    eq(2, refresh(rule), "one rg per highlight rule")
    eq({ "match:1:resource", "hl:1:busy:1", "match:2:resource", "hl:2:retry:2" }, highlighted())
end)

test("nothing changed: no rg runs", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    refresh(rule)
    eq(0, refresh(rule), "rg calls")
end)

test("[rg] changed: both levels rerun", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    refresh(rule)
    set_rule(rule, { "-e 'hardware'" }, { "-e 'busy'" })
    eq(2, refresh(rule), "rg calls")
    eq({ "match:1:hardware" }, highlighted())
end)

test("searched file changed on disk: level 1 reruns", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    vim.fn.writefile({ "resource appended" }, "a.log", "a")
    eq(1, refresh(rule), "rg calls")
    eq("5: resource appended", result_lines()[4])
end)

test("result buffer edited: level 1 reruns; :w alone does not", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    api.nvim_buf_call(result_buf(), function() vim.cmd("silent write") end)
    eq(0, refresh(rule), "rg calls after :w")
    api.nvim_buf_set_lines(result_buf(), 0, 1, false, { "edited" })
    eq(1, refresh(rule), "rg calls after edit")
    eq("file: a.log", result_lines()[1])
end)

test("opened_only = false: nothing changed reruns level 1, [highlight] change only level 2", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" }, false)
    eq(2, refresh(rule), "first refresh")
    eq(2, refresh(rule), "nothing changed: cwd files may have, rerun both")
    set_rule(rule, { "-e 'resource'" }, { "-e 'retry'" }, false)
    eq(1, refresh(rule), "only [highlight] changed")
end)

test("level 2 columns are right with multibyte text and ':' in lines", function()
    local rule = setup_session()
    vim.fn.writefile({ "日本: resource a:b busy", "x resource 日本 busy" }, "a.log")
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'", "-e 'a:b'" })
    refresh(rule)
    eq({
        "match:1:resource", "hl:1:busy:1", "hl:1:a:b:2",
        "match:2:resource", "hl:2:busy:1",
    }, highlighted())
end)

test("level 1 columns are right with several matches per line and multibyte text", function()
    local rule = setup_session()
    vim.fn.writefile({ "日本 busy x busy", "busy" }, "a.log")
    set_rule(rule, { "-e 'busy'", "-e '日本'" })
    refresh(rule)
    eq({ "match:1:日本", "match:1:busy", "match:1:busy", "match:2:busy" }, highlighted())
end)

test("level 1 skips -A/-B context lines and keeps lines that aren't utf-8", function()
    local rule = setup_session()
    vim.fn.writefile({ "before", "\255 busy", "after" }, "a.log")
    set_rule(rule, { "-A 1", "-B 1", "-e 'busy'" })
    refresh(rule)
    eq({ "file: a.log", "2: \255 busy", "" }, result_lines())
    eq({ "match:1:busy" }, highlighted())
end)

-- a log big enough that level 1 output arrives in many batches
local function write_big_log(n)
    local lines = {}
    for i = 1, n do
        lines[i] = ("%d resource line padded to be long enough %s busy"):format(i, ("x"):rep(40))
    end
    vim.fn.writefile(lines, "a.log")
end

test("level 1 streamed in batches lists every line once, with highlights on late rows", function()
    local rule = setup_session()
    write_big_log(60000) -- ~6 MB of output
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    refresh(rule)
    local lines = result_lines()
    eq(60000 + 2, #lines, "line count")
    eq("file: a.log", lines[1])
    for i = 1, 60000 do
        if not vim.startswith(lines[i + 1], i .. ": " .. i .. " resource") then
            eq(i .. ": " .. i .. " resource ...", lines[i + 1], "row " .. i)
        end
    end
    eq("", lines[#lines])
    local hls = L._result_highlights[result_buf()]
    local last = #lines - 2 -- 0-based row of the last match line
    local m = L._match_ranges(result_buf(), last)[1]
    eq("resource", lines[last + 1]:sub(m[1] + 1, m[2]))
    local h = hls.hl[last][1]
    eq("busy", lines[last + 1]:sub(h[1] + 1, h[2]))
end)

test("[rg] changed while loading: the old run is dropped", function()
    local rule = setup_session()
    write_big_log(60000)
    set_rule(rule, { "-e 'resource'" })
    L.refresh(rule)
    eq(true, L._busy(rule), "busy")
    set_rule(rule, { "-e '^7 resource'" })
    refresh(rule)
    eq({ "file: a.log", "7: 7 resource line padded to be long enough " .. ("x"):rep(40) .. " busy", "" },
        result_lines())
end)

test("only [highlight] changed while loading: the run goes on and uses the new rules", function()
    local rule = setup_session()
    write_big_log(60000)
    set_rule(rule, { "-e 'resource'" }, { "-e 'nothing'" })
    rg_calls = 0
    L.refresh(rule)
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    L.refresh(rule)
    vim.wait(5000, function() return not L._busy(rule) end, 1)
    eq(2, rg_calls, "rg calls") -- one level 1 run, one level 2 rule
    eq(60000 + 2, #result_lines(), "line count")
    local h = L._result_highlights[result_buf()].hl[1][1]
    eq("busy", result_lines()[2]:sub(h[1] + 1, h[2]))
end)

test("context lines don't make level 1 parsing slow", function()
    local rule = setup_session()
    local lines = {}
    for i = 1, 3000 do
        lines[i] = (i % 3 == 0 and "busy " or "ctx ") .. ("x"):rep(2000)
    end
    vim.fn.writefile(lines, "a.log")
    set_rule(rule, { "-C 1", "-e 'busy'" })
    local t = vim.uv.hrtime()
    refresh(rule)
    eq(1000 + 2, #result_lines(), "line count")
    -- unanchored, the 2000 context lines of 2000 bytes took seconds
    eq(true, (vim.uv.hrtime() - t) / 1e6 < 500, "fast")
end)

test("a spinner float shows on the rule window's last line while loading, then closes", function()
    local rule = setup_session()
    write_big_log(60000)
    set_rule(rule, { "-e 'resource'" })
    local win = api.nvim_get_current_win()
    vim.wo[win].statusline = "%f%=%l"
    local function spinners()
        local out = {}
        for _, w in ipairs(api.nvim_list_wins()) do
            local c = api.nvim_win_get_config(w)
            if c.relative == "win" and c.win == win then
                table.insert(out, w)
            end
        end
        return out
    end
    L.refresh(rule)
    local floats = spinners()
    eq(1, #floats, "one float while loading")
    local c = api.nvim_win_get_config(floats[1])
    eq(api.nvim_win_get_height(win) - 1, c.row, "on the last line, above the statusline")
    eq(api.nvim_win_get_width(win), c.col + c.width, "at its right end")
    eq(false, c.focusable, "not focusable")
    local text = vim.trim(api.nvim_buf_get_lines(api.nvim_win_get_buf(floats[1]), 0, -1, false)[1])
    eq(true, text:find("^%S+ loading %d+ lines$") ~= nil, "float text")
    eq("%f%=%l", vim.wo[win].statusline, "statusline untouched")
    vim.wait(5000, function() return not L._busy(rule) end, 1)
    eq(0, #spinners(), "float closed when done")
end)

test("invalid [highlight] pattern warns and keeps level 1", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e '(bad'", "-e 'busy'" })
    local warned = false
    local orig_notify = vim.notify
    vim.notify = function(msg) warned = warned or msg:find("highlight rule") ~= nil end
    refresh(rule)
    vim.notify = orig_notify
    eq(true, warned, "warned")
    eq({ "match:1:resource", "hl:1:busy:2", "match:2:resource" }, highlighted())
end)

local failed = 0
for _, t in ipairs(tests) do
    local ok, err = pcall(t.f)
    if ok then
        print("ok   " .. t.name)
    else
        failed = failed + 1
        print("FAIL " .. t.name .. "\n  " .. tostring(err))
    end
end
print(("%d/%d passed"):format(#tests - failed, #tests))
vim.cmd(failed == 0 and "qa!" or "cquit!")
