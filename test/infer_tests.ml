open Tern

let infer source = Check.source ~file:"types.tern" source

let check source =
  match infer source with
  | Ok result -> print_string (Infer.format_bindings result)
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let reject ~at source =
  match infer source with
  | Ok _ -> failwith "expected a type error"
  | Error diagnostic ->
      assert (diagnostic.severity = Diagnostic.Error);
      let span = diagnostic.primary in
      assert (String.sub source span.start_pos.byte_offset
                (span.end_pos.byte_offset - span.start_pos.byte_offset) = at);
      print_endline diagnostic.message

let render_error source =
  match infer source with
  | Ok _ -> failwith "expected a type error"
  | Error diagnostic ->
      print_string
        (Diagnostic.render
           ~source:(fun file -> if file = "types.tern" then Some source else None)
           diagnostic)

let%expect_test "01 one polymorphic identity is used at two types" =
  check "let id x = x;; let pair = (id 1, id true);;";
  [%expect
    {|
    val id : 'a -> 'a
    val pair : int * bool
    |}]

let%expect_test "02 constant" =
  check "let const x y = x;;";
  [%expect {| val const : 'a -> 'b -> 'a |}]

let%expect_test "03 composition" =
  check "let compose f g x = f (g x);;";
  [%expect {| val compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b |}]

let%expect_test "04 first-class application" =
  check "let apply f x = f x;;";
  [%expect {| val apply : ('a -> 'b) -> 'a -> 'b |}]

let%expect_test "05 tuple parameter and swapped result" =
  check "let swap (x, y) = (y, x);;";
  [%expect {| val swap : 'a * 'b -> 'b * 'a |}]

let%expect_test "06 local identity is generalized" =
  check "let pair = let id x = x in (id 1, id true);;";
  [%expect {| val pair : int * bool |}]

let%expect_test "07 an alias of an outer argument stays monomorphic" =
  check "let f x = let y = x in y;;";
  [%expect {| val f : 'a -> 'a |}]

let%expect_test "08 only the local function's independent argument is generalized" =
  check "let f x = let g y = x in g;;";
  [%expect {| val f : 'a -> 'b -> 'a |}]

let%expect_test "09 exported local variables are lowered to the outer level" =
  check "let f x = let g y = x y in g;;";
  [%expect {| val f : ('a -> 'b) -> 'a -> 'b |}]

let%expect_test "10 instantiation permits identity applied to itself" =
  check "let id x = x;; let self = id id;;";
  [%expect
    {|
    val id : 'a -> 'a
    val self : 'a -> 'a
    |}]

let%expect_test "11 no value restriction on a closed application RHS" =
  check "let id = (fun f -> f) (fun x -> x);; let pair = (id 1, id true);;";
  [%expect
    {|
    val id : 'a -> 'a
    val pair : int * bool
    |}]

let%expect_test "12 shadowed bindings keep their own schemes" =
  check "let id x = x;; let old = id true;; let id x = x + 1;; let now = id 1;;";
  [%expect
    {|
    val id : 'a -> 'a
    val old : bool
    val id : int -> int
    val now : int
    |}]

let%expect_test "13 factorial" =
  check "let rec factorial n = if n = 0 then 1 else n * factorial (n - 1);;";
  [%expect {| val factorial : int -> int |}]

let%expect_test "14 recursive identity is generalized after its body" =
  check "let rec id x = x;; let pair = (id 1, id true);;";
  [%expect
    {|
    val id : 'a -> 'a
    val pair : int * bool
    |}]

let%expect_test "15 mutually recursive predicates" =
  check "let rec even n = if n = 0 then true else odd (n - 1) and odd n = if n = 0 then false else even (n - 1);;";
  [%expect
    {|
    val even : int -> bool
    val odd : int -> bool
    |}]

let%expect_test "16 mutual group generalization happens after every body" =
  check "let rec f x = g x and g y = y;; let pair = (f 1, g true);;";
  [%expect
    {|
    val f : 'a -> 'a
    val g : 'a -> 'a
    val pair : int * bool
    |}]

let%expect_test "17 each binder in a closed tuple let is polymorphic" =
  check "let (f, g) = ((fun x -> x), (fun y -> y));; let uses = (f 1, f true, g \"s\", g 2);;";
  [%expect
    {|
    val f : 'a -> 'a
    val g : 'a -> 'a
    val uses : int * bool * string * int
    |}]

let%expect_test "18 unit and wildcard parameters" =
  check "let ignore _ = ();; let tick () = 42;;";
  [%expect
    {|
    val ignore : 'a -> unit
    val tick : unit -> int
    |}]

let%expect_test "19 built-in output and unit sequencing" =
  check {|let output n = print_int n; print_string "\n";;|};
  [%expect {| val output : int -> unit |}]

let%expect_test "20 string concatenation" =
  check {|let greet name = "hello " ^ name;;|};
  [%expect {| val greet : string -> string |}]

let%expect_test "21 boolean short-circuit desugaring enforces boolean operands" =
  check "let both x y = x && y;; let either x y = x || y;;";
  [%expect
    {|
    val both : bool -> bool -> bool
    val either : bool -> bool -> bool
    |}]

let%expect_test "22 polymorphic option constructors" =
  check "type 'a option = None | Some of 'a;; let none = None;; let some = Some;; let pair = (Some 1, Some true);;";
  [%expect
    {|
    val none : 'a option
    val some : 'a -> 'a option
    val pair : int option * bool option
    |}]

let%expect_test "23 map over an option" =
  check "type 'a option = None | Some of 'a;; let map f value = match value with None -> None | Some x -> Some (f x);;";
  [%expect {| val map : ('a -> 'b) -> 'a option -> 'b option |}]

let%expect_test "24 recursive list length, map, and fold" =
  check
    "type 'a list = Nil | Cons of ('a * 'a list);;\n\
     let rec length xs = match xs with Nil -> 0 | Cons (_, rest) -> 1 + length rest;;\n\
     let rec map f xs = match xs with Nil -> Nil | Cons (x, rest) -> Cons (f x, map f rest);;\n\
     let rec fold f acc xs = match xs with Nil -> acc | Cons (x, rest) -> fold f (f acc x) rest;;";
  [%expect
    {|
    val length : 'a list -> int
    val map : ('a -> 'b) -> 'a list -> 'b list
    val fold : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a
    |}]

let%expect_test "25 two-parameter nominal constructors" =
  check "type ('a, 'b) result = Ok of 'a | Error of 'b;; let ok = Ok;; let error = Error;;";
  [%expect
    {|
    val ok : 'a -> ('a, 'b) result
    val error : 'a -> ('b, 'a) result
    |}]

let%expect_test "26 value and primitive type namespaces stay separate" =
  check "type box = Box of int;; let int = 1;; let box = Box int;;";
  [%expect
    {|
    val int : int
    val box : box
    |}]

let%expect_test "27 a conditional returning identity functions" =
  check "let choose b = if b then (fun x -> x) else (fun y -> y);;";
  [%expect {| val choose : bool -> 'a -> 'a |}]

let%expect_test "28 constructors are first-class function arguments" =
  check "type 'a option = None | Some of 'a;; let make f x = f x;; let some = make Some 1;;";
  [%expect
    {|
    val make : ('a -> 'b) -> 'a -> 'b
    val some : int option
    |}]

let%expect_test "29 a nominal wrapper cannot generalize an outer variable" =
  check "type 'a box = Box of 'a;; let wrap x = let box = Box x in box;;";
  [%expect {| val wrap : 'a -> 'a box |}]

let%expect_test "30 a recursive local closure keeps its outer argument" =
  check "let outer x = let rec f y = if y then x else f true in f;;";
  [%expect {| val outer : 'a -> bool -> 'a |}]

let%expect_test "31 tuple generalization separates captured and independent components" =
  check "let f x = let (a, b) = (x, fun y -> y) in (a, b 1, b true);;";
  [%expect {| val f : 'a -> 'a * int * bool |}]

let%expect_test "32 no value restriction on a closed conditional RHS" =
  check "let id = if true then (fun x -> x) else (fun y -> y);; let pair = (id 1, id true);;";
  [%expect
    {|
    val id : 'a -> 'a
    val pair : int * bool
    |}]

let%expect_test "33 shadowing a built-in does not retain its old type" =
  check {|let print_int x = x;; let pair = (print_int true, print_int "yes");;|};
  [%expect
    {|
    val print_int : 'a -> 'a
    val pair : bool * string
    |}]

let%expect_test "34 infinite type at the self-application argument" =
  render_error "let omega x = x x;;";
  [%expect
    {|
    error: infinite type: expected 'a, but got 'a -> 'b
     --> types.tern:1:17
      |
    1 | let omega x = x x;;
      |                 ^
     = note: occurs check: a type variable would contain itself
    |}]

let%expect_test "35 primitive mismatch points at the responsible operand" =
  render_error "let bad = 1 + true;;";
  [%expect
    {|
    error: type mismatch: expected int, but got bool
     --> types.tern:1:15
      |
    1 | let bad = 1 + true;;
      |               ^^^^
    |}]

let%expect_test "36 branch mismatch points at the conflicting branch" =
  render_error "let bad = if true then 1 else false;;";
  [%expect
    {|
    error: type mismatch: expected int, but got bool
     --> types.tern:1:31
      |
    1 | let bad = if true then 1 else false;;
      |                               ^^^^^
    |}]

let%expect_test "37 the if condition must be boolean" =
  reject ~at:"0" "let bad = if 0 then true else false;;";
  [%expect {| type mismatch: expected bool, but got int |}]

let%expect_test "38 a literal cannot be called" =
  reject ~at:"1" "let bad = 1 true;;";
  [%expect {| type mismatch: expected 'a -> 'b, but got int |}]

let%expect_test "39 lambda parameters cannot be used polymorphically" =
  reject ~at:"true" "let bad f = (f 1, f true);;";
  [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "40 an alias cannot generalize a variable owned by an outer lambda" =
  reject ~at:"true" "let bad x = let y = x in (y 1, y true);;";
  [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "41 unification lowers variables exported by a local function" =
  reject ~at:"true" "let bad f = let g x = f x in (g 1, g true);;";
  [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "42 tuple lambda components remain monomorphic" =
  reject ~at:"true" "let bad (f, g) = (f 1, f true);;";
  [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "43 sequencing still requires unit after desugaring" =
  reject ~at:"1" "let bad = 1; ();;";
  [%expect {| type mismatch: expected unit, but got int |}]

let%expect_test "44 an explicit unit binding also requires unit" =
  reject ~at:"1" "let () = 1;;";
  [%expect {| type mismatch: expected unit, but got int |}]

let%expect_test "45 tuple arities must agree" =
  reject ~at:"(1, true, \"x\")" "let (a, b) = (1, true, \"x\");;";
  [%expect {| type mismatch: expected 'a * 'b, but got int * bool * string |}]

let%expect_test "46 distinct variant types are nominal, not structural" =
  reject ~at:"B" "type a = A;; type b = B;; let bad = if true then A else B;;";
  [%expect {| type mismatch: expected a, but got b |}]

let%expect_test "47 constructor payload patterns impose types" =
  reject ~at:"Some 0"
    "type 'a option = None | Some of 'a;; let bad = match Some true with Some 0 -> 0 | None -> 0;;";
  [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "48 recursive uses stay monomorphic until the group ends" =
  reject ~at:"true" "let rec bad x = if false then () else (bad 1; bad true);;";
  [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "49 output built-ins have concrete argument types" =
  reject ~at:"true" "let bad = print_int true;;";
  reject ~at:"1" "let bad = print_string 1;;";
  [%expect
    {|
    type mismatch: expected int, but got bool
    type mismatch: expected string, but got int
    |}]

let%expect_test "50 integer-only equality is not accidentally polymorphic" =
  reject ~at:"true" "let bad = true = false;;";
  [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "51 a diverging recursive function need not have a cyclic type" =
  check "let rec loop x = loop x;;";
  [%expect {| val loop : 'a -> 'b |}]

let%expect_test "52 nonliteral unary negation has an integer signature" =
  check "let negate x = -x;;";
  reject ~at:"true" "let bad = -true;;";
  [%expect
    {|
    val negate : int -> int
    type mismatch: expected int, but got bool
    |}]

let%expect_test "53 every member of a recursive group is generalized" =
  check "let rec f x = 0 and g y = y;; let uses = (f true, f \"s\", g 1, g false);;";
  [%expect
    {|
    val f : 'a -> int
    val g : 'a -> 'a
    val uses : int * int * int * bool
    |}]

let%expect_test "54 boolean operand errors do not point at synthetic branches" =
  reject ~at:"1" "let bad = true && 1;;";
  reject ~at:"1" "let bad = false || 1;;";
  [%expect
    {|
    type mismatch: expected bool, but got int
    type mismatch: expected bool, but got int
    |}]

let%expect_test "match-bound variables are monomorphic, unlike pattern-let variables" =
  reject ~at:"true"
    "let id x = x;; let bad = match (id, id) with (f, g) -> (f 1, f true);;";
  [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "mutual group members are not generalized one body too early" =
  reject ~at:"y = if y then true else false"
    "let rec f x = g 1 and g y = if y then true else false;;";
  [%expect {| type mismatch: expected int -> 'a, but got bool -> bool |}]

let%expect_test "all example programs type-check with a unit program result" =
  let directory = "../examples" in
  let files =
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun file -> Filename.extension file = ".tern")
    |> List.sort String.compare
  in
  assert (List.length files = 15);
  List.iter
    (fun file ->
      let source = In_channel.with_open_bin (Filename.concat directory file) In_channel.input_all in
      match infer source with
      | Error diagnostic -> failwith (Diagnostic.show diagnostic)
      | Ok result ->
          assert (Ty.show result.body_type = "unit");
          Printf.printf "%s: type-checks\n" file)
    files;
  [%expect
    {|
    01_hello.tern: type-checks
    02_arithmetic.tern: type-checks
    03_booleans.tern: type-checks
    04_strings.tern: type-checks
    05_unit_and_sequence.tern: type-checks
    06_let_and_shadowing.tern: type-checks
    07_factorial.tern: type-checks
    08_mutual_recursion.tern: type-checks
    09_closures.tern: type-checks
    10_higher_order.tern: type-checks
    11_polymorphic_tuples.tern: type-checks
    12_options.tern: type-checks
    13_nested_patterns.tern: type-checks
    14_variant_tree.tern: type-checks
    15_list_library.tern: type-checks
    |}]
