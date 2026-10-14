--[[--
Tailscale button: an icon in KOReader's top menu bar (reader and file
browser), next to the main-menu icon.

  Tailscale running            Wi-Fi icon with a lock (the tunnel)
  Wi-Fi on, Tailscale off      plain Wi-Fi icon
  both off                     empty Wi-Fi icon

Tapping it closes the menu and toggles: if Tailscale is running, stop it
and turn Wi-Fi off; otherwise turn Wi-Fi on and start Tailscale once
connected. Holding it opens a network panel: status (Wi-Fi network, IP,
Tailscale) and Wi-Fi / Tailscale / network buttons. The work is done by
tailscale-ctl.sh, the same script the NickelMenu entry uses.

Wi-Fi on means Tailscale on: whenever Wi-Fi connects (from this button,
KOReader's own menu, waking up, any plugin asking to go online), Tailscale
is started if it isn't running.

@module koplugin.tailscale
--]]--

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local CTL = "/mnt/onboard/.adds/tailscale/tailscale-ctl.sh"
local PIDFILE = "/tmp/tailscaled.pid"
local TAB_ID = "tailscale_toggle"

-- Put our icon just before the main-menu icon, in both menu bars.
-- MenuSorter drops a tab that has no entry of its own in the order
-- table, so give it an empty one (as the file manager's plus_menu has).
for _, name in ipairs{"ui/elements/reader_menu_order", "ui/elements/filemanager_menu_order"} do
    local order = require(name)
    order[TAB_ID] = order[TAB_ID] or {}
    local buttons = order["KOMenu:menu_buttons"]
    local present, main_pos = false, #buttons + 1
    for i, id in ipairs(buttons) do
        if id == TAB_ID then present = true end
        if id == "main" then main_pos = i end
    end
    if not present then table.insert(buttons, main_pos, TAB_ID) end
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function tailscaleRunning()
    local pid = (readFile(PIDFILE) or ""):match("%d+")
    if pid and (readFile("/proc/" .. pid .. "/comm") or ""):match("tailscaled") then
        return true
    end
    local p = io.popen("pidof tailscaled 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    return out:match("%d") ~= nil
end

local function ctlStatus()
    local p = io.popen("/bin/sh " .. CTL .. " status 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    return out:gsub("%s+$", "")
end

local TailscaleButton = WidgetContainer:extend{
    name = "tailscale",
    is_doc_only = false,
}

function TailscaleButton:init()
    if not readFile(CTL) then
        logger.warn("tailscale button:", CTL, "not found; not adding the icon")
        return
    end
    self.tab = {
        icon = self:currentIcon(),
        remember = false,
        callback = function()
            self:closeMenu()
            self:toggle()
        end,
    }
    self.ui.menu:registerToMainMenu(self)

    -- The bar reads each tab's icon when the menu opens: refresh ours first.
    -- TouchMenu also runs the callback of the tab it opens on (the last one
    -- used, remembered by number), so never let it open on a button tab:
    -- that would toggle on every open. Move on to the next real tab.
    local menu = self.ui.menu
    local orig = menu.onShowMenu
    menu.onShowMenu = function(m, tab_index, ...)
        self.tab.icon = self:currentIcon()
        if m.tab_item_table == nil then m:setUpdateItemTable() end
        local tabs = m.tab_item_table
        local i = tab_index or m.last_tab_index
            or G_reader_settings:readSetting("filemanagermenu_tab_index")
        if not tabs[i] then i = 1 end
        while tabs[i + 1] and tabs[i].callback and #tabs[i] == 0 do i = i + 1 end
        local ret = orig(m, i, ...)
        self:addHold(m)
        return ret
    end
end

-- TouchMenu has no hold for its bar icons: put one on our icon's button.
function TailscaleButton:addHold(menu)
    local touch = menu.menu_container and menu.menu_container[1]
    local bar = touch and touch.bar
    if not (bar and bar.icon_widgets) then return end
    for i, tab in ipairs(menu.tab_item_table or {}) do
        if tab == self.tab and bar.icon_widgets[i] then
            bar.icon_widgets[i].hold_callback = function()
                self:closeMenu()
                self:showPanel()
            end
        end
    end
end

-- Wi-Fi coming up from anywhere starts Tailscale.
function TailscaleButton:onNetworkConnected()
    if tailscaleRunning() then return end
    local now = os.time()
    if TailscaleButton.starting_at and now - TailscaleButton.starting_at < 60 then return end
    TailscaleButton.starting_at = now
    logger.info("tailscale button: Wi-Fi connected, starting Tailscale")
    os.execute("/bin/sh " .. CTL .. " start >/dev/null 2>&1 &")
end

function TailscaleButton:addToMainMenu(menu_items)
    menu_items[TAB_ID] = self.tab
end

function TailscaleButton:currentIcon()
    if tailscaleRunning() then return "wifi.secure.100" end
    if NetworkMgr:isWifiOn() then return "wifi.open.100" end
    return "wifi.open.0"
end

function TailscaleButton:closeMenu()
    local menu = self.ui.menu
    if menu.onTapCloseMenu then
        menu:onTapCloseMenu()
    elseif menu.onCloseFileManagerMenu then
        menu:onCloseFileManagerMenu()
    end
end

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

function TailscaleButton:toggle()
    if tailscaleRunning() then
        toast(_("Stopping Tailscale and turning Wi-Fi off…"), 2)
        UIManager:nextTick(function()
            -- stop can take up to ~10 s; don't hold the UI for it
            os.execute("/bin/sh " .. CTL .. " stop >/dev/null 2>&1 &")
            NetworkMgr:disableWifi(nil, false)
        end)
        return
    end
    local start = function()
        os.execute("/bin/sh " .. CTL .. " start >/dev/null 2>&1 &")
        toast(_("Wi-Fi on. Starting Tailscale…"), 2)
        -- tailscaled takes a few seconds to get its address.
        UIManager:scheduleIn(8, function() toast(ctlStatus(), 4) end)
    end
    if NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then
        start()
    else
        NetworkMgr:enableWifi(start, true)
    end
end

-- The network panel (hold the icon).
function TailscaleButton:showPanel()
    local ButtonDialog = require("ui/widget/buttondialog")
    NetworkMgr:queryNetworkState()
    local wifi_on = NetworkMgr:isWifiOn()
    local lines = {}
    if wifi_on and NetworkMgr:isConnected() then
        local ok, net = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
        local ssid = ok and type(net) == "table" and net.ssid
        table.insert(lines, ssid and ("Wi-Fi: " .. ssid) or _("Wi-Fi: connected"))
    elseif wifi_on then
        table.insert(lines, _("Wi-Fi: on, not connected"))
    else
        table.insert(lines, _("Wi-Fi: off"))
    end
    local ts_on = tailscaleRunning()
    table.insert(lines, ts_on and ctlStatus() or _("Tailscale: stopped"))

    local dialog
    local function run(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local function reopen(delay)
        UIManager:scheduleIn(delay, function() self:showPanel() end)
    end
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        title_align = "center",
        buttons = {
            {
                {
                    text = wifi_on and _("Wi-Fi off") or _("Wi-Fi on"),
                    callback = run(function()
                        if wifi_on then
                            NetworkMgr:disableWifi(nil, false)
                        else
                            NetworkMgr:enableWifi(nil, true)
                        end
                    end),
                },
                {
                    text = ts_on and _("Tailscale off") or _("Tailscale on"),
                    enabled = ts_on or wifi_on,
                    callback = run(function()
                        if ts_on then
                            toast(_("Stopping Tailscale…"), 2)
                            os.execute("/bin/sh " .. CTL .. " stop >/dev/null 2>&1 &")
                        else
                            toast(_("Starting Tailscale…"), 2)
                            os.execute("/bin/sh " .. CTL .. " start >/dev/null 2>&1 &")
                            reopen(10)
                        end
                    end),
                },
            },
            {
                {
                    text = _("Choose network"),
                    callback = run(function()
                        if NetworkMgr:isWifiOn() then
                            NetworkMgr.wifi_toggle_long_press = true
                            NetworkMgr:reconnectOrShowNetworkMenu(nil, true)
                        else
                            NetworkMgr:toggleWifiOn(nil, true, true)
                        end
                    end),
                },
                {
                    text = _("Restart Tailscale"),
                    enabled = wifi_on,
                    callback = run(function()
                        toast(_("Restarting Tailscale…"), 2)
                        os.execute("/bin/sh " .. CTL .. " restart >/dev/null 2>&1 &")
                        reopen(15)
                    end),
                },
            },
            {
                {
                    text = _("Network info"),
                    callback = run(function()
                        UIManager:broadcastEvent(require("ui/event"):new("ShowNetworkInfo"))
                    end),
                },
                {
                    text = _("Check KoboHub"),
                    enabled = wifi_on,
                    callback = run(function()
                        UIManager:broadcastEvent(require("ui/event"):new("KoboHubCheckNow"))
                    end),
                },
            },
            {
                {
                    text = _("Refresh"),
                    callback = run(function() reopen(0) end),
                },
                {
                    text = _("Close"),
                    callback = run(function() end),
                },
            },
        },
    }
    UIManager:show(dialog)
end

return TailscaleButton
