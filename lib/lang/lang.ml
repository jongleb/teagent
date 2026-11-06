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

let compile source =
  let outcome =
    Compiler.compile_modules ~entry:(Some "Main")
      (Project.Sources.of_list
         [
           Project.Elm_file.of_path ~path:"Agent.elm" Agent.source;
           Project.Elm_file.of_path ~path:"Main.elm" source;
         ])
  in
  let sources = Reporting.Sources.of_list outcome.sources in
  let refused reports =
    let hinted text =
      let contains piece =
        let rec at index =
          index + String.length piece <= String.length text
          && (String.equal (String.sub text index (String.length piece)) piece || at (index + 1))
        in
        at 0
      in
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
        ]
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
               match List.filter (fun piece -> not (contains piece)) pieces with
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
