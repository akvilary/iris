## Semantic analyzer for the Iris language
## Runs between parser and codegen.
##
## Current checks:
##   - view[T] cannot be stored in object/error/tuple fields (dangling reference)
##   - variables declared without init must be assigned on all paths before use
##   - undeclared variables cannot be used
##
## Future: ownership tracking, borrow checker, lifetime inference

import std/[tables, sets, strutils, sequtils]
import ast

type
  VarInfo = object
    name: string
    modifier: DeclModifier
    typeAnn: TypeExpr

  Scope = object
    vars: Table[string, VarInfo]

  SemaContext* = object
    errors*: seq[string]
    scopes: seq[Scope]       # lexical scope stack
    initVars: HashSet[string] # definitely-initialized variable names
    knownTypes: HashSet[string]
    fnParams: HashSet[string]  # current function's parameter names (always initialized)
    filename: string           # source file path
    currentLine: int           # line of the statement being analyzed

# ── Helpers ──

proc error(ctx: var SemaContext, msg: string) =
  if ctx.currentLine > 0:
    ctx.errors.add(ctx.filename & ":" & $ctx.currentLine & ": " & msg)
  else:
    ctx.errors.add(msg)

proc pushScope(ctx: var SemaContext) =
  ctx.scopes.add(Scope(vars: initTable[string, VarInfo]()))

proc popScope(ctx: var SemaContext) =
  if ctx.scopes.len > 0:
    # Remove scope-local vars from initVars
    let top = ctx.scopes[^1]
    for name in top.vars.keys:
      ctx.initVars.excl(name)
    ctx.scopes.setLen(ctx.scopes.len - 1)

proc declareVar(ctx: var SemaContext, name: string, info: VarInfo) =
  if ctx.scopes.len > 0:
    ctx.scopes[^1].vars[name] = info

proc lookupVar(ctx: SemaContext, name: string): bool =
  ## Check if variable is declared in any scope
  for i in countdown(ctx.scopes.len - 1, 0):
    if name in ctx.scopes[i].vars:
      return true
  return false

proc markInitialized(ctx: var SemaContext, name: string) =
  ctx.initVars.incl(name)

proc isInitialized(ctx: SemaContext, name: string): bool =
  name in ctx.initVars or name in ctx.fnParams

# ── Type checks ──

proc isViewType(t: TypeExpr): bool =
  ## Check if type is view[T]
  if t == nil: return false
  if t of GenericType:
    return GenericType(t).name == "view"
  return false

proc typeToStr(t: TypeExpr): string =
  ## Pretty-print a type expression for error messages
  if t == nil: return "void"
  if t of NamedType:
    return NamedType(t).name
  if t of GenericType:
    let gt = GenericType(t)
    return gt.name & "[" & gt.args.mapIt(typeToStr(it)).join(", ") & "]"
  if t of TupleType:
    return "(" & TupleType(t).elems.mapIt(typeToStr(it)).join(", ") & ")"
  return "?"

proc isStrType(t: TypeExpr): bool =
  ## Check if type is `str`
  if t == nil: return false
  if t of NamedType:
    return NamedType(t).name == "str"
  return false

proc checkFieldsNoView(ctx: var SemaContext, typeName: string, fields: seq[TypeField]) =
  ## Reject view[T] in struct/object fields — views are borrowed references
  ## that may dangle if stored.
  for f in fields:
    if isViewType(f.typeAnn):
      ctx.error("error: field '" & f.name & "' in '" & typeName &
        "' has type " & typeToStr(f.typeAnn) &
        " — views cannot be stored in fields (borrowed reference may dangle)")

proc checkVariantFieldsNoView(ctx: var SemaContext, typeName: string, variant: ObjectVariant) =
  if variant.tagName.len == 0: return
  for branch in variant.branches:
    for f in branch.fields:
      if isViewType(f.typeAnn):
        ctx.error("error: variant field '" & f.name & "' in '" & typeName &
          "' has type " & typeToStr(f.typeAnn) &
          " — views cannot be stored in fields (borrowed reference may dangle)")

# ── AST walking ──

proc analyzeExpr(ctx: var SemaContext, e: Expr)
proc analyzeStmt(ctx: var SemaContext, s: Stmt)
proc analyzeBody(ctx: var SemaContext, body: seq[Stmt])

