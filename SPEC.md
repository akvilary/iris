# Iris Language Specification

## Overview

Iris is a compiled systems programming language.
File extension: `.is`
Compiles to C (later C++, JavaScript).
Compiler is written in Rust (bootstrap), then self-hosting.

**Identity:** Nim-level metaprogramming and multi-target compilation,
with Rust-level memory safety. "Safe Nim."

## Syntax

- Case-sensitive language — `Red` and `red` are different identifiers
- Indentation-based blocks
- 2 spaces per indent level (enforced by `iris fmt`)
- No semicolons
- No curly braces for blocks
- Naming convention: pascalCase
- Explicit return values: `result` in functions only
- No mandatory `main` function — top-level code runs directly

## Entry Point

Top-level code executes directly, no `main` required:

```
# hello.is — just runs
*echo("hello world")

@x = 42
*echo(x)
```

For libraries — `when isMain:` to run code only when file is executed directly
(not when imported):

```
# myLib.is
@helper! func(@x int) ok int:
  result = x + 1

when isMain:
  *echo("testing myLib")
  *echo(helper(5))
```

## Loops

Only `while` and `for`. No `loop`. Named loops via `@name`.

A loop is a block — spawns are cancelled and memory is freed on exit.

```
# while
while condition:
  doSomething()

# for
for @item in collection:
  process(item)

for @i in 0..10:
  *echo(i)             # 0, 1, 2, ..., 10 (inclusive)

for @i in 0..<10:
  *echo(i)             # 0, 1, 2, ..., 9 (exclusive end)

# Named loops via @name — for break/continue targeting a specific loop
@outer while true:
  @inner for @item in myCollection:
    if item.id == 3:
      continue outer     # skip to next while iteration
    if item.id == 99:
      break outer        # exit while entirely
    if item.id < 0:
      continue inner     # skip to next for iteration
```

### Loops do not return values

Loops cannot be assigned to variables. To get a value from a loop,
declare a variable before and assign inside:

```
# Declare before, assign inside:
@input String
@loop while true:
  @line = readLine()
  if line:
    input = ->line
    break loop

# Search pattern — declare before loop:
@found Item
@search for @item in list:
  if item.id == targetId:
    found = item
    break search
else:
  found = defaultItem

# Spawns inside loop are cancelled on break:
@loop for @url in urls:
  spawn fetch(url)
  if timeout:
    break loop          # all spawns cancelled, memory freed
```

## Expressions vs Statements

The colon `:` distinguishes statements (blocks) from expressions (values).
No colon = expression, returns a value. Colon = statement, opens a block.

### if expression — value if condition else alternative

```
# Inline:
@x = "yes" if condition else "no"

# Chaining (no elif needed):
@grade = "A" if score > 90 else "B" if score > 80 else "C"

# Multiline — wrap in ():
@status = (
  "ok" if code == 200
  else "not found" if code == 404
  else "error"
)
```

### case expression — pattern matching as expression

```
# Inline:
@name = case color of red "Red" of green "Green" of blue "Blue"

# Multiline — wrap in ():
@name = (case color
  of red "Red"
  of green "Green"
  of blue "Blue")
```

### Statement forms (colons, blocks, no return value)

```
# if statement:
if condition:
  doSomething()
else:
  doOtherThing()

# case — case with blocks:
case color:
  of red:
    paintRed()
    logColor()
  of green:
    paintGreen()
```

`case` without colon is an expression. `case` with colon is a statement with blocks.
Both forms must be exhaustive (all variants or `else`).

## Truthiness

`if x` only works on `bool`, `Option[T]`, and result unions (`T else E`).
Other types require explicit comparison — compiler error otherwise.

```
# bool — standard:
if isReady:            # OK

# Option — true if some:
@a = some(42)
if a:
  *echo(->a)        # -> to extract value

# Result union — true if ok:
@cfg = readConfig("app.toml")
if cfg:
  start(->cfg)     # -> to extract value

# Other types — explicit comparison required:
if count > 0:          # OK
if not name.isEmpty:   # OK
# if count:            # ERROR: use explicit comparison
# if name:             # ERROR: use 'not name.isEmpty'
```

Falsy values: `false`, `none`, `error`. Everything else is true.
No automatic unwrapping — use `->x` to unwrap. Compiler verifies the value is checked first.

`else:` on expressions follows the same rule — enters else on none or error:

```
@data = fetch(url) else:
  defaultData()        # only if fetch returned none or error
```

## Variables

All declarations start with `@`. Immutable by default.

| Syntax | Meaning | Example |
|--------|---------|---------|
| `@name = value` | Immutable (runtime) | `@name = "Alice"` |
| `@name mut = value` | Mutable (runtime) | `@count mut = 0` |
| `@name const = value` | Constant (compile-time) | `@maxSize const = 1024` |

```
@pi const = 3.14159265             # compile-time, inlined
@maxRetries! const = 3             # compile-time, public

@user = getUser(id)                # runtime, cannot reassign
# user = otherUser                 # ERROR: immutable

@counter mut = 0                   # runtime, mutable
counter = counter + 1              # OK
```

### Assignment semantics

Assignment from an **rvalue** (literal, constructor, function call) creates ownership.
Assignment from an **lvalue** (another variable) creates a **reference**:

| Expression | What happens |
|------------|-------------|
| `@x = User()` | x owns the value (rvalue → ownership) |
| `@x = someFunc()` | x owns the result (rvalue → ownership) |
| `@x = 42` | x owns the value (literal → ownership) |
| `@y = x` | y is an immutable reference to x (lvalue → ref) |
| `@y mut = x` | y is a mutable reference to x (lvalue → mut ref) |
| `@y = mv x` | y takes ownership, x becomes invalid (move) |
| `@y mut = mv x` | y takes ownership (mutable), x becomes invalid (move) |
| `@y = x.copy()` | y owns a copy (rvalue → ownership) |

```
@user = User(name=~"Alice")    # ownership — rvalue
@ref = user                    # immutable reference to user
@mref mut = user               # mutable reference to user
@moved = mv user               # ownership transferred, user is now invalid
```

This is consistent with function parameters, where immutable reference is the default.

#### Borrowing rules

Either N immutable refs **or** 1 mutable ref — not both at the same time.
Same rule as Rust, but no lifetime annotations — compiler checks by scope.

| Rule | Example |
|------|---------|
| Multiple immutable refs OK | `@a = x; @b = x; @c = x` — all valid |
| One mutable ref, exclusive | `@m mut = x` — only if no other refs to x exist |
| Immutable refs block mut | `@a = x; @m mut = x` — **compile error** |
| Mut ref blocks other refs | `@m mut = x; @a = x` — **compile error** |
| Ref cannot outlive source | `@y = x` where x dies before y — compile error |
| Cannot return ref to local | `result = x` — error, use `result = mv x` |

