type token_type =
  (* Single-character tokens. *)
  | Left_paren
  | Right_paren
  | Left_brace
  | Right_brace
  | Left_bracket
  | Right_bracket
  | Comma
  | Minus
  | Plus
  | Semicolon
  | Slash
  | Percent
  | Dot_dot_dot
  | Amp_amp
  | Pipe_pipe
  | Amp
  | Pipe
  | Caret
  | Tilde
  | Star
  | Colon
  | Dot
  | At
    (* One or two character tokens. *)
  | Bang
  | Bang_equal
  | Equal
  | Equal_equal
  | Greater
  | Greater_equal
  | Less
  | Less_equal
  | Plus_plus
  | Minus_minus
  | Plus_equal
  | Minus_equal
  | Star_equal
  | Slash_equal
  | Percent_equal
  | Arrow
  | Fat_arrow
  (* Literals. *)
  | Identifier of string
  | String of string
  | Char of Uchar.t
  | Int of int
  | Float of float
  (* The one comment that reaches the parser. *)
  (* The text, and whether a blank line follows it -- which is what tells a doc
     comment about the module from one about the declaration below it. *)
  | Doc of string * bool
  (* Keywords. *)
  | Ctl
  | Final
  | Effect
  | Else
  | False
  | Fn
  | For
  | If
  | Impl
  | Import
  | Meta
  | Gen
  | Code
  | Derive
  | Defer
  | Handle
  | Handler
  | Resume
  | Discontinue
  | Return
  | Break
  | Continue
  | Run
  | Match
  | True
  | Trait
  | Type
  | Typeof
  | With
  | Var
  | While
  | Eof

type token =
  { token_type : token_type
  ; lexeme : string
  ; span : Source_map.Span.t
  }

let make token_type ~lexeme ~span = { token_type; lexeme; span }

let token_type_to_string = function
  | Left_paren -> "LEFT_PAREN"
  | Right_paren -> "RIGHT_PAREN"
  | Left_brace -> "LEFT_BRACE"
  | Right_brace -> "RIGHT_BRACE"
  | Left_bracket -> "LEFT_BRACKET"
  | Right_bracket -> "RIGHT_BRACKET"
  | Comma -> "COMMA"
  | Minus -> "MINUS"
  | Plus -> "PLUS"
  | Semicolon -> "SEMICOLON"
  | Slash -> "SLASH"
  | Percent -> "PERCENT"
  | At -> "AT"
  | Dot_dot_dot -> "DOT_DOT_DOT"
  | Amp_amp -> "AMP_AMP"
  | Pipe_pipe -> "PIPE_PIPE"
  | Amp -> "AMP"
  | Pipe -> "PIPE"
  | Caret -> "CARET"
  | Tilde -> "TILDE"
  | Star -> "STAR"
  | Colon -> "COLON"
  | Dot -> "DOT"
  | Bang -> "BANG"
  | Bang_equal -> "BANG_EQUAL"
  | Equal -> "EQUAL"
  | Equal_equal -> "EQUAL_EQUAL"
  | Greater -> "GREATER"
  | Greater_equal -> "GREATER_EQUAL"
  | Less -> "LESS"
  | Less_equal -> "LESS_EQUAL"
  | Plus_plus -> "PLUS_PLUS"
  | Minus_minus -> "MINUS_MINUS"
  | Plus_equal -> "PLUS_EQUAL"
  | Minus_equal -> "MINUS_EQUAL"
  | Star_equal -> "STAR_EQUAL"
  | Slash_equal -> "SLASH_EQUAL"
  | Percent_equal -> "PERCENT_EQUAL"
  | Arrow -> "ARROW"
  | Fat_arrow -> "FAT_ARROW"
  | Identifier _ -> "IDENTIFIER"
  | String _ -> "STRING"
  | Char _ -> "CHAR"
  | Int _ -> "INT"
  | Float _ -> "FLOAT"
  | Doc _ -> "DOC"
  | Ctl -> "CTL"
  | Final -> "FINAL"
  | Effect -> "EFFECT"
  | Else -> "ELSE"
  | False -> "FALSE"
  | Fn -> "FN"
  | For -> "FOR"
  | If -> "IF"
  | Impl -> "IMPL"
  | Import -> "IMPORT"
  | Meta -> "META"
  | Gen -> "GEN"
  | Code -> "CODE"
  | Derive -> "DERIVE"
  | Defer -> "DEFER"
  | Handle -> "HANDLE"
  | Handler -> "HANDLER"
  | Resume -> "RESUME"
  | Discontinue -> "DISCONTINUE"
  | Return -> "RETURN"
  | Break -> "BREAK"
  | Continue -> "CONTINUE"
  | Run -> "RUN"
  | Match -> "MATCH"
  | True -> "TRUE"
  | Trait -> "TRAIT"
  | Type -> "TYPE"
  | Typeof -> "TYPEOF"
  | With -> "WITH"
  | Var -> "VAR"
  | While -> "WHILE"
  | Eof -> "EOF"

(* Floats keep a visible fractional part so they never read as ints. *)
(* The fewest digits that read back as the same float. *)
(* Spelled here rather than by printf, whose NaN carries its sign bit and
   differs between C libraries. *)
let float_to_string n =
  if Float.is_nan n
  then "NaN"
  else if Float.is_finite n |> not
  then if n > 0.0 then "inf" else "-inf"
  else if Float.is_integer n && Float.abs n < 1e16
  then Printf.sprintf "%.1f" n
  else (
    (* The Windows C library writes `1e+016` where the others write `1e+16`. *)
    let two_digit_exponent text =
      match String.index_opt text 'e' with
      | None -> text
      | Some at ->
        let digits = at + 2 in
        let stop = ref digits in
        while String.length text - !stop > 2 && Char.equal text.[!stop] '0' do
          incr stop
        done;
        String.sub text 0 digits ^ String.sub text !stop (String.length text - !stop)
    in
    let rec shortest digits =
      let text = two_digit_exponent (Printf.sprintf "%.*g" digits n) in
      if digits >= 17 || Float.equal (float_of_string text) n then text else shortest (digits + 1)
    in
    shortest 1)

let literal_to_string = function
  | Identifier name -> name
  | String s -> s
  | Char c ->
    let buf = Buffer.create 4 in
    Buffer.add_utf_8_uchar buf c;
    Buffer.contents buf
  | Int n -> string_of_int n
  | Float n -> float_to_string n
  | Doc (text, _) -> String.escaped text
  | _ -> "null"

let to_string { token_type; lexeme; span } =
  let line, col =
    match Source_map.Span.view span with
    | Source_map.Span.Located l -> l.Source_map.Span.line, l.Source_map.Span.col
    | Source_map.Span.Nowhere_in_source -> 1, 1
  in
  Printf.sprintf
    "%d:%d %s %s %s"
    line
    col
    (token_type_to_string token_type)
    lexeme
    (literal_to_string token_type)
