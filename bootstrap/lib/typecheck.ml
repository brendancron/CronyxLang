(* A node's type is not finished when it is first visited — `x` in
   `fn f(x) { return x + 1; }` is pinned at the `+` — so the tree is built with
   mutable types and resolved once at the end. *)

type error =
  { span : Ast.span
  ; message : string
  }

exception Located of error

type checked_expr = (checked_expr_kind, Types.infer_ty) Ast.node

and checked_expr_kind =
  [ Ast.lit
  | checked_expr Ast.vars
  | checked_expr Ast.ops
  | checked_expr Ast.logic
  | checked_expr Ast.compound
  | checked_expr Ast.indexing
  | checked_expr Ast.tuple
  | checked_expr Ast.record
  | checked_expr Ast.nominal
  | checked_expr Ast.collection
  | checked_expr Ast.arrays
  | checked_expr Ast.strings
  | checked_expr Ast.method_call
  | checked_expr Ast.reflect
  | (checked_expr, checked_stmt) Ast.lambdas
  | (checked_expr, checked_stmt, checked_stmt Ast.handler) Ast.run_expr
  ]

and checked_stmt = (checked_stmt_kind, Types.infer_ty) Ast.node

and checked_stmt_kind =
  [ (checked_expr, checked_stmt) Ast.stmts
  | (checked_expr, checked_stmt, checked_stmt Ast.handler) Ast.effects
  | Ast.type_defs
  | (checked_expr, checked_stmt) Ast.matching
  | (checked_stmt, Types.infer_ty) Ast.method_defs
  ]

type env =
  { bindings : (string, Types.scheme) Hashtbl.t
  ; parent : env option
  }

type ctx =
  { registry : Registry.t
  ; mutable return_type : Types.infer_ty option
  ; mutable saw_return : bool
  ; mutable row : Types.infer_row
  ; mutable resume_type : Types.infer_ty option
  ; mutable in_final_arm : bool
  }

type effect_info =
  { ops : (string, Ast.op_decl) Hashtbl.t
  ; declared : (string, Ast.op_decl list) Hashtbl.t
  }

let ctx_effects = { ops = Hashtbl.create 16; declared = Hashtbl.create 8 }

(* Operations share one namespace, so a second declaration would silently
   overwrite the first and every call site be checked against it. *)
let ctx_op_owner : (string, string) Hashtbl.t = Hashtbl.create 16

let ctx_effect_params : (string, (string * Types.infer_ty) list) Hashtbl.t =
  Hashtbl.create 8

type decl =
  | Opaque of Types.infer_ty list
  | Product of Types.infer_ty list * Types.infer_fields
  | Sum of Types.infer_ty list * (string * variant_decl) list

(* A GADT variant is what makes these worth carrying. *)
and variant_decl =
  { vd_params : Types.infer_ty list
  ; vd_payload : Types.infer_ty Ast.payload
  ; vd_result : Types.infer_ty list
  (* Matching it says something about the scrutinee, scoped to the arm. *)
  ; vd_refines : bool
  }

let ctx_types : (string, decl) Hashtbl.t = Hashtbl.create 16

(* Attributes are inert, so they stay out of [decl] — nothing unification or
   monomorphization touches has a reason to carry them. [Reflect] is the only
   reader, and it asks by type name and member label. *)
let ctx_attrs : (string, (string * Ast.attr list) list) Hashtbl.t = Hashtbl.create 8

let attrs_of name label =
  match Hashtbl.find_opt ctx_attrs name with
  | None -> []
  | Some members ->
    (match List.assoc_opt label members with
     | None -> []
     | Some attrs -> attrs)

let ctx_type_params : (string, Types.infer_ty) Hashtbl.t = Hashtbl.create 8

let decl_params = function
  | Opaque vars | Product (vars, _) | Sum (vars, _) -> vars

let params_of_decl name =
  match Hashtbl.find_opt ctx_types name with
  | Some decl -> decl_params decl
  | None -> []

let instance vars args = List.map2 (fun v a -> Types.var_id v, a) vars args

(* The type's parameters and the variant's own together: a payload or head may
   mention both. *)
let instantiation vars declared =
  let bound = vars @ declared.vd_params in
  instance bound (List.map (fun _ -> Types.fresh ()) bound)

let ctx_fn_params : (string, (string * Types.infer_ty) list) Hashtbl.t =
  Hashtbl.create 16

(* A parameter standing in a row is a row variable rather than an effect named
   after it, so each also gets one. Which of the two a mention is follows from
   where it stands, as it does in Koka. *)
let ctx_row_params : (string, Types.infer_row) Hashtbl.t = Hashtbl.create 8

let with_type_params assoc f =
  let saved =
    List.map
      (fun (name, _) ->
        name, Hashtbl.find_opt ctx_type_params name, Hashtbl.find_opt ctx_row_params name)
      assoc
  in
  List.iter
    (fun (name, var) ->
      Hashtbl.replace ctx_type_params name var;
      let row = Types.fresh_row () in
      Types.declare_row row;
      Hashtbl.replace ctx_row_params name row)
    assoc;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (name, previous, previous_row) ->
          (match previous with
           | Some var -> Hashtbl.replace ctx_type_params name var
           | None -> Hashtbl.remove ctx_type_params name);
          match previous_row with
          | Some row -> Hashtbl.replace ctx_row_params name row
          | None -> Hashtbl.remove ctx_row_params name)
        saved)
    f

(* Two impls of one trait at different arguments are told apart here. *)
(* The span is kept so that a second impl of the same method can name the first
   one. Coherence is global after concatenation, so the two are often in
   different packages and the other site is the half a reader is missing. *)
let ctx_entries : (string, Ast.span) Hashtbl.t = Hashtbl.create 32

let ctx_associated : (string * string, unit) Hashtbl.t = Hashtbl.create 8

let ctx_traits : (string, string list * Ast.trait_body) Hashtbl.t = Hashtbl.create 8

(* So a program's declaration can be told from the prelude's. *)
let ctx_trait_spans : (string, Ast.span) Hashtbl.t = Hashtbl.create 8
let ctx_type_spans : (string, Ast.span) Hashtbl.t = Hashtbl.create 8

(* No trait in the key: two naming the same associated type would collide. *)
let ctx_assoc : (string * string, Types.infer_ty) Hashtbl.t = Hashtbl.create 8

(* Added rather than replaced: one type may implement a trait at more than one
   argument. *)
let ctx_impls : (string * string, Types.infer_ty list) Hashtbl.t = Hashtbl.create 8

(* So a call site can ask whether the name still refers to it rather than
   testing the spelling: a program declaring its own `print` gets its own. *)
let ctx_variadic : (string, Types.scheme * Types.infer_ty) Hashtbl.t = Hashtbl.create 4
let ctx_methods : (string * string, unit) Hashtbl.t = Hashtbl.create 32

(* The tables are program-global, so what a block adds is taken back out on the
   way past it. [add] rather than [replace]: [ctx_impls] keeps every entry for a
   key, and the snapshot is oldest-first. *)
let scoped_declarations f =
  let snapshot table = Hashtbl.fold (fun key v acc -> (key, v) :: acc) table [] in
  let restore table saved =
    Hashtbl.reset table;
    List.iter (fun (key, v) -> Hashtbl.add table key v) saved
  in
  let types = snapshot ctx_types
  and attrs = snapshot ctx_attrs
  and traits = snapshot ctx_traits
  and trait_spans = snapshot ctx_trait_spans
  and type_spans = snapshot ctx_type_spans
  and methods = snapshot ctx_methods
  and impls = snapshot ctx_impls
  and associated = snapshot ctx_associated
  and entries = snapshot ctx_entries
  and assoc = snapshot ctx_assoc
  and ops = snapshot ctx_effects.ops
  and declared = snapshot ctx_effects.declared
  and owners = snapshot ctx_op_owner
  and effect_params = snapshot ctx_effect_params in
  Fun.protect
    ~finally:(fun () ->
      restore ctx_types types;
      restore ctx_attrs attrs;
      restore ctx_traits traits;
      restore ctx_trait_spans trait_spans;
      restore ctx_type_spans type_spans;
      restore ctx_methods methods;
      restore ctx_impls impls;
      restore ctx_associated associated;
      restore ctx_entries entries;
      restore ctx_assoc assoc;
      restore ctx_effects.ops ops;
      restore ctx_effects.declared declared;
      restore ctx_op_owner owners;
      restore ctx_effect_params effect_params)
    f

let reset_effects () =
  Hashtbl.reset ctx_effects.ops;
  Hashtbl.reset ctx_effects.declared;
  Hashtbl.reset ctx_op_owner;
  Hashtbl.reset ctx_types;
  Hashtbl.reset ctx_attrs;
  Hashtbl.reset ctx_effect_params;
  Hashtbl.reset ctx_traits;
  Hashtbl.reset ctx_trait_spans;
  Hashtbl.reset ctx_type_spans;
  Hashtbl.reset ctx_associated;
  Hashtbl.reset ctx_entries;
  Hashtbl.reset ctx_assoc;
  Hashtbl.reset ctx_impls;
  Hashtbl.reset ctx_variadic;
  Hashtbl.reset ctx_methods;
  Hashtbl.reset ctx_type_params;
  Hashtbl.reset ctx_fn_params

let new_env parent = { bindings = Hashtbl.create 16; parent }
let bind env name scheme = Hashtbl.replace env.bindings name scheme

let rec lookup env name =
  match Hashtbl.find_opt env.bindings name with
  | Some scheme -> Some scheme
  | None ->
    (match env.parent with
     | Some p -> lookup p name
     | None -> None)

(* Generalization must not quantify a variable the enclosing scope still uses. *)
let env_free ~free ~quantified env =
  let acc = ref [] in
  let rec walk env =
    Hashtbl.iter
      (fun _ (scheme : Types.scheme) ->
        free scheme.Types.body
        |> List.iter (fun id ->
          if (not (List.mem id (quantified scheme))) && not (List.mem id !acc)
          then acc := id :: !acc))
      env.bindings;
    Option.iter walk env.parent
  in
  walk env;
  !acc

let env_free_vars env =
  env_free
    ~free:(fun body -> List.map fst (Types.free_vars body))
    ~quantified:(fun (s : Types.scheme) -> s.Types.quantified)
    env

let env_free_row_vars env =
  env_free
    ~free:Types.free_row_vars
    ~quantified:(fun (s : Types.scheme) -> s.Types.quantified_rows)
    env

let env_free_field_vars env =
  env_free
    ~free:Types.free_field_vars
    ~quantified:(fun (s : Types.scheme) -> s.Types.quantified_fields)
    env

(* The other end of a two-site diagnostic. The tail of the path rather than the
   whole of it: a span renders relative to the entry and the entry is not this
   one, so an absolute path would leak the machine it was built on -- but a
   basename alone reads as `lib.cx` for every package there is. *)
let where span =
  match Source_map.Span.view span with
  | Source_map.Span.Located l ->
    let path = Source_map.File.path l.Source_map.Span.file in
    let tail =
      match List.rev (String.split_on_char '/' path) with
      | file :: directory :: package :: _ -> String.concat "/" [ package; directory; file ]
      | segments -> String.concat "/" (List.rev segments)
    in
    Printf.sprintf "%s:%d" tail l.Source_map.Span.line
  | Source_map.Span.Nowhere_in_source -> "elsewhere"

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Located { span; message })) fmt

type receiver =
  | Owner of string
  | Via_trait of string

(* Which trait gives an operator its meaning, and whether that trait fixes the
   result at bool rather than binding an `Output`. *)
let trait_of_operator (op : Ast.binop) =
  match op with
  | Ast.Add -> Some ("Add", false)
  | Ast.Sub -> Some ("Sub", false)
  | Ast.Mul -> Some ("Mul", false)
  | Ast.Div -> Some ("Div", false)
  | Ast.Mod -> Some ("Rem", false)
  (* `==` compares any two values of a type structurally, so it constrains an
     operand no further. What `T: Eq` asks for is an impl to reach, which is a
     different question from whether the operator works. *)
  | Ast.Equal | Ast.Not_equal -> None
  | Ast.Less | Ast.Less_equal | Ast.Greater | Ast.Greater_equal ->
    Some ("PartialOrd", true)

let operator_traits =
  [ "Add", (Ast.Add, "add")
  ; "Sub", (Ast.Sub, "sub")
  ; "Mul", (Ast.Mul, "mul")
  ; "Div", (Ast.Div, "div")
  ; "Rem", (Ast.Mod, "rem")
  ]

(* [seen] guards a cycle, which nothing rejects yet. *)
let rec trait_closure ?(seen = []) (trait : string) : string list =
  if List.mem trait seen
  then seen
  else (
    let seen = trait :: seen in
    match Hashtbl.find_opt ctx_traits trait with
    | None -> seen
    | Some (_, body) ->
      List.fold_left
        (fun seen (super, _) -> trait_closure ~seen super)
        seen
        body.Ast.tb_super)

let declares trait name =
  match Hashtbl.find_opt ctx_traits trait with
  | None -> false
  | Some (_, body) ->
    List.exists (fun (m : Ast.method_sig) -> String.equal m.Ast.ms_name name) body.Ast.tb_methods

