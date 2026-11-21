# TODO

Open items. Resolved ones (done or cancelled) are in `DONE.md`.

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
