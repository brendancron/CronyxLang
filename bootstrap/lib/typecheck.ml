(* A node's type is not finished when it is first visited — `x` in
   `fn f(x) { return x + 1; }` is pinned at the `+` — so the tree is built with
   mutable types and resolved once at the end. *)

type error =
  { span : Ast.span
  ; message : string
  }

exception Located of error

(* Something only metaprocessing removes, met by a check. It ends the check
   rather than the statement: whatever follows would be checked without what
   it stood for. *)
exception Rejected of error

(* What the checker does where a name has nothing declared behind it:
   [unknown fail anything] either fails or answers with [anything ()]. *)
type policy = { unknown : 'a. (unit -> 'a) -> (unit -> 'a) -> 'a }

let strict = { unknown = (fun fail _ -> fail ()) }
let current = ref strict

(* The types made up for names nothing declared yet, and what calling one
   returns: a receiver of one of these is unknown because of a meta block, where
   any other unpinned receiver is ambiguous whatever a meta block does. *)
let unknowns : Types.infer_ty list ref = ref []

let unknown_ty () =
  let t = Types.fresh () in
  unknowns := t :: !unknowns;
  t

(* The unknowns an error already reported left behind: no instance is made at
   one, since what it generated could only fail a second time for the same
   mistake. *)
let erroneous : Types.infer_ty list ref = ref []

let erroneous_ty () =
  let t = unknown_ty () in
  erroneous := t :: !erroneous;
  t

