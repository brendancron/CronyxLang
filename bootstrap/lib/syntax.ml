(* The compiler's surface tree and `std/compiler/Ast`'s, as one another.

   [of_*] builds the values a quote hands a meta program; [to_*] reads one back
   when `gen` emits it or a quote splices it. The library's tree has a node
   for every surface form, so the two directions are inverses but for what the
   library does not hold: a method call's name as a function, which the loader
   decides again from the name. *)

exception Malformed of string

let malformed fmt = Printf.ksprintf (fun m -> raise (Malformed m)) fmt

(* ---- building values ---- *)

let ty name = Some (Core.syntax name)
let name n = Value.Name n
let str s = Value.Str (Utf8.decode s)
let int n = Value.Int n
let bool b = Value.Bool b

let list f items =
  let items = Array.of_list (List.map f items) in
  Value.Record
    (Some Core.list, [ "items", ref (Value.Array items); "count", ref (Value.Int (Array.length items)) ])

let option f = function
  | None -> Value.Variant (Some Core.option, "None", [])
  | Some x -> Value.Variant (Some Core.option, "Some", [ "0", f x ])

let variant ty_name label values =
  Value.Variant (ty ty_name, label, List.mapi (fun i v -> string_of_int i, v) values)

let record ty_name fields = Value.Record (ty ty_name, List.map (fun (l, v) -> l, ref v) fields)
let span s = Value.Span s
let node ty_name kind sp = record ty_name [ "kind", kind; "span", span sp ]

let unop (op : Ast.unop) =
  variant "UnOp" (match op with Ast.Neg -> "Neg" | Ast.Not -> "Not" | Ast.Bit_not -> "BitNot") []

let binop_names : (Ast.binop * string) list =
  [ Ast.Add, "Add"; Ast.Sub, "Sub"; Ast.Mul, "Mul"; Ast.Div, "Div"; Ast.Mod, "Mod"
  ; Ast.Bit_and, "BitAnd"; Ast.Bit_or, "BitOr"; Ast.Bit_xor, "BitXor"; Ast.Shl, "Shl"
  ; Ast.Shr, "Shr"; Ast.Equal, "Equal"; Ast.Not_equal, "NotEqual"; Ast.Less, "Less"
  ; Ast.Less_equal, "LessEqual"; Ast.Greater, "Greater"; Ast.Greater_equal, "GreaterEqual"
  ]

let binop op = variant "BinOp" (List.assoc op binop_names) []

let op_kind (k : Ast.op_kind) =
  variant "OpKind" (match k with Ast.Op_fn -> "Fn" | Ast.Op_ctl -> "Ctl" | Ast.Op_final -> "Final") []

let attr_arg (a : Ast.attr_arg) =
  let label, v =
    match a with
    | Ast.A_str s -> "Str", str s
    | Ast.A_int n -> "Int", int n
    | Ast.A_float f -> "Float", Value.Float f
    | Ast.A_bool b -> "Bool", bool b
  in
  Value.Variant (Some Core.attr_arg, label, [ "0", v ])

let attribute (a : Ast.attr) =
  record "Attribute" [ "name", name a.Ast.a_name; "args", list attr_arg a.Ast.a_args; "span", span a.Ast.a_span ]

let applied (n, args) type_expr = record "Applied" [ "name", name n; "args", list type_expr args ]

let rec type_expr (t : Ast.type_expr) =
  let k label values = variant "TypeKind" label values in
  let row r = list (fun a -> applied a type_expr) r in
  let kind =
    match t.Ast.it with
    | Ast.Ty_name n -> k "Named" [ name n ]
    | Ast.Ty_app (n, args) -> k "Applied" [ name n; list type_expr args ]
    | Ast.Ty_tuple items -> k "Tuple" [ list type_expr items ]
    | Ast.Ty_record fields -> k "Record" [ list field_type fields ]
    | Ast.Ty_fn (params, ret, r) -> k "Function" [ list type_expr params; type_expr ret; row r ]
    | Ast.Ty_variadic t -> k "Variadic" [ type_expr t ]
    | Ast.Ty_spread t -> k "Spread" [ type_expr t ]
    | Ast.Ty_assoc (owner, member) -> k "Assoc" [ type_expr owner; name member ]
    | Ast.Ty_bind (n, t) -> k "Bind" [ name n; type_expr t ]
    | Ast.Ty_row r -> k "Row" [ row r ]
  in
  node "TypeExpr" kind t.Ast.span

and field_type (n, t) = record "FieldType" [ "name", name n; "ty", type_expr t ]

let param (p : Ast.param) =
  record
    "Param"
    [ "name", name p.Ast.name; "ty", option type_expr p.Ast.ty; "implicit", bool p.Ast.implicit ]

let static_param (p : Ast.static_param) =
  record
    "StaticParam"
    [ "name", name p.Ast.sp_name; "ty", option type_expr p.Ast.sp_ty; "pack", bool p.Ast.sp_pack ]

