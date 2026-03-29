use crate::ast::*;
use crate::error::{CompileError, CompileResult};
use crate::token::{Token, TokenKind};

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

/// Result of parsing `@name[+]` — the universal declaration prefix.
struct AtName {
    name: String,
    public: bool,
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

    // ── @name parsing — the universal prefix ──

    /// Parse `@name[+]` — expects `@`, reads name (ident or keyword), optional `+`.
    /// Used everywhere: declarations, fields, params, labels, loop vars.
    fn parse_at_name(&mut self) -> CompileResult<AtName> {
        self.expect(&TokenKind::At)?;
        let name = self.parse_any_name()?;
        let public = if self.at(&TokenKind::Plus) { self.advance(); true } else { false };
        Ok(AtName { name, public })
    }

    /// Parse `@name` without public marker — for params, loop vars, enum fields.
    fn parse_at_ident(&mut self) -> CompileResult<String> {
        self.expect(&TokenKind::At)?;
        self.parse_ident_name()
    }

    fn parse_ident_name(&mut self) -> CompileResult<String> {
        if let TokenKind::Ident(name) = self.peek().clone() {
            self.advance();
            Ok(name)
        } else {
            Err(self.error(format!("expected identifier, got {:?}", self.peek())))
        }
    }

    /// Parse any name — identifier or keyword (for fields/enum variants).
    fn parse_any_name(&mut self) -> CompileResult<String> {
        let name = match self.peek().clone() {
            TokenKind::Ident(name) => name,
            ref k => {
                if let Some(name) = Self::keyword_as_name(k) {
                    name.to_string()
                } else {
                    return Err(self.error(format!("expected name, got {:?}", self.peek())));
                }
            }
        };
        self.advance();
        Ok(name)
    }

    fn keyword_as_name(kind: &TokenKind) -> Option<&str> {
        match kind {
            TokenKind::Func => Some("func"),
            TokenKind::Const => Some("const"),
            TokenKind::Mut => Some("mut"),
            TokenKind::If => Some("if"),
            TokenKind::Elif => Some("elif"),
            TokenKind::Else => Some("else"),
            TokenKind::While => Some("while"),
            TokenKind::For => Some("for"),
            TokenKind::In => Some("in"),
            TokenKind::Break => Some("break"),
            TokenKind::Continue => Some("continue"),
            TokenKind::Return => Some("return"),
            TokenKind::Result => Some("result"),
            TokenKind::Block => Some("block"),
            TokenKind::Object => Some("object"),
            TokenKind::Enum => Some("enum"),
            TokenKind::Tuple => Some("tuple"),
            TokenKind::Case => Some("case"),
            TokenKind::Of => Some("of"),
            TokenKind::Not => Some("not"),
            TokenKind::And => Some("and"),
            TokenKind::Or => Some("or"),
            TokenKind::Some => Some("some"),
            TokenKind::None => Some("none"),
            TokenKind::Import => Some("import"),
            TokenKind::From => Some("from"),
            TokenKind::Export => Some("export"),
            TokenKind::Raise => Some("raise"),
            TokenKind::Quit => Some("quit"),
            TokenKind::Own => Some("own"),
            TokenKind::Discard => Some("discard"),
            TokenKind::Do => Some("do"),
            _ => None,
        }
    }

