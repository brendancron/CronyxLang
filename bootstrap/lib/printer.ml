(* S-expression dump of the parsed tree. *)

let string_of_binop = Ast.string_of_binop

let string_of_unop : Ast.unop -> string = function
  | Ast.Neg -> "-"
  | Ast.Not -> "!"

let string_of_row = function
  | [] -> ""
  | labels -> Printf.sprintf " <%s>" (String.concat ", " labels)

let rec string_of_type_expr (t : Ast.type_expr) : string =
  match t.Ast.it with
  | Ast.Ty_name name -> name
  | Ast.Ty_assoc (owner, member) -> string_of_type_expr owner ^ "." ^ member
  | Ast.Ty_bind (bound, t) -> bound ^ " = " ^ string_of_type_expr t
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
  | `Comptime_call (callee, comptime_args, args) ->
    let comptime = function
      | Ast.Ct_type t -> string_of_type_expr t
      | Ast.Ct_value v -> string_of_expr v
    in
    Printf.sprintf
      "(call %s<%s>%s)"
      (string_of_expr callee)
      (String.concat ", " (List.map comptime comptime_args))
      (String.concat "" (List.map (fun a -> " " ^ string_of_expr a) args))
  | `Method_call (receiver, name, _, args) ->
    Printf.sprintf
      "(. %s %s%s)"
      (string_of_expr receiver)
      name
      (String.concat "" (List.map (fun a -> " " ^ string_of_expr a) args))
  | `And (a, b) -> Printf.sprintf "(and %s %s)" (string_of_expr a) (string_of_expr b)
  | `Or (a, b) -> Printf.sprintf "(or %s %s)" (string_of_expr a) (string_of_expr b)
  | `Typeof e -> Printf.sprintf "(typeof %s)" (string_of_expr e)
  | `Code e -> Printf.sprintf "(code %s)" (string_of_expr e)
  | `Lambda (params, _, _) ->
    Printf.sprintf "(fn (%s) ...)" (String.concat " " (List.map string_of_param params))
  | `Run_expr (_, handlers, _) ->
    Printf.sprintf
      "(run ...%s)"
      (String.concat
         ""
         (List.map
            (function
              | Ast.Inline h -> " handle " ^ h.Ast.handled
              | Ast.Named name -> " with " ^ name)
            handlers))
  | `Name n -> n
  | `Collection_lit items ->
    Printf.sprintf "[%s]" (String.concat " " (List.map string_of_expr items))
  | `Tuple items ->
    Printf.sprintf "(tuple %s)" (String.concat " " (List.map string_of_expr items))
  | `Tuple_get (t, i) -> Printf.sprintf "(get %s %d)" (string_of_expr t) i
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
  | `New (name, fields) ->
    Printf.sprintf
      "(new %s%s)"
      name
      (String.concat "" (List.map (fun (l, v) -> " " ^ l ^ ":" ^ string_of_expr v) fields))
  | `New_variant (ty, variant, payload) ->
    Printf.sprintf
      "(new %s::%s%s)"
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
  | `Derive (traits, ty) ->
    line "%s(derive %s for %s)\n" pad (String.concat ", " traits) ty
  | `Meta_fn (name, params, _, body) ->
    nested
      (Printf.sprintf "meta fn %s (%s)" name (String.concat " " (List.map string_of_param params)))
      body
  | `Import decl ->
    let shown =
      match decl with
      | Ast.Qualified path -> Printf.sprintf "%S" path
      | Ast.Aliased (path, alias) -> Printf.sprintf "%S as %s" path alias
      | Ast.Selective (names, path) ->
        Printf.sprintf "{%s} from %S" (String.concat " " names) path
      | Ast.Wildcard dir -> Printf.sprintf "%S/*" dir
    in
    line "%s(import %s)\n" pad shown
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
  | `For_in (names, iterable, body) ->
    nested
      (Printf.sprintf "for %s in %s" (String.concat ", " names) (string_of_expr iterable))
      [ body ]
  | `For (init, cond, step, body) ->
    line "%s(for %s %s\n" pad (opt_expr cond) (opt_expr step);
    List.iter (write_stmt buf (indent + 1)) (Option.to_list init @ [ body ]);
    line "%s)\n" pad
  | `Effect_decl (name, _, ops) ->
    line
      "%s(effect %s%s)\n"
      pad
      name
      (String.concat "" (List.map (fun (o : Ast.op_decl) -> " " ^ o.Ast.op_name) ops))
  | `Run (body, handlers) ->
    let label (c : Ast.stmt Ast.handler_clause) =
      match c with
      | Ast.Inline h -> " handle " ^ h.Ast.handled
      | Ast.Named name -> " with " ^ name
    in
    let arms (c : Ast.stmt Ast.handler_clause) =
      match c with
      | Ast.Inline h -> List.concat_map (fun a -> a.Ast.arm_body) h.Ast.arms
      | Ast.Named _ -> []
    in
    nested
      (Printf.sprintf "run%s" (String.concat "" (List.map label handlers)))
      (body @ List.concat_map arms handlers)
  | `Resume value -> line "%s(resume %s)\n" pad (opt_expr value)
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
  | `Handler_decl (name, h) ->
    nested
      (Printf.sprintf "handler %s : %s" name h.Ast.handled)
      (List.concat_map (fun a -> a.Ast.arm_body) h.Ast.arms)
  | `Trait_decl (name, _, body) ->
    line
      "%s(trait %s%s%s)\n"
      pad
      name
      (String.concat "" (List.map (fun a -> " type " ^ a) body.Ast.tb_assoc))
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

