# Tracing

teagent reports what it does through [`trace`](https://github.com/c-cube/ocaml-trace) 0.12.
Without a collector this costs a few integer additions: no span, message or counter is built. A
host that wants them installs a collector with `Trace_core.setup_collector`, for example one that
forwards to OpenTelemetry.

## Spans

| Span | Where | Data |
| --- | --- | --- |
| `interp.entry` | each entry into a program: `main`, a top-level value, a function applied | `global` (`Main.main`, `Counter.main`, or `a function of <module>`), `steps` it took, `budget` it had, `outcome` (`ok`, `out of budget`, `crashed`, `stuck`) |
| `handler.call <name>` | each call through `Handler.booted`, around the budget, journal and rules; `<name>` is the tool (`read`, `shell`, …) or the driver call (`fetch.get`) | `class` (`pure`, `staged`, `contained`, `egress`, `irreversible`), `outcome` (`ok`, `failed`, `blocked`, `exhausted`) |
| `live.init`, `live.update`, `live.view`, `live.listen` | `Live.started`, `Live.updated`, `Live.drawn`, `Live.listening` | `steps`, over every entry the call made |
| `model.request` | each completion, retries included | `tokens_in` (uncached, read from and written to the cache), `tokens_out`, `tokens_cached`; or `error` (`status 429`, `transport`, `refusal`, `unreadable`) |

`handler.call` and `model.request` are async spans, entered and exited around Lwt promises.

## Messages

| Message | When | Data |
| --- | --- | --- |
| `session.event` | each event `Session.solve` hands to its host | `agent` (`main`, `spawned <id>`), `kind` (the log key of a logged event, such as `performed` or `answered`, or `began`, `merged`, `proposed`, `asking`), `step`, `tokens_in`, `tokens_out` so far |
| `handler.denied` | the person's rules deny a call, or the person says no | `call`, `reason` |

## Counters

Counters are totals since the process started, sent each time they change.

| Counter | What it counts |
| --- | --- |
| `interp.steps` | steps every program took |
| `handler.calls.<class>` | calls of each class, counted while a collector is installed |
| `handler.denials` | calls denied by the rules or the person |

`Interp.spent` is the step count of a program's last entry, and `Interp.used` of every entry
since it was loaded, for a host that puts them on its own spans.
