(* A call of a function declared `inline`, or of a lambda written where it is
   called, replaced by the body it would run, in code already processed. *)

open Ast
module M = Map.Make (String)

let counter = ref 0

let is_fresh name = String.starts_with ~prefix:"inlined#" name

let fresh name =
  incr counter;
  let name =
    if is_fresh name
    then (
      match String.split_on_char '#' name with
      | _ :: base :: _ -> base
      | _ -> name)
    else name
  in
  generated [ "inlined"; name; string_of_int !counter ]

(* A renamed name is bound once; these are the ones also assigned. *)
let fresh_assigned : (string, unit) Hashtbl.t = Hashtbl.create 64

let children = Defers.children

let iter_children f (e : resolved_expr) =
  ignore
    (children
       (fun x ->
         f x;
         x)
       e)

let rec iter_expr ~expr ~stmt (e : resolved_expr) =
  expr e;
  match e.it with
  | `Lambda (_, _, body) -> List.iter (iter_stmt ~expr ~stmt) body
  | _ -> iter_children (iter_expr ~expr ~stmt) e

and iter_stmt ~expr ~stmt (s : resolved_stmt) =
  stmt s;
  let e = iter_expr ~expr ~stmt
  and st = iter_stmt ~expr ~stmt in
  match s.it with
  | `Expr x | `Var_tuple (_, x) | `Var_decl (_, _, Some x) | `Return (Some x) -> e x
  | `Var_decl (_, _, None) | `Return None | `Break | `Continue | `Type_decl _ -> ()
  | `Defer inner -> st inner
  | `Block body | `Fn (_, _, _, body) -> List.iter st body
  | `If (c, t, f) ->
    e c;
    st t;
    Option.iter st f
  | `While (c, body) ->
    e c;
    st body
  | `Match (subject, cases) ->
    e subject;
    List.iter (fun (_, body) -> List.iter st body) cases

let iter_body ?(expr = fun _ -> ()) ?(stmt = fun _ -> ()) body = List.iter (iter_stmt ~expr ~stmt) body

(* What a body binds, each name as often as it is bound; what it assigns; and
   every name it reads or writes. *)
type facts =
  { bound : (string, int) Hashtbl.t
  ; assigned : (string, unit) Hashtbl.t
  ; named : (string, unit) Hashtbl.t
  }

let facts body =
  let f = { bound = Hashtbl.create 32; assigned = Hashtbl.create 8; named = Hashtbl.create 32 } in
  let bind n = Hashtbl.replace f.bound n (1 + Option.value ~default:0 (Hashtbl.find_opt f.bound n)) in
  let params = List.iter (fun (p : param) -> bind p.name) in
  iter_body
    ~expr:(fun e ->
      match e.it with
      | `Var n -> Hashtbl.replace f.named n ()
      | `Assign (n, _) ->
        Hashtbl.replace f.named n ();
        Hashtbl.replace f.assigned n ()
      | `Lambda (ps, _, _) -> params ps
      | _ -> ())
    ~stmt:(fun s ->
      match s.it with
      | `Var_decl (n, _, _) -> bind n
      | `Var_tuple (ns, _) -> List.iter bind ns
      | `Fn (n, ps, _, _) ->
        bind n;
        params ps
      | `Match (_, cases) -> List.iter (fun (p, _) -> List.iter bind (pattern_names p)) cases
      | _ -> ())
    body;
  f

(* A function declared in the body is settled by its own type, not by its
   body's: that body can be generic in what its scheme quantifies, which no call
   of the outer body settles, as the copy a transform makes for a run is in the
   answer of a handler it is handed. *)
let closed body =
  let ok = ref true in
  let check t = if not (Types.closed t) then ok := false in
  let rec expr (e : resolved_expr) =
    check e.ann;
    match e.it with
    | `Lambda (_, _, body) -> List.iter stmt body
    | _ -> iter_children expr e
  and stmt (s : resolved_stmt) =
    check s.ann;
    match s.it with
    | `Expr x | `Var_tuple (_, x) | `Var_decl (_, _, Some x) | `Return (Some x) -> expr x
    | `Var_decl (_, _, None) | `Return None | `Break | `Continue | `Type_decl _ | `Fn _ -> ()
    | `Defer inner -> stmt inner
    | `Block body -> List.iter stmt body
    | `If (c, t, f) ->
      expr c;
      stmt t;
      Option.iter stmt f
    | `While (c, body) ->
      expr c;
      stmt body
    | `Match (subject, cases) ->
      expr subject;
      List.iter (fun (_, body) -> List.iter stmt body) cases
  in
  List.iter stmt body;
  !ok

(* Whether running the body could leave it other than by its end: a return,
   or a break or continue no loop of its own catches. Code under a lambda
   leaves only the lambda. *)
let rec leaves_stmt ~loops (s : resolved_stmt) =
  match s.it with
  | `Return _ -> true
  | `Break | `Continue -> loops = 0
  | `Block body -> List.exists (leaves_stmt ~loops) body
  | `If (_, t, f) -> leaves_stmt ~loops t || Option.fold ~none:false ~some:(leaves_stmt ~loops) f
  | `While (_, body) -> leaves_stmt ~loops:(loops + 1) body
  | `Match (_, cases) -> List.exists (fun (_, b) -> List.exists (leaves_stmt ~loops) b) cases
  | `Defer d -> leaves_stmt ~loops d
  | _ -> false

let holds pick body =
  let found = ref false in
  iter_body ~stmt:(fun s -> if pick s then found := true) body;
  !found

let declares_type =
  holds (fun s ->
    match s.it with
    | `Type_decl _ -> true
    | _ -> false)

