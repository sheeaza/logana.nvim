-- starting rg: posix_spawn through the ffi on linux, vim.system elsewhere.
-- libuv forks, which makes all of neovim's pages copy-on-write until the child
-- execs; with a large result loaded, the next writes to old memory then take a
-- page fault each (clearing 738k result lines: ~220 ms instead of ~55). glibc's
-- posix_spawn shares the memory instead (CLONE_VM | CLONE_VFORK), nothing to fault.
local uv = vim.uv

local M = {}

local has_ffi, ffi = pcall(require, 'ffi')
M.enabled = has_ffi and ffi.os == 'Linux' -- tests turn it off to cover vim.system
if M.enabled then
    -- each on its own, another plugin may have declared some already
    for _, decl in ipairs({
        'typedef int pid_t;',
        'int posix_spawnp(pid_t *pid, const char *file, const void *file_actions, const void *attrp,'
            .. ' char *const argv[], char *const envp[]);',
        'int posix_spawn_file_actions_init(void *file_actions);',
        'int posix_spawn_file_actions_destroy(void *file_actions);',
        'int posix_spawn_file_actions_adddup2(void *file_actions, int fd, int newfd);',
        'int posix_spawn_file_actions_addopen(void *file_actions, int fd, const char *path, int flags, int mode);',
        'int pipe2(int fds[2], int flags);',
        'int close(int fd);',
        'pid_t waitpid(pid_t pid, int *status, int options);',
        'int kill(pid_t pid, int sig);',
        'extern char **environ;',
    }) do
        pcall(ffi.cdef, decl)
    end
end

local O_CLOEXEC, WNOHANG = 0x80000, 1
-- glibc's posix_spawn_file_actions_t is 80 bytes on 64 bit, room to spare
local FILE_ACTIONS_SIZE = 256

-- a pipe whose ends don't leak into the child, but the one dup2'd to 0/1/2
local function new_pipe()
    local fds = ffi.new('int[2]')
    if ffi.C.pipe2(fds, O_CLOEXEC) ~= 0 then
        error('[logana] pipe2 failed')
    end
    return fds[0], fds[1]
end

-- the part of vim.system the plugin uses: opts.stdout is a function(err, data)
-- streaming it, else stdout is collected into res.stdout; stderr is always
-- collected; opts.stdin is a string. on_exit(res) with res = { code, stdout,
-- stderr } runs in a fast event context, as vim.system's. errors if args[1]
-- can't be run. returns an object with :kill(signal)
local function spawn(args, opts, on_exit)
    local out_r, out_w = new_pipe()
    local err_r, err_w = new_pipe()
    local fa = ffi.new('uint8_t[?]', FILE_ACTIONS_SIZE)
    ffi.C.posix_spawn_file_actions_init(fa)
    -- without input /dev/null, as vim.system: rg given no path searches a piped
    -- stdin instead of the directory
    local in_r, in_w
    if opts.stdin then
        in_r, in_w = new_pipe()
        ffi.C.posix_spawn_file_actions_adddup2(fa, in_r, 0)
    else
        ffi.C.posix_spawn_file_actions_addopen(fa, 0, '/dev/null', 0, 0) -- O_RDONLY
    end
    ffi.C.posix_spawn_file_actions_adddup2(fa, out_w, 1)
    ffi.C.posix_spawn_file_actions_adddup2(fa, err_w, 2)

    local argv = ffi.new('char *[?]', #args + 1)
    local keep = {} -- argv strings must outlive the call
    for i, a in ipairs(args) do
        keep[i] = ffi.new('char[?]', #a + 1, a)
        argv[i - 1] = keep[i]
    end
    local pid = ffi.new('pid_t[1]')
    local rc = ffi.C.posix_spawnp(pid, args[1], fa, nil, argv, ffi.C.environ)
    ffi.C.posix_spawn_file_actions_destroy(fa)
    -- the child's ends
    if in_r then
        ffi.C.close(in_r)
    end
    ffi.C.close(out_w)
    ffi.C.close(err_w)
    if rc ~= 0 then
        if in_w then
            ffi.C.close(in_w)
        end
        ffi.C.close(out_r)
        ffi.C.close(err_r)
        error(('[logana] cannot run %s (errno %d)'):format(args[1], rc))
    end
    pid = pid[0]

    if in_w then
        local stdin = uv.new_pipe(false)
        stdin:open(in_w)
        stdin:write(opts.stdin)
        stdin:shutdown(function() stdin:close() end)
    end

    local out, err, open = {}, {}, 2
    local exited = false
    local function reap()
        -- the pipes are closed, the child is done or about to be
        local status = ffi.new('int[1]')
        local timer = uv.new_timer()
        local function try()
            if ffi.C.waitpid(pid, status, WNOHANG) ~= pid then
                return false
            end
            exited = true
            timer:stop()
            timer:close()
            local s = status[0]
            -- exit code when it exited, 128 + signal when it was killed
            local code = bit.band(s, 0x7f) == 0 and bit.rshift(bit.band(s, 0xff00), 8) or 128 + bit.band(s, 0x7f)
            on_exit({ code = code, stdout = not opts.stdout and table.concat(out) or nil, stderr = table.concat(err) })
            return true
        end
        if not try() then
            timer:start(1, 1, try)
        end
    end
    local function reader(fd, on_data)
        local pipe = uv.new_pipe(false)
        pipe:open(fd)
        pipe:read_start(function(e, data)
            on_data(e, data)
            if not data then
                pipe:close()
                open = open - 1
                if open == 0 then
                    reap()
                end
            end
        end)
    end
    reader(out_r, opts.stdout or function(_, data) out[#out + 1] = data end)
    reader(err_r, function(_, data) err[#err + 1] = data end)

    return {
        kill = function(_, signal)
            if not exited then
                ffi.C.kill(pid, signal or 15)
            end
        end,
    }
end

-- vim.system(args, opts, on_exit), started without fork where it can be
function M.system(args, opts, on_exit)
    if M.enabled then
        return spawn(args, opts, on_exit)
    end
    return vim.system(args, opts, on_exit)
end

return M
