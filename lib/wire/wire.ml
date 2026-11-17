type step = Index of int | Key of string

type edit =
  | Set of { path : step list; value : Yojson.Safe.t }
  | Splice of { path : step list; at : int; removed : int; inserted : Yojson.Safe.t list }

let rec json (value : Value.t) : Yojson.Safe.t =
  match value with
  | V_labelled { value; _ } -> json value
  | V_number number when Float.is_integer number && Float.abs number < 1e15 ->
      `Int (Float.to_int number)
  | V_number number -> `Float number
  | V_string text | V_char text -> `String text
  | V_bool truth -> `Bool truth
  | V_json json -> json
  | V_unit | V_closure _ | V_task _ -> `Null
  | V_list items | V_tuple items -> `List (List.map json items)
  | V_record fields -> `Assoc (List.map (fun (label, value) -> (label, json value)) fields)
  | V_constr { constructor = { name; _ }; arguments = [] } -> `String name
  | V_constr { constructor = { name; _ }; arguments } ->
      `List (`String name :: List.map json arguments)

let diff old new_ =
  let rec changed path (old : Yojson.Safe.t) (new_ : Yojson.Safe.t) edits =
    match (old, new_) with
    | `List olds, `List news -> spliced path (Array.of_list olds) (Array.of_list news) edits
    | `Assoc olds, `Assoc news when List.equal (fun (a, _) (b, _) -> String.equal a b) olds news ->
        List.fold_left2
          (fun edits (label, old) (_, new_) -> changed (Key label :: path) old new_ edits)
          edits olds news
    | _ when Yojson.Safe.equal old new_ -> edits
    | _ -> Set { path = List.rev path; value = new_ } :: edits
  and spliced path olds news edits =
    let shortest = min (Array.length olds) (Array.length news) in
    let rec prefix count =
      match count < shortest && Yojson.Safe.equal olds.(count) news.(count) with
      | true -> prefix (count + 1)
      | false -> count
    in
    let kept = prefix 0 in
    let rec suffix count =
      match
        count < shortest - kept
        && Yojson.Safe.equal
             olds.(Array.length olds - 1 - count)
             news.(Array.length news - 1 - count)
      with
      | true -> suffix (count + 1)
      | false -> count
    in
    let trailing = suffix 0 in
    let removed = Array.length olds - kept - trailing in
    let inserted = Array.length news - kept - trailing in
    match removed = inserted with
    | true ->
        List.fold_left
          (fun edits offset ->
            changed (Index (kept + offset) :: path) olds.(kept + offset) news.(kept + offset) edits)
          edits (List.init removed Fun.id)
    | false ->
        Splice
          { path = List.rev path; at = kept; removed; inserted = Array.to_list (Array.sub news kept inserted) }
        :: edits
  in
  List.rev (changed [] old new_ [])

let edit_json edit : Yojson.Safe.t =
  let located path =
    ( "path",
      `List (List.map (function Index index -> `Int index | Key label -> `String label) path) )
  in
  match edit with
  | Set { path; value } -> `Assoc [ located path; ("set", value) ]
  | Splice { path; at; removed; inserted } ->
      `Assoc
        [ located path; ("at", `Int at); ("removed", `Int removed); ("inserted", `List inserted) ]
