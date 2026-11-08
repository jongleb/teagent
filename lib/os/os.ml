type call = Bash | Read | Write | Edit | Grep | Run | Fetch

let calls =
  [
    ("bash", Bash);
    ("read", Read);
    ("write", Write);
    ("edit", Edit);
    ("grep", Grep);
    ("run", Run);
    ("fetch", Fetch);
  ]

type view = {
  offers : call list;
  mounts : (Tools.Path.t * Tools.mount) list;
  reads : Tools.reads;
  net : string list;
}

type t = { root : string; allows : view }

let granted root ~net =
  {
    root;
    allows = { offers = List.map snd calls; mounts = []; reads = Anywhere; net };
  }

let narrowing change os = { os with allows = change os.allows }

let only kept os =
  narrowing (fun allows ->
      { allows with offers = List.filter (fun call -> List.mem call kept) allows.offers })
    os

let mounting mounts os = narrowing (fun allows -> { allows with mounts = allows.mounts @ mounts }) os

let reading paths os =
  narrowing (fun allows ->
      {
        allows with
        reads =
          (match allows.reads with
          | Anywhere -> Within paths
          | Within allowed ->
              Within
                (List.filter
                   (fun path ->
                     List.exists
                       (fun parent ->
                         String.equal parent path || String.starts_with ~prefix:(parent ^ "/") path)
                       allowed)
                   paths));
      })
    os

let reaching hosts os =
  narrowing (fun allows ->
      {
        allows with
        net =
          List.filter
            (fun host ->
              List.exists
                (fun allowed ->
                  String.equal allowed host
                  || String.starts_with ~prefix:"*." allowed
                     && String.ends_with
                          ~suffix:(String.sub allowed 1 (String.length allowed - 1))
                          host)
                allows.net)
            hosts;
      })
    os

let narrowed json os =
  let listed key fields ~expected parse =
    match List.assoc_opt key fields with
    | None -> Ok None
    | Some (`List items) ->
        Result.map Option.some
          (List.fold_right
             (fun item collected ->
               Result.bind collected (fun rest ->
                   match item with
                   | `String text ->
                       Result.map
                         (fun parsed -> parsed :: rest)
                         (Option.to_result ~none:(key ^ ": " ^ text ^ " is not " ^ expected)
                            (parse text))
                   | _ -> Error (key ^ " holds something that is not text")))
             items (Ok []))
    | Some _ -> Error (key ^ " is not a list")
  in
  let home = Option.value ~default:"/var/empty" (Sys.getenv_opt "HOME") in
  let absolute text =
    match String.split_on_char '/' text with
    | "~" :: rest -> Some (String.concat "/" (home :: rest))
    | "" :: _ -> Some text
    | _ -> None
  in
  let host text =
    let name = String.lowercase_ascii text in
    let labels = match String.split_on_char '.' name with "*" :: rest -> rest | labels -> labels in
    match
      ( List.for_all
          (fun label ->
            String.length label > 0
            && String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) label)
          labels,
        labels )
    with
    | true, _ :: _ -> Some name
    | _, _ -> None
  in
  let applied narrow = Option.fold ~none:Fun.id ~some:narrow in
  match json with
  | `Assoc fields -> (
      match
        List.find_opt
          (fun (key, _) ->
            not (List.mem key [ "tools"; "mounts"; "hidden"; "readonly"; "reads"; "net" ]))
          fields
      with
      | Some (key, _) -> Error ("there is no setting called " ^ key)
      | None ->
          let inside text = Result.to_option (Tools.Path.of_string text) in
          Result.bind
            (listed "tools" fields ~expected:"bash, read, write, edit, grep, run or fetch" (fun name ->
                 List.assoc_opt name calls))
            (fun tools ->
              Result.bind (listed "hidden" fields ~expected:"a path in the project" inside)
                (fun hidden ->
                  Result.bind (listed "readonly" fields ~expected:"a path in the project" inside)
                    (fun readonly ->
                      Result.bind
                        (match List.assoc_opt "mounts" fields with
                        | None -> Ok []
                        | Some (`Assoc entries) ->
                            List.fold_right
                              (fun (path, kind) collected ->
                                Result.bind collected (fun rest ->
                                    match
                                      ( inside path,
                                        match kind with
                                        | `String "hidden" -> Some Tools.Hidden
                                        | `String "readonly" -> Some Tools.Readonly
                                        | `String "scratch" -> Some Tools.Scratch
                                        | _ -> None )
                                    with
                                    | Some path, Some mount -> Ok ((path, mount) :: rest)
                                    | None, _ -> Error ("mounts: " ^ path ^ " is not a path in the project")
                                    | Some _, None ->
                                        Error ("mounts: " ^ path ^ " is not hidden, readonly or scratch")))
                              entries (Ok [])
                        | Some _ -> Error "mounts is not an object of paths")
                        (fun mounts ->
                      Result.bind
                        (listed "reads" fields ~expected:"an absolute path or one under ~/"
                           absolute) (fun reads ->
                          Result.map
                            (fun net ->
                              os |> applied only tools
                              |> mounting
                                   (List.map (fun path -> (path, Tools.Hidden)) (Option.value ~default:[] hidden)
                                   @ List.map (fun path -> (path, Tools.Readonly)) (Option.value ~default:[] readonly)
                                   @ mounts)
                              |> applied reading reads
                              |> applied reaching net)
                            (listed "net" fields
                               ~expected:"a host such as registry.npmjs.org or *.crates.io" host)))))))
  | _ -> Error "it is not a JSON object"

let view os = os.allows

let workspace os =
  Tools.limited
    {
      mounts = os.allows.mounts;
      reads = os.allows.reads;
      net = os.allows.net;
    }
    (Tools.at os.root)

let table os =
  let missing =
    List.filter (fun (_, call) -> not (List.mem call os.allows.offers)) calls |> List.map snd
  in
  Lang.Calls.all
  |> Lang.Calls.without
       (List.filter_map
          (function
            | Bash -> Some Data.Kernel.Agent_shell
            | Read -> Some Data.Kernel.Agent_read
            | Write -> Some Data.Kernel.Agent_write
            | Edit -> Some Data.Kernel.Agent_edit
            | Grep -> Some Data.Kernel.Agent_grep
            | Run | Fetch -> None)
          missing)
  |> Lang.Calls.unplugged
       (List.filter_map
          (function Fetch -> Some Device.Fetch | Bash | Read | Write | Edit | Grep | Run -> None)
          missing)
