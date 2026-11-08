open Runtime

let rec bind environment (pattern : Core.pattern) value =
  match pattern.value, value with
  | Core.Wildcard, _ -> Some environment
  | Bind name, value -> Some (Ids.add name.value.id value environment)
  | Literal_pattern literal, value when equal_literal literal value -> Some environment
  | Tuple_pattern patterns, Tuple values when List.length patterns = List.length values ->
      bind_fields environment patterns values
  | Constructor_pattern (name, payload), Variant (tag, value) when name.value.id = tag.id ->
      (match payload, value with
      | None, None -> Some environment
      | Some pattern, Some value -> bind environment pattern value
      | _ -> None)
  | _ -> None

and bind_fields environment patterns values =
  match patterns, values with
  | [], [] -> Some environment
  | pattern :: patterns, value :: values ->
      (match bind environment pattern value with
      | None -> None
      | Some environment -> bind_fields environment patterns values)
  | _ -> assert false

let rec evaluate context environment (source : Core.expr) =
  context.current <- source.span;
  match source.value with
  | Core.Literal value -> literal value
  | Variable name -> Ids.find name.value.id environment
  | Constructor name -> constructor context name
  | Lambda (parameter, body) ->
      Closure { parameter; body; environment = ref environment }
  | Apply (callee, argument) ->
      let callee = evaluate context environment callee in
      let argument = evaluate context environment argument in
      Runtime.apply context source.span ~call:(evaluate context) callee argument
  | Let (pattern, rhs, body) ->
      let value = evaluate context environment rhs in
      (match bind environment pattern value with
      | Some environment -> evaluate context environment body
      | None -> Diagnostic.fail pattern.span "pattern binding failed")
  | Let_rec (bindings, body) ->
      let shared = ref environment in
      let recursive_environment =
        List.fold_left
          (fun environment (binding : Core.recursive_binding) ->
            let value =
              match binding.value.recursive_body.value with
              | Core.Lambda (parameter, body) ->
                  Closure { parameter; body; environment = shared }
              | _ -> assert false
            in
            Ids.add binding.value.recursive_name.value.id value environment)
          environment bindings
      in
      (* The whole group is tied before any closure body can run. *)
      shared := recursive_environment;
      evaluate context recursive_environment body
  | If (condition, yes, no) ->
      (match evaluate context environment condition with
      | Boolean true -> evaluate context environment yes
      | Boolean false -> evaluate context environment no
      | _ -> assert false)
  | Tuple fields -> Tuple (evaluate_fields context environment fields)
  | Match (subject, cases) ->
      let value = evaluate context environment subject in
      cases_value context environment source.span value cases
  | Primitive (operator, operands) ->
      let values = evaluate_fields context environment operands in
      primitive context operator values

and evaluate_fields context environment = function
  | [] -> []
  | first :: rest ->
      let value = evaluate context environment first in
      let values = evaluate_fields context environment rest in
      value :: values

and cases_value context environment span value = function
  | [] -> Diagnostic.fail span "pattern match failed"
  | (case : Core.case) :: rest ->
      (match bind environment case.value.case_pattern value with
      | Some environment -> evaluate context environment case.value.case_body
      | None -> cases_value context environment span value rest)

let program ~write (checked : Check.checked) =
  let core = checked.core in
  let context = Runtime.create ~write core.span in
  Runtime.protect context (fun () ->
    let environment = Runtime.initialize context core.value.types core.value.builtins in
    match evaluate context environment core.value.body with
    | Unit -> ()
    | _ -> assert false)
