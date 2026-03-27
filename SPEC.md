# Iris Language Specification

## Overview

Iris is a compiled systems programming language.
File extension: `.is`
Compiles to C (later C++, JavaScript).
Compiler is written in Rust (bootstrap), then self-hosting.

**Identity:** Nim-level metaprogramming and multi-target compilation,
with Rust-level memory safety. "Safe Nim."

## Syntax

- Indentation-based blocks (like Nim/Python)
- 2 spaces per indent level (enforced by `iris fmt`)
- No semicolons
- No curly braces for blocks
- Naming convention: pascalCase
- Explicit return values: `result` in functions, `handle.result` in blocks
- No mandatory `main` function — top-level code runs directly

## Entry Point

Top-level code executes directly, no `main` required:

```
# hello.is — just runs
echo("hello world")

let x = 42
echo($x)
```

For libraries — `when isMain:` to run code only when file is executed directly
(not when imported):

```
# myLib.is
fn helper*(x: int) -> int:
  result = x + 1

when isMain:
  echo("testing myLib")
  echo(helper(5))
```

## Loops

Only `while` and `for`. No `loop`. Named loops via `as`:

```
# while
while condition:
  doSomething()

# for
for item in collection:
  process(item)

for i in 0..10:
  echo(i)             # 0, 1, 2, ..., 10 (inclusive)

for i in 0..<10:
  echo(i)             # 0, 1, 2, ..., 9 (exclusive end)

# Named loops via as — for break/continue targeting a specific loop
while true as outer:
  for item in myCollection as inner:
    if item.id == 3:
      continue outer     # skip to next while iteration
    if item.id == 99:
      break outer        # exit while entirely
    if item.id < 0:
      continue inner     # skip to next for iteration
```

## Expressions

`if`/`elif`/`else` and `match` are expressions — they return values:

```
# Inline if:
let x = if condition: "yes" else: "no"

# Multiline if:
let status = if code == 200:
  "ok"
elif code == 404:
  "not found"
else:
  "error"

# match as expression:
let name = match color:
  Color.red: "Red"
  Color.green: "Green"
  Color.blue: "Blue"
```

## Truthiness

`if x` only works on `bool`, `Option[T]`, and `Result[T, E]`.
Other types require explicit comparison — compiler error otherwise.

```
# bool — standard:
if isReady:            # OK

# Option — true if some:
let a = some(42)
if a:
  echo(a.get())        # .get() to extract value

# Result — true if ok:
let cfg = readConfig("app.toml")
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
let data = fetch(url) else:
  defaultData()        # only if fetch returned none or error
```

## Variables

| Keyword | Meaning | Example |
|---------|---------|---------|
| `const` | Evaluated at compile-time | `const maxSize = 1024` |
| `let` | Immutable variable (runtime) | `let name = "Alice"` |
| `var` | Mutable variable (runtime) | `var count = 0` |

```
const pi = 3.14159265              # compile-time, inlined
const maxRetries* = 3              # compile-time, public

let user = getUser(id)             # runtime, cannot reassign
# user = otherUser                 # ERROR: let cannot be reassigned

var counter = 0                    # runtime, mutable
counter = counter + 1              # OK
```

## Visibility

Public visibility via `*` after the name (like Nim):

```
fn helperFunc(x: int) -> int:        # private
  x + 1

fn processData*(x: int) -> int:      # public
  helperFunc(x)

type Config*:
  host*: string        # public field
  port*: int           # public field
  secret: string       # private field

type Shape*:
  Circle(radius: float)
  Rect(w: float, h: float)

concept Drawable*:
  fn draw(self)

const maxRetries* = 3
```

## Module System

### Import — qualified access only

```
import net

# Must use module name:
let conn = net.connect("localhost", 8080)

# NOT allowed:
# connect("localhost", 8080)   <- compile error
```

### From import — explicit import of specific names

```
from net import connect, listen

# Now available directly:
let conn = connect("localhost", 8080)
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

```
fn funcName*(param1: Type1, param2: Type2) -> ReturnType | !ErrorType:
  ...
```

- `*` after name = public
- `| !ErrorType` = function can return an error (expands to Result)
- Multiple error types: `-> ReturnType | !ErrA | !ErrB`
- `?` operator for error propagation

### Return Values

`result` is a reserved word — cannot be used as a variable name.
Return value is set explicitly:

```
fn add*(a: int, b: int) -> int:
  result = a + b

fn findUser*(id: int) -> User | !NotFoundError:
  let user = db.query(id)?
  result = user

# result can be set anywhere, including branches:
fn classify*(n: int) -> string:
  if n > 0:
    result = "positive"
  elif n < 0:
    result = "negative"
  else:
    result = "zero"

