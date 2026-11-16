(** An HTTP API described by an OpenAPI 3 document, cut to what a program can call with types. *)

(** The form of one value, as the program and the API's JSON both see it. *)
type shape =
  | Text
  | Whole
  | Fraction
  | Truth
  | Empty  (** No content; [()] in the program. *)
  | Raw  (** JSON the program cannot type: the JSON text itself, as a [String]. *)
  | Listed of shape
  | Record of field list
  | Alias of string  (** A named record of the API, declared once in its module. *)

(** One field of a record: its name in the program, its key in the JSON. *)
and field = { elm : string; json : string; shape : shape; presence : presence }

and presence =
  | Required
  | Optional  (** [Maybe] in the program; absent or [null] in the JSON. *)

type meth = Get | Head | Post | Put | Patch | Delete

(** Where an argument of an operation goes in the request. *)
type place = Path | Query

type parameter = { field : field; place : place }

(** One call of the API: a function of its module. *)
type operation = {
  key : string;  (** The function's name, and the last part of its call's name. *)
  meth : meth;
  path : string;  (** The path template, such as [/repos/{owner}/{repo}/issues]. *)
  parameters : parameter list;
  body : field option;  (** The JSON request body, as the field [body] of the arguments. *)
  result : shape;
  summary : string;
}

(** How a request proves who sends it; the secret itself stays in the environment. *)
type credential =
  | Anonymous
  | Bearer of string  (** [Authorization: Bearer], from this environment variable. *)
  | Keyed of { header : string; variable : string }  (** This header, from this variable. *)

type t

val parsed :
  name:string ->
  base:string option ->
  token:string option ->
  only:string list ->
  Yojson.Safe.t ->
  (t, string) result

val name : t -> string
val base : t -> string
val credential : t -> credential
val operations : t -> operation list
val operation : t -> string -> operation option
val alias : t -> string -> shape
val method_name : meth -> string
val signature : operation -> string
val declaration : t -> string -> string option
val source : t -> string
