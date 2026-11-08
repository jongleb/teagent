# teagent as a micro-OS

Design note, 2026-11-07. It describes where teagent goes after the profile: from a harness with
a JSON list of restrictions to a small operating system that is assembled per task, where the
system itself is a typed value. Nothing here is built yet; the last section says in what order
to build it and how to tell each step worked.

## The idea in one paragraph

Today every session runs against the same fixed system: five tools, one overlay, one sandbox,
and a profile that can only take things away. A micro-OS turns that system into a program. A
task gets an OS described in Dartea: which calls exist, which drivers implement them, what the
file system and the network look like, and how much the task may spend. teagent typechecks the
agent's program against that OS before anything runs, then boots it. A sub-agent gets an OS
that is derived from its parent's and can only be narrower. This is the MirageOS idea, a system
assembled from modules for one application, applied to agents: the kernel is teagent, and the
system calls are typed effects.

## What maps to what

| Operating system | teagent today | teagent as a micro-OS |
| --- | --- | --- |
| kernel | the interpreter and the handlers, about 3,500 lines | the same; it stays the only trusted part |
| system call table | `Agent.elm`, fixed | generated from the OS value; a call that is not there does not compile |
| drivers | `Handler.run`, `Handler.staged` | modules that each implement some calls, stacked in order |
| file system | one overlay over the project | mounts: overlay, read-only, hidden, scratch, per mount point |
| network | the egress proxy and `net` | a driver with its own policy, so `http` becomes a typed call |
| permissions | the profile, narrowing only | the OS value; `spawn` takes a narrower one |
| processes | one session | sessions with O(1) fork of overlay, log and budget |
| journal | the session log, replay, resume | the same, per OS instance |
| packages | — | skills as pure Dartea modules, typechecked against the OS |

## The OS as a value

An OS is a record in a module the user or the harness writes. The agent never writes it.

```elm
module Os exposing (os)

import Os.Kernel exposing (..)


os : Os
os =
    { calls = [ read, edit, grep, shell, http ]
    , mounts =
        [ overlay "."
        , hidden "secrets"
        , readonly "vendor"
        , scratch "/tmp"
        ]
    , net = allow [ "registry.npmjs.org", "*.crates.io" ]
    , budget = { steps = 10000000, shells = 20, seconds = 1800, tokens = 200000 }
    , drivers = [ sqlite "app.db" ]
    }
```

Three properties make it more than a config file:

1. **It typechecks.** A mount that names a path outside the project, a budget with a negative
   number, a driver that needs a call the OS does not list: each is a compile error, reported
   the way the agent's own errors are.
2. **It generates the call table.** teagent builds the agent's `Agent` module from `calls`. If
   `shell` is not listed, `Agent.shell` does not exist, and a program that uses it is refused
   before it runs. This is `pledge` checked ahead of time instead of at the first violation.
3. **It only narrows downwards.** `Os.Kernel` exposes no way to widen an OS, only functions
   that take one and return a smaller one (`withoutCall`, `hide`, `readonlyAll`, `cap`). The
   OS a user hands to teagent is the widest any part of the session will ever see.

The JSON profile stays as a shorthand: teagent reads it into the same value.

## Drivers without touching the compiler

`Value.tool` is a closed variant today, and every new effect means a new kernel in
`vendor/dartea`'s `Data.Kernel`. That does not scale to drivers. Instead:

- Add one generic kernel, `Agent_call : String -> Json -> Task Json Json`, once.
- A driver is a pair: an OCaml handler that answers calls under one name (`"sqlite.query"`),
  and a Dartea module that wraps `Agent_call` in typed functions and decoders.

```elm
query : String -> List Value -> Task SqlErr (List Row)
query sql arguments =
    call "sqlite.query" (encode sql arguments)
        |> mapErr decodeErr
        |> andThen (fromResult << decodeRows)
```

The agent sees only the typed module. The handler sees only well-formed JSON, because the
wrapper is the only code that can build the call, and the wrapper is part of the OS, not of the
agent's program. Every driver call goes through the same stack as the built-in tools, so plan,
log, replay and policy work for it with no extra code.

Each call carries a class, as a constructor and not a flag: `Pure`, `Staged`, `Contained` or
`Irreversible` (the classes from `docs/research/sandboxing.md`). Planning speculates through
the first two, replay answers all four from the log, and an `Irreversible` call is held for
approval unless the OS says otherwise.

## Drivers stack like handlers

A handler is already `{ perform : tool -> state -> step }`. A driver is a function from a
handler to a handler, so the boot order is plain composition:

```
budget ∘ policy ∘ journal ∘ mounts ∘ net ∘ drivers ∘ run
```

The order is part of the OS and visible in it. Moving `journal` outward logs denied calls too;
moving `budget` inward stops counting calls that the policy refused. Nothing else changes.

## Processes: spawn and fork

- `spawn : Os -> Task e a -> Task Never (Handle a)` starts a child with an OS derived from the
  current one. Because `Os.Kernel` only narrows, a child can never hold a right its parent lacks.
- The child's state is a value: its own overlay, log and budget. `fork` copies the value in
  O(1); `merge` is an explicit call whose conflicts come back as data, not as markers in files.
