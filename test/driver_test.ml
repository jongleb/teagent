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
          calls = Lang.Calls.all;
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
          calls = Lang.Calls.all;
        }
    in
    (report, events, List.rev !asked)
  in
  let nested =
    let workspace = fresh () in
    let holed =
      "module Main exposing (main)\n\n\
       import Agent exposing (..)\n\n\n\
       main : Task IoErr String\n\
       main =\n\
      \    edit { path = \"lib/a.ml\", old = \"Foo.bar\", new = \"Foo.baz\" }\n\
      \        |> andThen (\\_ -> read \"lib/a.ml\")\n\
      \        |> andThen (\\text -> hole \"turn the text into the answer\")\n"
    in
    let replies =
      ref
        [
          fenced holed;
          fenced "hole \"count it\"\n    |> map (\\count -> String.toUpper text ++ count)\n";
          fenced "succeed (String.fromInt (String.length text))\n";
          "Done.";
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
          calls = Lang.Calls.all;
        }
    in
    (workspace, report, events, List.rev !asked)
  in
  let requests = ref [] in
  let port =
    let socket = Lwt_unix.socket PF_INET SOCK_STREAM 0 in
    Lwt_main.run (Lwt_unix.bind socket (ADDR_INET (Unix.inet_addr_loopback, 0)));
    Lwt_unix.listen socket 8;
    let rec accepted () =
      Lwt.bind (Lwt_unix.accept socket) (fun (client, _) ->
          let input = Lwt_io.of_fd ~mode:Input client
          and output = Lwt_io.of_fd ~mode:Output client in
          let rec headers () =
            Lwt.bind (Lwt_io.read_line input) (fun line ->
                match String.trim line with "" -> Lwt.return_unit | _ -> headers ())
          in
          Lwt.async (fun () ->
              Lwt.bind (Lwt_io.read_line input) (fun first ->
                  requests := String.trim first :: !requests;
                  Lwt.bind (headers ()) (fun () ->
                      Lwt.bind
                        (Lwt_io.write output
                           "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
                        (fun () -> Lwt.bind (Lwt_io.flush output) (fun () -> Lwt_unix.close client)))));
          accepted ())
    in
    Lwt.async accepted;
    match Lwt_unix.getsockname socket with ADDR_INET (_, port) -> port | ADDR_UNIX _ -> 0
  in
  let fetching ~net =
    let workspace = fresh () in
    let replies =
      ref
        [
          fenced
            (Printf.sprintf
               "module Main exposing (main)\n\n\
                import Agent exposing (..)\n\
                import Fetch\n\n\n\
                main : Task Fetch.FetchErr ( Int, String )\n\
                main =\n\
               \    Fetch.get \"http://127.0.0.1:%d/x\"\n\
               \        |> map (\\response -> ( response.status, response.body ))\n"
               port);
          "Fetched.";
        ]
    in
    collected
      {
        ask =
          (fun ~system:_ _ ->
            match !replies with
            | reply :: rest ->
                replies := rest;
                Lwt.return (Ok reply)
            | [] -> Lwt.return (Error (`Llm (Llm.Transport "no more replies"))));
        approve = (fun _ -> Lwt.return Driver.Apply);
        handler = Handler.staged (Os.workspace (Os.granted workspace ~net)) Handler.Open;
        commit = Tools.commit (Tools.at workspace);
        calls = Lang.Calls.all;
      }
  in
  let spawned =
    let workspace = fresh () in
    Sys.mkdir (Filename.concat workspace "secrets") 0o755;
    Out_channel.with_open_text (Filename.concat workspace "secrets/key") (fun channel ->
        Out_channel.output_string channel "KEY_VALUE\n");
    let program =
      "module Main exposing (main)\n\n\
       import Agent exposing (..)\n\n\n\
       type Err\n\
      \    = Io IoErr\n\
      \    | Clash (List Change)\n\n\n\
       main : Task Err (List String)\n\
       main =\n\
      \    spawn [ Hidden \"secrets\" ]\n\
      \        (read \"secrets/key\"\n\
      \            |> onError (\\_ -> succeed \"denied\")\n\
      \            |> andThen (\\seen -> shell \"cat secrets/key; echo\" |> map (\\ran -> [ seen, ran.out ]))\n\
      \            |> andThen (\\seen -> edit { path = \"lib/a.ml\", old = \"Foo.bar\", new = \"Foo.child\" } |> map (\\_ -> seen))\n\
      \        )\n\
      \        |> mapErr Io\n\
      \        |> andThen\n\
      \            (\\child ->\n\
      \                read \"lib/a.ml\"\n\
      \                    |> mapErr Io\n\
      \                    |> andThen (\\before -> merge child |> mapErr Clash |> map (\\seen -> seen ++ [ before ]))\n\
      \            )\n\
      \        |> andThen (\\seen -> read \"secrets/key\" |> mapErr Io |> map (\\key -> seen ++ [ key ]))\n\
      \        |> andThen (\\seen -> read \"lib/a.ml\" |> mapErr Io |> map (\\after -> seen ++ [ after ]))\n\
      \        |> andThen\n\
      \            (\\seen ->\n\
      \                spawn [] (write \"lib/b.ml\" \"child\")\n\
      \                    |> mapErr Io\n\
      \                    |> andThen (\\child -> write \"lib/b.ml\" \"parent\" |> mapErr Io |> map (\\_ -> child))\n\
      \                    |> andThen\n\
      \                        (\\child ->\n\
      \                            merge child\n\
      \                                |> map (\\_ -> \"merged\")\n\
      \                                |> onError (\\clash -> succeed (\"clash \" ++ String.join \",\" (List.map .path clash)))\n\
      \                        )\n\
      \                    |> map (\\outcome -> seen ++ [ outcome ])\n\
      \            )\n"
    in
    let replies = ref [ fenced program; "Done." ] in
    let report, events =
      collected
        {
          ask =
            (fun ~system:_ _ ->
              match !replies with
              | reply :: rest ->
                  replies := rest;
                  Lwt.return (Ok reply)
              | [] -> Lwt.return (Error (`Llm (Llm.Transport "no more replies"))));
          approve = (fun _ -> Lwt.return Driver.Apply);
          handler = Handler.staged (Tools.at workspace) Handler.Contained;
          commit = Tools.commit (Tools.at workspace);
          calls = Lang.Calls.all;
        }
    in
    (workspace, report, events)
  in
  let posting person =
    let workspace = fresh () in
    let replies =
      ref
        [
          fenced
            (Printf.sprintf
               "module Main exposing (main)\n\n\
                import Agent exposing (..)\n\
                import Fetch\n\n\n\
                main : Task Fetch.FetchErr Int\n\
                main =\n\
               \    Fetch.post \"http://127.0.0.1:%d/upload\" \"the code\" |> map .status\n"
               port);
          "Posted.";
        ]
    in
    collected
      {
        ask =
          (fun ~system:_ _ ->
            match !replies with
            | reply :: rest ->
                replies := rest;
                Lwt.return (Ok reply)
            | [] -> Lwt.return (Error (`Llm (Llm.Transport "no more replies"))));
        approve = (fun _ -> Lwt.return Driver.Apply);
        handler =
          Handler.staged ~person
            (Os.workspace (Os.granted workspace ~net:[ "127.0.0.1" ]))
            Handler.Open;
        commit = Tools.commit (Tools.at workspace);
        calls = Lang.Calls.all;
      }
  in
  let failures =
    List.filter_map Fun.id
      [
        (requests := [];
         let declined = posting (fun _ -> Lwt.return Device.Declines) in
         let sent_after_decline = !requests in
         let agreed = posting (fun _ -> Lwt.return Device.Agrees) in
         let sent_after_agree = !requests in
         let ran (_, events) =
           Option.value ~default:"no result"
             (List.find_map (function Driver.Ran text -> Some text | _ -> None) events)
         in
         let report, events = agreed in
         match
           ( String.starts_with ~prefix:"main failed with:\nDeclined" (ran declined),
             sent_after_decline,
             ran agreed,
             sent_after_agree,
             collected (Driver.replayed Lang.Calls.all events),
             !requests )
         with
         | true, [], "main finished with:\n200", [ "POST /upload HTTP/1.1" ], (again, replayed), [ _ ]
           when again = report && replayed = events ->
             None
         | _ ->
             Some
               ("post: a request went out without consent, or the replay sent it again\n"
               ^ ran declined ^ "\n" ^ ran agreed ^ "\n"
               ^ String.concat "; " !requests));
        (match (fetching ~net:[ "127.0.0.1" ], fetching ~net:[]) with
        | ( ( report,
              ([ Wrote _; Performed { tool = Call { name = "fetch.get"; _ }; _ }; Ran fetched; Answered _ ]
               as recorded) ),
            (_, [ _; _; Ran refused; _ ]) ) -> (
            match
              ( fetched,
                String.starts_with ~prefix:"main failed with:\nNotGranted" refused,
                collected (Driver.replayed Lang.Calls.all recorded),
                List.map
                  (fun event ->
                    Driver.event_of_json
                      (Yojson.Safe.from_string (Yojson.Safe.to_string (Driver.event_to_json event))))
                  recorded )
            with
            | "main finished with:\n( 200, \"hello\" )", true, (again, replayed), decoded
              when again = report && replayed = recorded && decoded = List.map Result.ok recorded ->
                None
            | _ -> Some ("fetch: the result, the refusal, the replay or the log is wrong\n" ^ fetched ^ "\n" ^ refused))
        | (_, events), _ ->
            Some
              ("fetch: the session went another way\n"
              ^ String.concat "\n"
                  (List.map (fun event -> Yojson.Safe.to_string (Driver.event_to_json event)) events)));

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
         match nested with
         | ( workspace,
             { ending = Ok "Done."; rounds = [ 1 ] },
             ([
                Wrote _;
                Performed { tool = Edit _; _ };
                Performed { tool = Read "lib/a.ml"; _ };
                Filled { hole = "turn the text into the answer"; _ };
                Filled { hole = "count it"; _ };
                Staged _;
                Decided Apply;
                Committed (Ok ());
                Ran "main finished with:\n\"LET X = FOO.BAZ 1\\n18\"";
                Answered _;
              ] as recorded),
             [ _; outer; inner; _ ] ) -> (
             match
               ( contains (last outer) "text = \"let x = Foo.baz 1\\n\"",
                 contains (last inner) "The program now reads"
                 && not (contains (last inner) "#"),
                 contents workspace "lib/a.ml",
                 collected (Driver.replayed Lang.Calls.all recorded) )
             with
             | true, true, "let x = Foo.baz 1\n", (_, replayed) when replayed = recorded -> None
             | _ -> Some ("holes: the hole messages, file or replay are wrong\n" ^ last outer))
         | _, _, events, _ ->
             Some
               ("holes: the session went another way\n"
               ^ String.concat "\n"
                   (List.map
                      (fun event -> Yojson.Safe.to_string (Driver.event_to_json event))
                      events)));
        (let workspace, report, events = spawned in
         let ran =
           List.find_map (function Driver.Ran text -> Some text | _ -> None) events
           |> Option.value ~default:"no result"
         in
         match
           ( String.starts_with ~prefix:"main finished with:\n[ \"denied\", \"cat: secrets/key: " ran
             && String.ends_with
                  ~suffix:
                    "\"let x = Foo.bar 1\\n\", \"KEY_VALUE\\n\", \"let x = Foo.child 1\\n\", \"clash lib/b.ml\" ]"
                  ran,
             contents workspace "lib/a.ml",
             contents workspace "lib/b.ml",
             collected (Driver.replayed Lang.Calls.all events),
             Driver.undone events )
         with
         | true, "let x = Foo.child 1\n", "parent", (again, replayed), [ _; _ ]
           when again = report && replayed = events ->
             None
         | _ ->
             Some
               ("spawn: the child saw the hidden path, its changes leaked, the merge or the replay is wrong\n"
               ^ ran ^ "\n"
               ^ String.concat "\n"
                   (List.map (fun event -> Yojson.Safe.to_string (Driver.event_to_json event)) events)));
        (match session ~decision:Driver.Discard with
        | workspace, { ending = Error Discarded; rounds = [ 2 ] }, _, _ -> (
            match contents workspace "lib/a.ml" with
            | "let x = Foo.bar 1\n" -> None
            | _ -> Some "discard: the file changed")
        | _ -> Some "discard: the session went another way");
        (let _, report, recorded, _ = applied in
         match collected (Driver.replayed Lang.Calls.all recorded) with
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
                    calls = Lang.Calls.all;
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
         match Driver.undone recorded with
         | [ ({ path; before = Some "let x = Foo.baz 1\n"; after = Some "let x = Foo.bar 1\n" } as
              change) ]
           when String.equal (path :> string) "lib/a.ml" -> (
             let workspace = fresh () in
             Out_channel.with_open_text (Filename.concat workspace "lib/a.ml") (fun channel ->
                 Out_channel.output_string channel "let x = Foo.baz 1\n");
             match Lwt_main.run (Tools.commit (Tools.at workspace) [ change ]) with
             | Ok () when String.equal (contents workspace "lib/a.ml") "let x = Foo.bar 1\n" ->
                 None
             | _ -> Some "undo: the file was not put back")
         | _ -> Some "undo: the inverse of the session is wrong");
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
