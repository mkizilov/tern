module Ids = Map.Make (Int)

type context = {
  mutable strings : (string * int) list;
  mutable division : bool;
  mutable remainder : bool;
}

let variable (name : Core.name) = "$v" ^ string_of_int name.value.id

let indent text =
  String.split_on_char '\n' text |> List.map (( ^ ) "  ") |> String.concat "\n"

let unsupported span feature =
  Diagnostic.fail span
    ("the part-1 Wasm backend does not support " ^ feature ^ " yet")

let atom context = function
  | Anf.Name name -> "(local.get " ^ variable name ^ ")"
  | Literal (Ast.Int value) ->
      "(call $rt_int (i32.const " ^ Int32.to_string value ^ "))"
  | Literal (Bool value) -> if value then "(i64.const 10)" else "(i64.const 2)"
  | Literal Unit -> "(i64.const 3)"
  | Literal (String text) ->
      let index =
        match List.assoc_opt text context.strings with
        | Some index -> index
        | None ->
            let index = List.length context.strings in
            context.strings <- context.strings @ [ (text, index) ];
            index
      in
      Printf.sprintf "(call $literal%d)" index

let call name arguments =
  "(call " ^ name
  ^ (if arguments = [] then "" else " " ^ String.concat " " arguments)
  ^ ")"

let primitive context (operator : Core.primitive Ast.located) arguments =
  let arguments = List.map (atom context) arguments in
  let integers =
    List.map (fun value -> call "$rt_unbox_int" [ value ]) arguments
  in
  let operation name = "(" ^ name ^ " " ^ String.concat " " integers ^ ")" in
  match operator.value with
  | Core.Concat -> unsupported operator.span "string concatenation"
  | Negate ->
      call "$rt_int" [ "(i32.sub (i32.const 0) " ^ List.hd integers ^ ")" ]
  | Add -> call "$rt_int" [ operation "i32.add" ]
  | Subtract -> call "$rt_int" [ operation "i32.sub" ]
  | Multiply -> call "$rt_int" [ operation "i32.mul" ]
  | Divide ->
      context.division <- true;
      call "$checked_divide" arguments
  | Remainder ->
      context.remainder <- true;
      call "$checked_remainder" arguments
  | Equal -> call "$rt_bool" [ operation "i32.eq" ]
  | Not_equal -> call "$rt_bool" [ operation "i32.ne" ]
  | Less -> call "$rt_bool" [ operation "i32.lt_s" ]
  | Less_equal -> call "$rt_bool" [ operation "i32.le_s" ]
  | Greater -> call "$rt_bool" [ operation "i32.gt_s" ]
  | Greater_equal -> call "$rt_bool" [ operation "i32.ge_s" ]

let rec expression context (source : Closed.expr) =
  match source.value with
  | Return value -> atom context value
  | Let (name, rhs, body) ->
      let rhs = right_hand_side context rhs in
      "(local.set " ^ variable name ^ " " ^ rhs ^ ")\n"
      ^ expression context body
  | If (condition, yes, no) ->
      let condition = call "$rt_unbox_bool" [ atom context condition ] in
      let yes = expression context yes in
      let no = expression context no in
      "(if (result i64) " ^ condition ^ "\n"
      ^ indent ("(then\n" ^ indent yes ^ ")\n(else\n" ^ indent no ^ ")")
      ^ ")"
  | Joins _ | Jump _ | Switch _ | Fail _ ->
      unsupported source.span "pattern matching"

and right_hand_side context (source : Closed.rhs) =
  let value = atom context in
  match source.value with
  | Alias atom -> value atom
  | Direct_call (index, environment, argument) ->
      call ("$fn" ^ string_of_int index) [ value environment; value argument ]
  | Closure_call _ -> unsupported source.span "indirect closure calls"
  | Primitive (operator, arguments) -> primitive context operator arguments
  | Builtin_apply (Core.Print_int, argument) ->
      call "$rt_print_int" [ value argument ]
  | Builtin_apply (Print_string, argument) ->
      call "$rt_print_string" [ value argument ]
  | Block body ->
      "(block (result i64)\n" ^ indent (expression context body) ^ ")"
  | Environment fields ->
      let stores =
        List.mapi
          (fun index field ->
            "(drop "
            ^ call "$rt_field_set"
                [
                  "(local.get $allocation)";
                  "(i32.const " ^ string_of_int index ^ ")";
                  value field;
                ]
            ^ ")")
          fields
      in
      "(block (result i64)\n"
      ^ indent
          (String.concat "\n"
             ([
                "(local.set $allocation "
                ^ call "$rt_environment"
                    [ "(i32.const " ^ string_of_int (List.length fields) ^ ")" ]
                ^ ")";
              ]
             @ stores
             @ [ "(local.get $allocation)" ]))
      ^ ")"
  | Allocate_environment count ->
      call "$rt_environment" [ "(i32.const " ^ string_of_int count ^ ")" ]
  | Environment_get (environment, index) ->
      call "$rt_field_get"
        [ value environment; "(i32.const " ^ string_of_int index ^ ")" ]
  | Environment_set (environment, index, field) ->
      call "$rt_field_set"
        [
          value environment;
          "(i32.const " ^ string_of_int index ^ ")";
          value field;
        ]
  | Closure (index, environment) ->
      call "$rt_closure"
        [ "(i32.const " ^ string_of_int index ^ ")"; value environment ]
  | Closure_environment closure ->
      call "$rt_closure_environment" [ value closure ]
  | Tuple _ | Field _ -> unsupported source.span "tuples"
  | Variant _ | Payload _ -> unsupported source.span "variants"

