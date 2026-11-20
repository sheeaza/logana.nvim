# Tests

The tests are plain Lua scripts run by Neovim in headless mode. They need no test
framework or plugin manager, only `nvim` (tested with 0.12) and `rg` on `PATH`.

## Running

From the repo root:

```sh
nvim --headless -u NONE -l tests/run.lua
```

To test with a specific Neovim build, replace `nvim` with the path to that binary.

Each test prints one line, followed by a summary:

```
ok   level 1 lists matched lines with one shared color
ok   level 2 colors each [highlight] line separately, using rg syntax
...
20/20 passed
```

The exit code is `0` if every test passed and `1` otherwise, so the command can be
used in CI or a git hook. A failing test prints the expected and actual values:

```
FAIL level 1 lists matched lines with one shared color
  tests/run.lua:93: rg calls
  expected: 2
  actual:   1
```

`-u NONE` skips your own config, so other plugins can't affect the results. The
runner adds the repo to `runtimepath` itself.

## How it works

`tests/run.lua` does the following:

- Loads the plugin from the repo and calls `require("logana").setup({})`.
- Wraps `vim.system` to count how many `rg` processes each refresh starts. The
  tests check this count to confirm which levels re-ran:
  - level 1 (`[rg]`) runs one `rg`;
  - level 2 (`[highlight]`) runs one `rg` per `[highlight]` line that has a pattern,
    when rows are drawn, not during the refresh;
  - `0` means nothing re-ran.
- `highlighted()` runs `:redraw`, which calls the decoration provider even headless,
  so rows on screen ask for level 2, and waits for it. Only rows on screen get it:
  tests that check a late row scroll there first (`normal! G`).
- For every test, wipes all buffers, `cd`s into a new temp dir, writes a small
  `a.log`, opens it, and opens `0.logana_rule` in a split. Rule and result files are
  created relative to cwd, so each test starts with nothing left over from the previous one.
- Turns on `filetype` detection, which `-u NONE` leaves off; rule buffers are set up
  by their `FileType` autocmd.
- Runs every test twice: with the LuaJIT ffi scanner for level 1 (`[ffi]`) and
  with the Lua parser used without LuaJIT (`[lua]`).
- Reads the computed highlights from `require("logana")._result_highlights` and
  turns them into readable strings:

  ```
  match:<row>:<matched text>             -- level 1
  hl:<row>:<matched text>:<color index>  -- level 2
  ```

  For example, `hl:1:busy:2` means that on result row 1 (0-based), `busy` is
  highlighted with `LoganaHighlight2`.

The highlights are not read from the screen. The decoration provider only draws
the ranges stored in that table, so checking the table also checks what gets
drawn.

## Helpers

| Helper | Purpose |
| --- | --- |
| `setup_session()` | Fresh temp dir with `a.log` opened and a new rule buffer; returns the rule bufnr |
| `set_rule(rule_buf, rg, hl, opened_only)` | Replace the rule buffer with the given `[rg]` lines, `opened_only` (default `true`), and the given `[highlight]` lines |
| `refresh(rule_buf)` | Same as pressing `<CR>` in the rule buffer, then waits for the streamed results to load; returns the number of `rg` runs |
| `result_lines()` | Lines of `0.logana_result` |
| `highlighted()` | All highlights in the result buffer, in the `match:`/`hl:` string format above |
| `eq(expected, actual, what)` | Deep-equal assertion |

## Adding a test

Add a `test(...)` block above the runner loop at the bottom of `tests/run.lua`:

```lua
test("short description of the behavior", function()
    local rule = setup_session()
    set_rule(rule, { "-e 'resource'" }, { "-e 'busy'" })
    eq(2, refresh(rule), "rg calls")   -- level 1 + one highlight rule
    eq({ "match:1:resource", "hl:1:busy:1", "match:2:resource" }, highlighted())
end)
```

To test with different log content, overwrite `a.log` after `setup_session()` and
call `refresh(rule)`; with `opened_only = true` the change is detected, as the multibyte test shows.

## CI

`.github/workflows/test.yml` runs the same command on GitHub Actions for every
push and pull request. It runs against the latest Neovim release (v0.12.6) and
nightly, with ripgrep from Ubuntu's packages.

## Benchmark

`tests/bench.lua` times one refresh against a real log, split by phase:

```sh
nvim --headless -u NONE -l tests/bench.lua <log file or dir> [runs] [--xl]
```

Each case does one warmup refresh, which fills the page cache and opens the result
window, then prints the median of `runs` refreshes (default 3) in ms. The phase
times come from the plugin's `log.trace` timers. Redraw isn't measured, since no UI
is attached. The cases search the camera log the numbers below were taken on:
`small` is `ResourceReserve` (~900 matches), `medium` is `DRV_COMMON` (~130k),
`large` is `CLIENT_MGR` (~740k), and `--xl` adds `Info  ` (~2.5M). All cases use the
same three `[highlight]` rules. For another log, edit `CASES` in the script.

Columns (the first three runs below predate streaming): `rg` level 1 rg run, `parse`
its output into the result lines (`prep` was a separate pass before the third run),
`set_lines` writing them, `first` time until the first lines are in the buffer,
`max_batch` the longest a single streamed batch blocked Neovim, `level1` until all
level 1 lines are in, `hl` level 2 (since it's lazy: coloring the rows on one
screen after the refresh), `save_fold`/`rest_fold` folds,
`total` the whole refresh (since level 2 is lazy, without it), `rss_MB` resident memory after the case.

