open Lwt.Syntax

module Overlay = struct
  module Paths = Map.Make (String)

  (** What one process sees over the workspace. *)
  type frame = {
    staged : Tools.change Paths.t;  (** Applied when the changes are settled. *)
    scratch : Tools.change Paths.t;  (** Under a [Scratch] mount: seen, never applied. *)
    mounts : (Tools.Path.t * Tools.mount) list;  (** What spawns added to the workspace's. *)
  }

  (** The running process's frame over the frames of the processes that spawned it, nearest first. *)
  type t = { frame : frame; parents : frame list }

  let empty = { frame = { staged = Paths.empty; scratch = Paths.empty; mounts = [] }; parents = [] }
  let staged frame = List.map snd (Paths.bindings frame.staged)
  let changes overlay = staged (List.fold_left (fun _ parent -> parent) overlay.frame overlay.parents)

  let visible overlay =
    List.map snd
      (Paths.bindings
         (Paths.union (fun _ staged _ -> Some staged) overlay.frame.staged overlay.frame.scratch))

  let found overlay path =
    Option.fold ~none:(Paths.find_opt path overlay.frame.scratch) ~some:Option.some
      (Paths.find_opt path overlay.frame.staged)

  let put paths (change : Tools.change) =
    match change with
    | { before = None; after = None; _ } -> Paths.remove (change.path :> string) paths
    | { before = Some _; _ } | { after = Some _; _ } -> Paths.add (change.path :> string) change paths

  let added overlay changes =
    { overlay with frame = { overlay.frame with staged = List.fold_left put overlay.frame.staged changes } }

  let since earlier later =
    match Int.equal (List.length earlier.parents) (List.length later.parents) with
    | false -> []
    | true ->
        List.filter (fun change -> not (List.mem change (staged earlier.frame))) (staged later.frame)
        @ List.filter_map
            (fun (gone : Tools.change) ->
              Option.fold
                ~none:(Some { gone with before = None; after = None })
                ~some:(fun _ -> None)
                (List.find_opt
                   (fun (kept : Tools.change) -> kept.path = gone.path)
                   (staged later.frame)))
            (staged earlier.frame)

  let after overlay (tool : Value.tool) changes =
    match tool with
    | Enter mounts ->
        {
          frame = { overlay.frame with mounts = overlay.frame.mounts @ mounts };
          parents = overlay.frame :: overlay.parents;
        }
    | Leave -> (
        match overlay.parents with [] -> overlay | parent :: parents -> { frame = parent; parents })
    | Read _ | Write _ | Edit _ | Grep _ | Shell _ | Call _ | Merge _ -> added overlay changes

  (** One line of a diff, with the line numbers before it in each version. *)
  type line = { mark : mark; text : string; old_at : int; new_at : int }

  (** Whether a line stayed, went or came. *)
  and mark = Kept | Removed | Added

  let diff changes =
    let lines text =
      match List.rev (String.split_on_char '\n' text) with
      | "" :: rest -> Array.of_list (List.rev rest)
      | all -> Array.of_list (List.rev all)
    in
    let rendered ({ path; before; after } : Tools.change) =
      let old = lines (Option.value ~default:"" before)
      and fresh = lines (Option.value ~default:"" after) in
      let rows = Array.length old and columns = Array.length fresh in
      let common = Array.make_matrix (rows + 1) (columns + 1) 0 in
      for row = rows - 1 downto 0 do
        for column = columns - 1 downto 0 do
          common.(row).(column) <-
            (if String.equal old.(row) fresh.(column) then
               common.(row + 1).(column + 1) + 1
             else max common.(row + 1).(column) common.(row).(column + 1))
        done
      done;
      let rec walked row column found =
        match (row < rows, column < columns) with
        | true, true when String.equal old.(row) fresh.(column) ->
            walked (row + 1) (column + 1)
              ({ mark = Kept; text = old.(row); old_at = row; new_at = column } :: found)
        | true, _
          when column = columns
               || common.(row + 1).(column) >= common.(row).(column + 1) ->
            walked (row + 1) column
              ({ mark = Removed; text = old.(row); old_at = row; new_at = column }
              :: found)
        | _, true ->
            walked row (column + 1)
              ({ mark = Added; text = fresh.(column); old_at = row; new_at = column }
              :: found)
        | false, false | true, false -> Array.of_list (List.rev found)
      in
      let script = walked 0 0 [] in
      let context = 3 in
      let changed =
        List.filter
          (fun index -> match script.(index).mark with Kept -> false | Removed | Added -> true)
          (List.init (Array.length script) Fun.id)
      in
      let groups =
        List.rev
          (List.fold_left
             (fun groups index ->
               match groups with
               | (first, last) :: rest when index - last <= 2 * context ->
                   (first, index) :: rest
               | _ -> (index, index) :: groups)
             [] changed)
      in
      let hunk (first, last) =
        let low = max 0 (first - context)
        and high = min (Array.length script - 1) (last + context) in
        let span = Array.to_list (Array.sub script low (high - low + 1)) in
        let counted keep =
          List.length (List.filter (fun line -> keep line.mark) span)
        in
        let olds = counted (function Kept | Removed -> true | Added -> false)
        and news = counted (function Kept | Added -> true | Removed -> false) in
        Printf.sprintf "@@ -%d,%d +%d,%d @@\n%s"
          (if olds = 0 then script.(low).old_at else script.(low).old_at + 1)
          olds
          (if news = 0 then script.(low).new_at else script.(low).new_at + 1)
          news
          (String.concat ""
             (List.map
                (fun line ->
                  (match line.mark with Kept -> " " | Removed -> "-" | Added -> "+")
                  ^ line.text ^ "\n")
                span))
      in
      Printf.sprintf "--- %s\n+++ %s\n%s"
        (Option.fold ~none:"/dev/null" ~some:(fun _ -> "a/" ^ (path :> string)) before)
        (Option.fold ~none:"/dev/null" ~some:(fun _ -> "b/" ^ (path :> string)) after)
        (String.concat "" (List.map hunk groups))
    in
    String.concat "" (List.map rendered changes)
end

type 'state step = Performed of (Value.t, Value.t) result * 'state | Blocked | Exhausted
type 'state t = { perform : Value.tool -> Value.source list -> 'state -> 'state step Lwt.t }

type outcome =
  | Finished of (Value.t, [ `Failed of Value.t | `Interp of Interp.error | `Exhausted ]) result
  | Stopped of Value.task
  | Reached of Value.hole

let seen result =
  Result.map_error
    (fun (`Tools (problem : Tools.error)) ->
      let name, detail =
        match problem with
        | Not_found detail -> ("NotFound", detail)
        | Denied detail -> ("Denied", detail)
        | Conflict detail -> ("Conflict", detail)
      in
      Value.V_constr
        { constructor = { module_name = "Agent"; name }; arguments = [ V_string detail ] })
    result

let matches found =
  Value.V_list
    (List.map
       (fun ({ path; line; text } : Tools.found) ->
         Value.V_record
           [
             ("line", V_number (Float.of_int line));
             ("path", V_string path);
             ("text", V_string text);
           ])
       found)

let maybe text =
  Option.fold
    ~none:(Value.V_constr { constructor = { module_name = "Maybe"; name = "Nothing" }; arguments = [] })
    ~some:(fun text ->
      Value.V_constr { constructor = { module_name = "Maybe"; name = "Just" }; arguments = [ V_string text ] })
    text

let ran ({ out; code } : Tools.ran) =
  Value.V_record [ ("code", V_number (Float.of_int code)); ("out", V_string out) ]

let class_of : Value.tool -> Value.class_ = function
  | Read _ | Grep _ -> Pure
  | Write _ | Edit _ | Enter _ | Leave | Merge _ -> Staged
  | Shell _ -> Contained
  | Call { name; argument } -> Device.class_of ~name argument

let run workspace =
  let located path within =
    match Tools.Path.of_string path with
    | Error _ as denied -> Lwt.return (seen denied)
    | Ok path -> within path
  in
  let perform (tool : Value.tool) _ () =
    let performed result = Lwt.map (fun result -> Performed (result, ())) result in
    match tool with
    | Enter _ | Leave | Merge _ -> Lwt.return Blocked
    | Read path ->
        performed
          (located path (fun path ->
               Lwt.map
                 (fun read -> seen (Result.map (fun text -> Value.V_string text) read))
                 (Tools.read workspace path)))
    | Write { path; content } ->
        performed
          (located path (fun path ->
               Lwt.map
                 (fun written -> seen (Result.map (fun () -> Value.V_unit) written))
                 (Tools.write workspace path content)))
    | Edit { path; old; new_ } ->
        performed
          (located path (fun path ->
               Lwt.map
                 (fun edited -> seen (Result.map (fun () -> Value.V_unit) edited))
                 (Tools.edit workspace path ~old ~new_)))
    | Grep { pattern; glob } ->
        performed (Lwt.map (fun found -> Ok (matches found)) (Tools.grep workspace ~pattern ~glob))
    | Shell command -> performed (Lwt.map (fun done_ -> Ok (ran done_)) (Tools.shell workspace command))
    | Call { name; argument } -> performed (Device.perform workspace ~name argument)
  in
  { perform }

type shell = Open | Contained | Disabled

let shells = [ ("contained", Contained); ("open", Open); ("off", Disabled) ]

let staged workspace shell =
  let within (overlay : Overlay.t) = Tools.mounting overlay.frame.mounts workspace in
  let current overlay (path : Tools.Path.t) =
    match (Tools.mounted (within overlay) path, Overlay.found overlay (path :> string)) with
    | Some Hidden, _ -> Lwt.return (Error (`Tools (Tools.Denied (path :> string))))
    | (None | Some (Readonly | Scratch)), Some (change : Tools.change) ->
        Lwt.return (Ok (change.before, change.after))
    | (None | Some (Readonly | Scratch)), None ->
        Lwt.map
          (function
            | Ok text -> Ok (Some text, Some text)
            | Error (`Tools (Tools.Not_found _)) -> Ok (None, None)
            | Error _ as failure -> failure)
          (Tools.read (within overlay) path)
  in
  let unhidden overlay =
    List.filter
      (fun (change : Tools.change) ->
        match Tools.mounted (within overlay) change.path with
        | Some Hidden -> false
        | None | Some (Readonly | Scratch) -> true)
      (Overlay.visible overlay)
  in
  let stored (overlay : Overlay.t) (path : Tools.Path.t) before after =
    match Tools.mounted (within overlay) path with
    | Some Scratch ->
        {
          overlay with
          frame =
            { overlay.frame with scratch = Overlay.put overlay.frame.scratch { Tools.path; before; after } };
        }
    | None | Some (Hidden | Readonly) -> Overlay.added overlay [ { Tools.path; before; after } ]
  in
  let writable overlay path =
    Result.bind (Tools.Path.of_string path) (fun (path : Tools.Path.t) ->
        match Tools.mounted (within overlay) path with
        | Some (Hidden | Readonly) -> Error (`Tools (Tools.Denied (path :> string)))
        | None | Some Scratch -> Ok path)
  in
  let perform (tool : Value.tool) _ (overlay : Overlay.t) =
    let kept result = Performed (seen result, overlay) in
    match tool with
    | Enter _ -> Lwt.return (Performed (Ok Value.V_unit, Overlay.after overlay tool []))
    | Leave -> (
        let left = Overlay.after overlay tool [] in
        let viewed side (file : Tools.Path.t) =
          Lwt.map
            (function Ok (_, after) -> after | Error _ -> None)
            (current side file)
        in
        match overlay.parents with
        | [] -> Lwt.return (Performed (Ok (Value.V_list []), overlay))
        | _ :: _ ->
            let+ patches =
              Lwt_list.map_s
                (fun (change : Tools.change) ->
                  let* base = viewed left change.path in
                  let+ content = viewed overlay change.path in
                  Value.V_record
                    [
                      ("base", maybe base);
                      ("content", maybe content);
                      ("path", V_string (change.path :> string));
                    ])
                (Overlay.since left { overlay with parents = left.parents })
            in
            Performed (Ok (Value.V_list patches), left))
    | Merge patches -> (
        let* checked =
          Lwt_list.map_s
            (fun ({ file; base; content } : Value.patch) ->
              match writable overlay file with
              | Error _ -> Lwt.return (Error { Value.file; base; content })
              | Ok path ->
                  Lwt.map
                    (function
                      | Ok (before, now) when Option.equal String.equal now base -> Ok (path, before, content)
                      | Ok _ | Error _ -> Error { Value.file; base; content })
                    (current overlay path))
            patches
        in
        match List.filter_map (function Ok _ -> None | Error patch -> Some patch) checked with
        | [] ->
            Lwt.return
              (Performed
                 ( Ok Value.V_unit,
                   List.fold_left
                     (fun overlay checked ->
                       match checked with
                       | Ok (path, before, content) -> stored overlay path before content
                       | Error _ -> overlay)
                     overlay checked ))
        | conflicts ->
            Lwt.return
              (Performed
                 ( Error
                     (Value.V_list
                        (List.map
                           (fun ({ file; base; content } : Value.patch) ->
                             Value.V_record
                               [ ("base", maybe base); ("content", maybe content); ("path", V_string file) ])
                           conflicts)),
                   overlay )))
    | Read path -> (
        match Tools.Path.of_string path with
        | Error _ as denied -> Lwt.return (kept denied)
        | Ok path ->
            Lwt.map
              (function
                | Ok (_, Some text) -> Performed (Ok (Value.V_string text), overlay)
                | Ok (_, None) -> kept (Error (`Tools (Tools.Not_found (path :> string))))
                | Error _ as failure -> kept failure)
              (current overlay path))
    | Write { path; content } -> (
        match writable overlay path with
        | Error _ as denied -> Lwt.return (kept denied)
        | Ok path ->
            Lwt.map
              (function
                | Ok (before, _) ->
                    Performed (Ok Value.V_unit, stored overlay path before (Some content))
                | Error _ as failure -> kept failure)
              (current overlay path))
    | Edit { path; old; new_ } -> (
        match writable overlay path with
        | Error _ as denied -> Lwt.return (kept denied)
        | Ok path ->
            Lwt.map
              (function
                | Ok (before, Some text) -> (
                    match Tools.replaced path ~old ~new_ text with
                    | Ok after ->
                        Performed (Ok Value.V_unit, stored overlay path before (Some after))
                    | Error _ as failure -> kept failure)
                | Ok (_, None) -> kept (Error (`Tools (Tools.Not_found (path :> string))))
                | Error _ as failure -> kept failure)
              (current overlay path))
    | Grep { pattern; glob } ->
        let+ on_disk = Tools.grep (within overlay) ~pattern ~glob in
        Performed
          ( Ok
              (matches
                 (List.sort
                    (fun (one : Tools.found) (other : Tools.found) ->
                      compare (one.path, one.line) (other.path, other.line))
                    (List.filter
                       (fun (found : Tools.found) -> Option.is_none (Overlay.found overlay found.path))
                       on_disk
                    @ List.concat_map
                        (fun (change : Tools.change) ->
                          Option.fold ~none:[]
                            ~some:(Tools.search ~pattern ~glob ~path:(change.path :> string))
                            change.after)
                        (unhidden overlay)))),
            overlay )
    | Call { name; argument } ->
        Lwt.map
          (fun result -> Performed (result, overlay))
          (Device.perform (within overlay) ~name argument)
    | Shell command -> (
        match (shell, Overlay.visible overlay, overlay.parents) with
        | Open, _, _ :: _ ->
            Lwt.return
              (Performed
                 ( Ok (ran { out = "a spawned process runs commands only with --shell contained"; code = 126 }),
                   overlay ))
        | Disabled, _, _ ->
            Lwt.return
              (Performed
                 (Ok (ran { out = "shell is disabled in this run"; code = 126 }), overlay))
        | Open, [], [] ->
            Lwt.map
              (fun done_ -> Performed (Ok (ran done_), overlay))
              (Tools.shell workspace command)
        | Open, _ :: _, [] -> Lwt.return Blocked
        | Contained, _, _ ->
            Lwt.map
              (fun (done_, written) ->
                Performed
                  ( Ok (ran done_),
                    List.fold_left
                      (fun overlay (change : Tools.change) ->
                        stored overlay change.path
                          (Option.fold ~none:change.before
                             ~some:(fun (earlier : Tools.change) -> earlier.before)
                             (Overlay.found overlay (change.path :> string)))
                          change.after)
                      overlay written ))
              (Tools.contained (within overlay) (unhidden overlay) command))
  in
  { perform }

module Boot = struct
  type layer = Budget of int | Policy | Journal
  type t = layer list

  let standard = [ Journal; Policy ]

  let of_layers layers =
    match
      ( List.filter (function Budget _ -> false | Policy | Journal -> true) layers,
        List.filter_map (function Budget calls -> Some calls | Policy | Journal -> None) layers )
    with
    | [ Journal; Policy ], [] -> Ok layers
    | [ Journal; Policy ], [ calls ] when calls >= 0 -> Ok layers
    | [ Journal; Policy ], [ _ ] -> Error "a budget of tool calls cannot be below zero"
    | [ Journal; Policy ], _ :: _ :: _ -> Error "boot has more than one budget"
    | _ ->
        Error
          "boot lists journal once and policy once, journal first, so the log holds every \
           answer the person gives"

  let narrowed earlier later =
    let budget = List.find_map (function Budget calls -> Some calls | Policy | Journal -> None) in
    match (budget earlier, budget later) with
    | None, _ -> later
    | Some calls, None -> Budget calls :: later
    | Some calls, Some fewer ->
        List.map (function Budget _ -> Budget (min calls fewer) | (Policy | Journal) as layer -> layer) later
end

let booted boot ~class_of ~person ~journal base =
  List.fold_right
    (fun (layer : Boot.layer) inner ->
      match layer with
      | Journal -> journal inner
      | Policy ->
          {
            perform =
              (fun tool sources state ->
                let carried =
                  List.filter_map
                    (fun (source : Value.source) ->
                      match source with
                      | File path -> Some path
                      | Search -> Some "lines grep found"
                      | Command -> Some "a shell command's output"
                      | Child -> Some "a child process's changes"
                      | Driver _ -> None)
                    sources
                in
                let asked question declined =
                  let* consent = person question in
                  match consent with
                  | Device.Agrees -> inner.perform tool sources state
                  | Declines -> Lwt.return (Performed (declined, state))
                in
                match ((class_of tool : Value.class_), carried) with
                | Irreversible { question; declined }, [] -> asked question (Error declined)
                | Irreversible { question; declined }, _ :: _ ->
                    asked
                      (question ^ "\n\nIt carries content of the project: " ^ String.concat ", " carried)
                      (Error declined)
                | Egress { declined }, _ :: _ ->
                    asked
                      ("send content of the project (" ^ String.concat ", " carried ^ ") out with "
                      ^ Yojson.Safe.to_string (Value.tool_to_json tool))
                      declined
                | (Pure | Staged | Contained | Egress _), _ -> inner.perform tool sources state);
          }
      | Budget calls ->
          let spent = ref 0 in
          {
            perform =
              (fun tool sources state ->
                match !spent < calls with
                | false -> Lwt.return Exhausted
                | true ->
                    let+ step = inner.perform tool sources state in
                    (match step with Performed _ -> incr spent | Blocked | Exhausted -> ());
                    step);
          })
    boot base

let interpret handler program state (task : Value.task) =
  let rec interpret ~pc state (task : Value.task) =
    let continued callback value state =
      match Interp.apply program callback value with
      | Ok (V_task next) -> interpret ~pc state next
      | Ok _ ->
          Lwt.return
            (Finished (Error (`Interp (Interp.Stuck "a continuation that is not a task"))), state)
      | Error failure -> Lwt.return (Finished (Error failure), state)
    in
    let resumed rebuild (outcome, state) =
      match outcome with
      | Stopped rest -> (Stopped (rebuild rest), state)
      | Finished _ | Reached _ -> (outcome, state)
    in
    match task with
    | Succeed value -> Lwt.return (Finished (Ok value), state)
    | Fail value -> Lwt.return (Finished (Error (`Failed value)), state)
    | Labelled { sources; task } ->
        let+ outcome, state = interpret ~pc:(List.sort_uniq compare (sources @ pc)) state task in
        ( (match outcome with
          | Finished (Ok value) -> Finished (Ok (Value.labelled sources value))
          | Finished (Error (`Failed value)) -> Finished (Error (`Failed (Value.labelled sources value)))
          | Finished (Error (`Interp _ | `Exhausted)) | Reached _ -> outcome
          | Stopped rest -> Stopped (Labelled { sources; task = rest })),
          state )
    | Tool tool -> (
        let+ step = handler.perform tool pc state in
        let stamped = Value.labelled (Value.sources tool) in
        match step with
        | Performed (result, state) ->
            ( Finished
                (Result.fold
                   ~ok:(fun value -> Ok (stamped value))
                   ~error:(fun value -> Error (`Failed (stamped value)))
                   result),
              state )
        | Blocked -> (Stopped task, state)
        | Exhausted -> (Finished (Error `Exhausted), state))
    | Hole hole -> Lwt.return (Reached hole, state)
    | And_then { callback; task } -> (
        let* outcome, state = interpret ~pc state task in
        match outcome with
        | Finished (Ok value) -> continued callback value state
        | Finished (Error _) | Reached _ -> Lwt.return (outcome, state)
        | Stopped rest -> Lwt.return (Stopped (And_then { callback; task = rest }), state))
    | Map { callback; task } ->
        let+ outcome, state = interpret ~pc state task in
        resumed
          (fun rest -> Map { callback; task = rest })
          ( (match outcome with
            | Finished (Ok value) -> Finished (Interp.apply program callback value)
            | Finished (Error _) | Stopped _ | Reached _ -> outcome),
            state )
    | Map_err { callback; task } ->
        let+ outcome, state = interpret ~pc state task in
        resumed
          (fun rest -> Map_err { callback; task = rest })
          ( (match outcome with
            | Finished (Error (`Failed value)) ->
                Finished
                  (Result.bind (Interp.apply program callback value) (fun value ->
                       Error (`Failed value)))
            | Finished (Ok _ | Error (`Interp _ | `Exhausted)) | Stopped _ | Reached _ -> outcome),
            state )
    | On_error { callback; task } -> (
        let* outcome, state = interpret ~pc state task in
        match outcome with
        | Finished (Error (`Failed value)) -> continued callback value state
        | Finished (Ok _ | Error (`Interp _ | `Exhausted)) | Reached _ -> Lwt.return (outcome, state)
        | Stopped rest -> Lwt.return (Stopped (On_error { callback; task = rest }), state))
    | Batch tasks ->
        let rec each done_ state = function
          | [] -> Lwt.return (Finished (Ok (Value.V_list (List.rev done_))), state)
          | task :: rest -> (
              let* outcome, state = interpret ~pc state task in
              match outcome with
              | Finished (Ok value) -> each (value :: done_) state rest
              | Finished (Error _) | Reached _ -> Lwt.return (outcome, state)
              | Stopped remaining ->
                  Lwt.return
                    ( Stopped
                        (Batch (List.rev_map (fun value -> Value.Succeed value) done_ @ (remaining :: rest))),
                      state ))
        in
        each [] state tasks
  in
  let+ outcome, state = interpret ~pc:[] state task in
  ( (match outcome with
    | Finished (Ok value) -> Finished (Ok (snd (Value.plain value)))
    | Finished (Error (`Failed value)) -> Finished (Error (`Failed (snd (Value.plain value))))
    | Finished (Error (`Interp _ | `Exhausted)) | Stopped _ | Reached _ -> outcome),
    state )
