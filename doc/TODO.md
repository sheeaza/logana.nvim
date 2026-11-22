# TODO

Open items. Resolved ones (done or cancelled) are in `DONE.md`.

## Result file order

rg searches files in parallel and writes each file's block of matches when its thread
is done, so the order of the blocks in the result can change between two refreshes
over the same files (lines inside a file are always in order). `--sort path` fixes it,
but makes rg single-threaded. Measure each item with `tests/bench.lua`, on one file and
on a split log (`split -l 882 -a 5 -d <log> <dir>/f`, ~10k files), also with the
largest file listed first.

- [ ] `opened_only`: the file list is known (`get_valid_opened_files`, buffer order).
  Write a file's block only once all files before it in the list are written. Blocks
  that come early wait in memory. No extra CPU: watch `first` (grows when an early
  file is slow, worst case its whole search time), `max_batch` (the held blocks must
  still be written in batches, not in one burst) and `rss_MB`.
- [ ] Directory search (`opened_only = false`): list the files first with `rg --files`
  (same globs and ignore rules), sorted by path, pass them as explicit paths and order
  the blocks as above. Cost: the extra walk, added to `first`. Fall back to rg's own
  order when the list is too long for one command line (`ARG_MAX`).

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
