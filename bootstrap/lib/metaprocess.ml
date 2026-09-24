(* The rest of the pipeline, applied to a fragment of the program it belongs
   to and then removed. *)

type error =
  { span : Ast.span
  ; message : string
  }

exception Failed of error

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Failed { span; message })) fmt

(* Narrower than [Loader.is_declaration], which counts the meta forms too. *)
let rec is_visible_to_meta (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn _ | `Type_decl _ | `Trait_decl _ | `Impl_decl _ | `Effect_decl _
  | `Handler_decl _ -> true
  | `Attributed (_, inner) -> is_visible_to_meta inner
  | _ -> false

(* The interpreter already compares two values of any shape, so a derived `Eq`
   reaches that rather than walking the type's fields. *)
let derived_eq span target : Ast.stmt =
  let at it = Ast.at span it in
  let ty name = { Ast.it = Ast.Ty_name name; span; ann = () } in
  Ast.at
    span
    (`Impl_decl
      ( Some ("Eq", [])
      , target
      , []
      , { Ast.ib_assoc = []
        ; ib_methods =
            [ { Ast.md_name = "eq"
              ; md_params =
                  [ { Ast.name = "self"; ty = None; implicit = false }
                  ; { Ast.name = "rhs"; ty = Some (ty target); implicit = false }
                  ]
              ; md_signature =
                  { Ast.ret = Some (ty "bool"); row = Some []; static_params = [] }
              ; md_body =
                  [ at
                      (`Return
                        (Some
                           (at
                              (`Call
                                ( at (`Var "__structural_eq")
                                , [ at (`Var "self"); at (`Var "rhs") ] )))))
                  ]
              ; md_ann = ()
              }
            ]
        } ))

(* ---- what a block emits ---- *)

let emitter = Ast.generated [ "meta"; "emit" ]
let capturer = Ast.generated [ "meta"; "value" ]
let quoter = Ast.generated [ "meta"; "code" ]

(* A value written back as the syntax that denotes it. A function and an object
   have no such syntax, so they are [None]. *)
