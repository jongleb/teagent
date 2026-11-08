let () =
  let narrowed text os = Os.narrowed (Yojson.Safe.from_string text) os in
  let paths names =
    List.filter_map (fun name -> Result.to_option (Tools.Path.of_string name)) names
  in
  let failures =
    List.filter_map Fun.id
      [
        (match narrowed {|{ "net": ["evil.example"] }|} (Os.granted "/w" ~net:[]) with
        | Ok os when (Os.view os).net = [] -> None
        | _ -> Some "a profile with net opened a host nobody granted");
        (match
           narrowed {|{ "net": ["registry.npmjs.org", "evil.example", "*.org"] }|}
             (Os.granted "/w" ~net:[ "*.npmjs.org"; "example.com" ])
         with
        | Ok os when (Os.view os).net = [ "registry.npmjs.org" ] -> None
        | _ -> Some "net kept a host or a pattern wider than the grant");
        (match narrowed {|{ "tools": ["read", "bash"] }|} (Os.granted "/w" ~net:[]) with
        | Ok os when (Os.view os).offers = [ Os.Bash; Os.Read ] -> None
        | _ -> Some "tools did not narrow to the listed calls");
        (match
           Os.granted "/w" ~net:[] |> Os.only [ Os.Read ] |> narrowed {|{ "tools": ["read", "bash"] }|}
         with
        | Ok os when (Os.view os).offers = [ Os.Read ] -> None
        | _ -> Some "a profile gave back a call the OS had dropped");
        (match
           Os.granted "/w" ~net:[] |> Os.reading [ "/opt/a" ] |> Os.reading [ "/opt/a/b"; "/etc" ]
         with
        | os when (Os.view os).reads = Within [ "/opt/a/b" ] -> None
        | _ -> Some "a second reads widened the first");
        (match
           Os.granted "/w" ~net:[]
           |> Os.mounting (List.map (fun path -> (path, Tools.Hidden)) (paths [ "secrets" ]))
           |> narrowed {|{ "hidden": ["keys"], "mounts": { "vendor": "readonly", "tmp": "scratch" } }|}
         with
        | Ok os
          when List.map snd (Os.view os).mounts = [ Tools.Hidden; Tools.Hidden; Tools.Readonly; Tools.Scratch ] ->
            None
        | _ -> Some "mounts did not add up");
        (match narrowed {|{ "mounts": { "tmp": "writable" } }|} (Os.granted "/w" ~net:[]) with
        | Error "mounts: tmp is not hidden, readonly or scratch" -> None
        | _ -> Some "an unknown mount kind was not refused");
        (match narrowed {|{ "tools": ["read", "run"] }|} (Os.granted "/w" ~net:[]) with
        | Ok os
          when List.filter
                 (fun name ->
                   let source = Lang.Calls.source (Os.table os) and piece = "\n" ^ name ^ " :" in
                   List.exists
                     (fun at -> String.equal (String.sub source at (String.length piece)) piece)
                     (List.init (String.length source - String.length piece + 1) Fun.id))
                 [ "read"; "write"; "edit"; "grep"; "shell"; "hole" ]
               = [ "read"; "hole" ]
               && not
                    (List.exists
                       (String.starts_with ~prefix:"module Fetch")
                       (String.split_on_char '\n' (Lang.Calls.source (Os.table os)))) ->
            None
        | _ -> Some "the Agent module kept a call the profile dropped");
        (match narrowed {|{ "nett": [] }|} (Os.granted "/w" ~net:[]) with
        | Error "there is no setting called nett" -> None
        | _ -> Some "an unknown setting was not refused");
        (match narrowed {|{ "hidden": [".git"] }|} (Os.granted "/w" ~net:[]) with
        | Error "hidden: .git is not a path in the project" -> None
        | _ -> Some "a tooling path was accepted as a profile path");
      ]
  in
  match failures with
  | [] -> ()
  | _ :: _ ->
      prerr_endline (String.concat "\n" failures);
      exit 1
