open Tern

let check source =
  match Check.source ~file:"coverage.tern" source with
  | Ok result ->
      assert (List.for_all (fun (warning : Diagnostic.t) -> warning.severity = Diagnostic.Warning) result.warnings);
      result
  | Error diagnostic -> failwith (Diagnostic.show diagnostic)

let warnings source =
  match (check source).warnings with
  | [] -> print_endline "no warnings"
  | warnings ->
      List.iter
        (fun (warning : Diagnostic.t) ->
          print_endline warning.message;
          List.iter (fun note -> print_endline ("note: " ^ note)) warning.notes)
        warnings

let render source =
  List.iter
    (fun warning ->
      print_string
        (Diagnostic.render
           ~source:(fun file -> if file = "coverage.tern" then Some source else None)
           warning))
    (check source).warnings

let option = "type 'a option = None | Some of 'a;; "
let list = "type 'a list = Nil | Cons of ('a * 'a list);; "

let%expect_test "option constructors cover a polymorphic family" =
  warnings (option ^ "let f x = match x with None -> 0 | Some _ -> 1;;");
  [%expect {| no warnings |}]

let%expect_test "a missing option constructor has a witness" =
  warnings (option ^ "let f x = match x with Some _ -> 1;;");
  warnings (option ^ "let f x = match x with None -> 0;;");
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: None
    non-exhaustive pattern match
    note: example of an unmatched value: Some _
    |}]

let%expect_test "nested option patterns reconstruct a missing inner constructor" =
  warnings (option ^ "let f x = match x with None -> 0 | Some (Some _) -> 1;;");
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: Some None
    |}]

let%expect_test "nested option wildcard is exhaustive" =
  warnings (option ^ "let f x = match x with None -> 0 | Some (Some _) -> 1 | Some None -> 2;;");
  [%expect {| no warnings |}]

let%expect_test "actual type arguments make Some true and Some false complete" =
  warnings (option ^ "let f x = match x with None -> 0 | Some true -> 1 | Some false -> 2;;");
  [%expect {| no warnings |}]

let%expect_test "missing boolean payload uses the substituted payload type" =
  warnings (option ^ "let f x = match x with None -> 0 | Some true -> 1;;");
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: Some false
    |}]

let%expect_test "list constructors and recursive wildcards are exhaustive" =
  warnings (list ^ "let f xs = match xs with Nil -> 0 | Cons (_, _) -> 1;;");
  [%expect {| no warnings |}]

let%expect_test "list missing empty and nonempty cases" =
  warnings (list ^ "let f xs = match xs with Cons (_, _) -> 1;;");
  warnings (list ^ "let f xs = match xs with Nil -> 0;;");
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: Nil
    non-exhaustive pattern match
    note: example of an unmatched value: Cons _
    |}]

let%expect_test "nested list gap reconstructs a singleton shape" =
  warnings (list ^ "let f xs = match xs with Nil -> 0 | Cons (_, Cons (_, _)) -> 2;;");
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: Cons (_, Nil)
    |}]

let%expect_test "a missing integer head in a list has a concrete witness" =
  warnings (list ^ "let f xs = match xs with Nil -> 0 | Cons (0, _) -> 1;;");
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: Cons (1, Nil)
    |}]

let%expect_test "tuple coverage preserves correlations between columns" =
  warnings "let f x = match x with (true, true) -> 1 | (false, false) -> 0;;";
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: (false, true)
    |}]

let%expect_test "redundancy is checked against a union, not only a previous row" =
  warnings "let f x = match x with (true, _) -> 1 | (false, true) -> 2 | (false, false) -> 3 | (_, _) -> 4;;";
  [%expect
    {|
    unreachable match case
    note: this pattern is covered by earlier cases
    |}]

let%expect_test "wildcards and binding variables both subsume later cases" =
  warnings (option ^ "let f x = match x with _ -> 0 | Some _ -> 1;;");
  warnings (option ^ "let f x = match x with y -> 0 | None -> 1;;");
  [%expect
    {|
    unreachable match case
    note: this pattern is covered by earlier cases
    unreachable match case
    note: this pattern is covered by earlier cases
    |}]

