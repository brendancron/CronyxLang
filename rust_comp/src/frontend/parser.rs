use super::id_provider::*;
use super::meta_ast::*;
use super::token::*;

pub struct ParseCtx {
    pub ast: MetaAst,
    pub id_provider: IdProvider,
}

impl ParseCtx {
    pub fn new() -> Self {
        Self {
            ast: MetaAst::new(),
            id_provider: IdProvider::new(),
        }
    }
}

#[derive(Debug)]
pub enum ParseError {
    UnterminatedString,
    UnexpectedToken {
        found: TokenType,
        expected: TokenType,
        pos: usize,
    },
    UnexpectedEOF {
        expected: TokenType,
        pos: usize,
    },
}

fn peek(tokens: &[Token], pos: usize) -> Option<TokenType> {
    match tokens.get(pos) {
        None => None,
        Some(t) => Some(t.token_type),
    }
}

fn check(tokens: &[Token], pos: usize, expected: TokenType) -> bool {
    match peek(tokens, pos) {
        None => false,
        Some(token_type) => token_type == expected,
    }
}

fn consume<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    expected: TokenType,
) -> Result<&'a Token, ParseError> {
    match tokens.get(*pos) {
        Some(t) if t.token_type == expected => Ok(consume_next(tokens, pos)),
        Some(t) => Err(ParseError::UnexpectedToken {
            found: t.token_type,
            expected,
            pos: *pos,
        }),
        None => Err(ParseError::UnexpectedEOF {
            expected,
            pos: *pos,
        }),
    }
}

fn consume_next<'a>(tokens: &'a [Token], pos: &mut usize) -> &'a Token {
    let tok = tokens
        .get(*pos)
        .expect("internal error: consume_next out of bounds");
    *pos += 1;
    tok
}

fn parse_separated<T>(
    tokens: &[Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
    separator: TokenType,
    terminator: TokenType,
    mut parse_item: impl FnMut(&[Token], &mut usize, &mut ParseCtx) -> Result<T, ParseError>,
) -> Result<Vec<T>, ParseError> {
    let mut items = Vec::new();

    if check(tokens, *pos, terminator) {
        return Ok(items);
    }

    loop {
        let before = *pos;
        items.push(parse_item(tokens, pos, ctx)?);

        if *pos == before {
            panic!("parser made no progress in comma-separated list");
        }

        if check(tokens, *pos, separator) {
            consume(tokens, pos, separator)?;
        } else {
            break;
        }
    }

    Ok(items)
}

fn parse_factor<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    match tokens.get(*pos) {
        Some(tok) => match tok.token_type {
            TokenType::Number => {
                consume_next(tokens, pos);
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Int(tok.expect_int()));
                Ok(id)
            }

            TokenType::String => {
                consume_next(tokens, pos);
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::String(tok.expect_str()));
                Ok(id)
            }

            TokenType::True => {
                consume_next(tokens, pos);
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Bool(true));
                Ok(id)
            }

            TokenType::False => {
                consume_next(tokens, pos);
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Bool(false));
                Ok(id)
            }

            TokenType::LeftParen => {
                consume(tokens, pos, TokenType::LeftParen)?;
                let expr_id = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightParen)?;
                Ok(expr_id)
            }

            TokenType::Typeof => {
                consume(tokens, pos, TokenType::Typeof)?;
                consume(tokens, pos, TokenType::LeftParen)?;
                let ident = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::RightParen)?;
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Typeof(ident));
                Ok(id)
            }

            TokenType::Embed => {
                consume(tokens, pos, TokenType::Embed)?;
                consume(tokens, pos, TokenType::LeftParen)?;
                let file_path = consume(tokens, pos, TokenType::String)?.expect_str();
                consume(tokens, pos, TokenType::RightParen)?;
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Embed(file_path));
                Ok(id)
            }

            TokenType::Identifier => {
                let name = consume_next(tokens, pos).expect_str();

                if check(tokens, *pos, TokenType::LeftParen) {
                    consume(tokens, pos, TokenType::LeftParen)?;
                    let args = parse_separated(
                        tokens,
                        pos,
                        ctx,
                        TokenType::Comma,
                        TokenType::RightParen,
                        parse_expr,
                    )?;
                    consume(tokens, pos, TokenType::RightParen)?;

                    let id = ctx
                        .ast
                        .insert_expr(&mut ctx.id_provider, MetaExpr::Call { callee: name, args });
                    Ok(id)
                } else if check(tokens, *pos, TokenType::LeftBrace) {
                    consume(tokens, pos, TokenType::LeftBrace)?;

                    let fields = parse_separated(
                        tokens,
                        pos,
                        ctx,
                        TokenType::Comma,
                        TokenType::RightBrace,
                        |tokens, pos, ctx| {
                            let field_name =
                                consume(tokens, pos, TokenType::Identifier)?.expect_str();
                            consume(tokens, pos, TokenType::Colon)?;
                            let expr_id = parse_expr(tokens, pos, ctx)?;
                            Ok((field_name, expr_id))
                        },
                    )?;

                    consume(tokens, pos, TokenType::RightBrace)?;

                    let struct_literal = MetaExpr::StructLiteral {
                        type_name: name,
                        fields,
                    };
                    let id = ctx.ast.insert_expr(&mut ctx.id_provider, struct_literal);
                    Ok(id)
                } else {
                    let id = ctx
                        .ast
                        .insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name));
                    Ok(id)
                }
            }

            TokenType::LeftBracket => {
                consume(tokens, pos, TokenType::LeftBracket)?;

                let elems = parse_separated(
                    tokens,
                    pos,
                    ctx,
                    TokenType::Comma,
                    TokenType::RightBracket,
                    parse_expr,
                )?;

                consume(tokens, pos, TokenType::RightBracket)?;

                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::List(elems));
                Ok(id)
            }

            TokenType::LeftBrace => {
                consume(tokens, pos, TokenType::LeftBrace)?;

                let fields = parse_separated(
                    tokens,
                    pos,
                    ctx,
                    TokenType::Comma,
                    TokenType::RightBrace,
                    |tokens, pos, ctx| {
                        let field_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                        consume(tokens, pos, TokenType::Colon)?;
                        let expr_id = parse_expr(tokens, pos, ctx)?;
                        Ok((field_name, expr_id))
                    },
                )?;

                consume(tokens, pos, TokenType::RightBrace)?;

                let id = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::StructLiteral { type_name: String::new(), fields },
                );
                Ok(id)
            }

            _ => panic!("expected literal or '('"),
        },
        None => panic!("Unexpected EOF"),
    }
}

