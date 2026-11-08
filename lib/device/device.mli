(** A driver: an Elm module that wraps [Agent.call] in typed functions, and the code that answers
    those calls. *)
type t = Fetch  (** [Fetch.get] over the hosts granted with [--net]. *)

val all : t list
val source : t -> string
val perform : Tools.t -> name:string -> Value.t -> (Value.t, Value.t) result Lwt.t
