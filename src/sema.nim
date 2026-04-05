## Semantic analyzer for the Iris language
## Runs between parser and codegen.
##
## Current checks:
##   - Seq[T] cannot be stored in object/error/tuple fields (dangling reference)
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
    isHeap: bool  # true for String, List, HashTable, HashSet
    isRef: bool       # true if this variable is a reference to another
    isMutRef: bool    # true if this is a mutable reference
    refSource: string # name of the source variable (if isRef)
    isOwn: bool       # true if this variable owns its value (can mv)

  Scope = object
    vars: Table[string, VarInfo]

  SemaContext* = object
    errors*: seq[string]
    scopes: seq[Scope]       # lexical scope stack
    initVars: HashSet[string] # definitely-initialized variable names
    knownTypes: HashSet[string]
    fnParams: HashSet[string]  # current function's parameter names (always initialized)
    movedVars: HashSet[string] # variables moved via result = x
    immBorrows: Table[string, int]    # source var -> count of immutable refs
    mutBorrow: Table[string, string]  # source var -> name of mutable ref holder
    fnParamMods: Table[string, seq[ParamModifier]]  # func name -> param modifiers
    currentFnReturnsBorrow: bool  # true if current function returns Seq/str
    currentFnReturnType: TypeExpr  # current function's return type
    currentFnBorrowParams: HashSet[string]  # borrow param names in current function
    guardedVars: HashSet[string]  # Option/Result vars checked by if/case (valid for ^)
    filename: string           # source file path
    currentLine: int           # line of the statement being analyzed
    # Closure capture tracking
    fnScopeDepth: int                      # scope index at current function boundary (-1 = top level)
    currentCaptures: ptr seq[CaptureInfo]  # captures list for current closure (nil = not in closure)
    currentClosureIsMv: bool              # whether current closure uses own captures

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
    # Remove scope-local vars from initVars and clean up borrow tracking
    let top = ctx.scopes[^1]
    for name, info in top.vars.pairs:
      ctx.initVars.excl(name)
      # If this var was a ref, decrement borrow count
      if info.isRef and info.refSource.len > 0:
        if info.isMutRef:
          ctx.mutBorrow.del(info.refSource)
        else:
          let count = ctx.immBorrows.getOrDefault(info.refSource, 0)
          if count <= 1:
            ctx.immBorrows.del(info.refSource)
          else:
            ctx.immBorrows[info.refSource] = count - 1
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

proc lookupVarInfo(ctx: SemaContext, name: string): VarInfo =
  for i in countdown(ctx.scopes.len - 1, 0):
    if name in ctx.scopes[i].vars:
      return ctx.scopes[i].vars[name]
  return VarInfo()

proc lookupVarDepth(ctx: SemaContext, name: string): int =
  ## Return the scope index where variable is declared, or -1
  for i in countdown(ctx.scopes.len - 1, 0):
    if name in ctx.scopes[i].vars:
      return i
  return -1

proc markInitialized(ctx: var SemaContext, name: string) =
  ctx.initVars.incl(name)

proc isInitialized(ctx: SemaContext, name: string): bool =
  name in ctx.initVars or name in ctx.fnParams

# ── Type checks ──

proc isViewType(t: TypeExpr): bool =
  ## Check if type is view[T] — a borrowed slice that cannot be stored
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

proc isHeapTypeAnn(t: TypeExpr): bool =
  ## Check if type annotation is a heap type
  if t == nil: return false
  if t of NamedType:
    return NamedType(t).name == "String"
  if t of GenericType:
    let name = GenericType(t).name
    return name in ["List", "HashTable", "HashSet", "Heap"]
  return false

proc isCopyType(t: TypeExpr): bool =
  ## Check if type is a primitive that can be implicitly copied (no move needed)
  if t == nil: return false  # unknown type — be conservative
  if t of NamedType:
    return NamedType(t).name in ["int", "int8", "int16", "int32", "int64",
      "uint", "uint8", "uint16", "uint32", "uint64",
      "float", "float32", "float64", "bool", "rune", "natural", "str"]
  return false

proc isPartialMove(e: Expr): bool =
  ## Check if expression is a field access or index into a variable (partial move)
  if e of FieldAccessExpr: return true
  if e of IndexExpr: return true
  return false

