# Iris Language Specification

## Overview

Iris is a compiled systems programming language.
File extension: `.is`
Compiles to C (later C++, JavaScript).
Compiler is written in Rust (bootstrap), then self-hosting.

**Identity:** Nim-level metaprogramming and multi-target compilation,
with Rust-level memory safety. "Safe Nim."

## Syntax

- Indentation-based blocks
- 2 spaces per indent level (enforced by `iris fmt`)
- No semicolons
- No curly braces for blocks
- Naming convention: pascalCase
- Explicit return values: `result` in functions and blocks (belongs to nearest scope)
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
@helper+ func(@x int) -> int:
  result = x + 1

when isMain:
  *echo("testing myLib")
  *echo(helper(5))
```

## Loops

Only `while` and `for`. No `loop`. Named loops via `label.

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

### Loop as expression

Loops can return values via `result`. If the loop may complete without
`break`, an `else` clause is required by the compiler:

```
# while true — always breaks, result always set:
@input = @loop while true:
  @line = readLine()
    case line:
      Ok:
        result = line
        break loop
    else:
      continue

# for — may complete without break, else required:
@found = @search for @item in list:
  if item.matches(query):
    result = item
    break search
else:
  result = defaultItem

# Spawns inside loop are cancelled on break:
@loop for @url in urls:
  spawn: fetch(url)
  if timeout:
    break loop          # all spawns cancelled, memory freed
```

## Expressions

`if`/`elif`/`else` and `case` are expressions — they return values:

```
# Inline if:
@x = if condition: "yes" else: "no"

# Multiline if:
@status = if code == 200:
  "ok"
elif code == 404:
  "not found"
else:
  "error"

# case as expression:
@name = case color:
  of Color.red: "Red"
  of Color.green: "Green"
  of Color.blue: "Blue"
```

## Truthiness

`if x` only works on `bool`, `Option[T]`, and result unions (`T | !E`).
Other types require explicit comparison — compiler error otherwise.

```
# bool — standard:
if isReady:            # OK

# Option — true if some:
@a = some(42)
if a:
  *echo(a.get())        # .get() to extract value

# Result union — true if ok:
@cfg = readConfig("app.toml")
if cfg:
  start(cfg.get())     # .get() to extract value

# Other types — explicit comparison required:
if count > 0:          # OK
if not name.isEmpty:   # OK
# if count:            # ERROR: use explicit comparison
# if name:             # ERROR: use 'not name.isEmpty'
```

Falsy values: `false`, `none`, `error`. Everything else is true.
No automatic unwrapping — use `.get()` to extract the value.

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
@maxRetries+ const = 3             # compile-time, public

@user = getUser(id)                # runtime, cannot reassign
# user = otherUser                 # ERROR: immutable

@counter mut = 0                   # runtime, mutable
counter = counter + 1              # OK
```

## Declarations

All named declarations use `@` prefix. `+` after the name means public.
This allows using reserved words as field/variant names.

```
@User+ object:
  @name+ string
  @age+ int

@Admin+ object of User:
  @for str            # reserved word — OK with @
  @type str           # reserved word — OK with @
  @data int

@Status+ enum:
  @ok, @error, @pending  # reserved words — OK with @
```

Construction and access:
```
@u = User(name="Alice", age=30)
*echo(u.name)           # read field
```

Functions:
```
@add+ func(@a int, @b int) -> int:
  result = a + b

@sum = add(a=10, b=20)
```

## Visibility

Public visibility via `+` after the name:

```
@helperFunc func(@x int) -> int:       # private
  result = x + 1

@processData+ func(@x int) -> int:     # public
  result = helperFunc(x)

@Config+ object:
  @host+ string         # public field
  @port+ int            # public field
  @secret str        # private field

@maxRetries+ const = 3
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
do @conn = connect("localhost", 8080) else:
  quit(conn.getError())
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
@createUser+ func(@name str, @age int) -> User:
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
@funcName+ func(@param1 Type1, @param2 Type2) -> Ok[ReturnType]:
  ...
