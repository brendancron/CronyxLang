(* What the compiler is allowed to reach, worked out from the manifest. `cx`
   resolves; the compiler consumes. *)

open Bootstrap

(* [located] is where resolution unpacked each registry dependency. *)
let dependency_roots ?(located = fun _ -> None) (m : Manifest.t) =
  List.filter_map
    (fun (d : Manifest.dependency) ->
      match d.Manifest.source with
      | Manifest.Path (path, _) ->
        Some (d.Manifest.name, Loader.from_source (Filename.concat m.Manifest.root path))
      | Manifest.Registry _ ->
        Option.map (fun dir -> d.Manifest.name, Loader.from_source dir) (located d.Manifest.name))
    m.Manifest.dependencies

let roots ?located (m : Manifest.t) =
  { Loader.package = m.Manifest.root
  ; std = Toolchain.stdlib ()
  ; deps = dependency_roots ?located m
  }

(* The entry a package runs: `src/main.cx`, and `src/lib.cx` for a library that
   has no other. *)
let entry_of root =
  let candidate name = Filename.concat root (Filename.concat "src" name) in
  if Sys.file_exists (candidate "main.cx")
  then Some (candidate "main.cx")
  else if Sys.file_exists (candidate "lib.cx")
  then Some (candidate "lib.cx")
  else None