let type_param (p : Ast.type_param) =
  record
    "TypeParam"
    [ "name", name p.Ast.tp_name; "pack", bool p.Ast.tp_pack; "ty", option type_expr p.Ast.tp_ty ]

let signature (sg : Ast.signature) =
  record
    "Signature"
    [ "ret", option type_expr sg.Ast.ret
    ; "row", option (list (fun a -> applied a type_expr)) sg.Ast.row
    ; "static_params", list static_param sg.Ast.static_params
    ]

let pattern (p : Ast.pattern) =
  match p with
  | Ast.Pat_wild -> variant "Pattern" "Wild" []
  | Ast.Pat_variant (t, v, payload) ->
    let bindings =
      match payload with
      | Ast.P_none -> variant "Bindings" "None" []
      | Ast.P_tuple names -> variant "Bindings" "Positional" [ list name names ]
      | Ast.P_fields pairs ->
        variant
          "Bindings"
          "Named"
          [ list (fun (f, b) -> record "NamedBinding" [ "field", name f; "bound", name b ]) pairs ]
    in
    variant "Pattern" "Variant" [ name t; name v; bindings ]

let import (i : Ast.import) =
  match i with
  | Ast.Qualified path -> variant "Import" "Qualified" [ str path ]
  | Ast.Aliased (path, alias) -> variant "Import" "Aliased" [ str path; name alias ]
  | Ast.Selective (names, path) -> variant "Import" "Selective" [ list name names; str path ]
  | Ast.Wildcard path -> variant "Import" "Wildcard" [ str path ]

let rec expr (e : Ast.expr) : Value.value =
  let k label values = variant "ExprKind" label values in
  let field_inits fields = list field_init fields in
  let kind =
    match e.Ast.it with
    | `Unit -> k "Unit" []
    | `Int n -> k "Int" [ int n ]
    | `Float f -> k "Float" [ Value.Float f ]
    | `Str s -> k "Str" [ Value.Str s ]
    | `Char c -> k "Char" [ Value.Chr c ]
    | `Bool b -> k "Bool" [ bool b ]
    | `Name n -> k "NameLit" [ name n ]
    | `Bytes raw ->
      k "Bytes" [ Value.Array (Array.init (String.length raw) (fun i -> Value.Byte raw.[i])) ]
    | `Var n -> k "Var" [ name n ]
    | `Assign (n, v) -> k "Assign" [ name n; expr v ]
    | `Unop (op, a) -> k "Unary" [ unop op; expr a ]
    | `Binop (op, a, b) -> k "Binary" [ binop op; expr a; expr b ]
    | `And (a, b) -> k "And" [ expr a; expr b ]
    | `Or (a, b) -> k "Or" [ expr a; expr b ]
    | `Call (f, args) -> k "Call" [ expr f; list expr args ]
    | `Method_call (receiver, n, _, args) -> k "MethodCall" [ expr receiver; name n; list expr args ]
    | `Static_call (f, static_args, args) ->
      k "StaticCall" [ expr f; list static_arg static_args; list expr args ]
    | `Compound (op, n, v) -> k "Compound" [ binop op; name n; expr v ]
    | `Compound_index (op, a, i, v) -> k "CompoundIndex" [ binop op; expr a; expr i; expr v ]
    | `Compound_field (op, r, f, v) -> k "CompoundField" [ binop op; expr r; name f; expr v ]
    | `Index (a, i) -> k "Index" [ expr a; expr i ]
    | `Index_assign (a, i, v) -> k "IndexAssign" [ expr a; expr i; expr v ]
    | `Tuple items -> k "Tuple" [ list expr items ]
    | `Tuple_get (t, i) -> k "TupleGet" [ expr t; int i ]
    | `Spread inner -> k "Spread" [ expr inner ]
    | `Record_lit fields -> k "Record" [ field_inits fields ]
    | `Field (r, f) -> k "Field" [ expr r; name f ]
    | `Field_assign (r, f, v) -> k "FieldAssign" [ expr r; name f; expr v ]
    | `New (t, fields) -> k "New" [ name t; field_inits fields ]
    | `New_call (t, targs, args) -> k "NewCall" [ name t; list type_expr targs; list expr args ]
    | `New_generic (t, static_args, fields) ->
      k "NewGeneric" [ name t; list static_arg static_args; field_inits fields ]
    | `New_variant (t, v, payload) -> k "NewVariant" [ name t; name v; args payload ]
    | `Collection_lit items -> k "Collection" [ list expr items ]
    | `Lambda (params, sg, body) -> k "Lambda" [ list param params; signature sg; list stmt body ]
    | `Run_expr (body, clauses, ret) ->
      k "Run" [ valued_block body; list handler_clause clauses; option return_clause ret ]
    | `Match_expr (scrutinee, arms) ->
      k
        "Match"
        [ expr scrutinee
        ; list
            (fun (p, b) -> record "ValuedArm" [ "pattern", pattern p; "body", valued_block b ])
            arms
        ]
    | `Typeof inner -> k "Typeof" [ expr inner ]
    | `Code inner -> k "QuoteExpr" [ expr inner ]
    | `Code_stmts body -> k "QuoteStmts" [ list stmt body ]
    | `Code_decl d -> k "QuoteDecl" [ decl d ]
  in
  node "Expr" kind e.Ast.span

