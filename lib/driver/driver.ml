open Lwt.Syntax

type decision = Apply | Discard

type event =
  | Wrote of string
  | Refused of string
  | Performed of {
      tool : Value.tool;
      result : (Value.t, Value.t) result;
      staged : Tools.change list;
    }
  | Deferred of Value.tool
  | Staged of string
  | Decided of decision
  | Committed of (unit, string) result
  | Ran of string
  | Answered of string

type stop = Llm_failed of Llm.error | Never_compiled of string | Discarded | Too_many_programs
type report = { ending : (string, stop) result; rounds : int list }

type world = {
  ask : system:string -> Llm.message list -> (string, [ `Llm of Llm.error ]) result Lwt.t;
  approve : string -> decision Lwt.t;
  handler : Handler.Overlay.t Handler.t;
  commit : Tools.change list -> (unit, [ `Tools of Tools.error ]) result Lwt.t;
}

let system =
  String.concat "\n\n"
    ([
       "You are Rune, a coding agent. You act only by writing a program in Dartea, a \
        dialect of Elm. The harness typechecks it, runs it in the user's workspace, and \
        shows you the value of `main`.";
       "Rules:\n\
        - Reply with exactly one ```elm code block holding one module: `module Main \
        exposing (main)`, `import Agent exposing (..)`, and `main : Task e a`.\n\
        - Every effect goes through the Agent module below; nothing else can touch files \
        or run commands. Paths are relative to the workspace.\n\
        - Handle every error and cover every case of a `case`; the compiler rejects \
        missing branches.\n\
        - The core modules Basics, List, Maybe, Result, String, Char, Tuple, Dict and Set \
        are available. `List.unique` removes duplicates.\n\
        - `grep` takes an Emacs-style regular expression, not PCRE: alternation is `\\|` \
        (written \"a\\\\|b\" in an Elm string) and there is no `\\d`. `glob` matches \
        paths like `lib/**/*.ml`.\n\
        - `shell` runs `/bin/sh -c` in the workspace and returns stdout and stderr \
        together.\n\
        - When the compiler reports an error, send the whole corrected program.\n\
        - When the task is done, reply in plain text without a code block.";
       "The Agent module:\n\n```elm\n" ^ Agent.source ^ "```";
     ]
    @ List.map (fun example -> "An example program:\n\n```elm\n" ^ example ^ "```") Examples.all)

