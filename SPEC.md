# Slang Language Specification

## Overview

Slang — компилируемый системный язык программирования.
Компилируется в C (позже C++, JavaScript).
Компилятор пишется на Rust (bootstrap), затем self-hosting.

## Syntax

- Блоки через отступы (как Nim/Python)
- Нет точек с запятой
- Нет фигурных скобок для блоков
- Naming convention: pascalCase
- Явные возвращаемые значения: `result` в функциях, `handle.result` в блоках

## Variables

| Ключевое слово | Значение | Пример |
|----------------|----------|--------|
| `const` | Вычисляется на этапе компиляции (compile-time) | `const maxSize = 1024` |
| `let` | Неизменяемая переменная (runtime) | `let name = "Alice"` |
| `var` | Изменяемая переменная (runtime) | `var count = 0` |

```
const pi = 3.14159265              # compile-time, встраивается в код
const maxRetries* = 3              # compile-time, публичная

let user = getUser(id)             # runtime, нельзя переприсвоить
# user = otherUser                 # ОШИБКА: let нельзя изменить

var counter = 0                    # runtime, можно изменять
counter = counter + 1              # ОК
```

## Visibility

Публичность через `*` после имени (как в Nim):

```
fn helperFunc(x: int) -> int:        # приватная
    x + 1

fn processData*(x: int) -> int:      # публичная
    helperFunc(x)

type Config*:
    host*: string        # публичное поле
    port*: int        # публичное поле
    secret: string       # приватное поле

type Shape*:
    Circle(radius: float)
    Rect(w: float, h: float)

trait Drawable*:
    fn draw(self)

const maxRetries* = 3
```

## Module System

### Import — только квалифицированный доступ

```
import net

# Обязательно через имя модуля:
let conn = net.connect("localhost", 8080)

# НЕ допускается:
# connect("localhost", 8080)   ← ошибка компиляции
```

### From import — явный импорт конкретных имён

```
from net import connect, listen

# Теперь можно напрямую:
let conn = connect("localhost", 8080)
```

### From export — реэкспорт из вложенных модулей

```
# Реэкспорт конкретных имён:
from myLib.internal.parser export parseJson, parseXml

# Реэкспорт целого модуля:
export myLib.internal.parser

# Пользователь myLib получает доступ к parseJson
# без знания о внутренней структуре myLib
```

## Functions

```
fn funcName*(param1: Type1, param2: Type2) -> ReturnType !ErrorType:
    ...
```

- `*` после имени = публичная
- `!ErrorType` = функция может вернуть ошибку (разворачивается в Result)
- Несколько типов ошибок: `-> ReturnType !ErrA | ErrB`
- `?` оператор для проброса ошибок

### Return Values

`result` — зарезервированное слово. Возвращаемое значение задаётся явно:

```
fn add*(a: int, b: int) -> int:
    result = a + b

fn findUser*(id: int) -> User !NotFoundError:
    let user = db.query(id)?
    result = user

# result можно задать в любом месте, в т.ч. в ветвлениях:
fn classify*(n: int) -> string:
    if n > 0:
        result = "positive"
    elif n < 0:
        result = "negative"
    else:
        result = "zero"

# result можно задать рано и продолжить работу:
fn process*(data: []byte) -> int:
    result = 0
    for b in data:
        result = result + b.toInt()
    log("sum computed")    # выполнится после, result уже задан

# return — досрочный выход (использует текущее значение result):
fn search*(list: []int, target: int) -> int:
    result = -1
    for i, val in list:
        if val == target:
            result = i
            return             # выход с текущим result
```

Компилятор проверяет, что `result` задан на всех путях выполнения.

## Memory Model

### Ownership + Borrow Checker

По умолчанию — immutable borrow. Аннотации для других режимов:

| Аннотация | Смысл | Аналог в Rust |
|-----------|-------|---------------|
| *(ничего)* | Immutable borrow | `&T` |
| `var` | Mutable borrow | `&mut T` |
| `own` | Take ownership (immutable) | `T` |
| `own var` | Take ownership + mutable | `mut T` |

