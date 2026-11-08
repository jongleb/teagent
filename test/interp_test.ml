let () =
  let loaded source =
    Result.map (Interp.load ~budget:100_000)
      (Result.map_error (fun report -> `Lang report) (Lang.compile Lang.Calls.all source))
  in
  let program file =
    loaded
      (In_channel.with_open_text
         (Filename.concat "../bench/programs" file)
         In_channel.input_all)
  in
  let explained name = function
    | `Lang report -> Some (name ^ ": refused\n" ^ report)
    | `Interp (Interp.Stuck reason) -> Some (name ^ ": stuck, " ^ reason)
    | `Interp (Interp.Crashed reason) -> Some (name ^ ": crashed, " ^ reason)
    | `Interp Interp.Budget_exhausted -> Some (name ^ ": out of budget")
  in
  let matched path : Value.t =
    V_record
      [
        ("line", V_number 1.);
        ("path", V_string path);
        ("text", V_string "Foo.bar and TODO");
      ]
  in
  let run name check =
    match check () with
    | Ok None -> None
    | Ok (Some failure) -> Some (name ^ ": " ^ failure)
    | Error error -> explained name error
  in
  let failures =
    List.filter_map Fun.id
      [
        run "01_rename" (fun () ->
            Result.bind (program "01_rename.elm") (fun loaded ->
                match Interp.main loaded with
                | Ok
                    (And_then
                      {
                        callback = tested;
                        task =
                          And_then
                            {
                              callback = edited;
                              task =
                                Tool (Grep { pattern = "Foo\\.bar"; glob = "**/*.ml" });
                            };
                      }) -> (
                    match
                      Interp.apply loaded edited
                        (V_list
                           [ matched "lib/a.ml"; matched "lib/a.ml"; matched "lib/b.ml" ])
                    with
                    | Ok
                        (V_task
                          (Map_err
                            {
                              task =
                                Batch
                                  [
                                    Tool
                                      (Edit
                                        {
                                          path = "lib/a.ml";
                                          old = "Foo.bar";
                                          new_ = "Foo.baz";
                                        });
                                    Tool (Edit { path = "lib/b.ml"; _ });
                                  ];
                              _;
                            })) -> (
                        match Interp.apply loaded tested (V_list [ V_unit; V_unit ]) with
                        | Ok (V_task (Tool (Shell "dune test"))) -> Ok None
                        | Ok _ -> Ok (Some "tests are not run after the edits")
                        | Error error -> Error error)
                    | Ok _ -> Ok (Some "the matches do not become one edit per file")
                    | Error error -> Error error)
                | Ok _ -> Ok (Some "main is another task")
                | Error error -> Error error));
        run "02_todos" (fun () ->
            Result.bind (program "02_todos.elm") (fun loaded ->
                match Interp.main loaded with
                | Ok
                    (And_then
                      {
                        callback = searched;
                        task = On_error { callback = recovered; task = Tool (Read "README.md") };
                      }) -> (
                    match
                      ( Interp.apply loaded recovered
                          (V_constr
                             {
                               constructor = { module_name = "Agent"; name = "NotFound" };
                               arguments = [ V_string "README.md" ];
                             }),
                        Interp.apply loaded searched (V_string "# Teagent\nmore") )
                    with
                    | ( Ok (V_task (Succeed (V_string ""))),
                        Ok
                          (V_task
                            (Map
                              {
                                callback = reported;
                                task = Tool (Grep { pattern = "TODO"; glob = "lib/**/*.ml" });
                              })) ) -> (
                        match
                          Interp.apply loaded reported
                            (V_list
                               [ matched "lib/a.ml"; matched "lib/b.ml"; matched "lib/a.ml" ])
                        with
                        | Ok
                            (V_record
                              [
                                ("title", V_string "# Teagent");
                                ( "todos",
                                  V_list
                                    [
                                      V_record
                                        [
                                          ("count", V_number 2.);
                                          ("path", V_string "lib/a.ml");
                                        ];
                                      V_record
                                        [
                                          ("count", V_number 1.);
                                          ("path", V_string "lib/b.ml");
                                        ];
                                    ] );
                              ]) ->
                            Ok None
                        | Ok _ -> Ok (Some "the report is wrong")
                        | Error error -> Error error)
                    | Ok _, Ok _ -> Ok (Some "a missing README or the search goes wrong")
                    | Error error, _ | _, Error error -> Error error)
                | Ok _ -> Ok (Some "main is another task")
                | Error error -> Error error));
        run "03_build" (fun () ->
            Result.bind (program "03_build.elm") (fun loaded ->
                match Interp.main loaded with
                | Ok (And_then { callback = built; task = Tool (Shell "dune build 2>&1") })
                  -> (
                    match
                      Interp.apply loaded built
                        (V_record
                           [
                             ("code", V_number 1.);
                             ( "out",
                               V_string "File \"lib/a.ml\", line 3\nError: Unbound x\nnoise" );
                           ])
                    with
                    | Ok
                        (V_task
                          (Map { callback = described; task = Tool (Shell "git diff --stat") }))
                      -> (
                        match
                          Interp.apply loaded described
                            (V_record
                               [ ("code", V_number 0.); ("out", V_string " lib/a.ml | 2 +-\n") ])
                        with
                        | Ok
                            (V_constr
                              {
                                constructor = { module_name = "Main"; name = "Broken" };
                                arguments =
                                  [
                                    V_record
                                      [
                                        ("changed", V_string "lib/a.ml | 2 +-");
                                        ( "errors",
                                          V_list
                                            [
                                              V_string "File \"lib/a.ml\", line 3";
                                              V_string "Error: Unbound x";
                                            ] );
                                      ];
                                  ];
                              }) ->
                            Ok None
                        | Ok _ -> Ok (Some "the broken build is described wrongly")
                        | Error error -> Error error)
                    | Ok _ -> Ok (Some "a failed build does not ask for the diff")
                    | Error error -> Error error)
                | Ok _ -> Ok (Some "main is another task")
                | Error error -> Error error));
        run "kernels" (fun () ->
            Result.bind
              (loaded
                 "module Main exposing (main)\n\n\
                  import Agent exposing (..)\n\n\n\
                  main : Task Never (List String)\n\
                  main =\n\
                 \    succeed\n\
                 \        [ String.fromInt 42\n\
                 \        , String.fromFloat 0.1\n\
                 \        , String.fromFloat (10 / 4)\n\
                 \        , String.fromInt (7 // 2)\n\
                 \        , String.fromInt (modBy 3 (negate 7))\n\
                 \        , String.left 2 \"h\xc3\xa9llo\"\n\
                 \        , String.fromInt (String.length \"h\xc3\xa9llo\")\n\
                 \        , String.join \",\" (String.split \", \" \"a, b, c\")\n\
                 \        , Maybe.withDefault \"none\" (Maybe.map String.fromInt (String.toInt \"12\"))\n\
                 \        , Maybe.withDefault \"none\" (Maybe.map String.fromInt (String.toInt \"x1\"))\n\
                 \        , String.fromInt (Char.toCode '\xc3\xa9')\n\
                 \        , String.toUpper \"abc\"\n\
                 \        , String.join \"|\" (String.lines \"a\\nb\")\n\
                 \        , String.fromInt (List.sum (List.indexedMap (\\i x -> i * x) [ 1, 2, 3 ]))\n\
                 \        , if compare \"a\" \"b\" == LT then \"lt\" else \"ge\"\n\
                 \        , String.fromInt (round 2.5)\n\
                 \        , String.fromInt (truncate (negate 2.7))\n\
                 \        , String.trim \"  x  \"\n\
                 \        , String.dropLeft 2 \"hello\"\n\
                 \        , String.right 2 \"hello\"\n\
                 \        ]\n")
              (fun loaded ->
                match Interp.main loaded with
                | Ok (Succeed (V_list shown)) -> (
                    let expected =
                      [
                        "42"; "0.1"; "2.5"; "3"; "2"; "h\xc3\xa9"; "5"; "a,b,c"; "12";
                        "none"; "233"; "ABC"; "a|b"; "8"; "lt"; "3"; "-2"; "x"; "llo";
                        "lo";
                      ]
                    in
                    let texts =
                      List.map
                        (function Value.V_string text -> text | _ -> "<not a string>")
                        shown
                    in
                    match List.equal String.equal texts expected with
                    | true -> Ok None
                    | false -> Ok (Some (String.concat " | " texts)))
                | Ok _ -> Ok (Some "main is another task")
                | Error error -> Error error));
        run "budget" (fun () ->
            Result.bind
              (loaded
                 "module Main exposing (main)\n\n\
                  import Agent exposing (..)\n\n\n\
                  spin : Int -> Int\n\
                  spin n =\n\
                 \    spin (n + 1)\n\n\n\
                  main : Task Never Int\n\
                  main =\n\
                 \    succeed (spin 0)\n")
              (fun loaded ->
                match Interp.main loaded with
                | Error (`Interp Interp.Budget_exhausted) -> Ok None
                | Ok _ -> Ok (Some "an endless program finished")
                | Error error -> Error error));
      ]
  in
  match failures with
  | [] -> ()
  | _ :: _ ->
      prerr_endline (String.concat "\n\n" failures);
      exit 1
