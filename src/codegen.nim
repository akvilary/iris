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
    errorNames: seq[string]
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
    genericFuncs*: Table[string, FnDeclStmt]  # generic func name -> AST
    emittedSpecializations*: seq[string]  # already emitted specializations
    pendingSpecializations*: string  # code to emit before main

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
    of "Str": "iris_Str"
    of "natural": "uint64_t"
    of "rune": "int32_t"
    else: n
  elif t of GenericType:
    let gt = GenericType(t)
    if gt.name == "view" and gt.args.len == 1 and gt.args[0] of NamedType:
      "iris_view_" & NamedType(gt.args[0]).name
    else:
      gt.name & "_" & gt.args.mapIt(g.typeToCStr(it)).join("_")
  elif t of TupleType:
    "/* tuple type */"
  else:
    "void"

proc varCType(g: CodeGen, name: string): string =
  g.varTypes.getOrDefault(name, "")

proc substituteType(t: TypeExpr, subs: Table[string, string]): TypeExpr =
  ## Replace generic type params with concrete types
  if t == nil: return nil
  if t of NamedType:
    let n = NamedType(t).name
    if n in subs: return NamedType(name: subs[n])
    return t
  if t of GenericType:
    let gt = GenericType(t)
    var newArgs: seq[TypeExpr]
    for a in gt.args:
      newArgs.add(substituteType(a, subs))
    return GenericType(name: gt.name, args: newArgs)
  return t

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
    of "const char*": return ("%s", false)
    of "iris_view_Str", "iris_Str": return ("%.*s", false)
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
            of "const char*": return ("%s", false)
            of "iris_view_Str", "iris_Str": return ("%.*s", false)
            of "bool": return ("%s", false)
            else: return ("%lld", true)
  return ("%lld", true)

proc inferCType(g: CodeGen, e: Expr): string =
  if e of IntLitExpr: return "int64_t"
  if e of FloatLitExpr: return "double"
  if e of StringLitExpr or e of StringInterpExpr: return "iris_view_Str"
  if e of StrLitExpr or e of StrInterpExpr: return "iris_Str"
  if e of HashTableLitExpr: return "iris_HashTable"
  if e of HashSetLitExpr: return "iris_HashSet"
  if e of HeapAllocExpr:
    let inner = HeapAllocExpr(e).inner
    if inner.fn of IdentExpr:
      return "iris_Heap_" & IdentExpr(inner.fn).name
  if e of BoolLitExpr: return "bool"
  if e of RuneLitExpr: return "int32_t"
  if e of BinaryExpr:
    let b = BinaryExpr(e)
    if b.op in {opEq, opNotEq, opLess, opLessEq, opGreater, opGreaterEq, opAnd, opOr}:
      return "bool"
    return g.inferCType(b.left)
  if e of CallExpr:
    let c = CallExpr(e)
    if c.fn of FieldAccessExpr:
      let fa = FieldAccessExpr(c.fn)
      if fa.field == "get":
        return "int64_t"  # simplified
    if c.fn of IdentExpr:
      let name = IdentExpr(c.fn).name
      if name == "Str": return "iris_Str"
      if name == "some" and c.args.len == 1:
        return "iris_Option_" & g.inferCType(c.args[0].value)
      if name == "none":
        return "iris_Option_int64_t"  # default, needs type param
      if name in g.typeFields: return name
      if name in g.fnReturnTypes: return g.fnReturnTypes[name]
      # Generic function call — infer return type from specialization
      if name in g.genericFuncs:
        let gf = g.genericFuncs[name]
        var subs = initTable[string, string]()
        for i, param in gf.params:
          if i < c.args.len:
            let ct = g.inferCType(c.args[i].value)
            if param.typeAnn of NamedType:
              let tn = NamedType(param.typeAnn).name
              if tn in gf.genericParams:
                subs[tn] = ct
        if gf.returnType != nil:
          let specRet = substituteType(gf.returnType, subs)
          return g.typeToCStr(specRet)
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

proc ensureOptionType(g: var CodeGen, valType, optType: string)

