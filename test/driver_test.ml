let () =
  let workspaces = ref [] in
  let fresh () =
    let workspace = Filename.temp_dir "teagent" "" in
    workspaces := workspace :: !workspaces;
    Sys.mkdir (Filename.concat workspace "lib") 0o755;
    Out_channel.with_open_text (Filename.concat workspace "lib/a.ml") (fun channel ->
        Out_channel.output_string channel "let x = Foo.bar 1\n");
    workspace
  in
  let contents workspace path =
    In_channel.with_open_text (Filename.concat workspace path) In_channel.input_all
  in
  let fenced program = "Here is the program.\n\n```elm\n" ^ program ^ "```\n" in
  let broken =
    "module Main exposing (main)\n\n\
     import Agent exposing (..)\n\n\n\
     main : Task IoErr String\n\
     main =\n\
    \    read 42\n"
  in
  let renaming =
    "module Main exposing (main)\n\n\
     import Agent exposing (..)\n\n\n\
     main : Task IoErr { out : String, code : Int }\n\
     main =\n\
    \    edit { path = \"lib/a.ml\", old = \"Foo.bar\", new = \"Foo.baz\" }\n\
    \        |> andThen (\\_ -> shell \"cat lib/a.ml\")\n"
  in
  let task = "Rename Foo.bar to Foo.baz." in
  let collected world =
    let events = ref [] in
    let report =
      Lwt_main.run
        (Driver.solve world
           ~on:(fun event ->
             events := event :: !events;
             Lwt.return_unit)
           task)
    in
    (report, List.rev !events)
  in
  let session ~decision =
    let workspace = fresh () in
    let replies = ref [ fenced broken; fenced renaming; "Renamed Foo.bar to Foo.baz." ] in
    let asked = ref [] in
    let report, events =
      collected
        {
          ask =
            (fun ~system:_ history ->
              asked := history :: !asked;
              match !replies with
              | reply :: rest ->
                  replies := rest;
                  Lwt.return (Ok reply)
              | [] -> Lwt.return (Error (`Llm (Llm.Transport "no more replies"))));
          approve = (fun _ -> Lwt.return decision);
          handler = Handler.staged (Tools.at workspace) Handler.Open;
          commit = Tools.commit (Tools.at workspace);
        }
    in
    (workspace, report, events, List.rev !asked)
  in
  let applied = session ~decision:Driver.Apply in
  let stubborn =
    let workspace = fresh () in
    let reading =
      "module Main exposing (main)\n\n\
       import Agent exposing (..)\n\n\n\
       main : Task IoErr String\n\
       main =\n\
      \    read \"lib/a.ml\"\n"
    in
    let replies =
      ref
        [
          "It is surely Foo.bar in lib/a.ml.";
          fenced broken;
          fenced broken;
          fenced reading;
          fenced reading;
          "lib/a.ml holds Foo.bar.";
        ]
    in
    let asked = ref [] in
    let report, events =
      collected
        {
          ask =
            (fun ~system:_ history ->
              asked := history :: !asked;
              match !replies with
              | reply :: rest ->
                  replies := rest;
                  Lwt.return (Ok reply)
              | [] -> Lwt.return (Error (`Llm (Llm.Transport "no more replies"))));
          approve = (fun _ -> Lwt.return Driver.Apply);
          handler = Handler.staged (Tools.at workspace) Handler.Open;
          commit = Tools.commit (Tools.at workspace);
        }
    in
    (report, events, List.rev !asked)
  in
  let failures =
    List.filter_map Fun.id
      [
        (match applied with
        | ( workspace,
            { ending = Ok "Renamed Foo.bar to Foo.baz."; rounds = [ 2 ] },
            [
              Wrote _;
              Refused _;
              Wrote _;
              Performed { tool = Edit _; result = Ok V_unit; staged = [ _ ] };
              Deferred (Shell "cat lib/a.ml");
              Staged diff;
              Decided Apply;
              Committed (Ok ());
              Performed { tool = Shell "cat lib/a.ml"; staged = []; _ };
              Ran ran;
              Answered _;
            ],
            [ _; _; last ] ) -> (
            match
              ( contents workspace "lib/a.ml",
                String.equal diff
                  "--- a/lib/a.ml\n\
                   +++ b/lib/a.ml\n\
                   @@ -1,1 +1,1 @@\n\
                   -let x = Foo.bar 1\n\
                   +let x = Foo.baz 1\n",
                String.equal ran
                  "main finished with:\n{ code = 0, out = \"let x = Foo.baz 1\\n\" }",
                List.length last )
            with
            | "let x = Foo.baz 1\n", true, true, 5 -> None
            | _, _, _, _ -> Some ("apply: the file, diff, result or history is wrong\n" ^ ran))
        | _ -> Some "apply: the session went another way");
        (let contains text piece =
           let rec at index =
             index + String.length piece <= String.length text
             && (String.equal (String.sub text index (String.length piece)) piece
                || at (index + 1))
           in
           at 0
         in
         let last (history : Llm.message list) =
           Option.fold ~none:"" ~some:(fun (message : Llm.message) -> message.text)
             (List.nth_opt (List.rev history) 0)
         in
         match stubborn with
         | ( { ending = Ok "lib/a.ml holds Foo.bar."; rounds = [ 3; 1 ] },
             [
               Guessed _;
               Wrote _;
               Refused _;
               Wrote _;
               Refused _;
               Wrote _;
               Performed _;
               Ran _;
               Wrote _;
               Performed _;
               Ran _;
               Answered _;
             ],
             [ _; guessed; once; twice; _; ran_again ] ) -> (
             match
               ( contains (last guessed) "You have not looked at the workspace yet",
                 contains (last once) "This is the same program",
                 contains (last twice) "This is the same program",
                 contains (last ran_again) "You already ran this same program" )
             with
             | true, false, true, true -> None
             | _ -> Some "stubborn: the model was not told what it repeats or guesses")
         | _ -> Some "stubborn: the session went another way");
        (match session ~decision:Driver.Discard with
        | workspace, { ending = Error Discarded; rounds = [ 2 ] }, _, _ -> (
            match contents workspace "lib/a.ml" with
            | "let x = Foo.bar 1\n" -> None
            | _ -> Some "discard: the file changed")
        | _ -> Some "discard: the session went another way");
        (let _, report, recorded, _ = applied in
         match collected (Driver.replayed recorded) with
         | again, replayed when replayed = recorded && again = report -> None
         | _ -> Some "replay: the replayed session differs from the log");
        (let _, report, recorded, _ = applied in
         let rec cut = function
           | [] -> []
           | (Driver.Decided Apply as decided) :: _ -> [ decided ]
           | event :: rest -> event :: cut rest
         in
         let resumed ~committed =
           let workspace = fresh () in
           if committed then
             Out_channel.with_open_text (Filename.concat workspace "lib/a.ml") (fun channel ->
                 Out_channel.output_string channel "let x = Foo.baz 1\n");
           let live_asks = ref 0 in
           let again, events =
             collected
               (Driver.resumed (cut recorded)
                  {
                    ask =
                      (fun ~system:_ _ ->
                        incr live_asks;
                        Lwt.return (Ok "Renamed Foo.bar to Foo.baz."));
                    approve = (fun _ -> Lwt.return Driver.Apply);
                    handler = Handler.staged (Tools.at workspace) Handler.Open;
                    commit = Tools.commit (Tools.at workspace);
                  })
           in
           match (again = report, events = recorded, !live_asks, contents workspace "lib/a.ml") with
           | true, true, 1, "let x = Foo.baz 1\n" -> None
           | same_report, same_events, asks, file ->
               Some
                 (Printf.sprintf
                    "resume (committed before the crash: %b): report %b, events %b (%d vs %d), \
                     live asks %d, file %S\n%s"
                    committed same_report same_events (List.length events) (List.length recorded)
                    asks file
                    (String.concat "\n"
                       (List.map (fun event -> Yojson.Safe.to_string (Driver.event_to_json event)) events)))
         in
         match (resumed ~committed:false, resumed ~committed:true) with
         | None, None -> None
         | Some failure, _ | _, Some failure -> Some failure);
        (let _, _, recorded, _ = applied in
         match
           List.map
             (fun event ->
               Driver.event_of_json
                 (Yojson.Safe.from_string (Yojson.Safe.to_string (Driver.event_to_json event))))
             recorded
         with
         | decoded when decoded = List.map Result.ok recorded -> None
         | _ -> Some "json: an event does not survive the log");
      ]
  in
  let rec removed path =
    match Sys.is_directory path with
    | true ->
        Array.iter (fun name -> removed (Filename.concat path name)) (Sys.readdir path);
        Sys.rmdir path
    | false -> Sys.remove path
  in
  List.iter removed !workspaces;
  match failures with
  | [] -> ()
  | _ :: _ ->
      prerr_endline (String.concat "\n\n" failures);
      exit 1
