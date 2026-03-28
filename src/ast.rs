// AST nodes for the Iris language
#![allow(dead_code)]

#[derive(Debug, Clone)]
pub enum Expr {
    IntLit(i64),
    FloatLit(f64),
    StringLit(String),
    RuneLit(char),
    BoolLit(bool),
    Ident(String),
    Binary {
        left: Box<Expr>,
        op: BinOp,
        right: Box<Expr>,
    },
    Unary {
        op: UnaryOp,
        expr: Box<Expr>,
    },
    Call {
        func: Box<Expr>,
        args: Vec<CallArg>,
    },
    FieldAccess {
        expr: Box<Expr>,
        field: String,
    },
    Index {
        expr: Box<Expr>,
        index: Box<Expr>,
    },
    StringInterp {
        parts: Vec<StringPart>,
    },
    Range {
        start: Box<Expr>,
        end: Box<Expr>,
        inclusive: bool,
    },
    SeqLit(Vec<Expr>),
    ArrayLit(Vec<Expr>),
    TupleLit(Vec<(Option<String>, Expr)>),
    HashTableLit(Vec<(Expr, Expr)>),
    HashSetLit(Vec<Expr>),
    IfExpr {
        branches: Vec<(Expr, Vec<Stmt>)>,
        else_body: Option<Vec<Stmt>>,
    },
    Dollar(Box<Expr>),
    Question(Box<Expr>),
    Ref(Box<Expr>),          // &value
}

#[derive(Debug, Clone)]
pub enum StringPart {
    Lit(String),
    Expr(Expr),
}

#[derive(Debug, Clone)]
pub struct CallArg {
    pub name: Option<String>,
    pub value: Expr,
}

#[derive(Debug, Clone)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    NotEq,
    Less,
    LessEq,
    Greater,
    GreaterEq,
    And,
    Or,
    Pipe,
}

#[derive(Debug, Clone)]
pub enum UnaryOp {
    Neg,
    Not,
}

#[derive(Debug, Clone)]
pub enum Stmt {
    // Variable declarations: name@ = val, name@ mut = val, name@ const = val
    Decl {
        name: String,
        public: bool,
        modifier: DeclModifier,
        value: Option<Expr>,
    },

    // Assignment
    Assign {
        target: Expr,
        value: Expr,
    },
    ResultAssign {
        value: Expr,
    },

    // Functions: name@ fn(params) -> RetType:
    FnDecl {
        name: String,
        public: bool,
        params: Vec<Param>,
        return_type: Option<TypeExpr>,
        error_types: Vec<TypeExpr>,
        body: Vec<Stmt>,
    },

    // Control flow
    If {
        branches: Vec<(Expr, Vec<Stmt>)>,
        else_body: Option<Vec<Stmt>>,
    },
    While {
        condition: Expr,
        label: Option<String>,
        body: Vec<Stmt>,
    },
    For {
        var: String,
        iter: Expr,
        label: Option<String>,
        body: Vec<Stmt>,
        else_body: Option<Vec<Stmt>>,
    },
    Break(Option<String>),
    Continue(Option<String>),
    Return,

    // Block
    Block {
        label: Option<String>,
        body: Vec<Stmt>,
    },

    // Expressions as statements
    ExprStmt(Expr),

    // Type declarations: Name@ object: / Name@ enum:
    ObjectDecl {
        name: String,
        public: bool,
        parent: Option<String>,
        fields: Vec<TypeField>,
    },
    EnumDecl {
        name: String,
        public: bool,
        variants: Vec<EnumVariant>,
    },

    // Module
    Import(String),
    FromImport {
        module: String,
        names: Vec<String>,
    },
    FromExport {
        module: String,
        names: Vec<String>,
    },
    ExportModule(String),

    // Concurrency
    Spawn(Vec<Stmt>),
    Detach {
        body: Vec<Stmt>,
    },

    // Error handling
    Raise(Expr),
    Quit(Option<Expr>),

    // Case
    Case {
        expr: Expr,
        branches: Vec<CaseBranch>,
        else_body: Option<Vec<Stmt>>,
    },

    // Discard
    Discard,
}

#[derive(Debug, Clone)]
pub enum DeclModifier {
    Default,  // immutable (x@ = 42)
    Mut,      // mutable   (x@ mut = 42)
    Const,    // constant  (x@ const = 42)
}

#[derive(Debug, Clone)]
pub struct Param {
    pub name: String,
    pub mutable: bool,
    pub type_ann: TypeExpr,
}

#[derive(Debug, Clone)]
pub struct TypeField {
    pub name: String,
    pub public: bool,
    pub type_ann: TypeExpr,
}

#[derive(Debug, Clone)]
pub struct EnumVariant {
    pub name: String,
    pub value: Option<EnumValue>,
}

#[derive(Debug, Clone)]
pub enum EnumValue {
    Int(i64),
    String(String),
    Fields(Vec<(String, TypeExpr)>),
}

#[derive(Debug, Clone)]
pub struct CaseBranch {
    pub pattern: CasePattern,
    pub body: Vec<Stmt>,
}

#[derive(Debug, Clone)]
pub enum CasePattern {
    Variant(String),
    Ok,
    Error(Option<String>),
    Some,
    None,
}

#[derive(Debug, Clone)]
pub enum TypeExpr {
    Named(String),
    Generic {
        name: String,
        args: Vec<TypeExpr>,
    },
    Array {
        elem: Box<TypeExpr>,
        size: usize,
    },
    Seq(Box<TypeExpr>),
    Slice(Box<TypeExpr>),
    Option(Box<TypeExpr>),
    Tuple(Vec<(Option<String>, TypeExpr)>),
    Fn {
        params: Vec<TypeExpr>,
        return_type: Option<Box<TypeExpr>>,
    },
    ErrorUnion {
        ok_type: Box<TypeExpr>,
        error_types: Vec<TypeExpr>,
    },
    Ref(Box<TypeExpr>),  // &Type
}
