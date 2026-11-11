# teagent ABI, version 2

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
| `shell : String -> Task e { out, code }` | Contained, or Egress when `--net` grants hosts | `{"shell": command}` |
| `spawn mounts task`, on entry | Staged | `{"enter": [{"path", "mount"}]}` with `mount` one of `hidden`, `readonly`, `scratch` |
| `spawn mounts task`, on exit | Staged | `{"leave": null}` |
| `merge : Child a -> Task (List Change) a` | Staged | `{"merge": [{"file", "base", "content"}]}`, `null` for a missing file |
| `Fetch.get : String -> Task FetchErr Response` | Egress | `{"call": {"name": "fetch.get", "argument": value}}` |
| `Fetch.post : String -> String -> Task FetchErr Response` | Irreversible | `{"call": {"name": "fetch.post", "argument": value}}` |

`IoErr` is `NotFound String | Denied String | Conflict String`. The classes are `Pure` (reads
only), `Staged` (changes the overlay), `Contained` (a sandboxed command whose writes are staged),
`Egress` (sends data to a granted host) and `Irreversible` (asks the person first). A driver adds calls only through
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
| Changes to files other programs run, shown apart, and the person's answer | `{"held": {"diff": diff, "decision": "apply" or "discard"}}` |
| A program that can leak, shown to the person before it ran, and their answer | `{"exposed": {"summary": text, "decision": "apply" or "discard"}}` |
| The commit | `{"committed": ["path", ...]}`, the paths written, or `{"committed": reason}` |
| What main returned | `{"ran": text}` |
| A reply without a program before any program ran | `{"guessed": reply}` |
| The final reply | `{"answered": reply}` |
| The code for a hole | `{"filled": {"hole": description, "reply": reply}}` |

When changes settle, those to files that other programs run or obey outside the sandbox are
shown apart (`held`), and only the person can allow them; the rest are approved as before
(`staged`, `decided`). In version 2 those files are, at any depth and in any case: `.husky/`,
`.githooks/`, `.pre-commit-config.yaml`, `lefthook.yml`, `.lefthook.yml`, `.gitattributes`,
`.gitmodules` (git); `.github/workflows/`, `.github/actions/`, `.circleci/`, `.buildkite/`,
`.gitlab-ci.yml`, `.travis.yml`, `azure-pipelines.yml`, `bitbucket-pipelines.yml`, `Jenkinsfile`
(CI); `package.json`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pnpmfile.cjs` (install);
`.devcontainer/`, `.idea/` (editors); `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursorrules`,
`.windsurfrules`, `.clinerules`, `.github/copilot-instructions.md`, `.continue/` (other agents).
No path may contain `.git`, `.claude`, `.codex`, `.cursor`, `.mcp.json`, `.teagent`, `.envrc` or
`.vscode` at any depth. A file named `.env` or `.env.*`, at any depth, is hidden as if mounted
`hidden`, except names ending in `.example`, `.sample`, `.template` or `.dist`.

A replay answers each call from the log at the journal's place among the boot layers, in log
order. The first call that differs from the log ends the replay; from there the session runs
live.

## 4. The image

The image is the BLAKE2b-256 hash, in hex, of this JSON, written without spaces and with the
keys in this order:

```json
{"abi": 2,
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
the image is computed. The list of files other programs run is part of the
version too. A change to a driver's or a skill's source changes only the image.
`test/sessions/abi2.jsonl` is a session logged under version 2. Every build of version 2 must
replay it exactly.

Before a program or the code for a hole runs, teagent looks at the calls it can reach. If it
can read the project (`read`, `grep`, `shell`), take in text from outside (a driver call, a
`hole`, `shell` when `--net` grants hosts) and send data out (`shell` when `--net` grants
hosts, or a driver call whose name is not written out), it runs only if the person says yes,
and the answer is logged as `exposed`.

While a program runs, the interpreter labels each value with where its content came from: a
file `read` returned, lines `grep` found, a command's output, a child's changes, a driver's
answer. Labels pass through every operation, and an `if` or `case` on a labelled value labels
what its branch returns. A call is performed with the labels of its arguments and of the
choices that led to it. An `Egress` call that carries labels of the project, or an
`Irreversible` one, asks the person; a refusal is the call's result and is logged as any other.
The model writes each program and each hole's code after
seeing what earlier calls of the session returned, so `main` runs labelled with the sources of
every call performed before it in the session. Labels are never logged: the interpreter
computes them again on replay.

Version 2 added the `Egress` class, the `held` and `exposed` events, the paths in `committed`,
and hidden `.env` files.
