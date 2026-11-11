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
        (match
           Result.bind
             (narrowed {|{ "boot": [{ "budget": 5 }, "journal", "policy"] }|} (Os.granted "/w" ~net:[]))
             (narrowed {|{ "boot": ["journal", "policy", { "budget": 9 }] }|})
         with
        | Ok os when ((Os.view os).boot :> Handler.Boot.layer list) = [ Journal; Policy; Budget 5 ] -> None
        | _ -> Some "a second boot did not keep its order with the smaller budget");
        (match
           Result.bind
             (narrowed {|{ "boot": [{ "budget": 5 }, "journal", "policy"] }|} (Os.granted "/w" ~net:[]))
             (narrowed {|{ "boot": ["journal", "policy"] }|})
         with
        | Ok os when ((Os.view os).boot :> Handler.Boot.layer list) = [ Budget 5; Journal; Policy ] -> None
        | _ -> Some "a boot without a budget dropped the earlier one");
        (match
           List.map
             (fun text -> narrowed text (Os.granted "/w" ~net:[]))
             [
               {|{ "boot": ["policy", "journal"] }|};
               {|{ "boot": ["journal"] }|};
               {|{ "boot": ["journal", "policy", "journal"] }|};
               {|{ "boot": [{ "budget": 1 }, "journal", "policy", { "budget": 2 }] }|};
               {|{ "boot": [{ "budget": -1 }, "journal", "policy"] }|};
             ]
         with
        | [ Error _; Error _; Error _; Error _; Error _ ] -> None
        | _ -> Some "a boot without one policy inside one journal, or with a bad budget, was accepted");
        (match
           ( List.map
               (fun name -> Result.is_ok (Tools.Path.of_string name))
               [ "pkg/.git/hooks/pre-commit"; "a/.VSCode/tasks.json"; "x/.envrc"; "lib/git.ml" ],
             List.map
               (fun name -> Option.bind (Result.to_option (Tools.Path.of_string name)) Tools.Path.runner)
               [ ".github/workflows/ci.yml"; "AGENTS.md"; "web/package.json"; "src/CLAUDE.md";
                 ".husky/pre-commit"; "lib/a.ml"; "docs/agents.txt"; "github/workflows.md" ] )
         with
        | ( [ false; false; false; true ],
            [ Some "CI"; Some _; Some _; Some _; Some "git hooks"; None; None; None ] ) ->
            None
        | _ -> Some "paths: a tooling folder below the top was accepted, or a host-run file was missed");
        (match
           ( Os.class_of (Os.granted "/w" ~net:[]) (Value.Shell "make"),
             Os.class_of (Os.granted "/w" ~net:[ "registry.npmjs.org" ]) (Value.Shell "make"),
             Os.class_of (Os.granted "/w" ~net:[])
               (Value.Call { name = "fetch.get"; argument = V_string "https://example.com" }) )
         with
        | Contained, Egress _, Egress _ -> None
        | _ -> Some "classes: a shell with granted hosts or Fetch.get is not Egress");
        (let reach os body imports =
           Result.map
             (fun modules -> Os.exposure os (Lang.calls modules))
             (Lang.compile (Os.table os) (program imports body))
         in
         let offline = Os.granted "/w" ~net:[] and online = Os.granted "/w" ~net:[ "registry.npmjs.org" ] in
         match
           ( reach offline
               "read \"a\" |> mapErr (\\_ -> Fetch.Unreachable \"\") |> andThen (\\t -> Fetch.get t) |> map .status |> mapErr (\\_ -> NotFound \"\")"
               "import Fetch",
             reach offline "read \"a\" |> andThen (\\t -> write \"b\" t) |> map (\\_ -> 0)" "",
             reach offline "shell \"ls\" |> map .code" "",
             reach online "shell \"npm ci\" |> map .code" "",
             reach offline "read \"a\" |> andThen (\\_ -> hole \"later\")" "",
             reach offline
               "read \"a\" |> andThen (\\_ -> hole \"later\") |> andThen (\\t -> Fetch.get t |> map .status |> mapErr (\\_ -> NotFound \"\"))"
               "import Fetch" )
         with
        | ( Ok None,
            Ok None,
            Ok None,
            Ok (Some { reads = [ "shell with --net" ]; _ }),
            Ok None,
            Ok None )
          ->
            None
        | _ -> Some "exposure: a program with all three legs passed, or one without them was held");
        (match
           ( Result.bind
               (narrowed {|{ "seconds": 60 }|} (Os.granted "/w" ~net:[]))
               (narrowed {|{ "seconds": 600 }|}),
             narrowed {|{ "seconds": 0 }|} (Os.granted "/w" ~net:[]),
             (Os.view (Os.granted "/w" ~net:[])).seconds )
         with
        | Ok os, Error _, 1800 when (Os.view os).seconds = 60 -> None
        | _ -> Some "seconds: a profile raised the time limit, or took zero");
        (let ruled source =
           Result.bind (Lang.Skill.of_source ~name:"Rules" source) (fun rules ->
               Os.ruled rules (Os.granted "/w" ~net:[]))
         in
         let fetched = Value.Call { name = "fetch.get"; argument = V_string "https://x" } in
         match
           ( ruled "module Rules exposing (decide)\n\n\
import Policy exposing (..)\n\n\n\
decide : Call -> List Source -> List Call -> Decision\n\
decide call sources history =\n\
\    case call of\n\
\        Call \"fetch.get\" _ ->\n\
\            if List.any readsSecrets history then\n\
\                Deny \"no fetching after reading secrets\"\n\n\
\            else\n\
\                Allow\n\n\
\        Write path ->\n\
\            if String.startsWith \"vendor/\" path then\n\
\                Ask (\"write \" ++ path)\n\n\
\            else\n\
\                Allow\n\n\
\        _ ->\n\
\            Allow\n\n\n\
readsSecrets : Call -> Bool\n\
readsSecrets call =\n\
\    case call of\n\
\        Read path ->\n\
\            String.startsWith \"secrets/\" path\n\n\
\        _ ->\n\
\            False\n",
             ruled "module Rules exposing (decide)\n\nimport Policy exposing (..)\n\n\ndecide : Call -> List Source -> List Call -> Decision\ndecide call sources history =\n    decide call sources history\n",
             ruled "module Rules exposing (decide)\n\nimport Policy exposing (..)\n\n\ndecide : Call -> Decision\ndecide call =\n    Allow\n" )
         with
        | Ok _, Ok _, Ok _ -> Some "rules: a decide of the wrong type was accepted"
        | Ok os, Ok looping, Error _ -> (
            match
              ( Os.decided os [ Value.Read "secrets/key" ] fetched [],
                Os.decided os [ Value.Read "lib/a.ml" ] fetched [],
                Os.decided os [] (Value.Write { path = "vendor/x.ml"; content = "" }) [],
                Os.decided os [] (Value.Read "lib/a.ml") [],
                Os.decided looping [] (Value.Read "lib/a.ml") [],
                String.equal (Os.image os) (Os.image (Os.granted "/w" ~net:[])) )
            with
            | Deny _, Allow, Ask "write vendor/x.ml", Allow, Deny reason, false
              when String.starts_with ~prefix:"the rules failed" reason ->
                None
            | _ -> Some "rules: a decision came out wrong, a failing rule did not deny, or the image ignored them")
        | _ -> Some "rules: good rules were refused");
        (match
           ( Lang.Skill.of_source ~name:"Sneaky"
               "module Sneaky exposing (x)\n\n\n-- \u{202E}evil hidden\nx : Int\nx =\n    1\n",
             Lang.Skill.of_source ~name:"Spaced" "module Spaced exposing (x)\n\n\nx : String\nx =\n    \"a\u{200B}b\"\n",
             Tools.revealed "a\u{202E}b\u{FEFF}c",
             String.equal
               (Tools.revealed (Lang.Calls.source Lang.Calls.all))
               (Lang.Calls.source Lang.Calls.all),
             Handler.Overlay.diff
               (List.filter_map
                  (fun path ->
                    Result.to_option
                      (Result.map
                         (fun path -> { Tools.path; before = Some "x\n"; after = Some "x\u{2066}y\n" })
                         (Tools.Path.of_string path)))
                  [ "a.ml" ]) )
         with
        | Error first, Error second, "a<U+202E>b<U+FEFF>c", true, diff
          when holds "<U+202E>" first && holds "<U+200B>" second && holds "+x<U+2066>y" diff ->
            None
        | _ -> Some "unicode: a hidden character passed into a skill, a diff, or teagent's own modules");
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
