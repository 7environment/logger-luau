local HttpService = game:GetService("HttpService")

local Logger = {}
Logger.__index = Logger

Logger.Level = {
    DEBUG = 10,
    INFO = 20,
    WARNING = 30,
    ERROR = 40,
    CRITICAL = 50,
}

local LEVEL_NAMES = {
    [Logger.Level.DEBUG] = "DEBUG",
    [Logger.Level.INFO] = "INFO",
    [Logger.Level.WARNING] = "WARNING",
    [Logger.Level.ERROR] = "ERROR",
    [Logger.Level.CRITICAL] = "CRITICAL",
}

local HANDLER_NAMES = {
    console = "Console",
    file = "File",
    discord = "Discord",
}

local function shallowCopy(source)
    local result = {}
    if type(source) == "table" then
        for key, value in pairs(source) do
            result[key] = value
        end
    end
    return result
end

local function merge(defaults, overrides)
    local result = shallowCopy(defaults)
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            result[key] = value
        end
    end
    return result
end

local function normalizeLevel(level, fieldName)
    if type(level) == "string" then
        level = Logger.Level[string.upper(level)]
    end

    if type(level) ~= "number" then
        error((fieldName or "level") .. " must be a Logger.Level value or level name", 3)
    end

    return level
end

local function nowIso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function interpolate(template, record)
    local values = {
        time = record.Time,
        timestamp = tostring(record.Timestamp),
        level = record.LevelName,
        levelname = record.LevelName,
        name = record.LoggerName,
        message = record.Message,
    }

    return (string.gsub(template, "{([%w_]+)}", function(key)
        return values[key] or "{" .. key .. "}"
    end))
end

local function formatMessage(message, ...)
    local arguments = table.pack(...)
    message = tostring(message)

    if arguments.n == 0 then
        return message
    end

    local ok, formatted = pcall(string.format, message, table.unpack(arguments, 1, arguments.n))
    if ok then
        return formatted
    end

    local parts = { message }
    for index = 1, arguments.n do
        table.insert(parts, tostring(arguments[index]))
    end
    return table.concat(parts, " ")
end

local function findHeader(headers, wantedName)
    if type(headers) ~= "table" then
        return nil
    end

    wantedName = string.lower(wantedName)
    for name, value in pairs(headers) do
        if string.lower(tostring(name)) == wantedName then
            return value
        end
    end
    return nil
end

local function truncateUtf8(value, maximumCharacters)
    if maximumCharacters <= 0 then
        return ""
    end

    local ok, length = pcall(utf8.len, value)
    if not ok or length == nil then
        return string.sub(value, 1, maximumCharacters)
    end
    if length <= maximumCharacters then
        return value
    end

    local offset = utf8.offset(value, maximumCharacters + 1)
    if offset == nil then
        return value
    end
    return string.sub(value, 1, offset - 1)
end

local function utf8Length(value)
    local ok, length = pcall(utf8.len, value)
    if ok and length ~= nil then
        return length
    end
    return #value
end

local function normalizeImmediateLevels(levels)
    local result = {}
    if type(levels) ~= "table" then
        return result
    end

    for key, value in pairs(levels) do
        if type(key) == "number" then
            if value == true then
                result[normalizeLevel(key, "Discord.ImmediateLevels")] = true
            else
                result[normalizeLevel(value, "Discord.ImmediateLevels")] = true
            end
        elseif value == true then
            result[normalizeLevel(key, "Discord.ImmediateLevels")] = true
        end
    end
    return result
end

local function getEnvironment()
    if type(getgenv) == "function" then
        local ok, environment = pcall(getgenv)
        if ok and type(environment) == "table" then
            return environment
        end
    end
    return _G
end

local function getEnvironmentFunction(name)
    local environment = getEnvironment()
    if type(environment[name]) == "function" then
        return environment[name]
    end
    if type(_G) == "table" and type(_G[name]) == "function" then
        return _G[name]
    end
    return nil
