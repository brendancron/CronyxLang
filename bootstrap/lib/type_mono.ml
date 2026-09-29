(* An operator inside a generic body cannot be selected while the body is
   generic, so it is copied per concrete type its call sites use. *)
type state =
  { registry : Registry.t
  ; generic : (string, Ast.typed_stmt) Hashtbl.t
  ; copies : (string * Types.ty, string) Hashtbl.t
  ; (* So an instance asking for another instance of its own generic is recognized. *)
    origin : (string, string) Hashtbl.t
  ; mutable emitted : Ast.typed_stmt list
  ; mutable changed : bool
  ; mutable rewriting : string option
  ; mutable recursive : string option
  (* The variables the declarations around the body being rewritten own. *)
  ; mutable owned : int list
  (* Names a body binds itself, which a generic of the same name does not
     reach: a local `fn print` is not the prelude's. *)
  ; mutable shadowed : string list
  }

(* A call the body makes to itself at another type is deliberately not counted:
   every copy would ask for one more. Such a function stays generic. *)
let rec type_directed_expr self (e : Ast.typed_expr) =
  let operand (child : Ast.typed_expr) = Types.has_generic child.Ast.ann in
  let type_directed_expr = type_directed_expr self in
  match e.Ast.it with
  | `Binop (_, a, b) -> operand a || operand b || type_directed_expr a || type_directed_expr b
  | `Compound (_, _, v) -> Types.has_generic e.Ast.ann || type_directed_expr v
  | `Compound_index (_, a, b, c) ->
    Types.has_generic e.Ast.ann
    || type_directed_expr a
    || type_directed_expr b
    || type_directed_expr c
  | `Compound_field (_, a, _, b) ->
    Types.has_generic e.Ast.ann || type_directed_expr a || type_directed_expr b
  | `Bound_call (receiver, _, _, args) | `Dyn_call (receiver, _, _, args) ->
    operand receiver
    || type_directed_expr receiver
    || List.exists type_directed_expr args
  | `Collection_lit items | `Array_lit items ->
    Types.has_generic e.Ast.ann || List.exists type_directed_expr items
  | `Array_new (a, b) | `Array_get (a, b) -> type_directed_expr a || type_directed_expr b
  | `Array_set (a, b, c) ->
    type_directed_expr a || type_directed_expr b || type_directed_expr c
  | `Array_len a | `Str_len a -> type_directed_expr a
  | `Str_get (a, b) -> type_directed_expr a || type_directed_expr b
  | `Unop (_, a) | `Tuple_get (a, _) | `Field (a, _) | `Typeof a | `Assign (_, a) ->
    type_directed_expr a
  (* Which impl the vtable holds follows from the value's type, so a body
     coercing one is owed a copy per type it coerces. *)
  | `Coerce (inner, _, _) -> operand inner || type_directed_expr inner
  (* How many arguments the call has is what the pack holds, so a body is owed
     a copy per pack even when nothing else in it is. *)
  | `Spread a -> Types.has_generic a.Ast.ann || type_directed_expr a
  | `And (a, b) | `Or (a, b) | `Index (a, b) | `Field_assign (a, _, b) ->
    type_directed_expr a || type_directed_expr b
  | `Index_assign (a, b, c) ->
    type_directed_expr a || type_directed_expr b || type_directed_expr c
    | `Lambda _ -> false
  (* A generic argument selects the callee's copy, so its holder is copied. *)
  | `Call ({ Ast.it = `Var called; _ }, args) when String.equal called self ->
    List.exists type_directed_expr args
  | `Call (callee, args) ->
    List.exists operand args
    || type_directed_expr callee
    || List.exists type_directed_expr args
  | `Tuple items -> List.exists type_directed_expr items
  | `New_call (_, _, args) -> List.exists type_directed_expr args
  | `Record_lit fields | `New (_, fields) ->
    List.exists (fun (_, v) -> type_directed_expr v) fields
  | `New_variant (_, _, payload) ->
    List.exists (fun (_, v) -> type_directed_expr v) (Ast.payload_fields payload)
  | `Run_expr (body, _, clause) ->
    Option.fold ~none:false ~some:type_directed_expr body.Ast.vb_value
    || Option.fold
         ~none:false
         ~some:(fun c -> Option.fold ~none:false ~some:type_directed_expr c.Ast.rc_body.Ast.vb_value)
         clause
  | `Match_expr (scrutinee, cases) ->
    type_directed_expr scrutinee
    || List.exists
         (fun (_, (b : (Ast.typed_expr, Ast.typed_stmt) Ast.valued_block)) ->
           List.exists (type_directed self) b.Ast.vb_stmts
           || Option.fold ~none:false ~some:type_directed_expr b.Ast.vb_value)
         cases
  | #Ast.lit | `Var _ -> false

and type_directed self (s : Ast.typed_stmt) =
  let expr = type_directed_expr self in
  let type_directed = type_directed self in
  match s.Ast.it with
  | `Expr e | `Return (Some e) | `Var_decl (_, _, Some e) | `Resume (Some e) -> expr e
  | `Block body | `Fn (_, _, _, body) -> List.exists type_directed body
  | `If (cond, then_branch, else_branch) ->
    expr cond
    || type_directed then_branch
    || Option.fold ~none:false ~some:type_directed else_branch
  | `While (cond, body) -> expr cond || type_directed body
  | `Match (scrutinee, cases) ->
    expr scrutinee || List.exists (fun (_, body) -> List.exists type_directed body) cases
  | `Run (body, handlers) ->
    List.exists type_directed body
    || List.exists
         (fun (h : Ast.typed_stmt Ast.handler) ->
           List.exists
             (fun (a : Ast.typed_stmt Ast.arm) -> List.exists type_directed a.Ast.arm_body)
             h.Ast.arms)
         handlers
  | `Impl_decl (_, _, _, impl) ->
    List.exists
      (fun (m : (Ast.typed_stmt, Types.ty) Ast.method_def) ->
        List.exists type_directed m.Ast.md_body)
      impl.Ast.ib_methods
  | _ -> false

let rec subst_expr ?(rows = []) mapping (e : Ast.typed_expr) : Ast.typed_expr =
  let subst_expr mapping e = subst_expr ~rows mapping e in
  let subst_stmt mapping s = subst_stmt ~rows mapping s in
  let it : Ast.typed_expr_kind =
    match e.Ast.it with
    | #Ast.lit as l -> l
    | #Ast.arrays as a -> (Ast.map_arrays (subst_expr mapping) a :> Ast.typed_expr_kind)
    | #Ast.strings as s -> (Ast.map_strings (subst_expr mapping) s :> Ast.typed_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars (subst_expr mapping) v :> Ast.typed_expr_kind)
    | #Ast.ops as o -> (Ast.map_ops (subst_expr mapping) o :> Ast.typed_expr_kind)
    | #Ast.logic as l -> (Ast.map_logic (subst_expr mapping) l :> Ast.typed_expr_kind)
    | #Ast.compound as c -> (Ast.map_compound (subst_expr mapping) c :> Ast.typed_expr_kind)
    | #Ast.indexing as i -> (Ast.map_indexing (subst_expr mapping) i :> Ast.typed_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple (subst_expr mapping) t :> Ast.typed_expr_kind)
    | #Ast.spread as s -> (Ast.map_spread (subst_expr mapping) s :> Ast.typed_expr_kind)
    | #Ast.record as r -> (Ast.map_record (subst_expr mapping) r :> Ast.typed_expr_kind)
    | #Ast.nominal as n -> (Ast.map_nominal (subst_expr mapping) n :> Ast.typed_expr_kind)
    | #Ast.collection as c ->
      (Ast.map_collection (subst_expr mapping) c :> Ast.typed_expr_kind)
    (* The dispatch is types, so a copy's targets are the copy's own. *)
    | #Ast.bound_calls as b ->
      (Ast.map_bound_call
         (subst_expr mapping)
         (Types.subst_generic ~rows mapping)
         b
       :> Ast.typed_expr_kind)
    | #Ast.dyn_calls as d ->
      (Ast.map_dyn_call (subst_expr mapping) (Types.subst_generic ~rows mapping) d
       :> Ast.typed_expr_kind)
    | #Ast.coercions as c ->
      (Ast.map_coercion (subst_expr mapping) (Types.subst_generic ~rows mapping) c
       :> Ast.typed_expr_kind)
    | #Ast.reflect as r -> (Ast.map_reflect (subst_expr mapping) r :> Ast.typed_expr_kind)
    | `Lambda (params, signature, body) ->
      `Lambda (params, signature, List.map (subst_stmt mapping) body)
    | #Ast.run_expr as r ->
      (Ast.map_run_expr
         (subst_expr mapping)
         (subst_stmt mapping)
         (Ast.map_handler (subst_stmt mapping))
         r
       :> Ast.typed_expr_kind)
    | #Ast.match_expr as m ->
      (Ast.map_match_expr (subst_expr mapping) (subst_stmt mapping) m :> Ast.typed_expr_kind)
  in
  { e with Ast.it; ann = Types.subst_generic ~rows mapping e.Ast.ann }

and subst_stmt ?(rows = []) mapping (s : Ast.typed_stmt) : Ast.typed_stmt =
  let subst_expr mapping e = subst_expr ~rows mapping e in
  let subst_stmt mapping s = subst_stmt ~rows mapping s in
  let it : Ast.typed_stmt_kind =
    match s.Ast.it with
    | #Ast.stmts as st ->
      (Ast.map_stmts (subst_expr mapping) (subst_stmt mapping) st
       :> Ast.typed_stmt_kind)
    | #Ast.effects as e ->
      (Ast.map_effects
         (subst_expr mapping)
         (subst_stmt mapping)
         (Ast.map_handler (subst_stmt mapping))
         e
       :> Ast.typed_stmt_kind)
    | #Ast.type_defs as t -> t
    | #Ast.method_defs as m ->
      (Ast.map_method_defs (subst_stmt mapping) (Types.subst_generic ~rows mapping) m
       :> Ast.typed_stmt_kind)
    | #Ast.matching as m ->
      (Ast.map_matching (subst_expr mapping) (subst_stmt mapping) m
       :> Ast.typed_stmt_kind)
  in
  { s with Ast.it; ann = Types.subst_generic ~rows mapping s.Ast.ann }

(* Keyed by the type, not its printing: two types can render alike. *)
let copy_for state name (at : Types.ty) =
  match Hashtbl.find_opt state.copies (name, at) with
  | Some existing -> existing
  | None ->
    let copy = Ast.generated [ name; string_of_int (Hashtbl.length state.copies) ] in
    Hashtbl.replace state.copies (name, at) copy;
    Hashtbl.replace state.origin copy name;
    if state.rewriting = Some name then state.recursive <- Some name;
    let declaration = Hashtbl.find state.generic name in
    (match declaration.Ast.it with
     | `Fn (_, params, signature, body) ->
       let mapping = Types.match_generic declaration.Ast.ann at [] in
       let rows = Types.match_rows declaration.Ast.ann at [] in
       let specialized =
         subst_stmt
           ~rows
           mapping
           { declaration with Ast.it = `Fn (copy, params, signature, body) }
       in
       state.emitted <- specialized :: state.emitted;
       state.changed <- true
     | _ -> ());
    copy

(* From the generic, not the call site: CPS reads it off the callee. *)
let method_call_type state name (receiver : Ast.typed_expr) args result =
  let row =
    match Hashtbl.find_opt state.generic name with
    | Some { Ast.ann = Types.Fn (_, _, row); _ } -> row
    | _ -> Types.closed_row []
  in
  Types.Fn
    ( receiver.Ast.ann :: List.map (fun (a : Ast.typed_expr) -> a.Ast.ann) args
    , result
    , row )

(* What a body reads or assigns, first use first, and every name it binds.
   Shadowing is not tracked -- a name bound anywhere inside counts as bound
   throughout -- so a capture can be missed but never invented. *)
let names_in (params : Ast.param list) (body : Ast.typed_stmt list) =
  let used = ref [] and bound = Hashtbl.create 16 in
  let bind name = Hashtbl.replace bound name () in
  let bind_params = List.iter (fun (p : Ast.param) -> bind p.Ast.name) in
  let bind_patterns cases = List.iter (fun (p, _) -> List.iter bind (Ast.pattern_names p)) cases in
  let rec expr (e : Ast.typed_expr) =
    (match e.Ast.it with
     | `Var name | `Assign (name, _) ->
       if not (List.mem_assoc name !used) then used := (name, e.Ast.span) :: !used
     | `Lambda (ps, _, _) -> bind_params ps
     | `Match_expr (_, cases) -> bind_patterns cases
     | `Run_expr (_, _, Some c) -> bind c.Ast.rc_param
     | _ -> ());
    ignore (children e)
  and seen e =
    expr e;
    e
  and seen_stmt s =
    stmt s;
    s
  and handler (h : Ast.typed_stmt Ast.handler) =
    List.iter (fun (a : Ast.typed_stmt Ast.arm) -> List.iter bind a.Ast.arm_params) h.Ast.arms;
    Ast.map_handler seen_stmt h
  and children (e : Ast.typed_expr) : Ast.typed_expr_kind =
    match e.Ast.it with
    | `Lambda (ps, sg, b) -> `Lambda (ps, sg, List.map seen_stmt b)
    | #Ast.lit as l -> l
    | #Ast.arrays as a -> (Ast.map_arrays seen a :> Ast.typed_expr_kind)
    | #Ast.strings as x -> (Ast.map_strings seen x :> Ast.typed_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars seen v :> Ast.typed_expr_kind)
    | #Ast.ops as o -> (Ast.map_ops seen o :> Ast.typed_expr_kind)
    | #Ast.logic as l -> (Ast.map_logic seen l :> Ast.typed_expr_kind)
    | #Ast.compound as c -> (Ast.map_compound seen c :> Ast.typed_expr_kind)
    | #Ast.indexing as i -> (Ast.map_indexing seen i :> Ast.typed_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple seen t :> Ast.typed_expr_kind)
    | #Ast.spread as x -> (Ast.map_spread seen x :> Ast.typed_expr_kind)
    | #Ast.record as r -> (Ast.map_record seen r :> Ast.typed_expr_kind)
    | #Ast.nominal as n -> (Ast.map_nominal seen n :> Ast.typed_expr_kind)
    | #Ast.collection as c -> (Ast.map_collection seen c :> Ast.typed_expr_kind)
    | #Ast.bound_calls as b -> (Ast.map_bound_call seen Fun.id b :> Ast.typed_expr_kind)
    | #Ast.coercions as c -> (Ast.map_coercion seen Fun.id c :> Ast.typed_expr_kind)
    | #Ast.dyn_calls as d -> (Ast.map_dyn_call seen Fun.id d :> Ast.typed_expr_kind)
    | #Ast.reflect as r -> (Ast.map_reflect seen r :> Ast.typed_expr_kind)
    | #Ast.run_expr as r -> (Ast.map_run_expr seen seen_stmt handler r :> Ast.typed_expr_kind)
    | #Ast.match_expr as m -> (Ast.map_match_expr seen seen_stmt m :> Ast.typed_expr_kind)
  and stmt (s : Ast.typed_stmt) =
    (match s.Ast.it with
     | `Var_decl (name, _, _) -> bind name
     | `Var_tuple (names, _) -> List.iter bind names
     | `Fn (name, ps, _, _) ->
       bind name;
       bind_params ps
     | `Match (_, cases) -> bind_patterns cases
     | _ -> ());
    let (_ : Ast.typed_stmt_kind) =
      match s.Ast.it with
      | #Ast.stmts as st -> (Ast.map_stmts seen seen_stmt st :> Ast.typed_stmt_kind)
      | #Ast.effects as ef -> (Ast.map_effects seen seen_stmt handler ef :> Ast.typed_stmt_kind)
      | #Ast.type_defs as t -> t
      | #Ast.method_defs as m -> (Ast.map_method_defs seen_stmt Fun.id m :> Ast.typed_stmt_kind)
      | #Ast.matching as m -> (Ast.map_matching seen seen_stmt m :> Ast.typed_stmt_kind)
    in
    ()
  in
  bind_params params;
  List.iter stmt body;
  List.rev !used, bound

(* A variable at a call that no declaration around it owns is one nothing
   constrains -- `attempt` around work that throws nothing has no `X` -- so any
   type will do, and one is needed for the call to get an instance at all. An
   owned one is left for the instance of its owner to settle. *)
let settled state (t : Types.ty) =
  fst (Types.variables t)
  |> List.filter (fun id -> not (List.mem id state.owned))
  |> List.sort_uniq compare
  |> List.map (fun id -> id, Types.Unit)

let owning state (ann : Types.ty) f =
  let saved = state.owned in
  state.owned <- fst (Types.variables ann) @ saved;
  Fun.protect ~finally:(fun () -> state.owned <- saved) f

(* A nested function that is itself one of the generics is reached through the
   table as before; any other name the body binds hides a generic's. *)
let binding state params body f =
  let _, bound = names_in params body in
  let rec own_generics (s : Ast.typed_stmt) =
    match s.Ast.it with
    | `Fn (name, _, _, _) ->
      (match Hashtbl.find_opt state.generic name with
       | Some registered when registered == s -> [ name ]
       | _ -> [])
    | `Block inner | `Run (inner, _) -> List.concat_map own_generics inner
    | `If (_, t, e) -> own_generics t @ Option.fold ~none:[] ~some:own_generics e
    | `While (_, inner) -> own_generics inner
    | `Match (_, cases) -> List.concat_map (fun (_, inner) -> List.concat_map own_generics inner) cases
    | _ -> []
  in
  let reachable = List.concat_map own_generics body in
  let hidden =
    Hashtbl.fold (fun name () acc -> if List.mem name reachable then acc else name :: acc) bound []
  in
  let saved = state.shadowed in
  state.shadowed <- hidden @ saved;
  Fun.protect ~finally:(fun () -> state.shadowed <- saved) f

let rec rewrite state (e : Ast.typed_expr) : Ast.typed_expr =
  let ann = ref e.Ast.ann in
  let it : Ast.typed_expr_kind =
    match e.Ast.it with
    | `Lambda (params, signature, body) ->
      binding state params body (fun () ->
        `Lambda (params, signature, List.map (rewrite_stmt state) body))
    | `Bound_call (receiver, name, dispatch, args) ->
      let receiver = rewrite state receiver in
      let args = List.map (rewrite state) args in
      (* The receiver is a type by now or the body is still generic, and the
         bound already said which impl a type answers with. *)
      let owned =
        Option.map
          (fun owner -> Registry.dispatched dispatch owner name)
          (Types.type_name receiver.Ast.ann)
      in
      (match owned with
       | Some mangled when Hashtbl.mem state.generic mangled ->
         let at = method_call_type state mangled receiver args e.Ast.ann in
         let at = Types.subst_generic (settled state at) at in
         if Types.has_generic at
         then `Bound_call (receiver, name, dispatch, args)
         else (
           let copy = copy_for state mangled at in
           let passed =
             match Types.type_name receiver.Ast.ann with
             | Some owner when Registry.is_associated state.registry owner name -> args
             | _ -> receiver :: args
           in
           `Call ({ receiver with Ast.it = `Var copy; ann = at }, passed))
       | _ -> `Bound_call (receiver, name, dispatch, args))
    | `Call (callee, args) ->
      let args = List.map (rewrite state) args in
      (match callee.Ast.it with
       | `Var name
         when Hashtbl.mem state.generic name
              && (not (List.mem name state.shadowed))
              && not
                   (Types.has_generic
                      (Types.subst_generic (settled state callee.Ast.ann) callee.Ast.ann)) ->
         let mapping = settled state callee.Ast.ann in
         let at = Types.subst_generic mapping callee.Ast.ann in
         let copy = copy_for state name at in
         ann := Types.subst_generic mapping e.Ast.ann;
         `Call ({ callee with Ast.it = `Var copy; ann = at }, List.map (subst_expr mapping) args)
       | _ -> `Call (rewrite state callee, args))
    (* A generic passed as a value gets an instance at the type it is passed
       at, as a call does; the name alone would reach nothing once only its
       instances are emitted. *)
    | `Var name when Hashtbl.mem state.generic name && not (List.mem name state.shadowed) ->
      let mapping = settled state e.Ast.ann in
      let at = Types.subst_generic mapping e.Ast.ann in
      if Types.has_generic at
      then `Var name
      else (
        ann := at;
        `Var (copy_for state name at))
    | #Ast.lit as l -> l
    | #Ast.arrays as a -> (Ast.map_arrays (rewrite state) a :> Ast.typed_expr_kind)
    | #Ast.strings as s -> (Ast.map_strings (rewrite state) s :> Ast.typed_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars (rewrite state) v :> Ast.typed_expr_kind)
    | #Ast.ops as o -> (Ast.map_ops (rewrite state) o :> Ast.typed_expr_kind)
    | #Ast.logic as l -> (Ast.map_logic (rewrite state) l :> Ast.typed_expr_kind)
    | #Ast.compound as c -> (Ast.map_compound (rewrite state) c :> Ast.typed_expr_kind)
    | #Ast.indexing as i -> (Ast.map_indexing (rewrite state) i :> Ast.typed_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple (rewrite state) t :> Ast.typed_expr_kind)
    | #Ast.spread as s -> (Ast.map_spread (rewrite state) s :> Ast.typed_expr_kind)
    | #Ast.record as r -> (Ast.map_record (rewrite state) r :> Ast.typed_expr_kind)
    | #Ast.nominal as n -> (Ast.map_nominal (rewrite state) n :> Ast.typed_expr_kind)
    | #Ast.collection as c ->
      (Ast.map_collection (rewrite state) c :> Ast.typed_expr_kind)
    | #Ast.coercions as c ->
      (Ast.map_coercion (rewrite state) (fun t -> t) c :> Ast.typed_expr_kind)
    | #Ast.dyn_calls as d ->
      (Ast.map_dyn_call (rewrite state) (fun t -> t) d :> Ast.typed_expr_kind)
    (* Answered from the annotation and never evaluated, so what it names is
       the generic itself, not an instance of it. *)
    | #Ast.reflect as r -> (r :> Ast.typed_expr_kind)
    | #Ast.run_expr as r ->
      (Ast.map_run_expr
         (rewrite state)
         (rewrite_stmt state)
         (Ast.map_handler (rewrite_stmt state))
         r
       :> Ast.typed_expr_kind)
    | #Ast.match_expr as m ->
      (Ast.map_match_expr (rewrite state) (rewrite_stmt state) m :> Ast.typed_expr_kind)
  in
  { e with Ast.it; ann = !ann }

and rewrite_stmt state (s : Ast.typed_stmt) : Ast.typed_stmt =
  let it : Ast.typed_stmt_kind =
    match s.Ast.it with
    | `Fn (name, params, signature, body) ->
      owning state s.Ast.ann (fun () ->
        binding state params body (fun () ->
          `Fn (name, params, signature, List.map (rewrite_stmt state) body)))
    | `Impl_decl (trait, type_name, params, impl) ->
      let method_ (m : (Ast.typed_stmt, Types.ty) Ast.method_def) =
        owning state m.Ast.md_ann (fun () ->
          binding state m.Ast.md_params m.Ast.md_body (fun () ->
            { m with Ast.md_body = List.map (rewrite_stmt state) m.Ast.md_body }))
      in
      `Impl_decl
        (trait, type_name, params, { impl with Ast.ib_methods = List.map method_ impl.Ast.ib_methods })
    | #Ast.stmts as st ->
      (Ast.map_stmts (rewrite state) (rewrite_stmt state) st :> Ast.typed_stmt_kind)
    | #Ast.effects as e ->
      (Ast.map_effects
         (rewrite state)
         (rewrite_stmt state)
         (Ast.map_handler (rewrite_stmt state))
         e
       :> Ast.typed_stmt_kind)
    | #Ast.type_defs as t -> t
    | #Ast.method_defs as m ->
      (Ast.map_method_defs (rewrite_stmt state) Fun.id m :> Ast.typed_stmt_kind)
    | #Ast.matching as m ->
      (Ast.map_matching (rewrite state) (rewrite_stmt state) m :> Ast.typed_stmt_kind)
  in
  { s with Ast.it }

type error =
  { span : Ast.span
  ; message : string
  }

exception Failed of error

(* What a function declared in a body inherits from the functions around it. A
   variable of theirs is settled when they are copied, so it makes nothing
   generic here. *)
type scope =
  { owner : string option
  ; generics : int list
  ; rows : int list
  ; locals : string list
  }

let top = { owner = None; generics = []; rows = []; locals = [] }

let within scope name params body ann =
  let generics, rows = Types.variables ann in
  let _, bound = names_in params body in
  { owner = Some name
  ; generics = generics @ scope.generics
  ; rows = rows @ scope.rows
  ; locals = Hashtbl.fold (fun local () acc -> local :: acc) bound scope.locals
  }

(* An instance is emitted at the top of the program, away from the body that
   declared its generic, so it cannot see that body's locals. *)
let refuse_captures owner name params body locals =
  let used, bound = names_in params body in
  let captured =
    List.filter
      (fun (local, _) ->
        List.mem local locals && (not (Hashtbl.mem bound local)) && not (String.equal local name))
      used
  in
  match captured with
  | [] -> ()
  | (_, span) :: _ ->
    let quoted = String.concat ", " (List.map (fun (local, _) -> "'" ^ local ^ "'") captured) in
    raise
      (Failed
         { span
         ; message =
             Printf.sprintf
               "'%s' is compiled once per type or effect row it is called at, so it cannot \
                read %s from '%s'. Pass %s in, or declare '%s' outside '%s'."
               name
               quoted
               owner
               (if List.length captured = 1 then "it" else "them")
               name
               owner
         })

let rec collect state scope (s : Ast.typed_stmt) =
  match s.Ast.it with
  | `Fn (name, params, _, body) ->
    let own = List.filter (fun id -> not (List.mem id scope.generics)) (fst (Types.variables s.Ast.ann)) in
    if (own <> [] && type_directed name s) || Types.row_polymorphic ~inherited:scope.rows s.Ast.ann
    then (
      Option.iter (fun owner -> refuse_captures owner name params body scope.locals) scope.owner;
      Hashtbl.replace state.generic name s);
    List.iter (collect state (within scope name params body s.Ast.ann)) body
  | `Impl_decl (trait, type_name, _, impl) ->
    List.iter
      (fun (m : (Ast.typed_stmt, Types.ty) Ast.method_def) ->
        let mangled = Ast.impl_method_name trait type_name m.Ast.md_name in
        if Types.has_generic m.Ast.md_ann
           && List.exists (type_directed mangled) m.Ast.md_body
        then
          Hashtbl.replace
            state.generic
            mangled
            { s with
              Ast.it = `Fn (mangled, m.Ast.md_params, m.Ast.md_signature, m.Ast.md_body)
            ; ann = m.Ast.md_ann
            };
        List.iter
          (collect state (within scope mangled m.Ast.md_params m.Ast.md_body m.Ast.md_ann))
          m.Ast.md_body)
      impl.Ast.ib_methods
  | `Block body -> List.iter (collect state scope) body
  | `If (_, then_branch, else_branch) ->
    collect state scope then_branch;
    Option.iter (collect state scope) else_branch
  | `While (_, body) -> collect state scope body
  | `Run (body, _) -> List.iter (collect state scope) body
  | `Match (_, cases) ->
    List.iter (fun (_, body) -> List.iter (collect state scope) body) cases
  | _ -> ()

(* A monomorphized generic's own body still names types nothing can select on. *)
let is_monomorphized state (s : Ast.typed_stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) -> Hashtbl.mem state.generic name
  | _ -> false

(* Each round of draining specializes one level deeper, and real nesting is
   shallow — a chain of generic calls each needing a copy of the next. A
   function that calls itself at a new type never converges, and the type grows
   with every round, so the cap has to bite before the types themselves get
   expensive to print rather than merely numerous. *)
let depth_limit = 16

let program ~registry (p : Ast.typed_stmt list) : Ast.typed_stmt list =
  let state =
    { registry
    ; generic = Hashtbl.create 8
    ; copies = Hashtbl.create 8
    ; origin = Hashtbl.create 8
    ; emitted = []
    ; changed = false
    ; rewriting = None
    ; recursive = None
    ; owned = []
    ; shadowed = []
    }
  in
  List.iter (collect state top) p;
  if Hashtbl.length state.generic = 0
  then p
  else (
    let rewritten =
      List.filter_map
        (fun s -> if is_monomorphized state s then None else Some (rewrite_stmt state s))
        p
    in
    (* An instance may itself call a generic at a type nothing has asked for yet. *)
    let rec drain depth acc =
      if depth > depth_limit
      then (
        let deepest = state.recursive in
        let span =
          match Option.bind deepest (Hashtbl.find_opt state.generic) with
          | Some (d : Ast.typed_stmt) -> d.Ast.span
          | None -> Source_map.Span.nowhere
        in
        raise
          (Failed
             { span
             ; message =
                 Printf.sprintf
                   "'%s' calls itself at a new type each time, so there is no finite set of copies of it."
                   (Option.value deepest ~default:"this function")
             }));
      let fresh = state.emitted in
      state.emitted <- [];
      state.changed <- false;
      let done_ =
        List.rev_map
          (fun (s : Ast.typed_stmt) ->
            state.rewriting <-
              (match s.Ast.it with
               | `Fn (name, _, _, _) -> Hashtbl.find_opt state.origin name
               | _ -> None);
            rewrite_stmt state s)
          fresh
      in
      state.rewriting <- None;
      if state.changed then drain (depth + 1) (done_ @ acc) else done_ @ acc
    in
    drain 0 [] @ rewritten)
