local api = vim.api
local fn = vim.fn
local log = require('logana.log')

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

    local start = vim.uv.now()
    api.nvim_open_win(result_buf, false, { split = _split, win = rule_win, })
    local stop = vim.uv.now()
    log.trace(string.format("render_results openwin took: %d ms", stop - start))
end

local function split_with_quotes(str)
  local result = {}
  local current = ""
  local in_quotes = false
  local quote_char = nil

  for i = 1, #str do
    local char = str:sub(i, i)

    -- Handle quote characters
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
    -- Handle spaces outside quotes
    elseif char == " " and not in_quotes then
      if current ~= "" then
        table.insert(result, current)
        current = ""
      end
    else
      current = current .. char
    end
  end

  -- Add the last token
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
        for _, arg in ipairs(split_with_quotes(line)) do
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
            }, {
                ...
            }...
        }
    }, {
        ...
    }...
--]]
local function collect_matches(ropts)
    local args = vim.deepcopy(ropts.args_common)
    local ok_sys, proc = pcall(vim.system, args, { text = true })
    if not ok_sys or not proc then
        vim.notify("[logana] failed to execute ripgrep", vim.log.levels.WARN)
        return nil, "failed"
    end

    local start = vim.uv.now()
    local res = proc:wait()
    local stop = vim.uv.now()
    log.trace(string.format("rg took: %d ms", stop - start))
    if res.code == 1 then
        vim.notify(("[logana] cmd[%s], no match found"):format(table.concat(args, ' ')), vim.log.levels.INFO)
        return nil, {}
    end

    if res.code == 2 then
        vim.notify(("[logana] ripgrep error for: %s"):format(res.stderr or ("exit code " .. tostring(res.code))), vim.log.levels.WARN)
        return nil, {}
    end

    local start = vim.uv.now()
    local results = {}
    local cur_fentry = nil

    for jline in (res.stdout):gmatch("([^\n]+)") do
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
    local stop = vim.uv.now()
    log.trace(string.format("parse rg json took: %d ms", stop - start))

    return results
end

local function render_results(result_buf, matches, rule_win)
    local lines = {}
    local high_lights = {}
    local cur_line_num = 0
    local start = vim.uv.now()
    for _, file in ipairs(matches) do
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
    local stop = vim.uv.now()
    log.trace(string.format("render_results prepair lines took: %d ms", stop - start))

    local start = vim.uv.now()
    api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
    local stop = vim.uv.now()
    log.trace(string.format("render_results shows lines took: %d ms", stop - start))

    local start = vim.uv.now()
    api.nvim_buf_clear_namespace(result_buf, NS_MATCH, 0, -1)
    for _, hi in ipairs(high_lights) do
        vim.hl.range(result_buf, NS_MATCH, M.config.hi_group_name, hi[1], hi[2])
    end
    local stop = vim.uv.now()
    log.trace(string.format("render_results hi took: %d ms", stop - start))

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

local function get_valid_opened_files()
    local files = {}
    for _, b in ipairs(api.nvim_list_bufs()) do
        local abs_path = api.nvim_buf_get_name(b)

        if api.nvim_buf_is_valid(b)
            and api.nvim_buf_is_loaded(b)
            and abs_path ~= "" then

            -- ensure buf has file
            local ok, stats = pcall(vim.uv.fs_stat, abs_path)
            local exists_on_disk = ok and stats ~= nil

            if exists_on_disk == true then
                local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = b })
                ft = ok_ft and ft or ""
                if ft ~= M.config.naming.rule and ft ~= M.config.naming.result then
                    local rel_path = vim.fn.fnamemodify(abs_path, ":.")
                    table.insert(files, rel_path)
                end
            end
        end
    end

    return files
end

local function get_runtime_opts(rule_buf)
    local args_common = { M.config.rg.cmd }
    for _, a in ipairs(M.config.rg.args) do
        table.insert(args_common, a)
    end

    -- exclude rule/result file
    table.insert(args_common, '-g')
    table.insert(args_common, [[!*.]] .. M.config.naming.rule)
    table.insert(args_common, '-g')
    table.insert(args_common, [[!*.]] .. M.config.naming.result)

    local rule, perr = parse_rule_buf(rule_buf)
    if perr then
        return nil, perr
    end
    for _, pat in ipairs(rule.rg.cmd) do
        table.insert(args_common, pat)
    end

    if rule.file and rule.file.opened_only then
        local files = get_valid_opened_files()
        if next(files) == nil then
            vim.notify("[logana] no valid files opened", vim.log.levels.INFO)
            return nil, {}
        end

        for _, f in ipairs(files) do
            table.insert(args_common, f)
        end
    end

    local ropts = {}
    ropts.args_common = args_common

    return ropts
