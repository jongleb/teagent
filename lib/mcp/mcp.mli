(** One MCP connection: the folder it works in, how commands run, and where its events go. *)
type t

(** A tool a connection can serve. *)
type tool = Bash | Read | Write | Edit | Grep

val tools : (string * tool) list
val start : Tools.t -> Handler.shell -> serves:tool list -> on:(Driver.event -> unit Lwt.t) -> t
val handled : t -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t
