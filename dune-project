(lang dune 3.10)

(name teagent)

(version 0.2.0)

(generate_opam_files true)

(source
 (github jongleb/teagent))

(authors "Gleb <10594395+jongleb@users.noreply.github.com>")

(maintainers "Gleb <10594395+jongleb@users.noreply.github.com>")

(license BSD-3-Clause)

(package
 (name teagent)
 (synopsis "A coding agent whose unit of work is a typed program")
 (description
  "The model writes a Dartea (Elm) program; teagent typechecks it, plans it, runs its effects through one handler, and logs every step so any session replays exactly. Write and edit stay staged until commit, and shell commands run in a sandboxed clone of the project.")
 (depends
  (ocaml
   (>= 5.4.0))
  dune
  (menhir
   (>= 20240715))
  (cmdliner
   (>= 2.0.0))
  fpath
  bos
  rresult
  (yojson
   (>= 3.0.0))
  conf-libcurl
  ocurl
  ezcurl
  lwt
  (trace
   (>= 0.12))
  digestif
  base64
  (tar
   (>= 3.0.0))
  (tar-unix
   (>= 3.0.0))
  decompress
  zipc
  ppx_deriving
  ppx_deriving_yojson
  ppx_jane
  non_empty_list
  base
  (ounit2 :with-test)
  (qcheck-core :with-test)
  (qcheck-ounit :with-test)))