```

- `+` after name = public
- Functions return `Ok[T]` for success, error types for failure
- `.get()` to unwrap `Ok[T]` — always explicit, no auto-unwrap
- `?` operator for error propagation
- `raise` to return an error

### Return Values

`result` is a reserved word — cannot be used as a variable name.
Return value is set explicitly:

```
@add+ func(@a int, @b int) -> int:
  result = a + b

@findUser+ func(@id int) -> User | !NotFoundError:
  @user = db.query(id)?
  result = user

# result can be set anywhere, including branches:
@classify+ func(@n int) -> str:
  if n > 0:
    result = "positive"
  elif n < 0:
    result = "negative"
  else:
    result = "zero"

# result can be set early and execution continues:
@process+ func(@data slice[byte]) -> int:
  result = 0
  for b in data:
    result = result + b.toInt()
  log("sum computed")    # runs after, result already set

# return — early exit (uses current result value):
@search+ func(@list slice[int], @target int) -> int:
  result = -1
  for i, val in list:
    if val == target:
      result = i
      return             # exit with current result
```

Compiler verifies that `result` is set on all execution paths.

## Memory Model

Every variable lives until the end of its scope (function or block).
When the scope ends, the variable is destroyed. No GC, no reference counting.
The compiler verifies all of this automatically.

### Stack and Heap

**Rule: look at the type — know where data lives.** No surprises.

**Stack by default.** All primitives and objects are value types on the stack.
No `ref object` — only `object`. Like Rust, not like Go or Java.

**Heap only explicitly** — via `Pool` or heap-owning types (`String`, `Seq`, etc.).

#### Allocation table — every type, no exceptions

| Type | Where | Size | Notes |
|------|-------|------|-------|
| `int`, `int8`..`int64` | Stack | 1-8 bytes | Primitive |
| `uint`, `uint8`..`uint64` | Stack | 1-8 bytes | Primitive |
| `float`, `float32`, `float64` | Stack | 4-8 bytes | Primitive |
| `bool` | Stack | 1 byte | Primitive |
| `rune` | Stack | 4 bytes | Unicode code point |
| `natural` | Stack | 8 bytes | Non-negative integer |
| `str` | Stack | Max 256 bytes | Immutable, compiler optimizes known sizes |
| `array[T, N]` | Stack | `N * sizeof(T)` | Fixed size, known at compile time |
| Custom objects | Stack | Sum of fields | `@User object:` → stack |
| `String` | **Heap** | Unlimited | Mutable, growable. Metadata (ptr+len+cap) on stack |
| `Seq[T]` | **Heap** | Unlimited | Like Rust's `Vec<T>`. Metadata on stack |
| `HashTable[K,V]` | **Heap** | Unlimited | Like Rust's `HashMap`. Metadata on stack |
| `HashSet[T]` | **Heap** | Unlimited | Like Rust's `HashSet`. Metadata on stack |
| `Pool` allocations | **Heap** | Unlimited | `pool.alloc(...)` — explicit arena heap |

Heap types (`String`, `Seq`, `HashTable`, `HashSet`) own their heap buffer
and free it when they go out of scope. The metadata (pointer, length, capacity)
lives on the stack — only the buffer is in heap. This is explicit:
**you choose a heap type, you know it allocates.**

```
# Stack — all data on stack, no heap allocation
@x int = 42                           # 8 bytes stack
@name str = "Alice"                   # 6 bytes stack (optimized)
@point = Point(x=10, y=20)           # sizeof(Point) stack
@arr array[int, 100] = [0; 100]      # 800 bytes stack

# Heap — explicit, you chose a heap type
@buf mut String = String.new()        # buffer in heap
@list mut Seq[int] = Seq[int].new()   # buffer in heap
@map mut HashTable[str, int] = {}     # buffer in heap

# Heap via Pool — explicit arena allocation
@pool = newPool()
@node = pool.alloc(HugeNode(...))     # data in pool's heap arena
```

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
| `@param own Type` | Takes ownership (move) |

```
@length func(@s str) -> int:          # immutable ref (auto)
  result = s.len

@sort func(@list mut slice[int]):     # mutable ref — can modify caller's data
  ...