let listed names =
  match List.rev names with
  | [] -> ""
  | [ only ] -> only
  | last :: earlier -> String.concat ", " (List.rev earlier) ^ " and " ^ last

(* Guessing the owner is unsound: three types declare `len`. *)
let receiver_of span registry (receiver : (_, Types.infer_ty) Ast.node) name elem_owners =
  match Types.infer_type_name receiver.Ast.ann with
  | Some owner -> Owner owner
  | None ->
    (match Types.repr receiver.Ast.ann with
     | Types.IVar { contents = Types.Unbound (_, Types.Bound traits) } ->
       (* The one that answers declares the method, not the one written
          first. *)
       let reachable =
         List.concat_map (fun (b : Types.bound) -> trait_closure b.Types.bd_trait) traits
       in
       (match List.find_opt (fun trait -> declares trait name) reachable, traits with
        | Some trait, _ -> Via_trait trait
        | None, first :: _ -> Via_trait first.Types.bd_trait
        | None, [] ->
          fail span "Cannot call '%s': the receiver's type is not known here." name)
     | Types.IVar { contents = Types.Unbound (_, Types.Collection elem) } ->
       let holds owner =
         String.equal owner Types.array_name || Registry.container registry owner <> None
       in
       let candidates = List.filter holds elem_owners in
       let narrow_to owner =
         (match
            (if String.equal owner Types.array_name
             then Some (Types.iarray elem)
             else (
               match Registry.container registry owner with
               | Some c ->
                 (match Types.repr (Types.instantiate c.Registry.scheme) with
                  | Types.IFn ([ element ], result, _) ->
                    Types.unify element elem;
                    Some result
                  | _ -> None)
               | None -> None))
          with
          | Some ty ->
            (try Types.unify receiver.Ast.ann ty with
             | Types.Type_error message -> raise (Located { span; message }))
          | None -> fail span "'%s' cannot be built from a literal." owner);
         Owner owner
       in
       (match candidates with
        | [] -> fail span "No container has a method '%s'." name
        | _ when List.mem Types.array_name candidates -> narrow_to Types.array_name
        | [ only ] -> narrow_to only
        | several ->
          fail span
            "'%s' does not say which container this is: %s all declare it."
            name
            (listed several))
     | Types.IVar _ ->
       (match elem_owners with
        | [] -> fail span "No type has a method '%s'." name
        | owners ->
          fail span
            "Cannot call '%s': the receiver's type is not known here. %s declare one, so this needs a bound or an annotation."
            name
            (listed owners))
     | other ->
       fail span
         "Cannot call '%s' on %s, which no impl can name."
         name
         (Types.string_of_infer_ty other))

(* A callee quantifying no rows is concrete, or still being inferred and
   sharing a row variable with its own definition. Only the second ties. *)
let admits_row (callee : Types.scheme option) row (caller : Types.infer_row) =
  let pending =
    (not (Types.row_is_declared row))
    &&
    match Types.repr_row row, callee with
    | Types.RVar _, Some { Types.quantified_rows = []; _ } -> true
    | Types.RVar _, None -> true
    | _ -> false
  in
  if pending then Types.unify_row row caller else Types.row_within row caller

let unify_at span expected actual =
  try Types.unify expected actual with
  | Types.Type_error message -> raise (Located { span; message })

(* Put back however the body leaves: [check] carries on after an error, and a
   field pointing at the failed function would follow it. *)
let in_ctx ctx ~set body =
  let saved =
    ctx.return_type, ctx.saw_return, ctx.row, ctx.resume_type, ctx.in_final_arm
  in
  let restore () =
    let return_type, saw_return, row, resume_type, in_final_arm = saved in
    ctx.return_type <- return_type;
    ctx.saw_return <- saw_return;
    ctx.row <- row;
    ctx.resume_type <- resume_type;
    ctx.in_final_arm <- in_final_arm
  in
  Fun.protect ~finally:restore (fun () ->
    set ();
    body ())

let in_function_body ctx ~ret ~row body =
  in_ctx
    ctx
    ~set:(fun () ->
      ctx.return_type <- Some ret;
      ctx.saw_return <- false;
      ctx.row <- row)
    (fun () ->
      let checked = body () in
      if not ctx.saw_return then Types.unify ret Types.IUnit;
      checked)

(* Not in [ctx_types], so anything resolving a written name has to ask here. *)
let primitive = function
  | "int" -> Some Types.IInt
  | "float" -> Some Types.IFloat
  | "string" -> Some Types.IStr
  | "byte" -> Some Types.IByte
  | "char" -> Some Types.IChr
  | "bool" -> Some Types.IBool
  | "unit" -> Some Types.IUnit
  | _ -> None

let rec infer_ty_of_annotation (t : Ast.type_expr) : Types.infer_ty =
  match t.Ast.it with
  | Ast.Ty_variadic element -> Types.iarray (infer_ty_of_annotation element)
  | Ast.Ty_name name when primitive name <> None -> Option.get (primitive name)
  | Ast.Ty_tuple items -> Types.ITuple (List.map infer_ty_of_annotation items)
  | Ast.Ty_record fields ->
    Types.IRecord
      (List.fold_right
         (fun (l, t) rest -> Types.FCons (l, infer_ty_of_annotation t, rest))
         fields
         Types.FEmpty)
  | Ast.Ty_app (name, args) ->
    named_type t.Ast.span name (List.map infer_ty_of_annotation args)
  | Ast.Ty_name other ->
    (match Hashtbl.find_opt ctx_type_params other with
     | Some var -> var
     | None -> named_type t.Ast.span other [])
  (* The copy [Type_mono] makes has a concrete owner; this one may not. *)
  | Ast.Ty_assoc (owner, member) ->
    Types.project (infer_ty_of_annotation owner) member
  (* [type_params_of] reads it off before the rest become types. *)
  | Ast.Ty_bind (bound, _) -> fail t.Ast.span "'%s = ...' is only allowed in a bound." bound
  | Ast.Ty_fn (params, ret, row) ->
    Types.IFn
      ( List.map infer_ty_of_annotation params
      , infer_ty_of_annotation ret
      , row_of_labels row )

and named_type span name args =
  if String.equal name Types.reflection_name && args = []
  then Types.ireflected
  else if String.equal name Types.code_name && args = []
  then Types.icode
  else if String.equal name Types.name_name && args = []
  then Types.iname
  else if String.equal name Types.array_name
  then (
    match args with
    | [ elem ] -> Types.iarray elem
    | _ ->
      fail
        span
        "Type '%s' takes 1 argument(s) but %d were given."
        name
        (List.length args))
  else
    match Hashtbl.find_opt ctx_types name with
    | None -> fail span "Unknown type '%s'." name
    | Some decl ->
      let vars = decl_params decl in
      if List.length vars <> List.length args
      then
        fail
          span
          "Type '%s' takes %d argument(s) but %d were given."
          name
          (List.length vars)
          (List.length args);
      (match decl with
       | Opaque _ -> Types.INamed (name, args, Types.FEmpty)
       | Product (_, fields) ->
         Types.INamed (name, args, Types.substitute_fields (instance vars args) fields)
       | Sum _ -> Types.ISum (name, args))

(* Each entry takes fresh arguments; a use is what settles them. *)
and row_of_labels labels =
  let tail =
    match List.filter_map (Hashtbl.find_opt ctx_row_params) labels with
    | [] -> Types.REmpty
    | [ row ] -> row
    | _ -> Types.error "A row may be open in one variable, not several."
  in
  List.fold_right
    (fun label rest ->
      if Hashtbl.mem ctx_row_params label
      then rest
      else (
        let arity =
          List.length (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params label))
        in
        Types.RCons (label, List.init arity (fun _ -> Types.fresh ()), rest)))
    labels
    tail

(* What is registered here is undone before returning; the caller installs the
   whole list. *)
let type_params_of span (comptime : Ast.comptime_param list) =
  let touched = List.map (fun (p : Ast.comptime_param) ->
    p.Ast.cp_name, Hashtbl.find_opt ctx_type_params p.Ast.cp_name) comptime
  in
  let restore () =
    List.iter
      (fun (name, previous) ->
        match previous with
        | Some var -> Hashtbl.replace ctx_type_params name var
        | None -> Hashtbl.remove ctx_type_params name)
      touched
  in
  Fun.protect ~finally:restore (fun () ->
    (* A bound may name the parameter it constrains. *)
    let declared =
      List.map
        (fun (p : Ast.comptime_param) ->
          match p.Ast.cp_ty with
          | None | Some { Ast.it = Ast.Ty_name _ | Ast.Ty_app _; _ } ->
            let var = Types.fresh () in
            Types.declare_param var;
            Hashtbl.replace ctx_type_params p.Ast.cp_name var;
            p, var
          | Some _ ->
            fail span "Comptime value parameter '%s' is not supported yet." p.Ast.cp_name)
        comptime
    in
    List.iter
      (fun ((p : Ast.comptime_param), var) ->
        match p.Ast.cp_ty with
        | None -> ()
        | Some { Ast.it = Ast.Ty_name trait; _ } when Hashtbl.mem ctx_traits trait ->
          Types.constrain
            var
            (Types.Bound [ { Types.bd_trait = trait; bd_args = []; bd_bindings = [] } ])
        (* An `Output = T` among them says what the impl must have bound. *)
        | Some { Ast.it = Ast.Ty_app (trait, args); _ } when Hashtbl.mem ctx_traits trait ->
          let bindings, args =
            List.partition_map
              (fun (a : Ast.type_expr) ->
                match a.Ast.it with
                | Ast.Ty_bind (name, bound) -> Either.Left (name, bound)
                | _ -> Either.Right a)
              args
          in
          let bd_args = List.map infer_ty_of_annotation args
          and bd_bindings = List.map (fun (m, b) -> m, infer_ty_of_annotation b) bindings in
          Types.constrain
            var
            (Types.Bound [ { Types.bd_trait = trait; bd_args; bd_bindings } ])
        | Some _ ->
          fail span "Comptime value parameter '%s' is not supported yet." p.Ast.cp_name)
      declared;
    List.map (fun ((p : Ast.comptime_param), var) -> p.Ast.cp_name, var) declared)

let annotated_or_fresh = function
  | Some t -> infer_ty_of_annotation t
  | None -> Types.fresh ()

(* `var f = someGenericFn; f = otherFn;` would otherwise check. *)
let is_syntactic_value (e : Ast.desugared_expr) =
  match e.Ast.it with
  | #Ast.lit | `Var _ -> true
  | _ -> false

let rec assigned_in_expr (e : Ast.desugared_expr) acc =
  match e.Ast.it with
  (* What a lambda assigns it assigns when called, not where it stands. *)
  | `Lambda _ -> acc
  | #Ast.lit | `Var _ -> acc
  | `Assign (name, v) | `Compound (_, name, v) -> assigned_in_expr v (name :: acc)
  | `Unop (_, a) -> assigned_in_expr a acc
  | `Binop (_, a, b) | `And (a, b) | `Or (a, b) ->
    assigned_in_expr b (assigned_in_expr a acc)
  | `Call (callee, args) ->
    List.fold_left (fun acc a -> assigned_in_expr a acc) (assigned_in_expr callee acc) args
  | `Typeof e -> assigned_in_expr e acc
  | `Method_call (receiver, _, _, args) | `Comptime_call (receiver, _, args) ->
    List.fold_left
      (fun acc a -> assigned_in_expr a acc)
      (assigned_in_expr receiver acc)
      args
  | `Index (a, b) -> assigned_in_expr b (assigned_in_expr a acc)
  | `Index_assign (a, b, c) ->
    assigned_in_expr c (assigned_in_expr b (assigned_in_expr a acc))
  | `Collection_lit items | `Tuple items ->
    List.fold_left (fun acc i -> assigned_in_expr i acc) acc items
  | `Tuple_get (t, _) | `Field (t, _) -> assigned_in_expr t acc
  | `Record_lit fields ->
    List.fold_left (fun acc (_, v) -> assigned_in_expr v acc) acc fields
  | `Field_assign (r, _, v) -> assigned_in_expr v (assigned_in_expr r acc)
  | `New (_, fields) ->
    List.fold_left (fun acc (_, v) -> assigned_in_expr v acc) acc fields
  | `New_call (_, _, args) ->
    List.fold_left (fun acc a -> assigned_in_expr a acc) acc args
  | `New_variant (_, _, payload) ->
    List.fold_left
      (fun acc (_, v) -> assigned_in_expr v acc)
      acc
      (Ast.payload_fields payload)
  | `Run_expr (body, handlers, clause) ->
    let block b acc =
      let acc = List.fold_left (fun acc st -> assigned_in_stmt st acc) acc b.Ast.vb_stmts in
      Option.fold ~none:acc ~some:(fun v -> assigned_in_expr v acc) b.Ast.vb_value
    in
    let acc = block body acc in
    let acc =
      List.fold_left
        (fun acc (h : Ast.desugared_stmt Ast.handler) ->
          List.fold_left
            (fun acc (a : Ast.desugared_stmt Ast.arm) ->
              List.fold_left (fun acc st -> assigned_in_stmt st acc) acc a.Ast.arm_body)
            acc
            h.Ast.arms)
        acc
        handlers
    in
    Option.fold ~none:acc ~some:(fun c -> block c.Ast.rc_body acc) clause

