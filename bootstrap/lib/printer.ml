(* S-expression dump of the parsed tree. *)

let string_of_binop = Ast.string_of_binop

let string_of_unop : Ast.unop -> string = function
  | Ast.Neg -> "-"
  | Ast.Not -> "!"
  | Ast.Bit_not -> "~"

let rec string_of_row entries =
  match entries with
  | [] -> ""
  | entries ->
    Printf.sprintf
      " <%s>"
      (String.concat ", " (List.map string_of_row_entry entries))

and string_of_row_entry (label, args) =
  match args with
  | [] -> label
  | args ->
    Printf.sprintf
      "%s<%s>"
      label
      (String.concat ", " (List.map string_of_type_expr args))

and string_of_type_expr (t : Ast.type_expr) : string =
  match t.Ast.it with
  | Ast.Ty_name name -> name
  | Ast.Ty_assoc (owner, member) -> string_of_type_expr owner ^ "." ^ member
  | Ast.Ty_bind (bound, t) -> bound ^ " = " ^ string_of_type_expr t
  | Ast.Ty_row row ->
    Printf.sprintf "<%s>" (String.concat ", " (List.map string_of_row_entry row))
  | Ast.Ty_variadic ({ Ast.it = Ast.Ty_spread _; _ } as held) -> string_of_type_expr held
  | Ast.Ty_variadic t -> "..." ^ string_of_type_expr t
  | Ast.Ty_spread t -> "..." ^ string_of_type_expr t
  | Ast.Ty_app (name, args) ->
    Printf.sprintf "%s<%s>" name (String.concat ", " (List.map string_of_type_expr args))
  | Ast.Ty_tuple items ->
    Printf.sprintf "(%s)" (String.concat ", " (List.map string_of_type_expr items))
  | Ast.Ty_record fields ->
    Printf.sprintf
      "{ %s }"
      (String.concat
         ", "
         (List.map (fun (l, t) -> l ^ ": " ^ string_of_type_expr t) fields))
  | Ast.Ty_fn (params, ret, row) ->
    Printf.sprintf
      "(%s) -> %s%s"
      (String.concat ", " (List.map string_of_type_expr params))
      (string_of_type_expr ret)
      (string_of_row row)

let annotation = function
  | None -> ""
  | Some t -> ": " ^ string_of_type_expr t

let string_of_param (p : Ast.param) = p.Ast.name ^ annotation p.Ast.ty

