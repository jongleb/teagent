let () =
  let workspace = Filename.temp_dir "teagent" "" in
  Out_channel.with_open_text (Filename.concat workspace "a.txt") (fun channel ->
      Out_channel.output_string channel "hello\n");
  let program =
    "module Main exposing (main)\n\n\
     import Agent exposing (..)\n\n\n\
     main : Task IoErr String\n\
     main =\n\
    \    read \"a.txt\"\n\
    \        |> andThen\n\
    \            (\\text ->\n\
    \                spawn [] (write \"b.txt\" text)\n\
    \                    |> andThen (\\child -> merge child |> mapErr (\\_ -> NotFound \"b.txt\"))\n\
    \                    |> map (\\_ -> text)\n\
    \            )\n"
  in
  let usage = { Llm.input = 10; output = 2; cached = 0; written = 0 } in
  let world ask =
    {
      Driver.ask;
      approve = (fun _ -> Lwt.return Driver.Apply);
      person = (fun _ -> Lwt.return Device.Declines);
      handler = Handler.staged (Tools.at workspace) Handler.Open;
      commit = Tools.commit (Tools.at workspace);
      keep = Tools.keep (Tools.at workspace);
      os = Os.granted workspace ~net:[];
      recorded = [];
    }
  in
  let solved world ~cancelled =
    let events = ref [] in
    let report =
      Lwt_main.run
        (Session.solve world ~cancelled
           ~on:(fun event ->
             events := event :: !events;
             Lwt.return_unit)
           "Copy a.txt to b.txt in a child.")
    in
    (report, List.rev !events)
  in
  let replies = ref [ "Copying a in a child.\n\n```elm\n" ^ program ^ "```\n"; "Copied." ] in
  let scripted =
    world (fun ~system:_ _ ->
        match !replies with
        | text :: rest ->
            replies := rest;
            Lwt.return (Ok { Llm.text; usage })
        | [] -> Lwt.return (Error (`Llm (Llm.Transport "no more replies"))))
  in
  let report, events = solved scripted ~cancelled:(fst (Lwt.wait ())) in
  let rec named : Session.agent -> string = function
    | Main -> "main"
    | Spawned { id; parent } -> named parent ^ "/" ^ string_of_int id
  in
  let paths = List.map (fun (path : Tools.Path.t) -> (path :> string)) in
  let shown =
    List.filter_map
      (fun ({ agent; step; spent; touched; happened } : Session.event) ->
        let tail =
          Printf.sprintf "%s %s %d read=%s changed=%s" (named agent) (Option.value ~default:"-" step) spent.input
            (String.concat "," (paths touched.read))
            (String.concat "," (paths touched.changed))
        in
        match happened with
        | Logged (Performed { tool = Read _; _ }) -> Some ("read " ^ tail)
        | Logged (Performed { tool = Write _; _ }) -> Some ("write " ^ tail)
        | Logged (Performed { tool = Leave; _ }) -> Some ("leave " ^ tail)
        | Logged (Performed { tool = Merge _; _ }) -> Some ("merge " ^ tail)
        | Logged (Answered _) -> Some ("answered " ^ tail)
        | Began id -> Some (Printf.sprintf "began %d %s" id tail)
        | Merged id -> Some (Printf.sprintf "merged %d %s" id tail)
        | Proposed files ->
            Some
              (String.concat ";"
                 (List.map
                    (fun ({ change; hunks } : Session.file) ->
                      (change.path :> string)
                      ^ String.concat ""
                          (List.concat_map
                             (fun ({ lines; _ } : Handler.Overlay.hunk) ->
                               List.map
                                 (function
                                   | Handler.Overlay.Added text -> " +" ^ text
                                   | Removed text -> " -" ^ text
                                   | Kept text -> " " ^ text)
                                 lines)
                             hunks))
                    files)
              ^ " " ^ tail)
        | Logged _ -> None)
      events
  in
  let expected =
    [
      "read main Copying a in a child. 10 read=a.txt changed=";
      "began 1 main Copying a in a child. 10 read= changed=";
      "write main/1 Copying a in a child. 10 read= changed=b.txt";
      "leave main/1 Copying a in a child. 10 read= changed=";
      "merge main Copying a in a child. 10 read= changed=b.txt";
      "merged 1 main Copying a in a child. 10 read= changed=";
      "b.txt +hello main Copying a in a child. 10 read= changed=";
      "answered main Copying a in a child. 20 read= changed=";
    ]
  in
  let failures =
    List.filter_map Fun.id
      [
        (match (report.ending, shown) with
        | Ok "Copied.", shown when List.equal String.equal shown expected -> None
        | _ -> Some ("session: the events went\n" ^ String.concat "\n" shown));
        (let stop, cancel = Lwt.wait () in
         let silent = world (fun ~system:_ _ -> Lwt.wakeup_later cancel (); fst (Lwt.wait ())) in
         match solved silent ~cancelled:stop with
         | { ending = Error Cancelled; _ }, [ { happened = Logged (Ended "Stopped from outside."); _ } ] -> None
         | _ -> Some "session: a cancelled session did not end at once");
      ]
  in
  List.iter prerr_endline failures;
  match failures with [] -> print_endline "session: ok" | _ :: _ -> exit 1