let solve { ask; approve; handler; commit } ~on task =
  let watched =
    {
      Handler.perform =
        (fun tool overlay ->
          let* step = handler.perform tool overlay in
          match step with
          | Handler.Performed (result, after) ->
              let* () =
                on
                  (Performed
                     {
                       tool;
                       result;
                       staged =
                         List.filter
                           (fun change -> not (List.mem change (Handler.Overlay.changes overlay)))
                           (Handler.Overlay.changes after);
                     })
              in
              Lwt.return step
          | Handler.Blocked ->
              let* () = on (Deferred tool) in
              Lwt.return step);
    }
  in
  let program_in reply =
    let opening = "```elm\n" in
    let rec found from =
      if from + String.length opening > String.length reply then None
      else if String.equal (String.sub reply from (String.length opening)) opening then
        let start = from + String.length opening in
        let rec closing at =
          if at + 3 > String.length reply then None
          else if String.equal (String.sub reply at 3) "```" then
            Some (String.sub reply start (at - start))
          else closing (at + 1)
        in
        closing start
      else found (from + 1)
    in
    found 0
  in
  let shown value =
    let text = Value.to_elm value and limit = 20_000 in
    if String.length text <= limit then text
    else
      Printf.sprintf "%s… (%d more characters cut)" (String.sub text 0 limit)
        (String.length text - limit)
  in
  let settled overlay =
    match Handler.Overlay.changes overlay with
    | [] -> Lwt.return (Ok ())
    | changes -> (
        let diff = Handler.Overlay.diff overlay in
        let* () = on (Staged diff) in
        let* decision = approve diff in
        let* () = on (Decided decision) in
        match decision with
        | Discard -> Lwt.return (Error `Discarded)
        | Apply ->
            let* committed = commit changes in
            let applied =
              Result.map_error
                (fun (`Tools (Tools.Not_found reason | Denied reason | Conflict reason)) ->
                  `Conflicted reason)
                committed
            in
            let* () =
              on (Committed (Result.map_error (fun (`Conflicted reason) -> reason) applied))
            in
            Lwt.return applied)
  in
  let executed modules =
    let failed : Interp.error -> string = function
      | Crashed reason -> "main crashed: " ^ reason
      | Budget_exhausted -> "main ran out of steps; it probably loops forever."
      | Stuck reason -> "The harness failed to run main (a bug in Rune): " ^ reason
    in
    let program = Interp.load ~budget:10_000_000 modules in
    let rec stepped task =
      let* outcome, overlay = Handler.interpret watched program Handler.Overlay.empty task in
      let* settlement = settled overlay in
      match (settlement, outcome) with
      | Error `Discarded, _ -> Lwt.return (Error Discarded)
      | Error (`Conflicted reason), _ ->
          Lwt.return (Ok ("The changes could not be applied: " ^ reason))
      | Ok (), Stopped rest -> stepped rest
      | Ok (), Finished (Ok value) -> Lwt.return (Ok ("main finished with:\n" ^ shown value))
      | Ok (), Finished (Error (`Failed value)) ->
          Lwt.return (Ok ("main failed with:\n" ^ shown value))
      | Ok (), Finished (Error (`Interp error)) -> Lwt.return (Ok (failed error))
    in
    match Interp.main program with
    | Ok task -> stepped task
    | Error (`Interp error) -> Lwt.return (Ok (failed error))
  in
  let rec conversation history rounds =
    match List.length rounds >= 8 with
    | true -> Lwt.return { ending = Error Too_many_programs; rounds = List.rev rounds }
    | false -> replied history rounds 1
  and replied history rounds round =
    let* reply = ask ~system history in
    match reply with
    | Error (`Llm problem) ->
        Lwt.return { ending = Error (Llm_failed problem); rounds = List.rev rounds }
    | Ok text -> (
        match program_in text with
        | None ->
            let* () = on (Answered text) in
            Lwt.return { ending = Ok text; rounds = List.rev rounds }
        | Some source -> (
            let* () = on (Wrote text) in
            let history = history @ [ { Llm.role = Assistant; text } ] in
            match Lang.compile source with
            | Error report when round >= 4 ->
                let* () = on (Refused report) in
                Lwt.return { ending = Error (Never_compiled report); rounds = List.rev rounds }
            | Error report ->
                let* () = on (Refused report) in
                replied
                  (history
                  @ [
                      {
                        Llm.role = User;
                        text =
                          "The program does not compile:\n\n" ^ report
                          ^ "\n\nSend the whole corrected program.";
                      };
                    ])
                  rounds (round + 1)
            | Ok modules -> (
                let* result = executed modules in
                match result with
                | Error stop -> Lwt.return { ending = Error stop; rounds = List.rev (round :: rounds) }
                | Ok result ->
                    let* () = on (Ran result) in
                    conversation
                      (history
                      @ [
                          {
                            Llm.role = User;
                            text =
                              result
                              ^ "\n\nIf the task is done, reply in plain text without a \
                                 program. Otherwise send the next program.";
                          };
                        ])
                      (round :: rounds))))
  in
  conversation [ { Llm.role = User; text = task } ] []

let explained = function
  | Llm_failed problem -> Llm.explained problem
  | Never_compiled _ -> "The program still did not compile after 4 rounds."
  | Discarded -> "Stopped: the changes were not applied."
  | Too_many_programs -> "Stopped after 8 programs without an answer."