fn parse_term<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    let mut left = parse_factor(tokens, pos, ctx)?;

    loop {
        match tokens.get(*pos) {
            Some(tok) => match tok.token_type {
                TokenType::Star => {
                    *pos += 1;
                    let right = parse_factor(tokens, pos, ctx)?;
                    let node = MetaExpr::Mult(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }
                TokenType::Slash => {
                    *pos += 1;
                    let right = parse_factor(tokens, pos, ctx)?;
                    let node = MetaExpr::Div(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }
                _ => return Ok(left),
            },
            _ => return Ok(left),
        }
    }
}

fn parse_expr<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    let mut left = parse_term(tokens, pos, ctx)?;

    loop {
        match tokens.get(*pos) {
            Some(tok) => match tok.token_type {
                TokenType::Plus => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::Add(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }

                TokenType::Minus => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::Sub(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }

                TokenType::EqualEqual => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::Equals(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }

                _ => return Ok(left),
            },
            _ => return Ok(left),
        }
    }
}

fn parse_expr_stmt<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    let expr = parse_expr(tokens, pos, ctx)?;
    consume(tokens, pos, TokenType::Semicolon)?;
    let id = ctx
        .ast
        .insert_stmt(&mut ctx.id_provider, MetaStmt::ExprStmt(expr));
    Ok(id)
}

