open Ast

type error =
  { span : span
  ; message : string
  }

exception Error of error

let declared : (string, stmt handler) Hashtbl.t = Hashtbl.create 8

(* Functions whose last parameter is variadic: how many come before it, and
   whether what it collects into is a pack's tuple rather than an array. *)
let variadic : (string, int * bool) Hashtbl.t = Hashtbl.create 8

(* What a declaration was written with, kept here because this is where the
   wrapper is unwound and no later tree can hold one.

   Only a type is recorded. `typeof(T).attrs` is the one reader and it keys by
   type name, so recording a function or a variable under the same key would
   collide rather than answer — and nothing can ask for those yet, because
   `typeof` takes a value and a function value's type names no declaration. *)
let decl_attrs : (string, Ast.attr list) Hashtbl.t = Hashtbl.create 8

let declared_name (s : stmt) =
  match s.it with
  | `Type_decl (name, _, _) -> Some name
  | _ -> None

let variadic_arity (params : param list) =
  match List.rev params with
  | { ty = Some { it = Ty_variadic { it = Ty_spread _; _ }; _ }; _ } :: before ->
    Some (List.length before, true)
  | { ty = Some { it = Ty_variadic _; _ }; _ } :: before -> Some (List.length before, false)
  | _ -> None

let counter = ref 0

let fresh prefix =
  incr counter;
  generated [ prefix; string_of_int !counter ]

(* One name binds the value; several take it apart by position. The arity is
   written down, so this needs no type — which is what keeps destructuring out
   of the checker entirely. *)
let bound span (names : binder) (value : expr) : stmt list =
  let decl n init : stmt = { it = `Var_decl (n, None, Some init); span; ann = () } in
  match names with
  | [ only ] -> [ decl only value ]
  | names ->
    let whole = fresh "tuple" in
    decl whole value
    :: List.mapi
         (fun index n -> decl n (at span (`Tuple_get (at span (`Var whole), index))))
         names

