(* Talking to a registry. The index says which versions exist and what each one
   requires; the store holds the archives. Both are reached through a root that
   is a directory today and a URL when there is a server -- the client's job is
   the same either way, which is why the checksum, the cache and the yank rules
   live here rather than waiting on the transport. *)

open Bootstrap

let root () =
  match Sys.getenv_opt "CRONYX_REGISTRY" with
  | Some "" | None -> None
  | Some dir -> Some dir

let index root = Filename.concat root "index"
let store root = Filename.concat root "store"
let release_path root name version = Filename.concat (Filename.concat (index root) name) (version ^ ".toml")
let archive_path root name version =
  Filename.concat (store root) (Printf.sprintf "%s-%s.cxar" name version)

type release =
  { version : Version.t
  ; checksum : string
  ; yanked : bool
  ; requirements : (string * Requirement.t) list
  }

let fail message = Error [ Diagnostic.at Diagnostic.Manifest Source_map.Span.nowhere message ]

let read_release root name version =
  let path = release_path root name version in
  match Source_map.File.load path with
  | Error _ -> fail (Printf.sprintf "'%s' has no release %s in the index." name version)
  | Ok file ->
    (match Toml.parse file with
     | Error e -> fail (Printf.sprintf "%s: %s" path e.Toml.message)
     | Ok entries ->
       let string_at key =
         match Toml.find entries key with
         | Some { Toml.node = { Toml.value = Toml.String s; _ }; _ } -> Some s
         | _ -> None
       in
       let requirements =
         match Toml.find entries "dependencies" with
         | Some { Toml.node = { Toml.value = Toml.Table fields; _ }; _ } ->
           List.filter_map
             (fun (e : Toml.entry) ->
               match e.Toml.node.Toml.value with
               | Toml.String written ->
                 (match Requirement.of_string written with
                  | Ok requirement -> Some (e.Toml.key, requirement)
                  | Error _ -> None)
               | _ -> None)
             fields
         | _ -> []
       in
       (match Version.of_string version, string_at "checksum" with
        | Ok version, Some checksum ->
          Ok
            { version
            ; checksum
            ; yanked =
                (match Toml.find entries "yanked" with
                 | Some { Toml.node = { Toml.value = Toml.Bool b; _ }; _ } -> b
                 | _ -> false)
            ; requirements
            }
        | _ -> fail (Printf.sprintf "'%s' %s is not a usable release." name version)))

(* Newest first, which is the order a resolver wants to try them in. *)
let releases root name =
  let dir = Filename.concat (index root) name in
  if not (Sys.file_exists dir)
  then Ok []
  else (
    let versions =
      Sys.readdir dir
      |> Array.to_list
      |> List.filter (fun entry -> Filename.check_suffix entry ".toml")
      |> List.map Filename.remove_extension
    in
    List.fold_left
      (fun acc version ->
        match acc with
        | Error e -> Error e
        | Ok acc ->
          (match read_release root name version with
           | Error e -> Error e
           | Ok release -> Ok (release :: acc)))
      (Ok [])
      versions
    |> Result.map
         (List.sort (fun a b -> Version.compare b.version a.version)))

(* What this machine has fetched, laid out as a registry of its own: the index
   entries it read, and the source they describe unpacked one directory per
   name-version. An `--offline` resolution reads it with the same code that
   reads a registry. What a build reads is shared, and what it writes is not. *)
let cache () = Filename.concat (Home.root ()) "registry"

let cached name version =
  Filename.concat
    (cache ())
    (Filename.concat "src" (Printf.sprintf "%s-%s" name (Version.to_string version)))

let remember root name version =
  let copy = release_path (cache ()) name version in
  if not (Sys.file_exists copy)
  then (
    match In_channel.with_open_bin (release_path root name version) In_channel.input_all with
    | exception Sys_error _ -> ()
    | text ->
      Home.ensure (Filename.dirname copy);
      Out_channel.with_open_bin copy (fun out -> Out_channel.output_string out text))

(* [registry] is [None] offline, when the cache is all there is. [expected_by]
   names where [checksum] came from, which is what a mismatch has to say. *)
let fetch ~registry ~checksum ~expected_by name version =
  let shown = Version.to_string version in
  let target = cached name version in
  match registry with
  | None ->
    if Sys.file_exists target
    then Ok target
    else
      fail
        (Printf.sprintf
           "%s %s is not in the cache, and --offline was given. Build once without --offline \
            to fetch it."
           name
           shown)
  | Some root when Sys.file_exists target ->
    remember root name shown;
    Ok target
  | Some root ->
    let path = archive_path root name shown in
    (match In_channel.with_open_bin path In_channel.input_all with
     | exception Sys_error _ ->
       fail (Printf.sprintf "The registry has no archive for %s %s." name shown)
     | text ->
       (* Before anything is unpacked, let alone compiled: a registry that serves
          different bytes for a version it has already served is a bug the client
          is supposed to catch. *)
       let actual = Archive.checksum text in
       if not (String.equal actual checksum)
       then
         fail
           (Printf.sprintf
              "%s %s does not match its checksum.\n\
              \  ─ %s expects %s\n\
              \  ─ the registry served %s"
              name
              shown
              expected_by
              checksum
              actual)
       else (
         match Archive.unpack text with
         | Error message -> fail (Printf.sprintf "%s %s: %s." name shown message)
         | Ok files ->
           Home.ensure target;
           Archive.into_directory target files;
           remember root name shown;
           Ok target))
