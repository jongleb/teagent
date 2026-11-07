open Lwt.Syntax

type tool = Bash | Read | Write | Edit | Grep

let tools = [ ("bash", Bash); ("read", Read); ("write", Write); ("edit", Edit); ("grep", Grep) ]

type t = {
  workspace : Tools.t;
  handler : Handler.Overlay.t Handler.t;
  serves : tool list;
  on : Driver.event -> unit Lwt.t;
}

let start workspace shell ~serves ~on =
  { workspace; handler = Handler.staged workspace shell; serves; on }

let handled program json =
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
    let tool name description input =
      ( List.assoc name tools,
        `Assoc [ ("name", `String name); ("description", `String description); ("inputSchema", input) ] )
    in
    List.filter_map
      (fun (kind, listed) -> Option.map (fun _ -> listed) (List.find_opt (( = ) kind) program.serves))
      [
        tool "bash"
          "Run a shell command with /bin/sh in a sandboxed copy of the project: no network, no \
           writes outside the copy. Files the command writes or deletes are applied to the project \
           when it ends. Returns stdout and stderr together, then the exit code."
          (schema [ ("command", "The command to run, as you would type it in sh.") ] [ "command" ]);
        tool "read" "Read a file of the project. Paths are relative to the project folder."
          (schema [ ("path", "The file, relative to the project folder.") ] [ "path" ]);
        tool "write"
          "Write a whole file, creating folders as needed. A file the user changed meanwhile is \
           never overwritten."
          (schema
             [ ("path", "The file, relative to the project folder."); ("content", "The full new text.") ]
             [ "path"; "content" ]);
        tool "edit"
          "Replace the one place in a file where old_string appears with new_string. Fails if \
           old_string is missing or appears more than once."
          (schema
             [
               ("path", "The file, relative to the project folder.");
               ("old_string", "The exact text to replace; it must appear once.");
               ("new_string", "The text to put in its place.");
             ]
             [ "path"; "old_string"; "new_string" ]);
        tool "grep"
          "Find the lines that match an Emacs-style regular expression (write a\\|b for 'a or b') \
           in files whose path matches a glob such as src/**/*.ml."
          (schema
             [
               ("pattern", "The regular expression.");
               ("glob", "Which files to search, such as src/**/*.ml; ** by default.");
             ]
             [ "pattern" ]);
      ]
  in
  let reply id result = `Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ] in
  let text body failed =
    `Assoc
      [
        ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String body) ] ]);
        ("isError", `Bool failed);
      ]
  in
  let called arguments name =
    let field key =
      match List.assoc_opt key arguments with
      | Some (`String value) -> Ok value
      | Some _ | None -> Error ("The argument " ^ key ^ " is missing or not text.")
    in
    let requested : (Value.tool, string) result =
      match
        Option.bind (List.assoc_opt name tools) (fun kind ->
            List.find_opt (( = ) kind) program.serves)
      with
      | Some Bash -> Result.map (fun command -> Value.Shell command) (field "command")
      | Some Read -> Result.map (fun path -> Value.Read path) (field "path")
      | Some Write ->
          Result.bind (field "path") (fun path ->
              Result.map (fun content -> Value.Write { path; content }) (field "content"))
      | Some Edit ->
          Result.bind (field "path") (fun path ->
              Result.bind (field "old_string") (fun old ->
                  Result.map (fun new_ -> Value.Edit { path; old; new_ }) (field "new_string")))
      | Some Grep ->
          Result.map
            (fun pattern ->
              Value.Grep { pattern; glob = Result.value ~default:"**" (field "glob") })
            (field "pattern")
      | None -> Error ("There is no tool called " ^ name ^ ".")
    in
    match requested with
    | Error reason -> Lwt.return (text reason true)
    | Ok tool -> (
        let* step = program.handler.perform tool Handler.Overlay.empty in
        match step with
        | Handler.Blocked -> Lwt.return (text "The tool was held back; try again." true)
        | Handler.Performed (result, overlay) ->
            let staged = Handler.Overlay.changes overlay in
            let* () = program.on (Performed { tool; result; staged }) in
            let* applied =
              match staged with
              | [] -> Lwt.return (Ok [])
              | _ :: _ ->
                  let* committed = Tools.commit program.workspace staged in
                  let applied =
                    Result.map_error
                      (function
                        | `Tools (Tools.Denied path) -> path ^ " is off limits"
                        | `Tools (Tools.Not_found reason | Conflict reason) -> reason)
                      committed
                  in
                  let* () = program.on (Committed applied) in
                  Lwt.return
                    (Result.map
                       (fun () ->
                         List.map (fun (change : Tools.change) -> (change.path :> string)) staged)
                       applied)
            in
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
              (match (result, applied) with
              | Error _, _ -> text body true
              | Ok _, Ok [] -> text body false
              | Ok _, Ok paths -> text (body ^ "\n\nApplied to the project: " ^ String.concat ", " paths) false
              | Ok _, Error reason ->
                  text (body ^ "\n\nNot applied, nothing was written: " ^ reason) true))
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
