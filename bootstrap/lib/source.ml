(* The surface tree as Cronyx: parsing the output gives back the same tree. Not
   a formatter — comments are not in the tree, so not in the output. *)

let pad depth = String.make (depth * 4) ' '
let line depth text = Printf.sprintf "%s%s\n" (pad depth) text

(* Only the enclosing quote is escaped: a `'` inside a string needs nothing. *)
let escape ?(quote = '"') text =
  let buf = Buffer.create (String.length text + 2) in
  String.iter
    (fun c ->
      match c with
      | c when c = quote ->
        Buffer.add_char buf '\\';
        Buffer.add_char buf c
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | c -> Buffer.add_char buf c)
    text;
  Buffer.contents buf

let string_of_unop = function
  | Ast.Neg -> "-"
  | Ast.Not -> "!"

let rec type_expr (t : Ast.type_expr) =
  match t.Ast.it with
  | Ast.Ty_name name -> name
  | Ast.Ty_assoc (owner, member) -> type_expr owner ^ "." ^ member
  | Ast.Ty_bind (bound, t) -> bound ^ " = " ^ type_expr t
  (* The pack already carries the dots. *)
  | Ast.Ty_variadic ({ Ast.it = Ast.Ty_spread _; _ } as held) -> type_expr held
  | Ast.Ty_variadic inner -> "..." ^ type_expr inner
  | Ast.Ty_spread inner -> "..." ^ type_expr inner
  | Ast.Ty_app (name, args) ->
    Printf.sprintf "%s<%s>" name (String.concat ", " (List.map type_expr args))
  | Ast.Ty_tuple items -> Printf.sprintf "(%s)" (String.concat ", " (List.map type_expr items))
  | Ast.Ty_record fields ->
    Printf.sprintf
      "{ %s }"
      (String.concat ", " (List.map (fun (l, t) -> l ^ ": " ^ type_expr t) fields))
  | Ast.Ty_fn (params, ret, row) ->
    Printf.sprintf
      "(%s) ->%s %s"
      (String.concat ", " (List.map type_expr params))
      (match row with
       | [] -> ""
       | labels -> Printf.sprintf " <%s>" (String.concat ", " labels))
      (type_expr ret)

let annotation = function
  | None -> ""
  | Some t -> ": " ^ type_expr t

let param (p : Ast.param) = p.Ast.name ^ annotation p.Ast.ty

let static_params (cs : Ast.static_param list) =
  match cs with
  | [] -> ""
  | cs ->
    Printf.sprintf
      "<%s>"
      (String.concat
         ", "
         (List.map
            (fun (c : Ast.static_param) ->
              (if c.Ast.sp_pack then "..." else "") ^ c.Ast.sp_name ^ annotation c.Ast.sp_ty)
            cs))

let signature (sg : Ast.signature) =
  match sg.Ast.ret with
  | None -> ""
  | Some ret ->
    Printf.sprintf
      ":%s %s"
      (match sg.Ast.row with
       | None | Some [] -> ""
       | Some labels -> Printf.sprintf " <%s>" (String.concat ", " labels))
      (type_expr ret)

