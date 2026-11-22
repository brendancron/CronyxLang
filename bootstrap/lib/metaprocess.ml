(* The rest of the pipeline, applied to a fragment of the program it belongs
   to and then removed. *)

type error = Splice.error =
  { span : Ast.span
  ; message : string
  }

exception Failed = Splice.Failed

let fail = Splice.fail

(* The interpreter already compares two values of any shape, so a derived `Eq`
   reaches that rather than walking the type's fields. *)
let derived_eq span target : Ast.stmt =
  let at it = Ast.at span it in
  let ty name = { Ast.it = Ast.Ty_name name; span; ann = () } in
  Ast.at
    span
    (`Impl_decl
      ( Some (Core.eq, [])
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
                  { Ast.ret = Some (ty "Bool"); row = Some []; static_params = [] }
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
              ; md_attrs = []
              }
            ]
        } ))

(* ---- what a block emits ---- *)

(* A bound run's value is one declaration, which no walk splits. *)
let only = function
  | [ s ] -> s
  | stmts -> Ast.at Source_map.Span.nowhere (`Block stmts)

let emitter = Ast.generated [ "meta"; "emit" ]
let value_emitter = Ast.generated [ "meta"; "emit_value" ]
let capturer = Ast.generated [ "meta"; "value" ]
let quoter = Ast.generated [ "meta"; "code" ]
let quoter_stmts = Ast.generated [ "meta"; "code_stmts" ]
let quoter_decl = Ast.generated [ "meta"; "code_decl" ]
let reflector = Ast.generated [ "meta"; "moduleof" ]
let declarer = Ast.generated [ "meta"; "declof" ]

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
      | Ast.Ty_name n ->
        (match Hashtbl.find_opt bound n with
         | Some v when Syntax.kind_of v = Some Syntax.Type_node ->
           (Splice.syntax t.Ast.span (fun () -> Syntax.to_type ~fallback:t.Ast.span v)).Ast.it
         | _ -> Ast.Ty_name (named n))
      | Ast.Ty_assoc (owner, member) -> Ast.Ty_assoc (type_expr owner, member)
      | Ast.Ty_bind (bound, t) -> Ast.Ty_bind (bound, type_expr t)
      | Ast.Ty_app (n, args) -> Ast.Ty_app (named n, List.map type_expr args)
      | Ast.Ty_tuple items -> Ast.Ty_tuple (List.map type_expr items)
      | Ast.Ty_record fields ->
        Ast.Ty_record (List.map (fun (l, t) -> l, type_expr t) fields)
      | Ast.Ty_fn (args, ret, row) ->
        Ast.Ty_fn (List.map type_expr args, type_expr ret, row)
      | Ast.Ty_row row -> Ast.Ty_row row
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
         (match Splice.reify e.Ast.span v with
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
        | `Method_call (receiver, name, as_function, args, scope) ->
          `Method_call (expr receiver, named name, named as_function, List.map expr args, scope)
        (* Lowered when the code holding it runs, not now. *)
        | (`Code _ | `Code_stmts _ | `Code_decl _) as c -> c
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
        | `Static_call (callee, static_args, args) ->
          `Static_call (expr callee, List.map (static_arg shadowed) static_args, List.map expr args)
        | `Static_ref (callee, static_args) -> `Static_ref (expr callee, List.map (static_arg shadowed) static_args)
        | `Declof (operand, static_args) ->
          `Declof (expr operand, Option.map (List.map (static_arg shadowed)) static_args)
        | `Meta_expr body -> `Meta_expr (sequence shadowed body)
        | #Ast.reflect as r -> (Ast.map_reflect expr r :> Ast.expr_kind)
        | #Ast.run_expr as r ->
          (match Ast.map_run_expr expr (stmt shadowed) (clause shadowed) r with
           | `Run_expr (ret, body, handlers) -> `Run_expr (Option.map type_expr ret, body, handlers))
        | `Match_expr (scrutinee, cases) ->
          `Match_expr
            ( expr scrutinee
            , List.map
                (fun (pattern, (b : (Ast.expr, Ast.stmt) Ast.valued_block)) ->
                  let inner = hidden shadowed (Ast.pattern_names pattern) in
                  ( pattern
                  , { Ast.vb_stmts = sequence inner b.Ast.vb_stmts
                    ; vb_value = Option.map (expr_in inner) b.Ast.vb_value
                    } ))
                cases )
      in
      { e with Ast.it }
  (* A bare name parses as a type, and a meta value there is a value. *)
  and static_arg shadowed (a : Ast.expr Ast.static_arg) =
    match a with
    | Ast.St_type { Ast.it = Ast.Ty_name n; span; _ } when not (Shadowed.mem n shadowed) ->
      (match Option.bind (Hashtbl.find_opt bound n) (Splice.reify span) with
       | Some v -> Ast.St_value v
       | None -> Ast.St_type (type_expr { Ast.it = Ast.Ty_name n; span; ann = () }))
    | a -> Ast.map_static_arg (expr shadowed) a
  and clause shadowed (c : Ast.stmt Ast.handler_clause) =
    match c with
    | Ast.Named n -> Ast.Named n
    | Ast.Handle (handled, defs) -> Ast.Handle (type_expr handled, List.map (method_def shadowed) defs)
    | Ast.Bound (label, handler, value) ->
      Ast.Bound (label, handler, Option.map (fun s -> only (sequence shadowed [ s ])) value)
  and method_def shadowed (m : (Ast.stmt, unit) Ast.method_def) =
    { m with
      Ast.md_params = List.map param m.Ast.md_params
    ; md_signature = signature m.Ast.md_signature
    ; md_body = sequence (hidden shadowed (param_names m.Ast.md_params)) m.Ast.md_body
    }
  and sequence shadowed (body : Ast.stmt list) : Ast.stmt list =
    match body with
    | [] -> []
    | s :: rest ->
      let walked = statements shadowed s in
      let shadowed =
        match s.Ast.it with
        | `Var_decl (name, _, _) -> Shadowed.add name shadowed
        | _ -> shadowed
      in
      walked @ sequence shadowed rest
  (* A bare meta name standing as a statement is spliced by what it holds: a
     statement, a declaration, or a list of statements, which may be empty. *)
  and statements shadowed (s : Ast.stmt) : Ast.stmt list =
    match spliced shadowed s with
    | Some stmts -> stmts
    | None -> [ stmt shadowed s ]
  and spliced shadowed (s : Ast.stmt) : Ast.stmt list option =
    let sp = s.Ast.span in
    match s.Ast.it with
    | `Expr { Ast.it = `Var name; _ } when not (Shadowed.mem name shadowed) ->
      (match Hashtbl.find_opt bound name with
       | Some (Value.Record (Some t, _) as v) when String.equal t Core.list ->
         Some (Splice.syntax sp (fun () -> Syntax.to_stmts ~fallback:sp v))
       | Some v ->
         (match Syntax.kind_of v with
          | Some Syntax.Stmt_node -> Some [ Splice.syntax sp (fun () -> Syntax.to_stmt ~fallback:sp v) ]
          | Some Syntax.Decl_node -> Some [ Splice.syntax sp (fun () -> Syntax.to_decl ~fallback:sp v) ]
          | _ -> None)
       | None -> None)
    | _ -> None
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
      | `Expr ({ Ast.it = `Var _; _ } as e) ->
        (match spliced shadowed s with
         | Some [ one ] -> one.Ast.it
         | Some many -> `Block many
         | None -> `Expr (expr e))
      | `For_in (names, over, inner) ->
        `For_in
          (names, expr over, stmt (List.fold_left (Fun.flip Shadowed.add) shadowed names) inner)
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
          , { Ast.ib_assoc =
                List.map
                  (fun (a : Ast.assoc_def) -> { a with Ast.as_ty = type_expr a.Ast.as_ty })
                  impl.Ast.ib_assoc
            ; ib_methods = List.map (method_def shadowed) impl.Ast.ib_methods
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
      | `Trait_members (decl, metas) ->
        `Trait_members (stmt shadowed decl, List.map (stmt shadowed) metas)
      | `Meta body -> `Meta (sequence shadowed body)
      | `Import decl -> `Import decl
      | `Global_import decl -> `Global_import decl
      | `Var_decl (name, ty, init) ->
        `Var_decl (name, Option.map type_expr ty, Option.map expr init)
      | `Var_tuple (names, init) -> `Var_tuple (names, expr init)
      | #Ast.stmts as st ->
        (Ast.map_stmts expr (stmt shadowed) st :> Ast.stmt_kind)
    in
    { s with Ast.it }
  and expr_in shadowed e = expr shadowed e in
  expr Shadowed.empty, stmt Shadowed.empty, sequence Shadowed.empty, (param, signature, type_expr)

let substitute bound (root : Ast.stmt) : Ast.stmt =
  let _, stmt, _, _ = substitution bound in
  stmt root

let substitute_expr bound (e : Ast.expr) : Ast.expr =
  let expr, _, _, _ = substitution bound in
  expr e

let substitute_all bound (body : Ast.stmt list) : Ast.stmt list =
  let _, _, sequence, _ = substitution bound in
  sequence body

let substitute_type bound (t : Ast.type_expr) : Ast.type_expr =
  let _, _, _, (_, _, type_expr) = substitution bound in
  type_expr t

let substitute_sig bound (m : Ast.method_sig) : Ast.method_sig =
  let _, _, _, (param, signature, _) = substitution bound in
  { m with Ast.ms_params = List.map param m.Ast.ms_params; ms_signature = signature m.Ast.ms_signature }

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
  ; current : Splice.fragment list ref ref
  }

(* A quote standing as the whole statement is what is emitted, not a statement
   computing it. A signature or a type has no statement to stand in. *)
let fragments bound (captured : Ast.stmt) : Splice.fragment list =
  let stmts = List.map (fun s -> Splice.Stmt s) in
  let standalone v =
    match Syntax.kind_of v with
    | Some (Syntax.Sig_node | Syntax.Type_node) -> true
    | _ -> false
  in
  match captured.Ast.it with
  | `Expr { Ast.it = `Code e; _ } -> [ Splice.Expr (substitute_expr bound e) ]
  | `Expr { Ast.it = `Code_stmts body; _ } -> stmts (substitute_all bound body)
  | `Expr { Ast.it = `Code_decl d; _ } -> [ Splice.Stmt (substitute bound d) ]
  | `Expr { Ast.it = `Var name; span; _ } when Option.fold ~none:false ~some:standalone (Hashtbl.find_opt bound name) ->
    Splice.of_value span (Hashtbl.find bound name)
  | _ -> stmts (substitute_all bound [ captured ])

let collect { current; _ } emitted = !current := List.rev_append emitted !(!current)

let emit_into context span args =
  match args with
  | Value.Int index :: rest ->
    (match Hashtbl.find_opt context.table index with
     | Some captured -> collect context (fragments (bindings_of rest) captured)
     | None -> Value.fail span "Nothing was captured here.")
  | _ -> Value.fail span "Nothing was captured here."

let emit_value context span args =
  match args with
  | [ v ] -> collect context (Splice.of_value span v)
  | _ -> Value.fail span "Nothing was captured here."

(* Run against an environment holding the entries a lowered `gen` or
   `code` calls. *)
(* Fresh across the whole program, so no two generated names meet. *)
let fresh_names = ref 0

