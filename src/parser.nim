## Parser for the Iris language
## Produces AST from token stream

import std/tables
import token, ast

type
  Parser* = object
    tokens: seq[Token]
    pos: int

proc newParser*(tokens: seq[Token]): Parser =
  Parser(tokens: tokens, pos: 0)

# ── Token access ──

proc peek(P: Parser): TokenKind =
  if P.pos < P.tokens.len: P.tokens[P.pos].kind else: tkEof

proc current(P: Parser): Token =
  P.tokens[P.pos]

proc at(P: Parser, kind: TokenKind): bool =
  P.peek() == kind

proc advance(P: var Parser): Token =
  result = P.tokens[P.pos]
  if P.pos < P.tokens.len - 1:
    P.pos += 1

proc expect(P: var Parser, kind: TokenKind) =
  if not P.at(kind):
    let t = P.current()
    raise newException(ValueError,
      $t.line & ":" & $t.col & ": expected " & $kind & ", got " & $t.kind)
  discard P.advance()

proc skipNewlines(P: var Parser) =
  while P.at(tkNewline): discard P.advance()

proc error(P: Parser, msg: string) =
  let t = P.current()
  raise newException(ValueError, $t.line & ":" & $t.col & ": error: " & msg)

# ── @name parsing ──

type AtName = object
  name: string
  public: bool

proc parseAtName(P: var Parser): AtName =
  ## Parse @name[+] — the universal declaration prefix.
  ## Allows keywords as names (for fields/enum variants).
  P.expect(tkAt)
  let tok = P.current()
  var name: string
  if tok.kind == tkIdent:
    name = tok.strVal
    discard P.advance()
  elif tok.kind.isKeyword():
    # Keywords can be used as names after @
    name = $tok.kind
    # Convert token kind back to string
    for k, v in token.keywords:
      if v == tok.kind:
        name = k
        break
    discard P.advance()
  else:
    P.error("expected name after @")

  let public = if P.at(tkBang): discard P.advance(); true else: false
  AtName(name: name, public: public)

proc parseAtIdent(P: var Parser): string =
  ## Parse @name (identifier only, no public marker).
  P.expect(tkAt)
  if P.peek() != tkIdent:
    P.error("expected identifier after @")
  result = P.advance().strVal

proc parseIdentName(P: var Parser): string =
  if P.peek() != tkIdent:
    P.error("expected identifier, got " & $P.peek())
  result = P.advance().strVal

proc tryParseIdent(P: var Parser): string =
  ## Try to parse optional ident (for break/continue labels).
  if P.at(tkIdent): result = P.advance().strVal

# ── Type parsing ──

proc parseType*(P: var Parser): TypeExpr

proc parseType*(P: var Parser): TypeExpr =
  # func(Type, Type) ok ReturnType — function type
  if P.at(tkFunc):
    discard P.advance()
    P.expect(tkLParen)
    var paramTypes: seq[TypeExpr]
    while not P.at(tkRParen) and not P.at(tkEof):
      paramTypes.add(P.parseType())
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    var returnType: TypeExpr = nil
    if P.at(tkOk):
      discard P.advance()
      returnType = P.parseType()
    return FuncType(paramTypes: paramTypes, returnType: returnType)

  # (Type, Type) — tuple type
  if P.at(tkLParen):
    discard P.advance()
    var elems: seq[TypeExpr]
    while not P.at(tkRParen) and not P.at(tkEof):
      elems.add(P.parseType())
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    return TupleType(elems: elems)

  # Integer literal as type arg (e.g. array[int, 100])
  if P.at(tkIntLit):
    let val = P.advance().intVal
    return NamedType(name: $val)

  let name = P.parseIdentName()
  if P.at(tkLBracket):
    discard P.advance()
    var args: seq[TypeExpr]
    while not P.at(tkRBracket) and not P.at(tkEof):
      args.add(P.parseType())
      if P.at(tkComma): discard P.advance()
    P.expect(tkRBracket)
    return GenericType(name: name, args: args)
  else:
    return NamedType(name: name)

# ── Expression parsing (precedence climbing) ──

proc parseExpr*(P: var Parser): Expr
proc parseOr(P: var Parser): Expr
proc parseAnd(P: var Parser): Expr
proc parseRange(P: var Parser): Expr
proc parseComparison(P: var Parser): Expr
proc parseAddition(P: var Parser): Expr
proc parseMultiplication(P: var Parser): Expr
proc parseUnary(P: var Parser): Expr
proc parsePostfix(P: var Parser): Expr
proc parsePrimary(P: var Parser): Expr
proc parseCallArgs(P: var Parser): seq[CallArg]
proc parseParenOrTuple(P: var Parser): Expr
proc parseStmt*(P: var Parser): Stmt
proc parseBlockBody(P: var Parser): seq[Stmt]

proc parseExpr*(P: var Parser): Expr =
  result = P.parseOr()
  # Postfix if expression: value if cond else altValue
  if P.at(tkIf):
    discard P.advance()
    let cond = P.parseOr()  # condition (not parseExpr — avoid consuming nested if)
    P.expect(tkElse)
    let elseValue = P.parseExpr()  # recursive — allows chaining
    result = IfExpr(value: result, cond: cond, elseValue: elseValue)

proc parseOr(P: var Parser): Expr =
  result = P.parseAnd()
  while P.at(tkOr):
    discard P.advance()
    result = BinaryExpr(left: result, op: opOr, right: P.parseAnd())

