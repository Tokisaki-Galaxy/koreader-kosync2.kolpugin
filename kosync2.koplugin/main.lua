local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Math = require("optmath")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local time = require("ui/time")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local statistics_db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local KOSync2 = WidgetContainer:extend{
    name = "kosync2",
    is_doc_only = true,
    title = _("Register/login to sync server"),

    push_timestamp = nil,
    pull_timestamp = nil,
    page_update_counter = nil,
    last_page = nil,
    last_page_turn_timestamp = nil,
    periodic_push_task = nil,
    periodic_push_scheduled = nil,

    settings = nil,
}

local SYNC_STRATEGY = {
    PROMPT  = 1,
    SILENT  = 2,
    DISABLE = 3,
}

local CHECKSUM_METHOD = {
    BINARY = 0,
    FILENAME = 1
}

-- Debounce push/pull attempts
local API_CALL_DEBOUNCE_DELAY = time.s(25)

-- NOTE: This is used in a migration script by ui/data/onetime_migration,
--       which is why it's public.
KOSync2.default_settings = {
    custom_server = nil,
    username = nil,
    userkey = nil,
    -- Do *not* default to auto-sync, as wifi may not be on at all times, and the nagging enabling this may cause requires careful consideration.
    auto_sync = false,
    pages_before_update = nil,
    sync_forward = SYNC_STRATEGY.PROMPT,
    sync_backward = SYNC_STRATEGY.DISABLE,
    checksum_method = CHECKSUM_METHOD.BINARY,
    auto_sync_stats = false,
}

function KOSync2:init()
    self.push_timestamp = 0
    self.pull_timestamp = 0
    self.page_update_counter = 0
    self.last_page = -1
    self.last_page_turn_timestamp = 0
    self.periodic_push_scheduled = false

    -- Like AutoSuspend, we need an instance-specific task for scheduling/resource management reasons.
    self.periodic_push_task = function()
        self.periodic_push_scheduled = false
        self.page_update_counter = 0
        -- We do *NOT* want to make sure networking is up here, as the nagging would be extremely annoying; we're leaving that to the network activity check...
        self:updateProgress(false, false)
    end

    self.settings = G_reader_settings:readSetting("kosync2", self.default_settings)
    self.device_id = G_reader_settings:readSetting("device_id")

    -- Disable auto-sync if beforeWifiAction was reset to "prompt" behind our back...
    if self.settings.auto_sync and Device:hasSeamlessWifiToggle() and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
        self.settings.auto_sync = false
        logger.warn("KOSync2: Automatic sync has been disabled because wifi_enable_action is *not* turn_on")
    end

    self.ui.menu:registerToMainMenu(self)
end

function KOSync2:getSyncPeriod()
    if not self.settings.auto_sync then
        return _("Not available")
    end

    local period = self.settings.pages_before_update
    if period and period > 0 then
        return period
    else
        return _("Never")
    end
end

local function getNameStrategy(type)
    if type == 1 then
        return _("Prompt")
    elseif type == 2 then
        return _("Auto")
    else
        return _("Disable")
    end
end

local function showSyncedMessage()
    UIManager:show(InfoMessage:new{
        text = _("Progress has been synchronized."),
        timeout = 3,
    })
end

local function promptLogin()
    UIManager:show(InfoMessage:new{
        text = _("Please register or login before using the progress synchronization feature."),
        timeout = 3,
    })
end

local function showSyncError()
    UIManager:show(InfoMessage:new{
        text = _("Something went wrong when syncing progress, please check your network connection and try again later."),
        timeout = 3,
    })
end

local function validate(entry)
    if not entry then return false end
    if type(entry) == "string" then
        if entry == "" or not entry:match("%S") then return false end
    end
    return true
end

local function validateUser(user, pass)
    local error_message = nil
    local user_ok = validate(user)
    local pass_ok = validate(pass)
    if not user_ok and not pass_ok then
        error_message = _("invalid username and password")
    elseif not user_ok then
        error_message = _("invalid username")
    elseif not pass_ok then
        error_message = _("invalid password")
    end

    if not error_message then
        return user_ok and pass_ok
    else
        return user_ok and pass_ok, error_message
    end
end

function KOSync2:onDispatcherRegisterActions()
    Dispatcher:registerAction("kosync_set_autosync",
        { category="string", event="KOSync2ToggleAutoSync", title=_("Set auto progress sync"), reader=true,
        args={true, false}, toggle={_("on"), _("off")},})
    Dispatcher:registerAction("kosync_toggle_autosync", { category="none", event="KOSync2ToggleAutoSync", title=_("Toggle auto progress sync"), reader=true,})
    Dispatcher:registerAction("kosync_push_progress", { category="none", event="KOSync2PushProgress", title=_("Push progress from this device"), reader=true,})
    Dispatcher:registerAction("kosync_pull_progress", { category="none", event="KOSync2PullProgress", title=_("Pull progress from other devices"), reader=true, separator=true,})