let run ~out ~codes ~emit ~emit_value ~capture ~reflect ~declof ~declof_call ~named_method ~declare ~remembered ((shared, own) : Ast.resolved_stmt list * Ast.resolved_stmt list) =
  match Compile.back_sharing ~shared ~own with
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
    let quote name convert =
      native name None (fun span args ->
        match args with
        | Value.Int index :: rest ->
          (match Hashtbl.find_opt codes index with
           | Some captured ->
             (try convert (bindings_of rest) captured with
              | Failed e -> raise (Value.Runtime_error { Value.span = e.span; message = e.message })
              | Syntax.Malformed message -> Value.fail span "%s" message)
           | None -> Value.fail span "Nothing was captured here.")
        | _ -> Value.fail span "Nothing was captured here.")
    in
    quote quoter (fun bound captured -> Syntax.expr (substitute_expr bound captured));
    quote quoter_stmts (fun bound captured ->
      match captured.Ast.it with
      | `Code_stmts body -> Syntax.list Syntax.stmt (substitute_all bound body)
      | _ -> Value.fail captured.Ast.span "Nothing was captured here.");
    quote quoter_decl (fun bound captured ->
      match captured.Ast.it with
      | `Code_decl d -> Syntax.decl (substitute bound d)
      | _ -> Value.fail captured.Ast.span "Nothing was captured here.");
    native emitter None (fun span args ->
      emit span args;
      Value.Unit);
    native value_emitter (Some 1) (fun span args ->
      emit_value span args;
      Value.Unit);
    native declarer (Some 1) (fun span args ->
      match args with
      | [ Value.Name name ] ->
        (try Syntax.decl (declof span name) with
         | Failed e -> raise (Value.Runtime_error { Value.span = e.span; message = e.message }))
      | _ -> Value.fail span "declof takes a name.");
    let typed span typer write =
      match typer with
      | None -> Value.fail span "Only a meta block inside checked code can ask for processed code."
      | Some (typer, lowered) ->
        let previous = !Syntax.typer
        and previous_lowered = !Syntax.expansion in
        Syntax.typer := (fun e -> Option.map (Splice.type_expr_of ~opened:true e.Ast.span) (typer e));
        Syntax.expansion := lowered;
        Fun.protect
          ~finally:(fun () ->
            Syntax.typer := previous;
            Syntax.expansion := previous_lowered)
          write
    in
    let checked span check =
      try check () with
      | Typecheck.Located e -> raise (Value.Runtime_error { Value.span = e.Typecheck.span; message = e.Typecheck.message })
      | Syntax.Malformed message -> Value.fail span "%s" message
    in
    native "__processed" (Some 1) (fun span args ->
      match args with
      | [ v ] ->
        checked span (fun () ->
          let body = Syntax.read_valued { Syntax.fallback = span } v in
          typed span (Typecheck.typed_block body) (fun () -> Syntax.valued_block body))
      | _ -> Value.fail span "processed takes a block.");
    let row span labels =
      Syntax.list
        (fun (label, args) ->
          Syntax.record
            "Applied"
            [ "name", Value.Name label; "args", Syntax.list (fun t -> Syntax.type_expr (Splice.type_expr_of span t)) args ])
        labels
    in
    native "__processed_row" (Some 0) (fun span _ -> row span !Typecheck.processed_row);
    native "__arms_row" (Some 0) (fun span _ -> row span (Typecheck.arms_row ()));
    native "__processed_fn" (Some 1) (fun span args ->
      match args with
      | [ v ] ->
        checked span (fun () ->
          let d = Syntax.read_decl { Syntax.fallback = span } v in
          match d.Ast.it with
          | `Fn (name, params, sg, body) -> typed span (Typecheck.typed_fn name params sg body) (fun () -> Syntax.decl d)
          | _ -> Value.fail span "processed_fn takes a function.")
      | _ -> Value.fail span "processed_fn takes a function.");
    native "__fresh_name" (Some 1) (fun span args ->
      match args with
      | [ Value.Str prefix ] ->
        incr fresh_names;
        Value.Name (Ast.generated [ "cx" ^ string_of_int !fresh_names; Utf8.encode prefix ])
      | _ -> Value.fail span "fresh takes a string.");
    let operation (label, op, control, arity) =
      Syntax.record
        "Operation"
        [ "label", Value.Name label
        ; "name", Value.Name op
        ; "takes_control", Value.Bool control
        ; "arity", Value.Int arity
        ]
    in
    native "__operation" (Some 1) (fun span args ->
      match args with
      | [ Value.Name name ] -> Syntax.option operation (Typecheck.operation_of name)
      | _ -> Value.fail span "operation takes a name.");
    native "__operation_in" (Some 2) (fun span args ->
      match args with
      | [ Value.Name label; Value.Name m ] ->
        Syntax.option operation (Typecheck.operation_of (Ast.operation_name label m))
      | _ -> Value.fail span "operation_in takes an effect and a method.");
    native "__operations" (Some 1) (fun span args ->
      match args with
      | [ Value.Name label ] -> Syntax.list operation (Typecheck.effect_operations label)
      | _ -> Value.fail span "operations takes an effect.");
    native "__bound_arguments" (Some 2) (fun span args ->
      match args with
      | [ Value.Name handler; Value.Name label ] ->
        let found =
          List.map Types.resolve (Option.value ~default:[] (Hashtbl.find_opt Typecheck.bound_arguments (handler, label)))
        in
        let found = if List.exists Typecheck.holds_generic found then [] else found in
        Syntax.list (fun t -> Syntax.type_expr (Splice.type_expr_of span t)) found
      | _ -> Value.fail span "bound_arguments takes a handler and an effect.");
    native "__names_function" (Some 1) (fun span args ->
      match args with
      | [ Value.Name name ] -> Value.Bool (Typecheck.names_function name)
      | _ -> Value.fail span "names_function takes a name.");
    native "__method_row" (Some 2) (fun span args ->
      match args with
      | [ Value.Name trait; Value.Name name ] ->
        Value.Array (Array.of_list (List.map (fun l -> Value.Name l) (Typecheck.declared_row trait name)))
      | _ -> Value.fail span "method_row takes a trait and a method.");
    native "__controls" (Some 1) (fun span args ->
      match args with
      | [ Value.Name label ] -> Value.Bool (Typecheck.takes_control_label label)
      | _ -> Value.fail span "controls takes a name.");
    let called span args =
      match args with
      | [ Value.Name name; ty; Value.Span at ] ->
        name, Syntax.read_option (Syntax.read_type { Syntax.fallback = span }) ty, at
      | _ -> Value.fail span "declof_call takes a callee."
    in
    (* At the callee's own span, which is where its call recorded the key it
       reached. *)
    native "__declof_call" (Some 3) (fun span args ->
      let name, ty, at = called span args in
      checked span (fun () ->
        try Syntax.decl (Lazy.force (fst (declof_call span ~at name ty))) with
        | Failed e -> raise (Value.Runtime_error { Value.span = e.span; message = e.message })));
    native "__named_method" (Some 2) (fun span args ->
      match args with
      | [ Value.Name handler; Value.Name short ] ->
        checked span (fun () ->
          try Syntax.option Syntax.decl (named_method span handler short) with
          | Failed e -> raise (Value.Runtime_error { Value.span = e.span; message = e.message }))
      | _ -> Value.fail span "named_method takes a handler and a method.");
    native "__instance_of" (Some 3) (fun span args ->
      let name, ty, at = called span args in
      checked span (fun () ->
        try Value.Name (snd (declof_call span ~at name ty)) with
        | Failed e -> raise (Value.Runtime_error { Value.span = e.span; message = e.message })));
    let key span v =
      try Syntax.read_list Syntax.read_name v with
      | Syntax.Malformed message -> Value.fail span "%s" message
    in
    native "__remembered" (Some 1) (fun span args ->
      match args with
      | [ k ] -> Syntax.option (fun n -> Value.Name n) (Hashtbl.find_opt remembered (key span k))
      | _ -> Value.fail span "remembered takes a key.");
    native "__remember" (Some 2) (fun span args ->
      match args with
      | [ k; Value.Name n ] ->
        Hashtbl.replace remembered (key span k) n;
        Value.Unit
      | _ -> Value.fail span "remember takes a key and a name.");
    native "__declare" (Some 1) (fun span args ->
      match args with
      | [ v ] ->
        checked span (fun () ->
          (try declare (Syntax.read_decl { Syntax.fallback = span } v) with
           | Failed e -> raise (Value.Runtime_error { Value.span = e.span; message = e.message }));
          Value.Unit)
      | _ -> Value.fail span "declare takes a declaration.");
    native reflector (Some 2) (fun span args ->
      match args with
      | [ Value.Str prefix; Value.Str shown ] ->
        (try reflect (Utf8.encode prefix) (Utf8.encode shown) with
         | Failed e -> raise (Value.Runtime_error { Value.span = e.span; message = e.message }))
      | _ -> Value.fail span "moduleof takes a module.");
    (match Compile.run env converted with
     | Ok 0 -> ()
     | Ok code ->
       fail Source_map.Span.nowhere "A meta block ended the program with exit code %d." code
     | Error e -> fail e.Diagnostic.span "%s" e.Diagnostic.message)


(* Inside a `gen`, the largest subexpression made only of meta-scope values is
   evaluated while the block runs and written back as a literal; the rest stays
   syntax. It is replaced by a placeholder the emitter binds, so it rides the
   same path a meta-bound name does. A static call is never evaluated whole —
   that would instantiate from inside the block — but its arguments may be. *)
let promote ~meta ~visible (s : Ast.stmt) : Ast.stmt * (string * Ast.expr) list =
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
    | `Method_call (receiver, _, _, args, _) -> all (receiver :: args)
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
    if evaluable shadowed e then placeholder e else children shadowed e
  and children shadowed (e : Ast.expr) : Ast.expr =
    let expr_in = expr in
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
      | (`Code _ | `Code_stmts _ | `Code_decl _ | `Declof _ | `Meta_expr _) as c -> c
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
      | `Match_expr (scrutinee, cases) ->
        `Match_expr
          ( expr scrutinee
          , List.map
              (fun (pattern, (b : (Ast.expr, Ast.stmt) Ast.valued_block)) ->
                let inner =
                  List.fold_left (Fun.flip Shadowed.add) shadowed (Ast.pattern_names pattern)
                in
                ( pattern
                , { Ast.vb_stmts = sequence inner b.Ast.vb_stmts
                  ; vb_value = Option.map (expr_in inner) b.Ast.vb_value
                  } ))
              cases )
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
let lowering { table; codes; _ } ~visible ~returns =
  (* Added per block with [Hashtbl.add], so an inner function shadows an outer. *)
  let local_fns = Hashtbl.create 4 in
  let rec declared_fn (s : Ast.stmt) =
    match s.Ast.it with
    | `Fn (name, _, sg, _) -> Some (name, sg.Ast.ret)
    | `Attributed (_, inner) -> declared_fn inner
    | _ -> None
  in
  let evaluated scope (e : Ast.expr) =
    let declared name =
      if List.mem name scope
      then None
      else (
        match Hashtbl.find_opt local_fns name with
        | Some ret -> ret
        | None -> returns name)
    in
    let ret =
      match e.Ast.it with
      | `Call ({ Ast.it = `Var name; _ }, _) | `Static_call ({ Ast.it = `Var name; _ }, _, _) -> declared name
      | `Method_call (_, _, as_function, _, _) -> declared as_function
      | _ -> None
    in
    Option.fold ~none:false ~some:Splice.is_syntax_type ret
  in
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
    | `Call ({ Ast.it = `Var "__moduleof"; _ } as callee, args) ->
      { e with Ast.it = `Call ({ callee with Ast.it = `Var reflector }, List.map (expr scope) args) }
    | `Code_stmts _ | `Code_decl _ ->
      let index = Hashtbl.length codes in
      Hashtbl.replace codes index e;
      let callee = match e.Ast.it with `Code_stmts _ -> quoter_stmts | _ -> quoter_decl in
      { e with Ast.it = (call sp index scope callee).Ast.it }
    | `Match_expr (scrutinee, cases) ->
      let arm (p, (b : (Ast.expr, Ast.stmt) Ast.valued_block)) =
        let inner = Ast.pattern_names p @ scope in
        p, { Ast.vb_stmts = block inner b.Ast.vb_stmts; vb_value = Option.map (expr inner) b.Ast.vb_value }
      in
      { e with Ast.it = `Match_expr (expr scope scrutinee, List.map arm cases) }
    | it ->
      let expr = expr scope in
      let it : Ast.expr_kind =
        match it with
        | (`Code _ | `Code_stmts _ | `Code_decl _ | `Declof _ | `Meta_expr _) as c -> c
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
            | Ast.Named name -> Ast.Named name
            | Ast.Handle (handled, defs) ->
              Ast.Handle
                ( handled
                , List.map
                    (fun (m : (Ast.stmt, unit) Ast.method_def) -> { m with Ast.md_body = block scope m.Ast.md_body })
                    defs )
            | Ast.Bound (label, handler, value) ->
              Ast.Bound (label, handler, Option.map (fun s -> only (block scope [ s ])) value)
          in
          (Ast.map_run_expr expr (fun s -> fst (stmt scope s)) clause r :> Ast.expr_kind)

        | `Match_expr _ as m -> m
      in
      { e with Ast.it }
  (* A `code` in an initializer cannot be given the name it initializes. *)
  and stmt scope (s : Ast.stmt) : Ast.stmt * string list =
    let sp = s.Ast.span in
    let same it = { s with Ast.it = it }, scope in
    match s.Ast.it with
    | `Gen { Ast.it = `Expr e; _ } when evaluated scope e ->
      same (`Expr (Ast.at sp (`Call (Ast.at sp (`Var value_emitter), [ expr scope e ]))))
    | `Gen inner ->
      let meta name = List.mem name scope in
      let inner, extras = promote ~meta ~visible inner in
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
    | `Var_tuple (names, init) -> { s with Ast.it = `Var_tuple (names, expr scope init) }, names @ scope
    | `Block body -> same (`Block (block scope body))
    | `While (cond, body) -> same (`While (expr scope cond, fst (stmt scope body)))
    | `If (cond, t, e) ->
      same (`If (expr scope cond, fst (stmt scope t), Option.map (fun e -> fst (stmt scope e)) e))
    | `For_in (names, iterable, body) ->
      same (`For_in (names, expr scope iterable, fst (stmt (names @ scope) body)))
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
    let fns = List.filter_map declared_fn body in
    List.iter (fun (name, ret) -> Hashtbl.add local_fns name ret) fns;
    let lowered =
      List.rev (fst (List.fold_left (fun (out, scope) s ->
        let s, scope = stmt scope s in
        s :: out, scope) ([], scope) body))
    in
    List.iter (fun (name, _) -> Hashtbl.remove local_fns name) fns;
    lowered
  in
  expr, block

let lower context ~visible ~returns ~params (body : Ast.program) =
  snd (lowering context ~visible ~returns) params body

let lower_expr context ~visible ~returns ~params (e : Ast.expr) =
  fst (lowering context ~visible ~returns) params e


(* ---- surface traversal ----

   Reads and rewrites syntax without checking it: substitution, splicing, and
   what a meta block's program has to hold. *)

module S = Shadowed

type hooks =
  { var : S.t -> Ast.expr -> Ast.expr
  ; static_call : S.t -> Ast.expr -> Ast.expr
  ; method_call : S.t -> Ast.expr -> Ast.expr
  ; call : S.t -> Ast.expr -> Ast.expr
  ; code : S.t -> Ast.expr -> Ast.expr
  ; declof : S.t -> Ast.expr -> Ast.expr
  ; meta_expr : S.t -> Ast.expr -> Ast.expr
  ; typeof : S.t -> Ast.expr -> Ast.expr
  ; generic_new : S.t -> Ast.expr -> Ast.expr
  ; (* A local being bound, before it is in scope. *)
    local : string -> Ast.type_expr option -> Ast.expr option -> unit
  ; meta : S.t -> Ast.stmt -> Ast.stmt list
  ; gen : S.t -> Ast.stmt -> Ast.stmt list
  ; run : S.t -> Ast.stmt Ast.handler_clause list -> unit
  ; (* An assignment to, or compound assignment of, a name nothing local
       answers to. *)
    assign : S.t -> Ast.expr -> Ast.expr
  }

let quiet =
  { var = (fun _ e -> e)
  ; static_call = (fun _ e -> e)
  ; method_call = (fun _ e -> e)
  ; call = (fun _ e -> e)
  ; code = (fun _ e -> e)
  ; declof = (fun _ e -> e)
  ; meta_expr = (fun _ e -> e)
  ; typeof = (fun _ e -> e)
  ; generic_new = (fun _ e -> e)
  ; local = (fun _ _ _ -> ())
  ; meta = (fun _ s -> [ s ])
  ; gen = (fun _ s -> [ s ])
  ; run = (fun _ _ -> ())
  ; assign = (fun _ e -> e)
  }

let meta_bodies f =
  { quiet with
    meta =
      (fun _ (s : Ast.stmt) ->
        match s.Ast.it with
        | `Meta inner -> [ { s with Ast.it = `Meta (f inner) } ]
        | _ -> [ s ])
  ; meta_expr =
      (fun _ (e : Ast.expr) ->
        match e.Ast.it with
        | `Meta_expr inner -> { e with Ast.it = `Meta_expr (f inner) }
        | _ -> e)
  }

let with_params scope params =
  List.fold_left (fun acc (p : Ast.param) -> S.add p.Ast.name acc) scope params

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
  let assigned name (it : Ast.expr_kind) : Ast.expr_kind =
    if S.mem name scope then it else (h.assign scope { e with Ast.it }).Ast.it
  in
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
  | `Static_ref (callee, static_args) ->
    let callee =
      match callee.Ast.it with
      | `Var _ -> callee
      | _ -> ex callee
    in
    h.static_call scope { e with Ast.it = `Static_ref (callee, List.map (Ast.map_static_arg ex) static_args) }
  | `Method_call (receiver, name, as_function, args, in_scope) ->
    let receiver = ex receiver in
    let args = many args in
    h.method_call scope { e with Ast.it = `Method_call (receiver, name, as_function, args, in_scope) }
  | `Code _ | `Code_stmts _ | `Code_decl _ -> h.code scope e
  | `Declof _ -> h.declof scope e
  | `Meta_expr _ -> h.meta_expr scope e
  | `Lambda (params, sg, body) ->
    { e with Ast.it = `Lambda (params, sg, tblock h (with_params scope params) body) }
  | `Run_expr (ret, body, handlers) ->
    h.run scope handlers;
    let body = tvalued h scope body in
    { e with Ast.it = `Run_expr (ret, body, List.map (tclause h scope) handlers) }
  | `Match_expr (scrutinee, cases) ->
    let scrutinee = ex scrutinee in
    let cases =
      List.map
        (fun (p, b) -> p, tvalued h (List.fold_left (Fun.flip S.add) scope (Ast.pattern_names p)) b)
        cases
    in
    { e with Ast.it = `Match_expr (scrutinee, cases) }
  | it ->
    let it : Ast.expr_kind =
      match it with
      | #Ast.lit as l -> l
      | `Assign (name, v) -> assigned name (`Assign (name, ex v))
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
      | `Compound (op, name, v) -> assigned name (`Compound (op, name, ex v))
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
      | `Typeof a -> (h.typeof scope { e with Ast.it = `Typeof (ex a) }).Ast.it
      | `Var _ | `Static_call _ | `Static_ref _ | `Method_call _ | `Code _ | `Code_stmts _ | `Code_decl _
      | `Declof _ | `Meta_expr _ | `Lambda _ | `Run_expr _
      | `Match_expr _ -> it
    in
    { e with Ast.it }

and tvalued h scope (b : (Ast.expr, Ast.stmt) Ast.valued_block) =
  let stmts, scope = tseq h scope b.Ast.vb_stmts in
  { Ast.vb_stmts = stmts; vb_value = Option.map (texpr h scope) b.Ast.vb_value }

and tclause h scope (c : Ast.stmt Ast.handler_clause) =
  match c with
  | Ast.Named name -> Ast.Named name
  | Ast.Handle (handled, defs) ->
    Ast.Handle
      ( handled
      , List.map
          (fun (m : (Ast.stmt, unit) Ast.method_def) ->
            { m with Ast.md_body = tblock h (with_params scope m.Ast.md_params) m.Ast.md_body })
          defs )
  | Ast.Bound (label, handler, value) ->
    Ast.Bound (label, handler, Option.map (fun s -> only (tblock h scope [ s ])) value)

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
  | `Break -> one `Break
  | `Continue -> one `Continue
  | `Expr e -> one (`Expr (ex e))
  | `Defer inner -> one (`Defer (st inner))
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
               p, tblock h (List.fold_left (Fun.flip S.add) scope (Ast.pattern_names p)) body)
             cases ))
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
  | `Type_decl _ | `Trait_decl _ | `Import _ | `Global_import _ | `Type_members _ | `Trait_members _ ->
    [ s ], scope

(* ---- what a declaration needs ---- *)

(* A method is read by name alone, so it is kept apart from a variable's. *)
let method_read name = "." ^ name


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
           | `Static_call ({ Ast.it = `Var name; _ }, _, _) | `Static_ref ({ Ast.it = `Var name; _ }, _) ->
             reads := S.add name !reads
           | _ -> ());
          e)
    ; method_call =
        (fun _ e ->
          (match e.Ast.it with
           | `Method_call (_, name, as_function, _, _) ->
             reads := S.add as_function (S.add (method_read name) !reads)
           | _ -> ());
          e)
    ; meta =
        (fun _ s ->
          meta := true;
          [ s ])
    ; meta_expr =
        (fun _ e ->
          meta := true;
          e)
    ; gen =
        (fun _ s ->
          meta := true;
          [ s ])
    }
  in
  ignore (tblock h scope body);
  !reads, !meta

(* ---- the world ---- *)

type state =
  | Walking
  | Done
  | Failed_instance

type spliced =
  | Spliced_stmts of Ast.stmt list
  | Spliced_expr of Ast.expr

(* A declaration at one key. Its type is the written signature while it is
   being processed, and what its body inferred once it is done. *)
type instance =
  { decl : Typecheck.walk_decl
  ; key : Key.t
  ; name : string
  ; mutable state : state
  ; mutable ty : Types.infer_ty
  ; mutable ret_written : bool
  ; mutable checked : Typecheck.checked_stmt option
  ; mutable processed : Ast.resolved_stmt list option
  ; (* The instances its body names, by name. *)
    mutable deps : S.t
  ; (* Its body quotes code or runs a `gen`, so only a meta block runs it. *)
    mutable quoting : bool
  ; (* The body as the checker received it, and what each of its meta blocks
       generated, by the block's own statement list: what `declof` shows. *)
    mutable source : Ast.stmt list
  ; mutable generated : (Ast.stmt list * spliced) list
  }

type made =
  | Function of instance
  | Copy of string

(* A meta block being checked: what it names, and what a block nested in it
   cannot see. *)
type frame =
  { outer : string list
  ; mutable reached : S.t
  }

type world =
  { context : context
  ; registry : Registry.t
  ; mutable session : Typecheck.Session.t option
  ; traits : (string, unit) Hashtbl.t
  ; (* By declaration and key: a function's instances, and a type's copies. *)
    cache : (int * string, made) Hashtbl.t
  ; (* Newest first, per declaration. *)
    by_decl : (int, instance list) Hashtbl.t
  ; by_name : (string, instance) Hashtbl.t
  ; (* Top-level instances completed and not yet zonked, newest first. *)
    mutable finished : instance list
  ; mutable current : instance option
  ; mutable meta_frame : frame option
  ; (* The instances processed, newest first. *)
    mutable emitted : instance list
  ; (* What the root statements name. *)
    mutable rooted : S.t
  ; mutable root : string option
  ; (* Every top-level function, written or generated: what a meta program
       compiles from. *)
    fns : (string, Ast.stmt) Hashtbl.t
  ; known : (string, unit) Hashtbl.t
  ; unknown : (string, Ast.span) Hashtbl.t
  ; known_methods : (string, unit) Hashtbl.t
  ; unknown_methods : (string, Ast.span) Hashtbl.t
  ; mutable impls : Ast.stmt list
  ; mutable types : Ast.stmt list
  ; mutable generator : string
  ; (* Run-time variables, which a meta program never sees. *)
    vars : (string, unit) Hashtbl.t
  ; (* A module's top-level meta blocks, by the prefix its names carry, until
       the walk first asks it for one. *)
    units : (string, Ast.stmt list) Hashtbl.t
  ; type_names : (string, unit) Hashtbl.t
  ; (* A type taking a value, or whose body runs a meta block: copied once per
       key, into [cache], when first built. *)
    comptime_types : (string, comptime_type) Hashtbl.t
  ; (* A trait whose body runs a meta block: made once per argument list, as an
       impl first names it. *)
    comptime_traits : (string, comptime_trait) Hashtbl.t
  ; (* Every named top-level declaration, written or generated, newest first:
       what `moduleof` lists. *)
    mutable declared : Ast.stmt list
  ; gens : (string, bool) Hashtbl.t
  ; (* The type-level declarations as processed, newest first. *)
    mutable type_level : Ast.resolved_stmt list
  ; (* What one meta block left for a later one: a name, by a key of names. *)
    remembered : (string list, string) Hashtbl.t
  ; (* A plain generic type, copied per key as processed code names it. *)
    generic_decls : (string, comptime_type) Hashtbl.t
  ; (* Each copy of one, newest first. *)
    mutable copies_made : string list
  }

and comptime_type =
  { tt_id : int
  ; tt_name : string
  ; tt_params : Ast.type_param list
  ; tt_decl : Ast.stmt
  ; tt_members : Ast.stmt list
  }

and comptime_trait =
  { tr_id : int
  ; tr_name : string
  ; tr_params : string list
  ; tr_body : Ast.trait_body
  ; tr_metas : Ast.stmt list
  ; tr_attrs : Ast.attr list
  ; tr_span : Ast.span
  }

let session w = Option.get w.session

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

let rec fn_parts (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn (name, params, sg, body) -> Some (name, params, sg, body)
  | `Attributed (_, inner) -> fn_parts inner
  | _ -> None

(* [fn_parts] drops the wrapper, so a function inside a type body would arrive
   at the impl it becomes with its attributes gone. *)
let rec fn_attrs (s : Ast.stmt) =
  match s.Ast.it with
  | `Attributed (list, inner) -> list @ fn_attrs inner
  | _ -> []

let rec with_body (s : Ast.stmt) body =
  match s.Ast.it with
  | `Fn (name, params, sg, _) -> { s with Ast.it = `Fn (name, params, sg, body) }
  | `Attributed (attrs, inner) -> { s with Ast.it = `Attributed (attrs, with_body inner body) }
  | _ -> s

(* `<T: Show>` and `<n: Int>` are one syntax: only whether the annotation's head
   names a trait says a bound from a value. *)
let value_param traits (p : Ast.static_param) =
  match p.Ast.sp_ty with
  | None -> false
  | Some { Ast.it = Ast.Ty_name name; _ } | Some { Ast.it = Ast.Ty_app (name, _); _ } ->
    not (Hashtbl.mem traits name)
  | Some _ -> true

let is_value w = value_param w.traits

let param_names params = List.map (fun (p : Ast.param) -> p.Ast.name) params

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

(* A run-time name does not cross into a meta block, but its type does: a
   `typeof` reading one is answered before the block is checked, where the
   name is still in scope. *)
let typed_body type_in runtime body =
  let runtime = S.of_list runtime in
  let h =
    { quiet with
      typeof =
        (fun scope e ->
          match e.Ast.it with
          | `Typeof operand
            when S.exists (fun n -> S.mem n runtime && not (S.mem n scope)) (reads_of operand) ->
            Splice.reflected e.Ast.span (type_in operand) None
          | _ -> e)
    }
  in
  tblock h S.empty body

let typed_reads type_in runtime (s : Ast.stmt) =
  match s.Ast.it with
  | `Meta body -> { s with Ast.it = `Meta (typed_body type_in runtime body) }
  | _ -> s

let variant_of w (ty : string) (name : string) =
  let rec declares (s : Ast.stmt) =
    match s.Ast.it with
    | `Type_decl (n, _, Ast.T_variants variants) when String.equal n ty ->
      List.exists (fun (v : Ast.variant) -> String.equal v.Ast.v_name name) variants
    | `Attributed (_, inner) -> declares inner
    | _ -> false
  in
  List.exists declares w.types

(* A name written in `<…>` parses as a type whether it is one or not, so a value
   argument is read back out of it: `Mode.Fast` is a projection there. *)
let rec value_of_type (t : Ast.type_expr) : Ast.expr option =
  let at it = Some (Ast.at t.Ast.span it) in
  match t.Ast.it with
  | Ast.Ty_name n -> at (`Var n)
  | Ast.Ty_assoc (owner, member) ->
    Option.bind (value_of_type owner) (fun owner -> at (`Field (owner, member)))
  | Ast.Ty_tuple items ->
    let items = List.map value_of_type items in
    if List.for_all Option.is_some items then at (`Tuple (List.map Option.get items)) else None
  | _ -> None

let rec type_key (t : Ast.type_expr) =
  match t.Ast.it with
  | Ast.Ty_name n -> n
  | Ast.Ty_app (n, args) -> n ^ "<" ^ String.concat "," (List.map type_key args) ^ ">"
  | Ast.Ty_tuple items -> "(" ^ String.concat "," (List.map type_key items) ^ ")"
  | _ -> "_"

(* Total, so it also decides whether an argument may be one at all. Two
   arguments share a copy exactly when their keys are equal, so a key says
   which constructor built every part of the value. *)
let rec key_of w (e : Ast.expr) : string option =
  let all es =
    let keys = List.map (key_of w) es in
    if List.for_all Option.is_some keys
    then Some (String.concat "," (List.map Option.get keys))
    else None
  in
  (* Fields are sorted: `P { x: 1, y: 2 }` and `P { y: 2, x: 1 }` are one value. *)
  let fields fs =
    let fs = List.sort (fun (a, _) (b, _) -> String.compare a b) fs in
    Option.map
      (fun values -> "{" ^ values ^ "}")
      (let keyed = List.map (fun (l, v) -> Option.map (fun k -> l ^ ":" ^ k) (key_of w v)) fs in
       if List.for_all Option.is_some keyed
       then Some (String.concat "," (List.map Option.get keyed))
       else None)
  in
  match e.Ast.it with
  | `Unit -> Some "()"
  | `Int n -> Some (string_of_int n)
  | `Float n -> Some (Printf.sprintf "%h" n)
  | `Str s -> Some (Printf.sprintf "%S" (Utf8.encode s))
  | `Char c -> Some (Printf.sprintf "'%d'" (Uchar.to_int c))
  | `Bool b -> Some (string_of_bool b)
  | `Bytes b -> Some ("bytes:" ^ Digest.to_hex (Digest.string b))
  | `Unop (Ast.Neg, inner) -> Option.map (fun key -> "-" ^ key) (key_of w inner)
  | `Unop (Ast.Bit_not, inner) -> Option.map (fun key -> "~" ^ key) (key_of w inner)
  | `Tuple items -> Option.map (fun k -> "(" ^ k ^ ")") (all items)
  | `Collection_lit items -> Option.map (fun k -> "[" ^ k ^ "]") (all items)
  | `Record_lit fs -> fields fs
  | `New (name, fs) -> Option.map (fun k -> name ^ k) (fields fs)
  (* The parameter's type already fixes the type arguments, so only a value
     argument tells two of these apart, and `Pair { … }` shares a copy with
     `Pair<Int, String> { … }`. *)
  | `New_generic (name, static_args, fs) ->
    (match
       List.filter_map
         (function
           | Ast.St_type _ -> None
           | Ast.St_value v -> Some v)
         static_args
     with
     | [] -> Option.map (fun k -> name ^ k) (fields fs)
     | values ->
       (match all values, fields fs with
        | Some v, Some f -> Some (name ^ "<" ^ v ^ ">" ^ f)
        | _ -> None))
  | `Field ({ Ast.it = `Var ty; _ }, name) when variant_of w ty name -> Some (ty ^ "." ^ name)
  | `Method_call ({ Ast.it = `Var ty; _ }, name, _, args, _) when variant_of w ty name ->
    Option.map (fun k -> ty ^ "." ^ name ^ "(" ^ k ^ ")") (all args)
  | `New_variant (ty, name, Ast.P_none) -> Some (ty ^ "." ^ name)
  | `New_variant (ty, name, Ast.P_tuple args) ->
    Option.map (fun k -> ty ^ "." ^ name ^ "(" ^ k ^ ")") (all args)
  | `New_variant (ty, name, Ast.P_fields fs) ->
    Option.map (fun k -> ty ^ "." ^ name ^ k) (fields fs)
  | _ -> None

(* What a static value's `==` compiles to is not visible here, so a
   comparison folds only when every type in it compares field by field: no
   `Eq` impl, or one the compiler derived. *)
let structural_eq w ty =
  let derived (m : (Ast.stmt, unit) Ast.method_def) =
    match m.Ast.md_body with
    | [ { Ast.it = `Return (Some { Ast.it = `Call ({ Ast.it = `Var "__structural_eq"; _ }, _); _ }); _ } ] ->
      true
    | _ -> false
  in
  not
    (List.exists
       (fun s ->
         match impl_parts s with
         | Some (Some (trait, _), target, _, body) ->
           String.equal trait Core.eq
           && String.equal target ty
           && not (List.for_all derived body.Ast.ib_methods)
         | _ -> false)
       w.impls)

let rec constructed w (e : Ast.expr) =
  let all = List.concat_map (constructed w) in
  let named name =
    match String.rindex_opt name '.' with
    | Some at when variant_of w (String.sub name 0 at) (String.sub name (at + 1) (String.length name - at - 1)) ->
      String.sub name 0 at
    | _ -> name
  in
  match e.Ast.it with
  | `Tuple items | `Collection_lit items -> all items
  | `Record_lit fs -> all (List.map snd fs)
  | `New (name, fs) | `New_generic (name, _, fs) -> named name :: all (List.map snd fs)
  | `Field ({ Ast.it = `Var ty; _ }, _) -> [ ty ]
  | `Method_call ({ Ast.it = `Var ty; _ }, _, _, args, _) -> ty :: all args
  | `New_variant (ty, _, payload) ->
    ty
    :: (match payload with
        | Ast.P_none -> []
        | Ast.P_tuple args -> all args
        | Ast.P_fields fs -> all (List.map snd fs))
  | _ -> []

let hidden w = Hashtbl.fold (fun name () acc -> name :: acc) w.vars []

let checks w (s : Ast.stmt) =
  try Typecheck.Walk.probe (session w) ~hidden:(hidden w) s with
  | Typecheck.Located e -> fail e.Typecheck.span "%s" e.Typecheck.message

let equal w op (e : Ast.expr) (a : Ast.expr) (b : Ast.expr) =
  match key_of w a, key_of w b with
  | Some x, Some y when List.for_all (structural_eq w) (constructed w a @ constructed w b) ->
    checks w (Ast.at e.Ast.span (`Var_decl (Ast.generated [ "static"; "comparison" ], None, Some e)));
    Some { e with Ast.it = `Bool (if op = Ast.Equal then String.equal x y else not (String.equal x y)) }
  | _ -> None

(* A static argument is an expression the compiler can evaluate: literals and
   constructors, and the static parameters already written in where it stands,
   under the operators. A call is evaluated only inside a meta block. *)
let rec fold w (e : Ast.expr) : Ast.expr =
  let at it = { e with Ast.it } in
  let lit (e : Ast.expr) = match e.Ast.it with #Ast.lit -> true | _ -> false in
  let fields = List.map (fun (l, v) -> l, fold w v) in
  match e.Ast.it with
  | `Tuple items -> at (`Tuple (List.map (fold w) items))
  | `Collection_lit items -> at (`Collection_lit (List.map (fold w) items))
  | `Record_lit fs -> at (`Record_lit (fields fs))
  | `New (name, fs) -> at (`New (name, fields fs))
  | `New_generic (name, static_args, fs) ->
    at (`New_generic (name, List.map (Ast.map_static_arg (fold w)) static_args, fields fs))
  | `Method_call (receiver, name, as_function, args, scope) ->
    at (`Method_call (receiver, name, as_function, List.map (fold w) args, scope))
  | `New_variant (ty, name, payload) -> at (`New_variant (ty, name, Ast.map_payload (fold w) payload))
  | `Tuple_get (a, i) ->
    (match (fold w a).Ast.it with
     | `Tuple items when i >= 0 && i < List.length items -> List.nth items i
     | _ -> e)
  | `Field (a, label) ->
    (match (fold w a).Ast.it with
     | `Record_lit fs | `New (_, fs) | `New_generic (_, _, fs) ->
       (match List.assoc_opt label fs with
        | Some v -> v
        | None -> e)
     | _ -> e)
  | `Unop (op, a) ->
    (match op, (fold w a).Ast.it with
     | Ast.Neg, `Int n -> at (`Int (-n))
     | Ast.Neg, `Float n -> at (`Float (-.n))
     | Ast.Not, `Bool b -> at (`Bool (not b))
     | Ast.Bit_not, `Int n -> at (`Int (lnot n))
     | _ -> e)
  | `And (a, b) | `Or (a, b) ->
    (match (fold w a).Ast.it, (fold w b).Ast.it, e.Ast.it with
     | `Bool x, `Bool y, `And _ -> at (`Bool (x && y))
     | `Bool x, `Bool y, _ -> at (`Bool (x || y))
     | _ -> e)
  | `Binop (op, a, b) ->
    let a = fold w a
    and b = fold w b in
    if not (lit a && lit b)
    then (
      match op with
      | Ast.Equal | Ast.Not_equal -> Option.value (equal w op e a b) ~default:e
      | _ -> e)
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
      | Ast.Bit_and, `Int x, `Int y -> at (`Int (x land y))
      | Ast.Bit_or, `Int x, `Int y -> at (`Int (x lor y))
      | Ast.Bit_xor, `Int x, `Int y -> at (`Int (x lxor y))
      | Ast.Add, `Float x, `Float y -> at (`Float (x +. y))
      | Ast.Sub, `Float x, `Float y -> at (`Float (x -. y))
      | Ast.Mul, `Float x, `Float y -> at (`Float (x *. y))
      | Ast.Div, `Float x, `Float y -> at (`Float (x /. y))
      | Ast.Add, `Str x, `Str y -> at (`Str (Array.append x y))
      | _, `Int x, `Int y -> Option.fold ~none:e ~some:(fun r -> at (`Bool r)) (judged (Int.compare x y))
      (* Not through [judged]: a total order would make NaN equal to itself. *)
      | Ast.Equal, `Float x, `Float y -> at (`Bool (x = y))
      | Ast.Not_equal, `Float x, `Float y -> at (`Bool (x <> y))
      | Ast.Less, `Float x, `Float y -> at (`Bool (x < y))
      | Ast.Less_equal, `Float x, `Float y -> at (`Bool (x <= y))
      | Ast.Greater, `Float x, `Float y -> at (`Bool (x > y))
      | Ast.Greater_equal, `Float x, `Float y -> at (`Bool (x >= y))
      | _, `Str x, `Str y -> Option.fold ~none:e ~some:(fun r -> at (`Bool r)) (judged (Utf8.compare x y))
      | _ -> e)
  | _ -> e

let static_value w name (arg : Ast.expr Ast.static_arg) : Ast.expr * string =
  let written =
    match arg with
    | Ast.St_type t ->
      (match value_of_type t with
       | Some v -> fold w v
       | None -> fail t.Ast.span "'%s' takes a value here, not a type." name)
    | Ast.St_value v -> fold w v
  in
  match key_of w written with
  | Some key -> written, key
  | None ->
    (match written.Ast.it with
     | `Var unknown when Hashtbl.mem w.type_names unknown ->
       fail written.Ast.span "'%s' takes a value here, not a type." name
     | `Var unknown ->
       fail
         written.Ast.span
         "'%s' is not known at compile time: it is a run-time variable, not a static \
          parameter of the enclosing function."
         unknown
     | `Binop ((Ast.Equal | Ast.Not_equal), a, b)
       when Option.is_some (key_of w (fold w a)) && Option.is_some (key_of w (fold w b)) ->
       let own = List.find (fun ty -> not (structural_eq w ty)) (constructed w (fold w a) @ constructed w (fold w b)) in
       fail
         written.Ast.span
         "'%s' has its own Eq, so a comparison of it is evaluated at compile time only \
          inside a meta block."
         own
     | `Call _ | `Static_call _ | `Static_ref _ | `Method_call _ ->
       fail
         written.Ast.span
         "This argument to '%s' is not known at compile time: a call is evaluated at \
          compile time only inside a meta block."
         name
     | _ ->
       fail
         written.Ast.span
         "This argument to '%s' is not known at compile time; only literals, \
          constructors and the static parameters of the enclosing function are."
         name)

(* An instance binds its value parameters as locals, but a static argument is
   decided before the instance runs, so there the value itself is written in.
   Not inside a meta block: the block binds the value itself, so one nested in
   it does not receive it. *)
let substitute_values (values : (string * Ast.expr) list) (body : Ast.stmt list) =
  let passed h scope (a : Ast.expr Ast.static_arg) =
    match a with
    | Ast.St_value v -> Ast.St_value (texpr h scope v)
    | Ast.St_type t ->
      (match value_of_type t with
       | Some v when S.exists (fun n -> List.mem_assoc n values) (S.diff (reads_of v) scope) ->
         Ast.St_value (texpr h scope v)
       | _ -> a)
  in
  let arguments h =
    { quiet with
      static_call =
        (fun scope e ->
          match e.Ast.it with
          | `Static_call (callee, static_args, args) ->
            { e with Ast.it = `Static_call (callee, List.map (passed !h scope) static_args, args) }
          | _ -> e)
    ; generic_new =
        (fun scope e ->
          match e.Ast.it with
          | `New_generic (name, static_args, fields) ->
            { e with Ast.it = `New_generic (name, List.map (passed !h scope) static_args, fields) }
          | _ -> e)
    }
  in
  let written = ref quiet in
  written
  := { (arguments written) with
       var =
         (fun _ e ->
           match e.Ast.it with
           | `Var name ->
             (match List.assoc_opt name values with
              | Some v -> { v with Ast.span = e.Ast.span }
              | None -> e)
           | _ -> e)
     };
  tblock (arguments written) S.empty body

let bind_values (values : (string * Ast.type_expr option * Ast.expr) list) body =
  List.map (fun (n, ty, (v : Ast.expr)) -> Ast.at v.Ast.span (`Var_decl (n, ty, Some v))) values
  @ substitute_values (List.map (fun (n, _, v) -> n, v) values) body

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

let visible w n = (Hashtbl.mem w.fns n || Hashtbl.mem w.known n) && not (Hashtbl.mem w.vars n)

let returns w n =
  match Option.bind (Hashtbl.find_opt w.fns n) fn_parts with
  | Some (_, _, sg, _) -> sg.Ast.ret
  | None -> None

let rec gens_in (body : Ast.stmt list) =
  List.exists
    (fun (s : Ast.stmt) ->
      match s.Ast.it with
      | `Gen _ -> true
      | `Block b | `Fn (_, _, _, b) -> gens_in b
      | `If (_, t, e) -> gens_in (t :: Option.to_list e)
      | `While (_, b) | `For_in (_, _, b) | `Defer b | `Attributed (_, b) -> gens_in [ b ]
      | `Match (_, cases) -> List.exists (fun (_, b) -> gens_in b) cases
      | _ -> false)
    body

(* A function that runs a `gen` outside any meta block runs only as part of
   one, and so does whatever calls it. *)
let rec performs_gen w name params body =
  match Hashtbl.find_opt w.gens name with
  | Some answer -> answer
  | None ->
    Hashtbl.replace w.gens name false;
    let answer =
      gens_in body
      || S.exists
           (fun n ->
             match Option.bind (Hashtbl.find_opt w.fns n) fn_parts with
             | Some (_, params, _, b) when not (String.equal n name) -> performs_gen w n params b
             | _ -> false)
           (fst (survey body ~scope:(with_params S.empty params)))
    in
    Hashtbl.replace w.gens name answer;
    answer

(* ---- walking ---- *)

let rec declared_of (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) | `Type_decl (name, _, _) | `Trait_decl (name, _, _) -> [ name ]
  | `Attributed (_, inner) -> declared_of inner
  | _ -> []

(* Set once [register] exists; the walk and registration call each other. *)
let register_hook : (world -> Ast.stmt -> unit) ref = ref (fun _ _ -> ())
let module_hook : (world -> string -> string -> Value.value) ref = ref (fun _ _ _ -> Value.Unit)

let starts_with ~prefix name =
  let n = String.length prefix in
  String.length name > n && String.equal (String.sub name 0 n) prefix

let deferred_prefix (s : Ast.stmt) =
  match s.Ast.it with
  | `Attributed ([ { Ast.a_name; a_args = [ Ast.A_str prefix ]; _ } ], _)
    when String.equal a_name Ast.deferred_marker -> Some prefix
  | _ -> None

let is_printer (d : Typecheck.walk_decl) =
  match d.Typecheck.wd_impl with
  | Some (Some (t, _), _, _) -> String.equal t Core.display || String.equal t Core.debug
  | _ -> false

let instance_name w (d : Typecheck.walk_decl) (key : Key.t) =
  let made = Option.value ~default:[] (Hashtbl.find_opt w.by_decl d.Typecheck.wd_id) in
  (* The printer finds a `Display` or `Debug` method by its declaration's name,
     so the first instance of one keeps it. *)
  if key = [] || (is_printer d && made = [])
  then d.Typecheck.wd_name
  else Ast.generated [ d.Typecheck.wd_name; string_of_int (List.length made) ]

let view (i : instance) : Typecheck.instance_view =
  { Typecheck.iv_name = i.name
  ; iv_ty = i.ty
  ; iv_walking = i.state = Walking
  ; iv_ret_written = i.ret_written || i.state = Failed_instance
  ; iv_key = i.key
  }

let values_of (key : Key.t) =
  List.filter_map
    (fun (name, arg) ->
      match arg with
      | Key.Value (v, _) -> Some (name, v)
      | _ -> None)
    key

let referenced w name =
  match w.current, w.meta_frame with
  | Some i, _ -> i.deps <- S.add name i.deps
  | None, Some f -> f.reached <- S.add name f.reached
  | None, None -> w.rooted <- S.add name w.rooted

let processed_of w i =
  match i.processed with
  | Some processed -> processed
  | None ->
    let previous = w.current in
    w.current <- Some i;
    let processed =
      Fun.protect
        ~finally:(fun () -> w.current <- previous)
        (fun () -> Typecheck.processed_stmt w.registry (Option.get i.checked))
    in
    i.processed <- Some processed;
    w.emitted <- i :: w.emitted;
    processed

(* Processed at the end of the root statement that reached them, not their
   own: a body may share a variable with a `var` the statement settles later.
   Processing one may reach more. *)
let rec drain w =
  match List.rev w.finished with
  | [] -> ()
  | finished ->
    w.finished <- [];
    List.iter
      (fun i ->
        match Types.repr i.ty with
        | Types.IFn (_, _, row) -> Typecheck.close_tail row
        | _ -> ())
      finished;
    List.iter (fun i -> ignore (processed_of w i)) finished;
    drain w

let rec made ?(use = true) w span (d : Typecheck.walk_decl) (key : Key.t) : instance =
  match Hashtbl.find_opt w.cache (d.Typecheck.wd_id, Key.show key) with
  | Some (Function i) ->
    if use && i.quoting && not !Typecheck.in_meta
    then
      fail
        span
        "'%s' quotes code or runs a gen, so only a meta block can call it."
        (Typecheck.shown_name d.Typecheck.wd_name);
    if use then referenced w i.name;
    i
  | Some (Copy _) | None ->
    let name = instance_name w d key in
    if use then referenced w name;
    let i =
      { decl = d
      ; key
      ; name
      ; state = Walking
      ; ty = Types.fresh ()
      ; ret_written = false
      ; checked = None
      ; processed = None
      ; deps = S.empty
      ; quoting = false
      ; source = []
      ; generated = []
      }
    in
    Hashtbl.replace w.cache (d.Typecheck.wd_id, Key.show key) (Function i);
    Hashtbl.replace
      w.by_decl
      d.Typecheck.wd_id
      (i :: Option.value ~default:[] (Hashtbl.find_opt w.by_decl d.Typecheck.wd_id));
    Hashtbl.replace w.by_name name i;
    let values = values_of key in
    let named = Hashtbl.create 4 in
    List.iter
      (fun (p : Ast.static_param) ->
        match p.Ast.sp_ty, List.assoc_opt p.Ast.sp_name values with
        | Some ty, Some v -> check_static w named ty v
        | _ -> ())
      d.Typecheck.wd_values;
    let body =
      match values with
      | [] -> d.Typecheck.wd_body
      | values ->
        bind_values
          (List.map
             (fun (p : Ast.static_param) ->
               p.Ast.sp_name, p.Ast.sp_ty, List.assoc p.Ast.sp_name values)
             (List.filter
                (fun (p : Ast.static_param) -> List.mem_assoc p.Ast.sp_name values)
                d.Typecheck.wd_values))
          d.Typecheck.wd_body
    in
    (* A meta block names a type argument by its parameter: a type is not a
       value there, so it does not cross, it is written in. Nowhere else: the
       checker reads a parameter through the key, and writing a type's name
       into the body would let a parameter of the same name capture it. *)
    let named = Hashtbl.create 4 in
    List.iter
      (fun (param, arg) ->
        match arg with
        | Key.Type ty ->
          (match ty with
           | Types.Int | Types.Float | Types.Str | Types.Byte | Types.Chr | Types.Bool | Types.Unit ->
             Hashtbl.replace named param (Value.Name (Types.string_of_ty ty))
           | Types.Named (n, []) | Types.Sum (n, []) -> Hashtbl.replace named param (Value.Name n)
           | (Types.Named (n, args) | Types.Sum (n, args)) when Hashtbl.mem w.generic_decls n && Types.closed ty ->
             Hashtbl.replace named param (Value.Name (type_copy w n args))
           | _ -> ())
        | _ -> ())
      key;
    let body =
      if Hashtbl.length named = 0
      then body
      else
        tblock (meta_bodies (substitute_all named)) S.empty body
    in
    let body = renamed_locals d name body in
    i.source <- body;
    (* Reached from a meta block, its quotes and gens are lowered as the
       block's are. One that has any runs only inside a meta block. *)
    let body =
      if not !Typecheck.in_meta
      then body
      else (
        let captured () = Hashtbl.length w.context.table + Hashtbl.length w.context.codes in
        let before = captured () in
        let names =
          List.map (fun (p : Ast.static_param) -> p.Ast.sp_name) d.Typecheck.wd_sig.Ast.static_params
          @ param_names d.Typecheck.wd_params
        in
        let lowered = lower w.context ~visible:(visible w) ~returns:(returns w) ~params:names body in
        i.quoting <- captured () > before;
        lowered)
    in
    let previous = w.current
    and frame = w.meta_frame in
    w.current <- Some i;
    w.meta_frame <- None;
    (match
       Fun.protect
         ~finally:(fun () ->
           w.current <- previous;
           w.meta_frame <- frame)
         (fun () ->
           Typecheck.check_instance
             ~registry:w.registry
             d
             key
             ~name
             ~body
             ~started:(fun ty written ->
               i.ty <- ty;
               i.ret_written <- written))
     with
     | checked ->
       i.checked <- Some checked;
       i.ty <- checked.Ast.ann;
       i.state <- Done;
       if not d.Typecheck.wd_local then w.finished <- i :: w.finished
     | exception Typecheck.Located e ->
       i.state <- Failed_instance;
       Typecheck.leave_open i.ty;
       let s = session w in
       s.Typecheck.Session.errors := e :: !(s.Typecheck.Session.errors));
    i

and instance w span d key = view (made w span d key)

(* What `declof` shows of an instance: its body as checked, each meta block
   replaced by what it generated, and its signature at the key, under the
   declaration's own name: an instance's is mangled. Only a simple
   type name is written into the body, where a parameter may also stand as a
   value: `T.zero()`. *)
and surface w (i : instance) : Ast.stmt =
  let d = i.decl in
  let span = d.Typecheck.wd_span in
  let written = Hashtbl.create 4
  and named = Hashtbl.create 4 in
  List.iter
    (fun (param, arg) ->
      match arg with
      | Key.Type ty ->
        let t = Splice.type_expr_of span ty in
        Hashtbl.replace written param (Syntax.type_expr t);
        (match t.Ast.it, ty with
         | Ast.Ty_name n, _ -> Hashtbl.replace named param (Value.Name n)
         | _, (Types.Named (n, args) | Types.Sum (n, args)) when Hashtbl.mem w.generic_decls n && Types.closed ty ->
           Hashtbl.replace named param (Value.Name (type_copy w n args))
         | _ -> ())
      | Key.Value _ | Key.Row _ -> ())
    i.key;
  let h = ref quiet in
  h
  := { quiet with
       meta =
         (fun scope (s : Ast.stmt) ->
           match s.Ast.it with
           | `Meta body ->
             (match List.assq_opt body i.generated with
              | Some (Spliced_stmts generated) -> tblock !h scope generated
              | _ -> [ s ])
           | _ -> [ s ])
     ; meta_expr =
         (fun scope (e : Ast.expr) ->
           match e.Ast.it with
           | `Meta_expr body ->
             (match List.assq_opt body i.generated with
              | Some (Spliced_expr generated) -> texpr !h scope generated
              | _ -> e)
           | _ -> e)
     };
  let body = substitute_all named (tblock !h S.empty i.source) in
  let _, _, _, (param, signature, _) = substitution written in
  (* A parameter standing in a row is written back as the effects it is at. *)
  let rows =
    List.filter_map
      (fun (param, arg) ->
        match arg with
        | Key.Row r -> Some (param, r)
        | _ -> None)
      i.key
  in
  let rec effects (entries : (string * Ast.type_expr list) list) =
    List.concat_map
      (fun (label, args) ->
        match List.assoc_opt label rows with
        | Some (r : Types.row) ->
          List.map (fun (l, args) -> l, List.map (Splice.type_expr_of span) args) r.Types.labels
        | None -> [ label, List.map expanded args ])
      entries
  and expanded (t : Ast.type_expr) =
    let it =
      match t.Ast.it with
      | Ast.Ty_fn (args, ret, row) -> Ast.Ty_fn (List.map expanded args, expanded ret, effects row)
      | Ast.Ty_app (n, args) -> Ast.Ty_app (n, List.map expanded args)
      | Ast.Ty_tuple items -> Ast.Ty_tuple (List.map expanded items)
      | Ast.Ty_row row -> Ast.Ty_row (effects row)
      | it -> it
    in
    { t with Ast.it }
  in
  (* A parameter written with no type, a method's `self` among them, has the
     one the instance settled. *)
  let settled =
    match Types.repr i.ty with
    | Types.IFn (params, _, _) -> params
    | _ -> []
  in
  let param index p =
    let p : Ast.param = param p in
    match p.Ast.ty, List.nth_opt settled index with
    | None, Some t ->
      let t = Types.resolve t in
      if Typecheck.holds_generic t then p else { p with Ast.ty = Some (Splice.type_expr_of span t) }
    | _ -> { p with Ast.ty = Option.map expanded p.Ast.ty }
  in
  let sg = signature { d.Typecheck.wd_sig with Ast.static_params = [] } in
  let sg = { sg with Ast.ret = Option.map expanded sg.Ast.ret; row = Option.map effects sg.Ast.row } in
  Ast.at span (`Fn (d.Typecheck.wd_name, List.mapi param d.Typecheck.wd_params, sg, body))

and declared_instance w span (d : Typecheck.walk_decl) key =
  let i = made ~use:false w span d key in
  if i.state = Walking
  then
    fail
      span
      "'%s' is still being metaprocessed, so declof cannot see it yet."
      (Typecheck.shown_name d.Typecheck.wd_name);
  surface w i

(* A type, trait or effect as written; a comptime one at arguments is the copy
   they make. *)
and declared_type w span name (static_args : Ast.expr Ast.static_arg list option) =
  wake w name;
  let name =
    match static_args with
    | None -> name
    | Some args ->
      (match Hashtbl.find_opt w.comptime_types name, Hashtbl.find_opt w.comptime_traits name with
       | Some tt, _ -> instantiate_type w tt args span
       | None, Some tr ->
         let types =
           List.map
             (function
               | Ast.St_type t -> t
               | Ast.St_value { Ast.it = `Var n; span; _ } -> Ast.at span (Ast.Ty_name n)
               | Ast.St_value v -> fail v.Ast.span "'%s' takes a type here, not a value." name)
             args
         in
         fst (instantiate_trait w tr types ~open_params:[] span)
       | None, None when Hashtbl.mem w.generic_decls name -> written_copy w span name args
       | None, None -> fail span "'%s' takes no static arguments here." (Typecheck.shown_name name))
  in
  match Hashtbl.find_opt Types.copies name with
  | Some _ -> Option.get (copy_decl w name)
  | None ->
  match List.find_opt (fun s -> List.mem name (declared_of s)) w.types, Hashtbl.find_opt w.comptime_traits name with
  | Some s, _ -> s
  | None, Some tr ->
    let decl = Ast.at tr.tr_span (`Trait_decl (tr.tr_name, tr.tr_params, tr.tr_body)) in
    Ast.at tr.tr_span (`Trait_members (decl, tr.tr_metas))
  | None, None -> fail span "'%s' is not a declaration." (Typecheck.shown_name name)

and declared_by_name w span name =
  wake w name;
  match Typecheck.decl_of (session w).Typecheck.Session.env name with
  | Some d ->
    if d.Typecheck.wd_vars <> [] || d.Typecheck.wd_values <> []
    then
      fail
        span
        "'%s' takes static parameters, so declof needs its key written: declof(%s<…>)."
        (Typecheck.shown_name name)
        (Typecheck.shown_name name);
    declared_instance w span d []
  | None -> declared_type w span name None

(* The instance a callee of processed code reaches, found from its type, and
   the name of that instance's key. *)
and declared_at w span ~at name ty =
  wake w name;
  match Typecheck.instance_at span ~at name ty with
  | Some (d, key) -> lazy (declared_instance w span d key), d.Typecheck.wd_name ^ Key.show key
  | None -> lazy (declared_type w span name None), name

(* A named handler's method as its impl writes it, for a transform to make
   taking control as if it were written as an arm. *)
and named_method w span handler short =
  match Hashtbl.find_opt Typecheck.named_handlers handler with
  | None -> None
  | Some (name, label) ->
    let entries = Registry.method_entries w.registry name short in
    let entry =
      match List.filter (fun (e : Registry.method_entry) -> e.Registry.trait = Some label) entries, entries with
      | [ e ], _ | [], [ e ] -> Some e
      | _ -> None
    in
    Option.bind entry (fun (e : Registry.method_entry) ->
      Option.map
        (fun (d : Typecheck.walk_decl) ->
          Ast.at
            span
            (`Fn
              ( short
              , List.map (fun (p : Ast.param) -> { p with Ast.ty = None }) d.Typecheck.wd_params
              , { d.Typecheck.wd_sig with Ast.static_params = [] }
              , d.Typecheck.wd_body )))
        (Option.bind !Typecheck.top_env (fun env -> Typecheck.decl_of env e.Registry.mangled)))

(* A type declared in a body is renamed after its owner, and so after each
   instance of it: two instances at different keys declare two types. *)
and renamed_locals (d : Typecheck.walk_decl) name body =
  if String.equal name d.Typecheck.wd_name
  then body
  else (
    let prefix = d.Typecheck.wd_name ^ "#" in
    let renames = Hashtbl.create 4 in
    let rec note (s : Ast.stmt) =
      match s.Ast.it with
      | `Type_decl (n, _, _) when starts_with ~prefix n ->
        Hashtbl.replace
          renames
          n
          (Value.Name (name ^ "#" ^ String.sub n (String.length prefix) (String.length n - String.length prefix)))
      | `Attributed (_, inner) -> note inner
      | `Block b -> List.iter note b
      | _ -> ()
    in
    List.iter note body;
    if Hashtbl.length renames = 0 then body else substitute_all renames body)

and meta_stmt w ~statics ~runtime ~outer (s : Ast.stmt) : Splice.fragment list =
  match s.Ast.it with
  | `Meta body ->
    w.generator <- "meta block";
    run_meta w ~span:s.Ast.span ~statics ~runtime ~outer body
  | `Derive (traits, target) -> derive w s traits target
  | _ -> [ Splice.Stmt s ]

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
    Hashtbl.mem w.fns (deriver t)
  in
  (* `Eq` is the compiler's to derive unless a program wrote its own. *)
  let compiler t = String.equal t Core.eq && not (has_deriver t) in
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
      let produced = run_meta w ~span:s.Ast.span ~statics:[] ~runtime:S.empty ~outer:[] calls in
      w.generator <- "derive";
      produced
  in
  List.map (fun s -> Splice.Stmt s) derived @ generated

and run_meta w ~span ~statics ~runtime ~outer body =
  let scope = List.fold_left (fun acc (n, _) -> S.add n acc) S.empty statics in
  ignore
    (tblock
       { quiet with
         static_call =
           (fun scope e ->
             (match e.Ast.it with
              | `Static_call ({ Ast.it = `Var name; _ }, static_args, _) ->
                List.iter
                  (fun (a : Ast.expr Ast.static_arg) ->
                    let reads =
                      match a with
                      | Ast.St_value v -> reads_of v
                      | Ast.St_type { Ast.it = Ast.Ty_name n; _ } -> S.singleton n
                      | Ast.St_type _ -> S.empty
                    in
                    match S.find_first_opt (fun n -> S.mem n scope) reads with
                    | Some value when Option.is_some (instance_decl w name) ->
                      fail
                        e.Ast.span
                        "'%s' cannot be instantiated from inside a meta block: '%s' is a value \
                         there. Write the call inside a gen."
                        name
                        value
                    | _ -> ())
                  static_args
              | _ -> ());
             e)
       ; meta = (fun _ s -> [ s ])
       ; gen = (fun _ s -> [ s ])
       }
       scope
       body);
  let lowered = lower w.context ~visible:(visible w) ~returns:(returns w) ~params:(List.map fst statics) body in
  let bindings =
    List.map (fun (n, (v : Ast.expr)) -> Ast.at v.Ast.span (`Var_decl (n, None, Some v))) statics
  in
  (* Run as a root statement is, so what it performs is handled the same way.
     Not one the root's own body reaches: its runs need meta blocks of their
     own -- the transform, an `EffectHandler` instance -- and one put under the
     root would need the root finished first. *)
  let at it = Ast.at span it in
  let root_walking =
    match w.current with
    | Some i -> Ast.is_root i.decl.Typecheck.wd_name
    | None -> false
  in
  let block =
    match w.root with
    | Some root when not root_walking ->
      let main = at (`Lambda ([], { Ast.ret = None; row = None; static_params = [] }, [ at (`Block (bindings @ lowered)) ])) in
      at (`Expr (at (`Call (at (`Var root), [ main ]))))
    | _ -> at (`Block (bindings @ lowered))
  in
  let s = session w in
  let runtime = List.fold_left (Fun.flip S.add) runtime (hidden w) in
  printed w;
  let frame = { outer = List.map fst statics @ outer; reached = S.empty } in
  let previous_frame = w.meta_frame
  and previous_current = w.current
  and previous_finished = w.finished in
  w.meta_frame <- Some frame;
  w.current <- None;
  w.finished <- [];
  let reported = List.length !(s.Typecheck.Session.errors) in
  let failed (e : Typecheck.error) =
    Failed (explain { span = e.Typecheck.span; message = e.Typecheck.message } ~runtime ~outer)
  in
  let program =
    Fun.protect
      ~finally:(fun () ->
        w.meta_frame <- previous_frame;
        w.current <- previous_current;
        w.finished <- w.finished @ previous_finished)
      (fun () ->
        try
          let checked = Typecheck.Walk.meta s ~hidden:(hidden w) block in
          let processed = Typecheck.processed_block w.registry checked in
          drain w;
          (* What an instance it reached reported, it fails with: the block
             cannot run without that instance. *)
          let errors = !(s.Typecheck.Session.errors) in
          let fresh = List.length errors - reported in
          if fresh > 0 then raise (failed (List.nth errors (fresh - 1)));
          List.rev w.type_level @ reached w frame.reached, processed
        with
        | Typecheck.Located e -> raise (failed e))
  in
  let collected = ref [] in
  let previous = !(w.context.current) in
  w.context.current := collected;
  (try
     run
       ~out:w.context.out
       ~codes:w.context.codes
       ~emit:(emit_into w.context)
       ~emit_value:(emit_value w.context)
       ~capture:(fun _ -> ())
       ~reflect:(fun prefix shown -> !module_hook w prefix shown)
       ~declof:(declared_by_name w)
       ~declof_call:(declared_at w)
       ~named_method:(named_method w)
       ~declare:(fun d -> !register_hook w d)
       ~remembered:w.remembered
       program
   with
   | Failed e ->
     w.context.current := previous;
     raise (Failed (explain e ~runtime ~outer)));
  w.context.current := previous;
  List.rev !collected

(* The processed bodies of the instances a meta block names, and of those they
   name, and every printer: the interpreter finds a `Display` or `Debug` method
   by name wherever a value is written. *)
and reached w names =
  let seen = Hashtbl.create 32 in
  let out = ref [] in
  let rec visit name =
    if not (Hashtbl.mem seen name)
    then (
      Hashtbl.replace seen name ();
      match Hashtbl.find_opt w.by_name name with
      | None -> ()
      | Some i ->
        (match i.state with
         | Walking ->
           fail
             i.decl.Typecheck.wd_span
             "'%s' is still being metaprocessed, so a meta block cannot call it yet."
             (Typecheck.shown_name i.decl.Typecheck.wd_name)
         | Failed_instance -> ()
         | Done ->
           let processed = processed_of w i in
           if not i.decl.Typecheck.wd_local then out := processed :: !out;
           S.iter visit i.deps))
  in
  S.iter visit names;
  Hashtbl.iter
    (fun name i -> if i.state = Done && is_printer i.decl then visit name)
    w.by_name;
  List.concat (List.rev !out)

(* The printer finds these by name wherever a value is written, so each is made
   whether or not anything calls it. *)
and printed w =
  let s = session w in
  (* Made is not used: [pruned] keeps one only for a type the program builds. *)
  let rooted = w.rooted in
  Fun.protect ~finally:(fun () -> w.rooted <- rooted) @@ fun () ->
  List.iter
    (fun impl ->
      match impl_parts impl with
      | Some ((Some (trait, _) as written), type_name, _, body)
        when String.equal trait Core.display || String.equal trait Core.debug ->
        List.iter
          (fun (m : (Ast.stmt, unit) Ast.method_def) ->
            match
              Typecheck.decl_of s.Typecheck.Session.env (Ast.impl_method_name written type_name m.Ast.md_name)
            with
            | Some d when not (Hashtbl.mem w.by_decl d.Typecheck.wd_id) ->
              let key =
                List.map
                  (fun (name, var) ->
                    match Types.repr var with
                    | Types.IVar { contents = Types.Unbound _ } -> name, Key.Type Types.Unit
                    | fixed -> name, Key.Type (Types.resolve fixed))
                  d.Typecheck.wd_vars
              in
              let previous = w.current in
              w.current <- None;
              (try
                 Fun.protect
                   ~finally:(fun () -> w.current <- previous)
                   (fun () -> ignore (instance w d.Typecheck.wd_span d key))
               with
               | Typecheck.Located e -> s.Typecheck.Session.errors := e :: !(s.Typecheck.Session.errors))
            | _ -> ())
          body.Ast.ib_methods
      | _ -> ())
    (List.rev w.impls)

and instance_decl w name =
  match w.session with
  | None -> None
  | Some s ->
    (match Typecheck.decl_of s.Typecheck.Session.env name with
     | Some d when d.Typecheck.wd_values <> [] -> Some d
     | _ -> None)

and generic_new w (e : Ast.expr) =
  match e.Ast.it with
  | `New_generic (name, static_args, fields) ->
    wake w name;
    (match Hashtbl.find_opt w.comptime_types name with
     | Some tt -> { e with Ast.it = `New (instantiate_type w tt static_args e.Ast.span, fields) }
     | None ->
       if Hashtbl.mem w.generic_decls name then ignore (written_copy ~strict:false w e.Ast.span name static_args);
       e)
  | `New (name, _) ->
    (match Hashtbl.find_opt w.comptime_types name with
     | Some tt ->
       fail
         e.Ast.span
         "'%s' %s, so its arguments must be written: %s<…> { … }."
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
    let bound =
      List.map (fun (n, (v : Ast.expr)) -> Ast.at v.Ast.span (`Var_decl (n, None, Some v))) values
    in
    tblock (meta_bodies (fun inner -> bound @ inner)) S.empty body

(* A plain generic type at a key: the copy its uses name, made the first time
   one reaches it. *)
and type_copy w base (args : Types.ty list) =
  let shown = Types.string_of_ty (Types.Named (base, args)) in
  match Hashtbl.find_opt w.generic_decls base with
  | None -> shown
  | Some g ->
    let key =
      Key.show
        (List.mapi
           (fun i a ->
             (match List.nth_opt g.tt_params i with
              | Some p -> p.Ast.tp_name
              | None -> string_of_int i),
             Key.Type a)
           args)
    in
    (match Hashtbl.find_opt w.cache (g.tt_id, key) with
     | Some (Copy copy) -> copy
     | Some (Function _) | None ->
       Hashtbl.replace w.cache (g.tt_id, key) (Copy shown);
       Hashtbl.replace Types.copies shown (base, args);
       w.copies_made <- shown :: w.copies_made;
       shown)

(* A plain generic type at written arguments, as `Box<Int> { … }` or
   `declof(Box<Int>)` names it. *)
and written_copy ?(strict = true) w span name (static_args : Ast.expr Ast.static_arg list) =
  let types =
    List.map
      (function
        | Ast.St_type t -> t
        | Ast.St_value { Ast.it = `Var n; span; _ } -> Ast.at span (Ast.Ty_name n)
        | Ast.St_value v -> fail v.Ast.span "'%s' takes a type here, not a value." (Typecheck.shown_name name))
      static_args
  in
  let written = Ast.at span (Ast.Ty_app (name, types)) in
  let ty =
    try Types.resolve (Typecheck.infer_ty_of_annotation written) with
    | Typecheck.Located e -> fail e.Typecheck.span "%s" e.Typecheck.message
  in
  match ty with
  | (Types.Named (n, args) | Types.Sum (n, args)) when Types.closed ty -> type_copy w n args
  | _ when not strict -> name
  | _ -> fail span "'%s' is not settled here." (Printer.string_of_type_expr written)

(* A written type naming each closed use of a generic type by its copy. *)
and renamed_type ?(reach = ignore) w (t : Ast.type_expr) : Ast.type_expr =
  let renamed = renamed_type ~reach w in
  let it =
    match t.Ast.it with
    | Ast.Ty_app (n, args) when Hashtbl.mem Types.generic_types n ->
      let settled =
        try Some (Types.resolve (Typecheck.infer_ty_of_annotation t)) with
        | _ -> None
      in
      (match settled with
       | Some ty when Types.closed ty ->
         (match Types.copied ~copy:(fun n a -> reach (type_copy w n a)) ty with
          | Types.Named (c, []) | Types.Sum (c, []) -> Ast.Ty_name c
          | _ -> Ast.Ty_app (n, List.map renamed args))
       | _ -> Ast.Ty_app (n, List.map renamed args))
    | Ast.Ty_app (n, args) -> Ast.Ty_app (n, List.map renamed args)
    | Ast.Ty_tuple items -> Ast.Ty_tuple (List.map renamed items)
    | Ast.Ty_record fields -> Ast.Ty_record (List.map (fun (l, t) -> l, renamed t) fields)
    | Ast.Ty_fn (ps, r, row) -> Ast.Ty_fn (List.map renamed ps, renamed r, row)
    | Ast.Ty_variadic t -> Ast.Ty_variadic (renamed t)
    | Ast.Ty_spread t -> Ast.Ty_spread (renamed t)
    | it -> it
  in
  { t with Ast.it }

(* A copy's declaration: the generic one at its arguments, every closed use of
   a generic type in it naming that type's copy. *)
and copy_decl ?(reach = ignore) w copy : Ast.stmt option =
  match Hashtbl.find_opt Types.copies copy with
  | None -> None
  | Some (base, args) ->
    Option.map
      (fun g ->
        let span = g.tt_decl.Ast.span in
        let written = Hashtbl.create 4 in
        List.iteri
          (fun i (p : Ast.type_param) ->
            match List.nth_opt args i with
            | Some a ->
              Hashtbl.replace written p.Ast.tp_name (Syntax.type_expr (Splice.type_expr_of span (Types.copied a)))
            | None -> ())
          g.tt_params;
        let decl = substitute written g.tt_decl in
        let renamed = renamed_type w ~reach in
        match decl.Ast.it with
        | `Type_decl (_, _, Ast.T_fields fields) ->
          Ast.at
            span
            (`Type_decl
              (copy, [], Ast.T_fields (List.map (fun (f : Ast.field) -> { f with Ast.f_ty = renamed f.Ast.f_ty }) fields)))
        | `Type_decl (_, _, Ast.T_variants variants) ->
          Ast.at
            span
            (`Type_decl
              ( copy
              , []
              , Ast.T_variants
                  (List.map
                     (fun (v : Ast.variant) ->
                       { v with
                         Ast.v_payload = Ast.map_payload renamed v.Ast.v_payload
                       ; v_result = Option.map renamed v.Ast.v_result
                       })
                     variants) ))
        | _ -> decl)
      (Hashtbl.find_opt w.generic_decls base)

(* A copy is named by what it was made from, `Buf<4>`, which is how a
   diagnostic or `typeof` shows it. Its meta blocks run as it is made, with its
   value arguments bound; its functions become its methods. *)
and instantiate_type w (tt : comptime_type) static_args span =
  let params = tt.tt_params in
  if List.length params <> List.length static_args
  then
    fail
      span
      "Type '%s' takes %d argument(s) but %d were given."
      tt.tt_name
      (List.length params)
      (List.length static_args);
  let values, types, shown, key =
    List.fold_left2
      (fun (values, types, shown, key) (p : Ast.type_param) arg ->
        let name = p.Ast.tp_name in
        if Option.is_some p.Ast.tp_ty
        then (
          let v, written = static_value w tt.tt_name arg in
          (name, v) :: values, types, Source.expr v :: shown, (name, Key.Value (v, written)) :: key)
        else (
          let t =
            match arg with
            | Ast.St_type t -> t
            | Ast.St_value { Ast.it = `Var n; span; _ } -> Ast.at span (Ast.Ty_name n)
            | Ast.St_value v -> fail v.Ast.span "'%s' takes a type here, not a value." tt.tt_name
          in
          let ty = Types.resolve (Typecheck.infer_ty_of_annotation t) in
          values, (name, type_key t) :: types, type_key t :: shown, (name, Key.Type ty) :: key))
      ([], [], [], [])
      params
      static_args
  in
  let key = Key.show (List.rev key) in
  match Hashtbl.find_opt w.cache (tt.tt_id, key) with
  | Some (Copy copy) -> copy
  | Some (Function _) | None ->
    let copy = tt.tt_name ^ "<" ^ String.concat ", " (List.rev shown) ^ ">" in
    Hashtbl.replace w.cache (tt.tt_id, key) (Copy copy);
    (
    let values = List.rev values in
    let named = Hashtbl.create 4 in
    List.iter (fun (param, ty) -> Hashtbl.replace named param (Value.Name ty)) types;
    List.iter
      (fun (p : Ast.type_param) ->
        match p.Ast.tp_ty, List.assoc_opt p.Ast.tp_name values with
        | Some ty, Some v -> check_static w named ty v
        | _ -> ())
      params;
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
            (fun g -> functions := g :: !functions)
            (Splice.fit Splice.Type_body m.Ast.span (meta_stmt w ~statics:values ~runtime:S.empty ~outer:[] m))
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
            ; md_body =
                with_values
                  values
                  (List.map
                     (substitute named)
                     (bind_values
                        (List.filter_map
                           (fun (p : Ast.type_param) ->
                             Option.map
                               (fun v -> p.Ast.tp_name, p.Ast.tp_ty, v)
                               (List.assoc_opt p.Ast.tp_name values))
                           tt.tt_params)
                        body))
            ; md_ann = ()
            ; md_attrs = fn_attrs f
            })
          functions
      in
      !register_hook
        w
        (Ast.at span (`Impl_decl (None, copy, [], { Ast.ib_assoc = []; ib_methods = methods }))));
    copy

(* An argument naming one of the impl's own parameters leaves its slot open:
   the instance keeps the trait's parameter there, `EffectHandler<Effect, _>`,
   and the impl passes its own. A generated signature names a parameter by its
   string, so the bound ones are written in after the blocks run as well as
   before. *)
and instantiate_trait w (tr : comptime_trait) (args : Ast.type_expr list) ~open_params span =
  if List.length args <> List.length tr.tr_params
  then
    fail
      span
      "Trait '%s' takes %d type argument(s) but %d were given."
      tr.tr_name
      (List.length tr.tr_params)
      (List.length args);
  let slots =
    List.map2
      (fun param (arg : Ast.type_expr) ->
        match arg.Ast.it with
        | Ast.Ty_name n when List.mem n open_params -> param, None
        | _ -> param, Some arg)
      tr.tr_params
      args
  in
  let open_args = List.filter_map (fun ((_, slot), arg) -> if slot = None then Some arg else None) (List.combine slots args) in
  let key =
    String.concat
      ","
      (List.map
         (fun (_, slot) ->
           match slot with
           | None -> "_"
           | Some arg -> Types.string_of_ty (Types.resolve (Typecheck.infer_ty_of_annotation arg)))
         slots)
  in
  match Hashtbl.find_opt w.cache (tr.tr_id, key) with
  | Some (Copy name) -> name, open_args
  | Some (Function _) | None ->
    let shown = List.map (fun (_, slot) -> Option.fold ~none:"_" ~some:type_key slot) slots in
    let name = if shown = [] then tr.tr_name else tr.tr_name ^ "<" ^ String.concat ", " shown ^ ">" in
    Hashtbl.replace w.cache (tr.tr_id, key) (Copy name);
    Hashtbl.replace Typecheck.trait_instances name (tr.tr_name, List.map snd slots);
    let named = Hashtbl.create 4
    and written = Hashtbl.create 4 in
    List.iter
      (fun (param, slot) ->
        match slot with
        | Some ({ Ast.it = Ast.Ty_name n; _ } as arg) ->
          Hashtbl.replace named param (Value.Name n);
          Hashtbl.replace written param (Syntax.type_expr arg)
        | Some arg -> Hashtbl.replace written param (Syntax.type_expr arg)
        | None -> ())
      slots;
    let generated =
      List.concat_map
        (fun (m : Ast.stmt) ->
          let m = substitute named m in
          List.map
            (fun g -> m.Ast.span, g)
            (Splice.fit Splice.Trait_body m.Ast.span (meta_stmt w ~statics:[] ~runtime:S.empty ~outer:[] m)))
        tr.tr_metas
    in
    let seen = Hashtbl.create 8 in
    List.iter (fun (m : Ast.method_sig) -> Hashtbl.replace seen m.Ast.ms_name ()) tr.tr_body.Ast.tb_methods;
    List.iter
      (fun (at, (m : Ast.method_sig)) ->
        if Hashtbl.mem seen m.Ast.ms_name then fail at "Trait '%s' already has a method '%s'." tr.tr_name m.Ast.ms_name;
        Hashtbl.replace seen m.Ast.ms_name ())
      generated;
    let body =
      { tr.tr_body with
        Ast.tb_super =
          List.map (fun (t, args) -> t, List.map (substitute_type written) args) tr.tr_body.Ast.tb_super
      ; tb_methods = List.map (substitute_sig written) (tr.tr_body.Ast.tb_methods @ List.map snd generated)
      }
    in
    let decl = Ast.at tr.tr_span (`Trait_decl (name, List.filter_map (fun (p, slot) -> if slot = None then Some p else None) slots, body)) in
    !register_hook w (if tr.tr_attrs = [] then decl else Ast.at tr.tr_span (`Attributed (tr.tr_attrs, decl)));
    name, open_args

(* Nothing else checks an argument against its parameter: the copy's body only
   ever sees the value written in where the parameter was read. *)
and check_static w named (declared : Ast.type_expr) (v : Ast.expr) =
  let primitive =
    match declared.Ast.it, v.Ast.it with
    | Ast.Ty_name "Int", `Int _
    | Ast.Ty_name "Float", `Float _
    | Ast.Ty_name "String", `Str _
    | Ast.Ty_name "Char", `Char _
    | Ast.Ty_name "Bool", `Bool _ -> true
    | _ -> false
  in
  if not primitive
  then (
    let probe =
      substitute
        named
        (Ast.at v.Ast.span (`Var_decl (Ast.generated [ "static"; "argument" ], Some declared, Some v)))
    in
    checks w probe)

(* A module's top-level meta blocks run once, the first time the walk asks the
   module for a name. What they generate is the module's, so it takes the
   module's prefix; a statement they generate is dropped, as the module's own
   statements are. *)
and wake w name =
  if Hashtbl.length w.units > 0
  then (
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
            let declarations =
              Splice.fit Splice.Module s.Ast.span (meta_stmt w ~statics:[] ~runtime:S.empty ~outer:[] inner)
            in
            let owned = Hashtbl.create 4 in
            List.iter
              (fun d ->
                List.iter
                  (fun n -> if not (starts_with ~prefix n) then Hashtbl.replace owned n (Value.Name (prefix ^ n)))
                  (declared_of d))
              declarations;
            List.iter (fun d -> !register_hook w (substitute owned d)) declarations)
          blocks)
      ready)

(* ---- the program ---- *)

let rec declared_names (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) | `Type_decl (name, _, _) -> [ name ]
  | `Trait_decl (name, _, _) -> [ name ]
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

let rec declaration_kind (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn _ -> Some "Function"
  | `Type_decl _ | `Type_members _ -> Some "Type"
  | `Trait_decl _ -> Some "Trait"
  | `Attributed (_, inner) -> declaration_kind inner
  | _ -> None

let note_declared w (s : Ast.stmt) =
  if Option.is_some (declaration_kind s) then w.declared <- s :: w.declared
(* What `moduleof` answers: the module's top-level meta run first, so what it
   generates is listed with what was written. *)
let module_record w prefix shown =
  (* Any name under the prefix wakes the module, and no identifier holds a `?`. *)
  wake w (prefix ^ "?");
  let owned name =
    String.length name > String.length prefix
    && starts_with ~prefix name
    && not (String.contains (String.sub name (String.length prefix) (String.length name - String.length prefix)) '#')
  in
  let rec name_of (s : Ast.stmt) =
    match s.Ast.it with
    | `Fn (n, _, _, _) | `Type_decl (n, _, _) | `Trait_decl (n, _, _) -> Some n
    | `Type_members (decl, _) -> name_of decl
    | `Attributed (_, inner) -> name_of inner
    | _ -> None
  in
  let rec attrs_of (s : Ast.stmt) =
    match s.Ast.it with
    | `Attributed (list, inner) -> list @ attrs_of inner
    | _ -> []
  in
  let attr_arg (a : Ast.attr_arg) =
    let label, v =
      match a with
      | Ast.A_str t -> "Str", Value.Str (Utf8.decode t)
      | Ast.A_int n -> "Int", Value.Int n
      | Ast.A_float f -> "Float", Value.Float f
      | Ast.A_bool b -> "Bool", Value.Bool b
    in
    Value.Variant (Some Core.attr_arg, label, [ "0", v ])
  in
  (* Where the declaration itself starts, past any attribute above it. *)
  let rec unwrapped (s : Ast.stmt) =
    match s.Ast.it with
    | `Attributed (_, inner) -> unwrapped inner
    | _ -> s
  in
  let declaration (s : Ast.stmt) name kind =
    let attrs = attrs_of s in
    let doc, written = List.partition (fun (a : Ast.attr) -> String.equal a.Ast.a_name Ast.doc_attr) attrs in
    let doc =
      match doc with
      | { Ast.a_args = [ Ast.A_str text ]; _ } :: _ -> text
      | _ -> ""
    in
    Value.Record
      ( Some (Core.reflect "Declaration")
      , [ "name", ref (Value.Name name)
        ; "kind", ref (Value.Variant (Some (Core.reflect "DeclarationKind"), kind, []))
        ; "doc", ref (Value.Str (Utf8.decode doc))
        ; ( "params"
          , ref
              (Value.Array
                 (Array.of_list
                    (match fn_parts s with
                     | Some (_, params, _, _) -> List.map (fun (p : Ast.param) -> Value.Name p.Ast.name) params
                     | None -> []))) )
        ; "span", ref (Value.Span (unwrapped s).Ast.span)
        ; ( "attrs"
          , ref
              (Value.Array
                 (Array.of_list
                    (List.map
                       (fun (a : Ast.attr) ->
                         Value.Record
                           ( Some Core.attr
                           , [ "name", ref (Value.Name a.Ast.a_name)
                             ; "args", ref (Value.Array (Array.of_list (List.map attr_arg a.Ast.a_args)))
                             ] ))
                       written))) )
        ] )
  in
  let seen = Hashtbl.create 16 in
  let listed =
    List.filter_map
      (fun s ->
        match name_of s, declaration_kind s with
        | Some name, Some kind when owned name && not (Hashtbl.mem seen name) ->
          Hashtbl.replace seen name ();
          Some (declaration s name kind)
        | _ -> None)
      (List.rev w.declared)
  in
  Value.Variant
    ( Some (Core.reflect "Module")
    , "File"
    , [ "0", Value.Name shown; "1", Value.Array (Array.of_list listed) ] )

let () = module_hook := module_record

let rec is_type_level (s : Ast.stmt) =
  match s.Ast.it with
  | `Type_decl _ | `Trait_decl _ -> true
  | `Attributed (_, inner) -> is_type_level inner
  | _ -> false

(* A trait written with a doc comment or an attribute is an `Attributed` around
   the declaration, and the trait table is what tells `<T: Ord>` from `<n: Int>`
   -- so missing one turns every bound naming it into a static value parameter
   and the walk starts demanding arguments nobody wrote. *)
let rec trait_declared (s : Ast.stmt) =
  match s.Ast.it with
  | `Trait_decl (name, _, _) -> Some name
  | `Trait_members (decl, _) -> trait_declared decl
  | `Attributed (_, inner) -> trait_declared inner
  | _ -> None

let declared_traits (p : Ast.program) =
  let found = Hashtbl.create 16 in
  List.iter
    (fun s -> Option.iter (fun name -> Hashtbl.replace found name ()) (trait_declared s))
    p;
  found

let rec note_type w (s : Ast.stmt) =
  match s.Ast.it with
  | `Type_decl (name, _, _) -> Hashtbl.replace w.type_names name ()
  | `Attributed (_, inner) -> note_type w inner
  | _ -> ()

let rec trait_members (s : Ast.stmt) =
  match s.Ast.it with
  | `Trait_members (({ Ast.it = `Trait_decl (name, params, body); _ } as decl), metas) ->
    Some ([], decl, name, params, body, metas)
  | `Attributed (attrs, inner) ->
    Option.map
      (fun (more, decl, name, params, body, metas) -> attrs @ more, decl, name, params, body, metas)
      (trait_members inner)
  | _ -> None

(* Nothing is checked until an impl names an instance, so the trait itself is
   declared only by its instances. *)
let note_trait w (s : Ast.stmt) =
  match trait_members s with
  | None -> false
  | Some (attrs, decl, name, params, body, metas) ->
    incr Typecheck.walk_decl_count;
    Hashtbl.replace
      w.comptime_traits
      name
      { tr_id = !Typecheck.walk_decl_count
      ; tr_name = name
      ; tr_params = params
      ; tr_body = body
      ; tr_metas = metas
      ; tr_attrs = attrs
      ; tr_span = decl.Ast.span
      };
    Hashtbl.replace w.traits name ();
    Hashtbl.replace w.known name ();
    note_declared w (if attrs = [] then decl else { s with Ast.it = `Attributed (attrs, decl) });
    true

let names_comptime_trait w (s : Ast.stmt) =
  match impl_parts s with
  | Some (Some (trait, _), _, _, _) -> Hashtbl.mem w.comptime_traits trait
  | _ -> false

let rec trait_instance w (s : Ast.stmt) =
  match s.Ast.it with
  | `Impl_decl (Some (trait, args), ty, params, body) ->
    (match Hashtbl.find_opt w.comptime_traits trait with
     | Some tr ->
       let open_params = List.map (fun (p : Ast.type_param) -> p.Ast.tp_name) params in
       let instance, args = instantiate_trait w tr args ~open_params s.Ast.span in
       { s with Ast.it = `Impl_decl (Some (instance, args), ty, params, body) }
     | None -> s)
  | `Attributed (attrs, inner) -> { s with Ast.it = `Attributed (attrs, trait_instance w inner) }
  | _ -> s

(* Written or generated alike: a generated declaration quietly replacing one
   the program wrote is the mistake nobody would find. *)
let add_fn w name (s : Ast.stmt) =
  if Hashtbl.mem w.fns name
  then (
    match Ast.deriver_trait name with
    | Some trait -> fail s.Ast.span "Trait '%s' already has a deriver." trait
    | None -> fail s.Ast.span "'%s' is already declared." name);
  Hashtbl.replace w.fns name s

(* A parameter written without a type is a static parameter the function is
   generic in, so it is part of the key. An impl of a trait takes the trait's
   types instead. *)
let rec implicit (s : Ast.stmt) : Ast.stmt =
  let params_of span (params : Ast.param list) (sg : Ast.signature) =
    let added = ref [] in
    let params =
      List.map
        (fun (p : Ast.param) ->
          match p.Ast.ty with
          | Some _ -> p
          | None when String.equal p.Ast.name "self" -> p
          | None when String.starts_with ~prefix:(Ast.handler_param "") p.Ast.name -> p
          | None ->
            let name = Ast.implicit_param (List.length !added) in
            added := name :: !added;
            { p with Ast.ty = Some { Ast.it = Ast.Ty_name name; span; ann = () } })
        params
    in
    ( params
    , { sg with
        Ast.static_params =
          sg.Ast.static_params
          @ List.rev_map (fun name -> { Ast.sp_name = name; sp_ty = None; sp_pack = false }) !added
      } )
  in
  let it : Ast.stmt_kind =
    match s.Ast.it with
    | `Fn (name, params, sg, body) ->
      let params, sg = params_of s.Ast.span params sg in
      `Fn (name, params, sg, List.map implicit body)
    | `Attributed (attrs, inner) -> `Attributed (attrs, implicit inner)
    | `Block body -> `Block (List.map implicit body)
    | `If (c, t, e) -> `If (c, implicit t, Option.map implicit e)
    | `While (c, body) -> `While (c, implicit body)
    | `For_in (names, over, body) -> `For_in (names, over, implicit body)
    | `Match (subject, cases) -> `Match (subject, List.map (fun (p, b) -> p, List.map implicit b) cases)
    | `Defer inner -> `Defer (implicit inner)
    | `Impl_decl (trait, ty, params, impl) ->
      `Impl_decl
        ( trait
        , ty
        , params
        , { impl with
            Ast.ib_methods =
              List.map
                (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                  let md_params, md_signature =
                    if Option.is_some trait
                    then m.Ast.md_params, m.Ast.md_signature
                    else params_of s.Ast.span m.Ast.md_params m.Ast.md_signature
                  in
                  { m with Ast.md_params; md_signature; md_body = List.map implicit m.Ast.md_body })
                impl.Ast.ib_methods
          } )
    | other -> other
  in
  { s with Ast.it }
(* A type taking a value, or holding a meta block, is made per argument list;
   one whose members are only functions is a type and an impl, as it would be
   written by hand. *)
let types_of w (p : Ast.program) =
  let method_of (f : Ast.stmt) =
    match fn_parts f with
    | Some (name, params, sg, body) ->
      { Ast.md_name = name
      ; md_params = params
      ; md_signature = sg
      ; md_body = body
      ; md_ann = ()
      ; md_attrs = fn_attrs f
      }
    | None -> fail f.Ast.span "A type holds functions and meta blocks after its fields."
  in
  let comptime_type name params decl members =
    incr Typecheck.walk_decl_count;
    Hashtbl.replace
      w.comptime_types
      name
      { tt_id = !Typecheck.walk_decl_count; tt_name = name; tt_params = params; tt_decl = decl; tt_members = members };
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
          comptime_type name params decl members;
          [])
        else
          [ decl
          ; Ast.at
              s.Ast.span
              (`Impl_decl
                (None, name, params, { Ast.ib_assoc = []; ib_methods = List.map method_of members }))
          ]
      | `Type_decl (name, params, _) when takes_value params ->
        comptime_type name params s [];
        []
      | _ -> [ s ])
    p

(* A type declared in a body is renamed after its owner, and left where it is:
   once checked, a type is looked up by name, so two functions each declaring a
   `Temp` have to declare two names. *)
let rename_local_types (p : Ast.program) =
  let rec declared_type (s : Ast.stmt) =
    match s.Ast.it with
    | `Type_decl (name, _, _) -> Some name
    | `Attributed (_, inner) -> declared_type inner
    | _ -> None
  in
  let rec body owner (stmts : Ast.stmt list) =
    let renames = Hashtbl.create 4 in
    List.iter
      (fun (s : Ast.stmt) ->
        Option.iter
          (fun name -> Hashtbl.replace renames name (Value.Name (Ast.generated [ owner; name ])))
          (declared_type s))
      stmts;
    let rename (s : Ast.stmt) = if Hashtbl.length renames = 0 then s else substitute renames s in
    List.map (fun s -> stmt owner (rename s)) stmts
  and stmt owner (s : Ast.stmt) : Ast.stmt =
    let one = stmt owner in
    let it : Ast.stmt_kind =
      match s.Ast.it with
      | `Fn (name, params, sg, b) -> `Fn (name, params, sg, body (Ast.generated [ owner; name ]) b)
      | `Block b -> `Block (body owner b)
      | `If (c, t, e) -> `If (c, one t, Option.map one e)
      | `While (c, b) -> `While (c, one b)
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
  List.map
    (fun (s : Ast.stmt) ->
      match fn_parts s with
      | Some (name, _, _, b) -> with_body s (body name b)
      | None ->
        (match s.Ast.it with
         | `Impl_decl _ | `Attributed _ -> stmt "impl" s
         | _ -> s))
    p


let note_written w (s : Ast.stmt) =
  (match fn_parts s with
   | Some (name, _, _, _) -> add_fn w name s
   | None -> ());
  (match trait_declared s with
   | Some name -> Hashtbl.replace w.traits name ()
   | None -> ());
  if is_type_level s then w.types <- s :: w.types;
  if Option.is_some (impl_parts s) then w.impls <- s :: w.impls

let note_generic w (s : Ast.resolved_stmt) =
  match s.Ast.it with
  | `Type_decl (name, (_ :: _ as params), body) when not (Hashtbl.mem w.comptime_types name) ->
    incr Typecheck.walk_decl_count;
    Hashtbl.replace Types.generic_types name ();
    Hashtbl.replace
      w.generic_decls
      name
      { tt_id = !Typecheck.walk_decl_count
      ; tt_name = name
      ; tt_params = params
      ; tt_decl = Ast.at s.Ast.span (`Type_decl (name, params, body))
      ; tt_members = []
      }
  | _ -> ()

