open Ast

let cover (first : span) (last : span) = { first with end_pos = last.end_pos }

let node span value = { value; span }

let name (token : Token.t) =
  match token.value with
  | Token.Identifier value | Constructor value | Type_variable value ->
      node token.span value
  | _ -> assert false

let error span message = raise (Parse_error.Error { message; span })

type expression = Magnitude of int64 located | Expr of expr

let finish = function
  | Expr expression -> expression
  | Magnitude integer ->
      if integer.value > 2147483647L then
        error integer.span "positive integer literal exceeds 2147483647";
      node integer.span (E_literal (Int (Int64.to_int32 integer.value)))

let magnitude (token : Token.t) =
  match token.value with
  | Token.Integer value -> node token.span value
  | _ -> assert false

let negative (minus : Token.t) expression =
  match expression with
  | Magnitude integer ->
      Expr
        (node (cover minus.span integer.span)
           (E_literal (Int (Int64.to_int32 (Int64.neg integer.value)))))
  | Expr expression ->
      Expr
        (node (cover minus.span expression.span)
           (E_unary (node minus.span Negate, expression)))

let lambda parameters body =
  List.fold_right
    (fun parameter body ->
      node (cover parameter.span body.span) (E_lambda (parameter, body)))
    parameters body

let binding pattern parameters body =
  let body = lambda parameters (finish body) in
  node (cover pattern.span body.span)
    { binding_pattern = pattern; binding_body = body }

let recursive bindings =
  List.iter
    (fun binding ->
      match
        binding.value.binding_pattern.value, binding.value.binding_body.value
      with
      | P_variable _, E_lambda _ -> ()
      | _ ->
          error binding.span "recursive bindings require a name and a function")
    bindings;
  Recursive, bindings