@send func(@msg own Message):         # takes ownership — caller can't use msg after
  channel.push(msg)
```

The borrow checker ensures:
- Immutable refs: multiple allowed simultaneously
- Mutable ref: only one at a time, no other refs
- Ownership: value moved, caller loses access

#### Regular code — just write code, everything is automatic

```
@handle func(@request Request) -> Response | !Error:
  @user = db.getUser(request.userId)?
  @posts = db.getPosts(user.id)?
  result = newResponse(user, posts)
# <- user, posts, everything destroyed automatically

@process func():
  @a = "hello"
  @b = "world"
  @long = longest(a, b)    # compiler knows: a, b, long same scope
  *echo(long)                # OK
# <- a, b, long destroyed
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
@length func(@s str) -> int:
  result = s.len

# Rule 2 — one borrow param, obvious:
@firstWord func(@s str) -> str:
  result = s.split(" ")[0]       # tied to s

# Rule 3 — multiple borrows, tied to all:
@longest func(@x str, @y str) -> str:
  result = if x.len > y.len: x else: y
  # compiler: result tied to both x AND y

@a = "hello"
@b = "world"
@long = longest(a, b)        # OK: a, b, long same scope
```

No function body analysis needed. Fast compilation. Separate module compilation.
May reject rare valid code — but never allows a bug.

### Pool — heap allocation

Pool is the **only mechanism** for heap allocation (like Rust's `Box`,
but arena-based). Covers all heap use cases:

- **Large objects** — avoid large stack allocations
- **Recursive types** — self-referencing data needs known pointer size
- **Cyclic references** — A references B and B references A
- **Long-lived data** — data that must outlive the creating function

`Pool` is created with `newPool()`. All data allocated through a pool
is freed in O(1) when the pool goes out of scope.

```
# Large object — put in heap to avoid stack overflow:
@pool = newPool()
@buf = pool.alloc(HugeBuffer(size=1_000_000))
process(buf)
# <- pool goes out of scope, buf freed

# Recursive type — needs heap for known size:
@Node+ object:
  @value+ int
  @next+ Pool       # child nodes allocated in same pool

# Cyclic references:
@buildDom func() -> str:
  @pool = newPool()
  @parent = pool.alloc(Element("div"))
  @child = pool.alloc(Element("span"))
  parent.addChild(child)    # parent -> child
  child.parent = parent      # child -> parent (cycle!)
  result = parent.render().clone()
# <- pool goes out of scope, all memory freed in O(1)

# Regular code — no pool needed:
@buildList func() -> str:
  @items mut = newSeq[Item]()
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
@pool = newPool()
@root = buildGraph(pool)
traverse(root)
printTree(root)
# <- pool goes out of scope, all memory freed

@buildGraph func(@pool Pool) -> Node:
  @a = pool.alloc(Node("A"))
  @b = pool.alloc(Node("B"))
  @c = pool.alloc(Node("C"))
  a.neighbors.add(b)
  b.neighbors.add(c)
  c.neighbors.add(a)   # cycle!
  result = a

@traverse func(@node Node):
  *echo(node.name)
  for child in node.children:
    traverse(child)

@printTree func(@node Node):
  *echo("Tree root: {node.name}")

# Two independent graphs — two separate pools
@userPool = newPool()
@users = buildUserGraph(userPool)
processUsers(users)

@rolePool = newPool()
@roles = buildRoleGraph(rolePool)
processRoles(roles)

# Multiple pools passed to one function
@mergeGraphs func(@src Pool, @dst Pool) -> Node:
  @srcRoot = buildGraph(src)
  @dstRoot = buildGraph(dst)
  # srcRoot and dstRoot cannot link to each other (cross-pool forbidden)
  # but we can clone data from one to another:
  @copy = srcRoot.clone()
  dst.alloc(copy)
  result = dstRoot
