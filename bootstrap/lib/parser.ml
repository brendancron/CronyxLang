type error =
  { span : Source_map.Span.t
  ; message : string
  }

type state =
  { tokens : Token.token array
  ; mutable current : int
  ; mutable errors : error list (* reversed *)
  (* A `{` after a match's scrutinee opens the cases, so brace literals are
     suppressed there. Parenthesise to write one. *)
  ; mutable no_brace : bool
  }

(* The error is recorded before raising. *)
exception Parse_error

let peek s = s.tokens.(s.current)

let peek_at s ahead =
  let at = s.current + ahead in
  if at < Array.length s.tokens then s.tokens.(at) else s.tokens.(Array.length s.tokens - 1)

let previous s = s.tokens.(s.current - 1)
let is_at_end s = (peek s).Token.token_type = Token.Eof

let advance s =
  if not (is_at_end s) then s.current <- s.current + 1;
  previous s

let check s token_type = (not (is_at_end s)) && (peek s).Token.token_type = token_type

let matches s token_types =
  if List.exists (check s) token_types then Some (advance s) else None

let error s (tok : Token.token) message =
  s.errors <- { span = tok.Token.span; message } :: s.errors;
  Parse_error

let consume s token_type message =
  if check s token_type then advance s else raise (error s (peek s) message)

let consume_identifier s message =
  match (peek s).Token.token_type with
  | Token.Identifier name ->
    ignore (advance s);
    name
  | _ -> raise (error s (peek s) message)

let matches_binop s ops =
  let token_type = (peek s).Token.token_type in
  if List.mem token_type ops
  then (
    match Ast.binop_of_token token_type with
    | Some op ->
      ignore (advance s);
      Some op
    | None -> None)
  else None

(* Panic-mode recovery: skip to what looks like the start of a declaration. *)
let synchronize s =
  ignore (advance s);
  let rec loop () =
    if is_at_end s || (previous s).Token.token_type = Token.Semicolon
    then ()
    else (
      match (peek s).Token.token_type with
      | Token.Fn | Token.Var | Token.For | Token.If | Token.While | Token.Return -> ()
      | _ ->
        ignore (advance s);
        loop ())
  in
  loop ()

(* [closer] is what a trailing comma may be followed by; without it [item]
   would run again and fail on whatever closes the list. [ends] is a list that
   has no closing token to stand behind, so a comma before it is reported as
   the comma rather than as whatever was expected in the item's place. *)
let rec comma_separated ?closer ?ends s item =
  let first = item s in
  let continues =
    match matches s [ Token.Comma ] with
    | None -> false
    | Some comma ->
      (match closer, ends with
       | Some closer, _ when check s closer -> false
       | _, Some (ends, written) when check s ends ->
         ignore (error s comma (Printf.sprintf "A trailing comma is not allowed before '%s'." written));
         false
       | _ -> true)
  in
  if continues then first :: comma_separated ?closer ?ends s item else [ first ]

(* Neither consumes the closer; every caller has its own message for it. *)
let listed_until s closer item =
  if check s closer then [] else comma_separated ~closer s item

(* ---- type annotations ---- *)

(* The loader resolves the pair; nothing after it sees a dot. *)
let qualified s name =
  if not (check s Token.Dot)
  then name
  else (
    ignore (advance s);
    name ^ "." ^ consume_identifier s "Expected a type name after '.'.")

let rec type_expr s : Ast.type_expr =
  let tok = peek s in
  let sp = Ast.span_of_token tok in
  match tok.Token.token_type with
  | Token.Left_brace ->
    ignore (advance s);
    let fields = listed_until s Token.Right_brace typed_field in
    ignore (consume s Token.Right_brace "Expected '}' after record fields.");
    Ast.at sp (Ast.Ty_record fields)
  (* A projection; the loader folds it back if the name is an alias. *)
  | Token.Identifier name ->
    ignore (advance s);
    let head =
      if check s Token.Less
      then (
        ignore (advance s);
        let args = listed_until s Token.Greater type_argument in
        ignore (consume s Token.Greater "Expected '>' after type arguments.");
        Ast.at sp (Ast.Ty_app (name, args)))
      else Ast.at sp (Ast.Ty_name name)
    in
    let rec projected owner =
      if check s Token.Dot
      then (
        ignore (advance s);
        let member = consume_identifier s "Expected an associated type name after '.'." in
        projected (Ast.at sp (Ast.Ty_assoc (owner, member))))
      else owner
    in
    projected head
  | Token.Left_paren ->
    ignore (advance s);
    let items = listed_until s Token.Right_paren spreadable in
    ignore (consume s Token.Right_paren "Expected ')' after type list.");
    if check s Token.Arrow
    then (
      ignore (advance s);
      (* The row comes first, or `<` after the arrow reads as a type argument. *)
      let row = row_annotation s in
      Ast.at sp (Ast.Ty_fn (items, type_expr s, row)))
    else Ast.at sp (Ast.Ty_tuple items)
  | _ -> raise (error s tok "Expected a type.")

(* A pack stands for a parameter list, so it is written where a type is and
   read as however many the pack holds. *)
and spreadable s : Ast.type_expr =
  let sp = Ast.span_of_token (peek s) in
  match matches s [ Token.Dot_dot_dot ] with
  | None -> type_expr s
  | Some _ -> Ast.at sp (Ast.Ty_spread (type_expr s))

(* `Output = T` says what the impl a bound reaches must have bound; anything
   else is an ordinary argument. *)
and type_argument s : Ast.type_expr =
  let tok = peek s in
  match tok.Token.token_type, (peek_at s 1).Token.token_type with
  | Token.Identifier bound, Token.Equal ->
    let sp = Ast.span_of_token tok in
    ignore (advance s);
    ignore (advance s);
    Ast.at sp (Ast.Ty_bind (bound, type_expr s))
  | _ -> spreadable s

and typed_field s =
  let label = consume_identifier s "Expected a field name." in
  ignore (consume s Token.Colon "Expected ':' after field name.");
  label, type_expr s

and row_annotation s : string list =
  match matches s [ Token.Less ] with
  | None -> []
  | Some _ ->
    let labels =
      listed_until s Token.Greater (fun s ->
        consume_identifier s "Expected an effect name.")
    in
    ignore (consume s Token.Greater "Expected '>' after effect row.");
    labels

let type_annotation s : Ast.type_expr option =
  match matches s [ Token.Colon ] with
  | Some _ -> Some (type_expr s)
  | None -> None

let comptime_params s : Ast.comptime_param list =
  match matches s [ Token.Less ] with
  | None -> []
  | Some _ ->
    let params =
      comma_separated ~closer:Token.Greater s (fun s ->
        let starts = peek s in
        let pack = matches s [ Token.Dot_dot_dot ] <> None in
        let name = consume_identifier s "Expected a comptime parameter name." in
        ({ Ast.cp_name = name; cp_ty = type_annotation s; cp_pack = pack }, pack, starts))
    in
    let rec check_last = function
      | (_, pack, _) :: (((_, _, after) :: _) as rest) ->
        if pack then ignore (error s after "A type pack must be the last parameter.");
        check_last rest
      | _ -> ()
    in
    check_last params;
    ignore (consume s Token.Greater "Expected '>' after comptime parameters.");
    List.map (fun (p, _, _) -> p) params

let type_params s : string list =
  List.map (fun (p : Ast.comptime_param) -> p.Ast.cp_name) (comptime_params s)

let pack_names (comptime : Ast.comptime_param list) =
  List.filter_map
    (fun (p : Ast.comptime_param) -> if p.Ast.cp_pack then Some p.Ast.cp_name else None)
    comptime

let declared_type_params s : Ast.type_param list =
  List.map
    (fun (p : Ast.comptime_param) ->
      { Ast.tp_name = p.Ast.cp_name; tp_pack = p.Ast.cp_pack })
    (comptime_params s)

let signature ?(comptime = []) s : Ast.signature =
  let returning () =
    let row = if check s Token.Less then Some (row_annotation s) else None in
    { Ast.ret = Some (type_expr s); row; comptime }
  in
  match matches s [ Token.Colon ] with
  | Some _ -> returning ()
  (* The arrow belongs to a function *type*; a declaration says what it returns
     the way every other annotation does. Read it anyway, so the mistake is one
     diagnostic rather than the wreckage of parsing the rest as statements. *)
  | None when check s Token.Arrow ->
    ignore (error s (peek s) "A return type follows ':', not '->'.");
    ignore (advance s);
    returning ()
  | None -> { Ast.ret = None; row = None; comptime }

(* ---- expressions ---- *)

let rec expression s : Ast.expr = assignment s

and assignment s : Ast.expr =
  let left = or_expr s in
  let target op tok =
    let value = assignment s in
    match left.Ast.it, op with
    | `Var name, None -> Ast.at left.Ast.span (`Assign (name, value))
    | `Var name, Some binop -> Ast.at left.Ast.span (`Compound (binop, name, value))
    | `Index (target, i), None ->
      Ast.at left.Ast.span (`Index_assign (target, i, value))
    | `Field (target, label), None ->
      Ast.at left.Ast.span (`Field_assign (target, label, value))
    | _ ->
      ignore (error s tok "Invalid assignment target.");
      left
  in
  match (peek s).Token.token_type with
  | Token.Equal -> target None (advance s)
  | Token.Plus_equal -> target (Some Ast.Add) (advance s)
  | Token.Minus_equal -> target (Some Ast.Sub) (advance s)
  | Token.Star_equal -> target (Some Ast.Mul) (advance s)
  | Token.Slash_equal -> target (Some Ast.Div) (advance s)
  | Token.Percent_equal -> target (Some Ast.Mod) (advance s)
  | _ -> left

