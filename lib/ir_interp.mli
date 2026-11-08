val program :
  write:(string -> unit) -> Anf.program -> (unit, Diagnostic.t) result

val closed :
  write:(string -> unit) -> Closed.program -> (unit, Diagnostic.t) result
