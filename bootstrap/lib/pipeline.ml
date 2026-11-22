(* [Compile] holds everything from the check on, because metaprocessing needs
   that much and cannot reach this module. What is left here happens on surface
   syntax: reading the files and running the meta blocks in them. *)

let ( let* ) = Result.bind

(* One package: its own units, loaded. A dependency of it arrives as an
   artifact and is not read here. Nothing is metaprocessed yet: which instances of
   a package's comptime functions exist is decided by whatever program uses it. *)
let package ?roots ?entry_namespace ?seeds path
  : (Ast.program * Artifact.unit_interface list, Diagnostic.error list) result
  =
  match Loader.package ?roots ?entry_namespace ?seeds path with
  | linked -> Ok linked
  | exception Loader.Failed e -> Diagnostic.one Diagnostic.Load e.Loader.span e.Loader.message

(* The standard library, which is not a package and has no entry: a set of
   modules, loaded for what they declare. *)
let library ?roots ~package paths
  : (Ast.program * Artifact.unit_interface list, Diagnostic.error list) result
  =
  match Loader.library ?roots ~package paths with
  | linked -> Ok linked
  | exception Loader.Failed e -> Diagnostic.one Diagnostic.Load e.Loader.span e.Loader.message

(* A whole program, from its roots, checked as it is walked. [on_code] sees
   it once this is done. *)
let metaprocess ?(on_code = fun _ -> ()) ~out program =
  match Metaprocess.program ~out program with
  | Ok processed ->
    on_code processed;
    Ok processed
  | Error errors -> Error errors

let key (e : Diagnostic.error) = Ast.locate ~entry:"" e.Diagnostic.span

(* What the check before the walk found, beside what the walk did. The walk
   checks at a key, so where both report one place, its account is the one
   that knows the types. *)
let merged early late =
  match late, early with
  | Ok converted, [] -> Ok converted
  | Ok _, early -> Error early
  | Error late, early ->
    let seen = List.map key late in
    Error (late @ List.filter (fun e -> not (List.mem (key e) seen)) early)

(* Checked twice: first everything, reached or not, with what meta blocks
   produce unknown; then as the walk reaches it. An error the first finds in
   code the walk never reaches is reported all the same. *)
let whole ?on_code ?(on_types = fun _ -> ()) ~out program =
  let early = Precheck.program program in
  merged
    early
    (let* processed = metaprocess ?on_code ~out program in
     on_types processed;
     Compile.back processed)

(* Artifacts concatenated: every package's declarations, none metaprocessed. *)
let linked = whole

let front ?on_code ?roots ~out path : (Ast.resolved_stmt list, Diagnostic.error list) result =
  let* loaded, _ = package ?roots path in
  metaprocess ?on_code ~out loaded

let compile ?on_code ?on_types ?roots ~out path
  : (Ast.resolved_stmt list, Diagnostic.error list) result
  =
  let* loaded, _ = package ?roots path in
  whole ?on_code ?on_types ~out loaded

let run = Compile.run