proc parseAnd(P: var Parser): Expr =
  result = P.parseRange()
  while P.at(tkAnd):
    discard P.advance()
    result = BinaryExpr(left: result, op: opAnd, right: P.parseRange())

proc parseRange(P: var Parser): Expr =
  result = P.parseComparison()
  if P.at(tkDotDot):
    discard P.advance()
    result = RangeExpr(start: result, finish: P.parseComparison(), inclusive: true)
  elif P.at(tkDotDotLess):
    discard P.advance()
    result = RangeExpr(start: result, finish: P.parseComparison(), inclusive: false)

proc parseComparison(P: var Parser): Expr =
  result = P.parseAddition()
  while true:
    let op = case P.peek()
      of tkEqEq: opEq
      of tkNotEq: opNotEq
      of tkLess: opLess
      of tkLessEq: opLessEq
      of tkGreater: opGreater
      of tkGreaterEq: opGreaterEq
      else: break
    discard P.advance()
    result = BinaryExpr(left: result, op: op, right: P.parseAddition())

proc parseAddition(P: var Parser): Expr =
  result = P.parseMultiplication()
  while true:
    let op = case P.peek()
      of tkPlus: opAdd
      of tkMinus: opSub
      else: break
    discard P.advance()
    result = BinaryExpr(left: result, op: op, right: P.parseMultiplication())

proc parseMultiplication(P: var Parser): Expr =
  result = P.parseUnary()
  while true:
    let op = case P.peek()
      of tkStar: opMul
      of tkSlash: opDiv
      of tkPercent: opMod
      else: break
    discard P.advance()
    result = BinaryExpr(left: result, op: op, right: P.parseUnary())

proc parseUnary(P: var Parser): Expr =
  case P.peek()
  of tkMinus:
    discard P.advance()
    UnaryExpr(op: opNeg, expr: P.parseUnary())
  of tkNot:
    discard P.advance()
    UnaryExpr(op: opNot, expr: P.parseUnary())
  of tkDollar:
    discard P.advance()
    DollarExpr(expr: P.parsePostfix())
  of tkArrow:
    discard P.advance()
    UnwrapExpr(expr: P.parsePostfix())
  else:
    P.parsePostfix()

proc parsePostfix(P: var Parser): Expr =
  result = P.parsePrimary()
  while true:
    case P.peek()
    of tkLParen:
      discard P.advance()
      let args = P.parseCallArgs()
      P.expect(tkRParen)
      result = CallExpr(fn: result, args: args)
    of tkDot:
      discard P.advance()
      var field: string
      if P.at(tkIntLit):
        field = $P.advance().intVal  # tuple.0
      else:
        field = P.parseIdentName()
      result = FieldAccessExpr(expr: result, field: field)
    of tkLBracket:
      discard P.advance()
      let idx = P.parseExpr()
      P.expect(tkRBracket)
      result = IndexExpr(expr: result, index: idx)
    of tkQuestion:
      discard P.advance()
      result = QuestionExpr(expr: result)
    else:
      break

