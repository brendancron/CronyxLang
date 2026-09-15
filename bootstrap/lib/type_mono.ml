(* An operator inside a generic body cannot be selected while the body is
   generic, so it is copied per concrete type its call sites use. *)
type state =
  { registry : Registry.t
  ; generic : (string, Ast.typed_stmt) Hashtbl.t
  ; copies : (string * Types.ty, string) Hashtbl.t
  ; (* So a copy asking for another copy of its own template is recognized. *)
    origin : (string, string) Hashtbl.t
  ; mutable emitted : Ast.typed_stmt list
  ; mutable changed : bool
  ; mutable rewriting : string option
  ; mutable recursive : string option
  }

(* A call the body makes to itself at another type is deliberately not counted:
   every copy would ask for one more. Such a function stays generic. *)
let rec type_directed_expr self (e : Ast.typed_expr) =
  let operand (child : Ast.typed_expr) = Types.has_generic child.Ast.ann in
  let type_directed_expr = type_directed_expr self in
  match e.Ast.it with
  | `Binop (_, a, b) -> operand a || operand b || type_directed_expr a || type_directed_expr b
  | `Compound (_, _, v) -> Types.has_generic e.Ast.ann || type_directed_expr v
  | `Method_call (receiver, _, _, args) ->
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
    | #Ast.method_call as m ->
      (Ast.map_method_call (subst_expr mapping) m :> Ast.typed_expr_kind)
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

(* From the template, not the call site: CPS reads it off the callee. *)
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

let rec rewrite state (e : Ast.typed_expr) : Ast.typed_expr =
  let it : Ast.typed_expr_kind =
    match e.Ast.it with
    | `Lambda (params, signature, body) ->
      `Lambda (params, signature, List.map (rewrite_stmt state) body)
        | `Method_call (receiver, name, as_function, args) ->
      let receiver = rewrite state receiver in
      let args = List.map (rewrite state) args in
      (* A trait impl's method is mangled with the trait it answers, so the
         registry is what says which entry a receiver's method is. *)
      let owned =
        match Types.type_name receiver.Ast.ann with
        | Some owner -> Some (Registry.entry_for_method state.registry owner name)
        | None -> None
      in
      (match owned with
       | Some mangled when Hashtbl.mem state.generic mangled ->
         let at = method_call_type state mangled receiver args e.Ast.ann in
         if Types.has_generic at
         then `Method_call (receiver, name, as_function, args)
         else (
           let copy = copy_for state mangled at in
           let passed =
             match Types.type_name receiver.Ast.ann with
             | Some owner when Registry.is_associated state.registry owner name -> args
             | _ -> receiver :: args
           in
           `Call ({ receiver with Ast.it = `Var copy; ann = at }, passed))
       | _ -> `Method_call (receiver, name, as_function, args))
    | `Call (callee, args) ->
      let args = List.map (rewrite state) args in
      (match callee.Ast.it with
       | `Var name
         when Hashtbl.mem state.generic name && not (Types.has_generic callee.Ast.ann) ->
         let copy = copy_for state name callee.Ast.ann in
         `Call ({ callee with Ast.it = `Var copy }, args)
       | _ -> `Call (rewrite state callee, args))
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
    | #Ast.reflect as r -> (Ast.map_reflect (rewrite state) r :> Ast.typed_expr_kind)
    | #Ast.run_expr as r ->
      (Ast.map_run_expr
         (rewrite state)
         (rewrite_stmt state)
         (Ast.map_handler (rewrite_stmt state))
         r
       :> Ast.typed_expr_kind)
  in
  { e with Ast.it }

and rewrite_stmt state (s : Ast.typed_stmt) : Ast.typed_stmt =
  let it : Ast.typed_stmt_kind =
    match s.Ast.it with
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

let rec collect state (s : Ast.typed_stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, body) ->
    if (Types.has_generic s.Ast.ann && type_directed name s)
       || Types.row_polymorphic s.Ast.ann
    then Hashtbl.replace state.generic name s;
    List.iter (collect state) body
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
        List.iter (collect state) m.Ast.md_body)
      impl.Ast.ib_methods
  | `Block body -> List.iter (collect state) body
  | `If (_, then_branch, else_branch) ->
    collect state then_branch;
    Option.iter (collect state) else_branch
  | `While (_, body) -> collect state body
  | `Run (body, _) -> List.iter (collect state) body
  | `Match (_, cases) ->
    List.iter (fun (_, body) -> List.iter (collect state) body) cases
  | _ -> ()

(* A template's own body still names types nothing can select on. *)
let is_template state (s : Ast.typed_stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) -> Hashtbl.mem state.generic name
  | _ -> false

type error =
  { span : Ast.span
  ; message : string
  }

exception Diverged of error

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
    }
  in
  List.iter (collect state) p;
  if Hashtbl.length state.generic = 0
  then p
  else (
    let rewritten =
      List.filter_map
        (fun s -> if is_template state s then None else Some (rewrite_stmt state s))
        p
    in
    (* A copy may itself call a template at a type nothing has asked for yet. *)
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
          (Diverged
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