end

function KOSync2:onReaderReady()
    if self.settings.auto_sync then
        UIManager:nextTick(function()
            self:getProgress(true, false)
        end)
    end
    -- NOTE: Keep in mind that, on Android, turning on WiFi requires a focus switch, which will trip a Suspend/Resume pair.
    --       NetworkMgr will attempt to hide the damage to avoid a useless pull -> push -> pull dance instead of the single pull requested.
    --       Plus, if wifi_enable_action is set to prompt, that also avoids stacking three prompts on top of each other...
    self:registerEvents()
    self:onDispatcherRegisterActions()

    self.last_page = self.ui:getCurrentPage()
end

function KOSync2:addToMainMenu(menu_items)
    menu_items.progress_sync2 = {
        text = _("Progress & Statistics sync"),
        sub_item_table = {
            {
                text = _("Custom sync server"),
                keep_menu_open = true,
                tap_input_func = function()
                    return {
                        -- @translators Server address defined by user for progress sync.
                        title = _("Custom progress sync server address"),
                        input = self.settings.custom_server or "https://",
                        callback = function(input)
                            self:setCustomServer(input)
                        end,
                    }
                end,
            },
            {
                text = _("Device hostname"),
                keep_menu_open = true,
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        -- @translators Name of this device defined by user for progress sync (if different than default device name)
                        title = _("Hostname for sync"),
                        input = self.settings.kosync_hostname,
                        input_hint = _("Leave empty to use default"),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(dialog)
                                    end,
                                },
                                {
                                    text = _("OK"),
                                    is_enter_default = true,
                                    callback = function()
                                        local hostname = dialog:getInputText()
                                        logger.dbg("KOSync2: Setting custom hostname to:", hostname)
                                        self.settings.kosync_hostname = hostname ~= "" and hostname or nil
                                        UIManager:close(dialog)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
            {
                text_func = function()
                    return self.settings.userkey and (_("Logout"))
                        or _("Register") .. " / " .. _("Login")
                end,
                keep_menu_open = true,
                callback_func = function()
                    if self.settings.userkey then
                        return function(menu)
                            self:logout(menu)
                        end
                    else
                        return function(menu)
                            self:login(menu)
                        end
                    end
                end,
                separator = true,
            },
            {
                text = _("Automatically keep documents in sync"),
                checked_func = function() return self.settings.auto_sync end,
                help_text = _([[This may lead to nagging about toggling WiFi on document close and suspend/resume, depending on the device's connectivity.]]),
                callback = function()
                    self:onKOSync2ToggleAutoSync(nil, true)
                end,
            },
            {
                text_func = function()
                    return T(_("Periodically sync every # pages (%1)"), self:getSyncPeriod())
                end,
                enabled_func = function() return self.settings.auto_sync end,
                -- This is the condition that allows enabling auto_disable_wifi in NetworkManager ;).
                help_text = NetworkMgr:getNetworkInterfaceName() and _([[Unlike the automatic sync above, this will *not* attempt to setup a network connection, but instead relies on it being already up, and may trigger enough network activity to passively keep WiFi enabled!]]),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local items = SpinWidget:new{
                        text = _([[This value determines how many page turns it takes to update book progress.
If set to 0, updating progress based on page turns will be disabled.]]),
                        value = self.settings.pages_before_update or 0,
                        value_min = 0,
                        value_max = 999,
                        value_step = 1,
                        value_hold_step = 10,
                        ok_text = _("Set"),
                        title_text = _("Number of pages before update"),
                        default_value = 0,
                        callback = function(spin)
                            self:setPagesBeforeUpdate(spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end
                    }
                    UIManager:show(items)
                end,
                separator = true,
            },
            {
                text = _("Sync behavior"),
                sub_item_table = {
                    {
                        text_func = function()
                            -- NOTE: With an up-to-date Sync server, "forward" means *newer*, not necessarily ahead in the document.
                            return T(_("Sync to a newer state (%1)"), getNameStrategy(self.settings.sync_forward))
                        end,
                        sub_item_table = {
                            {
                                text = _("Silently"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.SILENT
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.SILENT)
                                end,
                            },
                            {
                                text = _("Prompt"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.PROMPT
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.PROMPT)
                                end,
                            },
                            {
                                text = _("Never"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.DISABLE
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.DISABLE)
                                end,
                            },
                        }
                    },
                    {
                        text_func = function()
                            return T(_("Sync to an older state (%1)"), getNameStrategy(self.settings.sync_backward))
                        end,
                        sub_item_table = {
                            {
                                text = _("Silently"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.SILENT
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.SILENT)
                                end,
                            },
                            {
                                text = _("Prompt"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.PROMPT
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.PROMPT)
                                end,
                            },
                            {
                                text = _("Never"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.DISABLE
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.DISABLE)
                                end,
                            },
                        }
                    },
                },
                separator = true,
            },
            {
                text = _("Push progress from this device now"),
                enabled_func = function()
                    return self.settings.userkey ~= nil
                end,
                callback = function()
                    self:updateProgress(true, true)
                end,
            },
            {
                text = _("Pull progress from other devices now"),
                enabled_func = function()
                    return self.settings.userkey ~= nil
                end,
                callback = function()
                    self:getProgress(true, true)
                end,
                separator = true,
            },
            {
                text = _("Document matching method"),
                sub_item_table = {
                    {
                        text = _("Binary. Only identical files will be kept in sync."),
                        checked_func = function()
                            return self.settings.checksum_method == CHECKSUM_METHOD.BINARY
                        end,
                        callback = function()
                            self:setChecksumMethod(CHECKSUM_METHOD.BINARY)
                        end,
                    },
                    {
                        text = _("Filename. Files with matching names will be kept in sync."),
                        checked_func = function()
                            return self.settings.checksum_method == CHECKSUM_METHOD.FILENAME
                        end,
                        callback = function()
                            self:setChecksumMethod(CHECKSUM_METHOD.FILENAME)
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Statistics sync"),
                sub_item_table = {
                    {
                        text = _("Sync statistics now"),
                        enabled_func = function()
                            return self.settings.userkey ~= nil
                        end,
                        callback = function()
                            self:syncStatistics()
                        end,
                    },
                    {
                        text = _("Automatically sync statistics on book close"),
                        checked_func = function()
                            return self.settings.auto_sync_stats
                        end,
                        callback = function()
                            self.settings.auto_sync_stats = not self.settings.auto_sync_stats
                            self:registerEvents()
                        end,
                    },
                }
            },
        }
    }
end

function KOSync2:setPagesBeforeUpdate(pages_before_update)
    self.settings.pages_before_update = pages_before_update > 0 and pages_before_update or nil
end

function KOSync2:setCustomServer(server)
    logger.dbg("KOSync2: Setting custom server to:", server)
    self.settings.custom_server = server ~= "" and server or nil
end

function KOSync2:setSyncForward(strategy)
    self.settings.sync_forward = strategy
end

function KOSync2:setSyncBackward(strategy)
    self.settings.sync_backward = strategy
end

function KOSync2:setChecksumMethod(method)
    self.settings.checksum_method = method
end

function KOSync2:login(menu)
    if NetworkMgr:willRerunWhenOnline(function() self:login(menu) end) then
        return
    end

    local dialog
    dialog = MultiInputDialog:new{
        title = self.title,
        fields = {
            {
                text = self.settings.username,
                hint = "username",
            },
            {
                hint = "password",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Login"),
                    callback = function()
                        local username, password = unpack(dialog:getFields())
                        username = util.trim(username)
                        local ok, err = validateUser(username, password)
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                text = T(_("Cannot login: %1"), err),
                                timeout = 2,
                            })
                        else
                            UIManager:close(dialog)
                            UIManager:scheduleIn(0.5, function()
                                self:doLogin(username, password, menu)
                            end)
                            UIManager:show(InfoMessage:new{
                                text = _("Logging in. Please wait…"),
                                timeout = 1,
                            })
                        end
                    end,
                },
                {
                    text = _("Register"),
                    callback = function()
                        local username, password = unpack(dialog:getFields())
                        username = util.trim(username)
                        local ok, err = validateUser(username, password)
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                text = T(_("Cannot register: %1"), err),
                                timeout = 2,
                            })
                        else
                            UIManager:close(dialog)
                            UIManager:scheduleIn(0.5, function()
                                self:doRegister(username, password, menu)
                            end)
                            UIManager:show(InfoMessage:new{
                                text = _("Registering. Please wait…"),
                                timeout = 1,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KOSync2:doRegister(username, password, menu)
    local KOSync2Client = require("KOSync2Client")
    local client = KOSync2Client:new{
        custom_url = self.settings.custom_server,
        service_spec = self.path .. "/api.json"
    }
    -- on Android to avoid ANR (no-op on other platforms)
    Device:setIgnoreInput(true)
    local userkey = md5(password)
    local ok, status, body = pcall(client.register, client, username, userkey)
    if not ok then
        if status then
            UIManager:show(InfoMessage:new{
                text = _("An error occurred while registering:") ..
                    "\n" .. status,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("An unknown error occurred while registering."),
            })
        end
    elseif status then
        self.settings.username = username
        self.settings.userkey = userkey
        if menu then
            menu:updateItems()
        end
        UIManager:show(InfoMessage:new{
            text = _("Registered to KOReader server."),
        })
    else
        UIManager:show(InfoMessage:new{
            text = body and body.message or _("Unknown server error"),
        })
    end
    Device:setIgnoreInput(false)
end

function KOSync2:doLogin(username, password, menu)
    local KOSync2Client = require("KOSync2Client")
    local client = KOSync2Client:new{
        custom_url = self.settings.custom_server,
        service_spec = self.path .. "/api.json"
    }
    Device:setIgnoreInput(true)
    local userkey = md5(password)
    local ok, status, body = pcall(client.authorize, client, username, userkey)
    if not ok then
        if status then
            UIManager:show(InfoMessage:new{
                text = _("An error occurred while logging in:") ..
                    "\n" .. status,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("An unknown error occurred while logging in."),
            })
        end
        Device:setIgnoreInput(false)
        return
    elseif status then
        self.settings.username = username
        self.settings.userkey = userkey
        if menu then
            menu:updateItems()
        end
        UIManager:show(InfoMessage:new{
            text = _("Logged in to KOReader server."),
        })
    else
        UIManager:show(InfoMessage:new{
            text = body and body.message or _("Unknown server error"),
        })
    end
    Device:setIgnoreInput(false)
end

function KOSync2:logout(menu)
    self.settings.userkey = nil
    self.settings.auto_sync = true
    if menu then
        menu:updateItems()
    end
end

function KOSync2:getLastPercent()
    if self.ui.document.info.has_pages then
        return Math.roundPercent(self.ui.paging:getLastPercent())
    else
        return Math.roundPercent(self.ui.rolling:getLastPercent())
    end
end

function KOSync2:getLastProgress()
    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastProgress()
    else
        return self.ui.rolling:getLastProgress()
    end
end

function KOSync2:getDocumentDigest()
    if self.settings.checksum_method == CHECKSUM_METHOD.FILENAME then
        return self:getFileNameDigest()
    else
        return self:getFileDigest()
    end
end

function KOSync2:getFileDigest()
    return self.ui.doc_settings:readSetting("partial_md5_checksum")
end

function KOSync2:getFileNameDigest()
    local file = self.ui.document.file
    if not file then return end

    local file_path, file_name = util.splitFilePathName(file) -- luacheck: no unused
    if not file_name then return end

    return md5(file_name)
end

function KOSync2:syncToProgress(progress)
    logger.dbg("KOSync2: [Sync] progress to", progress)
    if self.ui.document.info.has_pages then
        self.ui:handleEvent(Event:new("GotoPage", tonumber(progress)))
    else
        self.ui:handleEvent(Event:new("GotoXPointer", progress))
    end
end

function KOSync2:updateProgress(ensure_networking, interactive, on_suspend)
    if not self.settings.username or not self.settings.userkey then
        if interactive then
            promptLogin()
        end
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    if not interactive and now - self.push_timestamp <= API_CALL_DEBOUNCE_DELAY then
        logger.dbg("KOSync2: We've already pushed progress less than 25s ago!")
        return
    end

    if ensure_networking and NetworkMgr:willRerunWhenOnline(function() self:updateProgress(ensure_networking, interactive, on_suspend) end) then
        return
    end

    local KOSync2Client = require("KOSync2Client")
    local client = KOSync2Client:new{
        custom_url = self.settings.custom_server,
        service_spec = self.path .. "/api.json"
    }
    local doc_digest = self:getDocumentDigest()
    local progress = self:getLastProgress()
    local percentage = self:getLastPercent()
    local chosen_device_name = self.settings.kosync_hostname or Device.model
    local ok, err = pcall(client.update_progress,
        client,
        self.settings.username,
        self.settings.userkey,
        doc_digest,
        progress,
        percentage,
        chosen_device_name,
        self.device_id,
        function(ok, body)
            logger.dbg("KOSync2: [Push] progress to", percentage * 100, "% =>", progress, "for", self.view.document.file)
            logger.dbg("KOSync2: ok:", ok, "body:", body)
            if interactive then
                if ok then
                    UIManager:show(InfoMessage:new{
                        text = _("Progress has been pushed."),
                        timeout = 3,
                    })
                else
                    showSyncError()
                end
            end
        end)
    if not ok then
        if interactive then showSyncError() end
        if err then logger.dbg("err:", err) end
    else
        -- This is solely for onSuspend's sake, to clear the ghosting left by the "Connected" InfoMessage
        if on_suspend then
            -- Our top-level widget should be the "Connected to network" InfoMessage from NetworkMgr's reconnectOrShowNetworkMenu
            local widget = UIManager:getTopmostVisibleWidget()
            if widget and widget.modal and widget.tag == "NetworkMgr" and not widget.dismiss_callback then
                -- We want a full-screen flash on dismiss
                widget.dismiss_callback = function()
                    -- Enqueued, because we run before the InfoMessage's close
                    UIManager:setDirty(nil, "full")
                end
            end
        end
    end

    if on_suspend then
        -- NOTE: We want to murder Wi-Fi once we're done in this specific case (i.e., Suspend),
        --       because some of our hasWifiManager targets will horribly implode when attempting to suspend with the Wi-Fi chip powered on,
        --       and they'll have attempted to kill Wi-Fi well before *we* run (e.g., in `Device:onPowerEvent`, *before* actually sending the Suspend Event)...
        if Device:hasWifiManager() then
            NetworkMgr:disableWifi()
        end
    end

    self.push_timestamp = now
end

function KOSync2:getProgress(ensure_networking, interactive)
    if not self.settings.username or not self.settings.userkey then
        if interactive then
            promptLogin()
        end
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    if not interactive and now - self.pull_timestamp <= API_CALL_DEBOUNCE_DELAY then
        logger.dbg("KOSync2: We've already pulled progress less than 25s ago!")
        return
    end

    if ensure_networking and NetworkMgr:willRerunWhenOnline(function() self:getProgress(ensure_networking, interactive) end) then
        return
    end

    local KOSync2Client = require("KOSync2Client")
    local client = KOSync2Client:new{
        custom_url = self.settings.custom_server,
        service_spec = self.path .. "/api.json"
    }
    local doc_digest = self:getDocumentDigest()
    local ok, err = pcall(client.get_progress,
        client,
        self.settings.username,
        self.settings.userkey,
        doc_digest,
        function(ok, body)
            logger.dbg("KOSync2: [Pull] progress for", self.view.document.file)
            logger.dbg("KOSync2: ok:", ok, "body:", body)
            if not ok or not body then
                if interactive then
                    showSyncError()
                end
                return
            end

            if not body.percentage then
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("No progress found for this document."),
                        timeout = 3,
                    })
                end
                return
            end

            if body.device == Device.model
            and body.device_id == self.device_id then
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("Latest progress is coming from this device."),
                        timeout = 3,
                    })
                end
                return
            end

            body.percentage = Math.roundPercent(body.percentage)
            local progress = self:getLastProgress()
            local percentage = self:getLastPercent()
            logger.dbg("KOSync2: Current progress:", percentage * 100, "% =>", progress)

            if percentage == body.percentage
            or body.progress == progress then
                if interactive then
                    UIManager:show(InfoMessage:new{
                        text = _("The progress has already been synchronized."),
                        timeout = 3,
                    })
                end
                return
            end

            -- The progress needs to be updated.
            if interactive then
                -- If user actively pulls progress from other devices,
                -- we always update the progress without further confirmation.
                self:syncToProgress(body.progress)
                showSyncedMessage()
                return
            end

            local self_older
            if body.timestamp ~= nil then
                self_older = (body.timestamp > self.last_page_turn_timestamp)
            else
                -- If we are working with an old sync server, we can only use the percentage field.
                self_older = (body.percentage > percentage)
            end
            if self_older then
                if self.settings.sync_forward == SYNC_STRATEGY.SILENT then
                    self:syncToProgress(body.progress)
                    showSyncedMessage()
                elseif self.settings.sync_forward == SYNC_STRATEGY.PROMPT then
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Sync to latest location %1% from device '%2'?"),
                                 Math.round(body.percentage * 100),
                                 body.device),
                        ok_callback = function()
                            self:syncToProgress(body.progress)
                        end,
                    })
                end
            else -- if not self_older then
                if self.settings.sync_backward == SYNC_STRATEGY.SILENT then
                    self:syncToProgress(body.progress)
                    showSyncedMessage()
                elseif self.settings.sync_backward == SYNC_STRATEGY.PROMPT then
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Sync to previous location %1% from device '%2'?"),
                                 Math.round(body.percentage * 100),
                                 body.device),
                        ok_callback = function()
                            self:syncToProgress(body.progress)
                        end,
                    })
                end
            end
        end)
    if not ok then
        if interactive then showSyncError() end
        if err then logger.dbg("err:", err) end
    end

    self.pull_timestamp = now