# result can be set early and execution continues:
fn process*(data: slice[byte]) -> int:
  result = 0
  for b in data:
    result = result + b.toInt()
  log("sum computed")    # runs after, result already set

# return — early exit (uses current result value):
fn search*(list: slice[int], target: int) -> int:
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

**When to use `Pool`:** only when you have cyclic references
(A references B and B references A). Everything else is automatic.

### Ownership + Borrow Checker

Default is immutable borrow. Annotations for other modes:

| Annotation | Meaning | Rust equivalent |
|------------|---------|-----------------|
| *(none)* | Immutable borrow | `&T` |
| `var` | Mutable borrow | `&mut T` |
| `own` | Take ownership (immutable) | `T` |
| `own var` | Take ownership + mutable | `mut T` |

```
fn length(s: string) -> int:             # immutable borrow (default)
  s.len

fn sort(var list: slice[int]):           # mutable borrow
  ...

fn send(own msg: Message):              # take ownership
  channel.push(msg)

fn normalize(own var data: slice[byte]) -> slice[byte]:  # own + mutate
  data.trim()
  data
```

#### Regular code — just write code, everything is automatic

```
fn handle(request: Request) -> Response | !Error:
  let user = db.getUser(request.userId)?
  let posts = db.getPosts(user.id)?
  result = newResponse(user, posts)
# <- user, posts, everything destroyed automatically

fn process():
  let a = "hello"
  let b = "world"
  let long = longest(a, b)    # compiler knows: a, b, long same scope
  echo(long)                   # OK
# <- a, b, long destroyed
```

No lifetime annotations. No manual memory management.
Compiler tracks scopes and verifies borrows automatically.

### Cyclic References (Pool)

The only case where you need explicit memory management:
**A references B and B references A.** The borrow checker cannot handle
cycles — use `Pool` to put cyclic data in a memory region.

`Pool` is a regular object created with `newPool()`. Freed automatically
when it goes out of scope. All allocated data freed in O(1).

```
# Cyclic references — need Pool:
fn buildDom() -> string:
  let pool = newPool()
  let parent = pool.alloc(Element("div"))
  let child = pool.alloc(Element("span"))
  parent.addChild(child)    # parent -> child
  child.parent = parent      # child -> parent (cycle!)
  result = parent.render().clone()
# <- pool goes out of scope, all memory freed in O(1)

# NOT cyclic — no pool needed, just regular code:
fn buildList() -> string:
  let items = newSeq[Item]()
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
let pool = newPool()
let root = buildGraph(pool)
traverse(root)
printTree(root)
# <- pool goes out of scope, all memory freed

fn buildGraph(pool: Pool) -> Node:
  let a = pool.alloc(Node("A"))
  let b = pool.alloc(Node("B"))
  let c = pool.alloc(Node("C"))
  a.neighbors.add(b)
  b.neighbors.add(c)
  c.neighbors.add(a)   # cycle!
  result = a

fn traverse(node: Node):
  echo($node.name)
  for child in node.children:
    traverse(child)

fn printTree(node: Node):
  echo("Tree root: {node.name}")

# Two independent graphs — two separate pools
let userPool = newPool()
let users = buildUserGraph(userPool)
processUsers(users)

let rolePool = newPool()
let roles = buildRoleGraph(rolePool)
processRoles(roles)

# Multiple pools passed to one function
fn mergeGraphs(src: Pool, dst: Pool) -> Node:
  let srcRoot = buildGraph(src)
  let dstRoot = buildGraph(dst)
  # srcRoot and dstRoot cannot link to each other (cross-pool forbidden)
  # but we can clone data from one to another:
  let copy = srcRoot.clone()
  dst.alloc(copy)
  result = dstRoot
```

## Collections

### Arrays, Sequences, Slices

| Syntax | What | Storage | Size |
|--------|------|---------|------|
| `array[int, 5]` | Fixed-size array | Stack (inline) | Known at compile-time |
| `seq[int]` | Dynamic sequence | Heap | Grows at runtime |
| `slice[int]` | View/slice (parameters only) | Reference to existing data | Pointer + length |

```
# Fixed array — stack
let fixed: array[int, 5] = [1, 2, 3, 4, 5]

# Dynamic sequence — heap, created with @[...]
var dynamic = @[1, 2, 3]
dynamic.add(4)

# Explicit type annotation also works
var other: seq[int] = @[10, 20, 30]

# Empty seq
var empty = seq[int]()

# Slice — accepts both array and seq
fn sum(arr: slice[int]) -> int:
  result = 0
  for x in arr:
    result = result + x

sum(fixed)      # OK — slice into stack array
sum(dynamic)    # OK — slice into seq
```

