## Iris compiler — main entry point
## Usage: irisc <command> <file.is>
## Commands: build, run, tokens, parse, emit

import std/[os, strutils, osproc, tables]
import token, lexer, ast, parser, sema, codegen

proc compileToAst(source: string): seq[Stmt] =
  var lex = newLexer(source)
  let allTokens = lex.tokenize()
  let tokens = compilerTokens(allTokens)
  var p = newParser(tokens)
  p.parse()

proc checkSemantics(stmts: seq[Stmt], filename: string = "") =
  ## Run semantic analysis and raise on errors
  let errors = analyze(stmts, filename)
  if errors.len > 0:
    raise newException(ValueError, errors.join("\n"))

type
  ImportInfo = object
    stmts: seq[Stmt]
    fromNames: seq[string]  # empty = full import, non-empty = from import

proc resolveModule(result: var Table[string, ImportInfo], modName: string,
                   fromNames: seq[string], baseDir: string) =
  if modName in result: return
  # Module path: "mymath" → "mymath.is", "std/io" → "std/io.is"
  let modPath = baseDir / modName & ".is"
  if not fileExists(modPath):
    raise newException(ValueError, "error: module '" & modName & "' not found (" & modPath & ")")
  let modSource = readFile(modPath)
  result[modName] = ImportInfo(stmts: compileToAst(modSource), fromNames: fromNames)

proc resolveImports(stmts: seq[Stmt], baseDir: string): Table[string, ImportInfo] =
  ## Find import statements, load and parse imported modules
  for s in stmts:
    if s of ImportStmt:
      result.resolveModule(ImportStmt(s).module, @[], baseDir)
    elif s of ImportListStmt:
      for m in ImportListStmt(s).modules:
        result.resolveModule(m, @[], baseDir)
    elif s of FromImportStmt:
      result.resolveModule(FromImportStmt(s).module, FromImportStmt(s).names, baseDir)

