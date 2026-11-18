(** Why a program stopped. *)
type error =
  | Budget_exhausted  (** The program took more steps than it was given. *)
  | Crashed of string  (** The program itself failed, as [modBy 0] does. *)
  | Stuck of string  (** The IR does not fit its values: a pipeline bug, never a program bug. *)

(** How many steps a loaded program may take. *)
type budget =
  | Total of int  (** Shared by every call into the program; it only goes down. *)
  | Each of int  (** Given afresh to every [main], [lookup] and [apply], as for a view drawn again. *)

(** A loaded program with its remaining step budget. *)
type t

val load : budget:budget -> Lang.t list -> t
val main : t -> (Value.task, [> `Interp of error ]) result
val lookup :
  t -> Value.global -> (Value.t, [> `Interp of error | `Undeclared of Value.global ]) result
val apply : t -> Value.closure -> Value.t -> (Value.t, [> `Interp of error ]) result
val spent : t -> int
val used : t -> int
