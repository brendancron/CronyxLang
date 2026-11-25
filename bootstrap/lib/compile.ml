(* The passes after metaprocessing, in their order. The walk leaves a program,
   or a meta block, checked and resolved, and [back] takes it from there. *)

let ( let* ) = Result.bind

let declared_root (p : Ast.program) =
  let rec root (s : Ast.stmt) =
    match s.Ast.it with
    | `Fn (name, _, _, _) when Ast.is_program_root name -> Some name
    | `Attributed (_, inner) -> root inner
    | _ -> None
  in
  List.find_map root p

let rec always_returns (s : Ast.stmt) =
  match s.Ast.it with
  | `Return _ -> true
  | `Block body -> List.exists always_returns body
  | `If (_, yes, Some no) -> always_returns yes && always_returns no
  | `Match (_, arms) -> arms <> [] && List.for_all (fun (_, body) -> List.exists always_returns body) arms
  | `Attributed (_, inner) -> always_returns inner
  | _ -> false

(* The statements of the top level, in order, as `main`, the function handed to
   [root]: it returns the exit code, 0 unless a top-level `return` says
   otherwise. The call stands at the span of all of them, and each statement
   keeps its own, so an error still names the statement that caused it. *)
let root_call root (body : Ast.stmt list) : Ast.stmt =
  let span =
    List.fold_left (fun span (s : Ast.stmt) -> Source_map.Span.join span s.Ast.span) Source_map.Span.nowhere body
  in
  let status = Ast.at span (`Return (Some (Ast.at span (`Int 0)))) in
  let main : Ast.expr =
    Ast.at
      span
      (`Lambda
        ( []
        , { Ast.ret = Some (Ast.at span (Ast.Ty_name "Int")); row = None; static_params = []; inline = false }
        , if List.exists always_returns body then body else body @ [ status ] ))
  in
  Ast.at span (`Return (Some (Ast.at span (`Call (Ast.at span (`Var root), [ main ])))))

(* The whole top level under the root, for a check that sees the program at
   once and orders it by what each statement uses. A fragment without [root]
   -- a static argument checked on its own -- is left alone. *)
let under_root (p : Ast.program) : Ast.program =
  match declared_root p with
  | None -> p
  | Some root ->
    let declarations, statements = List.partition Loader.is_declaration p in
    if statements = [] then declarations else root_call root statements :: declarations

let verify ?monomorphized (p : Ast.resolved_stmt list) : (unit, Diagnostic.error list) result =
  match Verify.program ?monomorphized p with
  | Ok () -> Ok ()
  | Error e -> Diagnostic.one Diagnostic.Verify e.Verify.span e.Verify.message

(* What follows the walk, which leaves a program checked, monomorphic and
   resolved. *)
let back (resolved : Ast.resolved_stmt list) : (Ast.resolved_stmt list, Diagnostic.error list) result =
  let* () = verify ~monomorphized:true resolved in
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
  match Interp.run env (Defers.program converted) with
  | Ok code -> Ok code
  | Error e -> Error (Diagnostic.at Diagnostic.Runtime e.Value.span e.Value.message)
