local api = vim.api
local fn = vim.fn

local M = {}

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


-- Namespaces and highlights
local NS_MATCH = api.nvim_create_namespace("logana.match")

local function setup_highlights()
    local colors = M.config.highlight_colors

    for i, entry in ipairs(colors) do
        local name = "LoganaMatch" .. tostring(i)
        entry.default = true

        pcall(api.nvim_set_hl, 0, name, entry)
    end
end

-- In-memory state linking buffers
-- rule_bufnr -> { source = bufnr, result = bufnr }
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

local function open_windows_for_rule_and_result(rule_buf, result_buf)
    vim.cmd("vsplit")
    local rule_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(rule_win, rule_buf)

    if M.config.result_win.behavior == 'open_with_rule' then
        -- 2) Split the right pane horizontally and put result on bottom
        if M.config.layout.rule_pos == 'top' then
            vim.cmd("split")
        elseif M.config.layout.rule_pos == 'bottom' then
            vim.cmd("aboveleft split")
        elseif M.config.layout.rule_pos == 'left' then
            vim.cmd("vsplit")
        else
            vim.cmd("aboveleft  vsplit")
        end

        local result_win = api.nvim_get_current_win()
        api.nvim_win_set_buf(result_win, result_buf)
    end

    -- Keep rule window focused for editing rules
    api.nvim_set_current_win(rule_win)
end

local function get_rule_section_patterns(rule_buf)
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local patterns = {}
    local found_match = false

    local in_match = false
    for _, line in ipairs(lines) do
        local s = line:gsub("%s+$", "")
        if s:match("^%s*%[match%]%s*$") or s:match("^%s*%[pattern%]%s*$") then
            in_match = true
            found_match = true
        elseif in_match then
            -- Stop if another section begins
            if s:match("^%s*%[.+%]%s*$") then
                break
            end
            -- Skip comments and empty lines
            if s:match("^%s*$") or s:match("^%s*#") then
                -- ignore
            else
                local m = s:match("^%s*/(.*)/%s*$")
                table.insert(patterns, m or s)
            end
        end
    end

    -- Require an explicit [match] (or [pattern]) section and at least one pattern line
    if not found_match then
        vim.notify("[logana] Missing [match] section. Add a [match] section with one ripgrep regex per line.", vim.log.levels.ERROR)
        return nil, "missing_section"
    end
    if #patterns == 0 then
        vim.notify("[logana] No patterns under [match]. Add regex rules, one per line.", vim.log.levels.WARN)
        return nil, "empty_patterns"
    end

    return patterns
end

local function get_rule_options(rule_buf)
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local opts = {}
    local in_rule = false
    for _, line in ipairs(lines) do
        local s = line:gsub("%s+$", "")
        if s:match("^%s*%[rule%]%s*$") then
            in_rule = true
        elseif in_rule then
            if s:match("^%s*%[.+%]%s*$") then
                break
            end
            if not s:match("^%s*$") and not s:match("^%s*#") then
                local k, v = s:match("^%s*([%w_]+)%s*=%s*(%w+)%s*$")
                if k and v then
                    local vb = (v == "true") and true or ((v == "false") and false or nil)
                    opts[k] = vb
                end
            end
        end
    end
    return opts
end

