type checked = private { core : Core.program; inferred : Infer.result }

val prepare : file:string -> string -> (checked, Diagnostic.t) result
val source : file:string -> string -> (Infer.result, Diagnostic.t) result
