## C code generator for the Iris language

import std/[strutils, tables, sequtils]
import ast

type
  VariantFieldInfo* = object
    fieldName*: string
    branchValues*: seq[string]  # which enum values allow this field

  VariantInfo* = object
    tagName*: string            # "kind"
    tagType*: string            # "ShapeKind"
    fields*: seq[VariantFieldInfo]

  CodeGen* = object
    output*: string
    indent*: int
    varTypes: Table[string, string]
    typeFields: Table[string, seq[tuple[name, ctype: string]]]
    enumNames: seq[string]
    variantInfo: Table[string, VariantInfo]  # type name -> variant info
    activeCaseBranch: Table[string, seq[string]]  # var name -> allowed variant values
    okTypes*: seq[string]  # Ok types already emitted
    fnReturnTypes*: Table[string, string]  # func name -> C return type
    inResultFunc: bool    # inside a function with error types
    currentResultName: string  # e.g. "divide_Result"
    moduleName: string    # current module name (empty = main)
    importedModules*: seq[string]  # list of imported module names
    modulePublicNames*: Table[string, seq[string]]  # module -> list of public names
    nameAliases*: Table[string, string]  # local name -> C name (from imports)

proc newCodeGen*(): CodeGen =
  CodeGen(varTypes: initTable[string, string](),
          typeFields: initTable[string, seq[tuple[name, ctype: string]]](),
          variantInfo: initTable[string, VariantInfo](),
          activeCaseBranch: initTable[string, seq[string]]())

# ── Emit helpers ──

proc emit*(g: var CodeGen, s: string) = g.output.add(s)

proc emitIndent(g: var CodeGen) =
  for _ in 0..<g.indent: g.output.add("  ")

proc emitLine*(g: var CodeGen, s: string) =
  g.emitIndent(); g.emit(s); g.emit("\n")

# ── Type mapping ──

proc typeToCStr*(g: CodeGen, t: TypeExpr): string =
  if t == nil: return "void"
  if t of NamedType:
    let n = NamedType(t).name
    case n
    of "int", "int64": "int64_t"
    of "int8": "int8_t"
    of "int16": "int16_t"
    of "int32": "int32_t"
    of "uint", "uint64": "uint64_t"
    of "uint8", "byte": "uint8_t"
    of "uint16": "uint16_t"
    of "uint32": "uint32_t"
    of "float", "float64": "double"
    of "float32": "float"
    of "bool": "bool"
    of "str": "iris_str"
    of "String": "iris_String"
    of "natural": "uint64_t"
    of "rune": "int32_t"
    else: n
  elif t of GenericType:
    let gt = GenericType(t)
    gt.name & "_" & gt.args.mapIt(g.typeToCStr(it)).join("_")
  elif t of TupleType:
    "/* tuple type */"
  else:
    "void"

proc varCType(g: CodeGen, name: string): string =
  g.varTypes.getOrDefault(name, "")

proc escapeC(s: string): string =
  for ch in s:
    case ch
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '%': result.add("%%")
    else: result.add(ch)

proc formatParams*(g: CodeGen, params: seq[Param]): string =
  if params.len == 0: return "void"
  params.mapIt(g.typeToCStr(it.typeAnn) & " " & it.name).join(", ")

proc printfFormat(g: CodeGen, e: Expr): tuple[fmt: string, needsCast: bool] =
  if e of StringLitExpr or e of StringInterpExpr: return ("%s", false)
  if e of FloatLitExpr: return ("%g", false)
  if e of BoolLitExpr: return ("%s", false)
  if e of DollarExpr: return ("%s", false)
  if e of IdentExpr:
    let ct = g.varCType(IdentExpr(e).name)
    case ct
    of "const char*", "iris_str", "iris_String": return ("%s", false)
    of "bool": return ("%s", false)
    of "double", "float": return ("%g", false)
    else: return ("%lld", true)
  if e of FieldAccessExpr:
    let fa = FieldAccessExpr(e)
    if fa.expr of IdentExpr:
      let objName = IdentExpr(fa.expr).name
      let objType = g.varCType(objName)
      if objType.len > 0 and objType in g.typeFields:
        for f in g.typeFields[objType]:
          if f.name == fa.field:
            case f.ctype
            of "double", "float": return ("%g", false)
            of "const char*", "iris_str", "iris_String": return ("%s", false)
            of "bool": return ("%s", false)
            else: return ("%lld", true)
  return ("%lld", true)

