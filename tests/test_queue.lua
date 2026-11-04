-- Standalone queue test. Run from the repository root:
--   lua tests/test_queue.lua
-- The real plugin runs inside KOReader; this harness stubs the few KOReader
-- modules the queue needs so the persistence and retry logic can be exercised
-- without a device.

local store = {}

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deep_copy(val) end
    return out
end

local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp" end }
end

package.preload["logger"] = function()
    return {
        dbg = function() end,
        info = function() end,
        warn = function() end,
    }
end

package.preload["util"] = function()
    return { tableEquals = deep_equal }
end

package.preload["persist"] = function()
    local Persist = {}
    function Persist:new(o)
        return setmetatable({ path = o.path }, { __index = self })
    end
    function Persist:exists()
        return store[self.path] ~= nil
    end
    function Persist:load()
        return deep_copy(store[self.path] or {})
    end
    function Persist:save(data)
        store[self.path] = deep_copy(data)
        return true
    end
    return Persist
end

local Queue = dofile("kosync2.koplugin/KOSync2Queue.lua")

Queue:clear()
Queue:push({ document = "a", metadata = { title = "Book A" }, progress = "10", percentage = 0.1 })
assert(Queue:count() == 1, "push count")

Queue:push({ document = "a", metadata = { title = "Book A" }, progress = "20", percentage = 0.2 })
assert(Queue:count() == 1, "same-day dedupe")
assert(Queue:load()[1].progress == "20", "dedupe keeps newest")
assert(Queue:load()[1].metadata.title == "Book A", "metadata survives queue")

Queue:push({ document = "b", progress = "5", percentage = 0.05 })
assert(Queue:count() == 2, "two documents")

Queue:removeDocument("a")
assert(Queue:count() == 1, "removeDocument")
assert(Queue:load()[1].document == "b", "removeDocument keeps other")

local sent = {}
Queue:drain(function(item, cb)
    sent[#sent + 1] = item.document
    cb(true)
end, function(n)
    assert(n == 1, "drain done count")
end)
assert(#sent == 1 and sent[1] == "b", "drain sends")
assert(Queue:count() == 0, "drain clears")

Queue:push({ document = "c", progress = "1", percentage = 0.01 })
Queue:drain(function(item, cb)
    cb(false)
end, function(n)
    assert(n == 0, "failed drain count")
end)
assert(Queue:count() == 1, "failed drain keeps item")

local item = Queue:load()[1]
assert(Queue:remove(item), "remove exact")
assert(Queue:count() == 0, "remove exact clears")

print("KOSync2Queue tests passed")
