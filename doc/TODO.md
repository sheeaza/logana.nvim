# TODO

Open items. Resolved ones (done or cancelled) are in `DONE.md`.

## Features

- [ ] Sticky `file:` header in the result buffer: the header of the file the top row
  of the window belongs to stays on top while scrolling, e.g. in the window's winbar
  (or a floating window over the first line), updated on scroll (`WinScrolled`,
  `CursorMoved`), found with the `file_rows` binary search `header_file` already does.
  Hidden when the top row is the header itself.

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
