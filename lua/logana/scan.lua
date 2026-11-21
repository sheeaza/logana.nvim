-- level 1: the ffi scanner, and putting its lines in the buffer
local api = vim.api
local fn = vim.fn

local M = {}

-- level 1 is scanned byte by byte through the ffi, and the result lines go to the
-- buffer with ':read' from a temp file, made in C: no lua string per line, ~3x
-- faster than a lua gmatch parser. needs LuaJIT, which neovim is built with almost everywhere
local ok, ffi = pcall(require, 'ffi')
if not ok then
    error('[logana] needs a neovim built with LuaJIT')
end
-- each on its own, another plugin may have declared some already
for _, decl in ipairs({ 'void *fopen(const char *path, const char *mode);',
    'size_t fwrite(const void *buf, size_t size, size_t n, void *f);', 'int fclose(void *f);',
    -- linux only. long is off_t for the unsuffixed symbols, also on 32 bit
    'int memfd_create(const char *name, unsigned int flags);', 'int ftruncate(int fd, long len);',
    'long pwrite(int fd, const void *buf, size_t n, long off);',
    'void *memchr(const void *s, int c, size_t n);', 'int memcmp(const void *a, const void *b, size_t n);',
    'void *memrchr(const void *s, int c, size_t n);', 'long pread(int fd, void *buf, size_t n, long off);',
    'int fallocate(int fd, int mode, long off, long len);', 'int close(int fd);',
    'void *memmove(void *dst, const void *src, size_t n);' }) do
    pcall(ffi.cdef, decl)
end

local C = ffi.C
local u8p = ffi.typeof('const uint8_t *')
local FILE_PREFIX = 'file: '

-- offset of the first byte c in src[i, e), or e. memchr through the ffi: the
-- lines are scanned in C, not one byte per loop iteration in lua
local function find(src, i, e, c)
    local r = C.memchr(src + i, c, e - i)
    return r == nil and e or tonumber(ffi.cast(u8p, r) - src)
end

local rows_t, cols_t = ffi.typeof('int32_t[?]'), ffi.typeof('uint32_t[?]')

-- a copy of the used elements of arr, a ct array of cap elements, with room for
-- at least need, and its new capacity
local function grow(ct, arr, cap, need, used)
    cap = math.max(2 * cap, need, 4096)
    local grown = ffi.new(ct, cap)
    if used > 0 then
        ffi.copy(grown, arr, used * 4)
    end
    return grown, cap
end

