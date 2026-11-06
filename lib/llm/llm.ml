open Lwt.Syntax

type effort = Low | Medium | High | Xhigh | Max
type credential = Api_key of string | Bearer of string

type t =
  | Anthropic of { credential : credential; model : string; effort : effort }
  | Openai_compatible of { url : string; key : string option; model : string }

type role = User | Assistant
type message = { role : role; text : string }

type error =
  | Status of { code : int; body : string }
  | Transport of string
  | Refusal of string
  | Unreadable of string

(** One HTTP exchange: the status, the body, and the [retry-after] seconds if the server sent them. *)
type answer = { code : int; body : string; retry_after : float option }

let posted ~url ~headers body =
  let cancelled = Atomic.make false in
  let waiting, wakener = Lwt.task () in
  Lwt.on_cancel waiting (fun () -> Atomic.set cancelled true);
  Lwt.async (fun () ->
      let+ exchanged =
        Lwt_preemptive.detach
          (fun () ->
            let handle = Curl.init () in
            let received = Buffer.create 4096 in
            let retry_after = ref None in
            Fun.protect
              ~finally:(fun () -> Curl.cleanup handle)
              (fun () ->
                match
                  Curl.set_url handle url;
                  Curl.set_httpheader handle headers;
                  Curl.set_post handle true;
                  Curl.set_postfields handle body;
                  Curl.set_postfieldsize handle (String.length body);
                  Curl.set_connecttimeout handle 30;
                  Curl.set_timeout handle 900;
                  Curl.set_noprogress handle false;
                  Curl.set_xferinfofunction handle (fun _ _ _ _ -> Atomic.get cancelled);
                  Curl.set_writefunction handle (fun chunk ->
                      Buffer.add_string received chunk;
                      String.length chunk);
                  Curl.set_headerfunction handle (fun line ->
                      (match String.index_opt line ':' with
                      | Some colon
                        when String.equal
                               (String.lowercase_ascii (String.sub line 0 colon))
                               "retry-after" ->
                          retry_after :=
                            float_of_string_opt
                              (String.trim
                                 (String.sub line (colon + 1)
                                    (String.length line - colon - 1)))
                      | Some _ | None -> ());
                      String.length line);
                  Curl.perform handle
                with
                | () ->
                    Ok
                      {
                        code = Curl.get_responsecode handle;
                        body = Buffer.contents received;
                        retry_after = !retry_after;
                      }
                | exception Curl.CurlException (_, _, reason) -> Error (Transport reason)))
          ()
      in
      if not (Atomic.get cancelled) then Lwt.wakeup wakener exchanged);
  waiting

