(* Before anything is checked: a value can decide a type, so there is no one
   type to check the template against. Type parameters are left alone. *)

open Ast

type error =
  { span : span
  ; message : string
  }

exception Error of error

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Error { span; message })) fmt

type template =
  { t_params : param list
  ; t_signature : signature
  ; t_body : desugared_stmt list
  }

type state =
  { templates : (string, template) Hashtbl.t
  ; (* Which copy serves a given argument list, so a repeated call reuses it. *)
    copies : (string * string, string) Hashtbl.t
  ; mutable emitted : desugared_stmt list (* reversed *)
  ; mutable pending : (string * desugared_stmt) list
  }

(* A trait name after the colon is a bound, not a value's type, and nothing
   knows the traits yet — so this pass collects them itself. *)
let traits : (string, unit) Hashtbl.t = Hashtbl.create 8

(* No wildcard: a statement that can hold another has to be listed, or a trait
   declared inside it is read as a comptime value parameter. *)
let children (s : desugared_stmt) : desugared_stmt list =
  match s.it with
  | `Block body | `Fn (_, _, _, body) -> body
  | `Defer inner -> [ inner ]
  | `If (_, t, e) -> t :: Option.to_list e
  | `While (_, body) -> [ body ]
  | `Match (_, cases) -> List.concat_map snd cases
  | `Run (body, handlers) ->
    body @ List.concat_map (fun h -> List.concat_map (fun a -> a.arm_body) h.arms) handlers
  | `Impl_decl (_, _, _, body) -> List.concat_map (fun m -> m.md_body) body.ib_methods
  | `Expr _ | `Var_decl _ | `Var_tuple _ | `Return _ | `Effect_decl _ | `Resume _ | `Type_decl _
  | `Trait_decl _ -> []

