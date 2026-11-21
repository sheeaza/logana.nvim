local M = {
    rg = {
        cmd = 'rg', -- you can set your 'rg' path here
        args = { "--no-config" }, -- extra args; the output format flags are set by logana
    },

    -- level 1: every [rg] match shares this one color
    match_color = {
         link = "TermCursor",
    },

    -- level 2: one color per line under [highlight], cycling through this list
    -- if there are more lines than colors
    highlight_colors = {
        { link = "IncSearch" },
        { link = "DiffAdd" },
        { link = "DiffChange" },
        { link = "DiffText" },
        { link = "Substitute" },
        { link = "MatchParen" },
    },

    -- shown in a float at the right end of the rule window's last line, above its
    -- statusline, while results are loading, with the number of lines loaded so
    -- far. set to false to disable
    spinner = {
        frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
        interval = 80, -- ms per frame
    },

    highlight = {
        hl_buf = true,   -- true: also highlight normal buffers, except logana buffers. false: ...
        hl_result = true,-- true: highlight for result buffers. false: ...
    },

    -- layout of the rule and result windows, used when <Enter> in a rule buffer
    -- opens its result buffer
    layout = {
        -- rule_pos: define rule and result layout
        --  'top': rule on top, result on bottom
        --  'bottom': rule on ..
        --  'left': rule on left, result ...
        --  'right': rule on...
        rule_pos = 'top',

        -- percentage of rule and result window, result window wil be set to '1 - rule_window'
        rule_window = '20',
    },

    result_win = {
        -- how <Enter> in a rule buffer shows its result buffer, if it isn't shown yet
        -- 'split': split the rule window, see 'layout'
        -- 'override': show it in the rule window, 'layout' will be ignored
        behavior = 'split',
    },

    -- file extensions, also used as the filetypes. any file named <name>.<rule> is a
    -- rule buffer (e.g. ':e cam.logana_rule'), and its results go to <name>.<result>
    -- in the same directory (cam.logana_result)
    naming = {
        rule = 'logana_rule',
        result = 'logana_result',
    },

    -- help text put to rule buffer
    rule_template = [[
# below is rg cmd args
# Press <Enter> in this buffer to refresh results.
# Example:
#    -e 'abc'
#    -e '.*ui'
#    -g '*.log'
[rg]
--smart-case

[file]
opened_only = true

# below are rg args matched against the result lines, one color per line
# Example:
#    -e 'error'
#    -i -e 'timeout' -e 'retry'
# a line with only flags (no pattern) applies to every line
[highlight]
--smart-case

# files folded in the result buffer, one per line, kept in sync with the result window
# Example:
#    [fold]
#    a.log
#    logs/b.log
[fold]
]],

    key = {
        rule_refresh = '<cr>',
        result_jump = '<cr>',
        -- visual mode in a result buffer: add the selected text to [highlight], or
        -- remove it if it's there
        result_toggle_highlight = '<cr>',
    },
}

return M