and field_init (n, v) = record "FieldInit" [ "name", name n; "value", expr v ]

and args (p : Ast.expr Ast.payload) =
  match p with
  | Ast.P_none -> variant "Args" "None" []
  | Ast.P_tuple items -> variant "Args" "Positional" [ list expr items ]
  | Ast.P_fields fields -> variant "Args" "Named" [ list field_init fields ]

and static_arg (a : Ast.expr Ast.static_arg) =
  match a with
  | Ast.St_type t -> variant "StaticArg" "Type" [ type_expr t ]
  | Ast.St_value v -> variant "StaticArg" "Value" [ expr v ]

and valued_block (b : (Ast.expr, Ast.stmt) Ast.valued_block) =
  record "ValuedBlock" [ "stmts", list stmt b.Ast.vb_stmts; "value", option expr b.Ast.vb_value ]

and return_clause (c : (Ast.expr, Ast.stmt) Ast.ret_clause) =
  record "ReturnClause" [ "param", name c.Ast.rc_param; "body", valued_block c.Ast.rc_body ]

and handler (h : Ast.stmt Ast.handler) =
  record "Handler" [ "handles", name h.Ast.handled; "arms", list arm h.Ast.arms ]

and arm (a : Ast.stmt Ast.arm) =
  record
    "Arm"
    [ "name", name a.Ast.arm_name
    ; "kind", op_kind a.Ast.arm_kind
    ; "params", list name a.Ast.arm_params
    ; "body", list stmt a.Ast.arm_body
    ]

and handler_clause (c : Ast.stmt Ast.handler_clause) =
  match c with
  | Ast.Inline h -> variant "HandlerClause" "Inline" [ handler h ]
  | Ast.Named n -> variant "HandlerClause" "Named" [ name n ]

and stmt (s : Ast.stmt) : Value.value =
  let k label values = variant "StmtKind" label values in
  let kind =
    match s.Ast.it with
    | `Expr e -> k "Expression" [ expr e ]
    | `Var_decl (n, t, init) -> k "Let" [ name n; option type_expr t; option expr init ]
    | `Var_tuple (names, init) -> k "LetTuple" [ list name names; expr init ]
    | `Block body -> k "Block" [ list stmt body ]
    | `If (c, t, e) -> k "If" [ expr c; stmt t; option stmt e ]
    | `While (c, body) -> k "While" [ expr c; stmt body ]
    | `For (init, c, step, body) ->
      k "For" [ option stmt init; option expr c; option expr step; stmt body ]
    | `For_in (names, over, body) -> k "ForIn" [ list name names; expr over; stmt body ]
    | `Return e -> k "Return" [ option expr e ]
    | `Break -> k "Break" []
    | `Continue -> k "Continue" []
    | `Defer body -> k "Defer" [ stmt body ]
    | `Match (scrutinee, arms) ->
      k
        "Match"
        [ expr scrutinee
        ; list (fun (p, body) -> record "MatchArm" [ "pattern", pattern p; "body", list stmt body ]) arms
        ]
    | `Run (body, clauses) -> k "Run" [ list stmt body; list handler_clause clauses ]
    | `Resume e -> k "Resume" [ option expr e ]
    | `Discontinue -> k "Discontinue" []
    | `Meta body -> k "Meta" [ list stmt body ]
    | `Gen inner -> k "Gen" [ stmt inner ]
    | `Derive (traits, target) -> k "Derive" [ list name traits; name target ]
    | _ -> k "Declare" [ decl s ]
  in
  node "Stmt" kind s.Ast.span

and decl (s : Ast.stmt) : Value.value =
  let attrs, inner =
    match s.Ast.it with
    | `Attributed (attrs, inner) -> attrs, inner
    | _ -> [], s
  in
  let k label values = variant "DeclKind" label values in
  let kind =
    match inner.Ast.it with
    | `Fn (n, params, sg, body) ->
      k
        "Fn"
        [ record
            "FnDecl"
            [ "name", name n; "params", list param params; "signature", signature sg; "body", list stmt body ]
        ]
    | `Type_decl (n, params, body) -> k "Type" [ type_decl n params body ]
    | `Type_members ({ Ast.it = `Type_decl (n, params, body); _ }, members) ->
      k "TypeWithMembers" [ type_decl n params body; list stmt members ]
    | `Trait_decl (n, params, body) ->
      k
        "Trait"
        [ record
            "TraitDecl"
            [ "name", name n
            ; "params", list name params
            ; "supers", list (fun a -> applied a type_expr) body.Ast.tb_super
            ; ( "assoc"
              , list
                  (fun (a : Ast.assoc_decl) ->
                    record "AssocDecl" [ "name", name a.Ast.ad_name; "attrs", list attribute a.Ast.ad_attrs ])
                  body.Ast.tb_assoc )
            ; "methods", list method_sig body.Ast.tb_methods
            ]
        ]
    | `Impl_decl (trait, target, params, body) ->
      k
        "Impl"
        [ record
            "ImplDecl"
            [ "implements", option (fun a -> applied a type_expr) trait
            ; "target", name target
            ; "params", list type_param params
            ; ( "assoc"
              , list
                  (fun (a : Ast.assoc_def) ->
                    record
                      "AssocDef"
                      [ "name", name a.Ast.as_name
                      ; "ty", type_expr a.Ast.as_ty
                      ; "attrs", list attribute a.Ast.as_attrs
                      ])
                  body.Ast.ib_assoc )
            ; "methods", list method_def body.Ast.ib_methods
            ]
        ]
    | `Effect_decl (n, params, ops) ->
      k
        "Effect"
        [ record "EffectDecl" [ "name", name n; "params", list name params; "ops", list op_decl ops ] ]
    | `Handler_decl (n, h) -> k "Handler" [ name n; handler h ]
    | `Import i -> k "Import" [ import i ]
    | `Global_import i -> k "GlobalImport" [ import i ]
    | _ -> malformed "This statement is not a declaration."
  in
  record "Decl" [ "kind", kind; "attrs", list attribute attrs; "span", span s.Ast.span ]

