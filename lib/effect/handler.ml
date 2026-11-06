open Lwt.Syntax

module Overlay = struct
  module Paths = Map.Make (String)

  type t = Tools.change Paths.t

  let empty = Paths.empty
  let changes overlay = List.map snd (Paths.bindings overlay)

  let added overlay changes =
    List.fold_left
      (fun overlay (change : Tools.change) ->
        match change with
        | { before = None; after = None; _ } -> Paths.remove (change.path :> string) overlay
        | { before = Some _; _ } | { after = Some _; _ } ->
            Paths.add (change.path :> string) change overlay)
      overlay changes

  (** One line of a diff, with the line numbers before it in each version. *)
  type line = { mark : mark; text : string; old_at : int; new_at : int }

  (** Whether a line stayed, went or came. *)
  and mark = Kept | Removed | Added

  let diff overlay =
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
    String.concat "" (List.map rendered (changes overlay))
end

type 'state step = Performed of (Value.t, Value.t) result * 'state | Blocked
type 'state t = { perform : Value.tool -> 'state -> 'state step Lwt.t }

type outcome =
  | Finished of (Value.t, [ `Failed of Value.t | `Interp of Interp.error ]) result
  | Stopped of Value.task

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

let ran ({ out; code } : Tools.ran) =
  Value.V_record [ ("code", V_number (Float.of_int code)); ("out", V_string out) ]

let run workspace =
  let located path within =
    match Tools.Path.of_string path with
    | Error _ as denied -> Lwt.return (seen denied)
    | Ok path -> within path
  in
  let perform (tool : Value.tool) () =
    let+ result =
      match tool with
      | Read path ->
          located path (fun path ->
              Lwt.map
                (fun read -> seen (Result.map (fun text -> Value.V_string text) read))
                (Tools.read workspace path))
      | Write { path; content } ->
          located path (fun path ->
              Lwt.map
                (fun written -> seen (Result.map (fun () -> Value.V_unit) written))
                (Tools.write workspace path content))
      | Edit { path; old; new_ } ->
          located path (fun path ->
              Lwt.map
                (fun edited -> seen (Result.map (fun () -> Value.V_unit) edited))
                (Tools.edit workspace path ~old ~new_))
      | Grep { pattern; glob } ->
          Lwt.map (fun found -> Ok (matches found)) (Tools.grep workspace ~pattern ~glob)
      | Shell command -> Lwt.map (fun done_ -> Ok (ran done_)) (Tools.shell workspace command)
    in
    Performed (result, ())
  in
  { perform }

type shell = Open | Contained | Disabled

let shells = [ ("contained", Contained); ("open", Open); ("off", Disabled) ]

