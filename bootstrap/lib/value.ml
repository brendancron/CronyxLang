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
  | Record of (string * value ref) list
  (* A value behind a trait: the data, and the impl chosen for each method the
     trait declared. Which body runs is read from here, not from the call. *)
  | Object of value * (string * value) list
  | Variant of string * (string * value) list
  | Fn of fn
  (* Never outlives metaprocessing. *)
  | Code of Ast.expr
  (* Apart from a string, so only what reflection handed out can be spliced
     into a name position. *)
  | Name of string

and fn =
  { name : string
  ; arity : int option (* [None] is variadic *)
  ; apply : Ast.span -> value list -> value
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
  | Code _ -> "code"
  | Name _ -> "name"
  | Object _ -> "object"

let rec string_of_value = function
  | Array items ->
    "[" ^ String.concat ", " (Array.to_list (Array.map string_of_value items)) ^ "]"
  | Tuple items -> "(" ^ String.concat ", " (List.map string_of_value items) ^ ")"
  | Variant (name, []) -> name
  | Variant (name, fields) ->
    name ^ "(" ^ String.concat ", " (List.map (fun (_, v) -> string_of_value v) fields) ^ ")"
  | Record fields ->
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
  | Object (data, _) -> string_of_value data
  | Code e -> Printf.sprintf "<code %s>" (Printer.string_of_expr e)
  | Name n -> n

(* OCaml's own comparison raises on functional values. A pair already under
   comparison counts as equal, which is what makes a cyclic value terminate. *)
let rec equal_with seen a b =
  if List.exists (fun (x, y) -> x == a && y == b) seen
  then true
  else (
    let seen = (a, b) :: seen in
    match a, b with
    | Array x, Array y ->
      x == y
      || (Array.length x = Array.length y
          &&
          let rec from i = i >= Array.length x || (equal_with seen x.(i) y.(i) && from (i + 1)) in
          from 0)
    | Record x, Record y ->
      x == y
      || (List.length x = List.length y
          && List.for_all
               (fun (label, cell) ->
                 match List.assoc_opt label y with
                 | Some other -> equal_with seen !cell !other
                 | None -> false)
               x)
    | Tuple x, Tuple y ->
      List.length x = List.length y && List.for_all2 (equal_with seen) x y
    | Variant (n, a), Variant (m, b) ->
      String.equal n m
      && List.length a = List.length b
      && List.for_all2 (fun (_, x) (_, y) -> equal_with seen x y) a b
    | Int x, Int y -> x = y
    | Float x, Float y -> Float.equal x y
    | Str x, Str y -> x = y
    | Byte x, Byte y -> Char.equal x y
    | Chr x, Chr y -> Uchar.equal x y
    | Bool x, Bool y -> x = y
    | Unit, Unit -> true
    | _ -> false)

let values_equal a b = equal_with [] a b

(* A scalar cannot be mutated, so nothing can tell two equal ones apart and it
   falls back to equality. *)
let rec same a b =
  match a, b with
  | Array x, Array y -> x == y
  | Record x, Record y -> x == y
  | Fn x, Fn y -> x == y
  | Code x, Code y -> x == y
  | Name x, Name y -> String.equal x y
  | Tuple x, Tuple y -> List.length x = List.length y && List.for_all2 same x y
  | Variant (n, a), Variant (m, b) ->
    String.equal n m
    && List.length a = List.length b
    && List.for_all2 (fun (_, x) (_, y) -> same x y) a b
  | a, b -> values_equal a b
