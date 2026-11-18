type Trace_core.span += Recorded of int

let () =
  let spans = Hashtbl.create 16 and seen = ref [] and count = ref 0 in
  let callbacks =
    Trace_core.Collector.Callbacks.make
      ~enter_span:(fun () ~__FUNCTION__:_ ~__FILE__:_ ~__LINE__:_ ~level:_ ~params:_ ~data ~parent:_ name ->
        incr count;
        Hashtbl.replace spans !count (name, data);
        Recorded !count)
      ~exit_span:(fun () span ->
        match span with
        | Recorded id ->
            Option.iter (fun (name, data) -> seen := (`Span, name, data) :: !seen) (Hashtbl.find_opt spans id)
        | _ -> ())
      ~add_data_to_span:(fun () span more ->
        match span with
        | Recorded id ->
            Option.iter
              (fun (name, data) -> Hashtbl.replace spans id (name, data @ more))
              (Hashtbl.find_opt spans id)
        | _ -> ())
      ~message:(fun () ~level:_ ~params:_ ~data ~span:_ name -> seen := (`Message, name, data) :: !seen)
      ~metric:(fun () ~level:_ ~params:_ ~data:_ name metric ->
        match metric with
        | Trace_core.Core_ext.Metric_int value -> seen := (`Metric, name, [ ("value", `Int value) ]) :: !seen
        | _ -> ())
      ()
  in
  Trace_core.setup_collector (C_some ((), callbacks));
  let workspace = Filename.temp_dir "teagent" "" in
  Out_channel.with_open_text (Filename.concat workspace "a.txt") (fun channel ->
      Out_channel.output_string channel "hello\n");
  let replies =
    ref
      [
        "Reading.\n\n```elm\nmodule Main exposing (main)\n\nimport Agent exposing (..)\n\n\nmain : Task IoErr String\nmain =\n    read \"a.txt\"\n```\n";
        "Read.";
      ]
  in
  let world : Driver.world =
    {
      ask =
        (fun ~system:_ _ ->
          match !replies with
          | text :: rest ->
              replies := rest;
              Lwt.return (Ok { Llm.text; usage = { input = 10; output = 2; cached = 0; written = 0 } })
          | [] -> Lwt.return (Error (`Llm (Llm.Transport "no more replies"))));
      approve = (fun _ -> Lwt.return Driver.Apply);
      person = (fun _ -> Lwt.return Device.Declines);
      handler = Handler.staged (Tools.at workspace) Handler.Open;
      commit = Tools.commit (Tools.at workspace);
      keep = Tools.keep (Tools.at workspace);
      os = Os.granted workspace ~net:[];
      recorded = [];
    }
  in
  ignore
    (Lwt_main.run (Session.solve world ~cancelled:(fst (Lwt.wait ())) ~on:(fun _ -> Lwt.return_unit) "Read a.txt."));
  let denying =
    Handler.booted Handler.Boot.standard ~class_of:(Handler.class_of [])
      ~rules:(fun _ _ -> Handler.Deny "not here")
      ~person:(fun _ -> Lwt.return Device.Declines)
      ~journal:Fun.id (Handler.run (Tools.at workspace))
  in
  ignore (Lwt_main.run (Handler.interpret denying (Interp.load ~budget:(Each 1000) []) () (Tool (Read "a.txt"))));
  let counter = In_channel.with_open_text "live/Counter.elm" In_channel.input_all in
  let main : Value.global = { module_name = "Counter"; name = "main" } in
  (match Lang.compile_modules Lang.Calls.pure [ ("Counter", counter) ] ~entries:[ main ] with
  | Error _ -> ()
  | Ok modules ->
      ignore
        (Result.bind (Live.started (Interp.load ~budget:(Each 1_000_000) modules) main) (fun (live, _) ->
             Live.drawn live)));
  Trace_core.shutdown ();
  let found kind name wanted =
    List.exists
      (fun (seen_kind, seen_name, data) ->
        seen_kind = kind && String.equal seen_name name && wanted data)
      !seen
  in
  let has pairs data = List.for_all (fun pair -> List.mem pair data) pairs in
  let stepped data = match List.assoc_opt "steps" data with Some (`Int steps) -> steps > 0 | _ -> false in
  let failures =
    List.filter_map
      (fun (what, held) -> match held with true -> None | false -> Some ("trace: no " ^ what))
      [
        ("interp.entry of Main.main", found `Span "interp.entry" (has [ ("global", `String "Main.main") ]));
        ( "handler.call read, pure, ok",
          found `Span "handler.call read" (has [ ("class", `String "pure"); ("outcome", `String "ok") ]) );
        ( "handler.call read, failed",
          found `Span "handler.call read" (has [ ("class", `String "pure"); ("outcome", `String "failed") ]) );
        ("handler.denied", found `Message "handler.denied" (has [ ("reason", `String "not here") ]));
        ("handler.denials counter", found `Metric "handler.denials" (has [ ("value", `Int 1) ]));
        ("handler.calls.pure counter", found `Metric "handler.calls.pure" (has []));
        ("interp.steps counter", found `Metric "interp.steps" (has []));
        ("session.event performed", found `Message "session.event" (has [ ("kind", `String "performed") ]));
        ( "session.event answered",
          found `Message "session.event" (has [ ("kind", `String "answered"); ("tokens_in", `Int 20) ]) );
        ("live.init with steps", found `Span "live.init" stepped);
        ("live.view with steps", found `Span "live.view" stepped);
      ]
  in
  List.iter prerr_endline failures;
  match failures with [] -> print_endline "trace: ok" | _ :: _ -> exit 1
