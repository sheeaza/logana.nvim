-- entry point: setup(), the rule/result buffer autocmds and keymaps, refresh()
local api = vim.api
local fn = vim.fn
local config = require('logana.config')
local highlight = require('logana.highlight')
local refresh = require('logana.refresh')
local rule = require('logana.rule')
local result = require('logana.result')
local fold = require('logana.fold')

local M = {}
M.config = config

-- exposed for tests only
M._result_highlights = highlight.by_buf
M._source_highlights = highlight.source_by_buf
M._match_ranges = highlight.match_ranges
function M._busy(rule_buf)
    local st = refresh.state[rule_buf]
    return st ~= nil and st.job ~= nil
end
function M._counting(rule_buf)
    local st = refresh.state[rule_buf]
    return st ~= nil and require('logana.count').busy(st)
end
M._count_ns = require('logana.count').ns

local function setup_config(opts)
    local defconfig = require('logana.defconfig')
    -- filled in place, the modules keep a reference to this table
    local merged = vim.tbl_deep_extend("force", defconfig, opts or {})
    for k in pairs(config) do
        config[k] = nil
    end
    for k, v in pairs(merged) do
        config[k] = v
    end

    if fn.executable(config.rg.cmd) ~= 1 then
        error("[logana] ripgrep (" .. config.rg.cmd .. ") not found in PATH")
    end

    highlight.setup_highlights()

    vim.filetype.add({
        extension = {
            [config.naming.rule] = config.naming.rule,
            [config.naming.result] = config.naming.result,
        },
    })
end

-- the rule buffer of a result buffer: the one it was last rendered from, else the
-- loaded rule file next to it with the same name
local function rule_buf_of_result(result_buf)
    local rule_buf = refresh.rule_state_of_result(result_buf)
    if rule_buf then
        return rule_buf
    end
    local name = fn.fnamemodify(api.nvim_buf_get_name(result_buf), ':r') .. '.' .. config.naming.rule
    local b = fn.bufnr(name)
    if b ~= -1 and api.nvim_buf_is_loaded(b) then
        return b
    end
end

-- the rule args of the [highlight] color shown where the selection is, the one
-- drawn on top if several (the last). nil if none, or the row's colors aren't in
-- yet: then none is shown either
local function rule_under_selection(hls, pos)
    local s, e = pos[1][1], pos[1][2]
    local marks = hls and hls.hl[s[2] - 1]
    if not marks then
        return nil
    end
    -- getregionpos: 1-based, the end on the last byte; marks: 0-based, end exclusive
    local from, to = s[3] - 1, e[3]
    for k = #marks, 1, -1 do
        local m = marks[k]
        if m[1] <= from and to <= m[2] then
            return hls.hl_rules[m[3]]
        end
    end
end

-- visual <Enter> in a result or source buffer: inside a [highlight] color, its
-- line is removed; else the selected text goes in or out of [highlight]. the
-- colors follow, only level 2 reruns, not a full refresh. find() gives the rule
-- buffer and the colors shown in the buffer (nil if none)
local function toggle_selection(find)
    local buf = api.nvim_get_current_buf()
    local opts = { type = fn.mode() }
    local region = fn.getregion(fn.getpos('v'), fn.getpos('.'), opts)
    local pos = fn.getregionpos(fn.getpos('v'), fn.getpos('.'), opts)
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
    if #region ~= 1 then
        vim.notify("[logana] only single line selections are supported", vim.log.levels.INFO)
        return
    end
    if region[1] == '' then
        return
    end
    local rule_buf, hls = find(buf)
    if not rule_buf then
        vim.notify("[logana] no rule buffer found for this buffer", vim.log.levels.INFO)
        return
    end
    -- matched by args, not the color's line number: the rule buffer may have changed
    -- since the colors were computed. no longer there: toggle the text instead
    local args = rule_under_selection(hls, pos)
    if args and rule.remove_highlight_rule(rule_buf, args) then
        return refresh.refresh_highlight(rule_buf)
    end
    rule.toggle_highlight(rule_buf, region[1], function(changed)
        if changed ~= nil then
            refresh.refresh_highlight(rule_buf)
        end
    end)
end

local function toggle_result_selection()
    toggle_selection(function(buf)
        return rule_buf_of_result(buf), highlight.by_buf[buf]
    end)
end

-- in a source: its rule buffer and colors as its windows show them. no longer
-- a source: the key does what it does without the mapping
local function toggle_source_selection()
    local buf = api.nvim_get_current_buf()
    local rule_buf, from = highlight.source_of(buf)
    if not rule_buf then
        local key = api.nvim_replace_termcodes(config.key.toggle_highlight, true, false, true)
        return api.nvim_feedkeys(key, 'n', false)
    end
    toggle_selection(function()
        local hls = highlight.source_by_buf[buf]
        return rule_buf, hls and hls.from == from and hls.hl_rules == from.hl_rules and hls or nil
    end)
end

