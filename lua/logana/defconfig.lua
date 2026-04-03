local M = {
    rg = {
        cmd = 'rg', -- you can set your 'rg' path here
        args = { "--json", "--no-config", "--color", "never" },

        -- smart_case: overridable in rule buffer
        smart_case = true,

        -- whole_word: overridable in rule buffer
        whole_word = false,
    },

    -- source: define what to grep
    source = {
        -- buffer_only:
        --  true: only grep in buffers
        --  false: grep both in buffers and files
        buffer_only = false,
    },

    -- with string, it will link to existing highlight group
    -- with '#', it will took as guibg
    highlight_colors = {
        { "TermCursor" },
        { "DiffText" },
        { "#47b292" },  -- Aqua menthe
        { "#8A2BE2" },  -- Proton purple
        { "#9c4186" },  -- Orange red
        { "#008000" },  -- Office green
        { "#128eb4" },-- Just blue
        { "#fdffe3" },  -- Cosmic latte
        { "#7d5c34" },  -- Fallow brown
        { "#ff9d7f" },  -- Aqua menthe
    },

    highlight = {
        hl_buf = true,   -- true: also highlight normal buffers, except logana buffers. false: ...
        hl_result = true,-- true: highlight for result buffers. false: ...
    },

    layout = {
        -- 'hsplit'
        -- 'vsplit'
        rule_result = 'vsplit',

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
    -- note: logana_rule_<suffix> will bind to logana_result_<suffix>
    --  like: logana_rule_0  <==> logana_result_0
    --
    -- user can also naming suffix on demands on cmd line,
    --  <cmd>: Logana custom
    --  then the rule/result name will be, logana_rule_custom, logana_result_custom
    naming = {
        rule = 'logana_rule',
        result = 'logana_result',

        -- suffix appends to name
        -- 'number': 0, 1, 2, 3...
        -- 'alphabet': a, b, c...
        -- the final name will be: logana_rule|result_<suffix>
        -- like: logana_rule_0, logana_result_0, logana_rule_a, logana_result_a
        suffix = 'number',
    },

    -- help text put to rule buffer
    rule_template = {
        "[pattern]",
        "# Each line is a rg regex wrapped with /<regex>/, to search in the source buffer.",
        "# Press <Enter> in this buffer to refresh results.",
        "# Example: /aa.*[123]/",
        "",
        "",
        "[rule]",
        "smart_case = true",
        "whole_word = false",
        "",
        "",
        "#[highlight]",
        "# similar to [pattern], but this will not used to grep text, only do highlight things",
        "",
        "",
        "#[file_pattern]",
        "# buf_only = false",
        "# pattern: used to match file to grep, if not provided, then will grep all",
        "# pattern = '<regex>'",
    },
}

return M
