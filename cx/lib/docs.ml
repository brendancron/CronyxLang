(* The documentation index: every declaration of every package in a build,
   reached or not, as data.

   It reads artifacts rather than compiling: an artifact holds the package's
   declarations before metaprocessing, which is the whole declared surface
   rather than the part some entry happened to reach. Nothing here runs a
   program or consults the checker. *)

open Bootstrap

let format_version = 3

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

(* ---- where a declaration was written ---- *)

(* Which unit a declaration belongs to is the *span's* question, not the
   mangled name's. An `impl` for a primitive is why: `impl Add for int` is
   written under some unit and mangles to `int#impl#…`, so locating it by its
   name would place it nowhere and drop it from the reference entirely.

   A unit records its path relative to the root that owns it, and a span carries
   the path the loader opened, so the two are matched by suffix -- longest
   first, so `src/shapes/Round.cx` wins over `Round.cx`. A unit the artifact
   embeds rather than owns has no path, which is also the filter that keeps
   another package's declarations out of this package's reference. *)
let places (units : Artifact.unit_interface list) =
  List.filter_map
    (fun (u : Artifact.unit_interface) ->
      Option.map (fun path -> Ast.slashed path, u.Artifact.namespace) u.Artifact.path)
    units
  |> List.sort (fun (a, _) (b, _) -> Int.compare (String.length b) (String.length a))

let place places span =
  let path = Ast.slashed (Source_map.Span.path span) in
  List.find_map
    (fun (unit_path, namespace) ->
      if String.equal path unit_path || String.ends_with ~suffix:("/" ^ unit_path) path
      then Some (namespace, unit_path)
      else None)
    places

(* A declaration's line, so a renderer can offer its source. Absent for one the
   compiler invented, which is a case a renderer answers for rather than a
   missing field it skips. *)
let line_of span =
  match Source_map.Span.view span with
  | Source_map.Span.Located { line; _ } -> Json.Int line
  | Source_map.Span.Nowhere_in_source -> Json.Null

(* ---- types ---- *)

(* Every declaration in the build, by the name it was mangled to. [display] is
   what a page titles it; [is_trait] is what tells `<T: Ord>` from `<n: int>`,
   since both are written as a `<>` parameter with a type and only the trait
   table separates them. *)
type known_entry =
  { display : string
  ; is_trait : bool
  }

