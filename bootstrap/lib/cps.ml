(* Two translations, chosen per effect by its declaration: continuations when
   it has a `ctl` operation, evidence passing otherwise. *)

type error =
  { span : Ast.span
  ; message : string
  }

exception Unsupported of error

let unsupported span fmt =
  Printf.ksprintf (fun message -> raise (Unsupported { span; message })) fmt

type effects =
  { owner : (string, string) Hashtbl.t (* operation -> effect *)
  ; operations : (string, string list) Hashtbl.t (* effect -> operations *)
  ; delimited : (string, unit) Hashtbl.t (* effects needing continuations *)
  ; op_ty : (string, Types.ty) Hashtbl.t (* operation -> its function type *)
  (* Which evidence a `perform` currently reaches: the innermost `run` that
     installed a handler for it, rather than the one name the operation has. *)
  ; bound : (string, string) Hashtbl.t
  (* Where a `return` leaves its value when it has a `run` block to get out of
     first, and the flag saying it did. *)
  ; mutable leaving : (string * string) option
  (* Whether the statement being compiled sits inside a `run` the enclosing
     function has not left. *)
  ; mutable inside_run : bool
  }

let evidence_name op = Ast.generated [ "ev"; op ]

(* A converted function receives its evidence as parameters under the canonical
   name; a `run` inside it installs its own. Two `run` blocks live in one
   expression often enough -- `run { … } + run { … }` -- that sharing one name
   per operation lets the second quietly answer for the first. *)
let evidence_var info op =
  match Hashtbl.find_opt info.bound op with
  | Some name -> name
  | None -> evidence_name op

let with_bound info names f =
  let saved = List.map (fun (op, _) -> op, Hashtbl.find_opt info.bound op) names in
  List.iter (fun (op, name) -> Hashtbl.replace info.bound op name) names;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (op, previous) ->
          match previous with
          | Some name -> Hashtbl.replace info.bound op name
          | None -> Hashtbl.remove info.bound op)
        saved)
    f

(* Converted code whose enclosing function was left unconverted, because
   handling the effect discharged its row. A `return` there has no continuation
   to call and leaves the frames the pass made instead. *)
let no_return = Ast.generated [ "cps"; "no-return" ]
let continuation = Ast.generated [ "cps"; "k" ]
let counter = ref 0

let fresh prefix =
  incr counter;
  Ast.generated [ prefix; string_of_int !counter ]

(* Sorted, so caller and callee agree without communicating. *)
let evidence_of_row info (row : Types.row) =
  row.Types.labels
  |> List.map fst
  |> List.sort_uniq String.compare
  |> List.concat_map (fun label ->
    match Hashtbl.find_opt info.operations label with
    | Some ops -> ops
    | None -> [])
  |> List.sort_uniq String.compare

let row_of (t : Types.ty) =
  match t with
  | Types.Fn (_, _, row) -> row
  | _ -> Types.closed_row []

let is_effectful info (t : Types.ty) = evidence_of_row info (row_of t) <> []

let evidence_ty info op =
  match Hashtbl.find_opt info.op_ty op with
  | Some t -> t
  | None -> Types.Unit

let is_delimited info (row : Types.row) =
  List.exists (fun (label, _) -> Hashtbl.mem info.delimited label) row.Types.labels

(* Whether a `run` needs continuations is settled by the effects it handles and
   not by the arms it was written with: the functions it runs were compiled
   against the declaration, and a handler that happens to resume in tail
   position cannot change what they expect. *)
let handlers_delimited info handlers =
  List.exists
    (fun (h : _ Ast.handler) -> Hashtbl.mem info.delimited h.Ast.handled)
    handlers

(* The type gains the evidence parameters too, or it describes the wrong
   arity. *)
let rec widen info (t : Types.ty) =
  match t with
  | Types.Fn (params, ret, row) ->
    (* A converted function takes its continuation last: handed the result, and
       answering with nothing, since a converted call is a statement. Not the
       block's own type — that reaches its `run` by another route. *)
    let continuation =
      if is_delimited info row
      then [ Types.Fn ([ widen info ret ], Types.Unit, Types.closed_row []) ]
      else []
    in
    Types.Fn
      ( (List.map (widen info) params
         @ List.map (evidence_ty info) (evidence_of_row info row))
        @ continuation
      , widen info ret
      , row )
  | Types.Tuple items -> Types.Tuple (List.map (widen info) items)
  | Types.Record fields -> Types.Record (widen_fields info fields)
  | Types.Named (name, args, fields) ->
    Types.Named (name, List.map (widen info) args, widen_fields info fields)
  | Types.Sum (name, args) -> Types.Sum (name, List.map (widen info) args)
  | other -> other

and widen_fields info fields = List.map (fun (label, t) -> label, widen info t) fields

let node span it : Ast.cps_stmt = { Ast.it; span; ann = Types.Unit }
let var span ty name : Ast.cps_expr = { Ast.it = `Var name; span; ann = ty }

let ignored span : Ast.cps_expr = { Ast.it = `Bool false; span; ann = Types.Bool }

let call ?(result = Types.Unit) span callee args =
  let callee_ty =
    Types.Fn (List.map (fun (a : Ast.cps_expr) -> a.Ast.ann) args, result, Types.closed_row [])
  in
  node
    span
    (`Expr { Ast.it = `Call (var span callee_ty callee, args); span; ann = result })

(* The pass's own functions: pieces of a converted body, not functions the
   source wrote. *)
let frame_decl span name params body =
  node
    span
    (`Frame
      ( name
      , List.map (fun p -> { Ast.name = p; ty = None; implicit = false }) params
      , body ))

(* An arm reached without a continuation is an ordinary function, and a
   `return` written in it returns from the arm. *)
let arm_decl span name params body =
  node
    span
    (`Fn
      ( name
      , List.map (fun p -> { Ast.name = p; ty = None; implicit = false }) params
      , { Ast.ret = None; row = None; static_params = [] }
      , body ))