end

function KOSync2:_onCloseDocument()
    logger.dbg("KOSync2: onCloseDocument")
    -- NOTE: Because everything is terrible, on Android, opening the system settings to enable WiFi means we lose focus,
    --       and we handle those system focus events via... Suspend & Resume events, so we need to neuter those handlers early.
    self.onResume = nil
    self.onSuspend = nil
    -- NOTE: Because we'll lose the document instance on return, we need to *block* until the connection is actually up here,
    --       we cannot rely on willRerunWhenOnline, because if we're not currently online,
    --       it *will* return early, and that means the actual callback *will* run *after* teardown of the document instance
    --       (and quite likely ours, too).
    NetworkMgr:goOnlineToRun(function()
        -- Drop the inner willRerunWhenOnline ;).
        if self.settings.auto_sync then
            self:updateProgress(false, false)
        end
        -- Sync statistics if auto-sync is enabled
        if self.settings.auto_sync_stats then
            self:syncStatistics()
        end
    end)
end

function KOSync2:schedulePeriodicPush()
    UIManager:unschedule(self.periodic_push_task)
    -- Use a sizable delay to make debouncing this on skim feasible...
    UIManager:scheduleIn(10, self.periodic_push_task)
    self.periodic_push_scheduled = true
end

function KOSync2:_onPageUpdate(page)
    if page == nil then
        return
    end

    if self.last_page ~= page then
        self.last_page = page
        self.last_page_turn_timestamp = os.time()
        self.page_update_counter = self.page_update_counter + 1
        -- If we've already scheduled a push, regardless of the counter's state, delay it until we're *actually* idle
        if self.periodic_push_scheduled or self.settings.pages_before_update and self.page_update_counter >= self.settings.pages_before_update then
            self:schedulePeriodicPush()
        end
    end