# ── Expression codegen ──

proc genExpr(g: var CodeGen, e: Expr)
proc genStmt*(g: var CodeGen, s: Stmt)

proc genEchoArg(g: var CodeGen, e: Expr) =
  if e of BoolLitExpr:
    g.emit(if BoolLitExpr(e).val: "\"true\"" else: "\"false\"")
  elif e of IdentExpr:
    let name = IdentExpr(e).name
    let ct = g.varCType(name)
    if ct == "bool": g.emit("(" & name & " ? \"true\" : \"false\")")
    elif ct in ["iris_view_Str", "iris_Str"]: g.emit("(int)" & name & ".len, " & name & ".data")
    else: g.genExpr(e)
  elif e of DollarExpr:
    let inner = DollarExpr(e).expr
    if inner of IdentExpr:
      let name = IdentExpr(inner).name
      let ct = g.varCType(name)
      if ct == "bool": g.emit("(" & name & " ? \"true\" : \"false\")")
      elif ct in ["iris_view_Str", "iris_Str"]: g.emit("(int)" & name & ".len, " & name & ".data")
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
  if e of StringLitExpr or e of StrLitExpr:
    let val = if e of StringLitExpr: StringLitExpr(e).val else: StrLitExpr(e).val
    g.emit("printf(\"%s\\n\", \"" & escapeC(val) & "\")")
  elif e of StringInterpExpr or e of StrInterpExpr:
    let parts = if e of StringInterpExpr: StringInterpExpr(e).parts
                else: StrInterpExpr(e).parts
    var fmt = ""
    var exprs: seq[Expr]
    for p in parts:
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
    g.emit("iris_view_Str_from(\"" & escapeC(StringLitExpr(e).val) & "\")")
  elif e of StrLitExpr:
    g.emit("iris_Str_from(\"" & escapeC(StrLitExpr(e).val) & "\")")
  elif e of StrInterpExpr:
    var fmt = ""
    var exprs: seq[Expr]
    for p in StrInterpExpr(e).parts:
      if not p.isExpr:
        fmt.add(escapeC(p.lit))
      else:
        let (f, _) = g.printfFormat(p.expr)
        fmt.add(f)
        exprs.add(p.expr)
    g.emit("iris_Str_fmt(\"" & fmt & "\"")
    for ex in exprs:
      let (_, needsCast) = g.printfFormat(ex)
      g.emit(", ")
      if needsCast: g.emit("(long long)")
      g.genEchoArg(ex)
    g.emit(")")
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
      # Str("literal") or Str(view) → owned string
      if name == "Str" and c.args.len == 1:
        if c.args[0].value of StringLitExpr:
          g.emit("iris_Str_from(\"" & escapeC(StringLitExpr(c.args[0].value).val) & "\")")
        else:
          g.emit("iris_Str_from_view(")
          g.genExpr(c.args[0].value)
          g.emit(")")
        return
      # some(value) → Option struct with has=true
      if name == "some" and c.args.len == 1:
        let valType = g.inferCType(c.args[0].value)
        let optType = "iris_Option_" & valType
        g.ensureOptionType(valType, optType)
        g.emit("(" & optType & "){.has = true, .value = ")
        g.genExpr(c.args[0].value)
        g.emit("}")
        return
      # none(Type) → Option struct with has=false
      if name == "none" and c.args.len == 1:
        # none(int) — arg is parsed as ident "int", treat as type name
        if c.args[0].value of IdentExpr:
          let typeName = IdentExpr(c.args[0].value).name
          let valType = g.typeToCStr(NamedType(name: typeName))
          let optType = "iris_Option_" & valType
          g.ensureOptionType(valType, optType)
          g.emit("(" & optType & "){.has = false}")
          return
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
      # Generic function call — monomorphize
      if name in g.genericFuncs:
        let gf = g.genericFuncs[name]
        # Infer concrete types from arguments
        var subs = initTable[string, string]()
        for i, param in gf.params:
          if i < c.args.len:
            let concreteType = g.inferCType(c.args[i].value)
            # Match param type against generic params
            if param.typeAnn of NamedType:
              let tn = NamedType(param.typeAnn).name
              if tn in gf.genericParams:
                subs[tn] = concreteType
            elif param.typeAnn of GenericType:
              let gt = GenericType(param.typeAnn)
              # view[T] → extract inner type
              if gt.name == "view" and gt.args.len == 1 and gt.args[0] of NamedType:
                let inner = NamedType(gt.args[0]).name
                if inner in gf.genericParams:
                  # concreteType is iris_view_X → extract X
                  if concreteType.startsWith("iris_view_"):
                    subs[inner] = concreteType[10..^1]
                  else:
                    subs[inner] = concreteType
        # Build specialized name
        let specName = name & "_" & gf.genericParams.mapIt(subs.getOrDefault(it, "unknown")).join("_")
        # Emit specialization if not yet emitted
        if specName notin g.emittedSpecializations:
          g.emittedSpecializations.add(specName)
          # Generate specialized function into pending buffer
          let origOutput = g.output
          let origIndent = g.indent
          g.output = ""
          g.indent = 0
          var specParams: seq[Param]
          for p in gf.params:
            specParams.add(Param(name: p.name, modifier: p.modifier,
                                 typeAnn: substituteType(p.typeAnn, subs)))
          let specReturn = substituteType(gf.returnType, subs)
          let ret = if specReturn != nil: g.typeToCStr(specReturn) else: "void"
          g.emit(ret & " " & specName & "(" & g.formatParams(specParams) & ") {\n")
          g.indent = 1
          if specReturn != nil: g.emitLine(ret & " __result;")
          for st in gf.body: g.genStmt(st)
          if specReturn != nil: g.emitLine("return __result;")
          g.indent = 0
          g.emit("}\n\n")
          g.pendingSpecializations.add(g.output)
          g.output = origOutput
          g.indent = origIndent
          g.fnReturnTypes[specName] = ret
        g.emit(specName & "(")
        for i, arg in c.args:
          if i > 0: g.emit(", ")
          g.genExpr(arg.value)
        g.emit(")")
        return
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
  elif e of ArrayLitExpr:
    let a = ArrayLitExpr(e)
    if a.fillValue != nil:
      # [value: count] → iris_array_fill(value, count)
      g.emit("iris_array_fill(")
      g.genExpr(a.fillValue)
      g.emit(", ")
      g.genExpr(a.fillCount)
      g.emit(")")
    else:
      g.emit("{")
      for i, el in a.elems:
        if i > 0: g.emit(", ")
        g.genExpr(el)
      g.emit("}")
  elif e of SeqLitExpr:
    let s = SeqLitExpr(e)
    if s.capacityOnly:
      # ~[:count] → iris_Seq_with_capacity(count)
      g.emit("iris_Seq_with_capacity(")
      g.genExpr(s.fillCount)
      g.emit(")")
    elif s.fillValue != nil:
      # ~[value: count] → iris_Seq_fill(value, count)
      g.emit("iris_Seq_fill(")
      g.genExpr(s.fillValue)
      g.emit(", ")
      g.genExpr(s.fillCount)
      g.emit(")")
    else:
      g.emit("{")
      for i, el in s.elems:
        if i > 0: g.emit(", ")
        g.genExpr(el)
      g.emit("}")
  elif e of HashTableLitExpr:
    let ht = HashTableLitExpr(e)
    g.emit("iris_HashTable_from(" & $ht.entries.len)
    for entry in ht.entries:
      g.emit(", ")
      g.genExpr(entry.key)
      g.emit(", ")
      g.genExpr(entry.value)
    g.emit(")")
  elif e of HashSetLitExpr:
    let hs = HashSetLitExpr(e)
    g.emit("iris_HashSet_from(" & $hs.elems.len)
    for el in hs.elems:
      g.emit(", ")
      g.genExpr(el)
    g.emit(")")
  elif e of HeapAllocExpr:
    let ha = HeapAllocExpr(e)
    let typeName = if ha.inner.fn of IdentExpr: IdentExpr(ha.inner.fn).name
                   else: "Unknown"
    g.emit("iris_Heap_" & typeName & "_alloc((" & typeName & "){")
    let fields = g.typeFields.getOrDefault(typeName, @[])
    for i, arg in ha.inner.args:
      if i > 0: g.emit(", ")
      if arg.name.len > 0:
        g.emit("." & arg.name & " = ")
      elif i < fields.len:
        g.emit("." & fields[i].name & " = ")
      g.genExpr(arg.value)
    g.emit("})")
  else:
    g.emit("/* expr not implemented */")

