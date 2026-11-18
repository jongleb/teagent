type shape =
  | Text
  | Whole
  | Fraction
  | Truth
  | Empty
  | Raw
  | Listed of shape
  | Record of field list
  | Alias of string

and field = { elm : string; json : string; shape : shape; presence : presence }
and presence = Required | Optional

type meth = Get | Head | Post | Put | Patch | Delete
type place = Path | Query
type parameter = { field : field; place : place }

type operation = {
  key : string;
  meth : meth;
  path : string;
  parameters : parameter list;
  body : field option;
  result : shape;
  summary : string;
}

type credential = Anonymous | Bearer of string | Keyed of { header : string; variable : string }

type t = {
  name : string;
  base : string;
  credential : credential;
  aliases : (string * shape) list;
  operations : operation list;
}

let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let text = function Some (`String value) -> Some value | _ -> None

let named case raw =
  let pieces =
    List.filter
      (fun piece -> String.length piece > 0)
      (String.split_on_char ' '
         (String.map (function ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9') as kept -> kept | _ -> ' ') raw))
  in
  let joined =
    String.concat ""
      (List.mapi
         (fun index piece ->
           match (index, case) with
           | 0, `Lower -> String.uncapitalize_ascii piece
           | _ -> String.capitalize_ascii piece)
         pieces)
  in
  let started =
    match String.to_seq joined () with
    | Seq.Nil -> ( match case with `Lower -> "value" | `Upper -> "Value")
    | Seq.Cons ('0' .. '9', _) -> ( match case with `Lower -> "n" | `Upper -> "N") ^ joined
    | Seq.Cons _ -> joined
  in
  let reserved =
    match case with
    | `Lower ->
        [ "type"; "port"; "module"; "import"; "exposing"; "as"; "where"; "alias"; "effect"; "case";
          "of"; "let"; "in"; "if"; "then"; "else"; "infix"; "arguments" ]
    | `Upper ->
        [ "List"; "Maybe"; "String"; "Int"; "Float"; "Bool"; "Char"; "Result"; "Task"; "Never";
          "Order"; "ApiErr"; "Dict"; "Set"; "Array"; "Ok"; "Err"; "Just"; "Nothing"; "True"; "False";
          "Declined"; "Unreachable"; "Failed"; "Unexpected" ]
  in
  match List.mem started reserved with true -> started ^ "_" | false -> started

let distinct names =
  List.rev
    (fst
       (List.fold_left
          (fun (kept, seen) name ->
            let rec free count =
              let candidate = match count with 1 -> name | _ -> name ^ string_of_int count in
              match List.mem candidate seen with true -> free (count + 1) | false -> candidate
            in
            let chosen = free 1 in
            (chosen :: kept, chosen :: seen))
          ([], []) names))

let method_name = function
  | Get -> "GET"
  | Head -> "HEAD"
  | Post -> "POST"
  | Put -> "PUT"
  | Patch -> "PATCH"
  | Delete -> "DELETE"

