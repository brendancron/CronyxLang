(* The whole program checked before metaprocessing, reached or not, with every
   meta block's contribution unknown. It reports what is wrong whatever a meta
   block produces, and nothing that a meta block could still make right. *)

module S = Metaprocess.Shadowed

let unknown_name = Ast.generated [ "meta"; "unknown" ]
let unknown span : Ast.expr = Ast.at span (`Var unknown_name)

(* Of whatever type it is used at, as a call that never returns is. *)
let anything span : Ast.expr =
  let at it = Ast.at span it in
  at (`Call (at (`Var "compile_error"), [ at (`Call (at (`Var "__span_generated"), [])); at (`Str [||]) ]))

(* A value parameter is checked as a local of its declared type: its value is
   what a meta block would read, its type is known now. *)
let erase (p : Ast.program) : Ast.program =
  let traits = Metaprocess.declared_traits p in
  let comptime = Hashtbl.create 16 in
  let rec note (s : Ast.stmt) =
    (match Metaprocess.fn_parts s with
     | Some (name, _, sg, _) when List.exists (Metaprocess.value_param traits) sg.Ast.static_params ->
       Hashtbl.replace comptime name sg.Ast.static_params
     | _ -> ());
    match s.Ast.it with
    | `Fn (_, _, _, body) | `Block body -> List.iter note body
    | `Attributed (_, inner) -> note inner
    | `Type_members (_, members) -> List.iter note members
    | `Impl_decl (_, _, _, impl) ->
      List.iter
        (fun (m : (Ast.stmt, unit) Ast.method_def) -> List.iter note m.Ast.md_body)
        impl.Ast.ib_methods
    | _ -> ()
  in
  List.iter note p;
  let ran_meta = ref false in
  let hooks =
    { Metaprocess.quiet with
      meta =
        (fun _ _ ->
          ran_meta := true;
          [])
    ; gen =
        (fun _ _ ->
          ran_meta := true;
          [])
    ; code = (fun _ e -> unknown e.Ast.span)
    ; declof = (fun _ e -> unknown e.Ast.span)
    ; meta_expr = (fun _ e -> unknown e.Ast.span)
    ; static_call =
        (fun _ e ->
          match e.Ast.it with
          | `Static_call (({ Ast.it = `Var name; _ } as callee), static_args, args)
            when Hashtbl.mem comptime name ->
            let declared = Hashtbl.find comptime name in
            if List.length declared <> List.length static_args
            then e
            else (
              let kept =
                List.filter_map
                  (fun ((p : Ast.static_param), a) -> if Metaprocess.value_param traits p then None else Some a)
                  (List.combine declared static_args)
              in
              match kept with
              | [] -> { e with Ast.it = `Call (callee, args) }
              | kept -> { e with Ast.it = `Static_call (callee, kept, args) })
          | _ -> e)
    }
  in
  let rec returns (body : Ast.stmt list) =
    List.exists
      (fun (s : Ast.stmt) ->
        match s.Ast.it with
        | `Return (Some _) -> true
        | `Block b -> returns b
        | `If (_, t, e) -> returns (t :: Option.to_list e)
        | `While (_, b) | `For_in (_, _, b) | `Defer b | `Attributed (_, b) -> returns [ b ]
        | `Match (_, cases) -> List.exists (fun (_, b) -> returns b) cases
        | _ -> false)
      body
  in
  let rec fn (s : Ast.stmt) =
    match Metaprocess.fn_parts s with
    | None -> s
    | Some (name, params, sg, body) ->
      let values, types = List.partition (Metaprocess.value_param traits) sg.Ast.static_params in
      ran_meta := false;
      let body = List.map nested (Metaprocess.tblock hooks S.empty body) in
      let locals =
        List.map
          (fun (sp : Ast.static_param) ->
            Ast.at s.Ast.span (`Var_decl (sp.Ast.sp_name, sp.Ast.sp_ty, Some (unknown s.Ast.span))))
          values
      in
      (* What a meta block would have returned is not known either. Where the
         signature or the body's own `return` already says what that is, the
         value is only of that type: an unknown is never quantified, so
         returning one would fix a generic function's parameters at its first
         call. *)
      let tail =
        if not !ran_meta
        then []
        else if Option.is_none sg.Ast.ret && not (returns body)
        then [ Ast.at s.Ast.span (`Return (Some (unknown s.Ast.span))) ]
        else [ Ast.at s.Ast.span (`Return (Some (anything s.Ast.span))) ]
      in
      Metaprocess.with_body
        (match s.Ast.it with
         | `Fn _ -> { s with Ast.it = `Fn (name, params, { sg with Ast.static_params = types }, []) }
         | `Attributed (attrs, inner) ->
           { s with
             Ast.it =
               `Attributed
                 ( attrs
                 , { inner with Ast.it = `Fn (name, params, { sg with Ast.static_params = types }, []) }
                 )
           }
         | _ -> s)
        (locals @ body @ tail)
  and nested (s : Ast.stmt) : Ast.stmt =
    let it : Ast.stmt_kind =
      match s.Ast.it with
      | `Fn _ -> (fn s).Ast.it
      | `Block b -> `Block (List.map nested b)
      | `If (c, t, e) -> `If (c, nested t, Option.map nested e)
      | `While (c, b) -> `While (c, nested b)
      | `For_in (names, over, b) -> `For_in (names, over, nested b)
      | `Match (subject, cases) -> `Match (subject, List.map (fun (p, b) -> p, List.map nested b) cases)
      | `Defer inner -> `Defer (nested inner)
      | `Impl_decl (trait, ty, params, impl) ->
        `Impl_decl
          ( trait
          , ty
          , params
          , { impl with
              Ast.ib_methods =
                List.map
                  (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                    { m with Ast.md_body = List.map nested m.Ast.md_body })
                  impl.Ast.ib_methods
            } )
      | `Attributed (attrs, inner) -> `Attributed (attrs, nested inner)
      | other -> other
    in
    { s with Ast.it }
  in
  let keeps_types (params : Ast.type_param list) =
    List.filter (fun (p : Ast.type_param) -> Option.is_none p.Ast.tp_ty) params
  in
  let type_decl (s : Ast.stmt) =
    match s.Ast.it with
    | `Type_decl (name, params, body) -> { s with Ast.it = `Type_decl (name, keeps_types params, body) }
    | _ -> s
  in
  let method_of (f : Ast.stmt) : (Ast.stmt, unit) Ast.method_def option =
    match Metaprocess.fn_parts (fn f) with
    | Some (name, params, sg, body) ->
      Some
        { Ast.md_name = name
        ; md_params = params
        ; md_signature = sg
        ; md_body = body
        ; md_ann = ()
        ; md_attrs = Metaprocess.fn_attrs f
        }
    | None -> None
  in
  List.concat_map
    (fun (s : Ast.stmt) ->
      match Metaprocess.deferred_prefix s with
      | Some _ -> []
      | None ->
        (match s.Ast.it with
         | `Meta _ | `Derive _ | `Gen _ -> []
         (* Its impls are then of an unknown trait, which [Typecheck.partial]
            leaves alone; kept with only its written methods, each impl would
            miss what the meta blocks generate. *)
         | `Trait_members _ | `Attributed (_, { Ast.it = `Trait_members _; _ }) -> []

         | `Type_members (({ Ast.it = `Type_decl (name, params, _); _ } as decl), members) ->
           [ type_decl decl
           ; Ast.at
               s.Ast.span
               (`Impl_decl
                 ( None
                 , name
                 , keeps_types params
                 , { Ast.ib_assoc = []; ib_methods = List.filter_map method_of members } ))
           ]
         | `Type_decl _ -> [ type_decl s ]
         | _ when Option.is_some (Metaprocess.fn_parts s) -> [ fn s ]
         | _ -> List.map nested (Metaprocess.tblock hooks S.empty [ s ])))
    p

let program (p : Ast.program) : Diagnostic.error list =
  List.map
    (fun (e : Typecheck.error) -> Diagnostic.at Diagnostic.Type e.Typecheck.span e.Typecheck.message)
    (Typecheck.check
       ~policy:Typecheck.partial
       ~registry:(Registry.builtins ())
       (Compile.under_root (erase (List.filter (fun s -> not (Ast.is_walk_only s)) p))))