let check_type_level w (s : Ast.stmt) =
  if is_type_level s
  then
    Option.iter
      (fun checked ->
        let processed = Typecheck.processed_block w.registry checked in
        List.iter (note_generic w) processed;
        w.type_level <- List.rev_append processed w.type_level)
      (Typecheck.Walk.type_level (session w) s)

(* A declaration a meta block generated, from the point it was generated. *)
let register w (s : Ast.stmt) =
  if not (note_trait w s) then (
  let s = trait_instance w s in
  note_declared w s;
  note_type w s;
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
  let prepared = List.map implicit (types_of w [ s ]) in
  List.iter (note_written w) prepared;
  match w.session with
  | None -> ()
  | Some session ->
    Typecheck.Walk.declare session prepared;
    List.iter (check_type_level w) prepared)

let () = register_hook := register

let collect w (s : Ast.stmt) =
  note_declared w s;
  note_type w s;
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
  note_written w s

(* The types whose values a body builds. A `typeof` builds the reflection
   records. *)
let constructed (body : Ast.resolved_stmt list) =
  let found = ref S.empty in
  let note (ty : Types.ty) =
    match ty with
    | Types.Named (name, _) | Types.Sum (name, _) -> found := S.add name !found
    | _ -> ()
  in
  let rec expr (e : Ast.resolved_expr) =
    (match e.Ast.it with
     | `Record_lit _ | `Variant _ -> note e.Ast.ann
     | _ -> ());
    let _ : Ast.resolved_expr_kind =
      match e.Ast.it with
      | #Ast.lit as l -> l
      | #Ast.arrays as a -> (Ast.map_arrays expr a :> Ast.resolved_expr_kind)
      | #Ast.strings as a -> (Ast.map_strings expr a :> Ast.resolved_expr_kind)
      | #Ast.vars as a -> (Ast.map_vars expr a :> Ast.resolved_expr_kind)
      | #Ast.ops as a -> (Ast.map_ops expr a :> Ast.resolved_expr_kind)
      | #Ast.logic as a -> (Ast.map_logic expr a :> Ast.resolved_expr_kind)
      | #Ast.tuple as a -> (Ast.map_tuple expr a :> Ast.resolved_expr_kind)
      | #Ast.record as a -> (Ast.map_record expr a :> Ast.resolved_expr_kind)
      | #Ast.variant_lit as a -> (Ast.map_variant_lit expr a :> Ast.resolved_expr_kind)
      | #Ast.objects as a -> (Ast.map_object expr a :> Ast.resolved_expr_kind)
      | `Lambda (params, signature, body) -> `Lambda (params, signature, List.map stmt body)
    in
    e
  and stmt (s : Ast.resolved_stmt) =
    let _ : Ast.resolved_stmt_kind =
      match s.Ast.it with
      | #Ast.stmts as st -> (Ast.map_stmts expr stmt st :> Ast.resolved_stmt_kind)
      | #Ast.type_defs as t -> t
      | #Ast.matching as m -> (Ast.map_matching expr stmt m :> Ast.resolved_stmt_kind)
    in
    s
  in
  List.iter (fun s -> ignore (stmt s)) body;
  !found

