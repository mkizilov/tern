open Tern

let int_type = Ty.Constructor ({ Core.id = 2; spelling = "int" }, [])
let unit_type = Ty.Constructor ({ Core.id = 5; spelling = "unit" }, [])

let%expect_test
    "unification lowers a young variable that escapes through an older one" =
  let context = Ty.create () in
  let old = Ty.fresh context 0 in
  let young = Ty.fresh context 1 in
  Ty.unify old (Ty.Arrow (young, unit_type));
  (match Ty.repr young with
  | Variable { contents = Unbound (_, level) } ->
      Printf.printf "level=%d\n" level
  | _ -> assert false);
  Ty.generalize 0 old;
  let instance = Ty.instantiate context 0 old in
  Ty.unify young int_type;
  print_endline (Ty.show instance);
  [%expect {|
    level=0
    int -> unit
    |}]

let%expect_test
    "generic instances are fresh but preserve sharing within one instance" =
  let context = Ty.create () in
  let variable = Ty.fresh context 1 in
  let scheme = Ty.Arrow (variable, variable) in
  Ty.generalize 0 scheme;
  let first = Ty.instantiate context 0 scheme in
  let second = Ty.instantiate context 0 scheme in
  Ty.unify first (Ty.Arrow (int_type, int_type));
  Printf.printf "scheme: %s\nfirst: %s\nsecond: %s\n" (Ty.show scheme)
    (Ty.show first) (Ty.show second);
  [%expect
    {|
    scheme: 'a -> 'a
    first: int -> int
    second: 'a -> 'a
    |}]

let%expect_test
    "occurs checks inspect arrows, tuples, and nominal type arguments" =
  List.iter
    (fun recursive_type ->
      let context = Ty.create () in
      let variable = Ty.fresh context 0 in
      try
        Ty.unify variable (recursive_type variable);
        assert false
      with Ty.Unification_error Ty.Occurs_check ->
        print_endline "occurs check")
    [
      (fun variable -> Ty.Arrow (variable, int_type));
      (fun variable -> Ty.Tuple [ int_type; variable ]);
      (fun variable ->
        Ty.Constructor ({ Core.id = 6; spelling = "list" }, [ variable ]));
    ];
  [%expect {|
    occurs check
    occurs check
    occurs check
    |}]

let%expect_test
    "diagnostic variable names are shared across expected and actual types" =
  let context = Ty.create () in
  let first = Ty.fresh context 0 and second = Ty.fresh context 0 in
  let expected, actual = Ty.show_pair first (Ty.Arrow (first, second)) in
  Printf.printf "expected %s; actual %s\n" expected actual;
  [%expect {| expected 'a; actual 'a -> 'b |}]

let%expect_test "more than 26 type variables have stable readable names" =
  let context = Ty.create () in
  let variables = List.init 28 (fun _ -> Ty.fresh context 0) in
  print_endline (Ty.show (Ty.Tuple variables));
  [%expect
    {| 'a * 'b * 'c * 'd * 'e * 'f * 'g * 'h * 'i * 'j * 'k * 'l * 'm * 'n * 'o * 'p * 'q * 'r * 's * 't * 'u * 'v * 'w * 'x * 'y * 'z * 'a1 * 'b1 |}]

let%expect_test
    "type reporting excludes locals, generated parameters, and the prelude" =
  let source =
    "let outer (x, y) = let inner z = z in (inner x, inner y);; let (_, value) \
     = (1, true);;"
  in
  match Check.source ~file:"types.tern" source with
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)
  | Ok result ->
      print_string (Infer.format_bindings result);
      [%expect
        {|
        val outer : 'a * 'b -> 'a * 'b
        val value : bool
        |}]

let%expect_test
    "failure does not leak mutable type cells into another invocation" =
  let valid = "let id x = x;;" in
  let infer source =
    match Check.source ~file:"types.tern" source with
    | Ok result -> Infer.format_bindings result
    | Error _ -> "error"
  in
  let first = infer valid in
  assert (infer "let bad x = x x;;" = "error");
  assert (infer valid = first);
  print_string first;
  [%expect {| val id : 'a -> 'a |}]