```

## Collections

### Arrays, Sequences, Slices

| Syntax | What | Storage | Size |
|--------|------|---------|------|
| `array[int, 5]` | Fixed-size array | Stack (inline) | Known at compile-time |
| `Seq[int]` | Dynamic sequence | Heap | Grows at runtime |
| `slice[int]` | View/slice (parameters only) | Reference to existing data | Pointer + length |

```
# Fixed array — stack
@fixed: array[int, 5] = [1, 2, 3, 4, 5]

# Dynamic sequence — heap, created with ~[...]
@dynamic mut = ~[1, 2, 3]
dynamic.add(4)

# Explicit type annotation also works
@other mut Seq[int] = ~[10, 20, 30]

# Empty Seq
@empty mut = Seq[int]()

# Slice — accepts both array and Seq
@sum func(@arr slice[int]) -> int:
  result = 0
  for @x in arr:
    result = result + x

sum(fixed)      # OK — slice into stack array
sum(dynamic)    # OK — slice into Seq
```

### HashTable

Inline hash table literal with `{key: value}`:

```
# Create hash table:
@headers = {"Content-Type": "json", "Authorization": "Bearer xxx"}

# Type: HashTable[string, string]
@scores: HashTable[string, int] = {"alice": 100, "bob": 85}

# Access:
*echo(headers["Content-Type"])

# Empty:
@empty = HashTable[string, int]()
```

### HashSet

Inline hash set literal with `{values}`:

```
@ids = {1, 2, 3, 4}
# Type: HashSet[int]

@names = {"Alice", "Bob", "Charlie"}
# names of HashSet[string]

if 2 in ids:
  *echo("found")

# Empty:
@empty = HashSet[int]()
```

Compiler distinguishes by syntax: `{k: v}` → HashTable, `{v}` → HashSet.

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
@divide+ func(@a int, @b int) -> (@quotient int, @remainder int):
  result = (quotient=a / b, remainder=a % b)

@r = divide(10, 3)
*echo(r.quotient)            # 3
*echo(r.remainder)           # 1

# or
@divide+ func[
  (@a int, @b int),
  (int, int)
]:
  result = (a / b, a % b)


@divide+ func[
  (
    @a int,
    @b int,
  ),
  (
    int,
    int,
  )
]:
  result = (a / b, a % b)


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
@createBuffer+ func(@size natural) -> Buffer:
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
  of some: *echo(a.get())           # 42
  of none: *echo("nothing")

# else — default value
@x = a else: 0           # 42 (has value)
@y = b else: 0           # 0 (no value — fallback)

# ? — propagate none (like ? for errors)
@findUser+ func(@id int) -> Option[User]:
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

| Type | Where | Max size | Mutability | Rust analogy |
|------|-------|----------|------------|--------------|
| `str` | Stack | 256 bytes | Immutable | Fixed `[u8; 256]` |
| `String` | Heap | Unlimited | Mutable, growable | `String` |

- UTF-8 by default
- `str` — stack-allocated, immutable, max 256 bytes. No SSO, no hidden heap.
  Literal too long → compile error. Runtime overflow → runtime error.
- `String` — heap-allocated, growable, mutable buffer.
  Use for large/dynamic text: file contents, network data, building strings.
- Interpolation: `"hello {name}"` — built into lexer, works everywhere.

#### `str` stack optimization

Since `str` is immutable, the compiler optimizes stack allocation
when the size is known at compile time:

| Situation | Stack size |
|-----------|-----------|
| `@x str = "Hi"` | 3 bytes (compiler knows length) |
| `@x str = if c: "a" else: "bb"` | 3 bytes (max of branches) |
| `@x str = runtimeFunc()` | 256 bytes (max, length unknown) |
| `func(@s str)` parameter | Passed by reference automatically (8 bytes) |

The 256-byte max is a **type guarantee**, not always the actual allocation.
The compiler allocates only what is needed when the value is known.

```
@name str = "Alice"                   # stack, 6 bytes (optimized)
@greeting str = "Hello, {name}!"     # stack, compiler computes size

@greet func(@s str):                  # passed by reference (auto), 8 bytes
  *echo(s)

# For large/dynamic text — use String (heap)
@buf mut String = String.new()
buf.append("part1")
buf.append("part2")
@result str = buf.toStr()            # copy to stack str (must fit 256 bytes)

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
@Direction+ enum:
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
@Color+ enum:
  @red = 0, @green = 1, @blue = 2

