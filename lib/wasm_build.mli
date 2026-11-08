val emit :
  ?optimizations:Optimize.flags ->
  Check.checked ->
  (string, Diagnostic.t) result

val build :
  ?optimizations:Optimize.flags ->
  output:string ->
  Check.checked ->
  (unit, Diagnostic.t) result

val run :
  ?optimizations:Optimize.flags -> Check.checked -> (int, Diagnostic.t) result
