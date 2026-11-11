type error =
  | Budget_exhausted
  | Crashed of string
  | Stuck of string

exception Stopped of error

(** A join point: [definition] runs with [parameters] bound in its own scope. *)
type join = {
  parameters : string list;
  definition : Ir.Ast.term;
  scope : Value.t Value.Scope.t;
  joins : join Value.Scope.t;
}

type t = {
  declarations : (Value.global, Ir.Ast.declaration) Hashtbl.t;
  constructors : (Value.global, int) Hashtbl.t;
  cached : (Value.global, Value.t) Hashtbl.t;
  mutable steps : int;
}

let stuck reason = raise (Stopped (Stuck reason))
let crashed reason = raise (Stopped (Crashed reason))

let global ~home (name : Data.Name.t) : Value.global =
  match name with
  | Data.Name.Local name -> { module_name = home; name }
  | Data.Name.Global { module_name; exported_name } ->
      { module_name; name = exported_name }

let load ~budget (modules : Lang.t list) =
  let program =
    {
      declarations = Hashtbl.create 64;
      constructors = Hashtbl.create 64;
      cached = Hashtbl.create 64;
      steps = budget;
    }
  in
  List.iter
    (fun (compiled : Lang.t) ->
      List.iter
        (fun (declaration : Ir.Ast.declaration) ->
          Hashtbl.replace program.declarations
            { Value.module_name = compiled.module_name; name = declaration.name }
            declaration)
        compiled.declarations;
      List.iter
        (fun (name, arity) ->
          Hashtbl.replace program.constructors
            (global ~home:compiled.module_name name)
            arity)
        compiled.constructors)
    modules;
  program

let constant ~home name : Value.t =
  match
    (Primitives.bool_of_constructor name, Primitives.is_unit_constructor name)
  with
  | Some truth, _ -> V_bool truth
  | None, true -> V_unit
  | None, false -> V_constr { constructor = global ~home name; arguments = [] }

let peeled (value : Value.t) =
  match value with
  | V_labelled { sources; value } -> (sources, value)
  | V_number _ | V_string _ | V_char _ | V_bool _ | V_unit | V_list _ | V_tuple _ | V_record _
  | V_constr _ | V_closure _ | V_task _ ->
      ([], value)

let rec equal (left : Value.t) (right : Value.t) =
  match (left, right) with
  | V_labelled { value; _ }, other | other, V_labelled { value; _ } -> equal value other
  | (V_closure _ | V_task _), _ | _, (V_closure _ | V_task _) ->
      crashed "functions cannot be compared"
  | V_number left, V_number right -> Float.equal left right && not (Float.is_nan left)
  | V_string left, V_string right | V_char left, V_char right ->
      String.equal left right
  | V_bool left, V_bool right -> Bool.equal left right
  | V_unit, V_unit -> true
  | V_list left, V_list right | V_tuple left, V_tuple right ->
      List.equal equal left right
  | V_record left, V_record right ->
      List.equal
        (fun (one, left) (other, right) -> String.equal one other && equal left right)
        left right
  | V_constr left, V_constr right ->
      left.constructor = right.constructor
      && List.equal equal left.arguments right.arguments
  | ( ( V_number _ | V_string _ | V_char _ | V_bool _ | V_unit | V_list _
      | V_tuple _ | V_record _ | V_constr _ ),
      _ ) ->
      stuck "an equality of values of different types"

let rec compared (left : Value.t) (right : Value.t) =
  let rec lexicographic left right =
    match (left, right) with
    | [], [] -> 0
    | [], _ :: _ -> -1
    | _ :: _, [] -> 1
    | one :: left, other :: right -> (
        match compared one other with 0 -> lexicographic left right | order -> order)
  in
  match (left, right) with
  | V_labelled { value; _ }, other -> compared value other
  | other, V_labelled { value; _ } -> compared other value
  | V_number left, V_number right -> Float.compare left right
  | V_string left, V_string right | V_char left, V_char right ->
      Int.compare (String.compare left right) 0
  | V_list left, V_list right | V_tuple left, V_tuple right ->
      lexicographic left right
  | _, _ -> stuck "a comparison of values that are not comparable"

let uint32 number =
  match Float.is_finite number with
  | false -> 0.
  | true ->
      let wrapped = Float.rem (Float.trunc number) 4294967296. in
      if wrapped < 0. then wrapped +. 4294967296. else wrapped