# String values — $ returns the string value instead of variant name
@HttpMethod+ enum:
  @get = "GET"
  @post = "POST"
  @put = "PUT"
  @delete = "DELETE"

*echo(HttpMethod.get)            # 0 (int)
*echo($HttpMethod.get)           # "GET" ($ returns string value)

@LogLevel+ enum:
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
@ShapeKind+ enum:
  @circle, @rect, @point

@Shape+ object:
  case @kind ShapeKind:
    of circle:
      @radius float
    of rect:
      @w float
      @h float
    of point:
      discard

@area+ func(@s Shape) -> float:
  result = case s.kind:
    of circle: PI * s.radius * s.radius
    of rect: s.w * s.h
    of point: 0.0
```

### case/of — pattern matching

Exhaustive by default. Compiler checks all cases are handled.

#### Enums — short member names

Inside `case`, use **member name only** — no full path needed:

```
@Color+ enum:
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
@Response = Ok[Data] | ServerError | NetworkError

@resp = fetch("http://api.com")
case resp:
  of Ok:
    @data = resp.get()
    *echo(data)
  of ServerError:
    *echo("server error")
  of NetworkError:
    *echo("network error")
```

Partial match with `else`:

```
case resp:
  of Ok:
    @data = resp.get()
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
  @toString func(@self) -> str

@Comparable concept:
  @lessThan func(@self, @other Self) -> bool
  @equals func(@self, @other Self) -> bool

@Serializable concept:
  @toJson func(@self) -> str
  @fromJson func(@raw str) -> Self
```

Usage is **optional**, for documentation and better compiler errors:

```
# With concept — better error messages:
@sort func[T: Comparable](@list mut slice[T]):
  ...
# error: type Socket does not satisfy concept Comparable
#   missing: @lessThan func(@self, @other Socket) -> bool

# Without concept — also works, duck typing at call site:
@sort func[T](@list mut slice[T]):
  ...
# error: type Socket has no method 'lessThan'
#   called from sort() at main.is:10
```

A type automatically satisfies a concept if it has the required methods:

```
@User object:
  @name str
  @age int

@toString func(@self User) -> str:
  result = "{self.name}, {self.age}"

# User automatically satisfies Printable — has toString
# No impl, no registration needed
```

### Generics

```
@map func[T, U](@list slice[T], @f func(T) -> U) -> Seq[U]:
  result = [f(x) for x in list]

# With concept constraint (optional):
@printAll func[T: Printable](@items slice[T]):
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
- Visibility via `+` (like everything else)
- Can generate types, functions, entire modules

### Two kinds of parameters

- **Typed** (`@param Type`) — evaluated, passed as value
- **Untyped** (`@param`) — passed as code (AST), expanded with `ast.expand()`

```
# Simple macro — typed params, value substitution
@log macro(@msg str):
  *echo("[LOG] ", msg)

*log("server started")
# → *echo("[LOG] ", "server started")

# Code macro — untyped param, AST expansion
@benchmark macro(@label str, @body):
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

### ast.quote — code generation with `^expr^`

`ast.quote` creates AST from a code template. `^expr^` inserts
(unquotes) a value as a **name** into the generated code.

Rule: `^expr^` only when substituting a **name** (type name, field name).
Iterating over AST objects uses normal `for` — no `^^ ` needed.

```
@getter macro(@field, @typ):
  ast.quote:
    @get_^field.name^+ func(@self ^ast.nameOf(typ)^) -> ^field.type^:
      result = self.^field.name^
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
@derive macro(@trait str, @body):
  ast.expand(body)

  if trait == "Eq":
    @name = ast.nameOf(body)
    @fields = ast.fieldsOf(body)

    ast.quote:
      @eq+ func(@a ^name^, @b ^name^) -> bool:
        result = true
        for @f in fields:
          if a.^f.name^ != b.^f.name^:
            result = false
            return

*derive("Eq"):
  @Point+ object:
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

