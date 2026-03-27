use crate::token::{Token, TokenKind, keyword_or_ident};

pub struct Lexer {
    source: Vec<char>,
    pos: usize,
    line: usize,
    col: usize,
    indent_stack: Vec<usize>,
    pending_tokens: Vec<Token>,
    at_line_start: bool,
}

impl Lexer {
    pub fn new(source: &str) -> Self {
        Lexer {
            source: source.chars().collect(),
            pos: 0,
            line: 1,
            col: 1,
            indent_stack: vec![0],
            pending_tokens: Vec::new(),
            at_line_start: true,
        }
    }

    fn peek(&self) -> Option<char> {
        self.source.get(self.pos).copied()
    }

    fn peek_next(&self) -> Option<char> {
        self.source.get(self.pos + 1).copied()
    }

    fn advance(&mut self) -> Option<char> {
        let ch = self.source.get(self.pos).copied();
        if let Some(c) = ch {
            self.pos += 1;
            if c == '\n' {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }
        ch
    }

    fn skip_comment(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == '\n' {
                break;
            }
            self.advance();
        }
    }

    fn handle_indentation(&mut self) {
        let mut spaces = 0;
        while let Some(' ') = self.peek() {
            self.advance();
            spaces += 1;
        }

        // Skip blank lines and comment-only lines
        if let Some(ch) = self.peek() {
            if ch == '\n' || ch == '#' {
                return;
            }
        } else {
            return;
        }

        let current_indent = *self.indent_stack.last().unwrap();

        if spaces > current_indent {
            self.indent_stack.push(spaces);
            self.pending_tokens.push(Token::new(
                TokenKind::Indent,
                self.line,
                self.col,
            ));
        } else if spaces < current_indent {
            while *self.indent_stack.last().unwrap() > spaces {
                self.indent_stack.pop();
                self.pending_tokens.push(Token::new(
                    TokenKind::Dedent,
                    self.line,
                    self.col,
                ));
            }
            if *self.indent_stack.last().unwrap() != spaces {
                self.pending_tokens.push(Token::new(
                    TokenKind::Ident("IndentationError".to_string()),
                    self.line,
                    self.col,
                ));
            }
        }
    }

    fn read_string(&mut self) -> Token {
        let start_line = self.line;
        let start_col = self.col;
        self.advance(); // skip opening "

        let mut result = String::new();

        while let Some(ch) = self.peek() {
            match ch {
                '"' => {
                    self.advance();
                    return Token::new(
                        TokenKind::StringLit(result),
                        start_line,
                        start_col,
                    );
                }
                '\\' => {
                    self.advance();
                    match self.peek() {
                        Some('n') => { self.advance(); result.push('\n'); }
                        Some('t') => { self.advance(); result.push('\t'); }
                        Some('\\') => { self.advance(); result.push('\\'); }
                        Some('"') => { self.advance(); result.push('"'); }
                        Some('{') => { self.advance(); result.push('{'); }
                        _ => result.push('\\'),
                    }
                }
                '\n' => {
                    break;
                }
                _ => {
                    self.advance();
                    result.push(ch);
                }
            }
        }

        Token::new(
            TokenKind::StringLit(result),
            start_line,
            start_col,
        )
    }

    fn read_rune(&mut self) -> Token {
        let start_line = self.line;
        let start_col = self.col;
        self.advance(); // skip opening '

        let ch = if let Some('\\') = self.peek() {
            self.advance();
            match self.peek() {
                Some('n') => { self.advance(); '\n' }
                Some('t') => { self.advance(); '\t' }
                Some('\\') => { self.advance(); '\\' }
                Some('\'') => { self.advance(); '\'' }
                _ => '\\',
            }
        } else if let Some(c) = self.advance() {
            c
        } else {
            '\0'
        };

        // skip closing '
        if let Some('\'') = self.peek() {
            self.advance();
        }

        Token::new(TokenKind::RuneLit(ch), start_line, start_col)
    }