and assigned_in_stmt (s : Ast.desugared_stmt) acc =
  let opt f o acc =
    match o with
    | Some x -> f x acc
    | None -> acc
  in
  match s.Ast.it with
  | `Expr e -> assigned_in_expr e acc
  | `Var_tuple (_, init) -> assigned_in_expr init acc
  | `Defer inner -> assigned_in_stmt inner acc
  | `Var_decl (_, _, init) -> opt assigned_in_expr init acc
  | `Block body | `Fn (_, _, _, body) ->
    List.fold_left (fun acc st -> assigned_in_stmt st acc) acc body
  | `If (cond, then_branch, else_branch) ->
    opt assigned_in_stmt else_branch (assigned_in_stmt then_branch (assigned_in_expr cond acc))
  | `While (cond, body) -> assigned_in_stmt body (assigned_in_expr cond acc)
  | `Return e -> opt assigned_in_expr e acc
  | `Effect_decl _ | `Type_decl _ | `Trait_decl _ -> acc
  | `Impl_decl (_, _, _, impl) ->
    List.fold_left
      (fun acc (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
        List.fold_left (fun acc st -> assigned_in_stmt st acc) acc m.Ast.md_body)
      acc
      impl.Ast.ib_methods
  | `Match (scrutinee, cases) ->
    List.fold_left
      (fun acc (_, body) ->
        List.fold_left (fun acc st -> assigned_in_stmt st acc) acc body)
      (assigned_in_expr scrutinee acc)
      cases
  | `Resume e -> opt assigned_in_expr e acc
  | `Run (body, handlers) ->
    let acc = List.fold_left (fun acc st -> assigned_in_stmt st acc) acc body in
    List.fold_left
      (fun acc (h : Ast.desugared_stmt Ast.handler) ->
        List.fold_left
          (fun acc (a : Ast.desugared_stmt Ast.arm) ->
            List.fold_left (fun acc st -> assigned_in_stmt st acc) acc a.Ast.arm_body)
          acc
          h.Ast.arms)
      acc
      handlers

(* Anywhere but a nested function, where it would be a different handler's. *)
let rec resumes (s : Ast.desugared_stmt) =
  match s.Ast.it with
  | `Resume _ -> true
  | `Block body -> List.exists resumes body
  | `If (_, t, e) -> resumes t || Option.fold ~none:false ~some:resumes e
  | `While (_, body) | `Defer body -> resumes body
  | `Match (_, cases) -> List.exists (fun (_, body) -> List.exists resumes body) cases
  | _ -> false

let assigned_names body =
  List.fold_left (fun acc s -> assigned_in_stmt s acc) [] body

let field_of (target : checked_expr) label =
  match Types.repr target.Ast.ann with
  | Types.INamed (name, _, fields) ->
    let rec find f =
      match Types.repr_fields f with
      | Types.FCons (l, ty, _) when String.equal l label -> Some ty
      | Types.FCons (_, _, rest) -> find rest
      | _ -> None
    in
    (match find fields with
     | Some ty -> ty
     | None -> fail target.Ast.span "Type '%s' has no field '%s'." name label)
  | _ ->
    let ty = Types.fresh () in
    unify_at
      target.Ast.span
      (Types.IRecord (Types.FCons (label, ty, Types.fresh_fields ())))
      target.Ast.ann;
    ty

let element_of registry (target : checked_expr) =
  match Types.concrete target.Ast.ann with
  | Some Types.Str -> Types.IChr
  | Some other ->
    (match Types.container_element (Types.of_ty other) with
     | Some (name, elem)
       when String.equal name Types.array_name || Registry.is_indexed registry name ->
       elem
     | _ ->
       (* A non-container has no element in its own arguments, so indexing
          answers with what its impl bound. *)
       (match Types.type_name other with
        | Some name when Registry.is_indexed registry name ->
          (match Hashtbl.find_opt ctx_assoc (name, "Output") with
           | Some elem -> elem
           | None -> fail target.Ast.span "Cannot index %s." (Types.string_of_ty other))
        | _ -> fail target.Ast.span "Cannot index %s." (Types.string_of_ty other)))
  | None ->
    let elem = Types.fresh () in
    unify_at target.Ast.span (Types.fresh_with (Types.Collection elem)) target.Ast.ann;
    elem

let declared_index env registry (target : checked_expr) (index : checked_expr) =
  let concrete t = Option.map Types.string_of_ty (Types.concrete t) in
  match Types.concrete index.Ast.ann with
  | Some Types.Int | None -> None
  | Some _ ->
    (* Decided here because the entry to reach cannot be found without it. *)
    (match Types.repr target.Ast.ann with
     | Types.IVar { contents = Types.Unbound (_, Types.Collection elem) } ->
       (try Types.unify target.Ast.ann (Types.iarray elem) with
        | Types.Type_error _ -> ())
     | _ -> ());
    (match Types.type_name (Option.value (Types.concrete target.Ast.ann) ~default:Types.Unit) with
     | None -> None
     | Some owner ->
       (match Registry.indexed registry owner (Option.value (concrete index.Ast.ann) ~default:"") with
        | Some { Registry.get = Some fn; _ } ->
          (match lookup env fn with
           | None -> None
           | Some scheme ->
             let result = Types.fresh () in
             (try
                Types.unify
                  (Types.instantiate scheme)
                  (Types.IFn ([ target.Ast.ann; index.Ast.ann ], result, Types.REmpty));
                Some result
              with
              | Types.Type_error _ -> None))
        | _ -> None))

let binop_result registry (op : Ast.binop) a b =
  match Types.concrete a, Types.concrete b with
  | Some lhs, Some rhs ->
    (match Registry.find registry op lhs rhs with
     | Some entry -> Types.of_ty (Registry.result_of entry lhs)
     | None ->
       let missing =
         match List.find_opt (fun (_, (binary, _)) -> binary = op) operator_traits with
         | Some (trait, _) ->
           Printf.sprintf
             ": %s does not implement %s<%s>"
             (Types.string_of_ty lhs)
             trait
             (Types.string_of_ty rhs)
         | None -> ""
       in
       Types.error
         "No operator %s for %s and %s%s."
         (Ast.string_of_binop op)
         (Types.string_of_ty lhs)
         (Types.string_of_ty rhs)
         missing)
  | _ ->
    (* Unifying would make an asymmetric operator unreachable. *)
    Types.unify a b;
    (match trait_of_operator op with
     | None -> Registry.unresolved_result op a
     | Some (trait, produces_bool) ->
       (* Both operands were just unified, so this is the homogeneous case and
          the bound says so: `Output = T`. Asking for the projection instead
          would leave `d(d(x))` with an intermediate that resolves to `Generic`
          and that monomorphization cannot tell what it was a projection of. *)
       Types.constrain
         a
         (Types.Bound
            [ { Types.bd_trait = trait
              ; bd_args = (if produces_bool then [] else [ a ])
              ; bd_bindings = (if produces_bool then [] else [ "Output", a ])
              } ]);
       if produces_bool then Types.IBool else a)

(* A trailing lambda writes no parameters, so how many it has is whatever the
   type it is passed to says: none, or the single `it` it already carries. Two or
   more have no names to be reached by, and must be written. *)
let name_implicit_params_from (expected : Types.infer_ty list) (args : Ast.desugared_expr list) =
    List.mapi
      (fun index (arg : Ast.desugared_expr) ->
        match arg.Ast.it with
        | `Lambda ([ { Ast.implicit = true; _ } ], signature, body) ->
          (match Option.map Types.repr (List.nth_opt expected index) with
           | Some (Types.IFn ([], _, _)) -> { arg with Ast.it = `Lambda ([], signature, body) }
           | Some (Types.IFn (wanted, _, _)) when List.length wanted > 1 ->
             fail
               arg.Ast.span
               "A lambda taking %d parameters must name them."
               (List.length wanted)
           | _ -> arg)
        | _ -> arg)
      args

let name_implicit_params (callee : Types.infer_ty) (args : Ast.desugared_expr list) =
  match Types.repr callee with
  | Types.IFn (expected, _, _) -> name_implicit_params_from expected args
  | _ -> args

let kind_name = function
  | Ast.Op_fn -> "fn"
  | Ast.Op_ctl -> "ctl"
  | Ast.Op_final -> "final ctl"

let rec infer_expr env ctx (e : Ast.desugared_expr) : checked_expr =
  try infer_expr_impl env ctx e with
  | Types.Type_error message -> raise (Located { span = e.Ast.span; message })