### Tuples

Named and unnamed tuples for lightweight data grouping:

```
# Named tuple
let point = (x: 10, y: 20)
echo(point.x)              # 10
echo(point.y)              # 20

# Unnamed tuple
let pair = (10, 20)
echo(pair.0)                # 10

# Tuple type
type Point = tuple[x: int, y: int]

# Return multiple values without defining a separate type
fn divide*(a: int, b: int) -> (quotient: int, remainder: int):
  result = (quotient: a / b, remainder: a % b)

let r = divide(10, 3)
echo(r.quotient)            # 3
echo(r.remainder)           # 1

# Destructuring
let (q, rem) = divide(10, 3)
echo(q)                      # 3
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
var n: natural = 10
n = n - 5                # OK, n = 5
n = n - 10               # ERROR: natural cannot be negative

# Ideal for indices, sizes, counters
fn createBuffer*(size: natural) -> Buffer:
  # size is guaranteed >= 0, no validation needed
  ...
```

### Option

No null/nil in Iris. `Option[T]` represents a value that may or may not exist.
Works with `?`, `match`, and `else` — same patterns as error handling.

```
# Creating
let a = some(42)            # Option[int] with value
let b = none(int)           # Option[int] without value

# Pattern matching
match a as val:
  some: echo(val)               # 42
  none: echo("nothing")

# else — default value
let x = a else: 0           # 42 (has value)
let y = b else: 0           # 0 (no value — fallback)

# ? — propagate none (like ? for errors)
fn findUser*(id: int) -> Option[User]:
  let row = db.find(id)?   # if db.find returns none → function returns none
  result = some(User.from(row))

# Chaining with ?
let name = getUser(1)?.name  # none if user not found
```

## Strings

- `string` — immutable (like Python)
- UTF-8 by default
- Ownership-based, no GC, no reference counting
- Storage (transparent to programmer):
  - Literals `"..."` → static memory
  - Short (<=23 bytes) → inline SSO (stack)
  - Long (>23 bytes) → heap, single owner
- Passing: borrow by default (zero cost)
- `StringBuf` — mutable buffer for building strings
- Interpolation: `"hello {name}"`

```
let name = "Alice"                    # static memory
let greeting = "Hello, {name}!"      # SSO
let big = readFile("big.txt")        # heap, single owner

fn greet(s: string):                  # immutable borrow, zero cost
  echo(s)

let buf = newStringBuf()
buf.add("part1")
buf.add("part2")
let result = buf.toString()          # final immutable string
```

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
enum Direction*:
  north, south, east, west

let d = Direction.north
echo(d)                         # 0 (enum is always int)
echo($d)                        # "north" ($ returns variant name)

# Iterate over all values
for dir in Direction:
    echo($dir)

# Sets
let dirs: set[Direction] = {Direction.north, Direction.south}
if Direction.north in dirs:
    echo("going north")

# Explicit numeric values
enum Color*:
  red = 0, green = 1, blue = 2

# String values — $ returns the string value instead of variant name
enum HttpMethod*:
  get = "GET"
  post = "POST"
  put = "PUT"
  delete = "DELETE"

echo(HttpMethod.get)            # 0 (int)
echo($HttpMethod.get)           # "GET" ($ returns string value)

enum LogLevel*:
  debug = "DEBUG"
  info = "INFO"
  warn = "WARNING"
  error = "ERROR"

echo($LogLevel.warn)            # "WARNING"
```

`$` operator: returns the string value if defined, otherwise the variant name.
Enum value without `$` is always `int`.

#### Enum with data (algebraic type / sum type)

```
enum Shape*:
  Circle(radius: float)
  Rect(w: float, h: float)
  Point                        # variant without data — also OK

fn area*(s: Shape) -> float:
  result = match s:
    Circle as c: PI * c.radius * c.radius
    Rect as r: r.w * r.h
    Point: 0.0
```

Pattern matching with exhaustiveness checking — compiler guarantees
all variants are handled. Use `else` to catch remaining cases,
`discard` to explicitly ignore:

```
match direction:
  Direction.north: goUp()
  Direction.south: goDown()
else: discard                        # explicitly ignore east, west
```

No `_:` wildcard — use `else:` instead. `match` must always be exhaustive
(all cases handled or `else` present).

### Concepts

Named set of requirements for a type. Purely compile-time, zero overhead.
No `impl` needed — if a type fits, it automatically satisfies the concept.

```
concept Printable:
  fn toString(self) -> string