let rec expr (e : Ast.expr) : string =
  match e.Ast.it with
  | `Unit -> "()"
  | `Int n -> string_of_int n
  | `Float n -> Token.float_to_string n
  | `Str s -> Printf.sprintf "\"%s\"" (escape (Utf8.encode s))
  | `Char c -> Printf.sprintf "'%s'" (escape ~quote:'\'' (Utf8.encode [| c |]))
  | `Bool b -> string_of_bool b
  | `Name n -> n
  | `Bytes b -> Printf.sprintf "\"%s\"" (escape b)
  | `Var name -> name
  | `Assign (name, v) -> Printf.sprintf "%s = %s" name (expr v)
  | `Compound (op, name, v) ->
    Printf.sprintf "%s %s= %s" name (Ast.string_of_binop op) (expr v)
  | `Compound_index (op, target, index, v) ->
    Printf.sprintf "%s[%s] %s= %s" (expr target) (expr index) (Ast.string_of_binop op) (expr v)
  | `Compound_field (op, target, label, v) ->
    Printf.sprintf "%s.%s %s= %s" (expr target) label (Ast.string_of_binop op) (expr v)
  | `Unop (op, a) -> Printf.sprintf "%s%s" (string_of_unop op) (expr a)
  (* Parenthesised throughout: the tree already says how it groups, and this
     has no precedence table to decide when the parentheses are spare. *)
  | `Binop (op, a, b) ->
    Printf.sprintf "(%s %s %s)" (expr a) (Ast.string_of_binop op) (expr b)
  | `And (a, b) -> Printf.sprintf "(%s && %s)" (expr a) (expr b)
  | `Or (a, b) -> Printf.sprintf "(%s || %s)" (expr a) (expr b)
  | `Call (callee, args) -> Printf.sprintf "%s(%s)" (expr callee) (arguments args)
  | `Index (target, index) -> Printf.sprintf "%s[%s]" (expr target) (expr index)
  | `Index_assign (target, index, v) ->
    Printf.sprintf "%s[%s] = %s" (expr target) (expr index) (expr v)
  | `Tuple items -> Printf.sprintf "(%s)" (arguments items)
  | `Tuple_get (target, at) -> Printf.sprintf "%s.%d" (expr target) at
  | `Spread inner -> "..." ^ expr inner
  | `Record_lit fields -> Printf.sprintf "{ %s }" (labelled fields)
  | `Field (target, label) -> Printf.sprintf "%s.%s" (expr target) label
  | `Field_assign (target, label, v) ->
    Printf.sprintf "%s.%s = %s" (expr target) label (expr v)
  | `New (name, fields) -> Printf.sprintf "new %s { %s }" name (labelled fields)
  | `New_call (name, args, values) ->
    Printf.sprintf
      "new %s%s(%s)"
      name
      (match args with
       | [] -> ""
       | args -> Printf.sprintf "<%s>" (String.concat ", " (List.map type_expr args)))
      (arguments values)
  | `New_variant (ty, variant, payload) ->
    Printf.sprintf "%s::%s%s" ty variant (payload_of payload)
  | `Collection_lit items -> Printf.sprintf "[%s]" (arguments items)
  | `New_generic (name, static_args, fields) ->
    Printf.sprintf
      "new %s<%s> { %s }"
      name
      (String.concat
         ", "
         (List.map
            (function
              | Ast.St_type t -> type_expr t
              | Ast.St_value v -> expr v)
            static_args))
      (labelled fields)
  | `Static_call (callee, static_args, args) ->
    Printf.sprintf
      "%s<%s>(%s)"
      (expr callee)
      (String.concat
         ", "
         (List.map
            (function
              | Ast.St_type t -> type_expr t
              | Ast.St_value v -> expr v)
            static_args))
      (arguments args)
  | `Method_call (receiver, name, _, args) ->
    Printf.sprintf "%s.%s(%s)" (expr receiver) name (arguments args)
  | `Typeof inner -> Printf.sprintf "typeof(%s)" (expr inner)
  | `Code inner -> Printf.sprintf "code(%s)" (expr inner)
  | `Lambda (params, sg, body) ->
    Printf.sprintf
      "(%s)%s => { %s }"
      (String.concat ", " (List.map param params))
      (signature sg)
      (String.concat " " (List.map (stmt 0) body))
  | `Run_expr (body, handlers, clause) ->
    Printf.sprintf
      "run { %s }%s%s"
      (valued_block body)
      (String.concat
         ""
         (List.map
            (function
              | Ast.Named name -> Printf.sprintf " with %s;" name
              | Ast.Inline h ->
                Printf.sprintf
                  " handle %s { %s}"
                  h.Ast.handled
                  (String.concat "" (List.map (arm 0) h.Ast.arms)))
            handlers))
      (match clause with
       | None -> ""
       | Some c ->
         Printf.sprintf " return (%s) { %s }" c.Ast.rc_param (valued_block c.Ast.rc_body))

and valued_block (b : (Ast.expr, Ast.stmt) Ast.valued_block) =
  String.concat " " (List.map (stmt 0) b.Ast.vb_stmts)
  ^ (match b.Ast.vb_value with
     | None -> ""
     | Some v -> expr v)

and arguments items = String.concat ", " (List.map expr items)

and labelled fields =
  String.concat ", " (List.map (fun (l, v) -> Printf.sprintf "%s: %s" l (expr v)) fields)

and payload_of (p : Ast.expr Ast.payload) =
  match p with
  | Ast.P_none -> ""
  | Ast.P_tuple [] -> ""
  | Ast.P_tuple items -> Printf.sprintf "(%s)" (arguments items)
  | Ast.P_fields fields -> Printf.sprintf " { %s }" (labelled fields)

and block depth body =
  String.concat "" (List.map (stmt depth) body)

and stmt depth (s : Ast.stmt) : string =
  let line = line depth in
  let braced head body = line (Printf.sprintf "%s {" head) ^ block (depth + 1) body ^ line "}" in
  match s.Ast.it with
  | `Attributed (list, inner) -> line (String.trim (attrs list)) ^ stmt depth inner
  (* Printed back as it was written, rather than as the expression it is. *)
  | `Expr { Ast.it = `Run_expr (body, handlers, None); _ } when body.Ast.vb_value = None ->
    line "run {" ^ block (depth + 1) body.Ast.vb_stmts ^ handlers_of depth handlers
  | `Expr e -> line (expr e ^ ";")
  | `Var_tuple (names, init) ->
    line (Printf.sprintf "var (%s) = %s;" (String.concat ", " names) (expr init))
  | `Var_decl (name, ty, init) ->
    line
      (Printf.sprintf
         "var %s%s%s;"
         name
         (annotation ty)
         (match init with
          | None -> ""
          | Some v -> " = " ^ expr v))
  | `Block body -> braced "" body
  | `If (cond, then_branch, else_branch) ->
    let head = line (Printf.sprintf "if (%s) {" (expr cond)) in
    let then_part = head ^ nested depth then_branch in
    (match else_branch with
     | None -> then_part ^ line "}"
     | Some other -> then_part ^ line "} else {" ^ nested depth other ^ line "}")
  | `While (cond, body) ->
    line (Printf.sprintf "while (%s) {" (expr cond)) ^ nested depth body ^ line "}"
  | `For (init, cond, step, body) ->
    line
      (Printf.sprintf
         "for (%s %s; %s) {"
         (match init with
          | None -> ";"
          | Some i -> String.trim (stmt 0 i))
         (match cond with
          | None -> ""
          | Some c -> expr c)
         (match step with
          | None -> ""
          | Some st -> expr st))
    ^ nested depth body
    ^ line "}"
  | `For_in (names, iterable, body) ->
    line
      (Printf.sprintf
         "for (%s in %s) {"
         (match names with
          | [ only ] -> only
          | names -> "(" ^ String.concat ", " names ^ ")")
         (expr iterable))
    ^ nested depth body
    ^ line "}"
  | `Fn (name, params, sg, body) ->
    braced
      (Printf.sprintf
         "fn %s%s(%s)%s%s"
         (match Ast.deriver_trait name with
          | Some _ -> "derive"
          | None -> name)
         (static_params sg.Ast.static_params)
         (String.concat ", " (List.map param params))
         (signature sg)
         (match Ast.deriver_trait name with
          | Some trait -> " for " ^ trait
          | None -> ""))
      body
  | `Return e ->
    line
      (match e with
       | None -> "return;"
       | Some v -> Printf.sprintf "return %s;" (expr v))
  | `Defer inner -> line "defer" ^ nested depth inner
  | `Import decl ->
    line
      (match decl with
       | Ast.Qualified path -> Printf.sprintf "import \"%s\";" (escape path)
       | Ast.Aliased (path, alias) ->
         Printf.sprintf "import \"%s\" as %s;" (escape path) alias
       | Ast.Selective (names, path) ->
         Printf.sprintf
           "import { %s } from \"%s\";"
           (String.concat ", " names)
           (escape path)
       | Ast.Wildcard path -> Printf.sprintf "import \"%s/*\";" (escape path))
  | `Meta body -> braced "meta" body
  | `Gen inner -> line "gen" ^ nested depth inner
  | `Derive (traits, target) ->
    line (Printf.sprintf "derive %s for %s;" (String.concat ", " traits) target)
  | `Type_decl (name, params, body) -> type_decl depth name params body
  | `Type_members ({ Ast.it = `Type_decl (name, params, body); _ }, members) ->
    type_decl ~members depth name params body
  | `Type_members (decl, members) -> stmt depth decl ^ block depth members
  | `Effect_decl (name, params, ops) -> effect_decl depth name params ops
  | `Handler_decl (name, h) ->
    line (Printf.sprintf "handler %s : %s {" name h.Ast.handled)
    ^ String.concat "" (List.map (arm (depth + 1)) h.Ast.arms)
    ^ line "}"
  | `Run (body, handlers) ->
    line "run {" ^ block (depth + 1) body ^ handlers_of depth handlers
  | `Resume e ->
    line
      (match e with
       | None -> "resume;"
       | Some v -> Printf.sprintf "resume %s;" (expr v))
  | `Trait_decl (name, params, sigs) ->
    line
      (Printf.sprintf
         "trait %s%s%s {"
         name
         (match params with
          | [] -> ""
          | ps -> Printf.sprintf "<%s>" (String.concat ", " ps))
         (match sigs.Ast.tb_super with
          | [] -> ""
          | supers ->
            ": "
            ^ String.concat
                ", "
                (List.map
                   (fun (super, args) ->
                     match args with
                     | [] -> super
                     | args ->
                       Printf.sprintf
                         "%s<%s>"
                         super
                         (String.concat ", " (List.map type_expr args)))
                   supers)))
    ^ String.concat
        ""
        (List.map
           (fun name -> Printf.sprintf "%stype %s;\n" (pad (depth + 1)) name)
           sigs.Ast.tb_assoc)
    ^ String.concat
        ""
        (List.map
           (fun (m : Ast.method_sig) ->
             Printf.sprintf
               "%sfn %s(%s)%s;\n"
               (pad (depth + 1))
               m.Ast.ms_name
               (String.concat ", " (List.map param m.Ast.ms_params))
               (signature m.Ast.ms_signature))
           sigs.Ast.tb_methods)
    ^ line "}"
  | `Impl_decl (trait, target, params, impl) ->
    line
      (Printf.sprintf
         "impl %s%s%s {"
         (match trait with
          | None -> ""
          | Some (t, args) ->
            Printf.sprintf
              "%s%s for "
              t
              (match args with
               | [] -> ""
               | args -> Printf.sprintf "<%s>" (String.concat ", " (List.map type_expr args))))
         target
         (match params with
          | [] -> ""
          | ps ->
            Printf.sprintf
              "<%s>"
              (String.concat
                 ", "
                 (List.map
                    (fun (p : Ast.type_param) ->
                      (if p.Ast.tp_pack then "..." else "") ^ p.Ast.tp_name)
                    ps))))
    ^ String.concat
        ""
        (List.map
           (fun (name, bound) ->
             Printf.sprintf "%stype %s = %s;\n" (pad (depth + 1)) name (type_expr bound))
           impl.Ast.ib_assoc)
    ^ String.concat "" (List.map (method_def (depth + 1)) impl.Ast.ib_methods)
    ^ line "}"
  | `Match (scrutinee, cases) ->
    line (Printf.sprintf "match %s {" (expr scrutinee))
    ^ String.concat "" (List.map (case (depth + 1)) cases)
    ^ line "}"

