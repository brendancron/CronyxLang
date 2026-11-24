(* `defer` as the statements it means: each deferred statement copied in front of
   every way out of its block, the latest first. A `defer` the effect transform
   kept is in code nothing splits, so leaving its block is plain control flow. *)

open Ast

type deferred =
  { body : resolved_stmt
  ; loops : int
  }

let rec holds_stmt (s : resolved_stmt) =
  match s.it with
  | `Defer _ -> true
  | `Expr e | `Var_tuple (_, e) | `Var_decl (_, _, Some e) | `Return (Some e) -> holds_expr e
  | `Block body | `Fn (_, _, _, body) -> List.exists holds_stmt body
  | `If (c, t, e) -> holds_expr c || holds_stmt t || Option.fold ~none:false ~some:holds_stmt e
  | `While (c, body) -> holds_expr c || holds_stmt body
  | `Match (subject, cases) -> holds_expr subject || List.exists (fun (_, b) -> List.exists holds_stmt b) cases
  | _ -> false

and holds_expr (e : resolved_expr) =
  match e.it with
  | `Lambda (_, _, body) -> List.exists holds_stmt body
  | _ ->
    let found = ref false in
    ignore
      (children
         (fun x ->
           if holds_expr x then found := true;
           x)
         e);
    !found

and children f (e : resolved_expr) : resolved_expr =
  let it : resolved_expr_kind =
    match e.it with
    | #lit as l -> l
    | #vars as v -> (map_vars f v :> resolved_expr_kind)
    | #ops as o -> (map_ops f o :> resolved_expr_kind)
    | #logic as l -> (map_logic f l :> resolved_expr_kind)
    | #tuple as t -> (map_tuple f t :> resolved_expr_kind)
    | #record as r -> (map_record f r :> resolved_expr_kind)
    | #arrays as a -> (map_arrays f a :> resolved_expr_kind)
    | #strings as s -> (map_strings f s :> resolved_expr_kind)
    | #variant_lit as v -> (map_variant_lit f v :> resolved_expr_kind)
    | #objects as o -> (map_object f o :> resolved_expr_kind)
    | `Lambda _ as l -> l
  in
  { e with it }

let rec leaves (s : resolved_stmt) =
  match s.it with
  | `Return _ | `Break | `Continue -> true
  | `Block body -> List.exists leaves body
  | `If (_, t, Some e) -> leaves t && leaves e
  | _ -> false

let copies (ds : deferred list) : resolved_stmt list = List.map (fun d -> d.body) ds

(* [active] holds the `defer`s in scope, the latest first; [loops] is how many
   loops of this function stand around the statement. *)
let rec stmt ~loops ~(active : deferred list) (s : resolved_stmt) : resolved_stmt =
  let block body = { s with it = `Block body } in
  match s.it with
  | `Return value when active <> [] ->
    (match value with
     | Some e ->
       let e = expr e in
       let held = Lower.fresh "returned" in
       block
         ({ s with it = `Var_decl (held, None, Some e); ann = Types.Unit }
          :: copies active
          @ [ { s with it = `Return (Some { e with it = `Var held }) } ])
     | None -> block (copies active @ [ s ]))
  | (`Break | `Continue) when List.exists (fun d -> d.loops = loops) active ->
    block (copies (List.filter (fun d -> d.loops = loops) active) @ [ s ])
  | _ when not (holds_stmt s || active <> []) -> s
  | _ ->
    let it : resolved_stmt_kind =
      match s.it with
      | `Expr e -> `Expr (expr e)
      | `Var_decl (n, ty, init) -> `Var_decl (n, ty, Option.map expr init)
      | `Var_tuple (names, e) -> `Var_tuple (names, expr e)
      | `Return e -> `Return (Option.map expr e)
      | `Block body -> `Block (scope ~loops ~active body)
      | `If (c, t, e) -> `If (expr c, stmt ~loops ~active t, Option.map (stmt ~loops ~active) e)
      | `While (c, body) -> `While (expr c, stmt ~loops:(loops + 1) ~active body)
      | `Fn (name, params, sg, body) -> `Fn (name, params, sg, scope ~loops:0 ~active:[] body)
      | `Match (subject, cases) -> `Match (expr subject, List.map (fun (p, b) -> p, scope ~loops ~active b) cases)
      (* Alone where a statement stands, it is a block of its own, left at once. *)
      | `Defer _ -> `Block (scope ~loops ~active [ s ])
      | other -> other
    in
    { s with it }

and expr (e : resolved_expr) : resolved_expr =
  if not (holds_expr e)
  then e
  else (
    match e.it with
    | `Lambda (params, sg, body) -> { e with it = `Lambda (params, sg, scope ~loops:0 ~active:[] body) }
    | _ -> children expr e)

and scope ~loops ~active (body : resolved_stmt list) : resolved_stmt list =
  let rec go own = function
    | [] -> []
    | ({ it = `Defer d; _ } : resolved_stmt) :: rest ->
      (* What it defers is left only once it has run, so nothing in scope
         around it runs again inside it. *)
      let d = { body = stmt ~loops:0 ~active:[] d; loops } in
      let rest = go (d :: own) rest in
      (match List.rev rest with
       | last :: _ when leaves last -> rest
       | _ -> rest @ copies [ d ])
    | s :: rest -> stmt ~loops ~active:(own @ active) s :: go own rest
  in
  if List.exists holds_stmt body || active <> [] then go [] body else body

let program (p : resolved_stmt list) : resolved_stmt list =
  List.map (stmt ~loops:0 ~active:[]) p