Bitwise ops use words (like Nim), freeing `^` for macros:

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

`block` is the single building block for control flow, concurrency, scoping, and values.
Behavior is determined by contents, not by different keywords.

### Control Flow — named blocks and break

```
# Exit from nested loops
*block `search:
  for item in list1:
    for item2 in list2:
      if item == item2:
        break `search         # exit both loops
  *echo("not found")

# Nested named blocks
*block `outer:
  for i in 0..100:
    block `inner:
      if i == 50:
        break `outer          # exit everything
      if i % 2 == 0:
        break `inner          # skip this block
      process(i)
```

### Block as expression (returns a value)

```
@count = block `b:
  if users.isEmpty:
    result = 0
    break `b
  result = users.len

# Or simpler:
@status = block `b:
  result = if isReady: "ok" else: "waiting"
```

### Thread Safety

Data races are impossible — prevented at compile time by the borrow checker.
If data is passed to a `spawn`, no other spawn can access it mutably.

```
@data mut = ~[1, 2, 3]

# COMPILE ERROR — two spawns cannot mutate the same data:
block:
  spawn:
    data.add(4)          # ERROR: mutable borrow conflict
  spawn:
    data.add(5)          # ERROR: data already borrowed

# OK — communicate via channels instead of shared memory:
@ch = channel[int](2)
block:
  spawn:
    ch.send(4)
  spawn:
    ch.send(5)

# OK — each spawn gets its own data:
block:
  spawn:
    @local mut = ~[1, 2]
    local.add(3)
  spawn:
    @local mut = ~[4, 5]
    local.add(6)
```

| Problem | Prevented? | How |
|---------|-----------|-----|
| Data races | **Yes, compile-time** | Borrow checker forbids shared mutable state |
| Race conditions | Risk reduced | Channels, structured concurrency |
| Deadlocks | No | Same as all languages |

### Structured Concurrency

```
@workers block:
  spawn: fetch("url1")
  spawn: fetch("url2")
# <- all tasks guaranteed to be complete

# spawn is available via block handle
@pipeline block:
  @ch = channel[str](10)

  @urls_loop for @url in urls:
    spawn:
      do @data = fetch(url) else:
        break urls_loop
      ch.send(data)

  for @_ in urls:
    @recv block:
      spawn:
        @val = ch.receive()
        if val:
          process(val.get())
          break recv
      spawn:
        after(10.sec)
        break pipeline       # timeout — exit everything
```

### Nested blocks for pipeline

```
@pipeline block:
  @raw = channel[bytes](100)
  @parsed = channel[Record](100)

  @producers block:
    for @url in urls:
      spawn:
        raw.send(fetch(url))

  @consumers block:
    for @_ in urls:
      spawn:
        @data = raw.recv()
        parsed.send(parse(data))
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
@ch = channel[Seq[int]](1)
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
      process(val.get())
      break race
  spawn:
    @val = ch2.receive()
    if val:
      process(val.get())
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
@fetch func(@url str) -> Ok[bytes]:
  @resp = http.get(url)?
  result = Ok(resp.body())

# Calling — just a call, no await:
@process func() -> Ok[void]:
  @data = fetch("https://api.example.com")?
  *echo(data)
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
No runtime needed — just C code with pthreads under the hood.

## Error Handling

Functions return `Ok[T]` for success or a specific error type.
No automatic unwrapping — always use `.get()` to extract the value.

### Returning errors (function author)

```
@readConfig+ func(@path str) -> Ok[Config]:
  @raw = fs.read(path)?              # ? propagates error up
  @parsed = json.parse(raw)?         # ? propagates error up
  result = Ok(Config.from(parsed))

@divide+ func(@a int, @b int) -> Ok[int]:
  if b == 0:
    raise MathError.divByZero        # returns error, exits function
  result = Ok(a / b)
```

- `?` — propagates the error to the caller
- `raise` — explicitly returns an error and exits the function

### Handling errors (caller side)

Three levels — from shortest to most detailed:

#### 1. `?` — propagate up