    /// Try to parse an optional identifier (for break/continue labels).
    fn try_parse_ident(&mut self) -> Option<String> {
        if let TokenKind::Ident(_) = self.peek() {
            Some(self.parse_ident_name().unwrap())
        } else {
            None
        }
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
            // @ starts all declarations
            TokenKind::At => self.parse_decl(),
            // do @x = expr() else: block
            TokenKind::Do => self.parse_do_else(),
            // Control flow (unlabeled)
            TokenKind::If => self.parse_if_stmt(),
            TokenKind::While => { self.advance(); self.parse_while_body(None) }
            TokenKind::For => { self.advance(); self.parse_for_body(None) }
            TokenKind::Break => { self.advance(); Ok(Stmt::Break(self.try_parse_ident())) }
            TokenKind::Continue => { self.advance(); Ok(Stmt::Continue(self.try_parse_ident())) }
            TokenKind::Return => { self.advance(); Ok(Stmt::Return) }
            TokenKind::Result => self.parse_result_assign(),
            TokenKind::Block => {
                self.advance();
                self.expect(&TokenKind::Colon)?;
                self.skip_newlines();
                Ok(Stmt::Block { label: None, body: self.parse_block_body()? })
            }
            TokenKind::Spawn => { self.advance(); self.expect(&TokenKind::Colon)?; self.skip_newlines(); Ok(Stmt::Spawn(self.parse_block_body()?)) }
            TokenKind::Case => self.parse_case(),
            // Module
            TokenKind::Import => { self.advance(); Ok(Stmt::Import(self.parse_ident_name()?)) }
            // Other
            TokenKind::Raise => { self.advance(); Ok(Stmt::Raise(self.parse_expr()?)) }
            TokenKind::Quit => {
                self.advance();
                let arg = if self.at(&TokenKind::LParen) {
                    self.advance();
                    let expr = if !self.at(&TokenKind::RParen) { Some(self.parse_expr()?) } else { None };
                    self.expect(&TokenKind::RParen)?;
                    expr
                } else {
                    None
                };
                Ok(Stmt::Quit(arg))
            }
            TokenKind::Discard => { self.advance(); Ok(Stmt::Discard) }
            // Expression or assignment
            _ => self.parse_expr_or_assign(),
        }
    }

    /// Parse declaration starting with `@`.
    /// Dispatches based on what follows `@name[+]`.
    fn parse_decl(&mut self) -> CompileResult<Stmt> {
        let at = self.parse_at_name()?;

        match self.peek().clone() {
            // @x = value
            TokenKind::Eq => {
                self.advance();
                Ok(Stmt::Decl { name: at.name, public: at.public, modifier: DeclModifier::Default, value: Some(self.parse_expr()?) })
            }
            // @x mut = value
            TokenKind::Mut => {
                self.advance();
                self.expect(&TokenKind::Eq)?;
                Ok(Stmt::Decl { name: at.name, public: at.public, modifier: DeclModifier::Mut, value: Some(self.parse_expr()?) })
            }
            // @x const = value
            TokenKind::Const => {
                self.advance();
                self.expect(&TokenKind::Eq)?;
                Ok(Stmt::Decl { name: at.name, public: at.public, modifier: DeclModifier::Const, value: Some(self.parse_expr()?) })
            }
            // @name func(...)
            TokenKind::Func => { self.advance(); self.parse_fn_body(at.name, at.public) }
            // @Name object:
            TokenKind::Object => { self.advance(); self.parse_object_body(at.name, at.public) }
            // @Name enum:
            TokenKind::Enum => { self.advance(); self.parse_enum_body(at.name, at.public) }
            // @Name tuple:\n  @x int\n  @y int
            TokenKind::Tuple => { self.advance(); self.parse_tuple_block(at.name, at.public) }
            // @Name (@x int, @y int) — inline tuple
            TokenKind::LParen => self.parse_tuple_inline(at.name, at.public),
            // @label while ...:
            TokenKind::While => { self.advance(); self.parse_while_body(Some(at.name)) }
            // @label for @item in ...:
            TokenKind::For => { self.advance(); self.parse_for_body(Some(at.name)) }
            // @label block:
            TokenKind::Block => {
                self.advance();
                self.expect(&TokenKind::Colon)?;
                self.skip_newlines();
                Ok(Stmt::Block { label: Some(at.name), body: self.parse_block_body()? })
            }
            _ => Err(self.error("expected =, mut, const, func, object, enum, while, for, or block after @name"))
        }
    }

    // ── Function ──

    fn parse_fn_body(&mut self, name: String, public: bool) -> CompileResult<Stmt> {
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

    /// Parse function params: `@name Type, @name mut Type, @name own Type`
    fn parse_params(&mut self) -> CompileResult<Vec<Param>> {
        let mut params = Vec::new();
        while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
            let name = self.parse_at_ident()?;
            let modifier = match self.peek() {
                TokenKind::Mut => { self.advance(); ParamModifier::Mut }
                TokenKind::Own => { self.advance(); ParamModifier::Own }
                _ => ParamModifier::Default,
            };
            let type_ann = self.parse_type()?;
            params.push(Param { name, modifier, type_ann });
            if self.at(&TokenKind::Comma) { self.advance(); }
        }
        Ok(params)
    }

    // ── Type declarations (object / enum / tuple) ──

    /// Parse typed fields in block form: `:\n  @name[+] Type\n  ...`
    /// Shared by object and tuple block declarations.
    fn parse_fields_block(&mut self) -> CompileResult<Vec<TypeField>> {
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        self.parse_indented_items(|p| {
            let at = p.parse_at_name()?;
            let type_ann = p.parse_type()?;
            Ok(TypeField { name: at.name, public: at.public, type_ann })
        })
    }

    /// Parse typed fields in inline form: `(@name[+] Type, ...)`
    /// Shared by inline tuple and enum variant fields.
    fn parse_fields_inline(&mut self) -> CompileResult<Vec<TypeField>> {
        self.advance(); // skip (
        let mut fields = Vec::new();
        while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
            let at = self.parse_at_name()?;
            let type_ann = self.parse_type()?;
            fields.push(TypeField { name: at.name, public: at.public, type_ann });
            if self.at(&TokenKind::Comma) { self.advance(); }
        }
        self.expect(&TokenKind::RParen)?;
        Ok(fields)
    }

    fn parse_object_body(&mut self, name: String, public: bool) -> CompileResult<Stmt> {
        let parent = if self.at(&TokenKind::Of) {
            self.advance();
            Some(self.parse_ident_name()?)
        } else {
            None
        };
        let fields = self.parse_fields_block()?;
        Ok(Stmt::ObjectDecl { name, public, parent, fields })
    }

    fn parse_tuple_block(&mut self, name: String, public: bool) -> CompileResult<Stmt> {
        let fields = self.parse_fields_block()?;
        Ok(Stmt::TupleDecl { name, public, fields })
    }

    fn parse_tuple_inline(&mut self, name: String, public: bool) -> CompileResult<Stmt> {
        let fields = self.parse_fields_inline()?;
        Ok(Stmt::TupleDecl { name, public, fields })
    }

    fn parse_enum_body(&mut self, name: String, public: bool) -> CompileResult<Stmt> {
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();

        let variants = self.parse_indented_items(|p| {
            let at = p.parse_at_name()?;
            let value = p.parse_enum_value()?;
            if p.at(&TokenKind::Comma) { p.advance(); }
            Ok(EnumVariant { name: at.name, value })
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
            let fields = self.parse_fields_inline()?;
            let converted = fields.into_iter().map(|f| (f.name, f.type_ann)).collect();
            Ok(Some(EnumValue::Fields(converted)))
        } else {
            Ok(None)
        }
    }

    // ── Control flow ──

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

    fn parse_while_body(&mut self, label: Option<String>) -> CompileResult<Stmt> {
        let condition = self.parse_expr()?;
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        let body = self.parse_block_body()?;
        Ok(Stmt::While { condition, label, body })
    }

    fn parse_for_body(&mut self, label: Option<String>) -> CompileResult<Stmt> {
        let var = self.parse_at_ident()?;
        self.expect(&TokenKind::In)?;
        let iter = self.parse_expr()?;
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

    fn parse_result_assign(&mut self) -> CompileResult<Stmt> {
        self.advance();
        self.expect(&TokenKind::Eq)?;
        Ok(Stmt::ResultAssign { value: self.parse_expr()? })
    }

    // ── do...else ──

    /// Parse `do @name = expr() else: block`
    fn parse_do_else(&mut self) -> CompileResult<Stmt> {
        self.advance(); // skip 'do'
        let name = self.parse_at_ident()?;
        self.expect(&TokenKind::Eq)?;
        let value = self.parse_expr()?;
        self.expect(&TokenKind::Else)?;
        self.expect(&TokenKind::Colon)?;
        self.skip_newlines();
        let else_body = self.parse_block_body()?;
        Ok(Stmt::DoElse { name, value, else_body })
    }

    // ── Case ──

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

        if else_body.is_none() && self.at(&TokenKind::Else) {
            else_body = Some(self.parse_else_branch()?);
        }

        Ok(Stmt::Case { expr, branches, else_body })
    }

    fn parse_else_branch(&mut self) -> CompileResult<Vec<Stmt>> {
        self.advance();
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

    // ── Block helpers ──

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

    fn parse_block_body(&mut self) -> CompileResult<Vec<Stmt>> {
        if !self.at(&TokenKind::Indent) {
            return if !self.at(&TokenKind::Newline) && !self.at(&TokenKind::Eof) {
                Ok(vec![self.parse_stmt()?])
            } else {
                Ok(Vec::new())
            };
        }

        self.advance();
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

    // ── Expressions ──

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
                    let field = if let TokenKind::IntLit(n) = self.peek().clone() {
                        self.advance();
                        n.to_string()
                    } else {
                        self.parse_ident_name()?
                    };
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
            TokenKind::LParen => self.parse_paren_or_tuple(),
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

    fn parse_paren_or_tuple(&mut self) -> CompileResult<Expr> {
        self.advance(); // skip (

        if self.at(&TokenKind::RParen) {
            self.advance();
            return Ok(Expr::TupleLit(Vec::new()));
        }

        // Detect named tuple: (name=val, ...)
        let first_named = if let TokenKind::Ident(_) = self.peek().clone() {
            let saved = self.pos;
            self.advance();
            if self.at(&TokenKind::Eq) {
                self.pos = saved;
                true
            } else {
                self.pos = saved;
                false
            }
        } else {
            false
        };

        if first_named {
            let mut elems = Vec::new();
            while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
                let name = self.parse_ident_name()?;
                self.expect(&TokenKind::Eq)?;
                let val = self.parse_expr()?;
                elems.push((Some(name), val));
                if self.at(&TokenKind::Comma) { self.advance(); }
            }
            self.expect(&TokenKind::RParen)?;
            return Ok(Expr::TupleLit(elems));
        }

        let first = self.parse_expr()?;

        if self.at(&TokenKind::Comma) {
            self.advance();
            let mut elems = vec![(None, first)];
            while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
                elems.push((None, self.parse_expr()?));
                if self.at(&TokenKind::Comma) { self.advance(); }
            }
            self.expect(&TokenKind::RParen)?;
            Ok(Expr::TupleLit(elems))
        } else {
            self.expect(&TokenKind::RParen)?;
            Ok(first)
        }
    }

    fn parse_string_interp(&mut self) -> CompileResult<Expr> {
        self.advance();
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

    /// Parse call arguments: `name=value` for named, or just `value` for positional.
    fn parse_call_args(&mut self) -> CompileResult<Vec<CallArg>> {
        let mut args = Vec::new();
        while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
            let arg = if let TokenKind::Ident(name) = self.peek().clone() {
                let saved = self.pos;
                self.advance();
                if self.at(&TokenKind::Eq) {
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
        // (Type, Type) — tuple type
        if self.at(&TokenKind::LParen) {
            self.advance();
            let mut elems = Vec::new();
            while !self.at(&TokenKind::RParen) && !self.at(&TokenKind::Eof) {
                elems.push((None, self.parse_type()?));
                if self.at(&TokenKind::Comma) { self.advance(); }
            }
            self.expect(&TokenKind::RParen)?;
            return Ok(TypeExpr::Tuple(elems));
        }

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
