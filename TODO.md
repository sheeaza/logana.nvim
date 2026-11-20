# TODO

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
  the temp file in `stdpath('run')`: rewriting it on a disk cost more than reading it.
- [ ] Search one multi-GB file with several threads (klogg does this: 10k-line
  chunks to N matcher threads, hits stored as `chunk start + offset` in a roaring
  bitmap, which merges in any order; lnav doesn't split a file). rg uses one thread per file
  (`-j 1` and `-j 16` both ~0.08 s, ~95% of one CPU on the 500 MB `xaa`), so a big
  file needs splitting into chunks / byte ranges, searched in parallel, with results
  put back in file order and line numbers offset per chunk.
- [ ] Lazy level 2: compute [highlight] only for rows as they're drawn (as klogg
  does), caching per row, instead of all rows at the end of a refresh. neovim's regex
  isn't rg's syntax, so it would mean calling rg for the visible rows.

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
