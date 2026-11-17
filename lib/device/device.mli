(** A driver: an Elm module that wraps [Agent.call] in typed functions, and the code that answers
    those calls. *)
type t =
  | Fetch  (** [Fetch.get] and [Fetch.post] over the hosts granted with [--net]. *)
  | Model  (** [Model.judge]: the model teagent runs with picks one of the answers a program gives. *)
  | Person  (** [Person.ask]: the person picks one of the answers a program gives. *)
  | Catalog  (** [Catalog.search]: finds the calls of the APIs by words, with their types. *)
  | Api of Api.t  (** A module of typed calls to an HTTP API the person described. *)

(** Whether the person lets an irreversible call go ahead. *)
type consent = Agrees | Declines

val all : t list
val source : t -> string
val class_of : name:string -> Value.t -> Value.class_
val refused : name:string -> string -> Value.t
val perform : Tools.t -> name:string -> Value.t -> (Value.t, Value.t) result Lwt.t
val searched : Api.t list -> string -> string
val judged : Llm.t -> Value.t -> (Value.t, Value.t) result Lwt.t

val asked :
  (question:string -> string list -> string option Lwt.t) -> Value.t -> (Value.t, Value.t) result Lwt.t
