--[[--
Tailscale button: an icon in KOReader's top menu bar (reader and file
browser), next to the main-menu icon.

  Tailscale running            Wi-Fi icon with a lock (the tunnel)
  Wi-Fi on, Tailscale off      plain Wi-Fi icon
  both off                     empty Wi-Fi icon

Tapping it closes the menu and toggles: if Tailscale is running, stop it
and turn Wi-Fi off; otherwise turn Wi-Fi on and start Tailscale once
connected. The work is done by tailscale-ctl.sh, the same script the
NickelMenu entry uses.

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
        return orig(m, i, ...)
    end
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

return TailscaleButton
