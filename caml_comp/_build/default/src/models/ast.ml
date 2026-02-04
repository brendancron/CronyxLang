type _ expr =
  | Int: int -> int expr
  | String: string -> string expr
  | Bool: bool -> bool expr
  | Add: int expr * int expr -> int expr
  | Sub: int expr * int expr -> int expr
  | Mult: int expr * int expr -> int expr
  | Div: int expr * int expr -> int expr
  | Equals: 'a expr * 'a expr -> bool expr

type boxed = Box : 'a expr -> boxed

let rec string_of_expr : type a. a expr -> string = function
  | Int n ->
    "Int(" ^ string_of_int n ^ ")"
  | String s ->
    "String(\"" ^ s ^ "\")"
  | Bool b ->
    "Bool(\"" ^ string_of_bool b ^ "\")"
  | Add (l, r) ->
    "Add(" ^ string_of_expr l ^ ", " ^ string_of_expr r ^ ")"
  | Sub (l, r) ->
    "Sub(" ^ string_of_expr l ^ ", " ^ string_of_expr r ^ ")"
  | Mult (l, r) ->
    "Mult(" ^ string_of_expr l ^ ", " ^ string_of_expr r ^ ")"
  | Div (l, r) ->
    "Div(" ^ string_of_expr l ^ ", " ^ string_of_expr r ^ ")"
  | Equals (l, r) ->
    "Equals(" ^ string_of_expr l ^ ", " ^ string_of_expr r ^ ")"

let print_result : type a. a expr -> a -> unit = fun expr v ->
  match expr with
  | Int _ ->
      Printf.printf "%d\n" v

  | String _ ->
      Printf.printf "%s\n" v

  | Bool _ ->
      Printf.printf "%b\n" v

  | Add _ ->
      Printf.printf "%d\n" v

  | Sub _ ->
      Printf.printf "%d\n" v

  | Mult _ ->
      Printf.printf "%d\n" v

  | Div _ ->
      Printf.printf "%d\n" v

  | Equals _ ->
      Printf.printf "%b\n" v
