(* A node's type is not finished when it is first visited — `x` in
   `fn f(x) { return x + 1; }` is pinned at the `+` — so the tree is built with
   mutable types and resolved once at the end. *)

type error =
  { span : Ast.span
  ; message : string
  }

exception Located of error

(* What the checker does where a name has nothing declared behind it. Once
   metaprocessing is done that is an error. Before it runs, a meta block may
   still declare the name, so the check carries on as if it knew nothing about
   it: [unknown fail anything] either fails or answers with [anything ()]. *)
type policy = { unknown : 'a. (unit -> 'a) -> (unit -> 'a) -> 'a }

let strict = { unknown = (fun fail _ -> fail ()) }
let partial = { unknown = (fun _ anything -> anything ()) }
let current = ref strict

(* The types made up for names nothing declared yet, and what calling one
   returns: a receiver of one of these is unknown because of a meta block, where
   any other unpinned receiver is ambiguous whatever a meta block does. *)
let unknowns : Types.infer_ty list ref = ref []

let unknown_ty () =
  let t = Types.fresh () in
  unknowns := t :: !unknowns;
  t

(* By cell, not by node: unifying two variables links one to a fresh [IVar]
   around the other's cell, so the same variable has more than one node. *)
let is_unknown t =
  let same u =
    match Types.repr u, Types.repr t with
    | Types.IVar a, Types.IVar b -> a == b
    | u, t -> u == t
  in
  List.exists same !unknowns

(* Nothing handles the top level's row, and once a label is in it the row no
   longer says which call put it there, so each is recorded as it arrives. The
   checker finishes a node after its children, so the innermost one records it. *)
let top_row : Types.infer_row option ref = ref None
let effect_sites : (string, Source_map.Span.t) Hashtbl.t = Hashtbl.create 8

(* A deferred statement runs while a failure may already be unwinding, and one
   of its own would replace it, so its row may hold nothing that never resumes.
   Read once checking is done: a callee not yet checked adds to it later. A
   call through a row the enclosing function declares is refused outright,
   since its caller can put anything there. *)
type deferred =
  { d_span : Source_map.Span.t
  ; d_row : Types.infer_row
  ; mutable d_open : bool
  }

let deferred_rows : deferred list ref = ref []

(* The parameter a lambda argument is passed to, set by the call just before the
   lambda is checked and read by it first thing, so nothing nested sees it. *)
let expected_lambda : Types.infer_ty option ref = ref None

(* The row a trait's method performs when reached through a table: the one the
   trait wrote, or none. A copy made at an object calls through the table, and
   only [Resolve] learns that it was made at one. *)
let dynamic_rows : (string * string, Types.infer_row) Hashtbl.t = Hashtbl.create 16
let open_defer : deferred option ref = ref None

(* Each top-level statement is the body of a function handed to the root, so
   its row stands in for the top level's while it is checked: otherwise every
   site would be the whole statement. Set by the call, read by its lambda. *)
let root_argument = ref false

let note_effect_sites span row =
  match !top_row with
  | Some top when top == row ->
    List.iter
      (fun (label, _) ->
        if not (Hashtbl.mem effect_sites label) then Hashtbl.add effect_sites label span)
      (fst (Types.labels_of_infer_row row))
  | _ -> ()

type checked_expr = (checked_expr_kind, Types.infer_ty) Ast.node

and checked_expr_kind =
  [ Ast.lit
  | checked_expr Ast.vars
  | checked_expr Ast.ops
  | checked_expr Ast.logic
  | checked_expr Ast.compound
  | checked_expr Ast.indexing
  | checked_expr Ast.tuple
  | checked_expr Ast.spread
  | checked_expr Ast.record
  | checked_expr Ast.nominal
  | checked_expr Ast.collection
  | checked_expr Ast.arrays
  | checked_expr Ast.strings
  | (checked_expr, Types.infer_ty) Ast.bound_calls
  | (checked_expr, Types.infer_ty) Ast.dyn_calls
  | (checked_expr, Types.infer_ty) Ast.coercions
  | checked_expr Ast.reflect
  | (checked_expr, checked_stmt) Ast.lambdas
  | (checked_expr, checked_stmt, checked_stmt Ast.handler) Ast.run_expr
  | (checked_expr, checked_stmt) Ast.match_expr
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

(* The first member of the type being declared whose type did not read. *)
let unreadable_member : error option ref = ref None

(* What a type declared its parameters as, for reflection to name them. *)
let ctx_type_param_names : (string, string list) Hashtbl.t = Hashtbl.create 8

let attrs_of name label =
  match Hashtbl.find_opt ctx_attrs name with
  | None -> []
  | Some members ->
    (match List.assoc_opt label members with
     | None -> []
     | Some attrs -> attrs)

let ctx_type_params : (string, Types.infer_ty) Hashtbl.t = Hashtbl.create 8

(* Whose last parameter is a pack, so a written argument list is collected into
   it rather than matched one for one. *)
let ctx_type_packs : (string, unit) Hashtbl.t = Hashtbl.create 8

let decl_params = function
  | Opaque vars | Product (vars, _) | Sum (vars, _) -> vars

let params_of_decl name =
  match Hashtbl.find_opt ctx_types name with
  | Some decl -> decl_params decl
  | None -> []

(* A declared type's parameters standing in a row -- `E` in
   `type Iter<T, E> { next: () -> <E> Option<T> }` -- by the variable the
   declaration registered, with the row its body is open in; and per type, which
   of its parameters those are, so a written argument is read as a row there. *)
let ctx_standing_rows : (int, Types.infer_row) Hashtbl.t = Hashtbl.create 8
let ctx_row_standing : (string, bool list) Hashtbl.t = Hashtbl.create 8

(* A parameter standing in a row maps its row too, to the row its argument is. *)
let instance vars args =
  List.concat
    (List.map2
       (fun v a ->
         let id = Types.var_id v in
         (id, a)
         ::
         (match Hashtbl.find_opt ctx_standing_rows id, Types.repr a with
          | Some row, Types.IRow _ ->
            (match Types.row_tail row with
             | Some row_id -> [ row_id, a ]
             | None -> [])
          | _ -> []))
       vars
       args)

let fresh_argument v =
  if Hashtbl.mem ctx_standing_rows (Types.var_id v)
  then Types.IRow (Types.fresh_row ())
  else Types.fresh ()

(* The type's parameters and the variant's own together: a payload or head may
   mention both. *)
let instantiation vars declared =
  let bound = vars @ declared.vd_params in
  instance bound (List.map fresh_argument bound)

let ctx_fn_params : (string, (string * Types.infer_ty) list) Hashtbl.t =
  Hashtbl.create 16

(* A parameter standing in a row is a row variable rather than an effect named
   after it, so each also gets one. Which of the two a mention is follows from
   where it stands, as it does in Koka. *)
let ctx_row_params : (string, Types.infer_row) Hashtbl.t = Hashtbl.create 8

(* Keyed by the parameter's own variable, so entering its scope again finds the
   same row: a signature is read when it is hoisted and again when its body is
   checked, and a fresh row each time makes the body's `E` a different variable
   from the signature's -- which a nested function then generalizes over. *)
let param_rows : (Types.infer_ty * Types.infer_row) list ref = ref []

let row_of_param var =
  match List.assq_opt var !param_rows with
  | Some row -> row
  | None ->
    let row = Types.fresh_row () in
    Types.declare_row row;
    param_rows := (var, row) :: !param_rows;
    row

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
      Types.name_param name var;
      Hashtbl.replace
        ctx_row_params
        name
        (match Types.repr var with
         | Types.IRow row -> row
         | _ -> row_of_param var))
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

(* What is declared already, so a second declaration of a name is caught. *)
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
  and param_names = snapshot ctx_type_param_names
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
      restore ctx_type_param_names param_names;
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
  Hashtbl.reset ctx_type_packs;
  Hashtbl.reset ctx_standing_rows;
  Hashtbl.reset ctx_row_standing;
  Hashtbl.reset ctx_attrs;
  Hashtbl.reset ctx_type_param_names;
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
  Hashtbl.reset ctx_fn_params;
  param_rows := []

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

(* An unknown is never quantified: each use would instantiate a fresh variable,
   and a fresh variable is no longer known to be unknown. *)
let env_free_vars env =
  env_free
    ~free:(fun body -> List.map fst (Types.free_vars body))
    ~quantified:(fun (s : Types.scheme) -> s.Types.quantified)
    env
  @ List.concat_map (fun u -> List.map fst (Types.free_vars u)) !unknowns

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

(* The module a mangled name was declared in, for a message that has to say
   where to import it from: [std#Error#Result] is Error, in std. A message
   shows every mangled name by its last part, so two different declarations of
   one name read the same without this. *)
let declared_in name =
  let is_number part = part <> "" && String.for_all (fun c -> c >= '0' && c <= '9') part in
  match List.filter (fun part -> not (is_number part)) (String.split_on_char '#' name) with
  | [ package; namespace; _ ] -> Some (Printf.sprintf "'%s', in %s" namespace package)
  | [ namespace; _ ] -> Some (Printf.sprintf "'%s'" namespace)
  | _ -> None

(* Each declaration of the name, other than [except], by where it was declared. *)
let declarations_of table ~except name =
  Hashtbl.fold
    (fun key _ acc ->
      if (not (String.equal key except))
         && (String.equal key name || String.ends_with ~suffix:("#" ^ name) key)
      then key :: acc
      else acc)
    table
    []
  |> List.sort_uniq String.compare
  |> List.filter_map declared_in

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Located { span; message })) fmt

type receiver =
  | Owner of string
  | Via_trait of string

(* Which trait gives an operator its meaning, and whether that trait fixes the
   result at bool rather than binding an `Output`. *)
let trait_of_operator (op : Ast.binop) =
  match op with
  | Ast.Add -> Some (Core.add, false)
  | Ast.Sub -> Some (Core.sub, false)
  | Ast.Mul -> Some (Core.mul, false)
  | Ast.Div -> Some (Core.div, false)
  | Ast.Mod -> Some (Core.rem, false)
  | Ast.Bit_and -> Some (Core.bit_and, false)
  | Ast.Bit_or -> Some (Core.bit_or, false)
  | Ast.Bit_xor -> Some (Core.bit_xor, false)
  | Ast.Shl -> Some (Core.shl, false)
  | Ast.Shr -> Some (Core.shr, false)
  (* `==` compares any two values of a type structurally, so it constrains an
     operand no further. What `T: Eq` asks for is an impl to reach, which is a
     different question from whether the operator works. *)
  | Ast.Equal | Ast.Not_equal -> None
  | Ast.Less | Ast.Less_equal | Ast.Greater | Ast.Greater_equal ->
    Some (Core.partial_ord, true)

let operator_traits =
  [ Core.add, (Ast.Add, "add")
  ; Core.sub, (Ast.Sub, "sub")
  ; Core.mul, (Ast.Mul, "mul")
  ; Core.div, (Ast.Div, "div")
  ; Core.rem, (Ast.Mod, "rem")
  ; Core.bit_and, (Ast.Bit_and, "bit_and")
  ; Core.bit_or, (Ast.Bit_or, "bit_or")
  ; Core.bit_xor, (Ast.Bit_xor, "bit_xor")
  ; Core.shl, (Ast.Shl, "shl")
  ; Core.shr, (Ast.Shr, "shr")
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
  (* A trait object names a trait, so the trait declares the signature and the
     value carries which body answers. *)
  | Some owner when Hashtbl.mem ctx_traits owner -> Via_trait owner
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
(* The functions and methods hoisted and not yet generalized, by name. *)
let unchecked : (string, unit) Hashtbl.t = Hashtbl.create 64

(* A call to one of them, whose row is not written: its callee's row is
   contained in its caller's once the callee is checked. Containment is
   recorded rather than the two rows made equal, because a method call names
   every method of its name, so a group of declarations checked together is
   often wider than what calls what, and equal rows would give a pure method
   the effects of whichever caller met it first. *)
let pending_calls : (string * Types.infer_row * Types.infer_row) list ref = ref []

(* Until nothing changes, since a callee may gain labels from its own pending
   callees after a caller has been given its labels. A callee generalized
   since the last time has its final row, so its calls are settled for good. *)
let discharge_pending () =
  pending_calls := List.filter (fun (name, _, _) -> Hashtbl.mem unchecked name) !pending_calls;
  let size () =
    List.fold_left
      (fun n (_, callee, caller) ->
        n + List.length (fst (Types.labels_of_infer_row callee))
        + List.length (fst (Types.labels_of_infer_row caller)))
      0
      !pending_calls
  in
  let rec settle before =
    List.iter (fun (_, callee, caller) -> Types.row_within callee caller) !pending_calls;
    let after = size () in
    if after <> before then settle after
  in
  settle (size ())

let admits_row ?name (callee : Types.scheme option) row (caller : Types.infer_row) =
  let pending =
    (not (Types.row_is_declared row))
    &&
    match Types.repr_row row, callee with
    | Types.RVar _, Some { Types.quantified_rows = []; _ } -> true
    | Types.RVar _, None -> true
    | _ -> false
  in
  (match !open_defer with
   | Some d when caller == d.d_row && Types.row_is_declared row -> d.d_open <- true
   | _ -> ());
  match name with
  | Some name when Hashtbl.mem unchecked name && not (Types.row_is_declared row) ->
    pending_calls := (name, row, caller) :: !pending_calls
  | _ -> if pending then Types.unify_row row caller else Types.row_within row caller

let unify_at span expected actual =
  try Types.unify expected actual with
  | Types.Type_error message -> raise (Located { span; message })

let is_trait_type (t : Types.infer_ty) =
  match Types.repr t with
  | Types.INamed (name, _) -> Hashtbl.mem ctx_traits name
  | _ -> false

(* The one place a value's type changes without unifying. A trait in type
   position is an object, and a written type is the only thing that asks for
   one: inference never produces a trait, so it never reaches here. *)
let rec mentions_trait (t : Types.infer_ty) =
  match Types.repr t with
  | Types.INamed (name, args) ->
    Hashtbl.mem ctx_traits name || List.exists mentions_trait args
  | Types.ISum (_, args) -> List.exists mentions_trait args
  | _ -> false

let not_pure (written : Ast.desugared_expr) param (arg : checked_expr) =
  match Types.repr param, Types.repr arg.Ast.ann with
  | Types.IFn (_, _, expected), Types.IFn (_, _, actual) ->
    (match Types.labels_of_infer_row expected, Types.labels_of_infer_row actual with
     | ([], false), ((_ :: _ as labels), _) ->
       fail
         arg.Ast.span
         "%s performs %s, but the parameter's function type is written without a row, so it \
          is pure. A row variable lets the effects through, as in (T) -> <E> T."
         (match written.Ast.it with
          | `Var name -> Printf.sprintf "'%s'" name
          | _ -> "This argument")
         (String.concat ", " (List.map (fun (l, _) -> Printf.sprintf "'%s'" l) labels))
     | _ -> ())
  | _ -> ()

(* The object and the bound are spelled with the same name, so unification
   would report the trait against itself. *)
let not_a_bound ~declared (written : Ast.desugared_expr) param (arg : checked_expr) =
  match Types.repr param, Types.infer_type_name (Types.repr arg.Ast.ann) with
  | Types.IVar { contents = Types.Unbound (_, Types.Bound (bound :: _)) }, Some trait
    when Hashtbl.mem ctx_traits trait && not (List.mem bound.Types.bd_trait (trait_closure trait)) ->
    (* Instantiation renames, so the parameter is called what the declaration
       called it rather than what the copy carries. *)
    let named =
      match
        List.filter
          (fun (_, t) ->
            match Types.repr t with
            | Types.IVar { contents = Types.Unbound (_, Types.Bound bounds) } ->
              List.exists
                (fun (b : Types.bound) -> String.equal b.Types.bd_trait bound.Types.bd_trait)
                bounds
            | _ -> false)
          declared
      with
      | [ (name, _) ] -> name
      | _ -> "T"
    in
    fail
      arg.Ast.span
      "%s is a '%s' object, which meets that trait and its supertraits; '<%s: %s>' needs \
       the type behind it, which an object does not carry."
      (match written.Ast.it with
       | `Var name -> Printf.sprintf "'%s'" name
       | _ -> "This argument")
      trait
      named
      bound.Types.bd_trait
  | _ -> ()

(* Whether a `break` here leaves a loop. A function, a lambda, a `run` block, a
   handler arm and a `defer` each start again without one: each is entered
   through [in_ctx] or clears it itself. *)
let in_loop = ref false

let in_ctx ctx ~set body =
  let saved =
    ctx.return_type, ctx.saw_return, ctx.row, ctx.resume_type, ctx.in_final_arm
  in
  let looping = !in_loop in
  in_loop := false;
  let restore () =
    in_loop := looping;
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
  (* What the call site collected into: a pack's tuple, or an array. *)
  | Ast.Ty_variadic ({ Ast.it = Ast.Ty_spread _; _ } as held) ->
    Types.ITuple [ infer_ty_of_annotation held ]
  | Ast.Ty_variadic element -> Types.iarray (infer_ty_of_annotation element)
  | Ast.Ty_spread inner ->
    let held = infer_ty_of_annotation inner in
    (match Types.repr held with
     | _ when Types.is_pack_param held -> ()
     | Types.IVar _ ->
       fail
         t.Ast.span
         "'%s' was not declared as a pack, so there is nothing to spread."
         (Printer.string_of_type_expr inner)
     | _ ->
       fail
         t.Ast.span
         "'%s' is a type, not a pack, so there is nothing to spread."
         (Printer.string_of_type_expr inner));
    Types.ISpread held
  | Ast.Ty_name name when primitive name <> None -> Option.get (primitive name)
  | Ast.Ty_tuple [] -> Types.IUnit
  | Ast.Ty_tuple items -> Types.ITuple (List.map infer_ty_of_annotation items)
  | Ast.Ty_record fields ->
    Types.IRecord
      (List.fold_right
         (fun (l, t) rest -> Types.FCons (l, infer_ty_of_annotation t, rest))
         fields
         Types.FEmpty)
  | Ast.Ty_app (name, args) -> named_type ~written:true t.Ast.span name (type_arguments name args)
  | Ast.Ty_row _ ->
    fail t.Ast.span "An effect row is an argument only where a type's parameter stands in one."
  | Ast.Ty_name other ->
    (match Hashtbl.find_opt ctx_type_params other with
     | Some var -> var
     | None -> named_type ~written:false t.Ast.span other [])
  (* The copy [Type_mono] makes has a concrete owner; this one may not. *)
  | Ast.Ty_assoc (owner, member) ->
    Types.project (infer_ty_of_annotation owner) member
  (* [type_params_of] reads it off before the rest become types. *)
  | Ast.Ty_bind (bound, _) -> fail t.Ast.span "'%s = ...' is only allowed in a bound." bound
  | Ast.Ty_fn (params, ret, row) ->
    Types.IFn
      ( List.map infer_ty_of_annotation params
      , infer_ty_of_annotation ret
      , row_of_labels ~span:t.Ast.span row )

(* The arguments written for a type or a trait, each read as a row where the
   parameter it is for stands in one. *)
and type_arguments owner (args : Ast.type_expr list) =
  let standing = Option.value ~default:[] (Hashtbl.find_opt ctx_row_standing owner) in
  List.mapi
    (fun i a ->
      if List.nth_opt standing i = Some true then row_argument owner a else infer_ty_of_annotation a)
    args

(* A supertrait as its parent wrote it: arguments in the parent's parameters and
   [self], and an `Output = Self` among them a binding rather than an argument. *)
and super_arguments ~self scope super (written : Ast.type_expr list) =
  let bindings, args =
    List.partition_map
      (fun (a : Ast.type_expr) ->
        match a.Ast.it with
        | Ast.Ty_bind (name, bound) -> Either.Left (name, bound)
        | _ -> Either.Right a)
      written
  in
  with_type_params (("Self", self) :: scope) (fun () ->
    ( type_arguments super args
    , List.map (fun (name, bound) -> name, infer_ty_of_annotation bound) bindings ))

(* The arguments [target] is reached at from [trait] at [args], through the
   supertraits: `File` at none reaches `Closer` at `IoError`. *)
and reached_at trait (args : Types.infer_ty list) target : Types.infer_ty list option =
  if String.equal trait target
  then Some args
  else (
    match Hashtbl.find_opt ctx_traits trait with
    | None -> None
    | Some (params, body) ->
      let scope = if List.length params = List.length args then List.combine params args else [] in
      List.find_map
        (fun (super, written) ->
          reached_at super (fst (super_arguments ~self:(Types.fresh ()) scope super written)) target)
        body.Ast.tb_super)

(* Where the parameter stands in a row: a written row, or a parameter of the
   enclosing function standing in one. *)
and row_argument owner (a : Ast.type_expr) =
  match a.Ast.it with
  | Ast.Ty_row labels -> Types.IRow (row_of_labels ~span:a.Ast.span labels)
  | Ast.Ty_name n when Hashtbl.mem ctx_row_params n -> Types.IRow (Hashtbl.find ctx_row_params n)
  | _ ->
    fail
      a.Ast.span
      "'%s' takes an effect row here, written as '<...>' or as a parameter standing in one."
      owner

(* A pack takes the arguments a use wrote past the parameters before it, so
   `Slot<>` is the empty one and `Slot<int, string>` holds two. Written as a
   pack already — `Slot<...Args>` — it is what it stands for. *)
and collect_pack name vars args =
  if not (Hashtbl.mem ctx_type_packs name)
  then args
  else (
    let fixed = List.length vars - 1 in
    let rec split n = function
      | rest when n = 0 -> [], rest
      | [] -> [], []
      | a :: rest ->
        let before, after = split (n - 1) rest in
        a :: before, after
    in
    let before, held = split fixed args in
    before
    @ [ (match held with
         | [ Types.ISpread inner ] -> inner
         | held -> Types.IPack held)
      ])

and named_type ?(written = true) span name args =
  if String.equal name Types.reflection_name && args = []
  then Types.ireflected
  else if String.equal name Types.span_name && args = []
  then Types.ispan
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
    | None -> !current.unknown (fun () -> fail span "Unknown type '%s'." name) Types.fresh
    | Some decl ->
      let vars = decl_params decl in
      let packed = Hashtbl.mem ctx_type_packs name && written in
      if (not packed) || List.length args < List.length vars - 1
      then
        if List.length vars <> List.length args
        then
          fail
            span
            "Type '%s' takes %d argument(s) but %d were given."
            name
            (List.length vars)
            (List.length args);
      let args = if packed then collect_pack name vars args else args in
      (match decl with
       | Opaque _ | Product _ -> Types.INamed (name, args)
       | Sum _ -> Types.ISum (name, args))

(* Each entry takes fresh arguments; a use is what settles them. *)
and row_of_labels ~span entries =
  let tail =
    match List.filter_map (fun (l, _) -> Hashtbl.find_opt ctx_row_params l) entries with
    | [] -> Types.REmpty
    | [ row ] -> row
    | _ -> Types.error "A row may be open in one variable, not several."
  in
  List.fold_right
    (fun (label, written) rest ->
      if Hashtbl.mem ctx_row_params label
      then rest
      else (
        let declared =
          List.length (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params label))
        in
        (* Unwritten arguments are left to inference, each at its own variable,
           so `<Yield>` is every instantiation and `<Yield<int>>` is one. *)
        if not (Hashtbl.mem ctx_effect_params label)
        then
          !current.unknown
            (fun () ->
              match declarations_of ctx_effect_params ~except:label label with
              | [] -> fail span "Unknown effect '%s'." label
              | where ->
                fail
                  span
                  "'%s' is not an effect in scope here. One is declared in %s: import it from there."
                  label
                  (String.concat " and in " where))
            ignore;
        let args =
          match written with
          | [] -> List.init declared (fun _ -> Types.fresh ())
          | written when List.length written = declared ->
            List.map infer_ty_of_annotation written
          (* Nothing declared it, which says more than a count of arguments. *)
          | written when not (Hashtbl.mem ctx_effect_params label) ->
            List.map (fun _ -> Types.fresh ()) written
          | written ->
            fail
              span
              "Effect '%s' takes %d type argument(s) but %d were given."
              label
              declared
              (List.length written)
        in
        Types.RCons (label, args, rest)))
    entries
    tail

(* What is registered here is undone before returning; the caller installs the
   whole list. *)
(* Where a method a trait reaches was declared, and that trait's arguments at
   this use: a supertrait's are written in its parent's parameters, so they are
   read with those bound. *)
let rec declaring_trait trait (args : Types.infer_ty list) name
  : Types.infer_ty Ast.dispatch option
  =
  match Hashtbl.find_opt ctx_traits trait with
  | None -> None
  | Some (params, body) ->
    if List.exists (fun (m : Ast.method_sig) -> String.equal m.Ast.ms_name name) body.Ast.tb_methods
    then Some { Ast.dp_trait = trait; dp_targets = args; dp_instance = None }
    else (
      let scope =
        if List.length params = List.length args then List.combine params args else []
      in
      List.find_map
        (fun (super, written) ->
          let super_args = fst (super_arguments ~self:(Types.fresh ()) scope super written) in
          declaring_trait super super_args name)
        body.Ast.tb_super)

let coerced (expected : Types.infer_ty) (e : checked_expr) : checked_expr =
  let span = e.Ast.span in
  match Types.repr expected, Types.infer_type_name (Types.repr e.Ast.ann) with
  (* An object of a trait is already an object of each of its supertraits: its
     table holds their methods too. No slots, which `Resolve` reads as that. *)
  | Types.INamed (trait, _), Some concrete
    when Hashtbl.mem ctx_traits trait
         && Hashtbl.mem ctx_traits concrete
         && (not (String.equal trait concrete))
         && List.mem trait (trait_closure concrete) ->
    Ast.annotated span expected (`Coerce (e, trait, []))
  | Types.INamed (trait, _), Some concrete
    when Hashtbl.mem ctx_traits trait && not (String.equal trait concrete) ->
    let reachable = trait_closure trait in
    if not (List.exists (fun t -> Hashtbl.mem ctx_impls (concrete, t)) reachable)
    then fail span "'%s' does not implement '%s'." concrete trait;
    (* A supertrait's methods are reachable through the value, so the table
       owes a slot for each of them too. *)
    let declared =
      List.fold_left
        (fun acc t ->
          match Hashtbl.find_opt ctx_traits t with
          | Some (_, body) ->
            acc
            @ List.filter
                (fun (m : Ast.method_sig) ->
                  not
                    (List.exists
                       (fun (seen : Ast.method_sig) ->
                         String.equal seen.Ast.ms_name m.Ast.ms_name)
                       acc))
                body.Ast.tb_methods
          | None -> acc)
        []
        (trait_closure trait)
    in
    (* A vtable slot is reached through the value, so a method that takes no
       receiver has no slot and the trait has no object. *)
    List.iter
      (fun (m : Ast.method_sig) ->
        match m.Ast.ms_params with
        | { Ast.name = "self"; _ } :: _ -> ()
        | _ ->
          fail
            span
            "'%s' cannot be used as a type: '%s' takes no receiver."
            trait
            m.Ast.ms_name)
      declared;
    let trait_args =
      match Types.repr expected with
      | Types.INamed (_, args) -> args
      | _ -> []
    in
    let slots =
      List.map
        (fun (m : Ast.method_sig) ->
          let name = m.Ast.ms_name in
          ( name
          , Option.value
              (declaring_trait trait trait_args name)
              ~default:{ Ast.dp_trait = trait; dp_targets = trait_args; dp_instance = None } ))
        declared
    in
    Ast.annotated span expected (`Coerce (e, trait, slots))
  | _ ->
    unify_at span expected e.Ast.ann;
    e

(* Unification would reach the closed row from the call's side and report the
   argument's effect as unhandled there, however many handlers enclose it. *)
let coerce_params params (args : checked_expr list) =
  let params = Types.expand params in
  if List.length params <> List.length args
  then args
  else List.map2 (fun p a -> if is_trait_type p then coerced p a else a) params args

(* Put back however the body leaves: [check] carries on after an error, and a
   field pointing at the failed function would follow it. *)
let type_params_of span (static_params : Ast.static_param list) =
  let touched = List.map (fun (p : Ast.static_param) ->
    ( p.Ast.sp_name
    , Hashtbl.find_opt ctx_type_params p.Ast.sp_name
    , Hashtbl.find_opt ctx_row_params p.Ast.sp_name )) static_params
  in
  let restore () =
    List.iter
      (fun (name, previous, previous_row) ->
        (match previous with
         | Some var -> Hashtbl.replace ctx_type_params name var
         | None -> Hashtbl.remove ctx_type_params name);
        match previous_row with
        | Some row -> Hashtbl.replace ctx_row_params name row
        | None -> Hashtbl.remove ctx_row_params name)
      touched
  in
  Fun.protect ~finally:restore (fun () ->
    (* A bound may name the parameter it constrains. *)
    let declared =
      List.map
        (fun (p : Ast.static_param) ->
          match p.Ast.sp_ty with
          | None | Some { Ast.it = Ast.Ty_name _ | Ast.Ty_app _; _ } ->
            let var = Types.fresh () in
            Types.declare_param var;
            if p.Ast.sp_pack then Types.declare_pack var;
            Types.name_param p.Ast.sp_name var;
            Hashtbl.replace ctx_type_params p.Ast.sp_name var;
            (* So a sibling's bound may pass it where a row goes:
               `S: Source<int, E>, E`. *)
            Hashtbl.replace ctx_row_params p.Ast.sp_name (row_of_param var);
            p, var
          | Some _ ->
            fail span "Static value parameter '%s' is not supported yet." p.Ast.sp_name)
        static_params
    in
    List.iter
      (fun ((p : Ast.static_param), var) ->
        match p.Ast.sp_ty with
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
          let bd_args = type_arguments trait args
          and bd_bindings = List.map (fun (m, b) -> m, infer_ty_of_annotation b) bindings in
          Types.constrain
            var
            (Types.Bound [ { Types.bd_trait = trait; bd_args; bd_bindings } ])
        | Some _ ->
          fail span "Static value parameter '%s' is not supported yet." p.Ast.sp_name)
      declared;
    List.map (fun ((p : Ast.static_param), var) -> p.Ast.sp_name, var) declared)

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
  | `Compound_index (_, a, b, c) ->
    assigned_in_expr c (assigned_in_expr b (assigned_in_expr a acc))
  | `Compound_field (_, r, _, v) -> assigned_in_expr v (assigned_in_expr r acc)
  | `Unop (_, a) -> assigned_in_expr a acc
  | `Binop (_, a, b) | `And (a, b) | `Or (a, b) ->
    assigned_in_expr b (assigned_in_expr a acc)
  | `Call (callee, args) ->
    List.fold_left (fun acc a -> assigned_in_expr a acc) (assigned_in_expr callee acc) args
  | `Typeof e -> assigned_in_expr e acc
  | `Method_call (receiver, _, _, args, _) | `Static_call (receiver, _, args) ->
    List.fold_left
      (fun acc a -> assigned_in_expr a acc)
      (assigned_in_expr receiver acc)
      args
  | `Index (a, b) -> assigned_in_expr b (assigned_in_expr a acc)
  | `Index_assign (a, b, c) ->
    assigned_in_expr c (assigned_in_expr b (assigned_in_expr a acc))
  | `Collection_lit items | `Tuple items ->
    List.fold_left (fun acc i -> assigned_in_expr i acc) acc items
  | `Tuple_get (t, _) | `Field (t, _) | `Spread t -> assigned_in_expr t acc
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
  | `Match_expr (scrutinee, cases) ->
    List.fold_left
      (fun acc (_, (b : (Ast.desugared_expr, Ast.desugared_stmt) Ast.valued_block)) ->
        let acc = List.fold_left (fun acc st -> assigned_in_stmt st acc) acc b.Ast.vb_stmts in
        Option.fold ~none:acc ~some:(fun v -> assigned_in_expr v acc) b.Ast.vb_value)
      (assigned_in_expr scrutinee acc)
      cases

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
  | `For_in (_, iterable, body) -> assigned_in_stmt body (assigned_in_expr iterable acc)
  | `Return e -> opt assigned_in_expr e acc
  | `Break | `Continue -> acc
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
  | `Discontinue -> acc
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
  | `While (_, body) | `For_in (_, _, body) | `Defer body -> resumes body
  | `Match (_, cases) -> List.exists (fun (_, body) -> List.exists resumes body) cases
  | _ -> false

let assigned_names body =
  List.fold_left (fun acc s -> assigned_in_stmt s acc) [] body

(* A method's own name is reached only through a call on a receiver, so it is
   kept apart from the names a bare identifier reaches. Otherwise a local
   sharing a method's name -- `var close` inside `iterator` -- joins the
   function to every impl with that method, and inside one component a generic
   function is not generic yet: the first caller there fixes its row for every
   caller outside. *)
type dependency_name =
  | Value of string
  | Member of string

(* A method call names every method of that name, since which impl answers is
   not known yet. A local is tracked by scope: the entry file's top-level names
   are not mangled, so a loop variable `s` in another module would otherwise
   tie that module's functions to the entry's `var s`, and through the order
   top-level statements keep, to every statement before it. *)
let names_used (s : Ast.desugared_stmt) =
  let module S = Set.Make (String) in
  let used = Hashtbl.create 16 in
  let bound = ref S.empty in
  let note name = Hashtbl.replace used name () in
  let value name = if not (S.mem name !bound) then note (Value name) in
  let bind names = bound := List.fold_left (Fun.flip S.add) !bound names in
  let scoped f =
    let saved = !bound in
    Fun.protect ~finally:(fun () -> bound := saved) f
  in
  let declared_fns body =
    List.filter_map
      (fun (s : Ast.desugared_stmt) ->
        match s.Ast.it with
        | `Fn (name, _, _, _) -> Some name
        | _ -> None)
      body
  in
  let param_names = List.map (fun (p : Ast.param) -> p.Ast.name) in
  let rec expr (e : Ast.desugared_expr) =
    (match e.Ast.it with
     | `Var name | `Assign (name, _) | `Compound (_, name, _) | `New_call (name, _, _) -> value name
     | `Method_call (_, name, as_function, _, _) ->
       note (Member name);
       value as_function
     | _ -> ());
    match e.Ast.it with
    | `Lambda (ps, _, body) -> scoped (fun () -> bind (param_names ps); block body)
    | `Run_expr (body, handlers, clause) ->
      valued body;
      List.iter handler handlers;
      Option.iter
        (fun (c : (_, _) Ast.ret_clause) ->
          scoped (fun () -> bind [ c.Ast.rc_param ]; valued c.Ast.rc_body))
        clause
    | `Match_expr (scrutinee, cases) ->
      expr scrutinee;
      List.iter (fun (p, b) -> scoped (fun () -> bind (Ast.pattern_names p); valued b)) cases
    | _ ->
      let (_ : Ast.desugared_expr_kind) =
        match e.Ast.it with
        | `Lambda _ | `Run_expr _ | `Match_expr _ -> e.Ast.it
        | #Ast.lit as l -> l
        | #Ast.vars as v -> (Ast.map_vars (fun e -> expr e; e) v :> Ast.desugared_expr_kind)
        | #Ast.ops as o -> (Ast.map_ops (fun e -> expr e; e) o :> Ast.desugared_expr_kind)
        | #Ast.logic as l -> (Ast.map_logic (fun e -> expr e; e) l :> Ast.desugared_expr_kind)
        | #Ast.compound as c -> (Ast.map_compound (fun e -> expr e; e) c :> Ast.desugared_expr_kind)
        | #Ast.indexing as i -> (Ast.map_indexing (fun e -> expr e; e) i :> Ast.desugared_expr_kind)
        | #Ast.tuple as t -> (Ast.map_tuple (fun e -> expr e; e) t :> Ast.desugared_expr_kind)
        | #Ast.spread as x -> (Ast.map_spread (fun e -> expr e; e) x :> Ast.desugared_expr_kind)
        | #Ast.record as r -> (Ast.map_record (fun e -> expr e; e) r :> Ast.desugared_expr_kind)
        | #Ast.nominal as n -> (Ast.map_nominal (fun e -> expr e; e) n :> Ast.desugared_expr_kind)
        | #Ast.collection as c -> (Ast.map_collection (fun e -> expr e; e) c :> Ast.desugared_expr_kind)
        | #Ast.static_call as c ->
          (Ast.map_static_call (fun e -> expr e; e) c :> Ast.desugared_expr_kind)
        | #Ast.method_call as m ->
          (Ast.map_method_call (fun e -> expr e; e) m :> Ast.desugared_expr_kind)
        | #Ast.reflect as r -> (Ast.map_reflect (fun e -> expr e; e) r :> Ast.desugared_expr_kind)
      in
      ()
  and valued (b : (Ast.desugared_expr, Ast.desugared_stmt) Ast.valued_block) =
    scoped (fun () ->
      bind (declared_fns b.Ast.vb_stmts);
      List.iter stmt b.Ast.vb_stmts;
      Option.iter expr b.Ast.vb_value)
  and handler (h : Ast.desugared_stmt Ast.handler) =
    List.iter
      (fun (a : Ast.desugared_stmt Ast.arm) -> scoped (fun () -> bind a.Ast.arm_params; block a.Ast.arm_body))
      h.Ast.arms
  (* A function declared in a block is in scope for all of it. *)
  and block body =
    bind (declared_fns body);
    List.iter stmt body
  and nested (s : Ast.desugared_stmt) = scoped (fun () -> stmt s)
  and stmt (s : Ast.desugared_stmt) =
    match s.Ast.it with
    | `Expr e -> expr e
    | `Var_decl (name, _, init) ->
      Option.iter expr init;
      bind [ name ]
    | `Var_tuple (names, init) ->
      expr init;
      bind names
    | `Block body -> scoped (fun () -> block body)
    | `If (c, t, e) ->
      expr c;
      nested t;
      Option.iter nested e
    | `While (c, body) ->
      expr c;
      nested body
    | `Fn (name, params, _, body) ->
      bind [ name ];
      scoped (fun () -> bind (param_names params); block body)
    | `Return e -> Option.iter expr e
    | `Break | `Continue -> ()
    | `Defer inner -> nested inner
    (* What the checker lowers it to calls these, and an order that misses
       one checks the loop before the method it reaches. *)
    | `For_in (names, iterable, body) ->
      List.iter (fun name -> note (Member name)) [ "len"; "next"; "close" ];
      expr iterable;
      scoped (fun () -> bind names; stmt body)
    | `Match (scrutinee, cases) ->
      expr scrutinee;
      List.iter (fun (p, body) -> scoped (fun () -> bind (Ast.pattern_names p); block body)) cases
    | `Run (body, handlers) ->
      scoped (fun () -> block body);
      List.iter handler handlers
    | `Resume e -> Option.iter expr e
    | `Discontinue | `Effect_decl _ -> ()
    | #Ast.type_defs -> ()
    | `Trait_decl _ -> ()
    | `Impl_decl (_, _, _, impl) ->
      List.iter
        (fun (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
          scoped (fun () -> bind (param_names m.Ast.md_params); block m.Ast.md_body))
        impl.Ast.ib_methods
  in
  stmt s;
  Hashtbl.fold (fun name () acc -> name :: acc) used []

let names_declared (s : Ast.desugared_stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) | `Var_decl (name, _, _) -> [ Value name ]
  | `Var_tuple (names, _) -> List.map (fun name -> Value name) names
  | `Impl_decl (trait, type_name, _, impl) ->
    List.concat_map
      (fun (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
        [ Member m.Ast.md_name; Value (Ast.impl_method_name trait type_name m.Ast.md_name) ])
      impl.Ast.ib_methods
  | _ -> []

(* A block's statements, by index, in the groups they are checked in: the
   strongly connected components of what each uses and declares, dependencies
   first and otherwise in source order. A function is generalized only once
   what it calls has been: a call to one still carrying [hoist]'s binding
   unifies with that binding's row, which then stays free in the environment
   and is fixed by whatever calls the caller -- at the top level, to the row
   `__root` hands a statement. Statements that are not declarations keep their
   source order among themselves, so a shadowing or an assignment is never
   checked out of turn. Effects come first, whatever their order: the walk
   emits a declaration where it reaches it, which is after a function in
   another module that handles the effect, and a handler needs the effect's
   operations. *)
let dependency_order (body : Ast.desugared_stmt list) : int list list =
  let stmts = Array.of_list body in
  let n = Array.length stmts in
  let declared_by = Hashtbl.create 64 in
  Array.iteri
    (fun i s -> List.iter (fun name -> Hashtbl.add declared_by name i) (names_declared s))
    stmts;
  let deps = Array.make n [] in
  let previous = ref None in
  Array.iteri
    (fun i (s : Ast.desugared_stmt) ->
      let chained =
        match s.Ast.it with
        | `Fn _ | `Impl_decl _ | `Trait_decl _ | `Type_decl _ | `Effect_decl _ -> []
        | _ ->
          let before = Option.to_list !previous in
          previous := Some i;
          before
      in
      deps.(i)
      <- List.sort_uniq
           compare
           (List.filter
              (fun j -> j <> i)
              (chained @ List.concat_map (Hashtbl.find_all declared_by) (names_used s))))
    stmts;
  let index = Array.make n (-1)
  and low = Array.make n 0
  and on_stack = Array.make n false in
  let counter = ref 0
  and stack = ref []
  and groups = ref [] in
  let rec connect v =
    index.(v) <- !counter;
    low.(v) <- !counter;
    incr counter;
    stack := v :: !stack;
    on_stack.(v) <- true;
    List.iter
      (fun w ->
        if index.(w) < 0
        then (
          connect w;
          low.(v) <- min low.(v) low.(w))
        else if on_stack.(w)
        then low.(v) <- min low.(v) index.(w))
      deps.(v);
    if low.(v) = index.(v)
    then (
      let rec pop group =
        match !stack with
        | w :: rest ->
          stack := rest;
          on_stack.(w) <- false;
          if w = v then w :: group else pop (w :: group)
        | [] -> group
      in
      groups := List.sort compare (pop []) :: !groups)
  in
  for v = 0 to n - 1 do
    if index.(v) < 0 then connect v
  done;
  let effects, rest =
    List.partition
      (function
        | [ i ] -> (match stmts.(i).Ast.it with `Effect_decl _ -> true | _ -> false)
        | _ -> false)
      (List.rev !groups)
  in
  effects @ rest

let field_of (target : checked_expr) label =
  match Types.repr target.Ast.ann with
  | Types.INamed (name, args) ->
    let fields = Types.fields_of name args in
    let rec find f =
      match Types.repr_fields f with
      | Types.FCons (l, ty, _) when String.equal l label -> Some ty
      | Types.FCons (_, _, rest) -> find rest
      | _ -> None
    in
    (match find fields with
     | Some ty -> ty
     | None ->
       !current.unknown
         (fun () -> fail target.Ast.span "Type '%s' has no field '%s'." name label)
         Types.fresh)
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
    (* The target's own type, not [of_ty] of it: that gives an open row a fresh
       tail, and the element stops sharing the row variable its container was
       declared with. *)
    (match Types.container_element target.Ast.ann with
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

let constructs env ctx name =
  lookup env name = None
  && (String.equal name Types.array_name || Registry.constructor ctx.registry name <> None)

let declared_variant env ty variant =
  match lookup env ty, Hashtbl.find_opt ctx_types ty with
  | None, Some (Sum (_, variants)) -> List.assoc_opt variant variants
  | _ -> None

(* An effect's argument is a type, so a parameter standing in a row would be
   matched by name where the effect is declared and carried by nothing where it
   is used: a handler's arm and a call site would each get a row of their own. *)
let rec row_param_in names (t : Ast.type_expr) =
  let within = List.find_map (row_param_in names) in
  match t.Ast.it with
  | Ast.Ty_fn (params, ret, row) ->
    (match List.find_opt (fun (label, _) -> List.mem label names) row with
     | Some (label, _) -> Some (label, t.Ast.span)
     | None -> within ((ret :: params) @ List.concat_map snd row))
  | Ast.Ty_row row ->
    (match List.find_opt (fun (label, _) -> List.mem label names) row with
     | Some (label, _) -> Some (label, t.Ast.span)
     | None -> within (List.concat_map snd row))
  | Ast.Ty_app (_, args) | Ast.Ty_tuple args -> within args
  | Ast.Ty_record fields -> within (List.map snd fields)
  | Ast.Ty_variadic inner | Ast.Ty_spread inner | Ast.Ty_assoc (inner, _) | Ast.Ty_bind (_, inner) ->
    row_param_in names inner
  | Ast.Ty_name _ -> None

let rec infer_expr env ctx (e : Ast.desugared_expr) : checked_expr =
  located ctx e (fun () -> infer_expr_impl env ctx e)

and located ctx (e : Ast.desugared_expr) check : checked_expr =
  let checked =
    try check () with
    | Types.Type_error message -> raise (Located { span = e.Ast.span; message })
  in
  note_effect_sites e.Ast.span ctx.row;
  checked

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
     | None ->
       (* A type with no fields has one value, and its name is that value. *)
       (match Hashtbl.find_opt ctx_types name with
        | Some (Product ([], declared)) when Types.repr_fields declared = Types.FEmpty ->
          node (Types.INamed (name, [])) (`New (name, []))
        | _ ->
          !current.unknown
            (fun () -> fail span "Undefined variable '%s'." name)
            (fun () -> node (unknown_ty ()) (`Var name))))
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
  | `Match_expr (scrutinee, cases) -> infer_match_expr env ctx span (Types.fresh ()) scrutinee cases
  | `Assign (name, v) ->
    (match lookup env name with
     | None ->
       !current.unknown
         (fun () -> fail span "Undefined variable '%s'." name)
         (fun () -> node Types.IUnit (`Assign (name, infer_expr env ctx v)))
     | Some scheme ->
       let target = Types.instantiate scheme in
       let value = infer_expr env ctx v in
       let value = if is_trait_type target then coerced target value else value in
       Types.unify target value.Ast.ann;
       node target (`Assign (name, value)))
  | `Unop (((Ast.Neg | Ast.Bit_not) as op), a) ->
    let a = infer_expr env ctx a in
    let trait, what = if op = Ast.Neg then Core.neg, "negate" else Core.bit_not, "apply '~' to" in
    (match Types.concrete a.Ast.ann with
     | Some operand ->
       (match Registry.find_unary ctx.registry op operand with
        | Some entry -> node (Types.of_ty (Registry.result_of entry operand)) (`Unop (op, a))
        | None ->
          fail
            span
            "Cannot %s %s: it does not implement %s."
            what
            (Types.string_of_ty operand)
            (if op = Ast.Neg then "Neg" else "BitNot"))
     | None ->
       Types.constrain
         a.Ast.ann
         (Types.Bound
            [ { Types.bd_trait = trait
              ; bd_args = []
              ; bd_bindings = [ "Output", a.Ast.ann ]
              } ]);
       node a.Ast.ann (`Unop (op, a)))
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
     | None ->
       !current.unknown
         (fun () -> fail span "Undefined variable '%s'." name)
         (fun () -> node Types.IUnit (`Compound (op, name, infer_expr env ctx v)))
     | Some scheme ->
       let target = Types.instantiate scheme in
       let v = infer_expr env ctx v in
       let result = binop_result ctx.registry op target v.Ast.ann in
       Types.unify target result;
       let it : checked_expr_kind = `Compound (op, name, v) in
       node target it)
  | `Compound_index (op, target, index, v) ->
    let target = infer_expr env ctx target in
    if Types.concrete target.Ast.ann = Some Types.Str
    then fail target.Ast.span "A string cannot be assigned into.";
    let index = infer_expr env ctx index in
    let current =
      match declared_index env ctx.registry target index with
      | Some result -> result
      | None ->
        unify_at index.Ast.span Types.IInt index.Ast.ann;
        element_of ctx.registry target
    in
    let v = infer_expr env ctx v in
    unify_at span current (binop_result ctx.registry op current v.Ast.ann);
    node current (`Compound_index (op, target, index, v))
  | `Compound_field (op, target, label, v) ->
    let target = infer_expr env ctx target in
    let current = field_of target label in
    let v = infer_expr env ctx v in
    unify_at span current (binop_result ctx.registry op current v.Ast.ann);
    node current (`Compound_field (op, target, label, v))
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
  (* `Array<int>(3, 0)` reads as a call until `Array` turns out to be a type
     with a constructor rather than a function. *)
  | `Call ({ Ast.it = `Var name; _ }, args) when constructs env ctx name ->
    infer_expr env ctx { e with Ast.it = `New_call (name, [], args) }
  | `Static_call ({ Ast.it = `Var name; _ }, static_args, args) when constructs env ctx name ->
    let type_args =
      List.map
        (function
          | Ast.St_type t -> t
          | Ast.St_value _ -> fail span "'%s' takes types here, not values." name)
        static_args
    in
    infer_expr env ctx { e with Ast.it = `New_call (name, type_args, args) }
  | `Call (callee, args) ->
    let callee_node = infer_expr env ctx callee in
    root_argument
    := (match callee.Ast.it, !top_row with
        | `Var name, Some top -> Ast.is_root name && top == ctx.row
        | _ -> false);
    let args = name_implicit_params callee_node.Ast.ann args in
    (* A literal is unified with itself before a coercion could reach inside
       it, so an argument whose parameter mentions a trait is checked rather
       than inferred. *)
    let declared_params =
      match callee.Ast.it with
      | `Var name -> Option.value ~default:[] (Hashtbl.find_opt ctx_fn_params name)
      | _ -> []
    in
    let expected_params =
      match Types.repr callee_node.Ast.ann with
      | Types.IFn (params, _, _) ->
        let params = Types.expand params in
        if List.length params = List.length args then Some params else None
      | _ -> None
    in
    let args =
      match expected_params with
      | Some params ->
        (* A lambda's parameters are typed by what the arguments before it
           settled, so `using(f) { x -> x.close() }` knows what `x` is. A
           mismatch there is left for the call's own unification to report. *)
        let settle_before (checked : checked_expr list) =
          List.iteri
            (fun i (c : checked_expr) ->
              try Types.unify (List.nth params i) c.Ast.ann with
              | Types.Type_error _ -> ())
            checked
        in
        List.rev
          (snd
             (List.fold_left2
                (fun (i, checked) param (a : Ast.desugared_expr) ->
                  let c =
                    match a.Ast.it with
                    | `Spread _ -> argument env ctx a
                    | _ when mentions_trait param -> check_against env ctx param a
                    | _ ->
                      (match a.Ast.it with
                       | `Lambda _ ->
                         settle_before (List.rev checked);
                         expected_lambda := Some param
                       | _ -> ());
                      let c = argument env ctx a in
                      not_a_bound ~declared:declared_params a param c;
                      not_pure a param c;
                      c
                  in
                  i + 1, c :: checked)
                (0, [])
                params
                args))
      | None -> List.map (argument env ctx) args
    in
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
       let ret = if is_unknown callee_node.Ast.ann then unknown_ty () else Types.fresh () in
       let row = Types.fresh_row () in
       Types.unify
         callee_node.Ast.ann
         (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) args, ret, row));
       let name, scheme =
         match callee.Ast.it with
         | `Var name -> Some name, lookup env name
         | _ -> None, None
       in
       admits_row ?name scheme row ctx.row;
       node ret (`Call (callee_node, args)))
  (* `f.to<bool>()`. The receiver says which type, and the written targets say
     which of that type's impls, which is the one thing a call by name alone
     cannot. *)
  | `Static_call ({ Ast.it = `Field (target, method_); _ }, static_args, args) ->
    let receiver = infer_expr env ctx target in
    let owner =
      match Types.infer_type_name receiver.Ast.ann with
      | Some owner -> owner
      | None ->
        fail span "Cannot call '%s': the receiver's type is not known here." method_
    in
    let targets =
      List.map
        (function
          | Ast.St_type t -> Ast.written_type t
          | Ast.St_value _ ->
            fail span "A target of '%s' is not a type." method_)
        static_args
    in
    let entry =
      match Registry.entry_with_targets ctx.registry owner method_ targets with
      | Some entry -> entry
      | None ->
        (match Registry.method_entries ctx.registry owner method_ with
         | [] -> fail span "Type '%s' has no method '%s'." owner method_
         | several ->
           fail
             span
             "'%s' has no '%s' for <%s>. It has %s."
             owner
             method_
             (String.concat ", " targets)
             (listed (List.map (Registry.describe_entry owner) several)))
    in
    let scheme =
      match lookup env entry.Registry.mangled with
      | Some scheme -> scheme
      | None -> fail span "Type '%s' has no method '%s'." owner method_
    in
    let fn = Types.instantiate scheme in
    let args = List.map (infer_expr env ctx) args in
    let all =
      if Hashtbl.mem ctx_associated (owner, method_) then args else receiver :: args
    in
    let ret = Types.fresh () in
    let row = Types.fresh_row () in
    Types.unify
      fn
      (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) all, ret, row));
    admits_row ~name:entry.Registry.mangled (Some scheme) row ctx.row;
    node ret (`Call (Ast.annotated span fn (`Var entry.Registry.mangled), all))
  | `Static_call (callee, static_args, args) ->
    let name =
      match callee.Ast.it with
      | `Var name -> name
      | _ -> fail span "Only a named function takes static arguments."
    in
    let scheme =
      match lookup env name with
      | Some scheme -> scheme
      | None -> fail span "Undefined variable '%s'." name
    in
    let declared = Option.value ~default:[] (Hashtbl.find_opt ctx_fn_params name) in
    if List.length declared <> List.length static_args
    then
      fail
        span
        "'%s' takes %d static argument(s) but %d were given."
        name
        (List.length declared)
        (List.length static_args);
    let type_args =
      List.map
        (function
          | Ast.St_type t -> t
          | Ast.St_value _ ->
            fail span "A static argument to '%s' is not known at compile time." name)
        static_args
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
    admits_row ~name (lookup env name) row ctx.row;
    node ret (`Call (callee_node, args))
  (* `Option.Some(x)` and `Option.None` read as a method call and a field until
     `Option` turns out to be a type with that variant. *)
  | `Method_call ({ Ast.it = `Var ty; _ }, variant, _, args, _) when declared_variant env ty variant <> None ->
    let declared = Option.get (declared_variant env ty variant) in
    if args = [] && Ast.payload_fields declared.vd_payload = []
    then fail span "'%s.%s' carries nothing, so it is written without parentheses." ty variant;
    infer_expr env ctx { e with Ast.it = `New_variant (ty, variant, Ast.P_tuple args) }
  | `Field ({ Ast.it = `Var ty; _ }, variant) when declared_variant env ty variant <> None ->
    infer_expr env ctx { e with Ast.it = `New_variant (ty, variant, Ast.P_none) }
  | `Field ({ Ast.it = `Var ty; _ }, variant)
    when lookup env ty = None
         && (match Hashtbl.find_opt ctx_types ty with
             | Some (Sum _) -> true
             | _ -> false) ->
    fail span "Type '%s' has no variant '%s'." ty variant
  | `Method_call (receiver, name, as_function, args, in_scope) ->
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
    (* The method's own parameters, so a lambda among the arguments is sized and
       typed before its body is read rather than after. *)
    (* An inherent method answers anywhere; a trait's only where the file
       that wrote the call can see the trait. *)
    let in_reach owner =
      List.filter
        (fun (e : Registry.method_entry) ->
          match e.Registry.trait, in_scope with
          | None, _ | _, None -> true
          | Some trait, Some names -> List.mem trait names)
        (Registry.method_entries ctx.registry owner name)
    in
    let entry_in_reach owner =
      match in_reach owner with
      | e :: _ -> e.Registry.mangled
      | [] -> Registry.entry_for_method ctx.registry owner name
    in
    let expected =
      match found with
      | Ok (Owner owner) when not (Hashtbl.mem ctx_associated (owner, name)) ->
        (match lookup env (entry_in_reach owner) with
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
    let args =
      List.mapi
        (fun i (a : Ast.desugared_expr) ->
          (match a.Ast.it, List.nth_opt expected i with
           | `Lambda _, Some param when List.length expected = List.length args ->
             expected_lambda := Some param
           | _ -> ());
          argument env ctx a)
        (name_implicit_params_from expected args)
    in
    (* The receiver's own field comes first: a record of functions is how an
       `Iter` or a hand-made table is written, and a local that happens to share
       the field's name says nothing about the receiver. *)
    let via_field () =
      let field =
        match Types.repr receiver.Ast.ann with
        | Types.INamed (named, args) ->
          let rec find f =
            match Types.repr_fields f with
            | Types.FCons (l, ty, _) when String.equal l name -> Some ty
            | Types.FCons (_, _, rest) -> find rest
            | _ -> None
          in
          find (Types.fields_of named args)
        | _ -> None
      in
      match Option.map (fun ty -> ty, Types.repr ty) field with
      | Some (ty, (Types.IFn _ | Types.IVar { contents = Types.Unbound _ })) ->
        let ret = Types.fresh () in
        let row = Types.fresh_row () in
        unify_at
          span
          ty
          (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) args, ret, row));
        (* As any call: a written row is what the call adds, within whatever
           more its context holds. *)
        admits_row None row ctx.row;
        Some (node ret (`Call (Ast.annotated span ty (`Field (receiver, name)), args)))
      | _ -> None
    in
    let anything () =
      node (unknown_ty ()) (`Call ({ Ast.it = `Var as_function; span; ann = Types.fresh () }, receiver :: args))
    in
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
         | Types.IFn (params, _, _)
           when List.length (Types.expand params) <> List.length (Types.expand passed) ->
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
        admits_row ~name:as_function (Some scheme) row ctx.row;
        Some
          (node ret (`Call ({ Ast.it = `Var as_function; span; ann = fn }, receiver :: args)))
    in
    (match via_field () with
    | Some call -> call
    | None ->
    (match found with
     | Error e ->
       (match via_function () with
        | Some call -> call
        | None ->
          !current.unknown
            (fun () -> raise e)
            (fun () -> if is_unknown receiver.Ast.ann then anything () else raise e))
     | Ok found ->
       (match found with
     (* The trait declares the signature; which type supplies the body is
        settled later. *)
     | Via_trait trait ->
       (* A supertrait's method is declared with that trait's parameters, and its
          arguments are written in the parent's, so both are read from the bound
          the receiver carries rather than from the trait reached through. *)
       let dispatch =
         match Types.repr receiver.Ast.ann with
         | Types.INamed (named, args) -> declaring_trait named args name
         | Types.IVar { contents = Types.Unbound (_, Types.Bound bounds) } ->
           List.find_map
             (fun (b : Types.bound) ->
               declaring_trait b.Types.bd_trait b.Types.bd_args name)
             bounds
         | _ -> None
       in
       let declaring = Option.fold ~none:trait ~some:(fun d -> d.Ast.dp_trait) dispatch in
       let bound_args = Option.fold ~none:[] ~some:(fun d -> d.Ast.dp_targets) dispatch in
       let trait_params, trait_body =
         Option.value
           (Hashtbl.find_opt ctx_traits declaring)
           ~default:([], { Ast.tb_super = []; tb_assoc = []; tb_methods = [] })
       in
       let trait_methods =
         List.concat_map
           (fun t ->
             match Hashtbl.find_opt ctx_traits t with
             | Some (_, body) -> body.Ast.tb_methods
             | None -> [])
           (trait_closure declaring)
       in
       (* Read as a variable until the receiver's own impl is reached. *)
       let projected name = Types.project receiver.Ast.ann name in
       let in_scope =
         ("Self", receiver.Ast.ann)
         :: List.map (fun name -> name, projected name) (Ast.assoc_names trait_body.Ast.tb_assoc)
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
          if List.length rest <> spread_arity args
          then
            fail
              span
              "Method '%s' takes %d argument(s) but %d were passed."
              name
              (List.length rest)
              (List.length args);
          let dynamic =
            match Types.repr receiver.Ast.ann with
            | Types.INamed (named, _) -> String.equal named trait
            | _ -> false
          in
          let fn =
            Types.IFn
              ( receiver.Ast.ann
                :: List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) rest
              , annotated_or_fresh m.Ast.ms_signature.Ast.ret
              , (match m.Ast.ms_signature.Ast.row with
                 | Some labels -> row_of_labels ~span labels
                 (* A table's slot holds an impl compiled for the trait's
                    signature, so a row the trait leaves unwritten is empty: a
                    call made where more is handled must not pass that too. *)
                 | None when dynamic -> Types.REmpty
                 | None -> Types.fresh_row ()) )
          in
          Hashtbl.replace
            dynamic_rows
            (declaring, name)
            (match m.Ast.ms_signature.Ast.row with
             | Some labels -> row_of_labels ~span labels
             | None -> Types.REmpty);
          let ret = Types.fresh () in
          let row = Types.fresh_row () in
          (* The written row is what the call passes evidence for, and what it
             adds to its context -- not all its context may hold, which a closed
             row unified with the context would insist on. *)
          let rec opened (r : Types.infer_row) =
            match Types.repr_row r with
            | Types.REmpty -> Types.fresh_row ()
            | Types.RCons (label, args, rest) -> Types.RCons (label, args, opened rest)
            | open_ -> open_
          in
          let unified =
            match fn with
            | Types.IFn (params, answer, r) -> Types.IFn (params, answer, opened r)
            | other -> other
          in
          Types.unify
            unified
            (Types.IFn
               ( receiver.Ast.ann :: List.map (fun (a : checked_expr) -> a.Ast.ann) args
               , ret
               , row ));
          Types.unify_row row ctx.row;
          (* A receiver whose type is the trait is a value paired with a table,
             so the call reads its target out of that table. Otherwise the bound
             is what says which impl, and it is recorded for the copy. *)
          (match Types.repr receiver.Ast.ann with
           | Types.INamed (named, _) when String.equal named trait ->
             node ret (`Dyn_call (receiver, name, fn, args))
           | _ ->
             node
               ret
               (`Bound_call
                 ( receiver
                 , name
                 , Option.value
                     dispatch
                     ~default:{ Ast.dp_trait = declaring; dp_targets = bound_args; dp_instance = None }
                 , args )))))
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
       (* `Cat.type_name()` names the type, not its one value. *)
       if Option.is_some named_receiver
          && Hashtbl.mem ctx_methods (owner, name)
          && not (Hashtbl.mem ctx_associated (owner, name))
       then
         fail
           span
           "'%s' takes self, so it is called on a value, not on the type '%s'."
           name
           owner;
       let missing (type a) (anything : unit -> a) : a =
         !current.unknown
           (fun () ->
             match Hashtbl.find_opt ctx_types owner with
             | Some (Sum _) when Option.is_some named_receiver && Char.uppercase_ascii name.[0] = name.[0] ->
               fail span "Type '%s' has no variant '%s'." owner name
             | _ -> fail span "Type '%s' has no method '%s'." owner name)
           anything
       in
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
               || (Registry.method_entries ctx.registry owner name <> [] && in_reach owner = [])
       then (
         match via_function () with
         | Some call -> call
         | None ->
           (match via_field () with
            | Some call -> call
            | None ->
              (match Registry.method_entries ctx.registry owner name with
               | ({ Registry.trait = Some _; _ } as entry) :: _ ->
                 fail
                   span
                   "'%s' on '%s' comes from the trait '%s', which is not in scope here. Import it to call the method."
                   name
                   owner
                   (Registry.describe_entry owner entry)
               | _ -> missing anything)))
       else (
         (* Which impl a call reaches is decided by the receiver's type and the
            arguments, and neither tells these apart. *)
         (match in_reach owner with
          | (first :: _ :: _) as several ->
            fail
              span
              "'%s' has more than one '%s', from %s. Write which one, as '%s<%s>'."
              owner
              name
              (listed (List.map (Registry.describe_entry owner) several))
              name
              (String.concat ", " first.Registry.targets)
          | _ -> ());
         let fn =
           match lookup env (entry_in_reach owner) with
           | Some scheme -> Types.instantiate scheme
           | None -> missing Types.fresh
         in
         let associated = Hashtbl.mem ctx_associated (owner, name) in
         let args =
           match Types.repr fn with
           | Types.IFn (params, _, _) ->
             let params = Types.expand params in
             coerce_params
               (if associated
                then params
                else (
                  match params with
                  | _receiver :: rest -> rest
                  | [] -> []))
               args
           | _ -> args
         in
         let passed =
           let given = List.map (fun (a : checked_expr) -> a.Ast.ann) args in
           if associated then given else receiver.Ast.ann :: given
         in
         (match Types.repr fn with
          | Types.IFn (params, _, _)
            when List.length (Types.expand params) <> List.length (Types.expand passed) ->
            let params = Types.expand params in
            fail
              span
              "%s '%s' takes %d argument(s) but %d were passed."
              (if associated then "Associated function" else "Method")
              name
              (if associated then List.length params else List.length params - 1)
              (spread_arity args)
          | Types.IFn (params, _, _) ->
            let spans =
              (if associated then [] else [ receiver.Ast.span ])
              @ List.map (fun (a : checked_expr) -> a.Ast.span) args
            in
            if List.length params = List.length spans && List.length passed = List.length spans
            then
              List.iter2
                (fun (param, at) given -> unify_at at param given)
                (List.combine params spans)
                passed
          | _ -> ());
         let ret = Types.fresh () in
         let row = Types.fresh_row () in
         Types.unify fn (Types.IFn (passed, ret, row));
         admits_row
           ~name:(Registry.entry_for_method ctx.registry owner name)
           (lookup env (Registry.entry_for_method ctx.registry owner name))
           row
           ctx.row;
         let all = if associated then args else receiver :: args in
         node
           ret
           (`Call
             ( Ast.annotated
                 span
                 fn
                 (`Var (Registry.entry_for_method ctx.registry owner name))
             , all ))))))
  (* A spread stands for however many its tuple holds, so it is read where an
     argument list is and nowhere else. *)
  | `Spread _ -> fail span "A spread is an argument, so it belongs in a call."
  | `Lambda (params, signature, body) ->
    let expected = !expected_lambda in
    expected_lambda := None;
    let param_types = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params in
    (match Option.map Types.repr expected with
     | Some (Types.IFn (wanted, _, _)) ->
       let wanted = Types.expand wanted in
       if List.length wanted = List.length param_types
       then
         List.iter2
           (fun ty want ->
             try Types.unify ty want with
             | Types.Type_error _ -> ())
           param_types
           wanted
     | _ -> ());
    let declared_ret = annotated_or_fresh signature.Ast.ret in
    let row = Types.fresh_row () in
    let scope = new_env (Some env) in
    List.iter2
      (fun (p : Ast.param) ty -> bind scope p.Ast.name (Types.mono ty))
      params
      param_types;
    let at_root = !root_argument in
    root_argument := false;
    let saved = !top_row in
    if at_root then top_row := Some row;
    let body =
      Fun.protect
        ~finally:(fun () -> top_row := saved)
        (fun () -> in_function_body ctx ~ret:declared_ret ~row (fun () -> infer_block scope ctx body))
    in
    node (Types.IFn (param_types, declared_ret, row)) (`Lambda (params, signature, body))
  (* The declared type when no value answers, so `typeof(Dog)` works. *)
  | `Typeof { Ast.it = `Var name; span = inner; _ } when lookup env name = None ->
    let ty =
      match Hashtbl.find_opt ctx_type_param_names name with
      (* A generic type asked about as itself: at its own parameters. *)
      | Some (_ :: _ as names) ->
        let args =
          List.map
            (fun n ->
              let var = Types.fresh () in
              Types.declare_param var;
              Types.name_param n var;
              var)
            names
        in
        (match Hashtbl.find_opt ctx_types name with
         | Some (Sum _) -> Types.ISum (name, args)
         | _ -> Types.INamed (name, args))
      | _ ->
        (try infer_ty_of_annotation { Ast.it = Ast.Ty_name name; span = inner; ann = () } with
         | Located _ -> fail inner "Nothing named '%s' is a value or a type." name)
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
       admits_row ~name:fn (lookup env fn) row ctx.row;
       if type_args <> []
       then
         unify_at
           span
           (named_type span name (type_arguments name type_args))
           ret;
       node ret (`Call (Ast.annotated span fn_ty (`Var fn), args)))
  | `New (name, fields) ->
    (match Hashtbl.find_opt ctx_types name with
     | Some (Opaque _) -> fail span "'%s' has no fields to construct it with." name
     | None | Some (Sum _) -> fail span "Unknown record type '%s'." name
     | Some (Product (vars, declared)) ->
       let args = List.map fresh_argument vars in
       let declared = Types.substitute_fields (instance vars args) declared in
       let rec labels f =
         match Types.repr_fields f with
         | Types.FEmpty | Types.FVar _ -> []
         | Types.FCons (l, ty, rest) -> (l, ty) :: labels rest
       in
       let expected = labels declared in
       let fields =
         List.map
           (fun (l, v) ->
             match List.assoc_opt l expected with
             | Some ty when mentions_trait ty -> l, check_against env ctx ty v
             | _ -> l, infer_expr env ctx v)
           fields
       in
       List.iter
         (fun (l, _) ->
           if not (List.mem_assoc l expected)
           then
             !current.unknown
               (fun () -> fail span "Type '%s' has no field '%s'." name l)
               (fun () -> ()))
         fields;
       List.iter
         (fun (l, _) ->
           if not (List.mem_assoc l fields)
           then fail span "Field '%s' is missing." l)
         expected;
       (* A field the type does not declare was reported above, or set aside
          while a meta block could still declare it. *)
       List.iter
         (fun (l, (v : checked_expr)) ->
           match List.assoc_opt l expected with
           | Some ty -> unify_at v.Ast.span ty v.Ast.ann
           | None -> ())
         fields;
       node (Types.INamed (name, args)) (`New (name, fields)))
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
    let declared = field_of target label in
    let v = if is_trait_type declared then coerced declared v else v in
    unify_at v.Ast.span declared v.Ast.ann;
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
       let items = Types.expand items in
       (match List.nth_opt items index with
        | Some ty -> node ty (`Tuple_get (target, index))
        | None ->
          fail
            span
            "A tuple of %d element(s) has no field %d."
            (List.length items)
            index)
     | Types.IVar _ ->
       let unresolved () =
         fail
           target.Ast.span
           "The type of this tuple is not known here, so field %d cannot be resolved."
           index
       in
       !current.unknown unresolved (fun () ->
         if is_unknown target.Ast.ann
         then node (unknown_ty ()) (`Tuple_get (target, index))
         else unresolved ())
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
     | None when !current.unknown (fun () -> false) (fun () -> is_unknown target.Ast.ann) ->
       node (unknown_ty ()) (`Index (target, index))
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

(* What an argument contributes to the callee's parameter list: one type, or
   however many a spread's tuple holds. *)
(* How many arguments a list is once its spreads are taken apart. *)
and spread_arity (args : checked_expr list) =
  List.length (Types.expand (List.map (fun (a : checked_expr) -> a.Ast.ann) args))

and argument env ctx (a : Ast.desugared_expr) : checked_expr =
  match a.Ast.it with
  | `Spread inner ->
    let inner = infer_expr env ctx inner in
    let held =
      match Types.repr inner.Ast.ann with
      | Types.IUnit -> Types.IPack []
      | Types.ITuple items -> Types.IPack items
      | Types.IVar { contents = Types.Unbound (_, Types.Collection elem) } ->
        fail
          a.Ast.span
          "A spread takes a tuple, not Array<%s>: an argument list's length has to be \
           known at compile time."
          (Types.string_of_infer_ty elem)
      | other ->
        fail
          a.Ast.span
          "A spread takes a tuple, not %s: an argument list's length has to be known at \
           compile time."
          (Types.string_of_infer_ty other)
    in
    Ast.annotated a.Ast.span (Types.ISpread held) (`Spread inner)
  | _ -> infer_expr env ctx a

(* Checking mode, for the forms a written type can reach inside. A literal's
   elements are unified with each other, so an element that has to become an
   object must be coerced before that happens rather than after. *)
and check_against env ctx (expected : Types.infer_ty) (e : Ast.desugared_expr)
  : checked_expr
  =
  let element =
    match Types.repr expected with
    | Types.INamed (_, [ elem ]) -> Some elem
    | _ -> None
  in
  match e.Ast.it, element with
  | `Collection_lit items, Some elem when mentions_trait elem ->
    let items = List.map (check_against env ctx elem) items in
    Ast.annotated e.Ast.span expected (`Collection_lit items)
  (* Everything else keeps the unification it had, down to which span a
     mismatch is reported at. *)
  | `Match_expr (scrutinee, cases), _ ->
    located ctx e (fun () -> infer_match_expr env ctx e.Ast.span expected scrutinee cases)
  | _ when is_trait_type expected -> coerced expected (infer_expr env ctx e)
  | _ -> infer_expr env ctx e

(* [answer] is refined in each arm the way the scrutinee is, so a match checked
   against `T` can answer `int` from an arm that proved `T` is `int`. *)
and infer_match_expr env ctx span answer scrutinee cases : checked_expr =
  let arm scope refinement (b : (Ast.desugared_expr, Ast.desugared_stmt) Ast.valued_block) =
    let stmts = infer_block scope ctx b.Ast.vb_stmts in
    let expected = Types.substitute refinement answer in
    let value = Option.map (check_against scope ctx expected) b.Ast.vb_value in
    (match value with
     | None ->
       let last =
         match List.rev stmts with
         | (last : checked_stmt) :: _ -> last.Ast.span
         | [] -> span
       in
       unify_at last expected Types.IUnit
     | Some v -> unify_at v.Ast.span expected v.Ast.ann);
    { Ast.vb_stmts = stmts; vb_value = value }
  in
  let scrutinee, cases = infer_match env ctx span scrutinee cases arm in
  Ast.annotated span answer (`Match_expr (scrutinee, cases))

and declare_traits (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Trait_decl (name, params, trait_body) ->
        if Hashtbl.mem ctx_trait_spans name then fail s.Ast.span "Trait '%s' is already declared." name;
        Hashtbl.replace ctx_trait_spans name s.Ast.span;
        Hashtbl.replace ctx_traits name (params, trait_body);
        (* A parameter stands in a row where a method's signature puts it in one. *)
        let in_row p =
          List.exists
            (fun (m : Ast.method_sig) ->
              let written (t : Ast.type_expr option) =
                match t with
                | Some t -> row_param_in [ p ] t <> None
                | None -> false
              in
              (match m.Ast.ms_signature.Ast.row with
               | Some labels -> List.exists (fun (l, _) -> String.equal l p) labels
               | None -> false)
              || written m.Ast.ms_signature.Ast.ret
              || List.exists (fun (prm : Ast.param) -> written prm.Ast.ty) m.Ast.ms_params)
            trait_body.Ast.tb_methods
        in
        Hashtbl.replace ctx_row_standing name (List.map in_row params);
        (* In type position the name is a trait object, which has no fields of
           its own and cannot be constructed. *)
        Hashtbl.replace ctx_types name (Opaque (List.map (fun _ -> Types.fresh ()) params))
      | _ -> ())
    body

and declare_impls registry (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Impl_decl (trait, type_name, params, impl) ->
        let span = s.Ast.span in
        let methods = impl.Ast.ib_methods in
        check_pack_spelling span type_name params;
        let type_params =
          List.map
            (fun (p : Ast.type_param) ->
              let var = Types.fresh () in
              if p.Ast.tp_pack then Types.declare_pack var;
              p.Ast.tp_name, var)
            params
        in
        let supplies name =
          List.exists
            (fun (m : (Ast.desugared_stmt, unit) Ast.method_def) ->
              String.equal m.Ast.md_name name)
            methods
        in
        with_type_params type_params (fun () ->
          ignore (self_ty span type_name (List.map fst type_params)));
        with_type_params type_params (fun () ->
          List.iter
            (fun (name, bound) ->
              (* The key does not say which index, so the first stands and a
                 container reads as holding elements rather than slices. *)
              if not (Hashtbl.mem ctx_assoc (type_name, name))
              then Hashtbl.replace ctx_assoc (type_name, name) (infer_ty_of_annotation bound))
            (List.map (fun (a : Ast.assoc_def) -> a.Ast.as_name, a.Ast.as_ty) impl.Ast.ib_assoc));
        (match trait with
         | None -> ()
         | Some (trait_name, trait_args) ->
           (match Hashtbl.find_opt ctx_traits trait_name with
            | None -> !current.unknown (fun () -> fail span "Unknown trait '%s'." trait_name) ignore
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
                  if not (Ast.assoc_binds impl.Ast.ib_assoc name)
                  then
                    fail
                      span
                      "'%s' for '%s' is missing associated type '%s'."
                      trait_name
                      type_name
                      name)
                (Ast.assoc_names required.Ast.tb_assoc);
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
            (* `T.V(…)` names the variant, so the function could never be reached. *)
            (match Hashtbl.find_opt ctx_types type_name with
             | Some (Sum (_, variants)) when List.mem_assoc m.Ast.md_name variants ->
               fail span "'%s' already has a variant named '%s'." type_name m.Ast.md_name
             | _ -> ());
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
            Registry.register_entry
              registry
              type_name
              m.Ast.md_name
              { Registry.mangled
              ; trait = Option.map fst trait
              ; targets =
                  (match trait with
                   | Some (_, args) -> List.map Ast.written_type args
                   | None -> [])
              };
            Hashtbl.replace ctx_methods (type_name, m.Ast.md_name) ())
          methods;
        Option.iter
          (fun (t, args) ->
            (* The impl's own parameter may be among the trait's arguments. *)
            with_type_params type_params (fun () ->
              Hashtbl.add ctx_impls (type_name, t) (type_arguments t args)))
          trait;
        Option.iter
          (fun (t, args) ->
            let entry_name method_ = Ast.impl_method_name (Some (t, args)) type_name method_ in
            let self_concrete () =
              match Types.concrete (self_ty span type_name (List.map (fun (p : Ast.type_param) -> p.Ast.tp_name) params)) with
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
             | t when String.equal t Core.eq ->
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
             | t when String.equal t Core.neg || String.equal t Core.bit_not ->
               let op, written, method_ =
                 if String.equal t Core.neg then Ast.Neg, "Neg", "neg" else Ast.Bit_not, "BitNot", "bit_not"
               in
               with_type_params type_params (fun () ->
                 Registry.register_unary
                   registry
                   op
                   (self_concrete ())
                   { Registry.result =
                       (match Ast.assoc_bound impl.Ast.ib_assoc "Output" with
                        | Some bound -> Types.concrete (infer_ty_of_annotation bound)
                        | None ->
                          fail span "'%s' for '%s' is missing associated type 'Output'." written type_name)
                   ; emit = Registry.Call (entry_name method_)
                   })
             | t when String.equal t Core.partial_ord ->
               with_type_params type_params (fun () ->
                 let self = self_concrete () in
                 List.iter
                   (fun op ->
                     (* A primitive keeps the machine's comparison: its impl is
                        for a call to `partial_cmp`, and `<` reaching it would
                        put the impl's own comparisons through itself. *)
                     match Registry.find registry op self self with
                     | Some { Registry.emit = Registry.Primitive; _ } -> ()
                     | _ ->
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
             | t when String.equal t Core.index ->
               Registry.register_index_get registry type_name (written_name ()) (entry_name "get")
             | t when String.equal t Core.index_set ->
               Registry.register_index_set registry type_name (written_name ()) (entry_name "set")
             | t when String.equal t Core.from_array ->
               with_type_params type_params (fun () ->
                 let element = one_argument () in
                 let self = self_ty span type_name (List.map (fun (p : Ast.type_param) -> p.Ast.tp_name) params) in
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
                let lhs = concrete "type" (self_ty span type_name (List.map (fun (p : Ast.type_param) -> p.Ast.tp_name) params)) in
                let rhs =
                  match args with
                  | [ rhs ] -> concrete "right operand" (infer_ty_of_annotation rhs)
                  | _ -> fail span "'%s' takes one type argument." t
                in
                let result =
                  match Ast.assoc_bound impl.Ast.ib_assoc "Output" with
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
    body

(* Separate from [declare_impls] and run after it over the whole program: the
   impl a supertrait needs may come from a module declared later. *)
and check_supertraits (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Impl_decl (Some (trait, trait_args), type_name, params, _) ->
        (match Hashtbl.find_opt ctx_traits trait with
         | None -> ()
         | Some (trait_params, body) ->
           let type_params =
             List.map
               (fun (p : Ast.type_param) -> p.Ast.tp_name, Types.fresh ())
               params
           in
           let written t = Option.value (Types.infer_type_name t) ~default:"_" in
           let args =
             with_type_params type_params (fun () -> type_arguments trait trait_args)
           in
           let scope =
             type_params
             @ (if List.length trait_params = List.length args
                then List.combine trait_params args
                else [])
           in
           List.iter
             (fun (super, super_args) ->
               (* At the arguments the supertrait is written with: `Derived<int>`
                  over `Base<Idx>` is satisfied by `Base<int>` and no other. *)
               let self =
                 with_type_params type_params (fun () ->
                   self_ty s.Ast.span type_name (List.map fst type_params))
               in
               let wanted, bindings = super_arguments ~self scope super super_args in
               let wanted = List.map written wanted in
               let supplied = Hashtbl.find_all ctx_impls (type_name, super) in
               if not (List.exists (fun have -> List.map written have = wanted) supplied)
               then (
                 let named args =
                   match args with
                   | [] -> super
                   | args -> Printf.sprintf "%s<%s>" super (String.concat ", " args)
                 in
                 match supplied with
                 | [] ->
                   fail
                     s.Ast.span
                     "'%s' for '%s' is missing the supertrait '%s'."
                     trait
                     type_name
                     (named wanted)
                 | supplied ->
                   fail
                     s.Ast.span
                     "'%s' for '%s' needs '%s', and has %s."
                     trait
                     type_name
                     (named wanted)
                     (listed (List.map (fun have -> named (List.map written have)) supplied)));
               List.iter
                 (fun (member, expected) ->
                   match Hashtbl.find_opt ctx_assoc (type_name, member) with
                   | Some found when written found = written expected -> ()
                   | found ->
                     fail
                       s.Ast.span
                       "'%s' for '%s' needs '%s' with %s = %s, and %s."
                       trait
                       type_name
                       super
                       member
                       (written expected)
                       (match found with
                        | Some found -> Printf.sprintf "has %s = %s" member (written found)
                        | None -> "binds no " ^ member))
                 bindings)
             body.Ast.tb_super)
      | _ -> ())
    body

and associated_names trait =
  List.sort_uniq
    String.compare
    (List.concat_map
       (fun t ->
         match Hashtbl.find_opt ctx_traits t with
         | Some (_, body) -> Ast.assoc_names body.Ast.tb_assoc
         | None -> [])
       (trait_closure trait))

and conforms span ~trait ~args ~params ~required ~type_name ~type_params ~decl_params impl =
  let in_scope =
    with_type_params type_params (fun () ->
      ( "Self"
      , self_ty span type_name (List.map (fun (p : Ast.type_param) -> p.Ast.tp_name) decl_params)
      )
      :: List.map
           (fun name ->
             ( name
             , match Ast.assoc_bound impl.Ast.ib_assoc name with
               | Some bound -> infer_ty_of_annotation bound
               (* A supertrait's, bound by the impl that supplied it. *)
               | None ->
                 (match Hashtbl.find_opt ctx_assoc (type_name, name) with
                  | Some ty -> ty
                  | None -> Types.fresh ()) ))
           (associated_names trait)
      @ List.combine params (type_arguments trait args))
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
    type_params_of span r.Ast.ms_signature.Ast.static_params
    @ type_params_of span m.Ast.md_signature.Ast.static_params
  in
  with_type_params own (fun () ->
    let types params = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params in
    let declared = types declared_params
    and declared_ret = annotated_or_fresh r.Ast.ms_signature.Ast.ret in
    let defined = types defined_params
    and defined_ret = annotated_or_fresh m.Ast.md_signature.Ast.ret in
    let written (sg : Ast.signature) = Option.value ~default:[] sg.Ast.row in
    let declared_row = written r.Ast.ms_signature
    and defined_row = written m.Ast.md_signature in
    let shown params row ret =
      Printf.sprintf
        "(self%s): %s%s"
        (String.concat "" (List.map (fun t -> ", " ^ Types.string_of_infer_ty t) params))
        (match row with
         | [] -> ""
         | entries ->
           Printf.sprintf
             "<%s> "
             (String.concat ", " (List.map Printer.string_of_row_entry entries)))
        (Types.string_of_infer_ty ret)
    in
    (* Read before unifying: a link the first mismatch leaves behind would
       otherwise be printed as what was written. *)
    let declared_text = shown declared declared_row declared_ret
    and defined_text = shown defined defined_row defined_ret in
    let mismatched () =
      fail
        span
        "'%s' for '%s' declares '%s' as %s but defines %s."
        trait
        type_name
        r.Ast.ms_name
        declared_text
        defined_text
    in
    (* A call through a vtable emits one calling convention, so the row an impl
       performs is the trait's to declare and the impl's to repeat -- as rows,
       so `<E>` at an impl of `Source<int, <log>>` is `<log>`. *)
    (try Types.unify_row (row_of_labels ~span declared_row) (row_of_labels ~span defined_row) with
     | Types.Type_error _ -> mismatched ());
    try
      List.iter2 Types.unify declared defined;
      Types.unify declared_ret defined_ret
    with
    | Types.Type_error _ -> mismatched ())

(* One spelling for a pack: the dots say which parameter stands for a parameter
   list, and a header that disagrees with the declaration reads as the other
   thing. *)
and check_pack_spelling span type_name (params : Ast.type_param list) =
  let packed = Hashtbl.mem ctx_type_packs type_name in
  List.iteri
    (fun index (p : Ast.type_param) ->
      let last = index = List.length params - 1 in
      match p.Ast.tp_pack, packed && last with
      | true, false ->
        fail
          span
          "'%s' has no pack parameter, so '...%s' has nothing to spread."
          type_name
          p.Ast.tp_name
      | false, true ->
        fail
          span
          "'%s' declared its last parameter a pack, so it is written '...%s'."
          type_name
          p.Ast.tp_name
      | _ -> ())
    params

and self_ty span type_name params =
  if params = []
  then infer_ty_of_annotation (Ast.at span (Ast.Ty_name type_name))
  else
    (* An impl header supplies the type's parameters rather than arguments to
       them, so a pack stands where it was declared instead of collecting what
       came after it. *)
    let standing = Option.value ~default:[] (Hashtbl.find_opt ctx_row_standing type_name) in
    named_type
      ~written:false
      span
      type_name
      (List.mapi
         (fun i name ->
           match Hashtbl.find_opt ctx_type_params name, Hashtbl.find_opt ctx_row_params name with
           | Some _, Some row when List.nth_opt standing i = Some true -> Types.IRow row
           | Some var, _ -> var
           | None, _ -> Types.fresh ())
         params)

(* Hoisting reads signatures, and a row naming an effect has to know how many
   arguments that effect carries, so the parameters are bound before any of
   them is read. The declaration itself reuses what is bound here: one variable
   per parameter per declaration, so every use of the effect agrees. *)
and declare_effects (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Effect_decl (name, params, _) when not (Hashtbl.mem ctx_effect_params name) ->
        Hashtbl.replace
          ctx_effect_params
          name
          (List.map (fun p -> p, Types.fresh ()) params)
      | _ -> ())
    body

(* Every name is registered before any body is read, so a field may name a
   type declared after its own -- which the walk produces whenever it reaches a
   type through another's field rather than through the program. The fields are
   read off the declaration when used, so a placeholder is all a use needs. *)
and declare_type_names (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      match s.Ast.it with
      | `Type_decl (name, params, body) ->
        if Hashtbl.mem ctx_type_spans name || Hashtbl.mem ctx_types name
        then fail s.Ast.span "Type '%s' is already declared." name;
        Hashtbl.replace ctx_type_spans name s.Ast.span;
        Hashtbl.replace
          ctx_type_param_names
          name
          (List.map (fun (p : Ast.type_param) -> p.Ast.tp_name) params);
        let vars =
          List.map
            (fun (p : Ast.type_param) ->
              let var = Types.fresh () in
              if p.Ast.tp_pack then Types.declare_pack var;
              var)
            params
        in
        if List.exists (fun (p : Ast.type_param) -> p.Ast.tp_pack) params
        then Hashtbl.replace ctx_type_packs name ();
        (* Already the right shape, or `Add(Expr<int>, …)` reads `Expr` as a
           product. *)
        Hashtbl.replace
          ctx_types
          name
          (match body with
           | Ast.T_variants _ -> Sum (vars, [])
           | Ast.T_fields _ -> Product (vars, Types.FEmpty));
        (match body with
         | Ast.T_fields _ -> Types.declare_fields name vars Types.FEmpty
         | Ast.T_variants _ -> ())
      | _ -> ())
    body

(* The variables are the ones [declare_type_names] registered, so a use read
   before this ran agrees with the declaration. A duplicate it rejected is not
   the registered one and is skipped, or it would overwrite the original. *)
(* A member whose type does not read is reported once, and stands as a variable
   meanwhile: dropping the whole type instead would report every later use of
   its other members as missing. *)
and member_type annotation =
  try infer_ty_of_annotation annotation with
  | Located e ->
    if Option.is_none !unreadable_member then unreadable_member := Some e;
    Types.fresh ()

and declare_type_bodies (body : Ast.desugared_stmt list) =
  List.iter
    (fun (s : Ast.desugared_stmt) ->
      unreadable_member := None;
      match s.Ast.it with
      | `Type_decl (name, params, body)
        when (match Hashtbl.find_opt ctx_type_spans name with
              | Some registered -> registered == s.Ast.span
              | None -> false) ->
        let vars = params_of_decl name in
        let type_params =
          List.map2 (fun (p : Ast.type_param) var -> p.Ast.tp_name, var) params vars
        in
        let declared =
          with_type_params type_params (fun () ->
            match body with
            | Ast.T_fields fields ->
              Product
                ( vars
                , List.fold_right
                    (fun (f : Ast.field) rest ->
                      Types.FCons (f.Ast.f_name, member_type f.Ast.f_ty, rest))
                    fields
                    Types.FEmpty )
            | Ast.T_variants variants ->
              Sum (vars, List.map (variant_of s.Ast.span name vars) variants))
        in
        Hashtbl.replace ctx_types name declared;
        (match declared with
         | Product (vars, fields) -> Types.declare_fields name vars fields
         | Opaque _ | Sum _ -> ());
        (* A parameter stands in a row where the body leaves a row open in it. *)
        let body_rows =
          match declared with
          | Product (_, fields) -> Types.free_row_vars (Types.IRecord fields)
          | Sum (_, variants) ->
            List.concat_map
              (fun (_, vd) ->
                List.concat_map
                  Types.free_row_vars
                  (match vd.vd_payload with
                   | Ast.P_none -> []
                   | Ast.P_tuple types -> types
                   | Ast.P_fields fields -> List.map snd fields))
              variants
          | Opaque _ -> []
        in
        let standing =
          List.map
            (fun v ->
              match Types.row_tail (row_of_param v) with
              | Some id when List.mem id body_rows ->
                Hashtbl.replace ctx_standing_rows (Types.var_id v) (row_of_param v);
                Some id
              | _ -> None)
            vars
        in
        Hashtbl.replace ctx_row_standing name (List.map Option.is_some standing);
        Types.declare_row_params name standing;
        Hashtbl.replace
          ctx_attrs
          name
          (match body with
           | Ast.T_fields fields ->
             List.map (fun (f : Ast.field) -> f.Ast.f_name, f.Ast.f_attrs) fields
           | Ast.T_variants variants ->
             List.map (fun (v : Ast.variant) -> v.Ast.v_name, v.Ast.v_attrs) variants);
        Option.iter (fun e -> raise (Located e)) !unreadable_member
      | _ -> ())
    body

(* A written head is the type at whatever the constructor pins; one that is not
   is what every non-GADT builds. *)
and variant_of span owner vars (v : Ast.variant) =
  let own = List.map (fun name -> name, Types.fresh ()) v.Ast.v_params in
  with_type_params own (fun () ->
    let payload = Ast.map_payload member_type v.Ast.v_payload in
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
            (fun (p : Ast.type_param) ->
              let var = Types.fresh () in
              Types.declare_param var;
              if p.Ast.tp_pack then Types.declare_pack var;
              p.Ast.tp_name, var)
            params
        in
        (* `impl Encode for List<T: Encode>`: a parameter annotated with a trait
           is bounded by it, as a function's is. *)
        with_type_params impl_params (fun () ->
          List.iter2
            (fun (p : Ast.type_param) (_, var) ->
              match p.Ast.tp_ty with
              | Some { Ast.it = Ast.Ty_name trait; _ } when Hashtbl.mem ctx_traits trait ->
                Types.constrain var (Types.Bound [ { Types.bd_trait = trait; bd_args = []; bd_bindings = [] } ])
              | Some { Ast.it = Ast.Ty_app (trait, args); _ } when Hashtbl.mem ctx_traits trait ->
                Types.constrain
                  var
                  (Types.Bound [ { Types.bd_trait = trait; bd_args = type_arguments trait args; bd_bindings = [] } ])
              | _ -> ())
            params
            impl_params);
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
                @ type_params_of s.Ast.span m.Ast.md_signature.Ast.static_params
              in
              Hashtbl.replace ctx_fn_params mangled type_params;
              Hashtbl.replace unchecked mangled ();
              with_type_params type_params (fun () ->
                let param_types =
                  self_ty s.Ast.span type_name (List.map fst impl_params)
                  :: List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) rest
                in
                let row =
                  match m.Ast.md_signature.Ast.row with
                  | Some labels -> row_of_labels ~span:s.Ast.span labels
                  | None -> Types.fresh_row ()
                in
                bind
                  env
                  mangled
                  (declared_scheme
                     type_params
                     (Types.IFn
                        ( param_types
                        , annotated_or_fresh m.Ast.md_signature.Ast.ret
                        , row ))))
            (* An associated function takes no receiver, but its signature is
               still written in the impl's parameters. *)
            | written ->
              let mangled = Ast.impl_method_name trait type_name m.Ast.md_name in
              let type_params =
                impl_params @ type_params_of s.Ast.span m.Ast.md_signature.Ast.static_params
              in
              Hashtbl.replace ctx_fn_params mangled type_params;
              Hashtbl.replace unchecked mangled ();
              with_type_params type_params (fun () ->
                let row =
                  match m.Ast.md_signature.Ast.row with
                  | Some labels -> row_of_labels ~span:s.Ast.span labels
                  | None -> Types.fresh_row ()
                in
                bind
                  env
                  mangled
                  (declared_scheme
                     type_params
                     (Types.IFn
                        ( List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) written
                        , annotated_or_fresh m.Ast.md_signature.Ast.ret
                        , row )))))
          impl.Ast.ib_methods
      | `Fn (name, params, signature, _) ->
        let type_params = type_params_of s.Ast.span signature.Ast.static_params in
        Hashtbl.replace ctx_fn_params name type_params;
        Hashtbl.replace unchecked name ();
        with_type_params type_params (fun () ->
          let param_types =
            List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params
          in
          let row =
            match signature.Ast.row with
            | Some labels -> row_of_labels ~span:s.Ast.span labels
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
    (* Before the types: a field may be written with a trait, which is a type
       only once the trait is registered as one. *)
    declare_traits body;
    declare_effects body;
    declare_type_names body;
    declare_type_bodies body;
    declare_impls ctx.registry body;
    check_supertraits body;
    hoist env body;
    let assigned = assigned_names body in
    List.map
      Option.get
      (infer_in_order env ctx assigned ~attempt:(fun check -> Some (check ())) body))

(* In [dependency_order], back in source order. Functions calling each other are
   generalized together, once all of them are checked, so none is generalized
   while another's row is still [hoist]'s. [attempt] says what a failed check
   leaves behind. *)
and infer_in_order env ctx assigned ~attempt (body : Ast.desugared_stmt list) =
  let stmts = Array.of_list body in
  let checked = Array.make (Array.length stmts) None in
  List.iter
    (fun group ->
      let name_of i =
        match stmts.(i).Ast.it with
        | `Fn (name, _, _, _) -> Some name
        | _ -> None
      in
      let is_impl i =
        match stmts.(i).Ast.it with
        | `Impl_decl _ -> true
        | _ -> false
      in
      (* A method call names every method of that name, so unrelated impls and
         the functions calling them often land in one group. Its declarations
         are generalized together, once all of them are checked, as functions
         calling each other are: a method's or a function's row is open until
         it is checked, so one generalized while another it calls is unchecked
         keeps that row, and every later caller would add its effects to it.
         The impls go first, so a function in the group instantiates a method
         its impl has already answered for. *)
      let together =
        List.length group > 1
        && List.for_all (fun i -> Option.is_some (name_of i) || is_impl i) group
      in
      let impls, rest = List.partition is_impl group in
      let methods () =
        List.concat_map
          (fun i ->
            match checked.(i) with
            | Some { Ast.it = `Impl_decl (trait, type_name, _, impl); _ } ->
              List.map
                (fun (m : (checked_stmt, Types.infer_ty) Ast.method_def) ->
                  Ast.impl_method_name trait type_name m.Ast.md_name, m.Ast.md_ann)
                impl.Ast.ib_methods
            | _ -> [])
          impls
      in
      let waiting = ref [] in
      let generalize_waiting ?(with_methods = false) () =
        if !waiting <> [] || with_methods
        then (
          discharge_pending ();
          generalize_methods
            env
            ((if with_methods then methods () else [])
             @ List.filter_map
               (fun i ->
                 match name_of i, checked.(i) with
                 | Some name, Some (c : checked_stmt) -> Some (name, c.Ast.ann)
                 | _ -> None)
               (List.rev !waiting));
          waiting := [])
      in
      List.iter
        (fun i -> checked.(i) <- attempt (fun () -> infer_stmt ~generalize:false env ctx assigned stmts.(i)))
        impls;
      discharge_pending ();
      if not together then generalize_methods env (methods ());
      (* A group holding a top-level statement too -- a function reaching a
         `var` declared after a statement that calls it -- still generalizes
         its functions together. One generalized while a callee later in the
         group is unchecked has its row grow when that callee is, after its
         callers have instantiated the smaller one, and CPS then gives the
         declaration more evidence parameters than those calls pass. *)
      let mixed = List.length group > 1 in
      let last_fn =
        List.fold_left (fun last i -> if Option.is_some (name_of i) then Some i else last) None rest
      in
      List.iter
        (fun i ->
          checked.(i)
          <- attempt (fun () ->
               infer_stmt ~generalize:(not mixed) env ctx assigned stmts.(i));
          if mixed && Option.is_some (name_of i) then waiting := i :: !waiting;
          if Some i = last_fn && mixed then generalize_waiting ~with_methods:together ())
        rest;
      discharge_pending ();
      if together && Option.is_none last_fn then generalize_waiting ~with_methods:true ())
    (dependency_order body);
  Array.to_list checked

and generalize_methods env methods =
  if methods <> [] then generalize_listed env methods

and generalize_listed env methods =
  List.iter
    (fun (mangled, _) ->
      Hashtbl.remove unchecked mangled;
      Hashtbl.remove env.bindings mangled)
    methods;
  let env_vars = env_free_vars env
  and env_rows = env_free_row_vars env
  and env_fields = env_free_field_vars env in
  List.iter
    (fun (mangled, fn_type) -> bind env mangled (Types.generalize ~env_vars ~env_rows ~env_fields fn_type))
    methods

and infer_stmt ?(generalize = true) env ctx assigned (s : Ast.desugared_stmt)
  : checked_stmt
  =
  let checked =
    try infer_stmt_impl ~generalize env ctx assigned s with
    | Types.Type_error message -> raise (Located { span = s.Ast.span; message })
  in
  note_effect_sites s.Ast.span ctx.row;
  checked

and infer_stmt_impl ~generalize env ctx assigned (s : Ast.desugared_stmt) : checked_stmt =
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
        (try Types.unify declared Types.IUnit with
         | Types.Type_error _ ->
           let written = Types.string_of_infer_ty declared in
           bind env name (Types.mono declared);
           fail
             span
             "'%s' is declared as %s but has no value; write 'var %s: %s = …;'."
             name
             written
             name
             written);
        None
      | Some e ->
        let e' =
          if Option.is_some annotation
          then check_against env ctx declared e
          else infer_expr env ctx e
        in
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
  (* Lowered here rather than in [Desugar]: whether the sequence is indexed or
     pulled is a question about its type. One the checker cannot see yet is
     indexed, which is what every `for` was before iterators. *)
  | `For_in (names, iterable, body) ->
    let scope = new_env (Some env) in
    let seq = Desugar.fresh "seq" in
    let at = iterable.Ast.span in
    let decl =
      infer_stmt scope ctx assigned { Ast.it = `Var_decl (seq, None, Some iterable); span = at; ann = () }
    in
    let held =
      match decl.Ast.it with
      | `Var_decl (_, _, Some e) -> Types.repr e.Ast.ann
      | _ -> Types.IUnit
    in
    let loop =
      match held with
      | Types.INamed (name, [ _; _ ]) when String.equal name Core.iter -> Desugar.pulled at names seq ~closes:true body
      | Types.IFn ([], _, _) -> Desugar.pulled at names seq ~closes:false body
      | _ -> Desugar.indexed at names seq body
    in
    node (`Block (decl :: infer_block scope ctx loop))
  | `While (cond, body) ->
    let cond = infer_expr env ctx cond in
    unify_at cond.Ast.span Types.IBool cond.Ast.ann;
    let looping = !in_loop in
    in_loop := true;
    let body = Fun.protect ~finally:(fun () -> in_loop := looping) (fun () -> infer_stmt env ctx assigned body) in
    node (`While (cond, body))
  | (`Break | `Continue) as jump ->
    if not !in_loop
    then
      fail
        span
        "%s, and none encloses it here: a function, a lambda, a 'run' block or a \
         'defer' stands between."
        (match jump with
         | `Break -> "'break' leaves a loop"
         | `Continue -> "'continue' skips to a loop's next iteration");
    node jump
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
    if generalize
    then (
      discharge_pending ();
      Hashtbl.remove unchecked name;
      Hashtbl.remove env.bindings name;
      bind
        env
        name
        (Types.generalize
           ~env_vars:(env_free_vars env)
           ~env_rows:(env_free_row_vars env)
           ~env_fields:(env_free_field_vars env)
           fn_type));
    Ast.annotated span fn_type (`Fn (name, params, signature, body)))
  | `Defer inner ->
    let looping = !in_loop
    and outer = ctx.row
    and enclosing = !open_defer in
    let d = { d_span = span; d_row = Types.fresh_row (); d_open = false } in
    in_loop := false;
    ctx.row <- d.d_row;
    open_defer := Some d;
    let inner =
      Fun.protect
        ~finally:(fun () ->
          in_loop := looping;
          ctx.row <- outer;
          open_defer := enclosing)
        (fun () -> infer_stmt env ctx assigned inner)
    in
    Types.row_within d.d_row ctx.row;
    deferred_rows := d :: !deferred_rows;
    node (`Defer inner)
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
    (* The printer calls these wherever a value is written, inside another
       value or not, and nothing there handles an effect. *)
    (match trait with
     | Some (t, _) when String.equal t Core.display || String.equal t Core.debug ->
       List.iter
         (fun (_, fn_type, (m : (checked_stmt, Types.infer_ty) Ast.method_def)) ->
           match fn_type with
           | Types.IFn (_, _, row) ->
             (match fst (Types.labels_of_infer_row row) with
              | [] -> ()
              | (label, _) :: _ ->
                fail
                  span
                  "'%s' in this impl performs '%s', and a value is printed by calling it wherever \
                   the value is written, where nothing handles an effect."
                  m.Ast.md_name
                  label)
           | _ -> ())
         inferred
     | _ -> ());
    (* One variable per impl parameter is shared by every method, so the impl
       generalizes as a group or not at all. *)
    if generalize
    then (
      discharge_pending ();
      generalize_methods env (List.map (fun (mangled, fn_type, _) -> mangled, fn_type) inferred));
    node
      (`Impl_decl (trait, type_name, params, { impl with Ast.ib_methods = List.map (fun (_, _, m) -> m) inferred }))
  | `Match (scrutinee, cases) ->
    let scrutinee, cases =
      infer_match env ctx span scrutinee cases (fun scope _ body -> infer_block scope ctx body)
    in
    node (`Match (scrutinee, cases))
  | `Effect_decl (name, params, ops) ->
    Hashtbl.replace ctx_effects.declared name ops;
    let bound =
      match Hashtbl.find_opt ctx_effect_params name with
      | Some bound when List.length bound = List.length params -> bound
      | _ -> List.map (fun p -> p, Types.fresh ()) params
    in
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
    (* After the operations are bound, so a handler naming one still checks. *)
    List.iter
      (fun (o : Ast.op_decl) ->
        let shared = List.filter (fun p -> not (List.mem p o.Ast.op_tparams)) params in
        List.iter
          (fun t ->
            match row_param_in shared t with
            | Some (param, at) ->
              fail
                at
                "'%s' is a parameter of '%s', and an effect's parameter cannot stand in a \
                 row."
                param
                name
            | None -> ())
          (Option.to_list o.Ast.op_ret
           @ List.filter_map (fun (p : Ast.param) -> p.Ast.ty) o.Ast.op_params))
      ops;
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
  | `Discontinue ->
    if ctx.resume_type = None
    then
      if ctx.in_final_arm
      then
        fail
          span
          "A 'final ctl' handler cannot discontinue: it never resumes, so its \
           continuation is unwound already."
      else fail span "'discontinue' outside of a 'ctl' handler.";
    node `Discontinue
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
        (* A signature's return type is written, so it asks for an object the
           same way a parameter does. *)
        let e' = check_against env ctx expected e in
        unify_at e'.Ast.span expected e'.Ast.ann;
        Some e'
    in
    node (`Return e)

and infer_match
  : 'b 'c.
    env
    -> ctx
    -> Ast.span
    -> Ast.desugared_expr
    -> (Ast.pattern * 'b) list
    -> (env -> (int * Types.infer_ty) list -> 'b -> 'c)
    -> checked_expr * (Ast.pattern * 'c) list
  =
  fun env ctx span scrutinee cases arm_body ->
  let scrutinee = infer_expr env ctx scrutinee in
  let not_a_sum other =
    fail
      scrutinee.Ast.span
      "Only a sum type can be matched, and this is %s."
      (Types.string_of_infer_ty other)
  in
  (* A scrutinee a meta block has yet to declare is whatever its arms say. *)
  let pinned () =
    List.find_map
      (fun ((pattern : Ast.pattern), _) ->
        match pattern with
        | Ast.Pat_variant (ty, _, _) ->
          (match Hashtbl.find_opt ctx_types ty with
           | Some (Sum (vars, _)) ->
             let args = List.map fresh_argument vars in
             unify_at scrutinee.Ast.span (Types.ISum (ty, args)) scrutinee.Ast.ann;
             Some (ty, args)
           | _ -> None)
        | Ast.Pat_wild -> None)
      cases
  in
  let matched =
    match Types.repr scrutinee.Ast.ann with
    | Types.ISum (name, args) -> Some (name, args)
    | other when is_unknown scrutinee.Ast.ann ->
      !current.unknown (fun () -> not_a_sum other) pinned
    | other -> not_a_sum other
  in
  (match matched with
   | None ->
     scrutinee, List.map (fun (pattern, body) -> pattern, arm_body (new_env (Some env)) [] body) cases
   | Some (sum, sum_args) ->
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
      let fresh = List.map (fun (_, v) -> Types.var_id v) freshened in
      match Types.solve ~fresh (List.combine sum_args head) with
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
      then arm_body scope refinement body
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
                let checked = arm_body scope refinement body in
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
            pattern, arm_body (new_env (Some env)) [] body
          | Ast.Pat_variant (ty, variant, payload) ->
            if not (String.equal ty sum)
            then (
              let short n =
                match List.rev (String.split_on_char '#' n) with
                | last :: _ -> last
                | [] -> n
              in
              match declared_in sum with
              | Some where when not (Hashtbl.mem ctx_types ty) ->
                fail
                  span
                  "'%s' is not a type in scope here. The value matched is the %s declared in %s: import it from there."
                  (short ty)
                  (short sum)
                  where
              | Some where when String.equal (short ty) (short sum) ->
                fail
                  span
                  "This matches a %s, but the value is the %s declared in %s, which is a different type."
                  ty
                  (short sum)
                  where
              | _ -> fail span "This matches a %s, not a %s." ty sum);
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
    scrutinee, cases)

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
    (* Tied to a variable outside the arm is settled too, only later: whatever
       that variable becomes, every call site would be held to it. *)
    let outer_types = env_free_vars env
    and outer_rows = env_free_row_vars env in
    List.iter
      (fun (name, var) ->
        (match Types.repr var with
         | Types.IVar { contents = Types.Unbound (id, _) } ->
           if List.mem id outer_types
           then
             Types.error
               "This handler ties '%s' to a type from outside it, but '%s' is handled \
                once for every type its call sites use."
               name
               a.Ast.arm_name
         | settled ->
           Types.error
             "This handler settles '%s' at %s, but '%s' is handled once for every \
              type its call sites use."
             name
             (Types.string_of_infer_ty settled)
             a.Ast.arm_name);
        match Types.repr_row (row_of_param var) with
        | Types.RVar { contents = Types.RUnbound id } ->
          if List.mem id outer_rows
          then
            Types.error
              "This handler ties '%s' to a row from outside it, but '%s' is handled \
               once for every row its call sites use."
              name
              a.Ast.arm_name
        | settled ->
          Types.error
            "This handler settles '%s' at <%s>, but '%s' is handled once for every \
             row its call sites use."
            name
            (Types.string_of_infer_row settled)
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
    | #Ast.spread as s -> (Ast.map_spread resolve_expr s :> Ast.typed_expr_kind)
    | #Ast.record as r -> (Ast.map_record resolve_expr r :> Ast.typed_expr_kind)
    | #Ast.nominal as n -> (Ast.map_nominal resolve_expr n :> Ast.typed_expr_kind)
    | #Ast.collection as c ->
      (Ast.map_collection resolve_expr c :> Ast.typed_expr_kind)
    | #Ast.bound_calls as b ->
      (Ast.map_bound_call resolve_expr Types.resolve b :> Ast.typed_expr_kind)
    | #Ast.dyn_calls as d ->
      (Ast.map_dyn_call resolve_expr Types.resolve d :> Ast.typed_expr_kind)
    | #Ast.coercions as c ->
      (Ast.map_coercion resolve_expr Types.resolve c :> Ast.typed_expr_kind)
    | #Ast.reflect as r -> (Ast.map_reflect resolve_expr r :> Ast.typed_expr_kind)
    | #Ast.run_expr as r ->
      (Ast.map_run_expr resolve_expr resolve_stmt (Ast.map_handler resolve_stmt) r
       :> Ast.typed_expr_kind)
    | #Ast.match_expr as m ->
      (Ast.map_match_expr resolve_expr resolve_stmt m :> Ast.typed_expr_kind)
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

(* An impl a meta block has yet to generate is as unknown as a name. *)
let satisfies name (b : Types.bound) =
  let fits declared =
    List.length declared = List.length b.Types.bd_args
    &&
    try
      List.iter2 Types.unify b.Types.bd_args declared;
      (* The impl reached must have bound the name to what the bound said. *)
      List.for_all
        (fun (member, expected) ->
          match Hashtbl.find_opt ctx_assoc (name, member) with
          | None -> false
          | Some found ->
            Types.unify found expected;
            true)
        b.Types.bd_bindings
    with
    | Types.Type_error _ -> false
  in
  (* Each impl is tried with its unifications taken back, then the one that fits
     is unified for good: `Add<int>` tried first would otherwise fix the
     argument to `int` before `Add<V>` is reached. *)
  (match
     List.find_opt
       (fun declared -> Types.retracting (fun () -> fits declared))
       (Hashtbl.find_all ctx_impls (name, b.Types.bd_trait))
   with
   | Some declared -> fits declared
   | None -> false)
  || !current.unknown (fun () -> false) (fun () -> true)

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
     (* An object meets its own trait and each supertrait: its table holds their
        methods, so a copy made at the object dispatches through it. *)
     | Some name when Hashtbl.mem ctx_traits name ->
       let args =
         match Types.repr t with
         | Types.INamed (_, args) -> args
         | _ -> []
       in
       List.for_all
         (fun (b : Types.bound) ->
           match reached_at name args b.Types.bd_trait with
           | Some found ->
             (try
                List.iter2 Types.unify b.Types.bd_args found;
                true
              with
              | Types.Type_error _ | Invalid_argument _ -> false)
           | None -> false)
         traits
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
      Hashtbl.add ctx_impls (Option.get (Types.type_name ty), Core.eq) [])
    [ Types.Int; Types.Float; Types.Str; Types.Chr; Types.Byte; Types.Bool; Types.Unit ];
  (* Whatever the registry can compare has an order, which is what a
     `PartialOrd` bound asks for. *)
  List.iter
    (fun ty ->
      if Registry.find registry Ast.Less ty ty <> None
      then Hashtbl.add ctx_impls (Option.get (Types.type_name ty), Core.partial_ord) [])
    [ Types.Int; Types.Float; Types.Str; Types.Chr; Types.Byte ];
  List.iter
    (fun ty -> Hashtbl.add ctx_impls (Option.get (Types.type_name ty), Core.neg) [])
    [ Types.Int; Types.Float ];
  List.iter
    (fun ty -> Hashtbl.add ctx_impls (Option.get (Types.type_name ty), Core.bit_not) [])
    [ Types.Int; Types.Byte ];
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
    (fun (owner, name, _doc, signature) ->
      let params, ret = signature () in
      Hashtbl.replace ctx_methods (owner, name) ();
      bind env (Ast.method_name owner name) (pure params ret))
    Builtins.methods;
  List.iter
    (fun (name, _doc, signature) ->
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

let check_with ~registry (program : Ast.desugared_stmt list)
  : (Ast.typed_stmt list, error list) result
  =
  Types.reset ();
  unknowns := [];
  Types.extra_admits := admits registry;
  Types.assoc_binding := (fun owner member -> Hashtbl.find_opt ctx_assoc (owner, member));
  reset_effects ();
  deferred_rows := [];
  pending_calls := [];
  Hashtbl.reset unchecked;
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
  top_row := Some ctx.row;
  Hashtbl.reset effect_sites;
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
  each declare_traits;
  each declare_effects;
  each declare_type_names;
  each declare_type_bodies;
  each (declare_impls registry);
  each check_supertraits;
  each (hoist env);
  let assigned = assigned_names program in
  let attempt check =
    try Some (check ()) with
    | Located e ->
      errors := e :: !errors;
      None
  in
  let checked = List.filter_map Fun.id (infer_in_order env ctx assigned ~attempt program) in
  let never_resumes label =
    match Hashtbl.find_opt ctx_effects.declared label with
    | Some ops -> List.exists (fun (o : Ast.op_decl) -> o.Ast.op_kind = Ast.Op_final) ops
    | None -> false
  in
  List.iter
    (fun d ->
      let failing =
        List.filter (fun (label, _) -> never_resumes label) (Types.resolve_row d.d_row).Types.labels
      in
      match failing with
      | entry :: _ ->
        errors
        := { span = d.d_span
           ; message =
               Printf.sprintf
                 "A deferred statement cannot fail, and this one can: '%s' never resumes, \
                  and would replace whatever is already unwinding. Handle it inside the \
                  'defer'."
                 (Types.entry Types.string_of_ty entry)
           }
           :: !errors
      | [] when d.d_open ->
        errors
        := { span = d.d_span
           ; message =
               "A deferred statement cannot fail, and this one calls through an effect \
                row its caller decides, which could hold an operation that never resumes."
           }
           :: !errors
      | [] -> ())
    (List.rev !deferred_rows);
  let errors =
    List.fold_left
      (fun errors ((label, _) as entry) ->
        { span =
            Option.value
              ~default:Source_map.Span.nowhere
              (Hashtbl.find_opt effect_sites label)
        ; message =
            Printf.sprintf
              "Unhandled effect '%s': no handler encloses this."
              (Types.entry Types.string_of_ty entry)
        }
        :: errors)
      !errors
      (Types.resolve_row ctx.row).Types.labels
  in
  match List.rev errors with
  | [] -> Ok (List.map resolve_stmt checked)
  | errors -> Error errors

let check ?(policy = strict) ~registry program =
  current := policy;
  Fun.protect ~finally:(fun () -> current := strict) (fun () -> check_with ~registry program)
