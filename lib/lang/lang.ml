type t = {
  module_name : string;
  declarations : Ir.Ast.declaration list;
  constructors : (Data.Name.t * int) list;
}

module Compiler = Dartea.Compiler.Make (struct
  let extension = "ir"
  let runtime_modules _ = []

  let platform_kernel name =
    Option.map Data.Kernel.agent_arity (Data.Kernel.agent_of_name name)

  let through _ = None

  let emit_module ~blocks:_ ~arities ~constructors ~built:_ ~siblings
      ~typedecls:_ ~imports:_ ~exports:_ declarations =
    ( Ir.To_string.program
        (Ir.Of_optimized.convert ~arities ~constructors ~siblings declarations),
      [] )
end)

let found piece text =
  let rec at index =
    match index + String.length piece <= String.length text with
    | false -> None
    | true when String.equal (String.sub text index (String.length piece)) piece -> Some index
    | true -> at (index + 1)
  in
  at 0

module Calls = struct
  type t = { dropped : Data.Kernel.agent list; plugged : Device.t list }

  let all = { dropped = []; plugged = Device.all }
  let without kernels calls = { calls with dropped = List.sort_uniq compare (kernels @ calls.dropped) }

  let unplugged devices calls =
    { calls with plugged = List.filter (fun device -> not (List.mem device devices)) calls.plugged }

  let cut { dropped; _ } =
    let rec blocks text =
      Option.fold ~none:[ text ]
        ~some:(fun at ->
          String.sub text 0 at :: blocks (String.sub text (at + 3) (String.length text - at - 3)))
        (found "\n\n\n" text)
    in
    let gone block =
      Option.bind (found "Elm.Kernel.Agent." block) (fun at ->
          let start = at + String.length "Elm.Kernel.Agent." in
          match
            String.split_on_char '\n' (String.sub block start (String.length block - start))
          with
          | [] -> None
          | kernel :: _ ->
              Option.bind
                (Data.Kernel.agent_of_name (Data.Kernel.written_as "Agent" kernel))
                (fun kernel ->
                  Option.map
                    (fun _ ->
                      match String.split_on_char ' ' block with [] -> block | name :: _ -> name)
                    (List.find_opt (( = ) kernel) dropped)))
    in
    match blocks Agent.source with
    | [] -> ("", [])
    | header :: declarations ->
        let kept, names =
          List.partition_map
            (fun block -> Option.fold ~none:(Either.Left block) ~some:Either.right (gone block))
            declarations
        in
        ( String.concat "\n\n\n"
            (String.concat "\n"
               (List.filter
                  (fun line ->
                    Option.is_none
                      (List.find_opt (fun name -> String.equal line ("    , " ^ name)) names))
                  (String.split_on_char '\n' header))
            :: kept),
          names )

  let modules calls = fst (cut calls) :: List.map Device.source calls.plugged
  let source calls = String.concat "\n\n" (modules calls)
end

