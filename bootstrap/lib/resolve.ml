(* A statement may expand into several: an `impl` is a group of functions
   written under one header. *)

(* A synthesized call claiming purity would be given no evidence. *)
let declared_rows : (string, Types.row) Hashtbl.t = Hashtbl.create 16

(* A vtable slot holds the impl's own function, so the entry's type is the one
   the method was checked at rather than one rebuilt from the call. *)
let declared_types : (string, Types.ty) Hashtbl.t = Hashtbl.create 16

(* A trait in type position is an object, and its methods dispatch at run time
   rather than through an entry chosen here. *)
let traits : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Every impl of a method was checked against the trait's signature, so any one
   of them says what a call through the vtable performs. *)
let trait_methods : (string * string, Types.ty) Hashtbl.t = Hashtbl.create 16

let supers : (string, string list) Hashtbl.t = Hashtbl.create 8

(* What a table for the trait owes a slot for, which [Verify] reads back. *)
let declared_methods : (string, string list) Hashtbl.t = Hashtbl.create 8

let row_of (t : Types.ty) =
  match t with
  | Types.Fn (_, _, row) -> row
  | _ -> Types.closed_row []

let rec record (s : Ast.typed_stmt) =
  match s.Ast.it with
  | `Trait_decl (name, _, body) ->
    Hashtbl.replace traits name ();
    Hashtbl.replace supers name (List.map fst body.Ast.tb_super);
    Hashtbl.replace
      declared_methods
      name
      (List.map (fun (m : Ast.method_sig) -> m.Ast.ms_name) body.Ast.tb_methods)
  | `Impl_decl (trait, type_name, _, impl) ->
    List.iter
      (fun (m : (Ast.typed_stmt, Types.ty) Ast.method_def) ->
        let entry = Ast.impl_method_name trait type_name m.Ast.md_name in
        Hashtbl.replace declared_rows entry (row_of m.Ast.md_ann);
        Hashtbl.replace declared_types entry m.Ast.md_ann;
        Option.iter
          (fun (name, _) -> Hashtbl.replace trait_methods (name, m.Ast.md_name) m.Ast.md_ann)
          trait;
        List.iter record m.Ast.md_body)
      impl.Ast.ib_methods
  | `Block body | `Fn (_, _, _, body) -> List.iter record body
  | `If (_, then_branch, else_branch) ->
    record then_branch;
    Option.iter record else_branch
  | `While (_, body) -> record body
  | `Run (body, handlers) ->
    List.iter record body;
    List.iter
      (fun (h : Ast.typed_stmt Ast.handler) ->
        List.iter
          (fun (a : Ast.typed_stmt Ast.arm) -> List.iter record a.Ast.arm_body)
          h.Ast.arms)
      handlers
  | `Match (_, cases) -> List.iter (fun (_, body) -> List.iter record body) cases
  | _ -> ()

type error =
  { span : Ast.span
  ; message : string
  }

exception Failed of error

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Failed { span; message })) fmt

let accessor registry (target : Ast.resolved_expr) (index : Ast.resolved_expr) pick =
  let by_index owner =
    Registry.indexed registry owner (Option.value (Types.type_name index.Ast.ann) ~default:"")
  in
  match Option.bind (Types.type_name target.Ast.ann) by_index with
  | Some entry ->
    (match pick entry with
     | Some name -> name
     | None ->
       fail target.Ast.span "%s cannot be assigned into." (Types.string_of_ty target.Ast.ann))
  | None ->
    fail target.Ast.span "Cannot index %s." (Types.string_of_ty target.Ast.ann)

let ordering_test (op : Ast.binop) =
  match op with
  | Ast.Less -> Some "__is_less"
  | Ast.Less_equal -> Some "__is_less_equal"
  | Ast.Greater -> Some "__is_greater"
  | Ast.Greater_equal -> Some "__is_greater_equal"
  | _ -> None

let ordering_result = Types.Sum ("Option", [ Types.Sum ("Ordering", []) ])

(* Where a `run` in expression position leaves the statements it lowers to, for
   the statement being resolved to splice in front of itself. *)
let hoisted : Ast.resolved_stmt list ref = ref []

let counter = ref 0

let fresh () =
  incr counter;
  Ast.generated [ "answer"; string_of_int !counter ]

