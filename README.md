# logana.nvim

Lightweight log analyzer for Neovim. Write ripgrep args under an `[rg]` section in a rule buffer, then press Enter in it to refresh a bound result buffer that lists the matching lines and highlights the matched text.

## Features
- Two-level filtering, both driven by the rule buffer and using ripgrep syntax:
  1. `[rg]`: ripgrep args. Matching lines from the files are listed in the result buffer, and every match shares one color (`LoganaMatch`).
  2. `[highlight]`: one ripgrep args list per line, matched against the result lines. Each line gets its own color (`LoganaHighlight1..N`).
- Pressing `<Enter>` in the rule buffer only redoes what's needed (see [Refresh](#refresh)).
- Pressing `<Enter>` on a result line jumps to that line in the source file.
- Selecting text in the result buffer and pressing `<Enter>` adds it to `[highlight]`, or removes it if it's there (see [Toggling a highlight](#toggling-a-highlight)).

## Install
Needs Neovim built with LuaJIT (the default) and ripgrep.

- lazy.nvim:
  {
    "yourname/logana.nvim",
    config = function()
      require("logana").setup({})
    end,
  }

- packer.nvim:
  use({
    "yourname/logana.nvim",
    config = function()
      require("logana").setup({})
    end,
  })

`setup()` registers the rule/result filetypes, so load the plugin at startup rather
than lazily on a command.

## Usage
There is no command. Rule and result buffers are plain files, told apart by extension.
1) Open your log file(s).
2) Open a rule file the usual way, e.g. `:vs cam.logana_rule` (or `:e`, `:tabe`, a session,
   a file picker). A new or empty rule buffer is filled with a template.
3) Write the rules:
  ```ini
  [rg]
  --smart-case
  -e 'hw..?_cam'
  -e 'resource'

  [file]
  # true: search only the files opened in nvim; false: rg searches cwd
  opened_only = true

  [highlight]
  # one color per line; a line may hold several patterns and rg flags.
  # a line with only flags applies to every line and takes no color.
  --smart-case
  -i -e 'error'
  -e 'retry' -e 'busy'
  ```
4) Press `<Enter>` in the rule buffer. The results go to `cam.logana_result`, next to the
   rule file, and its window opens beside the rule window if it isn't shown already (see
   `layout` and `result_win` in `defconfig.lua`). It lists `file: <path>` headers followed
   by `<line>: <text>`.

`:w` saves the rules, and opening the file later brings them back. To type less, pick
shorter extensions:
```lua
require("logana").setup({ naming = { rule = "lr", result = "lres" } })  -- :vs cam.lr
```

### Refresh
Pressing `<Enter>` checks each level in turn and only reruns what changed:
- Level 1 reruns (and then level 2) if the `[rg]`/`[file]` args changed, any searched file changed on disk (only checked when `opened_only = true`), or the result buffer was edited or closed.
- Otherwise level 2 reruns, but only if `[highlight]` changed.
- With `opened_only = false`, changes to files under cwd can't be detected, so pressing `<Enter>` without changing anything reruns both levels.

Level 2 runs only for the lines on screen: each line gets its `[highlight]` colors the
first time it's drawn, from an rg run over just those lines, so scrolling to new lines
colors them a moment later.

Level 1 results load in the background: the first lines show right away and the rest
are appended while you can keep working. While loading, a spinner and the number of
lines loaded so far show in a small float at the right end of the rule window's last
line, just above its statusline, so it works with any statusline plugin (`spinner` in the config, `false` to
turn it off). `[highlight]` colors show on the loaded lines as you see them, folds are applied once loading is done. Pressing `<Enter>` while results are loading restarts the search
if `[rg]`/`[file]` changed; otherwise the load continues and uses the new `[highlight]`
and `[fold]` when it's done.

### Folding
The result buffer has one fold per file, so `za`/`zc`/`zo`/`zM`/`zR` work on whole files.
The folded files are kept in the rule buffer under `[fold]`, one per line. That section
is updated when you leave the result window or refresh, and is saved with the rule file.
If it is missing, it is added the first time a file is folded. Editing `[fold]` by hand
and pressing `<Enter>` applies it.

### Toggling a highlight
In the result buffer, select text on one line in visual mode and press `<Enter>`
(`key.result_toggle_highlight`): `-F -e '<text>'` is added at the end of the rule
buffer's `[highlight]` section and the colors are refreshed, so the text is matched as
is, not as a regex. A text with a `'` is put in `"` instead. Doing it again on the same
text removes that line. Only lines that are exactly that rule count, patterns inside
other lines are left alone. If the line can't be written (the text has both quotes) or
rg rejects it with the section's flags, it warns and adds nothing. The rule buffer is
edited like any buffer, it isn't saved.

## API
- `require("logana").setup(opts)`: see `lua/logana/defconfig.lua` for all options.
- `require("logana").refresh(rule_buf, on_done)`: same as pressing `<Enter>` in `rule_buf`.
  Results load asynchronously; the optional `on_done()` is called once they and their
  folds are applied (`[highlight]` colors come as lines are drawn). It isn't called if the refresh fails, finds no
  match, or is superseded by another refresh.

## Highlight Customization
```lua
require("logana").setup({
    match_color = { link = "TermCursor" },          -- level 1, LoganaMatch
    highlight_colors = {                            -- level 2, LoganaHighlight1..N (cycled)
        { fg = "#000000", bg = "#ff8800" },
        { link = "DiffAdd" },
    },
})
```
Where both levels overlap, the level 2 color wins.

## Workflow Tips
- Keep one pane on your log file (source buffer) while you iterate on patterns in the rule buffer.
- Rule/result buffers are named files; `:w` them to keep your rules.

## Tests
```sh
nvim --headless -u NONE -l tests/run.lua   # details: tests/README.md
```

## License
MIT