and type_decl n params (body : Ast.type_body) =
  let body =
    match body with
    | Ast.T_fields fields ->
      variant
        "TypeBody"
        "Fields"
        [ list
            (fun (f : Ast.field) ->
              record
                "FieldDecl"
                [ "name", name f.Ast.f_name; "ty", type_expr f.Ast.f_ty; "attrs", list attribute f.Ast.f_attrs ])
            fields
        ]
    | Ast.T_variants variants ->
      variant
        "TypeBody"
        "Variants"
        [ list
            (fun (v : Ast.variant) ->
              let payload =
                match v.Ast.v_payload with
                | Ast.P_none -> variant "Payload" "None" []
                | Ast.P_tuple items -> variant "Payload" "Positional" [ list type_expr items ]
                | Ast.P_fields fields -> variant "Payload" "Named" [ list field_type fields ]
              in
              record
                "VariantDecl"
                [ "name", name v.Ast.v_name
                ; "params", list name v.Ast.v_params
                ; "payload", payload
                ; "result", option type_expr v.Ast.v_result
                ; "attrs", list attribute v.Ast.v_attrs
                ])
            variants
        ]
  in
  record "TypeDecl" [ "name", name n; "params", list type_param params; "body", body ]

and method_sig (m : Ast.method_sig) =
  record
    "MethodSig"
    [ "name", name m.Ast.ms_name
    ; "params", list param m.Ast.ms_params
    ; "signature", signature m.Ast.ms_signature
    ; "attrs", list attribute m.Ast.ms_attrs
    ]

and method_def (m : (Ast.stmt, unit) Ast.method_def) =
  record
    "MethodDef"
    [ "name", name m.Ast.md_name
    ; "params", list param m.Ast.md_params
    ; "signature", signature m.Ast.md_signature
    ; "body", list stmt m.Ast.md_body
    ; "attrs", list attribute m.Ast.md_attrs
    ]

and op_decl (o : Ast.op_decl) =
  record
    "OpDecl"
    [ "name", name o.Ast.op_name
    ; "kind", op_kind o.Ast.op_kind
    ; "type_params", list name o.Ast.op_tparams
    ; "params", list param o.Ast.op_params
    ; "ret", option type_expr o.Ast.op_ret
    ; "attrs", list attribute o.Ast.op_attrs
    ]

(* ---- reading values back ---- *)

(* A hand-made node has no source position, so it takes the one it is emitted
   at. *)
type reader = { fallback : Ast.span }

let field label (v : Value.value) =
  match v with
  | Value.Record (_, fields) ->
    (match List.assoc_opt label fields with
     | Some cell -> !cell
     | None -> malformed "A tree node is missing its '%s'." label)
  | v -> malformed "Expected a tree node, found %s." (Value.type_name v)

let case (v : Value.value) =
  match v with
  | Value.Variant (_, label, payload) -> label, List.map snd payload
  | v -> malformed "Expected a variant, found %s." (Value.type_name v)

let read_name (v : Value.value) =
  match v with
  | Value.Name n -> n
  | v -> malformed "Expected a name, found %s." (Value.type_name v)

let read_str (v : Value.value) =
  match v with
  | Value.Str s -> Utf8.encode s
  | v -> malformed "Expected a string, found %s." (Value.type_name v)

let read_int (v : Value.value) =
  match v with
  | Value.Int n -> n
  | v -> malformed "Expected an int, found %s." (Value.type_name v)

let read_bool (v : Value.value) =
  match v with
  | Value.Bool b -> b
  | v -> malformed "Expected a bool, found %s." (Value.type_name v)