let cont_decl span name params body =
  node
    span
    (`Cont
      (name, List.map (fun p -> { Ast.name = p; ty = None; implicit = false }) params, body))

(* ---- tail-resumptive detection ---- *)

let rec count pick (body : Ast.reflected_stmt list) =
  List.fold_left (fun n s -> n + count_in pick s) 0 body

and count_in pick (s : Ast.reflected_stmt) =
  (if pick s then 1 else 0)
  +
  match s.Ast.it with
  | `Block body | `Fn (_, _, _, body) | `Run (body, _) -> count pick body
  | `If (_, t, e) ->
    count_in pick t + (match e with Some e -> count_in pick e | None -> 0)
  | `While (_, body) -> count_in pick body
  | `Match (_, cases) ->
    List.fold_left (fun n (_, body) -> n + count pick body) 0 cases
  | `Defer inner -> count_in pick inner
  | _ -> 0

let is_resume (s : Ast.reflected_stmt) =
  match s.Ast.it with
  | `Resume _ -> true
  | _ -> false

(* Left alone, its value never reaches the continuation. *)
let rec holds_return (s : Ast.reflected_stmt) =
  match s.Ast.it with
  | `Return _ -> true
  | `Block body -> List.exists holds_return body
  | `If (_, t, e) -> holds_return t || Option.fold ~none:false ~some:holds_return e
  | `While (_, body) -> holds_return body
  | `Match (_, cases) -> List.exists (fun (_, body) -> List.exists holds_return body) cases
  | `Defer inner -> holds_return inner
  | _ -> false

let is_return (s : Ast.reflected_stmt) =
  match s.Ast.it with
  | `Return _ -> true
  | _ -> false

(* A `ctl` arm resuming exactly once, last, behaves like a `fn` arm. Koka
   calls this bind-inversion. *)
let tail_resumptive (body : Ast.reflected_stmt list) =
  match List.rev body with
  | ({ Ast.it = `Resume value; _ } as last) :: earlier
    when count is_resume body = 1 && count is_return body = 0 ->
    Some (List.rev ({ last with Ast.it = `Return value } :: earlier))
  | _ -> None

(* "Needs no continuation" rather than "resumes in tail position": a `final ctl`
   never resumes, and what it needs is an unwind. *)
let arm_needs_no_continuation (a : Ast.reflected_stmt Ast.arm) =
  match a.Ast.arm_kind with
  | Ast.Op_fn | Ast.Op_final -> true
  | Ast.Op_ctl -> tail_resumptive a.Ast.arm_body <> None

let handlers_are_tail_resumptive handlers =
  List.for_all
    (fun (h : Ast.reflected_stmt Ast.handler) ->
      List.for_all arm_needs_no_continuation h.Ast.arms)
    handlers

(* ---- expressions ---- *)

let convert_body : (effects -> Ast.reflected_stmt list -> Ast.cps_stmt list) ref =
  ref (fun _ _ -> [])

(* [cps] is written below [expr], and a lambda that suspends needs it. *)
let convert_cps
  : (effects -> string -> Ast.span -> Ast.reflected_stmt list -> Ast.cps_stmt list) ref
  =
  ref (fun _ _ _ _ -> [])