let rec locals (source : Closed.expr) =
  match source.value with
  | Let (name, rhs, body) ->
      let inner =
        match rhs.value with Closed.Block body -> locals body | _ -> []
      in
      (name :: inner) @ locals body
  | If (_, yes, no) -> locals yes @ locals no
  | _ -> []

let source_names (program : Closed.program) =
  let aliases = ref Ids.empty in
  let rec scan (source : Closed.expr) =
    match source.value with
    | Let (name, rhs, body) ->
        (match rhs.value with
        | Closed.Alias (Anf.Name original) ->
            if not (Ids.mem original.value.id !aliases) then
              aliases := Ids.add original.value.id name !aliases
        | Block inner -> scan inner
        | _ -> ());
        scan body
    | If (_, yes, no) ->
        scan yes;
        scan no
    | _ -> ()
  in
  scan program.value.body;
  List.iter
    (fun (f : Closed.function_definition) -> scan f.value.body)
    program.value.functions;
  fun (name : Core.name) ->
    if String.starts_with ~prefix:"$" name.value.spelling then
      Option.value (Ids.find_opt name.value.id !aliases) ~default:name
    else name

let declarations names =
  List.map (fun name -> "(local " ^ variable name ^ " i64)") names
  |> String.concat "\n"

let checked_arithmetic name instruction =
  Printf.sprintf
    "(func $%s (param $left i64) (param $right i64) (result i64)\n\
    \  (local $a i32) (local $b i32)\n\
    \  (local.set $a (call $rt_unbox_int (local.get $left)))\n\
    \  (local.set $b (call $rt_unbox_int (local.get $right)))\n\
    \  (if (i32.or (i32.eqz (local.get $b))\n\
    \        (i32.and (i32.eq (local.get $a) (i32.const -2147483648))\n\
    \                 (i32.eq (local.get $b) (i32.const -1)))) (then \
     unreachable))\n\
    \  (call $rt_int (%s (local.get $a) (local.get $b))))"
    name instruction

let literal (text, index) =
  let bytes =
    String.to_seq text |> List.of_seq
    |> List.map (fun c -> Printf.sprintf "\\%02x" (Char.code c))
    |> String.concat ""
  in
  Printf.sprintf
    ";; UTF-8 literal %d: %d bytes\n\
     (data $data%d \"%s\")\n\
     (func $literal%d (result i64) (local $string i64)\n\
    \  (local.set $string (call $rt_string (i32.const %d)))\n\
    \  (memory.init $data%d (call $rt_string_data (local.get $string)) \
     (i32.const 0) (i32.const %d))\n\
    \  (local.get $string))"
    index (String.length text) index bytes index (String.length text) index
    (String.length text)

let program (program : Closed.program) =
  try
    let context = { strings = []; division = false; remainder = false } in
    let source_name = source_names program in
    let functions =
      List.map
        (fun (definition : Closed.function_definition) ->
          let f = definition.value in
          let body = expression context f.body in
          let declarations = declarations (locals f.body) in
          let name = source_name f.name in
          Printf.sprintf
            ";; source function %s#%d (code %d)\n\
             (func $fn%d (type $tern_function) (param %s i64) (param %s i64) \
             (result i64)\n\
             %s\n\
             )"
            name.value.spelling name.value.id f.index f.index
            (variable f.environment) (variable f.parameter)
            (indent ("(local $allocation i64)\n" ^ declarations ^ "\n" ^ body)))
        program.value.functions
    in
    let body = expression context program.value.body in
    let initialization =
      List.map
        (fun ((name : Core.name), index) ->
          "(local.set " ^ variable name ^ " "
          ^ call "$rt_closure"
              [
                "(i32.const " ^ string_of_int index ^ ")";
                call "$rt_environment" [ "(i32.const 0)" ];
              ]
          ^ ")")
        program.value.builtins
    in
    let entry =
      "(func (export \"_start\")\n"
      ^ indent
          ("(local $allocation i64)\n"
          ^ declarations
              (List.map fst program.value.builtins @ locals program.value.body)
          ^ "\n"
          ^ String.concat "\n" initialization
          ^ "\n(drop (block (result i64)\n" ^ indent body ^ "))")
      ^ "\n)"
    in
    let arithmetic =
      (if context.division then
         [ checked_arithmetic "checked_divide" "i32.div_s" ]
       else [])
      @
      if context.remainder then
        [ checked_arithmetic "checked_remainder" "i32.rem_s" ]
      else []
    in
    let runtime = String.trim Runtime_assets.wat in
    Ok
      (String.sub runtime 0 (String.length runtime - 1)
      ^ "\n"
      ^ String.concat "\n\n"
          (arithmetic @ List.map literal context.strings @ functions @ [ entry ])
      ^ "\n)\n")
  with Diagnostic.Raised diagnostic -> Error diagnostic
