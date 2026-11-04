local DataStorage = require("datastorage")
local Persist = require("persist")
local logger = require("logger")
local util = require("util")

-- Keep this separate from the built-in KOSync queue. KOReader puts every
-- plugin directory on package.path, so sharing either the module name or the
-- queue file would make both plugins read and write the same pending items.
local QUEUE_PATH = DataStorage:getSettingsDir() .. "/kosync2_queue.lua"
local MAX_AGE = 28 * 24 * 3600 -- 4 weeks in seconds
local MAX_ENTRIES = 200 -- paranoia cap

local KOSync2Queue = {
    _draining = nil,
}

function KOSync2Queue:_storage()
    if not self._persist then
        self._persist = Persist:new{
            path = QUEUE_PATH, codec = "dump" }
    end
    return self._persist
end

function KOSync2Queue:load()
    local storage = self:_storage()
    if not storage:exists() then return {} end
    local data, err = storage:load()
    if not data then
        logger.warn("KOSync2Queue: failed to load queue:", err)
        return {}
    end
    return data
end

function KOSync2Queue:save(queue)
    local ok, err = self:_storage():save(queue)
    if not ok then
        logger.warn("KOSync2Queue: failed to save queue:", err)
    end
end

--- Queue a failed progress update for later retry.
-- Keeps one entry per document per day (for statistics granularity).
-- Expires entries older than 4 weeks.
function KOSync2Queue:push(item)
    local queue = self:load()
    local now = os.time()
    item.queued_at = now

    local today = math.floor(now / 86400)

    -- Filter: expire old entries, deduplicate same document+same day
    local filtered = {}
    for _, entry in ipairs(queue) do
        local dominated = entry.document == item.document
            and math.floor((entry.queued_at or 0) / 86400) == today
        if (now - (entry.queued_at or 0)) < MAX_AGE and not dominated then
            table.insert(filtered, entry)
        end
    end

    table.insert(filtered, item)

    -- Paranoia cap: drop oldest
    while #filtered > MAX_ENTRIES do
        table.remove(filtered, 1)
    end

    self:save(filtered)
    logger.dbg("KOSync2Queue: queued progress for", item.document, "total:", #filtered)
end

--- Remove one exact entry from the queue.
-- Used when a queued item has been superseded by a newer server state, or
-- when a previous queued item has already been sent by another code path.
function KOSync2Queue:remove(item)
    local queue = self:load()
    for i, entry in ipairs(queue) do
        if util.tableEquals(entry, item) then
            table.remove(queue, i)
            self:save(queue)
            return true
        end
    end
    return false
end

--- Drop every queued entry for a document.
-- Called after a successful push so an older queued snapshot can never
-- overwrite the progress we just uploaded.
function KOSync2Queue:removeDocument(document)
    local queue = self:load()
    local filtered = {}
    local removed = 0
    for _, entry in ipairs(queue) do
        if entry.document == document then
            removed = removed + 1
        else
            table.insert(filtered, entry)
        end
    end
    if removed > 0 then
        self:save(filtered)
        logger.dbg("KOSync2Queue: dropped", removed, "queued item(s) for", document)
    end
end

--- Attempt to send all queued items in order, stopping on the first failure.
-- @param send_func function(item, callback): reports success through callback(bool)
-- @param done_func optional function(sent): called when the drain finishes
function KOSync2Queue:drain(send_func, done_func)
    -- Network events may arrive while an asynchronous request is still in flight.
    if self._draining then return end
    local queue = self:load()
    if #queue == 0 then
        if done_func then done_func(0) end
        return
    end
    self._draining = true

    logger.info("KOSync2Queue: draining", #queue, "queued items")
    local sent = 0
    local settled = false

    -- Both failure and queue exhaustion complete the drain exactly once.
    local function settle()
        if settled then return end
        settled = true
        self._draining = nil
        local ok, remaining = pcall(self.count, self)
        logger.info("KOSync2Queue: sent", sent, ", remaining", ok and remaining or "unknown")
        if done_func then done_func(sent) end
    end

    local function fail(err)
        if err then
            logger.warn("KOSync2Queue: drain failed:", err)
        end
        settle()
    end

    local function findItem(current, item)
        for i, entry in ipairs(current) do
            -- Compare the contents too: a same-day replacement can have the same
            -- document and queued_at when it was queued within the same second.
            if util.tableEquals(entry, item) then return i end
        end
    end

    local function sendNext(i)
        if settled then return end
        local item = queue[i]
        if not item then
            settle()
            return
        end
        -- Do not send snapshot entries that have since been replaced or cleared.
        local ok_load, current_queue = pcall(self.load, self)
        if not ok_load then
            fail(current_queue)
            return
        end
        if not findItem(current_queue, item) then
            logger.dbg("KOSync2Queue: skipping replaced or cleared progress for", item.document)
            sendNext(i + 1)
            return
        end
        local completed = false
        local function callback(ok)
            if settled or completed then return end
            completed = true
            if not ok then
                fail()
                return
            end
            -- Reload after the request: pushes may have changed the queue in flight.
            local ok_book, err = pcall(function()
                local current = self:load()
                local index = findItem(current, item)
                if index then
                    table.remove(current, index)
                    self:save(current)
                end
                sent = sent + 1
            end)
            if not ok_book then
                fail(err)
                return
            end
            sendNext(i + 1)
        end
        local ok, err = pcall(send_func, item, callback)
        if not ok then
            logger.warn("KOSync2Queue: failed to send queued progress:", err)
            callback(false)
        end
    end

    sendNext(1)
end

function KOSync2Queue:count()
    return #self:load()
end

function KOSync2Queue:clear()
    self:save({})
end

return KOSync2Queue
