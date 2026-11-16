(** One MCP connection: the folder it works in, how commands run, and where its events go. *)
type t

val start :
  Os.t ->
  Handler.Overlay.t Handler.t ->
  send:(Yojson.Safe.t -> unit Lwt.t) ->
  on:(Driver.event -> unit Lwt.t) ->
  t
val handled : t -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t
