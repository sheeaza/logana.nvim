# Design

The data flow of logana: what each piece of data is computed from, where, and
whether it is sync, async or streamed. The first part is the whole flow on one
page; the second goes through it block by block. For usage see `README.md`, for
timings `tests/README.md` and `doc/DONE.md`.

## 1. Data flow

### Execution contexts

Every step runs in one of four places:

```
+------------------+   vim.schedule    +---------------------+
| fast callback    | ----------------> | main loop (sync)    |
| libuv: rg stdout |                   | Lua + ffi, blocks   |
| chunk, rg exit,  |                   | the UI while it     |
| timers           |                   | runs                |
+------------------+                   +---------------------+
         ^                                ^           |
         | pipe / exit                    | redraw    | spawn
         |                                |           v
+------------------+                   +---------------------+
| rg child process |                   | decoration provider |
| (parallel, own   |                   | on_win/on_line/     |
| cores)           |                   | on_end, sync,       |
+------------------+                   | inside a redraw     |
                                       +---------------------+
```

- **Main loop** `[M]`: parsing the rule buffer, scanning a batch, `:read`, folds,
  extmarks. Kept short per step so the UI stays responsive.
- **Fast callbacks** `[F]`: libuv callbacks, on the main thread too, but at points
  where most of the API can't be called. They only queue data or set a flag, then
  `vim.schedule` the work.
- **Decoration provider** `[D]`: runs inside a redraw; it only reads the match and
  highlight columns in memory and records rows it lacks. It never starts a process.
- **rg processes** `[P]`: all matching, on other cores. Level 1 (one run), level 2
  (one run per `[highlight]` rule, per batch of drawn rows), hit counts (one run
  per rule).

### Map

Arrows show how each value is produced, and in which execution contexts:

| Arrow | Kind | Contexts |
| --- | --- | --- |
| `==>` | streamed, filled batch by batch while rg runs | `[P]` rg writes -> `[F]` queue -> `[M]` scan batch |
| `~~>` | async, computed later by rg, back via a callback | `[M]` spawn -> `[P]` rg -> `[F]` exit -> `[M]` apply |
| `-->` | sync, computed at once | `[M]` only |

The tag on a node is the context the value is computed in. `[P]` and `[F]` only
appear on arrows: rg and the fast callbacks produce or pass data on, they don't
hold any. `[D]` only reads data and asks for missing rows.

```
 rg cmd [M] --+
              +==> rg output [P] ==+==> result lines [M] ---+
 files -------+                    |                        +~~> highlight columns [M]
                                   |        hl rules [M] ---+    (rows asked by [D])
                                   |
                                   +==> match columns [M] -------> drawn by [D]
                                   |
                                   +==> file_rows [M] ------+--> folds <--> [fold] [M]  (once level 1 is done)
                                   |                        +--> jump [M]
                                   |                        +~~> source highlight columns [M]
                                   |                             (rows asked by [D], + hl rules, source lines)
                                   |
                                   +==> count texts [M] ----+~~> hit counts [M]         (once level 1 is done)
                                          count rules [M] --+

 rg cmd + files (size, mtime) --> match_sig [M] : level 1 reruns when it changes
 hl rules                     --> hl_sig    [M] : level 2 resets when it changes
```

- **Streamed**: everything level 1 makes. Level 2 (result and source files) and
  `on_line` already read the rows, match columns and `file_rows` loaded so far.
- **Async**: level 2 (per batch of drawn rows, one rg per rule) and hit counts (one
  rg per rule over the whole count texts, started when level 1 is done).
- **Sync**: the signatures, folds (made after level 1 is done, skipped while
  loading) and jump.

Two roots decide almost everything: `match_sig` (level 1 and all that comes from
its output) and `hl_sig` (level 2 and the `[highlight]` counts). Level 2 depends
only on the result rows, never on the files on disk, so a `[highlight]` change
never reruns level 1.

