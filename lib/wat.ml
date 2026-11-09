module Ids = Map.Make (Int)

type context = {
  mutable strings : (string * int) list;
  mutable division : bool;
  mutable remainder : bool;
  mutable next_label : int;
  mutable roots : int Ids.t;
  mutable allocation_slot : int;
}

type join_target = { block : string; parameters : Core.name list }

let variable (name : Core.name) = "$v" ^ string_of_int name.value.id

let indent text =
  String.split_on_char '\n' text |> List.map (( ^ ) "  ") |> String.concat "\n"

let label context prefix =
  let value = "$" ^ prefix ^ string_of_int context.next_label in
  context.next_label <- context.next_label + 1;
  value

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

let root_slot slot value =
  call "$rt_root_set"
    [ "(local.get $frame)"; "(i32.const " ^ string_of_int slot ^ ")"; value ]

let root context (name : Core.name) =
  root_slot
    (Ids.find name.value.id context.roots)
    ("(local.get " ^ variable name ^ ")")

let invoke tail target environment argument code =
  if not tail then target environment argument code
  else
    "(block (result i64)\n"
    ^ indent
        ("(local.set $call_env " ^ environment ^ ")\n(local.set $call_arg "
       ^ argument ^ ")\n"
        ^ (match code with
          | None -> ""
          | Some code -> "(local.set $call_code " ^ code ^ ")\n")
        ^ call "$rt_frame_pop" [ "(local.get $frame)" ]
        ^ "\n"
        ^ target "(local.get $call_env)" "(local.get $call_arg)"
            (Option.map (fun _ -> "(local.get $call_code)") code))
    ^ ")"

let primitive context (operator : Core.primitive Ast.located) arguments =
  let arguments = List.map (atom context) arguments in
  let integers =
    List.map (fun value -> call "$rt_unbox_int" [ value ]) arguments
  in
  let operation name = "(" ^ name ^ " " ^ String.concat " " integers ^ ")" in
  match operator.value with
  | Core.Concat -> call "$rt_string_concat" arguments
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

let rec forwards (name : Core.name) (source : Closed.expr) =
  match source.value with
  | Return (Anf.Name result) -> result.value.id = name.value.id
  | Let (alias, { value = Closed.Alias (Anf.Name original); _ }, body)
    when original.value.id = name.value.id ->
      forwards alias body
  | _ -> false

let branch condition yes no =
  "(if (result i64) " ^ condition ^ "\n"
  ^ indent ("(then\n" ^ indent yes ^ ")\n(else\n" ^ indent no ^ ")")
  ^ ")"

let allocation context helper fields =
  let stores =
    List.mapi
      (fun index field ->
        "(drop "
        ^ call "$rt_field_set"
            [
              "(local.get $allocation)";
              "(i32.const " ^ string_of_int index ^ ")";
              atom context field;
            ]
        ^ ")")
      fields
  in
  "(block (result i64)\n"
  ^ indent
      (String.concat "\n"
         ([
            "(local.set $allocation "
            ^ call helper
                [ "(i32.const " ^ string_of_int (List.length fields) ^ ")" ]
            ^ ")";
            root_slot context.allocation_slot "(local.get $allocation)";
          ]
         @ stores
         @ [ "(local.get $allocation)" ]))
  ^ ")"

