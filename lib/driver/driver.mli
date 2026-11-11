(** What the user decided about staged changes. *)
type decision = Apply | Discard

(** What happened during a session, in order; replaying its log reproduces it exactly. *)
type event =
  | Wrote of string  (** A reply of the model that carries a program. *)
  | Refused of string  (** The compiler's report, sent back to the model. *)
  | Performed of {
      tool : Value.tool;
      result : (Value.t, Value.t) result;
      staged : Tools.change list;  (** What the tool added to the staged changes. *)
    }
  | Deferred of Value.tool  (** The handler held the tool back until the changes are settled. *)
  | Exhausted of Value.tool  (** The budget of tool calls ran out at this tool. *)
  | Staged of string  (** The diff of the changes waiting for approval. *)
  | Decided of decision
  | Held of { diff : string; decision : decision }
      (** Changes to files that run outside the sandbox, shown apart, and the person's answer. *)
  | Committed of (Tools.Path.t list, string) result  (** The paths written, or why none were. *)
  | Ran of string  (** What the program returned, as the model sees it. *)
  | Guessed of string  (** A reply without a program before any program ran; sent back once. *)
  | Answered of string  (** The model's final reply, without a program. *)
  | Filled of { hole : string; reply : string }  (** A reply with the code for a reached hole. *)

(** Why a session ended without an answer. *)
type stop =
  | Llm_failed of Llm.error
  | Never_compiled of string  (** The last report, after every allowed round failed. *)
  | Discarded  (** The user did not apply the changes. *)
  | Too_many_programs

(** How a session ended, and how many compile rounds each program took. *)
type report = { ending : (string, stop) result; rounds : int list }

(** Everything a session touches outside itself: the model, the person, the tools, the disk. *)
type world = {
  ask : system:string -> Llm.message list -> (string, [ `Llm of Llm.error ]) result Lwt.t;
  approve : string -> decision Lwt.t;
  person : string -> Device.consent Lwt.t;  (** Asked before an irreversible call. *)
  handler : Handler.Overlay.t Handler.t;  (** The tools; [boot] puts its layers around them. *)
  boot : Handler.Boot.t;
  commit : Tools.change list -> (unit, [ `Tools of Tools.error ]) result Lwt.t;
  calls : Lang.Calls.t;  (** What the programs of this session may call. *)
  recorded : event list;  (** An earlier run of the session: it answers first, until this one strays. *)
}

val explained : stop -> string
val solve : world -> on:(event -> unit Lwt.t) -> string -> report Lwt.t
val replayed : Lang.Calls.t -> Handler.Boot.t -> event list -> world
val undone : event list -> Tools.change list
val event_to_json : event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (event, string) result
