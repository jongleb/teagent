# teagent ABI, version 1

This is the contract between a program, the runtime that performs its calls, and the log that
records them. Another runtime that implements it can run the same programs, and a log written by
one build replays under any build of the same version. The version is `Os.abi`; every session
log names it on its first line.

The ABI has four parts: the call table, the JSON of values, the session log, and the image.

## 1. The call table

A program reaches the world only through the `Agent` module and the driver modules. Each
function below becomes one call; the column on the right is its JSON in the log.

| Function | Class | Call |
| --- | --- | --- |
| `read : String -> Task IoErr String` | Pure | `{"read": path}` |
| `write : String -> String -> Task IoErr ()` | Staged | `{"write": {"path", "content"}}` |
| `edit : { path, old, new } -> Task IoErr ()` | Staged | `{"edit": {"path", "old", "new"}}` |
| `grep : { pattern, glob } -> Task e (List Match)` | Pure | `{"grep": {"pattern", "glob"}}` |
| `shell : String -> Task e { out, code }` | Contained | `{"shell": command}` |
| `spawn mounts task`, on entry | Staged | `{"enter": [{"path", "mount"}]}` with `mount` one of `hidden`, `readonly`, `scratch` |
| `spawn mounts task`, on exit | Staged | `{"leave": null}` |
| `merge : Child a -> Task (List Change) a` | Staged | `{"merge": [{"file", "base", "content"}]}`, `null` for a missing file |
| `Fetch.get : String -> Task FetchErr Response` | Pure | `{"call": {"name": "fetch.get", "argument": value}}` |
| `Fetch.post : String -> String -> Task FetchErr Response` | Irreversible | `{"call": {"name": "fetch.post", "argument": value}}` |

`IoErr` is `NotFound String | Denied String | Conflict String`. A driver adds calls only through
`call` with a dotted name. Its Elm module is part of the image (section 4), so a driver can
change without a new ABI version, but sessions logged against the old driver no longer replay
under the new image.

`hole`, `succeed`, `fail`, `andThen`, `map`, `mapErr`, `onError` and `batch` are not calls.
They shape the task and never reach the runtime.

## 2. The JSON of values

Every value is an object with a single key that names its kind.

| Value | JSON |
| --- | --- |
| `Int`, `Float` | `{"number": 1}` |
| `String` | `{"string": "text"}` |
| `Char` | `{"char": "c"}` |
| `Bool` | `{"bool": true}` |
| `()` | `{"unit": null}` |
| `List a` | `{"list": [...]}` |
| a tuple | `{"tuple": [...]}` |
| a record | `{"record": {"label": value, ...}}`, labels sorted |
| a constructor | `{"constr": {"module": "Agent", "name": "Denied", "arguments": [...]}}` |
| a function or a task | `{"opaque": null}` |

## 3. The session log

A log is JSON lines. The first line is the header:

```json
{"task": "...", "directory": "/path", "abi": 1, "image": "<64 hex digits>"}
```

Each later line is one event, an object with a single key:

| Event | JSON |
| --- | --- |
| A model reply that carries a program | `{"wrote": reply}` |
| The compiler's report | `{"refused": report}` |
| A call performed | `{"performed": {"tool": call, "result": {"ok": value} or {"error": value}, "staged": [{"path", "before", "after"}]}}` |
| A call held until the changes are settled | `{"deferred": call}` |
| A call the budget stopped | `{"exhausted": call}` |
| The diff shown for approval | `{"staged": diff}` |
| The person's decision | `{"decided": "apply"}` or `{"decided": "discard"}` |
| The commit | `{"committed": null}` or `{"committed": reason}` |
| What main returned | `{"ran": text}` |
| A reply without a program before any program ran | `{"guessed": reply}` |
| The final reply | `{"answered": reply}` |
| The code for a hole | `{"filled": {"hole": description, "reply": reply}}` |

A replay answers each call from the log at the journal's place among the boot layers, in log
order. The first call that differs from the log ends the replay; from there the session runs
live.

## 4. The image

The image is the BLAKE2b-256 hash, in hex, of this JSON, written without spaces and with the
keys in this order:

```json
{"abi": 1,
 "offers": ["bash", "read", "write", "edit", "grep", "run", "fetch"],
 "mounts": [["path", "hidden"], ...],
 "reads": "anywhere" or ["/abs/path", ...],
 "net": ["host", ...],
 "boot": [{"budget": 200}, "journal", "policy"],
 "drivers": ["<Elm source of each offered driver>"],
 "skills": ["<Elm source of each skill>"]}
```

`offers` follows the order above. `mounts`, `reads`, `net` and `skills` are sorted. The project's
own path is not part of the image, so the same OS has the same image on any machine.
`--replay` and `--resume` refuse a log whose image differs from the OS they would run.

## What needs a new version

A new version is needed for any change to the call table (a call added, removed or retyped, or
a class changed), to the JSON of values, calls or events, to the meaning of an event, or to how
the image is computed. A change to a driver's or a skill's source changes only the image.
`test/sessions/abi1.jsonl` is a session logged under version 1. Every build of version 1 must
replay it exactly.