(* A function inside is hoisted to the top of its block, and a `defer` is
   lowered by the block it stands in, so a body holding either keeps a block
   of its own. *)
let needs_block =
  holds (fun s ->
    match s.it with
    | `Fn _ | `Defer _ -> true
    | _ -> false)

let holds_declaration body = declares_type body || needs_block body

(* Every binder renamed afresh, scope by scope, so the body can stand inside
   any other without its names meeting that body's. *)
let rec rename_expr m (e : resolved_expr) : resolved_expr =
  let name n = Option.value ~default:n (M.find_opt n m) in
  match e.it with
  | `Var n -> { e with it = `Var (name n) }
  | `Assign (n, v) -> { e with it = `Assign (name n, rename_expr m v) }
  | `Lambda (ps, sg, body) ->
    let m, ps = rename_params m ps in
    { e with it = `Lambda (ps, sg, rename_block m body) }
  | _ -> children (rename_expr m) e

and rename_params m ps =
  List.fold_left_map
    (fun m (p : param) ->
      let n = fresh p.name in
      M.add p.name n m, { p with name = n })
    m
    ps

and rename_block m body =
  (* A function is visible across the whole of its block. *)
  let m =
    List.fold_left
      (fun m (s : resolved_stmt) ->
        match s.it with
        | `Fn (n, _, _, _) -> M.add n (fresh n) m
        | _ -> m)
      m
      body
  in
  let declared (s : resolved_stmt) =
    match s.it with
    | `Var_decl (n, _, _) -> [ n ]
    | `Var_tuple (ns, _) -> ns
    | _ -> []
  in
  (* A function is hoisted to the top of its block, so it reads a variable the
     block declares after it, as that stands when the function is called. *)
  let rec go m before = function
    | [] -> []
    | ((s : resolved_stmt), own) :: rest ->
      let m' = List.fold_left (fun m (n, n') -> M.add n n' m) m own in
      let before' = List.map fst own @ before in
      (match s.it with
       | `Var_decl (_, ty, init) ->
         let init = Option.map (rename_expr m) init in
         { s with it = `Var_decl (snd (List.hd own), ty, init) } :: go m' before' rest
       | `Var_tuple (_, init) ->
         let init = rename_expr m init in
         { s with it = `Var_tuple (List.map snd own, init) } :: go m' before' rest
       | `Fn _ ->
         let later =
           List.fold_left
             (fun m (n, n') -> if List.mem n before then m else M.add n n' m)
             m
             (List.concat_map snd rest)
         in
         rename_stmt later s :: go m before rest
       | _ -> rename_stmt m s :: go m before rest)
  in
  go m [] (List.map (fun s -> s, List.map (fun n -> n, fresh n) (declared s)) body)

and rename_stmt m (s : resolved_stmt) : resolved_stmt =
  let e = rename_expr m in
  let one st =
    match rename_block m [ st ] with
    | [ st ] -> st
    | body -> { st with it = `Block body }
  in
  let it : resolved_stmt_kind =
    match s.it with
    | `Expr x -> `Expr (e x)
    | `Return x -> `Return (Option.map e x)
    | `Block body -> `Block (rename_block m body)
    | `If (c, t, f) -> `If (e c, one t, Option.map one f)
    | `While (c, body) -> `While (e c, one body)
    | `Match (subject, cases) ->
      let case (p, body) =
        let renames = List.map (fun n -> n, fresh n) (pattern_names p) in
        let m = List.fold_left (fun m (n, n') -> M.add n n' m) m renames in
        let p =
          match p with
          | Pat_variant (t, v, payload) ->
            Pat_variant (t, v, map_payload (fun n -> List.assoc n renames) payload)
          | Pat_wild -> Pat_wild
        in
        p, rename_block m body
      in
      `Match (e subject, List.map case cases)
    | (`Var_decl _ | `Var_tuple _) as it -> `Block (rename_block m [ { s with it } ])
    | `Fn (n, ps, sg, body) ->
      let inner, ps = rename_params m ps in
      `Fn (Option.value ~default:n (M.find_opt n m), ps, sg, rename_block inner body)
    | `Defer d -> `Defer (one d)
    | other -> other
  in
  { s with it }

let rec subst_expr (m : resolved_expr M.t) (e : resolved_expr) : resolved_expr =
  match e.it with
  | `Var n ->
    (match M.find_opt n m with
     | Some (by : resolved_expr) ->
       (match by.it with
        | `Lambda _ -> by
        (* The argument's own place, so a failure in it points at the call. *)
        | it -> { e with it; span = by.span })
     | None -> e)
  | `Lambda (ps, sg, body) -> { e with it = `Lambda (ps, sg, List.map (subst_stmt m) body) }
  | _ -> children (subst_expr m) e

and subst_stmt m (s : resolved_stmt) : resolved_stmt =
  match s.it with
  | `Match (subject, cases) ->
    { s with it = `Match (subst_expr m subject, List.map (fun (p, b) -> p, List.map (subst_stmt m) b) cases) }
  | `Type_decl _ -> s
  | #stmts as st -> { s with it = (map_stmts (subst_expr m) (subst_stmt m) st :> resolved_stmt_kind) }

let uses name body =
  let n = ref 0 in
  iter_body
    ~expr:(fun e ->
      match e.it with
      | `Var v when String.equal v name -> incr n
      | _ -> ())
    body;
  !n

(* What a name called is: a function declared `inline` whose processed
   declaration is at hand, one that is declared `inline` but has none to give
   (with why), or anything else. *)
type found =
  | Ready of resolved_stmt
  | Unready of string
  | Not_inline

(* What the code around a call is: what it binds, which says what a body put
   there could capture, and which of the names it reads keep one value. *)
type scope =
  { facts : facts
  ; find : string -> found
  ; is_function : string -> bool
  ; (* The function whose body this is: a callee calling back into it names
       that function, not anything the body binds. *)
    own : string option
  }

let bound sc n = Hashtbl.mem sc.facts.bound n

let stable sc n =
  if is_fresh n
  then not (Hashtbl.mem fresh_assigned n)
  else
    (not (Hashtbl.mem sc.facts.assigned n))
    &&
    match Hashtbl.find_opt sc.facts.bound n with
    | Some 1 -> true
    | Some _ -> false
    | None -> sc.is_function n

let trivial sc (e : resolved_expr) =
  match e.it with
  | #lit -> true
  | `Var n -> stable sc n
  | _ -> false

(* What can run in either order with an argument: it neither has an effect nor
   can fail. *)
let rec pure (e : resolved_expr) =
  match e.it with
  | #lit | `Var _ | `Lambda _ -> true
  | `Binop ((Div | Mod), _, _) -> false
  | `Binop (_, a, b) | `And (a, b) | `Or (a, b) -> pure a && pure b
  | `Unop (_, a) | `Tuple_get (a, _) | `Field (a, _) | `Str_len a | `Array_len a -> pure a
  | `Tuple items | `Array_lit items -> List.for_all pure items
  | `Record_lit fields | `Variant (_, fields) -> List.for_all (fun (_, v) -> pure v) fields
  | _ -> false

(* Pure, and making nothing: read twice, it is still one value. *)
let rec readable (e : resolved_expr) =
  match e.it with
  | #lit | `Var _ -> true
  | `Binop ((Div | Mod), _, _) -> false
  | `Binop (_, a, b) -> readable a && readable b
  | `Unop (_, a) | `Tuple_get (a, _) | `Field (a, _) | `Str_len a | `Array_len a -> readable a
  | _ -> false

(* Whether [name] is read once, where it would be read every time the
   expression is: not under a lambda, nor on the side of `&&` or `||` that may
   not run. *)
(* Whether every read of [names] comes before anything that could change what
   it reads, in the order the interpreter evaluates. *)
let reads_first names (e : resolved_expr) =
  let changed = ref false
  and ok = ref true in
  let rec go (e : resolved_expr) =
    let all = List.iter go in
    match e.it with
    | `Var v -> if !changed && List.mem v names then ok := false
    | #lit | `Lambda _ -> ()
    | `Call (callee, args) ->
      go callee;
      all args;
      changed := true
    | `Dyn_call (receiver, _, _, args) ->
      go receiver;
      all args;
      changed := true
    | `Assign (_, v) ->
      go v;
      changed := true
    | `Field_assign (a, _, b) ->
      all [ a; b ];
      changed := true
    | `Array_set (a, b, c) ->
      all [ a; b; c ];
      changed := true
    | `Binop (_, a, b) | `And (a, b) | `Or (a, b) | `Array_get (a, b) | `Str_get (a, b) | `Array_new (a, b) ->
      all [ a; b ]
    | `Unop (_, a) | `Tuple_get (a, _) | `Field (a, _) | `Str_len a | `Array_len a -> go a
    | `Tuple items | `Array_lit items -> all items
    | `Record_lit fields | `Variant (_, fields) -> all (List.map snd fields)
    | `Object _ -> if names <> [] then ok := false
  in
  if names = [] then true else (go e; !ok)

(* The reads of [name] made when the expression is, not later from a lambda. *)
let rec uses_now name (e : resolved_expr) =
  match e.it with
  | `Var v when String.equal v name -> 1
  | `Lambda _ -> 0
  | _ ->
    let n = ref 0 in
    iter_children (fun x -> n := !n + uses_now name x) e;
    !n

let read_once_always name (e : resolved_expr) =
  let within (x : resolved_expr) = uses name [ { it = `Expr x; span = x.span; ann = Types.Unit } ] in
  let rec count (e : resolved_expr) =
    match e.it with
    | `Var v when String.equal v name -> 1, 0
    | `Lambda _ -> 0, within e
    | `And (a, b) | `Or (a, b) ->
      let sure, unsure = count a in
      sure, unsure + within b
    | _ ->
      let sure = ref 0
      and unsure = ref 0 in
      iter_children
        (fun x ->
          let s, u = count x in
          sure := !sure + s;
          unsure := !unsure + u)
        e;
      !sure, !unsure
  in
  count e = (1, 0)

