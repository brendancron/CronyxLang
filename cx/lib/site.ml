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
   link unreadable in a status bar. A dot reads as the path it is. *)
let slug id = String.map (fun c -> if Char.equal c '#' then '.' else c) id

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
  ; t_unit : string
  ; t_name : string
  }

(* Every id in the build, so a reference knows whether it has a page to point at
   and how far away it is. *)
let targets index =
  let table = Hashtbl.create 256 in
  List.iter
    (fun package ->
      let name = Json.text (Json.field "name" package) in
      List.iter
        (fun unit_ ->
          let namespace = Json.text (Json.field "namespace" unit_) in
          List.iter
            (fun entry ->
              Hashtbl.replace
                table
                (Json.text (Json.field "id" entry))
                { t_package = name
                ; t_unit = namespace
                ; t_name = Json.text (Json.field "name" entry)
                })
            (Json.items (Json.field "entries" unit_)))
        (Json.items (Json.field "units" package)))
    (Json.items (Json.field "packages" index));
  table

let page_of t = t.t_package ^ "/" ^ t.t_unit ^ ".html"

(* Relative, so the directory can be opened from a file:// URL or served from
   anywhere without the paths meaning something different. *)
let link ~from ~table id label =
  match Hashtbl.find_opt table id with
  | None -> escape label
  | Some t ->
    let href =
      if String.equal t.t_package from.t_package && String.equal t.t_unit from.t_unit
      then "#" ^ slug id
      else "../" ^ page_of t ^ "#" ^ slug id
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
      "(%s) -&gt; %s%s"
      (String.concat
         ", "
         (List.map (type_html ~from ~table) (Json.items (Json.field "params" node))))
      (type_html ~from ~table (Json.field "ret" node))
      (row_html ~from ~table (Json.field "row" node))
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
  | _ -> ""

(* An absent row was left to inference and says nothing; a written empty one
   says the function performs no effect, which is worth printing. *)
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
         if Json.is_null ty then name else name ^ ": " ^ type_html ~from ~table ty)
       (Json.items ps))

(* `<>` parameters, with a value parameter shown as the value it takes: that is
   the difference between a template and a generic and the page should not make
   a reader guess which one this is. *)
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
              let name = escape (Json.text (Json.field "name" p)) in
              let name = if Json.flag (Json.field "pack" p) then "..." ^ name else name in
              match Json.text (Json.field "form" p) with
              | "value" -> name ^ ": " ^ type_html ~from ~table (Json.field "type" p)
              | _ -> name)
            ps))

let returns_html ~from ~table entry =
  let ret = Json.field "ret" entry in
  (if Json.is_null ret then "" else ": " ^ type_html ~from ~table ret)
  ^ row_html ~from ~table (Json.field "row" entry)

(* ---- pieces of a page ---- *)

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
           Printf.sprintf
             "<div class=\"member\"><div class=\"sig\">%s%s</div>\n%s%s</div>\n"
             (escape (Json.text (Json.field "name" v)))
             written
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
      | list ->
        ": "
        ^ String.concat
            " + "
            (List.map
               (fun s ->
                 link ~from ~table (Json.text (Json.field "ref" s)) (Json.text (Json.field "name" s)))
               list)
    in
    Printf.sprintf "%s %s%s" (kw "trait") name supers
  | "impl" ->
    let trait = Json.field "trait" entry in
    let target = type_html ~from ~table (Json.field "for" entry) in
    if Json.is_null trait
    then Printf.sprintf "%s %s" (kw "impl") target
    else
      Printf.sprintf
        "%s %s %s %s"
        (kw "impl")
        (link ~from ~table (Json.text (Json.field "ref" trait)) (Json.text (Json.field "name" trait)))
        (kw "for")
        target
  | "effect" -> Printf.sprintf "%s %s" (kw "effect") name
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

