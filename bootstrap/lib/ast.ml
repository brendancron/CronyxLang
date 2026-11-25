type span = Source_map.Span.t

(* Every path that reaches a diagnostic has been through [Loader.normalize],
   which spells a separator `/` -- as the line below already assumes. An entry
   arrives from [Filename.concat], which spells it `\\` on Windows, so the two
   would never compare equal and every diagnostic would name the file it is
   already in. *)
let slashed path =
  if Sys.win32 then String.map (fun c -> if Char.equal c '\\' then '/' else c) path else path

(* A path is shown only when it is not the file the user named, and then
   relative to it. *)
let shown_path ~entry path =
  let path = slashed path in
  let root = Filename.dirname (slashed entry) ^ "/" in
  if String.length path > String.length root
     && String.equal (String.sub path 0 (String.length root)) root
  then String.sub path (String.length root) (String.length path - String.length root)
  else path

let locate ~entry (s : span) =
  let entry = slashed entry in
  match Source_map.Span.view s with
  | Source_map.Span.Nowhere_in_source -> "[unknown]"
  | Source_map.Span.Located l ->
    let path = slashed (Source_map.File.path l.Source_map.Span.file) in
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
  | Bit_not (* ~ *)

type binop =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | Bit_and
  | Bit_or
  | Bit_xor
  | Shl
  | Shr
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
  | Ty_fn of type_expr list * type_expr * (string * type_expr list) list
  (* The callee takes an `Array<T>`; the call site fills it. *)
  | Ty_variadic of type_expr
  (* `...Args`: the parameter list a pack stands for, spliced where it stands. *)
  | Ty_spread of type_expr
  (* `T.Item`: which impl bound it is not known until the owner is. *)
  | Ty_assoc of type_expr * string
  (* `Output = T`: what the impl the bound reaches must have bound. *)
  | Ty_bind of string * type_expr
  (* `<Async, E>` as an argument, where the type's parameter stands in a row. *)
  | Ty_row of (string * type_expr list) list

(* [implicit] marks a trailing lambda whose parameters were not written, so how
   many it has is not known until the expected type says. *)
type param =
  { name : string
  ; ty : type_expr option
  ; implicit : bool
  }

type static_param =
  { sp_name : string
  ; sp_ty : type_expr option
  (* The one a written argument list is collected into, rather than one of
     them. *)
  ; sp_pack : bool
  }

type type_param =
  { tp_name : string
  ; tp_pack : bool
  (* `n: Int`: a value the type is instantiated at, never seen by the checker. *)
  ; tp_ty : type_expr option
  }

(* [row = None] leaves the effect row to inference; [Some labels] closes it. An
   effect taking parameters may be written at its arguments — `<Yield<Int>>` —
   and is otherwise left to inference at every one of them. *)
type signature =
  { ret : type_expr option
  ; row : (string * type_expr list) list option
  ; static_params : static_param list
  ; inline : bool
  }

(* An effect trait's method as the checker reads it. *)
type op_kind =
  | Op_fn (* returns once, with the handler's value *)
  | Op_ctl (* takes its continuation, and may resume it more than once *)
  (* Never resumes, so each call site may read its result as what it needs. *)
  | Op_final

(* Metadata a deriver reads off a member, and nothing else in the language
   looks at. It is inert everywhere: no pass changes behaviour on one, and
   [resolved_stmt_kind] keeps only a type's declaration, which the interpreter
   passes over, of everything an attribute is attached to. *)
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

type op_decl =
  { op_name : string
  ; op_kind : op_kind
  (* The operation's own, on top of its effect's. Sound because a call site
     settles them through the arguments, so a handler is never owed a value of
     a type it did not receive one at. *)
  ; op_tparams : string list
  ; op_params : param list
  ; op_ret : type_expr option
  (* An operation is a member of its effect, as a field is of a type, so it
     carries what was written above it. A doc comment rides here. *)
  ; op_attrs : attr list
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

type 'e compound =
  [ `Compound of binop * string * 'e
  | `Compound_index of binop * 'e * 'e * 'e
  | `Compound_field of binop * 'e * string * 'e
  ]

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

(* Only [stmt_kind] carries this, so the checker unwrapping one is what erases
   every declaration attribute: no later stage's type can hold one, and a pass
   that tried to read one would not compile. A member's attributes cannot use
   this — a field, a variant and a method are not statements — so they stay on
   the member itself. A method's die where its impl becomes plain functions,
   and [resolved_stmt_kind] holds no [method_defs] to carry one further. *)
type 's attributed = [ `Attributed of attr list * 's ]

type method_sig =
  { ms_name : string
  ; ms_params : param list
  ; ms_signature : signature
  ; ms_attrs : attr list
  }

(* `type Item;` in a trait: a name the implementer has to bind, which carries
   what was written above it like any other member. *)
type assoc_decl =
  { ad_name : string
  ; ad_attrs : attr list
  }

(* [tb_super] is a bound on `Self`, and a bound on this trait reaches their
   methods. *)
type trait_body =
  { tb_super : (string * type_expr list) list
  ; tb_assoc : assoc_decl list
  ; tb_methods : method_sig list
  }

type ('s, 'ann) method_def =
  { md_name : string
  ; md_params : param list
  ; md_signature : signature
  ; md_body : 's list
  ; md_ann : 'ann
  ; md_attrs : attr list
  }

(* `type Item = Int;` in an impl: the binding the trait asked for. *)
type assoc_def =
  { as_name : string
  ; as_ty : type_expr
  ; as_attrs : attr list
  }

type ('s, 'ann) impl_body =
  { ib_assoc : assoc_def list
  ; ib_methods : ('s, 'ann) method_def list
  }

(* What the checker asks of a binding list, which is what `List.assoc` was doing
   before the name carried anything besides itself. *)
let assoc_names (list : assoc_decl list) = List.map (fun a -> a.ad_name) list

let assoc_bound (list : assoc_def list) name =
  List.find_map (fun a -> if String.equal a.as_name name then Some a.as_ty else None) list

let assoc_binds (list : assoc_def list) name =
  List.exists (fun a -> String.equal a.as_name name) list

type ('s, 'ann) method_defs =
  [ `Trait_decl of string * string list * trait_body
  | `Impl_decl of (string * type_expr list) option * string * type_param list * ('s, 'ann) impl_body
  ]

(* Method-or-function is a typing question, the name a loading one. *)
(* The names the file that wrote the call can see, which is where a trait's
   impl may answer it from; [None] for a call no file wrote, which a meta block
   built and which reaches any impl. *)
type in_scope = string list option

type 'e method_call = [ `Method_call of 'e * string * string * 'e list * in_scope ]

(* Which impl a call reaches: the trait, and the arguments that tell two impls of
   it on one type apart. A bound is where these come from, so a call inside a
   generic body carries what the bound said rather than deciding later from the
   receiver's type and the method's name, which cannot say. *)
type 'ty dispatch =
  { dp_trait : string
  ; dp_targets : 'ty list
  }

(* The method's own type travels with the call: a row cannot be read off a
   vtable. *)
type ('e, 'ty) dyn_calls = [ `Dyn_call of 'e * string * 'ty * 'e list ]

(* What tells two objects apart: the type each was made from, and the `Eq`
   impl `==` reaches at that type, if it has one. The data alone cannot say --
   two fieldless types are the same record. *)
type 'e identity =
  { made_from : string
  ; equal : 'e option
  }

(* What a coercion becomes: the data beside the functions chosen for it, and a
   call that reads its target out of that table rather than from a name. *)
type 'e object_lit = [ `Object of 'e * 'e identity * (string * 'e) list ]

type 'e objects =
  [ 'e object_lit
  | ('e, Types.ty) dyn_calls
  ]

(* A bare name parses as [St_type] whichever it is. *)
type 'e static_arg =
  | St_type of type_expr
  | St_value of 'e

(* [`Static_ref] is `f<int>` named as a value, with no call. *)
type 'e static_call =
  [ `Static_call of 'e * 'e static_arg list * 'e list
  | `Static_ref of 'e * 'e static_arg list
  ]

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

(* A `global import` is one every file of its package has written. *)
type imports = [ `Import of import | `Global_import of import ]

(* A type declared with members after its fields: the `Type_decl`, then its
   functions and meta blocks. Metaprocessing takes it apart. *)
type 's type_members = [ `Type_members of 's * 's list ]

(* `new Box<Int> { … }`, keeping what `<…>` said: an instantiation needs it,
   and nothing after metaprocessing does. *)
type 'e generic_new = [ `New_generic of string * 'e static_arg list * (string * 'e) list ]

type 's meta_blocks =
    [ `Meta of 's list
    | `Gen of 's
    | `Derive of string list * string
  ]

(* `with H` names a type implementing the effects it binds; `handle<E> { … }`
   implements one in place. *)
type 's handler_clause =
  | Named of string
  | Handle of type_expr * ('s, unit) method_def list
  (* What a transform makes of a run: the effect, the handler bound to it, and
     the statement declaring the handler's value, checked outside the run. Its
     body is not transformed again. *)
  | Bound of string * string * 's option

type 'e reflect = [ `Typeof of 'e ]

(* [None] when no `<…>` was written, which is not the same key as `<>`. *)
type 'e declof = [ `Declof of 'e * 'e static_arg list option ]

type 's meta_expr = [ `Meta_expr of 's list ]

(* A trait with meta blocks among its members: the `Trait_decl`, then the
   blocks. *)
type 's trait_members = [ `Trait_members of 's * 's list ]

(* `code(e)`, `code { … }` and `code fn …`: syntax held as a value rather than
   run, so only metaprocessing ever meets one. *)
type ('e, 's) quote =
  [ `Code of 'e
  | `Code_stmts of 's list
  | `Code_decl of 's
  ]

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
  (* Leaves the innermost loop. *)
  | `Break
  (* Skips to the innermost loop's next iteration. *)
  | `Continue
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

(* A `run`, lowered to a block and a temporary once checked, so no later stage
   meets one. The type is the `<R>` written after `run`. *)
type ('e, 's, 'h) run_expr = [ `Run_expr of type_expr option * ('e, 's) valued_block * 'h list ]

(* `match` where a value is wanted, lowered the way `Run_expr` is. *)
type ('e, 's) match_expr = [ `Match_expr of 'e * (pattern * ('e, 's) valued_block) list ]

(* Lowered by the checker rather than the parser: whether the sequence is
   indexed or pulled depends on its type. *)
type ('e, 's) for_in = [ `For_in of binder * 'e * 's ]

(* Code already checked, standing where it was moved to: the checker hands back
   what it checked under this number, so nothing in it runs or is checked
   again. *)
type pre_checked = [ `Pre_checked of int ]

type expr = (expr_kind, unit) node

and expr_kind =
  [ lit
  | pre_checked
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
  | expr static_call
  | expr method_call
  | expr reflect
  | expr declof
  | stmt meta_expr
  | (expr, stmt) quote
  | expr generic_new
  | (expr, stmt) lambdas
  | (expr, stmt, stmt handler_clause) run_expr
  | (expr, stmt) match_expr
  ]

and stmt = (stmt_kind, unit) node

and stmt_kind =
  [ (expr, stmt) stmts
  | pre_checked
  | stmt attributed
  | imports
  | stmt meta_blocks
  | stmt type_members
  | stmt trait_members
  | (expr, stmt) for_in
  | type_defs
  | (stmt, unit) method_defs
  | (expr, stmt) matching
  ]

type program = stmt list

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
  | resolved_expr objects
  | (resolved_expr, resolved_stmt) lambdas
  ]

and resolved_stmt = (resolved_stmt_kind, Types.ty) node

and resolved_stmt_kind =
  [ (resolved_expr, resolved_stmt) stmts
  | type_defs
  | (resolved_expr, resolved_stmt) matching
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
  | `Compound_index (op, target, i, v) -> `Compound_index (op, f target, f i, f v)
  | `Compound_field (op, target, label, v) -> `Compound_field (op, f target, label, f v)

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

(* A row label no program can write, standing for whatever else a generated
   function type performs: the row is open there. *)
let open_row = generated [ "row"; "open" ]

let absent_type = Types.absent_name

(* A type processed code shows where the checker had not settled one. *)
let open_type = generated [ "type"; "open" ]

(* The static parameter a transform marks its own functions with. *)
let plain_marker = generated [ "plain"; "made" ]

(* The static parameter marking a function a transform made taking more than
   its type shows: after those parameters, the handler of each effect it takes
   control of, then what the library's [Core.handed] lists. *)
let handed_marker = generated [ "handed"; "made" ]

(* The static parameter marking a handler's method a transform made taking,
   after the parameters its operation shows, what [Core.handed_method] lists. *)
let handed_method_marker = generated [ "method"; "made" ]

(* The parameter a function taking control takes an effect's handler in. *)
let handler_param label = generated [ "hv"; label ]


(* The function the top level runs under, and the one a top-level statement
   that throws runs under inside it, by the whole names the prelude's
   declarations are mangled to. Any module may declare a `__root` of its own,
   and one matched by its last part would take the top level over. *)
let root_function = generated [ "std"; "prelude"; "__root" ]
let root_catcher = generated [ "std"; "prelude"; "__throwing" ]

(* What a meta block's program runs under, wherever the block is written. *)
let meta_root_function = generated [ "std"; "prelude"; "__meta_root" ]

let program_main = generated [ "program"; "main" ]

let is_program_root name = String.equal name root_function

let is_root name = is_program_root name || String.equal name meta_root_function
let is_root_or_catcher name = is_root name || String.equal name root_catcher

(* What a parameter written without a type is a static parameter of: the
   function is generic in it, under a name no program can write. *)
let implicit_param n = generated [ "implicit"; string_of_int n ]
let is_implicit_param name = String.starts_with ~prefix:"implicit#" name

(* By trait rather than by the name written, so every deriver may be called
   `derive`. *)
let deriver_name trait = generated [ "derive"; trait ]

let deriver_trait name =
  let prefix = deriver_name "" in
  let n = String.length prefix in
  if String.length name > n && String.equal (String.sub name 0 n) prefix
  then Some (String.sub name n (String.length name - n))
  else None

(* How a `/** … */` rides to the artifact: an attribute is already carried
   everywhere one needs to go, so docs borrow the channel rather than build a
   second one beside it. The name is generated, so `/**` is the only way to
   write a doc and no `@doc` exists to be typed, printed or reflected — every
   surface that meets one presents it as a comment. *)
let doc_attr = generated [ "attr"; "doc" ]

(* On each declaration of a unit loaded because the walk runs it, and imported by
   no unit: nothing the program writes can name one, so Precheck leaves them out. *)
let walk_only_attr = generated [ "attr"; "walk" ]

let walk_only (s : stmt) : stmt =
  let marker = { a_name = walk_only_attr; a_args = []; a_span = s.span } in
  match s.it with
  | `Import _ | `Global_import _ | `Meta _ | `Derive _ | `Gen _ -> s
  | `Attributed (attrs, inner) -> { s with it = `Attributed (marker :: attrs, inner) }
  | _ -> { s with it = `Attributed ([ marker ], s) }

let is_walk_only (s : stmt) =
  match s.it with
  | `Attributed (attrs, _) -> List.exists (fun a -> String.equal a.a_name walk_only_attr) attrs
  | _ -> false

(* A module's top-level meta block, tagged with the prefix its unit's names are
   mangled under: it runs the first time the walk asks that unit for a name. *)
let deferred_marker = generated [ "unit"; "meta" ]

let deferred ~unit_prefix (s : stmt) : stmt =
  { s with
    it = `Attributed ([ { a_name = deferred_marker; a_args = [ A_str unit_prefix ]; a_span = s.span } ], s)
  }

(* The entry file's own `fn main`, which the program starts at instead of its
   top level. *)
let entry_main_marker = generated [ "entry"; "main" ]

let entry_main (s : stmt) : stmt =
  { s with it = `Attributed ([ { a_name = entry_main_marker; a_args = []; a_span = s.span } ], s) }

let type_head (t : type_expr option) =
  match t with
  | Some { it = Ty_name n; _ } | Some { it = Ty_app (n, _); _ } -> n
  | _ -> "_"

let method_name type_name method_ = generated [ type_name; method_ ]

(* What a bare call to an effect's operation resolves to, which no program can
   spell. The method's own name is last, so a diagnostic shows it. *)
let operation_name trait method_ = generated [ trait; "op"; method_ ]

(* `@abort` never resumes, and its handler is written without the continuation. *)
let aborts (attrs : attr list) = List.exists (fun a -> String.equal a.a_name "abort") attrs

let takes_control (m : method_sig) =
  aborts m.ms_attrs || List.exists (fun a -> String.equal a.a_name "ctl") m.ms_attrs

let rec mentions name (t : type_expr) =
  match t.it with
  | Ty_name n -> String.equal n name
  | Ty_app (n, args) -> String.equal n name || List.exists (mentions name) args
  | Ty_tuple items -> List.exists (mentions name) items
  | Ty_record fields -> List.exists (fun (_, t) -> mentions name t) fields
  | Ty_fn (params, ret, row) ->
    List.exists (mentions name) params
    || mentions name ret
    || List.exists (fun (l, args) -> String.equal l name || List.exists (mentions name) args) row
  | Ty_variadic t | Ty_spread t | Ty_assoc (t, _) | Ty_bind (_, t) -> mentions name t
  | Ty_row row -> List.exists (fun (l, args) -> String.equal l name || List.exists (mentions name) args) row

(* An effect is a trait written as its callers see it: its operations are
   called with no receiver, so none takes `self`, and none can name `Self`,
   which a bare call has nothing to stand for. A trait of associated functions
   that build `Self` -- `Zero`, `FromArray` -- is therefore not one. *)
let is_effect (body : trait_body) =
  body.tb_methods <> []
  && List.for_all
       (fun m ->
         (match m.ms_params with
          | { name = "self"; _ } :: _ -> false
          | _ -> true)
         && (not (List.exists (fun p -> Option.fold ~none:false ~some:(mentions "Self") p.ty) m.ms_params))
         && not (Option.fold ~none:false ~some:(mentions "Self") m.ms_signature.ret))
       body.tb_methods

let written_type (t : type_expr) =
  match t.it with
  | Ty_name n | Ty_app (n, _) -> n
  | _ -> "_"

(* `Index<Int>` and `Index<Range>` on one list each bring a `get`, so the trait
   and its arguments are in the name. A dispatch names the same entry from the
   types a bound gave: [Types.type_name] and [written_type] agree on the head. *)
let dispatched_method_name type_name trait targets method_ =
  generated ([ type_name; trait ] @ targets @ [ method_ ])

let impl_method_name trait type_name method_ =
  match trait with
  | None -> method_name type_name method_
  | Some (name, args) ->
    dispatched_method_name type_name name (List.map written_type args) method_

let map_static_arg (f : 'a -> 'b) (a : 'a static_arg) : 'b static_arg =
  match a with
  | St_type t -> St_type t
  | St_value v -> St_value (f v)

let map_generic_new (f : 'a -> 'b) (e : 'a generic_new) : 'b generic_new =
  match e with
  | `New_generic (name, static_args, fields) ->
    `New_generic
      (name, List.map (map_static_arg f) static_args, List.map (fun (l, v) -> l, f v) fields)

let map_static_call (f : 'a -> 'b) (e : 'a static_call) : 'b static_call =
  match e with
  | `Static_call (callee, static_args, args) ->
    `Static_call
      (f callee, List.map (map_static_arg f) static_args, List.map f args)
  | `Static_ref (callee, static_args) -> `Static_ref (f callee, List.map (map_static_arg f) static_args)

let map_method_call (f : 'a -> 'b) (e : 'a method_call) : 'b method_call =
  match e with
  | `Method_call (receiver, name, as_function, args, scope) ->
    `Method_call (f receiver, name, as_function, List.map f args, scope)

let map_dyn_call (f : 'a -> 'b) (g : 't -> 'u) (e : ('a, 't) dyn_calls)
  : ('b, 'u) dyn_calls
  =
  match e with
  | `Dyn_call (receiver, name, ty, args) ->
    `Dyn_call (f receiver, name, g ty, List.map f args)

let map_object_lit (f : 'a -> 'b) (e : 'a object_lit) : 'b object_lit =
  match e with
  | `Object (data, id, vtable) ->
    `Object
      ( f data
      , { id with equal = Option.map f id.equal }
      , List.map (fun (l, v) -> l, f v) vtable )

let map_object (f : 'a -> 'b) (e : 'a objects) : 'b objects =
  match e with
  | #object_lit as o -> (map_object_lit f o :> 'b objects)
  | #dyn_calls as d -> (map_dyn_call f (fun t -> t) d :> 'b objects)

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

let pattern_names (p : pattern) =
  match p with
  | Pat_variant (_, _, payload) -> List.map snd (payload_fields payload)
  | Pat_wild -> []

let map_reflect (f : 'a -> 'b) (e : 'a reflect) : 'b reflect =
  match e with
  | `Typeof v -> `Typeof (f v)

let map_declof (f : 'a -> 'b) (e : 'a declof) : 'b declof =
  match e with
  | `Declof (v, static_args) -> `Declof (f v, Option.map (List.map (map_static_arg f)) static_args)

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
  | `Break -> `Break
  | `Continue -> `Continue
  | `Defer s -> `Defer (fs s)

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
  | `Run_expr (ret, body, handlers) -> `Run_expr (ret, map_valued_block fe fs body, List.map fh handlers)

let string_of_binop = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Bit_and -> "&"
  | Bit_or -> "|"
  | Bit_xor -> "^"
  | Shl -> "<<"
  | Shr -> ">>"
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
  | Token.Amp -> Some Bit_and
  | Token.Pipe -> Some Bit_or
  | Token.Caret -> Some Bit_xor
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
  | Token.Tilde -> Some Bit_not
  | _ -> None

let span_of_token (t : Token.token) = t.Token.span