```
@user = User(name=~"Alice")

# Multiple immutable refs — OK:
@a = user
@b = user

# Mutable ref — exclusive:
@user2 = User(name=~"Bob")
@m mut = user2                  # OK — sole reference
# @n = user2                    # ERROR: cannot borrow while mutable ref exists
# @k mut = user2                # ERROR: second mutable ref

# Move through mut ref — invalidates both:
@n = mv m                       # value moved: m and user2 both invalid
# *echo(m)                      # ERROR: used after move
# *echo(user2)                  # ERROR: used after move (moved through m)

# Direct move:
@user3 = User(name=~"Charlie")
@owned = mv user3               # OK — user3 is now invalid
# *echo(user3)                  # ERROR: used after move

# Ref cannot outlive source:
@outer User
if true:
  @inner = User(name=~"Temp")
  outer = inner                 # ERROR: inner dies at end of block
```

## Declarations

All named declarations use `@` prefix. `!` after the name means public.
This allows using reserved words as field/variant names.

```
@User! object:
  @name! String
  @age! int

@Admin! object of User:
  @for String            # reserved word — OK with @
  @type String           # reserved word — OK with @
  @data int

@Status! enum:
  @ok, @error, @pending  # reserved words — OK with @
```

Construction and access:
```
@u = User(name="Alice", age=30)
*echo(u.name)           # read field
```

Functions:
```
@add! func(@a int, @b int) ok int:
  result = a + b

@sum = add(a=10, b=20)
```

## Visibility

Public visibility via `!` after the name:

```
@helperFunc func(@x int) ok int:       # private
  result = x + 1

@processData! func(@x int) ok int:     # public
  result = helperFunc(x)

@Config! object:
  @host! String         # public field
  @port! int            # public field
  @secret String        # private field

@maxRetries! const = 3
```

## Module System

### Import — qualified access only

```
import net

# Must use module name:
@conn = net.connect("localhost", 8080)

# NOT allowed:
# connect("localhost", 8080)   <- compile error

# Multiple imports from same path:
import std/[strutils, sequtils, tables]

# Multiple separate imports:
import net
import json
```

### From import — explicit import of specific names

```
from net import connect, listen

# Now available directly:
@conn = connect("localhost", 8080)
if not conn:
  return
```

### From export — re-export from nested modules

```
# Re-export specific names:
from myLib.internal.parser export parseJson, parseXml

# Re-export entire module:
export myLib.internal.parser

# Users of myLib get access to parseJson
# without knowing the internal structure of myLib
```

## Functions

### Named Arguments

Arguments can be passed by name using `=`. Order doesn't matter for named arguments:

```
@createUser! func(@name String, @age int) ok User:
  result = User(name=name, age=age)

# Positional (by order):
@u = createUser("Alice", 30)

# Named (order doesn't matter):
@u = createUser(name="Alice", age=30)
@u = createUser(age=30, name="Alice")

# Mixed — positional first, then named:
@u = createUser("Alice", age=30)
```

### Declaration

```
# Pure function (no errors):
@funcName! func(@param1 Type1, @param2 Type2) ok ReturnType:
  ...

# Function with errors:
@funcName! func(@param1 Type1) ok ReturnType else Error1, Error2:
  ...
```

- `!` after name = public
- `ok T` — pure function, cannot return errors
- `ok T else E1, E2` — can return E1 or E2, compiler checks
- `->` to unwrap result — always explicit, no auto-unwrap
- `?` operator for error propagation
- Errors returned via `result = Error(...)` + `return` (no `raise` keyword)

### Return Values

`result` is a reserved word — cannot be used as a variable name.
Return value is set explicitly:

```
@add! func(@a int, @b int) ok int:
  result = a + b

@findUser! func(@id int) ok User else NotFoundError:
  @user = db.query(id)?
  result = mv user

# result can be set anywhere, including branches:
@classify! func(@n int) ok String:
  if n > 0:
    result = String("positive")
  elif n < 0:
    result = String("negative")
  else:
    result = String("zero")

# result can be set early and execution continues:
@process! func(@data Seq[byte]) ok int:
  result = 0
  for b in data:
    result = result + b.toInt()
  log("sum computed")    # runs after, result already set

# return — early exit (uses current result value):
@search! func(@list Seq[int], @target int) ok int:
  result = -1
  for i, val in list:
    if val == target:
      result = i
      return             # exit with current result
```

Compiler verifies that `result` is set on all execution paths.

#### `result` and ownership

`result` cannot hold a reference to a local variable — it must own the value.
Use `mv` to move a local variable into `result`, or assign an rvalue directly:

```
@makeNums func() ok List[int]:
  @nums mut = ~[1, 2, 3]
  nums.add(4)
  result = mv nums            # ownership moves to result, nums is now invalid
                              # nums is NOT freed — caller owns the data

@makeDirect func() ok List[int]:
  result = ~[1, 2, 3]        # rvalue — ownership, no intermediate

@process func() ok List[int]:
  @temp mut = ~[10, 20]
  @other mut = ~[30, 40]     # other is NOT moved to result
  result = mv temp            # temp moved to result
                              # other freed at scope end (not moved)

@broken func() ok User:
  @u = User(name=~"Alice")
  result = u                  # ERROR: cannot return reference to local variable
                              # use: result = mv u
```

At function exit:
- Moved variables — stack metadata (pointer, len, cap) destroyed as usual,
  but the **heap buffer is not freed** (caller owns it via `result`)
- Other local heap variables — **heap buffer freed**, stack metadata destroyed
- Stack-only variables — destroyed as usual

### Declaration without initialization

Variables can be declared without a value — assigned later:

```
@x int
@u User

# Compiler verifies assignment before first use on all paths:
if condition:
  x = 42
else:
  x = 0
*echo(x)            # OK — assigned on all paths

@y int
if condition:
  y = 1
*echo(y)            # ERROR: y may not be assigned (missing else)
```

No zero-initialization — uninitialized variables have no default value.
Works the same for primitives and objects (like Rust, unlike Nim/Go).

## Memory Model

Every variable lives until the end of its scope (function or block).
When the scope ends, the variable is destroyed. No GC, no reference counting.
The compiler verifies all of this automatically.

### Stack and Heap

**Rule: look at the type — know where data lives.** No surprises.

**Stack by default.** All primitives and objects are value types on the stack.
No `ref object` — only `object`. Like Rust, not like Go or Java.

**Heap only explicitly** — via `Pool`, `Heap[T]`, or heap-owning types (`String`, `List`, etc.).

#### Allocation table — every type, no exceptions