proc inferCType(g: CodeGen, e: Expr): string =
  if e of IntLitExpr: return "int64_t"
  if e of FloatLitExpr: return "double"
  if e of StringLitExpr or e of StringInterpExpr: return "iris_str"
  if e of BoolLitExpr: return "bool"
  if e of RuneLitExpr: return "int32_t"
  if e of BinaryExpr:
    let b = BinaryExpr(e)
    if b.op in {opEq, opNotEq, opLess, opLessEq, opGreater, opGreaterEq, opAnd, opOr}:
      return "bool"
    return g.inferCType(b.left)
  if e of CallExpr:
    let c = CallExpr(e)
    # .get() → unwrap, return the value type (not Result type)
    if c.fn of FieldAccessExpr:
      let fa = FieldAccessExpr(c.fn)
      if fa.field == "get":
        let ct = g.inferCType(fa.expr)
        # For Result types, .get() returns the value type — simplified for now
        return "int64_t"
    if c.fn of IdentExpr:
      let name = IdentExpr(c.fn).name
      if name in g.typeFields: return name
      if name in g.fnReturnTypes: return g.fnReturnTypes[name]
      return g.varTypes.getOrDefault(name, "int64_t")
  if e of FieldAccessExpr:
    let fa = FieldAccessExpr(e)
    if fa.expr of IdentExpr:
      let name = IdentExpr(fa.expr).name
      if name in g.enumNames: return name
      let objType = g.varCType(name)
      if objType.len > 0 and objType in g.typeFields:
        for f in g.typeFields[objType]:
          if f.name == fa.field:
            return f.ctype
  if e of IdentExpr:
    return g.varTypes.getOrDefault(IdentExpr(e).name, "int64_t")
  return "int64_t"

# ── Expression codegen ──

proc genExpr(g: var CodeGen, e: Expr)

proc genEchoArg(g: var CodeGen, e: Expr) =
  if e of BoolLitExpr:
    g.emit(if BoolLitExpr(e).val: "\"true\"" else: "\"false\"")
  elif e of IdentExpr:
    let name = IdentExpr(e).name
    let ct = g.varCType(name)
    if ct == "bool": g.emit("(" & name & " ? \"true\" : \"false\")")
    elif ct == "iris_str": g.emit(name & ".data")
    else: g.genExpr(e)
  elif e of DollarExpr:
    let inner = DollarExpr(e).expr
    if inner of IdentExpr:
      let name = IdentExpr(inner).name
      let ct = g.varCType(name)
      if ct == "bool": g.emit("(" & name & " ? \"true\" : \"false\")")
      elif ct == "iris_str": g.emit(name & ".data")
      elif ct == "const char*": g.emit(name)
      else:
        for en in g.enumNames:
          if ct == en:
            g.emit(en & "_to_string(" & name & ")")
            return
        g.emit(name)
    else:
      g.genExpr(inner)
  else:
    g.genExpr(e)

proc genEcho(g: var CodeGen, args: seq[CallArg]) =
  if args.len == 0:
    g.emit("printf(\"\\n\")"); return
  let e = args[0].value
  if e of StringLitExpr:
    g.emit("printf(\"%s\\n\", \"" & escapeC(StringLitExpr(e).val) & "\")")
  elif e of StringInterpExpr:
    var fmt = ""
    var exprs: seq[Expr]
    for p in StringInterpExpr(e).parts:
      if not p.isExpr:
        fmt.add(escapeC(p.lit))
      else:
        let (f, _) = g.printfFormat(p.expr)
        fmt.add(f)
        exprs.add(p.expr)
    fmt.add("\\n")
    g.emit("printf(\"" & fmt & "\"")
    for ex in exprs:
      let (_, needsCast) = g.printfFormat(ex)
      g.emit(", ")
      if needsCast: g.emit("(long long)")
      g.genEchoArg(ex)
    g.emit(")")
  else:
    let (fmt, needsCast) = g.printfFormat(e)
    g.emit("printf(\"" & fmt & "\\n\", ")
    if needsCast: g.emit("(long long)")
    g.genEchoArg(e)
    g.emit(")")

