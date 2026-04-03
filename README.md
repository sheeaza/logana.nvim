# logana.nvim

Lightweight log analyzer for Neovim. Open a rule buffer where each line is a Vim regex under a [match] section. Press Enter in the rule buffer to refresh a bound result buffer that lists matching lines and highlights the matched text.

## Features
- Rule buffer with [match] section; each non-empty, non-comment line is a Vim regex
- Searches the current source buffer (e.g., a log file) against all listed patterns
- Result buffer shows lines in the format: line: <the matched line>
- Highlights the matched substring with a dedicated highlight group
- Press Enter in the rule buffer to refresh results instantly
- Simple command: :Logana (optionally ":Logana refresh")

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
1) Open a log file in a buffer (this is the source buffer).
2) Run :Logana to open two panes on the right:
   - Top-right: Rule buffer (scratch, filetype: logana_rules)
   - Bottom-right: Result buffer (scratch, filetype: logana_results)
3) In the rule buffer, define your regex rules under a [match] section:
  ```ini
   [match]
   # Each line is a ripgrep regex.
   xx.*[abc]
  ```
4) Press Enter in the rule buffer to refresh results.
5) The result buffer will list all matched lines prefixed with:
   `<line>: <the matched line>`
   and will highlight the matched substring(s) with the LoganaMatch group.

## Notes on Regex
- Patterns are Vim regex (not Lua patterns). Consider using \v at the start for very-magic mode.
- Each rule line is compiled and applied independently to each line of the source buffer.
- If a line matches multiple patterns, it may appear multiple times in the results (once per matching rule).
- The current version highlights the first match per line for each rule; duplicates of the same physical line can occur if multiple rules match.

## Commands
- :Logana [refresh|bufnr]
  Context-aware unified command. Behavior:
  - If run in a Logana rule buffer: ensures a result buffer exists and refreshes it.
  - If run in a non-rule buffer with no args: opens rule/result panes bound to the current buffer.
  - If provided a numeric bufnr: opens panes bound to that buffer, e.g. :Logana 5
  - If provided the subcmd "refresh": attempts to refresh the current rule/result context.

## API
- require("logana").setup(opts)
  Initializes the plugin and defines the highlight group. Called automatically by the plugin loader but safe to call manually.
- require("logana").open({ source_buf = <bufnr> })
  Programmatically open the rule/result panes bound to a given source buffer (defaults to current).
- require("logana").refresh()
  Refresh from the current rule or result buffer context.

## Highlight Customization
- The matched substring is highlighted with the LoganaMatch group, which by default links to Search.
- You can override it in your config:
  vim.api.nvim_set_hl(0, "LoganaMatch", { fg = "#000000", bg = "#FFFF00", bold = true })
  or link it:
  vim.api.nvim_set_hl(0, "LoganaMatch", { link = "IncSearch" })

## Workflow Tips
- Keep one pane on your log file (source buffer) while you iterate on patterns in the rule buffer.
- Use \v to simplify complex Vim regex patterns.
- You can close the rule/result quickly by pressing q in the rule buffer.
- The rule buffer is a scratch buffer; it will be wiped when closed. Persist patterns by saving them elsewhere and pasting as needed.

## Limitations
- Highlights the first match per line for each rule. If you need multiple matches per line highlighted, that can be added in a future iteration.
- Operates on the currently loaded buffer contents only (no filesystem scanning).

## License
MIT