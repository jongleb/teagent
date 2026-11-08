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
type mount = Hidden | Readonly | Scratch
type limits = { mounts : (Path.t * mount) list; reads : reads; net : string list }
type t = { root : string; limits : limits }

let at root = { root; limits = { mounts = []; reads = Anywhere; net = [] } }

let mounted workspace (inside : Path.t) =
  List.fold_left
    (fun strictest ((entry : Path.t), mount) ->
      let entry = String.lowercase_ascii (entry :> string)
      and path = String.lowercase_ascii (inside :> string) in
      match (String.equal path entry || String.starts_with ~prefix:(entry ^ "/") path, strictest, mount) with
      | false, _, _ -> strictest
      | true, (Some Hidden as kept), _ | true, (Some Readonly as kept), (Readonly | Scratch) -> kept
      | true, (None | Some Scratch), _ | true, Some Readonly, Hidden -> Some mount)
    None workspace.limits.mounts

let granted workspace host =
  List.find_opt
    (fun entry ->
      String.equal entry host
      || String.starts_with ~prefix:"*." entry
         && String.ends_with ~suffix:(String.sub entry 1 (String.length entry - 1)) host)
    workspace.limits.net
let limited limits workspace = { workspace with limits }

let mounting mounts workspace =
  { workspace with limits = { workspace.limits with mounts = workspace.limits.mounts @ mounts } }

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
                  match (access, mounted workspace inside) with
                  | _, Some Hidden | `Writing, Some (Readonly | Scratch) -> denied
                  | `Reading, (None | Some (Readonly | Scratch)) | `Writing, None ->
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

let bridged = 3128

let joined (client_in, client_out) (server_in, server_out) =
  let rec copied input output =
    let* chunk = Lwt_io.read ~count:65536 input in
    match chunk with
    | "" -> Lwt.return_unit
    | _ ->
        let* () = Lwt_io.write output chunk in
        let* () = Lwt_io.flush output in
        copied input output
  in
  Lwt.finalize
    (fun () ->
      Lwt.catch
        (fun () -> Lwt.pick [ copied client_in server_out; copied server_in client_out ])
        (fun _ -> Lwt.return_unit))
    (fun () ->
      Lwt_list.iter_p
        (fun close -> Lwt.catch close (fun _ -> Lwt.return_unit))
        [
          (fun () -> Lwt_io.close client_in);
          (fun () -> Lwt_io.close client_out);
          (fun () -> Lwt_io.close server_in);
          (fun () -> Lwt_io.close server_out);
        ])

let () =
  match Array.to_list Sys.argv with
  | _ :: "--teagent-bridge" :: socket :: program :: arguments ->
      exit
        (Lwt_main.run
           (let listening = Lwt_unix.socket PF_INET SOCK_STREAM 0 in
            Lwt_unix.setsockopt listening SO_REUSEADDR true;
            let* () = Lwt_unix.bind listening (ADDR_INET (Unix.inet_addr_loopback, bridged)) in
            Lwt_unix.listen listening 64;
            let rec accepted () =
              let* client, _ = Lwt_unix.accept listening in
              Lwt.async (fun () ->
                  Lwt.catch
                    (fun () ->
                      let* upstream = Lwt_io.open_connection (ADDR_UNIX socket) in
                      joined
                        (Lwt_io.of_fd ~mode:Lwt_io.Input client, Lwt_io.of_fd ~mode:Lwt_io.Output client)
                        upstream)
                    (fun _ -> Lwt.return_unit));
              accepted ()
            in
            Lwt.async (fun () -> Lwt.catch accepted (fun _ -> Lwt.return_unit));
            let+ status = Lwt_process.exec (program, Array.of_list (program :: arguments)) in
            match status with
            | WEXITED code -> code
            | WSIGNALED signal | WSTOPPED signal -> 128 + abs signal))
  | _ -> ()

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
      let socket = Filename.concat base "proxy.sock" in
      let proxy =
        match (workspace.limits.net, sandbox) with
        | [], _ -> None
        | _ :: _, `Seatbelt ->
            let listening = Unix.socket PF_INET SOCK_STREAM 0 in
            Unix.bind listening (ADDR_INET (Unix.inet_addr_loopback, 0));
            Unix.listen listening 64;
            Some
              ( listening,
                match Unix.getsockname listening with
                | ADDR_INET (_, port) -> port
                | ADDR_UNIX _ -> bridged )
        | _ :: _, `Bubblewrap ->
            let listening = Unix.socket PF_UNIX SOCK_STREAM 0 in
            Unix.bind listening (ADDR_UNIX socket);
            Unix.listen listening 64;
            Some (listening, bridged)
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
                  "(version 1)\n(allow default)\n(deny network*)\n%s%s(deny file-read* %s)\n\
                   (deny file-write*)\n\
                   (allow file-write* (subpath %S) (literal \"/dev/null\") \
                   (literal \"/dev/zero\") (regex #\"^/dev/fd/\") (regex #\"^/dev/tty\"))\n"
                  (Option.fold ~none:""
                     ~some:(fun (_, port) ->
                       Printf.sprintf "(allow network-outbound (remote tcp \"localhost:%d\"))\n" port)
                     proxy)
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
                @ Option.fold ~none:[]
                    ~some:(fun _ -> [ "--ro-bind"; Sys.executable_name; Sys.executable_name ])
                    proxy
                @ [ "--bind"; base; base; "--chdir"; clone; "--unshare-all"; "--die-with-parent";
                    "--new-session" ]
                @ Option.fold ~none:[]
                    ~some:(fun _ -> [ Sys.executable_name; "--teagent-bridge"; socket ])
                    proxy
                @ [ "/bin/sh"; "-c"; "exec 2>&1\n" ^ command ]) )
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
                      (fun ((hidden : Path.t), _) ->
                        let* found = matching clone (String.split_on_char '/' (hidden :> string)) in
                        Lwt_list.iter_s
                          (fun path -> Lwt.catch (fun () -> removed path) (fun _ -> Lwt.return_unit))
                          found)
                      (List.filter
                         (function _, Hidden -> true | _, (Readonly | Scratch) -> false)
                         workspace.limits.mounts)
                  in
                  let* () =
                    Lwt_list.iter_s (fun change -> Lwt.map ignore (placed shadow change)) staged
                  in
                  let* untouched = walked clone "" in
                  let connections = ref [] in
                  let served listening =
                    let listening = Lwt_unix.of_unix_file_descr listening in
                    let rec accepted () =
                      let* client, _ = Lwt_unix.accept listening in
                      Lwt.async (fun () ->
                          let input = Lwt_io.of_fd ~mode:Lwt_io.Input client
                          and output = Lwt_io.of_fd ~mode:Lwt_io.Output client in
                          let answered status =
                            Lwt.catch
                              (fun () ->
                                let* () =
                                  Lwt_io.write output
                                    ("HTTP/1.1 " ^ status
                                   ^ "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                                in
                                Lwt_io.close output)
                              (fun _ -> Lwt.return_unit)
                          in
                          Lwt.catch
                            (fun () ->
                              let* request = Lwt_io.read_line input in
                              let rec headers found =
                                let* line = Lwt_io.read_line input in
                                match String.trim line with
                                | "" -> Lwt.return (List.rev found)
                                | _ -> headers (line :: found)
                              in
                              let* fields = headers [] in
                              let authority text default =
                                match String.rindex_opt text ':' with
                                | Some at ->
                                    Option.map
                                      (fun port -> (String.lowercase_ascii (String.sub text 0 at), port))
                                      (int_of_string_opt
                                         (String.sub text (at + 1) (String.length text - at - 1)))
                                | None -> Some (String.lowercase_ascii text, default)
                              in
                              let destination =
                                match String.split_on_char ' ' (String.trim request) with
                                | [ "CONNECT"; target; _ ] ->
                                    Option.map
                                      (fun (host, port) -> (host, port, `Tunnel))
                                      (authority target 443)
                                | [ verb; target; version ]
                                  when String.starts_with ~prefix:"http://"
                                         (String.lowercase_ascii target) ->
                                    let rest = String.sub target 7 (String.length target - 7) in
                                    let slash =
                                      Option.value ~default:(String.length rest)
                                        (String.index_opt rest '/')
                                    in
                                    Option.map
                                      (fun (host, port) ->
                                        ( host,
                                          port,
                                          `Forward
                                            (String.concat " "
                                               [
                                                 verb;
                                                 (match
                                                    String.sub rest slash (String.length rest - slash)
                                                  with
                                                 | "" -> "/"
                                                 | path -> path);
                                                 version;
                                               ]) ))
                                      (authority (String.sub rest 0 slash) 80)
                                | _ -> None
                              in
                              match destination with
                              | None -> answered "400 Bad Request"
                              | Some (host, port, way) -> (
                                  match granted workspace host with
                                  | None ->
                                      connections := (host, port, `Blocked) :: !connections;
                                      answered "403 Forbidden"
                                  | Some _ -> (
                                      connections := (host, port, `Allowed) :: !connections;
                                      let* addresses =
                                        Lwt_unix.getaddrinfo host (string_of_int port)
                                          [ AI_SOCKTYPE SOCK_STREAM ]
                                      in
                                      match addresses with
                                      | [] -> answered "502 Bad Gateway"
                                      | address :: _ ->
                                          let* server_in, server_out =
                                            Lwt_io.open_connection address.ai_addr
                                          in
                                          let* () =
                                            match way with
                                            | `Tunnel ->
                                                Lwt_io.write output
                                                  "HTTP/1.1 200 Connection established\r\n\r\n"
                                            | `Forward line ->
                                                Lwt_io.write server_out
                                                  (String.concat "\r\n"
                                                     ((line
                                                      :: List.filter
                                                           (fun field ->
                                                             match
                                                               Option.map
                                                                 (fun at ->
                                                                   String.lowercase_ascii
                                                                     (String.trim (String.sub field 0 at)))
                                                                 (String.index_opt field ':')
                                                             with
                                                             | Some
                                                                 ( "connection" | "proxy-connection"
                                                                 | "keep-alive" | "proxy-authorization" )
                                                               ->
                                                                 false
                                                             | Some _ | None -> true)
                                                           fields)
                                                     @ [ "Connection: close"; ""; "" ]))
                                          in
                                          let* () = Lwt_io.flush output in
                                          let* () = Lwt_io.flush server_out in
                                          joined (input, output) (server_in, server_out))))
                            (fun _ -> answered "502 Bad Gateway"));
                      accepted ()
                    in
                    Lwt.catch accepted (fun _ -> Lwt.return_unit)
                  in
                  Option.iter (fun (listening, _) -> Lwt.async (fun () -> served listening)) proxy;
                  let* done_ =
                    ran_in ~cwd:clone
                      ~env:
                        (Array.append
                           (Array.of_list
                              (List.map
                                 (fun (name, folder) -> name ^ "=" ^ Filename.concat scratch folder)
                                 [ ("TMPDIR", ""); ("XDG_CACHE_HOME", "cache");
                                   ("npm_config_cache", "npm"); ("PIP_CACHE_DIR", "pip") ]
                              @ Option.fold ~none:[]
                                   ~some:(fun (_, port) ->
                                     List.map
                                       (fun name -> Printf.sprintf "%s=http://127.0.0.1:%d" name port)
                                       [ "HTTP_PROXY"; "HTTPS_PROXY"; "ALL_PROXY"; "http_proxy";
                                         "https_proxy"; "all_proxy" ])
                                   proxy))
                           (Array.of_list
                              (List.filter
                                 (fun binding ->
                                   match
                                     String.lowercase_ascii
                                       (Option.fold ~none:binding
                                          ~some:(fun at -> String.sub binding 0 at)
                                          (String.index_opt binding '='))
                                   with
                                   | "tmpdir" | "xdg_cache_home" | "npm_config_cache"
                                   | "pip_cache_dir" | "http_proxy" | "https_proxy" | "all_proxy"
                                   | "no_proxy" ->
                                       false
                                   | _ -> true)
                                 (Array.to_list (Unix.environment ())))))
                      program arguments
                  in
                  let done_ =
                    match
                      List.sort_uniq String.compare
                        (List.filter_map
                           (function
                             | host, port, `Blocked -> Some (Printf.sprintf "%s:%d" host port)
                             | _, _, `Allowed -> None)
                           !connections)
                    with
                    | [] -> done_
                    | blocked ->
                        {
                          done_ with
                          out =
                            done_.out ^ "\nteagent: blocked connections to "
                            ^ String.concat ", " blocked ^ ", which the profile's net does not list\n";
                        }
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
        (fun () ->
          Option.iter
            (fun (listening, _) -> try Unix.close listening with Unix.Unix_error _ -> ())
            proxy;
          Lwt.catch (fun () -> removed base) (fun _ -> Lwt.return_unit))

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

type fetched = { status : int; body : string }
type request = Get | Post of string

let fetch workspace request url =
  let authority =
    List.find_map
      (fun scheme ->
        Option.map
          (fun rest ->
            List.fold_left
              (fun authority stop ->
                Option.fold ~none:authority
                  ~some:(fun at -> String.sub authority 0 at)
                  (String.index_opt authority stop))
              rest [ '/'; '?'; '#' ])
          (match String.starts_with ~prefix:scheme (String.lowercase_ascii url) with
          | true -> Some (String.sub url (String.length scheme) (String.length url - String.length scheme))
          | false -> None))
      [ "http://"; "https://" ]
  in
  match authority with
  | None -> Lwt.return (Error (`Unreachable ("not an http or https URL: " ^ url)))
  | Some authority when String.contains authority '@' ->
      Lwt.return (Error (`Unreachable ("a URL with a user in it: " ^ url)))
  | Some authority -> (
      let host =
        String.lowercase_ascii
          (Option.fold ~none:authority
             ~some:(fun at -> String.sub authority 0 at)
             (String.index_opt authority ':'))
      in
      match granted workspace host with
      | None -> Lwt.return (Error (`Not_granted host))
      | Some _ ->
          Lwt_preemptive.detach
            (fun () ->
              let handle = Curl.init () in
              let received = Buffer.create 4096 and limit = 10_000_000 in
              Fun.protect
                ~finally:(fun () -> Curl.cleanup handle)
                (fun () ->
                  match
                    Curl.set_url handle url;
                    (match request with
                    | Get -> ()
                    | Post body ->
                        Curl.set_post handle true;
                        Curl.set_postfields handle body;
                        Curl.set_postfieldsize handle (String.length body));
                    Curl.set_proxy handle "";
                    Curl.set_followlocation handle false;
                    Curl.set_protocols handle [ Curl.CURLPROTO_HTTP; Curl.CURLPROTO_HTTPS ];
                    Curl.set_connecttimeout handle 30;
                    Curl.set_timeout handle 120;
                    Curl.set_writefunction handle (fun chunk ->
                        match Buffer.length received + String.length chunk > limit with
                        | true -> 0
                        | false ->
                            Buffer.add_string received chunk;
                            String.length chunk);
                    Curl.perform handle
                  with
                  | () -> Ok { status = Curl.get_responsecode handle; body = Buffer.contents received }
                  | exception Curl.CurlException (_, _, reason) -> Error (`Unreachable reason)))
            ())
