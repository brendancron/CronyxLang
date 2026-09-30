(* The reference as static HTML, written from the index and nothing else.

   No compiler is reachable from here: everything on a page came out of the
   JSON, which is what stops the pages and the index from drifting into
   disagreeing about what a declaration is.

   One page per unit, each declaration anchored inside it. A cross-reference is
   therefore a path and a fragment, which needs no server and no script. *)

let escape text =
  let buf = Buffer.create (String.length text + 16) in
  String.iter
    (fun c ->
      match c with
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | '"' -> Buffer.add_string buf "&quot;"
      | c -> Buffer.add_char buf c)
    text;
  Buffer.contents buf

(* `#` is in every id and must be percent-encoded in a fragment, which makes a
   link unreadable in a status bar. A dot reads as the path it is.

   An impl's id also carries the trait's written arguments -- `Into<float>` --
   and those go the same way: an angle bracket in an anchor is an angle bracket
   in a URL. Folding them cannot collide, because what differed before the fold
   still differs after it. *)
let slug id =
  String.map
    (fun c ->
      match c with
      | '#' | '<' | '>' | ',' -> '.'
      | ' ' -> '_'
      | c -> c)
    id

(* ---- the doc comment ---- *)

(* Paragraphs, bullets, fenced blocks and inline code. Not a Markdown
   implementation: a doc comment that wants more than this is telling you the
   renderer needs a real parser, and guessing at emphasis in the meantime turns
   an `a * b` into an italic. *)
let inline text =
  let buf = Buffer.create (String.length text + 16) in
  let rec go i code =
    if i >= String.length text
    then (
      if code then Buffer.add_string buf "</code>";
      Buffer.contents buf)
    else if Char.equal text.[i] '`'
    then (
      Buffer.add_string buf (if code then "</code>" else "<code>");
      go (i + 1) (not code))
    else (
      Buffer.add_string buf (escape (String.make 1 text.[i]));
      go (i + 1) code)
  in
  go 0 false

let markdown text =
  if String.equal (String.trim text) ""
  then ""
  else (
    let buf = Buffer.create (String.length text + 64) in
    let bullet line =
      let t = String.trim line in
      (String.length t > 1 && (Char.equal t.[0] '-' || Char.equal t.[0] '*'))
      && Char.equal t.[1] ' '
    in
    let fence line = String.starts_with ~prefix:"```" (String.trim line) in
    let rec go lines ~in_list ~in_code =
      let close () =
        if in_list then Buffer.add_string buf "</ul>\n";
        if in_code then Buffer.add_string buf "</code></pre>\n"
      in
      match lines with
      | [] -> close ()
      | line :: rest when in_code ->
        if fence line
        then (
          Buffer.add_string buf "</code></pre>\n";
          go rest ~in_list:false ~in_code:false)
        else (
          Buffer.add_string buf (escape line);
          Buffer.add_char buf '\n';
          go rest ~in_list ~in_code:true)
      | line :: rest when fence line ->
        close ();
        Buffer.add_string buf "<pre><code>";
        go rest ~in_list:false ~in_code:true
      | line :: rest when bullet line ->
        if not in_list then Buffer.add_string buf "<ul>\n";
        let t = String.trim line in
        Buffer.add_string buf "<li>";
        Buffer.add_string buf (inline (String.sub t 2 (String.length t - 2)));
        Buffer.add_string buf "</li>\n";
        go rest ~in_list:true ~in_code:false
      | line :: rest when String.equal (String.trim line) "" ->
        close ();
        go rest ~in_list:false ~in_code:false
      | line :: rest ->
        if in_list then Buffer.add_string buf "</ul>\n";
        (* A paragraph runs to the next blank line, so a doc wrapped at column
           eighty is one paragraph rather than six. *)
        let rec paragraph acc = function
          | l :: more when (not (String.equal (String.trim l) "")) && (not (bullet l)) && not (fence l) ->
            paragraph (l :: acc) more
          | more -> List.rev acc, more
        in
        let lines, rest = paragraph [ line ] rest in
        Buffer.add_string buf "<p>";
        Buffer.add_string buf (inline (String.concat " " (List.map String.trim lines)));
        Buffer.add_string buf "</p>\n";
        go rest ~in_list:false ~in_code:false
    in
    go (String.split_on_char '\n' text) ~in_list:false ~in_code:false;
    Buffer.contents buf)