type callee =
  { c_params : param list
  ; c_body : resolved_stmt list
  }

let suitable : (string, resolved_stmt * (callee, string) result) Hashtbl.t = Hashtbl.create 64

(* An `inline` function's body, when it can stand at a call: its types
   settled, not taking control, declaring nothing, and not calling itself. *)
let inlinable name (decl : resolved_stmt) =
  match decl.it with
  | `Fn (fn_name, params, sg, body) when String.equal fn_name name ->
    if Typecheck.is_handed sg
    then Error "it takes control, so its body is rewritten into continuations"
    else if Hashtbl.mem (facts body).named name
    then Error "it calls itself"
    else if declares_type body
    then Error "it declares a type"
    else if not (closed body)
    then Error "its types are not settled"
    else Ok { c_params = params; c_body = body }
  | _ -> Error "it is not a function here"

(* The arguments a call passes past a callee's parameters are evidence it does
   not take, which the interpreter would drop. *)
let fitted c (args : resolved_expr list) =
  let n = List.length c.c_params in
  if List.length args = n
  then Some args
  else if List.length args > n
          && List.for_all
               (fun (a : resolved_expr) ->
                 match a.it with
                 | `Var _ | #lit -> true
                 | _ -> false)
               (List.filteri (fun i _ -> i >= n) args)
  then Some (List.filteri (fun i _ -> i < n) args)
  else None