end

local function validateEnvironment(console, file, discord, onInternalError)
    local missing = {}

    local function requireFunction(available, name)
        if not available then
            table.insert(missing, name)
        end
    end

    requireFunction(type(os) == "table" and type(os.time) == "function", "os.time")
    requireFunction(type(os) == "table" and type(os.date) == "function", "os.date")
    requireFunction(type(table.pack) == "function", "table.pack")
    requireFunction(type(table.unpack) == "function", "table.unpack")

    if console.Enabled then
        requireFunction(type(print) == "function", "print")
        requireFunction(type(warn) == "function", "warn")
    elseif onInternalError == nil and (file.Enabled or discord.Enabled) then
        requireFunction(type(warn) == "function", "warn (or configure OnInternalError)")
    end

    local needsTaskScheduler = discord.Enabled or (file.Enabled and file.FlushInterval > 0)
    if needsTaskScheduler then
        requireFunction(type(task) == "table" and type(task.spawn) == "function", "task.spawn")
        requireFunction(type(task) == "table" and type(task.wait) == "function", "task.wait")
    end

    if file.Enabled and file.Adapter == nil then
        local hasAppend = getEnvironmentFunction("appendfile") ~= nil
        local hasReadWrite = getEnvironmentFunction("readfile") ~= nil
            and getEnvironmentFunction("writefile") ~= nil
        requireFunction(hasAppend or hasReadWrite, "appendfile or (readfile + writefile)")
    end

    if discord.Enabled then
        requireFunction(type(os) == "table" and type(os.clock) == "function", "os.clock")
        requireFunction(type(utf8) == "table" and type(utf8.len) == "function", "utf8.len")
        requireFunction(type(utf8) == "table" and type(utf8.offset) == "function", "utf8.offset")
        requireFunction(type(HttpService.JSONEncode) == "function", "HttpService.JSONEncode")
        requireFunction(type(HttpService.JSONDecode) == "function", "HttpService.JSONDecode")
    end

    if #missing > 0 then
        error("Logger environment is missing required functions: " .. table.concat(missing, ", "), 3)
    end
end

local function validateHttp(http)
    if type(http) ~= "table" then
        error("Logger.new requires an initialized HTTP module object as its second argument", 3)
    end

    if type(http.Request) ~= "function" and type(http.request) ~= "function" then
        error("HTTP module object must provide Request(options) or request(options)", 3)
    end
end

local DEFAULT_CONSOLE = {
    Enabled = true,
    Level = Logger.Level.INFO,
    Format = "{time} [{level}] {name}: {message}",
}

local DEFAULT_FILE = {
    Enabled = false,
    Level = Logger.Level.DEBUG,
    Path = "logger.log",
    Format = "{time} [{level}] {name}: {message}",
    BatchSize = 50,
    FlushInterval = 5,
    Adapter = nil,
}

local DEFAULT_DISCORD = {
    Enabled = false,
    Level = Logger.Level.WARNING,
    WebhookUrl = nil,
    Format = "[{level}] {name}: {message}",
    Username = nil,
    AvatarUrl = nil,
    UseProxy = nil,
    ImmediateLevels = {},
    BatchSize = 1,
    BatchInterval = 0.5,
    BatchSeparator = "\n",
    PollInterval = 0.1,
    BaseRetryDelay = 1,
    MaxRetryDelay = 60,
    MaxContentLength = 1900,
    AllowedMentions = { parse = {} },
}