let rec literal_of span (v : Value.value) : Ast.expr option =
  let at it = Ast.at span it in
  let all items =
    List.fold_right
      (fun v acc ->
        match acc, literal_of span v with
        | Some acc, Some e -> Some (e :: acc)
        | _ -> None)
      items
      (Some [])
  in
  match v with
  | Value.Code e -> Some e
  | Value.Int n -> Some (at (`Int n))
  | Value.Float n -> Some (at (`Float n))
  | Value.Str s -> Some (at (`Str s))
  | Value.Bool b -> Some (at (`Bool b))
  | Value.Chr c -> Some (at (`Char c))
  | Value.Unit -> Some (at `Unit)
  | Value.Tuple items -> Option.map (fun items -> at (`Tuple items)) (all items)
  | Value.Array items ->
    Option.map (fun items -> at (`Collection_lit items)) (all (Array.to_list items))
  | Value.Record (named, fields) ->
    Option.map
      (fun values ->
        let fields = List.combine (List.map fst fields) values in
        match named with
        | Some name -> at (`New (name, fields))
        | None -> at (`Record_lit fields))
      (all (List.map (fun (_, v) -> !v) fields))
  | Value.Variant (Some ty, variant, fields) ->
    let positional =
      List.for_all Fun.id (List.mapi (fun i (label, _) -> String.equal label (string_of_int i)) fields)
    in
    Option.map
      (fun values ->
        let payload : Ast.expr Ast.payload =
          match values with
          | [] -> Ast.P_none
          | values when positional -> Ast.P_tuple values
          | values -> Ast.P_fields (List.combine (List.map fst fields) values)
        in
        at (`New_variant (ty, variant, payload)))
      (all (List.map snd fields))
  | _ -> None

let promoted_prefix = Ast.generated [ "meta"; "promoted" ]

let is_promoted name =
  let n = String.length promoted_prefix in
  String.length name > n && String.equal (String.sub name 0 n) promoted_prefix

let unwritable span name (v : Value.value) =
  if is_promoted name
  then fail span "This expression cannot be written into generated code."
  else (
    match v with
    | Value.Fn _ -> fail span "'%s' is a function and cannot be written into generated code." name
    | Value.Object _ ->
      fail span "'%s' is a trait object and cannot be written into generated code." name
    | _ -> fail span "'%s' cannot be written into generated code." name)

let name_of (v : Value.value) =
  match v with
  | Value.Name n -> Some n
  | _ -> None

(* A generated declaration binding a name the meta program also bound means its
   own local. *)
module Shadowed = Set.Make (String)

let substitution (bound : (string, Value.value) Hashtbl.t) =
  let named name =
    match Hashtbl.find_opt bound name with
    | Some v -> Option.value (name_of v) ~default:name
    | None -> name
  in
  let rec type_expr (t : Ast.type_expr) : Ast.type_expr =
    let it =
      match t.Ast.it with
      | Ast.Ty_variadic t -> Ast.Ty_variadic (type_expr t)
      | Ast.Ty_spread t -> Ast.Ty_spread (type_expr t)
      | Ast.Ty_name n -> Ast.Ty_name (named n)
      | Ast.Ty_assoc (owner, member) -> Ast.Ty_assoc (type_expr owner, member)
      | Ast.Ty_bind (bound, t) -> Ast.Ty_bind (bound, type_expr t)
      | Ast.Ty_app (n, args) -> Ast.Ty_app (named n, List.map type_expr args)
      | Ast.Ty_tuple items -> Ast.Ty_tuple (List.map type_expr items)
      | Ast.Ty_record fields ->
        Ast.Ty_record (List.map (fun (l, t) -> l, type_expr t) fields)
      | Ast.Ty_fn (args, ret, row) ->
        Ast.Ty_fn (List.map type_expr args, type_expr ret, row)
    in
    { t with Ast.it }
  in
  let param (p : Ast.param) = { p with Ast.ty = Option.map type_expr p.Ast.ty } in
  let signature (sg : Ast.signature) =
    { sg with
      Ast.ret = Option.map type_expr sg.Ast.ret
    ; static_params =
        List.map
          (fun (c : Ast.static_param) -> { c with Ast.sp_ty = Option.map type_expr c.Ast.sp_ty })
          sg.Ast.static_params
    }
  in
  let hidden shadowed names = List.fold_left (Fun.flip Shadowed.add) shadowed names
  and param_names params = List.map (fun (p : Ast.param) -> p.Ast.name) params in
  let rec expr shadowed (e : Ast.expr) : Ast.expr =
    let expr = expr shadowed in
    match e.Ast.it with
    | `Var name when Shadowed.mem name shadowed -> e
    | `Var name ->
      (match Hashtbl.find_opt bound name with
       | None -> e
       | Some v ->
         (match literal_of e.Ast.span v with
          | Some replacement -> replacement
          | None ->
            (match v with
             | Value.Name n -> { e with Ast.it = `Var n }
             | v -> unwritable e.Ast.span name v)))
    | it ->
      let it : Ast.expr_kind =
        match it with
        | `Lambda (params, sg, body) ->
          `Lambda
            ( List.map param params
            , signature sg
            , sequence (hidden shadowed (param_names params)) body )
        | `New (name, fields) -> `New (named name, List.map (fun (l, v) -> l, expr v) fields)
        | `New_variant (ty, variant, payload) ->
          `New_variant (named ty, variant, Ast.map_payload expr payload)
        | `New_call (name, args, values) ->
          `New_call (named name, List.map type_expr args, List.map expr values)
        | `New_generic (name, static_args, fields) ->
          `New_generic
            ( named name
            , List.map
                (function
                  | Ast.St_type t -> Ast.St_type (type_expr t)
                  | Ast.St_value v -> Ast.St_value (expr v))
                static_args
            , List.map (fun (l, v) -> l, expr v) fields )
        | `Method_call (receiver, name, as_function, args) ->
          `Method_call (expr receiver, named name, named as_function, List.map expr args)
        (* Lowered when the code holding it runs, not now. *)
        | `Code _ as c -> c
        | `Field (receiver, label) -> `Field (expr receiver, named label)
        | `Field_assign (receiver, label, v) ->
          `Field_assign (expr receiver, named label, expr v)
        | `Compound_field (op, receiver, label, v) ->
          `Compound_field (op, expr receiver, named label, expr v)
        | #Ast.lit as l -> l
        | #Ast.vars as v -> (Ast.map_vars expr v :> Ast.expr_kind)
        | #Ast.ops as o -> (Ast.map_ops expr o :> Ast.expr_kind)
        | #Ast.logic as l -> (Ast.map_logic expr l :> Ast.expr_kind)
        | #Ast.compound as c -> (Ast.map_compound expr c :> Ast.expr_kind)
        | #Ast.indexing as i -> (Ast.map_indexing expr i :> Ast.expr_kind)
        | #Ast.tuple as t -> (Ast.map_tuple expr t :> Ast.expr_kind)
        | #Ast.spread as sp -> (Ast.map_spread expr sp :> Ast.expr_kind)
        | #Ast.record as r -> (Ast.map_record expr r :> Ast.expr_kind)
        | #Ast.collection as c -> (Ast.map_collection expr c :> Ast.expr_kind)
        (* A bare name parses as a type, and a meta value there is a value. *)
        | `Static_call (callee, static_args, args) ->
          let arg (a : Ast.expr Ast.static_arg) =
            match a with
            | Ast.St_type { Ast.it = Ast.Ty_name n; span; _ }
              when not (Shadowed.mem n shadowed) ->
              (match Option.bind (Hashtbl.find_opt bound n) (literal_of span) with
               | Some v -> Ast.St_value v
               | None -> Ast.St_type (type_expr { Ast.it = Ast.Ty_name n; span; ann = () }))
            | a -> Ast.map_static_arg expr a
          in
          `Static_call (expr callee, List.map arg static_args, List.map expr args)
        | #Ast.reflect as r -> (Ast.map_reflect expr r :> Ast.expr_kind)
        | #Ast.run_expr as r ->
          let clause (c : Ast.stmt Ast.handler_clause) =
            match c with
            | Ast.Inline h -> Ast.Inline (Ast.map_handler (stmt shadowed) h)
            | Ast.Named name -> Ast.Named name
          in
          (Ast.map_run_expr expr (stmt shadowed) clause r :> Ast.expr_kind)
      in
      { e with Ast.it }
  and sequence shadowed (body : Ast.stmt list) : Ast.stmt list =
    match body with
    | [] -> []
    | s :: rest ->
      let walked = stmt shadowed s in
      let shadowed =
        match s.Ast.it with
        | `Var_decl (name, _, _) -> Shadowed.add name shadowed
        | _ -> shadowed
      in
      walked :: sequence shadowed rest
  and stmt shadowed (s : Ast.stmt) : Ast.stmt =
    let expr = expr shadowed in
    let it : Ast.stmt_kind =
      match s.Ast.it with
      | `Attributed (attrs, inner) -> `Attributed (attrs, stmt shadowed inner)
      | `Fn (name, params, sg, body) ->
        `Fn
          ( named name
          , List.map param params
          , signature sg
          , sequence (hidden shadowed (param_names params)) body )
      | `Block body -> `Block (sequence shadowed body)
      | `For_in (names, over, inner) ->
        `For_in
          (names, expr over, stmt (List.fold_left (Fun.flip Shadowed.add) shadowed names) inner)
      | `For (init, cond, step, inner) ->
        let inner_scope =
          match init with
          | Some { Ast.it = `Var_decl (name, _, _); _ } -> Shadowed.add name shadowed
          | _ -> shadowed
        in
        `For
          ( Option.map (stmt shadowed) init
          , Option.map (expr_in inner_scope) cond
          , Option.map (expr_in inner_scope) step
          , stmt inner_scope inner )
      | `Match (scrutinee, cases) ->
        `Match
          ( expr scrutinee
          , List.map
              (fun (pattern, body) ->
                let bound_here =
                  match pattern with
                  | Ast.Pat_variant (_, _, payload) ->
                    List.map snd (Ast.payload_fields payload)
                  | Ast.Pat_wild -> []
                in
                pattern, sequence (hidden shadowed bound_here) body)
              cases )
      | `Impl_decl (trait, type_name, params, impl) ->
        `Impl_decl
          ( Option.map (fun (t, args) -> named t, List.map type_expr args) trait
          , named type_name
          , params
          , { Ast.ib_assoc = List.map (fun (n, t) -> n, type_expr t) impl.Ast.ib_assoc
            ; ib_methods =
                List.map
                  (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                    { m with
                      Ast.md_params = List.map param m.Ast.md_params
                    ; md_signature = signature m.Ast.md_signature
                    ; md_body =
                        sequence (hidden shadowed (param_names m.Ast.md_params)) m.Ast.md_body
                    })
                  impl.Ast.ib_methods
            } )
      | `Derive (traits, target) -> `Derive (traits, named target)
      | `Type_decl (name, params, body) ->
        let body =
          match body with
          | Ast.T_fields fields ->
            Ast.T_fields (List.map (fun (f : Ast.field) -> { f with Ast.f_ty = type_expr f.Ast.f_ty }) fields)
          | Ast.T_variants variants ->
            Ast.T_variants
              (List.map
                 (fun (v : Ast.variant) ->
                   { v with
                     Ast.v_payload = Ast.map_payload type_expr v.Ast.v_payload
                   ; v_result = Option.map type_expr v.Ast.v_result
                   })
                 variants)
        in
        `Type_decl (named name, params, body)
      | `Trait_decl (name, params, methods) -> `Trait_decl (named name, params, methods)
      | `Gen inner -> `Gen (stmt shadowed inner)
      | `Type_members (decl, members) ->
        `Type_members (stmt shadowed decl, List.map (stmt shadowed) members)
      | `Meta body -> `Meta (sequence shadowed body)
      | `Import decl -> `Import decl
      | `Var_decl (name, ty, init) ->
        `Var_decl (name, Option.map type_expr ty, Option.map expr init)
      | `Var_tuple (names, init) -> `Var_tuple (names, expr init)
      | #Ast.stmts as st ->
        (Ast.map_stmts expr (stmt shadowed) st :> Ast.stmt_kind)
      | #Ast.effects as e ->
        let arm (a : Ast.stmt Ast.arm) =
          { a with Ast.arm_body = sequence (hidden shadowed a.Ast.arm_params) a.Ast.arm_body }
        in
        let handler (h : Ast.stmt Ast.handler) = { h with Ast.arms = List.map arm h.Ast.arms } in
        let clause (c : Ast.stmt Ast.handler_clause) =
          match c with
          | Ast.Inline h -> Ast.Inline (handler h)
          | Ast.Named n -> Ast.Named n
        in
        (Ast.map_effects expr (stmt shadowed) clause e :> Ast.stmt_kind)
      | `Handler_decl (n, h) ->
        let arm (a : Ast.stmt Ast.arm) =
          { a with Ast.arm_body = sequence (hidden shadowed a.Ast.arm_params) a.Ast.arm_body }
        in
        `Handler_decl (n, { h with Ast.arms = List.map arm h.Ast.arms })
    in
    { s with Ast.it }
  and expr_in shadowed e = expr shadowed e in
  expr Shadowed.empty, stmt Shadowed.empty

let substitute bound (root : Ast.stmt) : Ast.stmt = snd (substitution bound) root
let substitute_expr bound (e : Ast.expr) : Ast.expr = fst (substitution bound) e

(* A lowered `gen` or `code` carries its meta-bound names beside its index. *)
let bindings_of args =
  let bound = Hashtbl.create 8 in
  let rec pairs = function
    | Value.Str name :: value :: rest ->
      Hashtbl.replace bound (Utf8.encode name) value;
      pairs rest
    | _ -> ()
  in
  pairs args;
  bound

type context =
  { out : string -> unit
  ; (* Indexed by size at insertion, so nothing may be removed: a later entry
       would take an index already handed out. *)
    table : (int, Ast.stmt) Hashtbl.t
  ; codes : (int, Ast.expr) Hashtbl.t
  ; current : Ast.stmt list ref ref
  }

let emit_into { table; current; _ } span args =
  match args with
  | Value.Int index :: rest ->
    (match Hashtbl.find_opt table index with
     | Some captured -> !current := substitute (bindings_of rest) captured :: !(!current)
     | None -> Value.fail span "Nothing was captured here.")
  | _ -> Value.fail span "Nothing was captured here."

(* Run against an environment holding the three entries a lowered `gen` or
   `code` calls. *)
let run ~out ~codes ~emit ~capture (program : Ast.program) =
  match Compile.program program with
  | Error [] -> fail Source_map.Span.nowhere "The meta block does not check."
  | Error (e :: _) -> fail e.Diagnostic.span "%s" e.Diagnostic.message
  | Ok converted ->
    let env = Builtins.env ~out in
    let native name arity apply = Value.define env name (Value.Fn { Value.name; arity; apply }) in
    native capturer (Some 1) (fun _ args ->
      (match args with
       | [ v ] -> capture v
       | _ -> ());
      Value.Unit);
    native quoter None (fun span args ->
      match args with
      | Value.Int index :: rest ->
        (match Hashtbl.find_opt codes index with
         | Some captured -> Value.Code (substitute_expr (bindings_of rest) captured)
         | None -> Value.fail span "Nothing was captured here.")
      | _ -> Value.fail span "Nothing was captured here.");
    native emitter None (fun span args ->
      emit span args;
      Value.Unit);
    (match Compile.run env converted with
     | Ok () -> ()
     | Error e -> fail e.Diagnostic.span "%s" e.Diagnostic.message)


(* Inside a `gen`, the largest subexpression made only of meta-scope values is
   evaluated while the block runs and written back as a literal; the rest stays
   syntax. It is replaced by a placeholder the emitter binds, so it rides the
   same path a meta-bound name does. A static call is never evaluated whole —
   that would instantiate from inside the block — but its arguments may be. *)
let promote ~meta ~visible ~refs (s : Ast.stmt) : Ast.stmt * (string * Ast.expr) list =
  let extras = ref [] in
  let placeholder (e : Ast.expr) =
    let name = promoted_prefix ^ string_of_int (List.length !extras) in
    extras := (name, e) :: !extras;
    { e with Ast.it = `Var name }
  in
  (* The names an expression reads, or [None] if it cannot be evaluated early. *)
  let rec reads (e : Ast.expr) : Shadowed.t option =
    let all es =
      List.fold_left
        (fun acc e ->
          match acc, reads e with
          | Some acc, Some r -> Some (Shadowed.union acc r)
          | _ -> None)
        (Some Shadowed.empty)
        es
    in
    match e.Ast.it with
    | #Ast.lit -> Some Shadowed.empty
    | `Var name -> Some (Shadowed.singleton name)
    | `Unop (_, a) -> reads a
    | `Binop (_, a, b) | `And (a, b) | `Or (a, b) -> all [ a; b ]
    | `Call (callee, args) -> all (callee :: args)
    | `Method_call (receiver, _, _, args) -> all (receiver :: args)
    | `Index (a, b) -> all [ a; b ]
    | `Tuple items | `Collection_lit items -> all items
    | `Tuple_get (a, _) | `Field (a, _) -> reads a
    | `Record_lit fields -> all (List.map snd fields)
    | _ -> None
  in
  let evaluable shadowed (e : Ast.expr) =
    match e.Ast.it with
    | `Var _ | #Ast.lit -> false
    | _ ->
      (match reads e with
       | None -> false
       | Some names ->
         Shadowed.exists (fun n -> meta n && not (Shadowed.mem n shadowed)) names
         && Shadowed.for_all
              (fun n -> (not (Shadowed.mem n shadowed)) && (meta n || visible n))
              names)
  in
  let rec expr shadowed (e : Ast.expr) : Ast.expr =
    if evaluable shadowed e
    then (
      (match reads e with
       | Some names -> Shadowed.iter (fun n -> if not (meta n) then refs := Shadowed.add n !refs) names
       | None -> ());
      placeholder e)
    else children shadowed e
  and children shadowed (e : Ast.expr) : Ast.expr =
    let expr = expr shadowed in
    let it : Ast.expr_kind =
      match e.Ast.it with
      | `Lambda (params, sg, body) ->
        `Lambda
          ( params
          , sg
          , sequence
              (List.fold_left (fun acc (p : Ast.param) -> Shadowed.add p.Ast.name acc) shadowed params)
              body )
      | `Code _ as c -> c
      | #Ast.lit as l -> l
      | #Ast.vars as v -> (Ast.map_vars expr v :> Ast.expr_kind)
      | #Ast.ops as o -> (Ast.map_ops expr o :> Ast.expr_kind)
      | #Ast.logic as l -> (Ast.map_logic expr l :> Ast.expr_kind)
      | #Ast.compound as c -> (Ast.map_compound expr c :> Ast.expr_kind)
      | #Ast.indexing as i -> (Ast.map_indexing expr i :> Ast.expr_kind)
      | #Ast.tuple as t -> (Ast.map_tuple expr t :> Ast.expr_kind)
      | #Ast.spread as sp -> (Ast.map_spread expr sp :> Ast.expr_kind)
      | #Ast.record as r -> (Ast.map_record expr r :> Ast.expr_kind)
      | #Ast.nominal as n -> (Ast.map_nominal expr n :> Ast.expr_kind)
      | #Ast.collection as c -> (Ast.map_collection expr c :> Ast.expr_kind)
      | #Ast.static_call as c -> (Ast.map_static_call expr c :> Ast.expr_kind)
      | #Ast.method_call as m -> (Ast.map_method_call expr m :> Ast.expr_kind)
      | #Ast.reflect as r -> (Ast.map_reflect expr r :> Ast.expr_kind)
      | #Ast.generic_new as g -> (Ast.map_generic_new expr g :> Ast.expr_kind)
      | #Ast.run_expr as r -> (r :> Ast.expr_kind)
    in
    { e with Ast.it }
  and sequence shadowed (body : Ast.stmt list) : Ast.stmt list =
    match body with
    | [] -> []
    | s :: rest ->
      let walked = stmt shadowed s in
      let shadowed =
        match s.Ast.it with
        | `Var_decl (name, _, _) -> Shadowed.add name shadowed
        | `Var_tuple (names, _) -> List.fold_left (Fun.flip Shadowed.add) shadowed names
        | _ -> shadowed
      in
      walked :: sequence shadowed rest
  and stmt shadowed (s : Ast.stmt) : Ast.stmt =
    let expr = expr shadowed in
    let body names b =
      sequence (List.fold_left (Fun.flip Shadowed.add) shadowed names) b
    in
    let it : Ast.stmt_kind =
      match s.Ast.it with
      (* The call a statement makes is what is emitted; only its arguments may
         be evaluated now. *)
      | `Expr e -> `Expr (children shadowed e)
      | `Var_decl (name, ty, init) -> `Var_decl (name, ty, Option.map expr init)
      | `Var_tuple (names, init) -> `Var_tuple (names, expr init)
      | `Return e -> `Return (Option.map expr e)
      | `Block b -> `Block (sequence shadowed b)
      | `If (c, t, e) -> `If (expr c, stmt shadowed t, Option.map (stmt shadowed) e)
      | `While (c, b) -> `While (expr c, stmt shadowed b)
      | `Defer inner -> `Defer (stmt shadowed inner)
      | `Fn (name, params, sg, b) ->
        `Fn (name, params, sg, body (name :: List.map (fun (p : Ast.param) -> p.Ast.name) params) b)
      | `For_in (names, over, inner) ->
        `For_in (names, expr over, stmt (List.fold_left (Fun.flip Shadowed.add) shadowed names) inner)
      | `Match (subject, cases) ->
        `Match
          ( expr subject
          , List.map
              (fun (pattern, b) ->
                let bound =
                  match pattern with
                  | Ast.Pat_variant (_, _, payload) -> List.map snd (Ast.payload_fields payload)
                  | Ast.Pat_wild -> []
                in
                pattern, body bound b)
              cases )
      | `Impl_decl (trait, ty, params, impl) ->
        `Impl_decl
          ( trait
          , ty
          , params
          , { impl with
              Ast.ib_methods =
                List.map
                  (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                    { m with
                      Ast.md_body =
                        body (List.map (fun (p : Ast.param) -> p.Ast.name) m.Ast.md_params) m.Ast.md_body
                    })
                  impl.Ast.ib_methods
            } )
      | `Attributed (attrs, inner) -> `Attributed (attrs, stmt shadowed inner)
      | other -> other
    in
    { s with Ast.it }
  in
  let s = stmt Shadowed.empty s in
  s, List.rev !extras

(* Surface syntax, which every later IR has dropped, so it reaches the
   interpreter as a table index. *)
let lower { table; codes; _ } ~visible ~refs ~params (body : Ast.program) =
  let arguments sp scope =
    List.concat_map
      (fun name -> [ Ast.at sp (`Str (Utf8.decode name)); Ast.at sp (`Var name) ])
      (List.sort_uniq String.compare scope)
  in
  let call sp index scope callee =
    Ast.at
      sp
      (`Call (Ast.at sp (`Var callee), Ast.at sp (`Int index) :: arguments sp scope))
  in
  let rec expr scope (e : Ast.expr) : Ast.expr =
    let sp = e.Ast.span in
    match e.Ast.it with
    | `Code inner ->
      let index = Hashtbl.length codes in
      Hashtbl.replace codes index inner;
      { e with Ast.it = (call sp index scope quoter).Ast.it }
    | it ->
      let expr = expr scope in
      let it : Ast.expr_kind =
        match it with
        | `Code _ as c -> c
        | `Lambda (params, sg, body) -> `Lambda (params, sg, block scope body)
        | #Ast.lit as l -> l
        | #Ast.vars as v -> (Ast.map_vars expr v :> Ast.expr_kind)
        | #Ast.ops as o -> (Ast.map_ops expr o :> Ast.expr_kind)
        | #Ast.logic as l -> (Ast.map_logic expr l :> Ast.expr_kind)
        | #Ast.compound as c -> (Ast.map_compound expr c :> Ast.expr_kind)
        | #Ast.indexing as i -> (Ast.map_indexing expr i :> Ast.expr_kind)
        | #Ast.tuple as t -> (Ast.map_tuple expr t :> Ast.expr_kind)
        | #Ast.spread as sp -> (Ast.map_spread expr sp :> Ast.expr_kind)
        | #Ast.record as r -> (Ast.map_record expr r :> Ast.expr_kind)
        | #Ast.nominal as n -> (Ast.map_nominal expr n :> Ast.expr_kind)
        | #Ast.collection as c -> (Ast.map_collection expr c :> Ast.expr_kind)
        | #Ast.static_call as c -> (Ast.map_static_call expr c :> Ast.expr_kind)
        | #Ast.method_call as m -> (Ast.map_method_call expr m :> Ast.expr_kind)
        | #Ast.reflect as r -> (Ast.map_reflect expr r :> Ast.expr_kind)
        | #Ast.generic_new as g -> (Ast.map_generic_new expr g :> Ast.expr_kind)
        | #Ast.run_expr as r ->
          let clause (c : Ast.stmt Ast.handler_clause) =
            match c with
            | Ast.Inline h -> Ast.Inline (Ast.map_handler (fun s -> fst (stmt scope s)) h)
            | Ast.Named name -> Ast.Named name
          in
          (Ast.map_run_expr expr (fun s -> fst (stmt scope s)) clause r :> Ast.expr_kind)
      in
      { e with Ast.it }
  (* A `code` in an initializer cannot be given the name it initializes. *)
  and stmt scope (s : Ast.stmt) : Ast.stmt * string list =
    let sp = s.Ast.span in
    let same it = { s with Ast.it = it }, scope in
    match s.Ast.it with
    | `Gen inner ->
      let meta name = List.mem name scope in
      let inner, extras = promote ~meta ~visible ~refs inner in
      let index = Hashtbl.length table in
      Hashtbl.replace table index inner;
      let call = call sp index scope emitter in
      let extras =
        List.concat_map
          (fun (name, e) -> [ Ast.at sp (`Str (Utf8.decode name)); e ])
          extras
      in
      (match call.Ast.it with
       | `Call (callee, args) -> same (`Expr { call with Ast.it = `Call (callee, args @ extras) })
       | _ -> same (`Expr call))
    | `Var_decl (name, ty, init) ->
      { s with Ast.it = `Var_decl (name, ty, Option.map (expr scope) init) }, name :: scope
    | `Block body -> same (`Block (block scope body))
    | `While (cond, body) -> same (`While (expr scope cond, fst (stmt scope body)))
    | `If (cond, t, e) ->
      same (`If (expr scope cond, fst (stmt scope t), Option.map (fun e -> fst (stmt scope e)) e))
    | `For_in (names, iterable, body) ->
      same (`For_in (names, expr scope iterable, fst (stmt (names @ scope) body)))
    | `For (init, cond, step, body) ->
      let init, inner =
        match init with
        | None -> None, scope
        | Some i ->
          let i, inner = stmt scope i in
          Some i, inner
      in
      same
        (`For
           ( init
           , Option.map (expr inner) cond
           , Option.map (expr inner) step
           , fst (stmt inner body) ))
    | #Ast.stmts as st -> same (Ast.map_stmts (expr scope) (fun b -> fst (stmt scope b)) st :> Ast.stmt_kind)
    | `Match (subject, arms) ->
      same
        (`Match
           ( expr scope subject
           , List.map
               (fun ((p, body) : Ast.pattern * Ast.stmt list) ->
                 let inner =
                   match p with
                   | Ast.Pat_variant (_, _, payload) ->
                     List.map snd (Ast.payload_fields payload) @ scope
                   | Ast.Pat_wild -> scope
                 in
                 p, block inner body)
               arms ))
    | _ -> s, scope
  and block scope body =
    List.rev (fst (List.fold_left (fun (out, scope) s ->
      let s, scope = stmt scope s in
      s :: out, scope) ([], scope) body))
  in
  block params body


