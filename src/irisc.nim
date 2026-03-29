## Iris compiler — main entry point
## Usage: irisc <command> <file.is>
## Commands: build, run, tokens, parse, emit

import std/[os, strutils, osproc]
import token, lexer, ast, parser, codegen

proc compileToAst(source: string): seq[Stmt] =
  var lex = newLexer(source)
  let allTokens = lex.tokenize()
  let tokens = compilerTokens(allTokens)  # strip comments
  var p = newParser(tokens)
  p.parse()

proc compileToC(source: string): string =
  let stmts = compileToAst(source)
  var gen = newCodeGen()
  gen.generate(stmts)

proc buildBinary(source, inputPath: string): string =
  let cCode = compileToC(source)
  let cPath = inputPath.changeFileExt("c")
  let binPath = inputPath.changeFileExt("")

  writeFile(cPath, cCode)
  let (output, exitCode) = execCmdEx("cc " & cPath & " -o " & binPath)
  removeFile(cPath)

  if exitCode != 0:
    raise newException(ValueError, "C compilation failed:\n" & output)
  binPath

proc main() =
  let args = commandLineParams()
  if args.len < 2:
    echo "Usage: irisc <command> <file.is>"
    echo "Commands: build, run, tokens, parse, emit"
    quit(1)

  let command = args[0]
  let filename = args[1]

  let source = try: readFile(filename)
                except: echo "error: cannot read " & filename; quit(1); ""

  try:
    case command
    of "tokens":
      var lex = newLexer(source)
      let tokens = lex.tokenize()
      for tok in tokens:
        echo alignLeft($tok.line, 4) & ":" & alignLeft($tok.col, 3) & " " & $tok.kind &
          (if tok.kind == tkIdent: " (" & tok.strVal & ")" else: "") &
          (if tok.kind == tkIntLit: " (" & $tok.intVal & ")" else: "") &
          (if tok.kind == tkStringLit: " (\"" & tok.strVal & "\")" else: "") &
          (if tok.kind == tkComment: " " & tok.strVal else: "")

    of "parse":
      let stmts = compileToAst(source)
      for s in stmts:
        echo repr(s)

    of "emit":
      echo compileToC(source)

    of "build":
      let bin = buildBinary(source, filename)
      echo "Built: " & bin

    of "run":
      let bin = buildBinary(source, filename)
      let exitCode = execCmd(bin)
      removeFile(bin)
      quit(exitCode)

    else:
      echo "Unknown command: " & command
      quit(1)

  except ValueError as e:
    echo e.msg
    quit(1)

main()
