# Measurements

Every number here comes from agents that saw only what an outside agent sees: the description
of teagent's MCP tools and the task. Each was one run with one model (Claude, frontier class),
so these are pilots, not publishable results; [docs/research/frontier.md](../docs/research/frontier.md)
says what a publishable study needs.

## Does an agent write Dartea? (2026-11-11)

| Set | Tasks | Compiled on the first try | Solved |
| --- | --- | --- | --- |
| `bench/tasks` | 20 | 20 | 19 on the first pass; the one left was held by teagent's own rule for `package.json`, since fixed |
| `bench/hard` | 8 | 8 | 8, in 11 runs; the extra runs came from teagent bugs, since fixed |

## One program per step, or one tool per call? (2026-11-11)

The same 28 tasks, the same model, the same sandbox and handler. One arm used teagent's single
tools (`bash`, `read`, `write`, `edit`, `grep`) one call at a time; the other wrote a Dartea
program per step (`run`). Neither arm could read the project any other way.

| Arm | Solved | teagent calls | All agent actions | Tokens | Wall time |
| --- | --- | --- | --- | --- | --- |
| tools | 28/28 | 57 | 97 | 178k | 280 s |
| program | 28/28 | 40 (−30%) | 80 (−18%) | 225k (+27%) | 275 s |

What it says, and what it does not:

- Programs took a third fewer calls, but most tasks were done in one or two calls in either
  arm, which is where the literature also finds code costs more input tokens than it saves.
- The tools arm wrote code too, as `sed` and shell one-liners inside `bash`; the comparison is
  shell scripts against typed programs, not JSON calls against programs.
- The program arm paid for a 10k-character description, longer programs and `--exec`'s
  per-call output.
- `dune` was not on the sandbox's path in this run; one agent of the tools arm reached it through
  `opam exec`, so `03_build` was answered by building in one arm and by reading in the other.

Next: tasks with long chains, five runs per task, a second model, and a smaller description and
output, measured by ablation.

## Long chains (2026-11-12)

`bench/long`: six tasks built as chains in which each step needs the result of the one before
(follow includes, bisect 40 releases, five bugs the tests show one at a time, migrations applied
one per run, a transitive import graph, an API change across 11 files). Same protocol and arms as
above, one run per task, the description and `--exec` output as of `4eb5bd0`.

| Task | tools calls | program calls |
| --- | --- | --- |
| l01_config_chain | 1 | 1 |
| l02_bisect | 2 | 2 |
| l03_fix_chain | 8 | 2 |
| l04_migrations | 3 | 2 |
| l05_dead_modules | 3 | 3 |
| l06_logger_api | 4 (one never reached the tool) | 3 |

| Arm | Solved | teagent calls | Tokens | Wall time |
| --- | --- | --- | --- | --- |
| tools | 6/6 | 21 | 242k | 185 s |
| program | 6/6 | 13 (−38%) | 260k (+7%) | 185 s |

What it says:

- The chains were long only for an agent that walks them. Both arms collapsed them: a loop in
  `sh` over every release or migration, one command printing every file. Where a chain runs
  through the shell, `bash` already is a program.
- The calls saved came from edits: the five fixes of `l03` were five `edit` calls in one arm and
  one program in the other. Wall time did not move.
- The trap in `l06` (`dialog(` contains `log(`) caught the program arm: an unbounded
  `String.replace` rewrote two `dialog` calls, `main` succeeded, and the bad edits were written
  and fixed by the next call. Staging only protects a program that checks its own result.
- The tools arm lost a call to BSD `sed` and one to shell quoting; the program arm had no compile
  failures.

Next: chains a shell loop cannot fold, where each step needs the model's judgement on data
(the case `hole` is for), and k = 5.

## Chains that need judgement (2026-11-12)

`bench/judge`: three tasks whose state lives outside the project, behind a client the agent may
use but not read, so the chain cannot be dumped up front: a help desk that shows the next ticket
only once the last one is routed by prose rules (`j01`), the first of 32 releases whose invoice
does not add up (`j02`), and a cluster check that names one problem at a time, ports taken
included (`j03`). Three arms, one run per task, the description as of `b83a413`: tools; programs
without holes; programs with holes, which `--exec` and `--fill` now offer from the shell.

| Arm | Solved | teagent calls | Tokens | Wall time |
| --- | --- | --- | --- | --- |
| tools | 3/3 | 17 (11, 2, 4) | 125k | 107 s |
| program | 2/3 | 17 (10, 3, 4) | 138k | 145 s |
| holes | 3/3 | 17 (10, 2, 5) | 139k | 139 s |

What it says:

- No arm saved a call. Where every step needs a judgement (`j01`), each arm took one call per
  ticket, and the holes arm chose not to use holes: a fill per ticket is a round trip per ticket.
- Where the next step is mechanical, every arm folded the chain again: all 32 invoices rendered
  in one loop, the next free port found by a loop in `sh` or a recursive program.
- The one hole chain (`j03`, three fills) found a bug in teagent, not in holes: a local `let`
  function that calls itself crashed the interpreter. Fixed in `3207286`.
- The program arm's miss was the task's fault: v18's subtotal of 160.00 could be read as the sum
  before the discount. It now shows 148.00, which no reading makes right.

Next: holes do not save calls on a chain the model must judge step by step. What they can still
win on is that a chain's changes stay staged until its last step, and that a fill is shorter than
a program; a measure of that needs tasks where a late step shows an early write was wrong.