(* [None] when the call is not of an `inline` function. *)
let callee_or_why sc name (args : resolved_expr list) =
  if bound sc name
  then None
  else (
    match sc.find name with
    | Not_inline -> None
    | Unready why -> Some (Error why)
    | Ready decl ->
      let c =
        match Hashtbl.find_opt suitable name with
        | Some (seen, c) when seen == decl -> c
        | _ ->
          let c = inlinable name decl in
          Hashtbl.replace suitable name (decl, c);
          c
      in
      (* Fewer arguments than parameters is evidence the call does not hand
         over, which only a program already in error has. *)
      (match c with
       | Ok c when List.length args < List.length c.c_params -> None
       | c ->
         Some
           (Result.bind c (fun c ->
              match fitted c args with
              | Some args -> Ok (c, args)
              | None -> Error "an argument past its parameters is more than evidence it does not take"))))

let callee sc name args =
  match callee_or_why sc name args with
  | Some (Ok found) -> Some found
  | _ -> None

(* Whether the one read of [name] comes before anything with an effect or
   that can fail, in the order the interpreter evaluates: an argument
   substituted there runs where it would have run as a binding ahead of the
   body. *)
let first_effect_after name (e : resolved_expr) =
  let rec go (e : resolved_expr) =
    let rec seq = function
      | [] -> `Clean
      | x :: rest ->
        (match go x with
         | `Clean -> seq rest
         | other -> other)
    in
    let then_own effectful children =
      match seq children with
      | `Clean -> if effectful then `Dirty else `Clean
      | other -> other
    in
    match e.it with
    | `Var v when String.equal v name -> `Found
    | #lit | `Var _ | `Lambda _ -> `Clean
    | `Call (callee, args) -> then_own true (callee :: args)
    | `Dyn_call (receiver, _, _, args) -> then_own true (receiver :: args)
    | `Assign (_, v) -> then_own true [ v ]
    | `Field_assign (a, _, b) -> then_own true [ a; b ]
    | `Array_set (a, b, c) -> then_own true [ a; b; c ]
    | `Binop ((Div | Mod), a, b) | `Array_get (a, b) | `Str_get (a, b) | `Array_new (a, b) -> then_own true [ a; b ]
    | `Binop (_, a, b) | `And (a, b) | `Or (a, b) -> then_own false [ a; b ]
    | `Unop (_, a) | `Tuple_get (a, _) | `Field (a, _) | `Str_len a | `Array_len a -> then_own false [ a ]
    | `Tuple items | `Array_lit items -> then_own false items
    | `Record_lit fields | `Variant (_, fields) -> then_own false (List.map snd fields)
    | `Object _ -> `Dirty
  in
  go e = `Found

(* The body with its parameters renamed, once it is known nothing it reads is
   bound where it will stand. *)
let renamed ps body =
  let m, params = rename_params M.empty ps in
  let body = rename_block m body in
  let f = facts body in
  Hashtbl.iter (fun n () -> if is_fresh n then Hashtbl.replace fresh_assigned n ()) f.assigned;
  params, body, f

let opened sc c =
  let params, body, f = renamed c.c_params c.c_body in
  let free = f.named in
  let own n = sc.own = Some n && Hashtbl.find_opt sc.facts.bound n = Some 1 in
  if Hashtbl.fold (fun n () clash -> clash || ((not (is_fresh n)) && bound sc n && not (own n))) free false
  then None
  else Some (params, body)

let bind_stmt (span : span) name (arg : resolved_expr) : resolved_stmt =
  { it = `Var_decl (name, None, Some arg); span; ann = Types.Unit }

(* A lambda handed to a body that calls it once, as a statement of its own:
   the call is replaced by the lambda's statements. *)
let rec beta_ready (lam : resolved_expr) arity =
  match lam.it with
  | `Lambda (ps, sg, body) ->
    List.length ps = arity
    && (not (Typecheck.is_handed sg))
    && (not (List.exists (leaves_stmt ~loops:0) body))
    && not (holds_declaration body)
  | _ -> false

(* A lambda whose value is returned where it is called: its statements take the
   call's place, its `return`s returning from the function it was written into.
   It must end in one, or the statements after the call would run. *)
and tail_ready (lam : resolved_expr) arity =
  match lam.it with
  | `Lambda (ps, sg, body) ->
    List.length ps = arity
    && (not (Typecheck.is_handed sg))
    && (match List.rev body with
        | { it = `Return (Some _); _ } :: _ -> true
        | _ -> false)
  | _ -> false

