use crate::error::{CompileError, CompileResult};
use crate::token::{Token, TokenKind};

pub struct Lexer {
    source: Vec<char>,
    pos: usize,
    line: usize,
    col: usize,
    indent_stack: Vec<usize>,
    pending: Vec<Token>,
    at_line_start: bool,
    errors: Vec<CompileError>,
}

impl Lexer {
    pub fn new(source: &str) -> Self {
        Lexer {
            source: source.chars().collect(),
            pos: 0,
            line: 1,
            col: 1,
            indent_stack: vec![0],
            pending: Vec::new(),
            at_line_start: true,
            errors: Vec::new(),
        }
    }

    pub fn tokenize(&mut self) -> CompileResult<Vec<Token>> {
        let mut tokens = Vec::new();

        while self.pos < self.source.len() {
            tokens.extend(self.pending.drain(..));

            if self.at_line_start {
                self.at_line_start = false;
                self.handle_indentation();
                tokens.extend(self.pending.drain(..));
                continue;
            }

            let Some(ch) = self.peek() else { break };

            match ch {
                '\n' => {
                    tokens.push(self.make_token(TokenKind::Newline));
                    self.advance();
                    self.at_line_start = true;
                }
                ' ' | '\t' | '\r' => { self.advance(); }
                '#' => self.skip_comment(),
                '"' => tokens.extend(self.read_string()),
                '\'' => tokens.push(self.read_rune()),
                '`' => tokens.push(self.read_label()),
                '0'..='9' => tokens.push(self.read_number()),
                _ if ch.is_alphabetic() || ch == '_' => tokens.push(self.read_identifier()),
                _ => {
                    if let Some(tok) = self.read_operator() {
                        tokens.push(tok);
                    } else {
                        self.errors.push(CompileError::new(
                            format!("unexpected character '{}'", ch),
                            self.line, self.col,
                        ));
                        self.advance();
                    }
                }
            }
        }

        // Emit remaining dedents
        while self.indent_stack.len() > 1 {
            self.indent_stack.pop();
            tokens.push(Token::new(TokenKind::Dedent, self.line, self.col));
        }
        tokens.push(Token::new(TokenKind::Eof, self.line, self.col));

        if !self.errors.is_empty() {
            return Err(self.errors[0].clone());
        }
        Ok(tokens)
    }

    // ── Character access ──

    fn peek(&self) -> Option<char> {
        self.source.get(self.pos).copied()
    }

    fn peek_next(&self) -> Option<char> {
        self.source.get(self.pos + 1).copied()
    }

    fn advance(&mut self) -> Option<char> {
        let ch = self.source.get(self.pos).copied()?;
        self.pos += 1;
        if ch == '\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        Some(ch)
    }

    fn make_token(&self, kind: TokenKind) -> Token {
        Token::new(kind, self.line, self.col)
    }

    // ── Indentation ──

    fn handle_indentation(&mut self) {
        let mut spaces = 0;
        while self.peek() == Some(' ') {
            self.advance();
            spaces += 1;
        }

        // Skip blank lines and comment-only lines
        match self.peek() {
            Some('\n') | Some('#') | None => return,
            _ => {}
        }

        let current = self.current_indent();

        if spaces > current {
            self.indent_stack.push(spaces);
            self.pending.push(Token::new(TokenKind::Indent, self.line, self.col));
        } else if spaces < current {
            while self.current_indent() > spaces {
                self.indent_stack.pop();
                self.pending.push(Token::new(TokenKind::Dedent, self.line, self.col));
            }
            if self.current_indent() != spaces {
                self.errors.push(CompileError::new(
                    "inconsistent indentation",
                    self.line, self.col,
                ));
            }
        }
    }

    fn current_indent(&self) -> usize {
        self.indent_stack.last().copied().unwrap_or(0)
    }

    // ── Readers ──

