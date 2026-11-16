let () =
  let shop =
    Result.get_ok
      (Api.parsed ~name:"Shop" ~base:None ~token:(Some "SHOP_TOKEN") ~only:[]
         (Yojson.Safe.from_file "shop.json"))
  in
  let os = Os.granted ~apis:[ shop ] "/w" ~net:[] in
  let program body =
    "module Main exposing (main)\n\nimport Agent exposing (..)\nimport Shop\n\n\nmain : Task Shop.ApiErr String\nmain =\n    "
    ^ body ^ "\n"
  in
  let compiled body = Lang.compile (Os.table os) (program body) in
  let call key = Value.Call { name = "api.Shop." ^ key; argument = Value.V_unit } in
  let failures =
    List.filter_map Fun.id
      [
        (match List.map (fun (operation : Api.operation) -> operation.key) (Api.operations shop) with
        | [ "listItems"; "createItem"; "getItem"; "deleteItem"; "broken" ] -> None
        | keys -> Some ("api: the operations are " ^ String.concat ", " keys));
        (match Api.credential shop with
        | Bearer "SHOP_TOKEN" -> None
        | _ -> Some "api: the token is not sent as a bearer");
        (match
           compiled
             "let\n        options =\n            Shop.listItemsOptions\n    in\n    Shop.listItems { options | limit = Just 2 }\n        |> andThen (\\items -> Shop.getItem { id = 1 })\n        |> map .name"
         with
        | Ok _ -> None
        | Error report -> Some ("api: a typed call does not compile:\n" ^ report));
        (match compiled "Shop.getItem { id = \"1\" } |> map .name" with
        | Error _ -> None
        | Ok _ -> Some "api: a call with the wrong type compiled");
        (match (Os.class_of os (call "getItem"), Os.class_of os (call "createItem"), Os.class_of os (call "deleteItem")) with
        | Value.Egress _, Value.Irreversible _, Value.Irreversible _ -> None
        | _ -> Some "api: reads are not egress, or writes are not irreversible");
        (match
           Api.parsed ~name:"Agent" ~base:None ~token:None ~only:[] (Yojson.Safe.from_file "shop.json")
         with
        | Error _ -> None
        | Ok _ -> Some "api: an API took the name of a teagent module");
        (match Lang.compile (Os.table (Os.granted "/w" ~net:[])) (program "succeed \"\"") with
        | Error _ -> None
        | Ok _ -> Some "api: a program imported an API the OS does not offer");
      ]
  in
  match failures with
  | [] -> ()
  | _ :: _ ->
      prerr_endline (String.concat "\n" failures);
      exit 1