and called_alone name body =
  List.exists
    (fun (s : resolved_stmt) ->
      match s.it with
      | `Expr { it = `Call ({ it = `Var v; _ }, _); _ } -> String.equal v name
      | _ -> false)
    body

and returned name body =
  List.find_map
    (fun (s : resolved_stmt) ->
      match s.it with
      | `Return (Some { it = `Call ({ it = `Var v; _ }, cargs); _ }) when String.equal v name -> Some (List.length cargs)
      | _ -> None)
    body

and arity_called name body =
  List.find_map
    (fun (s : resolved_stmt) ->
      match s.it with
      | `Expr { it = `Call ({ it = `Var v; _ }, cargs); _ } when String.equal v name -> Some (List.length cargs)
      | _ -> None)
    body

(* The arguments bound to the parameters: substituted where that changes
   nothing, declared ahead of the body otherwise, in the order they were
   written. *)
let bindings sc span params args body =
  let simple (a : resolved_expr) = trivial sc a || (match a.it with `Lambda _ -> true | _ -> false) in
  let opening =
    match body with
    | { it = `Expr e | `Return (Some e) | `Var_decl (_, _, Some e); _ } :: _ -> Some e
    | _ -> None
  in
  (* The one argument that is not simple, read once and first in the body's
     opening statement, is written there rather than bound ahead. *)
  let in_place (p : param) (arg : resolved_expr) =
    (not (simple arg))
    && List.length (List.filter (fun a -> not (simple a)) args) = 1
    && uses p.name body = 1
    &&
    match opening with
    | Some e -> uses_now p.name e = 1 && read_once_always p.name e && first_effect_after p.name e
    | None -> false
  in
  let subst, binds =
    List.fold_left2
      (fun (subst, binds) (p : param) (arg : resolved_expr) ->
        let n = uses p.name body in
        let substitutes =
          trivial sc arg
          || (match arg.it with
              | `Lambda _ ->
                n = 0
                || (n = 1
                    && called_alone p.name body
                    && Option.fold ~none:false ~some:(beta_ready arg) (arity_called p.name body))
                || (n = 1 && Option.fold ~none:false ~some:(tail_ready arg) (returned p.name body))
              | _ -> false)
        in
        if substitutes || in_place p arg
        then M.add p.name arg subst, binds
        else subst, bind_stmt span p.name arg :: binds)
      (M.empty, [])
      params
      args
  in
  List.rev binds, List.map (subst_stmt subst) body

(* A body whose one way out is a `return` at its end, so its value can be
   handed to whatever the call stood in. *)
let returns_at_end c =
  match List.rev c.c_body with
  | { it = `Return (Some _); _ } :: before -> not (List.exists (leaves_stmt ~loops:0) before)
  | _ -> false

(* Where an `inline` call stands in an expression, the call taken out of it,
   with what is evaluated before it bound ahead in order: [Found] holds those
   bindings, the call, and the expression with something in the call's place.
   What has no effect and reads only names that keep one value is [Movable],
   and stays where it is. *)
type hoist =
  | Found of resolved_stmt list * resolved_expr * (resolved_expr -> resolved_expr)
  | Movable
  | Fixed

(* The children in the order the interpreter evaluates them; [children]
   rebuilds in whatever order OCaml evaluates a constructor's arguments. *)
let in_order (e : resolved_expr) : resolved_expr list option =
  match e.it with
  | #lit | `Var _ | `Lambda _ -> Some []
  | `Call (callee, args) -> Some (callee :: args)
  | `Dyn_call (receiver, _, _, args) -> Some (receiver :: args)
  | `Assign (_, v) -> Some [ v ]
  | `Field_assign (a, _, b) -> Some [ a; b ]
  | `Array_set (a, b, c) -> Some [ a; b; c ]
  | `Binop (_, a, b) | `And (a, b) | `Or (a, b) | `Array_get (a, b) | `Str_get (a, b) | `Array_new (a, b) ->
    Some [ a; b ]
  | `Unop (_, a) | `Tuple_get (a, _) | `Field (a, _) | `Str_len a | `Array_len a -> Some [ a ]
  | `Tuple items | `Array_lit items -> Some items
  | `Record_lit fields | `Variant (_, fields) -> Some (List.map snd fields)
  | `Object _ -> None

(* The rebuild finds a child by identity, so no two may be one value. *)
let distinct kids =
  let rec go = function
    | [] -> true
    | x :: rest -> (not (List.memq x rest)) && go rest
  in
  go kids

let rec hoist sc (e : resolved_expr) =
  match e.it with
  | `Call ({ it = `Var f; _ }, args) when Option.is_some (callee sc f args) -> Found ([], e, fun x -> x)
  | #lit | `Lambda _ -> Movable
  | `Var n -> if stable sc n then Movable else Fixed
  (* The right side may not run, so nothing is taken out of it. *)
  | `And (a, b) | `Or (a, b) ->
    (match hoist sc a with
     | Found (ahead, call, put) ->
       let rebuild x =
         match e.it with
         | `And _ -> { e with it = `And (put x, b) }
         | _ -> { e with it = `Or (put x, b) }
       in
       Found (ahead, call, rebuild)
     | Movable ->
       (match hoist sc b with
        | Movable -> Movable
        | _ -> Fixed)
     | Fixed -> Fixed)
  | `Object _ | `Call _ | `Dyn_call _ | `Assign _ | `Field_assign _ | `Array_set _ | `Field _ | `Array_get _
  | `Str_get _ | `Binop ((Div | Mod), _, _) -> hoist_children ~movable:false sc e
  | _ -> hoist_children ~movable:true sc e

