local api = vim.api
local fn = vim.fn
    -- print(vim.inspect(res.stdout))
    -- vim.fn.getchar()

local M = {}

-- Namespaces and highlights
local NS_MATCH = api.nvim_create_namespace("logana.match")

local function get_prefix_and_increase()
    local prefix_mode = M.config.naming.prefix

    local prefix = ''
    if prefix_mode == "alphabet" then
        counter = M._prefix_counter

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

-- In-memory state linking buffers
-- rule_bufnr -> { result = bufnr, }
-- result_bufnr -> rule_bufnr (reverse lookup)
M.state = {
    rule_links = {},
    result_to_rule = {},
}

local function set_buf_opts(buf, opts)
    for k, v in pairs(opts) do
        api.nvim_set_option_value(k, v, { buf = buf })
    end
end

local function create_normal_buffer(name, filetype, opts)
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
    local _split = ''
    if M.config.layout.rule_pos == 'top' then
        _split = 'below'
    elseif M.config.layout.rule_pos == 'bottom' then
        _split = 'above'
    elseif M.config.layout.rule_pos == 'left' then
        _split = 'right'
    else
        _split = 'left'
    end

    api.nvim_open_win(result_buf, false, { split = _split, win = rule_win, })
end

local function parse_rule_buf(rule_buf)
    local rule = {}
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)

    local section = ''
    for _, line in ipairs(lines) do
        local s = line:gsub("%s+$", "")

        -- Skip comments and empty lines
        if s:match("^%s*$") or s:match("^%s*#") then
            -- ignore
        else
            local cur_section = s:match("^%s*%[(.+)%]%s*$")
            if cur_section then
                section = cur_section
                rule[section] = {}
                rule[section].lines = {}
            elseif section ~= '' then
                local m = s:match("^%s*(.*)%s*$")
                table.insert(rule[section].lines, m or s)
            end
        end
    end

    -- Require an explicit [match] (or [pattern]) section and at least one pattern line
    if next(rule) == nil then
        vim.notify("[logana] Missing [rg] section. Add a [rg] section with one ripgrep regex per line.", vim.log.levels.ERROR)
        return nil, "missing_section"
    end
    if next(rule.rg) == nil or next(rule.rg.lines) == nil then
        vim.notify("[logana] No patterns under [rg]. Add regex rules, one per line.", vim.log.levels.WARN)
        return nil, "empty_patterns"
    end

    rule.rg.cmd = {}
    for _, line in ipairs(rule.rg.lines) do
        for _, arg in ipairs(vim.split(line, ' +')) do -- add + to prevent empty string
            local _arg = arg:match("[\'\"](.+)[\'\"]") -- remove wrap ' or " if exist
            if _arg then
                table.insert(rule.rg.cmd, _arg)
            else
                table.insert(rule.rg.cmd, arg)
            end
        end
    end

    if rule.file and rule.file.lines then
        for _, line in ipairs(rule.file.lines) do
            local kb, vb = line:match("^%s*(%S-)%s*=%s*(%S-)%s*$")
            if kb == "opened_only" then
                if vb == "true" then
                    rule.file.opened_only = true
                elseif vb == "false" then
                    rule.file.opened_only = false
                end
            end
        end
    end
    return rule
end

