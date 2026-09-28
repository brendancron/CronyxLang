(* Enough JSON to write the documentation index, and no reader: nothing in `cx`
   consumes JSON, and a parser nobody calls is a parser nobody fixes. *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | String of string
  | List of t list
  | Obj of (string * t) list

(* Only what JSON requires, so text stays as its bytes: a doc comment is UTF-8
   and escaping it to `\u` would make the index unreadable for no gain. *)
let escaped text =
  let buf = Buffer.create (String.length text + 8) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    text;
  Buffer.contents buf

(* Indented rather than dense, because the index is read in a diff as often as
   by a program: a field that changed should be one line of one hunk. *)
let to_string (value : t) =
  let buf = Buffer.create 4096 in
  let pad depth = Buffer.add_string buf (String.make (depth * 2) ' ') in
  let rec write depth value =
    match value with
    | Null -> Buffer.add_string buf "null"
    | Bool b -> Buffer.add_string buf (if b then "true" else "false")
    | Int n -> Buffer.add_string buf (string_of_int n)
    | String text ->
      Buffer.add_char buf '"';
      Buffer.add_string buf (escaped text);
      Buffer.add_char buf '"'
    | List [] -> Buffer.add_string buf "[]"
    | List items ->
      Buffer.add_string buf "[\n";
      List.iteri
        (fun i item ->
          if i > 0 then Buffer.add_string buf ",\n";
          pad (depth + 1);
          write (depth + 1) item)
        items;
      Buffer.add_char buf '\n';
      pad depth;
      Buffer.add_char buf ']'
    | Obj [] -> Buffer.add_string buf "{}"
    | Obj fields ->
      Buffer.add_string buf "{\n";
      List.iteri
        (fun i (label, item) ->
          if i > 0 then Buffer.add_string buf ",\n";
          pad (depth + 1);
          Buffer.add_char buf '"';
          Buffer.add_string buf (escaped label);
          Buffer.add_string buf "\": ";
          write (depth + 1) item)
        fields;
      Buffer.add_char buf '\n';
      pad depth;
      Buffer.add_char buf '}'
  in
  write 0 value;
  Buffer.add_char buf '\n';
  Buffer.contents buf

let string_or_null = function
  | "" -> Null
  | text -> String text

let opt f = function
  | None -> Null
  | Some x -> f x

(* Reading a document back, which is how the renderer is kept honest: it sees
   what the index holds and nothing the index left out. *)
let field label = function
  | Obj fields -> (match List.assoc_opt label fields with Some v -> v | None -> Null)
  | _ -> Null

let items = function
  | List items -> items
  | _ -> []

let text = function
  | String s -> s
  | _ -> ""

let flag = function
  | Bool b -> b
  | _ -> false

let is_null = function
  | Null -> true
  | _ -> false