(* By cell, not by node: unifying two variables links one to a fresh [IVar]
   around the other's cell, so the same variable has more than one node. *)
let among ts t =
  let same u =
    match Types.repr u, Types.repr t with
    | Types.IVar a, Types.IVar b -> a == b
    | u, t -> u == t
  in
  List.exists same ts

let is_unknown t = among !unknowns t
let is_erroneous t = among !erroneous t

(* Variables nothing can settle and nothing reads: what an operation, or a
   function that never returns, hands back to a call that ignores it, and what
   an error already reported left open. *)
let unobservable : (int, unit) Hashtbl.t = Hashtbl.create 16

let leave_open t =
  List.iter (fun (id, _) -> Hashtbl.replace unobservable id ()) (Types.free_vars t)

(* A result no parameter mentions is one the function never hands back:
   `compile_error` stops the build, an operation that never resumes unwinds. *)
let returns_nothing = function
  | Some { Types.quantified; body = Types.IFn (params, ret, _); _ } ->
    (match Types.repr ret with
     | Types.IVar { contents = Types.Unbound (id, _) } ->
       List.mem id quantified
       && not (List.exists (fun p -> List.mem_assoc id (Types.free_vars p)) params)
     | _ -> false)
  | _ -> false

(* Nothing handles the top level's row, and once a label is in it the row no
   longer says which call put it there, so each is recorded as it arrives. The
   checker finishes a node after its children, so the innermost one records it. *)
let top_row : Types.infer_row option ref = ref None
let effect_sites : (string, Source_map.Span.t) Hashtbl.t = Hashtbl.create 8

(* The root's body is the whole top level, so a statement in it that fails is
   reported where the session keeps its errors and the next one is checked, as
   if each were checked apart. *)
let root_errors : error list ref ref = ref (ref [])

(* The top-level `var`s whose initializers failed: a later statement reading one
   is not checked, since every error it gave would be the first one again. *)
let root_failed : (string, unit) Hashtbl.t = Hashtbl.create 8

(* The root's body as [root_block] checked it: each `var` an assignment to its
   global and each statement that throws under the catcher. A transform that
   takes the body apart is handed this, not the statements as written. *)
let root_rewritten : Ast.stmt list option ref = ref None


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

(* The row a trait's method performs when reached through a table: the one the
   trait wrote, or none. A copy made at an object calls through the table, and
   only the call's lowering learns that it was made at one. *)
let dynamic_rows : (string * string, Types.infer_row) Hashtbl.t = Hashtbl.create 16
let open_defer : deferred option ref = ref None

(* Where a handler's methods first perform each effect, while they are being
   checked, and then what such a handler performs outward: the methods are a
   value the run uses, so their effects reach the caller at the run, and an
   unhandled one is reported at the call inside the method instead. *)
let arm_sites : (string, Source_map.Span.t) Hashtbl.t option ref = ref None
let escaping_sites : (string, Source_map.Span.t) Hashtbl.t = Hashtbl.create 8

let note_effect_sites span row =
  (match !arm_sites with
   | Some sites ->
     List.iter
       (fun (label, _) -> if not (Hashtbl.mem sites label) then Hashtbl.add sites label span)
       (fst (Types.labels_of_infer_row row))
   | None -> ());
  match !top_row with
  | Some top when top == row ->
    List.iter
      (fun (label, _) ->
        if not (Hashtbl.mem effect_sites label)
        then
          let inside =
            match Hashtbl.find_opt escaping_sites label, !arm_sites with
            | (Some _ as found), _ -> found
            | None, Some sites -> Hashtbl.find_opt sites label
            | None, None -> None
          in
          Hashtbl.add effect_sites label (Option.value ~default:span inside))
      (fst (Types.labels_of_infer_row row))
  | _ -> ()

(* A receiver whose type is still a variable. Which impl answers is settled once
   it is not, from the dispatch. *)
type 'e bound_calls = [ `Bound_call of 'e * string * Types.infer_ty Ast.dispatch * 'e list ]

(* A value on its way into a trait-typed position. The concrete type is still on
   the inner expression's annotation; each slot the vtable owes names a method
   and the dispatch that picks the impl answering it, in the order the trait
   declared them. *)
type 'e coercions = [ `Coerce of 'e * string * (string * Types.infer_ty Ast.dispatch) list ]

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
  | checked_expr bound_calls
  | (checked_expr, Types.infer_ty) Ast.dyn_calls
  | checked_expr coercions
  | checked_expr Ast.variant_lit
  | checked_expr Ast.object_lit
  | (checked_expr, checked_stmt) Ast.lambdas
  (* A run's clauses are bound once it is checked, so it holds none. *)
  | `Run_block of (checked_expr, checked_stmt) Ast.valued_block
  | (checked_expr, checked_stmt) Ast.match_expr
  ]

and checked_stmt = (checked_stmt_kind, Types.infer_ty) Ast.node

and checked_stmt_kind =
  [ (checked_expr, checked_stmt) Ast.stmts
  | Ast.type_defs
  | (checked_expr, checked_stmt) Ast.matching
  | (checked_stmt, Types.infer_ty) Ast.method_defs
  ]

(* Hashed by offsets and the node's head: hashing a span hashes the whole text
   of its file. *)
module Physical = Hashtbl.Make (struct
    type t = Ast.expr

    let equal = ( == )
    let hash (e : Ast.expr) = Hashtbl.hash (Source_map.Span.offsets e.Ast.span, Hashtbl.hash_param 3 3 e.Ast.it)
  end)

module Physical_stmt = Hashtbl.Make (struct
    type t = Ast.stmt

    let equal = ( == )
    let hash (s : Ast.stmt) = Hashtbl.hash (Source_map.Span.offsets s.Ast.span, Hashtbl.hash_param 3 3 s.Ast.it)
  end)

type passed_code =
  | Passed_expr of checked_expr
  | Passed_stmts of checked_stmt list

type view =
  [ `Expr of Ast.expr
  | `Stmt of Ast.stmt
  | `Stmts of Ast.stmt list
  ]

(* Code checked once and passed through wherever it is moved: what it was
   checked to, what it performs, the code it was checked from (shown to a
   meta block that asks, and read by what looks for names), what it bound,
   and the names it reached. *)
type passed =
  { pc_code : passed_code
  ; pc_row : Types.infer_row
  ; pc_view : view
  ; pc_binds : (string * Types.scheme) list
  ; pc_uses : string list
  ; (* A function's whole body: what it returns. *)
    pc_returns : Types.infer_ty option
  ; pc_notes : notes
  ; mutable pc_shown : bool
  }

(* The type each expression was checked at, and each run with what it was
   lowered to: what a meta block asking about the code is shown. *)
and notes =
  { mutable n_types : (Ast.expr * Types.infer_ty) list
  ; mutable n_runs : (Ast.expr * Ast.expr) list
  }

let passed : (int, passed) Hashtbl.t = Hashtbl.create 64
let passed_count = ref 0

let pass_through p =
  incr passed_count;
  Hashtbl.replace passed !passed_count p;
  !passed_count

let passed_view n = Option.map (fun p -> p.pc_view) (Hashtbl.find_opt passed n)

let viewed_stmt n =
  match passed_view n with
  | Some (`Stmt s) -> Some s
  | Some (`Stmts body) -> Some (Ast.at Source_map.Span.nowhere (`Block body))
  | _ -> None

let noting : notes option ref = ref None

(* The notes of each pass-through shown so far. *)
let noted_types : Types.infer_ty Physical.t = Physical.create 256
let noted_runs : Ast.expr Physical.t = Physical.create 16

let shown_view n =
  match Hashtbl.find_opt passed n with
  | None -> None
  | Some p ->
    if not p.pc_shown
    then (
      p.pc_shown <- true;
      List.iter (fun (e, t) -> Physical.replace noted_types e t) (List.rev p.pc_notes.n_types);
      List.iter (fun (e, g) -> Physical.replace noted_runs e g) (List.rev p.pc_notes.n_runs));
    Some p.pc_view

(* What each meta block generated, so code holding one is shown, and checked
   again, as what it generated rather than run again. *)
let meta_stmts : Ast.stmt list Physical_stmt.t = Physical_stmt.create 16
let meta_exprs : Ast.expr Physical.t = Physical.create 16

(* Set while a recorded read leaves out what a final check would do, so the
   code it read cannot be passed through. *)
let read_only_partly = ref false

(* The statements of the block processed code was asked about, each with the
   pass-through it was checked to. *)
let kept_stmts : int Physical_stmt.t = Physical_stmt.create 16

(* The block processed code is being asked about. *)
let kept_block : Ast.stmt list option ref = ref None

(* The names reached while code that may be passed through is checked. *)
let reaching : string list ref option ref = ref None

type env =
  { bindings : (string, Types.scheme) Hashtbl.t
  ; parent : env option
  ; (* The bindings that may leave a variable free, which is all a
       generalization reads: a scheme whose every variable is quantified stays
       so, and the top level holds thousands of them. *)
    open_names : (string, unit) Hashtbl.t
  ; (* A meta block's top level: it reads the top level through [parent],
       except these names. *)
    hides : string list option
  }

type ctx =
  { registry : Registry.t
  ; mutable return_type : Types.infer_ty option
  ; mutable saw_return : bool
  ; mutable row : Types.infer_row
  ; (* What the statement being checked has to run ahead of itself, newest
       first. *)
    mutable hoisted : checked_stmt list
  ; (* What the function value taking control that the code stands in answers,
       which a continuation it is part of answers too. *)
    mutable handed_answer : Types.infer_ty option
  }

(* A function or method as the walk sees it: never checked as written, only at
   each key a use settles. [wd_vars] are the variables its signature was read
   with, impl parameters first. *)
type walk_decl =
  { wd_id : int
  ; wd_name : string
  ; wd_span : Ast.span
  ; wd_params : Ast.param list
  ; wd_sig : Ast.signature
  ; wd_body : Ast.stmt list
  ; wd_impl : ((string * Ast.type_expr list) option * string * Ast.type_param list) option
  ; wd_env : env
  ; wd_scheme : Types.scheme
  ; wd_vars : (string * Types.infer_ty) list
  ; wd_values : Ast.static_param list
  ; wd_local : bool
  ; (* The instance whose body declares a local function, which its own
       instances are named after: each instance of the owner declares it anew. *)
    wd_owner : string option
  }

type instance_view =
  { iv_name : string
  ; iv_ty : Types.infer_ty
  ; iv_walking : bool
  ; iv_ret_written : bool
  ; iv_key : Key.t
  }

(* What the walk asks of [Metaprocess], which owns the instances and runs the
   meta blocks. *)
type walk_ops =
  { instance : Ast.span -> walk_decl -> Key.t -> instance_view
  ; (* The run-time names around the block, and the type of an expression
       reading them, which is all a block may ask of one. *)
    meta : string list -> (Ast.expr -> Types.ty) -> Ast.stmt -> Ast.stmt list
  ; (* A meta block standing in the top level: what it generates is declared at
       the top level, and only its statements come back, for the root's body. *)
    top_meta : Ast.stmt -> Ast.stmt list
  ; meta_expr : string list -> (Ast.expr -> Types.ty) -> Ast.expr -> Ast.expr
  ; (* Inside a meta block the declaration is looked up when the block runs;
       outside one it is the literal of its value. *)
    declof :
      meta:bool -> Ast.span -> (walk_decl * Key.t) option -> string -> Ast.expr Ast.static_arg list option -> Ast.expr
  ; (* A quote, or a module's reflection, outside a meta block: the literal of
       its value, which the program builds at run time. *)
    quoted : Ast.expr -> Ast.expr
  ; moduleof : Ast.span -> string -> string -> Ast.expr
  ; typeof : Ast.span -> Types.ty -> string option -> Ast.expr
  ; (* Runs what it is given without counting what it reaches as used. *)
    unused : (unit -> Types.infer_ty) -> Types.infer_ty
  ; wake : string -> unit
  ; unknown : string -> Ast.span -> unit
  ; unknown_method : string -> Ast.span -> unit
  ; static_value : string -> Ast.expr Ast.static_arg -> Ast.expr * string
  ; generic_new : Ast.expr -> Ast.expr
  ; (* The copy of each closed use of a plain generic type this one makes. *)
    copies_of : Types.ty -> unit
  ; performs_gen : walk_decl -> bool
  ; instances_of : walk_decl -> checked_stmt list
  ; (* `EffectHandler<E, _>` for the effect named, made through the library's
       trait; [None] where the library does not declare it. *)
    effect_handler : Ast.span -> string -> string option
  ; (* A handler's method made a function of the top level, under this name. *)
    lift : string -> checked_stmt -> unit
  ; refer : string -> unit
  }

(* An instance of a trait whose body runs a meta block is named for its
   arguments, `Getter<Int>`, and is in scope wherever `Getter` is. *)
let written_trait name =
  match String.index_opt name '<' with
  | Some at -> String.sub name 0 at
  | None -> name

let walk_ops : walk_ops option ref = ref None

let ops () =
  match !walk_ops with
  | Some ops -> ops
  | None -> invalid_arg "Typecheck.ops: not walking"

let walking () = Option.is_some !walk_ops

(* While a meta block's code is checked, and whatever it reaches: a function
   that runs a `gen` may be called there. *)
let in_meta = ref false

(* While [processed] checks code a meta block asked about: each expression,
   with the type it was given. *)
let recording : (Ast.expr * Types.infer_ty) list ref option ref = ref None

(* Whether this check is what the code will run as: a recorded read leaves the
   rest to the check of what the meta block generates. *)
let final_read () =
  Option.is_none !recording
  ||
  (read_only_partly := true;
   false)


(* Where the meta block being run stands: what [processed] checks the block's
   code against. *)
let meta_scope : (env * ctx) option ref = ref None

let in_scope env ctx f =
  let previous = !meta_scope in
  meta_scope := Some (env, ctx);
  Fun.protect ~finally:(fun () -> meta_scope := previous) f

(* By name, each with the scheme it was bound by: a name means the declaration
   only where [lookup] still finds that very scheme, so a local shadowing it
   does not. *)
let walk_decls : (string, (Types.scheme * walk_decl) list) Hashtbl.t = Hashtbl.create 64
let walk_decl_count = ref 0

(* The local functions a block declared, so the block can hold their instances. *)
let walk_locals : walk_decl list ref = ref []

let checking_instance : string option ref = ref None

(* A type declared in a body has its name only there, but its impls' methods
   are that body's functions: an instance whose key holds one is checked in the
   block declaring it and emitted into that block, not the one being walked,
   since a later use of the same instance may stand anywhere the type can.
   [active_blocks] says the type has not escaped: a value of it returned out of
   its body reaches an instance at the top level as before. *)
let local_type_home : (string, env) Hashtbl.t = Hashtbl.create 8
let active_blocks : env list ref = ref []
let local_instances : (env * checked_stmt) list ref = ref []

let home_of_key (key : Key.t) =
  let rec in_ty (t : Types.ty) =
    match t with
    | Types.Named (n, ts) | Types.Sum (n, ts) ->
      (match Hashtbl.find_opt local_type_home n with
       | Some env when List.memq env !active_blocks -> Some env
       | _ -> List.find_map in_ty ts)
    | Types.Tuple ts | Types.Pack ts -> List.find_map in_ty ts
    | Types.Spread t -> in_ty t
    | Types.Fn (ps, r, _) -> List.find_map in_ty (r :: ps)
    | _ -> None
  in
  List.find_map
    (fun (_, arg) ->
      match arg with
      | Key.Type t -> in_ty t
      | _ -> None)
    key

(* An effect a run bound, innermost first: what the code being checked reaches
   it through. [bd_value] is the name the handler's value has here, the run's
   own variable or an instance's leading parameter, and [None] for a handler
   with no value. *)
type binding =
  { bd_label : string
  ; bd_handler : string
  ; bd_value : string option
  ; (* What was bound outside the run: a named handler's methods are reached
       from there, as an inline one's are checked there. *)
    bd_outer : binding list
  ; (* In an instance whose key names this binding's handler: that name. *)
    bd_key : string option
  }

let effect_bindings : binding list ref = ref []

(* The evidence a function is handed: a record holding, by label, the handler
   of each effect the function's type performs. A function whose type performs
   nothing takes none, and a call passes it last, after any continuation, so a
   closure taking none ignores it. *)
let evidence = Ast.generated [ "ev"; "h" ]

(* A function's own frame: every label nothing inside the function binds is
   answered by the evidence its caller handed it. *)
let own_frame = { bd_label = ""; bd_handler = ""; bd_value = Some evidence; bd_outer = []; bd_key = None }

let is_own b = String.equal b.bd_label ""

(* The top level's own frame, and that of each instance a call there reaches:
   its evidence comes from the program root's run, so an operation it answers
   is the handler that run binds, once that run is checked. A key holds it
   once, for every label nothing nearer binds. *)
let root_key = "root"
let root_label = "*"
let root_frame = { own_frame with bd_key = Some root_key }

(* The bindings the program root's run hands its body: what [root_frame]
   answers. *)
let root_bindings : binding list option ref = ref None
let root_param : string option ref = ref None

(* The program root's instances, its call of the top level, and whether the
   top level, once processed, reads no evidence: then it is handed none. *)
let root_instances : (string, unit) Hashtbl.t = Hashtbl.create 2
let root_call : (checked_expr_kind, Types.infer_ty) Ast.node option ref = ref None
let root_main_bare = ref false
let program_root_body = ref false

let binding_for label bindings =
  List.find_opt (fun b -> is_own b || String.equal b.bd_label label) bindings

(* The bindings each call and each operation was checked under, read once the
   statement ends, when the callee's type finally says what it performs. *)
module Checked_table = Hashtbl.Make (struct
    type t = (checked_expr_kind, Types.infer_ty) Ast.node

    let equal = ( == )

    let hash (e : t) = Hashtbl.hash (Source_map.Span.offsets e.Ast.span)
  end)

let bindings_at : binding list Checked_table.t = Checked_table.create 256

(* Generated code a transform made: continuations, joins and loops. Each is
   marked by a static parameter of this name, binds what it performs where it
   is written, and takes no evidence. *)
let plain_marker = Ast.plain_marker

let is_plain (sg : Ast.signature) =
  List.exists (fun (p : Ast.static_param) -> String.equal p.Ast.sp_name plain_marker) sg.Ast.static_params

let plain_only (sg : Ast.signature) =
  { sg with
    Ast.static_params =
      List.filter (fun (p : Ast.static_param) -> String.equal p.Ast.sp_name plain_marker) sg.Ast.static_params
  }

let plain_signature =
  { Ast.ret = None; row = None; static_params = [ { Ast.sp_name = plain_marker; sp_ty = None; sp_pack = false } ]; inline = false }

let unmarked (sg : Ast.signature) =
  { sg with
    Ast.static_params =
      List.filter
        (fun (p : Ast.static_param) ->
          not
            (String.equal p.Ast.sp_name plain_marker
             || String.equal p.Ast.sp_name Ast.handed_marker
             || String.equal p.Ast.sp_name Ast.handed_method_marker))
        sg.Ast.static_params
  }

(* The type of each handler's value, by the handler's name. A handler not here
   has no value. *)
let handler_values : (string, Types.infer_ty) Hashtbl.t = Hashtbl.create 8

let handler_count = ref 0

(* What a run's own handler's value is checked against, made afresh at each
   check. *)
let handler_signatures :
  (string, unit -> Types.infer_ty * Types.infer_row * (string * (string * Types.infer_ty) list) list) Hashtbl.t
  =
  Hashtbl.create 8

let handler_labels : (string, string) Hashtbl.t = Hashtbl.create 8

(* The named handlers an operation was answered through, which `with` binds
   whatever the body's row says. *)
let used_handlers : (string, unit) Hashtbl.t = Hashtbl.create 8

(* [label] leaves [row] where it is in it; a row open where it is not is left
   as it is, rather than made to perform it. *)
let rec discharged label args (row : Types.infer_row) =
  match Types.repr_row row with
  | Types.RCons (l, found, rest) when String.equal l label ->
    (try List.iter2 Types.unify args found with
     | Invalid_argument _ | Types.Type_error _ -> ());
    rest
  | Types.RCons (l, found, rest) -> Types.RCons (l, found, discharged label args rest)
  | r -> r

(* The value of a named handler is checked calling its impl's methods: the
   type and the effect each such value was made for. *)
let named_handlers : (string, string * string) Hashtbl.t = Hashtbl.create 8

(* What the methods that take control in the run being transformed perform. *)
let arm_rows : Types.infer_row list ref = ref []

(* The arguments of the effect a bound run's clause binds, by handler and
   effect: a run inside another binding the same effect at other arguments
   leaves the outer one's to it. *)
let bound_arguments : (string * string, Types.infer_ty list) Hashtbl.t = Hashtbl.create 8

(* The run the check just lowered, and, while processed code is being read,
   each run with what it was lowered to: processed code shows that in the
   run's place, so a transform around it never transforms it again. *)
let last_lowered : Ast.expr option ref = ref None

let expansions : (Ast.expr * Ast.expr) list ref option ref = ref None

let handler_param = Ast.handler_param

(* A function named as a value, before the expression around it settles which
   instance it is. Its node carries [p_placeholder] until then. *)
type pending =
  { p_span : Ast.span
  ; p_decl : walk_decl
  ; p_vars : (string * Types.infer_ty * Types.infer_row option) list
  ; p_ty : Types.infer_ty
  ; p_placeholder : string
  }

let pending_values : pending list ref = ref []

(* The traits an instance's static parameters were bounded by, and their
   supertraits. A generic body reached a method through the bound, which the
   file need not import; at a key the receiver is concrete, and the bound still
   says which trait it meant. *)
let bound_traits : (string * string list option) list ref = ref []

let placeholders : (string, string) Hashtbl.t = Hashtbl.create 16
let placeholder_count = ref 0

type effect_info =
  { ops : (string, Ast.op_decl) Hashtbl.t
  ; declared : (string, Ast.op_decl list) Hashtbl.t
  }

let ctx_effects = { ops = Hashtbl.create 16; declared = Hashtbl.create 8 }

(* Operations share one namespace, so a second declaration would silently
   overwrite the first and every call site be checked against it. *)
let ctx_op_owner : (string, string) Hashtbl.t = Hashtbl.create 16

(* Where a call can name the handler of an effect whose operations are all
   plain functions, the instance it reaches is keyed by that handler and calls
   it directly. An effect taking control is the library transform's. *)
let evidence_passed label =
  match Hashtbl.find_opt ctx_effects.declared label with
  | Some ops -> List.for_all (fun (o : Ast.op_decl) -> o.Ast.op_kind = Ast.Op_fn) ops
  | None -> false

let run_count = ref 0
let active_runs : int list ref = ref []

(* The run each handler belongs to: an instance calling an inline handler's
   method through its value is emitted in that run's block, which is where the
   value is in scope. *)
let handler_run : (string, int) Hashtbl.t = Hashtbl.create 16

(* By the name a key gives it: the binding an instance at that key answers the
   effect through, and the innermost run the instance has to be emitted in. *)
let keyed_handlers : (string, binding * (int * string) option) Hashtbl.t = Hashtbl.create 16

let run_instances : (int * checked_stmt) list ref = ref []

(* An inline handler's method that reads nothing of where its run stands and
   performs nothing, by handler and method: the function of the top level it
   became, and that function's type. *)
let lifted_methods : (string * string, string * Types.infer_ty) Hashtbl.t = Hashtbl.create 16
let lifted_handlers : (string, unit) Hashtbl.t = Hashtbl.create 16

(* Each such function as checked, and once processed: a call is inlined from
   the processed body, which the function's own emission then reuses. *)
let lifted_checked : (string, checked_stmt) Hashtbl.t = Hashtbl.create 16
let lifted_processed : (string, Ast.resolved_stmt list) Hashtbl.t = Hashtbl.create 16

(* Set when a call reads a run's handler value: code reading one reads where
   that run stands. *)
let read_handler_value = ref false
let reading_handlers : (string, unit) Hashtbl.t = Hashtbl.create 16

let binds_in_run handler =
  match !active_runs with
  | run :: _ -> Hashtbl.replace handler_run handler run
  | [] -> ()

let key_name b = Option.value ~default:b.bd_handler b.bd_key

let innermost a b =
  match a, b with
  | Some (x, _), Some (y, _) -> if x >= y then a else b
  | Some _, None -> a
  | None, _ -> b

(* What a key names for each effect a run bound around the call, up to the
   evidence of the function the call is in. *)
let rec known_handlers bindings : (string * string) list =
  let seen = Hashtbl.create 4 in
  (* The root answers what nothing nearer binds, so a nearer handler no key can
     name leaves the root's out of it. *)
  let shadowed = ref false in
  let rec go = function
    | [] -> []
    | b :: _ when String.equal b.bd_label "" && b.bd_key = Some root_key ->
      if !shadowed then [] else [ root_label, root_key ]
    | b :: _ when String.equal b.bd_label "" -> []
    | b :: rest when Hashtbl.mem seen b.bd_label -> go rest
    | b :: rest ->
      Hashtbl.replace seen b.bd_label ();
      (match keyed_handler b with
       | Some id -> (b.bd_label, id) :: go rest
       | None ->
         if evidence_passed b.bd_label then shadowed := true;
         go rest)
  in
  go bindings

and keyed_handler b =
  if not (evidence_passed b.bd_label)
  then None
  else if Option.is_some b.bd_key
  then b.bd_key
  else (
    (* A run the transform takes apart is checked as written, then as what the
       transform made, which binds the same handlers again in another run and
       is the one emitted. What was made under the first belongs to a block
       that is not, and is checked as written: the name a key gives a handler
       is also the run binding it. *)
    match b.bd_value, Hashtbl.find_opt handler_run b.bd_handler with
    | Some v, _ when String.equal v (Ast.handler_param b.bd_label) -> None
    | Some _, None -> None
    | Some _, Some run when Hashtbl.mem named_handlers b.bd_handler ->
      let id = b.bd_handler ^ "@" ^ string_of_int run in
      (* A named handler's methods are its impl's, reached from where its run
         stands, so it lives wherever what is bound there does. *)
      let home =
        List.fold_left
          (fun home (_, id) -> innermost home (Option.bind (Hashtbl.find_opt keyed_handlers id) snd))
          None
          (known_handlers b.bd_outer)
      in
      Hashtbl.replace keyed_handlers id ({ b with bd_value = None; bd_key = Some id }, home);
      Some id
    | Some _, Some run when Hashtbl.mem handler_values b.bd_handler ->
      let id = b.bd_handler ^ "@" ^ string_of_int run in
      let home = if Hashtbl.mem lifted_handlers b.bd_handler then None else Some (run, id) in
      Hashtbl.replace keyed_handlers id ({ b with bd_key = Some id }, home);
      Some id
    | _ -> None)

(* The labels each instance answered, by its declaration and its key without
   its handlers: what the key of a later call at those types keeps of the
   handlers around it. *)
let answered_labels : (int * string, string list) Hashtbl.t = Hashtbl.create 64

(* A key whose handlers are those the instance made under a wider key used:
   the same instance. *)
let handler_alias : (int * string, Key.t) Hashtbl.t = Hashtbl.create 64

let walking_keys : (int, Key.t list) Hashtbl.t = Hashtbl.create 16

(* While a function a transform made is checked: it binds what it performs
   where it is written, so it sees its caller's runs, but it is emitted at the
   top level, outside them. *)
let in_plain = ref 0

(* While an instance is checked: the labels it answered through its key. *)
let keyed_used : (string, unit) Hashtbl.t list ref = ref []

let note_keyed b =
  match b.bd_key, !keyed_used with
  | Some _, used :: _ -> Hashtbl.replace used b.bd_label ()
  | _ -> ()

let without_handlers (key : Key.t) =
  List.filter
    (fun (_, a) ->
      match a with
      | Key.Handler _ -> false
      | _ -> true)
    key

(* The instance that `declof` last showed, by the name it showed it under: a
   transform reading that body to copy it reads it under the handlers the
   instance was made under, so what it reaches is the instances already made. *)
let declof_shown : (string * Key.t) option ref = ref None

let key_handlers (key : Key.t) =
  List.filter_map
    (fun (l, a) ->
      match a with
      | Key.Handler h -> Some (l, h)
      | _ -> None)
    key

(* What a keyed instance's body is checked under: the bindings its key names,
   then its own frame, or the root's when the key names the root. *)
let key_frames (key : Key.t) =
  List.filter_map (fun (_, h) -> Option.map fst (Hashtbl.find_opt keyed_handlers h)) (key_handlers key)
  @ [ (if List.mem_assoc root_label (key_handlers key) then root_frame else own_frame) ]

(* What of [handlers] an instance answering [answered] reads: the root's,
   only while some label it performs is answered by evidence. *)
let narrowed answered handlers =
  let named = List.filter (fun (l, _) -> not (String.equal l root_label)) handlers in
  let kept = List.filter (fun (l, _) -> List.mem l answered) named in
  if List.mem_assoc root_label handlers
     && List.exists (fun l -> evidence_passed l && not (List.mem_assoc l named)) answered
  then kept @ [ root_label, root_key ]
  else kept

(* The run an instance at [key] is emitted in: the innermost of those whose
   handlers' values it reads. *)
let handler_home (key : Key.t) =
  Option.map
    fst
    (List.fold_left
       (fun home (_, id) -> innermost home (Option.bind (Hashtbl.find_opt keyed_handlers id) snd))
       None
       (key_handlers key))

(* A call of an operation is named after its trait by the loader, which never
   sees a trait a meta block generates: a name nothing else binds is that
   trait's operation when exactly one trait has a method of the name. *)
(* Every declared effect trait with an operation [name], as the trait. *)
let operation_owners name =
  Hashtbl.fold
    (fun op owner acc -> if String.equal op (Ast.operation_name owner name) then owner :: acc else acc)
    ctx_op_owner
    []

let bare_operation name =
  match operation_owners name with
  | [ owner ] -> Some (Ast.operation_name owner name)
  | _ -> None

let ctx_effect_params : (string, (string * Types.infer_ty) list) Hashtbl.t =
  Hashtbl.create 8

let takes_control_label label =
  List.exists
    (fun (o : Ast.op_decl) -> o.Ast.op_kind <> Ast.Op_fn)
    (Option.value ~default:[] (Hashtbl.find_opt ctx_effects.declared label))

(* The effects of a function type whose operations take control: a value of
   that type takes a handler for each, in this order, after the parameters
   the type shows, then what [Core.handed] lists. *)
let controlling labels =
  (* By the name as shown, which is what the library's transform orders them
     by: it never sees a module's prefix. *)
  let shown l =
    match String.rindex_opt l '#' with
    | Some at -> String.sub l (at + 1) (String.length l - at - 1)
    | None -> l
  in
  List.sort_uniq
    (fun a b ->
      match String.compare (shown a) (shown b) with
      | 0 -> String.compare a b
      | c -> c)
    (List.filter takes_control_label labels)

let controlling_row (row : Types.infer_row) = controlling (List.map fst (fst (Types.labels_of_infer_row row)))

let controlling_ty (t : Types.ty) =
  match t with
  | Types.Fn (_, _, row) -> controlling (List.map fst row.Types.labels)
  | _ -> []

let marked marker (sg : Ast.signature) =
  List.exists (fun (p : Ast.static_param) -> String.equal p.Ast.sp_name marker) sg.Ast.static_params

let is_handed = marked Ast.handed_marker
let is_handed_method = marked Ast.handed_method_marker

(* The library's declarations of what its transform hands what it makes, as
   [hoist] read them. *)
let shapes : (string, Types.scheme * Ast.param list * Ast.stmt list) Hashtbl.t = Hashtbl.create 2

let shape name =
  match Hashtbl.find_opt shapes name with
  | Some s -> s
  | None -> Types.error "The standard library declares no '%s', which says what its transform makes." name

(* A shape [(value: R, handed…): <P> A] read at what the item returns, what a
   call to it answers and what it performs: the parameters it is handed. *)
let handed_params name ~result ~answer ~row =
  let scheme, _, _ = shape name in
  (* Every use its own: a hoisted scheme leaves its rows to each instance. *)
  let body = scheme.Types.body in
  let whole =
    { scheme with Types.quantified = List.map fst (Types.free_vars body); quantified_rows = Types.free_row_vars body }
  in
  match Types.instantiate whole with
  | Types.IFn (value :: handed, a, r) ->
    Types.unify value result;
    Types.unify a answer;
    Types.unify_row r row;
    handed
  | _ -> Types.error "'%s' takes no parameter for what its item returns." name

let handed_count name =
  let _, params, _ = shape name in
  max 0 (List.length params - 1)

let method_shape (o : Ast.op_decl) = if Ast.aborts o.Ast.op_attrs then Core.handed_abort else Core.handed_method

(* The effect a parameter named for its handler holds the handler of. *)
let handled_by name =
  let prefix = Ast.handler_param "" in
  let n = String.length prefix in
  if String.length name > n && String.equal (String.sub name 0 n) prefix
  then (
    let label = String.sub name n (String.length name - n) in
    if Hashtbl.mem ctx_effects.declared label then Some label else None)
  else None

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

(* Each impl's own parameters, for `implements`, which checks their bounds
   against the type's arguments. *)
let ctx_impl_params : (string * string, Ast.type_param list) Hashtbl.t = Hashtbl.create 8

(* What an impl asks of the type's own arguments, `impl Shout for Box<T: Display>`
   asking `Display` of argument 0, beside the trait arguments that name that impl
   in [ctx_impls]: matching an impl without them finds it for `Box<Point>`, and
   the mistake surfaces in whatever body later calls `shout`. *)
let ctx_impl_bounds : (string * string, Types.infer_ty list * (int * string) list) Hashtbl.t = Hashtbl.create 8

(* So a call site can ask whether the name still refers to it rather than
   testing the spelling: a program declaring its own `print` gets its own. *)
let ctx_variadic : (string, Types.scheme * Types.infer_ty) Hashtbl.t = Hashtbl.create 4
let ctx_methods : (string * string, unit) Hashtbl.t = Hashtbl.create 32

(* What each instance of a trait whose body runs a meta block was made from:
   the trait, and each argument, [None] where the instance keeps the slot open.
   An impl names the instance, and `with` needs the arguments it was given. *)
let trait_instances : (string, string * Ast.type_expr option list) Hashtbl.t = Hashtbl.create 8

(* A named handler's method that takes control is handed the rest of a run's
   body, whose effects are that run's to say: its continuation is read as
   performing a row of its own, `(A) -> <ρ> R`, which each call settles, as a
   handler written inline gets one. *)
(* Compared physically: a binding of the same name nearer the call, or the
   parameter of a function the continuation was passed to, is another
   binding, and `discontinue` is only ever rewritten for the method's own. *)
let continuation_params : Ast.param list ref = ref []
let continuations : Types.scheme list ref = ref []
let builtin_discontinue : Types.scheme option ref = ref None

let note_continuation_param (p : Ast.param) =
  if not (List.memq p !continuation_params) then continuation_params := p :: !continuation_params

let handled_effect (trait : (string * Ast.type_expr list) option) =
  match trait with
  | Some (t, args) when String.equal t Core.effect_handler ->
    (match args with
     | { Ast.it = Ast.Ty_name e | Ast.Ty_app (e, _); _ } :: _ -> Some e
     | _ -> None)
  | Some (t, _) ->
    (match Hashtbl.find_opt trait_instances t with
     | Some (base, Some { Ast.it = Ast.Ty_name e | Ast.Ty_app (e, _); _ } :: _)
       when String.equal base Core.effect_handler ->
       Some e
     | _ -> None)
  | None -> None

let open_continuation (trait : (string * Ast.type_expr list) option) (m : (Ast.stmt, unit) Ast.method_def) =
  let takes_control e =
    match Hashtbl.find_opt ctx_effects.ops (Ast.operation_name e m.Ast.md_name) with
    | Some op -> op.Ast.op_kind <> Ast.Op_fn
    | None -> false
  in
  match handled_effect trait, List.rev m.Ast.md_params with
  | Some e, ({ Ast.ty = Some ({ Ast.it = Ast.Ty_fn (ps, r, []); _ } as k); _ } as last) :: before when takes_control e ->
    let row = Ast.generated [ "resumes"; m.Ast.md_name ] in
    { m with
      Ast.md_params = List.rev ({ last with Ast.ty = Some { k with Ast.it = Ast.Ty_fn (ps, r, [ row, [] ]) } } :: before)
    ; md_signature =
        { m.Ast.md_signature with
          Ast.static_params =
            m.Ast.md_signature.Ast.static_params @ [ { Ast.sp_name = row; sp_ty = None; sp_pack = false } ]
        }
    }
  | _ -> m

let note_continuation trait (m : (Ast.stmt, unit) Ast.method_def) =
  match handled_effect trait, List.rev m.Ast.md_params with
  | Some e, last :: _ ->
    (match Hashtbl.find_opt ctx_effects.ops (Ast.operation_name e m.Ast.md_name) with
     | Some op when op.Ast.op_kind <> Ast.Op_fn && not (Ast.aborts op.Ast.op_attrs) -> note_continuation_param last
     | _ -> ())
  | _ -> ()

(* Functions whose last parameter is variadic: how many come before it, and
   whether what it collects into is a pack's tuple rather than an array. Keyed
   by bare name and read from anywhere, so one written inside a block is found
   the same as one written at the top: missing it is silently an ordinary
   function taking an array. *)
let ctx_variadic_arity : (string, int * bool) Hashtbl.t = Hashtbl.create 8

(* What a declaration was written with: no later tree can hold the wrapper.

   Only a type is recorded. `typeof(T).attrs` is the one reader and it keys by
   type name, so recording a function or a variable under the same key would
   collide rather than answer -- and nothing can ask for those yet, because
   `typeof` takes a value and a function value's type names no declaration. *)
let decl_attrs : (string, Ast.attr list) Hashtbl.t = Hashtbl.create 8

(* The attributes are recorded and the wrapper dropped: nothing after this
   pass has a type that could carry one. *)
let rec unattributed (s : Ast.stmt) =
  match s.Ast.it with
  | `Attributed (attrs, inner) ->
    (match inner.Ast.it with
     | `Type_decl (name, _, _) -> Hashtbl.replace decl_attrs name attrs
     | _ -> ());
    unattributed inner
  | _ -> s

let variadic_arity (params : Ast.param list) =
  match List.rev params with
  | { Ast.ty = Some { it = Ast.Ty_variadic { it = Ast.Ty_spread _; _ }; _ }; _ } :: before ->
    Some (List.length before, true)
  | { Ast.ty = Some { it = Ast.Ty_variadic _; _ }; _ } :: before -> Some (List.length before, false)
  | _ -> None

(* What a whole program names from anywhere in it. *)
let gather (program : Ast.stmt list) =
  let rec collect (s : Ast.stmt) =
    (match s.Ast.it with
     | `Fn (name, params, _, _) ->
       Option.iter (Hashtbl.replace ctx_variadic_arity name) (variadic_arity params)
     | _ -> ());
    List.iter collect (children s)
  and children (s : Ast.stmt) =
    match s.Ast.it with
    | `Pre_checked n -> Option.to_list (viewed_stmt n)
    | `Attributed (_, inner) -> [ inner ]
    | `Type_members (decl, members) | `Trait_members (decl, members) -> decl :: members
    | `Block body | `Fn (_, _, _, body) | `Meta body -> body
    | `Defer inner | `Gen inner -> [ inner ]
    | `If (_, t, e) -> t :: Option.to_list e
    | `While (_, body) -> [ body ]
    | `For_in (_, _, body) -> [ body ]
    | `Match (_, cases) -> List.concat_map snd cases
    | `Impl_decl (_, _, _, body) ->
      List.concat_map (fun (m : (Ast.stmt, unit) Ast.method_def) -> m.Ast.md_body) body.Ast.ib_methods
    | `Expr _ | `Var_decl _ | `Var_tuple _ | `Return _ | `Break | `Continue | `Import _
    | `Global_import _ | `Derive _ | `Type_decl _ | `Trait_decl _ -> []
  in
  List.iter collect program

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
  and impl_params = snapshot ctx_impl_params
  and impl_bounds = snapshot ctx_impl_bounds
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
      restore ctx_impl_params impl_params;
      restore ctx_impl_bounds impl_bounds;
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
  Hashtbl.reset ctx_impl_params;
  Hashtbl.reset ctx_impl_bounds;
  Hashtbl.reset ctx_variadic;
  Hashtbl.reset ctx_methods;
  Hashtbl.reset ctx_type_params;
  Hashtbl.reset ctx_fn_params;
  param_rows := []

let new_env parent = { bindings = Hashtbl.create 16; parent; open_names = Hashtbl.create 16; hides = None }

let closed_scheme (scheme : Types.scheme) =
  List.for_all (fun (id, _) -> List.mem id scheme.Types.quantified) (Types.free_vars scheme.Types.body)
  && List.for_all (fun id -> List.mem id scheme.Types.quantified_rows) (Types.free_row_vars scheme.Types.body)
  && List.for_all (fun id -> List.mem id scheme.Types.quantified_fields) (Types.free_field_vars scheme.Types.body)

let bind env name scheme =
  Hashtbl.replace env.bindings name scheme;
  if closed_scheme scheme then Hashtbl.remove env.open_names name else Hashtbl.replace env.open_names name ()

let bind_param env (p : Ast.param) ty =
  let scheme = Types.mono ty in
  if List.memq p !continuation_params then continuations := scheme :: !continuations;
  bind env p.Ast.name scheme

let rec lookup env name =
  match Hashtbl.find_opt env.bindings name with
  | Some scheme -> Some scheme
  | None when Option.fold ~none:false ~some:(List.mem name) env.hides -> None
  | None ->
    (match env.parent with
     | Some p -> lookup p name
     | None -> None)

let handed_continuation env (e : Ast.expr) =
  match e.Ast.it with
  | `Var k -> Option.fold ~none:false ~some:(fun s -> List.memq s !continuations) (lookup env k)
  | _ -> false

let decl_of env name =
  if not (walking ())
  then None
  else (
    (ops ()).wake name;
    match lookup env name with
    | None -> None
    | Some scheme ->
      Option.map
        snd
        (List.find_opt
           (fun (s, _) -> s == scheme)
           (Option.value ~default:[] (Hashtbl.find_opt walk_decls name))))

let top_level env = Option.is_none env.parent || Option.is_some env.hides

let note_walk_decl env ~name ~scheme ~vars ~values ~params ~sg ~body ~impl ~span =
  if walking ()
  then (
    incr walk_decl_count;
    let d =
      { wd_id = !walk_decl_count
      ; wd_name = name
      ; wd_span = span
      ; wd_params = params
      ; wd_sig = sg
      ; wd_body = body
      ; wd_impl = impl
      ; wd_env = env
      ; wd_scheme = scheme
      ; wd_vars = vars
      ; wd_values = values
      ; wd_local = not (top_level env)
      ; wd_owner = (if top_level env then None else !checking_instance)
      }
    in
    Hashtbl.replace
      walk_decls
      name
      ((scheme, d) :: Option.value ~default:[] (Hashtbl.find_opt walk_decls name));
    if d.wd_local then walk_locals := d :: !walk_locals)

(* What a meta block standing here cannot see: everything bound below the top
   level. *)
let runtime_names env =
  let rec go env acc =
    match env.parent with
    | _ when top_level env -> acc
    | None -> acc
    | Some parent -> go parent (Hashtbl.fold (fun name _ acc -> name :: acc) env.bindings acc)
  in
  go env []

let shown_name name =
  match String.rindex_opt name '#' with
  | Some at -> String.sub name (at + 1) (String.length name - at - 1)
  | None -> name

(* Each inline handler's arm for an operation that does not take control, by
   the method's name. Its own row is the one to read: the record it is a field
   of says nothing of what an outer run's binding handles. *)
let plain_arms : string Physical.t = Physical.create 16

let plain_arm_controls span arm label =
  raise
    (Located
       { span
       ; message =
           Printf.sprintf
             "A handler's '%s' performs '%s', which takes control; '%s' is a plain operation, so its handler \
              must return. Mark it `@ctl` if it should take control."
             arm
             (shown_name label)
             arm
       })

(* Generalization must not quantify a variable the enclosing scope still uses. *)
let env_free env =
  let vars = ref [], Hashtbl.create 64
  and rows = ref [], Hashtbl.create 64
  and fields = ref [], Hashtbl.create 16 in
  let add (acc, seen) quantified id =
    if (not (List.mem id quantified)) && not (Hashtbl.mem seen id)
    then (
      Hashtbl.replace seen id ();
      acc := id :: !acc)
  in
  let rec walk hides env =
    let settled = ref [] in
    Hashtbl.iter
      (fun name () ->
        match Hashtbl.find_opt env.bindings name with
        | _ when List.mem name hides -> ()
        | None -> settled := name :: !settled
        | Some scheme ->
          let free_vars = List.filter (fun (id, _) -> not (List.mem id scheme.Types.quantified)) (Types.free_vars scheme.Types.body)
          and free_rows = List.filter (fun id -> not (List.mem id scheme.Types.quantified_rows)) (Types.free_row_vars scheme.Types.body)
          and free_fields =
            List.filter (fun id -> not (List.mem id scheme.Types.quantified_fields)) (Types.free_field_vars scheme.Types.body)
          in
          if free_vars = [] && free_rows = [] && free_fields = []
          then settled := name :: !settled
          else (
            List.iter (fun (id, _) -> add vars [] id) free_vars;
            List.iter (add rows []) free_rows;
            List.iter (add fields []) free_fields))
      env.open_names;
    List.iter (Hashtbl.remove env.open_names) !settled;
    Option.iter (walk (Option.value ~default:[] env.hides @ hides)) env.parent
  in
  walk [] env;
  !(fst vars), !(fst rows), !(fst fields)

(* An unknown is never quantified: each use would instantiate a fresh variable,
   and a fresh variable is no longer known to be unknown. *)
let env_free_all env =
  let vars, rows, fields = env_free env in
  vars @ List.concat_map (fun u -> List.map fst (Types.free_vars u)) !unknowns, rows, fields

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

let is_trait name = Hashtbl.mem ctx_traits name

(* What a table for the trait owes a slot for, its supertraits' included. *)
let methods_of trait =
  List.concat_map
    (fun t ->
      match Hashtbl.find_opt ctx_traits t with
      | Some (_, body) -> List.map (fun (m : Ast.method_sig) -> m.Ast.ms_name) body.Ast.tb_methods
      | None -> [])
    (trait_closure trait)

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
(* The functions and methods hoisted and not yet generalized, by name, each
   with the scheme it was hoisted as. *)
let unchecked : (string, Types.scheme option) Hashtbl.t = Hashtbl.create 64

(* A local spelled like an unchecked function is not it: a parameter named
   `main` called where the program declares `fn main` would otherwise have its
   row postponed to that function's. *)
let calls_unchecked name (callee : Types.scheme option) =
  match Hashtbl.find_opt unchecked name, callee with
  | Some (Some hoisted), Some scheme -> hoisted == scheme
  | Some _, _ -> true
  | None, _ -> false

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

(* What a call performs of [row], less each label only a parameter of the
   callee's names that nothing settled and the caller does not carry: the key
   would default that parameter, and the call performs no such effect. *)
let undefaulted env (callee : Types.infer_ty) row (caller : Types.infer_row) =
  let rec outside acc (t : Types.infer_ty) =
    match Types.repr t with
    | Types.IVar { contents = Types.Unbound (id, _) } -> id :: acc
    | Types.ITuple ts | Types.IPack ts | Types.INamed (_, ts) | Types.ISum (_, ts) -> List.fold_left outside acc ts
    | Types.ISpread t -> outside acc t
    | Types.IRecord f ->
      let rec fields acc (f : Types.infer_fields) =
        match Types.repr_fields f with
        | Types.FCons (_, t, rest) -> fields (outside acc t) rest
        | _ -> acc
      in
      fields acc f
    | Types.IFn (ps, r, _) -> List.fold_left outside acc (r :: ps)
    | _ -> acc
  in
  let labels, _ = Types.labels_of_infer_row row in
  let carried, _ = Types.labels_of_infer_row caller in
  let unsettled =
    List.concat_map
      (fun (l, args) ->
        if List.mem_assoc l carried
        then []
        else
          List.filter_map
            (fun a ->
              match Types.repr a with
              | Types.IVar { contents = Types.Unbound (id, _) } when not (Hashtbl.mem Types.declared_params id) -> Some id
              | _ -> None)
            args)
      labels
  in
  if unsettled = []
  then row
  else (
    let seen = outside [] callee in
    let in_env, _, _ = env_free_all env in
    let defaulted = List.filter (fun id -> not (List.mem id seen || List.mem id in_env)) unsettled in
    let rec kept (r : Types.infer_row) =
      match Types.repr_row r with
      | Types.RCons (l, args, rest) ->
        if List.exists
             (fun a ->
               match Types.repr a with
               | Types.IVar { contents = Types.Unbound (id, _) } -> List.mem id defaulted
               | _ -> false)
             args
        then kept rest
        else Types.RCons (l, args, kept rest)
      | r -> r
    in
    if defaulted = [] then row else kept row)

(* The rows of the function values the transform made, which perform through
   what is around them. A continuation among them can be a key's row, closed at
   the call, while it still calls a function being checked -- the loop it is
   the next step of, or the copy it is in -- and tying the two would close that
   function's row before the rest of its body performs what it does. Such a
   call is contained at once: what the callee gains later is its own, and
   reaches the function around the continuation through the callee. *)
let made_rows : Types.infer_row list ref = ref []

let is_made_row caller = List.exists (fun r -> r == caller) !made_rows

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
  | _ when is_made_row caller -> Types.row_within row caller
  | Some name when calls_unchecked name callee && not (Types.row_is_declared row) ->
    pending_calls := (name, row, caller) :: !pending_calls
  | _ -> if pending then Types.unify_row row caller else Types.row_within row caller

let unify_at span expected actual =
  try Types.unify expected actual with
  | Types.Type_error message -> raise (Located { span; message })

let is_trait_type (t : Types.infer_ty) =
  match Types.repr t with
  | Types.INamed (name, _) -> Hashtbl.mem ctx_traits name
  | _ -> false

let not_pure (written : Ast.expr) param (arg : checked_expr) =
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
let not_a_bound ~declared (written : Ast.expr) param (arg : checked_expr) =
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
  let saved = ctx.return_type, ctx.saw_return, ctx.row, ctx.handed_answer in
  let looping = !in_loop in
  in_loop := false;
  let restore () =
    in_loop := looping;
    let return_type, saw_return, row, handed_answer = saved in
    ctx.return_type <- return_type;
    ctx.saw_return <- saw_return;
    ctx.row <- row;
    ctx.handed_answer <- handed_answer
  in
  Fun.protect ~finally:restore (fun () ->
    set ();
    body ())

let in_function_body ?handed ctx ~ret ~row body =
  in_ctx
    ctx
    ~set:(fun () ->
      ctx.return_type <- Some ret;
      ctx.saw_return <- false;
      ctx.row <- row;
      ctx.handed_answer <- handed)
    (fun () ->
      let checked = body () in
      if not ctx.saw_return then Types.unify ret Types.IUnit;
      checked)

(* Not in [ctx_types], so anything resolving a written name has to ask here. *)
let primitive = function
  | "Int" -> Some Types.IInt
  | "Float" -> Some Types.IFloat
  | "String" -> Some Types.IStr
  | "Byte" -> Some Types.IByte
  | "Char" -> Some Types.IChr
  | "Bool" -> Some Types.IBool
  | "Unit" -> Some Types.IUnit
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
   `Slot<>` is the empty one and `Slot<Int, String>` holds two. Written as a
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
  if String.equal name Types.span_name && args = []
  then Types.ispan
  else if String.equal name Types.name_name && args = []
  then Types.iname
  else if String.equal name Types.absent_name && args = []
  then Types.INamed (Types.absent_name, [])
  else if String.equal name Ast.open_type && args = []
  then Types.fresh ()
  else if args = [] && Hashtbl.mem Types.copies name && not (Hashtbl.mem ctx_types name)
  then (
    (* A copy's name, as a key writes it into a meta block, is the generic
       type at its arguments: inference never sees a copy. *)
    let base, copied = Hashtbl.find Types.copies name in
    named_type ~written span base (List.map Types.of_ty copied))
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
    | [] when List.mem_assoc Ast.open_row entries -> Types.fresh_row ()
    | [] -> Types.REmpty
    | [ row ] -> row
    | _ -> Types.error "A row may be open in one variable, not several."
  in
  List.fold_right
    (fun (label, written) rest ->
      if Hashtbl.mem ctx_row_params label || String.equal label Ast.open_row
      then rest
      else (
        let declared =
          List.length (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params label))
        in
        (* Unwritten arguments are left to inference, each at its own variable,
           so `<Yield>` is every instantiation and `<Yield<Int>>` is one. *)
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
    then Some { Ast.dp_trait = trait; dp_targets = args }
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
     table holds their methods too. No slots, which the lowering reads as that. *)
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
              ~default:{ Ast.dp_trait = trait; dp_targets = trait_args } ))
        declared
    in
    Ast.annotated span expected (`Coerce (e, trait, slots))
  | _ ->
    unify_at span expected e.Ast.ann;
    e

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
               `S: Source<Int, E>, E`. *)
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

(* `<T: Show>` and `<n: Int>` are one syntax: only whether the annotation's head
   names a trait tells a bound from a value. *)
let is_value_param (p : Ast.static_param) =
  match p.Ast.sp_ty with
  | None -> false
  | Some { Ast.it = Ast.Ty_name name | Ast.Ty_app (name, _); _ } -> not (Hashtbl.mem ctx_traits name)
  | Some _ -> true

(* A use of a declaration: its written signature with every static parameter
   fresh, [u_vars] standing for them. A parameter standing in a row also has
   the row it is copied to. *)
type use =
  { u_decl : walk_decl
  ; u_ty : Types.infer_ty
  ; u_vars : (string * Types.infer_ty * Types.infer_row option) list
  ; mutable u_values : (string * Key.arg) list
  ; mutable u_defaulted : bool
  }

(* One instantiation of the signature together with the parameters, so each
   copy can be read back where it landed. *)
let use_of (d : walk_decl) : use =
  let body = d.wd_scheme.Types.body in
  let in_body = Types.free_row_vars body in
  let rows =
    List.map
      (fun (_, var) ->
        match List.assq_opt var !param_rows with
        | Some row ->
          (match Types.row_tail row with
           | Some id when List.mem id in_body -> Some row
           | _ -> None)
        | None -> None)
      d.wd_vars
  in
  let together =
    Types.ITuple
      ((body :: List.map snd d.wd_vars)
       @ List.filter_map (Option.map (fun row -> Types.IRow row)) rows)
  in
  (* Every variable, not only the static parameters': what the signature
     leaves unwritten is what each instance's body settles for itself. *)
  let quantified = List.map fst (Types.free_vars together) in
  match
    Types.instantiate
      { Types.quantified
      ; quantified_rows = Types.free_row_vars together
      ; quantified_fields = []
      ; body = together
      }
  with
  | Types.ITuple (ty :: copies) ->
    let n = List.length d.wd_vars in
    let types = List.filteri (fun i _ -> i < n) copies
    and row_copies = ref (List.filteri (fun i _ -> i >= n) copies) in
    let vars =
      List.map2
        (fun ((name, _), copy) row ->
          let row =
            match row, !row_copies with
            | Some _, Types.IRow r :: rest ->
              row_copies := rest;
              Some r
            | _ -> None
          in
          name, copy, row)
        (List.combine d.wd_vars types)
        rows
    in
    { u_decl = d; u_ty = ty; u_vars = vars; u_values = []; u_defaulted = false }
  | _ -> assert false

(* A signature read and dropped. A declaration's hoisted scheme shares what its
   signature leaves unwritten, so the walk reads a fresh copy rather than tie
   every reader to one row. *)
let signature_of env name scheme =
  match decl_of env name with
  | Some d -> (use_of d).u_ty
  | None -> Types.instantiate scheme

(* Whether a variable appears in a type outside every effect label's arguments,
   and whether inside one. *)
let occurrences id (t : Types.infer_ty) =
  let outside = ref false
  and inside = ref false in
  let rec ty ~labelled t =
    match Types.repr t with
    | Types.IVar { contents = Types.Unbound (i, _) } ->
      if i = id then if labelled then inside := true else outside := true
    | Types.ITuple ts | Types.IPack ts | Types.INamed (_, ts) | Types.ISum (_, ts) ->
      List.iter (ty ~labelled) ts
    | Types.ISpread t -> ty ~labelled t
    | Types.IFn (ps, r, row) ->
      List.iter (ty ~labelled) ps;
      ty ~labelled r;
      row_of ~labelled row
    | Types.IRecord f -> fields ~labelled f
    | Types.IRow row -> row_of ~labelled row
    | _ -> ()
  and row_of ~labelled row =
    match Types.repr_row row with
    | Types.RCons (_, args, rest) ->
      List.iter (ty ~labelled:true) args;
      row_of ~labelled rest
    | _ -> ()
  and fields ~labelled f =
    match Types.repr_fields f with
    | Types.FCons (_, t, rest) ->
      ty ~labelled t;
      fields ~labelled rest
    | _ -> ()
  in
  ty ~labelled:false t;
  !outside, !inside

(* A key is closed: a row still open would let the caller's grow after the
   instance was made at it, and the two would disagree about the handler
   values it takes. *)
let rec close_row (r : Types.infer_row) =
  match Types.repr_row r with
  | Types.RVar { contents = Types.RUnbound _ } -> Types.unify_row r Types.REmpty
  | Types.RCons (_, args, rest) ->
    List.iter close_type args;
    close_row rest
  | _ -> ()

and close_type (t : Types.infer_ty) =
  match Types.repr t with
  | Types.IVar { contents = Types.Unbound (_, Types.Collection elem) } ->
    Types.unify t (Types.iarray elem);
    close_type t
  | Types.ITuple ts | Types.IPack ts | Types.INamed (_, ts) | Types.ISum (_, ts) ->
    List.iter close_type ts
  | Types.ISpread t -> close_type t
  | Types.IFn (ps, r, row) ->
    List.iter close_type ps;
    close_type r;
    close_row row
  | Types.IRecord f ->
    let rec fields f =
      match Types.repr_fields f with
      | Types.FCons (_, t, rest) ->
        close_type t;
        fields rest
      | _ -> ()
    in
    fields f
  | Types.IRow row -> close_row row
  | _ -> ()

(* The variables a resolved type still holds outside every effect label's
   arguments. One inside a label is what a defaulted parameter left open at
   its use, and the instance is generic in it. *)
let outside_labels (t : Types.ty) =
  let rec generics (t : Types.ty) =
    match t with
    | Types.Generic id -> [ id ]
    | Types.Tuple ts | Types.Pack ts | Types.Named (_, ts) | Types.Sum (_, ts) -> List.concat_map generics ts
    | Types.Spread t -> generics t
    | Types.Record fields -> List.concat_map (fun (_, t) -> generics t) fields
    | Types.Fn (ps, r, _) -> List.concat_map generics (r :: ps)
    | _ -> []
  in
  generics t

(* A handler arm serves every instantiation of its operation, so the
   operation's own parameters are still variables there, and an instance made
   inside the arm is made generic in them. Those are the only declared
   parameters a key can meet: a declaration's own are copied at each use. *)
let parametric (t : Types.ty) = List.for_all (fun id -> Hashtbl.mem Types.declared_params id) (outside_labels t)

(* The call a statement discards the value of, by its offsets. *)
let discarded : (int * int) option ref = ref None

(* Only in the result, which nothing reads: no argument or effect can settle
   it, and no reader can tell what it is. *)
let only_returned id (declared : Types.infer_ty) =
  match Types.repr declared with
  | Types.IFn (params, ret, row) ->
    let in_params = List.exists (fun p -> occurrences id p <> (false, false)) params in
    let in_row = occurrences id (Types.IFn ([], Types.IUnit, row)) <> (false, false) in
    (not in_params) && (not in_row) && fst (occurrences id ret)
  | _ -> false

(* Each key a call reached, by the callee and its span: processed code writes a
   callee's type with the rows its arguments settled left out, so a row
   parameter is read back from here. *)
let keyed_at : (string * (int * int), Key.t list) Hashtbl.t = Hashtbl.create 64

(* Read once the use's arguments are unified, and never later: a key is settled
   at the call. *)
let key_of_use span ~value (u : use) : Key.t =
  let discarding = (not value) && !discarded = Some (Source_map.Span.offsets span) in
  let d = u.u_decl in
  let declared = d.wd_scheme.Types.body in
  let unsettled = ref [] in
  let settled =
    List.map
      (fun (name, copy, row) ->
        match row with
        | Some r ->
          close_row r;
          name, Some (Key.Row (Types.resolve_row r))
        | None ->
          (try close_type copy with
           | Types.Type_error message -> fail span "%s" message);
          let resolved = Types.resolve copy in
          if outside_labels resolved = []
          then name, Some (Key.Type resolved)
            (* Generic in it whatever part of it is: the instance is checked
               once, generically, rather than once per shape a run-time value
               could take. *)
          else if parametric resolved || is_unknown copy
          then name, Some (Key.Type (Types.Generic 0))
          else (
            let defaulted =
              match Types.repr copy, List.assoc_opt name d.wd_vars with
              | Types.IVar _, Some var ->
                (match Types.repr var with
                 | Types.IVar { contents = Types.Unbound (id, _) } ->
                   (match occurrences id declared with
                    | false, true -> true
                    | _ -> false)
                 | _ -> false)
              | _ -> false
            in
            let returned () =
              discarding
              &&
              match Types.repr copy, List.assoc_opt name d.wd_vars with
              | Types.IVar _, Some var ->
                (match Types.repr var with
                 | Types.IVar { contents = Types.Unbound (id, _) } -> only_returned id declared
                 | _ -> false)
              | _ -> false
            in
            if defaulted
            then (
              u.u_defaulted <- true;
              (try Types.unify copy (Types.INamed (Ast.absent_type, [])) with
               | Types.Type_error _ -> ());
              name, Some (Key.Type (Types.Named (Ast.absent_type, []))))
            else if returned ()
            then (
              (try Types.unify copy Types.IUnit with
               | Types.Type_error _ -> ());
              name, Some (Key.Type Types.Unit))
            else (
              unsettled := name :: !unsettled;
              name, None)))
      u.u_vars
  in
  if !unsettled <> []
  then (
    let shown =
      "{"
      ^ String.concat
          ", "
          (List.map
             (fun (name, arg) ->
               (if Ast.is_implicit_param name then "_" else name)
               ^ " = "
               ^ match arg with
                 | Some a -> Key.show_arg a
                 | None -> "?")
             settled)
      ^ "}"
    in
    if value
    then
      fail
        span
        "'%s' is generic and its static params are not settled here; write them or give it a \
         type: %s."
        (shown_name d.wd_name)
        shown
    else fail span "The static params of '%s' are not settled here: %s." (shown_name d.wd_name) shown);
  let k = List.map (fun (name, arg) -> name, Option.get arg) settled @ u.u_values in
  (match Source_map.Span.view span with
   | Source_map.Span.Nowhere_in_source -> ()
   | Source_map.Span.Located _ ->
     let at = d.wd_name, Source_map.Span.offsets span in
     Hashtbl.replace keyed_at at (k :: Option.value ~default:[] (Hashtbl.find_opt keyed_at at)));
  k

(* The instance a use reaches, its type unified with the use's. One still being
   metaprocessed has only its written signature to offer. *)
let enter ?(handlers = []) span ~value (u : use) : instance_view =
  let key = key_of_use span ~value u in
  let key =
    if handlers = []
    then Option.value ~default:key (Hashtbl.find_opt handler_alias (u.u_decl.wd_id, Key.show key))
    else (
      let id = u.u_decl.wd_id in
      let shown = Key.show key in
      (* A recursive call made under a run its own body holds keys only what
         the calls around it already did, or each run would make another. *)
      let handlers =
        match Hashtbl.find_opt walking_keys id with
        | Some keys -> List.filter (fun (l, h) -> List.exists (List.mem (l, Key.Handler h)) keys) handlers
        | None -> handlers
      in
      let handlers =
        match Hashtbl.find_opt answered_labels (id, shown) with
        | Some labels -> narrowed labels handlers
        | None -> handlers
      in
      (* A local function's instances are emitted where it is declared, outside
         any run its body is called in. *)
      let handlers =
        if u.u_decl.wd_local
        then List.filter (fun (_, h) -> handler_home [ "", Key.Handler h ] = None) handlers
        else handlers
      in
      let full = key @ List.map (fun (l, h) -> l, Key.Handler h) handlers in
      let full = Option.value ~default:full (Hashtbl.find_opt handler_alias (id, Key.show full)) in
      let at = u.u_decl.wd_name, Source_map.Span.offsets span in
      (match Hashtbl.find_opt keyed_at at with
       | Some (k :: rest) when Key.show k = shown -> Hashtbl.replace keyed_at at (full :: rest)
       | _ -> ());
      full)
  in
  let view = (ops ()).instance span u.u_decl key in
  if view.iv_walking && not view.iv_ret_written
  then
    fail
      span
      "'%s' is still being metaprocessed and its signature leaves its return type to \
       inference; write it."
      (shown_name u.u_decl.wd_name);
  (* A generic instance is generic in its own variables at every use, as a
     scheme is: a call reaching it at another shape is not that shape. *)
  let own =
    List.filter (fun id -> Hashtbl.mem Types.declared_params id) (List.map fst (Types.free_vars view.iv_ty))
  in
  let ty =
    if own = []
    then view.iv_ty
    else
      Types.instantiate
        { Types.quantified = own; quantified_rows = []; quantified_fields = []; body = view.iv_ty }
  in
  (* A parameter the key defaulted stands only in labels, and the instance
     performs none of them: unifying would put `Throw<Unit>` in the caller's
     row, where a later `Throw<IoError>` could not join it. *)
  (if u.u_defaulted
   then (
     match Types.repr u.u_ty, Types.repr ty with
     | Types.IFn (_, ret, _), Types.IFn (_, ret', _) -> unify_at span ret ret'
     | _ -> ())
   else unify_at span u.u_ty ty);
  view

(* A finished instance's row is what it performs, contained in its caller's.
   One still being processed is tied to its caller instead: labels it gains
   after this call would otherwise never reach the caller. *)
let walk_admits ~(view : instance_view) ~written row caller =
  (match !open_defer with
   | Some d when caller == d.d_row && Types.row_is_declared row -> d.d_open <- true
   | _ -> ());
  if view.iv_walking && (not written) && not (is_made_row caller)
  then Types.unify_row row caller
  else Types.row_within row caller

(* A function named where no call settles it, made concrete once the
   statement around it has said what it is. *)
let settle_pending () =
  let waiting = List.rev !pending_values in
  pending_values := [];
  List.iter
    (fun p ->
      let u = { u_decl = p.p_decl; u_ty = p.p_ty; u_vars = p.p_vars; u_values = []; u_defaulted = false } in
      let view = enter p.p_span ~value:true u in
      Hashtbl.replace placeholders p.p_placeholder view.iv_name)
    waiting

(* Kept only if it holds: the parent unifies against what it expected anyway,
   and a mismatch is reported there, at the span it always was. *)
let meet expected actual =
  match expected with
  | Some t ->
    if Types.retracting (fun () ->
         try
           Types.unify t actual;
           true
         with
         | Types.Type_error _ -> false)
    then Types.unify t actual
  | None -> ()

(* Met before the arguments are read, so what the parent expects of the result
   reaches the parameters: `var p: Promise<Int> = promise();` settles the key. *)
let use_toward expected (d : walk_decl) =
  let u = use_of d in
  (match Types.repr u.u_ty with
   | Types.IFn (_, ret, _) -> meet expected ret
   | _ -> ());
  u

let written_instance span name scheme static_args =
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
  fn

let parameters fn ~receiver (args : Ast.expr list) =
  let unknown = List.map (fun _ -> None) args in
  match Types.repr fn with
  | Types.IFn (params, _, _) ->
    (match Types.expand params, receiver with
     | _ :: params, true | params, false ->
       if List.length params = List.length args then List.map Option.some params else unknown
     | [], true -> unknown)
  | _ -> unknown

(* An implicit parameter has no name to write it by. *)
let write_static ?(implicit = false) span name (u : use) static_args =
  let d = u.u_decl in
  let written =
    List.filter
      (fun (p : Ast.static_param) -> not (Ast.is_implicit_param p.Ast.sp_name))
      d.wd_sig.Ast.static_params
  in
  let written = if implicit && written = [] then d.wd_sig.Ast.static_params else written in
  if List.length written <> List.length static_args
  then
    fail
      span
      "'%s' takes %d static argument(s) but %d were given."
      (shown_name name)
      (List.length written)
      (List.length static_args);
  List.iter2
    (fun (p : Ast.static_param) (arg : Ast.expr Ast.static_arg) ->
      if is_value_param p
      then (
        let v, shown = (ops ()).static_value name arg in
        u.u_values <- u.u_values @ [ p.Ast.sp_name, Key.Value (v, shown) ])
      else (
        let written =
          match arg with
          | Ast.St_type t -> infer_ty_of_annotation t
          | Ast.St_value { Ast.it = `Var n; span = at; _ } ->
            infer_ty_of_annotation (Ast.at at (Ast.Ty_name n))
          | Ast.St_value v -> fail v.Ast.span "'%s' takes a type here, not a value." (shown_name name)
        in
        match List.find_opt (fun (n, _, _) -> String.equal n p.Ast.sp_name) u.u_vars with
        | Some (_, copy, Some row) ->
          (match Types.repr written with
           | Types.IRow r -> unify_at span (Types.IRow row) (Types.IRow r)
           | _ -> unify_at span copy written)
        | Some (_, copy, None) -> unify_at span copy written
        | None -> ()))
    written
    static_args

(* A use at one is reached at no instance, so what it returns is as unknown as
   what it was handed: left open, it would be the next error. *)
let at_erroneous (u : use) =
  let at = List.exists (fun (_, copy, _) -> is_erroneous copy) u.u_vars in
  (if at
   then
     match Types.repr u.u_ty with
     | Types.IFn (_, ret, _) when Types.free_vars ret <> [] && not (is_erroneous ret) ->
       (try Types.unify ret (erroneous_ty ()) with
        | Types.Type_error _ -> ())
     | _ -> ());
  at

(* A function named as a value: the instance once its use is settled, and
   otherwise a placeholder the expression around it settles. *)
let value_of span (u : use) =
  let settled (_, copy, row) =
    match row with
    | Some r -> Types.row_tail r = None
    | None -> Types.free_vars copy = []
  in
  if at_erroneous u
  then u.u_decl.wd_name
  else if List.for_all settled u.u_vars || u.u_values <> []
  then (enter span ~value:true u).iv_name
  else (
    incr placeholder_count;
    let placeholder = Ast.generated [ "use"; string_of_int !placeholder_count ] in
    pending_values
    := { p_span = span; p_decl = u.u_decl; p_vars = u.u_vars; p_ty = u.u_ty; p_placeholder = placeholder }
       :: !pending_values;
    placeholder)

(* A call's use, once its arguments are unified: the functions they name are
   settled first, then the callee's own key. *)
let reached span (u : use) row ctx =
  if at_erroneous u then u.u_decl.wd_name else (
  settle_pending ();
  (* A label the caller already carries says what the callee's argument to it
     is, before the key is read; the rest waits for the key, which may find a
     parameter standing only in labels nothing performs. *)
  let carried, _ = Types.labels_of_infer_row ctx.row in
  List.iter
    (fun (label, args) ->
      match List.assoc_opt label carried with
      | Some found when List.length found = List.length args ->
        (try List.iter2 Types.unify args found with
         | Types.Type_error _ -> ())
      | _ -> ())
    (fst (Types.labels_of_infer_row row));
  let handlers =
    if !in_plain > 0 || is_plain u.u_decl.wd_sig then [] else known_handlers !effect_bindings
  in
  let view = enter ~handlers span ~value:false u in
  if Ast.is_program_root u.u_decl.wd_name then Hashtbl.replace root_instances view.iv_name ();
  let answered =
    Hashtbl.find_opt answered_labels (u.u_decl.wd_id, Key.show (without_handlers view.iv_key))
  in
  List.iter
    (fun (l, a) ->
      match a with
      | Key.Handler _ when Option.fold ~none:true ~some:(List.mem l) answered ->
        (match binding_for l !effect_bindings with
         | Some b -> note_keyed b
         | None -> ())
      | _ -> ())
    view.iv_key;
  Types.row_within row ctx.row;
  walk_admits ~view ~written:(Option.is_some u.u_decl.wd_sig.Ast.row) row ctx.row;
  view.iv_name)

(* What [f] checks, noted so it can be shown again, and the names it reached. *)
let noted f =
  let previous = !noting
  and previous_reaching = !reaching in
  let names = ref [] in
  let notes = { n_types = []; n_runs = [] } in
  noting := Some notes;
  reaching := Some names;
  let result =
    Fun.protect
      ~finally:(fun () ->
        noting := previous;
        reaching := previous_reaching;
        Option.iter (fun outer -> outer := List.rev_append !names !outer) previous_reaching;
        Option.iter
          (fun outer ->
            outer.n_types <- List.rev_append notes.n_types outer.n_types;
            outer.n_runs <- List.rev_append notes.n_runs outer.n_runs)
          previous)
      f
  in
  result, (!names, notes)

let passed_at span ctx n =
  match Hashtbl.find_opt passed n with
  | None -> fail span "Nothing was checked under %d." n
  | Some p ->
    (try Types.row_within p.pc_row ctx.row with
     | Types.Type_error message -> fail span "%s" message);
    if walking () then List.iter (ops ()).refer p.pc_uses;
    Option.iter
      (fun returned ->
        Option.iter (fun t -> unify_at span t returned) ctx.return_type;
        ctx.saw_return <- true)
      p.pc_returns;
    p

let with_pending f =
  let outer = !pending_values in
  pending_values := [];
  Fun.protect
    ~finally:(fun () -> pending_values := outer)
    (fun () ->
      let result = f () in
      settle_pending ();
      result)

(* Where every entry the registry names is declared. *)
let top_env : env option ref = ref None

(* A call the checker builds to an entry the registry chose: in the walk, the
   instance the arguments' types settle, with the row that instance performs. *)
(* Made while its root statement is being finished, an instance is closed at
   once, as one made earlier is closed then: the call names its row, and an
   open tail would leave it for the caller to decide. *)
let closed_if ~at_end (view : instance_view) (ty : Types.infer_ty) =
  if at_end && not view.iv_walking
  then (
    let rec close (r : Types.infer_row) =
      match Types.repr_row r with
      | Types.RVar { contents = Types.RUnbound _ } -> Types.unify_row r Types.REmpty
      | Types.RCons (_, _, rest) -> close rest
      | _ -> ()
    in
    match Types.repr ty with
    | Types.IFn (_, _, row) -> close row
    | _ -> ())

let entry_ref ~at_end span name (args : Types.infer_ty list) (result : Types.infer_ty) : checked_expr =
  let found, row =
    match Option.bind !top_env (fun env -> decl_of env name) with
    | None -> name, Types.REmpty
    | Some d ->
      let u = use_of d in
      (match Types.repr u.u_ty with
       | Types.IFn (params, _, _) ->
         let params = Types.expand params in
         List.iteri
           (fun i a ->
             match List.nth_opt params i with
             | Some p -> unify_at span p a
             | None -> ())
           args
       | _ -> ());
      let view = enter span ~value:false u in
      closed_if ~at_end view u.u_ty;
      ( view.iv_name
      , match Types.repr u.u_ty with
        | Types.IFn (_, _, row) -> row
        | _ -> Types.REmpty )
  in
  Ast.annotated span (Types.IFn (args, result, row)) (`Var found)

let call_entry ~at_end span name (args : checked_expr list) result : checked_expr =
  Ast.annotated
    span
    result
    (`Call (entry_ref ~at_end span name (List.map (fun (a : checked_expr) -> a.Ast.ann) args) result, args))

(* The effects a trait's method writes in its row. *)
let declared_row trait name =
  let methods =
    List.concat_map
      (fun t ->
        match Hashtbl.find_opt ctx_traits t with
        | Some (_, body) -> body.Ast.tb_methods
        | None -> [])
      (trait_closure trait)
  in
  match List.find_opt (fun (m : Ast.method_sig) -> String.equal m.Ast.ms_name name) methods with
  | Some { Ast.ms_signature = { Ast.row = Some labels; _ }; _ } -> List.map fst labels
  | _ -> []

(* A table's slot for a method that takes control holds the impl's method
   made taking its handlers and what the transform hands it, as a function
   value is. *)
let controlled_slot : (Registry.t -> Ast.span -> string -> checked_expr) ref =
  ref (fun _ span _ -> fail span "A method that takes control has no table slot here.")

let slot_ref ~at_end span ~owner ~trait name entry (receiver : Types.infer_ty) : checked_expr =
  match Option.bind !top_env (fun env -> decl_of env entry) with
  | None -> fail span "'%s' has no '%s' to put in a '%s'." owner name trait
  | Some d ->
    let u = use_of d in
    (match Types.repr u.u_ty with
     | Types.IFn (self :: _, _, _) -> unify_at span self receiver
     | _ -> ());
    let view = enter span ~value:false u in
    closed_if ~at_end view u.u_ty;
    Ast.annotated span u.u_ty (`Var view.iv_name)

let ordering_test (op : Ast.binop) =
  match op with
  | Ast.Less -> Some Core.is_less
  | Ast.Less_equal -> Some Core.is_less_equal
  | Ast.Greater -> Some Core.is_greater
  | Ast.Greater_equal -> Some Core.is_greater_equal
  | _ -> None

let ordering_result = Types.ISum (Core.option, [ Types.ISum (Core.ordering, []) ])

(* What a node's lowering reads a type as: while it is checked, only a type no
   variable is left in; at the end of its root statement, whatever it became. *)
(* What is still open when a root statement ends. An instance's own
   parameters are its key's, so this is inference nothing finished. Some stay
   open on purpose: a collection's kind, which is an array; a parameter a
   parametric instance keeps; a variable standing only in an effect's
   arguments, which the key defaulted; what an error or a meta block left
   unknown; and what [unobservable] holds. *)
let unsettled (t : Types.infer_ty) =
  List.exists
    (fun (id, kind) ->
      match kind with
      | Types.Collection _ -> false
      | _ ->
        not
          (Hashtbl.mem Types.declared_params id
           || Hashtbl.mem unobservable id
           || List.exists
                (fun u ->
                  match Types.repr u with
                  | Types.IVar { contents = Types.Unbound (other, _) } -> other = id
                  | _ -> false)
                !unknowns)
        && fst (occurrences id t))
    (Types.free_vars t)

let settled_now = Types.concrete
let settled_at_end t = if unsettled t then None else Some (Types.resolve t)

let rec settled_all settle = function
  | [] -> Some []
  | t :: rest ->
    Option.bind (settle t) (fun t -> Option.map (fun rest -> t :: rest) (settled_all settle rest))

let accessor registry span (target : Types.ty) (index : Types.ty) pick =
  let by_index owner =
    Registry.indexed registry owner (Option.value (Types.type_name index) ~default:"")
  in
  match Option.bind (Types.type_name target) by_index with
  | Some entry ->
    (match pick entry with
     | Some name -> name
     | None -> fail span "%s cannot be assigned into." (Types.string_of_ty target))
  | None -> fail span "Cannot index %s." (Types.string_of_ty target)

(* [None] while a type the choice reads is not settled. *)
let lowered ~at_end registry (e : checked_expr) : checked_expr option =
  let settle = if at_end then settled_at_end else settled_now in
  let call_entry = call_entry ~at_end
  and entry_ref = entry_ref ~at_end
  and slot_ref = slot_ref ~at_end in
  let span = e.Ast.span
  and ann = e.Ast.ann in
  let node it : checked_expr = Ast.annotated span ann it in
  match e.Ast.it with
  | `Binop (op, a, b) ->
    (match settle a.Ast.ann, settle b.Ast.ann with
     | Some lhs, Some rhs ->
       (match Registry.find registry op lhs rhs with
        (* The method answers with an `Ordering`; which comparison was written
           decides how that becomes a bool. *)
        | Some { Registry.emit = Registry.Call name; _ } when ordering_test op <> None ->
          let compared = call_entry span name [ a; b ] ordering_result in
          Some (call_entry span (Option.get (ordering_test op)) [ compared ] ann)
        (* One entry answers both, since a type that says what equal means has
           said what unequal means. *)
        | Some { Registry.emit = Registry.Call name; _ } when op = Ast.Not_equal ->
          Some (node (`Unop (Ast.Not, call_entry span name [ a; b ] Types.IBool)))
        | Some { Registry.emit = Registry.Call name; _ } -> Some (call_entry span name [ a; b ] ann)
        | Some { Registry.emit = Registry.Primitive; _ } | None -> Some e)
     | _ -> None)
  | `Unop (((Ast.Neg | Ast.Bit_not) as op), a) ->
    Option.map
      (fun operand ->
        match Registry.find_unary registry op operand with
        | Some { Registry.emit = Registry.Call name; _ } -> call_entry span name [ a ] ann
        | Some { Registry.emit = Registry.Primitive; _ } | None -> e)
      (settle a.Ast.ann)
  | `Index (target, index) ->
    (match settle target.Ast.ann, settle index.Ast.ann with
     | Some t, Some i ->
       let via_entry () =
         call_entry
           span
           (accessor registry target.Ast.span t i (fun entry -> entry.Registry.get))
           [ target; index ]
           ann
       in
       (* Anything but an int is an entry the type declared, a range included. *)
       Some
         (if i <> Types.Int
          then via_entry ()
          else if t = Types.Str
          then node (`Str_get (target, index))
          else if Types.is_array t
          then node (`Array_get (target, index))
          else via_entry ())
     | _ -> None)
  | `Index_assign (target, index, v) ->
    (match settle target.Ast.ann with
     | Some t when Types.is_array t -> Some (node (`Array_set (target, index, v)))
     | Some t ->
       Option.map
         (fun i ->
           call_entry
             span
             (accessor registry target.Ast.span t i (fun entry -> entry.Registry.set))
             [ target; index; v ]
             ann)
         (settle index.Ast.ann)
     | None -> None)
  | `Collection_lit items ->
    Option.map
      (fun ty ->
        if Types.is_array ty
        then node (`Array_lit items)
        else (
          let unbuildable () =
            fail span "%s cannot be built from a literal." (Types.string_of_ty ty)
          in
          match Types.type_name ty with
          | None -> unbuildable ()
          (* What it holds comes from the entry rather than from its arity. *)
          | Some name ->
            (match Registry.container registry name, Registry.container_element registry name ann with
             | Some make, Some element ->
               (* The items' own type where there are any, so the entry's
                  element is the very type they were checked at. *)
               let element =
                 match items with
                 | (first : checked_expr) :: _ -> first.Ast.ann
                 | [] -> element
               in
               let elements : checked_expr =
                 Ast.annotated span (Types.iarray element) (`Array_lit items)
               in
               call_entry span make.Registry.entry [ elements ] ann
             | _ -> unbuildable ())))
      (settle ann)
  | `Coerce (inner, trait, slots) ->
    let targets =
      settled_all settle (List.concat_map (fun (_, (d : Types.infer_ty Ast.dispatch)) -> d.Ast.dp_targets) slots)
    in
    (match settle inner.Ast.ann, targets with
     | Some data, Some _ ->
       (match slots, Types.type_name data with
        (* An object passed where one of its supertraits is wanted is that
           object. Called through an identity, so the node keeps the type it
           was given. *)
        | [], Some owner when Hashtbl.mem ctx_traits owner ->
          let identity = Types.IFn ([ inner.Ast.ann ], ann, Types.REmpty) in
          Some (node (`Call (Ast.annotated span identity (`Var "__upcast"), [ inner ])))
        | _, None ->
          fail
            inner.Ast.span
            "%s cannot become a '%s': it has no type to dispatch on."
            (Types.string_of_ty data)
            trait
        | _, Some owner ->
          let slot (name, (d : Types.infer_ty Ast.dispatch)) =
            let d =
              { Ast.dp_trait = d.Ast.dp_trait
              ; dp_targets = List.map Types.resolve d.Ast.dp_targets
              
              }
            in
            let entry = Registry.dispatched registry d owner name in
            let written = declared_row d.Ast.dp_trait name in
            let ((_, e) as made) =
              if controlling written <> [] && walking () && final_read ()
              then name, !controlled_slot registry span entry
              else name, slot_ref span ~owner ~trait name entry inner.Ast.ann
            in
            (* A call through the table arranges handlers for what the trait
               wrote and nothing more, so the method put in the slot may perform
               nothing else. A row parameter in what it wrote lets anything
               through. *)
            (match Types.repr e.Ast.ann with
             | Types.IFn (_, _, performed) when List.for_all (Hashtbl.mem ctx_traits) written ->
               (match
                  List.find_opt (fun (label, _) -> not (List.mem label written)) (fst (Types.labels_of_infer_row performed))
                with
                | Some (label, _) ->
                  fail
                    inner.Ast.span
                    "%s cannot become a '%s': its '%s' performs '%s', which %s.%s does not allow."
                    (Types.string_of_ty data)
                    (shown_name trait)
                    name
                    (shown_name label)
                    (shown_name d.Ast.dp_trait)
                    name
                | None -> ())
             | _ -> ());
            made
          in
          let equal =
            match Registry.find registry Ast.Equal data data with
            | Some { Registry.emit = Registry.Call name; _ } ->
              Some (entry_ref span name [ inner.Ast.ann; inner.Ast.ann ] Types.IBool)
            | Some { Registry.emit = Registry.Primitive; _ } | None -> None
          in
          Some
            (node
               (`Object (inner, { Ast.made_from = Types.string_of_ty data; equal }, List.map slot slots))))
     | _ -> None)
  (* A trait object dispatches on the value it holds, so the impl is not chosen
     here; the row the call performs was read off the trait. *)
  | `Bound_call (receiver, name, dispatch, args) ->
    (match settle receiver.Ast.ann, settled_all settle dispatch.Ast.dp_targets with
     | Some r, Some targets ->
       (match Types.type_name r with
        | Some owner when Hashtbl.mem ctx_traits owner ->
          let row =
            Option.value
              ~default:Types.REmpty
              (Hashtbl.find_opt dynamic_rows (dispatch.Ast.dp_trait, name))
          in
          let performs =
            Types.IFn
              (receiver.Ast.ann :: List.map (fun (a : checked_expr) -> a.Ast.ann) args, ann, row)
          in
          Some (node (`Dyn_call (receiver, name, performs, args)))
        | Some owner ->
          let all =
            if Registry.is_associated registry owner name then args else receiver :: args
          in
          let d = { Ast.dp_trait = dispatch.Ast.dp_trait; dp_targets = targets } in
          Some (call_entry span (Registry.dispatched registry d owner name) all ann)
        (* Nothing settled the receiver, so there is no impl to name. *)
        | None ->
          fail receiver.Ast.span "Cannot call '%s': the receiver's type is not known here." name)
     | _ -> None)
  | `New (_, fields) -> Some (node (`Record_lit fields))
  | `New_variant (_, variant, payload) -> Some (node (`Variant (variant, Ast.payload_fields payload)))
  | _ -> None

let lowered_now registry (e : checked_expr) =
  if walking () then Option.value (lowered ~at_end:false registry e) ~default:e else e

let answer_count = ref 0

let fresh_answer () =
  incr answer_count;
  Ast.generated [ "answer"; string_of_int !answer_count ]

(* A compound target is read and then written, and what it is made of must run
   once between them: `xs[f()] += 1` calls `f` once. The temporary is assigned
   where the expression stood rather than declared with its value, so an
   enclosing loop condition still evaluates it every time round. *)
let once ctx (x : checked_expr) : checked_expr * checked_expr =
  match x.Ast.it with
  | `Var _ | #Ast.lit -> x, x
  | _ ->
    let temp = fresh_answer () in
    ctx.hoisted <- Ast.annotated x.Ast.span x.Ast.ann (`Var_decl (temp, None, None)) :: ctx.hoisted;
    { x with Ast.it = `Assign (temp, x) }, { x with Ast.it = `Var temp }

(* The expressions a node evaluates as part of itself: not a lambda's body,
   which runs later, nor what a `match` or `run` holds, which is lowered with
   it. *)
let children (e : checked_expr) : checked_expr list =
  match e.Ast.it with
  | #Ast.lit | `Var _ | `Lambda _ | `Run_block _ | `Match_expr _ -> []
  | `Assign (_, a) | `Unop (_, a) | `Compound (_, _, a) | `Tuple_get (a, _) | `Spread a
  | `Field (a, _) | `Array_len a | `Str_len a | `Coerce (a, _, _) -> [ a ]
  | `Binop (_, a, b) | `And (a, b) | `Or (a, b) | `Compound_field (_, a, _, b) | `Index (a, b)
  | `Field_assign (a, _, b) | `Array_new (a, b) | `Array_get (a, b) | `Str_get (a, b) ->
    [ a; b ]
  | `Compound_index (_, a, b, c) | `Index_assign (a, b, c) | `Array_set (a, b, c) -> [ a; b; c ]
  | `Call (callee, args) -> callee :: args
  | `Bound_call (receiver, _, _, args) | `Dyn_call (receiver, _, _, args) -> receiver :: args
  | `Tuple items | `Collection_lit items | `Array_lit items | `New_call (_, _, items) -> items
  | `Record_lit fields | `New (_, fields) | `Variant (_, fields) -> List.map snd fields
  | `New_variant (_, _, payload) -> List.map snd (Ast.payload_fields payload)
  | `Object (data, _, _) -> [ data ]

(* Whether running checked code reaches a call that takes control, outside the
   function values it makes. *)
let rec expr_splits (e : checked_expr) =
  let takes (t : Types.infer_ty) =
    match Types.repr t with
    | Types.IFn (_, _, row) -> controlling_row row <> []
    | _ -> false
  in
  match e.Ast.it with
  | `Lambda _ -> false
  | `Call (callee, args) ->
    takes callee.Ast.ann || List.exists expr_splits (callee :: args)
  | `Dyn_call (receiver, _, performs, args) -> takes performs || List.exists expr_splits (receiver :: args)
  | `Run_block b -> block_splits b.Ast.vb_stmts || Option.fold ~none:false ~some:expr_splits b.Ast.vb_value
  | `Match_expr (x, cases) ->
    expr_splits x
    || List.exists
         (fun (_, (b : (checked_expr, checked_stmt) Ast.valued_block)) ->
           block_splits b.Ast.vb_stmts || Option.fold ~none:false ~some:expr_splits b.Ast.vb_value)
         cases
  | _ -> List.exists expr_splits (children e)

and stmt_splits (s : checked_stmt) =
  match s.Ast.it with
  | `Fn _ -> false
  | `Match (x, cases) -> expr_splits x || List.exists (fun (_, body) -> block_splits body) cases
  | #Ast.stmts as st ->
    let found = ref false in
    ignore
      (Ast.map_stmts
         (fun e ->
           if expr_splits e then found := true;
           e)
         (fun s ->
           if stmt_splits s then found := true;
           s)
         st);
    !found
  | _ -> false

and block_splits body = List.exists stmt_splits body

(* A call rebuilt keeps the bindings it was checked under. *)
let carried ~(from : checked_expr) (e : checked_expr) =
  (match from.Ast.it with
   | (`Call _ | `Dyn_call _ | `Bound_call _) when from != e ->
     Option.iter (Checked_table.replace bindings_at e) (Checked_table.find_opt bindings_at from)
   | _ -> ());
  e

let rec hoists (e : checked_expr) =
  match e.Ast.it with
  | `Run_block _ | `Match_expr _ -> true
  | _ -> List.exists hoists (children e)

(* A `run` or a `match` in expression position becomes statements run ahead of
   the statement holding it, and so does the right side of `&&` or `||` that
   holds one. Each statement is taken apart once, when it is checked, so a
   statement list inside an expression -- a lambda's body, a block's arms --
   was already. *)
let rec hoist_expr ctx (e : checked_expr) : checked_expr =
  let original = e in
  let e = in_order ctx e in
  let span = e.Ast.span
  and ann = e.Ast.ann in
  let it : checked_expr_kind =
    match e.Ast.it with
    | `Lambda _ as l -> l
    | (`And (a, b) | `Or (a, b)) as logic ->
      let a = hoist_expr ctx a in
      (* What the right side hoisted runs only when the right side would. *)
      (match hoisting ctx b, logic with
       | ([], b), `And _ -> `And (a, b)
       | ([], b), `Or _ -> `Or (a, b)
       | (before, b), _ ->
         let temp = fresh_answer () in
         let at it : checked_stmt = Ast.annotated span Types.IUnit it in
         let var : checked_expr = Ast.annotated span Types.IBool (`Var temp) in
         let test =
           match logic with
           | `And _ -> var
           | `Or _ -> { var with Ast.it = `Unop (Ast.Not, var) }
         in
         let decided = at (`Expr { b with Ast.it = `Assign (temp, b) }) in
         ctx.hoisted
         <- at (`If (test, at (`Block (before @ [ decided ])), None))
            :: at (`Var_decl (temp, None, Some a))
            :: ctx.hoisted;
         `Var temp)
    | `Run_block body ->
      let answer = fresh_answer () in
      let body_stmts, body_value = valued ctx body in
      let answered =
        Option.fold
          ~none:[]
          ~some:(fun (v : checked_expr) ->
            [ Ast.annotated v.Ast.span v.Ast.ann (`Expr { v with Ast.it = `Assign (answer, v) }) ])
          body_value
      in
      ctx.hoisted
      <- Ast.annotated span ann (`Block (body_stmts @ answered))
         :: Ast.annotated span ann (`Var_decl (answer, None, None))
         :: ctx.hoisted;
      `Var answer
    | `Match_expr (scrutinee, cases) ->
      let answer = fresh_answer () in
      let scrutinee = hoist_expr ctx scrutinee in
      let arm = valued_arm ctx (fun v -> `Expr { v with Ast.it = `Assign (answer, v) }) in
      let matched : checked_stmt = Ast.annotated span ann (`Match (scrutinee, List.map arm cases)) in
      ctx.hoisted
      <- matched :: Ast.annotated span ann (`Var_decl (answer, None, None)) :: ctx.hoisted;
      `Var answer
    | _ -> (map_children (hoist_expr ctx) e).Ast.it
  in
  carried ~from:original { Ast.it; span; ann }

(* An operand that hoists runs ahead of the whole expression, so each operand
   before it is evaluated into a temporary first, keeping the order the source
   wrote. A name or a literal is left in place: spilling an assignment's target
   would assign the copy, and a callee's name is what picks a builtin. *)
and in_order ctx (e : checked_expr) : checked_expr =
  let rec spill (child : checked_expr) : checked_expr =
    match child.Ast.it with
    | `Var _ | #Ast.lit -> child
    | `Spread inner -> { child with Ast.it = `Spread (spill inner) }
    | _ ->
      let temp = fresh_answer () in
      let value = hoist_expr ctx child in
      ctx.hoisted
      <- Ast.annotated child.Ast.span child.Ast.ann (`Var_decl (temp, None, Some value)) :: ctx.hoisted;
      { child with Ast.it = `Var temp }
  in
  let rec ordered = function
    | child :: rest when List.exists hoists rest ->
      let child = spill child in
      child :: ordered rest
    | children -> children
  in
  let two a b k =
    match ordered [ a; b ] with
    | [ a; b ] -> { e with Ast.it = k a b }
    | _ -> assert false
  in
  let fields pairs = List.combine (List.map fst pairs) (ordered (List.map snd pairs)) in
  match e.Ast.it with
  | `Binop (op, a, b) -> two a b (fun a b -> `Binop (op, a, b))
  | `Index (a, b) -> two a b (fun a b -> `Index (a, b))
  | `Array_new (a, b) -> two a b (fun a b -> `Array_new (a, b))
  | `Array_get (a, b) -> two a b (fun a b -> `Array_get (a, b))
  | `Str_get (a, b) -> two a b (fun a b -> `Str_get (a, b))
  | `Index_assign (target, index, v) -> two index v (fun index v -> `Index_assign (target, index, v))
  | `Array_set (target, index, v) -> two index v (fun index v -> `Array_set (target, index, v))
  | `Call (callee, args) ->
    (match ordered (callee :: args) with
     | callee :: args -> { e with Ast.it = `Call (callee, args) }
     | [] -> assert false)
  | `Bound_call (receiver, name, dispatch, args) ->
    (match ordered (receiver :: args) with
     | receiver :: args -> { e with Ast.it = `Bound_call (receiver, name, dispatch, args) }
     | [] -> assert false)
  | `Dyn_call (receiver, name, performs, args) ->
    (match ordered (receiver :: args) with
     | receiver :: args -> { e with Ast.it = `Dyn_call (receiver, name, performs, args) }
     | [] -> assert false)
  | `Tuple items -> { e with Ast.it = `Tuple (ordered items) }
  | `Collection_lit items -> { e with Ast.it = `Collection_lit (ordered items) }
  | `Array_lit items -> { e with Ast.it = `Array_lit (ordered items) }
  | `Record_lit pairs -> { e with Ast.it = `Record_lit (fields pairs) }
  | `Variant (variant, pairs) -> { e with Ast.it = `Variant (variant, fields pairs) }
  | _ -> e

and hoisting ctx (e : checked_expr) =
  let saved = ctx.hoisted in
  ctx.hoisted <- [];
  let e = hoist_expr ctx e in
  let before = List.rev ctx.hoisted in
  ctx.hoisted <- saved;
  before, e

(* Whatever the value expression hoists belongs inside the block, in front of
   it. *)
and valued ctx (b : (checked_expr, checked_stmt) Ast.valued_block) =
  match b.Ast.vb_value with
  | None -> b.Ast.vb_stmts, None
  | Some v ->
    let before, v = hoisting ctx v in
    b.Ast.vb_stmts @ before, Some v

and valued_arm ctx finish (pattern, b) =
  let stmts, value = valued ctx b in
  ( pattern
  , stmts
    @ Option.fold
        ~none:[]
        ~some:(fun (v : checked_expr) -> [ Ast.annotated v.Ast.span v.Ast.ann (finish v) ])
        value )

and map_children f (e : checked_expr) : checked_expr =
  let it : checked_expr_kind =
    match e.Ast.it with
    | #Ast.lit as l -> l
    | `Lambda _ as l -> l
    | #Ast.arrays as a -> (Ast.map_arrays f a :> checked_expr_kind)
    | #Ast.strings as s -> (Ast.map_strings f s :> checked_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars f v :> checked_expr_kind)
    | #Ast.ops as o -> (Ast.map_ops f o :> checked_expr_kind)
    | #Ast.logic as l -> (Ast.map_logic f l :> checked_expr_kind)
    | #Ast.compound as c -> (Ast.map_compound f c :> checked_expr_kind)
    | #Ast.indexing as i -> (Ast.map_indexing f i :> checked_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple f t :> checked_expr_kind)
    | #Ast.spread as s -> (Ast.map_spread f s :> checked_expr_kind)
    | #Ast.record as r -> (Ast.map_record f r :> checked_expr_kind)
    | #Ast.nominal as n -> (Ast.map_nominal f n :> checked_expr_kind)
    | #Ast.collection as c -> (Ast.map_collection f c :> checked_expr_kind)
    | `Bound_call (receiver, name, d, args) -> `Bound_call (f receiver, name, d, List.map f args)
    | #Ast.dyn_calls as d -> (Ast.map_dyn_call f Fun.id d :> checked_expr_kind)
    | `Coerce (inner, trait, slots) -> `Coerce (f inner, trait, slots)
    | #Ast.variant_lit as v -> (Ast.map_variant_lit f v :> checked_expr_kind)
    | #Ast.object_lit as o -> (Ast.map_object_lit f o :> checked_expr_kind)
    | (`Run_block _ | `Match_expr _) as r -> r
  in
  carried ~from:e { e with Ast.it }

(* Every statement list here is the statements a check produced one at a time,
   each with what it hoisted already in front of it. *)
let hoist_stmt ctx (s : checked_stmt) : checked_stmt list =
  let span = s.Ast.span in
  let node it : checked_stmt = { s with Ast.it } in
  match s.Ast.it with
  (* Its answer goes nowhere, so it needs no name to go by. *)
  | `Expr ({ Ast.it = `Run_block _; _ } as inner) ->
    ignore (hoist_expr ctx inner);
    []
  | `Expr { Ast.it = `Match_expr (scrutinee, cases); _ } ->
    let scrutinee = hoist_expr ctx scrutinee in
    [ node (`Match (scrutinee, List.map (valued_arm ctx (fun v -> `Expr v)) cases)) ]
  (* A condition that hoisted statements runs them on every test, so they are
     written once before the loop and again at the end of its body. Taking the
     condition apart twice gives each copy names of its own. *)
  | `While (cond, body) ->
    (match hoisting ctx cond with
     | [], cond -> [ node (`While (cond, body)) ]
     | before, first ->
       let temp = fresh_answer () in
       let var : checked_expr = Ast.annotated span Types.IBool (`Var temp) in
       let again, next = hoisting ctx cond in
       let retest = node (`Expr { next with Ast.it = `Assign (temp, next) }) in
       before
       @ [ node (`Var_decl (temp, None, Some first))
         ; node (`While (var, node (`Block ((body :: again) @ [ retest ]))))
         ])
  | #Ast.stmts as st -> [ node (Ast.map_stmts (hoist_expr ctx) Fun.id st :> checked_stmt_kind) ]
  | `Match (scrutinee, cases) -> [ node (`Match (hoist_expr ctx scrutinee, cases)) ]
  | #Ast.type_defs | #Ast.method_defs -> [ s ]

let statement ctx (check : unit -> checked_stmt) : checked_stmt list =
  if not (walking ())
  then [ check () ]
  else (
    let saved = ctx.hoisted in
    ctx.hoisted <- [];
    Fun.protect
      ~finally:(fun () -> ctx.hoisted <- saved)
      (fun () ->
        let checked = check () in
        let produced = hoist_stmt ctx checked in
        List.rev ctx.hoisted @ produced))

let one_statement ctx (s : Ast.stmt) (check : unit -> checked_stmt) : checked_stmt =
  match statement ctx check with
  | [ single ] -> single
  | many -> Ast.annotated s.Ast.span Types.IUnit (`Block many)

let performed (t : Types.ty) =
  match t with
  | Types.Fn (_, _, row) -> List.map fst row.Types.labels
  | _ -> []

let evidence_param = { Ast.name = evidence; ty = None; implicit = false }


(* The functions whose every operation went to a handler their key names: they
   take no evidence, and a call hands them none. *)
let without_evidence : (string, unit) Hashtbl.t = Hashtbl.create 64

(* Whether processed code reads [name]. A lambda declaring it as well is
   counted: what this answers is only ever what can be dropped. *)
let rec reads_expr name (e : Ast.resolved_expr) =
  let go = reads_expr name in
  match e.Ast.it with
  | `Unit | `Int _ | `Bytes _ | `Name _ | `Float _ | `Str _ | `Char _ | `Bool _ -> false
  | `Var n -> String.equal n name
  | `Assign (n, v) -> String.equal n name || go v
  | `Unop (_, a) | `Tuple_get (a, _) | `Field (a, _) | `Array_len a | `Str_len a -> go a
  | `Binop (_, a, b) | `And (a, b) | `Or (a, b) | `Field_assign (a, _, b) | `Array_new (a, b)
  | `Array_get (a, b) | `Str_get (a, b) -> go a || go b
  | `Array_set (a, b, c) -> go a || go b || go c
  | `Call (callee, args) -> go callee || List.exists go args
  | `Dyn_call (receiver, _, _, args) -> go receiver || List.exists go args
  | `Tuple items | `Array_lit items -> List.exists go items
  | `Record_lit fields | `Variant (_, fields) -> List.exists (fun (_, v) -> go v) fields
  | `Object (data, _, slots) -> go data || List.exists (fun (_, v) -> go v) slots
  | `Lambda (_, _, body) -> List.exists (reads_stmt name) body

and reads_stmt name (s : Ast.resolved_stmt) =
  let expr = reads_expr name
  and stmt = reads_stmt name in
  match s.Ast.it with
  | `Expr e | `Var_tuple (_, e) | `Var_decl (_, _, Some e) | `Return (Some e) -> expr e
  | `Var_decl (_, _, None) | `Return None | `Break | `Continue | `Type_decl _ -> false
  | `Defer inner -> stmt inner
  | `Block body | `Fn (_, _, _, body) -> List.exists stmt body
  | `If (c, t, e) -> expr c || stmt t || Option.fold ~none:false ~some:stmt e
  | `While (c, body) -> expr c || stmt body
  | `Match (scrutinee, cases) -> expr scrutinee || List.exists (fun (_, body) -> List.exists stmt body) cases

let reads_evidence_stmt = reads_stmt evidence

let rec unforwarded self (e : Ast.resolved_expr) : Ast.resolved_expr =
  let e =
    match e.Ast.it with
    | `Lambda (params, sg, body) -> { e with Ast.it = `Lambda (params, sg, List.map (unforwarded_stmt self) body) }
    | _ -> Defers.children (unforwarded self) e
  in
  match e.Ast.it, List.rev (match e.Ast.it with `Call (_, args) -> args | _ -> []) with
  | `Call (({ Ast.it = `Var name; _ } as callee), _), { Ast.it = `Var last; _ } :: before
    when String.equal name self && String.equal last evidence ->
    { e with Ast.it = `Call (callee, List.rev before) }
  | _ -> e

and unforwarded_stmt self (s : Ast.resolved_stmt) : Ast.resolved_stmt =
  match s.Ast.it with
  | #Ast.stmts as st ->
    { s with Ast.it = (Ast.map_stmts (unforwarded self) (unforwarded_stmt self) st :> Ast.resolved_stmt_kind) }
  | `Match (scrutinee, cases) ->
    { s with
      Ast.it =
        `Match (unforwarded self scrutinee, List.map (fun (p, body) -> p, List.map (unforwarded_stmt self) body) cases)
    }
  | #Ast.type_defs -> s

(* A recursive function handing its own evidence to itself does not read it:
   counting that call keeps a parameter nothing else uses. *)
let reads_own_evidence self body = List.exists (fun s -> reads_evidence_stmt (unforwarded_stmt self s)) body

(* What a run left that nothing reads: a handler's value every call went past,
   and the variable for a run's value that nothing assigned. Neither does
   anything when it is made. *)
let without_unread (body : Ast.resolved_stmt list) =
  let made_by_run name = String.starts_with ~prefix:"hv#" name || String.starts_with ~prefix:"answer#" name in
  let inert (e : Ast.resolved_expr) =
    match e.Ast.it with
    | `Record_lit fields ->
      List.for_all
        (fun (_, (v : Ast.resolved_expr)) ->
          match v.Ast.it with
          | `Var _ | `Lambda _ -> true
          | _ -> false)
        fields
    | _ -> false
  in
  let kept =
    List.filter
      (fun (s : Ast.resolved_stmt) ->
        match s.Ast.it with
        | `Var_decl (name, _, init)
          when made_by_run name && Option.fold ~none:true ~some:inert init ->
          List.exists (fun other -> other != s && reads_stmt name other) body
        | _ -> true)
      body
  in
  (* A block left declaring nothing is its statements. *)
  let declares (s : Ast.resolved_stmt) =
    match s.Ast.it with
    | `Var_decl _ | `Var_tuple _ | `Fn _ | `Type_decl _ | `Defer _ -> true
    | _ -> false
  in
  List.concat_map
    (fun (s : Ast.resolved_stmt) ->
      match s.Ast.it with
      | `Block inner when not (List.exists declares inner) -> inner
      | _ -> [ s ])
    kept

(* Each label the callee performs, from the handler the call's bindings give
   it. Evidence handed in whole is passed on whole, which is the usual case. *)
let evidence_for span bindings labels : Ast.resolved_expr =
  let resolved = List.filter_map (fun label -> Option.map (fun b -> label, b) (binding_for label bindings)) labels in
  let whole = { Ast.it = `Var evidence; span; ann = Types.Unit } in
  if resolved <> [] && List.for_all (fun (_, b) -> is_own b || Option.is_some b.bd_key) resolved
  then whole
  else (
    let entries =
      List.filter_map
        (fun (label, b) ->
          match b.bd_value with
          | _ when is_own b || Option.is_some b.bd_key ->
            let fields = [ label, Types.Unit ] in
            Some (label, { Ast.it = `Field ({ whole with Ast.ann = Types.Record fields }, label); span; ann = Types.Unit })
          | Some v -> Some (label, { Ast.it = `Var v; span; ann = Types.Unit })
          | None -> None)
        resolved
    in
    { Ast.it = `Record_lit entries; span; ann = Types.Record (List.map (fun (l, _) -> l, Types.Unit) entries) })

(* An operation its function's own evidence answers: the handler's method,
   read from the evidence. *)
let evidence_operation span bindings name (callee_ty : Types.ty) =
  match Hashtbl.find_opt ctx_op_owner name with
  | Some label ->
    (match binding_for label bindings with
     | Some b when is_own b ->
       let prefix = Ast.operation_name label "" in
       let short = String.sub name (String.length prefix) (String.length name - String.length prefix) in
       let at_root =
         match b.bd_key, !root_bindings with
         | Some key, Some bound when String.equal key root_key && evidence_passed label ->
           (match binding_for label bound with
            | Some r when not (is_own r) -> Hashtbl.find_opt lifted_methods (r.bd_handler, short)
            | _ -> None)
         | _ -> None
       in
       (match at_root with
        | Some (fn, fn_ty) ->
          let fn_ty =
            match Types.resolve fn_ty with
            | Types.Fn (ps, r, _) -> Types.Fn (ps, r, { Types.labels = []; tail = None })
            | t -> t
          in
          Some { Ast.it = `Var fn; span; ann = fn_ty }
        | None ->
          let callee_ty =
            match callee_ty with
            | Types.Fn (ps, r, _) -> Types.Fn (ps, r, { Types.labels = []; tail = None })
            | t -> t
          in
          let handler = Types.Record [ short, callee_ty ] in
          let whole = { Ast.it = `Var evidence; span; ann = Types.Record [ label, handler ] } in
          let read = { Ast.it = `Field (whole, label); span; ann = handler } in
          Some { Ast.it = `Field (read, short); span; ann = callee_ty })
     | _ -> None)
  | None -> None

(* [t] with the generic [id] put back as [by], and every other variable, which
   nothing reads, settled as `Unit` or a closed row. *)
let rec generic_as id by (t : Types.ty) : Types.ty =
  let go = generic_as id by in
  let row (r : Types.row) =
    { Types.labels = List.map (fun (l, args) -> l, List.map go args) r.Types.labels; tail = None }
  in
  match t with
  | Types.Generic g when g = id -> by
  | Types.Generic _ -> Types.Unit
  | Types.Tuple items -> Types.Tuple (List.map go items)
  | Types.Pack items -> Types.Pack (List.map go items)
  | Types.Spread inner -> Types.Spread (go inner)
  | Types.Record fields -> Types.Record (List.map (fun (l, t) -> l, go t) fields)
  | Types.Named (n, args) -> Types.Named (n, List.map go args)
  | Types.Sum (n, args) -> Types.Sum (n, List.map go args)
  | Types.Fn (ps, r, rw) -> Types.Fn (List.map go ps, go r, row rw)
  | Types.Row r -> Types.Row (row r)
  | t -> t

(* A function value whose type takes control though nothing in it splits: it
   is handed its handlers and what [Core.handed] lists, and its body is that
   declaration's, with what the value returns put for the first parameter. *)
let wrapped span (ann : Types.ty) params (signature : Ast.signature) body taken : Ast.resolved_expr_kind =
  let at it ann : Ast.resolved_expr = { Ast.it; span; ann } in
  let pure = { Types.labels = []; tail = None } in
  let ps, ret =
    match ann with
    | Types.Fn (ps, ret, _) -> ps, ret
    | _ -> [], Types.Unit
  in
  let _, written, shape_body = shape Core.handed in
  let returned = Types.fresh () in
  Types.declare_param returned;
  let types =
    handed_params Core.handed ~result:returned ~answer:(Types.fresh ()) ~row:(Types.fresh_row ())
    |> List.map (fun t -> generic_as (Types.var_id returned) ret (Types.resolve t))
  in
  let value_param, rest =
    match written with
    | v :: rest -> v.Ast.name, rest
    | [] -> fail span "'%s' takes no parameter for what a function value returns." Core.handed
  in
  let handed = List.map (fun (p : Ast.param) -> p.Ast.name, Ast.generated [ p.Ast.name; "wrapped" ]) rest in
  let typed = List.combine (List.map snd handed) types in
  let inner =
    at (`Lambda (params, plain_signature, body)) (Types.Fn (ps, ret, pure))
  in
  let value =
    at
      (`Call (inner, List.map2 (fun (p : Ast.param) t -> at (`Var p.Ast.name) t) params ps))
      ret
  in
  let rec put (e : Ast.expr) : Ast.resolved_expr =
    match e.Ast.it with
    | `Var n when String.equal n value_param -> value
    | `Var n when List.mem_assoc n handed ->
      let n = List.assoc n handed in
      at (`Var n) (List.assoc n typed)
    | `Call (f, args) ->
      let f = put f in
      (match f.Ast.ann with
       | Types.Fn (_, r, _) -> at (`Call (f, List.map put args)) r
       | _ -> fail e.Ast.span "'%s' calls what is not a function." Core.handed)
    | _ -> fail e.Ast.span "The body of '%s' is to be one call of its parameters." Core.handed
  in
  let result =
    match shape_body with
    | [ { Ast.it = `Return (Some e); _ } ] -> put e
    | _ -> fail span "The body of '%s' is to be one call of its parameters." Core.handed
  in
  let handlers = List.map (fun label -> { Ast.name = handler_param label; ty = None; implicit = false }) taken in
  let handed = List.map (fun (_, n) -> { Ast.name = n; ty = None; implicit = false }) handed in
  let evidence = if performed ann = [] then [] else [ evidence_param ] in
  `Lambda
    ( params @ handlers @ handed @ evidence
    , { signature with Ast.static_params = { Ast.sp_name = Ast.handed_marker; sp_ty = None; sp_pack = false } :: signature.Ast.static_params }
    , [ { Ast.it = `Return (Some result); span; ann = Types.Unit } ] )

(* A call of a handler's method made a function, written in its caller: the
   arguments put for the parameters, and a match on a parameter given a
   variant with nothing in it reduced to that variant's arm. Only a body of
   one expression once that is done, with no function value in it, and only
   where each argument is evaluated exactly once, as the call would. *)
let inlined (body : Ast.resolved_stmt list) params (args : Ast.resolved_expr list) : Ast.resolved_expr option =
  let names = List.map (fun (p : Ast.param) -> p.Ast.name) params in
  if List.length names <> List.length args
  then None
  else (
    let bound = List.combine names args in
    let rec single = function
      | [ ({ Ast.it = `Block inner; _ } : Ast.resolved_stmt) ] -> single inner
      | [ { Ast.it = `Match ({ Ast.it = `Var p; _ }, cases); _ } ] as stmts ->
        (match List.assoc_opt p bound with
         | Some { Ast.it = `Variant (v, []); _ } ->
           let arm =
             List.find_opt
               (fun (pattern, _) ->
                 match pattern with
                 | Ast.Pat_variant (_, v', _) -> String.equal v v' && Ast.pattern_names pattern = []
                 | Ast.Pat_wild -> true)
               cases
           in
           (match arm with
            | Some (_, body) -> single body
            | None -> stmts)
         | _ -> stmts)
      | stmts -> stmts
    in
    let expr =
      match single body with
      | [ { Ast.it = `Expr e | `Return (Some e); _ } ] -> Some e
      | _ -> None
    in
    Option.bind expr (fun e ->
      let uses = Hashtbl.create 4 in
      let plain = ref true in
      let rec count (e : Ast.resolved_expr) =
        (match e.Ast.it with
         | `Var n -> Hashtbl.replace uses n (1 + Option.value ~default:0 (Hashtbl.find_opt uses n))
         | `Assign (n, _) when List.mem n names -> plain := false
         | `Lambda _ -> plain := false
         | _ -> ());
        ignore (Defers.children (fun c -> count c; c) e)
      in
      count e;
      let trivial (a : Ast.resolved_expr) =
        match a.Ast.it with
        | #Ast.lit | `Var _ | `Variant (_, []) -> true
        | _ -> false
      in
      let once =
        List.for_all
          (fun (n, a) -> trivial a || Option.value ~default:0 (Hashtbl.find_opt uses n) = 1)
          bound
      in
      let evaluated = List.length (List.filter (fun a -> not (trivial a)) args) <= 1 in
      if not (!plain && once && evaluated)
      then None
      else (
        let rec put (e : Ast.resolved_expr) =
          match e.Ast.it with
          | `Var n when List.mem_assoc n bound -> List.assoc n bound
          | _ -> Defers.children put e
        in
        Some (put e))))

(* The walk's tree once its root statement is done: every type settled, and
   what could not be lowered while it was checked lowered now. *)
let rec processed_expr registry (e : checked_expr) : Ast.resolved_expr =
  let go = processed_expr registry in
  let span = e.Ast.span in
  if unsettled e.Ast.ann && not (is_erroneous e.Ast.ann)
  then
    fail
      span
      "This is not settled when its statement ends: its type is %s, and nothing fixes it. \
       Write the type."
      (Types.string_of_ty (Types.resolve e.Ast.ann));
  let ann = Types.resolve e.Ast.ann in
  let again () =
    match lowered ~at_end:true registry e with
    | Some l when l != e -> Some (go l)
    | _ -> None
  in
  let it : Ast.resolved_expr_kind =
    match e.Ast.it with
    | `Var placeholder when Hashtbl.mem placeholders placeholder ->
      `Var (Hashtbl.find placeholders placeholder)
    | ( `Binop _ | `Unop ((Ast.Neg | Ast.Bit_not), _) | `Index _ | `Index_assign _
      | `Collection_lit _ | `Coerce _ | `Bound_call _ | `New _ | `New_variant _ ) as kind ->
      (match again (), kind with
       | Some done_, _ -> done_.Ast.it
       | None, `Binop (op, a, b) -> `Binop (op, go a, go b)
       | None, `Unop (op, a) -> `Unop (op, go a)
       | None, _ -> fail span "This is not settled when its statement ends.")
    | #Ast.lit as l -> l
    | `Lambda (params, signature, body) ->
      let with_evidence params =
        if is_plain signature || performed ann = [] then params else params @ [ evidence_param ]
      in
      let body = processed_block registry body in
      (match controlling_ty ann with
       | taken when taken <> [] && not (is_handed signature || is_plain signature) ->
         wrapped span ann params signature body taken
       | _ -> `Lambda (with_evidence params, signature, body))
    | `Call (({ Ast.it = `Var main; _ } as callee), [])
      when !root_main_bare
           && (match !root_call with
               | Some { Ast.it = `Call ({ Ast.it = `Var called; _ }, []); span; _ } ->
                 String.equal called main && span = e.Ast.span
               | _ -> false) ->
      let callee' = go callee in
      let bare =
        match callee'.Ast.ann with
        | Types.Fn (ps, r, _) -> Types.Fn (ps, r, { Types.labels = []; tail = None })
        | t -> t
      in
      `Call ({ callee' with Ast.ann = bare }, [])
    | `Call (({ Ast.it = `Var root; _ } as callee), [ ({ Ast.it = `Lambda (params, signature, body); _ } as main) ])
      when Hashtbl.mem root_instances root
           && controlling_ty (Types.resolve main.Ast.ann) = []
           && not (is_handed signature || is_plain signature) ->
      let main_ann = Types.resolve main.Ast.ann in
      let body = processed_block registry body in
      let reads = List.exists reads_evidence_stmt body in
      root_main_bare := not reads;
      let params = if reads && performed main_ann <> [] then params @ [ evidence_param ] else params in
      (* Marked as a transform's function, which takes no evidence, so its
         type still says what it performs. *)
      let signature = if reads then signature else { signature with Ast.static_params = plain_signature.Ast.static_params @ signature.Ast.static_params } in
      `Call (go callee, [ { Ast.it = `Lambda (params, signature, body); span = main.Ast.span; ann = main_ann } ])
    | `Call (callee, args) ->
      let bindings = Option.value ~default:[ own_frame ] (Checked_table.find_opt bindings_at e) in
      let callee' = go callee in
      let args = processed_arguments registry args in
      (match callee.Ast.it with
       | `Var name when Hashtbl.mem ctx_effects.ops name ->
         (match evidence_operation span bindings name callee'.Ast.ann with
          | Some handler -> `Call (handler, args)
          | None -> `Call (callee', args))
       | _ ->
         (match performed callee'.Ast.ann, callee'.Ast.it, callee'.Ast.ann with
          | [], _, _ -> `Call (callee', args)
          | _, `Var name, Types.Fn (ps, r, _) when Hashtbl.mem without_evidence name ->
            `Call ({ callee' with Ast.ann = Types.Fn (ps, r, { Types.labels = []; tail = None }) }, args)
          | labels, _, _ -> `Call (callee', args @ [ evidence_for span bindings labels ])))
    | `Dyn_call (receiver, name, performs, args) ->
      let bindings = Option.value ~default:[ own_frame ] (Checked_table.find_opt bindings_at e) in
      let performs = Types.resolve performs in
      let args = processed_arguments registry args in
      let args =
        match performed performs with
        | [] -> args
        | labels -> args @ [ evidence_for span bindings labels ]
      in
      `Dyn_call (go receiver, name, performs, args)
    | #Ast.arrays as a -> (Ast.map_arrays go a :> Ast.resolved_expr_kind)
    | #Ast.strings as s -> (Ast.map_strings go s :> Ast.resolved_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars go v :> Ast.resolved_expr_kind)
    | `Unop (op, a) -> `Unop (op, go a)
    | #Ast.logic as l -> (Ast.map_logic go l :> Ast.resolved_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple go t :> Ast.resolved_expr_kind)
    | #Ast.record as r -> (Ast.map_record go r :> Ast.resolved_expr_kind)
    | #Ast.variant_lit as v -> (Ast.map_variant_lit go v :> Ast.resolved_expr_kind)
    | #Ast.object_lit as o -> (Ast.map_object_lit go o :> Ast.resolved_expr_kind)
    | #Ast.compound | `New_call _ | `Spread _ | `Run_block _ | `Match_expr _ ->
      fail span "This should have been taken apart while it was checked."
  in
  (* The length intrinsics answer with an int whatever the caller pinned. *)
  let ann =
    match it with
    | `Array_len _ | `Str_len _ -> Types.Int
    | _ -> ann
  in
  { Ast.it; span; ann }

(* A tuple spread into an argument list is as many arguments as it holds. *)
and processed_arguments registry (args : checked_expr list) : Ast.resolved_expr list =
  List.concat_map
    (fun (a : checked_expr) ->
      match a.Ast.it with
      | `Spread inner ->
        let inner = processed_expr registry inner in
        let held =
          match inner.Ast.ann with
          | Types.Tuple items -> Types.expand_ty items
          | Types.Unit -> []
          | other -> fail inner.Ast.span "A spread takes a tuple, not %s." (Types.string_of_ty other)
        in
        List.mapi (fun index ann -> { Ast.it = `Tuple_get (inner, index); span = a.Ast.span; ann }) held
      | _ -> [ processed_expr registry a ])
    args

and processed_stmt registry (s : checked_stmt) : Ast.resolved_stmt list =
  let span = s.Ast.span in
  let node it : Ast.resolved_stmt = { Ast.it; span; ann = Types.resolve s.Ast.ann } in
  let go = processed_expr registry in
  match s.Ast.it with
  | `Block body -> [ node (`Block (processed_block registry body)) ]
  | `Fn (name, _, _, _) when Hashtbl.mem lifted_processed name -> Hashtbl.find lifted_processed name
  | `Fn (name, params, signature, body) when Hashtbl.mem lifted_checked name ->
    let processed = [ node (`Fn (name, params, signature, processed_block registry body)) ] in
    Hashtbl.replace lifted_processed name processed;
    processed
  | `Expr e ->
    let e = go e in
    [ node (`Expr (inline_lifted registry e)) ]
  | `Return (Some e) ->
    let e = go e in
    [ node (`Return (Some (inline_lifted registry e))) ]
  | `Fn (name, params, signature, body) ->
    let ty = Types.resolve s.Ast.ann in
    let body = processed_block registry body in
    let evidenced = not (is_plain signature || performed ty = []) in
    let takes = evidenced && (controlling_ty ty <> [] || reads_own_evidence name body) in
    if evidenced && not takes then Hashtbl.replace without_evidence name ();
    let params = if takes then params @ [ evidence_param ] else params in
    [ node (`Fn (name, params, signature, body)) ]
  | #Ast.stmts as st -> [ node (Ast.map_stmts go (processed_one registry) st :> Ast.resolved_stmt_kind) ]
  | `Match (scrutinee, cases) ->
    [ node (`Match (go scrutinee, List.map (fun (p, body) -> p, processed_block registry body) cases)) ]
  | #Ast.type_defs as t -> [ node t ]
  | `Trait_decl _ -> []
  | `Impl_decl _ -> fail span "An impl reaches the walk only as the instances of its methods."

and processed_block registry body = without_unread (List.concat_map (processed_stmt registry) body)

and inline_lifted registry (call : Ast.resolved_expr) : Ast.resolved_expr =
  match call.Ast.it with
  | `Call ({ Ast.it = `Var fn; _ }, args) when Hashtbl.mem lifted_checked fn ->
    let processed =
      match Hashtbl.find_opt lifted_processed fn with
      | Some p -> p
      | None -> processed_stmt registry (Hashtbl.find lifted_checked fn)
    in
    (match processed with
     | [ { Ast.it = `Fn (_, params, sg, body); _ } ] when sg.Ast.inline ->
       Option.value ~default:call (inlined body params args)
     | _ -> call)
  | _ -> call

and processed_one registry (s : checked_stmt) : Ast.resolved_stmt =
  match processed_stmt registry s with
  | [ single ] -> single
  | many -> { Ast.it = `Block many; span = s.Ast.span; ann = Types.resolve s.Ast.ann }

(* `var f = someGenericFn; f = otherFn;` would otherwise check. *)
(* A statement whose check stands anywhere it is moved: nothing in it leaves
   it but by finishing, and it declares no function, whose instances its block
   would hold. A function value may hold anything, since it runs where it is
   called. Read once it is checked, for what its meta blocks generated. *)
let stands_alone (s : Ast.stmt) =
  let exception Leaves in
  let rec expr (e : Ast.expr) =
    match e.Ast.it with
    | `Lambda _ | #Ast.quote | `Declof _ | `Pre_checked _ -> ()
    | `Run_expr (_, body, _) -> valued body
    | `Match_expr (scrutinee, cases) ->
      expr scrutinee;
      List.iter (fun (_, b) -> valued b) cases
    | `Meta_expr _ ->
      (match Physical.find_opt meta_exprs e with
       | Some made -> expr made
       | None -> raise Leaves)
    | `New_generic (_, _, fields) -> List.iter (fun (_, v) -> expr v) fields
    | #Ast.lit -> ()
    | #Ast.vars as v -> ignore (Ast.map_vars (fun e -> expr e; e) v)
    | #Ast.ops as o -> ignore (Ast.map_ops (fun e -> expr e; e) o)
    | #Ast.logic as l -> ignore (Ast.map_logic (fun e -> expr e; e) l)
    | #Ast.compound as c -> ignore (Ast.map_compound (fun e -> expr e; e) c)
    | #Ast.indexing as i -> ignore (Ast.map_indexing (fun e -> expr e; e) i)
    | #Ast.tuple as t -> ignore (Ast.map_tuple (fun e -> expr e; e) t)
    | #Ast.spread as x -> ignore (Ast.map_spread (fun e -> expr e; e) x)
    | #Ast.record as r -> ignore (Ast.map_record (fun e -> expr e; e) r)
    | #Ast.nominal as n -> ignore (Ast.map_nominal (fun e -> expr e; e) n)
    | #Ast.collection as c -> ignore (Ast.map_collection (fun e -> expr e; e) c)
    | #Ast.static_call as c -> ignore (Ast.map_static_call (fun e -> expr e; e) c)
    | #Ast.method_call as m -> ignore (Ast.map_method_call (fun e -> expr e; e) m)
    | #Ast.reflect as r -> ignore (Ast.map_reflect (fun e -> expr e; e) r)
  and valued (b : (Ast.expr, Ast.stmt) Ast.valued_block) =
    List.iter (stmt ~looped:false) b.Ast.vb_stmts;
    Option.iter expr b.Ast.vb_value
  and stmt ~looped (s : Ast.stmt) =
    match s.Ast.it with
    | `Expr e -> expr e
    | `Var_decl (_, _, init) -> Option.iter expr init
    | `Var_tuple (_, init) -> expr init
    | `Block body -> List.iter (stmt ~looped) body
    | `If (c, t, e) ->
      expr c;
      stmt ~looped t;
      Option.iter (stmt ~looped) e
    | `While (c, body) ->
      expr c;
      stmt ~looped:true body
    | `For_in (_, over, body) ->
      expr over;
      stmt ~looped:true body
    | `Match (scrutinee, cases) ->
      expr scrutinee;
      List.iter (fun (_, body) -> List.iter (stmt ~looped) body) cases
    | (`Break | `Continue) when looped -> ()
    | `Attributed (_, inner) -> stmt ~looped inner
    | `Meta _ ->
      (match Physical_stmt.find_opt meta_stmts s with
       | Some made -> List.iter (stmt ~looped) made
       | None -> raise Leaves)
    | _ -> raise Leaves
  in
  match s.Ast.it with
  | `Expr _ | `Var_decl _ | `Var_tuple _ | `Block _ | `If _ | `While _ | `For_in _ | `Match _ ->
    (try
       stmt ~looped:false s;
       true
     with
     | Leaves -> false)
  | _ -> false

let is_syntactic_value (e : Ast.expr) =
  match e.Ast.it with
  | #Ast.lit | `Var _ -> true
  | _ -> false

let rec assigned_in_expr (e : Ast.expr) acc =
  match e.Ast.it with
  (* What a lambda assigns it assigns when called, not where it stands. *)
  | `Lambda _ -> acc
  | #Ast.lit | `Var _ | `Declof _ | `Meta_expr _ | `Static_ref _ -> acc
  | `Pre_checked n ->
    (match passed_view n with
     | Some (`Expr e) -> assigned_in_expr e acc
     | Some (`Stmt s) -> assigned_in_stmt s acc
     | Some (`Stmts body) -> List.fold_left (fun acc st -> assigned_in_stmt st acc) acc body
     | None -> acc)
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
  | `New (_, fields) | `New_generic (_, _, fields) ->
    List.fold_left (fun acc (_, v) -> assigned_in_expr v acc) acc fields
  | `Code _ | `Code_stmts _ | `Code_decl _ -> acc
  | `New_call (_, _, args) ->
    List.fold_left (fun acc a -> assigned_in_expr a acc) acc args
  | `New_variant (_, _, payload) ->
    List.fold_left
      (fun acc (_, v) -> assigned_in_expr v acc)
      acc
      (Ast.payload_fields payload)
  | `Run_expr (_, body, _) ->
    let acc = List.fold_left (fun acc st -> assigned_in_stmt st acc) acc body.Ast.vb_stmts in
    Option.fold ~none:acc ~some:(fun v -> assigned_in_expr v acc) body.Ast.vb_value
  | `Match_expr (scrutinee, cases) ->
    List.fold_left
      (fun acc (_, (b : (Ast.expr, Ast.stmt) Ast.valued_block)) ->
        let acc = List.fold_left (fun acc st -> assigned_in_stmt st acc) acc b.Ast.vb_stmts in
        Option.fold ~none:acc ~some:(fun v -> assigned_in_expr v acc) b.Ast.vb_value)
      (assigned_in_expr scrutinee acc)
      cases

and assigned_in_stmt (s : Ast.stmt) acc =
  let opt f o acc =
    match o with
    | Some x -> f x acc
    | None -> acc
  in
  match s.Ast.it with
  | `Pre_checked n ->
    (match passed_view n with
     | Some (`Expr e) -> assigned_in_expr e acc
     | Some (`Stmt s) -> assigned_in_stmt s acc
     | Some (`Stmts body) -> List.fold_left (fun acc st -> assigned_in_stmt st acc) acc body
     | None -> acc)
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
  | `Type_decl _ | `Trait_decl _ -> acc
  | `Impl_decl (_, _, _, impl) ->
    List.fold_left
      (fun acc (m : (Ast.stmt, unit) Ast.method_def) ->
        List.fold_left (fun acc st -> assigned_in_stmt st acc) acc m.Ast.md_body)
      acc
      impl.Ast.ib_methods
  | `Match (scrutinee, cases) ->
    List.fold_left
      (fun acc (_, body) ->
        List.fold_left (fun acc st -> assigned_in_stmt st acc) acc body)
      (assigned_in_expr scrutinee acc)
      cases
  | `Attributed (_, inner) -> assigned_in_stmt inner acc
  | `Import _ | `Global_import _ | #Ast.meta_blocks | `Type_members _ | `Trait_members _ -> acc

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
let names_used (s : Ast.stmt) =
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
      (fun (s : Ast.stmt) ->
        match s.Ast.it with
        | `Fn (name, _, _, _) -> Some name
        | _ -> None)
      body
  in
  let param_names = List.map (fun (p : Ast.param) -> p.Ast.name) in
  let rec expr (e : Ast.expr) =
    (match e.Ast.it with
     | `Var name | `Assign (name, _) | `Compound (_, name, _) | `New_call (name, _, _) -> value name
     | `Method_call (_, name, as_function, _, _) ->
       note (Member name);
       value as_function
     | _ -> ());
    match e.Ast.it with
    | `Pre_checked n ->
      (match passed_view n with
       | Some (`Expr e) -> expr e
       | Some (`Stmt s) -> stmt s
       | Some (`Stmts body) -> List.iter stmt body
       | None -> ())
    | `Lambda (ps, _, body) -> scoped (fun () -> bind (param_names ps); block body)
    | `Run_expr (_, body, _) -> valued body
    | `Match_expr (scrutinee, cases) ->
      expr scrutinee;
      List.iter (fun (p, b) -> scoped (fun () -> bind (Ast.pattern_names p); valued b)) cases
    | _ ->
      let (_ : Ast.expr_kind) =
        match e.Ast.it with
        | `Lambda _ | `Run_expr _ | `Match_expr _ | #Ast.quote | `Declof _ | `Meta_expr _ | `Pre_checked _ -> e.Ast.it
        | `New_generic (_, _, fields) ->
          List.iter (fun (_, v) -> expr v) fields;
          e.Ast.it
        | #Ast.lit as l -> l
        | #Ast.vars as v -> (Ast.map_vars (fun e -> expr e; e) v :> Ast.expr_kind)
        | #Ast.ops as o -> (Ast.map_ops (fun e -> expr e; e) o :> Ast.expr_kind)
        | #Ast.logic as l -> (Ast.map_logic (fun e -> expr e; e) l :> Ast.expr_kind)
        | #Ast.compound as c -> (Ast.map_compound (fun e -> expr e; e) c :> Ast.expr_kind)
        | #Ast.indexing as i -> (Ast.map_indexing (fun e -> expr e; e) i :> Ast.expr_kind)
        | #Ast.tuple as t -> (Ast.map_tuple (fun e -> expr e; e) t :> Ast.expr_kind)
        | #Ast.spread as x -> (Ast.map_spread (fun e -> expr e; e) x :> Ast.expr_kind)
        | #Ast.record as r -> (Ast.map_record (fun e -> expr e; e) r :> Ast.expr_kind)
        | #Ast.nominal as n -> (Ast.map_nominal (fun e -> expr e; e) n :> Ast.expr_kind)
        | #Ast.collection as c -> (Ast.map_collection (fun e -> expr e; e) c :> Ast.expr_kind)
        | #Ast.static_call as c ->
          (Ast.map_static_call (fun e -> expr e; e) c :> Ast.expr_kind)
        | #Ast.method_call as m ->
          (Ast.map_method_call (fun e -> expr e; e) m :> Ast.expr_kind)
        | #Ast.reflect as r -> (Ast.map_reflect (fun e -> expr e; e) r :> Ast.expr_kind)
      in
      ()
  and valued (b : (Ast.expr, Ast.stmt) Ast.valued_block) =
    scoped (fun () ->
      bind (declared_fns b.Ast.vb_stmts);
      List.iter stmt b.Ast.vb_stmts;
      Option.iter expr b.Ast.vb_value)
  (* A function declared in a block is in scope for all of it. *)
  and block body =
    bind (declared_fns body);
    List.iter stmt body
  and nested (s : Ast.stmt) = scoped (fun () -> stmt s)
  and stmt (s : Ast.stmt) =
    match s.Ast.it with
    | `Pre_checked n ->
      (match passed_view n with
       | Some (`Expr e) -> expr e
       | Some (`Stmt s) -> stmt s
       | Some (`Stmts body) -> List.iter stmt body
       | None -> ())
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
    | `Attributed (_, inner) -> stmt inner
    | `Import _ | `Global_import _ | #Ast.meta_blocks | `Type_members _ | `Trait_members _ -> ()
    | #Ast.type_defs -> ()
    | `Trait_decl _ -> ()
    | `Impl_decl (_, _, _, impl) ->
      List.iter
        (fun (m : (Ast.stmt, unit) Ast.method_def) ->
          scoped (fun () -> bind (param_names m.Ast.md_params); block m.Ast.md_body))
        impl.Ast.ib_methods
  in
  stmt s;
  Hashtbl.fold (fun name () acc -> name :: acc) used []

let rec names_declared (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) | `Var_decl (name, _, _) -> [ Value name ]
  | `Var_tuple (names, _) -> List.map (fun name -> Value name) names
  (* The root's body declares the top level's globals. *)
  | `Expr { Ast.it = `Call ({ Ast.it = `Var root; _ }, [ { Ast.it = `Lambda (_, _, body); _ } ]); _ }
    when Ast.is_root root ->
    List.concat_map names_declared body
  | `Impl_decl (trait, type_name, _, impl) ->
    List.concat_map
      (fun (m : (Ast.stmt, unit) Ast.method_def) ->
        [ Member m.Ast.md_name; Value (Ast.impl_method_name trait type_name m.Ast.md_name) ])
      impl.Ast.ib_methods
  | _ -> []

(* A block's statements, by index, in the groups they are checked in: the
   strongly connected components of what each uses and declares, dependencies
   first and otherwise in source order. A function is generalized only once
   what it calls has been: a call to one still carrying [hoist]'s binding
   unifies with that binding's row, which then stays free in the environment
   and is fixed by whatever calls the caller -- at the top level, to the row
   the root's body gives a statement. Statements that are not declarations keep their
   source order among themselves, so a shadowing or an assignment is never
   checked out of turn. *)
let dependency_order (body : Ast.stmt list) : int list list =
  let stmts = Array.of_list body in
  let n = Array.length stmts in
  let declared_by = Hashtbl.create 64 in
  Array.iteri
    (fun i s -> List.iter (fun name -> Hashtbl.add declared_by name i) (names_declared s))
    stmts;
  let deps = Array.make n [] in
  let previous = ref None in
  Array.iteri
    (fun i (s : Ast.stmt) ->
      let chained =
        match s.Ast.it with
        | `Fn _ | `Impl_decl _ | `Trait_decl _ | `Type_decl _ -> []
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
  List.rev !groups

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
                  (signature_of env fn scheme)
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
let name_implicit_params_from (expected : Types.infer_ty list) (args : Ast.expr list) =
    List.mapi
      (fun index (arg : Ast.expr) ->
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

let name_implicit_params (callee : Types.infer_ty) (args : Ast.expr list) =
  match Types.repr callee with
  | Types.IFn (expected, _, _) -> name_implicit_params_from expected args
  | _ -> args

let constructs env ctx name =
  lookup env name = None
  && (String.equal name Types.array_name || Registry.constructor ctx.registry name <> None)

(* A call to a variadic function, with its trailing arguments bundled into the
   one argument they are passed as. *)
let collected span (callee : Ast.expr) (args : Ast.expr list) =
  match callee.Ast.it with
  | `Var name ->
    (match Hashtbl.find_opt ctx_variadic_arity name with
     | Some (fixed, packed) when List.length args >= fixed ->
       let before = List.filteri (fun i _ -> i < fixed) args
       and rest = List.filteri (fun i _ -> i >= fixed) args in
       let bundle : Ast.expr_kind =
         match packed, rest with
         (* A product of none is `Unit`, and nothing later reads an empty tuple
            as one. *)
         | true, [] -> `Unit
         | true, rest -> `Tuple rest
         | false, rest -> `Collection_lit rest
       in
       before @ [ Ast.at span bundle ]
     | _ -> args)
  | _ -> args

let declared_variant env ty variant =
  match lookup env ty, Hashtbl.find_opt ctx_types ty with
  | None, Some (Sum (_, variants)) -> List.assoc_opt variant variants
  | _ -> None

(* Each effect `H` implements, as itself or through `EffectHandler`. *)
let implemented_by name =
  Hashtbl.fold
    (fun (ty, trait) args acc ->
      if not (String.equal ty name)
      then acc
      else (
        match Hashtbl.find_opt trait_instances trait with
        | Some (base, handled :: result) when String.equal base Core.effect_handler ->
          (match handled with
           | Some e ->
             let label = Ast.written_type e in
             let label_args =
               match e.Ast.it with
               | Ast.Ty_app (_, a) -> List.map infer_ty_of_annotation a
               | _ -> []
             in
             (label, label_args, List.concat_map Option.to_list result) :: acc
           | None -> acc)
        | Some _ -> acc
        | None ->
          if String.equal trait Core.effect_handler
          then (
            match args with
            | Types.INamed (label, label_args) :: _ -> (label, label_args, []) :: acc
            | _ -> acc)
          else if Hashtbl.mem ctx_effects.declared trait
          then (trait, args, []) :: acc
          else acc))
    ctx_impls
    []

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

let method_of_operation label op =
  let prefix = Ast.operation_name label "" in
  let n = String.length prefix in
  if String.length op > n && String.equal (String.sub op 0 n) prefix
  then String.sub op n (String.length op - n)
  else op

(* A named handler's value calls its impl's method for an operation that takes
   control with the continuation the record is handed, which nothing else
   writes. *)
let named_method_call name args =
  match Hashtbl.find_opt ctx_effects.ops name, Hashtbl.find_opt ctx_op_owner name with
  | Some op, Some label ->
    op.Ast.op_kind <> Ast.Op_fn
    && List.length args = List.length op.Ast.op_params + (if Ast.aborts op.Ast.op_attrs then 0 else 1)
    && (match binding_for label !effect_bindings with
        | Some b -> (not (is_own b)) && b.bd_value = None
        | None -> false)
  | _ -> false

(* The handler a function taking control is handed for [label]: a record of
   the effect's methods, one that takes control answering whatever its
   continuation does at each call and performing what its continuation
   does, `(…, (A) -> <ρ> R) -> <ρ> R`, then handed what [method_shape]
   lists; and before that, the record as the operations show the methods. *)
let handler_types ?answer label (args : Types.infer_ty list) =
  let ops = Option.value ~default:[] (Hashtbl.find_opt ctx_effects.declared label) in
  let names = List.map fst (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params label)) in
  let bound =
    if List.length names = List.length args
    then List.combine names args
    else List.map (fun n -> n, Types.fresh ()) names
  in
  with_type_params bound (fun () ->
    let field (o : Ast.op_decl) =
      let own =
        List.map
          (fun n ->
            let v = Types.fresh () in
            Types.declare_param v;
            n, v)
          o.Ast.op_tparams
      in
      with_type_params own (fun () ->
        let params = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) o.Ast.op_params in
        let result = annotated_or_fresh o.Ast.op_ret in
        let shown, ty =
          if o.Ast.op_kind = Ast.Op_fn
          then (
            let ty = Types.IFn (params, result, Types.fresh_row ()) in
            ty, ty)
          else (
            let answer =
              match answer with
              | Some a -> a
              | None ->
                let a = Types.fresh () in
                Types.declare_param a;
                a
            in
            let rho = Types.fresh_row () in
            let continuation = if Ast.aborts o.Ast.op_attrs then [] else [ Types.IFn ([ result ], answer, rho) ] in
            let handed = handed_params (method_shape o) ~result:answer ~answer ~row:rho in
            Types.IFn (params @ continuation, answer, rho), Types.IFn (params @ continuation @ handed, answer, rho))
        in
        method_of_operation label o.Ast.op_name, shown, ty)
    in
    let fields = List.map field ops in
    let record pick =
      Types.IRecord (List.fold_right (fun f rest -> Types.FCons (fst (pick f), snd (pick f), rest)) fields Types.FEmpty)
    in
    record (fun (m, shown, _) -> m, shown), record (fun (m, _, ty) -> m, ty))

let handler_type ?answer label args = snd (handler_types ?answer label args)

(* A named handler's value as its methods are written, beside the one in
   [handler_values] a function taking control is handed. *)
let handler_shown : (string, Types.infer_ty) Hashtbl.t = Hashtbl.create 8

let param_handlers = ref 0

(* The binding a function's own handler parameter makes: what it performs of
   that effect is answered by the handler it is handed. *)
let param_binding label ty =
  incr param_handlers;
  let handler = Ast.generated [ "param"; string_of_int !param_handlers ] in
  Hashtbl.replace handler_values handler ty;
  { bd_label = label; bd_handler = handler; bd_value = Some (handler_param label); bd_outer = []; bd_key = None }

(* A handler's method, as a call shows it: it answers what it performs where
   its run stands, so it takes no evidence. *)
let answered (t : Types.infer_ty) =
  match Types.repr t with
  | Types.IFn (ps, r, _) -> Types.IFn (ps, r, Types.REmpty)
  | t -> t

let named_binding op =
  match Hashtbl.find_opt ctx_op_owner op with
  | Some label ->
    (match binding_for label !effect_bindings with
     | Some b -> (not (is_own b)) && (b.bd_value = None || Hashtbl.mem named_handlers b.bd_handler)
     | None -> false)
  | None -> false

let is_handler_value v = List.exists (fun b -> (not (is_own b)) && b.bd_value = Some v) !effect_bindings

(* A copy of [t] with each variable a handler method left to its caller, an
   operation's own parameter, fresh: one method serves every call. A copy the
   call leaves open is what a call to the operation leaves open, as `throw<T>`'s
   [T] in a statement that discards it. *)
let per_call (t : Types.infer_ty) =
  let free = Types.free_vars t in
  let own =
    List.filter_map (fun (id, _) -> if Hashtbl.mem Types.declared_params id then Some id else None) free
  in
  let copy = Types.instantiate { Types.quantified = own; quantified_rows = []; quantified_fields = []; body = t } in
  List.iter
    (fun (id, _) -> if not (List.mem_assoc id free) then Hashtbl.replace unobservable id ())
    (Types.free_vars copy);
  copy

(* A call to an operation a run bound: the handler's method, called directly.
   An inline handler's methods are its value's fields, a named one's are its
   impl's. One that takes control is reached only handed its continuation. *)
let bound_operation ?(handed = false) env span ctx name (args : checked_expr list) ret : checked_expr option =
  let kind_fits (op : Ast.op_decl) = handed || op.Ast.op_kind = Ast.Op_fn in
  match Hashtbl.find_opt ctx_effects.ops name, Hashtbl.find_opt ctx_op_owner name with
  | Some op, Some label when walking () && kind_fits op ->
    (match binding_for label !effect_bindings with
     | None -> None
     | Some b when is_own b -> None
     | Some b ->
       note_keyed b;
       let short = method_of_operation label name in
       let arg_types = List.map (fun (a : checked_expr) -> a.Ast.ann) args in
       (match b.bd_value with
        | Some value ->
          let value_ty = Hashtbl.find handler_values b.bd_handler in
          let rec field (f : Types.infer_fields) =
            match Types.repr_fields f with
            | Types.FCons (l, t, _) when String.equal l short -> t
            | Types.FCons (_, _, rest) -> field rest
            | _ -> fail span "The handler of '%s' has no method '%s'." (shown_name label) short
          in
          let method_ty =
            match Types.repr value_ty with
            | Types.IRecord f -> field f
            | _ -> fail span "The handler of '%s' has no methods." (shown_name label)
          in
          if not handed
          then (
            unify_at span method_ty (Types.IFn (arg_types, ret, Types.fresh_row ()));
            match Hashtbl.find_opt lifted_methods (b.bd_handler, short) with
            | Some (fn, fn_ty) ->
              (ops ()).refer fn;
              Some (Ast.annotated span ret (`Call (Ast.annotated span (answered fn_ty) (`Var fn), args)))
            | None ->
            read_handler_value := true;
            let target =
              Ast.annotated span (Types.IRecord (Types.FCons (short, answered method_ty, Types.FEmpty))) (`Var value)
            in
            Some
              (Ast.annotated span ret (`Call (Ast.annotated span (answered method_ty) (`Field (target, short)), args))))
          else (
            (* The value is shown holding this call's copy of the method, which
               is all a later stage reads of it here. *)
            let method_ty = per_call method_ty in
            (match Types.repr method_ty with
             | Types.IFn (params, result, row) when List.length params = List.length arg_types ->
               List.iter2 (unify_at span) params arg_types;
               unify_at span result ret;
               Types.row_within row ctx.row
             | _ -> fail span "The handler of '%s' has no method '%s' that takes control." (shown_name label) short);
            let target =
              Ast.annotated span (Types.IRecord (Types.FCons (short, answered method_ty, Types.FEmpty))) (`Var value)
            in
            Some
              (Ast.annotated span ret (`Call (Ast.annotated span (answered method_ty) (`Field (target, short)), args))))
        | None ->
          let handler_type =
            match Hashtbl.find_opt named_handlers b.bd_handler with
            | Some (name, _) -> name
            | None -> b.bd_handler
          in
          let entries = Registry.method_entries ctx.registry handler_type short in
          let entry =
            match List.filter (fun (e : Registry.method_entry) -> e.Registry.trait = Some label) entries, entries with
            | [ e ], _ | [], [ e ] -> e
            | _ -> fail span "'%s' has no one method '%s' for '%s'." (shown_name handler_type) short (shown_name label)
          in
          (* A handler declared in a body has its methods in that body's scope. *)
          (match decl_of env entry.Registry.mangled with
           | None -> fail span "'%s' has no method '%s'." (shown_name handler_type) short
           | Some d ->
             let u = use_of d in
             let row = Types.fresh_row () in
             unify_at span u.u_ty (Types.IFn (arg_types, ret, row));
             (* A handler's parameter its method's signature never names, as
                `Picker<R>`'s in `log`, is nothing this call can settle, and
                nothing the method's type depends on. *)
             let named = List.map fst (Types.free_vars u.u_ty) in
             List.iter
               (fun (_, var, _) ->
                 match Types.repr var with
                 | Types.IVar { contents = Types.Unbound (id, _) } when not (List.mem id named) ->
                   unify_at span var Types.IUnit
                 | _ -> ())
               u.u_vars;
             let inner = !effect_bindings in
             effect_bindings := b.bd_outer;
             let fn =
               Fun.protect ~finally:(fun () -> effect_bindings := inner) (fun () -> reached span u row ctx)
             in
             let ty = u.u_ty in
             Some (Ast.annotated span ret (`Call (Ast.annotated span ty (`Var fn), args))))))
  | _ -> None

(* A function named as a value whose type takes control: a lambda calling it,
   which the transform makes as it makes any such lambda. *)
let eta span name (ty : Types.infer_ty) : Ast.expr =
  let at it = Ast.at span it in
  let arity =
    match Types.repr ty with
    | Types.IFn (params, _, _) -> List.length (Types.expand params)
    | _ -> 0
  in
  let names = List.init arity (fun i -> Ast.generated [ "arg"; string_of_int i ]) in
  at
    (`Lambda
      ( List.map (fun n -> { Ast.name = n; ty = None; implicit = false }) names
      , { Ast.ret = None; row = None; static_params = []; inline = false }
      , [ at (`Return (Some (at (`Call (at (`Var name), List.map (fun n -> at (`Var n)) names))))) ] ))

(* A call a transform made through a value whose type takes control: the
   parameters its type shows, its row, and how many handlers it is handed
   before what [Core.handed] lists. *)
let handed_shape (t : Types.infer_ty) (args : Ast.expr list) =
  match Types.repr t with
  | Types.IFn (ps, ret, row) when List.length args > List.length ps ->
    let ps = Types.expand ps in
    let n = List.length (controlling_row row) in
    if n > 0 && List.length args = List.length ps + n + handed_count Core.handed then Some (ps, ret, row, n) else None
  | _ -> None

(* A trait expected of a value asks for an object, so the value is inferred
   on its own and coerced. A match is not: each arm is coerced instead. *)
(* A tuple or an anonymous record has no declaration to implement a trait on,
   so it is written as its structure, each part through `debug`. *)
let structural_parts (t : Types.infer_ty) =
  let rec fields acc = function
    | Types.FCons (label, ty, rest) -> fields ((`Field label, ty) :: acc) (Types.repr_fields rest)
    | Types.FEmpty -> Some (List.rev acc)
    | Types.FVar _ -> None
  in
  match Types.repr t with
  | Types.ITuple items -> Some (List.mapi (fun i ty -> `Index i, ty) items)
  | Types.IRecord f -> fields [] (Types.repr_fields f)
  | _ -> None

let is_printing trait = String.equal trait Core.display || String.equal trait Core.debug

(* `fmt` or `debug` on a tuple or an anonymous record: its parts, each through
   `debug`, between the brackets the built-in form writes. The receiver is read
   once per part, so only a variable is taken apart. *)
let structurally_written span (receiver : Ast.expr) ty name args : Ast.expr option =
  match structural_parts ty, receiver.Ast.it, args with
  | Some parts, `Var _, [] when String.equal name "fmt" || String.equal name "debug" ->
    let at it : Ast.expr = Ast.at span it in
    let text t = at (`Str (Utf8.decode t)) in
    let plus a b = at (`Binop (Ast.Add, a, b)) in
    let part = function
      | `Index i -> at (`Tuple_get (receiver, i))
      | `Field label -> at (`Field (receiver, label))
    in
    let shown (place, _) =
      let value = at (`Call (at (`Var (Core.name "text/Format" "debug")), [ part place ])) in
      match place with
      | `Index _ -> value
      | `Field label -> plus (text (label ^ ": ")) value
    in
    let opening, closing, empty =
      match Types.repr ty with
      | Types.ITuple _ -> "(", ")", "()"
      | _ -> "{ ", " }", "{}"
    in
    (match parts with
     | [] -> Some (text empty)
     | first :: rest ->
       Some
         (plus
            (List.fold_left (fun acc p -> plus (plus acc (text ", ")) (shown p)) (plus (text opening) (shown first)) rest)
            (text closing)))
  | _ -> None

let written_parts env v name args =
  match lookup env v with
  | Some scheme when args = [] && (String.equal name "fmt" || String.equal name "debug") ->
    let ty = Types.instantiate scheme in
    Option.map (fun _ -> ty) (structural_parts ty)
  | _ -> None

(* A tuple, an anonymous record and a function have no declaration to
   implement a trait on, so they never do, even where a printing bound admits
   one structurally. *)
let rec implements (t : Types.infer_ty) trait =
  match Types.repr t with
  | Types.ITuple _ | Types.IRecord _ | Types.IFn _ -> false
  | t when Types.is_absent t -> true
  | t ->
    Types.retracting (fun () ->
      try
        Types.unify (Types.fresh_with (Types.Bound [ { Types.bd_trait = trait; bd_args = []; bd_bindings = [] } ])) t;
        true
      with
      | Types.Type_error _ -> false)
    && own_bounds_met t trait

and own_bounds_met t trait =
  match Types.infer_type_name t, t with
  | Some name, (Types.INamed (_, args) | Types.ISum (_, args)) ->
    let met params =
      List.length params = List.length args
      && List.for_all2
           (fun (p : Ast.type_param) arg ->
             match p.Ast.tp_ty with
             | Some { Ast.it = Ast.Ty_name bound; _ } when Hashtbl.mem ctx_traits bound -> implements arg bound
             | _ -> true)
           params
           args
    in
    (match Hashtbl.find_all ctx_impl_params (name, trait) with
     | [] -> true
     | found -> List.exists met found)
  | _ -> true

(* A type as the annotation that denotes it, or [None] for one that still
   holds a type variable outside a row. An open row is written open, and so is
   one with a label whose arguments are not settled, which leaves it out. *)
let rec written_type span (t : Types.ty) : Ast.type_expr option =
  let at it = Some { Ast.it; span; ann = () } in
  let all ts =
    List.fold_right
      (fun t acc ->
        match acc, written_type span t with
        | Some acc, Some w -> Some (w :: acc)
        | _ -> None)
      ts
      (Some [])
  in
  (* A static parameter of the function being checked is a name here, and no
     name where the transform checks the value on its own. *)
  let rec declared (t : Types.ty) =
    match t with
    | Types.Named (n, args) | Types.Sum (n, args) ->
      (Hashtbl.mem ctx_types n || String.equal n Types.array_name) && List.for_all declared args
    | Types.Tuple ts -> List.for_all declared ts
    | Types.Fn (ps, r, _) -> List.for_all declared ps && declared r
    | Types.Int | Types.Float | Types.Str | Types.Byte | Types.Chr | Types.Bool | Types.Unit -> true
    | Types.Generic _ | Types.Pack _ | Types.Spread _ | Types.Record _ | Types.Row _ -> false
  in
  let labels (row : Types.row) =
    let written =
      List.filter_map
        (fun (l, args) -> if List.for_all declared args then Option.map (fun ws -> l, ws) (all args) else None)
        row.Types.labels
    in
    let opened = Option.is_some row.Types.tail || List.length written < List.length row.Types.labels in
    Some (if opened then written @ [ Ast.open_row, [] ] else written)
  in
  match t with
  | Types.Named (n, []) | Types.Sum (n, []) -> at (Ast.Ty_name n)
  | Types.Named (n, args) | Types.Sum (n, args) ->
    if List.exists (function Types.Pack _ -> true | _ -> false) args
    then None
    else Option.bind (all args) (fun ws -> at (Ast.Ty_app (n, ws)))
  | Types.Tuple ts -> Option.bind (all ts) (fun ws -> at (Ast.Ty_tuple ws))
  | Types.Fn (ps, r, row) ->
    (match all ps, written_type span r, labels row with
     | Some ps, Some r, Some row -> at (Ast.Ty_fn (ps, r, row))
     | _ -> None)
  | Types.Int | Types.Float | Types.Str | Types.Byte | Types.Chr | Types.Bool | Types.Unit ->
    at (Ast.Ty_name (Types.string_of_ty t))
  | Types.Generic _ | Types.Pack _ | Types.Spread _ | Types.Record _ | Types.Row _ -> None

let rec infer_expr ?expected ?at_root ?root_body env ctx (e : Ast.expr) : checked_expr =
  match expected, e.Ast.it with
  | Some t, it when is_trait_type t && (match it with `Match_expr _ -> false | _ -> true) ->
    lowered_now ctx.registry (coerced t (located ctx e (fun () -> infer_expr_impl ?at_root ?root_body env ctx e)))
  | _ -> located ctx e (fun () -> infer_expr_impl ?expected ?at_root ?root_body env ctx e)

and located ctx (e : Ast.expr) check : checked_expr =
  let checked =
    try check () with
    | Types.Type_error message -> raise (Located { span = e.Ast.span; message })
  in
  note_effect_sites e.Ast.span ctx.row;
  (* Under a function's own frame, a call reads what it is not told. *)
  (match checked.Ast.it, !effect_bindings with
   | (`Call _ | `Dyn_call _ | `Bound_call _), b :: _ when is_own b && Option.is_none b.bd_key -> ()
   | (`Call _ | `Dyn_call _ | `Bound_call _), bindings when walking () ->
     Checked_table.replace bindings_at checked bindings
   | _ -> ());
  if Option.is_some !recording || Option.is_some !noting
  then (
    let note (e : Ast.expr) ty =
      Option.iter (fun table -> table := (e, ty) :: !table) !recording;
      Option.iter (fun n -> n.n_types <- (e, ty) :: n.n_types) !noting
    in
    note e checked.Ast.ann;
    (* A callee the call branch resolves is never checked as an expression of
       its own. The handler values it is passed first are not written. *)
    match e.Ast.it, checked.Ast.it with
    | `Call (callee, written), `Call (resolved, passed) ->
      let extra = List.length passed - List.length written in
      let ty =
        match Types.repr resolved.Ast.ann with
        | Types.IFn (params, ret, row) when extra > 0 ->
          Types.IFn (List.filteri (fun i _ -> i >= extra) params, ret, row)
        | ty -> ty
      in
      note callee ty
    | _ -> ());
  checked

and unbound env name = Option.is_none (lookup env name) && Option.is_none (decl_of env name)

and infer_expr_impl ?expected ?(at_root = false) ?(root_body = false) env ctx (e : Ast.expr) : checked_expr =
  let span = e.Ast.span in
  let node ty it : checked_expr = Ast.annotated span ty it in
  match e.Ast.it with
  | `Pre_checked n ->
    (match (passed_at span ctx n).pc_code with
     | Passed_expr checked ->
       Option.iter (fun t -> unify_at span t checked.Ast.ann) expected;
       checked
     | Passed_stmts _ -> fail span "A statement passed through where an expression stands.")
  | `Int n -> node Types.IInt (`Int n)
  | `Float n -> node Types.IFloat (`Float n)
  | `Str s -> node Types.IStr (`Str s)
  | `Name n -> node Types.iname (`Name n)
  | `Bytes b -> node (Types.iarray Types.IByte) (`Bytes b)
  | `Char c -> node Types.IChr (`Char c)
  | `Bool b -> node Types.IBool (`Bool b)
  | `Unit -> node Types.IUnit `Unit
  | `Var name | `Call ({ Ast.it = `Var name; _ }, _)
    when unbound env name && List.length (operation_owners name) > 1 ->
    fail
      span
      "Ambiguous operation '%s': %s."
      name
      (String.concat
         " or "
         (List.map (fun owner -> shown_name owner ^ "." ^ name) (List.sort compare (operation_owners name))))
  | `Var name when unbound env name && Option.is_some (bare_operation name) ->
    infer_expr ?expected env ctx { e with Ast.it = `Var (Option.get (bare_operation name)) }
  | `Call (({ Ast.it = `Var name; _ } as callee), args)
    when unbound env name && Option.is_some (bare_operation name) ->
    infer_expr
      ?expected
      env
      ctx
      { e with Ast.it = `Call ({ callee with Ast.it = `Var (Option.get (bare_operation name)) }, args) }
  | `Var name when Option.is_some (decl_of env name) ->
    let d = Option.get (decl_of env name) in
    let u = use_of d in
    meet expected u.u_ty;
    if d.wd_values <> []
    then
      fail
        span
        "'%s' takes a static value, so it is used by a call that writes it: %s<…>(…)."
        (shown_name name)
        (shown_name name);
    (match Types.repr u.u_ty with
     | Types.IFn (_, _, row) when walking () && controlling_row row <> [] && final_read () ->
       (* Not entered first: an instance entered at this type would perform
          what the context expects of the value, and the call inside the
          lambda would reach it and take control the function never does. *)
       infer_expr ?expected env ctx (eta span name u.u_ty)
     | _ -> node u.u_ty (`Var (value_of span u)))
  | `Var name ->
    (match lookup env name with
     | Some scheme -> node (Types.instantiate scheme) (`Var name)
     | None ->
       (* A type with no fields has one value, and its name is that value. *)
       (match Hashtbl.find_opt ctx_types name with
        | Some (Product ([], declared)) when Types.repr_fields declared = Types.FEmpty ->
          lowered_now ctx.registry (node (Types.INamed (name, [])) (`New (name, [])))
        (* A static parameter is written by name in its instance, so inside a
           meta block a type standing as a value is the type, as `typeof`
           answers it: `str(E)`. *)
        | _
          when !in_meta
               && (Hashtbl.mem ctx_types name
                   || Hashtbl.mem ctx_traits name
                   || Hashtbl.mem ctx_type_params name
                   || primitive name <> None) ->
          infer_expr ?expected env ctx (Ast.at span (`Typeof (Ast.at span (`Var name))))
        | _ ->
          if walking () then (ops ()).unknown name span;
          !current.unknown
            (fun () -> fail span "Undefined variable '%s'." name)
            (fun () -> node (unknown_ty ()) (`Var name))))
  | `Run_expr (written, body, handlers) ->
    let answer =
      match written with
      | Some ret -> infer_ty_of_annotation ret
      | None ->
        let answer = Types.fresh () in
        meet expected answer;
        answer
    in
    let assigned = assigned_in_expr e [] in
    let valued scope (b : (Ast.expr, Ast.stmt) Ast.valued_block) =
      let stmts = infer_block scope ctx b.Ast.vb_stmts in
      let value = Option.map (infer_expr scope ctx) b.Ast.vb_value in
      ( { Ast.vb_stmts = stmts; vb_value = value }
      , match value with
        | None -> Types.IUnit
        | Some v -> v.Ast.ann )
    in
    last_lowered := None;
    incr run_count;
    let run = !run_count in
    let outer_runs = !active_runs in
    active_runs := run :: outer_runs;
    let (body, produced), prelude =
      Fun.protect ~finally:(fun () -> active_runs := outer_runs) @@ fun () ->
      check_run
        ~transform:(body, fun b -> valued (new_env (Some env)) b)
        env
        ctx
        assigned
        span
        ~answer
        handlers
        (fun () -> valued (new_env (Some env)) body)
    in
    (match !last_lowered, !expansions with
     | Some lowered, Some table -> table := (e, lowered) :: !table
     | _ -> ());
    (match !last_lowered with
     | Some lowered -> Option.iter (fun n -> n.n_runs <- (e, lowered) :: n.n_runs) !noting
     | _ -> ());
    last_lowered := None;
    unify_at span answer produced;
    let homed, elsewhere = List.partition (fun (r, _) -> r = run) !run_instances in
    run_instances := elsewhere;
    node answer (`Run_block { body with Ast.vb_stmts = prelude @ List.rev_map snd homed @ body.Ast.vb_stmts })
  | `Match_expr (scrutinee, cases) ->
    infer_match_expr env ctx span (Option.value expected ~default:(Types.fresh ())) scrutinee cases
  | `Assign (name, v) ->
    (match lookup env name with
     | None ->
       !current.unknown
         (fun () -> fail span "Undefined variable '%s'." name)
         (fun () -> node Types.IUnit (`Assign (name, infer_expr env ctx v)))
     | Some scheme ->
       let target = Types.instantiate scheme in
       let value = infer_expr ~expected:target env ctx v in
       Types.unify target value.Ast.ann;
       node target (`Assign (name, value)))
  | `Unop (((Ast.Neg | Ast.Bit_not) as op), a) ->
    let a = infer_expr env ctx a in
    let trait, what = if op = Ast.Neg then Core.neg, "negate" else Core.bit_not, "apply '~' to" in
    (match Types.concrete a.Ast.ann with
     | Some operand ->
       (match Registry.find_unary ctx.registry op operand with
        | Some entry ->
          lowered_now ctx.registry (node (Types.of_ty (Registry.result_of entry operand)) (`Unop (op, a)))
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
    if walking ()
    then
      List.iter
        (fun (c : checked_expr) -> Option.iter (ops ()).wake (Types.infer_type_name c.Ast.ann))
        [ a; b ];
    lowered_now ctx.registry (node (binop_result ctx.registry op a.Ast.ann b.Ast.ann) (`Binop (op, a, b)))
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
       (* No in-place entry exists, so it derives from the plain operator. *)
       if walking ()
       then (
         let current = node target (`Var name) in
         node target (`Assign (name, lowered_now ctx.registry (node target (`Binop (op, current, v))))))
       else node target (`Compound (op, name, v)))
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
    if walking ()
    then (
      let target, target_again = once ctx target in
      let index, index_again = once ctx index in
      let read = lowered_now ctx.registry (node current (`Index (target_again, index_again))) in
      let combined = lowered_now ctx.registry (node current (`Binop (op, read, v))) in
      lowered_now ctx.registry (node current (`Index_assign (target, index, combined))))
    else node current (`Compound_index (op, target, index, v))
  | `Compound_field (op, target, label, v) ->
    let target = infer_expr env ctx target in
    let current = field_of target label in
    let v = infer_expr env ctx v in
    unify_at span current (binop_result ctx.registry op current v.Ast.ann);
    if walking ()
    then (
      let target, target_again = once ctx target in
      let read = node current (`Field (target_again, label)) in
      let combined = lowered_now ctx.registry (node current (`Binop (op, read, v))) in
      node current (`Field_assign (target, label, combined)))
    else node current (`Compound_field (op, target, label, v))
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
  (* `Array<Int>(3, 0)` reads as a call until `Array` turns out to be a type
     with a constructor rather than a function. *)
  (* The walk lowers one a meta block holds before the check sees it. *)
  | `Call ({ Ast.it = `Var "__moduleof"; _ }, [ { Ast.it = `Str prefix; _ }; { Ast.it = `Str shown; _ } ])
    when walking () ->
    infer_expr ?expected env ctx ((ops ()).moduleof span (Utf8.encode prefix) (Utf8.encode shown))
  | (`Code _ | `Code_stmts _ | `Code_decl _) when walking () -> infer_expr ?expected env ctx ((ops ()).quoted e)
  | `Call ({ Ast.it = `Var "__moduleof"; _ }, _) ->
    raise (Rejected { span; message = "'moduleof' is only allowed inside a meta block." })
  | `Code _ | `Code_stmts _ | `Code_decl _ ->
    raise (Rejected { span; message = "'code' is only allowed inside a meta block." })
  | `Call ({ Ast.it = `Var "__implements"; _ }, [ operand; trait ]) ->
    let trait =
      match trait.Ast.it with
      | `Var name when Hashtbl.mem ctx_traits name -> name
      | _ -> fail trait.Ast.span "implements takes a trait after the type."
    in
    node Types.IBool (`Bool (implements (Types.of_ty (reflected_type env ctx operand)) trait))
  | `Call ({ Ast.it = `Var "__implements"; _ }, _) ->
    raise (Rejected { span; message = "implements takes a type and a trait." })
  | `Call ({ Ast.it = `Var "__effects_of"; _ }, [ { Ast.it = `Var param; _ } ])
    when Hashtbl.mem ctx_row_params param ->
    let labels = fst (Types.labels_of_infer_row (Hashtbl.find ctx_row_params param)) in
    infer_expr
      ?expected
      env
      ctx
      { e with Ast.it = `Collection_lit (List.map (fun (label, _) -> Ast.at span (`Name label)) labels) }
  | `Call ({ Ast.it = `Var "__effects_of"; _ }, _) ->
    raise
      (Rejected
         { span; message = "'effects_of' takes a row parameter of the function it is written in, as in `fn f<E>(g: () -> <E> Unit)`." })
  | `Declof (operand, static_args) when walking () ->
    let name =
      match operand.Ast.it with
      | `Var name -> name
      | _ -> fail operand.Ast.span "declof takes the name of a declaration."
    in
    let not_a_declaration () = fail operand.Ast.span "'%s' is not a declaration." (shown_name name) in
    let reified =
      match decl_of env name with
      | Some d ->
        let u = use_of d in
        (match static_args with
         | Some args -> write_static ~implicit:true span name u args
         | None ->
           if u.u_vars <> [] || d.wd_values <> []
           then
             fail
               span
               "'%s' takes static parameters, so declof needs its key written: declof(%s<…>)."
               (shown_name name)
               (shown_name name));
        (ops ()).declof ~meta:!in_meta span (Some (d, key_of_use span ~value:false u)) name static_args
      | None ->
        (match lookup env name with
         | Some scheme ->
           (* A meta value holding a name is looked up when the block runs. *)
           let ty = Types.instantiate scheme in
           let holds_name () =
             Types.retracting (fun () ->
               try
                 Types.unify ty Types.iname;
                 true
               with
               | Types.Type_error _ -> false)
           in
           if Option.is_some static_args || (not !in_meta) || not (holds_name ()) then not_a_declaration ();
           Ast.at span (`Call (Ast.at span (`Var (Ast.generated [ "meta"; "declof" ])), [ operand ]))
         (* Inside a meta block the instance's key has already written the
            type in the parameter's place. *)
         | None when Hashtbl.mem ctx_type_params name && Option.is_none static_args ->
           (match reflected_type env ctx operand with
            | (Types.Named (n, args) | Types.Sum (n, args)) when not (String.equal n name) ->
              let written = List.filter_map (written_type span) args in
              if List.length written <> List.length args then not_a_declaration ();
              let static_args = if written = [] then None else Some (List.map (fun t -> Ast.St_type t) written) in
              (ops ()).declof ~meta:!in_meta span None n static_args
            | _ -> not_a_declaration ())
         | None -> (ops ()).declof ~meta:!in_meta span None name static_args)
    in
    infer_expr ?expected env ctx reified
  | `Declof _ -> raise (Rejected { span; message = "'declof' is only allowed inside a meta block." })
  | `Meta_expr _ when walking () ->
    let generated = in_scope env ctx (fun () -> (ops ()).meta_expr (runtime_names env) (reflected_type env ctx) e) in
    Physical.replace meta_exprs e generated;
    infer_expr ?expected env ctx generated
  | `Meta_expr _ -> raise (Rejected { span; message = "A meta block as an expression is not supported yet." })

  (* An ordinary generic type is checked once, so what `<…>` said is the
     checker's to infer again: from the fields, not from what the parent
     expects, which would overrule what was written. *)
  | (`New_generic _ | `New _) when walking () && (ops ()).generic_new e != e ->
    infer_expr_impl ?expected env ctx ((ops ()).generic_new e)
  | `New_generic (name, static_args, fields) ->
    let written =
      List.map
        (function
          | Ast.St_type t -> Some t
          | Ast.St_value { Ast.it = `Var n; span = at; _ } -> Some (Ast.at at (Ast.Ty_name n))
          | Ast.St_value _ -> None)
        static_args
    in
    if List.for_all Option.is_some written
       && Hashtbl.mem ctx_types name
       && List.length (params_of_decl name) = List.length written
    then (
      let ty = infer_ty_of_annotation (Ast.at span (Ast.Ty_app (name, List.map Option.get written))) in
      let checked = infer_expr_impl ~expected:ty env ctx { e with Ast.it = `New (name, fields) } in
      unify_at span checked.Ast.ann ty;
      checked)
    else infer_expr_impl env ctx { e with Ast.it = `New (name, fields) }
  | `Call (({ Ast.it = `Var name; _ } as callee), args) when constructs env ctx name ->
    infer_expr ?expected env ctx { e with Ast.it = `New_call (name, [], collected span callee args) }
  | `Static_call ({ Ast.it = `Var name; _ }, static_args, args) when constructs env ctx name ->
    let type_args =
      List.map
        (function
          | Ast.St_type t -> t
          | Ast.St_value _ -> fail span "'%s' takes types here, not values." name)
        static_args
    in
    infer_expr ?expected env ctx { e with Ast.it = `New_call (name, type_args, args) }
  | `Call ({ Ast.it = `Field (({ Ast.it = `Var v; _ } as target), short); _ }, args)
    when walking () && is_handler_value v ->
    handler_call env ctx span target short args
  | `Call ({ Ast.it = `Var name; _ }, args) when walking () && named_method_call name args ->
    let args = List.map (argument env ctx) args in
    let ret = Types.fresh () in
    (match bound_operation ~handed:true env span ctx name args ret with
     | Some bound -> bound
     | None -> fail span "'%s' is not an operation." (shown_name name))
  | `Call ({ Ast.it = `Var "discontinue"; _ }, [ arg ])
    when Option.is_none !recording
         && Option.is_some !builtin_discontinue
         && Option.equal ( == ) (lookup env "discontinue") !builtin_discontinue
         && not (handed_continuation env arg) ->
    (match arg.Ast.it with
     | `Var k ->
       fail
         span
         "'discontinue' takes the continuation of the handler method it is written in, and '%s' is not one here."
         (shown_name k)
     | _ -> fail span "'discontinue' takes the continuation of the handler method it is written in, by its name.")
  | `Call (callee, args) ->
    let args = collected span callee args in
    let use =
      match callee.Ast.it with
      | `Var name ->
        (match decl_of env name with
         | Some d ->
           if (ops ()).performs_gen d && not !in_meta
           then
             fail
               callee.Ast.span
               "'%s' performs Gen, which only a meta block handles."
               (shown_name name);
           Some (use_toward expected d)
         | None -> None)
      | _ -> None
    in
    (* What the caller already carries settles the callee's arguments to it
       before the arguments are read, so a function value among them is made
       taking the handlers it will be handed. *)
    Option.iter
      (fun u ->
        match Types.repr u.u_ty with
        | Types.IFn (_, _, row) ->
          let carried, _ = Types.labels_of_infer_row ctx.row in
          List.iter
            (fun (label, args) ->
              match List.assoc_opt label carried with
              | Some found when List.length found = List.length args ->
                (try List.iter2 Types.unify args found with
                 | Types.Type_error _ -> ())
              | _ -> ())
            (fst (Types.labels_of_infer_row row))
        | _ -> ())
      use;
    let outer_pending = !pending_values in
    if Option.is_some use then pending_values := [];
    Fun.protect ~finally:(fun () -> if Option.is_some use then pending_values := outer_pending)
    @@ fun () ->
    begin
    let callee_node =
      match use, callee.Ast.it with
      | Some u, `Var name -> Ast.annotated callee.Ast.span u.u_ty (`Var name)
      | _ -> infer_expr env ctx callee
    in
    match handed_shape callee_node.Ast.ann args with
    | Some (params, ret, row, n) when Option.is_none use -> handed_call env ctx span callee_node params ret row n args
    | _ ->
    (* The top level is the body of a function handed to the root, and a
       statement that throws the body of one handed to the catcher, so that
       function's row stands in for the top level's while it is checked:
       otherwise every effect site would be the whole call. *)
    let at_root, root_body =
      match callee.Ast.it, !top_row with
      | `Var name, Some top when top == ctx.row -> Ast.is_root_or_catcher name, Ast.is_root name
      | _ -> false, false
    in
    program_root_body :=
      (match callee.Ast.it with
       | `Var name -> root_body && Ast.is_program_root name
       | _ -> false);
    let args = name_implicit_params callee_node.Ast.ann args in
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
          (List.fold_left2
             (fun checked param (a : Ast.expr) ->
               let c =
                 match a.Ast.it with
                 | `Spread _ -> argument env ctx a
                 | _ ->
                   (* Whether a trailing lambda takes its `it` is read the
                      same way: processed code shows `xs.push { … }` as
                      `push(xs, { … })`. *)
                   let a =
                     match a.Ast.it with
                     | `Lambda _ ->
                       settle_before (List.rev checked);
                       List.hd (name_implicit_params_from [ param ] [ a ])
                     | _ -> a
                   in
                   let c = argument ~expected:param ~at_root ~root_body env ctx a in
                   not_a_bound ~declared:declared_params a param c;
                   not_pure a param c;
                   c
               in
               c :: checked)
             []
             params
             args)
      | None -> List.map (argument ~at_root ~root_body env ctx) args
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
       let ret =
         if is_erroneous callee_node.Ast.ann
         then erroneous_ty ()
         else if is_unknown callee_node.Ast.ann
         then unknown_ty ()
         else Types.fresh ()
       in
       let row = Types.fresh_row () in
       Types.unify
         callee_node.Ast.ann
         (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) args, ret, row));
       (match callee.Ast.it with
        | `Var name when Hashtbl.mem ctx_effects.ops name || returns_nothing (lookup env name) ->
          leave_open ret
        | _ -> ());
       (match use with
        | Some u ->
          let name = reached span u row ctx in
          node ret (`Call (Ast.annotated callee.Ast.span u.u_ty (`Var name), args))
        | None ->
          let name, scheme =
            match callee.Ast.it with
            | `Var name -> Some name, lookup env name
            | _ -> None, None
          in
          (match name, !root_param with
           | Some n, Some p when String.equal n p && args = [] -> root_bindings := Some !effect_bindings
           | _ -> ());
          let at_root_main =
            match name, !root_param with
            | Some n, Some p -> String.equal n p && args = []
            | _ -> false
          in
          (match Option.bind name (fun name -> bound_operation env span ctx name args ret) with
           | Some bound ->
             (* Outside the walk a named handler has no value, and the label
                staying in the row is how `with` sees what it binds. *)
             if Option.fold ~none:false ~some:named_binding name
             then (
               match Option.bind (Option.bind name (Hashtbl.find_opt ctx_op_owner)) (fun l -> binding_for l !effect_bindings) with
               | Some b when Option.is_some b.bd_value && Option.is_none b.bd_key ->
                 Hashtbl.replace used_handlers b.bd_handler ()
               | _ -> admits_row ?name scheme row ctx.row)
             else if
               (* Answered through the instance's key, it is still what the
                  function performs, as its type says to whoever calls it. *)
               Option.fold
                 ~none:false
                 ~some:(fun b -> Option.is_some b.bd_key)
                 (Option.bind (Option.bind name (Hashtbl.find_opt ctx_op_owner)) (fun l -> binding_for l !effect_bindings))
             then admits_row ?name scheme row ctx.row;
             bound
           | None ->
             let row =
               match scheme with
               | Some _ when not (walking ()) -> undefaulted env callee_node.Ast.ann row ctx.row
               | _ -> row
             in
             admits_row ?name scheme row ctx.row;
             let call = node ret (`Call (callee_node, args)) in
             if at_root_main then root_call := Some call;
             call)))
    end
  (* `f.to<Bool>()`. The receiver says which type, and the written targets say
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
    let use = Option.map (use_toward expected) (decl_of env entry.Registry.mangled) in
    with_pending @@ fun () ->
    let fn =
      match use with
      | Some u -> u.u_ty
      | None -> Types.instantiate scheme
    in
    let associated = Hashtbl.mem ctx_associated (owner, method_) in
    let args =
      List.map2
        (fun expected a -> infer_expr ?expected env ctx a)
        (parameters fn ~receiver:(not associated) args)
        args
    in
    let all = if associated then args else receiver :: args in
    let ret = Types.fresh () in
    let row = Types.fresh_row () in
    Types.unify
      fn
      (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) all, ret, row));
    (match use with
     | Some u ->
              let name = reached span u row ctx in
          let ty = u.u_ty in
       node ret (`Call (Ast.annotated span ty (`Var name), all))
     | None ->
       admits_row ~name:entry.Registry.mangled (Some scheme) row ctx.row;
       node ret (`Call (Ast.annotated span fn (`Var entry.Registry.mangled), all)))
  | `Static_call (({ Ast.it = `Var name; _ } as callee), static_args, args)
    when Option.is_some (decl_of env name) ->
    let d = Option.get (decl_of env name) in
    if (ops ()).performs_gen d && not !in_meta
    then fail span "'%s' performs Gen, which only a meta block handles." (shown_name name);
    let u = use_of d in
    write_static span name u static_args;
    (match Types.repr u.u_ty with
     | Types.IFn (_, ret, _) -> meet expected ret
     | _ -> ());
    let args = collected span callee args in
    with_pending @@ fun () ->
    let args =
      List.map2 (fun expected a -> infer_expr ?expected env ctx a) (parameters u.u_ty ~receiver:false args) args
    in
    let ret = Types.fresh () in
    let row = Types.fresh_row () in
    unify_at
      span
      u.u_ty
      (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) args, ret, row));
        let name = reached span u row ctx in
          let ty = u.u_ty in
    node ret (`Call (Ast.annotated span ty (`Var name), args))
  | `Static_ref ({ Ast.it = `Var name; _ }, static_args) when Option.is_some (decl_of env name) ->
    let u = use_of (Option.get (decl_of env name)) in
    write_static span name u static_args;
    meet expected u.u_ty;
    node u.u_ty (`Var (value_of span u))
  | `Static_ref ({ Ast.it = `Var name; _ }, static_args) ->
    (match lookup env name with
     | Some scheme -> node (written_instance span name scheme static_args) (`Var name)
     | None -> fail span "Undefined variable '%s'." name)
  | `Static_ref _ -> fail span "Only a named function takes static arguments."
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
    let fn = written_instance span name scheme static_args in
    let args = List.map (infer_expr env ctx) (collected span callee args) in
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
    infer_expr ?expected env ctx { e with Ast.it = `New_variant (ty, variant, Ast.P_tuple args) }
  | `Field ({ Ast.it = `Var ty; _ }, variant) when declared_variant env ty variant <> None ->
    infer_expr ?expected env ctx { e with Ast.it = `New_variant (ty, variant, Ast.P_none) }
  | `Field ({ Ast.it = `Var ty; _ }, variant)
    when lookup env ty = None
         && (match Hashtbl.find_opt ctx_types ty with
             | Some (Sum _) -> true
             | _ -> false) ->
    fail span "Type '%s' has no variant '%s'." ty variant
  (* An instance at `absent` is never called, since no value has that type. *)
  | `Method_call ({ Ast.it = `Var v; _ }, _, _, _, _)
    when Option.fold ~none:false ~some:(fun sc -> Types.is_absent (Types.repr (Types.instantiate sc))) (lookup env v) ->
    infer_expr env ctx (Ast.at span (`Call (Ast.at span (`Var "__unreachable"), [])))
  | `Method_call ({ Ast.it = `Var v; _ }, ("fmt" | "debug"), _, [], _)
    when Option.fold
           ~none:false
           ~some:(fun sc ->
             match Types.repr (Types.instantiate sc) with
             | Types.IFn _ -> true
             | _ -> false)
           (lookup env v) ->
    node Types.IStr (`Str (Utf8.decode "<fn>"))
  | `Method_call (({ Ast.it = `Var v; _ } as receiver), name, _, args, _)
    when Option.is_some (written_parts env v name args) ->
    infer_expr env ctx (Option.get (structurally_written span receiver (Option.get (written_parts env v name args)) name args))
  | `Method_call (receiver, name, as_function, args, in_scope) ->
    (* `T.from(x)` names a type rather than a value. *)
    let named_receiver =
      match receiver.Ast.it with
      | `Var owner when lookup env owner = None ->
        (match Hashtbl.find_opt ctx_type_params owner with
         | Some var -> Some var
         (* A primitive is not in [ctx_types], so `Int.from(…)` would reach
            nothing while `21.double()` works. *)
         | None when primitive owner <> None -> primitive owner
         | None ->
           if Hashtbl.mem ctx_types owner || Hashtbl.mem Types.copies owner
           then Some (named_type receiver.Ast.span owner [])
           else None)
      | _ -> None
    in
    let receiver =
      match named_receiver with
      | Some ann -> { Ast.it = `Int 0; span = receiver.Ast.span; ann }
      | None -> infer_expr env ctx receiver
    in
    if walking () then Option.iter (ops ()).wake (Types.infer_type_name receiver.Ast.ann);
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
      let reached =
        List.filter
          (fun (e : Registry.method_entry) ->
            match e.Registry.trait, in_scope with
            | None, _ | _, None -> true
            | Some trait, Some names ->
              List.mem (written_trait trait) names || List.mem_assoc trait !bound_traits)
          (Registry.method_entries ctx.registry owner name)
      in
      match reached with
      | _ :: _ :: _ ->
        (match
           List.filter
             (fun (e : Registry.method_entry) ->
               List.exists
                 (fun (trait, targets) ->
                   e.Registry.trait = Some trait
                   && (targets = None || targets = Some e.Registry.targets))
                 !bound_traits)
             reached
         with
         | [ bound ] -> [ bound ]
         | _ -> reached)
      | reached -> reached
    in
    let entry_in_reach owner =
      match in_reach owner with
      | e :: _ -> e.Registry.mangled
      | [] -> Registry.entry_for_method ctx.registry owner name
    in
    let declared =
      match found with
      | Ok (Owner owner) when not (Hashtbl.mem ctx_associated (owner, name)) ->
        (match lookup env (entry_in_reach owner) with
         | Some scheme ->
           (match Types.repr (signature_of env (entry_in_reach owner) scheme) with
            | Types.IFn (self :: rest, _, _) ->
              (* A generic parameter only says how many a lambda takes once the
                 receiver has bound it. This instantiation is read and dropped;
                 the call makes its own. *)
              (try Types.unify self receiver.Ast.ann with
               | _ -> ());
              rest
            | _ -> [])
         | None -> [])
      | Ok (Owner owner) ->
        (match lookup env (entry_in_reach owner) with
         | Some scheme ->
           (match Types.repr (signature_of env (entry_in_reach owner) scheme) with
            | Types.IFn (params, _, _) -> params
            | _ -> [])
         | None -> [])
      | _ -> []
    in
    let args =
      let sized = List.length declared = List.length args in
      List.mapi
        (fun i (a : Ast.expr) ->
          argument ?expected:(if sized then List.nth_opt declared i else None) env ctx a)
        (name_implicit_params_from declared args)
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
        let use = Option.map (use_toward expected) (decl_of env as_function) in
        with_pending @@ fun () ->
        let fn =
          match use with
          | Some u -> u.u_ty
          | None -> Types.instantiate scheme
        in
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
        match use with
        | Some u ->
                    let name = reached span u row ctx in
          let ty = u.u_ty in
          Some (node ret (`Call ({ Ast.it = `Var name; span; ann = ty }, receiver :: args)))
        | None ->
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
          let dynamic =
            match Types.repr receiver.Ast.ann with
            | Types.INamed (named, _) -> String.equal named trait
            | _ -> false
          in
          let taken =
            match m.Ast.ms_signature.Ast.row with
            | Some labels when dynamic -> controlling (List.map fst labels)
            | _ -> []
          in
          (* Called through a table a transform made taking control: the
             method's arguments, a handler for each effect it takes control
             of, then what [Core.handed] lists, whose answer is the call's. *)
          let handed =
            taken <> [] && List.length args = List.length rest + List.length taken + handed_count Core.handed
          in
          let args, continuation =
            if handed
            then (
              let surface = List.filteri (fun i _ -> i < List.length rest) args
              and extra = List.filteri (fun i _ -> i >= List.length rest) args in
              surface, Some extra)
            else args, None
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
          (* The written row is what the call adds to its context -- not all
             its context may hold, which a closed row unified with the context
             would insist on. *)
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
          (* What the call takes control of is answered through the handlers
             it is handed. *)
          if handed
          then (
            let rec without (r : Types.infer_row) =
              match Types.repr_row r with
              | Types.RCons (l, _, rest) when List.mem l taken -> without rest
              | Types.RCons (l, a, rest) -> Types.RCons (l, a, without rest)
              | r -> r
            in
            Types.row_within (without row) ctx.row)
          else Types.unify_row row ctx.row;
          (* A receiver whose type is the trait is a value paired with a table,
             so the call reads its target out of that table. Otherwise the bound
             is what says which impl, and it is recorded for the copy. *)
          (match Types.repr receiver.Ast.ann, continuation with
           | Types.INamed (named, _), Some extra when String.equal named trait ->
             let answer = Types.fresh () in
             let wanted = handed_params Core.handed ~result:ret ~answer ~row:(Types.fresh_row ()) in
             List.iter2
               (fun (c : checked_expr) t -> unify_at c.Ast.span c.Ast.ann t)
               (List.filteri (fun i _ -> i >= List.length taken) extra)
               wanted;
             node answer (`Dyn_call (receiver, name, fn, args @ extra))
           | Types.INamed (named, _), None when String.equal named trait ->
             node ret (`Dyn_call (receiver, name, fn, args))
           | _ ->
             lowered_now ctx.registry @@ node
               ret
               (`Bound_call
                 ( receiver
                 , name
                 , Option.value
                     dispatch
                     ~default:{ Ast.dp_trait = declaring; dp_targets = bound_args }
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
         if walking () then (ops ()).unknown_method name span;
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
         let use = Option.map (use_toward expected) (decl_of env (entry_in_reach owner)) in
         let outer_pending = !pending_values in
         if Option.is_some use then pending_values := [];
         Fun.protect ~finally:(fun () -> if Option.is_some use then pending_values := outer_pending)
         @@ fun () ->
         let fn =
           match use, lookup env (entry_in_reach owner) with
           | Some u, _ -> u.u_ty
           | None, Some scheme -> Types.instantiate scheme
           | None, None -> missing Types.fresh
         in
         let associated = Hashtbl.mem ctx_associated (owner, name) in
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
         let all = if associated then args else receiver :: args in
         match use with
         | Some u ->
           (* Processed code shows the method as the function it is, called
              with its receiver first (an associated function without one): a
              transform copies it as it would any function. *)
           (match !expansions, !recording, e.Ast.it with
            | Some lowered, Some table, `Method_call (written_receiver, _, _, written_args, _) ->
              let callee = Ast.at span (`Var u.u_decl.wd_name) in
              let written_all = if associated then written_args else written_receiver :: written_args in
              let call = Ast.at span (`Call (callee, written_all)) in
              table := (callee, fn) :: (call, ret) :: !table;
              lowered := (e, call) :: !lowered
            | _, _, `Method_call (written_receiver, _, _, written_args, _) when Option.is_some !noting ->
              let callee = Ast.at span (`Var u.u_decl.wd_name) in
              let written_all = if associated then written_args else written_receiver :: written_args in
              let call = Ast.at span (`Call (callee, written_all)) in
              Option.iter
                (fun n ->
                  n.n_types <- (callee, fn) :: (call, ret) :: n.n_types;
                  n.n_runs <- (e, call) :: n.n_runs)
                !noting
            | _ -> ());
           let name = reached span u row ctx in
          let ty = u.u_ty in
           node ret (`Call (Ast.annotated span ty (`Var name), all))
         | None ->
           admits_row
             ~name:(Registry.entry_for_method ctx.registry owner name)
             (lookup env (Registry.entry_for_method ctx.registry owner name))
             row
             ctx.row;
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
  | `Lambda (params, signature, body) when is_handed signature ->
    handed_lambda ?expected ~at_root env ctx span params signature body
  | `Lambda (params, signature, body) ->
    let param_types = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params in
    let declared_ret = annotated_or_fresh signature.Ast.ret in
    (* A mismatch is left for whatever expected this type to report, against
       the lambda's whole type. *)
    let hint ty want =
      try Types.unify ty want with
      | Types.Type_error _ -> ()
    in
    let wanted_control =
      match Option.map Types.repr expected with
      | Some (Types.IFn (wanted, wanted_ret, wanted_row)) ->
        let wanted = Types.expand wanted in
        if List.length wanted = List.length param_types then List.iter2 hint param_types wanted;
        if Option.is_none signature.Ast.ret then hint declared_ret wanted_ret;
        (* A label whose arguments nothing has settled may be one the key
           finds nothing performs, and then it is no label: such a one is
           taken only if the body performs it. *)
        let open_args =
          List.filter_map
            (fun (l, args) ->
              if List.exists
                   (fun a ->
                     List.exists
                       (fun (id, _) -> not (Hashtbl.mem Types.declared_params id))
                       (Types.free_vars a))
                   args
              then Some l
              else None)
            (fst (Types.labels_of_infer_row wanted_row))
        in
        List.map (fun l -> l, List.mem l open_args) (controlling_row wanted_row)
      | _ -> []
    in
    let row = Types.fresh_row () in
    if is_plain signature then made_rows := row :: !made_rows;
    let scope = new_env (Some env) in
    List.iter2 (bind_param scope) params param_types;
    let saved = !top_row
    and outer = !effect_bindings in
    if at_root then top_row := Some row;
    let program_root = root_body && !program_root_body in
    program_root_body := false;
    if not (is_plain signature) then effect_bindings := (if program_root then root_frame else own_frame) :: outer;
    (* One the transform may make taking control is shown to it as checked
       here, which is noted for that. *)
    let may_convert = (not (is_plain signature)) && (not root_body) && walking () && Option.is_none !recording in
    let body, uses =
      Fun.protect
        ~finally:(fun () ->
          top_row := saved;
          effect_bindings := outer)
        (fun () ->
          let handed = if is_plain signature then ctx.handed_answer else None in
          let check () =
            in_function_body ?handed ctx ~ret:declared_ret ~row (fun () ->
              if root_body then root_block env scope ctx body else infer_block scope ctx body)
          in
          if may_convert then noted check else check (), ([], { n_types = []; n_runs = [] }))
    in
    (match Physical.find_opt plain_arms e, controlling_row row with
     | Some arm, taken :: _ -> plain_arm_controls span arm taken
     | _ -> ());
    (* Bound where it is written, it performs through what is around it. *)
    if is_plain signature then Types.row_within row ctx.row;
    let checked = node (Types.IFn (param_types, declared_ret, row)) (`Lambda (params, signature, body)) in
    (* A function value whose type takes control is made by the library's
       transform, wherever it is written. *)
    if (not (is_plain signature))
       && walking ()
       && controlling_row row <> []
       && block_splits body
       && final_read ()
    then (
      (* The handlers a value takes follow from its type where it is used,
         which may take control of more than its body does. *)
      let own = controlling_row row in
      let wanted = List.filter_map (fun (l, unsettled) -> if unsettled && not (List.mem l own) then None else Some l) wanted_control in
      let taken = List.sort_uniq String.compare (own @ wanted) in
      (* The transform checks the value on its own, so a parameter or a result
         the context typed goes to it written: a call in the body whose key only
         the result settles (`attempt(() => decode_data(d))`) is keyed there. *)
      let e =
        let signature =
          match signature.Ast.ret, written_type span (Types.resolve declared_ret) with
          | None, Some t -> { signature with Ast.ret = Some t }
          | _ -> signature
        in
        let params =
          List.map2
            (fun (p : Ast.param) ty ->
              match p.Ast.ty, written_type span (Types.resolve ty) with
              | None, Some t -> { p with Ast.ty = Some t }
              | _ -> p)
            params
            param_types
        in
        match e.Ast.it, !root_rewritten with
        | `Lambda _, Some rewritten when root_body -> { e with Ast.it = `Lambda (params, signature, rewritten) }
        | `Lambda (_, _, written), _ ->
          (* Shown to the transform as checked here; what it makes of the body
             is checked again, the meta blocks in it as what they generated. *)
          let n =
            pass_through
              { pc_code = Passed_stmts body
              ; pc_row = row
              ; pc_view = `Stmts written
              ; pc_binds = []
              ; pc_uses = fst uses
              ; pc_returns = Some declared_ret
              ; pc_notes = snd uses
              ; pc_shown = false
              }
          in
          { e with Ast.it = `Lambda (params, signature, [ Ast.at span (`Pre_checked n) ]) }
        | _ -> e
      in
      let made = infer_expr ?expected ~at_root env ctx (converted env ctx e taken) in
      unify_at span made.Ast.ann checked.Ast.ann;
      made)
    else checked
  | `Field ({ Ast.it = `Typeof operand; _ }, (("name" | "shape" | "attrs" | "doc") as field)) ->
    reflected env ctx span operand (Some field)
  | `Typeof operand -> reflected env ctx span operand None
  | `Collection_lit items ->
    (* Without a container expected of it, a literal is one the context may
       still choose, and `Array` if nothing does. *)
    let container, elem =
      let chosen =
        match Option.map (fun t -> t, Types.repr t) expected with
        | Some (t, Types.INamed (name, _)) when String.equal name Types.array_name ->
          Option.map (fun (_, elem) -> t, elem) (Types.container_element t)
        | Some (t, Types.INamed (name, _)) ->
          Option.map (fun elem -> t, elem) (Registry.container_element ctx.registry name t)
        | _ -> None
      in
      match chosen with
      | Some chosen -> chosen
      | None ->
        let elem = Types.fresh () in
        Types.fresh_with (Types.Collection elem), elem
    in
    let items = List.map (infer_expr ~expected:elem env ctx) items in
    List.iter
      (fun (i : checked_expr) -> unify_at i.Ast.span elem i.Ast.ann)
      items;
    lowered_now ctx.registry (node container (`Collection_lit items))
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
       let use = Option.map (use_toward expected) (decl_of env fn) in
       with_pending @@ fun () ->
       let fn_ty =
         match use with
         | Some u -> u.u_ty
         | None -> Types.instantiate scheme
       in
       let args =
         List.map2 (fun expected a -> infer_expr ?expected env ctx a) (parameters fn_ty ~receiver:false args) args
       in
       let ret = Types.fresh () in
       let row = Types.fresh_row () in
       Types.unify
         fn_ty
         (Types.IFn (List.map (fun (a : checked_expr) -> a.Ast.ann) args, ret, row));
       if type_args <> []
       then
         unify_at
           span
           (named_type span name (type_arguments name type_args))
           ret;
       (match use with
        | Some u ->
                    let fn = reached span u row ctx in
          let ty = u.u_ty in
          node ret (`Call (Ast.annotated span ty (`Var fn), args))
        | None ->
          admits_row ~name:fn (lookup env fn) row ctx.row;
          node ret (`Call (Ast.annotated span fn_ty (`Var fn), args))))
  | `New (name, fields) ->
    (match Hashtbl.find_opt ctx_types name with
     | Some (Opaque _) -> fail span "'%s' has no fields to construct it with." name
     | None | Some (Sum _) -> fail span "Unknown record type '%s'." name
     | Some (Product (vars, declared)) ->
       let args = List.map fresh_argument vars in
       meet expected (Types.INamed (name, args));
       let declared = Types.substitute_fields (instance vars args) declared in
       let rec labels f =
         match Types.repr_fields f with
         | Types.FEmpty | Types.FVar _ -> []
         | Types.FCons (l, ty, rest) -> (l, ty) :: labels rest
       in
       let fields_expected = labels declared in
       let fields =
         List.map
           (fun (l, v) -> l, infer_expr ?expected:(List.assoc_opt l fields_expected) env ctx v)
           fields
       in
       List.iter
         (fun (l, _) ->
           if not (List.mem_assoc l fields_expected)
           then
             !current.unknown
               (fun () -> fail span "Type '%s' has no field '%s'." name l)
               (fun () -> ()))
         fields;
       List.iter
         (fun (l, _) ->
           if not (List.mem_assoc l fields)
           then fail span "Field '%s' is missing." l)
         fields_expected;
       (* A field the type does not declare was reported above, or set aside
          while a meta block could still declare it. *)
       List.iter
         (fun (l, (v : checked_expr)) ->
           match List.assoc_opt l fields_expected with
           | Some ty -> unify_at v.Ast.span ty v.Ast.ann
           | None -> ())
         fields;
       lowered_now ctx.registry (node (Types.INamed (name, args)) (`New (name, fields))))
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
          meet expected (Types.ISum (ty, args));
          let carried =
            List.map
              (fun (l, t) -> l, Types.substitute mapping t)
              (Ast.payload_fields declared.vd_payload)
          in
          let given =
            List.map
              (fun (l, v) -> l, infer_expr ?expected:(List.assoc_opt l carried) env ctx v)
              (Ast.payload_fields payload)
          in
          if List.length carried <> List.length given
          then
            fail
              span
              "Variant '%s' carries %d value(s) but %d were given."
              variant
              (List.length carried)
              (List.length given);
          List.iter
            (fun (l, (v : checked_expr)) ->
              match List.assoc_opt l carried with
              | Some ty -> unify_at v.Ast.span ty v.Ast.ann
              | None -> fail span "Variant '%s' has no field '%s'." variant l)
            given;
          let payload =
            match payload with
            | Ast.P_none -> Ast.P_none
            | Ast.P_tuple _ -> Ast.P_tuple (List.map snd given)
            | Ast.P_fields _ -> Ast.P_fields given
          in
          lowered_now ctx.registry (node (Types.ISum (ty, args)) (`New_variant (ty, variant, payload)))))
  | `Record_lit fields ->
    let expected_field l =
      match Option.map Types.repr expected with
      | Some (Types.IRecord f) ->
        let rec find (f : Types.infer_fields) =
          match Types.repr_fields f with
          | Types.FCons (l', t, _) when String.equal l l' -> Some t
          | Types.FCons (_, _, rest) -> find rest
          | _ -> None
        in
        find f
      | _ -> None
    in
    let fields = List.map (fun (l, v) -> l, infer_expr ?expected:(expected_field l) env ctx v) fields in
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
    let declared = field_of target label in
    let v = infer_expr ~expected:declared env ctx v in
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
     | Some result -> lowered_now ctx.registry (node result (`Index (target, index)))
     | None when !current.unknown (fun () -> false) (fun () -> is_unknown target.Ast.ann) ->
       node (unknown_ty ()) (`Index (target, index))
     | None ->
       unify_at index.Ast.span Types.IInt index.Ast.ann;
       lowered_now ctx.registry (node (element_of ctx.registry target) (`Index (target, index))))
  | `Index_assign (target, index, v) ->
    let target = infer_expr env ctx target in
    if Types.concrete target.Ast.ann = Some Types.Str
    then fail target.Ast.span "A string cannot be assigned into.";
    let index = infer_expr env ctx index in
    unify_at index.Ast.span Types.IInt index.Ast.ann;
    let element = element_of ctx.registry target in
    let v = infer_expr ~expected:element env ctx v in
    unify_at v.Ast.span element v.Ast.ann;
    lowered_now ctx.registry (node v.Ast.ann (`Index_assign (target, index, v)))

(* What an argument contributes to the callee's parameter list: one type, or
   however many a spread's tuple holds. *)
(* How many arguments a list is once its spreads are taken apart. *)
and spread_arity (args : checked_expr list) =
  List.length (Types.expand (List.map (fun (a : checked_expr) -> a.Ast.ann) args))

and argument ?expected ?at_root ?root_body env ctx (a : Ast.expr) : checked_expr =
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
  | _ -> infer_expr ?expected ?at_root ?root_body env ctx a

(* [answer] is refined in each arm the way the scrutinee is, so a match checked
   against `T` can answer `Int` from an arm that proved `T` is `Int`. *)
and infer_match_expr env ctx span answer scrutinee cases : checked_expr =
  let arm scope refinement (b : (Ast.expr, Ast.stmt) Ast.valued_block) =
    let stmts = infer_block scope ctx b.Ast.vb_stmts in
    let expected = Types.substitute refinement answer in
    let value = Option.map (infer_expr ~expected scope ctx) b.Ast.vb_value in
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

(* An operation called through the handler a transform names: the method is
   copied per call, so an operation's own parameters are each call's own. *)
and handler_call env ctx span target short args : checked_expr =
  let target = infer_expr env ctx target in
  let method_ty =
    match Types.repr target.Ast.ann with
    | Types.IRecord f ->
      (try fst (Types.rewrite_fields short f) with
       | Types.Type_error _ -> fail span "This handler has no method '%s'." short)
    | _ -> fail span "This handler has no methods."
  in
  let method_ty = per_call method_ty in
  match Types.repr method_ty with
  | Types.IFn (params, result, row) when List.length params = List.length args ->
    let args =
      List.map2
        (fun p a ->
          let c = argument ~expected:p env ctx a in
          unify_at c.Ast.span p c.Ast.ann;
          c)
        params
        args
    in
    Types.row_within row ctx.row;
    let shown = { target with Ast.ann = Types.IRecord (Types.FCons (short, answered method_ty, Types.FEmpty)) } in
    Ast.annotated span result (`Call (Ast.annotated span (answered method_ty) (`Field (shown, short)), args))
  | Types.IFn (params, _, _) ->
    fail span "'%s' takes %d argument(s) here, but %d are given." short (List.length params) (List.length args)
  | _ -> fail span "This handler has no method '%s'." short

(* A call a transform made through a value that takes control: its arguments,
   a handler for each effect its type takes control of, then what
   [Core.handed] lists, whose answer is the call's. *)
and handed_call env ctx span callee params ret row n args : checked_expr =
  let count = List.length params in
  let surface = List.filteri (fun i _ -> i < count) args
  and rest = List.filteri (fun i _ -> i >= count) args in
  let surface =
    List.map2
      (fun p a ->
        let c = argument ~expected:p env ctx a in
        unify_at c.Ast.span p c.Ast.ann;
        c)
      params
      surface
  in
  let answer = Types.fresh () in
  let handed = handed_params Core.handed ~result:ret ~answer ~row:(Types.fresh_row ()) in
  let taken = controlling_row row in
  let labels = fst (Types.labels_of_infer_row row) in
  let rest =
    List.mapi
      (fun i a ->
        if i >= n
        then (
          let wanted = List.nth handed (i - n) in
          let c = argument ~expected:wanted env ctx a in
          unify_at c.Ast.span wanted c.Ast.ann;
          c)
        else (
          let c = argument env ctx a in
          (match List.nth_opt taken i with
           | Some label ->
             let wanted = handler_type label (Option.value ~default:[] (List.assoc_opt label labels)) in
             unify_at c.Ast.span (per_call wanted) c.Ast.ann
           | None -> ());
          c))
      rest
  in
  let rec without (r : Types.infer_row) =
    match Types.repr_row r with
    | Types.RCons (l, _, rest) when List.mem l taken -> without rest
    | Types.RCons (l, a, rest) -> Types.RCons (l, a, without rest)
    | r -> r
  in
  Types.row_within (without row) ctx.row;
  Ast.annotated span answer (`Call (callee, surface @ rest))

(* The operand is only asked its type: nothing it would hoist or call is part
   of the program. *)
and reflected_type env ctx (operand : Ast.expr) : Types.ty =
  let infer () =
    match operand.Ast.it with
    (* The declared type when no value answers, so `typeof(Dog)` works. *)
    | `Var name when lookup env name = None ->
      (match Hashtbl.find_opt ctx_type_param_names name with
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
         (try infer_ty_of_annotation { Ast.it = Ast.Ty_name name; span = operand.Ast.span; ann = () } with
          | Located _ -> fail operand.Ast.span "Nothing named '%s' is a value or a type." name))
    | `Static_ref ({ Ast.it = `Var name; _ }, static_args)
      when lookup env name = None && Hashtbl.mem ctx_types name ->
      let written =
        List.map
          (function
            | Ast.St_type t -> t
            | Ast.St_value { Ast.it = `Var n; span; _ } -> Ast.at span (Ast.Ty_name n)
            | Ast.St_value v -> fail v.Ast.span "'%s' takes a type here, not a value." name)
          static_args
      in
      infer_ty_of_annotation (Ast.at operand.Ast.span (Ast.Ty_app (name, written)))
    | _ ->
      let hoisted = ctx.hoisted in
      Fun.protect
        ~finally:(fun () -> ctx.hoisted <- hoisted)
        (fun () -> (infer_expr env ctx operand).Ast.ann)
  in
  let ty = Types.resolve (if walking () then (ops ()).unused infer else infer ()) in
  if walking () then (ops ()).copies_of ty;
  ty

(* Spliced where it stands, so no stage after the walk meets a `typeof`. *)
and reflected env ctx span operand field : checked_expr =
  let ty = reflected_type env ctx operand in
  let answer =
    match field with
    | Some ("name" | "doc") -> Types.IStr
    | Some "shape" -> Types.ISum (Core.shape, [])
    | Some "attrs" -> Types.iarray (Types.INamed (Core.attr, []))
    | _ -> Types.INamed (Core.reflect "Type", [])
  in
  if walking ()
  then infer_expr ~expected:answer env ctx ((ops ()).typeof span ty field)
  else Ast.annotated span answer (`Var "typeof")

and declare_traits (body : Ast.stmt list) =
  List.iter
    (fun (s : Ast.stmt) ->
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

and declare_impls registry (body : Ast.stmt list) =
  List.iter
    (fun (s : Ast.stmt) ->
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
            (fun (m : (Ast.stmt, unit) Ast.method_def) ->
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
          (fun (m : (Ast.stmt, unit) Ast.method_def) ->
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
            (* Keyed by the mangled name, so `Index<Int>` and `Index<Range>`
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
            Hashtbl.add ctx_impl_params (type_name, t) params;
            with_type_params type_params (fun () ->
              let declared = type_arguments t args in
              Hashtbl.add ctx_impls (type_name, t) declared;
              let bounds =
                List.concat
                  (List.mapi
                     (fun i (p : Ast.type_param) ->
                       match p.Ast.tp_ty with
                       | Some { Ast.it = Ast.Ty_name bound; _ } when Hashtbl.mem ctx_traits bound -> [ i, bound ]
                       | _ -> [])
                     params)
              in
              if bounds <> [] then Hashtbl.add ctx_impl_bounds (type_name, t) (declared, bounds)))
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
             (* One entry answers all four: the lowering turns the `Ordering` the
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
             (* By the names written: `Index<Int> for List<T>` is every List. *)
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
and check_supertraits (body : Ast.stmt list) =
  List.iter
    (fun (s : Ast.stmt) ->
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
               (* At the arguments the supertrait is written with: `Derived<Int>`
                  over `Base<Idx>` is satisfied by `Base<Int>` and no other. *)
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
            (fun (m : (Ast.stmt, unit) Ast.method_def) ->
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
  (m : (Ast.stmt, unit) Ast.method_def)
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
       so `<E>` at an impl of `Source<Int, <Log>>` is `<log>`. *)
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
and declare_effects (body : Ast.stmt list) =
  List.iter
    (fun (s : Ast.stmt) ->
      let declared =
        match s.Ast.it with
        | `Trait_decl (name, params, body) when Ast.is_effect body -> Some (name, params)
        | _ -> None
      in
      match declared with
      | Some (name, params) when not (Hashtbl.mem ctx_effect_params name) ->
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
and declare_type_names (body : Ast.stmt list) =
  List.iter
    (fun (s : Ast.stmt) ->
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
        (* Already the right shape, or `Add(Expr<Int>, …)` reads `Expr` as a
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

and declare_type_bodies (body : Ast.stmt list) =
  List.iter
    (fun (s : Ast.stmt) ->
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

and hoist env (body : Ast.stmt list) =
  List.iter
    (fun (s : Ast.stmt) ->
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
          (fun (m : (Ast.stmt, unit) Ast.method_def) ->
            let m = if walking () then open_continuation trait m else m in
            note_continuation trait m;
            match m.Ast.md_params with
            (* [declare_impls] reported it; binding it anyway would blame a
               parameter the author did write. The walk binds it anyway, since
               nothing generalizes it later. *)
            | [] when not (walking ()) -> ()
            | { Ast.name = "self"; _ } :: rest ->
              let mangled = Ast.impl_method_name trait type_name m.Ast.md_name in
              let types, values = split_static m.Ast.md_signature.Ast.static_params in
              let type_params = impl_params @ type_params_of s.Ast.span types in
              Hashtbl.replace ctx_fn_params mangled type_params;
              Hashtbl.replace unchecked mangled None;
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
                let scheme =
                  declared_scheme
                    type_params
                    (Types.IFn (param_types, annotated_or_fresh m.Ast.md_signature.Ast.ret, row))
                in
                bind env mangled scheme;
                Hashtbl.replace unchecked mangled (Some scheme);
                note_walk_decl
                  env
                  ~name:mangled
                  ~scheme
                  ~vars:type_params
                  ~values
                  ~params:m.Ast.md_params
                  ~sg:m.Ast.md_signature
                  ~body:m.Ast.md_body
                  ~impl:(Some (trait, type_name, params))
                  ~span:s.Ast.span)
            (* An associated function takes no receiver, but its signature is
               still written in the impl's parameters. *)
            | written ->
              let mangled = Ast.impl_method_name trait type_name m.Ast.md_name in
              let types, values = split_static m.Ast.md_signature.Ast.static_params in
              let type_params = impl_params @ type_params_of s.Ast.span types in
              Hashtbl.replace ctx_fn_params mangled type_params;
              Hashtbl.replace unchecked mangled None;
              with_type_params type_params (fun () ->
                let row =
                  match m.Ast.md_signature.Ast.row with
                  | Some labels -> row_of_labels ~span:s.Ast.span labels
                  | None -> Types.fresh_row ()
                in
                let scheme =
                  declared_scheme
                    type_params
                    (Types.IFn
                       ( List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) written
                       , annotated_or_fresh m.Ast.md_signature.Ast.ret
                       , row ))
                in
                bind env mangled scheme;
                Hashtbl.replace unchecked mangled (Some scheme);
                note_walk_decl
                  env
                  ~name:mangled
                  ~scheme
                  ~vars:type_params
                  ~values
                  ~params:m.Ast.md_params
                  ~sg:m.Ast.md_signature
                  ~body:m.Ast.md_body
                  ~impl:(Some (trait, type_name, params))
                  ~span:s.Ast.span))
          impl.Ast.ib_methods
      | `Fn (name, params, signature, body) ->
        let types, values = split_static (unmarked signature).Ast.static_params in
        let type_params = type_params_of s.Ast.span types in
        Hashtbl.replace ctx_fn_params name type_params;
        Hashtbl.replace unchecked name None;
        with_type_params type_params (fun () ->
          let param_types =
            List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params
          in
          let row =
            match signature.Ast.row with
            | Some labels -> row_of_labels ~span:s.Ast.span labels
            | None -> Types.fresh_row ()
          in
          let scheme =
            declared_scheme
              type_params
              (Types.IFn (param_types, annotated_or_fresh signature.Ast.ret, row))
          in
          bind env name scheme;
          if List.mem name [ Core.handed; Core.handed_method; Core.handed_abort ]
          then Hashtbl.replace shapes name (scheme, params, body);
          Hashtbl.replace unchecked name (Some scheme);
          note_walk_decl
            env
            ~name
            ~scheme
            ~vars:type_params
            ~values
            ~params
            ~sg:signature
            ~body
            ~impl:None
            ~span:s.Ast.span)
      | _ -> ())
    body

(* A value parameter is settled by what a call writes, never inferred, so the
   walk keeps it out of the signature it reads. *)
and split_static (params : Ast.static_param list) =
  if walking () then List.partition (fun p -> not (is_value_param p)) params else params, []

(* Load-bearing: hoisting reads signatures, which may name a declared type or
   trait, and a use may precede its declaration. *)
and infer_block env ctx (body : Ast.stmt list) : checked_stmt list =
  if walking () then walk_block env ctx body else
  let body = List.map unattributed body in
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

(* In source order, a callee processed where its call settles it. Its own local
   functions are the instances made of them, which the interpreter defines
   before the block runs. Only a block declaring types of its own puts the
   tables back on the way out: one that does not may still have registered a
   type a meta block or a comptime type made, which outlives it. *)
and walk_block env ctx (body : Ast.stmt list) : checked_stmt list =
  let asked =
    match !kept_block with
    | Some asked -> asked == body
    | None -> false
  in
  let body = List.map unattributed body in
  let declares (s : Ast.stmt) =
    match s.Ast.it with
    | `Type_decl _ | `Trait_decl _ | `Impl_decl _ -> true
    | _ -> false
  in
  (* A block declaring its own types or functions holds what its statements
     name, so none of them stands apart from it. *)
  let keeping =
    asked
    && not
         (List.exists
            (fun (s : Ast.stmt) ->
              declares s
              ||
              match s.Ast.it with
              | `Fn _ -> true
              | _ -> false)
            body)
  in
  let run () =
    let outer = !walk_locals
    and outer_blocks = !active_blocks in
    walk_locals := [];
    active_blocks := env :: outer_blocks;
    List.iter
      (fun (s : Ast.stmt) ->
        match s.Ast.it with
        | `Type_decl (name, _, _) -> Hashtbl.replace local_type_home name env
        | _ -> ())
      body;
    Fun.protect
      ~finally:(fun () ->
        walk_locals := outer;
        active_blocks := outer_blocks)
      (fun () ->
        let checked = walk_stmts ~keeping env ctx body in
        let here, elsewhere = List.partition (fun (home, _) -> home == env) !local_instances in
        local_instances := elsewhere;
        List.rev_map snd here @ List.concat_map (ops ()).instances_of (List.rev !walk_locals) @ checked)
  in
  if List.exists declares body then scoped_declarations run else run ()

and walk_stmts ?(keeping = false) env ctx (body : Ast.stmt list) : checked_stmt list =
  declare_traits body;
  declare_effects body;
  declare_type_names body;
  declare_type_bodies body;
  declare_impls ctx.registry body;
  check_supertraits body;
  hoist env body;
  let assigned = assigned_names body in
  if keeping then List.concat_map (kept_stmt env ctx assigned) body else List.concat_map (walk_stmt env ctx assigned) body

(* A statement of the block processed code was asked about, checked with a row
   of its own so it can be passed through wherever the meta block puts it. *)
and kept_stmt env ctx assigned (s : Ast.stmt) : checked_stmt list =
  let outer = ctx.row in
  let row = Types.fresh_row () in
  if is_made_row outer then made_rows := row :: !made_rows;
  let partly = !read_only_partly in
  read_only_partly := false;
  ctx.row <- row;
  let checked, uses =
    Fun.protect
      ~finally:(fun () -> ctx.row <- outer)
      (fun () -> noted (fun () -> walk_stmt env ctx assigned s))
  in
  let whole = not !read_only_partly in
  read_only_partly := partly || not whole;
  Types.row_within row outer;
  if whole && stands_alone s
  then (
    let declared =
      match s.Ast.it with
      | `Var_decl (name, _, _) -> [ name ]
      | `Var_tuple (names, _) -> names
      | _ -> []
    in
    let binds =
      List.filter_map (fun name -> Option.map (fun sc -> name, sc) (Hashtbl.find_opt env.bindings name)) declared
    in
    let n =
      pass_through
        { pc_code = Passed_stmts checked
        ; pc_row = row
        ; pc_view = `Stmt s
        ; pc_binds = binds
        ; pc_uses = fst uses
        ; pc_returns = None
        ; pc_notes = snd uses
        ; pc_shown = false
        }
    in
    Physical_stmt.replace kept_stmts s n);
  checked

and walk_stmt env ctx assigned (s : Ast.stmt) : checked_stmt list =
  match s.Ast.it with
  | `Meta _ | `Derive _ ->
    let generated = in_scope env ctx (fun () -> (ops ()).meta (runtime_names env) (reflected_type env ctx) s) in
    Physical_stmt.replace meta_stmts s generated;
    walk_stmts env ctx (List.map unattributed generated)
  | `Pre_checked n -> passed_stmts env ctx s.Ast.span n
  | `Fn _ | `Impl_decl _ -> []
  | _ -> statement ctx (fun () -> with_pending (fun () -> infer_stmt env ctx assigned s))

(* Code checked once, standing here: what it performs is performed here, and
   what it declared is in scope after it. *)
and passed_stmts env ctx span n : checked_stmt list =
  let p = passed_at span ctx n in
  List.iter (fun (name, scheme) -> bind env name scheme) p.pc_binds;
  match p.pc_code with
  | Passed_stmts checked -> checked
  | Passed_expr checked -> [ Ast.annotated span Types.IUnit (`Expr checked) ]

(* The top level, as the root's body: each statement checked in order with a
   row of its own, which is how a statement is found to throw. One that throws
   is passed through under the root's catcher, so each throwing statement
   catches its own failure and two may throw different types. A top-level `var`
   stays a global: its initializer is an assignment here, and the name is bound
   at the top level only once the initializer is checked, so a function reached
   before it does not see it. *)
and root_block env scope ctx (body : Ast.stmt list) : checked_stmt list =
  let body = List.map unattributed body in
  let assigned = assigned_names body in
  let whole = ctx.row in
  let saved_top = !top_row in
  let caught =
    match Option.map (fun sc -> Types.repr (Types.instantiate sc)) (lookup env Ast.root_catcher) with
    | Some (Types.IFn ([ main ], _, _)) ->
      (match Types.repr main with
       | Types.IFn (_, _, row) -> List.map fst (fst (Types.labels_of_infer_row row))
       | _ -> [])
    | _ -> []
  in
  let throws row = List.exists (fun (l, _) -> List.mem l caught) (fst (Types.labels_of_infer_row row)) in
  let catcher span ?ret (body : Ast.stmt list) : Ast.expr =
    Ast.at span
      (`Call
        ( Ast.at span (`Var Ast.root_catcher)
        , [ Ast.at span (`Lambda ([], { Ast.ret; row = None; static_params = []; inline = false }, body)) ] ))
  in
  let under_catcher (s : Ast.stmt) : Ast.stmt = Ast.at s.Ast.span (`Expr (catcher s.Ast.span [ s ])) in
  let passed_on (shown : Ast.stmt) (checked, row, uses) : Ast.stmt =
    let n =
      pass_through
        { pc_code = Passed_stmts checked
        ; pc_row = row
        ; pc_view = `Stmt shown
        ; pc_binds = []
        ; pc_uses = fst uses
        ; pc_returns = None
        ; pc_notes = snd uses
        ; pc_shown = false
        }
    in
    Ast.at shown.Ast.span (`Pre_checked n)
  in
  let mark_failed s =
    List.iter
      (function
        | Value name -> Hashtbl.replace root_failed name ()
        | Member _ -> ())
      (names_declared s)
  in
  let rewritten = ref [] in
  let as_assignment (s : Ast.stmt) : Ast.stmt =
    let at it : Ast.stmt = { s with Ast.it } in
    match s.Ast.it with
    | `Var_decl (name, _, Some init) -> at (`Expr (Ast.at s.Ast.span (`Assign (name, init))))
    | `Var_decl (_, _, None) -> at (`Block [])
    | `Var_tuple (names, init) ->
      let held = Lower.fresh "tuple" in
      let whole = Ast.at s.Ast.span (`Var held) in
      at
        (`Block
          (at (`Var_decl (held, None, Some init))
           :: List.mapi
                (fun i name -> at (`Expr (Ast.at s.Ast.span (`Assign (name, Ast.at s.Ast.span (`Tuple_get (whole, i)))))))
                names))
    | _ -> s
  in
  let rec one assigned (s : Ast.stmt) : checked_stmt list =
    match s.Ast.it with
    | `Meta _ | `Derive _ ->
      let generated = List.map unattributed ((ops ()).top_meta s) in
      List.concat_map (one (assigned_names generated @ assigned)) generated
    | _ ->
    if List.exists
         (function
           | Value name -> Hashtbl.mem root_failed name
           | Member _ -> false)
         (names_used s)
    then (
      mark_failed s;
      [])
    else (
      let globals =
        match s.Ast.it with
        | `Var_decl (name, annotation, _) -> [ name, annotated_or_fresh annotation ]
        | `Var_tuple (names, _) -> List.map (fun name -> name, Types.fresh ()) names
        | _ -> []
      in
      let check (s : Ast.stmt) =
        let row = Types.fresh_row () in
        ctx.row <- row;
        top_row := Some row;
        let checked, uses =
          noted (fun () -> statement ctx (fun () -> with_pending (fun () -> root_stmt scope ctx assigned globals s)))
        in
        checked, row, uses
      in
      match
        let checked, row, uses = check s in
        let shown = as_assignment s in
        let (checked, row, uses), shown =
          if throws row
          then (
            (* What the transform makes of the catcher's body is checked
               there, inside it, so the globals are already bound. *)
            List.iter (fun (name, ty) -> bind env name (Types.mono ty)) globals;
            let caught = under_catcher (passed_on shown (checked, row, uses)) in
            check caught, caught)
          else (checked, row, uses), shown
        in
        rewritten := passed_on shown (checked, row, uses) :: !rewritten;
        (* Contained, not unified: a function value the statement calls takes
           the statement's row, and the whole top level's would hand it every
           effect the root binds. *)
        (try Types.row_within row whole with
         | Types.Type_error message -> raise (Located { span = s.Ast.span; message }));
        checked
      with
      | checked ->
        List.iter (fun (name, ty) -> bind env name (Types.mono ty)) globals;
        checked
      | exception Located e ->
        !root_errors := e :: !(!root_errors);
        mark_failed s;
        [])
  in
  Fun.protect
    ~finally:(fun () ->
      ctx.row <- whole;
      top_row := saved_top;
      root_rewritten := Some (List.rev !rewritten))
    (fun () -> List.concat_map (one assigned) body)


(* A statement of the root's body. A `var`'s initializer is assigned to the
   global [root_block] declares for it. *)
and root_stmt env ctx assigned globals (s : Ast.stmt) : checked_stmt =
  let span = s.Ast.span in
  let node it : checked_stmt = Ast.annotated span Types.IUnit it in
  let assign name (target : Types.infer_ty) (value : checked_expr) : checked_stmt =
    node (`Expr (Ast.annotated span target (`Assign (name, value))))
  in
  let checked () =
    match s.Ast.it with
    | `Var_decl (name, annotation, init) ->
      let target = List.assoc name globals in
      (match init with
       | None ->
         (try Types.unify target Types.IUnit with
          | Types.Type_error _ ->
            let written = Types.string_of_infer_ty target in
            fail
              span
              "'%s' is declared as %s but has no value; write 'var %s: %s = …;'."
              name
              written
              name
              written);
         node (`Block [])
       | Some e ->
         let value = infer_expr ?expected:(Option.map (fun _ -> target) annotation) env ctx e in
         unify_at value.Ast.span target value.Ast.ann;
         assign name target value)
    | `Var_tuple (names, init) ->
      let value = infer_expr env ctx init in
      let parts = List.map (fun name -> List.assoc name globals) names in
      unify_at value.Ast.span (Types.ITuple parts) value.Ast.ann;
      let held = Lower.fresh "tuple" in
      let whole : checked_expr = Ast.annotated span value.Ast.ann (`Var held) in
      node
        (`Block
          (node (`Var_decl (held, None, Some value))
           :: List.mapi
                (fun i (name, part) -> assign name part (Ast.annotated span part (`Tuple_get (whole, i))))
                (List.combine names parts)))
    | _ -> infer_stmt env ctx assigned s
  in
  match s.Ast.it with
  | `Var_decl _ | `Var_tuple _ ->
    let c =
      try checked () with
      | Types.Type_error message -> raise (Located { span; message })
    in
    note_effect_sites span ctx.row;
    c
  | _ -> checked ()

(* In [dependency_order], back in source order. Functions calling each other are
   generalized together, once all of them are checked, so none is generalized
   while another's row is still [hoist]'s. [attempt] says what a failed check
   leaves behind. *)
and infer_in_order env ctx assigned ~attempt (body : Ast.stmt list) =
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
         callers have instantiated the smaller one. *)
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
  let env_vars, env_rows, env_fields = env_free_all env in
  List.iter
    (fun (mangled, fn_type) -> bind env mangled (Types.generalize ~env_vars ~env_rows ~env_fields fn_type))
    methods

and infer_stmt ?(generalize = true) env ctx assigned (s : Ast.stmt)
  : checked_stmt
  =
  let checked =
    try infer_stmt_impl ~generalize env ctx assigned s with
    | Types.Type_error message -> raise (Located { span = s.Ast.span; message })
  in
  note_effect_sites s.Ast.span ctx.row;
  checked

and infer_stmt_impl ~generalize env ctx assigned (s : Ast.stmt) : checked_stmt =
  let span = s.Ast.span in
  let node it : checked_stmt = Ast.annotated span Types.IUnit it in
  match s.Ast.it with
  | `Expr ({ Ast.it = `Call _; _ } as e) ->
    let outer = !discarded in
    discarded := Some (Source_map.Span.offsets e.Ast.span);
    node (`Expr (Fun.protect ~finally:(fun () -> discarded := outer) (fun () -> infer_expr env ctx e)))
  | `Expr e -> node (`Expr (infer_expr env ctx e))
  | `Attributed _ -> infer_stmt_impl ~generalize env ctx assigned (unattributed s)
  | `Pre_checked n ->
    (match passed_stmts env ctx span n with
     | [ single ] -> single
     | many -> node (`Block many))
  | `Import _ | `Global_import _ -> node (`Block [])
  | (`Meta _ | `Derive _ | `Fn _ | `Impl_decl _) when walking () ->
    node (`Block (walk_stmts env ctx [ s ]))
  | `Gen _ when walking () -> fail span "'gen' is only allowed inside a meta block."
  (* Metaprocessing has replaced every one before a check sees it. *)
  | #Ast.meta_blocks | `Type_members _ -> assert false
  | `Trait_members _ ->
    raise (Rejected { span; message = "A trait whose body runs a meta block is declared only at the top level." })
  (* The arity is written, so the tuple it takes apart is known before the
     initializer is looked at — an annotation would say nothing more. *)
  | `Var_tuple (names, init) ->
    let init = infer_expr env ctx init in
    let parts = List.map (fun _ -> Types.fresh ()) names in
    unify_at init.Ast.span (Types.ITuple parts) init.Ast.ann;
    List.iter2 (fun name part -> bind env name (Types.mono part)) names parts;
    node (`Var_tuple (names, init))
  (* A handler a transform made for itself is read at whatever type each call
     through it uses, so what nothing here settles is left open. *)
  | `Var_decl (name, Some { Ast.it = Ast.Ty_name n; _ }, Some init) when String.equal n Ast.open_type ->
    let init = infer_expr env ctx init in
    leave_open init.Ast.ann;
    bind env name (Types.mono init.Ast.ann);
    node (`Var_decl (name, None, Some init))
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
          infer_expr ?expected:(Option.map (fun _ -> declared) annotation) env ctx e
        in
        unify_at e'.Ast.span declared e'.Ast.ann;
        Some e'
    in
    let generalizable =
      (not (walking ()))
      && (not (List.mem name assigned))
      && (match s.Ast.it with
          | `Var_decl (_, _, Some e) -> is_syntactic_value e
          | _ -> false)
    in
    bind
      env
      name
      (if generalizable
       then
         (let env_vars, env_rows, env_fields = env_free_all env in
          Types.generalize ~env_vars ~env_rows ~env_fields declared)
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
        , one_statement ctx then_branch (fun () -> infer_stmt env ctx assigned then_branch)
        , Option.map
            (fun branch -> one_statement ctx branch (fun () -> infer_stmt env ctx assigned branch))
            else_branch ))
  (* Lowered here rather than in the parser: whether the sequence is indexed or
     pulled is a question about its type. One the checker cannot see yet is
     indexed, which is what every `for` was before iterators. *)
  | `For_in (names, iterable, body) ->
    let scope = new_env (Some env) in
    let seq = Lower.fresh "seq" in
    let at = iterable.Ast.span in
    let decl =
      statement ctx (fun () ->
        infer_stmt scope ctx assigned { Ast.it = `Var_decl (seq, None, Some iterable); span = at; ann = () })
    in
    let held =
      match (List.hd (List.rev decl)).Ast.it with
      | `Var_decl (_, _, Some e) -> Types.repr e.Ast.ann
      | _ -> Types.IUnit
    in
    let loop =
      match held with
      | Types.INamed (name, [ _; _ ]) when String.equal name Core.iter -> Lower.pulled at names seq ~closes:true body
      | Types.IFn ([], _, _) -> Lower.pulled at names seq ~closes:false body
      | _ -> Lower.indexed at names seq body
    in
    node (`Block (decl @ infer_block scope ctx loop))
  | `While (cond, body) ->
    let cond = infer_expr env ctx cond in
    unify_at cond.Ast.span Types.IBool cond.Ast.ann;
    let looping = !in_loop in
    in_loop := true;
    let body = Fun.protect ~finally:(fun () -> in_loop := looping)
        (fun () -> one_statement ctx body (fun () -> infer_stmt env ctx assigned body))
    in
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
        (let env_vars, env_rows, env_fields = env_free_all env in
         Types.generalize ~env_vars ~env_rows ~env_fields fn_type));
    Ast.annotated span fn_type (`Fn (name, params, signature, body)))
  | `Defer inner ->
    (* A `for` closing what it pulls from performs what pulling does, and that
       is what unwinding the producer runs: its own `defer`s, which cannot
       fail. *)
    let closes_loop =
      match inner.Ast.it with
      | `Expr { Ast.it = `Method_call ({ Ast.it = `Var n; _ }, "close", _, [], None); _ } ->
        String.starts_with ~prefix:"seq#" n
      | _ -> false
    in
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
        (fun () -> one_statement ctx inner (fun () -> infer_stmt env ctx assigned inner))
    in
    Types.row_within d.d_row ctx.row;
    if not closes_loop then deferred_rows := d :: !deferred_rows;
    node (`Defer inner)
  | `Type_decl (name, params, body) -> node (`Type_decl (name, params, body))
  | `Trait_decl (name, params, body) ->
    if Ast.is_effect body then declare_operations env span name params (operations_of span name body);
    node (`Trait_decl (name, params, body))
  | `Impl_decl (trait, type_name, params, impl) ->
    let inferred =
      List.map
        (fun (m : (Ast.stmt, unit) Ast.method_def) ->
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
          note_continuation trait m;
          let scope = new_env (Some env) in
          List.iter2 (bind_param scope) m.Ast.md_params param_types;
          let body =
            in_function_body ctx ~ret:declared_ret ~row:declared_row (fun () ->
              infer_block scope ctx m.Ast.md_body)
          in
          let fn_type = Types.IFn (param_types, declared_ret, declared_row) in
          mangled, fn_type, { m with Ast.md_body = body; md_ann = fn_type }))
        impl.Ast.ib_methods
    in
    (* A value is printed inside another value's impl, and `str` declares no
       row, so an effect performed here would have nothing to handle it. *)
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
        let e' = infer_expr ~expected env ctx e in
        unify_at e'.Ast.span expected e'.Ast.ann;
        Some e'
    in
    node (`Return e)


and declare_operations env span name params (ops : Ast.op_decl list) =
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
      ops

(* An effect trait's methods as the operations they are. One that takes control
   and whose result is its own parameter, standing nowhere in its arguments,
   can never be resumed: the handler is given no value of that type. *)
and operations_of span name (body : Ast.trait_body) : Ast.op_decl list =
  List.map
    (fun (m : Ast.method_sig) ->
      let own = List.map (fun (c : Ast.static_param) -> c.Ast.sp_name) m.Ast.ms_signature.Ast.static_params in
      let never_resumes =
        match m.Ast.ms_signature.Ast.ret with
        | Some { Ast.it = Ast.Ty_name t; _ } ->
          List.mem t own
          && not
               (List.exists
                  (fun (p : Ast.param) -> Option.fold ~none:false ~some:(Ast.mentions t) p.Ast.ty)
                  m.Ast.ms_params)
        | _ -> false
      in
      { Ast.op_name = Ast.operation_name name m.Ast.ms_name
      ; op_kind =
          (if not (Ast.takes_control m)
           then Ast.Op_fn
           else if never_resumes || Ast.aborts m.Ast.ms_attrs
           then Ast.Op_final
           else Ast.Op_ctl)
      ; op_tparams = own
      ; op_params = m.Ast.ms_params
      ; op_ret =
          Some
            (Option.value
               m.Ast.ms_signature.Ast.ret
               ~default:{ Ast.it = Ast.Ty_name "Unit"; span; ann = () })
      ; op_attrs = m.Ast.ms_attrs
      })
    body.Ast.tb_methods

and infer_match
  : 'b 'c.
    env
    -> ctx
    -> Ast.span
    -> Ast.expr
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
    (* Where `Expr<T>` becomes `Expr<Int>`, and only for this arm — which is
       why it is solved into a substitution rather than unified. *)
    let refine declared =
      let freshened = instantiation vars declared in
      let head = List.map (Types.substitute freshened) declared.vd_result in
      let fresh = List.map (fun (_, v) -> Types.var_id v) freshened in
      match Types.solve ~fresh (List.combine sum_args head) with
      | Some refinement ->
        (* What the head leaves unsaid is existential: only a run-time value
           says what it is, so an instance reached through it is generic in
           it, as one reached from a handler arm is. *)
        if walking ()
        then
          List.iter
            (fun (id, v) -> if not (List.mem_assoc id refinement) then Types.declare_param v)
            freshened;
        freshened, refinement
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
          (* At a key the scrutinee is concrete, so an arm it cannot reach is
             one this instance never runs, though another key may run it. With
             no type parameters there is no other key, and the arm is dead. *)
          | exception Not_found when walking () && Hashtbl.length ctx_type_params > 0 -> raise Exit
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
      List.filter_map
        (fun ((pattern : Ast.pattern), body) ->
          try Some (
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
          with
          | Exit -> None)
        cases
    in
    List.iter
      (fun (name, declared) ->
        if (not (List.mem name !covered)) && reachable declared
        then fail span "This match does not cover '%s'." name)
      variants;
    scrutinee, cases)

(* The row work is the same wherever a `run` stands; [answer] is what its
   handlers' methods that take control answer. *)
and check_run ?transform env ctx assigned span ~answer handlers infer_body =
  if handlers <> [] && List.for_all (function Ast.Bound _ -> true | _ -> false) handlers
  then check_bound env ctx assigned handlers infer_body
  else check_bindings ?transform env ctx assigned span ~answer handlers infer_body

(* A run a transform has already made: each handler's value is declared where
   the run stands, outside its bindings, and the body is checked under them as
   it is. A value's type is whatever its declaration now says, since an outer
   transform may have rewritten its methods. *)
and check_bound env ctx assigned handlers infer_body =
  let checked =
    List.map
      (function
        | Ast.Bound (_, handler, Some s) -> run_value env ctx assigned handler s
        | _ -> [], None)
      handlers
  in
  let prelude = List.concat_map fst checked in
  let outer = !effect_bindings in
  let pushed =
    List.filter_map
      (function
        | Ast.Bound (label, handler, value) ->
          let value =
            Option.bind value (fun (s : Ast.stmt) ->
              match s.Ast.it with
              | `Var_decl (name, _, _) -> Some name
              | _ -> None)
          in
          binds_in_run handler;
          Some { bd_label = label; bd_handler = handler; bd_value = value; bd_outer = outer; bd_key = None }
        | _ -> None)
      handlers
  in
  let body_row = Types.fresh_row () in
  let body =
    in_ctx ctx ~set:(fun () -> ctx.row <- body_row) (fun () ->
      effect_bindings := pushed @ outer;
      Fun.protect ~finally:(fun () -> effect_bindings := outer) infer_body)
  in
  let performed, _ = Types.labels_of_infer_row body_row in
  let remaining =
    List.fold_left
      (fun row b ->
        match List.assoc_opt b.bd_label performed with
        | Some args ->
          (try Types.rewrite_row b.bd_label args row with
           | Types.Type_error _ -> row)
        | None -> row)
      body_row
      pushed
  in
  Types.unify_row remaining ctx.row;
  List.iter (fun (_, row) -> Option.iter (fun row -> Types.row_within row ctx.row) row) checked;
  body, prelude

(* A value with no signature of its own: a named handler's, read against its
   effect's methods where they still fit, or one an outer transform rewrote,
   read as written. *)
and bound_value env ctx assigned handler (s : Ast.stmt) : checked_stmt list =
  let rewritten, s =
    match s.Ast.it with
    | `Var_decl (name, Some { Ast.it = Ast.Ty_name n; _ }, init) when String.equal n Ast.open_type ->
      true, { s with Ast.it = `Var_decl (name, None, init) }
    | _ -> false, s
  in
  match s.Ast.it with
  | `Var_decl (name, None, Some ({ Ast.it = `Record_lit fields; _ } as init)) ->
    let arity (e : Ast.expr) =
      match e.Ast.it with
      | `Lambda (params, _, _) -> Some (List.length params)
      | _ -> None
    in
    let first = Hashtbl.find_opt handler_values handler in
    let shown =
      match Option.map Types.repr (Hashtbl.find_opt handler_shown handler) with
      | Some (Types.IRecord f) -> f
      | _ -> Types.FEmpty
    in
    let rec field_of l (f : Types.infer_fields) =
      match Types.repr_fields f with
      | Types.FCons (l', t, _) when String.equal l l' -> Some t
      | Types.FCons (_, _, rest) -> field_of l rest
      | _ -> None
    in
    (* A method is read as what it is handed, or, written as its operation
       shows it, as that. *)
    let rec fitted n (f : Types.infer_fields) =
      match Types.repr_fields f with
      | Types.FCons (l, ty, rest) ->
        (match List.assoc_opt l fields, Types.repr ty with
         | Some e, Types.IFn (ps, r, row) ->
           let rest = fitted (n + 1) rest in
           if arity e = Some (List.length ps)
           then Option.map (fun (exact, rest) -> exact, Types.FCons (l, Types.IFn (ps, r, row), rest)) rest
           else (
             match Option.map Types.repr (field_of l shown) with
             | Some (Types.IFn (ps, _, _) as written) when arity e = Some (List.length ps) ->
               Option.map (fun (exact, rest) -> exact, Types.FCons (l, written, rest)) rest
             | _ -> None)
         | _ -> None)
      | _ -> if n = List.length fields then Some (true, Types.FEmpty) else None
    in
    let exact, expected =
      match Option.map Types.repr first with
      | _ when rewritten -> false, None
      | Some (Types.IRecord f) ->
        (match fitted 0 f with
         | Some (exact, f) -> exact, Some (Types.IRecord f)
         | None -> false, None)
      | _ -> false, None
    in
    (* Only the parameters are read from it: what a method performs is checked
       as it is written, apart from what it was first found to perform. *)
    let loosened (t : Types.infer_ty) =
      let rec fields (f : Types.infer_fields) =
        match Types.repr_fields f with
        | Types.FCons (l, ty, rest) ->
          let ty =
            match Types.repr ty with
            | Types.IFn (ps, r, _) -> Types.IFn (ps, r, Types.fresh_row ())
            | ty -> ty
          in
          Types.FCons (l, ty, fields rest)
        | f -> f
      in
      match Types.repr t with
      | Types.IRecord f -> Types.IRecord (fields f)
      | t -> t
    in
    let checked =
      match Hashtbl.find_opt named_handlers handler with
      | Some (name, label) ->
        let outer = !effect_bindings in
        effect_bindings := { bd_label = label; bd_handler = name; bd_value = None; bd_outer = outer; bd_key = None } :: outer;
        let own = Types.fresh_row () in
        let checked =
          Fun.protect
            ~finally:(fun () -> effect_bindings := outer)
            (fun () ->
              in_ctx ctx ~set:(fun () -> ctx.row <- own) (fun () ->
                infer_expr ?expected:(Option.map loosened expected) env ctx init))
        in
        let rec without (r : Types.infer_row) =
          match Types.repr_row r with
          | Types.RCons (l, _, rest) when String.equal l label -> without rest
          | Types.RCons (l, args, rest) -> Types.RCons (l, args, without rest)
          | r -> r
        in
        Types.row_within (without own) ctx.row;
        checked
      | None -> infer_expr ?expected:(Option.map loosened expected) env ctx init
    in
    if not exact
    then (
      (* What is left open is the methods' own, as an operation's own
         parameters are: each handed call takes its own copy. *)
      let in_env, _, _ = env_free_all env in
      List.iter
        (fun (id, _) -> if not (List.mem id in_env) then Hashtbl.replace Types.declared_params id ())
        (Types.free_vars checked.Ast.ann);
      Hashtbl.replace handler_values handler checked.Ast.ann);
    bind env name (Types.mono checked.Ast.ann);
    [ Ast.annotated s.Ast.span Types.IUnit (`Var_decl (name, None, Some checked)) ]
  | _ -> statement ctx (fun () -> infer_stmt env ctx assigned s)

(* The run's fixed meaning, typed: each clause binds the effects it handles,
   which leave the body's row; what is left is the run's own. `handle<E>`
   implements `EffectHandler<E, R>`, so an operation that takes control is
   given the rest of the body as its last parameter, `(A) -> <ρ> R` with ρ what
   the run passes outward, and answers the run; any other is implemented as
   declared. *)
and check_bindings ?transform env ctx assigned span ~answer clauses infer_body =
  let effect_named at name =
    match Hashtbl.find_opt ctx_effects.declared name with
    | Some ops when Hashtbl.mem ctx_traits name -> ops
    | _ ->
      if Hashtbl.mem ctx_traits name
      then fail at "'%s' is not an effect, so it has no operations to handle." (shown_name name)
      else if Hashtbl.mem ctx_types name || Option.is_some (primitive name)
      then fail at "'%s' is not a trait, so it has no operations to handle." (shown_name name)
      else fail at "Unknown effect '%s'." (shown_name name)
  in
  let effect_arguments at name (written : Ast.type_expr list option) =
    let params = Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params name) in
    match written with
    | None when params = [] -> []
    | None ->
      fail
        at
        "Trait '%s' takes %d type argument(s), which a handler writes: 'handle<%s<…>>'."
        (shown_name name)
        (List.length params)
        (shown_name name)
    | Some args ->
      if List.length args <> List.length params
      then
        fail
          at
          "Trait '%s' takes %d type argument(s) but %d were given."
          (shown_name name)
          (List.length params)
          (List.length args);
      List.map infer_ty_of_annotation args
  in
  let inline =
    List.filter_map
      (function
        | Ast.Handle (handled, defs) ->
          let name, written =
            match handled.Ast.it with
            | Ast.Ty_name n -> n, None
            | Ast.Ty_app (n, args) -> n, Some args
            | _ -> fail handled.Ast.span "A handler names the effect it handles."
          in
          let operations = effect_named handled.Ast.span name in
          (* The library's instance, in the walk, says what each method is; the
             same rule written here says it where there is no walk, and for a
             generic effect, which the instance's meta block cannot be handed as
             a name. *)
          let shapes =
            if walking ()
               && List.exists (fun (o : Ast.op_decl) -> o.Ast.op_kind <> Ast.Op_fn) operations
               && Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params name) = []
            then
              Option.bind ((ops ()).effect_handler handled.Ast.span name) (fun instance ->
                Option.map
                  (fun (_, (body : Ast.trait_body)) -> body.Ast.tb_methods)
                  (Hashtbl.find_opt ctx_traits instance))
            else None
          in
          Some (name, effect_arguments handled.Ast.span name written, operations, defs, shapes)
        | Ast.Named _ | Ast.Bound _ -> None)
      clauses
  in
  let named =
    List.filter_map
      (function
        | Ast.Named name -> Some name
        | _ -> None)
      clauses
  in
  let implemented = implemented_by in
  let lowering = transform in
  let takes_control label =
    List.exists
      (fun (o : Ast.op_decl) -> o.Ast.op_kind <> Ast.Op_fn)
      (Option.value ~default:[] (Hashtbl.find_opt ctx_effects.declared label))
  in
  (* A named handler's value, one per effect it binds: a record of closures
     calling its impl's methods, so it is handed on like an inline one. *)
  let named_values =
    if not (walking ())
    then []
    else
      List.concat_map
        (fun name ->
          List.map
            (fun (label, args, _) ->
              incr handler_count;
              let handler = Ast.generated [ "handler"; string_of_int !handler_count ] in
              let value = Ast.generated [ "hv"; string_of_int !handler_count ] in
              let ops = Option.value ~default:[] (Hashtbl.find_opt ctx_effects.declared label) in
              let at it = Ast.at span it in
              let field (o : Ast.op_decl) =
                let short = method_of_operation label o.Ast.op_name in
                let control = o.Ast.op_kind <> Ast.Op_fn in
                let count = List.length o.Ast.op_params + if control && not (Ast.aborts o.Ast.op_attrs) then 1 else 0 in
                let names = List.init count (fun i -> Ast.generated [ "arg"; string_of_int i ]) in
                let call = at (`Call (at (`Var o.Ast.op_name), List.map (fun n -> at (`Var n)) names)) in
                ( short
                , at
                    (`Lambda
                      ( List.map (fun n -> { Ast.name = n; ty = None; implicit = false }) names
                      , plain_signature
                      , [ at (`Return (Some call)) ] )) )
              in
              let fields = List.map field ops in
              let shown, ty = handler_types ~answer label args in
              Hashtbl.replace handler_values handler ty;
              Hashtbl.replace handler_shown handler shown;
              Hashtbl.replace named_handlers handler (name, label);
              let record = at (`Record_lit fields) in
              (name, label), (handler, value, Ast.at span (`Var_decl (value, None, Some record))))
            (implemented name))
        named
  in
  let named_value name label = List.assoc_opt (name, label) named_values in
  (* An inline handler whose operations take control gives the run its fixed
     meaning: the body is handed to the library's transform, and what that
     generates is checked in the body's place. *)
  let transform =
    match transform with
    | Some t
      when walking ()
           && (List.exists (fun (name, _, _, _, _) -> takes_control name) inline
               || List.exists (fun name -> List.exists (fun (l, _, _) -> takes_control l) (implemented name)) named) ->
      Some t
    | _ -> None
  in
  if walking ()
  then
    walk_bindings
      env ctx assigned span ~answer ~lowering ~transform ~inline ~named ~named_value ~takes_control infer_body
  else (
    (* Outside the walk nothing is lowered: the methods are checked against
       the continuation the body leaves them. *)
    let body_row = Types.fresh_row () in
    List.iter
      (fun (name, args, ops, defs, _) ->
        handle_block env ctx assigned span ~answer ~resumes:(Types.fresh_row ()) ~pass:`Unmarked name args ops defs)
      inline;
    let body = in_ctx ctx ~set:(fun () -> ctx.row <- body_row) infer_body in
    let performed = fst (Types.labels_of_infer_row body_row) in
    let claimed = Hashtbl.create 4 in
    List.iter (fun (name, _, _, _, _) -> Hashtbl.replace claimed name ()) inline;
    List.iter
      (fun name ->
        List.iter
          (fun (label, _, _) ->
            if Hashtbl.mem claimed label then fail span "'%s' is handled twice in this run." (shown_name label);
            Hashtbl.replace claimed label ())
          (implemented name))
      named;
    let by_type name =
      if not (Hashtbl.mem ctx_types name)
      then raise (Rejected { span; message = Printf.sprintf "Unknown handler '%s'." name });
      let bound = List.filter (fun (label, _, _) -> List.mem_assoc label performed) (implemented name) in
      if bound = [] then fail span "'%s' handles nothing this run performs." (shown_name name);
      List.iter
        (fun (_, _, answers) ->
          List.iter (fun (r : Ast.type_expr) -> unify_at span answer (infer_ty_of_annotation r)) answers)
        bound;
      List.map (fun (label, args, _) -> label, args) bound
    in
    let bindings =
      List.map (fun (name, args, ops, defs, _) -> Some (ops, defs), name, args) inline
      @ List.concat_map (fun name -> List.map (fun (label, args) -> None, label, args) (by_type name)) named
    in
    let seen = Hashtbl.create 4 in
    List.iter
      (fun (_, label, _) ->
        if Hashtbl.mem seen label then fail span "'%s' is handled twice in this run." (shown_name label);
        Hashtbl.replace seen label ())
      bindings;
    let remaining = List.fold_left (fun row (_, label, args) -> discharged label args row) body_row bindings in
    Types.unify_row remaining ctx.row;
    List.iter
      (fun (binding, label, args) ->
        match binding with
        | None -> ()
        | Some (ops, defs) ->
          handle_block env ctx assigned span ~answer ~resumes:remaining ~pass:`Ctl label args ops defs)
      bindings;
    body, [])

(* The walk's run: each inline handler is a value, a record of its methods,
   checked against what `EffectHandler<E, R>` says of each method; the body is
   checked under the bindings as the transform made it. *)
and walk_bindings
      env ctx assigned span ~answer ~lowering ~transform ~inline ~named ~named_value ~takes_control infer_body =
  let implemented = implemented_by in
  let outer = !effect_bindings in
  let clauses =
    List.map
      (fun (name, args, ops, defs, shapes) ->
        incr handler_count;
        let handler = Ast.generated [ "handler"; string_of_int !handler_count ] in
        let value =
          match defs with
          | [] -> None
          | _ -> Some (Ast.generated [ "hv"; string_of_int !handler_count ])
        in
        Hashtbl.replace bound_arguments (handler, name) args;
        let signature () = handler_signature span ~answer ~shapes name args ops defs in
        Hashtbl.replace handler_signatures handler signature;
        Hashtbl.replace handler_labels handler name;
        (* A handler with no methods has no value to check, and still owes
           the effect's. *)
        ignore (signature ());
        name, args, ops, defs, handler, value)
      inline
  in
  let records =
    List.filter_map
      (fun (name, _, ops, defs, handler, value) ->
        Option.map (fun hv -> handler, handler_record span hv name ops defs) value)
      clauses
  in
  (* Read where the run stands: a method is outside its run. *)
  let check_values values =
    effect_bindings := outer;
    List.fold_left
      (fun (checked, rows) (handler, s) ->
        let saved = !read_handler_value in
        read_handler_value := false;
        let c, row =
          let outer = !arm_sites in
          let sites = Hashtbl.create 4 in
          arm_sites := Some sites;
          Fun.protect
            ~finally:(fun () -> arm_sites := outer)
            (fun () ->
              let checked = run_value env ctx assigned handler s in
              Hashtbl.iter
                (fun label span -> if not (Hashtbl.mem escaping_sites label) then Hashtbl.add escaping_sites label span)
                sites;
              checked)
        in
        if !read_handler_value then Hashtbl.replace reading_handlers handler ();
        read_handler_value := saved || !read_handler_value;
        checked @ c, rows @ Option.to_list row)
      ([], [])
      values
  in
  (* Before a transform reads the run as written: what that read checks and
     the transform leaves whole is passed through into the run it makes, so a
     call there is keyed by these handlers already. *)
  List.iter (fun (_, _, _, _, handler, _) -> binds_in_run handler) clauses;
  List.iter
    (fun name ->
      List.iter
        (fun (label, _, _) ->
          match named_value name label with
          | Some (handler, _, _) -> binds_in_run handler
          | None -> ())
        (implemented name))
    named;
  let pushed =
    List.map
      (fun (name, _, _, _, handler, value) ->
        { bd_label = name; bd_handler = handler; bd_value = value; bd_outer = outer; bd_key = None })
      clauses
    @ List.concat_map
        (fun name ->
          List.map
            (fun (label, _, _) ->
              match named_value name label with
              | Some (handler, value, _) ->
                { bd_label = label; bd_handler = handler; bd_value = Some value; bd_outer = outer; bd_key = None }
              | None -> { bd_label = label; bd_handler = name; bd_value = None; bd_outer = outer; bd_key = None })
            (implemented name))
        named
  in
  let bound =
    List.map
      (fun (name, _, _, _, handler, value) ->
        Ast.Bound
          ( name
          , handler
          , Option.map (fun _ -> List.assoc handler records) value ))
      clauses
    @ List.concat_map
        (fun name ->
          List.map
            (fun (label, args, _) ->
              match named_value name label with
              | Some (handler, _, decl) ->
                Hashtbl.replace bound_arguments (handler, label) args;
                Ast.Bound (label, handler, Some decl)
              | None ->
                Hashtbl.replace bound_arguments (name, label) args;
                Ast.Bound (label, name, None))
            (implemented name))
        named
  in
  let shell body : Ast.expr = Ast.at span (`Run_expr (None, body, bound)) in
  let surface, check_valued =
    match lowering with
    | Some l -> l
    | None -> fail span "A run in the walk is lowered."
  in
  let lowered =
    match transform with
    | Some _ ->
      let handled =
        List.filter_map (fun (name, _, _, _, _, _) -> if takes_control name then Some name else None) clauses
        @ List.concat_map
            (fun name ->
              List.filter_map (fun (l, _, _) -> if takes_control l then Some l else None) (implemented name))
            named
      in
      (* The transform reads what the methods perform, so the values as
         written are read first; what it generates is checked again below,
         from scratch. *)
      let _, arms = check_values records in
      effect_bindings := pushed @ outer;
      let saved = !arm_rows in
      arm_rows := arms;
      Fun.protect
        ~finally:(fun () ->
          effect_bindings := outer;
          arm_rows := saved)
        (fun () -> transformed env ctx span surface handled (shell { Ast.vb_stmts = []; vb_value = None }))
    | None -> shell surface
  in
  let lowered_values, lowered_body =
    match lowered with
    | { Ast.it = `Run_expr (_, body, clauses); _ } ->
      ( List.filter_map
          (function
            | Ast.Bound (_, handler, Some s) -> Some (handler, s)
            | _ -> None)
          clauses
      , body )
    | g -> fail g.Ast.span "A run's transform made something other than a run."
  in
  (* A named handler's value is checked once the body has settled what the
     run answers, which its impl's methods may be generic in. *)
  let named_late, inline_now = List.partition (fun (handler, _) -> Hashtbl.mem named_handlers handler) lowered_values in
  let lowered_prelude, rows = check_values inline_now in
  let lowered_prelude =
    if final_read ()
    then lifted env span clauses lowered_prelude
    else lowered_prelude
  in
  List.iter
    (fun (handler, (s : Ast.stmt)) ->
      match s.Ast.it, Hashtbl.find_opt handler_values handler with
      | `Var_decl (name, _, _), Some ty -> bind env name (Types.mono ty)
      | _ -> ())
    named_late;
  let body_row = Types.fresh_row () in
  let body =
    in_ctx ctx ~set:(fun () -> ctx.row <- body_row) (fun () ->
      effect_bindings := pushed @ outer;
      Fun.protect ~finally:(fun () -> effect_bindings := outer) (fun () -> check_valued lowered_body))
  in
  last_lowered := Some lowered;
  let performed = fst (Types.labels_of_infer_row body_row) in
  let claimed = Hashtbl.create 4 in
  List.iter (fun (name, _, _, _, _, _) -> Hashtbl.replace claimed name ()) clauses;
  List.iter
    (fun name ->
      List.iter
        (fun (label, _, _) ->
          if Hashtbl.mem claimed label then fail span "'%s' is handled twice in this run." (shown_name label);
          Hashtbl.replace claimed label ())
        (implemented name))
    named;
  let by_type name =
    if not (Hashtbl.mem ctx_types name)
    then raise (Rejected { span; message = Printf.sprintf "Unknown handler '%s'." name });
    let reached label =
      match named_value name label with
      | Some (handler, _, _) -> Hashtbl.mem used_handlers handler
      | None -> false
    in
    let bound =
      List.filter
        (fun (label, _, _) ->
          List.mem_assoc label performed || reached label || (Option.is_some transform && takes_control label))
        (implemented name)
    in
    if bound = [] then fail span "'%s' handles nothing this run performs." (shown_name name);
    List.iter
      (fun (_, _, answers) ->
        List.iter (fun (r : Ast.type_expr) -> unify_at span answer (infer_ty_of_annotation r)) answers)
      bound;
    List.map (fun (label, args, _) -> label, args) bound
  in
  let bindings =
    List.map (fun (name, args, _, _, _, _) -> name, args) clauses @ List.concat_map by_type named
  in
  let seen = Hashtbl.create 4 in
  List.iter
    (fun (label, _) ->
      if Hashtbl.mem seen label then fail span "'%s' is handled twice in this run." (shown_name label);
      Hashtbl.replace seen label ())
    bindings;
  let remaining = List.fold_left (fun row (label, args) -> discharged label args row) body_row bindings in
  Types.unify_row remaining ctx.row;
  List.iter (fun row -> Types.row_within row ctx.row) rows;
  let lowered_prelude =
    lowered_prelude @ fst (check_values named_late)
  in
  body, lowered_prelude

(* Each handler of the run whose every method reads only its parameters and
   names of the top level, and performs nothing, has its methods made
   functions of the top level: its value holds those, and a call the walk can
   name the handler of calls one directly. *)
and lifted env span clauses (prelude : checked_stmt list) : checked_stmt list =
  let local = runtime_names env in
  let reads_only_globals (m : (Ast.stmt, unit) Ast.method_def) =
    let fn = Ast.at span (`Fn ("", m.Ast.md_params, plain_signature, m.Ast.md_body)) in
    List.for_all
      (function
        | Value n -> not (List.mem n local)
        | Member _ -> true)
      (names_used fn)
  in
  let liftable_value = Hashtbl.create 4 in
  List.iter
    (fun (name, _, _, defs, handler, value) ->
      match value with
      | Some hv
        when evidence_passed name
             && defs <> []
             && (not (Hashtbl.mem reading_handlers handler))
             && List.for_all reads_only_globals defs ->
        Hashtbl.replace liftable_value hv handler
      | _ -> ())
    clauses;
  let pure (t : Types.infer_ty) =
    match Types.repr t with
    | Types.IFn (_, _, row) -> fst (Types.labels_of_infer_row row) = [] && Types.free_vars t = []
    | _ -> false
  in
  List.map
    (fun (s : checked_stmt) ->
      match s.Ast.it with
      | `Var_decl (hv, ty, Some ({ Ast.it = `Record_lit fields; _ } as record))
        when Hashtbl.mem liftable_value hv
             && List.for_all
                  (fun (_, (e : checked_expr)) ->
                    match e.Ast.it with
                    | `Lambda _ -> pure e.Ast.ann
                    | _ -> false)
                  fields ->
        let handler = Hashtbl.find liftable_value hv in
        let fields =
          List.map
            (fun (short, (e : checked_expr)) ->
              match e.Ast.it with
              | `Lambda (params, signature, body) ->
                let fn = handler ^ "#" ^ short in
                let lifted = Ast.annotated e.Ast.span e.Ast.ann (`Fn (fn, params, signature, body)) in
                Hashtbl.replace lifted_checked fn lifted;
                (ops ()).lift fn lifted;
                Hashtbl.replace lifted_methods (handler, short) (fn, e.Ast.ann);
                short, Ast.annotated e.Ast.span e.Ast.ann (`Var fn)
              | _ -> short, e)
            fields
        in
        Hashtbl.replace lifted_handlers handler ();
        { s with Ast.it = `Var_decl (hv, ty, Some { record with Ast.it = `Record_lit fields }) }
      | _ -> s)
    prelude

(* A run's own handler value, checked against its signature where it has one;
   what it performs where its methods take control is the row returned. *)
and run_value env ctx assigned handler (s : Ast.stmt) : checked_stmt list * Types.infer_row option =
  match s.Ast.it, Hashtbl.find_opt handler_signatures handler with
  | `Var_decl (name, None, Some ({ Ast.it = `Record_lit fields; _ } as init)), Some signature ->
    let ty, rho, owns = signature () in
    let arity (e : Ast.expr) =
      match e.Ast.it with
      | `Lambda (params, sg, _) -> Some (List.length params, is_handed_method sg)
      | _ -> None
    in
    let declared =
      match Types.repr ty with
      | Types.IRecord f -> f
      | _ -> Types.FEmpty
    in
    let made_shape method_name =
      match Hashtbl.find_opt handler_labels handler with
      | Some label ->
        (match Hashtbl.find_opt ctx_effects.ops (Ast.operation_name label method_name) with
         | Some o -> method_shape o
         | None -> Core.handed_method)
      | None -> Core.handed_method
    in
    let rec field_of l (f : Types.infer_fields) =
      match Types.repr_fields f with
      | Types.FCons (l', t, _) when String.equal l l' -> Some t
      | Types.FCons (_, _, rest) -> field_of l rest
      | _ -> None
    in
    let expected =
      Types.IRecord
        (List.fold_right
           (fun (l, e) rest ->
             let t =
               match field_of l declared, arity e with
               | Some t, Some (n, made) ->
                 (match Types.repr t with
                  | Types.IFn (ps, r, row) when made ->
                    let handed = handed_params (made_shape l) ~result:r ~answer:r ~row in
                    if List.length ps + List.length handed = n then Types.IFn (ps @ handed, r, row) else Types.fresh ()
                  | Types.IFn (ps, _, _) when List.length ps = n -> t
                  | _ -> Types.fresh ())
               | _ -> Types.fresh ()
             in
             Types.FCons (l, t, rest))
           fields
           Types.FEmpty)
    in
    let checked = infer_expr ~expected env ctx init in
    unify_at s.Ast.span expected checked.Ast.ann;
    (try List.iter (fun (arm, own) -> own_params_unsettled env own arm) owns with
     | Types.Type_error message -> raise (Located { span = s.Ast.span; message }));
    Hashtbl.replace handler_values handler checked.Ast.ann;
    bind env name (Types.mono checked.Ast.ann);
    [ Ast.annotated s.Ast.span Types.IUnit (`Var_decl (name, None, Some checked)) ], Some rho
  | _ -> bound_value env ctx assigned handler s, None

(* What `EffectHandler<E, R>` says of each method a handler defines: one that
   takes control is handed its continuation last, `(A) -> <ρ> R`, and performs
   ρ, one row for every such method of the handler. An operation's own
   parameters are each call's own. *)
and handler_signature span ~answer ~shapes label args (ops : Ast.op_decl list) defs =
  let op_of (m : (Ast.stmt, unit) Ast.method_def) =
    List.find_opt
      (fun (o : Ast.op_decl) -> String.equal o.Ast.op_name (Ast.operation_name label m.Ast.md_name))
      ops
  in
  List.iter
    (fun (o : Ast.op_decl) ->
      if not
           (List.exists
              (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                String.equal o.Ast.op_name (Ast.operation_name label m.Ast.md_name))
              defs)
      then
        fail span "This handler for '%s' is missing method '%s'." (shown_name label) (shown_name o.Ast.op_name))
    ops;
  let names = List.map fst (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params label)) in
  let rho = Types.fresh_row () in
  Types.declare_row rho;
  let owns = ref [] in
  let field (m : (Ast.stmt, unit) Ast.method_def) =
    let op =
      match op_of m with
      | Some op -> op
      | None -> fail span "Trait '%s' has no method '%s'." (shown_name label) m.Ast.md_name
    in
    let own =
      List.map
        (fun name ->
          let var = Types.fresh () in
          Types.declare_param var;
          name, var)
        op.Ast.op_tparams
    in
    owns := (m.Ast.md_name, own) :: !owns;
    with_type_params own (fun () ->
      let takes_control = op.Ast.op_kind <> Ast.Op_fn in
      let shape =
        Option.bind
          shapes
          (List.find_opt (fun (sg : Ast.method_sig) -> String.equal sg.Ast.ms_name m.Ast.md_name))
      in
      let expected, returns =
        match shape with
        | Some sg ->
          let rows =
            List.filter_map
              (fun (p : Ast.static_param) ->
                if List.mem p.Ast.sp_name op.Ast.op_tparams then None else Some (p.Ast.sp_name, Types.IRow rho))
              sg.Ast.ms_signature.Ast.static_params
          in
          with_type_params (("R", answer) :: rows) (fun () ->
            ( List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) sg.Ast.ms_params
            , annotated_or_fresh sg.Ast.ms_signature.Ast.ret ))
        | None ->
          let params = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) op.Ast.op_params in
          let result = annotated_or_fresh op.Ast.op_ret in
          if Ast.aborts op.Ast.op_attrs
          then params, answer
          else if takes_control
          then params @ [ Types.IFn ([ result ], answer, rho) ], answer
          else params, result
      in
      if List.length expected <> List.length m.Ast.md_params
      then
        fail
          span
          "'%s' takes %d parameter(s) in this handler, but %d are written."
          m.Ast.md_name
          (List.length expected)
          (List.length m.Ast.md_params);
      List.iter2
        (fun (p : Ast.param) ty ->
          Option.iter (fun written -> unify_at span ty (infer_ty_of_annotation written)) p.Ast.ty)
        m.Ast.md_params
        expected;
      Option.iter
        (fun written -> unify_at span returns (infer_ty_of_annotation written))
        m.Ast.md_signature.Ast.ret;
      m.Ast.md_name, Types.IFn (expected, returns, if takes_control then rho else Types.fresh_row ()))
  in
  let fields =
    with_type_params
      (try List.combine names args with
       | Invalid_argument _ -> [])
      (fun () -> List.map field defs)
  in
  ( Types.IRecord (List.fold_right (fun (m, t) rest -> Types.FCons (m, t, rest)) fields Types.FEmpty)
  , rho
  , !owns )

(* The run's fixed meaning: its body quoted and handed to the library's
   transform with each handler's value, and what that generates checked where
   the body stands. *)
and transformed env ctx span (body : (Ast.expr, Ast.stmt) Ast.valued_block) handled (shell : Ast.expr) : Ast.expr =
  let at it : Ast.expr = Ast.at span it in
  let value =
    match body.Ast.vb_value with
    | None -> at (`New_variant (Core.option, "None", Ast.P_none))
    | Some v -> at (`New_variant (Core.option, "Some", Ast.P_tuple [ at (`Code v) ]))
  in
  let call =
    at
      (`Call
        ( at (`Var Core.effect_transform)
        , [ at (`Code_stmts body.Ast.vb_stmts)
          ; value
          ; at (`Collection_lit (List.map (fun label -> at (`Name label)) handled))
          ; at (`Code shell)
          ] ))
  in
  let meta = at (`Meta_expr [ Ast.at span (`Gen (Ast.at span (`Expr call))) ]) in
  in_scope env ctx (fun () -> (ops ()).meta_expr (runtime_names env) (reflected_type env ctx) meta)

(* A function value whose type takes control, made by the library's
   transform. *)
and converted env ctx (lambda : Ast.expr) taken : Ast.expr =
  let span = lambda.Ast.span in
  let at it : Ast.expr = Ast.at span it in
  let labels = at (`Collection_lit (List.map (fun label -> at (`Name label)) taken)) in
  let call = at (`Call (at (`Var Core.effect_lambda), [ at (`Code lambda); labels ])) in
  let meta = at (`Meta_expr [ Ast.at span (`Gen (Ast.at span (`Expr call))) ]) in
  in_scope env ctx (fun () -> (ops ()).meta_expr (runtime_names env) (reflected_type env ctx) meta)

(* A function value a transform made taking more than its type shows: its
   type is what it was written as, the parameters before the handlers, and
   what the last parameters, those [Core.handed] lists, are handed. Its
   written row says which handlers. *)
and handed_lambda ?expected ?(at_root = false) env ctx span params (signature : Ast.signature) body : checked_expr =
  let written = Option.value ~default:[] signature.Ast.row in
  let row = row_of_labels ~span written in
  let labels = fst (Types.labels_of_infer_row row) in
  let taken = controlling_row row in
  let extra = handed_count Core.handed in
  let count = List.length params - List.length taken - extra in
  if count < 0 then fail span "A function made taking control has too few parameters.";
  let surface = List.filteri (fun i _ -> i < count) params in
  let param_types = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) surface in
  let ret = Types.fresh () in
  (match Option.map Types.repr expected with
   | Some (Types.IFn (wanted, wanted_ret, _)) ->
     let wanted = Types.expand wanted in
     let hint ty want =
       try Types.unify ty want with
       | Types.Type_error _ -> ()
     in
     if List.length wanted = List.length param_types then List.iter2 hint param_types wanted;
     hint ret wanted_ret
   | _ -> ());
  (* One the transform made for itself answers what the function value taking
     control it stands in does, so what it is handed can be kept where that
     one's is. *)
  let answer =
    match ctx.handed_answer with
    | Some t when is_plain signature -> t
    | _ ->
      let a = Types.fresh () in
      Types.declare_param a;
      a
  in
  let scope = new_env (Some env) in
  List.iter2 (fun (p : Ast.param) ty -> bind scope p.Ast.name (Types.mono ty)) surface param_types;
  let handlers =
    List.map
      (fun label ->
        let args = Option.value ~default:[] (List.assoc_opt label labels) in
        let ty = handler_type label args in
        bind scope (handler_param label) (Types.mono ty);
        param_binding label ty)
      taken
  in
  let handed = List.filteri (fun i _ -> i >= List.length params - extra) params in
  let handed_types = handed_params Core.handed ~result:ret ~answer ~row:(Types.fresh_row ()) in
  (* Their own rows declared, as a copy's are: each continuation of the body
     calling one would otherwise be unified with its row, and so with each
     other, and the first key closing one closes them all, before a later one
     performs what it still has to. *)
  let shown = Types.free_row_vars ret @ Types.free_row_vars answer in
  List.iter
    (fun t ->
      List.iter
        (fun id -> if not (List.mem id shown) then Hashtbl.replace Types.declared_row_params id ())
        (Types.free_row_vars t))
    handed_types;
  List.iter2 (fun (p : Ast.param) t -> bind scope p.Ast.name (Types.mono t)) handed handed_types;
  let own = Types.fresh_row () in
  let outer = !effect_bindings in
  (* The root's, or a top-level statement's under its catcher, which binds
     only what the transform answers: what nothing nearer binds is the root's,
     as it was where the statement was first checked. *)
  effect_bindings
  := handlers
     @
     if is_plain signature then outer else if at_root then root_frame :: outer else own_frame :: outer;
  let checked =
    Fun.protect
      ~finally:(fun () -> effect_bindings := outer)
      (fun () -> in_function_body ~handed:answer ctx ~ret:answer ~row:own (fun () -> infer_block scope ctx body))
  in
  if is_plain signature then Types.row_within own ctx.row;
  Ast.annotated span (Types.IFn (param_types, ret, row)) (`Lambda (params, signature, checked))

(* An inline handler's value, as the declaration a bound run holds: a record
   of its methods as lambdas. A parameter takes the type the operation writes
   for it unless that names a parameter only the trait can settle; the
   continuation's is left to the calls that hand one. *)
and handler_record span value label (ops : Ast.op_decl list) defs : Ast.stmt =
  let params = List.map fst (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params label)) in
  let field (m : (Ast.stmt, unit) Ast.method_def) =
    let op =
      List.find_opt
        (fun (o : Ast.op_decl) -> String.equal o.Ast.op_name (Ast.operation_name label m.Ast.md_name))
        ops
    in
    let control = Option.fold ~none:false ~some:(fun (o : Ast.op_decl) -> o.Ast.op_kind <> Ast.Op_fn) op in
    let count = List.length m.Ast.md_params in
    let declared i =
      match op with
      | Some o ->
        (match List.nth_opt o.Ast.op_params i with
         | Some { Ast.ty = Some t; _ }
           when not (List.exists (fun n -> Ast.mentions n t) (params @ o.Ast.op_tparams)) -> Some t
         | _ -> None)
      | None -> None
    in
    let param i (p : Ast.param) =
      if control && i = count - 1
      then (
        let k = { p with Ast.ty = None } in
        if not (Option.fold ~none:false ~some:(fun (o : Ast.op_decl) -> Ast.aborts o.Ast.op_attrs) op)
        then note_continuation_param k;
        k)
      else (
        match p.Ast.ty with
        | Some _ -> p
        | None -> { p with Ast.ty = declared i })
    in
    let lambda =
      Ast.at
        span
        (`Lambda
          ( List.mapi param m.Ast.md_params
          , { plain_signature with Ast.inline = m.Ast.md_signature.Ast.inline }
          , m.Ast.md_body ))
    in
    if Option.is_some op && not control then Physical.replace plain_arms lambda m.Ast.md_name;
    m.Ast.md_name, lambda
  in
  Ast.at span (`Var_decl (value, None, Some (Ast.at span (`Record_lit (List.map field defs)))))

and handle_block
      env
      ctx
      assigned
      span
      ~answer
      ~resumes
      ~pass
      label
      args
      (ops : Ast.op_decl list)
      defs
  : unit
  =
  let op_of (m : (Ast.stmt, unit) Ast.method_def) =
    List.find_opt
      (fun (o : Ast.op_decl) -> String.equal o.Ast.op_name (Ast.operation_name label m.Ast.md_name))
      ops
  in
  let written = defs in
  let defs =
    List.filter
      (fun m ->
        match pass, op_of m with
        | `All, _ | `Unmarked, None -> true
        | `Unmarked, Some o -> o.Ast.op_kind = Ast.Op_fn
        | `Ctl, Some o -> o.Ast.op_kind <> Ast.Op_fn
        | `Ctl, None -> false)
      defs
  in
  if pass <> `Ctl
  then
  List.iter
    (fun (o : Ast.op_decl) ->
      if not
           (List.exists
              (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                String.equal o.Ast.op_name (Ast.operation_name label m.Ast.md_name))
              written)
      then
        fail
          span
          "This handler for '%s' is missing method '%s'."
          (shown_name label)
          (shown_name o.Ast.op_name))
    ops;
  let names =
    List.map fst (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params label))
  in
  let arm (m : (Ast.stmt, unit) Ast.method_def) =
    let op =
      match op_of m with
      | Some op -> op
      | None -> fail span "Trait '%s' has no method '%s'." (shown_name label) m.Ast.md_name
    in
    let own =
      List.map
        (fun name ->
          let var = Types.fresh () in
          Types.declare_param var;
          name, var)
        op.Ast.op_tparams
    in
    with_type_params own (fun () ->
      let params = List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) op.Ast.op_params in
      let result = annotated_or_fresh op.Ast.op_ret in
      let takes_control = op.Ast.op_kind <> Ast.Op_fn in
      let expected, returns =
        if Ast.aborts op.Ast.op_attrs
        then params, answer
        else if takes_control
        then params @ [ Types.IFn ([ result ], answer, resumes) ], answer
        else params, result
      in
      if List.length expected <> List.length m.Ast.md_params
      then
        fail
          span
          "'%s' takes %d parameter(s) in this handler, but %d are written."
          m.Ast.md_name
          (List.length expected)
          (List.length m.Ast.md_params);
      if takes_control && not (Ast.aborts op.Ast.op_attrs)
      then Option.iter note_continuation_param (List.nth_opt (List.rev m.Ast.md_params) 0);
      let scope = new_env (Some env) in
      List.iter2
        (fun (p : Ast.param) ty ->
          Option.iter (fun written -> unify_at span ty (infer_ty_of_annotation written)) p.Ast.ty;
          bind_param scope p ty)
        m.Ast.md_params
        expected;
      Option.iter
        (fun written -> unify_at span returns (infer_ty_of_annotation written))
        m.Ast.md_signature.Ast.ret;
      let around = ctx.row in
      let own_row = if takes_control then around else Types.fresh_row () in
      let body =
        in_ctx
          ctx
          ~set:(fun () ->
            ctx.row <- own_row;
            ctx.return_type <- Some returns;
            ctx.saw_return <- false)
          (fun () ->
            let body =
              List.concat_map
                (fun s -> statement ctx (fun () -> infer_stmt scope ctx assigned s))
                m.Ast.md_body
            in
            if not ctx.saw_return then unify_at span returns Types.IUnit;
            body)
      in
      ignore body;
      (match if takes_control then [] else controlling_row own_row with
       | [] -> ()
       | taken :: _ ->
         plain_arm_controls span m.Ast.md_name taken);
      if not takes_control then Types.row_within own_row around;
      own_params_unsettled env own m.Ast.md_name)
  in
  with_type_params
    (try List.combine names args with
     | Invalid_argument _ -> [])
    (fun () ->
      List.iter arm defs)

(* One arm serves every instantiation of the operation, so its own parameters
   must stay what they were made: free, and free of the enclosing scope. *)
and own_params_unsettled env own arm_name =
  (* Tied to a variable outside the arm is settled too, only later: whatever
     that variable becomes, every call site would be held to it. *)
  let outer_types, outer_rows, _ = env_free_all env in
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
             arm_name
       | settled ->
         Types.error
           "This handler settles '%s' at %s, but '%s' is handled once for every \
            type its call sites use."
           name
           (Types.string_of_infer_ty settled)
           arm_name);
      match Types.repr_row (row_of_param var) with
      | Types.RVar { contents = Types.RUnbound id } ->
        if List.mem id outer_rows
        then
          Types.error
            "This handler ties '%s' to a row from outside it, but '%s' is handled \
             once for every row its call sites use."
            name
            arm_name
      | settled ->
        Types.error
          "This handler settles '%s' at <%s>, but '%s' is handled once for every \
           row its call sites use."
          name
          (Types.string_of_infer_row settled)
          arm_name)
    own

let () =
  controlled_slot
  := fun registry span entry ->
       match !top_env with
       | None -> fail span "A method that takes control has no table slot here."
       | Some env ->
         let arity =
           match decl_of env entry with
           | Some d -> List.length d.wd_params
           | None -> fail span "'%s' has no method to put in a table." (shown_name entry)
         in
         let at it : Ast.expr = Ast.at span it in
         let names = List.init arity (fun i -> Ast.generated [ "arg"; string_of_int i ]) in
         let lambda =
           at
             (`Lambda
               ( List.map (fun n -> { Ast.name = n; ty = None; implicit = false }) names
               , { Ast.ret = None; row = None; static_params = []; inline = false }
               , [ Ast.at span (`Return (Some (at (`Call (at (`Var entry), List.map (fun n -> at (`Var n)) names))))) ] ))
         in
         let ctx = { registry; return_type = None; saw_return = false; row = Types.fresh_row (); hoisted = []; handed_answer = None } in
         infer_expr env ctx lambda

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
let satisfies ?(holds = fun _ _ -> true) name (args : Types.infer_ty list) (b : Types.bound) =
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
     is unified for good: `Add<Int>` tried first would otherwise fix the
     argument to `Int` before `Add<V>` is reached. *)
  (match
     List.find_opt
       (fun declared -> Types.retracting (fun () -> fits declared))
       (Hashtbl.find_all ctx_impls (name, b.Types.bd_trait))
   with
   | Some declared ->
     fits declared
     && List.for_all
          (fun (position, bound) -> match List.nth_opt args position with Some arg -> holds bound arg | None -> true)
          (match
             List.find_opt (fun (d, _) -> d == declared) (Hashtbl.find_all ctx_impl_bounds (name, b.Types.bd_trait))
           with
           | Some (_, bounds) -> bounds
           | None -> [])
   | None -> false)
  || !current.unknown (fun () -> false) (fun () -> true)

let rec admits registry kind (t : Types.infer_ty) =
  match kind with
  (* No value has it, so nothing it is bounded by is ever called. *)
  | Types.Bound _ when Types.is_absent t -> true
  (* Its parts are written through `debug`, which takes any type. *)
  | Types.Bound traits
    when List.for_all (fun (b : Types.bound) -> is_printing b.Types.bd_trait) traits
         && Option.is_some (structural_parts t) -> true
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
               (fun () ->
                 let args =
                   match Types.repr t with
                   | Types.INamed (_, args) | Types.ISum (_, args) -> args
                   | _ -> []
                 in
                 let holds bound arg =
                   admits registry (Types.Bound [ { Types.bd_trait = bound; bd_args = []; bd_bindings = [] } ]) arg
                 in
                 satisfies ~holds name args b)))
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
    (fun (name, signature) ->
      let body = signature () in
      bind
        env
        name
        { Types.quantified = List.map fst (Types.free_vars body)
        ; quantified_rows = Types.free_row_vars body
        ; quantified_fields = []
        ; body
        })
    Builtins.effectful;
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
    Builtins.variadic;
  builtin_discontinue := lookup env "discontinue"

module Session = struct
  type t =
    { env : env
    ; ctx : ctx
    ; errors : error list ref
    }

  let start ~registry =
    Types.counter := 0;
    Types.reset ();
    Hashtbl.reset Types.declarations;
    Hashtbl.reset Types.row_params;
    unknowns := [];
    erroneous := [];
    Hashtbl.reset local_type_home;
    active_blocks := [];
    local_instances := [];
    Hashtbl.reset root_failed;
    Hashtbl.reset unobservable;
    Types.extra_admits := admits registry;
    Types.assoc_binding := (fun owner member -> Hashtbl.find_opt ctx_assoc (owner, member));
    reset_effects ();
    deferred_rows := [];
    pending_calls := [];
    Hashtbl.reset unchecked;
    made_rows := [];
    Hashtbl.reset trait_instances;
    Hashtbl.reset ctx_variadic_arity;
    let env = new_env None in
    declare_builtins env;
    declare_builtin_impls registry;
    let ctx =
      { registry
      ; return_type = None
      ; saw_return = false
      ; handed_answer = None
      ; row = Types.fresh_row ()
      ; hoisted = []
      }
    in
    top_row := Some ctx.row;
    Hashtbl.reset effect_sites;
    Hashtbl.reset escaping_sites;
    let errors = ref [] in
    root_errors := errors;
    { env; ctx; errors }

  let declare session (program : Ast.stmt list) =
    gather program;
    let program = List.map unattributed program in
    (* Per statement: everything after a bad declaration would otherwise be
       checked without the signatures it needs. *)
    let each pass =
      List.iter
        (fun s ->
          try pass [ s ] with
          | Located e -> session.errors := e :: !(session.errors))
        program
    in
    each declare_traits;
    each declare_effects;
    each declare_type_names;
    each declare_type_bodies;
    each (declare_impls session.ctx.registry);
    each check_supertraits;
    (* A handler in another module may be checked before the trait's own
       statement is, so its operations are known from the start. What is wrong
       with them is reported once, by that statement. *)
    each (List.iter (fun (s : Ast.stmt) ->
      match s.Ast.it with
      | `Trait_decl (name, params, body) when Ast.is_effect body ->
        (try declare_operations session.env s.Ast.span name params (operations_of s.Ast.span name body) with
         | Located _ -> ())
      | _ -> ()));
    (* A function whose signature does not read is still declared, as
       something unknown: a call to it is not a second error. *)
    List.iter
      (fun s ->
        try hoist session.env [ s ] with
        | Located e ->
          session.errors := e :: !(session.errors);
          if walking ()
          then
            List.iter
              (function
                | Value name -> bind session.env name (Types.mono (erroneous_ty ()))
                | Member _ -> ())
              (names_declared s))
      program

  let infer session (program : Ast.stmt list) =
    let program = List.map unattributed program in
    let assigned = assigned_names program in
    let attempt check =
      try Some (check ()) with
      | Located e ->
        session.errors := e :: !(session.errors);
        None
    in
    ignore (infer_in_order session.env session.ctx assigned ~attempt program)

  let errors session : error list =
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
          session.errors
          := { span = d.d_span
             ; message =
                 Printf.sprintf
                   "A deferred statement cannot fail, and this one can: '%s' never resumes, \
                    and would replace whatever is already unwinding. Handle it inside the \
                    'defer'."
                   (Types.entry Types.string_of_ty entry)
             }
             :: !(session.errors)
        | [] when d.d_open ->
          session.errors
          := { span = d.d_span
             ; message =
                 "A deferred statement cannot fail, and this one calls through an effect \
                  row its caller decides, which could hold an operation that never resumes."
             }
             :: !(session.errors)
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
        !(session.errors)
        (Types.resolve_row session.ctx.row).Types.labels
    in
    List.rev errors
end

(* What the walk checks a key's instance with: each static parameter bound to
   what the key settled, the rest as [hoist] read them. *)
let with_key_params (assoc : (string * Types.infer_ty) list) f =
  let saved =
    List.map
      (fun (name, _) ->
        name, Hashtbl.find_opt ctx_type_params name, Hashtbl.find_opt ctx_row_params name)
      assoc
  in
  List.iter
    (fun (name, ty) ->
      Hashtbl.replace ctx_type_params name ty;
      match ty with
      | Types.IRow row -> Hashtbl.replace ctx_row_params name row
      | _ -> Hashtbl.remove ctx_row_params name)
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

let rec close_tail (r : Types.infer_row) =
  match Types.repr_row r with
  | Types.RVar { contents = Types.RUnbound _ } -> Types.unify_row r Types.REmpty
  | Types.RCons (_, _, rest) -> close_tail rest
  | _ -> ()

(* [started] hears the signature before the body is read, so a call the body
   makes back into it finds what was written. *)
let check_instance ?home ~registry (d : walk_decl) (key : Key.t) ~name ~(body : Ast.stmt list) ~started
  : checked_stmt
  =
  let generics = Hashtbl.create 4 in
  let rec of_key (t : Types.ty) : Types.infer_ty =
    match t with
    | Types.Generic id ->
      (match Hashtbl.find_opt generics id with
       | Some var -> var
       | None ->
         let var = Types.fresh () in
         Types.declare_param var;
         Hashtbl.replace generics id var;
         var)
    | Types.Tuple ts -> Types.ITuple (List.map of_key ts)
    | Types.Pack ts -> Types.IPack (List.map of_key ts)
    | Types.Spread t -> Types.ISpread (of_key t)
    | Types.Named (n, ts) -> Types.INamed (n, List.map of_key ts)
    | Types.Sum (n, ts) -> Types.ISum (n, List.map of_key ts)
    | Types.Fn (ps, r, row) -> Types.IFn (List.map of_key ps, of_key r, of_key_row row)
    | Types.Row row -> Types.IRow (of_key_row row)
    | t -> Types.of_ty t
  and of_key_row (row : Types.row) =
    List.fold_right
      (fun (l, args) rest -> Types.RCons (l, List.map of_key args, rest))
      row.Types.labels
      Types.REmpty
  in
  let assoc =
    List.map
      (fun (param, var) ->
        match List.assoc_opt param key with
        | Some (Key.Type t) -> param, of_key t
        | Some (Key.Row r) -> param, Types.IRow (of_key_row r)
        | _ -> param, var)
      d.wd_vars
  in
  with_key_params assoc (fun () ->
    let params = d.wd_params in
    let param_types =
      match d.wd_impl, params with
      | Some (_, type_name, impl_params), { Ast.name = "self"; _ } :: rest ->
        self_ty d.wd_span type_name (List.map (fun (p : Ast.type_param) -> p.Ast.tp_name) impl_params)
        :: List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) rest
      | _ -> List.map (fun (p : Ast.param) -> annotated_or_fresh p.Ast.ty) params
    in
    (* A copy a transform made takes the handlers of the effects it splits at. *)
    let handed =
      List.filter_map
        (fun (p : Ast.param) -> Option.map (fun label -> p.Ast.name, label) (handled_by p.Ast.name))
        params
    in
    (* Read through its methods in the body, while a caller hands any value
       of a handler of that effect. *)
    let ret = annotated_or_fresh d.wd_sig.Ast.ret in
    let row =
      match d.wd_sig.Ast.row with
      | Some labels -> row_of_labels ~span:d.wd_span labels
      | None -> Types.fresh_row ()
    in
    let read_as =
      List.map2
        (fun (p : Ast.param) ty ->
          match List.assoc_opt p.Ast.name handed with
          | Some label when Option.is_none p.Ast.ty ->
            (* Any handler of the effect, at whatever arguments it is handed:
               the body's reading of them is the copy's own, as a parametric
               instance's parameters are. *)
            let args =
              List.map
                (fun _ ->
                  let v = Types.fresh () in
                  Types.declare_param v;
                  v)
                (Option.value ~default:[] (Hashtbl.find_opt ctx_effect_params label))
            in
            handler_type label args
          | _ -> ty)
        params
        param_types
    in
    let fn_type = Types.IFn (param_types, ret, row) in
    started fn_type (Option.is_some d.wd_sig.Ast.ret);
    let ctx =
      { registry
      ; return_type = None
      ; saw_return = false
      ; handed_answer = None
      ; row = Types.fresh_row ()
      ; hoisted = []
      }
    in
    let scope = new_env (Some (Option.value ~default:d.wd_env home)) in
    List.iter2 (bind_param scope) params read_as;
    let saved = !open_defer, !pending_values, !walk_locals in
    let outer_instance = !checking_instance in
    checking_instance := Some name;
    let outer_bindings = !effect_bindings in
    if not (is_plain d.wd_sig) then effect_bindings := key_frames key;
    let outer_root_param = !root_param in
    if Ast.is_program_root d.wd_name
    then root_param := Option.map (fun (p : Ast.param) -> p.Ast.name) (List.nth_opt params 0);
    let used = Hashtbl.create 4 in
    keyed_used := used :: !keyed_used;
    let plain = is_plain d.wd_sig in
    if plain then incr in_plain;
    let walking = Option.value ~default:[] (Hashtbl.find_opt walking_keys d.wd_id) in
    Hashtbl.replace walking_keys d.wd_id (key :: walking);
    List.iter2
      (fun (p : Ast.param) ty ->
        match List.assoc_opt p.Ast.name handed with
        | Some label -> effect_bindings := param_binding label ty :: !effect_bindings
        | None -> ())
      params
      read_as;
    let outer_bounds = !bound_traits in
    bound_traits
    := List.concat_map
         (fun (_, var) ->
           match Types.repr var with
           | Types.IVar { contents = Types.Unbound (_, Types.Bound bounds) } ->
             List.concat_map
               (fun (b : Types.bound) ->
                 let targets =
                   List.map
                     (fun arg ->
                       match Types.repr arg with
                       | Types.IVar _ ->
                         (match List.find_opt (fun (_, v) -> v == arg) d.wd_vars with
                          | Some (name, _) ->
                            (match List.assoc_opt name assoc with
                             | Some t -> Types.infer_type_name t
                             | None -> None)
                          | None -> None)
                       | t -> Types.infer_type_name t)
                     b.Types.bd_args
                 in
                 ( b.Types.bd_trait
                 , if List.for_all Option.is_some targets
                   then Some (List.map Option.get targets)
                   else None )
                 :: List.map (fun t -> t, None) (List.tl (List.rev (trait_closure b.Types.bd_trait))))
               bounds
           | _ -> [])
         d.wd_vars;
    open_defer := None;
    pending_values := [];
    walk_locals := [];
    let body =
      Fun.protect
        ~finally:(fun () ->
          let defer, pending, locals = saved in
          checking_instance := outer_instance;
          keyed_used := List.tl !keyed_used;
          root_param := outer_root_param;
          if plain then decr in_plain;
          if walking = [] then Hashtbl.remove walking_keys d.wd_id else Hashtbl.replace walking_keys d.wd_id walking;
          effect_bindings := outer_bindings;
          bound_traits := outer_bounds;
          open_defer := defer;
          pending_values := pending;
          walk_locals := locals)
        (fun () -> in_function_body ctx ~ret ~row (fun () -> infer_block scope ctx body))
    in
    (let typed = without_handlers key in
     let answered =
       List.map fst (fst (Types.labels_of_infer_row row)) @ Hashtbl.fold (fun l () acc -> l :: acc) used []
     in
     let shown = Key.show typed in
     if not (Hashtbl.mem answered_labels (d.wd_id, shown))
     then Hashtbl.replace answered_labels (d.wd_id, shown) answered;
     let kept = narrowed answered (key_handlers key) in
     let narrow = typed @ List.map (fun (l, h) -> l, Key.Handler h) kept in
     if Key.show narrow <> Key.show key then Hashtbl.replace handler_alias (d.wd_id, Key.show narrow) key);
    (* A value is printed inside another value's impl, and `str` declares no
       row, so an effect performed here would have nothing to handle it. *)
    (match d.wd_impl with
     | Some (Some (t, _), _, _) when String.equal t Core.display || String.equal t Core.debug ->
       (match fst (Types.labels_of_infer_row row) with
        | [] -> ()
        | (label, _) :: _ ->
          fail
            d.wd_span
            "'%s' in this impl performs '%s', and a value is printed by calling it wherever \
             the value is written, where nothing handles an effect."
            (shown_name d.wd_name)
            label)
     | _ -> ());
    Ast.annotated
      d.wd_span
      (Types.IFn (param_types, ret, row))
      (`Fn (name, params, plain_only d.wd_sig, body)))

let rec holds_generic (t : Types.ty) =
  let row (r : Types.row) = List.exists (fun (_, args) -> List.exists holds_generic args) r.Types.labels in
  match t with
  | Types.Generic _ -> true
  | Types.Tuple ts | Types.Pack ts | Types.Named (_, ts) | Types.Sum (_, ts) -> List.exists holds_generic ts
  | Types.Spread t -> holds_generic t
  | Types.Record fields -> List.exists (fun (_, t) -> holds_generic t) fields
  | Types.Fn (ps, r, rw) -> List.exists holds_generic ps || holds_generic r || row rw
  | Types.Row r -> row r
  | Types.Int | Types.Float | Types.Str | Types.Byte | Types.Chr | Types.Bool | Types.Unit -> false

(* Code a meta block asks about, checked where the block stands, and the type
   each expression was given there; [None] where no checked code surrounds the
   block.
   Nothing it reaches counts as a use and nothing it hoists is kept, since what
   the block generates from it is checked again. A type inference left open is
   not answered. *)
let typed_here (check : env -> ctx -> unit)
  : ((Ast.expr -> Types.ty option) * (Ast.expr -> Ast.expr option)) option
  =
  match !meta_scope with
  | None -> None
  | Some (env, ctx) ->
    let table = ref [] in
    let lowered = ref [] in
    let previous = !recording
    and previous_lowered = !expansions
    and previous_noting = !noting in
    recording := Some table;
    expansions := Some lowered;
    noting := None;
    let scratch = { ctx with row = Types.fresh_row (); hoisted = [] } in
    Fun.protect
      ~finally:(fun () ->
        recording := previous;
        expansions := previous_lowered;
        noting := previous_noting)
      (fun () ->
        ignore
          ((ops ()).unused (fun () ->
             check env scratch;
             Types.IUnit)));
    let types = Physical.create 64 in
    List.iter (fun (e, t) -> Physical.replace types e t) !table;
    let runs = Physical.create 8 in
    List.iter (fun (e, g) -> Physical.replace runs e g) !lowered;
    let found table fallback e =
      match Physical.find_opt table e with
      | Some _ as found -> found
      | None -> Physical.find_opt fallback e
    in
    Some
      ( (fun e ->
          Option.bind (found types noted_types e) (fun t ->
            let t = Types.resolve t in
            (* A function's row says what calling it performs, which is worth
               knowing even where a type in it is still open. *)
            match t with
            | Types.Fn _ -> Some t
            | _ -> if holds_generic t then None else Some t))
      , fun e ->
          match found runs noted_runs e with
          | Some _ as lowered -> lowered
          | None -> Physical.find_opt meta_exprs e )

(* What the block [typed_block] last checked performs, each label at arguments
   it settled. *)
let processed_row : (string * Types.ty list) list ref = ref []

let settled_labels (rows : Types.infer_row list) =
  List.fold_left
    (fun acc (label, args) ->
      let args = List.map Types.resolve args in
      if List.exists holds_generic args || List.mem (label, args) acc then acc else acc @ [ label, args ])
    []
    (List.concat_map (fun r -> fst (Types.labels_of_infer_row r)) rows)

let typed_block (body : (Ast.expr, Ast.stmt) Ast.valued_block) =
  typed_here (fun env ctx ->
    let scope = new_env (Some env) in
    let asking block f =
      let outer = !kept_block in
      kept_block := Some block;
      Fun.protect ~finally:(fun () -> kept_block := outer) f
    in
    ignore (asking body.Ast.vb_stmts (fun () -> infer_block scope ctx body.Ast.vb_stmts));
    Option.iter
      (fun (v : Ast.expr) ->
        match v.Ast.it with
        | `Lambda (_, _, lambda_body) -> ignore (asking lambda_body (fun () -> infer_expr scope ctx v))
        | _ -> ignore (infer_expr scope ctx v))
      body.Ast.vb_value;
    processed_row := settled_labels (ctx.row :: !arm_rows))

(* What the methods that take control of the run being transformed perform. *)
let arms_row () = settled_labels !arm_rows

(* A function's body, checked as the declaration it is: everything it performs
   is answered by the evidence it is handed. *)
let typed_fn name (params : Ast.param list) (sg : Ast.signature) (body : Ast.stmt list) =
  typed_here (fun _ ctx ->
    let scope = new_env !top_env in
    let outer = !effect_bindings in
    effect_bindings
    := (match !declof_shown with
        | Some (shown, key) when String.equal shown name -> key_frames key
        | _ -> [ own_frame ]);
    Fun.protect ~finally:(fun () -> effect_bindings := outer) @@ fun () ->
    (* A copy's own parameters are gone from what declof gives of it, while its
       types still name them: such a type is left to the body. *)
    let read t =
      try annotated_or_fresh t with
      | Located _ | Rejected _ -> Types.fresh ()
    in
    List.iter (fun (p : Ast.param) -> bind scope p.Ast.name (Types.mono (read p.Ast.ty))) params;
    let returns = read sg.Ast.ret in
    in_ctx
      ctx
      ~set:(fun () ->
        ctx.return_type <- Some returns;
        ctx.saw_return <- false)
      (fun () -> ignore (infer_block scope ctx body)))

(* The declaration a callee names and the key its type settles, as the call
   branch reads one: a fresh use of the signature unified with the type, rows
   left out, since what the callee performs is no part of a plain key. *)
let instance_at span ~at name (ty : Ast.type_expr option) : (walk_decl * Key.t) option =
  match !top_env with
  | None -> None
  | Some env ->
    (match decl_of env name with
     | None -> None
     | Some d ->
       let u = use_of d in
       (match ty with
        | Some t ->
          (match Types.repr u.u_ty, infer_ty_of_annotation t with
           | Types.IFn (ps, r, _), Types.IFn (ps', r', _) when List.length ps = List.length ps' ->
             (try
                List.iter2 Types.unify ps ps';
                Types.unify r r'
              with
              | Types.Type_error _ -> ())
           | _ -> ())
        | None -> ());
       (match key_of_use span ~value:false u with
        | derived ->
          (* The call may have named the handlers around it too. *)
          (match Source_map.Span.view at, Hashtbl.find_opt keyed_at (d.wd_name, Source_map.Span.offsets at) with
           | Source_map.Span.Located _, Some (k :: _) when Key.show (without_handlers k) = Key.show derived ->
             Some (d, k)
           | _ -> Some (d, derived))
        | exception (Located _ as unsettled) ->
          (* What the call settled is what the instance was made at. *)
          (match Source_map.Span.view at, Hashtbl.find_opt keyed_at (d.wd_name, Source_map.Span.offsets at) with
           | Source_map.Span.Located _, Some (k :: rest) when List.for_all (fun k' -> Key.show k' = Key.show k) rest ->
             Some (d, k)
           | _ -> raise unsettled)))

(* The type of a record's field at the record's arguments, as written where the
   record's type is. *)
let field_type (t : Ast.type_expr) field : Types.ty option =
  match Types.repr (infer_ty_of_annotation t) with
  | Types.INamed (named, args) ->
    let rec find f =
      match Types.repr_fields f with
      | Types.FCons (l, ty, _) when String.equal l field -> Some (Types.resolve ty)
      | Types.FCons (_, _, rest) -> find rest
      | _ -> None
    in
    (try find (Types.fields_of named args) with
     | Types.Type_error _ | Located _ -> None)
  | _ -> None
  | exception (Types.Type_error _ | Located _) -> None

(* The operation a name stands for: its effect, its method's name, and whether
   it takes control. *)
let operation_of name =
  match Hashtbl.find_opt ctx_effects.ops name, Hashtbl.find_opt ctx_op_owner name with
  | Some op, Some label ->
    Some
      ( label
      , method_of_operation label name
      , op.Ast.op_kind <> Ast.Op_fn
      , Ast.aborts op.Ast.op_attrs
      , List.length op.Ast.op_params )
  | _ -> None

let effect_operations label =
  List.map
    (fun (o : Ast.op_decl) ->
      ( label
      , method_of_operation label o.Ast.op_name
      , o.Ast.op_kind <> Ast.Op_fn
      , Ast.aborts o.Ast.op_attrs
      , List.length o.Ast.op_params ))
    (Option.value ~default:[] (Hashtbl.find_opt ctx_effects.declared label))

(* Whether a name, where the asking meta block stands, is a function the walk
   reaches through an instance rather than a value. *)
let names_function name =
  match !meta_scope, !top_env with
  | Some (env, _), _ | None, Some env -> Option.is_some (decl_of env name)
  | None, None -> false

(* The walk's own session: declarations as [Session] reads them, then each
   root statement checked where it stands. *)
module Walk = struct
  (* The `var`s whose statements failed. A later statement reading one is not
     checked: every error it gave would be the first one again. *)
  let failed : (string, unit) Hashtbl.t = Hashtbl.create 8

  let start ~registry ops =
    let session = Session.start ~registry in
    Hashtbl.reset failed;
    walk_ops := Some ops;
    top_env := Some session.Session.env;
    Hashtbl.reset walk_decls;
    Hashtbl.reset placeholders;
    Hashtbl.reset handler_values;
    Hashtbl.reset handler_shown;
    Hashtbl.reset handler_signatures;
    Hashtbl.reset handler_labels;
    continuations := [];
    Hashtbl.reset used_handlers;
    Hashtbl.reset bound_arguments;
    Hashtbl.reset handler_run;
    Hashtbl.reset keyed_handlers;
    Hashtbl.reset lifted_methods;
    Hashtbl.reset lifted_handlers;
    Hashtbl.reset lifted_checked;
    Hashtbl.reset lifted_processed;
    Hashtbl.reset reading_handlers;
    Hashtbl.reset without_evidence;
    Hashtbl.reset answered_labels;
    Hashtbl.reset handler_alias;
    Hashtbl.reset walking_keys;
    keyed_used := [];
    in_plain := 0;
    root_bindings := None;
    root_param := None;
    declof_shown := None;
    kept_block := None;
    Hashtbl.reset passed;
    Physical.reset noted_types;
    Physical.reset noted_runs;
    Physical.reset meta_exprs;
    Physical_stmt.reset meta_stmts;
    Physical_stmt.reset kept_stmts;
    Hashtbl.reset root_instances;
    root_call := None;
    root_main_bare := false;
    program_root_body := false;
    active_runs := [];
    run_instances := [];
    effect_bindings := [];
    pending_values := [];
    walk_locals := [];
    session

  let stop () =
    walk_ops := None;
    top_env := None

  (* A declaration a meta block generated, as one written there would be. *)
  let declare (session : Session.t) (program : Ast.stmt list) =
    Session.declare session program

  let check (session : Session.t) f =
    try Some (f ()) with
    | Located e ->
      session.Session.errors := e :: !(session.Session.errors);
      None

  let root (session : Session.t) (s : Ast.stmt) : checked_stmt list option =
    let s = unattributed s in
    if List.exists
         (function
           | Value name -> Hashtbl.mem failed name
           | Member _ -> false)
         (names_used s)
    then (
      List.iter
        (function
          | Value name -> Hashtbl.replace failed name ()
          | Member _ -> ())
        (names_declared s);
      None)
    else (
      let checked =
        check session (fun () ->
          statement session.Session.ctx (fun () ->
            with_pending (fun () ->
              infer_stmt session.Session.env session.Session.ctx (assigned_names [ s ]) s)))
      in
      if Option.is_none checked
      then
        List.iter
          (function
            | Value name -> Hashtbl.replace failed name ()
            | Member _ -> ())
          (names_declared s);
      checked)

  (* What a meta block sees: the declarations, and none of the program's
     run-time variables. *)
  (* Not a copy: what the check declares at the top level while the block is
     checked, as the copies a run's transform makes, is reached from it. *)
  let meta_env (session : Session.t) ~hidden =
    { bindings = Hashtbl.create 16; parent = Some session.Session.env; open_names = Hashtbl.create 16; hides = Some hidden }

  (* A statement checked apart from whatever the walk was in the middle of: its
     own row, so nothing the interrupted check was building reaches it. *)
  let isolated (session : Session.t) env (s : Ast.stmt) =
    let ctx =
      { registry = session.Session.ctx.registry
      ; return_type = None
      ; saw_return = false
      ; handed_answer = None
      ; row = Types.fresh_row ()
      ; hoisted = []
      }
    in
    let saved = !top_row, !open_defer, !walk_locals, !bound_traits, !in_loop in
    let runs = !effect_bindings, !active_runs, !keyed_used in
    top_row := Some ctx.row;
    open_defer := None;
    walk_locals := [];
    bound_traits := [];
    in_loop := false;
    effect_bindings := [];
    active_runs := [];
    keyed_used := [];
    Fun.protect
      ~finally:(fun () ->
        let bindings, active, used = runs in
        effect_bindings := bindings;
        active_runs := active;
        keyed_used := used;
        let top, defer, locals, bounds, looping = saved in
        top_row := top;
        open_defer := defer;
        walk_locals := locals;
        bound_traits := bounds;
        in_loop := looping)
      (fun () ->
        let checked =
          statement ctx (fun () ->
            with_pending (fun () -> infer_stmt env ctx (assigned_names [ s ]) s))
        in
        checked, ctx.row)

  let meta (session : Session.t) ~hidden (s : Ast.stmt) : checked_stmt list =
    let saved = !in_meta in
    in_meta := true;
    Fun.protect
      ~finally:(fun () -> in_meta := saved)
      (fun () ->
        let checked, row = isolated session (meta_env session ~hidden) s in
        (match (Types.resolve_row row).Types.labels with
         | entry :: _ ->
           fail
             s.Ast.span
             "Unhandled effect '%s': no handler encloses this."
             (Types.entry Types.string_of_ty entry)
         | [] -> close_tail row);
        checked)

  (* A static argument checked against its parameter's type. *)
  let probe (session : Session.t) ~hidden (s : Ast.stmt) =
    ignore (isolated session (meta_env session ~hidden) s)

  (* A type-level statement emitted as written; an effect's operations are bound
     where it is checked. *)
  let type_level (session : Session.t) (s : Ast.stmt) : checked_stmt list option =
    root session s

  let errors (session : Session.t) = Session.errors session
end

let instance_run (d : walk_decl) (key : Key.t) =
  let answered =
    Option.value ~default:[] (Hashtbl.find_opt answered_labels (d.wd_id, Key.show (without_handlers key)))
  in
  handler_home (List.map (fun (l, h) -> l, Key.Handler h) (narrowed answered (key_handlers key)))

(* A call processed before its callee hands it evidence, since the callee may
   still take some; once the whole program is processed, a callee known to
   take none is handed none. *)
let rec exact_expr (e : Ast.resolved_expr) : Ast.resolved_expr =
  let e =
    match e.Ast.it with
    | `Lambda (params, sg, body) -> { e with Ast.it = `Lambda (params, sg, List.map exact_stmt body) }
    | _ -> Defers.children exact_expr e
  in
  match e.Ast.it with
  | `Call (({ Ast.it = `Var name; ann = Types.Fn (ps, r, { Types.labels = _ :: _; _ }); _ } as callee), args)
    when Hashtbl.mem without_evidence name && List.length args = List.length (Types.expand_ty ps) + 1 ->
    let args = List.filteri (fun i _ -> i < List.length args - 1) args in
    { e with Ast.it = `Call ({ callee with Ast.ann = Types.Fn (ps, r, { Types.labels = []; tail = None }) }, args) }
  | _ -> e

and exact_stmt (s : Ast.resolved_stmt) : Ast.resolved_stmt =
  match s.Ast.it with
  | #Ast.stmts as st -> { s with Ast.it = (Ast.map_stmts exact_expr exact_stmt st :> Ast.resolved_stmt_kind) }
  | `Match (scrutinee, cases) ->
    { s with Ast.it = `Match (exact_expr scrutinee, List.map (fun (p, body) -> p, List.map exact_stmt body) cases) }
  | #Ast.type_defs -> s
