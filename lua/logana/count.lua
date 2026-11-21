-- hit counts: how many result lines each [rg] and [highlight] rule matches, as
-- virtual text at the end of the rule's line in the rule buffer. one rg --count
-- per rule over the result texts level 1 collected (scan.open_texts), async
local api = vim.api
local config = require('logana.config')
local process = require('logana.proc')

local M = {}

local NS = api.nvim_create_namespace('logana.count')

-- per rule buffer state, in its refresh state as st.counts[kind], kind 'rg' or 'hl':
-- { marks = { [rule idx] = extmark id }, procs = { ... }, left = <rg runs not done> }
-- replaced on every run, the callbacks of an older one see it and do nothing

local function mark_opts(text, group)
    return { virt_text = { { text, group } }, virt_text_pos = 'eol', invalidate = true, undo_restore = false }
end

-- puts the text on the mark, wherever edits moved its line since; a mark whose
-- line was deleted stays hidden
local function update_mark(rule_buf, id, text, group)
    local pos = api.nvim_buf_get_extmark_by_id(rule_buf, NS, id, { details = true })
    if not pos[1] or pos[3].invalid then
        return
    end
    local opts = mark_opts(text, group)
    opts.id = id
    pcall(api.nvim_buf_set_extmark, rule_buf, NS, pos[1], 0, opts)
end

-- stops the counts of one kind and removes their marks
local function stop(rule_buf, st, kind)
    local c = st.counts and st.counts[kind]
    if not c then
        return
    end
    st.counts[kind] = nil
    for _, p in pairs(c.procs) do
        pcall(p.kill, p, 15)
    end
    if api.nvim_buf_is_valid(rule_buf) then
        for _, id in pairs(c.marks) do
            pcall(api.nvim_buf_del_extmark, rule_buf, NS, id)
        end
    end
end

local function stop_all(rule_buf, st)
    stop(rule_buf, st, 'rg')
    stop(rule_buf, st, 'hl')
end

-- counts rules ({ args, lnum, group }, see rule.lua) over st.texts, replacing the
-- counts of that kind. nothing when turned off or there are no texts
local function run(rule_buf, st, kind, rules)
    stop(rule_buf, st, kind)
    local texts = st.texts
    if not config.hit_count or #rules == 0 or not texts or texts.failed
        or not api.nvim_buf_is_valid(rule_buf) then
        return
    end
    local c = { marks = {}, procs = {}, left = 0 }
    st.counts = st.counts or {}
    st.counts[kind] = c
    local line_count = api.nvim_buf_line_count(rule_buf)

    for i, r in ipairs(rules) do
        if r.lnum <= line_count then
            local ok, id = pcall(api.nvim_buf_set_extmark, rule_buf, NS, r.lnum - 1, 0, mark_opts(' … ', 'Comment'))
            if ok then
                c.marks[i] = id
                local args = { config.rg.cmd, '--color', 'never', '--no-filename' }
                vim.list_extend(args, r.args)
                vim.list_extend(args, { '--count', texts.path })
                c.left = c.left + 1
                local ran, proc = pcall(process.system, args, { text = true }, function(res)
                    vim.schedule(function()
                        if st.counts == nil or st.counts[kind] ~= c then
                            return
                        end
                        c.procs[i] = nil
                        c.left = c.left - 1
                        if not api.nvim_buf_is_valid(rule_buf) then
                            return
                        end
                        -- rg exits 1 when nothing matched
                        local n = res.code == 0 and res.stdout:match('%d+') or (res.code == 1 and '0')
                        if n then
                            update_mark(rule_buf, id, ' ' .. n .. ' ', r.group)
                        else
                            update_mark(rule_buf, id, ' ! ', 'WarningMsg')
                        end
                    end)
                end)
                if ran then
                    c.procs[i] = proc
                else
                    c.left = c.left - 1
                    update_mark(rule_buf, id, ' ! ', 'WarningMsg')
                end
            end
        end
    end
end

-- whether counts are still running, for tests
local function busy(st)
    for _, c in pairs(st.counts or {}) do
        if c.left > 0 then
            return true
        end
    end
    return false
end

M.ns = NS
M.run = run
M.stop = stop
M.stop_all = stop_all
M.busy = busy
return M