proc genExpr(g: var CodeGen, e: Expr) =
  if e of IntLitExpr: g.emit($IntLitExpr(e).val)
  elif e of FloatLitExpr: g.emit($FloatLitExpr(e).val)
  elif e of StringLitExpr:
    g.emit("iris_str_from(\"" & escapeC(StringLitExpr(e).val) & "\")")
  elif e of BoolLitExpr:
    g.emit(if BoolLitExpr(e).val: "true" else: "false")
  elif e of RuneLitExpr:
    g.emit("'" & $RuneLitExpr(e).val & "'")
  elif e of IdentExpr:
    let name = IdentExpr(e).name
    if name in g.nameAliases:
      g.emit(g.nameAliases[name])
    else:
      g.emit(name)
  elif e of BinaryExpr:
    let b = BinaryExpr(e)
    g.emit("("); g.genExpr(b.left)
    let opStr = case b.op
      of opAdd: " + "
      of opSub: " - "
      of opMul: " * "
      of opDiv: " / "
      of opMod: " % "
      of opEq: " == "
      of opNotEq: " != "
      of opLess: " < "
      of opLessEq: " <= "
      of opGreater: " > "
      of opGreaterEq: " >= "
      of opAnd: " && "
      of opOr: " || "
      of opPipe: " | "
      of opShl: " << "
      of opShr: " >> "
      of opXor: " ^ "
    g.emit(opStr)
    g.genExpr(b.right); g.emit(")")
  elif e of UnaryExpr:
    let u = UnaryExpr(e)
    g.emit(if u.op == opNeg: "-" else: "!")
    g.genExpr(u.expr)
  elif e of CallExpr:
    let c = CallExpr(e)
    # .get() on result → .value
    if c.fn of FieldAccessExpr:
      let fa = FieldAccessExpr(c.fn)
      if fa.field == "get" and c.args.len == 0:
        g.genExpr(fa.expr); g.emit(".value"); return
    if c.fn of IdentExpr:
      let name = IdentExpr(c.fn).name
      if name == "echo":
        g.genEcho(c.args); return
      # Struct constructor
      if name in g.typeFields:
        let fields = g.typeFields[name]
        # Check variant field validity
        if name in g.variantInfo:
          let vi = g.variantInfo[name]
          # Find which variant is active from kind= arg
          var activeVariant = ""
          for arg in c.args:
            if arg.name == vi.tagName:
              # Extract enum value: ShapeKind.circle → circle
              if arg.value of FieldAccessExpr:
                activeVariant = FieldAccessExpr(arg.value).field
          # Check each named arg against variant
          if activeVariant.len > 0:
            for arg in c.args:
              if arg.name.len > 0 and arg.name != vi.tagName:
                for vf in vi.fields:
                  if vf.fieldName == arg.name:
                    if activeVariant notin vf.branchValues:
                      raise newException(ValueError,
                        "error: field '" & arg.name & "' is not accessible for variant '" &
                        activeVariant & "' (belongs to: " & vf.branchValues.join(", ") & ")")
        g.emit("(" & name & "){")
        for i, arg in c.args:
          if i > 0: g.emit(", ")
          if arg.name.len > 0:
            g.emit("." & arg.name & " = ")
          elif i < fields.len:
            g.emit("." & fields[i].name & " = ")
          g.genExpr(arg.value)
        g.emit("}"); return
    g.genExpr(c.fn); g.emit("(")
    for i, arg in c.args:
      if i > 0: g.emit(", ")
      g.genExpr(arg.value)
    g.emit(")")
  elif e of FieldAccessExpr:
    let f = FieldAccessExpr(e)
    if f.expr of IdentExpr:
      let name = IdentExpr(f.expr).name
      # Module access: calc.double → utils_calc_double
      if name in g.importedModules:
        if name in g.modulePublicNames:
          if f.field notin g.modulePublicNames[name]:
            raise newException(ValueError,
              "error: '" & f.field & "' is not public in module '" & name & "'")
        let prefix = g.nameAliases.getOrDefault("__mod_" & name, name)
        g.emit(prefix & "_" & f.field); return
      if name in g.enumNames:
        g.emit(name & "_" & f.field); return
      # Check variant field access
      let varType = g.varCType(name)
      if varType.len > 0 and varType in g.variantInfo:
        let vi = g.variantInfo[varType]
        for vf in vi.fields:
          if vf.fieldName == f.field:
            # This is a variant field — check if we're in a matching case branch
            if name in g.activeCaseBranch:
              let allowed = g.activeCaseBranch[name]
              var ok = false
              for v in vf.branchValues:
                if v in allowed: ok = true
              if not ok:
                raise newException(ValueError,
                  "error: field '" & f.field & "' is not accessible here (requires variant: " &
                  vf.branchValues.join(", ") & ")")
            else:
              raise newException(ValueError,
                "error: field '" & f.field & "' is a variant field — access only inside 'case " &
                name & "." & vi.tagName & ":'")
    g.genExpr(f.expr); g.emit("."); g.emit(f.field)
  elif e of IndexExpr:
    let idx = IndexExpr(e)
    g.genExpr(idx.expr); g.emit("["); g.genExpr(idx.index); g.emit("]")
  elif e of MacroCallExpr:
    let mc = MacroCallExpr(e)
    if mc.name == "echo":
      g.genEcho(mc.args)
    else:
      g.emit("/* macro *" & mc.name & " not yet implemented */")
  elif e of DollarExpr:
    g.genEchoArg(e)  # reuse echo arg logic
  elif e of QuestionExpr:
    g.genExpr(QuestionExpr(e).expr)
  elif e of TupleLitExpr:
    g.emit("(")
    for i, el in TupleLitExpr(e).elems:
      if i > 0: g.emit(", ")
      g.genExpr(el.value)
    g.emit(")")
  elif e of ArrayLitExpr or e of SeqLitExpr:
    let elems = if e of ArrayLitExpr: ArrayLitExpr(e).elems
                else: SeqLitExpr(e).elems
    g.emit("{")
    for i, el in elems:
      if i > 0: g.emit(", ")
      g.genExpr(el)
    g.emit("}")
  else:
    g.emit("/* expr not implemented */")

