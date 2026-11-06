module Overlay : sig
  (** Writes staged over a workspace and not yet on disk; keeping an old value is a fork. *)
  type t

  val empty : t
  val changes : t -> Tools.change list
  val added : t -> Tools.change list -> t
  val diff : t -> string
end

(** What a handler did with one tool. *)
type 'state step =
  | Performed of (Value.t, Value.t) result * 'state
      (** [Error] carries the [IoErr] value the program sees. *)
  | Blocked  (** The handler will not perform the tool now. *)

(** What performs the tools of a task, threading its own state. *)
type 'state t = { perform : Value.tool -> 'state -> 'state step Lwt.t }

(** How far a task got. *)
type outcome =
  | Finished of (Value.t, [ `Failed of Value.t | `Interp of Interp.error ]) result
  | Stopped of Value.task  (** The rest of the task, starting at the blocked tool. *)

(** How a staged handler runs shell commands. *)
type shell =
  | Open  (** In the workspace itself, and only when nothing is staged. *)
  | Contained  (** In a sandboxed clone that sees the staged changes; its writes are staged. *)
  | Disabled  (** Never; the program sees exit code 126. *)

val shells : (string * shell) list
val run : Tools.t -> unit t
val staged : Tools.t -> shell -> Overlay.t t
val interpret : 'state t -> Interp.t -> 'state -> Value.task -> (outcome * 'state) Lwt.t
