type flags = {
  constants : bool;
  dead_code : bool;
  inline : bool;
  matches : bool;
}

let none =
  { constants = false; dead_code = false; inline = false; matches = false }

let all = { constants = true; dead_code = true; inline = true; matches = true }

let program flags source =
  let source = if flags.inline then Opt_inline.program source else source in
  let source = if flags.constants then Opt_const.program source else source in
  let source = if flags.matches then Opt_match.program source else source in
  if flags.dead_code then Opt_dce.program source else source

let options flags =
  [
    ( "--const-fold",
      Arg.Unit (fun () -> flags := { !flags with constants = true }),
      " fold and propagate constants" );
    ( "--dce",
      Arg.Unit (fun () -> flags := { !flags with dead_code = true }),
      " eliminate dead pure bindings and functions" );
    ( "--inline",
      Arg.Unit (fun () -> flags := { !flags with inline = true }),
      " inline small non-recursive functions" );
    ( "--match-simplify",
      Arg.Unit (fun () -> flags := { !flags with matches = true }),
      " simplify decisions with known constructors" );
    ( "--opt-all",
      Arg.Unit (fun () -> flags := all),
      " enable all IR optimization passes" );
  ]
