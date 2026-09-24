(* Only the entry contributes statements, so nothing is initialized in an order
   and a cycle is harmless. Names are made unique per unit here. *)

type error =
  { span : Ast.span
  ; message : string
  }

exception Failed of error

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Failed { span; message })) fmt

type unit_ =
  { path : string (* normalized: what a span reports and what `visited` keys on *)
  ; namespace : string
  (* Empty for the package being compiled. Two packages may each hold a
     `parse.cx`, and package names come from a registry rather than from the
     author, so the name they mangle to has to carry the package. *)
  ; package : string
  ; program : Ast.program
  }

let namespace_of path = Filename.remove_extension (Filename.basename path)

(* What a unit is allowed to reach. A package is a set of files under one
   directory; anything outside it is named in the manifest and arrives here as
   a root of its own, so that an import the resolver cannot see is impossible
   rather than merely discouraged. *)
(* A dependency is reached by name. Its source is only opened when nothing has
   compiled it yet: with an artifact, what crosses the boundary is the names it
   exports, and its declarations arrive already mangled. *)
type dependency =
  { dep_root : string
  ; compiled : Artifact.t option
  }

type roots =
  { package : string
  ; std : string option
  ; deps : (string * dependency) list
  }

let anywhere = { package = "/"; std = None; deps = [] }
let from_source root = { dep_root = root; compiled = None }

(* Windows accepts either separator and roots a path at a drive rather than at
   `/`. Both are folded to the one spelling, because [within] below is what
   keeps an import inside its package: a prefix test between two spellings of
   the same path answers wrongly, and which way it is wrong depends on which
   spelling reached it. *)
let slashed = Ast.slashed

(* The drive is upper-cased because `Sys.getcwd` and a path the user wrote need
   not agree on its case, and a difference there is a difference in every prefix
   test built on it. A *segment* whose case differs still compares unequal,
   which refuses an import rather than admitting one. *)
let drive path =
  if Sys.win32
     && String.length path >= 2
     && Char.equal path.[1] ':'
     && (match path.[0] with 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false)
  then Some (String.uppercase_ascii (String.sub path 0 2))
  else None

(* Textual: the visited set only has to agree with itself. *)
let normalize path =
  let path = slashed path in
  let root = drive path in
  let body =
    match root with
    | Some _ -> String.sub path 2 (String.length path - 2)
    | None -> path
  in
  let absolute = String.length body > 0 && Char.equal body.[0] '/' in
  let parts =
    String.split_on_char '/' body
    |> List.filter (fun part -> not (String.equal part "" || String.equal part "."))
    |> List.fold_left
         (fun acc part ->
           match part, acc with
           | "..", previous :: rest when not (String.equal previous "..") -> rest
           | part, acc -> part :: acc)
         []
    |> List.rev
  in
  Option.value root ~default:""
  ^ (if absolute then "/" else "")
  ^ String.concat "/" parts

let canonical path =
  normalize (if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path)

let within ~root path =
  let root = canonical root and path = canonical path in
  (* A root that is already a root -- `/`, or `C:/` -- carries its separator, and
     appending another would make a prefix nothing matches. *)
  let prefix = if String.ends_with ~suffix:"/" root then root else root ^ "/" in
  String.equal root "/" || String.equal path root || String.starts_with ~prefix path

(* The root a file belongs to, which is what its own imports are measured
   against: a dependency's file may move within the dependency, not within
   whoever imported it. *)
let owner roots path =
  let candidates =
    (match roots.std with Some dir -> [ dir ] | None -> [])
    @ List.map (fun (_, d) -> d.dep_root) roots.deps
    @ [ roots.package ]
  in
  match List.filter (fun root -> within ~root path) candidates with
  | [] -> roots.package
  | roots ->
    List.fold_left
      (fun best root -> if String.length root > String.length best then root else best)
      (List.hd roots)
      roots

let with_extension path =
  if Filename.check_suffix path ".cx" then path else path ^ ".cx"