(* ---- where a declaration's page is ---- *)

type target =
  { t_package : string
  (* The page, as a path under the package and without its extension: a unit is
     a file, and two files may share a namespace -- `core/Array.cx` and
     `collections/Array.cx` -- so a page named after the namespace would be one
     page for both of them. *)
  ; t_page : string
  ; t_name : string
  }

(* `collections/HashMap.cx` is `collections/HashMap.html`, and a unit with no
   path -- the natives, which are in no file -- is its own name. A package's
   modules all sit under `src/`, which says nothing and is the one segment a
   consumer never writes, so it comes off. *)
let without_src path =
  if String.starts_with ~prefix:"src/" path
  then String.sub path 4 (String.length path - 4)
  else path

let page_for ~namespace ~path =
  match path with
  | Some path -> Filename.remove_extension (without_src path)
  | None -> namespace

(* Every id in the build, so a reference knows whether it has a page to point at
   and how far away it is. *)
let targets index =
  let table = Hashtbl.create 256 in
  List.iter
    (fun package ->
      let name = Json.text (Json.field "name" package) in
      List.iter
        (fun unit_ ->
          let page =
            page_for
              ~namespace:(Json.text (Json.field "namespace" unit_))
              ~path:
                (match Json.field "path" unit_ with
                 | Json.String p -> Some p
                 | _ -> None)
          in
          List.iter
            (fun entry ->
              Hashtbl.replace
                table
                (Json.text (Json.field "id" entry))
                { t_package = name
                ; t_page = page
                ; t_name = Json.text (Json.field "name" entry)
                })
            (Json.items (Json.field "entries" unit_)))
        (Json.items (Json.field "units" package)))
    (Json.items (Json.field "packages" index));
  table

let page_of t = t.t_package ^ "/" ^ t.t_page ^ ".html"

(* How far up from a page to the root of the site: a page under a directory of
   its own is one level further away than one beside the index. *)
let depth_of page = List.length (String.split_on_char '/' page)

let up depth = String.concat "" (List.init depth (fun _ -> "../"))

(* Relative, so the directory can be opened from a file:// URL or served from
   anywhere without the paths meaning something different. *)
let link ~from ~table id label =
  match Hashtbl.find_opt table id with
  | None -> escape label
  | Some t ->
    let href =
      if String.equal t.t_package from.t_package && String.equal t.t_page from.t_page
      then "#" ^ slug id
      else up (depth_of from.t_page) ^ page_of t ^ "#" ^ slug id
    in
    Printf.sprintf "<a href=\"%s\">%s</a>" (escape href) (escape label)

(* ---- types ---- *)

let rec type_html ~from ~table node =
  let name () = Json.text (Json.field "name" node) in
  let args () =
    String.concat ", " (List.map (type_html ~from ~table) (Json.items (Json.field "args" node)))
  in
  let named () =
    let r = Json.field "ref" node in
    if Json.is_null r
    then
      Printf.sprintf
        "<span class=\"%s\">%s</span>"
        (if Json.flag (Json.field "param" node) then "tp" else "prim")
        (escape (name ()))
    else link ~from ~table (Json.text r) (name ())
  in
  match Json.text (Json.field "kind" node) with
  | "name" -> named ()
  | "app" -> Printf.sprintf "%s&lt;%s&gt;" (named ()) (args ())
  | "tuple" ->
    Printf.sprintf
      "(%s)"
      (String.concat ", " (List.map (type_html ~from ~table) (Json.items (Json.field "items" node))))
  | "record" ->
    Printf.sprintf
      "{ %s }"
      (String.concat
         ", "
         (List.map
            (fun f ->
              Printf.sprintf
                "%s: %s"
                (escape (Json.text (Json.field "name" f)))
                (type_html ~from ~table (Json.field "type" f)))
            (Json.items (Json.field "fields" node))))
  | "fn" ->
    Printf.sprintf
      "(%s) -&gt;%s %s"
      (String.concat
         ", "
         (List.map (type_html ~from ~table) (Json.items (Json.field "params" node))))
      (* A written function *type* carries a plain list rather than an option, so
         an empty one is a row nobody wrote and printing `<>` would invent one. *)
      (match Json.items (Json.field "row" node) with
       | [] -> ""
       | _ -> row_html ~from ~table (Json.field "row" node))
      (type_html ~from ~table (Json.field "ret" node))
  | "variadic" -> "..." ^ type_html ~from ~table (Json.field "of" node)
  | "spread" -> "..." ^ type_html ~from ~table (Json.field "of" node)
  | "assoc" ->
    Printf.sprintf
      "%s.%s"
      (type_html ~from ~table (Json.field "of" node))
      (escape (Json.text (Json.field "member" node)))
  | "bind" ->
    Printf.sprintf
      "%s = %s"
      (escape (Json.text (Json.field "name" node)))
      (type_html ~from ~table (Json.field "type" node))
  | "row" -> String.trim (row_html ~from ~table (Json.field "row" node))
  | _ -> ""

(* An absent row was left to inference and says nothing; a written empty one
   says the function performs no effect, which is worth printing. It stands
   before the type it decorates -- `-> <E> bool`, not `-> bool <E>` -- because
   that is where it is written and `--dump-code` prints it there. *)
and row_html ~from ~table row =
  if Json.is_null row
  then ""
  else
    Printf.sprintf
      " &lt;%s&gt;"
      (String.concat
         ", "
         (List.map
            (fun e ->
              let head =
                link ~from ~table (Json.text (Json.field "ref" e)) (Json.text (Json.field "name" e))
              in
              match Json.items (Json.field "args" e) with
              | [] -> head
              | args ->
                Printf.sprintf
                  "%s&lt;%s&gt;"
                  head
                  (String.concat ", " (List.map (type_html ~from ~table) args)))
            (Json.items row)))

let params_html ~from ~table ps =
  String.concat
    ", "
    (List.map
       (fun p ->
         let name = escape (Json.text (Json.field "name" p)) in
         let ty = Json.field "type" p in
         match String.equal name "", Json.is_null ty with
         (* A native has no written parameter names. *)
         | true, _ -> type_html ~from ~table ty
         | false, true -> name
         | false, false -> name ^ ": " ^ type_html ~from ~table ty)
       (Json.items ps))

(* `<>` parameters. A bound and a value are both written as a name with a type
   and mean different things -- `<T: Ord>` is a generic the checker constrains,
   `<n: int>` is a value a copy is made for -- so each is styled as what it is
   and neither is left for a reader to infer. *)
let statics_html ~from ~table ps =
  match Json.items ps with
  | [] -> ""
  | ps ->
    Printf.sprintf
      "&lt;%s&gt;"
      (String.concat
         ", "
         (List.map
            (fun p ->
              let form = Json.text (Json.field "form" p) in
              let name = escape (Json.text (Json.field "name" p)) in
              let name = if Json.flag (Json.field "pack" p) then "..." ^ name else name in
              let name =
                Printf.sprintf
                  "<span class=\"%s\">%s</span>"
                  (if String.equal form "value" then "sv" else "tp")
                  name
              in
              match form with
              | "type" -> name
              | _ -> name ^ ": " ^ type_html ~from ~table (Json.field "type" p))
            ps))

let returns_html ~from ~table entry =
  let row = row_html ~from ~table (Json.field "row" entry) in
  match Json.field "ret" entry with
  (* A row with nothing to decorate still says the function performs no effect,
     and `: <>` is how that is written. *)
  | ret when Json.is_null ret -> if String.equal row "" then "" else ":" ^ row
  | ret -> ":" ^ row ^ " " ^ type_html ~from ~table ret

(* ---- pieces of a page ---- *)

(* A trait's and an effect's parameters are bare names -- neither takes a bound
   or a value -- so they are a list of strings rather than the `<>` parameters a
   `fn` or a `type` carries. *)
let names_html ns =
  match Json.items ns with
  | [] -> ""
  | ns ->
    Printf.sprintf
      "&lt;%s&gt;"
      (String.concat
         ", "
         (List.map
            (fun n -> Printf.sprintf "<span class=\"tp\">%s</span>" (escape (Json.text n)))
            ns))

(* A trait written at arguments: `Index<Range>` is not `Index`, and an impl head
   and a supertrait bound are both written that way. *)
let applied_html ~from ~table node =
  let head =
    link ~from ~table (Json.text (Json.field "ref" node)) (Json.text (Json.field "name" node))
  in
  match Json.items (Json.field "args" node) with
  | [] -> head
  | args ->
    Printf.sprintf
      "%s&lt;%s&gt;"
      head
      (String.concat ", " (List.map (type_html ~from ~table) args))

let doc_html entry =
  match Json.field "doc" entry with
  | Json.String text -> Printf.sprintf "<div class=\"doc\">%s</div>\n" (markdown text)
  | _ -> ""

let attrs_html entry =
  match Json.items (Json.field "attrs" entry) with
  | [] -> ""
  | attrs ->
    Printf.sprintf
      "<div class=\"attrs\">%s</div>\n"
      (String.concat
         " "
         (List.map
            (fun a ->
              let args =
                List.map
                  (fun arg ->
                    match arg with
                    | Json.Obj [ (_, v) ] ->
                      (match v with
                       | Json.String s -> Printf.sprintf "%S" s
                       | Json.Int n -> string_of_int n
                       | Json.Bool b -> if b then "true" else "false"
                       | _ -> "")
                    | _ -> "")
                  (Json.items (Json.field "args" a))
              in
              Printf.sprintf
                "<code>@%s%s</code>"
                (escape (Json.text (Json.field "name" a)))
                (match args with
                 | [] -> ""
                 | args -> "(" ^ escape (String.concat ", " args) ^ ")"))
            attrs))

let method_html ~from ~table m =
  Printf.sprintf
    "<div class=\"member\"><div class=\"sig\"><span class=\"kw\">fn</span> %s%s(%s)%s</div>\n%s%s</div>\n"
    (escape (Json.text (Json.field "name" m)))
    (statics_html ~from ~table (Json.field "static" m))
    (params_html ~from ~table (Json.field "params" m))
    (returns_html ~from ~table m)
    (attrs_html m)
    (doc_html m)

let body_html ~from ~table entry =
  let body = Json.field "body" entry in
  match Json.text (Json.field "form" body) with
  | "fields" ->
    String.concat
      ""
      (List.map
         (fun f ->
           Printf.sprintf
             "<div class=\"member\"><div class=\"sig\">%s: %s</div>\n%s%s</div>\n"
             (escape (Json.text (Json.field "name" f)))
             (type_html ~from ~table (Json.field "type" f))
             (attrs_html f)
             (doc_html f))
         (Json.items (Json.field "fields" body)))
  | "variants" ->
    String.concat
      ""
      (List.map
         (fun v ->
           let payload = Json.field "payload" v in
           let written =
             match Json.text (Json.field "form" payload) with
             | "tuple" ->
               Printf.sprintf
                 "(%s)"
                 (String.concat
                    ", "
                    (List.map (type_html ~from ~table) (Json.items (Json.field "items" payload))))
             | "fields" ->
               Printf.sprintf
                 " { %s }"
                 (String.concat
                    ", "
                    (List.map
                       (fun f ->
                         Printf.sprintf
                           "%s: %s"
                           (escape (Json.text (Json.field "name" f)))
                           (type_html ~from ~table (Json.field "type" f)))
                       (Json.items (Json.field "fields" payload))))
             | _ -> ""
           in
           let result =
             match Json.field "result" v with
             | r when Json.is_null r -> ""
             | r -> ": " ^ type_html ~from ~table r
           in
           Printf.sprintf
             "<div class=\"member\"><div class=\"sig\">%s%s%s%s</div>\n%s%s</div>\n"
             (escape (Json.text (Json.field "name" v)))
             (names_html (Json.field "generics" v))
             written
             result
             (attrs_html v)
             (doc_html v))
         (Json.items (Json.field "variants" body)))
  | _ -> ""

let signature_html ~from ~table entry =
  let name = escape (Json.text (Json.field "name" entry)) in
  let kw word = Printf.sprintf "<span class=\"kw\">%s</span>" word in
  match Json.text (Json.field "kind" entry) with
  | "fn" ->
    Printf.sprintf
      "%s %s%s(%s)%s"
      (kw "fn")
      name
      (statics_html ~from ~table (Json.field "static" entry))
      (params_html ~from ~table (Json.field "params" entry))
      (returns_html ~from ~table entry)
  | "type" ->
    Printf.sprintf "%s %s%s" (kw "type") name (statics_html ~from ~table (Json.field "generics" entry))
  | "trait" ->
    let supers =
      match Json.items (Json.field "supers" entry) with
      | [] -> ""
      | list -> ": " ^ String.concat " + " (List.map (applied_html ~from ~table) list)
    in
    Printf.sprintf
      "%s %s%s%s"
      (kw "trait")
      name
      (names_html (Json.field "generics" entry))
      supers
  | "impl" ->
    let trait = Json.field "trait" entry in
    (* The parameters belong to the target, which is where they are written:
       `impl Index<int> for List<T>`. *)
    let target =
      type_html ~from ~table (Json.field "for" entry)
      ^ statics_html ~from ~table (Json.field "generics" entry)
    in
    if Json.is_null trait
    then Printf.sprintf "%s %s" (kw "impl") target
    else
      Printf.sprintf
        "%s %s %s %s"
        (kw "impl")
        (applied_html ~from ~table trait)
        (kw "for")
        target
  | "effect" ->
    Printf.sprintf "%s %s%s" (kw "effect") name (names_html (Json.field "generics" entry))
  | "handler" ->
    let handles = Json.field "handles" entry in
    Printf.sprintf
      "%s %s : %s"
      (kw "handler")
      name
      (link ~from ~table (Json.text (Json.field "ref" handles)) (Json.text (Json.field "name" handles)))
  | "var" ->
    let ty = Json.field "type" entry in
    Printf.sprintf
      "%s %s%s"
      (kw "var")
      name
      (if Json.is_null ty then "" else ": " ^ type_html ~from ~table ty)
  | _ -> name

(* The impls a type or a trait carries. A trait's are the only way to reach an
   impl for a primitive: `int` has no declaration and so no page to list it on. *)
let impls_html ~from ~table ~label entry =
  match Json.items (Json.field "impls" entry) with
  | [] -> ""
  | ids ->
    Printf.sprintf
      "<div class=\"impls\">%s %s</div>\n"
      label
      (String.concat
         ", "
         (List.map
            (fun id ->
              let id = Json.text id in
              let name =
                match Hashtbl.find_opt table id with
                | Some t -> t.t_name
                | None -> id
              in
              link ~from ~table id name)
            ids))

(* `type Item;` in a trait, and `type Item = int;` in an impl that binds it. *)
let assoc_html ~from ~table entry =
  String.concat
    ""
    (List.map
       (fun a ->
         let bound =
           match Json.field "type" a with
           | ty when Json.is_null ty -> ""
           | ty -> " = " ^ type_html ~from ~table ty
         in
         Printf.sprintf
           "<div class=\"member\"><div class=\"sig\"><span class=\"kw\">type</span> \
            %s%s</div>\n%s%s</div>\n"
           (escape (Json.text (Json.field "name" a)))
           bound
           (attrs_html a)
           (doc_html a))
       (Json.items (Json.field "assoc" entry)))

let members_html ~from ~table entry =
  match Json.text (Json.field "kind" entry) with
  | "type" ->
    body_html ~from ~table entry ^ impls_html ~from ~table ~label:"Implements:" entry
  | "trait" ->
    assoc_html ~from ~table entry
    ^ String.concat "" (List.map (method_html ~from ~table) (Json.items (Json.field "methods" entry)))
    ^ impls_html ~from ~table ~label:"Implemented by:" entry
  | "impl" ->
    assoc_html ~from ~table entry
    ^ String.concat "" (List.map (method_html ~from ~table) (Json.items (Json.field "methods" entry)))
  | "effect" ->
    String.concat
      ""
      (List.map
         (fun o ->
           Printf.sprintf
             "<div class=\"member\"><div class=\"sig\"><span class=\"kw\">%s</span> %s%s(%s)%s</div>\n%s%s</div>\n"
             (escape (Json.text (Json.field "kind" o)))
             (escape (Json.text (Json.field "name" o)))
             (names_html (Json.field "generics" o))
             (params_html ~from ~table (Json.field "params" o))
             (let r = Json.field "ret" o in
              if Json.is_null r then "" else ": " ^ type_html ~from ~table r)
             (attrs_html o)
             (doc_html o))
         (Json.items (Json.field "ops" entry)))
  | "handler" ->
    String.concat
      ""
      (List.map
         (fun a ->
           Printf.sprintf
             "<div class=\"member\"><div class=\"sig\"><span class=\"kw\">%s</span> %s(%s)</div></div>\n"
             (escape (Json.text (Json.field "kind" a)))
             (escape (Json.text (Json.field "name" a)))
             (String.concat ", " (List.map (fun p -> escape (Json.text p)) (Json.items (Json.field "params" a)))))
         (Json.items (Json.field "arms" entry)))
  | _ -> ""

(* Where the declaration was written. The line is the index's; the file is the
   unit's, since a unit is one file. *)
let source_html ~path entry =
  match path, Json.field "line" entry with
  | Some path, Json.Int line ->
    Printf.sprintf
      "<span class=\"where\">%s:%d</span>"
      (escape path)
      line
  | _ -> ""

let entry_html ~from ~table ~path entry =
  Printf.sprintf
    "<section id=\"%s\" class=\"entry %s\">\n<h2><a class=\"self\" href=\"#%s\">%s</a>%s</h2>\n<div class=\"sig head\">%s</div>\n%s%s%s</section>\n"
    (escape (slug (Json.text (Json.field "id" entry))))
    (escape (Json.text (Json.field "kind" entry)))
    (escape (slug (Json.text (Json.field "id" entry))))
    (escape (Json.text (Json.field "name" entry)))
    (source_html ~path entry)
    (signature_html ~from ~table entry)
    (attrs_html entry)
    (doc_html entry)
    (members_html ~from ~table entry)

(* A page reads by kind rather than by one alphabet through all of them: a
   reader looking for a function is not helped by the impls sorted among them,
   and an impl's title is its type's name, so two sections a page apart
   otherwise carry the same heading. Within a kind the index's order stands. *)
let kinds =
  [ "type", "Types"
  ; "trait", "Traits"
  ; "effect", "Effects"
  ; "handler", "Handlers"
  ; "fn", "Functions"
  ; "var", "Values"
  ; "impl", "Implementations"
  ]

let grouped entries =
  List.filter_map
    (fun (kind, heading) ->
      match
        List.filter (fun e -> String.equal (Json.text (Json.field "kind" e)) kind) entries
      with
      | [] -> None
      | mine -> Some (heading, mine))
    kinds

(* ---- pages ---- *)

let style =
  {|:root { color-scheme: light dark; --fg: #1b1b1f; --bg: #fdfdfd; --dim: #61616b;
  --rule: #e2e2e8; --accent: #2b5fa8; --code: #f4f4f7; }
@media (prefers-color-scheme: dark) { :root { --fg: #e6e6ea; --bg: #17171a;
  --dim: #9b9ba6; --rule: #2c2c33; --accent: #8ab4f8; --code: #1f1f24; } }
* { box-sizing: border-box; }
body { margin: 0 auto; padding: 2rem 1rem 6rem; max-width: 52rem; background: var(--bg);
  color: var(--fg); font: 16px/1.6 ui-sans-serif, system-ui, sans-serif; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
code, .sig { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
h1 { font-size: 1.6rem; margin: 0 0 .25rem; }
h2 { font-size: 1.1rem; margin: 0 0 .5rem; }
h2 a.self { color: inherit; }
.crumb { color: var(--dim); font-size: .85rem; margin-bottom: 2rem; }
.mark { display: block; margin-bottom: .75rem; }
.entry { border-top: 1px solid var(--rule); padding-top: 1.5rem; margin-top: 1.5rem; }
.sig.head { font-size: 1rem; margin-bottom: .75rem; }
.kw { color: var(--dim); }
.tp { font-style: italic; }
.doc p { margin: .5rem 0; }
.doc ul { margin: .5rem 0; padding-left: 1.25rem; }
.doc pre { background: var(--code); padding: .75rem; overflow-x: auto; border-radius: 4px; }
.member { border-left: 2px solid var(--rule); padding: .25rem 0 .25rem .75rem; margin: .75rem 0; }
.member .sig { font-size: .9rem; }
.attrs { color: var(--dim); font-size: .85rem; margin: .25rem 0; }
.impls { color: var(--dim); font-size: .85rem; margin-top: .75rem; }
.units { list-style: none; padding: 0; }
.units li { padding: .3rem 0; }
.kinds { color: var(--dim); font-size: .85rem; }
h3 { font-size: .95rem; margin: 1.5rem 0 .25rem; color: var(--dim);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
h2.kind { font-size: .8rem; letter-spacing: .08em; text-transform: uppercase;
  color: var(--dim); margin: 2.5rem 0 0; border-bottom: 1px solid var(--rule);
  padding-bottom: .25rem; }
h2.kind + .entry { border-top: none; }
.sv { font-style: italic; color: var(--accent); }
.where { color: var(--dim); font-size: .75rem; font-weight: normal;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin-left: .5rem; }
.import { margin: 0 0 1.5rem; }
.import code { background: var(--code); padding: .2rem .4rem; border-radius: 3px; }
.search { width: 100%; padding: .5rem .6rem; margin: 0 0 1rem; font: inherit;
  color: var(--fg); background: var(--bg); border: 1px solid var(--rule);
  border-radius: 4px; }
|}

let document ~depth ~title body =
  let up = String.concat "" (List.init depth (fun _ -> "../")) in
  Printf.sprintf
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta \
     name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>%s</title>\n<link \
     rel=\"icon\" href=\"%slogo.svg\">\n<link rel=\"stylesheet\" \
     href=\"%sstyle.css\">\n</head>\n<body>\n%s</body>\n</html>\n"
    (escape title)
    up
    up
    body

(* What a consumer in another package writes to reach this unit -- inside a
   package an import is a path relative to the file that wrote it, so there is
   nothing general to print. A package's modules are under `src/`, which `cx`
   is what mandates and which `Loader.in_package` puts back, so the segment
   comes off here; and the root module is reached as the package itself. The
   library has no `src/`: `stdlib/collections/HashMap.cx` is
   `import "std/collections/HashMap"`. *)
let import_of ~package ~namespace ~path =
  match path with
  | None -> None
  | Some _ when String.equal package namespace -> Some package
  | Some path ->
    Some (package ^ "/" ^ Filename.remove_extension (without_src path))

let unit_page ~table ~package ~version unit_ =
  let namespace = Json.text (Json.field "namespace" unit_) in
  let path =
    match Json.field "path" unit_ with
    | Json.String p -> Some p
    | _ -> None
  in
  let page = page_for ~namespace ~path in
  let from = { t_package = package; t_page = page; t_name = namespace } in
  let entries = Json.items (Json.field "entries" unit_) in
  let section (heading, mine) =
    Printf.sprintf
      "<h2 class=\"kind\">%s</h2>\n%s"
      (escape heading)
      (String.concat "" (List.map (entry_html ~from ~table ~path) mine))
  in
  let body =
    Printf.sprintf
      "<h1>%s</h1>\n<div class=\"crumb\"><a href=\"%sindex.html\">index</a> / %s%s%s</div>\n%s%s%s"
      (escape namespace)
      (up (depth_of page))
      (escape package)
      (match version with
       | None -> ""
       | Some v -> escape (" " ^ v))
      (match path with
       | None -> ""
       | Some p -> Printf.sprintf " / <span class=\"where\">%s</span>" (escape p))
      (match import_of ~package ~namespace ~path with
       | None -> ""
       | Some target ->
         Printf.sprintf "<div class=\"import\"><code>import \"%s\";</code></div>\n" (escape target))
      (doc_html unit_)
      (String.concat "" (List.map section (grouped entries)))
  in
  document ~depth:(depth_of page) ~title:(package ^ " / " ^ namespace) body

(* ---- search ---- *)

(* A reference is searched more than it is browsed, and thirty-four modules is
   the last moment at which that is not true.

   The data is the index, written beside the pages -- but *not* fetched: a
   `file://` page asking for a sibling file is a cross-origin request, and every
   browser refuses it, so a reference opened the way `cx docs` opens one would
   have a dead search box. A `<script>` is under no such rule, so the same rows
   are written a second time as an assignment to a global. `index.json` is for
   every consumer that is not a browser reading a local file. *)
let search_html =
  {|<input id="q" class="search" type="search" placeholder="Search declarations" autocomplete="off">
<ul id="results" class="units"></ul>
<script src="search-index.js"></script>
<script src="search.js"></script>
|}

let search_js =
  {|(function () {
  var rows = window.CX_INDEX || [];
  var box = document.getElementById("q");
  var out = document.getElementById("results");
  if (!box || !out) return;
  function render(matches) {
    out.innerHTML = "";
    matches.forEach(function (row) {
      var li = document.createElement("li");
      var a = document.createElement("a");
      a.href = row.h;
      a.textContent = row.n;
      var where = document.createElement("span");
      where.className = "kinds";
      where.textContent = row.k + " — " + row.p + "/" + row.u;
      li.appendChild(a);
      li.appendChild(document.createTextNode(" "));
      li.appendChild(where);
      out.appendChild(li);
    });
  }
  box.addEventListener("input", function () {
    var q = box.value.trim().toLowerCase();
    if (q === "") { out.innerHTML = ""; return; }
    var matches = rows.filter(function (row) {
      return row.n.toLowerCase().indexOf(q) >= 0;
    });
    matches.sort(function (a, b) {
      var an = a.n.toLowerCase().indexOf(q) === 0 ? 0 : 1;
      var bn = b.n.toLowerCase().indexOf(q) === 0 ? 0 : 1;
      if (an !== bn) return an - bn;
      if (a.n.length !== b.n.length) return a.n.length - b.n.length;
      return a.n.localeCompare(b.n);
    });
    render(matches.slice(0, 60));
  });
})();
|}

(* One row per entry: what it is called, what it is, and where its anchor is.
   The doc is not in it -- a name is what a reference is searched by, and the
   whole of every doc comment would be the pages again in one file. *)
let search_rows index =
  let rows =
    List.concat_map
      (fun package ->
        let name = Json.text (Json.field "name" package) in
        List.concat_map
          (fun unit_ ->
            let namespace = Json.text (Json.field "namespace" unit_) in
            let page =
              page_for
                ~namespace
                ~path:
                  (match Json.field "path" unit_ with
                   | Json.String p -> Some p
                   | _ -> None)
            in
            List.map
              (fun entry ->
                let id = Json.text (Json.field "id" entry) in
                Json.Obj
                  [ "n", Json.String (Json.text (Json.field "name" entry))
                  ; "k", Json.String (Json.text (Json.field "kind" entry))
                  ; "p", Json.String name
                  ; "u", Json.String namespace
                  ; "h", Json.String (name ^ "/" ^ page ^ ".html#" ^ slug id)
                  ])
              (Json.items (Json.field "entries" unit_)))
          (Json.items (Json.field "units" package)))
      (Json.items (Json.field "packages" index))
  in
  Json.List rows

(* The directory a unit was written in, which is how the index page groups
   them: `stdlib/collections/HashMap.cx` is imported as
   `std/collections/HashMap`, and a flat alphabet of every module in a library
   throws that away. A unit with no path -- one this package embeds rather than
   owns -- groups under the root, which is also where a single-directory package
   puts everything. *)
let folder unit_ =
  match Json.field "path" unit_ with
  | Json.String path ->
    let path = without_src path in
    (match String.rindex_opt path '/' with
     | None -> ""
     | Some at -> String.sub path 0 at)
  | _ -> ""

let by_folder units =
  let folders =
    List.sort_uniq String.compare (List.map folder units)
    (* The root's own modules first, then each directory. *)
    |> List.sort (fun a b ->
      match String.equal a "", String.equal b "" with
      | true, false -> -1
      | false, true -> 1
      | _ -> String.compare a b)
  in
  List.map (fun f -> f, List.filter (fun u -> String.equal (folder u) f) units) folders

let index_page index =
  let packages = Json.items (Json.field "packages" index) in
  let root = Json.text (Json.field "root" index) in
  let unit_html ~package unit_ =
    let namespace = Json.text (Json.field "namespace" unit_) in
    let entries = Json.items (Json.field "entries" unit_) in
    let kinds =
      List.sort_uniq String.compare (List.map (fun e -> Json.text (Json.field "kind" e)) entries)
    in
    let summary =
      (* The first sentence of the unit's own prose says more than a count of
         its declarations, so the count stands aside for it. *)
      match Json.field "doc" unit_ with
      | Json.String text ->
        let line =
          match String.index_opt text '\n' with
          | Some at -> String.sub text 0 at
          | None -> text
        in
        (match String.index_opt line '.' with
         | Some at -> String.sub line 0 (at + 1)
         | None -> line)
      | _ -> Printf.sprintf "%d — %s" (List.length entries) (String.concat ", " kinds)
    in
    Printf.sprintf
      "<li><a href=\"%s\">%s</a> <span class=\"kinds\">%s</span></li>\n"
      (escape
         (package
          ^ "/"
          ^ page_for
              ~namespace
              ~path:
                (match Json.field "path" unit_ with
                 | Json.String p -> Some p
                 | _ -> None)
          ^ ".html"))
      (escape namespace)
      (escape summary)
  in
  let package_html package =
    let name = Json.text (Json.field "name" package) in
    let version = Json.field "version" package in
    let folder_html (dir, units) =
      Printf.sprintf
        "%s<ul class=\"units\">\n%s</ul>\n"
        (if String.equal dir "" then "" else Printf.sprintf "<h3>%s/</h3>\n" (escape dir))
        (String.concat "" (List.map (unit_html ~package:name) units))
    in
    Printf.sprintf
      "<h2>%s%s%s</h2>\n%s"
      (escape name)
      (if Json.is_null version then "" else " " ^ escape (Json.text version))
      (if String.equal name root then " <span class=\"kinds\">(this package)</span>" else "")
      (String.concat "" (List.map folder_html (by_folder (Json.items (Json.field "units" package)))))
  in
  document
    ~depth:0
    ~title:(root ^ " reference")
    (Printf.sprintf
       "<img class=\"mark\" src=\"logo.svg\" alt=\"\" width=\"44\" height=\"44\">\n<h1>%s</h1>\n<div \
        class=\"crumb\">Cronyx %s</div>\n%s%s"
       (escape root)
       (escape (Json.text (Json.field "compiler" index)))
       search_html
       (String.concat "" (List.map package_html packages)))

(* ---- writing ---- *)

let ensure dir = if not (Sys.file_exists dir) then Sys.mkdir dir 0o755

(* Every directory on the way, so a unit nested two deep has somewhere to be. *)
let rec nested dir =
  if not (Sys.file_exists dir)
  then (
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then nested parent;
    Sys.mkdir dir 0o755)

let write_file path contents =
  Out_channel.with_open_bin path (fun out -> Out_channel.output_string out contents)

(* Returns the page to open. A build product, so the directory is created and
   overwritten rather than merged with whatever was there. *)
let write ~out_dir index =
  ensure out_dir;
  write_file (Filename.concat out_dir "style.css") style;
  write_file (Filename.concat out_dir "logo.svg") Logo.svg;
  write_file (Filename.concat out_dir "search.js") search_js;
  let rows = search_rows index in
  write_file
    (Filename.concat out_dir "search-index.js")
    ("window.CX_INDEX = " ^ Json.to_string rows ^ ";\n");
  (* The model is the interface: a renderer is one consumer of the index and an
     editor or another site is the next, so the document it was built from is
     written beside the pages rather than only under `--json`. *)
  write_file (Filename.concat out_dir "index.json") (Json.to_string index);
  write_file (Filename.concat out_dir "index.html") (index_page index);
  let table = targets index in
  List.iter
    (fun package ->
      let name = Json.text (Json.field "name" package) in
      let version =
        match Json.field "version" package with
        | Json.String v -> Some v
        | _ -> None
      in
      let dir = Filename.concat out_dir name in
      ensure dir;
      List.iter
        (fun unit_ ->
          let namespace = Json.text (Json.field "namespace" unit_) in
          let page =
            page_for
              ~namespace
              ~path:
                (match Json.field "path" unit_ with
                 | Json.String p -> Some p
                 | _ -> None)
          in
          let target = Filename.concat dir (page ^ ".html") in
          (* `collections/HashMap.html` is a directory and a file. *)
          nested (Filename.dirname target);
          write_file target (unit_page ~table ~package:name ~version unit_))
        (Json.items (Json.field "units" package)))
    (Json.items (Json.field "packages" index));
  Filename.concat out_dir "index.html"