let resumed events live =
  let queued pick = ref (List.filter_map pick events) in
  let next queue =
    match !queue with
    | first :: rest ->
        queue := rest;
        Some first
    | [] -> None
  in
  let replies = queued (function Wrote text | Answered text -> Some text | _ -> None) in
  let steps =
    queued (function
      | Performed { tool; result; staged } -> Some (tool, `Performed (result, staged))
      | Deferred tool -> Some (tool, `Deferred)
      | _ -> None)
  in
  let decisions = queued (function Decided decision -> Some decision | _ -> None) in
  let commits = queued (function Committed outcome -> Some outcome | _ -> None) in
  {
    ask =
      (fun ~system history ->
        match next replies with
        | Some reply -> Lwt.return (Ok reply)
        | None -> live.ask ~system history);
    approve =
      (fun diff ->
        match next decisions with
        | Some decision -> Lwt.return decision
        | None -> live.approve diff);
    handler =
      {
        perform =
          (fun tool overlay ->
            match next steps with
            | Some (recorded, `Performed (result, staged)) when recorded = tool ->
                Lwt.return (Handler.Performed (result, Handler.Overlay.added overlay staged))
            | Some (recorded, `Deferred) when recorded = tool -> Lwt.return Handler.Blocked
            | Some _ ->
                replies := [];
                steps := [];
                decisions := [];
                commits := [];
                live.handler.perform tool overlay
            | None -> live.handler.perform tool overlay);
      };
    commit =
      (fun changes ->
        match next commits with
        | Some (Ok ()) -> Lwt.return (Ok ())
        | Some (Error reason) -> Lwt.return (Error (`Tools (Tools.Conflict reason)))
        | None -> live.commit changes);
  }

let replayed events =
  resumed events
    {
      ask = (fun ~system:_ _ -> Lwt.return (Error (`Llm (Llm.Transport "the log has no more replies"))));
      approve = (fun _ -> Lwt.return Discard);
      handler =
        {
          perform =
            (fun _ overlay ->
              Lwt.return
                (Handler.Performed (Error (Value.V_string "the log has no such tool here"), overlay)));
        };
      commit = (fun _ -> Lwt.return (Error (`Tools (Tools.Conflict "the log has no commit here"))));
    }

let event_to_json event : Yojson.Safe.t =
  let text tag body = `Assoc [ (tag, `String body) ] in
  match event with
  | Wrote reply -> text "wrote" reply
  | Refused report -> text "refused" report
  | Staged diff -> text "staged" diff
  | Ran result -> text "ran" result
  | Answered reply -> text "answered" reply
  | Decided Apply -> text "decided" "apply"
  | Decided Discard -> text "decided" "discard"
  | Committed (Ok ()) -> `Assoc [ ("committed", `Null) ]
  | Committed (Error reason) -> text "committed" reason
  | Deferred tool -> `Assoc [ ("deferred", Value.tool_to_json tool) ]
  | Performed { tool; result; staged } ->
      `Assoc
        [
          ( "performed",
            `Assoc
              [
                ("tool", Value.tool_to_json tool);
                ( "result",
                  match result with
                  | Ok value -> `Assoc [ ("ok", Value.to_json value) ]
                  | Error value -> `Assoc [ ("error", Value.to_json value) ] );
                ( "staged",
                  `List
                    (List.map
                       (fun ({ path; before; after } : Tools.change) ->
                         `Assoc
                           [
                             ("path", `String (path :> string));
                             ( "before",
                               Option.fold ~none:`Null ~some:(fun text -> `String text) before );
                             ("after", `String after);
                           ])
                       staged) );
              ] );
        ]

let event_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc [ ("wrote", `String reply) ] -> Ok (Wrote reply)
  | `Assoc [ ("refused", `String report) ] -> Ok (Refused report)
  | `Assoc [ ("staged", `String diff) ] -> Ok (Staged diff)
  | `Assoc [ ("ran", `String result) ] -> Ok (Ran result)
  | `Assoc [ ("answered", `String reply) ] -> Ok (Answered reply)
  | `Assoc [ ("decided", `String "apply") ] -> Ok (Decided Apply)
  | `Assoc [ ("decided", `String "discard") ] -> Ok (Decided Discard)
  | `Assoc [ ("committed", `Null) ] -> Ok (Committed (Ok ()))
  | `Assoc [ ("committed", `String reason) ] -> Ok (Committed (Error reason))
  | `Assoc [ ("deferred", tool) ] -> Result.map (fun tool -> Deferred tool) (Value.tool_of_json tool)
  | `Assoc
      [ ("performed", `Assoc [ ("tool", tool); ("result", result); ("staged", `List staged) ]) ]
    ->
      Result.bind (Value.tool_of_json tool) (fun tool ->
          Result.bind
            (match result with
            | `Assoc [ ("ok", value) ] -> Result.map Result.ok (Value.of_json value)
            | `Assoc [ ("error", value) ] -> Result.map Result.error (Value.of_json value)
            | other -> Error ("not a recorded result: " ^ Yojson.Safe.to_string other))
            (fun result ->
              Result.map
                (fun staged -> Performed { tool; result; staged })
                (List.fold_right
                   (fun change collected ->
                     Result.bind collected (fun rest ->
                         match change with
                         | `Assoc
                             [ ("path", `String path); ("before", before); ("after", `String after) ]
                           -> (
                             match (Tools.Path.of_string path, before) with
                             | Ok path, `Null -> Ok ({ Tools.path; before = None; after } :: rest)
                             | Ok path, `String before ->
                                 Ok ({ Tools.path; before = Some before; after } :: rest)
                             | Ok _, _ | Error _, _ ->
                                 Error ("not a recorded change: " ^ Yojson.Safe.to_string change))
                         | _ -> Error ("not a recorded change: " ^ Yojson.Safe.to_string change)))
                   staged (Ok []))))
  | other -> Error ("not a recorded event: " ^ Yojson.Safe.to_string other)
