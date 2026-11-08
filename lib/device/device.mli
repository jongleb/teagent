(** A driver: an Elm module that wraps [Agent.call] in typed functions, and the code that answers
    those calls. *)
type t = Fetch  (** [Fetch.get] and [Fetch.post] over the hosts granted with [--net]. *)

(** Whether the person lets an irreversible call go ahead. *)
type consent = Agrees | Declines

val all : t list
val source : t -> string
val class_of : string -> Value.class_

val perform :
  Tools.t ->
  person:(string -> consent Lwt.t) ->
  name:string ->
  Value.t ->
  (Value.t, Value.t) result Lwt.t