-- parses whole lines of level 1 output (level1.lua), a string or n bytes at a
-- pointer, appends the buffer lines to p.out, p.o bytes so far,
-- for read_scanned. headers are found by comparing each line's path with the
-- previous one, kept in p.path. with p.texts, each line's text also goes to
-- p.txt, p.to bytes so far, for write_texts
local function scan_batch(p, data, n)
    n = n or #data
    -- a line grows by at most the 'file: ' header and blank line before it
    if p.cap < p.o + 3 * n + 16 then
        p.cap = 2 * (p.o + 3 * n + 16)
        local grown = ffi.new('uint8_t[?]', p.cap)
        ffi.copy(grown, p.out, p.o)
        p.out = grown
    end
    local texts = p.texts
    if texts and p.tcap < p.to + n + 1 then
        p.tcap = 2 * (p.to + n + 1)
        local grown = ffi.new('uint8_t[?]', p.tcap)
        ffi.copy(grown, p.txt, p.to)
        p.txt = grown
    end
    local out, txt, to = p.out, p.txt, p.to
    local src = ffi.cast(u8p, data)
    local row, k = p.n, p.k
    local file_rows = p.file_rows
    local m = p.match
    local start, cols, nc, scap, ccap = m.start, m.cols, m.nc, m.scap, m.ccap
    local i, o = 0, p.o

    while i < n do
        local e = find(src, i, n, 10)
        -- '<path>\0<lnum>: <text>'. context lines ('<lnum>-') and the '--' between
        -- them are skipped
        local z = find(src, i, e, 0)
        if z < e then
            local ps, plen = i, z - i
            i = z + 1
            local ls = i
            while src[i] >= 48 and src[i] <= 57 do
                i = i + 1
            end
            if i > ls and src[i] == 58 and src[i + 1] == 32 then
                i = i + 2
                -- a line makes at most 3 rows: blank, header and its own
                if row + 3 > scap then
                    start, scap = grow(rows_t, start, scap, row + 3, row)
                end
                if plen ~= p.plen or C.memcmp(src + ps, p.path, plen) ~= 0 then
                    if p.cur then
                        start[row] = nc
                        out[o], o, row = 10, o + 1, row + 1
                    end
                    ffi.copy(out + o, FILE_PREFIX, 6)
                    ffi.copy(out + o + 6, src + ps, plen)
                    o = o + 6 + plen
                    start[row] = nc
                    out[o], o, row = 10, o + 1, row + 1
                    if plen > p.pcap then
                        p.pcap = 2 * plen
                        p.path = ffi.new('uint8_t[?]', p.pcap)
                    end
                    ffi.copy(p.path, src + ps, plen)
                    p.plen = plen
                    p.cur = ffi.string(src + ps, plen)
                    file_rows[#file_rows + 1] = { row, p.cur }
                end

                local lo = o
                ffi.copy(out + o, src + ls, i - ls)
                o = o + i - ls
                local ts = o
                -- the text up to each marker is copied, the markers dropped; a stray
                -- one in a log line only shifts its own columns
                local ms
                start[row] = nc
                local s30, s31 = find(src, i, e, 30), find(src, i, e, 31)
                while true do
                    local mk = s30 < s31 and s30 or s31
                    ffi.copy(out + o, src + i, mk - i)
                    o = o + mk - i
                    if mk == e then
                        break
                    end
                    if mk == s30 then
                        ms = o - lo
                        s30 = find(src, mk + 1, e, 30)
                    else
                        if ms then
                            if nc + 2 > ccap then
                                cols, ccap = grow(cols_t, cols, ccap, nc + 2, nc)
                            end
                            cols[nc], cols[nc + 1] = ms, o - lo
                            nc, ms = nc + 2, nil
                        end
                        s31 = find(src, mk + 1, e, 31)
                    end
                    i = mk + 1
                end
                -- a CRLF log's '\r' is dropped, as a buffer read with ff=dos does:
                -- no ^M, and level 2 and the hit counts see the same text as the
                -- source window. a match ending on it (only \s$-like patterns) is
                -- cut, or dropped if it was only the '\r'
                if o > ts and out[o - 1] == 13 then
                    o = o - 1
                    if nc > start[row] and cols[nc - 1] > o - lo then
                        cols[nc - 1] = o - lo
                        if cols[nc - 2] >= cols[nc - 1] then
                            nc = nc - 2
                        end
                    end
                end
                out[o], o, row, k = 10, o + 1, row + 1, k + 1
                if texts then
                    ffi.copy(txt + to, out + ts, o - ts)
                    to = to + o - ts
                end
            end
        end
        i = e + 1
    end

    p.n, p.k, p.o, p.to = row, k, o, to
    m.start, m.cols, m.n, m.nc, m.scap, m.ccap = start, cols, row, nc, scap, ccap
end

-- rg's output on linux: rg writes it to a memfd, read back here with pread. a pipe
-- holds 64 KB, and nothing reads it while a batch runs on the main thread, so rg
-- stalled; it also came as one lua string per chunk, joined and cut per batch.
-- nil when there's no memfd
local function open_output()
    local ok, fd = pcall(function() return C.memfd_create('logana.rg', 1) end) -- MFD_CLOEXEC
    if not ok or fd < 0 then
        return nil
    end
    return { fd = fd, off = 0, freed = 0, carry = 0, cap = 0 }
end

-- scans the whole lines of up to max more bytes rg wrote, keeping a partial last
-- line for the next call. returns how many bytes it read
local function scan_output(src, p, max)
    if src.cap < src.carry + max then
        src.cap = src.carry + max
        local grown = ffi.new('uint8_t[?]', src.cap)
        ffi.copy(grown, src.buf, src.carry)
        src.buf = grown
    end
    local buf = src.buf
    local got = tonumber(C.pread(src.fd, buf + src.carry, max, src.off))
    if got <= 0 then
        return 0
    end
    src.off = src.off + got
    local len = src.carry + got
    local r = C.memrchr(buf, 10, len)
    local cut = r == nil and 0 or tonumber(ffi.cast(u8p, r) - buf) + 1
    scan_batch(p, buf, cut)
    src.carry = len - cut
    if cut > 0 then
        C.memmove(buf, buf + cut, src.carry)
    end
    -- give back the pages read. FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE
    local upto = src.off - src.off % 4096
    if upto > src.freed then
        C.fallocate(src.fd, 3, src.freed, upto - src.freed)
        src.freed = upto
    end
    return got
end

local function close_output(src)
    C.close(src.fd)
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
            -- not nvim_buf_set_lines: it also counts the bytes of every line it deletes
            -- (for on_bytes), 61 vs 47 ms clearing 1.1M lines
            vim.cmd('silent noautocmd keepjumps %delete _')
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

-- the texts of the result lines, for the hit counts (count.lua) to run rg on:
-- '<lnum>: ', headers and blank lines dropped. on linux a memfd, read by rg
-- through /proc/<pid>/fd/<fd>, else a file in the run dir. nil if neither works
local texts_n = 0
local function open_texts()
    local pid = vim.uv.os_getpid()
    local ok, fd = pcall(function() return C.memfd_create('logana.texts', 1) end) -- MFD_CLOEXEC
    if ok and fd >= 0 then
        return { fd = fd, size = 0, path = ('/proc/%d/fd/%d'):format(pid, fd) }
    end
    texts_n = texts_n + 1
    local path = ('%s/logana.%d.%d.txt'):format(fn.stdpath('run'), pid, texts_n)
    local f = C.fopen(path, 'wb')
    if f == nil then
        return nil
    end
    return { f = f, size = 0, path = path }
end

-- appends what scan_batch put in p.txt. t.failed if a write fell short
local function write_texts(t, p)
    if t and not t.failed and p.to > 0 then
        local n
        if t.fd then
            n = tonumber(C.pwrite(t.fd, p.txt, p.to, t.size))
        else
            n = t.f ~= nil and tonumber(C.fwrite(p.txt, 1, p.to, t.f)) or 0
        end
        t.failed = n ~= p.to
        t.size = t.size + p.to
    end
    p.to = 0
end

-- all of it written: the file is complete for rg to read
local function finish_texts(t)
    if t.f then
        C.fclose(t.f)
        t.f = nil
    end
end

local function close_texts(t)
    if t.fd then
        C.close(t.fd)
    else
        finish_texts(t)
        os.remove(t.path)
    end
end

M.open_texts = open_texts
M.write_texts = write_texts
M.finish_texts = finish_texts
M.close_texts = close_texts
M.scan_batch = scan_batch
M.read_scanned = read_scanned
M.release = release
M.open_output = open_output
M.scan_output = scan_output
M.close_output = close_output
return M
