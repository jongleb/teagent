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