let rec expr info (e : Ast.reflected_expr) : Ast.cps_expr =
  let widened = ref (widen info e.Ast.ann) in
  let it : Ast.cps_expr_kind =
    match e.Ast.it with
    | #Ast.lit as l -> l
    (* A call site passes the same arguments whichever it reached. *)
    | `Lambda (params, signature, body) ->
      let row = row_of e.Ast.ann in
      let evidence =
        evidence_of_row info row
        |> List.map (fun op -> { Ast.name = evidence_name op; ty = None; implicit = false })
      in
      widened := widen info e.Ast.ann;
      if is_delimited info row
      then (
        (* Its own name, so a `resume` written here still reaches the arm's. *)
        let own = fresh "k" in
        `Lambda
          ( params @ evidence @ [ { Ast.name = own; ty = None; implicit = false } ]
          , signature
          , !convert_cps info own e.Ast.span body ))
      else `Lambda (params @ evidence, signature, !convert_body info body)
    | `Var name ->
      (* A bare reference would escape with the wrong arity. *)
      widened := widen info e.Ast.ann;
      `Var name
    | `Call (callee, args) ->
      let args = List.map (expr info) args in
      (match callee.Ast.it with
       | `Var name when Hashtbl.mem info.owner name ->
         let ty =
           Types.Fn
             (List.map (fun (a : Ast.cps_expr) -> a.Ast.ann) args, e.Ast.ann, Types.closed_row [])
         in
         `Call (var callee.Ast.span ty (evidence_var info name), args)
       | _ ->
         let evidence =
           evidence_of_row info (row_of callee.Ast.ann)
           |> List.map (fun op -> var e.Ast.span (evidence_ty info op) (evidence_var info op))
         in
         let callee =
           match callee.Ast.it with
           | `Var name ->
             { Ast.it = `Var name
             ; span = callee.Ast.span
             ; ann = widen info callee.Ast.ann
             }
           | _ -> expr info callee
         in
         `Call (callee, args @ evidence))
    | #Ast.arrays as a -> (Ast.map_arrays (expr info) a :> Ast.cps_expr_kind)
    | #Ast.strings as s -> (Ast.map_strings (expr info) s :> Ast.cps_expr_kind)
    | #Ast.vars as v -> (Ast.map_vars (expr info) v :> Ast.cps_expr_kind)
    | #Ast.ops as o -> (Ast.map_ops (expr info) o :> Ast.cps_expr_kind)
    | #Ast.logic as l -> (Ast.map_logic (expr info) l :> Ast.cps_expr_kind)
    | #Ast.tuple as t -> (Ast.map_tuple (expr info) t :> Ast.cps_expr_kind)
    | #Ast.record as r -> (Ast.map_record (expr info) r :> Ast.cps_expr_kind)
    | #Ast.variant_lit as v -> (Ast.map_variant_lit (expr info) v :> Ast.cps_expr_kind)
    (* The slot holds a converted function, so the call owes it the same
       evidence a named call to that impl would have passed. *)
    | `Dyn_call (receiver, name, performs, args) ->
      let receiver = expr info receiver in
      let args = List.map (expr info) args in
      let evidence =
        evidence_of_row info (row_of performs)
        |> List.map (fun op -> var e.Ast.span (evidence_ty info op) (evidence_var info op))
      in
      `Dyn_call (receiver, name, performs, args @ evidence)
    | #Ast.objects as o -> (Ast.map_object (expr info) o :> Ast.cps_expr_kind)
  in
  { Ast.it; span = e.Ast.span; ann = !widened }

let rec suspends info (e : Ast.reflected_expr) =
  match e.Ast.it with
  | `Lambda _ | #Ast.lit | `Var _ -> false
  | `Call (callee, args) ->
    (match callee.Ast.it with
     | `Var name when Hashtbl.mem info.owner name ->
       Hashtbl.mem info.delimited (Hashtbl.find info.owner name)
     | _ -> is_delimited info (row_of callee.Ast.ann))
    || List.exists (suspends info) args
  | `Assign (_, v) | `Unop (_, v) -> suspends info v
  | `Binop (_, a, b) | `And (a, b) | `Or (a, b) ->
    suspends info a || suspends info b
  | `Tuple items | `Array_lit items -> List.exists (suspends info) items
  | `Array_new (a, b) | `Array_get (a, b) -> suspends info a || suspends info b
  | `Array_set (target, index, v) ->
    suspends info target || suspends info index || suspends info v
  | `Str_get (a, b) -> suspends info a || suspends info b
  | `Array_len t | `Str_len t | `Tuple_get (t, _) | `Field (t, _) -> suspends info t
  | `Record_lit fields | `Variant (_, fields) ->
    List.exists (fun (_, v) -> suspends info v) fields
  | `Field_assign (r, _, v) -> suspends info r || suspends info v
  (* A vtable hides which body answers, so whether it suspends is not a
     question the row on this call site can be asked. *)
  | `Object (data, _) -> suspends info data
  | `Dyn_call (receiver, _, performs, args) ->
    is_delimited info (row_of performs)
    || suspends info receiver
    || List.exists (suspends info) args

let rec suspends_stmt info (s : Ast.reflected_stmt) =
  match s.Ast.it with
  | `Expr e | `Return (Some e) | `Var_decl (_, _, Some e) -> suspends info e
  | `Block body -> List.exists (suspends_stmt info) body
  | `If (c, t, e) ->
    suspends info c
    || suspends_stmt info t
    || (match e with
        | Some e -> suspends_stmt info e
        | None -> false)
  | `While (c, body) -> suspends info c || suspends_stmt info body
  | `Resume _ -> true
  | `Run (_, handlers) -> handlers_delimited info handlers
  | `Match (scrutinee, cases) ->
    suspends info scrutinee
    || List.exists (fun (_, body) -> List.exists (suspends_stmt info) body) cases
  | `Defer inner -> suspends_stmt info inner
  | _ -> false

(* A call whose own arguments are already settled, so the operation it performs
   is the next thing that happens. *)
let ready_call info (e : Ast.reflected_expr) =
  match e.Ast.it with
  | `Call (_, args) | `Dyn_call (_, _, _, args) ->
    suspends info e && not (List.exists (suspends info) args)
  | _ -> false

let suspending_logic info (e : Ast.reflected_expr) =
  match e.Ast.it with
  | `And _ | `Or _ -> suspends info e
  | _ -> false

(* [select] names the subexpression to pull out; everything before it in
   evaluation order stays where it is. *)
