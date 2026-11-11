(** A call an OS can offer an agent. *)
type call =
  | Bash
  | Read
  | Write
  | Edit
  | Grep
  | Run  (** A Dartea program; it sees only the other calls this OS offers. *)
  | Fetch  (** The [Fetch] module of programs, over the hosts granted with [--net]. *)

val calls : (string * call) list

(** What one task may do. Only [granted] gives rights; every other function returns an OS no
    wider than the one it takes. *)
type t

val granted : string -> net:string list -> t
val taught : Lang.Skill.t list -> t -> t
val only : call list -> t -> t
val mounting : (Tools.Path.t * Tools.mount) list -> t -> t
val reading : string list -> t -> t
val reaching : string list -> t -> t
val narrowed : Yojson.Safe.t -> t -> (t, string) result

(** What an OS allows, to read; building one this way gives no OS. *)
type view = {
  offers : call list;
  mounts : (Tools.Path.t * Tools.mount) list;
  reads : Tools.reads;
  net : string list;
  boot : Handler.Boot.t;  (** The layers around the tools; a narrower OS only lowers the budget. *)
  seconds : int;  (** How long one command may run; a narrower OS only lowers it. *)
}

val view : t -> view
val workspace : t -> Tools.t
val table : t -> Lang.Calls.t

(** The three legs of a leak in one program, each with the calls that give it. *)
type exposure = {
  reads : string list;  (** Calls that read the project. *)
  inward : string list;  (** Calls that bring in text the model did not write. *)
  outward : string list;  (** Calls that send data out. *)
}

val class_of : t -> Value.tool -> Value.class_
val exposure : t -> Lang.call list -> exposure option
val abi : int
val image : t -> string
