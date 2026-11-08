module Ids = Map.Make (Int)

type context = {
  mutable next_id : int;
  mutable next_function : int;
  mutable functions : Closed.function_definition list;
  constructors : int Ids.t;
}

let node span value : _ Ast.located = { value; span }

let fresh context span spelling : Core.name =
  let id = context.next_id in
  context.next_id <- id + 1;
  node span { Core.id; spelling }

let reserve context =
  let index = context.next_function in
  context.next_function <- index + 1;
  index

let atom substitution = function
  | Anf.Name name as original ->
      Option.value (Ids.find_opt name.value.id substitution) ~default:original
  | literal -> literal

let named context span value continuation =
  let name = fresh context span "$cc" in
  node span (Closed.Let (name, node span value, continuation (Anf.Name name)))

let add_function context definition =
  context.functions <- definition :: context.functions

let rec expression context substitution known (source : Anf.expr) =
  let value =
    match source.value with
    | Anf.Return value -> Closed.Return (atom substitution value)
    | Let (name, rhs, body) ->
        return_let context substitution known source.span name rhs body
    | Let_rec (functions, body) ->
        recursive_group context substitution known source.span functions body
    | Joins (joins, body) ->
        let joins =
          List.map
            (fun (join : Anf.join) ->
              let action =
                expression context substitution known join.value.action
              in
              node join.span
                {
                  Closed.label = join.value.label;
                  parameters = join.value.parameters;
                  action;
                })
            joins
        in
        Closed.Joins (joins, expression context substitution known body)
    | Jump (label, arguments) ->
        Closed.Jump (label, List.map (atom substitution) arguments)
    | If (condition, yes, no) ->
        let yes = expression context substitution known yes in
        let no = expression context substitution known no in
        Closed.If (atom substitution condition, yes, no)
    | Switch (subject, arms, default) ->
        let arms =
          List.map
            (fun (key, body) ->
              (key, expression context substitution known body))
            arms
        in
        let default = expression context substitution known default in
        Closed.Switch (atom substitution subject, arms, default)
    | Fail message -> Closed.Fail message
  in
  node source.span value

and return_let context substitution known span (name : Core.name)
    (rhs : Anf.rhs) body =
  let finish ?index value =
    let known =
      match index with
      | None -> known
      | Some index -> Ids.add name.Ast.value.id index known
    in
    Closed.Let
      (name, node rhs.span value, expression context substitution known body)
  in
  match rhs.value with
  | Anf.Lambda (parameter, function_body) ->
      let index = reserve context in
      let captures = Free_vars.function_body parameter function_body in
      lift context known index name parameter captures captures function_body;
      let environment = fresh context rhs.span "$env" in
      let fields =
        List.map
          (fun (name : Core.name) -> atom substitution (Anf.Name name))
          captures
      in
      Closed.Let
        ( environment,
          node rhs.span (Closed.Environment fields),
          node span
            (finish ~index (Closed.Closure (index, Anf.Name environment))) )
  | Constructor constructor -> (
      match Ids.find_opt constructor.value.id context.constructors with
      | None -> finish (Closed.Variant (constructor, None))
      | Some index ->
          let environment = fresh context rhs.span "$env" in
          Closed.Let
            ( environment,
              node rhs.span (Closed.Environment []),
              node span
                (finish ~index (Closed.Closure (index, Anf.Name environment)))
            ))
  | Alias value ->
      let index =
        match value with
        | Name value -> Ids.find_opt value.value.id known
        | _ -> None
      in
      finish ?index (Closed.Alias (atom substitution value))
  | Apply (callee, argument) -> (
      let index =
        match callee with
        | Anf.Name name -> Ids.find_opt name.value.id known
        | _ -> None
      in
      let callee = atom substitution callee
      and argument = atom substitution argument in
      match index with
      | None -> finish (Closed.Closure_call (callee, argument))
      | Some index ->
          let environment = fresh context rhs.span "$call_env" in
          Closed.Let
            ( environment,
              node rhs.span (Closed.Closure_environment callee),
              node span
                (finish
                   (Closed.Direct_call (index, Anf.Name environment, argument)))
            ))
  | Primitive (operator, arguments) ->
      finish
        (Closed.Primitive (operator, List.map (atom substitution) arguments))
  | Tuple fields -> finish (Closed.Tuple (List.map (atom substitution) fields))
  | Field (value, index) ->
      finish (Closed.Field (atom substitution value, index))
  | Payload value -> finish (Closed.Payload (atom substitution value))
  | Block block ->
      let block = expression context substitution known block in
      finish (Closed.Block block)