let rec note_traits (s : desugared_stmt) =
  (match s.it with
   | `Trait_decl (name, _, _) -> Hashtbl.replace traits name ()
   | _ -> ());
  List.iter note_traits (children s)

let is_value (p : comptime_param) =
  match p.cp_ty with
  | None -> false
  (* A bound may carry arguments — `T: TryFrom<S>` — and is still a bound. *)
  | Some { it = Ty_name name; _ } | Some { it = Ty_app (name, _); _ } ->
    not (Hashtbl.mem traits name)
  | Some _ -> true

let split (signature : signature) =
  List.partition is_value signature.comptime

(* Total, so it also decides whether an argument may be one at all. *)
let rec key_of (e : desugared_expr) : string option =
  match e.it with
  | `Int n -> Some (string_of_int n)
  | `Float n -> Some (Printf.sprintf "%h" n)
  | `Str s -> Some (Printf.sprintf "%S" (Utf8.encode s))
  | `Char c -> Some (Printf.sprintf "'%d'" (Uchar.to_int c))
  | `Bool b -> Some (string_of_bool b)
  | `Unop (Neg, inner) -> Option.map (fun key -> "-" ^ key) (key_of inner)
  | _ -> None

(* A local of the same name is a different variable. *)
let shadow names env = List.filter (fun (name, _) -> not (List.mem name names)) env
let param_names params = List.map (fun (p : param) -> p.name) params

let rec subst_expr env (e : desugared_expr) : desugared_expr =
  let it : desugared_expr_kind =
    match e.it with
    | `Var name when List.mem_assoc name env -> (List.assoc name env).it
    | `Lambda (params, signature, body) ->
      `Lambda (params, signature, subst_body (shadow (param_names params) env) body)
    | #lit as l -> l
    | #vars as v -> (map_vars (subst_expr env) v :> desugared_expr_kind)
    | #ops as o -> (map_ops (subst_expr env) o :> desugared_expr_kind)
    | #logic as l -> (map_logic (subst_expr env) l :> desugared_expr_kind)
    | #compound as c -> (map_compound (subst_expr env) c :> desugared_expr_kind)
    | #indexing as i -> (map_indexing (subst_expr env) i :> desugared_expr_kind)
    | #tuple as t -> (map_tuple (subst_expr env) t :> desugared_expr_kind)
    | #spread as s -> (map_spread (subst_expr env) s :> desugared_expr_kind)
    | #record as r -> (map_record (subst_expr env) r :> desugared_expr_kind)
    | #nominal as n -> (map_nominal (subst_expr env) n :> desugared_expr_kind)
    | #collection as c -> (map_collection (subst_expr env) c :> desugared_expr_kind)
        | `Comptime_call (callee, comptime_args, args) ->
      let arg = function
        | Ct_type { it = Ty_name written; _ } when List.mem_assoc written env ->
          Ct_value (List.assoc written env)
        | other -> map_comptime_arg (subst_expr env) other
      in
      `Comptime_call
        ( subst_expr env callee
        , List.map arg comptime_args
        , List.map (subst_expr env) args )
    | #method_call as m -> (map_method_call (subst_expr env) m :> desugared_expr_kind)
    | #reflect as r -> (map_reflect (subst_expr env) r :> desugared_expr_kind)
    | #run_expr as r ->
      (map_run_expr (subst_expr env) (subst_stmt env) (map_handler (subst_stmt env)) r
       :> desugared_expr_kind)
  in
  { e with it }

and subst_body env (body : desugared_stmt list) : desugared_stmt list =
  match body with
  | [] -> []
  | s :: rest ->
    let substituted = subst_stmt env s in
    let env =
      match s.it with
      | `Var_decl (name, _, _) -> shadow [ name ] env
      | _ -> env
    in
    substituted :: subst_body env rest

and subst_stmt env (s : desugared_stmt) : desugared_stmt =
  let it : desugared_stmt_kind =
    match s.it with
    | `Block body -> `Block (subst_body env body)
    | `Fn (name, params, signature, body) ->
      `Fn (name, params, signature, subst_body (shadow (param_names params) env) body)
    | `Match (scrutinee, cases) ->
      `Match
        ( subst_expr env scrutinee
        , List.map
            (fun (pattern, body) ->
              let bound =
                match pattern with
                | Pat_variant (_, _, payload) -> List.map snd (payload_fields payload)
                | Pat_wild -> []
              in
              pattern, subst_body (shadow bound env) body)
            cases )
    | #stmts as st ->
      (map_stmts (subst_expr env) (subst_stmt env) st :> desugared_stmt_kind)
    | #effects as e ->
      (map_effects
         (subst_expr env)
         (subst_stmt env)
         (map_handler (subst_stmt env))
         e
       :> desugared_stmt_kind)
    | #type_defs as t -> t
    | #method_defs as m ->
      (map_method_defs (subst_stmt env) Fun.id m :> desugared_stmt_kind)
  in
  { s with it }

let literal_of name (arg : desugared_expr comptime_arg) =
  let written =
    match arg with
    | Ct_type { it = Ty_name written; span = at } ->
      { it = `Var written; span = at; ann = () }
    | Ct_type t ->
      fail t.span "'%s' takes a value here, not a type." name
    | Ct_value v -> v
  in
  match key_of written with
  | Some key -> written, key
  | None ->
    (match written.it with
     | `Var unknown ->
       fail
         written.span
         "'%s' is not known at compile time: it is a run-time variable, not a \
          comptime parameter of the enclosing function."
         unknown
     | `Call _ | `Comptime_call _ ->
       fail
         written.span
         "This argument to '%s' is not known at compile time: a call is only \
          comptime-evaluable inside a meta block, which does not exist yet."
         name
     (* An `embed` is already its contents here, so the message above would
        be a lie. *)
     | `Bytes _ ->
       fail
         written.span
         "Embedded bytes cannot be a comptime argument to '%s': a comptime \
          value is a number, string, char or bool."
         name
     | _ ->
       fail
         written.span
         "This argument to '%s' is not known at compile time; only a literal or \
          a comptime parameter of the enclosing function is."
         name)

let copy_name state name key =
  match Hashtbl.find_opt state.copies (name, key) with
  | Some existing -> existing, false
  | None ->
    let index = Hashtbl.length state.copies in
    let fresh = generated [ name; string_of_int index ] in
    Hashtbl.replace state.copies (name, key) fresh;
    fresh, true

