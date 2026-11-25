(* Which instance of a declaration a use reaches: what each static parameter
   was settled to, in the order the declaration lists them. *)

type arg =
  | Type of Types.ty
  | Value of Ast.expr * string
  | Row of Types.row
  (* The handler a run bound the effect named to, at the call. *)
  | Handler of string

type t = (string * arg) list

let show_arg = function
  | Type t -> Types.string_of_ty t
  | Value (_, shown) -> shown
  | Row r -> Types.string_of_ty (Types.Row r)
  | Handler h -> h

(* Also the cache key, so two keys are one instance exactly when they show the
   same. *)
let show (k : t) =
  "{" ^ String.concat ", " (List.map (fun (name, a) -> name ^ " = " ^ show_arg a) k) ^ "}"
