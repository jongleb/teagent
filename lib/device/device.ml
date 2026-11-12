type t = Fetch | Model
type consent = Agrees | Declines

let all = [ Fetch; Model ]
let source = function Fetch -> Fetch_elm.source | Model -> Model_elm.source

let failed module_name constructor detail =
  Value.V_constr { constructor = { module_name; name = constructor }; arguments = [ V_string detail ] }

let class_of ~name argument =
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
  | _ -> Value.Pure

let refused ~name reason =
  match String.split_on_char '.' name with
  | "fetch" :: _ -> failed "Fetch" "Declined" reason
  | "model" :: _ -> failed "Model" "Declined" reason
  | _ -> Value.V_string reason

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
  | "fetch.get", Value.V_string url -> fetched Tools.Get url
  | "fetch.post", Value.V_record [ ("body", V_string body); ("url", V_string url) ] ->
      fetched (Tools.Post body) url
  | "model.judge", _ ->
      Lwt.return
        (Error
           (failed "Model" "Unreachable"
              "this run has no model to judge with: set ANTHROPIC_API_KEY or pass --openai"))
  | _ -> Lwt.return (Error (Value.V_string ("no driver answers the call " ^ name)))

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