and hoist_children ~movable sc e =
  match in_order e with
  | Some kids when distinct kids -> hoist_kids ~movable sc e kids
  | _ -> Fixed

and hoist_kids ~movable sc e kids =
  let rec go before = function
    | [] -> Error (List.for_all (fun (_, how) -> how = `Stays) before)
    | x :: rest ->
      (match hoist sc x with
       | Found (ahead, call, put) -> Ok (List.rev before, x, ahead, call, put)
       | Movable -> go ((x, `Stays) :: before) rest
       | Fixed -> go ((x, `Bound) :: before) rest)
  in
  match go [] kids with
  | Ok (before, found, ahead, call, put) ->
    let bound =
      List.filter_map
        (fun ((x : resolved_expr), how) ->
          match how with
          | `Bound -> Some (x, fresh "value")
          | `Stays -> None)
        before
    in
    let binds = List.map (fun ((x : resolved_expr), n) -> bind_stmt x.span n x) bound in
    let rebuild v =
      children
        (fun c ->
          if c == found
          then put v
          else (
            match List.assq_opt c bound with
            | Some n -> { c with it = `Var n }
            | None -> c))
        e
    in
    Found (binds @ ahead, call, rebuild)
  | Error all_stay -> if movable && all_stay then Movable else Fixed

(* The body with each `return` replaced by what [put] makes of its value, when
   every one ends the body or a branch that ends it: what runs after each is
   then what ran after the call. *)
