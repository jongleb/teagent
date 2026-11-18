open Lwt.Syntax

type agent = Main | Spawned of { id : int; parent : agent }
type touched = { read : Tools.Path.t list; changed : Tools.Path.t list }
type file = { change : Tools.change; hunks : Handler.Overlay.hunk list }
type happened =
  | Logged of Driver.event
  | Began of int
  | Merged of int
  | Proposed of file list
  | Asking of { question : string; answers : string list }

type event = {
  agent : agent;
  step : string option;
  spent : Llm.usage;
  touched : touched;
  happened : happened;
}

let solve (world : Driver.world) ~on ~cancelled task =
  let current = ref Main and count = ref 0 and step = ref None and spent = ref Llm.unused in
  let left = ref [] in
  let nothing = { read = []; changed = [] } in
  let emitted touched happened =
    if Trace_core.enabled () then
      Trace_core.message "session.event" ~data:(fun () ->
          [
            ( "agent",
              `String (match !current with Main -> "main" | Spawned { id; _ } -> "spawned " ^ string_of_int id) );
            ( "kind",
              `String
                (match happened with
                | Logged event -> (
                    match Driver.event_to_json event with `Assoc [ (kind, _) ] -> kind | _ -> "logged")
                | Began _ -> "began"
                | Merged _ -> "merged"
                | Proposed _ -> "proposed"
                | Asking _ -> "asking") );
            ("step", Option.fold ~none:`None ~some:(fun step -> `String step) !step);
            ("tokens_in", `Int !spent.input);
            ("tokens_out", `Int !spent.output);
          ]);
    on { agent = !current; step = !step; spent = !spent; touched; happened }
  in
  let listed (value : Value.t) =
    match value with
    | V_list rows ->
        List.sort_uniq String.compare
          (List.filter_map
             (function
               | Value.V_record fields -> (
                   match List.assoc_opt "path" fields with Some (V_string path) -> Some path | _ -> None)
               | _ -> None)
             rows)
    | _ -> []
  in
  let stopping call =
    match Lwt.is_sleeping cancelled with
    | false -> Lwt.fail Lwt.Canceled
    | true -> Lwt.pick [ call (); Lwt.bind (Lwt.no_cancel cancelled) (fun () -> Lwt.fail Lwt.Canceled) ]
  in
  let observed (event : Driver.event) =
    match event with
    | Performed { tool; result; staged } -> (
        let read =
          match (tool, result) with
          | Read path, Ok _ -> [ path ]
          | Grep _, Ok found -> listed found
          | _ -> []
        in
        let* () =
          emitted
            {
              read = List.filter_map (fun path -> Result.to_option (Tools.Path.of_string path)) read;
              changed = List.sort_uniq compare (List.map (fun (change : Tools.change) -> change.path) staged);
            }
            (Logged event)
        in
        match (tool, result, !current) with
        | Enter _, Ok _, _ ->
            incr count;
            let+ () = emitted nothing (Began !count) in
            current := Spawned { id = !count; parent = !current }
        | Leave, result, Spawned { id; parent } ->
            left := !left @ [ (id, Result.fold ~ok:listed ~error:(fun _ -> []) result) ];
            current := parent;
            Lwt.return_unit
        | Merge patches, Ok _, _ ->
            let files = List.sort_uniq String.compare (List.map (fun (patch : Value.patch) -> patch.file) patches) in
            Option.fold ~none:Lwt.return_unit
              ~some:(fun (id, _) ->
                left := List.remove_assoc id !left;
                emitted nothing (Merged id))
              (List.find_opt (fun (_, paths) -> List.equal String.equal paths files) !left)
        | _ -> Lwt.return_unit)
    | Ran _ ->
        current := Main;
        emitted nothing (Logged event)
    | Wrote reply ->
        let rec said = function
          | [] -> None
          | line :: _ when String.starts_with ~prefix:"```" line -> None
          | "" :: rest -> said rest
          | line :: _ -> Some line
        in
        Option.iter (fun line -> step := Some line) (said (List.map String.trim (String.split_on_char '\n' reply)));
        emitted nothing (Logged event)
    | Aimed goal | Filled { hole = goal; _ } ->
        step := Some goal;
        emitted nothing (Logged event)
    | Refused _ | Deferred _ | Exhausted _ | Staged _ | Decided _ | Held _ | Exposed _ | Committed _
    | Guessed _ | Answered _ | Saved _ | Ended _ ->
        emitted nothing (Logged event)
  in
  let watched =
    {
      world with
      ask =
        (fun ~system history ->
          Lwt.map
            (Result.map (fun (reply : Llm.reply) ->
                 spent := Llm.added !spent reply.usage;
                 reply))
            (stopping (fun () -> world.ask ~system history)));
      approve =
        (fun changes ->
          let* () =
            emitted nothing
              (Proposed (List.map (fun change -> { change; hunks = Handler.Overlay.hunks change }) changes))
          in
          stopping (fun () -> world.approve changes));
      person = (fun question -> stopping (fun () -> world.person question));
      handler =
        {
          perform =
            (fun tool sources state ->
              let* () =
                match tool with
                | Call
                    {
                      name = "person.ask";
                      argument = V_record [ ("answers", V_list answers); ("question", V_string question) ];
                    } ->
                    emitted nothing
                      (Asking
                         {
                           question;
                           answers =
                             List.filter_map (function Value.V_string answer -> Some answer | _ -> None) answers;
                         })
                | _ -> Lwt.return_unit
              in
              stopping (fun () -> world.handler.perform tool sources state));
        };
      keep = (fun ~name source -> stopping (fun () -> world.keep ~name source));
      commit =
        (fun changes ->
          match Lwt.is_sleeping cancelled with true -> world.commit changes | false -> Lwt.fail Lwt.Canceled);
    }
  in
  Lwt.catch
    (fun () -> Driver.solve watched ~on:observed task)
    (function
      | Lwt.Canceled ->
          let+ () = emitted nothing (Logged (Ended (Driver.explained Cancelled))) in
          { Driver.ending = Error Cancelled; rounds = [] }
      | other -> Lwt.reraise other)
