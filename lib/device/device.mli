(** A driver: an Elm module that wraps [Agent.call] in typed functions, and the code that answers
    those calls. *)
type t = Fetch  (** [Fetch.get] and [Fetch.post] over the hosts granted with [--net]. *)

(** Whether the person lets an irreversible call go ahead. *)
type consent = Agrees | Declines

val all : t list
val source : t -> string
val class_of : name:string -> Value.t -> Value.class_
val refused : name:string -> string -> Value.t
val perform : Tools.t -> name:string -> Value.t -> (Value.t, Value.t) result Lwt.t
