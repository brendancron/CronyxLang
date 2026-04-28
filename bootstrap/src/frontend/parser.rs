use crate::util::id_provider::*;
use crate::util::node_id::MetaNodeId;
use super::meta_ast::*;
use super::token::*;
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// Effect helpers
// ---------------------------------------------------------------------------

/// Parse `effect name { (fn|ctl) op(params): ret; ... }`
fn parse_effect_decl(
    tokens: &[Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    consume(tokens, pos, TokenType::Effect)?;
    let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
    consume(tokens, pos, TokenType::LeftBrace)?;

    let mut ops = Vec::new();
    while !check(tokens, *pos, TokenType::RightBrace) {
        let kind = match tokens.get(*pos).map(|t| t.token_type) {
            Some(TokenType::Func) => { *pos += 1; EffectOpKind::Fn }
            Some(TokenType::Ctl) => { *pos += 1; EffectOpKind::Ctl }
            _ => { *pos += 1; EffectOpKind::Fn } // graceful fallback
        };
        let op_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
        consume(tokens, pos, TokenType::LeftParen)?;
        let params = parse_separated(
            tokens, pos, ctx,
            TokenType::Comma, TokenType::RightParen,
            |tokens, pos, _ctx| {
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                let ty = parse_type_annot(tokens, pos);
                Ok(Param { name, ty })
            },
        )?;
        consume(tokens, pos, TokenType::RightParen)?;
        let ret_ty = if check(tokens, *pos, TokenType::Colon) {
            *pos += 1;
            Some(consume(tokens, pos, TokenType::Identifier)?.expect_str())
        } else {
            None
        };
        if check(tokens, *pos, TokenType::Semicolon) {
            *pos += 1;
        }
        ops.push(EffectOp { kind, name: op_name, params, ret_ty });
    }
    consume(tokens, pos, TokenType::RightBrace)?;

    let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::EffectDecl { name, ops });
    Ok(id)
}

/// Parse `ctl op(params): ret { body }` or `fn op(params): ret { body }` (no leading `with`).
fn parse_single_handler(
    tokens: &[Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let is_ctl = match tokens.get(*pos).map(|t| t.token_type) {
        Some(TokenType::Ctl) => { *pos += 1; true }
        Some(TokenType::Func) => { *pos += 1; false }
        _ => {
            let (found, line, col) = match tokens.get(*pos) {
                Some(t) => (t.token_type, t.line_number, t.col),
                None => return Err(ParseError::UnexpectedEOF { expected: TokenType::Ctl }),
            };
            return Err(ParseError::UnexpectedToken { found, expected: TokenType::Ctl, line, col });
        }
    };

    let op_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
    consume(tokens, pos, TokenType::LeftParen)?;
    let params = parse_separated(
        tokens, pos, ctx,
        TokenType::Comma, TokenType::RightParen,
        |tokens, pos, _ctx| {
            let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
            let ty = parse_type_annot(tokens, pos);
            Ok(Param { name, ty })
        },
    )?;
    consume(tokens, pos, TokenType::RightParen)?;
    let ret_ty = if check(tokens, *pos, TokenType::Colon) {
        *pos += 1;
        Some(consume(tokens, pos, TokenType::Identifier)?.expect_str())
    } else {
        None
    };
    consume(tokens, pos, TokenType::LeftBrace)?;
    let body = parse_block(tokens, pos, ctx)?;
    consume(tokens, pos, TokenType::RightBrace)?;

    let stmt = if is_ctl {
        MetaStmt::WithCtl { op_name, params, ret_ty, body }
    } else {
        MetaStmt::WithFn { op_name, params, ret_ty, body }
    };
    let id = ctx.ast.insert_stmt(&mut ctx.id_provider, stmt);
    Ok(id)
}


/// Parse `resume` or `resume expr`
fn parse_resume(
    tokens: &[Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    consume(tokens, pos, TokenType::Resume)?;
    // bare resume (no expression) when followed by ; or }
    let opt_expr = if check(tokens, *pos, TokenType::Semicolon)
        || check(tokens, *pos, TokenType::RightBrace)
    {
        None
    } else {
        Some(parse_expr(tokens, pos, ctx)?)
    };
    if check(tokens, *pos, TokenType::Semicolon) {
        *pos += 1;
    }
    let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Resume(opt_expr));
    Ok(id)
}

pub struct ParseCtx {
    pub ast: MetaAst,
    pub id_provider: IdProvider,
    /// Maps AST node ID → (line, col) of the first token of that node.
    pub span_table: HashMap<usize, (usize, usize)>,
    /// When false, `name { }` no-paren trailing lambda is suppressed.
    /// Set to false for match scrutinees to avoid consuming the match body.
    pub allow_trailing_brace: bool,
}

impl ParseCtx {
    pub fn new() -> Self {
        Self {
            ast: MetaAst::new(),
            id_provider: IdProvider::new(),
            span_table: HashMap::new(),
            allow_trailing_brace: true,
        }
    }

    /// Record the source location for a node, if a location is known.
    pub fn record_span(&mut self, node_id: MetaNodeId, loc: Option<(usize, usize)>) {
        if let Some(l) = loc {
            self.span_table.insert(node_id.0, l);
        }
    }

    /// Copy the span of `src` to `dst` (for compound nodes that start at src).
    pub fn copy_span(&mut self, src: MetaNodeId, dst: MetaNodeId) {
        if let Some(loc) = self.span_table.get(&src.0).cloned() {
            self.span_table.insert(dst.0, loc);
        }
    }
}

#[derive(Debug)]
pub enum ParseError {
    UnterminatedString,
    UnexpectedToken {
        found: TokenType,
        expected: TokenType,
        line: usize,
        col: usize,
    },
    UnexpectedEOF {
        expected: TokenType,
    },
}

fn tok_loc(tokens: &[Token], pos: usize) -> Option<(usize, usize)> {
    tokens.get(pos).map(|t| (t.line_number, t.col))
}

// ---------------------------------------------------------------------------
// Trailing lambda helpers
// ---------------------------------------------------------------------------

/// Peek from `brace_pos` (pointing at `{`) to detect explicit params before `->`.
/// Returns `Some(params)` if pattern `{ (ident (,ident)*)? ->` is found.
/// Returns `None` if no `->` found — caller should use implicit `it`.
fn peek_trailing_lambda_params(tokens: &[Token], brace_pos: usize) -> Option<Vec<String>> {
    let mut i = brace_pos + 1; // skip `{`
    let mut params: Vec<String> = Vec::new();

    match tokens.get(i).map(|t| t.token_type) {
        Some(TokenType::Arrow) => return Some(vec![]), // `{ -> body }`
        Some(TokenType::Identifier) => {
            params.push(tokens[i].expect_str());
            i += 1;
        }
        _ => return None, // implicit `it`
    }

    loop {
        match tokens.get(i).map(|t| t.token_type) {
            Some(TokenType::Arrow) => return Some(params),
            Some(TokenType::Comma) => {
                i += 1;
                if matches!(tokens.get(i).map(|t| t.token_type), Some(TokenType::Identifier)) {
                    params.push(tokens[i].expect_str());
                    i += 1;
                } else {
                    return None;
                }
            }
            _ => return None, // not a valid param list → implicit `it`
        }
    }
}

/// Parse the body of a trailing lambda: statements with `;`, but a bare final expression
/// (no `;` before `}`) is wrapped as an implicit `Return` so the value propagates.
fn parse_lambda_body<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let mut stmts = Vec::new();

    while *pos < tokens.len() && tokens[*pos].token_type != TokenType::RightBrace {
        let is_stmt_kw = matches!(
            tokens.get(*pos).map(|t| t.token_type),
            Some(
                TokenType::Var  | TokenType::If    | TokenType::While  | TokenType::Return |
                TokenType::Func | TokenType::For   | TokenType::Defer  | TokenType::Effect |
                TokenType::Impl | TokenType::Trait | TokenType::Enum   | TokenType::Struct |
                TokenType::Print| TokenType::Match | TokenType::Handle |
                TokenType::Run  | TokenType::Handler
            )
        );

        if is_stmt_kw {
            stmts.push(parse_stmt(tokens, pos, ctx)?);
        } else {
            let start_loc = tok_loc(tokens, *pos);
            let expr = parse_expr(tokens, pos, ctx)?;
            if check(tokens, *pos, TokenType::RightBrace) {
                // Bare final expression → implicit return
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Return(Some(expr)));
                ctx.record_span(id, start_loc);
                stmts.push(id);
            } else {
                consume(tokens, pos, TokenType::Semicolon)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::ExprStmt(expr));
                ctx.record_span(id, start_loc);
                stmts.push(id);
            }
        }
    }

    let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Block(stmts));
    Ok(id)
}

