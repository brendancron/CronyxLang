use crate::util::id_provider::*;
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

fn parse_type_annot(tokens: &[Token], pos: &mut usize) -> Option<String> {
    if check(tokens, *pos, TokenType::Colon) {
        *pos += 1;
        if let Some(tok) = tokens.get(*pos) {
            *pos += 1;
            return Some(tok.expect_str());
        }
    }
    None
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
            TokenType::Bang => {
                *pos += 1;
                let operand = parse_factor(tokens, pos, ctx)?;
                let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Not(operand));
                Ok(id)
            }

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

                // EnumName::Variant or EnumName::Variant(...) or EnumName::Variant { ... }
                if check(tokens, *pos, TokenType::DoubleColon) {
                    consume(tokens, pos, TokenType::DoubleColon)?;
                    let variant = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    let payload = if check(tokens, *pos, TokenType::LeftParen) {
                        consume(tokens, pos, TokenType::LeftParen)?;
                        let exprs = parse_separated(
                            tokens, pos, ctx,
                            TokenType::Comma, TokenType::RightParen,
                            parse_expr,
                        )?;
                        consume(tokens, pos, TokenType::RightParen)?;
                        ConstructorPayload::Tuple(exprs)
                    } else if check(tokens, *pos, TokenType::LeftBrace)
                        && check(tokens, *pos + 1, TokenType::Identifier)
                        && check(tokens, *pos + 2, TokenType::Colon)
                    {
                        consume(tokens, pos, TokenType::LeftBrace)?;
                        let fields = parse_separated(
                            tokens, pos, ctx,
                            TokenType::Comma, TokenType::RightBrace,
                            |tokens, pos, ctx| {
                                let field_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                                consume(tokens, pos, TokenType::Colon)?;
                                let expr_id = parse_expr(tokens, pos, ctx)?;
                                Ok((field_name, expr_id))
                            },
                        )?;
                        consume(tokens, pos, TokenType::RightBrace)?;
                        ConstructorPayload::Struct(fields)
                    } else {
                        ConstructorPayload::Unit
                    };
                    let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::EnumConstructor {
                        enum_name: name,
                        variant,
                        payload,
                    });
                    return Ok(id);
                }

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
                } else if check(tokens, *pos, TokenType::LeftBrace)
                    && check(tokens, *pos + 1, TokenType::Identifier)
                    && check(tokens, *pos + 2, TokenType::Colon)
                {
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

/// Parses postfix dot-access and dot-call after a primary expression.
/// `foo.bar` → DotAccess, `foo.bar(args)` → DotCall, chainable.
fn parse_postfix<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    let mut base = parse_factor(tokens, pos, ctx)?;

    loop {
        if check(tokens, *pos, TokenType::Dot) {
            *pos += 1; // consume Dot
            let field = consume(tokens, pos, TokenType::Identifier)?.expect_str();
            if check(tokens, *pos, TokenType::LeftParen) {
                consume(tokens, pos, TokenType::LeftParen)?;
                let args = parse_separated(
                    tokens, pos, ctx,
                    TokenType::Comma, TokenType::RightParen, parse_expr,
                )?;
                consume(tokens, pos, TokenType::RightParen)?;
                base = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::DotCall { object: base, method: field, args },
                );
            } else {
                base = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::DotAccess { object: base, field },
                );
            }
        } else if check(tokens, *pos, TokenType::LeftBracket) {
            *pos += 1; // consume [
            let index = parse_expr(tokens, pos, ctx)?;
            consume(tokens, pos, TokenType::RightBracket)?;
            base = ctx.ast.insert_expr(
                &mut ctx.id_provider,
                MetaExpr::Index { object: base, index },
            );
        } else {
            break;
        }
    }

    Ok(base)
}