let rec string_of_expr (e : Ast.expr) : string =
  match e.Ast.it with
  | `Unit -> "()"
  | `Int n -> string_of_int n
  | `Bytes b -> Printf.sprintf "(bytes %d)" (String.length b)
  | `Float n -> Token.float_to_string n
  | `Str s -> Printf.sprintf "%S" (Utf8.encode s)
  | `Char c -> Printf.sprintf "'%s'" (Token.literal_to_string (Token.Char c))
  | `Bool b -> string_of_bool b
  | `Var name -> name
  | `Assign (name, v) -> Printf.sprintf "(set %s %s)" name (string_of_expr v)
  | `Compound (op, name, v) ->
    Printf.sprintf "(%s= %s %s)" (string_of_binop op) name (string_of_expr v)
  | `Compound_index (op, t, i, v) ->
    Printf.sprintf
      "(%s= (index %s %s) %s)"
      (string_of_binop op)
      (string_of_expr t)
      (string_of_expr i)
      (string_of_expr v)
  | `Compound_field (op, r, label, v) ->
    Printf.sprintf
      "(%s= (field %s %s) %s)"
      (string_of_binop op)
      (string_of_expr r)
      label
      (string_of_expr v)
  | `Unop (op, a) -> Printf.sprintf "(%s %s)" (string_of_unop op) (string_of_expr a)
  | `Binop (op, a, b) ->
    Printf.sprintf
      "(%s %s %s)"
      (string_of_binop op)
      (string_of_expr a)
      (string_of_expr b)
  | `Call (callee, args) ->
    Printf.sprintf
      "(call %s%s)"
      (string_of_expr callee)
      (String.concat "" (List.map (fun a -> " " ^ string_of_expr a) args))
  | `Static_call (callee, static_args, args) ->
    let static_arg = function
      | Ast.St_type t -> string_of_type_expr t
      | Ast.St_value v -> string_of_expr v
    in
    Printf.sprintf
      "(call %s<%s>%s)"
      (string_of_expr callee)
      (String.concat ", " (List.map static_arg static_args))
      (String.concat "" (List.map (fun a -> " " ^ string_of_expr a) args))
  | `Static_ref (callee, static_args) ->
    let static_arg = function
      | Ast.St_type t -> string_of_type_expr t
      | Ast.St_value v -> string_of_expr v
    in
    Printf.sprintf "%s<%s>" (string_of_expr callee) (String.concat ", " (List.map static_arg static_args))
  | `Method_call (receiver, name, _, args, _) ->
    Printf.sprintf
      "(. %s %s%s)"
      (string_of_expr receiver)
      name
      (String.concat "" (List.map (fun a -> " " ^ string_of_expr a) args))
  | `And (a, b) -> Printf.sprintf "(and %s %s)" (string_of_expr a) (string_of_expr b)
  | `Or (a, b) -> Printf.sprintf "(or %s %s)" (string_of_expr a) (string_of_expr b)
  | `Typeof e -> Printf.sprintf "(typeof %s)" (string_of_expr e)
  | `Declof (e, None) -> Printf.sprintf "(declof %s)" (string_of_expr e)
  | `Declof (e, Some static_args) ->
    let static_arg = function
      | Ast.St_type t -> string_of_type_expr t
      | Ast.St_value v -> string_of_expr v
    in
    Printf.sprintf
      "(declof %s<%s>)"
      (string_of_expr e)
      (String.concat ", " (List.map static_arg static_args))
  | `Meta_expr _ -> "(meta { ... })"
  | `Code e -> Printf.sprintf "(code %s)" (string_of_expr e)
  | `Code_stmts _ -> "(code { ... })"
  | `Code_decl _ -> "(code decl)"
  | `Lambda (params, _, _) ->
    Printf.sprintf "(fn (%s) ...)" (String.concat " " (List.map string_of_param params))
  | `Match_expr (scrutinee, _) -> Printf.sprintf "(match %s ...)" (string_of_expr scrutinee)
  | `Run_expr (ret, _, handlers) ->
    Printf.sprintf
      "(run%s ...%s)"
      (match ret with
       | None -> ""
       | Some t -> "<" ^ string_of_type_expr t ^ ">")
      (String.concat "" (List.map clause_label handlers))
  | `Name n -> n
  | `Collection_lit items ->
    Printf.sprintf "[%s]" (String.concat " " (List.map string_of_expr items))
  | `Tuple items ->
    Printf.sprintf "(tuple %s)" (String.concat " " (List.map string_of_expr items))
  | `Tuple_get (t, i) -> Printf.sprintf "(get %s %d)" (string_of_expr t) i
  | `Spread inner -> Printf.sprintf "(spread %s)" (string_of_expr inner)
  | `Record_lit fields ->
    Printf.sprintf
      "{%s}"
      (String.concat " " (List.map (fun (l, v) -> l ^ ":" ^ string_of_expr v) fields))
  | `Field (r, label) -> Printf.sprintf "(field %s %s)" (string_of_expr r) label
  | `Field_assign (r, label, v) ->
    Printf.sprintf "(field-set %s %s %s)" (string_of_expr r) label (string_of_expr v)
  | `New_call (name, _, args) ->
    Printf.sprintf
      "(new %s%s)"
      name
      (String.concat "" (List.map (fun a -> " " ^ string_of_expr a) args))
  | `New (name, fields) | `New_generic (name, _, fields) ->
    Printf.sprintf
      "(new %s%s)"
      name
      (String.concat "" (List.map (fun (l, v) -> " " ^ l ^ ":" ^ string_of_expr v) fields))
  | `New_variant (ty, variant, payload) ->
    Printf.sprintf
      "(new %s.%s%s)"
      ty
      variant
      (String.concat
         ""
         (List.map (fun (_, v) -> " " ^ string_of_expr v) (Ast.payload_fields payload)))
  | `Index (t, i) -> Printf.sprintf "(index %s %s)" (string_of_expr t) (string_of_expr i)
  | `Index_assign (t, i, v) ->
    Printf.sprintf
      "(index-set %s %s %s)"
      (string_of_expr t)
      (string_of_expr i)
      (string_of_expr v)