function Logger.new(name, http, config)
    if type(name) ~= "string" or name == "" then
        error("Logger.new name must be a non-empty string", 2)
    end
    validateHttp(http)

    config = config or {}
    if type(config) ~= "table" then
        error("Logger.new config must be a table", 2)
    end

    local console = merge(DEFAULT_CONSOLE, config.Console)
    local file = merge(DEFAULT_FILE, config.File)
    local discord = merge(DEFAULT_DISCORD, config.Discord)

    console.Level = normalizeLevel(console.Level, "Console.Level")
    file.Level = normalizeLevel(file.Level, "File.Level")
    discord.Level = normalizeLevel(discord.Level, "Discord.Level")
    discord.ImmediateLevels = normalizeImmediateLevels(discord.ImmediateLevels)

    file.BatchSize = math.max(1, math.floor(tonumber(file.BatchSize) or DEFAULT_FILE.BatchSize))
    file.FlushInterval = math.max(0, tonumber(file.FlushInterval) or DEFAULT_FILE.FlushInterval)
    discord.BatchSize = math.min(100, math.max(1, math.floor(tonumber(discord.BatchSize) or DEFAULT_DISCORD.BatchSize)))
    discord.BatchInterval = math.max(0, tonumber(discord.BatchInterval) or DEFAULT_DISCORD.BatchInterval)
    discord.PollInterval = math.max(0.03, tonumber(discord.PollInterval) or DEFAULT_DISCORD.PollInterval)
    discord.BaseRetryDelay = math.max(0.1, tonumber(discord.BaseRetryDelay) or DEFAULT_DISCORD.BaseRetryDelay)
    discord.MaxRetryDelay = math.max(discord.BaseRetryDelay, tonumber(discord.MaxRetryDelay) or DEFAULT_DISCORD.MaxRetryDelay)
    discord.MaxContentLength = math.min(2000, math.max(1, math.floor(tonumber(discord.MaxContentLength) or DEFAULT_DISCORD.MaxContentLength)))

    if type(discord.BatchSeparator) ~= "string" then
        error("Discord.BatchSeparator must be a string", 2)
    end

    if file.Enabled and (type(file.Path) ~= "string" or file.Path == "") then
        error("File.Path must be a non-empty string when the file handler is enabled", 2)
    end
    if file.Adapter ~= nil and (type(file.Adapter) ~= "table" or type(file.Adapter.Append) ~= "function") then
        error("File.Adapter must provide Append(path, data)", 2)
    end
    if discord.Enabled and (type(discord.WebhookUrl) ~= "string" or discord.WebhookUrl == "") then
        error("Discord.WebhookUrl is required when the Discord handler is enabled", 2)
    end
    if config.OnInternalError ~= nil and type(config.OnInternalError) ~= "function" then
        error("OnInternalError must be a function", 2)
    end

    validateEnvironment(console, file, discord, config.OnInternalError)

    local self = setmetatable({
        Name = name,
        Level = normalizeLevel(config.Level or Logger.Level.DEBUG, "Logger.Level"),
        _http = http,
        _config = {
            Console = console,
            File = file,
            Discord = discord,
        },
        _onInternalError = config.OnInternalError,
        _accepting = true,
        _closed = false,
        _fileBuffer = {},
        _fileFlushing = false,
        _fileWorkerStarted = false,
        _discordQueue = {},
        _discordPriorityQueue = {},
        _discordFailed = {},
        _discordSending = false,
        _discordInFlightUnqueued = 0,
        _discordBlockedUntil = 0,
        _discordWorkerStarted = false,
        _discordStats = {
            Requests = 0,
            SuccessfulRequests = 0,
            DeliveredRecords = 0,
            RetryEvents = 0,
            FailedRecords = 0,
            LargestBatch = 0,
        },
    }, Logger)

    self:_ensureWorkers()
    return self
end

function Logger:_reportInternalError(component, message, details)
    if type(self._onInternalError) == "function" then
        pcall(self._onInternalError, component, message, details)
    else
        warn(string.format("[Logger/%s] %s", component, tostring(message)))
    end
end

function Logger:_handlerAccepts(handler, level)
    return handler.Enabled == true and level >= handler.Level
end

function Logger:_format(handler, record)
    return interpolate(tostring(handler.Format), record)
end

function Logger:_writeConsole(record)
    local line = self:_format(self._config.Console, record)
    if record.Level >= Logger.Level.WARNING then
        warn(line)
    else
        print(line)
    end