```
fn length(s: string) -> int:             # immutable borrow (default)
    s.len

fn sort(var list: []int):             # mutable borrow
    ...

fn send(own msg: Message):            # take ownership
    channel.push(msg)

fn normalize(own var data: []byte) -> []byte:  # own + mutate
    data.trim()
    data
```

### Lifetimes

Нет ручных lifetime-аннотаций. Компилятор выводит lifetimes автоматически
и проверяет корректность на call site (аналогично duck typing для дженериков).

```
fn longest(x: string, y: string) -> string:
    result = if x.len > y.len: x else: y

# Компилятор на call site проверяет, что результат не переживёт x и y:
let a = "hello"
let b = "world"
let long = longest(a, b)    # ОК: a, b, long — в одном scope
```

### Memory Regions (block.alloc)

Region-based memory management через `block.alloc`.
Для циклических структур и графов:

```
block pool:
    let a = pool.alloc(Node("A"))
    let b = pool.alloc(Node("B"))
    a.link(b)
    b.link(a)              # циклическая ссылка — ОК, один регион
# <- вся память региона освобождена за O(1)
```

Данные из `block.alloc` не могут покинуть block:

```
block pool:
    let node = pool.alloc(Node("A"))
    node                   # ОШИБКА: node привязан к pool
# Если нужно вынести — явный .clone()
```

Вызывающий код владеет block, функции принимают handle
(как передача аллокатора в Zig):

```
block pool:
    buildGraph(pool)       # функция аллоцирует внутри pool
    traverse(pool.root)    # используем данные
# <- всё освобождено

fn buildGraph(pool: Block):
    let a = pool.alloc(Node("A"))
    let b = pool.alloc(Node("B"))
    a.link(b)
    b.link(a)
    pool.root = a
```

Если block не использует `.alloc` — аллокатор не создаётся (zero overhead).

## Collections

### Arrays, Sequences, Views

| Синтаксис | Что это | Где живёт | Размер |
|-----------|---------|-----------|--------|
| `[5]int` | Фиксированный массив | Стек (inline) | Известен на компиляции |
| `seq[int]` | Динамическая последовательность | Куча | Растёт в runtime |
| `[]int` | View/slice (только для параметров) | Ссылка на чужие данные | Указатель + длина |

```
# Фиксированный массив — стек
let fixed: [5]int = [1, 2, 3, 4, 5]

# Динамическая последовательность — куча
var dynamic: seq[int] = [1, 2, 3]
dynamic.add(4)

# View — принимает и array, и seq
fn sum(arr: []int) -> int:
    result = 0
    for x in arr:
        result = result + x

sum(fixed)      # ОК — view на стековый массив
sum(dynamic)    # ОК — view на seq
```

## Strings

## Numeric Types

```
int         # signed, размер платформы (64-bit на современных системах)
int8        # 8-bit signed
int16       # 16-bit signed
int32       # 32-bit signed
int64       # 64-bit signed
uint        # unsigned, размер платформы
uint8       # 8-bit unsigned (он же byte)
uint16      # 16-bit unsigned
uint32      # 32-bit unsigned
uint64      # 64-bit unsigned
float       # = float64 по умолчанию
float32     # 32-bit float
float64     # 64-bit float
byte        # алиас для uint8
natural     # int с ограничением >= 0, ошибка при попытке стать отрицательным
```

`natural` — безопасный неотрицательный тип. В отличие от `uint`,
не оборачивается при переполнении, а вызывает ошибку:

```
var n: natural = 10
n = n - 5                # ОК, n = 5
n = n - 10               # ОШИБКА: natural не может быть отрицательным

# Идеален для индексов, размеров, счётчиков
fn createBuffer*(size: natural) -> Buffer:
    # size гарантированно >= 0, не нужна проверка
    ...
```

## Strings

- `string` — неизменяемый (immutable), как в Python
- UTF-8 по умолчанию
- Ownership-based, без GC и без reference counting
- Хранение (прозрачно для программиста):
  - Литералы `"..."` → статическая память
  - Короткие (<=23 байт) → inline SSO (стек)
  - Длинные (>23 байт) → куча, один владелец
