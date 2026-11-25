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
  | `Pre_checked n -> Printf.sprintf "(processed %d)" n
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
  | `Pre_checked n -> line "%s(processed %d)\n" pad n
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
         "%sfn %s (%s)%s%s"
         (if signature.Ast.inline then "inline " else "")
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

(* ---- processed code, written as Cronyx ---- *)

module Str_find = struct
  let after hay needle =
    let n = String.length needle and h = String.length hay in
    let rec go i = if i + n > h then None else if String.sub hay i n = needle then Some (String.sub hay (i + n) (h - i - n)) else go (i + 1) in
    go 0
end

(* A module's names carry its path, `std#Format#str#0`; the instance's own
   number is kept, since it says which instance a call reaches. *)
let readable name =
  if String.equal name Ast.program_main then "main" else
  let parts = String.split_on_char '#' name in
  let rec drop = function
    | "std" :: _ :: rest -> drop rest
    | p :: rest -> p :: drop rest
    | [] -> []
  in
  match drop parts with
  | [] -> name
  | kept -> String.concat "#" kept

let string_of_cronyx_ty t =
  let s = Types.string_of_ty t in
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  while !i < n do
    if !i + 4 <= n && String.sub s !i 4 = "std#"
    then (
      (* `std#Module#` *)
      let j = try String.index_from s (!i + 4) '#' with Not_found -> n - 1 in
      i := j + 1)
    else (
      Buffer.add_char b s.[!i];
      incr i)
  done;
  Buffer.contents b

(* Source text with each library path, `std#Module#`, left out of the names it
   qualifies. A string literal is copied as it stands. *)
let readable_source text =
  let b = Buffer.create (String.length text) in
  let n = String.length text in
  let is_name c =
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '#' -> true
    | _ -> false
  in
  let rec go i quoted =
    if i < n
    then (
      let c = text.[i] in
      if quoted
      then (
        Buffer.add_char b c;
        if c = '\\' && i + 1 < n
        then (
          Buffer.add_char b text.[i + 1];
          go (i + 2) true)
        else go (i + 1) (c <> '"'))
      else if c = '"'
      then (
        Buffer.add_char b c;
        go (i + 1) true)
      else if i + 4 <= n && String.sub text i 4 = "std#" && (i = 0 || not (is_name text.[i - 1]))
      then (
        match String.index_from_opt text (i + 4) '#' with
        | Some j -> go (j + 1) false
        | None ->
          Buffer.add_char b c;
          go (i + 1) false)
      else (
        Buffer.add_char b c;
        go (i + 1) false))
  in
  go 0 false;
  Buffer.contents b

