open Lwt.Syntax

(** Whether the client can put a question to its user. *)
type client =
  | Mute  (** It cannot: every question is answered no. *)
  | Elicits  (** It takes [elicitation/create] and shows the question to the person. *)

type t = {
  workspace : Tools.t;
  handler : Handler.Overlay.t Handler.t;
  serves : Os.call list;
  mutable os : Os.t;  (** Replaced when the agent saves a module. *)
  on : Driver.event -> unit Lwt.t;
  waiting : (string, Run.hole) Hashtbl.t;  (** Runs stopped at a hole, by the name given out. *)
  mutable started : int;  (** How many runs this connection has begun. *)
  performed : Value.tool list ref;  (** The calls of this connection so far, newest first. *)
  client : client ref;
  asking : (int, Device.consent Lwt.u) Hashtbl.t;  (** Questions sent to the client, by request id. *)
  person : string -> Device.consent Lwt.t;
}

let start os tools ~send ~on =
  let performed = ref [] in
  let client = ref Mute in
  let asking = Hashtbl.create 4 in
  let asked = ref 0 in
  let person question =
    match !client with
    | Mute -> Lwt.return Device.Declines
    | Elicits ->
        incr asked;
        let id = !asked in
        let answer, answered = Lwt.wait () in
        Hashtbl.replace asking id answered;
        let* () =
          send
            (`Assoc
              [
                ("jsonrpc", `String "2.0");
                ("id", `Int id);
                ("method", `String "elicitation/create");
                ( "params",
                  `Assoc
                    [
                      ( "message",
                        `String
                          ("teagent asks you, not the agent. Allow it to " ^ question
                          ^ "?\n\nAccept lets it go ahead; decline or cancel stops it.") );
                      ("requestedSchema", `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ]);
                    ] );
              ])
        in
        answer
  in
  {
    workspace = Os.workspace os;
    handler =
      Handler.booted (Os.view os).boot ~class_of:(Os.class_of os)
        ~rules:(fun tool sources -> Os.decided os !performed tool sources)
        ~person
        ~journal:(fun (inner : Handler.Overlay.t Handler.t) ->
          {
            perform =
              (fun tool sources overlay ->
                let* step = inner.perform tool sources overlay in
                let* () =
                  match step with
                  | Handler.Performed (result, after) ->
                      performed := tool :: !performed;
                      on (Driver.Performed { tool; result; staged = Handler.Overlay.since overlay after })
                  | Handler.Blocked -> Lwt.return_unit
                  | Handler.Exhausted -> on (Driver.Exhausted tool)
                in
                Lwt.return step);
          })
        tools;
    serves = (Os.view os).offers;
    os;
    on;
    waiting = Hashtbl.create 4;
    started = 0;
    performed;
    client;
    asking;
    person;
  }

let handled program json =
  let offered kind = List.find_opt (( = ) kind) program.serves in
  let listed =
    let schema properties required =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            `Assoc
              (List.map
                 (fun (name, description) ->
                   (name, `Assoc [ ("type", `String "string"); ("description", `String description) ]))
                 properties) );
          ("required", `List (List.map (fun name -> `String name) required));
          ("additionalProperties", `Bool false);
        ]
    in
    let tool kind name description input =
      ( kind,
        `Assoc [ ("name", `String name); ("description", `String description); ("inputSchema", input) ] )
    in
    List.filter_map
      (fun (kind, listed) -> Option.map (fun _ -> listed) (offered kind))
      [
        tool Os.Bash "bash"
          "Run a shell command with /bin/sh in a sandboxed copy of the project: no network, no \
           writes outside the copy. Files the command writes or deletes are applied to the project \
           when it ends, except names starting with a dot, _build, node_modules and Python caches. Returns stdout and stderr together, then the exit code."
          (schema [ ("command", "The command to run, as you would type it in sh.") ] [ "command" ]);
        tool Os.Read "read" "Read a file of the project. Paths are relative to the project folder."
          (schema [ ("path", "The file, relative to the project folder.") ] [ "path" ]);
        tool Os.Write "write"
          "Write a whole file, creating folders as needed. A file the user changed meanwhile is \
           never overwritten."
          (schema
             [ ("path", "The file, relative to the project folder."); ("content", "The full new text.") ]
             [ "path"; "content" ]);
        tool Os.Edit "edit"
          "Replace the one place in a file where old_string appears with new_string. Fails if \
           old_string is missing or appears more than once."
          (schema
             [
               ("path", "The file, relative to the project folder.");
               ("old_string", "The exact text to replace; it must appear once.");
               ("new_string", "The text to put in its place.");
             ]
             [ "path"; "old_string"; "new_string" ]);
        tool Os.Grep "grep"
          "Find the lines that match a regular expression in files whose path matches a glob \
           such as src/**/*.ml. The expression knows . * + ? [...] ^ $ | (...) \\d \\s \\w \\b; \
           a backslash makes a character literal; there is no {n,m}. Returns path:line: text, \
           lines counted from 1. Names starting with a dot, _build and node_modules are not \
           searched."
          (schema
             [
               ("pattern", "The regular expression.");
               ("glob", "Which files to search, such as src/**/*.ml; ** by default.");
             ]
             [ "pattern" ]);
        tool Os.Run "run"
          ("Run a program instead of calling tools one by one. Send the whole Main module as \
            `program`. teagent typechecks it, runs it against the project, and writes its \
            changes together if main succeeds; the reply holds every compiler report, or the \
            value of main and the files written. A `hole` stops the run and returns the values \
            in scope; send the code for it with `fill`. What is under \"What a person has to \
            allow\" is asked of the user through your client, not of you; a client that cannot \
            ask them gets no.\n\n"
          ^ Manual.text
          ^ "\n## The modules\n\nAgent, and drivers such as Fetch, which a program imports by \
             name (`import Fetch`):\n\n"
          ^ Lang.Calls.source (Os.table program.os))
          (schema [ ("program", "The whole Main module.") ] [ "program" ]);
        tool Os.Run "fill"
          "Give the code for the hole a run stopped at: one Elm expression of the hole's type, \
           which may use the values in scope there. The run starts again with it; the tools \
           that already ran are not run twice."
          (schema
             [
               ("run", "The run, as `run` named it.");
               ("code", "The Elm expression that takes the place of the hole.");
             ]
             [ "run"; "code" ]);
        tool Os.Run "search"
          "Find the calls of the HTTP APIs this session offers, the modules listed with a number \
           of calls, by words such as `list issues` or `create pull request`. Returns their Elm \
           signatures, what each does, and the record types they name; a type's name as the query \
           returns that type."
          (schema [ ("query", "Words to look for, or the name of a type.") ] [ "query" ]);
        tool Os.Run "save"
          "Keep a module that worked, so later programs import it instead of writing it again. \
           Send the whole module, `module Name exposing (...)` with its imports. It must \
           typecheck against the calls this session offers, and it is typechecked again in every \
           program that imports it, so a module the project outgrew fails before anything runs. \
           Saving a name again replaces that module; the names of the person's skills are \
           refused. Saved modules are kept in .teagent/saved and installed in later sessions."
          (schema
             [ ("name", "The module name, such as Testing."); ("module", "The whole Elm module.") ]
             [ "name"; "module" ]);
      ]
  in
  let reply id result = `Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ] in
  let text body failed =
    `Assoc
      [
        ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String (Tools.redacted body)) ] ]);
        ("isError", `Bool failed);
      ]
  in
  let called arguments name =
    let field key =
      match List.assoc_opt key arguments with
      | Some (`String value) -> Ok value
      | Some _ | None -> Error ("The argument " ^ key ^ " is missing or not text.")
    in
    let requested =
      match Option.bind (List.assoc_opt name Os.calls) offered with
      | Some Os.Bash -> Result.map (fun command -> `Tool (Value.Shell command)) (field "command")
      | Some Read -> Result.map (fun path -> `Tool (Value.Read path)) (field "path")
      | Some Write ->
          Result.bind (field "path") (fun path ->
              Result.map (fun content -> `Tool (Value.Write { path; content })) (field "content"))
      | Some Edit ->
          Result.bind (field "path") (fun path ->
              Result.bind (field "old_string") (fun old ->
                  Result.map (fun new_ -> `Tool (Value.Edit { path; old; new_ })) (field "new_string")))
      | Some Grep ->
          Result.map
            (fun pattern ->
              `Tool (Value.Grep { pattern; glob = Result.value ~default:"**" (field "glob") }))
            (field "pattern")
      | Some Run -> Result.map (fun source -> `Run source) (field "program")
      | Some Fetch -> Error "fetch is not a tool of its own: a program sent to run reaches it as Fetch.get."
      | Some Model -> Error "model is not a tool of its own: a program sent to run reaches it as Model.judge."
      | None -> (
          match (name, offered Os.Run) with
          | "fill", Some _ ->
              Result.bind (field "run") (fun run ->
                  Result.map (fun code -> `Fill (run, code)) (field "code"))
          | "search", Some _ -> Result.map (fun query -> `Search query) (field "query")
          | "save", Some _ ->
              Result.bind (field "name") (fun name ->
                  Result.map (fun source -> `Save (name, source)) (field "module"))
          | _ -> Error ("There is no tool called " ^ name ^ "."))
    in
    let applied staged =
      let outside, inside =
        List.partition
          (fun (change : Tools.change) -> Option.is_some (Tools.runner change))
          staged
      in
      let paths = List.map (fun (change : Tools.change) -> (change.path :> string)) in
      let* held =
        match outside with
        | [] -> Lwt.return Driver.Apply
        | _ :: _ ->
            let diff = Handler.Overlay.diff outside in
            let* consent =
              program.person
                ("write files that run outside the sandbox after this session ("
                ^ String.concat ", "
                    (List.filter_map
                       (fun (change : Tools.change) ->
                         Option.map
                           (fun runner -> (change.path :> string) ^ ", run by " ^ runner)
                           (Tools.runner change))
                       outside)
                ^ "):\n\n" ^ diff)
            in
            let decision = match consent with Device.Agrees -> Driver.Apply | Declines -> Discard in
            let+ () = program.on (Held { diff; decision }) in
            decision
      in
      let inside, outside =
        match held with Driver.Apply -> (inside @ outside, []) | Discard -> (inside, outside)
      in
      match inside with
      | [] -> Lwt.return (Ok ([], paths outside))
      | _ :: _ ->
          let* committed = Tools.commit program.workspace inside in
          let applied =
            Result.map_error
              (function
                | `Tools (Tools.Denied path) -> path ^ " is off limits"
                | `Tools (Tools.Not_found reason | Conflict reason) -> reason)
              committed
          in
          let* () =
            program.on
              (Committed
                 (Result.map (fun () -> List.map (fun (change : Tools.change) -> change.path) inside) applied))
          in
          Lwt.return (Result.map (fun () -> (paths inside, paths outside)) applied)
    in
    let reported body = function
      | Ok (written, withheld) ->
          text
            (body
            ^ (match written with
              | [] -> ""
              | _ :: _ -> "\n\nApplied to the project: " ^ String.concat ", " written)
            ^
            match withheld with
            | [] -> ""
            | _ :: _ ->
                "\n\nNot written, because other programs run them outside the sandbox and the \
                 person did not allow it (a client without elicitation cannot ask them): "
                ^ String.concat ", " withheld)
            (match withheld with [] -> false | _ :: _ -> true)
      | Error reason -> text (body ^ "\n\nNot applied, nothing was written: " ^ reason) true
    in
    let dropped body =
      let* () = program.on (Decided Discard) in
      Lwt.return (text (body ^ "\n\nThe changes of this run were dropped.") true)
    in
    let rec went run =
      match Os.exposure program.os (Run.calls run) with
      | Some { reads; inward; outward } -> (
          let summary =
            Printf.sprintf
              "read the project (%s), take in text from outside (%s) and send data out (%s)"
              (String.concat ", " reads) (String.concat ", " inward) (String.concat ", " outward)
          in
          let* consent = program.person summary in
          let decision = match consent with Device.Agrees -> Driver.Apply | Declines -> Discard in
          let* () = program.on (Exposed { summary; decision }) in
          match decision with
          | Driver.Apply -> performed run
          | Discard ->
              Lwt.return
                (text
                   ("Refused: this program would " ^ summary
                  ^ ". A program that does all three can leak the project, and the person did \
                     not allow it (a client without elicitation cannot ask them). Split the work \
                     so no program does all three.")
                   true))
      | None -> performed run
    and performed run =
        let* outcome =
          Run.run run ~seen:(List.concat_map Value.sources !(program.performed)) program.handler ~settle:(fun overlay ->
              Lwt.map (Result.map ignore) (applied (Handler.Overlay.changes overlay)))
        in
        match outcome with
        | Error reason -> dropped ("The changes could not be applied: " ^ reason)
        | Ok (Finished (Ok value), overlay) ->
            let body = "main finished with:\n" ^ Value.to_elm value in
            let* () = program.on (Ran body) in
            Lwt.map (reported body) (applied (Handler.Overlay.changes overlay))
        | Ok (Finished (Error (`Failed value)), _) ->
            dropped ("main failed with:\n" ^ Value.to_elm value)
        | Ok (Finished (Error ((`Interp _ | `Exhausted) as stop)), _) -> dropped (Run.stopped stop)
        | Ok (Unfillable reason, _) -> dropped reason
        | Ok (Reached hole, _) ->
            program.started <- program.started + 1;
            let name = Printf.sprintf "run-%d" program.started in
            Hashtbl.replace program.waiting name hole;
            let* () = program.on (Decided Discard) in
            Lwt.return
              (text
                 (Run.question hole ^ "\n\nCall `fill` with run \"" ^ name
                ^ "\" and that expression as code; until then nothing of this run is applied.")
                 false)
    and resumed name code =
      match Hashtbl.find_opt program.waiting name with
      | None -> Lwt.return (text ("No run called " ^ name ^ " is waiting for a hole.") true)
      | Some hole -> (
          match Run.filled hole code with
          | Error report ->
              Lwt.return
                (text ("That code does not compile in place of the hole:\n\n" ^ report) true)
          | Ok run ->
              Hashtbl.remove program.waiting name;
              let* () = program.on (Filled { hole = Run.description hole; reply = code }) in
              let* () =
                Lwt_list.iter_s
                  (fun ({ tool; result; staged; _ } : Run.step) ->
                    program.on (Performed { tool; result; staged }))
                  (Run.performed hole)
              in
              went run)
    in
    match requested with
    | Error reason -> Lwt.return (text reason true)
    | Ok (`Run source) -> (
        let* () = program.on (Wrote source) in
        match Run.compiled (Os.table program.os) source with
        | Error report ->
            let* () = program.on (Refused report) in
            Lwt.return (text report true)
        | Ok run -> went run)
    | Ok (`Fill (name, code)) -> resumed name code
    | Ok (`Search query) ->
        let contains text piece =
          let rec at index =
            index + String.length piece <= String.length text
            && (String.equal (String.sub text index (String.length piece)) piece || at (index + 1))
          in
          at 0
        in
        let words =
          List.filter
            (fun word -> String.length word > 0)
            (String.split_on_char ' ' (String.lowercase_ascii query))
        in
        let apis = (Os.view program.os).apis in
        let found =
          List.filteri
            (fun index _ -> index < 8)
            (List.stable_sort
               (fun (one, _, _) (other, _, _) -> compare other one)
               (List.concat_map
                  (fun api ->
                    List.filter_map
                      (fun (operation : Api.operation) ->
                        let haystack =
                          String.lowercase_ascii
                            (String.concat " " [ operation.key; operation.summary; operation.path ])
                        in
                        match List.length (List.filter (contains haystack) words) with
                        | 0 -> None
                        | score -> Some (score, api, operation))
                      (Api.operations api))
                  apis))
        in
        let types =
          List.sort_uniq compare
            (List.concat_map
               (fun api ->
                 List.filter_map
                   (fun name -> Option.map (fun declaration -> (Api.name api, declaration)) (Api.declaration api name))
                   (String.split_on_char ' ' query
                   @ List.concat_map
                       (fun (_, (other : Api.t), operation) ->
                         match String.equal (Api.name other) (Api.name api) with
                         | false -> []
                         | true ->
                             String.split_on_char ' '
                               (String.map
                                  (function ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_') as kept -> kept | _ -> ' ')
                                  (Api.signature operation)))
                       (List.filteri (fun index _ -> index < 2) found)))
               apis)
        in
        Lwt.return
          (match (found, types) with
          | [], [] -> text ("Nothing matches " ^ query ^ ".") true
          | _, _ ->
              text
                (String.concat "\n\n"
                   (List.map
                      (fun (_, api, (operation : Api.operation)) ->
                        "-- " ^ Api.method_name operation.meth ^ " " ^ operation.path
                        ^ (match operation.summary with "" -> "" | summary -> ": " ^ summary)
                        ^ "\n" ^ Api.name api ^ "." ^ Api.signature operation)
                      found
                   @ List.map (fun (module_name, declaration) -> "-- in " ^ module_name ^ "\n" ^ declaration) types)
                ^ "\n\nA call with options takes a record of them as its last argument; start from \
                   the value named after the call with Options at the end, which sets every option \
                   to Nothing.")
                false)
    | Ok (`Save (name, source)) -> (
        match Result.bind (Lang.Skill.of_source ~name source) (fun skill -> Os.learned skill program.os) with
        | Error report -> Lwt.return (text ("Not saved:\n\n" ^ report) true)
        | Ok os -> (
            let* kept = Tools.keep program.workspace ~name source in
            match kept with
            | Error (`Tools (Tools.Denied reason | Not_found reason | Conflict reason)) ->
                Lwt.return (text ("Not saved: " ^ reason) true)
            | Ok () ->
                program.os <- os;
                let* () = program.on (Saved { name; source }) in
                Lwt.return
                  (text
                     (Printf.sprintf
                        "Saved as .teagent/saved/%s.elm. Programs import it with `import %s`, in \
                         this session and later ones."
                        name name)
                     false)))
    | Ok (`Tool tool) -> (
        let* step = program.handler.perform tool [] Handler.Overlay.empty in
        match step with
        | Handler.Blocked -> Lwt.return (text "The tool was held back; try again." true)
        | Handler.Exhausted ->
            Lwt.return (text "This OS allows no more tool calls in the session." true)
        | Handler.Performed (result, overlay) ->
            let staged = Handler.Overlay.changes overlay in
            let* applied = applied staged in
            let body =
              match (tool, result) with
              | Read _, Ok (V_string content) -> content
              | Shell _, Ok (V_record [ ("code", V_number code); ("out", V_string out) ]) ->
                  Printf.sprintf "%s\n[exit code %.0f]" out code
              | Grep _, Ok (V_list found) ->
                  String.concat "\n"
                    (List.map
                       (function
                         | Value.V_record
                             [ ("line", V_number line); ("path", V_string path); ("text", V_string line_text) ]
                           ->
                             Printf.sprintf "%s:%.0f: %s" path line line_text
                         | other -> Value.to_elm other)
                       found)
              | (Write _ | Edit _), Ok _ -> "Done."
              | _, (Ok value | Error value) -> Value.to_elm value
            in
            Lwt.return
              (match result with
              | Error _ -> text body true
              | Ok _ -> reported body applied))
  in
  match json with
  | `Assoc fields -> (
      match (List.assoc_opt "method" fields, List.assoc_opt "id" fields) with
      | Some (`String "initialize"), Some id ->
          program.client :=
            (match List.assoc_opt "params" fields with
            | Some (`Assoc params) -> (
                match List.assoc_opt "capabilities" params with
                | Some (`Assoc capabilities) ->
                    Option.fold ~none:Mute ~some:(fun _ -> Elicits) (List.assoc_opt "elicitation" capabilities)
                | Some _ | None -> Mute)
            | Some _ | None -> Mute);
          let protocol =
            match List.assoc_opt "params" fields with
            | Some (`Assoc params) -> (
                match List.assoc_opt "protocolVersion" params with
                | Some (`String protocol) -> protocol
                | Some _ | None -> "2025-06-18")
            | Some _ | None -> "2025-06-18"
          in
          Lwt.return
            (Some
               (reply id
                  (`Assoc
                    [
                      ("protocolVersion", `String protocol);
                      ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
                      ("serverInfo", `Assoc [ ("name", `String "teagent"); ("version", `String Version.number) ]);
                      ( "instructions",
                        `String
                          "Use these tools for every change to the project and every command. \
                           Commands run in a sandboxed copy without network; what they change is \
                           applied when they end. Every change is logged and the user can undo \
                           the whole session with one command." );
                    ])))
      | Some (`String "ping"), Some id -> Lwt.return (Some (reply id (`Assoc [])))
      | Some (`String "tools/list"), Some id ->
          Lwt.return (Some (reply id (`Assoc [ ("tools", `List listed) ])))
      | Some (`String "tools/call"), Some id ->
          let name, arguments =
            match List.assoc_opt "params" fields with
            | Some (`Assoc params) ->
                ( (match List.assoc_opt "name" params with Some (`String name) -> name | _ -> ""),
                  match List.assoc_opt "arguments" params with
                  | Some (`Assoc arguments) -> arguments
                  | _ -> [] )
            | Some _ | None -> ("", [])
          in
          let+ result = called arguments name in
          Some (reply id result)
      | Some _, Some id ->
          Lwt.return
            (Some
               (`Assoc
                 [
                   ("jsonrpc", `String "2.0");
                   ("id", id);
                   ( "error",
                     `Assoc [ ("code", `Int (-32601)); ("message", `String "Method not found") ] );
                 ]))
      | _, None -> Lwt.return None
      | None, Some id -> (
          match
            Option.bind
              (match id with `Int id -> Some id | _ -> None)
              (fun id -> Option.map (fun answered -> (id, answered)) (Hashtbl.find_opt program.asking id))
          with
          | Some (id, answered) ->
              Hashtbl.remove program.asking id;
              Lwt.wakeup_later answered
                (match List.assoc_opt "result" fields with
                | Some (`Assoc result) -> (
                    match List.assoc_opt "action" result with
                    | Some (`String "accept") -> Device.Agrees
                    | Some _ | None -> Declines)
                | Some _ | None -> Declines);
              Lwt.return None
          | None ->
          Lwt.return
            (Some
               (`Assoc
                 [
                   ("jsonrpc", `String "2.0");
                   ("id", id);
                   ("error", `Assoc [ ("code", `Int (-32600)); ("message", `String "Invalid request") ]);
                 ]))))
  | _ -> Lwt.return None