let rec tails put (body : resolved_stmt list) =
  match body with
  | [] -> Some []
  | [ last ] -> tail put last
  | first :: rest when not (leaves_stmt ~loops:0 first) -> Option.map (fun rest -> first :: rest) (tails put rest)
  (* `if (c) { return a; } rest` is `if (c) { return a; } else { rest }`. *)
  | ({ it = `If (c, t, None); _ } as first) :: rest when Defers.leaves t ->
    tail put { first with it = `If (c, t, Some { first with it = `Block rest }) }
  | _ -> None

and tail put (s : resolved_stmt) : resolved_stmt list option =
  let one body = Option.map (fun b -> { s with it = `Block b }) (tails put body) in
  let branch (st : resolved_stmt) =
    match st.it with
    | `Block body -> one body
    | _ -> one [ st ]
  in
  match s.it with
  | `Return r -> Some (put r)
  | `Block body -> Option.map (fun b -> [ { s with it = `Block b } ]) (tails put body)
  | `If (c, t, f) ->
    (match branch t, Option.map branch f with
     | Some t, None -> Some [ { s with it = `If (c, t, None) } ]
     | Some t, Some (Some f) -> Some [ { s with it = `If (c, t, Some f) } ]
     | _ -> None)
  | `Match (subject, cases) ->
    let cases = List.map (fun (p, b) -> Option.map (fun b -> p, b) (tails put b)) cases in
    if List.for_all Option.is_some cases
    then Some [ { s with it = `Match (subject, List.map Option.get cases) } ]
    else None
  | _ -> if leaves_stmt ~loops:0 s then None else Some [ s ]

let rec expr sc (e : resolved_expr) : resolved_expr =
  let e =
    match e.it with
    | `Lambda (ps, sg, body) -> { e with it = `Lambda (ps, sg, block sc body) }
    | _ -> children (expr sc) e
  in
  match e.it with
  | `Call ({ it = `Var f; _ }, args) ->
    Option.value ~default:e (Option.bind (callee sc f args) (fun (c, args) -> in_expression sc e args c))
  | _ -> e

(* A call standing where a value is wanted becomes the expression its callee
   returns, when every argument can be substituted: all but one have no
   effect, and that one is read exactly once, first among what could notice. *)
and in_expression sc (call : resolved_expr) args c =
  match c.c_body with
  | [ { it = `Return (Some _); _ } ] ->
    Option.bind (opened sc c) (fun (params, body) ->
      match body with
      | [ { it = `Return (Some r); _ } ] ->
        let pairs = List.combine params args in
        let kind ((p : param), (a : resolved_expr)) =
          match a.it with
          | _ when trivial sc a -> `Trivial
          | `Lambda _ -> if uses p.name body = 0 then `Trivial else `Refused
          | _ when readable a -> `Read p.name
          | _ -> `Heavy p.name
        in
        let kinds = List.map kind pairs in
        let reads = List.filter_map (function `Read n -> Some n | _ -> None) kinds in
        let heavy = List.filter_map (function `Heavy n -> Some n | _ -> None) kinds in
        let delayed n = uses n body - uses_now n r in
        let substitutable =
          (not (List.mem `Refused kinds))
          && List.for_all (fun n -> delayed n = 0) reads
          &&
          match heavy with
          | [] -> reads_first reads r
          | [ n ] -> reads = [] && read_once_always n r && (pure r || first_effect_after n r)
          | _ -> false
        in
        if not substitutable
        then None
        else (
          let m = List.fold_left2 (fun m (p : param) a -> M.add p.name a m) M.empty params args in
          let r = subst_expr m r in
          Some { r with span = call.span })
      | _ -> None)
  | _ -> None

and block sc body = propagate sc (List.concat_map (stmt_list sc) body)

and one sc (s : resolved_stmt) =
  match stmt_list sc s with
  | [ s ] -> s
  | body -> { s with it = `Block body }

and stmt_list sc (s : resolved_stmt) : resolved_stmt list =
  let e = expr sc in
  let s =
    let it : resolved_stmt_kind =
      match s.it with
      | `Expr x -> `Expr (e x)
      | `Var_decl (n, ty, init) -> `Var_decl (n, ty, Option.map e init)
      | `Var_tuple (ns, x) -> `Var_tuple (ns, e x)
      | `Return x -> `Return (Option.map e x)
      | `Block body -> `Block (block sc body)
      | `If (c, t, f) -> `If (e c, one sc t, Option.map (one sc) f)
      | `While (c, body) -> `While (e c, one sc body)
      | `Fn (n, ps, sg, body) -> `Fn (n, ps, sg, block sc body)
      | `Match (subject, cases) -> `Match (e subject, List.map (fun (p, b) -> p, block sc b) cases)
      | `Defer d -> `Defer (one sc d)
      | other -> other
    in
    { s with it }
  in
  List.concat_map (settle sc) (replaced sc s)

(* A statement that is a call, or hands one's value straight to a `return`, a
   `var` or an assignment, replaced by the callee's body after its arguments. An argument
   bound ahead of the body is such a statement in turn. *)
and replaced sc (s : resolved_stmt) : resolved_stmt list =
  let ahead binds = List.concat_map (replaced sc) binds in
  let at_call body = List.map (fun (st : resolved_stmt) -> { st with span = s.span }) body in
  let own c body = if needs_block c.c_body then [ { s with it = `Block body } ] else body in
  (* The body after its arguments, each way out of it handed to [put]: only
     when every `return` ends the body, or ends a branch that does. *)
  let written (call : resolved_expr) put =
    match call.it with
    | `Call ({ it = `Var f; _ }, args) ->
      Option.bind (callee sc f args) (fun (c, args) ->
        Option.bind (opened sc c) (fun (params, body) ->
          let binds, body = bindings sc s.span params args body in
          Option.map
            (fun body -> ahead binds @ own c (List.concat_map (beta sc) (at_call body)))
            (tails put body)))
    | _ -> None
  in
  (* `return f(..);` may take the body whole, its returns the caller's. *)
  let returned (call : resolved_expr) =
    match call.it with
    | `Call ({ it = `Var f; _ }, args) ->
      Option.bind (callee sc f args) (fun (c, args) ->
        Option.map
          (fun (params, body) ->
            let binds, body = bindings sc s.span params args body in
            let ends =
              match List.rev body with
              | { it = `Return _; _ } :: _ -> []
              | _ -> [ { s with it = `Return None } ]
            in
            ahead binds @ own c (List.concat_map (beta sc) (at_call body) @ ends))
          (opened sc c))
    | _ -> None
  in
  let assigned n = Hashtbl.replace (if is_fresh n then fresh_assigned else sc.facts.assigned) n () in
  let assign n (assign : resolved_expr) = function
    | Some r -> [ { s with it = `Expr { assign with it = `Assign (n, r) } } ]
    | None -> []
  in
  let replacement =
    match s.it with
    | `Expr ({ it = `Call ({ it = `Var _; _ }, _); _ } as call) ->
      written call (function
        | Some r -> [ { s with it = `Expr r } ]
        | None -> [])
    | `Expr { it = `Call ({ it = `Lambda _; _ }, _); _ } -> Some (beta sc s)
    | `Return (Some call) -> returned call
    | `Var_decl (n, ty, Some ({ it = `Call ({ it = `Var f; _ }, args); _ } as call)) ->
      (match callee sc f args with
       | Some (c, _) when returns_at_end c && not (needs_block c.c_body) -> written call (fun r -> [ { s with it = `Var_decl (n, ty, r) } ])
       | Some _ ->
         (* Returned from inside, the value is assigned where each return was. *)
         Option.map
           (fun body ->
             assigned n;
             { s with it = `Var_decl (n, ty, None) } :: body)
           (written call (assign n { call with it = `Assign (n, call) }))
       | None -> None)
    | `Expr ({ it = `Assign (n, call); _ } as a) -> written call (assign n a)
    | _ -> None
  in
  Option.value ~default:[ s ] replacement

(* A statement still holding an `inline` call where it is evaluated first:
   the call bound ahead of it, and replaced as a statement of its own. A call
   that is the whole of its statement was already refused as one. *)
