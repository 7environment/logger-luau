# Logger для Roblox/Luau

Python-подобный логгер с независимыми обработчиками консоли, файла и Discord
webhook. Для каждого обработчика отдельно настраиваются включение и минимальный
уровень. Файловые записи отправляются батчами, а Discord использует очередь с
повторами при timeout, `429` и серверных ошибках.

## Подключение

Проект состоит из одного модуля `init.luau`. Загрузите его и соседний
[HTTP-адаптер](https://github.com/7environment/http-roblox-adapter) удобным для вашей среды способом. Logger принимает **готовый объект
HTTP-модуля вторым аргументом** и не создаёт HTTP-клиент самостоятельно.

```lua
local UniversalHttp = loadstring(readfile("http-roblox-adapter/init.luau"))()
local Logger = loadstring(readfile("logger-luau/init.luau"))()

local http = UniversalHttp.new({
    DefaultTimeout = 30,
    Proxy = {
        Enabled = true,
        Url = "https://proxy.example.com",
        Token = "replace-with-your-token",
    },
})

local logger = Logger.new("Server", http, {
    Console = {
        Enabled = true,
        Level = Logger.Level.INFO,
    },

    File = {
        Enabled = true,
        Level = Logger.Level.DEBUG,
        Path = "logs/server.log",
        BatchSize = 50,
        FlushInterval = 5,
    },

    Discord = {
        Enabled = true,
        Level = Logger.Level.WARNING,
        WebhookUrl = "https://discord.com/api/webhooks/.../...",
        BatchSize = 10,
        BatchInterval = 0.5,
        ImmediateLevels = {
            [Logger.Level.ERROR] = true,
            [Logger.Level.CRITICAL] = true,
        },
    },
})
```

Если Discord отключён, HTTP-объект всё равно обязателен: это явная зависимость
логгера и единая форма его инициализации. Объект должен иметь метод
`Request(options)` или `request(options)`. Формат ответа должен совпадать с
модулем `http-proxy`: `Success`, `StatusCode`, `Headers`, `Body` и `Error`.

## Проверка окружения при инициализации

`Logger.new` проверяет необходимые функции до запуска worker-ов и до первой
записи. Требования зависят от включённых обработчиков:

- всегда: `os.time`, `os.date`, `table.pack`, `table.unpack`;
- Console: `print` и `warn`;
- фоновые worker-ы: `task.spawn` и `task.wait`;
- Discord: `os.clock`, `utf8.len`, `utf8.offset`,
  `HttpService.JSONEncode` и `HttpService.JSONDecode`;
- File без адаптера: `appendfile` либо одновременно `readfile + writefile`;
- File с `Adapter.Append`: файловые функции executor-а не требуются.

Если Console выключена, но File или Discord могут сообщить внутреннюю ошибку,
также требуется `warn`. Это требование снимается при заданном
`OnInternalError`.

При отсутствии функций инициализация сразу завершится понятной ошибкой:

```text
Logger environment is missing required functions: task.spawn, task.wait
```

`isfile` необязателен. Один `writefile` без `readfile` намеренно не принимается,
поскольку он не может безопасно дополнять существующий файл между батчами.

## Запись логов

Названия методов соответствуют привычному API Python `logging`:

```lua
logger:Debug("loaded cache")
logger:Info("player %s connected", player.Name)
logger:Warning("inventory is almost full: %d slots", freeSlots)
logger:Error("could not save player %s", player.Name)
logger:Critical("database is unavailable")
```

Есть варианты с нижним регистром (`debug`, `info`, `warning`, `error`,
`critical`), алиас `Warn`/`warn` и общий метод:

```lua
logger:Log(Logger.Level.INFO, "custom log entry")
```

Поддерживаются уровни:

| Уровень | Значение |
| --- | ---: |
| `Logger.Level.DEBUG` | 10 |
| `Logger.Level.INFO` | 20 |
| `Logger.Level.WARNING` | 30 |
| `Logger.Level.ERROR` | 40 |
| `Logger.Level.CRITICAL` | 50 |

Уровни в конфигурации также можно задавать строками, например `Level = "INFO"`.
Сначала применяется общий `Logger.Level`, затем порог конкретного обработчика.

## Конфигурация

### Общие параметры

| Параметр | По умолчанию | Назначение |
| --- | --- | --- |
| `Level` | `DEBUG` | Общий минимальный уровень Logger. |
| `OnInternalError` | `nil` | Callback `(component, message, details)` для внутренних ошибок. |

Если `OnInternalError` не задан, внутренние ошибки выводятся через `warn`.
Ошибки доставки не создают новые записи Logger и поэтому не вызывают рекурсию.

### Console

| Параметр | По умолчанию | Назначение |
| --- | --- | --- |
| `Enabled` | `true` | Включает консоль. |
| `Level` | `INFO` | Минимальный уровень. |
| `Format` | `{time} [{level}] {name}: {message}` | Формат строки. |

`DEBUG` и `INFO` используют `print`, более высокие уровни — `warn`.

### File

| Параметр | По умолчанию | Назначение |
| --- | --- | --- |
| `Enabled` | `false` | Включает запись в файл. |
| `Level` | `DEBUG` | Минимальный уровень. |
| `Path` | `logger.log` | Путь к файлу. |
| `BatchSize` | `50` | Записей до немедленного сброса батча. |
| `FlushInterval` | `5` | Периодический сброс в секундах, `0` отключает его. |
| `Format` | `{time} [{level}] {name}: {message}` | Формат строки. |
| `Adapter` | `nil` | Необязательный файловый адаптер. |

По умолчанию Logger использует executor-функцию `appendfile`. Если её нет, он
пытается применить `readfile` + `writefile`. Для другой среды передайте адаптер:

```lua
File = {
    Enabled = true,
    Path = "server.log",
    Adapter = {
        Append = function(path, data)
            myStorage:Append(path, data)
        end,
    },
}
```

Данные удаляются из памяти только после успешной записи всего батча. При ошибке
буфер остаётся на месте, а следующая попытка повторит запись. В адаптере
`Append` ошибка должна выбрасываться через `error`, чтобы Logger сохранил батч.

### Discord

| Параметр | По умолчанию | Назначение |
| --- | --- | --- |
| `Enabled` | `false` | Включает webhook. |
| `Level` | `WARNING` | Минимальный уровень. |
| `WebhookUrl` | `nil` | Полный URL Discord webhook. |
| `ImmediateLevels` | `{}` | Уровни для прямой попытки отправки. |
| `BatchSize` | `1` | Максимум записей в одном webhook-запросе, от `1` до `100`. |
| `BatchInterval` | `0.5` | Максимальное ожидание наполнения неполного батча в секундах. |
| `BatchSeparator` | `\n` | Разделитель записей внутри сообщения Discord. |
| `Username` | `nil` | Переопределение имени webhook. |
| `AvatarUrl` | `nil` | Переопределение аватара webhook. |
| `UseProxy` | `nil` | Переопределяет режим proxy у HTTP-модуля для webhook. |
| `PollInterval` | `0.1` | Интервал проверки очереди. |
| `BaseRetryDelay` | `1` | Начальная задержка повтора. |
| `MaxRetryDelay` | `60` | Максимальная задержка повтора. |
| `MaxContentLength` | `1900` | Ограничение всего батча, не более лимита Discord `2000`. |
| `Format` | `[{level}] {name}: {message}` | Формат сообщения. |
| `AllowedMentions` | `{ parse = {} }` | Значение Discord `allowed_mentions`. |

`ImmediateLevels` принимает и словарную, и списочную форму:

```lua
ImmediateLevels = {
    INFO = true,
    WARNING = true,
}

-- либо
ImmediateLevels = {
    Logger.Level.INFO,
    Logger.Level.WARNING,
}
```

Для такого уровня Logger сразу выполняет HTTP-запрос. Если другая отправка уже
идёт или действует rate limit, сообщение помещается в приоритетный буфер. При
timeout, транспортной ошибке, `408`, `425`, `429` или `5xx` запись остаётся в
памяти и повторяется с задержкой. Для `429` читается `retry_after` из JSON-тела,
`Retry-After` или `X-RateLimit-Reset-After` из заголовков.

Обычная очередь объединяет до `BatchSize` записей, пока общий текст помещается
в `MaxContentLength`. Полный батч отправляется сразу; неполный — после
`BatchInterval`. `FlushDiscord` отправляет остаток немедленно, не дожидаясь
интервала. При `BatchSize = 1` каждая запись снова становится отдельным
webhook-запросом.

Приоритетная и обычная очереди никогда не смешиваются в одном батче.
`ImmediateLevels` выполняются одиночным запросом; только после временной ошибки
несколько приоритетных retry-записей могут объединиться между собой.

Неисправимые ответы (`400`, `401`, `403`, `404` и другие не retryable `4xx`)
перемещаются в отдельный failed-буфер, чтобы не блокировать следующие записи и
не терять исходное сообщение:

```lua
local failed = logger:GetFailedDiscordMessages()
print("failed messages", #failed)

-- После исправления URL/доступа вернуть их в приоритетную очередь:
local retried = logger:RetryFailedDiscord()
```

Статистика batching и доставки доступна без раскрытия содержимого очереди:

```lua
local stats = logger:GetDiscordStats()
print(stats.DeliveredRecords, stats.Requests)
print(stats.SuccessfulRequests, stats.RetryEvents, stats.LargestBatch)
print(stats.PendingRecords, stats.CurrentFailedRecords)
```

Очередь находится в памяти процесса. Она защищает от временных ошибок во время
работы, но не переживает аварийное завершение executor-а или процесса.

## Форматирование

В `Format` доступны маркеры:

- `{time}` — UTC-время ISO 8601;
- `{timestamp}` — Unix timestamp;
- `{level}` или `{levelname}` — название уровня;
- `{name}` — имя Logger;
- `{message}` — сообщение.

Неизвестные маркеры остаются без изменений.

## Изменение настроек во время работы

```lua
logger:SetLevel(Logger.Level.INFO)
logger:SetHandlerLevel("console", Logger.Level.WARNING)
logger:SetHandlerEnabled("file", false)
logger:SetHandlerEnabled("discord", true)
```

Допустимые имена обработчиков: `console`, `file`, `discord` без учёта регистра.

## Flush и завершение

```lua
local ok, status = logger:Flush(15)
if not ok then
    warn("not everything was delivered", status.DiscordPending)
end

local closed, closeStatus = logger:Close(15)
```

`FlushFile()` немедленно записывает файловый батч. `FlushDiscord(timeout)` ждёт
опустошения обычной и приоритетной очередей. `Flush(timeout)` выполняет оба
действия.

`Close(timeout)` сначала запрещает новые логи, затем вызывает `Flush`. Logger
помечается закрытым только после успешного сброса. Если timeout закончился,
метод возвращает `false`, сообщения остаются в памяти, фоновый worker продолжает
повторы, а `Close` можно вызвать ещё раз позднее.

Failed-буфер постоянных Discord-ошибок не делает `Flush` неуспешным; его размер
доступен в `status.DiscordFailed`.

## Важные ограничения

- Обычный Roblox не предоставляет файловой системы. Для File нужен executor с
  файловыми функциями либо собственный `File.Adapter`.
- Для фоновых батчей и очереди необходимы стандартные функции `task.spawn` и
  `task.wait`.
- Гарантия повторной отправки действует только пока жив текущий Luau-процесс.
- Не публикуйте URL webhook в клиентском коде, доступном недоверенным игрокам.

## Локальная проверка

Если установлен Lua 5.4, базовые smoke-тесты можно запустить из корня рабочей
директории:

```shell
lua test_main.lua
```

Тестовый загрузчик проверяет обязательное внедрение HTTP-объекта, файловый
batching, Discord batching и ограничение размера содержимого, немедленную
Discord-отправку, повтор после `429` и failed-буфер.