(* ---- the walk ----

   A declaration is metaprocessed the first time the walk from the entry file's
   top-level statements reaches it, and what nothing reaches never is. *)

module S = Shadowed

type hooks =
  { var : S.t -> Ast.expr -> Ast.expr
  ; static_call : S.t -> Ast.expr -> Ast.expr
  ; method_call : S.t -> Ast.expr -> Ast.expr
  ; call : S.t -> Ast.expr -> Ast.expr
  ; code : S.t -> Ast.expr -> Ast.expr
  ; generic_new : S.t -> Ast.expr -> Ast.expr
  ; (* A local being bound, before it is in scope. *)
    local : string -> Ast.type_expr option -> Ast.expr option -> unit
  ; meta : S.t -> Ast.stmt -> Ast.stmt list
  ; gen : S.t -> Ast.stmt -> Ast.stmt list
  }

let quiet =
  { var = (fun _ e -> e)
  ; static_call = (fun _ e -> e)
  ; method_call = (fun _ e -> e)
  ; call = (fun _ e -> e)
  ; code = (fun _ e -> e)
  ; generic_new = (fun _ e -> e)
  ; local = (fun _ _ _ -> ())
  ; meta = (fun _ s -> [ s ])
  ; gen = (fun _ s -> [ s ])
  }

let with_params scope params =
  List.fold_left (fun acc (p : Ast.param) -> S.add p.Ast.name acc) scope params

let pattern_names (p : Ast.pattern) =
  match p with
  | Ast.Pat_variant (_, _, payload) -> List.map snd (Ast.payload_fields payload)
  | Ast.Pat_wild -> []

let declared_here scope (s : Ast.stmt) =
  match s.Ast.it with
  | `Var_decl (name, _, _) | `Fn (name, _, _, _) -> S.add name scope
  | `Var_tuple (names, _) -> List.fold_left (Fun.flip S.add) scope names
  | _ -> scope

(* [scope] is what the code being walked binds, so a hook only ever sees a name
   nothing local answers to. Children are visited left to right, each [let]
   forcing the order: the walk runs meta blocks as it goes, so its order is the
   order of a program's compile-time output, and OCaml evaluates constructor
   arguments right to left. *)
let rec texpr h scope (e : Ast.expr) : Ast.expr =
  let ex = texpr h scope in
  let two a b =
    let a = ex a in
    a, ex b
  in
  let many items = List.map ex items in
  match e.Ast.it with
  | `Var name -> if S.mem name scope then e else h.var scope e
  | `Static_call (callee, static_args, args) ->
    let callee =
      match callee.Ast.it with
      | `Var _ -> callee
      | _ -> ex callee
    in
    let static_args = List.map (Ast.map_static_arg ex) static_args in
    let args = many args in
    h.static_call scope { e with Ast.it = `Static_call (callee, static_args, args) }
  | `Method_call (receiver, name, as_function, args) ->
    let receiver = ex receiver in
    let args = many args in
    h.method_call scope { e with Ast.it = `Method_call (receiver, name, as_function, args) }
  | `Code _ -> h.code scope e
  | `Lambda (params, sg, body) ->
    { e with Ast.it = `Lambda (params, sg, tblock h (with_params scope params) body) }
  | `Run_expr (body, handlers, clause) ->
    let body = tvalued h scope body in
    let handlers = List.map (tclause h scope) handlers in
    let clause =
      Option.map
        (fun (c : (Ast.expr, Ast.stmt) Ast.ret_clause) ->
          { c with Ast.rc_body = tvalued h (S.add c.Ast.rc_param scope) c.Ast.rc_body })
        clause
    in
    { e with Ast.it = `Run_expr (body, handlers, clause) }
  | it ->
    let it : Ast.expr_kind =
      match it with
      | #Ast.lit as l -> l
      | `Assign (name, v) -> `Assign (name, ex v)
      | `Unop (op, a) -> `Unop (op, ex a)
      | `Binop (op, a, b) ->
        let a, b = two a b in
        `Binop (op, a, b)
      | `Call (callee, args) ->
        let callee = ex callee in
        (h.call scope { e with Ast.it = `Call (callee, many args) }).Ast.it
      | `And (a, b) ->
        let a, b = two a b in
        `And (a, b)
      | `Or (a, b) ->
        let a, b = two a b in
        `Or (a, b)
      | `Compound (op, name, v) -> `Compound (op, name, ex v)
      | `Compound_index (op, a, b, c) ->
        let a, b = two a b in
        `Compound_index (op, a, b, ex c)
      | `Compound_field (op, a, label, v) ->
        let a, v = two a v in
        `Compound_field (op, a, label, v)
      | `Index (a, b) ->
        let a, b = two a b in
        `Index (a, b)
      | `Index_assign (a, b, c) ->
        let a, b = two a b in
        `Index_assign (a, b, ex c)
      | `Tuple items -> `Tuple (many items)
      | `Tuple_get (a, i) -> `Tuple_get (ex a, i)
      | `Spread a -> `Spread (ex a)
      | `Record_lit fields -> `Record_lit (List.map (fun (l, v) -> l, ex v) fields)
      | `Field (a, label) -> `Field (ex a, label)
      | `Field_assign (a, label, v) ->
        let a, v = two a v in
        `Field_assign (a, label, v)
      | `New_call (name, types, args) -> `New_call (name, types, many args)
      | `New (name, fields) ->
        let fields = List.map (fun (l, v) -> l, ex v) fields in
        (h.generic_new scope { e with Ast.it = `New (name, fields) }).Ast.it
      | `New_variant (ty, variant, payload) -> `New_variant (ty, variant, Ast.map_payload ex payload)
      | `New_generic (name, static_args, fields) ->
        let static_args = List.map (Ast.map_static_arg ex) static_args in
        let fields = List.map (fun (l, v) -> l, ex v) fields in
        (h.generic_new scope { e with Ast.it = `New_generic (name, static_args, fields) }).Ast.it
      | `Collection_lit items -> `Collection_lit (many items)
      | `Typeof a -> `Typeof (ex a)
      | `Var _ | `Static_call _ | `Method_call _ | `Code _ | `Lambda _ | `Run_expr _ -> it
    in
    { e with Ast.it }

and tvalued h scope (b : (Ast.expr, Ast.stmt) Ast.valued_block) =
  let stmts, scope = tseq h scope b.Ast.vb_stmts in
  { Ast.vb_stmts = stmts; vb_value = Option.map (texpr h scope) b.Ast.vb_value }

and tclause h scope (c : Ast.stmt Ast.handler_clause) =
  match c with
  | Ast.Inline handler -> Ast.Inline (thandler h scope handler)
  | Ast.Named name -> Ast.Named name

and thandler h scope (handler : Ast.stmt Ast.handler) =
  { handler with
    Ast.arms =
      List.map
        (fun (a : Ast.stmt Ast.arm) ->
          { a with
            Ast.arm_body =
              tblock h (List.fold_left (Fun.flip S.add) scope a.Ast.arm_params) a.Ast.arm_body
          })
        handler.Ast.arms
  }

(* A local function is visible to the whole block it stands in. *)
and tseq h scope (stmts : Ast.stmt list) : Ast.stmt list * S.t =
  let scope =
    List.fold_left
      (fun acc (s : Ast.stmt) ->
        match s.Ast.it with
        | `Fn (name, _, _, _) -> S.add name acc
        | _ -> acc)
      scope
      stmts
  in
  let rec go scope acc = function
    | [] -> List.rev acc, scope
    | s :: rest ->
      let out, scope = tstmt h scope s in
      go scope (List.rev_append out acc) rest
  in
  go scope [] stmts

and tblock h scope stmts = fst (tseq h scope stmts)

and tsingle h scope (s : Ast.stmt) : Ast.stmt =
  match tstmt h scope s with
  | [ one ], _ -> one
  | many, _ -> { s with Ast.it = `Block many }