let compile calls source =
  match found "Elm.Kernel" source with
  | Some _ ->
      Error
        "-- KERNEL ACCESS ---------------------------------------------------- Main.elm\n\n\
         A program cannot name `Elm.Kernel` directly: everything it does goes through Agent \
         and the other modules of this run, so write the call with them."
  | None ->
      let outcome =
        Compiler.compile_modules ~entry:(Some "Main")
          (Project.Sources.of_list
             (List.map
                (fun module_source ->
                  Project.Elm_file.of_path
                    ~path:
                      (match String.split_on_char ' ' module_source with
                      | "module" :: name :: _ -> name ^ ".elm"
                      | _ -> "Prelude.elm")
                    module_source)
                (Calls.modules calls)
             @ [ Project.Elm_file.of_path ~path:"Main.elm" source ]))
      in
      let sources = Reporting.Sources.of_list outcome.sources in
      let refused reports =
        let hinted text =
          let maybe =
            "`String.toInt`, `List.head` and `Dict.get` return a `Maybe`: match `Just value` and \
             `Nothing`, not `Ok` and `Err`."
          in
          let rules =
            [
              ([ "`Ok` values"; "Maybe" ], maybe);
              ([ "`Err` values"; "Maybe" ], maybe);
              ( [ "`Just` values"; "Result" ],
                "This value is a `Result`: match `Ok value` and `Err problem`, not `Just` and \
                 `Nothing`." );
              ( [ "I cannot find a `Task." ],
                "There is no `Task` module: the task functions come from Agent and are written \
                 without a prefix, as `succeed`, `fail`, `andThen`, `map`, `mapErr`, `onError`, \
                 `batch` and `fromResult`." );
              ( [ "does not expose `Ok`" ],
                "`Result`, `Ok` and `Err` are already imported. To import a type with its \
                 constructors elsewhere, write `Type(..)`." );
              ( [ "does not expose `Just`" ],
                "`Maybe`, `Just` and `Nothing` are already imported. To import a type with its \
                 constructors elsewhere, write `Type(..)`." );
              ( [ "I cannot find a `List." ],
                "Only the core List functions exist (map, filter, filterMap, foldl, foldr, head, \
                 tail, take, drop, length, member, any, all, sort, sortBy, concat, concatMap, \
                 indexedMap, partition, unique and the like). To get the element at index n, \
                 write `List.head (List.drop n list)`." );
              ( [ "I cannot find a `IoErr` variant" ],
                "`IoErr` is a type, not a constructor. Its values are `NotFound path`, `Denied \
                 path` and `Conflict reason`. For failures of your own, declare your own error \
                 type." );
            ]
            @ List.map
                (fun name ->
                  ( [ "I cannot find a `" ^ name ^ "`" ],
                    "`" ^ name
                    ^ "` is not in Agent in this run: the OS the task runs under does not offer it, \
                       so solve the task without it." ))
                (snd (Calls.cut calls))
            @ List.map
                (fun word ->
                  ( [ "I was not expecting `" ^ word ^ "`" ],
                    "`" ^ word
                    ^ "` is a reserved word in Elm, so it cannot name a variable or a field; pick \
                       another name." ))
                [ "port"; "type"; "module"; "import"; "exposing"; "as"; "where"; "alias"; "effect" ]
          in
          let errors =
            List.sort_uniq String.compare
              (List.filter_map
                 (fun line ->
                   match String.split_on_char ' ' (String.trim line) with
                   | "Task" :: error :: _ -> Some error
                   | _ -> None)
                 (String.split_on_char '\n' text))
          in
          let hints =
            List.sort_uniq String.compare
              (List.filter_map
                 (fun (pieces, hint) ->
                   match List.filter (fun piece -> Option.is_none (found piece text)) pieces with
                   | [] -> Some hint
                   | _ :: _ -> None)
                 rules
              @ (match List.partition (String.equal "IoErr") errors with
                | _ :: _, _ :: _ ->
                    [
                      "These tasks fail with different error types. Convert an `IoErr` with \
                       `mapErr`, as in `read path |> mapErr ReadFailed`, or make `IoErr` the \
                       error type of `main`.";
                    ]
                | [], _ | _ :: _, [] -> []))
          in
          String.concat "\n\n" (text :: List.map (fun hint -> "Hint: " ^ hint) hints)
        in
        Error
          (String.concat "\n\n"
             (List.map
                (fun report -> hinted (Reporting.Report.to_string ~colours:false report))
                reports))
      in
      match
        ( outcome.errors,
          List.concat_map
            (fun (linked : Dartea.Compiler.linkable) -> linked.warnings)
            outcome.modules,
          outcome.entry )
      with
      | (_ :: _ as errors), _, _ ->
          refused (List.map (Reporting.Sources.report sources) errors)
      | [], (_ :: _ as warnings), _ ->
          refused (List.map (Reporting.Sources.warning sources) warnings)
      | [], [], None ->
          refused
            [
              Reporting.Sources.report sources
                (Reporting.Error.of_failure
                   (Diagnostic.Failure.about
                      (No_entry
                         {
                           module_name = "Main";
                           declaration = Dartea.Entry.declaration;
                         })));
            ]
      | ( [],
          [],
          Some
            ({
               Dartea.Entry.typ =
                 Typed.Type.TCustom
                   ( Data.Name.Global
                       { module_name = "Agent"; exported_name = "Task" },
                     [ _; _ ] );
               _;
             } as entry) ) ->
          let alive =
            Compiler.reach ~roots:[ Dartea.Compiler.entry_root entry ]
              outcome.modules
          in
          Ok
            (List.filter_map
               (fun (linked : Dartea.Compiler.linkable) ->
                 match
                   ( List.filter
                       (fun declaration ->
                         Dartea.Compiler.Reached.mem
                           ( linked.module_name,
                             Dartea.Compiler.name_of_declaration declaration )
                           alive)
                       linked.declarations,
                     linked.constructors )
                 with
                 | [], [] -> None
                 | reached, constructors ->
                     Some
                       {
                         module_name = linked.module_name;
                         declarations =
                           Ir.Of_optimized.convert ~arities:linked.arities
                             ~constructors ~siblings:linked.siblings reached;
                         constructors;
                       })
               outcome.modules)
      | [], [], Some entry ->
          refused
            [
              {
                Reporting.Report.title = "BAD MAIN TYPE";
                region = entry.region;
                suggestions = [];
                message =
                  Reporting.Doc.stack
                    [
                      Reporting.Doc.words "I cannot run `main`:";
                      Reporting.Snippet.of_region
                        (Reporting.Sources.source_of sources entry.region)
                        entry.region;
                      Reporting.Doc.words "Its type is:";
                      Reporting.Doc.indent 4
                        (Reporting.Doc.text (Reporting.Message.of_type entry.typ));
                      Reporting.Doc.words "But `main` must be a task from Agent:";
                      Reporting.Doc.indent 4 (Reporting.Doc.text "Task e a");
                      Reporting.Doc.words
                        "Hint: build it with `succeed`, `read`, `grep`, `andThen` and the other functions of Agent.";
                    ];
              };
            ]
