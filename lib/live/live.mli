(** A long-lived program: its model now, and the functions that move it on. *)
type t

(** A source the program listens to, and the task that turns its news into one message. *)
type listening = { source : string; task : Value.task }

(** What a call of a program can do, known before it runs. *)
type power =
  | Reads  (** It only reads. *)
  | Sends  (** It sends data out to a host. *)
  | Changes  (** It changes files, runs a command, or acts on the world outside. *)
  | Asks  (** It asks the person a question. *)

type error = [ `Interp of Interp.error | `Undeclared of Value.global | `Live of string ]

val started : Interp.t -> Value.global -> (t * Value.task list, [> error ]) result
val drawn : t -> (Value.t, [> error ]) result
val updated : t -> Value.t -> (t * Value.task list, [> error ]) result
val listening : t -> (listening list, [> error ]) result
val message : t -> view:Value.t -> Wire.step list -> Value.t list -> (Value.t, [> error ]) result
val powers : devices:Device.t list -> Lang.t list -> (Lang.call * power) list
