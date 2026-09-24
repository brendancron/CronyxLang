(* Where the standard library is. It ships inside the toolchain rather than as
   a package, so `import "std/…"` resolves here and never through the
   filesystem the program happens to sit in. *)

let marker = Filename.concat "stdlib" "lang"

let up_from dir =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir marker)
    then Some (Filename.concat dir "stdlib")
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else up parent)
  in
  up dir

(* A package manager puts the binary somewhere and links it onto the PATH --
   Homebrew links `bin/cx` out of a versioned cellar -- so the prefix has to be
   measured from the real file rather than from the name it was reached by.
   This does not save a *shim*, which is a different executable rather than a
   link and so reports itself; `CRONYX_STDLIB` is the way out of that. *)
let real path = try Unix.realpath path with Unix.Unix_error _ -> path

(* An installed toolchain is `<prefix>/bin/cx` beside `<prefix>/lib/cronyx/stdlib`,
   so the library is found from the binary rather than from wherever the user
   happens to be standing. *)
let beside_binary () =
  let prefix = Filename.dirname (Filename.dirname (real Sys.executable_name)) in
  let installed = Filename.concat prefix (Filename.concat "lib" (Filename.concat "cronyx" "stdlib")) in
  if Sys.file_exists (Filename.concat installed "lang") then Some installed else None

let stdlib () =
  match Sys.getenv_opt "CRONYX_STDLIB" with
  | Some dir -> Some dir
  | None ->
    (match beside_binary () with
     | Some dir -> Some dir
     | None ->
       (match up_from (Sys.getcwd ()) with
        | Some dir -> Some dir
        | None -> up_from (Filename.dirname Sys.executable_name)))
