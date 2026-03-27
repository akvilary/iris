use crate::ast::*;
use crate::token::{Token, TokenKind};

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, pos: 0 }
    }

    fn peek(&self) -> &TokenKind {
        self.tokens
            .get(self.pos)
            .map(|t| &t.kind)
            .unwrap_or(&TokenKind::Eof)
    }

    fn at(&self, kind: &TokenKind) -> bool {
        std::mem::discriminant(self.peek()) == std::mem::discriminant(kind)
    }

    fn advance(&mut self) -> &Token {
        let tok = &self.tokens[self.pos];
        if self.pos < self.tokens.len() - 1 {
            self.pos += 1;
        }
        tok
    }

    fn expect(&mut self, kind: &TokenKind) -> &Token {
        if !self.at(kind) {
            let tok = &self.tokens[self.pos];
            panic!(
                "{}:{}: expected {:?}, got {:?}",
                tok.line, tok.col, kind, tok.kind
            );
        }
        self.advance()
    }

    fn skip_newlines(&mut self) {
        while self.at(&TokenKind::Newline) {
            self.advance();
        }
    }

    fn current_line(&self) -> usize {
        self.tokens.get(self.pos).map(|t| t.line).unwrap_or(0)
    }

    // ── Parsing entry ──

    pub fn parse(&mut self) -> Vec<Stmt> {
        let mut stmts = Vec::new();
        self.skip_newlines();
        while !self.at(&TokenKind::Eof) {
            stmts.push(self.parse_stmt());
            self.skip_newlines();
        }
        stmts
    }

    // ── Statements ──

    fn parse_stmt(&mut self) -> Stmt {
        match self.peek().clone() {
            TokenKind::Let => self.parse_let(),
            TokenKind::Var => self.parse_var(),
            TokenKind::Const => self.parse_const(),
            TokenKind::Fn => self.parse_fn(),
            TokenKind::If => self.parse_if_stmt(),
            TokenKind::While => self.parse_while(),
            TokenKind::For => self.parse_for(),
            TokenKind::Break => self.parse_break(),
            TokenKind::Continue => self.parse_continue(),
            TokenKind::Return => { self.advance(); Stmt::Return }
            TokenKind::Result => self.parse_result_assign(),
            TokenKind::Block => self.parse_block(),
            TokenKind::Spawn => self.parse_spawn(),
            TokenKind::Import => self.parse_import(),
            TokenKind::Raise => self.parse_raise(),
            TokenKind::Discard => { self.advance(); Stmt::Discard }
            _ => self.parse_expr_or_assign(),
        }
    }

    fn parse_let(&mut self) -> Stmt {
        self.advance(); // skip 'let'
        let name = self.parse_ident_name();
        let type_ann = if self.at(&TokenKind::Colon) {
            self.advance();
            Some(self.parse_type())
        } else {
            None
        };
        let value = if self.at(&TokenKind::Eq) {
            self.advance();
            Some(self.parse_expr())
        } else {
            None
        };
        Stmt::LetDecl { name, type_ann, value }
    }

    fn parse_var(&mut self) -> Stmt {
        self.advance(); // skip 'var'
        let name = self.parse_ident_name();
        let type_ann = if self.at(&TokenKind::Colon) {
            self.advance();
            Some(self.parse_type())
        } else {
            None
        };
        let value = if self.at(&TokenKind::Eq) {
            self.advance();
            Some(self.parse_expr())
        } else {
            None
        };
        Stmt::VarDecl { name, type_ann, value }
    }

    fn parse_const(&mut self) -> Stmt {
        self.advance(); // skip 'const'
        let name = self.parse_ident_name();
        let public = if self.at(&TokenKind::Star) {
            self.advance();
            true
        } else {
            false
        };
        let type_ann = if self.at(&TokenKind::Colon) {
            self.advance();
            Some(self.parse_type())
        } else {
            None
        };
        self.expect(&TokenKind::Eq);
        let value = self.parse_expr();
        Stmt::ConstDecl { name, public, type_ann, value }
    }

    fn parse_fn(&mut self) -> Stmt {
        self.advance(); // skip 'fn'
        let name = self.parse_ident_name();
        let public = if self.at(&TokenKind::Star) {
            self.advance();
            true
        } else {
            false
        };

        // Params
        self.expect(&TokenKind::LParen);
        let params = self.parse_params();
        self.expect(&TokenKind::RParen);

        // Return type
        let mut return_type = None;
        let mut error_types = Vec::new();
        if self.at(&TokenKind::Arrow) {
            self.advance();
            return_type = Some(self.parse_type());
            // Error types: | !Error1 | !Error2
            while self.at(&TokenKind::Pipe) {
                self.advance();
                self.expect(&TokenKind::Bang);
                error_types.push(self.parse_type());
            }
        }

        // Check for error-only: fn foo() !Error:
        if self.at(&TokenKind::Bang) {
            self.advance();
            error_types.push(self.parse_type());
        }

        self.expect(&TokenKind::Colon);
        self.skip_newlines();
        let body = self.parse_block_body();

        Stmt::FnDecl {
            name,
            public,
            params,
            return_type,
            error_types,
            body,
        }
    }

    fn parse_params(&mut self) -> Vec<Param> {
        let mut params = Vec::new();
        while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
            let ownership = if self.at(&TokenKind::Own) {
                self.advance();
                if self.at(&TokenKind::Var) {
                    self.advance();
                    Ownership::OwnVar
                } else {
                    Ownership::Own
                }
            } else if self.at(&TokenKind::Var) {
                self.advance();
                Ownership::VarBorrow
            } else {
                Ownership::Borrow
            };

            let name = self.parse_ident_name();
            self.expect(&TokenKind::Colon);
            let type_ann = self.parse_type();

            params.push(Param { name, type_ann, ownership });

            if self.at(&TokenKind::Comma) {
                self.advance();
            }
        }
        params
    }

    fn parse_if_stmt(&mut self) -> Stmt {
        let mut branches = Vec::new();
        let mut else_body = None;

        // if
        self.advance();
        let cond = self.parse_expr();
        self.expect(&TokenKind::Colon);
        self.skip_newlines();
        let body = self.parse_block_body();
        branches.push((cond, body));

        // elif
        while self.at(&TokenKind::Elif) {
            self.advance();
            let cond = self.parse_expr();
            self.expect(&TokenKind::Colon);
            self.skip_newlines();
            let body = self.parse_block_body();
            branches.push((cond, body));
        }

        // else
        if self.at(&TokenKind::Else) {
            self.advance();
            self.expect(&TokenKind::Colon);
            self.skip_newlines();
            else_body = Some(self.parse_block_body());
        }

        Stmt::If { branches, else_body }
    }

    fn parse_while(&mut self) -> Stmt {
        self.advance(); // skip 'while'
        let condition = self.parse_expr();
        let label = self.try_parse_label();
        self.expect(&TokenKind::Colon);
        self.skip_newlines();
        let body = self.parse_block_body();
        Stmt::While { condition, label, body }
    }

    fn parse_for(&mut self) -> Stmt {
        self.advance(); // skip 'for'
        let var = self.parse_ident_name();
        self.expect(&TokenKind::In);
        let iter = self.parse_expr();
        let label = self.try_parse_label();
        self.expect(&TokenKind::Colon);
        self.skip_newlines();
        let body = self.parse_block_body();

        let else_body = if self.at(&TokenKind::Else) {
            self.advance();
            self.expect(&TokenKind::Colon);
            self.skip_newlines();
            Some(self.parse_block_body())
        } else {
            None
        };

        Stmt::For { var, iter, label, body, else_body }
    }

    fn parse_break(&mut self) -> Stmt {
        self.advance();
        let label = if let TokenKind::Label(_) = self.peek() {
            if let TokenKind::Label(name) = self.advance().kind.clone() {
                Some(name)
            } else {
                None
            }
        } else {
            None
        };
        Stmt::Break(label)
    }

    fn parse_continue(&mut self) -> Stmt {
        self.advance();
        let label = if let TokenKind::Label(_) = self.peek() {
            if let TokenKind::Label(name) = self.advance().kind.clone() {
                Some(name)
            } else {
                None
            }
        } else {
            None
        };
        Stmt::Continue(label)
    }

    fn parse_result_assign(&mut self) -> Stmt {
        self.advance(); // skip 'result'
        self.expect(&TokenKind::Eq);
        let value = self.parse_expr();
        Stmt::ResultAssign { value }
    }

    fn parse_block(&mut self) -> Stmt {
        self.advance(); // skip 'block'
        let label = if let TokenKind::Label(_) = self.peek() {
            if let TokenKind::Label(name) = self.advance().kind.clone() {
                Some(name)
            } else {
                None
            }
        } else {
            None
        };
        self.expect(&TokenKind::Colon);
        self.skip_newlines();
        let body = self.parse_block_body();
        Stmt::Block { label, body }
    }

    fn parse_spawn(&mut self) -> Stmt {
        self.advance(); // skip 'spawn'
        self.expect(&TokenKind::Colon);
        self.skip_newlines();
        let body = self.parse_block_body();
        Stmt::Spawn(body)
    }

    fn parse_import(&mut self) -> Stmt {
        self.advance(); // skip 'import'
        let name = self.parse_ident_name();
        Stmt::Import(name)
    }

    fn parse_raise(&mut self) -> Stmt {
        self.advance(); // skip 'raise'
        let expr = self.parse_expr();
        Stmt::Raise(expr)
    }

    fn parse_expr_or_assign(&mut self) -> Stmt {
        let expr = self.parse_expr();
        if self.at(&TokenKind::Eq) {
            self.advance();
            let value = self.parse_expr();
            Stmt::Assign { target: expr, value }
        } else {
            Stmt::ExprStmt(expr)
        }
    }

    // ── Block body (indented) ──

    fn parse_block_body(&mut self) -> Vec<Stmt> {
        let mut stmts = Vec::new();

        if !self.at(&TokenKind::Indent) {
            // Single-line body
            if !self.at(&TokenKind::Newline) && !self.at(&TokenKind::Eof) {
                stmts.push(self.parse_stmt());
            }
            return stmts;
        }

        self.advance(); // skip Indent

        while !self.at(&TokenKind::Dedent) && !self.at(&TokenKind::Eof) {
            self.skip_newlines();
            if self.at(&TokenKind::Dedent) || self.at(&TokenKind::Eof) {
                break;
            }
            stmts.push(self.parse_stmt());
            self.skip_newlines();
        }

        if self.at(&TokenKind::Dedent) {
            self.advance();
        }

        stmts
    }

    // ── Expressions ──

    fn parse_expr(&mut self) -> Expr {
        self.parse_or()
    }

    fn parse_or(&mut self) -> Expr {
        let mut left = self.parse_and();
        while self.at(&TokenKind::Or) {
            self.advance();
            let right = self.parse_and();
            left = Expr::Binary {
                left: Box::new(left),
                op: BinOp::Or,
                right: Box::new(right),
            };
        }
        left
    }

    fn parse_and(&mut self) -> Expr {
        let mut left = self.parse_range();
        while self.at(&TokenKind::And) {
            self.advance();
            let right = self.parse_range();
            left = Expr::Binary {
                left: Box::new(left),
                op: BinOp::And,
                right: Box::new(right),
            };
        }
        left
    }

    fn parse_range(&mut self) -> Expr {
        let mut left = self.parse_comparison();
        match self.peek() {
            TokenKind::DotDot => {
                self.advance();
                let right = self.parse_range();
                Expr::Range {
                    start: Box::new(left),
                    end: Box::new(right),
                    inclusive: true,
                }
            }
            TokenKind::DotDotLess => {
                self.advance();
                let right = self.parse_range();
                Expr::Range {
                    start: Box::new(left),
                    end: Box::new(right),
                    inclusive: false,
                }
            }
            _ => left,
        }
    }

    fn parse_comparison(&mut self) -> Expr {
        let mut left = self.parse_addition();
        loop {
            let op = match self.peek() {
                TokenKind::EqEq => BinOp::Eq,
                TokenKind::NotEq => BinOp::NotEq,
                TokenKind::Less => BinOp::Less,
                TokenKind::LessEq => BinOp::LessEq,
                TokenKind::Greater => BinOp::Greater,
                TokenKind::GreaterEq => BinOp::GreaterEq,
                _ => break,
            };
            self.advance();
            let right = self.parse_addition();
            left = Expr::Binary {
                left: Box::new(left),
                op,
                right: Box::new(right),
            };
        }
        left
    }

    fn parse_addition(&mut self) -> Expr {
        let mut left = self.parse_multiplication();
        loop {
            let op = match self.peek() {
                TokenKind::Plus => BinOp::Add,
                TokenKind::Minus => BinOp::Sub,
                _ => break,
            };
            self.advance();
            let right = self.parse_multiplication();
            left = Expr::Binary {
                left: Box::new(left),
                op,
                right: Box::new(right),
            };
        }
        left
    }

    fn parse_multiplication(&mut self) -> Expr {
        let mut left = self.parse_unary();
        loop {
            let op = match self.peek() {
                TokenKind::Star => BinOp::Mul,
                TokenKind::Slash => BinOp::Div,
                TokenKind::Percent => BinOp::Mod,
                _ => break,
            };
            self.advance();
            let right = self.parse_unary();
            left = Expr::Binary {
                left: Box::new(left),
                op,
                right: Box::new(right),
            };
        }
        left
    }

    fn parse_unary(&mut self) -> Expr {
        match self.peek() {
            TokenKind::Minus => {
                self.advance();
                let expr = self.parse_unary();
                Expr::Unary { op: UnaryOp::Neg, expr: Box::new(expr) }
            }
            TokenKind::Not => {
                self.advance();
                let expr = self.parse_unary();
                Expr::Unary { op: UnaryOp::Not, expr: Box::new(expr) }
            }
            TokenKind::Dollar => {
                self.advance();
                let expr = self.parse_postfix();
                Expr::Dollar(Box::new(expr))
            }
            _ => self.parse_postfix(),
        }
    }

    fn parse_postfix(&mut self) -> Expr {
        let mut expr = self.parse_primary();

        loop {
            match self.peek() {
                TokenKind::LParen => {
                    self.advance();
                    let args = self.parse_call_args();
                    self.expect(&TokenKind::RParen);
                    expr = Expr::Call {
                        func: Box::new(expr),
                        args,
                    };
                }
                TokenKind::Dot => {
                    self.advance();
                    let field = self.parse_ident_name();
                    expr = Expr::FieldAccess {
                        expr: Box::new(expr),
                        field,
                    };
                }
                TokenKind::LBracket => {
                    self.advance();
                    let index = self.parse_expr();
                    self.expect(&TokenKind::RBracket);
                    expr = Expr::Index {
                        expr: Box::new(expr),
                        index: Box::new(index),
                    };
                }
                TokenKind::Question => {
                    self.advance();
                    expr = Expr::Question(Box::new(expr));
                }
                _ => break,
            }
        }

        expr
    }

    fn parse_primary(&mut self) -> Expr {
        match self.peek().clone() {
            TokenKind::IntLit(n) => {
                let val = n;
                self.advance();
                Expr::IntLit(val)
            }
            TokenKind::FloatLit(n) => {
                let val = n;
                self.advance();
                Expr::FloatLit(val)
            }
            TokenKind::StringLit(s) => {
                let val = s.clone();
                self.advance();
                Expr::StringLit(val)
            }
            TokenKind::RuneLit(c) => {
                let val = c;
                self.advance();
                Expr::RuneLit(val)
            }
            TokenKind::BoolLit(b) => {
                let val = b;
                self.advance();
                Expr::BoolLit(val)
            }
            TokenKind::Ident(_) => {
                let name = self.parse_ident_name();
                Expr::Ident(name)
            }
            TokenKind::LParen => {
                self.advance();
                let expr = self.parse_expr();
                self.expect(&TokenKind::RParen);
                expr
            }
            TokenKind::LBracket => {
                self.advance();
                let mut elems = Vec::new();
                while !self.at(&TokenKind::RBracket) && !self.at(&TokenKind::Eof) {
                    elems.push(self.parse_expr());
                    if self.at(&TokenKind::Comma) {
                        self.advance();
                    }
                }
                self.expect(&TokenKind::RBracket);
                Expr::ArrayLit(elems)
            }
            TokenKind::Tilde => {
                self.advance();
                self.expect(&TokenKind::LBracket);
                let mut elems = Vec::new();
                while !self.at(&TokenKind::RBracket) && !self.at(&TokenKind::Eof) {
                    elems.push(self.parse_expr());
                    if self.at(&TokenKind::Comma) {
                        self.advance();
                    }
                }
                self.expect(&TokenKind::RBracket);
                Expr::SeqLit(elems)
            }
            TokenKind::Some => {
                self.advance();
                self.expect(&TokenKind::LParen);
                let expr = self.parse_expr();
                self.expect(&TokenKind::RParen);
                Expr::Call {
                    func: Box::new(Expr::Ident("some".to_string())),
                    args: vec![CallArg { name: None, value: expr }],
                }
            }
            TokenKind::None => {
                self.advance();
                self.expect(&TokenKind::LParen);
                let expr = self.parse_expr();
                self.expect(&TokenKind::RParen);
                Expr::Call {
                    func: Box::new(Expr::Ident("none".to_string())),
                    args: vec![CallArg { name: None, value: expr }],
                }
            }
            _ => {
                let tok = &self.tokens[self.pos];
                panic!(
                    "{}:{}: unexpected token {:?}",
                    tok.line, tok.col, tok.kind
                );
            }
        }
    }

    fn parse_call_args(&mut self) -> Vec<CallArg> {
        let mut args = Vec::new();
        while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
            // Check for named argument: name: value
            let arg = if let TokenKind::Ident(name) = self.peek().clone() {
                let saved_pos = self.pos;
                self.advance();
                if self.at(&TokenKind::Colon) {
                    self.advance();
                    let value = self.parse_expr();
                    CallArg { name: Some(name), value }
                } else {
                    self.pos = saved_pos;
                    let value = self.parse_expr();
                    CallArg { name: None, value }
                }
            } else {
                let value = self.parse_expr();
                CallArg { name: None, value }
            };
            args.push(arg);
            if self.at(&TokenKind::Comma) {
                self.advance();
            }
        }
        args
    }

    // ── Helpers ──

    fn parse_ident_name(&mut self) -> String {
        match self.peek().clone() {
            TokenKind::Ident(name) => {
                self.advance();
                name
            }
            _ => {
                let tok = &self.tokens[self.pos];
                panic!(
                    "{}:{}: expected identifier, got {:?}",
                    tok.line, tok.col, tok.kind
                );
            }
        }
    }

    fn try_parse_label(&mut self) -> Option<String> {
        if let TokenKind::Label(_) = self.peek() {
            if let TokenKind::Label(name) = self.advance().kind.clone() {
                Some(name)
            } else {
                None
            }
        } else {
            None
        }
    }

    fn parse_type(&mut self) -> TypeExpr {
        let name = self.parse_ident_name();

        if self.at(&TokenKind::LBracket) {
            self.advance();
            let mut args = Vec::new();
            while !self.at(&TokenKind::RBracket) && !self.at(&TokenKind::Eof) {
                args.push(self.parse_type());
                if self.at(&TokenKind::Comma) {
                    self.advance();
                }
            }
            self.expect(&TokenKind::RBracket);
            TypeExpr::Generic { name, args }
        } else {
            TypeExpr::Named(name)
        }
    }
}
