open Models.Ast
open Models.Token

exception Parse_error

let box_add (Box l) (Box r) =
  match l, r with
  | Int _, Int _ -> Box (Add (l, r))
  | _ -> failwith "type error: + expects ints"

let box_sub (Box l) (Box r) =
  match l, r with
  | Int _, Int _ -> Box (Sub (l, r))
  | _ -> failwith "type error: - expects ints"

let box_mult (Box l) (Box r) =
  match l, r with
  | Int _, Int _ -> Box (Mult (l, r))
  | _ -> failwith "type error: * expects ints"

let box_div (Box l) (Box r) =
  match l, r with
  | Int _, Int _ -> Box (Div (l, r))
  | _ -> failwith "type error: / expects ints"

let box_equals (Box l) (Box r) =
   match l, r with
   | Int _, Int _ -> Box (Equals (l, r))
   | String _, String _ -> Box (Equals (l, r))
   | Bool _, Bool _ -> Box (Equals (l, r))
   | _ -> failwith "type error: == expects values of same type"

let parse tokens : boxed =
  let pos = ref 0 in
  let peek () = List.nth tokens !pos in
  let advance () = incr pos in
  let consume expected =
    match peek () with
    | t when t = expected -> advance ()
    | _ -> failwith "unexpected token"
  in

  let rec parse_factor () : boxed =
    match peek () with
    | NUMBER n ->
        advance ();
        Box (Int n)

    | STRING s ->
        advance ();
        Box (String s)

    | TRUE ->
        advance ();
        Box (Bool true)

    | FALSE ->
        advance ();
        Box (Bool false)

    | LEFT_PAREN ->
        advance ();
        let Box e = parse_expr () in
        consume RIGHT_PAREN;
        Box e

    | _ ->
        failwith "expected literal or '('"
  
  and parse_term () : boxed =
    let left = ref (parse_factor ()) in
    let rec loop () =
      match peek () with
      | STAR ->
          advance ();
          let right = parse_factor () in
          left := box_mult !left right;
          loop ()
      | SLASH ->
          advance ();
          let right = parse_factor () in
          left := box_div !left right;
          loop ()
      | _ ->
          !left
    in
    loop ()
  
  and parse_expr () : boxed =
    let left = ref (parse_term ()) in
    let rec loop () =
      match peek () with
      | PLUS ->
          advance ();
          let right = parse_term () in
          left := box_add !left right;
          loop ()
      | MINUS ->
          advance ();
          let right = parse_term () in
          left := box_sub !left right;
          loop ()
      | _ ->
          !left
    in
    loop ()
  in

  parse_expr ()
