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
    fnParamTypes*: Table[string, seq[string]]  # func name -> param C types
    inResultFunc: bool    # inside a function with error types
    currentResultName: string  # e.g. "divide_Result"
    moduleName: string    # current module name (empty = main)
    importedModules*: seq[string]  # list of imported module names
    modulePublicNames*: Table[string, seq[string]]  # module -> list of public names
    nameAliases*: Table[string, string]  # local name -> C name (from imports)
    genericFuncs*: Table[string, FnDeclStmt]  # generic func name -> AST
    concepts*: Table[string, ConceptDeclStmt]  # concept name -> definition
    typeMethods*: Table[string, seq[tuple[name: string, paramTypes: seq[string], retType: string]]]
    emittedSpecializations*: seq[string]  # already emitted specializations
    emittedSeqTypes*: seq[string]  # already emitted Seq specializations
    pendingSpecializations*: string  # code to emit before main
    tmpCounter: int  # monotonic counter for unique temp names

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

proc nextTmp(g: var CodeGen): string =
  g.tmpCounter += 1
  "__destruct_" & $g.tmpCounter

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
    of "str": "iris_str"  # static ref — typedef for iris_view_String
    of "String": "iris_String"
    of "natural": "uint64_t"
    of "rune": "int32_t"
    else: n
  elif t of GenericType:
    let gt = GenericType(t)
    if gt.name == "view" and gt.args.len == 1 and gt.args[0] of NamedType:
      "iris_view_" & NamedType(gt.args[0]).name
    elif gt.name == "Seq" and gt.args.len == 1:
      "iris_Seq_" & g.typeToCStr(gt.args[0])
    elif gt.name == "HashTable" and gt.args.len == 2:
      "iris_HT_" & g.typeToCStr(gt.args[0]) & "__" & g.typeToCStr(gt.args[1])
    elif gt.name == "HashSet" and gt.args.len == 1:
      "iris_HS_" & g.typeToCStr(gt.args[0])
    elif gt.name == "array" and gt.args.len == 2:
      "__array_" & g.typeToCStr(gt.args[0]) & "_" & g.typeToCStr(gt.args[1])
    else:
      gt.name & "_" & gt.args.mapIt(g.typeToCStr(it)).join("_")
  elif t of TupleType:
    "/* tuple type */"
  else:
    "void"

proc varCType(g: CodeGen, name: string): string =
  g.varTypes.getOrDefault(name, "")

proc isArrayType(ct: string): bool = ct.startsWith("__array_")
proc isSeqType(ct: string): bool = ct.startsWith("iris_Seq_")
proc isHashTableType(ct: string): bool = ct.startsWith("iris_HT_")
proc isHashSetType(ct: string): bool = ct.startsWith("iris_HS_")

proc arrayElemType(ct: string): string =
  let rest = ct[8..^1]  # strip "__array_"
  let i = rest.rfind('_')
  rest[0..<i]

proc arraySize(ct: string): string =
  let i = ct.rfind('_')
  ct[i+1..^1]

proc seqElemType(ct: string): string =
  ct[9..^1]  # strip "iris_Seq_"

proc htKeyType(ct: string): string =
  let rest = ct[8..^1]  # strip "iris_HT_"
  let sep = rest.find("__")
  if sep >= 0: rest[0..<sep] else: rest

proc htValType(ct: string): string =
  let rest = ct[8..^1]
  let sep = rest.find("__")
  if sep >= 0: rest[sep+2..^1] else: ""

proc hsElemType(ct: string): string = ct[8..^1]  # strip "iris_HS_"

proc cTypeToIris(g: CodeGen, ct: string): string =
  ## Convert C type name back to Iris type name for error messages.
  if ct.isArrayType():
    return "array[" & g.cTypeToIris(arrayElemType(ct)) & ", " & arraySize(ct) & "]"
  if ct.isSeqType():
    return "Seq[" & g.cTypeToIris(seqElemType(ct)) & "]"
  if ct.isHashTableType():
    return "HashTable[" & g.cTypeToIris(htKeyType(ct)) & ", " & g.cTypeToIris(htValType(ct)) & "]"
  if ct.isHashSetType():
    return "HashSet[" & g.cTypeToIris(hsElemType(ct)) & "]"
  case ct
  of "iris_str": "str"
  of "iris_view_String": "view[String]"
  of "iris_String": "String"
  of "int64_t": "int"
  of "double": "float"
  of "bool": "bool"
  of "int32_t": "rune"
  of "uint64_t": "uint"
  else: ct

proc isAssignable(g: CodeGen, fromType, toType: string): bool =
  ## Check if fromType can be assigned to toType.
  ## Permissive by default — only rejects known incompatible string pairs.
  if fromType == toType: return true
  # str → view[String]: OK (static ref is a valid view)
  if fromType == "iris_str" and toType == "iris_view_String": return true
  # String → view[String]: OK (owned buffer can be viewed)
  if fromType == "iris_String" and toType == "iris_view_String": return true
  # Explicit rejections — known incompatible string pairs:
  if toType == "iris_str" and fromType in ["iris_view_String", "iris_String"]:
    return false  # view[String]/String → str: NO
  if toType == "iris_String" and fromType in ["iris_str", "iris_view_String"]:
    return false  # str/view[String] → String: NO (must use constructor)
  # All other type pairs — allow (full type system will catch later)
  return true

proc isGenericParam(params: seq[GenericParam], name: string): bool =
  for p in params:
    if p.name == name: return true
  return false

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

proc inferCType(g: CodeGen, e: Expr): string

proc printfFormat(g: CodeGen, e: Expr): tuple[fmt: string, needsCast: bool] =
  if e of StringLitExpr or e of StringInterpExpr: return ("%s", false)
  if e of FloatLitExpr: return ("%g", false)
  if e of BoolLitExpr: return ("%s", false)
  if e of DollarExpr: return ("%s", false)
  if e of IdentExpr:
    let ct = g.varCType(IdentExpr(e).name)
    case ct
    of "const char*": return ("%s", false)
    of "iris_str", "iris_view_String", "iris_String": return ("%.*s", false)
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
            of "iris_str", "iris_view_String", "iris_String": return ("%.*s", false)
            of "bool": return ("%s", false)
            else: return ("%lld", true)
  # Fallback — use inferCType for any expression (including CallExpr)
  let ct = g.inferCType(e)
  case ct
  of "iris_str", "iris_view_String", "iris_String": return ("%.*s", false)
  of "bool": return ("%s", false)
  of "double", "float": return ("%g", false)
  else: return ("%lld", true)