and tstmt h scope (s : Ast.stmt) : Ast.stmt list * S.t =
  let one it = [ { s with Ast.it } ], scope in
  let ex = texpr h scope
  and st = tsingle h scope in
  match s.Ast.it with
  | `Meta _ | `Derive _ ->
    let out = h.meta scope s in
    out, List.fold_left declared_here scope out
  | `Gen _ -> h.gen scope s, scope
  | `Var_decl (name, ty, init) ->
    let init = Option.map ex init in
    h.local name ty init;
    [ { s with Ast.it = `Var_decl (name, ty, init) } ], S.add name scope
  | `Var_tuple (names, init) ->
    ( [ { s with Ast.it = `Var_tuple (names, ex init) } ]
    , List.fold_left (Fun.flip S.add) scope names )
  | `Fn (name, params, sg, body) ->
    [ { s with
        Ast.it = `Fn (name, params, sg, tblock h (with_params (S.add name scope) params) body)
      } ]
    , S.add name scope
  | `Block body -> one (`Block (tblock h scope body))
  | `If (c, t, e) ->
    let c = ex c in
    let t = st t in
    one (`If (c, t, Option.map st e))
  | `While (c, body) ->
    let c = ex c in
    one (`While (c, st body))
  | `Return e -> one (`Return (Option.map ex e))
  | `Expr e -> one (`Expr (ex e))
  | `Defer inner -> one (`Defer (st inner))
  | `For (init, cond, step, body) ->
    let init, inner =
      match init with
      | None -> None, scope
      | Some i ->
        let out, inner = tstmt h scope i in
        (match out with
         | [ one ] -> Some one, inner
         | many -> Some { i with Ast.it = `Block many }, inner)
    in
    let cond = Option.map (texpr h inner) cond in
    let body = tsingle h inner body in
    one (`For (init, cond, Option.map (texpr h inner) step, body))
  | `For_in (names, over, body) ->
    let over = ex over in
    one (`For_in (names, over, tsingle h (List.fold_left (Fun.flip S.add) scope names) body))
  | `Match (subject, cases) ->
    let subject = ex subject in
    one
      (`Match
         ( subject
         , List.map
             (fun (p, body) ->
               p, tblock h (List.fold_left (Fun.flip S.add) scope (pattern_names p)) body)
             cases ))
  | `Run (body, handlers) ->
    let body = tblock h scope body in
    one (`Run (body, List.map (tclause h scope) handlers))
  | `Resume e -> one (`Resume (Option.map ex e))
  | `Handler_decl (name, handler) -> one (`Handler_decl (name, thandler h scope handler))
  | `Impl_decl (trait, ty, params, impl) ->
    one
      (`Impl_decl
         ( trait
         , ty
         , params
         , { impl with
             Ast.ib_methods =
               List.map
                 (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                   { m with Ast.md_body = tblock h (with_params scope m.Ast.md_params) m.Ast.md_body })
                 impl.Ast.ib_methods
           } ))
  | `Attributed (attrs, inner) ->
    (match tstmt h scope inner with
     | [ one ], scope -> [ { s with Ast.it = `Attributed (attrs, one) } ], scope
     | many, scope -> many, scope)
  | `Effect_decl _ | `Type_decl _ | `Trait_decl _ | `Import _ | `Type_members _ -> [ s ], scope

(* ---- what a declaration needs ---- *)

(* A method is read by name alone, so it is kept apart from a variable's. *)
let method_read name = "." ^ name

let read_method n = if String.length n > 1 && n.[0] = '.' then Some (String.sub n 1 (String.length n - 1)) else None

let survey (body : Ast.stmt list) ~scope =
  let reads = ref S.empty
  and meta = ref false in
  let h =
    { quiet with
      var =
        (fun _ e ->
          (match e.Ast.it with
           | `Var name -> reads := S.add name !reads
           | _ -> ());
          e)
    ; static_call =
        (fun _ e ->
          (match e.Ast.it with
           | `Static_call ({ Ast.it = `Var name; _ }, _, _) -> reads := S.add name !reads
           | _ -> ());
          e)
    ; method_call =
        (fun _ e ->
          (match e.Ast.it with
           | `Method_call (_, name, as_function, _) ->
             reads := S.add as_function (S.add (method_read name) !reads)
           | _ -> ());
          e)
    ; meta =
        (fun _ s ->
          meta := true;
          [ s ])
    ; gen =
        (fun _ s ->
          meta := true;
          [ s ])
    }
  in
  ignore (tblock h scope body);
  !reads, !meta

let rec contains_code (body : Ast.stmt list) =
  let found = ref false in
  let rec expr (e : Ast.expr) =
    match e.Ast.it with
    | `Code _ -> found := true
    | `Lambda (_, _, b) -> if contains_code b then found := true
    | `Var _ | #Ast.lit -> ()
    | `Static_call (callee, static_args, args) ->
      expr callee;
      List.iter
        (function
          | Ast.St_value v -> expr v
          | Ast.St_type _ -> ())
        static_args;
      List.iter expr args
    | `Method_call (r, _, _, args) -> List.iter expr (r :: args)
    | `Call (c, args) -> List.iter expr (c :: args)
    | `Unop (_, a) -> expr a
    | `Binop (_, a, b) | `And (a, b) | `Or (a, b) | `Index (a, b) -> expr a; expr b
    | `Assign (_, v) | `Compound (_, _, v) | `Tuple_get (v, _) | `Field (v, _) | `Spread v
    | `Typeof v -> expr v
    | `Index_assign (a, b, c) | `Compound_index (_, a, b, c) -> expr a; expr b; expr c
    | `Compound_field (_, a, _, b) -> expr a; expr b
    | `Field_assign (a, _, b) -> expr a; expr b
    | `Tuple items | `Collection_lit items -> List.iter expr items
    | `Record_lit fields | `New (_, fields) -> List.iter (fun (_, v) -> expr v) fields
    | `New_call (_, _, args) -> List.iter expr args
    | `New_generic (_, static_args, fields) ->
      List.iter
        (function
          | Ast.St_value v -> expr v
          | Ast.St_type _ -> ())
        static_args;
      List.iter (fun (_, v) -> expr v) fields
    | `New_variant (_, _, payload) -> List.iter (fun (_, v) -> expr v) (Ast.payload_fields payload)
    | `Run_expr (b, _, _) ->
      if contains_code b.Ast.vb_stmts then found := true;
      Option.iter expr b.Ast.vb_value
  and stmt (s : Ast.stmt) =
    match s.Ast.it with
    | `Expr e | `Var_tuple (_, e) -> expr e
    | `Var_decl (_, _, init) | `Return init -> Option.iter expr init
    | `Block b | `Fn (_, _, _, b) | `Meta b -> List.iter stmt b
    | `If (c, t, e) -> expr c; stmt t; Option.iter stmt e
    | `While (c, b) -> expr c; stmt b
    | `Defer b | `Gen b | `Attributed (_, b) -> stmt b
    | `For (i, c, st, b) -> Option.iter stmt i; Option.iter expr c; Option.iter expr st; stmt b
    | `For_in (_, over, b) -> expr over; stmt b
    | `Match (subject, cases) -> expr subject; List.iter (fun (_, b) -> List.iter stmt b) cases
    | `Run (b, _) -> List.iter stmt b
    | `Resume e -> Option.iter expr e
    | `Impl_decl (_, _, _, impl) ->
      List.iter (fun (m : (Ast.stmt, unit) Ast.method_def) -> List.iter stmt m.Ast.md_body) impl.Ast.ib_methods
    | _ -> ()
  in
  List.iter stmt body;
  !found

(* ---- the world ---- *)

type state =
  | Unwalked
  | Walking
  | Walked

type entry =
  { name : string
  ; written : Ast.stmt (* a `Fn`, perhaps under an attribute *)
  ; mutable state : state
  ; mutable walked : Ast.stmt
  ; mutable deps : S.t
  ; mutable plain : bool option
  ; (* A `gen` outside any meta block: this runs only as part of one. *)
    mutable gens : bool
  }

(* An impl or a handler. One with nothing to metaprocess is always part of the
   program. Otherwise an impl's methods are walked when reached — a trait impl
   all at once, since a table of its methods is what a caller gets — and a
   handler where it stands. *)
type standing =
  { stmt : Ast.stmt
  ; is_plain : bool
  ; target : string option
  ; trait : string option
  ; plain_methods : S.t
  ; walked : (string, (Ast.stmt, unit) Ast.method_def) Hashtbl.t
  ; walking : (string, unit) Hashtbl.t
  ; mutable handler : Ast.stmt option
  ; mutable reads : S.t
  }

type world =
  { context : context
  ; entries : (string, entry) Hashtbl.t
  ; traits : (string, unit) Hashtbl.t
  ; copies : (string * string, string) Hashtbl.t
  ; mutable instances : string list
  ; known : (string, unit) Hashtbl.t
  ; unknown : (string, Ast.span) Hashtbl.t
  ; known_methods : (string, unit) Hashtbl.t
  ; unknown_methods : (string, Ast.span) Hashtbl.t
  ; mutable standing : standing list
  ; mutable types : Ast.stmt list
  ; mutable generated : [ `Entry of string | `Stmt of Ast.stmt ] list
  ; mutable generator : string
  ; roots : S.t ref
  ; (* Run-time variables, which a meta program never sees. *)
    vars : (string, unit) Hashtbl.t
  ; (* A module's top-level meta blocks, by the prefix its names carry, until
       the walk first asks it for one. *)
    units : (string, Ast.stmt list) Hashtbl.t
  ; type_names : (string, unit) Hashtbl.t
  ; (* Methods whose body runs a meta block: a function calling one by that
       name has to be walked to find out which. *)
    meta_methods : (string, unit) Hashtbl.t
  ; (* A type taking a value, or whose body runs a meta block: made once per
       argument list when first built, like a function template. *)
    type_templates : (string, type_template) Hashtbl.t
  ; type_copies : (string, unit) Hashtbl.t
  }

and type_template =
  { tt_name : string
  ; tt_params : Ast.type_param list
  ; tt_decl : Ast.stmt
  ; tt_members : Ast.stmt list
  }

let type_head (t : Ast.type_expr) =
  match t.Ast.it with
  | Ast.Ty_name n | Ast.Ty_app (n, _) -> Some n
  | _ -> None

let rec impl_parts (s : Ast.stmt) =
  match s.Ast.it with
  | `Impl_decl (trait, ty, params, body) -> Some (trait, ty, params, body)
  | `Attributed (_, inner) -> impl_parts inner
  | _ -> None

let rec with_methods (s : Ast.stmt) methods =
  match s.Ast.it with
  | `Impl_decl (trait, ty, params, body) ->
    { s with Ast.it = `Impl_decl (trait, ty, params, { body with Ast.ib_methods = methods }) }
  | `Attributed (attrs, inner) -> { s with Ast.it = `Attributed (attrs, with_methods inner methods) }
  | _ -> s

let ready (st : standing) : Ast.stmt option =
  if st.is_plain
  then Some st.stmt
  else (
    match impl_parts st.stmt with
    | Some (_, _, _, body) ->
      let methods =
        List.filter_map
          (fun (m : (Ast.stmt, unit) Ast.method_def) ->
            match Hashtbl.find_opt st.walked m.Ast.md_name with
            | Some walked -> Some walked
            | None -> if S.mem m.Ast.md_name st.plain_methods then Some m else None)
          body.Ast.ib_methods
      in
      if Hashtbl.length st.walking > 0
      then None
      else if Option.is_some st.trait
      then if Hashtbl.length st.walked > 0 then Some (with_methods st.stmt methods) else None
      else if methods = []
      then None
      else Some (with_methods st.stmt methods)
    | None -> st.handler)

let rec fn_parts (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn (name, params, sg, body) -> Some (name, params, sg, body)
  | `Attributed (_, inner) -> fn_parts inner
  | _ -> None

let parts (e : entry) =
  match fn_parts e.written with
  | Some parts -> parts
  | None -> invalid_arg "Metaprocess.parts"

let rec with_body (s : Ast.stmt) body =
  match s.Ast.it with
  | `Fn (name, params, sg, _) -> { s with Ast.it = `Fn (name, params, sg, body) }
  | `Attributed (attrs, inner) -> { s with Ast.it = `Attributed (attrs, with_body inner body) }
  | _ -> s

let is_template (e : entry) =
  let _, _, sg, _ = parts e in
  sg.Ast.static_params <> []

let takes_value_params (sg : Ast.signature) =
  List.exists (fun (p : Ast.static_param) -> Option.is_some p.Ast.sp_ty) sg.Ast.static_params

let is_value w (p : Ast.static_param) =
  match p.Ast.sp_ty with
  | None -> false
  | Some { Ast.it = Ast.Ty_name name; _ } | Some { Ast.it = Ast.Ty_app (name, _); _ } ->
    not (Hashtbl.mem w.traits name)
  | Some _ -> true

let param_names params = List.map (fun (p : Ast.param) -> p.Ast.name) params

let entry_scope (e : entry) =
  let _, params, sg, _ = parts e in
  with_params
    (List.fold_left (fun acc (p : Ast.static_param) -> S.add p.Ast.sp_name acc) S.empty sg.Ast.static_params)
    params

(* A value decides a copy's body, so the walk makes every copy of a template
   taking one; a template taking only types is checked once, generically,
   unless a meta block in it reads one. *)
let rec instantiated w (e : entry) =
  is_template e
  && (List.exists (is_value w) (let _, _, sg, _ = parts e in sg.Ast.static_params) || not (plain w e))

and plain w (e : entry) =
  match e.plain with
  | Some p -> p
  | None ->
    (* Assumed while it is being decided, so a cycle answers for itself. *)
    e.plain <- Some true;
    let _, _, _, body = parts e in
    let reads, meta = survey body ~scope:(entry_scope e) in
    let p =
      (not meta)
      && (not (contains_code body))
      && S.for_all
           (fun n ->
             match read_method n with
             | Some m -> not (Hashtbl.mem w.meta_methods m)
             | None ->
               (match Hashtbl.find_opt w.entries n with
                | Some d -> plain w d && not (instantiated w d)
                | None -> true))
           reads
    in
    e.plain <- Some p;
    p

let note_unknown w name span =
  if not (Hashtbl.mem w.known name || Hashtbl.mem w.unknown name)
  then Hashtbl.replace w.unknown name span

let reads_of (e : Ast.expr) =
  let found = ref S.empty in
  ignore
    (texpr
       { quiet with
         var =
           (fun _ e ->
             (match e.Ast.it with
              | `Var name -> found := S.add name !found
              | _ -> ());
             e)
       }
       S.empty
       e);
  !found