let int32 number =
  let wrapped = uint32 number in
  if wrapped >= 2147483648. then wrapped -. 4294967296. else wrapped

let uchars text =
  let rec decoded at found =
    if at >= String.length text then List.rev found
    else
      let decoding = String.get_utf_8_uchar text at in
      decoded
        (at + Uchar.utf_decode_length decoding)
        (Uchar.utf_decode_uchar decoding :: found)
  in
  decoded 0 []

let utf_8 uchar =
  let buffer = Buffer.create 4 in
  Buffer.add_utf_8_uchar buffer uchar;
  Buffer.contents buffer

let number text =
  let trimmed = String.trim text in
  let digits = "0123456789+-.eE" in
  match trimmed with
  | "" -> 0.
  | "Infinity" | "+Infinity" -> Float.infinity
  | "-Infinity" -> Float.neg_infinity
  | _
    when String.starts_with ~prefix:"0x" trimmed
         || String.starts_with ~prefix:"0X" trimmed ->
      Option.fold ~none:Float.nan ~some:Float.of_int (int_of_string_opt trimmed)
  | _ when String.for_all (fun char -> String.contains digits char) trimmed ->
      Option.value ~default:Float.nan (float_of_string_opt trimmed)
  | _ -> Float.nan

let rec term program ~home scope joins (current : Ir.Ast.term) : Value.t =
  program.steps <- program.steps - 1;
  if program.steps < 0 then raise (Stopped Budget_exhausted);
  match current with
  | T_return returned -> atom program ~home scope returned
  | T_let { name; bind = bound; body } ->
      term program ~home
        (Value.Scope.add name (bind program ~home scope bound) scope)
        joins body
  | T_if { condition; consequent; alternative } -> (
      let sources, condition = peeled (atom program ~home scope condition) in
      match condition with
      | V_bool true -> Value.labelled sources (term program ~home scope joins consequent)
      | V_bool false -> Value.labelled sources (term program ~home scope joins alternative)
      | _ -> stuck "an if on a value that is not a Bool")
  | T_switch { subject; branches; default } -> (
      let canonical (test : Ir.Ast.Decision_tree.test) :
          Ir.Ast.Decision_tree.test =
        let named name =
          match Primitives.bool_of_constructor name with
          | Some truth -> Primitives.bool_constructor truth
          | None ->
              let { Value.module_name; name } = global ~home name in
              Data.Name.global ~module_name ~exported_name:name
        in
        match test with
        | Test_ctor name -> Test_ctor (named name)
        | Test_tag name -> Test_tag (named name)
        | Test_int _ | Test_str _ | Test_chr _ | Test_nil | Test_cons -> test
      in
      let sources, subject = peeled (atom program ~home scope subject) in
      let head : Ir.Ast.Decision_tree.test =
        match subject with
        | V_number value -> Test_int (Float.to_int value)
        | V_string value -> Test_str value
        | V_char value -> Test_chr value
        | V_list [] -> Test_nil
        | V_list (_ :: _) -> Test_cons
        | V_bool truth -> Test_ctor (Primitives.bool_constructor truth)
        | V_constr { constructor = { module_name; name }; arguments = [] } ->
            Test_ctor (Data.Name.global ~module_name ~exported_name:name)
        | V_constr { constructor = { module_name; name }; arguments = _ :: _ } ->
            Test_tag (Data.Name.global ~module_name ~exported_name:name)
        | V_unit | V_tuple _ | V_record _ | V_closure _ | V_task _ | V_labelled _ ->
            stuck "a case on a value without a shape"
      in
      match
        ( List.assoc_opt head
            (List.map (fun (test, branch) -> (canonical test, branch)) branches),
          default )
      with
      | Some branch, _ | None, Some branch ->
          Value.labelled sources (term program ~home scope joins branch)
      | None, None -> stuck "a case without a matching branch")
  | T_join { label; parameters; definition; body } ->
      term program ~home scope
        (Value.Scope.add label { parameters; definition; scope; joins } joins)
        body
  | T_jump { label; arguments } -> (
      match Value.Scope.find_opt label joins with
      | None -> stuck ("a jump to an unknown label " ^ label)
      | Some join ->
          let rec bound scope parameters arguments =
            match (parameters, arguments) with
            | [], [] -> scope
            | parameter :: parameters, argument :: arguments ->
                bound
                  (Value.Scope.add parameter
                     (atom program ~home scope argument)
                     scope)
                  parameters arguments
            | [], _ :: _ | _ :: _, [] -> stuck "a jump with the wrong arity"
          in
          term program ~home
            (bound join.scope join.parameters arguments)
            join.joins join.definition)
  | T_fail { message } -> stuck message

