# Embedding a session

`Driver.solve` runs a session and hands each event of its log to a callback. A host such as an
IDE needs more than the log: who did each thing, what the model says it is doing, what it has
cost, which files it touched, and the staged changes as data. `Session.solve` (library
`teagent.session`) runs the same session and gives each event that context.

```ocaml
Session.solve world ~on ~cancelled task : Driver.report Lwt.t
```

| Field of `Session.event` | What it holds |
| --- | --- |
| `agent` | `Main`, the program the model wrote, or `Spawned { id; parent }`, a process `spawn` began; ids count from 1 in a session |
| `step` | the last line the model wrote before its program, or the goal `Aimed` named, or the hole being filled |
| `spent` | the session's `Llm.usage` so far; it grows after each reply of the model |
| `touched` | the paths this event read (`read`, the files `grep` matched) and changed (what it staged) |
| `happened` | what happened, below |

| `happened` | When |
| --- | --- |
| `Logged event` | every `Driver.event`, in log order |
| `Began id` | the agent spawned the child `id`; the child's own events follow under `Spawned { id; ... }` |
| `Merged id` | the agent took in the changes of the child `id` |
| `Proposed files` | before the person is asked to apply staged changes: each file's `Tools.change`, with before and after, and its hunks |

A hunk is `{ old_start; new_start; lines }`, with each line `Kept`, `Removed` or `Added`, as in a
unified diff; `Handler.Overlay.hunks` computes them for any change.

The events of one session come in order, each after the callback for the one before has
returned. Sessions share no state, so several can run at once in one process.

## Cancelling

When `cancelled` resolves, the call the session is waiting on (the model, a tool, the person) is
abandoned, nothing staged is written, and the session ends with `Error Cancelled` and a last
`Logged (Ended "Stopped from outside.")`. A commit that has begun finishes first.

## The world

`Driver.world.ask` returns an `Llm.reply`, text and usage; `Llm.answered` is one. A replay's
replies cost `Llm.unused`. `Driver.world.approve` gets the staged changes, and the log gets their
diff as `Staged`.
