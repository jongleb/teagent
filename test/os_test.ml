let () =
  let narrowed text os = Os.narrowed (Yojson.Safe.from_string text) os in
  let paths names =
    List.filter_map (fun name -> Result.to_option (Tools.Path.of_string name)) names
  in
  let skill source =
    Result.get_ok
      (Lang.Skill.of_source
         ~name:(List.hd (String.split_on_char ' ' source))
         ("module " ^ source))
  in
  let testing =
    skill
      "Testing exposing (check)\n\nimport Agent exposing (Task, IoErr, shell, map)\n\n\n\
       check : Task IoErr Int\ncheck =\n    shell \"make test\" |> map .code\n"
  in
  let program imports body =
    "module Main exposing (main)\n\nimport Agent exposing (..)\n" ^ imports
    ^ "\n\n\nmain : Task IoErr Int\nmain =\n    " ^ body ^ "\n"
  in
  let compiled os source = Lang.compile (Os.table os) source in
  let holds piece text =
    List.exists
      (fun at -> String.equal (String.sub text at (String.length piece)) piece)
      (List.init (String.length text - String.length piece + 1) Fun.id)
  in
  let says piece = function Ok _ -> false | Error report -> holds piece report in
  let full = Os.granted "/w" ~net:[] |> Os.taught [ testing ] in
  let failures =
    List.filter_map Fun.id
      [
        (match compiled full (program "import Testing" "Testing.check") with
        | Ok _ -> None
        | Error report -> Some ("a skill whose calls the OS offers did not compile:\n" ^ report));
        (match compiled (Os.only [ Os.Read ] full) (program "import Testing" "Testing.check") with
        | outcome when says "`Testing` is a skill this run does not install: it imports `shell`" outcome
          ->
            None
        | Ok _ -> Some "a skill that needs shell compiled in an OS without it"
        | Error report -> Some ("the report did not name the skill and the call:\n" ^ report));
        (match
           compiled
             (Os.granted "/w" ~net:[]
             |> Os.taught
                  [
                    skill
                      "Sly exposing (sly)\n\nimport Agent exposing (Task, IoErr)\n\n\n\
                       sly : Task IoErr Int\nsly =\n    Agent.shell \"x\" |> Agent.map .code\n";
                  ]
             |> Os.only [ Os.Read ])
             (program "" "succeed 1")
         with
        | Ok _ -> None
        | Error report -> Some ("a skill the program does not import broke it:\n" ^ report));
        (match
           compiled
             (Os.granted "/w" ~net:[]
             |> Os.taught
                  [
                    testing;
                    skill
                      "Ci exposing (ci)\n\nimport Agent exposing (Task, IoErr, read)\nimport Testing\n\n\n\
                       ci : Task IoErr Int\nci =\n    Testing.check\n";
                  ]
             |> Os.only [ Os.Read ])
             (program "import Ci" "Ci.ci")
         with
        | outcome when says "`Ci` is a skill this run does not install: it imports `Testing`" outcome ->
            None
        | outcome -> Some ("a skill that imports a withheld skill was installed:\n" ^ Result.fold ~ok:(fun _ -> "compiled") ~error:Fun.id outcome));
        (match
           compiled
             (Os.granted "/w" ~net:[]
             |> Os.taught
                  [
                    skill
                      "Probe exposing (probe)\n\nimport Agent exposing (Task)\nimport Fetch\n\n\n\
                       probe : Task Fetch.FetchErr Int\nprobe =\n    Fetch.get \"https://x\" |> Agent.map .status\n";
                  ]
             |> Os.only [ Os.Read; Os.Bash ])
             (program "import Probe" "Probe.probe")
         with
        | outcome when says "`Probe` is a skill this run does not install: it imports `Fetch`" outcome ->
            None
        | outcome -> Some ("a skill that imports an unplugged driver was installed:\n" ^ Result.fold ~ok:(fun _ -> "compiled") ~error:Fun.id outcome));
        (match
           ( Lang.Calls.source (Os.table full),
             Lang.Calls.source (Os.table (Os.only [ Os.Read ] full)) )
         with
        | shown, hidden when holds "module Testing" shown && not (holds "module Testing" hidden) -> None
        | _ -> Some "the model was shown a skill the OS cannot install, or not shown one it can");
        (match
           Lang.Skill.of_source ~name:"Raw" "module Raw exposing (x)\n\n\nx =\n    Elm.Kernel.Agent.shell\n"
         with
        | Error _ -> None
        | Ok _ -> Some "a skill that names Elm.Kernel was accepted");
        (match
           List.map
             (fun (name, header) -> Lang.Skill.of_source ~name (header ^ " exposing (x)\n\n\nx =\n    1\n"))
             [ ("Agent", "module Agent"); ("Fetch", "module Fetch"); ("Tools", "module Testing") ]
         with
        | [ Error _; Error _; Error "the module is called Testing, not Tools" ] -> None
        | _ -> Some "a skill that takes a teagent module's name or another file's was accepted");
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
