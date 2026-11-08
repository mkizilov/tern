type checked = { core : Core.program; inferred : Infer.result }

let prepare ~file source =
  match Parse.program ~file source with
  | Error diagnostic -> Error diagnostic
  | Ok surface -> (
      match Resolve.program surface with
      | Error diagnostic -> Error diagnostic
      | Ok core -> (
          match Infer.program core with
          | Error diagnostic -> Error diagnostic
          | Ok inferred -> Ok { core; inferred }))

let source ~file source =
  match prepare ~file source with
  | Error diagnostic -> Error diagnostic
  | Ok checked -> Ok checked.inferred