let read_list f (v : Value.value) =
  match v with
  | Value.Record (_, _) ->
    (match field "items" v, field "count" v with
     | Value.Array items, Value.Int count -> List.init count (fun i -> f items.(i))
     | _ -> malformed "Expected a list.")
  | Value.Array items -> List.map f (Array.to_list items)
  | v -> malformed "Expected a list, found %s." (Value.type_name v)

let read_option f (v : Value.value) =
  match case v with
  | "None", [] -> None
  | "Some", [ x ] -> Some (f x)
  | _ -> malformed "Expected an option."

let read_span r (v : Value.value) =
  match v with
  | Value.Span s ->
    (match Source_map.Span.view s with
     | Source_map.Span.Nowhere_in_source -> r.fallback
     | Source_map.Span.Located _ -> s)
  | v -> malformed "Expected a span, found %s." (Value.type_name v)

let read_unop v : Ast.unop =
  match case v with
  | "Neg", _ -> Ast.Neg
  | "Not", _ -> Ast.Not
  | "BitNot", _ -> Ast.Bit_not
  | l, _ -> malformed "'%s' is not a unary operator." l

let read_binop v : Ast.binop =
  let l, _ = case v in
  match List.find_opt (fun (_, n) -> String.equal n l) binop_names with
  | Some (op, _) -> op
  | None -> malformed "'%s' is not a binary operator." l

let read_op_kind v : Ast.op_kind =
  match case v with
  | "Fn", _ -> Ast.Op_fn
  | "Ctl", _ -> Ast.Op_ctl
  | "Final", _ -> Ast.Op_final
  | l, _ -> malformed "'%s' is not an operation kind." l

let read_attr_arg v : Ast.attr_arg =
  match case v with
  | "Str", [ s ] -> Ast.A_str (read_str s)
  | "Int", [ n ] -> Ast.A_int (read_int n)
  | "Float", [ Value.Float f ] -> Ast.A_float f
  | "Bool", [ b ] -> Ast.A_bool (read_bool b)
  | l, _ -> malformed "'%s' is not an attribute argument." l

let read_attribute r v : Ast.attr =
  { Ast.a_name = read_name (field "name" v)
  ; a_args = read_list read_attr_arg (field "args" v)
  ; a_span = read_span r (field "span" v)
  }

let read_applied f v = read_name (field "name" v), read_list f (field "args" v)

let rec read_type r v : Ast.type_expr =
  let sp = read_span r (field "span" v) in
  let ty = read_type r in
  let row x = read_list (read_applied ty) x in
  let it : Ast.type_expr_kind =
    match case (field "kind" v) with
    | "Named", [ n ] -> Ast.Ty_name (read_name n)
    | "Applied", [ n; a ] -> Ast.Ty_app (read_name n, read_list ty a)
    | "Tuple", [ a ] -> Ast.Ty_tuple (read_list ty a)
    | "Record", [ a ] -> Ast.Ty_record (read_list (read_field_type r) a)
    | "Function", [ p; ret; rw ] -> Ast.Ty_fn (read_list ty p, ty ret, row rw)
    | "Variadic", [ t ] -> Ast.Ty_variadic (ty t)
    | "Spread", [ t ] -> Ast.Ty_spread (ty t)
    | "Assoc", [ o; m ] -> Ast.Ty_assoc (ty o, read_name m)
    | "Bind", [ n; t ] -> Ast.Ty_bind (read_name n, ty t)
    | "Row", [ rw ] -> Ast.Ty_row (row rw)
    | l, _ -> malformed "'%s' is not a type." l
  in
  { Ast.it; span = sp; ann = () }

and read_field_type r v = read_name (field "name" v), read_type r (field "ty" v)

let read_param r v : Ast.param =
  { Ast.name = read_name (field "name" v)
  ; ty = read_option (read_type r) (field "ty" v)
  ; implicit = read_bool (field "implicit" v)
  }

let read_static_param r v : Ast.static_param =
  { Ast.sp_name = read_name (field "name" v)
  ; sp_ty = read_option (read_type r) (field "ty" v)
  ; sp_pack = read_bool (field "pack" v)
  }

let read_type_param r v : Ast.type_param =
  { Ast.tp_name = read_name (field "name" v)
  ; tp_pack = read_bool (field "pack" v)
  ; tp_ty = read_option (read_type r) (field "ty" v)
  }

let read_signature r v : Ast.signature =
  { Ast.ret = read_option (read_type r) (field "ret" v)
  ; row = read_option (read_list (read_applied (read_type r))) (field "row" v)
  ; static_params = read_list (read_static_param r) (field "static_params" v)
  }

let read_pattern v : Ast.pattern =
  match case v with
  | "Wild", [] -> Ast.Pat_wild
  | "Variant", [ t; n; b ] ->
    let payload =
      match case b with
      | "None", [] -> Ast.P_none
      | "Positional", [ names ] -> Ast.P_tuple (read_list read_name names)
      | "Named", [ pairs ] ->
        Ast.P_fields
          (read_list (fun p -> read_name (field "field" p), read_name (field "bound" p)) pairs)
      | l, _ -> malformed "'%s' is not a binding list." l
    in
    Ast.Pat_variant (read_name t, read_name n, payload)
  | l, _ -> malformed "'%s' is not a pattern." l