    fn read_number(&mut self) -> Token {
        let start_line = self.line;
        let start_col = self.col;
        let mut num = String::new();
        let mut is_float = false;

        while let Some(ch) = self.peek() {
            if ch.is_ascii_digit() || ch == '_' {
                if ch != '_' {
                    num.push(ch);
                }
                self.advance();
            } else if ch == '.' && !is_float {
                if let Some(next) = self.peek_next() {
                    if next == '.' {
                        // This is `..` range operator, not a decimal point
                        break;
                    }
                    if next.is_ascii_digit() {
                        is_float = true;
                        num.push('.');
                        self.advance();
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if is_float {
            let val: f64 = num.parse().unwrap_or(0.0);
            Token::new(TokenKind::FloatLit(val), start_line, start_col)
        } else {
            let val: i64 = num.parse().unwrap_or(0);
            Token::new(TokenKind::IntLit(val), start_line, start_col)
        }
    }

    fn read_identifier(&mut self) -> Token {
        let start_line = self.line;
        let start_col = self.col;
        let mut word = String::new();

        while let Some(ch) = self.peek() {
            if ch.is_alphanumeric() || ch == '_' {
                word.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        let kind = keyword_or_ident(&word);
        Token::new(kind, start_line, start_col)
    }

    fn read_label(&mut self) -> Token {
        let start_line = self.line;
        let start_col = self.col;
        self.advance(); // skip `

        let mut name = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_alphanumeric() || ch == '_' {
                name.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        Token::new(TokenKind::Label(name), start_line, start_col)
    }

    pub fn tokenize(&mut self) -> Vec<Token> {
        let mut tokens = Vec::new();

        while self.pos < self.source.len() {
            // Drain pending indent/dedent tokens
            if !self.pending_tokens.is_empty() {
                tokens.append(&mut self.pending_tokens);
            }

            // Handle line start (indentation)
            if self.at_line_start {
                self.at_line_start = false;
                self.handle_indentation();
                if !self.pending_tokens.is_empty() {
                    tokens.append(&mut self.pending_tokens);
                }
                continue;
            }

            let ch = match self.peek() {
                Some(c) => c,
                None => break,
            };

            match ch {
                '\n' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Newline, line, col));
                    self.at_line_start = true;
                }
                ' ' | '\t' | '\r' => {
                    self.advance();
                }
                '#' => {
                    self.skip_comment();
                }
                '"' => {
                    tokens.push(self.read_string());
                }
                '\'' => {
                    tokens.push(self.read_rune());
                }
                '`' => {
                    tokens.push(self.read_label());
                }
                '0'..='9' => {
                    tokens.push(self.read_number());
                }
                '+' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Plus, line, col));
                }
                '-' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    if self.peek() == Some('>') {
                        self.advance();
                        tokens.push(Token::new(TokenKind::Arrow, line, col));
                    } else {
                        tokens.push(Token::new(TokenKind::Minus, line, col));
                    }
                }
                '*' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Star, line, col));
                }
                '/' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Slash, line, col));
                }
                '%' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Percent, line, col));
                }
                '=' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    if self.peek() == Some('=') {
                        self.advance();
                        tokens.push(Token::new(TokenKind::EqEq, line, col));
                    } else {
                        tokens.push(Token::new(TokenKind::Eq, line, col));
                    }
                }
                '!' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    if self.peek() == Some('=') {
                        self.advance();
                        tokens.push(Token::new(TokenKind::NotEq, line, col));
                    } else {
                        tokens.push(Token::new(TokenKind::Bang, line, col));
                    }
                }
                '<' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    if self.peek() == Some('=') {
                        self.advance();
                        tokens.push(Token::new(TokenKind::LessEq, line, col));
                    } else {
                        tokens.push(Token::new(TokenKind::Less, line, col));
                    }
                }
                '>' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    if self.peek() == Some('=') {
                        self.advance();
                        tokens.push(Token::new(TokenKind::GreaterEq, line, col));
                    } else {
                        tokens.push(Token::new(TokenKind::Greater, line, col));
                    }
                }
                '.' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    if self.peek() == Some('.') {
                        self.advance();
                        if self.peek() == Some('<') {
                            self.advance();
                            tokens.push(Token::new(TokenKind::DotDotLess, line, col));
                        } else {
                            tokens.push(Token::new(TokenKind::DotDot, line, col));
                        }
                    } else {
                        tokens.push(Token::new(TokenKind::Dot, line, col));
                    }
                }
                ':' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Colon, line, col));
                }
                ',' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Comma, line, col));
                }
                '|' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Pipe, line, col));
                }
                '?' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Question, line, col));
                }
                '@' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::At, line, col));
                }
                '$' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Dollar, line, col));
                }
                '~' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Tilde, line, col));
                }
                '&' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::Ampersand, line, col));
                }
                '(' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::LParen, line, col));
                }
                ')' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::RParen, line, col));
                }
                '[' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::LBracket, line, col));
                }
                ']' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::RBracket, line, col));
                }
                '{' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::LBrace, line, col));
                }
                '}' => {
                    let line = self.line;
                    let col = self.col;
                    self.advance();
                    tokens.push(Token::new(TokenKind::RBrace, line, col));
                }
                _ if ch.is_alphabetic() || ch == '_' => {
                    tokens.push(self.read_identifier());
                }
                _ => {
                    self.advance(); // skip unknown
                }
            }
        }

        // Emit remaining dedents at EOF
        while self.indent_stack.len() > 1 {
            self.indent_stack.pop();
            tokens.push(Token::new(TokenKind::Dedent, self.line, self.col));
        }

        tokens.push(Token::new(TokenKind::Eof, self.line, self.col));
        tokens
    }
}
