(* An invented annotation is wrong silently, so each node is checked against its
   children. Local: no environment, and a `Var` is taken at its word. *)

type error =
  { span : Ast.span
  ; message : string
  }

exception Failed of error

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Failed { span; message })) fmt

let expect span what expected actual =
  if expected <> actual
  then
    fail
      span
      "%s should be %s but is annotated %s."
      what
      (Types.string_of_ty expected)
      (Types.string_of_ty actual)

let listed names =
  match names with
  | [] -> "nothing"
  | names -> String.concat ", " (List.map (Printf.sprintf "'%s'") names)

let element span (t : Types.ty) =
  match t with
  | Types.Named (name, [ elem ], _) when String.equal name Types.array_name -> elem
  | other -> fail span "An array is annotated %s." (Types.string_of_ty other)

let rec expr (e : Ast.cps_expr) : unit =
  let span = e.Ast.span
  and ann = e.Ast.ann in
  match e.Ast.it with
  | `Unit -> expect span "A unit literal" Types.Unit ann
  | `Int _ -> expect span "An int literal" Types.Int ann
  | `Float _ -> expect span "A float literal" Types.Float ann
  | `Str _ -> expect span "A string literal" Types.Str ann
  | `Name _ -> expect span "A name" Types.name ann
  | `Bytes _ -> expect span "Embedded bytes" (Types.array Types.Byte) ann
  | `Char _ -> expect span "A char literal" Types.Chr ann
  | `Bool _ -> expect span "A bool literal" Types.Bool ann
  | `Var _ -> ()
  | `Assign (_, v) ->
    expr v;
    expect span "An assignment" v.Ast.ann ann
  | `Unop (Ast.Neg, a) ->
    expr a;
    expect span "A negation" a.Ast.ann ann
  | `Unop (Ast.Not, a) ->
    expr a;
    expect a.Ast.span "The operand of '!'" Types.Bool a.Ast.ann;
    expect span "A negation" Types.Bool ann
  | `Binop (op, a, b) ->
    expr a;
    expr b;
    expect b.Ast.span "Both operands" a.Ast.ann b.Ast.ann;
    (match op with
     | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod ->
       expect span "An arithmetic result" a.Ast.ann ann
     | Ast.Equal | Ast.Not_equal | Ast.Less | Ast.Less_equal | Ast.Greater
     | Ast.Greater_equal -> expect span "A comparison" Types.Bool ann)
  | `And (a, b) | `Or (a, b) ->
    expr a;
    expr b;
    expect a.Ast.span "The operand of a logical operator" Types.Bool a.Ast.ann;
    expect b.Ast.span "The operand of a logical operator" Types.Bool b.Ast.ann;
    expect span "A logical operator" Types.Bool ann
  | `Tuple items ->
    List.iter expr items;
    expect
      span
      "A tuple"
      (Types.Tuple (List.map (fun (i : Ast.cps_expr) -> i.Ast.ann) items))
      ann
  | `Record_lit fields ->
    List.iter (fun (_, v) -> expr v) fields;
    let actual =
      List.sort compare (List.map (fun (l, (v : Ast.cps_expr)) -> l, v.Ast.ann) fields)
    in
    (match ann with
     | Types.Record declared | Types.Named (_, _, declared) ->
       if declared <> actual
       then
         fail
           span
           "A record literal is annotated %s but its fields are %s."
           (Types.string_of_ty ann)
           (Types.string_of_ty (Types.Record actual))
     | other ->
       fail span "A record literal is annotated %s." (Types.string_of_ty other))
  | `Field (target, label) ->
    expr target;
    (match target.Ast.ann with
     | Types.Record fields | Types.Named (_, _, fields) ->
       (match List.assoc_opt label fields with
        | Some ty -> expect span "A field" ty ann
        | None -> fail span "A record has no field '%s'." label)
     | other ->
       fail target.Ast.span "Taking a field of %s." (Types.string_of_ty other))
  | `Field_assign (target, label, v) ->
    expr target;
    expr v;
    (match target.Ast.ann with
     | Types.Record fields | Types.Named (_, _, fields) ->
       (match List.assoc_opt label fields with
        | Some ty ->
          expect v.Ast.span "An assigned field" ty v.Ast.ann;
          expect span "A field assignment" ty ann
        | None -> fail span "A record has no field '%s'." label)
     | other ->
       fail target.Ast.span "Taking a field of %s." (Types.string_of_ty other))
  | `Tuple_get (target, index) ->
    expr target;
    (match target.Ast.ann with
     | Types.Tuple items ->
       (match List.nth_opt items index with
        | Some ty -> expect span "A tuple field" ty ann
        | None -> fail span "A tuple has no field %d." index)
     | other ->
       fail target.Ast.span "Taking a field of %s." (Types.string_of_ty other))
  | `Array_lit items ->
    List.iter expr items;
    let elem = element span ann in
    List.iter
      (fun (i : Ast.cps_expr) -> expect i.Ast.span "An array element" elem i.Ast.ann)
      items
  | `Array_new (length, fill) ->
    expr length;
    expr fill;
    expect length.Ast.span "An array's length" Types.Int length.Ast.ann;
    expect fill.Ast.span "An array's fill value" (element span ann) fill.Ast.ann
  | `Array_get (target, index) ->
    expr target;
    expr index;
    expect index.Ast.span "An index" Types.Int index.Ast.ann;
    expect span "An element" (element target.Ast.span target.Ast.ann) ann
  | `Array_set (target, index, v) ->
    expr target;
    expr index;
    expr v;
    expect index.Ast.span "An index" Types.Int index.Ast.ann;
    let elem = element target.Ast.span target.Ast.ann in
    expect v.Ast.span "An assigned element" elem v.Ast.ann;
    expect span "An index assignment" elem ann
  | `Str_get (target, index) ->
    expr target;
    expr index;
    expect target.Ast.span "An indexed string" Types.Str target.Ast.ann;
    expect index.Ast.span "An index" Types.Int index.Ast.ann;
    expect span "A character" Types.Chr ann
  | `Str_len target ->
    expr target;
    expect target.Ast.span "A measured string" Types.Str target.Ast.ann;
    expect span "A length" Types.Int ann
  | `Array_len target ->
    expr target;
    ignore (element target.Ast.span target.Ast.ann);
    expect span "A length" Types.Int ann
  | `Variant (_, fields) ->
    List.iter (fun (_, v) -> expr v) fields;
    (match ann with
     | Types.Sum _ -> ()
     | other -> fail span "A variant is annotated %s." (Types.string_of_ty other))
    | `Lambda (params, _, body) ->
    (match ann with
     | Types.Fn (declared, _, _) when List.length declared = List.length params ->
       List.iter stmt body
     | Types.Fn _ ->
       fail span "A lambda of %d parameter(s) is annotated %s." (List.length params)
         (Types.string_of_ty ann)
     | other -> fail span "A lambda is annotated %s." (Types.string_of_ty other))
  (* The object's own type says nothing about what it holds, so what is checked
     here is that each slot can take the data it was built beside, and that the
     trait's own methods are the ones the table holds. *)
  | `Object (data, vtable) ->
    expr data;
    (match ann with
     | Types.Named (trait, _, _) when Resolve.is_trait trait ->
       let owed = List.sort_uniq String.compare (Resolve.methods_of trait) in
       let held = List.sort_uniq String.compare (List.map fst vtable) in
       if owed <> held
       then
         fail
           span
           "A '%s' object holds %s, but the trait declares %s."
           trait
           (listed held)
           (listed owed)
     | other -> fail span "An object is annotated %s." (Types.string_of_ty other));
    List.iter
      (fun (name, (slot : Ast.cps_expr)) ->
        expr slot;
        match slot.Ast.ann with
        | Types.Fn (receiver :: _, _, _) ->
          expect slot.Ast.span "A vtable slot's receiver" receiver data.Ast.ann
        | other ->
          fail slot.Ast.span "'%s' is annotated %s, which takes no receiver." name
            (Types.string_of_ty other))
      vtable
  | `Dyn_call (receiver, name, _, args) ->
    expr receiver;
    List.iter expr args;
    (match receiver.Ast.ann with
     | Types.Named (trait, _, _) when Resolve.is_trait trait ->
       if not (List.mem name (Resolve.methods_of trait))
       then fail span "'%s' declares no '%s' to dispatch on." trait name
     | other ->
       fail
         receiver.Ast.span
         "'%s' is called on %s, which is not an object."
         name
         (Types.string_of_ty other))
  | `Call (callee, args) ->
    expr callee;
    List.iter expr args;
    (match callee.Ast.ann with
     | Types.Fn (params, ret, _) ->
       if List.length params <> List.length args
       then
         fail
           span
           "A call passes %d argument(s) to a function of %d."
           (List.length args)
           (List.length params);
       List.iter2
         (fun param (a : Ast.cps_expr) ->
           expect a.Ast.span "An argument" param a.Ast.ann)
         params
         args;
       expect span "A call" ret ann
     | other ->
       fail
         callee.Ast.span
         "A callee is annotated %s, which is not a function."
         (Types.string_of_ty other))

