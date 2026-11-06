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
    Error
      (String.concat "\n\n"
         (List.map (Reporting.Report.to_string ~colours:false) reports))
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