and clause_label (c : Ast.stmt Ast.handler_clause) =
  match c with
  | Ast.Named name -> " with " ^ name
  | Ast.Handle (handled, _) -> " handle<" ^ string_of_type_expr handled ^ ">"
  | Ast.Bound (label, handler, _) -> " bound " ^ label ^ " = " ^ handler

let opt_expr = function
  | None -> "_"
  | Some e -> string_of_expr e

let rec write_stmt buf indent (s : Ast.stmt) =
  let line fmt = Printf.ksprintf (fun str -> Buffer.add_string buf str) fmt in
  let pad = String.make (indent * 2) ' ' in
  let nested label body =
    line "%s(%s\n" pad label;
    List.iter (write_stmt buf (indent + 1)) body;
    line "%s)\n" pad
  in
  match s.Ast.it with
  | `Attributed (list, inner) ->
    nested
      (String.concat " " (List.map (fun (a : Ast.attr) -> "@" ^ a.Ast.a_name) list))
      [ inner ]
  | `Expr e -> line "%s%s\n" pad (string_of_expr e)
  | `Defer s -> nested "defer" [ s ]
  | `Meta body -> nested "meta" body
  | `Gen inner -> nested "gen" [ inner ]
  | `Type_members (decl, members) -> nested "type members" (decl :: members)
  | `Trait_members (decl, metas) -> nested "trait members" (decl :: metas)
  | `Derive (traits, ty) ->
    line "%s(derive %s for %s)\n" pad (String.concat ", " traits) ty
  | (`Import decl | `Global_import decl) as s ->
    let shown =
      match decl with
      | Ast.Qualified path -> Printf.sprintf "%S" path
      | Ast.Aliased (path, alias) -> Printf.sprintf "%S as %s" path alias
      | Ast.Selective (names, path) ->
        Printf.sprintf "{%s} from %S" (String.concat " " names) path
      | Ast.Wildcard dir -> Printf.sprintf "%S/*" dir
    in
    let kind =
      match s with
      | `Global_import _ -> "global import"
      | `Import _ -> "import"
    in
    line "%s(%s %s)\n" pad kind shown
  | `Var_tuple (names, init) ->
    line "%s(var (%s) %s)\n" pad (String.concat " " names) (string_of_expr init)
  | `Var_decl (name, ty, init) ->
    line "%s(var %s%s %s)\n" pad name (annotation ty) (opt_expr init)
  | `Block body -> nested "block" body
  | `If (cond, then_branch, else_branch) ->
    nested
      (Printf.sprintf "if %s" (string_of_expr cond))
      (then_branch :: Option.to_list else_branch)
  | `While (cond, body) -> nested (Printf.sprintf "while %s" (string_of_expr cond)) [ body ]
  | `Fn (name, params, signature, body) ->
    nested
      (Printf.sprintf
         "fn %s (%s)%s%s"
         name
         (String.concat " " (List.map string_of_param params))
         (match signature.Ast.ret with
          | None -> ""
          | Some t -> " -> " ^ string_of_type_expr t)
         (match signature.Ast.row with
          | None -> ""
          | Some labels -> string_of_row labels))
      body
  | `Return value -> line "%s(return %s)\n" pad (opt_expr value)
  | `Break -> line "%s(break)\n" pad
  | `Continue -> line "%s(continue)\n" pad
  | `For_in (names, iterable, body) ->
    nested
      (Printf.sprintf "for %s in %s" (String.concat ", " names) (string_of_expr iterable))
      [ body ]
  | `Type_decl (name, params, body) ->
    line
      "%s(type %s%s%s)\n"
      pad
      name
      (match params with
       | [] -> ""
       | params ->
         Printf.sprintf
           "<%s>"
           (String.concat
              ", "
              (List.map
                 (fun (p : Ast.type_param) ->
                   (if p.Ast.tp_pack then "..." else "") ^ p.Ast.tp_name)
                 params)))
      (match body with
       | Ast.T_fields fields ->
         String.concat "" (List.map (fun (f : Ast.field) -> " " ^ f.Ast.f_name) fields)
       | Ast.T_variants variants ->
         String.concat "" (List.map (fun (v : Ast.variant) -> " " ^ v.Ast.v_name) variants))
  | `Match (scrutinee, cases) ->
    nested
      (Printf.sprintf "match %s" (string_of_expr scrutinee))
      (List.concat_map snd cases)
  | `Trait_decl (name, _, body) ->
    line
      "%s(trait %s%s%s)\n"
      pad
      name
      (String.concat "" (List.map (fun (a : Ast.assoc_decl) -> " type " ^ a.Ast.ad_name) body.Ast.tb_assoc))
      (String.concat
         ""
         (List.map (fun (m : Ast.method_sig) -> " " ^ m.Ast.ms_name) body.Ast.tb_methods))
  | `Impl_decl (trait, type_name, _, impl) ->
    nested
      (match trait with
       | Some (trait, _) -> Printf.sprintf "impl %s for %s" trait type_name
       | None -> Printf.sprintf "impl %s" type_name)
      (List.concat_map
         (fun (m : (Ast.stmt, unit) Ast.method_def) -> m.Ast.md_body)
         impl.Ast.ib_methods)

