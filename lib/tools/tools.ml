open Lwt.Syntax

type error = Not_found of string | Denied of string | Conflict of string

module Path = struct
  type t = string

  let of_string written =
    let parts =
      List.filter
        (fun part -> not (String.equal part "" || String.equal part "."))
        (String.split_on_char '/' written)
    in
    match
      ( Filename.is_relative written,
        List.exists (String.equal "..") parts,
        List.map String.lowercase_ascii parts )
    with
    | ( true,
        false,
        (".git" | ".claude" | ".codex" | ".cursor" | ".mcp.json" | ".teagent" | ".envrc"
        | ".vscode")
        :: _ ) ->
        Error (`Tools (Denied written))
    | true, false, _ :: _ -> Ok (String.concat "/" parts)
    | _, _, _ -> Error (`Tools (Denied written))
end

type reads = Anywhere | Within of string list
type limits = { hidden : Path.t list; readonly : Path.t list; reads : reads }
type t = { root : string; limits : limits }

let at root = { root; limits = { hidden = []; readonly = []; reads = Anywhere } }
let limited limits workspace = { workspace with limits }

let located workspace access (path : Path.t) =
  let denied = Error (`Tools (Denied (path :> string))) in
  match Unix.realpath workspace.root with
  | exception Unix.Unix_error _ -> Error (`Tools (Not_found (path :> string)))
  | root ->
      let parts = String.split_on_char '/' (path :> string) in
      let count = List.length parts in
      let resolved kept =
        match
          Unix.realpath (String.concat "/" (root :: List.filteri (fun index _ -> index < kept) parts))
        with
        | exception Unix.Unix_error _ -> None
        | real -> Some (String.concat "/" (real :: List.filteri (fun index _ -> index >= kept) parts))
      in
      Option.fold ~none:denied
        ~some:(fun real ->
          match String.starts_with ~prefix:(root ^ "/") real with
          | false -> denied
          | true ->
              Result.fold
                ~ok:(fun (inside : Path.t) ->
                  let covering entries =
                    List.find_opt
                      (fun (entry : Path.t) ->
                        let entry = String.lowercase_ascii (entry :> string)
                        and inside = String.lowercase_ascii (inside :> string) in
                        String.equal inside entry || String.starts_with ~prefix:(entry ^ "/") inside)
                      entries
                  in
                  match
                    ( access,
                      covering workspace.limits.hidden,
                      covering workspace.limits.readonly )
                  with
                  | _, Some _, _ | `Writing, None, Some _ -> denied
                  | `Reading, None, _ | `Writing, None, None ->
                      Ok (Filename.concat root (inside :> string)))
                ~error:(fun _ -> denied)
                (Path.of_string
                   (String.sub real (String.length root + 1)
                      (String.length real - String.length root - 1))))
        (List.find_map resolved (List.init (count + 1) (fun index -> count - index)))

type found = { path : string; line : int; text : string }
type ran = { out : string; code : int }
type change = { path : Path.t; before : string option; after : string option }

let failed path = function
  | Unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> `Tools (Not_found path)
  | Unix.Unix_error ((EACCES | EPERM | EROFS), _, _) -> `Tools (Denied path)
  | Unix.Unix_error (problem, _, _) ->
      `Tools (Conflict (path ^ ": " ^ Unix.error_message problem))
  | problem -> `Tools (Conflict (path ^ ": " ^ Printexc.to_string problem))

let read workspace (path : Path.t) =
  match located workspace `Reading path with
  | Error _ as denied -> Lwt.return denied
  | Ok file ->
      Lwt.catch
        (fun () -> Lwt.map Result.ok (Lwt_io.with_file ~mode:Lwt_io.Input file Lwt_io.read))
        (fun problem -> Lwt.return (Error (failed path problem)))

let write workspace (path : Path.t) content =
  match located workspace `Writing path with
  | Error _ as denied -> Lwt.return denied
  | Ok file ->
      let staging =
        Filename.concat (Filename.dirname file) ("." ^ Filename.basename file ^ ".teagent")
      in
      let rec made directory =
        Lwt.catch
          (fun () -> Lwt_unix.mkdir directory 0o755)
          (function
            | Unix.Unix_error (EEXIST, _, _) -> Lwt.return_unit
            | Unix.Unix_error (ENOENT, _, _) ->
                let* () = made (Filename.dirname directory) in
                Lwt_unix.mkdir directory 0o755
            | problem -> Lwt.fail problem)
      in
      Lwt.catch
        (fun () ->
          let* () = made (Filename.dirname file) in
          let* () =
            Lwt_io.with_file ~mode:Lwt_io.Output staging (fun channel ->
                Lwt_io.write channel content)
          in
          let* () = Lwt_unix.rename staging file in
          Lwt.return (Ok ()))
        (fun problem -> Lwt.return (Error (failed path problem)))

let placed workspace change =
  match change.after with
  | Some text -> write workspace change.path text
  | None -> (
      match located workspace `Writing change.path with
      | Error _ as denied -> Lwt.return denied
      | Ok file ->
          Lwt.catch
            (fun () ->
              let* () = Lwt_unix.unlink file in
              Lwt.return (Ok ()))
            (function
              | Unix.Unix_error (ENOENT, _, _) -> Lwt.return (Ok ())
              | problem -> Lwt.return (Error (failed change.path problem))))

let replaced (path : Path.t) ~old ~new_ text =
  let rec occurrences from found =
    match String.length old > 0 && from + String.length old <= String.length text with
    | false -> List.rev found
    | true when String.equal (String.sub text from (String.length old)) old ->
        occurrences (from + String.length old) (from :: found)
    | true -> occurrences (from + 1) found
  in
  match occurrences 0 [] with
  | [ at ] ->
      Ok
        (String.sub text 0 at ^ new_
        ^ String.sub text (at + String.length old)
            (String.length text - at - String.length old))
  | [] -> Error (`Tools (Conflict (path ^ ": the old text is not in the file")))
  | several ->
      Error
        (`Tools
          (Conflict
             (Printf.sprintf "%s: the old text occurs %d times, not once" path
                (List.length several))))

let edit workspace path ~old ~new_ =
  let* found = read workspace path in
  match Result.bind found (replaced path ~old ~new_) with
  | Error _ as failure -> Lwt.return failure
  | Ok text -> write workspace path text

let search ~pattern ~glob ~path text =
  let rec segments pattern path =
    match (pattern, path) with
    | [], [] -> true
    | "**" :: rest, _ -> (
        segments rest path
        || match path with _ :: deeper -> segments pattern deeper | [] -> false)
    | written :: pattern, name :: path ->
        let rec letters at from =
          match (at < String.length written, from < String.length name) with
          | false, ended -> not ended
          | true, _ when Char.equal written.[at] '*' ->
              letters (at + 1) from
              || (from < String.length name && letters at (from + 1))
          | true, false -> false
          | true, true ->
              (Char.equal written.[at] '?' || Char.equal written.[at] name.[from])
              && letters (at + 1) (from + 1)
        in
        letters 0 0 && segments pattern path
    | [], _ :: _ | _ :: _, [] -> false
  in
  match
    ( segments (String.split_on_char '/' glob) (String.split_on_char '/' path),
      Str.regexp pattern )
  with
  | exception Failure _ -> []
  | false, _ -> []
  | true, expression ->
      List.filter_map Fun.id
        (List.mapi
           (fun index line ->
             match Str.search_forward expression line 0 with
             | _ -> Some { path; line = index + 1; text = line }
             | exception Not_found -> None)
           (String.split_on_char '\n' text))

let rec walked root relative =
  let* names =
    Lwt.catch
      (fun () -> Lwt_stream.to_list (Lwt_unix.files_of_directory (Filename.concat root relative)))
      (fun _ -> Lwt.return [])
  in
  let* nested =
    Lwt_list.map_s
      (fun name ->
        let path = if String.equal relative "" then name else relative ^ "/" ^ name in
        match
          String.starts_with ~prefix:"." name || List.mem name [ "_build"; "node_modules" ]
        with
        | true -> Lwt.return []
        | false -> (
            let* stats =
              Lwt.catch
                (fun () -> Lwt.map Option.some (Lwt_unix.lstat (Filename.concat root path)))
                (fun _ -> Lwt.return None)
            in
            match stats with
            | Some { st_kind = S_DIR; _ } -> walked root path
            | Some ({ st_kind = S_REG; _ } as stats) -> Lwt.return [ (path, stats) ]
            | Some { st_kind = S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK; _ } | None ->
                Lwt.return []))
      (List.sort String.compare names)
  in
  Lwt.return (List.concat nested)

let grep workspace ~pattern ~glob =
  let* candidates = walked workspace.root "" in
  Lwt.map List.concat
    (Lwt_list.map_s
       (fun (path, _) ->
         let+ text = read workspace path in
         Result.fold ~ok:(search ~pattern ~glob ~path) ~error:(fun _ -> []) text)
       candidates)

let ran_in ~cwd ?env program arguments =
  Lwt.catch
    (fun () ->
      Lwt_process.with_process_in ~cwd ?env ~stdin:`Dev_null (program, arguments)
        (fun process ->
          let* out = Lwt_io.read process#stdout in
          let+ status = process#close in
          {
            out;
            code =
              (match status with
              | WEXITED code -> code
              | WSIGNALED signal | WSTOPPED signal -> 128 + abs signal);
          }))
    (fun problem -> Lwt.return { out = Printexc.to_string problem; code = 127 })

let shell workspace command =
  ran_in ~cwd:workspace.root "/bin/sh" [| "/bin/sh"; "-c"; "exec 2>&1\n" ^ command |]

let contained workspace staged command =
  let refused out = Lwt.return ({ out; code = 126 }, []) in
  let rec removed path =
    let* stats = Lwt_unix.lstat path in
    match stats.st_kind with
    | S_DIR ->
        let* names = Lwt_stream.to_list (Lwt_unix.files_of_directory path) in
        let* () =
          Lwt_list.iter_s
            (fun name ->
              match name with
              | "." | ".." -> Lwt.return_unit
              | _ -> removed (Filename.concat path name))
            names
        in
        Lwt_unix.rmdir path
    | S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK -> Lwt_unix.unlink path
  in
  match
    List.find_opt
      (fun (program, _) -> Sys.file_exists program)
      [ ("/usr/bin/sandbox-exec", `Seatbelt); ("/usr/bin/bwrap", `Bubblewrap) ]
  with
  | None ->
      refused
        "A contained shell needs sandbox-exec (macOS) or bwrap (Linux); run with --shell open."
  | Some (program, sandbox) ->
      let base = Unix.realpath (Filename.temp_dir "teagent-shadow" "") in
      let clone = Filename.concat base "work" and scratch = Filename.concat base "tmp" in
      let shadow = at clone in
      let existing paths =
        List.filter_map
          (fun path ->
            match Unix.realpath path with
            | real -> Some (path, real)
            | exception Unix.Unix_error _ -> None)
          paths
      in
      let home names =
        List.map
          (Filename.concat (Option.value ~default:"/var/empty" (Sys.getenv_opt "HOME")))
          names
      in
      let secrets =
        existing
          (workspace.root
          :: home
               [ ".ssh"; ".aws"; ".gnupg"; ".netrc"; ".config/gh"; ".docker"; ".kube";
                 ".git-credentials"; ".npmrc"; ".pypirc"; ".teagent"; ".claude"; ".codex";
                 "Library/Keychains" ])
      in
      let readable system =
        match workspace.limits.reads with
        | Anywhere -> None
        | Within extra -> Some (existing (system @ home [ ".gitconfig"; ".config/git" ] @ extra))
      in
      let copying, arguments =
        match sandbox with
        | `Seatbelt ->
            let subpaths paths =
              String.concat " " (List.map (fun (_, real) -> Printf.sprintf "(subpath %S)" real) paths)
            in
            ( [| "cp"; "-cR"; workspace.root ^ "/."; clone |],
              [|
                "sandbox-exec";
                "-p";
                Printf.sprintf
                  "(version 1)\n(allow default)\n(deny network*)\n%s(deny file-read* %s)\n\
                   (deny file-write*)\n\
                   (allow file-write* (subpath %S) (literal \"/dev/null\") \
                   (literal \"/dev/zero\") (regex #\"^/dev/fd/\") (regex #\"^/dev/tty\"))\n"
                  (Option.fold ~none:""
                     ~some:(fun paths ->
                       Printf.sprintf
                         "(deny file-read-data)\n(allow file-read-data (literal \"/\") %s)\n"
                         (subpaths paths))
                     (readable
                        [ "/usr"; "/bin"; "/sbin"; "/System"; "/Library"; "/private/etc";
                          "/private/var/select"; "/private/var/db"; "/dev"; "/opt";
                          "/Applications"; base ]))
                  (subpaths secrets) base;
                "/bin/sh";
                "-c";
                "exec 2>&1\n" ^ command;
              |] )
        | `Bubblewrap ->
            ( [| "cp"; "-a"; "--reflink=auto"; workspace.root ^ "/."; clone |],
              Array.of_list
                ([ "bwrap" ]
                @ Option.fold ~none:[ "--ro-bind"; "/"; "/" ]
                    ~some:(List.concat_map (fun (path, real) -> [ "--ro-bind"; real; path ]))
                    (readable [ "/usr"; "/bin"; "/sbin"; "/lib"; "/lib64"; "/lib32"; "/etc"; "/opt" ])
                @ [ "--dev"; "/dev"; "--proc"; "/proc"; "--tmpfs"; "/tmp" ]
                @ List.concat_map
                    (fun (_, real) ->
                      match Sys.is_directory real with
                      | true -> [ "--tmpfs"; real ]
                      | false -> [ "--ro-bind"; "/dev/null"; real ])
                    secrets
                @ [ "--bind"; base; base; "--chdir"; clone; "--unshare-all"; "--die-with-parent";
                    "--new-session"; "/bin/sh"; "-c"; "exec 2>&1\n" ^ command ]) )
      in
      Lwt.finalize
        (fun () ->
          Lwt.catch
            (fun () ->
              let* () = Lwt_unix.mkdir clone 0o700 in
              let* () = Lwt_unix.mkdir scratch 0o700 in
              let* copied =
                ran_in ~cwd:base "/bin/cp" copying
              in
              match copied.code with
              | 0 ->
                  let rec matching directory = function
                    | [] -> Lwt.return []
                    | part :: rest ->
                        let* names =
                          Lwt.catch
                            (fun () -> Lwt_stream.to_list (Lwt_unix.files_of_directory directory))
                            (fun _ -> Lwt.return [])
                        in
                        Lwt.map List.concat
                          (Lwt_list.map_s
                             (fun name ->
                               let path = Filename.concat directory name in
                               match
                                 ( String.equal (String.lowercase_ascii name)
                                     (String.lowercase_ascii part),
                                   rest )
                               with
                               | false, _ -> Lwt.return []
                               | true, [] -> Lwt.return [ path ]
                               | true, _ :: _ -> (
                                   let* stats = Lwt_unix.lstat path in
                                   match stats.st_kind with
                                   | S_DIR -> matching path rest
                                   | S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK -> Lwt.return []))
                             names)
                  in
                  let* () =
                    Lwt_list.iter_s
                      (fun (hidden : Path.t) ->
                        let* found = matching clone (String.split_on_char '/' (hidden :> string)) in
                        Lwt_list.iter_s
                          (fun path -> Lwt.catch (fun () -> removed path) (fun _ -> Lwt.return_unit))
                          found)
                      workspace.limits.hidden
                  in
                  let* () =
                    Lwt_list.iter_s (fun change -> Lwt.map ignore (placed shadow change)) staged
                  in
                  let* untouched = walked clone "" in
                  let* done_ =
                    ran_in ~cwd:clone
                      ~env:
                        (Array.append
                           [| "TMPDIR=" ^ scratch ^ "/" |]
                           (Array.of_list
                              (List.filter
                                 (fun binding -> not (String.starts_with ~prefix:"TMPDIR=" binding))
                                 (Array.to_list (Unix.environment ())))))
                      program arguments
                  in
                  let* touched = walked clone "" in
                  let* written =
                    Lwt_list.filter_map_s
                      (fun (path, (stats : Unix.stats)) ->
                        match List.assoc_opt path untouched with
                        | Some (old : Unix.stats)
                          when old.st_size = stats.st_size && Float.equal old.st_mtime stats.st_mtime
                          ->
                            Lwt.return None
                        | Some _ | None -> (
                            let* produced = read shadow path in
                            let+ original = read workspace path in
                            let seen =
                              Option.fold
                                ~none:(Result.to_option original)
                                ~some:(fun change -> change.after)
                                (List.find_opt (fun change -> String.equal change.path path) staged)
                            in
                            match (produced, seen) with
                            | Ok text, Some seen when String.equal text seen -> None
                            | Ok text, (Some _ | None) ->
                                Some { path; before = Result.to_option original; after = Some text }
                            | Error _, _ -> None))
                      touched
                  in
                  let* deleted =
                    Lwt_list.filter_map_s
                      (fun (path, _) ->
                        match List.assoc_opt path touched with
                        | Some _ -> Lwt.return None
                        | None ->
                            let+ original = read workspace path in
                            Some { path; before = Result.to_option original; after = None })
                      untouched
                  in
                  Lwt.return (done_, written @ deleted)
              | _ -> refused ("Could not clone the workspace: " ^ copied.out))
            (fun problem -> refused ("Could not run the contained shell: " ^ Printexc.to_string problem)))
        (fun () -> Lwt.catch (fun () -> removed base) (fun _ -> Lwt.return_unit))

let commit workspace changes =
  let* checked =
    Lwt_list.filter_map_s
      (fun change ->
        let+ now =
          Result.fold
            ~ok:(fun _ -> read workspace change.path)
            ~error:(fun denied -> Lwt.return (Error denied))
            (located workspace `Writing change.path)
        in
        match (now, change.before) with
        | Ok text, _ when Option.equal String.equal (Some text) change.after -> None
        | Error (`Tools (Not_found _)), _ when Option.is_none change.after -> None
        | Ok text, Some before when String.equal text before -> None
        | Error (`Tools (Not_found _)), None -> None
        | Error (`Tools (Denied _) as denied), _ -> Some (`Denied denied)
        | Ok _, (Some _ | None) | Error _, _ -> Some (`Moved (change.path :> string)))
      changes
  in
  let moved =
    List.filter_map (function `Moved path -> Some path | `Denied _ -> None) checked
  in
  match
    (List.find_map (function `Denied denied -> Some denied | `Moved _ -> None) checked, moved)
  with
  | Some denied, _ -> Lwt.return (Error denied)
  | None, _ :: _ ->
      Lwt.return
        (Error
           (`Tools
             (Conflict ("changed on disk since staged: " ^ String.concat ", " moved))))
  | None, [] ->
      let rec applied = function
        | [] -> Lwt.return (Ok ())
        | change :: rest -> (
            let* written = placed workspace change in
            match written with
            | Ok () -> applied rest
            | Error _ as failure -> Lwt.return failure)
      in
      applied changes
