(** Why a program stopped. *)
type error =
  | Budget_exhausted  (** The program took more steps than it was given. *)
  | Crashed of string  (** The program itself failed, as [modBy 0] does. *)
  | Stuck of string  (** The IR does not fit its values: a pipeline bug, never a program bug. *)

(** A loaded program with its remaining step budget. *)
type t

val load : budget:int -> Lang.t list -> t
val main : t -> (Value.task, [> `Interp of error ]) result
val apply : t -> Value.closure -> Value.t -> (Value.t, [> `Interp of error ]) result
