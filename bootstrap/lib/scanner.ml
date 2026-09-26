type error =
  { span : Source_map.Span.t
  ; message : string
  }

type state =
  { file : Source_map.File.t
  ; source : string
  ; mutable start : int
  ; mutable current : int
  ; mutable tokens : Token.token list (* reversed *)
  ; mutable errors : error list (* reversed *)
  }

let span_here s = Source_map.Span.of_range s.file ~lo:s.start ~hi:s.current

let is_at_end s = s.current >= String.length s.source

let advance s =
  let c = s.source.[s.current] in
  s.current <- s.current + 1;
  c

let peek s = if is_at_end s then '\000' else s.source.[s.current]

let peek_next s =
  if s.current + 1 >= String.length s.source then '\000' else s.source.[s.current + 1]

let matches s expected =
  if is_at_end s || s.source.[s.current] <> expected
  then false
  else (
    s.current <- s.current + 1;
    true)

let lexeme s = String.sub s.source s.start (s.current - s.start)

let add_token s token_type =
  s.tokens
  <- Token.make token_type ~lexeme:(lexeme s) ~span:(span_here s) :: s.tokens

let error s message =
  s.errors <- { span = span_here s; message } :: s.errors
let is_digit c = c >= '0' && c <= '9'
let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_alphanumeric c = is_alpha c || is_digit c

let keyword = function
  | "ctl" -> Some Token.Ctl
  | "final" -> Some Token.Final
  | "effect" -> Some Token.Effect
  | "else" -> Some Token.Else
  | "false" -> Some Token.False
  | "fn" -> Some Token.Fn
  | "for" -> Some Token.For
  | "if" -> Some Token.If
  | "impl" -> Some Token.Impl
  | "import" -> Some Token.Import
  | "gen" -> Some Token.Gen
  | "code" -> Some Token.Code
  | "derive" -> Some Token.Derive
  | "defer" -> Some Token.Defer
  | "meta" -> Some Token.Meta
  | "handle" -> Some Token.Handle
  | "handler" -> Some Token.Handler
  | "match" -> Some Token.Match
  | "resume" -> Some Token.Resume
  | "return" -> Some Token.Return
  | "run" -> Some Token.Run
  | "trait" -> Some Token.Trait
  | "true" -> Some Token.True
  | "type" -> Some Token.Type
  | "typeof" -> Some Token.Typeof
  | "var" -> Some Token.Var
  | "while" -> Some Token.While
  | "with" -> Some Token.With
  | _ -> None

let line_comment s =
  while peek s <> '\n' && not (is_at_end s) do
    ignore (advance s)
  done

(* Anything else after a backslash is a typo more often than an intent. *)
let escaped s =
  if is_at_end s
  then None
  else (
    match advance s with
    | 'n' -> Some '\n'
    | 't' -> Some '\t'
    | 'r' -> Some '\r'
    | '0' -> Some '\000'
    | '\\' -> Some '\\'
    | '"' -> Some '"'
    | '\'' -> Some '\''
    | _ -> None)

(* Reads to the closing [quote] whatever went wrong, so one bad literal costs
   one diagnostic. *)
let quoted s quote =
  let buf = Buffer.create 16 in
  let bad = ref None in
  let rec scan () =
    if is_at_end s
    then bad := Some "Unterminated literal."
    else (
      match advance s with
      | c when c = quote -> ()
      | '\\' ->
        (match escaped s with
         | Some c -> Buffer.add_char buf c
         | None -> if !bad = None then bad := Some "Unknown escape.");
        scan ()
      | c ->
        Buffer.add_char buf c;
        scan ())
  in
  scan ();
  match !bad with
  | Some message -> Error message
  | None -> Ok (Buffer.contents buf)

let char_literal s =
  match quoted s '\'' with
  | Error message -> error s message
  | Ok text ->
    if String.length text = 0
    then error s "A char literal holds exactly one character."
    else (
      let decoded = String.get_utf_8_uchar text 0 in
      if (not (Uchar.utf_decode_is_valid decoded))
         || Uchar.utf_decode_length decoded <> String.length text
      then error s "A char literal holds exactly one character."
      else add_token s (Token.Char (Uchar.utf_decode_uchar decoded)))

