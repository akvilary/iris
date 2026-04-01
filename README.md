# Iris

**A compiled systems language with Nim-level metaprogramming and Rust-level memory safety.**

Iris compiles to C, uses indentation-based syntax, and gives you full control over memory — without a garbage collector, without lifetime annotations, and without surprises.

```python
# hello.is
@name = "Iris"
*echo("Hello from {name}!")

@add func(@a int, @b int) ok int:
  result = a + b

*echo(add(3, 4))
```

## Why Iris

**Explicit by design.** Every allocation, every mutation, every error — visible in the code. No implicit constructors, no hidden copies, no magic.

**Safe without ceremony.** Memory safety is enforced at compile time. No garbage collector, no runtime overhead. The compiler checks assigned-before-use, borrow rules, and exhaustive pattern matching — all without requiring annotations from you.

**Readable from day one.** Clean indentation-based syntax. One obvious way to do things. Code reads like pseudocode, compiles like C.

## Quick tour

### Variables

Three levels of mutability — nothing more:

```python
@host = "localhost"       # immutable
@port mut = 8080          # mutable
@maxRetries const = 3     # compile-time constant
```

No zero-initialization. The compiler verifies every variable is assigned before use.

### Functions and named arguments

```python
@factorial func(@n int) ok int:
  if n <= 1:
    result = 1
    return
  result = n * factorial(n - 1)

*echo(factorial(10))
```

Call with positional or named arguments:

```python
@connect func(@host str, @port int) ok Connection:
  ...

connect("localhost", 8080)
connect(port=443, host="example.com")
```

### Types

```python
@User object:
  @name String
  @age int

@Color enum:
  @red, @green, @blue

@HttpMethod enum:
  @get = "GET"
  @post = "POST"
  @delete = "DELETE"
```

### Object variants (tagged unions)

```python
@Shape object:
  @x int
  @y int
  case @kind ShapeKind:
    of circle:
      @radius float
    of rect:
      @w float
      @h float
    of point:
      discard
```

The compiler enforces that variant-specific fields are only accessed inside the matching `case` branch.

### Error handling

Errors are types, not exceptions. Functions declare what they return — and what can go wrong:

```python
@ParseError error:
  @message String

@parsePort func(@input str) ok int else ParseError:
  if not isDigit(input):
    result = ParseError(message=~"not a number: {input}")
    return
  result = toInt(input)
```

Callers handle errors explicitly:

```python
@port = parsePort("8080")
if not port:
  *echo("bad port")
  quit()
*echo(port.get())
```

Or with pattern matching:

```python
caseblock parsePort(value):
  of ok:
    listen(port.get())
  of ParseError:
    *echo("failed to parse")
```

### Option[T]

No null. Values that may be absent use `Option[T]`:

```python
@user = findUser(id=42)

if user:
  *echo(user.get().name)

caseblock user:
  of some:
    greet(user.get())
  of none:
    *echo("not found")
```

### Expressions

`if` and `case` work as both statements and expressions:

```python
@status = "ok" if code == 200 else "error"

@label = case color of red "Red" of green "Green" of blue "Blue"

@grade = (
  "A" if score > 90
  else "B" if score > 80
  else "C"
)
```

### Generics and concepts

Generics use duck typing at instantiation — no boxing, full monomorphization:

```python
@identity func[T](@x T) ok T:
  result = x

@a = identity(42)       # T = int
@b = identity("hello")  # T = str
```

Concepts add optional constraints with clear error messages:

```python
@Printable concept:
  @toString func(@self) ok str

@print func[T: Printable](@item T):
  *echo(toString(item))
```

Types satisfy concepts automatically — no `impl` blocks needed.

### Strings

Three string types with clear semantics:

```python
@greeting = "hello"           # str — static, immutable, zero-cost
@owned = ~"hello"             # String — heap-owned, mutable
@name = "world"
@msg = ~"hello {name}!"      # String — owned interpolation
```

In function parameters, `view[String]` accepts both `str` and `String` at zero cost.

### Heap control with `~`

Stack by default. Heap only when you ask for it — always with `~`:

```python
@nums = [1, 2, 3]            # array[int, 3] — stack
@dynNums = ~[1, 2, 3]        # Seq[int] — heap

@scores = ~{"alice": 100}    # HashTable[str, int]
@ids = ~{1, 2, 3}            # HashSet[int]

@Point object:
  @x int
  @y int

@p = Point(x=10, y=20)       # stack
@hp = ~Point(x=10, y=20)     # Heap[Point] — heap
```

### Structured concurrency

No async/await. Concurrency is `block` + `spawn` — structured and guaranteed to clean up:

```python
# Parallel fetch — both complete before block exits:
@results block:
  spawn: fetch("url1")
  spawn: fetch("url2")

# First to complete wins:
@race block:
  spawn:
    @val = ch1.receive()
    if val:
      process(val.get())
      break race
  spawn:
    after(5.sec)
    break race
```

Channels transfer ownership — no shared mutable state, no data races:

```python
@ch = channel[int](10)
ch.send(data)               # data moved into channel
@val = ch.receive()
```

The concurrency runtime is **zero-cost when unused** — programs without `spawn` compile to pure C with no runtime overhead.

### Modules

```python
import net
@conn = net.connect("localhost", 8080)

from net import connect, listen
@conn = connect("localhost", 8080)
```

### Macros

Hygienic macros written in Iris itself, called with `*` prefix:

```python
@log macro(@msg):
  ast.expand:
    *echo("[LOG] {^msg^}")

*log("server started")
```

## Design principles

| Principle | How Iris applies it |
|---|---|
| **Explicit over implicit** | `~` marks every heap allocation. `mut` marks every mutable variable. Errors are in the signature. |
| **No zero-initialization** | Compiler checks assigned-before-use — no hidden defaults, no "zero value" bugs. |
| **One way to do it** | One loop syntax. One match syntax. One heap marker. |
| **Safety without annotations** | Lifetime inference uses 3 simple rules — no `'a` annotations needed for 90%+ of code. |
| **Pay only for what you use** | No GC. No runtime unless you use concurrency. Stack by default. |

## Compiling

```bash
iris build hello.is      # compile to binary
iris run hello.is        # compile and run
```

## Status

Iris is under active development. The compiler (written in Nim) covers:

- Lexer, parser, AST, semantic analyzer, C codegen
- Full type system: objects, enums, variants, generics, concepts
- Option[T], error types, pattern matching with exhaustiveness
- Tuples, destructuring, string types
- Module system with qualified and direct imports

See [ROADMAP.md](ROADMAP.md) for what's next.

## License

MIT
