(** Local variables of a running program, by name. *)
module Scope = Map.Make (String)

(** A top-level name: a declaration or a constructor of [module_name]. *)
type global = { module_name : string; name : string }

(** A runtime value of a Dartea program. *)
type t =
  | V_number of float  (** Int and Float alike, as in Dartea's JavaScript runtime. *)
  | V_string of string
  | V_char of string
  | V_bool of bool
  | V_unit
  | V_list of t list
  | V_tuple of t list
  | V_record of (string * t) list  (** Fields sorted by label. *)
  | V_constr of { constructor : global; arguments : t list }
  | V_closure of closure
  | V_task of task

(** A function: [body] runs in [scope]; top-level names resolve against [home]. *)
and closure = {
  home : string;
  parameters : string list;
  scope : t Scope.t;
  body : Ir.Ast.term;
}

(** A description of effects; nothing runs until a handler interprets it. *)
and task =
  | Succeed of t
  | Fail of t
  | Tool of tool
  | And_then of { callback : closure; task : task }
  | Map of { callback : closure; task : task }
  | Map_err of { callback : closure; task : task }
  | On_error of { callback : closure; task : task }
  | Batch of task list
  | Hole of hole

(** A place the program left for the agent to fill once it is reached. *)
and hole = { description : string; locals : t Scope.t  (** Values in scope where it was reached. *) }

(** One effect the agent asks the harness to perform. *)
and tool =
  | Read of string
  | Write of { path : string; content : string }
  | Edit of { path : string; old : string; new_ : string }
  | Grep of { pattern : string; glob : string }
  | Shell of string
  | Call of { name : string; argument : t }  (** A call a driver answers, such as [fetch.get]. *)
  | Enter of (Tools.Path.t * Tools.mount) list  (** A child process begins, narrower by these. *)
  | Leave  (** The child process ends; its changes come back as a value. *)
  | Merge of patch list  (** A child's changes, taken only if nothing moved under them. *)

(** A file a child changed: what it held when the child began, and what the child left. *)
and patch = { file : string; base : string option; content : string option }

let rec to_elm (value : t) =
  let nested (value : t) =
    match value with
    | V_constr { arguments = _ :: _; _ } -> "(" ^ to_elm value ^ ")"
    | V_number _ | V_string _ | V_char _ | V_bool _ | V_unit | V_list _ | V_tuple _
    | V_record _ | V_constr { arguments = []; _ } | V_closure _ | V_task _ ->
        to_elm value
  in
  match value with
  | V_number number when Float.is_integer number && Float.abs number < 1e15 ->
      Printf.sprintf "%.0f" number
  | V_number number -> Printf.sprintf "%.17g" number
  | V_string text ->
      let buffer = Buffer.create (String.length text + 2) in
      Buffer.add_char buffer '"';
      String.iter
        (function
          | '"' -> Buffer.add_string buffer "\\\""
          | '\\' -> Buffer.add_string buffer "\\\\"
          | '\n' -> Buffer.add_string buffer "\\n"
          | '\t' -> Buffer.add_string buffer "\\t"
          | '\r' -> Buffer.add_string buffer "\\r"
          | char -> Buffer.add_char buffer char)
        text;
      Buffer.add_char buffer '"';
      Buffer.contents buffer
  | V_char char -> "'" ^ char ^ "'"
  | V_bool true -> "True"
  | V_bool false -> "False"
  | V_unit -> "()"
  | V_list [] -> "[]"
  | V_list items -> "[ " ^ String.concat ", " (List.map to_elm items) ^ " ]"
  | V_tuple items -> "( " ^ String.concat ", " (List.map to_elm items) ^ " )"
  | V_record [] -> "{}"
  | V_record fields ->
      "{ "
      ^ String.concat ", "
          (List.map (fun (label, value) -> label ^ " = " ^ to_elm value) fields)
      ^ " }"
  | V_constr { constructor = { name; _ }; arguments } ->
      String.concat " " (name :: List.map nested arguments)
  | V_closure _ -> "<function>"
  | V_task _ -> "<task>"

let rec to_json (value : t) : Yojson.Safe.t =
  match value with
  | V_number number -> `Assoc [ ("number", `Float number) ]
  | V_string text -> `Assoc [ ("string", `String text) ]
  | V_char char -> `Assoc [ ("char", `String char) ]
  | V_bool truth -> `Assoc [ ("bool", `Bool truth) ]
  | V_unit -> `Assoc [ ("unit", `Null) ]
  | V_list items -> `Assoc [ ("list", `List (List.map to_json items)) ]
  | V_tuple items -> `Assoc [ ("tuple", `List (List.map to_json items)) ]
  | V_record fields ->
      `Assoc [ ("record", `Assoc (List.map (fun (label, value) -> (label, to_json value)) fields)) ]
  | V_constr { constructor = { module_name; name }; arguments } ->
      `Assoc
        [
          ( "constr",
            `Assoc
              [
                ("module", `String module_name);
                ("name", `String name);
                ("arguments", `List (List.map to_json arguments));
              ] );
        ]
  | V_closure _ | V_task _ -> `Assoc [ ("opaque", `Null) ]

let rec of_json (json : Yojson.Safe.t) : (t, string) result =
  let all items =
    List.fold_right
      (fun item collected ->
        Result.bind collected (fun rest -> Result.map (fun value -> value :: rest) (of_json item)))
      items (Ok [])
  in
  match json with
  | `Assoc [ ("number", `Float number) ] -> Ok (V_number number)
  | `Assoc [ ("number", `Int number) ] -> Ok (V_number (Float.of_int number))
  | `Assoc [ ("string", `String text) ] -> Ok (V_string text)
  | `Assoc [ ("char", `String char) ] -> Ok (V_char char)
  | `Assoc [ ("bool", `Bool truth) ] -> Ok (V_bool truth)
  | `Assoc [ ("unit", `Null) ] -> Ok V_unit
  | `Assoc [ ("list", `List items) ] -> Result.map (fun items -> V_list items) (all items)
  | `Assoc [ ("tuple", `List items) ] -> Result.map (fun items -> V_tuple items) (all items)
  | `Assoc [ ("record", `Assoc fields) ] ->
      Result.map
        (fun values -> V_record (List.combine (List.map fst fields) values))
        (all (List.map snd fields))
  | `Assoc
      [
        ( "constr",
          `Assoc
            [ ("module", `String module_name); ("name", `String name); ("arguments", `List items) ]
        );
      ] ->
      Result.map
        (fun arguments -> V_constr { constructor = { module_name; name }; arguments })
        (all items)
  | other -> Error ("not a recorded value: " ^ Yojson.Safe.to_string other)

let tool_to_json (tool : tool) : Yojson.Safe.t =
  match tool with
  | Read path -> `Assoc [ ("read", `String path) ]
  | Write { path; content } ->
      `Assoc [ ("write", `Assoc [ ("path", `String path); ("content", `String content) ]) ]
  | Edit { path; old; new_ } ->
      `Assoc
        [
          ( "edit",
            `Assoc [ ("path", `String path); ("old", `String old); ("new", `String new_) ] );
        ]
  | Grep { pattern; glob } ->
      `Assoc [ ("grep", `Assoc [ ("pattern", `String pattern); ("glob", `String glob) ]) ]
  | Shell command -> `Assoc [ ("shell", `String command) ]
  | Call { name; argument } ->
      `Assoc [ ("call", `Assoc [ ("name", `String name); ("argument", to_json argument) ]) ]
  | Enter mounts ->
      `Assoc
        [
          ( "enter",
            `List
              (List.map
                 (fun ((path : Tools.Path.t), (mount : Tools.mount)) ->
                   `Assoc
                     [
                       ("path", `String (path :> string));
                       ( "mount",
                         `String
                           (match mount with
                           | Hidden -> "hidden"
                           | Readonly -> "readonly"
                           | Scratch -> "scratch") );
                     ])
                 mounts) );
        ]
  | Leave -> `Assoc [ ("leave", `Null) ]
  | Merge patches ->
      let text = Option.fold ~none:`Null ~some:(fun text -> `String text) in
      `Assoc
        [
          ( "merge",
            `List
              (List.map
                 (fun { file; base; content } ->
                   `Assoc [ ("file", `String file); ("base", text base); ("content", text content) ])
                 patches) );
        ]

let tool_of_json (json : Yojson.Safe.t) : (tool, string) result =
  match json with
  | `Assoc [ ("read", `String path) ] -> Ok (Read path)
  | `Assoc [ ("write", `Assoc [ ("path", `String path); ("content", `String content) ]) ] ->
      Ok (Write { path; content })
  | `Assoc
      [ ("edit", `Assoc [ ("path", `String path); ("old", `String old); ("new", `String new_) ]) ]
    ->
      Ok (Edit { path; old; new_ })
  | `Assoc [ ("grep", `Assoc [ ("pattern", `String pattern); ("glob", `String glob) ]) ] ->
      Ok (Grep { pattern; glob })
  | `Assoc [ ("shell", `String command) ] -> Ok (Shell command)
  | `Assoc [ ("call", `Assoc [ ("name", `String name); ("argument", argument) ]) ] ->
      Result.map (fun argument -> Call { name; argument }) (of_json argument)
  | `Assoc [ ("enter", `List mounts) ] ->
      List.fold_right
        (fun mount collected ->
          Result.bind collected (fun rest ->
              match mount with
              | `Assoc [ ("path", `String path); ("mount", `String kind) ] -> (
                  match
                    ( Tools.Path.of_string path,
                      List.assoc_opt kind
                        [ ("hidden", Tools.Hidden); ("readonly", Tools.Readonly); ("scratch", Tools.Scratch) ] )
                  with
                  | Ok path, Some mount -> Ok ((path, mount) :: rest)
                  | _ -> Error ("not a recorded mount: " ^ Yojson.Safe.to_string mount))
              | _ -> Error ("not a recorded mount: " ^ Yojson.Safe.to_string mount)))
        mounts (Ok [])
      |> Result.map (fun mounts -> Enter mounts)
  | `Assoc [ ("leave", `Null) ] -> Ok Leave
  | `Assoc [ ("merge", `List patches) ] ->
      List.fold_right
        (fun patch collected ->
          Result.bind collected (fun rest ->
              let text = function `Null -> Some None | `String text -> Some (Some text) | _ -> None in
              match patch with
              | `Assoc [ ("file", `String file); ("base", base); ("content", content) ] -> (
                  match (text base, text content) with
                  | Some base, Some content -> Ok ({ file; base; content } :: rest)
                  | _ -> Error ("not a recorded patch: " ^ Yojson.Safe.to_string patch))
              | _ -> Error ("not a recorded patch: " ^ Yojson.Safe.to_string patch)))
        patches (Ok [])
      |> Result.map (fun patches -> Merge patches)
  | other -> Error ("not a recorded tool: " ^ Yojson.Safe.to_string other)