let read_import v : Ast.import =
  match case v with
  | "Qualified", [ p ] -> Ast.Qualified (read_str p)
  | "Aliased", [ p; a ] -> Ast.Aliased (read_str p, read_name a)
  | "Selective", [ ns; p ] -> Ast.Selective (read_list read_name ns, read_str p)
  | "Wildcard", [ p ] -> Ast.Wildcard (read_str p)
  | l, _ -> malformed "'%s' is not an import." l

let rec read_expr r v : Ast.expr =
  let sp = read_span r (field "span" v) in
  let e = read_expr r in
  let es = read_list e in
  let s = read_stmt r in
  let inits = read_list (read_field_init r) in
  let it : Ast.expr_kind =
    match case (field "kind" v) with
    | "Unit", [] -> `Unit
    | "Int", [ n ] -> `Int (read_int n)
    | "Float", [ Value.Float f ] -> `Float f
    | "Str", [ Value.Str t ] -> `Str t
    | "Char", [ Value.Chr c ] -> `Char c
    | "Bool", [ b ] -> `Bool (read_bool b)
    | "NameLit", [ n ] -> `Name (read_name n)
    | "Bytes", [ Value.Array bytes ] ->
      `Bytes
        (String.init (Array.length bytes) (fun i ->
           match bytes.(i) with
           | Value.Byte c -> c
           | _ -> malformed "Expected a byte."))
    | "Var", [ n ] -> `Var (read_name n)
    | "Assign", [ n; x ] -> `Assign (read_name n, e x)
    | "Unary", [ op; x ] -> `Unop (read_unop op, e x)
    | "Binary", [ op; a; b ] -> `Binop (read_binop op, e a, e b)
    | "And", [ a; b ] -> `And (e a, e b)
    | "Or", [ a; b ] -> `Or (e a, e b)
    | "Call", [ f; a ] -> `Call (e f, es a)
    | "MethodCall", [ recv; n; a ] ->
      let n = read_name n in
      `Method_call (e recv, n, n, es a)
    | "StaticCall", [ f; sa; a ] -> `Static_call (e f, read_list (read_static_arg r) sa, es a)
    | "Compound", [ op; n; x ] -> `Compound (read_binop op, read_name n, e x)
    | "CompoundIndex", [ op; a; i; x ] -> `Compound_index (read_binop op, e a, e i, e x)
    | "CompoundField", [ op; rc; f; x ] -> `Compound_field (read_binop op, e rc, read_name f, e x)
    | "Index", [ a; i ] -> `Index (e a, e i)
    | "IndexAssign", [ a; i; x ] -> `Index_assign (e a, e i, e x)
    | "Tuple", [ a ] -> `Tuple (es a)
    | "TupleGet", [ t; i ] -> `Tuple_get (e t, read_int i)
    | "Spread", [ x ] -> `Spread (e x)
    | "Record", [ f ] -> `Record_lit (inits f)
    | "Field", [ rc; f ] -> `Field (e rc, read_name f)
    | "FieldAssign", [ rc; f; x ] -> `Field_assign (e rc, read_name f, e x)
    | "New", [ t; f ] -> `New (read_name t, inits f)
    | "NewCall", [ t; ta; a ] -> `New_call (read_name t, read_list (read_type r) ta, es a)
    | "NewGeneric", [ t; sa; f ] ->
      `New_generic (read_name t, read_list (read_static_arg r) sa, inits f)
    | "NewVariant", [ t; n; a ] ->
      let payload : Ast.expr Ast.payload =
        match case a with
        | "None", [] -> Ast.P_none
        | "Positional", [ items ] -> Ast.P_tuple (es items)
        | "Named", [ f ] -> Ast.P_fields (inits f)
        | l, _ -> malformed "'%s' is not an argument list." l
      in
      `New_variant (read_name t, read_name n, payload)
    | "Collection", [ a ] -> `Collection_lit (es a)
    | "Lambda", [ p; sg; body ] ->
      `Lambda (read_list (read_param r) p, read_signature r sg, read_list s body)
    | "Run", [ body; clauses; ret ] ->
      `Run_expr
        ( read_valued r body
        , read_list (read_clause r) clauses
        , read_option
            (fun c ->
              { Ast.rc_param = read_name (field "param" c); rc_body = read_valued r (field "body" c) })
            ret )
    | "Match", [ x; arms ] ->
      `Match_expr
        ( e x
        , read_list
            (fun a -> read_pattern (field "pattern" a), read_valued r (field "body" a))
            arms )
    | "Typeof", [ x ] -> `Typeof (e x)
    | "QuoteExpr", [ x ] -> `Code (e x)
    | "QuoteStmts", [ body ] -> `Code_stmts (read_list s body)
    | "QuoteDecl", [ d ] -> `Code_decl (read_decl r d)
    | l, _ -> malformed "'%s' is not an expression." l
  in
  { Ast.it; span = sp; ann = () }