proc analyzeExpr(ctx: var SemaContext, e: Expr) =
  if e == nil: return

  if e of IdentExpr:
    let name = IdentExpr(e).name
    if ctx.lookupVar(name):
      # Declared — check assigned-before-use
      if not ctx.isInitialized(name):
        ctx.error("error: variable '" & name & "' used before initialization")
    else:
      # Not declared in any scope
      ctx.error("error: undeclared variable '" & name & "'")

  elif e of BinaryExpr:
    ctx.analyzeExpr(BinaryExpr(e).left)
    ctx.analyzeExpr(BinaryExpr(e).right)

  elif e of UnaryExpr:
    ctx.analyzeExpr(UnaryExpr(e).expr)

  elif e of CallExpr:
    let call = CallExpr(e)
    ctx.analyzeExpr(call.fn)
    for arg in call.args:
      ctx.analyzeExpr(arg.value)

  elif e of FieldAccessExpr:
    ctx.analyzeExpr(FieldAccessExpr(e).expr)

  elif e of IndexExpr:
    ctx.analyzeExpr(IndexExpr(e).expr)
    ctx.analyzeExpr(IndexExpr(e).index)

  elif e of StringInterpExpr:
    for part in StringInterpExpr(e).parts:
      if part.isExpr: ctx.analyzeExpr(part.expr)

  elif e of StrInterpExpr:
    for part in StrInterpExpr(e).parts:
      if part.isExpr: ctx.analyzeExpr(part.expr)

  elif e of RangeExpr:
    ctx.analyzeExpr(RangeExpr(e).start)
    ctx.analyzeExpr(RangeExpr(e).finish)

  elif e of SeqLitExpr:
    let sl = SeqLitExpr(e)
    if sl.fillValue != nil: ctx.analyzeExpr(sl.fillValue)
    if sl.fillCount != nil: ctx.analyzeExpr(sl.fillCount)
    for elem in sl.elems: ctx.analyzeExpr(elem)

  elif e of ArrayLitExpr:
    let al = ArrayLitExpr(e)
    if al.fillValue != nil: ctx.analyzeExpr(al.fillValue)
    if al.fillCount != nil: ctx.analyzeExpr(al.fillCount)
    for elem in al.elems: ctx.analyzeExpr(elem)

  elif e of HashTableLitExpr:
    for entry in HashTableLitExpr(e).entries:
      ctx.analyzeExpr(entry.key)
      ctx.analyzeExpr(entry.value)

  elif e of HashSetLitExpr:
    for elem in HashSetLitExpr(e).elems: ctx.analyzeExpr(elem)

  elif e of HeapAllocExpr:
    let inner = HeapAllocExpr(e).inner
    ctx.analyzeExpr(inner.fn)
    for arg in inner.args: ctx.analyzeExpr(arg.value)

  elif e of TupleLitExpr:
    for elem in TupleLitExpr(e).elems: ctx.analyzeExpr(elem.value)

  elif e of MacroCallExpr:
    for arg in MacroCallExpr(e).args: ctx.analyzeExpr(arg.value)

  elif e of DollarExpr:
    ctx.analyzeExpr(DollarExpr(e).expr)

  elif e of QuestionExpr:
    ctx.analyzeExpr(QuestionExpr(e).expr)

  elif e of IfExpr:
    let ie = IfExpr(e)
    ctx.analyzeExpr(ie.cond)
    ctx.analyzeExpr(ie.value)
    ctx.analyzeExpr(ie.elseValue)

  elif e of CaseExpr:
    let ce = CaseExpr(e)
    ctx.analyzeExpr(ce.expr)
    for branch in ce.branches: ctx.analyzeExpr(branch.value)
    if ce.elseValue != nil: ctx.analyzeExpr(ce.elseValue)

  # Literals (IntLitExpr, FloatLitExpr, BoolLitExpr, RuneLitExpr,
  #           StringLitExpr, StrLitExpr) — nothing to check
  else:
    discard

proc analyzeBody(ctx: var SemaContext, body: seq[Stmt]) =
  for s in body:
    ctx.analyzeStmt(s)

