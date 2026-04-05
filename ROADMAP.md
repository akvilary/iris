# Iris Roadmap

### Phase 1 — MVP Compiler

Minimal compiler that can compile basic Iris programs to C.

- [x] Lexer (tokenization, string interpolation)
- [x] Parser (indentation-based, AST construction)
- [x] Basic types: int, float, bool, rune
- [x] Variables: @x, @x mut, @x const
- [x] Functions: func, result, return
- [x] Control flow: if/elif/else, while, for, break, continue
- [x] Ranges: `..` and `..<`
- [x] Labels: @label while/for/block
- [x] C code generation
- [x] `iris build` and `iris run`
- [x] Module system: import, from import, import path/[a, b]

### Phase 2 — Type System

- [x] Custom types with `@` attributes
- [x] Enum (simple)
- [x] Object variants (tagged union)
- [x] Option[T]: some, none
- [x] Result: ok T else Error (if/else, case, .get())
- [x] case/of with exhaustiveness checking
- [x] Tuples (named + unnamed, block + inline)
- [x] Generics (duck typing at instantiation, monomorphization)
- [x] Concepts (optional named constraints, compile-time validation)
- [x] `$` operator for string conversion (partial)
- [x] Destructuring (positional, named, nested, modifiers, _ skip)

### Phase 3 — Memory Safety

- [x] Semantic analyzer (between parser and codegen)
- [x] Reject view[T] in object/error/tuple fields
- [x] Assigned-before-use check (no zero-init)
- [x] Lambdas without capture (func as argument, no environment)
- [x] Closures with capture (heap environment struct, by reference)
- [x] Reject view[T] in closure captures
- [x] Ownership + borrow checker (immutable borrow, mut, mv)
- [x] Lifetime inference (3 rules, no annotations)
- [ ] Pool for cyclic references
- [x] Compile-time verification of borrows
- [x] Compile-time variant field access checks

### Phase 4 — Collections + Strings

- [x] array[T, N] (stack, struct-wrapped, fill syntax)
- [x] List[T] (heap): literal, fill, capacity, add, remove, removeSwap, pop, insert, contains, find
- [x] Seq[T] (sequence: array on stack or List on heap)
- [x] HashTable[K,V] (wyhash, linear probing, backward-shift deletion)
- [x] HashSet[T] (same algorithm, separate implementation)
- [x] view[T] (immutable view, pointer + length)
- [x] Str (heap): ~"..." literal, Str() constructor, ~"...{expr}..." interpolation
- [x] for-in iteration over array, Seq, List
- [x] Index assignment: list[i], ht[key]

### Phase 5 — Concurrency

- [ ] block (structured concurrency scope)
- [ ] spawn (thread pool, function call syntax — parsed, not yet in codegen)
- [ ] channel[T] (buffered, unbuffered)
- [ ] Thread safety (borrow checker prevents data races)
- [ ] detach (long-lived tasks)
- [ ] Zero-cost: no runtime linked when unused

### Phase 6 — Error Handling

- [x] `ok T else E` syntax in signatures
- [ ] `?` operator (parsed, codegen not yet propagating errors)
- [x] `result = Error(...)` (error return via result)
- [x] `quit()` / `quit(error)`
- [x] Compile-time check: raise matches signature

### Phase 7 — Metaprogramming

- [ ] Macros (`*name()` call syntax)
- [x] `<<expr>>` unquote syntax (changed from `^expr^`)
- [ ] ast.expand, ast.export, ast.fieldsOf
- [x] *echo as built-in macro
- [ ] DSL support
- [ ] `iris expand` for debugging

### Phase 8 — Standard Library

- [x] std/time (Duration, constants: Nanosecond..Hour)
- [x] Stdlib import support, C cache in ~/.cache/iris/
- [ ] std/io (file, stdin/stdout)
- [ ] std/net (TCP, HTTP)
- [ ] std/os (env, args, path)
- [ ] std/math
- [ ] std/json

### Phase 9 — Tooling

- [ ] `iris fmt` (mandatory formatter, 2-space indent)
- [ ] `iris test` (test runner)
- [ ] `iris deps` (dependency manager)
- [ ] `iris check --api-compat` (breaking change detection)
- [ ] LSP (language server protocol)
- [x] LSP-ready tokens (SemanticKind, len, comments preserved)

### Phase 10 — Additional Targets

- [ ] C++ code generation
- [ ] TypeScript code generation

### Phase 11 — Self-hosting

- [ ] Rewrite compiler in Iris
- [ ] Bootstrap: Iris compiler compiles itself
