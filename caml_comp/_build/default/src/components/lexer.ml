open Models.Token

let is_digit c = c >= '0' && c <= '9'

let is_alpha c =
  ('a' <= c && c <= 'z') ||
  ('A' <= c && c <= 'Z') ||
  c = '_'

let is_alpha_numeric c =
  is_alpha c || is_digit c

let rec lex_number s i acc =
  if i < String.length s && is_digit s.[i] then
    lex_number s (i+1) (acc ^ String.make 1 s.[i])
  else
    (NUMBER (int_of_string acc), i)

let rec lex_identifier s i acc =
  if i < String.length s && is_alpha_numeric s.[i] then
    lex_identifier s (i+1) (acc ^ String.make 1 s.[i])
  else
    (acc, i)

let tokenize s =
  let len = String.length s in
  let rec loop i tokens =
    if i >= len then
      List.rev (EOF :: tokens)
    else
      match s.[i] with
      | ' ' | '\n' | '\t' -> loop (i+1) tokens
      | '(' -> loop (i+1) (LEFT_PAREN :: tokens)
      | ')' -> loop (i+1) (RIGHT_PAREN :: tokens)
      | '[' -> loop (i+1) (LEFT_BRACE :: tokens)
      | ']' -> loop (i+1) (RIGHT_BRACE :: tokens)
      | ',' -> loop (i+1) (COMMA :: tokens)
      | '.' -> loop (i+1) (DOT :: tokens)
      | '-' -> loop (i+1) (MINUS :: tokens)
      | '+' -> loop (i+1) (PLUS :: tokens)
      | ';' -> loop (i+1) (SEMICOLON :: tokens)
      | '/' -> loop (i+1) (SLASH :: tokens)
      | '*' -> loop (i+1) (STAR :: tokens)
      
      | '!' ->
          if i + 1 < len && s.[i+1] = '='
          then loop (i+2) (BANG_EQUAL :: tokens)
          else loop (i+1) (BANG :: tokens)
      | '=' ->
          if i + 1 < len && s.[i+1] = '='
          then loop (i+2) (EQUAL_EQUAL :: tokens)
          else loop (i+1) (EQUAL :: tokens)
      | '>' ->
          if i + 1 < len && s.[i+1] = '='
          then loop (i+2) (GREATER_EQUAL :: tokens)
          else loop (i+1) (GREATER :: tokens)
      | '<' ->
          if i + 1 < len && s.[i+1] = '='
          then loop (i+2) (LESS_EQUAL :: tokens)
          else loop (i+1) (LESS :: tokens)

      | c when is_digit c ->
          let (tok, j) = lex_number s i "" in
          loop j (tok :: tokens)

      | c when is_alpha c ->
        let (name, j) = lex_identifier s i "" in
        let tok =
          match name with
          | "and"    -> AND
          | "else"   -> ELSE
          | "false"  -> FALSE
          | "func"   -> FUNC
          | "for"    -> FOR
          | "if"     -> IF
          | "or"     -> OR
          | "print"  -> PRINT
          | "return" -> RETURN
          | "true"   -> TRUE
          | "var"    -> VAR
          | "while"  -> WHILE
          | _        -> IDENTIFIER ( name )
        in
        loop j (tok :: tokens)

      | '"' ->
        let rec scan_string j acc =
          if j >= len then failwith "unterminated string"
          else
            match s.[j] with
            | '"' -> (STRING acc, j + 1)
            | c   -> scan_string (j + 1) (acc ^ String.make 1 c)
        in
        let (tok, j) = scan_string (i + 1) "" in
        loop j (tok :: tokens)

      | _ ->
          failwith "unexpected character"
  in
  loop 0 []
