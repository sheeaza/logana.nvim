-- the rule buffer: its template, and its sections turned into rg args
local api = vim.api
local fn = vim.fn
local config = require('logana.config')
local LEVEL1_ARGS = require('logana.level1').ARGS
local process = require('logana.proc')

local M = {}

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

local function get_valid_opened_files()
    local files = {}
    local rule_ft = config.naming.rule
    local result_ft = config.naming.result
    for _, b in ipairs(api.nvim_list_bufs()) do
        local abs_path = api.nvim_buf_get_name(b)
        if api.nvim_buf_is_loaded(b) and abs_path ~= "" then
            if vim.uv.fs_stat(abs_path) then
                local ft = vim.bo[b].filetype
                if ft ~= rule_ft and ft ~= result_ft then
                    table.insert(files, fn.fnamemodify(abs_path, ":."))
                end
            end
        end
    end
    return files
end

local function get_runtime_opts(rule_buf)
    local args = { config.rg.cmd }
    for _, a in ipairs(config.rg.args) do
        -- output format is fixed by LEVEL1_ARGS; drop the old default from user configs
        if a ~= '--json' then
            table.insert(args, a)
        end
    end
    vim.list_extend(args, LEVEL1_ARGS)

    -- exclude rule/result files
    table.insert(args, '-g')
    table.insert(args, '!*.' .. config.naming.rule)
    table.insert(args, '-g')
    table.insert(args, '!*.' .. config.naming.result)

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
    api.nvim_buf_set_lines(rule_buf, 0, -1, false, vim.split(config.rule_template, '\n'))
    api.nvim_set_option_value('undolevels', undolevels, { buf = rule_buf })

    local rg_end = find_rg_section_end(rule_buf)
    if rg_end then
        for _, win in ipairs(fn.win_findbuf(rule_buf)) do
            pcall(api.nvim_win_set_cursor, win, { rg_end, 0 })
        end
    end
end

-- the [highlight] lines whose args are `want`, the last rule line of the section
-- (or its header), and the flag-only lines' args
local function find_highlight(rule_buf, want)
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local section, last, found, shared = '', nil, {}, {}
    for i, l in ipairs(lines) do
        local s = l:gsub("%s+$", "")
        local cur_section = s:match("^%s*%[(.+)%]%s*$")
        if cur_section then
            section = cur_section
            if section == 'highlight' then
                last = i
            end
        elseif section == 'highlight' and not s:match("^%s*$") and not s:match("^%s*#") then
            last = i
            local args = split_with_quotes(s)
            if vim.deep_equal(args, want) then
                table.insert(found, i)
            elseif not has_pattern(args) then
                vim.list_extend(shared, args)
            end
        end
    end
    return found, last, shared
end

-- removes the [highlight] lines that are exactly `-F -e '<text>'` (the text as is,
-- not a regex), or adds one at the end of the section (making it if there's none)
-- once rg accepts it with the section's flags.
-- on_done(true) when added, false when removed, nil when nothing changed (warned)
local function toggle_highlight(rule_buf, text, on_done)
    local want = { '-F', '-e', text }
    local q = text:find("'", 1, true) and '"' or "'"
    local line = '-F -e ' .. q .. text .. q
    -- the rule parser has no escapes: text with both quotes, or a '\' before the
    -- closing one, can't be written
    if not vim.deep_equal(split_with_quotes(line), want) then
        vim.notify(("[logana] can't write %s as a [highlight] line"):format(text), vim.log.levels.WARN)
        return on_done(nil)
    end

    local found, _, shared = find_highlight(rule_buf, want)
    if #found > 0 then
        for j = #found, 1, -1 do
            api.nvim_buf_set_lines(rule_buf, found[j] - 1, found[j], false, {})
        end
        return on_done(false)
    end

    -- as level 2 runs it, over no input: only the flags are checked
    local args = { config.rg.cmd, '--no-config' }
    vim.list_extend(args, shared)
    vim.list_extend(args, want)
    table.insert(args, '-')
    local ok = pcall(process.system, args, { text = true, stdin = '' }, function(res)
        vim.schedule(function()
            if res.code == 2 then
                vim.notify(("[logana] not added to [highlight], %s: %s"):format(line, res.stderr),
                    vim.log.levels.WARN)
                return on_done(nil)
            end
            if not api.nvim_buf_is_valid(rule_buf) then
                return on_done(nil)
            end
            -- the buffer may have changed meanwhile
            local _, last = find_highlight(rule_buf, want)
            if last then
                api.nvim_buf_set_lines(rule_buf, last, last, false, { line })
            else
                api.nvim_buf_set_lines(rule_buf, -1, -1, false, { '', '[highlight]', line })
            end
            on_done(true)
        end)
    end)
    if not ok then
        vim.notify("[logana] failed to execute ripgrep", vim.log.levels.WARN)
        on_done(nil)
    end
end

M.get_runtime_opts = get_runtime_opts
M.toggle_highlight = toggle_highlight
M.initialize_rule_buffer = initialize_rule_buffer
return M