end

function KOSync2:_onResume()
    logger.dbg("KOSync2: onResume")
    -- If we have auto_restore_wifi enabled, skip this to prevent both the "Connecting..." UI to pop-up,
    -- *and* a duplicate NetworkConnected event from firing...
    if Device:hasWifiRestore() and NetworkMgr.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
        return
    end

    -- And if we don't, this *will* (attempt to) trigger a connection and as such a NetworkConnected event,
    -- but only a single pull will happen, since getProgress debounces itself.
    UIManager:scheduleIn(1, function()
        self:getProgress(true, false)
    end)
end

function KOSync2:_onSuspend()
    logger.dbg("KOSync2: onSuspend")
    -- We request an extra flashing refresh on success, to deal with potential ghosting left by the NetworkMgr UI
    self:updateProgress(true, false, true)
end

function KOSync2:_onNetworkConnected()
    logger.dbg("KOSync2: onNetworkConnected")
    UIManager:scheduleIn(0.5, function()
        -- Network is supposed to be on already, don't wrap this in willRerunWhenOnline
        self:getProgress(false, false)
    end)
end

function KOSync2:_onNetworkDisconnecting()
    logger.dbg("KOSync2: onNetworkDisconnecting")
    -- Network is supposed to be on already, don't wrap this in willRerunWhenOnline
    self:updateProgress(false, false)
