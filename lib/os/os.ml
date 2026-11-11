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
  boot : Handler.Boot.t;
}

type t = { root : string; allows : view; skills : Lang.Skill.t list }

let granted root ~net =
  {
    root;
    allows =
      { offers = List.map snd calls; mounts = []; reads = Anywhere; net; boot = Handler.Boot.standard };
    skills = [];
  }

let taught skills os = { os with skills = os.skills @ skills }

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
            not (List.mem key [ "tools"; "mounts"; "hidden"; "readonly"; "reads"; "net"; "boot" ]))
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
                      Result.bind
                        (match List.assoc_opt "boot" fields with
                        | None -> Ok None
                        | Some (`List layers) ->
                            Result.bind
                              (List.fold_right
                                 (fun layer collected ->
                                   Result.bind collected (fun rest ->
                                       match layer with
                                       | `String "journal" -> Ok (Handler.Boot.Journal :: rest)
                                       | `String "policy" -> Ok (Handler.Boot.Policy :: rest)
                                       | `Assoc [ ("budget", `Int calls) ] -> Ok (Handler.Boot.Budget calls :: rest)
                                       | other ->
                                           Error
                                             ("boot: " ^ Yojson.Safe.to_string other
                                            ^ " is not \"journal\", \"policy\" or {\"budget\": calls}")))
                                 layers (Ok []))
                              (fun layers ->
                                Result.map Option.some
                                  (Result.map_error (fun reason -> "boot: " ^ reason)
                                     (Handler.Boot.of_layers layers)))
                        | Some _ -> Error "boot is not a list of layers")
                        (fun boot ->
                          Result.map
                            (fun net ->
                              let booting later os =
                                narrowing
                                  (fun allows -> { allows with boot = Handler.Boot.narrowed allows.boot later })
                                  os
                              in
                              os |> applied only tools
                              |> mounting
                                   (List.map (fun path -> (path, Tools.Hidden)) (Option.value ~default:[] hidden)
                                   @ List.map (fun path -> (path, Tools.Readonly)) (Option.value ~default:[] readonly)
                                   @ mounts)
                              |> applied reading reads
                              |> applied reaching net
                              |> applied booting boot)
                            (listed "net" fields
                               ~expected:"a host such as registry.npmjs.org or *.crates.io" host))))))))
  | _ -> Error "it is not a JSON object"

let view os = os.allows
let device = function Fetch -> Some Device.Fetch | Bash | Read | Write | Edit | Grep | Run -> None

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
  |> Lang.Calls.unplugged (List.filter_map device missing)
  |> Lang.Calls.taught os.skills

let class_of os (tool : Value.tool) =
  match (tool, os.allows.net) with
  | Shell _, _ :: _ ->
      Value.Egress
        {
          declined =
            Ok
              (V_record
              [
                ("code", V_number 126.);
                ( "out",
                  V_string
                    "the person did not let this command run: it carries content of the project \
                     and can reach the network" );
               ]);
        }
  | _, _ -> Handler.class_of tool

type exposure = { reads : string list; inward : string list; outward : string list }

let exposure os calls =
  let networked = match os.allows.net with [] -> `Offline | _ :: _ -> `Networked in
  let legs (call : Lang.call) =
    match (call, networked) with
    | Kernel Agent_read, _ -> Some ("read", [ `Reads ])
    | Kernel Agent_grep, _ -> Some ("grep", [ `Reads ])
    | Kernel Agent_shell, `Offline -> Some ("shell", [ `Reads ])
    | Kernel Agent_shell, `Networked -> Some ("shell with --net", [ `Reads; `Inward; `Outward ])
    | Kernel Agent_hole, _ -> Some ("hole", [ `Inward ])
    | Driver name, _ -> Some (name, [ `Inward ])
    | Computed, _ -> Some ("a driver call", [ `Inward; `Outward ])
    | ( Kernel
          ( Agent_write | Agent_edit | Agent_enter | Agent_leave | Agent_merge | Agent_call
          | Task_succeed | Task_fail | Task_and_then | Task_map | Task_map_err | Task_on_error
          | Task_batch ),
        _ ) ->
        None
  in
  let giving leg =
    List.filter_map
      (fun call ->
        Option.bind (legs call) (fun (name, given) ->
            Option.map (fun _ -> name) (List.find_opt (( = ) leg) given)))
      calls
  in
  match (giving `Reads, giving `Inward, giving `Outward) with
  | (_ :: _ as reads), (_ :: _ as inward), (_ :: _ as outward) -> Some { reads; inward; outward }
  | _ -> None

let abi = 2

let image os =
  let texts strings = `List (List.map (fun text -> `String text) strings) in
  Digest.BLAKE256.to_hex
    (Digest.BLAKE256.string
       (Yojson.Safe.to_string
          (`Assoc
             [
               ("abi", `Int abi);
               ( "offers",
                 texts
                   (List.filter_map
                      (fun (name, call) ->
                        Option.map (fun _ -> name) (List.find_opt (( = ) call) os.allows.offers))
                      calls) );
               ( "mounts",
                 `List
                   (List.map
                      (fun ((path : Tools.Path.t), (mount : Tools.mount)) ->
                        texts
                          [
                            (path :> string);
                            (match mount with
                            | Hidden -> "hidden"
                            | Readonly -> "readonly"
                            | Scratch -> "scratch");
                          ])
                      (List.sort compare os.allows.mounts)) );
               ( "reads",
                 match os.allows.reads with
                 | Anywhere -> `String "anywhere"
                 | Within paths -> texts (List.sort String.compare paths) );
               ("net", texts (List.sort String.compare os.allows.net));
               ( "boot",
                 `List
                   (List.map
                      (function
                        | Handler.Boot.Budget calls -> `Assoc [ ("budget", `Int calls) ]
                        | Policy -> `String "policy"
                        | Journal -> `String "journal")
                      (os.allows.boot :> Handler.Boot.layer list)) );
               ("drivers", texts (List.map Device.source (List.filter_map device os.allows.offers)));
               ("skills", texts (List.sort String.compare (List.map Lang.Skill.source os.skills)));
             ])))