    fn skip_comment(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == '\n' { break; }
            self.advance();
        }
    }

    fn read_string(&mut self) -> Vec<Token> {
        let start_line = self.line;
        let start_col = self.col;
        self.advance(); // skip "

        let mut buf = String::new();
        let mut tokens = Vec::new();
        let mut has_interp = false;

        while let Some(ch) = self.peek() {
            match ch {
                '"' => {
                    self.advance();
                    if has_interp {
                        tokens.push(Token::new(TokenKind::StringInterpEnd(buf), self.line, self.col));
                    } else {
                        tokens.push(Token::new(TokenKind::StringLit(buf), start_line, start_col));
                    }
                    return tokens;
                }
                '{' => {
                    self.advance();
                    if !has_interp {
                        has_interp = true;
                        tokens.push(Token::new(TokenKind::StringInterpStart, start_line, start_col));
                    }
                    tokens.push(Token::new(TokenKind::StringLit(buf.clone()), self.line, self.col));
                    buf.clear();

                    // Read expression inside {} as identifier
                    let mut expr = String::new();
                    let mut depth = 1;
                    while let Some(c) = self.peek() {
                        if c == '}' { depth -= 1; if depth == 0 { self.advance(); break; } }
                        if c == '{' { depth += 1; }
                        expr.push(c);
                        self.advance();
                    }
                    tokens.push(Token::new(TokenKind::Ident(expr), self.line, self.col));
                }
                '\\' => {
                    self.advance();
                    buf.push(match self.peek() {
                        Some('n') => { self.advance(); '\n' }
                        Some('t') => { self.advance(); '\t' }
                        Some('\\') => { self.advance(); '\\' }
                        Some('"') => { self.advance(); '"' }
                        Some('{') => { self.advance(); '{' }
                        _ => '\\',
                    });
                }
                '\n' => {
                    self.errors.push(CompileError::new(
                        "unterminated string literal",
                        start_line, start_col,
                    ));
                    break;
                }
                _ => { self.advance(); buf.push(ch); }
            }
        }

        tokens.push(Token::new(TokenKind::StringLit(buf), start_line, start_col));
        tokens
    }

    fn read_rune(&mut self) -> Token {
        let start_line = self.line;
        let start_col = self.col;
        self.advance(); // skip '

        let ch = match self.peek() {
            Some('\\') => {
                self.advance();
                match self.advance() {
                    Some('n') => '\n',
                    Some('t') => '\t',
                    Some('\\') => '\\',
                    Some('\'') => '\'',
                    _ => '\\',
                }
            }
            Some(c) => { self.advance(); c }
            None => {
                self.errors.push(CompileError::new(
                    "unterminated rune literal", start_line, start_col,
                ));
                '\0'
            }
        };

        if self.peek() == Some('\'') {
            self.advance();
        } else {
            self.errors.push(CompileError::new(
                "unterminated rune literal", start_line, start_col,
            ));
        }

        Token::new(TokenKind::RuneLit(ch), start_line, start_col)
    }

    fn read_number(&mut self) -> Token {
        let start_line = self.line;
        let start_col = self.col;
        let mut num = String::new();
        let mut is_float = false;

        while let Some(ch) = self.peek() {
            match ch {
                '0'..='9' => { num.push(ch); self.advance(); }
                '_' => { self.advance(); } // digit separator, skip
                '.' if !is_float => {
                    // Check for range operator (..)
                    if self.peek_next() == Some('.') { break; }
                    if self.peek_next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
                        is_float = true;
                        num.push('.');
                        self.advance();
                    } else {
                        break;
                    }
                }
                _ => break,
            }
        }

        let kind = if is_float {
            match num.parse::<f64>() {
                Ok(val) => TokenKind::FloatLit(val),
                Err(_) => {
                    self.errors.push(CompileError::new(
                        format!("invalid float literal '{}'", num),
                        start_line, start_col,
                    ));
                    TokenKind::FloatLit(0.0)
                }
            }
        } else {
            match num.parse::<i64>() {
                Ok(val) => TokenKind::IntLit(val),
                Err(_) => {
                    self.errors.push(CompileError::new(
                        format!("integer literal '{}' is too large", num),
                        start_line, start_col,
                    ));
                    TokenKind::IntLit(0)
                }
            }
        };

        Token::new(kind, start_line, start_col)
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

        Token::new(TokenKind::from_keyword(&word), start_line, start_col)
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

        if name.is_empty() {
            self.errors.push(CompileError::new(
                "empty label", start_line, start_col,
            ));
        }

        Token::new(TokenKind::Label(name), start_line, start_col)
    }

    fn read_operator(&mut self) -> Option<Token> {
        let line = self.line;
        let col = self.col;

        let kind = match self.peek()? {
            '+' => { self.advance(); TokenKind::Plus }
            '-' => {
                self.advance();
                if self.peek() == Some('>') { self.advance(); TokenKind::Arrow }
                else { TokenKind::Minus }
            }
            '*' => { self.advance(); TokenKind::Star }
            '/' => { self.advance(); TokenKind::Slash }
            '%' => { self.advance(); TokenKind::Percent }
            '=' => {
                self.advance();
                if self.peek() == Some('=') { self.advance(); TokenKind::EqEq }
                else { TokenKind::Eq }
            }
            '!' => {
                self.advance();
                if self.peek() == Some('=') { self.advance(); TokenKind::NotEq }
                else { TokenKind::Bang }
            }
            '<' => {
                self.advance();
                if self.peek() == Some('=') { self.advance(); TokenKind::LessEq }
                else { TokenKind::Less }
            }
            '>' => {
                self.advance();
                if self.peek() == Some('=') { self.advance(); TokenKind::GreaterEq }
                else { TokenKind::Greater }
            }
            '.' => {
                self.advance();
                if self.peek() == Some('.') {
                    self.advance();
                    if self.peek() == Some('<') { self.advance(); TokenKind::DotDotLess }
                    else { TokenKind::DotDot }
                } else { TokenKind::Dot }
            }
            ':' => { self.advance(); TokenKind::Colon }
            ',' => { self.advance(); TokenKind::Comma }
            '|' => { self.advance(); TokenKind::Pipe }
            '?' => { self.advance(); TokenKind::Question }
            '@' => { self.advance(); TokenKind::At }
            '$' => { self.advance(); TokenKind::Dollar }
            '~' => { self.advance(); TokenKind::Tilde }
            '&' => { self.advance(); TokenKind::Ampersand }
            '(' => { self.advance(); TokenKind::LParen }
            ')' => { self.advance(); TokenKind::RParen }
            '[' => { self.advance(); TokenKind::LBracket }
            ']' => { self.advance(); TokenKind::RBracket }
            '{' => { self.advance(); TokenKind::LBrace }
            '}' => { self.advance(); TokenKind::RBrace }
            _ => return None,
        };

        Some(Token::new(kind, line, col))
    }
}