and atom program ~home scope (written : Ir.Ast.atom) : Value.t =
  match written with
  | A_var name -> (
      match Value.Scope.find_opt name scope with
      | Some value -> value
      | None -> stuck ("an unbound variable " ^ name))
  | A_int value -> V_number (Float.of_int value)
  | A_float value -> V_number value
  | A_string value -> V_string value
  | A_char value -> V_char value
  | A_unit -> V_unit
  | A_nil -> V_list []
  | A_constant name -> constant ~home name
  | A_global name -> top program ~home name

and top program ~home name =
  let found = global ~home name in
  match
    ( Hashtbl.find_opt program.declarations found,
      Hashtbl.find_opt program.constructors found,
      Hashtbl.find_opt program.cached found )
  with
  | _, _, Some value -> value
  | Some { Ir.Ast.parameters = []; body; _ }, _, None ->
      let value =
        term program ~home:found.module_name Value.Scope.empty Value.Scope.empty
          body
      in
      Hashtbl.replace program.cached found value;
      value
  | Some { parameters; body; _ }, _, None ->
      V_closure
        { home = found.module_name; parameters; scope = Value.Scope.empty; body }
  | None, Some 0, None | None, None, None -> constant ~home name
  | None, Some arity, None ->
      let parameters = List.init arity (Printf.sprintf "%%%d") in
      V_closure
        {
          home = found.module_name;
          parameters;
          scope = Value.Scope.empty;
          body =
            T_let
              {
                name = "%built";
                bind =
                  B_construct
                    {
                      name = Data.Name.local found.name;
                      arguments =
                        List.map
                          (fun parameter -> Ir.Ast.A_var parameter)
                          parameters;
                    };
                body = T_return (A_var "%built");
              };
        }

and called program (callee : Value.t) arguments : Value.t =
  let sources, callee = peeled callee in
  Value.labelled sources
  @@
  match (callee, arguments) with
  | _, [] -> callee
  | V_closure closure, _ :: _ ->
      let rec saturated scope parameters arguments =
        match (parameters, arguments) with
        | [], rest ->
            called program
              (term program ~home:closure.home scope Value.Scope.empty
                 closure.body)
              rest
        | parameter :: parameters, argument :: arguments ->
            saturated
              (Value.Scope.add parameter argument scope)
              parameters arguments
        | (_ :: _ as parameters), [] ->
            V_closure { closure with parameters; scope }
      in
      saturated closure.scope closure.parameters arguments
  | _, _ :: _ -> stuck "a call of a value that is not a function"

