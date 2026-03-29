## Lexer for the Iris language
## Preserves comments for LSP, tracks token lengths

import std/[strutils, sequtils]
import token

type
  Lexer* = object
    source: string
    pos: int
    line, col: int
    indentStack: seq[int]
    tokens: seq[Token]
    atLineStart: bool

proc newLexer*(source: string): Lexer =
  Lexer(
    source: source, pos: 0,
    line: 1, col: 1,
    indentStack: @[0],
    atLineStart: true,
  )

# ── Character access ──

proc peek(L: Lexer): char =
  if L.pos < L.source.len: L.source[L.pos] else: '\0'

proc peekNext(L: Lexer): char =
  if L.pos + 1 < L.source.len: L.source[L.pos + 1] else: '\0'

proc atEnd(L: Lexer): bool =
  L.pos >= L.source.len

proc advance(L: var Lexer): char =
  result = L.source[L.pos]
  L.pos += 1
  if result == '\n':
    L.line += 1
    L.col = 1
  else:
    L.col += 1

proc error*(L: Lexer, msg: string) =
  raise newException(ValueError, $L.line & ":" & $L.col & ": error: " & msg)

# ── Indentation ──

proc currentIndent(L: Lexer): int =
  L.indentStack[^1]

proc handleIndentation(L: var Lexer) =
  var spaces = 0
  while L.peek() == ' ':
    discard L.advance()
    spaces += 1

  if L.peek() in {'\n', '#', '\0'}:
    return

  let current = L.currentIndent()
  if spaces > current:
    L.indentStack.add(spaces)
    L.tokens.add(newToken(tkIndent, L.line, L.col, 0))
  elif spaces < current:
    while L.currentIndent() > spaces:
      discard L.indentStack.pop()
      L.tokens.add(newToken(tkDedent, L.line, L.col, 0))
    if L.currentIndent() != spaces:
      L.error("inconsistent indentation")

# ── Readers ──

proc readComment(L: var Lexer) =
  let startCol = L.col
  var text = ""
  while not L.atEnd() and L.peek() != '\n':
    text.add(L.advance())
  L.tokens.add(newCommentToken(text, L.line, startCol, text.len))

proc readNumber(L: var Lexer) =
  let startCol = L.col
  var num = ""
  var isFloat = false

  while not L.atEnd():
    let ch = L.peek()
    case ch
    of '0'..'9':
      num.add(ch); discard L.advance()
    of '_':
      discard L.advance()
    of '.':
      if isFloat: break
      if L.peekNext() == '.': break
      if L.peekNext() in {'0'..'9'}:
        isFloat = true
        num.add('.'); discard L.advance()
      else: break
    else: break

  if isFloat:
    L.tokens.add(newFloatToken(parseFloat(num), L.line, startCol, num.len))
  else:
    L.tokens.add(newIntToken(parseBiggestInt(num), L.line, startCol, num.len))

proc readString(L: var Lexer) =
  let startLine = L.line
  let startCol = L.col
  discard L.advance()  # skip "

  var buf = ""
  var hasInterp = false
  var totalLen = 1  # opening quote

  while not L.atEnd():
    let ch = L.peek()
    case ch
    of '"':
      discard L.advance()
      totalLen += buf.len + 1
      if hasInterp:
        var tok = newToken(tkStringInterpEnd, L.line, L.col, 0)
        tok.strVal = buf
        L.tokens.add(tok)
      else:
        L.tokens.add(newStringToken(buf, startLine, startCol, totalLen))
      return
    of '{':
      discard L.advance()
      if not hasInterp:
        hasInterp = true
        L.tokens.add(newToken(tkStringInterpStart, startLine, startCol, 0))
      L.tokens.add(newStringToken(buf, L.line, L.col, buf.len))
      buf = ""
      # Read expression inside {}
      var expr = ""
      var depth = 1
      while not L.atEnd():
        let c = L.peek()
        if c == '}':
          depth -= 1
          if depth == 0: discard L.advance(); break
        if c == '{': depth += 1
        expr.add(c)
        discard L.advance()
      L.tokens.add(newIdentToken(expr, L.line, L.col))
    of '\\':
      discard L.advance()
      case L.peek()
      of 'n': buf.add('\n'); discard L.advance()
      of 't': buf.add('\t'); discard L.advance()
      of '\\': buf.add('\\'); discard L.advance()
      of '"': buf.add('"'); discard L.advance()
      of '{': buf.add('{'); discard L.advance()
      else: buf.add('\\')
    of '\n':
      L.error("unterminated string literal")
    else:
      buf.add(ch); discard L.advance()

  L.tokens.add(newStringToken(buf, startLine, startCol, buf.len))