(* Total, so it also decides whether an argument may be one at all. *)
let rec key_of (e : Ast.expr) : string option =
  match e.Ast.it with
  | `Int n -> Some (string_of_int n)
  | `Float n -> Some (Printf.sprintf "%h" n)
  | `Str s -> Some (Printf.sprintf "%S" (Utf8.encode s))
  | `Char c -> Some (Printf.sprintf "'%d'" (Uchar.to_int c))
  | `Bool b -> Some (string_of_bool b)
  | `Unop (Ast.Neg, inner) -> Option.map (fun key -> "-" ^ key) (key_of inner)
  | _ -> None

(* A static argument is an expression the compiler can evaluate: literals, and
   the static parameters already written in where it stands, under the
   operators. A call is evaluated only inside a meta block. *)
let rec fold (e : Ast.expr) : Ast.expr =
  let at it = { e with Ast.it } in
  let lit (e : Ast.expr) = match e.Ast.it with #Ast.lit -> true | _ -> false in
  match e.Ast.it with
  | `Unop (op, a) ->
    (match op, (fold a).Ast.it with
     | Ast.Neg, `Int n -> at (`Int (-n))
     | Ast.Neg, `Float n -> at (`Float (-.n))
     | Ast.Not, `Bool b -> at (`Bool (not b))
     | _ -> e)
  | `And (a, b) | `Or (a, b) ->
    (match (fold a).Ast.it, (fold b).Ast.it, e.Ast.it with
     | `Bool x, `Bool y, `And _ -> at (`Bool (x && y))
     | `Bool x, `Bool y, _ -> at (`Bool (x || y))
     | _ -> e)
  | `Binop (op, a, b) ->
    let a = fold a
    and b = fold b in
    if not (lit a && lit b)
    then e
    else (
      let judged c =
        match op with
        | Ast.Equal -> Some (c = 0)
        | Ast.Not_equal -> Some (c <> 0)
        | Ast.Less -> Some (c < 0)
        | Ast.Less_equal -> Some (c <= 0)
        | Ast.Greater -> Some (c > 0)
        | Ast.Greater_equal -> Some (c >= 0)
        | _ -> None
      in
      match op, a.Ast.it, b.Ast.it with
      | Ast.Add, `Int x, `Int y -> at (`Int (x + y))
      | Ast.Sub, `Int x, `Int y -> at (`Int (x - y))
      | Ast.Mul, `Int x, `Int y -> at (`Int (x * y))
      | Ast.Div, `Int x, `Int y when y <> 0 -> at (`Int (x / y))
      | Ast.Mod, `Int x, `Int y when y <> 0 -> at (`Int (x mod y))
      | Ast.Add, `Float x, `Float y -> at (`Float (x +. y))
      | Ast.Sub, `Float x, `Float y -> at (`Float (x -. y))
      | Ast.Mul, `Float x, `Float y -> at (`Float (x *. y))
      | Ast.Div, `Float x, `Float y -> at (`Float (x /. y))
      | Ast.Add, `Str x, `Str y -> at (`Str (Array.append x y))
      | _, `Int x, `Int y -> Option.fold ~none:e ~some:(fun r -> at (`Bool r)) (judged (Int.compare x y))
      | _, `Float x, `Float y ->
        Option.fold ~none:e ~some:(fun r -> at (`Bool r)) (judged (Float.compare x y))
      | _, `Str x, `Str y -> Option.fold ~none:e ~some:(fun r -> at (`Bool r)) (judged (Utf8.compare x y))
      | _ -> e)
  | _ -> e

let static_value name (arg : Ast.expr Ast.static_arg) : Ast.expr * string =
  let written =
    match arg with
    | Ast.St_type { Ast.it = Ast.Ty_name n; span; _ } -> Ast.at span (`Var n)
    | Ast.St_type t -> fail t.Ast.span "'%s' takes a value here, not a type." name
    | Ast.St_value v -> fold v
  in
  match key_of written with
  | Some key -> written, key
  | None ->
    (match written.Ast.it with
     | `Var unknown ->
       fail
         written.Ast.span
         "'%s' is not known at compile time: it is a run-time variable, not a static \
          parameter of the enclosing function."
         unknown
     | `Call _ | `Static_call _ ->
       fail
         written.Ast.span
         "This argument to '%s' is not known at compile time: a call is evaluated at \
          compile time only inside a meta block."
         name
     | `Bytes _ ->
       fail
         written.Ast.span
         "Embedded bytes cannot be a static argument to '%s': a static value is a number, \
          string, char or bool."
         name
     | _ ->
       fail
         written.Ast.span
         "This argument to '%s' is not known at compile time; only a literal or a static \
          parameter of the enclosing function is."
         name)

let rec type_key (t : Ast.type_expr) =
  match t.Ast.it with
  | Ast.Ty_name n -> n
  | Ast.Ty_app (n, args) -> n ^ "<" ^ String.concat "," (List.map type_key args) ^ ">"
  | Ast.Ty_tuple items -> "(" ^ String.concat "," (List.map type_key items) ^ ")"
  | _ -> "_"

(* A value parameter is written where it was used, but not inside a meta block:
   there it is bound, so a block nested in that one does not receive it. *)
let substitute_values (values : (string * Ast.expr) list) (body : Ast.stmt list) =
  let h =
    { quiet with
      var =
        (fun _ e ->
          match e.Ast.it with
          | `Var name ->
            (match List.assoc_opt name values with
             | Some v -> { v with Ast.span = e.Ast.span }
             | None -> e)
          | _ -> e)
    ; static_call =
        (fun scope e ->
          match e.Ast.it with
          | `Static_call (callee, static_args, args) ->
            let arg (a : Ast.expr Ast.static_arg) =
              match a with
              | Ast.St_type { Ast.it = Ast.Ty_name n; span; _ }
                when List.mem_assoc n values && not (S.mem n scope) ->
                Ast.St_value { (List.assoc n values) with Ast.span = span }
              | a -> a
            in
            { e with Ast.it = `Static_call (callee, List.map arg static_args, args) }
          | _ -> e)
    }
  in
  tblock h S.empty body

let undefined message =
  let prefix = "Undefined variable '" in
  let n = String.length prefix in
  if String.length message > n + 2 && String.equal (String.sub message 0 n) prefix
  then Some (String.sub message n (String.length message - n - 2))
  else None

(* A name a meta block cannot see is a construct that does not cross into it;
   the checker only knows it as undefined. *)
let explain (e : error) ~runtime ~outer =
  match undefined e.message with
  | Some name when List.mem name outer ->
    { e with
      message =
        Printf.sprintf
          "'%s' is a value of the enclosing meta block and does not cross into a nested one."
          name
    }
  | Some name when S.mem name runtime ->
    { e with
      message =
        Printf.sprintf "'%s' is a run-time value and does not cross into a meta block." name
    }
  | _ -> e

let performs_gen w name =
  let seen = Hashtbl.create 8 in
  let rec go n =
    if Hashtbl.mem seen n
    then false
    else (
      Hashtbl.add seen n ();
      match Hashtbl.find_opt w.entries n with
      | Some e -> e.gens || S.exists go e.deps
      | None -> false)
  in
  go name

let visible w n =
  (Hashtbl.mem w.entries n || Hashtbl.mem w.known n) && not (Hashtbl.mem w.vars n)

(* ---- walking ---- *)

let rec declared_of (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) | `Type_decl (name, _, _) | `Trait_decl (name, _, _)
  | `Handler_decl (name, _) | `Effect_decl (name, _, _) -> [ name ]
  | `Attributed (_, inner) -> declared_of inner
  | _ -> []

(* Set once [register] exists; the walk and registration call each other. *)
let register_hook : (world -> Ast.stmt -> unit) ref = ref (fun _ _ -> ())

let starts_with ~prefix name =
  let n = String.length prefix in
  String.length name > n && String.equal (String.sub name 0 n) prefix

let deferred_prefix (s : Ast.stmt) =
  match s.Ast.it with
  | `Attributed ([ { Ast.a_name; a_args = [ Ast.A_str prefix ]; _ } ], _)
    when String.equal a_name Ast.deferred_marker -> Some prefix
  | _ -> None

let rec reach w ~deps name =
  wake w name;
  match Hashtbl.find_opt w.entries name with
  | None -> false
  | Some e ->
    if not (instantiated w e)
    then (
      deps := S.add name !deps;
      walk_entry w e);
    true

and walk_entry ?(statics = []) w (e : entry) =
  match e.state with
  | Walked | Walking -> ()
  | Unwalked ->
    e.state <- Walking;
    let _, params, _, body = parts e in
    let deps = ref S.empty in
    let env = typed_params params in
    let body =
      tblock (runtime_hooks w ~deps ~current:(Some e) ~statics ~env) (entry_scope e) body
    in
    e.walked <- with_body e.written body;
    e.deps <- !deps;
    e.state <- Walked

and typed_params ?self params =
  let env = Hashtbl.create 8 in
  List.iter
    (fun (p : Ast.param) ->
      match Option.bind p.Ast.ty type_head with
      | Some t -> Hashtbl.replace env p.Ast.name t
      | None -> ())
    params;
  Option.iter (fun t -> Hashtbl.replace env "self" t) self;
  env

(* What the walk can tell about a value's type without the checker: what built
   it, what it was annotated with, or what a function says it returns. *)
and type_of w env (e : Ast.expr) =
  match e.Ast.it with
  | `Var n ->
    (match Hashtbl.find_opt env n with
     | Some t -> Some t
     | None -> if Hashtbl.mem w.type_names n then Some n else None)
  | `New (n, _) | `New_call (n, _, _) | `New_variant (n, _, _) | `New_generic (n, _, _) -> Some n
  | `Int _ -> Some "int"
  | `Float _ -> Some "float"
  | `Str _ -> Some "string"
  | `Bool _ -> Some "bool"
  | `Char _ -> Some "char"
  | `Call ({ Ast.it = `Var f; _ }, _) ->
    (match Hashtbl.find_opt w.entries f with
     | Some e ->
       let _, _, sg, _ = parts e in
       Option.bind sg.Ast.ret type_head
     | None -> None)
  | _ -> None

and walk_method w (st : standing) (m : (Ast.stmt, unit) Ast.method_def) =
  if not (Hashtbl.mem st.walked m.Ast.md_name || Hashtbl.mem st.walking m.Ast.md_name)
  then (
    Hashtbl.replace st.walking m.Ast.md_name ();
    let deps = ref S.empty in
    let env = typed_params ?self:st.target m.Ast.md_params in
    let body =
      tblock
        (runtime_hooks w ~deps ~current:None ~statics:[] ~env)
        (with_params S.empty m.Ast.md_params)
        m.Ast.md_body
    in
    Hashtbl.remove st.walking m.Ast.md_name;
    Hashtbl.replace st.walked m.Ast.md_name { m with Ast.md_body = body };
    st.reads <- S.union !deps st.reads)

and methods_of (st : standing) =
  match impl_parts st.stmt with
  | Some (_, _, _, body) -> body.Ast.ib_methods
  | None -> []

