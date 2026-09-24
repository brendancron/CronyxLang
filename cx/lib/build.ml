(* Building a package: its dependencies first, each to an artifact, then the
   package itself against those artifacts rather than against their source. *)

open Bootstrap

let target_dir root = Filename.concat root "target"
let debug_dir root = Filename.concat (target_dir root) "debug"
let artifact_path root name = Filename.concat (debug_dir root) (name ^ Artifact.extension)

let ensure dir = if not (Sys.file_exists dir) then Sys.mkdir dir 0o755

(* Every source file in the package, so the artifact holds all of it. *)
let rec walk dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun entry ->
    let path = Filename.concat dir entry in
    if Sys.is_directory path
    then walk path
    else if Filename.check_suffix entry ".cx"
    then [ path ]
    else [])

let sources root =
  let src = Filename.concat root "src" in
  if Sys.file_exists src && Sys.is_directory src then walk src else []

(* A test file is not a source file: it is compiled against the package's
   artifact rather than into it, so `sources` must not see it and an artifact
   never carries one. *)
let tests root =
  let dir = Filename.concat root "tests" in
  if Sys.file_exists dir && Sys.is_directory dir then walk dir else []

let manifest_of root =
  Manifest.load (Filename.concat root Manifest.file_name)

let missing root =
  [ Diagnostic.at
      Diagnostic.Manifest
      Source_map.Span.nowhere
      (Printf.sprintf "'%s' has no src/main.cx or src/lib.cx." root)
  ]

(* Depth first, so a dependency is compiled before whoever needs it, and a
   package reached twice through a diamond is compiled once. *)
let profile = "debug"

(* Three flags on two axes, not two points on one. `--locked` says nothing
   about the network and `--offline` says nothing about the lockfile;
   `--frozen` is both, and is the one CI types. *)
type mode =
  { locked : bool
  ; offline : bool
  }

let unrestricted = { locked = false; offline = false }

(* Resolution, and the lockfile it either writes or is held to. *)
let lock ~mode root =
  let pinned =
    match Lockfile.read root with
    | Some text -> Lockfile.pins text
    | None -> []
  in
  match Resolution.resolve ~pinned root with
  | Error errors -> Error errors
  | Ok resolution ->
    let rendered = Lockfile.render resolution in
    let existing = Lockfile.read root in
    let refuse message =
      Error [ Diagnostic.at Diagnostic.Manifest Source_map.Span.nowhere message ]
    in
    (match mode.locked, existing with
     | true, None ->
       refuse
         "--locked was given and there is no cronyx.lock. Run `cx build` once without it, and \
          check the lockfile in."
     | true, Some current when not (String.equal current rendered) ->
       refuse
         "--locked was given and the lockfile would change. Run `cx build` without it to see \
          what moved."
     | true, Some _ -> Ok resolution
     | false, Some current when String.equal current rendered -> Ok resolution
     | false, _ ->
       Lockfile.write root rendered;
       Ok resolution)

(* [compiled] names the packages this build actually ran the compiler over, so
   that "nothing to do" is something a caller can see rather than infer from a
   clock. *)
(* Where a registry dependency was unpacked. Resolution decided the version and
   verified the archive; this is only the directory it landed in. *)