concept Comparable:
  fn lessThan(self, other: Self) -> bool
  fn equals(self, other: Self) -> bool

concept Serializable:
  fn toJson(self) -> string
  fn fromJson(raw: string) -> Self
```

Usage is **optional**, for documentation and better compiler errors:

```
# With concept — better error messages:
fn sort[T: Comparable](var list: slice[T]):
  ...
# error: type Socket does not satisfy concept Comparable
#   missing: fn lessThan(self, other: Socket) -> bool

# Without concept — also works, duck typing at call site:
fn sort[T](var list: slice[T]):
  ...
# error: type Socket has no method 'lessThan'
#   called from sort() at main.is:10
```

A type automatically satisfies a concept if it has the required methods:

```
type User:
  name: string
  age: int

fn toString(self: User) -> string:
  result = "{self.name}, {self.age}"

# User automatically satisfies Printable — has toString
# No impl, no registration needed
```

### Generics

```
fn map[T, U](list: slice[T], f: fn(T) -> U) -> seq[U]:
  result = [f(x) for x in list]

# With concept constraint (optional):
fn printAll[T: Printable](items: slice[T]):
  for item in items:
    echo(item.toString())
```

## Metaprogramming

Macros are a core feature of Iris. Written in Iris itself,
they operate on AST at compile-time. Three levels from simple to powerful.

### Principles

- Written in Iris itself (not a separate language)
- Operate on AST at compile-time
- Hygienic (no accidental name collisions)
- Type-safe where possible
- Debuggable (`iris expand` shows macro output)
- Applied by calling the macro directly (like Nim), no special decorator syntax
- Visibility via `*` (like everything else in Iris)
- Can generate types, functions, entire modules

### Templates — inline substitution

Simple compile-time code substitution, zero overhead:

```
template notEqual(a, b) -> bool:
  not (a == b)

# Usage — expanded at compile-time:
if notEqual(x, y):
  echo("different")

# Expands to:
# if not (x == y):
#     echo("different")
```

### Macros — AST transformation

Receive AST, return modified AST:

```
macro serializable*(body: Ast) -> Ast:
  # adds toJson() and fromJson() methods to a type
  let typeName = body.name
  body.addFn:
    fn toJson*(self) -> string:
      var buf = newStringBuf()
      buf.add("{")
      for i, field in body.fields:
        if i > 0: buf.add(", ")
        buf.add("\"{field.name}\": {self.{field.name}}")
      buf.add("}")
      result = buf.toString()
  result = body

# Usage — macro is just called, block is its AST argument:
serializable:
  type User:
    name*: string
    age*: int

# Compiler expands to:
# type User:
#     name*: string
#     age*: int
# fn toJson*(self: User) -> string:
#     ...
```

### DSL — domain-specific languages

Macros can parse custom syntax and generate code:

```
macro html(body: Ast) -> Ast:
  # parse DSL and generate Element constructors
  ...

let page = html:
  div(class: "container"):
    h1: "Hello"
    p: "World"

# Expands to Element constructor calls
```

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
block search:
  for item in list1:
    for item2 in list2:
      if item == item2:
        break search         # exit both loops
  echo("not found")

# Nested named blocks
block outer:
  for i in 0..100:
    block inner:
      if i == 50:
        break outer          # exit everything
      if i % 2 == 0:
        break inner          # skip this block
      process(i)
```

### Block as expression (returns a value)

```
let count = block b:
  if users.isEmpty:
    b.result = 0
    break b
  b.result = users.len

# Or simpler:
let status = block b:
  b.result = if isReady: "ok" else: "waiting"
```

### Thread Safety

Data races are impossible — prevented at compile time by the borrow checker.
If data is passed to a `spawn`, no other spawn can access it mutably.

```
var data = @[1, 2, 3]

# COMPILE ERROR — two spawns cannot mutate the same data:
block b:
  b.spawn:
    data.add(4)          # ERROR: mutable borrow conflict
  b.spawn:
    data.add(5)          # ERROR: data already borrowed

# OK — communicate via channels instead of shared memory:
let ch = channel[int](2)
block b:
  b.spawn:
    ch.send(4)
  b.spawn:
    ch.send(5)

# OK — each spawn gets its own data:
block b:
  b.spawn:
    var local = @[1, 2]
    local.add(3)
  b.spawn:
    var local = @[4, 5]
    local.add(6)
```

| Problem | Prevented? | How |
|---------|-----------|-----|
| Data races | **Yes, compile-time** | Borrow checker forbids shared mutable state |
| Race conditions | Risk reduced | Channels, structured concurrency |
| Deadlocks | No | Same as all languages |

