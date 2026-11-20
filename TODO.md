# TODO

## Performance

Numbers are for the `large` case of `tests/bench.lua` (740k result lines), see
`tests/README.md`.

- [x] Find out why streamed level 1 parsing took twice as long (3211 ms vs 1592 ms in
  one pass): the GC re-marking the per-row match tables and per-line texts that are
  alive while streaming. Not the batch size or rg running alongside.
- [x] Keep match ranges in flat arrays instead of one table per row, and join the
  level 2 input per batch: `large` total 3881 -> 2727 ms, RSS 1336 -> 907 MB.
- [ ] Size level 1 batches by time (~16-30 ms) instead of 1 MB, so input never waits
  more than a frame or two. Total time stays about the same.
- [ ] Later, if still worth it: `collect_highlights` (148 ms), save/restore folds.
