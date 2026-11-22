# logana.nvim

Lightweight log analyzer for Neovim. Write ripgrep args in a rule buffer, press
`<Enter>`, and a result buffer lists the matching lines with the matches colored.
Every rule uses ripgrep syntax and flags.

## Install

Needs Neovim built with LuaJIT (the default) and ripgrep.

lazy.nvim:
```lua
{
    "sheeaza/logana.nvim",
    config = function()
        require("logana").setup({})
    end,
}
```

packer.nvim:
```lua
use({
    "sheeaza/logana.nvim",
    config = function()
        require("logana").setup({})
    end,
})
```

`setup()` registers the rule/result filetypes, so load the plugin at startup rather
than lazily on a command.

`:checkhealth logana` shows whether `setup()` was called, the ripgrep version, and
which ways of starting rg (`posix_spawn` or `vim.system`) and passing its output
(memfd or temp files in `stdpath("run")`) are in use.

## Usage

There is no command. Rule and result buffers are plain files, told apart by extension.

1. Open your log file(s).
2. Open a rule file the usual way, e.g. `:vs app.logana_rule` (or `:e`, `:tabe`, a
   session, a file picker). A new or empty rule buffer is filled with a template.
3. Write the rules (see [Rule file](#rule-file)).
4. Press `<Enter>` in the rule buffer. The results go to `app.logana_result`, next to
   the rule file, and its window opens beside the rule window if it isn't shown
   already. It lists `file: <path>` headers followed by `<line>: <text>`.

`:w` saves the rules, and opening the file later brings them back.

### Rule file

```ini
[rg]
--smart-case
-e 'timeout'
-e 'connect'

[file]
# true: search only the files opened in nvim; false: rg searches cwd
opened_only = true

[highlight]
--smart-case
-i -e 'error'
-e 'retry' -e 'busy'

[fold]
logs/b.log
```

- `[rg]`: ripgrep args. The matching lines of the files are listed in the result
  buffer, every match in one color (`LoganaMatch`).
- `[file]`: `opened_only = true` searches the files opened in Neovim, `false` lets rg
  search cwd. `-g`/`--glob`/`--iglob` in `[rg]` pick files either way: with
  `opened_only` the opened files are filtered as rg would filter them under cwd.
- `[highlight]`: one ripgrep args list per line, matched against the result lines.
  Each line gets its own color (`LoganaHighlight1..N`); a line may hold several
  patterns. A line with only flags (no `-e`/`-f`) gets no color: its flags are put in
  front of every pattern line, so above there are two colors,
  `--smart-case -i -e 'error'` and `--smart-case -e 'retry' -e 'busy'`. A line's own
  flags win (`-i` overrides `--smart-case`).
- `[fold]`: the files folded in the result buffer, one per line. Kept in sync with
  the result window (see [Folding](#folding)).

Where `[rg]` and `[highlight]` colors overlap, the `[highlight]` one wins.

### Refresh

`<Enter>` in the rule buffer only reruns what changed:
- The search reruns if `[rg]`/`[file]` changed, a searched file changed on disk (only
  checked with `opened_only = true`), or the result buffer was edited or closed. With
  `opened_only = false`, changes under cwd can't be seen, so `<Enter>` always reruns it.
- Otherwise only the `[highlight]` colors are redone, and only if `[highlight]` changed.

Results load in the background: the first lines show at once, the rest are appended
while you keep working. A spinner with the number of lines loaded so far shows at the
right end of the rule window's last line. `<Enter>` while loading restarts the search
if `[rg]`/`[file]` changed; otherwise the load goes on and uses the new `[highlight]`
and `[fold]` when it's done.

`[highlight]` colors are added to lines as they're drawn, so scrolling to new lines
colors them a moment later.

### Result buffer

- `<Enter>` on a result line jumps to that line in the source file: in the source
  file's window if the current tab has one, otherwise in the result window.
- Moving to another line moves the cursor of the source file's window along, if the
  current tab has one, without leaving the result (`result_win.follow`).
- Select text on one line in visual mode and press `<Enter>`: `-F -e '<text>'` is added
  at the end of `[highlight]` (in `"` if the text has a `'`), matched as is, not as a
  regex. Doing it again on the same text removes that line; only lines that are
  exactly that rule count. If the selection lies inside a `[highlight]` color shown there, that
  color's line is removed instead (the whole line, with any other patterns on it; of
  overlapping colors, the one on top). The colors follow right away: only `[highlight]` reruns,
  not `[rg]` or `[fold]` even if they were edited, and edits in the result are kept. If the line can't be written (the text has both quotes) or rg
  rejects it with the section's flags, it warns and adds nothing.
- The result buffer is volatile: editing it doesn't refresh anything, and the next
  refresh throws the edits away. Undo is off in it, so each refresh stays fast with a
  large result. Edits meant to last go in the source file.
- CRLF logs: the `\r` at the end of each line is dropped, as in a buffer read with
  `ff=dos`, so `[highlight]` and the source window's colors see the same text. `$` in
  `[rg]` still needs rg's `--crlf`. A hit count of an `[rg]` pattern matching the `\r`
  itself (`\s$` without `--crlf`) is 0.

### Folding

The result buffer has one fold per file, so `za`/`zc`/`zo`/`zM`/`zR` work on whole
files. The folded files are kept in `[fold]`, updated when you leave the result window
or refresh, and saved with the rule file. If the section is missing, it is added the
first time a file is folded. Editing `[fold]` by hand and pressing `<Enter>` applies it.

### Source file colors

A file listed in a result (a `file:` header) gets the `[highlight]` colors in its own
windows too, not the `[rg]` one, only for the lines on screen. It keeps them in other
tabs and with the result closed, until the rule buffer is wiped or a refresh no longer
lists the file. If several rule buffers list it, the one refreshed last gives the
rules. `highlight.hl_buf = false` turns it off.

Visual `<Enter>` in such a file toggles the selection in `[highlight]` as in the
result buffer, in that rule buffer (`key.toggle_highlight`). The mapping is
local to the file's buffer, set once it's shown as a source; if it no longer is one,
`<Enter>` does what it does without it.

### Hit counts

After a refresh, the end of each `[rg]` line with a `-e`/`-f` and each colored
`[highlight]` line shows how many result lines it matches, in that rule's color (` … `
while loading and counting, `!` if rg failed). Every result line is counted, not only
the ones drawn. The flag-only lines of the section are shared by every rule; in
`[rg]`, lines without a pattern (e.g. `-g '*.log'`, paths) aren't counted. For a line
with several patterns, the count is of the lines matching any of them. The counts move
with edits to the rule buffer, also ones made while loading, and are updated on the
next refresh. `hit_count = false` turns them off.

## Config

`setup(opts)` merges `opts` over the defaults in `lua/logana/defconfig.lua`:

| Option | Default | Meaning |
| --- | --- | --- |
| `rg.cmd` | `'rg'` | ripgrep executable |
| `rg.args` | `{ '--no-config' }` | extra args for the search; the output format is set by logana |
| `match_color` | bold white on gray | `[rg]` color (`LoganaMatch`), any `nvim_set_hl` spec |
| `highlight_colors` | 10 fixed colors | `[highlight]` colors (`LoganaHighlight1..N`), cycled |
| `spinner` | `{ frames = {...}, interval = 80 }` | loading spinner, `false` to turn off |
| `hit_count` | `true` | hit counts in the rule buffer |
| `highlight.hl_buf` | `true` | `[highlight]` colors in source file windows |
| `layout.rule_pos` | `'top'` | where the rule window is: `'top'`, `'bottom'`, `'left'`, `'right'` |
| `layout.rule_window` | `'20'` | rule window size, percent of the rule/result split |
| `result_win.behavior` | `'split'` | `'split'` the rule window, or `'override'`: show the result in it |
| `result_win.follow` | `true` | move the source window's cursor with the result's |
| `naming.rule` / `naming.result` | `'logana_rule'` / `'logana_result'` | file extensions, also the filetypes |
| `rule_template` | see `defconfig.lua` | text of a new rule buffer |
| `key.rule_refresh` | `'<cr>'` | refresh, in the rule buffer |
| `key.result_jump` | `'<cr>'` | jump to the source line, in the result buffer |
| `key.toggle_highlight` | `'<cr>'` | visual mode in the result buffer, or a source file of it: toggle the selection in `[highlight]` |

Colors, fixed by default so they look the same with every colorscheme; use `link` to
follow the theme:
```lua
require("logana").setup({
    match_color = { fg = "#ffffff", bg = "#8a8a8a" },
    highlight_colors = {
        { fg = "#000000", bg = "#ff8800" },
        { link = "DiffAdd" },
    },
})
```

Shorter extensions, to type less:
```lua
require("logana").setup({ naming = { rule = "lr", result = "lres" } })  -- :vs app.lr
```

## API

- `require("logana").setup(opts)`: see [Config](#config).
- `require("logana").refresh(rule_buf, on_done)`: same as `<Enter>` in `rule_buf`.
  Results load asynchronously; the optional `on_done()` is called once they and their
  folds are applied (`[highlight]` colors come as lines are drawn). It isn't called if
  the refresh fails, finds no match, or is superseded by another refresh.

## Reference

- `:h logana`: this README as Vim help ([doc/logana.txt](doc/logana.txt)).
- [doc/DESIGN.md](doc/DESIGN.md): design, the data flow.
- [tests/README.md](tests/README.md): running the tests and the benchmark, results.
- [doc/TODO.md](doc/TODO.md) / [doc/DONE.md](doc/DONE.md): open and resolved items.

## License

MIT
