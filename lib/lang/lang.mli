(** One module of a compiled program, cut down to what [Main.main] reaches. *)
type t = private {
  module_name : string;
  declarations : Ir.Ast.declaration list;
  constructors : (Data.Name.t * int) list;  (** Constructors with arities. *)
}

(** A module programs may import. It needs the calls its [import Agent exposing (...)] names, all
    of them when it imports Agent whole, and the drivers and skills it imports. *)
module Skill : sig
  type t

  val of_source : name:string -> string -> (t, string) result
  val source : t -> string
end

(** The Agent module programs compile against: the calls one OS offers, and the skills whose needs
    it meets. *)
module Calls : sig
  type t

  val all : t
  val taught : Skill.t list -> t -> t
  val without : Data.Kernel.agent list -> t -> t
  val unplugged : Device.t list -> t -> t
  val source : t -> string
end

val compile : Calls.t -> string -> (t list, string) result