/// Parse `{ (params ->)? body }` as a `Lambda` expression (trailing lambda desugaring).
/// If no `params ->` is found, inserts implicit `it` as the single parameter.
fn parse_trailing_lambda_block<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let start_loc = tok_loc(tokens, *pos);
    let explicit_params = peek_trailing_lambda_params(tokens, *pos);

    consume(tokens, pos, TokenType::LeftBrace)?;

    let params = if let Some(explicit) = explicit_params {
        let mut result = Vec::new();
        let mut first = true;
        for _ in 0..explicit.len() {
            if !first {
                consume(tokens, pos, TokenType::Comma)?;
            }
            first = false;
            result.push(consume(tokens, pos, TokenType::Identifier)?.expect_str());
        }
        consume(tokens, pos, TokenType::Arrow)?;
        result
    } else {
        vec!["it".to_string()]
    };

    let body = parse_lambda_body(tokens, pos, ctx)?;
    consume(tokens, pos, TokenType::RightBrace)?;

    let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Lambda { params, body });
    ctx.record_span(id, start_loc);
    Ok(id)
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
        Some(t) if t.token_type == expected => consume_next(tokens, pos),
        Some(t) => Err(ParseError::UnexpectedToken {
            found: t.token_type,
            expected,
            line: t.line_number,
            col: t.col,
        }),
        None => Err(ParseError::UnexpectedEOF { expected }),
    }
}

fn consume_next<'a>(tokens: &'a [Token], pos: &mut usize) -> Result<&'a Token, ParseError> {
    match tokens.get(*pos) {
        Some(tok) => { *pos += 1; Ok(tok) }
        None => Err(ParseError::UnexpectedEOF { expected: TokenType::EOF }),
    }
}

/// Consume the next token as a field/method name in dot-access position.
/// Allows keywords (like `run`) to be used as method names: `obj.run()`.
fn consume_field_name(tokens: &[Token], pos: &mut usize) -> Result<String, ParseError> {
    match tokens.get(*pos) {
        Some(t) => {
            let name = match t.token_type {
                TokenType::Identifier => t.expect_str(),
                TokenType::Run => "run".to_string(),
                _ => {
                    return Err(ParseError::UnexpectedToken {
                        found: t.token_type,
                        expected: TokenType::Identifier,
                        line: t.line_number,
                        col: t.col,
                    });
                }
            };
            *pos += 1;
            Ok(name)
        }
        None => Err(ParseError::UnexpectedEOF { expected: TokenType::Identifier }),
    }
}

/// Parse a type expression starting at `*pos` (no leading `:` consumed).
/// Handles Named, App (`Expr<T>`), Tuple (`(A, B)`), and Slice (`[T]`).
fn parse_type_expr(tokens: &[Token], pos: &mut usize) -> Result<MetaTypeExpr, ParseError> {
    // Tuple: (A, B, ...)
    if check(tokens, *pos, TokenType::LeftParen) {
        *pos += 1;
        let mut elems = Vec::new();
        while *pos < tokens.len() && !check(tokens, *pos, TokenType::RightParen) {
            elems.push(parse_type_expr(tokens, pos)?);
            if check(tokens, *pos, TokenType::Comma) { *pos += 1; }
        }
        if check(tokens, *pos, TokenType::RightParen) { *pos += 1; }
        return Ok(MetaTypeExpr::Tuple(elems));
    }
    // Slice: [T]
    if check(tokens, *pos, TokenType::LeftBracket) {
        *pos += 1;
        let inner = parse_type_expr(tokens, pos)?;
        if check(tokens, *pos, TokenType::RightBracket) { *pos += 1; }
        return Ok(MetaTypeExpr::Slice(Box::new(inner)));
    }
    // Named or App
    let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
    if check(tokens, *pos, TokenType::Less) {
        *pos += 1; // consume <
        let mut args = Vec::new();
        while *pos < tokens.len() && !check(tokens, *pos, TokenType::Greater) {
            args.push(parse_type_expr(tokens, pos)?);
            if check(tokens, *pos, TokenType::Comma) { *pos += 1; }
        }
        if check(tokens, *pos, TokenType::Greater) { *pos += 1; }
        return Ok(MetaTypeExpr::App(name, args));
    }
    Ok(MetaTypeExpr::Named(name))
}