let rec extract_with select info (e : Ast.reflected_expr)
  : (Ast.reflected_expr * (string -> Ast.reflected_expr)) option
  =
  let rebuild it : Ast.reflected_expr = { e with Ast.it = it } in
  let extract_list = extract_list select in
  let extract info = extract_with select info in
  match e.Ast.it with
  | _ when select info e ->
    Some (e, fun name -> { Ast.it = `Var name; span = e.Ast.span; ann = e.Ast.ann })
  | #Ast.lit | `Var _ | `Lambda _ -> None
  | `Object _ -> None
  | `Dyn_call (receiver, name, performs, args) ->
    extract_list info args (fun args -> rebuild (`Dyn_call (receiver, name, performs, args)))
  | `Call (callee, args) -> extract_list info args (fun args -> rebuild (`Call (callee, args)))
  | `Tuple items -> extract_list info items (fun items -> rebuild (`Tuple items))
  | `Array_lit items -> extract_list info items (fun items -> rebuild (`Array_lit items))
  | `Array_new (length, fill) ->
    extract_list info [ length; fill ] (function
      | [ length; fill ] -> rebuild (`Array_new (length, fill))
      | _ -> assert false)
  | `Array_get (target, index) ->
    extract_list info [ target; index ] (function
      | [ target; index ] -> rebuild (`Array_get (target, index))
      | _ -> assert false)
  | `Array_set (target, index, v) ->
    extract_list info [ target; index; v ] (function
      | [ target; index; v ] -> rebuild (`Array_set (target, index, v))
      | _ -> assert false)
  | `Array_len target ->
    extract info target |> Option.map (fun (c, f) -> c, fun n -> rebuild (`Array_len (f n)))
  | `Str_len target ->
    extract info target |> Option.map (fun (c, f) -> c, fun n -> rebuild (`Str_len (f n)))
  | `Str_get (target, index) ->
    extract_list info [ target; index ] (function
      | [ target; index ] -> rebuild (`Str_get (target, index))
      | _ -> assert false)
  | `Tuple_get (t, i) ->
    extract info t |> Option.map (fun (c, f) -> c, fun n -> rebuild (`Tuple_get (f n, i)))
  | `Field (t, label) ->
    extract info t |> Option.map (fun (c, f) -> c, fun n -> rebuild (`Field (f n, label)))
  | `Record_lit fields ->
    extract_fields select info fields (fun fields -> rebuild (`Record_lit fields))
  | `Variant (name, fields) ->
    extract_fields select info fields (fun fields -> rebuild (`Variant (name, fields)))
  | `Field_assign (target, label, v) ->
    extract_list info [ target; v ] (function
      | [ target; v ] -> rebuild (`Field_assign (target, label, v))
      | _ -> assert false)
  | `Assign (name, v) ->
    extract info v |> Option.map (fun (c, f) -> c, fun n -> rebuild (`Assign (name, f n)))
  | `Unop (op, v) ->
    extract info v |> Option.map (fun (c, f) -> c, fun n -> rebuild (`Unop (op, f n)))
  | `Binop (op, a, b) ->
    extract_list info [ a; b ] (function
      | [ a; b ] -> rebuild (`Binop (op, a, b))
      | _ -> assert false)
  (* Only the left operand is reached unconditionally, so only it can be
     hoisted; a suspension on the right is split into an `if` first. *)
  | `And (a, b) ->
    extract info a |> Option.map (fun (c, f) -> c, fun n -> rebuild (`And (f n, b)))
  | `Or (a, b) ->
    extract info a |> Option.map (fun (c, f) -> c, fun n -> rebuild (`Or (f n, b)))

and extract_list select info items rebuild =
  let rec loop before = function
    | [] -> None
    | item :: after ->
      (match extract_with select info item with
       | Some (c, f) -> Some (c, fun name -> rebuild (List.rev before @ [ f name ] @ after))
       | None -> loop (item :: before) after)
  in
  loop [] items

and extract_fields select info fields rebuild =
  extract_list select info (List.map snd fields) (fun values ->
    rebuild (List.map2 (fun (label, _) v -> label, v) fields values))

let extract info = extract_with ready_call info
let extract_logic info = extract_with suspending_logic info

(* The expression a statement evaluates first. A control statement is missing
   here on purpose: its condition already reaches [controlled_by], which is
   where it is evaluated once per iteration rather than once. *)
let leading_expr (s : Ast.reflected_stmt)
  : (Ast.reflected_expr * (Ast.reflected_expr -> Ast.reflected_stmt_kind)) option
  =
  match s.Ast.it with
  | `Expr e -> Some (e, fun e -> `Expr e)
  | `Var_decl (name, ty, Some e) -> Some (e, fun e -> `Var_decl (name, ty, Some e))
  | `Return (Some e) -> Some (e, fun e -> `Return (Some e))
  | _ -> None

(* The `and`/`or` a statement evaluates first, paired with the statement put
   back together around the answer it produced. *)
let leading_logic info (s : Ast.reflected_stmt) =
  match leading_expr s with
  | None -> None
  | Some (e, rebuild_stmt) ->
    extract_logic info e
    |> Option.map (fun (logic, rebuild_expr) ->
      logic, fun held -> { s with Ast.it = rebuild_stmt (rebuild_expr held) })

let splits_logic info s = Option.is_some (leading_logic info s)

(* Deferred statements armed on the way here. Leaving disarms them, so a pass
   that resumes past one would find nothing armed and release nothing. *)
let open_defers : string list ref = ref []

(* And the cleanups guarding them. An unwind reaching a later pass would pass
   through nothing, since the frame it went through belonged to the first. *)
let open_unwinds : Ast.cps_stmt list list ref = ref []

