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
- [x] Result: ok T else Error (do..else, case, raise, .get())
- [x] case/of with exhaustiveness checking
- [x] Tuples (named + unnamed, block + inline)
- [ ] Generics (duck typing at instantiation)
- [ ] Concepts (optional named constraints)
- [x] `$` operator for string conversion (partial)
- [ ] Destructuring

### Phase 3 — Memory Safety

- [ ] Semantic analyzer (between parser and codegen)
- [ ] Reject view[T] in object fields and closure captures
- [ ] Ownership + borrow checker (immutable borrow, mut, own)
- [ ] Lifetime inference (3 rules, no annotations)
- [ ] Pool for cyclic references
- [ ] Compile-time verification of borrows
- [x] Compile-time variant field access checks

### Phase 4 — Collections + Strings

- [ ] array[T, N] (stack)
- [ ] Seq[T] (heap), `~[...]` literal
- [x] view[T] (immutable view, pointer + length)
- [ ] Str (heap, mutable builder)

### Phase 5 — Concurrency

- [ ] block (control flow, expressions, scoping)
- [ ] spawn (thread pool)
- [ ] channel[T] (buffered, unbuffered)
- [ ] Thread safety (borrow checker prevents data races)
- [ ] detach (long-lived tasks)

### Phase 6 — Error Handling

- [x] `ok T else E` syntax in signatures
- [ ] `?` operator (proper codegen)
- [x] `do...else` (error handling)
- [x] `raise` (explicit error return)
- [x] `quit()` / `quit(error)`
- [x] Compile-time check: raise matches signature

### Phase 7 — Metaprogramming

- [ ] Macros (`*name()` call syntax)
- [ ] `^expr^` unquote in ast.quote
- [ ] ast.expand, ast.export, ast.fieldsOf
- [x] *echo as built-in macro
- [ ] DSL support
- [ ] `iris expand` for debugging

### Phase 8 — Tooling

- [ ] `iris fmt` (mandatory formatter, 2-space indent)
- [ ] `iris test` (test runner)
- [ ] `iris deps` (dependency manager)
- [ ] `iris check --api-compat` (breaking change detection)
- [ ] LSP (language server protocol)
- [x] LSP-ready tokens (SemanticKind, len, comments preserved)

### Phase 9 — Additional Targets

- [ ] C++ code generation
- [ ] JavaScript code generation

### Phase 10 — Self-hosting

- [ ] Rewrite compiler in Iris
- [ ] Bootstrap: Iris compiler compiles itself