| Type | Where | Size | Notes |
|------|-------|------|-------|
| `int`, `int8`..`int64` | Stack | 1-8 bytes | Primitive |
| `uint`, `uint8`..`uint64` | Stack | 1-8 bytes | Primitive |
| `float`, `float32`, `float64` | Stack | 4-8 bytes | Primitive |
| `bool` | Stack | 1 byte | Primitive |
| `rune` | Stack | 4 bytes | Unicode code point |
| `natural` | Stack | 8 bytes | Non-negative integer |
| `str` | Stack | 16 bytes | Static string reference (`.rodata`) |
| `array[T, N]` | Stack | `N * sizeof(T)` | Fixed size, known at compile time |
| `Seq[T]` | Depends | Varies | Sequence — either `array[T, N]` (stack) or `List[T]` (heap) |
| `view[T]` | Stack | 16 bytes | Borrowed slice (pointer + length). Cannot be stored in fields or closures |
| Custom objects | Stack | Sum of fields | `@User object:` → stack |
| `String` | **Heap** | Unlimited | Owned heap buffer (ptr+len+cap=24 bytes on stack) |
| `List[T]` | **Heap** | Unlimited | Like Rust's `Vec<T>`. Metadata on stack |
| `HashTable[K,V]` | **Heap** | Unlimited | Like Rust's `HashMap`. Metadata on stack |
| `HashSet[T]` | **Heap** | Unlimited | Like Rust's `HashSet`. Metadata on stack |
| `Heap[T]` | **Heap** | Unlimited | Like Rust's `Box<T>`. Pointer (8 bytes) on stack |
| `Pool` allocations | **Heap** | Unlimited | `pool.alloc(...)` — explicit arena heap |

Heap types (`String`, `List`, `HashTable`, `HashSet`, `Heap[T]`) own their heap data
and free it when they go out of scope. The metadata (pointer, length, capacity)
lives on the stack — only the data is in heap. This is explicit:
**you choose a heap type, you know it allocates.**

```
# Stack — all data on stack, no heap allocation
@x int = 42                           # 8 bytes stack
@name = "Alice"                              # str: 16 bytes stack (pointer + length into .rodata)
@point = Point(x=10, y=20)           # sizeof(Point) stack
@arr array[int, 100] = [0: 100]      # 800 bytes stack

# Heap — explicit, you chose a heap type
@buf mut String = ~""                            # buffer in heap
@list mut List[int] = ~[]                      # buffer in heap
@map mut HashTable[str, int] = ~{"key": 1}       # buffer in heap
@ids HashSet[int] = ~{1, 2, 3}               # buffer in heap
@user Heap[User] = ~User(name=~"Andrey")      # object in heap

# Heap via Pool — explicit arena allocation
@pool = Pool()
@node = pool.alloc(HugeNode(...))     # data in pool's heap arena
```

#### `~` prefix — heap literal syntax

`~` before a literal or constructor = heap allocation. Unified syntax:

| Expression | Type | Where |
|------------|------|-------|
| `"hello"` | `str` | Stack — static reference to `.rodata` |
| `~"hello"` | `String` | Heap — owned string |
| `[1, 2, 3]` | `array[int, 3]` | Stack — fixed array |
| `~[1, 2, 3]` | `List[int]` | Heap — dynamic list |
| `~{"k": 1}` | `HashTable[str, int]` | Heap — hash table |
| `~{1, 2, 3}` | `HashSet[int]` | Heap — hash set |
| `User(...)` | `User` | Stack — object |
| `~User(...)` | `Heap[User]` | Heap — boxed object |

No `&` in the language. All function parameters are passed by reference
automatically — the compiler handles it (see Parameter passing).
No automatic escape analysis. Programmer decides where data lives.
Compiler never silently moves data from stack to heap.

### Parameter passing

All parameters are passed **by reference automatically**.
The compiler optimizes small types (int, bool, float) to registers.
No `&` in the language — the compiler handles it.

| Syntax | Meaning |
|--------|---------|
| `@param Type` | Immutable reference (default) |
| `@param mut Type` | Mutable reference |
| `@param mv Type` | Takes ownership (move) |

```
@length func(@s String) ok int:                # immutable ref (auto)
  result = s.len

@sort func(@list mut Seq[int]):      # mutable ref — can modify caller's data
  ...

@send func(@msg mv Message):          # takes ownership — caller can't use msg after
  channel.push(msg)
```

Same borrowing rules apply at call sites:
- Immutable params: multiple allowed simultaneously
- Mutable param: only one at a time, no other refs to that variable
- `mv` param: value moved, caller loses access

#### Variable assignment

Variable assignment follows the same rules as parameter passing:
- `@y = x` — immutable reference (like `@param Type`)
- `@y mut = x` — mutable reference (like `@param mut Type`)
- `@y = mv x` — takes ownership (immutable), x becomes invalid
- `@y mut = mv x` — takes ownership (mutable), x becomes invalid

`Heap[T]` auto-derefs to `T` — functions accepting `T` also accept
`Heap[T]` without any changes to the signature (see Heap[T] section).

#### Regular code — just write code, everything is automatic

```
@handle func(@request Request) ok Response else Error:
  @user = db.getUser(request.userId)?     # ownership — rvalue from func
  @posts = db.getPosts(user.id)?          # ownership — rvalue from func
  result = mv newResponse(user, posts)
# <- user, posts, everything destroyed automatically

@process func():
  @a = "hello"
  @b = "world"
  @long = longest(a, b)    # ref — tied to a and b (lifetime rule 3)
  *echo(long)                # OK — a, b, long same scope
# <- a, b destroyed (long is just a ref, no cleanup)
```

No lifetime annotations. No manual memory management.
Compiler tracks scopes and verifies borrows automatically.

#### Lifetime inference rules

No annotations needed. Compiler applies simple rules:

1. **Returns owned value** — no lifetime concern (90% of code)
2. **One borrow param, returns borrow** — result tied to that param
3. **Multiple borrow params, returns borrow** — result tied to ALL params (conservative)

```
# Rule 1 — owned return, no concern:
@length func(@s String) ok int:
  result = s.len

# Rule 2 — one borrow param, obvious:
@firstWord func(@s String) ok String:
  result = s.split(" ")[0]       # tied to s

# Rule 3 — multiple borrows, tied to all:
@longest func(@x String, @y String) ok String:
  result = x if x.len > y.len else y
  # compiler: result tied to both x AND y

@a = "hello"
@b = "world"
@long = longest(a, b)        # OK: a, b, long same scope
```

No function body analysis needed. Fast compilation. Separate module compilation.
May reject rare valid code — but never allows a bug.

### Heap[T] — single heap allocation

`Heap[T]` puts a single object on the heap. Like Rust's `Box<T>`.
Created with `~` prefix before a constructor. Freed at scope end.

```
# Stack — default
@user = User(name=~"Andrey", age=25)          # User on stack

# Heap — explicit ~
@user = ~User(name=~"Andrey", age=25)         # Heap[User], object on heap
*echo(user.name)                               # auto-deref, works like stack
```

Memory layout:

```
Heap[User] (8 bytes on stack):
┌──────────────┐
│   User*      │
│  (8 bytes)   │
└──────┬───────┘
       │
       ▼
  heap-allocated User (owned, freed at scope end)
```

Primary use case — **heterogeneous collections** (elements of different sizes
behind a uniform pointer):

```
@Drawable concept:
  @draw func(@self)

# Circle (8 bytes) and Rect (16 bytes) — different sizes.
# Heap[Drawable] is always 8 bytes (pointer), so List can store both:
@shapes List[Heap[Drawable]] = ~[~Circle(r=5), ~Rect(w=3, h=4)]

for @shape in shapes:
  shape.draw()                # auto-deref, calls correct draw()
```

