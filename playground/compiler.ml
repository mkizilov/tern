open Js_of_ocaml
open Tern

let span (span : Ast.span) =
  object%js
    val file = Js.string span.file
    val startByte = span.start_pos.byte_offset
    val endByte = span.end_pos.byte_offset
  end

let diagnostic source (diagnostic : Diagnostic.t) =
  object%js
    val severity = Js.string (Diagnostic.severity_name diagnostic.severity)
    val message = Js.string diagnostic.message
    val primary = span diagnostic.primary

    val secondary =
      Js.array
        (Array.of_list
           (List.map
              (fun (label : Diagnostic.label) ->
                object%js
                  val span = span label.span

                  val message =
                    Js.string (Option.value label.message ~default:"")
                end)
              diagnostic.secondary))

    val rendered =
      Js.string
        (Diagnostic.render ~color:false
           ~source:(fun _ -> Some source)
           diagnostic)
  end

let result source ok types ir wat diagnostics =
  object%js
    val ok = Js.bool ok
    val types = Js.string types
    val ir = Js.string ir
    val wat = Js.string wat

    val diagnostics =
      Js.array (Array.of_list (List.map (diagnostic source) diagnostics))
  end

let compile source =
  let source = Js.to_string source in
  match Check.prepare ~file:"playground.tern" source with
  | Error error -> result source false "" "" "" [ error ]
  | Ok checked -> (
      let anf = Lower.program checked in
      let ir = Ir_pretty.program anf in
      let types = Infer.format_bindings checked.inferred in
      match Wat.program (Closure_convert.program anf) with
      | Error error ->
          result source false types ir "" (checked.inferred.warnings @ [ error ])
      | Ok wat -> result source true types ir wat checked.inferred.warnings)

let () =
  Js.export "TernCompiler"
    object%js
      method compile source = compile source
    end