and or_expr s : Ast.expr =
  let rec loop left =
    match matches s [ Token.Pipe_pipe ] with
    | Some _ ->
      let right = and_expr s in
      loop (Ast.at left.Ast.span (`Or (left, right)))
    | None -> left
  in
  loop (and_expr s)

and and_expr s : Ast.expr =
  let rec loop left =
    match matches s [ Token.Amp_amp ] with
    | Some _ ->
      let right = equality s in
      loop (Ast.at left.Ast.span (`And (left, right)))
    | None -> left
  in
  loop (equality s)

and binary_level s ops next : Ast.expr =
  let rec loop left =
    match matches_binop s ops with
    | Some op ->
      let right = next s in
      loop (Ast.at left.Ast.span (`Binop (op, left, right)))
    | None -> left
  in
  loop (next s)

and equality s : Ast.expr =
  binary_level s [ Token.Bang_equal; Token.Equal_equal ] comparison

and comparison s : Ast.expr =
  binary_level
    s
    [ Token.Greater; Token.Greater_equal; Token.Less; Token.Less_equal ]
    term

and term s : Ast.expr = binary_level s [ Token.Minus; Token.Plus ] factor
and factor s : Ast.expr = binary_level s [ Token.Slash; Token.Star; Token.Percent ] unary

and unary s : Ast.expr =
  match Ast.unop_of_token (peek s).Token.token_type with
  | Some op ->
    let tok = advance s in
    let right = unary s in
    Ast.at (Ast.span_of_token tok) (`Unop (op, right))
  | None -> postfix s

(* These yield the updated value, so `++x` and `x++` would mean the same thing;
   only the postfix spelling is accepted. *)
and postfix s : Ast.expr =
  let rec loop left =
    let step op tok =
      match left.Ast.it with
      | `Var name ->
        let one = Ast.at (Ast.span_of_token tok) (`Int 1) in
        loop (Ast.at left.Ast.span (`Compound (op, name, one)))
      | _ ->
        ignore (error s tok "Invalid increment target.");
        left
    in
    match (peek s).Token.token_type with
    | Token.Plus_plus -> step Ast.Add (advance s)
    | Token.Minus_minus -> step Ast.Sub (advance s)
    | _ -> left
  in
  loop (call s)

and call s : Ast.expr =
  let rec loop callee =
    match (peek s).Token.token_type with
    | Token.Left_paren ->
      ignore (advance s);
      loop (finish_call s callee)
    (* `f { it * 2 }` — the parentheses a call would need are what the braces
       stand in for, so there is nothing between the callee and the lambda. *)
    | Token.Left_brace when not s.no_brace && callable callee ->
      loop (Ast.at callee.Ast.span (`Call (callee, trailing_lambda s [])))
    | Token.Left_bracket ->
      ignore (advance s);
      let index = index_or_range s in
      ignore (consume s Token.Right_bracket "Expected ']' after index.");
      loop (Ast.at callee.Ast.span (`Index (callee, index)))
    | Token.Less ->
      (match comptime_arguments s with
       | Some comptime_args ->
         ignore (consume s Token.Left_paren "Expected '(' after comptime arguments.");
         loop
           (Ast.at
              callee.Ast.span
              (`Comptime_call (callee, comptime_args, arguments s)))
       | None -> callee)
    | Token.Dot ->
      ignore (advance s);
      (match (peek s).Token.token_type with
       | Token.Int n ->
         ignore (advance s);
         loop (Ast.at callee.Ast.span (`Tuple_get (callee, n)))
       | _ ->
         let label =
           match (peek s).Token.token_type with
           | Token.Identifier name -> name
           (* An ordinary word after a dot, which lets a module export `new`. *)
           | _ when Scanner.keyword (peek s).Token.lexeme <> None ->
             (peek s).Token.lexeme
           | _ -> raise (error s (peek s) "Expected a field after '.'.")
         in
         ignore (advance s);
         (match matches s [ Token.Left_paren ] with
          | Some _ ->
            loop
              (Ast.at
                 callee.Ast.span
                 (`Method_call (callee, label, label, trailing_lambda s (arguments s))))
          (* `x.m { it }` is the method, not a field holding a function: with
             parentheses there is no field to reach, so braces agree. *)
          | None when check s Token.Left_brace && not s.no_brace ->
            loop
              (Ast.at
                 callee.Ast.span
                 (`Method_call (callee, label, label, trailing_lambda s [])))
          | None -> loop (Ast.at callee.Ast.span (`Field (callee, label)))))
    | _ -> callee
  in
  loop (primary s)

