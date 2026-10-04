type value =
  | Int of int
  | Float of float
  | Str of Uchar.t array
  | Byte of char
  | Chr of Uchar.t
  | Bool of bool
  | Unit
  | Tuple of value list
  | Array of value array
  (* The declared type each was built as, if any. Writing one back into
     generated code needs it, and the structure alone does not say it. *)
  | Record of string option * (string * value ref) list
  | Variant of string option * string * (string * value) list
  (* A value behind a trait: the data, the type it was made from, and the impl
     chosen for each method the trait declared. Which body runs is read from
     here, not from the call. *)
  | Object of value * identity * (string * value) list
  | Fn of fn
  (* Never outlives metaprocessing. *)
  | Span of Ast.span
  (* Apart from a string, so only what reflection handed out can be spliced
     into a name position. *)
  | Name of string

and fn =
  { name : string
  ; arity : int option (* [None] is variadic *)
  ; apply : Ast.span -> value list -> value
  }

and identity =
  { made_from : string
  ; equal : value option
  }

and env =
  { vars : (string, value ref) Hashtbl.t
  ; parent : env option
  }

type error =
  { span : Ast.span
  ; message : string
  }

exception Runtime_error of error

(* The program asked to end with this exit code. Raised rather than exiting, so
   whoever runs the program -- a command, or the test suite -- decides what
   ending means. *)
exception Exited of int

let fail span fmt =
  Printf.ksprintf (fun message -> raise (Runtime_error { span; message })) fmt

let new_env parent = { vars = Hashtbl.create 16; parent }

let rec lookup env name =
  match Hashtbl.find_opt env.vars name with
  | Some cell -> Some cell
  | None -> Option.bind env.parent (fun parent -> lookup parent name)

let define env name v = Hashtbl.replace env.vars name (ref v)

let type_name = function
  | Tuple _ -> "tuple"
  | Record _ -> "record"
  | Variant _ -> "variant"
  | Int _ -> "int"
  | Float _ -> "float"
  | Str _ -> "string"
  | Byte _ -> "byte"
  | Chr _ -> "char"
  | Bool _ -> "bool"
  | Unit -> "unit"
  | Array _ -> "array"
  | Fn _ -> "fn"
  | Span _ -> "span"
  | Name _ -> "name"
  | Object _ -> "object"

let rec string_of_value = function
  | Array items ->
    "[" ^ String.concat ", " (Array.to_list (Array.map string_of_value items)) ^ "]"
  | Tuple items -> "(" ^ String.concat ", " (List.map string_of_value items) ^ ")"
  | Variant (_, name, []) -> name
  | Variant (_, name, fields) ->
    name ^ "(" ^ String.concat ", " (List.map (fun (_, v) -> string_of_value v) fields) ^ ")"
  | Record (_, fields) ->
    "{ "
    ^ String.concat ", " (List.map (fun (l, v) -> l ^ ": " ^ string_of_value !v) fields)
    ^ " }"
  | Int n -> string_of_int n
  | Float n -> Token.float_to_string n
  | Str s -> Utf8.encode s
  | Byte b -> String.make 1 b
  | Chr c ->
    let buf = Buffer.create 4 in
    Buffer.add_utf_8_uchar buf c;
    Buffer.contents buf
  | Bool b -> string_of_bool b
  | Unit -> "unit"
  | Fn f -> Printf.sprintf "<fn %s>" f.name
  | Object (data, _, _) -> string_of_value data
  | Span s ->
    (match Source_map.Span.view s with
     | Source_map.Span.Nowhere_in_source -> "<generated>"
     | Source_map.Span.Located l ->
       Printf.sprintf
         "%s:%d:%d"
         (Source_map.File.path l.Source_map.Span.file)
         l.Source_map.Span.line
         l.Source_map.Span.col)
  (* A name from another module carries that module's prefix, which the program
     never wrote; it is shown as written. *)
  | Name n ->
    (match String.rindex_opt n '#' with
     | Some at -> String.sub n (at + 1) (String.length n - at - 1)
     | None -> n)

(* OCaml's own comparison raises on functional values. A pair already under
   comparison counts as equal, which is what makes a cyclic value terminate. *)
let rec equal_with span seen a b =
  if List.exists (fun (x, y) -> x == a && y == b) seen
  then true
  else (
    let seen = (a, b) :: seen in
    match a, b with
    | Array x, Array y ->
      x == y
      || (Array.length x = Array.length y
          &&
          let rec from i = i >= Array.length x || (equal_with span seen x.(i) y.(i) && from (i + 1)) in
          from 0)
    | Record (_, x), Record (_, y) ->
      x == y
      || (List.length x = List.length y
          && List.for_all
               (fun (label, cell) ->
                 match List.assoc_opt label y with
                 | Some other -> equal_with span seen !cell !other
                 | None -> false)
               x)
    | Tuple x, Tuple y ->
      List.length x = List.length y && List.for_all2 (equal_with span seen) x y
    | Variant (_, n, a), Variant (_, m, b) ->
      String.equal n m
      && List.length a = List.length b
      && List.for_all2 (fun (_, x) (_, y) -> equal_with span seen x y) a b
    | Int x, Int y -> x = y
    (* IEEE 754's, so NaN equals nothing, itself included, and -0.0 equals 0.0. *)
    | Float x, Float y -> x = y
    | Str x, Str y -> x = y
    | Byte x, Byte y -> Char.equal x y
    | Chr x, Chr y -> Uchar.equal x y
    | Bool x, Bool y -> x = y
    | Unit, Unit -> true
    (* Two objects are equal as `==` would find their data were it not behind a
       trait. An `Eq` impl runs to its end when called: it performs nothing, so
       it is never converted. *)
    | Object (x, i, _), Object (y, j, _) ->
      String.equal i.made_from j.made_from
      && (match i.equal with
          | Some (Fn f) ->
            (match f.apply span [ x; y ] with
             | Bool b -> b
             | other -> fail span "'%s' answered %s rather than a bool." f.name (type_name other))
          | _ -> equal_with span seen x y)
    | Name x, Name y -> String.equal x y
    | Span x, Span y -> x == y
    | _ -> false)

let values_equal span a b = equal_with span [] a b

(* A scalar cannot be mutated, so nothing can tell two equal ones apart and it
   falls back to equality. *)
let rec same span a b =
  match a, b with
  | Array x, Array y -> x == y
  | Record (_, x), Record (_, y) -> x == y
  | Fn x, Fn y -> x == y
  | Span x, Span y -> x == y
  | Name x, Name y -> String.equal x y
  (* By bits: a NaN is itself even though it equals nothing. *)
  | Float x, Float y -> Int64.equal (Int64.bits_of_float x) (Int64.bits_of_float y)
  | Tuple x, Tuple y -> List.length x = List.length y && List.for_all2 (same span) x y
  | Variant (_, n, a), Variant (_, m, b) ->
    String.equal n m
    && List.length a = List.length b
    && List.for_all2 (fun (_, x) (_, y) -> same span x y) a b
  | Object (x, _, _), Object (y, _, _) -> same span x y
  | a, b -> values_equal span a b
