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
