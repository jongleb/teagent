let () =
  let directory = ref (Sys.getcwd ()) in
  let model = ref None in
  let effort = ref Llm.High in
  let openai = ref None in
  let approval = ref `Ask in
  let shell = ref Handler.Contained in
  let mode = ref `Fresh in
  let words = ref [] in
  Arg.parse
    [
      ("-C", Arg.Set_string directory, "DIR  Work in DIR (default: the current directory)");
      ( "--model",
        Arg.String (fun id -> model := Some id),
        "ID  The model (default: claude-opus-5-5)" );
      ( "--effort",
        Arg.Symbol
          ( List.map fst Llm.efforts,
            fun level -> Option.iter (fun level -> effort := level) (List.assoc_opt level Llm.efforts)
          ),
        "  How hard an Anthropic model thinks (default: high)" );
      ( "--openai",
        Arg.String (fun url -> openai := Some url),
        "URL  Use an OpenAI-compatible server at URL, e.g. http://localhost:8080/v1" );
      ("--yes", Arg.Unit (fun () -> approval := `Always), "  Apply changes without asking");
      ( "--shell",
        Arg.Symbol
          ( List.map fst Handler.shells,
            fun shape -> Option.iter (fun shape -> shell := shape) (List.assoc_opt shape Handler.shells)
          ),
        "  contained: a sandboxed clone, no network, writes staged (default); open: the \
         workspace itself; off: never" );
      ( "--replay",
        Arg.String (fun file -> mode := `Replay file),
        "FILE  Replay a session log without the model or the disk, and check it matches" );
      ( "--resume",
        Arg.String (fun file -> mode := `Resume file),
        "FILE  Continue a session from its log: replay what it holds, then go on live" );
    ]
    (fun word -> words := word :: !words)
    "teagent [options] TASK...";
  let failed reason =
    prerr_endline reason;
    exit 2
  in
  let section title body = Lwt.return (Printf.printf "\n── %s ──\n%s\n%!" title body) in
  let printed (event : Driver.event) =
    match event with
    | Wrote reply -> section "program" reply
    | Refused report -> section "compiler" report
    | Performed { tool; _ } -> section "tool" (Yojson.Safe.to_string (Value.tool_to_json tool))
    | Deferred tool ->
        section "deferred until the changes are settled"
          (Yojson.Safe.to_string (Value.tool_to_json tool))
    | Staged diff -> section "changes" diff
    | Decided Apply -> section "decision" "apply"
    | Decided Discard -> section "decision" "discard"
    | Committed (Ok ()) -> section "commit" "written"
    | Committed (Error reason) -> section "commit" ("refused: " ^ reason)
    | Ran result -> section "result" result
    | Guessed reply -> section "guess, sent back" reply
    | Answered reply -> section "answer" reply
  in
  let loaded file =
    match In_channel.with_open_text file In_channel.input_lines with
    | exception Sys_error reason -> failed reason
    | [] -> failed (file ^ " is empty.")
    | header :: lines -> (
        match
          match Yojson.Safe.from_string header with
          | `Assoc [ ("task", `String task) ] ->
              Result.map
                (fun events -> (task, events))
                (List.fold_right
                   (fun line collected ->
                     Result.bind collected (fun rest ->
                         match Yojson.Safe.from_string line with
                         | json ->
                             Result.map (fun event -> event :: rest) (Driver.event_of_json json)
                         | exception Yojson.Json_error reason -> Error reason))
                   lines (Ok []))
          | _ -> Error "the first line does not name the task"
          | exception Yojson.Json_error reason -> Error reason
        with
        | Ok loaded -> loaded
        | Error reason -> failed (file ^ ": " ^ reason))
  in
  let live () =
    match Llm.configured ~model:!model ~effort:!effort ~openai:!openai with
    | Error reason -> failed reason
    | Ok provider ->
        let workspace = Tools.at !directory in
        {
          Driver.ask = (fun ~system history -> Llm.complete provider ~system history);
          approve =
            (fun _ ->
              match !approval with
              | `Always -> Lwt.return Driver.Apply
              | `Ask -> (
                  print_string "Apply these changes? [y/N] ";
                  flush stdout;
                  match
                    String.lowercase_ascii
                      (String.trim (Option.value ~default:"" (In_channel.input_line stdin)))
                  with
                  | "y" | "yes" -> Lwt.return Driver.Apply
                  | _ -> Lwt.return Driver.Discard));
          handler = Handler.staged workspace !shell;
          commit = Tools.commit workspace;
        }
  in
  let logged ~flags log ~skipped world task =
    Out_channel.with_open_gen flags 0o600 log (fun channel ->
        let written json =
          Out_channel.output_string channel (Yojson.Safe.to_string json ^ "\n");
          Out_channel.flush channel
        in
        let seen = ref 0 in
        let report =
          Lwt_main.run
            (Driver.solve world
               ~on:(fun event ->
                 incr seen;
                 if !seen > skipped then written (Driver.event_to_json event);
                 printed event)
               task)
        in
        Printf.printf "\ncompile rounds per program: %s\nsession log: %s\n"
          (String.concat ", " (List.map string_of_int report.rounds))
          log;
        match report.ending with
        | Ok _ -> ()
        | Error stop ->
            prerr_endline (Driver.explained stop);
            exit 1)
  in
  match !mode with
  | `Replay file -> (
      let task, recorded = loaded file in
      let replayed = ref [] in
      let _report =
        Lwt_main.run
          (Driver.solve (Driver.replayed recorded)
             ~on:(fun event ->
               replayed := event :: !replayed;
               printed event)
             task)
      in
      let rec first index recorded replayed =
        match (recorded, replayed) with
        | [], [] -> None
        | one :: recorded, other :: replayed when one = other -> first (index + 1) recorded replayed
        | one :: _, other :: _ -> Some (index, Some one, Some other)
        | one :: _, [] -> Some (index, Some one, None)
        | [], other :: _ -> Some (index, None, Some other)
      in
      let shown =
        Option.fold ~none:"(nothing)" ~some:(fun event ->
            Yojson.Safe.to_string (Driver.event_to_json event))
      in
      match first 1 recorded (List.rev !replayed) with
      | None ->
          Printf.printf "\nThe replay matches the log: %d events, no model, no disk.\n"
            (List.length recorded)
      | Some (index, logged, again) ->
          Printf.printf "\nThe replay diverges at event %d.\nlogged:   %s\nreplayed: %s\n" index
            (shown logged) (shown again);
          exit 1)
  | `Resume file ->
      let task, recorded = loaded file in
      logged ~flags:[ Open_wronly; Open_append; Open_text ] file ~skipped:(List.length recorded)
        (Driver.resumed recorded (live ()))
        task
  | `Fresh -> (
      match String.concat " " (List.rev !words) with
      | "" -> failed "Say what to do: teagent [options] TASK..."
      | task ->
          let world = live () in
          let sessions =
            List.fold_left Filename.concat (Sys.getenv "HOME") [ ".teagent"; "sessions" ]
          in
          List.iter
            (fun directory -> if not (Sys.file_exists directory) then Sys.mkdir directory 0o700)
            [ Filename.dirname sessions; sessions ];
          let log =
            Filename.concat sessions
              (Printf.sprintf "%04d.jsonl" (Array.length (Sys.readdir sessions) + 1))
          in
          Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl; Open_text ] 0o600 log
            (fun channel ->
              Out_channel.output_string channel
                (Yojson.Safe.to_string (`Assoc [ ("task", `String task) ]) ^ "\n"));
          logged ~flags:[ Open_wronly; Open_append; Open_text ] log ~skipped:0 world task)
