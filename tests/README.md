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
12/12 passed
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
  - level 2 (`[highlight]`) runs one `rg` per `[highlight]` line that has a pattern;
  - `0` means nothing re-ran.
- For every test, wipes all buffers, `cd`s into a new temp dir, writes a small
  `a.log`, opens it, and runs `:Logana`. Rule and result files are created
  relative to cwd, so each test starts with nothing left over from the previous one.
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
| `set_rule(rule_buf, rg, hl)` | Replace the rule buffer with the given `[rg]` lines, `opened_only = true`, and the given `[highlight]` lines |
| `refresh(rule_buf, force)` | Same as pressing `<CR>` (or `:Logana refresh` when `force` is true); returns the number of `rg` runs |
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
call `refresh(rule, true)`, as the multibyte test does.

## CI

`.github/workflows/test.yml` runs the same command on GitHub Actions for every
push and pull request. It runs against the latest Neovim release (v0.12.6) and
nightly, with ripgrep from Ubuntu's packages.
