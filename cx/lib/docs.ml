(* The documentation index: every declaration of every package in a build,
   reached or not, as data.

   It reads artifacts rather than compiling: an artifact holds the package's
   declarations before metaprocessing, which is the whole declared surface
   rather than the part some entry happened to reach. Nothing here runs a
   program or consults the checker. *)

open Bootstrap

let format_version = 1

(* ---- names ---- *)

(* A declaration in an artifact carries what the loader mangled it to --
   `package#unit#name`, or `package#name` for the unit a consumer reaches as the
   package itself. Splitting one back is exact, because `#` is in no identifier
   the scanner can produce.

   The unit is matched against the ones the artifact records rather than counted
   off: a name may be generated and carry separators of its own, so the segment
   count says nothing. *)
let prefixes ~package ~namespaces =
  List.map
    (fun ns ->
      ns, (if String.equal ns package then package ^ "#" else package ^ "#" ^ ns ^ "#"))
    namespaces
  (* Longest first, so a unit called `shapes` wins over the package's own. *)
  |> List.sort (fun (_, a) (_, b) -> Int.compare (String.length b) (String.length a))

let split prefixes mangled =
  List.find_map
    (fun (ns, prefix) ->
      if String.starts_with ~prefix mangled
      then (
        let n = String.length prefix in
        Some (ns, String.sub mangled n (String.length mangled - n)))
      else None)
    prefixes

(* ---- types ---- *)

(* [known] is every declaration in the build, so a name that is in it is a link
   and a name that is not is a builtin or a parameter. [params] separates those
   two: only the declaration's own `<>` names are in scope as parameters. *)
let rec type_expr ~known ~params (t : Ast.type_expr) : Json.t =
  let of_name name =
    match Hashtbl.find_opt known name with
    | Some display -> [ "name", Json.String display; "ref", Json.String name ]
    | None ->
      [ "name", Json.String name
      ; "ref", Json.Null
      ; "param", Json.Bool (List.mem name params)
      ]
  in
  let each = type_expr ~known ~params in
  match t.Ast.it with
  | Ast.Ty_name name -> Json.Obj (("kind", Json.String "name") :: of_name name)
  | Ast.Ty_app (name, args) ->
    Json.Obj
      ((("kind", Json.String "app") :: of_name name)
       @ [ "args", Json.List (List.map each args) ])
  | Ast.Ty_tuple items ->
    Json.Obj [ "kind", Json.String "tuple"; "items", Json.List (List.map each items) ]
  | Ast.Ty_record fields ->
    Json.Obj
      [ "kind", Json.String "record"
      ; ( "fields"
        , Json.List
            (List.map
               (fun (label, ty) ->
                 Json.Obj [ "name", Json.String label; "type", each ty ])
               fields) )
      ]
  | Ast.Ty_fn (ps, ret, row) ->
    Json.Obj
      [ "kind", Json.String "fn"
      ; "params", Json.List (List.map each ps)
      ; "ret", each ret
      ; "row", Json.List (List.map (effect_ref ~known ~params) row)
      ]
  | Ast.Ty_variadic inner -> Json.Obj [ "kind", Json.String "variadic"; "of", each inner ]
  | Ast.Ty_spread inner -> Json.Obj [ "kind", Json.String "spread"; "of", each inner ]
  | Ast.Ty_assoc (inner, member) ->
    Json.Obj
      [ "kind", Json.String "assoc"; "of", each inner; "member", Json.String member ]
  | Ast.Ty_bind (name, inner) ->
    Json.Obj [ "kind", Json.String "bind"; "name", Json.String name; "type", each inner ]

and effect_ref ~known ~params (name, args) =
  let display =
    match Hashtbl.find_opt known name with
    | Some display -> display
    | None -> name
  in
  Json.Obj
    [ "effect", Json.String display
    ; "ref", (if Hashtbl.mem known name then Json.String name else Json.Null)
    ; "args", Json.List (List.map (type_expr ~known ~params) args)
    ]

(* [None] is a row left to inference and `[]` is one written closed. They are
   different things to a reader, so the index keeps them apart. *)
let row_of ~known ~params = function
  | None -> Json.Null
  | Some row -> Json.List (List.map (effect_ref ~known ~params) row)

(* ---- parameters ---- *)

(* A `<>` parameter written with a type is a value the declaration is
   instantiated at -- what makes it a template rather than a generic -- so the
   index says which it is instead of leaving a renderer to infer it. *)
let parameter ~known ~params ~name ~ty ~pack =
  Json.Obj
    [ "name", Json.String name
    ; "form", Json.String (match ty with None -> "type" | Some _ -> "value")
    ; "type", Json.opt (type_expr ~known ~params) ty
    ; "pack", Json.Bool pack
    ]

let static_of ~known ~params (sg : Ast.signature) =
  Json.List
    (List.map
       (fun (p : Ast.static_param) ->
         parameter ~known ~params ~name:p.Ast.sp_name ~ty:p.Ast.sp_ty ~pack:p.Ast.sp_pack)
       sg.Ast.static_params)

let generics_of ~known ~params (ps : Ast.type_param list) =
  Json.List
    (List.map
       (fun (p : Ast.type_param) ->
         parameter ~known ~params ~name:p.Ast.tp_name ~ty:p.Ast.tp_ty ~pack:p.Ast.tp_pack)
       ps)

let param_names (sg : Ast.signature) =
  List.map (fun (p : Ast.static_param) -> p.Ast.sp_name) sg.Ast.static_params

let type_param_names (ps : Ast.type_param list) =
  List.map (fun (p : Ast.type_param) -> p.Ast.tp_name) ps

let params_of ~known ~params (ps : Ast.param list) =
  Json.List
    (List.map
       (fun (p : Ast.param) ->
         Json.Obj
           [ "name", Json.String p.Ast.name
           ; "type", Json.opt (type_expr ~known ~params) p.Ast.ty
           ])
       ps)

(* ---- attributes ---- *)

(* The same split reflection makes: a doc is a doc, and `attrs` is what was
   written with `@`. Nothing downstream learns that one rode in on the other. *)
let doc_of (list : Ast.attr list) =
  match
    List.find_opt (fun (a : Ast.attr) -> String.equal a.Ast.a_name Ast.doc_attr) list
  with
  | Some { Ast.a_args = [ Ast.A_str text ]; _ } -> Json.String text
  | _ -> Json.Null

let attrs_of (list : Ast.attr list) =
  let arg = function
    | Ast.A_str text -> Json.Obj [ "str", Json.String text ]
    | Ast.A_int value -> Json.Obj [ "int", Json.Int value ]
    | Ast.A_float value -> Json.Obj [ "float", Json.String (string_of_float value) ]
    | Ast.A_bool value -> Json.Obj [ "bool", Json.Bool value ]
  in
  Json.List
    (List.filter_map
       (fun (a : Ast.attr) ->
         if String.equal a.Ast.a_name Ast.doc_attr
         then None
         else
           Some
             (Json.Obj
                [ "name", Json.String a.Ast.a_name
                ; "args", Json.List (List.map arg a.Ast.a_args)
                ]))
       list)

(* ---- members ---- *)

(* One shape whether it came from a trait's signature or an impl's definition,
   so a renderer showing a trait beside its implementers compares like with
   like. A body is not in the index. *)
let method_json ~known ~params ~name ~attrs ~(sg : Ast.signature) ~ps =
  let params = params @ param_names sg in
  Json.Obj
    [ "name", Json.String name
    ; "doc", doc_of attrs
    ; "attrs", attrs_of attrs
    ; "static", static_of ~known ~params sg
    ; "params", params_of ~known ~params ps
    ; "ret", Json.opt (type_expr ~known ~params) sg.Ast.ret
    ; "row", row_of ~known ~params sg.Ast.row
    ]

let method_sig ~known ~params (m : Ast.method_sig) =
  method_json
    ~known
    ~params
    ~name:m.Ast.ms_name
    ~attrs:m.Ast.ms_attrs
    ~sg:m.Ast.ms_signature
    ~ps:m.Ast.ms_params

let method_def ~known ~params (m : (Ast.stmt, unit) Ast.method_def) =
  method_json
    ~known
    ~params
    ~name:m.Ast.md_name
    ~attrs:m.Ast.md_attrs
    ~sg:m.Ast.md_signature
    ~ps:m.Ast.md_params

let payload_of ~known ~params (p : Ast.type_expr Ast.payload) =
  match p with
  | Ast.P_none -> Json.Obj [ "form", Json.String "none" ]
  | Ast.P_tuple items ->
    Json.Obj
      [ "form", Json.String "tuple"
      ; "items", Json.List (List.map (type_expr ~known ~params) items)
      ]
  | Ast.P_fields fields ->
    Json.Obj
      [ "form", Json.String "fields"
      ; ( "fields"
        , Json.List
            (List.map
               (fun (label, ty) ->
                 Json.Obj
                   [ "name", Json.String label; "type", type_expr ~known ~params ty ])
               fields) )
      ]

let body_of ~known ~params (body : Ast.type_body) =
  match body with
  | Ast.T_fields fields ->
    Json.Obj
      [ "form", Json.String "fields"
      ; ( "fields"
        , Json.List
            (List.map
               (fun (f : Ast.field) ->
                 Json.Obj
                   [ "name", Json.String f.Ast.f_name
                   ; "type", type_expr ~known ~params f.Ast.f_ty
                   ; "doc", doc_of f.Ast.f_attrs
                   ; "attrs", attrs_of f.Ast.f_attrs
                   ])
               fields) )
      ]
  | Ast.T_variants variants ->
    Json.Obj
      [ "form", Json.String "variants"
      ; ( "variants"
        , Json.List
            (List.map
               (fun (v : Ast.variant) ->
                 let params = params @ v.Ast.v_params in
                 Json.Obj
                   [ "name", Json.String v.Ast.v_name
                   ; "generics", Json.List (List.map (fun n -> Json.String n) v.Ast.v_params)
                   ; "payload", payload_of ~known ~params v.Ast.v_payload
                   ; "result", Json.opt (type_expr ~known ~params) v.Ast.v_result
                   ; "doc", doc_of v.Ast.v_attrs
                   ; "attrs", attrs_of v.Ast.v_attrs
                   ])
               variants) )
      ]

(* ---- entries ---- *)

type entry =
  { name : string (* what the entry is titled and sorted by *)
  ; id : string
  ; unit_ : string
  ; kind : string
  (* The type an impl is for, so a type can list the impls that name it. *)
  ; impl_for : string option
  ; json : Json.t
  }

let display known name =
  match Hashtbl.find_opt known name with
  | Some display -> display
  | None -> name

(* A trait written at arguments, in a supertrait bound or an impl head. *)
let applied ~known ~params (name, args) =
  Json.Obj
    [ "name", Json.String (display known name)
    ; "ref", (if Hashtbl.mem known name then Json.String name else Json.Null)
    ; "args", Json.List (List.map (type_expr ~known ~params) args)
    ]

(* An impl is written with no name, so its id is built from the two things that
   identify it: the type it is for and the trait it implements, arguments
   included -- `Index<int>` and `Index<Range>` for one type are two impls of one
   trait. Overlapping impls are rejected, so nothing else can collide. *)
let impl_id ~target ~trait =
  match trait with
  | None -> target ^ "#impl"
  | Some (name, []) -> target ^ "#impl#" ^ name
  | Some (name, args) ->
    target
    ^ "#impl#"
    ^ name
    ^ "<"
    ^ String.concat "," (List.map Source.type_expr args)
    ^ ">"

(* Cronyx has no export marker, so nothing is private and this records the
   nearest thing there is: whether another unit can reach the declaration by
   name, which is exactly what the unit's `exports` lists. An impl is the one
   exception, because it has no name to export and is reached through its
   type. *)
let reachable ~kind ~exports name =
  String.equal kind "impl" || List.mem name exports

let rec declaration ~known ~prefixes ~package ~exports (s : Ast.stmt) : entry list =
  let attrs, inner =
    match s.Ast.it with
    | `Attributed (list, inner) -> list, inner
    | _ -> [], s
  in
  let head ~unit_ ~id ~name ~kind rest =
    Json.Obj
      ([ "id", Json.String id
       ; "package", Json.String package
       ; "unit", Json.String unit_
       ; "name", Json.String name
       ; "kind", Json.String kind
       ; "exported", Json.Bool (reachable ~kind ~exports:(Option.value (exports unit_) ~default:[]) name)
       ; "doc", doc_of attrs
       ; "attrs", attrs_of attrs
       ]
       @ rest)
  in
  (* Where a declaration belongs, and whether it belongs here at all. A name
     that names no unit of this package came from somewhere else -- the standard
     library, which every package embeds until it is compiled like any other --
     and `cx docs std` is what documents that. *)
  let located mangled k =
    match split prefixes mangled with
    | Some (unit_, name) -> k ~unit_ ~name
    | None -> []
  in
  match inner.Ast.it with
  | `Fn (mangled, ps, sg, _) ->
    located mangled (fun ~unit_ ~name ->
      let params = param_names sg in
      [ { name; kind = "fn"; impl_for = None
        ; id = mangled
        ; unit_
        ; json =
            head
              ~unit_
              ~id:mangled
              ~name
              ~kind:"fn"
              [ "static", static_of ~known ~params sg
              ; "params", params_of ~known ~params ps
              ; "ret", Json.opt (type_expr ~known ~params) sg.Ast.ret
              ; "row", row_of ~known ~params sg.Ast.row
              ]
        }
      ])
  | `Type_decl (mangled, ps, body) ->
    located mangled (fun ~unit_ ~name ->
      let params = type_param_names ps in
      [ { name; kind = "type"; impl_for = None
        ; id = mangled
        ; unit_
        ; json =
            head
              ~unit_
              ~id:mangled
              ~name
              ~kind:"type"
              [ "generics", generics_of ~known ~params ps
              ; "body", body_of ~known ~params body
              ]
        }
      ])
  (* The type and the functions written inside it, which are an inherent impl
     written in one place rather than two. *)
  | `Type_members (decl, members) ->
    declaration ~known ~prefixes ~package ~exports { s with Ast.it = decl.Ast.it }
    @ (match decl.Ast.it with
       | `Type_decl (mangled, ps, _) ->
         located mangled (fun ~unit_ ~name ->
           let params = type_param_names ps in
           let methods =
             List.filter_map
               (fun (m : Ast.stmt) ->
                 match Metaprocess.fn_parts m with
                 | Some (fn_name, ps, sg, _) ->
                   Some
                     (method_json
                        ~known
                        ~params
                        ~name:fn_name
                        ~attrs:(Metaprocess.fn_attrs m)
                        ~sg
                        ~ps)
                 | None -> None)
               members
           in
           match methods with
           | [] -> []
           | methods ->
             let id = impl_id ~target:mangled ~trait:None in
             [ { name
               ; id
               ; unit_
               ; kind = "impl"
               ; impl_for = Some mangled
               ; json =
                   head
                     ~unit_
                     ~id
                     ~name
                     ~kind:"impl"
                     [ "trait", Json.Null
                     ; ( "for"
                       , Json.Obj
                           [ "kind", Json.String "name"
                           ; "name", Json.String name
                           ; "ref", Json.String mangled
                           ] )
                     ; "generics", generics_of ~known ~params ps
                     ; "assoc", Json.List []
                     ; "methods", Json.List methods
                     ]
               }
             ])
       | _ -> [])
  | `Trait_decl (mangled, ps, body) ->
    located mangled (fun ~unit_ ~name ->
      let params = ps in
      [ { name; kind = "trait"; impl_for = None
        ; id = mangled
        ; unit_
        ; json =
            head
              ~unit_
              ~id:mangled
              ~name
              ~kind:"trait"
              [ "generics", Json.List (List.map (fun n -> Json.String n) ps)
              ; "supers", Json.List (List.map (applied ~known ~params) body.Ast.tb_super)
              ; ( "assoc"
                , Json.List (List.map (fun n -> Json.String n) body.Ast.tb_assoc) )
              ; ( "methods"
                , Json.List (List.map (method_sig ~known ~params) body.Ast.tb_methods) )
              ]
        }
      ])
  | `Impl_decl (trait, target, ps, body) ->
    located target (fun ~unit_ ~name:target_name ->
      let params = type_param_names ps in
      let id = impl_id ~target ~trait in
      let name =
        match trait with
        | None -> target_name
        | Some (t, _) -> display known t ^ " for " ^ target_name
      in
      [ { name; kind = "impl"; impl_for = Some target
        ; id
        ; unit_
        ; json =
            head
              ~unit_
              ~id
              ~name
              ~kind:"impl"
              [ "trait", Json.opt (applied ~known ~params) trait
              ; ( "for"
                , Json.Obj
                    [ "kind", Json.String "name"
                    ; "name", Json.String target_name
                    ; "ref", Json.String target
                    ] )
              ; "generics", generics_of ~known ~params ps
              ; ( "assoc"
                , Json.List
                    (List.map
                       (fun (n, ty) ->
                         Json.Obj
                           [ "name", Json.String n
                           ; "type", type_expr ~known ~params ty
                           ])
                       body.Ast.ib_assoc) )
              ; ( "methods"
                , Json.List (List.map (method_def ~known ~params) body.Ast.ib_methods) )
              ]
        }
      ])
  | `Effect_decl (mangled, ps, ops) ->
    located mangled (fun ~unit_ ~name ->
      [ { name; kind = "effect"; impl_for = None
        ; id = mangled
        ; unit_
        ; json =
            head
              ~unit_
              ~id:mangled
              ~name
              ~kind:"effect"
              [ "generics", Json.List (List.map (fun n -> Json.String n) ps)
              ; ( "ops"
                , Json.List
                    (List.map
                       (fun (o : Ast.op_decl) ->
                         let params = ps @ o.Ast.op_tparams in
                         Json.Obj
                           [ "name", Json.String o.Ast.op_name
                           ; ( "kind"
                             , Json.String
                                 (match o.Ast.op_kind with
                                  | Ast.Op_fn -> "fn"
                                  | Ast.Op_ctl -> "ctl"
                                  | Ast.Op_final -> "final ctl") )
                           ; ( "generics"
                             , Json.List
                                 (List.map (fun n -> Json.String n) o.Ast.op_tparams) )
                           ; "params", params_of ~known ~params o.Ast.op_params
                           ; "ret", Json.opt (type_expr ~known ~params) o.Ast.op_ret
                           ])
                       ops) )
              ]
        }
      ])
  | `Handler_decl (mangled, h) ->
    located mangled (fun ~unit_ ~name ->
      [ { name; kind = "handler"; impl_for = None
        ; id = mangled
        ; unit_
        ; json =
            head
              ~unit_
              ~id:mangled
              ~name
              ~kind:"handler"
              [ "handles", applied ~known ~params:[] (h.Ast.handled, [])
              ; ( "arms"
                , Json.List
                    (List.map
                       (fun (a : Ast.stmt Ast.arm) ->
                         Json.Obj
                           [ "name", Json.String a.Ast.arm_name
                           ; ( "kind"
                             , Json.String
                                 (match a.Ast.arm_kind with
                                  | Ast.Op_fn -> "fn"
                                  | Ast.Op_ctl -> "ctl"
                                  | Ast.Op_final -> "final ctl") )
                           ; ( "params"
                             , Json.List
                                 (List.map (fun n -> Json.String n) a.Ast.arm_params) )
                           ])
                       h.Ast.arms) )
              ]
        }
      ])
  | `Var_decl (mangled, ty, _) ->
    located mangled (fun ~unit_ ~name ->
      [ { name; kind = "var"; impl_for = None
        ; id = mangled
        ; unit_
        ; json =
            head
              ~unit_
              ~id:mangled
              ~name
              ~kind:"var"
              [ "type", Json.opt (type_expr ~known ~params:[]) ty ]
        }
      ])
  | _ -> []

(* ---- the index ---- *)

(* Every declaration of every package, so a type reference resolves across a
   package boundary as readily as inside one. *)
let known_of (artifacts : Artifact.t list) =
  let known = Hashtbl.create 512 in
  List.iter
    (fun (a : Artifact.t) ->
      let prefixes =
        prefixes
          ~package:a.Artifact.package
          ~namespaces:
            (List.map (fun (u : Artifact.unit_interface) -> u.Artifact.namespace) a.Artifact.units)
      in
      List.iter
        (fun (s : Ast.stmt) ->
          match Loader.declared_name s with
          | None -> ()
          | Some mangled ->
            (match split prefixes mangled with
             | Some (_, name) -> Hashtbl.replace known mangled name
             | None -> ()))
        a.Artifact.program)
    artifacts;
  known

(* An impl is reached through its type, so a type carries the impls that name it
   and a renderer joins by id rather than scanning every entry. *)
let with_impls entries =
  let table = Hashtbl.create 64 in
  List.iter
    (fun e ->
      match e.impl_for with
      | None -> ()
      | Some target ->
        Hashtbl.replace
          table
          target
          (e.id :: (match Hashtbl.find_opt table target with Some l -> l | None -> [])))
    entries;
  List.map
    (fun e ->
      match e.kind, e.json with
      | "type", Json.Obj fields ->
        let impls =
          match Hashtbl.find_opt table e.id with
          | None -> []
          | Some ids -> List.sort String.compare ids
        in
        { e with json = Json.Obj (fields @ [ "impls", Json.List (List.map (fun i -> Json.String i) impls) ]) }
      | _ -> e)
    entries

let package_json ~known ~version (a : Artifact.t) =
  let namespaces =
    List.map (fun (u : Artifact.unit_interface) -> u.Artifact.namespace) a.Artifact.units
  in
  let prefixes = prefixes ~package:a.Artifact.package ~namespaces in
  let exports unit_ =
    List.find_map
      (fun (u : Artifact.unit_interface) ->
        if String.equal u.Artifact.namespace unit_ then Some u.Artifact.exports else None)
      a.Artifact.units
  in
  let entries =
    with_impls
      (List.concat_map
         (declaration ~known ~prefixes ~package:a.Artifact.package ~exports)
         a.Artifact.program)
  in
  let unit_json ns =
    match List.filter (fun e -> String.equal e.unit_ ns) entries with
    (* A unit that documents nothing is left out rather than reported empty.
       Every package embeds whatever of the standard library it imported, and
       those units are listed beside its own -- but their declarations carry the
       library's names, not this package's, so they belong to `cx docs std`. *)
    | [] -> None
    | mine ->
      let sorted =
        List.sort
          (fun a b ->
            match String.compare a.name b.name with
            | 0 -> String.compare a.id b.id
            | n -> n)
          mine
      in
      Some
        (Json.Obj
           [ "namespace", Json.String ns
           ; "doc", Json.Null
           ; "entries", Json.List (List.map (fun e -> e.json) sorted)
           ])
  in
  Json.Obj
    [ "name", Json.String a.Artifact.package
    ; "version", Json.opt (fun v -> Json.String v) version
    ; ( "units"
      , Json.List (List.filter_map unit_json (List.sort String.compare namespaces)) )
    ]

let index ~root ~versions (artifacts : Artifact.t list) =
  let known = known_of artifacts in
  let ordered =
    List.sort
      (fun (a : Artifact.t) (b : Artifact.t) ->
        match
          Bool.compare
            (String.equal b.Artifact.package root)
            (String.equal a.Artifact.package root)
        with
        | 0 -> String.compare a.Artifact.package b.Artifact.package
        | n -> n)
      artifacts
  in
  Json.Obj
    [ "format", Json.Int format_version
    ; "compiler", Json.String Release.version
    ; "root", Json.String root
    ; ( "packages"
      , Json.List
          (List.map
             (fun (a : Artifact.t) ->
               package_json ~known ~version:(versions a.Artifact.package) a)
             ordered) )
    ]

(* The version of each package in the build: the root's from its own manifest,
   a dependency's from the lockfile, which is what said which one this is. *)
let versions_of root =
  let table = Hashtbl.create 8 in
  (match Lockfile.read root with
   | None -> ()
   | Some text ->
     List.iter
       (fun (name, version) -> Hashtbl.replace table name (Version.to_string version))
       (Lockfile.pins text));
  (match Build.manifest_of root with
   | Ok m -> Hashtbl.replace table m.Manifest.name (Version.to_string m.Manifest.version)
   | Error _ -> ());
  fun name -> Hashtbl.find_opt table name

(* The package here and everything it depends on, built as `cx build` builds it
   so the artifact cache is the same one. *)
let of_package ?mode ?note root =
  let ( let* ) = Result.bind in
  let* manifest = Build.manifest_of root in
  let* artifacts, _ = Build.package ?mode ?note ~out:(fun _ -> ()) root in
  Ok (index ~root:manifest.Manifest.name ~versions:(versions_of root) artifacts)

let library_name = "std"

(* The library ships inside the toolchain rather than as a package, so there is
   no manifest to read and no artifact to load: its modules are compiled from
   source, here, every time. *)
let of_stdlib () =
  match Toolchain.stdlib () with
  | None ->
    Error
      [ Diagnostic.at
          Diagnostic.Load
          Source_map.Span.nowhere
          "Cannot find the standard library."
      ]
  | Some dir ->
    let rec walk acc path =
      if Sys.is_directory path
      then
        Array.fold_left
          (fun acc entry -> walk acc (Filename.concat path entry))
          acc
          (Sys.readdir path)
      else if Filename.check_suffix path ".cx"
      then path :: acc
      else acc
    in
    let paths = List.sort String.compare (walk [] dir) in
    let roots = { Loader.package = dir; std = Some dir; deps = [] } in
    (match Pipeline.library ~roots ~package:library_name paths with
     | Error errors -> Error errors
     | Ok (program, units) ->
       Ok
         (index
            ~root:library_name
            ~versions:(fun _ -> Some Release.version)
            [ { Artifact.compiler = Release.version
              ; package = library_name
              ; units
              ; program
              ; inputs = []
              ; fingerprint = ""
              } ]))

let directory root = Filename.concat (Build.target_dir root) "doc"

(* Not under `target/`: `cx docs std` is asked from wherever you are standing,
   which is often no package at all, and the library is the toolchain's rather
   than any one project's. *)
let library_directory () = Filename.concat (Home.root ()) (Filename.concat "doc" library_name)

let render_stdlib () =
  match of_stdlib () with
  | Error errors -> Error errors
  | Ok index ->
    let out = library_directory () in
    Home.ensure out;
    Ok (Site.write ~out_dir:out index)

(* A build product, so it sits under `target/` beside the artifacts and inside
   the `.gitignore` `cx new` already writes. *)
let render ?mode ?note root =
  let ( let* ) = Result.bind in
  let* index = of_package ?mode ?note root in
  Build.ensure (Build.target_dir root);
  Ok (Site.write ~out_dir:(directory root) index)

(* Best effort: a reference that was written is worth more than an error about
   a browser, so a failure to open one is reported as the path instead. *)
let opened path =
  let quoted = Filename.quote path in
  let command =
    match Sys.os_type with
    | "Win32" -> Printf.sprintf "start \"\" %s" quoted
    | _ -> Printf.sprintf "(xdg-open %s || open %s) >/dev/null 2>&1" quoted quoted
  in
  match Sys.command command with
  | 0 -> true
  | _ | (exception Sys_error _) -> false