let complete provider ~system messages =
  let turns =
    List.map
      (fun { role; text } ->
        `Assoc
          [
            ("role", `String (match role with User -> "user" | Assistant -> "assistant"));
            ("content", `String text);
          ])
      messages
  in
  let url, headers, body, read =
    match provider with
    | Anthropic { credential; model; effort } ->
        let signed =
          match credential with
          | Api_key key -> [ "x-api-key: " ^ key; "anthropic-beta: server-side-fallback-2026-07-01" ]
          | Bearer token ->
              [
                "Authorization: Bearer " ^ token;
                "anthropic-beta: oauth-2025-04-20,server-side-fallback-2026-07-01";
              ]
        in
        ( "https://api.anthropic.com/v1/messages",
          ("content-type: application/json" :: "anthropic-version: 2026-10-21" :: signed),
          `Assoc
            [
              ("model", `String model);
              ("max_tokens", `Int 16000);
              ("system", `String system);
              ("messages", `List turns);
              ( "output_config",
                `Assoc
                  [
                    ( "effort",
                      `String
                        (match effort with
                        | Low -> "low"
                        | Medium -> "medium"
                        | High -> "high"
                        | Xhigh -> "xhigh"
                        | Max -> "max") );
                  ] );
              ("fallbacks", `String "default");
            ],
          fun (json : Yojson.Safe.t) ->
            match
              ( Yojson.Safe.Util.member "stop_reason" json,
                Yojson.Safe.Util.member "content" json )
            with
            | `String "refusal", _ ->
                Error
                  (Refusal
                     (Yojson.Safe.to_string (Yojson.Safe.Util.member "stop_details" json)))
            | _, `List blocks ->
                Ok
                  (String.concat ""
                     (List.filter_map
                        (fun block ->
                          match
                            ( Yojson.Safe.Util.member "type" block,
                              Yojson.Safe.Util.member "text" block )
                          with
                          | `String "text", `String text -> Some text
                          | _, _ -> None)
                        blocks))
            | _, _ -> Error (Unreadable (Yojson.Safe.to_string json)) )
    | Openai_compatible { url; key; model } ->
        ( url ^ "/chat/completions",
          "content-type: application/json"
          :: Option.fold ~none:[] ~some:(fun key -> [ "Authorization: Bearer " ^ key ]) key,
          `Assoc
            [
              ("model", `String model);
              ( "messages",
                `List
                  (`Assoc [ ("role", `String "system"); ("content", `String system) ]
                  :: turns) );
            ],
          fun (json : Yojson.Safe.t) ->
            match Yojson.Safe.Util.member "choices" json with
            | `List (choice :: _) -> (
                match
                  Yojson.Safe.Util.member "content" (Yojson.Safe.Util.member "message" choice)
                with
                | `String text -> Ok text
                | _ -> Error (Unreadable (Yojson.Safe.to_string json)))
            | _ -> Error (Unreadable (Yojson.Safe.to_string json)) )
  in
  let request = Yojson.Safe.to_string body in
  let rec attempt left delay =
    let* exchanged = posted ~url ~headers request in
    let retried retry_after failure =
      match left with
      | 0 -> Lwt.return (Error (`Llm failure))
      | _ ->
          let* () = Lwt_unix.sleep (Option.value ~default:delay retry_after) in
          attempt (left - 1) (delay *. 2.)
    in
    match exchanged with
    | Error failure -> retried None failure
    | Ok { code = 200; body; _ } ->
        Lwt.return
          (match Yojson.Safe.from_string body with
          | json -> Result.map_error (fun failure -> `Llm failure) (read json)
          | exception Yojson.Json_error reason -> Error (`Llm (Unreadable reason)))
    | Ok { code = (408 | 429 | 500 | 502 | 503 | 504 | 529) as code; body; retry_after } ->
        retried retry_after (Status { code; body })
    | Ok { code; body; _ } -> Lwt.return (Error (`Llm (Status { code; body })))
  in
  attempt 4 1.

let efforts =
  [ ("low", Low); ("medium", Medium); ("high", High); ("xhigh", Xhigh); ("max", Max) ]

let configured ~model ~effort ~openai =
  let anthropic credential =
    Anthropic
      { credential; model = Option.value ~default:"claude-opus-5-5" model; effort }
  in
  match
    ( openai,
      model,
      Sys.getenv_opt "ANTHROPIC_API_KEY",
      Sys.getenv_opt "ANTHROPIC_AUTH_TOKEN" )
  with
  | Some url, Some model, _, _ ->
      Ok (Openai_compatible { url; key = Sys.getenv_opt "OPENAI_API_KEY"; model })
  | Some url, None, _, _ -> Error ("--openai " ^ url ^ " needs --model ID.")
  | None, _, Some key, _ when not (String.equal key "") -> Ok (anthropic (Api_key key))
  | None, _, _, Some token when not (String.equal token "") -> Ok (anthropic (Bearer token))
  | None, _, _, _ ->
      Error "Set ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN), or pass --openai URL --model ID."

let explained = function
  | Status { code; body } -> Printf.sprintf "The model API answered %d: %s" code body
  | Transport reason -> "The model API is unreachable: " ^ reason
  | Refusal details -> "The model declined: " ^ details
  | Unreadable body -> "The model API sent something unexpected: " ^ body