fn parse_type_annot(tokens: &[Token], pos: &mut usize) -> Option<MetaTypeExpr> {
    if !check(tokens, *pos, TokenType::Colon) {
        return None;
    }
    *pos += 1; // consume `:`
    // Function type: `fn(T, ...): R` — not a MetaTypeExpr, handled separately.
    if check(tokens, *pos, TokenType::Func) {
        *pos += 1;
        if check(tokens, *pos, TokenType::LeftParen) {
            let mut depth = 1usize;
            *pos += 1;
            while *pos < tokens.len() && depth > 0 {
                match tokens[*pos].token_type {
                    TokenType::LeftParen  => { depth += 1; *pos += 1; }
                    TokenType::RightParen => { depth -= 1; *pos += 1; }
                    _ => { *pos += 1; }
                }
            }
        }
        if check(tokens, *pos, TokenType::Colon) {
            *pos += 1;
            if *pos < tokens.len() { *pos += 1; }
        }
        return Some(MetaTypeExpr::Named("fn".to_string()));
    }
    parse_type_expr(tokens, pos).ok()
}

/// Consume an optional `: Type` return-type annotation and return it.
fn parse_return_type(tokens: &[Token], pos: &mut usize) -> Option<MetaTypeExpr> {
    if check(tokens, *pos, TokenType::Colon) {
        *pos += 1;
        return parse_type_expr(tokens, pos).ok();
    }
    if check(tokens, *pos, TokenType::Arrow) {
        *pos += 1;
        return parse_type_expr(tokens, pos).ok();
    }
    None
}

