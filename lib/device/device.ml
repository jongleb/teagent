type t = Fetch

let all = [ Fetch ]
let source = function Fetch -> Fetch_elm.source

let perform workspace ~name argument =
  let failed constructor detail =
    Value.V_constr { constructor = { module_name = "Fetch"; name = constructor }; arguments = [ V_string detail ] }
  in
  match (name, argument) with
  | "fetch.get", Value.V_string url ->
      Lwt.map
        (function
          | Ok ({ status; body } : Tools.fetched) ->
              Ok (Value.V_record [ ("body", V_string body); ("status", V_number (Float.of_int status)) ])
          | Error (`Not_granted host) ->
              Error (failed "NotGranted" (host ^ " is not among the hosts granted with --net"))
          | Error (`Unreachable reason) -> Error (failed "Unreachable" reason))
        (Tools.fetch workspace url)
  | _ -> Lwt.return (Error (Value.V_string ("no driver answers the call " ^ name)))
