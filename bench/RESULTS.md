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

## Chains a late step overturns (2026-11-12)

`bench/staged`: a release whose gate, once the release is rightly prepared, blocks it and asks
for every file back (`k01`), and a setting rename whose check then names, one at a time, two
services that must keep the old setting too (`k02`). Same arms as above, one run per task. A
new measure, taken by the harness after every call and unseen by the agent: the calls after
which the project on disk was half done, neither as it was nor as it should end.

| Arm | Solved | teagent calls | Calls left half done | Tokens | Wall time |
| --- | --- | --- | --- | --- | --- |
| tools | 2/2 | 12 (5, 7) | 5 (2, 3) | 82k | 82 s |
| program | 2/2 | 8 (3, 5) | 2 (0, 2) | 88k | 80 s |
| holes | 2/2 | 12 (4, 8) | 0 (0, 0) | 98k | 119 s |

What it says:

- Staging is what the programs bought, not fewer calls. To undo the blocked release, the
  program and holes arms wrote it and ran the gate in one program that failed when the gate did:
  nothing reached the disk. The tools arm wrote it, saw the block, and rewrote six files from
  what it had printed earlier; its tar backup, named with a dot, was silently dropped by the
  shell, which now says so (`c747ef2`).
- Only holes kept the revised chain whole: four fills took the rename through both corrections
  before anything was written. Programs without holes committed each correction on its own.
- Holes cost the most here, and part of that was teagent: one compile failure each, and
  `List.filter` crashed on a test computed from command output, a label the filter did not
  peel (`879b1ec`); a fill also printed again the compiler report of an earlier fill.

Next: k = 5 on `bench/staged` and `bench/judge`, with a second model, now that the tasks and
the harness have held up.

## Five runs per task (2026-11-12)

`bench/judge` and `bench/staged`, three arms, five fresh runs per task: 75 runs, one model.
Teagent as of `c747ef2`; from the second round on also `7a4d0b6`, which stopped parallel
sessions from crashing over one log file (two tools-arm runs of the first round lost a read to
it). "Half done" counts the calls after which the project on disk was neither as it was nor as
it should end; in `j01` every routed ticket counts, since the desk's queue lives in the project.

| Arm | Solved | teagent calls | Calls left half done | Compile failures | Tokens | Wall time |
| --- | --- | --- | --- | --- | --- | --- |
| tools | 25/25 | 162 | 84 | – | 1040k | 947 s |
| program | 25/25 | 122 (−25%) | 54 | 2 | 1118k (+8%) | 993 s |
| holes | 24/25 | 135 (−17%) | 13 | 8 | 1202k (+16%) | 1137 s |

Calls per task, five runs each:

| Task | tools | program | holes |
| --- | --- | --- | --- |
| j01_desk | 10–11 | 10 | 5–12 |
| j02_invoice | 2–3 | 2 | 1–3 |
| j03_deploy | 4–9 | 3–5 | 4–7 |
| k01_release | 5–8 | 3–4 | 3–4 |
| k02_rollout | 7–9 | 5–6 | 5–6 |

What it says:

- Programs saved a quarter of the calls and cost 8% more tokens; holes saved fewer calls and
  cost 16% more. The savings come from the staged tasks and `j03`; on `j01` and `j02` the arms
  tie, as in the pilot.
- Staging is what the program arms bought. On `k01`, where the gate blocks a rightly prepared
  release, every tools run wrote the release and then rewrote it back from what it had printed
  (one kept a backup folder); every program and holes run failed `main` on the gate and wrote
  nothing. Across the staged tasks and `j03`, programs left the project half done after 14
  calls, tools after 44, holes after 2.
- The agents used holes in 17 of 25 runs, 71 fills in all, and solved the same tasks. Where they
  skipped them, the run looked like the program arm.
- Holes have two traps, and both cost runs:
  - A hole inside a loop or a function is filled once, for every pass. One `j01` run filled
    the first ticket's hole with `succeed "billing"`, and all nine tickets went to billing and
    were written: the only wrong result of the 75.
  - A run may reach at most 8 holes. Three `j01` runs filled a hole per ticket, met the ninth,
    lost their eight fills and started over.
- Compile failures in fills came from names the program does not import (`Dict`, three
  times) and from `port`, a reserved word, as a variable (four times, all in `j03`).

Next: say in the hole's question that its code is used on every pass, and how many holes are
left; decide whether the limit of 8 should hold for an outside agent; name `port` and imports in
the compiler's reply. Then a second model.