# ── Statement codegen ──

proc genStmt*(g: var CodeGen, s: Stmt)

proc genStmt*(g: var CodeGen, s: Stmt) =
  if s of DeclStmt:
    let d = DeclStmt(s)
    let ctype = if d.value != nil: g.inferCType(d.value) else: "int64_t"
    g.varTypes[d.name] = ctype
    g.emitIndent()
    case d.modifier
    of declDefault, declConst:
      g.emit("const " & ctype & " " & d.name & " = ")
    of declMut:
      g.emit(ctype & " " & d.name & " = ")
    if d.value != nil: g.genExpr(d.value)
    else: g.emit("0")
    g.emit(";\n")

  elif s of DoElseStmt:
    let d = DoElseStmt(s)
    let ctype = g.inferCType(d.value)
    g.varTypes[d.name] = ctype
    g.emitIndent(); g.emit(ctype & " " & d.name & " = ")
    g.genExpr(d.value); g.emit(";\n")
    # Check if result type has _Ok kind (error-returning function)
    g.emitIndent()
    if ctype.endsWith("_Result"):
      g.emit("if (" & d.name & ".kind != " & ctype & "_Ok) {\n")
    else:
      g.emit("if (!" & d.name & ") {\n")
    g.indent += 1
    for st in d.elseBody: g.genStmt(st)
    g.indent -= 1
    g.emitLine("}")

  elif s of AssignStmt:
    let a = AssignStmt(s)
    g.emitIndent(); g.genExpr(a.target); g.emit(" = "); g.genExpr(a.value); g.emit(";\n")

  elif s of ResultAssignStmt:
    g.emitIndent()
    if g.inResultFunc:
      g.emit("__result.value = ")
    else:
      g.emit("__result = ")
    g.genExpr(ResultAssignStmt(s).value); g.emit(";\n")

  elif s of FnDeclStmt:
    let f = FnDeclStmt(s)
    let hasReturn = f.returnType != nil
    let hasErrors = f.errorTypes.len > 0

    if hasErrors and hasReturn:
      let valType = g.typeToCStr(f.returnType)
      let resultName = f.name & "_Result"
      # Emit result struct if not yet emitted
      if resultName notin g.okTypes:
        g.okTypes.add(resultName)
        g.emit("typedef enum { " & resultName & "_Ok")
        for et in f.errorTypes:
          g.emit(", " & resultName & "_" & g.typeToCStr(et))
        g.emit(" } " & resultName & "_Kind;\n")
        g.emit("typedef struct {\n")
        g.indent += 1
        g.emitLine(resultName & "_Kind kind;")
        g.emitLine("union {")
        g.indent += 1
        g.emitLine(valType & " value;")
        for et in f.errorTypes:
          let etype = g.typeToCStr(et)
          g.emitLine(etype & " " & etype & "_err;")
        g.indent -= 1
        g.emitLine("};")
        g.indent -= 1
        g.emit("} " & resultName & ";\n")
      # Function returns Result struct
      g.emit(resultName & " " & f.name & "(" & g.formatParams(f.params) & ") {\n")
      g.indent += 1
      g.emitLine(resultName & " __result;")
      g.emitLine("__result.kind = " & resultName & "_Ok;")
      g.inResultFunc = true
      g.currentResultName = resultName
      for st in f.body: g.genStmt(st)
      g.inResultFunc = false
      g.emitLine("return __result;")
      g.indent -= 1
      g.emit("}\n")
    else:
      let ret = if hasReturn: g.typeToCStr(f.returnType) else: "void"
      g.emit(ret & " " & f.name & "(" & g.formatParams(f.params) & ") {\n")
      g.indent += 1
      if hasReturn: g.emitLine(ret & " __result;")
      for st in f.body: g.genStmt(st)
      if hasReturn: g.emitLine("return __result;")
      g.indent -= 1
      g.emit("}\n")

  elif s of IfStmt:
    let ifs = IfStmt(s)
    for i, b in ifs.branches:
      g.emitIndent()
      g.emit(if i == 0: "if (" else: "else if (")
      g.genExpr(b.cond); g.emit(") {\n")
      g.indent += 1
      for st in b.body: g.genStmt(st)
      g.indent -= 1
      g.emitIndent(); g.emit("} ")
    if ifs.elseBranch.len > 0:
      g.emit("else {\n")
      g.indent += 1
      for st in ifs.elseBranch: g.genStmt(st)
      g.indent -= 1
      g.emitIndent(); g.emit("}")
    g.emit("\n")

  elif s of WhileStmt:
    let w = WhileStmt(s)
    if w.label.len > 0: g.emitLine(w.label & "_start:")
    g.emitIndent(); g.emit("while ("); g.genExpr(w.condition); g.emit(") {\n")
    g.indent += 1
    for st in w.body: g.genStmt(st)
    g.indent -= 1
    g.emitLine("}")
    if w.label.len > 0: g.emitLine(w.label & "_end: ;")

  elif s of ForStmt:
    let f = ForStmt(s)
    if f.label.len > 0: g.emitLine(f.label & "_start:")
    if f.iter of RangeExpr:
      let r = RangeExpr(f.iter)
      g.emitIndent(); g.emit("for (int64_t " & f.varName & " = ")
      g.genExpr(r.start)
      g.emit("; " & f.varName & (if r.inclusive: " <= " else: " < "))
      g.genExpr(r.finish)
      g.emit("; " & f.varName & "++) {\n")
    else:
      g.emitIndent(); g.emit("/* for " & f.varName & " in <collection> */ {\n")
    g.indent += 1
    for st in f.body: g.genStmt(st)
    g.indent -= 1
    g.emitLine("}")
    if f.label.len > 0: g.emitLine(f.label & "_end: ;")

  elif s of BreakStmt:
    let b = BreakStmt(s)
    if b.label.len > 0: g.emitLine("goto " & b.label & "_end;")
    else: g.emitLine("break;")

  elif s of ContinueStmt:
    let c = ContinueStmt(s)
    if c.label.len > 0: g.emitLine("goto " & c.label & "_start;")
    else: g.emitLine("continue;")

  elif s of ReturnStmt:
    g.emitLine("return __result;")

  elif s of ExprStmt:
    g.emitIndent(); g.genExpr(ExprStmt(s).expr); g.emit(";\n")

  elif s of ObjectDeclStmt:
    let o = ObjectDeclStmt(s)
    var allFields: seq[tuple[name, ctype: string]]
    if o.parent.len > 0 and o.parent in g.typeFields:
      allFields = g.typeFields[o.parent]
    g.emit("typedef struct {\n")
    g.indent += 1
    # Parent fields
    for f in allFields: g.emitLine(f.ctype & " " & f.name & ";")
    # Own fields
    for f in o.fields:
      let ct = g.typeToCStr(f.typeAnn)
      g.emitLine(ct & " " & f.name & ";")
      allFields.add((f.name, ct))
    # Object variant (tagged union)
    if o.variant.tagName.len > 0:
      g.emitLine(o.variant.tagType & " " & o.variant.tagName & ";")
      allFields.add((o.variant.tagName, o.variant.tagType))
      g.emitLine("union {")
      g.indent += 1
      for b in o.variant.branches:
        if b.fields.len == 1:
          # Single field — flat in union
          let f = b.fields[0]
          let ct = g.typeToCStr(f.typeAnn)
          g.emitLine(ct & " " & f.name & ";")
          allFields.add((f.name, ct))
        elif b.fields.len > 1:
          # Multiple fields — anonymous struct in union
          g.emitLine("struct {")
          g.indent += 1
          for f in b.fields:
            let ct = g.typeToCStr(f.typeAnn)
            g.emitLine(ct & " " & f.name & ";")
            allFields.add((f.name, ct))
          g.indent -= 1
          g.emitLine("};")
      g.indent -= 1
      g.emitLine("};")  # anonymous union
    g.indent -= 1
    g.emit("} " & o.name & ";\n")
    g.typeFields[o.name] = allFields
    # Store variant info for compile-time checks
    if o.variant.tagName.len > 0:
      var vi = VariantInfo(tagName: o.variant.tagName, tagType: o.variant.tagType)
      for b in o.variant.branches:
        for f in b.fields:
          vi.fields.add(VariantFieldInfo(fieldName: f.name, branchValues: b.values))
      g.variantInfo[o.name] = vi

  elif s of EnumDeclStmt:
    let en = EnumDeclStmt(s)
    g.enumNames.add(en.name)
    # Simple enum — no data variants (tagged unions are via object variants)
    g.emit("typedef enum {\n")
    g.indent += 1
    for i, v in en.variants:
      g.emitIndent(); g.emit(en.name & "_" & v.name)
      if v.valueKind == evInt: g.emit(" = " & $v.intVal)
      if i < en.variants.len - 1: g.emit(",")
      g.emit("\n")
    g.indent -= 1
    g.emit("} " & en.name & ";\n")

    # toString for string-valued enums
    let hasStrings = en.variants.anyIt(it.valueKind == evString)
    if hasStrings:
      g.emit("const char* " & en.name & "_to_string(" & en.name & " v) {\n")
      g.indent += 1; g.emitLine("switch (v) {"); g.indent += 1
      for v in en.variants:
        let display = if v.valueKind == evString: v.strVal else: v.name
        g.emitLine("case " & en.name & "_" & v.name & ": return \"" & display & "\";")
      g.emitLine("default: return \"unknown\";")
      g.indent -= 1; g.emitLine("}"); g.indent -= 1
      g.emit("}\n")

  elif s of TupleDeclStmt:
    let t = TupleDeclStmt(s)
    var allFields: seq[tuple[name, ctype: string]]
    g.emit("typedef struct {\n")
    g.indent += 1
    for f in t.fields:
      let ct = g.typeToCStr(f.typeAnn)
      g.emitLine(ct & " " & f.name & ";")
      allFields.add((f.name, ct))
    g.indent -= 1
    g.emit("} " & t.name & ";\n")
    g.typeFields[t.name] = allFields

  elif s of CaseStmt:
    let cs = CaseStmt(s)
    # Infer type context for case expression
    var enumType = ""
    var variantVar = ""
    var resultType = ""  # non-empty if case on a Result type
    if cs.expr of IdentExpr:
      let ct = g.varCType(IdentExpr(cs.expr).name)
      if ct in g.enumNames: enumType = ct
      elif ct.endsWith("_Result"): resultType = ct
    elif cs.expr of FieldAccessExpr:
      let fa = FieldAccessExpr(cs.expr)
      if fa.expr of IdentExpr:
        let objName = IdentExpr(fa.expr).name
        let objType = g.varCType(objName)
        if objType.len > 0 and objType in g.variantInfo:
          let vi = g.variantInfo[objType]
          if fa.field == vi.tagName:
            variantVar = objName
            enumType = vi.tagType
    g.emitIndent()
    if resultType.len > 0:
      g.emit("switch ("); g.genExpr(cs.expr); g.emit(".kind) {\n")
    else:
      g.emit("switch ("); g.genExpr(cs.expr); g.emit(") {\n")
    g.indent += 1
    for b in cs.branches:
      case b.pattern.kind
      of patVariant:
        if resultType.len > 0:
          # of DivError: → case resultType_DivError:
          g.emitLine("case " & resultType & "_" & b.pattern.name & ":")
        elif enumType.len > 0:
          g.emitLine("case " & enumType & "_" & b.pattern.name & ":")
        else:
          g.emitLine("case " & b.pattern.name & ":")
      of patOk:
        if resultType.len > 0:
          g.emitLine("case " & resultType & "_Ok:")
        else:
          g.emitLine("/* of Ok — no result context */")
      of patError:
        g.emitLine("/* of Error — not yet implemented */")
      of patSome:
        g.emitLine("/* of some — not yet implemented */")
      of patNone:
        g.emitLine("/* of none — not yet implemented */")
      g.indent += 1
      # Set active variant for field access checks inside this branch
      if variantVar.len > 0 and b.pattern.kind == patVariant:
        g.activeCaseBranch[variantVar] = @[b.pattern.name]
      for st in b.body: g.genStmt(st)
      # Clear active variant after branch
      if variantVar.len > 0:
        g.activeCaseBranch.del(variantVar)
      g.emitLine("break;")
      g.indent -= 1
    if cs.elseBranch.len > 0:
      g.emitLine("default:")
      g.indent += 1
      for st in cs.elseBranch: g.genStmt(st)
      g.emitLine("break;")
      g.indent -= 1
    else:
      # Exhaustive — hint to C compiler that all cases are covered
      g.emitLine("default: __builtin_unreachable();")
    g.indent -= 1
    g.emitLine("}")

  elif s of QuitStmt:
    let q = QuitStmt(s)
    g.emitIndent()
    if q.expr != nil:
      g.emit("exit("); g.genExpr(q.expr); g.emit(");\n")
    else:
      g.emit("exit(0);\n")

  elif s of RaiseStmt:
    let r = RaiseStmt(s)
    if g.inResultFunc:
      # raise DivError(...) → set kind and return
      if r.expr of CallExpr and CallExpr(r.expr).fn of IdentExpr:
        let errType = IdentExpr(CallExpr(r.expr).fn).name
        g.emitIndent()
        g.emit("__result.kind = " & g.currentResultName & "_" & errType & ";\n")
        g.emitIndent()
        g.emit("__result." & errType & "_err = ")
        g.genExpr(r.expr)
        g.emit(";\n")
        g.emitLine("return __result;")
      else:
        g.emitLine("/* raise: unknown error expression */")
    else:
      g.emitLine("/* raise outside error function */")

  elif s of DiscardStmt:
    g.emitLine("(void)0;")

  else:
    g.emitLine("/* not yet implemented */")

