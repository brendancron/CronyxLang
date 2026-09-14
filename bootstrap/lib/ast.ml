type span = Source_map.Span.t

(* A path is shown only when it is not the file the user named, and then
   relative to it. *)
let shown_path ~entry path =
  let root = Filename.dirname entry ^ "/" in
  if String.length path > String.length root
     && String.equal (String.sub path 0 (String.length root)) root
  then String.sub path (String.length root) (String.length path - String.length root)
  else path

let locate ~entry (s : span) =
  match Source_map.Span.view s with
  | Source_map.Span.Nowhere_in_source -> "[unknown]"
  | Source_map.Span.Located l ->
    let path = Source_map.File.path l.Source_map.Span.file in
    if String.equal path entry
    then Printf.sprintf "[%d:%d]" l.Source_map.Span.line l.Source_map.Span.col
    else
      Printf.sprintf
        "[%s %d:%d]"
        (shown_path ~entry path)
        l.Source_map.Span.line
        l.Source_map.Span.col

type ('a, 'ann) node =
  { it : 'a
  ; span : span
  ; ann : 'ann
  }

let at span it = { it; span; ann = () }
let annotated span ann it = { it; span; ann }

type unop =
  | Neg (* - *)
  | Not (* ! *)

type binop =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | Equal
  | Not_equal
  | Less
  | Less_equal
  | Greater
  | Greater_equal

type type_expr = (type_expr_kind, unit) node

and type_expr_kind =
  | Ty_name of string
  | Ty_app of string * type_expr list
  | Ty_tuple of type_expr list
  | Ty_record of (string * type_expr) list
  | Ty_fn of type_expr list * type_expr * string list
  (* The callee takes an `Array<T>`; the call site fills it. *)
  | Ty_variadic of type_expr
  (* `...Args`: the parameter list a pack stands for, spliced where it stands. *)
  | Ty_spread of type_expr
  (* `T.Item`: which impl bound it is not known until the owner is. *)
  | Ty_assoc of type_expr * string
  (* `Output = T`: what the impl the bound reaches must have bound. *)
  | Ty_bind of string * type_expr

(* [implicit] marks a trailing lambda whose parameters were not written, so how
   many it has is not known until the expected type says. *)
type param =
  { name : string
  ; ty : type_expr option
  ; implicit : bool
  }

type comptime_param =
  { cp_name : string
  ; cp_ty : type_expr option
  (* The one a written argument list is collected into, rather than one of
     them. *)
  ; cp_pack : bool
  }

type type_param =
  { tp_name : string
  ; tp_pack : bool
  }

(* [row = None] leaves the effect row to inference; [Some labels] closes it. *)
type signature =
  { ret : type_expr option
  ; row : string list option
  ; comptime : comptime_param list
  }

