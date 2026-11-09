open Tern

let parse source =
  match Parse.program ~file:"resolve.tern" source with
  | Ok program -> program
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let resolve source =
  match Resolve.program (parse source) with
  | Ok program -> program
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let name (name : Core.name) =
  Printf.sprintf "%s#%d" name.value.spelling name.value.id

let rec pattern (pat : Core.pattern) =
  match pat.value with
  | Wildcard -> "_"
  | Bind binder -> name binder
  | Literal_pattern value -> Pretty.literal value
  | Tuple_pattern fields ->
      "(" ^ String.concat ", " (List.map pattern fields) ^ ")"
  | Constructor_pattern (constructor, None) -> name constructor
  | Constructor_pattern (constructor, Some payload) ->
      name constructor ^ "(" ^ pattern payload ^ ")"

let rec expression (expr : Core.expr) =
  match expr.value with
  | Literal value -> Pretty.literal value
  | Variable variable -> name variable
  | Constructor constructor -> "ctor[" ^ name constructor ^ "]"
  | Lambda (parameter, body) ->
      "(fun " ^ name parameter ^ " -> " ^ expression body ^ ")"
  | Apply (callee, argument) ->
      "(" ^ expression callee ^ " " ^ expression argument ^ ")"
  | Let (pat, rhs, body) ->
      "(let " ^ pattern pat ^ " = " ^ expression rhs ^ " in " ^ expression body
      ^ ")"
  | Let_rec (bindings, body) ->
      "(let rec "
      ^ String.concat " and " (List.map recursive_binding bindings)
      ^ " in " ^ expression body ^ ")"
  | If (condition, yes, no) ->
      "(if " ^ expression condition ^ " then " ^ expression yes ^ " else "
      ^ expression no ^ ")"
  | Tuple fields -> "(" ^ String.concat ", " (List.map expression fields) ^ ")"
  | Match (subject, cases) ->
      "(match " ^ expression subject ^ " with "
      ^ String.concat " "
          (List.map
             (fun (case : Core.case) ->
               "| "
               ^ pattern case.value.case_pattern
               ^ " -> "
               ^ expression case.value.case_body)
             cases)
      ^ ")"
  | Primitive (primitive, operands) ->
      "("
      ^ Core.show_primitive primitive.value
      ^ " "
      ^ String.concat " " (List.map expression operands)
      ^ ")"

and recursive_binding (binding : Core.recursive_binding) =
  name binding.value.recursive_name
  ^ " = "
  ^ expression binding.value.recursive_body

let dump source =
  let program = resolve source in
  let rec bindings (expr : Core.expr) =
    match expr.value with
    | Let (pat, rhs, body) ->
        Printf.printf "let %s = %s\n" (pattern pat) (expression rhs);
        bindings body
    | Let_rec (group, body) ->
        Printf.printf "let rec %s\n"
          (String.concat " and " (List.map recursive_binding group));
        bindings body
    | Literal Ast.Unit -> ()
    | _ -> assert false
  in
  bindings program.value.body

let error source =
  match Resolve.program (parse source) with
  | Ok _ -> failwith "expected a resolution error"
  | Error diagnostic ->
      assert (diagnostic.severity = Diagnostic.Error);
      print_string
        (Diagnostic.render
           ~source:(fun file ->
             if file = "resolve.tern" then Some source else None)
           diagnostic)

let message source =
  match Resolve.program (parse source) with
  | Ok _ -> failwith "expected a resolution error"
  | Error diagnostic -> print_endline diagnostic.message

module Ids = Set.Make (Int)