`Heap[T]` auto-derefs to `T` (zero-cost).

#### Heap[T] and function parameters

`Heap[T]` auto-derefs to `T` in function parameters. No need to write
`Heap[T]` in function signatures — just use `T`:

| Parameter | Stack `T` | `Heap[T]` |
|-----------|-----------|-----------|
| `@x T` | immutable ref | auto-deref, immutable ref |
| `@x mut T` | mutable ref | auto-deref, mutable ref |
| `@x mv T` | move | ownership transfer, freed at scope end |

```
@greet func(@user User):
  *echo(user.name)

@stack = User(name=~"Alice", age=30)
@heap = ~User(name=~"Bob", age=25)

greet(stack)    # OK — ref to stack object
greet(heap)     # OK — auto-deref Heap[User] → User

@consume func(@user mv User):
  *echo(user.name)
# user freed at scope end (stack: destroyed, heap: free)

consume(stack)  # move stack value
consume(heap)   # ownership of heap transferred, freed at scope end
```

`Heap[T]` in type annotations is only needed for:
- **Variable annotation** (optional): `@user Heap[User] = ~User(...)`
- **Heterogeneous collections**: `List[Heap[Drawable]]`

#### Stack size warning

Compiler warns when a stack-allocated object exceeds **4 KB (4096 bytes)**:

```
warning: type HugeBuffer (12288 bytes) is large for stack allocation
  --> app.is:15
  hint: consider using Heap[HugeBuffer] via ~HugeBuffer(...)
```

Suppress with `![allowStack]` when stack allocation is intentional:

```
@buf = ![allowStack] HugeBuffer(size=100_000)
```

Configurable in `iris.toml`:

```toml
[warnings]
stackSizeLimit = 4096    # bytes, default
```

### Pool — heap allocation

Pool is the **only mechanism** for heap allocation (like Rust's `Box`,
but arena-based). Covers all heap use cases:

- **Large objects** — avoid large stack allocations
- **Recursive types** — self-referencing data needs known pointer size
- **Cyclic references** — A references B and B references A
- **Long-lived data** — data that must outlive the creating function

`Pool` is created with `Pool()`. All data allocated through a pool
is freed in O(1) when the pool goes out of scope.

```
# Large object — put in heap to avoid stack overflow:
@pool = Pool()
@buf = pool.alloc(HugeBuffer(size=1_000_000))
process(buf)
# <- pool goes out of scope, buf freed

# Recursive type — needs heap for known size:
@Node! object:
  @value! int
  @next! Pool       # child nodes allocated in same pool

# Cyclic references:
@buildDom func() ok String:
  @pool = Pool()
  @parent = pool.alloc(Element("div"))
  @child = pool.alloc(Element("span"))
  parent.addChild(child)    # parent -> child
  child.parent = parent      # child -> parent (cycle!)
  result = parent.render().clone()
# <- pool goes out of scope, all memory freed in O(1)

# Regular code — no pool needed:
@buildList func() ok String:
  @items mut = List[Item]()
  items.add(Item("first"))
  items.add(Item("second"))     # items owns the data, no cycles
  result = items.toString()
# <- items destroyed automatically
```

#### Pool rules

1. Cross-pool linking is forbidden — data from different pools cannot reference each other
2. Data from `pool.alloc` cannot outlive the pool (use `.clone()` if needed)
3. A function can accept multiple Pool parameters

Rationale: if two structures need to reference each other,
they are by definition part of the same graph and live in one pool.
If not — they are independent and live in separate pools.

```
# Create pool, build graph, use it, pass further
@pool = Pool()
@root = buildGraph(pool)
traverse(root)
printTree(root)
# <- pool goes out of scope, all memory freed

@buildGraph func(@pool Pool) ok Node:
  @a = pool.alloc(Node("A"))
  @b = pool.alloc(Node("B"))
  @c = pool.alloc(Node("C"))
  a.neighbors.add(b)
  b.neighbors.add(c)
  c.neighbors.add(a)   # cycle!
  result = mv a

@traverse func(@node Node):
  *echo(node.name)
  for child in node.children:
    traverse(child)

@printTree func(@node Node):
  *echo("Tree root: {node.name}")

# Two independent graphs — two separate pools
@userPool = Pool()
@users = buildUserGraph(userPool)
processUsers(users)

@rolePool = Pool()
@roles = buildRoleGraph(rolePool)
processRoles(roles)

# Multiple pools passed to one function
@mergeGraphs func(@src Pool, @dst Pool) ok Node:
  @srcRoot = buildGraph(src)
  @dstRoot = buildGraph(dst)
  # srcRoot and dstRoot cannot link to each other (cross-pool forbidden)
  # but we can clone data from one to another:
  @copy = srcRoot.clone()
  dst.alloc(copy)
  result = mv dstRoot
```

## Collections

### array[T, N] — fixed-size array

Stack-allocated, size known at compile time.

```
@nums = [1, 2, 3, 4, 5]               # array[int, 5]
@zeros array[int, 100] = [0: 100]     # fill syntax — 100 zeros
```

#### array properties

| Property | Type | Description |
|----------|------|-------------|
| `.len` | `int` | Number of elements (compile-time constant) |
| `.cap` | `int` | Same as `.len` for arrays |
| `[i]` | `T` | Element access by index |

### List[T] — dynamic heap array

Like Rust's `Vec<T>`. Created with `~[...]`. Metadata (pointer, length, capacity) on stack, data on heap.

```
@nums mut = ~[1, 2, 3]                # List[int]
nums.add(4)                            # append
@other mut List[int] = ~[10, 20, 30]  # explicit type
@filled mut List[int] = ~[0: 100]     # fill — 100 zeros
@reserved mut List[int] = ~[:100]     # empty, capacity 100
@empty mut = List[int]()              # empty list
```

#### List properties

| Property | Type | Description |
|----------|------|-------------|
| `.len` | `int` | Number of elements |
| `.cap` | `int` | Current capacity |
| `[i]` | `T` | Element access by index |

#### List methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `.add(val)` | `(T) → void` | Append element. Grows capacity 2x when full |
| `.insert(i, val)` | `(int, T) → void` | Insert at index, shift right. O(n) |
| `.remove(i)` | `(int) → void` | Remove at index, preserve order. O(n) |
| `.removeSwap(i)` | `(int) → void` | Remove at index, swap with last. O(1) |
| `.pop()` | `() → T` | Remove and return last element |
| `.contains(val)` | `(T) → bool` | True if element exists. O(n) |
| `.find(val)` | `(T) → int` | Index of element, or -1 if not found. O(n) |

### Seq[T] — sequence

Accepts both `array[T, N]` and `List[T]`. Use in function parameters to accept any sequence.

```
@sum func(@arr Seq[int]) ok int:
  result = 0
  for @x in arr:
    result = result + x

@fixed = [1, 2, 3]
@dynamic mut = ~[4, 5, 6]
sum(fixed)      # OK — array
sum(dynamic)    # OK — List
```

