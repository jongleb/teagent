open Lwt.Syntax

type t = Fetch
type consent = Agrees | Declines

let all = [ Fetch ]
let source = function Fetch -> Fetch_elm.source

let class_of = function
  | "fetch.post" -> Value.Irreversible
  | _ -> Value.Pure

let perform workspace ~person ~name argument =
  let failed constructor detail =
    Value.V_constr
      { constructor = { module_name = "Fetch"; name = constructor }; arguments = [ V_string detail ] }
  in
  let fetched request url =
    Lwt.map
      (function
        | Ok ({ status; body } : Tools.fetched) ->
            Ok (Value.V_record [ ("body", V_string body); ("status", V_number (Float.of_int status)) ])
        | Error (`Not_granted host) ->
            Error (failed "NotGranted" (host ^ " is not among the hosts granted with --net"))
        | Error (`Unreachable reason) -> Error (failed "Unreachable" reason))
      (Tools.fetch workspace request url)
  in
  match (name, argument) with
  | "fetch.get", Value.V_string url -> fetched Tools.Get url
  | "fetch.post", Value.V_record [ ("body", V_string body); ("url", V_string url) ] -> (
      let* consent =
        person
          (Printf.sprintf "send %d bytes to %s:\n%s" (String.length body) url
             (match String.length body <= 2_000 with
             | true -> body
             | false -> String.sub body 0 2_000 ^ "… (cut)"))
      in
      match consent with
      | Agrees -> fetched (Tools.Post body) url
      | Declines ->
          Lwt.return
            (Error (failed "Declined" "the person did not let this request go out; ask them first")))
  | _ -> Lwt.return (Error (Value.V_string ("no driver answers the call " ^ name)))