let rec cronyx_of_expr ?(depth = 0) (e : Ast.resolved_expr) : string =
  let go = cronyx_of_expr ~depth in
  let args xs = String.concat ", " (List.map go xs) in
  match e.Ast.it with
  | `Unit -> "()"
  | `Int n -> string_of_int n
  | `Bytes b -> Printf.sprintf "<%d bytes>" (String.length b)
  | `Name n -> Printf.sprintf "`%s`" (readable n)
  | `Float n -> Token.float_to_string n
  | `Str s -> Printf.sprintf "%S" (Utf8.encode s)
  | `Char c -> Printf.sprintf "'%s'" (Token.literal_to_string (Token.Char c))
  | `Bool b -> string_of_bool b
  | `Var name -> readable name
  | `Assign (name, v) -> Printf.sprintf "%s = %s" (readable name) (go v)
  | `Unop (op, a) -> Printf.sprintf "%s%s" (string_of_unop op) (go a)
  | `Binop (op, a, b) -> Printf.sprintf "(%s %s %s)" (go a) (string_of_binop op) (go b)
  | `And (a, b) -> Printf.sprintf "(%s && %s)" (go a) (go b)
  | `Or (a, b) -> Printf.sprintf "(%s || %s)" (go a) (go b)
  | `Call (({ Ast.it = `Lambda _; _ } as callee), xs) -> Printf.sprintf "(%s)(%s)" (go callee) (args xs)
  | `Call (callee, xs) -> Printf.sprintf "%s(%s)" (go callee) (args xs)
  | `Dyn_call (receiver, name, _, xs) -> Printf.sprintf "%s.%s(%s)" (go receiver) name (args xs)
  | `Tuple items -> Printf.sprintf "(%s)" (args items)
  | `Tuple_get (t, i) -> Printf.sprintf "%s.%d" (go t) i
  | `Record_lit fields ->
    if fields = [] then "{}" else Printf.sprintf "{ %s }" (String.concat ", " (List.map (fun (l, v) -> readable l ^ ": " ^ go v) fields))
  | `Field (r, label) -> Printf.sprintf "%s.%s" (go r) (readable label)
  | `Field_assign (r, label, v) -> Printf.sprintf "%s.%s = %s" (go r) (readable label) (go v)
  | `Array_lit items -> Printf.sprintf "[%s]" (args items)
  | `Array_new (length, fill) -> Printf.sprintf "Array.filled(%s, %s)" (go length) (go fill)
  | `Array_get (t, i) | `Str_get (t, i) -> Printf.sprintf "%s[%s]" (go t) (go i)
  | `Array_set (t, i, v) -> Printf.sprintf "%s[%s] = %s" (go t) (go i) (go v)
  | `Array_len t | `Str_len t -> Printf.sprintf "%s.len()" (go t)
  | `Variant (variant, []) -> readable variant
  | `Variant (variant, fields) ->
    Printf.sprintf "%s(%s)" (readable variant) (String.concat ", " (List.map (fun (_, v) -> go v) fields))
  | `Object (data, _, _) -> Printf.sprintf "dyn(%s)" (go data)
  | `Lambda (params, _, body) ->
    let ps = String.concat ", " (List.map (fun (p : Ast.param) -> readable p.Ast.name) params) in
    let buf = Buffer.create 64 in
    List.iter (write_cronyx_stmt buf (depth + 1)) body;
    Printf.sprintf "(%s) => {\n%s%s}" ps (Buffer.contents buf) (String.make (depth * 4) ' ')

