let () =
  let sources =
    List.map
      (fun name ->
        (name, In_channel.with_open_text ("widgets/" ^ name ^ ".elm") In_channel.input_all))
      [ "Bus"; "Widget"; "AgentBoard"; "Harness" ]
  in
  let render : Value.global = { module_name = "Harness"; name = "render" } in
  let source : Value.global = { module_name = "Harness"; name = "source" } in
  let explained name = function
    | `Lang report -> Some (name ^ ": refused\n" ^ report)
    | `Undeclared ({ module_name; name = missing } : Value.global) ->
        Some (name ^ ": no " ^ module_name ^ "." ^ missing)
    | `Interp (Interp.Stuck reason) -> Some (name ^ ": stuck, " ^ reason)
    | `Interp (Interp.Crashed reason) -> Some (name ^ ": crashed, " ^ reason)
    | `Interp Interp.Budget_exhausted -> Some (name ^ ": out of budget")
  in
  let loaded () =
    Result.map (Interp.load ~budget:(Total 10_000_000))
      (Result.map_error
         (fun report -> `Lang report)
         (Lang.compile_modules Lang.Calls.pure sources ~entries:[ render; source ]))
  in
  let called program name argument =
    Result.bind (Interp.lookup program name) (function
      | Value.V_closure closure -> Interp.apply program closure argument
      | _ -> Ok (Value.V_string "not a function"))
  in
  let run name check =
    match check () with
    | Ok None -> None
    | Ok (Some failure) -> Some (name ^ ": " ^ failure)
    | Error error -> explained name error
  in
  let agent ~task ~state ~tokens =
    Printf.sprintf
      {|{"id":"%s","task":"%s","goal":"g","state":"%s","step":1,"doing":"%s step","tokens":%d}|}
      task task state task tokens
  in
  let agents =
    Value.V_json
      (Yojson.Safe.from_string
         ("["
         ^ agent ~task:"beta" ~state:"running" ~tokens:1200
         ^ ","
         ^ agent ~task:"alpha" ~state:"needs-you" ~tokens:7
         ^ "]"))
  in
  let failures =
    List.filter_map Fun.id
      [
        run "render" (fun () ->
            Result.bind (loaded ()) (fun program ->
                Result.map
                  (fun (rendered : Value.t) ->
                    let expected =
                      Yojson.Safe.from_string
                        {|{"t":"stack","direction":"column","children":[
                            {"t":"label","value":"Агенты: 2"},
                            {"t":"table","columns":["задача","состояние","токены"],"rows":[
                              [{"t":"text","tone":"normal","value":"alpha"},
                               {"t":"status","state":"needs-you","text":"alpha step"},
                               {"t":"text","tone":"normal","value":"7"}],
                              [{"t":"text","tone":"normal","value":"beta"},
                               {"t":"status","state":"running","text":"beta step"},
                               {"t":"text","tone":"normal","value":"1200"}]]}]}|}
                    in
                    match rendered with
                    | V_json json when Yojson.Safe.equal json expected -> None
                    | other -> Some ("rendered " ^ Value.to_elm other))
                  (called program render agents)));
        run "budget per call" (fun () ->
            Result.bind
              (Result.map_error
                 (fun report -> `Lang report)
                 (Lang.compile_modules Lang.Calls.pure sources ~entries:[ render; source ]))
              (fun modules ->
                let drawn budget =
                  let program = Interp.load ~budget modules in
                  let first = called program render agents in
                  let second = called program render agents in
                  (first, second, Interp.spent program)
                in
                match drawn (Total 10_000_000) with
                | Ok _, Ok _, steps -> (
                    match (drawn (Each (steps * 3 / 2)), drawn (Total (steps * 3 / 2)), drawn (Each (steps / 2))) with
                    | ( (Ok _, Ok _, again),
                        (Ok _, Error (`Interp Interp.Budget_exhausted), _),
                        (Error (`Interp Interp.Budget_exhausted), Error (`Interp Interp.Budget_exhausted), _) )
                      when again = steps ->
                        Ok None
                    | _ -> Ok (Some (Printf.sprintf "a budget of one call does not hold for each of %d steps" steps)))
                | (Error _ as failed), _, _ | _, (Error _ as failed), _ -> Result.map (fun _ -> None) failed));
        run "source" (fun () ->
            Result.bind (loaded ()) (fun program ->
                Result.map
                  (function
                    | Value.V_string "agents" -> None
                    | other -> Some ("source " ^ Value.to_elm other))
                  (called program source V_unit)));
        run "bad rows" (fun () ->
            Result.bind (loaded ()) (fun program ->
                Result.map
                  (function
                    | Value.V_json (`Assoc [ ("failed", `String _) ]) -> None
                    | other -> Some ("rendered " ^ Value.to_elm other))
                  (called program render (V_json (`Assoc [ ("agents", `Null) ])))));
        run "undeclared" (fun () ->
            Result.bind (loaded ()) (fun program ->
                match Interp.lookup program { module_name = "Bus"; name = "goals" } with
                | Error (`Undeclared _) -> Ok None
                | Ok _ -> Ok (Some "a declaration no entry reaches was kept")
                | Error (`Interp _ as error) -> Error error));
        run "missing entry" (fun () ->
            match Lang.compile_modules Lang.Calls.pure sources ~entries:[ { module_name = "Harness"; name = "view" } ] with
            | Error _ -> Ok None
            | Ok _ -> Ok (Some "an entry the modules do not expose compiled"));
        run "type error" (fun () ->
            match
              Lang.compile_modules Lang.Calls.pure
                (List.map
                   (fun (name, text) ->
                     match name with
                     | "AgentBoard" -> (name, text ^ "\n\nbroken : Int\nbroken =\n    \"text\"\n")
                     | _ -> (name, text))
                   sources)
                ~entries:[ render ]
            with
            | Error _ -> Ok None
            | Ok _ -> Ok (Some "a module with a type error compiled"));
      ]
  in
  match failures with
  | [] -> ()
  | _ :: _ ->
      prerr_endline (String.concat "\n\n" failures);
      exit 1