let delimited span body =
  let armed =
    List.map
      (fun flag ->
        node
          span
          (`Expr
            { Ast.it = `Assign (flag, { Ast.it = `Bool true; span; ann = Types.Bool })
            ; span
            ; ann = Types.Bool
            }))
      !open_defers
  in
  let guarded =
    List.fold_left
      (fun acc cleanup -> [ node span (`On_unwind (acc, cleanup)) ])
      (armed @ body)
      !open_unwinds
  in
  guarded

(* ---- continuation-passing form ---- *)

(* [ret] is what a `return` calls, [k] what the next statement runs under. They
   part company inside a branch, where the join resumes the rest of the body. *)
let rec cps info ret k ~at (stmts : Ast.reflected_stmt list) : Ast.cps_stmt list =
  match stmts with
  (* Reported against the construct that held them rather than nowhere. *)
  | [] -> [ call at k [ ignored at ] ]
  | s :: rest when splits_logic info s ->
    let logic, rebuilt = Option.get (leading_logic info s) in
    split_logic info s.Ast.span logic (fun held -> cps info ret k ~at (rebuilt held :: rest))
  | s :: rest ->
    let span = s.Ast.span in
    (match s.Ast.it with
     | `Return value ->
       let value =
         match value with
         | Some v -> v
         | None -> { Ast.it = `Bool false; span; ann = Types.Bool }
       in
       (match extract info value with
        | Some (c, rebuild) -> sequence info span c (fun name ->
            cps info ret k ~at:span [ { s with Ast.it = `Return (Some (rebuild name)) } ])
        | None ->
          (* No continuation to hand it to: the enclosing function was left
             unconverted because handling the effect discharged its row. The
             statement leaves every frame between here and it. *)
          match (if info.inside_run then info.leaving else None) with
          | _ when String.equal ret no_return ->
            [ node span (`Return (Some (expr info value))) ]
          (* Ending the function, with nothing between here and it. The arm that
             resumed into this is owed its sequel, so the continuation is called
             and comes back to it. *)
          | None -> [ call span ret [ expr info value ] ]
          (* Leaving the function from inside a `run` it has not finished. The
             value waits while the unwind leaves the block -- which is what runs
             a `defer` the arm armed -- and the scope hands it on once nothing
             is left to leave. Calling the continuation here instead would let
             the caller see the value before the arm had finished being left. *)
          | Some (stash, crossed) ->
            let handed = expr info value in
            let assign name v ann : Ast.cps_stmt =
              node span (`Expr { Ast.it = `Assign (name, v); span; ann })
            in
            [ assign stash handed handed.Ast.ann
            ; assign crossed { Ast.it = `Bool true; span; ann = Types.Bool } Types.Bool
            ; node span (`Return None)
            ])
     (* The arm keeps running afterwards: multi-shot falls out. *)
     | `Resume value ->
       let value =
         match value with
         | Some v -> expr info v
         | None -> ignored span
       in
       call span continuation [ value ] :: cps info ret k ~at:span rest
     (* Converted code leaves a scope by calling the continuation, by
        returning, or by an unwind. The first two are calls, so the deferred
        statement wraps each — which is what runs it once per exit when a
        handler resumes twice. The flag keeps an unwind reaching this frame
        afterwards from running it again. *)
     | `Defer inner ->
       let armed = fresh "armed" in
       let flag value : Ast.cps_expr =
         { Ast.it = (if value then `Bool true else `Bool false); span; ann = Types.Bool }
       in
       let disarm =
         node span (`Expr { Ast.it = `Assign (armed, flag false); span; ann = Types.Bool })
       in
       (* The deferred statement, then whatever this exit was on its way to. *)
       let leaving finish handed =
         if not (suspends_stmt info inner)
         then Option.to_list (stmt info inner) @ [ call span finish [ handed ] ]
         else (
           let after = fresh "resumed" in
           frame_decl span after [ fresh "x" ] [ call span finish [ handed ] ]
           :: cps info no_return after ~at:span [ inner ])
       in
       let wrapper finish =
         let name = fresh "leave" in
         let value = fresh "x" in
         name, frame_decl span name [ value ] (disarm :: leaving finish (var span Types.Unit value))
       in
       let ret', wrapped_ret =
         (* Nothing to wrap: a `return` there is a statement, and the unwind it
            raises passes through the cleanup below. *)
         if String.equal ret no_return
         then no_return, []
         else (
           let name, declaration = wrapper ret in
           name, [ declaration ])
       in
       let k', wrapped_k = wrapper k in
       (* No continuation here, so one performing an effect cannot run. *)
       let cleanup =
         if suspends_stmt info inner
         then []
         else
           [ node
               span
               (`If
                 ( var span Types.Bool armed
                 , node span (`Block (disarm :: Option.to_list (stmt info inner)))
                 , None ))
           ]
       in
       let outer_defers = !open_defers
       and outer_unwinds = !open_unwinds in
       let converted_rest =
         open_defers := armed :: outer_defers;
         open_unwinds := cleanup :: outer_unwinds;
         Fun.protect
           ~finally:(fun () ->
             open_defers := outer_defers;
             open_unwinds := outer_unwinds)
           (fun () -> cps info ret' k' ~at:span rest)
       in
       (node span (`Var_decl (armed, None, Some (flag true)))
        :: wrapped_ret)
       @ [ wrapped_k; node span (`On_unwind (converted_rest, cleanup)) ]
     | `Expr e when suspends info e ->
       (match extract info e with
        | Some (c, rebuild) ->
          sequence info span c (fun name ->
            match (rebuild name).Ast.it with
            | `Var _ -> cps info ret k ~at:span rest
            | _ -> cps info ret k ~at:span ({ s with Ast.it = `Expr (rebuild name) } :: rest))
        | None -> unsupported span "This effect cannot be sequenced yet.")
     | `Var_decl (name, _, Some e) when suspends info e ->
       (match extract info e with
        | Some (c, rebuild) ->
          let bound = ref name in
          let build tmp =
            match (rebuild tmp).Ast.it with
            | `Var _ ->
              bound := name;
              cps info ret k ~at:span rest
            | _ ->
              bound := tmp;
              cps info ret k ~at:span ({ s with Ast.it = `Var_decl (name, None, Some (rebuild tmp)) } :: rest)
          in
          let tmp = fresh "v" in
          let body = build tmp in
          let next = fresh "k" in
          cont_decl span next [ !bound ] (delimited span body) :: invoke info span next c
        | None -> unsupported span "This effect cannot be sequenced yet.")
     | `If (cond, then_branch, else_branch) when suspends_stmt info s || holds_return s ->
       let join = fresh "join" in
       let branch b = node span (`Block (cps info ret join ~at:span [ b ])) in
       frame_decl span join [ fresh "x" ] (cps info ret k ~at:span rest)
       :: controlled_by info span cond (fun cond ->
            [ node
                span
                (`If
                  ( cond
                  , branch then_branch
                  , Some
                      (match else_branch with
                       | Some e -> branch e
                       (* Without this the join is never reached. *)
                       | None -> call span join [ ignored span ]) ))
            ])
     | `Match (scrutinee, cases) when suspends_stmt info s || holds_return s ->
       let join = fresh "join" in
       frame_decl span join [ fresh "x" ] (cps info ret k ~at:span rest)
       :: controlled_by info span scrutinee (fun scrutinee ->
            [ node
                span
                (`Match
                  ( scrutinee
                  , List.map (fun (pattern, body) -> pattern, cps info ret join ~at:span body) cases ))
            ])
     | `Block body when suspends_stmt info s || holds_return s ->
       let next = fresh "k" in
       [ cont_decl span next [ fresh "x" ] (delimited span (cps info ret k ~at:span rest))
       ; node span (`Block (cps info ret next ~at:span body))
       ]
     (* The body's "what runs next" is the loop itself, so resuming carries
        on with the next iteration and resuming twice runs it twice. *)
     | `While (cond, body) when suspends_stmt info s ->
       let again = fresh "loop"
       and after = fresh "after" in
       [ frame_decl span after [ fresh "x" ] (cps info ret k ~at:span rest)
       ; (* Once per iteration, so extracting it goes inside the continuation
            the loop re-enters. *)
         frame_decl
           span
           again
           [ fresh "x" ]
           (controlled_by info span cond (fun cond ->
              [ node
                  span
                  (`If
                    ( cond
                    , node span (`Block (cps info ret again ~at:span [ body ]))
                    , Some (call span after [ ignored span ]) ))
              ]))
       ; call span again [ ignored span ]
       ]
     | `Run (body, handlers) when handlers_delimited info handlers ->
       run info ret span k handlers body rest
     (* The body may still return out of the converted function it stands in,
        so what follows is its continuation rather than a later statement. *)
     | `Run (body, handlers)
       when List.exists (fun b -> suspends_stmt info b || holds_return b) body ->
       let after = fresh "after" in
       let scope = fresh "scope" in
       (* An abort skipped the body's own continuation. *)
       let on_abort = [ call span after [ ignored span ] ] in
       frame_decl span after [ fresh "x" ] (cps info ret k ~at:span rest)
       :: (direct_arms info span ~scope handlers
           @ [ node span (`Scope (scope, cps info ret after ~at:span body, on_abort)) ])
     | _ ->
       (match stmt info s with
        | Some s -> s :: cps info ret k ~at:span rest
        | None -> cps info ret k ~at:span rest))

(* Evaluated before the statement it controls rather than inside it. *)
and controlled_by info span (cond : Ast.reflected_expr) build =
  if not (suspends info cond)
  then build (expr info cond)
  else (
    match extract_logic info cond with
    | Some (logic, rebuild) ->
      split_logic info span logic (fun held ->
        controlled_by info span (rebuild held) build)
    | None ->
      (match extract info cond with
       | Some (c, rebuild) ->
         sequence info span c (fun name -> build (expr info (rebuild name)))
       | None -> unsupported span "This effect cannot be sequenced yet."))

(* `and`/`or` reaches its right operand on one branch only, so an operation
   there cannot be sequenced with the rest of the expression: the operand
   becomes a branch, and what held the operator is entered once from each with
   the answer as its argument. A `while` condition is why the answer is passed
   rather than assigned to a temporary: the temporary would have to be declared
   outside the loop and re-assigned inside it, which is the condition written
   twice. *)
and split_logic info span (logic : Ast.reflected_expr) build =
  let held = fresh "v" in
  let join = fresh "join" in
  let settled value : Ast.cps_stmt list =
    let answer : Ast.cps_expr =
      { Ast.it = (if value then `Bool true else `Bool false); span; ann = Types.Bool }
    in
    [ call span join [ answer ] ]
  in
  let evaluated operand =
    controlled_by info span operand (fun operand -> [ call span join [ operand ] ])
  in
  let block stmts = node span (`Block stmts) in
  let left, taken, skipped =
    match logic.Ast.it with
    | `And (left, right) -> left, evaluated right, settled false
    | `Or (left, right) -> left, settled true, evaluated right
    | _ -> assert false
  in
  frame_decl span join [ held ] (build held)
  :: controlled_by info span left (fun left ->
       [ node span (`If (left, block taken, Some (block skipped))) ])

and sequence info span c build =
  let name = fresh "v" in
  let next = fresh "k" in
  cont_decl span next [ name ] (delimited span (build name)) :: invoke info span next c

and invoke info span next (c : Ast.reflected_expr) : Ast.cps_stmt list =
  match c.Ast.it with
  | `Call (callee, args) ->
    let args = List.map (expr info) args in
    let evidence_for ty =
      evidence_of_row info (row_of ty)
      |> List.map (fun op -> var span (evidence_ty info op) (evidence_var info op))
    in
    let before, target, evidence =
      match callee.Ast.it with
      | `Var name when Hashtbl.mem info.owner name -> [], evidence_var info name, []
      | `Var name -> [], name, evidence_for callee.Ast.ann
      (* Anything else is bound first, since the call is emitted by name. *)
      | _ ->
        let held = fresh "callee" in
        ( [ node span (`Var_decl (held, None, Some (expr info callee))) ]
        , held
        , evidence_for callee.Ast.ann )
    in
    let answering = Types.Fn ([ widen info c.Ast.ann ], Types.Unit, Types.closed_row []) in
    before @ [ call span target (args @ evidence @ [ var span answering next ]) ]
  (* The target is read from the vtable rather than named, so what is appended
     is the same and only the call form differs. *)
  | `Dyn_call (receiver, name, performs, args) ->
    let receiver = expr info receiver in
    let args = List.map (expr info) args in
    let evidence =
      evidence_of_row info (row_of performs)
      |> List.map (fun op -> var span (evidence_ty info op) (evidence_var info op))
    in
    let answering = Types.Fn ([ widen info c.Ast.ann ], Types.Unit, Types.closed_row []) in
    [ node
        span
        (`Expr
          { Ast.it =
              `Dyn_call
                (receiver, name, performs, args @ evidence @ [ var span answering next ])
          ; span
          ; ann = Types.Unit
          })
    ]
  | _ -> unsupported span "This effect cannot be sequenced yet."

(* An arm that never calls it abandons the rest of the body: abort. *)
and run info ret span k handlers body rest : Ast.cps_stmt list =
  let after = fresh "after" in
  let finished = fresh "finished" in
  let installed =
    List.concat_map
      (fun (h : Ast.reflected_stmt Ast.handler) ->
        List.map (fun (a : Ast.reflected_stmt Ast.arm) -> a.Ast.arm_name, fresh "ev") h.Ast.arms)
      handlers
  in
  (* An arm is not under its own handler: an operation it performs itself
     reaches whatever installed the evidence outside this block. *)
  let arms =
    List.concat_map
      (fun (h : Ast.reflected_stmt Ast.handler) ->
        List.map
          (fun (a : Ast.reflected_stmt Ast.arm) ->
            let name = List.assoc a.Ast.arm_name installed in
            (* One `run` may handle a delimited effect beside an undelimited
               one, and each keeps the shape its own declaration asked for: a
               caller of an undelimited operation passes no continuation,
               whatever else this block happens to handle. *)
            if not (Hashtbl.mem info.delimited h.Ast.handled)
            then arm_decl span name a.Ast.arm_params (sequence_body info a.Ast.arm_body)
            else (
              let arm_body =
                match a.Ast.arm_kind with
                | Ast.Op_fn -> cps info continuation continuation ~at:span a.Ast.arm_body
                | Ast.Op_ctl | Ast.Op_final ->
                  cps info finished finished ~at:span a.Ast.arm_body
              in
              frame_decl span name (a.Ast.arm_params @ [ continuation ]) arm_body))
          h.Ast.arms)
      handlers
  in
  (* What follows the block runs once after the handler is done, not once
     per resumption. *)
  (frame_decl span after [ fresh "x" ] (cps info ret k ~at:span rest)
   :: frame_decl span finished [ fresh "x" ] []
   :: arms)
  @ with_bound info installed (fun () ->
      let previous = info.inside_run in
      info.inside_run <- true;
      Fun.protect
        ~finally:(fun () -> info.inside_run <- previous)
        (fun () -> cps info ret finished ~at:span body))
  @ [ call span after [ ignored span ] ]

(* ---- evidence-only translation ---- *)

and stmt info (s : Ast.reflected_stmt) : Ast.cps_stmt option =
  let keep it = Some { Ast.it; span = s.Ast.span; ann = s.Ast.ann } in
  match s.Ast.it with
  | `Effect_decl _ | `Type_decl _ -> None
  | `Match (scrutinee, cases) ->
    keep
      (`Match
        ( expr info scrutinee
        , List.map (fun (p, body) -> p, List.map (block info) body) cases ))
  | `Resume _ -> unsupported s.Ast.span "'resume' outside a handler."
  | `Fn (name, params, signature, body) ->
    let row = row_of s.Ast.ann in
    let evidence =
      evidence_of_row info row |> List.map (fun op -> { Ast.name = evidence_name op; ty = None; implicit = false })
    in
    if is_delimited info row
    then (
      (* Its own, rather than the shared name: a converted body nested inside an
         arm would otherwise bind the arm's continuation, which is what `resume`
         reaches for. *)
      let own = fresh "k" in
      let stash = fresh "left" in
      let crossed = fresh "crossed" in
      let inner = fresh "body" in
      let previous = info.leaving, info.inside_run in
      info.leaving <- Some (stash, crossed);
      info.inside_run <- false;
      let converted =
        Fun.protect
          ~finally:(fun () ->
            info.leaving <- fst previous;
            info.inside_run <- snd previous)
          (fun () -> cps info own own ~at:s.Ast.span body)
      in
      let all = params @ evidence @ [ { Ast.name = own; ty = None; implicit = false } ] in
      let span = s.Ast.span in
      let flag value : Ast.cps_expr =
        { Ast.it = (if value then `Bool true else `Bool false); span; ann = Types.Bool }
      in
      let widened = widen info s.Ast.ann in
      let argument_types, answer =
        match widened with
        | Types.Fn (types, answer, _) -> types, answer
        | _ -> List.map (fun _ -> Types.Unit) all, Types.Unit
      in
      (* The body is a function of its own so that a `return` crossing a `run`
         can leave it. Unwinding out of the body runs whatever the arms
         deferred, and only then is the value handed on; calling the
         continuation at the `return` instead would let the caller see the
         value while the arm was still being left. *)
      keep
        (`Fn
          ( name
          , all
          , signature
          , [ node span (`Var_decl (stash, None, Some (flag false)))
            ; node span (`Var_decl (crossed, None, Some (flag false)))
            ; node span (`Fn (inner, all, signature, converted))
            ; node
                span
                (`Expr
                  { Ast.it =
                      `Call
                        ( var span widened inner
                        , List.map2
                            (fun (p : Ast.param) ty -> var span ty p.Ast.name)
                            all
                            argument_types )
                  ; span
                  ; ann = answer
                  })
            ; node
                span
                (`If
                  ( var span Types.Bool crossed
                  , node span (`Block [ call span own [ var span Types.Unit stash ] ])
                  , None ))
            ] )))
    else keep (`Fn (name, params @ evidence, signature, sequence_body info body))
  | `Run (body, handlers) when handlers_delimited info handlers ->
    unsupported
      s.Ast.span
      "A 'run' whose handler needs a continuation is not supported yet in this position."
  | `Run (body, handlers) ->
    let scope = fresh "scope" in
    keep
      (`Block
        (direct_arms info s.Ast.span ~scope handlers
         (* The statements after the block are still statements. *)
         @ [ node s.Ast.span (`Scope (scope, sequence_body info body, [])) ]))
  | #Ast.stmts as st ->
    keep (Ast.map_stmts (expr info) (block info) st :> Ast.cps_stmt_kind)

(* Each arm is a function of the operation's parameters alone. *)
and direct_arms info span ~scope handlers =
  List.concat_map
    (fun (h : Ast.reflected_stmt Ast.handler) ->
      List.map
        (fun (a : Ast.reflected_stmt Ast.arm) ->
          let converted =
            match a.Ast.arm_kind with
            | Ast.Op_fn -> sequence_body info a.Ast.arm_body
            | Ast.Op_ctl -> sequence_body info (Option.get (tail_resumptive a.Ast.arm_body))
            (* Whatever it did, it does not go back. *)
            | Ast.Op_final -> sequence_body info a.Ast.arm_body @ [ node span (`Abort scope) ]
          in
          arm_decl span (evidence_name a.Ast.arm_name) a.Ast.arm_params converted)
        h.Ast.arms)
    handlers

and block info (s : Ast.reflected_stmt) : Ast.cps_stmt =
  match stmt info s with
  | Some s -> s
  | None -> node s.Ast.span (`Block [])

and sequence_body info (stmts : Ast.reflected_stmt list) : Ast.cps_stmt list =
  match stmts with
  | [] -> []
  (* A `return` among them returns from the function they are in. *)
  | { Ast.it = `Run (body, handlers); span; _ } :: rest
    when handlers_delimited info handlers ->
    let nothing = fresh "nothing" in
    (frame_decl span nothing [ fresh "x" ] []
     :: run info no_return span nothing handlers body [])
    @ sequence_body info rest
  (* A `run` deeper down — in a branch, a loop or an arm — needs a
     continuation just the same. *)
  | s :: rest when suspends_stmt info s ->
    let nothing = fresh "nothing" in
    (frame_decl s.Ast.span nothing [ fresh "x" ] []
     :: cps info no_return nothing ~at:s.Ast.span [ s ])
    @ sequence_body info rest
  | s :: rest ->
    (match stmt info s with
     | Some s -> s :: sequence_body info rest
     | None -> sequence_body info rest)

(* ---- entry point ---- *)

let () = convert_body := sequence_body
let () = convert_cps := fun info k span body -> cps info k k ~at:span body

let collect (p : Ast.reflected_stmt list) =
  let info =
    { owner = Hashtbl.create 16
    ; operations = Hashtbl.create 8
    ; delimited = Hashtbl.create 8
    ; op_ty = Hashtbl.create 16
    ; bound = Hashtbl.create 8
    ; leaving = None
    ; inside_run = false
    }
  in
  List.iter
    (fun (s : Ast.reflected_stmt) ->
      match s.Ast.it with
      | `Effect_decl (name, _, ops) ->
        Hashtbl.replace
          info.operations
          name
          (List.map (fun (o : Ast.op_decl) -> o.Ast.op_name) ops |> List.sort String.compare);
        List.iter
          (fun (o : Ast.op_decl) -> Hashtbl.replace info.owner o.Ast.op_name name)
          ops;
        if List.exists (fun (o : Ast.op_decl) -> o.Ast.op_kind = Ast.Op_ctl) ops
        then Hashtbl.replace info.delimited name ()
      | _ -> ())
    p;
  let rec scan (s : Ast.reflected_stmt) =
    match s.Ast.it with
    | `Block body | `Fn (_, _, _, body) -> List.iter scan body
    | `If (_, t, e) ->
      scan t;
      Option.iter scan e
    | `While (_, body) -> scan body
    | `Run (body, handlers) ->
      List.iter scan body;
      List.iter
        (fun (h : Ast.reflected_stmt Ast.handler) ->
          List.iter
            (fun (a : Ast.reflected_stmt Ast.arm) -> List.iter scan a.Ast.arm_body)
            h.Ast.arms)
        handlers
    | `Match (_, cases) -> List.iter (fun (_, body) -> List.iter scan body) cases
    | `Defer inner -> scan inner
    | _ -> ()
  in
  List.iter scan p;
  let rec harvest_expr (e : Ast.reflected_expr) =
    match e.Ast.it with
    | `Call (callee, args) ->
      (match callee.Ast.it with
       | `Var name when Hashtbl.mem info.owner name ->
         Hashtbl.replace info.op_ty name callee.Ast.ann
       | _ -> harvest_expr callee);
      List.iter harvest_expr args
    | `Assign (_, v) | `Unop (_, v) -> harvest_expr v
    | `Binop (_, a, b) | `And (a, b) | `Or (a, b) ->
      harvest_expr a;
      harvest_expr b
    | _ -> ()
  in
  let rec harvest (s : Ast.reflected_stmt) =
    (match s.Ast.it with
     | `Expr e | `Return (Some e) | `Var_decl (_, _, Some e) -> harvest_expr e
     | `If (c, _, _) | `While (c, _) -> harvest_expr c
     | `Resume (Some e) -> harvest_expr e
     | `Match (scrutinee, _) -> harvest_expr scrutinee
     | _ -> ());
    match s.Ast.it with
    | `Block body | `Fn (_, _, _, body) -> List.iter harvest body
    | `If (_, t, e) ->
      harvest t;
      Option.iter harvest e
    | `While (_, body) -> harvest body
    | `Run (body, handlers) ->
      List.iter harvest body;
      List.iter
        (fun (h : Ast.reflected_stmt Ast.handler) ->
          List.iter
            (fun (a : Ast.reflected_stmt Ast.arm) -> List.iter harvest a.Ast.arm_body)
            h.Ast.arms)
        handlers
    | `Match (_, cases) -> List.iter (fun (_, body) -> List.iter harvest body) cases
    | `Defer inner -> harvest inner
    | _ -> ()
  in
  List.iter harvest p;
  info

let program (p : Ast.reflected_stmt list) : (Ast.cps_stmt list, error) result =
  counter := 0;
  let info = collect p in
  try Ok (sequence_body info p) with
  | Unsupported e -> Error e