let%expect_test "an earlier constructor wildcard subsumes a nested constructor" =
  warnings (option ^ "let f x = match x with Some _ -> 0 | Some (Some _) -> 1 | None -> 2;;");
  [%expect
    {|
    unreachable match case
    note: this pattern is covered by earlier cases
    |}]

let%expect_test "overlapping patterns are not redundant when they add values" =
  warnings "let f x = match x with (true, _) -> 1 | (_, true) -> 2 | (false, false) -> 3;;";
  [%expect {| no warnings |}]

let%expect_test "integer and string domains use fresh literal witnesses" =
  warnings "let f x = match x with 0 -> 0 | 1 -> 1;;";
  warnings {|let f x = match x with "" -> 0;;|};
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: 2
    non-exhaustive pattern match
    note: example of an unmatched value: "x"
    |}]

let%expect_test "duplicate scalar literals are redundant, without losing exhaustiveness" =
  warnings {|let f x = match x with "a" -> 0 | "a" -> 1 | _ -> 2;;|};
  warnings "let f x = match x with 0 -> 0 | 0 -> 1 | _ -> 2;;";
  [%expect
    {|
    unreachable match case
    note: this pattern is covered by earlier cases
    unreachable match case
    note: this pattern is covered by earlier cases
    |}]

let%expect_test "unit is a singleton domain, bool is a two-value domain" =
  warnings "let f x = match x with () -> 0;;";
  warnings "let f x = match x with true -> 1;;";
  [%expect
    {|
    no warnings
    non-exhaustive pattern match
    note: example of an unmatched value: false
    |}]

let%expect_test "multiple type parameters are substituted independently" =
  warnings "type ('a, 'b) result = Ok of 'a | Error of 'b;; let f x = match x with Ok true -> 1 | Ok false -> 2 | Error _ -> 3;;";
  warnings "type ('a, 'b) result = Ok of 'a | Error of 'b;; let f x = match x with Ok _ -> 1 | Error true -> 2 | Error false -> 3;;";
  [%expect
    {|
    no warnings
    no warnings
    |}]

let%expect_test "warning spans show the complete partial match" =
  render ("type 'a option = None | Some of 'a;;\n"
          ^ "let get x =\n  match x with\n  | Some n -> n;;");
  [%expect
    {|
    warning: non-exhaustive pattern match
     --> coverage.tern:3:3
      |
    3 |   match x with
      |   ^^^^^^^^^^^^
    4 |   | Some n -> n;;
      | ^^^^^^^^^^^^^^^
     = note: example of an unmatched value: None
    |}]

let%expect_test "an unreachable case points at its own pattern" =
  render "let f x =\n  match x with\n  | _ -> 0\n  | _ -> 1;;";
  [%expect
    {|
    warning: unreachable match case
     --> coverage.tern:4:5
      |
    4 |   | _ -> 1;;
      |     ^
     = note: this pattern is covered by earlier cases
    |}]

let%expect_test "partial and redundant warnings are both emitted in source order" =
  warnings "let f x = match x with true -> 0 | true -> 1;;";
  [%expect
    {|
    non-exhaustive pattern match
    note: example of an unmatched value: false
    unreachable match case
    note: this pattern is covered by earlier cases
    |}]

let%expect_test "a type error is still fatal even in an unreachable case" =
  match Check.source ~file:"coverage.tern" "let f x = match x with _ -> 0 | true -> false;;" with
  | Ok _ -> assert false
  | Error diagnostic -> print_endline diagnostic.message;
      [%expect {| type mismatch: expected int, but got bool |}]

let%expect_test "variant payload and nominal result typing remain enforced" =
  List.iter
    (fun source ->
      match Check.source ~file:"coverage.tern" source with
      | Ok _ -> assert false
      | Error diagnostic -> print_endline diagnostic.message)
    [ "type a = A;; type b = B;; let bad = if true then A else B;;";
      option ^ "let bad = match Some true with Some 0 -> 0 | None -> 1;;" ];
  [%expect
    {|
    type mismatch: expected a, but got b
    type mismatch: expected int, but got bool
    |}]

