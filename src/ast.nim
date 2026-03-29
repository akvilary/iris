## AST nodes for the Iris language

type
  BinOp* = enum
    opAdd, opSub, opMul, opDiv, opMod
    opEq, opNotEq, opLess, opLessEq, opGreater, opGreaterEq
    opAnd, opOr, opPipe
    opShl, opShr, opXor

  UnaryOp* = enum
    opNeg, opNot

  DeclModifier* = enum
    declDefault   # immutable (@x = 42)
    declMut       # mutable   (@x mut = 42)
    declConst     # constant  (@x const = 42)

  ParamModifier* = enum
    paramDefault  # immutable ref (auto)
    paramMut      # mutable ref
    paramOwn      # takes ownership

  CasePatternKind* = enum
    patVariant    # enum member or union type
    patOk
    patError
    patSome
    patNone

  EnumValueKind* = enum
    evNone, evInt, evString, evFields

  # Forward declarations
  Expr* = ref object of RootObj
  Stmt* = ref object of RootObj

  # ── Expressions ──

  IntLitExpr* = ref object of Expr
    val*: int64

  FloatLitExpr* = ref object of Expr
    val*: float64

  StringLitExpr* = ref object of Expr
    val*: string

  BoolLitExpr* = ref object of Expr
    val*: bool

  RuneLitExpr* = ref object of Expr
    val*: char

  IdentExpr* = ref object of Expr
    name*: string

  BinaryExpr* = ref object of Expr
    left*, right*: Expr
    op*: BinOp

  UnaryExpr* = ref object of Expr
    op*: UnaryOp
    expr*: Expr

  CallArg* = object
    name*: string   # empty = positional
    value*: Expr

  CallExpr* = ref object of Expr
    fn*: Expr
    args*: seq[CallArg]

  FieldAccessExpr* = ref object of Expr
    expr*: Expr
    field*: string

  IndexExpr* = ref object of Expr
    expr*, index*: Expr

  StringPart* = object
    isExpr*: bool
    lit*: string
    expr*: Expr

  StringInterpExpr* = ref object of Expr
    parts*: seq[StringPart]

  RangeExpr* = ref object of Expr
    start*, finish*: Expr
    inclusive*: bool

  SeqLitExpr* = ref object of Expr
    elems*: seq[Expr]

  ArrayLitExpr* = ref object of Expr
    elems*: seq[Expr]

  TupleElem* = object
    name*: string  # empty = unnamed
    value*: Expr

  TupleLitExpr* = ref object of Expr
    elems*: seq[TupleElem]

  MacroCallExpr* = ref object of Expr
    name*: string
    args*: seq[CallArg]
    body*: seq[Stmt]   # for block macros: *macro: block

  DollarExpr* = ref object of Expr
    expr*: Expr

  QuestionExpr* = ref object of Expr
    expr*: Expr

  IfExpr* = ref object of Expr
    branches*: seq[CondBranch]
    elseBranch*: seq[Stmt]

  CondBranch* = object
    cond*: Expr
    body*: seq[Stmt]

  # ── Type expressions ──

  TypeExpr* = ref object of RootObj

  NamedType* = ref object of TypeExpr
    name*: string

  GenericType* = ref object of TypeExpr
    name*: string
    args*: seq[TypeExpr]

  TupleType* = ref object of TypeExpr
    elems*: seq[TypeExpr]

  # ── Statements ──

  DeclStmt* = ref object of Stmt
    name*: string
    public*: bool
    modifier*: DeclModifier
    value*: Expr

  DoElseStmt* = ref object of Stmt
    name*: string
    value*: Expr
    elseBody*: seq[Stmt]

  AssignStmt* = ref object of Stmt
    target*: Expr
    value*: Expr

  CompoundAssignStmt* = ref object of Stmt
    target*: Expr
    op*: BinOp
    value*: Expr

  ResultAssignStmt* = ref object of Stmt
    value*: Expr

  Param* = object
    name*: string
    modifier*: ParamModifier
    typeAnn*: TypeExpr

  FnDeclStmt* = ref object of Stmt
    name*: string
    public*: bool
    params*: seq[Param]
    returnType*: TypeExpr  # nil = void
    errorTypes*: seq[TypeExpr]  # !Error1, !Error2
    body*: seq[Stmt]

  IfStmt* = ref object of Stmt
    branches*: seq[CondBranch]
    elseBranch*: seq[Stmt]

  WhileStmt* = ref object of Stmt
    label*: string
    condition*: Expr
    body*: seq[Stmt]

  ForStmt* = ref object of Stmt
    label*: string
    varName*: string
    iter*: Expr
    body*: seq[Stmt]
    elseBranch*: seq[Stmt]

  BreakStmt* = ref object of Stmt
    label*: string

  ContinueStmt* = ref object of Stmt
    label*: string

  ReturnStmt* = ref object of Stmt

  BlockStmt* = ref object of Stmt
    label*: string
    body*: seq[Stmt]

  ExprStmt* = ref object of Stmt
    expr*: Expr

  TypeField* = object
    name*: string
    public*: bool
    typeAnn*: TypeExpr

  VariantBranch* = object
    values*: seq[string]     # enum member names (of circle, rect, ...)
    fields*: seq[TypeField]  # fields for this variant

  ObjectVariant* = object
    tagName*: string         # @kind
    tagType*: string         # ShapeKind
    branches*: seq[VariantBranch]

  ObjectDeclStmt* = ref object of Stmt
    name*: string
    public*: bool
    parent*: string
    fields*: seq[TypeField]
    variant*: ObjectVariant  # empty tagName = no variant

  EnumVariant* = object
    name*: string
    valueKind*: EnumValueKind
    intVal*: int64
    strVal*: string
    fields*: seq[TypeField]

  EnumDeclStmt* = ref object of Stmt
    name*: string
    public*: bool
    variants*: seq[EnumVariant]

  TupleDeclStmt* = ref object of Stmt
    name*: string
    public*: bool
    fields*: seq[TypeField]

  CasePattern* = object
    kind*: CasePatternKind
    name*: string  # variant name or error type

  CaseBranch* = object
    pattern*: CasePattern
    body*: seq[Stmt]

  CaseStmt* = ref object of Stmt
    expr*: Expr
    branches*: seq[CaseBranch]
    elseBranch*: seq[Stmt]

  ImportStmt* = ref object of Stmt
    module*: string

  ImportListStmt* = ref object of Stmt
    modules*: seq[string]  # import std/[a, b] → ["std/a", "std/b"]

  FromImportStmt* = ref object of Stmt
    module*: string
    names*: seq[string]

  SpawnStmt* = ref object of Stmt
    body*: seq[Stmt]

  RaiseStmt* = ref object of Stmt
    expr*: Expr

  QuitStmt* = ref object of Stmt
    expr*: Expr  # nil = no arg

  DiscardStmt* = ref object of Stmt
