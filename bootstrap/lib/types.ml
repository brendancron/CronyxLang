
type fields = (string * ty) list

(* `Yield<int>` and `Yield<string>` are different entries. [tail] is the
   variable a call site settles: `Cps` reads evidence arity off a definition, so
   a row that is still open here is one `Type_mono` owes a copy per row. *)
and row =
  { labels : (string * ty list) list
  ; tail : int option
  }

and ty =
  | Int
  | Float
  | Str
  | Byte
  | Chr
  | Bool
  | Unit
  | Tuple of ty list
  (* The parameter list a pack stands for, and a use of one in a list position.
     [Spread] survives only where the pack is still generic: [Type_mono] splices
     it the moment the copy is concrete. *)
  | Pack of ty list
  | Spread of ty
  | Record of fields
  | Named of string * ty list * fields
  | Sum of string * ty list
  | Fn of ty list * ty * row
  (* Quantified, not unresolved. Reaching codegen means a call site was missed. *)
  | Generic of int

type infer_ty =
  | IInt
  | IFloat
  | IStr
  | IByte
  | IChr
  | IBool
  | IUnit
  | ITuple of infer_ty list
  | IPack of infer_ty list
  | ISpread of infer_ty
  | IRecord of infer_fields
  | INamed of string * infer_ty list * infer_fields
  | ISum of string * infer_ty list
  | IFn of infer_ty list * infer_ty * infer_row
  | IVar of tv ref

and kind =
  | Any
  | Collection of infer_ty
  | Bound of bound list
  (* `T.Item` before `T` is known: the owner is carried, not the answer. *)
  | Projection of infer_ty * string

and bound =
  { bd_trait : string
  ; bd_args : infer_ty list
  ; bd_bindings : (string * infer_ty) list
  }

and tv =
  | Unbound of int * kind
  | Link of infer_ty

(* Rewriting an open tail is what lets a pure function pass where an effectful
   one is expected. *)
and infer_row =
  | REmpty
  | RCons of string * infer_ty list * infer_row
  | RVar of rv ref

and rv =
  | RUnbound of int
  | RLink of infer_row

and infer_fields =
  | FEmpty
  | FCons of string * infer_ty * infer_fields
  | FVar of fv ref

and fv =
  | FUnbound of int
  | FLink of infer_fields

type scheme =
  { quantified : int list
  ; quantified_rows : int list
  ; quantified_fields : int list
  ; body : infer_ty
  }

exception Type_error of string

let error fmt = Printf.ksprintf (fun message -> raise (Type_error message)) fmt

let counter = ref 0

let fresh_with kind =
  incr counter;
  IVar (ref (Unbound (!counter, kind)))

let fresh () = fresh_with Any

let fresh_row () =
  incr counter;
  RVar (ref (RUnbound !counter))

let fresh_fields () =
  incr counter;
  FVar (ref (FUnbound !counter))

(* Never defaulted: the author said the function is generic in T. *)
let declared_params : (int, unit) Hashtbl.t = Hashtbl.create 8

(* A row the author opened, as against one inference has not settled yet. A
   call through the first is contained; through the second it is tied. *)
let declared_row_params : (int, unit) Hashtbl.t = Hashtbl.create 8

(* Which parameters were declared to stand for a parameter list. Recorded per
   variable rather than per name, so a use is checked against the binder that is
   actually in scope. *)
let declared_packs : (int, unit) Hashtbl.t = Hashtbl.create 8

(* What the author called a parameter. An id is a counter, so printing one would
   make a signature read differently for a variable allocated somewhere else
   entirely. *)
let param_names : (int, string) Hashtbl.t = Hashtbl.create 8

let name_param name (t : infer_ty) =
  match t with
  | IVar { contents = Unbound (id, _) } -> Hashtbl.replace param_names id name
  | _ -> ()

let reset () =
  counter := 0;
  Hashtbl.reset declared_params;
  Hashtbl.reset declared_row_params;
  Hashtbl.reset param_names;
  Hashtbl.reset declared_packs

(* An equation holding only inside a match arm is taken back when the arm ends.
   Recording is off unless asked for, so every other unification pays nothing. *)
type undo = Undo : 'a ref * 'a -> undo

let trail : undo list ref = ref []
let recording = ref false

