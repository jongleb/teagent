let () =
  let root = ref "." in
  let model = ref None in
  let effort = ref Llm.High in
  let openai = ref None in
  let source = ref `Model in
  let only = ref [] in
  let loud = ref `Quiet in
  let shell = ref Handler.Contained in
  Arg.parse
    [
      ("--root", Arg.Set_string root, "DIR  The bench directory (default: .)");
      ( "--reference",
        Arg.Unit (fun () -> source := `Reference),
        "  Run the reference programs instead of a model" );
      ("--model", Arg.String (fun id -> model := Some id), "ID  The model");
      ( "--effort",
        Arg.Symbol
          ( List.map fst Llm.efforts,
            fun level -> Option.iter (fun level -> effort := level) (List.assoc_opt level Llm.efforts)
          ),
        "  How hard an Anthropic model thinks (default: high)" );
      ( "--openai",
        Arg.String (fun url -> openai := Some url),
        "URL  Use an OpenAI-compatible server at URL" );
      ("--verbose", Arg.Unit (fun () -> loud := `Loud), "  Print every program and result");
      ( "--shell",
        Arg.Symbol
          ( List.map fst Handler.shells,
            fun mode -> Option.iter (fun mode -> shell := mode) (List.assoc_opt mode Handler.shells)
          ),
        "  How the model's shell commands run (default: contained)" );
    ]
    (fun task -> only := task :: !only)
    "bench [options] [TASK...]";
  let rec copied source target =
    match Sys.is_directory source with
    | true ->
        if not (Sys.file_exists target) then Sys.mkdir target 0o755;
        Array.iter
          (fun name -> copied (Filename.concat source name) (Filename.concat target name))
          (Sys.readdir source)
    | false ->
        Out_channel.with_open_bin target (fun channel ->
            Out_channel.output_string channel
              (In_channel.with_open_bin source In_channel.input_all))
  in
  let rec removed path =
    match Sys.is_directory path with
    | true ->
        Array.iter (fun name -> removed (Filename.concat path name)) (Sys.readdir path);
        Sys.rmdir path
    | false -> Sys.remove path
  in
  let rec files directory =
    List.concat_map
      (fun name ->
        let path = Filename.concat directory name in
        match Sys.is_directory path with
        | true -> List.map (Filename.concat name) (files path)
        | false -> [ name ])
      (List.sort String.compare (Array.to_list (Sys.readdir directory)))
  in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let trailing text =
    let rec last at =
      if at > 0 && String.contains " \n\t\r" text.[at - 1] then last (at - 1) else at
    in
    String.sub text 0 (last (String.length text))
  in
  let lowered = String.lowercase_ascii in
  let contains text piece =
    let rec at index =
      index + String.length piece <= String.length text
      && (String.equal (String.sub text index (String.length piece)) piece || at (index + 1))
    in
    at 0
  in
  let tasks_directory = Filename.concat !root "tasks" in
  let names =
    List.filter
      (fun name ->
        match !only with [] -> true | chosen -> List.mem name chosen)
      (List.sort String.compare (Array.to_list (Sys.readdir tasks_directory)))
  in
  let attempted =
    match (!source, Llm.configured ~model:!model ~effort:!effort ~openai:!openai) with
    | `Reference, _ -> Ok `Reference
    | `Model, Ok provider -> Ok (`Model provider)
    | `Model, Error reason -> Error reason
  in
  match attempted with
  | Error reason ->
      prerr_endline reason;
      exit 2
  | Ok attempt ->
      let results =
        List.map
          (fun name ->
            let task = Filename.concat tasks_directory name in
            let workspace = Filename.temp_dir ("teagent-" ^ name) "" in
            copied (Filename.concat task "workspace") workspace;
            let answer, rounds =
              match attempt with
              | `Reference -> (
                  match
                    Lang.compile Lang.Calls.all (read (Filename.concat !root ("programs/" ^ name ^ ".elm")))
                  with
                  | Error report -> (Error ("the reference does not compile:\n" ^ report), [])
                  | Ok modules -> (
                      let program = Interp.load ~budget:10_000_000 modules in
                      match Interp.main program with
                      | Error (`Interp _) -> (Error "the reference does not start", [ 1 ])
                      | Ok started -> (
                          match
                            Lwt_main.run
                              (Handler.interpret (Handler.run (Tools.at workspace)) program ()
                                 started)
                          with
                          | Finished (Ok value), () -> (Ok (Value.to_elm value), [ 1 ])
                          | Finished (Error (`Failed value)), () ->
                              (Error ("the reference failed with " ^ Value.to_elm value), [ 1 ])
                          | Finished (Error (`Interp _)), () ->
                              (Error "the reference crashed", [ 1 ])
                          | Stopped _, () -> (Error "the reference stopped", [ 1 ])
                          | Reached _, () -> (Error "the reference reached a hole", [ 1 ]))))
              | `Model provider ->
                  let report =
                    Lwt_main.run
                      (Driver.solve
                         {
                           ask = (fun ~system history -> Llm.complete provider ~system history);
                           approve = (fun _ -> Lwt.return Driver.Apply);
                           handler = Handler.staged (Tools.at workspace) !shell;
                           commit = Tools.commit (Tools.at workspace);
                           calls = Lang.Calls.all;
                         }
                         ~on:(fun event ->
                           match (!loud, event) with
                           | `Quiet, _ -> Lwt.return_unit
                           | `Loud, (Wrote text | Refused text | Staged text | Ran text | Guessed text | Answered text
                                     | Filled { reply = text; _ })
                             ->
                               Lwt.return (Printf.printf "%s\n%s\n\n%!" name text)
                           | `Loud, (Performed _ | Deferred _ | Decided _ | Committed _) ->
                               Lwt.return_unit)
                         (read (Filename.concat task "task.md")))
                  in
                  (Result.map_error Driver.explained report.ending, report.rounds)
            in
            let expected = Filename.concat task "expected" in
            let wrong_files =
              match Sys.file_exists expected with
              | false -> []
              | true ->
                  List.filter
                    (fun path ->
                      let produced = Filename.concat workspace path in
                      not
                        (Sys.file_exists produced
                        && String.equal
                             (trailing (read produced))
                             (trailing (read (Filename.concat expected path)))))
                    (files expected)
            in
            let missing =
              match (Sys.file_exists (Filename.concat task "answer.txt"), answer) with
              | false, _ | _, Error _ -> []
              | true, Ok text ->
                  List.filter
                    (fun piece -> not (contains (lowered text) (lowered piece)))
                    (List.filter
                       (fun line -> not (String.equal line ""))
                       (String.split_on_char '\n' (read (Filename.concat task "answer.txt"))))
            in
            removed workspace;
            let verdict =
              match (answer, wrong_files, missing) with
              | Ok _, [], [] -> Ok ()
              | Error reason, _, _ -> Error reason
              | Ok _, _ :: _, _ -> Error ("wrong files: " ^ String.concat ", " wrong_files)
              | Ok _, [], _ :: _ -> Error ("the answer lacks: " ^ String.concat ", " missing)
            in
            Printf.printf "%-22s %-5s rounds %-8s %s\n%!" name
              (match verdict with Ok () -> "ok" | Error _ -> "FAIL")
              (match rounds with [] -> "-" | _ -> String.concat "," (List.map string_of_int rounds))
              (match verdict with Ok () -> "" | Error reason -> reason);
            (verdict, rounds))
          names
      in
      let passed = List.length (List.filter (fun (verdict, _) -> Result.is_ok verdict) results) in
      let first =
        List.sort Int.compare
          (List.map (fun (_, rounds) -> match rounds with first :: _ -> first | [] -> 5) results)
      in
      Printf.printf "\npassed %d of %d; median compile rounds of the first program: %s\n" passed
        (List.length results)
        (match first with
        | [] -> "-"
        | _ -> string_of_int (List.nth first (List.length first / 2)));
      match passed = List.length results with true -> () | false -> exit 1