end

local function refresh_from_rule(rule_buf)
    local ropts, err = get_runtime_opts(rule_buf)
    if err then
        return nil, "get runtime opts failed"
    end

    local start = vim.uv.now()
    local matches, err = collect_matches(ropts)
    if err then
        return nil, "collect_matches failed"
    end
    local stop = vim.uv.now()
    log.trace(string.format("collect_matches took: %d ms", stop - start))

    local rule_abs_path = api.nvim_buf_get_name(rule_buf)
    local rule_prefix = vim.fn.fnamemodify(rule_abs_path, ":t:r")
    local abs_dir_path = vim.fn.fnamemodify(rule_buf, ':p:h')
    local result_abs_path = abs_dir_path .. '/' .. rule_prefix .. '.' .. M.config.naming.result
    local result_buf = vim.fn.bufnr(result_abs_path)
    if result_buf == -1 then
        -- buf not open for this result file
        -- check if result file exists
        local ok, stats = pcall(vim.uv.fs_stat, result_abs_path)
        local exists_on_disk = ok and stats ~= nil
        if exists_on_disk == true then
            result_buf = vim.fn.bufadd(result_abs_path)
            vim.fn.bufload(result_buf)
        else
            result_buf = create_normal_buffer(rule_prefix .. '.' .. M.config.naming.result, M.config.naming.result)
        end
    end

    local start = vim.uv.now()
    render_results(result_buf, matches, vim.fn.bufwinid(rule_buf))
    local stop = vim.uv.now()
    log.trace(string.format("render_results took: %d ms", stop - start))
end

local function initialize_rule_buffer(rule_buf)
    local curr = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local empty = (#curr == 0) or (#curr == 1 and curr[1] == "")
    if empty then
        api.nvim_buf_set_lines(rule_buf, 0, -1, false, vim.split(M.config.rule_template, '\n'))
    end
end

local function result_buffer_jump(result_buf)
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

    local stat1 = vim.uv.fs_stat(file)
    if not stat1 then
        vim.notify(("[logana] did file: %s not exist"):format(file), vim.log.levels.INFO)
        return
    end

    local target_buf = vim.fn.bufnr(file)
    if target_buf == -1 then
        target_buf = vim.fn.bufadd(file)
        vim.fn.bufload(target_buf)
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

    -- buffer naming per config
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
                    local exists_on_disk = ok and stats ~= nil
                    if exists_on_disk == false then
                        -- file not exists, skip prompt for saving
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

-- Utility helpers for external control
function M.is_rule_buffer(buf)
    local ok, ft = pcall(api.nvim_get_option_value, "filetype", { buf = buf })
    return ok and ft == M.config.naming.rule
end

function M.open(opts)
    -- buffer naming per config
    local naming = M.config.naming
    local suffix_rule = naming.rule
    local suffix_result = naming.result

    local prefix = ''
    local rule_buf = nil
    while true do
        prefix = get_prefix_and_increase()
        local rule_name = ("%s.%s"):format(prefix, suffix_rule)

        local ok, stats = pcall(vim.uv.fs_stat, rule_name)
        local exists_on_disk = ok and stats ~= nil
        if exists_on_disk == true then
            -- goto get next
        else
            rule_buf = create_normal_buffer(rule_name, naming.rule)
            initialize_rule_buffer(rule_buf)
            break
        end
    end

    -- Windows layout (default behavior; config-driven layout can be expanded later)
    local rule_win = api.nvim_open_win(rule_buf, true, { split = 'right', win = 0, })
    if M.config.result_win.behavior == 'open_with_rule' then
        local result_name = ("%s.%s"):format(prefix, suffix_result)
        local result_abs_path = vim.fn.fnamemodify(result_name, ':p')
        local result_buf = vim.fn.bufnr(result_abs_path)
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
