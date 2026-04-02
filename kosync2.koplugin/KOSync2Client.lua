local UIManager = require("ui/uimanager")
local logger = require("logger")
local socketutil = require("socketutil")

local PROGRESS_TIMEOUTS = { 2, 5 }
local SYNC_TIMEOUTS = { 10, 45 }
local AUTH_TIMEOUTS = { 5, 10 }

local KOSync2Client = {
    service_spec = nil,
    custom_url = nil,
}

function KOSync2Client:new(o)
    if o == nil then o = {} end
    setmetatable(o, self)
    self.__index = self
    if o.init then o:init() end
    return o
end

function KOSync2Client:init()
    local Spore = require("Spore")
    self.client = Spore.new_from_spec(self.service_spec, {
        base_url = self.custom_url,
    })

    package.loaded["Spore.Middleware.KOSync2GinClient"] = {}
    require("Spore.Middleware.KOSync2GinClient").call = function(_, req)
        req.headers["accept"] = "application/vnd.koreader.v1+json"
        req.headers["x-client-version"] = "y-anna-1.0"
        req.headers["user-agent"] = "Mozilla/DONTLIKE/ANYTHING"
    end

    package.loaded["Spore.Middleware.KOSync2Auth"] = {}
    require("Spore.Middleware.KOSync2Auth").call = function(args, req)
        req.headers["x-auth-user"] = args.username
        req.headers["x-auth-key"] = args.userkey
    end

    package.loaded["Spore.Middleware.KOSync2AsyncHTTP"] = {}
    require("Spore.Middleware.KOSync2AsyncHTTP").call = function(args, req)
        if not UIManager.looper then return end
        req:finalize()
        local result
        require("httpclient"):new():request({
            url = req.url,
            method = req.method,
            body = req.env.spore.payload,
            on_headers = function(headers)
                for header, value in pairs(req.headers) do
                    if type(header) == "string" then
                        headers:add(header, value)
                    end
                end
            end,
        }, function(res)
            result = res
            result.status = res.code
            coroutine.resume(args.thread)
        end)
        return coroutine.create(function() coroutine.yield(result) end)
    end
end

function KOSync2Client:register(username, password)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("KOSync2GinClient")
    socketutil:set_timeout(AUTH_TIMEOUTS[1], AUTH_TIMEOUTS[2])
    local ok, res = pcall(function()
        return self.client:register({
            username = username,
            password = password,
        })
    end)
    socketutil:reset_timeout()
    if ok then
        return res.status == 201, res.body
    else
        logger.warn("KOSync2Client:register failure:", res)
        return false, res.body
    end
end

function KOSync2Client:authorize(username, password)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("KOSync2GinClient")
    self.client:enable("KOSync2Auth", {
        username = username,
        userkey = password,
    })
    socketutil:set_timeout(AUTH_TIMEOUTS[1], AUTH_TIMEOUTS[2])
    local ok, res = pcall(function()
        return self.client:authorize()
    end)
    socketutil:reset_timeout()
    if ok then
        return res.status == 200, res.body
    else
        logger.warn("KOSync2Client:authorize failure:", res)
        return false, res.body
    end
end

function KOSync2Client:sync_statistics(username, userkey, payload, callback)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("KOSync2GinClient")
    self.client:enable("KOSync2Auth", {
        username = username,
        userkey = userkey,
    })

    socketutil:set_timeout(SYNC_TIMEOUTS[1], SYNC_TIMEOUTS[2])

    local co = coroutine.create(function()
        local ok, res = pcall(function()
            return self.client:sync_statistics(payload)
        end)
        if ok then
            callback(res.status == 200 or res.status == 202, res.body, res.status)
        else
            logger.warn("KOSync2Client:sync_statistics failure:", res)
            local error_body = type(res) == "table" and res.body or nil
            callback(false, error_body, nil)
        end
    end)
    self.client:enable("KOSync2AsyncHTTP", {thread = co})
    coroutine.resume(co)
    if UIManager.looper then UIManager:setInputTimeout() end
    socketutil:reset_timeout()
end

function KOSync2Client:update_progress(
        username,
        password,
        document,
        progress,
        percentage,
        device,
        device_id,
        callback)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("KOSync2GinClient")
    self.client:enable("KOSync2Auth", {
        username = username,
        userkey = password,
    })
    -- Set *very* tight timeouts to avoid blocking for too long...
    socketutil:set_timeout(PROGRESS_TIMEOUTS[1], PROGRESS_TIMEOUTS[2])
    local co = coroutine.create(function()
        local ok, res = pcall(function()
            return self.client:update_progress({
                document = document,
                progress = tostring(progress),
                percentage = percentage,
                device = device,
                device_id = device_id,
            })
        end)
        if ok then
            callback(res.status == 200, res.body)
        else
            logger.warn("KOSync2Client:update_progress failure:", res)
            callback(false, res.body)
        end
    end)
    self.client:enable("KOSync2AsyncHTTP", {thread = co})
    coroutine.resume(co)
    if UIManager.looper then UIManager:setInputTimeout() end
    socketutil:reset_timeout()
end

function KOSync2Client:get_progress(
        username,
        password,
        document,
        callback)
    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("KOSync2GinClient")
    self.client:enable("KOSync2Auth", {
        username = username,
        userkey = password,
    })
    socketutil:set_timeout(PROGRESS_TIMEOUTS[1], PROGRESS_TIMEOUTS[2])
    local co = coroutine.create(function()
        local ok, res = pcall(function()
            return self.client:get_progress({
                document = document,
            })
        end)
        if ok then
            callback(res.status == 200, res.body)
        else
            logger.warn("KOSync2Client:get_progress failure:", res)
            callback(false, res.body)
        end
    end)
    self.client:enable("KOSync2AsyncHTTP", {thread = co})
    coroutine.resume(co)
    if UIManager.looper then UIManager:setInputTimeout() end
    socketutil:reset_timeout()
end

return KOSync2Client