and settle sc (s : resolved_stmt) : resolved_stmt list =
  let whole (e : resolved_expr) =
    match e.it with
    | `Call ({ it = `Var f; _ }, args) | `Assign (_, { it = `Call ({ it = `Var f; _ }, args); _ }) ->
      Option.is_some (callee sc f args)
    | _ -> false
  in
  let taken (e : resolved_expr) rebuild =
    if whole e
    then None
    else (
      match hoist sc e with
      | Found (ahead, call, put) ->
        let name = fresh "value" in
        let bind = bind_stmt s.span name call in
        let rest = rebuild (put { call with it = `Var name }) in
        Some (ahead @ replaced sc bind @ settle sc rest)
      | Movable | Fixed -> None)
  in
  let found =
    match s.it with
    | `Expr x -> taken x (fun x -> { s with it = `Expr x })
    | `Var_decl (n, ty, Some x) -> taken x (fun x -> { s with it = `Var_decl (n, ty, Some x) })
    | `Var_tuple (ns, x) -> taken x (fun x -> { s with it = `Var_tuple (ns, x) })
    | `Return (Some x) -> taken x (fun x -> { s with it = `Return (Some x) })
    | `If (c, t, f) -> taken c (fun c -> { s with it = `If (c, t, f) })
    | `Match (subject, cases) -> taken subject (fun x -> { s with it = `Match (x, cases) })
    | _ -> None
  in
  Option.value ~default:[ s ] found

(* A lambda called where it is written, as a statement: its statements, after
   its arguments. *)
and beta sc (s : resolved_stmt) : resolved_stmt list =
  match s.it with
  | `Expr { it = `Call (({ it = `Lambda (ps, _, body); _ } as lam), cargs); _ } when beta_ready lam (List.length cargs) ->
    let params, body, _ = renamed ps body in
    let binds, body = bindings sc s.span params cargs body in
    List.concat_map (replaced sc) binds @ body
  | `Return (Some { it = `Call (({ it = `Lambda (ps, _, body); _ } as lam), cargs); _ })
    when tail_ready lam (List.length cargs) ->
    let params, body, _ = renamed ps body in
    let binds, body = bindings sc s.span params cargs body in
    List.concat_map (replaced sc) binds @ body
  | _ -> [ s ]

(* `var x = y;` where neither name ever holds another value: each read of
   [x] after it reads [y]. *)
and propagate sc body =
  let propagates x =
    if is_fresh x
    then not (Hashtbl.mem fresh_assigned x)
    else Hashtbl.find_opt sc.facts.bound x = Some 1 && not (Hashtbl.mem sc.facts.assigned x)
  in
  (* Inlining has run by now, so a call this would make of an `inline`
     function would be left standing. *)
  let names_inline (e : resolved_expr) =
    match e.it with
    | `Var n ->
      (match sc.find n with
       | Not_inline -> false
       | Unready _ | Ready _ -> true)
    | _ -> false
  in
  let rec go = function
    | [] -> []
    | ({ it = `Var_decl (x, _, Some init); _ } : resolved_stmt) :: rest
      when propagates x && trivial sc init && not (names_inline init) ->
      go (List.map (subst_stmt (M.singleton x init)) rest)
    | s :: rest -> s :: go rest
  in
  (* A function declared in the block is hoisted above the declaration, and
     may read [x] where no substitution reaches. *)
  if List.exists (fun (s : resolved_stmt) -> match s.it with `Fn _ -> true | _ -> false) body then body else go body

let refused name why span =
  let declared =
    match String.rindex_opt name '#' with
    | Some at when at > 0 && Option.is_some (int_of_string_opt (String.sub name (at + 1) (String.length name - at - 1))) ->
      String.sub name 0 at
    | _ -> name
  in
  Typecheck.fail span "'%s' is declared inline, but %s." (Typecheck.shown_name declared) why

(* What says why a call of an `inline` function is still a call. *)
let why_left sc f args =
  match callee_or_why sc f args with
  | None -> None
  | Some (Error why) -> Some (Printf.sprintf "this call cannot be inlined: %s" why)
  | Some (Ok (c, _)) when tails (fun _ -> []) c.c_body = None ->
    Some "it returns from inside a loop, so only a call it returns from can be inlined: `return f(…);`"
  | Some (Ok _) ->
    Some
      "this call cannot be inlined: it stands where its body cannot be written, after something in its statement \
       that has to be evaluated first"

let left sc body =
  iter_body
    ~expr:(fun e ->
      match e.it with
      | `Call ({ it = `Var f; _ }, args) -> Option.iter (fun why -> refused f why e.span) (why_left sc f args)
      | _ -> ())
    body

let declared_inline (s : resolved_stmt) =
  match s.it with
  | `Fn (name, _, sg, body) when sg.inline && Hashtbl.mem (facts body).named name ->
    refused name "it calls itself, so it can never be inlined" s.span
  | _ -> ()

(* [report] is false once the program has failed: what a call could not be
   inlined for is then most likely that failure seen again. *)
let program ~report ~find ~is_function (body : resolved_stmt list) : resolved_stmt list =
  if report then List.iter declared_inline body;
  let own =
    match body with
    | [ { it = `Fn (name, _, _, _); _ } ] -> Some name
    | _ -> None
  in
  let sc = { facts = facts body; find; is_function; own } in
  let body = block sc body in
  if report then left sc body;
  body