# ── Condition helper ──

proc genCondExpr(g: var CodeGen, e: Expr) =
  ## Generate condition expression — Option/Result types need special handling
  if e of IdentExpr:
    let ct = g.varCType(IdentExpr(e).name)
    if ct.startsWith("iris_Option_"):
      g.genExpr(e); g.emit(".has"); return
    if ct.endsWith("_Result"):
      g.emit("("); g.genExpr(e); g.emit(".kind == "); g.emit(ct & "_Ok)"); return
  # not expr — check inner for Option/Result
  if e of UnaryExpr and UnaryExpr(e).op == opNot:
    let inner = UnaryExpr(e).expr
    if inner of IdentExpr:
      let ct = g.varCType(IdentExpr(inner).name)
      if ct.startsWith("iris_Option_"):
        g.emit("!"); g.genExpr(inner); g.emit(".has"); return
      if ct.endsWith("_Result"):
        g.emit("("); g.genExpr(inner); g.emit(".kind != "); g.emit(ct & "_Ok)"); return
  g.genExpr(e)

# ── Statement codegen ──

proc genStmt*(g: var CodeGen, s: Stmt) =
  if s of DeclStmt:
    let d = DeclStmt(s)
    # Validate array fill size matches type annotation
    if d.typeAnn != nil and d.typeAnn of GenericType:
      let gt = GenericType(d.typeAnn)
      if gt.name == "array" and gt.args.len == 2 and d.value != nil and d.value of ArrayLitExpr:
        let arr = ArrayLitExpr(d.value)
        if arr.fillCount != nil and arr.fillCount of IntLitExpr and gt.args[1] of NamedType:
          let fillN = IntLitExpr(arr.fillCount).val
          let sizeStr = NamedType(gt.args[1]).name
          var typeN: int64 = -1
          try: typeN = parseInt(sizeStr)
          except: discard
          if typeN >= 0 and fillN != typeN:
            raise newException(ValueError,
              "error: array size mismatch — type says " & $typeN &
              " but fill has " & $fillN & " elements")
    let ctype = if d.typeAnn != nil: g.typeToCStr(d.typeAnn)
                elif d.value != nil: g.inferCType(d.value)
                else: "int64_t"
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

  elif s of CompoundAssignStmt:
    let ca = CompoundAssignStmt(s)
    g.emitIndent(); g.genExpr(ca.target)
    g.emit(case ca.op
      of opAdd: " += "
      of opSub: " -= "
      of opMul: " *= "
      of opDiv: " /= "
      else: " ?= ")
    g.genExpr(ca.value); g.emit(";\n")

  elif s of AssignStmt:
    let a = AssignStmt(s)
    g.emitIndent(); g.genExpr(a.target); g.emit(" = "); g.genExpr(a.value); g.emit(";\n")

  elif s of ResultAssignStmt:
    let val = ResultAssignStmt(s).value
    # Check if assigning an error type (result = Error(...))
    if g.inResultFunc and val of CallExpr and CallExpr(val).fn of IdentExpr:
      let name = IdentExpr(CallExpr(val).fn).name
      if name in g.errorNames:
        g.emitIndent()
        g.emit("__result.kind = " & g.currentResultName & "_" & name & ";\n")
        g.emitIndent()
        g.emit("__result." & name & "_err = ")
        g.genExpr(val)
        g.emit(";\n")
        return
    g.emitIndent()
    if g.inResultFunc:
      g.emit("__result.value = ")
    else:
      g.emit("__result = ")
    g.genExpr(val); g.emit(";\n")

  elif s of FnDeclStmt:
    let f = FnDeclStmt(s)
    # Generic functions — store for monomorphization, don't emit
    if f.genericParams.len > 0:
      g.genericFuncs[f.name] = f
      return
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
      g.genCondExpr(b.cond); g.emit(") {\n")
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
    g.emitIndent(); g.emit("while ("); g.genCondExpr(w.condition); g.emit(") {\n")
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

  elif s of ErrorDeclStmt:
    let e = ErrorDeclStmt(s)
    g.errorNames.add(e.name)
    var allFields: seq[tuple[name, ctype: string]]
    g.emit("typedef struct {\n")
    g.indent += 1
    for f in e.fields:
      let ct = g.typeToCStr(f.typeAnn)
      g.emitLine(ct & " " & f.name & ";")
      allFields.add((f.name, ct))
    # Error variant (tagged union) — same as object
    if e.variant.tagName.len > 0:
      g.emitLine(e.variant.tagType & " " & e.variant.tagName & ";")
      allFields.add((e.variant.tagName, e.variant.tagType))
      g.emitLine("union {")
      g.indent += 1
      for b in e.variant.branches:
        if b.fields.len == 1:
          let f = b.fields[0]
          let ct = g.typeToCStr(f.typeAnn)
          g.emitLine(ct & " " & f.name & ";")
          allFields.add((f.name, ct))
        elif b.fields.len > 1:
          g.emitLine("struct {")
          g.indent += 1
          for f in b.fields:
            let ct = g.typeToCStr(f.typeAnn)
            g.emitLine(ct & " " & f.name & ";")
            allFields.add((f.name, ct))
          g.indent -= 1
          g.emitLine("};")
      g.indent -= 1
      g.emitLine("};")
    g.indent -= 1
    g.emit("} " & e.name & ";\n")
    g.typeFields[e.name] = allFields
    if e.variant.tagName.len > 0:
      var vi = VariantInfo(tagName: e.variant.tagName, tagType: e.variant.tagType)
      for b in e.variant.branches:
        for f in b.fields:
          vi.fields.add(VariantFieldInfo(fieldName: f.name, branchValues: b.values))
      g.variantInfo[e.name] = vi

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
    var resultType = ""
    var optionType = false
    if cs.expr of IdentExpr:
      let ct = g.varCType(IdentExpr(cs.expr).name)
      if ct in g.enumNames: enumType = ct
      elif ct.endsWith("_Result"): resultType = ct
      elif ct.startsWith("iris_Option_"): optionType = true
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
    # Option type → generate if/else instead of switch
    if optionType:
      var first = true
      for b in cs.branches:
        g.emitIndent()
        if b.pattern.kind == patSome:
          g.emit((if first: "if (" else: "else if ("))
          g.genExpr(cs.expr); g.emit(".has) {\n")
        elif b.pattern.kind == patNone:
          g.emit((if first: "if (!" else: "else if (!"))
          g.genExpr(cs.expr); g.emit(".has) {\n")
        else:
          g.emit("/* unknown option pattern */ {\n")
        first = false
        g.indent += 1
        for st in b.body: g.genStmt(st)
        g.indent -= 1
        g.emitIndent(); g.emit("} ")
      if cs.elseBranch.len > 0:
        g.emit("else {\n")
        g.indent += 1
        for st in cs.elseBranch: g.genStmt(st)
        g.indent -= 1
        g.emitIndent(); g.emit("}")
      g.emit("\n")
      return  # done, skip switch logic below

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
  g.emit("#include <stdlib.h>\n")
  g.emit("#include <stdarg.h>\n\n")
  g.emit("// view[Str] — immutable view (pointer + length)\n")
  g.emit("typedef struct { const char* data; size_t len; } iris_view_Str;\n")
  g.emit("static inline iris_view_Str iris_view_Str_from(const char* s) {\n")
  g.emit("  return (iris_view_Str){s, strlen(s)};\n")
  g.emit("}\n\n")
  g.emit("// Str — owned heap buffer (pointer + length + capacity)\n")
  g.emit("typedef struct { char* data; size_t len; size_t cap; } iris_Str;\n")
  g.emit("static inline iris_Str iris_Str_from(const char* s) {\n")
  g.emit("  size_t len = strlen(s);\n")
  g.emit("  char* data = (char*)malloc(len + 1);\n")
  g.emit("  memcpy(data, s, len + 1);\n")
  g.emit("  return (iris_Str){data, len, len};\n")
  g.emit("}\n")
  g.emit("static inline iris_Str iris_Str_from_view(iris_view_Str v) {\n")
  g.emit("  char* data = (char*)malloc(v.len + 1);\n")
  g.emit("  memcpy(data, v.data, v.len);\n")
  g.emit("  data[v.len] = '\\0';\n")
  g.emit("  return (iris_Str){data, v.len, v.len};\n")
  g.emit("}\n")
  g.emit("static inline iris_Str iris_Str_fmt(const char* fmt, ...) {\n")
  g.emit("  va_list a1, a2;\n")
  g.emit("  va_start(a1, fmt); va_copy(a2, a1);\n")
  g.emit("  int len = vsnprintf(NULL, 0, fmt, a1); va_end(a1);\n")
  g.emit("  char* data = (char*)malloc(len + 1);\n")
  g.emit("  vsnprintf(data, len + 1, fmt, a2); va_end(a2);\n")
  g.emit("  return (iris_Str){data, (size_t)len, (size_t)len};\n")
  g.emit("}\n\n")

  # Common Option types
  g.emit("// Option types\n")
  for t in ["int64_t", "double", "bool", "iris_view_Str"]:
    let optName = "iris_Option_" & t
    g.emit("typedef struct { bool has; " & t & " value; } " & optName & ";\n")
    g.okTypes.add(optName)
  g.emit("\n")