end

function KOSync2:onKOSync2PushProgress()
    self:updateProgress(true, true)
end

function KOSync2:onKOSync2PullProgress()
    self:getProgress(true, true)
end

function KOSync2:onKOSync2ToggleAutoSync(toggle, from_menu)
    if toggle == self.settings.auto_sync then
        return true
    end
    -- Actively recommend switching the before wifi action to "turn_on" instead of prompt,
    -- as prompt will just not be practical (or even plain usable) here.
    if not self.settings.auto_sync
            and Device:hasSeamlessWifiToggle()
            and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
        UIManager:show(InfoMessage:new{ text = _("You will have to switch the 'Action when Wi-Fi is off' Network setting to 'turn on' to be able to enable this feature!") })
        return true
    end
    self.settings.auto_sync = not self.settings.auto_sync
    self:registerEvents()

    if self.settings.auto_sync then
        -- Since we will update the progress when closing the document,
        -- pull the current progress now so as not to silently overwrite it.
        self:getProgress(true, true)
    elseif from_menu then
        -- Since we won't update the progress when closing the document,
        -- push the current progress now so as not to lose it.
        self:updateProgress(true, true)
    end

    if not from_menu then
        Notification:notify(self.settings.auto_sync and _("Auto progress sync: on") or _("Auto progress sync: off"))
    end
    return true