let verify (program : Core.program) =
  let definitions = ref Ids.empty in
  let bind (name : Core.name) =
    assert (not (Ids.mem name.value.id !definitions));
    definitions := Ids.add name.value.id !definitions;
    name.value.id
  in
  let value_environment =
    List.fold_left
      (fun ids (name, _) -> Ids.add (bind name) ids)
      Ids.empty program.value.builtins
  in
  let type_environment =
    List.fold_left
      (fun ids (name, _) -> Ids.add (bind name) ids)
      Ids.empty program.value.builtin_types
  in
  let constructors = ref Ids.empty in
  let rec typ parameters types (source_type : Core.type_expr) =
    match source_type.value with
    | Type_variable name -> assert (Ids.mem name.value.id parameters)
    | Type_constructor (name, arguments) ->
        assert (Ids.mem name.value.id types);
        List.iter (typ parameters types) arguments
    | Type_arrow (argument, result) ->
        typ parameters types argument;
        typ parameters types result
    | Type_tuple fields -> List.iter (typ parameters types) fields
  in
  ignore
    (List.fold_left
       (fun types (declaration : Core.type_decl) ->
         let definition = declaration.value in
         let types = Ids.add (bind definition.type_name) types in
         let parameters =
           List.fold_left
             (fun ids name -> Ids.add (bind name) ids)
             Ids.empty definition.type_parameters
         in
         List.iter
           (fun (constructor : Core.constructor_decl) ->
             constructors :=
               Ids.add (bind constructor.value.constructor_name) !constructors;
             Option.iter (typ parameters types)
               constructor.value.constructor_payload)
           definition.type_constructors;
         types)
       type_environment program.value.types);
  let rec pat ids (pattern : Core.pattern) =
    match pattern.value with
    | Wildcard | Literal_pattern _ -> ids
    | Bind name -> Ids.add (bind name) ids
    | Tuple_pattern fields -> List.fold_left pat ids fields
    | Constructor_pattern (name, payload) -> (
        assert (Ids.mem name.value.id !constructors);
        match payload with None -> ids | Some payload -> pat ids payload)
  in
  let rec expr environment (expression : Core.expr) =
    match expression.value with
    | Literal _ -> ()
    | Variable name -> assert (Ids.mem name.value.id environment)
    | Constructor name -> assert (Ids.mem name.value.id !constructors)
    | Lambda (name, body) -> expr (Ids.add (bind name) environment) body
    | Apply (callee, argument) ->
        expr environment callee;
        expr environment argument
    | Let (pattern, rhs, body) ->
        expr environment rhs;
        expr (pat environment pattern) body
    | Let_rec (bindings, body) ->
        let environment =
          List.fold_left
            (fun ids (binding : Core.recursive_binding) ->
              Ids.add (bind binding.value.recursive_name) ids)
            environment bindings
        in
        List.iter
          (fun (binding : Core.recursive_binding) ->
            (match binding.value.recursive_body.value with
            | Lambda _ -> ()
            | _ -> assert false);
            expr environment binding.value.recursive_body)
          bindings;
        expr environment body
    | If (condition, yes, no) ->
        expr environment condition;
        expr environment yes;
        expr environment no
    | Tuple fields -> List.iter (expr environment) fields
    | Match (subject, cases) ->
        expr environment subject;
        List.iter
          (fun (case : Core.case) ->
            expr (pat environment case.value.case_pattern) case.value.case_body)
          cases
    | Primitive (operator, operands) ->
        assert (
          List.length operands
          = match operator.value with Negate -> 1 | _ -> 2);
        List.iter (expr environment) operands
  in
  expr value_environment program.value.body;
  let count = Ids.cardinal !definitions in
  assert (program.value.next_id = count);
  assert (Ids.equal !definitions (Ids.of_list (List.init count Fun.id)));
  count

let%expect_test "shadowing, closures, and nonrecursive right-hand sides" =
  dump "let x = 1;; let f y = x + y;; let x = 2;; let z = f x;;";
  dump "let x = 1;; let x = x + 1;;";
  [%expect
    {|
    let x#6 = 1
    let f#7 = (fun y#8 -> (Add x#6 y#8))
    let x#9 = 2
    let z#10 = (f#7 x#9)
    let x#6 = 1
    let x#7 = (Add x#6 1)
    |}]