proc ensureOptionType(g: var CodeGen, valType, optType: string) =
  ## Emit Option typedef if not yet emitted.
  if optType notin g.okTypes:
    g.okTypes.add(optType)
    # Emit inline — this works for types defined before first use
    g.emit("typedef struct { bool has; " & valType & " value; } " & optType & ";\n")

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
    if s of ObjectDeclStmt or s of ErrorDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt:
      g.genStmt(s); g.emit("\n")

  # Result structs + forward declarations (skip generics — monomorphized later)
  for s in stmts:
    if s of FnDeclStmt:
      let f = FnDeclStmt(s)
      if f.genericParams.len > 0:
        g.genericFuncs[f.name] = f
        continue
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

  # Functions (non-generic)
  var topLevel: seq[Stmt]
  for s in stmts:
    if s of FnDeclStmt:
      g.genStmt(s); g.emit("\n")
    elif not (s of ObjectDeclStmt or s of ErrorDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt):
      topLevel.add(s)

  # Top-level code → main
  if topLevel.len > 0:
    # First pass: generate main body to trigger specializations
    let origOutput = g.output
    g.output = ""
    g.indent = 1
    for s in topLevel: g.genStmt(s)
    g.emitLine("return 0;")
    let mainBody = g.output
    g.output = origOutput
    g.indent = 0
    # Emit collected specializations before main
    if g.pendingSpecializations.len > 0:
      g.emit(g.pendingSpecializations)
    g.emit("int main(void) {\n")
    g.emit(mainBody)
    g.emit("}\n")

  result = g.output

proc generateModule*(g: var CodeGen, stmts: seq[Stmt], modName: string): string =
  ## Generate C file for a module (no main, prefix public names)
  g.moduleName = modName
  let prefix = sanitizeModName(modName)
  g.emitPreamble()

  # Types
  for s in stmts:
    if s of ObjectDeclStmt or s of ErrorDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt:
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
    if s of ErrorDeclStmt:
      let er = ErrorDeclStmt(s)
      if er.public: g.emit("/* error " & er.name & " from " & modName & " */\n")
    if s of EnumDeclStmt:
      let e = EnumDeclStmt(s)
      if e.public: g.emit("/* enum " & e.name & " from " & modName & " */\n")
  result = g.output
