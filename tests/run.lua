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

local process = require("logana.proc")
local orig_system = process.system
local rg_calls, level1_calls, count_calls = 0, 0, 0
process.system = function(args, ...)
    -- hit counts run apart from the levels, counted on their own
    if vim.tbl_contains(args, "--count") then
        count_calls = count_calls + 1
        return orig_system(args, ...)
    end
    rg_calls = rg_calls + 1
    if vim.tbl_contains(args, "--null") then
        level1_calls = level1_calls + 1
    end
    return orig_system(args, ...)
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

-- waits for the hit counts, returns { [1-based rule buffer line] = "<count>" }
local function counts(rule_buf)
    vim.wait(5000, function() return not L._counting(rule_buf) end, 1)
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(rule_buf, L._count_ns, 0, -1, { details = true })) do
        if not m[4].invalid then
            out[m[2] + 1] = vim.trim(m[4].virt_text[1][1])
        end
    end
    return out
end

local function result_buf()
    return vim.fn.bufnr("0.logana_result")
end

local function result_lines()
    return api.nvim_buf_get_lines(result_buf(), 0, -1, false)
end

-- draws the screen, which asks for level 2 of the rows on it, and waits for it
local function draw()
    vim.cmd("redraw")
    local hls = L._result_highlights[result_buf()]
    vim.wait(5000, function() return hls.pending == 0 end, 1)
end

-- returns { "<level>:<row>:<text>[:<hl_idx>]", ... } for the result buffer
-- (level 2 for the rows on screen)
local function highlighted()
    draw()
    local rb = result_buf()
    local hls = L._result_highlights[rb]
    local out = {}
    for row, line in ipairs(result_lines()) do
        for _, level in ipairs({ "match", "hl" }) do
            local marks
            if level == "match" then
                marks = L._match_ranges(rb, row - 1)
            else
                marks = hls.hl[row - 1]
            end
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

test("default colors are fixed and survive :colorscheme", function()
    local function hl(name) return api.nvim_get_hl(0, { name = name }) end
    eq(0xffd75f, hl("LoganaHighlight1").bg, "LoganaHighlight1 bg")
    eq(10, #L.config.hi_group_names, "10 level 2 groups")
    vim.cmd("colorscheme default")
    eq(0x8a8a8a, hl("LoganaMatch").bg, "LoganaMatch bg after :colorscheme")
    eq(0x000000, hl("LoganaHighlight10").fg, "LoganaHighlight10 fg after :colorscheme")
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
    eq(1, refresh(rule), "rg calls")   -- level 1, level 2 runs when drawn
    eq({
        "match:1:resource", "hl:1:ERROR:1",
        "match:2:resource", "hl:2:retry:3",
    }, highlighted())
    eq(4, rg_calls, "rg calls with level 2")   -- + 3 highlight rules
end)

test("a [highlight] rule's own flags override the shared ones", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-i", "-s -e 'error'", "-e 'timeout'" })
    refresh(rule)
    eq({ "match:1:resource", "match:2:resource", "hl:2:Timeout:2" }, highlighted())
end)

-- in the result window: select `keys` from (row, col) (1-based row, 0-based col),
-- press <Enter>, and wait for [highlight] to change (adding waits on rg) and the
-- refresh it starts, or for `done()`
local function toggle_selection(rule, row, col, keys, done)
    local tick = api.nvim_buf_get_changedtick(rule)
    api.nvim_set_current_win(vim.fn.bufwinid(result_buf()))
    api.nvim_win_set_cursor(0, { row, col })
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys .. "<CR>", true, false, true), "mx", false)
    vim.wait(5000, done or function() return api.nvim_buf_get_changedtick(rule) ~= tick end, 1)
    vim.wait(5000, function() return not L._busy(rule) end, 1)
end

local function hl_section(rule)
    local lines = api.nvim_buf_get_lines(rule, 0, -1, false)
    local i = vim.fn.index(lines, "[highlight]")
    return vim.list_slice(lines, i + 2)
end

-- rule.toggle_highlight, waited for; returns what it passed to on_done
local function toggle(rule, text)
    local res = "pending"
    require("logana.rule").toggle_highlight(rule, text, function(changed) res = changed end)
    vim.wait(5000, function() return res ~= "pending" end, 1)
    return res
end

