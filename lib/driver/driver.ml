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
  | Exhausted of Value.tool
  | Staged of string
  | Decided of decision
  | Held of { diff : string; decision : decision }
  | Exposed of { summary : string; decision : decision }
  | Committed of (Tools.Path.t list, string) result
  | Ran of string
  | Guessed of string
  | Answered of string
  | Filled of { hole : string; reply : string }

type stop = Llm_failed of Llm.error | Never_compiled of string | Discarded | Too_many_programs
type report = { ending : (string, stop) result; rounds : int list }

type world = {
  ask : system:string -> Llm.message list -> (string, [ `Llm of Llm.error ]) result Lwt.t;
  approve : string -> decision Lwt.t;
  person : string -> Device.consent Lwt.t;
  handler : Handler.Overlay.t Handler.t;
  commit : Tools.change list -> (unit, [ `Tools of Tools.error ]) result Lwt.t;
  os : Os.t;
  recorded : event list;
}

let solve world ~on task =
  let queued pick = ref (List.filter_map pick world.recorded) in
  let next queue =
    match !queue with
    | first :: rest ->
        queue := rest;
        Some first
    | [] -> None
  in
  let replies =
    queued (function
      | Wrote text | Guessed text | Answered text | Filled { reply = text; _ } -> Some text
      | _ -> None)
  in
  let steps =
    queued (function
      | Performed { tool; result; staged } -> Some (tool, `Performed (result, staged))
      | Deferred tool -> Some (tool, `Deferred)
      | Exhausted tool -> Some (tool, `Exhausted)
      | _ -> None)
  in
  let decisions = queued (function Decided decision -> Some decision | _ -> None) in
  let holds = queued (function Held { decision; _ } -> Some decision | _ -> None) in
  let exposures = queued (function Exposed { decision; _ } -> Some decision | _ -> None) in
  let commits = queued (function Committed outcome -> Some outcome | _ -> None) in
  let ask ~system history =
    match next replies with
    | Some reply -> Lwt.return (Ok reply)
    | None -> world.ask ~system history
  in
  let approve diff =
    match next decisions with
    | Some decision -> Lwt.return decision
    | None -> world.approve diff
  in
  let commit changes =
    match next commits with
    | Some (Ok _) -> Lwt.return (Ok ())
    | Some (Error reason) -> Lwt.return (Error (`Tools (Tools.Conflict reason)))
    | None -> world.commit changes
  in
  let system =
    String.concat "\n\n"
      ([
         "You are teagent, a coding agent. You act only by writing a program in Dartea, a \
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
          - `shell` runs `/bin/sh -c` in a sandboxed copy of the workspace that already holds \
          your edits, without network, and returns stdout and stderr together; the files it \
          writes are staged with your edits.\n\
          - `String.toInt`, `List.head` and `Dict.get` return a `Maybe` (`Just` / `Nothing`), \
          not a `Result`. `port`, `type`, `as` and `where` are reserved words.\n\
          - Write the Agent functions without a prefix (`succeed`, not `Task.succeed`); \
          `fromResult` turns a `Result` into a task. Only the core List functions exist, \
          there is no `List.Extra`.\n\
          - If `main` has its own error type, convert each `IoErr` with `mapErr`; otherwise \
          use `IoErr` itself.\n\
          - Look before you answer: write a program that reads or searches first.\n\
          - When the compiler reports an error, change the program and send all of it again.\n\
          - When part of the program depends on what earlier steps return and you cannot \
          write it before you see that, put `hole \"what goes here\"` in its place, with a \
          plain string: it is a task of whatever type fits there. When main reaches it, you \
          see the values in scope and write the code for that place; that code may hold holes \
          too.\n\
          - `spawn mounts task` runs `task` as a child process: it sees your changes so far, \
          cannot see what `mounts` hide, and keeps its own changes apart. They reach yours \
          only through `merge`, which fails with the changes that clash if a file moved \
          meanwhile. Use it to try something you may throw away.\n\
          - teagent tracks where every value came from, and counts what you write as carrying \
          everything earlier programs and holes of this session read. A Fetch call or a shell \
          command under --net that carries content of the project runs only if the person says \
          yes; otherwise it fails with Declined (a shell command gets exit code 126). So reach \
          the network first, before you read the project, when the task allows it. A program \
          that reads the project and runs shell under --net asks the person before it \
          starts.\n\
          - When the task is done, reply in plain text without a code block, and state the \
          facts you found: names, paths, numbers.";
         "The modules this run offers: Agent, and drivers such as Fetch, which a program \
          imports by name (`import Fetch`). `Fetch.get` reaches only the hosts the user granted; \
          the others fail with `NotGranted`. `Fetch.post` sends data out, which cannot be \
          taken back, so it goes only if the person says yes; otherwise it fails with \
          `Declined`, and you should tell them what you wanted to send.\n\n\
          ```elm\n"
         ^ Lang.Calls.source (Os.table world.os) ^ "```";
         "The examples below show the style only. Each solves a different task from yours; \
          write a new program for your task instead of copying one.";
       ]
      @ List.map (fun example -> "An example program:\n\n```elm\n" ^ example ^ "```") Examples.all)
  in
  let performed = ref [] in
  let watched =
    Handler.booted (Os.view world.os).boot ~class_of:(Os.class_of world.os)
      ~rules:(fun tool sources -> Os.decided world.os !performed tool sources)
      ~person:world.person
      ~journal:(fun (inner : Handler.Overlay.t Handler.t) ->
        {
          perform =
            (fun tool sources overlay ->
              let* step =
                match next steps with
                | Some (recorded, `Performed (result, staged)) when recorded = tool ->
                    Lwt.return (Handler.Performed (result, Handler.Overlay.after overlay tool staged))
                | Some (recorded, `Deferred) when recorded = tool -> Lwt.return Handler.Blocked
                | Some (recorded, `Exhausted) when recorded = tool -> Lwt.return Handler.Exhausted
                | Some _ ->
                    replies := [];
                    steps := [];
                    decisions := [];
                    holds := [];
                    exposures := [];
                    commits := [];
                    inner.perform tool sources overlay
                | None -> inner.perform tool sources overlay
              in
              let* () =
                on
                  (match step with
                  | Handler.Performed (result, after) ->
                      performed := tool :: !performed;
                      Performed { tool; result; staged = Handler.Overlay.since overlay after }
                  | Handler.Blocked -> Deferred tool
                  | Handler.Exhausted -> Exhausted tool)
              in
              Lwt.return step);
        })
      world.handler
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
    let text = Tools.redacted (Value.to_elm value) and limit = 20_000 in
    if String.length text <= limit then text
    else
      Printf.sprintf "%s… (%d more characters cut)" (String.sub text 0 limit)
        (String.length text - limit)
  in
  let settled overlay =
    let outside, inside =
      List.partition
        (fun (change : Tools.change) -> Option.is_some (Tools.Path.runner change.path))
        (Handler.Overlay.changes overlay)
    in
    let* decision =
      match inside with
      | [] -> Lwt.return Apply
      | _ :: _ ->
          let diff = Handler.Overlay.diff inside in
          let* () = on (Staged diff) in
          let* decision = approve diff in
          let+ () = on (Decided decision) in
          decision
    in
    match decision with
    | Discard -> Lwt.return (Error `Discarded)
    | Apply -> (
        let* held =
          match outside with
          | [] -> Lwt.return Apply
          | _ :: _ -> (
              let diff = Handler.Overlay.diff outside in
              let* decision =
                match next holds with
                | Some decision -> Lwt.return decision
                | None ->
                    Lwt.map
                      (function Device.Agrees -> Apply | Declines -> Discard)
                      (world.person
                         ("write files that run outside the sandbox after this session:\n"
                         ^ String.concat "\n"
                             (List.filter_map
                                (fun (change : Tools.change) ->
                                  Option.map
                                    (fun runner -> "  " ^ (change.path :> string) ^ ", run by " ^ runner)
                                    (Tools.Path.runner change.path))
                                outside)
                         ^ "\n\n" ^ diff))
              in
              let+ () = on (Held { diff; decision }) in
              decision)
        in
        let kept, withheld =
          match held with Apply -> (inside @ outside, []) | Discard -> (inside, outside)
        in
        let paths = List.map (fun (change : Tools.change) -> change.path) in
        match kept with
        | [] -> Lwt.return (Ok (paths withheld))
        | _ :: _ ->
            let* committed = commit kept in
            let applied =
              Result.map_error
                (fun (`Tools (Tools.Not_found reason | Denied reason | Conflict reason)) ->
                  `Conflicted reason)
                committed
            in
            let* () =
              on
                (Committed
                   (Result.fold
                      ~ok:(fun () -> Ok (paths kept))
                      ~error:(fun (`Conflicted reason) -> Error reason)
                      applied))
            in
            Lwt.return (Result.map (fun () -> paths withheld) applied))
  in
  let cleared run =
    match Os.exposure world.os (Run.calls run) with
    | None -> Lwt.return (Ok run)
    | Some { reads; inward; outward } -> (
        let summary =
          Printf.sprintf
            "read the project (%s), take in text from outside (%s) and send data out (%s)"
            (String.concat ", " reads) (String.concat ", " inward) (String.concat ", " outward)
        in
        let* decision =
          match next exposures with
          | Some decision -> Lwt.return decision
          | None ->
              Lwt.map
                (function Device.Agrees -> Apply | Declines -> Discard)
                (world.person summary)
        in
        let+ () = on (Exposed { summary; decision }) in
        match decision with
        | Apply -> Ok run
        | Discard ->
            Error
              ("The person did not let this program " ^ summary
             ^ ". A program that does all three can leak the project, so it needs their yes. \
                Do the task without one of the three, or tell the person to run teagent with \
                --ask."))
  in
  let executed history run =
    let refused history = function
      | `Discarded -> Error Discarded
      | `Conflicted reason -> Ok (history, "The changes could not be applied: " ^ reason)
    in
    let rec ran history run =
      let* went =
        Run.run run ~seen:(List.concat_map Value.sources !performed) watched ~settle:(fun overlay -> Lwt.map (Result.map ignore) (settled overlay))
      in
      match went with
      | Error problem -> Lwt.return (refused history problem)
      | Ok (outcome, overlay) -> (
          let finished history text =
            Lwt.map
              (Result.fold
                 ~ok:(fun withheld ->
                   Ok
                     ( history,
                       match withheld with
                       | [] -> text
                       | _ :: _ ->
                           text
                           ^ "\n\nNot written, because other programs run them outside the \
                              sandbox and the person did not allow it: "
                           ^ String.concat ", "
                               (List.map (fun (path : Tools.Path.t) -> (path :> string)) withheld) ))
                 ~error:(refused history))
              (settled overlay)
          in
          match outcome with
          | Finished (Ok value) -> finished history ("main finished with:\n" ^ shown value)
          | Finished (Error (`Failed value)) -> finished history ("main failed with:\n" ^ shown value)
          | Finished (Error ((`Interp _ | `Exhausted) as stop)) -> finished history (Run.stopped stop)
          | Unfillable reason -> finished history reason
          | Reached hole ->
              let rec asked history round =
                let* reply = ask ~system history in
                match reply with
                | Error (`Llm problem) -> Lwt.return (Error (Llm_failed problem))
                | Ok text -> (
                    let* () = on (Filled { hole = Run.description hole; reply = text }) in
                    let history = history @ [ { Llm.role = Assistant; text } ] in
                    let again problem =
                      match round >= 4 with
                      | true ->
                          finished history
                            ("main stopped at the hole "
                            ^ Value.to_elm (V_string (Run.description hole))
                            ^ ": none of 4 replies for it compiled.")
                      | false ->
                          asked
                            (history
                            @ [
                                {
                                  Llm.role = User;
                                  text = problem ^ "\n\nSend the expression for the hole again.";
                                };
                              ])
                            (round + 1)
                    in
                    match program_in text with
                    | None -> again "Reply with one ```elm block holding only the expression."
                    | Some code -> (
                        match Run.filled hole code with
                        | Ok run -> (
                            let* cleared = cleared run in
                            match cleared with
                            | Ok run -> ran history run
                            | Error refusal -> again refusal)
                        | Error report ->
                            let* () = on (Refused report) in
                            again ("That code does not compile in place of the hole:\n\n" ^ report)))
              in
              asked
                (history
                @ [
                    {
                      Llm.role = User;
                      text =
                        Run.question hole
                        ^ "\n\nReply with one ```elm block holding only that expression.";
                    };
                  ])
                1)
    in
    ran history run
  in
  let rec conversation history rounds runs nudged =
    match List.length rounds >= 8 with
    | true -> Lwt.return { ending = Error Too_many_programs; rounds = List.rev rounds }
    | false -> replied history rounds runs nudged 1 None
  and replied history rounds runs nudged round previous =
    let* reply = ask ~system history in
    match reply with
    | Error (`Llm problem) ->
        Lwt.return { ending = Error (Llm_failed problem); rounds = List.rev rounds }
    | Ok text -> (
        match (program_in text, rounds, nudged) with
        | None, [], `Not_nudged ->
            let* () = on (Guessed text) in
            replied
              (history
              @ [
                  { Llm.role = Assistant; text };
                  {
                    Llm.role = User;
                    text =
                      "You have not looked at the workspace yet, so that answer is a guess. \
                       Write a program that finds out, then answer from what it returns.";
                  };
                ])
              rounds runs `Nudged round previous
        | None, _, _ ->
            let* () = on (Answered text) in
            Lwt.return { ending = Ok text; rounds = List.rev rounds }
        | Some source, _, _ -> (
            let* () = on (Wrote text) in
            let history = history @ [ { Llm.role = Assistant; text } ] in
            match Run.compiled (Os.table world.os) source with
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
                          (match previous with
                          | Some earlier when String.equal earlier source ->
                              "This is the same program you sent before, so the compiler \
                               rejects it the same way. Change it.\n\n"
                          | Some _ | None -> "")
                          ^ "The program does not compile:\n\n" ^ report
                          ^ "\n\nSend the whole corrected program.";
                      };
                    ])
                  rounds runs nudged (round + 1) (Some source)
            | Ok run -> (
                let* result =
                  let* cleared = cleared run in
                  match cleared with
                  | Ok run -> executed history run
                  | Error refusal -> Lwt.return (Ok (history, refusal))
                in
                match result with
                | Error stop -> Lwt.return { ending = Error stop; rounds = List.rev (round :: rounds) }
                | Ok (history, result) ->
                    let* () = on (Ran result) in
                    conversation
                      (history
                      @ [
                          {
                            Llm.role = User;
                            text =
                              result
                              ^ Option.fold
                                  ~none:
                                    "\n\nIf the task is done, reply in plain text without a \
                                     program, and state the facts you found: names, paths, \
                                     numbers. Otherwise send the next program."
                                  ~some:(fun _ ->
                                    "\n\nYou already ran this same program and got this same \
                                     result, so running it again will not help. The task is:\n\n"
                                    ^ task
                                    ^ "\n\nWrite a different program, or answer in plain text \
                                       from what you found.")
                                  (List.find_opt (fun run -> run = (source, result)) runs);
                          };
                        ])
                      (round :: rounds) ((source, result) :: runs) nudged)))
  in
  conversation [ { Llm.role = User; text = task } ] [] [] `Not_nudged

let explained = function
  | Llm_failed problem -> Llm.explained problem
  | Never_compiled _ -> "The program still did not compile after 4 rounds."
  | Discarded -> "Stopped: the changes were not applied."
  | Too_many_programs -> "Stopped after 8 programs without an answer."

let replayed os recorded =
  {
    os;
    recorded;
    ask = (fun ~system:_ _ -> Lwt.return (Error (`Llm (Llm.Transport "the log has no more replies"))));
    approve = (fun _ -> Lwt.return Discard);
    person = (fun _ -> Lwt.return Device.Declines);
    handler =
      {
        perform =
          (fun _ _ overlay ->
            Lwt.return (Handler.Performed (Error (Value.V_string "the log has no such tool here"), overlay)));
      };
    commit = (fun _ -> Lwt.return (Error (`Tools (Tools.Conflict "the log has no commit here"))));
  }

let undone events =
  let committed, _ =
    List.fold_left
      (fun (committed, overlay) event ->
        match event with
        | Performed { tool; staged; _ } -> (committed, Handler.Overlay.after overlay tool staged)
        | Committed (Ok paths) ->
            ( committed
              @ List.filter
                  (fun (change : Tools.change) -> List.mem change.path paths)
                  (Handler.Overlay.changes overlay),
              Handler.Overlay.empty )
        | Committed (Error _) | Decided Discard -> (committed, Handler.Overlay.empty)
        | Wrote _ | Refused _ | Deferred _ | Exhausted _ | Staged _ | Decided Apply | Held _
        | Exposed _ | Ran _ | Guessed _
        | Answered _ | Filled _ ->
            (committed, overlay))
      ([], Handler.Overlay.empty) events
  in
  let spans =
    List.fold_left
      (fun spans (change : Tools.change) ->
        let key = (change.path :> string) in
        match List.assoc_opt key spans with
        | Some (path, before, _) -> (key, (path, before, change.after)) :: List.remove_assoc key spans
        | None -> (key, (change.path, change.before, change.after)) :: spans)
      [] committed
  in
  List.filter_map
    (fun (_, (path, before, after)) ->
      match Option.equal String.equal before after with
      | true -> None
      | false -> Some { Tools.path; before = after; after = before })
    (List.sort (fun (one, _) (other, _) -> String.compare one other) spans)

let event_to_json event : Yojson.Safe.t =
  let text tag body = `Assoc [ (tag, `String body) ] in
  match event with
  | Wrote reply -> text "wrote" reply
  | Refused report -> text "refused" report
  | Staged diff -> text "staged" diff
  | Ran result -> text "ran" result
  | Guessed reply -> text "guessed" reply
  | Answered reply -> text "answered" reply
  | Filled { hole; reply } ->
      `Assoc [ ("filled", `Assoc [ ("hole", `String hole); ("reply", `String reply) ]) ]
  | Decided Apply -> text "decided" "apply"
  | Decided Discard -> text "decided" "discard"
  | Held { diff; decision } ->
      `Assoc
        [
          ( "held",
            `Assoc
              [
                ("diff", `String diff);
                ("decision", `String (match decision with Apply -> "apply" | Discard -> "discard"));
              ] );
        ]
  | Exposed { summary; decision } ->
      `Assoc
        [
          ( "exposed",
            `Assoc
              [
                ("summary", `String summary);
                ("decision", `String (match decision with Apply -> "apply" | Discard -> "discard"));
              ] );
        ]
  | Committed (Ok paths) ->
      `Assoc [ ("committed", `List (List.map (fun (path : Tools.Path.t) -> `String (path :> string)) paths)) ]
  | Committed (Error reason) -> text "committed" reason
  | Deferred tool -> `Assoc [ ("deferred", Value.tool_to_json tool) ]
  | Exhausted tool -> `Assoc [ ("exhausted", Value.tool_to_json tool) ]
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
                             ( "after",
                               Option.fold ~none:`Null ~some:(fun text -> `String text) after );
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
  | `Assoc [ ("guessed", `String reply) ] -> Ok (Guessed reply)
  | `Assoc [ ("answered", `String reply) ] -> Ok (Answered reply)
  | `Assoc [ ("filled", `Assoc [ ("hole", `String hole); ("reply", `String reply) ]) ] ->
      Ok (Filled { hole; reply })
  | `Assoc [ ("decided", `String "apply") ] -> Ok (Decided Apply)
  | `Assoc [ ("decided", `String "discard") ] -> Ok (Decided Discard)
  | `Assoc [ ("held", `Assoc [ ("diff", `String diff); ("decision", `String "apply") ]) ] ->
      Ok (Held { diff; decision = Apply })
  | `Assoc [ ("held", `Assoc [ ("diff", `String diff); ("decision", `String "discard") ]) ] ->
      Ok (Held { diff; decision = Discard })
  | `Assoc [ ("exposed", `Assoc [ ("summary", `String summary); ("decision", `String "apply") ]) ] ->
      Ok (Exposed { summary; decision = Apply })
  | `Assoc [ ("exposed", `Assoc [ ("summary", `String summary); ("decision", `String "discard") ]) ]
    ->
      Ok (Exposed { summary; decision = Discard })
  | `Assoc [ ("committed", `List paths) ] ->
      Result.map
        (fun paths -> Committed (Ok paths))
        (List.fold_right
           (fun path collected ->
             Result.bind collected (fun rest ->
                 match path with
                 | `String text ->
                     Result.map_error
                       (fun _ -> "not a recorded path: " ^ text)
                       (Result.map (fun path -> path :: rest) (Tools.Path.of_string text))
                 | other -> Error ("not a recorded path: " ^ Yojson.Safe.to_string other)))
           paths (Ok []))
  | `Assoc [ ("committed", `String reason) ] -> Ok (Committed (Error reason))
  | `Assoc [ ("deferred", tool) ] -> Result.map (fun tool -> Deferred tool) (Value.tool_of_json tool)
  | `Assoc [ ("exhausted", tool) ] -> Result.map (fun tool -> Exhausted tool) (Value.tool_of_json tool)
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
                         let text = function
                           | `Null -> Ok None
                           | `String content -> Ok (Some content)
                           | _ -> Error ("not a recorded change: " ^ Yojson.Safe.to_string change)
                         in
                         match change with
                         | `Assoc [ ("path", `String path); ("before", before); ("after", after) ] -> (
                             match (Tools.Path.of_string path, text before, text after) with
                             | Ok path, Ok before, Ok after ->
                                 Ok ({ Tools.path; before; after } :: rest)
                             | Error _, _, _ ->
                                 Error ("not a recorded change: " ^ Yojson.Safe.to_string change)
                             | Ok _, (Error _ as failure), _ | Ok _, Ok _, (Error _ as failure) ->
                                 failure)
                         | _ -> Error ("not a recorded change: " ^ Yojson.Safe.to_string change)))
                   staged (Ok []))))
  | other -> Error ("not a recorded event: " ^ Yojson.Safe.to_string other)
