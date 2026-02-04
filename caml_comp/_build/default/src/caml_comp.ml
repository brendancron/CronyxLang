let () =
  let input = read_line () in

  let tokens = Components.Lexer.tokenize input in

  let oc_tokens = open_out "out/tokens.txt" in
  List.iter
    (fun t ->
      output_string oc_tokens (Models.Token.string_of_token t);
      output_char oc_tokens '\n')
    tokens;
  close_out oc_tokens;

  let ast = Components.Parser.parse tokens in

  let oc_ast = open_out "out/ast.txt" in
  let Box e = ast in
  output_string oc_ast (Models.Ast.string_of_expr e);
  close_out oc_ast;

  let result = Components.Eval.eval e in
  Models.Ast.print_result e result
