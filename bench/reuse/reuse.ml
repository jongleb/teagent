let () =
  let spec = ref "" in
  let tasks = ref "bench/reuse/tasks.json" in
  let model = ref None in
  let effort = ref Llm.High in
  let phases = ref [ `Cold; `Warm ] in
  let out = ref "" in
  let only = ref [] in
  let openai = ref None in
  Arg.parse
    [
      ("--spec", Arg.Set_string spec, "FILE  GitHub's OpenAPI description, api.github.com.json");
      ("--tasks", Arg.Set_string tasks, "FILE  The tasks (default: bench/reuse/tasks.json)");
      ("--model", Arg.String (fun id -> model := Some id), "ID  The model");
      ( "--effort",
        Arg.Symbol
          ( List.map fst Llm.efforts,
            fun level -> Option.iter (fun level -> effort := level) (List.assoc_opt level Llm.efforts)
          ),
        "  How hard the model thinks (default: high)" );
      ("--openai", Arg.String (fun url -> openai := Some url), "URL  An OpenAI-compatible server");
      ("--cold", Arg.Unit (fun () -> phases := [ `Cold ]), "  Only the run without saved modules");
      ("--out", Arg.Set_string out, "FILE  Write every result as JSON");
    ]
    (fun task -> only := task :: !only)
    "reuse --spec FILE [options] [TASK...]";
  let failed reason =
    prerr_endline reason;
    exit 2
  in
  let provider =
    Result.fold ~ok:Fun.id ~error:failed (Llm.configured ~model:!model ~effort:!effort ~openai:!openai)
  in
  let listed = Yojson.Safe.from_file !tasks in
  let texts json key =
    match Yojson.Safe.Util.member key json with
    | `List items -> List.filter_map (function `String text -> Some text | _ -> None) items
    | _ -> []
  in
  let github =
    Result.fold ~ok:Fun.id
      ~error:(fun reason -> failed (!spec ^ ": " ^ reason))
      (Api.parsed ~name:"Github" ~base:None ~token:(Some "GH_TOKEN") ~only:(texts listed "operations")
         (Yojson.Safe.from_file !spec))
  in
  let chosen =
    List.filter_map
      (fun task ->
        match (Yojson.Safe.Util.member "name" task, Yojson.Safe.Util.member "task" task) with
        | `String name, `String text
          when List.is_empty !only || List.exists (String.equal name) !only ->
            Some (name, text, texts task "answer")
        | _ -> None)
      (match Yojson.Safe.Util.member "tasks" listed with `List tasks -> tasks | _ -> [])
  in
  let solved pool (name, task, answer) =
    let workspace = Filename.temp_dir ("reuse-" ^ name) "" in
    let os =
      List.fold_left
        (fun os (module_name, source) ->
          Result.fold ~ok:Fun.id ~error:(fun _ -> os)
            (Result.bind (Lang.Skill.of_source ~name:module_name source) (fun skill -> Os.learned skill os)))
        (Os.granted ~apis:[ github ] workspace ~net:[])
        pool
    in
    let tools = Os.workspace os in
    List.iter (fun (module_name, source) -> ignore (Lwt_main.run (Tools.keep tools ~name:module_name source))) pool;
    let spent = ref { Llm.input = 0; output = 0; cached = 0; written = 0 } in
    let calls = ref 0 in
    let started = Unix.gettimeofday () in
    let report =
      Lwt_main.run
        (Driver.solve
           {
             ask =
               (fun ~system history ->
                 Lwt.map
                   (Result.map (fun ({ text; usage } : Llm.reply) ->
                        incr calls;
                        spent :=
                          {
                            input = !spent.input + usage.input;
                            output = !spent.output + usage.output;
                            cached = !spent.cached + usage.cached;
                            written = !spent.written + usage.written;
                          };
                        text))
                   (Llm.answered provider ~system history));
             approve = (fun _ -> Lwt.return Driver.Apply);
             person = (fun _ -> Lwt.return Device.Declines);
             handler = Handler.staged tools Handler.Contained;
             commit = Tools.commit tools;
             keep = Tools.keep tools;
             os;
             recorded = [];
           }
           ~on:(fun _ -> Lwt.return_unit)
           (task
          ^ "\n\nUse the Github module. When a module you write would help with similar tasks \
             later, save it."))
    in
    let seconds = Unix.gettimeofday () -. started in
    let folder = Filename.concat workspace ".teagent/saved" in
    let saved =
      match Sys.readdir folder with
      | exception Sys_error _ -> []
      | names ->
          List.filter_map
            (fun file ->
              Option.map
                (fun module_name ->
                  (module_name, In_channel.with_open_text (Filename.concat folder file) In_channel.input_all))
                (Filename.chop_suffix_opt ~suffix:".elm" file))
            (List.sort String.compare (Array.to_list names))
    in
    let lowered = String.lowercase_ascii in
    let missing =
      match report.ending with
      | Error stop -> [ Driver.explained stop ]
      | Ok text ->
          List.filter
            (fun piece ->
              let piece = lowered piece and text = lowered text in
              not
                (List.exists
                   (fun at -> String.equal (String.sub text at (String.length piece)) piece)
                   (List.init (max 0 (String.length text - String.length piece + 1)) Fun.id)))
            answer
    in
    let usage = !spent in
    let cost =
      ((Float.of_int usage.input *. 4.) +. (Float.of_int usage.written *. 5.)
      +. (Float.of_int usage.cached *. 0.2) +. (Float.of_int usage.output *. 20.))
      /. 1_000_000.
    in
    (name, usage, !calls, cost, seconds, missing, saved)
  in
  let tokens (usage : Llm.usage) = usage.input + usage.output + usage.cached + usage.written in
  let row phase (name, usage, calls, cost, seconds, missing, _) =
    Printf.printf "%-5s %-13s %8d tokens %3d calls  $%.3f  %5.0f s  %s\n%!" phase name (tokens usage)
      calls cost seconds
      (match missing with [] -> "ok" | _ -> "WRONG: " ^ String.concat "; " missing)
  in
  let cold = List.map (fun task -> let result = solved [] task in row "cold" result; result) chosen in
  let pool =
    List.fold_left
      (fun pool (_, _, _, _, _, _, saved) ->
        pool
        @ List.filter (fun (module_name, _) -> not (List.mem_assoc module_name pool)) saved)
      [] cold
  in
  Printf.printf "\nsaved modules: %s\n\n%!" (String.concat ", " (List.map fst pool));
  let warm =
    match List.mem `Warm !phases with
    | false -> []
    | true -> List.map (fun task -> let result = solved pool task in row "warm" result; result) chosen
  in
  let total results =
    List.fold_left
      (fun (tokens_sum, cost_sum, seconds_sum, right) (_, usage, _, cost, seconds, missing, _) ->
        ( tokens_sum + tokens usage,
          cost_sum +. cost,
          seconds_sum +. seconds,
          right + match missing with [] -> 1 | _ -> 0 ))
      (0, 0., 0., 0) results
  in
  let summary phase results =
    let tokens_sum, cost_sum, seconds_sum, right = total results in
    Printf.printf "%-5s %d tokens, $%.2f, %.0f s, %d of %d right\n" phase tokens_sum cost_sum seconds_sum
      right (List.length results)
  in
  summary "cold" cold;
  (match warm with [] -> () | _ :: _ -> summary "warm" warm);
  match !out with
  | "" -> ()
  | file ->
      let encoded phase =
        List.map (fun (name, (usage : Llm.usage), calls, cost, seconds, missing, saved) ->
            `Assoc
              [
                ("phase", `String phase);
                ("task", `String name);
                ("input", `Int usage.input);
                ("output", `Int usage.output);
                ("cached", `Int usage.cached);
                ("written", `Int usage.written);
                ("calls", `Int calls);
                ("cost", `Float cost);
                ("seconds", `Float seconds);
                ("missing", `List (List.map (fun piece -> `String piece) missing));
                ("saved", `List (List.map (fun (module_name, _) -> `String module_name) saved));
              ])
      in
      Yojson.Safe.to_file file
        (`Assoc
          [
            ("results", `List (encoded "cold" cold @ encoded "warm" warm));
            ("pool", `Assoc (List.map (fun (module_name, source) -> (module_name, `String source)) pool));
          ])
