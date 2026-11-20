-- level 1 with LuaJIT: the ffi scanner, and putting its lines in the buffer
local api = vim.api
local fn = vim.fn

local M = {}

-- with LuaJIT, level 1 is scanned byte by byte through the ffi instead, and the
-- result lines go to the buffer with ':read' from a temp file, made in C: no lua
-- string per line, which is most of level1.parse_batch's cost. ~3x faster level 1.
local has_ffi, ffi = pcall(require, 'ffi')
M.enabled = has_ffi -- tests turn it off to cover the lua parser
if has_ffi then
    -- each on its own, another plugin may have declared some already
    for _, decl in ipairs({ 'void *fopen(const char *path, const char *mode);',
        'size_t fwrite(const void *buf, size_t size, size_t n, void *f);', 'int fclose(void *f);',
        -- linux only. long is off_t for the unsuffixed symbols, also on 32 bit
        'int memfd_create(const char *name, unsigned int flags);', 'int ftruncate(int fd, long len);',
        'long pwrite(int fd, const void *buf, size_t n, long off);' }) do
        pcall(ffi.cdef, decl)
    end
end

local function copy_bytes(dst, o, src, s, e)
    for j = s, e - 1 do
        dst[o] = src[j]
        o = o + 1
    end
    return o
end

-- same as level1.parse_batch, but appends the buffer lines to p.out, p.o bytes so far,
-- for read_scanned. headers are found by comparing each line's path with the
-- previous one, kept in p.path
local function scan_batch(p, data)
    local n = #data
    -- a line grows by at most the 'file: ' header and blank line before it
    if p.cap < p.o + 3 * n + 16 then
        p.cap = 2 * (p.o + 3 * n + 16)
        local grown = ffi.new('uint8_t[?]', p.cap)
        ffi.copy(grown, p.out, p.o)
        p.out = grown
    end
    local out = p.out
    local src = ffi.cast('const uint8_t *', data)
    local row, k = p.n, p.k
    local file_rows = p.file_rows
    local first, count, cols = p.match.first, p.match.count, p.match.cols
    local nc = #cols
    local i, o = 0, p.o

    while i < n do
        local ps = i
        while src[i] ~= 0 and src[i] ~= 10 do
            i = i + 1
        end
        -- '<path>\0<lnum>: <text>'. context lines ('<lnum>-') and the '--' between
        -- them are skipped
        if src[i] == 0 then
            local plen = i - ps
            i = i + 1
            local ls = i
            while src[i] >= 48 and src[i] <= 57 do
                i = i + 1
            end
            if i > ls and src[i] == 58 and src[i + 1] == 32 then
                i = i + 2
                local same = plen == p.plen
                for j = 0, same and plen - 1 or -1 do
                    if src[ps + j] ~= p.path[j] then
                        same = false
                        break
                    end
                end
                if not same then
                    if p.cur then
                        out[o], o, row = 10, o + 1, row + 1
                    end
                    o = copy_bytes(out, o, ffi.cast('const uint8_t *', 'file: '), 0, 6)
                    o = copy_bytes(out, o, src, ps, ps + plen)
                    out[o], o, row = 10, o + 1, row + 1
                    if plen > p.pcap then
                        p.pcap = 2 * plen
                        p.path = ffi.new('uint8_t[?]', p.pcap)
                    end
                    copy_bytes(p.path, 0, src, ps, ps + plen)
                    p.plen = plen
                    p.cur = ffi.string(src + ps, plen)
                    file_rows[#file_rows + 1] = { row, p.cur }
                end

                local lo = o
                o = copy_bytes(out, o, src, ls, i)
                local c0, ms = nc, nil
                local c = src[i]
                while c ~= 10 do
                    -- markers are dropped; a stray one in a log line only shifts its own columns
                    if c == 30 then
                        ms = o - lo
                    elseif c == 31 then
                        if ms then
                            cols[nc + 1], cols[nc + 2] = ms, o - lo
                            nc, ms = nc + 2, nil
                        end
                    else
                        out[o], o = c, o + 1
                    end
                    i = i + 1
                    c = src[i]
                end
                if nc > c0 then
                    first[row], count[row] = c0 + 1, (nc - c0) / 2
                end
                out[o], o, row, k = 10, o + 1, row + 1, k + 1
            end
        end
        while src[i] ~= 10 do
            i = i + 1
        end
        i = i + 1
    end

    p.n, p.k, p.o = row, k, o
end

-- the file read_scanned puts the lines in for ':read', returns its path and fd:
-- on linux an anonymous memfd, memory backed and gone with neovim, opened once.
-- else a file in the run dir, a tmpfs on most linux systems: on a disk,
-- rewriting the file before each ':read' cost more than the read
local scan_fd
local function scan_tmp()
    if not scan_fd then
        local ok, fd = pcall(function() return ffi.C.memfd_create('logana', 1) end) -- MFD_CLOEXEC
        scan_fd = ok and fd or -1
    end
    if scan_fd >= 0 then
        return '/proc/self/fd/' .. scan_fd, scan_fd
    end
    return ('%s/logana.%d.tmp'):format(fn.stdpath('run'), vim.uv.os_getpid())
end

-- puts the lines scan_batch collected in p.out into buf, replacing its lines or
-- appending to them. ++enc/++bad keep the bytes as they are (++bin would set 'binary')
local function read_scanned(buf, p, replace)
    local tmp, fd = scan_tmp()
    local written
    if fd then
        written = ffi.C.ftruncate(fd, 0) == 0 and tonumber(ffi.C.pwrite(fd, p.out, p.o, 0)) == p.o
    else
        local f = ffi.C.fopen(tmp, 'wb')
        written = f ~= nil and ffi.C.fwrite(p.out, 1, p.o, f) == p.o
        if f ~= nil then
            ffi.C.fclose(f)
        end
    end
    if not written then
        -- slower, but the lines still get in
        local lines = vim.split(ffi.string(p.out, p.o - 1), '\n', { plain = true })
        p.o = 0
        api.nvim_buf_set_lines(buf, replace and 0 or -1, -1, false, lines)
        return
    end
    p.o = 0
    -- ':read' moves the cursor of the window it runs in, keep every window's view
    local views = {}
    for _, win in ipairs(fn.win_findbuf(buf)) do
        views[win] = api.nvim_win_call(win, fn.winsaveview)
    end
    local cmd = 'silent noautocmd keepalt keepjumps %sread ++ff=unix ++enc=utf-8 ++bad=keep '
        .. fn.fnameescape(tmp)
    api.nvim_buf_call(buf, function()
        if replace then
            api.nvim_buf_set_lines(buf, 0, -1, false, {})
            vim.cmd(cmd:format('0'))
            -- the empty line an empty buffer still has
            api.nvim_buf_set_lines(buf, -2, -1, false, {})
        else
            vim.cmd(cmd:format('$'))
        end
    end)
    for win, view in pairs(views) do
        api.nvim_win_call(win, function() fn.winrestview(view) end)
    end
end

-- after a run, frees what the lines of its last ':read' took
local function release()
    local tmp, fd = scan_tmp()
    if fd then
        ffi.C.ftruncate(fd, 0)
    else
        os.remove(tmp)
    end
end

M.scan_batch = scan_batch
M.read_scanned = read_scanned
M.release = release
return M
