-- logana.nvim loader and unified user command
-- This file defines :Logana (with optional subcmds like "refresh") and initializes the plugin.

local api = vim.api

local function notify_err(msg)
    vim.notify("[logana] " .. msg, vim.log.levels.ERROR)
end

-- :Logana [subcmd]
-- Unified command. Behavior:
-- - If current buffer is a Logana rule buffer: ensure result buffer exists and refresh.
-- - Otherwise: open rule/result panes bound to the current buffer (or bufnr if numeric arg provided).
-- Optional subcmds: "refresh" (equivalent to being in rule buffer and refreshing).
vim.api.nvim_create_user_command("Logana", function(opts)
    local ok, logana = pcall(require, "logana")
    if not ok then
        notify_err("module not found. Ensure lua/logana/init.lua is on runtimepath.")
        return
    end

    local arg = opts and opts.args or ""
    local curbuf = api.nvim_get_current_buf()

    -- If current buffer is a rule buffer: ensure result exists and refresh
    if logana.is_rule_buffer(curbuf) then
        logana.ensure_result_for_rule(curbuf)
        logana.refresh()
        return
    end

    logana.open()
end, {
nargs = "?",
desc = 'Logana: context-aware; "refresh" subcmd forces refresh, otherwise open or refresh depending on current buffer',
})
