-- timings: callers log "<phase> took: <n> ms". a no-op, tests/bench.lua replaces
-- trace to collect them; called as log.trace, so the replacement is seen
return {
    trace = function() end,
}
