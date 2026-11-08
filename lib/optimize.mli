type flags = {
  constants : bool;
  dead_code : bool;
  inline : bool;
  matches : bool;
}

val none : flags
val all : flags
val program : flags -> Anf.program -> Anf.program
val options : flags ref -> (string * Arg.spec * string) list