-- runs f, returns the messages vim.notify got meanwhile
local function notified(f)
    local msgs = {}
    local orig_notify = vim.notify
    vim.notify = function(msg) table.insert(msgs, msg) end
    local ok, err = pcall(f)
    vim.notify = orig_notify
    assert(ok, err)
    return msgs
end

test("visual <Enter> in the result adds the selection to [highlight], again removes it", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "--smart-case" })
    refresh(rule)
    toggle_selection(rule, 2, 7, "v4l")   -- "1: cam ERROR ..."
    eq({ "--smart-case", "-F -e 'ERROR'" }, hl_section(rule))
    eq({ "match:1:resource", "hl:1:ERROR:1", "match:2:resource" }, highlighted())
    toggle_selection(rule, 2, 7, "v4l")
    eq({ "--smart-case" }, hl_section(rule))
    eq({ "match:1:resource", "match:2:resource" }, highlighted())
    eq("n", api.nvim_get_mode().mode, "mode")
end)

test("visual <Enter> over several lines only shows a message", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    refresh(rule)
    local msgs = notified(function()
        toggle_selection(rule, 2, 7, "vj", function() return true end)
    end)
    eq({ "[logana] only single line selections are supported" }, msgs)
    eq({ "-e 'busy'" }, hl_section(rule))
end)

test("toggling [highlight]: only exact lines are removed, the template's section used", function()
    local rule = setup_session()   -- filled with the template
    eq(true, toggle(rule, "it's"))
    eq(true, toggle(rule, [=[[]()\w2409]=]))
    local lines = api.nvim_buf_get_lines(rule, 0, -1, false)
    local i = vim.fn.index(lines, "[highlight]")
    eq({ "[highlight]", "--smart-case", [[-F -e "it's"]], [=[-F -e '[]()\w2409']=], "" },
        vim.list_slice(lines, i + 1, i + 5))
    api.nvim_buf_set_lines(rule, i + 1, i + 1, false, { "-e 'busy'" })
    eq(true, toggle(rule, "busy"))     -- not the same rule
    eq(false, toggle(rule, "busy"))
    eq(false, toggle(rule, "it's"))
    lines = api.nvim_buf_get_lines(rule, 0, -1, false)
    eq({ "[highlight]", "-e 'busy'", "--smart-case", [=[-F -e '[]()\w2409']=], "" },
        vim.list_slice(lines, i + 1, i + 5))
end)

test("a selection with regex characters and quotes is matched as is", function()
    local rule = setup_session()
    vim.fn.writefile({ "it's (busy) [1]" }, "a.log")
    vim.cmd("checktime")
    set_rule(rule, { "-e 'busy'" })
    refresh(rule)
    toggle_selection(rule, 2, 3, "v3l")   -- "1: it's (busy) [1]"
    toggle_selection(rule, 2, 8, "v5l")
    toggle_selection(rule, 2, 15, "v2l")
    eq({ [[-F -e "it's"]], "-F -e '(busy)'", "-F -e '[1]'" }, hl_section(rule))
    eq({ "match:1:busy", "hl:1:it's:1", "hl:1:(busy):2", "hl:1:[1]:3" }, highlighted())
end)

