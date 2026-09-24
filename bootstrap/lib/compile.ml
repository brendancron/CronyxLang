(* Desugar through Verify. Metaprocessing calls this on each block and the
   driver on the whole program, so the pass order lives here and nowhere
   else. *)

let ( let* ) = Result.bind

(* The checker reports every statement it could not check. Every other pass
   stops at one. *)
let program ?(on_types = fun _ -> ()) (source : Ast.program)
  : (Ast.cps_stmt list, Diagnostic.error list) result
  =
  let* desugared =
    match Desugar.program (Prelude.program () @ source) with
    | Ok desugared -> Ok desugared
    | Error e -> Diagnostic.one Diagnostic.Desugar e.Desugar.span e.Desugar.message
  in
  let registry = Registry.builtins () in
  let* typed =
    match Typecheck.check ~registry desugared with
    | Ok typed -> Ok typed
    | Error [] ->
      Diagnostic.one Diagnostic.Type Source_map.Span.nowhere "This does not check."
    | Error errors ->
      Error
        (List.map
           (fun (e : Typecheck.error) -> Diagnostic.at Diagnostic.Type e.Typecheck.span e.Typecheck.message)
           errors)
  in
  on_types typed;
  let* specialized =
    match Type_mono.program ~registry typed with
    | specialized -> Ok specialized
    | exception Type_mono.Diverged e ->
      Diagnostic.one Diagnostic.Type_mono e.Type_mono.span e.Type_mono.message
  in
  let* resolved =
    match Resolve.program ~registry specialized with
    | Ok resolved -> Ok resolved
    | Error e -> Diagnostic.one Diagnostic.Resolve e.Resolve.span e.Resolve.message
  in
  let* reflected =
    match Reflect.program resolved with
    | Ok reflected -> Ok reflected
    | Error e -> Diagnostic.one Diagnostic.Reflect e.Reflect.span e.Reflect.message
  in
  let* converted =
    match Cps.program reflected with
    | Ok converted -> Ok converted
    | Error e -> Diagnostic.one Diagnostic.Cps e.Cps.span e.Cps.message
  in
  let* () =
    match Verify.program converted with
    | Ok () -> Ok ()
    | Error e -> Diagnostic.one Diagnostic.Verify e.Verify.span e.Verify.message
  in
  Ok converted

let run env (converted : Ast.cps_stmt list) : (unit, Diagnostic.error) result =
  match Interp.run env converted with
  | Ok () -> Ok ()
  | Error e -> Error (Diagnostic.at Diagnostic.Runtime e.Value.span e.Value.message)