Level 1 data stays out of Lua objects on purpose: one table or string per row made
the GC re-mark millions of objects while a large result streamed in.

## 2. Blocks

### rg cmd, rules and signatures `[M]`

```
 rule buffer lines --> sections --> split on spaces, '/" quoting
                                      |
      +-------------------------------+------------------------------+
      v                               v                              v
  [rg] + [file]                  [highlight]                     [rg], [highlight]
  config.rg.args, level1.ARGS,   flag-only lines put in front    one rule per pattern line,
  -g excludes, opened files      of each pattern line            other lines' flags in front
      |                               |                              |
  rg cmd (args_common)           hl rules (hl_rules)             count rules
  match_sig = cmd + size:mtime   hl_sig = hl rules joined        (rg_counts, hl_counts)
```

- `rg cmd` is everything level 1 passes to rg: the `[rg]` lines, `config.rg.args`,
  the output format (`level1.ARGS`), the rule/result excludes, and with
  `opened_only` the opened files as paths. The files' size and mtime only go in
  `match_sig` with `opened_only`; with a directory search, a refresh where nothing
  else changed reruns level 1.
- Computed on every refresh, then compared with the refresh state:
  `match_sig` differs, or the result buffer was edited or is gone -> level 1;
  only `hl_sig` differs -> level 2 reset.
- `st.match_sig` is cleared when level 1 starts and set when it finishes, so an
  interrupted run always reruns.

### rg output `[P]` ==> pump `[M]`

```
 [M] spawn ---------> [P] rg --stdout--> memfd (Linux) ----------------+
     posix_spawn                     or  pipe ---> [F] chunk: queue it, |
     (Linux) or                                    schedule pump        |
     vim.system                                                         |
                                                                        v
 [M] pump: read <= 1 MB of whole lines (pread, or join the queued chunks)
           scan the batch ==> result lines, match columns, file_rows, count texts
           more left  -> schedule pump
           memfd idle -> timer 3 ms -> pump
           pipe idle  -> timer 100 ms -> pump (show what's collected)
     [P] rg exits --> [F] exit: schedule pump --> [M] drained -> done
```

- **memfd on Linux**: a pipe holds 64 KB, and nothing reads it while a batch runs
  on the main loop, so rg stalled. With a memfd rg never blocks; the pump polls it
  and punches out pages already read (`fallocate`). Elsewhere a pipe, its chunks
  queued as Lua strings and joined per batch.
- **posix_spawn on Linux**: libuv forks, which made Neovim's pages copy-on-write
  until exec; with a large result loaded, the next writes page-faulted.
- **Stale runs**: `st.gen` is bumped per run; the pump and the exit callback drop
  out when it moved on. rg is killed (SIGTERM) when its run is replaced, the result
  buffer is wiped while loading, or the rule buffer is wiped.

### Scan ==> result lines, match columns, file_rows, count texts `[M]`

rg prints one line per match, each match wrapped in marker bytes:

```
 <path>\0<lnum>: <text with \30match\31>          (--null, --field-match-separator ': ',
                                                   --replace '\30${0}\31')
        |
        v  scan_batch (ffi: memchr, memcmp, ffi.copy, no Lua string per row)
        |
        +--> path changed?  blank row + 'file: <path>' row -----> file_rows { row, path }
        +--> row without markers -----------> p.out --> write --> result lines
        +--> marker positions ----------------------------------> match columns
        +--> row text without '<lnum>: ' ---> p.txt --> write --> count texts
```

- **write**, per 1 MB or 100 ms (each costs a file write): `p.out` goes to a memfd
  (else a file in `stdpath('run')`) and Neovim reads it with
  `:read ++ff=unix ++enc=utf-8 ++bad=keep`, its C reader instead of a Lua list.
  The first write replaces the buffer (`:%delete _`), the next ones append.
  `p.txt` is appended to the count texts.
- **match columns**: two ffi arrays, `start[row]` indexing into `cols`, which holds
  `start, end` pairs. Read by `on_line`.
