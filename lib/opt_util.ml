module Ids = Map.Make (Int)

let atom values = function
  | Anf.Name name as original ->
      Option.value (Ids.find_opt name.value.id values) ~default:original
  | literal -> literal

let rhs map expression (source : Anf.rhs) =
  let value =
    match source.value with
    | Alias a -> Anf.Alias (map a)
    | Apply (f, a) -> Apply (map f, map a)
    | Primitive (op, args) -> Primitive (op, List.map map args)
    | Tuple args -> Tuple (List.map map args)
    | Constructor name -> Constructor name
    | Lambda (parameter, body) -> Lambda (parameter, expression body)
    | Field (a, index) -> Field (map a, index)
    | Payload a -> Payload (map a)
    | Block body -> Block (expression body)
  in
  { source with value }

let program expression (source : Anf.program) =
  {
    source with
    value = { source.value with body = expression source.value.body };
  }