proc parsePrimary(P: var Parser): Expr =
  case P.peek()
  of tkIntLit:
    let t = P.advance()
    IntLitExpr(val: t.intVal)
  of tkFloatLit:
    let t = P.advance()
    FloatLitExpr(val: t.floatVal)
  of tkStringLit:
    let t = P.advance()
    StringLitExpr(val: t.strVal)
  of tkBoolLit:
    let t = P.advance()
    BoolLitExpr(val: t.boolVal)
  of tkRuneLit:
    let t = P.advance()
    RuneLitExpr(val: t.runeVal)
  of tkIdent:
    let t = P.advance()
    IdentExpr(name: t.strVal)
  of tkStringInterpStart:
    discard P.advance()
    var parts: seq[StringPart]
    while true:
      case P.peek()
      of tkStringLit:
        let t = P.advance()
        if t.strVal.len > 0:
          parts.add(StringPart(isExpr: false, lit: t.strVal))
      of tkIdent:
        let t = P.advance()
        parts.add(StringPart(isExpr: true, expr: IdentExpr(name: t.strVal)))
      of tkStringInterpEnd:
        let t = P.advance()
        if t.strVal.len > 0:
          parts.add(StringPart(isExpr: false, lit: t.strVal))
        break
      else: break
    StringInterpExpr(parts: parts)
  of tkStar:
    # *macroName(args) or *macroName: block
    discard P.advance()
    let name = P.parseIdentName()
    var args: seq[CallArg]
    var body: seq[Stmt]
    if P.at(tkLParen):
      discard P.advance()
      args = P.parseCallArgs()
      P.expect(tkRParen)
    if P.at(tkColon):
      P.expect(tkColon); P.skipNewlines()
      body = P.parseBlockBody()
    MacroCallExpr(name: name, args: args, body: body)
  of tkLParen:
    P.parseParenOrTuple()
  of tkLBracket:
    discard P.advance()
    if P.at(tkRBracket):
      discard P.advance()
      ArrayLitExpr(elems: @[])
    else:
      let first = P.parseExpr()
      if P.at(tkColon):
        # [value: count] → fill syntax
        discard P.advance()
        let count = P.parseExpr()
        P.expect(tkRBracket)
        ArrayLitExpr(fillValue: first, fillCount: count)
      else:
        var elems = @[first]
        while P.at(tkComma):
          discard P.advance()
          if P.at(tkRBracket): break
          elems.add(P.parseExpr())
        P.expect(tkRBracket)
        ArrayLitExpr(elems: elems)
  of tkTilde:
    discard P.advance()
    if P.at(tkStringLit):
      let t = P.advance()
      StrLitExpr(val: t.strVal)
    elif P.at(tkStringInterpStart):
      discard P.advance()
      var parts: seq[StringPart]
      while true:
        case P.peek()
        of tkStringLit:
          let t = P.advance()
          if t.strVal.len > 0:
            parts.add(StringPart(isExpr: false, lit: t.strVal))
        of tkIdent:
          let t = P.advance()
          parts.add(StringPart(isExpr: true, expr: IdentExpr(name: t.strVal)))
        of tkStringInterpEnd:
          let t = P.advance()
          if t.strVal.len > 0:
            parts.add(StringPart(isExpr: false, lit: t.strVal))
          break
        else: break
      StrInterpExpr(parts: parts)
    elif P.at(tkLBracket):
      # ~[...] → SeqLitExpr
      discard P.advance()
      if P.at(tkRBracket):
        discard P.advance()
        SeqLitExpr(elems: @[])
      elif P.at(tkColon):
        # ~[:count] → capacity-only
        discard P.advance()
        let count = P.parseExpr()
        P.expect(tkRBracket)
        SeqLitExpr(capacityOnly: true, fillCount: count)
      else:
        let first = P.parseExpr()
        if P.at(tkColon):
          # ~[value: count] → fill syntax
          discard P.advance()
          let count = P.parseExpr()
          P.expect(tkRBracket)
          SeqLitExpr(fillValue: first, fillCount: count)
        else:
          var elems = @[first]
          while P.at(tkComma):
            discard P.advance()
            if P.at(tkRBracket): break
            elems.add(P.parseExpr())
          P.expect(tkRBracket)
          SeqLitExpr(elems: elems)
    elif P.at(tkLBrace):
      # ~{...} → HashTableLitExpr or HashSetLitExpr
      discard P.advance()
      if P.at(tkRBrace):
        # ~{} → empty HashTable
        discard P.advance()
        HashTableLitExpr(entries: @[])
      else:
        # Parse first element, then check for colon to distinguish
        let first = P.parseExpr()
        if P.at(tkColon):
          # ~{key: value, ...} → HashTableLitExpr
          discard P.advance()
          var entries: seq[HashTableEntry]
          entries.add(HashTableEntry(key: first, value: P.parseExpr()))
          while P.at(tkComma):
            discard P.advance()
            if P.at(tkRBrace): break
            let k = P.parseExpr()
            P.expect(tkColon)
            entries.add(HashTableEntry(key: k, value: P.parseExpr()))
          P.expect(tkRBrace)
          HashTableLitExpr(entries: entries)
        else:
          # ~{value, ...} → HashSetLitExpr
          var elems: seq[Expr]
          elems.add(first)
          while P.at(tkComma):
            discard P.advance()
            if P.at(tkRBrace): break
            elems.add(P.parseExpr())
          P.expect(tkRBrace)
          HashSetLitExpr(elems: elems)
    elif P.at(tkIdent):
      # ~TypeName(...) → HeapAllocExpr
      let t = P.advance()
      let ident = IdentExpr(name: t.strVal)
      P.expect(tkLParen)
      let args = P.parseCallArgs()
      P.expect(tkRParen)
      HeapAllocExpr(inner: CallExpr(fn: ident, args: args))
    else:
      P.error("expected string, [, {, or type name after ~")
      nil
  of tkCase:
    # case expression (no colon): case expr of pat value of pat value else value
    # Inside (), newlines are suppressed by lexer. Inline: all on one line.
    discard P.advance()
    let expr = P.parseExpr()
    var branches: seq[CaseExprBranch]
    var elseValue: Expr = nil
    while P.at(tkOf):
      discard P.advance()
      var pat: CasePattern
      case P.peek()
      of tkOk: discard P.advance(); pat = CasePattern(kind: patOk)
      of tkSome: discard P.advance(); pat = CasePattern(kind: patSome)
      of tkNone: discard P.advance(); pat = CasePattern(kind: patNone)
      of tkIdent:
        let name = P.advance().strVal
        if name == "error": pat = CasePattern(kind: patError)
        else: pat = CasePattern(kind: patVariant, name: name)
      else: P.error("expected case pattern after 'of'")
      branches.add(CaseExprBranch(pattern: pat, value: P.parseExpr()))
    if P.at(tkElse):
      discard P.advance()
      elseValue = P.parseExpr()
    CaseExpr(expr: expr, branches: branches, elseValue: elseValue)
  of tkSome, tkNone:
    let isSome = P.peek() == tkSome
    discard P.advance()
    P.expect(tkLParen)
    let arg = P.parseExpr()
    P.expect(tkRParen)
    CallExpr(
      fn: IdentExpr(name: if isSome: "some" else: "none"),
      args: @[CallArg(value: arg)]
    )
  of tkMv:
    # mv func(...) — lambda with ownership captures
    discard P.advance()
    if not P.at(tkFunc):
      P.error("expected 'func' after 'mv'")
      return nil
    discard P.advance()
    P.expect(tkLParen)
    var params: seq[Param]
    while not P.at(tkRParen) and not P.at(tkEof):
      let name = P.parseAtIdent()
      let modifier = case P.peek()
        of tkMut: discard P.advance(); paramMut
        of tkMv: discard P.advance(); paramMv
        else: paramDefault
      let typeAnn = P.parseType()
      params.add(Param(name: name, modifier: modifier, typeAnn: typeAnn))
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    var returnType: TypeExpr = nil
    if P.at(tkOk):
      discard P.advance()
      returnType = P.parseType()
    P.expect(tkAs)
    let body = P.parseExpr()
    LambdaExpr(params: params, returnType: returnType, body: body, isMv: true)
  of tkFunc:
    # Lambda: func(@x int, @y int) ok int as expr
    discard P.advance()
    P.expect(tkLParen)
    var params: seq[Param]
    while not P.at(tkRParen) and not P.at(tkEof):
      let name = P.parseAtIdent()
      let modifier = case P.peek()
        of tkMut: discard P.advance(); paramMut
        of tkMv: discard P.advance(); paramMv
        else: paramDefault
      let typeAnn = P.parseType()
      params.add(Param(name: name, modifier: modifier, typeAnn: typeAnn))
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    var returnType: TypeExpr = nil
    if P.at(tkOk):
      discard P.advance()
      returnType = P.parseType()
    P.expect(tkAs)
    let body = P.parseExpr()
    LambdaExpr(params: params, returnType: returnType, body: body)
  else:
    P.error("unexpected token " & $P.peek())
    nil

