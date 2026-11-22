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

-- the header rows of an edited result, { { <1-based row>, <path> }, ... } as
-- level 1's file_rows, found again only when the buffer changed
local EDITED_ROWS = setmetatable({}, { __mode = 'k' })

local function edited_rows(buf)
    local tick = api.nvim_buf_get_changedtick(buf)
    local c = EDITED_ROWS[buf]
    if not c or c.tick ~= tick then
        local rows = {}
        for _, m in ipairs(fn.matchbufline(buf, [[^file: \zs.\+$]], 1, '$')) do
            rows[#rows + 1] = { m.lnum, m.text }
        end
        c = { tick = tick, rows = rows }
        EDITED_ROWS[buf] = c
    end
    return c.rows
end

-- the path in the 'file: ' header at or above 1-based row of result buffer buf.
-- from the header rows level 1 recorded (so far, while it loads), when they match
-- the buffer (not edited): a search back from a row of a big one-file result goes
-- over every row above it
local function header_of_row(buf, row)
    -- required here, refresh requires this module
    local _, st = require('logana.refresh').rule_state_of_result(buf)
    -- a level 1 run replaces the buffer at its first batch (job.started)
    local rows = st and not st.result_dirty
        and (st.job and st.job.started and st.job.parser.file_rows or st.file_rows)
    rows = rows or edited_rows(buf)
    -- the last header at or above row
    local lo, hi = 1, #rows
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if rows[mid][1] <= row then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return rows[hi] and rows[hi][2]
end

-- the winbar of a result window: the 'file: ' header of its top row's file, so
-- the file of the rows on screen shows while its header is scrolled off. an
-- expression, evaluated on each redraw of the window
local WINBAR = "%{%v:lua.require'logana.result'.winbar()%}"

-- (%{} items: the window drawn is the current one meanwhile). an error here
-- would come on every redraw, none gets out
function M.winbar()
    local ok, file = pcall(header_of_row, api.nvim_get_current_buf(), fn.line('w0'))
    return ok and file and ("file: " .. file):gsub('%%', '%%%%') or ''
end

-- BufWinEnter: the window shows a result buffer, it gets the winbar; it shows
-- another buffer (e.g. a source opened by <Enter>), the one put by logana goes
-- back to the global value
local function update_winbar(buf, win)
    if vim.bo[buf].filetype == config.naming.result and config.result_win.sticky_header then
        vim.wo[win].winbar = WINBAR
    elseif vim.wo[win].winbar == WINBAR then
        vim.wo[win].winbar = vim.go.winbar
    end
end

-- the source of the cursor's row in the current (result) buffer: file, line and
-- col (0-based) in it; nil and why when the row isn't a matched line
local function row_source()
    local line = api.nvim_get_current_line()
    local lnum_str = line:match("^(%d+):")
    if not lnum_str then
        return nil, "not at matched line"
    end
    local cursor = api.nvim_win_get_cursor(0)
    local col = math.max(0, cursor[2] - #lnum_str - 2) -- -2 for ':' and ' '
    local file = header_of_row(api.nvim_get_current_buf(), cursor[1])
    if not file or file == '' then
        return nil, "did not find 'file:'"
    end
    return file, tonumber(lnum_str), col
end

-- the first window of the current tab showing file, other than the current one.
-- by full path: bufnr() takes a pattern, 'a.log' would also find 'ba.log'
local function source_win(file)
    local path = fn.fnamemodify(file, ':p')
    local cur = api.nvim_get_current_win()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if win ~= cur and api.nvim_buf_get_name(api.nvim_win_get_buf(win)) == path then
            return win
        end
    end
end

local function result_buffer_jump()
    local file, lnum, col = row_source()
    if not file then
        vim.notify("[logana] " .. lnum, vim.log.levels.INFO)
        return
    end

    if not vim.uv.fs_stat(file) then
        vim.notify(("[logana] file: %s does not exist"):format(file), vim.log.levels.INFO)
        return
    end

    local src_win = source_win(file)
    if src_win then
        -- the file is already shown in this tab: go there, the result stays
        api.nvim_set_current_win(src_win)
        vim.cmd("normal! m'")
        pcall(api.nvim_win_set_cursor, src_win, { lnum, col })
        return
    end

    -- an existing buffer of exactly that file, or a new one. bufadd leaves a new
    -- buffer unlisted, list it as :edit would
    local target_buf = fn.bufadd(file)
    fn.bufload(target_buf)
    vim.bo[target_buf].buflisted = true
    local win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, target_buf)
    pcall(api.nvim_win_set_cursor, win, { lnum, col })
end

-- follow: the result window's cursor moved to another row, move the cursor of the
-- source file's window in this tab to it too, staying in the result window. only
-- on a row change, CursorMoved also fires on entering a window: after moving in
-- the source window, going back to the result doesn't undo it. the window's last
-- followed row covers that; follow_enter, on WinEnter (before that CursorMoved),
-- also covers a window entered with no row followed yet, e.g. its cursor set by code
local function follow_enter()
    vim.w.logana_follow_row = api.nvim_win_get_cursor(0)[1]
end

local function follow()
    local row = api.nvim_win_get_cursor(0)[1]
    if vim.w.logana_follow_row == row then
        return
    end
    vim.w.logana_follow_row = row
    if not config.result_win.follow then
        return
    end
    local file, lnum, col = row_source()
    local src_win = file and source_win(file)
    if src_win then
        pcall(api.nvim_win_set_cursor, src_win, { lnum, col })
    end
end

M.get_result_buf = get_result_buf
M.show_result = show_result
M.result_buffer_jump = result_buffer_jump
M.update_winbar = update_winbar
M.follow_enter = follow_enter
M.follow = follow
return M