let rec expression context joins tail (source : Closed.expr) =
  match source.value with
  | Return value -> atom context value
  | Let (name, rhs, body) when tail && forwards name body ->
      right_hand_side context joins true rhs
  | Let (name, rhs, body) ->
      let rhs = right_hand_side context joins false rhs in
      "(local.set " ^ variable name ^ " " ^ rhs ^ ")\n" ^ root context name
      ^ "\n"
      ^ expression context joins tail body
  | If (condition, yes, no) ->
      let condition = call "$rt_unbox_bool" [ atom context condition ] in
      let yes = expression context joins tail yes in
      let no = expression context joins tail no in
      branch condition yes no
  | Joins (definitions, body) ->
      let done_label = label context "joins_done" in
      let targets =
        List.map
          (fun (join : Closed.join) ->
            ( join,
              {
                block = "$join" ^ string_of_int join.value.label.value.id;
                parameters = join.value.parameters;
              } ))
          definitions
      in
      let dispatch_joins =
        List.fold_left
          (fun joins ((join : Closed.join), target) ->
            Ids.add join.value.label.value.id target joins)
          joins targets
      in
      let finish body =
        "(br " ^ done_label ^ " (block (result i64)\n" ^ indent body ^ "))"
      in
      let dispatch = finish (expression context dispatch_joins tail body) in
      let body =
        List.fold_left
          (fun body ((join : Closed.join), target) ->
            "(block " ^ target.block ^ "\n" ^ indent body ^ ")\n"
            ^ finish (expression context joins tail join.value.action))
          dispatch targets
      in
      "(block " ^ done_label ^ " (result i64)\n" ^ indent body ^ ")"
  | Jump (name, arguments) ->
      let target =
        match Ids.find_opt name.value.id joins with
        | Some target -> target
        | None -> Diagnostic.fail source.span "invalid Wasm join target"
      in
      (* Stack all arguments before assigning any formal, preserving parallel moves. *)
      String.concat "\n"
        (List.map (atom context) arguments
        @ List.rev_map
            (fun name -> "(local.set " ^ variable name ^ ")")
            target.parameters
        @ List.map (root context) target.parameters
        @ [ "(br " ^ target.block ^ ")" ])
  | Switch (subject, arms, default) ->
      switch context joins tail subject arms default
  | Fail _ -> "unreachable"

and switch context joins tail subject arms default =
  let fallback = expression context joins tail default in
  match arms with
  | (Anf.Tag _, _) :: _ ->
      let tags =
        List.map
          (function
            | Anf.Tag tag, body -> (tag.Core.id, body) | _ -> assert false)
          arms
      in
      let ordered =
        List.sort (fun (left, _) (right, _) -> Int.compare left right) tags
      in
      let low = fst (List.hd ordered)
      and high = fst (List.hd (List.rev ordered)) in
      let discriminant = call "$rt_variant_tag" [ atom context subject ] in
      if Int64.sub (Int64.of_int high) (Int64.of_int low) <= 4095L then
        let done_label = label context "switch_done" in
        let default_label = label context "switch_default" in
        let targets =
          List.map (fun (tag, body) -> (tag, label context "case", body)) tags
        in
        let names =
          List.fold_left
            (fun map (tag, name, _) -> Ids.add tag name map)
            Ids.empty targets
        in
        let table =
          List.init
            (high - low + 1)
            (fun offset ->
              Option.value
                (Ids.find_opt (low + offset) names)
                ~default:default_label)
        in
        let dispatch =
          "(br_table "
          ^ String.concat " " (table @ [ default_label ])
          ^ " (i32.sub " ^ discriminant ^ " (i32.const " ^ string_of_int low
          ^ ")))"
        in
        let finish body =
          "(br " ^ done_label ^ " (block (result i64)\n" ^ indent body ^ "))"
        in
        let body =
          List.fold_left
            (fun body (_, target, action) ->
              "(block " ^ target ^ "\n" ^ indent body ^ ")\n"
              ^ finish (expression context joins tail action))
            dispatch targets
        in
        "(block " ^ done_label ^ " (result i64)\n"
        ^ indent
            ("(block " ^ default_label ^ "\n" ^ indent body ^ ")\n"
           ^ finish fallback)
        ^ ")"
      else
        let rec balanced = function
          | [] -> fallback
          | arms ->
              let middle = List.length arms / 2 in
              let pivot, action = List.nth arms middle in
              let left = List.filteri (fun i _ -> i < middle) arms in
              let right = List.filteri (fun i _ -> i > middle) arms in
              branch
                ("(i32.eq " ^ discriminant ^ " (i32.const "
               ^ string_of_int pivot ^ "))")
                (expression context joins tail action)
                (branch
                   ("(i32.lt_u " ^ discriminant ^ " (i32.const "
                  ^ string_of_int pivot ^ "))")
                   (balanced left) (balanced right))
        in
        balanced ordered
  | _ ->
      List.fold_right
        (fun (key, body) fallback ->
          let literal =
            match key with Anf.Constant literal -> literal | _ -> assert false
          in
          let left = atom context subject
          and right = atom context (Anf.Literal literal) in
          let condition =
            match literal with
            | Ast.String _ ->
                call "$rt_unbox_bool"
                  [ call "$rt_string_equal" [ left; right ] ]
            | _ -> "(i64.eq " ^ left ^ " " ^ right ^ ")"
          in
          branch condition (expression context joins tail body) fallback)
        arms fallback

