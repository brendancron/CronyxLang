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
  (* The file's own doc comment, which belongs to no declaration in it. *)
  ; doc : string option
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

(* Where a file sits inside the root that owns it. Nothing a build machine
   knows survives this, which is what lets an artifact's path be reported. *)
let under roots path =
  let root = canonical (owner roots path) in
  let path = canonical path in
  let prefix = if String.ends_with ~suffix:"/" root then root else root ^ "/" in
  if String.starts_with ~prefix path
  then String.sub path (String.length prefix) (String.length path - String.length prefix)
  else Filename.basename path

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
       (match Parser.parse_unit tokens with
        | Error (e :: _) -> fail e.Parser.span "%s" e.Parser.message
        | Error [] -> fail span "'%s' does not parse." path
        | Ok parsed -> parsed))

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

(* Every import a file names, global or not: what loading it has to read. *)
let imports (program : Ast.program) =
  List.filter_map
    (fun (s : Ast.stmt) ->
      match s.Ast.it with
      | `Import decl | `Global_import decl -> Some (decl, s.Ast.span)
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
(* What every program has without importing it: loaded with every program, so
   what it imports is loaded once, beside whatever the program imports itself. *)
let prelude roots =
  match roots.std with
  | Some dir ->
    let path = Filename.concat dir "prelude.cx" in
    if Sys.file_exists path then Some (normalize path) else None
  | None -> None

let load roots ?namespace:entry_namespace ?(seeds = []) ?(core = true) entry =
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
      let program, doc = parse_unit span path in
      let program = expand_wildcards roots ~from:path program in
      units := { path; namespace; doc; package = package_of roots path; program } :: !units;
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
  Option.iter (fun path -> walk root ~namespace:(namespace_of path) path) (prelude roots);
  (match roots.std with
   | _ when not core -> ()
   | Some dir ->
     List.iter
       (fun m ->
         let path = with_extension (Filename.concat dir m) in
         if not (Sys.file_exists path)
         then
           fail
             root
             "The standard library has no `%s`, and every program is compiled with `core`. Set \
              CRONYX_STDLIB to the library this toolchain ships."
             m;
         walk root ~namespace:(namespace_of path) path)
       Core.modules
   | None ->
     fail
       root
       "Cannot find the standard library, which every program is compiled with. Set \
        CRONYX_STDLIB to the library this toolchain ships.");
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
  (* An effect and a handler are declarations like any other: both carry the
     unit's name and both are imported by it. Their *operations* are not --
     an operation is a member of its effect, reached through it. *)
  | `Effect_decl (name, _, _) -> Some name
  | `Handler_decl (name, _) -> Some name
  | `Attributed (_, inner) -> declared_name inner
  | _ -> None

(* The operations as written. Each carries its module's name as every
   declaration does, so two modules may both declare `yield`; a bare one is
   reached through its effect, imported by name. *)
let rec operations (s : Ast.stmt) =
  match s.Ast.it with
  | `Effect_decl (_, _, ops) -> List.map (fun (o : Ast.op_decl) -> o.Ast.op_name) ops
  | `Attributed (_, inner) -> operations inner
  | _ -> []

let rec effects_of (s : Ast.stmt) =
  match s.Ast.it with
  | `Effect_decl (name, _, ops) -> [ name, List.map (fun (o : Ast.op_decl) -> o.Ast.op_name) ops ]
  | `Attributed (_, inner) -> effects_of inner
  | _ -> []

let rec is_declaration (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn _ | `Type_decl _ | `Trait_decl _ | `Impl_decl _ | `Effect_decl _
  | `Handler_decl _ | `Import _ | `Global_import _ | `Meta _ | `Gen _ | `Derive _
  | `Type_members _ -> true
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
  | `Var_decl (name, _, _) | `Fn (name, _, _, _) -> [ name ]
  | `Var_tuple (names, _) -> names
  | `Block body -> List.concat_map bound_by body
  | _ -> []

let rewrite ~aliases ~direct ~own ~foreign ~ops ~rename ~from (program : Ast.program) =
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
      | Ast.Ty_row row -> Ast.Ty_row (effect_row row)
      | Ast.Ty_app (name, args) ->
        Ast.Ty_app (resolve_type name, List.map type_expr args)
      | Ast.Ty_tuple items -> Ast.Ty_tuple (List.map type_expr items)
      | Ast.Ty_record fields ->
        Ast.Ty_record (List.map (fun (l, t) -> l, type_expr t) fields)
      | Ast.Ty_fn (params, ret, row) ->
        Ast.Ty_fn (List.map type_expr params, type_expr ret, effect_row row)
    in
    { t with Ast.it }
  (* A written row names effects, which are declarations and so are resolved
     like one. *)
  and effect_row row =
    List.map (fun (label, args) -> resolve_type label, List.map type_expr args) row
  in
  let param (p : Ast.param) = { p with Ast.ty = Option.map type_expr p.Ast.ty } in
  let signature (sg : Ast.signature) =
    { Ast.ret = Option.map type_expr sg.Ast.ret
    ; row = Option.map effect_row sg.Ast.row
    ; static_params =
        List.map
          (fun (c : Ast.static_param) ->
            { c with Ast.sp_ty = Option.map type_expr c.Ast.sp_ty })
          sg.Ast.static_params
    }
  in
  (* An operation is named after its module, as every declaration is, so an
     arm is named after the effect it handles: `std#Throw#Throw`'s `throw` is
     `std#Throw#throw`, and a plain effect's operations stay plain. *)
  let rec handler locals (h : Ast.stmt Ast.handler) : Ast.stmt Ast.handler =
    let handled = resolve_type h.Ast.handled in
    let prefix =
      match String.rindex_opt handled '#' with
      | Some at -> String.sub handled 0 (at + 1)
      | None -> ""
    in
    let h = Ast.map_handler (stmt locals) h in
    { Ast.handled
    ; arms = List.map (fun (a : Ast.stmt Ast.arm) -> { a with Ast.arm_name = prefix ^ a.Ast.arm_name }) h.Ast.arms
    }

  and handler_clause locals (c : Ast.stmt Ast.handler_clause) =
    match c with
    | Ast.Inline h -> Ast.Inline (handler locals h)
    | Ast.Named name -> Ast.Named (resolve_type name)

  and expr locals (e : Ast.expr) : Ast.expr =
    let go = expr locals in
    let it : Ast.expr_kind =
      match e.Ast.it with
      | `Lambda (params, sg, body) ->
        let inner =
          List.fold_left (fun acc (p : Ast.param) -> S.add p.Ast.name acc) locals params
        in
        let inner = List.fold_left (fun acc s -> S.union acc (S.of_list (bound_by s))) inner body in
        `Lambda (List.map param params, signature sg, List.map (stmt inner) body)
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
      | `Code_stmts body ->
        let inner = List.fold_left (fun acc s -> S.union acc (S.of_list (bound_by s))) locals body in
        `Code_stmts (List.map (stmt inner) body)
      | `Code_decl decl -> `Code_decl (stmt locals decl)
      (* What the file declares or imports by name first: an operation of an
         effect every package imports must not take a name from the file's own
         `fn write`. *)
      | `Var name when (not (S.mem name locals)) && (Hashtbl.mem direct name || Hashtbl.mem own name) ->
        `Var (resolve_local name)
      | `Var name when not (S.mem name locals) ->
        (match Hashtbl.find_opt foreign name with
         | Some (declaring, namespace) ->
           fail
             e.Ast.span
             "'%s' is an operation of '%s', which this file does not import by name. Write \
              '%s.%s', or import { %s } from its module."
             name
             declaring
             namespace
             name
             declaring
         | None ->
           (match Hashtbl.find_opt ops name with
            | Some operation -> `Var operation
            | None -> `Var (resolve_local name)))
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
      (* `geom.Point { … }` parses as a variant of `geom` until `geom` turns
         out to be a module. *)
      | `New_variant (namespace, name, Ast.P_fields fields)
        when (not (S.mem namespace locals)) && Hashtbl.mem aliases namespace ->
        `New (Hashtbl.find aliases namespace name, List.map (fun (l, v) -> l, go v) fields)
      | `New_variant (ty, variant, payload) ->
        `New_variant (resolve_type ty, variant, Ast.map_payload go payload)
      | `New_call (name, args, values) ->
        `New_call (resolve_type name, List.map type_expr args, List.map go values)
      | `Static_call (callee, static_args, args) ->
        `Static_call
          ( go callee
          , List.map
              (function
                (* A bare name parses as a type whichever it is, so a local
                   value is left for the scope that binds it. *)
                | Ast.St_type { Ast.it = Ast.Ty_name name; _ } as arg when S.mem name locals -> arg
                | Ast.St_type t -> Ast.St_type (type_expr t)
                | Ast.St_value v -> Ast.St_value (go v))
              static_args
          , List.map go args )
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
      | #Ast.reflect as r -> (Ast.map_reflect go r :> Ast.expr_kind)
      | #Ast.run_expr as r ->
        (Ast.map_run_expr go (stmt locals) (handler_clause locals) r :> Ast.expr_kind)
      | `Match_expr (scrutinee, cases) ->
        `Match_expr
          ( go scrutinee
          , List.map
              (fun (p, b) ->
                let p, inner = pattern locals p in
                p, Ast.map_valued_block (expr inner) (stmt inner) b)
              cases )
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
          , { Ast.ib_assoc =
                List.map
                  (fun (a : Ast.assoc_def) -> { a with Ast.as_ty = type_expr a.Ast.as_ty })
                  impl.Ast.ib_assoc
            ; ib_methods =
                List.map
                  (fun (m : (Ast.stmt, unit) Ast.method_def) ->
                    let inner =
                      List.fold_left
                        (fun acc (p : Ast.param) -> S.add p.Ast.name acc)
                        locals
                        m.Ast.md_params
                    in
                    let inner =
                      List.fold_left (fun acc s -> S.union acc (S.of_list (bound_by s))) inner m.Ast.md_body
                    in
                    { m with
                      Ast.md_params = List.map param m.Ast.md_params
                    ; md_signature = signature m.Ast.md_signature
                    ; md_body = List.map (stmt inner) m.Ast.md_body
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
        let inner =
          List.fold_left
            (fun acc (c : Ast.static_param) -> S.add c.Ast.sp_name acc)
            inner
            sg.Ast.static_params
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
      | `Import _ | `Global_import _ -> `Block []
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
        let clause = handler_clause locals in
        let e =
          match e with
          | `Effect_decl (name, params, declared) ->
            `Effect_decl
              ( (if Hashtbl.mem own name then rename name else name)
              , params
              , List.map
                  (fun (o : Ast.op_decl) ->
                    { o with
                      Ast.op_name = Option.value (Hashtbl.find_opt ops o.Ast.op_name) ~default:o.Ast.op_name
                    ; op_params = List.map param o.Ast.op_params
                    ; op_ret = Option.map type_expr o.Ast.op_ret
                    })
                  declared )
          | other -> other
        in
        (Ast.map_effects (expr locals) (stmt locals) clause e :> Ast.stmt_kind)
      | `Handler_decl (name, h) ->
        `Handler_decl ((if Hashtbl.mem own name then rename name else name), handler locals h)
      | `Match (scrutinee, cases) ->
        `Match
          ( expr locals scrutinee
          , List.map
              (fun (p, body) ->
                let p, inner = pattern locals p in
                p, List.map (stmt inner) body)
              cases )
    in
    { s with Ast.it }
  and pattern locals (p : Ast.pattern) =
    match p with
    | Ast.Pat_wild -> Ast.Pat_wild, locals
    | Ast.Pat_variant (ty, variant, payload) ->
      ( Ast.Pat_variant (resolve_type ty, variant, payload)
      , List.fold_left
          (fun acc (_, binding) -> S.add binding acc)
          locals
          (Ast.payload_fields payload) )
  in
  (* A top-level `var` binds for the whole file, as a declaration does, so a
     name the prelude brings -- `Console`'s `write` -- does not take it. *)
  let rec top_level_vars (s : Ast.stmt) =
    match s.Ast.it with
    | `Var_decl (name, _, _) -> [ name ]
    | `Var_tuple (names, _) -> names
    | `Attributed (_, inner) -> top_level_vars inner
    | _ -> []
  in
  List.map (stmt (S.of_list (List.concat_map top_level_vars program))) program

(* The declarations, and what each unit of this package exports so that a
   consumer can bind the names without reading the source again. *)
(* [entry_namespace] is the name a consumer reaches this package by, which is
   the package's own rather than its entry file's: `src/lib.cx` is imported as
   the package. *)
(* [entry_unit] is the file being run, when there is one. A library has none:
   its modules are all imported and none is a program, so nothing keeps plain
   names and no statements run. *)
let assemble roots ~package:own ~plain_entry ~entry_unit ~rest =
  let all = Option.to_list entry_unit @ rest in
  let table = Hashtbl.create 8 in
  (* Keyed by file rather than by namespace: two packages may each hold a unit
     of the same name, and only the path tells them apart. *)
  List.iter (fun u -> Hashtbl.replace table u.path (u, exports u)) all;
  (* An operation keeps its written name, so without this a file could perform
     one from a module it never named, and which module a name comes from would
     stop being something the file says. *)
  let known_operations =
    List.concat_map
      (fun u ->
        List.concat_map effects_of u.program
        |> List.concat_map (fun (declaring, ops) ->
          List.map (fun op -> op, (declaring, u.namespace)) ops))
      all
  in
  (* A `global import` binds in every file of its package, resolved from the
     file that wrote it; the prelude's bind in every file of every package. *)
  let written_in kind (u : unit_) =
    List.filter_map
      (fun (s : Ast.stmt) ->
        match s.Ast.it, kind with
        | `Import decl, `Local | `Global_import decl, `Global -> Some (decl, s.Ast.span, u.path)
        | _ -> None)
      u.program
  in
  let implicit =
    match prelude roots with
    | Some path -> List.concat_map (written_in `Global) (List.filter (fun (u : unit_) -> String.equal u.path path) all)
    | None -> []
  in
  let globals_of (u : unit_) =
    List.concat_map (written_in `Global) (List.filter (fun (v : unit_) -> String.equal v.package u.package) all)
    @ implicit
  in
  let resolve_unit u ~entry =
    let own = Hashtbl.create 8 in
    List.iter (fun name -> Hashtbl.replace own name ()) (exports u);
    let aliases = Hashtbl.create 4 in
    let direct = Hashtbl.create 4 in
    (* What the prelude binds, whatever this file shadows: `core.print` reaches
       it past the file's own `print`. *)
    let core = Hashtbl.create 16 in
    let from_prelude from = Some from = prelude roots in
    (* Names this file binds itself, by declaring or importing them, which a
       global import then leaves alone. *)
    let locally = Hashtbl.create 4 in
    (* Each operation this file may perform bare, and the name it has. *)
    let reachable = Hashtbl.create 8 in
    List.iter
      (fun op -> Hashtbl.replace reachable op (renamed u ~entry op))
      (List.concat_map operations u.program);
    List.iter
      (fun (global, (decl, span, from)) ->
        let shadowed name = global && (Hashtbl.mem own name || Hashtbl.mem locally name) in
        let written = path_of decl in
        let target = namespace_of written in
        let found =
          match resolve_import roots span ~from written with
          | File path ->
            (match Hashtbl.find_opt table (normalize path) with
             | Some (unit_, exports) ->
               Some (unit_, exports, List.concat_map operations unit_.program)
             | None -> None)
          | Compiled (package, interface) ->
            (* The declarations are already in the program, mangled by whoever
               compiled them; only the names have to be bound here. *)
            Some
              ( { path = ""
                ; namespace = interface.Artifact.namespace
                ; doc = None
                ; package
                ; program = []
                }
              , interface.Artifact.exports
              , interface.Artifact.operations )
        in
        match found with
        | None -> fail span "Module '%s' was not loaded." target
        | Some (target_unit, target_exports, target_operations) ->
          let is_entry =
            plain_entry
            &&
            match entry_unit with
            | Some e -> String.equal target_unit.path e.path
            | None -> false
          in
          (* A dependency reached as an artifact has no program here, so its
             operations come from the interface it recorded. *)
          let target_ops =
            match target_unit.program with
            | [] -> target_operations
            | program -> List.concat_map operations program
          in
          (* The same module under the same name twice is one binding: a file
             may write an import its package also makes global. *)
          let bind under =
            if not global then Hashtbl.replace locally under ();
            if not (shadowed under) then
            match Hashtbl.find_opt aliases under with
            | Some (path, _) when String.equal path target_unit.path -> ()
            | Some _ -> fail span "'%s' is already bound. Import one of them with `as`." under
            | None ->
              Hashtbl.replace
                aliases
                under
                (target_unit.path, fun name -> renamed target_unit ~entry:is_entry name)
          in
          (match decl with
           | Ast.Qualified _ -> bind target
           | Ast.Aliased (_, alias) -> bind alias
           | Ast.Selective (names, _) ->
             List.iter
               (fun name ->
                 if not (List.mem name target_exports)
                 then fail span "Module '%s' does not export '%s'." target name;
                 let bound = renamed target_unit ~entry:is_entry name in
                 (* An artifact records its operations but not whose they are. *)
                 let brought =
                   match target_unit.program with
                   | [] -> target_ops
                   | program ->
                     List.concat_map effects_of program
                     |> List.filter (fun (declaring, _) -> String.equal declaring name)
                     |> List.concat_map snd
                 in
                 if global && from_prelude from
                 then (
                   Hashtbl.replace core name bound;
                   List.iter
                     (fun op -> Hashtbl.replace core op (renamed target_unit ~entry:is_entry op))
                     brought);
                 if not global then Hashtbl.replace locally name ();
                 if not (shadowed name) then begin
                 (match Hashtbl.find_opt direct name with
                  | Some earlier when not (String.equal earlier bound) ->
                    fail span "'%s' is already imported." name
                  | _ -> ());
                 Hashtbl.replace direct name bound;
                 List.iter
                   (fun op -> Hashtbl.replace reachable op (renamed target_unit ~entry:is_entry op))
                   brought
                 end)
               names
           | Ast.Wildcard _ -> ()))
      (List.map (fun i -> false, i) (written_in `Local u)
       @ List.map (fun i -> true, i) (globals_of u));
    if not (Hashtbl.mem aliases "core" || Hashtbl.mem own "core")
    then
      Hashtbl.replace
        aliases
        "core"
        ("", fun name -> Option.value (Hashtbl.find_opt core name) ~default:name);
    let foreign = Hashtbl.create 8 in
    List.iter
      (fun (op, owner) -> if not (Hashtbl.mem reachable op) then Hashtbl.replace foreign op owner)
      known_operations;
    let aliases =
      let qualify = Hashtbl.create (Hashtbl.length aliases) in
      Hashtbl.iter (fun under (_, f) -> Hashtbl.replace qualify under f) aliases;
      qualify
    in
    rewrite
      ~aliases
      ~direct
      ~own
      ~foreign
      ~ops:reachable
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
    @ (match entry_unit with
       | None -> []
       | Some u -> declarations_of u ~entry:plain_entry ~keep:true)
  , List.map
      (fun u ->
        { Artifact.namespace = u.namespace
        ; path = (if String.equal u.package own then Some (under roots u.path) else None)
        ; doc = u.doc
        ; exports = exports u
        ; operations = List.concat_map operations u.program
        })
      all )

let package ?(roots = anywhere) ?entry_namespace ?seeds entry_path =
  let entry_unit, rest = load roots ?namespace:entry_namespace ?seeds entry_path in
  (* Every unit of the package being compiled, not only its entry. A unit that
     already names a package came from somewhere else. *)
  let owned (u : unit_) =
    match entry_namespace with
    | Some package when String.equal u.package "" -> { u with package }
    | _ -> u
  in
  assemble
    roots
    ~package:(Option.value entry_namespace ~default:"")
    (* A file run on its own keeps its declarations under the names it wrote; a
       package carries them under its own, because a consumer will link them
       beside somebody else's. *)
    ~plain_entry:(Option.is_none entry_namespace)
    ~entry_unit:(Some (owned entry_unit))
    ~rest:(List.map owned rest)

(* A set of modules with no program among them: the standard library, which is
   not a package and has no entry to be loaded from. Every module is a module,
   so nothing keeps plain names and no top-level statement is kept. *)
let library ?(roots = anywhere) ~package:name paths =
  match paths with
  | [] -> [], []
  | first :: _ ->
    (* No [namespace] argument, so the file that happens to be walked first is
       named after itself like every other rather than after the library. *)
    (* Documenting a library needs only what it declares, so one with no `core`
       is still a library. *)
    let entry_unit, rest = load roots ~seeds:paths ~core:false first in
    let owned (u : unit_) = if String.equal u.package "" then { u with package = name } else u in
    assemble
      roots
      ~package:name
      ~plain_entry:false
      ~entry_unit:None
      ~rest:(List.map owned (entry_unit :: rest))

let program ?roots entry_path = fst (package ?roots entry_path)
