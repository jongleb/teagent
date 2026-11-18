let () =
  let counter = In_channel.with_open_text "live/Counter.elm" In_channel.input_all in
  let main : Value.global = { module_name = "Counter"; name = "main" } in
  let shown = function
    | `Interp (Interp.Stuck reason) -> "stuck, " ^ reason
    | `Interp (Interp.Crashed reason) -> "crashed, " ^ reason
    | `Interp Interp.Budget_exhausted -> "out of budget"
    | `Undeclared ({ module_name; name } : Value.global) -> "no " ^ module_name ^ "." ^ name
    | `Live reason -> reason
  in
  let answered ~name (_ : Value.t) =
    Lwt.return
      (match name with
      | "listen.agents" -> Ok (Value.V_json (`List [ `Int 1; `Int 2; `Int 3 ]))
      | other -> Error (Value.V_string ("no answer for " ^ other)))
  in
  let ran program task =
    match fst (Lwt_main.run (Handler.interpret (Handler.answering answered) program () task)) with
    | Finished (Ok message) -> Ok message
    | Finished (Error _) | Stopped _ | Reached _ -> Error (`Live "a task did not end in a message")
  in
  let settled program live tasks =
    List.fold_left
      (fun live task -> Result.bind live (fun live -> Result.bind (ran program task) (fun message ->
           Result.bind (Live.updated live message) (fun (live, more) ->
               match more with [] -> Ok live | _ :: _ -> Error (`Live "a message gave more commands")))))
      (Ok live) tasks
  in
  let drawn live = Result.map Wire.json (Live.drawn live) in
  let journey () =
    match Lang.compile_modules Lang.Calls.pure [ ("Counter", counter) ] ~entries:[ main ] with
    | Error report -> Error (`Live ("refused:\n" ^ report))
    | Ok modules ->
        let program = Interp.load ~budget:(Each 1_000_000) modules in
        let ( let* ) = Result.bind in
        let* live, tasks = Live.started program main in
        let* live = settled program live tasks in
        let* first = drawn live in
        let* view = Live.drawn live in
        let* clicked = Live.message live ~view [ Index 1; Index 1; Key "onPress" ] [] in
        let* live, _ = Live.updated live clicked in
        let* typed = Live.message live ~view [ Index 2; Index 1 ] [ V_string "hi" ] in
        let* live, tasks = Live.updated live typed in
        let* live = settled program live tasks in
        let* second = drawn live in
        let* listened = Live.listening live in
        let* live =
          match listened with
          | [ { source = "agents"; task } ] ->
              Result.bind (ran program task) (fun heard -> Result.map fst (Live.updated live heard))
          | _ -> Error (`Live "the program does not listen to agents alone")
        in
        let* third = drawn live in
        Ok (List.map Yojson.Safe.to_string [ first; second; third ])
  in
  let compiled calls source =
    Lang.compile_modules calls [ ("Fetching", source) ] ~entries:[ { module_name = "Fetching"; name = "main" } ]
  in
  let fetching =
    "module Fetching exposing (main)\n\nimport Fetch\nimport Live\n\n\nmain : Live.Program () () ()\nmain =\n    Live.program\n        { init = ( (), Live.attempt (\\_ -> ()) (Fetch.get \"https://example.com\") )\n        , update = \\_ m -> ( m, Cmd.none )\n        , view = \\m -> m\n        , subscriptions = \\_ -> Sub.none\n        }\n"
  in
  let reading =
    "module Fetching exposing (main)\n\nimport Agent\nimport Live\n\n\nmain : Live.Program () () ()\nmain =\n    Live.program\n        { init = ( (), Live.attempt (\\_ -> ()) (Agent.read \"secret.txt\") )\n        , update = \\_ m -> ( m, Cmd.none )\n        , view = \\m -> m\n        , subscriptions = \\_ -> Sub.none\n        }\n"
  in
  let failures =
    List.filter_map Fun.id
      [
        (match journey () with
        | Ok
            [
              {|[["Shown",40,""],["Button",{"label":"+","onPress":"Clicked"}],["Field",null]]|};
              {|[["Shown",42,"hi"],["Button",{"label":"+","onPress":"Clicked"}],["Field",null]]|};
              {|[["Shown",3,"hi"],["Button",{"label":"+","onPress":"Clicked"}],["Field",null]]|};
            ] ->
            None
        | Ok views -> Some ("live: the views went\n" ^ String.concat "\n" views)
        | Error error -> Some ("live: " ^ shown error));
        (match (compiled Lang.Calls.pure fetching, compiled Lang.Calls.pure reading) with
        | Error _, Error _ -> None
        | _ -> Some "live: a widget without rights reached Fetch or Agent.read");
        (match compiled (Lang.Calls.plugging [ Device.Fetch ] Lang.Calls.pure) fetching with
        | Ok modules -> (
            match Live.powers ~devices:[] modules with
            | [ (Driver "fetch.get", Sends) ] -> None
            | _ -> Some "live: the powers of a widget that fetches are not one send")
        | Error report -> Some ("live: a granted Fetch did not compile:\n" ^ report));
        (match
           compiled
             (Lang.Calls.plugging [ Device.Person ] Lang.Calls.pure)
             "module Fetching exposing (main)\n\nimport Live\nimport Person\n\n\nmain : Live.Program () () ()\nmain =\n    Live.program\n        { init = ( (), Live.attempt (\\_ -> ()) (Person.ask \"Which?\" [ \"a\" ]) )\n        , update = \\_ m -> ( m, Cmd.none )\n        , view = \\m -> m\n        , subscriptions = \\_ -> Sub.none\n        }\n"
         with
        | Ok modules -> (
            match Live.powers ~devices:[] modules with
            | [ (Driver "person.ask", Asks) ] -> None
            | _ -> Some "live: the powers of a widget that asks are not one question")
        | Error report -> Some ("live: a granted Person did not compile:\n" ^ report));
        (let slack_source =
           "module Slack exposing (SlackErr(..), post)\n\nimport Agent exposing (Task)\n\n\ntype SlackErr\n    = Failed String\n\n\npost : { channel : String, text : String } -> Task SlackErr String\npost message =\n    Elm.Kernel.Agent.call \"slack.post\" message\n"
         in
         let declined = Value.V_string "the person did not let it post" in
         let calls = [ ("slack.post", Value.Irreversible { question = "post to Slack"; declined }) ] in
         let posting =
           "module Fetching exposing (main)\n\nimport Live\nimport Slack\n\n\nmain : Live.Program String String String\nmain =\n    Live.program\n        { init = ( \"\", Live.attempt (\\r -> case r of\n            Ok ts -> ts\n            Err _ -> \"failed\"\n          ) (Slack.post { channel = \"c\", text = \"hi\" }) )\n        , update = \\m _ -> ( m, Cmd.none )\n        , view = \\m -> m\n        , subscriptions = \\_ -> Sub.none\n        }\n"
         in
         let refusals =
           List.filter_map
             (fun (name, source, calls) -> Result.fold ~ok:(fun _ -> Some name) ~error:(fun _ -> None) (Device.hosted ~name ~source ~calls))
             [
               ("Fetch", slack_source, calls);
               ("Slack", "module Slack exposing (x)\n\nx =\n    Elm.Kernel.Agent.shell \"ls\"\n", calls);
               ("Slack", slack_source, []);
               ("Slack", slack_source, ("fetch.get", Value.Pure) :: calls);
               ("Jira", slack_source, calls);
             ]
         in
         match (Device.hosted ~name:"Slack" ~source:slack_source ~calls, refusals) with
         | Error reason, _ -> Some ("live: a host's module was refused: " ^ reason)
         | Ok _, _ :: _ -> Some "live: Device.hosted let in a module it should refuse"
         | Ok slack, [] -> (
             match compiled (Lang.Calls.plugging [ slack ] Lang.Calls.pure) posting with
             | Error report -> Some ("live: a widget with a host's module did not compile:\n" ^ report)
             | Ok modules -> (
                 let program = Interp.load ~budget:(Each 1_000_000) modules in
                 let answered ~name argument =
                   Lwt.return
                     (match (name, argument) with
                     | "slack.post", Value.V_record [ ("channel", V_string "c"); ("text", V_string "hi") ] ->
                         Ok (Value.V_string "ts1")
                     | _ -> Error (Value.V_string "unexpected"))
                 in
                 let main : Value.global = { module_name = "Fetching"; name = "main" } in
                 let viewed =
                   Result.bind (Live.started program main) (fun (live, tasks) ->
                       match tasks with
                       | [ task ] -> (
                           match fst (Lwt_main.run (Handler.interpret (Handler.answering answered) program () task)) with
                           | Finished (Ok message) -> Result.bind (Live.updated live message) (fun (live, _) -> Live.drawn live)
                           | _ -> Error (`Live "the post did not end in a message"))
                       | _ -> Error (`Live "init did not post once"))
                 in
                 match
                   ( Live.powers ~devices:[ slack ] modules,
                     Handler.class_of [] (Call { name = "slack.post"; argument = V_string "hi" }),
                     Handler.class_of [] (Call { name = "listen.agents"; argument = V_unit }),
                     Handler.class_of [ slack ] (Call { name = "slack.post"; argument = V_string "hi" }),
                     viewed,
                     Lang.compile_modules (Lang.Calls.plugging [ slack ] Lang.Calls.pure) [ ("Slack", slack_source) ] ~entries:[] )
                 with
                 | [ (Driver "slack.post", Changes) ], Irreversible _, Pure, Irreversible { question = "post to Slack, with:\n\"hi\""; _ }, Ok (V_string "ts1"), Error _ -> None
                 | _, _, _, _, Error error, _ -> Some ("live: the host did not answer the post: " ^ shown error)
                 | _ -> Some "live: a host's call got the wrong power or class, or a program took its module's name")));
        (match Lang.compile_modules Lang.Calls.pure [ ("Live", counter) ] ~entries:[] with
        | Error _ -> None
        | Ok _ -> Some "live: a module took the name Live");
      ]
  in
  List.iter prerr_endline failures;
  match failures with [] -> print_endline "live: ok" | _ :: _ -> exit 1
