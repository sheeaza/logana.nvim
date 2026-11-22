# TODO

Open items. Resolved ones (done or cancelled) are in `DONE.md`.

## Result file order

rg searches files in parallel and writes each file's block of matches when its thread
is done, so the order of the blocks in the result can change between two refreshes
over the same files (lines inside a file are always in order).

- [ ] Fixed file order, rg on all cores: rg has no ordered parallel mode (`--sort path`
  is single-threaded, 2.5-3.4x slower on 3213 files), and holding back blocks can't
  tell a file without matches from one not searched yet. Instead:
  - the file list: `opened_only` has it (buffer order); a directory search lists the
    files first with `rg --files` and the same args (~5 ms for 3213 files), sorted by
    path
  - split into consecutive chunks of about equal bytes, one per core, each searched by
    its own `rg -j1` (keeps the given order) into its own memfd, all at once
  - chunk 1 streams into the result; once its rg exited the chunk is complete, then
    chunk 2 (often already done), ... rg's exit is the "done" signal hold-back lacked
  - one rg as now: a single file, a user `-j`/`--threads`/`--sort`, no memfd (pipe /
    `vim.system`), a command line too long (`ARG_MAX`)
  Shell timings: 8 `rg -j1` ~160 ms vs one parallel rg ~150 ms (`CLIENT_MGR`), one
  spawn ~2 ms. Memory: the memfds hold what isn't scanned yet, as now; worst case (a
  slow first chunk) the whole rg output, 161 MB on `large`, freed as it's read. Not in
  `rss_MB` (shmem, read with `pread`). Measure on one file and the split log, also with
  the largest file first.

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