proc compileToC(source: string, baseDir: string, filename: string = ""): string =
  let stmts = compileToAst(source)
  # Semantic analysis before codegen
  checkSemantics(stmts, filename)
  let modules = resolveImports(stmts, baseDir)
  for modName, info in modules:
    checkSemantics(info.stmts, modName & ".is")
  var gen = newCodeGen()

  # Generate main file
  # But first, we need to handle module C files separately
  if modules.len == 0:
    return gen.generate(stmts)

  # Multi-module: register imports and collect public names
  for modName, info in modules:
    let isFromImport = info.fromNames.len > 0
    let prefix = sanitizeModName(modName)
    # Short name for qualified access: utils/calc → calc
    let shortName = modName.split("/")[^1]

    if not isFromImport:
      gen.importedModules.add(shortName)
      # Map short name to sanitized prefix for C name generation
      gen.nameAliases["iris_mod_" & shortName] = prefix

    # Collect public names for access checking
    var pubNames: seq[string]
    for s in info.stmts:
      if s of FnDeclStmt and FnDeclStmt(s).public:
        pubNames.add(FnDeclStmt(s).name)
      if s of ObjectDeclStmt and ObjectDeclStmt(s).public:
        pubNames.add(ObjectDeclStmt(s).name)
      if s of EnumDeclStmt and EnumDeclStmt(s).public:
        pubNames.add(EnumDeclStmt(s).name)
      if s of DeclStmt and DeclStmt(s).public:
        pubNames.add(DeclStmt(s).name)
    gen.modulePublicNames[shortName] = pubNames

    # For from imports: check names exist and are public, register aliases
    if isFromImport:
      for name in info.fromNames:
        if name notin pubNames:
          raise newException(ValueError,
            "error: '" & name & "' is not public in module '" & modName & "'")
        gen.nameAliases[name] = prefix & "_" & name

  gen.emitPreamble()

  # Emit types from imported modules (needed by main)
  for modName, info in modules:
    gen.emit("// --- imported from " & modName & " ---\n")
    for s in info.stmts:
      if s of ObjectDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt:
        gen.genStmt(s); gen.emit("\n")
    # Extern declarations for public functions
    let prefix = sanitizeModName(modName)
    for s in info.stmts:
      if s of FnDeclStmt:
        let f = FnDeclStmt(s)
        if not f.public: continue
        let cname = prefix & "_" & f.name
        let ret = if f.returnType != nil: gen.typeToCStr(f.returnType) else: "void"
        gen.emit("extern " & ret & " " & cname & "(" & gen.formatParams(f.params) & ");\n")
        gen.fnReturnTypes[cname] = ret
    gen.emit("\n")

  # Now generate main module (types, functions, top-level)
  # Filter out import statements
  var mainStmts: seq[Stmt]
  for s in stmts:
    if not (s of ImportStmt) and not (s of ImportListStmt) and not (s of FromImportStmt):
      mainStmts.add(s)

  # Types from main
  for s in mainStmts:
    if s of ObjectDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt:
      gen.genStmt(s); gen.emit("\n")

  # Forward decls + result structs for main functions
  for s in mainStmts:
    if s of FnDeclStmt:
      let f = FnDeclStmt(s)
      if f.errorTypes.len > 0 and f.returnType != nil:
        let valType = gen.typeToCStr(f.returnType)
        let resultName = f.name & "_Result"
        if resultName notin gen.okTypes:
          gen.okTypes.add(resultName)
          gen.emit("typedef enum { " & resultName & "_Ok")
          for et in f.errorTypes:
            gen.emit(", " & resultName & "_" & gen.typeToCStr(et))
          gen.emit(" } " & resultName & "_Kind;\n")
          gen.emit("typedef struct { " & resultName & "_Kind kind; union { " & valType & " value; ")
          for et in f.errorTypes:
            let etype = gen.typeToCStr(et)
            gen.emit(etype & " " & etype & "_err; ")
          gen.emit("}; } " & resultName & ";\n")
        gen.emit(resultName & " " & f.name & "(" & gen.formatParams(f.params) & ");\n")
        gen.fnReturnTypes[f.name] = resultName
      else:
        let ret = if f.returnType != nil: gen.typeToCStr(f.returnType) else: "void"
        gen.emit(ret & " " & f.name & "(" & gen.formatParams(f.params) & ");\n")
        gen.fnReturnTypes[f.name] = ret
  gen.emit("\n")

  # Functions from main
  var topLevel: seq[Stmt]
  for s in mainStmts:
    if s of FnDeclStmt:
      gen.genStmt(s); gen.emit("\n")
    elif not (s of ObjectDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt):
      topLevel.add(s)

  if topLevel.len > 0:
    gen.emit("int main(void) {\n")
    gen.indent += 1
    for s in topLevel: gen.genStmt(s)
    gen.emitLine("return 0;")
    gen.indent -= 1
    gen.emit("}\n")

  result = gen.output

proc generateModuleC(modStmts: seq[Stmt], modName: string): string =
  ## Generate C file for a single module
  var gen = newCodeGen()
  result = gen.generateModule(modStmts, modName)

proc buildBinary(source, inputPath: string): string =
  let baseDir = parentDir(inputPath)
  let stmts = compileToAst(source)
  let modules = resolveImports(stmts, baseDir)

  var cFiles: seq[string]

  # Generate and write module C files
  for modName, info in modules:
    let modC = generateModuleC(info.stmts, modName)
    let modCPath = baseDir / modName & ".c"
    writeFile(modCPath, modC)
    cFiles.add(modCPath)

  # Generate and write main C file
  let mainC = compileToC(source, baseDir, inputPath)
  let mainCPath = inputPath.changeFileExt("c")
  writeFile(mainCPath, mainC)
  cFiles.add(mainCPath)

  # Compile all C files together
  let binPath = inputPath.changeFileExt("")
  let compilerDir = getAppDir()
  let runtimeDir = compilerDir / "runtime"
  let ccCmd = "cc " & cFiles.join(" ") & " -I" & runtimeDir & " -o " & binPath
  let (output, exitCode) = execCmdEx(ccCmd)

  # Cleanup C files
  for f in cFiles: removeFile(f)

  if exitCode != 0:
    raise newException(ValueError, "C compilation failed:\n" & output)
  binPath

proc main() =
  let args = commandLineParams()
  if args.len < 2:
    echo "Usage: irisc <command> <file.is>"
    echo "Commands: build, run, check, tokens, parse, emit"
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

    of "check":
      let stmts = compileToAst(source)
      let errors = analyze(stmts, filename)
      if errors.len > 0:
        for e in errors: echo e
        quit(1)
      else:
        echo "OK"

    of "emit":
      let baseDir = parentDir(filename)
      echo compileToC(source, baseDir, filename)

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