proc inferCType(g: CodeGen, e: Expr): string =
  if e of IntLitExpr: return "int64_t"
  if e of FloatLitExpr: return "double"
  if e of StringLitExpr or e of StringInterpExpr: return "iris_str"
  if e of StrLitExpr or e of StrInterpExpr: return "iris_String"
  if e of ArrayLitExpr:
    let a = ArrayLitExpr(e)
    let elemT = if a.fillValue != nil: g.inferCType(a.fillValue)
                elif a.elems.len > 0: g.inferCType(a.elems[0])
                else: "int64_t"
    let size = if a.fillCount != nil and a.fillCount of IntLitExpr: $IntLitExpr(a.fillCount).val
               else: $a.elems.len
    return "__array_" & elemT & "_" & size
  if e of SeqLitExpr:
    let s = SeqLitExpr(e)
    let elemT = if s.fillValue != nil: g.inferCType(s.fillValue)
                elif s.elems.len > 0: g.inferCType(s.elems[0])
                else: "int64_t"
    return "iris_Seq_" & elemT
  if e of HashTableLitExpr:
    let ht = HashTableLitExpr(e)
    if ht.entries.len > 0:
      let kt = g.inferCType(ht.entries[0].key)
      let vt = g.inferCType(ht.entries[0].value)
      return "iris_HT_" & kt & "__" & vt
    return "iris_HT_int64_t__int64_t"
  if e of HashSetLitExpr:
    let hs = HashSetLitExpr(e)
    if hs.elems.len > 0:
      return "iris_HS_" & g.inferCType(hs.elems[0])
    return "iris_HS_int64_t"
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
      if name == "String": return "iris_String"
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
              if gf.genericParams.isGenericParam(tn):
                subs[tn] = ct
        if gf.returnType != nil:
          let specRet = substituteType(gf.returnType, subs)
          return g.typeToCStr(specRet)
      return g.varTypes.getOrDefault(name, "int64_t")
  if e of FieldAccessExpr:
    let fa = FieldAccessExpr(e)
    if fa.expr of IdentExpr:
      let name = IdentExpr(fa.expr).name
      let varType = g.varCType(name)
      if fa.field == "len" and (varType.isArrayType() or varType.isSeqType() or varType.isHashTableType() or varType.isHashSetType()):
        return "int64_t"
      if fa.field == "cap" and (varType.isArrayType() or varType.isSeqType()):
        return "int64_t"
      if name in g.enumNames: return name
      if varType.len > 0 and varType in g.typeFields:
        for f in g.typeFields[varType]:
          if f.name == fa.field:
            return f.ctype
  if e of IndexExpr:
    let idx = IndexExpr(e)
    if idx.expr of IdentExpr:
      let varType = g.varCType(IdentExpr(idx.expr).name)
      if varType.isArrayType(): return arrayElemType(varType)
      if varType.isSeqType(): return seqElemType(varType)
      if varType.isHashTableType(): return htValType(varType)
  if e of IdentExpr:
    return g.varTypes.getOrDefault(IdentExpr(e).name, "int64_t")
  if e of IfExpr:
    return g.inferCType(IfExpr(e).value)
  if e of CaseExpr:
    let ce = CaseExpr(e)
    if ce.branches.len > 0:
      return g.inferCType(ce.branches[0].value)
    if ce.elseValue != nil:
      return g.inferCType(ce.elseValue)
  return "int64_t"

proc ensureOptionType(g: var CodeGen, valType, optType: string)

proc ensureArrayType(g: var CodeGen, elemType, size: string) =
  let arrType = "__array_" & elemType & "_" & size
  if arrType in g.emittedSeqTypes: return  # reuse the same tracking list
  g.emittedSeqTypes.add(arrType)
  var s = ""
  s.add("typedef struct { " & elemType & " data[" & size & "]; } " & arrType & ";\n\n")
  g.pendingSpecializations.add(s)

proc hashFuncFor(ctype: string): string =
  case ctype
  of "iris_str", "iris_view_String": "iris_hash_str"
  of "iris_String": "iris_hash_str"  # String has same data/len layout
  of "int64_t", "int32_t", "int16_t", "int8_t",
     "uint64_t", "uint32_t", "uint16_t", "uint8_t": "iris_hash_int"
  of "double", "float": "iris_hash_double"
  of "bool": "iris_hash_int"
  else: "iris_hash_int"

proc eqFuncFor(ctype: string): string =
  case ctype
  of "iris_str", "iris_view_String": "iris_eq_str"
  of "iris_String": "iris_eq_str"
  of "double", "float": "iris_eq_double"
  else: "iris_eq_int"

proc ensureHashTableType(g: var CodeGen, keyType, valType: string) =
  let htType = "iris_HT_" & keyType & "__" & valType
  if htType in g.emittedSeqTypes: return
  g.emittedSeqTypes.add(htType)
  let hashFn = hashFuncFor(keyType)
  let eqFn = eqFuncFor(keyType)
  # For str keys, we need to cast to iris_str for hashing
  let keyIsStr = keyType in ["iris_str", "iris_view_String", "iris_String"]
  let hashCall = if keyIsStr: hashFn & "(*(iris_str*)&s->keys[i])"
                 else: hashFn & "((" & (if keyType == "double": "double" else: "int64_t") & ")s->keys[i])"
  let hashCallK = if keyIsStr: hashFn & "(*(iris_str*)&key)"
                  else: hashFn & "((" & (if keyType == "double": "double" else: "int64_t") & ")key)"
  let eqCall = if keyIsStr: eqFn & "(*(iris_str*)&s->keys[i], *(iris_str*)&key)"
               else: eqFn & "(s->keys[i], key)"
  var s = ""
  # Struct: parallel arrays for used flags, keys, values
  s.add("typedef struct { bool* used; " & keyType & "* keys; " & valType & "* vals; size_t cap; size_t len; } " & htType & ";\n")
  # Create with capacity
  s.add("static inline " & htType & " " & htType & "_new(size_t cap) {\n")
  s.add("  if(cap<8) cap=8;\n")
  s.add("  bool* u=(bool*)calloc(cap,sizeof(bool));\n")
  s.add("  " & keyType & "* k=(" & keyType & "*)calloc(cap,sizeof(" & keyType & "));\n")
  s.add("  " & valType & "* v=(" & valType & "*)calloc(cap,sizeof(" & valType & "));\n")
  s.add("  return (" & htType & "){u,k,v,cap,0};\n}\n")
  # Internal find slot
  s.add("static inline size_t " & htType & "_findslot(" & htType & "* s, " & keyType & " key) {\n")
  s.add("  uint64_t h=" & hashCallK & "; size_t i=h&(s->cap-1);\n")
  s.add("  while(s->used[i] && !" & eqCall & ") i=(i+1)&(s->cap-1);\n")
  s.add("  return i;\n}\n")
  # Grow
  s.add("static inline void " & htType & "_grow(" & htType & "* s) {\n")
  s.add("  size_t oldcap=s->cap; bool* ou=s->used; " & keyType & "* ok=s->keys; " & valType & "* ov=s->vals;\n")
  s.add("  s->cap*=2; s->len=0;\n")
  s.add("  s->used=(bool*)calloc(s->cap,sizeof(bool));\n")
  s.add("  s->keys=(" & keyType & "*)calloc(s->cap,sizeof(" & keyType & "));\n")
  s.add("  s->vals=(" & valType & "*)calloc(s->cap,sizeof(" & valType & "));\n")
  s.add("  for(size_t i=0;i<oldcap;i++) if(ou[i]){ size_t j=" & htType & "_findslot(s,ok[i]); s->used[j]=true; s->keys[j]=ok[i]; s->vals[j]=ov[i]; s->len++; }\n")
  s.add("  free(ou); free(ok); free(ov);\n}\n")
  # set
  s.add("static inline void " & htType & "_set(" & htType & "* s, " & keyType & " key, " & valType & " val) {\n")
  s.add("  if(s->len*4>=s->cap*3) " & htType & "_grow(s);\n")  # 75% load factor
  s.add("  size_t i=" & htType & "_findslot(s,key);\n")
  s.add("  if(!s->used[i]) s->len++;\n")
  s.add("  s->used[i]=true; s->keys[i]=key; s->vals[i]=val;\n}\n")
  # get (returns value, undefined if missing)
  s.add("static inline " & valType & " " & htType & "_get(" & htType & "* s, " & keyType & " key) {\n")
  s.add("  size_t i=" & htType & "_findslot(s,key);\n")
  s.add("  return s->vals[i];\n}\n")
  # has
  s.add("static inline bool " & htType & "_has(" & htType & "* s, " & keyType & " key) {\n")
  s.add("  size_t i=" & htType & "_findslot(s,key);\n")
  s.add("  return s->used[i];\n}\n")
  # remove
  s.add("static inline void " & htType & "_remove(" & htType & "* s, " & keyType & " key) {\n")
  s.add("  size_t i=" & htType & "_findslot(s,key);\n")
  s.add("  if(!s->used[i]) return;\n")
  s.add("  s->used[i]=false; s->len--;\n")
  # backward-shift deletion
  let hashCallJ = if keyIsStr: hashFn & "(*(iris_str*)&s->keys[j])"
                  else: hashFn & "((" & (if keyType == "double": "double" else: "int64_t") & ")s->keys[j])"
  s.add("  size_t j=i;\n")
  s.add("  while(1){ j=(j+1)&(s->cap-1); if(!s->used[j]) break;\n")
  s.add("    size_t nat=" & hashCallJ & "&(s->cap-1);\n")
  s.add("    if((j>i && (nat<=i || nat>j)) || (j<i && nat<=i && nat>j))\n")
  s.add("      { s->used[i]=true; s->keys[i]=s->keys[j]; s->vals[i]=s->vals[j]; s->used[j]=false; i=j; }}\n}\n")
  # free
  s.add("static inline void " & htType & "_free(" & htType & "* s) { free(s->used); free(s->keys); free(s->vals); }\n\n")
  g.pendingSpecializations.add(s)

