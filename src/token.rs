/// Token types for the Iris language

#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    // Literals
    IntLit(i64),
    FloatLit(f64),
    StringLit(String),
    StringInterpStart,
    StringInterpEnd(String),
    RuneLit(char),
    BoolLit(bool),

    // Identifiers and labels
    Ident(String),
    Label(String),

    // Keywords
    Fn, Let, Var, Const,
    If, Elif, Else,
    While, For, In,
    Break, Continue, Return, Result,
    Block, Spawn, Detach,
    Type, Enum, Concept,
    Import, From, Export,
    When, IsMain,
    Case, Of, Discard,
    Not, And, Or,
    Some, None,
    Raise, Quit, Own,
    Template, Macro, After,

    // Operators
    Plus,        // +
    Minus,       // -
    Star,        // *
    Slash,       // /
    Percent,     // %
    Eq,          // =
    EqEq,        // ==
    NotEq,       // !=
    Less,        // <
    LessEq,      // <=
    Greater,     // >
    GreaterEq,   // >=
    Arrow,       // ->
    DotDot,      // ..
    DotDotLess,  // ..<
    Dot,         // .
    Colon,       // :
    Comma,       // ,
    Pipe,        // |
    Bang,        // !
    Question,    // ?
    At,          // @
    Dollar,      // $
    Tilde,       // ~
    Ampersand,   // &

    // Delimiters
    LParen,      // (
    RParen,      // )
    LBracket,    // [
    RBracket,    // ]
    LBrace,      // {
    RBrace,      // }

    // Structure
    Indent,
    Dedent,
    Newline,
    Eof,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Token {
    pub kind: TokenKind,
    pub line: usize,
    pub col: usize,
}

impl Token {
    pub fn new(kind: TokenKind, line: usize, col: usize) -> Self {
        Token { kind, line, col }
    }
}

impl TokenKind {
    pub fn from_keyword(word: &str) -> TokenKind {
        match word {
            "fn" => TokenKind::Fn,
            "let" => TokenKind::Let,
            "var" => TokenKind::Var,
            "const" => TokenKind::Const,
            "if" => TokenKind::If,
            "elif" => TokenKind::Elif,
            "else" => TokenKind::Else,
            "while" => TokenKind::While,
            "for" => TokenKind::For,
            "in" => TokenKind::In,
            "break" => TokenKind::Break,
            "continue" => TokenKind::Continue,
            "return" => TokenKind::Return,
            "result" => TokenKind::Result,
            "block" => TokenKind::Block,
            "spawn" => TokenKind::Spawn,
            "detach" => TokenKind::Detach,
            "type" => TokenKind::Type,
            "enum" => TokenKind::Enum,
            "concept" => TokenKind::Concept,
            "import" => TokenKind::Import,
            "from" => TokenKind::From,
            "export" => TokenKind::Export,
            "when" => TokenKind::When,
            "isMain" => TokenKind::IsMain,
            "case" => TokenKind::Case,
            "of" => TokenKind::Of,
            "discard" => TokenKind::Discard,
            "not" => TokenKind::Not,
            "and" => TokenKind::And,
            "or" => TokenKind::Or,
            "true" => TokenKind::BoolLit(true),
            "false" => TokenKind::BoolLit(false),
            "some" => TokenKind::Some,
            "none" => TokenKind::None,
            "raise" => TokenKind::Raise,
            "quit" => TokenKind::Quit,
            "own" => TokenKind::Own,
            "template" => TokenKind::Template,
            "macro" => TokenKind::Macro,
            "after" => TokenKind::After,
            _ => TokenKind::Ident(word.to_string()),
        }
    }
}
