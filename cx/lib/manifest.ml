(* `cronyx.toml`, read into what the rest of the tool needs from it. A key the
   schema does not know is an error rather than a silent skip: a manifest that
   ignores what it does not understand is how a typo becomes a support
   burden. *)

open Bootstrap

type source =
  | Path of string * Requirement.t option
  | Registry of Requirement.t

type dependency =
  { name : string
  ; source : source
  ; span : Source_map.Span.t
  }

type t =
  { name : string
  ; version : Version.t
  ; cronyx : Version.t
  ; dependencies : dependency list
  ; root : string
  }

let file_name = "cronyx.toml"

exception Failed of Diagnostic.error

let fail span fmt =
  Printf.ksprintf
    (fun message -> raise (Failed (Diagnostic.at Diagnostic.Manifest span message)))
    fmt

let required entries key span what =
  match Toml.find entries key with
  | Some entry -> entry
  | None -> fail span "%s needs a '%s' key." what key

let as_string (entry : Toml.entry) =
  match entry.node.Toml.value with
  | Toml.String s -> s
  | other -> fail entry.node.Toml.span "'%s' must be a string, not %s." entry.key (Toml.kind other)

let as_table (entry : Toml.entry) =
  match entry.node.Toml.value with
  | Toml.Table entries -> entries
  | other -> fail entry.node.Toml.span "'%s' must be a table, not %s." entry.key (Toml.kind other)

let version_of (entry : Toml.entry) =
  match Version.of_string (as_string entry) with
  | Ok v -> v
  | Error message -> fail entry.node.Toml.span "%s" message

let reject_unknown ~what ~known entries =
  List.iter
    (fun (e : Toml.entry) ->
      if not (List.mem e.Toml.key known)
      then
        fail
          e.Toml.key_span
          "%s has no '%s' key. It takes %s."
          what
          e.Toml.key
          (String.concat ", " known))
    entries

let name_problem name =
  if String.equal name ""
  then Some "A package name may not be empty."
  else if
    not
      (String.for_all
         (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true | _ -> false)
         name)
  then Some (Printf.sprintf "'%s' is not a package name: letters, digits, '-' and '_' only." name)
  else None

let package_name span name =
  match name_problem name with
  | Some problem -> fail span "%s" problem
  | None -> name

let requirement_of (entry : Toml.entry) written =
  match Requirement.of_string written with
  | Ok requirement -> requirement
  | Error message -> fail entry.Toml.node.Toml.span "%s" message

(* `http = "1.4"` is a registry requirement and `{ path = … }` is a directory.
   A table naming both is how a package depends on a local checkout while still
   publishing a version, which `cx publish` requires. *)
let dependency (entry : Toml.entry) =
  let span = entry.Toml.node.Toml.span in
  let name = package_name entry.Toml.key_span entry.Toml.key in
  if String.equal name "std"
  then
    fail
      entry.Toml.key_span
      "'std' is the standard library, which ships with the toolchain. A dependency may not take the name.";
  match entry.Toml.node.Toml.value with
  | Toml.Table fields ->
    reject_unknown
      ~what:(Printf.sprintf "Dependency '%s'" name)
      ~known:[ "path"; "version" ]
      fields;
    (match Toml.find fields "path", Toml.find fields "version" with
     | Some path, version ->
       let version = Option.map (fun v -> requirement_of v (as_string v)) version in
       { name; source = Path (as_string path, version); span }
     | None, Some version ->
       { name; source = Registry (requirement_of version (as_string version)); span }
     | None, None ->
       fail span "Dependency '%s' needs a 'path' or a 'version'." name)
  | Toml.String written -> { name; source = Registry (requirement_of entry written); span }
  | other -> fail span "Dependency '%s' must be a table, not %s." name (Toml.kind other)

let of_file file =
  match Toml.parse file with
  | Error e -> Error [ Diagnostic.at Diagnostic.Manifest e.Toml.span e.Toml.message ]
  | Ok entries ->
    let path = Source_map.File.path file in
    let whole = Source_map.Span.of_range file ~lo:0 ~hi:0 in
    (match
       reject_unknown ~what:"A manifest" ~known:[ "package"; "dependencies" ] entries;
       let package_entry = required entries "package" whole "A manifest" in
       let package = as_table package_entry in
       reject_unknown
         ~what:"[package]"
         ~known:[ "name"; "version"; "cronyx" ]
         package;
       let span_of key =
         match Toml.find package key with
         | Some e -> e.Toml.node.Toml.span
         | None -> whole
       in
       let name_entry = required package "name" (span_of "name") "[package]" in
       let name = package_name name_entry.Toml.node.Toml.span (as_string name_entry) in
       let version = version_of (required package "version" whole "[package]") in
       let cronyx = version_of (required package "cronyx" whole "[package]") in
       let dependencies =
         match Toml.find entries "dependencies" with
         | None -> []
         | Some entry -> List.map dependency (as_table entry)
       in
       { name
       ; version
       ; cronyx
       ; dependencies
       ; root = Filename.dirname path
       }
     with
     | manifest -> Ok manifest
     | exception Failed e -> Error [ e ])

let load path =
  match Source_map.File.load path with
  | Error message ->
    Error [ Diagnostic.at Diagnostic.Manifest Source_map.Span.nowhere message ]
  | Ok file -> of_file file

(* The package root is the nearest ancestor holding a manifest, which is also
   what dispatch walks for. *)
let find_root from =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir file_name)
    then Some dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else up parent)
  in
  up (if Sys.file_exists from && Sys.is_directory from then from else Filename.dirname from)
