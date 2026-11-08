(** One module of a compiled program, cut down to what [Main.main] reaches. *)
type t = private {
  module_name : string;
  declarations : Ir.Ast.declaration list;
  constructors : (Data.Name.t * int) list;  (** Constructors with arities. *)
}

(** The Agent module programs compile against: the calls one OS offers. *)
module Calls : sig
  type t

  val all : t
  val without : Data.Kernel.agent list -> t -> t
  val unplugged : Device.t list -> t -> t
  val source : t -> string
end

val compile : Calls.t -> string -> (t list, string) result