proc ensureHashSetType(g: var CodeGen, elemType: string) =
  let hsType = "iris_HS_" & elemType
  if hsType in g.emittedSeqTypes: return
  g.emittedSeqTypes.add(hsType)
  let hashFn = hashFuncFor(elemType)
  let eqFn = eqFuncFor(elemType)
  let keyIsStr = elemType in ["iris_str", "iris_view_String", "iris_String"]
  let hashCallK = if keyIsStr: hashFn & "(*(iris_str*)&key)"
                  else: hashFn & "((" & (if elemType == "double": "double" else: "int64_t") & ")key)"
  let eqCall = if keyIsStr: eqFn & "(*(iris_str*)&s->keys[i], *(iris_str*)&key)"
               else: eqFn & "(s->keys[i], key)"
  var s = ""
  s.add("typedef struct { bool* used; " & elemType & "* keys; size_t cap; size_t len; } " & hsType & ";\n")
  s.add("static inline " & hsType & " " & hsType & "_new(size_t cap) {\n")
  s.add("  if(cap<8) cap=8;\n")
  s.add("  return (" & hsType & "){(bool*)calloc(cap,sizeof(bool)),(" & elemType & "*)calloc(cap,sizeof(" & elemType & ")),cap,0};\n}\n")
  s.add("static inline size_t " & hsType & "_findslot(" & hsType & "* s, " & elemType & " key) {\n")
  s.add("  uint64_t h=" & hashCallK & "; size_t i=h&(s->cap-1);\n")
  s.add("  while(s->used[i] && !" & eqCall & ") i=(i+1)&(s->cap-1);\n")
  s.add("  return i;\n}\n")
  s.add("static inline void " & hsType & "_grow(" & hsType & "* s) {\n")
  s.add("  size_t oldcap=s->cap; bool* ou=s->used; " & elemType & "* ok=s->keys;\n")
  s.add("  s->cap*=2; s->len=0;\n")
  s.add("  s->used=(bool*)calloc(s->cap,sizeof(bool));\n")
  s.add("  s->keys=(" & elemType & "*)calloc(s->cap,sizeof(" & elemType & "));\n")
  s.add("  for(size_t i=0;i<oldcap;i++) if(ou[i]){ size_t j=" & hsType & "_findslot(s,ok[i]); s->used[j]=true; s->keys[j]=ok[i]; s->len++; }\n")
  s.add("  free(ou); free(ok);\n}\n")
  s.add("static inline void " & hsType & "_add(" & hsType & "* s, " & elemType & " key) {\n")
  s.add("  if(s->len*4>=s->cap*3) " & hsType & "_grow(s);\n")
  s.add("  size_t i=" & hsType & "_findslot(s,key);\n")
  s.add("  if(!s->used[i]) s->len++;\n")
  s.add("  s->used[i]=true; s->keys[i]=key;\n}\n")
  s.add("static inline bool " & hsType & "_has(" & hsType & "* s, " & elemType & " key) {\n")
  s.add("  size_t i=" & hsType & "_findslot(s,key);\n")
  s.add("  return s->used[i];\n}\n")
  s.add("static inline void " & hsType & "_remove(" & hsType & "* s, " & elemType & " key) {\n")
  s.add("  size_t i=" & hsType & "_findslot(s,key);\n")
  s.add("  if(!s->used[i]) return;\n")
  s.add("  s->used[i]=false; s->len--;\n")
  s.add("  size_t j=i;\n")
  s.add("  while(1){ j=(j+1)&(s->cap-1); if(!s->used[j]) break;\n")
  let hashCallJ = if keyIsStr: hashFn & "(*(iris_str*)&s->keys[j])"
                  else: hashFn & "((" & (if elemType == "double": "double" else: "int64_t") & ")s->keys[j])"
  s.add("    size_t nat=" & hashCallJ & "&(s->cap-1);\n")
  s.add("    if((j>i && (nat<=i || nat>j)) || (j<i && nat<=i && nat>j))\n")
  s.add("      { s->used[i]=true; s->keys[i]=s->keys[j]; s->used[j]=false; i=j; }}\n}\n")
  s.add("static inline void " & hsType & "_free(" & hsType & "* s) { free(s->used); free(s->keys); }\n\n")
  g.pendingSpecializations.add(s)

