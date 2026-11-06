(** One module of a compiled program, cut down to what [Main.main] reaches. *)
type t = private {
  module_name : string;
  declarations : Ir.Ast.declaration list;
  constructors : (Data.Name.t * int) list;  (** Constructors with arities. *)
}

val compile : string -> (t list, string) result
