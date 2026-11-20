-- the result buffer and its window, and jumping from it to the source line
local api = vim.api
local fn = vim.fn
local config = require('logana.config')
local log = require('logana.log')
local now_ms = require('logana.util').now_ms

local M = {}

local SPLIT_DIR = { top = 'below', bottom = 'above', left = 'right', right = 'left' }

local function set_buf_opts(buf, opts)
    for k, v in pairs(opts) do
        api.nvim_set_option_value(k, v, { buf = buf })
    end
end

local function create_normal_buffer(name, filetype)
    local buf = api.nvim_create_buf(true, false) -- [listed=true, scratch=false]
    set_buf_opts(buf, {
        swapfile = false,
        modifiable = true,
        readonly = false,
        filetype = filetype or "",
    })
    -- Set a readable name so users can :w to persist (writes relative to cwd if no path)
    pcall(api.nvim_buf_set_name, buf, name)
    return buf
end

local function result_open_win(result_buf, rule_win)
    if config.result_win.behavior == 'override' then
        api.nvim_win_set_buf(rule_win, result_buf)
        return
    end

    local split = SPLIT_DIR[config.layout.rule_pos] or 'left'
    local t0 = now_ms()
    local result_win = api.nvim_open_win(result_buf, false, { split = split, win = rule_win })
    log.trace(string.format("result_open_win took: %d ms", now_ms() - t0))

    -- rule and result split the space rule_win had; the +1 is the statusline
    -- or vertical separator between them
    local pct = tonumber(config.layout.rule_window)
    if pct and pct > 0 and pct < 100 then
        if split == 'below' or split == 'above' then
            local total = api.nvim_win_get_height(rule_win) + api.nvim_win_get_height(result_win) + 1
            api.nvim_win_set_height(rule_win, math.max(1, math.floor(total * pct / 100)))
        else
            local total = api.nvim_win_get_width(rule_win) + api.nvim_win_get_width(result_win) + 1
            api.nvim_win_set_width(rule_win, math.max(1, math.floor(total * pct / 100)))
        end
    end
end

local function get_result_buf(rule_buf)
    local rule_abs_path = api.nvim_buf_get_name(rule_buf)
    local rule_prefix = fn.fnamemodify(rule_abs_path, ":t:r")
    local rule_dir = fn.fnamemodify(rule_abs_path, ':p:h')
    local result_abs_path = rule_dir .. '/' .. rule_prefix .. '.' .. config.naming.result

    local result_buf = fn.bufnr(result_abs_path)
    if result_buf == -1 then
        if vim.uv.fs_stat(result_abs_path) then
            result_buf = fn.bufadd(result_abs_path)
            fn.bufload(result_buf)
        else
            result_buf = create_normal_buffer(result_abs_path, config.naming.result)
        end
    end
    return result_buf
end

-- show the result buffer if it isn't, e.g. first refresh or its window was closed
local function show_result(rule_buf, result_buf)
    if fn.bufwinid(result_buf) == -1 then
        local rule_win = fn.bufwinid(rule_buf)
        result_open_win(result_buf, rule_win ~= -1 and rule_win or api.nvim_get_current_win())
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

M.get_result_buf = get_result_buf
M.show_result = show_result
M.result_buffer_jump = result_buffer_jump
return M