(* A method reached through an object may be a supertrait's, and the impl that
   registered it did so under the trait that declared it. *)
let rec method_type trait name =
  match Hashtbl.find_opt trait_methods (trait, name) with
  | Some ty -> Some ty
  | None ->
    List.find_map
      (fun super -> method_type super name)
      (Option.value ~default:[] (Hashtbl.find_opt supers trait))

let is_trait name = Hashtbl.mem traits name

let rec methods_of trait =
  Option.value ~default:[] (Hashtbl.find_opt declared_methods trait)
  @ List.concat_map methods_of (Option.value ~default:[] (Hashtbl.find_opt supers trait))

let is_object (t : Types.ty) =
  match Types.type_name t with
  | Some name -> Hashtbl.mem traits name
  | None -> false

let rec expr registry (e : Ast.typed_expr) : Ast.resolved_expr =
  let span = e.Ast.span
  and ann = e.Ast.ann in
  let it : Ast.resolved_expr_kind =
    match e.Ast.it with
    (* No in-place entry exists, so it derives from the plain operator. *)
    | `Compound (op, name, v) ->
      let target : Ast.resolved_expr = { Ast.it = `Var name; span; ann } in
      let combined : Ast.resolved_expr =
        { Ast.it = `Binop (op, target, expr registry v); span; ann }
      in
      `Assign (name, combined)
    | `Unop (Ast.Neg, a) ->
      let a = expr registry a in
      (match Registry.find_unary registry Ast.Neg a.Ast.ann with
       | Some { Registry.emit = Registry.Call name; _ } ->
         `Call (fn_ref span name [ a ] ann, [ a ])
       | Some { Registry.emit = Registry.Primitive; _ } | None -> `Unop (Ast.Neg, a))
    | `Binop (op, a, b) ->
      let a = expr registry a
      and b = expr registry b in
      (match Registry.find registry op a.Ast.ann b.Ast.ann with
       (* The method answers with an `Ordering`; which comparison was written
          decides how that becomes a bool. *)
       | Some { Registry.emit = Registry.Call name; _ } when ordering_test op <> None ->
         let compared : Ast.resolved_expr =
           { Ast.it = `Call (fn_ref span name [ a; b ] ordering_result, [ a; b ])
           ; span
           ; ann = ordering_result
           }
         in
         let test = Option.get (ordering_test op) in
         `Call (fn_ref span test [ compared ] Types.Bool, [ compared ])
       (* One entry answers both, since a type that says what equal means has
          said what unequal means. *)
       | Some { Registry.emit = Registry.Call name; _ } when op = Ast.Not_equal ->
         let equal : Ast.resolved_expr =
           { Ast.it = `Call (fn_ref span name [ a; b ] Types.Bool, [ a; b ])
           ; span
           ; ann = Types.Bool
           }
         in
         `Unop (Ast.Not, equal)
       | Some { Registry.emit = Registry.Call name; _ } ->
         `Call (fn_ref span name [ a; b ] ann, [ a; b ])
       (* Spelled out, so a third emission form has to be decided here. *)
       | Some { Registry.emit = Registry.Primitive; _ } | None -> `Binop (op, a, b))
    | `Coerce (inner, trait, methods) ->
      let data = expr registry inner in
      let owner =
        match Types.type_name data.Ast.ann with
        | Some owner -> owner
        | None ->
          fail
            data.Ast.span
            "%s cannot become a '%s': it has no type to dispatch on."
            (Types.string_of_ty data.Ast.ann)
            trait
      in
      let slot name : string * Ast.resolved_expr =
        let entry = Registry.entry_for_method registry owner name in
        ( name
        , { Ast.it = `Var entry
          ; span
          ; ann =
              (match Hashtbl.find_opt declared_types entry with
               | Some ty -> ty
               | None ->
                 fail span "'%s' has no '%s' to put in a '%s'." owner name trait)
          } )
      in
      `Object (data, List.map slot methods)
    | `Method_call (receiver, name, _, args) when is_object receiver.Ast.ann ->
      let receiver = expr registry receiver in
      let performs =
        match Option.bind (Types.type_name receiver.Ast.ann) (fun t -> method_type t name) with
        | Some ty -> ty
        (* A purity this could not check would be evidence the call never
           passes. *)
        | None -> fail span "No impl of '%s' was registered to dispatch on." name
      in
      `Dyn_call (receiver, name, performs, arguments registry args)
    | `Method_call (receiver, name, _, args) ->
      let receiver = expr registry receiver in
      let args = arguments registry args in
      let owner =
        match Types.type_name receiver.Ast.ann with
        | Some owner -> owner
        | None ->
          fail
            receiver.Ast.span
            "Cannot call '%s': the receiver's type is not known here."
            name
      in
      (* A receiver the checker could not name is an array by here. *)
      if String.equal name Types.array_len && args = [] && Types.is_array receiver.Ast.ann
      then `Array_len receiver
      else if String.equal name Types.array_len && args = [] && receiver.Ast.ann = Types.Str
      then `Str_len receiver
      else (
                let all =
          if Registry.is_associated registry owner name then args else receiver :: args
        in
        `Call (fn_ref span (Registry.entry_for_method registry owner name) all ann, all))
    | `Collection_lit items ->
      let items = List.map (expr registry) items in
      if Types.is_array ann
      then `Array_lit items
      else (
        let unbuildable () =
          fail span "%s cannot be built from a literal." (Types.string_of_ty ann)
        in
        match Types.type_name ann with
        | None -> unbuildable ()
        (* What it holds comes from the entry rather than from its arity. *)
        | Some name ->
          (match Registry.container registry name, Registry.container_element registry name (Types.of_ty ann) with
           | Some make, Some element ->
             let elements : Ast.resolved_expr =
               { Ast.it = `Array_lit items
               ; span
               ; ann = Types.array (Types.resolve element)
               }
             in
             `Call (fn_ref span make.Registry.entry [ elements ] ann, [ elements ])
           | _ -> unbuildable ()))
    | `Index (target, index) ->
      let target = expr registry target
      and index = expr registry index in
      (* Anything but an int is an entry the type declared, a range included. *)
      if index.Ast.ann <> Types.Int
      then (
        let name = accessor registry target index (fun entry -> entry.Registry.get) in
        `Call (fn_ref span name [ target; index ] ann, [ target; index ]))
      else if target.Ast.ann = Types.Str
      then `Str_get (target, index)
      else if Types.is_array target.Ast.ann
      then `Array_get (target, index)
      else (
        let name = accessor registry target index (fun entry -> entry.Registry.get) in
        `Call (fn_ref span name [ target; index ] ann, [ target; index ]))
    | `Index_assign (target, index, v) ->
      let target = expr registry target
      and index = expr registry index
      and v = expr registry v in
      if Types.is_array target.Ast.ann
      then `Array_set (target, index, v)
      else (
        let args = [ target; index; v ] in
        let name = accessor registry target index (fun entry -> entry.Registry.set) in
        `Call (fn_ref span name args ann, args))
    | #Ast.lit as l -> l
    | #Ast.arrays as a -> (Ast.map_arrays (expr registry) a :> Ast.resolved_expr_kind)
    | #Ast.strings as s -> (Ast.map_strings (expr registry) s :> Ast.resolved_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars (expr registry) v :> Ast.resolved_expr_kind)
    | `Call (callee, args) -> `Call (expr registry callee, arguments registry args)
    (* Only an argument list holds one, and [arguments] is what takes it
       apart. *)
    | `Spread _ -> assert false
    | #Ast.ops as o -> (Ast.map_ops (expr registry) o :> Ast.resolved_expr_kind)
    | #Ast.logic as l -> (Ast.map_logic (expr registry) l :> Ast.resolved_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple (expr registry) t :> Ast.resolved_expr_kind)
        | `New_call _ -> assert false
    | `New (_, fields) ->
      `Record_lit (List.map (fun (l, v) -> l, expr registry v) fields)
    | `New_variant (_, variant, payload) ->
      `Variant
        (variant, List.map (fun (l, v) -> l, expr registry v) (Ast.payload_fields payload))
    | #Ast.record as r ->
      (Ast.map_record (expr registry) r :> Ast.resolved_expr_kind)
    | `Lambda (params, signature, body) ->
      `Lambda (params, signature, List.concat_map (stmt registry) body)
    | `Run_expr (body, handlers, clause) ->
      let answer = fresh () in
      let at (n : Ast.resolved_expr) it : Ast.resolved_stmt =
        { Ast.it; span = n.Ast.span; ann = n.Ast.ann }
      in
      let answered (value : Ast.resolved_expr) =
        [ at value (`Expr { value with Ast.it = `Assign (answer, value) }) ]
      in
      let body_stmts, body_value = valued registry body in
      let tail =
        match clause with
        | None -> Option.fold ~none:[] ~some:answered body_value
        | Some c ->
          let stmts, value = valued registry c.Ast.rc_body in
          [ { Ast.it =
                `Block
                  (({ Ast.it = `Var_decl (c.Ast.rc_param, None, body_value)
                    ; span
                    ; ann = Option.fold ~none:Types.Unit ~some:(fun v -> v.Ast.ann) body_value
                    }
                    :: stmts)
                   @ Option.fold ~none:[] ~some:answered value)
            ; span
            ; ann
            }
          ]
      in
      let run : Ast.resolved_stmt =
        { Ast.it =
            `Run
              ( body_stmts @ tail
              , List.map
                  (fun h ->
                    let h = handler registry h in
                    { h with
                      Ast.arms =
                        List.map
                          (fun (a : Ast.resolved_stmt Ast.arm) ->
                            match a.Ast.arm_kind with
                            | Ast.Op_fn -> a
                            | Ast.Op_ctl | Ast.Op_final ->
                              { a with
                                Ast.arm_body = List.map (answering answer) a.Ast.arm_body
                              })
                          h.Ast.arms
                    })
                  handlers )
        ; span
        ; ann
        }
      in
      hoisted := run :: { Ast.it = `Var_decl (answer, None, None); span; ann } :: !hoisted;
      `Var answer
    | #Ast.reflect as r ->
      (Ast.map_reflect (expr registry) r :> Ast.resolved_expr_kind)
  in
  (* The length intrinsics answer with an int whatever the caller pinned. *)
  let ann =
    match it with
    | `Array_len _ | `Str_len _ -> Types.Int
    | _ -> ann
  in
  { Ast.it; span; ann }

(* Whatever the value expression hoists belongs inside the block, in front of it. *)
and valued registry (b : (Ast.typed_expr, Ast.typed_stmt) Ast.valued_block) =
  let stmts = block registry b.Ast.vb_stmts in
  match b.Ast.vb_value with
  | None -> stmts, None
  | Some v ->
    let saved = !hoisted in
    hoisted := [];
    let v = expr registry v in
    let before = List.rev !hoisted in
    hoisted := saved;
    stmts @ before, Some v

(* A `return` in an arm is the answer for the whole block. A nested function's
   is its own, and a nested `run`'s arms already answered for theirs. *)
and answering answer (s : Ast.resolved_stmt) : Ast.resolved_stmt =
  let same it = { s with Ast.it = it } in
  let inner = answering answer in
  match s.Ast.it with
  | `Return (Some v) ->
    same
      (`Block
        [ { Ast.it = `Expr { v with Ast.it = `Assign (answer, v) }
          ; span = v.Ast.span
          ; ann = v.Ast.ann
          }
        ; same (`Return None)
        ])
  | `Block body -> same (`Block (List.map inner body))
  | `If (cond, t, e) -> same (`If (cond, inner t, Option.map inner e))
  | `While (cond, body) -> same (`While (cond, inner body))
  | `Defer body -> same (`Defer (inner body))
  | `Match (scrutinee, cases) ->
    same (`Match (scrutinee, List.map (fun (p, body) -> p, List.map inner body) cases))
  | `Run (body, handlers) -> same (`Run (List.map inner body, handlers))
  | _ -> s