proc isHeapExpr(e: Expr): bool =
  ## Check if expression produces a heap value (~ prefix or String literal)
  if e == nil: return false
  if e of StrLitExpr or e of StrInterpExpr: return true  # ~"..."
  if e of SeqLitExpr: return true  # ~[...]
  if e of HashTableLitExpr: return true  # ~{k: v}
  if e of HashSetLitExpr: return true  # ~{v}
  if e of HeapAllocExpr: return true  # ~Type(...)
  return false

proc inferType(ctx: SemaContext, e: Expr): TypeExpr =
  ## Infer type from expression
  if e == nil: return nil
  if e of IntLitExpr: return NamedType(name: "int")
  if e of FloatLitExpr: return NamedType(name: "float")
  if e of BoolLitExpr: return NamedType(name: "bool")
  if e of RuneLitExpr: return NamedType(name: "rune")
  if e of StringLitExpr: return NamedType(name: "str")
  # StringInterpExpr without ~ is a compile error (handled in analyzeExpr)
  if e of StrLitExpr or e of StrInterpExpr: return NamedType(name: "String")
  if e of IdentExpr:
    let info = ctx.lookupVarInfo(IdentExpr(e).name)
    return info.typeAnn
  return nil

proc isBorrowType(t: TypeExpr): bool =
  ## Check if return type is a borrow (str)
  if t == nil: return false
  if t of NamedType:
    return NamedType(t).name == "str"
  return false

proc isStrType(t: TypeExpr): bool =
  ## Check if type is `str`
  if t == nil: return false
  if t of NamedType:
    return NamedType(t).name == "str"
  return false

proc checkFieldsNoView(ctx: var SemaContext, typeName: string, fields: seq[TypeField]) =
  ## Reject view[T] in struct/object fields — views are borrowed slices
  ## that may dangle if stored.
  for f in fields:
    if isViewType(f.typeAnn):
      ctx.error("error: field '" & f.name & "' in '" & typeName &
        "' has type " & typeToStr(f.typeAnn) &
        " — view cannot be stored in fields (borrowed slice may dangle)")

proc checkVariantFieldsNoView(ctx: var SemaContext, typeName: string, variant: ObjectVariant) =
  if variant.tagName.len == 0: return
  for branch in variant.branches:
    for f in branch.fields:
      if isViewType(f.typeAnn):
        ctx.error("error: variant field '" & f.name & "' in '" & typeName &
          "' has type " & typeToStr(f.typeAnn) &
          " — view cannot be stored in fields (borrowed slice may dangle)")

# ── AST walking ──

proc analyzeExpr(ctx: var SemaContext, e: Expr)
proc analyzeStmt(ctx: var SemaContext, s: Stmt)
proc analyzeBody(ctx: var SemaContext, body: seq[Stmt])

