-- small helpers shared by the modules
local M = {}

-- for trace timings. not vim.uv.now(), that's the loop's cached time, which
-- doesn't advance during synchronous lua work
function M.now_ms()
    return vim.uv.hrtime() / 1e6
end

return M
