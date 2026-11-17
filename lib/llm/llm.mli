(** How hard an Anthropic model thinks before it answers. *)
type effort = Low | Medium | High | Xhigh | Max

(** How a request to the Anthropic API is signed. *)
type credential =
  | Api_key of string  (** Sent as [x-api-key]. *)
  | Bearer of string  (** An OAuth access token, sent as [Authorization: Bearer]. *)

(** Where completions come from. *)
type t =
  | Anthropic of { credential : credential; model : string; effort : effort }
  | Openai_compatible of { url : string; key : string option; model : string }
      (** A [/chat/completions] server such as llama.cpp, vLLM or Ollama, at [url]. *)

(** Who said a message. *)
type role = User | Assistant

type message = { role : role; text : string }

(** Why a completion failed, after retries. *)
type error =
  | Status of { code : int; body : string }  (** The server answered with an HTTP error. *)
  | Transport of string  (** The request never got an answer. *)
  | Refusal of string  (** The model declined the request. *)
  | Unreadable of string  (** The answer is not the JSON this client expects. *)

(** Tokens one completion took: [input] uncached, [cached] read from the prompt cache, [written]
    into it. *)
type usage = { input : int; output : int; cached : int; written : int }

type reply = { text : string; usage : usage }

val answered : t -> system:string -> message list -> (reply, [> `Llm of error ]) result Lwt.t
val complete : t -> system:string -> message list -> (string, [> `Llm of error ]) result Lwt.t
val efforts : (string * effort) list

val configured :
  model:string option -> effort:effort -> openai:string option -> (t, string) result

val explained : error -> string
