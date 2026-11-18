type t = Fetch | Model | Person | Catalog | Api of Api.t | Hosted of hosted
and hosted = { name : string; source : string; calls : (string * Value.class_) list }
type consent = Agrees | Declines

let all = [ Fetch; Model; Person ]
let source = function
  | Fetch -> Fetch_elm.source
  | Model -> Model_elm.source
  | Person -> Person_elm.source
  | Catalog -> Catalog_elm.source
  | Api api -> Api.source api
  | Hosted hosted -> hosted.source

let failed module_name constructor detail =
  Value.V_constr { constructor = { module_name; name = constructor }; arguments = [ V_string detail ] }

let declared devices name =
  List.find_map
    (function Hosted hosted -> List.assoc_opt name hosted.calls | Fetch | Model | Person | Catalog | Api _ -> None)
    devices

let class_of devices ~name argument =
  match declared devices name with
  | Some (Value.Irreversible { question; declined }) ->
      Value.Irreversible { question = question ^ ", with:\n" ^ Value.to_elm argument; declined }
  | Some class_ -> class_
  | None -> (
  match (name, argument) with
  | "fetch.post", Value.V_record [ ("body", V_string body); ("url", V_string url) ] ->
      Value.Irreversible
        {
          question =
            Printf.sprintf "send %d bytes to %s, which cannot be taken back:\n%s" (String.length body)
              url body;
          declined = failed "Fetch" "Declined" "the person did not let this request go out; ask them first";
        }
  | "fetch.get", _ ->
      Value.Egress
        {
          declined =
            Error
              (failed "Fetch" "Declined"
                 "the person did not let this request carry content of the project; ask them first");
        }
  | ("model.judge" | "person.ask" | "catalog.search"), _ -> Value.Pure
  | _ when String.starts_with ~prefix:"listen." name -> Value.Pure
  | _ -> (
      match String.split_on_char '.' name with
      | [ "api"; module_name; _ ] ->
          Value.Irreversible
            {
              question = "make the call " ^ name ^ " of an API, which may not be taken back";
              declined = failed module_name "Declined" "the person did not let this call go out; ask them first";
            }
      | _ ->
          Value.Irreversible
            {
              question = "make the call " ^ name ^ ", which teagent does not know, with:\n" ^ Value.to_elm argument;
              declined = Value.V_string "the person did not let this call go out; ask them first";
            }))

let hosted ~name ~source ~calls =
  let prefix = String.lowercase_ascii name ^ "." in
  let identifier = Str.string_match (Str.regexp "[A-Z][A-Za-z0-9_]*$") name 0 in
  let kernels =
    match Str.split_delim (Str.regexp_string "Elm.Kernel.") source with
    | [] -> []
    | _ :: uses -> uses
  in
  let opening = "Agent.call \"" in
  let undeclared =
    List.find_map
      (fun use ->
        match String.starts_with ~prefix:opening use with
        | false ->
            Some ("Elm.Kernel." ^ Option.fold ~none:use ~some:(fun at -> String.sub use 0 at) (String.index_opt use '\n'))
        | true -> (
            let rest = String.sub use (String.length opening) (String.length use - String.length opening) in
            match String.index_opt rest '"' with
            | None -> Some "a call whose name is not written out"
            | Some at ->
                let called = String.sub rest 0 at in
                Option.fold ~none:(Some ("the call " ^ called ^ ", which has no class")) ~some:(fun _ -> None)
                  (List.assoc_opt called calls)))
      kernels
  in
  match
    ( identifier,
      List.mem name [ "Main"; "Agent"; "Live"; "Policy"; "Listen"; "Api"; "Fetch"; "Model"; "Person"; "Catalog" ],
      String.starts_with ~prefix:("module " ^ name ^ " ") source,
      List.find_opt (fun (called, _) -> not (String.starts_with ~prefix called)) calls,
      undeclared )
  with
  | false, _, _, _, _ -> Error (name ^ " is not a module name")
  | true, true, _, _, _ -> Error (name ^ " is a module of teagent")
  | true, false, false, _, _ -> Error ("the source is not the module " ^ name)
  | true, false, true, Some (called, _), _ -> Error ("the call " ^ called ^ " does not start with " ^ prefix)
  | true, false, true, None, Some use -> Error ("the module uses " ^ use)
  | true, false, true, None, None -> Ok (Hosted { name; source; calls })