and bind program ~home scope (bound : Ir.Ast.bind) : Value.t =
  match bound with
  | B_atom written -> atom program ~home scope written
  | B_construct { name; arguments = [] } -> constant ~home name
  | B_construct { name; arguments = _ :: _ as arguments } ->
      V_constr
        {
          constructor = global ~home name;
          arguments = List.map (atom program ~home scope) arguments;
        }
  | B_cons { head; tail } -> (
      let sources, tail = peeled (atom program ~home scope tail) in
      match tail with
      | V_list rest -> Value.labelled sources (V_list (atom program ~home scope head :: rest))
      | _ -> stuck "a cons onto a value that is not a List")
  | B_tuple { items } -> V_tuple (List.map (atom program ~home scope) items)
  | B_record { fields } ->
      V_record
        (List.sort
           (fun (one, _) (other, _) -> String.compare one other)
           (List.map
              (fun (label, value) -> (label, atom program ~home scope value))
              fields))
  | B_record_update { base; fields } -> (
      let sources, base = peeled (atom program ~home scope base) in
      match base with
      | V_record old ->
          Value.labelled sources
          @@ V_record
            (List.map
               (fun (label, value) ->
                 ( label,
                   Option.fold ~none:value ~some:(atom program ~home scope)
                     (List.assoc_opt label fields) ))
               old)
      | _ -> stuck "an update of a value that is not a record")
  | B_access { subject; step } -> (
      let sources, subject = peeled (atom program ~home scope subject) in
      Value.labelled sources
      @@
      match (step, subject) with
      | Payload index, V_constr { arguments; _ }
      | Index index, V_tuple arguments -> (
          match List.nth_opt arguments index with
          | Some value -> value
          | None -> stuck "an access out of range")
      | Field label, V_record fields -> (
          match List.assoc_opt label fields with
          | Some value -> value
          | None -> stuck ("a record without the field " ^ label))
      | Hd, V_list (first :: _) -> first
      | Tl, V_list (_ :: rest) -> V_list rest
      | (Payload _ | Index _ | Field _ | Hd | Tl), _ ->
          stuck "an access that does not fit its value")
  | B_call { callee; arguments } | B_partial { callee; arguments; _ } -> (
      match
        ( global ~home callee,
          List.map (fun argument -> snd (Value.plain (atom program ~home scope argument))) arguments )
      with
      | { module_name = "Agent"; name = "hole" }, [ V_string description ] ->
          V_task
            (Hole
               {
                 description;
                 locals =
                   Value.Scope.filter
                     (fun name _ ->
                       String.length name > 0
                       && (match name.[0] with 'a' .. 'z' -> true | _ -> false)
                       && String.for_all
                            (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
                            name)
                     scope;
               })
      | _, _ -> called program (top program ~home callee) (List.map (atom program ~home scope) arguments))
  | B_call_closure { callee; arguments } ->
      called program
        (atom program ~home scope callee)
        (List.map (atom program ~home scope) arguments)
  | B_primitive { operator; arguments } -> (
      let found = List.map (fun argument -> Value.plain (atom program ~home scope argument)) arguments in
      Value.labelled (List.concat_map fst found)
      @@
      match (operator, List.map snd found) with
      | Add, [ V_number left; V_number right ] -> V_number (left +. right)
      | Subtract, [ V_number left; V_number right ] -> V_number (left -. right)
      | Multiply, [ V_number left; V_number right ] -> V_number (left *. right)
      | Divide, [ V_number left; V_number right ] -> V_number (left /. right)
      | Integer_divide, [ V_number left; V_number right ] ->
          V_number (int32 (left /. right))
      | Power, [ V_number left; V_number right ] -> V_number (Float.pow left right)
      | Append, [ V_string left; V_string right ] -> V_string (left ^ right)
      | Append, [ V_list left; V_list right ] -> V_list (left @ right)
      | Equal, [ left; right ] -> V_bool (equal left right)
      | Not_equal, [ left; right ] -> V_bool (not (equal left right))
      | Less, [ left; right ] -> V_bool (compared left right < 0)
      | Less_or_equal, [ left; right ] -> V_bool (compared left right <= 0)
      | Greater, [ left; right ] -> V_bool (compared left right > 0)
      | Greater_or_equal, [ left; right ] -> V_bool (compared left right >= 0)
      | Conjunction, [ V_bool left; V_bool right ] -> V_bool (left && right)
      | Disjunction, [ V_bool left; V_bool right ] -> V_bool (left || right)
      | _, _ ->
          stuck
            ("an operator on values it does not take: "
            ^ Data.Operator.lexeme operator))
  | B_kernel { kernel = Language language; arguments } -> (
      let units uchar = if Uchar.to_int uchar >= 0x10000 then 2 else 1 in
      let length text =
        List.fold_left (fun sum uchar -> sum + units uchar) 0 (uchars text)
      in
      let sliced text start stop =
        let length = length text in
        let clamped at =
          let at =
            Float.to_int
              (Float.max (Float.of_int (-length)) (Float.min at (Float.of_int length)))
          in
          if at < 0 then length + at else at
        in
        let start = clamped start and stop = clamped stop in
        snd
          (List.fold_left
             (fun (at, kept) uchar ->
               ( at + units uchar,
                 if at >= start && at + units uchar <= stop then kept ^ utf_8 uchar
                 else kept ))
             (0, "") (uchars text))
      in
      let math operation number : Value.t = V_number (operation number) in
      let found = List.map (fun argument -> Value.plain (atom program ~home scope argument)) arguments in
      Value.labelled (List.concat_map fst found)
      @@
      match (language, List.map snd found) with
      | Nullary Basics_pi, [] -> V_number Float.pi
      | Nullary Basics_e, [] -> V_number (Float.exp 1.)
      | Unary String_length, [ V_string text ] ->
          V_number (Float.of_int (length text))
      | Unary String_from_number, [ V_number value ] ->
          V_string
            (match Float.classify_float value with
            | FP_nan -> "NaN"
            | FP_infinite -> if value > 0. then "Infinity" else "-Infinity"
            | FP_zero -> "0"
            | FP_normal | FP_subnormal
              when Float.is_integer value && Float.abs value < 1e21 ->
                Printf.sprintf "%.0f" value
            | FP_normal | FP_subnormal ->
                Option.value ~default:(Printf.sprintf "%.17g" value)
                  (List.find_map
                     (fun precision ->
                       let shown = Printf.sprintf "%.*g" precision value in
                       if Float.equal (float_of_string shown) value then Some shown
                       else None)
                     (List.init 17 succ)))
      | Unary String_is_int, [ V_string text ] ->
          V_bool ((not (String.equal text "")) && Float.is_integer (number text))
      | Unary String_to_int_unsafe, [ V_string text ]
      | Unary String_to_float_unsafe, [ V_string text ] ->
          V_number (number text)
      | Unary String_is_float, [ V_string text ] ->
          V_bool ((not (String.equal text "")) && not (Float.is_nan (number text)))
      | Unary String_to_list, [ V_string text ] ->
          V_list (List.map (fun uchar -> Value.V_char (utf_8 uchar)) (uchars text))
      | Unary String_from_list, [ V_list chars ] ->
          V_string
            (String.concat ""
               (List.map
                  (function
                    | Value.V_char char -> char
                    | _ -> stuck "a string from values that are not chars")
                  chars))
      | Unary Basics_to_float, [ (V_number _ as number) ] -> number
      | Unary Basics_round, [ V_number number ] -> math (fun x -> Float.floor (x +. 0.5)) number
      | Unary Basics_floor, [ V_number number ] -> math Float.floor number
      | Unary Basics_ceiling, [ V_number number ] -> math Float.ceil number
      | Unary Basics_truncate, [ V_number number ] -> math int32 number
      | Unary Basics_is_nan, [ V_number number ] -> V_bool (Float.is_nan number)
      | Unary Basics_is_infinite, [ V_number number ] ->
          V_bool (Float.equal (Float.abs number) Float.infinity)
      | Unary Basics_sqrt, [ V_number number ] -> math Float.sqrt number
      | Unary Basics_log, [ V_number number ] -> math Float.log number
      | Unary Basics_cos, [ V_number number ] -> math Float.cos number
      | Unary Basics_sin, [ V_number number ] -> math Float.sin number
      | Unary Basics_tan, [ V_number number ] -> math Float.tan number
      | Unary Basics_acos, [ V_number number ] -> math Float.acos number
      | Unary Basics_asin, [ V_number number ] -> math Float.asin number
      | Unary Basics_atan, [ V_number number ] -> math Float.atan number
      | Unary Basics_not, [ V_bool truth ] -> V_bool (not truth)
      | Unary Char_to_code, [ V_char char ] ->
          V_number
            (Float.of_int
               (Option.fold ~none:0 ~some:Uchar.to_int (List.nth_opt (uchars char) 0)))
      | Unary Char_from_code, [ V_number code ] ->
          let code = Float.to_int code in
          V_char
            (utf_8 (if Uchar.is_valid code then Uchar.of_int code else Uchar.rep))
      | Unary Char_to_upper, [ V_char char ] -> V_char (String.uppercase_ascii char)
      | Unary Char_to_lower, [ V_char char ] -> V_char (String.lowercase_ascii char)
      | Unary List_reverse, [ V_list items ] -> V_list (List.rev items)
      | Unary List_length, [ V_list items ] ->
          V_number (Float.of_int (List.length items))
      | Unary Bitwise_complement, [ V_number number ] ->
          V_number (int32 (Float.of_int (lnot (Float.to_int (int32 number)))))
      | Binary String_append, [ V_string left; V_string right ] ->
          V_string (left ^ right)
      | Binary String_split, [ V_string separator; V_string text ] -> (
          match separator with
          | "" ->
              V_list
                (List.map (fun uchar -> Value.V_string (utf_8 uchar)) (uchars text))
          | _ ->
              let rec pieces from found =
                let rec at index =
                  if index + String.length separator > String.length text then None
                  else if
                    String.equal
                      (String.sub text index (String.length separator))
                      separator
                  then Some index
                  else at (index + 1)
                in
                match at from with
                | Some index ->
                    pieces
                      (index + String.length separator)
                      (Value.V_string (String.sub text from (index - from)) :: found)
                | None ->
                    List.rev
                      (Value.V_string
                         (String.sub text from (String.length text - from))
                      :: found)
              in
              V_list (pieces 0 []))
      | Binary String_take_left, [ V_number count; V_string text ] ->
          V_string (sliced text 0. count)
      | Binary String_drop_left, [ V_number count; V_string text ] ->
          V_string (sliced text count Float.infinity)
      | Binary Utils_compare, [ left; right ] ->
          V_number (Float.of_int (compared left right))
      | Binary Basics_mod_by, [ V_number modulus; V_number number ] -> (
          match Float.equal modulus 0. with
          | true -> crashed "modBy: division by zero"
          | false ->
              let answer = Float.rem number modulus in
              V_number
                (if (answer > 0. && modulus < 0.) || (answer < 0. && modulus > 0.)
                 then answer +. modulus
                 else answer))
      | Binary Basics_remainder_by, [ V_number modulus; V_number number ] ->
          V_number (Float.rem number modulus)
      | Binary Basics_atan2, [ V_number y; V_number x ] -> V_number (Float.atan2 y x)
      | Binary Basics_xor, [ V_bool left; V_bool right ] ->
          V_bool (not (Bool.equal left right))
      | Binary List_map, [ callback; V_list items ] ->
          V_list (List.map (fun item -> called program callback [ item ]) items)
      | Binary List_indexed_map, [ callback; V_list items ] ->
          V_list
            (List.mapi
               (fun index item ->
                 called program callback [ V_number (Float.of_int index); item ])
               items)
      | Binary List_filter, [ callback; V_list items ] ->
          V_list
            (List.filter
               (fun item ->
                 match called program callback [ item ] with
                 | V_bool truth -> truth
                 | _ -> stuck "a filter whose test is not a Bool")
               items)
      | Binary Bitwise_and, [ V_number left; V_number right ] ->
          V_number
            (int32
               (Float.of_int
                  (Float.to_int (int32 left) land Float.to_int (int32 right))))
      | Binary Bitwise_or, [ V_number left; V_number right ] ->
          V_number
            (int32
               (Float.of_int
                  (Float.to_int (int32 left) lor Float.to_int (int32 right))))
      | Binary Bitwise_xor, [ V_number left; V_number right ] ->
          V_number
            (int32
               (Float.of_int
                  (Float.to_int (int32 left) lxor Float.to_int (int32 right))))
      | Binary Bitwise_shift_left_by, [ V_number offset; V_number number ] ->
          V_number
            (int32
               (Float.of_int
                  (Float.to_int (int32 number) lsl (Float.to_int (uint32 offset) land 31))))
      | Binary Bitwise_shift_right_by, [ V_number offset; V_number number ] ->
          V_number
            (Float.of_int
               (Float.to_int (int32 number) asr (Float.to_int (uint32 offset) land 31)))
      | Binary Bitwise_shift_right_zf_by, [ V_number offset; V_number number ] ->
          V_number
            (Float.of_int
               (Float.to_int (uint32 number) lsr (Float.to_int (uint32 offset) land 31)))
      | (Nullary _ | Unary _ | Binary _), _ ->
          stuck
            ("a kernel with the wrong arguments: "
            ^ Data.Name.to_string (Data.Kernel.origin language)))
  | B_kernel { kernel = Platform { name; _ }; arguments } -> (
      let field label fields =
        match List.assoc_opt label fields with
        | Some (Value.V_string text) -> text
        | Some _ | None ->
            stuck ("a tool record without the text field " ^ label)
      in
      let raw = List.map (atom program ~home scope) arguments in
      let found = List.map Value.plain raw in
      let task (built : Value.task) = Value.labelled (List.concat_map fst found) (V_task built) in
      match (Data.Kernel.agent_of_name name, raw) with
      | Some Task_succeed, [ value ] -> V_task (Succeed value)
      | Some Task_fail, [ value ] -> V_task (Fail value)
      | Some ((Task_and_then | Task_map | Task_map_err | Task_on_error) as kernel), [ callback; built ]
        -> (
          let callers, callback = peeled callback in
          match (callback, built) with
          | V_closure callback, V_task task ->
              Value.labelled callers
                (V_task
                   (match kernel with
                   | Task_and_then -> And_then { callback; task }
                   | Task_map -> Map { callback; task }
                   | Task_map_err -> Map_err { callback; task }
                   | Task_on_error | Agent_read | Agent_write | Agent_edit | Agent_grep | Agent_shell
                   | Agent_hole | Agent_call | Agent_enter | Agent_leave | Agent_merge | Task_succeed
                   | Task_fail | Task_batch ->
                       On_error { callback; task }))
          | _ -> stuck ("a task kernel with the wrong arguments: " ^ Data.Name.to_string name))
      | Some Task_batch, [ tasks ] -> (
          let listed, tasks = peeled tasks in
          match tasks with
          | V_list tasks ->
              Value.labelled listed
                (V_task
                   (Batch
                      (List.map
                         (function
                           | Value.V_task task -> task
                           | _ -> stuck "a batch of values that are not tasks")
                         tasks)))
          | _ -> stuck "a batch of values that are not tasks")
      | _ ->
      task
        (match
           ( Data.Kernel.agent_of_name name,
             List.map snd found )
         with
        | Some Agent_read, [ V_string path ] -> Tool (Read path)
        | Some Agent_write, [ V_string path; V_string content ] ->
            Tool (Write { path; content })
        | Some Agent_edit, [ V_record fields ] ->
            Tool
              (Edit
                 {
                   path = field "path" fields;
                   old = field "old" fields;
                   new_ = field "new" fields;
                 })
        | Some Agent_grep, [ V_record fields ] ->
            Tool
              (Grep { pattern = field "pattern" fields; glob = field "glob" fields })
        | Some Agent_shell, [ V_string command ] -> Tool (Shell command)
        | Some Agent_hole, [ V_string description ] -> Hole { description; locals = Value.Scope.empty }
        | Some Agent_call, [ V_string name; argument ] -> Tool (Call { name; argument })
        | Some Agent_enter, [ V_list mounts ] ->
            Tool
              (Enter
                 (List.map
                    (function
                      | Value.V_constr
                          { constructor = { module_name = "Agent"; name }; arguments = [ V_string path ] }
                        -> (
                          match
                            ( Tools.Path.of_string path,
                              List.assoc_opt name
                                [ ("Hidden", Tools.Hidden); ("Readonly", Tools.Readonly); ("Scratch", Tools.Scratch) ] )
                          with
                          | Ok path, Some mount -> (path, mount)
                          | Error _, _ -> crashed ("spawn: " ^ path ^ " is not a path in the project")
                          | Ok _, None -> stuck ("spawn: an unknown mount " ^ name))
                      | _ -> stuck "spawn: a mount that is not a Mount")
                    mounts))
        | Some Agent_leave, [ _ ] -> Tool Leave
        | Some Agent_merge, [ V_list changes ] ->
            let text = function
              | Value.V_constr { constructor = { name = "Just"; _ }; arguments = [ V_string text ] } -> Some text
              | Value.V_constr { constructor = { name = "Nothing"; _ }; arguments = [] } -> None
              | _ -> stuck "merge: a change whose text is not a Maybe String"
            in
            Tool
              (Merge
                 (List.map
                    (function
                      | Value.V_record [ ("base", base); ("content", content); ("path", V_string file) ] ->
                          { Value.file; base = text base; content = text content }
                      | _ -> stuck "merge: a change that is not a Change")
                    changes))
        | Some _, _ ->
            stuck
              ("an agent kernel with the wrong arguments: "
              ^ Data.Name.to_string name)
        | None, _ ->
            stuck ("an unknown platform kernel " ^ Data.Name.to_string name)))
  | B_closure { parameters; captures = _; body } ->
      V_closure { home; parameters; scope; body }

let guarded run =
  match run () with
  | value -> Ok value
  | exception Stopped error -> Error (`Interp error)

let main program =
  Result.bind
    (guarded (fun () -> top program ~home:"Main" (Data.Name.local "main")))
    (function
      | Value.V_task task -> Ok task
      | _ -> Error (`Interp (Stuck "main is not a task")))

let apply program callback argument =
  guarded (fun () -> called program (V_closure callback) [ argument ])
