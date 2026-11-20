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
- [ ] Prototype loading level 1 through neovim's C file reader instead of Lua: rg
  output to a temp file, read into the result buffer, match columns from rg byte
  offsets (as level 2 does). Lua parsing is ~1.56 s of the 2.05 s on `large`, mostly
  making the line strings. Open: rg `--heading` prints the path without our `file: `
  prefix, and how to keep streaming. Measure offline first.
  (MapReduce/Spark won't help: rg is already fast, the cost is on neovim's main thread.)
  Measured offline on `large`: rg `--heading` to a file 180 ms, `:read ++bin` of it
  (135 MB, 740k lines) 90 ms; columns from a second rg `-o --column --sort path`
  230 ms (can run alongside) + 210 ms Lua parse. About 0.5 s vs 2.05 s now. To solve:
  - both rg runs must list files in the same order: `--sort path`, which makes rg
    single-threaded over directories
  - `-A/-B/-C` context lines show in the lines run but not in `-o`: override with
    `--context 0` (the result already drops context lines)
  - headers: rg prints the bare path, rewrite those few rows to `file: <path>`
  - level 2: run `-o --column` over the source files and keep matches on result rows,
    instead of feeding the texts on stdin (no 120 MB hl_input string)
  - no streaming: first lines at ~0.3 s instead of ~30 ms, but done in ~0.5 s;
    the longest block is the ~90 ms read plus the column parse (can be batched)
