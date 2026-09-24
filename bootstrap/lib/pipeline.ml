(* [Compile] holds everything from `Desugar` on, because metaprocessing needs
   that much and cannot reach this module. What is left here happens on surface
   syntax: reading the files and running the meta blocks in them. *)

let ( let* ) = Result.bind

(* One package: its own units, loaded. A dependency of it arrives as an
   artifact and is not read here. Nothing is metaprocessed yet: which copy of a
   package's template exists is decided by whatever program uses it. *)
let package ?roots ?entry_namespace ?seeds path
  : (Ast.program * Artifact.unit_interface list, Diagnostic.error list) result
  =
  match Loader.package ?roots ?entry_namespace ?seeds path with
  | linked -> Ok linked
  | exception Loader.Failed e -> Diagnostic.one Diagnostic.Load e.Loader.span e.Loader.message

(* A whole program, from its roots. [on_code] sees it once this is done. *)
let metaprocess ?(on_code = fun _ -> ()) ~out program =
  match Metaprocess.program ~out program with
  | Ok processed ->
    on_code processed;
    Ok processed
  | Error e -> Diagnostic.one Diagnostic.Meta e.Metaprocess.span e.Metaprocess.message

let key (e : Diagnostic.error) = Ast.locate ~entry:"" e.Diagnostic.span, e.Diagnostic.message

(* What the check before the walk found, beside what the full check did. *)
let merged early late =
  match late, early with
  | Ok converted, [] -> Ok converted
  | Ok _, early -> Error early
  | Error late, early ->
    let seen = List.map key late in
    Error (late @ List.filter (fun e -> not (List.mem (key e) seen)) early)

(* Checked twice: first everything, reached or not, with what meta blocks
   produce unknown; then what the walk emitted, fully. An error the first finds
   in code the walk never reaches is reported all the same. *)
let whole ?on_code ?on_types ~out program =
  let early = Precheck.program program in
  merged
    early
    (let* processed = metaprocess ?on_code ~out program in
     Compile.program ?on_types processed)

(* A test run: what carries [attribute] is a root, and [wrap] finds the tests
   on what the walk produced — generated ones included, under the names the
   walk gave them — and says how each is run. *)
let rooted ~attribute ~wrap ~out program =
  let early = Precheck.program program in
  merged
    early
    (let* processed =
       match Metaprocess.program ~rooted_by:attribute ~out program with
       | Ok processed -> Ok processed
       | Error e -> Diagnostic.one Diagnostic.Meta e.Metaprocess.span e.Metaprocess.message
     in
     let* runs = wrap processed in
     Compile.program (processed @ runs))

(* Artifacts concatenated: every package's declarations, none metaprocessed. *)
let linked = whole

let front ?on_code ?roots ~out path : (Ast.program, Diagnostic.error list) result =
  let* loaded, _ = package ?roots path in
  metaprocess ?on_code ~out loaded

let compile ?on_code ?on_types ?roots ~out path
  : (Ast.cps_stmt list, Diagnostic.error list) result
  =
  let* loaded, _ = package ?roots path in
  whole ?on_code ?on_types ~out loaded

let run = Compile.run