let first_segment path =
  match String.index_opt path '/' with
  | None -> path, ""
  | Some i -> String.sub path 0 i, String.sub path (i + 1) (String.length path - i - 1)

(* A package's own module, reached by name rather than by path. `http` is its
   root module and `http/client` is a module beside it. *)
let in_package root rest =
  Filename.concat root (Filename.concat "src" (if String.equal rest "" then "lib" else rest))

(* Where an import lands: a file to read, or a package already compiled, whose
   names are known without reading anything. *)
type target =
  | File of string
  | Compiled of string * Artifact.unit_interface

let resolve_import roots span ~from path =
  let segment, rest = first_segment path in
  match segment, List.assoc_opt segment roots.deps with
  | "std", _ ->
    (match roots.std with
     | Some dir when not (String.equal rest "") ->
       File (with_extension (Filename.concat dir rest))
     | Some _ -> fail span "'std' is the standard library; import a module inside it."
     | None -> fail span "Cannot find the standard library.")
  | _, Some { compiled = Some artifact; _ } ->
    let namespace = if String.equal rest "" then segment else namespace_of rest in
    (match Artifact.interface artifact namespace with
     | Some interface -> Compiled (segment, interface)
     | None -> fail span "'%s' has no module '%s'." segment namespace)
  | _, Some { dep_root = root; compiled = None } ->
    File (with_extension (in_package root rest))
  | _, None ->
    let resolved =
      let path = with_extension path in
      if Filename.is_relative path
      then Filename.concat (Filename.dirname from) path
      else path
    in
    let root = owner roots from in
    (* Naming the root here would put an absolute path in a diagnostic, which
       is the one thing Diagnostics.md says a span may not carry. *)
    if not (within ~root resolved)
    then
      fail
        span
        "'%s' reaches outside its package. A package is the files under one directory, and \
         everything else arrives through a dependency name."
        path;
    File resolved

let parse_unit span path =
  if not (Sys.file_exists path) then fail span "Cannot find module '%s'." path;
  match Source_map.File.load path with
  | Error message -> fail span "%s" message
  | Ok file ->
    (match Scanner.scan_tokens file with
     | Error (e :: _) -> fail e.Scanner.span "%s" e.Scanner.message
     | Error [] -> fail span "'%s' does not scan." path
     | Ok tokens ->
       (match Parser.parse tokens with
        | Error (e :: _) -> fail e.Parser.span "%s" e.Parser.message
        | Error [] -> fail span "'%s' does not parse." path
        | Ok program -> program))

(* Sorted, so the expansion does not depend on readdir order. *)
let expand_wildcards roots ~from (program : Ast.program) =
  List.concat_map
    (fun (s : Ast.stmt) ->
      match s.Ast.it with
      | `Import (Ast.Wildcard dir) ->
        let base =
          match resolve_import roots s.Ast.span ~from (dir ^ "/x") with
          | File path -> Filename.dirname (Filename.remove_extension path)
          | Compiled _ ->
            fail s.Ast.span "A wildcard import reaches a directory, not a dependency."
        in
        if not (Sys.file_exists base && Sys.is_directory base)
        then fail s.Ast.span "Cannot find directory '%s'." dir;
        Sys.readdir base
        |> Array.to_list
        |> List.filter (fun name -> Filename.check_suffix name ".cx")
        |> List.sort String.compare
        |> List.map (fun name ->
          { s with
            Ast.it = `Import (Ast.Qualified (dir ^ "/" ^ Filename.remove_extension name))
          })
      | _ -> [ s ])
    program

