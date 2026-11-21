# TODO

Open items. Resolved ones (done or cancelled) are in `DONE.md`.

## Navigation

- [x] Hit counts per rule: how many result lines each `[rg]` pattern and each
  `[highlight]` line matches, as virtual text at the end of the rule line. For level 2
  that means a run over all result lines (not only the drawn ones), async.
  - counted over the result lines, not the source files: one `rg --count` per rule
    over the result texts (`<lnum>: ` prefix, headers and blank lines dropped), so
    a count is how many result lines that rule's rg matches
  - `[rg]`: a line with `-e`/`--regexp`/`-f`/`--file` is a rule; the flags of the
    other lines (`config.rg.args` too) are shared by every rule, paths in them
    dropped. `[highlight]`: the lines that get a color, with the shared flags, as
    level 2 runs them
  - level 1's scanner copies each line's text to a memfd as it goes (no lua string
    per line); kept until the next level 1 run, so a `[highlight]` change only
    reruns those counts
  - eol virtual text in the rule buffer: ` … ` while counting, then the number, in
    the rule's color (`LoganaMatch` / `LoganaHighlightN`); `!` when rg fails.
    Extmarks, so they follow edits; recomputed on refresh
  - `hit_count = false` in the config turns it off
  Done: `count.lua`, the texts in `scan.lua` (`p.txt`, `open_texts`). The counts run
  in `finish_refresh`, after level 1 is done. `test-500m.log` (8.8M lines), results of
  1.0M / 1.1M / 1.8M lines, `hit_count` off -> on: `level1` 374 -> 372, 450 -> 426,
  586 -> 591 ms (noise); the counts are in 31 / 36 / 57 ms after the refresh. The
  memfd holds a copy of the result texts (shmem, not in `rss_MB`) until the next level
  1 run or the rule buffer is wiped.
