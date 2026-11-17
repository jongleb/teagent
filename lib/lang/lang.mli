(** One module of a compiled program, cut down to what its entries reach. *)
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
  val name : t -> string
  val source : t -> string
end

(** The Agent module programs compile against: the calls one OS offers, and the skills whose needs
    it meets. *)
module Calls : sig
  type t

  val all : t
  val taught : Skill.t list -> t -> t
  val without : Data.Kernel.agent list -> t -> t
  val plugging : Device.t list -> t -> t
  val unplugged : Device.t list -> t -> t
  val source : t -> string
end

(** A call a compiled program can make, found before it runs. *)
type call =
  | Kernel of Data.Kernel.agent  (** One of Agent's tools, [hole] included. *)
  | Driver of string  (** A driver call by its name, such as [fetch.get]. *)
  | Computed  (** A driver call whose name is not written out. *)

(** A kernel of [Json.Decode] and [Json.Encode]; it works on [Value.V_json]. *)
module Json : sig
  type t =
    | Is_string
    | Is_bool
    | Is_number
    | Is_int
    | Is_null
    | Is_array
    | Is_object
    | Has_field
    | Unsafe_field
    | Length
    | Unsafe_index
    | Identity  (** Between a JSON string, bool or number and the Elm value. *)
    | Stringify
    | Is_valid
    | Unsafe_parse
    | Empty_array
    | Pushed
    | Empty_object
    | With_field

  val of_name : Data.Name.t -> t option
end

val module_name : string -> string option
val compile : Calls.t -> string -> (t list, string) result

val compile_modules :
  (string * string) list -> entries:Value.global list -> (t list, string) result
val calls : t list -> call list