/// Consume and discard an optional `<T, U: Bound + Bound2, ...>` type parameter list.
/// Handles nested `<` `>` for complex types.
/// Parse an optional `<T, U: Bound, ...>` type-parameter list.
/// Returns the bare parameter names (bounds are discarded).
/// Consumes no tokens if there is no `<`.
fn parse_type_params(tokens: &[Token], pos: &mut usize) -> Vec<String> {
    if !check(tokens, *pos, TokenType::Less) {
        return vec![];
    }
    *pos += 1; // consume <
    let mut names = Vec::new();
    let mut depth = 1usize;
    while *pos < tokens.len() && depth > 0 {
        match tokens[*pos].token_type {
            TokenType::Less => { depth += 1; *pos += 1; }
            TokenType::Greater => { depth -= 1; *pos += 1; }
            TokenType::Comma if depth == 1 => { *pos += 1; }
            TokenType::Colon if depth == 1 => {
                // skip bound tokens until the next `,` or `>`
                *pos += 1;
                while *pos < tokens.len()
                    && !matches!(tokens[*pos].token_type, TokenType::Comma | TokenType::Greater)
                {
                    *pos += 1;
                }
            }
            TokenType::Identifier if depth == 1 => {
                names.push(tokens[*pos].expect_str());
                *pos += 1;
            }
            _ => { *pos += 1; }
        }
    }
    names
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
            return match tokens.get(*pos) {
                Some(t) => Err(ParseError::UnexpectedToken {
                    found: t.token_type,
                    expected: separator,
                    line: t.line_number,
                    col: t.col,
                }),
                None => Err(ParseError::UnexpectedEOF { expected: separator }),
            };
        }

        if check(tokens, *pos, separator) {
            consume(tokens, pos, separator)?;
            if check(tokens, *pos, terminator) { break; } // allow trailing separator
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
) -> Result<MetaNodeId, ParseError> {
    let start_loc = tok_loc(tokens, *pos);
    match tokens.get(*pos) {
        Some(tok) => match tok.token_type {
            TokenType::Bang => {
                *pos += 1;
                let operand = parse_postfix(tokens, pos, ctx)?;
                let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Not(operand));
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::Minus => {
                *pos += 1;
                let operand = parse_postfix(tokens, pos, ctx)?;
                let zero = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Int(0));
                let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Sub(zero, operand));
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::Number => {
                consume_next(tokens, pos)?;
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Int(tok.expect_int()));
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::String => {
                consume_next(tokens, pos)?;
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::String(tok.expect_str()));
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::True => {
                consume_next(tokens, pos)?;
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Bool(true));
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::False => {
                consume_next(tokens, pos)?;
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Bool(false));
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::LeftParen => {
                consume(tokens, pos, TokenType::LeftParen)?;
                // Empty-param arrow lambda: `() => body`
                if check(tokens, *pos, TokenType::RightParen) {
                    consume(tokens, pos, TokenType::RightParen)?;
                    if check(tokens, *pos, TokenType::FatArrow) {
                        consume(tokens, pos, TokenType::FatArrow)?;
                        let body = parse_arrow_body(tokens, pos, ctx)?;
                        let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Lambda { params: vec![], body });
                        ctx.record_span(id, start_loc);
                        return Ok(id);
                    }
                    // `()` with no `=>` — treat as integer 0 (unit placeholder)
                    let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Int(0));
                    ctx.record_span(id, start_loc);
                    return Ok(id);
                }
                let first = parse_expr(tokens, pos, ctx)?;
                if check(tokens, *pos, TokenType::Comma) {
                    // Tuple literal or multi-param arrow lambda: (a, b, ...)
                    let mut elems = vec![first];
                    while check(tokens, *pos, TokenType::Comma) {
                        *pos += 1;
                        if check(tokens, *pos, TokenType::RightParen) { break; }
                        elems.push(parse_expr(tokens, pos, ctx)?);
                    }
                    consume(tokens, pos, TokenType::RightParen)?;
                    // Multi-param arrow lambda: (a, b) => body
                    if check(tokens, *pos, TokenType::FatArrow) {
                        let params: Option<Vec<String>> = elems.iter()
                            .map(|&e| extract_ident(&ctx.ast, e))
                            .collect();
                        if let Some(params) = params {
                            consume(tokens, pos, TokenType::FatArrow)?;
                            let body = parse_arrow_body(tokens, pos, ctx)?;
                            let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Lambda { params, body });
                            ctx.record_span(id, start_loc);
                            return Ok(id);
                        }
                    }
                    let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Tuple(elems));
                    ctx.record_span(id, start_loc);
                    Ok(id)
                } else {
                    consume(tokens, pos, TokenType::RightParen)?;
                    // Single-param arrow lambda: (x) => body
                    if check(tokens, *pos, TokenType::FatArrow) {
                        if let Some(param) = extract_ident(&ctx.ast, first) {
                            consume(tokens, pos, TokenType::FatArrow)?;
                            let body = parse_arrow_body(tokens, pos, ctx)?;
                            let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Lambda { params: vec![param], body });
                            ctx.record_span(id, start_loc);
                            return Ok(id);
                        }
                    }
                    Ok(first)
                }
            }

            TokenType::Typeof => {
                consume(tokens, pos, TokenType::Typeof)?;
                consume(tokens, pos, TokenType::LeftParen)?;
                let ident = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::RightParen)?;
                let id = ctx
                    .ast
                    .insert_expr(&mut ctx.id_provider, MetaExpr::Typeof(ident));
                ctx.record_span(id, start_loc);
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
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::Identifier => {
                let name = consume_next(tokens, pos)?.expect_str();

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
                    ctx.record_span(id, start_loc);
                    return Ok(id);
                }

                if check(tokens, *pos, TokenType::LeftParen) {
                    consume(tokens, pos, TokenType::LeftParen)?;
                    let mut args = parse_separated(
                        tokens,
                        pos,
                        ctx,
                        TokenType::Comma,
                        TokenType::RightParen,
                        parse_expr,
                    )?;
                    consume(tokens, pos, TokenType::RightParen)?;

                    // Trailing lambda: foo(args) { params -> body }
                    if check(tokens, *pos, TokenType::LeftBrace) {
                        let lambda = parse_trailing_lambda_block(tokens, pos, ctx)?;
                        args.push(lambda);
                    }

                    let id = ctx
                        .ast
                        .insert_expr(&mut ctx.id_provider, MetaExpr::Call { callee: name, args });
                    ctx.record_span(id, start_loc);
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
                    ctx.record_span(id, start_loc);
                    Ok(id)
                } else if ctx.allow_trailing_brace && check(tokens, *pos, TokenType::LeftBrace) {
                    // Trailing lambda, no parens: foo { params -> body }
                    let lambda = parse_trailing_lambda_block(tokens, pos, ctx)?;
                    let id = ctx.ast.insert_expr(
                        &mut ctx.id_provider,
                        MetaExpr::Call { callee: name, args: vec![lambda] },
                    );
                    ctx.record_span(id, start_loc);
                    Ok(id)
                } else {
                    let id = ctx
                        .ast
                        .insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name));
                    ctx.record_span(id, start_loc);
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
                ctx.record_span(id, start_loc);
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

            // `resume` or `resume(expr)` used as an expression
            TokenType::Resume => {
                consume(tokens, pos, TokenType::Resume)?;
                let opt_expr = if check(tokens, *pos, TokenType::LeftParen) {
                    consume(tokens, pos, TokenType::LeftParen)?;
                    if check(tokens, *pos, TokenType::RightParen) {
                        consume(tokens, pos, TokenType::RightParen)?;
                        None
                    } else {
                        let e = parse_expr(tokens, pos, ctx)?;
                        consume(tokens, pos, TokenType::RightParen)?;
                        Some(e)
                    }
                } else {
                    None
                };
                let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::ResumeExpr(opt_expr));
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            // `run { body } handle eff_name { ops } ...`
            TokenType::Run => {
                consume(tokens, pos, TokenType::Run)?;
                consume(tokens, pos, TokenType::LeftBrace)?;
                let body_block = parse_block(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightBrace)?;
                let mut effects: Vec<(String, Vec<MetaNodeId>)> = Vec::new();
                while check(tokens, *pos, TokenType::Handle) {
                    *pos += 1; // consume `handle`
                    let eff_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    consume(tokens, pos, TokenType::LeftBrace)?;
                    let mut ops = Vec::new();
                    while !check(tokens, *pos, TokenType::RightBrace) && !check(tokens, *pos, TokenType::EOF) {
                        ops.push(parse_single_handler(tokens, pos, ctx)?);
                    }
                    consume(tokens, pos, TokenType::RightBrace)?;
                    effects.push((eff_name, ops));
                }
                // `run { body } with handler_name` — named handler
                if check(tokens, *pos, TokenType::With)
                    && tokens.get(*pos + 1).map(|t| t.token_type) == Some(TokenType::Identifier)
                {
                    *pos += 1; // consume `with`
                    let handler_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::RunWith {
                        body: body_block,
                        handler_name,
                    });
                    ctx.record_span(id, start_loc);
                    return Ok(id);
                }
                let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::RunHandle {
                    body: body_block,
                    effects,
                });
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            // Lambda expression: `fn(params): ReturnType { body }`
            TokenType::Func => {
                consume_next(tokens, pos)?; // consume `fn`
                consume(tokens, pos, TokenType::LeftParen)?;
                let params = parse_separated(
                    tokens, pos, ctx,
                    TokenType::Comma, TokenType::RightParen,
                    |tokens, pos, _ctx| {
                        let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                        let _ = parse_type_annot(tokens, pos); // consume annotation, discard
                        Ok(name)
                    },
                )?;
                consume(tokens, pos, TokenType::RightParen)?;
                let _ = parse_return_type(tokens, pos);
                consume(tokens, pos, TokenType::LeftBrace)?;
                let body = parse_block(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Lambda { params, body });
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            _ => Err(ParseError::UnexpectedToken {
                found: tok.token_type,
                expected: TokenType::LeftParen,
                line: tok.line_number,
                col: tok.col,
            }),
        },
        None => Err(ParseError::UnexpectedEOF { expected: TokenType::LeftParen }),
    }
}