- Передача: borrow по умолчанию (zero cost)
- `StrBuf` — мутабельный буфер для построения строк
- Интерполяция: `"hello {name}"`

```
let name = "Alice"                    # статическая память
let greeting = "Hello, {name}!"      # SSO
let big = readFile("big.txt")        # куча, один владелец

fn greet(s: string):                    # immutable borrow, zero cost
    echo(s)

let buf = StrBuf.new()
buf.add("part1")
buf.add("part2")
let result = buf.toString()          # финальная immutable string
```

## Type System

- Статическая типизация
- Дженерики без явных constraints (duck typing при инстанциации, как Nim)
  - Компилятор проверяет при вызове, не при объявлении
  - `slang check --api-compat` для проверки breaking changes
- Pattern matching с exhaustiveness checking
- Traits (interfaces)
- Нет null/nil — только `Option[T]`
- Нет наследования классов — только композиция и traits
- Нет неявных преобразований — только явные `.into()`
- Nominal typing (два типа с одинаковыми полями ≠ один тип)
- Structural typing через traits

### Enum

Единый keyword `enum` для простых перечислений и алгебраических типов.
Компилятор определяет вид по наличию данных у вариантов.

#### Простой enum (без данных)

Поддерживает итерацию, `ord`, множества (`set`):

```
enum Direction*:
    north, south, east, west

let d = Direction.north
echo(d)                         # "north"
echo(ord(d))                    # 0

# Итерация по всем значениям
for dir in Direction:
    echo(dir)

# Множества
let dirs: set[Direction] = {Direction.north, Direction.south}
if Direction.north in dirs:
    echo("going north")

# Явные числовые значения
enum Color*:
    red = 0, green = 1, blue = 2
```

#### Enum с данными (алгебраический тип / sum type)

```
enum Shape*:
    Circle(radius: float)
    Rect(w: float, h: float)
    Point                        # вариант без данных — тоже ОК

fn area*(s: Shape) -> float:
    result = match s:
        Circle(r): PI * r * r
        Rect(w, h): w * h
        Point: 0.0
```

Pattern matching с exhaustiveness checking — компилятор гарантирует,
что все варианты обработаны.

### Generics

```
fn map[T, U](list: []T, f: fn(T) -> U) -> []U:
    result = [f(x) for x in list]
```

## Block — универсальная конструкция

`block` — единый building block для control flow, concurrency, scoping и значений.
Поведение определяется содержимым, а не разными ключевыми словами.

### Control Flow — именованные блоки и break

```
# Выход из вложенных циклов
block search:
    for item in list1:
        for item2 in list2:
            if item == item2:
                break search         # выход из обоих циклов
    echo("not found")

# Вложенные именованные блоки
block outer:
    for i in 0..100:
        block inner:
            if i == 50:
                break outer          # выход из всего
            if i % 2 == 0:
                break inner          # пропуск этого блока
            process(i)
```

### Block как выражение (возвращает значение)

```
let count = block b:
    if users.isEmpty:
        b.result = 0
        break b
    b.result = users.len

# Или проще:
let status = block b:
    b.result = if isReady: "ok" else: "waiting"
```

### Structured Concurrency

```
block workers:
    workers.spawn: fetch("url1")
    workers.spawn: fetch("url2")
# <- все задачи гарантированно завершены

# spawn доступен через handle блока
block pipeline:
    let ch = chan[string](10)

    for url in urls:
        pipeline.spawn:
            let data = fetch(url) else error:
                break
            ch.send(data)

    for _ in urls:
        select:
            val from ch:
                process(val)
            after 10.sec:
                break pipeline       # таймаут — выходим из всего
```

### Вложенные блоки для pipeline

```
block pipeline:
    let raw = chan[bytes](100)
    let parsed = chan[Record](100)

    block producers:
        for url in urls:
            producers.spawn:
                raw.send(fetch(url))

    block consumers:
        for _ in urls:
            consumers.spawn:
                let data = raw.recv()
                parsed.send(parse(data))
    # producers закончились -> consumers закончились -> pipeline закончился
```

