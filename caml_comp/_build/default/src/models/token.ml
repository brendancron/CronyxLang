type token =
  
  | LEFT_PAREN
  | RIGHT_PAREN
  | LEFT_BRACE
  | RIGHT_BRACE
  | COMMA
  | DOT
  | MINUS
  | PLUS
  | SEMICOLON
  | SLASH
  | STAR

  | BANG
  | BANG_EQUAL
  | EQUAL
  | EQUAL_EQUAL
  | GREATER
  | GREATER_EQUAL
  | LESS
  | LESS_EQUAL

  | IDENTIFIER of string
  | STRING of string
  | NUMBER of int

  | AND
  | ELSE
  | FALSE
  | FUNC
  | FOR
  | IF
  | OR
  | PRINT
  | RETURN
  | TRUE
  | VAR
  | WHILE

  | EOF

let string_of_token = function
  | LEFT_PAREN      -> "LEFT_PAREN"
  | RIGHT_PAREN     -> "RIGHT_PAREN"
  | LEFT_BRACE      -> "LEFT_BRACE"
  | RIGHT_BRACE     -> "RIGHT_BRACE"
  | COMMA           -> "COMMA"
  | DOT             -> "DOT"
  | MINUS           -> "MINUS"
  | PLUS            -> "PLUS"
  | SEMICOLON       -> "SEMICOLON"
  | SLASH           -> "SLASH"
  | STAR            -> "STAR"

  | BANG            -> "BANG"
  | BANG_EQUAL      -> "BANG_EQUAL"
  | EQUAL           -> "EQUAL"
  | EQUAL_EQUAL     -> "EQUAL_EQUAL"
  | GREATER         -> "GREATER"
  | GREATER_EQUAL   -> "GREATER_EQUAL"
  | LESS            -> "LESS"
  | LESS_EQUAL      -> "LESS_EQUAL"

  | IDENTIFIER s    -> "IDENTIFIER(" ^ s ^ ")"
  | STRING s        -> "STRING(\"" ^ s ^ "\")"
  | NUMBER n        -> "NUMBER(" ^ string_of_int n ^ ")"

  | AND             -> "AND"
  | ELSE            -> "ELSE"
  | FALSE           -> "FALSE"
  | FUNC            -> "FUNC"
  | FOR             -> "FOR"
  | IF              -> "IF"
  | OR              -> "OR"
  | PRINT           -> "PRINT"
  | RETURN          -> "RETURN"
  | TRUE            -> "TRUE"
  | VAR             -> "VAR"
  | WHILE           -> "WHILE"

  | EOF             -> "EOF"