let staged workspace shell =
  let current overlay (path : Tools.Path.t) =
    match Overlay.Paths.find_opt (path :> string) overlay with
    | Some (change : Tools.change) -> Lwt.return (Ok (change.before, change.after))
    | None ->
        Lwt.map
          (function
            | Ok text -> Ok (Some text, Some text)
            | Error (`Tools (Tools.Not_found _)) -> Ok (None, None)
            | Error _ as failure -> failure)
          (Tools.read workspace path)
  in
  let stored overlay (path : Tools.Path.t) before after =
    Overlay.added overlay [ { Tools.path; before; after } ]
  in
  let perform (tool : Value.tool) overlay =
    let kept result = Performed (seen result, overlay) in
    match tool with
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
        match Tools.Path.of_string path with
        | Error _ as denied -> Lwt.return (kept denied)
        | Ok path ->
            Lwt.map
              (function
                | Ok (before, _) ->
                    Performed (Ok Value.V_unit, stored overlay path before (Some content))
                | Error _ as failure -> kept failure)
              (current overlay path))
    | Edit { path; old; new_ } -> (
        match Tools.Path.of_string path with
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
        let+ on_disk = Tools.grep workspace ~pattern ~glob in
        Performed
          ( Ok
              (matches
                 (List.sort
                    (fun (one : Tools.found) (other : Tools.found) ->
                      compare (one.path, one.line) (other.path, other.line))
                    (List.filter
                       (fun (found : Tools.found) -> not (Overlay.Paths.mem found.path overlay))
                       on_disk
                    @ List.concat_map
                        (fun (change : Tools.change) ->
                          Option.fold ~none:[]
                            ~some:(Tools.search ~pattern ~glob ~path:(change.path :> string))
                            change.after)
                        (Overlay.changes overlay)))),
            overlay )
    | Shell command -> (
        match (shell, Overlay.Paths.min_binding_opt overlay) with
        | Disabled, _ ->
            Lwt.return
              (Performed
                 (Ok (ran { out = "shell is disabled in this run"; code = 126 }), overlay))
        | Open, None ->
            Lwt.map
              (fun done_ -> Performed (Ok (ran done_), overlay))
              (Tools.shell workspace command)
        | Open, Some _ -> Lwt.return Blocked
        | Contained, _ ->
            Lwt.map
              (fun (done_, written) ->
                Performed
                  ( Ok (ran done_),
                    List.fold_left
                      (fun overlay (change : Tools.change) ->
                        stored overlay change.path
                          (Option.fold ~none:change.before
                             ~some:(fun (earlier : Tools.change) -> earlier.before)
                             (Overlay.Paths.find_opt (change.path :> string) overlay))
                          change.after)
                      overlay written ))
              (Tools.contained workspace (Overlay.changes overlay) command))
  in
  { perform }

let rec interpret handler program state (task : Value.task) =
  let continued callback value state =
    match Interp.apply program callback value with
    | Ok (V_task next) -> interpret handler program state next
    | Ok _ ->
        Lwt.return
          ( Finished (Error (`Interp (Interp.Stuck "a continuation that is not a task"))),
            state )
    | Error failure -> Lwt.return (Finished (Error failure), state)
  in
  let resumed rebuild (outcome, state) =
    match outcome with
    | Stopped rest -> (Stopped (rebuild rest), state)
    | Finished _ -> (outcome, state)
  in
  match task with
  | Succeed value -> Lwt.return (Finished (Ok value), state)
  | Fail value -> Lwt.return (Finished (Error (`Failed value)), state)
  | Tool tool -> (
      let+ step = handler.perform tool state in
      match step with
      | Performed (result, state) ->
          (Finished (Result.map_error (fun value -> `Failed value) result), state)
      | Blocked -> (Stopped task, state))
  | And_then { callback; task } -> (
      let* outcome, state = interpret handler program state task in
      match outcome with
      | Finished (Ok value) -> continued callback value state
      | Finished (Error _) -> Lwt.return (outcome, state)
      | Stopped rest -> Lwt.return (Stopped (And_then { callback; task = rest }), state))
  | Map { callback; task } ->
      let+ outcome, state = interpret handler program state task in
      resumed
        (fun rest -> Map { callback; task = rest })
        ( (match outcome with
          | Finished (Ok value) -> Finished (Interp.apply program callback value)
          | Finished (Error _) | Stopped _ -> outcome),
          state )
  | Map_err { callback; task } ->
      let+ outcome, state = interpret handler program state task in
      resumed
        (fun rest -> Map_err { callback; task = rest })
        ( (match outcome with
          | Finished (Error (`Failed value)) ->
              Finished
                (Result.bind (Interp.apply program callback value) (fun value ->
                     Error (`Failed value)))
          | Finished (Ok _ | Error (`Interp _)) | Stopped _ -> outcome),
          state )
  | On_error { callback; task } -> (
      let* outcome, state = interpret handler program state task in
      match outcome with
      | Finished (Error (`Failed value)) -> continued callback value state
      | Finished (Ok _ | Error (`Interp _)) -> Lwt.return (outcome, state)
      | Stopped rest -> Lwt.return (Stopped (On_error { callback; task = rest }), state))
  | Batch tasks ->
      let rec each done_ state = function
        | [] -> Lwt.return (Finished (Ok (Value.V_list (List.rev done_))), state)
        | task :: rest -> (
            let* outcome, state = interpret handler program state task in
            match outcome with
            | Finished (Ok value) -> each (value :: done_) state rest
            | Finished (Error _) -> Lwt.return (outcome, state)
            | Stopped remaining ->
                Lwt.return
                  ( Stopped
                      (Batch
                         (List.rev_map (fun value -> Value.Succeed value) done_
                         @ (remaining :: rest))),
                    state ))
      in
      each [] state tasks
