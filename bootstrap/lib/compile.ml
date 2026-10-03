(* Desugar through Verify. Metaprocessing calls this on each block and the
   driver on the whole program, so the pass order lives here and nowhere
   else. *)

let ( let* ) = Result.bind

(* Each statement of the top level runs as a function handed to [root], in
   place, and a `var` is given what its initializer's function returns. In
   place, rather than moved into one function, so a statement is checked where
   it stands: a top-level function reading a `var` still meets it declared,
   with its annotation, and an error names the statement that caused it. A
   fragment without [root] -- a static argument checked on its own -- is left
   alone. *)
let under_root (p : Ast.program) : Ast.program =
  let rec declared_root (s : Ast.stmt) =
    match s.Ast.it with
    | `Fn (name, _, _, _) when Ast.is_root name -> Some name
    | `Attributed (_, inner) -> declared_root inner
    | _ -> None
  in
  match List.find_map declared_root p with
  | None -> p
  | Some root ->
    let under ?ret span (body : Ast.stmt list) : Ast.expr =
      let main : Ast.expr =
        Ast.at span (`Lambda ([], { Ast.ret; row = None; static_params = [] }, body))
      in
      Ast.at span (`Call (Ast.at span (`Var root), [ main ]))
    in
    (* At the initializer's own span, returning the `var`'s annotation, so the
       initializer is checked against it as it was before, and a mismatch
       names the initializer. *)
    let returning ?ret (e : Ast.expr) =
      under ?ret e.Ast.span [ Ast.at e.Ast.span (`Return (Some e)) ]
    in
    (* A `var` keeps what it carries, a doc comment included. *)
    let rec binding (s : Ast.stmt) : Ast.stmt option =
      let span = s.Ast.span in
      match s.Ast.it with
      | `Var_decl (_, _, None) -> Some s
      | `Var_decl (name, ty, Some init) ->
        Some (Ast.at span (`Var_decl (name, ty, Some (returning ?ret:ty init))))
      | `Var_tuple (names, init) -> Some (Ast.at span (`Var_tuple (names, returning init)))
      | `Attributed (attrs, inner) ->
        Option.map (fun inner -> Ast.at span (`Attributed (attrs, inner))) (binding inner)
      | _ -> None
    in
    List.map
      (fun (s : Ast.stmt) ->
        if Loader.is_declaration s
        then s
        else (
          match binding s with
          | Some s -> s
          | None -> Ast.at s.Ast.span (`Expr (under s.Ast.span [ s ]))))
      p

let program ?(on_types = fun _ -> ()) (source : Ast.program)
  : (Ast.cps_stmt list, Diagnostic.error list) result
  =
  let* desugared =
    match Desugar.program (under_root source) with
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
    | exception Type_mono.Failed e ->
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

(* The exit code the program ended with: 0 unless it asked for another. *)
let run env (converted : Ast.cps_stmt list) : (int, Diagnostic.error) result =
  match Interp.run env converted with
  | Ok code -> Ok code
  | Error e -> Error (Diagnostic.at Diagnostic.Runtime e.Value.span e.Value.message)
