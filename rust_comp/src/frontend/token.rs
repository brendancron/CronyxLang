#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TokenType {
    // Single-character tokens
    LeftParen,
    RightParen,
    LeftBrace,
    RightBrace,
    LeftBracket,
    RightBracket,
    Comma,
    Dot,
    Minus,
    Plus,
    Semicolon,
    Colon,
    Slash,
    Star,

    // One or two character tokens
    Bang,
    BangEqual,
    Equal,
    EqualEqual,
    FatArrow,
    Greater,
    GreaterEqual,
    Less,
    LessEqual,
    DoubleColon,
    AmpAmp,
    PipePipe,
    PlusEqual,
    MinusEqual,
    PlusPlus,
    MinusMinus,
    Arrow,

    // Literals
    Identifier,
    String,
    Number,

    // Keywords
    And,
    As,
    Ctl,
    Defer,
    Effect,
    Else,
    Embed,
    Enum,
    False,
    For,
    From,
    Func,
    Gen,
    If,
    Impl,
    Import,
    In,
    Match,
    Meta,
    Or,
    Print,
    Resume,
    Return,
    Struct,
    Trait,
    True,
    Typeof,
    Var,
    While,
    With,

    // End of file
    EOF,
}

#[derive(PartialEq, Debug)]
pub enum TokenMetadata {
    Int(i64),
    String(String),
}

impl Token {
    pub fn expect_int(&self) -> i64 {
        match &self.metadata {
            Some(TokenMetadata::Int(n)) => *n,
            Some(other) => panic!("expected Int metadata, found {:?}", other),
            None => panic!("expected Int metadata, found None"),
        }
    }

    pub fn expect_str(&self) -> String {
        match &self.metadata {
            Some(TokenMetadata::String(s)) => s.to_string(),
            Some(other) => panic!("expected String metadata, found {:?}", other),
            None => panic!("expected String metadata, found None"),
        }
    }
}

#[derive(PartialEq, Debug)]
pub struct Token {
    pub token_type: TokenType,
    pub line_number: usize,
    pub col: usize,
    pub metadata: Option<TokenMetadata>,
}
