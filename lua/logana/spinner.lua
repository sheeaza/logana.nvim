-- the loading spinner in the rule window
local api = vim.api
local fn = vim.fn
local config = require('logana.config')

local M = {}

-- animates config.spinner while level 1 loads, in a float at the right end of
-- the last line of each window showing the rule buffer in the current tabpage,
-- just above its statusline. being a float, it works with any statusline plugin.
-- returns a function that stops it.
local function start_spinner(rule_buf, job)
    local cfg = config.spinner
    if not cfg or not cfg.frames or #cfg.frames == 0 then
        return function() end
    end

    local sbuf = api.nvim_create_buf(false, true)
    local floats = {} -- win showing rule_buf -> float

    local timer = vim.uv.new_timer()
    local frame = 0
    local function draw()
        if not api.nvim_buf_is_valid(rule_buf) then
            return
        end
        frame = frame % #cfg.frames + 1
        local text = ("%s loading %d lines"):format(cfg.frames[frame], job.parser.k)
        api.nvim_buf_set_lines(sbuf, 0, -1, false, { ' ' .. text .. ' ' })
        local width = fn.strdisplaywidth(text) + 2

        -- windows can be split, closed or resized while loading, place them again
        local tab, seen = api.nvim_get_current_tabpage(), {}
        for _, win in ipairs(fn.win_findbuf(rule_buf)) do
            if api.nvim_win_get_tabpage(win) == tab then
                seen[win] = true
                -- the last line of the window, right-aligned
                local conf = { relative = 'win', win = win, row = api.nvim_win_get_height(win) - 1,
                    col = math.max(api.nvim_win_get_width(win) - width, 0), width = width, height = 1 }
                local f = floats[win]
                if f and api.nvim_win_is_valid(f) then
                    api.nvim_win_set_config(f, conf)
                else
                    conf.style, conf.focusable, conf.zindex, conf.noautocmd = 'minimal', false, 60, true
                    f = api.nvim_open_win(sbuf, false, conf)
                    vim.wo[f].winhighlight = 'Normal:StatusLine'
                    floats[win] = f
                end
            end
        end
        for key, f in pairs(floats) do
            if not seen[key] then
                pcall(api.nvim_win_close, f, true)
                floats[key] = nil
            end
        end
    end
    draw()
    local interval = cfg.interval or 80
    timer:start(interval, interval, vim.schedule_wrap(function()
        if not timer:is_closing() then
            draw()
        end
    end))
    return function()
        if not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        for _, f in pairs(floats) do
            pcall(api.nvim_win_close, f, true)
        end
        if api.nvim_buf_is_valid(sbuf) then
            api.nvim_buf_delete(sbuf, { force = true })
        end
    end
end

M.start_spinner = start_spinner
return M