and right_hand_side context joins tail (source : Closed.rhs) =
  let value = atom context in
  match source.value with
  | Alias atom -> value atom
  | Direct_call (index, environment, argument) ->
      invoke tail
        (fun environment argument _ ->
          "("
          ^ (if tail then "return_call" else "call")
          ^ " $fn" ^ string_of_int index ^ " " ^ environment ^ " " ^ argument
          ^ ")")
        (value environment) (value argument) None
  | Closure_call (callee, argument) ->
      invoke tail
        (fun environment argument code ->
          "("
          ^ (if tail then "return_call_indirect" else "call_indirect")
          ^ " (type $tern_function) " ^ environment ^ " " ^ argument ^ " "
          ^ Option.get code ^ ")")
        (call "$rt_closure_environment" [ value callee ])
        (value argument)
        (Some (call "$rt_closure_code" [ value callee ]))
  | Primitive (operator, arguments) -> primitive context operator arguments
  | Builtin_apply (Core.Print_int, argument) ->
      call "$rt_print_int" [ value argument ]
  | Builtin_apply (Print_string, argument) ->
      call "$rt_print_string" [ value argument ]
  | Block body ->
      "(block (result i64)\n"
      ^ indent (expression context joins tail body)
      ^ ")"
  | Environment fields -> allocation context "$rt_environment" fields
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
  | Tuple fields -> allocation context "$rt_tuple" fields
  | Field (subject, index) ->
      call "$rt_field_get"
        [ value subject; "(i32.const " ^ string_of_int index ^ ")" ]
  | Variant (tag, None) ->
      call "$rt_variant_nullary"
        [ "(i32.const " ^ string_of_int tag.value.id ^ ")" ]
  | Variant (tag, Some payload) ->
      call "$rt_variant"
        [ "(i32.const " ^ string_of_int tag.value.id ^ ")"; value payload ]
  | Payload subject -> call "$rt_variant_payload" [ value subject ]

let rec locals (source : Closed.expr) =
  match source.value with
  | Let (name, rhs, body) ->
      let inner =
        match rhs.value with Closed.Block body -> locals body | _ -> []
      in
      (name :: inner) @ locals body
  | If (_, yes, no) -> locals yes @ locals no
  | Joins (joins, body) ->
      List.concat_map
        (fun (join : Closed.join) ->
          join.value.parameters @ locals join.value.action)
        joins
      @ locals body
  | Switch (_, arms, default) ->
      List.concat_map (fun (_, body) -> locals body) arms @ locals default
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
    | Joins (joins, body) ->
        List.iter (fun (join : Closed.join) -> scan join.value.action) joins;
        scan body
    | Switch (_, arms, default) ->
        List.iter (fun (_, body) -> scan body) arms;
        scan default
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

let literal offset (text, index) =
  let size = (String.length text + 23) land -8 in
  let block = Bytes.make size '\000' in
  Bytes.set_int32_le block 0
    (Int32.logor (Int32.shift_left (Int32.of_int (String.length text)) 8) 4l);
  Bytes.blit_string text 0 block 16 (String.length text);
  let bytes =
    Bytes.to_seq block |> List.of_seq
    |> List.map (fun c -> Printf.sprintf "\\%02x" (Char.code c))
    |> String.concat ""
  in
  Printf.sprintf
    ";; UTF-8 literal %d: %d bytes\n\
     (data (i32.const %d) \"%s\")\n\
     (func $literal%d (result i64) (i64.const %d))"
    index (String.length text) offset bytes index offset

let frame_locals =
  "(local $frame i32)\n\
   (local $allocation i64)\n\
   (local $result i64)\n\
   (local $call_env i64)\n\
   (local $call_arg i64)\n\
   (local $call_code i32)\n"

let roots context offset names =
  context.roots <-
    List.mapi
      (fun index (name : Core.name) -> (name.value.id, index + offset))
      names
    |> List.to_seq |> Ids.of_seq;
  context.allocation_slot <- offset + List.length names

