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

-- rg flags that take a value as the next arg, so it isn't taken for a path
local VALUE_FLAGS = {}
for _, f in ipairs({ '-A', '-B', '-C', '-d', '-E', '-g', '-j', '-m', '-M', '-r', '-t', '-T',
    '--after-context', '--before-context', '--context', '--max-depth', '--encoding', '--glob',
    '--iglob', '--threads', '--max-count', '--max-columns', '--replace', '--type', '--type-not',
    '--type-add', '--type-clear', '--max-filesize', '--sort', '--sortr', '--path-separator',
    '--pre', '--pre-glob', '--ignore-file', '--engine', '--dfa-size-limit', '--regex-size-limit',
    '--colors', '--color', '--context-separator', '--field-context-separator',
    '--field-match-separator', '--hyperlink-format' }) do
    VALUE_FLAGS[f] = true
end

-- whether rg args give a pattern with -e/--regexp or -f/--file (positional ones
-- aren't, in [rg] they're paths once a -e is there)
local function has_explicit_pattern(args)
    for _, arg in ipairs(args) do
        if arg:match("^%-%-regexp") or arg:match("^%-%-file") or arg:match("^%-%a*[ef]") then
            return true
        end
    end
    return false
end

-- the flags of rg args, positional args (paths) dropped
local function flags_only(args)
    local out, i = {}, 1
    while i <= #args do
        local a = args[i]
        if a:match("^%-") then
            out[#out + 1] = a
            if VALUE_FLAGS[a] and args[i + 1] then
                out[#out + 1] = args[i + 1]
                i = i + 1
            end
        end
        i = i + 1
    end
    return out
end

local function parse_rule_buf(rule_buf)
    local rule = {}
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)

    local section = ''
    for lnum, line in ipairs(lines) do
        local s = line:gsub("%s+$", "")

        if s:match("^%s*$") or s:match("^%s*#") then
            -- skip comments and empty lines
        else
            local cur_section = s:match("^%s*%[(.+)%]%s*$")
            if cur_section then
                section = cur_section
                rule[section] = { lines = {}, lnums = {} }
            elseif section ~= '' then
                local m = s:match("^%s*(.*)%s*$")
                table.insert(rule[section].lines, m or s)
                table.insert(rule[section].lnums, lnum)
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
    -- hit counts: each [rg] line with a -e/-f is counted on its own, with the
    -- flags of the other lines
    local rg_shared, rg_patterns = {}, {}
    for i, line in ipairs(rule.rg.lines) do
        local args = split_with_quotes(line)
        vim.list_extend(rule.rg.cmd, args)
        if has_explicit_pattern(args) then
            table.insert(rg_patterns, { args = args, lnum = rule.rg.lnums[i] })
        else
            vim.list_extend(rg_shared, flags_only(args))
        end
    end
    rule.rg_counts = {}
    for _, r in ipairs(rg_patterns) do
        table.insert(rule.rg_counts, { args = vim.list_extend(vim.list_slice(rg_shared), r.args), lnum = r.lnum })
    end

    -- each [highlight] line with a pattern is its own rg args list, and gets its own
    -- color. lines with only flags (e.g. '--smart-case') are shared by every rule,
    -- placed first so a rule's own flags override them.
    rule.hl_rules, rule.hl_lnums = {}, {}
    if rule.highlight then
        local shared = {}
        local patterns = {}
        for i, line in ipairs(rule.highlight.lines) do
            local args = split_with_quotes(line)
            if has_pattern(args) then
                table.insert(patterns, args)
                table.insert(rule.hl_lnums, rule.highlight.lnums[i])
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

-- short rg flags whose value is the rest of the cluster or the next arg
local SHORT_VALUE = {}
for c in ('ABCdEefgjmMrtT'):gmatch('.') do
    SHORT_VALUE[c] = true
end

-- the -g/--glob/--iglob globs of rg args, in order: { glob, icase }.
-- --glob-case-insensitive makes -g globs case insensitive too
local function collect_globs(args)
    local globs, icase_all = {}, false
    local i = 1
    while i <= #args do
        local a = args[i]
        local long, val = a:match('^%-%-([%w-]+)=(.*)$')
        long = long or a:match('^%-%-([%w-]+)$')
        if long then
            if long == 'glob' or long == 'iglob' then
                if not val then
                    i = i + 1
                    val = args[i]
                end
                if val then
                    table.insert(globs, { val, long == 'iglob' })
                end
            elseif long == 'glob-case-insensitive' then
                icase_all = true
            elseif long == 'no-glob-case-insensitive' then
                icase_all = false
            elseif VALUE_FLAGS[a] then
                i = i + 1
            end
        elseif a:match('^%-[^-]') then
            -- a short cluster like '-ig' '*.log' or '-g*.log'
            for j = 2, #a do
                local c = a:sub(j, j)
                if SHORT_VALUE[c] then
                    local v = a:sub(j + 1)
                    if v == '' then
                        i = i + 1
                        v = args[i]
                    end
                    if c == 'g' and v then
                        table.insert(globs, { v, false })
                    end
                    break
                end
            end
        end
        i = i + 1
    end
    for _, g in ipairs(globs) do
        g[2] = g[2] or icase_all
    end
    return globs
end

-- an rg glob as a matcher of cwd relative paths, gitignore style: a glob without
-- '/' matches a name in any directory, one with '/' the path from cwd ('/' in
-- front anchors it, as rg), one ending in '/' only dirs
local function glob_matcher(glob, icase)
    local neg = glob:sub(1, 1) == '!'
    if neg then
        glob = glob:sub(2)
    end
    local dir_only = glob:sub(-1) == '/'
    if dir_only then
        glob = glob:sub(1, -2)
    end
    if not glob:find('/') then
        glob = '**/' .. glob
    end
    glob = glob:gsub('^/', '')
    local ok, pat = pcall(vim.glob.to_lpeg, icase and glob:lower() or glob)
    if not ok then
        return nil
    end
    return {
        neg = neg,
        match = function(path, is_dir)
            return (is_dir or not dir_only) and pat:match(icase and path:lower() or path) ~= nil
        end,
    }
end

-- whether the last glob matching path is a '!' one (nil: none matches)
local function last_match_neg(matchers, path, is_dir)
    for k = #matchers, 1, -1 do
        if matchers[k].match(path, is_dir) then
            return matchers[k].neg
        end
    end
    return nil
end

-- the files rg would search with these globs had it found them walking cwd
-- (rg doesn't apply -g to paths it's given). as rg: a dir whose last matching
-- glob is a '!' one is skipped with all under it; then the last glob matching
-- the file decides, and with any non '!' glob a file matching none is dropped.
-- a non '!' glob matching a dir doesn't take the files under it
local function filter_by_globs(files, args)
    local matchers, any_pos = {}, false
    for _, g in ipairs(collect_globs(args)) do
        local m = glob_matcher(g[1], g[2])
        if m then
            table.insert(matchers, m)
            any_pos = any_pos or not m.neg
        end
    end
    if #matchers == 0 then
        return files
    end
    local out = {}
    for _, f in ipairs(files) do
        local path = f:gsub('\\', '/'):gsub('^%./', '')
        local keep = true
        local from = 1
        while keep do
            local slash = path:find('/', from, true)
            if not slash then
                break
            end
            if slash > 1 and last_match_neg(matchers, path:sub(1, slash - 1), true) then
                keep = false
            end
            from = slash + 1
        end
        if keep then
            local neg = last_match_neg(matchers, path, false)
            if neg == nil then
                keep = not any_pos
            else
                keep = not neg
            end
        end
        if keep then
            table.insert(out, f)
        end
    end
    return out
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
    local user_args = {}
    for _, a in ipairs(config.rg.args) do
        -- output format is fixed by LEVEL1_ARGS; drop the old default from user configs
        if a ~= '--json' then
            table.insert(user_args, a)
        end
    end
    vim.list_extend(args, user_args)
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
    local search_args, opened = vim.list_slice(args), nil

    if rule.file and rule.file.opened_only then
        local files = get_valid_opened_files()
        if next(files) == nil then
            vim.notify("[logana] no valid files opened", vim.log.levels.INFO)
            return nil, {}
        end
        files = filter_by_globs(files, vim.list_extend(vim.list_slice(user_args), rule.rg.cmd))
        if next(files) == nil then
            vim.notify("[logana] no opened file passes the -g globs", vim.log.levels.INFO)
            return nil, {}
        end
        vim.list_extend(args, files)
        opened = files
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

    -- the rules hit counts run: { args, lnum, group }, see count.lua
    local rg_counts, hl_counts = {}, {}
    for _, r in ipairs(rule.rg_counts) do
        table.insert(rg_counts, { args = vim.list_extend(vim.list_slice(user_args), r.args), lnum = r.lnum,
            group = config.hi_match_group })
    end
    local names = config.hi_group_names
    for i, rule_args in ipairs(rule.hl_rules) do
        table.insert(hl_counts, { args = vim.list_extend({ '--no-config' }, rule_args), lnum = rule.hl_lnums[i],
            group = #names > 0 and names[(i - 1) % #names + 1] or 'Comment' })
    end

    return {
        args_common = args,
        -- without the opened files, which are in opened (else nil: a directory search)
        search_args = search_args,
        opened = opened,
        match_sig = table.concat(sig, '\n'),
        hl_rules = rule.hl_rules,
        hl_sig = table.concat(hl_sig, '\n'),
        rg_counts = rg_counts,
        hl_counts = hl_counts,
        opened_only = rule.file and rule.file.opened_only or false,
    }
end

-- the positional args of rg args (args[1] is rg): { [index] = 'pattern' | 'path' }.
-- without a -e/-f the first one is the pattern
local function positionals(args)
    local kinds, pattern = {}, not has_explicit_pattern(args)
    local i, rest = 2, false
    while i <= #args do
        local a = args[i]
        if rest or not a:match('^%-.') then
            kinds[i] = pattern and 'pattern' or 'path'
            pattern = false
        elseif a == '--' then
            rest = true
        elseif a:match('^%-%-') then
            if not a:find('=', 1, true) and VALUE_FLAGS[a] then
                i = i + 1
            end
        else
            -- a short cluster: a value flag takes the rest, or the next arg
            for j = 2, #a do
                if SHORT_VALUE[a:sub(j, j)] then
                    if j == #a then
                        i = i + 1
                    end
                    break
                end
            end
        end
        i = i + 1
    end
    return kinds
end

-- rg args without the positional args of a kind ('pattern' or 'path'), and whether
-- there were any
local function without(args, kind)
    local kinds, out, found = positionals(args), {}, false
    for i, a in ipairs(args) do
        if kinds[i] == kind then
            found = true
        else
            out[#out + 1] = a
        end
    end
    return out, found
end

-- the args listing the files rg args would search: --files, without the pattern,
-- which it would take for a path
local function files_args(args)
    local out = without(args, 'pattern')
    table.insert(out, 2, '--files') -- not after a '--', where it's a path
    return out
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

-- removes the [highlight] lines whose rule is `rule_args` (as parse_rule_buf makes
-- it: the flag-only lines' args, then the line's), true if there were some
local function remove_highlight_rule(rule_buf, rule_args)
    local _, _, shared = find_highlight(rule_buf, nil)
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local section, found = '', {}
    for i, l in ipairs(lines) do
        local s = l:gsub("%s+$", "")
        local cur_section = s:match("^%s*%[(.+)%]%s*$")
        if cur_section then
            section = cur_section
        elseif section == 'highlight' and not s:match("^%s*$") and not s:match("^%s*#") then
            local args = split_with_quotes(s)
            if has_pattern(args) and vim.deep_equal(vim.list_extend(vim.list_slice(shared), args), rule_args) then
                table.insert(found, i)
            end
        end
    end
    for j = #found, 1, -1 do
        api.nvim_buf_set_lines(rule_buf, found[j] - 1, found[j], false, {})
    end
    return #found > 0
end

M.get_runtime_opts = get_runtime_opts
M.files_args = files_args
M.without = without
M.toggle_highlight = toggle_highlight
M.remove_highlight_rule = remove_highlight_rule
M.initialize_rule_buffer = initialize_rule_buffer
return M