### Structured Concurrency

```
block workers:
  workers.spawn: fetch("url1")
  workers.spawn: fetch("url2")
# <- all tasks guaranteed to be complete

# spawn is available via block handle
block pipeline:
  let ch = channel[string](10)

  for url in urls:
    pipeline.spawn:
      let data = fetch(url) else:
        break
      ch.send(data)

  for _ in urls:
    select:
      val from ch:
        process(val)
      after 10.sec:
        break pipeline       # timeout — exit everything
```

### Nested blocks for pipeline

```
block pipeline:
  let raw = channel[bytes](100)
  let parsed = channel[Record](100)

  block producers:
    for url in urls:
      producers.spawn:
        raw.send(fetch(url))

  block consumers:
    for _ in urls:
      consumers.spawn:
        let data = raw.recv()
        parsed.send(parse(data))
  # producers done -> consumers done -> pipeline done
```

### detach — for long-lived tasks (outside block)

`detach` is the opposite of `block`. Launches a task that lives independently of the current scope.

```
# For daemons/servers — explicit unstructured spawn (rare)
let server = detach:
  listen(8080)
# execution continues, server runs in background
server.cancel()       # explicit stop
```

### Channels + Select

Channels transfer ownership — sender loses access, no shared mutable state.
Primitive types (int, float, bool) are copied. Complex types are moved.

No unbounded channels — always explicit size to prevent memory leaks.
`send` blocks when buffer is full. `receive` blocks when buffer is empty.

```
# Buffered — blocks send when full:
let ch = channel[int](10)

# Unbuffered — blocks send until someone calls receive:
let ch = channel[int](0)

# Explicit receive:
let val = ch.receive()      # blocks until value available

# select — multiple channels, timeouts:
block b:
  b.spawn:
    ch.send(42)

while true:
  select:
    val from ch:
      echo("Got: {val}")
    after 5.sec:
      echo("Timeout!")
      break

# Ownership transfer — sender loses access:
let ch = channel[seq[int]](1)
var data = @[1, 2, 3]
ch.send(data)           # data MOVED into channel
# echo(data)            # ERROR: data was moved

# To send and keep — explicit clone:
ch.send(data.clone())   # send a copy
echo(data)              # OK — original still available
```

### No Colored Functions (no async/await)

In languages with async/await, functions are split into two worlds — sync and async.
Async "infects" the entire call chain: one async function forces all callers
to also be async. This is known as the "colored functions" problem.

Iris has **no async/await**. All functions are the same:

```
# Regular function. IO inside — but syntax is the same.
fn fetch(url: string) -> bytes | !NetError:
  let resp = http.get(url)?
  result = resp.body()

# Calling — just a call, no await:
fn process() !NetError:
  let data = fetch("https://api.example.com")?
  echo(data)
```

Concurrency is achieved via `block.spawn`, not async/await:

```
# Sequential — regular call:
let a = fetch("url1")?
let b = fetch("url2")?

# Parallel — block.spawn:
var a: bytes
var b: bytes
block w:
  w.spawn: a = fetch("url1")?
  w.spawn: b = fetch("url2")?
# <- both complete, a and b available
```

The compiler automatically detects IO operations inside `block.spawn`
and compiles them as non-blocking. The programmer doesn't think about it.

## Error Handling

A function with `| !ErrorType` in its signature returns a Result under the hood.
`result` sets the success value. Errors are returned via `raise`.

### Returning errors from a function (function author)

```
fn readConfig*(path: string) -> Config | !IoError | !ParseError:
  let raw = fs.read(path)?           # ? propagates IoError up
  let parsed = json.parse(raw)?      # ? propagates ParseError up
  result = Config.from(parsed)

fn divide*(a: int, b: int) -> int | !MathError:
  if b == 0:
    raise MathError.divByZero      # explicit error return
  result = a / b
```

- `?` — propagates the error to the caller (if error types are compatible)
- `raise` — explicitly returns an error and exits the function

### Handling errors (caller side)

#### 1. `?` — propagate up (if the calling function also returns an error)

```
fn loadApp*() -> App | !IoError | !ParseError:
  let cfg = readConfig("app.toml")?   # error propagated
  result = newApp(cfg)
```

#### 2. `match` — handle all cases

```
match readConfig("app.toml") as cfg:
  ok:
    start(cfg)
  error(IoError.notFound):
    createDefault()
  error as e:
    quit(e)
```

Exhaustiveness checking — compiler guarantees all variants are handled.

#### 3. `else` with fallback value

```
let cfg = readConfig("app.toml") else:
  Config.default()

# cfg = either the read config or the default
```

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