proc ensureSeqType(g: var CodeGen, elemType: string) =
  let seqType = "iris_Seq_" & elemType
  if seqType in g.emittedSeqTypes: return
  g.emittedSeqTypes.add(seqType)
  var s = ""
  s.add("typedef struct { " & elemType & "* data; size_t len; size_t cap; } " & seqType & ";\n")
  # from N elements
  s.add("static inline " & seqType & " " & seqType & "_from(" & elemType & "* arr, size_t n) {\n")
  s.add("  " & elemType & "* data = (" & elemType & "*)malloc(n * sizeof(" & elemType & "));\n")
  s.add("  for (size_t i = 0; i < n; i++) data[i] = arr[i];\n")
  s.add("  return (" & seqType & "){data, n, n};\n}\n")
  # fill
  s.add("static inline " & seqType & " " & seqType & "_fill(" & elemType & " val, size_t n) {\n")
  s.add("  " & elemType & "* data = (" & elemType & "*)malloc(n * sizeof(" & elemType & "));\n")
  s.add("  for (size_t i = 0; i < n; i++) data[i] = val;\n")
  s.add("  return (" & seqType & "){data, n, n};\n}\n")
  # with capacity
  s.add("static inline " & seqType & " " & seqType & "_with_cap(size_t cap) {\n")
  s.add("  return (" & seqType & "){(" & elemType & "*)malloc(cap * sizeof(" & elemType & ")), 0, cap};\n}\n")
  # add
  s.add("static inline void " & seqType & "_add(" & seqType & "* s, " & elemType & " val) {\n")
  s.add("  if (s->len == s->cap) {\n")
  s.add("    s->cap = s->cap == 0 ? 4 : s->cap * 2;\n")
  s.add("    s->data = (" & elemType & "*)realloc(s->data, s->cap * sizeof(" & elemType & "));\n")
  s.add("  }\n  s->data[s->len++] = val;\n}\n")
  # remove (remove at index, preserve order, O(n))
  s.add("static inline void " & seqType & "_remove(" & seqType & "* s, size_t i) {\n")
  s.add("  for (size_t j = i; j < s->len - 1; j++) s->data[j] = s->data[j + 1];\n")
  s.add("  s->len--;\n}\n")
  # removeSwap (remove at index, swap with last, O(1))
  s.add("static inline void " & seqType & "_removeSwap(" & seqType & "* s, size_t i) {\n")
  s.add("  s->data[i] = s->data[s->len - 1];\n")
  s.add("  s->len--;\n}\n")
  # pop (remove and return last)
  s.add("static inline " & elemType & " " & seqType & "_pop(" & seqType & "* s) {\n")
  s.add("  return s->data[--s->len];\n}\n")
  # insert (insert at index, shift right, O(n))
  s.add("static inline void " & seqType & "_insert(" & seqType & "* s, size_t i, " & elemType & " val) {\n")
  s.add("  if (s->len == s->cap) {\n")
  s.add("    s->cap = s->cap == 0 ? 4 : s->cap * 2;\n")
  s.add("    s->data = (" & elemType & "*)realloc(s->data, s->cap * sizeof(" & elemType & "));\n")
  s.add("  }\n")
  s.add("  for (size_t j = s->len; j > i; j--) s->data[j] = s->data[j - 1];\n")
  s.add("  s->data[i] = val;\n  s->len++;\n}\n")
  # contains (returns bool)
  s.add("static inline bool " & seqType & "_contains(" & seqType & "* s, " & elemType & " val) {\n")
  s.add("  for (size_t i = 0; i < s->len; i++) if (s->data[i] == val) return true;\n")
  s.add("  return false;\n}\n")
  # find (returns index, -1 if not found)
  s.add("static inline int64_t " & seqType & "_find(" & seqType & "* s, " & elemType & " val) {\n")
  s.add("  for (size_t i = 0; i < s->len; i++) if (s->data[i] == val) return (int64_t)i;\n")
  s.add("  return -1;\n}\n")
  # free
  s.add("static inline void " & seqType & "_free(" & seqType & "* s) { free(s->data); s->data = NULL; s->len = 0; s->cap = 0; }\n\n")
  g.pendingSpecializations.add(s)

# ── Expression codegen ──

proc genExpr(g: var CodeGen, e: Expr)
proc genStmt*(g: var CodeGen, s: Stmt)
proc genCondExpr(g: var CodeGen, e: Expr)

