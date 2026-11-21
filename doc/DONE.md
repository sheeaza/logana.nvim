# Done

Resolved items from `TODO.md` (done or cancelled, with the measurements).

## Performance

Numbers are for the `large` case of `tests/bench.lua` (740k result lines), see
`tests/README.md`.

- [x] Find out why streamed level 1 parsing took twice as long (3211 ms vs 1592 ms in
  one pass): the GC re-marking the per-row match tables and per-line texts that are
  alive while streaming. Not the batch size or rg running alongside.
- [x] Keep match ranges in flat arrays instead of one table per row, and join the
  level 2 input per batch: `large` total 3881 -> 2727 ms, RSS 1336 -> 907 MB.
- [x] ~~Size level 1 batches by time instead of 1 MB~~: not needed, the pump already
  takes only what rg sent so far, ~110 KB / ~500 lines, ~1.5 ms per batch. The few
  slow ones (30-100 ms) are GC steps, and the first write (~75 ms) replacing the old
  result. Instead made less garbage per line (positions for `<lnum>: ` and the text):
  `large` total 2727 -> 2048 ms.
- [ ] ~~Later, if still worth it: `collect_highlights`, save/restore folds~~: cancelled.
  `collect_highlights` is ~100 ms on `large`, but the bench's [highlight] rules match
  few lines; it runs synchronously (blocks for its whole time) and grows with the
  number of highlight matches, so revisit if broad [highlight] rules get slow.
- [x] Prototype loading level 1 through neovim's C file reader instead of Lua: rg
  output to a temp file, read into the result buffer, match columns from rg byte
  offsets (as level 2 does). Lua parsing is ~1.56 s of the 2.05 s on `large`, mostly
  making the line strings. Open: rg `--heading` prints the path without our `file: `
  prefix, and how to keep streaming. Measure offline first.
  (MapReduce/Spark won't help: rg is already fast, the cost is on neovim's main thread.)
  Measured offline on `large`: rg `--heading` to a file 180 ms, `:read ++bin` of it
  (135 MB, 740k lines) 90 ms; columns from a second rg `-o --column --sort path`
  230 ms (can run alongside) + 210 ms Lua parse. About 0.5 s vs 2.05 s now. To solve:
  - both rg runs must list files in the same order. `--sort path` is NOT acceptable:
    it makes rg single-threaded, and multi-GB inputs must stay multi-threaded. Needs
    a design with one rg run (lines and columns from the same output)
  - `-A/-B/-C` context lines show in the lines run but not in `-o`: override with
    `--context 0` (the result already drops context lines)
  - headers: rg prints the bare path, rewrite those few rows to `file: <path>`
  Single-run design, prototyped offline (`large`): keep the one rg run with match
  markers and `--heading` (a header is the first line or the line after a blank one),
  and scan each ~1 MB batch with a LuaJIT FFI byte loop that copies the lines minus
  the markers into a C buffer, records match columns, rows and the level 2 text,
  with no Lua string per line. Write the buffer to a temp file and `:$read ++bin` it.
  Level 1 ~0.57 s vs ~1.9 s, longest batch 12 ms vs 78 ms, streaming kept, rg stays
  multi-threaded. To handle: `file: ` prefix on headers (write it while copying),
  force no context (`-A 0 -B 0` last), `:read` moves the cursor of windows showing
  the buffer, and keep the current Lua parser as a fallback when there's no LuaJIT.
  Done, measured on a synthetic 400 MB log on another machine (`large` level 1
  3.9 -> 1.6 s, see `tests/README.md`). Differences from the plan: the rg output
  keeps `--null` and no `--heading` (headers come from comparing each line's path
  with the previous one), so context lines are skipped as before and no `-A 0 -B 0`
  is needed; `:read ++ff=unix ++enc=utf-8 ++bad=keep` instead of `++bin`, which set
  'binary'; one `:read` per 1 MB or 100 ms instead of per pump batch (~100 KB), and
  the temp file in memory: an anonymous memfd on Linux (`:read /proc/self/fd/<n>`),
  else a file in `stdpath('run')`. Rewriting it on a disk cost more than reading it.