let%expect_test "recursive types do not require unbounded constructor unfolding" =
  warnings "type tree = Leaf | Branch of (tree * tree);; let f x = match x with Leaf -> 0 | Branch (_, _) -> 1;;";
  warnings "type loop = Loop of loop;; let f x = match x with Loop (Loop _) -> 0;;";
  [%expect
    {|
    no warnings
    no warnings
    |}]

let%expect_test "option and list libraries type-check without match warnings" =
  List.iter
    (fun file ->
      let source = In_channel.with_open_bin ("../examples/" ^ file) In_channel.input_all in
      let result = check source in
      assert (result.warnings = []);
      Printf.printf "%s\n%s" file (Infer.format_bindings result))
    [ "12_options.tern"; "15_list_library.tern" ];
  [%expect
    {|
    12_options.tern
    val map_option : ('a -> 'b) -> 'a option -> 'b option
    val value_or : 'a -> 'a option -> 'a
    15_list_library.tern
    val map : ('a -> 'b) -> 'a list -> 'b list
    val filter : ('a -> bool) -> 'a list -> 'a list
    val fold : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a
    val print_list : int list -> unit
    val numbers : int list
    val doubled : int list
    val large : int list
    val total : int
    val words : string list
    |}]

let%expect_test "all example matches are exhaustive and useful" =
  let files =
    Sys.readdir "../examples" |> Array.to_list
    |> List.filter (fun file -> Filename.extension file = ".tern")
  in
  assert (List.length files = 15);
  List.iter
    (fun file ->
      let source = In_channel.with_open_bin ("../examples/" ^ file) In_channel.input_all in
      assert ((check source).warnings = []))
    files;
  print_endline "15 examples: no pattern-match warnings";
  [%expect {| 15 examples: no pattern-match warnings |}]

let%expect_test "finite boolean products agree with exhaustive enumeration" =
  let core =
    match Resolve.program (match Parse.program ~file:"finite.tern" "" with Ok p -> p | Error _ -> assert false) with
    | Ok core -> core
    | Error _ -> assert false
  in
  let catalog = Coverage.catalog core in
  let boolean, _ = List.find (fun (_, kind) -> kind = Core.Bool_type) core.value.builtin_types in
  let bool_type = Ty.Constructor (boolean.value, []) in
  let typ = Ty.Tuple [ bool_type; bool_type ] in
  let literal value = Coverage.Node (Coverage.Literal (Ast.Bool value), []) in
  let patterns =
    List.concat_map
      (fun first ->
        List.map (fun second -> Coverage.Node (Coverage.Tuple 2, [ first; second ]))
          [ Coverage.Any; literal false; literal true ])
      [ Coverage.Any; literal false; literal true ]
  in
  let values =
    List.concat_map
      (fun first -> List.map (fun second -> Coverage.Node (Coverage.Tuple 2, [ literal first; literal second ]))
                      [ false; true ])
      [ false; true ]
  in
  let rec matches (pattern : Coverage.pattern) (value : Coverage.pattern) =
    match pattern, value with
    | Coverage.Any, _ -> true
    | Node (head, arguments), Node (other, fields) ->
        Coverage.equal_head head other && List.for_all2 matches arguments fields
    | _ -> false
  in
  let count = ref 0 in
  for mask = 0 to 511 do
    let previous = List.filteri (fun index _ -> mask land (1 lsl index) <> 0) patterns in
    let matrix = List.map (fun pattern -> [ pattern ]) previous in
    List.iter
      (fun query ->
        let uncovered value = not (List.exists (fun pattern -> matches pattern value) previous) in
        let expected = List.exists (fun value -> matches query value && uncovered value) values in
        let actual = Coverage.useful catalog [ typ ] matrix [ query ] in
        assert (Option.is_some actual = expected);
        (match actual with
        | Some [ witness ] ->
            assert (List.exists (matches witness) values);
            List.iter
              (fun value -> if matches witness value then assert (matches query value && uncovered value))
              values
        | None -> ()
        | _ -> assert false);
        incr count)
      patterns
  done;
  Printf.printf "%d usefulness queries; all witnesses validated\n" !count;
  [%expect {| 4608 usefulness queries; all witnesses validated |}]
