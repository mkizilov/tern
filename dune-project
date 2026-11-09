(lang dune 3.20)

(name ternc)

(version 0.1.0)

(authors "Mykyta Kizilov")
(maintainers "Mykyta Kizilov")
(license MIT)

(generate_opam_files true)

(using menhir 3.0)

(package
 (name ternc)
 (synopsis "Tern functional language compiler targeting WebAssembly")
 (description "A statically typed functional language with Hindley-Milner inference.")
 (depends
  (ocaml (and (>= 5.1) (< 6.0)))
  dune
  menhir
  menhirLib
  uucp
  (sedlex (>= 3.6))
  ppx_deriving
  ppx_expect
  qcheck
  js_of_ocaml
  js_of_ocaml-ppx
  (ocamlformat (= 0.29.0))))
