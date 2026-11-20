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
M._match_ranges = highlight.match_ranges
function M._busy(rule_buf)
    local st = refresh.state[rule_buf]
    return st ~= nil and st.job ~= nil
end

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

local function setup_keybinding()
    if M._quit_auto then
        return
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

    api.nvim_create_autocmd("QuitPre", {
        group = M._quit_auto,
        callback = function()
            for _, b in ipairs(api.nvim_list_bufs()) do
                local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = b })
                ft = ok_ft and ft or ""
                if ft == config.naming.rule or ft == config.naming.result then
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

            local group = api.nvim_create_augroup("logana_fold_" .. ev.buf, { clear = true })
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
