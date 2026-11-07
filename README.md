<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
  <img src="assets/logo.svg" alt="teagent: a cup of tea with steam shaped like code brackets" width="140">
</picture>

# teagent

**A coding agent that writes one typed program, which is checked before anything runs.**

The model writes Dartea, a pure dialect of Elm. teagent typechecks it, turns it into a tree of
effects, runs every command in a sandboxed copy, and applies the result by itself. Nothing it does
leaves the project folder, and any session can be undone with one command.

![OCaml 5.4](https://img.shields.io/badge/OCaml-5.4-ec6813?logo=ocaml&logoColor=white)
![Dartea](https://img.shields.io/badge/programs-Dartea%20%C2%B7%20Elm-5b4fd6)
![Shell](https://img.shields.io/badge/shell-Seatbelt%20sandbox-cf222e)
![Bench](https://img.shields.io/badge/bench-20%2F20%20reference-1a7f37)
![Stage](https://img.shields.io/badge/stage-0%20spike-9a6700)

[Why](#why-teagent) · [How it works](#how-it-works) · [The language](#the-language) ·
[Status](#status) · [Install](#install) · [Quick start](#quick-start) · [Layout](#layout)

</div>

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/stats-dark.svg">
  <img src="assets/stats.svg" alt="20 of 20 bench tasks pass with reference programs; one way to touch the world; 0.32 s to clone 2,093 files for a contained shell; exact replay of any session" width="100%">
</picture>

<br>

```console
$ teagent -C ~/code/app "Rename Foo.bar to Foo.baz in all .ml files, then run the tests"
```

```diff
--- a/lib/a.ml
+++ b/lib/a.ml
@@ -1,1 +1,1 @@
-let x = Foo.bar 1
+let x = Foo.baz 1
```

```console
$ teagent --undo ~/.teagent/sessions/0001.jsonl
Put back 2 file(s) in /Users/me/code/app:
  restored lib/a.ml
  restored lib/b.ml
```

## Why teagent

<table>
<tr>
<td width="50%" valign="top">

**A program, not tool calls.** The model answers with one Dartea program for the whole step.
A wrong argument is a type error before anything runs, not a JSON blob to repair afterwards.

</td>
<td width="50%" valign="top">

**One way out.** Dartea has no side effects, no FFI and no `eval`. The only way to touch the
world is a `Task` value, and only the harness decides what a task does.

</td>
</tr>
<tr>
<td valign="top">

**Effects are data.** `main` evaluates to a tree of effects whose callbacks are closures of
the program. A handler walks it: run, stage, replay. A plan is the same tree, cut where it stops.

</td>
<td valign="top">

**Nothing to approve, nothing irreversible.** Edits are staged in memory, checked against the
disk and written as one commit. Any session can be undone, and a file you changed since is
never overwritten, by the agent or by the undo.

</td>
</tr>
<tr>
<td valign="top">

**A contained shell.** Commands run in an APFS clone that holds your staged edits, under
Seatbelt, with no network and no writes outside the clone. What they write or delete is staged.

</td>
<td valign="top">

**Exact replay and resume.** Every session is a log of what the world answered. Replay it with
no model and no disk; resume a crashed one from where it stopped, without paying again.

</td>
</tr>
</table>

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/pipeline-dark.svg">
  <img src="assets/pipeline.svg" alt="Model writes a program, typecheck sends errors back for up to 4 rounds, the interpreter builds a tree of effects, the handler stages edits and contains the shell, the diff is shown, then commit or discard" width="100%">
</picture>

The compiler is [Dartea](https://github.com/jongleb/dartea), used as a library. A report
goes back to the model as Elm prints it, with a `Hint:` line for the mistakes models make most:
`Maybe` against `Result`, reserved words, a missing `mapErr`, APIs from packages that are not
there. The driver also notices when the model resends the same program or answers before it
has looked at anything.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/tree-dark.svg">
  <img src="assets/tree.svg" alt="main of the rename task evaluates to And_then of And_then of Tool Grep; nothing has run yet" width="100%">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/shell-dark.svg">
  <img src="assets/shell.svg" alt="The workspace is cloned with the staged edits into a Seatbelt sandbox with no network; files the command writes or deletes come back as staged changes" width="100%">
</picture>

`--shell contained` is the default, on macOS and on Linux with bubblewrap. `--shell open` runs in the workspace itself, and
only when nothing is staged, so a command never sees a different tree than the program.
`--shell off` answers every command with exit code 126.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/replay-dark.svg">
  <img src="assets/replay.svg" alt="A session log of events; --replay answers from the log and checks the events match, --resume plays the log and then goes on live" width="100%">
</picture>

A session is a pure function of its world: the model, the approval (automatic unless you pass
`--ask`), the tools and the disk. A live run gets the real world; `--replay` gets one built from the log and checks
that the new events equal the logged ones.

## The language

A program is one module, `Main`, with `main : Task e a`. Everything it can do to the world is
in the `Agent` module:

```elm
type IoErr = NotFound String | Denied String | Conflict String
type alias Match = { path : String, line : Int, text : String }

read  : String -> Task IoErr String
write : String -> String -> Task IoErr ()
edit  : { path : String, old : String, new : String } -> Task IoErr ()
grep  : { pattern : String, glob : String } -> Task e (List Match)
shell : String -> Task e { out : String, code : Int }

succeed, fail, andThen, map, mapErr, onError, batch, fromResult
```

The rename task, as the bench's reference program writes it:

```elm
module Main exposing (main)

import Agent exposing (..)


type Err
    = EditFailed IoErr


main : Task Err { out : String, code : Int }
main =
    grep { pattern = "Foo\\.bar", glob = "**/*.ml" }
        |> andThen
            (\matches ->
                matches
                    |> List.map .path
                    |> List.unique
                    |> List.map (\p -> edit { path = p, old = "Foo.bar", new = "Foo.baz" })
                    |> batch
                    |> mapErr EditFailed
            )
        |> andThen (\_ -> shell "dune test")
```

The type says the program can only fail with a failed edit, and the compiler makes it handle
every case.

## Status

Stage 0 of the [plan](docs/Rune%20%E2%80%94%20%D0%BF%D0%BB%D0%B0%D0%BD.md): the whole loop works,
the question it exists to answer is still open.

| | |
| --- | --- |
| Bench, reference programs | 20 of 20 tasks: reading, single-file edits, multi-file refactors, shell |
| Gate of stage 0 | median compile rounds per task ≤ 2 on a frontier model: **not measured yet** |
| Local `qwen2.5-coder:7b` | 2 to 3 of 6–11 tasks; it copies examples and reaches for missing APIs |
| Contained shell | macOS (Seatbelt + APFS clone); Linux (bubblewrap + reflink copy) |
| Network for commands | off; an allowlist proxy is planned |

The sandbox design and the roadmap behind it: [docs/research/sandboxing.md](docs/research/sandboxing.md).

## Install

teagent needs OCaml 5.4 and the libraries Dartea builds with (menhir, ppx_jane, ppx_deriving,
yojson, lwt, curl, str).

```console
$ git clone --recurse-submodules https://github.com/jongleb/teagent.git
$ cd teagent
$ eval $(opam env --switch=<a 5.4 switch with those libraries>)
$ dune build
$ dune test
```

`dune test` runs the unit tests and the whole bench on its reference programs.

## Quick start

```console
$ export ANTHROPIC_API_KEY=…            # or ANTHROPIC_AUTH_TOKEN from `ant auth login`
$ teagent -C ~/code/app "Find every TODO under lib/ and count them per file"

$ teagent --openai http://localhost:11434/v1 --model qwen2.5-coder:7b "…"   # any OpenAI-compatible server
$ teagent --replay ~/.teagent/sessions/0001.jsonl                               # no model, no disk
$ teagent --resume ~/.teagent/sessions/0001.jsonl                               # go on after a crash
$ teagent --undo ~/.teagent/sessions/0001.jsonl                                 # put everything back
```

| Flag | Meaning |
| --- | --- |
| `-C DIR` | work in `DIR` |
| `--model ID` | the model, `claude-opus-5-5` by default |
| `--effort LEVEL` | `low`, `medium`, `high` (default), `xhigh`, `max` |
| `--openai URL` | an OpenAI-compatible `/chat/completions` server |
| `--shell MODE` | `contained` (default), `open`, `off` |
| `--ask` | ask before writing changes |
| `--dry-run` | show the changes, write nothing |
| `--undo FILE` | put back every file a session changed, unless you changed it since |
| `--exec FILE` | run a program you wrote, with no model inside |
| `--mcp` | serve bash, read, write, edit and grep to another agent over MCP |

### With Claude Code, over MCP

`teagent --mcp` serves five tools to another agent: `bash`, `read`, `write`, `edit` and
`grep`. Commands run in a sandboxed copy without network, and what they write or delete is
applied when they end. Writes never overwrite a file you changed meanwhile. The whole session is
logged, so `teagent --undo` puts everything back.

Add it to a project and switch off Claude Code's own shell and editing, so every change goes
through teagent:

```console
$ cd ~/code/app
$ claude mcp add --scope project teagent -- /path/to/teagent --mcp
```

`.claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["mcp__teagent"],
    "deny": ["Bash", "Edit", "WebFetch", "WebSearch"]
  }
}
```

`Edit` also covers Claude Code's Write and NotebookEdit. Its read-only tools (Read, Grep, Glob)
stay on. Each session prints its log path on stderr; undo it with
`teagent --undo ~/.teagent/sessions/NNNN.jsonl`.

### From another agent, with a Dartea program

Any agent that can write a file and run a command can use teagent as its executor: Claude
Code, Codex, a script. It writes the Dartea program, teagent checks and runs it.

```console
$ teagent -C ~/code/app --exec plan.elm --dry-run   # typecheck, run contained, print results and diff; writes nothing
$ teagent -C ~/code/app --exec plan.elm             # the same, then commit
```

A program that does not compile prints the report with its hints and exits with 1. These runs
are logged like any session, so `--replay` works on them too.

The bench:

```console
$ dune exec bench/bench.exe -- --root bench --reference                 # the reference programs
$ dune exec bench/bench.exe -- --root bench --model claude-sonnet-5-5   # a model, all 20 tasks
$ dune exec bench/bench.exe -- --root bench --model … 04_count_lines    # some of them
```

## Layout

| Path | What it holds |
| --- | --- |
| `lib/lang` | source to Dartea IR, reachable from `Main.main`, with hints on reports |
| `lib/agent` | the `Agent` prelude |
| `lib/interp` | IR to a tree of effects; every Dartea kernel; a step budget |
| `lib/effect` | handlers: run, staged overlay with diff, contained shell |
| `lib/tools` | the only IO: files, search, processes, the sandbox, commit |
| `lib/llm` | its own client for Anthropic Messages and OpenAI-compatible servers |
| `lib/driver` | the session loop, the world it runs against, logs, replay, resume |
| `lib/mcp` | the MCP server: tools for another agent, applied and logged |
| `bin/teagent.ml` | the CLI |
| `bench/` | 20 tasks with fixtures, expected files and reference programs |
| `vendor/dartea` | the compiler, on its `rune-agent` branch |
