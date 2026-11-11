open Lwt.Syntax

type t = {
  workspace : Tools.t;
  handler : Handler.Overlay.t Handler.t;
  serves : Os.call list;
  os : Os.t;
  on : Driver.event -> unit Lwt.t;
  waiting : (string, Run.hole) Hashtbl.t;  (** Runs stopped at a hole, by the name given out. *)
  mutable started : int;  (** How many runs this connection has begun. *)
  performed : Value.tool list ref;  (** The calls of this connection so far, newest first. *)
}

let start os shell ~on =
  let performed = ref [] in
  {
    workspace = Os.workspace os;
    handler =
      Handler.booted (Os.view os).boot ~class_of:(Os.class_of os)
        ~rules:(fun tool sources -> Os.decided os !performed tool sources)
        ~person:(fun _ -> Lwt.return Device.Declines)
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
        (Handler.staged (Os.workspace os) shell);
    serves = (Os.view os).offers;
    os;
    on;
    waiting = Hashtbl.create 4;
    started = 0;
    performed;
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
           when it ends. Returns stdout and stderr together, then the exit code."
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
            in scope; send the code for it with `fill`. Over MCP there is no person to ask, so \
            everything under \"What a person has to allow\" is refused.\n\n"
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
      | None -> (
          match (name, offered Os.Run) with
          | "fill", Some _ ->
              Result.bind (field "run") (fun run ->
                  Result.map (fun code -> `Fill (run, code)) (field "code"))
          | _ -> Error ("There is no tool called " ^ name ^ "."))
    in
    let applied staged =
      let outside, inside =
        List.partition
          (fun (change : Tools.change) -> Option.is_some (Tools.runner change))
          staged
      in
      let paths = List.map (fun (change : Tools.change) -> (change.path :> string)) in
      let* () =
        match outside with
        | [] -> Lwt.return_unit
        | _ :: _ -> program.on (Held { diff = Handler.Overlay.diff outside; decision = Discard })
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
                "\n\nNot written, because other programs run them outside the sandbox and only \
                 a person at teagent's own prompt can allow that: "
                ^ String.concat ", " withheld)
            (match withheld with [] -> false | _ :: _ -> true)
      | Error reason -> text (body ^ "\n\nNot applied, nothing was written: " ^ reason) true
    in
    let rec went run =
      let dropped body =
        let* () = program.on (Decided Discard) in
        Lwt.return (text (body ^ "\n\nThe changes of this run were dropped.") true)
      in
      match Os.exposure program.os (Run.calls run) with
      | Some { reads; inward; outward } ->
          let summary =
            Printf.sprintf
              "read the project (%s), take in text from outside (%s) and send data out (%s)"
              (String.concat ", " reads) (String.concat ", " inward) (String.concat ", " outward)
          in
          let* () = program.on (Exposed { summary; decision = Discard }) in
          Lwt.return
            (text
               ("Refused: this program would " ^ summary
              ^ ". A program that does all three can leak the project, and over MCP there is \
                 no person to say yes. Split the work so no program does all three.")
               true)
      | None ->
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
          let version =
            match List.assoc_opt "params" fields with
            | Some (`Assoc params) -> (
                match List.assoc_opt "protocolVersion" params with
                | Some (`String version) -> version
                | Some _ | None -> "2025-06-18")
            | Some _ | None -> "2025-06-18"
          in
          Lwt.return
            (Some
               (reply id
                  (`Assoc
                    [
                      ("protocolVersion", `String version);
                      ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
                      ("serverInfo", `Assoc [ ("name", `String "teagent"); ("version", `String "0.1.0") ]);
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
      | None, Some id ->
          Lwt.return
            (Some
               (`Assoc
                 [
                   ("jsonrpc", `String "2.0");
                   ("id", id);
                   ("error", `Assoc [ ("code", `Int (-32600)); ("message", `String "Invalid request") ]);
                 ])))
  | _ -> Lwt.return None