and lift context known index (name : Core.name) (parameter : Core.name)
    (captures : Core.name list) layout (body : Anf.expr) =
  let environment = fresh context body.Ast.span "$env_arg" in
  let loads =
    List.map
      (fun (capture : Core.name) ->
        (capture, fresh context capture.span "$capture"))
      captures
  in
  let substitution =
    List.fold_left
      (fun map ((original : Core.name), local) ->
        Ids.add original.value.id (Anf.Name local) map)
      Ids.empty loads
  in
  let body = expression context substitution known body in
  let slot (capture : Core.name) =
    let rec find index = function
      | (name : Core.name) :: _ when name.value.id = capture.value.id -> index
      | _ :: rest -> find (index + 1) rest
      | [] -> assert false
    in
    find 0 layout
  in
  let body =
    List.fold_right
      (fun (capture, local) body ->
        node local.Ast.span
          (Closed.Let
             ( local,
               node local.span
                 (Closed.Environment_get (Anf.Name environment, slot capture)),
               body )))
      loads body
  in
  add_function context
    (node body.span
       { Closed.index; name; environment; parameter; captures; layout; body })

and recursive_group context substitution known span functions body =
  let indexed =
    List.map (fun (f : Anf.function_binding) -> (f, reserve context)) functions
  in
  let group_names =
    List.map
      (fun ((f : Anf.function_binding), _) -> f.value.function_name)
      indexed
  in
  let known =
    List.fold_left
      (fun known ((f : Anf.function_binding), index) ->
        Ids.add f.value.function_name.value.id index known)
      known indexed
  in
  let outside =
    List.fold_left
      (fun free ((f : Anf.function_binding), _) ->
        let names =
          Free_vars.remove f.value.parameter (Free_vars.expression f.value.body)
        in
        Free_vars.union free (Free_vars.remove_all group_names names))
      Free_vars.Names.empty indexed
    |> Free_vars.Names.bindings |> List.map snd
  in
  let layout = outside @ group_names in
  List.iter
    (fun ((f : Anf.function_binding), index) ->
      let captures = Free_vars.function_body f.value.parameter f.value.body in
      lift context known index f.value.function_name f.value.parameter captures
        layout f.value.body)
    indexed;
  let environment = fresh context span "$rec_env" in
  let body = expression context substitution known body in
  let fields =
    List.map
      (fun (name : Core.name) -> atom substitution (Anf.Name name))
      outside
    @ List.map (fun name -> Anf.Name name) group_names
  in
  let body =
    List.fold_right
      (fun (slot, value) body ->
        let ignored = fresh context span "$init" in
        node span
          (Closed.Let
             ( ignored,
               node span
                 (Closed.Environment_set (Anf.Name environment, slot, value)),
               body )))
      (List.mapi (fun slot value -> (slot, value)) fields)
      body
  in
  let body =
    List.fold_right
      (fun ((f : Anf.function_binding), index) body ->
        node f.span
          (Closed.Let
             ( f.value.function_name,
               node f.span (Closed.Closure (index, Anf.Name environment)),
               body )))
      indexed body
  in
  Closed.Let
    ( environment,
      node span (Closed.Allocate_environment (List.length layout)),
      body )

let wrapper context (name : Core.name) builtin constructor =
  let index = reserve context in
  let environment = fresh context name.Ast.span "$env_arg" in
  let parameter = fresh context name.span "$arg" in
  let body =
    named context name.span
      (match (builtin, constructor) with
      | Some builtin, None -> Closed.Builtin_apply (builtin, Anf.Name parameter)
      | None, Some constructor ->
          Closed.Variant (constructor, Some (Anf.Name parameter))
      | _ -> assert false)
      (fun value -> node name.span (Closed.Return value))
  in
  add_function context
    (node name.span
       {
         Closed.index;
         name;
         environment;
         parameter;
         captures = [];
         layout = [];
         body;
       });
  index

let program (program : Anf.program) : Closed.program =
  let context =
    {
      next_id = program.value.next_id;
      next_function = 0;
      functions = [];
      constructors = Ids.empty;
    }
  in
  let builtins =
    List.map
      (fun ((name : Core.name), builtin) ->
        (name, wrapper context name (Some builtin) None))
      program.value.builtins
  in
  let constructors =
    List.fold_left
      (fun map (definition : Core.type_decl) ->
        List.fold_left
          (fun map (constructor : Core.constructor_decl) ->
            if Option.is_some constructor.value.constructor_payload then
              let name = constructor.value.constructor_name in
              Ids.add name.value.id (wrapper context name None (Some name)) map
            else map)
          map definition.value.type_constructors)
      Ids.empty program.value.types
  in
  let context = { context with constructors } in
  let known =
    List.fold_left
      (fun map ((name : Core.name), index) -> Ids.add name.value.id index map)
      Ids.empty builtins
  in
  let body = expression context Ids.empty known program.value.body in
  let functions =
    List.sort
      (fun (left : Closed.function_definition) right ->
        Int.compare left.value.index right.value.index)
      context.functions
  in
  node program.span
    {
      Closed.next_id = context.next_id;
      functions;
      builtins;
      types = program.value.types;
      body;
    }
