let () =
  let rec applied (tree : Yojson.Safe.t) path change : Yojson.Safe.t =
    match (path, tree) with
    | [], _ -> change tree
    | Wire.Index index :: rest, `List items ->
        `List (List.mapi (fun at item -> if at = index then applied item rest change else item) items)
    | Wire.Key label :: rest, `Assoc fields ->
        `Assoc
          (List.map
             (fun (name, item) -> (name, if String.equal name label then applied item rest change else item))
             fields)
    | _ -> failwith ("wire: no node at the path in " ^ Yojson.Safe.to_string tree)
  in
  let patched tree edits =
    List.fold_left
      (fun tree (edit : Wire.edit) ->
        match edit with
        | Set { path; value } -> applied tree path (fun _ -> value)
        | Splice { path; at; removed; inserted } ->
            applied tree path (function
              | `List items ->
                  `List
                    (List.filteri (fun index _ -> index < at) items
                    @ inserted
                    @ List.filteri (fun index _ -> index >= at + removed) items)
              | other -> failwith ("wire: a splice into " ^ Yojson.Safe.to_string other)))
      tree edits
  in
  let constr name arguments =
    Value.V_constr { constructor = { module_name = "Widget"; name }; arguments }
  in
  let row index =
    Value.V_record
      [
        ("agent", constr "Just" [ V_record [ ("name", V_string ("agent " ^ string_of_int index)); ("step", V_number (Float.of_int (index mod 7))) ] ]);
        ("branch", V_string ("feature/" ^ string_of_int index));
        ("dirty", V_bool (index mod 3 = 0));
        ("path", V_string ("/work/trees/" ^ string_of_int index));
        ("tone", constr (match index mod 2 with 0 -> "Good" | _ -> "Warning") []);
      ]
  in
  let rows count = Value.V_list (List.init count row) in
  let edited change = Value.V_list (change (List.init 200 row)) in
  let checked name old new_ =
    let edits = Wire.diff (Wire.json old) (Wire.json new_) in
    match Yojson.Safe.equal (patched (Wire.json old) edits) (Wire.json new_) with
    | true -> (edits, None)
    | false -> (edits, Some (name ^ ": the edits do not give the new tree"))
  in
  let random = Random.State.make [| 17 |] in
  let rec generated depth : Value.t =
    match Random.State.int random (if depth = 0 then 4 else 8) with
    | 0 -> V_number (Float.of_int (Random.State.int random 5))
    | 1 -> V_string (String.make 1 (Char.chr (97 + Random.State.int random 3)))
    | 2 -> V_bool (Random.State.bool random)
    | 3 -> constr "Nothing" []
    | 4 -> V_list (List.init (Random.State.int random 5) (fun _ -> generated (depth - 1)))
    | 5 -> V_tuple [ generated (depth - 1); generated (depth - 1) ]
    | 6 -> V_record [ ("a", generated (depth - 1)); ("b", generated (depth - 1)) ]
    | _ -> constr (match Random.State.bool random with true -> "Just" | false -> "Ok") [ generated (depth - 1) ]
  in
  let rec mutated (value : Value.t) : Value.t =
    match (Random.State.int random 10, value) with
    | 0, _ -> generated 2
    | _, V_list items ->
        let items = List.map mutated items in
        let at = Random.State.int random (List.length items + 1) in
        V_list
          (match Random.State.int random 3 with
          | 0 -> List.filteri (fun index _ -> index < at) items @ [ generated 1 ] @ List.filteri (fun index _ -> index >= at) items
          | 1 -> List.filteri (fun index _ -> index <> at) items
          | _ -> items)
    | _, V_tuple items -> V_tuple (List.map mutated items)
    | _, V_record fields -> V_record (List.map (fun (label, item) -> (label, mutated item)) fields)
    | _, V_constr { constructor; arguments } -> V_constr { constructor; arguments = List.map mutated arguments }
    | _, other -> other
  in
  let changed_row = edited (List.mapi (fun index item -> if index = 120 then row 1000 else item)) in
  let inserted = edited (fun items -> row 999 :: items) in
  let removed = edited List.tl in
  let failures =
    List.filter_map Fun.id
      (List.concat
         [
           List.init 500 (fun round ->
               let old = generated 4 in
               snd (checked ("random pair " ^ string_of_int round) old (mutated old)));
           [
             (match checked "one row" (rows 200) changed_row with
             | _, (Some _ as failure) -> failure
             | edits, None when List.for_all (function Wire.Set { path = Index 120 :: _; _ } -> true | _ -> false) edits -> None
             | edits, None -> Some (Printf.sprintf "wire: a changed row gives %d edits outside it" (List.length edits)));
             (match checked "insert" (rows 200) inserted with
             | _, (Some _ as failure) -> failure
             | [ Splice { path = []; at = 0; removed = 0; inserted = [ _ ] } ], None -> None
             | edits, None -> Some (Printf.sprintf "wire: an inserted row gives %d edits, not one splice" (List.length edits)));
             (match checked "remove" (rows 200) removed with
             | _, (Some _ as failure) -> failure
             | [ Splice { path = []; at = 0; removed = 1; inserted = [] } ], None -> None
             | edits, None -> Some (Printf.sprintf "wire: a removed row gives %d edits, not one splice" (List.length edits)));
             (match checked "same" (rows 200) (rows 200) with
             | [], None -> None
             | _, failure -> Option.fold ~none:(Some "wire: equal trees give edits") ~some:Option.some failure);
             (let compact = String.length (Yojson.Safe.to_string (Wire.json (rows 200))) in
              let tagged = String.length (Yojson.Safe.to_string (Value.to_json (rows 200))) in
              Printf.printf "200 rows: %d bytes compact, %d tagged\n" compact tagged;
              match compact * 2 < tagged with
              | true -> None
              | false -> Some "wire: the compact form is not half the tagged one");
           ];
         ])
  in
  List.iter prerr_endline failures;
  match failures with [] -> print_endline "wire: ok" | _ :: _ -> exit 1