/// Parses postfix dot-access and dot-call after a primary expression.
/// `foo.bar` → DotAccess, `foo.bar(args)` → DotCall, chainable.
fn parse_postfix<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let mut base = parse_factor(tokens, pos, ctx)?;

    loop {
        if check(tokens, *pos, TokenType::Dot) {
            *pos += 1; // consume Dot
            // Numeric dot access: tuple.0, tuple.1
            if check(tokens, *pos, TokenType::Number) {
                let idx = consume_next(tokens, pos)?.expect_int() as usize;
                let prev = base;
                base = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::TupleIndex { object: base, index: idx },
                );
                ctx.copy_span(prev, base);
                continue;
            }
            let field = consume_field_name(tokens, pos)?;
            if check(tokens, *pos, TokenType::LeftParen) {
                consume(tokens, pos, TokenType::LeftParen)?;
                let mut args = parse_separated(
                    tokens, pos, ctx,
                    TokenType::Comma, TokenType::RightParen, parse_expr,
                )?;
                consume(tokens, pos, TokenType::RightParen)?;

                // Trailing lambda: obj.method(args) { params -> body }
                if check(tokens, *pos, TokenType::LeftBrace) {
                    let lambda = parse_trailing_lambda_block(tokens, pos, ctx)?;
                    args.push(lambda);
                }

                let prev = base;
                base = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::DotCall { object: base, method: field, args },
                );
                ctx.copy_span(prev, base);
            } else if check(tokens, *pos, TokenType::LeftBrace) {
                // No-parens trailing block: obj.method { block } → DotCall([fn() { block }])
                // Uses zero params (thunk) rather than the implicit `it` param from trailing_lambda.
                let lam_start = tok_loc(tokens, *pos);
                consume(tokens, pos, TokenType::LeftBrace)?;
                let lam_body = parse_lambda_body(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightBrace)?;
                let lambda = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::Lambda { params: vec![], body: lam_body },
                );
                ctx.record_span(lambda, lam_start);
                let prev = base;
                base = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::DotCall { object: base, method: field, args: vec![lambda] },
                );
                ctx.copy_span(prev, base);
            } else {
                let prev = base;
                base = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::DotAccess { object: base, field },
                );
                ctx.copy_span(prev, base);
            }
        } else if check(tokens, *pos, TokenType::LeftBracket) {
            *pos += 1; // consume [
            // Detect slice range: `[:]`, `[start:]`, `[:end]`, `[start:end]`
            let is_range = check(tokens, *pos, TokenType::Colon);

            if is_range {
                // `[:]` or `[:end]`
                *pos += 1; // consume :
                let end = if check(tokens, *pos, TokenType::RightBracket) {
                    None
                } else {
                    Some(parse_expr(tokens, pos, ctx)?)
                };
                consume(tokens, pos, TokenType::RightBracket)?;
                let prev = base;
                base = ctx.ast.insert_expr(
                    &mut ctx.id_provider,
                    MetaExpr::SliceRange { object: base, start: None, end },
                );
                ctx.copy_span(prev, base);
            } else {
                let first = parse_expr(tokens, pos, ctx)?;
                if check(tokens, *pos, TokenType::Colon) {
                    // `[start:]` or `[start:end]`
                    *pos += 1; // consume :
                    let end = if check(tokens, *pos, TokenType::RightBracket) {
                        None
                    } else {
                        Some(parse_expr(tokens, pos, ctx)?)
                    };
                    consume(tokens, pos, TokenType::RightBracket)?;
                    let prev = base;
                    base = ctx.ast.insert_expr(
                        &mut ctx.id_provider,
                        MetaExpr::SliceRange { object: base, start: Some(first), end },
                    );
                    ctx.copy_span(prev, base);
                } else {
                    consume(tokens, pos, TokenType::RightBracket)?;
                    let prev = base;
                    base = ctx.ast.insert_expr(
                        &mut ctx.id_provider,
                        MetaExpr::Index { object: base, index: first },
                    );
                    ctx.copy_span(prev, base);
                }
            }
        } else {
            break;
        }
    }

    Ok(base)
}

/// Level 6: * /
fn parse_term<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let mut left = parse_postfix(tokens, pos, ctx)?;
    loop {
        match tokens.get(*pos).map(|t| t.token_type) {
            Some(TokenType::Star) => {
                *pos += 1;
                let right = parse_postfix(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Mult(left, right));
                ctx.copy_span(prev, left);
            }
            Some(TokenType::Slash) => {
                *pos += 1;
                let right = parse_postfix(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Div(left, right));
                ctx.copy_span(prev, left);
            }
            Some(TokenType::Percent) => {
                *pos += 1;
                let right = parse_postfix(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Mod(left, right));
                ctx.copy_span(prev, left);
            }
            _ => return Ok(left),
        }
    }
}

/// Level 5: + -
fn parse_addition<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let mut left = parse_term(tokens, pos, ctx)?;
    loop {
        match tokens.get(*pos).map(|t| t.token_type) {
            Some(TokenType::Plus) => {
                *pos += 1;
                let right = parse_term(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Add(left, right));
                ctx.copy_span(prev, left);
            }
            Some(TokenType::Minus) => {
                *pos += 1;
                let right = parse_term(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Sub(left, right));
                ctx.copy_span(prev, left);
            }
            _ => return Ok(left),
        }
    }
}

/// Level 4: < > <= >=
fn parse_comparison<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let mut left = parse_addition(tokens, pos, ctx)?;
    loop {
        match tokens.get(*pos).map(|t| t.token_type) {
            Some(TokenType::Less) => {
                *pos += 1;
                let right = parse_addition(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Lt(left, right));
                ctx.copy_span(prev, left);
            }
            Some(TokenType::Greater) => {
                *pos += 1;
                let right = parse_addition(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Gt(left, right));
                ctx.copy_span(prev, left);
            }
            Some(TokenType::LessEqual) => {
                *pos += 1;
                let right = parse_addition(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Lte(left, right));
                ctx.copy_span(prev, left);
            }
            Some(TokenType::GreaterEqual) => {
                *pos += 1;
                let right = parse_addition(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Gte(left, right));
                ctx.copy_span(prev, left);
            }
            _ => return Ok(left),
        }
    }
}