- [ ] ~~Search one multi-GB file with several threads (klogg does this: 10k-line
  chunks to N matcher threads, hits stored as `chunk start + offset` in a roaring
  bitmap, which merges in any order; lnav doesn't split a file). rg uses one thread per file
  (`-j 1` and `-j 16` both ~0.08 s, ~95% of one CPU on the 500 MB `xaa`), so a big
  file needs splitting into chunks / byte ranges, searched in parallel, with results
  put back in file order and line numbers offset per chunk.~~: cancelled, not worth
  the code. Measured on a synthetic 1 GB log (18M lines, 8 cores): rg alone on 8
  chunk files `-j 8` is 2.58 -> 0.72 s for 4.78M matches, 0.41 -> 0.18 s for 361k,
  but the refresh is neovim-bound when matches are many (level 1 4178 ms, ~2.8 s of
  it parse + `:read`), and only ~290 ms when they are few. rg can't search a byte
  range (pipes cost more than they gain, chunk files mean copying the file), line
  numbers need a newline count up to each split, and N outputs need merging in order.
- [x] Lazy level 2: compute [highlight] only for rows as they're drawn (as klogg
  does), caching per row, instead of all rows at the end of a refresh. neovim's regex
  isn't rg's syntax, so it would mean calling rg for the visible rows.
  Done: on_line marks rows without ranges, on_end starts one async rg per rule over
  their texts (read from the buffer), the windows redraw when they're in. Visible rows
  get colors while level 1 still loads, and level 1 no longer collects the level 2
  input: `large` total 5097 -> 1298 ms, RSS 1471 -> 224 MB, one screen ~25 ms.

Next, after `posix_spawn` (`large` total ~803 ms: parse ~342, `:read` ~248, the rest
waiting on rg and the pump). For static log files; re-searching only the bytes a
growing log appended is out of scope.
- [x] `scan_batch` copies and tests byte by byte (~2.5 ns/byte). Find `\n` and the
  match markers with `memchr`, copy the runs between them with `ffi.copy`, compare
  the path with `memcmp`.
  Done. Measured on a synthetic 500 MB log (8.8M lines, `large` is `Display`, 1.1M
  rows, i5-12500H): `scan_batch` alone over the 94 MB rg output 264 -> 176 ms; in
  the bench `parse` 419 -> 282 ms, but `level1` only 974 -> 915 ms, rg's pipe is
  the limit now (next item).
- [x] rg writes to a pipe of 64 KB that nothing reads while a batch runs on the main
  thread, so rg stalls; each chunk is also a Lua string, joined and cut per batch.
  Point rg's stdout at a memfd (`posix_spawn_file_actions_adddup2`), `mmap` it and
  scan the bytes up to its current size, so rg runs ahead and no output string is made.
  Done, with `pread` into a reused C buffer instead of `mmap`, the pages read given
  back with `fallocate` (punch hole), the pump polling every 3 ms while rg runs; the
  pipe stays when there's no `posix_spawn`. Same log as above: `level1` 931 -> 732 ms
  (`parse` 292 -> 220, `set_lines` 240 -> 167), RSS 192 -> 164 MB. rg alone takes
  ~640 ms of it (single threaded on one file): its `--replace` markers ~180 ms, `-n`
  ~140 ms. A 1 MB pipe (`F_SETPIPE_SZ`) instead got 931 -> 845 ms.
- [x] Keep the level 1 ranges (`first`, `count`, `cols`, ~2.2M numbers on `large`) in
  ffi `uint32_t` arrays grown by doubling, instead of Lua tables, which rehash inside
  a batch at each power of two.
  Done: `cols` and a `start` per row (where its ranges begin, the next row's is where
  they end) in two ffi arrays, `count` dropped. Same log: `scan_batch` alone 185 ->
  137 ms, `parse` 220 -> 186, `level1` 732 -> ~715 ms, RSS 164 -> 123 MB. `max_batch`
  stays ~65 ms, so the longest batch wasn't the rehash. Reserving room per batch
  (half its bytes as rows) instead of checking per row doubled the arrays on every
  batch of a small result, 3x slower there.