`Seq[T]` can be stored in object fields and captured in closures.

### view[T] — borrowed slice

Borrowed slice into a sequence (pointer + length). Like Rust's `&[T]`.
Created by slicing an array, List, or Seq.

```
@nums = [1, 2, 3, 4, 5]
@slice view[int] = nums[1..3]     # elements 1, 2, 3

@dynamic mut = ~[10, 20, 30, 40]
@part view[int] = dynamic[0..<2]  # elements 10, 20
```

**Restrictions** — borrowed reference, may dangle:
- Cannot be stored in object, error, or tuple fields
- Cannot be captured in closures
- Cannot outlive the source data

### String

Owned heap string. Created with `~"..."`. Metadata (pointer, length, capacity) on stack, data on heap.

```
@s = ~"hello"                          # String
@msg = ~"value: {x}"                   # String with interpolation
```

#### String properties

| Property | Type | Description |
|----------|------|-------------|
| `.len` | `int` | Number of bytes |
| `.data` | pointer | Raw data pointer (internal) |

`str` is the immutable stack string (points to `.rodata`). Use `String` for owned mutable strings.

### HashTable[K, V]

Hash map. Created with `~{key: value}`. Uses wyhash + linear probing, grows at 75% load.

```
@scores = ~{"alice": 100, "bob": 85}  # HashTable[str, int]
@empty = HashTable[str, int]()        # empty

*echo(scores["alice"])                 # 100
```

#### HashTable properties

| Property | Type | Description |
|----------|------|-------------|
| `.len` | `int` | Number of entries |

#### HashTable methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `.set(key, val)` | `(K, V) → void` | Insert or update entry |
| `.get(key)` | `(K) → V` | Get value by key |
| `.has(key)` | `(K) → bool` | True if key exists |
| `.remove(key)` | `(K) → void` | Remove entry |
| `.removeIf(key)` | `(K) → bool` | Remove if exists, return whether removed |

### HashSet[T]

Hash set. Created with `~{values}`. Same hash implementation as HashTable.

```
@ids = ~{1, 2, 3, 4}                  # HashSet[int]
@names = ~{"Alice", "Bob"}            # HashSet[str]
@empty = HashSet[int]()               # empty
```

#### HashSet properties

| Property | Type | Description |
|----------|------|-------------|
| `.len` | `int` | Number of elements |

#### HashSet methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `.add(val)` | `(T) → void` | Add element |
| `.has(val)` | `(T) → bool` | True if element exists |
| `.remove(val)` | `(T) → void` | Remove element |
| `.removeIf(val)` | `(T) → bool` | Remove if exists, return whether removed |

Compiler distinguishes by syntax: `~{k: v}` → HashTable, `~{v}` → HashSet.

### Tuples

Named and unnamed tuples for lightweight data grouping:

```
# Named tuple
@point = (x=10, y=20)
*echo(point.x)              # 10
*echo(point.y)              # 20

# Unnamed tuple
@pair = (10, 20)
*echo(pair.0)                # 10

# Tuple type
@Point tuple:
  @x int
  @y int

# or
@Point (@x int, @y int)

# Return multiple values without defining a separate type
@divide! func(@a int, @b int) ok (@quotient int, @remainder int):
  result = (quotient=a / b, remainder=a % b)

@r = divide(10, 3)
*echo(r.quotient)            # 3
*echo(r.remainder)           # 1

# Destructuring
(@q, @rem) = divide(10, 3)
*echo(q)                      # 3
```

## Numeric Types

```
int         # signed, platform size (64-bit on modern systems)
int8        # 8-bit signed
int16       # 16-bit signed
int32       # 32-bit signed
int64       # 64-bit signed
uint        # unsigned, platform size
uint8       # 8-bit unsigned (a.k.a. byte)
uint16      # 16-bit unsigned
uint32      # 32-bit unsigned
uint64      # 64-bit unsigned
float       # = float64 by default
float32     # 32-bit float
float64     # 64-bit float
byte        # alias for uint8
natural     # int restricted to >= 0, error on attempt to go negative
```

`natural` is a safe non-negative type. Unlike `uint`,
it does not wrap around on overflow — it raises an error:

```
@n mut natural = 10
n = n - 5                # OK, n = 5
n = n - 10               # ERROR: natural cannot be negative

# Ideal for indices, sizes, counters
@createBuffer! func(@size natural) ok Buffer:
  # size is guaranteed >= 0, no validation needed
  ...
```

### Option

No null/nil in Iris. `Option[T]` represents a value that may or may not exist.
Works with `?`, `case`, and `else` — same patterns as error handling.

```
# Creating
@a = some(42)            # Option[int] with value
@b = none(int)           # Option[int] without value

# Pattern matching
case a:
  of some: *echo(->a)           # 42
  of none: *echo("nothing")

# else — default value
@x = a else: 0           # 42 (has value)
@y = b else: 0           # 0 (no value — fallback)

# ? — propagate none (like ? for errors)
@findUser! func(@id int) ok Option[User]:
  @row = db.find(id)?   # if db.find returns none → function returns none
  result = some(User.from(row))

# Chaining with ?
@name = getUser(1)?.name  # none if user not found
```

## Rune

`rune` — a single Unicode code point. Literals use single quotes:

```
@ch rune = 'A'
@emoji rune = '🎉'
```

## Strings

Two string types — explicit about where data lives:

| Type | What | Size on stack | Mutability |
|------|------|---------------|------------|
| `str` | Static string reference (`.rodata`) | 16 bytes (64-bit) | Immutable |
| `String` | Owned heap buffer | 24 bytes (64-bit) | Mutable, growable |

- UTF-8 by default.
- No null-termination guarantee — length is always explicit.
- `str` — a **static reference**: `(const char* data, size_t len)`.
  Points only to string literals embedded in the binary (`.rodata`).
  Lives forever — safe to store in object fields. `"hello"` has type `str`.
  `str mut` is a compile error — `.rodata` is read-only, mutation is impossible.
- `String` — an **owned heap buffer**: `(char* data, size_t len, size_t cap)`.
  Growable, mutable. Use for dynamic text: file contents, network data,
  building strings. Freed automatically at scope end.
- Function parameters taking `String` accept both `str` and `String`.
- Concatenation: `str + str` → `String`, `String + str` → `String`.
- Interpolation: `"hello {name}"` — built into lexer, works everywhere.

#### Where each type can be used

| Type | Parameters | Local vars | Return values | Object fields | Closures |
|------|-----------|------------|---------------|---------------|----------|
| `str` | yes | yes | yes | **yes** | yes |
| `String` | yes | yes | yes | **yes** | yes |

#### Memory layout

```
str (16 bytes on 64-bit):
┌──────────────┬──────────────┐
│ const char*  │  size_t len  │
│   (8 bytes)  │   (8 bytes)  │
└──────┬───────┴──────────────┘
       │
       ▼
  .rodata in binary (lives forever)

String (24 bytes on 64-bit):
┌──────────────┬──────────────┬──────────────┐
│   char*      │  size_t len  │  size_t cap  │
│  (8 bytes)   │   (8 bytes)  │   (8 bytes)  │
└──────┬───────┴──────────────┴──────────────┘
       │
       ▼
  heap-allocated buffer (owned, freed at scope end)
```

