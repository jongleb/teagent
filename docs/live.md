# Long-lived programs

An agent's program runs once: `main : Task e a`. A long-lived program, such as a widget in an
IDE, keeps a model, draws a view of it, and changes it on messages, as an Elm program does. Its
effects are the same Agent tasks as an agent's, so they go through the same handler: budget,
journal, the person's rules, and the classes that decide when to ask.

## The program

```elm
module Counter exposing (main)

import Agent
import Live


main : Live.Program Model Msg (List View)
main =
    Live.program
        { init = ( { count = 0 }, Live.perform Loaded (Agent.succeed 40) )
        , update = update
        , view = view
        , subscriptions = \_ -> Live.listen "agents" Heard
        }
```

| Function | Type | What it does |
| --- | --- | --- |
| `Live.program` | `{ init, update, view, subscriptions } -> Live.Program model msg view` | the program; `view` returns any type the host knows how to draw |
| `Live.perform` | `(a -> msg) -> Task Never a -> Cmd msg` | runs a task and sends its value as a message |
| `Live.attempt` | `(Result e a -> msg) -> Task e a -> Cmd msg` | the same for a task that can fail |
| `Live.listen` | `String -> (Json.Decode.Value -> msg) -> Sub msg` | a message each time the host's source of that name changes |

`Cmd` and `Sub` are Elm's own, so `Cmd.none`, `Cmd.batch`, `Cmd.map` and their `Sub` twins work.
Write the type as `Live.Program`: with `import Live exposing (..)`, a bare `Program` is ambiguous
with Elm's.

## Rights

`Lang.compile_modules calls sources ~entries` compiles a program's modules against a call table, and
the table is the program's rights. `Lang.Calls.pure` has Agent's tasks and none of its tools, and no
driver; `Lang.Calls.plugging [ Device.Fetch ] Lang.Calls.pure` adds one. A module that imports a
driver the table does not have, or calls a tool it dropped, does not compile. `Live.powers` lists
what the compiled calls can do, `Reads`, `Sends`, `Changes` or `Asks` (`Person.ask`, with
`Device.Person` plugged), so a host can ask the person before it runs anything.

A host adds its own calls, such as actions through its integrations, with a module it writes:

```ocaml
Device.hosted ~name:"Slack" ~source
  ~calls:[ ("slack.post", Irreversible { question = "post to Slack"; declined }) ]
```

The source is an Elm module named `name` whose functions wrap `Elm.Kernel.Agent.call` with a
name written out, as `Fetch` does. `Device.hosted` refuses a module that uses any other kernel,
makes a call missing from `calls`, names a call that does not start with the module's name in
lower case (`slack.`), or takes the name of a module of teagent. The device plugs in like any
other (`Lang.Calls.plugging [ slack ]`), and no program can take its name. Its classes reach the
handler through `Handler.class_of [ slack ]`, which adds the argument to an irreversible call's
question, and `Live.powers ~devices:[ slack ]`. The host answers the calls with
`Handler.answering`.

## The host

| Call | What it does |
| --- | --- |
| `Interp.load ~budget:(Each n)` | every entry into the program gets `n` steps afresh |
| `Live.started program main` | runs `init`: the program and the tasks of its commands |
| `Live.drawn live` | the view of the model; `Wire.json` and `Wire.diff` send it |
| `Live.message live ~view path arguments` | the message the view holds at a `Wire` path, applied to the event's arguments when it is a function |
| `Live.updated live message` | runs `update`: the next program and the tasks of its commands |
| `Live.listening live` | the sources the model listens to, each with its task |

The host runs each task with `Handler.interpret`, through `Handler.booted` for the budget, the
journal and the rules; `Handler.answering` answers driver calls from a function. A task ends in one
message, which goes to `Live.updated`. A listen is a task around the call `listen.<source>`: the
host answers it with the source's data as `Value.V_json`, and runs it again each time that data
changes. Subscriptions depend on the model, so the host reads `Live.listening` again after each
update.
