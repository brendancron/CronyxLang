type emission =
  | Primitive
  | Call of string

(* Declared one at a time, so a type may be readable without being writable. *)
type indexing =
  { get : string option
  ; set : string option
  }

(* `(element) -> container`, so the element is recovered by unifying against the
   result rather than by assuming one type argument. *)
type container =
  { entry : string
  ; scheme : Types.scheme
  }

type entry =
  { (* [None] is whatever the operands are. *)
    result : Types.ty option
  ; emit : emission
  }

(* [targets] is the trait's arguments as they were written, which is what one
   impl's method is told apart by: `To<string>` and `To<bool>` on one type each
   bring a `to`. *)
type method_entry =
  { mangled : string
  ; trait : string option
  ; targets : string list
  }

type t =
  {     containers : (string, container) Hashtbl.t
  ; (* Keyed by what the index is, so one type may be read by an int and
       sliced by a range. *)
    indexed : (string * string, indexing) Hashtbl.t
  ; constructors : (string, string) Hashtbl.t
  ; associated : (string * string, unit) Hashtbl.t
  ; (* An impl mangles its methods with the trait, so the written name alone
       does not name a function, and one type may hold several of one name. *)
    entries : (string * string, method_entry list) Hashtbl.t
  ; exact : (Ast.binop * Types.ty * Types.ty, entry) Hashtbl.t
  ; (* `-x`. One operand, so it cannot share [exact]'s key. *)
    unary : (Ast.unop * Types.ty, entry) Hashtbl.t
  ; (* Any two operands of the same type, which cannot be enumerated. *)
    homogeneous : (Ast.binop, entry) Hashtbl.t
  }

let create () =
  { containers = Hashtbl.create 8
  ; indexed = Hashtbl.create 8
  ; constructors = Hashtbl.create 8
  ; associated = Hashtbl.create 8
  ; entries = Hashtbl.create 32
  ; exact = Hashtbl.create 64
  ; unary = Hashtbl.create 8
  ; homogeneous = Hashtbl.create 8
  }

let register_container t name entry = Hashtbl.replace t.containers name entry

let entry_for t key =
  match Hashtbl.find_opt t.indexed key with
  | Some entry -> entry
  | None -> { get = None; set = None }

let register_index_get t name index fn =
  Hashtbl.replace t.indexed (name, index) { (entry_for t (name, index)) with get = Some fn }

let register_index_set t name index fn =
  Hashtbl.replace t.indexed (name, index) { (entry_for t (name, index)) with set = Some fn }

let overloads t name =
  Hashtbl.fold
    (fun (owner, index) entry acc ->
      if String.equal owner name then (index, entry) :: acc else acc)
    t.indexed
    []

(* Without [indexed]'s fallback, which is for reading rather than deciding. *)
let exact_index t name index = Hashtbl.find_opt t.indexed (name, index)

(* An index whose type is a parameter matches nothing written, so a type with
   one entry answers for any index. *)
let indexed t name index =
  match Hashtbl.find_opt t.indexed (name, index) with
  | Some entry -> Some entry
  | None ->
    (match overloads t name with
     | [ (_, only) ] -> Some only
     | _ -> None)

let is_indexed t name = overloads t name <> []

let register_entry t owner method_ entry =
  let known = Option.value ~default:[] (Hashtbl.find_opt t.entries (owner, method_)) in
  Hashtbl.replace t.entries (owner, method_) (known @ [ entry ])

let method_entries t owner method_ =
  Option.value ~default:[] (Hashtbl.find_opt t.entries (owner, method_))

(* The impl a method came from, as a diagnostic says it: `To<bool>`, or the type
   itself for an impl that answers no trait. A name from another module carries
   that module's prefix, which the program never wrote. *)
let describe_entry owner e =
  let written name =
    match String.rindex_opt name '#' with
    | Some at -> String.sub name (at + 1) (String.length name - at - 1)
    | None -> name
  in
  match e.trait with
  | None -> written owner
  | Some trait ->
    Printf.sprintf
      "%s<%s>"
      (written trait)
      (String.concat ", " (List.map written e.targets))

(* The written targets pick one, so `f.to<bool>()` reaches the impl that a call
   by name alone could not. *)
let entry_with_targets t owner method_ targets =
  let matches e =
    List.length e.targets = List.length targets
    && List.for_all2 String.equal e.targets targets
  in
  List.find_opt matches (method_entries t owner method_)

(* A bound names the entry outright, so a call it dispatched asks no table which
   impl it reaches. *)
let dispatched (d : Types.ty Ast.dispatch) owner method_ =
  let written t = Option.value (Types.type_name t) ~default:"_" in
  Ast.dispatched_method_name
    owner
    d.Ast.dp_trait
    (List.map written d.Ast.dp_targets)
    method_

(* A call left ambiguous is rejected before here, so the head is the one entry
   a receiver's method has. *)
let entry_for_method t owner method_ =
  match method_entries t owner method_ with
  | entry :: _ -> entry.mangled
  | [] -> Ast.method_name owner method_

(* No receiver is passed. The checker knows which these are; the passes that
   build the call have to be told. *)
let mark_associated t owner method_ = Hashtbl.replace t.associated (owner, method_) ()
let is_associated t owner method_ = Hashtbl.mem t.associated (owner, method_)
let register_constructor t name fn = Hashtbl.replace t.constructors name fn
let constructor t name = Hashtbl.find_opt t.constructors name
let container t name = Hashtbl.find_opt t.containers name

let container_element t name (target : Types.infer_ty) =
  match Hashtbl.find_opt t.containers name with
  | None -> None
  | Some c ->
    (match Types.repr (Types.instantiate c.scheme) with
     | Types.IFn ([ element ], result, _) ->
       (try
          Types.unify result target;
          Some element
        with
        | Types.Type_error _ -> None)
     | _ -> None)

let register t op lhs rhs entry = Hashtbl.replace t.exact (op, lhs, rhs) entry
let register_unary t op operand entry = Hashtbl.replace t.unary (op, operand) entry
let find_unary t op operand = Hashtbl.find_opt t.unary (op, operand)

let register_homogeneous t op entry = Hashtbl.replace t.homogeneous op entry

let find_exact t op lhs rhs = Hashtbl.find_opt t.exact (op, lhs, rhs)

let find t op lhs rhs =
  match Hashtbl.find_opt t.exact (op, lhs, rhs) with
  | Some entry -> Some entry
  | None -> if lhs = rhs then Hashtbl.find_opt t.homogeneous op else None

let result_of entry operand =
  match entry.result with
  | Some ty -> ty
  | None -> operand

let unresolved_result (op : Ast.binop) operand =
  match op with
  | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod | Ast.Bit_and | Ast.Bit_or | Ast.Bit_xor
  | Ast.Shl | Ast.Shr -> operand
  | Ast.Less | Ast.Less_equal | Ast.Greater | Ast.Greater_equal | Ast.Equal
  | Ast.Not_equal -> Types.IBool

let builtins () =
  let t = create () in
  let prim result = { result = Some result; emit = Primitive } in
  let arithmetic = [ Ast.Add; Ast.Sub; Ast.Mul; Ast.Div; Ast.Mod ] in
  let comparisons =
    [ Ast.Less; Ast.Less_equal; Ast.Greater; Ast.Greater_equal ]
  in
  List.iter
    (fun op ->
      register t op Types.Int Types.Int (prim Types.Int);
      register t op Types.Float Types.Float (prim Types.Float))
    arithmetic;
  register t Ast.Add Types.Str Types.Str (prim Types.Str);
  List.iter
    (fun op ->
      register t op Types.Int Types.Int (prim Types.Bool);
      register t op Types.Float Types.Float (prim Types.Bool);
      (* A scalar value and an octet both have an order, and code that
         classifies characters is written with it. *)
      register t op Types.Chr Types.Chr (prim Types.Bool);
      register t op Types.Str Types.Str (prim Types.Bool);
      register t op Types.Byte Types.Byte (prim Types.Bool))
    comparisons;
  List.iter
    (fun op -> register_homogeneous t op (prim Types.Bool))
    [ Ast.Equal; Ast.Not_equal ];
  register_unary t Ast.Neg Types.Int (prim Types.Int);
  register_unary t Ast.Neg Types.Float (prim Types.Float);
  (* A byte shifts by an int, as an int does: the amount is a count, not an
     octet. *)
  List.iter
    (fun op ->
      register t op Types.Int Types.Int (prim Types.Int);
      register t op Types.Byte Types.Byte (prim Types.Byte))
    [ Ast.Bit_and; Ast.Bit_or; Ast.Bit_xor ];
  List.iter
    (fun op ->
      register t op Types.Int Types.Int (prim Types.Int);
      register t op Types.Byte Types.Int (prim Types.Byte))
    [ Ast.Shl; Ast.Shr ];
  register_unary t Ast.Bit_not Types.Int (prim Types.Int);
  register_unary t Ast.Bit_not Types.Byte (prim Types.Byte);
  t