end

function KOSync2:registerEvents()
    if self.settings.auto_sync or self.settings.auto_sync_stats then
        self.onCloseDocument = self._onCloseDocument
    else
        self.onCloseDocument = nil
    end

    if self.settings.auto_sync then
        self.onPageUpdate = self._onPageUpdate
        self.onResume = self._onResume
        self.onSuspend = self._onSuspend
        self.onNetworkConnected = self._onNetworkConnected
        self.onNetworkDisconnecting = self._onNetworkDisconnecting
    else
        self.onPageUpdate = nil
        self.onResume = nil
        self.onSuspend = nil
        self.onNetworkConnected = nil
        self.onNetworkDisconnecting = nil
    end
end

function KOSync2:onCloseWidget()
    UIManager:unschedule(self.periodic_push_task)
    self.periodic_push_task = nil
end

function KOSync2:getLoadedStatisticsPlugin()
    if not self.ui then return nil end
    for _, plugin in ipairs(self.ui.pluginloader.plugins) do
        if plugin.name == "statistics" then
            return plugin
        end
    end
    return nil
end

function KOSync2:getAllStatistics()
    local stats_plugin = self:getLoadedStatisticsPlugin()
    if stats_plugin and stats_plugin.insertDB then
        pcall(stats_plugin.insertDB, stats_plugin)
    end

    local books = {}
    local books_by_id = {}

    local ok, err = pcall(function()
        local conn = SQ3.open(statistics_db_location)

        local books_stmt = conn:prepare([[
            SELECT id, title, authors, notes, last_open, highlights, pages, series, language, md5, total_read_time, total_read_pages
            FROM book;
        ]])

        local result = books_stmt:step()
        while result do
            local book_md5 = result[10]
            if book_md5 and book_md5 ~= "" then
                local book = {
                    title = result[2],
                    authors = result[3],
                    notes = tonumber(result[4]) or 0,
                    last_open = tonumber(result[5]) or 0,
                    highlights = tonumber(result[6]) or 0,
                    pages = tonumber(result[7]) or 0,
                    series = result[8],
                    language = result[9],
                    md5 = book_md5,
                    total_read_time = tonumber(result[11]) or 0,
                    total_read_pages = tonumber(result[12]) or 0,
                    page_stat_data = {},
                }
                books[#books + 1] = book
                books_by_id[tonumber(result[1])] = book
            end
            result = books_stmt:step()
        end
        books_stmt:close()

        local stat_stmt = conn:prepare([[
            SELECT id_book, page, start_time, duration, total_pages
            FROM page_stat_data;
        ]])
        result = stat_stmt:step()
        while result do
            local book = books_by_id[tonumber(result[1])]
            if book then
                book.page_stat_data[#book.page_stat_data + 1] = {
                    page = tonumber(result[2]),
                    start_time = tonumber(result[3]) or 0,
                    duration = tonumber(result[4]) or 0,
                    total_pages = tonumber(result[5]) or 0,
                }
            end
            result = stat_stmt:step()
        end
        stat_stmt:close()
        conn:close()
    end)

    if not ok then
        logger.warn("KOSync2: Failed to read statistics database (it might not exist yet):", err)
        return { books = {} }
    end

    return { books = books }
end

function KOSync2:importAllStatistics(snapshot)
    if type(snapshot) ~= "table" then
        logger.warn("KOSync2:importAllStatistics: invalid snapshot type")
        return false
    end
    local books = snapshot.books
    if type(books) ~= "table" then
        return false
    end

    local incoming_nonempty = false
    for _, row in ipairs(books) do
        local book_md5 = row and row.md5
        if book_md5 and book_md5 ~= "" then
            incoming_nonempty = true
            break
        end
    end

    local conn = SQ3.open(statistics_db_location)
    -- if local not have database
    conn:exec([[
        CREATE TABLE IF NOT EXISTS book (
            id INTEGER PRIMARY KEY, title TEXT, authors TEXT, notes INTEGER, 
            last_open INTEGER, highlights INTEGER, pages INTEGER, 
            series TEXT, language TEXT, md5 TEXT, 
            total_read_time INTEGER, total_read_pages INTEGER
        );
        CREATE TABLE IF NOT EXISTS page_stat_data (
            id_book INTEGER, page INTEGER, start_time INTEGER, 
            duration INTEGER, total_pages INTEGER
        );
    ]])

    local local_book_count = tonumber(conn:rowexec("SELECT count(*) FROM book;")) or 0
    if local_book_count > 0 and not incoming_nonempty then
        conn:close()
        logger.warn("KOSync2: refusing to replace non-empty local stats with an empty server snapshot")
        return false
    end

    conn:exec("BEGIN;")
    local ok, err = pcall(function()
        conn:exec("DELETE FROM page_stat_data;")
        conn:exec("DELETE FROM book;")
        local stmt_book = conn:prepare("INSERT INTO book VALUES(NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);")
        local stmt_stats = conn:prepare("INSERT INTO page_stat_data VALUES(?, ?, ?, ?, ?);")
        local seen_md5 = {}
        for _, row in ipairs(books) do
            local book_md5 = row.md5
            if book_md5 and book_md5 ~= "" and not seen_md5[book_md5] then
                seen_md5[book_md5] = true
                stmt_book:reset():bind(
                    row.title,
                    row.authors,
                    tonumber(row.notes) or 0,
                    tonumber(row.last_open) or 0,
                    tonumber(row.highlights) or 0,
                    tonumber(row.pages) or 0,
                    row.series,
                    row.language,
                    book_md5,
                    tonumber(row.total_read_time) or 0,
                    tonumber(row.total_read_pages) or 0
                ):step()
                local id_book = tonumber(conn:rowexec("SELECT last_insert_rowid();"))
                local page_stat_data = type(row.page_stat_data) == "table" and row.page_stat_data or {}
                for _, stat in ipairs(page_stat_data) do
                    stmt_stats:reset():bind(
                        id_book,
                        tonumber(stat.page) or 0,
                        tonumber(stat.start_time) or 0,
                        tonumber(stat.duration) or 0,
                        tonumber(stat.total_pages) or 0
                    ):step()
                end
            end
        end
        stmt_book:close()
        stmt_stats:close()

        conn:exec([[
            UPDATE book SET (total_read_pages, total_read_time) =
            (SELECT count(DISTINCT page), sum(duration) FROM page_stat WHERE id_book = book.id);
        ]])
    end)

    if not ok then
        pcall(conn.exec, conn, "ROLLBACK;")
        conn:close()
        logger.warn("KOSync2: failed to import statistics snapshot:", err)
        return false
    end
    conn:exec("COMMIT;")
    conn:close()

    local stats_plugin = self:getLoadedStatisticsPlugin()
    if stats_plugin and stats_plugin.document and stats_plugin.is_doc and stats_plugin.initData then
        stats_plugin:initData()
    end

    return true
end

function KOSync2:syncStatistics()
    if NetworkMgr:willRerunWhenOnline(function() self:syncStatistics() end) then
        return
    end

    if not self.settings.userkey then
        UIManager:show(InfoMessage:new{
            text = _("Please login before syncing statistics."),
            timeout = 2,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Syncing statistics. Please wait…"),
        timeout = 1,
    })

    local snapshot = self:getAllStatistics()
    if not snapshot then
        UIManager:show(InfoMessage:new{
            text = _("Failed to read statistics data."),
            timeout = 2,
        })
        return
    end

    local KOSync2Client = require("KOSync2Client")
    local client = KOSync2Client:new{
        custom_url = self.settings.custom_server,
        service_spec = self.path .. "/api.json"
    }

    local payload = {
        schema_version = 20221111,
        device = Device.model,
        device_id = self.device_id or "",
        snapshot = snapshot,
    }

    local ok, err = pcall(client.sync_statistics,
        client,
        self.settings.username,
        self.settings.userkey,
        payload,
        function(cb_ok, body, status)
            if status == 404 then
                UIManager:show(InfoMessage:new{
                    text = _("Current server does not support statistics sync."),
                    timeout = 3,
                })
                return
            end

            if cb_ok and body and body.snapshot then
                local server_snapshot = body.snapshot
                if type(server_snapshot) == "string" then
                    local JSON = require("json")
                    local decode_ok, decoded = pcall(JSON.decode, server_snapshot)
                    if decode_ok then
                        server_snapshot = decoded
                    else
                        server_snapshot = nil
                    end
                end

                if type(server_snapshot) == "table" then
                    if self:importAllStatistics(server_snapshot) then
                        UIManager:show(InfoMessage:new{
                            text = _("Successfully synchronized statistics."),
                            timeout = 2,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Failed to import statistics from server."),
                            timeout = 3,
                        })
                    end
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Invalid statistics snapshot received from server."),
                        timeout = 3,
                    })
                end
            elseif cb_ok then
                UIManager:show(InfoMessage:new{
                    text = _("Successfully synchronized statistics."),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = body and body.message or _("Sync failed. Please check your network connection and try again."),
                    timeout = 3,
                })
            end
        end
    )

    if not ok then
        logger.warn("KOSync2: statistics sync error:", err)
        UIManager:show(InfoMessage:new{
            text = _("An error occurred while syncing:\n") .. tostring(err),
            timeout = 3,
        })
    end
end

return KOSync2
