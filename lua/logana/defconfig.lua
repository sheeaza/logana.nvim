local M = {
    rg = {
        cmd = 'rg', -- you can set your 'rg' path here
        args = { "--no-config" }, -- extra args; the output format flags are set by logana
    },

    -- level 1: every [rg] match shares this one color.
    -- fixed colors (fg and bg), so they look the same with every colorscheme;
    -- any nvim_set_hl spec works here, e.g. { link = "DiffAdd" } to follow the theme
    match_color = { fg = "#ffffff", bg = "#8a8a8a", bold = true },

    -- level 2: one color per line under [highlight], cycling through this list
    -- if there are more lines than colors
    highlight_colors = {
        { fg = "#000000", bg = "#ffd75f" }, -- yellow
        { fg = "#000000", bg = "#87d787" }, -- green
        { fg = "#000000", bg = "#87afff" }, -- blue
        { fg = "#000000", bg = "#ff8787" }, -- red
        { fg = "#000000", bg = "#d7afff" }, -- purple
        { fg = "#000000", bg = "#5fd7d7" }, -- cyan
        { fg = "#000000", bg = "#ffaf5f" }, -- orange
        { fg = "#000000", bg = "#ff87d7" }, -- pink
        { fg = "#000000", bg = "#afd700" }, -- lime
        { fg = "#000000", bg = "#d7af87" }, -- tan
    },

    -- shown in a float at the right end of the rule window's last line, above its
    -- statusline, while results are loading, with the number of lines loaded so
    -- far. set to false to disable
    spinner = {
        frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
        interval = 80, -- ms per frame
    },

    -- at the end of each [rg] line with a -e/-f and each colored [highlight] line in
    -- the rule buffer: how many result lines it matches, counted after a refresh.
    -- false to turn off
    hit_count = true,

    highlight = {
        -- true: [highlight] colors also in the windows of a result's source files,
        -- from their rule buffer, for the lines on screen ([rg] colors only in the result)
        hl_buf = true,
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

        -- moving to another line in the result window also moves the cursor of the
        -- source file's window, if the current tab has one (the first one). false to
        -- turn off; <Enter> still goes to that window
        follow = true,
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
# a line with only flags (no -e/-f) gets no color; its flags are put in front
# of every pattern line. e.g.
#    --smart-case
#    -e 'error'
#    -i -e 'retry'
# gives two colors: "--smart-case -e 'error'" and "--smart-case -i -e 'retry'"
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
