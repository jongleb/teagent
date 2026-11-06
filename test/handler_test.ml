let () =
  let workspaces = ref [] in
  let fresh () =
    let workspace = Filename.temp_dir "rune" "" in
    workspaces := workspace :: !workspaces;
    let placed path content =
      let rec made directory =
        if not (Sys.file_exists directory) then (
          made (Filename.dirname directory);
          Sys.mkdir directory 0o755)
      in
      let file = Filename.concat workspace path in
      made (Filename.dirname file);
      Out_channel.with_open_text file (fun channel ->
          Out_channel.output_string channel content)
    in
    placed "lib/a.ml" "let x = Foo.bar 1\n";
    placed "lib/b.ml" "let y = Foo.bar 2\n";
    placed "lib/c.ml" "let z = 3\n";
    placed "_build/default/lib/a.ml" "let x = Foo.bar 1\n";
    placed "twice.txt" "x and x\n";
    workspace
  in
  let contents workspace path =
    In_channel.with_open_text (Filename.concat workspace path) In_channel.input_all
  in
  let rename =
    In_channel.with_open_text "../bench/programs/01_rename.elm" In_channel.input_all
  in
  let started source =
    Result.bind
      (Result.map_error (fun report -> `Lang report) (Lang.compile source))
      (fun modules ->
        let program = Interp.load ~budget:1_000_000 modules in
        Result.map (fun task -> (program, task)) (Interp.main program))
  in
  let explained name = function
    | `Lang report -> Some (name ^ ": refused\n" ^ report)
    | `Failed _ -> Some (name ^ ": the program failed")
    | `Interp (Interp.Stuck reason) -> Some (name ^ ": stuck, " ^ reason)
    | `Interp (Interp.Crashed reason) -> Some (name ^ ": crashed, " ^ reason)
    | `Interp Interp.Budget_exhausted -> Some (name ^ ": out of budget")
  in
  let finished name check = function
    | Handler.Finished (Ok value) -> check value
    | Handler.Finished (Error error) -> explained name error
    | Handler.Stopped _ -> Some (name ^ ": stopped early")
  in
  let failures =
    List.filter_map Fun.id
      [
        (let workspace = fresh () in
         match started rename with
         | Error error -> explained "run 01_rename" error
         | Ok (program, task) ->
             let outcome, () =
               Lwt_main.run
                 (Handler.interpret (Handler.run (Tools.at workspace)) program () task)
             in
             finished "run 01_rename"
               (function
                 | V_record [ ("code", V_number _); ("out", V_string _) ] -> (
                     match
                       ( contents workspace "lib/a.ml",
                         contents workspace "lib/b.ml",
                         contents workspace "_build/default/lib/a.ml" )
                     with
                     | "let x = Foo.baz 1\n", "let y = Foo.baz 2\n", "let x = Foo.bar 1\n" ->
                         None
                     | _ -> Some "run 01_rename: the files are not renamed as expected")
                 | _ -> Some "run 01_rename: another result")
               outcome);
        (let workspace = fresh () in
         match
           started
             "module Main exposing (main)\n\n\
              import Agent exposing (..)\n\n\n\
              describe : IoErr -> String\n\
              describe problem =\n\
             \    case problem of\n\
             \        NotFound path ->\n\
             \            \"missing \" ++ path\n\n\
             \        Denied path ->\n\
             \            \"denied \" ++ path\n\n\
             \        Conflict _ ->\n\
             \            \"conflict\"\n\n\n\
              recovered : Task IoErr String -> Task IoErr String\n\
              recovered task =\n\
             \    task |> onError (\\problem -> succeed (describe problem))\n\n\n\
              main : Task IoErr (List String)\n\
              main =\n\
             \    batch\n\
             \        [ recovered (read \"missing.txt\")\n\
             \        , recovered (read \"../outside\")\n\
             \        , recovered (edit { path = \"twice.txt\", old = \"x\", new = \"y\" } |> map (\\_ -> \"edited\"))\n\
             \        , write \"new/dir/file.txt\" \"hello\" |> andThen (\\_ -> read \"new/dir/file.txt\")\n\
             \        , shell \"echo out; echo err 1>&2; exit 3\" |> map (\\r -> String.fromInt r.code ++ \":\" ++ r.out)\n\
             \        ]\n"
         with
         | Error error -> explained "run tools" error
         | Ok (program, task) ->
             let outcome, () =
               Lwt_main.run
                 (Handler.interpret (Handler.run (Tools.at workspace)) program () task)
             in
             finished "run tools"
               (function
                 | V_list
                     [
                       V_string "missing missing.txt";
                       V_string "denied ../outside";
                       V_string "conflict";
                       V_string "hello";
                       V_string "3:out\nerr\n";
                     ] ->
                     None
                 | _ -> Some "run tools: another result")
               outcome);
        (let workspace = fresh () in
         match started rename with
         | Error error -> explained "staged 01_rename" error
         | Ok (program, task) -> (
             let staged = Handler.staged (Tools.at workspace) Handler.Open in
             match
               Lwt_main.run (Handler.interpret staged program Handler.Overlay.empty task)
             with
             | Stopped (Tool (Shell "dune test") as rest), overlay -> (
                 match
                   ( contents workspace "lib/a.ml",
                     Handler.Overlay.diff overlay,
                     Lwt_main.run
                       (Tools.commit (Tools.at workspace) (Handler.Overlay.changes overlay)) )
                 with
                 | ( "let x = Foo.bar 1\n",
                     "--- a/lib/a.ml\n\
                      +++ b/lib/a.ml\n\
                      @@ -1,1 +1,1 @@\n\
                      -let x = Foo.bar 1\n\
                      +let x = Foo.baz 1\n\
                      --- a/lib/b.ml\n\
                      +++ b/lib/b.ml\n\
                      @@ -1,1 +1,1 @@\n\
                      -let y = Foo.bar 2\n\
                      +let y = Foo.baz 2\n",
                     Ok () ) -> (
                     match
                       ( contents workspace "lib/a.ml",
                         Lwt_main.run
                           (Handler.interpret staged program Handler.Overlay.empty rest) )
                     with
                     | "let x = Foo.baz 1\n", (outcome, _) ->
                         finished "staged 01_rename"
                           (function
                             | V_record [ ("code", V_number _); ("out", V_string _) ] -> None
                             | _ -> Some "staged 01_rename: another result after commit")
                           outcome
                     | _, _ -> Some "staged 01_rename: the commit did not reach the disk")
                 | _, diff, _ ->
                     Some ("staged 01_rename: the disk, the diff or the commit is wrong\n" ^ diff))
             | Stopped _, _ -> Some "staged 01_rename: stopped at another tool"
             | Finished _, _ -> Some "staged 01_rename: ran the shell over staged edits"));
        (let workspace = fresh () in
         match
           started
             "module Main exposing (main)\n\n\
              import Agent exposing (..)\n\n\n\
              main : Task IoErr (List String)\n\
              main =\n\
             \    write \"notes.txt\" \"TODO new\"\n\
             \        |> andThen (\\_ -> edit { path = \"lib/c.ml\", old = \"3\", new = \"4 (* TODO *)\" })\n\
             \        |> andThen (\\_ -> read \"notes.txt\")\n\
             \        |> andThen (\\text -> grep { pattern = \"TODO\", glob = \"**\" } |> map (\\found -> text :: List.map .path found))\n"
         with
         | Error error -> explained "staged reads" error
         | Ok (program, task) ->
             let outcome, _ =
               Lwt_main.run
                 (Handler.interpret
                    (Handler.staged (Tools.at workspace) Handler.Open)
                    program Handler.Overlay.empty task)
             in
             finished "staged reads"
               (function
                 | V_list [ V_string "TODO new"; V_string "lib/c.ml"; V_string "notes.txt" ]
                   -> (
                     match
                       ( Sys.file_exists (Filename.concat workspace "notes.txt"),
                         contents workspace "lib/c.ml" )
                     with
                     | false, "let z = 3\n" -> None
                     | _, _ -> Some "staged reads: the disk changed before a commit")
                 | _ -> Some "staged reads: reads or grep miss the staged files")
               outcome);
        (let workspace = fresh () in
         match started rename with
         | Error error -> explained "conflict" error
         | Ok (program, task) -> (
             match
               Lwt_main.run
                 (Handler.interpret
                    (Handler.staged (Tools.at workspace) Handler.Open)
                    program Handler.Overlay.empty task)
             with
             | Stopped _, overlay -> (
                 Out_channel.with_open_text (Filename.concat workspace "lib/b.ml")
                   (fun channel -> Out_channel.output_string channel "changed meanwhile\n");
                 match
                   ( Lwt_main.run
                       (Tools.commit (Tools.at workspace) (Handler.Overlay.changes overlay)),
                     contents workspace "lib/a.ml" )
                 with
                 | Error (`Tools (Tools.Conflict reason)), "let x = Foo.bar 1\n"
                   when String.ends_with ~suffix:"lib/b.ml" reason ->
                     None
                 | _ -> Some "conflict: a stale commit was not refused whole")
             | Finished _, _ -> Some "conflict: the program did not stop"));
        (let workspace = fresh () in
         match
           started
             "module Main exposing (main)\n\n\
              import Agent exposing (..)\n\n\n\
              main : Task Never Int\n\
              main =\n\
             \    shell \"touch marker\" |> map .code\n"
         with
         | Error error -> explained "no shell" error
         | Ok (program, task) -> (
             match
               Lwt_main.run
                 (Handler.interpret
                    (Handler.staged (Tools.at workspace) Handler.Disabled)
                    program Handler.Overlay.empty task)
             with
             | Finished (Ok (V_number 126.)), _
               when not (Sys.file_exists (Filename.concat workspace "marker")) ->
                 None
             | _ -> Some "no shell: the command ran or the program saw another code"));
        (let workspace = fresh () in
         let contains text piece =
           let rec at index =
             index + String.length piece <= String.length text
             && (String.equal (String.sub text index (String.length piece)) piece
                || at (index + 1))
           in
           at 0
         in
         match
           started
             ("module Main exposing (main)\n\n\
               import Agent exposing (..)\n\n\n\
               main : Task IoErr String\n\
               main =\n\
              \    edit { path = \"lib/a.ml\", old = \"Foo.bar\", new = \"Foo.baz\" }\n\
              \        |> andThen (\\_ -> shell \"cat lib/a.ml; echo built > out.txt; echo escaped > "
             ^ Filename.concat workspace "escape.txt"
             ^ "; /usr/bin/curl -s -m 5 https://example.com > /dev/null; echo net=$?\")\n\
               \        |> map .out\n")
         with
         | Error error -> explained "contained" error
         | Ok (program, task) -> (
             match
               Lwt_main.run
                 (Handler.interpret
                    (Handler.staged (Tools.at workspace) Handler.Contained)
                    program Handler.Overlay.empty task)
             with
             | Finished (Ok (V_string out)), overlay -> (
                 match
                   ( contains out "let x = Foo.baz 1",
                     contains out "net=0",
                     List.map
                       (fun (change : Tools.change) -> ((change.path :> string), change.after))
                       (Handler.Overlay.changes overlay),
                     Sys.file_exists (Filename.concat workspace "out.txt"),
                     Sys.file_exists (Filename.concat workspace "escape.txt"),
                     contents workspace "lib/a.ml" )
                 with
                 | ( true,
                     false,
                     [ ("lib/a.ml", "let x = Foo.baz 1\n"); ("out.txt", "built\n") ],
                     false,
                     false,
                     "let x = Foo.bar 1\n" ) -> (
                     match
                       Lwt_main.run
                         (Tools.commit (Tools.at workspace) (Handler.Overlay.changes overlay))
                     with
                     | Ok () when String.equal (contents workspace "out.txt") "built\n" -> None
                     | _ -> Some "contained: the harvested file did not commit")
                 | _ -> Some ("contained: the sandbox leaked or missed a write\n" ^ out))
             | _ -> Some "contained: the program did not finish"));
      ]
  in
  let rec removed path =
    match Sys.is_directory path with
    | true ->
        Array.iter (fun name -> removed (Filename.concat path name)) (Sys.readdir path);
        Sys.rmdir path
    | false -> Sys.remove path
  in
  List.iter removed !workspaces;
  match failures with
  | [] -> ()
  | _ :: _ ->
      prerr_endline (String.concat "\n\n" failures);
      exit 1