proc parseParenOrTuple(P: var Parser): Expr =
  discard P.advance()  # skip (
  if P.at(tkRParen):
    discard P.advance()
    return TupleLitExpr(elems: @[])

  # Detect named tuple: (name=val, ...)
  var firstNamed = false
  if P.at(tkIdent):
    let saved = P.pos
    discard P.advance()
    if P.at(tkEq):
      firstNamed = true
    P.pos = saved

  if firstNamed:
    var elems: seq[TupleElem]
    while not P.at(tkRParen) and not P.at(tkEof):
      let name = P.parseIdentName()
      P.expect(tkEq)
      let val = P.parseExpr()
      elems.add(TupleElem(name: name, value: val))
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    return TupleLitExpr(elems: elems)

  let first = P.parseExpr()
  if P.at(tkComma):
    discard P.advance()
    var elems = @[TupleElem(value: first)]
    while not P.at(tkRParen) and not P.at(tkEof):
      elems.add(TupleElem(value: P.parseExpr()))
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    TupleLitExpr(elems: elems)
  else:
    P.expect(tkRParen)
    first  # just grouping

proc parseCallArgs(P: var Parser): seq[CallArg] =
  while not P.at(tkRParen) and not P.at(tkEof):
    if P.at(tkIdent):
      let saved = P.pos
      let name = P.advance().strVal
      if P.at(tkEq):
        discard P.advance()
        result.add(CallArg(name: name, value: P.parseExpr()))
      else:
        P.pos = saved
        result.add(CallArg(value: P.parseExpr()))
    else:
      result.add(CallArg(value: P.parseExpr()))
    if P.at(tkComma): discard P.advance()

# ── Typed fields (shared by object, tuple) ──

proc parseFieldsBlock(P: var Parser): seq[TypeField] =
  P.expect(tkColon)
  P.skipNewlines()
  if not P.at(tkIndent): return
  discard P.advance()
  while not P.at(tkDedent) and not P.at(tkEof):
    P.skipNewlines()
    if P.at(tkDedent): break
    let at = P.parseAtName()
    let typeAnn = P.parseType()
    result.add(TypeField(name: at.name, public: at.public, typeAnn: typeAnn))
    P.skipNewlines()
  if P.at(tkDedent): discard P.advance()

proc parseFieldsInline(P: var Parser): seq[TypeField] =
  discard P.advance()  # skip (
  while not P.at(tkRParen) and not P.at(tkEof):
    let at = P.parseAtName()
    let typeAnn = P.parseType()
    result.add(TypeField(name: at.name, public: at.public, typeAnn: typeAnn))
    if P.at(tkComma): discard P.advance()
  P.expect(tkRParen)

# ── Block body ──

proc parseBlockBody(P: var Parser): seq[Stmt] =
  if not P.at(tkIndent):
    if not P.at(tkNewline) and not P.at(tkEof):
      return @[P.parseStmt()]
    return @[]

  discard P.advance()  # skip Indent
  while not P.at(tkDedent) and not P.at(tkEof):
    P.skipNewlines()
    if P.at(tkDedent) or P.at(tkEof): break
    result.add(P.parseStmt())
    P.skipNewlines()
  if P.at(tkDedent): discard P.advance()

# ── Destructuring parsing ──

proc parseDestructPattern(P: var Parser): DestructPattern =
  ## Parse one element inside a destructuring tuple pattern.
  if P.at(tkAt):
    let at = P.parseAtName()
    var modifier = declDefault
    if P.at(tkMut):
      discard P.advance()
      modifier = declMut
    elif P.at(tkConst):
      discard P.advance()
      modifier = declConst
    # Named destructuring: @localName = fieldName
    var fieldName = ""
    if P.at(tkEq):
      discard P.advance()
      fieldName = P.parseIdentName()
    DestructPattern(kind: dpVar, name: at.name, public: at.public,
                    modifier: modifier, fieldName: fieldName)
  elif P.at(tkIdent) and P.current().strVal == "_":
    discard P.advance()
    DestructPattern(kind: dpSkip)
  elif P.at(tkLParen):
    # Nested: ( pattern, pattern, ... )
    discard P.advance()
    var children: seq[DestructPattern]
    while not P.at(tkRParen) and not P.at(tkEof):
      children.add(P.parseDestructPattern())
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    DestructPattern(kind: dpNested, children: children)
  else:
    P.error("expected @name, _, or ( in destructuring pattern")
    nil