proc analyzeExpr(ctx: var SemaContext, e: Expr) =
  if e == nil: return

  if e of IdentExpr:
    let name = IdentExpr(e).name
    if ctx.lookupVar(name):
      # Check use-after-move
      if name in ctx.movedVars:
        ctx.error("error: variable '" & name & "' used after move — ownership was transferred")
      # Declared — check assigned-before-use
      elif not ctx.isInitialized(name):
        ctx.error("error: variable '" & name & "' used before initialization")
      # Closure capture detection
      elif ctx.currentCaptures != nil:
        let varDepth = ctx.lookupVarDepth(name)
        if varDepth >= 0 and varDepth < ctx.fnScopeDepth:
          # Variable from outer function scope — it's a capture
          let info = ctx.lookupVarInfo(name)
          # Check: view types cannot be captured (borrowed slice may dangle)
          if isViewType(info.typeAnn):
            ctx.error("error: cannot capture '" & name & "' — view types cannot be stored in closures")
          # Add to captures (avoid duplicates)
          else:
            var alreadyCaptured = false
            for cap in ctx.currentCaptures[]:
              if cap.name == name:
                alreadyCaptured = true
                break
            if not alreadyCaptured:
              let isRef = not ctx.currentClosureIsMv
              ctx.currentCaptures[].add(CaptureInfo(name: name, isRef: isRef))
              # For own closures, heap types are moved
              if ctx.currentClosureIsMv and info.isHeap:
                ctx.movedVars.incl(name)
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
    # Borrow checking and own-move tracking at call site
    if call.fn of IdentExpr:
      let fnName = IdentExpr(call.fn).name
      if fnName in ctx.fnParamMods:
        let mods = ctx.fnParamMods[fnName]
        # Check mut borrow conflicts: same variable as mut + any other param
        let argCount = min(mods.len, call.args.len)
        for i in 0..<argCount:
          if mods[i] == paramMut and call.args[i].value of IdentExpr:
            let mutName = IdentExpr(call.args[i].value).name
            for j in (i+1)..<argCount:
              if call.args[j].value of IdentExpr and IdentExpr(call.args[j].value).name == mutName:
                if mods[j] == paramMut:
                  ctx.error("error: variable '" & mutName & "' passed as mut to multiple parameters")
                else:
                  ctx.error("error: variable '" & mutName & "' cannot be passed as both mut and immutable")
        # Mark own params as moved
        for i in 0..<min(mods.len, call.args.len):
          if mods[i] == paramMv and call.args[i].value of IdentExpr:
            ctx.movedVars.incl(IdentExpr(call.args[i].value).name)

  elif e of FieldAccessExpr:
    ctx.analyzeExpr(FieldAccessExpr(e).expr)

  elif e of IndexExpr:
    ctx.analyzeExpr(IndexExpr(e).expr)
    ctx.analyzeExpr(IndexExpr(e).index)

  elif e of StringInterpExpr:
    ctx.error("error: string interpolation requires ~ prefix — use ~\"...{expr}...\" (allocates on heap)")
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

  elif e of UnwrapExpr:
    let uw = UnwrapExpr(e)
    ctx.analyzeExpr(uw.expr)
    # Check that the unwrapped variable is guarded by if/case
    if uw.expr of IdentExpr:
      let name = IdentExpr(uw.expr).name
      if name notin ctx.guardedVars:
        ctx.error("error: '->" & name & "' — Option/Result must be checked before unwrap (use 'if " & name & ":' or 'case " & name & ":')")

  elif e of QuestionExpr:
    ctx.analyzeExpr(QuestionExpr(e).expr)

  elif e of LambdaExpr:
    let lam = LambdaExpr(e)
    # Save closure context
    let savedFnScopeDepth = ctx.fnScopeDepth
    let savedCaptures = ctx.currentCaptures
    let savedClosureIsOwn = ctx.currentClosureIsMv
    let savedParams = ctx.fnParams
    let savedMoved = ctx.movedVars
    # Set up closure context
    ctx.fnScopeDepth = ctx.scopes.len  # current depth = function boundary
    ctx.currentCaptures = addr(lam.captures)
    ctx.currentClosureIsMv = lam.isMv
    ctx.fnParams = initHashSet[string]()
    # Push scope for lambda params
    ctx.pushScope()
    for p in lam.params:
      ctx.declareVar(p.name, VarInfo(name: p.name, modifier: declDefault, typeAnn: p.typeAnn, isOwn: p.modifier == paramMv))
      ctx.fnParams.incl(p.name)
      ctx.markInitialized(p.name)
    # Analyze body
    ctx.analyzeExpr(lam.body)
    ctx.popScope()
    # Restore closure context
    ctx.fnScopeDepth = savedFnScopeDepth
    ctx.currentCaptures = savedCaptures
    ctx.currentClosureIsMv = savedClosureIsOwn
    ctx.fnParams = savedParams
    # For own closures, propagate moved vars to outer scope (heap captures are moved)
    if lam.isMv:
      for cap in lam.captures:
        if not cap.isRef:
          let info = ctx.lookupVarInfo(cap.name)
          if info.isHeap:
            ctx.movedVars.incl(cap.name)
    else:
      ctx.movedVars = savedMoved

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
    # Determine if this is a heap type
    var heap = isHeapTypeAnn(d.typeAnn) or (d.value != nil and isHeapExpr(d.value))
    # Partial move check: cannot move a field/element out of a struct/collection
    if d.value != nil and isPartialMove(d.value):
      if d.value of FieldAccessExpr and FieldAccessExpr(d.value).expr of IdentExpr:
        let srcName = IdentExpr(FieldAccessExpr(d.value).expr).name
        let srcInfo = ctx.lookupVarInfo(srcName)
        if srcInfo.isHeap:
          ctx.error("error: cannot move field out of struct — move the whole value or copy it")
    # Reference and move tracking for lvalue assignments
    var isRef = false
    var isMutRef = false
    var refSource = ""
    if d.value != nil and d.value of IdentExpr:
      let srcName = IdentExpr(d.value).name
      let srcInfo = ctx.lookupVarInfo(srcName)
      if d.isMv:
        # mv — ownership transfer: only allowed if source owns the value
        if not srcInfo.isOwn:
          ctx.error("error: cannot move '" & srcName & "' — it is a reference, not an owner. Only owned values can be moved")
        else:
          heap = heap or srcInfo.isHeap
          ctx.movedVars.incl(srcName)
          # If source was a mut ref, also invalidate the original
          if srcInfo.isRef and srcInfo.refSource.len > 0:
            ctx.movedVars.incl(srcInfo.refSource)
      elif isCopyType(srcInfo.typeAnn):
        # Copy type (int, float, bool, str, etc.) — just copy the value, no borrow tracking
        discard
      else:
        # Non-copy, no mv — this is a reference (borrow)
        # Resolve the ultimate source (if srcName is itself a ref, follow the chain)
        let ultimateSrc = if srcInfo.isRef and srcInfo.refSource.len > 0: srcInfo.refSource else: srcName
        isRef = true
        refSource = ultimateSrc
        if d.modifier == declMut:
          # Mutable ref — check exclusivity
          isMutRef = true
          if ultimateSrc in ctx.mutBorrow:
            ctx.error("error: cannot create second mutable reference to '" & ultimateSrc & "'")
          elif ctx.immBorrows.getOrDefault(ultimateSrc, 0) > 0:
            ctx.error("error: cannot create mutable reference to '" & ultimateSrc & "' — immutable references exist")
          else:
            ctx.mutBorrow[ultimateSrc] = d.name
        else:
          # Immutable ref — check no mut ref exists
          if ultimateSrc in ctx.mutBorrow:
            ctx.error("error: cannot borrow '" & ultimateSrc & "' — mutable reference exists (held by '" & ctx.mutBorrow[ultimateSrc] & "')")
          else:
            ctx.immBorrows[ultimateSrc] = ctx.immBorrows.getOrDefault(ultimateSrc, 0) + 1
    # Infer type if not explicitly annotated
    let resolvedType = if d.typeAnn != nil: d.typeAnn
                       elif d.value != nil: ctx.inferType(d.value)
                       else: nil
    # Declare the variable — owned if rvalue or mv, not owned if ref
    let own = not isRef
    ctx.declareVar(d.name, VarInfo(name: d.name, modifier: d.modifier, typeAnn: resolvedType,
                                   isHeap: heap, isRef: isRef, isMutRef: isMutRef, refSource: refSource, isOwn: own))
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
    # mv tracking for reassignment
    if a.isMv and a.value of IdentExpr:
      let srcName = IdentExpr(a.value).name
      let srcInfo = ctx.lookupVarInfo(srcName)
      if not srcInfo.isOwn:
        ctx.error("error: cannot move '" & srcName & "' — it is a reference, not an owner. Only owned values can be moved")
      else:
        ctx.movedVars.incl(srcName)
        if srcInfo.isRef and srcInfo.refSource.len > 0:
          ctx.movedVars.incl(srcInfo.refSource)
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
    let rs = ResultAssignStmt(s)
    ctx.analyzeExpr(rs.value)
    # Partial move check: cannot move a field/element out of a struct/collection
    if isPartialMove(rs.value):
      ctx.error("error: cannot move field out of struct — move the whole value or copy it")
    # Type check: owned type cannot be returned as Seq/str
    if ctx.currentFnReturnsBorrow and rs.value of IdentExpr:
      let srcName = IdentExpr(rs.value).name
      if srcName != "result":
        let srcInfo = ctx.lookupVarInfo(srcName)
        if srcInfo.isHeap:
          if isHeapTypeAnn(srcInfo.typeAnn):
            ctx.error("error: type mismatch — expected " &
              typeToStr(ctx.currentFnReturnType) & ", got " &
              typeToStr(srcInfo.typeAnn))
          else:
            ctx.error("error: cannot return '" & srcName &
              "' — it is a Seq of local data that will be freed")
    # result = variable requires mv for non-copy types
    if rs.value of IdentExpr:
      let srcName = IdentExpr(rs.value).name
      if srcName != "result":
        let srcInfo = ctx.lookupVarInfo(srcName)
        if rs.isMv:
          if not srcInfo.isOwn:
            ctx.error("error: cannot move '" & srcName & "' — it is a reference, not an owner. Only owned values can be moved")
          else:
            ctx.movedVars.incl(srcName)
            if srcInfo.isRef and srcInfo.refSource.len > 0:
              ctx.movedVars.incl(srcInfo.refSource)
        elif not isCopyType(srcInfo.typeAnn):
          # Non-copy type: must use mv to return
          ctx.error("error: cannot return reference to local variable '" & srcName & "' — use 'result = mv " & srcName & "'")

  elif s of FnDeclStmt:
    let f = FnDeclStmt(s)
    # Declare the function name in current scope
    ctx.declareVar(f.name, VarInfo(name: f.name, modifier: declDefault))
    ctx.markInitialized(f.name)
    # Track param modifiers for borrow checking at call sites
    ctx.fnParamMods[f.name] = f.params.mapIt(it.modifier)
    # Save closure context
    let savedFnScopeDepth = ctx.fnScopeDepth
    let savedCaptures = ctx.currentCaptures
    let savedClosureIsOwn = ctx.currentClosureIsMv
    # Set up closure context for nested functions
    let isNested = ctx.currentCaptures != nil or ctx.fnScopeDepth > 0
    if isNested or f.isMv:
      ctx.fnScopeDepth = ctx.scopes.len  # current depth = function boundary
      ctx.currentCaptures = addr(f.captures)
      ctx.currentClosureIsMv = f.isMv
    else:
      ctx.currentCaptures = nil  # top-level function, no captures
      ctx.fnScopeDepth = 0
    # Analyze body in a new scope with params as initialized
    ctx.pushScope()
    let savedParams = ctx.fnParams
    let savedMoved = ctx.movedVars
    let savedReturnsBorrow = ctx.currentFnReturnsBorrow
    let savedReturnType = ctx.currentFnReturnType
    let savedBorrowParams = ctx.currentFnBorrowParams
    ctx.fnParams = initHashSet[string]()
    ctx.movedVars = initHashSet[string]()
    ctx.currentFnReturnsBorrow = isBorrowType(f.returnType)
    ctx.currentFnReturnType = f.returnType
    ctx.currentFnBorrowParams = initHashSet[string]()
    for p in f.params:
      # str cannot be passed as mut — it references read-only data (.rodata)
      if p.modifier == paramMut and isStrType(p.typeAnn):
        ctx.error("error: parameter '" & p.name & "' has type str which cannot be mut — it references read-only data (.rodata)")
      ctx.declareVar(p.name, VarInfo(name: p.name, modifier: declDefault, typeAnn: p.typeAnn, isOwn: p.modifier == paramMv))
      ctx.fnParams.incl(p.name)
      ctx.markInitialized(p.name)
      # Track borrow params (not own = borrow)
      if p.modifier != paramMv:
        ctx.currentFnBorrowParams.incl(p.name)
    # 'result' is always available in functions with return type
    if f.returnType != nil:
      ctx.fnParams.incl("result")
    ctx.analyzeBody(f.body)
    ctx.fnParams = savedParams
    ctx.currentFnReturnsBorrow = savedReturnsBorrow
    ctx.currentFnReturnType = savedReturnType
    ctx.currentFnBorrowParams = savedBorrowParams
    ctx.popScope()
    # Restore closure context, propagate moves for own captures
    if f.isMv:
      for cap in f.captures:
        if not cap.isRef:
          let info = ctx.lookupVarInfo(cap.name)
          if info.isHeap:
            ctx.movedVars.incl(cap.name)
    else:
      ctx.movedVars = savedMoved
    ctx.fnScopeDepth = savedFnScopeDepth
    ctx.currentCaptures = savedCaptures
    ctx.currentClosureIsMv = savedClosureIsOwn

  elif s of IfStmt:
    let ifS = IfStmt(s)
    # Analyze conditions
    for branch in ifS.branches:
      ctx.analyzeExpr(branch.cond)

    if ifS.elseBranch.len > 0:
      # if/elif/else — variable is initialized only if initialized in ALL branches
      # Move is confirmed only if moved in ALL branches
      let initBefore = ctx.initVars
      let movedBefore = ctx.movedVars

      var branchInits: seq[HashSet[string]]
      var branchMoves: seq[HashSet[string]]
      for branch in ifS.branches:
        ctx.initVars = initBefore
        ctx.movedVars = movedBefore
        # Guard: if condition is a simple variable, mark as guarded for ^
        let savedGuarded = ctx.guardedVars
        if branch.cond of IdentExpr:
          ctx.guardedVars.incl(IdentExpr(branch.cond).name)
        ctx.pushScope()
        ctx.analyzeBody(branch.body)
        ctx.popScope()
        ctx.guardedVars = savedGuarded
        branchInits.add(ctx.initVars)
        branchMoves.add(ctx.movedVars)

      # else branch
      ctx.initVars = initBefore
      ctx.movedVars = movedBefore
      ctx.pushScope()
      ctx.analyzeBody(ifS.elseBranch)
      ctx.popScope()
      branchInits.add(ctx.initVars)
      branchMoves.add(ctx.movedVars)

      # Intersection: only vars initialized/moved in ALL branches
      var mergedInit = branchInits[0]
      var mergedMoved = branchMoves[0]
      for i in 1..<branchInits.len:
        mergedInit = mergedInit * branchInits[i]
        mergedMoved = mergedMoved * branchMoves[i]
      ctx.initVars = mergedInit
      ctx.movedVars = mergedMoved
    else:
      # No else — can't guarantee any new initializations
      # But moves in ANY branch make the var potentially moved (union)
      let initBefore = ctx.initVars
      let movedBefore = ctx.movedVars
      var mergedMoved = movedBefore
      for branch in ifS.branches:
        ctx.initVars = initBefore
        ctx.movedVars = movedBefore
        let savedGuarded = ctx.guardedVars
        if branch.cond of IdentExpr:
          ctx.guardedVars.incl(IdentExpr(branch.cond).name)
        ctx.pushScope()
        ctx.analyzeBody(branch.body)
        ctx.popScope()
        ctx.guardedVars = savedGuarded
        mergedMoved = mergedMoved + ctx.movedVars  # union: moved in ANY branch
      ctx.initVars = initBefore
      ctx.movedVars = mergedMoved

  elif s of WhileStmt:
    let w = WhileStmt(s)
    ctx.analyzeExpr(w.condition)
    # Loop body may not execute — don't count new inits
    # But moves in body make vars potentially moved (second iteration would use-after-move)
    let initBefore = ctx.initVars
    let movedBefore = ctx.movedVars
    ctx.pushScope()
    ctx.analyzeBody(w.body)
    ctx.popScope()
    let movedInBody = ctx.movedVars
    # Check: if an outer-scope var was moved, second iteration would use-after-move
    let newMoves = movedInBody - movedBefore
    if newMoves.len > 0:
      ctx.movedVars = movedBefore + newMoves
      ctx.pushScope()
      ctx.analyzeBody(w.body)
      ctx.popScope()
    ctx.initVars = initBefore
    ctx.movedVars = movedBefore + movedInBody  # union: moved in ANY iteration

  elif s of ForStmt:
    let f = ForStmt(s)
    ctx.analyzeExpr(f.iter)
    # Loop body may not execute — don't count new inits
    # But moves in body make vars potentially moved (second iteration would use-after-move)
    let initBefore = ctx.initVars
    let movedBefore = ctx.movedVars
    ctx.pushScope()
    ctx.declareVar(f.varName, VarInfo(name: f.varName, modifier: declDefault, isOwn: true))
    ctx.markInitialized(f.varName)
    ctx.analyzeBody(f.body)
    ctx.popScope()
    let movedInBody = ctx.movedVars
    # Check: if an outer-scope var was moved in the body, the second iteration
    # would use-after-move. Run body again with those vars marked as moved.
    let newMoves = movedInBody - movedBefore
    if newMoves.len > 0:
      ctx.movedVars = movedBefore + newMoves  # simulate second iteration
      ctx.pushScope()
      ctx.declareVar(f.varName, VarInfo(name: f.varName, modifier: declDefault, isOwn: true))
      ctx.markInitialized(f.varName)
      ctx.analyzeBody(f.body)
      ctx.popScope()
    if f.elseBranch.len > 0:
      ctx.initVars = initBefore
      ctx.movedVars = movedBefore
      ctx.pushScope()
      ctx.analyzeBody(f.elseBranch)
      ctx.popScope()
    ctx.initVars = initBefore
    ctx.movedVars = movedBefore + movedInBody  # union: moved in ANY iteration

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
      let savedGuarded = ctx.guardedVars
      # Guard: case expr is guarded in of some/of Ok branches
      if cs.expr of IdentExpr and branch.pattern.kind in {patSome, patOk}:
        ctx.guardedVars.incl(IdentExpr(cs.expr).name)
      ctx.pushScope()
      ctx.analyzeBody(branch.body)
      ctx.popScope()
      ctx.guardedVars = savedGuarded
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
    movedVars: initHashSet[string](),
    immBorrows: initTable[string, int](),
    mutBorrow: initTable[string, string](),
    fnParamMods: initTable[string, seq[ParamModifier]](),
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
