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
  match accepted @ rejected with
  | [] -> ()
  | failures ->
      prerr_endline (String.concat "\n\n" failures);
      exit 1