let rec compile ~out ~built ~compiled ~located root
  : (Artifact.t list, Diagnostic.error list) result
  =
  let ( let* ) = Result.bind in
  let* manifest = manifest_of root in
  match Hashtbl.find_opt built manifest.Manifest.name with
  | Some existing -> Ok existing
  | None ->
    let* dependencies =
      List.fold_left
        (fun acc (d : Manifest.dependency) ->
          let* acc = acc in
          match d.Manifest.source with
          | Manifest.Path path ->
            let* transitive =
              compile ~out ~built ~compiled ~located (Filename.concat root path)
            in
            Ok (acc @ transitive)
          | Manifest.Registry _ ->
            (match located d.Manifest.name with
             | None ->
               Error
                 [ Diagnostic.at
                     Diagnostic.Manifest
                     d.Manifest.span
                     (Printf.sprintf "'%s' was not resolved." d.Manifest.name)
                 ]
             | Some dir ->
               let* transitive = compile ~out ~built ~compiled ~located dir in
               Ok (acc @ transitive)))
        (Ok [])
        manifest.Manifest.dependencies
    in
    let artifact_for name =
      List.find_opt (fun (a : Artifact.t) -> String.equal a.Artifact.package name) dependencies
    in
    let deps =
      List.map
        (fun (d : Manifest.dependency) ->
          let dep_root =
            match d.Manifest.source with
            | Manifest.Path path -> Filename.concat root path
            | Manifest.Registry _ -> Option.value (located d.Manifest.name) ~default:root
          in
          d.Manifest.name, { Loader.dep_root; compiled = artifact_for d.Manifest.name })
        manifest.Manifest.dependencies
    in
    let roots = { Loader.package = root; std = Toolchain.stdlib (); deps } in
    let path = artifact_path root manifest.Manifest.name in
    let dependency_prints =
      List.map (fun (d : Artifact.t) -> d.Artifact.fingerprint) dependencies
    in
    (* An artifact is still good when everything it read still hashes to what it
       hashed then, and when the files it would read now are the same ones. The
       second half is what catches a source file added since: its own digest
       would be missing from the list rather than different. *)
    let fresh =
      match Artifact.load path with
      | Error _ -> None
      | Ok artifact ->
        let declared =
          Filename.concat root Manifest.file_name :: sources root |> List.sort String.compare
        in
        let recorded = List.map (fun (i : Artifact.input) -> i.Artifact.path) artifact.Artifact.inputs in
        let unchanged =
          List.for_all
            (fun (i : Artifact.input) ->
              match Artifact.digest_of i.Artifact.path with
              | Some digest -> String.equal digest i.Artifact.digest
              | None -> false)
            artifact.Artifact.inputs
        in
        let same_files =
          List.for_all (fun declared -> List.mem declared recorded) declared
        in
        let same_graph =
          String.equal
            artifact.Artifact.fingerprint
            (Artifact.fingerprint_of
               ~compiler:Release.version
               ~profile
               ~inputs:artifact.Artifact.inputs
               ~dependencies:dependency_prints)
        in
        if unchanged && same_files && same_graph then Some artifact else None
    in
    (match fresh with
     | Some artifact ->
       let all = dependencies @ [ artifact ] in
       Hashtbl.replace built manifest.Manifest.name all;
       Ok all
     | None ->
       (match Workspace.entry_of root with
        | None -> Error (missing root)
        | Some entry ->
       Inputs.reset ();
       let* program, units =
         Pipeline.package
           ~roots
           ~entry_namespace:manifest.Manifest.name
           ~seeds:(sources root)
           entry
       in
       let inputs =
         Artifact.inputs_of
           ((Filename.concat root Manifest.file_name :: sources root) @ Inputs.taken ())
       in
       let artifact =
         { Artifact.compiler = Release.version
         ; package = manifest.Manifest.name
         ; units
         ; program
         ; inputs
         ; fingerprint =
             Artifact.fingerprint_of
               ~compiler:Release.version
               ~profile
               ~inputs
               ~dependencies:dependency_prints
         }
       in
       ensure (target_dir root);
       ensure (debug_dir root);
       Artifact.save path artifact;
       compiled := manifest.Manifest.name :: !compiled;
       let all = dependencies @ [ artifact ] in
       Hashtbl.replace built manifest.Manifest.name all;
       Ok all))

(* Built from the package root, so every path an artifact carries is relative to
   it. Two copies of one tree then compile to the same bytes, which is what
   makes an artifact a function of its inputs rather than of its address. *)
let materialize (resolution : Resolution.t) =
  let ( let* ) = Result.bind in
  let* pairs =
    List.fold_left
      (fun acc (p : Resolution.entry) ->
        let* acc = acc in
        match p.Resolution.source with
        | Resolution.Path _ -> Ok acc
        | Resolution.From_registry checksum ->
          (match Registry_source.root () with
           | None ->
             Error
               [ Diagnostic.at
                   Diagnostic.Manifest
                   Source_map.Span.nowhere
                   "No registry is configured. Set CRONYX_REGISTRY."
               ]
           | Some registry ->
             let release =
               { Registry_source.version = p.Resolution.version
               ; checksum
               ; yanked = false
               ; requirements = []
               }
             in
             let* dir = Registry_source.fetch registry p.Resolution.name release in
             Ok ((p.Resolution.name, dir) :: acc)))
      (Ok [])
      resolution.Resolution.packages
  in
  Ok (fun name -> List.assoc_opt name pairs)

(* Every path an artifact carries is relative to the root it was built from,
   so a meta block reading a file, which runs when the program is put
   together, has to run from there too. *)
let within root f =
  let here = Sys.getcwd () in
  Sys.chdir root;
  Fun.protect ~finally:(fun () -> Sys.chdir here) f

let package ?(mode = unrestricted) ~out root =
  let compiled = ref [] in
  within root (fun () ->
      (* Resolution first: the lockfile is what says the graph is what it was,
         and a build that disagreed with it would be building something else. *)
      match lock ~mode "." with
      | Error errors -> Error errors
      | Ok resolution ->
        (* Fetched and verified before anything is compiled, so a bad archive is
           an error about the archive rather than about the code in it. *)
        (match materialize resolution with
         | Error errors -> Error errors
         | Ok located ->
           (match compile ~out ~built:(Hashtbl.create 8) ~compiled ~located "." with
            | Error errors -> Error errors
            | Ok artifacts -> Ok (artifacts, List.rev !compiled))))

(* Each package embeds whatever of the standard library it imported, since the
   library is not itself compiled to an artifact yet. Two of them embedding the
   same module declare it twice, so the link keeps the first of each name. *)
let link (artifacts : Artifact.t list) =
  let seen = Hashtbl.create 256 in
  List.concat_map (fun (a : Artifact.t) -> a.Artifact.program) artifacts
  |> List.filter (fun (s : Ast.stmt) ->
    match Loader.declared_name s with
    | None -> true
    | Some name ->
      if Hashtbl.mem seen name
      then false
      else (
        Hashtbl.replace seen name ();
        true))
