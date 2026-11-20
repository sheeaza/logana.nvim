-- Headless test runner, no dependencies:
--   nvim --headless -u NONE -l tests/run.lua
-- Each test runs in a fresh temp dir (rule/result files are created relative to cwd).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/logana.lua")

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
    L._prefix_counter = 0
    L.open()
    return api.nvim_get_current_buf()
end

local function set_rule(rule_buf, rg, hl)
    local lines = { "[rg]" }
    vim.list_extend(lines, rg)
    vim.list_extend(lines, { "[file]", "opened_only = true", "[highlight]" })
    vim.list_extend(lines, hl or {})
    api.nvim_buf_set_lines(rule_buf, 0, -1, false, lines)
end

-- refreshes and returns how many rg processes were spawned
local function refresh(rule_buf, force)
    rg_calls = 0
    L.refresh(rule_buf, { force = force })
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
            for _, m in ipairs(hls[level][row - 1] or {}) do
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

test("force reruns level 1 and 2", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    refresh(rule)
    eq(2, refresh(rule, true), "rg calls")
end)

test("level 2 columns are right with multibyte text and ':' in lines", function()
    local rule = setup_session()
    vim.fn.writefile({ "日本: resource a:b busy", "x resource 日本 busy" }, "a.log")
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'", "-e 'a:b'" })
    refresh(rule, true)
    eq({
        "match:1:resource", "hl:1:busy:1", "hl:1:a:b:2",
        "match:2:resource", "hl:2:busy:1",
    }, highlighted())
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
