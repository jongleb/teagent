let () =
  let programs = "../bench/programs" in
  let accepted =
    List.filter_map
      (fun file ->
        Result.fold
          ~ok:(fun _ -> None)
          ~error:(fun report -> Some (file ^ "\n" ^ report))
          (Lang.compile Lang.Calls.all
             (In_channel.with_open_text
                (Filename.concat programs file)
                In_channel.input_all)))
      (List.sort String.compare (Array.to_list (Sys.readdir programs)))
  in
  let rejected =
    List.filter_map
      (fun (title, source) ->
        match Lang.compile Lang.Calls.all source with
        | Error report
          when String.starts_with ~prefix:("-- " ^ title ^ " ") report ->
            None
        | Error report -> Some (title ^ ": another report\n" ^ report)
        | Ok _ -> Some (title ^ ": compiled"))
      [
        ( "KERNEL ACCESS",
          "module Main exposing (main)\n\nimport Agent exposing (..)\n\n\nmain : Task e { out : String, code : Int }\nmain =\n    Elm.Kernel.Agent.shell \"ls\"\n" );
        ( "BAD MAIN TYPE",
          "module Main exposing (main)\n\nmain : Int\nmain =\n    5\n" );
        ( "NO ENTRY POINT",
          "module Main exposing (start)\n\nstart : Int\nstart =\n    5\n" );
        ( "MISSING PATTERNS",
          "module Main exposing (main)\n\n\
           import Agent exposing (..)\n\n\
           main : Task IoErr String\n\
           main =\n\
          \    read \"notes.txt\"\n\
          \        |> onError\n\
          \            (\\problem ->\n\
          \                case problem of\n\
          \                    NotFound path ->\n\
          \                        succeed path\n\
          \            )\n" );
        ( "REDUNDANT PATTERN",
          "module Main exposing (main)\n\n\
           import Agent exposing (..)\n\n\
           main : Task IoErr String\n\
           main =\n\
          \    read \"notes.txt\"\n\
          \        |> onError\n\
          \            (\\problem ->\n\
          \                case problem of\n\
          \                    _ ->\n\
          \                        succeed \"\"\n\n\
          \                    NotFound path ->\n\
          \                        succeed path\n\
          \            )\n" );
      ]
  in
  let header =
    "module Main exposing (main)\n\nimport Agent exposing (..)\n\n\n"
  in
  let hinted =
    List.filter_map
      (fun (hint, source) ->
        let contains text piece =
          let rec at index =
            index + String.length piece <= String.length text
            && (String.equal (String.sub text index (String.length piece)) piece || at (index + 1))
          in
          at 0
        in
        match Lang.compile Lang.Calls.all (header ^ source) with
        | Error report when contains report ("Hint: " ^ hint) -> None
        | Error report -> Some ("no hint `" ^ hint ^ "` in\n" ^ report)
        | Ok _ -> Some ("compiled, so no hint `" ^ hint ^ "`"))
      [
        ( "`port` is a reserved word",
          "main : Task Never Int\n\
           main =\n\
          \    succeed\n\
          \        (case String.toInt \"1\" of\n\
          \            Just port ->\n\
          \                port\n\n\
          \            Nothing ->\n\
          \                0\n\
          \        )\n" );
        ( "`String.toInt`, `List.head` and `Dict.get` return a `Maybe`",
          "main : Task Never Int\n\
           main =\n\
          \    succeed\n\
          \        (case String.toInt \"1\" of\n\
          \            Ok n ->\n\
          \                n\n\n\
          \            Err _ ->\n\
          \                0\n\
          \        )\n" );
        ( "There is no `Task` module",
          "main : Task Never Int\nmain =\n    Task.succeed 1\n" );
        ( "`Result`, `Ok` and `Err` are already imported",
          "import Result exposing (Result, Ok, Err)\n\n\n\
           main : Task Never Int\nmain =\n    succeed 1\n" );
        ( "Only the core List functions exist",
          "main : Task Never (Maybe Int)\nmain =\n    succeed (List.getAt 0 [ 1 ])\n" );
        ( "`IoErr` is a type, not a constructor",
          "main : Task IoErr Int\nmain =\n    fail (NotFound (IoErr \"x\"))\n" );
        ( "These tasks fail with different error types",
          "type Err\n\
          \    = ReadFailed IoErr\n\n\n\
           main : Task Err String\n\
           main =\n\
          \    succeed \"x\" |> andThen (\\_ -> read \"a.txt\")\n" );
      ]
  in
  let piped =
    match
      Lang.compile Lang.Calls.all
        (header
       ^ "main : Task Never Int\n\
          main =\n\
         \    succeed\n\
         \        (case [ 1 ] |> List.length of\n\
         \            n ->\n\
         \                n\n\
         \        )\n")
    with
    | Ok _ -> []
    | Error report -> [ "a case subject with |> does not compile\n" ^ report ]
  in
  let piped =
    piped
    @
    match
      Lang.compile Lang.Calls.all
        (header
       ^ "main : Task String Int\n\
          main =\n\
         \    fromResult (Result.fromMaybe \"not a number\" (String.toInt \"7\"))\n"
        )
    with
    | Ok _ -> []
    | Error report -> [ "fromResult does not compile\n" ^ report ]
  in
  let narrowed =
    let calls = Lang.Calls.without [ Data.Kernel.Agent_shell ] Lang.Calls.all in
    let contains text piece =
      let rec at index =
        index + String.length piece <= String.length text
        && (String.equal (String.sub text index (String.length piece)) piece || at (index + 1))
      in
      at 0
    in
    match
      ( contains (Lang.Calls.source calls) "shell",
        contains (Lang.Calls.source calls) "read : String",
        Lang.compile calls (header ^ "main : Task e { out : String, code : Int }\nmain =\n    shell \"ls\"\n"),
        Lang.compile calls (header ^ "main : Task IoErr String\nmain =\n    read \"a\"\n") )
    with
    | false, true, Error report, Ok _ when contains report "is not in Agent in this run" -> []
    | _, _, Error report, _ -> [ "a call the OS left out was not refused with a hint\n" ^ report ]
    | _ -> [ "the Agent module of a narrowed OS is wrong" ]
  in
  match accepted @ rejected @ hinted @ piped @ narrowed with
  | [] -> ()
  | failures ->
      prerr_endline (String.concat "\n\n" failures);
      exit 1