(* `f<int>(x)` and `a < b > (c)` are the same shape, so this is accepted only
   when a call follows; position and errors are put back when none does. *)
and comptime_arguments s : Ast.expr Ast.comptime_arg list option =
  let start = s.current
  and errors = s.errors in
  let restore () =
    s.current <- start;
    s.errors <- errors;
    None
  in
  match
    ignore (advance s);
    let args =
      comma_separated ~closer:Token.Greater s (fun s ->
        let start = s.current
        and errors = s.errors in
        let as_value () =
          s.current <- start;
          s.errors <- errors;
          (* Below comparison, or the closing '>' reads as an operator. *)
          Ast.Ct_value (unary s)
        in
        match type_expr s with
        | t when check s Token.Comma || check s Token.Greater -> Ast.Ct_type t
        | _ -> as_value ()
        | exception Parse_error -> as_value ())
    in
    if check s Token.Greater
    then (
      ignore (advance s);
      Some args)
    else None
  with
  | Some args when check s Token.Left_paren -> Some args
  | _ -> restore ()
  | exception Parse_error -> restore ()

(* Assumes the '(' has been consumed; consumes the closing ')'. *)
and arguments s : Ast.expr list =
  let argument s =
    let starts = peek s in
    let sp = Ast.span_of_token starts in
    match matches s [ Token.Dot_dot_dot ] with
    | None -> expression s, false, starts
    | Some _ -> Ast.at sp (`Spread (expression s)), true, starts
  in
  let args = listed_until s Token.Right_paren argument in
  let rec check_last = function
    | (_, spread, _) :: (((_, _, after) :: _) as rest) ->
      if spread then ignore (error s after "A spread must be the last argument.");
      check_last rest
    | _ -> ()
  in
  check_last args;
  ignore (consume s Token.Right_paren "Expected ')' after arguments.");
  List.map (fun (a, _, _) -> a) args

(* Only a name or something already called can take one, so `if x { … }` and a
   record literal keep their braces. *)
and callable (e : Ast.expr) =
  match e.Ast.it with
  | `Var _ | `Call _ | `Method_call _ | `Comptime_call _ -> true
  | _ -> false

(* `{ x, y -> … }` names the parameters; anything else leaves how many there are
   to the type it is passed to. Read by lookahead, since a body may legitimately
   start with a name. *)
and trailing_params s : Ast.param list option =
  let rec names acc at =
    match (peek_at s at).Token.token_type with
    (* The arrow is what names parameters, so it needs one, and a comma promises
       another. A lambda taking none is written without either. Reaching an arrow
       here means one of the two was broken: nothing has been read yet, or a
       comma was. *)
    | Token.Arrow ->
      ignore
        (error
           s
           (peek_at s at)
           (if acc = []
            then "Expected a parameter name before '->'."
            else "Expected a parameter name after ','."));
      Some (List.rev acc)
    | Token.Identifier name ->
      (match (peek_at s (at + 1)).Token.token_type with
       | Token.Arrow -> Some (List.rev ({ Ast.name; ty = None; implicit = false } :: acc))
       | Token.Comma -> names ({ Ast.name; ty = None; implicit = false } :: acc) (at + 2)
       | _ -> None)
    | _ -> None
  in
  match names [] 0 with
  | None -> None
  | Some params ->
    let rec skip () =
      if (peek s).Token.token_type = Token.Arrow
      then ignore (advance s)
      else (
        ignore (advance s);
        skip ())
    in
    skip ();
    Some params

(* `f(xs) { it * 2 }` — a block after a call is a function value passed last.
   Unnamed parameters stay unresolved here: only the expected type knows whether
   there are none or the one `it` stands for. *)
and trailing_lambda s args : Ast.expr list =
  if not (check s Token.Left_brace && not s.no_brace)
  then args
  else (
    let sp = Ast.span_of_token (peek s) in
    ignore (advance s);
    let params =
      match trailing_params s with
      | Some params -> params
      | None -> [ { Ast.name = "it"; ty = None; implicit = true } ]
    in
    (* An expression filling the braces exactly is the value; anything else
       is a body. Telling them apart takes trying. *)
    let mark = s.current
    and errors = s.errors in
    let restore () =
      s.current <- mark;
      s.errors <- errors;
      block s
    in
    let body =
      match expression s with
      | value when check s Token.Right_brace ->
        ignore (advance s);
        [ { Ast.it = `Return (Some value); span = value.Ast.span; ann = () } ]
      | _ -> restore ()
      | exception Parse_error -> restore ()
    in
    args
    @ [ Ast.at sp (`Lambda (params, { Ast.ret = None; row = None; comptime = [] }, body)) ])

and finish_call s callee : Ast.expr =
  Ast.at callee.Ast.span (`Call (callee, trailing_lambda s (arguments s)))

(* Assumes the '{' has been consumed; consumes the closing '}'. *)
and record_fields s : (string * Ast.expr) list =
  let field s =
    let label = consume_identifier s "Expected a field name." in
    ignore (consume s Token.Colon "Expected ':' after field name.");
    label, expression s
  in
  let fields = listed_until s Token.Right_brace field in
  ignore (consume s Token.Right_brace "Expected '}' after fields.");
  fields

(* Slicing is indexing by a `Range` rather than an `int`, and which entry that
   reaches is the type's business. Either bound may be left out. *)
and index_or_range s : Ast.expr =
  let sp = Ast.span_of_token (peek s) in
  let range variant args =
    let payload = if args = [] then Ast.P_none else Ast.P_tuple args in
    Ast.at sp (`New_variant ("Range", variant, payload))
  in
  if check s Token.Colon
  then (
    ignore (advance s);
    if check s Token.Right_bracket
    then range "All" []
    else range "To" [ expression s ])
  else (
    let first = expression s in
    if not (check s Token.Colon)
    then first
    else (
      ignore (advance s);
      if check s Token.Right_bracket
      then range "From" [ first ]
      else range "Between" [ first; expression s ]))

and starts_lambda s =
  let depth = ref 0
  and at = ref s.current
  and answer = ref false
  and looking = ref true in
  while !looking do
    (match s.tokens.(!at).Token.token_type with
     | Token.Left_paren -> incr depth
     | Token.Right_paren ->
       decr depth;
       if !depth = 0
       then (
         answer := s.tokens.(!at + 1).Token.token_type = Token.Fat_arrow;
         looking := false)
     | Token.Eof -> looking := false
     | _ -> ());
    incr at
  done;
  !answer

and lambda s sp : Ast.expr =
  ignore (consume s Token.Left_paren "Expected '(' before parameters.");
  let params = parameters s in
  ignore (consume s Token.Fat_arrow "Expected '=>' after parameters.");
  let body =
    if check s Token.Left_brace
    then (
      ignore (advance s);
      block s)
    else (
      let e = expression s in
      [ { Ast.it = `Return (Some e); span = e.Ast.span; ann = () } ])
  in
  Ast.at sp (`Lambda (params, { Ast.ret = None; row = None; comptime = [] }, body))

and primary s : Ast.expr =
  let tok = peek s in
  let sp = Ast.span_of_token tok in
  match tok.Token.token_type with
  | Token.Int n ->
    ignore (advance s);
    Ast.at sp (`Int n)
  | Token.Float n ->
    ignore (advance s);
    Ast.at sp (`Float n)
  | Token.String str ->
    ignore (advance s);
    Ast.at sp (`Str (Utf8.decode str))
  | Token.Char c ->
    ignore (advance s);
    Ast.at sp (`Char c)
  | Token.True ->
    ignore (advance s);
    Ast.at sp (`Bool true)
  | Token.False ->
    ignore (advance s);
    Ast.at sp (`Bool false)
  | Token.Identifier name ->
    ignore (advance s);
    Ast.at sp (`Var name)
  | Token.Run ->
    ignore (advance s);
    run_expr s sp
  | Token.Typeof ->
    ignore (advance s);
    ignore (consume s Token.Left_paren "Expected '(' after 'typeof'.");
    let e = expression s in
    ignore (consume s Token.Right_paren "Expected ')' after typeof operand.");
    Ast.at sp (`Typeof e)
  | Token.Code ->
    ignore (advance s);
    ignore (consume s Token.Left_paren "Expected '(' after 'code'.");
    let e = expression s in
    ignore (consume s Token.Right_paren "Expected ')' after the captured expression.");
    Ast.at sp (`Code e)
  | Token.New ->
    ignore (advance s);
    let name = qualified s (consume_identifier s "Expected a type name after 'new'.") in
    (* `::` still separates a sum type from its variant. *)
    if check s Token.Colon_colon
    then (
      ignore (advance s);
      let variant = consume_identifier s "Expected a variant name." in
      let payload =
        match (peek s).Token.token_type with
        (* At least one, or `new T::V()` and `new T::V` would both write the
           same thing. *)
        | Token.Left_paren ->
          ignore (advance s);
          let items = comma_separated ~closer:Token.Right_paren s expression in
          ignore (consume s Token.Right_paren "Expected ')' after arguments.");
          Ast.P_tuple items
        | Token.Left_brace when not s.no_brace ->
          ignore (advance s);
          Ast.P_fields (record_fields s)
        | _ -> Ast.P_none
      in
      Ast.at sp (`New_variant (name, variant, payload)))
    else (
      let type_args = type_arguments s in
      match matches s [ Token.Left_paren ] with
      | Some _ -> Ast.at sp (`New_call (name, type_args, arguments s))
      | None ->
        ignore (consume s Token.Left_brace "Expected '{' after type name.");
        Ast.at sp (`New (name, record_fields s)))
  | Token.Left_brace when not s.no_brace ->
    ignore (advance s);
    Ast.at sp (`Record_lit (record_fields s))
  | Token.Left_bracket ->
    ignore (advance s);
    let items = listed_until s Token.Right_bracket expression in
    ignore (consume s Token.Right_bracket "Expected ']' after collection items.");
    Ast.at sp (`Collection_lit items)
  | Token.Left_paren when starts_lambda s -> lambda s sp
  (* After [starts_lambda], so `() => ...` is still a lambda. *)
  | Token.Left_paren when (peek_at s 1).Token.token_type = Token.Right_paren ->
    ignore (advance s);
    ignore (advance s);
    Ast.at sp `Unit
  | Token.Left_paren ->
    ignore (advance s);
    let saved = s.no_brace in
    s.no_brace <- false;
    let first = expression s in
    s.no_brace <- saved;
    (* A comma is what makes it a tuple; otherwise no node survives the parens. *)
    if check s Token.Comma
    then (
      let rec rest () =
        match matches s [ Token.Comma ] with
        | Some _ when not (check s Token.Right_paren) ->
          let item = expression s in
          item :: rest ()
        | _ -> []
      in
      let items = first :: rest () in
      ignore (consume s Token.Right_paren "Expected ')' after tuple.");
      Ast.at sp (`Tuple items))
    else (
      ignore (consume s Token.Right_paren "Expected ')' after expression.");
      first)
  | _ -> raise (error s tok "Expected an expression.")

(* ---- statements ---- *)

(* A `meta fn` and a `derive` are read by the metaprocessor before anything
   records an attribute, and an `import` names nothing to hang one on. *)
and attachable (s : Ast.stmt) =
  match s.Ast.it with
  | `Fn _ | `Type_decl _ | `Trait_decl _ | `Impl_decl _ | `Effect_decl _
  | `Handler_decl _ | `Var_decl _ -> true
  | _ -> false

and declaration s : Ast.stmt option =
  try
    let tok = peek s in
    let sp = Ast.span_of_token tok in
    match tok.Token.token_type with
    | Token.Fn ->
      ignore (advance s);
      Some (fn_decl s sp)
    | Token.Var ->
      ignore (advance s);
      Some (var_decl s sp)
    | Token.Effect ->
      ignore (advance s);
      Some (effect_decl s sp)
    | Token.Handler ->
      ignore (advance s);
      Some (handler_decl s sp)
    | Token.Type ->
      ignore (advance s);
      Some (type_decl s sp)
    | Token.At ->
      let list = attributes s in
      (match declaration s with
       | None -> None
       | Some inner ->
         if not (attachable inner)
         then raise (error s tok "An attribute belongs to a declaration.");
         Some (Ast.at sp (`Attributed (list, inner))))
    | Token.Trait ->
      ignore (advance s);
      Some (trait_decl s sp)
    | Token.Impl ->
      ignore (advance s);
      Some (impl_decl s sp)
    | Token.Import ->
      ignore (advance s);
      Some (import_decl s sp)
    | Token.Defer ->
      ignore (advance s);
      (match declaration s with
       | Some inner -> Some (Ast.at sp (`Defer inner))
       | None -> None)
    | Token.Derive ->
      ignore (advance s);
      let traits =
        comma_separated ~ends:(Token.For, "for") s (fun s ->
          consume_identifier s "Expected a trait name.")
      in
      ignore (consume s Token.For "Expected 'for' after the traits to derive.");
      let target = consume_identifier s "Expected the type to derive for." in
      ignore (consume s Token.Semicolon "Expected ';' after a derive.");
      Some (Ast.at sp (`Derive (traits, target)))
    | Token.Meta ->
      ignore (advance s);
      (* Braces are a block of statements, not part of the form: `meta` runs
         whatever follows it, one statement or many. *)
      if check s Token.Fn
      then (
        ignore (advance s);
        (* Registration is by `for Trait`, so every deriver is free to be
           called `derive` — a keyword, hence read here. *)
        let read_name s =
          match matches s [ Token.Derive ] with
          | Some _ -> "derive"
          | None -> consume_identifier s "Expected function name."
        in
        let before_body s name =
          match matches s [ Token.For ] with
          | None -> name
          | Some _ ->
            Ast.deriver_name (consume_identifier s "Expected a trait name after 'for'.")
        in
        match (fn_decl ~read_name ~before_body s sp).Ast.it with
        | `Fn (name, params, signature, body) ->
          Some (Ast.at sp (`Meta_fn (name, params, signature, body)))
        | _ -> None)
      else if check s Token.Left_brace
      then (
        ignore (advance s);
        Some (Ast.at sp (`Meta (block s))))
      else (
        match declaration s with
        | Some inner -> Some (Ast.at sp (`Meta [ inner ]))
        | None -> None)
    | Token.Gen ->
      ignore (advance s);
      (match declaration s with
       | Some inner -> Some (Ast.at sp (`Gen inner))
       | None -> None)
    | _ -> Some (statement s)
  with
  | Parse_error ->
    synchronize s;
    None

and type_arguments s : Ast.type_expr list =
  match matches s [ Token.Less ] with
  | None -> []
  | Some _ ->
    let args = listed_until s Token.Greater type_argument in
    ignore (consume s Token.Greater "Expected '>' after type arguments.");
    args

(* [packs] are the names the enclosing `<>` declared as packs, so `...Args`
   collects into the tuple the pack stands for while `...int` collects into an
   array. *)
and parameters ?(packs = []) s : Ast.param list =
  (* Each is kept with the token it started at, so a parameter that should not
     be there is reported where it stands. *)
  let parameter s =
    let starts = peek s in
    let name = consume_identifier s "Expected parameter name." in
    let ty =
      match matches s [ Token.Colon ] with
      | None -> None
      | Some _ ->
        let sp = Ast.span_of_token (peek s) in
        (match matches s [ Token.Dot_dot_dot ] with
         | None -> Some (type_expr s)
         | Some _ ->
           let inner = type_expr s in
           (match inner.Ast.it with
            | Ast.Ty_name name when List.mem name packs ->
              Some (Ast.at sp (Ast.Ty_variadic (Ast.at sp (Ast.Ty_spread inner))))
            | _ -> Some (Ast.at sp (Ast.Ty_variadic inner))))
    in
    { Ast.name; ty; implicit = false }, starts
  in
  let params = listed_until s Token.Right_paren parameter in
  let rec check_last = function
    | ((p : Ast.param), _) :: (((_, after) :: _) as rest) ->
      (* Anything after a variadic has no boundary to be collected up to. *)
      (match p.Ast.ty with
       | Some { Ast.it = Ast.Ty_variadic _; _ } ->
         ignore (error s after "A variadic parameter must be the last one.")
       | _ -> ());
      check_last rest
    | _ -> ()
  in
  check_last params;
  ignore (consume s Token.Right_paren "Expected ')' after parameters.");
  List.map fst params

and fn_decl
  ?(read_name =
    fun s ->
      (* In declaration position `new` cannot be read as the operator. No
         other keyword is allowed here. *)
      match matches s [ Token.New ] with
      | Some _ -> "new"
      | None -> consume_identifier s "Expected function name.")
  ?(before_body = fun _ name -> name)
  s
  sp
  : Ast.stmt
  =
  let name = read_name s in
  let comptime = comptime_params s in
  ignore (consume s Token.Left_paren "Expected '(' after function name.");
  let params = parameters ~packs:(pack_names comptime) s in
  let signature = signature ~comptime s in
  let name = before_body s name in
  ignore (consume s Token.Left_brace "Expected '{' before function body.");
  Ast.at sp (`Fn (name, params, signature, block s))

and var_decl s sp : Ast.stmt =
  if check s Token.Left_paren
  then (
    let names = binder s "Expected variable name." in
    ignore (consume s Token.Equal "A destructuring 'var' must be initialized.");
    let init = expression s in
    ignore (consume s Token.Semicolon "Expected ';' after variable declaration.");
    Ast.at sp (`Var_tuple (names, init)))
  else (
  let name = consume_identifier s "Expected variable name." in
  let ty = type_annotation s in
  let init =
    match matches s [ Token.Equal ] with
    | Some _ -> Some (expression s)
    | None -> None
  in
  ignore (consume s Token.Semicolon "Expected ';' after variable declaration.");
  Ast.at sp (`Var_decl (name, ty, init)))

(* `(a, b)` takes a tuple apart where a name would stand. Only names inside:
   a binder has to bind, so a nested pattern that could fail to match is not
   one — `Some(x)` belongs in a `match`. *)
and binder s message : Ast.binder =
  match matches s [ Token.Left_paren ] with
  | None -> [ consume_identifier s message ]
  | Some _ ->
    let names =
      comma_separated ~closer:Token.Right_paren s (fun s -> consume_identifier s message)
    in
    ignore (consume s Token.Right_paren "Expected ')' after the names.");
    if List.length names < 2
    then raise (error s (peek s) "A destructuring binder takes two names or more.");
    names

(* `(a, b) in` rather than a parenthesised expression. *)
and binder_ahead s =
  let rec look at =
    match (peek_at s at).Token.token_type with
    | Token.Identifier _ ->
      (match (peek_at s (at + 1)).Token.token_type with
       | Token.Comma -> look (at + 2)
       | Token.Right_paren ->
         (match (peek_at s (at + 2)).Token.token_type with
          | Token.Identifier "in" -> true
          | _ -> false)
       | _ -> false)
    | _ -> false
  in
  look 1

(* Assumes the '{' has been consumed; consumes the closing '}'. *)
and block s : Ast.stmt list =
  let rec loop acc =
    if check s Token.Right_brace || is_at_end s
    then List.rev acc
    else (
      match declaration s with
      | Some st -> loop (st :: acc)
      | None -> loop acc)
  in
  let body = loop [] in
  ignore (consume s Token.Right_brace "Expected '}' after block.");
  body

and statement s : Ast.stmt =
  let tok = peek s in
  let sp = Ast.span_of_token tok in
  match tok.Token.token_type with
  | Token.For ->
    ignore (advance s);
    for_stmt s sp
  | Token.If ->
    ignore (advance s);
    if_stmt s sp
  | Token.While ->
    ignore (advance s);
    while_stmt s sp
  | Token.Return ->
    ignore (advance s);
    return_stmt s sp
  | Token.Run ->
    ignore (advance s);
    run_stmt s sp
  | Token.Match ->
    ignore (advance s);
    match_stmt s sp
  | Token.Resume ->
    ignore (advance s);
    resume_stmt s sp
  | Token.Left_brace ->
    ignore (advance s);
    Ast.at sp (`Block (block s))
  | _ -> expr_stmt s sp

and expr_stmt s sp : Ast.stmt =
  let e = expression s in
  ignore (consume s Token.Semicolon "Expected ';' after expression.");
  Ast.at sp (`Expr e)

and if_stmt s sp : Ast.stmt =
  ignore (consume s Token.Left_paren "Expected '(' after 'if'.");
  let cond = expression s in
  ignore (consume s Token.Right_paren "Expected ')' after if condition.");
  let then_branch = statement s in
  let else_branch =
    match matches s [ Token.Else ] with
    | Some _ -> Some (statement s)
    | None -> None
  in
  Ast.at sp (`If (cond, then_branch, else_branch))

and while_stmt s sp : Ast.stmt =
  ignore (consume s Token.Left_paren "Expected '(' after 'while'.");
  let cond = expression s in
  ignore (consume s Token.Right_paren "Expected ')' after while condition.");
  Ast.at sp (`While (cond, statement s))

and for_stmt s sp : Ast.stmt =
  ignore (consume s Token.Left_paren "Expected '(' after 'for'.");
  (* `in` is not a keyword, so the two forms are told apart by lookahead. *)
  let iterates =
    s.current + 1 < Array.length s.tokens
    &&
    match (peek s).Token.token_type, s.tokens.(s.current + 1).Token.token_type with
    | Token.Identifier _, Token.Identifier "in" -> true
    | Token.Left_paren, Token.Identifier _ -> binder_ahead s
    | _ -> false
  in
  if iterates
  then (
    let name = binder s "Expected a loop variable." in
    ignore (advance s);
    let iterable = expression s in
    ignore (consume s Token.Right_paren "Expected ')' after the iterable.");
    Ast.at sp (`For_in (name, iterable, statement s)))
  else (
  let init =
    let tok = peek s in
    match tok.Token.token_type with
    | Token.Semicolon ->
      ignore (advance s);
      None
    | Token.Var ->
      ignore (advance s);
      Some (var_decl s (Ast.span_of_token tok))
    | _ -> Some (expr_stmt s (Ast.span_of_token tok))
  in
  let cond = if check s Token.Semicolon then None else Some (expression s) in
  ignore (consume s Token.Semicolon "Expected ';' after loop condition.");
  let step = if check s Token.Right_paren then None else Some (expression s) in
  ignore (consume s Token.Right_paren "Expected ')' after for clauses.");
  Ast.at sp (`For (init, cond, step, statement s)))

(* Matched by text, so neither becomes a word a program cannot use. *)
and import_decl s sp : Ast.stmt =
  let text tok =
    match tok.Token.token_type with
    | Token.String path -> path
    | _ -> raise (error s tok "Expected a quoted path.")
  in
  let decl =
    if check s Token.Left_brace
    then (
      ignore (advance s);
      let names =
        comma_separated ~closer:Token.Right_brace s (fun s ->
          consume_identifier s "Expected an imported name.")
      in
      ignore (consume s Token.Right_brace "Expected '}' after the imported names.");
      (match (peek s).Token.token_type with
       | Token.Identifier "from" -> ignore (advance s)
       | _ -> raise (error s (peek s) "Expected 'from' after the imported names."));
      Ast.Selective (names, text (advance s)))
    else (
      let path = text (advance s) in
      match (peek s).Token.token_type with
      | Token.Identifier "as" ->
        ignore (advance s);
        Ast.Aliased (path, consume_identifier s "Expected a name after 'as'.")
      | _ ->
        (match String.length path >= 2 && String.sub path (String.length path - 2) 2 = "/*" with
         | true -> Ast.Wildcard (String.sub path 0 (String.length path - 2))
         | false -> Ast.Qualified path))
  in
  ignore (matches s [ Token.Semicolon ]);
  Ast.at sp (`Import decl)

and op_kind s : Ast.op_kind =
  match (peek s).Token.token_type with
  | Token.Fn ->
    ignore (advance s);
    Ast.Op_fn
  | Token.Ctl ->
    ignore (advance s);
    Ast.Op_ctl
  | Token.Final ->
    ignore (advance s);
    ignore (consume s Token.Ctl "Expected 'ctl' after 'final'.");
    Ast.Op_final
  | _ -> raise (error s (peek s) "Expected 'fn', 'ctl' or 'final ctl'.")

and effect_decl s sp : Ast.stmt =
  let name = consume_identifier s "Expected effect name." in
  let params = type_params s in
  ignore (consume s Token.Left_brace "Expected '{' after effect name.");
  let rec loop acc =
    if check s Token.Right_brace || is_at_end s
    then List.rev acc
    else (
      let kind = op_kind s in
      let op_name = consume_identifier s "Expected operation name." in
      let op_tparams = type_params s in
      ignore (consume s Token.Left_paren "Expected '(' after operation name.");
      let params =
        listed_until s Token.Right_paren (fun s ->
          let name = consume_identifier s "Expected parameter name." in
          { Ast.name; ty = type_annotation s; implicit = false })
      in
      ignore (consume s Token.Right_paren "Expected ')' after parameters.");
      let op_ret =
        match matches s [ Token.Colon ] with
        | Some _ -> Some (type_expr s)
        | None -> None
      in
      ignore (consume s Token.Semicolon "Expected ';' after operation.");
      loop ({ Ast.op_name; op_kind = kind; op_tparams; op_params = params; op_ret } :: acc))
  in
  let ops = loop [] in
  ignore (consume s Token.Right_brace "Expected '}' after effect operations.");
  Ast.at sp (`Effect_decl (name, params, ops))

and trait_decl s sp : Ast.stmt =
  let name = consume_identifier s "Expected a trait name." in
  let params = type_params s in
  let supers =
    match matches s [ Token.Colon ] with
    | None -> []
    | Some _ ->
      let rec loop acc =
        let super = consume_identifier s "Expected a trait name after ':'." in
        let acc = (super, type_arguments s) :: acc in
        match matches s [ Token.Comma ] with
        | Some _ -> loop acc
        | None -> List.rev acc
      in
      loop []
  in
  ignore (consume s Token.Left_brace "Expected '{' after the trait name.");
  let rec loop assoc acc =
    if check s Token.Right_brace || is_at_end s
    then List.rev assoc, List.rev acc
    else if check s Token.Type
    then (
      ignore (advance s);
      let bound = consume_identifier s "Expected an associated type name." in
      ignore (consume s Token.Semicolon "Expected ';' after an associated type.");
      loop (bound :: assoc) acc)
    else (
      ignore (consume s Token.Fn "Expected a method signature.");
      let method_name = consume_identifier s "Expected a method name." in
      let comptime = comptime_params s in
      ignore (consume s Token.Left_paren "Expected '(' after the method name.");
      let params = parameters ~packs:(pack_names comptime) s in
      let signature = signature ~comptime s in
      ignore (consume s Token.Semicolon "Expected ';' after a method signature.");
      loop
        assoc
        ({ Ast.ms_name = method_name; ms_params = params; ms_signature = signature }
         :: acc))
  in
  let assoc, methods = loop [] [] in
  ignore (consume s Token.Right_brace "Expected '}' after the trait body.");
  Ast.at
    sp
    (`Trait_decl
      (name, params, { Ast.tb_super = supers; tb_assoc = assoc; tb_methods = methods }))

and impl_decl s sp : Ast.stmt =
  let first = consume_identifier s "Expected a type or trait name after 'impl'." in
  (* What follows the first name is the trait's arguments when a `for` comes
     after it, and the type's own parameters otherwise. *)
  let written = type_arguments s in
  let trait, type_name, params =
    match matches s [ Token.For ] with
    | Some _ ->
      let name = consume_identifier s "Expected a type name after 'for'." in
      Some (first, written), name, type_params s
    | None ->
      ( None
      , first
      , List.map
          (fun (t : Ast.type_expr) ->
            match t.Ast.it with
            | Ast.Ty_name n -> n
            | _ -> ignore (error s (peek s) "Expected a type parameter name."); "")
          written )
  in
  ignore (consume s Token.Left_brace "Expected '{' after the impl header.");
  let rec loop assoc acc =
    if check s Token.Right_brace || is_at_end s
    then List.rev assoc, List.rev acc
    else if check s Token.Type
    then (
      ignore (advance s);
      let bound = consume_identifier s "Expected an associated type name." in
      ignore (consume s Token.Equal "Expected '=' after an associated type name.");
      let value = type_expr s in
      ignore (consume s Token.Semicolon "Expected ';' after an associated type.");
      loop ((bound, value) :: assoc) acc)
    else (
      ignore (consume s Token.Fn "Expected a method.");
      let method_name = consume_identifier s "Expected a method name." in
      let comptime = comptime_params s in
      ignore (consume s Token.Left_paren "Expected '(' after the method name.");
      let params = parameters ~packs:(pack_names comptime) s in
      let signature = signature ~comptime s in
      ignore (consume s Token.Left_brace "Expected '{' before the method body.");
      loop
        assoc
        ({ Ast.md_name = method_name
         ; md_params = params
         ; md_signature = signature
         ; md_body = block s
         ; md_ann = ()
         }
         :: acc))
  in
  let assoc, methods = loop [] [] in
  ignore (consume s Token.Right_brace "Expected '}' after the methods.");
  Ast.at sp (`Impl_decl (trait, type_name, params, { Ast.ib_assoc = assoc; ib_methods = methods }))

(* Arguments are literals rather than expressions: an attribute is data a
   deriver reads, so there is nothing to evaluate and no stage that could. *)
and attributes s =
  let rec loop acc =
    match matches s [ Token.At ] with
    | None -> List.rev acc
    | Some at ->
      let sp = Ast.span_of_token at in
      let name = consume_identifier s "Expected an attribute name." in
      let args =
        match matches s [ Token.Left_paren ] with
        | None -> []
        | Some _ ->
          let args =
            if check s Token.Right_paren
            then []
            else comma_separated ~closer:Token.Right_paren s attribute_arg
          in
          ignore (consume s Token.Right_paren "Expected ')' after attribute arguments.");
          args
      in
      loop ({ Ast.a_name = name; a_args = args; a_span = sp } :: acc)
  in
  loop []

and attribute_arg s =
  let tok = peek s in
  match tok.Token.token_type with
  | Token.String text ->
    ignore (advance s);
    Ast.A_str text
  | Token.Int value ->
    ignore (advance s);
    Ast.A_int value
  | Token.Float value ->
    ignore (advance s);
    Ast.A_float value
  | Token.True ->
    ignore (advance s);
    Ast.A_bool true
  | Token.False ->
    ignore (advance s);
    Ast.A_bool false
  | Token.Minus ->
    ignore (advance s);
    let tok = peek s in
    (match tok.Token.token_type with
     | Token.Int value ->
       ignore (advance s);
       Ast.A_int (-value)
     | Token.Float value ->
       ignore (advance s);
       Ast.A_float (-.value)
     | _ -> raise (error s tok "An attribute argument must be a literal."))
  | _ -> raise (error s tok "An attribute argument must be a literal.")

and type_decl s sp : Ast.stmt =
  let name = consume_identifier s "Expected a type name." in
  let params = declared_type_params s in
  ignore (consume s Token.Left_brace "Expected '{' after type name.");
  let rec loop fields variants =
    if check s Token.Right_brace || is_at_end s
    then List.rev fields, List.rev variants
    else (
      let attrs = attributes s in
      let label = consume_identifier s "Expected a field or variant name." in
      match (peek s).Token.token_type with
      | Token.Colon ->
        if variants <> []
        then ignore (error s (peek s) "A type declares fields or variants, not both.");
        ignore (advance s);
        let ty = type_expr s in
        ignore (matches s [ Token.Comma ]);
        loop ({ Ast.f_name = label; f_ty = ty; f_attrs = attrs } :: fields) variants
      | _ ->
        if fields <> []
        then ignore (error s (peek s) "A type declares fields or variants, not both.");
        let variant_params = type_params s in
        let payload =
          match (peek s).Token.token_type with
          | Token.Left_paren ->
            ignore (advance s);
            let items = comma_separated ~closer:Token.Right_paren s type_expr in
            ignore (consume s Token.Right_paren "Expected ')' after variant payload.");
            Ast.P_tuple items
          | Token.Left_brace ->
            ignore (advance s);
            let rec named acc =
              if check s Token.Right_brace
              then List.rev acc
              else (
                let l = consume_identifier s "Expected a field name." in
                ignore (consume s Token.Colon "Expected ':' after field name.");
                let t = type_expr s in
                ignore (matches s [ Token.Comma ]);
                named ((l, t) :: acc))
            in
            let fields = named [] in
            ignore (consume s Token.Right_brace "Expected '}' after variant fields.");
            Ast.P_fields fields
          | _ -> Ast.P_none
        in
        (* `-> Expr<int>` says what this constructor builds, rather than the
           type applied to its own parameters. *)
        let result =
          match matches s [ Token.Arrow ] with
          | Some _ -> Some (type_expr s)
          | None -> None
        in
        ignore (matches s [ Token.Comma ]);
        loop
          fields
          ({ Ast.v_name = label
           ; v_params = variant_params
           ; v_payload = payload
           ; v_result = result
           ; v_attrs = attrs
           }
           :: variants))
  in
  let fields, variants = loop [] [] in
  ignore (consume s Token.Right_brace "Expected '}' after type body.");
  let body = if variants <> [] then Ast.T_variants variants else Ast.T_fields fields in
  Ast.at sp (`Type_decl (name, params, body))

and handler_decl s sp : Ast.stmt =
  let name = consume_identifier s "Expected handler name." in
  ignore (consume s Token.Colon "Expected ':' after handler name.");
  Ast.at sp (`Handler_decl (name, handler s))

and handler s : Ast.stmt Ast.handler =
  let handled = consume_identifier s "Expected an effect name." in
  ignore (consume s Token.Left_brace "Expected '{' after effect name.");
  let rec loop acc =
    if check s Token.Right_brace || is_at_end s
    then List.rev acc
    else (
      let kind = op_kind s in
      let arm_name = consume_identifier s "Expected operation name." in
      ignore (consume s Token.Left_paren "Expected '(' after operation name.");
      (* Types come from the declaration, so an annotation here is dropped. *)
      let params =
        listed_until s Token.Right_paren (fun s ->
          let name = consume_identifier s "Expected parameter name." in
          ignore (type_annotation s);
          name)
      in
      ignore (consume s Token.Right_paren "Expected ')' after parameters.");
      ignore (consume s Token.Left_brace "Expected '{' before operation body.");
      loop
        ({ Ast.arm_name; arm_kind = kind; arm_params = params; arm_body = block s } :: acc))
  in
  let arms = loop [] in
  ignore (consume s Token.Right_brace "Expected '}' after handler.");
  { Ast.handled; arms }

and handler_clauses s : Ast.stmt Ast.handler_clause list =
  let rec loop acc =
    match (peek s).Token.token_type with
    | Token.Handle ->
      ignore (advance s);
      loop (Ast.Inline (handler s) :: acc)
    | Token.With ->
      ignore (advance s);
      loop (Ast.Named (consume_identifier s "Expected a handler name.") :: acc)
    | _ -> List.rev acc
  in
  let handlers = loop [] in
  if handlers = []
  then ignore (error s (peek s) "Expected 'handle' or 'with' after a run block.");
  handlers

(* The same construct as one standing where a value is wanted, so an arm's
   `return` means the same thing here; nothing reads the answer. *)
and run_stmt s sp : Ast.stmt =
  let it = run_expr s sp in
  (* `with` takes a terminator; `handle` closes with its own brace. *)
  ignore (matches s [ Token.Semicolon ]);
  Ast.at sp (`Expr it)

(* The opening brace is already consumed. *)
and valued_block s : (Ast.expr, Ast.stmt) Ast.valued_block =
  let mark = s.current
  and errors = s.errors in
  let restore () =
    s.current <- mark;
    s.errors <- errors;
    { Ast.vb_stmts = block s; vb_value = None }
  in
  match expression s with
  | value when check s Token.Right_brace ->
    ignore (advance s);
    { Ast.vb_stmts = []; vb_value = Some value }
  | _ -> restore ()
  | exception Parse_error -> restore ()

and run_expr s sp : Ast.expr =
  ignore (consume s Token.Left_brace "Expected '{' after 'run'.");
  let body = valued_block s in
  let handlers = handler_clauses s in
  (* The whole shape, or a `return` statement on the next line is eaten. *)
  let is_clause =
    check s Token.Return
    && (peek_at s 1).Token.token_type = Token.Left_paren
    && (match (peek_at s 2).Token.token_type with
        | Token.Identifier _ -> true
        | _ -> false)
    && (peek_at s 3).Token.token_type = Token.Right_paren
    && (peek_at s 4).Token.token_type = Token.Left_brace
  in
  let clause =
    if not is_clause
    then None
    else (
      ignore (advance s);
      ignore (advance s);
      let param = consume_identifier s "Expected a name for the block's value." in
      ignore (advance s);
      ignore (advance s);
      Some { Ast.rc_param = param; rc_body = valued_block s })
  in
  Ast.at sp (`Run_expr (body, handlers, clause))

and resume_stmt s sp : Ast.stmt =
  let value = if check s Token.Semicolon then None else Some (expression s) in
  ignore (consume s Token.Semicolon "Expected ';' after resume.");
  Ast.at sp (`Resume value)

and match_stmt s sp : Ast.stmt =
  let saved = s.no_brace in
  s.no_brace <- true;
  let scrutinee = expression s in
  s.no_brace <- saved;
  ignore (consume s Token.Left_brace "Expected '{' after the matched value.");
  let rec loop acc =
    if check s Token.Right_brace || is_at_end s
    then List.rev acc
    else (
      let pattern =
        match (peek s).Token.token_type with
        | Token.Identifier "_" ->
          ignore (advance s);
          Ast.Pat_wild
        | _ ->
          let ty = consume_identifier s "Expected a pattern." in
          ignore (consume s Token.Colon_colon "Expected '::' after the type name.");
          let variant = consume_identifier s "Expected a variant name." in
          let payload =
            match (peek s).Token.token_type with
            | Token.Left_paren ->
              ignore (advance s);
              let items =
                comma_separated ~closer:Token.Right_paren s (fun s ->
                  consume_identifier s "Expected a binding name.")
              in
              ignore (consume s Token.Right_paren "Expected ')' after bindings.");
              Ast.P_tuple items
            | Token.Left_brace ->
              ignore (advance s);
              let rec named acc =
                if check s Token.Right_brace
                then List.rev acc
                else (
                  let n = consume_identifier s "Expected a field name." in
                  ignore (matches s [ Token.Comma ]);
                  named ((n, n) :: acc))
              in
              let fields = named [] in
              ignore (consume s Token.Right_brace "Expected '}' after bindings.");
              Ast.P_fields fields
            | _ -> Ast.P_none
          in
          Ast.Pat_variant (ty, variant, payload)
      in
      ignore (consume s Token.Fat_arrow "Expected '=>' after a pattern.");
      ignore (consume s Token.Left_brace "Expected '{' after '=>'.");
      loop ((pattern, block s) :: acc))
  in
  let cases = loop [] in
  ignore (consume s Token.Right_brace "Expected '}' after match cases.");
  Ast.at sp (`Match (scrutinee, cases))

and return_stmt s sp : Ast.stmt =
  let value = if check s Token.Semicolon then None else Some (expression s) in
  ignore (consume s Token.Semicolon "Expected ';' after return value.");
  Ast.at sp (`Return value)

let parse (tokens : Token.token list) : (Ast.program, error list) result =
  let s = { tokens = Array.of_list tokens; current = 0; errors = []; no_brace = false } in
  let rec loop acc =
    if is_at_end s
    then List.rev acc
    else (
      match declaration s with
      | Some st -> loop (st :: acc)
      | None -> loop acc)
  in
  let program = loop [] in
  match s.errors with
  | [] -> Ok program
  | errors -> Error (List.rev errors)