- [x] Context on demand: the source file's own window is the context, no float.
  - `<cr>` on a result row: if the source file is not in a window of the current tab,
    keep today's behavior (show it in the result window). If it is, go to that window
    and put the cursor on the row's line / col, with `m'` first so `<C-o>` goes back.
  - Follow: moving to another line in the result window moves the cursor of that
    source window too, without leaving the result window. Only when the result line
    changes (not the col, and not on entering the window: `CursorMoved` fires then),
    so after the user moves in the source window, going back to the result window
    does not undo it until they move there. Never opens or loads a buffer, no jumplist
  - Several windows on the same file: the first one in `nvim_tabpage_list_wins(0)`
    order, never the result window itself (`override` mode)
  - The `file:` header of a row: from the header rows level 1 records, binary
    searched, not `search('^file: ', 'bn')` per cursor move
  - `result_win.follow = false` in the config turns follow off
  Done: `row_source` / `source_win` / `follow` in `result.lua`, the `WinEnter` (records
  the row, it comes before the `CursorMoved` of entering) and `CursorMoved` autocmds in
  `init.lua`. The source window is found by full path, `bufnr()` took a pattern
  (`a.log` also found `ba.log`). The header rows (`st.file_rows`, the folds' rows) are
  used when no run is loading and the result isn't edited, else `search()`.
  `test-500m.log`, a 1.1M row result of one file, one follow at rows 2 / 550k / 1.1M:
  0.04 / 0.02 / 0.02 ms, with `search()` 0.03 / 22 / 44 ms.
- [x] `[highlight]` colors in the source file's window too, only for the lines on screen
  (the source can be huge), the same lazy way as the result: rows ask for level 2 as
  they're drawn, one rg per rule over their texts from stdin, cached per row.
  - only level 2: the `[rg]` match color stays in the result
  - only a buffer that is a source of a rule buffer's result (a `file:` header of it,
    by full path), bound to the rule buffer: in any tab, also with the result closed
    or wiped, until the rule buffer is wiped. Of several, the last refreshed one
    (first done as "a result shown in the window's tab", changed to this)
  - the cache is dropped when those rules change, or the source buffer changes
    (changedtick: edits, `:e`)
  - `highlight.hl_buf = false` in the config turns it off
  Done: `source_highlights` in `highlight.lua`, the source's own state in
  `SOURCE_HIGHLIGHTS` (`src = true`, same lazy request path as the result, whole lines
  as rg input). The source paths are a set per `file_rows`, extended while level 1 loads.
  After a refresh the non-result windows are redrawn (`redraw_sources`). `test-500m.log`
  (8.8M lines) in the source window: a screen at the top / middle / end colored in
  2.1 / 2.5 / 2.3 ms, only the drawn rows cached. Wiping a rule buffer redraws them too.

## Rules from the result

- [ ] On a `file: <path>` header, a key adds `-g '!<path>'` to `[rg]` to drop that file.

## Time

- [ ] Merge several files by timestamp instead of listing them file by file (lnav does
  this). Needs a timestamp format (config or detected), and rg output comes in file
  order, so the merge happens after level 1. Design first, measure on `large`.

## Packaging and docs

- [ ] `doc/logana.txt`: vimdoc help (`:h logana`), from the README.
- [ ] README install snippet says `"yourname/logana.nvim"`: put the real repo name.
- [ ] `:checkhealth logana`: LuaJIT, rg found and its version, `posix_spawn` / memfd path
  available or the fallback in use.
- [ ] `.gitignore` for local test files (`test-*.log`, `*.logana_rule`, `*.logana_result`
  at the top level).

## Robustness

- [ ] Tests for edge cases: CRLF logs, invalid UTF-8, very long lines, paths with spaces
  or `:`, editing the rule buffer while level 1 is loading.
- [ ] CI job on macOS, so the path without `posix_spawn` (`vim.system` and the pipe) and
  without memfd (temp file in `stdpath('run')`) is tested.
- [ ] Bench gate: `tests/bench.lua <log> --save <file>` writes the medians per case
  (`first`, `max_batch`, `level1`, `total`, `rss_MB`, and `count`: until the hit counts
  are in) to a baseline file; `--gate <file>` reruns and exits 1 when a column of a
  case is over its baseline by more than 15% and 10 ms (rss: 15% and 10 MB), printing
  the offending cells. The baseline is machine specific, so it's kept out of the repo:
  save it on the commit before a change, gate after. A `--gen <MB>` option writes a
  synthetic log (fixed seed, the cases' patterns at known rates) for a machine without
  the camera log.
- [ ] Bench case with a broad [highlight] rule (matching most lines), to see whether the
  cancelled `collect_highlights` item (`DONE.md`) is worth reopening.

## Low priority, not planned

Hopping match to match (`]h`, `]q`) isn't the intended workflow: the result buffer is
the list, `<Enter>` and follow go to the source. Kept in case that changes.

- [ ] `]h` / `[h` in a result buffer: jump to the next / previous [highlight] match,
  maybe per color (a count or a key per `LoganaHighlightN`). The level 2 ranges are
  only known for rows already drawn (lazy level 2), so jumping past the screen needs
  an rg run over the rows below / above.
- [ ] Quickfix export: put the result rows in the quickfix / location list (file, line,
  col of the first match), so `:cnext` and pickers work on them.

## References

Read 2026-11-20, shallow clones of github.com/variar/klogg and github.com/tstack/lnav.
- Neither keeps line text in memory: an index of line offsets (klogg: delta-encoded
  blocks of 128 with streamvbyte; lnav: 16 bytes per line), text read on demand for
  the visible rows only.
- Matches are integer sets (klogg: roaring bitmap; lnav: `uint32` vectors / btree of
  line numbers), streamed to the UI in batches (klogg throttles to 100 ms, lnav every
  10k lines).
- Highlights are computed at render time for visible rows only, no per-line cache.
- klogg uses Hyperscan with all patterns in one database; lnav runs up to 32 PCRE2
  patterns in one pass, in forked child processes.
