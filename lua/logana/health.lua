-- :checkhealth logana
local fn = vim.fn

local M = {}

local function check_setup(config)
    if config.rg then
        vim.health.ok('setup() called')
    else
        vim.health.warn('setup() not called: rule/result files are not recognized',
            { 'call require("logana").setup({}) at startup' })
    end
end

-- true when the ffi is there, the rest of the checks need it
local function check_luajit()
    local ok, ffi = pcall(require, 'ffi')
    if ok and jit then
        vim.health.ok(('%s, %s'):format(jit.version, ffi.os))
        return true
    end
    vim.health.error('Neovim is not built with LuaJIT: logana cannot run',
        { 'use a Neovim build with LuaJIT (the default)' })
    return false
end

local function check_rg(config)
    local cmd = config.rg and config.rg.cmd or require('logana.defconfig').rg.cmd
    if fn.executable(cmd) ~= 1 then
        vim.health.error(('ripgrep (%s) not found in PATH'):format(cmd),
            { 'install ripgrep, or set rg.cmd in setup()' })
        return
    end
    local ok, res = pcall(function() return vim.system({ cmd, '--version' }, { text = true }):wait(5000) end)
    local version = ok and res.code == 0 and res.stdout:match('^[^\n]*') or nil
    if version then
        vim.health.ok(('%s (%s)'):format(version, fn.exepath(cmd)))
    else
        vim.health.warn(('%s found, but `%s --version` failed'):format(fn.exepath(cmd), cmd))
    end
end

local function check_spawn()
    local ffi = require('ffi')
    local proc = require('logana.proc')
    if not proc.enabled then
        vim.health.info(('rg started with vim.system (fork): no posix_spawn on %s. '
            .. 'Slower refreshes with a large result loaded'):format(ffi.os))
        return
    end
    if pcall(function() return ffi.C.posix_spawnp end) then
        vim.health.ok('rg started with posix_spawn (no fork)')
    else
        vim.health.warn('posix_spawnp not found in the C library: starting rg will fail')
    end
end

local function check_memfd()
    local ffi = require('ffi')
    pcall(ffi.cdef, 'int memfd_create(const char *name, unsigned int flags);')
    pcall(ffi.cdef, 'int close(int fd);')
    local ok, fd = pcall(function() return ffi.C.memfd_create('logana.health', 1) end) -- MFD_CLOEXEC
    if ok and fd >= 0 then
        ffi.C.close(fd)
        vim.health.ok('rg output and result lines go through a memfd')
        return
    end
    local run = fn.stdpath('run')
    if fn.filewritable(run) == 2 then
        vim.health.info(('no memfd: temp files in %s instead'):format(run))
    else
        vim.health.error(('no memfd, and %s (stdpath("run")) is not writable'):format(run))
    end
end

function M.check()
    local config = require('logana.config')
    vim.health.start('logana')
    check_setup(config)
    check_rg(config)
    if check_luajit() then
        check_spawn()
        check_memfd()
    end
end

return M
