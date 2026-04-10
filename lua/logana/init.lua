local api = vim.api
local fn = vim.fn

local M = {}

-- Namespaces and highlights
local NS_MATCH = api.nvim_create_namespace("logana.match")

local function get_suffix_and_increase()
    local suffix_mode = M.config.naming.suffix

    local suffix = ''
    if suffix_mode == "alphabet" then
        counter = M._suffix_counter

        repeat
            suffix = string.char(string.byte("a") + counter % 26) .. suffix
            counter = math.floor(counter / 26) - 1
        until counter < 0
    else
        suffix = tostring(M._suffix_counter)
    end

    M._suffix_counter = M._suffix_counter + 1

    return suffix
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

local function open_windows_for_rule_and_result(rule_buf, result_buf)
    local rule_win = api.nvim_open_win(rule_buf, true, { split = 'right', win = 0, })

    if M.config.result_win.behavior == 'open_with_rule' then
        result_open_win(result_buf, rule_win)
    end
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
        for _, arg in ipairs(vim.split(line, ' ')) do
            table.insert(rule.rg.cmd, arg)
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

local function collect_matches(ropts)
    -- file-based search across working directory; filter by path_regex if provided
    local results = {}

    local args = vim.deepcopy(ropts.args_common)
    local ok_sys, proc = pcall(vim.system, args, { text = true })
    if not ok_sys or not proc then
        table.insert(results, { text = "[logana] failed to execute ripgrep", is_error = true })
        return nil
    end
    local res = proc:wait()
    local exit_code = res.code or 0
    local out = res.stdout or ""
    local err = res.stderr or ""
    local stderr_msg = err ~= "" and err or nil
    local stdout_lines = {}
    for line in (out .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            table.insert(stdout_lines, line)
        end
    end

    if exit_code ~= 0 and #stdout_lines == 0 then
        table.insert(results, { text = ("[logana] ripgrep error for pattern '%s': %s"):format(pat, stderr_msg or ("exit code " .. tostring(exit_code))), is_error = true })
        return nil
    end

    for _, jline in ipairs(stdout_lines) do
        local okj, ev = pcall(vim.json.decode, jline)
        if okj and ev and ev.type == "match" and ev.data then
            local d = ev.data
            local lnum = d.line_number
            local text = d.lines and d.lines.text or nil
            local path = d.path and d.path.text or nil
            if path_regex and path and not tostring(path):match(path_regex) then
                goto continue_event
            end
            if path and lnum and type(text) == "string" then
                local prefix = ("%s:%d: "):format(path, lnum)
                local entry = { text = prefix .. text:gsub("\n$", ""), highlights = {}, is_error = false }
                if d.submatches and #d.submatches > 0 then
                    for _, sm in ipairs(d.submatches) do
                        if sm and sm.start and sm["end"] then
                        table.insert(entry.highlights, { #prefix + sm.start, #prefix + sm["end"], pi })
                        end
                    end
                end
                table.insert(results, entry)
            end
        end
        ::continue_event::
    end

    return results
end

local function render_results(result_buf, results, rule_win)
    local lines = {}
    for _, item in ipairs(results) do
        table.insert(lines, item.text)
    end

    api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)

    -- Clear and re-add highlights
    api.nvim_buf_clear_namespace(result_buf, NS_MATCH, 0, -1)
    for i, item in ipairs(results) do
        if not item.is_error and item.highlights and #item.highlights > 0 then
            for _, h in ipairs(item.highlights) do
                local s, e, pi = h[1], h[2], h[3]
                if s and e and e > s then
                    vim.hl.range(result_buf, NS_MATCH, M.config.hi_group_name, { i - 1, s }, { i - 1, e })
                end
            end
        end
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
        render_results(link.result, { { text = err, is_error = true } }, vim.fn.bufwinid(rule_buf))
        return nil, msg
    end

    local results = {}
    if ropts.file.opened_only then
        -- Gather all opened buffers (ignore logana buffers) and optionally filter by pattern
        update_cmd_for_opened_only(ropts)
    end

    local part = collect_matches(ropts)
    for _, e in ipairs(part) do
        if not e.is_error and type(e.text) == "string" then
            local ln = tonumber(e.text:match("^(%d+):"))
            if ln then
                local oldp = ("%d: "):format(ln)
                local newp = ("%s:%d: "):format(file, ln)
                local delta = #newp - #oldp
                e.text = newp .. e.text:sub(#oldp + 1)
                if e.highlights and #e.highlights > 0 then
                    for _, h in ipairs(e.highlights) do
                        h[1] = h[1] + delta
                        h[2] = h[2] + delta
                    end
                end
            else
                e.text = ("%s: %s"):format(file, e.text)
            end
        end
        table.insert(results, e)
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
        local line = api.nvim_get_current_line()
        local path, lnum_s = (line or ""):match("^([^:]+):(%d+):")
        local lnum = tonumber(lnum_s or (line or ""):match("^(%d+):"))
        if not lnum then
            vim.notify("[logana] cannot parse line number from result line", vim.log.levels.WARN)
            return
        end

        local target_buf = nil
        if path then
            for _, b in ipairs(api.nvim_list_bufs()) do
                if api.nvim_buf_is_valid(b) and api.nvim_buf_is_loaded(b) then
                    local name = api.nvim_buf_get_name(b)
                    if name == path then
                        target_buf = b
                        break
                    end
                end
            end
        end

        if not target_buf then
            local rule = M.state.result_to_rule[result_buf]
            if not rule then
                vim.notify("[logana] no linked rule buffer for this result", vim.log.levels.WARN)
                return
            end
            local link = M.state.rule_links[rule]
            if not link then
                vim.notify("[logana] no link for rule buffer", vim.log.levels.WARN)
                return
            end
            target_buf = link.source
            if not target_buf or not api.nvim_buf_is_valid(target_buf) then
                vim.notify("[logana] could not resolve target buffer for jump", vim.log.levels.WARN)
                return
            end
        end

        local win = api.nvim_get_current_win()
        api.nvim_win_set_buf(win, target_buf)
        pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
    end, { buffer = result_buf, noremap = true, silent = true, desc = "logana: jump to source line" })
end

function M.open(opts)
    -- buffer naming per config
    local naming = M.config.naming
    local prefix_rule = naming.rule
    local prefix_result = naming.result

    local suffix = get_suffix_and_increase()
    local rule_name = ("%s_%s"):format(prefix_rule, suffix)
    local result_name = ("%s_%s"):format(prefix_result, suffix)

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

-- Utility helpers for external control
function M.is_rule_buffer(buf)
    local ok, ft = pcall(api.nvim_get_option_value, "filetype", { buf = buf })
    return ok and ft == "logana_rules"
end

local function setup_highlights()
    local colors = M.config.highlight_colors
    M.config.hi_group_name = "LoganaMatch"
    colors.default = true
    pcall(api.nvim_set_hl, 0, M.config.hi_group_name, colors)
end

local function setup_config()
    setup_highlights()

    -- buffer naming per config
    M._suffix_counter = 0
end

function M.setup(opts)
    local defconfig = require('logana.defconfig')
    M.config = vim.tbl_deep_extend("force", defconfig, opts or {})

    if fn.executable(M.config.rg.cmd) ~= 1 then
        error("[logana] ripgrep (" .. M.config.rg.cmd .. ") not found in PATH")
    end

    setup_config()

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
    end
end

return M
