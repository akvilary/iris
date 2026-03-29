## Token types for the Iris language
## Designed for both compiler and LSP (semantic highlighting)

import std/tables

type
  TokenKind* = enum
    # Literals
    tkIntLit, tkFloatLit, tkStringLit, tkRuneLit, tkBoolLit
    tkStringInterpStart, tkStringInterpEnd

    # Identifiers
    tkIdent

    # Comments (preserved for LSP)
    tkComment

    # Keywords
    tkFunc, tkConst, tkMut, tkDo
    tkIf, tkElif, tkElse
    tkWhile, tkFor, tkIn
    tkBreak, tkContinue, tkReturn, tkResult
    tkBlock, tkSpawn, tkDetach
    tkObject, tkEnum, tkTuple, tkConcept
    tkImport, tkFrom, tkExport
    tkWhen, tkIsMain
    tkCase, tkOf, tkDiscard
    tkNot, tkAnd, tkOr
    tkSome, tkNone, tkOk
    tkRaise, tkQuit, tkOwn
    tkTemplate, tkMacro, tkAfter
    tkShl, tkShr, tkXor

    # Operators
    tkPlus, tkMinus, tkStar, tkSlash, tkPercent
    tkEq, tkEqEq, tkNotEq
    tkPlusEq, tkMinusEq, tkStarEq, tkSlashEq
    tkLess, tkLessEq, tkGreater, tkGreaterEq
    tkArrow       # ->
    tkDotDot      # ..
    tkDotDotLess  # ..<
    tkDot         # .
    tkColon       # :
    tkComma       # ,
    tkPipe        # |
    tkBang        # !
    tkQuestion    # ?
    tkAt          # @
    tkDollar      # $
    tkTilde       # ~
    tkAmpersand   # &

    # Delimiters
    tkLParen, tkRParen     # ( )
    tkLBracket, tkRBracket # [ ]
    tkLBrace, tkRBrace     # { }

    # Structure
    tkIndent, tkDedent, tkNewline, tkEof

  ## Semantic type — assigned by parser, used by LSP for highlighting
  SemanticKind* = enum
    semNone           # not yet classified
    semKeyword
    semVariable
    semFunction
    semType
    semProperty       # field access
    semParameter
    semEnumMember
    semString
    semNumber
    semOperator
    semComment
    semMacroCall      # *macro
    semDecorator      # @ prefix
    semLabel          # @outer while

  Token* = object
    kind*: TokenKind
    line*, col*, len*: int    # position + length for LSP
    strVal*: string           # for tkIdent, tkStringLit, tkComment, etc.
    intVal*: int64            # for tkIntLit
    floatVal*: float64        # for tkFloatLit
    runeVal*: char            # for tkRuneLit
    boolVal*: bool            # for tkBoolLit
    semantic*: SemanticKind   # set by parser for LSP

proc newToken*(kind: TokenKind, line, col, len: int): Token =
  Token(kind: kind, line: line, col: col, len: len)

proc newIdentToken*(name: string, line, col: int): Token =
  Token(kind: tkIdent, line: line, col: col, len: name.len, strVal: name)

proc newIntToken*(val: int64, line, col, len: int): Token =
  Token(kind: tkIntLit, line: line, col: col, len: len, intVal: val)

proc newFloatToken*(val: float64, line, col, len: int): Token =
  Token(kind: tkFloatLit, line: line, col: col, len: len, floatVal: val)

proc newStringToken*(val: string, line, col, len: int): Token =
  Token(kind: tkStringLit, line: line, col: col, len: len, strVal: val)

proc newBoolToken*(val: bool, line, col, len: int): Token =
  Token(kind: tkBoolLit, line: line, col: col, len: len, boolVal: val)

proc newRuneToken*(val: char, line, col, len: int): Token =
  Token(kind: tkRuneLit, line: line, col: col, len: len, runeVal: val)

proc newCommentToken*(text: string, line, col, len: int): Token =
  Token(kind: tkComment, line: line, col: col, len: len, strVal: text,
        semantic: semComment)

let keywords* = {
  "func": tkFunc, "const": tkConst, "mut": tkMut, "do": tkDo,
  "if": tkIf, "elif": tkElif, "else": tkElse,
  "while": tkWhile, "for": tkFor, "in": tkIn,
  "break": tkBreak, "continue": tkContinue, "return": tkReturn,
  "result": tkResult,
  "block": tkBlock, "spawn": tkSpawn, "detach": tkDetach,
  "object": tkObject, "enum": tkEnum, "tuple": tkTuple,
  "concept": tkConcept,
  "import": tkImport, "from": tkFrom, "export": tkExport,
  "when": tkWhen, "isMain": tkIsMain,
  "case": tkCase, "of": tkOf, "discard": tkDiscard,
  "not": tkNot, "and": tkAnd, "or": tkOr,
  "some": tkSome, "none": tkNone, "ok": tkOk,
  "raise": tkRaise, "quit": tkQuit, "own": tkOwn,
  "template": tkTemplate, "macro": tkMacro, "after": tkAfter,
  "shl": tkShl, "shr": tkShr, "xor": tkXor,
}.toTable

proc lookupKeyword*(word: string): TokenKind =
  result = keywords.getOrDefault(word, tkIdent)

proc isKeyword*(kind: TokenKind): bool =
  kind >= tkFunc and kind <= tkXor