local function collect_matches(source_buf, patterns, ropts)
    -- Aggregate matches per source line to avoid reordering and to combine highlights
    local by_line = {}
    local results = {}
    if not patterns or #patterns == 0 then
        return results
    end

    local cmd = (M.config and M.config.rg and M.config.rg.cmd) or "rg"
    local base_args = (M.config and M.config.rg and M.config.rg.args) or { "--json", "--no-config", "--color", "never" }
    local smart_case_default = M.config and M.config.rg and M.config.rg.smart_case
    local whole_word_default = M.config and M.config.rg and M.config.rg.whole_word
    local smart_case = (ropts and ropts.smart_case ~= nil) and ropts.smart_case or smart_case_default
    local whole_word = (ropts and ropts.whole_word ~= nil) and ropts.whole_word or whole_word_default

    if fn.executable and fn.executable(cmd) ~= 1 then
        table.insert(results, { text = "[logana] ripgrep (" .. cmd .. ") not found in PATH", is_error = true })
        return results
    end

    local src_lines = api.nvim_buf_get_lines(source_buf, 0, -1, false)
    local stdin_text = table.concat(src_lines, "\n")

    for pi, pat in ipairs(patterns) do
        local stdout_lines = {}
        local stderr_msg = nil
        local exit_code = 0

        local args = { cmd }
        for _, a in ipairs(base_args) do
            table.insert(args, a)
        end
        if smart_case == true then
            table.insert(args, "--smart-case")
        elseif smart_case == false then
            table.insert(args, "--case-sensitive")
        end
        if whole_word == true then
            table.insert(args, "--word-regexp")
        end
        table.insert(args, "-e")
        table.insert(args, pat)
        table.insert(args, "-")

        if vim.system then
            local ok_sys, proc = pcall(vim.system, args, { text = true, stdin = stdin_text })
            if not ok_sys or not proc then
                table.insert(results, { text = "[logana] failed to execute ripgrep", is_error = true })
                goto continue_pattern
            end
            local res = proc:wait()
            exit_code = res.code or 0
            local out = res.stdout or ""
            local err = res.stderr or ""
            stderr_msg = err ~= "" and err or nil
            for line in (out .. "\n"):gmatch("([^\n]*)\n") do
                if line ~= "" then
                    table.insert(stdout_lines, line)
                end
            end
        else
            local tmp = fn.tempname and fn.tempname() or (os.tmpname and os.tmpname() or "/tmp/logana_rg.txt")
            pcall(fn.writefile, src_lines, tmp)
            local args_file = { cmd }
            for _, a in ipairs(base_args) do
                table.insert(args_file, a)
            end
            if smart_case == true then
                table.insert(args_file, "--smart-case")
            elseif smart_case == false then
                table.insert(args_file, "--case-sensitive")
            end
            if whole_word == true then
                table.insert(args_file, "--word-regexp")
            end
            table.insert(args_file, "-e")
            table.insert(args_file, pat)
            table.insert(args_file, tmp)
            local out = fn.systemlist(args_file)
            exit_code = vim.v.shell_error or 0
            stdout_lines = type(out) == "table" and out or {}
            pcall(fn.delete, tmp)
        end

        if exit_code ~= 0 and #stdout_lines == 0 then
            table.insert(results, { text = ("[logana] ripgrep error for pattern '%s': %s"):format(pat, stderr_msg or ("exit code " .. tostring(exit_code))), is_error = true })
            goto continue_pattern
        end

        for _, jline in ipairs(stdout_lines) do
            local okj, ev = pcall(vim.json.decode, jline)
            if okj and ev and ev.type == "match" and ev.data then
                local d = ev.data
                local lnum = d.line_number
                local text = d.lines and d.lines.text or nil
                if lnum and type(text) == "string" then
                    local prefix = ("%d: "):format(lnum)
                    local entry = by_line[lnum]
                    if not entry then
                        entry = { text = prefix .. text:gsub("\n$", ""), highlights = {}, is_error = false }
                        by_line[lnum] = entry
                    end
                    if d.submatches and #d.submatches > 0 then
                        for _, sm in ipairs(d.submatches) do
                            if sm and sm.start and sm["end"] then
                                table.insert(entry.highlights, { #prefix + sm.start, #prefix + sm["end"], pi })
                            end
                        end
                    end
                end
            end
        end

        ::continue_pattern::
    end

    -- Emit results in the same order as source buffer lines
    for idx = 1, #src_lines do
        local e = by_line[idx]
        if e then
            table.insert(results, e)
        end
    end

    return results
end

local function render_results(result_buf, results)
    -- Make buffer modifiable, replace content, then lock it again
    set_buf_opts(result_buf, { modifiable = true, readonly = false })

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
                    local total = #M.config.highlight_colors
                    local idx = ((pi or 1) - 1) % total + 1
                    local group = "LoganaMatch" .. tostring(idx)
                    api.nvim_buf_add_highlight(result_buf, NS_MATCH, group, i - 1, s, e)
                end
            end
        end
    end

    -- Mark as unmodified to avoid save prompts for programmatic updates
    pcall(api.nvim_set_option_value, "modified", false, { buf = result_buf })
end

local function refresh_from_rule(rule_buf)
    local link = M.state.rule_links[rule_buf]
    if not link or not api.nvim_buf_is_valid(link.source) then
        return
    end
    if not link.result or not api.nvim_buf_is_valid(link.result) then
        local res = M.ensure_result_for_rule and M.ensure_result_for_rule(rule_buf) or nil
        if not res or not api.nvim_buf_is_valid(res) then
            return
        end
    end
    local pats, perr = get_rule_section_patterns(rule_buf)
    if perr then
        local msg = perr == "missing_section"
        and "[logana] Missing [match] section. Add a [match] section with one ripgrep regex per line."
        or "[logana] No patterns under [match]. Add regex rules, one per line."
        render_results(link.result, { { text = msg, is_error = true } })
        return
    end
    local ropts = get_rule_options(rule_buf)
    local results = collect_matches(link.source, pats, ropts)
    render_results(link.result, results)
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
        local tpl = M.config.rule_template
        api.nvim_buf_set_lines(rule_buf, 0, -1, false, tpl)
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
        local lnum = tonumber((line or ""):match("^(%d+):"))
        if not lnum then
            vim.notify("[logana] cannot parse line number from result line", vim.log.levels.WARN)
            return
        end
        local rule = M.state.result_to_rule[result_buf]
        if not rule then
            vim.notify("[logana] no linked rule buffer for this result", vim.log.levels.WARN)
            return
        end
        local link = M.state.rule_links[rule]
        if not link or not api.nvim_buf_is_valid(link.source) then
            vim.notify("[logana] source buffer is not valid", vim.log.levels.WARN)
            return
        end
        local win = api.nvim_get_current_win()
        api.nvim_win_set_buf(win, link.source)
        pcall(api.nvim_win_set_cursor, win, { lnum, 0 })
    end, { buffer = result_buf, noremap = true, silent = true, desc = "logana: jump to source line" })
end

function M.open(opts)
    local source_buf = (opts and opts.source_buf) or api.nvim_get_current_buf()
    if not api.nvim_buf_is_valid(source_buf) then
        vim.notify("[logana] Invalid source buffer", vim.log.levels.ERROR)
        return
    end

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
    M.state.rule_links[rule_buf] = { source = source_buf, result = result_buf, suffix = suffix }
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

-- Ensure a result buffer is present and bound for the given rule buffer.
-- If the current window is the rule buffer, opens a horizontal split below with the result.
function M.ensure_result_for_rule(rule_buf)
    local link = M.state.rule_links[rule_buf]
    if not link or not api.nvim_buf_is_valid(link.source) then
        return nil
    end
    if link.result and api.nvim_buf_is_valid(link.result) then
        return link.result
    end

    -- create result buffer with same suffix as rule
    local naming = M.config and M.config.naming or {}
    local prefix_result = naming.result or "logana_result"
    local suffix = link.suffix or tostring(vim.fn.rand() % 100000)
    local result_name = ("%s_%s"):format(prefix_result, suffix)

    local result_buf = create_normal_buffer(result_name, "logana_results")
    link.result = result_buf
    M.state.result_to_rule[result_buf] = rule_buf

    -- If we're currently in the rule window, display the result below it
    local curwin = api.nvim_get_current_win()
    local curbuf = api.nvim_win_get_buf(curwin)
    if curbuf == rule_buf then
        vim.cmd("split")
        api.nvim_win_set_buf(api.nvim_get_current_win(), result_buf)
        -- return focus to the rule buffer
        vim.cmd("wincmd k")
    end

    initialize_result_buffer(result_buf)
    bind_lifecycle(rule_buf, result_buf)
    refresh_from_rule(rule_buf)
    return result_buf
end

local function setup_config()
    setup_highlights()

    -- buffer naming per config
    M._suffix_counter = 0
end

function M.setup(opts)
    local defconfig = require('logana.defconfig')
    M.config = vim.tbl_deep_extend("force", defconfig, opts or {})

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
