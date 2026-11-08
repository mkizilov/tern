module Ids = Map.Make (Int)

type context = { mutable next_id : int; payloads : bool Ids.t }

type row = {
  patterns : Core.pattern list;
  label : Core.name;
  parameters : Core.name list;
  bindings : Anf.atom Ids.t;
}

let node span value : _ Ast.located = { value; span }

let fresh context span spelling : Core.name =
  let id = context.next_id in
  context.next_id <- id + 1;
  node span { Core.id; spelling }

let named context span rhs continuation =
  let name = fresh context span "$anf" in
  node span (Anf.Let (name, node span rhs, continuation (Anf.Name name)))

let rec bind_pattern context (pattern : Core.pattern) atom body =
  match pattern.value with
  | Core.Wildcard | Literal_pattern Ast.Unit -> body
  | Bind name ->
      node pattern.span
        (Anf.Let (name, node pattern.span (Anf.Alias atom), body))
  | Tuple_pattern fields ->
      let rec fields_at index = function
        | [] -> body
        | field :: rest ->
            let name = fresh context field.Ast.span "$field" in
            let rest = fields_at (index + 1) rest in
            let body = bind_pattern context field (Anf.Name name) rest in
            node field.span
              (Anf.Let (name, node field.span (Anf.Field (atom, index)), body))
      in
      fields_at 0 fields
  | _ -> assert false

let rec pattern_names (pattern : Core.pattern) =
  match pattern.value with
  | Bind name -> [ name ]
  | Tuple_pattern fields -> List.concat_map pattern_names fields
  | Constructor_pattern (_, Some payload) -> pattern_names payload
  | _ -> []

let simple (pattern : Core.pattern) =
  match pattern.value with Wildcard | Bind _ -> true | _ -> false

let bind_column row (pattern : Core.pattern) atom =
  match pattern.value with
  | Core.Bind name ->
      { row with bindings = Ids.add name.value.id atom row.bindings }
  | _ -> row

let move_front index values =
  let rec take index before = function
    | first :: rest when index = 0 -> first :: List.rev_append before rest
    | first :: rest -> take (index - 1) (first :: before) rest
    | [] -> assert false
  in
  take index [] values

let key (pattern : Core.pattern) =
  match pattern.value with
  | Core.Literal_pattern literal -> Anf.Constant literal
  | Constructor_pattern (name, _) -> Anf.Tag name.value
  | _ -> assert false

let equal_key left right =
  match (left, right) with
  | Anf.Tag left, Anf.Tag right -> left.id = right.id
  | Anf.Constant left, Anf.Constant right -> left = right
  | _ -> false

let wild span = node span Core.Wildcard

let rec decision context span columns rows =
  match rows with
  | [] -> node span (Anf.Fail "pattern match failed")
  | first :: _ when List.for_all simple first.patterns ->
      let first = List.fold_left2 bind_column first first.patterns columns in
      let arguments =
        List.map
          (fun (name : Core.name) -> Ids.find name.value.id first.bindings)
          first.parameters
      in
      node span (Anf.Jump (first.label, arguments))
  | first :: _ -> (
      let rec select index = function
        | pattern :: rest ->
            if simple pattern then select (index + 1) rest else index
        | [] -> assert false
      in
      let column = select 0 first.patterns in
      let columns = move_front column columns in
      let rows =
        List.map
          (fun row -> { row with patterns = move_front column row.patterns })
          rows
      in
      let subject, remaining =
        match columns with first :: rest -> (first, rest) | [] -> assert false
      in
      let head = List.hd (List.hd rows).patterns in
      match head.value with
      | Core.Tuple_pattern fields ->
          let names =
            List.mapi
              (fun index _ ->
                fresh context span ("$field" ^ string_of_int index))
              fields
          in
          let specialized =
            List.map
              (fun row ->
                match row.patterns with
                | pattern :: rest ->
                    let row = bind_column row pattern subject in
                    let fields =
                      match pattern.value with
                      | Core.Tuple_pattern fields -> fields
                      | Wildcard | Bind _ ->
                          List.map (fun _ -> wild pattern.span) names
                      | _ -> assert false
                    in
                    { row with patterns = fields @ rest }
                | [] -> assert false)
              rows
          in
          let body =
            decision context span
              (List.map (fun name -> Anf.Name name) names @ remaining)
              specialized
          in
          List.fold_right
            (fun (index, name) body ->
              node span
                (Anf.Let (name, node span (Anf.Field (subject, index)), body)))
            (List.mapi (fun index name -> (index, name)) names)
            body
      | Literal_pattern _ | Constructor_pattern _ ->
          let keys =
            List.fold_left
              (fun keys row ->
                let pattern = List.hd row.patterns in
                if simple pattern then keys
                else
                  let candidate = key pattern in
                  if List.exists (equal_key candidate) keys then keys
                  else keys @ [ candidate ])
              [] rows
          in
          let branches =
            List.map
              (fun selected ->
                let payload =
                  match selected with
                  | Anf.Tag name when Ids.find name.id context.payloads ->
                      Some (fresh context span "$payload")
                  | _ -> None
                in
                let specialized =
                  List.filter_map
                    (fun row ->
                      let pattern, rest =
                        match row.patterns with
                        | p :: rest -> (p, rest)
                        | [] -> assert false
                      in
                      let row = bind_column row pattern subject in
                      let arguments =
                        if simple pattern then
                          Some
                            (match payload with
                            | None -> []
                            | Some _ -> [ wild pattern.span ])
                        else if equal_key selected (key pattern) then
                          Some
                            (match pattern.value with
                            | Core.Constructor_pattern (_, Some payload) ->
                                [ payload ]
                            | _ -> [])
                        else None
                      in
                      Option.map
                        (fun arguments ->
                          { row with patterns = arguments @ rest })
                        arguments)
                    rows
                in
                let columns =
                  match payload with
                  | None -> remaining
                  | Some name -> Anf.Name name :: remaining
                in
                let body = decision context span columns specialized in
                let body =
                  match payload with
                  | None -> body
                  | Some name ->
                      node span
                        (Anf.Let (name, node span (Anf.Payload subject), body))
                in
                (selected, body))
              keys
          in
          let defaults =
            List.filter_map
              (fun row ->
                match row.patterns with
                | pattern :: rest when simple pattern ->
                    let row = bind_column row pattern subject in
                    Some { row with patterns = rest }
                | _ -> None)
              rows
          in
          node span
            (Anf.Switch
               (subject, branches, decision context span remaining defaults))
      | _ -> assert false)