- **count texts**: every result row's text, a memfd that rg reads as
  `/proc/<pid>/fd/<n>` (else a file in `stdpath('run')`). Only with `hit_count`.
- Context lines (`<lnum>-`) don't parse as matches and are skipped.
- **Stale when** level 1 reruns: all four are replaced. Edits to the result buffer
  set `st.result_dirty`: nothing refreshes, the next refresh reruns level 1.

### Highlight columns ~~> `[D]` `[M]` `[P]`

```
 [D] on_line(row): match columns -> ephemeral extmarks
                   hls.hl[row] = marks -> ephemeral extmarks
                   hls.hl[row] = nil   -> set false, row -> wanted
 [D] on_end: wanted rows -> request (one at a time per buffer, the rest queued)
        |
        v  vim.schedule
 [M] row texts from the buffer, joined with '\n'
        |
        v  stdin, one run per hl rule
 [P] rg --only-matching --byte-offset <rule> -
        |
        v  [F] exit, count down; last one -> schedule
 [M] apply: '<lnum>:<off>:<match>' -> hls.hl[row] = { {start, end, rule}, ... }
            redraw --> [D] on_line draws them; queued rows -> next request
```

- Only drawn rows are matched, so the cost is per screen, not per result. `false`
  means asked for, or no match.
- Ephemeral extmarks only: one real extmark per match made the first redraw of a
  large result take seconds.
- One request per buffer at a time, so holding a scroll key doesn't start one rg
  per rule per redraw.
- **Stale when** `hl_sig` changes or level 1 reruns: `hls.hl` is replaced by a new
  table, so an answer still in flight sees it isn't its table and is dropped.

### Source highlight columns ~~> `[D]` `[M]` `[P]`

Same as the highlight columns, with a source file's lines as input:

```
 file_rows of every rule buffer (the job's so far while loading) --+
 hl rules, refresh order                                          +--> pick the rule buffer
 source buffer path ----------------------------------------------+    refreshed last
                                                                          |
 source buffer lines, changedtick ----------------------------------------+
                                                                          v
                                                  source_by_buf[buf] = { hl, hl_rules, tick }
                                                  [D] on_line -> request -> [P] rg -> [M] apply
```

- Only `[highlight]` colors; the `[rg]` color stays in the result.
- Bound to the rule buffer, not a window: kept in other tabs and with the result
  closed.
- **Stale when** the rules, the picked rule buffer or the buffer's `changedtick`
  change: the table is replaced. A refresh or a rule buffer wipe redraws the
  non-result windows so they pick again.

### Hit counts ~~> `[M]` `[P]`

```
 count texts --+
 count rules --+--> [M] ' … ' extmark on each rule line, spawn per rule
                       |
                       v
                    [P] rg --count <rule> <count texts>
                       |
                       v  [F] exit -> schedule
                    [M] ' N ' (0 on exit 1, ' ! ' on error) on the extmark
```

- `[rg]` counts start after level 1; `[highlight]` counts after level 1 or an
  `hl_sig` change. They read the count texts, so they cover every result row, not
  only the drawn ones.
- The extmarks move with edits to the rule buffer and hide when their line is
  deleted.
- **Stale when** a new run of the same kind starts: `st.counts[kind]` is replaced,
  older callbacks see it and do nothing.

### Folds and jump --> `[M]`

```
 file_rows + result line count
      |
      +--> folds:  result window folds  -- save: foldclosed() per header -->  [fold] lines
      |                                 <-- restore: :fold per file, open unless listed --
      |
      +--> jump:   row's '<lnum>: ' + header above it (binary search in file_rows)
                   --> source window / buffer, cursor at line and column
```

- Folds are saved when leaving the result window and before a refresh, restored
  after level 1 and when `[fold]` was edited by hand.
- Both need `file_rows` to match the buffer: folds are skipped while level 1 loads
  or after the result was edited; jump then searches back for `^file: ` instead.
