(** Who did something in a session. *)
type agent =
  | Main  (** The program the model wrote. *)
  | Spawned of { id : int; parent : agent }  (** A process [spawn] began; ids count from 1. *)

(** The files one event looked at and changed. *)
type touched = { read : Tools.Path.t list; changed : Tools.Path.t list }

(** A file of the staged changes, with the runs of lines that changed. *)
type file = { change : Tools.change; hunks : Handler.Overlay.hunk list }

(** What happened. *)
type happened =
  | Logged of Driver.event  (** As the session's log records it. *)
  | Began of int  (** The agent spawned the child with this id. *)
  | Merged of int  (** The agent took in the changes of the child with this id. *)
  | Proposed of file list  (** The staged changes the person is asked to apply. *)

type event = {
  agent : agent;
  step : string option;  (** What the model last said it was doing. *)
  spent : Llm.usage;  (** The session's tokens so far. *)
  touched : touched;
  happened : happened;
}

val solve : Driver.world -> on:(event -> unit Lwt.t) -> cancelled:unit Lwt.t -> string -> Driver.report Lwt.t