(* ---- typed dump ---- *)

let rec string_of_typed_expr (e : Ast.typed_expr) : string =
  let ty = Types.string_of_ty e.Ast.ann in
  let body =
    match e.Ast.it with
    | `Unit -> "()"
    | `Int n -> string_of_int n
    | `Bytes b -> Printf.sprintf "(bytes %d)" (String.length b)
    | `Lambda (params, _, _) ->
      Printf.sprintf "(fn (%s) ...)" (String.concat " " (List.map string_of_param params))
    | `Run_expr (_, handlers, _) ->
      Printf.sprintf
        "(run ...%s)"
        (String.concat
           ""
           (List.map (fun (h : Ast.typed_stmt Ast.handler) -> " handle " ^ h.Ast.handled) handlers))
    | `Name n -> n
    | `Float n -> Token.float_to_string n
    | `Str s -> Printf.sprintf "%S" (Utf8.encode s)
    | `Char c -> Printf.sprintf "'%s'" (Token.literal_to_string (Token.Char c))
    | `Bool b -> string_of_bool b
    | `Var name -> name
    | `Assign (name, v) -> Printf.sprintf "(set %s %s)" name (string_of_typed_expr v)
    | `Unop (op, a) ->
      Printf.sprintf "(%s %s)" (string_of_unop op) (string_of_typed_expr a)
    | `Binop (op, a, b) ->
      Printf.sprintf
        "(%s %s %s)"
        (string_of_binop op)
        (string_of_typed_expr a)
        (string_of_typed_expr b)
    | `Call (callee, args) ->
      Printf.sprintf
        "(call %s%s)"
        (string_of_typed_expr callee)
        (String.concat "" (List.map (fun a -> " " ^ string_of_typed_expr a) args))
    | `And (a, b) ->
      Printf.sprintf "(and %s %s)" (string_of_typed_expr a) (string_of_typed_expr b)
    | `Or (a, b) ->
      Printf.sprintf "(or %s %s)" (string_of_typed_expr a) (string_of_typed_expr b)
    | `Compound (op, name, v) ->
      Printf.sprintf "(%s= %s %s)" (string_of_binop op) name (string_of_typed_expr v)
    | `Method_call (receiver, name, as_function, args) ->
      Printf.sprintf
        "(. %s %s%s)"
        (string_of_typed_expr receiver)
        name
        (String.concat "" (List.map (fun a -> " " ^ string_of_typed_expr a) args))
    | `Typeof e -> Printf.sprintf "(typeof %s)" (string_of_typed_expr e)
    | `Collection_lit items ->
      Printf.sprintf "[%s]" (String.concat " " (List.map string_of_typed_expr items))
    | `Tuple items ->
      Printf.sprintf
        "(tuple %s)"
        (String.concat " " (List.map string_of_typed_expr items))
    | `Tuple_get (t, i) -> Printf.sprintf "(get %s %d)" (string_of_typed_expr t) i
    | `Record_lit fields ->
      Printf.sprintf
        "{%s}"
        (String.concat
           " "
           (List.map (fun (l, v) -> l ^ ":" ^ string_of_typed_expr v) fields))
    | `Field (r, label) ->
      Printf.sprintf "(field %s %s)" (string_of_typed_expr r) label
    | `Field_assign (r, label, v) ->
      Printf.sprintf
        "(field-set %s %s %s)"
        (string_of_typed_expr r)
        label
        (string_of_typed_expr v)
    | `New_call (name, _, args) ->
      Printf.sprintf
        "(new %s%s)"
        name
        (String.concat "" (List.map (fun a -> " " ^ string_of_typed_expr a) args))
    | `New (name, fields) ->
      Printf.sprintf
        "(new %s%s)"
        name
        (String.concat
           ""
           (List.map (fun (l, v) -> " " ^ l ^ ":" ^ string_of_typed_expr v) fields))
    | `New_variant (ty, variant, payload) ->
      Printf.sprintf
        "(new %s::%s%s)"
        ty
        variant
        (String.concat
           ""
           (List.map
              (fun (_, v) -> " " ^ string_of_typed_expr v)
              (Ast.payload_fields payload)))
    | `Index (t, i) ->
      Printf.sprintf "(index %s %s)" (string_of_typed_expr t) (string_of_typed_expr i)
    | `Index_assign (t, i, v) ->
      Printf.sprintf
        "(index-set %s %s %s)"
        (string_of_typed_expr t)
        (string_of_typed_expr i)
        (string_of_typed_expr v)
    | `Array_lit items ->
      Printf.sprintf
        "(array %s)"
        (String.concat " " (List.map string_of_typed_expr items))
    | `Array_new (length, fill) ->
      Printf.sprintf
        "(array-new %s %s)"
        (string_of_typed_expr length)
        (string_of_typed_expr fill)
    | `Array_get (t, i) ->
      Printf.sprintf "(array-get %s %s)" (string_of_typed_expr t) (string_of_typed_expr i)
    | `Array_set (t, i, v) ->
      Printf.sprintf
        "(array-set %s %s %s)"
        (string_of_typed_expr t)
        (string_of_typed_expr i)
        (string_of_typed_expr v)
    | `Array_len t -> Printf.sprintf "(array-len %s)" (string_of_typed_expr t)
    | `Str_get (t, i) ->
      Printf.sprintf "(str-get %s %s)" (string_of_typed_expr t) (string_of_typed_expr i)
    | `Str_len t -> Printf.sprintf "(str-len %s)" (string_of_typed_expr t)
  in
  Printf.sprintf "%s:%s" body ty

