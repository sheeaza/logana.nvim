local api = vim.api
local fn = vim.fn
local log = require('logana.log')

local M = {}

local NS_MATCH = api.nvim_create_namespace("logana.match")

local SPLIT_DIR = { top = 'below', bottom = 'above', left = 'right', right = 'left' }

local function get_prefix_and_increase()
    local prefix = ''
    if M.config.naming.prefix == "alphabet" then
        local counter = M._prefix_counter
        repeat
            prefix = string.char(string.byte("a") + counter % 26) .. prefix
            counter = math.floor(counter / 26) - 1
        until counter < 0
    else
        prefix = tostring(M._prefix_counter)
    end
    M._prefix_counter = M._prefix_counter + 1
    return prefix
end

local function set_buf_opts(buf, opts)
    for k, v in pairs(opts) do
        api.nvim_set_option_value(k, v, { buf = buf })
    end
end

local function create_normal_buffer(name, filetype)
    local buf = api.nvim_create_buf(true, false) -- [listed=true, scratch=false]
    set_buf_opts(buf, {
        swapfile = true,
        modifiable = true,
        readonly = false,
        filetype = filetype or "",
    })
    -- Set a readable name so users can :w to persist (writes relative to cwd if no path)
    pcall(api.nvim_buf_set_name, buf, name)
    return buf
end

local function result_open_win(result_buf, rule_win)
    local split = SPLIT_DIR[M.config.layout.rule_pos] or 'left'
    local t0 = vim.uv.now()
    api.nvim_open_win(result_buf, false, { split = split, win = rule_win })
    log.trace(string.format("render_results openwin took: %d ms", vim.uv.now() - t0))
end

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

--[[
return result format:
{
    {
        file_name = 'path/to/file',
        lines = {
            {
                line_number = <%d>,
                line_text = <%s>,
                matches = {
                    { <start_x>, <end_x> },
                    ...
                }
            }, ...
        }
    }, ...
--]]
local function collect_matches(ropts)
    local ok_sys, proc = pcall(vim.system, ropts.args_common, { text = true })
    if not ok_sys or not proc then
        vim.notify("[logana] failed to execute ripgrep", vim.log.levels.WARN)
        return nil, "failed"
    end

    local t0 = vim.uv.now()
    local res = proc:wait()
    log.trace(string.format("rg took: %d ms", vim.uv.now() - t0))

    if res.code == 1 then
        vim.notify(("[logana] cmd[%s], no match found"):format(table.concat(ropts.args_common, ' ')), vim.log.levels.INFO)
        return nil, {}
    end
    if res.code == 2 then
        vim.notify(("[logana] ripgrep error for: %s"):format(res.stderr or ("exit code " .. tostring(res.code))), vim.log.levels.WARN)
        return nil, {}
    end

    local t1 = vim.uv.now()
    local results = {}
    local cur_fentry = nil

    for jline in res.stdout:gmatch("([^\n]+)") do
        local okj, ev = pcall(vim.json.decode, jline)
        if okj and ev and ev.type == "match" and ev.data then
            local d = ev.data
            local path = d.path and d.path.text
            local lnum = d.line_number
            local text = d.lines and d.lines.text

            if path and lnum and type(text) == "string" then
                if not cur_fentry or cur_fentry.file_name ~= path then
                    cur_fentry = { file_name = path, lines = {} }
                    table.insert(results, cur_fentry)
                end

                local entry = {
                    line_number = lnum,
                    line_text = text:gsub("\n$", ""),
                    matches = {},
                }
                if d.submatches and #d.submatches > 0 then
                    for _, sm in ipairs(d.submatches) do
                        if sm and sm.start and sm["end"] then
                            table.insert(entry.matches, { sm.start, sm["end"] })
                        end
                    end
                end
                table.insert(cur_fentry.lines, entry)
            end
        end
    end
    log.trace(string.format("parse rg json took: %d ms", vim.uv.now() - t1))

    return results
end

local function render_results(result_buf, matches, rule_win)
    local lines = {}
    local highlights = {}
    local cur_line_num = 0

    local t0 = vim.uv.now()
    for _, file in ipairs(matches) do
        table.insert(lines, "file: " .. file.file_name)
        cur_line_num = cur_line_num + 1

        for _, line in ipairs(file.lines) do
            local prefix = ("%d: "):format(line.line_number)
            table.insert(lines, prefix .. line.line_text)
            cur_line_num = cur_line_num + 1

            local row = cur_line_num - 1
            local off = #prefix
            for _, hi in ipairs(line.matches) do
                table.insert(highlights, { { row, hi[1] + off }, { row, hi[2] + off } })
            end
        end
        table.insert(lines, '')
        cur_line_num = cur_line_num + 1
    end
    log.trace(string.format("render_results prepare lines took: %d ms", vim.uv.now() - t0))

    local t1 = vim.uv.now()
    api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
    log.trace(string.format("render_results set lines took: %d ms", vim.uv.now() - t1))

    local t2 = vim.uv.now()
    api.nvim_buf_clear_namespace(result_buf, NS_MATCH, 0, -1)
    for _, hi in ipairs(highlights) do
        vim.hl.range(result_buf, NS_MATCH, M.config.hi_group_name, hi[1], hi[2])
    end
    log.trace(string.format("render_results hi took: %d ms", vim.uv.now() - t2))

    if fn.bufwinid(result_buf) ~= -1 then
        return
    end

    if M.config.result_win.behavior == 'hide_at_first' then
        result_open_win(result_buf, rule_win)
    elseif M.config.result_win.behavior == 'override' then
        if rule_win ~= -1 and api.nvim_win_is_valid(rule_win) then
            api.nvim_win_set_buf(rule_win, result_buf)
        end
    end
end

local function get_valid_opened_files()
    local files = {}
    local rule_ft = M.config.naming.rule
    local result_ft = M.config.naming.result
    for _, b in ipairs(api.nvim_list_bufs()) do
        local abs_path = api.nvim_buf_get_name(b)
        if api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) and abs_path ~= "" then
            local ok, stats = pcall(vim.uv.fs_stat, abs_path)
            if ok and stats then
                local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = b })
                ft = ok_ft and ft or ""
                if ft ~= rule_ft and ft ~= result_ft then
                    table.insert(files, fn.fnamemodify(abs_path, ":."))
                end
            end
        end
    end
    return files
