val emit : Check.checked -> (string, Diagnostic.t) result
val build : output:string -> Check.checked -> (unit, Diagnostic.t) result
val run : Check.checked -> (int, Diagnostic.t) result