- `batch [ spawn os1 try1, spawn os2 try2, spawn os3 try3 ]` with a test inside each is
  best-of-N as a property of the runtime.

## The boundary for agents that do not write Dartea

Claude Code and Codex reach teagent over MCP, which plays the part of a POSIX compatibility
layer: the same calls with untyped arguments. The OS still decides which of them exist and how
each is carried out. What the micro-OS cannot do by itself is stop such an agent from acting
outside it, because the agent is a separate process with the user's rights. That needs an
operating-system boundary around the agent process; it is a separate piece of work, tracked on
its own, and this design assumes it rather than describes it.

## A runtime for other agents

Codemode, where a model writes code instead of calling tools one by one, runs elsewhere in
V8 isolates or containers: the effects show only after the code runs, the isolation is the
sandbox's and not the language's, and nothing replays. teagent offers the same thing as a
runtime any agent can call. Over MCP, `run` takes a Dartea program, typechecks it, runs it
against the OS and applies its changes together only if `main` succeeds. A `hole` in it stops
the run and hands the values in scope to the calling agent, which sends the missing code back
with `fill`; the tools that already ran answer from what they returned, so nothing runs twice.
The calling agent is the hole's filler, so the model inside the program is whatever agent
called it.

What would make this a standard and not one program:

- **A versioned ABI.** The `Agent` call table, the JSON of `Value`, and the session log, written
  down as a specification with a version, so another runtime can implement it and another agent
  can target it without teagent's source.
- **Images.** An OS value with its drivers and skills, addressed by the hash of its content. A
  session is an image, a program and a log; `--replay` checks it on any machine.
- **Layers.** The overlay as a stack: a checkpoint is a layer, `fork` copies the stack, and
  `merge` returns conflicts as data.

## The far end: a real unikernel

The handlers are OCaml and the OS is a list of modules, which is the shape MirageOS builds
unikernels from. A later backend could compile one micro-OS into a MirageOS image and run it on
Solo5 or Firecracker: isolation at the level of a virtual machine, with no general-purpose
kernel inside and nothing in the image that the OS value did not ask for. This is a research
direction, not a plan.

## Order of work, and how to tell it worked

| Step | Content | Done when |
| --- | --- | --- |
| 1 | `Os` record and `Os.Kernel` with narrowing functions only; the JSON profile parsed into it | every profile test passes through the new value unchanged |
| 2 | Generate the `Agent` module from `calls` | a program that calls a missing tool is refused at compile time with a report naming the OS |
| 3 | `Agent_call` kernel and the driver pair; first driver `http` over the existing proxy | `http` shows in plan, log and replay with no driver-specific code in those parts |
| 4 | Mounts as a list with per-mount kinds; `scratch` and `readonly` as real mounts | the escape demo passes with the profile expressed as mounts |
| 5 | Drivers as handler transformers; boot order taken from the OS | reordering `journal` and `budget` changes only what the log and the budget count |
| 6 | `spawn` with narrowing, per-child overlay and log; explicit `merge` | a child cannot read a path the parent hid, shown by a test |
| 7 | Call classes as constructors; plan and replay keyed on them | an `Irreversible` driver call is held for approval in every mode |
| 8 | ABI document with a version; image hash over OS, drivers and skills | a log made by one build replays under another build of the same ABI version |

Steps 1 to 4, 6 and 7 are done; step 5, the order of handler wrappers taken from the OS, is not. The OS is `Os.t`, built only by `granted` and narrowed by the profile;
`Os.table` turns it into `Lang.Calls.t`, which can only lose calls, and every program, the
model's prompt and the MCP `run` tool see the `Agent` module cut to that table. Drivers go
through one kernel, `Agent.call`; the first is `Fetch`, whose handler checks the host against
the hosts granted with `--net`, as the proxy for commands does, and fetches with curl directly.
A program cannot name `Elm.Kernel` itself, so the call table and the types hold. Mounts are
`Tools.mount` (`Hidden`, `Readonly`, `Scratch`) over paths of the project; the overlay keeps
scratch writes apart from the changes to apply, and the escape demo runs with its profile
written as mounts. Processes are frames of the overlay: `spawn` pushes a copy of the
running frame with more mounts, `leave` pops it and hands its changes to the program as
`List Change`, and `merge` takes them only where the file is still what the child started
from. Settling and the diff look at the root frame only, so a child that is never merged leaves
nothing behind. Every tool has a class, `Value.class_`: `Pure`, `Staged`, `Contained` or
`Irreversible`, and a driver states the class of each of its calls. An irreversible call, the
first is `Fetch.post`, asks the person through the handler; with no person it is declined, and
the answer is logged, so a replay neither asks nor sends.

## Open questions

- Where the OS value comes from when the user has none: a default OS equal to today's behaviour,
  or a refusal to start.
- How a skill declares the calls it needs, so that importing it into an OS without them is a
  compile error rather than a runtime failure.
- Whether budgets belong to the OS (fixed at boot) or to `spawn` (chosen per child), or both
  with the smaller one winning.
- How big an OS value may get before typechecking it at every boot is noticeable.