and fn_ref span name args result : Ast.resolved_expr =
  { Ast.it = `Var name
  ; span
  ; ann =
      Types.Fn
        ( List.map (fun (a : Ast.resolved_expr) -> a.Ast.ann) args
        , result
        , Option.value ~default:(Types.closed_row []) (Hashtbl.find_opt declared_rows name) )
  }

(* A tuple spread into an argument list is as many arguments as it holds, and
   [Type_mono] has already settled how many. *)
and arguments registry (args : Ast.typed_expr list) : Ast.resolved_expr list =
  List.concat_map
    (fun (a : Ast.typed_expr) ->
      match a.Ast.it with
      | `Spread inner ->
        let held =
          match inner.Ast.ann with
          | Types.Tuple items -> List.length (Types.expand_ty items)
          | Types.Unit -> 0
          | other ->
            fail
              inner.Ast.span
              "A spread takes a tuple, not %s."
              (Types.string_of_ty other)
        in
        let inner = expr registry inner in
        List.init
          held
          (fun index ->
            let ann =
              match inner.Ast.ann with
              | Types.Tuple items -> List.nth (Types.expand_ty items) index
              | _ -> assert false
            in
            { Ast.it = `Tuple_get (inner, index); span = a.Ast.span; ann })
      | _ -> [ expr registry a ])
    args

and stmt registry (s : Ast.typed_stmt) : Ast.resolved_stmt list =
  let saved = !hoisted in
  hoisted := [];
  let produced = stmt_of registry s in
  let before = List.rev !hoisted in
  hoisted := saved;
  before @ produced

(* Every statement list here goes through [block], never [one]: wrapping a
   declaration in a block would scope its name away from what follows. *)
and stmt_of registry (s : Ast.typed_stmt) : Ast.resolved_stmt list =
  let span = s.Ast.span
  and ann = s.Ast.ann in
  let node it : Ast.resolved_stmt = { Ast.it; span; ann } in
  match s.Ast.it with
  (* Its answer goes nowhere, so it needs no name to go by. *)
  | `Expr ({ Ast.it = `Run_expr _; _ } as inner) ->
    ignore (expr registry inner);
    []
  (* [`Block] and [`Fn] hold statement lists, where an expansion can land. *)
  | `Block body -> [ node (`Block (block registry body)) ]
  | `Fn (name, params, signature, body) ->
    [ node (`Fn (name, params, signature, block registry body)) ]
  | #Ast.stmts as st ->
    [ node (Ast.map_stmts (expr registry) (one registry) st :> Ast.resolved_stmt_kind) ]
  | `Run (body, handlers) ->
    [ node (`Run (block registry body, List.map (handler registry) handlers)) ]
  | #Ast.effects as e ->
    [ node
        (Ast.map_effects (expr registry) (one registry) (Ast.map_handler (one registry)) e
         :> Ast.resolved_stmt_kind)
    ]
  | `Impl_decl (trait, type_name, _, impl) ->
    List.map
      (fun (m : (Ast.typed_stmt, Types.ty) Ast.method_def) ->
        { Ast.it =
            (`Fn
            ( Ast.impl_method_name trait type_name m.Ast.md_name
            , m.Ast.md_params
            , m.Ast.md_signature
              , block registry m.Ast.md_body )
             :> Ast.resolved_stmt_kind)
        ; span
        ; ann = m.Ast.md_ann
        })
      impl.Ast.ib_methods
  | `Trait_decl _ -> []
  | #Ast.type_defs as t -> [ node t ]
  | `Match (scrutinee, cases) ->
    [ node
        (`Match
          ( expr registry scrutinee
          , List.map (fun (pattern, body) -> pattern, block registry body) cases ))
    ]

and handler registry (h : Ast.typed_stmt Ast.handler) : Ast.resolved_stmt Ast.handler =
  { Ast.handled = h.Ast.handled
  ; arms =
      List.map
        (fun (a : Ast.typed_stmt Ast.arm) ->
          { Ast.arm_name = a.Ast.arm_name
          ; arm_kind = a.Ast.arm_kind
          ; arm_params = a.Ast.arm_params
          ; arm_body = block registry a.Ast.arm_body
          })
        h.Ast.arms
  }

and block registry body = List.concat_map (stmt registry) body

and one registry (s : Ast.typed_stmt) : Ast.resolved_stmt =
  match stmt registry s with
  | [ single ] -> single
  | many -> { Ast.it = `Block many; span = s.Ast.span; ann = s.Ast.ann }

let program ~registry (p : Ast.typed_stmt list)
  : (Ast.resolved_stmt list, error) result
  =
  Hashtbl.reset declared_rows;
  Hashtbl.reset declared_types;
  Hashtbl.reset traits;
  Hashtbl.reset trait_methods;
  Hashtbl.reset supers;
  Hashtbl.reset declared_methods;
  List.iter record p;
  try Ok (block registry p) with
  | Failed e -> Error e
