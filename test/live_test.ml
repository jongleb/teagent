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
            match Live.powers ~apis:[] modules with
            | [ (Driver "fetch.get", Sends) ] -> None
            | _ -> Some "live: the powers of a widget that fetches are not one send")
        | Error report -> Some ("live: a granted Fetch did not compile:\n" ^ report));
        (match Lang.compile_modules Lang.Calls.pure [ ("Live", counter) ] ~entries:[] with
        | Error _ -> None
        | Ok _ -> Some "live: a module took the name Live");
      ]
  in
  List.iter prerr_endline failures;
  match failures with [] -> print_endline "live: ok" | _ :: _ -> exit 1