proc parseDestructDecl(P: var Parser): Stmt =
  ## Parse: ( @a, @b ) = expr
  discard P.advance()  # skip (
  var children: seq[DestructPattern]
  while not P.at(tkRParen) and not P.at(tkEof):
    children.add(P.parseDestructPattern())
    if P.at(tkComma): discard P.advance()
  P.expect(tkRParen)
  P.expect(tkEq)
  let value = P.parseExpr()
  DestructDeclStmt(
    pattern: DestructPattern(kind: dpNested, children: children),
    value: value
  )

# ── Statement parsing ──

proc peekNext(P: Parser): TokenKind =
  if P.pos + 1 < P.tokens.len: P.tokens[P.pos + 1].kind else: tkEof

proc parseMvExpr(P: var Parser): (Expr, bool) =
  ## Parse expression, checking for leading `mv` keyword.
  ## Returns (expr, isMv).
  ## Note: `mv func(...)` is a mv-capture lambda — don't consume mv here.
  if P.at(tkMv) and P.peekNext() != tkFunc:
    discard P.advance()
    (P.parseExpr(), true)
  else:
    (P.parseExpr(), false)

proc parseDecl(P: var Parser): Stmt =
  let at = P.parseAtName()
  case P.peek()
  of tkEq:
    discard P.advance()
    let (value, isMv) = P.parseMvExpr()
    DeclStmt(name: at.name, public: at.public, modifier: declDefault, value: value, isMv: isMv)
  of tkMut:
    discard P.advance()
    if P.at(tkEq):
      # @name mut = value
      discard P.advance()
      let (value, isMv) = P.parseMvExpr()
      DeclStmt(name: at.name, public: at.public, modifier: declMut, value: value, isMv: isMv)
    else:
      # @name mut Type [= value]
      let typeAnn = P.parseType()
      if P.at(tkEq):
        discard P.advance()
        let (value, isMv) = P.parseMvExpr()
        DeclStmt(name: at.name, public: at.public, modifier: declMut, typeAnn: typeAnn, value: value, isMv: isMv)
      else:
        DeclStmt(name: at.name, public: at.public, modifier: declMut, typeAnn: typeAnn)
  of tkConst:
    discard P.advance()
    if P.at(tkEq):
      # @name const = value
      discard P.advance()
      DeclStmt(name: at.name, public: at.public, modifier: declConst, value: P.parseExpr())
    else:
      # @name const Type = value
      let typeAnn = P.parseType()
      P.expect(tkEq)
      DeclStmt(name: at.name, public: at.public, modifier: declConst, typeAnn: typeAnn, value: P.parseExpr())
  of tkIdent:
    # @name Type [= value] (type annotation, immutable)
    let typeAnn = P.parseType()
    if P.at(tkEq):
      discard P.advance()
      let (value, isMv) = P.parseMvExpr()
      DeclStmt(name: at.name, public: at.public, modifier: declDefault, typeAnn: typeAnn, value: value, isMv: isMv)
    else:
      DeclStmt(name: at.name, public: at.public, modifier: declDefault, typeAnn: typeAnn)
  of tkMv:
    # @name own func(...) — nested function with ownership captures
    discard P.advance()
    if not P.at(tkFunc):
      P.error("expected 'func' after 'mv'")
      return nil
    discard P.advance()
    P.expect(tkLParen)
    var params: seq[Param]
    while not P.at(tkRParen) and not P.at(tkEof):
      let name = P.parseAtIdent()
      let modifier = case P.peek()
        of tkMut: discard P.advance(); paramMut
        of tkMv: discard P.advance(); paramMv
        else: paramDefault
      let typeAnn = P.parseType()
      params.add(Param(name: name, modifier: modifier, typeAnn: typeAnn))
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    var returnType: TypeExpr = nil
    var errorTypes: seq[TypeExpr]
    if P.at(tkOk):
      discard P.advance()
      returnType = P.parseType()
      while P.at(tkElse):
        discard P.advance()
        errorTypes.add(P.parseType())
        while P.at(tkComma):
          discard P.advance()
          errorTypes.add(P.parseType())
    P.expect(tkColon)
    P.skipNewlines()
    let body = P.parseBlockBody()
    FnDeclStmt(name: at.name, public: at.public, isMv: true,
               params: params, returnType: returnType, errorTypes: errorTypes, body: body)
  of tkFunc:
    discard P.advance()
    # Optional generic params: func[T, U: Concept](...)
    var genericParams: seq[GenericParam]
    if P.at(tkLBracket):
      discard P.advance()
      while not P.at(tkRBracket) and not P.at(tkEof):
        let gpName = P.parseIdentName()
        var constraint = ""
        if P.at(tkColon):
          discard P.advance()
          constraint = P.parseIdentName()
        genericParams.add(GenericParam(name: gpName, constraint: constraint))
        if P.at(tkComma): discard P.advance()
      P.expect(tkRBracket)
    P.expect(tkLParen)
    var params: seq[Param]
    while not P.at(tkRParen) and not P.at(tkEof):
      let name = P.parseAtIdent()
      let modifier = case P.peek()
        of tkMut: discard P.advance(); paramMut
        of tkMv: discard P.advance(); paramMv
        else: paramDefault
      let typeAnn = P.parseType()
      params.add(Param(name: name, modifier: modifier, typeAnn: typeAnn))
      if P.at(tkComma): discard P.advance()
    P.expect(tkRParen)
    var returnType: TypeExpr = nil
    var errorTypes: seq[TypeExpr]
    if P.at(tkOk):
      discard P.advance()
      returnType = P.parseType()
      # Parse else Error1, Error2
      while P.at(tkElse):
        discard P.advance()
        errorTypes.add(P.parseType())
        while P.at(tkComma):
          discard P.advance()
          errorTypes.add(P.parseType())
    P.expect(tkColon)
    P.skipNewlines()
    let body = P.parseBlockBody()
    FnDeclStmt(name: at.name, public: at.public, genericParams: genericParams,
               params: params, returnType: returnType, errorTypes: errorTypes, body: body)
  of tkObject:
    discard P.advance()
    var parent = ""
    if P.at(tkOf):
      discard P.advance()
      parent = P.parseIdentName()
    P.expect(tkColon)
    P.skipNewlines()
    var fields: seq[TypeField]
    var variant: ObjectVariant
    if P.at(tkIndent):
      discard P.advance()
      while not P.at(tkDedent) and not P.at(tkEof):
        P.skipNewlines()
        if P.at(tkDedent): break
        if P.at(tkCase):
          # case @kind EnumType:
          discard P.advance()
          let tagName = P.parseAtIdent()
          let tagType = P.parseIdentName()
          P.expect(tkColon)
          P.skipNewlines()
          var branches: seq[VariantBranch]
          if P.at(tkIndent):
            discard P.advance()
            while not P.at(tkDedent) and not P.at(tkEof):
              P.skipNewlines()
              if P.at(tkDedent): break
              P.expect(tkOf)
              var values: seq[string]
              values.add(P.parseIdentName())
              while P.at(tkComma):
                discard P.advance()
                values.add(P.parseIdentName())
              P.expect(tkColon)
              P.skipNewlines()
              var branchFields: seq[TypeField]
              if P.at(tkIndent):
                discard P.advance()
                while not P.at(tkDedent) and not P.at(tkEof):
                  P.skipNewlines()
                  if P.at(tkDedent): break
                  if P.at(tkDiscard):
                    discard P.advance()
                  else:
                    let fat = P.parseAtName()
                    let typeAnn = P.parseType()
                    branchFields.add(TypeField(name: fat.name, public: fat.public, typeAnn: typeAnn))
                  P.skipNewlines()
                if P.at(tkDedent): discard P.advance()
              branches.add(VariantBranch(values: values, fields: branchFields))
              P.skipNewlines()
            if P.at(tkDedent): discard P.advance()
          variant = ObjectVariant(tagName: tagName, tagType: tagType, branches: branches)
        else:
          let fat = P.parseAtName()
          let typeAnn = P.parseType()
          fields.add(TypeField(name: fat.name, public: fat.public, typeAnn: typeAnn))
        P.skipNewlines()
      if P.at(tkDedent): discard P.advance()
    ObjectDeclStmt(name: at.name, public: at.public, parent: parent,
                   fields: fields, variant: variant)
  of tkEnum:
    discard P.advance()
    P.expect(tkColon)
    P.skipNewlines()
    var variants: seq[EnumVariant]
    if P.at(tkIndent):
      discard P.advance()
      while not P.at(tkDedent) and not P.at(tkEof):
        P.skipNewlines()
        if P.at(tkDedent): break
        let vat = P.parseAtName()
        var v = EnumVariant(name: vat.name, valueKind: evNone)
        if P.at(tkEq):
          discard P.advance()
          if P.at(tkIntLit):
            v.valueKind = evInt; v.intVal = P.advance().intVal
          elif P.at(tkStringLit):
            v.valueKind = evString; v.strVal = P.advance().strVal
        elif P.at(tkLParen):
          v.valueKind = evFields; v.fields = P.parseFieldsInline()
        if P.at(tkComma): discard P.advance()
        variants.add(v)
        P.skipNewlines()
      if P.at(tkDedent): discard P.advance()
    EnumDeclStmt(name: at.name, public: at.public, variants: variants)
  of tkError:
    discard P.advance()
    P.expect(tkColon)
    P.skipNewlines()
    var fields: seq[TypeField]
    var variant: ObjectVariant
    if P.at(tkIndent):
      discard P.advance()
      while not P.at(tkDedent) and not P.at(tkEof):
        P.skipNewlines()
        if P.at(tkDedent): break
        if P.at(tkCase):
          # case @kind EnumType: (same as object)
          discard P.advance()
          let tagName = P.parseAtIdent()
          let tagType = P.parseIdentName()
          P.expect(tkColon)
          P.skipNewlines()
          var branches: seq[VariantBranch]
          if P.at(tkIndent):
            discard P.advance()
            while not P.at(tkDedent) and not P.at(tkEof):
              P.skipNewlines()
              if P.at(tkDedent): break
              P.expect(tkOf)
              var values: seq[string]
              values.add(P.parseIdentName())
              while P.at(tkComma):
                discard P.advance()
                values.add(P.parseIdentName())
              P.expect(tkColon)
              P.skipNewlines()
              var branchFields: seq[TypeField]
              if P.at(tkIndent):
                discard P.advance()
                while not P.at(tkDedent) and not P.at(tkEof):
                  P.skipNewlines()
                  if P.at(tkDedent): break
                  if P.at(tkDiscard):
                    discard P.advance()
                  else:
                    let fat = P.parseAtName()
                    let typeAnn = P.parseType()
                    branchFields.add(TypeField(name: fat.name, public: fat.public, typeAnn: typeAnn))
                  P.skipNewlines()
                if P.at(tkDedent): discard P.advance()
              branches.add(VariantBranch(values: values, fields: branchFields))
              P.skipNewlines()
            if P.at(tkDedent): discard P.advance()
          variant = ObjectVariant(tagName: tagName, tagType: tagType, branches: branches)
        else:
          let fat = P.parseAtName()
          let typeAnn = P.parseType()
          fields.add(TypeField(name: fat.name, public: fat.public, typeAnn: typeAnn))
        P.skipNewlines()
      if P.at(tkDedent): discard P.advance()
    ErrorDeclStmt(name: at.name, public: at.public,
                  fields: fields, variant: variant)
  of tkConcept:
    discard P.advance()
    P.expect(tkColon)
    P.skipNewlines()
    var methods: seq[ConceptMethod]
    if P.at(tkIndent):
      discard P.advance()
      while not P.at(tkDedent) and not P.at(tkEof):
        P.skipNewlines()
        if P.at(tkDedent): break
        # @methodName func(@self, ...) ok ReturnType
        let mat = P.parseAtName()
        P.expect(tkFunc)
        P.expect(tkLParen)
        var params: seq[Param]
        while not P.at(tkRParen) and not P.at(tkEof):
          let pname = P.parseAtIdent()
          var typeAnn: TypeExpr = nil
          if not P.at(tkComma) and not P.at(tkRParen):
            typeAnn = P.parseType()
          params.add(Param(name: pname, modifier: paramDefault, typeAnn: typeAnn))
          if P.at(tkComma): discard P.advance()
        P.expect(tkRParen)
        var retType: TypeExpr = nil
        if P.at(tkOk):
          discard P.advance()
          retType = P.parseType()
        methods.add(ConceptMethod(name: mat.name, params: params, returnType: retType))
        P.skipNewlines()
      if P.at(tkDedent): discard P.advance()
    ConceptDeclStmt(name: at.name, public: at.public, methods: methods)
  of tkTuple:
    discard P.advance()
    let fields = P.parseFieldsBlock()
    TupleDeclStmt(name: at.name, public: at.public, fields: fields)
  of tkLParen:
    let fields = P.parseFieldsInline()
    TupleDeclStmt(name: at.name, public: at.public, fields: fields)
  of tkWhile:
    discard P.advance()
    let cond = P.parseExpr()
    P.expect(tkColon); P.skipNewlines()
    WhileStmt(label: at.name, condition: cond, body: P.parseBlockBody())
  of tkFor:
    discard P.advance()
    let varName = P.parseAtIdent()
    P.expect(tkIn)
    let iter = P.parseExpr()
    P.expect(tkColon); P.skipNewlines()
    let body = P.parseBlockBody()
    var elseBranch: seq[Stmt]
    if P.at(tkElse):
      discard P.advance(); P.expect(tkColon); P.skipNewlines()
      elseBranch = P.parseBlockBody()
    ForStmt(label: at.name, varName: varName, iter: iter,
            body: body, elseBranch: elseBranch)
  of tkBlock:
    discard P.advance()
    P.expect(tkColon); P.skipNewlines()
    BlockStmt(label: at.name, body: P.parseBlockBody())
  else:
    P.error("expected =, mut, const, func, object, error, enum, while, for, or block after @name")
    nil