let rec expr state (e : desugared_expr) : desugared_expr =
  let it : desugared_expr_kind =
    match e.it with
    | `Lambda (params, signature, body) ->
      `Lambda (params, signature, List.map (stmt state) body)
    | `Comptime_call (callee, comptime_args, args) ->
      let args = List.map (expr state) args in
      (match callee.it with
       | `Var name when Hashtbl.mem state.templates name ->
         specialize state e.span name comptime_args args
       | _ ->
         `Comptime_call
           ( expr state callee
           , List.map (map_comptime_arg (expr state)) comptime_args
           , args ))
    | #lit as l -> l
    | #vars as v -> (map_vars (expr state) v :> desugared_expr_kind)
    | #ops as o -> (map_ops (expr state) o :> desugared_expr_kind)
    | #logic as l -> (map_logic (expr state) l :> desugared_expr_kind)
    | #compound as c -> (map_compound (expr state) c :> desugared_expr_kind)
    | #indexing as i -> (map_indexing (expr state) i :> desugared_expr_kind)
    | #tuple as t -> (map_tuple (expr state) t :> desugared_expr_kind)
    | #spread as s -> (map_spread (expr state) s :> desugared_expr_kind)
    | #record as r -> (map_record (expr state) r :> desugared_expr_kind)
    | #nominal as n -> (map_nominal (expr state) n :> desugared_expr_kind)
    | #collection as c -> (map_collection (expr state) c :> desugared_expr_kind)
    | #method_call as m -> (map_method_call (expr state) m :> desugared_expr_kind)
    | #reflect as r -> (map_reflect (expr state) r :> desugared_expr_kind)
    | #run_expr as r ->
      (map_run_expr (expr state) (stmt state) (map_handler (stmt state)) r
       :> desugared_expr_kind)
  in
  { e with it }

and specialize state span name comptime_args args : desugared_expr_kind =
  let template = Hashtbl.find state.templates name in
  let declared = template.t_signature.comptime in
  if List.length declared <> List.length comptime_args
  then
    fail
      span
      "'%s' takes %d comptime argument(s) but %d were given."
      name
      (List.length declared)
      (List.length comptime_args);
  let values, types =
    List.fold_left2
      (fun (values, types) (p : comptime_param) arg ->
        if is_value p
        then (p.cp_name, literal_of name arg) :: values, types
        else values, arg :: types)
      ([], [])
      declared
      comptime_args
  in
  let values = List.rev values
  and types = List.rev types in
  let key = String.concat "," (List.map (fun (_, (_, key)) -> key) values) in
  let bound = List.map (fun (param, (written, _)) -> param, written) values in
  let copy, is_new = copy_name state name key in
  if is_new
  then (
    let _, type_params = split template.t_signature in
    let specialized : desugared_stmt =
      { it =
          `Fn
            ( copy
            , template.t_params
            , { template.t_signature with comptime = type_params }
            , subst_body bound template.t_body )
      ; span
      ; ann = ()
      }
    in
    state.pending <- (copy, specialized) :: state.pending);
  let callee : desugared_expr = { it = `Var copy; span; ann = () } in
  if types = [] then `Call (callee, args) else `Comptime_call (callee, types, args)

(* Filtered, not mapped: a template left in place reaches the checker. *)
and body state (stmts : desugared_stmt list) : desugared_stmt list =
  List.filter_map
    (fun s ->
      match s.it with
      | `Fn (name, _, _, _) when Hashtbl.mem state.templates name -> None
      | _ -> Some (stmt state s))
    stmts

and stmt state (s : desugared_stmt) : desugared_stmt =
  let it : desugared_stmt_kind =
    match s.it with
    | `Block inner -> `Block (body state inner)
    | `Fn (name, params, signature, inner) ->
      `Fn (name, params, signature, body state inner)
    | #stmts as st ->
      (map_stmts (expr state) (stmt state) st :> desugared_stmt_kind)
    | #effects as e ->
      (map_effects (expr state) (stmt state) (map_handler (stmt state)) e
       :> desugared_stmt_kind)
    | #type_defs as t -> t
    | `Impl_decl (trait, type_name, params, impl) ->
      `Impl_decl
        ( trait
        , type_name
        , params
        , { impl with
            ib_methods =
              List.map (fun m -> { m with md_body = body state m.md_body }) impl.ib_methods
          } )
    | #method_defs as m ->
      (map_method_defs (stmt state) Fun.id m :> desugared_stmt_kind)
    | #matching as m ->
      (map_matching (expr state) (stmt state) m :> desugared_stmt_kind)
  in
  { s with it }

let rec collect state (s : desugared_stmt) =
  (match s.it with
   | `Fn (name, params, signature, body) ->
     let values, _ = split signature in
     if values <> []
     then
       Hashtbl.replace
         state.templates
         name
         { t_params = params; t_signature = signature; t_body = body }
   | _ -> ());
  List.iter (collect state) (children s)

let program (p : desugared_stmt list) : (desugared_stmt list, error) result =
  let state =
    { templates = Hashtbl.create 8
    ; copies = Hashtbl.create 8
    ; emitted = []
    ; pending = []
    }
  in
  Hashtbl.reset traits;
  List.iter note_traits p;
  List.iter (collect state) p;
  if Hashtbl.length state.templates = 0
  then Ok p
  else (
    try
      let rewritten = body state p in
      (* Runs until no new copy is asked for. *)
      let rec drain () =
        match state.pending with
        | [] -> ()
        | pending ->
          state.pending <- [];
          List.iter
            (fun (_, s) -> state.emitted <- stmt state s :: state.emitted)
            (List.rev pending);
          drain ()
      in
      drain ();
      Ok (List.rev state.emitted @ rewritten)
    with
    | Error e -> Result.Error e)