local function setup_keybinding()
    if M._quit_auto then
        return
    end

    -- a buffer seen as a source of a rule buffer's result gets the visual toggle,
    -- buffer-local: the user's other buffers keep their own <Enter>
    highlight.on_source = function(buf)
        vim.keymap.set("x", config.key.toggle_highlight, toggle_source_selection,
            { buffer = buf, noremap = true, silent = true, desc = "logana: toggle highlight of selection" })
    end

    -- Suppress save prompts on quit for rule/result buffers by marking them nomodified
    M._quit_auto = api.nvim_create_augroup("logana_quit_guard", { clear = true })

    -- Disable swapfile for rule/result files regardless of how the buffer is opened
    -- (create_normal_buffer covers plugin-created buffers, but this covers e.g. a
    -- user directly `:e`-ing an existing saved rule/result file). Must run on
    -- BufReadPre/BufNewFile, before Neovim creates the swap file, not FileType.
    api.nvim_create_autocmd({ "BufNewFile", "BufReadPre" }, {
        group = M._quit_auto,
        pattern = { '*.' .. config.naming.rule, '*.' .. config.naming.result },
        command = "setlocal noswapfile",
        desc = "logana: disable swapfile for rule/result files",
    })

    api.nvim_create_autocmd("BufWipeout", {
        group = M._quit_auto,
        callback = function(ev)
            refresh.forget(ev.buf)
        end,
        desc = "logana: free the state of a wiped rule/result buffer",
    })

    api.nvim_create_autocmd("TabEnter", {
        group = M._quit_auto,
        callback = function()
            refresh.bind_tab()
        end,
        desc = "logana: source files take the colors of the tab's rule buffer",
    })

    api.nvim_create_autocmd("QuitPre", {
        group = M._quit_auto,
        callback = function()
            for _, b in ipairs(api.nvim_list_bufs()) do
                local ft = vim.bo[b].filetype
                if (ft == config.naming.rule or ft == config.naming.result)
                    and not vim.uv.fs_stat(api.nvim_buf_get_name(b)) then
                    pcall(api.nvim_set_option_value, "modified", false, { buf = b })
                end
            end
        end,
        desc = "logana: mark rule/result buffers as nomodified on QuitPre",
    })

    api.nvim_create_autocmd("FileType", {
        group = M._quit_auto,
        pattern = config.naming.rule,
        callback = function(ev)
            rule.initialize_rule_buffer(ev.buf)
            vim.keymap.set("n", config.key.rule_refresh, function()
                refresh.refresh_from_rule(ev.buf)
            end, { buffer = ev.buf, noremap = true, silent = true, desc = "logana: refresh results" })
        end,
        desc = "logana: template and keybinding for rule file",
    })

    api.nvim_create_autocmd("FileType", {
        group = M._quit_auto,
        pattern = config.naming.result,
        callback = function(ev)
            vim.keymap.set("n", config.key.result_jump, result.result_buffer_jump,
                { buffer = ev.buf, noremap = true, silent = true, desc = "logana: results jump" })
            vim.keymap.set("x", config.key.toggle_highlight, toggle_result_selection,
                { buffer = ev.buf, noremap = true, silent = true, desc = "logana: toggle highlight of selection" })

            local group = api.nvim_create_augroup("logana_result_" .. ev.buf, { clear = true })
            api.nvim_create_autocmd("WinEnter", {
                group = group,
                buffer = ev.buf,
                callback = result.follow_enter,
                desc = "logana: the result row the cursor entered at",
            })
            api.nvim_create_autocmd("CursorMoved", {
                group = group,
                buffer = ev.buf,
                callback = result.follow,
                desc = "logana: move the source window's cursor with the result's",
            })
            api.nvim_create_autocmd("BufWinEnter", {
                group = group,
                buffer = ev.buf,
                callback = function()
                    local rule_buf, st = refresh.rule_state_of_result(ev.buf)
                    if rule_buf then
                        fold.restore_folds(rule_buf, st)
                    else
                        for _, win in ipairs(fn.win_findbuf(ev.buf)) do
                            fold.setup_fold_win(win)
                        end
                    end
                end,
                desc = "logana: fold result buffer by file",
            })
            api.nvim_create_autocmd("WinLeave", {
                group = group,
                buffer = ev.buf,
                callback = function()
                    local rule_buf, st = refresh.rule_state_of_result(ev.buf)
                    if rule_buf then
                        fold.save_folds(rule_buf, st, api.nvim_get_current_win())
                    end
                end,
                desc = "logana: save result folds to the rule buffer",
            })
        end,
        desc = "logana: keybinding for jumping in result buf",
    })
end

-- same as pressing <Enter> in rule_buf. results load asynchronously; on_done is
-- called once they and their folds are applied, level 2 comes as rows are drawn (not when the
-- refresh fails, finds no match, or is superseded by another one)
function M.refresh(rule_buf, on_done)
    return refresh.refresh_from_rule(rule_buf, on_done)
end

function M.setup(opts)
    setup_config(opts)
    setup_keybinding()
end

return M