let imports (program : Ast.program) =
  List.filter_map
    (fun (s : Ast.stmt) ->
      match s.Ast.it with
      | `Import decl -> Some (decl, s.Ast.span)
      | _ -> None)
    program

let path_of = function
  | Ast.Qualified path | Ast.Aliased (path, _) | Ast.Selective (_, path) | Ast.Wildcard path ->
    path

(* Which package a file belongs to, by the root it sits under. *)
let package_of roots path =
  let owned name root = if within ~root path then Some name else None in
  let candidates =
    (match roots.std with Some dir -> [ owned "std" dir ] | None -> [])
    @ List.map (fun (name, d) -> owned name d.dep_root) roots.deps
  in
  match List.filter_map Fun.id candidates with
  | name :: _ -> name
  | [] -> ""

(* A unit already seen is skipped rather than rejected: a cycle is legal. *)
(* [seeds] are the package's other files. A library's `src/lib.cx` need not
   import every module beside it, and an artifact that held only what the entry
   reached would be missing the rest. *)
let load roots ?namespace:entry_namespace ?(seeds = []) entry =
  let visited = Hashtbl.create 8 in
  let units = ref [] in
  (* The namespace comes from the import as written, not from the file it
     resolves to: a dependency's root module is `src/lib.cx` and is reached as
     the package's own name. *)
  let rec walk span ~namespace path =
    let path = normalize path in
    if not (Hashtbl.mem visited path)
    then (
      Hashtbl.replace visited path ();
      let program = expand_wildcards roots ~from:path (parse_unit span path) in
      units := { path; namespace; package = package_of roots path; program } :: !units;
      List.iter
        (fun (decl, span) ->
          let written = path_of decl in
          match resolve_import roots span ~from:path written with
          | File resolved -> walk span ~namespace:(namespace_of written) resolved
          (* Nothing to read: the package was compiled, and what it exports came
             with it. *)
          | Compiled _ -> ())
        (imports program))
  in
  let root = Source_map.Span.nowhere in
  walk root ~namespace:(Option.value entry_namespace ~default:(namespace_of entry)) entry;
  List.iter (fun path -> walk root ~namespace:(namespace_of path) path) seeds;
  let all = List.rev !units in
  let entry_path = normalize entry in
  match List.partition (fun u -> String.equal u.path entry_path) all with
  | [ entry_unit ], rest -> entry_unit, rest
  | _ -> fail root "Cannot find the entry module."

(* ---- resolution ---- *)

(* An `impl` exports nothing: its methods are reached through its type. *)
(* An attribute wraps the declaration it is written on, so both of these look
   through one: what a unit exports and what linking deduplicates are questions
   about the declaration, not about how it was marked. *)
let rec declared_name (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn (name, _, _, _) -> Some name
  | `Type_decl (name, _, _) -> Some name
  | `Type_members (decl, _) -> declared_name decl
  | `Trait_decl (name, _, _) -> Some name
  | `Attributed (_, inner) -> declared_name inner
  | _ -> None

let rec is_declaration (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn _ | `Type_decl _ | `Trait_decl _ | `Impl_decl _ | `Effect_decl _
  | `Handler_decl _ | `Import _ | `Meta _ | `Gen _ | `Derive _ | `Type_members _ -> true
  | `Attributed (_, inner) -> is_declaration inner
  | _ -> false

let exports unit_ = List.filter_map declared_name unit_.program

let renamed (unit_ : unit_) ~entry name =
  if entry
  then name
  else if String.equal unit_.package ""
  then Ast.generated [ unit_.namespace; name ]
  else if String.equal unit_.package unit_.namespace
  then (* A package's root module is reached as the package. *)
    Ast.generated [ unit_.package; name ]
  else Ast.generated [ unit_.package; unit_.namespace; name ]

(* So a rename never touches a local spelled like a top-level function. *)
let rec bound_by (s : Ast.stmt) =
  match s.Ast.it with
  | `Var_decl (name, _, _) -> [ name ]
  | `Block body -> List.concat_map bound_by body
  | _ -> []

let rewrite ~aliases ~direct ~own ~rename ~from (program : Ast.program) =
  let module S = Set.Make (String) in
    let resolve_local name =
    match Hashtbl.find_opt direct name with
    | Some target -> target
    | None -> if Hashtbl.mem own name then rename name else name
  in
    let resolve_type name =
    match String.index_opt name '.' with
    | Some at ->
      let namespace = String.sub name 0 at
      and field = String.sub name (at + 1) (String.length name - at - 1) in
      (match Hashtbl.find_opt aliases namespace with
       | Some qualify -> qualify field
       | None -> name)
    | None -> resolve_local name
  in
  let rec type_expr (t : Ast.type_expr) : Ast.type_expr =
    let it : Ast.type_expr_kind =
      match t.Ast.it with
      | Ast.Ty_variadic t -> Ast.Ty_variadic (type_expr t)
      | Ast.Ty_spread t -> Ast.Ty_spread (type_expr t)
      | Ast.Ty_name name -> Ast.Ty_name (resolve_type name)
      | Ast.Ty_assoc ({ Ast.it = Ast.Ty_name namespace; _ }, member)
        when Hashtbl.mem aliases namespace ->
        Ast.Ty_name ((Hashtbl.find aliases namespace) member)
      | Ast.Ty_assoc (owner, member) -> Ast.Ty_assoc (type_expr owner, member)
      | Ast.Ty_bind (bound, t) -> Ast.Ty_bind (bound, type_expr t)
      | Ast.Ty_app (name, args) ->
        Ast.Ty_app (resolve_type name, List.map type_expr args)
      | Ast.Ty_tuple items -> Ast.Ty_tuple (List.map type_expr items)
      | Ast.Ty_record fields ->
        Ast.Ty_record (List.map (fun (l, t) -> l, type_expr t) fields)
      | Ast.Ty_fn (params, ret, row) ->
        Ast.Ty_fn (List.map type_expr params, type_expr ret, row)
    in
    { t with Ast.it }
  in
  let param (p : Ast.param) = { p with Ast.ty = Option.map type_expr p.Ast.ty } in
  let signature (sg : Ast.signature) =
    { sg with
      Ast.ret = Option.map type_expr sg.Ast.ret
    ; static_params =
        List.map
          (fun (c : Ast.static_param) ->
            { c with Ast.sp_ty = Option.map type_expr c.Ast.sp_ty })
          sg.Ast.static_params
    }
  in
  let rec expr locals (e : Ast.expr) : Ast.expr =
    let go = expr locals in
    let it : Ast.expr_kind =
      match e.Ast.it with
      | `Lambda (params, signature, body) ->
        let inner =
          List.fold_left (fun acc (p : Ast.param) -> S.add p.Ast.name acc) locals params
        in
        `Lambda (params, signature, List.map (stmt inner) body)
      (* Read here, where the source file it was written in is known. *)
      | `Call ({ Ast.it = `Var "embed"; _ }, [ { Ast.it = `Str path; _ } ]) ->
        let path = Utf8.encode path in
        let full =
          if Filename.is_relative path
          then Filename.concat (Filename.dirname from) path
          else path
        in
        Inputs.record full;
        (match In_channel.with_open_bin full In_channel.input_all with
         | contents -> `Bytes contents
         | exception Sys_error _ -> fail e.Ast.span "Cannot embed '%s'." path)
      | `Code inner -> `Code (go inner)
      | `Var name when not (S.mem name locals) -> `Var (resolve_local name)
      (* A method call unless `math` names a module and nothing took the name. *)
      | `Method_call ({ Ast.it = `Var receiver; _ }, name, _, args)
        when (not (S.mem receiver locals)) && Hashtbl.mem aliases receiver ->
        `Call
          ( { e with Ast.it = `Var (Hashtbl.find aliases receiver name) }
          , List.map go args )
      (* `util.f<1>()` and `animals.Cat`: a name read out of a module. *)
      | `Field ({ Ast.it = `Var receiver; _ }, name)
        when (not (S.mem receiver locals)) && Hashtbl.mem aliases receiver ->
        `Var (Hashtbl.find aliases receiver name)
      (* Not known here, so the name it would have as a function is carried
         along for whoever can tell. *)
      | `Method_call (receiver, name, _, args) ->
        let as_function = if S.mem name locals then name else resolve_local name in
        `Method_call (go receiver, name, as_function, List.map go args)
      | `New (name, fields) ->
        `New (resolve_type name, List.map (fun (l, v) -> l, go v) fields)
      | `New_generic (name, static_args, fields) ->
        `New_generic
          ( resolve_type name
          , List.map
              (function
                | Ast.St_type t -> Ast.St_type (type_expr t)
                | Ast.St_value v -> Ast.St_value (go v))
              static_args
          , List.map (fun (l, v) -> l, go v) fields )
      | `New_variant (ty, variant, payload) ->
        `New_variant (resolve_type ty, variant, Ast.map_payload go payload)
      | `New_call (name, args, values) ->
        `New_call (resolve_type name, List.map type_expr args, List.map go values)
      | #Ast.lit as l -> l
      | #Ast.vars as v -> (Ast.map_vars go v :> Ast.expr_kind)
      | #Ast.ops as o -> (Ast.map_ops go o :> Ast.expr_kind)
      | #Ast.logic as l -> (Ast.map_logic go l :> Ast.expr_kind)
      | #Ast.compound as c -> (Ast.map_compound go c :> Ast.expr_kind)
      | #Ast.indexing as i -> (Ast.map_indexing go i :> Ast.expr_kind)
      | #Ast.tuple as t -> (Ast.map_tuple go t :> Ast.expr_kind)
      | #Ast.spread as s -> (Ast.map_spread go s :> Ast.expr_kind)
      | #Ast.record as r -> (Ast.map_record go r :> Ast.expr_kind)
      | #Ast.collection as c -> (Ast.map_collection go c :> Ast.expr_kind)
      | #Ast.static_call as c -> (Ast.map_static_call go c :> Ast.expr_kind)
      | #Ast.reflect as r -> (Ast.map_reflect go r :> Ast.expr_kind)
      | #Ast.run_expr as r ->
        let clause (c : Ast.stmt Ast.handler_clause) =
          match c with
          | Ast.Inline h -> Ast.Inline (Ast.map_handler (stmt locals) h)
          | Ast.Named name -> Ast.Named name
        in
        (Ast.map_run_expr go (stmt locals) clause r :> Ast.expr_kind)
    in
    { e with Ast.it }
  and stmt locals (s : Ast.stmt) : Ast.stmt =
    let it : Ast.stmt_kind =
      match s.Ast.it with
      | `Attributed (attrs, inner) -> `Attributed (attrs, stmt locals inner)
      | `Type_members (decl, members) ->
        `Type_members (stmt locals decl, List.map (stmt locals) members)
      | `Type_decl (name, params, body) ->
        let body =
          match body with
          | Ast.T_fields fields ->
            Ast.T_fields
              (List.map (fun (f : Ast.field) -> { f with Ast.f_ty = type_expr f.Ast.f_ty }) fields)
          | Ast.T_variants variants ->
            Ast.T_variants
              (List.map
                 (fun (v : Ast.variant) ->
                   { v with
                     Ast.v_payload = Ast.map_payload type_expr v.Ast.v_payload
                   ; v_result = Option.map type_expr v.Ast.v_result
                   })
                 variants)
        in
        `Type_decl (resolve_type name, params, body)
      | `Trait_decl (name, params, body) ->
        `Trait_decl
          ( resolve_type name
          , params
          , { body with
              Ast.tb_super =
                List.map
                  (fun (super, args) -> resolve_type super, List.map type_expr args)
                  body.Ast.tb_super
            ; tb_methods =
                List.map
                  (fun (m : Ast.method_sig) ->
                    { m with
                      Ast.ms_params = List.map param m.Ast.ms_params
                    ; ms_signature = signature m.Ast.ms_signature
                    })
                  body.Ast.tb_methods
            } )
      | `Derive (traits, target) ->
        `Derive (List.map resolve_type traits, resolve_type target)
      | `Impl_decl (trait, type_name, params, impl) ->
        `Impl_decl
          ( Option.map (fun (t, args) -> resolve_type t, List.map type_expr args) trait
          , resolve_type type_name
          , params
          , { Ast.ib_assoc = List.map (fun (n, t) -> n, type_expr t) impl.Ast.ib_assoc
            ; ib_methods =
                List.map
                  (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                    { m with
                      Ast.md_params = List.map param m.Ast.md_params
                    ; md_signature = signature m.Ast.md_signature
                    ; md_body = List.map (stmt locals) m.Ast.md_body
                    })
                  impl.Ast.ib_methods
            } )
      | `Fn (name, params, sg, body) ->
        let inner =
          List.fold_left
            (fun acc (p : Ast.param) -> S.add p.Ast.name acc)
            locals
            params
        in
        let inner = List.fold_left (fun acc s -> S.union acc (S.of_list (bound_by s))) inner body in
        `Fn
          ( (if Hashtbl.mem own name then rename name else name)
          , List.map param params
          , signature sg
          , List.map (stmt inner) body )
      | `Block body ->
        let inner = List.fold_left (fun acc s -> S.union acc (S.of_list (bound_by s))) locals body in
        `Block (List.map (stmt inner) body)
      | `Var_decl (name, ty, init) ->
        `Var_decl (name, Option.map type_expr ty, Option.map (expr locals) init)
      | `Var_tuple (names, init) -> `Var_tuple (names, expr locals init)
      | `Import _ -> `Block []
      | `Meta body -> `Meta (List.map (stmt locals) body)
      | `Gen inner -> `Gen (stmt locals inner)
      | #Ast.stmts as st -> (Ast.map_stmts (expr locals) (stmt locals) st :> Ast.stmt_kind)
      (* A loop variable binds for the body alone, so not via [bound_by]. *)
      | `For_in (names, over, body) ->
        `For_in
          (names, expr locals over, stmt (List.fold_left (Fun.flip S.add) locals names) body)
      | `For (init, cond, step, body) ->
        let inner =
          match init with
          | Some s -> S.union locals (S.of_list (bound_by s))
          | None -> locals
        in
        `For
          ( Option.map (stmt locals) init
          , Option.map (expr inner) cond
          , Option.map (expr inner) step
          , stmt inner body )
      | #Ast.effects as e ->
        let clause (c : Ast.stmt Ast.handler_clause) =
          match c with
          | Ast.Inline h -> Ast.Inline (Ast.map_handler (stmt locals) h)
          | Ast.Named name -> Ast.Named name
        in
        (Ast.map_effects (expr locals) (stmt locals) clause e :> Ast.stmt_kind)
      | `Handler_decl (name, h) -> `Handler_decl (name, Ast.map_handler (stmt locals) h)
            | `Match (scrutinee, cases) ->
        `Match
          ( expr locals scrutinee
          , List.map
              (fun (p, body) ->
                let payload =
                  match p with
                  | Ast.Pat_variant (_, _, payload) -> payload
                  | Ast.Pat_wild -> Ast.P_none
                in
                let p =
                  match p with
                  | Ast.Pat_variant (ty, variant, payload) ->
                    Ast.Pat_variant (resolve_type ty, variant, payload)
                  | Ast.Pat_wild -> Ast.Pat_wild
                in
                let inner =
                  List.fold_left
                    (fun acc (_, binding) -> S.add binding acc)
                    locals
                    (Ast.payload_fields payload)
                in
                p, List.map (stmt inner) body)
              cases )
    in
    { s with Ast.it }
  in
  List.map (stmt S.empty) program

(* The declarations, and what each unit of this package exports so that a
   consumer can bind the names without reading the source again. *)
(* [entry_namespace] is the name a consumer reaches this package by, which is
   the package's own rather than its entry file's: `src/lib.cx` is imported as
   the package. *)
let package ?(roots = anywhere) ?entry_namespace ?seeds entry_path =
  let entry_unit, rest = load roots ?namespace:entry_namespace ?seeds entry_path in
  (* A file run on its own keeps its declarations under the names it wrote; a
     package carries them under its own, because a consumer will link them
     beside somebody else's. *)
  let plain_entry = Option.is_none entry_namespace in
  (* Every unit of the package being compiled, not only its entry. A unit that
     already names a package came from somewhere else. *)
  let owned (u : unit_) =
    match entry_namespace with
    | Some package when String.equal u.package "" -> { u with package }
    | _ -> u
  in
  let entry_unit = owned entry_unit in
  let rest = List.map owned rest in
  let table = Hashtbl.create 8 in
  (* Keyed by file rather than by namespace: two packages may each hold a unit
     of the same name, and only the path tells them apart. *)
  List.iter (fun u -> Hashtbl.replace table u.path (u, exports u)) (entry_unit :: rest);
  let resolve_unit u ~entry =
    let own = Hashtbl.create 8 in
    List.iter (fun name -> Hashtbl.replace own name ()) (exports u);
    let aliases = Hashtbl.create 4 in
    let direct = Hashtbl.create 4 in
    List.iter
      (fun (decl, span) ->
        let written = path_of decl in
        let target = namespace_of written in
        let found =
          match resolve_import roots span ~from:u.path written with
          | File path ->
            (match Hashtbl.find_opt table (normalize path) with
             | Some (unit_, exports) -> Some (unit_, exports)
             | None -> None)
          | Compiled (package, interface) ->
            (* The declarations are already in the program, mangled by whoever
               compiled them; only the names have to be bound here. *)
            Some
              ( { path = ""
                ; namespace = interface.Artifact.namespace
                ; package
                ; program = []
                }
              , interface.Artifact.exports )
        in
        match found with
        | None -> fail span "Module '%s' was not loaded." target
        | Some (target_unit, target_exports) ->
          let is_entry =
            plain_entry && String.equal target_unit.path entry_unit.path
          in
          let bind under =
            if Hashtbl.mem aliases under
            then fail span "'%s' is already bound. Import one of them with `as`." under;
            Hashtbl.replace aliases under (fun name -> renamed target_unit ~entry:is_entry name)
          in
          (match decl with
           | Ast.Qualified _ -> bind target
           | Ast.Aliased (_, alias) -> bind alias
           | Ast.Selective (names, _) ->
             List.iter
               (fun name ->
                 if not (List.mem name target_exports)
                 then fail span "Module '%s' does not export '%s'." target name;
                 if Hashtbl.mem direct name
                 then fail span "'%s' is already imported." name;
                 Hashtbl.replace direct name (renamed target_unit ~entry:is_entry name))
               names
           | Ast.Wildcard _ -> ()))
      (imports u.program);
    rewrite
      ~aliases
      ~direct
      ~own
      ~rename:(fun name -> renamed u ~entry name)
      ~from:u.path
      u.program
  in
  (* [entry] says whose names stay plain; [keep] says whose statements run. A
     module's statements run only when it is the file being run, so importing
     one loads its declarations and nothing else. *)
  let declarations_of u ~entry ~keep =
    resolve_unit u ~entry |> List.filter (fun s -> is_declaration s || keep)
  in
  (* A module's own meta blocks wait for the walk to first ask it for a name. *)
  let deferred u (s : Ast.stmt) =
    match s.Ast.it with
    | `Meta _ | `Derive _ -> Ast.deferred ~unit_prefix:(renamed u ~entry:false "") s
    | _ -> s
  in
  ( List.concat_map
      (fun u -> List.map (deferred u) (declarations_of u ~entry:false ~keep:false))
      rest
    @ declarations_of entry_unit ~entry:plain_entry ~keep:true
  , List.map
      (fun u -> { Artifact.namespace = u.namespace; exports = exports u })
      (entry_unit :: rest) )

let program ?roots entry_path = fst (package ?roots entry_path)
