let () =
  let workspace = Filename.temp_dir "teagent" "" in
  let placed path content =
    let file = Filename.concat workspace path in
    if not (Sys.file_exists (Filename.dirname file)) then Sys.mkdir (Filename.dirname file) 0o755;
    Out_channel.with_open_text file (fun channel -> Out_channel.output_string channel content)
  in
  let contents path =
    In_channel.with_open_text (Filename.concat workspace path) In_channel.input_all
  in
  placed "lib/a.ml" "let x = Foo.bar 1\n";
  placed "lib/c.ml" "let z = 3\n";
  let events = ref [] in
  let program =
    Mcp.start (Os.granted workspace ~net:[]) Handler.Contained ~on:(fun event ->
        events := event :: !events;
        Lwt.return_unit)
  in
  let call id name arguments =
    Lwt_main.run
      (Mcp.handled program
         (`Assoc
           [
             ("jsonrpc", `String "2.0");
             ("id", `Int id);
             ("method", `String "tools/call");
             ( "params",
               `Assoc
                 [
                   ("name", `String name);
                   ("arguments", `Assoc (List.map (fun (key, value) -> (key, `String value)) arguments));
                 ] );
           ]))
  in
  let outcome = function
    | Some
        (`Assoc
          [
            _;
            _;
            ( "result",
              `Assoc
                [ ("content", `List [ `Assoc [ _; ("text", `String text) ] ]); ("isError", `Bool failed) ] );
          ]) ->
        Some (text, failed)
    | _ -> None
  in
  let edited =
    outcome
      (call 1 "edit" [ ("path", "lib/a.ml"); ("old_string", "Foo.bar"); ("new_string", "Foo.baz") ])
  in
  let ran = outcome (call 2 "bash" [ ("command", "cat lib/a.ml; echo built > out.txt; rm lib/c.ml") ]) in
  let escaped = outcome (call 3 "write" [ ("path", "../escape.txt"); ("content", "x") ]) in
  let listed =
    Lwt_main.run
      (Mcp.handled program
         (`Assoc [ ("jsonrpc", `String "2.0"); ("id", `Int 4); ("method", `String "tools/list") ]))
  in
  let after_session =
    ( contents "lib/a.ml",
      Sys.file_exists (Filename.concat workspace "out.txt"),
      Sys.file_exists (Filename.concat workspace "lib/c.ml") )
  in
  let undone = Lwt_main.run (Tools.commit (Tools.at workspace) (Driver.undone (List.rev !events))) in
  let failures =
    List.filter_map Fun.id
      [
        (match edited with
        | Some (text, false) when String.ends_with ~suffix:"Applied to the project: lib/a.ml" text -> None
        | _ -> Some "edit: not applied");
        (match ran with
        | Some (text, false) when String.starts_with ~prefix:"let x = Foo.baz 1" text -> None
        | _ -> Some "bash: did not see the edit or failed");
        (match escaped with Some (_, true) -> None | _ -> Some "write: a path outside was accepted");
        (match listed with
        | Some (`Assoc [ _; _; ("result", `Assoc [ ("tools", `List tools) ]) ]) when List.length tools = 5 ->
            None
        | _ -> Some "tools/list: wrong tools");
        (match after_session with
        | "let x = Foo.baz 1\n", true, false -> None
        | _ -> Some "session: the disk is not what the tools did");
        (match
           ( undone,
             contents "lib/a.ml",
             Sys.file_exists (Filename.concat workspace "out.txt"),
             contents "lib/c.ml" )
         with
        | Ok (), "let x = Foo.bar 1\n", false, "let z = 3\n" -> None
        | _ -> Some "undo: the session was not put back");
      ]
  in
  let rec removed path =
    match Sys.is_directory path with
    | true ->
        Array.iter (fun name -> removed (Filename.concat path name)) (Sys.readdir path);
        Sys.rmdir path
    | false -> Sys.remove path
  in
  removed workspace;
  match failures with
  | [] -> ()
  | _ :: _ ->
      prerr_endline (String.concat "\n" failures);
      exit 1