fn parse_term<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    let mut left = parse_postfix(tokens, pos, ctx)?;

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
                TokenType::BangEqual => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::NotEquals(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }
                TokenType::Less => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::Lt(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }
                TokenType::Greater => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::Gt(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }
                TokenType::LessEqual => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::Lte(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }
                TokenType::GreaterEqual => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::Gte(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }
                TokenType::And => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::And(left, right);
                    left = ctx.ast.insert_expr(&mut ctx.id_provider, node);
                }
                TokenType::Or => {
                    *pos += 1;
                    let right = parse_term(tokens, pos, ctx)?;
                    let node = MetaExpr::Or(left, right);
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

            TokenType::While => {
                consume(tokens, pos, TokenType::While)?;
                consume(tokens, pos, TokenType::LeftParen)?;
                let cond = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightParen)?;
                consume(tokens, pos, TokenType::LeftBrace)?;
                let body = parse_block(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightBrace)?;
                let stmt = MetaStmt::WhileLoop { cond, body };
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, stmt);
                return Ok(id);
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
                let type_annotation = parse_type_annot(tokens, pos);
                consume(tokens, pos, TokenType::Equal)?;
                let expr = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::Semicolon)?;
                let var_decl = MetaStmt::VarDecl {
                    name: ident.expect_str(),
                    type_annotation,
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
                        let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                        let ty = parse_type_annot(tokens, pos);
                        Ok(Param { name, ty })
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

            TokenType::Enum => {
                consume(tokens, pos, TokenType::Enum)?;
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::LeftBrace)?;
                let mut variants = Vec::new();
                while !check(tokens, *pos, TokenType::RightBrace) {
                    let variant_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    let payload = if check(tokens, *pos, TokenType::LeftParen) {
                        consume(tokens, pos, TokenType::LeftParen)?;
                        let types = parse_separated(
                            tokens, pos, ctx,
                            TokenType::Comma, TokenType::RightParen,
                            |tokens, pos, _ctx| {
                                Ok(consume(tokens, pos, TokenType::Identifier)?.expect_str())
                            },
                        )?;
                        consume(tokens, pos, TokenType::RightParen)?;
                        VariantPayload::Tuple(types)
                    } else if check(tokens, *pos, TokenType::LeftBrace) {
                        consume(tokens, pos, TokenType::LeftBrace)?;
                        let fields = parse_separated(
                            tokens, pos, ctx,
                            TokenType::Semicolon, TokenType::RightBrace,
                            |tokens, pos, _ctx| {
                                let field_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                                consume(tokens, pos, TokenType::Colon)?;
                                let type_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                                Ok(MetaFieldDecl { field_name, type_name })
                            },
                        )?;
                        consume(tokens, pos, TokenType::RightBrace)?;
                        VariantPayload::Struct(fields)
                    } else {
                        VariantPayload::Unit
                    };
                    variants.push(EnumVariant { name: variant_name, payload });
                    // Variants are separated by commas; trailing comma is allowed
                    if check(tokens, *pos, TokenType::Comma) {
                        *pos += 1;
                    }
                }
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::EnumDecl { name, variants });
                Ok(id)
            }

            TokenType::Match => {
                consume(tokens, pos, TokenType::Match)?;
                let scrutinee = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::LeftBrace)?;
                let mut arms = Vec::new();
                while !check(tokens, *pos, TokenType::RightBrace) {
                    let pattern = parse_pattern(tokens, pos)?;
                    consume(tokens, pos, TokenType::FatArrow)?;
                    consume(tokens, pos, TokenType::LeftBrace)?;
                    let body = parse_block(tokens, pos, ctx)?;
                    consume(tokens, pos, TokenType::RightBrace)?;
                    arms.push(MatchArm { pattern, body });
                }
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Match { scrutinee, arms });
                Ok(id)
            }

            TokenType::Meta => parse_meta_stmt(tokens, pos, ctx),

            TokenType::Import => {
                consume(tokens, pos, TokenType::Import)?;
                let decl = if check(tokens, *pos, TokenType::LeftBrace) {
                    // import { name1, name2 } from "path";
                    consume(tokens, pos, TokenType::LeftBrace)?;
                    let names = parse_separated(
                        tokens, pos, ctx,
                        TokenType::Comma, TokenType::RightBrace,
                        |tokens, pos, _ctx| {
                            Ok(consume(tokens, pos, TokenType::Identifier)?.expect_str())
                        },
                    )?;
                    consume(tokens, pos, TokenType::RightBrace)?;
                    consume(tokens, pos, TokenType::From)?;
                    let path = consume(tokens, pos, TokenType::String)?.expect_str();
                    ImportDecl::Selective { names, path }
                } else {
                    // import "path"; or import "path" as alias;
                    let path = consume(tokens, pos, TokenType::String)?.expect_str();
                    if check(tokens, *pos, TokenType::As) {
                        consume(tokens, pos, TokenType::As)?;
                        let alias = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                        ImportDecl::Aliased { path, alias }
                    } else {
                        ImportDecl::Qualified { path }
                    }
                };
                consume(tokens, pos, TokenType::Semicolon)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Import(decl));
                Ok(id)
            }

            TokenType::Identifier if check(tokens, *pos + 1, TokenType::LeftBracket) => {
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                let mut indices = Vec::new();
                while check(tokens, *pos, TokenType::LeftBracket) {
                    *pos += 1;
                    indices.push(parse_expr(tokens, pos, ctx)?);
                    consume(tokens, pos, TokenType::RightBracket)?;
                }
                consume(tokens, pos, TokenType::Equal)?;
                let expr = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::Semicolon)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::IndexAssign { name, indices, expr });
                Ok(id)
            }

            TokenType::Identifier if check(tokens, *pos + 1, TokenType::Equal) => {
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::Equal)?;
                let expr = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::Semicolon)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr });
                Ok(id)
            }

            _ => parse_expr_stmt(tokens, pos, ctx),
        },
        _ => parse_expr_stmt(tokens, pos, ctx),
    }
}

