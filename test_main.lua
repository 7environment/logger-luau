-- Local Lua 5.4 smoke tests for the production Luau module.

local function expect(condition, message)
    if not condition then
        error(message or "expectation failed", 2)
    end
end

local httpService = {}

function httpService:JSONEncode(_value)
    return "{}"
end

function httpService:JSONDecode(value)
    if value == "rate-limited" then
        return { retry_after = 0 }
    end
    return {}
end

game = {
    GetService = function(_, serviceName)
        expect(serviceName == "HttpService", "unexpected Roblox service")
        return httpService
    end,
}

local spawned = {}
task = {
    spawn = function(callback)
        table.insert(spawned, callback)
    end,
    wait = function(_seconds)
        -- The test drives queues directly and intentionally does not run workers.
    end,
}

warn = function(_message) end

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local scriptDirectory = scriptPath:match("^(.*[/\\])") or "./"
local sourceFile = assert(io.open(scriptDirectory .. "init.luau", "rb"))
local source = sourceFile:read("*a")
sourceFile:close()
local Logger = assert(load(source, "@logger/init.luau", "t", _ENV))()

local function newHttp(responses)
    local calls = {}
    local index = 0
    local client = {}

    function client:Request(options)
        table.insert(calls, options)
        index = index + 1
        return responses[index] or responses[#responses]
    end

    return client, calls
end

local function testHttpIsRequired()
    local ok = pcall(Logger.new, "test", nil, {})
    expect(not ok, "Logger.new must require an HTTP object")
end

local function testMissingFileFunctionsFailAtInitialization()
    local http = newHttp({ { Success = true, StatusCode = 204 } })
    local ok, message = pcall(Logger.new, "missing-file-api", http, {
        Console = { Enabled = false },
        File = {
            Enabled = true,
            Path = "test.log",
            FlushInterval = 0,
        },
        OnInternalError = function() end,
    })

    expect(not ok, "missing file functions were not detected")
    expect(
        string.find(tostring(message), "appendfile or (readfile + writefile)", 1, true) ~= nil,
        "missing file error does not list the required capabilities"
    )
end

local function testMissingTaskFunctionsFailAtInitialization()
    local http = newHttp({ { Success = true, StatusCode = 204 } })
    local savedTask = task
    task = nil
    local ok, message = pcall(Logger.new, "missing-task-api", http, {
        Console = { Enabled = false },
        Discord = {
            Enabled = true,
            WebhookUrl = "https://discord.test/webhook",
        },
        OnInternalError = function() end,
    })
    task = savedTask

    expect(not ok, "missing task functions were not detected")
    expect(string.find(tostring(message), "task.spawn", 1, true) ~= nil, "task.spawn is absent from error")
    expect(string.find(tostring(message), "task.wait", 1, true) ~= nil, "task.wait is absent from error")
end

local function testFileBatching()
    local written = {}
    local http = newHttp({ { Success = true, StatusCode = 204 } })
    local logger = Logger.new("file", http, {
        Console = { Enabled = false },
        File = {
            Enabled = true,
            Level = "DEBUG",
            Path = "test.log",
            BatchSize = 2,
            FlushInterval = 0,
            Adapter = {
                Append = function(path, data)
                    table.insert(written, { path = path, data = data })
                end,
            },
        },
    })

    logger:Debug("first")
    expect(#written == 0, "file handler flushed before BatchSize")
    logger:Info("second")
    expect(#written == 1, "file handler did not flush at BatchSize")
    expect(written[1].path == "test.log", "file handler used the wrong path")
    expect(string.find(written[1].data, "first", 1, true) ~= nil, "first record is absent")
    expect(string.find(written[1].data, "second", 1, true) ~= nil, "second record is absent")
end

local function testImmediateDiscordAndRetry()
    local http, calls = newHttp({
        {
            Success = false,
            StatusCode = 429,
            Headers = {},
            Body = "rate-limited",
        },
        {
            Success = true,
            StatusCode = 204,
            Headers = {},
            Body = "",
        },
    })
    local logger = Logger.new("discord", http, {
        Console = { Enabled = false },
        Discord = {
            Enabled = true,
            Level = "ERROR",
            WebhookUrl = "https://discord.test/webhook",
            ImmediateLevels = { ERROR = true },
            PollInterval = 0.03,
        },
    })

    logger:Error("send now")
    expect(#calls == 1, "immediate level did not make a direct attempt")
    expect(logger:GetPendingDiscordCount() == 1, "rate-limited record was lost")

    logger._discordBlockedUntil = 0
    logger._discordPriorityQueue[1].NextAttemptAt = 0
    local flushed, pending = logger:FlushDiscord(1)
    expect(flushed and pending == 0, "queued record was not retried")
    expect(#calls == 2, "unexpected Discord request count")
end

local function testDiscordBatching()
    local http, calls = newHttp({
        {
            Success = true,
            StatusCode = 204,
            Headers = {},
            Body = "",
        },
    })
    local logger = Logger.new("batch", http, {
        Console = { Enabled = false },
        Discord = {
            Enabled = true,
            Level = "INFO",
            WebhookUrl = "https://discord.test/webhook",
            BatchSize = 3,
            BatchInterval = 60,
        },
    })

    for index = 1, 2 do
        logger:Info("batch record %d", index)
    end
    expect(not logger:_processDiscordOnce(false), "incomplete Discord batch was sent before its interval")

    logger:Info("batch record 3")
    expect(logger:_processDiscordOnce(false), "full Discord batch was not sent immediately")
    expect(#calls == 1, "full Discord batch used the wrong request count")

    logger:Info("batch record 4")
    logger:Info("batch record 5")
    expect(not logger:_processDiscordOnce(false), "second incomplete batch ignored BatchInterval")
    expect(logger:GetPendingDiscordCount() == 2, "batched records were lost before flush")

    local flushed, pending = logger:FlushDiscord(1)
    expect(flushed and pending == 0, "Discord batches did not flush")
    expect(#calls == 2, "five records with BatchSize=3 must use two requests")

    local stats = logger:GetDiscordStats()
    expect(stats.DeliveredRecords == 5, "batch stats have the wrong record count")
    expect(stats.SuccessfulRequests == 2, "batch stats have the wrong request count")
    expect(stats.LargestBatch == 3, "batch stats have the wrong maximum batch")
end

local function testDiscordBatchRespectsContentLimit()
    local http, calls = newHttp({
        {
            Success = true,
            StatusCode = 204,
            Headers = {},
            Body = "",
        },
    })
    local logger = Logger.new("content-limit", http, {
        Console = { Enabled = false },
        Discord = {
            Enabled = true,
            Level = "INFO",
            WebhookUrl = "https://discord.test/webhook",
            BatchSize = 3,
            MaxContentLength = 20,
        },
    })

    logger:Info("first long record")
    logger:Info("second long record")
    logger:Info("third long record")
    local flushed = logger:FlushDiscord(1)

    expect(flushed, "content-limited Discord queue did not flush")
    expect(#calls == 3, "batch exceeded MaxContentLength")
    expect(logger:GetDiscordStats().LargestBatch == 1, "content-limited batch contains extra records")
end

local function testPermanentDiscordFailureIsRetained()
    local http = newHttp({
        {
            Success = false,
            StatusCode = 401,
            Headers = {},
            Body = "unauthorized",
        },
    })
    local logger = Logger.new("failed", http, {
        Console = { Enabled = false },
        Discord = {
            Enabled = true,
            Level = "WARNING",
            WebhookUrl = "https://discord.test/webhook",
        },
    })

    logger:Warning("retain me")
    logger:_processDiscordOnce()
    local failed = logger:GetFailedDiscordMessages()
    expect(#failed == 1, "permanent failure was discarded")
    expect(failed[1].Message == "retain me", "failed record changed")
    expect(logger:RetryFailedDiscord() == 1, "failed record could not be requeued")
end

testHttpIsRequired()
testMissingFileFunctionsFailAtInitialization()
testMissingTaskFunctionsFailAtInitialization()
testFileBatching()
testImmediateDiscordAndRetry()
testDiscordBatching()
testDiscordBatchRespectsContentLimit()
testPermanentDiscordFailureIsRetained()

print("logger smoke tests: ok")