fn parse_stmt<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    match tokens.get(*pos) {
        Some(tok) => match tok.token_type {
            TokenType::Print => {
                consume(tokens, pos, TokenType::Print)?;
                consume(tokens, pos, TokenType::LeftParen)?;
                let expr = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightParen)?;
                consume(tokens, pos, TokenType::Semicolon)?;
                let id = ctx
                    .ast
                    .insert_stmt(&mut ctx.id_provider, MetaStmt::Print(expr));
                Ok(id)
            }

            TokenType::If => {
                // TODO parse if func for efficient recursion
                consume(tokens, pos, TokenType::If)?;
                consume(tokens, pos, TokenType::LeftParen)?;
                let conditional = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightParen)?;
                consume(tokens, pos, TokenType::LeftBrace)?;
                let inner = parse_block(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightBrace)?;
                let else_branch = if check(tokens, *pos, TokenType::Else) {
                    consume(tokens, pos, TokenType::Else)?;
                    if check(tokens, *pos, TokenType::If) {
                        Some(parse_stmt(tokens, pos, ctx)?)
                    } else {
                        consume(tokens, pos, TokenType::LeftBrace)?;
                        let stmt = parse_stmt(tokens, pos, ctx)?;
                        consume(tokens, pos, TokenType::RightBrace)?;
                        Some(stmt)
                    }
                } else {
                    None
                };

                let if_stmt = MetaStmt::If {
                    cond: conditional,
                    body: inner,
                    else_branch: else_branch,
                };

                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, if_stmt);
                Ok(id)
            }

            TokenType::For => {
                consume(tokens, pos, TokenType::For)?;
                consume(tokens, pos, TokenType::LeftParen)?;
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::In)?;
                let iter = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightParen)?;
                consume(tokens, pos, TokenType::LeftBrace)?;
                let inner = parse_block(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightBrace)?;
                let for_stmt = MetaStmt::ForEach {
                    var: name,
                    iterable: iter,
                    body: inner,
                };

                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, for_stmt);
                Ok(id)
            }

            TokenType::Var => {
                consume(tokens, pos, TokenType::Var)?;
                let ident = consume(tokens, pos, TokenType::Identifier)?;
                consume(tokens, pos, TokenType::Equal)?;
                let expr = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::Semicolon)?;
                let var_decl = MetaStmt::VarDecl {
                    name: ident.expect_str(),
                    expr,
                };

                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, var_decl);
                Ok(id)
            }

            TokenType::Func => {
                consume(tokens, pos, TokenType::Func)?;
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();

                consume(tokens, pos, TokenType::LeftParen)?;
                let params = parse_separated(
                    tokens,
                    pos,
                    ctx,
                    TokenType::Comma,
                    TokenType::RightParen,
                    |tokens, pos, _ctx| {
                        Ok(consume(tokens, pos, TokenType::Identifier)?.expect_str())
                    },
                )?;
                consume(tokens, pos, TokenType::RightParen)?;

                consume(tokens, pos, TokenType::LeftBrace)?;
                let body = parse_block(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightBrace)?;

                let fn_decl = MetaStmt::FnDecl { name, params, body };
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, fn_decl);
                Ok(id)
            }
            //parse_fn_decl(tokens, pos, ctx, BlueprintFuncType::Normal),
            TokenType::Struct => {
                consume(tokens, pos, TokenType::Struct)?;
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::LeftBrace)?;
                let fields = parse_separated(
                    tokens,
                    pos,
                    ctx,
                    TokenType::Semicolon,
                    TokenType::RightBrace,
                    |tokens, pos, _ctx| {
                        let field_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                        consume(tokens, pos, TokenType::Colon)?;
                        let type_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                        Ok(MetaFieldDecl {
                            field_name,
                            type_name,
                        })
                    },
                )?;

                consume(tokens, pos, TokenType::RightBrace)?;
                let struct_decl = MetaStmt::StructDecl { name, fields };
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, struct_decl);
                Ok(id)
            }

            TokenType::Return => {
                consume(tokens, pos, TokenType::Return)?;
                let opt_expr = if check(tokens, *pos, TokenType::Semicolon) {
                    None
                } else {
                    Some(parse_expr(tokens, pos, ctx)?)
                };
                consume(tokens, pos, TokenType::Semicolon)?;

                let return_stmt = MetaStmt::Return(opt_expr);
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, return_stmt);
                Ok(id)
            }

            TokenType::Gen => {
                consume(tokens, pos, TokenType::Gen)?;
                let stmt = parse_stmt(tokens, pos, ctx)?;
                let gen = MetaStmt::Gen(vec![stmt]);
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, gen);
                Ok(id)
            }

            TokenType::LeftBrace => {
                // Lookahead: `{ ident :` means object literal expression, not a block
                let is_object_literal = check(tokens, *pos + 1, TokenType::Identifier)
                    && check(tokens, *pos + 2, TokenType::Colon);
                if is_object_literal {
                    parse_expr_stmt(tokens, pos, ctx)
                } else {
                    consume(tokens, pos, TokenType::LeftBrace)?;
                    let body = parse_block(tokens, pos, ctx)?;
                    consume(tokens, pos, TokenType::RightBrace)?;
                    Ok(body)
                }
            }

            TokenType::Meta => parse_meta_stmt(tokens, pos, ctx),

            TokenType::Import => {
                consume(tokens, pos, TokenType::Import)?;
                let mod_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::Semicolon)?;
                let import = MetaStmt::Import(mod_name);
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, import);
                Ok(id)
            }

            _ => parse_expr_stmt(tokens, pos, ctx),
        },
        _ => parse_expr_stmt(tokens, pos, ctx),
    }
}

fn parse_meta_stmt(
    tokens: &[Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    consume(tokens, pos, TokenType::Meta)?;
    let stmt = parse_stmt(tokens, pos, ctx)?;
    let meta_stmt = MetaStmt::MetaBlock(stmt);
    let id = ctx.ast.insert_stmt(&mut ctx.id_provider, meta_stmt);
    Ok(id)
}

fn parse_block(tokens: &[Token], pos: &mut usize, ctx: &mut ParseCtx) -> Result<usize, ParseError> {
    let mut stmts = Vec::new();

    while *pos < tokens.len() && tokens[*pos].token_type != TokenType::RightBrace {
        stmts.push(parse_stmt(tokens, pos, ctx)?);
    }

    let block_stmt = MetaStmt::Block(stmts);
    let id = ctx.ast.insert_stmt(&mut ctx.id_provider, block_stmt);
    Ok(id)
}

pub fn parse(tokens: &[Token], ctx: &mut ParseCtx) -> Result<(), ParseError> {
    let mut pos: usize = 0;

    while pos < tokens.len() && tokens[pos].token_type != TokenType::EOF {
        let id = parse_stmt(tokens, &mut pos, ctx)?;
        ctx.ast.sem_root_stmts.push(id);
    }

    Ok(())
}