and infer_expr_impl env ctx (e : Ast.desugared_expr) : checked_expr =
  let span = e.Ast.span in
  let node ty it : checked_expr = Ast.annotated span ty it in
  match e.Ast.it with
  | `Int n -> node Types.IInt (`Int n)
  | `Float n -> node Types.IFloat (`Float n)
  | `Str s -> node Types.IStr (`Str s)
  | `Name n -> node Types.iname (`Name n)
  | `Bytes b -> node (Types.iarray Types.IByte) (`Bytes b)
  | `Char c -> node Types.IChr (`Char c)
  | `Bool b -> node Types.IBool (`Bool b)
  | `Unit -> node Types.IUnit `Unit
  | `Var name ->
    (match lookup env name with
     | Some scheme -> node (Types.instantiate scheme) (`Var name)
     | None -> fail span "Undefined variable '%s'." name)
  | `Run_expr (body, handlers, clause) ->
    let answer = Types.fresh () in
    let assigned = assigned_in_expr e [] in
    let valued scope (b : (Ast.desugared_expr, Ast.desugared_stmt) Ast.valued_block) =
      let stmts = infer_block scope ctx b.Ast.vb_stmts in
      let value = Option.map (infer_expr scope ctx) b.Ast.vb_value in
      ( { Ast.vb_stmts = stmts; vb_value = value }
      , match value with
        | None -> Types.IUnit
        | Some v -> v.Ast.ann )
    in
    let (body, produced), handlers =
      check_run env ctx assigned span ~answer handlers (fun () ->
        valued (new_env (Some env)) body)
    in
    let clause =
      match clause with
      | None ->
        (* Without one, finishing normally is what the block evaluates to. *)
        unify_at span answer produced;
        None
      | Some c ->
        let scope = new_env (Some env) in
        bind scope c.Ast.rc_param (Types.mono produced);
        let rc_body, result = valued scope c.Ast.rc_body in
        unify_at span answer result;
        Some { Ast.rc_param = c.Ast.rc_param; rc_body }
    in
    node answer (`Run_expr (body, handlers, clause))
  | `Assign (name, v) ->
    (match lookup env name with
     | None -> fail span "Undefined variable '%s'." name
     | Some scheme ->
       let target = Types.instantiate scheme in
       let value = infer_expr env ctx v in
       Types.unify target value.Ast.ann;
       node target (`Assign (name, value)))
  | `Unop (Ast.Neg, a) ->
    let a = infer_expr env ctx a in
    (match Types.concrete a.Ast.ann with
     | Some operand ->
       (match Registry.find_unary ctx.registry Ast.Neg operand with
        | Some entry -> node (Types.of_ty (Registry.result_of entry operand)) (`Unop (Ast.Neg, a))
        | None ->
          fail
            span
            "Cannot negate %s: it does not implement Neg."
            (Types.string_of_ty operand))
     | None ->
       Types.constrain
         a.Ast.ann
         (Types.Bound
            [ { Types.bd_trait = "Neg"
              ; bd_args = []
              ; bd_bindings = [ "Output", a.Ast.ann ]
              } ]);
       node a.Ast.ann (`Unop (Ast.Neg, a)))
  | `Unop (Ast.Not, a) ->
    let a = infer_expr env ctx a in
    Types.unify Types.IBool a.Ast.ann;
    node Types.IBool (`Unop (Ast.Not, a))
  | `Binop (op, a, b) ->
    let a = infer_expr env ctx a in
    let b = infer_expr env ctx b in
    node (binop_result ctx.registry op a.Ast.ann b.Ast.ann) (`Binop (op, a, b))
  | `Compound (op, name, v) ->
    (match lookup env name with
     | None -> fail span "Undefined variable '%s'." name
     | Some scheme ->
       let target = Types.instantiate scheme in
       let v = infer_expr env ctx v in
       let result = binop_result ctx.registry op target v.Ast.ann in
       Types.unify target result;
       let it : checked_expr_kind = `Compound (op, name, v) in
       node target it)
  | `And (a, b) | `Or (a, b) ->
    let a = infer_expr env ctx a in
    let b = infer_expr env ctx b in
    Types.unify Types.IBool a.Ast.ann;
    Types.unify Types.IBool b.Ast.ann;
    let it : checked_expr_kind =
      match e.Ast.it with
      | `And _ -> `And (a, b)
      | _ -> `Or (a, b)
    in
    node Types.IBool it
  | `Call (callee, args) ->
    let callee_node = infer_expr env ctx callee in
    let args = name_implicit_params callee_node.Ast.ann args in
    let args = List.map (infer_expr env ctx) args in
    (* The name has to still mean the entry, not merely be spelled like it. *)
    let variadic =
      match callee.Ast.it with
      | `Var name ->
        (match Hashtbl.find_opt ctx_variadic name, lookup env name with
         | Some (declared, result), Some found when declared == found -> Some result
         | _ -> None)
      | _ -> None
    in
    (match variadic with
     | Some result ->
       (* Otherwise every such call reaches [Verify] as a generic callee. *)
       let callee_node =
         { callee_node with
           Ast.ann =
             Types.IFn
               ( List.map (fun (a : checked_expr) -> a.Ast.ann) args
               , result
               , Types.REmpty )
         }
       in
       node result (`Call (callee_node, args))
     | None ->
       let ret = Types.fresh () in
       let row = Types.fresh_row () in
       Types.unify
         callee_node.Ast.ann
         (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) args, ret, row));
       let scheme =
         match callee.Ast.it with
         | `Var name -> lookup env name
         | _ -> None
       in
       admits_row scheme row ctx.row;
       node ret (`Call (callee_node, args)))
  | `Comptime_call (callee, comptime_args, args) ->
    let name =
      match callee.Ast.it with
      | `Var name -> name
      | _ -> fail span "Only a named function takes comptime arguments."
    in
    let scheme =
      match lookup env name with
      | Some scheme -> scheme
      | None -> fail span "Undefined variable '%s'." name
    in
    let declared = Option.value ~default:[] (Hashtbl.find_opt ctx_fn_params name) in
    if List.length declared <> List.length comptime_args
    then
      fail
        span
        "'%s' takes %d comptime argument(s) but %d were given."
        name
        (List.length declared)
        (List.length comptime_args);
    let type_args =
      List.map
        (function
          | Ast.Ct_type t -> t
          | Ast.Ct_value _ ->
            fail span "A comptime argument to '%s' is not known at compile time." name)
        comptime_args
    in
    let bound, pinned =
      List.fold_left2
        (fun (bound, pinned) (_, var) written ->
          let written = infer_ty_of_annotation written in
          match Types.repr var with
          | Types.IVar { contents = Types.Unbound (id, _) } ->
            (id, written) :: bound, pinned
          | other -> bound, (other, written) :: pinned)
        ([], [])
        declared
        type_args
    in
    let fn = Types.instantiate ~bound scheme in
    List.iter (fun (a, b) -> unify_at span a b) pinned;
    let args = List.map (infer_expr env ctx) args in
    let callee_node : checked_expr = Ast.annotated callee.Ast.span fn (`Var name) in
    let ret = Types.fresh () in
    let row = Types.fresh_row () in
    Types.unify
      fn
      (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) args, ret, row));
    admits_row (lookup env name) row ctx.row;
    node ret (`Call (callee_node, args))
  | `Method_call (receiver, name, as_function, args) ->
    (* `T.from(x)` names a type rather than a value. *)
    let named_receiver =
      match receiver.Ast.it with
      | `Var owner when lookup env owner = None ->
        (match Hashtbl.find_opt ctx_type_params owner with
         | Some var -> Some var
         (* A primitive is not in [ctx_types], so `int.from(…)` would reach
            nothing while `21.double()` works. *)
         | None when primitive owner <> None -> primitive owner
         | None ->
           if Hashtbl.mem ctx_types owner
           then Some (named_type receiver.Ast.span owner [])
           else None)
      | _ -> None
    in
    let receiver =
      match named_receiver with
      | Some ann -> { Ast.it = `Int 0; span = receiver.Ast.span; ann }
      | None -> infer_expr env ctx receiver
    in
    let owners =
      List.sort_uniq
        compare
        (Hashtbl.fold
           (fun (owner, declared) _ acc ->
             if String.equal declared name then owner :: acc else acc)
           ctx_methods
           [])
    in
    (* An unpinned receiver has no owner to look in. *)
    let found =
      try Ok (receiver_of span ctx.registry receiver name owners) with
      | Located _ as e -> Error e
    in
    (* The method's own parameters, so a trailing lambda is sized before its body
       is read rather than after. *)
    let expected =
      match found with
      | Ok (Owner owner) when not (Hashtbl.mem ctx_associated (owner, name)) ->
        (match lookup env (Registry.entry_for_method ctx.registry owner name) with
         | Some scheme ->
           (match Types.repr (Types.instantiate scheme) with
            | Types.IFn (self :: rest, _, _) ->
              (* A generic parameter only says how many a lambda takes once the
                 receiver has bound it. This instantiation is read and dropped;
                 the call makes its own. *)
              (try Types.unify self receiver.Ast.ann with
               | _ -> ());
              rest
            | _ -> [])
         | None -> [])
      | _ -> []
    in
    let args = List.map (infer_expr env ctx) (name_implicit_params_from expected args) in
    (* An `impl` wins, or a free function could shadow a method. *)
    let via_function () =
      match lookup env as_function with
      | None -> None
      | Some scheme ->
        let fn = Types.instantiate scheme in
        let passed =
          receiver.Ast.ann :: List.map (fun (a : checked_expr) -> a.Ast.ann) args
        in
        (match Types.repr fn with
         | Types.IFn (params, _, _) when List.length params <> List.length passed ->
           fail
             span
             "'%s' takes %d argument(s) but %d were passed, counting the receiver."
             name
             (List.length params)
             (List.length passed)
         | Types.IFn _ -> ()
         | _ -> fail span "'%s' is not a function." name);
        let ret = Types.fresh () in
        let row = Types.fresh_row () in
        Types.unify fn (Types.IFn (passed, ret, row));
        admits_row (Some scheme) row ctx.row;
        Some
          (node ret (`Call ({ Ast.it = `Var as_function; span; ann = fn }, receiver :: args)))
    in
    (match found with
     | Error e ->
       (match via_function () with
        | Some call -> call
        | None -> raise e)
     | Ok found ->
       (match found with
     (* The trait declares the signature; which type supplies the body is
        settled later. *)
     | Via_trait trait ->
       let trait_params, trait_body =
         Option.value
           (Hashtbl.find_opt ctx_traits trait)
           ~default:([], { Ast.tb_super = []; tb_assoc = []; tb_methods = [] })
       in
       let trait_methods = trait_body.Ast.tb_methods in
       let bound_args =
         match Types.repr receiver.Ast.ann with
         | Types.IVar { contents = Types.Unbound (_, Types.Bound traits) } ->
           (match
              List.find_opt (fun (b : Types.bound) -> String.equal b.Types.bd_trait trait) traits
            with
            | Some found -> found.Types.bd_args
            | None -> [])
         | _ -> []
       in
       (* Read as a variable until the receiver's own impl is reached. *)
       let projected name = Types.project receiver.Ast.ann name in
       let in_scope =
         ("Self", receiver.Ast.ann)
         :: List.map (fun name -> name, projected name) trait_body.Ast.tb_assoc
         @ (if List.length trait_params = List.length bound_args
            then List.combine trait_params bound_args
            else [])
       in
       with_type_params in_scope (fun () ->
       let declared =
         List.find_opt (fun (m : Ast.method_sig) -> String.equal m.Ast.ms_name name) trait_methods
       in
       (match declared with
        | None -> fail span "Trait '%s' has no method '%s'." trait name
        | Some m ->
          let rest =
            match m.Ast.ms_params with
            | { Ast.name = "self"; _ } :: rest -> rest
            | all -> all
          in
          if List.length rest <> List.length args
          then
            fail
              span
              "Method '%s' takes %d argument(s) but %d were passed."
              name
              (List.length rest)
              (List.length args);
          let fn =
            Types.IFn
              ( receiver.Ast.ann
                :: List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) rest
              , annotated_or_fresh m.Ast.ms_signature.Ast.ret
              , Types.fresh_row () )
          in
          let ret = Types.fresh () in
          let row = Types.fresh_row () in
          Types.unify
            fn
            (Types.IFn
               ( receiver.Ast.ann :: List.map (fun (a : checked_expr) -> a.Ast.ann) args
               , ret
               , row ));
          Types.unify_row row ctx.row;
          node ret (`Method_call (receiver, name, as_function, args))))
     | Owner owner ->
       if Hashtbl.mem ctx_associated (owner, name) && named_receiver = None
       then
         fail
           span
           "'%s' is an associated function of '%s', so it is reached as '%s.%s'."
           name
           owner
           owner
           name;
       let missing () = fail span "Type '%s' has no method '%s'." owner name in
       if (String.equal owner Types.array_name || String.equal owner Types.string_name)
          && String.equal name Types.array_len
       then (
         if args <> []
         then
           fail
             span
             "Method '%s' takes 0 argument(s) but %d were passed."
             Types.array_len
             (List.length args);
         node
           Types.IInt
           (if String.equal owner Types.string_name
            then `Str_len receiver
            else `Array_len receiver))
       else if not (Hashtbl.mem ctx_methods (owner, name))
       then (
         match via_function () with
         | Some call -> call
         | None -> missing ())
       else (
         let fn =
           match lookup env (Registry.entry_for_method ctx.registry owner name) with
           | Some scheme -> Types.instantiate scheme
           | None -> missing ()
         in
         let associated = Hashtbl.mem ctx_associated (owner, name) in
         let passed =
           let given = List.map (fun (a : checked_expr) -> a.Ast.ann) args in
           if associated then given else receiver.Ast.ann :: given
         in
         (match Types.repr fn with
          | Types.IFn (params, _, _) when List.length params <> List.length passed ->
            fail
              span
              "%s '%s' takes %d argument(s) but %d were passed."
              (if associated then "Associated function" else "Method")
              name
              (if associated then List.length params else List.length params - 1)
              (List.length args)
          | _ -> ());
         let ret = Types.fresh () in
         let row = Types.fresh_row () in
         Types.unify fn (Types.IFn (passed, ret, row));
         admits_row
           (lookup env (Registry.entry_for_method ctx.registry owner name))
           row
           ctx.row;
         node ret (`Method_call (receiver, name, as_function, args)))))
  | `Lambda (params, signature, body) ->
    let param_types = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params in
    let declared_ret = annotated_or_fresh signature.Ast.ret in
    let row = Types.fresh_row () in
    let scope = new_env (Some env) in
    List.iter2
      (fun (p : Ast.param) ty -> bind scope p.Ast.name (Types.mono ty))
      params
      param_types;
    let body =
      in_function_body ctx ~ret:declared_ret ~row (fun () -> infer_block scope ctx body)
    in
    node (Types.IFn (param_types, declared_ret, row)) (`Lambda (params, signature, body))
  (* The declared type when no value answers, so `typeof(Dog)` works. *)
  | `Typeof { Ast.it = `Var name; span = inner; _ } when lookup env name = None ->
    let ty =
      try infer_ty_of_annotation { Ast.it = Ast.Ty_name name; span = inner; ann = () } with
      | Located _ -> fail inner "Nothing named '%s' is a value or a type." name
    in
    node Types.ireflected (`Typeof { Ast.it = `Int 0; span = inner; ann = ty })
  | `Typeof e -> node Types.ireflected (`Typeof (infer_expr env ctx e))
  | `Collection_lit items ->
    let elem = Types.fresh () in
    let container = Types.fresh_with (Types.Collection elem) in
    let items = List.map (infer_expr env ctx) items in
    List.iter
      (fun (i : checked_expr) -> unify_at i.Ast.span elem i.Ast.ann)
      items;
    node container (`Collection_lit items)
  | `New_call (name, type_args, args) when String.equal name Types.array_name ->
    let elem =
      match List.map infer_ty_of_annotation type_args with
      | [ elem ] -> elem
      | [] -> Types.fresh ()
      | given ->
        fail span "Type 'Array' takes 1 argument(s) but %d were given." (List.length given)
    in
    (match List.map (infer_expr env ctx) args with
     | [ length; fill ] ->
       unify_at length.Ast.span Types.IInt length.Ast.ann;
       unify_at fill.Ast.span elem fill.Ast.ann;
       node (Types.iarray elem) (`Array_new (length, fill))
     | given ->
       fail
         span
         "An array takes a length and a fill value, but %d argument(s) were given."
         (List.length given))
  | `New_call (name, type_args, args) ->
    (match Registry.constructor ctx.registry name with
     | None -> fail span "'%s' cannot be constructed with arguments." name
     | Some fn ->
       let scheme =
         match lookup env fn with
         | Some scheme -> scheme
         | None -> fail span "Undefined variable '%s'." fn
       in
       let fn_ty = Types.instantiate scheme in
       let args = List.map (infer_expr env ctx) args in
       let ret = Types.fresh () in
       let row = Types.fresh_row () in
       Types.unify
         fn_ty
         (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) args, ret, row));
       admits_row (lookup env fn) row ctx.row;
       if type_args <> []
       then
         unify_at
           span
           (named_type span name (List.map infer_ty_of_annotation type_args))
           ret;
       node ret (`Call (Ast.annotated span fn_ty (`Var fn), args)))
  | `New (name, fields) ->
    (match Hashtbl.find_opt ctx_types name with
     | Some (Opaque _) -> fail span "'%s' cannot be constructed with 'new'." name
     | None | Some (Sum _) -> fail span "Unknown record type '%s'." name
     | Some (Product (vars, declared)) ->
       let args = List.map (fun _ -> Types.fresh ()) vars in
       let declared = Types.substitute_fields (instance vars args) declared in
       let rec labels f =
         match Types.repr_fields f with
         | Types.FEmpty | Types.FVar _ -> []
         | Types.FCons (l, ty, rest) -> (l, ty) :: labels rest
       in
       let expected = labels declared in
       let fields = List.map (fun (l, v) -> l, infer_expr env ctx v) fields in
       List.iter
         (fun (l, _) ->
           if not (List.mem_assoc l expected)
           then fail span "Type '%s' has no field '%s'." name l)
         fields;
       List.iter
         (fun (l, _) ->
           if not (List.mem_assoc l fields)
           then fail span "Field '%s' is missing." l)
         expected;
       List.iter
         (fun (l, (v : checked_expr)) ->
           unify_at v.Ast.span (List.assoc l expected) v.Ast.ann)
         fields;
       node (Types.INamed (name, args, declared)) (`New (name, fields)))
  | `New_variant (ty, variant, payload) ->
    (match Hashtbl.find_opt ctx_types ty with
     | None | Some (Product _) | Some (Opaque _) ->
       fail span "Unknown sum type '%s'." ty
     | Some (Sum (vars, variants)) ->
       (match List.assoc_opt variant variants with
        | None -> fail span "Type '%s' has no variant '%s'." ty variant
        | Some declared ->
          let mapping = instantiation vars declared in
          let args = List.map (Types.substitute mapping) declared.vd_result in
          let expected =
            List.map
              (fun (l, t) -> l, Types.substitute mapping t)
              (Ast.payload_fields declared.vd_payload)
          in
          let given =
            List.map (fun (l, v) -> l, infer_expr env ctx v) (Ast.payload_fields payload)
          in
          if List.length expected <> List.length given
          then
            fail
              span
              "Variant '%s' carries %d value(s) but %d were given."
              variant
              (List.length expected)
              (List.length given);
          List.iter
            (fun (l, (v : checked_expr)) ->
              match List.assoc_opt l expected with
              | Some ty -> unify_at v.Ast.span ty v.Ast.ann
              | None -> fail span "Variant '%s' has no field '%s'." variant l)
            given;
          let payload =
            match payload with
            | Ast.P_none -> Ast.P_none
            | Ast.P_tuple _ -> Ast.P_tuple (List.map snd given)
            | Ast.P_fields _ -> Ast.P_fields given
          in
          node (Types.ISum (ty, args)) (`New_variant (ty, variant, payload))))
  | `Record_lit fields ->
    let fields = List.map (fun (l, v) -> l, infer_expr env ctx v) fields in
    node
      (Types.IRecord
         (List.fold_right
            (fun (l, (v : checked_expr)) rest -> Types.FCons (l, v.Ast.ann, rest))
            fields
            Types.FEmpty))
      (`Record_lit fields)
  | `Field (target, label) ->
    let target = infer_expr env ctx target in
    node (field_of target label) (`Field (target, label))
  | `Field_assign (target, label, v) ->
    let target = infer_expr env ctx target in
    let v = infer_expr env ctx v in
    unify_at v.Ast.span (field_of target label) v.Ast.ann;
    node v.Ast.ann (`Field_assign (target, label, v))
  | `Tuple items ->
    let items = List.map (infer_expr env ctx) items in
    node
      (Types.ITuple (List.map (fun (i : checked_expr) -> i.Ast.ann) items))
      (`Tuple items)
  | `Tuple_get (target, index) ->
    let target = infer_expr env ctx target in
    (match Types.repr target.Ast.ann with
     | Types.ITuple items ->
       (match List.nth_opt items index with
        | Some ty -> node ty (`Tuple_get (target, index))
        | None ->
          fail
            span
            "A tuple of %d element(s) has no field %d."
            (List.length items)
            index)
     | Types.IVar _ ->
       fail
         target.Ast.span
         "The type of this tuple is not known here, so field %d cannot be resolved."
         index
     | other ->
       fail
         target.Ast.span
         "Cannot take a field of %s."
         (Types.string_of_infer_ty other))
  | `Index (target, index) ->
    let target = infer_expr env ctx target in
    let index = infer_expr env ctx index in
    (match declared_index env ctx.registry target index with
     | Some result -> node result (`Index (target, index))
     | None ->
       unify_at index.Ast.span Types.IInt index.Ast.ann;
       node (element_of ctx.registry target) (`Index (target, index)))
  | `Index_assign (target, index, v) ->
    let target = infer_expr env ctx target in
    if Types.concrete target.Ast.ann = Some Types.Str
    then fail target.Ast.span "A string cannot be assigned into.";
    let index = infer_expr env ctx index in
    let v = infer_expr env ctx v in
    unify_at index.Ast.span Types.IInt index.Ast.ann;
    unify_at v.Ast.span (element_of ctx.registry target) v.Ast.ann;
    node v.Ast.ann (`Index_assign (target, index, v))

and declare_traits (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Trait_decl (name, params, trait_body) ->
        (* A program's own declaration replaces the prelude's; two of its own
           are still a mistake. *)
        let from_prelude (span : Ast.span) =
          String.equal (Source_map.Span.path span) Prelude.file
        in
        (match Hashtbl.find_opt ctx_trait_spans name with
         | Some declared when from_prelude declared && not (from_prelude s.Ast.span) -> ()
         | Some _ -> fail s.Ast.span "Trait '%s' is already declared." name
         | None -> ());
        Hashtbl.replace ctx_trait_spans name s.Ast.span;
        Hashtbl.replace ctx_traits name (params, trait_body)
      | _ -> ())
    body

and declare_impls registry (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Impl_decl (trait, type_name, params, impl) ->
        let span = s.Ast.span in
        let methods = impl.Ast.ib_methods in
        let type_params = List.map (fun name -> name, Types.fresh ()) params in
        let supplies name =
          List.exists
            (fun (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
              String.equal m.Ast.md_name name)
            methods
        in
        with_type_params type_params (fun () -> ignore (self_ty span type_name params));
        with_type_params type_params (fun () ->
          List.iter
            (fun (name, bound) ->
              (* The key does not say which index, so the first stands and a
                 container reads as holding elements rather than slices. *)
              if not (Hashtbl.mem ctx_assoc (type_name, name))
              then Hashtbl.replace ctx_assoc (type_name, name) (infer_ty_of_annotation bound))
            impl.Ast.ib_assoc);
        (match trait with
         | None -> ()
         | Some (trait_name, trait_args) ->
           (match Hashtbl.find_opt ctx_traits trait_name with
            | None -> fail span "Unknown trait '%s'." trait_name
            | Some (trait_params, required) ->
              if List.length trait_args <> List.length trait_params
              then
                fail
                  span
                  "Trait '%s' takes %d type argument(s) but %d were given."
                  trait_name
                  (List.length trait_params)
                  (List.length trait_args);
              List.iter
                (fun name ->
                  if not (List.mem_assoc name impl.Ast.ib_assoc)
                  then
                    fail
                      span
                      "'%s' for '%s' is missing associated type '%s'."
                      trait_name
                      type_name
                      name)
                required.Ast.tb_assoc;
              List.iter
                (fun (r : Ast.method_sig) ->
                  if not (supplies r.Ast.ms_name)
                  then
                    fail
                      span
                      "'%s' for '%s' is missing method '%s'."
                      trait_name
                      type_name
                      r.Ast.ms_name)
                required.Ast.tb_methods;
              conforms
                span
                ~trait:trait_name
                ~args:trait_args
                ~params:trait_params
                ~required
                ~type_name
                ~type_params
                ~decl_params:params
                impl));
        List.iter
          (fun (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
            (match m.Ast.md_params with
             | { Ast.name = "self"; _ } :: _ -> ()
             | _ ->
               Hashtbl.replace ctx_associated (type_name, m.Ast.md_name) ();
               Registry.mark_associated registry type_name m.Ast.md_name);
            (* Keyed by the mangled name, so `Index<int>` and `Index<Range>`
               each bring a `get` without colliding. *)
            let mangled = Ast.impl_method_name trait type_name m.Ast.md_name in
            (match Hashtbl.find_opt ctx_entries mangled with
             | Some first ->
               fail
                 span
                 "Type '%s' already has a method '%s', from %s."
                 type_name
                 m.Ast.md_name
                 (where first)
             | None -> ());
            Hashtbl.replace ctx_entries mangled span;
            Registry.register_entry registry type_name m.Ast.md_name mangled;
            Hashtbl.replace ctx_methods (type_name, m.Ast.md_name) ())
          methods;
        Option.iter
          (fun (t, args) ->
            (* The impl's own parameter may be among the trait's arguments. *)
            with_type_params type_params (fun () ->
              Hashtbl.add ctx_impls (type_name, t) (List.map infer_ty_of_annotation args)))
          trait;
        Option.iter
          (fun (t, args) ->
            let entry_name method_ = Ast.impl_method_name (Some (t, args)) type_name method_ in
            let self_concrete () =
              match Types.concrete (self_ty span type_name params) with
              | Some ty -> ty
              | None -> fail span "An operator impl's type must be concrete."
            in
            let one_argument () =
              match args with
              | [ only ] -> infer_ty_of_annotation only
              | _ -> fail span "'%s' takes one type argument." t
            in
            let written_name () =
              match args with
              | [ { Ast.it = Ast.Ty_name n; _ } ] | [ { Ast.it = Ast.Ty_app (n, _); _ } ] -> n
              | _ -> fail span "'%s' takes one named type argument." t
            in
            (match t with
             | "Eq" ->
               with_type_params type_params (fun () ->
                 let self = self_concrete () in
                 List.iter
                   (fun op ->
                     Registry.register
                       registry
                       op
                       self
                       self
                       { Registry.result = Some Types.Bool
                       ; emit = Registry.Call (entry_name "eq")
                       })
                   [ Ast.Equal; Ast.Not_equal ])
             (* One entry answers all four: [Resolve] turns the `Ordering` the
                method returns into the bool the operator wanted. *)
             | "Neg" ->
               with_type_params type_params (fun () ->
                 Registry.register_unary
                   registry
                   Ast.Neg
                   (self_concrete ())
                   { Registry.result =
                       (match List.assoc_opt "Output" impl.Ast.ib_assoc with
                        | Some bound -> Types.concrete (infer_ty_of_annotation bound)
                        | None ->
                          fail span "'Neg' for '%s' is missing associated type 'Output'." type_name)
                   ; emit = Registry.Call (entry_name "neg")
                   })
             | "PartialOrd" ->
               with_type_params type_params (fun () ->
                 let self = self_concrete () in
                 List.iter
                   (fun op ->
                     Registry.register
                       registry
                       op
                       self
                       self
                       { Registry.result = Some Types.Bool
                       ; emit = Registry.Call (entry_name "partial_cmp")
                       })
                   [ Ast.Less; Ast.Less_equal; Ast.Greater; Ast.Greater_equal ])
             (* By the names written: `Index<int> for List<T>` is every List. *)
             | "Index" ->
               Registry.register_index_get registry type_name (written_name ()) (entry_name "get")
             | "IndexSet" ->
               Registry.register_index_set registry type_name (written_name ()) (entry_name "set")
             | "FromArray" ->
               with_type_params type_params (fun () ->
                 let element = one_argument () in
                 let self = self_ty span type_name params in
                 let body = Types.IFn ([ element ], self, Types.REmpty) in
                 Registry.register_container
                   registry
                   type_name
                   { Registry.entry = entry_name "from_array"
                   ; scheme =
                       { Types.quantified = List.map fst (Types.free_vars body)
                       ; quantified_rows = []
                       ; quantified_fields = []
                       ; body
                       }
                   })
             | _ -> ());
            match List.assoc_opt t operator_traits with
            | None -> ()
            | Some (binary, method_) ->
              let concrete what ty =
                match Types.concrete ty with
                | Some ty -> ty
                | None -> fail span "An operator impl's %s must be a concrete type." what
              in
              with_type_params type_params (fun () ->
                let lhs = concrete "type" (self_ty span type_name params) in
                let rhs =
                  match args with
                  | [ rhs ] -> concrete "right operand" (infer_ty_of_annotation rhs)
                  | _ -> fail span "'%s' takes one type argument." t
                in
                let result =
                  match List.assoc_opt "Output" impl.Ast.ib_assoc with
                  | Some bound -> concrete "Output" (infer_ty_of_annotation bound)
                  | None -> fail span "'%s' for '%s' is missing associated type 'Output'." t type_name
                in
                if Registry.find_exact registry binary lhs rhs <> None
                then
                  fail
                    span
                    "Operator %s is already defined for %s and %s."
                    (Ast.string_of_binop binary)
                    (Types.string_of_ty lhs)
                    (Types.string_of_ty rhs);
                Registry.register
                  registry
                  binary
                  lhs
                  rhs
                  { Registry.result = Some result
                  ; emit = Registry.Call (Ast.impl_method_name (Some (t, args)) type_name method_)
                  }))
          trait
      | _ -> ())
    body;
  (* An impl may satisfy a supertrait further down the file. *)
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Impl_decl (Some (trait, _), type_name, _, _) ->
        (match Hashtbl.find_opt ctx_traits trait with
         | None -> ()
         | Some (_, body) ->
           List.iter
             (fun (super, _) ->
               if not (Hashtbl.mem ctx_impls (type_name, super))
               then
                 fail
                   s.Ast.span
                   "'%s' for '%s' is missing the supertrait '%s'."
                   trait
                   type_name
                   super)
             body.Ast.tb_super)
      | _ -> ())
    body

and associated_names trait =
  List.sort_uniq
    String.compare
    (List.concat_map
       (fun t ->
         match Hashtbl.find_opt ctx_traits t with
         | Some (_, body) -> body.Ast.tb_assoc
         | None -> [])
       (trait_closure trait))

and conforms span ~trait ~args ~params ~required ~type_name ~type_params ~decl_params impl =
  let in_scope =
    with_type_params type_params (fun () ->
      ("Self", self_ty span type_name decl_params)
      :: List.map
           (fun name ->
             ( name
             , match List.assoc_opt name impl.Ast.ib_assoc with
               | Some bound -> infer_ty_of_annotation bound
               (* A supertrait's, bound by the impl that supplied it. *)
               | None ->
                 (match Hashtbl.find_opt ctx_assoc (type_name, name) with
                  | Some ty -> ty
                  | None -> Types.fresh ()) ))
           (associated_names trait)
      @ List.combine params (List.map infer_ty_of_annotation args))
  in
  with_type_params (type_params @ in_scope) (fun () ->
    List.iter
      (fun (r : Ast.method_sig) ->
        match
          List.find_opt
            (fun (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
              String.equal m.Ast.md_name r.Ast.ms_name)
            impl.Ast.ib_methods
        with
        | None -> ()
        | Some m -> conforming_method span ~trait ~type_name r m)
      required.Ast.tb_methods)

and conforming_method
  span
  ~trait
  ~type_name
  (r : Ast.method_sig)
  (m : (Ast.desugared_stmt, unit) Ast.method_def)
  =
  let without_self = function
    | { Ast.name = "self"; _ } :: rest -> rest
    | all -> all
  in
  let declared_params = without_self r.Ast.ms_params
  and defined_params = without_self m.Ast.md_params in
  if List.length declared_params <> List.length defined_params
  then
    fail
      span
      "'%s' for '%s' declares '%s' with %d parameter(s) but it is defined with %d."
      trait
      type_name
      r.Ast.ms_name
      (List.length declared_params)
      (List.length defined_params);
  (* The two sides share a name for the same parameter, so binding both lists
     leaves one variable standing for it and the signatures can meet. *)
  let own =
    type_params_of span r.Ast.ms_signature.Ast.comptime
    @ type_params_of span m.Ast.md_signature.Ast.comptime
  in
  with_type_params own (fun () ->
    let types params = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params in
    let declared = types declared_params
    and declared_ret = annotated_or_fresh r.Ast.ms_signature.Ast.ret in
    let defined = types defined_params
    and defined_ret = annotated_or_fresh m.Ast.md_signature.Ast.ret in
    let shown params ret =
      Printf.sprintf
        "(self%s): %s"
        (String.concat "" (List.map (fun t -> ", " ^ Types.string_of_infer_ty t) params))
        (Types.string_of_infer_ty ret)
    in
    (* Read before unifying: a link the first mismatch leaves behind would
       otherwise be printed as what was written. *)
    let declared_text = shown declared declared_ret
    and defined_text = shown defined defined_ret in
    try
      List.iter2 Types.unify declared defined;
      Types.unify declared_ret defined_ret
    with
    | Types.Type_error _ ->
      fail
        span
        "'%s' for '%s' declares '%s' as %s but defines %s."
        trait
        type_name
        r.Ast.ms_name
        declared_text
        defined_text)

and self_ty span type_name params =
  if params = []
  then infer_ty_of_annotation (Ast.at span (Ast.Ty_name type_name))
  else
    named_type
      span
      type_name
      (List.map
         (fun name ->
           match Hashtbl.find_opt ctx_type_params name with
           | Some var -> var
           | None -> Types.fresh ())
         params)

and declare_types (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Type_decl (name, params, body) ->
        (* A program declaring a type the prelude also declares gets its own,
           the way it does for a trait. Two of its own are still a mistake. *)
        let from_prelude (at : Ast.span) =
          String.equal (Source_map.Span.path at) Prelude.file
        in
        (match Hashtbl.find_opt ctx_type_spans name with
         | Some declared when from_prelude declared && not (from_prelude s.Ast.span) -> ()
         | Some _ -> fail s.Ast.span "Type '%s' is already declared." name
         | None -> if Hashtbl.mem ctx_types name then fail s.Ast.span "Type '%s' is already declared." name);
        Hashtbl.replace ctx_type_spans name s.Ast.span;
        let type_params = List.map (fun name -> name, Types.fresh ()) params in
        let vars = List.map snd type_params in
        (* Already the right shape, or `Add(Expr<int>, …)` reads `Expr` as a
           product. *)
        Hashtbl.replace
          ctx_types
          name
          (match body with
           | Ast.T_variants _ -> Sum (vars, [])
           | Ast.T_fields _ -> Product (vars, Types.FEmpty));
        let declared =
          with_type_params type_params (fun () ->
            match body with
            | Ast.T_fields fields ->
              Product
                ( vars
                , List.fold_right
                    (fun (f : Ast.field) rest ->
                      Types.FCons (f.Ast.f_name, infer_ty_of_annotation f.Ast.f_ty, rest))
                    fields
                    Types.FEmpty )
            | Ast.T_variants variants ->
              Sum (vars, List.map (variant_of s.Ast.span name vars) variants))
        in
        Hashtbl.replace ctx_types name declared;
        Hashtbl.replace
          ctx_attrs
          name
          (match body with
           | Ast.T_fields fields ->
             List.map (fun (f : Ast.field) -> f.Ast.f_name, f.Ast.f_attrs) fields
           | Ast.T_variants variants ->
             List.map (fun (v : Ast.variant) -> v.Ast.v_name, v.Ast.v_attrs) variants)
      | _ -> ())
    body

(* A written head is the type at whatever the constructor pins; one that is not
   is what every non-GADT builds. *)
and variant_of span owner vars (v : Ast.variant) =
  let own = List.map (fun name -> name, Types.fresh ()) v.Ast.v_params in
  with_type_params own (fun () ->
    let payload = Ast.map_payload infer_ty_of_annotation v.Ast.v_payload in
    let result =
      match v.Ast.v_result with
      | None -> vars
      | Some head ->
        (match Types.repr (infer_ty_of_annotation head) with
         | Types.ISum (built, args) when String.equal built owner -> args
         | other ->
           fail
             span
             "Variant '%s' builds %s, but it is declared in '%s'."
             v.Ast.v_name
             (Types.string_of_infer_ty other)
             owner)
    in
    ( v.Ast.v_name
    , { vd_params = List.map snd own
      ; vd_payload = payload
      ; vd_result = result
      ; vd_refines = v.Ast.v_params <> [] || v.Ast.v_result <> None
      } ))

(* Quantifying the written parameters is what lets a function call itself at
   another instantiation — `depth<T>` reaching `depth` at `Nested<(T, T)>`. Only
   those: the rest is still being inferred and stays shared with the body. The
   row stays monomorphic, so recursion contributes to the inferred effects. *)
and declared_scheme type_params body =
  match
    List.filter_map
      (fun (_, var) ->
        match Types.repr var with
        | Types.IVar { contents = Types.Unbound (id, _) } -> Some id
        | _ -> None)
      type_params
  with
  | [] -> Types.mono body
  | quantified ->
    { Types.quantified; quantified_rows = []; quantified_fields = []; body }

and hoist env (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Impl_decl (trait, type_name, params, impl) ->
        (* Declared, like a written `<T>`, so a kind constraint from the body
           must not default it. *)
        let impl_params =
          List.map
            (fun name ->
              let var = Types.fresh () in
              Types.declare_param var;
              name, var)
            params
        in
        List.iter
          (fun (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
            match m.Ast.md_params with
            (* [declare_impls] reported it; binding it anyway would blame a
               parameter the author did write. *)
            | [] -> ()
            | { Ast.name = "self"; _ } :: rest ->
              let mangled = Ast.impl_method_name trait type_name m.Ast.md_name in
              let type_params =
                impl_params
                @ type_params_of s.Ast.span m.Ast.md_signature.Ast.comptime
              in
              Hashtbl.replace ctx_fn_params mangled type_params;
              with_type_params type_params (fun () ->
                let param_types =
                  self_ty s.Ast.span type_name params
                  :: List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) rest
                in
                let row =
                  match m.Ast.md_signature.Ast.row with
                  | Some labels -> row_of_labels labels
                  | None -> Types.fresh_row ()
                in
                bind
                  env
                  mangled
                  (Types.mono
                     (Types.IFn
                        ( param_types
                        , annotated_or_fresh m.Ast.md_signature.Ast.ret
                        , row ))))
            (* An associated function takes no receiver, but its signature is
               still written in the impl's parameters. *)
            | written ->
              let mangled = Ast.impl_method_name trait type_name m.Ast.md_name in
              let type_params =
                impl_params @ type_params_of s.Ast.span m.Ast.md_signature.Ast.comptime
              in
              Hashtbl.replace ctx_fn_params mangled type_params;
              with_type_params type_params (fun () ->
                let row =
                  match m.Ast.md_signature.Ast.row with
                  | Some labels -> row_of_labels labels
                  | None -> Types.fresh_row ()
                in
                bind
                  env
                  mangled
                  (Types.mono
                     (Types.IFn
                        ( List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) written
                        , annotated_or_fresh m.Ast.md_signature.Ast.ret
                        , row )))))
          impl.Ast.ib_methods
      | `Fn (name, params, signature, _) ->
        let type_params = type_params_of s.Ast.span signature.Ast.comptime in
        Hashtbl.replace ctx_fn_params name type_params;
        with_type_params type_params (fun () ->
          let param_types =
            List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params
          in
          let row =
            match signature.Ast.row with
            | Some labels -> row_of_labels labels
            | None -> Types.fresh_row ()
          in
          bind
            env
            name
            (declared_scheme
               type_params
               (Types.IFn (param_types, annotated_or_fresh signature.Ast.ret, row))))
      | _ -> ())
    body

(* Load-bearing: hoisting reads signatures, which may name a declared type or
   trait, and a use may precede its declaration. *)
and infer_block env ctx (body : Ast.desugared_stmt list) : checked_stmt list =
  scoped_declarations (fun () ->
    declare_types body;
    declare_traits body;
    declare_impls ctx.registry body;
    hoist env body;
    let assigned = assigned_names body in
    List.map (fun s -> infer_stmt env ctx assigned s) body)

and infer_stmt env ctx assigned (s : Ast.desugared_stmt) : checked_stmt =
  try infer_stmt_impl env ctx assigned s with
  | Types.Type_error message -> raise (Located { span = s.Ast.span; message })

and infer_stmt_impl env ctx assigned (s : Ast.desugared_stmt) : checked_stmt =
  let span = s.Ast.span in
  let node it : checked_stmt = Ast.annotated span Types.IUnit it in
  match s.Ast.it with
  | `Expr e -> node (`Expr (infer_expr env ctx e))
  (* The arity is written, so the tuple it takes apart is known before the
     initializer is looked at — an annotation would say nothing more. *)
  | `Var_tuple (names, init) ->
    let init = infer_expr env ctx init in
    let parts = List.map (fun _ -> Types.fresh ()) names in
    unify_at init.Ast.span (Types.ITuple parts) init.Ast.ann;
    List.iter2 (fun name part -> bind env name (Types.mono part)) names parts;
    node (`Var_tuple (names, init))
  | `Var_decl (name, annotation, init) ->
    let declared = annotated_or_fresh annotation in
    let init =
      match init with
      | None ->
        Types.unify declared Types.IUnit;
        None
      | Some e ->
        let e' = infer_expr env ctx e in
        unify_at e'.Ast.span declared e'.Ast.ann;
        Some e'
    in
    let generalizable =
      (not (List.mem name assigned))
      && (match s.Ast.it with
          | `Var_decl (_, _, Some e) -> is_syntactic_value e
          | _ -> false)
    in
    bind
      env
      name
      (if generalizable
       then
         Types.generalize
           ~env_vars:(env_free_vars env)
           ~env_rows:(env_free_row_vars env)
           ~env_fields:(env_free_field_vars env)
           declared
       else Types.mono declared);
    node (`Var_decl (name, annotation, init))
  | `Block body ->
    let scope = new_env (Some env) in
    node (`Block (infer_block scope ctx body))
  | `If (cond, then_branch, else_branch) ->
    let cond = infer_expr env ctx cond in
    unify_at cond.Ast.span Types.IBool cond.Ast.ann;
    node
      (`If
        ( cond
        , infer_stmt env ctx assigned then_branch
        , Option.map (infer_stmt env ctx assigned) else_branch ))
  | `While (cond, body) ->
    let cond = infer_expr env ctx cond in
    unify_at cond.Ast.span Types.IBool cond.Ast.ann;
    node (`While (cond, infer_stmt env ctx assigned body))
  | `Fn (name, params, signature, body) ->
    with_type_params
      (Option.value ~default:[] (Hashtbl.find_opt ctx_fn_params name))
      (fun () ->
    let param_types, declared_ret, declared_row =
      match lookup env name with
      | Some { Types.body = Types.IFn (ps, r, row); _ } -> ps, r, row
      | _ ->
        ( List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params
        , annotated_or_fresh signature.Ast.ret
        , Types.fresh_row () )
    in
    let scope = new_env (Some env) in
    List.iter2
      (fun (p : Ast.param) ty -> bind scope p.Ast.name (Types.mono ty))
      params
      param_types;
    let body =
      in_function_body ctx ~ret:declared_ret ~row:declared_row (fun () ->
        infer_block scope ctx body)
    in
    let fn_type = Types.IFn (param_types, declared_ret, declared_row) in
    (* Leaving [hoist]'s binding in place would make the function's own variables
       count as free in the enclosing scope. *)
    Hashtbl.remove env.bindings name;
    bind
      env
      name
      (Types.generalize
         ~env_vars:(env_free_vars env)
         ~env_rows:(env_free_row_vars env)
         ~env_fields:(env_free_field_vars env)
         fn_type);
    Ast.annotated span fn_type (`Fn (name, params, signature, body)))
  | `Defer inner -> node (`Defer (infer_stmt env ctx assigned inner))
  | `Type_decl (name, params, body) -> node (`Type_decl (name, params, body))
  | `Trait_decl (name, params, methods) -> node (`Trait_decl (name, params, methods))
  | `Impl_decl (trait, type_name, params, impl) ->
    let inferred =
      List.map
        (fun (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
          let mangled = Ast.impl_method_name trait type_name m.Ast.md_name in
          with_type_params
            (Option.value ~default:[] (Hashtbl.find_opt ctx_fn_params mangled))
            (fun () ->
          let hoisted =
            match lookup env mangled with
            | Some { Types.body = Types.IFn (params, ret, row); _ }
              when List.length params = List.length m.Ast.md_params ->
              Some (params, ret, row)
            | _ -> None
          in
          let param_types, declared_ret, declared_row =
            match hoisted with
            | Some triple -> triple
            | None ->
              ( List.map
                  (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty)
                  m.Ast.md_params
              , annotated_or_fresh m.Ast.md_signature.Ast.ret
              , Types.fresh_row () )
          in
          let scope = new_env (Some env) in
          List.iter2
            (fun (p : Ast.param) ty -> bind scope p.Ast.name (Types.mono ty))
            m.Ast.md_params
            param_types;
          let body =
            in_function_body ctx ~ret:declared_ret ~row:declared_row (fun () ->
              infer_block scope ctx m.Ast.md_body)
          in
          let fn_type = Types.IFn (param_types, declared_ret, declared_row) in
          mangled, fn_type, { m with Ast.md_body = body; md_ann = fn_type }))
        impl.Ast.ib_methods
    in
    (* One variable per impl parameter is shared by every method, so the impl
       generalizes as a group or not at all. *)
    List.iter (fun (mangled, _, _) -> Hashtbl.remove env.bindings mangled) inferred;
    let env_vars = env_free_vars env
    and env_rows = env_free_row_vars env
    and env_fields = env_free_field_vars env in
    List.iter
      (fun (mangled, fn_type, _) ->
        bind env mangled (Types.generalize ~env_vars ~env_rows ~env_fields fn_type))
      inferred;
    node
      (`Impl_decl (trait, type_name, params, { impl with Ast.ib_methods = List.map (fun (_, _, m) -> m) inferred }))
  | `Match (scrutinee, cases) ->
    let scrutinee = infer_expr env ctx scrutinee in
    let sum, sum_args =
      match Types.repr scrutinee.Ast.ann with
      | Types.ISum (name, args) -> name, args
      | other ->
        fail
          scrutinee.Ast.span
          "Only a sum type can be matched, and this is %s."
          (Types.string_of_infer_ty other)
    in
    let vars, variants =
      match Hashtbl.find_opt ctx_types sum with
      | Some (Sum (vars, variants)) -> vars, variants
      | _ -> fail span "Unknown sum type '%s'." sum
    in
    (* Where `Expr<T>` becomes `Expr<int>`, and only for this arm — which is
       why it is solved into a substitution rather than unified. *)
    let refine declared =
      let freshened = instantiation vars declared in
      let head = List.map (Types.substitute freshened) declared.vd_result in
      match Types.solve (List.combine sum_args head) with
      | Some refinement -> freshened, refinement
      | None -> raise Not_found
    in
    (* Unreachable, so a match leaving it out is still exhaustive. *)
    let reachable declared =
      match refine declared with
      | _ -> true
      | exception Not_found -> false
    in
    (* The store is left alone, so a constraint the arm places on anything
       else is ordinary and permanent. *)
    let refined_scope refinement =
      let scope = new_env (Some env) in
      (* Substituting into the recursive occurrence would make the function
         monomorphic at this arm's type. *)
      let applicable (scheme : Types.scheme) =
        List.filter (fun (id, _) -> not (List.mem id scheme.Types.quantified)) refinement
      in
      let rec walk visible =
        Option.iter walk visible.parent;
        Hashtbl.iter
          (fun name (scheme : Types.scheme) ->
            match applicable scheme with
            | [] -> ()
            | refinement ->
              if
                List.exists
                  (fun (id, _) -> List.mem_assoc id refinement)
                  (Types.free_vars scheme.Types.body)
              then
                bind
                  scope
                  name
                  { scheme with Types.body = Types.substitute refinement scheme.Types.body })
          visible.bindings
      in
      walk env;
      scope
    in
    let refined_params refinement =
      Hashtbl.fold
        (fun name var found ->
          match Types.repr var with
          | Types.IVar { contents = Types.Unbound (id, _) } when List.mem_assoc id refinement ->
            (name, Types.substitute refinement var) :: found
          | _ -> found)
        ctx_type_params
        []
    in
    let covered = ref [] in
    let arm variant declared payload body =
      let freshened, refinement =
        if not declared.vd_refines
        then instance vars sum_args, []
        else (
          match refine declared with
          | solved -> solved
          | exception Not_found ->
            fail
              span
              "'%s' cannot be a %s, so this arm can never match."
              variant
              (Types.string_of_infer_ty (Types.ISum (sum, sum_args))))
      in
      let scope = if refinement = [] then new_env (Some env) else refined_scope refinement in
      let expected =
        List.map
          (fun (l, t) -> l, Types.substitute refinement (Types.substitute freshened t))
          (Ast.payload_fields declared.vd_payload)
      in
      let bindings = Ast.payload_fields payload in
      if List.length expected <> List.length bindings
      then
        fail
          span
          "Variant '%s' carries %d value(s) but %d were bound."
          variant
          (List.length expected)
          (List.length bindings);
      List.iter
        (fun (l, name) ->
          match List.assoc_opt l expected with
          | Some ty -> bind scope name (Types.mono ty)
          | None -> fail span "Variant '%s' has no field '%s'." variant l)
        bindings;
      if refinement = []
      then infer_block scope ctx body
      else
        with_type_params (refined_params refinement) (fun () ->
          (* A `return` here is a fact about the function, not the arm. *)
          let returned = ref false in
          let checked =
            in_ctx
              ctx
              ~set:(fun () ->
                ctx.return_type <- Option.map (Types.substitute refinement) ctx.return_type)
              (fun () ->
                let checked = infer_block scope ctx body in
                returned := ctx.saw_return;
                checked)
          in
          if !returned then ctx.saw_return <- true;
          checked)
    in
    let cases =
      List.map
        (fun ((pattern : Ast.pattern), body) ->
          match pattern with
          | Ast.Pat_wild ->
            covered := List.map fst variants;
            pattern, infer_block (new_env (Some env)) ctx body
          | Ast.Pat_variant (ty, variant, payload) ->
            if not (String.equal ty sum)
            then fail span "This matches a %s, not a %s." ty sum;
            (match List.assoc_opt variant variants with
             | None -> fail span "Type '%s' has no variant '%s'." sum variant
             | Some declared ->
               covered := variant :: !covered;
               pattern, arm variant declared payload body))
        cases
    in
    List.iter
      (fun (name, declared) ->
        if (not (List.mem name !covered)) && reachable declared
        then fail span "This match does not cover '%s'." name)
      variants;
    node (`Match (scrutinee, cases))
  | `Effect_decl (name, params, ops) ->
    Hashtbl.replace ctx_effects.declared name ops;
    (* One per declaration, so operations naming it agree. *)
    let bound = List.map (fun p -> p, Types.fresh ()) params in
    Hashtbl.replace ctx_effect_params name bound;
    with_type_params bound (fun () ->
    List.iter
      (fun (o : Ast.op_decl) ->
        (match Hashtbl.find_opt ctx_op_owner o.Ast.op_name with
         | Some owner when not (String.equal owner name) ->
           fail span "Effect '%s' already declares an operation '%s'." owner o.Ast.op_name
         | _ -> ());
        Hashtbl.replace ctx_op_owner o.Ast.op_name name;
        Hashtbl.replace ctx_effects.ops o.Ast.op_name o;
        let own = List.map (fun p -> p, Types.fresh ()) o.Ast.op_tparams in
        let params, ret =
          with_type_params own (fun () ->
            ( List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) o.Ast.op_params
            , annotated_or_fresh o.Ast.op_ret ))
        in
        let op_type =
          Types.IFn (params, ret, Types.RCons (name, List.map snd bound, Types.fresh_row ()))
        in
        (* It never hands anything back, so quantifying its result is sound. *)
        let ids_of assoc =
          List.filter_map
            (fun (_, v) ->
              match Types.repr v with
              | Types.IVar { contents = Types.Unbound (id, _) } -> Some id
              | _ -> None)
            assoc
        in
        let effect_vars = ids_of bound @ ids_of own in
        let quantified =
          effect_vars
          @
          match o.Ast.op_kind with
          | Ast.Op_fn | Ast.Op_ctl -> []
          | Ast.Op_final ->
            let pinned = List.concat_map Types.free_vars params |> List.map fst in
            Types.free_vars ret
            |> List.map fst
            |> List.filter (fun id -> not (List.mem id pinned))
        in
        bind
          env
          o.Ast.op_name
          { Types.quantified
          ; quantified_rows = Types.free_row_vars op_type
          ; quantified_fields = []
          ; body = op_type
          })
      ops);
    node (`Effect_decl (name, params, ops))
  | `Run (body, handlers) ->
    let (body, _), handlers =
      check_run env ctx assigned span ~answer:Types.IUnit handlers (fun () ->
        { Ast.vb_stmts = infer_block (new_env (Some env)) ctx body; vb_value = None }
        , Types.IUnit)
    in
    node (`Run (body.Ast.vb_stmts, handlers))
  | `Resume value ->
    let expected =
      match ctx.resume_type with
      | Some t -> t
      | None ->
        if ctx.in_final_arm
        then
          fail
            span
            "A 'final ctl' handler cannot resume — that is what lets its result \
             be whatever each call site needs."
        else fail span "'resume' outside of a 'ctl' handler."
    in
    let value =
      match value with
      | None ->
        unify_at span expected Types.IUnit;
        None
      | Some e ->
        let e' = infer_expr env ctx e in
        unify_at e'.Ast.span expected e'.Ast.ann;
        Some e'
    in
    node (`Resume value)
  | `Return e ->
    let expected =
      match ctx.return_type with
      | Some t -> t
      | None -> fail span "'return' outside of a function."
    in
    ctx.saw_return <- true;
    let e =
      match e with
      | None ->
        Types.unify expected Types.IUnit;
        None
      | Some e ->
        let e' = infer_expr env ctx e in
        unify_at e'.Ast.span expected e'.Ast.ann;
        Some e'
    in
    node (`Return e)

(* The row work is the same wherever a `run` stands; [answer] is what its arms
   and its return clause must agree on. *)
and check_run env ctx assigned span ~answer handlers infer_body =
  List.iter
    (fun (h : Ast.desugared_stmt Ast.handler) ->
      match Hashtbl.find_opt ctx_effects.declared h.Ast.handled with
      | None -> fail span "Unknown effect '%s'." h.Ast.handled
      | Some ops ->
        List.iter
          (fun (o : Ast.op_decl) ->
            if not (List.exists (fun (a : Ast.desugared_stmt Ast.arm) ->
                      String.equal a.Ast.arm_name o.Ast.op_name)
                      h.Ast.arms)
            then
              fail
                span
                "Handler for '%s' is missing operation '%s'."
                h.Ast.handled
                o.Ast.op_name)
          ops;
        List.iter
          (fun (a : Ast.desugared_stmt Ast.arm) ->
            if not (List.exists (fun (o : Ast.op_decl) ->
                      String.equal o.Ast.op_name a.Ast.arm_name)
                      ops)
            then
              fail
                span
                "Effect '%s' has no operation '%s'."
                h.Ast.handled
                a.Ast.arm_name)
          h.Ast.arms)
    handlers;
  let body_row = Types.fresh_row () in
  let body = in_ctx ctx ~set:(fun () -> ctx.row <- body_row) (fun () -> infer_body ()) in
  let instantiated =
    List.map
      (fun (h : Ast.desugared_stmt Ast.handler) ->
        let arity =
          List.length
            (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params h.Ast.handled))
        in
        h, List.init arity (fun _ -> Types.fresh ()))
      handlers
  in
  let remaining =
    List.fold_left
      (fun row ((h : Ast.desugared_stmt Ast.handler), args) ->
        try Types.rewrite_row h.Ast.handled args row with
        | Types.Type_error _ -> row)
      body_row
      instantiated
  in
  Types.unify_row remaining ctx.row;
  ( body
  , List.map (fun (h, args) -> infer_handler env ctx assigned ~answer ~args h) instantiated )

(* An arm performing its own operation propagates outward. *)
and infer_handler env ctx assigned ~answer ~args (h : Ast.desugared_stmt Ast.handler)
  : checked_stmt Ast.handler
  =
  let arm (a : Ast.desugared_stmt Ast.arm) : checked_stmt Ast.arm =
    let op = Hashtbl.find ctx_effects.ops a.Ast.arm_name in
    (* One arm serves every instantiation, so the operation's own parameters
       stay variables its body is not allowed to settle. *)
    let own =
      List.map
        (fun name ->
          let var = Types.fresh () in
          Types.declare_param var;
          name, var)
        op.Ast.op_tparams
    in
    with_type_params own (fun () ->
    let param_types =
      List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) op.Ast.op_params
    in
    if List.length param_types <> List.length a.Ast.arm_params
    then
      Types.error
        "Operation '%s' takes %d argument(s) but the handler binds %d."
        a.Ast.arm_name
        (List.length param_types)
        (List.length a.Ast.arm_params);
    (* The declaration is the worst case the performing function was compiled
       for, so a handler may promise less than it and never more: a `fn`
       operation's caller has no continuation for a `ctl` arm to capture. *)
    (match op.Ast.op_kind, a.Ast.arm_kind with
     | Ast.Op_fn, (Ast.Op_ctl | Ast.Op_final) | Ast.Op_final, Ast.Op_ctl ->
       Types.error
         "'%s' is declared `%s`, so a handler may not answer it with `%s`."
         a.Ast.arm_name
         (kind_name op.Ast.op_kind)
         (kind_name a.Ast.arm_kind)
     | _ -> ());
    let scope = new_env (Some env) in
    List.iter2 (fun name ty -> bind scope name (Types.mono ty)) a.Ast.arm_params param_types;
    let body =
      in_ctx
        ctx
        ~set:(fun () ->
          ctx.resume_type
          <- (match a.Ast.arm_kind with
              | Ast.Op_ctl -> Some (annotated_or_fresh op.Ast.op_ret)
              | Ast.Op_fn | Ast.Op_final -> None);
          ctx.in_final_arm <- a.Ast.arm_kind = Ast.Op_final;
          (* An `fn` arm's value resumes the operation; any other arm's answers
             for the whole `run`. *)
          ctx.return_type
          <- Some
               (match a.Ast.arm_kind with
                | Ast.Op_fn -> annotated_or_fresh op.Ast.op_ret
                | Ast.Op_ctl | Ast.Op_final -> answer);
          ctx.saw_return <- false)
        (fun () ->
          let body = List.map (infer_stmt scope ctx assigned) a.Ast.arm_body in
          (* Leaving without answering and without handing the continuation the
             job leaves nothing for the `run` to evaluate to. *)
          (match a.Ast.arm_kind with
           | Ast.Op_fn -> ()
           | Ast.Op_ctl | Ast.Op_final ->
             if (not ctx.saw_return) && not (List.exists resumes a.Ast.arm_body)
             then Types.unify answer Types.IUnit);
          body)
    in
    List.iter
      (fun (name, var) ->
        match Types.repr var with
        | Types.IVar { contents = Types.Unbound _ } -> ()
        | settled ->
          Types.error
            "This handler settles '%s' at %s, but '%s' is handled once for every \
             type its call sites use."
            name
            (Types.string_of_infer_ty settled)
            a.Ast.arm_name)
      own;
    { Ast.arm_name = a.Ast.arm_name
    ; arm_kind = a.Ast.arm_kind
    ; arm_params = a.Ast.arm_params
    ; arm_body = body
    })
  in
  let names =
    List.map fst (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params h.Ast.handled))
  in
  with_type_params
    (try List.combine names args with
     | Invalid_argument _ -> [])
    (fun () -> { Ast.handled = h.Ast.handled; arms = List.map arm h.Ast.arms })

let rec resolve_expr (e : checked_expr) : Ast.typed_expr =
  let it : Ast.typed_expr_kind =
    match e.Ast.it with
    | #Ast.lit as l -> l
    | `Lambda (params, signature, body) ->
      `Lambda (params, signature, List.map resolve_stmt body)
    | #Ast.arrays as a -> (Ast.map_arrays resolve_expr a :> Ast.typed_expr_kind)
    | #Ast.strings as s -> (Ast.map_strings resolve_expr s :> Ast.typed_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars resolve_expr v :> Ast.typed_expr_kind)
    | #Ast.ops as o -> (Ast.map_ops resolve_expr o :> Ast.typed_expr_kind)
    | #Ast.logic as l -> (Ast.map_logic resolve_expr l :> Ast.typed_expr_kind)
    | #Ast.compound as c -> (Ast.map_compound resolve_expr c :> Ast.typed_expr_kind)
    | #Ast.indexing as i -> (Ast.map_indexing resolve_expr i :> Ast.typed_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple resolve_expr t :> Ast.typed_expr_kind)
    | #Ast.record as r -> (Ast.map_record resolve_expr r :> Ast.typed_expr_kind)
    | #Ast.nominal as n -> (Ast.map_nominal resolve_expr n :> Ast.typed_expr_kind)
    | #Ast.collection as c ->
      (Ast.map_collection resolve_expr c :> Ast.typed_expr_kind)
    | #Ast.method_call as m ->
      (Ast.map_method_call resolve_expr m :> Ast.typed_expr_kind)
    | #Ast.reflect as r -> (Ast.map_reflect resolve_expr r :> Ast.typed_expr_kind)
    | #Ast.run_expr as r ->
      (Ast.map_run_expr resolve_expr resolve_stmt (Ast.map_handler resolve_stmt) r
       :> Ast.typed_expr_kind)
  in
  { Ast.it; span = e.Ast.span; ann = Types.resolve e.Ast.ann }

and resolve_stmt (s : checked_stmt) : Ast.typed_stmt =
  let it : Ast.typed_stmt_kind =
    match s.Ast.it with
    | #Ast.stmts as st -> (Ast.map_stmts resolve_expr resolve_stmt st :> Ast.typed_stmt_kind)
    | #Ast.effects as e ->
      (Ast.map_effects resolve_expr resolve_stmt (Ast.map_handler resolve_stmt) e
       :> Ast.typed_stmt_kind)
    | #Ast.type_defs as t -> t
    | #Ast.matching as m ->
      (Ast.map_matching resolve_expr resolve_stmt m :> Ast.typed_stmt_kind)
    | #Ast.method_defs as m ->
      (Ast.map_method_defs resolve_stmt Types.resolve m :> Ast.typed_stmt_kind)
  in
  { Ast.it; span = s.Ast.span; ann = Types.resolve s.Ast.ann }

(* A closed row here would close the caller's, since a call unifies them. *)
let pure params ret =
  let row = Types.fresh_row () in
  let scheme_of body =
    { Types.quantified = List.map fst (Types.free_vars body)
    ; quantified_rows = Types.free_row_vars body
    ; quantified_fields = []
    ; body
    }
  in
  scheme_of (Types.IFn (params, ret, row))

(* A bound naming the parameter it constrains — `T: Add<T>` — is taken to hold
   while it is being proved, or proving it never ends. *)
let proving : (string * string) list ref = ref []

let satisfies name (b : Types.bound) =
  List.exists
    (fun declared ->
      List.length declared = List.length b.Types.bd_args
      &&
      try
        List.iter2 Types.unify b.Types.bd_args declared;
        true
      with
      | Types.Type_error _ -> false)
    (Hashtbl.find_all ctx_impls (name, b.Types.bd_trait))
  (* The impl reached must have bound the name to what the bound said. *)
  && List.for_all
       (fun (member, expected) ->
         match Hashtbl.find_opt ctx_assoc (name, member) with
         | None -> false
         | Some found ->
           (try
              Types.unify found expected;
              true
            with
            | Types.Type_error _ -> false))
       b.Types.bd_bindings

let admits registry kind (t : Types.infer_ty) =
  match kind with
  | Types.Collection elem ->
    (match Types.infer_type_name t with
     | Some name when String.equal name Types.array_name ->
       (match Types.container_element t with
        | Some (_, held) ->
          Types.unify elem held;
          true
        | None -> false)
     | Some name ->
       (match Registry.container_element registry name t with
        | Some held ->
          Types.unify elem held;
          true
        | None -> false)
     | None -> false)
  | Types.Bound traits ->
    (match Types.infer_type_name t with
     | Some name ->
       List.for_all
         (fun (b : Types.bound) ->
           let goal = b.Types.bd_trait, name in
           if List.mem goal !proving
           then true
           else (
             proving := goal :: !proving;
             Fun.protect
               ~finally:(fun () -> proving := List.tl !proving)
               (fun () -> satisfies name b)))
         traits
     | None -> false)
  | Types.Any -> true
  | Types.Projection _ -> true

(* Read back out of the registry, so the two accounts cannot disagree. *)
let declare_builtin_impls registry =
  List.iter
    (fun ty ->
      Hashtbl.add ctx_impls (Option.get (Types.type_name ty), "Eq") [])
    [ Types.Int; Types.Float; Types.Str; Types.Chr; Types.Byte; Types.Bool; Types.Unit ];
  (* Whatever the registry can compare has an order, which is what a
     `PartialOrd` bound asks for. *)
  List.iter
    (fun ty ->
      if Registry.find registry Ast.Less ty ty <> None
      then Hashtbl.add ctx_impls (Option.get (Types.type_name ty), "PartialOrd") [])
    [ Types.Int; Types.Float; Types.Chr; Types.Byte ];
  List.iter
    (fun ty -> Hashtbl.add ctx_impls (Option.get (Types.type_name ty), "Neg") [])
    [ Types.Int; Types.Float ];
  List.iter
    (fun (trait, (binary, _)) ->
      List.iter
        (fun ty ->
          match Registry.find registry binary ty ty with
          | None -> ()
          | Some entry ->
            let name = Option.get (Types.type_name ty) in
            Hashtbl.add ctx_impls (name, trait) [ Types.of_ty ty ];
            Hashtbl.replace
              ctx_assoc
              (name, "Output")
              (Types.of_ty (Registry.result_of entry ty)))
        [ Types.Int; Types.Float; Types.Str; Types.Chr; Types.Byte; Types.Bool ])
    operator_traits

let declare_builtins env =
  (* A receiver of unknown type has to see the length method to be ambiguous. *)
  Hashtbl.replace ctx_methods (Types.array_name, Types.array_len) ();
  Hashtbl.replace ctx_methods (Types.string_name, Types.array_len) ();
  List.iter
    (fun (name, arity) ->
      Hashtbl.replace ctx_types name (Opaque (List.init arity (fun _ -> Types.fresh ()))))
    Builtins.types;
  List.iter
    (fun (owner, name, signature) ->
      let params, ret = signature () in
      Hashtbl.replace ctx_methods (owner, name) ();
      bind env (Ast.method_name owner name) (pure params ret))
    Builtins.methods;
  List.iter
    (fun (name, signature) ->
      let params, ret = signature () in
      bind env name (pure params ret))
    Builtins.functions;
  List.iter
    (fun (name, result) ->
      let result = result () in
      let scheme =
        { Types.quantified = []
        ; quantified_rows = []
        ; quantified_fields = []
        ; body = Types.IFn ([], result, Types.REmpty)
        }
      in
      Hashtbl.replace ctx_variadic name (scheme, result);
      bind env name scheme)
    Builtins.variadic

let check ~registry (program : Ast.desugared_stmt list)
  : (Ast.typed_stmt list, error list) result
  =
  Types.reset ();
  Types.extra_admits := admits registry;
  Types.assoc_binding := (fun owner member -> Hashtbl.find_opt ctx_assoc (owner, member));
  reset_effects ();
  let env = new_env None in
  declare_builtins env;
  declare_builtin_impls registry;
  let ctx =
    { registry
    ; return_type = None
    ; saw_return = false
    ; row = Types.fresh_row ()
    ; resume_type = None
    ; in_final_arm = false
    }
  in
  let errors = ref [] in
  (* Per statement: everything after a bad declaration would otherwise be checked
     without the signatures it needs. *)
  let each pass =
    List.iter
      (fun s ->
        try pass [ s ] with
        | Located e -> errors := e :: !errors)
      program
  in
  each declare_types;
  each declare_traits;
  each (declare_impls registry);
  each (hoist env);
  let assigned = assigned_names program in
  let checked =
    List.filter_map
      (fun s ->
        try Some (infer_stmt env ctx assigned s) with
        | Located e ->
          errors := e :: !errors;
          None)
      program
  in
  let errors =
    match (Types.resolve_row ctx.row).Types.labels with
    | [] -> !errors
    | labels ->
      { span = Source_map.Span.nowhere
      ; message =
          Printf.sprintf
            "Unhandled effect(s): %s."
            (String.concat ", " (List.map (Types.entry Types.string_of_ty) labels))
      }
      :: !errors
  in
  match List.rev errors with
  | [] -> Ok (List.map resolve_stmt checked)
  | errors -> Error errors