let string_of_program (program : Ast.program) : string =
  let buf = Buffer.create 256 in
  List.iter (write_stmt buf 0) program;
  Buffer.contents buf

(* ---- processed dump ---- *)

let rec string_of_processed_expr (e : Ast.resolved_expr) : string =
  let ty = Types.string_of_ty e.Ast.ann in
  let body =
    match e.Ast.it with
    | `Unit -> "()"
    | `Int n -> string_of_int n
    | `Bytes b -> Printf.sprintf "(bytes %d)" (String.length b)
    | `Lambda (params, _, _) ->
      Printf.sprintf "(fn (%s) ...)" (String.concat " " (List.map string_of_param params))
    | `Name n -> n
    | `Float n -> Token.float_to_string n
    | `Str s -> Printf.sprintf "%S" (Utf8.encode s)
    | `Char c -> Printf.sprintf "'%s'" (Token.literal_to_string (Token.Char c))
    | `Bool b -> string_of_bool b
    | `Var name -> name
    | `Assign (name, v) -> Printf.sprintf "(set %s %s)" name (string_of_processed_expr v)
    | `Unop (op, a) ->
      Printf.sprintf "(%s %s)" (string_of_unop op) (string_of_processed_expr a)
    | `Binop (op, a, b) ->
      Printf.sprintf
        "(%s %s %s)"
        (string_of_binop op)
        (string_of_processed_expr a)
        (string_of_processed_expr b)
    | `Call (callee, args) ->
      Printf.sprintf
        "(call %s%s)"
        (string_of_processed_expr callee)
        (String.concat "" (List.map (fun a -> " " ^ string_of_processed_expr a) args))
    | `And (a, b) ->
      Printf.sprintf "(and %s %s)" (string_of_processed_expr a) (string_of_processed_expr b)
    | `Or (a, b) ->
      Printf.sprintf "(or %s %s)" (string_of_processed_expr a) (string_of_processed_expr b)
    | `Dyn_call (receiver, name, _, args) ->
      Printf.sprintf
        "(dyn. %s %s%s)"
        (string_of_processed_expr receiver)
        name
        (String.concat "" (List.map (fun a -> " " ^ string_of_processed_expr a) args))
    | `Tuple items ->
      Printf.sprintf
        "(tuple %s)"
        (String.concat " " (List.map string_of_processed_expr items))
    | `Tuple_get (t, i) -> Printf.sprintf "(get %s %d)" (string_of_processed_expr t) i
    | `Record_lit fields ->
      Printf.sprintf
        "{%s}"
        (String.concat
           " "
           (List.map (fun (l, v) -> l ^ ":" ^ string_of_processed_expr v) fields))
    | `Field (r, label) ->
      Printf.sprintf "(field %s %s)" (string_of_processed_expr r) label
    | `Field_assign (r, label, v) ->
      Printf.sprintf
        "(field-set %s %s %s)"
        (string_of_processed_expr r)
        label
        (string_of_processed_expr v)
    | `Array_lit items ->
      Printf.sprintf
        "(array %s)"
        (String.concat " " (List.map string_of_processed_expr items))
    | `Array_new (length, fill) ->
      Printf.sprintf
        "(array-new %s %s)"
        (string_of_processed_expr length)
        (string_of_processed_expr fill)
    | `Array_get (t, i) ->
      Printf.sprintf "(array-get %s %s)" (string_of_processed_expr t) (string_of_processed_expr i)
    | `Array_set (t, i, v) ->
      Printf.sprintf
        "(array-set %s %s %s)"
        (string_of_processed_expr t)
        (string_of_processed_expr i)
        (string_of_processed_expr v)
    | `Array_len t -> Printf.sprintf "(array-len %s)" (string_of_processed_expr t)
    | `Str_get (t, i) ->
      Printf.sprintf "(str-get %s %s)" (string_of_processed_expr t) (string_of_processed_expr i)
    | `Str_len t -> Printf.sprintf "(str-len %s)" (string_of_processed_expr t)
    | `Variant (variant, fields) ->
      Printf.sprintf
        "(variant %s%s)"
        variant
        (String.concat "" (List.map (fun (l, v) -> Printf.sprintf " (%s %s)" l (string_of_processed_expr v)) fields))
    | `Object (data, _, slots) ->
      Printf.sprintf
        "(object %s%s)"
        (string_of_processed_expr data)
        (String.concat "" (List.map (fun (l, v) -> Printf.sprintf " (%s %s)" l (string_of_processed_expr v)) slots))
  in
  Printf.sprintf "%s:%s" body ty

let opt_processed_expr = function
  | None -> "_"
  | Some e -> string_of_processed_expr e

let rec write_processed_stmt buf indent (s : Ast.resolved_stmt) =
  let line fmt = Printf.ksprintf (fun str -> Buffer.add_string buf str) fmt in
  let pad = String.make (indent * 2) ' ' in
  let nested label body =
    line "%s(%s\n" pad label;
    List.iter (write_processed_stmt buf (indent + 1)) body;
    line "%s)\n" pad
  in
  match s.Ast.it with
  | `Expr e -> line "%s%s\n" pad (string_of_processed_expr e)
  | `Var_tuple (names, init) ->
    line "%s(var (%s) %s)\n" pad (String.concat " " names) (string_of_processed_expr init)
  | `Defer s -> line "%s(defer …)\n" pad; ignore s
  | `Var_decl (name, _, init) -> line "%s(var %s %s)\n" pad name (opt_processed_expr init)
  | `Block body -> nested "block" body
  | `If (cond, then_branch, else_branch) ->
    nested
      (Printf.sprintf "if %s" (string_of_processed_expr cond))
      (then_branch :: Option.to_list else_branch)
  | `While (cond, body) ->
    nested (Printf.sprintf "while %s" (string_of_processed_expr cond)) [ body ]
  | `Fn (name, params, _, body) ->
    nested
      (Printf.sprintf
         "fn %s (%s)"
         name
         (String.concat " " (List.map (fun (p : Ast.param) -> p.Ast.name) params)))
      body
  | `Return value -> line "%s(return %s)\n" pad (opt_processed_expr value)
  | `Break -> line "%s(break)\n" pad
  | `Continue -> line "%s(continue)\n" pad
  | `Type_decl (name, _, _) -> line "%s(type %s)\n" pad name
  | `Match (scrutinee, cases) ->
    nested
      (Printf.sprintf "match %s" (string_of_processed_expr scrutinee))
      (List.concat_map snd cases)

let string_of_processed_program (program : Ast.resolved_stmt list) : string =
  let buf = Buffer.create 256 in
  List.iter (write_processed_stmt buf 0) program;
  Buffer.contents buf
