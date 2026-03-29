# Questions for discussion

Design decisions I made while working autonomously. Need your input.

## 1. Rust compiler — keep or remove?

The Nim compiler (`nim_src/`) is working and passes all 4 examples.
The Rust compiler (`src/`) is outdated (still has `echo()` not `*echo()`).

Options:
- a) Remove `src/` entirely, Nim is the compiler now
- b) Keep `src/` as reference, mark as deprecated
- c) Keep both in sync (lots of work)

## 2. `*echo()` in SPEC.md

I updated all `.is` examples to use `*echo()`, but SPEC.md still has many
`echo()` without `*` prefix. Should I do a full pass to update all spec
examples to `*echo()`?

## 3. case/of codegen for short names

Currently the C codegen resolves `of red:` → `case Color_red:` by looking
up the enum type of the case expression. This works for simple cases but
will need more work for:
- Union types (matching on type, not enum variant)
- Nested patterns
- Destructuring in patterns

## 4. `do...else` codegen

Currently generates a simple `if (!name)` check. Real implementation needs:
- Result/Ok type checking
- Proper error value extraction
- Works but is a placeholder

## 5. `iris_str` struct — max size

Current: `{ uint8_t len; char data[255]; }` = 256 bytes.
`len` is uint8 → max 255 chars. `data[len]` is always `'\0'`.

Should we increase? Or is 255 enough? (We discussed 256 bytes total,
this gives 255 chars + null terminator.)

## 6. Module system (import with [])

Specced: `import std/[strutils, sequtils]`
Not yet implemented in parser/codegen. Low priority but noted.

## 7. SPEC.md has mixed old/new syntax

Some sections (Loops, Collections, Concurrency, etc.) still use old syntax
(`let`, `var`, `fn`, `echo()` without `*`). Should be updated.