### Memory Regions (block.alloc)

```
block pool:
    let a = pool.alloc(Node("A"))
    let b = pool.alloc(Node("B"))
    a.link(b)
    b.link(a)                    # цикл — ОК, один регион
# <- вся память освобождена за O(1)

# Данные не могут покинуть block:
block pool:
    let node = pool.alloc(Node("A"))
    node                         # ОШИБКА: node привязан к pool

# Комбинация с concurrency:
block ctx:
    let graph = ctx.alloc(Graph.new())
    ctx.spawn: traverse(graph)
    ctx.spawn: validate(graph)
# <- задачи завершены, память освобождена

# Без .alloc — обычный block, zero overhead
```

### task.detach — для long-lived задач (вне block)

```
# Для демонов/серверов — явный unstructured spawn (редко)
let server = task.detach:
    listen(8080)
# продолжаем выполнение, сервер крутится в фоне
server.cancel()       # явная остановка
```

### Channels + Select

```
let ch = chan[int](10)

block:
    b.spawn:
        ch.send(42)

loop:
    select:
        val from ch:
            echo("Got: {val}")
        after 5.sec:
            echo("Timeout!")
            break
```

### No Colored Functions

Нет async/await. Компилятор сам определяет IO-операции и компилирует
их как state machines внутри block. Синтаксис одинаковый для sync и async.

```
fn fetch(url: string) -> bytes !NetError:
    let resp = http.get(url)?      # компилятор знает: это IO
    result = resp.body()
```

## Error Handling

Функция с `!ErrorType` в сигнатуре возвращает Result под капотом.
`result` задаёт успешное значение. Ошибка возвращается через `raise`.

### Возврат ошибки из функции (автор функции)

```
fn readConfig*(path: string) -> Config !IoError | ParseError:
    let raw = fs.read(path)?           # ? пробрасывает IoError наверх
    let parsed = json.parse(raw)?      # ? пробрасывает ParseError наверх
    result = Config.from(parsed)

fn divide*(a: int, b: int) -> int !MathError:
    if b == 0:
        raise MathError.divByZero      # явный возврат ошибки
    result = a / b
```

- `?` — пробрасывает ошибку вызывающему коду (если типы ошибок совместимы)
- `raise` — явно возвращает ошибку и выходит из функции

### Обработка ошибки (вызывающий код)

#### 1. `?` — проброс наверх (если вызывающая функция тоже возвращает ошибку)

```
fn loadApp*() -> App !IoError | ParseError:
    let cfg = readConfig("app.toml")?   # ошибка пробрасывается
    result = App.new(cfg)
```

#### 2. `match` — полная обработка всех случаев

```
match readConfig("app.toml"):
    ok(cfg):
        start(cfg)
    error(IoError.notFound):
        createDefault()
    error(ParseError.syntax(line)):
        echo("Syntax error at line {line}")
    error(e):
        fatal("Error: {e}")
```

Exhaustiveness checking — компилятор гарантирует, что все варианты обработаны.

#### 3. `else` — inline обработка ошибки

```
let cfg = readConfig("app.toml") else error:
    echo("Failed: {error}")
    return

# cfg здесь гарантированно успешный, тип Config (не Result)
start(cfg)
```

#### 4. `else` с конкретным fallback значением

```
let cfg = readConfig("app.toml") else:
    Config.default()

# cfg = либо прочитанный конфиг, либо default
```

#### 5. `else` с обработкой конкретных ошибок

```
let cfg = readConfig("app.toml") else error:
    match error:
        IoError.notFound: Config.default()
        _: raise error     # остальные пробрасываем
```

## Tooling (built into compiler)

- `slang build` — сборка (+ кросс-компиляция `--target=...`)
- `slang fmt` — обязательный форматтер
- `slang test` — запуск тестов
- `slang run file.sl` — запуск
- `slang deps` — менеджер зависимостей
- `slang check --api-compat` — проверка совместимости API
- LSP — разрабатывается параллельно с компилятором

## Compilation Targets

- C (primary, first)
- C++ (later)
- JavaScript (later)