#### Safety — borrow checker

The borrow checker guarantees references never outlive
the data they point to. No dangling pointers, no use-after-free:

```
# OK — literal lives forever, str type
@greet func() ok str:
  result = "hello"

# OK — result lifetime tied to parameter (rule 2)
@first_word func(@s String) ok String:
  result = s.split(" ")[0]

# OK — both params, result tied to both (rule 3)
@longest func(@x String, @y String) ok String:
  result = x if x.len > y.len else y

# COMPILE ERROR — returning reference to local
@bad func() ok String:
  @s String = ~"hello"
  result = s              # error: cannot return reference to local variable
                          # use: result = mv s
```

#### Creating strings

```
# str — static reference, zero allocation
@name = "Alice"                            # type: str
@greeting = "Hello, {name}!"              # type: str (interpolation)

# String — owned, heap-allocated
@owned = ~"hello"                          # ~"..." literal
@built = String("hello")                      # constructor from str (copies)
@msg = ~"Hello, {name}!"                   # ~"..." with interpolation

# str in object fields — zero-cost, no heap allocation
@Config object:
  @name str
  @version str

@cfg = Config(name="myapp", version="1.0")  # both point to .rodata
```

#### Usage

```
@greet func(@s String):                        # accepts both str and String
  *echo(s)

greet(name)                           # str auto-converts (zero-cost)
greet(buf)                            # String passed directly

# For large/dynamic text — use String (heap)
@buf mut String = String()
buf.append("part1")
buf.append("part2")

@big String = readFile("big.txt")    # heap, no size limit
```

String interpolation is processed at the **lexer level**, not as a macro.
`"hello {name}"` is transformed into `concat("hello ", $name)` before
any macro expansion. This guarantees interpolation works inside templates,
macros, and any other context.

## Type System

- Static typing
- Generics without explicit constraints (duck typing at instantiation, like Nim)
  - Compiler checks at call site, not at declaration
  - `iris check --api-compat` for checking breaking changes
- Pattern matching with exhaustiveness checking
- Concepts (compile-time duck typing with a name, like Nim)
- No null/nil — only `Option[T]`
- No class inheritance — composition only
- No implicit conversions — explicit `.into()` only
- Nominal typing (two types with identical fields ≠ same type)
- Structural typing via concepts

### Enum

Single `enum` keyword for both simple enumerations and algebraic types.
Compiler determines the kind based on whether variants carry data.

#### Simple enum (no data)

Supports iteration, `ord`, sets:

```
@Direction! enum:
  @north, @south, @east, @west

@d = Direction.north
*echo(d)                         # 0 (enum is always int)
*echo($d)                        # "north" ($ returns variant name)

# Iterate over all values
for @dir in Direction:
  *echo($dir)

# Sets
@dirs set[Direction] = {Direction.north, Direction.south}
if Direction.north in dirs:
  *echo("going north")

# Explicit numeric values
@Color! enum:
  @red = 0, @green = 1, @blue = 2

# String values — $ returns the string value instead of variant name
@HttpMethod! enum:
  @get = "GET"
  @post = "POST"
  @put = "PUT"
  @delete = "DELETE"

*echo(HttpMethod.get)            # 0 (int)
*echo($HttpMethod.get)           # "GET" ($ returns string value)

@LogLevel! enum:
  @debug = "DEBUG"
  @info = "INFO"
  @warn = "WARNING"
  @error = "ERROR"

*echo($LogLevel.warn)            # "WARNING"
```

`$` operator: returns the string value if defined, otherwise the variant name.
Enum value without `$` is always `int`.

#### Object variants (tagged union)

Enum for the tag, object with `case` for the data.
Two definitions — explicit and clear:

```
@ShapeKind! enum:
  @circle, @rect, @point

@Shape! object:
  case @kind ShapeKind:
    of circle:
      @radius float
    of rect:
      @w float
      @h float
    of point:
      discard

@area! func(@s Shape) ok float:
  result = (case s.kind
    of circle PI * s.radius * s.radius
    of rect s.w * s.h
    of point 0.0)
```

### case/of — pattern matching with blocks

Exhaustive by default. Compiler checks all cases are handled.

#### Enums — short member names

Inside `case`, use **member name only** — no full path needed:

```
@Color! enum:
  @red, @green, @blue

@c = Color.red

case c:
  of red:
    *echo("red!")
  of green:
    *echo("green!")
  of blue:
    *echo("blue!")
```

Partial match with `else`:

```
case c:
  of red: *echo("red!")
  else: discard            # covers green, blue
```

Without `else` and without all members → **compile error**:

```
case c:
  of red: *echo("red!")
  # ERROR: non-exhaustive — green, blue not handled
```

#### Union types — match on type

`case/of` works on union types. All types must be covered:

```
# Response from fetch is: Data else ServerError else NetworkError

@resp = fetch("http://api.com")
case resp:
  of ok:
    @data = ->resp
    *echo(data)
  of ServerError:
    *echo("server error")
  of NetworkError:
    *echo("network error")
```

Partial match with `else`:

```
case resp:
  of ok:
    @data = ->resp
  else:
    *echo("some error occurred")
```

#### Rules

- `case` must always be exhaustive (all cases or `else`)
- No `_:` wildcard — use `else:` instead
- `discard` to explicitly ignore: `else: discard`
- Enum members use short names (not `Color.red`, just `red`)
- Union types match on type name

### Concepts

Named set of requirements for a type. Purely compile-time, zero overhead.
No `impl` needed — if a type fits, it automatically satisfies the concept.

```
@Printable concept:
  @toString func(@self) ok String

@Comparable concept:
  @lessThan func(@self, @other Self) ok bool
  @equals func(@self, @other Self) ok bool

@Serializable concept:
  @toJson func(@self) ok String
  @fromJson func(@raw String) ok Self
```

Usage is **optional**, for documentation and better compiler errors:

```
# With concept — better error messages:
@sort func[T: Comparable](@list mut Seq[T]):
  ...
# error: type Socket does not satisfy concept Comparable
#   missing: @lessThan func(@self, @other Socket) ok bool

# Without concept — also works, duck typing at call site:
@sort func[T](@list mut Seq[T]):
  ...
# error: type Socket has no method 'lessThan'
#   called from sort() at main.is:10
```

A type automatically satisfies a concept if it has the required methods:

```
@User object:
  @name String
  @age int

@toString func(@self User) ok String:
  result = ~"{self.name}, {self.age}"

# User automatically satisfies Printable — has toString
# No impl, no registration needed
```

### Generics

```
@map func[T, U](@list Seq[T], @f func(T) ok U) ok List[U]:
  for @x in list:
    result.add(f(x))

# With concept constraint (optional):
@printAll func[T: Printable](@items Seq[T]):
  for @item in items:
    *echo(item.toString())
```