proc readRune(L: var Lexer) =
  let startCol = L.col
  discard L.advance()  # skip '
  var ch: char
  var runeLen = 3  # ' + char + '

  if L.peek() == '\\':
    discard L.advance()
    runeLen = 4
    case L.advance()
    of 'n': ch = '\n'
    of 't': ch = '\t'
    of '\\': ch = '\\'
    of '\'': ch = '\''
    else: ch = '\\'
  else:
    ch = L.advance()

  if L.peek() == '\'':
    discard L.advance()
  else:
    L.error("unterminated rune literal")

  L.tokens.add(newRuneToken(ch, L.line, startCol, runeLen))

proc readIdentifier(L: var Lexer) =
  let startCol = L.col
  var word = ""

  while not L.atEnd() and (L.peek().isAlphaNumeric() or L.peek() == '_'):
    word.add(L.advance())

  if word == "true":
    L.tokens.add(newBoolToken(true, L.line, startCol, word.len))
  elif word == "false":
    L.tokens.add(newBoolToken(false, L.line, startCol, word.len))
  else:
    let kind = lookupKeyword(word)
    if kind == tkIdent:
      L.tokens.add(newIdentToken(word, L.line, startCol))
    else:
      var tok = newToken(kind, L.line, startCol, word.len)
      tok.semantic = semKeyword
      L.tokens.add(tok)

proc readOperator(L: var Lexer): bool =
  let col = L.col
  let line = L.line

  template emit1(k: TokenKind) =
    discard L.advance()
    L.tokens.add(newToken(k, line, col, 1))

  template emit2(k: TokenKind) =
    discard L.advance(); discard L.advance()
    L.tokens.add(newToken(k, line, col, 2))

  case L.peek()
  of '+': emit1(tkPlus)
  of '*': emit1(tkStar)
  of '/': emit1(tkSlash)
  of '%': emit1(tkPercent)
  of ':': emit1(tkColon)
  of ',': emit1(tkComma)
  of '|': emit1(tkPipe)
  of '?': emit1(tkQuestion)
  of '@': emit1(tkAt)
  of '$': emit1(tkDollar)
  of '~': emit1(tkTilde)
  of '&': emit1(tkAmpersand)
  of '(': emit1(tkLParen)
  of ')': emit1(tkRParen)
  of '[': emit1(tkLBracket)
  of ']': emit1(tkRBracket)
  of '{': emit1(tkLBrace)
  of '}': emit1(tkRBrace)
  of '-':
    discard L.advance()
    if L.peek() == '>':
      discard L.advance()
      L.tokens.add(newToken(tkArrow, line, col, 2))
    else:
      L.tokens.add(newToken(tkMinus, line, col, 1))
  of '=':
    discard L.advance()
    if L.peek() == '=': discard L.advance(); L.tokens.add(newToken(tkEqEq, line, col, 2))
    else: L.tokens.add(newToken(tkEq, line, col, 1))
  of '!':
    discard L.advance()
    if L.peek() == '=': discard L.advance(); L.tokens.add(newToken(tkNotEq, line, col, 2))
    else: L.tokens.add(newToken(tkBang, line, col, 1))
  of '<':
    discard L.advance()
    if L.peek() == '=': discard L.advance(); L.tokens.add(newToken(tkLessEq, line, col, 2))
    else: L.tokens.add(newToken(tkLess, line, col, 1))
  of '>':
    discard L.advance()
    if L.peek() == '=': discard L.advance(); L.tokens.add(newToken(tkGreaterEq, line, col, 2))
    else: L.tokens.add(newToken(tkGreater, line, col, 1))
  of '.':
    discard L.advance()
    if L.peek() == '.':
      discard L.advance()
      if L.peek() == '<':
        discard L.advance()
        L.tokens.add(newToken(tkDotDotLess, line, col, 3))
      else:
        L.tokens.add(newToken(tkDotDot, line, col, 2))
    else:
      L.tokens.add(newToken(tkDot, line, col, 1))
  else:
    return false
  return true

# ── Main ──

proc tokenize*(L: var Lexer): seq[Token] =
  while not L.atEnd():
    if L.atLineStart:
      L.atLineStart = false
      L.handleIndentation()
      continue

    let ch = L.peek()
    case ch
    of '\n':
      L.tokens.add(newToken(tkNewline, L.line, L.col, 1))
      discard L.advance()
      L.atLineStart = true
    of ' ', '\t', '\r':
      discard L.advance()
    of '#':
      L.readComment()
    of '"':
      L.readString()
    of '\'':
      L.readRune()
    of '0'..'9':
      L.readNumber()
    of 'a'..'z', 'A'..'Z', '_':
      L.readIdentifier()
    else:
      if not L.readOperator():
        L.error("unexpected character '" & $ch & "'")
        discard L.advance()

  while L.indentStack.len > 1:
    discard L.indentStack.pop()
    L.tokens.add(newToken(tkDedent, L.line, L.col, 0))
  L.tokens.add(newToken(tkEof, L.line, L.col, 0))

  result = L.tokens

## Filter out comments for compiler (parser doesn't need them)
proc compilerTokens*(tokens: seq[Token]): seq[Token] =
  result = tokens.filterIt(it.kind != tkComment)

import std/sequtils
