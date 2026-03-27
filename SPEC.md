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
    host*: str        # публичное поле
    port*: int        # публичное поле
    secret: str       # приватное поле

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
fn classify*(n: int) -> str:
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
fn length(s: str) -> int:             # immutable borrow (default)
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
fn longest(x: str, y: str) -> str:
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

Если block не использует `.alloc` — аллокатор не создаётся (zero overhead).

## Strings

- `str` — неизменяемый (immutable), как в Python
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

fn greet(s: str):                    # immutable borrow, zero cost
    print(s)

let buf = StrBuf.new()
buf.add("part1")
buf.add("part2")
let result = buf.toStr()             # финальная immutable str
```

## Type System

- Статическая типизация
- Алгебраические типы (sum types / enums)
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

```
type Shape*:
    Circle(radius: float)
    Rect(w: float, h: float)
    Point

fn area*(s: Shape) -> float:
    result = match s:
        Circle(r): PI * r * r
        Rect(w, h): w * h
        Point: 0.0

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
    print("not found")

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
    let ch = chan[str](10)

    for url in urls:
        pipeline.spawn:
            let data = fetch(url) else err:
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
            print("Got: {val}")
        after 5.sec:
            print("Timeout!")
            break
```

### No Colored Functions

Нет async/await. Компилятор сам определяет IO-операции и компилирует
их как state machines внутри block. Синтаксис одинаковый для sync и async.

```
fn fetch(url: str) -> bytes !NetError:
    let resp = http.get(url)?      # компилятор знает: это IO
    result = resp.body()
```

## Error Handling

- Result-типы через `!Error` в сигнатуре
- `?` оператор для проброса
- Pattern matching для обработки
- `else` для inline обработки

```
fn readConfig*(path: str) -> Config !IoError | ParseError:
    let raw = fs.read(path)?
    let parsed = json.parse(raw)?
    result = Config.from(parsed)

match readConfig("app.toml"):
    ok(cfg): start(cfg)
    err(IoError.NotFound): createDefault()
    err(e): fatal("Error: {e}")

let cfg = readConfig("app.toml") else err:
    print("Failed: {err}")
    return
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