## Metaprogramming

One mechanism: `macro`. No separate `template` (unlike Nim).
Called with `*` prefix. Hygienic by default.

### Principles

- Written in Iris itself (not a separate language)
- One mechanism `macro` — no template/macro split
- Called with `*` prefix: `*myMacro(args)` — always clear it's a macro
- Hygienic by default — variables inside macro don't leak into caller's scope
- Debuggable: `iris expand` shows macro output
- Visibility via `!` (like everything else)
- Can generate types, functions, entire modules

### Two kinds of parameters

- **Typed** (`@param Type`) — evaluated, passed as value
- **Untyped** (`@param`) — passed as code (AST), expanded with `ast.expand()`

```
# Simple macro — typed params, value substitution
@log macro(@msg String):
  *echo("[LOG] ", msg)

*log("server started")
# → *echo("[LOG] ", "server started")

# Code macro — untyped param, AST expansion
@benchmark macro(@label String, @body):
  @start = clock()
  ast.expand(body)
  *echo(label, ": ", clock() - start)

*benchmark("sort"):
  sort(data)
# → @start = clock()
#   sort(data)
#   *echo("sort", ": ", clock() - start)
```

### Hygiene

Variables declared inside a macro are invisible to the caller:

```
@swap macro(@a, @b):
  @temp = a
  a = b
  b = temp

@temp = 100
*swap(x, y)
*echo(temp)         # 100 — not affected by macro's @temp
```

To explicitly export a variable into caller's scope — use `ast.export`:

```
@withTimer macro(@body):
  ast.export @elapsed int
  @start = clock()
  ast.expand(body)
  elapsed = clock() - start

*withTimer:
  heavyWork()
*echo(elapsed)      # available because of ast.export
```

### ast.quote — code generation with `<<expr>>`

`ast.quote` creates AST from a code template. `<<expr>>` inserts
(unquotes) a value as a **name** into the generated code.

Rule: `<<expr>>` only when substituting a **name** (type name, field name).
Iterating over AST objects uses normal `for` — no special syntax needed.

```
@getter macro(@field, @typ):
  ast.quote:
    @get_<<field.name>>! func(@some <<ast.nameOf(typ)>>) ok <<field.type>>:
      result = some.<<field.name>>.clone()
```

### AST manipulation

`ast` module for programmatic code inspection and generation:

| Function | What it does |
|----------|-------------|
| `ast.expand(code)` | Insert code parameter into output |
| `ast.export @name Type` | Export variable into caller's scope |
| `ast.quote:` | Create AST from code template |
| `ast.fieldsOf(type)` | All fields (common + variant), each has `.name`, `.type` |
| `ast.nameOf(node)` | Name of a node |
| `ast.typeOf(node)` | Type of a node |
| `ast.emit(node)` | Insert programmatically built AST |

`ast.fieldsOf` returns all fields including variant fields.
Compiler ensures safe access to variant fields at compile time.

### Full example — derive

Works with both regular objects and object variants:

```
@derive macro(@trait String, @body):
  ast.expand(body)

  if trait == "Eq":
    @name = ast.nameOf(body)
    @fields = ast.fieldsOf(body)

    ast.quote:
      @eq! func(@a <<name>>, @b <<name>>) ok bool:
        result = true
        for @f in fields:
          if a.<<f.name>> != b.<<f.name>>:
            result = false
            return

*derive("Eq"):
  @Point! object:
    @x int
    @y int
```

### DSL — domain-specific languages

```
@html macro(@body):
  # parse body AST and generate Element constructors
  ...

@page = *html:
  div(class="container"):
    h1: "Hello"
    p: "World"
```

### Bitwise operations

Bitwise ops use words (like Nim):

| Operation | Syntax | Example |
|-----------|--------|---------|
| Shift left | `shl` | `value shl 8` |
| Shift right | `shr` | `value shr 4` |
| Bitwise XOR | `xor` | `a xor b` |
| Bitwise AND | `and` | `data and 0xFF` (int context) |
| Bitwise OR | `or` | `READ or WRITE` (int context) |
| Bitwise NOT | `not` | `not mask` (int context) |

`and`/`or`/`not` work for both logical (bool) and bitwise (int) —
compiler distinguishes by type.

### Tooling

```
iris expand file.is          # show code after all macro expansions
iris expand --macro=html     # show what a specific macro generated
```

## Block — universal construct

`block` is a scoping and control flow construct. It does not return values.
Any indentation creates a scope — memory is freed on block exit.

### Unnamed blocks

```
# Simple scope — memory freed on exit:
block:
  @tmp = expensiveComputation()
  process(tmp)
# <- tmp freed here
```

### Named blocks and break

```
# Named block — early exit from complex logic:
@validate block:
  if not user.isActive:
    break validate
  if not user.hasPermission("admin"):
    break validate
  grantAccess(user)

# Named block — group related setup, bail on failure:
@setup block:
  @cfg = loadConfig()
  if not cfg:
    *echo("no config, using defaults")
    break setup
  @db = connect(->cfg.dbUrl)
  if not db:
    *echo("no db connection")
    break setup
  migrate(->db)
```

### Blocks do not return values

To get a value out of a block, declare a variable before and assign inside:

```
@count int
block:
  if users.isEmpty:
    count = 0
  else:
    count = users.len
```

### Thread Safety

Data races are impossible — prevented at compile time by the borrow checker.
If data is passed to a `spawn`, no other spawn can access it mutably.

```
@data mut = ~[1, 2, 3]

# OK — each spawn returns its own result:
@a = spawn fetch("url1")
@b = spawn fetch("url2")
if a and b:
  @buf = ~[->a, ->b]
```

| Problem | Prevented? | How |
|---------|-----------|-----|
| Data races | **Yes, compile-time** | Borrow checker forbids shared mutable state |
| Race conditions | Risk reduced | Channels, structured concurrency |
| Deadlocks | No | Same as all languages |

### Structured Concurrency

```
@workers block:
  spawn fetch("url1")
  spawn fetch("url2")
# <- all tasks guaranteed to be complete

# spawn is available via block handle
@pipeline block:
  @ch = channel[String](10)

  @urls_loop for @url in urls:
    @data = spawn fetch(url)
    if not data:
      break urls_loop
    ch.send(->data)

  for @_ in urls:
    @recv block:
      @val = spawn ch.receive()
      if val:
        process(->val)
        break recv
```

### Nested blocks for pipeline

```
@pipeline block:
  @raw = channel[bytes](100)
  @parsed = channel[Record](100)

  @producers block:
    for @url in urls:
      spawn raw.send(fetch(url))

  @consumers block:
    for @_ in urls:
      @data = spawn raw.recv()
      if data:
        parsed.send(parse(->data))
  # producers done -> consumers done -> pipeline done
```

### detach — for long-lived tasks (outside block)

`detach` is the opposite of `block`. Launches a task that lives independently of the current scope.

```
# For daemons/servers — explicit unstructured spawn (rare)
@server = detach:
  listen(8080)
# execution continues, server runs in background
server.cancel()       # explicit stop
```