-- return result format:
-- {
--   {
--     file = {
--
--
--
-- }
--
--
local function collect_matches(ropts)
    local args = vim.deepcopy(ropts.args_common)
    local ok_sys, proc = pcall(vim.system, args, { text = true })
    if not ok_sys or not proc then
        vim.notify("[logana] failed to execute ripgrep", vim.log.levels.WARN)
        return nil, "failed"
    end
    local res = proc:wait()

    if res.code == 1 then
        return nil, {}
    end

    if res.code == 2 then
        vim.notify(("[logana] ripgrep error for: %s"):format(res.stderr or ("exit code " .. tostring(res.code))), vim.log.levels.WARN)
        return nil, {}
    end

    local stdout_lines = {}
    for line in (res.stdout .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            table.insert(stdout_lines, line)
        end
    end

    local results = {}
    local cur_fentry = nil

    for _, jline in ipairs(stdout_lines) do
        local okj, ev = pcall(vim.json.decode, jline)
        if okj and ev and ev.type == "match" and ev.data then
            local d = ev.data
            local lnum = d.line_number
            local text = d.lines and d.lines.text or nil
            local path = d.path and d.path.text or nil

            if path and lnum and type(text) == "string" then
                if cur_fentry == nil or cur_fentry.file_name ~= path then
                    cur_fentry = { file_name = path, lines = {} }
                    table.insert(results, cur_fentry)
                end

                local entry = {
                    line_number = d.line_number,
                    line_text = d.lines.text:gsub("\n$", ""),
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

    return results
end

local function render_results(result_buf, results, rule_win)
    local lines = {}
    local high_lights = {}
    local cur_line_num = 0
    for _, file in ipairs(results) do
        table.insert(lines, "file: " .. file.file_name);
        cur_line_num = cur_line_num + 1

        for _, line in ipairs(file.lines) do
            local prefix = ("%d: "):format(line.line_number)
            table.insert(lines, prefix .. line.line_text);
            cur_line_num = cur_line_num + 1

            for _, hi in ipairs(line.matches) do
                _hi = { { cur_line_num - 1, hi[1] + #prefix }, { cur_line_num - 1, hi[2] + #prefix } }
                table.insert(high_lights, _hi)
            end
        end
        table.insert(lines, '');
        cur_line_num = cur_line_num + 1
    end

    api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)

    api.nvim_buf_clear_namespace(result_buf, NS_MATCH, 0, -1)
    for _, hi in ipairs(high_lights) do
        vim.hl.range(result_buf, NS_MATCH, M.config.hi_group_name, hi[1], hi[2])
    end

    -- open window for result buf if needed
    if vim.fn.bufwinid(result_buf) ~= -1 then
        return
    end

    -- result buf did not shown in windows
    if M.config.result_win.behavior == 'hide_at_first' then
        result_open_win(result_buf, rule_win)
    elseif M.config.result_win.behavior == 'override' then
        if rule_win ~= -1 and vim.api.nvim_win_is_valid(rule_win) then
            api.nvim_win_set_buf(rule_win, result_buf)
        end
    end
end

-- Gather all opened buffers (ignore logana buffers) and optionally filter by pattern
local function update_cmd_for_opened_only(ropts)
    local nrule = M.config.naming.rule
    local nres = M.config.naming.result
    local sources = {}
    for _, b in ipairs(api.nvim_list_bufs()) do
        local abs_path = api.nvim_buf_get_name(b)

        if api.nvim_buf_is_valid(b)
            and api.nvim_buf_is_loaded(b)
            and abs_path ~= "" then

            local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = b })
            ft = ok_ft and ft or ""
            if ft ~= nrule and ft ~= nres then
                local rel_path = vim.fn.fnamemodify(abs_path, ":.")
                table.insert(ropts.args_common, rel_path)
            end
        end
    end
end

local function get_runtime_opts(rule_buf)
    local rule, perr = parse_rule_buf(rule_buf)
    if perr then
        return nil, perr
    end

    local args_common = { M.config.rg.cmd }
    for _, a in ipairs(M.config.rg.args) do
        table.insert(args_common, a)
    end

    for _, pat in ipairs(rule.rg.cmd) do
        table.insert(args_common, pat)
    end

    local ropts = {}
    ropts.args_common = args_common

    ropts.file = {}
    ropts.file.opened_only = false
    if rule.file and rule.file.opened_only then
        ropts.file = rule.file
    end

    return ropts
end

local function refresh_from_rule(rule_buf)
    local link = M.state.rule_links[rule_buf]
    local ropts, err = get_runtime_opts(rule_buf)

    if err then
        return nil, "get runtime opts failed"
    end

    if ropts.file.opened_only then
        -- Gather all opened buffers (ignore logana buffers) and optionally filter by pattern
        update_cmd_for_opened_only(ropts)
    end

    local results, err = collect_matches(ropts)
    if err then
        return nil, "collect_matches failed"
    end

    render_results(link.result, results, vim.fn.bufwinid(rule_buf))
end

local function bind_lifecycle(rule_buf, result_buf)
    -- When rule buffer is wiped, clean and close result buffer
    api.nvim_create_autocmd({ "BufWipeout" }, {
        buffer = rule_buf,
        callback = function()
            local link = M.state.rule_links[rule_buf]
            if link then
                if link.result and api.nvim_buf_is_valid(link.result) then
                    pcall(api.nvim_buf_delete, link.result, { force = true })
                end
                M.state.rule_links[rule_buf] = nil
            end
        end,
        desc = "logana: cleanup result buffer on rule wipe",
    })

    -- When result buffer is wiped, unlink only the result and preserve the source link
    api.nvim_create_autocmd({ "BufWipeout" }, {
        buffer = result_buf,
        callback = function()
            local r = M.state.result_to_rule[result_buf]
            if r then
                M.state.result_to_rule[result_buf] = nil
                local link = M.state.rule_links[r]
                if link then
                    link.result = nil
                end
            end
        end,
        desc = "logana: unlink result on wipe (preserve source)",
    })
end

local function initialize_rule_buffer(rule_buf)
    local curr = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local empty = (#curr == 0) or (#curr == 1 and curr[1] == "")
    if empty then
        api.nvim_buf_set_lines(rule_buf, 0, -1, false, vim.split(M.config.rule_template, '\n'))
    end

    -- Buffer-local mapping: <CR> to refresh
    vim.keymap.set("n", M.config.key.rule_refresh, function()
        refresh_from_rule(rule_buf)
    end, { buffer = rule_buf, noremap = true, silent = true, desc = "logana: refresh results" })
end

-- Initialize result buffer mappings/behavior
local function initialize_result_buffer(result_buf)
    vim.keymap.set("n", M.config.key.result_jump, function()
        -- get line number
        local line = api.nvim_get_current_line()
        local lnum_str = line:match("^(%d+):")
        if lnum_str == nil then
            vim.notify("[logana] not at matched line", vim.log.levels.INFO)
            return
        end
        lnum = tonumber(lnum_str)
        local cursor = vim.api.nvim_win_get_cursor(0)
        local col = cursor[2] - lnum_str:len() - 2 -- - 2: ';' and ' '
        if col < 0 then -- not at source file column
            col = 0
        end

        -- get file name, reverse seach from current line
        local fline_num = vim.fn.search('^file: ', 'bn')
        if fline_num == 0 then
            vim.notify("[logana] did not find 'file:'", vim.log.levels.INFO)
            return
        end

        local fline = vim.fn.getline(fline_num)
        local file = fline:match("^file: (.+)$")
        if file == nil or file == '' then
            return
        end
        print(vim.inspect(file))
        vim.fn.getchar()

        local stat1 = vim.uv.fs_stat(file)
        if not stat1 then
            vim.notify(("[logana] did file: %s not exist"):format(file), vim.log.levels.INFO)
            return
        end

        local target_buf = nil
        for _, b in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) then
                local name = api.nvim_buf_get_name(b)
                local stat2 = vim.uv.fs_stat(name)
                if stat2 and stat1.dev == stat2.dev and stat1.ino == stat2.ino then
                    target_buf = b
                    break
                end
            end
        end

        -- target file not opened, goto open file
        if not target_buf then
            target_buf = vim.fn.bufadd(file)
            vim.fn.bufload(target_buf)
        end

        local win = api.nvim_get_current_win()
        api.nvim_win_set_buf(win, target_buf)
        pcall(api.nvim_win_set_cursor, win, { lnum, col })
    end, { buffer = result_buf, noremap = true, silent = true, desc = "logana: jump to source line" })
end

local function open_windows_for_rule_and_result(rule_buf, result_buf)
    local rule_win = api.nvim_open_win(rule_buf, true, { split = 'right', win = 0, })

    if M.config.result_win.behavior == 'open_with_rule' then
        result_open_win(result_buf, rule_win)
    end
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

    -- buffer naming per config
    M._prefix_counter = 0

    vim.filetype.add({
        extension = {
            [M.config.naming.rule] = M.config.naming.rule,
            [M.config.naming.result] = M.config.naming.result,
        },
    })
end

-- Utility helpers for external control
function M.is_rule_buffer(buf)
    local ok, ft = pcall(api.nvim_get_option_value, "filetype", { buf = buf })
    return ok and ft == M.config.naming.rule
end

function M.open(opts)
    -- buffer naming per config
    local naming = M.config.naming
    local prefix_rule = naming.rule
    local prefix_result = naming.result

    local prefix = get_prefix_and_increase()
    local rule_name = ("%s.%s"):format(prefix, prefix_rule)
    local result_name = ("%s.%s"):format(prefix, prefix_result)

    local rule_buf = create_normal_buffer(rule_name, naming.rule)
    local result_buf = create_normal_buffer(result_name, naming.result)

    -- Link state
    M.state.rule_links[rule_buf] = { result = result_buf }
    M.state.result_to_rule[result_buf] = rule_buf

    -- Windows layout (default behavior; config-driven layout can be expanded later)
    open_windows_for_rule_and_result(rule_buf, result_buf)

    -- Initialize rule buffer behavior and template
    initialize_rule_buffer(rule_buf)
    -- Initialize result buffer behavior and mappings
    initialize_result_buffer(result_buf)

    -- Bind buffer lifecycles (cleanup on wipe)
    bind_lifecycle(rule_buf, result_buf)
end

function M.setup(opts)
    setup_config(opts)

    -- Suppress save prompts on quit for rule/result buffers by marking them nomodified
    if not M._quit_auto then
        M._quit_auto = api.nvim_create_augroup("logana_quit_guard", { clear = true })
        api.nvim_create_autocmd("QuitPre", {
            group = M._quit_auto,
            callback = function()
                for rule, link in pairs(M.state.rule_links) do
                    if api.nvim_buf_is_valid(rule) then
                        pcall(api.nvim_set_option_value, "modified", false, { buf = rule })
                    end
                    if link and link.result and api.nvim_buf_is_valid(link.result) then
                        pcall(api.nvim_set_option_value, "modified", false, { buf = link.result })
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
    end
end

return M