/// Level 3: == !=
fn parse_equality<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let mut left = parse_comparison(tokens, pos, ctx)?;
    loop {
        match tokens.get(*pos).map(|t| t.token_type) {
            Some(TokenType::EqualEqual) => {
                *pos += 1;
                let right = parse_comparison(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Equals(left, right));
                ctx.copy_span(prev, left);
            }
            Some(TokenType::BangEqual) => {
                *pos += 1;
                let right = parse_comparison(tokens, pos, ctx)?;
                let prev = left;
                left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::NotEquals(left, right));
                ctx.copy_span(prev, left);
            }
            _ => return Ok(left),
        }
    }
}

/// Level 2: &&
fn parse_and<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let mut left = parse_equality(tokens, pos, ctx)?;
    loop {
        if tokens.get(*pos).map(|t| t.token_type) == Some(TokenType::AmpAmp) {
            *pos += 1;
            let right = parse_equality(tokens, pos, ctx)?;
            let prev = left;
            left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::And(left, right));
            ctx.copy_span(prev, left);
        } else {
            return Ok(left);
        }
    }
}

/// Level 1 (lowest): ||
fn parse_or<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let mut left = parse_and(tokens, pos, ctx)?;
    loop {
        if tokens.get(*pos).map(|t| t.token_type) == Some(TokenType::PipePipe) {
            *pos += 1;
            let right = parse_and(tokens, pos, ctx)?;
            let prev = left;
            left = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Or(left, right));
            ctx.copy_span(prev, left);
        } else {
            return Ok(left);
        }
    }
}

/// Entry point for expression parsing (lowest precedence = `||`).
fn extract_ident(ast: &crate::frontend::meta_ast::MetaAst, expr_id: MetaNodeId) -> Option<String> {
    match ast.get_expr(expr_id) {
        Some(MetaExpr::Variable(name)) => Some(name.clone()),
        _ => None,
    }
}

fn parse_arrow_body<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    if check(tokens, *pos, TokenType::LeftBrace) {
        consume(tokens, pos, TokenType::LeftBrace)?;
        let body = parse_lambda_body(tokens, pos, ctx)?;
        consume(tokens, pos, TokenType::RightBrace)?;
        Ok(body)
    } else {
        let expr = parse_expr(tokens, pos, ctx)?;
        let ret = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Return(Some(expr)));
        let block = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Block(vec![ret]));
        Ok(block)
    }
}

fn parse_expr<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    parse_or(tokens, pos, ctx)
}

fn parse_expr_stmt<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let start_loc = tok_loc(tokens, *pos);
    let expr = parse_expr(tokens, pos, ctx)?;
    if check(tokens, *pos, TokenType::Semicolon) {
        *pos += 1;
    }
    let id = ctx
        .ast
        .insert_stmt(&mut ctx.id_provider, MetaStmt::ExprStmt(expr));
    ctx.record_span(id, start_loc);
    Ok(id)
}