proc genEchoArg(g: var CodeGen, e: Expr) =
  if e of BoolLitExpr:
    g.emit(if BoolLitExpr(e).val: "\"true\"" else: "\"false\"")
  elif e of IdentExpr:
    let name = IdentExpr(e).name
    let ct = g.varCType(name)
    if ct == "bool": g.emit("(" & name & " ? \"true\" : \"false\")")
    elif ct in ["iris_str", "iris_view_String", "iris_String"]: g.emit("(int)" & name & ".len, " & name & ".data")
    else: g.genExpr(e)
  elif e of DollarExpr:
    let inner = DollarExpr(e).expr
    if inner of IdentExpr:
      let name = IdentExpr(inner).name
      let ct = g.varCType(name)
      if ct == "bool": g.emit("(" & name & " ? \"true\" : \"false\")")
      elif ct in ["iris_str", "iris_view_String", "iris_String"]: g.emit("(int)" & name & ".len, " & name & ".data")
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
    let ct = g.inferCType(e)
    if ct == "bool":
      g.emit("("); g.genExpr(e); g.emit(" ? \"true\" : \"false\")")
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
    let ct = g.inferCType(e)
    # Non-trivial expression returning string — use temp variable
    # (IdentExpr is handled in genEchoArg, literals handled above)
    if ct in ["iris_str", "iris_view_String", "iris_String"] and not (e of IdentExpr):
      g.emit("{ " & ct & " __echo_tmp = ")
      g.genExpr(e)
      g.emit("; printf(\"%.*s\\n\", (int)__echo_tmp.len, __echo_tmp.data); }")
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
    g.emit("iris_view_String_from(\"" & escapeC(StringLitExpr(e).val) & "\")")
  elif e of StrLitExpr:
    g.emit("iris_String_from(\"" & escapeC(StrLitExpr(e).val) & "\")")
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
    g.emit("iris_String_fmt(\"" & fmt & "\"")
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
      # Seq methods
      if fa.expr of IdentExpr:
        let varName = IdentExpr(fa.expr).name
        let varType = g.varCType(varName)
        if varType.isSeqType():
          # .add(x)
          if fa.field == "add" and c.args.len == 1:
            g.emit(varType & "_add(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
          # .remove(i)
          if fa.field == "remove" and c.args.len == 1:
            g.emit(varType & "_remove(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
          # .removeSwap(i)
          if fa.field == "removeSwap" and c.args.len == 1:
            g.emit(varType & "_removeSwap(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
          # .pop()
          if fa.field == "pop" and c.args.len == 0:
            g.emit(varType & "_pop(&" & varName & ")")
            return
          # .insert(i, value)
          if fa.field == "insert" and c.args.len == 2:
            g.emit(varType & "_insert(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(", ")
            g.genExpr(c.args[1].value)
            g.emit(")")
            return
          # .contains(x)
          if fa.field == "contains" and c.args.len == 1:
            g.emit(varType & "_contains(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
          # .find(x)
          if fa.field == "find" and c.args.len == 1:
            g.emit(varType & "_find(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
        # HashTable methods
        if varType.isHashTableType():
          if fa.field == "set" and c.args.len == 2:
            g.emit(varType & "_set(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(", ")
            g.genExpr(c.args[1].value)
            g.emit(")")
            return
          if fa.field == "has" and c.args.len == 1:
            g.emit(varType & "_has(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
          if fa.field == "remove" and c.args.len == 1:
            g.emit(varType & "_remove(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
        # HashSet methods
        if varType.isHashSetType():
          if fa.field == "add" and c.args.len == 1:
            g.emit(varType & "_add(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
          if fa.field == "has" and c.args.len == 1:
            g.emit(varType & "_has(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
          if fa.field == "remove" and c.args.len == 1:
            g.emit(varType & "_remove(&" & varName & ", ")
            g.genExpr(c.args[0].value)
            g.emit(")")
            return
    if c.fn of IdentExpr:
      let name = IdentExpr(c.fn).name
      if name == "echo":
        g.genEcho(c.args); return
      # Str("literal") or Str(view) → owned string
      if name == "String" and c.args.len == 1:
        if c.args[0].value of StringLitExpr:
          g.emit("iris_String_from(\"" & escapeC(StringLitExpr(c.args[0].value).val) & "\")")
        else:
          g.emit("iris_String_from_view(")
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
              if gf.genericParams.isGenericParam(tn):
                subs[tn] = concreteType
            elif param.typeAnn of GenericType:
              let gt = GenericType(param.typeAnn)
              # view[T] → extract inner type
              if gt.name == "view" and gt.args.len == 1 and gt.args[0] of NamedType:
                let inner = NamedType(gt.args[0]).name
                if gf.genericParams.isGenericParam(inner):
                  # concreteType is iris_view_X → extract X
                  if concreteType.startsWith("iris_view_"):
                    subs[inner] = concreteType[10..^1]
                  else:
                    subs[inner] = concreteType
        # Validate concept constraints
        for gp in gf.genericParams:
          if gp.constraint.len > 0 and gp.name in subs:
            let concreteType = subs[gp.name]
            if gp.constraint in g.concepts:
              let cdef = g.concepts[gp.constraint]
              let methods = g.typeMethods.getOrDefault(concreteType, @[])
              for m in cdef.methods:
                # Build expected param types: @self/nil → concreteType, Self → concreteType
                var expectedParams: seq[string]
                for p in m.params:
                  if p.typeAnn == nil:
                    expectedParams.add(concreteType)  # @self
                  elif p.typeAnn of NamedType and NamedType(p.typeAnn).name == "Self":
                    expectedParams.add(concreteType)  # Self → concrete type
                  else:
                    expectedParams.add(g.typeToCStr(p.typeAnn))
                let expectedRet = if m.returnType != nil: g.typeToCStr(m.returnType) else: "void"
                var found = false
                for tm in methods:
                  if tm.name == m.name and tm.paramTypes == expectedParams and tm.retType == expectedRet:
                    found = true
                    break
                if not found:
                  var sig = m.name & "("
                  for i, p in m.params:
                    if i > 0: sig.add(", ")
                    sig.add("@" & p.name)
                    if p.typeAnn == nil: sig.add(" " & concreteType)
                    elif p.typeAnn of NamedType and NamedType(p.typeAnn).name == "Self": sig.add(" " & concreteType)
                    elif p.typeAnn != nil: sig.add(" " & g.typeToCStr(p.typeAnn))
                  sig.add(")")
                  if m.returnType != nil: sig.add(" ok " & g.typeToCStr(m.returnType))
                  raise newException(ValueError,
                    "error: type '" & concreteType & "' does not satisfy concept '" &
                    gp.constraint & "'\n  missing: " & sig)
        # Build specialized name
        let specName = name & "_" & gf.genericParams.mapIt(subs.getOrDefault(it.name, "unknown")).join("_")
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
    # Type check arguments against parameter types
    if c.fn of IdentExpr:
      let fname = IdentExpr(c.fn).name
      if fname in g.fnParamTypes:
        let paramTypes = g.fnParamTypes[fname]
        for i, arg in c.args:
          if i < paramTypes.len:
            let argType = g.inferCType(arg.value)
            if not g.isAssignable(argType, paramTypes[i]):
              raise newException(ValueError,
                "error: type mismatch in argument " & $(i+1) & " of '" & fname &
                "' — expected '" & g.cTypeToIris(paramTypes[i]) &
                "', got '" & g.cTypeToIris(argType) & "'")
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
      let varType = g.varCType(name)
      # .len / .cap on array → compile-time constant (cap == len for fixed arrays)
      if (f.field == "len" or f.field == "cap") and varType.isArrayType():
        g.emit(arraySize(varType)); return
      # .len on Seq → field access
      if f.field == "len" and varType.isSeqType():
        g.emit("(int64_t)" & name & ".len"); return
      # .cap on Seq → field access
      if f.field == "cap" and varType.isSeqType():
        g.emit("(int64_t)" & name & ".cap"); return
      # .len on HashTable/HashSet
      if f.field == "len" and (varType.isHashTableType() or varType.isHashSetType()):
        g.emit("(int64_t)" & name & ".len"); return
      if name in g.enumNames:
        g.emit(name & "_" & f.field); return
      # Check variant field access
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
    if idx.expr of IdentExpr:
      let varName = IdentExpr(idx.expr).name
      let varType = g.varCType(varName)
      if varType.isSeqType() or varType.isArrayType():
        g.genExpr(idx.expr); g.emit(".data["); g.genExpr(idx.index); g.emit("]")
        return
      if varType.isHashTableType():
        g.emit(varType & "_get(&" & varName & ", ")
        g.genExpr(idx.index)
        g.emit(")")
        return
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
    let elemType = if a.fillValue != nil: g.inferCType(a.fillValue)
                   elif a.elems.len > 0: g.inferCType(a.elems[0])
                   else: "int64_t"
    let size = if a.fillCount != nil and a.fillCount of IntLitExpr: $IntLitExpr(a.fillCount).val
               else: $a.elems.len
    let arrType = "__array_" & elemType & "_" & size
    g.ensureArrayType(elemType, size)
    if a.fillValue != nil:
      if a.fillValue of IntLitExpr and IntLitExpr(a.fillValue).val == 0:
        g.emit("(" & arrType & "){{0}}")
      elif a.fillCount of IntLitExpr:
        let n = IntLitExpr(a.fillCount).val
        g.emit("(" & arrType & "){{")
        for i in 0..<n:
          if i > 0: g.emit(", ")
          g.genExpr(a.fillValue)
        g.emit("}}")
      else:
        g.emit("(" & arrType & "){{0}}")
    else:
      g.emit("(" & arrType & "){{")
      for i, el in a.elems:
        if i > 0: g.emit(", ")
        g.genExpr(el)
      g.emit("}}")
  elif e of SeqLitExpr:
    let s = SeqLitExpr(e)
    let elemType = if s.fillValue != nil: g.inferCType(s.fillValue)
                   elif s.elems.len > 0: g.inferCType(s.elems[0])
                   else: "int64_t"
    let seqType = "iris_Seq_" & elemType
    g.ensureSeqType(elemType)
    if s.capacityOnly:
      g.emit(seqType & "_with_cap(")
      g.genExpr(s.fillCount)
      g.emit(")")
    elif s.fillValue != nil:
      g.emit(seqType & "_fill(")
      g.genExpr(s.fillValue)
      g.emit(", ")
      g.genExpr(s.fillCount)
      g.emit(")")
    elif s.elems.len == 0:
      g.emit("(" & seqType & "){NULL, 0, 0}")
    else:
      g.emit(seqType & "_from((" & elemType & "[]){")
      for i, el in s.elems:
        if i > 0: g.emit(", ")
        g.genExpr(el)
      g.emit("}, " & $s.elems.len & ")")
  elif e of HashTableLitExpr:
    let ht = HashTableLitExpr(e)
    let kt = if ht.entries.len > 0: g.inferCType(ht.entries[0].key) else: "int64_t"
    let vt = if ht.entries.len > 0: g.inferCType(ht.entries[0].value) else: "int64_t"
    let htType = "iris_HT_" & kt & "__" & vt
    g.ensureHashTableType(kt, vt)
    if ht.entries.len == 0:
      g.emit(htType & "_new(8)")
    else:
      # Create table and insert entries via a compound expression
      let tmp = "__ht_" & $g.tmpCounter; g.tmpCounter += 1
      g.emit("({" & htType & " " & tmp & "=" & htType & "_new(" & $(ht.entries.len * 2) & ");")
      for entry in ht.entries:
        g.emit(htType & "_set(&" & tmp & ",")
        g.genExpr(entry.key)
        g.emit(",")
        g.genExpr(entry.value)
        g.emit(");")
      g.emit(tmp & ";})")
  elif e of HashSetLitExpr:
    let hs = HashSetLitExpr(e)
    let et = if hs.elems.len > 0: g.inferCType(hs.elems[0]) else: "int64_t"
    let hsType = "iris_HS_" & et
    g.ensureHashSetType(et)
    if hs.elems.len == 0:
      g.emit(hsType & "_new(8)")
    else:
      let tmp = "__hs_" & $g.tmpCounter; g.tmpCounter += 1
      g.emit("({" & hsType & " " & tmp & "=" & hsType & "_new(" & $(hs.elems.len * 2) & ");")
      for el in hs.elems:
        g.emit(hsType & "_add(&" & tmp & ",")
        g.genExpr(el)
        g.emit(");")
      g.emit(tmp & ";})")
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
  elif e of IfExpr:
    let ie = IfExpr(e)
    # value if cond else elseValue → (cond) ? (value) : (elseValue)
    g.emit("("); g.genCondExpr(ie.cond); g.emit(") ? (")
    g.genExpr(ie.value); g.emit(") : (")
    g.genExpr(ie.elseValue); g.emit(")")
  elif e of CaseExpr:
    let ce = CaseExpr(e)
    # Determine type context for comparison
    var enumType = ""
    var resultType = ""
    if ce.expr of IdentExpr:
      let ct = g.varCType(IdentExpr(ce.expr).name)
      if ct in g.enumNames: enumType = ct
      elif ct.endsWith("_Result"): resultType = ct
    elif ce.expr of FieldAccessExpr:
      let fa = FieldAccessExpr(ce.expr)
      if fa.expr of IdentExpr:
        let objType = g.varCType(IdentExpr(fa.expr).name)
        if objType.len > 0 and objType in g.variantInfo:
          let vi = g.variantInfo[objType]
          if fa.field == vi.tagName:
            enumType = vi.tagType
    # Generate nested ternary — last branch becomes fallback (exhaustive)
    # Wrap entire chain in () for safe embedding in larger expressions
    g.emit("(")
    let lastIdx = ce.branches.len - 1
    for i, b in ce.branches:
      if i == lastIdx and ce.elseValue == nil:
        # Last branch without else — use as fallback
        g.genExpr(b.value)
      else:
        g.emit("(")
        if resultType.len > 0:
          g.genExpr(ce.expr); g.emit(".kind == ")
          case b.pattern.kind
          of patOk: g.emit(resultType & "_Ok")
          of patVariant: g.emit(resultType & "_" & b.pattern.name)
          else: g.emit("/* unsupported pattern */")
        elif enumType.len > 0:
          g.genExpr(ce.expr); g.emit(" == ")
          g.emit(enumType & "_" & b.pattern.name)
        else:
          g.genExpr(ce.expr); g.emit(" == ")
          g.emit(b.pattern.name)
        g.emit(") ? "); g.genExpr(b.value); g.emit(" : ")
    if ce.elseValue != nil:
      g.genExpr(ce.elseValue)
    g.emit(")")
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
    # Type compatibility check when annotation is present and value is given
    if d.typeAnn != nil and d.value != nil:
      let valType = g.inferCType(d.value)
      if not g.isAssignable(valType, ctype):
        raise newException(ValueError,
          "error: type mismatch in declaration '@" & d.name &
          "' — expected '" & g.cTypeToIris(ctype) &
          "', got '" & g.cTypeToIris(valType) & "'")
    # Ensure runtime types are emitted
    if ctype.isSeqType():
      g.ensureSeqType(seqElemType(ctype))
    if ctype.isArrayType():
      g.ensureArrayType(arrayElemType(ctype), arraySize(ctype))
    if ctype.isHashTableType():
      g.ensureHashTableType(htKeyType(ctype), htValType(ctype))
    if ctype.isHashSetType():
      g.ensureHashSetType(hsElemType(ctype))
    g.varTypes[d.name] = ctype
    g.emitIndent()
    if d.value == nil:
      # Declaration without value: @x int — assigned later
      g.emit(ctype & " " & d.name & ";\n")
    else:
      case d.modifier
      of declDefault, declConst:
        g.emit("const " & ctype & " " & d.name & " = ")
      of declMut:
        g.emit(ctype & " " & d.name & " = ")
      g.genExpr(d.value)
      g.emit(";\n")

  elif s of DestructDeclStmt:
    let dd = DestructDeclStmt(s)

    proc fieldAccessor(g: CodeGen, tmpName, tmpType: string, index: int, fieldName: string): string =
      ## Build C field access expression for a destructured element.
      if fieldName.len > 0:
        return tmpName & "." & fieldName
      let fields = g.typeFields.getOrDefault(tmpType, @[])
      if index < fields.len:
        return tmpName & "." & fields[index].name
      return tmpName & ".field" & $index

    proc fieldCType(g: CodeGen, tmpType: string, index: int, fieldName: string): string =
      ## Look up the C type of a tuple/object field by index or name.
      let fields = g.typeFields.getOrDefault(tmpType, @[])
      if fieldName.len > 0:
        for f in fields:
          if f.name == fieldName: return f.ctype
      if index < fields.len:
        return fields[index].ctype
      return "int64_t"

    proc genDestructPattern(g: var CodeGen, pat: DestructPattern, tmpName, tmpType: string, index: int) =
      case pat.kind
      of dpVar:
        let access = g.fieldAccessor(tmpName, tmpType, index, pat.fieldName)
        let ct = g.fieldCType(tmpType, index, pat.fieldName)
        g.varTypes[pat.name] = ct
        g.emitIndent()
        case pat.modifier
        of declDefault, declConst:
          g.emit("const " & ct & " " & pat.name & " = " & access & ";\n")
        of declMut:
          g.emit(ct & " " & pat.name & " = " & access & ";\n")
      of dpSkip:
        discard
      of dpNested:
        let access = g.fieldAccessor(tmpName, tmpType, index, "")
        let ct = g.fieldCType(tmpType, index, "")
        let nestedTmp = g.nextTmp()
        g.emitIndent()
        g.emit("const " & ct & " " & nestedTmp & " = " & access & ";\n")
        for i, child in pat.children:
          g.genDestructPattern(child, nestedTmp, ct, i)

    # Path A: RHS is a tuple literal — assign directly, no temp needed
    if dd.value of TupleLitExpr:
      let tup = TupleLitExpr(dd.value)
      proc genDirectAssign(g: var CodeGen, pat: DestructPattern, tup: TupleLitExpr) =
        for i, child in pat.children:
          case child.kind
          of dpVar:
            let elemType = g.inferCType(tup.elems[i].value)
            g.varTypes[child.name] = elemType
            g.emitIndent()
            case child.modifier
            of declDefault, declConst:
              g.emit("const " & elemType & " " & child.name & " = ")
            of declMut:
              g.emit(elemType & " " & child.name & " = ")
            g.genExpr(tup.elems[i].value)
            g.emit(";\n")
          of dpSkip:
            discard
          of dpNested:
            # Nested element with a tuple literal sub-expression
            if tup.elems[i].value of TupleLitExpr:
              g.genDirectAssign(child, TupleLitExpr(tup.elems[i].value))
            else:
              # Fall back to temp-based approach for non-literal nested
              let innerTmp = g.nextTmp()
              let innerType = g.inferCType(tup.elems[i].value)
              g.emitIndent()
              g.emit("const " & innerType & " " & innerTmp & " = ")
              g.genExpr(tup.elems[i].value)
              g.emit(";\n")
              for j, grandchild in child.children:
                g.genDestructPattern(grandchild, innerTmp, innerType, j)
      g.genDirectAssign(dd.pattern, tup)
    else:
      # Path B: RHS is a call/variable — evaluate into temp, access fields
      let tmpName = g.nextTmp()
      let tmpType = g.inferCType(dd.value)
      g.emitIndent()
      g.emit("const " & tmpType & " " & tmpName & " = ")
      g.genExpr(dd.value)
      g.emit(";\n")
      for i, child in dd.pattern.children:
        g.genDestructPattern(child, tmpName, tmpType, i)

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
    let rs = ResultAssignStmt(s)
    # result.field = value
    if rs.field.len > 0:
      g.emitIndent()
      if g.inResultFunc:
        g.emit("__result.value." & rs.field & " = ")
      else:
        g.emit("__result." & rs.field & " = ")
      g.genExpr(rs.value); g.emit(";\n")
      return
    # result = Error(...)
    let val = rs.value
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
    # result = value
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
    # Track methods: func(@self TypeName) → register as method of TypeName
    if f.params.len > 0 and f.params[0].name == "self" and f.params[0].typeAnn != nil:
      if f.params[0].typeAnn of NamedType:
        let typeName = NamedType(f.params[0].typeAnn).name
        let retType = if f.returnType != nil: g.typeToCStr(f.returnType) else: "void"
        var paramTypes: seq[string]
        for p in f.params:
          if p.typeAnn != nil: paramTypes.add(g.typeToCStr(p.typeAnn))
          else: paramTypes.add(typeName)  # @self without type → the type itself
        if typeName notin g.typeMethods:
          g.typeMethods[typeName] = @[]
        g.typeMethods[typeName].add((name: f.name, paramTypes: paramTypes, retType: retType))
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
      g.varTypes[f.varName] = "int64_t"
      g.indent += 1
      for st in f.body: g.genStmt(st)
      g.indent -= 1
      g.emitLine("}")
    elif f.iter of IdentExpr:
      let iterName = IdentExpr(f.iter).name
      let iterType = g.varCType(iterName)
      let idx = "__i_" & f.varName
      if iterType.isSeqType():
        let elemT = seqElemType(iterType)
        g.varTypes[f.varName] = elemT
        g.emitIndent()
        g.emit("for (size_t " & idx & " = 0; " & idx & " < " & iterName & ".len; " & idx & "++) {\n")
        g.indent += 1
        g.emitLine(elemT & " " & f.varName & " = " & iterName & ".data[" & idx & "];")
        for st in f.body: g.genStmt(st)
        g.indent -= 1
        g.emitLine("}")
      elif iterType.isArrayType():
        let elemT = arrayElemType(iterType)
        let size = arraySize(iterType)
        g.varTypes[f.varName] = elemT
        g.emitIndent()
        g.emit("for (size_t " & idx & " = 0; " & idx & " < " & size & "; " & idx & "++) {\n")
        g.indent += 1
        g.emitLine(elemT & " " & f.varName & " = " & iterName & ".data[" & idx & "];")
        for st in f.body: g.genStmt(st)
        g.indent -= 1
        g.emitLine("}")
      else:
        g.emitIndent(); g.emit("/* for " & f.varName & " in <collection> */ {\n")
        g.indent += 1
        for st in f.body: g.genStmt(st)
        g.indent -= 1
        g.emitLine("}")
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
    # Check: view[T] not allowed in object fields (including variant fields)
    for f in o.fields:
      if f.typeAnn of GenericType and GenericType(f.typeAnn).name == "view":
        raise newException(ValueError,
          "error: " & g.cTypeToIris(g.typeToCStr(f.typeAnn)) &
          " cannot be stored in object fields — use 'str' (static) or 'String' (owned) instead" &
          "\n  in field '@" & f.name & "' of object '" & o.name & "'")
    if o.variant.tagName.len > 0:
      for b in o.variant.branches:
        for f in b.fields:
          if f.typeAnn of GenericType and GenericType(f.typeAnn).name == "view":
            raise newException(ValueError,
              "error: " & g.cTypeToIris(g.typeToCStr(f.typeAnn)) &
              " cannot be stored in object fields — use 'str' (static) or 'String' (owned) instead" &
              "\n  in variant field '@" & f.name & "' of object '" & o.name & "'")
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
    # Check: view[T] not allowed in error fields
    for f in e.fields:
      if f.typeAnn of GenericType and GenericType(f.typeAnn).name == "view":
        raise newException(ValueError,
          "error: " & g.cTypeToIris(g.typeToCStr(f.typeAnn)) &
          " cannot be stored in error fields — use 'str' (static) or 'String' (owned) instead" &
          "\n  in field '@" & f.name & "' of error '" & e.name & "'")
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

  elif s of ConceptDeclStmt:
    # Concepts are compile-time only — store for validation, no C output
    let c = ConceptDeclStmt(s)
    g.concepts[c.name] = c

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
  g.emit("// view[String] — immutable view (pointer + length)\n")
  g.emit("typedef struct { const char* data; size_t len; } iris_view_String;\n")
  g.emit("static inline iris_view_String iris_view_String_from(const char* s) {\n")
  g.emit("  return (iris_view_String){s, strlen(s)};\n")
  g.emit("}\n\n")
  g.emit("// str — static string reference (same layout as view[String])\n")
  g.emit("typedef iris_view_String iris_str;\n")
  g.emit("#define iris_str_from iris_view_String_from\n\n")
  g.emit("// String — owned heap buffer (pointer + length + capacity)\n")
  g.emit("typedef struct { char* data; size_t len; size_t cap; } iris_String;\n")
  g.emit("static inline iris_String iris_String_from(const char* s) {\n")
  g.emit("  size_t len = strlen(s);\n")
  g.emit("  char* data = (char*)malloc(len + 1);\n")
  g.emit("  memcpy(data, s, len + 1);\n")
  g.emit("  return (iris_String){data, len, len};\n")
  g.emit("}\n")
  g.emit("static inline iris_String iris_String_from_view(iris_view_String v) {\n")
  g.emit("  char* data = (char*)malloc(v.len + 1);\n")
  g.emit("  memcpy(data, v.data, v.len);\n")
  g.emit("  data[v.len] = '\\0';\n")
  g.emit("  return (iris_String){data, v.len, v.len};\n")
  g.emit("}\n")
  g.emit("static inline iris_String iris_String_fmt(const char* fmt, ...) {\n")
  g.emit("  va_list a1, a2;\n")
  g.emit("  va_start(a1, fmt); va_copy(a2, a1);\n")
  g.emit("  int len = vsnprintf(NULL, 0, fmt, a1); va_end(a1);\n")
  g.emit("  char* data = (char*)malloc(len + 1);\n")
  g.emit("  vsnprintf(data, len + 1, fmt, a2); va_end(a2);\n")
  g.emit("  return (iris_String){data, (size_t)len, (size_t)len};\n")
  g.emit("}\n\n")

  # wyhash v4.3 by Wang Yi — public domain (Unlicense)
  g.emit("// wyhash v4.3 by Wang Yi — public domain (Unlicense)\n")
  g.emit("static inline void _wymum(uint64_t *A, uint64_t *B) {\n")
  g.emit("#if defined(__SIZEOF_INT128__)\n")
  g.emit("  __uint128_t r = *A; r *= *B; *A = (uint64_t)r; *B = (uint64_t)(r >> 64);\n")
  g.emit("#else\n")
  g.emit("  uint64_t ha=*A>>32, hb=*B>>32, la=(uint32_t)*A, lb=(uint32_t)*B;\n")
  g.emit("  uint64_t rh=ha*hb, rm0=ha*lb, rm1=hb*la, rl=la*lb;\n")
  g.emit("  uint64_t t=rl+(rm0<<32), c=t<rl; uint64_t lo=t+(rm1<<32); c+=lo<t;\n")
  g.emit("  *A=lo; *B=rh+(rm0>>32)+(rm1>>32)+c;\n")
  g.emit("#endif\n}\n")
  g.emit("static inline uint64_t _wymix(uint64_t A, uint64_t B) { _wymum(&A,&B); return A^B; }\n")
  g.emit("static inline uint64_t _wyr8(const uint8_t *p) { uint64_t v; memcpy(&v,p,8); return v; }\n")
  g.emit("static inline uint64_t _wyr4(const uint8_t *p) { uint32_t v; memcpy(&v,p,4); return v; }\n")
  g.emit("static inline uint64_t _wyr3(const uint8_t *p, size_t k) {\n")
  g.emit("  return ((uint64_t)p[0]<<16)|((uint64_t)p[k>>1]<<8)|p[k-1]; }\n")
  g.emit("static const uint64_t _wyp[4] = {\n")
  g.emit("  0x2d358dccaa6c78a5ull, 0x8bb84b93962eacc9ull,\n")
  g.emit("  0x4b33a62ed433d4a3ull, 0x4d5a2da51de1aa47ull};\n")
  g.emit("static inline uint64_t wyhash(const void *key, size_t len, uint64_t seed, const uint64_t *secret) {\n")
  g.emit("  const uint8_t *p=(const uint8_t*)key; seed^=_wymix(seed^secret[0],secret[1]);\n")
  g.emit("  uint64_t a,b;\n")
  g.emit("  if(len<=16){\n")
  g.emit("    if(len>=4){ a=(_wyr4(p)<<32)|_wyr4(p+((len>>3)<<2)); b=(_wyr4(p+len-4)<<32)|_wyr4(p+len-4-((len>>3)<<2)); }\n")
  g.emit("    else if(len>0){ a=_wyr3(p,len); b=0; } else a=b=0;\n")
  g.emit("  } else {\n")
  g.emit("    size_t i=len;\n")
  g.emit("    if(i>=48){ uint64_t see1=seed,see2=seed;\n")
  g.emit("      do{ seed=_wymix(_wyr8(p)^secret[1],_wyr8(p+8)^seed);\n")
  g.emit("        see1=_wymix(_wyr8(p+16)^secret[2],_wyr8(p+24)^see1);\n")
  g.emit("        see2=_wymix(_wyr8(p+32)^secret[3],_wyr8(p+40)^see2);\n")
  g.emit("        p+=48; i-=48; }while(i>=48); seed^=see1^see2; }\n")
  g.emit("    while(i>16){ seed=_wymix(_wyr8(p)^secret[1],_wyr8(p+8)^seed); i-=16; p+=16; }\n")
  g.emit("    a=_wyr8(p+i-16); b=_wyr8(p+i-8); }\n")
  g.emit("  a^=secret[1]; b^=seed; _wymum(&a,&b);\n")
  g.emit("  return _wymix(a^secret[0]^len, b^secret[1]);\n}\n")
  g.emit("static inline uint64_t wyhash64(uint64_t A, uint64_t B) {\n")
  g.emit("  A^=0x2d358dccaa6c78a5ull; B^=0x8bb84b93962eacc9ull; _wymum(&A,&B);\n")
  g.emit("  return _wymix(A^0x2d358dccaa6c78a5ull, B^0x8bb84b93962eacc9ull);\n}\n")
  # str/view hash helpers
  g.emit("static inline uint64_t iris_hash_str(iris_str s) { return wyhash(s.data, s.len, 0, _wyp); }\n")
  g.emit("static inline bool iris_eq_str(iris_str a, iris_str b) { return a.len==b.len && memcmp(a.data,b.data,a.len)==0; }\n")
  g.emit("static inline uint64_t iris_hash_int(int64_t v) { return wyhash64((uint64_t)v, 0); }\n")
  g.emit("static inline bool iris_eq_int(int64_t a, int64_t b) { return a==b; }\n")
  g.emit("static inline uint64_t iris_hash_double(double v) { uint64_t u; memcpy(&u,&v,8); return wyhash64(u, 0); }\n")
  g.emit("static inline bool iris_eq_double(double a, double b) { return a==b; }\n\n")

  # Common Option types
  g.emit("// Option types\n")
  for t in ["int64_t", "double", "bool", "iris_view_String"]:
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
    if s of ObjectDeclStmt or s of ErrorDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt or s of ConceptDeclStmt:
      g.genStmt(s); g.emit("\n")

  # Pre-emit Seq/array types referenced in function signatures
  for s in stmts:
    if s of FnDeclStmt:
      let f = FnDeclStmt(s)
      if f.returnType != nil:
        let rt = g.typeToCStr(f.returnType)
        if rt.isSeqType(): g.ensureSeqType(seqElemType(rt))
        if rt.isArrayType(): g.ensureArrayType(arrayElemType(rt), arraySize(rt))
        if rt.isHashTableType(): g.ensureHashTableType(htKeyType(rt), htValType(rt))
        if rt.isHashSetType(): g.ensureHashSetType(hsElemType(rt))
      for p in f.params:
        let pt = g.typeToCStr(p.typeAnn)
        if pt.isSeqType(): g.ensureSeqType(seqElemType(pt))
        if pt.isArrayType(): g.ensureArrayType(arrayElemType(pt), arraySize(pt))
        if pt.isHashTableType(): g.ensureHashTableType(htKeyType(pt), htValType(pt))
        if pt.isHashSetType(): g.ensureHashSetType(hsElemType(pt))
  if g.pendingSpecializations.len > 0:
    g.emit(g.pendingSpecializations)
    g.pendingSpecializations = ""

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
        g.fnParamTypes[f.name] = f.params.mapIt(g.typeToCStr(it.typeAnn))
      else:
        let ret = if f.returnType != nil: g.typeToCStr(f.returnType) else: "void"
        g.emit(ret & " " & f.name & "(" & g.formatParams(f.params) & ");\n")
        g.fnReturnTypes[f.name] = ret
        g.fnParamTypes[f.name] = f.params.mapIt(g.typeToCStr(it.typeAnn))
  g.emit("\n")

  # Functions (non-generic)
  var topLevel: seq[Stmt]
  for s in stmts:
    if s of FnDeclStmt:
      g.genStmt(s); g.emit("\n")
    elif not (s of ObjectDeclStmt or s of ErrorDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt or s of ConceptDeclStmt):
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
    if s of ObjectDeclStmt or s of ErrorDeclStmt or s of EnumDeclStmt or s of TupleDeclStmt or s of ConceptDeclStmt:
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
