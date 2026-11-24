type error =
  { span : Ast.span
  ; message : string
  }

exception Failed of error

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Failed { span; message })) fmt

let syntax span read =
  try read () with
  | Syntax.Malformed message -> fail span "%s" message

(* A value written back as the syntax that denotes it. A function and an object
   have no such syntax, so they are [None]. A name is written as one only where
   [names] says: a meta value substituted into code stands for what it names,
   and substitution writes that identifier itself. *)
let rec reify_with ~names span (v : Value.value) : Ast.expr option =
  let reify = reify_with ~names in
  let at it = Ast.at span it in
  let all items =
    List.fold_right
      (fun v acc ->
        match acc, reify span v with
        | Some acc, Some e -> Some (e :: acc)
        | _ -> None)
      items
      (Some [])
  in
  match Syntax.kind_of v with
  | Some Syntax.Expr_node -> Some (syntax span (fun () -> Syntax.to_expr ~fallback:span v))
  | Some kind -> fail span "This is %s, which cannot stand where an expression does." (Syntax.describe kind)
  | None ->
  match v with
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
  | Value.Name n when names -> Some (at (`Name n))
  | _ -> None

let reify = reify_with ~names:false

(* The expression that builds a value, at run time as at compile time: a
   syntax value is built as one rather than written as the code it holds. A
   span is asked for at its own location, which the call carries. *)
let span_here = "__span_here"

let rec built span (v : Value.value) : Ast.expr =
  let at it = Ast.at span it in
  let built = built span in
  match v with
  | Value.Span sp -> Ast.at sp (`Call (Ast.at sp (`Var span_here), []))
  | Value.Name n -> at (`Name n)
  | Value.Tuple items -> at (`Tuple (List.map built items))
  | Value.Array items -> at (`Collection_lit (List.map built (Array.to_list items)))
  | Value.Record (Some name, fields) when String.equal name Core.list ->
    (match List.assoc_opt "items" fields with
     | Some { contents = Value.Array items } -> at (`Collection_lit (List.map built (Array.to_list items)))
     | _ -> fail span "This list has no items to build it from.")
  | Value.Record (named, fields) ->
    let fields = List.map (fun (l, v) -> l, built !v) fields in
    (match named with
     | Some name -> at (`New (name, fields))
     | None -> at (`Record_lit fields))
  | Value.Variant (Some ty, variant, fields) ->
    let positional = List.for_all Fun.id (List.mapi (fun i (l, _) -> String.equal l (string_of_int i)) fields) in
    let payload : Ast.expr Ast.payload =
      match fields with
      | [] -> Ast.P_none
      | _ when positional -> Ast.P_tuple (List.map (fun (_, v) -> built v) fields)
      | _ -> Ast.P_fields (List.map (fun (l, v) -> l, built v) fields)
    in
    at (`New_variant (ty, variant, payload))
  | _ ->
    (match reify span v with
     | Some e -> e
     | None -> fail span "This value has no literal to build it with.")

(* A settled type written back as the annotation that denotes it. A type still
   open where processed code is read is written as [Ast.open_type]. *)
let rec type_expr_of ?(opened = false) span (t : Types.ty) : Ast.type_expr =
  let at it = { Ast.it; span; ann = () } in
  let type_expr_of = type_expr_of ~opened in
  let all = List.map (type_expr_of span) in
  let labels (row : Types.row) = List.map (fun (l, args) -> l, all args) row.Types.labels in
  match t with
  | Types.Named (n, []) | Types.Sum (n, []) -> at (Ast.Ty_name n)
  | Types.Named (n, args) | Types.Sum (n, args) ->
    (* A pack argument is written as the types it holds. *)
    let spread = List.concat_map (function Types.Pack ts -> ts | t -> [ t ]) args in
    at (Ast.Ty_app (n, all spread))
  | Types.Tuple ts | Types.Pack ts -> at (Ast.Ty_tuple (all ts))
  | Types.Spread t -> at (Ast.Ty_spread (type_expr_of span t))
  | Types.Record fields -> at (Ast.Ty_record (List.map (fun (l, t) -> l, type_expr_of span t) fields))
  | Types.Fn (ps, r, row) -> at (Ast.Ty_fn (all ps, type_expr_of span r, labels row))
  | Types.Row row -> at (Ast.Ty_row (labels row))
  | Types.Generic _ when opened -> at (Ast.Ty_name Ast.open_type)
  | Types.Int | Types.Float | Types.Str | Types.Byte | Types.Chr | Types.Bool | Types.Unit | Types.Generic _ ->
    at (Ast.Ty_name (Types.string_of_ty t))

(* ---- what `typeof` answers ----

   Built as values and written back as literals, so a `typeof` is gone before
   anything runs. Answers are one level deep: a field reports a reference to
   its type, not the type's own shape, so a type that mentions itself
   describes itself in finite space. *)

let str_value text = Value.Str (Utf8.decode text)
let array_value items = Value.Array (Array.of_list items)
let record_value name fields = Value.Record (Some name, List.map (fun (l, v) -> l, ref v) fields)
let variant_value ty label payload =
  Value.Variant (Some ty, label, List.mapi (fun i v -> string_of_int i, v) payload)

let reflection = Core.reflect "Type"

(* Only a named type can be asked: a function value's type names no
   declaration to look the attributes up under. *)
let declared_attrs (ty : Types.ty) =
  match ty with
  | Types.Named (name, _) | Types.Sum (name, _) ->
    Option.value (Hashtbl.find_opt Typecheck.decl_attrs name) ~default:[]
  | _ -> []

(* A doc comment is carried as an attribute and presented as a doc, so `attrs`
   never reports one and there is no `@doc` to match on. *)
let doc_of (list : Ast.attr list) =
  match List.find_opt (fun (a : Ast.attr) -> String.equal a.Ast.a_name Ast.doc_attr) list with
  | Some { Ast.a_args = [ Ast.A_str text ]; _ } -> text
  | _ -> ""

let written (list : Ast.attr list) =
  List.filter (fun (a : Ast.attr) -> not (String.equal a.Ast.a_name Ast.doc_attr)) list

let attrs_value (list : Ast.attr list) =
  let arg (a : Ast.attr_arg) =
    match a with
    | Ast.A_str text -> variant_value Core.attr_arg "Str" [ str_value text ]
    | Ast.A_int n -> variant_value Core.attr_arg "Int" [ Value.Int n ]
    | Ast.A_float f -> variant_value Core.attr_arg "Float" [ Value.Float f ]
    | Ast.A_bool b -> variant_value Core.attr_arg "Bool" [ Value.Bool b ]
  in
  array_value
    (List.map
       (fun (a : Ast.attr) ->
         record_value Core.attr [ "name", Value.Name a.Ast.a_name; "args", array_value (List.map arg a.Ast.a_args) ])
       list)

let named_ref name args = variant_value Core.type_ref "Named" [ Value.Name name; array_value args ]

let param_ref id =
  variant_value Core.type_ref "Param" [ Value.Name (Option.value (Hashtbl.find_opt Types.param_names id) ~default:"T") ]

let rec ref_of_ty (ty : Types.ty) =
  match ty with
  | Types.Int | Types.Float | Types.Str | Types.Byte | Types.Chr | Types.Bool | Types.Unit ->
    named_ref (Types.string_of_ty ty) []
  | Types.Named (name, args) | Types.Sum (name, args) -> named_ref name (List.map ref_of_ty args)
  | Types.Generic id -> param_ref id
  | _ -> variant_value Core.type_ref "Other" []

let rec ref_of_infer (ty : Types.infer_ty) =
  match Types.repr ty with
  | Types.IVar { contents = Types.Unbound (id, _) } -> param_ref id
  | Types.INamed (name, args) | Types.ISum (name, args) -> named_ref name (List.map ref_of_infer args)
  | Types.IInt | Types.IFloat | Types.IStr | Types.IByte | Types.IChr | Types.IBool | Types.IUnit ->
    ref_of_ty (Types.resolve ty)
  | _ -> variant_value Core.type_ref "Other" []

(* The checker keeps fields sorted; a deriver writes them out in the order the
   type declared them, which is the order its attributes were recorded in. *)
let declared_order name fields =
  match Hashtbl.find_opt Typecheck.ctx_attrs name with
  | None -> fields
  | Some members ->
    let position label =
      let rec find i = function
        | [] -> max_int
        | (l, _) :: rest -> if String.equal l label then i else find (i + 1) rest
      in
      find 0 members
    in
    List.stable_sort (fun (a, _) (b, _) -> compare (position a) (position b)) fields

let params_value name =
  array_value
    (List.map (fun n -> Value.Name n) (Option.value (Hashtbl.find_opt Typecheck.ctx_type_param_names name) ~default:[]))

(* Neither kind of type carries what it declares, so both are read from the
   tables the checker built. *)
let shape_of (ty : Types.ty) =
  match ty with
  | Types.Int | Types.Float | Types.Str | Types.Byte | Types.Chr | Types.Bool | Types.Unit ->
    variant_value Core.shape "Scalar" []
  | Types.Named (name, args) when not (String.equal name Types.array_name) ->
    let each (label, ty) =
      let carried = Typecheck.attrs_of name label in
      record_value
        Core.field
        [ "name", Value.Name label
        ; "ty", ref_of_ty ty
        ; "doc", str_value (doc_of carried)
        ; "attrs", attrs_value (written carried)
        ]
    in
    variant_value
      Core.shape
      "Product"
      [ Value.Name name; params_value name; array_value (List.map each (declared_order name (Types.named_fields name args))) ]
  | Types.Sum (name, _) ->
    let variants =
      match Hashtbl.find_opt Typecheck.ctx_types name with
      | Some (Typecheck.Sum (_, variants)) -> variants
      | _ -> []
    in
    let each (label, (declared : Typecheck.variant_decl)) =
      let carried_types = List.map snd (Ast.payload_fields declared.Typecheck.vd_payload) in
      let carried = Typecheck.attrs_of name label in
      record_value
        Core.variant
        [ "name", Value.Name label
        ; "arity", Value.Int (List.length carried_types)
        ; "payload", array_value (List.map ref_of_infer carried_types)
        ; ( "fields"
          , array_value
              (match declared.Typecheck.vd_payload with
               | Ast.P_fields named -> List.map (fun (label, _) -> Value.Name label) named
               | Ast.P_none | Ast.P_tuple _ -> []) )
        ; "doc", str_value (doc_of carried)
        ; "attrs", attrs_value (written carried)
        ]
    in
    variant_value Core.shape "Sum" [ Value.Name name; params_value name; array_value (List.map each variants) ]
  | _ -> variant_value Core.shape "Other" []

(* As written, as a diagnostic shows it: `Console`, not the name it carries for
   the module that declared it. *)
let type_name ty = str_value (Diagnostic.as_written (Types.string_of_ty ty))

let type_value ty =
  record_value
    reflection
    [ "name", type_name ty
    ; "shape", shape_of ty
    ; "attrs", attrs_value (written (declared_attrs ty))
    ; "doc", str_value (doc_of (declared_attrs ty))
    ]

(* One field of the answer when only that one is asked for, so a run-time
   `typeof(x).name` is a string and not a record. *)
let reflected span (ty : Types.ty) (field : string option) : Ast.expr =
  let v =
    match field with
    | Some "name" -> type_name ty
    | Some "shape" -> shape_of ty
    | Some "attrs" -> attrs_value (written (declared_attrs ty))
    | Some "doc" -> str_value (doc_of (declared_attrs ty))
    | _ -> type_value ty
  in
  Option.get (reify_with ~names:true span v)

type fragment =
  | Stmt of Ast.stmt
  | Expr of Ast.expr
  | Sig of Ast.method_sig
  | Type of Ast.type_expr

let syntax_types = List.map Core.syntax [ "Expr"; "Stmt"; "Decl"; "MethodSig"; "TypeExpr" ]

(* What a `gen` of a call evaluates rather than emits as written. *)
let is_syntax_type (t : Ast.type_expr) =
  match t.Ast.it with
  | Ast.Ty_name n -> List.mem n syntax_types
  | Ast.Ty_app (n, [ { Ast.it = Ast.Ty_name item; _ } ]) -> String.equal n Core.list && List.mem item syntax_types
  | _ -> false

let rec of_value span (v : Value.value) : fragment list =
  let read f = syntax span (fun () -> f ~fallback:span v) in
  match v, Syntax.kind_of v with
  | Value.Record (Some t, _), _ when String.equal t Core.list ->
    List.concat_map (of_value span) (syntax span (fun () -> Syntax.read_list Fun.id v))
  | _, Some Syntax.Expr_node -> [ Expr (read Syntax.to_expr) ]
  | _, Some Syntax.Stmt_node -> [ Stmt (read Syntax.to_stmt) ]
  | _, Some Syntax.Decl_node -> [ Stmt (read Syntax.to_decl) ]
  | _, Some Syntax.Type_node -> [ Type (read Syntax.to_type) ]
  | _, Some Syntax.Sig_node -> [ Sig (read Syntax.to_method_sig) ]
  | _, (Some Syntax.Stmts | None) -> fail span "This is not code, so gen cannot emit it."

let rec is_visible_to_meta (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn _ | `Type_decl _ | `Trait_decl _ | `Impl_decl _ -> true
  | `Attributed (_, inner) -> is_visible_to_meta inner
  | _ -> false

let rec is_fn (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn _ -> true
  | `Attributed (_, inner) -> is_fn inner
  | _ -> false

let rec is_impl (s : Ast.stmt) =
  match s.Ast.it with
  | `Impl_decl _ -> true
  | `Attributed (_, inner) -> is_impl inner
  | _ -> false

(* Where a meta block stands, and so what its fragments become. *)
type _ context =
  | Top : Ast.stmt list context (* outside every function, in a block or not *)
  | Module : Ast.stmt list context
  | Body : Ast.stmt list context
  | Meta_program : Ast.stmt list context
  | Expression : Ast.expr context
  | Type_body : Ast.stmt list context
  | Trait_body : Ast.method_sig list context

let described = function
  | Stmt s when is_visible_to_meta s -> "a declaration"
  | Stmt _ -> "a statement"
  | Expr _ -> "an expression"
  | Sig _ -> "a method signature"
  | Type _ -> "a type"

(* Errors are the meta block's, at its span: the code a `gen` emits is only
   wrong for where the block stands. *)
let fit : type a. a context -> Ast.span -> fragment list -> a =
  fun context span fragments ->
  let statement = function
    | Stmt s -> s
    | Expr e -> Ast.at e.Ast.span (`Expr e)
    | Sig _ -> fail span "A method signature can be generated only into a trait body."
    | Type _ -> fail span "A type cannot be generated on its own; it stands only inside other code."
  in
  match context with
  | Top -> List.map statement fragments
  | Meta_program -> List.map statement fragments
  | Module -> List.filter is_visible_to_meta (List.map statement fragments)
  | Body ->
    List.map
      (fun f ->
        let s = statement f in
        if is_impl s then fail span "An impl cannot be generated inside a function body.";
        s)
      fragments
  | Type_body ->
    List.map
      (fun f ->
        match f with
        | Stmt s when is_fn s -> s
        | _ -> fail span "A type's meta block can generate only its methods.")
      fragments
  | Trait_body ->
    List.map
      (function
        | Sig m -> m
        | _ -> fail span "A trait's meta block can generate only method signatures.")
      fragments
  | Expression ->
    let expected = "A meta block standing as an expression generates one expression" in
    (match fragments with
     | [ Expr e ] | [ Stmt { Ast.it = `Expr e; _ } ] -> e
     | [] -> fail span "%s; this one generated nothing." expected
     | [ other ] -> fail span "%s; this one generated %s." expected (described other)
     | many -> fail span "%s; this one generated %d." expected (List.length many))