test("toggling [highlight] warns and adds nothing when the line can't be written or rg rejects it", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "--smart-case" })
    local msgs = notified(function()
        eq(nil, toggle(rule, [[it's "b"]]))   -- both quotes
        eq(nil, toggle(rule, "a\\"))         -- would escape the closing quote
    end)
    eq(2, #msgs, "warnings")
    set_rule(rule, { "-e 'resource'" }, { "--no-such-flag" })
    msgs = notified(function() eq(nil, toggle(rule, "busy")) end)
    eq(1, #msgs, "warnings")
    assert(msgs[1]:find("no-such-flag", 1, true), msgs[1])
    eq({ "--no-such-flag" }, hl_section(rule))
end)

test("toggling [highlight] adds the section when there's none", function()
    local rule = setup_session()
    api.nvim_buf_set_lines(rule, 0, -1, false, { "[rg]", "-e 'resource'" })
    toggle(rule, "busy")
    eq({ "[rg]", "-e 'resource'", "", "[highlight]", "-F -e 'busy'" }, api.nvim_buf_get_lines(rule, 0, -1, false))
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
test("hit counts: each [rg] -e line and colored [highlight] line, over the result lines", function()
    local rule = setup_session()
    -- lines: 1 [rg], 2-5, 6 [file], 7, 8 [highlight], 9-12. flag-only lines are
    -- shared, the -g isn't counted
    set_rule(rule, { "-i", "-e 'RESOURCE'", "-e 'hardware'", "-g '*.log'" },
        { "-i", "-e 'RESOURCE'", "-e 'busy' -e 'retry'", "-e 'nomatch'" })
    count_calls = 0
    refresh(rule)
    eq({ [3] = "2", [4] = "1", [10] = "2", [11] = "2", [12] = "0" }, counts(rule))
    eq(5, count_calls, "one rg per counted rule")
end)

test("hit counts: a [highlight] change recounts only [highlight], marks follow edits", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    refresh(rule)
    eq({ [2] = "2", [6] = "1" }, counts(rule))
    api.nvim_buf_set_lines(rule, 0, 0, false, { "# a comment" })
    api.nvim_buf_set_lines(rule, -2, -1, false, { "-e 'r'" })
    count_calls = 0
    eq(0, refresh(rule), "level 1 skipped")
    eq({ [3] = "2", [7] = "2" }, counts(rule))
    eq(1, count_calls, "only [highlight] recounted")
    count_calls = 0
    refresh(rule)
    eq(0, count_calls, "nothing changed: no recount")
end)

test("hit counts cover every result line, also of a streamed level 1", function()
    local rule = setup_session()
    local lines = {}
    for i = 1, 200000 do
        lines[i] = i % 2 == 0 and ("line %d even resource"):format(i) or ("line %d odd resource"):format(i)
    end
    vim.fn.writefile(lines, "a.log")
    vim.cmd("checktime")
    set_rule(rule, { "-e 'resource'" }, { "-e 'even'", "-e '^line'" })
    refresh(rule)
    eq({ [2] = "200000", [6] = "100000", [7] = "200000" }, counts(rule))
end)

test("hit counts: hit_count = false shows none", function()
    local rule = setup_session()
    L.config.hit_count = false
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    count_calls = 0
    local ok, err = pcall(function()
        refresh(rule)
        eq({}, counts(rule))
        eq(0, count_calls, "no count runs")
    end)
    L.config.hit_count = true
    assert(ok, err)
end)

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
    eq(0, refresh(rule), "rg calls")
    eq({ "match:1:resource", "hl:1:busy:1", "match:2:resource", "hl:2:retry:2" }, highlighted())
    eq(2, rg_calls, "one rg per highlight rule when drawn")
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
    eq(1, refresh(rule), "rg calls")
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
    eq(1, refresh(rule), "first refresh")
    eq(1, refresh(rule), "nothing changed: cwd files may have, rerun level 1")
    set_rule(rule, { "-e 'resource'" }, { "-e 'retry'" }, false)
    eq(0, refresh(rule), "only [highlight] changed")
    eq({ "match:1:resource", "match:2:resource", "hl:2:retry:1" }, highlighted())
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

test("with -v, level 1 lists the lines without colors and level 2 still colors them", function()
    local rule = setup_session()
    vim.fn.writefile({ "keep busy", "drop resource", "keep: 日本 busy" }, "a.log")
    set_rule(rule, { "-v", "-e 'resource'" }, { "-e 'busy'" })
    refresh(rule)
    local lines = result_lines()
    eq({ "1: keep busy", "3: keep: 日本 busy" }, { lines[2], lines[3] })
    eq({ "hl:1:busy:1", "hl:2:busy:1" }, highlighted())
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
    draw()
    eq(nil, hls.hl[last], "level 2 only for rows drawn")
    local win = vim.fn.bufwinid(result_buf())
    api.nvim_win_call(win, function() vim.cmd("normal! G") end)
    draw()
    local h = hls.hl[last][1]
    eq("busy", lines[last + 1]:sub(h[1] + 1, h[2]))
    eq(nil, hls.hl[30000], "nor for rows scrolled past")
end)

test("rows on screen get level 2 while level 1 is still loading", function()
    local rule = setup_session()
    write_big_log(60000)
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    -- drawn right after the first write, from a callback queued before the next
    -- batch. not from vim.wait's condition: once rg is ahead of the scan, the
    -- batches run back to back and vim.wait only checks it after the last one
    local scan = require("logana.scan")
    local orig_read = scan.read_scanned
    local loading
    scan.read_scanned = function(...)
        scan.read_scanned = orig_read
        orig_read(...)
        vim.schedule(function()
            loading = L._busy(rule)
            vim.cmd("redraw")
        end)
    end
    L.refresh(rule)
    vim.wait(5000, function() return loading ~= nil end, 1)
    scan.read_scanned = orig_read
    eq(true, loading, "drawn while loading")
    local hls = L._result_highlights[result_buf()]
    vim.wait(5000, function() return hls.pending == 0 end, 1)
    local h = hls.hl[1][1]
    eq("busy", result_lines()[2]:sub(h[1] + 1, h[2]))
    vim.wait(5000, function() return not L._busy(rule) end, 1)
    eq(h, L._result_highlights[result_buf()].hl[1][1], "kept when loading is done")
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
    level1_calls = 0
    L.refresh(rule)
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    L.refresh(rule)
    vim.wait(5000, function() return not L._busy(rule) end, 1)
    eq(1, level1_calls, "level 1 runs")
    eq(60000 + 2, #result_lines(), "line count")
    draw()
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
    local warned = 0
    local orig_notify = vim.notify
    vim.notify = function(msg) warned = warned + (msg:find("highlight rule") and 1 or 0) end
    refresh(rule)
    local hl = highlighted()
    vim.notify = orig_notify
    eq(1, warned, "warned")
    eq({ "match:1:resource", "hl:1:busy:2", "match:2:resource" }, hl)
end)

test("loading keeps the cursor and view of a window on the result buffer", function()
    local rule = setup_session()
    write_big_log(60000)
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    local win = vim.fn.bufwinid(result_buf())
    api.nvim_win_set_cursor(win, { 5, 3 })
    set_rule(rule, { "-e 'resource'", "-e 'nothing'" })
    refresh(rule)
    eq({ 5, 3 }, api.nvim_win_get_cursor(win), "cursor")
    eq(1, vim.fn.line("w0", win), "top line")
    eq(false, vim.bo[result_buf()].binary, "'binary' untouched")
end)

test("an invalid [highlight] pattern warns once, not on every scroll", function()
    local rule = setup_session()
    write_big_log(60000)
    set_rule(rule, { "-e 'resource'" }, { "-e '(bad'" })
    local warned = 0
    local orig_notify = vim.notify
    vim.notify = function(msg) warned = warned + (msg:find("highlight rule") and 1 or 0) end
    refresh(rule)
    draw()
    api.nvim_win_call(vim.fn.bufwinid(result_buf()), function() vim.cmd("normal! G") end)
    draw()
    vim.notify = orig_notify
    eq(1, warned, "warnings")
end)

test("wiping a result buffer frees its highlights", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" })
    refresh(rule)
    local rb = result_buf()
    eq(true, L._result_highlights[rb] ~= nil, "kept while it exists")
    vim.cmd("bwipeout! " .. rb)
    eq(nil, L._result_highlights[rb], "freed")
    eq(1, refresh(rule), "a refresh after it reruns level 1")
    eq("file: a.log", result_lines()[1])
end)

test("wiping the rule buffer while loading stops the run", function()
    local rule = setup_session()
    write_big_log(60000)
    set_rule(rule, { "-e 'resource'" })
    L.refresh(rule)
    eq(true, L._busy(rule), "busy")
    local errors = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.ERROR then table.insert(errors, msg) end end
    vim.cmd("bwipeout! " .. rule)
    eq(false, L._busy(rule), "stopped")
    local n = api.nvim_buf_line_count(result_buf())
    vim.wait(300, function() return false end, 10)
    vim.notify = orig_notify
    eq(n, api.nvim_buf_line_count(result_buf()), "nothing appended after")
    eq({}, errors, "errors")
end)

local failed, total = 0, 0
for _, t in ipairs(tests) do
    total = total + 1
    local ok, err = pcall(t.f)
    if ok then
        print("ok   " .. t.name)
    else
        failed = failed + 1
        print("FAIL " .. t.name .. "\n  " .. tostring(err))
    end
end
print(("%d/%d passed"):format(total - failed, total))
vim.cmd(failed == 0 and "qa!" or "cquit!")