proc parseIf(P: var Parser): Stmt =
  var branches: seq[CondBranch]
  discard P.advance()
  let cond = P.parseExpr()
  P.expect(tkColon); P.skipNewlines()
  branches.add(CondBranch(cond: cond, body: P.parseBlockBody()))
  while P.at(tkElif):
    discard P.advance()
    let c = P.parseExpr()
    P.expect(tkColon); P.skipNewlines()
    branches.add(CondBranch(cond: c, body: P.parseBlockBody()))
  var elseBranch: seq[Stmt]
  if P.at(tkElse):
    discard P.advance(); P.expect(tkColon); P.skipNewlines()
    elseBranch = P.parseBlockBody()
  IfStmt(branches: branches, elseBranch: elseBranch)

proc parseCaseBlock(P: var Parser): Stmt =
  discard P.advance()
  let expr = P.parseExpr()
  P.expect(tkColon); P.skipNewlines()
  var branches: seq[CaseBranch]
  var elseBranch: seq[Stmt]
  if P.at(tkIndent):
    discard P.advance()
    while not P.at(tkDedent) and not P.at(tkEof):
      P.skipNewlines()
      if P.at(tkDedent): break
      if P.at(tkElse):
        discard P.advance(); P.expect(tkColon); P.skipNewlines()
        elseBranch = P.parseBlockBody()
        break
      P.expect(tkOf)
      # Parse pattern — short name only
      var pat: CasePattern
      case P.peek()
      of tkOk: discard P.advance(); pat = CasePattern(kind: patOk)
      of tkSome: discard P.advance(); pat = CasePattern(kind: patSome)
      of tkNone: discard P.advance(); pat = CasePattern(kind: patNone)
      of tkIdent:
        let name = P.advance().strVal
        if name == "error": pat = CasePattern(kind: patError)
        else: pat = CasePattern(kind: patVariant, name: name)
      else: P.error("expected case pattern")
      P.expect(tkColon); P.skipNewlines()
      branches.add(CaseBranch(pattern: pat, body: P.parseBlockBody()))
      P.skipNewlines()
    if P.at(tkDedent): discard P.advance()
  if elseBranch.len == 0 and P.at(tkElse):
    discard P.advance(); P.expect(tkColon); P.skipNewlines()
    elseBranch = P.parseBlockBody()
  CaseStmt(expr: expr, branches: branches, elseBranch: elseBranch)

