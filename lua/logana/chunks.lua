-- level 1 in a fixed file order, on all cores. one rg searches files in parallel
-- and writes each file's matches when its thread is done, so the order of the files
-- changed from run to run; --sort path keeps it but is single-threaded. instead the
-- file list is split into chunks of consecutive files, each searched by its own
-- rg -j1 (which keeps the order it's given), one per core at a time. refresh.lua
-- reads them in order, a chunk being complete once its rg exited
local uv = vim.uv

local M = {}

-- a longer command line takes one rg instead. linux's ARG_MAX is 2 MB by default,
-- the environment counts too
local MAX_ARG_BYTES = 1024 * 1024

-- chunks per rg run at once: chunk 1 should be done soon, then the pump reads what
-- the others found meanwhile, instead of waiting on one slow single-threaded rg
local PER_CORE = 2

-- whether rg args set the thread count or a sort order, then rg runs as given
function M.user_ordered(args)
    for _, a in ipairs(args) do
        if a == '-j' or a:match('^%-j%d') or a:match('^%-%-threads') or a:match('^%-%-sort') then
            return true
        end
    end
    return false
end

-- the paths of 'rg --files --null' output, sorted
function M.parse_files(out)
    local files = {}
    for f in out:gmatch('%Z+') do
        files[#files + 1] = f
    end
    table.sort(files)
    return files
end

-- how many rg run at once: one per core
function M.count()
    return uv.available_parallelism()
end

-- files split into chunks of consecutive files, about equal in bytes (by_size; a
-- directory search can have many files, an fs_stat each took ~10 ms for 3213) or in
-- number, each an rg args list: base with -j1, and its files. nil when a command
-- line gets too long
function M.split(base, files, by_size)
    local sizes, total = {}, 0
    for i, f in ipairs(files) do
        local st = by_size and uv.fs_stat(f)
        sizes[i] = by_size and (st and st.size or 0) or 1
        total = total + sizes[i]
    end
    local n = math.min(PER_CORE * M.count(), #files)
    local base_len = 4 -- '-j1'
    for _, a in ipairs(base) do
        base_len = base_len + #a + 1
    end
    local chunks, cur, len, acc, c = {}, nil, 0, 0, 1
    for i, f in ipairs(files) do
        if not cur then
            cur = vim.list_extend({}, base)
            table.insert(cur, 2, '-j1') -- not after a '--', where it's a path
            len = base_len
        end
        cur[#cur + 1] = f
        len = len + #f + 1
        if len > MAX_ARG_BYTES then
            return nil
        end
        acc = acc + sizes[i]
        -- a chunk ends once the files so far reach its share, the last takes the rest
        if #chunks < n - 1 and acc >= c * total / n then
            chunks[#chunks + 1] = cur
            cur = nil
            while c < n and acc >= c * total / n do
                c = c + 1
            end
        end
    end
    chunks[#chunks + 1] = cur
    return chunks
end

return M
