module Overlay : sig
  (** Writes staged over a workspace and not yet on disk; keeping an old value is a fork. *)
  type t

  val empty : t
  val changes : t -> Tools.change list
  val since : t -> t -> Tools.change list
  val after : t -> Value.tool -> Tools.change list -> t
  val diff : Tools.change list -> string
end

(** What a handler did with one tool. *)
type 'state step =
  | Performed of (Value.t, Value.t) result * 'state
      (** [Error] carries the [IoErr] value the program sees. *)
  | Blocked  (** The handler will not perform the tool now. *)
  | Exhausted  (** The OS's budget of tool calls is spent; the program ends at this tool. *)

(** What performs the tools of a task, threading its own state. *)
type 'state t = { perform : Value.tool -> 'state -> 'state step Lwt.t }

(** How far a task got. *)
type outcome =
  | Finished of (Value.t, [ `Failed of Value.t | `Interp of Interp.error | `Exhausted ]) result
  | Stopped of Value.task  (** The rest of the task, starting at the blocked tool. *)
  | Reached of Value.hole  (** A hole the agent has to fill before the program can go on. *)

(** How a staged handler runs shell commands. *)
type shell =
  | Open  (** In the workspace itself, and only when nothing is staged. *)
  | Contained  (** In a sandboxed clone that sees the staged changes; its writes are staged. *)
  | Disabled  (** Never; the program sees exit code 126. *)

val shells : (string * shell) list
val class_of : Value.tool -> Value.class_

val run : Tools.t -> unit t
val staged : Tools.t -> shell -> Overlay.t t

(** The layers an OS boots around the tools, outermost first. *)
module Boot : sig
  (** One wrapper around the handler inside it. *)
  type layer =
    | Budget of int  (** Lets this many calls that reach it be performed in a run; then [Exhausted]. *)
    | Policy  (** Asks the person before an irreversible call. *)
    | Journal  (** Logs each call that reaches it; a replay answers here from the log. *)

  (** One [Journal] outside one [Policy], so the log holds every answer of the person; at most
      one [Budget]. *)
  type t = private layer list

  val standard : t
  val of_layers : layer list -> (t, string) result

  val narrowed : t -> t -> t
end

val booted :
  Boot.t ->
  person:(string -> Device.consent Lwt.t) ->
  journal:('state t -> 'state t) ->
  'state t ->
  'state t
val interpret : 'state t -> Interp.t -> 'state -> Value.task -> (outcome * 'state) Lwt.t