let opt_typed_expr = function
  | None -> "_"
  | Some e -> string_of_typed_expr e

let rec write_typed_stmt buf indent (s : Ast.typed_stmt) =
  let line fmt = Printf.ksprintf (fun str -> Buffer.add_string buf str) fmt in
  let pad = String.make (indent * 2) ' ' in
  let nested label body =
    line "%s(%s\n" pad label;
    List.iter (write_typed_stmt buf (indent + 1)) body;
    line "%s)\n" pad
  in
  match s.Ast.it with
  | `Expr e -> line "%s%s\n" pad (string_of_typed_expr e)
  | `Var_tuple (names, init) ->
    line "%s(var (%s) %s)\n" pad (String.concat " " names) (string_of_typed_expr init)
  | `Defer s -> line "%s(defer …)\n" pad; ignore s
  | `Var_decl (name, _, init) -> line "%s(var %s %s)\n" pad name (opt_typed_expr init)
  | `Block body -> nested "block" body
  | `If (cond, then_branch, else_branch) ->
    nested
      (Printf.sprintf "if %s" (string_of_typed_expr cond))
      (then_branch :: Option.to_list else_branch)
  | `While (cond, body) ->
    nested (Printf.sprintf "while %s" (string_of_typed_expr cond)) [ body ]
  | `Fn (name, params, _, body) ->
    nested
      (Printf.sprintf
         "fn %s (%s)"
         name
         (String.concat " " (List.map (fun (p : Ast.param) -> p.Ast.name) params)))
      body
  | `Return value -> line "%s(return %s)\n" pad (opt_typed_expr value)
  | `Effect_decl (name, _, _) -> line "%s(effect %s)\n" pad name
  | `Run (body, handlers) ->
    nested
      (Printf.sprintf
         "run%s"
         (String.concat "" (List.map (fun h -> " handle " ^ h.Ast.handled) handlers)))
      (body @ List.concat_map (fun h -> List.concat_map (fun a -> a.Ast.arm_body) h.Ast.arms) handlers)
  | `Resume value -> line "%s(resume %s)\n" pad (opt_typed_expr value)
  | `Type_decl (name, _, _) -> line "%s(type %s)\n" pad name
  | `Trait_decl (name, _, _) -> line "%s(trait %s)\n" pad name
  | `Impl_decl (trait, type_name, _, impl) ->
    nested
      (match trait with
       | Some (trait, _) -> Printf.sprintf "impl %s for %s" trait type_name
       | None -> Printf.sprintf "impl %s" type_name)
      (List.concat_map
         (fun (m : (Ast.typed_stmt, Types.ty) Ast.method_def) -> m.Ast.md_body)
         impl.Ast.ib_methods)
  | `Match (scrutinee, cases) ->
    nested
      (Printf.sprintf "match %s" (string_of_typed_expr scrutinee))
      (List.concat_map snd cases)

let string_of_typed_program (program : Ast.typed_stmt list) : string =
  let buf = Buffer.create 256 in
  List.iter (write_typed_stmt buf 0) program;
  Buffer.contents buf