proc analyzeStmt(ctx: var SemaContext, s: Stmt) =
  if s == nil: return
  if s.line > 0:
    ctx.currentLine = s.line

  if s of DeclStmt:
    let d = DeclStmt(s)
    # str cannot be mutable — it points to read-only .rodata
    if d.modifier == declMut and isStrType(d.typeAnn):
      ctx.error("error: 'str' cannot be declared as mut — it references read-only data (.rodata)")
    # Analyze the value expression first (before declaring the var)
    if d.value != nil:
      ctx.analyzeExpr(d.value)
    # Declare the variable
    ctx.declareVar(d.name, VarInfo(name: d.name, modifier: d.modifier, typeAnn: d.typeAnn))
    # Mark initialized if it has a value
    if d.value != nil:
      ctx.markInitialized(d.name)

  elif s of DestructDeclStmt:
    let dd = DestructDeclStmt(s)
    ctx.analyzeExpr(dd.value)
    proc declarePattern(ctx: var SemaContext, pat: DestructPattern) =
      case pat.kind
      of dpVar:
        ctx.declareVar(pat.name, VarInfo(name: pat.name, modifier: pat.modifier))
        ctx.markInitialized(pat.name)
      of dpSkip:
        discard
      of dpNested:
        for child in pat.children:
          ctx.declarePattern(child)
    ctx.declarePattern(dd.pattern)

  elif s of AssignStmt:
    let a = AssignStmt(s)
    ctx.analyzeExpr(a.value)
    # Mark target as initialized
    if a.target of IdentExpr:
      ctx.markInitialized(IdentExpr(a.target).name)
    else:
      ctx.analyzeExpr(a.target)

  elif s of CompoundAssignStmt:
    let ca = CompoundAssignStmt(s)
    # Compound assignment reads AND writes — target must be initialized first
    ctx.analyzeExpr(ca.target)
    ctx.analyzeExpr(ca.value)

  elif s of ResultAssignStmt:
    ctx.analyzeExpr(ResultAssignStmt(s).value)

  elif s of FnDeclStmt:
    let f = FnDeclStmt(s)
    # Declare the function name in current scope
    ctx.declareVar(f.name, VarInfo(name: f.name, modifier: declDefault))
    ctx.markInitialized(f.name)
    # Analyze body in a new scope with params as initialized
    ctx.pushScope()
    let savedParams = ctx.fnParams
    ctx.fnParams = initHashSet[string]()
    for p in f.params:
      # str cannot be passed as mut — it references read-only data (.rodata)
      if p.modifier == paramMut and isStrType(p.typeAnn):
        ctx.error("error: parameter '" & p.name & "' has type str which cannot be mut — it references read-only data (.rodata)")
      ctx.declareVar(p.name, VarInfo(name: p.name, modifier: declDefault, typeAnn: p.typeAnn))
      ctx.fnParams.incl(p.name)
      ctx.markInitialized(p.name)
    # 'result' is always available in functions with return type
    if f.returnType != nil:
      ctx.fnParams.incl("result")
    ctx.analyzeBody(f.body)
    ctx.fnParams = savedParams
    ctx.popScope()

  elif s of IfStmt:
    let ifS = IfStmt(s)
    # Analyze conditions
    for branch in ifS.branches:
      ctx.analyzeExpr(branch.cond)

    if ifS.elseBranch.len > 0:
      # if/elif/else — variable is initialized only if initialized in ALL branches
      let initBefore = ctx.initVars

      var branchInits: seq[HashSet[string]]
      for branch in ifS.branches:
        ctx.initVars = initBefore
        ctx.pushScope()
        ctx.analyzeBody(branch.body)
        ctx.popScope()
        branchInits.add(ctx.initVars)

      # else branch
      ctx.initVars = initBefore
      ctx.pushScope()
      ctx.analyzeBody(ifS.elseBranch)
      ctx.popScope()
      branchInits.add(ctx.initVars)

      # Intersection: only vars initialized in ALL branches
      var merged = branchInits[0]
      for i in 1..<branchInits.len:
        merged = merged * branchInits[i]  # set intersection
      ctx.initVars = merged
    else:
      # No else — can't guarantee any new initializations
      let initBefore = ctx.initVars
      for branch in ifS.branches:
        ctx.initVars = initBefore
        ctx.pushScope()
        ctx.analyzeBody(branch.body)
        ctx.popScope()
      ctx.initVars = initBefore

  elif s of WhileStmt:
    let w = WhileStmt(s)
    ctx.analyzeExpr(w.condition)
    # Loop body may not execute — don't count new inits
    let initBefore = ctx.initVars
    ctx.pushScope()
    ctx.analyzeBody(w.body)
    ctx.popScope()
    ctx.initVars = initBefore

  elif s of ForStmt:
    let f = ForStmt(s)
    ctx.analyzeExpr(f.iter)
    # Loop body may not execute
    let initBefore = ctx.initVars
    ctx.pushScope()
    ctx.declareVar(f.varName, VarInfo(name: f.varName, modifier: declDefault))
    ctx.markInitialized(f.varName)
    ctx.analyzeBody(f.body)
    ctx.popScope()
    if f.elseBranch.len > 0:
      ctx.initVars = initBefore
      ctx.pushScope()
      ctx.analyzeBody(f.elseBranch)
      ctx.popScope()
    ctx.initVars = initBefore

  elif s of BlockStmt:
    ctx.pushScope()
    ctx.analyzeBody(BlockStmt(s).body)
    ctx.popScope()

  elif s of CaseStmt:
    let cs = CaseStmt(s)
    ctx.analyzeExpr(cs.expr)

    # case is exhaustive (compiler guarantees) — treat like if/else
    let initBefore = ctx.initVars
    var branchInits: seq[HashSet[string]]

    for branch in cs.branches:
      ctx.initVars = initBefore
      ctx.pushScope()
      ctx.analyzeBody(branch.body)
      ctx.popScope()
      branchInits.add(ctx.initVars)

    if cs.elseBranch.len > 0:
      ctx.initVars = initBefore
      ctx.pushScope()
      ctx.analyzeBody(cs.elseBranch)
      ctx.popScope()
      branchInits.add(ctx.initVars)

    if branchInits.len > 0:
      var merged = branchInits[0]
      for i in 1..<branchInits.len:
        merged = merged * branchInits[i]
      ctx.initVars = merged
    else:
      ctx.initVars = initBefore

  elif s of ReturnStmt:
    discard

  elif s of BreakStmt:
    discard

  elif s of ContinueStmt:
    discard

  elif s of ExprStmt:
    ctx.analyzeExpr(ExprStmt(s).expr)

  elif s of ObjectDeclStmt:
    let obj = ObjectDeclStmt(s)
    ctx.knownTypes.incl(obj.name)
    ctx.declareVar(obj.name, VarInfo(name: obj.name, modifier: declDefault))
    ctx.markInitialized(obj.name)
    ctx.checkFieldsNoView(obj.name, obj.fields)
    ctx.checkVariantFieldsNoView(obj.name, obj.variant)

  elif s of ErrorDeclStmt:
    let err = ErrorDeclStmt(s)
    ctx.knownTypes.incl(err.name)
    ctx.declareVar(err.name, VarInfo(name: err.name, modifier: declDefault))
    ctx.markInitialized(err.name)
    ctx.checkFieldsNoView(err.name, err.fields)
    ctx.checkVariantFieldsNoView(err.name, err.variant)

  elif s of EnumDeclStmt:
    let en = EnumDeclStmt(s)
    ctx.knownTypes.incl(en.name)
    ctx.declareVar(en.name, VarInfo(name: en.name, modifier: declDefault))
    ctx.markInitialized(en.name)

  elif s of TupleDeclStmt:
    let tup = TupleDeclStmt(s)
    ctx.knownTypes.incl(tup.name)
    ctx.declareVar(tup.name, VarInfo(name: tup.name, modifier: declDefault))
    ctx.markInitialized(tup.name)
    ctx.checkFieldsNoView(tup.name, tup.fields)

  elif s of ConceptDeclStmt:
    let c = ConceptDeclStmt(s)
    ctx.knownTypes.incl(c.name)
    ctx.declareVar(c.name, VarInfo(name: c.name, modifier: declDefault))
    ctx.markInitialized(c.name)

  elif s of ImportStmt:
    # import mymath → register "mymath" as known name
    let modName = ImportStmt(s).module.split("/")[^1]
    ctx.declareVar(modName, VarInfo(name: modName, modifier: declDefault))
    ctx.markInitialized(modName)

  elif s of ImportListStmt:
    # import std/[a, b] → register "a", "b"
    for fullPath in ImportListStmt(s).modules:
      let modName = fullPath.split("/")[^1]
      ctx.declareVar(modName, VarInfo(name: modName, modifier: declDefault))
      ctx.markInitialized(modName)

  elif s of FromImportStmt:
    # from mymath import add, mul → register "add", "mul"
    for name in FromImportStmt(s).names:
      ctx.declareVar(name, VarInfo(name: name, modifier: declDefault))
      ctx.markInitialized(name)

  elif s of SpawnStmt:
    ctx.pushScope()
    ctx.analyzeBody(SpawnStmt(s).body)
    ctx.popScope()

  elif s of QuitStmt:
    if QuitStmt(s).expr != nil:
      ctx.analyzeExpr(QuitStmt(s).expr)

  elif s of DiscardStmt:
    discard

  else:
    discard

# ── Public API ──

const builtinNames = [
  # Builtin type constructors / functions
  "some", "none",
  "String", "int", "float", "bool", "rune",
  "int8", "int16", "int32", "int64",
  "uint", "uint8", "uint16", "uint32", "uint64",
  "byte", "natural",
  "str",
]

proc analyze*(stmts: seq[Stmt], filename: string = ""): seq[string] =
  ## Run semantic analysis on a list of statements.
  ## Returns a list of error messages (empty = no errors).
  var ctx = SemaContext(
    scopes: @[],
    initVars: initHashSet[string](),
    knownTypes: initHashSet[string](),
    fnParams: initHashSet[string](),
    filename: filename,
  )
  ctx.pushScope()
  # Register builtins
  for name in builtinNames:
    ctx.declareVar(name, VarInfo(name: name, modifier: declDefault))
    ctx.markInitialized(name)
  ctx.analyzeBody(stmts)
  ctx.popScope()
  return ctx.errors