let string_literal s =
  match quoted s '"' with
  | Ok text -> add_token s (Token.String text)
  | Error message -> error s message

let number s =
  while is_digit (peek s) do
    ignore (advance s)
  done;
  (* Consume the '.' only if a digit follows: `123.` is not a float, and the
     dot is also what tells int and float literals apart. *)
  let is_float = peek s = '.' && is_digit (peek_next s) in
  if is_float
  then (
    ignore (advance s);
    while is_digit (peek s) do
      ignore (advance s)
    done);
  let text = lexeme s in
  if is_float
  then add_token s (Token.Float (float_of_string text))
  else (
    match int_of_string_opt text with
    | Some n -> add_token s (Token.Int n)
    | None -> error s (Printf.sprintf "Integer literal '%s' is out of range." text))

let identifier s =
  while is_alphanumeric (peek s) do
    ignore (advance s)
  done;
  let text = lexeme s in
  match keyword text with
  | Some token_type -> add_token s token_type
  | None -> add_token s (Token.Identifier text)

let scan_token s =
  match advance s with
  | '(' -> add_token s Token.Left_paren
  | ')' -> add_token s Token.Right_paren
  | '[' -> add_token s Token.Left_bracket
  | ']' -> add_token s Token.Right_bracket
  | '{' -> add_token s Token.Left_brace
  | '}' -> add_token s Token.Right_brace
  | ',' -> add_token s Token.Comma
  | ';' -> add_token s Token.Semicolon
  | ':' -> add_token s Token.Colon
  | '.' ->
    if peek s = '.' && peek_next s = '.'
    then (
      ignore (advance s);
      ignore (advance s);
      add_token s Token.Dot_dot_dot)
    else add_token s Token.Dot
  | '*' -> add_token s (if matches s '=' then Token.Star_equal else Token.Star)
  | '+' ->
    add_token
      s
      (if matches s '+'
       then Token.Plus_plus
       else if matches s '='
       then Token.Plus_equal
       else Token.Plus)
  | '-' ->
    add_token
      s
      (if matches s '-'
       then Token.Minus_minus
       else if matches s '='
       then Token.Minus_equal
       else if matches s '>'
       then Token.Arrow
       else Token.Minus)
  | '!' -> add_token s (if matches s '=' then Token.Bang_equal else Token.Bang)
  | '=' ->
    add_token
      s
      (if matches s '='
       then Token.Equal_equal
       else if matches s '>'
       then Token.Fat_arrow
       else Token.Equal)
  | '<' -> add_token s (if matches s '=' then Token.Less_equal else Token.Less)
  | '>' -> add_token s (if matches s '=' then Token.Greater_equal else Token.Greater)
  | '/' ->
    if matches s '/'
    then line_comment s
    else add_token s (if matches s '=' then Token.Slash_equal else Token.Slash)
  | '%' -> add_token s (if matches s '=' then Token.Percent_equal else Token.Percent)
  | '@' -> add_token s Token.At
  (* A single `&` or `|` is not an operator at all. *)
  | '&' when matches s '&' -> add_token s Token.Amp_amp
  | '|' when matches s '|' -> add_token s Token.Pipe_pipe
  | ' ' | '\r' | '\t' | '\n' -> ()
  | '"' -> string_literal s
  | '\'' -> char_literal s
  | c ->
    if is_digit c
    then number s
    else if is_alpha c
    then identifier s
    else error s (Printf.sprintf "Unexpected character '%c'." c)

let scan_tokens file =
  let s =
    { file
    ; source = Source_map.File.text file
    ; start = 0
    ; current = 0
    ; tokens = []
    ; errors = []
    }
  in
  while not (is_at_end s) do
    s.start <- s.current;
    scan_token s
  done;
  s.start <- s.current;
  let eof = Token.make Token.Eof ~lexeme:"" ~span:(span_here s) in
  match s.errors with
  | [] -> Ok (List.rev (eof :: s.tokens))
  | errors -> Error (List.rev errors)
