let () =
  let programs = "../bench/programs" in
  let accepted =
    List.filter_map
      (fun file ->
        Result.fold
          ~ok:(fun _ -> None)
          ~error:(fun report -> Some (file ^ "\n" ^ report))
          (Lang.compile
             (In_channel.with_open_text
                (Filename.concat programs file)
                In_channel.input_all)))
      (List.sort String.compare (Array.to_list (Sys.readdir programs)))
  in
  let rejected =
    List.filter_map
      (fun (title, source) ->
        match Lang.compile source with
        | Error report
          when String.starts_with ~prefix:("-- " ^ title ^ " ") report ->
            None
        | Error report -> Some (title ^ ": another report\n" ^ report)
        | Ok _ -> Some (title ^ ": compiled"))
      [
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
        match Lang.compile (header ^ source) with
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
      Lang.compile
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
  match accepted @ rejected @ hinted @ piped with
  | [] -> ()
  | failures ->
      prerr_endline (String.concat "\n\n" failures);
      exit 1