let note (cell : 'a ref) = if !recording then trail := Undo (cell, !cell) :: !trail



(* Unused: refinement solves a substitution instead. Kept because a speculative
   unification is the obvious thing to want next. *)
let retracting f =
  let outer_trail = !trail
  and outer_recording = !recording in
  trail := [];
  recording := true;
  let undo () =
    List.iter (fun (Undo (cell, previous)) -> cell := previous) !trail;
    trail := outer_trail;
    recording := outer_recording
  in
  Fun.protect ~finally:undo f

let rec repr (t : infer_ty) : infer_ty =
  match t with
  | IVar ({ contents = Link inner } as r) ->
    let target = repr inner in
    note r;
    r := Link target;
    target
  | t -> t

let rec repr_row (r : infer_row) : infer_row =
  match r with
  | RVar ({ contents = RLink inner } as v) ->
    let target = repr_row inner in
    note v;
    v := RLink target;
    target
  | r -> r

let rec repr_fields (f : infer_fields) : infer_fields =
  match f with
  | FVar ({ contents = FLink inner } as v) ->
    let target = repr_fields inner in
    note v;
    v := FLink target;
    target
  | f -> f

(* A literal that narrowed to nothing else is an array. *)
let array_name = "Array"

(* Not a runtime value: [Reflect] folds each projection to the data it names. *)
let reflection_name = "Type"
let shape_name = "TypeShape"
let field_name = "TypeField"
let variant_name = "TypeVariant"

let name_name = "Name"
let iname = INamed (name_name, [], FEmpty)
let name = Named (name_name, [], [])
let attr_name = "Attr"
let attr_arg_name = "AttrArg"

let attr_fields =
  [ "args", Named (array_name, [ Sum (attr_arg_name, []) ], []); "name", name ]

let iattr_fields =
  FCons
    ( "args"
    , INamed (array_name, [ ISum (attr_arg_name, []) ], FEmpty)
    , FCons ("name", iname, FEmpty) )

let attr_ty = Named (attr_name, [], attr_fields)
let attrs_ty = Named (array_name, [ attr_ty ], [])

let reflection_fields =
  [ "attrs", attrs_ty; "name", Str; "shape", Sum (shape_name, []) ]

let ireflected =
  INamed
    ( reflection_name
    , []
    , FCons
        ( "attrs"
        , INamed (array_name, [ INamed (attr_name, [], iattr_fields) ], FEmpty)
        , FCons ("name", IStr, FCons ("shape", ISum (shape_name, []), FEmpty)) ) )

let reflected = Named (reflection_name, [], reflection_fields)

let code_name = "Code"
let icode = INamed (code_name, [], FEmpty)

let string_name = "string"

let array_len = "len"
let array elem = Named (array_name, [ elem ], [])
let iarray elem = INamed (array_name, [ elem ], FEmpty)

let is_array (t : ty) =
  match t with
  | Named (name, [ _ ], _) -> String.equal name array_name
  | _ -> false

let string_of_kind = function
  | Any -> "any"
  | Collection _ -> "a collection"
  | Bound traits -> String.concat " and " (List.map (fun b -> b.bd_trait) traits)
  | Projection (_, member) -> Printf.sprintf "an associated '%s'" member

let closed_row labels = { labels; tail = None }

let rec labels_of_infer_row (r : infer_row) : (string * infer_ty list) list * bool =
  match repr_row r with
  | REmpty -> [], false
  | RVar _ -> [], true
  | RCons (label, args, rest) ->
    let labels, open_ = labels_of_infer_row rest in
    (label, args) :: labels, open_

let rec row_tail (r : infer_row) : int option =
  match repr_row r with
  | REmpty | RVar { contents = RLink _ } -> None
  | RVar { contents = RUnbound id } -> Some id
  | RCons (_, _, rest) -> row_tail rest

let declare_row (r : infer_row) =
  match row_tail r with
  | Some id -> Hashtbl.replace declared_row_params id ()
  | None -> ()

let row_is_declared (r : infer_row) =
  match row_tail r with
  | Some id -> Hashtbl.mem declared_row_params id
  | None -> false

let entry render (label, args) =
  match args with
  | [] -> label
  | args -> Printf.sprintf "%s<%s>" label (String.concat ", " (List.map render args))

let letter n =
  let single = String.make 1 (Char.chr (Char.code 'a' + (n mod 26))) in
  if n < 26 then single else single ^ string_of_int (n / 26)

(* Named where it was declared, or after where it first appears in what is
   being printed. *)
let var_name seen id =
  match Hashtbl.find_opt param_names id with
  | Some name -> name
  | None ->
    (match Hashtbl.find_opt seen id with
     | Some name -> name
     | None ->
       let name = "'" ^ letter (Hashtbl.length seen) in
       Hashtbl.add seen id name;
       name)

let rec string_of_infer_args seen (args : infer_ty list) =
  match args with
  | [] -> ""
  | args ->
    Printf.sprintf "<%s>" (String.concat ", " (List.map (string_of_infer_ty seen) args))

and string_of_infer_ty seen (t : infer_ty) : string =
  let string_of_infer_args = string_of_infer_args seen in
  let string_of_infer_row = string_of_infer_row seen in
  let string_of_infer_ty = string_of_infer_ty seen in
  match repr t with
  | IInt -> "int"
  | IFloat -> "float"
  | IStr -> "string"
  | IByte -> "byte"
  | IChr -> "char"
  | IBool -> "bool"
  | IUnit -> "unit"
  | ITuple items ->
    Printf.sprintf "(%s)" (String.concat ", " (List.map string_of_infer_ty items))
  | IPack items -> String.concat ", " (List.map string_of_infer_ty items)
  | ISpread inner -> "..." ^ string_of_infer_ty inner
  | INamed (name, args, _) | ISum (name, args) ->
    name ^ string_of_infer_args args
  | IRecord f ->
    let rec fields f =
      match repr_fields f with
      | FEmpty -> []
      | FVar _ -> [ "..." ]
      | FCons (label, ty, rest) ->
        Printf.sprintf "%s: %s" label (string_of_infer_ty ty) :: fields rest
    in
    Printf.sprintf "{ %s }" (String.concat ", " (List.sort compare (fields f)))
  | IFn (params, ret, row) ->
    Printf.sprintf
      "(%s) ->%s %s"
      (String.concat ", " (List.map string_of_infer_ty params))
      (string_of_infer_row row)
      (string_of_infer_ty ret)
  | IVar { contents = Unbound (id, _) } -> var_name seen id
  | IVar { contents = Link _ } -> assert false (* repr collapsed these *)

and string_of_infer_row seen (r : infer_row) =
  match labels_of_infer_row r with
  | [], false -> ""
  | labels, open_ ->
    Printf.sprintf
      " <%s%s>"
      (String.concat ", " (List.map (entry (string_of_infer_ty seen)) labels))
      (if open_ then "|_" else "")

let rec string_of_args seen (args : ty list) =
  match args with
  | [] -> ""
  | args -> Printf.sprintf "<%s>" (String.concat ", " (List.map (string_of_ty seen) args))

(* The tail is not printed: what a row is open in says nothing about what the
   function performs. *)
and string_of_row seen (r : row) =
  match r.labels with
  | [] -> ""
  | labels ->
    Printf.sprintf " <%s>" (String.concat ", " (List.map (entry (string_of_ty seen)) labels))

and string_of_ty seen (t : ty) : string =
  let string_of_args = string_of_args seen in
  let string_of_row = string_of_row seen in
  let string_of_ty = string_of_ty seen in
  match t with
  | Int -> "int"
  | Float -> "float"
  | Str -> "string"
  | Byte -> "byte"
  | Chr -> "char"
  | Bool -> "bool"
  | Unit -> "unit"
  | Tuple items ->
    Printf.sprintf "(%s)" (String.concat ", " (List.map string_of_ty items))
  | Pack items -> String.concat ", " (List.map string_of_ty items)
  | Spread inner -> "..." ^ string_of_ty inner
  | Named (name, args, _) | Sum (name, args) -> name ^ string_of_args args
  | Record fields ->
    Printf.sprintf
      "{ %s }"
      (String.concat
         ", "
         (List.map (fun (l, t) -> Printf.sprintf "%s: %s" l (string_of_ty t)) fields))
  | Fn (params, ret, row) ->
    Printf.sprintf
      "(%s) ->%s %s"
      (String.concat ", " (List.map string_of_ty params))
      (string_of_row row)
      (string_of_ty ret)
  | Generic id -> var_name seen id

(* Each rendering numbers what it met, so a name means the same thing across one
   message and nothing more. *)
let string_of_infer_ty t = string_of_infer_ty (Hashtbl.create 4) t
let string_of_infer_row r = string_of_infer_row (Hashtbl.create 4) r
let string_of_ty t = string_of_ty (Hashtbl.create 4) t
let string_of_row r = string_of_row (Hashtbl.create 4) r
let string_of_args args = string_of_args (Hashtbl.create 4) args

let type_name (t : ty) : string option =
  match t with
  | Int -> Some "int"
  | Float -> Some "float"
  | Str -> Some "string"
  | Byte -> Some "byte"
  | Chr -> Some "char"
  | Bool -> Some "bool"
  | Unit -> Some "unit"
  | Named (name, _, _) | Sum (name, _) -> Some name
  | Tuple _ | Pack _ | Spread _ | Record _ | Fn _ | Generic _ -> None

(* A row whose tail is bound gains what the call site settled it to. Its own
   labels stay: `<log | E>` at `E = <ask>` is `<ask, log>`. *)
let subst_row rows (r : row) : row =
  match r.tail with
  | None -> r
  | Some id ->
    (match List.assoc_opt id rows with
     | None -> r
     | Some bound ->
       { labels = List.sort compare (r.labels @ bound.labels); tail = bound.tail })

(* The list form of [expand]: what a pack holds, spliced where the copy that
   settled it left a spread behind. *)
let rec expand_ty (items : ty list) : ty list =
  match items with
  | [] -> []
  | Spread (Pack held) :: rest -> expand_ty (held @ rest)
  | item :: rest -> item :: expand_ty rest

let rec subst_generic ?(rows = []) mapping (t : ty) : ty =
  let subst_generic mapping t = subst_generic ~rows mapping t in
  match t with
  | Generic id ->
    (match List.assoc_opt id mapping with
     | Some replacement -> replacement
     | None -> t)
  | Tuple items ->
    (match expand_ty (List.map (subst_generic mapping) items) with
     | [] -> Unit
     | items -> Tuple items)
  | Pack items -> Pack (List.map (subst_generic mapping) items)
  | Spread inner -> Spread (subst_generic mapping inner)
  | Record fields -> Record (List.map (fun (l, t) -> l, subst_generic mapping t) fields)
  | Named (name, args, fields) ->
    Named
      ( name
      , List.map (subst_generic mapping) args
      , List.map (fun (l, t) -> l, subst_generic mapping t) fields )
  | Sum (name, args) -> Sum (name, List.map (subst_generic mapping) args)
  | Fn (params, ret, row) ->
    Fn
      ( expand_ty (List.map (subst_generic mapping) params)
      , subst_generic mapping ret
      , subst_row rows row )
  | scalar -> scalar

let rec match_generic_fields a b acc =
  List.fold_left
    (fun acc (label, ty) ->
      match List.assoc_opt label b with
      | Some other -> match_generic ty other acc
      | None -> acc)
    acc
    a

and match_generic (general : ty) (concrete : ty) acc =
  match general, concrete with
  | Generic id, _ -> if List.mem_assoc id acc then acc else (id, concrete) :: acc
  | Tuple a, Tuple b -> match_generic_list a b acc
  | Tuple a, Unit -> match_generic_list a [] acc
  | Record a, Record b -> match_generic_fields a b acc
  | Named (_, ga, a), Named (_, gb, b) when List.length ga = List.length gb ->
    match_generic_fields a b (List.fold_left2 (fun acc x y -> match_generic x y acc) acc ga gb)
  | Named (_, _, a), Named (_, _, b) -> match_generic_fields a b acc
  | Sum (_, a), Sum (_, b) when List.length a = List.length b ->
    List.fold_left2 (fun acc a b -> match_generic a b acc) acc a b
  | Fn (pa, ra, _), Fn (pb, rb, _) -> match_generic ra rb (match_generic_list pa pb acc)
  | _ -> acc

(* A spread is what the copy settles, so it takes however many the concrete
   list has left rather than pairing off against one. *)
and match_generic_list (general : ty list) (concrete : ty list) acc =
  match general, concrete with
  | [ Spread (Generic id) ], rest ->
    if List.mem_assoc id acc then acc else (id, Pack rest) :: acc
  | a :: general, b :: concrete -> match_generic_list general concrete (match_generic a b acc)
  | _ -> acc

(* What the template left open, read off an instantiation of it. Any difference
   between the two rows must come from a variable: a row the definition closed
   is one unification would already have rejected at the call site. *)
let rec match_rows (general : ty) (concrete : ty) acc =
  match general, concrete with
  | Tuple a, Tuple b when List.length a = List.length b ->
    List.fold_left2 (fun acc a b -> match_rows a b acc) acc a b
  | Named (_, a, _), Named (_, b, _) | Sum (_, a), Sum (_, b) when List.length a = List.length b ->
    List.fold_left2 (fun acc a b -> match_rows a b acc) acc a b
  | Fn (pa, ra, rowa), Fn (pb, rb, rowb) when List.length pa = List.length pb ->
    let acc = List.fold_left2 (fun acc a b -> match_rows a b acc) acc pa pb in
    let acc = match_rows ra rb acc in
    (match rowa.tail with
     | Some id when not (List.mem_assoc id acc) ->
       let named = List.map fst rowa.labels in
       let rest = List.filter (fun (l, _) -> not (List.mem l named)) rowb.labels in
       (id, { labels = rest; tail = rowb.tail }) :: acc
     | _ -> acc)
  | _ -> acc

(* Evidence arity follows the row a definition declares, so a copy per row is
   owed only when a parameter is what brings that row in. A function merely
   left open — which is most of them — needs none. *)
let row_polymorphic (t : ty) =
  match t with
  | Fn (params, _, { tail = Some id; _ }) ->
    let rec mentions t =
      match t with
      | Fn (ps, ret, row) -> row.tail = Some id || List.exists mentions ps || mentions ret
      | Tuple items | Pack items -> List.exists mentions items
      | Spread inner -> mentions inner
      | Record fields | Named (_, _, fields) -> List.exists (fun (_, t) -> mentions t) fields
      | Sum (_, args) -> List.exists mentions args
      | _ -> false
    in
    List.exists mentions params
  | _ -> false

let rec has_generic (t : ty) =
  match t with
  | Generic _ -> true
  | Tuple items | Pack items -> List.exists has_generic items
  | Spread inner -> has_generic inner
  | Record fields -> List.exists (fun (_, t) -> has_generic t) fields
  (* Arguments as well as fields: an opaque container has no fields, so
     `Array<T>` would otherwise report as concrete. *)
  | Named (_, args, fields) ->
    List.exists has_generic args || List.exists (fun (_, t) -> has_generic t) fields
  | Sum (_, args) -> List.exists has_generic args
  | Fn (params, ret, _) -> List.exists has_generic params || has_generic ret
  | _ -> false

let container_element (t : infer_ty) : (string * infer_ty) option =
  match repr t with
  | INamed (name, [ elem ], _) -> Some (name, elem)
  | _ -> None

let infer_type_name (t : infer_ty) : string option =
  match repr t with
  | IInt -> Some "int"
  | IFloat -> Some "float"
  | IStr -> Some "string"
  | IByte -> Some "byte"
  | IChr -> Some "char"
  | IBool -> Some "bool"
  | IUnit -> Some "unit"
  | INamed (name, _, _) | ISum (name, _) -> Some name
  | ITuple _ | IPack _ | ISpread _ | IRecord _ | IFn _ | IVar _ -> None

(* A pack in a list position is however many types it holds. One whose pack is
   still a variable stays where it is: [Type_mono] splices it once the copy it
   makes has settled what the pack holds. *)
let rec expand (items : infer_ty list) : infer_ty list =
  match items with
  | [] -> []
  | item :: rest ->
    (match repr item with
     | ISpread inner ->
       (match repr inner with
        | IPack held -> expand (held @ rest)
        | _ -> item :: expand rest)
     | _ -> item :: expand rest)

(* ---- row unification ---- *)

let rec row_occurs id (r : infer_row) =
  match repr_row r with
  | REmpty -> false
  | RVar { contents = RUnbound id' } -> id = id'
  | RVar { contents = RLink _ } -> assert false
  | RCons (_, _, rest) -> row_occurs id rest

let extra_admits : (kind -> infer_ty -> bool) ref = ref (fun _ _ -> false)

(* The table belongs to the checker, so a projection asks through here. *)
let assoc_binding : (string -> string -> infer_ty option) ref = ref (fun _ _ -> None)

let project (owner : infer_ty) (member : string) : infer_ty =
  match Option.bind (infer_type_name owner) (fun name -> !assoc_binding name member) with
  | Some bound -> bound
  | None -> fresh_with (Projection (owner, member))

(* Called wherever a type is inspected, since the owner may be settled long
   after the projection was built. [settling] guards the self-reference
   `T: Add<T, Output = T>` builds, where asking what a variable stands for would
   ask for itself. *)
let settling : tv ref list ref = ref []

let rec settle (t : infer_ty) : infer_ty =
  match repr t with
  | IVar ({ contents = Unbound (_, Projection _) } as cell) as self
    when List.memq cell !settling -> self
  | IVar ({ contents = Unbound (_, Projection (owner, member)) } as cell) as self ->
    settling := cell :: !settling;
    Fun.protect
      ~finally:(fun () -> settling := List.tl !settling)
      (fun () ->
        match infer_type_name (settle owner) with
        | None -> self
        | Some name ->
          (match !assoc_binding name member with
           | None -> self
           | Some bound ->
             note cell;
             cell := Link bound;
             repr bound))
  | other -> other

(* Finding the label is also agreeing on what it was instantiated at, so the
   arguments are unified rather than compared. *)
let rec rewrite_row label args (r : infer_row) : infer_row =
  match repr_row r with
  | RCons (l, found, rest) when String.equal l label ->
    (try List.iter2 unify args found with
     | Invalid_argument _ ->
       error "Effect '%s' is used with %d argument(s) and %d here." l
         (List.length found) (List.length args));
    rest
  | RCons (l, found, rest) -> RCons (l, found, rewrite_row label args rest)
  | RVar ({ contents = RUnbound _ } as v) ->
    let tail = fresh_row () in
    note v;
    v := RLink (RCons (label, args, tail));
    tail
  | RVar { contents = RLink _ } -> assert false
  | REmpty -> error "This code does not handle the effect '%s'." label

(* Containment, not equality: the CPS pass reads the callee's annotation to
   decide how much evidence to pass. *)
and row_within (inner : infer_row) (outer : infer_row) : unit =
  match repr_row inner with
  | REmpty | RVar _ -> ()
  | RCons (label, args, rest) ->
    ignore (rewrite_row label args outer);
    row_within rest outer

and unify_row (a : infer_row) (b : infer_row) : unit =
  match repr_row a, repr_row b with
  | REmpty, REmpty -> ()
  | RVar v1, RVar v2 when v1 == v2 -> ()
  (* The declared one survives, so a later call through it is contained rather
     than tied — which is what stops `<log | E>` looking recursive to itself. *)
  | RVar ({ contents = RUnbound id1 } as v1), RVar ({ contents = RUnbound id2 } as v2) ->
    let keep, dropped =
      if Hashtbl.mem declared_row_params id1 && not (Hashtbl.mem declared_row_params id2)
      then v1, v2
      else v2, v1
    in
    note dropped;
    dropped := RLink (RVar keep)
  | RVar ({ contents = RUnbound id } as v), other
  | other, RVar ({ contents = RUnbound id } as v) ->
    if row_occurs id other then error "This effect row is recursive.";
    note v;
    v := RLink other
  | RCons (label, args, rest_a), (RCons _ as b) ->
    let rest_b = rewrite_row label args b in
    unify_row rest_a rest_b
  | REmpty, RCons (label, _, _) | RCons (label, _, _), REmpty ->
    error "This code does not handle the effect '%s'." label
  | RVar { contents = RLink _ }, _ | _, RVar { contents = RLink _ } -> assert false

(* ---- field rows ---- *)

and fields_occurs id (f : infer_fields) =
  match repr_fields f with
  | FEmpty -> false
  | FVar { contents = FUnbound id' } -> id = id'
  | FVar { contents = FLink _ } -> assert false
  | FCons (_, _, rest) -> fields_occurs id rest

and rewrite_fields label (f : infer_fields) : infer_ty * infer_fields =
  match repr_fields f with
  | FCons (l, ty, rest) when String.equal l label -> ty, rest
  | FCons (l, ty, rest) ->
    let found, rest = rewrite_fields label rest in
    found, FCons (l, ty, rest)
  | FVar ({ contents = FUnbound id } as v) ->
    let ty = fresh () in
    let tail = fresh_fields () in
    note v;
    v := FLink (FCons (label, ty, tail));
    ty, tail
  | FVar { contents = FLink _ } -> assert false
  | FEmpty -> error "This value has no field '%s'." label

(* ---- unification ---- *)

and occurs id (t : infer_ty) =
  match repr t with
  | IVar { contents = Unbound (id', _) } -> id = id'
  | ITuple items | IPack items -> List.exists (occurs id) items
  | ISpread inner -> occurs id inner
  | IRecord f | INamed (_, _, f) ->
    let rec walk f =
      match repr_fields f with
      | FEmpty | FVar _ -> false
      | FCons (_, ty, rest) -> occurs id ty || walk rest
    in
    walk f
  | IFn (params, ret, _) -> List.exists (occurs id) params || occurs id ret
  | _ -> false

and unify_fields (a : infer_fields) (b : infer_fields) : unit =
  match repr_fields a, repr_fields b with
  | FEmpty, FEmpty -> ()
  | FVar v1, FVar v2 when v1 == v2 -> ()
  | FVar ({ contents = FUnbound id } as v), other
  | other, FVar ({ contents = FUnbound id } as v) ->
    if fields_occurs id other then error "This record type is recursive.";
    note v;
    v := FLink other
  | FCons (label, ty, rest_a), (FCons _ as b) ->
    let found, rest_b = rewrite_fields label b in
    unify ty found;
    unify_fields rest_a rest_b
  | FEmpty, FCons (label, _, _) | FCons (label, _, _), FEmpty ->
    error "This value has no field '%s'." label
  | FVar { contents = FLink _ }, _ | _, FVar { contents = FLink _ } -> assert false

and strongest a b =
  match a, b with
  | Collection x, Collection y ->
    unify x y;
    Collection x
  | Collection _, Any -> a
  | Any, Collection _ -> b
  (* `T: Add<T>` puts the variable inside its own kind, so comparing the
     arguments structurally would not terminate. *)
  | Bound x, Bound y ->
    let same (a : bound) (b : bound) =
      String.equal a.bd_trait b.bd_trait
      && List.length a.bd_args = List.length b.bd_args
    in
    Bound (x @ List.filter (fun b -> not (List.exists (same b) x)) y)
  | Bound _, Any -> a
  | Any, Bound _ -> b
  | Collection _, other | other, Collection _ ->
    error "A collection is not %s." (string_of_kind other)
  (* A projection survives every merge: it is the only kind that says where a
     type comes from rather than what it must satisfy, and dropping the owner
     leaves nothing able to resolve it. *)
  | Projection _, _ -> a
  | _, Projection _ -> b
  | Any, Any -> Any

and kind_admits kind (t : infer_ty) =
  match kind, t with
  | Any, _ -> true
  | Projection _, _ -> true
  | (Collection _ | Bound _), _ -> !extra_admits kind t

and unify (a : infer_ty) (b : infer_ty) : unit =
  let a = settle a
  and b = settle b in
  match a, b with
  | IVar r1, IVar r2 when r1 == r2 -> ()
  | ( IVar ({ contents = Unbound (id1, k1) } as r1)
    , IVar ({ contents = Unbound (id2, k2) } as r2) ) ->
    (* A scheme records the survivor's id; an alias would leave it pointing at
       nothing. *)
    let keep, dropped, kept =
      if Hashtbl.mem declared_params id1 && not (Hashtbl.mem declared_params id2)
      then r1, r2, id1
      else r2, r1, id2
    in
    (* Rewriting the cell to the kind it already had is still a write, and that
       is an arm constraining something rather than mentioning it. *)
    (match k1, k2 with
     | Any, Any -> ()
     | _ ->
       note keep;
       keep := Unbound (kept, strongest k1 k2));
    (* Or a declared parameter stops being one the moment an operator gives it
       a kind. *)
    if Hashtbl.mem declared_params id1 || Hashtbl.mem declared_params id2
    then Hashtbl.replace declared_params kept ();
    note dropped;
    dropped := Link (IVar keep)
  | IVar ({ contents = Unbound (id, kind) } as r), t
  | t, IVar ({ contents = Unbound (id, kind) } as r) ->
    if occurs id t
    then error "This expression would have an infinitely recursive type.";
    if not (kind_admits kind t)
    then error "Expected %s, got %s." (string_of_kind kind) (string_of_infer_ty t);
    note r;
    r := Link t
  | IInt, IInt | IFloat, IFloat | IStr, IStr | IByte, IByte | IChr, IChr | IBool, IBool | IUnit, IUnit -> ()
  | IRecord a, IRecord b -> unify_fields a b
  | INamed (a, xs, _), INamed (b, ys, _)
    when String.equal a b && List.length xs = List.length ys -> List.iter2 unify xs ys
  | ISum (a, xs), ISum (b, ys)
    when String.equal a b && List.length xs = List.length ys -> List.iter2 unify xs ys
  | ITuple a, ITuple b ->
    unify_list
      ~mismatch:(fun m n -> error "Expected a tuple of %d element(s), got one of %d." m n)
      a
      b
  (* A pack that holds nothing spliced into a tuple leaves no elements, and a
     product of none is what `unit` already is. *)
  | ITuple items, IUnit | IUnit, ITuple items ->
    unify_list
      ~mismatch:(fun m n -> error "Expected a tuple of %d element(s), got one of %d." m n)
      items
      []
  | IPack a, IPack b ->
    if List.length a <> List.length b
    then
      error
        "Expected a pack of %d type(s), got one of %d."
        (List.length a)
        (List.length b);
    List.iter2 unify a b
  | IFn (p1, r1, e1), IFn (p2, r2, e2) ->
    unify_list
      ~mismatch:
        (fun m n -> error "Expected a function of %d argument(s), got one of %d." m n)
      p1
      p2;
    unify r1 r2;
    unify_row e1 e2
  | _ -> error "Expected %s, got %s." (string_of_infer_ty a) (string_of_infer_ty b)

(* A spread takes however many the other side has left, which is the only place
   a pack is ever settled: everywhere else it is already one type. *)
and unify_list ~mismatch (a : infer_ty list) (b : infer_ty list) : unit =
  let spread t =
    match repr t with
    | ISpread inner -> Some inner
    | _ -> None
  in
  let a = expand a
  and b = expand b in
  let mismatch () = mismatch (List.length a) (List.length b) in
  let rec go a b =
    match a, b with
    | [], [] -> ()
    | [ x ], [ y ] when spread x <> None && spread y <> None ->
      unify (Option.get (spread x)) (Option.get (spread y))
    | [ x ], rest when spread x <> None && not (List.exists (fun t -> spread t <> None) rest) ->
      unify (Option.get (spread x)) (IPack rest)
    | rest, [ y ] when spread y <> None && not (List.exists (fun t -> spread t <> None) rest) ->
      unify (Option.get (spread y)) (IPack rest)
    | x :: xs, y :: ys when spread x = None && spread y = None ->
      unify x y;
      go xs ys
    | _ -> mismatch ()
  in
  go a b

(* ---- schemes ---- *)

let rec walk_fields walk f =
  match repr_fields f with
  | FEmpty | FVar _ -> ()
  | FCons (_, ty, rest) ->
    walk ty;
    walk_fields walk rest

let free_vars (t : infer_ty) : (int * kind) list =
  let acc = ref [] in
  let rec walk t =
    match repr t with
    (* Into the kind as well: a projection's owner may appear nowhere else in
       the type, and leaving it unquantified makes every instantiation share
       the one the template built. Recorded before descending, since
       `T: Add<T>` puts the variable inside its own kind. *)
    | IVar { contents = Unbound (id, kind) } ->
      if not (List.mem_assoc id !acc)
      then (
        acc := (id, kind) :: !acc;
        match kind with
        | Collection elem -> walk elem
        | Projection (owner, _) -> walk owner
        | Bound bounds ->
          List.iter
            (fun b ->
              List.iter walk b.bd_args;
              List.iter (fun (_, t) -> walk t) b.bd_bindings)
            bounds
        | Any -> ())
    | ITuple items | IPack items -> List.iter walk items
    | ISpread inner -> walk inner
    | IRecord f -> walk_fields walk f
    | INamed (_, args, f) ->
      List.iter walk args;
      walk_fields walk f
    | ISum (_, args) -> List.iter walk args
    | IFn (params, ret, _) ->
      List.iter walk params;
      walk ret
    | _ -> ()
  in
  walk t;
  !acc

let free_row_vars (t : infer_ty) : int list =
  let acc = ref [] in
  let rec walk_row r =
    match repr_row r with
    | REmpty -> ()
    | RVar { contents = RUnbound id } -> if not (List.mem id !acc) then acc := id :: !acc
    | RVar { contents = RLink _ } -> assert false
    | RCons (_, args, rest) ->
      List.iter walk args;
      walk_row rest
  and walk t =
    match repr t with
    | ITuple items | IPack items -> List.iter walk items
    | ISpread inner -> walk inner
    | IRecord f -> walk_fields walk f
    | INamed (_, args, f) ->
      List.iter walk args;
      walk_fields walk f
    | ISum (_, args) -> List.iter walk args
    | IFn (params, ret, row) ->
      List.iter walk params;
      walk ret;
      walk_row row
    | _ -> ()
  in
  walk t;
  !acc

let mono body = { quantified = []; quantified_rows = []; quantified_fields = []; body }

let free_field_vars (t : infer_ty) : int list =
  let acc = ref [] in
  let rec walk_fields f =
    match repr_fields f with
    | FEmpty -> ()
    | FVar { contents = FUnbound id } -> if not (List.mem id !acc) then acc := id :: !acc
    | FVar { contents = FLink _ } -> assert false
    | FCons (_, ty, rest) ->
      walk ty;
      walk_fields rest
  and walk t =
    match repr t with
    | ITuple items | IPack items -> List.iter walk items
    | ISpread inner -> walk inner
    | IRecord f -> walk_fields f
    | INamed (_, args, f) ->
      List.iter walk args;
      walk_fields f
    | ISum (_, args) -> List.iter walk args
    | IFn (params, ret, _) ->
      List.iter walk params;
      walk ret
    | _ -> ()
  in
  walk t;
  !acc

let generalize ~env_vars ~env_rows ~env_fields body =
  { quantified =
      free_vars body |> List.map fst |> List.filter (fun id -> not (List.mem id env_vars))
  ; quantified_rows = free_row_vars body |> List.filter (fun id -> not (List.mem id env_rows))
  ; quantified_fields =
      free_field_vars body |> List.filter (fun id -> not (List.mem id env_fields))
  ; body
  }

(* A parameter's own bound may mention it, so the variable has to exist before
   its kind is known. *)
let constrain (t : infer_ty) (kind : kind) : unit =
  match repr t with
  | IVar ({ contents = Unbound (id, existing) } as cell) ->
    note cell;
    cell := Unbound (id, strongest existing kind)
  | _ -> ()

let instantiate ?(bound = []) (s : scheme) : infer_ty =
  if s.quantified = [] && s.quantified_rows = [] && s.quantified_fields = []
  then s.body
  else (
    let types = Hashtbl.create 8
    and rows = Hashtbl.create 8
    and fields = Hashtbl.create 8 in
    List.iter (fun (id, t) -> Hashtbl.replace types id t) bound;
    let rec walk_row r =
      match repr_row r with
      | REmpty -> REmpty
      | RVar { contents = RUnbound id } as original ->
        if List.mem id s.quantified_rows
        then (
          match Hashtbl.find_opt rows id with
          | Some copy -> copy
          | None ->
            let copy = fresh_row () in
            Hashtbl.add rows id copy;
            copy)
        else original
      | RVar { contents = RLink _ } -> assert false
      | RCons (label, args, rest) -> RCons (label, List.map walk args, walk_row rest)
    and walk t =
      match repr t with
      | IVar { contents = Unbound (id, kind) } as original ->
        if List.mem id s.quantified
        then (
          match Hashtbl.find_opt types id with
          | Some copy -> copy
          | None ->
            (* Registered before its kind is walked, since `T: Add<T>` carries
               the variable being copied. *)
            let copy = fresh () in
            Hashtbl.add types id copy;
            (* A copy of a declared parameter is still that parameter, so what
               the author called it survives instantiation. *)
            Option.iter (fun name -> name_param name copy) (Hashtbl.find_opt param_names id);
            (match copy with
             | IVar cell ->
               let copied =
                 match kind with
                 | Collection elem -> Collection (walk elem)
                 | Projection (owner, member) -> Projection (walk owner, member)
                 | Bound bounds ->
                   Bound
                     (List.map
                        (fun b ->
                          { b with
                            bd_args = List.map walk b.bd_args
                          ; bd_bindings =
                              List.map (fun (member, t) -> member, walk t) b.bd_bindings
                          })
                        bounds)
                 | other -> other
               in
               (match !cell with
                | Unbound (fresh_id, _) -> cell := Unbound (fresh_id, copied)
                | Link _ -> ())
             | _ -> ());
            copy)
        else original
      | ITuple items -> ITuple (List.map walk items)
      | IPack items -> IPack (List.map walk items)
      | ISpread inner -> ISpread (walk inner)
      | ISum (name, args) -> ISum (name, List.map walk args)
      | (IRecord _ | INamed _) as r ->
        let f =
          match r with
          | IRecord f | INamed (_, _, f) -> f
          | _ -> assert false
        in
        let rec copy f =
          match repr_fields f with
          | FEmpty -> FEmpty
          | FVar { contents = FUnbound id } as original ->
            if List.mem id s.quantified_fields
            then (
              match Hashtbl.find_opt fields id with
              | Some copy -> copy
              | None ->
                let copy = fresh_fields () in
                Hashtbl.add fields id copy;
                copy)
            else original
          | FVar { contents = FLink _ } -> assert false
          | FCons (label, ty, rest) -> FCons (label, walk ty, copy rest)
        in
        (match r with
         | INamed (name, args, _) -> INamed (name, List.map walk args, copy f)
         | _ -> IRecord (copy f))
      | IFn (params, ret, row) -> IFn (List.map walk params, walk ret, walk_row row)
      | concrete -> concrete
    in
    walk s.body)

(* A tree checked under an equation about to be taken back keeps its
   annotations this way. *)
let rec snapshot (t : infer_ty) : infer_ty =
  match repr t with
  | ITuple items -> ITuple (List.map snapshot items)
  | IPack items -> IPack (List.map snapshot items)
  | ISpread inner -> ISpread (snapshot inner)
  | IRecord f -> IRecord (snapshot_fields f)
  | INamed (name, args, f) -> INamed (name, List.map snapshot args, snapshot_fields f)
  | ISum (name, args) -> ISum (name, List.map snapshot args)
  | IFn (params, ret, row) -> IFn (List.map snapshot params, snapshot ret, row)
  | settled -> settled

and snapshot_fields (f : infer_fields) : infer_fields =
  match repr_fields f with
  | FCons (label, ty, rest) -> FCons (label, snapshot ty, snapshot_fields rest)
  | settled -> settled

(* Written nowhere: what a constructor says holds inside one arm, so it applies
   to what that arm sees rather than to the store. *)
let solve (pairs : (infer_ty * infer_ty) list) : (int * infer_ty) list option =
  let bindings = ref [] in
  let rec through t =
    match repr t with
    | IVar { contents = Unbound (id, _) } as unbound ->
      (match List.assoc_opt id !bindings with
       | Some bound -> through bound
       | None -> unbound)
    | settled -> settled
  in
  let rec agree a b =
    match through a, through b with
    | IVar { contents = Unbound (left, _) }, IVar { contents = Unbound (right, _) }
      when left = right -> true
    | IVar { contents = Unbound (id, _) }, other | other, IVar { contents = Unbound (id, _) } ->
      bindings := (id, other) :: !bindings;
      true
    | IInt, IInt | IFloat, IFloat | IStr, IStr | IByte, IByte | IChr, IChr
    | IBool, IBool | IUnit, IUnit -> true
    | ITuple xs, ITuple ys | IPack xs, IPack ys ->
      List.length xs = List.length ys && List.for_all2 agree xs ys
    | ISpread x, ISpread y -> agree x y
    | ISum (n, xs), ISum (m, ys) | INamed (n, xs, _), INamed (m, ys, _) ->
      String.equal n m && List.length xs = List.length ys && List.for_all2 agree xs ys
    | IFn (ps, r, _), IFn (qs, t, _) ->
      List.length ps = List.length qs && List.for_all2 agree ps qs && agree r t
    | _ -> false
  in
  if List.for_all (fun (a, b) -> agree a b) pairs
  then
    (* Chased through, so a binding never points at another binding's
       variable and one pass of [substitute] is enough. *)
    (let rec settle t =
       match through t with
       | ITuple items -> ITuple (List.map settle items)
       | IPack items -> IPack (List.map settle items)
       | ISpread inner -> ISpread (settle inner)
       | ISum (name, args) -> ISum (name, List.map settle args)
       | INamed (name, args, f) -> INamed (name, List.map settle args, f)
       | IFn (params, ret, row) -> IFn (List.map settle params, settle ret, row)
       | settled -> settled
     in
     Some
       (List.map
          (fun (id, _) -> id, settle (IVar (ref (Unbound (id, Any)))))
          !bindings))
  else None

let declare_pack (t : infer_ty) =
  match repr t with
  | IVar { contents = Unbound (id, _) } -> Hashtbl.replace declared_packs id ()
  | _ -> ()

let is_pack_param (t : infer_ty) =
  match repr t with
  | IVar { contents = Unbound (id, _) } -> Hashtbl.mem declared_packs id
  | IPack _ -> true
  | _ -> false

let declare_param (t : infer_ty) =
  match repr t with
  | IVar { contents = Unbound (id, _) } -> Hashtbl.replace declared_params id ()
  | _ -> ()

let var_id (t : infer_ty) =
  match repr t with
  | IVar { contents = Unbound (id, _) } -> id
  | other -> error "Not a type variable: %s." (string_of_infer_ty other)

let rec substitute mapping (t : infer_ty) : infer_ty =
  match repr t with
  | IVar { contents = Unbound (id, _) } as original ->
    (match List.assoc_opt id mapping with
     | Some replacement -> replacement
     | None -> original)
  | ITuple items -> ITuple (List.map (substitute mapping) items)
  | IPack items -> IPack (List.map (substitute mapping) items)
  | ISpread inner -> ISpread (substitute mapping inner)
  | IRecord f -> IRecord (substitute_fields mapping f)
  | INamed (name, args, f) ->
    INamed
      (name, List.map (substitute mapping) args, substitute_fields mapping f)
  | ISum (name, args) -> ISum (name, List.map (substitute mapping) args)
  | IFn (params, ret, row) ->
    IFn (List.map (substitute mapping) params, substitute mapping ret, row)
  | concrete -> concrete

and substitute_fields mapping (f : infer_fields) : infer_fields =
  match repr_fields f with
  | FCons (label, ty, rest) ->
    FCons (label, substitute mapping ty, substitute_fields mapping rest)
  | other -> other

let rec concrete_all (args : infer_ty list) : ty list option =
  List.fold_right
    (fun a acc -> Option.bind acc (fun acc -> Option.map (fun a -> a :: acc) (concrete a)))
    args
    (Some [])

and concrete (t : infer_ty) : ty option =
  let ( let* ) = Option.bind in
  match repr t with
  | IInt -> Some Int
  | IFloat -> Some Float
  | IStr -> Some Str
  | IByte -> Some Byte
  | IChr -> Some Chr
  | IBool -> Some Bool
  | IUnit -> Some Unit
  | ISum (name, args) ->
    let* args = concrete_all args in
    Some (Sum (name, args))
  | INamed (name, args, f) ->
    let* args = concrete_all args in
    let rec collect f =
      match repr_fields f with
      | FEmpty | FVar _ -> Some []
      | FCons (label, ty, rest) ->
        let* ty = concrete ty in
        let* rest = collect rest in
        Some ((label, ty) :: rest)
    in
    let* fields = collect f in
    Some (Named (name, args, List.sort compare fields))
  | IRecord f ->
    let rec collect f =
      match repr_fields f with
      | FEmpty -> Some []
      | FVar _ -> Some []
      | FCons (label, ty, rest) ->
        let* ty = concrete ty in
        let* rest = collect rest in
        Some ((label, ty) :: rest)
    in
    let* fields = collect f in
    Some (Record (List.sort compare fields))
  | ITuple items ->
    (match expand items with
     | [] -> Some Unit
     | items ->
       let* items = concrete_all items in
       Some (Tuple items))
  | IPack items ->
    let* items = concrete_all items in
    Some (Pack items)
  | ISpread inner ->
    let* inner = concrete inner in
    Some (Spread inner)
  | IFn (params, ret, row) ->
    let* params = concrete_all (expand params) in
    let* ret = concrete ret in
    let entries =
      List.filter_map
        (fun (label, args) ->
          let rec each acc = function
            | [] -> Some (List.rev acc)
            | a :: rest ->
              (match concrete a with
               | Some a -> each (a :: acc) rest
               | None -> None)
          in
          Option.map (fun args -> label, args) (each [] args))
        (fst (labels_of_infer_row row))
    in
    Some (Fn (params, ret, { labels = List.sort compare entries; tail = row_tail row }))
  | IVar _ -> None

let rec of_ty (t : ty) : infer_ty =
  match t with
  | Int -> IInt
  | Float -> IFloat
  | Str -> IStr
  | Byte -> IByte
  | Chr -> IChr
  | Bool -> IBool
  | Unit -> IUnit
  | Tuple items -> ITuple (List.map of_ty items)
  | Pack items -> IPack (List.map of_ty items)
  | Spread inner -> ISpread (of_ty inner)
  | Record fields ->
    IRecord
      (List.fold_right (fun (l, t) rest -> FCons (l, of_ty t, rest)) fields FEmpty)
  | Named (name, args, fields) ->
    INamed
      ( name
      , List.map of_ty args
      , List.fold_right (fun (l, t) rest -> FCons (l, of_ty t, rest)) fields FEmpty )
  | Sum (name, args) -> ISum (name, List.map of_ty args)
  | Fn (params, ret, row) ->
    IFn
      ( List.map of_ty params
      , of_ty ret
      , List.fold_right
          (fun (l, args) rest -> RCons (l, List.map of_ty args, rest))
          row.labels
          (match row.tail with
           | None -> REmpty
           | Some _ -> fresh_row ()) )
  | Generic _ -> fresh ()

(* ---- resolve ---- *)

(* Unbound numeric variables default to int; the rest stay polymorphic. *)
let rec resolve_row (r : infer_row) : row =
  let labels, _ = labels_of_infer_row r in
  { labels = List.sort compare (List.map (fun (l, args) -> l, List.map resolve args) labels)
  ; tail = row_tail r
  }

and resolve (t : infer_ty) : ty =
  match settle t with
  | IInt -> Int
  | IFloat -> Float
  | IStr -> Str
  | IByte -> Byte
  | IChr -> Chr
  | IBool -> Bool
  | IUnit -> Unit
  | ITuple items ->
    (match expand items with
     | [] -> Unit
     | items -> Tuple (List.map resolve items))
  | IPack items -> Pack (List.map resolve items)
  | ISpread inner -> Spread (resolve inner)
  | ISum (name, args) -> Sum (name, List.map resolve args)
  | IRecord f | INamed (_, _, f) ->
    let rec collect f =
      match repr_fields f with
      | FEmpty | FVar _ -> []
      | FCons (label, ty, rest) -> (label, resolve ty) :: collect rest
    in
    let fields = List.sort compare (collect f) in
    (match repr t with
     | INamed (name, args, _) -> Named (name, List.map resolve args, fields)
     | _ -> Record fields)
  | IFn (params, ret, row) ->
    Fn (List.map resolve (expand params), resolve ret, resolve_row row)
  | IVar { contents = Unbound (id, kind) } ->
    if Hashtbl.mem declared_params id
    then Generic id
    else (
      match kind with
      | Collection elem -> array (resolve elem)
      (* A bound is discharged by unification, so one still unbound here
         belongs to a definition nothing ever instantiated. *)
      | Bound _ -> Generic id
      | Projection _ -> Generic id
      | Any -> Generic id)
  | IVar { contents = Link _ } -> assert false (* repr collapsed these *)