let parsed ~name ~base ~token ~only document =
  let resolved schema =
    let rec followed seen schema =
      match text (member "$ref" schema) with
      | Some pointer when String.starts_with ~prefix:"#/" pointer && not (List.mem pointer seen) ->
          Option.fold ~none:schema ~some:(followed (pointer :: seen))
            (List.fold_left
               (fun found key -> Option.bind found (member key))
               (Some document)
               (List.filteri (fun index _ -> index > 0) (String.split_on_char '/' pointer)))
      | Some _ | None -> schema
    in
    followed [] schema
  in
  let components = Option.value ~default:(`Assoc []) (Option.bind (member "components" document) (member "schemas")) in
  let aliased =
    match components with
    | `Assoc entries ->
        List.combine (List.map fst entries) (distinct (List.map (fun (key, _) -> named `Upper key) entries))
    | _ -> []
  in
  let aliases = ref [] in
  let rec shaped progress schema =
    match text (member "$ref" schema) with
    | Some pointer when String.starts_with ~prefix:"#/components/schemas/" pointer -> (
        let component = String.sub pointer 21 (String.length pointer - 21) in
        match (List.assoc_opt component aliased, List.find_opt (String.equal component) progress) with
        | None, _ | _, Some _ -> Raw
        | Some alias, None -> (
            match List.assoc_opt alias !aliases with
            | Some (Record _) -> Alias alias
            | Some shape -> shape
            | None -> (
                match shaped (component :: progress) (resolved schema) with
                | Record _ as record ->
                    aliases := !aliases @ [ (alias, record) ];
                    Alias alias
                | other -> other)))
    | Some _ -> shaped progress (resolved schema)
    | None -> (
        let kinds =
          match member "type" schema with
          | Some (`String kind) -> [ kind ]
          | Some (`List kinds) -> List.filter_map (function `String kind -> Some kind | _ -> None) kinds
          | _ -> []
        in
        match (member "allOf" schema, member "oneOf" schema, member "anyOf" schema) with
        | Some (`List parts), _, _ ->
            let fields =
              List.concat_map
                (fun part ->
                  match shaped progress part with
                  | Record fields -> fields
                  | Alias alias -> (
                      match List.assoc_opt alias !aliases with Some (Record fields) -> fields | _ -> [])
                  | _ -> [])
                parts
            in
            Record
              (List.fold_left
                 (fun kept (field : field) ->
                   match List.find_opt (fun (other : field) -> String.equal other.json field.json) kept with
                   | Some _ -> kept
                   | None -> kept @ [ field ])
                 [] fields)
        | _, Some _, _ | _, _, Some _ -> Raw
        | _ -> (
            match List.filter (fun kind -> not (String.equal kind "null")) kinds with
            | [ "string" ] -> Text
            | [ "integer" ] -> Whole
            | [ "number" ] -> Fraction
            | [ "boolean" ] -> Truth
            | [ "array" ] ->
                Listed (Option.fold ~none:Raw ~some:(shaped progress) (member "items" schema))
            | [ "object" ] | [] -> (
                match member "properties" schema with
                | Some (`Assoc (_ :: _ as properties)) ->
                    let required =
                      match member "required" schema with
                      | Some (`List keys) -> List.filter_map (function `String key -> Some key | _ -> None) keys
                      | _ -> []
                    in
                    Record
                      (List.map2
                         (fun (key, property) elm ->
                           let target = resolved property in
                           {
                             elm;
                             json = key;
                             shape = shaped progress property;
                             presence =
                               (match
                                  ( List.mem key required,
                                    member "nullable" target,
                                    member "type" target )
                                with
                               | true, Some (`Bool true), _ -> Optional
                               | true, _, Some (`List kinds) when List.mem (`String "null") kinds -> Optional
                               | true, _, _ -> Required
                               | false, _, _ -> Optional);
                           })
                         properties
                         (distinct (List.map (fun (key, _) -> named `Lower key) properties)))
                | _ -> Raw)
            | _ -> Raw))
  in
  let content shape =
    Option.bind (member "content" shape) (function
      | `Assoc types ->
          Option.bind
            (List.find_opt
               (fun (kind, _) ->
                 String.equal kind "application/json" || String.ends_with ~suffix:"+json" kind)
               types)
            (fun (_, media) -> Option.map (shaped []) (member "schema" media))
      | _ -> None)
  in
  let operations =
    match member "paths" document with
    | Some (`Assoc paths) ->
        List.concat_map
          (fun (path, item) ->
            let shared = match member "parameters" item with Some (`List shared) -> shared | _ -> [] in
            List.filter_map
              (fun (word, meth) ->
                Option.bind (member word item) (fun operation ->
                    let identifier =
                      Option.value ~default:(word ^ " " ^ path) (text (member "operationId" operation))
                    in
                    match (only, List.find_opt (String.equal identifier) only) with
                    | _ :: _, None -> None
                    | [], _ | _ :: _, Some _ ->
                        let parameters =
                          List.filter_map
                            (fun parameter ->
                              let parameter = resolved parameter in
                              Option.bind (text (member "name" parameter)) (fun key ->
                                  Option.map
                                    (fun place ->
                                      ( key,
                                        place,
                                        Option.fold ~none:Raw
                                          ~some:(fun schema ->
                                            match shaped [] schema with
                                            | (Text | Whole | Fraction | Truth) as plain -> plain
                                            | Listed ((Text | Whole | Fraction | Truth) as plain) -> Listed plain
                                            | _ -> Raw)
                                          (member "schema" parameter),
                                        match (place, member "required" parameter) with
                                        | Path, _ | Query, Some (`Bool true) -> Required
                                        | Query, _ -> Optional ))
                                    (match text (member "in" parameter) with
                                    | Some "path" -> Some Path
                                    | Some "query" -> Some Query
                                    | Some _ | None -> None)))
                            (shared
                            @ match member "parameters" operation with Some (`List own) -> own | _ -> [])
                        in
                        let parameters =
                          List.fold_left
                            (fun kept ((key, place, _, _) as parameter) ->
                              match
                                List.find_opt
                                  (fun (other, other_place, _, _) -> String.equal other key && other_place = place)
                                  kept
                              with
                              | Some found -> List.filter (fun old -> not (old == found)) kept @ [ parameter ]
                              | None -> kept @ [ parameter ])
                            [] parameters
                        in
                        let body =
                          Option.bind (Option.map resolved (member "requestBody" operation)) (fun body ->
                              Option.map
                                (fun shape ->
                                  {
                                    elm = "body";
                                    json = "";
                                    shape;
                                    presence =
                                      (match member "required" body with
                                      | Some (`Bool true) -> Required
                                      | _ -> Optional);
                                  })
                                (content body))
                        in
                        let names =
                          distinct
                            (List.map (fun (key, _, _, _) -> named `Lower key) parameters
                            @ Option.fold ~none:[] ~some:(fun (field : field) -> [ field.elm ]) body)
                        in
                        Some
                          {
                            key = named `Lower identifier;
                            meth;
                            path;
                            parameters =
                              List.map2
                                (fun (key, place, shape, presence) elm ->
                                  { field = { elm; json = key; shape; presence }; place })
                                parameters
                                (List.filteri (fun index _ -> index < List.length parameters) names);
                            body =
                              Option.map
                                (fun (field : field) -> { field with elm = List.nth names (List.length parameters) })
                                body;
                            result =
                              (match member "responses" operation with
                              | Some (`Assoc responses) ->
                                  Option.fold ~none:Raw
                                    ~some:(fun (_, response) ->
                                      Option.value ~default:Empty (content (resolved response)))
                                    (List.find_opt
                                       (fun (code, _) -> String.length code = 3 && Char.equal code.[0] '2')
                                       (List.sort compare responses))
                              | _ -> Raw);
                            summary =
                              Option.value ~default:""
                                (Option.fold ~none:(text (member "description" operation)) ~some:Option.some
                                   (text (member "summary" operation)));
                          }))
              [ ("get", Get); ("head", Head); ("post", Post); ("put", Put); ("patch", Patch); ("delete", Delete) ])
          paths
    | _ -> []
  in
  let operations =
    List.map2 (fun operation key -> { operation with key }) operations
      (distinct (List.map (fun operation -> operation.key) operations))
  in
  let server =
    Option.bind (member "servers" document) (function
      | `List (first :: _) -> text (member "url" first)
      | _ -> None)
  in
  match (operations, Option.fold ~none:server ~some:Option.some base) with
  | _, _
    when Option.is_some (List.find_opt (String.equal name) [ "Main"; "Agent"; "Policy"; "Fetch"; "Model"; "Catalog" ])
         || not (String.equal (named `Upper name) name) ->
      Error ("an API is named like an Elm module of its own, such as Github; " ^ name ^ " cannot be one")
  | [], _ -> Error "it has no operation teagent can call (or none of those listed in operations)"
  | _, None -> Error "it names no server: give base, such as https://api.example.com"
  | _ :: _, Some base when not (String.starts_with ~prefix:"https://" base || String.starts_with ~prefix:"http://" base) ->
      Error ("its base is not an http or https URL: " ^ base)
  | _ :: _, Some base ->
      let keyed =
        Option.bind
          (Option.bind (member "components" document) (member "securitySchemes"))
          (function
            | `Assoc schemes ->
                List.find_map
                  (fun (_, scheme) ->
                    match (text (member "type" scheme), text (member "in" scheme)) with
                    | Some "apiKey", Some "header" -> text (member "name" scheme)
                    | _ -> None)
                  schemes
            | _ -> None)
      in
      Ok
        {
          name;
          base =
            (match String.ends_with ~suffix:"/" base with
            | true -> String.sub base 0 (String.length base - 1)
            | false -> base);
          credential =
            (match (token, keyed) with
            | None, _ -> Anonymous
            | Some variable, None -> Bearer variable
            | Some variable, Some header -> Keyed { header; variable });
          aliases = !aliases;
          operations;
        }

let name api = api.name
let base api = api.base
let credential api = api.credential
let operations api = api.operations
let operation api key = List.find_opt (fun operation -> String.equal operation.key key) api.operations
let alias api name = Option.value ~default:Raw (List.assoc_opt name api.aliases)

let rec typed shape =
  match shape with
  | Text | Raw -> "String"
  | Whole -> "Int"
  | Fraction -> "Float"
  | Truth -> "Bool"
  | Empty -> "()"
  | Alias alias -> alias
  | Listed inner -> "List " ^ atom inner
  | Record [] -> "{}"
  | Record fields ->
      "{ "
      ^ String.concat ", " (List.map (fun (field : field) -> field.elm ^ " : " ^ slot field) fields)
      ^ " }"

and atom shape = match shape with Listed _ -> "(" ^ typed shape ^ ")" | _ -> typed shape
and slot (field : field) = match field.presence with Required -> typed field.shape | Optional -> "Maybe " ^ atom field.shape

let arguments operation =
  List.partition
    (fun (field : field) -> match field.presence with Required -> true | Optional -> false)
    (List.map (fun (parameter : parameter) -> parameter.field) operation.parameters
    @ Option.to_list operation.body)

let signature operation =
  let required, optional = arguments operation in
  operation.key ^ " : "
  ^ String.concat ""
      (List.map
         (fun fields -> typed (Record fields) ^ " -> ")
         (List.filter (fun fields -> not (List.is_empty fields)) [ required; optional ]))
  ^ "Task ApiErr " ^ atom operation.result

let declaration api name =
  Option.map
    (fun shape ->
      "type alias " ^ name ^ " =\n    "
      ^
      match shape with
      | Record (_ :: _ as fields) ->
          "{ "
          ^ String.concat "\n    , " (List.map (fun (field : field) -> field.elm ^ " : " ^ slot field) fields)
          ^ "\n    }"
      | other -> typed other)
    (List.assoc_opt name api.aliases)

let source api =
  let options operation = operation.key ^ "Options" in
  String.concat "\n\n\n"
    ([
       "module " ^ api.name ^ " exposing\n    ( ApiErr(..)\n"
       ^ String.concat ""
           (List.map
              (fun name -> "    , " ^ name ^ "\n")
              (List.map fst api.aliases
              @ List.concat_map
                  (fun operation ->
                    match arguments operation with
                    | _, [] -> [ operation.key ]
                    | _, _ :: _ -> [ operation.key; options operation ])
                  api.operations))
       ^ "    )\n\nimport Agent exposing (Task)";
       "type ApiErr\n    = Declined String\n    | Unreachable String\n    | Failed Int String\n    | Unexpected String";
     ]
    @ List.filter_map (fun (name, _) -> declaration api name) api.aliases
    @ List.concat_map
        (fun operation ->
          let required, optional = arguments operation in
          let call = "Elm.Kernel.Agent.call \"api." ^ api.name ^ "." ^ operation.key ^ "\"" in
          (signature operation ^ "\n" ^ operation.key
          ^
          match (required, optional) with
          | [], [] -> " =\n    " ^ call ^ " { options = {}, required = {} }"
          | _ :: _, [] -> " required =\n    " ^ call ^ " { options = {}, required = required }"
          | [], _ :: _ -> " options =\n    " ^ call ^ " { options = options, required = {} }"
          | _ :: _, _ :: _ -> " required options =\n    " ^ call ^ " { options = options, required = required }")
          ::
          (match optional with
          | [] -> []
          | _ :: _ ->
              [
                options operation ^ " : " ^ typed (Record optional) ^ "\n" ^ options operation ^ " =\n    { "
                ^ String.concat "\n    , " (List.map (fun (field : field) -> field.elm ^ " = Nothing") optional)
                ^ "\n    }";
              ]))
        api.operations)
  ^ "\n"
