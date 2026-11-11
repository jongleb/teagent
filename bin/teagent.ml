let () =
  let directory = ref (Sys.getcwd ()) in
  let model = ref None in
  let effort = ref Llm.High in
  let openai = ref None in
  let approval = ref `Auto in
  let shell = ref Handler.Contained in
  let mode = ref `Fresh in
  let words = ref [] in
  let net = ref [] in
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
      ("--ask", Arg.Unit (fun () -> approval := `Ask), "  Ask before writing changes");
      ("--dry-run", Arg.Unit (fun () -> approval := `Dry), "  Show the changes, write nothing");
      ( "--shell",
        Arg.Symbol
          ( List.map fst Handler.shells,
            fun shape -> Option.iter (fun shape -> shell := shape) (List.assoc_opt shape Handler.shells)
          ),
        "  contained: a sandboxed clone, no network, writes staged (default); open: the \
         workspace itself; off: never" );
      ( "--undo",
        Arg.String (fun file -> mode := `Undo file),
        "FILE  Put back every file a session changed, unless you changed it since" );
      ( "--replay",
        Arg.String (fun file -> mode := `Replay file),
        "FILE  Replay a session log without the model or the disk, and check it matches" );
      ( "--resume",
        Arg.String (fun file -> mode := `Resume file),
        "FILE  Continue a session from its log: replay what it holds, then go on live" );
      ( "--exec",
        Arg.String (fun file -> mode := `Exec file),
        "FILE  Run a Dartea program you wrote, with no model" );
      ( "--net",
        Arg.String (fun host -> net := String.lowercase_ascii host :: !net),
        "HOST  Let contained commands reach HOST, or every name under it as *.HOST; repeat it" );
      ( "--mcp",
        Arg.Unit (fun () -> mode := `Mcp),
        "  Serve bash, read, write, edit, grep, run and fill to another agent over MCP (stdio)" );
    ]
    (fun word -> words := word :: !words)
    "teagent [options] TASK...";
  let failed reason =
    prerr_endline reason;
    exit 2
  in
  let profiled () =
    let file = List.fold_left Filename.concat !directory [ ".teagent"; "profile.json" ] in
    let granted =
      let folder = List.fold_left Filename.concat !directory [ ".teagent"; "skills" ] in
      Os.taught
        (match Sys.readdir folder with
        | exception Sys_error _ -> []
        | names ->
            List.filter_map
              (fun name ->
                Option.map
                  (fun skill ->
                    let file = Filename.concat folder name in
                    Result.fold ~ok:Fun.id
                      ~error:(fun reason -> failed (file ^ ": " ^ reason))
                      (Lang.Skill.of_source ~name:skill
                         (In_channel.with_open_text file In_channel.input_all)))
                  (Filename.chop_suffix_opt ~suffix:".elm" name))
              (List.sort String.compare (Array.to_list names)))
        (Os.granted !directory ~net:(List.rev !net))
    in
    match Sys.file_exists file with
    | false -> granted
    | true ->
        Result.fold ~ok:Fun.id
          ~error:(fun reason -> failed (file ^ ": " ^ reason))
          (match Yojson.Safe.from_file file with
          | json -> Os.narrowed json granted
          | exception Yojson.Json_error reason -> Error reason)
  in
  let section title body = Lwt.return (Printf.printf "\n── %s ──\n%s\n%!" title body) in
  let printed (event : Driver.event) =
    match event with
    | Wrote reply -> section "program" reply
    | Refused report -> section "compiler" report
    | Performed { tool; result; _ } ->
        let shown = Value.to_elm (Result.fold ~ok:Fun.id ~error:Fun.id result) in
        section
          ((match Handler.class_of tool with
           | Pure -> "pure "
           | Staged -> "staged "
           | Contained -> "contained "
           | Irreversible _ -> "irreversible ")
          ^ Yojson.Safe.to_string (Value.tool_to_json tool))
          (if String.length shown <= 2_000 then shown
           else String.sub shown 0 2_000 ^ "… (cut)")
    | Deferred tool ->
        section "deferred until the changes are settled"
          (Yojson.Safe.to_string (Value.tool_to_json tool))
    | Exhausted tool ->
        section "stopped: no tool calls left in the budget" (Yojson.Safe.to_string (Value.tool_to_json tool))
    | Staged diff -> section "changes" diff
    | Decided Apply -> section "decision" "apply"
    | Decided Discard -> section "decision" "discard"
    | Committed (Ok ()) -> section "commit" "written"
    | Committed (Error reason) -> section "commit" ("refused: " ^ reason)
    | Ran result -> section "result" result
    | Guessed reply -> section "guess, sent back" reply
    | Answered reply -> section "answer" reply
    | Filled { hole; reply } -> section ("hole " ^ Value.to_elm (V_string hole)) reply
  in
  let loaded file =
    match In_channel.with_open_text file In_channel.input_lines with
    | exception Sys_error reason -> failed reason
    | [] -> failed (file ^ " is empty.")
    | header :: lines -> (
        match
          match Yojson.Safe.from_string header with
          | `Assoc fields -> (
              match
                ( List.assoc_opt "task" fields,
                  List.assoc_opt "directory" fields,
                  List.assoc_opt "abi" fields,
                  List.assoc_opt "image" fields )
              with
              | Some (`String task), place, Some (`Int abi), Some (`String image) when abi = Os.abi ->
                  Result.map
                    (fun events ->
                      ( task,
                        (match place with Some (`String place) -> Some place | _ -> None),
                        image,
                        events ))
                    (List.fold_right
                       (fun line collected ->
                         Result.bind collected (fun rest ->
                             match Yojson.Safe.from_string line with
                             | json ->
                                 Result.map (fun event -> event :: rest)
                                   (Driver.event_of_json json)
                             | exception Yojson.Json_error reason -> Error reason))
                       lines (Ok []))
              | Some (`String _), _, Some (`Int abi), Some (`String _) ->
                  Error
                    (Printf.sprintf "the log speaks ABI %d, and this teagent speaks ABI %d" abi Os.abi)
              | Some (`String _), _, _, _ ->
                  Error "the log was written before logs named their ABI and image"
              | _ -> Error "the first line does not name the task")
          | _ -> Error "the first line does not name the task"
          | exception Yojson.Json_error reason -> Error reason
        with
        | Ok loaded -> loaded
        | Error reason -> failed (file ^ ": " ^ reason))
  in
  let approved _ =
    match !approval with
    | `Auto -> Lwt.return Driver.Apply
    | `Dry -> Lwt.return Driver.Discard
    | `Ask -> (
        print_string "Apply these changes? [y/N] ";
        flush stdout;
        match
          String.lowercase_ascii
            (String.trim (Option.value ~default:"" (In_channel.input_line stdin)))
        with
        | "y" | "yes" -> Lwt.return Driver.Apply
        | _ -> Lwt.return Driver.Discard)
  in
  let person what =
    match !approval with
    | `Auto | `Dry -> Lwt.return Device.Declines
    | `Ask -> (
        Printf.printf "\nThe program wants to %s\nThis cannot be taken back. Allow it? [y/N] " what;
        flush stdout;
        match
          String.lowercase_ascii
            (String.trim (Option.value ~default:"" (In_channel.input_line stdin)))
        with
        | "y" | "yes" -> Lwt.return Device.Agrees
        | _ -> Lwt.return Device.Declines)
  in
  let profiled_as image =
    let os = profiled () in
    match String.equal (Os.image os) image with
    | true -> os
    | false ->
        failed
          ("The log was made on image " ^ image ^ ", and this OS is image " ^ Os.image os
         ^ ".\nUse the same profile, skills and --net hosts as the session did.")
  in
  let live os =
    match Llm.configured ~model:!model ~effort:!effort ~openai:!openai with
    | Error reason -> failed reason
    | Ok provider ->
        {
          Driver.ask = (fun ~system history -> Llm.complete provider ~system history);
          approve = approved;
          person;
          handler = Handler.staged (Os.workspace os) !shell;
          boot = (Os.view os).boot;
          commit = Tools.commit (Os.workspace os);
          calls = Os.table os;
          recorded = [];
        }
  in
  let logged log ~skipped world task =
    Out_channel.with_open_gen [ Open_wronly; Open_append; Open_text ] 0o600 log (fun channel ->
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
        report)
  in
  let started task os =
    let sessions = List.fold_left Filename.concat (Sys.getenv "HOME") [ ".teagent"; "sessions" ] in
    List.iter
      (fun directory -> if not (Sys.file_exists directory) then Sys.mkdir directory 0o700)
      [ Filename.dirname sessions; sessions ];
    let log =
      Filename.concat sessions (Printf.sprintf "%04d.jsonl" (Array.length (Sys.readdir sessions) + 1))
    in
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl; Open_text ] 0o600 log
      (fun channel ->
        Out_channel.output_string channel
          (Yojson.Safe.to_string
             (`Assoc
                [
                  ("task", `String task);
                  ("directory", `String !directory);
                  ("abi", `Int Os.abi);
                  ("image", `String (Os.image os));
                ])
          ^ "\n"));
    log
  in
  let finished (report : Driver.report) =
    match report.ending with
    | Ok _ -> ()
    | Error Discarded when !approval = `Dry ->
        print_endline "\nNothing was written: this was a dry run."
    | Error stop ->
        prerr_endline (Driver.explained stop);
        exit 1
  in
  match !mode with
  | `Mcp ->
      let os = profiled () in
      let log = started "MCP session" os in
      prerr_endline ("teagent MCP server in " ^ !directory ^ ", logging to " ^ log);
      Out_channel.with_open_gen [ Open_wronly; Open_append; Open_text ] 0o600 log (fun channel ->
          let program =
            Mcp.start os !shell ~on:(fun event ->
                Out_channel.output_string channel
                  (Yojson.Safe.to_string (Driver.event_to_json event) ^ "\n");
                Out_channel.flush channel;
                Lwt.return_unit)
          in
          let rec served () =
            match In_channel.input_line stdin with
            | None -> ()
            | Some "" -> served ()
            | Some line ->
                let answer =
                  match Yojson.Safe.from_string line with
                  | json -> Lwt_main.run (Mcp.handled program json)
                  | exception Yojson.Json_error _ ->
                      Some
                        (`Assoc
                          [
                            ("jsonrpc", `String "2.0");
                            ("id", `Null);
                            ("error", `Assoc [ ("code", `Int (-32700)); ("message", `String "Parse error") ]);
                          ])
                in
                Option.iter
                  (fun answer ->
                    print_string (Yojson.Safe.to_string answer ^ "\n");
                    flush stdout)
                  answer;
                served ()
          in
          served ())
  | `Undo file -> (
      let _, place, _, recorded = loaded file in
      let workspace = Option.value ~default:!directory place in
      match Driver.undone recorded with
      | [] -> print_endline "The session changed nothing, so there is nothing to undo."
      | changes -> (
          match Lwt_main.run (Tools.commit (Tools.at workspace) changes) with
          | Ok () ->
              Printf.printf "Put back %d file(s) in %s:\n%s\n" (List.length changes) workspace
                (String.concat "\n"
                   (List.map
                      (fun (change : Tools.change) ->
                        (match change.after with Some _ -> "  restored " | None -> "  removed ")
                        ^ (change.path :> string))
                      changes))
          | Error (`Tools (Not_found reason | Denied reason | Conflict reason)) ->
              prerr_endline
                ("Nothing was undone, so none of your own edits are lost. " ^ reason
               ^ "\nThese files changed after the session; undo them by hand, or keep them.");
              exit 1))
  | `Replay file -> (
      let task, _, image, recorded = loaded file in
      let replayed = ref [] and os = profiled_as image in
      let _report =
        Lwt_main.run
          (Driver.solve (Driver.replayed (Os.table os) (Os.view os).boot recorded)
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
      let task, place, image, recorded = loaded file in
      Option.iter (fun place -> directory := place) place;
      finished
        (logged file ~skipped:(List.length recorded) { (live (profiled_as image)) with recorded } task)
  | `Exec file -> (
      let source =
        match In_channel.with_open_text file In_channel.input_all with
        | exception Sys_error reason -> failed reason
        | source -> source
      in
      let os = profiled () in
      match Lang.compile (Os.table os) source with
      | Error report ->
          print_endline report;
          exit 1
      | Ok _ ->
          let workspace = Os.workspace os in
          let replies = ref [ "```elm\n" ^ source ^ "```" ] in
          let task = "Run the program in " ^ file in
          finished
            (logged (started task os) ~skipped:0
               {
                 ask =
                   (fun ~system:_ _ ->
                     match !replies with
                     | reply :: rest ->
                         replies := rest;
                         Lwt.return (Ok reply)
                     | [] -> Lwt.return (Ok "Done."));
                 approve = approved;
                 person;
                 handler = Handler.staged workspace !shell;
                 boot = (Os.view os).boot;
                 commit = Tools.commit workspace;
                 calls = Os.table os;
                 recorded = [];
               }
               task))
  | `Fresh -> (
      match String.concat " " (List.rev !words) with
      | "" -> failed "Say what to do: teagent [options] TASK..."
      | task ->
          let os = profiled () in
          finished (logged (started task os) ~skipped:0 (live os) task))
