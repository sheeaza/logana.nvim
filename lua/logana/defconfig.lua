local M = {
    rg = {
        cmd = 'rg', -- you can set your 'rg' path here
        args = { "--json", "--no-config", "--color", "never" },
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

    highlight = {
        hl_buf = true,   -- true: also highlight normal buffers, except logana buffers. false: ...
        hl_result = true,-- true: highlight for result buffers. false: ...
    },

    -- layout
    -- todo:
    layout = {
        -- rule_pos: define rule and result layout
        --  'top': rule on top, result on bottom
        --  'bottom': rule on ..
        --  'left': rule on left, result ...
        --  'right': rule on...
        rule_pos = 'top',

        -- percentage of rule and result window, result window wil be set to '1 - rule_window'
        rule_window = '50',
    },

    result_win = {
        -- 'open_with_rule': open result window when rule window opened.
        -- 'hide_at_first': do not open with rule window. will open at rule window refresh
        -- 'override': result window will override rule window, 'layout' will be ignored
        behavior = 'open_with_rule',
    },

    -- name assigned to rule/result buffer, will also set them to buffer type
    -- note: logana_rule_<prefix> will bind to logana_result_<prefix>
    --  like: logana_rule_0  <==> logana_result_0
    --
    -- user can also naming prefix on demands on cmd line,
    --  <cmd>: Logana custom
    --  then the rule/result name will be, logana_rule_custom, logana_result_custom
    naming = {
        rule = 'logana_rule',
        result = 'logana_result',

        -- prefix appends to name
        -- 'number': 0, 1, 2, 3...
        -- 'alphabet': a, b, c...
        -- the final name will be: <prefix>.logana_(rule|result)
        -- like: 0.logana_rule, 0.logana_result, a.logana_rule, a.logana_result
        prefix = 'number',
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
]],

    key = {
        rule_refresh = '<cr>',
        result_jump = '<cr>',
    },
}

return M