let enter context environment argument =
  "(local.set $frame "
  ^ call "$rt_frame_push"
      [
        "(i32.const " ^ string_of_int (context.allocation_slot + 1) ^ ")";
        environment;
        argument;
      ]
  ^ ")\n"

let leave = call "$rt_frame_pop" [ "(local.get $frame)" ]

let program (program : Closed.program) =
  try
    let context =
      {
        strings = [];
        division = false;
        remainder = false;
        next_label = 0;
        roots = Ids.empty;
        allocation_slot = 0;
      }
    in
    let source_name = source_names program in
    let functions =
      List.map
        (fun (definition : Closed.function_definition) ->
          let f = definition.value in
          let names = locals f.body in
          roots context 0 (f.environment :: f.parameter :: names);
          let body = expression context Ids.empty true f.body in
          let declarations = declarations names in
          let name = source_name f.name in
          Printf.sprintf
            ";; source function %s#%d (code %d)\n\
             (func $fn%d (type $tern_function) (param %s i64) (param %s i64) \
             (result i64)\n\
             %s\n\
             )"
            name.value.spelling name.value.id f.index f.index
            (variable f.environment) (variable f.parameter)
            (indent
               (frame_locals ^ declarations ^ "\n"
               ^ enter context
                   ("(local.get " ^ variable f.environment ^ ")")
                   ("(local.get " ^ variable f.parameter ^ ")")
               ^ "(local.set $result (block (result i64)\n" ^ indent body
               ^ "))\n" ^ leave ^ "\n(local.get $result)")))
        program.value.functions
    in
    let names =
      List.map fst program.value.builtins @ locals program.value.body
    in
    roots context 2 names;
    let body = expression context Ids.empty false program.value.body in
    let initialization =
      List.map
        (fun ((name : Core.name), index) ->
          "(local.set " ^ variable name ^ " "
          ^ call "$rt_closure"
              [
                "(i32.const " ^ string_of_int index ^ ")";
                call "$rt_environment" [ "(i32.const 0)" ];
              ]
          ^ ")\n" ^ root context name)
        program.value.builtins
    in
    let entry =
      "(func (export \"_start\")\n"
      ^ indent
          (frame_locals ^ declarations names ^ "\n"
          ^ enter context "(i64.const 3)" "(i64.const 3)"
          ^ String.concat "\n" initialization
          ^ "\n(drop (block (result i64)\n" ^ indent body ^ "))\n" ^ leave)
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
    let table =
      "(table $functions "
      ^ string_of_int (List.length program.value.functions)
      ^ " funcref)\n" ^ "(elem (i32.const 0) "
      ^ String.concat " "
          (List.map
             (fun (f : Closed.function_definition) ->
               "$fn" ^ string_of_int f.value.index)
             program.value.functions)
      ^ ")"
    in
    let base, literals =
      List.fold_left
        (fun (offset, literals) ((text, _) as value) ->
          if String.length text > 16777215 then
            Diagnostic.fail program.span
              "string literal exceeds the runtime size limit";
          let next = offset + ((String.length text + 23) land -8) in
          if next > 67108864 then
            Diagnostic.fail program.span
              "static literals exceed the linear-memory limit";
          (next, literal offset value :: literals))
        (4096, []) context.strings
    in
    let runtime =
      String.split_on_char '\n' (String.trim Runtime_assets.wat)
      |> List.map (fun line ->
          if String.starts_with ~prefix:"  (global $heap " line then
            Printf.sprintf "  (global $heap (mut i32) (i32.const %d))" base
          else if String.starts_with ~prefix:"  (global $heap_base " line then
            Printf.sprintf
              "  (global $heap_base (export \"rt_heap_base\") i32 (i32.const \
               %d))"
              base
          else if String.starts_with ~prefix:"  (memory " line then
            Printf.sprintf "  (memory (export \"memory\") %d 1024)"
              ((base + 65535) / 65536)
          else line)
      |> String.concat "\n"
    in
    Ok
      (String.sub runtime 0 (String.length runtime - 1)
      ^ "\n"
      ^ String.concat "\n\n"
          ([ table ] @ arithmetic @ List.rev literals @ functions @ [ entry ])
      ^ "\n)\n")
  with Diagnostic.Raised diagnostic -> Error diagnostic
