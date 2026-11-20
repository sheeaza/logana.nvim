-- folding the result buffer by file, kept in the rule buffer's [fold] section
local api = vim.api
local fn = vim.fn

local M = {}

-- folding: each 'file: ' header in a result buffer starts a fold that runs to the
-- next header. which files are folded is kept in the rule buffer's [fold] section
-- (one file per line), so it survives refreshes and is saved with the rule file.
-- folds are manual, made from the header rows recorded at render time, since
-- foldexpr is evaluated per line and made refreshing a large result ~30% slower.

local function setup_fold_win(win)
    api.nvim_set_option_value('foldmethod', 'manual', { win = win, scope = 'local' })
    api.nvim_set_option_value('foldenable', true, { win = win, scope = 'local' })
end

-- returns the [fold] lines, and the 0-based [start, end) range of its body
-- (nil when there is no [fold] section)
local function read_fold_section(rule_buf)
    local lines = api.nvim_buf_get_lines(rule_buf, 0, -1, false)
    local files, body_start, body_end = {}, nil, #lines
    for i, line in ipairs(lines) do
        local section = line:match("^%s*%[(.+)%]%s*$")
        if section then
            if body_start then
                body_end = i - 1
                break
            end
            if section == 'fold' then
                body_start = i
            end
        elseif body_start and not line:match("^%s*$") and not line:match("^%s*#") then
            table.insert(files, vim.trim(line))
        end
    end
    -- keep the blank line separating [fold] from a following section
    while body_start and body_end > body_start and lines[body_end]:match("^%s*$") do
        body_end = body_end - 1
    end
    return files, body_start, body_end
end

local function write_fold_section(rule_buf, files)
    local cur, body_start, body_end = read_fold_section(rule_buf)
    if vim.deep_equal(cur, files) then
        return
    end
    if body_start then
        -- comments in the section are dropped along with the old entries
        api.nvim_buf_set_lines(rule_buf, body_start, body_end, false, files)
    elseif #files > 0 then
        local new = { '', '[fold]' }
        vim.list_extend(new, files)
        api.nvim_buf_set_lines(rule_buf, -1, -1, false, new)
    end
end

-- folded files in win; nil when the rows from the last render can't be trusted
local function capture_folds(st, win)
    if st.job or st.result_dirty or not st.file_rows then
        return nil
    end
    local files = {}
    api.nvim_win_call(win, function()
        if not vim.wo.foldenable then
            return
        end
        for _, fr in ipairs(st.file_rows) do
            if fn.foldclosed(fr[1]) ~= -1 then
                table.insert(files, fr[2])
            end
        end
    end)
    return files
end

local function apply_folds(st, win, files)
    if st.job or st.result_dirty or not st.file_rows then
        return
    end
    setup_fold_win(win)
    local closed = {}
    for _, f in ipairs(files) do
        closed[f] = true
    end
    local rows = st.file_rows
    local last = api.nvim_buf_line_count(st.result_buf)
    api.nvim_win_call(win, function()
        vim.cmd('silent! normal! zE')
        for i, fr in ipairs(rows) do
            local fold_end = rows[i + 1] and rows[i + 1][1] - 1 or last
            -- ':fold' leaves the new fold closed
            vim.cmd(('silent! %d,%dfold'):format(fr[1], fold_end))
            if not closed[fr[2]] then
                vim.cmd(('silent! %dfoldopen'):format(fr[1]))
            end
        end
    end)
end

-- result window -> rule buffer: record which files are folded in win
local function save_folds(rule_buf, st, win)
    local files = capture_folds(st, win)
    if files then
        write_fold_section(rule_buf, files)
        st.fold_sig = table.concat(files, '\n')
    end
end

-- rule buffer -> result windows
local function restore_folds(rule_buf, st)
    local files = read_fold_section(rule_buf)
    for _, win in ipairs(fn.win_findbuf(st.result_buf)) do
        apply_folds(st, win, files)
    end
    st.fold_sig = table.concat(files, '\n')
end

M.setup_fold_win = setup_fold_win
M.read_fold_section = read_fold_section
M.save_folds = save_folds
M.restore_folds = restore_folds
return M
