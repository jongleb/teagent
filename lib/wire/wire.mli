(** A step from a JSON node down to one of its children. *)
type step =
  | Index of int  (** An element of an array. *)
  | Key of string  (** A member of an object. *)

(** One change that brings the old tree closer to the new one; edits apply in order. *)
type edit =
  | Set of { path : step list; value : Yojson.Safe.t }  (** The node at [path] becomes [value]. *)
  | Splice of { path : step list; at : int; removed : int; inserted : Yojson.Safe.t list }
      (** In the array at [path], [removed] elements from [at] give way to [inserted]. *)

val json : Value.t -> Yojson.Safe.t
val diff : Yojson.Safe.t -> Yojson.Safe.t -> edit list
val edit_json : edit -> Yojson.Safe.t