and read_field_init r v = read_name (field "name" v), read_expr r (field "value" v)

and read_static_arg r v : Ast.expr Ast.static_arg =
  match case v with
  | "Type", [ t ] -> Ast.St_type (read_type r t)
  | "Value", [ x ] -> Ast.St_value (read_expr r x)
  | l, _ -> malformed "'%s' is not a static argument." l

and read_valued r v : (Ast.expr, Ast.stmt) Ast.valued_block =
  { Ast.vb_stmts = read_list (read_stmt r) (field "stmts" v)
  ; vb_value = read_option (read_expr r) (field "value" v)
  }

and read_handler r v : Ast.stmt Ast.handler =
  { Ast.handled = read_name (field "handles" v)
  ; arms =
      read_list
        (fun a ->
          { Ast.arm_name = read_name (field "name" a)
          ; arm_kind = read_op_kind (field "kind" a)
          ; arm_params = read_list read_name (field "params" a)
          ; arm_body = read_list (read_stmt r) (field "body" a)
          })
        (field "arms" v)
  }

and read_clause r v : Ast.stmt Ast.handler_clause =
  match case v with
  | "Inline", [ h ] -> Ast.Inline (read_handler r h)
  | "Named", [ n ] -> Ast.Named (read_name n)
  | l, _ -> malformed "'%s' is not a handler." l

and read_stmt r v : Ast.stmt =
  let sp = read_span r (field "span" v) in
  let e = read_expr r in
  let s = read_stmt r in
  let ss = read_list s in
  let opt f x = read_option f x in
  match case (field "kind" v) with
  | "Declare", [ d ] -> read_decl r d
  | kind ->
    let it : Ast.stmt_kind =
      match kind with
      | "Expression", [ x ] -> `Expr (e x)
      | "Let", [ n; t; init ] -> `Var_decl (read_name n, opt (read_type r) t, opt e init)
      | "LetTuple", [ ns; init ] -> `Var_tuple (read_list read_name ns, e init)
      | "Block", [ body ] -> `Block (ss body)
      | "If", [ c; t; f ] -> `If (e c, s t, opt s f)
      | "While", [ c; body ] -> `While (e c, s body)
      | "For", [ init; c; step; body ] -> `For (opt s init, opt e c, opt e step, s body)
      | "ForIn", [ ns; over; body ] -> `For_in (read_list read_name ns, e over, s body)
      | "Return", [ x ] -> `Return (opt e x)
      | "Break", [] -> `Break
      | "Continue", [] -> `Continue
      | "Defer", [ body ] -> `Defer (s body)
      | "Match", [ x; arms ] ->
        `Match
          (e x, read_list (fun a -> read_pattern (field "pattern" a), ss (field "body" a)) arms)
      | "Run", [ body; clauses ] -> `Run (ss body, read_list (read_clause r) clauses)
      | "Resume", [ x ] -> `Resume (opt e x)
      | "Discontinue", [] -> `Discontinue
      | "Meta", [ body ] -> `Meta (ss body)
      | "Gen", [ inner ] -> `Gen (s inner)
      | "Derive", [ traits; target ] -> `Derive (read_list read_name traits, read_name target)
      | l, _ -> malformed "'%s' is not a statement." l
    in
    { Ast.it; span = sp; ann = () }

and read_decl r v : Ast.stmt =
  let sp = read_span r (field "span" v) in
  let attrs = read_list (read_attribute r) (field "attrs" v) in
  let ty = read_type r in
  let ss = read_list (read_stmt r) in
  let it : Ast.stmt_kind =
    match case (field "kind" v) with
    | "Fn", [ f ] ->
      `Fn
        ( read_name (field "name" f)
        , read_list (read_param r) (field "params" f)
        , read_signature r (field "signature" f)
        , ss (field "body" f) )
    | "Type", [ t ] -> read_type_decl r t
    | "TypeWithMembers", [ t; members ] ->
      `Type_members ({ Ast.it = read_type_decl r t; span = sp; ann = () }, ss members)
    | "Trait", [ t ] ->
      `Trait_decl
        ( read_name (field "name" t)
        , read_list read_name (field "params" t)
        , { Ast.tb_super = read_list (read_applied ty) (field "supers" t)
          ; tb_assoc =
              read_list
                (fun a ->
                  { Ast.ad_name = read_name (field "name" a)
                  ; ad_attrs = read_list (read_attribute r) (field "attrs" a)
                  })
                (field "assoc" t)
          ; tb_methods =
              read_list
                (fun m ->
                  { Ast.ms_name = read_name (field "name" m)
                  ; ms_params = read_list (read_param r) (field "params" m)
                  ; ms_signature = read_signature r (field "signature" m)
                  ; ms_attrs = read_list (read_attribute r) (field "attrs" m)
                  })
                (field "methods" t)
          } )
    | "Impl", [ i ] ->
      `Impl_decl
        ( read_option (read_applied ty) (field "implements" i)
        , read_name (field "target" i)
        , read_list (read_type_param r) (field "params" i)
        , { Ast.ib_assoc =
              read_list
                (fun a ->
                  { Ast.as_name = read_name (field "name" a)
                  ; as_ty = ty (field "ty" a)
                  ; as_attrs = read_list (read_attribute r) (field "attrs" a)
                  })
                (field "assoc" i)
          ; ib_methods =
              read_list
                (fun m ->
                  { Ast.md_name = read_name (field "name" m)
                  ; md_params = read_list (read_param r) (field "params" m)
                  ; md_signature = read_signature r (field "signature" m)
                  ; md_body = ss (field "body" m)
                  ; md_ann = ()
                  ; md_attrs = read_list (read_attribute r) (field "attrs" m)
                  })
                (field "methods" i)
          } )
    | "Effect", [ ef ] ->
      `Effect_decl
        ( read_name (field "name" ef)
        , read_list read_name (field "params" ef)
        , read_list
            (fun o ->
              { Ast.op_name = read_name (field "name" o)
              ; op_kind = read_op_kind (field "kind" o)
              ; op_tparams = read_list read_name (field "type_params" o)
              ; op_params = read_list (read_param r) (field "params" o)
              ; op_ret = read_option ty (field "ret" o)
              ; op_attrs = read_list (read_attribute r) (field "attrs" o)
              })
            (field "ops" ef) )
    | "Handler", [ n; h ] -> `Handler_decl (read_name n, read_handler r h)
    | "Import", [ i ] -> `Import (read_import i)
    | "GlobalImport", [ i ] -> `Global_import (read_import i)
    | l, _ -> malformed "'%s' is not a declaration." l
  in
  let inner = { Ast.it; span = sp; ann = () } in
  match attrs with
  | [] -> inner
  | attrs -> { Ast.it = `Attributed (attrs, inner); span = sp; ann = () }