end

function Logger:_appendFile(data)
    local file = self._config.File
    if file.Adapter ~= nil then
        return pcall(file.Adapter.Append, file.Path, data)
    end

    local appendFile = getEnvironmentFunction("appendfile")
    if appendFile ~= nil then
        return pcall(appendFile, file.Path, data)
    end

    local readFile = getEnvironmentFunction("readfile")
    local writeFile = getEnvironmentFunction("writefile")
    local isFile = getEnvironmentFunction("isfile")
    if readFile == nil or writeFile == nil then
        return false, "appendfile or readfile+writefile is unavailable; provide File.Adapter"
    end

    local previous = ""
    if isFile ~= nil then
        local existsOk, exists = pcall(isFile, file.Path)
        if existsOk and exists then
            local readOk, contents = pcall(readFile, file.Path)
            if not readOk then
                return false, contents
            end
            previous = contents
        end
    else
        local readOk, contents = pcall(readFile, file.Path)
        if readOk then
            previous = contents
        end
    end

    return pcall(writeFile, file.Path, previous .. data)
end

function Logger:_queueFile(record)
    table.insert(self._fileBuffer, self:_format(self._config.File, record) .. "\n")
    if #self._fileBuffer >= self._config.File.BatchSize then
        self:FlushFile()
    end
end

function Logger:FlushFile()
    if self._fileFlushing or #self._fileBuffer == 0 then
        return true
    end

    self._fileFlushing = true
    local count = #self._fileBuffer
    local batch = {}
    for index = 1, count do
        batch[index] = self._fileBuffer[index]
    end

    local ok, result = self:_appendFile(table.concat(batch))
    if ok then
        for _ = 1, count do
            table.remove(self._fileBuffer, 1)
        end
    else
        self:_reportInternalError("File", "could not flush log batch", result)
    end
    self._fileFlushing = false
    return ok, result
end

function Logger:_makeDiscordItem(record)
    return {
        Record = record,
        Attempts = 0,
        NextAttemptAt = 0,
        QueuedAt = os.clock(),
    }
end

function Logger:_enqueueDiscord(item, priority)
    if priority then
        table.insert(self._discordPriorityQueue, item)
    else
        table.insert(self._discordQueue, item)
    end
end

function Logger:_discordPayload(content)
    local discord = self._config.Discord
    local payload = {
        content = content,
        allowed_mentions = discord.AllowedMentions,
    }

    if type(discord.Username) == "string" and discord.Username ~= "" then
        payload.username = discord.Username
    end
    if type(discord.AvatarUrl) == "string" and discord.AvatarUrl ~= "" then
        payload.avatar_url = discord.AvatarUrl
    end
    return payload
end

function Logger:_requestDiscord(content)
    local encoded, body = pcall(HttpService.JSONEncode, HttpService, self:_discordPayload(content))
    if not encoded then
        return {
            Success = false,
            StatusCode = -1,
            Error = "could not encode Discord payload: " .. tostring(body),
            Permanent = true,
        }
    end

    local options = {
        Url = self._config.Discord.WebhookUrl,
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
        },
        Body = body,
    }
    if self._config.Discord.UseProxy ~= nil then
        options.UseProxy = self._config.Discord.UseProxy == true
    end

    local request = self._http.Request or self._http.request
    self._discordStats.Requests = self._discordStats.Requests + 1
    local ok, response = pcall(request, self._http, options)
    if not ok then
        return {
            Success = false,
            StatusCode = 0,
            Error = tostring(response),
        }
    end
    if type(response) ~= "table" then
        return {
            Success = false,
            StatusCode = 0,
            Error = "HTTP module returned a non-table response",
        }
    end
    return response
end

