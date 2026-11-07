(** One MCP connection: the folder it works in, how commands run, and where its events go. *)
type t

val start : Os.t -> Handler.shell -> on:(Driver.event -> unit Lwt.t) -> t
val handled : t -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t