### Results

500 MB single-file camera log (2.64M lines), i7-12700, ripgrep 13.0.0, Neovim 0.12.0.

Baseline, level 1 parsed from `rg --json` (median of 3):

```
case    res_lines   rg   parse   prep  set_lines   hl   total   rss_MB
small         887   79       5      0          0    7      94       16
medium     132858  374    1006    107         49   59    1637      627
large      740954 1604    5246   1886        236  259    9393     3441
```

Level 1 parsed from plain output with `--replace` match markers (median of 5):

```
case    res_lines   rg   parse   prep  set_lines   hl   total   rss_MB
small         887   82       1      0          0    7      95       16
medium     132858  226     366    160         42   42     871      526
large      740954  991    2523    686        196  187    4707     2503
```

Level 1 parsed and the result lines built in one pass, rg printing `<lnum>: ` itself
via `--field-match-separator`, output read without `text = true` (median of 5):

```
case    res_lines   rg   parse   set_lines   hl   total   rss_MB
small         887   83       1           0    7      94       16
medium     132858  136     451          47   40     693      413
large      740954  371    1592         225  173    2419     2153
```

Level 1 streamed into the buffer in 1 MB batches (median of 5). `parse` and
`set_lines` are summed over the batches. The total is ~1.4 s longer than the one-pass
version, but the first lines show after ~40 ms and Neovim is blocked for at most
`max_batch` at a time instead of the whole refresh. The longest batch is most likely
where the result tables grow past 2^19 entries; it is the same with the GC stopped.

```
case    res_lines   first   parse   set_lines   max_batch   level1    hl   total   rss_MB
small         887       6       2           0           0       84     7      93       16
medium     132858      16     518          39          38      606    29     647      221
large      740954      36    3211         219         136     3549   148    3881     1336
```

Level 1 match ranges kept in flat number arrays instead of a `{ {s, e} }` table per
row, and the level 2 input joined per batch instead of kept as one string per line
(median of 3). While streaming, the GC kept re-marking the ~1.5M small tables and
~740k strings that were still alive; with the GC stopped during the load, `parse` was
~1.5 s. These are the objects it re-marked, so dropping them gives most of that back.
The one-pass version didn't show this: the previous result, still alive while it
parsed, made the heap big enough that the GC rarely ran.

```
case    res_lines   first   parse   set_lines   max_batch   level1    hl   total   rss_MB
small         887       6       2           0           0       85     7      93       15
medium     132858      10     333          37          17      422    23     457      211
large      740954      45    2239         198         137     2569   100    2727      907
```

`<lnum>: ` and the line text captured as positions instead of strings, two strings
less per line (median of 3). Each string made is interned (hashed) and later swept,
which is most of the parsing cost. Going further, taking the pieces around the match
markers straight from the batch by position, without the whole line as a string,
didn't help: the anchored pattern searches it needs cost as much as they save.

```
case    res_lines   first   parse   set_lines   max_batch   level1    hl   total   rss_MB
small         887       6       1           0           0       84     8      93       15
medium     132858      10     247          36          15      338    38     393      198
large      740954      27    1562         193          78     1884    98    2048      911
```

Level 1 scanned with a LuaJIT ffi byte loop, the result lines put in the buffer with
`:read` from a temp file, without a Lua string per line. Measured on another
machine with a synthetic 400 MB log of the same shape (2.64M lines, `large` ~739k
matches), against the Lua parser on that same machine (median of 3). `hl` is high
on both because the synthetic log's `start is`/`stop is` rules match every
`CLIENT_MGR` line; its gap between the two is GC noise (with the same refresh run
back to back in one process, both took 2.3-2.7 s). `set_lines` is the `:read`s,
~240 ms of it the first one, which clears the previous result.

```
case    res_lines   first   parse   set_lines   max_batch   level1    hl   total   rss_MB
lua parser:
small        8984       7      29           6           5      105    25     134       25
medium     131719      50     358          57          69      469    41     554      176
large      738898      45    3329         338         235     3947  2328    6380     1445
ffi scanner:
small        8984       7      12           6           3      103    25     132       30
medium     131719      13     120          73          40      255    44     346      143
large      738898      32     782         546         245     1561  3398    5097     1471
```

Level 2 lazy: a row gets its `[highlight]` colors when it's first drawn, from rg
over just the rows on screen, so the refresh no longer runs it over all rows, and
level 1 no longer collects the level 2 input (the line texts, ~100 MB on `large`).
Same machine and synthetic log as above (median of 3). `hl` is now one screen (24
rows), not included in `total`.

```
case    res_lines   first   parse   set_lines   max_batch   level1    hl   total   rss_MB
lua parser:
small        8984       7      19           6           3      108    11     109       18
medium     131719       8     166          62          42      272    13     273       50
large      738898      12    1023         346         235     1506    23    1507      219
ffi scanner:
small        8984       7       9           7           3      107    10     108       19
medium     131719       9      77          78          42      240    13     241       55
large      738898      12     526         523         252     1298    25    1298      224
```