and read_type_decl r t : Ast.stmt_kind =
  let ty = read_type r in
  let attrs = read_list (read_attribute r) in
  let body =
    match case (field "body" t) with
    | "Fields", [ fields ] ->
      Ast.T_fields
        (read_list
           (fun f ->
             { Ast.f_name = read_name (field "name" f)
             ; f_ty = ty (field "ty" f)
             ; f_attrs = attrs (field "attrs" f)
             })
           fields)
    | "Variants", [ variants ] ->
      Ast.T_variants
        (read_list
           (fun v ->
             let payload : Ast.type_expr Ast.payload =
               match case (field "payload" v) with
               | "None", [] -> Ast.P_none
               | "Positional", [ items ] -> Ast.P_tuple (read_list ty items)
               | "Named", [ fields ] -> Ast.P_fields (read_list (read_field_type r) fields)
               | l, _ -> malformed "'%s' is not a payload." l
             in
             { Ast.v_name = read_name (field "name" v)
             ; v_params = read_list read_name (field "params" v)
             ; v_payload = payload
             ; v_result = read_option ty (field "result" v)
             ; v_attrs = attrs (field "attrs" v)
             })
           variants)
    | l, _ -> malformed "'%s' is not a type body." l
  in
  `Type_decl (read_name (field "name" t), read_list (read_type_param r) (field "params" t), body)

(* ---- which kind a value is ---- *)

type kind =
  | Expr_node
  | Stmt_node
  | Decl_node
  | Type_node
  | Stmts

let kind_of (v : Value.value) =
  let is n t = String.equal t (Core.syntax n) in
  match v with
  | Value.Record (Some t, _) when is "Expr" t -> Some Expr_node
  | Value.Record (Some t, _) when is "Stmt" t -> Some Stmt_node
  | Value.Record (Some t, _) when is "Decl" t -> Some Decl_node
  | Value.Record (Some t, _) when is "TypeExpr" t -> Some Type_node
  | Value.Record (Some t, fields) when String.equal t Core.list ->
    (match List.assoc_opt "items" fields, List.assoc_opt "count" fields with
     | Some items, Some { contents = Value.Int count } when count > 0 ->
       (match !items with
        | Value.Array a ->
          (match a.(0) with
           | Value.Record (Some t, _) when is "Stmt" t -> Some Stmts
           | _ -> None)
        | _ -> None)
     | _ -> None)
  | _ -> None

let describe = function
  | Expr_node -> "an expression"
  | Stmt_node -> "a statement"
  | Decl_node -> "a declaration"
  | Type_node -> "a type"
  | Stmts -> "a list of statements"

let reader fallback = { fallback }
let to_expr ~fallback v = read_expr (reader fallback) v
let to_stmt ~fallback v = read_stmt (reader fallback) v
let to_decl ~fallback v = read_decl (reader fallback) v
let to_type ~fallback v = read_type (reader fallback) v
let to_stmts ~fallback v = read_list (read_stmt (reader fallback)) v