# ── Helpers ──

proc emitPreamble*(g: var CodeGen) =
  g.emit("#include <stdio.h>\n")
  g.emit("#include <stdint.h>\n")
  g.emit("#include <stdbool.h>\n")
  g.emit("#include <string.h>\n")
  g.emit("#include <stdlib.h>\n\n")
  g.emit("// iris str — stack-allocated, immutable, max 256 bytes\n")
  g.emit("typedef struct { uint8_t len; char data[255]; } iris_str;\n")
  g.emit("static inline iris_str iris_str_from(const char* s) {\n")
  g.emit("  iris_str r = {0};\n")
  g.emit("  r.len = (uint8_t)strlen(s);\n")
  g.emit("  if (r.len > 254) r.len = 254;\n")
  g.emit("  memcpy(r.data, s, r.len);\n")
  g.emit("  r.data[r.len] = '\\0';\n")
  g.emit("  return r;\n")
  g.emit("}\n\n")
  g.emit("typedef struct { char* data; uint32_t len; uint32_t cap; } iris_String;\n\n")

proc sanitizeModName*(name: string): string =
  ## Convert module path to valid C identifier: utils/calc → utils_calc
  result = name.replace("/", "_").replace("\\", "_")

proc cName(g: CodeGen, name: string, public: bool): string =
  ## Prefix name with module name for public symbols
  if g.moduleName.len > 0:
    sanitizeModName(g.moduleName) & "_" & name
  else:
    name