- [x] The bench only searches one file. Add a case over many files (10k+): `apply_folds`
  runs two ex commands per file and `capture_folds` a `foldclosed` per file.
  Measured, no change needed: 10k files (the same log split), folds ~10-20 ms, also
  with all closed, see `tests/README.md`. `max_batch` is ~100 ms there vs ~65 ms on
  one file, for the `:read` item below.
- [x] Scrolling: level 2 starts one rg per rule on every redraw with new rows, holding
  `<C-d>` can start dozens. Debounce the requests from `on_end`.
  Done as a throttle instead, no delay when idle: one request per buffer at a time, rows
  drawn meanwhile go in the next one together. 200 `<C-d>` + redraws, headless, 3
  rules, neovim's CPU (no rules: 95 / 168 ms): 2 ms apart 493 -> 256 ms, 600 -> ~370
  rg runs; 33 ms apart (key repeat) unchanged at ~595 ms, each request is done
  before the next redraw. So level 2 costs ~2 ms of CPU per screen of new rows.
- [x] `:read` (~248 ms, ~55 of it clearing the old result) is neovim's memline. Find
  out where it goes (`perf`), whether any of it can be avoided from Lua.
  Found (`perf`, offline: the 1.1M `large` lines read in 73 pieces of 1 MB): the
  reads take ~60 ms, `readfile` and `ml_append` mostly, nothing to win there. Clearing
  the old lines takes as long, ~60 ms, all in the first batch: `nvim_buf_set_lines`
  deletes line by line (`ml_delete`, its `memmove`s) and counts the bytes of every
  line for buffer update events (`get_region_bytecount`, ~1/4 of it). `:%delete _`
  skips the counting: 61 -> 47 ms; deleting from the end in chunks was ~10x slower.
  Done with `:%delete _`: bench `max_batch` 64 -> 50 ms, `set_lines` 160 -> 148 ms.
  The rest of `set_lines` vs offline (~150 vs ~120 ms) is the memfd writes and
  keeping the window views.

## Cleanup

From a review of the modules after the split.
- [x] `log.lua` is vlog with its defaults: every `log.trace` appends to
  `stdpath('data')/vlog.nvim.log` (open/write/close, `debug.getinfo`, `os.date`),
  ~10 lines per refresh and one per lazy level 2 request, growing forever. Only
  `tests/bench.lua` reads the traces, and it replaces `log.trace`: make it a no-op.
  Done, `log.lua` is 5 lines now.
- [x] Free a result's state on `BufWipeout`: `highlight.by_buf[buf]` (the match
  arrays, tens of MB on `large`) and `refresh.state[rule_buf]` are never cleared.
  Done; wiping the rule buffer also stops its level 1 run, which used to apply
  [fold] from the wiped buffer at the end.
- [x] ~~Skip one copy per level 1 batch~~: the pump makes `data:sub(1, cut)` to drop
  the partial last line; the ffi scanner could take `cut` as its length. Measured,
  no difference (`large` parse 354-386 ms before, 352-388 after), not kept.
