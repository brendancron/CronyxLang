open Models.Ast

let rec eval : type a. a expr -> a = function
  | Int n -> n
  | String s -> s
  | Bool b -> b
  | Add (x, y) -> eval x + eval y
  | Sub (x, y) -> eval x - eval y
  | Mult (x, y) -> eval x * eval y
  | Div (x, y) -> eval x / eval y
  | Equals (x,y) -> eval x = eval y