(* The braces are the enclosing form's; only the contents are printed. *)
and nested depth (s : Ast.stmt) =
  match s.Ast.it with
  | `Block body -> block (depth + 1) body
  | _ -> stmt (depth + 1) s

and attrs (list : Ast.attr list) =
  let arg = function
    | Ast.A_str text -> Printf.sprintf "%S" text
    | Ast.A_int value -> string_of_int value
    | Ast.A_float value -> Printf.sprintf "%g" value
    | Ast.A_bool value -> if value then "true" else "false"
  in
  String.concat
    ""
    (List.map
       (fun (a : Ast.attr) ->
         Printf.sprintf
           "@%s%s "
           a.Ast.a_name
           (match a.Ast.a_args with
            | [] -> ""
            | args -> Printf.sprintf "(%s)" (String.concat ", " (List.map arg args))))
       list)

and type_decl ?(members = []) depth name params body =
  let line = line depth in
  let head =
    Printf.sprintf
      "type %s%s {"
      name
      (match params with
       | [] -> ""
       | ps ->
         Printf.sprintf
           "<%s>"
           (String.concat
              ", "
              (List.map
                 (fun (p : Ast.type_param) ->
                   (if p.Ast.tp_pack then "..." else "")
                   ^ p.Ast.tp_name
                   ^ annotation p.Ast.tp_ty)
                 ps)))
  in
  line head
  ^ (match body with
     | Ast.T_fields fields ->
       String.concat
         ",\n"
         (List.map
            (fun (f : Ast.field) ->
              Printf.sprintf
                "%s%s%s: %s"
                (pad (depth + 1))
                (attrs f.Ast.f_attrs)
                f.Ast.f_name
                (type_expr f.Ast.f_ty))
            fields)
     | Ast.T_variants variants ->
       String.concat
         ",\n"
         (List.map
            (fun (v : Ast.variant) ->
              Printf.sprintf
                "%s%s%s%s%s%s"
                (pad (depth + 1))
                (attrs v.Ast.v_attrs)
                v.Ast.v_name
                (match v.Ast.v_params with
                 | [] -> ""
                 | ps -> Printf.sprintf "<%s>" (String.concat ", " ps))
                (match v.Ast.v_payload with
                 | Ast.P_none -> ""
                 | Ast.P_tuple items ->
                   Printf.sprintf "(%s)" (String.concat ", " (List.map type_expr items))
                 | Ast.P_fields fields ->
                   Printf.sprintf
                     " { %s }"
                     (String.concat
                        ", "
                        (List.map (fun (l, t) -> l ^ ": " ^ type_expr t) fields)))
                (match v.Ast.v_result with
                 | None -> ""
                 | Some head -> " -> " ^ type_expr head))
            variants))
  ^ "\n"
  ^ (match members with
     | [] -> ""
     | members -> "\n" ^ block (depth + 1) members)
  ^ line "}"

and effect_decl depth name params ops =
  let line = line depth in
  line
    (Printf.sprintf
       "effect %s%s {"
       name
       (match params with
        | [] -> ""
        | ps -> Printf.sprintf "<%s>" (String.concat ", " ps)))
  ^ String.concat
      ""
      (List.map
         (fun (o : Ast.op_decl) ->
           Printf.sprintf
             "%s%s %s%s(%s)%s;\n"
             (pad (depth + 1))
             (match o.Ast.op_kind with
              | Ast.Op_fn -> "fn"
              | Ast.Op_ctl -> "ctl"
              | Ast.Op_final -> "final ctl")
             o.Ast.op_name
             (match o.Ast.op_tparams with
              | [] -> ""
              | ps -> Printf.sprintf "<%s>" (String.concat ", " ps))
             (String.concat ", " (List.map param o.Ast.op_params))
             (match o.Ast.op_ret with
              | None -> ""
              | Some t -> ": " ^ type_expr t))
         ops)
  ^ line "}"

(* Each clause reopens the brace the last one closed. *)
and handlers_of depth handlers =
  let line = line depth in
  let clause (h : Ast.stmt Ast.handler_clause) =
    match h with
    | Ast.Named name -> line (Printf.sprintf "} with %s;" name)
    | Ast.Inline h ->
      line (Printf.sprintf "} handle %s {" h.Ast.handled)
      ^ String.concat "" (List.map (arm (depth + 1)) h.Ast.arms)
  in
  let printed = String.concat "" (List.map clause handlers) in
  match List.rev handlers with
  | Ast.Inline _ :: _ -> printed ^ line "}"
  | _ -> printed

and arm depth (a : Ast.stmt Ast.arm) =
  let line = line depth in
  line
    (Printf.sprintf
       "%s %s(%s) {"
       (match a.Ast.arm_kind with
        | Ast.Op_fn -> "fn"
        | Ast.Op_ctl -> "ctl"
        | Ast.Op_final -> "final ctl")
       a.Ast.arm_name
       (String.concat ", " a.Ast.arm_params))
  ^ block (depth + 1) a.Ast.arm_body
  ^ line "}"

and method_def depth (m : (Ast.stmt, unit) Ast.method_def) =
  let line = line depth in
  line
    (Printf.sprintf
       "fn %s%s(%s)%s {"
       m.Ast.md_name
       (static_params m.Ast.md_signature.Ast.static_params)
       (String.concat ", " (List.map param m.Ast.md_params))
       (signature m.Ast.md_signature))
  ^ block (depth + 1) m.Ast.md_body
  ^ line "}"

and case depth (p, body) =
  let line = line depth in
  line
    (Printf.sprintf
       "%s => {"
       (match p with
        | Ast.Pat_wild -> "_"
        | Ast.Pat_variant (ty, variant, payload) ->
          Printf.sprintf
            "%s::%s%s"
            ty
            variant
            (match payload with
             | Ast.P_none -> ""
             | Ast.P_tuple names -> Printf.sprintf "(%s)" (String.concat ", " names)
             | Ast.P_fields fields ->
               Printf.sprintf " { %s }" (String.concat ", " (List.map fst fields)))))
  ^ block (depth + 1) body
  ^ line "}"

let program (p : Ast.program) : string = block 0 p
