--[[--
Frontlight button: an icon at the left end of KOReader's top menu bar
(reader and file browser).

  frontlight on     sun, filled
  frontlight off    sun, hollow

Tapping it closes the menu and toggles the frontlight, the same as
KOReader's "Toggle frontlight" gesture action (it keeps the brightness).

@module koplugin.frontlight
--]]--

local Device = require("device")
local Event = require("ui/event")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")

local TAB_ID = "frontlight_toggle"

-- Put our icon first in both menu bars. MenuSorter drops a tab that has
-- no entry of its own in the order table, so give it an empty one.
for _, name in ipairs{"ui/elements/reader_menu_order", "ui/elements/filemanager_menu_order"} do
    local order = require(name)
    order[TAB_ID] = order[TAB_ID] or {}
    local buttons = order["KOMenu:menu_buttons"]
    local present = false
    for _, id in ipairs(buttons) do
        if id == TAB_ID then present = true end
    end
    if not present then table.insert(buttons, 1, TAB_ID) end
end

local FrontlightButton = WidgetContainer:extend{
    name = "frontlight",
    is_doc_only = false,
}

function FrontlightButton:init()
    if not Device:hasFrontlight() then return end
    -- IconWidget looks icons up by name under resources/icons/mdlight
    -- (relative to KOReader's folder); climb back out to our own folder.
    local path = self.path
    if path:sub(1, 1) == "/" then
        -- up from KOReader's folder to the root, then down again
        path = lfs.currentdir():gsub("[^/]+", "..") .. path
    end
    self.icon_base = "../../../" .. path:gsub("^/+", "") .. "/light."
    self.tab = {
        icon = self:currentIcon(),
        remember = false,
        callback = function()
            self:closeMenu()
            self.ui:handleEvent(Event:new("ToggleFrontlight"))
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

function FrontlightButton:addToMainMenu(menu_items)
    menu_items[TAB_ID] = self.tab
end

function FrontlightButton:currentIcon()
    local on = Device:getPowerDevice():isFrontlightOn()
    return self.icon_base .. (on and "on" or "off")
end

function FrontlightButton:closeMenu()
    local menu = self.ui.menu
    if menu.onTapCloseMenu then
        menu:onTapCloseMenu()
    elseif menu.onCloseFileManagerMenu then
        menu:onCloseFileManagerMenu()
    end
end

return FrontlightButton