let members_html ~from ~table entry =
  match Json.text (Json.field "kind" entry) with
  | "type" ->
    body_html ~from ~table entry
    ^ (match Json.items (Json.field "impls" entry) with
       | [] -> ""
       | ids ->
         Printf.sprintf
           "<div class=\"impls\">Implementations: %s</div>\n"
           (String.concat
              ", "
              (List.map
                 (fun id ->
                   let id = Json.text id in
                   let label =
                     match Hashtbl.find_opt table id with
                     | Some t -> t.t_name
                     | None -> id
                   in
                   link ~from ~table id label)
                 ids)))
  | "trait" | "impl" ->
    String.concat "" (List.map (method_html ~from ~table) (Json.items (Json.field "methods" entry)))
  | "effect" ->
    String.concat
      ""
      (List.map
         (fun o ->
           Printf.sprintf
             "<div class=\"member\"><div class=\"sig\"><span class=\"kw\">%s</span> %s(%s)%s</div>\n%s</div>\n"
             (escape (Json.text (Json.field "kind" o)))
             (escape (Json.text (Json.field "name" o)))
             (params_html ~from ~table (Json.field "params" o))
             (let r = Json.field "ret" o in
              if Json.is_null r then "" else ": " ^ type_html ~from ~table r)
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

let entry_html ~from ~table entry =
  Printf.sprintf
    "<section id=\"%s\" class=\"entry %s\">\n<h2><a class=\"self\" href=\"#%s\">%s</a></h2>\n<div class=\"sig head\">%s</div>\n%s%s%s</section>\n"
    (escape (slug (Json.text (Json.field "id" entry))))
    (escape (Json.text (Json.field "kind" entry)))
    (escape (slug (Json.text (Json.field "id" entry))))
    (escape (Json.text (Json.field "name" entry)))
    (signature_html ~from ~table entry)
    (attrs_html entry)
    (doc_html entry)
    (members_html ~from ~table entry)

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
|}

let document ~depth ~title body =
  let up = String.concat "" (List.init depth (fun _ -> "../")) in
  Printf.sprintf
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta \
     name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>%s</title>\n<link \
     rel=\"stylesheet\" href=\"%sstyle.css\">\n</head>\n<body>\n%s</body>\n</html>\n"
    (escape title)
    up
    body

let unit_page ~table ~package ~version unit_ =
  let namespace = Json.text (Json.field "namespace" unit_) in
  let from = { t_package = package; t_unit = namespace; t_name = namespace } in
  let entries = Json.items (Json.field "entries" unit_) in
  let body =
    Printf.sprintf
      "<h1>%s</h1>\n<div class=\"crumb\"><a href=\"../index.html\">index</a> / %s%s</div>\n%s"
      (escape namespace)
      (escape package)
      (match version with
       | None -> ""
       | Some v -> escape (" " ^ v))
      (String.concat "" (List.map (entry_html ~from ~table) entries))
  in
  document ~depth:1 ~title:(package ^ " / " ^ namespace) body

let index_page index =
  let packages = Json.items (Json.field "packages" index) in
  let root = Json.text (Json.field "root" index) in
  let package_html package =
    let name = Json.text (Json.field "name" package) in
    let version = Json.field "version" package in
    Printf.sprintf
      "<h2>%s%s%s</h2>\n<ul class=\"units\">\n%s</ul>\n"
      (escape name)
      (if Json.is_null version then "" else " " ^ escape (Json.text version))
      (if String.equal name root then " <span class=\"kinds\">(this package)</span>" else "")
      (String.concat
         ""
         (List.map
            (fun unit_ ->
              let namespace = Json.text (Json.field "namespace" unit_) in
              let entries = Json.items (Json.field "entries" unit_) in
              let kinds =
                List.sort_uniq
                  String.compare
                  (List.map (fun e -> Json.text (Json.field "kind" e)) entries)
              in
              Printf.sprintf
                "<li><a href=\"%s\">%s</a> <span class=\"kinds\">%d — %s</span></li>\n"
                (escape (name ^ "/" ^ namespace ^ ".html"))
                (escape namespace)
                (List.length entries)
                (escape (String.concat ", " kinds)))
            (Json.items (Json.field "units" package))))
  in
  document
    ~depth:0
    ~title:(root ^ " reference")
    (Printf.sprintf
       "<h1>%s</h1>\n<div class=\"crumb\">Cronyx %s</div>\n%s"
       (escape root)
       (escape (Json.text (Json.field "compiler" index)))
       (String.concat "" (List.map package_html packages)))

(* ---- writing ---- *)

let ensure dir = if not (Sys.file_exists dir) then Sys.mkdir dir 0o755

let write_file path contents =
  Out_channel.with_open_bin path (fun out -> Out_channel.output_string out contents)

(* Returns the page to open. A build product, so the directory is created and
   overwritten rather than merged with whatever was there. *)
let write ~out_dir index =
  ensure out_dir;
  write_file (Filename.concat out_dir "style.css") style;
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
          write_file
            (Filename.concat dir (namespace ^ ".html"))
            (unit_page ~table ~package:name ~version unit_))
        (Json.items (Json.field "units" package)))
    (Json.items (Json.field "packages" index));
  Filename.concat out_dir "index.html"