end

local function get_runtime_opts(rule_buf)
    local args = vim.list_extend({ M.config.rg.cmd }, M.config.rg.args)

    -- exclude rule/result files
    table.insert(args, '-g')
    table.insert(args, '!*.' .. M.config.naming.rule)
    table.insert(args, '-g')
    table.insert(args, '!*.' .. M.config.naming.result)

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

    return { args_common = args }
end

local function refresh_from_rule(rule_buf)
    local ropts, err = get_runtime_opts(rule_buf)
    if err then
        return nil, "get runtime opts failed"
    end

    local t0 = vim.uv.now()
    local matches, merr = collect_matches(ropts)
    if merr then
        return nil, "collect_matches failed"
    end
    log.trace(string.format("collect_matches took: %d ms", vim.uv.now() - t0))

    local rule_abs_path = api.nvim_buf_get_name(rule_buf)
    local rule_prefix = fn.fnamemodify(rule_abs_path, ":t:r")
    local rule_dir = fn.fnamemodify(rule_abs_path, ':p:h')
    local result_abs_path = rule_dir .. '/' .. rule_prefix .. '.' .. M.config.naming.result

    local result_buf = fn.bufnr(result_abs_path)
    if result_buf == -1 then
        local ok, stats = pcall(vim.uv.fs_stat, result_abs_path)
        if ok and stats then
            result_buf = fn.bufadd(result_abs_path)
            fn.bufload(result_buf)
        else
            result_buf = create_normal_buffer(rule_prefix .. '.' .. M.config.naming.result, M.config.naming.result)
        end
    end

    local t1 = vim.uv.now()
    render_results(result_buf, matches, fn.bufwinid(rule_buf))
    log.trace(string.format("render_results took: %d ms", vim.uv.now() - t1))
end

local function initialize_rule_buffer(rule_buf)
    local curr = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    if #curr == 0 or (#curr == 1 and curr[1] == "") then
        api.nvim_buf_set_lines(rule_buf, 0, -1, false, vim.split(M.config.rule_template, '\n'))
    end
end