function Logger:_retryAfter(response, attempts)
    local discord = self._config.Discord
    local headerDelay = tonumber(findHeader(response.Headers, "retry-after"))
        or tonumber(findHeader(response.Headers, "x-ratelimit-reset-after"))

    local bodyDelay = nil
    if type(response.Body) == "string" and response.Body ~= "" then
        local decoded, payload = pcall(HttpService.JSONDecode, HttpService, response.Body)
        if decoded and type(payload) == "table" then
            bodyDelay = tonumber(payload.retry_after)
        end
    end

    local specifiedDelay = bodyDelay or headerDelay
    if specifiedDelay ~= nil then
        return math.max(0.05, specifiedDelay)
    end

    return math.min(discord.MaxRetryDelay, discord.BaseRetryDelay * (2 ^ math.max(0, attempts - 1)))
end

function Logger:_deliverDiscord(items, content)
    local retryItem = items[1]
    local response = self:_requestDiscord(content)
    local statusCode = tonumber(response.StatusCode) or 0
    local success = response.Success == true or (statusCode >= 200 and statusCode < 300)
    if success then
        return "success", response
    end

    if response.Permanent == true then
        return "permanent", response
    end

    local retryable = statusCode == 0
        or statusCode == 408
        or statusCode == 425
        or statusCode == 429
        or statusCode >= 500

    if not retryable then
        return "permanent", response
    end

    retryItem.Attempts = retryItem.Attempts + 1
    self._discordStats.RetryEvents = self._discordStats.RetryEvents + 1
    local delay = self:_retryAfter(response, retryItem.Attempts)
    retryItem.NextAttemptAt = os.clock() + delay
    if statusCode == 429 then
        self._discordBlockedUntil = math.max(self._discordBlockedUntil, retryItem.NextAttemptAt)
    end

    self:_reportInternalError(
        "Discord",
        string.format("delivery failed; retrying in %.2f seconds", delay),
        response
    )
    return "retry", response
end

function Logger:_peekDiscordQueue(force)
    if #self._discordPriorityQueue > 0 then
        return self._discordPriorityQueue
    end
    if #self._discordQueue > 0 then
        local discord = self._config.Discord
        local oldest = self._discordQueue[1]
        local batchIsFull = #self._discordQueue >= discord.BatchSize
        local intervalElapsed = os.clock() - oldest.QueuedAt >= discord.BatchInterval
        if not force and not batchIsFull and not intervalElapsed then
            return nil
        end
        return self._discordQueue
    end
    return nil
end