fn parse_pattern(tokens: &[Token], pos: &mut usize) -> Result<Pattern, ParseError> {
    // Wildcard: _
    if check(tokens, *pos, TokenType::Identifier) {
        if tokens[*pos].expect_str() == "_" {
            *pos += 1;
            return Ok(Pattern::Wildcard);
        }
    }
    // EnumName::Variant or EnumName::Variant(x, y) or EnumName::Variant { field }
    let enum_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
    consume(tokens, pos, TokenType::DoubleColon)?;
    let variant = consume(tokens, pos, TokenType::Identifier)?.expect_str();
    let bindings = if check(tokens, *pos, TokenType::LeftParen) {
        consume(tokens, pos, TokenType::LeftParen)?;
        let mut names = Vec::new();
        while !check(tokens, *pos, TokenType::RightParen) {
            names.push(consume(tokens, pos, TokenType::Identifier)?.expect_str());
            if check(tokens, *pos, TokenType::Comma) { *pos += 1; }
        }
        consume(tokens, pos, TokenType::RightParen)?;
        VariantBindings::Tuple(names)
    } else if check(tokens, *pos, TokenType::LeftBrace) {
        consume(tokens, pos, TokenType::LeftBrace)?;
        let mut names = Vec::new();
        while !check(tokens, *pos, TokenType::RightBrace) {
            names.push(consume(tokens, pos, TokenType::Identifier)?.expect_str());
            if check(tokens, *pos, TokenType::Comma) { *pos += 1; }
        }
        consume(tokens, pos, TokenType::RightBrace)?;
        VariantBindings::Struct(names)
    } else {
        VariantBindings::Unit
    };
    Ok(Pattern::Enum { enum_name, variant, bindings })
}

fn parse_meta_stmt(
    tokens: &[Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<usize, ParseError> {
    consume(tokens, pos, TokenType::Meta)?;

    if check(tokens, *pos, TokenType::Func) {
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
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                let ty = parse_type_annot(tokens, pos);
                Ok(Param { name, ty })
            },
        )?;
        consume(tokens, pos, TokenType::RightParen)?;

        consume(tokens, pos, TokenType::LeftBrace)?;
        let body = parse_block(tokens, pos, ctx)?;
        consume(tokens, pos, TokenType::RightBrace)?;

        let meta_fn = MetaStmt::MetaFnDecl { name, params, body };
        let id = ctx.ast.insert_stmt(&mut ctx.id_provider, meta_fn);
        return Ok(id);
    }

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