(* A trait impl is reached whole; an inherent one a method at a time. *)
and reach_method w ~deps ty name =
  List.iter
    (fun st ->
      if (not st.is_plain) && st.target = Some ty
      then (
        let methods = methods_of st in
        if List.exists (fun (m : (Ast.stmt, unit) Ast.method_def) -> String.equal m.Ast.md_name name) methods
        then (
          if Option.is_some st.trait
          then List.iter (walk_method w st) methods
          else
            List.iter
              (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                if String.equal m.Ast.md_name name then walk_method w st m)
              methods;
          deps := S.union st.reads !deps)))
    w.standing

(* A value becoming a trait object needs its impl whole, whether or not a
   method is ever called through it. *)
and reach_impl w ~deps trait ty =
  List.iter
    (fun st ->
      if (not st.is_plain) && st.target = Some ty && st.trait = Some trait
      then (
        List.iter (walk_method w st) (methods_of st);
        deps := S.union st.reads !deps))
    w.standing

and runtime_hooks w ~deps ~current ~statics ~env =
  let converted ty value =
    match Option.bind ty type_head with
    | Some trait when Hashtbl.mem w.traits trait ->
      Option.iter (fun t -> reach_impl w ~deps trait t) (Option.bind value (type_of w env))
    | _ -> ()
  in
  let rec h =
    { generic_new = (fun _ e -> generic_new w e)
    ; code = (fun _ e -> e)
    ; local =
        (fun name ty init ->
          converted ty init;
          match
            match Option.bind ty type_head with
            | Some t -> Some t
            | None -> Option.bind init (type_of w env)
          with
          | Some t -> Hashtbl.replace env name t
          | None -> Hashtbl.remove env name)
    ; call =
        (fun _ e ->
          let e = implicit_call w ~deps env e in
          (match e.Ast.it with
           | `Call ({ Ast.it = `Var f; _ }, args) ->
             (match Hashtbl.find_opt w.entries f with
              | Some entry ->
                let _, params, _, _ = parts entry in
                if List.length params = List.length args
                then
                  List.iter2
                    (fun (p : Ast.param) arg -> converted p.Ast.ty (Some arg))
                    params
                    args
              | None -> ())
           | _ -> ());
          e)
    ; var =
        (fun _ e ->
          (match e.Ast.it with
           | `Var name -> if not (reach w ~deps name) then note_unknown w name e.Ast.span
           | _ -> ());
          e)
    ; static_call = (fun _ e -> static_call w ~deps ~meta_scope:None e)
    ; method_call =
        (fun _ e ->
          (match e.Ast.it with
           | `Method_call (receiver, name, as_function, _) ->
             if (not (reach w ~deps as_function)) && not (Hashtbl.mem w.known_methods name)
             then (
               if not (Hashtbl.mem w.unknown_methods name)
               then Hashtbl.replace w.unknown_methods name e.Ast.span);
             (match type_of w env receiver with
              | Some ty when Hashtbl.mem w.traits ty -> ()
              | Some ty -> reach_method w ~deps ty name
              (* Walking a candidate that runs no meta block changes nothing
                 anyone can see, so each is walked; one that does is the
                 reason the type has to be known. *)
              | None ->
                List.iter
                  (fun st ->
                    if not st.is_plain
                    then
                      List.iter
                        (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                          if String.equal m.Ast.md_name name && not (S.mem name st.plain_methods)
                          then
                            if snd (survey m.Ast.md_body ~scope:(with_params S.empty m.Ast.md_params))
                            then
                              fail
                                e.Ast.span
                                "Cannot tell which '%s' this calls, and one of them runs a meta \
                                 block; annotate the receiver's type."
                                name
                            else Option.iter (fun ty -> reach_method w ~deps ty name) st.target)
                        (methods_of st))
                  w.standing)
           | _ -> ());
          e)
    ; meta =
        (fun scope s ->
          let generated = meta_stmt w ~statics ~runtime:scope ~outer:[] s in
          if Option.is_some current
          then
            List.iter
              (fun (g : Ast.stmt) ->
                match g.Ast.it with
                | `Impl_decl _ -> fail s.Ast.span "An impl cannot be generated inside a function body."
                | _ -> ())
              generated;
          tblock h scope generated)
    ; gen =
        (fun _ s ->
          match current with
          | Some e ->
            e.gens <- true;
            [ s ]
          | None -> fail s.Ast.span "'gen' is only allowed inside a meta block.")
    }
  in
  h

and static_call w ~deps ~meta_scope (e : Ast.expr) =
  match e.Ast.it with
  | `Static_call (({ Ast.it = `Var name; _ } as callee), static_args, args) ->
    wake w name;
    (match Hashtbl.find_opt w.entries name with
     | Some t when is_template t ->
       if not (instantiated w t)
       then (
         deps := S.add name !deps;
         walk_entry w t;
         e)
       else (
         Option.iter
           (fun scope ->
             List.iter
               (fun (a : Ast.expr Ast.static_arg) ->
                 let reads =
                   match a with
                   | Ast.St_value v -> reads_of v
                   | Ast.St_type { Ast.it = Ast.Ty_name n; _ } -> S.singleton n
                   | Ast.St_type _ -> S.empty
                 in
                 match S.find_first_opt (fun n -> S.mem n scope) reads with
                 | Some value ->
                   fail
                     e.Ast.span
                     "'%s' cannot be instantiated from inside a meta block: '%s' is a value \
                      there. Write the call inside a gen."
                     name
                     value
                 | None -> ())
               static_args)
           meta_scope;
         let copy = instantiate w t static_args e.Ast.span in
         deps := S.add copy !deps;
         { e with Ast.it = `Call ({ callee with Ast.it = `Var copy }, args) })
     | _ -> e)
  | _ -> e

(* A template called without `<…>` has its type arguments read off what the
   walk can see of the arguments passed for them; a value argument, or a type
   it cannot see, has to be written. *)
and implicit_call w ~deps env (e : Ast.expr) =
  match e.Ast.it with
  | `Call (({ Ast.it = `Var f; _ } as callee), args) ->
    (match Hashtbl.find_opt w.entries f with
     | Some t when instantiated w t ->
       let _, params, sg, _ = parts t in
       let passed =
         if List.length params = List.length args then List.combine params args else []
       in
       let inferred =
         List.map
           (fun (sp : Ast.static_param) ->
             if is_value w sp
             then None
             else
               List.find_map
                 (fun ((p : Ast.param), arg) ->
                   match p.Ast.ty with
                   | Some { Ast.it = Ast.Ty_name n; _ } when String.equal n sp.Ast.sp_name ->
                     type_of w env arg
                   | _ -> None)
                 passed)
           sg.Ast.static_params
       in
       if List.for_all Option.is_some inferred
       then (
         let static_args =
           List.map
             (fun t -> Ast.St_type { Ast.it = Ast.Ty_name (Option.get t); span = e.Ast.span; ann = () })
             inferred
         in
         let copy = instantiate w t static_args e.Ast.span in
         deps := S.add copy !deps;
         { e with Ast.it = `Call ({ callee with Ast.it = `Var copy }, args) })
       else
         fail
           e.Ast.span
           "'%s' needs its static arguments written: the walk cannot see them from what is \
            passed here."
           f
     | _ -> e)
  | _ -> e

and instantiate w (t : entry) static_args span =
  let name, params, sg, body = parts t in
  let declared = sg.Ast.static_params in
  if List.length declared <> List.length static_args
  then
    fail
      span
      "'%s' takes %d static argument(s) but %d were given."
      name
      (List.length declared)
      (List.length static_args);
  let values, types, keys =
    List.fold_left2
      (fun (values, types, keys) (p : Ast.static_param) arg ->
        if is_value w p
        then (
          let v, key = static_value name arg in
          (p.Ast.sp_name, v) :: values, types, key :: keys)
        else (
          match arg with
          | Ast.St_type ({ Ast.it = Ast.Ty_name n; _ } as t) -> values, (p.Ast.sp_name, n) :: types, type_key t :: keys
          | Ast.St_type t -> fail t.Ast.span "'%s' needs a named type here." name
          | Ast.St_value { Ast.it = `Var n; _ } -> values, (p.Ast.sp_name, n) :: types, n :: keys
          | Ast.St_value v -> fail v.Ast.span "'%s' takes a type here, not a value." name))
      ([], [], [])
      declared
      static_args
  in
  let key = String.concat "," (List.rev keys) in
  match Hashtbl.find_opt w.copies (name, key) with
  | Some copy -> copy
  | None ->
    let copy = Ast.generated [ name; string_of_int (Hashtbl.length w.copies) ] in
    Hashtbl.replace w.copies (name, key) copy;
    (* A type argument is written everywhere, a meta block included: a type is
       not a value there, so it does not cross, it is simply named. *)
    let named = Hashtbl.create 4 in
    List.iter (fun (param, ty) -> Hashtbl.replace named param (Value.Name ty)) types;
    let renamed =
      substitute named { t.written with Ast.it = `Fn (name, params, { sg with Ast.static_params = [] }, body) }
    in
    let written =
      match renamed.Ast.it with
      | `Fn (_, params, sg, body) ->
        { renamed with Ast.it = `Fn (copy, params, sg, substitute_values values body) }
      | _ -> renamed
    in
    let e =
      { name = copy
      ; written
      ; state = Unwalked
      ; walked = written
      ; deps = S.empty
      ; plain = Some false
      ; gens = false
      }
    in
    Hashtbl.replace w.entries copy e;
    w.instances <- copy :: w.instances;
    walk_entry ~statics:(List.rev values) w e;
    copy

and meta_stmt w ~statics ~runtime ~outer (s : Ast.stmt) : Ast.stmt list =
  match s.Ast.it with
  | `Meta body ->
    w.generator <- "meta block";
    run_meta w ~statics ~runtime ~outer body
  | `Derive (traits, target) -> derive w s traits target
  | _ -> [ s ]

and derive w (s : Ast.stmt) traits target =
  (* A trait from a module carries its unit's prefix, and so does its deriver. *)
  let deriver t =
    match String.rindex_opt t '#' with
    | Some at ->
      String.sub t 0 (at + 1) ^ Ast.deriver_name (String.sub t (at + 1) (String.length t - at - 1))
    | None -> Ast.deriver_name t
  in
  let has_deriver t =
    wake w (deriver t);
    Hashtbl.mem w.entries (deriver t)
  in
  (* `Eq` is the compiler's to derive unless a program wrote its own. *)
  let compiler t = String.equal t "Eq" && not (has_deriver t) in
  let derived = if List.exists compiler traits then [ derived_eq s.Ast.span target ] else [] in
  let calls =
    List.filter_map
      (fun trait ->
        if compiler trait
        then None
        else (
          let name = deriver trait in
          if not (has_deriver trait) then fail s.Ast.span "Trait '%s' has no deriver." trait;
          let at it = Ast.at s.Ast.span it in
          let shape = at (`Field (at (`Typeof (at (`Var target))), "shape")) in
          Some (at (`Expr (at (`Call (at (`Var name), [ shape ])))))))
      traits
  in
  let generated =
    match calls with
    | [] -> []
    | calls ->
      let produced = run_meta w ~statics:[] ~runtime:S.empty ~outer:[] calls in
      w.generator <- "derive";
      produced
  in
  derived @ generated

and run_meta w ~statics ~runtime ~outer body =
  let deps = ref S.empty in
  let scope = List.fold_left (fun acc (n, _) -> S.add n acc) S.empty statics in
  let rec h =
    { quiet with
      generic_new = (fun _ e -> generic_new w e)
    ; call = (fun _ e -> implicit_call w ~deps (Hashtbl.create 1) e)
    ; var =
        (fun _ e ->
          (match e.Ast.it with
           | `Var name -> ignore (reach w ~deps name)
           | _ -> ());
          e)
    ; static_call = (fun scope e -> static_call w ~deps ~meta_scope:(Some scope) e)
    ; method_call =
        (fun _ e ->
          (match e.Ast.it with
           | `Method_call (_, _, as_function, _) -> ignore (reach w ~deps as_function)
           | _ -> ());
          e)
    ; (* Nested, so it runs while this one is compiled, and what it generates
         is this block's code. *)
      meta =
        (fun scope s ->
          let generated =
            meta_stmt w ~statics:[] ~runtime:scope ~outer:(List.map fst statics @ outer) s
          in
          tblock h scope generated)
    ; gen = (fun _ s -> [ s ])
    }
  in
  let body = tblock h scope body in
  let refs = ref S.empty in
  let lowered = lower w.context ~visible:(visible w) ~refs ~params:(List.map fst statics) body in
  S.iter (fun n -> ignore (reach w ~deps n)) !refs;
  let bindings =
    List.map (fun (n, (v : Ast.expr)) -> Ast.at v.Ast.span (`Var_decl (n, None, Some v))) statics
  in
  let program = meta_program w !deps @ bindings @ lowered in
  let collected = ref [] in
  let previous = !(w.context.current) in
  w.context.current := collected;
  (try
     run
       ~out:w.context.out
       ~codes:w.context.codes
       ~emit:(emit_into w.context)
       ~capture:(fun _ -> ())
       program
   with
   | Failed e ->
     w.context.current := previous;
     raise (Failed (explain e ~runtime ~outer)));
  w.context.current := previous;
  List.rev !collected

and generic_new w (e : Ast.expr) =
  match e.Ast.it with
  | `New_generic (name, static_args, fields) ->
    wake w name;
    (match Hashtbl.find_opt w.type_templates name with
     | Some tt -> { e with Ast.it = `New (instantiate_type w tt static_args e.Ast.span, fields) }
     | None -> e)
  | `New (name, _) ->
    (match Hashtbl.find_opt w.type_templates name with
     | Some tt ->
       fail
         e.Ast.span
         "'%s' %s, so its arguments must be written: new %s<…> { … }."
         name
         (if List.exists (fun (p : Ast.type_param) -> Option.is_some p.Ast.tp_ty) tt.tt_params
          then "takes a value parameter"
          else "runs a meta block")
         name
     | None -> e)
  | _ -> e

(* A method's meta blocks run when the method is reached, long after the copy
   was made, so the copy's value arguments are bound at the top of each. *)
and with_values values body =
  match values with
  | [] -> body
  | values ->
    tblock
      { quiet with
        meta =
          (fun _ (s : Ast.stmt) ->
            match s.Ast.it with
            | `Meta inner ->
              let bound =
                List.map
                  (fun (n, (v : Ast.expr)) -> Ast.at v.Ast.span (`Var_decl (n, None, Some v)))
                  values
              in
              [ { s with Ast.it = `Meta (bound @ inner) } ]
            | _ -> [ s ])
      }
      S.empty
      body

(* A copy is named by what it was made from, `Buf<4>`, which is how a
   diagnostic or `typeof` shows it. Its meta blocks run as it is made, with its
   value arguments bound; its functions become its methods. *)
and instantiate_type w (tt : type_template) static_args span =
  let params = tt.tt_params in
  if List.length params <> List.length static_args
  then
    fail
      span
      "Type '%s' takes %d argument(s) but %d were given."
      tt.tt_name
      (List.length params)
      (List.length static_args);
  let values, types, shown =
    List.fold_left2
      (fun (values, types, shown) (p : Ast.type_param) arg ->
        if Option.is_some p.Ast.tp_ty
        then (
          let v, _ = static_value tt.tt_name arg in
          (p.Ast.tp_name, v) :: values, types, Source.expr v :: shown)
        else (
          match arg with
          | Ast.St_type t -> values, (p.Ast.tp_name, type_key t) :: types, type_key t :: shown
          | Ast.St_value { Ast.it = `Var n; _ } -> values, (p.Ast.tp_name, n) :: types, n :: shown
          | Ast.St_value v -> fail v.Ast.span "'%s' takes a type here, not a value." tt.tt_name))
      ([], [], [])
      params
      static_args
  in
  let copy = tt.tt_name ^ "<" ^ String.concat ", " (List.rev shown) ^ ">" in
  if not (Hashtbl.mem w.type_copies copy)
  then (
    Hashtbl.replace w.type_copies copy ();
    let values = List.rev values in
    let named = Hashtbl.create 4 in
    List.iter (fun (param, ty) -> Hashtbl.replace named param (Value.Name ty)) types;
    let decl = substitute named tt.tt_decl in
    let decl =
      match decl.Ast.it with
      | `Type_decl (_, _, body) -> { decl with Ast.it = `Type_decl (copy, [], body) }
      | _ -> decl
    in
    !register_hook w decl;
    let functions = ref [] in
    List.iter
      (fun (m : Ast.stmt) ->
        let m = substitute named m in
        match m.Ast.it with
        | `Meta _ ->
          List.iter
            (fun (g : Ast.stmt) ->
              match fn_parts g with
              | Some _ -> functions := g :: !functions
              | None -> fail g.Ast.span "A type's meta block can generate only its methods.")
            (meta_stmt w ~statics:values ~runtime:S.empty ~outer:[] m)
        | _ ->
          (match fn_parts m with
           | Some _ -> functions := m :: !functions
           | None -> fail m.Ast.span "A type holds functions and meta blocks after its fields."))
      tt.tt_members;
    match List.rev !functions with
    | [] -> ()
    | functions ->
      let methods =
        List.map
          (fun f ->
            let name, params, sg, body = Option.get (fn_parts f) in
            { Ast.md_name = name
            ; md_params = params
            ; md_signature = sg
            ; md_body = with_values values (substitute_values values body)
            ; md_ann = ()
            })
          functions
      in
      !register_hook
        w
        (Ast.at span (`Impl_decl (None, copy, [], { Ast.ib_assoc = []; ib_methods = methods }))));
  copy

(* A module's top-level meta blocks run once, the first time the walk asks the
   module for a name. What they generate is the module's, so it takes the
   module's prefix; a statement they generate is dropped, as the module's own
   statements are. *)
and wake w name =
  let ready =
    Hashtbl.fold
      (fun prefix blocks acc -> if starts_with ~prefix name then (prefix, blocks) :: acc else acc)
      w.units
      []
  in
  List.iter
    (fun (prefix, blocks) ->
      Hashtbl.remove w.units prefix;
      List.iter
        (fun (s : Ast.stmt) ->
          let inner =
            match s.Ast.it with
            | `Attributed (_, inner) -> inner
            | _ -> s
          in
          let generated = meta_stmt w ~statics:[] ~runtime:S.empty ~outer:[] inner in
          let declarations = List.filter is_visible_to_meta generated in
          let owned = Hashtbl.create 4 in
          List.iter
            (fun d ->
              List.iter
                (fun n -> if not (starts_with ~prefix n) then Hashtbl.replace owned n (Value.Name (prefix ^ n)))
                (declared_of d))
            declarations;
          List.iter (fun d -> !register_hook w (substitute owned d)) declarations)
        blocks)
    ready

(* What a meta program is compiled from: the types, the impls, and each function
   the block reaches — walked first, so nothing in it is still a meta block. *)
and meta_program w deps =
  let seen = Hashtbl.create 16 in
  let out = ref [] in
  let rec add name =
    if not (Hashtbl.mem seen name)
    then (
      Hashtbl.add seen name ();
      match Hashtbl.find_opt w.entries name with
      | None -> ()
      | Some e ->
        (match e.state with
         | Unwalked -> walk_entry w e
         | Walking | Walked -> ());
        (match e.state with
         | Walking ->
           fail
             e.written.Ast.span
             "'%s' is still being metaprocessed, so a meta block cannot call it yet."
             name
         | Unwalked | Walked -> ());
        S.iter add e.deps;
        let _, params, sg, body = parts { e with written = e.walked } in
        let refs = ref S.empty in
        let names =
          List.map (fun (p : Ast.static_param) -> p.Ast.sp_name) sg.Ast.static_params
          @ param_names params
        in
        let body = lower w.context ~visible:(visible w) ~refs ~params:names body in
        S.iter
          (fun n ->
            let local = ref S.empty in
            if reach w ~deps:local n then S.iter add !local)
          !refs;
        out := with_body e.walked body :: !out)
  in
  S.iter add deps;
  let standing =
    List.filter_map
      (fun st ->
        match ready st with
        | Some ready ->
          S.iter add st.reads;
          Some ready
        | None -> None)
      w.standing
  in
  List.rev w.types @ standing @ List.rev !out

(* ---- the program ---- *)

let rec declared_names (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) | `Type_decl (name, _, _) | `Handler_decl (name, _) -> [ name ]
  | `Trait_decl (name, _, _) -> [ name ]
  | `Effect_decl (name, _, ops) -> name :: List.map (fun (o : Ast.op_decl) -> o.Ast.op_name) ops
  | `Var_decl (name, _, _) -> [ name ]
  | `Var_tuple (names, _) -> names
  | `Attributed (_, inner) -> declared_names inner
  | _ -> []

(* A trait only promises a method; an impl is what makes one callable. *)
let rec method_names (s : Ast.stmt) =
  match s.Ast.it with
  | `Impl_decl (_, _, _, impl) ->
    List.map (fun (m : (Ast.stmt, unit) Ast.method_def) -> m.Ast.md_name) impl.Ast.ib_methods
  | `Attributed (_, inner) -> method_names inner
  | _ -> []

let rec is_type_level (s : Ast.stmt) =
  match s.Ast.it with
  | `Type_decl _ | `Trait_decl _ | `Effect_decl _ -> true
  | `Attributed (_, inner) -> is_type_level inner
  | _ -> false

let rec is_standing (s : Ast.stmt) =
  match s.Ast.it with
  | `Impl_decl _ | `Handler_decl _ -> true
  | `Attributed (_, inner) -> is_standing inner
  | _ -> false

let new_entry name written =
  { name
  ; written
  ; state = Unwalked
  ; walked = written
  ; deps = S.empty
  ; plain = None
  ; gens = false
  }

(* Written or generated alike: a generated declaration quietly replacing one
   the program wrote is the mistake nobody would find. *)
let add_entry w name (s : Ast.stmt) =
  if Hashtbl.mem w.entries name
  then (
    match Ast.deriver_trait name with
    | Some trait -> fail s.Ast.span "Trait '%s' already has a deriver." trait
    | None -> fail s.Ast.span "'%s' is already declared." name);
  Hashtbl.replace w.entries name (new_entry name s)

let standing_of w (s : Ast.stmt) =
  let reads = ref S.empty
  and meta = ref false
  and plain_methods = ref S.empty in
  let pure r m' body =
    (not m')
    && (not (contains_code body))
    && S.for_all
         (fun n ->
           match read_method n with
           | Some m -> not (Hashtbl.mem w.meta_methods m)
           | None ->
             (match Hashtbl.find_opt w.entries n with
              | Some d -> plain w d && not (instantiated w d)
              | None -> true))
         r
  in
  let rec members (s : Ast.stmt) =
    match s.Ast.it with
    | `Impl_decl (_, _, _, impl) ->
      List.iter
        (fun (m : (Ast.stmt, unit) Ast.method_def) ->
          let r, m' = survey m.Ast.md_body ~scope:(with_params S.empty m.Ast.md_params) in
          reads := S.union r !reads;
          if pure r m' m.Ast.md_body
          then plain_methods := S.add m.Ast.md_name !plain_methods
          else meta := true)
        impl.Ast.ib_methods
    | `Handler_decl (_, handler) ->
      List.iter
        (fun (a : Ast.stmt Ast.arm) ->
          let r, m' =
            survey a.Ast.arm_body ~scope:(List.fold_left (Fun.flip S.add) S.empty a.Ast.arm_params)
          in
          reads := S.union r !reads;
          if not (pure r m' a.Ast.arm_body) then meta := true)
        handler.Ast.arms
    | `Attributed (_, inner) -> members inner
    | _ -> ()
  in
  members s;
  let target, trait =
    match impl_parts s with
    | Some (trait, ty, _, _) -> Some ty, Option.map fst trait
    | None -> None, None
  in
  { stmt = s
  ; is_plain = not !meta
  ; target
  ; trait
  ; plain_methods = !plain_methods
  ; walked = Hashtbl.create 4
  ; walking = Hashtbl.create 4
  ; handler = None
  ; reads = (if !meta then S.empty else !reads)
  }

(* One with nothing to metaprocess reaches what it reads now, so a meta program
   holding it holds those too; a handler that does is walked where it stands. *)
let walk_standing w (st : standing) =
  if st.is_plain
  then (
    let deps = ref S.empty in
    S.iter (fun n -> ignore (reach w ~deps n)) st.reads;
    st.reads <- !deps)
  else if Option.is_none (impl_parts st.stmt) && Option.is_none st.handler
  then (
    let deps = ref S.empty in
    let out =
      tsingle (runtime_hooks w ~deps ~current:None ~statics:[] ~env:(Hashtbl.create 1)) S.empty st.stmt
    in
    st.reads <- !deps;
    st.handler <- Some out)

let rec note_type w (s : Ast.stmt) =
  match s.Ast.it with
  | `Type_decl (name, _, _) -> Hashtbl.replace w.type_names name ()
  | `Attributed (_, inner) -> note_type w inner
  | _ -> ()

let note_meta_methods w (s : Ast.stmt) =
  match impl_parts s with
  | Some (_, _, _, body) ->
    List.iter
      (fun (m : (Ast.stmt, unit) Ast.method_def) ->
        let _, meta = survey m.Ast.md_body ~scope:(with_params S.empty m.Ast.md_params) in
        if meta || contains_code m.Ast.md_body then Hashtbl.replace w.meta_methods m.Ast.md_name ())
      body.Ast.ib_methods
  | None -> ()

(* A declaration a meta block generated, from the point it was generated. *)
let register w (s : Ast.stmt) =
  note_type w s;
  note_meta_methods w s;
  List.iter
    (fun name ->
      match Hashtbl.find_opt w.unknown name with
      | Some span -> fail span "'%s' is used before the %s that generates it." name w.generator
      | None -> Hashtbl.replace w.known name ())
    (declared_names s);
  List.iter
    (fun name ->
      match Hashtbl.find_opt w.unknown_methods name with
      | Some span -> fail span "'%s' is used before the %s that generates it." name w.generator
      | None -> Hashtbl.replace w.known_methods name ())
    (method_names s);
  match fn_parts s with
  | Some (name, _, _, _) ->
    add_entry w name s;
    w.generated <- `Entry name :: w.generated
  | None ->
    if is_type_level s
    then (
      (match s.Ast.it with
       | `Trait_decl (name, _, _) -> Hashtbl.replace w.traits name ()
       | _ -> ());
      w.types <- s :: w.types;
      w.generated <- `Stmt s :: w.generated)
    else if is_standing s
    then (
      let st = standing_of w s in
      w.standing <- w.standing @ [ st ];
      walk_standing w st;
      w.generated <- `Stmt s :: w.generated)
    else w.generated <- `Stmt s :: w.generated

let () = register_hook := register

let collect w (s : Ast.stmt) =
  note_type w s;
  note_meta_methods w s;
  (match deferred_prefix s with
   | Some prefix ->
     let earlier = Option.value (Hashtbl.find_opt w.units prefix) ~default:[] in
     Hashtbl.replace w.units prefix (earlier @ [ s ])
   | None -> ());
  List.iter (fun name -> Hashtbl.replace w.known name ()) (declared_names s);
  (match s.Ast.it with
   | `Var_decl (name, _, _) -> Hashtbl.replace w.vars name ()
   | `Var_tuple (names, _) -> List.iter (fun name -> Hashtbl.replace w.vars name ()) names
   | _ -> ());
  List.iter (fun name -> Hashtbl.replace w.known_methods name ()) (method_names s);
  match fn_parts s with
  | Some (name, _, _, _) -> add_entry w name s
  | None ->
    (match s.Ast.it with
     | `Trait_decl (name, _, _) -> Hashtbl.replace w.traits name ()
     | _ -> ());
    if is_type_level s then w.types <- s :: w.types

(* A type taking a value, or holding a meta block, is made per argument list;
   one whose members are only functions is a type and an impl, as it would be
   written by hand. *)
let types_of w (p : Ast.program) =
  let method_of (f : Ast.stmt) =
    match fn_parts f with
    | Some (name, params, sg, body) ->
      { Ast.md_name = name; md_params = params; md_signature = sg; md_body = body; md_ann = () }
    | None -> fail f.Ast.span "A type holds functions and meta blocks after its fields."
  in
  let template name params decl members =
    Hashtbl.replace w.type_templates name { tt_name = name; tt_params = params; tt_decl = decl; tt_members = members };
    Hashtbl.replace w.type_names name ();
    Hashtbl.replace w.known name ()
  in
  let runs_meta (m : Ast.stmt) =
    match m.Ast.it with
    | `Meta _ -> true
    | _ ->
      (match fn_parts m with
       | Some (_, params, _, body) -> snd (survey body ~scope:(with_params S.empty params))
       | None -> false)
  in
  let takes_value params = List.exists (fun (p : Ast.type_param) -> Option.is_some p.Ast.tp_ty) params in
  List.concat_map
    (fun (s : Ast.stmt) ->
      match s.Ast.it with
      | `Type_members (({ Ast.it = `Type_decl (name, params, _); _ } as decl), members) ->
        if takes_value params || List.exists runs_meta members
        then (
          template name params decl members;
          [])
        else
          [ decl
          ; Ast.at
              s.Ast.span
              (`Impl_decl
                (None, name, params, { Ast.ib_assoc = []; ib_methods = List.map method_of members }))
          ]
      | `Type_decl (name, params, _) when takes_value params ->
        template name params s [];
        []
      | _ -> [ s ])
    p

(* A template declared in a body is instantiated like one at the top level, so
   it is lifted there under its owner's name. It may read only what it is
   passed: a copy of it lives where the walk puts it, away from the body. *)
let lift_templates (p : Ast.program) =
  let lifted = ref [] in
  let rec body owner (stmts : Ast.stmt list) =
    let renames = Hashtbl.create 4 in
    List.iter
      (fun (s : Ast.stmt) ->
        match fn_parts s with
        | Some (name, _, sg, _) when takes_value_params sg ->
          Hashtbl.replace renames name (Value.Name (Ast.generated [ owner; name ]))
        | _ -> ())
      stmts;
    let rename (s : Ast.stmt) = if Hashtbl.length renames = 0 then s else substitute renames s in
    List.filter_map
      (fun (s : Ast.stmt) ->
        match fn_parts s with
        | Some (name, _, _, b) when Hashtbl.mem renames name ->
          let lifted_name = Ast.generated [ owner; name ] in
          let s = rename s in
          lifted := with_body s (body lifted_name (List.map rename b)) :: !lifted;
          None
        | _ -> Some (stmt owner (rename s)))
      stmts
  and stmt owner (s : Ast.stmt) : Ast.stmt =
    let one = stmt owner in
    let it : Ast.stmt_kind =
      match s.Ast.it with
      | `Fn (name, params, sg, b) -> `Fn (name, params, sg, body (Ast.generated [ owner; name ]) b)
      | `Block b -> `Block (body owner b)
      | `If (c, t, e) -> `If (c, one t, Option.map one e)
      | `While (c, b) -> `While (c, one b)
      | `For (i, c, st, b) -> `For (i, c, st, one b)
      | `For_in (names, over, b) -> `For_in (names, over, one b)
      | `Match (subject, cases) -> `Match (subject, List.map (fun (pat, b) -> pat, body owner b) cases)
      | `Defer inner -> `Defer (one inner)
      | `Attributed (attrs, inner) -> `Attributed (attrs, one inner)
      | `Impl_decl (trait, ty, params, impl) ->
        `Impl_decl
          ( trait
          , ty
          , params
          , { impl with
              Ast.ib_methods =
                List.map
                  (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                    { m with Ast.md_body = body (Ast.method_name ty m.Ast.md_name) m.Ast.md_body })
                  impl.Ast.ib_methods
            } )
      | other -> other
    in
    { s with Ast.it }
  in
  let top =
    List.map
      (fun (s : Ast.stmt) ->
        match fn_parts s with
        | Some (name, _, _, b) -> with_body s (body name b)
        | None ->
          (match s.Ast.it with
           | `Impl_decl _ | `Attributed _ -> stmt "impl" s
           | _ -> s))
      p
  in
  List.rev !lifted @ top

let rec carries attribute (s : Ast.stmt) =
  match s.Ast.it with
  | `Attributed (attrs, inner) ->
    List.exists (fun (a : Ast.attr) -> String.equal a.Ast.a_name attribute) attrs
    || carries attribute inner
  | _ -> false

(* [rooted_by] makes every function carrying that attribute a root, written or
   generated, once every module's top-level meta has run: nothing calls a test,
   so nothing else would reach one. *)
let program ?rooted_by ~out (p : Ast.program) : (Ast.program, error) result =
  let context =
    { out
    ; table = Hashtbl.create 16
    ; codes = Hashtbl.create 16
    ; current = ref (ref [])
    }
  in
  let w =
    { context
    ; entries = Hashtbl.create 64
    ; traits = Hashtbl.create 16
    ; copies = Hashtbl.create 16
    ; instances = []
    ; known = Hashtbl.create 256
    ; unknown = Hashtbl.create 16
    ; known_methods = Hashtbl.create 64
    ; unknown_methods = Hashtbl.create 16
    ; standing = []
    ; types = []
    ; generated = []
    ; generator = "meta block"
    ; roots = ref S.empty
    ; vars = Hashtbl.create 16
    ; units = Hashtbl.create 8
    ; type_names = Hashtbl.create 32
    ; meta_methods = Hashtbl.create 8
    ; type_templates = Hashtbl.create 8
    ; type_copies = Hashtbl.create 8
    }
  in
  try
    List.iter
      (fun (s : Ast.stmt) ->
        List.iter (fun name -> Hashtbl.replace w.known name ()) (declared_names s);
        List.iter (fun name -> Hashtbl.replace w.known_methods name ()) (method_names s);
        match s.Ast.it with
        | `Trait_decl (name, _, _) -> Hashtbl.replace w.traits name ()
        | _ -> ())
      (Prelude.program ());
    Hashtbl.iter (fun name _ -> Hashtbl.replace w.known name ()) (Builtins.env ~out:ignore).Value.vars;
    let p = lift_templates (types_of w p) in
    List.iter (collect w) p;
    w.standing <- List.filter_map (fun s -> if is_standing s then Some (standing_of w s) else None) p;
    List.iter (fun st -> if st.is_plain then walk_standing w st) w.standing;
    let roots = w.roots in
    let root_hooks =
      let base = runtime_hooks w ~deps:roots ~current:None ~statics:[] ~env:(Hashtbl.create 16) in
      { base with
        var =
          (fun scope e ->
            let e = base.var scope e in
            (match e.Ast.it with
             | `Var name when performs_gen w name ->
               fail e.Ast.span "'%s' performs Gen, which only a meta block handles." name
             | _ -> ());
            e)
      }
    in
    let scope = ref S.empty in
    let slots = ref [] in
    let slot f = slots := f :: !slots in
    List.iter
      (fun (s : Ast.stmt) ->
        match deferred_prefix s with
        | Some _ -> ()
        | None ->
        match s.Ast.it with
        | `Meta _ | `Derive _ ->
          let generated = meta_stmt w ~statics:[] ~runtime:!scope ~outer:[] s in
          (* Hoisted, since what generated it may stand below its use. *)
          let declarations, statements = List.partition is_visible_to_meta generated in
          List.iter (register w) declarations;
          let out, inner = tseq root_hooks !scope statements in
          scope := inner;
          slot (fun _ -> out)
        | `Gen _ -> fail s.Ast.span "'gen' is only allowed inside a meta block."
        | _ ->
          (match fn_parts s with
           | Some (name, _, _, _) -> slot (fun emit -> emit name)
           | None ->
             if is_type_level s
             then slot (fun _ -> [ s ])
             else if is_standing s
             then (
               match List.find_opt (fun st -> st.stmt == s) w.standing with
               | Some st ->
                 walk_standing w st;
                 slot (fun _ -> Option.to_list (ready st))
               | None -> slot (fun _ -> [ s ]))
             else (
               let out, inner = tstmt root_hooks !scope s in
               scope := inner;
               slot (fun _ -> out))))
      p;
    Option.iter
      (fun attribute ->
        List.iter
          (fun prefix -> wake w (prefix ^ "_"))
          (Hashtbl.fold (fun prefix _ acc -> prefix :: acc) w.units []);
        let marked =
          Hashtbl.fold
            (fun name (e : entry) acc -> if carries attribute e.written then name :: acc else acc)
            w.entries
            []
        in
        List.iter (fun name -> ignore (reach w ~deps:roots name)) (List.sort compare marked))
      rooted_by;
    (* Only what the running program reaches is emitted; what nothing reaches
       was checked by [Precheck], so an error there is still reported. *)
    let reachable = Hashtbl.create 64 in
    let rec mark n =
      if not (Hashtbl.mem reachable n)
      then (
        Hashtbl.add reachable n ();
        match Hashtbl.find_opt w.entries n with
        | Some e -> S.iter mark e.deps
        | None -> ())
    in
    S.iter mark !roots;
    List.iter (fun st -> S.iter mark st.reads) w.standing;
    let emitted = Hashtbl.create 64 in
    let emit name =
      match Hashtbl.find_opt w.entries name with
      | None -> []
      | Some _ when Hashtbl.mem emitted name -> []
      | Some e ->
        Hashtbl.add emitted name ();
        if is_template e
        then if instantiated w e then [] else [ e.written ]
        else if e.gens || performs_gen w name
        then []
        else if Hashtbl.mem reachable name
        then [ e.walked ]
        else []
    in
    let generated =
      List.concat_map
        (function
          | `Entry name -> emit name
          | `Stmt s ->
            (match List.find_opt (fun st -> st.stmt == s) w.standing with
             | Some st -> Option.to_list (ready st)
             | None -> [ s ]))
        (List.rev w.generated)
    in
    let instances =
      List.concat_map
        (fun name -> if Hashtbl.mem reachable name then emit name else [])
        (List.rev w.instances)
    in
    let body = List.concat_map (fun f -> f emit) (List.rev !slots) in
    Ok (generated @ instances @ body)
  with
  | Failed e -> Error e
