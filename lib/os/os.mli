(** A call an OS can offer an agent. *)
type call = Bash | Read | Write | Edit | Grep

val calls : (string * call) list

(** What one task may do. Only [granted] gives rights; every other function returns an OS no
    wider than the one it takes. *)
type t

val granted : string -> net:string list -> t
val only : call list -> t -> t
val hiding : Tools.Path.t list -> t -> t
val freezing : Tools.Path.t list -> t -> t
val reading : string list -> t -> t
val reaching : string list -> t -> t
val narrowed : Yojson.Safe.t -> t -> (t, string) result

(** What an OS allows, to read; building one this way gives no OS. *)
type view = {
  offers : call list;
  hidden : Tools.Path.t list;
  readonly : Tools.Path.t list;
  reads : Tools.reads;
  net : string list;
}

val view : t -> view
val workspace : t -> Tools.t
