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

  DestructPatternKind* = enum
    dpVar       # @name — bind a variable
    dpSkip      # _     — ignore this position
    dpNested    # (...) — nested tuple pattern

  # Forward declarations
  Expr* = ref object of RootObj
  Stmt* = ref object of RootObj
    line*: int  # source line (0 = unknown, e.g. macro-generated)

  DestructPattern* = ref object
    case kind*: DestructPatternKind
    of dpVar:
      name*: string
      public*: bool
      modifier*: DeclModifier
      fieldName*: string    # named destructuring: @q = quotient → fieldName="quotient"
    of dpSkip:
      discard
    of dpNested:
      children*: seq[DestructPattern]

  DestructDeclStmt* = ref object of Stmt
    pattern*: DestructPattern   # always dpNested at top level
    value*: Expr

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

  StrLitExpr* = ref object of Expr
    val*: string

  StrInterpExpr* = ref object of Expr
    parts*: seq[StringPart]

  RangeExpr* = ref object of Expr
    start*, finish*: Expr
    inclusive*: bool

  SeqLitExpr* = ref object of Expr
    elems*: seq[Expr]
    fillValue*: Expr    # ~[value: count] — nil if not fill syntax
    fillCount*: Expr
    capacityOnly*: bool # ~[:count] — true if capacity-only (no fill)

  ArrayLitExpr* = ref object of Expr
    elems*: seq[Expr]
    fillValue*: Expr    # [value: count] — nil if not fill syntax
    fillCount*: Expr

  HashTableEntry* = object
    key*: Expr
    value*: Expr

  HashTableLitExpr* = ref object of Expr
    entries*: seq[HashTableEntry]

  HashSetLitExpr* = ref object of Expr
    elems*: seq[Expr]

  HeapAllocExpr* = ref object of Expr
    inner*: CallExpr  # the constructor call

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
    value*: Expr       # value if condition is true
    cond*: Expr        # condition
    elseValue*: Expr   # else value (may be another IfExpr for chaining)

  CondBranch* = object
    cond*: Expr
    body*: seq[Stmt]

  CaseExprBranch* = object
    pattern*: CasePattern
    value*: Expr

  CaseExpr* = ref object of Expr
    expr*: Expr
    branches*: seq[CaseExprBranch]
    elseValue*: Expr

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
    typeAnn*: TypeExpr  # nil = inferred
    value*: Expr

  AssignStmt* = ref object of Stmt
    target*: Expr
    value*: Expr

  CompoundAssignStmt* = ref object of Stmt
    target*: Expr
    op*: BinOp
    value*: Expr

  ResultAssignStmt* = ref object of Stmt
    field*: string  # empty = whole result, non-empty = result.field
    value*: Expr

  Param* = object
    name*: string
    modifier*: ParamModifier
    typeAnn*: TypeExpr

  GenericParam* = object
    name*: string
    constraint*: string  # concept name, empty = unconstrained

  FnDeclStmt* = ref object of Stmt
    name*: string
    public*: bool
    genericParams*: seq[GenericParam]  # [T, U: Concept] — empty if not generic
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

  ErrorDeclStmt* = ref object of Stmt
    name*: string
    public*: bool
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

  ConceptMethod* = object
    name*: string
    params*: seq[Param]        # @self, @other Self, etc.
    returnType*: TypeExpr

  ConceptDeclStmt* = ref object of Stmt
    name*: string
    public*: bool
    methods*: seq[ConceptMethod]

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

  QuitStmt* = ref object of Stmt
    expr*: Expr  # nil = no arg

  DiscardStmt* = ref object of Stmt