fn parse_stmt<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let start_loc = tok_loc(tokens, *pos);
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

                // Distinguish: for (var ...) or for (ident in ...) vs for (ident ...)
                let is_c_style = check(tokens, *pos, TokenType::Var)
                    || (check(tokens, *pos, TokenType::Identifier)
                        && !check(tokens, *pos + 1, TokenType::In));

                if is_c_style {
                    // C-style: for (init; cond; incr) { body }
                    // init is a full stmt (consumes its own `;`)
                    let init = parse_stmt(tokens, pos, ctx)?;
                    let cond = parse_expr(tokens, pos, ctx)?;
                    consume(tokens, pos, TokenType::Semicolon)?;
                    let incr = parse_for_incr(tokens, pos, ctx)?;
                    consume(tokens, pos, TokenType::RightParen)?;
                    consume(tokens, pos, TokenType::LeftBrace)?;
                    let body_inner = parse_block(tokens, pos, ctx)?;
                    consume(tokens, pos, TokenType::RightBrace)?;

                    // Desugar to: Block([init, WhileLoop(cond, Block([body, incr]))])
                    let while_body = ctx.ast.insert_stmt(
                        &mut ctx.id_provider,
                        MetaStmt::Block(vec![body_inner, incr]),
                    );
                    let while_stmt = ctx.ast.insert_stmt(
                        &mut ctx.id_provider,
                        MetaStmt::WhileLoop { cond, body: while_body },
                    );
                    let id = ctx.ast.insert_stmt(
                        &mut ctx.id_provider,
                        MetaStmt::Block(vec![init, while_stmt]),
                    );
                    Ok(id)
                } else {
                    // for-each: for (ident in iterable)
                    let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    consume(tokens, pos, TokenType::In)?;
                    let iter = parse_expr(tokens, pos, ctx)?;
                    consume(tokens, pos, TokenType::RightParen)?;
                    consume(tokens, pos, TokenType::LeftBrace)?;
                    let inner = parse_block(tokens, pos, ctx)?;
                    consume(tokens, pos, TokenType::RightBrace)?;
                    let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::ForEach {
                        var: name,
                        iterable: iter,
                        body: inner,
                    });
                    Ok(id)
                }
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
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::Func => {
                consume(tokens, pos, TokenType::Func)?;
                let name = consume_field_name(tokens, pos)?;
                let type_params = parse_type_params(tokens, pos);

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
                let ret_ty = parse_return_type(tokens, pos);

                consume(tokens, pos, TokenType::LeftBrace)?;
                let body = parse_block(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::RightBrace)?;

                let fn_decl = MetaStmt::FnDecl { name, params, type_params, ret_ty, body };
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, fn_decl);
                ctx.record_span(id, start_loc);
                Ok(id)
            }
            //parse_fn_decl(tokens, pos, ctx, BlueprintFuncType::Normal),
            TokenType::Struct => {
                consume(tokens, pos, TokenType::Struct)?;
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                parse_type_params(tokens, pos); // type params on structs are parsed but discarded for now
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
                        let type_expr = parse_type_expr(tokens, pos)?;
                        Ok(MetaFieldDecl {
                            field_name,
                            type_name: type_expr.to_string(),
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
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::Defer => {
                consume(tokens, pos, TokenType::Defer)?;
                let deferred = parse_stmt(tokens, pos, ctx)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Defer(deferred));
                ctx.record_span(id, start_loc);
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
                // GADT: optional type params on the enum, e.g. `enum Expr<T>`
                let type_params = parse_type_params(tokens, pos);
                consume(tokens, pos, TokenType::LeftBrace)?;
                let mut variants = Vec::new();
                while !check(tokens, *pos, TokenType::RightBrace) {
                    let variant_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    // GADT: optional constructor-local type vars, e.g. `If<A>(...)`
                    let local_type_params = parse_type_params(tokens, pos);
                    let payload = if check(tokens, *pos, TokenType::LeftParen) {
                        consume(tokens, pos, TokenType::LeftParen)?;
                        let types = parse_separated(
                            tokens, pos, ctx,
                            TokenType::Comma, TokenType::RightParen,
                            |tokens, pos, _ctx| parse_type_expr(tokens, pos),
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
                    // GADT: optional return-type annotation, e.g. `: Expr<int>`
                    let return_type = if check(tokens, *pos, TokenType::Colon) {
                        *pos += 1;
                        Some(parse_type_expr(tokens, pos)?)
                    } else {
                        None
                    };
                    variants.push(EnumVariant { name: variant_name, local_type_params, payload, return_type });
                    // Variants are separated by commas; trailing comma is allowed
                    if check(tokens, *pos, TokenType::Comma) {
                        *pos += 1;
                    }
                }
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::EnumDecl { name, type_params, variants });
                Ok(id)
            }

            TokenType::Match => {
                consume(tokens, pos, TokenType::Match)?;
                ctx.allow_trailing_brace = false;
                let scrutinee = parse_expr(tokens, pos, ctx)?;
                ctx.allow_trailing_brace = true;
                consume(tokens, pos, TokenType::LeftBrace)?;
                let mut arms = Vec::new();
                while !check(tokens, *pos, TokenType::RightBrace) {
                    let pattern = parse_pattern(tokens, pos)?;
                    consume(tokens, pos, TokenType::FatArrow)?;
                    let body = if check(tokens, *pos, TokenType::LeftBrace) {
                        // Block-body arm: `Pattern => { stmts }`
                        consume(tokens, pos, TokenType::LeftBrace)?;
                        let b = parse_block(tokens, pos, ctx)?;
                        consume(tokens, pos, TokenType::RightBrace)?;
                        b
                    } else {
                        // Expression-body arm: `Pattern => expr,`
                        // Wrap in Return so the value propagates out of the match.
                        ctx.allow_trailing_brace = false;
                        let expr = parse_expr(tokens, pos, ctx)?;
                        ctx.allow_trailing_brace = true;
                        let ret_id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Return(Some(expr)));
                        if check(tokens, *pos, TokenType::Comma) { *pos += 1; }
                        ret_id
                    };
                    arms.push(MatchArm { pattern, body });
                }
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Match { scrutinee, arms });
                Ok(id)
            }

            TokenType::Effect => parse_effect_decl(tokens, pos, ctx),

            // `run { body } handle ... {}` used as a statement — semicolon optional.
            TokenType::Run => {
                let expr = parse_expr(tokens, pos, ctx)?;
                if check(tokens, *pos, TokenType::Semicolon) {
                    *pos += 1;
                }
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::ExprStmt(expr));
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            // `handler name : effect_name { ops }` — named handler definition
            TokenType::Handler => {
                consume(tokens, pos, TokenType::Handler)?;
                let name = consume_field_name(tokens, pos)?;
                consume(tokens, pos, TokenType::Colon)?;
                let effect_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::LeftBrace)?;
                let mut ops = Vec::new();
                while !check(tokens, *pos, TokenType::RightBrace) && !check(tokens, *pos, TokenType::EOF) {
                    ops.push(parse_single_handler(tokens, pos, ctx)?);
                }
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::HandlerDef {
                    name,
                    effect_name: Some(effect_name),
                    ops,
                });
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            // `handle name { ops }` — HandlerDef statement
            TokenType::Handle => {
                consume(tokens, pos, TokenType::Handle)?;
                let name = consume_field_name(tokens, pos)?;
                consume(tokens, pos, TokenType::LeftBrace)?;
                let mut ops = Vec::new();
                while !check(tokens, *pos, TokenType::RightBrace) && !check(tokens, *pos, TokenType::EOF) {
                    ops.push(parse_single_handler(tokens, pos, ctx)?);
                }
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::HandlerDef {
                    name,
                    effect_name: None,
                    ops,
                });
                ctx.record_span(id, start_loc);
                Ok(id)
            }

            TokenType::Resume => parse_resume(tokens, pos, ctx),

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
                    // import "path";  or  import "path" as alias;  or  import "dir/*";
                    let path = consume(tokens, pos, TokenType::String)?.expect_str();
                    if path.ends_with("/*") {
                        let dir = path.trim_end_matches("/*").to_string();
                        ImportDecl::Wildcard { path: dir }
                    } else if check(tokens, *pos, TokenType::As) {
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

            TokenType::Identifier if check(tokens, *pos + 1, TokenType::PlusPlus) => {
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                *pos += 1; // consume ++
                consume(tokens, pos, TokenType::Semicolon)?;
                let var_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name.clone()));
                let one_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Int(1));
                let expr = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Add(var_id, one_id));
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr });
                Ok(id)
            }

            TokenType::Identifier if check(tokens, *pos + 1, TokenType::MinusMinus) => {
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                *pos += 1; // consume --
                consume(tokens, pos, TokenType::Semicolon)?;
                let var_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name.clone()));
                let one_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Int(1));
                let expr = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Sub(var_id, one_id));
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr });
                Ok(id)
            }

            TokenType::Identifier if check(tokens, *pos + 1, TokenType::PlusEqual) => {
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                *pos += 1; // consume +=
                let rhs = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::Semicolon)?;
                let var_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name.clone()));
                let expr = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Add(var_id, rhs));
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr });
                Ok(id)
            }

            TokenType::Identifier if check(tokens, *pos + 1, TokenType::MinusEqual) => {
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                *pos += 1; // consume -=
                let rhs = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::Semicolon)?;
                let var_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name.clone()));
                let expr = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Sub(var_id, rhs));
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr });
                Ok(id)
            }

            TokenType::Identifier
                if check(tokens, *pos + 1, TokenType::Dot)
                    && check(tokens, *pos + 2, TokenType::Identifier)
                    && check(tokens, *pos + 3, TokenType::Equal) =>
            {
                let object = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                *pos += 1; // consume dot
                let field = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::Equal)?;
                let expr = parse_expr(tokens, pos, ctx)?;
                consume(tokens, pos, TokenType::Semicolon)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::DotAssign { object, field, expr });
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

            TokenType::Trait => {
                consume(tokens, pos, TokenType::Trait)?;
                let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                consume(tokens, pos, TokenType::LeftBrace)?;
                let mut method_names = Vec::new();
                while !check(tokens, *pos, TokenType::RightBrace) {
                    // fn method_name<T>(params) -> ReturnType;
                    consume(tokens, pos, TokenType::Func)?;
                    let method_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    parse_type_params(tokens, pos);
                    consume(tokens, pos, TokenType::LeftParen)?;
                    // consume params
                    while !check(tokens, *pos, TokenType::RightParen) {
                        *pos += 1;
                    }
                    consume(tokens, pos, TokenType::RightParen)?;
                    let _ = parse_return_type(tokens, pos);
                    consume(tokens, pos, TokenType::Semicolon)?;
                    method_names.push(method_name);
                }
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::TraitDecl { name, methods: method_names });
                Ok(id)
            }

            TokenType::Impl => {
                consume(tokens, pos, TokenType::Impl)?;
                let first_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                // optional <T> bounds after name
                parse_type_params(tokens, pos);
                // bare impl: `impl TypeName { ... }` — no trait
                // trait impl: `impl TraitName for TypeName { ... }`
                let (trait_name, type_name) = if check(tokens, *pos, TokenType::For) {
                    *pos += 1;
                    let type_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    parse_type_params(tokens, pos);
                    (first_name, type_name)
                } else {
                    (String::new(), first_name)
                };
                consume(tokens, pos, TokenType::LeftBrace)?;
                let mut methods = Vec::new();
                while !check(tokens, *pos, TokenType::RightBrace) {
                    consume(tokens, pos, TokenType::Func)?;
                    let method_name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                    parse_type_params(tokens, pos);
                    consume(tokens, pos, TokenType::LeftParen)?;
                    let params = parse_separated(
                        tokens, pos, ctx,
                        TokenType::Comma, TokenType::RightParen,
                        |tokens, pos, _ctx| {
                            let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
                            let ty = parse_type_annot(tokens, pos);
                            Ok(Param { name, ty })
                        },
                    )?;
                    consume(tokens, pos, TokenType::RightParen)?;
                    let _ = parse_return_type(tokens, pos);
                    consume(tokens, pos, TokenType::LeftBrace)?;
                    let body = parse_block(tokens, pos, ctx)?;
                    consume(tokens, pos, TokenType::RightBrace)?;
                    methods.push(ImplMethodDecl { name: method_name, params, body });
                }
                consume(tokens, pos, TokenType::RightBrace)?;
                let id = ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::ImplDecl { trait_name, type_name, methods });
                Ok(id)
            }

            _ => parse_expr_stmt(tokens, pos, ctx),
        },
        _ => parse_expr_stmt(tokens, pos, ctx),
    }
}