### Channels

Channels transfer ownership — sender loses access, no shared mutable state.
Primitive types (int, float, bool) are copied. Complex types are moved.

No unbounded channels — always explicit size to prevent memory leaks.
`send` blocks when buffer is full. `receive` blocks when buffer is empty.

```
# Buffered — blocks send when full:
@ch = channel[int](10)

# Unbuffered — blocks send until someone calls receive:
@ch = channel[int](0)

# Explicit receive:
@val = ch.receive()      # blocks until value available

# Ownership transfer — sender loses access:
@ch = channel[List[int]](1)
@data mut = ~[1, 2, 3]
ch.send(data)           # data MOVED into channel
# *echo(data)            # ERROR: data was moved

# To send and keep — explicit clone:
ch.send(data.clone())   # send a copy
*echo(data)              # OK — original still available
```

### Concurrency patterns via block

`block` with `spawn` covers all concurrency patterns — no special keywords needed.

```
# Wait for all (like doAll) — block waits for every spawn:
block:
  spawn: loadUsers()
  spawn: loadPosts()
  spawn: loadConfig()
# <- all three complete

# First to complete wins (like doOne/select) — break on success:
@race block:
  spawn:
    @val = ch1.receive()
    if val:
      process(->val)
      break race
  spawn:
    @val = ch2.receive()
    if val:
      process(->val)
      break race
  spawn:
    after(5.sec)
    *echo("Timeout!")
    break race
```

### No Colored Functions (no async/await)

In languages with async/await, functions are split into two worlds — sync and async.
Async "infects" the entire call chain: one async function forces all callers
to also be async. This is known as the "colored functions" problem.

Iris has **no async/await**. All functions are the same:

```
# Regular function. IO inside — but syntax is the same.
@fetch func(@url String) ok bytes else NetError:
  @resp = http.get(url)?
  result = resp.body()

# Calling — just a call, no await:
@process func() ok void else NetError:
  @data = fetch("https://api.example.com")?
  *echo(->data)
```

Concurrency is achieved via `block spawn`, not async/await:

```
# Sequential — regular call:
@a = fetch("url1")?
@b = fetch("url2")?

# Parallel — block spawn:
@a mut bytes
@b mut bytes
@w block:
  spawn: a = fetch("url1")?
  spawn: b = fetch("url2")?
# <- both complete, a and b available
```

Each `spawn` body is compiled as a separate function and executed in a thread pool
(number of threads = number of CPU cores). Thousands of spawns can be queued.
Blocking IO inside spawn blocks only that pool thread, not the program.

### Zero-cost when unused

The concurrency runtime (thread pool, futures, channels) is **not linked** into
programs that don't use it. The compiler detects presence of `spawn` or `detach`
in the AST during codegen:

- **No `spawn`/`detach`** → pure C output, no runtime, no pthreads, minimal binary
- **Has `spawn`/`detach`** → codegen emits `#include "iris_runtime.h"` and links
  the runtime automatically (thread pool init/shutdown in main, futures for detach)

The programmer never opts in manually — the compiler decides based on what the code
actually uses. A hello-world stays a tiny static binary; a concurrent server gets
the runtime it needs.

## Error Handling

Return type is the success type, errors listed after `else`:
`ok T else Error1, Error2`. All possible errors must be listed.
Errors are returned via `result = Error(...)` — same mechanism as success values.
No `raise` keyword — one unified `result` mechanism for both paths.
No automatic unwrapping — use `->x` to unwrap. Compiler verifies the value is checked first.

### Declaring errors

Error types use the `error` keyword (not `object`). This tells the compiler
the type is an error — falsy in conditions, assignable to `result`, usable with `case`.

```
# Simple errors
@DivError! error:
  @message String

@IoError! error:
  @path String
  @message String

@ParseError! error:
  @line int
  @message String
```

Grouped errors use enum variants (no inheritance — consistent with
"no class inheritance, composition only"):

```
@HttpErrorKind! enum:
  @notFound, @serverError, @timeout

@HttpError! error:
  @message String
  case @kind HttpErrorKind:
    of notFound:
      @path String
    of serverError:
      @code int
    of timeout:
      discard
```

Only types declared with `error` can be used after `else` in function
signatures and assigned to `result`. Assigning a regular `object` to
`result` in an error-returning function is a compile error.

### Returning errors (function author)

Errors are returned via the same `result` mechanism as success values.
The compiler distinguishes by type — `error` types vs regular values:

```
@divide! func(@a int, @b int) ok int else DivError:
  if b == 0:
    result = DivError(message=~"division by zero")
    return                 # early exit with error
  result = a / b           # compiler wraps in ok

@readConfig! func(@path String) ok Config else IoError, ParseError:
  @raw = fs.read(path)?              # ? propagates IoError up
  @parsed = json.parse(raw)?         # ? propagates ParseError up
  result = Config.from(parsed)       # compiler wraps in ok
```

Compiler checks:
- `result = DivError(...)` — `DivError` is in signature → OK
- `result = SomeOther(...)` — not in signature → **compile error**
- `?` propagates errors from callee — must be compatible with signature
- Function without errors → pure, assigning error type to `result` is compile error

### Handling errors (caller side)

Three levels — from shortest to most detailed:

#### 1. `?` — propagate up

Caller must include compatible error types in its own signature:

```
@loadApp! func() ok App else IoError, ParseError:
  @cfg = readConfig("app.toml")?     # IoError | ParseError propagated
  result = newApp(->cfg)
```

#### 2. `if`/`else` — handle inline

Assign result, then check with `if`:

```
# Handle error
@conn = connect("localhost", 8080)
if not conn:
  *echo("connection failed")
  quit()
@c = ->conn           # explicit unwrap — always required

# Fallback value
@cfg = readConfig("app.toml")
if not cfg:
  @cfg = Config.default()
```

#### 3. `case` — pattern match on all cases

```
@response = fetch("http://api.com/data")
case response:
  of ok:
    @data = ->response
    *echo(data)
  of ServerError:
    *echo("server error")
  of NetworkError:
    *echo("network error")
  else:
    db.close()
```

### Summary

| Syntax | What it does |
|--------|-------------|
| `result = Error(...)` | Return an error from function |
| `?` | Propagate error to caller |
| `->x` | Unwrap Option/Result value — compiler verifies checked first |
| `if`/`else` | Check result, handle error inline |
| `case` | Pattern match on `ok` and specific error types |

## Tooling (built into compiler)

- `iris build` — build (+ cross-compilation `--target=...`)
- `iris fmt` — mandatory formatter
- `iris test` — run tests
- `iris run file.is` — run
- `iris deps` — dependency manager
- `iris check --api-compat` — API compatibility check
- `iris expand file.is` — show code after macro expansion
- `iris expand --macro=name` — show output of a specific macro
- LSP — developed in parallel with the compiler

## Compilation Targets

- C (primary, first)
- C++ (later)
- TypeScript (later)

## Roadmap

See [ROADMAP.md](ROADMAP.md)
