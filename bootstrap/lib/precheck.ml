(* The whole program checked before metaprocessing, reached or not, with every
   meta block's contribution unknown. It reports what is wrong whatever a meta
   block produces, and nothing that a meta block could still make right. *)

module S = Metaprocess.Shadowed

let unknown_name = Ast.generated [ "meta"; "unknown" ]
let unknown span : Ast.expr = Ast.at span (`Var unknown_name)

let traits (p : Ast.program) =
  let found = Hashtbl.create 16 in
  let rec note (s : Ast.stmt) =
    match s.Ast.it with
    | `Trait_decl (name, _, _) -> Hashtbl.replace found name ()
    | `Attributed (_, inner) -> note inner
    | _ -> ()
  in
  List.iter note (Prelude.program ());
  List.iter note p;
  found

let is_value traits (p : Ast.static_param) =
  match p.Ast.sp_ty with
  | None -> false
  | Some { Ast.it = Ast.Ty_name name; _ } | Some { Ast.it = Ast.Ty_app (name, _); _ } ->
    not (Hashtbl.mem traits name)
  | Some _ -> true

(* A value parameter is checked as a local of its declared type: its value is
   what a meta block would read, its type is known now. *)
let erase (p : Ast.program) : Ast.program =
  let traits = traits p in
  let templates = Hashtbl.create 16 in
  let rec note (s : Ast.stmt) =
    (match Metaprocess.fn_parts s with
     | Some (name, _, sg, _) when List.exists (is_value traits) sg.Ast.static_params ->
       Hashtbl.replace templates name sg.Ast.static_params
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
    ; static_call =
        (fun _ e ->
          match e.Ast.it with
          | `Static_call (({ Ast.it = `Var name; _ } as callee), static_args, args)
            when Hashtbl.mem templates name ->
            let declared = Hashtbl.find templates name in
            if List.length declared <> List.length static_args
            then e
            else (
              let kept =
                List.filter_map
                  (fun ((p : Ast.static_param), a) -> if is_value traits p then None else Some a)
                  (List.combine declared static_args)
              in
              match kept with
              | [] -> { e with Ast.it = `Call (callee, args) }
              | kept -> { e with Ast.it = `Static_call (callee, kept, args) })
          | _ -> e)
    }
  in
  let rec fn (s : Ast.stmt) =
    match Metaprocess.fn_parts s with
    | None -> s
    | Some (name, params, sg, body) ->
      let values, types = List.partition (is_value traits) sg.Ast.static_params in
      ran_meta := false;
      let body = List.map nested (Metaprocess.tblock hooks S.empty body) in
      let locals =
        List.map
          (fun (sp : Ast.static_param) ->
            Ast.at s.Ast.span (`Var_decl (sp.Ast.sp_name, sp.Ast.sp_ty, Some (unknown s.Ast.span))))
          values
      in
      (* What a meta block would have returned is not known either. *)
      let tail = if !ran_meta then [ Ast.at s.Ast.span (`Return (Some (unknown s.Ast.span))) ] else [] in
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
      | `For (i, c, st, b) -> `For (i, c, st, nested b)
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
      Some { Ast.md_name = name; md_params = params; md_signature = sg; md_body = body; md_ann = () }
    | None -> None
  in
  List.concat_map
    (fun (s : Ast.stmt) ->
      match Metaprocess.deferred_prefix s with
      | Some _ -> []
      | None ->
        (match s.Ast.it with
         | `Meta _ | `Derive _ | `Gen _ -> []
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
  match Desugar.program (Prelude.program () @ erase p) with
  | Error _ -> []
  | Ok desugared ->
    (match Typecheck.check ~policy:Typecheck.partial ~registry:(Registry.builtins ()) desugared with
     | Ok _ -> []
     | Error errors ->
       List.map
         (fun (e : Typecheck.error) -> Diagnostic.at Diagnostic.Type e.Typecheck.span e.Typecheck.message)
         errors)