let rec expr (e : expr) : desugared_expr =
  let sp = e.span in
  let it : desugared_expr_kind =
    match e.it with
    (* Nothing after this pass knows a call was written any other way. *)
    | `Call (({ it = `Var name; _ } as callee), args)
      when Hashtbl.mem variadic name && List.length args >= fst (Hashtbl.find variadic name) ->
      let fixed, packed = Hashtbl.find variadic name in
      let rec split n = function
        | rest when n = 0 -> [], rest
        | [] -> [], []
        | a :: rest ->
          let before, after = split (n - 1) rest in
          a :: before, after
      in
      let before, collected = split fixed args in
      let bundle : desugared_expr_kind =
        match packed, collected with
        (* A product of none is `unit`, and nothing later reads an empty tuple
           as one. *)
        | true, [] -> `Unit
        | true, collected -> `Tuple (List.map expr collected)
        | false, collected -> `Collection_lit (List.map expr collected)
      in
      `Call (expr callee, List.map expr before @ [ { it = bundle; span = sp; ann = () } ])
    | #lit as l -> l
    | #vars as v -> (map_vars expr v :> desugared_expr_kind)
    | #ops as o -> (map_ops expr o :> desugared_expr_kind)
    | #logic as l -> (map_logic expr l :> desugared_expr_kind)
    | #compound as c -> (map_compound expr c :> desugared_expr_kind)
    | #indexing as i -> (map_indexing expr i :> desugared_expr_kind)
    | #tuple as t -> (map_tuple expr t :> desugared_expr_kind)
    | #spread as s -> (map_spread expr s :> desugared_expr_kind)
    | #record as r -> (map_record expr r :> desugared_expr_kind)
    | #nominal as n -> (map_nominal expr n :> desugared_expr_kind)
    | #collection as c -> (map_collection expr c :> desugared_expr_kind)
    | #comptime_call as c -> (map_comptime_call expr c :> desugared_expr_kind)
    | #method_call as m -> (map_method_call expr m :> desugared_expr_kind)
    | `Lambda (params, signature, body) -> `Lambda (params, signature, List.map stmt body)
    | #run_expr as r -> (map_run_expr expr stmt (clause sp) r :> desugared_expr_kind)
    | #reflect as r -> (map_reflect expr r :> desugared_expr_kind)
    (* One arriving here stood where no meta program would have run it. *)
    | `Code _ ->
      raise
        (Error
           { span = sp; message = "'code' is only allowed inside a meta block." })
  in
  { it; span = sp; ann = () }

and stmt (s : stmt) : desugared_stmt =
  let sp = s.span in
  match s.it with
  (* The attributes are recorded and the wrapper dropped: nothing after this
     pass has a type that could carry one. *)
  | `Attributed (attrs, inner) ->
    Option.iter (fun name -> Hashtbl.replace decl_attrs name attrs) (declared_name inner);
    stmt inner
  | _ ->
  let it : desugared_stmt_kind =
    match s.it with
        | `Import _ | `Meta _ | `Gen _ | `Meta_fn _ | `Derive _ | `Attributed _ -> assert false
    (* for (x in xs) body  ⇒  { var seq = xs; var i = 0;
                                 while (i < seq.len()) { var x = seq[i]; body; i = i + 1; } }

       The sequence is bound once so an expression is evaluated once, and `len`
       and `[]` are ordinary source so the checker resolves them for whatever
       the sequence turns out to be. *)
    | `For_in (names, iterable, body) ->
      let sp = iterable.span in
      let seq = fresh "seq"
      and index = fresh "i" in
      let var_decl_of at_span n init : stmt =
        { it = `Var_decl (n, None, Some init); span = at_span; ann = () }
      in
      let read n = at sp (`Var n) in
      let step : stmt =
        { it = `Expr (at body.span (`Assign (index, at body.span (`Binop (Add, read index, at body.span (`Int 1))))))
        ; span = body.span
        ; ann = ()
        }
      in
      let inner : stmt =
        { it =
            `Block
              (bound body.span names (at body.span (`Index (read seq, read index)))
               @ [ body; step ])
        ; span = body.span
        ; ann = ()
        }
      in
      (stmt
         { it =
             `Block
               [ var_decl_of sp seq iterable
               ; var_decl_of sp index (at sp (`Int 0))
               ; at sp (`While (at sp (`Binop (Less, read index, at sp (`Method_call (read seq, "len", "len", [])))), inner))
               ]
         ; span = sp
         ; ann = ()
         })
        .it
    (* for (init; cond; step) body  ⇒  { init; while (cond) { body; step; } } *)
    | `For (init, cond, step, body) ->
      let cond =
        match cond with
        | None -> at sp (`Bool true)
        | Some c -> expr c
      in
      let body =
        let body = stmt body in
        match step with
        | None -> body
        | Some st ->
          let step = expr st in
          { it = `Block [ body; { it = `Expr step; span = step.span; ann = () } ]
          ; span = body.span
          ; ann = ()
          }
      in
      let loop = at sp (`While (cond, body)) in
      `Block
        (match init with
         | Some i -> [ stmt i; loop ]
         | None -> [ loop ])
    | #stmts as s -> (map_stmts expr stmt s :> desugared_stmt_kind)
    | #effects as e -> (map_effects expr stmt (clause sp) e :> desugared_stmt_kind)
    | #type_defs as t -> t
    | #matching as m -> (map_matching expr stmt m :> desugared_stmt_kind)
    | #method_defs as m -> (map_method_defs stmt Fun.id m :> desugared_stmt_kind)
    | `Handler_decl _ -> `Block []
  in
  { it; span = sp; ann = () }

and clause span (c : stmt handler_clause) : desugared_stmt handler =
  match c with
  | Inline h -> map_handler stmt h
  | Named name ->
    (match Hashtbl.find_opt declared name with
     | Some h -> map_handler stmt h
     | None ->
       raise (Error { span; message = Printf.sprintf "Unknown handler '%s'." name }))

let program (p : program) : (desugared_stmt list, error) result =
  Hashtbl.reset declared;
  Hashtbl.reset variadic;
  (* Both tables are keyed by bare name and read from anywhere, so a handler or
     a variadic written inside a block has to be found the same as one written
     at the top: missing it is an "Unknown handler" for the first and, for the
     second, silently an ordinary function taking an array. *)
  let rec collect (s : stmt) =
    (match s.it with
     | `Handler_decl (name, h) -> Hashtbl.replace declared name h
     | `Fn (name, params, _, _) ->
       Option.iter (Hashtbl.replace variadic name) (variadic_arity params)
     | _ -> ());
    List.iter collect (children s)
  and children (s : stmt) =
    match s.it with
    | `Attributed (_, inner) -> [ inner ]
    | `Block body | `Fn (_, _, _, body) | `Meta body | `Meta_fn (_, _, _, body) -> body
    | `Defer inner | `Gen inner -> [ inner ]
    | `If (_, t, e) -> t :: Option.to_list e
    | `While (_, body) -> [ body ]
    | `For (init, _, _, body) -> Option.to_list init @ [ body ]
    | `For_in (_, _, body) -> [ body ]
    | `Match (_, cases) -> List.concat_map snd cases
    | `Handler_decl (_, h) -> List.concat_map (fun a -> a.arm_body) h.arms
    | `Run (body, handlers) ->
      body
      @ List.concat_map
          (function
            | Inline h -> List.concat_map (fun a -> a.arm_body) h.arms
            | Named _ -> [])
          handlers
    | `Impl_decl (_, _, _, body) -> List.concat_map (fun m -> m.md_body) body.ib_methods
    | `Expr _ | `Var_decl _ | `Var_tuple _ | `Return _ | `Import _ | `Derive _ | `Effect_decl _
    | `Resume _ | `Type_decl _ | `Trait_decl _ -> []
  in
  List.iter collect p;
  try Ok (List.map stmt p) with
  | Error e -> Result.Error e