and write_cronyx_stmt buf indent (s : Ast.resolved_stmt) =
  let pad = String.make (indent * 4) ' ' in
  let line fmt = Printf.ksprintf (fun str -> Buffer.add_string buf (pad ^ str ^ "\n")) fmt in
  let expr = cronyx_of_expr ~depth:indent in
  (* A condition is written in its own parentheses already. *)
  let bare (e : Ast.resolved_expr) =
    let shown = expr e in
    match e.Ast.it with
    | `Binop _ | `And _ | `Or _ -> String.sub shown 1 (String.length shown - 2)
    | _ -> shown
  in
  let block body =
    List.iter (write_cronyx_stmt buf (indent + 1)) body
  in
  let braced head body =
    if String.equal head "" then line "{" else line "%s {" head;
    block body;
    line "}"
  in
  let as_body (s : Ast.resolved_stmt) = match s.Ast.it with `Block b -> b | _ -> [ s ] in
  match s.Ast.it with
  | `Expr e -> line "%s;" (expr e)
  | `Var_tuple (names, init) -> line "var (%s) = %s;" (String.concat ", " (List.map readable names)) (expr init)
  | `Var_decl (name, _, None) -> line "var %s;" (readable name)
  | `Var_decl (name, _, Some init) -> line "var %s = %s;" (readable name) (expr init)
  | `Defer inner ->
    line "defer {";
    block [ inner ];
    line "}"
  | `Block body -> braced "" body
  | `If (cond, then_branch, None) -> braced (Printf.sprintf "if (%s)" (bare cond)) (as_body then_branch)
  | `If (cond, then_branch, Some else_branch) ->
    line "if (%s) {" (bare cond);
    block (as_body then_branch);
    line "} else {";
    block (as_body else_branch);
    line "}"
  | `While (cond, body) -> braced (Printf.sprintf "while (%s)" (bare cond)) (as_body body)
  | `Fn (name, params, sg, body) ->
    let inline = if sg.Ast.inline then "inline " else "" in
    let ty =
      match s.Ast.ann with
      | Types.Fn (ps, ret, _) when List.length ps = List.length params -> Some (ps, ret)
      | _ -> None
    in
    let shown =
      match ty with
      | Some (ps, ret) ->
        Printf.sprintf
          "%sfn %s(%s): %s"
          inline
          (readable name)
          (String.concat
             ", "
             (List.map2 (fun (p : Ast.param) t -> readable p.Ast.name ^ ": " ^ string_of_cronyx_ty t) params ps))
          (string_of_cronyx_ty ret)
      | None ->
        Printf.sprintf "%sfn %s(%s)" inline (readable name) (String.concat ", " (List.map (fun (p : Ast.param) -> readable p.Ast.name) params))
    in
    braced shown body
  | `Return None -> line "return;"
  | `Return (Some v) -> line "return %s;" (expr v)
  | `Break -> line "break;"
  | `Continue -> line "continue;"
  | `Type_decl (name, _, Ast.T_fields fields) ->
    line
      "type %s { %s }"
      (readable name)
      (String.concat ", " (List.map (fun (f : Ast.field) -> f.Ast.f_name ^ ": " ^ string_of_type_expr f.Ast.f_ty) fields))
  | `Type_decl (name, _, Ast.T_variants variants) ->
    line "type %s { %s }" (readable name) (String.concat ", " (List.map (fun (v : Ast.variant) -> v.Ast.v_name) variants))
  | `Match (scrutinee, cases) ->
    line "match %s {" (expr scrutinee);
    List.iter
      (fun (pattern, body) ->
        let head =
          match pattern with
          | Ast.Pat_wild -> "_"
          | Ast.Pat_variant (ty, variant, Ast.P_none) -> readable ty ^ "." ^ variant
          | Ast.Pat_variant (ty, variant, Ast.P_tuple names) ->
            Printf.sprintf "%s.%s(%s)" (readable ty) variant (String.concat ", " names)
          | Ast.Pat_variant (ty, variant, Ast.P_fields fields) ->
            Printf.sprintf "%s.%s { %s }" (readable ty) variant (String.concat ", " (List.map snd fields))
        in
        Buffer.add_string buf (Printf.sprintf "%s    %s => {\n" pad head);
        List.iter (write_cronyx_stmt buf (indent + 2)) body;
        Buffer.add_string buf (pad ^ "    }\n"))
      cases;
    line "}"

(* The whole program after metaprocessing: the entry's own declarations, then
   each library file's, under its path, then the top level as it runs, the
   root's call included. A library's types are counted, not written: every
   declared type is kept, used or not. *)
let cronyx_of_entry ~entry (program : Ast.resolved_stmt list) : string =
  let file (s : Ast.resolved_stmt) = Source_map.Span.path s.Ast.span in
  let is_type (s : Ast.resolved_stmt) = match s.Ast.it with `Type_decl _ -> true | _ -> false in
  let top_level (s : Ast.resolved_stmt) =
    match s.Ast.it with
    | `Fn (name, _, _, _) ->
      String.equal name Ast.program_main
      || (String.equal (file s) entry && String.equal (Diagnostic.as_written name) "main")
    | `Type_decl _ -> false
    | _ -> true
  in
  let shown path =
    if String.equal path ""
    then "generated"
    else (
      match Str_find.after path "stdlib/" with
      | Some rest -> "std/" ^ rest
      | None -> Filename.basename path)
  in
  let buf = Buffer.create 4096 in
  let write s =
    write_cronyx_stmt buf 0 s;
    Buffer.add_char buf '\n'
  in
  List.iter (fun s -> if String.equal (file s) entry && not (top_level s) then write s) program;
  let files = ref [] in
  List.iter
    (fun s ->
      let f = file s in
      if (not (String.equal f entry)) && (not (top_level s)) && not (List.mem f !files) then files := f :: !files)
    program;
  List.iter
    (fun f ->
      let here = List.filter (fun s -> String.equal (file s) f && not (top_level s)) program in
      let fns = List.filter (fun s -> not (is_type s)) here in
      let types = List.length here - List.length fns in
      if fns <> []
      then (
        Buffer.add_string buf (Printf.sprintf "// %s\n" (shown f));
        List.iter write fns)
      else ignore types)
    (List.rev !files);
  let types =
    List.length (List.filter (fun s -> is_type s && not (String.equal (file s) entry)) program)
  in
  if types > 0 then Buffer.add_string buf (Printf.sprintf "// and %d types the library declares\n\n" types);
  Buffer.add_string buf "// The top level.\n";
  List.iter (fun s -> if top_level s then write_cronyx_stmt buf 0 s) program;
  Buffer.contents buf