/// Parse the increment clause of a C-style for loop (no trailing `;`).
/// Handles: `i++`, `i--`, `i += expr`, `i -= expr`, `i = expr`.
fn parse_for_incr<'a>(
    tokens: &'a [Token],
    pos: &mut usize,
    ctx: &mut ParseCtx,
) -> Result<MetaNodeId, ParseError> {
    let name = consume(tokens, pos, TokenType::Identifier)?.expect_str();
    match tokens.get(*pos).map(|t| t.token_type) {
        Some(TokenType::PlusPlus) => {
            *pos += 1;
            let var_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name.clone()));
            let one_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Int(1));
            let expr = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Add(var_id, one_id));
            Ok(ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr }))
        }
        Some(TokenType::MinusMinus) => {
            *pos += 1;
            let var_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name.clone()));
            let one_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Int(1));
            let expr = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Sub(var_id, one_id));
            Ok(ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr }))
        }
        Some(TokenType::PlusEqual) => {
            *pos += 1;
            let rhs = parse_expr(tokens, pos, ctx)?;
            let var_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name.clone()));
            let expr = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Add(var_id, rhs));
            Ok(ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr }))
        }
        Some(TokenType::MinusEqual) => {
            *pos += 1;
            let rhs = parse_expr(tokens, pos, ctx)?;
            let var_id = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Variable(name.clone()));
            let expr = ctx.ast.insert_expr(&mut ctx.id_provider, MetaExpr::Sub(var_id, rhs));
            Ok(ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr }))
        }
        Some(TokenType::Equal) => {
            *pos += 1;
            let expr = parse_expr(tokens, pos, ctx)?;
            Ok(ctx.ast.insert_stmt(&mut ctx.id_provider, MetaStmt::Assign { name, expr }))
        }
        Some(t) => Err(ParseError::UnexpectedToken {
            found: t,
            expected: TokenType::PlusPlus,
            line: tokens[*pos].line_number,
            col: tokens[*pos].col,
        }),
        None => Err(ParseError::UnexpectedEOF { expected: TokenType::PlusPlus }),
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
) -> Result<MetaNodeId, ParseError> {
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

fn parse_block(tokens: &[Token], pos: &mut usize, ctx: &mut ParseCtx) -> Result<MetaNodeId, ParseError> {
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