type op_kind =
  | Op_fn (* resumes automatically with the arm's value *)
  | Op_ctl (* resumes only via `resume`, and may do so more than once *)
  (* Never resumes, so each call site may read its result as what it needs. *)
  | Op_final

type op_decl =
  { op_name : string
  ; op_kind : op_kind
  (* The operation's own, on top of its effect's. Sound because a call site
     settles them through the arguments, so a handler is never owed a value of
     a type it did not receive one at. *)
  ; op_tparams : string list
  ; op_params : param list
  ; op_ret : type_expr option
  }

type 's handler =
  { handled : string
  ; arms : 's arm list
  }

and 's arm =
  { arm_name : string
  ; arm_kind : op_kind
  ; arm_params : string list
  ; arm_body : 's list
  }

type lit =
  [ `Unit
  | `Int of int
  | `Float of float
  | `Str of Uchar.t array
  | `Char of Uchar.t
  | `Bool of bool
  (* Only reflection makes one, which keeps a name a name. *)
  | `Name of string
  (* Undecoded: what is embedded need not be text. *)
  | `Bytes of string
  ]

type 'e vars =
  [ `Var of string
  | `Assign of string * 'e
  ]

type 'e ops =
  [ `Unop of unop * 'e
  | `Binop of binop * 'e * 'e
  | `Call of 'e * 'e list
  ]

type 'e logic =
  [ `And of 'e * 'e
  | `Or of 'e * 'e
  ]

type 'a payload =
  | P_none
  | P_tuple of 'a list
  | P_fields of (string * 'a) list

type 'e compound = [ `Compound of binop * string * 'e ]

type 'e indexing =
  [ `Index of 'e * 'e
  | `Index_assign of 'e * 'e * 'e
  ]

type 'e tuple =
  [ `Tuple of 'e list
  | `Tuple_get of 'e * int
  ]

(* An argument list is as long as the tuple spread into it, so the checker is
   what takes one apart: nothing after it holds one. *)
type 'e spread = [ `Spread of 'e ]

type 'e record =
  [ `Record_lit of (string * 'e) list
  | `Field of 'e * string
  | `Field_assign of 'e * string * 'e
  ]

type 'e nominal =
  [ `New_call of string * type_expr list * 'e list
  | `New of string * (string * 'e) list
  | `New_variant of string * string * 'e payload
  ]

(* Metadata a deriver reads off a member, and nothing else in the language
   looks at. It is inert everywhere: no pass changes behaviour on one, and
   [cps_stmt_kind] does not include [type_defs], so nothing an attribute is
   attached to survives into the program the interpreter runs. *)
type attr_arg =
  | A_str of string
  | A_int of int
  | A_float of float
  | A_bool of bool

type attr =
  { a_name : string
  ; a_args : attr_arg list
  ; a_span : span
  }

type field =
  { f_name : string
  ; f_ty : type_expr
  ; f_attrs : attr list
  }

(* [v_params] are the variant's own — `If<A>` holds an `A` the head does not
   mention. [v_result] is what makes it a GADT. *)
type variant =
  { v_name : string
  ; v_params : string list
  ; v_payload : type_expr payload
  ; v_result : type_expr option
  ; v_attrs : attr list
  }

type type_body =
  | T_fields of field list
  | T_variants of variant list

type type_defs = [ `Type_decl of string * type_param list * type_body ]

(* Only [stmt_kind] carries this, so `Desugar` unwrapping one is what erases
   every declaration attribute: no later stage's type can hold one, and a pass
   that tried to read one would not compile. A member's attributes cannot use
   this — a field is not a statement — so they stay on the field itself. *)
type 's attributed = [ `Attributed of attr list * 's ]

type method_sig =
  { ms_name : string
  ; ms_params : param list
  ; ms_signature : signature
  }

(* [tb_super] is a bound on `Self`, and a bound on this trait reaches their
   methods. *)
type trait_body =
  { tb_super : (string * type_expr list) list
  ; tb_assoc : string list
  ; tb_methods : method_sig list
  }

(* CPS reads a row off each method's annotation, and one impl holds several. *)
type ('s, 'ann) method_def =
  { md_name : string
  ; md_params : param list
  ; md_signature : signature
  ; md_body : 's list
  ; md_ann : 'ann
  }

type ('s, 'ann) impl_body =
  { ib_assoc : (string * type_expr) list
  ; ib_methods : ('s, 'ann) method_def list
  }

type ('s, 'ann) method_defs =
  [ `Trait_decl of string * string list * trait_body
  | `Impl_decl of (string * type_expr list) option * string * string list * ('s, 'ann) impl_body
  ]

(* Method-or-function is a typing question, the name a loading one. *)
type 'e method_call = [ `Method_call of 'e * string * string * 'e list ]

(* A bare name parses as [Ct_type] whichever it is. *)
type 'e comptime_arg =
  | Ct_type of type_expr
  | Ct_value of 'e

type 'e comptime_call = [ `Comptime_call of 'e * 'e comptime_arg list * 'e list ]

type pattern =
  | Pat_variant of string * string * string payload
  | Pat_wild

type ('e, 's) matching = [ `Match of 'e * (pattern * 's list) list ]

type 'e collection = [ `Collection_lit of 'e list ]

type 'e arrays =
  [ `Array_lit of 'e list
  | `Array_new of 'e * 'e
  | `Array_get of 'e * 'e
  | `Array_set of 'e * 'e * 'e
  | `Array_len of 'e
  ]

type 'e strings =
  [ `Str_get of 'e * 'e
  | `Str_len of 'e
  ]

type 'e variant_lit = [ `Variant of string * (string * 'e) list ]

type import =
  | Qualified of string
  | Aliased of string * string
  | Selective of string list * string
  | Wildcard of string

type imports = [ `Import of import ]

type 's meta_blocks =
    [ `Meta of 's list
    | `Gen of 's
  | `Meta_fn of string * param list * signature * 's list
    | `Derive of string list * string
  ]

type 's handler_clause =
  | Inline of 's handler
  | Named of string

type 's handler_defs = [ `Handler_decl of string * 's handler ]

type ('e, 's, 'h) effects =
  (* Naming the parameters is what lets two operations agree on one. *)
  [ `Effect_decl of string * string list * op_decl list
  | `Run of 's list * 'h list
  | `Resume of 'e option
  ]

type 'e reflect = [ `Typeof of 'e ]

type 'e quote = [ `Code of 'e ]

(* The names a binder introduces. More than one takes a tuple apart. *)
type binder = string list

type ('e, 's) stmts =
  [ `Expr of 'e
  | `Var_decl of string * type_expr option * 'e option
  (* `var (a, b) = pair;`. One statement binding several names, because
     expanding it into several would need a block, and a block would scope them
     away from what follows. *)
  | `Var_tuple of binder * 'e
  | `Block of 's list
  | `If of 'e * 's * 's option
  | `While of 'e * 's
  | `Fn of string * param list * signature * 's list
  | `Return of 'e option
  (* However the block is left, and after anything deferred later. *)
  | `Defer of 's
  ]

(* Why every stage's expression and statement are one recursive group. *)
type ('e, 's) lambdas = [ `Lambda of param list * signature * 's list ]

(* Statements, and the value they leave behind. An expression filling the braces
   exactly is that value, as it is for a trailing lambda; anything else is a
   body and leaves unit. *)
type ('e, 's) valued_block =
  { vb_stmts : 's list
  ; vb_value : 'e option
  }

(* What the block produces when it finishes without an arm answering for it. *)
type ('e, 's) ret_clause =
  { rc_param : string
  ; rc_body : ('e, 's) valued_block
  }

(* `run` where a value is wanted. Desugar lowers it to the statement form and a
   temporary, so no later stage meets one. *)
type ('e, 's, 'h) run_expr =
  [ `Run_expr of ('e, 's) valued_block * 'h list * ('e, 's) ret_clause option ]

(* `Abort` unwinds to the `Scope` its `run` block became, so an effect that only
   aborts needs no continuation. Both carry that scope's name: stopping at the
   nearest would catch the wrong one. *)
type 's aborts =
  [ `Scope of string * 's list * 's list
  | `Abort of string
  (* The second list runs while an unwind passes through, and it carries on. *)
  | `On_unwind of 's list * 's list
  ]

type ('e, 's) loops =
  [ `For of 's option * 'e option * 'e option * 's
  | `For_in of binder * 'e * 's
  ]

type expr = (expr_kind, unit) node

and expr_kind =
  [ lit
  | expr vars
  | expr ops
  | expr logic
  | expr compound
  | expr indexing
  | expr tuple
  | expr spread
  | expr record
  | expr nominal
  | expr collection
  | expr comptime_call
  | expr method_call
  | expr reflect
  | expr quote
  | (expr, stmt) lambdas
  | (expr, stmt, stmt handler_clause) run_expr
  ]

and stmt = (stmt_kind, unit) node

and stmt_kind =
  [ (expr, stmt) stmts
  | stmt attributed
  | imports
  | stmt meta_blocks
  | (expr, stmt) loops
  | (expr, stmt, stmt handler_clause) effects
  | stmt handler_defs
  | type_defs
  | (stmt, unit) method_defs
  | (expr, stmt) matching
  ]

type program = stmt list

type desugared_expr = (desugared_expr_kind, unit) node

and desugared_expr_kind =
  [ lit
  | desugared_expr vars
  | desugared_expr ops
  | desugared_expr logic
  | desugared_expr compound
  | desugared_expr indexing
  | desugared_expr tuple
  | desugared_expr spread
  | desugared_expr record
  | desugared_expr nominal
  | desugared_expr collection
  | desugared_expr comptime_call
  | desugared_expr method_call
  | desugared_expr reflect
  | (desugared_expr, desugared_stmt) lambdas
  | (desugared_expr, desugared_stmt, desugared_stmt handler) run_expr
  ]

and desugared_stmt = (desugared_stmt_kind, unit) node

and desugared_stmt_kind =
  [ (desugared_expr, desugared_stmt) stmts
  | (desugared_expr, desugared_stmt, desugared_stmt handler) effects
  | type_defs
  | (desugared_stmt, unit) method_defs
  | (desugared_expr, desugared_stmt) matching
  ]

type typed_expr = (typed_expr_kind, Types.ty) node

and typed_expr_kind =
  [ lit
  | typed_expr vars
  | typed_expr ops
  | typed_expr logic
  | typed_expr compound
  | typed_expr indexing
  | typed_expr tuple
  | typed_expr spread
  | typed_expr record
  | typed_expr nominal
  | typed_expr collection
  | typed_expr arrays
  | typed_expr strings
  | typed_expr method_call
  | typed_expr reflect
  | (typed_expr, typed_stmt) lambdas
  | (typed_expr, typed_stmt, typed_stmt handler) run_expr
  ]

and typed_stmt = (typed_stmt_kind, Types.ty) node

and typed_stmt_kind =
  [ (typed_expr, typed_stmt) stmts
  | (typed_expr, typed_stmt, typed_stmt handler) effects
  | type_defs
  | (typed_stmt, Types.ty) method_defs
  | (typed_expr, typed_stmt) matching
  ]

type resolved_expr = (resolved_expr_kind, Types.ty) node

and resolved_expr_kind =
  [ lit
  | resolved_expr vars
  | resolved_expr ops
  | resolved_expr logic
  | resolved_expr tuple
  | resolved_expr record
  | resolved_expr arrays
  | resolved_expr strings
  | resolved_expr variant_lit
  | resolved_expr reflect
  | (resolved_expr, resolved_stmt) lambdas
  ]

and resolved_stmt = (resolved_stmt_kind, Types.ty) node

and resolved_stmt_kind =
  [ (resolved_expr, resolved_stmt) stmts
  | (resolved_expr, resolved_stmt, resolved_stmt handler) effects
  | type_defs
  | (resolved_expr, resolved_stmt) matching
  ]

type reflected_expr = (reflected_expr_kind, Types.ty) node

and reflected_expr_kind =
  [ lit
  | reflected_expr vars
  | reflected_expr ops
  | reflected_expr logic
  | reflected_expr tuple
  | reflected_expr record
  | reflected_expr arrays
  | reflected_expr strings
  | reflected_expr variant_lit
  | (reflected_expr, reflected_stmt) lambdas
  ]

and reflected_stmt = (reflected_stmt_kind, Types.ty) node

and reflected_stmt_kind =
  [ (reflected_expr, reflected_stmt) stmts
  | (reflected_expr, reflected_stmt, reflected_stmt handler) effects
  | type_defs
  | (reflected_expr, reflected_stmt) matching
  ]

type cps_expr = (cps_expr_kind, Types.ty) node

and cps_expr_kind =
  [ lit
  | cps_expr vars
  | cps_expr ops
  | cps_expr logic
  | cps_expr tuple
  | cps_expr record
  | cps_expr arrays
  | cps_expr strings
  | cps_expr variant_lit
  | (cps_expr, cps_stmt) lambdas
  ]

and cps_stmt = (cps_stmt_kind, Types.ty) node

and cps_stmt_kind =
  [ (cps_expr, cps_stmt) stmts
  | (cps_expr, cps_stmt) matching
  | cps_stmt aborts
  (* A function holding the rest of a computation. Apart from `Fn` because
     invoking one is being inside the scopes it was captured under again, even
     where those are still entered, which is true of nothing else. *)
  | `Cont of string * param list * cps_stmt list
  (* A function the pass cut out of another: what follows a branch, a loop or a
     suspension, and the arm that resumes into it. A `return` reaching one is
     leaving the source function it was cut from, so it passes through rather
     than stopping here — which is also why an arm's sequel does not run once a
     resumption returns. *)
  | `Frame of string * param list * cps_stmt list
  ]

let map_vars (f : 'a -> 'b) (e : 'a vars) : 'b vars =
  match e with
  | `Var name -> `Var name
  | `Assign (name, v) -> `Assign (name, f v)

let map_ops (f : 'a -> 'b) (e : 'a ops) : 'b ops =
  match e with
  | `Unop (op, a) -> `Unop (op, f a)
  | `Binop (op, a, b) -> `Binop (op, f a, f b)
  | `Call (callee, args) -> `Call (f callee, List.map f args)

let map_logic (f : 'a -> 'b) (e : 'a logic) : 'b logic =
  match e with
  | `And (a, b) -> `And (f a, f b)
  | `Or (a, b) -> `Or (f a, f b)

let map_compound (f : 'a -> 'b) (e : 'a compound) : 'b compound =
  match e with
  | `Compound (op, name, v) -> `Compound (op, name, f v)

let map_indexing (f : 'a -> 'b) (e : 'a indexing) : 'b indexing =
  match e with
  | `Index (target, i) -> `Index (f target, f i)
  | `Index_assign (target, i, v) -> `Index_assign (f target, f i, f v)

let map_spread (f : 'a -> 'b) (e : 'a spread) : 'b spread =
  match e with
  | `Spread inner -> `Spread (f inner)

let map_tuple (f : 'a -> 'b) (e : 'a tuple) : 'b tuple =
  match e with
  | `Tuple items -> `Tuple (List.map f items)
  | `Tuple_get (t, i) -> `Tuple_get (f t, i)

let map_record (f : 'a -> 'b) (e : 'a record) : 'b record =
  match e with
  | `Record_lit fields -> `Record_lit (List.map (fun (l, v) -> l, f v) fields)
  | `Field (r, label) -> `Field (f r, label)
  | `Field_assign (r, label, v) -> `Field_assign (f r, label, f v)

let map_payload (f : 'a -> 'b) (p : 'a payload) : 'b payload =
  match p with
  | P_none -> P_none
  | P_tuple items -> P_tuple (List.map f items)
  | P_fields fields -> P_fields (List.map (fun (l, v) -> l, f v) fields)

let map_nominal (f : 'a -> 'b) (e : 'a nominal) : 'b nominal =
  match e with
  | `New_call (name, type_args, args) ->
    `New_call (name, type_args, List.map f args)
  | `New (name, fields) -> `New (name, List.map (fun (l, v) -> l, f v) fields)
  | `New_variant (ty, variant, payload) ->
    `New_variant (ty, variant, map_payload f payload)

(* `#` is in no identifier the scanner can produce. Two parts or more, or the
   separator would not appear. *)
let generated parts =
  match parts with
  | [] | [ _ ] -> invalid_arg "Ast.generated: a generated name needs two parts"
  | parts -> String.concat "#" parts

(* By trait rather than by the name written, so every deriver may be called
   `derive`. *)
let deriver_name trait = generated [ "derive"; trait ]

let deriver_trait name =
  let prefix = deriver_name "" in
  let n = String.length prefix in
  if String.length name > n && String.equal (String.sub name 0 n) prefix
  then Some (String.sub name n (String.length name - n))
  else None

let type_head (t : type_expr option) =
  match t with
  | Some { it = Ty_name n; _ } | Some { it = Ty_app (n, _); _ } -> n
  | _ -> "_"

let method_name type_name method_ = generated [ type_name; method_ ]

(* `Index<int>` and `Index<Range>` on one list each bring a `get`. *)
let impl_method_name trait type_name method_ =
  match trait with
  | None -> method_name type_name method_
  | Some (name, args) ->
    let written (t : type_expr) =
      match t.it with
      | Ty_name n | Ty_app (n, _) -> n
      | _ -> "_"
    in
    generated ([ type_name; name ] @ List.map written args @ [ method_ ])

let map_comptime_arg (f : 'a -> 'b) (a : 'a comptime_arg) : 'b comptime_arg =
  match a with
  | Ct_type t -> Ct_type t
  | Ct_value v -> Ct_value (f v)

let map_comptime_call (f : 'a -> 'b) (e : 'a comptime_call) : 'b comptime_call =
  match e with
  | `Comptime_call (callee, comptime_args, args) ->
    `Comptime_call
      (f callee, List.map (map_comptime_arg f) comptime_args, List.map f args)

let map_method_call (f : 'a -> 'b) (e : 'a method_call) : 'b method_call =
  match e with
  | `Method_call (receiver, name, as_function, args) ->
    `Method_call (f receiver, name, as_function, List.map f args)

let map_method_def (fs : 's1 -> 's2) (fa : 'a1 -> 'a2) (m : ('s1, 'a1) method_def)
  : ('s2, 'a2) method_def
  =
  { md_name = m.md_name
  ; md_params = m.md_params
  ; md_signature = m.md_signature
  ; md_body = List.map fs m.md_body
  ; md_ann = fa m.md_ann
  }

let map_method_defs (fs : 's1 -> 's2) (fa : 'a1 -> 'a2) (m : ('s1, 'a1) method_defs)
  : ('s2, 'a2) method_defs
  =
  match m with
  | `Trait_decl (name, params, body) -> `Trait_decl (name, params, body)
  | `Impl_decl (trait, type_name, params, body) ->
    `Impl_decl
      ( trait
      , type_name
      , params
      , { body with ib_methods = List.map (map_method_def fs fa) body.ib_methods } )

let map_matching (fe : 'e1 -> 'e2) (fs : 's1 -> 's2) (m : ('e1, 's1) matching)
  : ('e2, 's2) matching
  =
  match m with
  | `Match (scrutinee, cases) ->
    `Match (fe scrutinee, List.map (fun (p, body) -> p, List.map fs body) cases)

let map_collection (f : 'a -> 'b) (e : 'a collection) : 'b collection =
  match e with
  | `Collection_lit items -> `Collection_lit (List.map f items)

let map_strings (f : 'a -> 'b) (e : 'a strings) : 'b strings =
  match e with
  | `Str_get (target, index) -> `Str_get (f target, f index)
  | `Str_len target -> `Str_len (f target)

let map_arrays (f : 'a -> 'b) (e : 'a arrays) : 'b arrays =
  match e with
  | `Array_lit items -> `Array_lit (List.map f items)
  | `Array_new (length, fill) -> `Array_new (f length, f fill)
  | `Array_get (target, index) -> `Array_get (f target, f index)
  | `Array_set (target, index, v) -> `Array_set (f target, f index, f v)
  | `Array_len target -> `Array_len (f target)

let map_variant_lit (f : 'a -> 'b) (e : 'a variant_lit) : 'b variant_lit =
  match e with
  | `Variant (name, fields) -> `Variant (name, List.map (fun (l, v) -> l, f v) fields)

(* Positional payloads are keyed "0", "1", … so one runtime shape serves both
   tuple and field variants. *)
let payload_fields (p : 'a payload) : (string * 'a) list =
  match p with
  | P_none -> []
  | P_tuple items -> List.mapi (fun i v -> string_of_int i, v) items
  | P_fields fields -> fields

let map_reflect (f : 'a -> 'b) (e : 'a reflect) : 'b reflect =
  match e with
  | `Typeof v -> `Typeof (f v)

let map_stmts (fe : 'e1 -> 'e2) (fs : 's1 -> 's2) (s : ('e1, 's1) stmts)
  : ('e2, 's2) stmts
  =
  match s with
  | `Expr e -> `Expr (fe e)
  | `Var_decl (name, ty, init) -> `Var_decl (name, ty, Option.map fe init)
  | `Var_tuple (names, init) -> `Var_tuple (names, fe init)
  | `Block body -> `Block (List.map fs body)
  | `If (c, t, e) -> `If (fe c, fs t, Option.map fs e)
  | `While (c, body) -> `While (fe c, fs body)
  | `Fn (name, params, signature, body) ->
    `Fn (name, params, signature, List.map fs body)
  | `Return e -> `Return (Option.map fe e)
  | `Defer s -> `Defer (fs s)

let map_loops (fe : 'e1 -> 'e2) (fs : 's1 -> 's2) (s : ('e1, 's1) loops)
  : ('e2, 's2) loops
  =
  match s with
  | `For (init, cond, step, body) ->
    `For (Option.map fs init, Option.map fe cond, Option.map fe step, fs body)
  | `For_in (names, iterable, body) -> `For_in (names, fe iterable, fs body)

let map_arm (fs : 's1 -> 's2) (a : 's1 arm) : 's2 arm =
  { arm_name = a.arm_name
  ; arm_kind = a.arm_kind
  ; arm_params = a.arm_params
  ; arm_body = List.map fs a.arm_body
  }

let map_handler (fs : 's1 -> 's2) (h : 's1 handler) : 's2 handler =
  { handled = h.handled; arms = List.map (map_arm fs) h.arms }

let map_valued_block (fe : 'e1 -> 'e2) (fs : 's1 -> 's2) (b : ('e1, 's1) valued_block)
  : ('e2, 's2) valued_block
  =
  { vb_stmts = List.map fs b.vb_stmts; vb_value = Option.map fe b.vb_value }

let map_run_expr
      (fe : 'e1 -> 'e2)
      (fs : 's1 -> 's2)
      (fh : 'h1 -> 'h2)
      (r : ('e1, 's1, 'h1) run_expr)
  : ('e2, 's2, 'h2) run_expr
  =
  match r with
  | `Run_expr (body, handlers, clause) ->
    `Run_expr
      ( map_valued_block fe fs body
      , List.map fh handlers
      , Option.map
          (fun c -> { rc_param = c.rc_param; rc_body = map_valued_block fe fs c.rc_body })
          clause )

let map_effects
      (fe : 'e1 -> 'e2)
      (fs : 's1 -> 's2)
      (fh : 'h1 -> 'h2)
      (s : ('e1, 's1, 'h1) effects)
  : ('e2, 's2, 'h2) effects
  =
  match s with
  | `Effect_decl (name, params, ops) -> `Effect_decl (name, params, ops)
  | `Run (body, handlers) -> `Run (List.map fs body, List.map fh handlers)
  | `Resume e -> `Resume (Option.map fe e)

let string_of_binop = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Equal -> "=="
  | Not_equal -> "!="
  | Less -> "<"
  | Less_equal -> "<="
  | Greater -> ">"
  | Greater_equal -> ">="

let binop_of_token : Token.token_type -> binop option = function
  | Token.Plus -> Some Add
  | Token.Minus -> Some Sub
  | Token.Star -> Some Mul
  | Token.Slash -> Some Div
  | Token.Percent -> Some Mod
  | Token.Equal_equal -> Some Equal
  | Token.Bang_equal -> Some Not_equal
  | Token.Less -> Some Less
  | Token.Less_equal -> Some Less_equal
  | Token.Greater -> Some Greater
  | Token.Greater_equal -> Some Greater_equal
  | _ -> None

let unop_of_token : Token.token_type -> unop option = function
  | Token.Minus -> Some Neg
  | Token.Bang -> Some Not
  | _ -> None

let span_of_token (t : Token.token) = t.Token.span
