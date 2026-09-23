(* After checking, when the annotation exists; before evaluation, so the
   interpreter never sees the node. Each answer is folded here into the data it
   names, leaving ordinary Cronyx.

   Answers are one level deep: a field reports its name, not its type, so a type
   that mentions itself describes itself in finite space. *)

type error =
  { span : Ast.span
  ; message : string
  }

exception Failed of error

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Failed { span; message })) fmt

let node span ann it : Ast.reflected_expr = { Ast.it; span; ann }

let string_at span text = node span Types.Str (`Str (Utf8.decode text))

let record_at span name fields values =
  node span (Types.Named (name, [], fields)) (`Record_lit values)

let array_at span elem items =
  node span (Types.array elem) (`Array_lit items)

let name_at span text = node span Types.name (`Name text)
let attr_arg_ty = Types.Sum (Types.attr_arg_name, [])

let attr_ty =
  Types.Named
    (Types.attr_name, [], [ "args", Types.array attr_arg_ty; "name", Types.name ])

(* Only a named type can be asked: `typeof` takes a value, and a function
   value's type names no declaration to look the attributes up under. *)
let declared_attrs (ty : Types.ty) =
  match ty with
  | Types.Named (name, _, _) | Types.Sum (name, _) ->
    (match Hashtbl.find_opt Desugar.decl_attrs name with
     | Some attrs -> attrs
     | None -> [])
  | _ -> []

let field_ty =
  Types.Named
    (Types.field_name, [], [ "attrs", Types.array attr_ty; "name", Types.name ])

let variant_ty =
  Types.Named
    ( Types.variant_name
    , []
    , [ "arity", Types.Int; "attrs", Types.array attr_ty; "name", Types.name ] )

let attrs_at span (list : Ast.attr list) =
  let arg (a : Ast.attr_arg) =
    let variant, payload =
      match a with
      | Ast.A_str text -> "Str", string_at span text
      | Ast.A_int value -> "Int", node span Types.Int (`Int value)
      | Ast.A_float value -> "Float", node span Types.Float (`Float value)
      | Ast.A_bool value -> "Bool", node span Types.Bool (`Bool value)
    in
    node span attr_arg_ty (`Variant (variant, [ "0", payload ]))
  in
  let one (a : Ast.attr) =
    record_at
      span
      Types.attr_name
      [ "args", Types.array attr_arg_ty; "name", Types.name ]
      [ "args", array_at span attr_arg_ty (List.map arg a.Ast.a_args)
      ; "name", name_at span a.Ast.a_name
      ]
  in
  array_at span attr_ty (List.map one list)

let shape_ty = Types.Sum (Types.shape_name, [])

let shape_at span variant payload =
  node span shape_ty (`Variant (variant, payload))

(* A product carries its fields in the type; a sum names its variants nowhere
   but the table the checker built, so reflection reads that. *)
let shape_of span (ty : Types.ty) =
  let one name = shape_at span name [] in
  match ty with
  | Types.Int | Types.Float | Types.Str | Types.Byte | Types.Chr | Types.Bool
  | Types.Unit -> one "Scalar"
  | Types.Named (name, _, fields) when not (String.equal name Types.array_name) ->
    let each (label, _) =
      record_at
        span
        Types.field_name
        [ "attrs", Types.array attr_ty; "name", Types.name ]
        [ "attrs", attrs_at span (Typecheck.attrs_of name label)
        ; "name", name_at span label
        ]
    in
    shape_at
      span
      "Product"
      [ "0", name_at span name; "1", array_at span field_ty (List.map each fields) ]
  | Types.Sum (name, _) ->
    let variants =
      match Hashtbl.find_opt Typecheck.ctx_types name with
      | Some (Typecheck.Sum (_, variants)) -> variants
      | _ -> []
    in
    let each (label, (declared : Typecheck.variant_decl)) =
      let arity =
        match declared.Typecheck.vd_payload with
        | Ast.P_none -> 0
        | Ast.P_tuple items -> List.length items
        | Ast.P_fields items -> List.length items
      in
      record_at
        span
        Types.variant_name
        [ "arity", Types.Int; "attrs", Types.array attr_ty; "name", Types.name ]
        [ "arity", node span Types.Int (`Int arity)
        ; "attrs", attrs_at span (Typecheck.attrs_of name label)
        ; "name", name_at span label
        ]
    in
    shape_at
      span
      "Sum"
      [ "0", name_at span name; "1", array_at span variant_ty (List.map each variants) ]
  | _ -> one "Other"

let rec expr (e : Ast.resolved_expr) : Ast.reflected_expr =
  let it : Ast.reflected_expr_kind =
    match e.Ast.it with
    | `Field ({ Ast.it = `Typeof inner; _ }, "name") ->
      (string_at e.Ast.span (Types.string_of_ty inner.Ast.ann)).Ast.it
    | `Field ({ Ast.it = `Typeof inner; _ }, "shape") ->
      (shape_of e.Ast.span inner.Ast.ann).Ast.it
    | `Field ({ Ast.it = `Typeof inner; _ }, "attrs") ->
      (attrs_at e.Ast.span (declared_attrs inner.Ast.ann)).Ast.it
    | `Typeof _ ->
      fail
        e.Ast.span
        "A type is not a value here. Ask for what you need of it, as \
         'typeof(x).name', 'typeof(x).shape' or 'typeof(x).attrs'."
    | #Ast.lit as l -> l
    | #Ast.arrays as a -> (Ast.map_arrays expr a :> Ast.reflected_expr_kind)
    | #Ast.strings as s -> (Ast.map_strings expr s :> Ast.reflected_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars expr v :> Ast.reflected_expr_kind)
    | #Ast.ops as o -> (Ast.map_ops expr o :> Ast.reflected_expr_kind)
    | #Ast.logic as l -> (Ast.map_logic expr l :> Ast.reflected_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple expr t :> Ast.reflected_expr_kind)
    | #Ast.record as r -> (Ast.map_record expr r :> Ast.reflected_expr_kind)
    | `Lambda (params, signature, body) ->
      `Lambda (params, signature, List.map stmt body)
    | #Ast.variant_lit as v ->
      (Ast.map_variant_lit expr v :> Ast.reflected_expr_kind)
    | #Ast.objects as o -> (Ast.map_object expr o :> Ast.reflected_expr_kind)
  in
  { Ast.it; span = e.Ast.span; ann = e.Ast.ann }

and stmt (s : Ast.resolved_stmt) : Ast.reflected_stmt =
  let it : Ast.reflected_stmt_kind =
    match s.Ast.it with
    | #Ast.stmts as st -> (Ast.map_stmts expr stmt st :> Ast.reflected_stmt_kind)
    | #Ast.effects as e -> (Ast.map_effects expr stmt (Ast.map_handler stmt) e :> Ast.reflected_stmt_kind)
    | #Ast.type_defs as t -> t
    | #Ast.matching as m ->
      (Ast.map_matching expr stmt m :> Ast.reflected_stmt_kind)
  in
  { Ast.it; span = s.Ast.span; ann = s.Ast.ann }

let program (p : Ast.resolved_stmt list) : (Ast.reflected_stmt list, error) result =
  try Ok (List.map stmt p) with
  | Failed e -> Error e
