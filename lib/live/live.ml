type t = {
  program : Interp.t;
  model : Value.t;
  update : Value.closure;
  view : Value.closure;
  subscriptions : Value.closure;
}

type listening = { source : string; task : Value.task }
type power = Reads | Sends | Changes | Asks
type error = [ `Interp of Interp.error | `Undeclared of Value.global | `Live of string ]

let rec plain (value : Value.t) = match value with V_labelled { value; _ } -> plain value | _ -> value

let function_of what (value : Value.t) =
  match plain value with
  | V_closure closure -> Ok closure
  | other -> Error (`Live (what ^ " is not a function: " ^ Value.to_elm other))

let applied program (callee : Value.t) arguments =
  List.fold_left
    (fun result argument ->
      Result.bind result (fun callee ->
          Result.bind (function_of "a call" callee) (fun closure -> Interp.apply program closure argument)))
    (Ok callee) arguments

let task_of program what (held : Value.t) =
  let identity : Value.closure =
    {
      home = "Basics";
      parameters = [ "value" ];
      scope = Value.Scope.empty;
      body = Ir.Ast.T_return (A_var "value");
      recursion = Anonymous;
    }
  in
  Result.bind
    (match plain held with
    | V_task _ as task -> Ok task
    | V_closure closure -> Interp.apply program closure (V_closure identity)
    | other -> Ok other)
    (fun built ->
      match plain built with
      | V_task task -> Ok task
      | other -> Error (`Live (what ^ " does not hold a task: " ^ Value.to_elm other)))

let moved program (pair : Value.t) =
  let rec commands (command : Value.t) =
    match plain command with
    | V_constr { constructor = { module_name = "Platform.Cmd"; name = "None" }; arguments = [] } -> Ok []
    | V_constr { constructor = { module_name = "Platform.Cmd"; name = "Batch" }; arguments = [ batch ] } -> (
        match plain batch with
        | V_list commands_in ->
            List.fold_left
              (fun found command ->
                Result.bind found (fun found ->
                    Result.map (fun more -> found @ more) (commands command)))
              (Ok []) commands_in
        | other -> Error (`Live ("a Cmd.batch of " ^ Value.to_elm other)))
    | V_constr { constructor = { module_name = "Platform.Cmd"; name = "Perform" }; arguments = [ held ] } ->
        Result.map (fun task -> [ task ]) (task_of program "a command" held)
    | other -> Error (`Live ("not a Cmd: " ^ Value.to_elm other))
  in
  match plain pair with
  | V_tuple [ model; command ] -> Result.map (fun tasks -> (model, tasks)) (commands command)
  | other -> Error (`Live ("not a ( model, Cmd msg ) pair: " ^ Value.to_elm other))

let traced name program run =
  Trace_core.with_span ~__FILE__ ~__LINE__ name (fun span ->
      let before = Interp.used program in
      let outcome = run () in
      if Trace_core.enabled () then
        Trace_core.add_data_to_span span [ ("steps", `Int (Interp.used program - before)) ];
      outcome)

let started program main =
  traced "live.init" program @@ fun () ->
  Result.bind (Interp.lookup program main) (fun value ->
      match plain value with
      | V_constr { constructor = { module_name = "Live"; name = "Program" }; arguments = [ fields ] } -> (
          match plain fields with
          | V_record [ ("init", init); ("subscriptions", subscriptions); ("update", update); ("view", view) ]
            ->
              Result.bind (function_of "update" update) (fun update ->
                  Result.bind (function_of "view" view) (fun view ->
                      Result.bind (function_of "subscriptions" subscriptions) (fun subscriptions ->
                          Result.map
                            (fun (model, tasks) -> ({ program; model; update; view; subscriptions }, tasks))
                            (moved program init))))
          | other -> Error (`Live ("not the fields of a Live.program: " ^ Value.to_elm other)))
      | other ->
          Error
            (`Live
               (main.module_name ^ "." ^ main.name ^ " is not a Live.program: " ^ Value.to_elm other)))

let drawn live = traced "live.view" live.program (fun () -> Interp.apply live.program live.view live.model)

let updated live message =
  traced "live.update" live.program @@ fun () ->
  Result.bind (applied live.program (V_closure live.update) [ message; live.model ]) (fun pair ->
      Result.map (fun (model, tasks) -> ({ live with model }, tasks)) (moved live.program pair))

let listening live =
  let rec found (subscription : Value.t) =
    match plain subscription with
    | V_constr { constructor = { module_name = "Platform.Sub"; name = "None" }; arguments = [] } -> Ok []
    | V_constr { constructor = { module_name = "Platform.Sub"; name = "Batch" }; arguments = [ batch ] }
      -> (
        match plain batch with
        | V_list subscriptions ->
            List.fold_left
              (fun listened subscription ->
                Result.bind listened (fun listened ->
                    Result.map (fun more -> listened @ more) (found subscription)))
              (Ok []) subscriptions
        | other -> Error (`Live ("a Sub.batch of " ^ Value.to_elm other)))
    | V_constr { constructor = { module_name = "Platform.Sub"; name = "Listen" }; arguments = [ key; watch ] }
      -> (
        match plain key with
        | V_string source ->
            Result.map (fun task -> [ { source; task } ]) (task_of live.program "a subscription" watch)
        | other -> Error (`Live ("a subscription keyed by " ^ Value.to_elm other)))
    | other -> Error (`Live ("not a Sub: " ^ Value.to_elm other))
  in
  traced "live.listen" live.program (fun () ->
      Result.bind (Interp.apply live.program live.subscriptions live.model) found)

let message live ~view path arguments =
  Option.fold
    ~none:(Error (`Live "the view holds nothing at this path"))
    ~some:(fun held ->
      match (plain held, arguments) with
      | V_closure _, _ :: _ -> applied live.program held arguments
      | V_closure _, [] -> Error (`Live "the view holds a function here, and the event carries nothing")
      | _, [] -> Ok held
      | _, _ :: _ -> Error (`Live "the view holds a message here, not a function of the event"))
    (Wire.at view path)

let powers ~devices modules =
  List.map
    (fun (call : Lang.call) ->
      ( call,
        match call with
        | Kernel (Agent_read | Agent_grep) -> Reads
        | Kernel
            ( Agent_write | Agent_edit | Agent_shell | Agent_hole | Agent_enter | Agent_leave | Agent_merge
            | Agent_call | Task_succeed | Task_fail | Task_and_then | Task_map | Task_map_err
            | Task_on_error | Task_batch ) ->
            Changes
        | Driver ("fetch.get" | "model.judge") -> Sends
        | Driver "catalog.search" -> Reads
        | Driver "person.ask" -> Asks
        | Driver name -> (
            match
(Device.declared devices name, String.split_on_char '.' name)
            with
            | Some Pure, _ -> Reads
            | Some (Egress _), _ -> Sends
            | Some (Staged | Contained | Irreversible _), _ -> Changes
            | None, [ "api"; module_name; key ] ->
                Option.fold ~none:Changes
                  ~some:(fun (operation : Api.operation) ->
                    match operation.meth with Get | Head -> Sends | Post | Put | Patch | Delete -> Changes)
                  (Option.bind
                     (List.find_map
                        (function
                          | Device.Api api when String.equal (Api.name api) module_name -> Some api
                          | _ -> None)
                        devices)
                     (fun api -> Api.operation api key))
            | None, _ -> Changes)
        | Computed -> Changes ))
    (Lang.calls modules)