and stmt (s : Ast.cps_stmt) : unit =
  match s.Ast.it with
  | `Expr e -> expr e
  | `Var_tuple (_, init) -> expr init
  | `Scope (_, body, on_abort) ->
    List.iter stmt body;
    List.iter stmt on_abort
  | `Defer s -> stmt s
  | `Abort _ -> ()
  | `On_unwind (body, cleanup) ->
    List.iter stmt body;
    List.iter stmt cleanup
  | `Var_decl (_, _, init) -> Option.iter expr init
  | `Block body -> List.iter stmt body
  | `If (cond, then_branch, else_branch) ->
    expr cond;
    expect cond.Ast.span "A condition" Types.Bool cond.Ast.ann;
    stmt then_branch;
    Option.iter stmt else_branch
  | `While (cond, body) ->
    expr cond;
    expect cond.Ast.span "A condition" Types.Bool cond.Ast.ann;
    stmt body
  | `Fn (_, _, _, body) -> List.iter stmt body
  | `Cont (_, _, body) | `Frame (_, _, body) -> List.iter stmt body
  | `Return e -> Option.iter expr e
  | `Match (scrutinee, cases) ->
    expr scrutinee;
    List.iter (fun (_, body) -> List.iter stmt body) cases

let program (p : Ast.cps_stmt list) : (unit, error) result =
  try
    List.iter stmt p;
    Ok ()
  with
  | Failed e -> Error e