(* [known] is every declaration in the build, so a name that is in it is a link
   and a name that is not is a builtin or a parameter. [params] separates those
   two: only the declaration's own `<>` names are in scope as parameters. *)
let rec type_expr ~known ~params (t : Ast.type_expr) : Json.t =
  let of_name name =
    match Hashtbl.find_opt known name with
    | Some { display; _ } -> [ "name", Json.String display; "ref", Json.String name ]
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
    | Some { display; _ } -> display
    | None -> name
  in
  Json.Obj
    [ "name", Json.String display
    ; "ref", (if Hashtbl.mem known name then Json.String name else Json.Null)
    ; "args", Json.List (List.map (type_expr ~known ~params) args)
    ]

(* [None] is a row left to inference and `[]` is one written closed. They are
   different things to a reader, so the index keeps them apart. *)
let row_of ~known ~params = function
  | None -> Json.Null
  | Some row -> Json.List (List.map (effect_ref ~known ~params) row)

(* ---- parameters ---- *)

(* `<T>`, `<T: Ord>` and `<n: int>` are one syntax and three different things: a
   generic, a generic with a bound, and a *value* the declaration is instantiated
   at -- which is what makes it comptime rather than generic. The written
   type does not say which, since a bound and a value type are both a type
   expression; only whether its head names a trait does, which is the same
   question `Metaprocess.is_value` asks. *)
let form_of ~known ty =
  match ty with
  | None -> "type"
  | Some { Ast.it = Ast.Ty_name name; _ } | Some { Ast.it = Ast.Ty_app (name, _); _ } ->
    (match Hashtbl.find_opt known name with
     | Some { is_trait = true; _ } -> "bound"
     | _ -> "value")
  | Some _ -> "value"

let parameter ~known ~params ~name ~ty ~pack =
  Json.Obj
    [ "name", Json.String name
    ; "form", Json.String (form_of ~known ty)
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
  (* The file it was written in, which is what a unit is. Two units may share a
     namespace -- the library has a `core/Array.cx` and a
     `collections/Array.cx` -- so grouping by name would put both on one page and
     report the same module twice. *)
  ; unit_ : string
  ; kind : string
  (* The type an impl is for, so a type can list the impls that name it. *)
  ; impl_for : string option
  (* And the trait it implements, so a trait can list its implementers -- which
     is the only way to find the impls for a primitive, since `int` has no page
     to carry them. *)
  ; impl_of : string option
  ; json : Json.t
  }

let display known name =
  match Hashtbl.find_opt known name with
  | Some { display; _ } -> display
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

let rec declaration ~known ~places ~prefixes ~package ~exports (s : Ast.stmt) : entry list =
  let attrs, inner =
    match s.Ast.it with
    | `Attributed (list, inner) -> list, inner
    | _ -> [], s
  in
  let head ~unit_ ~id ~name ~kind rest =
    let namespace =
      match List.assoc_opt unit_ (List.map (fun (path, ns) -> path, ns) places) with
      | Some ns -> ns
      | None -> unit_
    in
    Json.Obj
      ([ "id", Json.String id
       ; "package", Json.String package
       ; "unit", Json.String namespace
       ; "name", Json.String name
       ; "kind", Json.String kind
       ; "line", line_of s.Ast.span
       ; "exported", Json.Bool (reachable ~kind ~exports:(Option.value (exports namespace) ~default:[]) name)
       ; "doc", doc_of attrs
       ; "attrs", attrs_of attrs
       ]
       @ rest)
  in
  (* Where a declaration belongs, and whether it belongs here at all. A span
     under no unit of this package came from somewhere else -- the standard
     library, which every package embeds until it is compiled like any other --
     and `cx docs std` is what documents that.

     The mangled name says what to call it and nothing about where it lives: an
     `impl` carries the name of the type it is for, and a file run as its own
     entry keeps the names it wrote. Neither splits, and both are documented. *)
  let located mangled k =
    match place places s.Ast.span with
    | None -> []
    | Some (_, file) ->
      let name =
        match split prefixes mangled with
        | Some (_, name) -> name
        | None -> mangled
      in
      k ~unit_:file ~name
  in
  match inner.Ast.it with
  | `Fn (mangled, ps, sg, _) ->
    located mangled (fun ~unit_ ~name ->
      let params = param_names sg in
      [ { name; kind = "fn"; impl_for = None; impl_of = None
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
      [ { name; kind = "type"; impl_for = None; impl_of = None
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
    declaration ~known ~places ~prefixes ~package ~exports { s with Ast.it = decl.Ast.it }
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
               ; impl_of = None
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
      [ { name; kind = "trait"; impl_for = None; impl_of = None
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
                , Json.List
                    (List.map
                       (fun (a : Ast.assoc_decl) ->
                         Json.Obj
                           [ "name", Json.String a.Ast.ad_name
                           ; "type", Json.Null
                           ; "doc", doc_of a.Ast.ad_attrs
                           ; "attrs", attrs_of a.Ast.ad_attrs
                           ])
                       body.Ast.tb_assoc) )
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
        (* The arguments are in the title because they are what tells two impls
           of one trait apart: `Index<int>` and `Index<Range>` for one type are
           two entries, and both would otherwise be called `Index for List`. *)
        | Some (t, []) -> display known t ^ " for " ^ target_name
        | Some (t, args) ->
          display known t
          ^ "<"
          ^ String.concat ", " (List.map Source.type_expr args)
          ^ "> for "
          ^ target_name
      in
      [ { name
        ; kind = "impl"
        ; impl_for = (if Hashtbl.mem known target then Some target else None)
        ; impl_of = Option.map fst trait
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
                    ; "ref", (if Hashtbl.mem known target then Json.String target else Json.Null)
                    ] )
              ; "generics", generics_of ~known ~params ps
              ; ( "assoc"
                , Json.List
                    (List.map
                       (fun (a : Ast.assoc_def) ->
                         Json.Obj
                           [ "name", Json.String a.Ast.as_name
                           ; "type", type_expr ~known ~params a.Ast.as_ty
                           ; "doc", doc_of a.Ast.as_attrs
                           ; "attrs", attrs_of a.Ast.as_attrs
                           ])
                       body.Ast.ib_assoc) )
              ; ( "methods"
                , Json.List (List.map (method_def ~known ~params) body.Ast.ib_methods) )
              ]
        }
      ])
  | `Effect_decl (mangled, ps, ops) ->
    located mangled (fun ~unit_ ~name ->
      [ { name; kind = "effect"; impl_for = None; impl_of = None
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
                           [ ( "name"
                             , Json.String
                                 (match split prefixes o.Ast.op_name with
                                  | Some (_, written) -> written
                                  | None -> o.Ast.op_name) )
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
                           ; "doc", doc_of o.Ast.op_attrs
                           ; "attrs", attrs_of o.Ast.op_attrs
                           ])
                       ops) )
              ]
        }
      ])
  | `Handler_decl (mangled, h) ->
    located mangled (fun ~unit_ ~name ->
      [ { name; kind = "handler"; impl_for = None; impl_of = None
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
                           [ ( "name"
                             , Json.String
                                 (match split prefixes a.Ast.arm_name with
                                  | Some (_, written) -> written
                                  | None -> a.Ast.arm_name) )
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
      [ { name; kind = "var"; impl_for = None; impl_of = None
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

(* The library ships inside the toolchain rather than as a package. *)
let library_name = "std"

(* ---- the natives ---- *)

(* `print`, `str`, `panic` and the handful of methods on the primitives are
   OCaml: a type-producing thunk and an implementation, with no declaration
   anywhere. They are the most-used names in the language, so the reference
   carries them as entries built from the same thunk the checker reads -- which
   is what keeps the printed signature from being a second written form that
   could disagree with it. Only the prose is written twice, and only once.

   A native with no prose is the compiler's own business -- `__parse_int`, the
   `meta#…` names, the index a `cx test` process is for -- and is left out. *)
let natives_unit = "builtins"

(* The thunks quantify nothing: `print` takes a fresh variable, and `same` takes
   one variable twice. So a variable is named on first sight and remembered,
   which is what makes `same(a, b)` read as one type rather than two. *)
let native_type () =
  let seen = Hashtbl.create 4 in
  let letters = [| "T"; "U"; "V"; "W" |] in
  let named name args =
    Json.Obj
      ([ "kind", Json.String (if args = [] then "name" else "app")
       ; "name", Json.String name
       ; "ref", Json.Null
       ; "param", Json.Bool false
       ]
       @ if args = [] then [] else [ "args", Json.List args ])
  in
  let param name =
    Json.Obj
      [ "kind", Json.String "name"
      ; "name", Json.String name
      ; "ref", Json.Null
      ; "param", Json.Bool true
      ]
  in
  let rec go (t : Types.infer_ty) =
    match t with
    | Types.IInt -> named "int" []
    | Types.IFloat -> named "float" []
    | Types.IStr -> named "string" []
    | Types.IByte -> named "byte" []
    | Types.IChr -> named "char" []
    | Types.IBool -> named "bool" []
    | Types.IUnit -> named "unit" []
    | Types.ITuple items ->
      Json.Obj [ "kind", Json.String "tuple"; "items", Json.List (List.map go items) ]
    | Types.INamed (name, args) -> named name (List.map go args)
    | Types.ISum (name, args) -> named name (List.map go args)
    | Types.IVar { contents = Types.Link inner } -> go inner
    | Types.IVar { contents = Types.Unbound (id, _) } ->
      let name =
        match Hashtbl.find_opt seen id with
        | Some name -> name
        | None ->
          let name =
            let n = Hashtbl.length seen in
            if n < Array.length letters then letters.(n) else Printf.sprintf "T%d" n
          in
          Hashtbl.replace seen id name;
          name
      in
      param name
    | _ -> named "?" []
  in
  go

(* A native is reached by its bare name, so its id is built rather than
   mangled: nothing mangles it, and a page still needs an anchor to point at. *)
let native_id ?owner name =
  match owner with
  | None -> "builtin#" ^ name
  | Some owner -> "builtin#" ^ owner ^ "#" ^ name

let native_entry ?owner ~name ~doc ~params ~ret () =
  let each = native_type () in
  let params = List.map each params in
  let ret = each ret in
  let id = native_id ?owner name in
  Json.Obj
    [ "id", Json.String id
    ; "package", Json.String library_name
    ; "unit", Json.String natives_unit
    ; ( "name"
      , Json.String (match owner with None -> name | Some owner -> owner ^ "." ^ name) )
    ; "kind", Json.String "fn"
    ; "line", Json.Null
    ; "exported", Json.Bool true
    ; "doc", Json.String doc
    ; "attrs", Json.List []
    ; "static", Json.List []
    ; ( "params"
      , Json.List
          (List.mapi
             (fun i ty ->
               (* A native's parameters have no written names, and inventing
                  `a`, `b`, `c` would put words in the signature that no
                  diagnostic and no call site ever uses. *)
               Json.Obj
                 [ "name", Json.String (match owner, i with Some _, 0 -> "self" | _ -> "")
                 ; "type", ty
                 ])
             params) )
    ; "ret", ret
    (* Nobody wrote a row, so there is none to report: a native performs no
       control effect and `<>` would be a claim the source never made. *)
    ; "row", Json.Null
    ]

let natives_json () =
  let documented = List.filter (fun (_, doc, _) -> not (String.equal doc "")) in
  let functions =
    List.map
      (fun (name, doc, signature) ->
        let params, ret = signature () in
        name, native_entry ~name ~doc ~params ~ret ())
      (documented Builtins.functions)
  in
  let methods =
    List.filter_map
      (fun (owner, name, doc, signature) ->
        if String.equal doc ""
        then None
        else (
          let params, ret = signature () in
          Some (owner ^ "." ^ name, native_entry ~owner ~name ~doc ~params ~ret ())))
      Builtins.methods
  in
  let sorted =
    List.sort (fun (a, _) (b, _) -> String.compare a b) (functions @ methods)
  in
  Json.Obj
    [ "namespace", Json.String natives_unit
    ; "path", Json.Null
    ; ( "doc"
      , Json.String
          "What the compiler provides with no declaration behind it. These names \
           are always in scope and are not imported." )
    ; "entries", Json.List (List.map snd sorted)
    ]

(* ---- the index ---- *)

(* Every declaration of every package, so a type reference resolves across a
   package boundary as readily as inside one. *)
(* Whether the declaration was written in the library's `core`, whose names the
   compiler and the syntax produce and so cannot wait for an import. *)
let core ~places (s : Ast.stmt) =
  match place places s.Ast.span with
  | Some (_, path) -> String.starts_with ~prefix:"core/" (Ast.slashed path)
  | None -> false

let is_trait (s : Ast.stmt) =
  match s.Ast.it with
  | `Attributed (_, { Ast.it = `Trait_decl _; _ }) | `Trait_decl _ -> true
  | _ -> false

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
             | Some (_, name) ->
               let entry = { display = name; is_trait = is_trait s } in
               Hashtbl.replace known mangled entry;
               (* A declaration in `core` is reached by its plain name and is
                  never imported, so that is the name every other module's
                  signatures carry -- and the name a reference has to resolve if
                  `List<T>` in one of them is to be a link rather than grey
                  text. The mangled id is still what the page is anchored by. *)
               if core ~places:(places a.Artifact.units) s
               then Hashtbl.replace known name entry
             | None -> ()))
        a.Artifact.program)
    artifacts;
  known

(* An impl is reached through its type *and* through its trait, so both carry
   the impls that name them and a renderer joins by id rather than scanning
   every entry. The trait's side is not a convenience: `impl Add for int` has no
   type page to be listed on, because `int` is a builtin and has no declaration,
   so the trait is the only place it can be found. *)
let with_impls entries =
  let gather key =
    let table = Hashtbl.create 64 in
    List.iter
      (fun e ->
        match key e with
        | None -> ()
        | Some target ->
          Hashtbl.replace
            table
            target
            (e.id :: (match Hashtbl.find_opt table target with Some l -> l | None -> [])))
      entries;
    fun id ->
      match Hashtbl.find_opt table id with
      | None -> []
      | Some ids -> List.sort String.compare ids
  in
  let for_type = gather (fun e -> e.impl_for) in
  let of_trait = gather (fun e -> e.impl_of) in
  let listing ids = Json.List (List.map (fun i -> Json.String i) ids) in
  List.map
    (fun e ->
      match e.kind, e.json with
      | "type", Json.Obj fields ->
        { e with json = Json.Obj (fields @ [ "impls", listing (for_type e.id) ]) }
      | "trait", Json.Obj fields ->
        { e with json = Json.Obj (fields @ [ "impls", listing (of_trait e.id) ]) }
      | _ -> e)
    entries

let package_json ~known ~version ?(extra = []) (a : Artifact.t) =
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
  let places = places a.Artifact.units in
  (* By path, because that is what identifies a unit. *)
  let doc path =
    List.find_map
      (fun (u : Artifact.unit_interface) ->
        match u.Artifact.path with
        | Some p when String.equal (Ast.slashed p) path -> u.Artifact.doc
        | _ -> None)
      a.Artifact.units
  in
  let entries =
    with_impls
      (List.concat_map
         (declaration ~known ~places ~prefixes ~package:a.Artifact.package ~exports)
         a.Artifact.program)
  in
  let unit_json (path, ns) =
    match List.filter (fun e -> String.equal e.unit_ path) entries with
    (* A unit that documents nothing is left out rather than reported empty.
       Every package embeds whatever of the standard library it imported, and
       those units are listed beside its own -- but they are not this package's
       to document, so they belong to `cx docs std`. *)
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
           (* Relative to the package root, so nothing the building machine knows
              is in the document. A renderer groups by its directories and
              resolves a source link against whatever base it has. *)
           ; "path", Json.String (Ast.slashed path)
           ; "doc", Json.opt (fun d -> Json.String d) (doc path)
           ; "entries", Json.List (List.map (fun e -> e.json) sorted)
           ])
  in
  Json.Obj
    [ "name", Json.String a.Artifact.package
    ; "version", Json.opt (fun v -> Json.String v) version
    ; ( "units"
      , Json.List
          (extra
           @ List.filter_map
               unit_json
               (* By path, so the order is the tree's and two units of one name
                  are two units. *)
               (List.sort (fun (a, _) (b, _) -> String.compare a b) places) ) )
    ]

(* [extra] is a unit that belongs to a package without being one of its files:
   the natives, which `cx docs std` documents because they are the language's
   rather than any package's. It stands first, as the thing every program has
   before it imports anything. *)
let index ~root ~versions ?(extra = fun _ -> []) (artifacts : Artifact.t list) =
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
               package_json
                 ~known
                 ~version:(versions a.Artifact.package)
                 ~extra:(extra a.Artifact.package)
                 a)
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
            ~extra:(fun package ->
              if String.equal package library_name then [ natives_json () ] else [])
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