# ── Main entry ──

proc generate*(g: var CodeGen, stmts: seq[Stmt]): string =
  g.emitPreamble()

  # Types first
  for s in stmts:
    if s of ObjectDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt:
      g.genStmt(s); g.emit("\n")

  # Result structs + forward declarations
  for s in stmts:
    if s of FnDeclStmt:
      let f = FnDeclStmt(s)
      if f.errorTypes.len > 0 and f.returnType != nil:
        # Pre-emit result struct so forward decl can use it
        let valType = g.typeToCStr(f.returnType)
        let resultName = f.name & "_Result"
        if resultName notin g.okTypes:
          g.okTypes.add(resultName)
          g.emit("typedef enum { " & resultName & "_Ok")
          for et in f.errorTypes:
            g.emit(", " & resultName & "_" & g.typeToCStr(et))
          g.emit(" } " & resultName & "_Kind;\n")
          g.emit("typedef struct { " & resultName & "_Kind kind; union { " & valType & " value; ")
          for et in f.errorTypes:
            let etype = g.typeToCStr(et)
            g.emit(etype & " " & etype & "_err; ")
          g.emit("}; } " & resultName & ";\n")
        g.emit(resultName & " " & f.name & "(" & g.formatParams(f.params) & ");\n")
        g.fnReturnTypes[f.name] = resultName
      else:
        let ret = if f.returnType != nil: g.typeToCStr(f.returnType) else: "void"
        g.emit(ret & " " & f.name & "(" & g.formatParams(f.params) & ");\n")
        g.fnReturnTypes[f.name] = ret
  g.emit("\n")

  # Functions
  var topLevel: seq[Stmt]
  for s in stmts:
    if s of FnDeclStmt:
      g.genStmt(s); g.emit("\n")
    elif not (s of ObjectDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt):
      topLevel.add(s)

  # Top-level code → main
  if topLevel.len > 0:
    g.emit("int main(void) {\n")
    g.indent += 1
    for s in topLevel: g.genStmt(s)
    g.emitLine("return 0;")
    g.indent -= 1
    g.emit("}\n")

  result = g.output

