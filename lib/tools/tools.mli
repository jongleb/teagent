(** The directory the agent works in, with what it may not touch; every path is relative to it. *)
type t

type error =
  | Not_found of string  (** No such file. *)
  | Denied of string  (** The path leaves the workspace, belongs to its tooling, or is not readable. *)
  | Conflict of string  (** The file is there, but the change does not fit it. *)

(** A relative, normalized path inside the workspace and outside its tooling folders, at any
    depth. [runner] names what runs or obeys the file outside the sandbox after the session,
    such as git hooks, CI or other coding agents. *)
module Path : sig
  type t = private string

  val of_string : string -> (t, [> `Tools of error ]) result
  val runner : t -> string option
end

(** Where a contained shell may read files, besides the system and its own copy. *)
type reads =
  | Anywhere  (** Every file the user can, except the project itself and well-known secrets. *)
  | Within of string list  (** Only under these absolute paths. *)

(** What a path of the workspace is to the agent; a path no mount covers is staged and applied. *)
type mount =
  | Hidden  (** Neither readable nor writable, and absent from the shell's copy. *)
  | Readonly  (** Readable, never written. *)
  | Scratch  (** Read and written during the session; never applied to the project. *)

(** What the user keeps from the agent; it only ever narrows what the agent can do. *)
type limits = {
  mounts : (Path.t * mount) list;  (** Where several cover a path, the strictest holds. *)
  reads : reads;
  net : string list;  (** Hosts a contained command may reach through the proxy, such as [*.npmjs.org]. *)
  seconds : int;  (** How long a command may run, by the clock and in CPU time per process. *)
}

val at : string -> t
val limited : limits -> t -> t
val mounting : (Path.t * mount) list -> t -> t
val mounted : t -> Path.t -> mount option

(** One line that matched a search. *)
type found = { path : string; line : int; text : string }

(** What a shell command printed, stdout and stderr together, and its exit code. *)
type ran = { out : string; code : int }

(** New content for a file, and what the file held when it was first staged. *)
type change = {
  path : Path.t;
  before : string option;  (** [None]: the file did not exist. *)
  after : string option;  (** [None]: the file is deleted. *)
}

val read : t -> Path.t -> (string, [> `Tools of error ]) result Lwt.t
val write : t -> Path.t -> string -> (unit, [> `Tools of error ]) result Lwt.t

val edit :
  t -> Path.t -> old:string -> new_:string -> (unit, [> `Tools of error ]) result Lwt.t

val replaced :
  Path.t -> old:string -> new_:string -> string -> (string, [> `Tools of error ]) result

val grep : t -> pattern:string -> glob:string -> found list Lwt.t
val search : pattern:string -> glob:string -> path:string -> string -> found list
val shell : t -> string -> ran Lwt.t

val contained : t -> change list -> string -> (ran * change list) Lwt.t

val commit : t -> change list -> (unit, [> `Tools of error ]) result Lwt.t
val redacted : string -> string
val revealed : string -> string

(** What a server answered: the HTTP status and the body. *)
type fetched = { status : int; body : string }

(** What a fetch asks the server for. *)
type request =
  | Get
  | Post of string  (** The body sent. *)

val fetch :
  t ->
  request ->
  string ->
  (fetched, [> `Not_granted of string | `Unreachable of string ]) result Lwt.t
