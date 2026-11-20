# logana.nvim

Lightweight log analyzer for Neovim. Open a rule buffer where each line is a Vim regex under a [match] section. Press Enter in the rule buffer to refresh a bound result buffer that lists matching lines and highlights the matched text.

## Features
- Two-level filtering, both driven by the rule buffer and using ripgrep syntax:
  1. `[rg]`: ripgrep args. Matching lines from the files are listed in the result buffer, and every match shares one color (`LoganaMatch`).
  2. `[highlight]`: one ripgrep args list per line, matched against the result lines. Each line gets its own color (`LoganaHighlight1..N`).
- Pressing `<Enter>` in the rule buffer only redoes what's needed (see [Refresh](#refresh)).
- Pressing `<Enter>` on a result line jumps to that line in the source file.

## Install
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

## Usage
1) Open your log file(s).
2) Run `:Logana`. This opens a rule buffer (`0.logana_rule`) and a result buffer (`0.logana_result`).
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
4) Press `<Enter>` in the rule buffer. The result buffer lists `file: <path>` headers followed by `<line>: <text>`.

### Refresh
Pressing `<Enter>` checks each level in turn and only reruns what changed:
- Level 1 reruns (and then level 2) if the `[rg]`/`[file]` args changed, any searched file changed on disk (only checked when `opened_only = true`), or the result buffer was edited or closed.
- Otherwise level 2 reruns, but only if `[highlight]` changed.
- `:Logana refresh` in the rule buffer forces both levels to rerun. Use this when `opened_only = false` and files under cwd changed.

### Folding
The result buffer has one fold per file, so `za`/`zc`/`zo`/`zM`/`zR` work on whole files.
The folded files are kept in the rule buffer under `[fold]`, one per line. That section
is updated when you leave the result window or refresh, and is saved with the rule file.
If it is missing, it is added the first time a file is folded. Editing `[fold]` by hand
and pressing `<Enter>` applies it.

## Commands
- `:Logana`: in a rule buffer, refresh as described above. Anywhere else, open a new rule/result pair.
- `:Logana refresh`: in a rule buffer, force a full refresh.

## API
- `require("logana").setup(opts)`: see `lua/logana/defconfig.lua` for all options.
- `require("logana").open()`
- `require("logana").refresh(rule_buf, { force = false })`

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