let rec normalize context (source : Core.expr) continuation =
  match source.value with
  | Core.Literal literal -> continuation (Anf.Literal literal)
  | Variable name -> continuation (Anf.Name name)
  | Constructor name ->
      named context source.span (Anf.Constructor name) continuation
  | Lambda (parameter, body) ->
      let body = tail context body in
      named context source.span (Anf.Lambda (parameter, body)) continuation
  | Apply (callee, argument) ->
      normalize context callee (fun callee ->
          normalize context argument (fun argument ->
              named context source.span
                (Anf.Apply (callee, argument))
                continuation))
  | Primitive (operator, operands) ->
      atoms context operands (fun operands ->
          named context source.span
            (Anf.Primitive (operator, operands))
            continuation)
  | Tuple fields ->
      atoms context fields (fun fields ->
          named context source.span (Anf.Tuple fields) continuation)
  | Let (pattern, rhs, body) ->
      normalize context rhs (fun atom ->
          let body = normalize context body continuation in
          bind_pattern context pattern atom body)
  | Let_rec (bindings, body) ->
      let bindings =
        List.map
          (fun (binding : Core.recursive_binding) ->
            match binding.value.recursive_body.value with
            | Core.Lambda (parameter, body) ->
                let body = tail context body in
                node binding.span
                  {
                    Anf.function_name = binding.value.recursive_name;
                    parameter;
                    body;
                  }
            | _ -> assert false)
          bindings
      in
      node source.span
        (Anf.Let_rec (bindings, normalize context body continuation))
  | If (condition, yes, no) ->
      normalize context condition (fun condition ->
          let yes = tail context yes in
          let no = tail context no in
          let block = node source.span (Anf.If (condition, yes, no)) in
          named context source.span (Anf.Block block) continuation)
  | Match (subject, cases) ->
      normalize context subject (fun subject ->
          let joins, rows =
            List.split
              (List.map
                 (fun (case : Core.case) ->
                   let label = fresh context case.span "$case" in
                   let parameters = pattern_names case.value.case_pattern in
                   let action = tail context case.value.case_body in
                   let join =
                     node case.span { Anf.label; parameters; action }
                   in
                   let row =
                     {
                       patterns = [ case.value.case_pattern ];
                       label;
                       parameters;
                       bindings = Ids.empty;
                     }
                   in
                   (join, row))
                 cases)
          in
          let tree = decision context source.span [ subject ] rows in
          let block = node source.span (Anf.Joins (joins, tree)) in
          named context source.span (Anf.Block block) continuation)

and atoms context sources continuation =
  match sources with
  | [] -> continuation []
  | first :: rest ->
      normalize context first (fun first ->
          atoms context rest (fun rest -> continuation (first :: rest)))

and tail context source =
  normalize context source (fun atom -> node source.Ast.span (Anf.Return atom))

let program (checked : Check.checked) : Anf.program =
  let core = checked.core in
  let payloads =
    List.fold_left
      (fun map (definition : Core.type_decl) ->
        List.fold_left
          (fun map (constructor : Core.constructor_decl) ->
            Ids.add constructor.value.constructor_name.value.id
              (Option.is_some constructor.value.constructor_payload)
              map)
          map definition.value.type_constructors)
      Ids.empty core.value.types
  in
  let context = { next_id = core.value.next_id; payloads } in
  let body = tail context core.value.body in
  node core.span
    {
      Anf.next_id = context.next_id;
      builtins = core.value.builtins;
      types = core.value.types;
      body;
    }