let%expect_test
    "self recursion, local recursion, and shadowing a recursive name" =
  dump "let rec f n = if n = 0 then 1 else f (n - 1);;";
  dump "let f = let rec go x = go x in go;;";
  dump "let rec f f = f;;";
  [%expect
    {|
    let rec f#6 = (fun n#7 -> (if (Equal n#7 0) then 1 else (f#6 (Subtract n#7 1))))
    let f#6 = (let rec go#7 = (fun x#8 -> (go#7 x#8)) in go#7)
    let rec f#6 = (fun f#7 -> f#7)
    |}]

let%expect_test
    "tuple bindings read the outer scope before introducing all new names" =
  dump "let x = 1;; let (x, y) = (x, 2);; let z = x + y;;";
  [%expect
    {|
    let x#6 = 1
    let (x#7, y#8) = (x#6, 2)
    let z#9 = (Add x#7 y#8)
    |}]

let%expect_test "mutual names are all allocated before either function body" =
  dump "let rec f x = g x and g y = f y;; let call = f 1;;";
  [%expect
    {|
    let rec f#6 = (fun x#8 -> (g#7 x#8)) and g#7 = (fun y#9 -> (f#6 y#9))
    let call#10 = (f#6 1)
    |}]

let%expect_test
    "multi-argument and pattern functions lower to unary binder lambdas" =
  dump "let f x y = x;;";
  dump "let f (x, y) () _ = x;;";
  [%expect
    {|
    let f#6 = (fun x#7 -> (fun y#8 -> x#7))
    let f#6 = (fun $arg#7 -> (let (x#8, y#9) = $arg#7 in (fun $arg#10 -> (let () = $arg#10 in (fun $arg#11 -> x#8)))))
    |}]

let%expect_test
    "sequencing retains its unit constraint and booleans short-circuit" =
  dump {|let x = print_int 1; print_string "x";;|};
  dump "let f x = x;; let a = false && f true;; let b = true || f false;;";
  [%expect
    {|
    let x#6 = (let () = (print_int#0 1) in (print_string#1 "x"))
    let f#6 = (fun x#7 -> x#7)
    let a#8 = (if false then (if (f#6 true) then true else false) else false)
    let b#9 = (if true then true else (if (f#6 false) then true else false))
    |}]

let%expect_test "prelude identities are stable and built-ins can be shadowed" =
  dump "let print_int = print_int;; let x = print_int;;";
  let program = resolve "" in
  print_endline
    (String.concat ", "
       (List.map (fun (binder, _) -> name binder) program.value.builtins));
  print_endline
    (String.concat ", "
       (List.map (fun (binder, _) -> name binder) program.value.builtin_types));
  [%expect
    {|
    let print_int#6 = print_int#0
    let x#7 = print_int#6
    print_int#0, print_string#1
    int#2, bool#3, string#4, unit#5
    |}]

let%expect_test
    "type parameters, first-class constructors, and match arms have IDs" =
  let source =
    "type 'a option = None | Some of 'a;; let f = Some;; let g x = match x \
     with Some y -> y | None -> 0;;"
  in
  let program = resolve source in
  (match program.value.types with
  | [ definition ] ->
      Printf.printf "type %s parameters=%s constructors=%s\n"
        (name definition.value.type_name)
        (String.concat "," (List.map name definition.value.type_parameters))
        (String.concat ","
           (List.map
              (fun (c : Core.constructor_decl) -> name c.value.constructor_name)
              definition.value.type_constructors))
  | _ -> assert false);
  dump source;
  ignore (verify program);
  [%expect
    {|
    type option#6 parameters=a#7 constructors=None#8,Some#9
    let f#10 = ctor[Some#9]
    let g#11 = (fun x#12 -> (match x#12 with | Some#9(y#13) -> y#13 | None#8 -> 0))
    |}]

let%expect_test
    "recursive payload types point back to their own nominal type ID" =
  let program = resolve "type 'a list = Nil | Cons of ('a * 'a list);;" in
  ignore (verify program);
  (match program.value.types with
  | [
   {
     value =
       {
         type_name;
         type_parameters = [ parameter ];
         type_constructors = [ _; cons ];
       };
     _;
   };
  ] -> (
      match cons.value.constructor_payload with
      | Some
          {
            value =
              Type_tuple
                [ first; { value = Type_constructor (self, [ argument ]); _ } ];
            _;
          } ->
          assert (self.value.id = type_name.value.id);
          List.iter
            (fun (typ : Core.type_expr) ->
              match typ.value with
              | Type_variable name ->
                  assert (name.value.id = parameter.value.id)
              | _ -> assert false)
            [ first; argument ];
          print_endline "recursive type and parameter identities preserved"
      | _ -> assert false)
  | _ -> assert false);
  [%expect {| recursive type and parameter identities preserved |}]

let%expect_test
    "value and type namespaces are separate even for primitive type spellings" =
  let program = resolve "let int = 1;; type box = Box of int;;" in
  ignore (verify program);
  (match (program.value.body.value, program.value.types) with
  | Let ({ value = Bind value; _ }, _, _), [ definition ] -> (
      match definition.value.type_constructors with
      | [
       {
         value =
           {
             constructor_payload =
               Some { value = Type_constructor (typ, []); _ };
             _;
           };
         _;
       };
      ] ->
          Printf.printf "value %s; payload type %s\n" (name value) (name typ)
      | _ -> assert false)
  | _ -> assert false);
  [%expect {| value int#6; payload type int#2 |}]

let%expect_test "unbound value diagnostic" =
  error "let result = missing;;";
  [%expect
    {|
    error: unbound variable `missing`
     --> resolve.tern:1:14
      |
    1 | let result = missing;;
      |              ^^^^^^^
    |}]

let%expect_test "unbound constructor diagnostic" =
  error "let x = Missing;;";
  [%expect
    {|
    error: unbound constructor `Missing`
     --> resolve.tern:1:9
      |
    1 | let x = Missing;;
      |         ^^^^^^^
    |}]

let%expect_test "duplicate pattern variables retain both binding locations" =
  error "let (x, x) = (1, 2);;";
  [%expect
    {|
    error: duplicate pattern variable `x`
     --> resolve.tern:1:9
      |
    1 | let (x, x) = (1, 2);;
      |         ^
     ::: resolve.tern:1:6
      |
    1 | let (x, x) = (1, 2);;
      |      - previous pattern variable declaration
    |}]

let%expect_test "duplicate type names retain both declaration locations" =
  error "type t = A;;\ntype t = B;;";
  [%expect
    {|
    error: duplicate type name `t`
     --> resolve.tern:2:6
      |
    2 | type t = B;;
      |      ^
     ::: resolve.tern:1:6
      |
    1 | type t = A;;
      |      - previous type name declaration
    |}]

let%expect_test "duplicate constructors retain both declaration locations" =
  error "type a = C;;\ntype b = C;;";
  [%expect
    {|
    error: duplicate constructor name `C`
     --> resolve.tern:2:10
      |
    2 | type b = C;;
      |          ^
     ::: resolve.tern:1:10
      |
    1 | type a = C;;
      |          - previous constructor name declaration
    |}]

let%expect_test
    "names do not leak into nonrecursive RHSs, other arms, or earlier \
     declarations" =
  List.iter message
    [
      "let x = x;;";
      "let f x = g x;; let g y = y;;";
      "let x = C;; type t = C;;";
      "let f x = match x with Missing -> x;;";
      "type 'a option = None | Some of 'a;; let f x = match x with Some y -> y \
       | None -> y;;";
      "let x = false && missing;;";
    ];
  [%expect
    {|
    unbound variable `x`
    unbound variable `g`
    unbound constructor `C`
    unbound constructor `Missing`
    unbound variable `y`
    unbound variable `missing`
    |}]

let%expect_test
    "duplicate binders in nested patterns and recursive groups are errors" =
  List.iter message
    [
      "let f (x, (y, x)) = y;;";
      "type 'a option = None | Some of 'a;; let f x = match x with Some (a, a) \
       -> a | None -> 0;;";
      "let rec f x = x and f y = y;;";
      "type t = A | A;;";
      "type ('a, 'a) t = C;;";
      "type int = C;;";
    ];
  [%expect
    {|
    duplicate pattern variable `x`
    duplicate pattern variable `a`
    duplicate recursive binding `f`
    duplicate constructor name `A`
    duplicate type parameter `a`
    duplicate type name `int`
    |}]

let%expect_test "type references and constructor pattern arities are checked" =
  List.iter message
    [
      "type t = T of missing;;";
      "type 'a t = T of 'b;;";
      "type t = T of later;; type later = L;;";
      "type 'a option = None | Some of 'a;; type t = T of (int, bool) option;;";
      "type 'a option = None | Some of 'a;; let f x = match x with Some -> 0 | \
       None -> 1;;";
      "type 'a option = None | Some of 'a;; let f x = match x with None _ -> 0 \
       | Some _ -> 1;;";
    ];
  [%expect
    {|
    unbound type `missing`
    unbound type variable `b`
    unbound type `later`
    type `option` expects 1 type argument, but got 2
    constructor `Some` expects a payload pattern
    constructor `None` has no payload
    |}]

let%expect_test "separate lambda parameters and match arms may shadow names" =
  dump "let f x x = x;; let g x = match x with y -> y | y -> y;;";
  [%expect
    {|
    let f#6 = (fun x#7 -> (fun x#8 -> x#8))
    let g#9 = (fun x#10 -> (match x#10 with | y#11 -> y#11 | y#12 -> y#12))
    |}]

let%expect_test
    "failed and repeated invocations never leak the identity counter" =
  let source = "let f (x, y) = x + y;;" in
  let first = resolve source in
  (match Resolve.program (parse "let x = missing;;") with
  | Error _ -> ()
  | Ok _ -> assert false);
  let second = resolve source in
  assert (Core.equal_program first second);
  assert (String.length (Core.show_program first) > 0);
  Printf.printf
    "deterministic Core; %d globally unique binders; derived printers available\n"
    (verify first);
  [%expect
    {| deterministic Core; 10 globally unique binders; derived printers available |}]

let%expect_test
    "all examples resolve, retain scopes, and have unique bound identities" =
  let directory = "../examples" in
  let files =
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun name -> Filename.extension name = ".tern")
    |> List.sort String.compare
  in
  assert (List.length files = 16);
  List.iter
    (fun file ->
      let source =
        In_channel.with_open_bin
          (Filename.concat directory file)
          In_channel.input_all
      in
      let parsed = parse source in
      let resolved = resolve source in
      ignore (verify resolved);
      assert (Core.equal_program resolved (resolve (Pretty.program parsed)));
      Printf.printf "%s: resolved and Core identities verified\n" file)
    files;
  [%expect
    {|
    01_hello.tern: resolved and Core identities verified
    02_arithmetic.tern: resolved and Core identities verified
    03_booleans.tern: resolved and Core identities verified
    04_strings.tern: resolved and Core identities verified
    05_unit_and_sequence.tern: resolved and Core identities verified
    06_let_and_shadowing.tern: resolved and Core identities verified
    07_factorial.tern: resolved and Core identities verified
    08_mutual_recursion.tern: resolved and Core identities verified
    09_closures.tern: resolved and Core identities verified
    10_higher_order.tern: resolved and Core identities verified
    11_polymorphic_tuples.tern: resolved and Core identities verified
    12_options.tern: resolved and Core identities verified
    13_nested_patterns.tern: resolved and Core identities verified
    14_variant_tree.tern: resolved and Core identities verified
    15_list_library.tern: resolved and Core identities verified
    interpreter.tern: resolved and Core identities verified
    |}]
