let source ~file source =
  match Parse.program ~file source with
  | Error diagnostic -> Error diagnostic
  | Ok surface ->
      (match Resolve.program surface with
      | Error diagnostic -> Error diagnostic
      | Ok core -> Infer.program core)