local function result_buffer_jump()
    local line = api.nvim_get_current_line()
    local lnum_str = line:match("^(%d+):")
    if not lnum_str then
        vim.notify("[logana] not at matched line", vim.log.levels.INFO)
        return
    end
    local lnum = tonumber(lnum_str)
    local cursor = api.nvim_win_get_cursor(0)
    local col = math.max(0, cursor[2] - #lnum_str - 2) -- -2 for ':' and ' '

    -- reverse search from current line for the file header
    local fline_num = fn.search('^file: ', 'bn')
    if fline_num == 0 then
        vim.notify("[logana] did not find 'file:'", vim.log.levels.INFO)
        return
    end

    local file = fn.getline(fline_num):match("^file: (.+)$")
    if not file or file == '' then
        return
    end

    if not vim.uv.fs_stat(file) then
        vim.notify(("[logana] file: %s does not exist"):format(file), vim.log.levels.INFO)
        return
    end

    local target_buf = fn.bufnr(file)
    if target_buf == -1 then
        target_buf = fn.bufadd(file)
        fn.bufload(target_buf)
    end

    local win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, target_buf)
    pcall(api.nvim_win_set_cursor, win, { lnum, col })
end

local function setup_highlights()
    local colors = M.config.highlight_colors
    M.config.hi_group_name = "LoganaMatch"
    colors.default = true
    pcall(api.nvim_set_hl, 0, M.config.hi_group_name, colors)
end

local function setup_config(opts)
    local defconfig = require('logana.defconfig')
    M.config = vim.tbl_deep_extend("force", defconfig, opts or {})

    if fn.executable(M.config.rg.cmd) ~= 1 then
        error("[logana] ripgrep (" .. M.config.rg.cmd .. ") not found in PATH")
    end

    setup_highlights()
    M._prefix_counter = 0

    vim.filetype.add({
        extension = {
            [M.config.naming.rule] = M.config.naming.rule,
            [M.config.naming.result] = M.config.naming.result,
        },
    })
end

local function setup_keybinding()
    if M._quit_auto then
        return
    end

    -- Suppress save prompts on quit for rule/result buffers by marking them nomodified
    M._quit_auto = api.nvim_create_augroup("logana_quit_guard", { clear = true })
    api.nvim_create_autocmd("QuitPre", {
        group = M._quit_auto,
        callback = function()
            for _, b in ipairs(api.nvim_list_bufs()) do
                local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = b })
                ft = ok_ft and ft or ""
                if ft == M.config.naming.rule or ft == M.config.naming.result then
                    local abs_path = api.nvim_buf_get_name(b)
                    local ok, stats = pcall(vim.uv.fs_stat, abs_path)
                    if not (ok and stats) then
                        pcall(api.nvim_set_option_value, "modified", false, { buf = b })
                    end
                end
            end
        end,
        desc = "logana: mark rule/result buffers as nomodified on QuitPre",
    })

    api.nvim_create_autocmd("FileType", {
        group = M._quit_auto,
        pattern = M.config.naming.rule,
        callback = function(ev)
            vim.keymap.set("n", M.config.key.rule_refresh, function()
                refresh_from_rule(ev.buf)
            end, { buffer = ev.buf, noremap = true, silent = true, desc = "logana: refresh results" })
        end,
        desc = "logana: keybinding for rule file",
    })

    api.nvim_create_autocmd("FileType", {
        group = M._quit_auto,
        pattern = M.config.naming.result,
        callback = function(ev)
            vim.keymap.set("n", M.config.key.result_jump, result_buffer_jump,
                { buffer = ev.buf, noremap = true, silent = true, desc = "logana: results jump" })
        end,
        desc = "logana: keybinding for jumping in result buf",
    })
end

function M.is_rule_buffer(buf)
    local ok, ft = pcall(api.nvim_get_option_value, "filetype", { buf = buf })
    return ok and ft == M.config.naming.rule
end

function M.open()
    local naming = M.config.naming
    local rule_buf, prefix

    repeat
        prefix = get_prefix_and_increase()
        local rule_name = ("%s.%s"):format(prefix, naming.rule)
        local ok, stats = pcall(vim.uv.fs_stat, rule_name)
        if not (ok and stats) then
            rule_buf = create_normal_buffer(rule_name, naming.rule)
            initialize_rule_buffer(rule_buf)
        end
    until rule_buf

    local rule_win = api.nvim_open_win(rule_buf, true, { split = 'right', win = 0 })
    if M.config.result_win.behavior == 'open_with_rule' then
        local result_name = ("%s.%s"):format(prefix, naming.result)
        local result_abs_path = fn.fnamemodify(result_name, ':p')
        local result_buf = fn.bufnr(result_abs_path)
        if result_buf == -1 then
            result_buf = create_normal_buffer(result_name, naming.result)
        end
        result_open_win(result_buf, rule_win)
    end
end

function M.setup(opts)
    setup_config(opts)
    setup_keybinding()
end

return M
