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
    ; "inline", bool sg.Ast.inline
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

(* The type each expression was checked at, which only code [processed]
   hands back carries. *)
let typer : (Ast.expr -> Ast.type_expr option) ref = ref (fun _ -> None)

(* What processed code shows in a run's place: the run it was lowered to. *)
let expansion : (Ast.expr -> Ast.expr option) ref = ref (fun _ -> None)

(* While processed code is shown: the code a pass-through was checked from,
   shown in its place; what a meta block generated, shown in the block's place;
   and the pass-through a statement was checked to, if it can be one. *)
let viewed : (int -> [ `Expr of Ast.expr | `Stmt of Ast.stmt | `Stmts of Ast.stmt list ] option) ref =
  ref (fun _ -> None)
let generated : (Ast.stmt -> Ast.stmt list option) ref = ref (fun _ -> None)
let kept : (Ast.stmt -> int option) ref = ref (fun _ -> None)

(* Each node processed code handed out that the checker can pass through, by
   the node's identity, with its kind as handed out: one handed back as it was
   given is passed through rather than read. Only the node's own kind is
   compared, which holds because a transform builds what it changes rather than
   assigning into a node it was handed. *)
module Handed = Hashtbl.Make (struct
    type t = Value.value

    let equal = ( == )

    let hash (v : Value.value) =
      match v with
      | Value.Record (_, fields) ->
        (match List.assoc_opt "span" fields with
         | Some { contents = Value.Span s } -> Hashtbl.hash (Source_map.Span.offsets s)
         | _ -> 0)
      | _ -> 0
  end)

let handed : (Value.value * int) Handed.t = Handed.create 64

let hand_out (v : Value.value) n =
  match v with
  | Value.Record (_, fields) ->
    (match List.assoc_opt "kind" fields with
     | Some kind -> Handed.replace handed v (!kind, n)
     | None -> ())
  | _ -> ()

let handed_back (v : Value.value) =
  match Handed.find_opt handed v, v with
  | Some (kind, n), Value.Record (_, fields) ->
    (match List.assoc_opt "kind" fields with
     | Some current when !current == kind -> Some n
     | _ -> None)
  | _ -> None

let rec shown_stmts (body : Ast.stmt list) =
  List.concat_map
    (fun (s : Ast.stmt) ->
      match s.Ast.it, !generated s with
      | `Pre_checked n, _ ->
        (match !viewed n with
         | Some (`Stmts body) -> shown_stmts body
         | _ -> [ s ])
      | _, Some made -> shown_stmts made
      | _, None -> [ s ])
    body

let rec expr (e : Ast.expr) : Value.value =
  match e.Ast.it, !expansion e with
  | `Pre_checked n, _ ->
    (match !viewed n with
     | Some (`Expr v) ->
       let shown = expr v in
       hand_out shown n;
       shown
     | _ ->
       record
         "Expr"
         [ "kind", variant "ExprKind" "Processed" [ int n ]; "span", span e.Ast.span; "ty", option type_expr None ])
  | _, Some lowered -> expr lowered
  | _, None -> written_expr e

and written_expr (e : Ast.expr) : Value.value =
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
    | `Method_call (receiver, n, _, args, _) -> k "MethodCall" [ expr receiver; name n; list expr args ]
    | `Static_call (f, static_args, args) ->
      k "StaticCall" [ expr f; list static_arg static_args; list expr args ]
    | `Static_ref (f, static_args) -> k "StaticRef" [ expr f; list static_arg static_args ]
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
    | `Lambda (params, sg, body) -> k "Lambda" [ list param params; signature sg; stmts body ]
    | `Run_expr (ty, body, clauses) ->
      k "Run" [ option type_expr ty; valued_block body; list handler_clause clauses ]
    | `Match_expr (scrutinee, arms) ->
      k
        "Match"
        [ expr scrutinee
        ; list
            (fun (p, b) -> record "ValuedArm" [ "pattern", pattern p; "body", valued_block b ])
            arms
        ]
    | `Typeof inner -> k "Typeof" [ expr inner ]
    | `Declof (inner, static_args) -> k "Declof" [ expr inner; option (list static_arg) static_args ]
    | `Meta_expr body -> k "Meta" [ list stmt body ]
    | `Code inner -> k "QuoteExpr" [ expr inner ]
    | `Code_stmts body -> k "QuoteStmts" [ list stmt body ]
    | `Code_decl d -> k "QuoteDecl" [ decl d ]
    | `Pre_checked n -> k "Processed" [ int n ]
  in
  record "Expr" [ "kind", kind; "span", span e.Ast.span; "ty", option type_expr (!typer e) ]

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
  record "ValuedBlock" [ "stmts", stmts b.Ast.vb_stmts; "value", option expr b.Ast.vb_value ]

and handler_clause (c : Ast.stmt Ast.handler_clause) =
  match c with
  | Ast.Named n -> variant "HandlerClause" "Named" [ name n ]
  | Ast.Handle (t, defs) -> variant "HandlerClause" "Handle" [ type_expr t; list method_def defs ]
  | Ast.Bound (label, handler, value) -> variant "HandlerClause" "Bound" [ name label; name handler; option stmt value ]

and stmts (body : Ast.stmt list) = list stmt (shown_stmts body)

and stmt (s : Ast.stmt) : Value.value =
  match s.Ast.it, !generated s with
  | `Pre_checked n, _ ->
    (match !viewed n with
     | Some (`Stmt v) ->
       let shown = stmt v in
       hand_out shown n;
       shown
     | Some (`Stmts body) -> node "Stmt" (variant "StmtKind" "Block" [ stmts body ]) s.Ast.span
     | _ -> node "Stmt" (variant "StmtKind" "Processed" [ int n ]) s.Ast.span)
  | _, Some made -> node "Stmt" (variant "StmtKind" "Block" [ stmts made ]) s.Ast.span
  | _, None ->
    let shown = written_stmt s in
    Option.iter (hand_out shown) (!kept s);
    shown

and written_stmt (s : Ast.stmt) : Value.value =
  let k label values = variant "StmtKind" label values in
  let kind =
    match s.Ast.it with
    | `Expr e -> k "Expression" [ expr e ]
    | `Var_decl (n, t, init) -> k "Let" [ name n; option type_expr t; option expr init ]
    | `Var_tuple (names, init) -> k "LetTuple" [ list name names; expr init ]
    | `Block body -> k "Block" [ stmts body ]
    | `If (c, t, e) -> k "If" [ expr c; stmt t; option stmt e ]
    | `While (c, body) -> k "While" [ expr c; stmt body ]
    | `For_in (names, over, body) -> k "ForIn" [ list name names; expr over; stmt body ]
    | `Return e -> k "Return" [ option expr e ]
    | `Break -> k "Break" []
    | `Continue -> k "Continue" []
    | `Defer body -> k "Defer" [ stmt body ]
    | `Match (scrutinee, arms) ->
      k
        "Match"
        [ expr scrutinee
        ; list (fun (p, body) -> record "MatchArm" [ "pattern", pattern p; "body", stmts body ]) arms
        ]
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
            [ "name", name n; "params", list param params; "signature", signature sg; "body", stmts body ]
        ]
    | `Type_decl (n, params, body) -> k "Type" [ type_decl n params body ]
    | `Type_members ({ Ast.it = `Type_decl (n, params, body); _ }, members) ->
      k "TypeWithMembers" [ type_decl n params body; list stmt members ]
    | `Trait_decl (n, params, body) -> k "Trait" [ trait_decl n params body ]
    | `Trait_members ({ Ast.it = `Trait_decl (n, params, body); _ }, metas) ->
      k "TraitWithMembers" [ trait_decl n params body; list stmt metas ]
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

and trait_decl n params (body : Ast.trait_body) =
  record
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
  ; inline = read_bool (field "inline" v)
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
  match handed_back v with
  | Some n -> { Ast.it = `Pre_checked n; span = read_span r (field "span" v); ann = () }
  | None -> read_written_expr r v

and read_written_expr r v : Ast.expr =
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
      `Method_call (e recv, n, n, es a, None)
    | "StaticCall", [ f; sa; a ] -> `Static_call (e f, read_list (read_static_arg r) sa, es a)
    | "StaticRef", [ f; sa ] -> `Static_ref (e f, read_list (read_static_arg r) sa)
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
    | "Run", [ ty; body; clauses ] ->
      `Run_expr (read_option (read_type r) ty, read_valued r body, read_list (read_clause r) clauses)
    | "Match", [ x; arms ] ->
      `Match_expr
        ( e x
        , read_list
            (fun a -> read_pattern (field "pattern" a), read_valued r (field "body" a))
            arms )
    | "Typeof", [ x ] -> `Typeof (e x)
    | "Declof", [ x; sa ] -> `Declof (e x, read_option (read_list (read_static_arg r)) sa)
    | "Meta", [ body ] -> `Meta_expr (read_list s body)
    | "QuoteExpr", [ x ] -> `Code (e x)
    | "QuoteStmts", [ body ] -> `Code_stmts (read_list s body)
    | "QuoteDecl", [ d ] -> `Code_decl (read_decl r d)
    | "Processed", [ n ] -> `Pre_checked (read_int n)
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

and read_clause r v : Ast.stmt Ast.handler_clause =
  match case v with
  | "Named", [ n ] -> Ast.Named (read_name n)
  | "Handle", [ t; defs ] -> Ast.Handle (read_type r t, read_list (read_method_def r) defs)
  | "Bound", [ label; handler; value ] ->
    Ast.Bound (read_name label, read_name handler, read_option (read_stmt r) value)
  | l, _ -> malformed "'%s' is not a handler." l

and read_stmt r v : Ast.stmt =
  match handed_back v with
  | Some n -> { Ast.it = `Pre_checked n; span = read_span r (field "span" v); ann = () }
  | None -> read_written_stmt r v

and read_written_stmt r v : Ast.stmt =
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
      | "For", [ init; c; step; body ] -> (Lower.c_for sp (opt s init) (opt e c) (opt e step) (s body)).Ast.it
      | "ForIn", [ ns; over; body ] -> `For_in (read_list read_name ns, e over, s body)
      | "Return", [ x ] -> `Return (opt e x)
      | "Break", [] -> `Break
      | "Continue", [] -> `Continue
      | "Defer", [ body ] -> `Defer (s body)
      | "Match", [ x; arms ] ->
        `Match
          (e x, read_list (fun a -> read_pattern (field "pattern" a), ss (field "body" a)) arms)
      | "Meta", [ body ] -> `Meta (ss body)
      | "Gen", [ inner ] -> `Gen (s inner)
      | "Derive", [ traits; target ] -> `Derive (read_list read_name traits, read_name target)
      | "Processed", [ n ] -> `Pre_checked (read_int n)
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
    | "Trait", [ t ] -> read_trait_decl r t
    | "TraitWithMembers", [ t; metas ] ->
      `Trait_members ({ Ast.it = read_trait_decl r t; span = sp; ann = () }, ss metas)
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
          ; ib_methods = read_list (read_method_def r) (field "methods" i)
          } )
    | "Import", [ i ] -> `Import (read_import i)
    | "GlobalImport", [ i ] -> `Global_import (read_import i)
    | l, _ -> malformed "'%s' is not a declaration." l
  in
  let inner = { Ast.it; span = sp; ann = () } in
  match attrs with
  | [] -> inner
  | attrs -> { Ast.it = `Attributed (attrs, inner); span = sp; ann = () }

and read_trait_decl r t : Ast.stmt_kind =
  `Trait_decl
    ( read_name (field "name" t)
    , read_list read_name (field "params" t)
    , { Ast.tb_super = read_list (read_applied (read_type r)) (field "supers" t)
      ; tb_assoc =
          read_list
            (fun a ->
              { Ast.ad_name = read_name (field "name" a)
              ; ad_attrs = read_list (read_attribute r) (field "attrs" a)
              })
            (field "assoc" t)
      ; tb_methods = read_list (read_method_sig r) (field "methods" t)
      } )

and read_method_sig r m : Ast.method_sig =
  { Ast.ms_name = read_name (field "name" m)
  ; ms_params = read_list (read_param r) (field "params" m)
  ; ms_signature = read_signature r (field "signature" m)
  ; ms_attrs = read_list (read_attribute r) (field "attrs" m)
  }

and read_method_def r m : (Ast.stmt, unit) Ast.method_def =
  { Ast.md_name = read_name (field "name" m)
  ; md_params = read_list (read_param r) (field "params" m)
  ; md_signature = read_signature r (field "signature" m)
  ; md_body = read_list (read_stmt r) (field "body" m)
  ; md_ann = ()
  ; md_attrs = read_list (read_attribute r) (field "attrs" m)
  }

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
  | Sig_node
  | Stmts

let kind_of (v : Value.value) =
  let is n t = String.equal t (Core.syntax n) in
  match v with
  | Value.Record (Some t, _) when is "Expr" t -> Some Expr_node
  | Value.Record (Some t, _) when is "Stmt" t -> Some Stmt_node
  | Value.Record (Some t, _) when is "Decl" t -> Some Decl_node
  | Value.Record (Some t, _) when is "TypeExpr" t -> Some Type_node
  | Value.Record (Some t, _) when is "MethodSig" t -> Some Sig_node
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
  | Sig_node -> "a method signature"
  | Stmts -> "a list of statements"

let reader fallback = { fallback }
let to_expr ~fallback v = read_expr (reader fallback) v
let to_stmt ~fallback v = read_stmt (reader fallback) v
let to_decl ~fallback v = read_decl (reader fallback) v
let to_type ~fallback v = read_type (reader fallback) v
let to_method_sig ~fallback v = read_method_sig (reader fallback) v

let to_stmts ~fallback v = read_list (read_stmt (reader fallback)) v
