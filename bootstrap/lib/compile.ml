(* The passes after metaprocessing, in their order. The walk leaves a program,
   or a meta block, checked and resolved, and [back] takes it from there. *)

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

let verify (p : Ast.resolved_stmt list) : (unit, Diagnostic.error list) result =
  match Verify.program p with
  | Ok () -> Ok ()
  | Error e -> Diagnostic.one Diagnostic.Verify e.Verify.span e.Verify.message

(* What follows the walk, which leaves a program checked, monomorphic and
   resolved. *)
let back (resolved : Ast.resolved_stmt list) : (Ast.resolved_stmt list, Diagnostic.error list) result =
  let* () = verify resolved in
  Ok resolved

(* A meta block's program is the declarations it reaches, [shared], which the
   next block mostly reaches too, then its own statements. [shared] is verified
   again only when it is not, statement by statement, the list verified last. *)
let verified_shared : Ast.resolved_stmt list option ref = ref None

let back_sharing ~shared ~own : (Ast.resolved_stmt list, Diagnostic.error list) result =
  let* () =
    match !verified_shared with
    | Some previous when List.length previous = List.length shared && List.for_all2 ( == ) previous shared ->
      Ok ()
    | _ ->
      let* () = verify shared in
      verified_shared := Some shared;
      Ok ()
  in
  let* () = verify own in
  Ok (shared @ own)

(* The exit code the program ended with: 0 unless it asked for another. *)
let run env (converted : Ast.resolved_stmt list) : (int, Diagnostic.error) result =
  match Interp.run env converted with
  | Ok code -> Ok code
  | Error e -> Error (Diagnostic.at Diagnostic.Runtime e.Value.span e.Value.message)
