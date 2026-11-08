(** A program on its way to a value: its source, and what its tools returned so far. *)
type t

(** A hole a run reached and code can fill. *)
type hole

(** One tool the run performed, with what it returned and staged. *)
type step = {
  tool : Value.tool;
  result : (Value.t, Value.t) result;
  staged : Tools.change list;  (** What it added to the changes to apply. *)
  after : Handler.Overlay.t;  (** The whole overlay after it, scratch included. *)
}

(** Where a run stopped. *)
type outcome =
  | Finished of (Value.t, [ `Failed of Value.t | `Interp of Interp.error ]) result
  | Reached of hole  (** [filled] gives the run that goes on from it. *)
  | Unfillable of string  (** Why the hole it reached cannot be filled. *)

val compiled : Lang.Calls.t -> string -> (t, string) result

val run :
  t ->
  Handler.Overlay.t Handler.t ->
  settle:(Handler.Overlay.t -> (unit, 'e) result Lwt.t) ->
  (outcome * Handler.Overlay.t, 'e) result Lwt.t

val stopped : Interp.error -> string
val description : hole -> string
val question : hole -> string
val performed : hole -> step list
val filled : hole -> string -> (t, string) result