(* The instances the roots reach through what each one names, in the order they
   were processed. The printer finds a `Display` or `Debug` method by name
   wherever a value is written, so one for each type a reached body builds is
   reached too. *)
let pruned w (roots : Ast.resolved_stmt list) =
  let marked = Hashtbl.create 64 in
  let printers = Hashtbl.create 16 in
  Hashtbl.iter
    (fun name i ->
      match i.decl.Typecheck.wd_impl with
      | Some (_, type_name, _) when is_printer i.decl && String.equal name i.decl.Typecheck.wd_name ->
        Hashtbl.add printers type_name name
      | _ -> ())
    w.by_name;
  let built = Hashtbl.create 32 in
  let rec build body =
    S.iter
      (fun ty ->
        if not (Hashtbl.mem built ty)
        then (
          Hashtbl.replace built ty ();
          List.iter visit (Hashtbl.find_all printers ty)))
      (constructed body)
  and visit name =
    if not (Hashtbl.mem marked name)
    then (
      Hashtbl.replace marked name ();
      match Hashtbl.find_opt w.by_name name with
      | Some ({ state = Done; _ } as i) ->
        S.iter visit i.deps;
        (* A local one is built inside its owner's body. *)
        Option.iter build i.processed
      | _ -> ())
  in
  S.iter visit w.rooted;
  build roots;
  List.concat_map
    (fun i ->
      if Hashtbl.mem marked i.name && not (i.decl.Typecheck.wd_local || i.quoting)
      then Option.get i.processed
      else [])
    (List.rev w.emitted)

(* A named handler's `@abort` method is written without its continuation, and
   is given one it never names: what it answers is handed back once the
   continuation is discontinued, so what that unwinds runs its cleanups. *)
let aborting_impls (p : Ast.program) : Ast.program =
  let aborting = Hashtbl.create 8 in
  let rec note (s : Ast.stmt) =
    match s.Ast.it with
    | `Trait_decl (name, _, body) ->
      List.iter
        (fun (m : Ast.method_sig) -> if Ast.aborts m.Ast.ms_attrs then Hashtbl.replace aborting (name, m.Ast.ms_name) (List.length m.Ast.ms_params))
        body.Ast.tb_methods
    | `Attributed (_, inner) -> note inner
    | _ -> ()
  in
  List.iter note p;
  let given eff (m : (Ast.stmt, unit) Ast.method_def) =
    match Hashtbl.find_opt aborting (eff, m.Ast.md_name) with
    | Some arity when List.length m.Ast.md_params = arity ->
      let span = match m.Ast.md_body with s :: _ -> s.Ast.span | [] -> Source_map.Span.nowhere in
      let at it = Ast.at span it in
      let k = Ast.generated [ "aborted"; m.Ast.md_name ]
      and answer = Ast.generated [ "aborted"; "answer" ] in
      let body =
        at (`Lambda ([], { Ast.ret = m.Ast.md_signature.Ast.ret; row = None; static_params = [] }, m.Ast.md_body))
      in
      { m with
        Ast.md_params = m.Ast.md_params @ [ { Ast.name = k; ty = None; implicit = false } ]
      ; md_body =
          [ at (`Var_decl (answer, None, Some (at (`Call (body, [])))))
          ; at (`Expr (at (`Call (at (`Var "discontinue"), [ at (`Var k) ]))))
          ; at (`Return (Some (at (`Var answer))))
          ]
      }
    | _ -> m
  in
  let rec impl (s : Ast.stmt) =
    match s.Ast.it with
    | `Impl_decl (Some (trait, ({ Ast.it = Ast.Ty_name eff | Ast.Ty_app (eff, _); _ } :: _ as args)), ty, params, body)
      when String.equal trait Core.effect_handler ->
      { s with
        Ast.it = `Impl_decl (Some (trait, args), ty, params, { body with Ast.ib_methods = List.map (given eff) body.Ast.ib_methods })
      }
    | `Attributed (attrs, inner) -> { s with Ast.it = `Attributed (attrs, impl inner) }
    | _ -> s
  in
  List.map impl p

(* `type X impl A, B { … }`: each method goes to the trait that declares it, and
   one no named trait declares is the type's own. A trait whose meta blocks
   generate its methods declares nothing before an instance runs them, so it
   takes every method the other named traits do not declare. *)
let implemented_in_types (p : Ast.program) : Ast.program * (Ast.span * string) list =
  let declared = Hashtbl.create 32 in
  let rec note (s : Ast.stmt) =
    match s.Ast.it with
    | `Trait_decl (name, _, body) ->
      Hashtbl.replace declared name (Some (List.map (fun (m : Ast.method_sig) -> m.Ast.ms_name) body.Ast.tb_methods))
    | `Trait_members ({ Ast.it = `Trait_decl (name, _, _); _ }, _) -> Hashtbl.replace declared name None
    | `Attributed (_, inner) -> note inner
    | _ -> ()
  in
  List.iter note p;
  let errors = ref [] in
  let rec split (s : Ast.stmt) : Ast.stmt list =
    match s.Ast.it with
    | `Attributed (attrs, inner) ->
      (match split inner with
       | first :: rest -> { s with Ast.it = `Attributed (attrs, first) } :: rest
       | [] -> [])
    | `Type_members (decl, members) ->
      let named, members =
        List.partition_map
          (fun (m : Ast.stmt) ->
            match m.Ast.it with
            | `Impl_decl (Some (trait, args), ty, params, _) -> Either.Left (m.Ast.span, trait, args, ty, params)
            | _ -> Either.Right m)
          members
      in
      if named = []
      then [ s ]
      else (
        let name_of (m : Ast.stmt) = Option.map (fun (name, _, _, _) -> name) (fn_parts m) in
        let generating =
          List.filter (fun (_, trait, _, _, _) -> Hashtbl.find_opt declared trait = Some None) named
        in
        (match generating with
         | _ :: (at, trait, _, _, _) :: _ ->
           errors
             := ( at
                , Printf.sprintf
                    "'%s' generates its methods, as another trait named here does, so which takes each is \
                     not known; write them as separate impls."
                    trait )
                :: !errors
         | _ -> ());
        let claims (m : Ast.stmt) =
          match name_of m with
          | None -> []
          | Some method_ ->
            List.filter
              (fun (_, trait, _, _, _) ->
                match Hashtbl.find_opt declared trait with
                | Some (Some methods) -> List.mem method_ methods
                | _ -> false)
              named
        in
        let placed =
          List.map
            (fun (m : Ast.stmt) ->
              match claims m, generating, name_of m with
              | [ (_, trait, _, _, _) ], _, _ -> m, Some trait
              | (_, first, _, _, _) :: (_, second, _, _, _) :: _, _, Some method_ ->
                errors
                  := ( m.Ast.span
                     , Printf.sprintf
                         "'%s' is declared by both '%s' and '%s'; write them as separate impls."
                         method_
                         first
                         second )
                     :: !errors;
                m, Some first
              | [], (_, trait, _, _, _) :: _, Some _ -> m, Some trait
              | _ -> m, None)
            members
        in
        let own = List.filter_map (fun (m, owner) -> if owner = None then Some m else None) placed in
        let impls =
          List.map
            (fun (at, trait, args, ty, params) ->
              let methods =
                List.filter_map
                  (fun (m, owner) ->
                    match owner, fn_parts m with
                    | Some t, Some (name, params, sg, body) when String.equal t trait ->
                      Some
                        { Ast.md_name = name
                        ; md_params = params
                        ; md_signature = sg
                        ; md_body = body
                        ; md_ann = ()
                        ; md_attrs = fn_attrs m
                        }
                    | _ -> None)
                  placed
              in
              Ast.at at (`Impl_decl (Some (trait, args), ty, params, { Ast.ib_assoc = []; ib_methods = methods })))
            named
        in
        (match own with
         | [] -> decl
         | own -> { s with Ast.it = `Type_members (decl, own) })
        :: impls)
    | _ -> [ s ]
  in
  let p = List.concat_map split p in
  p, List.rev !errors

(* Processed code names each closed use of a plain generic type by its copy,
   and the copies it reaches stand where their generic declaration stood. *)
let monomorphized w (type_level : Ast.resolved_stmt list) (code : Ast.resolved_stmt list) =
  let reached = Hashtbl.create 32 in
  let reach copy = Hashtbl.replace reached copy () in
  let ty t = Types.copied ~copy:(fun n a -> reach (type_copy w n a)) t in
  let rec expr (e : Ast.resolved_expr) : Ast.resolved_expr =
    let it : Ast.resolved_expr_kind =
      match e.Ast.it with
      | #Ast.lit as l -> l
      | #Ast.arrays as a -> (Ast.map_arrays expr a :> Ast.resolved_expr_kind)
      | #Ast.strings as a -> (Ast.map_strings expr a :> Ast.resolved_expr_kind)
      | #Ast.vars as a -> (Ast.map_vars expr a :> Ast.resolved_expr_kind)
      | #Ast.ops as a -> (Ast.map_ops expr a :> Ast.resolved_expr_kind)
      | #Ast.logic as a -> (Ast.map_logic expr a :> Ast.resolved_expr_kind)
      | #Ast.tuple as a -> (Ast.map_tuple expr a :> Ast.resolved_expr_kind)
      | #Ast.record as a -> (Ast.map_record expr a :> Ast.resolved_expr_kind)
      | #Ast.variant_lit as a -> (Ast.map_variant_lit expr a :> Ast.resolved_expr_kind)
      | `Dyn_call (receiver, name, t, args) -> `Dyn_call (expr receiver, name, ty t, List.map expr args)
      | #Ast.object_lit as a -> (Ast.map_object_lit expr a :> Ast.resolved_expr_kind)
      | `Lambda (params, signature, body) -> `Lambda (params, signature, List.map stmt body)
    in
    { e with Ast.it; ann = ty e.Ast.ann }
  and stmt (s : Ast.resolved_stmt) : Ast.resolved_stmt =
    let it : Ast.resolved_stmt_kind =
      match s.Ast.it with
      | `Match (scrutinee, cases) ->
        let scrutinee = expr scrutinee in
        let pattern (p : Ast.pattern) =
          match p, scrutinee.Ast.ann with
          | Ast.Pat_variant (t, v, payload), Types.Sum (copy, [])
            when String.equal (Types.declaration copy) t && not (String.equal copy t) ->
            Ast.Pat_variant (copy, v, payload)
          | p, _ -> p
        in
        `Match (scrutinee, List.map (fun (p, body) -> pattern p, List.map stmt body) cases)
      | #Ast.stmts as st -> (Ast.map_stmts expr stmt st :> Ast.resolved_stmt_kind)
      | #Ast.type_defs as t -> t
    in
    { s with Ast.it; ann = ty s.Ast.ann }
  in
  let code = List.map stmt code in
  let declared (s : Ast.resolved_stmt) =
    match s.Ast.it with
    | `Type_decl (name, params, Ast.T_fields fields) ->
      { s with
        Ast.it =
          `Type_decl
            ( name
            , params
            , Ast.T_fields
                (List.map (fun (f : Ast.field) -> { f with Ast.f_ty = renamed_type ~reach w f.Ast.f_ty }) fields) )
      }
    | `Type_decl (name, params, Ast.T_variants variants) ->
      { s with
        Ast.it =
          `Type_decl
            ( name
            , params
            , Ast.T_variants
                (List.map
                   (fun (v : Ast.variant) ->
                     { v with
                       Ast.v_payload = Ast.map_payload (renamed_type ~reach w) v.Ast.v_payload
                     ; v_result = Option.map (renamed_type ~reach w) v.Ast.v_result
                     })
                   variants) )
      }
    | _ -> s
  in
  let plain, generic =
    List.partition
      (fun (s : Ast.resolved_stmt) ->
        match s.Ast.it with
        | `Type_decl (name, _ :: _, _) -> not (Hashtbl.mem w.generic_decls name)
        | _ -> true)
      type_level
  in
  let plain = List.map declared plain in
  let made = Hashtbl.create 32 in
  let rec settle () =
    let waiting = Hashtbl.fold (fun c () acc -> if Hashtbl.mem made c then acc else c :: acc) reached [] in
    if waiting <> []
    then (
      List.iter
        (fun c ->
          Hashtbl.replace made c (copy_decl ~reach w c))
        waiting;
      settle ())
  in
  settle ();
  let copies_of (s : Ast.resolved_stmt) =
    match s.Ast.it with
    | `Type_decl (base, _, _) ->
      List.filter_map
        (fun c ->
          match Hashtbl.find_opt made c, Hashtbl.find_opt Types.copies c with
          | Some (Some ({ Ast.it = `Type_decl _ as it; _ } : Ast.stmt)), Some (b, _) when String.equal b base ->
            Some { s with Ast.it }
          | _ -> None)
        (List.rev w.copies_made)
    | _ -> []
  in
  plain @ List.concat_map copies_of generic, code

let program ~out (p : Ast.program) : (Ast.resolved_stmt list, Diagnostic.error list) result =
  let p, misplaced = implemented_in_types p in
  let p = aborting_impls p in
  let context =
    { out
    ; table = Hashtbl.create 16
    ; codes = Hashtbl.create 16
    ; current = ref (ref [])
    }
  in
  let registry = Registry.builtins () in
  let w =
    { context
    ; registry
    ; session = None
    ; traits = Hashtbl.create 16
    ; cache = Hashtbl.create 64
    ; by_decl = Hashtbl.create 64
    ; by_name = Hashtbl.create 64
    ; finished = []
    ; current = None
    ; meta_frame = None
    ; remembered = Hashtbl.create 16
    ; emitted = []
    ; rooted = S.empty
    ; root = None
    ; fns = Hashtbl.create 64
    ; known = Hashtbl.create 256
    ; unknown = Hashtbl.create 16
    ; known_methods = Hashtbl.create 64
    ; unknown_methods = Hashtbl.create 16
    ; impls = []
    ; types = []
    ; generator = "meta block"
    ; vars = Hashtbl.create 16
    ; units = Hashtbl.create 8
    ; type_names = Hashtbl.create 32
    ; comptime_types = Hashtbl.create 8
    ; comptime_traits = Hashtbl.create 8
    ; declared = []
    ; gens = Hashtbl.create 16
    ; type_level = []
    ; generic_decls = Hashtbl.create 32
    ; copies_made = []
    }
  in
  Hashtbl.reset Types.generic_types;
  Hashtbl.reset Types.copies;
  let roots = ref [] in
  let finish_root (checked : Typecheck.checked_stmt list option) =
    let s = session w in
    try
      drain w;
      Option.iter
        (fun root ->
          let made = Typecheck.processed_block w.registry root in
          drain w;
          roots := List.rev_append made !roots)
        checked;
      drain w
    with
    | Typecheck.Located e ->
      s.Typecheck.Session.errors := e :: !(s.Typecheck.Session.errors);
      w.finished <- []
  in
  let type_errors =
    List.map (fun (e : Typecheck.error) -> Diagnostic.at Diagnostic.Type e.Typecheck.span e.Typecheck.message)
  in
  let walk () =
    (match misplaced with
     | (span, message) :: _ -> raise (Typecheck.Rejected { Typecheck.span; message })
     | [] -> ());
    Hashtbl.iter (fun name _ -> Hashtbl.replace w.known name ()) (Builtins.env ~out:ignore).Value.vars;
    let p = List.map implicit (rename_local_types (types_of w p)) in
    let p = List.filter (fun s -> not (note_trait w s)) p in
    (* Made once the session can run their trait's meta blocks. *)
    let of_comptime_traits, p = List.partition (names_comptime_trait w) p in
    List.iter (collect w) p;
    let statics () =
      match w.current with
      | Some i -> values_of i.key
      | None -> []
    in
    let ops =
      { Typecheck.instance = (fun span d key -> instance w span d key)
      ; meta =
          (fun runtime type_in written ->
            let s = typed_reads type_in runtime written in
            match w.meta_frame with
            | Some frame ->
              (* Nested in a meta block being checked: it runs first, and what it
                 generates is that block's code. *)
              let generated =
                List.map
                  implicit
                  (Splice.fit
                     Splice.Meta_program
                     s.Ast.span
                     (meta_stmt w ~statics:[] ~runtime:(S.of_list runtime) ~outer:frame.outer s))
              in
              lower w.context ~visible:(visible w) ~returns:(returns w) ~params:runtime generated
            | None ->
              let fragments = meta_stmt w ~statics:(statics ()) ~runtime:(S.of_list runtime) ~outer:[] s in
              let generated =
                List.map
                  implicit
                  (if Option.is_some w.current
                   then Splice.fit Splice.Body s.Ast.span fragments
                   else Splice.fit Splice.Top s.Ast.span fragments)
              in
              (match w.current, written.Ast.it with
               | Some i, `Meta body -> i.generated <- (body, Spliced_stmts generated) :: i.generated
               | _ -> ());
              generated)
      ; meta_expr =
          (fun runtime type_in e ->
            match e.Ast.it with
            | `Meta_expr written ->
              let body = typed_body type_in runtime written in
              w.generator <- "meta block";
              let fit ~statics ~outer =
                Splice.fit
                  Splice.Expression
                  e.Ast.span
                  (run_meta w ~span:e.Ast.span ~statics ~runtime:(S.of_list runtime) ~outer body)
              in
              (match w.meta_frame with
               | Some frame ->
                 lower_expr w.context ~visible:(visible w) ~returns:(returns w) ~params:runtime (fit ~statics:[] ~outer:frame.outer)
               | None ->
                 let generated = fit ~statics:(statics ()) ~outer:[] in
                 Option.iter (fun i -> i.generated <- (written, Spliced_expr generated) :: i.generated) w.current;
                 generated)
            | _ -> e)
      ; declof =
          (fun span target name static_args ->
            let decl =
              match target with
              | Some (d, key) -> declared_instance w span d key
              | None -> declared_type w span name static_args
            in
            let index = Hashtbl.length w.context.codes in
            Hashtbl.replace w.context.codes index (Ast.at span (`Code_decl decl));
            Ast.at span (`Call (Ast.at span (`Var quoter_decl), [ Ast.at span (`Int index) ])))
      ; typeof = Splice.reflected
      ; unused =
          (fun f ->
            let rooted = w.rooted
            and deps = Option.map (fun i -> i, i.deps) w.current
            and reached = Option.map (fun frame -> frame, frame.reached) w.meta_frame in
            Fun.protect
              ~finally:(fun () ->
                w.rooted <- rooted;
                Option.iter (fun (i, d) -> i.deps <- d) deps;
                Option.iter (fun (frame, r) -> frame.reached <- r) reached)
              f)
      ; wake = wake w
      ; unknown = note_unknown w
      ; unknown_method =
          (fun name span ->
            if not (Hashtbl.mem w.known_methods name || Hashtbl.mem w.unknown_methods name)
            then Hashtbl.replace w.unknown_methods name span)
      ; static_value = static_value w
      ; generic_new = generic_new w
      ; copies_of = (fun t -> ignore (Types.copied ~copy:(fun n a -> ignore (type_copy w n a)) t))
      ; performs_gen =
          (fun d -> performs_gen w d.Typecheck.wd_name d.Typecheck.wd_params d.Typecheck.wd_body)
      ; instances_of =
          (fun d ->
            List.filter_map
              (fun i -> if i.state = Done then i.checked else None)
              (List.rev (Option.value ~default:[] (Hashtbl.find_opt w.by_decl d.Typecheck.wd_id))))
      ; effect_handler =
          (fun span handled ->
            Option.map
              (fun tr ->
                let answer = Ast.generated [ "handler"; "answer" ] in
                fst
                  (instantiate_trait
                     w
                     tr
                     [ Ast.at span (Ast.Ty_name handled); Ast.at span (Ast.Ty_name answer) ]
                     ~open_params:[ answer ]
                     span))
              (Hashtbl.find_opt w.comptime_traits Core.effect_handler))
      }
    in
    let session = Typecheck.Walk.start ~registry ops in
    w.session <- Some session;
    Fun.protect ~finally:Typecheck.Walk.stop @@ fun () ->
    Typecheck.Walk.declare
      session
      (List.filter (fun s -> Option.is_none (deferred_prefix s) && Loader.is_declaration s) p);
    List.iter (check_type_level w) p;
    let root_decl =
      List.find_opt
        (fun s ->
          match fn_parts s with
          | Some (name, _, _, _) -> Ast.is_root name
          | None -> false)
        p
    in
    w.root <- Option.bind root_decl (fun s -> Option.map (fun (name, _, _, _) -> name) (fn_parts s));
    List.iter (register w) of_comptime_traits;
    (* The statements since the last top-level meta block, which run as one
       root call: a meta block stands between two, so it still runs after what
       the statements above it reach, and its generated statements join the
       ones below. Each `var` is declared at the top level ahead of the call,
       once the call has settled its type. *)
    let pending = ref [] in
    let flush () =
      let statements = List.rev !pending in
      pending := [];
      if statements <> []
      then (
        match w.root with
        | Some name ->
          let checked = Typecheck.Walk.root session (Compile.root_call name statements) in
          let globals = List.concat_map Compile.globals statements in
          let before = !roots in
          finish_root checked;
          let made = List.rev (List.filteri (fun i _ -> i < List.length !roots - List.length before) !roots) in
          roots := List.rev_append (globals @ made) before
        | None -> List.iter (fun s -> finish_root (Typecheck.Walk.root session s)) statements)
    in
    let rec root (s : Ast.stmt) =
      match s.Ast.it with
      | `Meta _ | `Derive _ ->
        flush ();
        let generated = Splice.fit Splice.Top s.Ast.span (meta_stmt w ~statics:[] ~runtime:S.empty ~outer:[] s) in
        (* Hoisted, since what generated it may stand below its use. *)
        let declarations, statements = List.partition Splice.is_visible_to_meta generated in
        List.iter (register w) declarations;
        List.iter root (List.map implicit statements)
      | `Gen _ -> fail s.Ast.span "'gen' is only allowed inside a meta block."
      | _ when Loader.is_declaration s -> ()
      | _ -> pending := s :: !pending
    in
    List.iter
      (fun (s : Ast.stmt) ->
        match deferred_prefix s with
        | Some _ -> ()
        | None -> root s)
      p;
    flush ();
    printed w;
    finish_root None;
    match type_errors (Typecheck.Walk.errors session) with
    | [] ->
      let type_level, code = monomorphized w (List.rev w.type_level) (pruned w (List.rev !roots) @ List.rev !roots) in
      Ok (type_level @ code)
    | errors -> Error errors
  in
  try walk () with
  | Failed e -> Error [ Diagnostic.at Diagnostic.Meta e.span e.message ]
  | Typecheck.Rejected e -> Error [ Diagnostic.at Diagnostic.Type e.Typecheck.span e.Typecheck.message ]
