use crate::ast::*;
use crate::error::{CompileError, CompileResult};
use crate::token::{Token, TokenKind};

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, pos: 0 }
    }

    // ── Token access ──

    fn peek(&self) -> &TokenKind {
        self.tokens.get(self.pos).map(|t| &t.kind).unwrap_or(&TokenKind::Eof)
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

    fn expect(&mut self, kind: &TokenKind) -> CompileResult<()> {
        if !self.at(kind) {
            let tok = &self.tokens[self.pos];
            return Err(CompileError::new(
                format!("expected {:?}, got {:?}", kind, tok.kind),
                tok.line, tok.col,
            ));
        }
        self.advance();
        Ok(())
    }

    fn skip_newlines(&mut self) {
        while self.at(&TokenKind::Newline) { self.advance(); }
    }

    fn error(&self, msg: impl Into<String>) -> CompileError {
        let tok = &self.tokens[self.pos];
        CompileError::new(msg, tok.line, tok.col)
    }

    // ── Helpers ──

    fn parse_ident_name(&mut self) -> CompileResult<String> {
        if let TokenKind::Ident(name) = self.peek().clone() {
            self.advance();
            Ok(name)
        } else {
            Err(self.error(format!("expected identifier, got {:?}", self.peek())))
        }
    }

    fn try_parse_label(&mut self) -> Option<String> {
        if let TokenKind::Label(name) = self.peek().clone() {
            self.advance();
            Some(name)
        } else {
            None
        }
    }

    fn try_parse_public(&mut self) -> bool {
        if self.at(&TokenKind::Star) { self.advance(); true } else { false }
    }

    // ── Entry ──

    pub fn parse(&mut self) -> CompileResult<Vec<Stmt>> {
        let mut stmts = Vec::new();
        self.skip_newlines();
        while !self.at(&TokenKind::Eof) {
            stmts.push(self.parse_stmt()?);
            self.skip_newlines();
        }
        Ok(stmts)
    }

    // ── Statements ──

    fn parse_stmt(&mut self) -> CompileResult<Stmt> {
        match self.peek().clone() {
            TokenKind::Let => self.parse_decl(false),
            TokenKind::Var => self.parse_decl(true),
            TokenKind::Const => self.parse_const(),
            TokenKind::Fn => self.parse_fn(),
            TokenKind::If => self.parse_if_stmt(),
            TokenKind::While => self.parse_while(),
            TokenKind::For => self.parse_for(),
            TokenKind::Break => self.parse_break(),
            TokenKind::Continue => self.parse_continue(),
            TokenKind::Return => { self.advance(); Ok(Stmt::Return) }
            TokenKind::Result => self.parse_result_assign(),
            TokenKind::Block => self.parse_block(),
            TokenKind::Spawn => self.parse_spawn(),
            TokenKind::Type => self.parse_type_decl(),
            TokenKind::Enum => self.parse_enum_decl(),
            TokenKind::Case => self.parse_case(),
            TokenKind::Import => self.parse_import(),
            TokenKind::Raise => { self.advance(); Ok(Stmt::Raise(self.parse_expr()?)) }
            TokenKind::Discard => { self.advance(); Ok(Stmt::Discard) }
            _ => self.parse_expr_or_assign(),
        }
    }

    fn parse_decl(&mut self, mutable: bool) -> CompileResult<Stmt> {
        self.advance(); // skip let/var
        let name = self.parse_ident_name()?;
        let type_ann = if self.at(&TokenKind::Colon) {
            self.advance();
            Some(self.parse_type()?)
        } else {
            None
        };
        let value = if self.at(&TokenKind::Eq) {
            self.advance();
            Some(self.parse_expr()?)
        } else {
            None
        };
        if mutable {
            Ok(Stmt::VarDecl { name, type_ann, value })
        } else {
            Ok(Stmt::LetDecl { name, type_ann, value })
        }
    }

    fn parse_const(&mut self) -> CompileResult<Stmt> {
        self.advance();
        let name = self.parse_ident_name()?;
        let public = self.try_parse_public();
        let type_ann = if self.at(&TokenKind::Colon) {
            self.advance();
            Some(self.parse_type()?)
        } else {
            None
        };
        self.expect(&TokenKind::Eq)?;
        let value = self.parse_expr()?;
        Ok(Stmt::ConstDecl { name, public, type_ann, value })
    }

    fn parse_fn(&mut self) -> CompileResult<Stmt> {
        self.advance();
        let name = self.parse_ident_name()?;
        let public = self.try_parse_public();

        self.expect(&TokenKind::LParen)?;
        let params = self.parse_params()?;
        self.expect(&TokenKind::RParen)?;

        let mut return_type = None;
        let mut error_types = Vec::new();

        if self.at(&TokenKind::Arrow) {
            self.advance();
            return_type = Some(self.parse_type()?);
            while self.at(&TokenKind::Pipe) {
                self.advance();
                self.expect(&TokenKind::Bang)?;
                error_types.push(self.parse_type()?);
            }
        }
        if self.at(&TokenKind::Bang) {
            self.advance();
            error_types.push(self.parse_type()?);
        }

        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        let body = self.parse_block_body()?;

        Ok(Stmt::FnDecl { name, public, params, return_type, error_types, body })
    }

    fn parse_params(&mut self) -> CompileResult<Vec<Param>> {
        let mut params = Vec::new();
        while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
            let ownership = match self.peek() {
                TokenKind::Own => {
                    self.advance();
                    if self.at(&TokenKind::Var) { self.advance(); Ownership::OwnVar }
                    else { Ownership::Own }
                }
                TokenKind::Var => { self.advance(); Ownership::VarBorrow }
                _ => Ownership::Borrow,
            };
            let name = self.parse_ident_name()?;
            self.expect(&TokenKind::Colon)?;
            let type_ann = self.parse_type()?;
            params.push(Param { name, type_ann, ownership });
            if self.at(&TokenKind::Comma) { self.advance(); }
        }
        Ok(params)
    }

    fn parse_if_stmt(&mut self) -> CompileResult<Stmt> {
        let mut branches = Vec::new();

        self.advance(); // skip 'if'
        let cond = self.parse_expr()?;
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        branches.push((cond, self.parse_block_body()?));

        while self.at(&TokenKind::Elif) {
            self.advance();
            let cond = self.parse_expr()?;
            self.expect(&TokenKind::Colon)?;
            self.skip_newlines();
            branches.push((cond, self.parse_block_body()?));
        }

        let else_body = if self.at(&TokenKind::Else) {
            self.advance();
            self.expect(&TokenKind::Colon)?;
            self.skip_newlines();
            Some(self.parse_block_body()?)
        } else {
            None
        };

        Ok(Stmt::If { branches, else_body })
    }

    fn parse_while(&mut self) -> CompileResult<Stmt> {
        self.advance();
        let condition = self.parse_expr()?;
        let label = self.try_parse_label();
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        let body = self.parse_block_body()?;
        Ok(Stmt::While { condition, label, body })
    }

    fn parse_for(&mut self) -> CompileResult<Stmt> {
        self.advance();
        let var = self.parse_ident_name()?;
        self.expect(&TokenKind::In)?;
        let iter = self.parse_expr()?;
        let label = self.try_parse_label();
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        let body = self.parse_block_body()?;

        let else_body = if self.at(&TokenKind::Else) {
            self.advance();
            self.expect(&TokenKind::Colon)?;
            self.skip_newlines();
            Some(self.parse_block_body()?)
        } else {
            None
        };

        Ok(Stmt::For { var, iter, label, body, else_body })
    }

    fn parse_break(&mut self) -> CompileResult<Stmt> {
        self.advance();
        Ok(Stmt::Break(self.try_parse_label()))
    }

    fn parse_continue(&mut self) -> CompileResult<Stmt> {
        self.advance();
        Ok(Stmt::Continue(self.try_parse_label()))
    }

    fn parse_result_assign(&mut self) -> CompileResult<Stmt> {
        self.advance();
        self.expect(&TokenKind::Eq)?;
        Ok(Stmt::ResultAssign { value: self.parse_expr()? })
    }

    fn parse_block(&mut self) -> CompileResult<Stmt> {
        self.advance();
        let label = self.try_parse_label();
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        let body = self.parse_block_body()?;
        Ok(Stmt::Block { label, body })
    }

    fn parse_spawn(&mut self) -> CompileResult<Stmt> {
        self.advance();
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        Ok(Stmt::Spawn(self.parse_block_body()?))
    }

    fn parse_import(&mut self) -> CompileResult<Stmt> {
        self.advance();
        Ok(Stmt::Import(self.parse_ident_name()?))
    }

    fn parse_type_decl(&mut self) -> CompileResult<Stmt> {
        self.advance();
        let name = self.parse_ident_name()?;
        let public = self.try_parse_public();
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();

        let fields = self.parse_indented_items(|p| {
            p.expect(&TokenKind::At)?;
            let name = p.parse_ident_name()?;
            let public = p.try_parse_public();
            p.expect(&TokenKind::Colon)?;
            let type_ann = p.parse_type()?;
            Ok(TypeField { name, public, type_ann })
        })?;

        Ok(Stmt::TypeDecl { name, public, fields })
    }

    fn parse_enum_decl(&mut self) -> CompileResult<Stmt> {
        self.advance();
        let name = self.parse_ident_name()?;
        let public = self.try_parse_public();
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();

        let variants = self.parse_indented_items(|p| {
            let vname = p.parse_ident_name()?;
            let value = p.parse_enum_value()?;
            if p.at(&TokenKind::Comma) { p.advance(); }
            Ok(EnumVariant { name: vname, value })
        })?;

        Ok(Stmt::EnumDecl { name, public, variants })
    }

    fn parse_enum_value(&mut self) -> CompileResult<Option<EnumValue>> {
        if self.at(&TokenKind::Eq) {
            self.advance();
            match self.peek().clone() {
                TokenKind::IntLit(n) => { self.advance(); Ok(Some(EnumValue::Int(n))) }
                TokenKind::StringLit(s) => { self.advance(); Ok(Some(EnumValue::String(s))) }
                _ => Err(self.error("expected int or string value for enum variant")),
            }
        } else if self.at(&TokenKind::LParen) {
            self.advance();
            let mut fields = Vec::new();
            while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
                let name = self.parse_ident_name()?;
                self.expect(&TokenKind::Colon)?;
                let type_ann = self.parse_type()?;
                fields.push((name, type_ann));
                if self.at(&TokenKind::Comma) { self.advance(); }
            }
            self.expect(&TokenKind::RParen)?;
            Ok(Some(EnumValue::Fields(fields)))
        } else {
            Ok(None)
        }
    }

    fn parse_case(&mut self) -> CompileResult<Stmt> {
        self.advance();
        let expr = self.parse_expr()?;
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();

        let mut branches = Vec::new();
        let mut else_body = None;

        if self.at(&TokenKind::Indent) {
            self.advance();
            while !self.at(&TokenKind::Dedent) && !self.at(&TokenKind::Eof) {
                self.skip_newlines();
                if self.at(&TokenKind::Dedent) { break; }

                if self.at(&TokenKind::Else) {
                    else_body = Some(self.parse_else_branch()?);
                    break;
                }

                self.expect(&TokenKind::Of)?;
                let pattern = self.parse_case_pattern()?;
                self.expect(&TokenKind::Colon)?;
                self.skip_newlines();
                branches.push(CaseBranch { pattern, body: self.parse_block_body()? });
                self.skip_newlines();
            }
            if self.at(&TokenKind::Dedent) { self.advance(); }
        }

        // else at same indent level as case (per spec)
        if else_body.is_none() && self.at(&TokenKind::Else) {
            else_body = Some(self.parse_else_branch()?);
        }

        Ok(Stmt::Case { expr, branches, else_body })
    }

    fn parse_else_branch(&mut self) -> CompileResult<Vec<Stmt>> {
        self.advance(); // skip 'else'
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        self.parse_block_body()
    }

    fn parse_case_pattern(&mut self) -> CompileResult<CasePattern> {
        match self.peek().clone() {
            TokenKind::Ident(ref name) if name == "ok" => {
                self.advance();
                Ok(CasePattern::Ok)
            }
            TokenKind::Ident(ref name) if name == "error" => {
                self.advance();
                Ok(CasePattern::Error(self.try_parse_dotted_name()?))
            }
            TokenKind::Some => { self.advance(); Ok(CasePattern::Some) }
            TokenKind::None => { self.advance(); Ok(CasePattern::None) }
            TokenKind::Ident(name) => {
                self.advance();
                // Allow dotted variant: Color.red
                let mut full = name;
                while self.at(&TokenKind::Dot) {
                    self.advance();
                    full = format!("{}.{}", full, self.parse_ident_name()?);
                }
                Ok(CasePattern::Variant(full))
            }
            _ => Err(self.error(format!("expected case pattern, got {:?}", self.peek()))),
        }
    }

    /// Parses optional `(Name.sub.path)` after a pattern keyword.
    fn try_parse_dotted_name(&mut self) -> CompileResult<Option<String>> {
        if !self.at(&TokenKind::LParen) { return Ok(None); }
        self.advance();
        let mut path = self.parse_ident_name()?;
        while self.at(&TokenKind::Dot) {
            self.advance();
            path = format!("{}.{}", path, self.parse_ident_name()?);
        }
        self.expect(&TokenKind::RParen)?;
        Ok(Some(path))
    }

    /// Parses an indented block where each item is produced by `parse_item`.
    fn parse_indented_items<T>(
        &mut self,
        mut parse_item: impl FnMut(&mut Self) -> CompileResult<T>,
    ) -> CompileResult<Vec<T>> {
        let mut items = Vec::new();
        if !self.at(&TokenKind::Indent) { return Ok(items); }
        self.advance();
        while !self.at(&TokenKind::Dedent) && !self.at(&TokenKind::Eof) {
            self.skip_newlines();
            if self.at(&TokenKind::Dedent) { break; }
            items.push(parse_item(self)?);
            self.skip_newlines();
        }
        if self.at(&TokenKind::Dedent) { self.advance(); }
        Ok(items)
    }

    fn parse_expr_or_assign(&mut self) -> CompileResult<Stmt> {
        let expr = self.parse_expr()?;
        if self.at(&TokenKind::Eq) {
            self.advance();
            Ok(Stmt::Assign { target: expr, value: self.parse_expr()? })
        } else {
            Ok(Stmt::ExprStmt(expr))
        }
    }

    // ── Block body ──

    fn parse_block_body(&mut self) -> CompileResult<Vec<Stmt>> {
        if !self.at(&TokenKind::Indent) {
            // Single-line body
            return if !self.at(&TokenKind::Newline) && !self.at(&TokenKind::Eof) {
                Ok(vec![self.parse_stmt()?])
            } else {
                Ok(Vec::new())
            };
        }

        self.advance(); // skip Indent
        let mut stmts = Vec::new();

        while !self.at(&TokenKind::Dedent) && !self.at(&TokenKind::Eof) {
            self.skip_newlines();
            if self.at(&TokenKind::Dedent) || self.at(&TokenKind::Eof) { break; }
            stmts.push(self.parse_stmt()?);
            self.skip_newlines();
        }

        if self.at(&TokenKind::Dedent) { self.advance(); }
        Ok(stmts)
    }

    // ── Expressions (precedence climbing) ──

    fn parse_expr(&mut self) -> CompileResult<Expr> { self.parse_or() }

    fn parse_or(&mut self) -> CompileResult<Expr> {
        let mut left = self.parse_and()?;
        while self.at(&TokenKind::Or) {
            self.advance();
            left = Expr::Binary { left: Box::new(left), op: BinOp::Or, right: Box::new(self.parse_and()?) };
        }
        Ok(left)
    }

    fn parse_and(&mut self) -> CompileResult<Expr> {
        let mut left = self.parse_range()?;
        while self.at(&TokenKind::And) {
            self.advance();
            left = Expr::Binary { left: Box::new(left), op: BinOp::And, right: Box::new(self.parse_range()?) };
        }
        Ok(left)
    }

    fn parse_range(&mut self) -> CompileResult<Expr> {
        let left = self.parse_comparison()?;
        let (inclusive, has_range) = match self.peek() {
            TokenKind::DotDot => { self.advance(); (true, true) }
            TokenKind::DotDotLess => { self.advance(); (false, true) }
            _ => (false, false),
        };
        if has_range {
            Ok(Expr::Range {
                start: Box::new(left),
                end: Box::new(self.parse_comparison()?),
                inclusive,
            })
        } else {
            Ok(left)
        }
    }

    fn parse_comparison(&mut self) -> CompileResult<Expr> {
        let mut left = self.parse_addition()?;
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
            left = Expr::Binary { left: Box::new(left), op, right: Box::new(self.parse_addition()?) };
        }
        Ok(left)
    }

    fn parse_addition(&mut self) -> CompileResult<Expr> {
        let mut left = self.parse_multiplication()?;
        loop {
            let op = match self.peek() {
                TokenKind::Plus => BinOp::Add,
                TokenKind::Minus => BinOp::Sub,
                _ => break,
            };
            self.advance();
            left = Expr::Binary { left: Box::new(left), op, right: Box::new(self.parse_multiplication()?) };
        }
        Ok(left)
    }

    fn parse_multiplication(&mut self) -> CompileResult<Expr> {
        let mut left = self.parse_unary()?;
        loop {
            let op = match self.peek() {
                TokenKind::Star => BinOp::Mul,
                TokenKind::Slash => BinOp::Div,
                TokenKind::Percent => BinOp::Mod,
                _ => break,
            };
            self.advance();
            left = Expr::Binary { left: Box::new(left), op, right: Box::new(self.parse_unary()?) };
        }
        Ok(left)
    }

    fn parse_unary(&mut self) -> CompileResult<Expr> {
        match self.peek() {
            TokenKind::Minus => {
                self.advance();
                Ok(Expr::Unary { op: UnaryOp::Neg, expr: Box::new(self.parse_unary()?) })
            }
            TokenKind::Not => {
                self.advance();
                Ok(Expr::Unary { op: UnaryOp::Not, expr: Box::new(self.parse_unary()?) })
            }
            TokenKind::Dollar => {
                self.advance();
                Ok(Expr::Dollar(Box::new(self.parse_postfix()?)))
            }
            _ => self.parse_postfix(),
        }
    }

    fn parse_postfix(&mut self) -> CompileResult<Expr> {
        let mut expr = self.parse_primary()?;
        loop {
            match self.peek() {
                TokenKind::LParen => {
                    self.advance();
                    let args = self.parse_call_args()?;
                    self.expect(&TokenKind::RParen)?;
                    expr = Expr::Call { func: Box::new(expr), args };
                }
                TokenKind::Dot => {
                    self.advance();
                    let field = self.parse_ident_name()?;
                    expr = Expr::FieldAccess { expr: Box::new(expr), field };
                }
                TokenKind::LBracket => {
                    self.advance();
                    let index = self.parse_expr()?;
                    self.expect(&TokenKind::RBracket)?;
                    expr = Expr::Index { expr: Box::new(expr), index: Box::new(index) };
                }
                TokenKind::Question => {
                    self.advance();
                    expr = Expr::Question(Box::new(expr));
                }
                _ => break,
            }
        }
        Ok(expr)
    }

    fn parse_primary(&mut self) -> CompileResult<Expr> {
        let tok = self.peek().clone();
        match tok {
            TokenKind::IntLit(n) => { self.advance(); Ok(Expr::IntLit(n)) }
            TokenKind::FloatLit(n) => { self.advance(); Ok(Expr::FloatLit(n)) }
            TokenKind::StringLit(s) => { self.advance(); Ok(Expr::StringLit(s)) }
            TokenKind::RuneLit(c) => { self.advance(); Ok(Expr::RuneLit(c)) }
            TokenKind::BoolLit(b) => { self.advance(); Ok(Expr::BoolLit(b)) }
            TokenKind::Ident(_) => { let name = self.parse_ident_name()?; Ok(Expr::Ident(name)) }
            TokenKind::StringInterpStart => self.parse_string_interp(),
            TokenKind::LParen => {
                self.advance();
                let expr = self.parse_expr()?;
                self.expect(&TokenKind::RParen)?;
                Ok(expr)
            }
            TokenKind::LBracket => {
                self.advance();
                let mut elems = Vec::new();
                while !self.at(&TokenKind::RBracket) && !self.at(&TokenKind::Eof) {
                    elems.push(self.parse_expr()?);
                    if self.at(&TokenKind::Comma) { self.advance(); }
                }
                self.expect(&TokenKind::RBracket)?;
                Ok(Expr::ArrayLit(elems))
            }
            TokenKind::Tilde => {
                self.advance();
                self.expect(&TokenKind::LBracket)?;
                let mut elems = Vec::new();
                while !self.at(&TokenKind::RBracket) && !self.at(&TokenKind::Eof) {
                    elems.push(self.parse_expr()?);
                    if self.at(&TokenKind::Comma) { self.advance(); }
                }
                self.expect(&TokenKind::RBracket)?;
                Ok(Expr::SeqLit(elems))
            }
            TokenKind::Some | TokenKind::None => {
                let is_some = matches!(tok, TokenKind::Some);
                let name = if is_some { "some" } else { "none" };
                self.advance();
                self.expect(&TokenKind::LParen)?;
                let arg = self.parse_expr()?;
                self.expect(&TokenKind::RParen)?;
                Ok(Expr::Call {
                    func: Box::new(Expr::Ident(name.to_string())),
                    args: vec![CallArg { name: None, value: arg }],
                })
            }
            _ => Err(self.error(format!("unexpected token {:?}", self.peek()))),
        }
    }

    fn parse_string_interp(&mut self) -> CompileResult<Expr> {
        self.advance(); // skip InterpStart
        let mut parts = Vec::new();
        loop {
            match self.peek().clone() {
                TokenKind::StringLit(s) => {
                    if !s.is_empty() { parts.push(StringPart::Lit(s)); }
                    self.advance();
                }
                TokenKind::Ident(name) => {
                    parts.push(StringPart::Expr(Expr::Ident(name)));
                    self.advance();
                }
                TokenKind::StringInterpEnd(s) => {
                    if !s.is_empty() { parts.push(StringPart::Lit(s)); }
                    self.advance();
                    break;
                }
                _ => break,
            }
        }
        Ok(Expr::StringInterp { parts })
    }

    fn parse_call_args(&mut self) -> CompileResult<Vec<CallArg>> {
        let mut args = Vec::new();
        while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
            // Check for named argument: name: value
            let arg = if let TokenKind::Ident(name) = self.peek().clone() {
                let saved = self.pos;
                self.advance();
                if self.at(&TokenKind::Colon) {
                    self.advance();
                    CallArg { name: Some(name), value: self.parse_expr()? }
                } else {
                    self.pos = saved;
                    CallArg { name: None, value: self.parse_expr()? }
                }
            } else {
                CallArg { name: None, value: self.parse_expr()? }
            };
            args.push(arg);
            if self.at(&TokenKind::Comma) { self.advance(); }
        }
        Ok(args)
    }

    // ── Types ──

    fn parse_type(&mut self) -> CompileResult<TypeExpr> {
        let name = self.parse_ident_name()?;

        if self.at(&TokenKind::LBracket) {
            self.advance();
            let mut args = Vec::new();
            while !self.at(&TokenKind::RBracket) && !self.at(&TokenKind::Eof) {
                args.push(self.parse_type()?);
                if self.at(&TokenKind::Comma) { self.advance(); }
            }
            self.expect(&TokenKind::RBracket)?;
            Ok(TypeExpr::Generic { name, args })
        } else {
            Ok(TypeExpr::Named(name))
        }
    }
}
