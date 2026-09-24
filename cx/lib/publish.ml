(* Putting a package into a registry, and the rules that make what comes back
   out trustworthy: a published version is immutable, what ships is what
   `Archive.of_directory` declares rather than whatever happened to be in the
   directory, and what ships has been built before it is published. *)

open Bootstrap

let fail message = Error [ Diagnostic.at Diagnostic.Manifest Source_map.Span.nowhere message ]

(* A `path` dependency means nothing to whoever downloads this, so it has to
   carry a version as well -- and then the version is what the published
   manifest records. *)
let publishable (m : Manifest.t) =
  match
    List.find_opt
      (fun (d : Manifest.dependency) ->
        match d.Manifest.source with
        | Manifest.Path (_, None) -> true
        | Manifest.Path (_, Some _) | Manifest.Registry _ -> false)
      m.Manifest.dependencies
  with
  | None -> Ok ()
  | Some d ->
    Error
      [ Diagnostic.at
          Diagnostic.Manifest
          d.Manifest.span
          (Printf.sprintf
             "'%s' is a `path` dependency, which means nothing to anyone who downloads this. Give \
              it a version as well, as in `{ path = \"…\", version = \"…\" }`, or drop it before \
              publishing."
             d.Manifest.name)
      ]

let requirements (m : Manifest.t) =
  List.filter_map
    (fun (d : Manifest.dependency) ->
      match d.Manifest.source with
      | Manifest.Registry requirement | Manifest.Path (_, Some requirement) ->
        Some (d.Manifest.name, requirement)
      | Manifest.Path (_, None) -> None)
    m.Manifest.dependencies
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let dependencies_toml m =
  match requirements m with
  | [] -> ""
  | requirements ->
    "\n[dependencies]\n"
    ^ String.concat
        ""
        (List.map
           (fun (name, requirement) ->
             Printf.sprintf "%s = \"%s\"\n" name (Requirement.to_string requirement))
           requirements)

let release_toml (m : Manifest.t) ~checksum =
  Printf.sprintf "checksum = \"%s\"\nyanked = false\n%s" checksum (dependencies_toml m)

(* What a consumer reads is a registry package, so a dependency that is a path
   here has to be the version it was published with there. A manifest with no
   path in it ships as written. *)
let shipped_manifest (m : Manifest.t) files =
  if
    not
      (List.exists
         (fun (d : Manifest.dependency) ->
           match d.Manifest.source with
           | Manifest.Path _ -> true
           | Manifest.Registry _ -> false)
         m.Manifest.dependencies)
  then files
  else (
    let rewritten =
      Printf.sprintf
        "[package]\nname    = \"%s\"\nversion = \"%s\"\ncronyx  = \"%s\"\n%s"
        m.Manifest.name
        (Version.to_string m.Manifest.version)
        (Version.to_string m.Manifest.cronyx)
        (dependencies_toml m)
    in
    List.map
      (fun (path, contents) ->
        if String.equal path Manifest.file_name then path, rewritten else path, contents)
      files)

let rec remove path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> remove (Filename.concat path entry)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path

(* Built from an unpacked copy of the archive rather than from the directory, so
   what is checked is what a consumer will get: a file the archive leaves out,
   or a path dependency that has no published version to stand in for it,
   fails here rather than downstream. *)
let verify ?note root ~name ~version files =
  let staged =
    Filename.concat (Build.target_dir root) (Filename.concat "package" (name ^ "-" ^ version))
  in
  remove staged;
  Home.ensure staged;
  Archive.into_directory staged files;
  Result.map ignore (Build.package ?note ~out:ignore staged)

let publish ?note root =
  let ( let* ) = Result.bind in
  match Registry_source.root () with
  | None -> fail "No registry is configured. Set CRONYX_REGISTRY."
  | Some registry ->
    let* manifest = Manifest.load (Filename.concat root Manifest.file_name) in
    let* () = publishable manifest in
    let name = manifest.Manifest.name in
    let version = Version.to_string manifest.Manifest.version in
    let release = Registry_source.release_path registry name version in
    (* Once a version exists, it is what it is: a registry that could serve
       different bytes for one version is a registry nothing can be pinned
       against. *)
    if Sys.file_exists release
    then fail (Printf.sprintf "%s %s is already published." name version)
    else (
      let files = shipped_manifest manifest (Archive.of_directory root) in
      let* () = verify ?note root ~name ~version files in
      let archive = Archive.pack files in
      let checksum = Archive.checksum archive in
      Home.ensure (Filename.dirname release);
      Home.ensure (Registry_source.store registry);
      Out_channel.with_open_bin
        (Registry_source.archive_path registry name version)
        (fun out -> Out_channel.output_string out archive);
      Out_channel.with_open_bin release (fun out ->
        Out_channel.output_string out (release_toml manifest ~checksum));
      Ok (name, version, checksum))