function Logger:_buildDiscordBatch(sourceQueue)
    local discord = self._config.Discord
    local now = os.clock()
    local items = {}
    local lines = {}
    local contentLength = 0
    local separatorLength = utf8Length(discord.BatchSeparator)

    for index = 1, math.min(#sourceQueue, discord.BatchSize) do
        local item = sourceQueue[index]
        if item.NextAttemptAt > now then
            break
        end

        local line = truncateUtf8(self:_format(discord, item.Record), discord.MaxContentLength)
        local lineLength = utf8Length(line)
        local extraLength = lineLength
        if #lines > 0 then
            extraLength = extraLength + separatorLength
        end

        if #lines > 0 and contentLength + extraLength > discord.MaxContentLength then
            break
        end

        table.insert(items, item)
        table.insert(lines, line)
        contentLength = contentLength + extraLength
    end

    return items, table.concat(lines, discord.BatchSeparator)
end

function Logger:_processDiscordOnce(force)
    if self._discordSending or os.clock() < self._discordBlockedUntil then
        return false
    end

    local sourceQueue = self:_peekDiscordQueue(force == true)
    if sourceQueue == nil or os.clock() < sourceQueue[1].NextAttemptAt then
        return false
    end

    local items, content = self:_buildDiscordBatch(sourceQueue)
    if #items == 0 then
        return false
    end

    self._discordSending = true
    local outcome, response = self:_deliverDiscord(items, content)
    if outcome == "success" then
        self._discordStats.SuccessfulRequests = self._discordStats.SuccessfulRequests + 1
        self._discordStats.DeliveredRecords = self._discordStats.DeliveredRecords + #items
        self._discordStats.LargestBatch = math.max(self._discordStats.LargestBatch, #items)
        for _ = 1, #items do
            table.remove(sourceQueue, 1)
        end
    elseif outcome == "permanent" then
        self._discordStats.FailedRecords = self._discordStats.FailedRecords + #items
        for _ = 1, #items do
            local item = table.remove(sourceQueue, 1)
            table.insert(self._discordFailed, item)
        end
        self:_reportInternalError(
            "Discord",
            string.format("%d message(s) moved to the failed buffer", #items),
            response
        )
    end
    self._discordSending = false
    return true
end

function Logger:_sendDiscordImmediately(record)
    local item = self:_makeDiscordItem(record)
    if self._discordSending or os.clock() < self._discordBlockedUntil then
        self:_enqueueDiscord(item, true)
        return
    end

    self._discordSending = true
    self._discordInFlightUnqueued = 1
    local content = truncateUtf8(
        self:_format(self._config.Discord, item.Record),
        self._config.Discord.MaxContentLength
    )
    local outcome, response = self:_deliverDiscord({ item }, content)
    if outcome == "success" then
        self._discordStats.SuccessfulRequests = self._discordStats.SuccessfulRequests + 1
        self._discordStats.DeliveredRecords = self._discordStats.DeliveredRecords + 1
        self._discordStats.LargestBatch = math.max(self._discordStats.LargestBatch, 1)
    elseif outcome == "retry" then
        self:_enqueueDiscord(item, true)
    elseif outcome == "permanent" then
        self._discordStats.FailedRecords = self._discordStats.FailedRecords + 1
        table.insert(self._discordFailed, item)
        self:_reportInternalError("Discord", "immediate message moved to the failed buffer", response)
    end
    self._discordInFlightUnqueued = 0
    self._discordSending = false
end

function Logger:_queueDiscord(record)
    if self._config.Discord.ImmediateLevels[record.Level] == true then
        self:_sendDiscordImmediately(record)
    else
        self:_enqueueDiscord(self:_makeDiscordItem(record), false)
    end
end

function Logger:_ensureWorkers()
    local file = self._config.File
    if file.Enabled and file.FlushInterval > 0 and not self._fileWorkerStarted then
        self._fileWorkerStarted = true
        task.spawn(function()
            while not self._closed do
                task.wait(file.FlushInterval)
                if #self._fileBuffer > 0 then
                    self:FlushFile()
                end
            end
        end)
    end

    if self._config.Discord.Enabled and not self._discordWorkerStarted then
        self._discordWorkerStarted = true
        task.spawn(function()
            while not self._closed do
                if not self:_processDiscordOnce(false) then
                    task.wait(self._config.Discord.PollInterval)
                end
            end
        end)
    end
end

function Logger:Log(level, message, ...)
    if not self._accepting then
        error("cannot write to a logger that is closing or closed", 2)
    end

    level = normalizeLevel(level, "log level")
    if level < self.Level then
        return nil
    end

    local record = {
        Timestamp = os.time(),
        Time = nowIso(),
        Level = level,
        LevelName = LEVEL_NAMES[level] or tostring(level),
        LoggerName = self.Name,
        Message = formatMessage(message, ...),
    }

    if self:_handlerAccepts(self._config.Console, level) then
        self:_writeConsole(record)
    end
    if self:_handlerAccepts(self._config.File, level) then
        self:_queueFile(record)
    end
    if self:_handlerAccepts(self._config.Discord, level) then
        self:_queueDiscord(record)
    end

    return record
end

function Logger:Debug(message, ...)
    return self:Log(Logger.Level.DEBUG, message, ...)
end

function Logger:Info(message, ...)
    return self:Log(Logger.Level.INFO, message, ...)
end

function Logger:Warning(message, ...)
    return self:Log(Logger.Level.WARNING, message, ...)
end

function Logger:Error(message, ...)
    return self:Log(Logger.Level.ERROR, message, ...)
end

function Logger:Critical(message, ...)
    return self:Log(Logger.Level.CRITICAL, message, ...)
end

Logger.Warn = Logger.Warning
Logger.debug = Logger.Debug
Logger.info = Logger.Info
Logger.warning = Logger.Warning
Logger.warn = Logger.Warning
Logger.error = Logger.Error
Logger.critical = Logger.Critical
Logger.log = Logger.Log

function Logger:SetLevel(level)
    self.Level = normalizeLevel(level, "Logger.Level")
end

function Logger:SetHandlerLevel(handlerName, level)
    local normalizedName = HANDLER_NAMES[string.lower(tostring(handlerName))]
    if normalizedName == nil then
        error("unknown handler: " .. tostring(handlerName), 2)
    end
    self._config[normalizedName].Level = normalizeLevel(level, normalizedName .. ".Level")
end

function Logger:SetHandlerEnabled(handlerName, enabled)
    local normalizedName = HANDLER_NAMES[string.lower(tostring(handlerName))]
    if normalizedName == nil then
        error("unknown handler: " .. tostring(handlerName), 2)
    end
    if type(enabled) ~= "boolean" then
        error("enabled must be a boolean", 2)
    end

    local handler = self._config[normalizedName]
    if enabled and normalizedName == "Discord"
        and (type(handler.WebhookUrl) ~= "string" or handler.WebhookUrl == "")
    then
        error("Discord.WebhookUrl is required before enabling the Discord handler", 2)
    end
    if enabled then
        local previousEnabled = handler.Enabled
        handler.Enabled = true
        local environmentOk, environmentError = pcall(
            validateEnvironment,
            self._config.Console,
            self._config.File,
            self._config.Discord,
            self._onInternalError
        )
        if not environmentOk then
            handler.Enabled = previousEnabled
            error(environmentError, 2)
        end
        self:_ensureWorkers()
    else
        handler.Enabled = false
    end
end

function Logger:GetPendingDiscordCount()
    return #self._discordPriorityQueue + #self._discordQueue + self._discordInFlightUnqueued
end

function Logger:GetFailedDiscordMessages()
    local result = {}
    for index, item in ipairs(self._discordFailed) do
        result[index] = shallowCopy(item.Record)
    end
    return result
end

function Logger:GetDiscordStats()
    local result = shallowCopy(self._discordStats)
    result.PendingRecords = self:GetPendingDiscordCount()
    result.CurrentFailedRecords = #self._discordFailed
    return result
end

function Logger:RetryFailedDiscord()
    local failed = self._discordFailed
    self._discordFailed = {}
    for _, item in ipairs(failed) do
        item.Attempts = 0
        item.NextAttemptAt = 0
        self:_enqueueDiscord(item, true)
    end
    return #failed
end

function Logger:FlushDiscord(timeout)
    timeout = math.max(0, tonumber(timeout) or 10)
    local deadline = os.clock() + timeout

    while self:GetPendingDiscordCount() > 0 do
        self:_processDiscordOnce(true)
        if os.clock() >= deadline then
            return false, self:GetPendingDiscordCount()
        end
        task.wait(self._config.Discord.PollInterval)
    end
    return true, 0
end

function Logger:Flush(timeout)
    local fileOk, fileError = self:FlushFile()
    local discordOk, pending = self:FlushDiscord(timeout)
    return fileOk and discordOk, {
        FileOk = fileOk,
        FileError = fileError,
        DiscordOk = discordOk,
        DiscordPending = pending,
        DiscordFailed = #self._discordFailed,
    }
end

function Logger:Close(timeout)
    if self._closed then
        return true, {
            FileOk = true,
            DiscordOk = true,
            DiscordPending = 0,
            DiscordFailed = #self._discordFailed,
        }
    end

    self._accepting = false
    local ok, status = self:Flush(timeout)
    if ok then
        self._closed = true
    end
    return ok, status
end

return Logger
