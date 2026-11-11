open Lwt.Syntax

type step = {
  tool : Value.tool;
  result : (Value.t, Value.t) result;
  staged : Tools.change list;
  after : Handler.Overlay.t;
}
type t = {
  calls : Lang.Calls.t;
  source : string;
  modules : Lang.t list;
  recorded : step list;
  fills : int;
}
type hole = { run : t; reached : Value.hole; needle : string; spots : int list }

type outcome =
  | Finished of (Value.t, [ `Failed of Value.t | `Interp of Interp.error | `Exhausted ]) result
  | Reached of hole
  | Unfillable of string

let compiled calls source =
  Result.map
    (fun modules -> { calls; source; modules; recorded = []; fills = 0 })
    (Lang.compile calls source)

let calls t = Lang.calls t.modules

let run t (handler : Handler.Overlay.t Handler.t) ~settle =
  let performed = ref [] and pending = ref t.recorded in
  let replaying =
    {
      Handler.perform =
        (fun tool overlay ->
          match !pending with
          | step :: rest when step.tool = tool ->
              pending := rest;
              performed := step :: !performed;
              Lwt.return (Handler.Performed (step.result, step.after))
          | _ ->
              pending := [];
              let* outcome = handler.perform tool overlay in
              (match outcome with
              | Handler.Performed (result, after) ->
                  performed :=
                    { tool; result; staged = Handler.Overlay.since overlay after; after } :: !performed
              | Handler.Blocked | Handler.Exhausted -> ());
              Lwt.return outcome);
    }
  in
  let program = Interp.load ~budget:10_000_000 t.modules in
  let rec stepped task =
    let* outcome, overlay = Handler.interpret replaying program Handler.Overlay.empty task in
    match outcome with
    | Stopped rest -> (
        let* settled = settle overlay in
        match settled with
        | Error problem -> Lwt.return (Error problem)
        | Ok () ->
            performed := List.map (fun step -> { step with staged = [] }) !performed;
            stepped rest)
    | Finished result -> Lwt.return (Ok (Finished result, overlay))
    | Reached reached ->
        let needle = "hole " ^ Value.to_elm (V_string reached.description) in
        let spots =
          List.filter
            (fun at ->
              String.equal (String.sub t.source at (String.length needle)) needle
              && (at = 0
                 ||
                 match t.source.[at - 1] with
                 | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' | '.' -> false
                 | _ -> true))
            (List.init (max 0 (String.length t.source - String.length needle + 1)) Fun.id)
        in
        Lwt.return
          (Ok
             ( (match (t.fills >= 8, spots) with
               | true, _ ->
                   Unfillable "main reached a ninth hole; write the rest of the program yourself."
               | false, [] ->
                   Unfillable
                     "main reached a hole that is not written as `hole \"…\"` with a plain \
                      string, so it cannot be filled; write each hole that way."
               | false, _ :: _ ->
                   Reached
                     { run = { t with recorded = List.rev !performed }; reached; needle; spots }),
               overlay ))
  in
  match Interp.main program with
  | Ok task -> stepped task
  | Error failure -> Lwt.return (Ok (Finished (Error failure), Handler.Overlay.empty))

let stopped = function
  | `Interp (Interp.Crashed reason) -> "main crashed: " ^ reason
  | `Interp Budget_exhausted -> "main ran out of steps; it probably loops forever."
  | `Interp (Stuck reason) -> "The harness failed to run main (a bug in teagent): " ^ reason
  | `Exhausted -> "main stopped at a tool: this OS allows no more tool calls in the session."

let description hole = hole.reached.description
let performed hole = hole.run.recorded

let question hole =
  let shown value =
    let text = Tools.redacted (Value.to_elm value) and limit = 4_000 in
    match String.length text <= limit with
    | true -> text
    | false ->
        Printf.sprintf "%s… (%d more characters cut)" (String.sub text 0 limit)
          (String.length text - limit)
  in
  "main reached `" ^ hole.needle ^ "`. What main did before it stays done.\n\n"
  ^ (match Value.Scope.bindings hole.reached.locals with
    | [] -> "No local values are in scope there."
    | bindings ->
        "Values in scope there:\n\n"
        ^ String.concat "\n" (List.map (fun (name, value) -> name ^ " = " ^ shown value) bindings))
  ^ (match hole.run.fills with
    | 0 -> ""
    | _ -> "\n\nThe program now reads:\n\n```elm\n" ^ hole.run.source ^ "```")
  ^ "\n\nThe code for the hole is one Elm expression of the hole's type, a task. It may use the \
     values above, the program's own definitions and Agent, and may hold holes of its own."

let filled hole code =
  let source = hole.run.source in
  let lines = String.split_on_char '\n' (String.trim code) in
  let buffer = Buffer.create (String.length source) in
  let last =
    List.fold_left
      (fun from at ->
        let column =
          at - Option.fold ~none:0 ~some:succ (String.rindex_from_opt source (max 0 (at - 1)) '\n')
        in
        Buffer.add_string buffer (String.sub source from (at - from));
        Buffer.add_char buffer '(';
        Buffer.add_string buffer (String.concat ("\n" ^ String.make (column + 1) ' ') lines);
        Buffer.add_char buffer ')';
        at + String.length hole.needle)
      0 hole.spots
  in
  Buffer.add_string buffer (String.sub source last (String.length source - last));
  let rewritten = Buffer.contents buffer in
  Result.map
    (fun modules -> { hole.run with source = rewritten; modules; fills = hole.run.fills + 1 })
    (Lang.compile hole.run.calls rewritten)