proc parseStmt*(P: var Parser): Stmt =
  let stmtLine = P.current().line
  case P.peek()
  of tkAt: result = P.parseDecl()
  of tkIf: result = P.parseIf()
  of tkWhile:
    discard P.advance()
    let cond = P.parseExpr()
    P.expect(tkColon); P.skipNewlines()
    result = WhileStmt(condition: cond, body: P.parseBlockBody())
  of tkFor:
    discard P.advance()
    let varName = P.parseAtIdent()
    P.expect(tkIn)
    let iter = P.parseExpr()
    P.expect(tkColon); P.skipNewlines()
    let body = P.parseBlockBody()
    var elseBranch: seq[Stmt]
    if P.at(tkElse):
      discard P.advance(); P.expect(tkColon); P.skipNewlines()
      elseBranch = P.parseBlockBody()
    result = ForStmt(varName: varName, iter: iter, body: body, elseBranch: elseBranch)
  of tkBreak:
    discard P.advance()
    result = BreakStmt(label: P.tryParseIdent())
  of tkContinue:
    discard P.advance()
    result = ContinueStmt(label: P.tryParseIdent())
  of tkReturn:
    discard P.advance()
    result = ReturnStmt()
  of tkResult:
    discard P.advance()
    if P.at(tkDot):
      discard P.advance()
      let field = P.parseIdentName()
      P.expect(tkEq)
      let (value, isMv) = P.parseMvExpr()
      result = ResultAssignStmt(field: field, value: value, isMv: isMv)
    else:
      P.expect(tkEq)
      let (value, isMv) = P.parseMvExpr()
      result = ResultAssignStmt(value: value, isMv: isMv)
  of tkBlock:
    discard P.advance()
    P.expect(tkColon); P.skipNewlines()
    result = BlockStmt(body: P.parseBlockBody())
  of tkSpawn:
    discard P.advance()
    P.expect(tkColon); P.skipNewlines()
    result = SpawnStmt(body: P.parseBlockBody())
  of tkCase: result = P.parseCaseBlock()
  of tkImport:
    discard P.advance()
    let baseName = P.parseIdentName()
    if P.at(tkSlash):
      discard P.advance()
      if P.at(tkLBracket):
        discard P.advance()
        var modules: seq[string]
        while not P.at(tkRBracket) and not P.at(tkEof):
          modules.add(baseName & "/" & P.parseIdentName())
          if P.at(tkComma): discard P.advance()
        P.expect(tkRBracket)
        result = ImportListStmt(modules: modules)
      else:
        result = ImportStmt(module: baseName & "/" & P.parseIdentName())
    else:
      result = ImportStmt(module: baseName)
  of tkFrom:
    discard P.advance()
    let module = P.parseIdentName()
    P.expect(tkImport)
    var names: seq[string]
    names.add(P.parseIdentName())
    while P.at(tkComma):
      discard P.advance()
      names.add(P.parseIdentName())
    result = FromImportStmt(module: module, names: names)
  of tkQuit:
    discard P.advance()
    var arg: Expr = nil
    if P.at(tkLParen):
      discard P.advance()
      if not P.at(tkRParen): arg = P.parseExpr()
      P.expect(tkRParen)
    result = QuitStmt(expr: arg)
  of tkDiscard:
    discard P.advance()
    result = DiscardStmt()
  else:
    # Check for tuple destructuring: ( @name, ... ) = expr
    if P.at(tkLParen):
      let saved = P.pos
      discard P.advance()  # skip (
      let isDestruct = P.at(tkAt) or
                       (P.at(tkIdent) and P.current().strVal == "_") or
                       P.at(tkLParen)
      P.pos = saved  # restore
      if isDestruct:
        result = P.parseDestructDecl()
        result.line = stmtLine
        return
    # Expression, assignment, or compound assignment
    let expr = P.parseExpr()
    if P.at(tkEq):
      discard P.advance()
      let (value, isMv) = P.parseMvExpr()
      result = AssignStmt(target: expr, value: value, isMv: isMv)
    elif P.at(tkPlusEq):
      discard P.advance()
      result = CompoundAssignStmt(target: expr, op: opAdd, value: P.parseExpr())
    elif P.at(tkMinusEq):
      discard P.advance()
      result = CompoundAssignStmt(target: expr, op: opSub, value: P.parseExpr())
    elif P.at(tkStarEq):
      discard P.advance()
      result = CompoundAssignStmt(target: expr, op: opMul, value: P.parseExpr())
    elif P.at(tkSlashEq):
      discard P.advance()
      result = CompoundAssignStmt(target: expr, op: opDiv, value: P.parseExpr())
    else:
      result = ExprStmt(expr: expr)
  result.line = stmtLine

proc parse*(P: var Parser): seq[Stmt] =
  P.skipNewlines()
  while not P.at(tkEof):
    result.add(P.parseStmt())
    P.skipNewlines()