proc generateModule*(g: var CodeGen, stmts: seq[Stmt], modName: string): string =
  ## Generate C file for a module (no main, prefix public names)
  g.moduleName = modName
  let prefix = sanitizeModName(modName)
  g.emitPreamble()

  # Types
  for s in stmts:
    if s of ObjectDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt:
      g.genStmt(s); g.emit("\n")

  # Forward declarations + result structs
  for s in stmts:
    if s of FnDeclStmt:
      let f = FnDeclStmt(s)
      if not f.public: continue
      let cname = prefix & "_" & f.name
      let ret = if f.returnType != nil: g.typeToCStr(f.returnType) else: "void"
      g.emit(ret & " " & cname & "(" & g.formatParams(f.params) & ");\n")
      g.fnReturnTypes[cname] = ret
  g.emit("\n")

  # Functions — public get prefixed, private get static
  for s in stmts:
    if s of FnDeclStmt:
      let f = FnDeclStmt(s)
      let hasReturn = f.returnType != nil
      let ret = if hasReturn: g.typeToCStr(f.returnType) else: "void"
      let cname = if f.public: prefix & "_" & f.name else: f.name
      if not f.public: g.emit("static ")
      g.emit(ret & " " & cname & "(" & g.formatParams(f.params) & ") {\n")
      g.indent += 1
      if hasReturn: g.emitLine(ret & " __result;")
      for st in f.body: g.genStmt(st)
      if hasReturn: g.emitLine("return __result;")
      g.indent -= 1
      g.emit("}\n\n")

  g.moduleName = ""
  result = g.output

proc generateHeader*(g: var CodeGen, stmts: seq[Stmt], modName: string): string =
  ## Generate extern declarations for importing module
  for s in stmts:
    if s of FnDeclStmt:
      let f = FnDeclStmt(s)
      if not f.public: continue
      let cname = modName & "_" & f.name
      let ret = if f.returnType != nil: g.typeToCStr(f.returnType) else: "void"
      g.emit("extern " & ret & " " & cname & "(" & g.formatParams(f.params) & ");\n")
      g.fnReturnTypes[modName & "." & f.name] = ret
  for s in stmts:
    if s of ObjectDeclStmt:
      let o = ObjectDeclStmt(s)
      if o.public: g.emit("/* type " & o.name & " from " & modName & " */\n")
    if s of EnumDeclStmt:
      let e = EnumDeclStmt(s)
      if e.public: g.emit("/* enum " & e.name & " from " & modName & " */\n")
  result = g.output
