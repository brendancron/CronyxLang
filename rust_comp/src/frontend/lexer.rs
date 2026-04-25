use super::token::*;

#[derive(Debug)]
pub enum ScanError {
    UnterminatedString,
    UnexpectedCharacter(char),
}

fn is_digit(c: char) -> bool {
    c >= '0' && c <= '9'
}

fn is_alpha(c: char) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

fn is_alpha_numeric(c: char) -> bool {
    is_alpha(c) || is_digit(c)
}

fn lex_number(chars: &[char], mut i: usize) -> (i64, usize) {
    let mut acc = String::new();

    while i < chars.len() && is_digit(chars[i]) {
        acc.push(chars[i]);
        i += 1;
    }

    (acc.parse::<i64>().unwrap(), i)
}

fn lex_identifier(chars: &[char], mut i: usize) -> (String, usize) {
    let mut acc = String::new();

    while i < chars.len() && is_alpha_numeric(chars[i]) {
        acc.push(chars[i]);
        i += 1;
    }

    (acc, i)
}

pub fn tokenize(s: &str) -> Result<Vec<Token>, ScanError> {
    let chars: Vec<char> = s.chars().collect();
    let len = chars.len();
    let mut tokens = Vec::new();

    let mut i = 0;
    let mut line_number: usize = 1;
    let mut line_start: usize = 0;
    while i < len {
        let c = chars[i];
        let col = i - line_start + 1;

        match c {
            '\n' => {
                line_number += 1;
                i += 1;
                line_start = i;
            }
            '\r' | ' ' | '\t' => {
                i += 1;
            }

            '(' => {
                tokens.push(Token {
                    token_type: TokenType::LeftParen,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }
            ')' => {
                tokens.push(Token {
                    token_type: TokenType::RightParen,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            '{' => {
                tokens.push(Token {
                    token_type: TokenType::LeftBrace,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            '}' => {
                tokens.push(Token {
                    token_type: TokenType::RightBrace,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            '[' => {
                tokens.push(Token {
                    token_type: TokenType::LeftBracket,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            ']' => {
                tokens.push(Token {
                    token_type: TokenType::RightBracket,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            ',' => {
                tokens.push(Token {
                    token_type: TokenType::Comma,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            '.' => {
                tokens.push(Token {
                    token_type: TokenType::Dot,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            '-' => {
                if i + 1 < len && chars[i + 1] == '-' {
                    tokens.push(Token { token_type: TokenType::MinusMinus, line_number, col, metadata: None });
                    i += 2;
                } else if i + 1 < len && chars[i + 1] == '=' {
                    tokens.push(Token { token_type: TokenType::MinusEqual, line_number, col, metadata: None });
                    i += 2;
                } else if i + 1 < len && chars[i + 1] == '>' {
                    tokens.push(Token { token_type: TokenType::Arrow, line_number, col, metadata: None });
                    i += 2;
                } else {
                    tokens.push(Token { token_type: TokenType::Minus, line_number, col, metadata: None });
                    i += 1;
                }
            }

            '+' => {
                if i + 1 < len && chars[i + 1] == '+' {
                    tokens.push(Token { token_type: TokenType::PlusPlus, line_number, col, metadata: None });
                    i += 2;
                } else if i + 1 < len && chars[i + 1] == '=' {
                    tokens.push(Token { token_type: TokenType::PlusEqual, line_number, col, metadata: None });
                    i += 2;
                } else {
                    tokens.push(Token { token_type: TokenType::Plus, line_number, col, metadata: None });
                    i += 1;
                }
            }

            ';' => {
                tokens.push(Token {
                    token_type: TokenType::Semicolon,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            ':' => {
                if i + 1 < len && chars[i + 1] == ':' {
                    tokens.push(Token {
                        token_type: TokenType::DoubleColon,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 2;
                } else {
                    tokens.push(Token {
                        token_type: TokenType::Colon,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 1;
                }
            }

            '/' => {
                if i + 1 < len && chars[i + 1] == '/' {
                    // Line comment — skip to end of line
                    while i < len && chars[i] != '\n' {
                        i += 1;
                    }
                } else {
                    tokens.push(Token {
                        token_type: TokenType::Slash,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 1;
                }
            }

            '*' => {
                tokens.push(Token {
                    token_type: TokenType::Star,
                    line_number: line_number,
                    col,
                    metadata: None,
                });
                i += 1;
            }

            '!' => {
                if i + 1 < len && chars[i + 1] == '=' {
                    tokens.push(Token {
                        token_type: TokenType::BangEqual,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 2;
                } else {
                    tokens.push(Token {
                        token_type: TokenType::Bang,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 1;
                }
            }

            '=' => {
                if i + 1 < len && chars[i + 1] == '=' {
                    tokens.push(Token {
                        token_type: TokenType::EqualEqual,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 2;
                } else if i + 1 < len && chars[i + 1] == '>' {
                    tokens.push(Token {
                        token_type: TokenType::FatArrow,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 2;
                } else {
                    tokens.push(Token {
                        token_type: TokenType::Equal,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 1;
                }
            }

            '>' => {
                if i + 1 < len && chars[i + 1] == '=' {
                    tokens.push(Token {
                        token_type: TokenType::GreaterEqual,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 2;
                } else {
                    tokens.push(Token {
                        token_type: TokenType::Greater,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 1;
                }
            }

            '<' => {
                if i + 1 < len && chars[i + 1] == '=' {
                    tokens.push(Token {
                        token_type: TokenType::LessEqual,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 2;
                } else {
                    tokens.push(Token {
                        token_type: TokenType::Less,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                    i += 1;
                }
            }

            '&' => {
                if i + 1 < len && chars[i + 1] == '&' {
                    tokens.push(Token { token_type: TokenType::AmpAmp, line_number, col, metadata: None });
                    i += 2;
                } else {
                    return Err(ScanError::UnexpectedCharacter('&'));
                }
            }

            '|' => {
                if i + 1 < len && chars[i + 1] == '|' {
                    tokens.push(Token { token_type: TokenType::PipePipe, line_number, col, metadata: None });
                    i += 2;
                } else {
                    return Err(ScanError::UnexpectedCharacter('|'));
                }
            }

            c if is_digit(c) => {
                let (num, j) = lex_number(&chars, i);
                tokens.push(Token {
                    token_type: TokenType::Number,
                    line_number: line_number,
                    col,
                    metadata: Some(TokenMetadata::Int(num)),
                });
                i = j;
            }

            c if is_alpha(c) => {
                let (name, j) = lex_identifier(&chars, i);

                // Keywords
                let tok_type = match name.as_str() {
                    "as" => TokenType::As,
                    "ctl" => TokenType::Ctl,
                    "defer" => TokenType::Defer,
                    "effect" => TokenType::Effect,
                    "else" => TokenType::Else,
                    "embed" => TokenType::Embed,
                    "false" => TokenType::False,
                    "from" => TokenType::From,
                    "fn" => TokenType::Func,
                    "for" => TokenType::For,
                    "gen" => TokenType::Gen,
                    "handle" => TokenType::Handle,
                    "handler" => TokenType::Handler,
                    "if" => TokenType::If,
                    "impl" => TokenType::Impl,
                    "import" => TokenType::Import,
                    "in" => TokenType::In,
                    "meta" => TokenType::Meta,
                    "enum" => TokenType::Enum,
                    "match" => TokenType::Match,
                    "print" => TokenType::Print,
                    "resume" => TokenType::Resume,
                    "return" => TokenType::Return,
                    "run" => TokenType::Run,
                    "struct" => TokenType::Struct,
                    "trait" => TokenType::Trait,
                    "true" => TokenType::True,
                    "typeof" => TokenType::Typeof,
                    "var" => TokenType::Var,
                    "while" => TokenType::While,
                    "with" => TokenType::With,
                    _ => TokenType::Identifier,
                };

                if tok_type == TokenType::Identifier {
                    tokens.push(Token {
                        token_type: tok_type,
                        line_number: line_number,
                        col,
                        metadata: Some(TokenMetadata::String(name)),
                    });
                } else {
                    tokens.push(Token {
                        token_type: tok_type,
                        line_number: line_number,
                        col,
                        metadata: None,
                    });
                }

                i = j;
            }

            '"' => {
                let mut acc = String::new();
                let mut j = i + 1;

                while j < len {
                    match chars[j] {
                        '"' => {
                            tokens.push(Token {
                                token_type: TokenType::String,
                                line_number: line_number,
                                col,
                                metadata: Some(TokenMetadata::String(acc)),
                            });
                            i = j + 1;
                            break;
                        }
                        '\\' if j + 1 < len => {
                            match chars[j + 1] {
                                'n'  => { acc.push('\n'); j += 2; }
                                't'  => { acc.push('\t'); j += 2; }
                                '\\' => { acc.push('\\'); j += 2; }
                                '"'  => { acc.push('"');  j += 2; }
                                c    => { acc.push('\\'); acc.push(c); j += 2; }
                            }
                        }
                        c => {
                            acc.push(c);
                            j += 1;
                        }
                    }
                }

                if j >= len {
                    return Err(ScanError::UnterminatedString);
                }
            }

            _ => return Err(ScanError::UnexpectedCharacter(c)),
        }
    }

    tokens.push(Token {
        token_type: TokenType::EOF,
        line_number: line_number,
        col: 0,
        metadata: None,
    });
    Ok(tokens)
}