let refused ~name reason =
  match String.split_on_char '.' name with
  | "fetch" :: _ -> failed "Fetch" "Declined" reason
  | "model" :: _ -> failed "Model" "Declined" reason
  | "person" :: _ -> failed "Person" "Unanswered" reason
  | [ "api"; module_name; _ ] -> failed module_name "Declined" reason
  | _ -> Value.V_string reason

let searched apis query =
  let contains text piece =
    let rec at index =
      index + String.length piece <= String.length text
      && (String.equal (String.sub text index (String.length piece)) piece || at (index + 1))
    in
    at 0
  in
  let words =
    List.filter
      (fun word -> String.length word > 2)
      (String.split_on_char ' ' (String.lowercase_ascii query))
  in
  let found =
    List.filteri
      (fun index _ -> index < 8)
      (List.stable_sort
         (fun (one, _, (first : Api.operation)) (other, _, (second : Api.operation)) ->
           compare (other, String.length first.key) (one, String.length second.key))
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
  match (found, types) with
    | [], [] -> "Nothing matches " ^ query ^ "."
    | _, _ ->
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

let perform workspace ~name argument =
  let fetched request url =
    Lwt.map
      (function
        | Ok ({ status; body } : Tools.fetched) ->
            Ok (Value.V_record [ ("body", V_string body); ("status", V_number (Float.of_int status)) ])
        | Error (`Not_granted host) ->
            Error (failed "Fetch" "NotGranted" (host ^ " is not among the hosts granted with --net"))
        | Error (`Unreachable reason) -> Error (failed "Fetch" "Unreachable" reason))
      (Tools.fetch workspace request url)
  in
  match (name, argument) with
  | "catalog.search", Value.V_string words -> Lwt.return (Ok (Value.V_string (searched (Tools.apis workspace) words)))
  | "fetch.get", Value.V_string url -> fetched Tools.Get url
  | "fetch.post", Value.V_record [ ("body", V_string body); ("url", V_string url) ] ->
      fetched (Tools.Post body) url
  | "person.ask", _ -> Lwt.return (Error (failed "Person" "Unanswered" "nobody here answers questions"))
  | "model.judge", _ ->
      Lwt.return
        (Error
           (failed "Model" "Unreachable"
              "this run has no model to judge with: set ANTHROPIC_API_KEY or pass --openai"))
  | _ -> (
      match
        match String.split_on_char '.' name with
        | [ "api"; module_name; key ] ->
            Option.bind (Tools.api workspace module_name) (fun api ->
                Option.map (fun operation -> (api, operation)) (Api.operation api key))
        | _ -> None
      with
      | None -> Lwt.return (Error (Value.V_string ("no driver answers the call " ^ name)))
      | Some (api, (operation : Api.operation)) ->
          let error constructor arguments =
            Value.V_constr { constructor = { module_name = Api.name api; name = constructor }; arguments }
          in
          let maybe = function
            | Value.V_constr { constructor = { name = "Just"; _ }; arguments = [ value ] } -> Some value
            | _ -> None
          in
          let rec plain = function Value.V_labelled { value; _ } -> plain value | value -> value in
          let rec encoded (shape : Api.shape) value : Yojson.Safe.t =
            match (shape, plain value) with
            | Api.Alias alias, value -> encoded (Api.alias api alias) value
            | Text, V_string text -> `String text
            | Raw, V_string text -> (
                match Yojson.Safe.from_string text with json -> json | exception Yojson.Json_error _ -> `String text)
            | Whole, V_number number -> `Int (Float.to_int number)
            | Fraction, V_number number -> `Float number
            | Truth, V_bool truth -> `Bool truth
            | Listed inner, V_list values -> `List (List.map (encoded inner) values)
            | Record fields, V_record values ->
                `Assoc
                  (List.filter_map
                     (fun (field : Api.field) ->
                       Option.bind (List.assoc_opt field.elm values) (fun value ->
                           match field.presence with
                           | Required -> Some (field.json, encoded field.shape value)
                           | Optional ->
                               Option.map (fun value -> (field.json, encoded field.shape value)) (maybe (plain value))))
                     fields)
            | _, _ -> `Null
          in
          let rec decoded (shape : Api.shape) (json : Yojson.Safe.t) =
            match (shape, json) with
            | Api.Alias alias, _ -> decoded (Api.alias api alias) json
            | Empty, _ -> Ok Value.V_unit
            | Raw, `String text -> Ok (Value.V_string text)
            | Raw, _ -> Ok (Value.V_string (Yojson.Safe.to_string json))
            | Text, `String text -> Ok (V_string text)
            | Whole, `Int whole -> Ok (V_number (Float.of_int whole))
            | (Whole | Fraction), `Intlit digits -> Ok (V_number (Float.of_string digits))
            | Fraction, `Int whole -> Ok (V_number (Float.of_int whole))
            | Fraction, `Float fraction -> Ok (V_number fraction)
            | Truth, `Bool truth -> Ok (V_bool truth)
            | Listed inner, `List items ->
                Result.map
                  (fun values -> Value.V_list values)
                  (List.fold_right
                     (fun item rest -> Result.bind (decoded inner item) (fun value -> Result.map (List.cons value) rest))
                     items (Ok []))
            | Record fields, `Assoc pairs ->
                Result.map
                  (fun values ->
                    Value.V_record (List.sort (fun (one, _) (other, _) -> String.compare one other) values))
                  (List.fold_right
                     (fun (field : Api.field) rest ->
                       Result.bind rest (fun rest ->
                           match (field.presence, List.assoc_opt field.json pairs) with
                           | Required, (None | Some `Null) ->
                               Error ("the field " ^ field.json ^ " is missing")
                           | Required, Some json ->
                               Result.map (fun value -> (field.elm, value) :: rest)
                                 (Result.map_error (fun reason -> field.json ^ ": " ^ reason) (decoded field.shape json))
                           | Optional, (None | Some `Null) ->
                               Ok
                                 ((field.elm, Value.V_constr { constructor = { module_name = "Maybe"; name = "Nothing" }; arguments = [] })
                                 :: rest)
                           | Optional, Some json ->
                               Result.map
                                 (fun value ->
                                   ( field.elm,
                                     Value.V_constr { constructor = { module_name = "Maybe"; name = "Just" }; arguments = [ value ] } )
                                   :: rest)
                                 (Result.map_error (fun reason -> field.json ^ ": " ^ reason) (decoded field.shape json))))
                     fields (Ok []))
            | _, _ ->
                let shown = Yojson.Safe.to_string json in
                Error
                  ("the API sent "
                  ^ (match String.length shown > 200 with
                    | true -> String.sub shown 0 200 ^ "..."
                    | false -> shown)
                  ^ " where its description promised another type")
          in
          let values =
            match plain argument with
            | Value.V_record [ ("options", options); ("required", required) ] ->
                List.concat_map
                  (fun part -> match plain part with Value.V_record values -> values | _ -> [])
                  [ options; required ]
            | _ -> []
          in
          let given (field : Api.field) =
            Option.bind (List.assoc_opt field.elm values) (fun value ->
                match field.presence with Required -> Some (plain value) | Optional -> Option.map plain (maybe (plain value)))
          in
          let escaped word =
            String.concat ""
              (List.map
                 (function
                   | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~') as kept -> String.make 1 kept
                   | other -> Printf.sprintf "%%%02X" (Char.code other))
                 (List.of_seq (String.to_seq word)))
          in
          let rendered (shape : Api.shape) value =
            let rec words (shape : Api.shape) value =
              match (shape, value) with
              | Listed inner, Value.V_list items -> List.concat_map (fun item -> words inner (plain item)) items
              | _, _ -> (
                  match encoded shape value with
                  | `String text -> [ text ]
                  | `Int whole -> [ string_of_int whole ]
                  | `Float fraction -> [ Printf.sprintf "%g" fraction ]
                  | `Bool truth -> [ string_of_bool truth ]
                  | json -> [ Yojson.Safe.to_string json ])
            in
            List.map escaped (words shape value)
          in
          let path =
            List.fold_left
              (fun path (parameter : Api.parameter) ->
                match (parameter.place, given parameter.field) with
                | Path, Some value ->
                    Str.global_replace
                      (Str.regexp_string ("{" ^ parameter.field.json ^ "}"))
                      (String.concat "," (rendered parameter.field.shape value))
                      path
                | (Path | Query), _ -> path)
              operation.path operation.parameters
          in
          let query =
            List.concat_map
              (fun (parameter : Api.parameter) ->
                match (parameter.place, given parameter.field) with
                | Query, Some value ->
                    List.map (fun word -> escaped parameter.field.json ^ "=" ^ word)
                      (rendered parameter.field.shape value)
                | (Path | Query), _ -> [])
              operation.parameters
          in
          Lwt.map
            (function
              | Error (`Unset variable) ->
                  Error
                    (error "Unreachable"
                       [ V_string ("the API needs " ^ variable ^ " set in teagent's environment, and it is not") ])
              | Error (`Unreachable reason) -> Error (error "Unreachable" [ V_string reason ])
              | Ok ({ status; body } : Tools.fetched) when status < 200 || status > 299 ->
                  Error (error "Failed" [ V_number (Float.of_int status); V_string body ])
              | Ok { body; _ } -> (
                  match
                    match (operation.result, String.trim body) with
                    | Empty, _ -> Ok Value.V_unit
                    | Raw, text -> Ok (Value.V_string text)
                    | shape, text -> (
                        match Yojson.Safe.from_string text with
                        | json -> decoded shape json
                        | exception Yojson.Json_error reason -> Error ("the answer is not JSON: " ^ reason))
                  with
                  | Ok value -> Ok value
                  | Error reason -> Error (error "Unexpected" [ V_string reason ])))
            (Tools.requested api operation.meth
               ~target:(path ^ match query with [] -> "" | _ :: _ -> "?" ^ String.concat "&" query)
               ~body:
                 (Option.bind operation.body (fun field ->
                      Option.map (fun value -> Yojson.Safe.to_string (encoded field.shape value)) (given field)))))

let judged model argument =
  match argument with
  | Value.V_record [ ("answers", V_list answers); ("question", V_string question) ] -> (
      let answers = List.filter_map (function Value.V_string answer -> Some answer | _ -> None) answers in
      let normal text = String.lowercase_ascii (String.trim text) in
      match answers with
      | [] -> Lwt.return (Error (failed "Model" "Unclear" "judge needs at least one answer to pick"))
      | _ :: _ ->
          Lwt.map
            (function
              | Error (`Llm problem) -> Error (failed "Model" "Unreachable" (Llm.explained problem))
              | Ok reply ->
                  Option.fold
                    ~none:(Error (failed "Model" "Unclear" reply))
                    ~some:(fun answer -> Ok (Value.V_string answer))
                    (List.find_opt (fun answer -> String.equal (normal answer) (normal reply)) answers))
            (Llm.complete model
               ~system:
                 "You judge one question inside a program. Reply with exactly one of the answers \
                  you are given, copied as written, and nothing else."
               [
                 {
                   role = User;
                   text =
                     question ^ "\n\nAnswers:\n"
                     ^ String.concat "\n" (List.map (fun answer -> "- " ^ answer) answers);
                 };
               ]))
  | _ -> Lwt.return (Error (failed "Model" "Unclear" "judge takes a question and a list of answers"))

let asked person argument =
  match argument with
  | Value.V_record [ ("answers", V_list answers); ("question", V_string question) ] -> (
      match List.filter_map (function Value.V_string answer -> Some answer | _ -> None) answers with
      | [] -> Lwt.return (Error (failed "Person" "Unanswered" "ask needs at least one answer to pick"))
      | answers ->
          Lwt.map
            (fun picked ->
              Option.fold
                ~none:(Error (failed "Person" "Unanswered" "the person picked none of the answers"))
                ~some:(fun answer -> Ok (Value.V_string answer))
                (Option.bind picked (fun picked -> List.find_opt (String.equal picked) answers)))
            (person ~question answers))
  | _ -> Lwt.return (Error (failed "Person" "Unanswered" "ask takes a question and a list of answers"))