- [x] Drop the `pcall`s around `vim.uv.fs_stat` (returns nil, doesn't throw) and
  around 'filetype' lookups on valid buffers.
- [x] The first level 1 write clearing the previous result (738k lines) blocks ~245
  ms, the largest `max_batch`, with either parser. Find out where it goes.
  Found: clearing the 738k lines alone takes ~55 ms, but ~220-250 ms after neovim
  started any process (level 1 rg, the lazy level 2 rgs, even `true`): libuv forks,
  which makes neovim's pages copy-on-write, and freeing the lines then takes a page
  fault on each of ~31k pages. Not specific to the clear: the first write to any
  old page after a spawn pays it.
  Tried: clearing at <Enter>, before rg starts: no gain, level 2 spawns rg on most
  redraws, so a fork had just happened (the ~250 ms moved to `first`). Also
  considered: loading into a new buffer and wiping the old one, but the result
  would get a new buffer number every refresh (marks, `#`), and freeing its lines
  most likely hits the same faults. Kept as is.
- [x] Start processes without fork: `posix_spawn` (glibc uses `CLONE_VM|CLONE_VFORK`,
  no page tables copied, so no copy-on-write faults) through the LuaJIT ffi, or a
  small helper process started early that spawns rg for us. Would also make each
  spawn itself cheaper with a large neovim.
  Done with `posix_spawn` (`proc.lua`, linux + LuaJIT, `vim.system` elsewhere):
  `large` total 1063 -> 803 ms, max_batch 251 -> 57 ms, one screen of level 2
  25 -> 6 ms.
- [x] Maybe: require LuaJIT and drop the lua parser (~100 lines, the `write`/pump
  branches, half the test runtime). Costs the few platforms built with PUC Lua.
  Done: `scan.lua` errors without LuaJIT, tests run once.

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

## Highlight

- [x] Better default colors, the same with every colorscheme. Now `match_color` links
  `TermCursor` and `highlight_colors` link `IncSearch`, `DiffAdd`, `DiffChange`,
  `DiffText`, `Substitute`, `MatchParen` (`defconfig.lua`): they change with the theme,
  and some barely stand out from the log text. Use fixed colors instead of links (both
  `fg` and `bg`, so the text stays readable on dark and light backgrounds), clearly
  distinct from each other: 10 for `highlight_colors`, and `match_color` along with
  them.
  - done: black text on 10 light hues (yellow, green, blue, red, purple, cyan, orange,
    pink, lime, tan); `match_color` bold white on gray, so it stays behind them
  - a `ColorScheme` autocmd defines the groups again (`:hi clear` empties them)
- [x] In a result buffer, visual select some text, <Enter>: toggle a highlight for it
  through `[highlight]` in the rule buffer: if there's no line for the text, add
  `-e '<text>'` under `[highlight]`, else remove that line, then rerun level 2. The
  text is taken as `[highlight]` takes it (a regex, unless its flags say otherwise,
  e.g. `-F`), quoted for the rule parser.
  - "has a line for the text" means a line that is exactly `-e '<text>'` (as the
    toggle adds it); patterns inside other lines aren't looked at or changed
  - single line selections only (charwise, within one line); otherwise a short
    message that only single line selections are supported
  - the rule buffer is edited like any buffer (left modified, not saved), nothing
    else changes, it still doesn't ask to save on quit as now
  - key in the config, `key.result_toggle_highlight = '<cr>'` (visual mode)
  - the new line goes at the end of the `[highlight]` section; the text is the
    selection as is (a `<lnum>: ` prefix in it isn't trimmed)
  Done: `rule.toggle_highlight`, the keymap in `init.lua`. Changed from the plan: the
  line is `-F -e '<text>'`, a selection is matched as is (regex characters, quotes)
  rather than as a regex; in `""` when the text has a `'`. The rule parser has no
  escapes, so text with both quotes (or a `\` before the closing one) gets a warning
  instead. Before adding, rg checks the line with the section's flags (async, over
  empty stdin), a warning and nothing added if it fails. A result buffer that wasn't
  rendered in this session finds its rule buffer by name (`x.logana_result` ->
  `x.logana_rule`, if loaded).
- [ ] ~~Like the highlight toggle: select text in the result, a key adds it to `[rg]` as
  an exclusion (rg has no per-pattern invert; decide how: a level 1 post-filter, or a
  separate `[exclude]` section run as a second rg over the result lines).~~: cancelled,
  not needed, not practical.
- [ ] ~~On a `file: <path>` header, a key adds `-g '!<path>'` to `[rg]` to drop that
  file.~~: cancelled, not needed now, done by hand in the rule.
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
- [x] Editing from the result buffer doesn't refresh: the user refreshes by hand with
  `<Enter>` in the rule buffer. Today the visual `<Enter>` toggle edits `[highlight]`
  and calls `refresh_from_rule` right away (`init.lua`, `toggle_selection_highlight`);
  it should only edit the rule buffer. Update the README (Toggling a highlight) to match.
  Edits typed in the result buffer stay as they are (no refresh), and the next refresh
  throws them away: the result buffer is volatile, edits meant to last go in the source
  file. Say so in the README.
  Done: `toggle_selection_highlight` only calls `rule.toggle_highlight`, no
  `refresh_from_rule`. The toggle tests check the colors stay until a refresh. README:
  Toggling a highlight says to press `<Enter>` in the rule buffer, Refresh says the
  result buffer is volatile.

## Time

- [ ] ~~Merge several files by timestamp instead of listing them file by file (lnav does
  this). Needs a timestamp format (config or detected), and rg output comes in file
  order, so the merge happens after level 1. Design first, measure on `large`.~~:
  cancelled, out of scope: leave merging logs to other tools (lnav, `sort -m`), keep
  logana simple.

## Packaging and docs

- [x] `.gitignore` for local test files at the top level: `*.logana_rule`,
  `*.logana_result`. Not `test-*.log` (left out on purpose).
- [x] README install snippet says `"yourname/logana.nvim"`: put the real repo name.
  Done: `"sheeaza/logana.nvim"`.
- [x] `:checkhealth logana`: LuaJIT, rg found and its version, `posix_spawn` / memfd path
  available or the fallback in use.
  Done: `lua/logana/health.lua`. Also warns when `setup()` wasn't called. Without
  posix_spawn or memfd it's info, not a warning: the fallbacks work, only slower.
  Test: no error or warning on linux.
- [x] `doc/logana.txt`: vimdoc help (`:h logana`), from the README.
  Done: same sections as the README (Install, Usage, Config, API, plus Health), a tag
  per section, config option and highlight group. A README change needs the same one
  there. `/doc/tags` (made by `:helptags`) in `.gitignore`.

## Robustness

- [x] Tests for edge cases: CRLF logs, invalid UTF-8, very long lines, paths with spaces
  or `:`, editing the rule buffer while level 1 is loading.
  Found and fixed:
  - hit count marks were set when level 1 ended, on the line numbers parsed when it
    started: an edit while loading put them on the wrong lines. Now placed at the
    start (`count.place`), filled in at the end (`count.start`)
  - CRLF lines kept their `\r` (`^M` in the result, `[highlight]` `$` not matching
    while the `ff=dos` source window did). Now dropped in `scan_batch`, a match ending
    on it cut. Same timing on `test-1g.log` (450k lines, within noise). A hit count of
    an `[rg]` pattern matching the `\r` itself is 0 (the counts run on the stripped texts)
  Already fine, now tested: invalid UTF-8 in level 2 and the counts (a file starting
  with `\xff\xfe` is read by rg as UTF-16), a 2 MB line, paths with spaces and `:`
  (headers, jump, `[fold]`, `opened_only = false`), the rule buffer emptied or
  `[fold]` added while loading.
- [x] CI job on macOS, so the path without `posix_spawn` (`vim.system` and the pipe) and
  without memfd (temp file in `stdpath('run')`) is tested.
  Done: a `macos-latest` job (v0.12.6, ripgrep from Homebrew) in `test.yml`, checked
  with actionlint; its first run is on the next push. Run on linux first with
  `proc.enabled = false` and a preloaded `memfd_create` that fails (how in
  `tests/README.md`): level 1 over a pipe hung on a line over 1 MB, fixed (a pump batch
  always takes a chunk). Test for it with `proc.enabled = false`, in the linux job too.