```
@loadApp+ func() -> Ok[App]:
  @cfg = readConfig("app.toml")?     # error propagated to caller
  result = Ok(newApp(cfg.get()))
```

#### 2. `do...else` — handle inline

`do` executes and checks for `Ok`. If not `Ok` — runs the `else` block.
No automatic unwrap — always use `.get()` explicitly.

```
# Handle error
do @conn = connect("localhost", 8080) else:
  *echo(conn)              # conn is the error value itself
  quit()
@c = conn.get()           # explicit unwrap — always required

# Log and continue
do @cfg = readConfig("app.toml") else:
  *echo("Config failed: ", cfg)

# Fallback value
do @cfg = readConfig("app.toml") else:
  @cfg = Ok(Config.default())

# One-liner
do @conn = connect("localhost", 8080) else: quit()
```

#### 3. `case` — pattern match on all cases

```
@response = fetch("http://api.com/data")
case response:
  of Ok:
    @data = response.get()
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
| `?` | Propagate error to caller |
| `.get()` | Explicit unwrap of `Ok[T]` — always required |
| `do @x = f() else:` | Check for `Ok`, handle error inline |
| `case` | Pattern match on `Ok` and specific error types |
| `raise` | Return an error from function |

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
- JavaScript (later)

## Roadmap

### Phase 1 — MVP Compiler

Minimal compiler that can compile basic Iris programs to C.

- [ ] Lexer (tokenization, string interpolation)
- [ ] Parser (indentation-based, AST construction)
- [ ] Basic types: int, float, bool, string, byte, rune
- [ ] Variables: const, let, var
- [ ] Functions: fn, result, return
- [ ] Control flow: if/elif/else, while, for, break, continue
- [ ] Ranges: `..` and `..<`
- [ ] Labels: `` `label ``
- [ ] C code generation
- [ ] `iris build` and `iris run`

### Phase 2 — Type System

- [ ] Custom types with `@` attributes
- [ ] Enum (simple + with data)
- [ ] Option[T]: some, none
- [ ] Result unions: `T | !E`
- [ ] case/of with exhaustiveness checking
- [ ] Tuples (named + unnamed, destructuring)
- [ ] Generics (duck typing at instantiation)
- [ ] Concepts (optional named constraints)
- [ ] `$` operator for string conversion

### Phase 3 — Memory Safety

- [ ] Ownership + borrow checker (immutable borrow, var, own, own var)
- [ ] Lifetime inference (3 rules, no annotations)
- [ ] Pool for cyclic references
- [ ] Compile-time verification of borrows

### Phase 4 — Collections + Strings

- [ ] array[T, N] (stack)
- [ ] Seq[T] (heap), `~[...]` literal
- [ ] slice[T] (view)
- [ ] string (immutable, SSO, interpolation in lexer)
- [ ] String (mutable builder)

### Phase 5 — Concurrency

- [ ] block (control flow, expressions, scoping)
- [ ] spawn (thread pool)
- [ ] channel[T] (buffered, unbuffered)
- [ ] Thread safety (borrow checker prevents data races)
- [ ] detach (long-lived tasks)

### Phase 6 — Error Handling

- [ ] `T | !E` syntax everywhere (signatures, params, aliases)
- [ ] `?` operator (propagation + unwrap)
- [ ] `else:` (fallback + unwrap)
- [ ] `raise` (explicit error return)
- [ ] `quit()` / `quit(error)`

### Phase 7 — Metaprogramming

- [ ] Templates (inline substitution)
- [ ] Macros (untyped AST transformation)
- [ ] DSL support
- [ ] `iris expand` for debugging

### Phase 8 — Tooling

- [ ] `iris fmt` (mandatory formatter, 2-space indent)
- [ ] `iris test` (test runner)
- [ ] `iris deps` (dependency manager)
- [ ] `iris check --api-compat` (breaking change detection)
- [ ] LSP (language server protocol)

### Phase 9 — Additional Targets

- [ ] C++ code generation
- [ ] JavaScript code generation

### Phase 10 — Self-hosting

- [ ] Rewrite compiler in Iris
- [ ] Bootstrap: Iris compiler compiles itself
