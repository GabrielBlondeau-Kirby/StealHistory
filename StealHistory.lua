-- StealHistory : historique de ce qui a été volé avec Vol à la tire.
--  1. Repère le butin ouvert juste après un Vol à la tire et l'enregistre.
--  2. Remplace dans le chat « Vous recevez le butin : x » par « Vol le butin : x ».
--  3. Fenêtre façon cadre de butin avec les N derniers vols (5 par défaut).

local ADDON = ...
local _, class = UnitClass("player")
if class ~= "ROGUE" then return end

local PICK_POCKET = 921
local ICON = "Interface\\AddOns\\StealHistory\\Media\\icon"
local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"

local FR = GetLocale() == "frFR"
local function T(fr, en) return FR and fr or en end
local STOLE = T("Vol le butin : %s", "Pickpocketed: %s")

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

-- visibility : "always" (tout le temps), "nocombat" (cachée en combat),
-- "fade" (en combat, transparence combatAlpha et taille combatScale).
local DEFAULTS = {
    max = 5, replaceChat = true, autoShow = false,
    alpha = 100, visibility = "always", combatAlpha = 40, combatScale = 70,
    minimap = { angle = 200, hide = false },
    history = {},
}
local db = DEFAULTS

local function Print(msg)
    print("|cff33ff99StealHistory|r : " .. msg)
end

---------------------------------------------------------------------------
-- 1. Détection du vol
---------------------------------------------------------------------------
-- Vol à la tire ouvre une fenêtre de butin, comme un cadavre. On considère
-- que c'est un vol si elle s'ouvre moins de 2 s après l'envoi du sort.

local castAt, castTarget = 0, nil
local stealing = false     -- fenêtre de butin du vol ouverte
local windowEnd = 0        -- fin de la période où les messages du chat sont « volés »
local slots = {}           -- contenu de la fenêtre de butin au moment de l'ouverture
local moneyBefore = 0

local Refresh  -- fenêtre, définie plus bas

local function Add(entry)
    entry.target = castTarget
    entry.time = time()
    table.insert(db.history, 1, entry)
    for i = #db.history, db.max + 1, -1 do db.history[i] = nil end
    if Refresh then Refresh() end
end

local function InWindow()
    return stealing or GetTime() < windowEnd
end

local function OnLootOpened()
    if GetTime() - castAt > 2 then return end
    castAt = 0
    stealing = true
    moneyBefore = GetMoney()
    wipe(slots)
    for i = 1, GetNumLootItems() do
        local link = GetLootSlotLink(i)
        if link then
            local icon, name, qty, _, quality = GetLootSlotInfo(i)
            slots[i] = { link = link, icon = icon, name = name, count = qty or 1, quality = quality }
        end
    end
end

---------------------------------------------------------------------------
-- 2. Chat : « Vol le butin : x »
---------------------------------------------------------------------------
-- Les messages du jeu sont des formats localisés (« Vous recevez le butin : %s. ») :
-- on les transforme en motifs Lua pour récupérer l'objet ou la somme.

local function Pattern(fmt)
    if not fmt then return nil end
    -- %s / %d (ou %1$s) -> repères, échappement des caractères magiques, puis captures.
    fmt = fmt:gsub("%%%d?%$?s", "\1"):gsub("%%%d?%$?d", "\2")
    fmt = fmt:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    fmt = fmt:gsub("\1", "(.+)"):gsub("\2", "(%%d+)")
    return "^" .. fmt .. "$"
end

local PATTERNS = {
    CHAT_MSG_LOOT  = { Pattern(LOOT_ITEM_SELF_MULTIPLE), Pattern(LOOT_ITEM_SELF) },
    CHAT_MSG_MONEY = { Pattern(YOU_LOOT_MONEY), Pattern(LOOT_MONEY_SPLIT) },
}

local function ChatFilter(_, event, msg, ...)
    if not db.replaceChat or not InWindow() then return false end
    for _, pat in ipairs(PATTERNS[event]) do
        local what, count = msg:match(pat)
        if what then
            if count then what = what .. " x" .. count end
            return false, STOLE:format(what), ...
        end
    end
    return false
end

local addFilter = ChatFrame_AddMessageEventFilter
    or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
addFilter("CHAT_MSG_LOOT", ChatFilter)
addFilter("CHAT_MSG_MONEY", ChatFilter)

---------------------------------------------------------------------------
-- 3. Fenêtre façon cadre de butin
---------------------------------------------------------------------------

local ROW_H, WIDTH = 44, 240

-- Le conteneur porte la visibilité / transparence ; la fenêtre, elle, garde
-- son état ouvert / fermé choisi par le joueur.
local holder = CreateFrame("Frame", nil, UIParent)
holder:SetAllPoints(UIParent)

local frame = CreateFrame("Frame", "StealHistoryFrame", holder, BACKDROP_TEMPLATE)

-- La position est sauvée en unités d'UIParent : on la divise par l'échelle
-- pour que la fenêtre réduite reste au même endroit.
local function Place()
    local p, s = db.pos or { "CENTER", "CENTER", 0, 0 }, frame:GetScale()
    frame:ClearAllPoints()
    frame:SetPoint(p[1], UIParent, p[2], p[3] / s, p[4] / s)
end

local inCombat = false
local function ApplyVisibility()
    holder:SetShown(not (inCombat and db.visibility == "nocombat"))
    local reduced = inCombat and db.visibility == "fade"
    holder:SetAlpha((reduced and db.combatAlpha or db.alpha) / 100)
    frame:SetScale(reduced and db.combatScale / 100 or 1)
    Place()
end
frame:SetSize(WIDTH, 120)
frame:SetPoint("CENTER")
frame:SetFrameStrata("DIALOG")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, rel, x, y = self:GetPoint()
    local s = self:GetScale()
    db.pos = { point, rel, x * s, y * s }
end)
frame:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:Hide()
tinsert(UISpecialFrames, "StealHistoryFrame")  -- Échap ferme la fenêtre

-- Portrait rond en haut à gauche, comme le cadre de butin.
local portrait = frame:CreateTexture(nil, "OVERLAY")
portrait:SetSize(46, 46)
portrait:SetPoint("TOPLEFT", -14, 14)
if SetPortraitToTexture then SetPortraitToTexture(portrait, ICON) else portrait:SetTexture(ICON) end
local ring = frame:CreateTexture(nil, "OVERLAY", nil, 1)
ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
ring:SetSize(80, 80)
ring:SetPoint("TOPLEFT", portrait, "TOPLEFT", -6, 5)

local header = frame:CreateTexture(nil, "ARTWORK")
header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
header:SetSize(220, 64)
header:SetPoint("TOP", 12, 12)
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", header, "TOP", 0, -14)
title:SetText(T("Vols à la tire", "Pickpockets"))

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -4, -4)

local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("TOP", 0, -50)
empty:SetText(T("Aucun vol pour l'instant.", "Nothing stolen yet."))

-- Somme en pièces avec icônes. GetCoinTextureString n'existe plus sur les
-- clients récents (déplacée dans C_CurrencyInfo) : on prend ce qui existe.
local COIN = "|TInterface\\MoneyFrame\\UI-%sIcon:0:0:2:0|t"
local function Coins(c)
    local f = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
    if f then return f(c) end
    local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. COIN:format("Gold") end
    if s > 0 then out[#out + 1] = s .. COIN:format("Silver") end
    if k > 0 or #out == 0 then out[#out + 1] = k .. COIN:format("Copper") end
    return table.concat(out, " ")
end

local rows = {}

local function RowEnter(self)
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if e.link then
        GameTooltip:SetHyperlink(e.link)
    else
        GameTooltip:AddLine(Coins(e.money), 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(e.target or "?", date("%d/%m %H:%M", e.time), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function RowClick(self)
    local e = self.entry
    if e and e.link and IsModifiedClick("CHATLINK") then ChatEdit_InsertLink(e.link) end
end

-- Même construction qu'un bouton de butin : icône + cadre de nom doré.
local function Row(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, frame)
    r:SetSize(WIDTH - 40, ROW_H - 4)
    r:SetPoint("TOPLEFT", 22, -34 - (i - 1) * ROW_H)

    r.icon = r:CreateTexture(nil, "BORDER")
    r.icon:SetSize(37, 37)
    r.icon:SetPoint("LEFT")
    local border = r:CreateTexture(nil, "ARTWORK")
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetSize(64, 64)
    border:SetPoint("CENTER", r.icon, "CENTER")

    local nameFrame = r:CreateTexture(nil, "BACKGROUND")
    nameFrame:SetTexture("Interface\\QuestFrame\\UI-QuestItemNameFrame")
    nameFrame:SetSize(WIDTH - 70, 64)
    nameFrame:SetPoint("LEFT", r.icon, "RIGHT", -10, 0)

    r.name = r:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -3)
    r.name:SetWidth(WIDTH - 95)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    r.sub = r:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.sub:SetWidth(WIDTH - 95)
    r.sub:SetJustifyH("LEFT")
    r.sub:SetWordWrap(false)

    r.count = r:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    r.count:SetPoint("BOTTOMRIGHT", r.icon, "BOTTOMRIGHT", -2, 2)

    r:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    r:GetHighlightTexture():SetAllPoints(r.icon)
    r:SetScript("OnEnter", RowEnter)
    r:SetScript("OnLeave", GameTooltip_Hide)
    r:SetScript("OnClick", RowClick)
    rows[i] = r
    return r
end

Refresh = function()
    local n = math.min(#db.history, db.max)
    for i = 1, n do
        local e, r = db.history[i], Row(i)
        r.entry = e
        if e.link then
            local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.quality or 1]
            r.icon:SetTexture(e.icon or GetItemIcon(e.link) or ICON)
            r.name:SetText(e.name or e.link)
            r.name:SetTextColor(q and q.r or 1, q and q.g or 1, q and q.b or 1)
            r.count:SetText((e.count or 1) > 1 and e.count or "")
        else
            r.icon:SetTexture(COIN_ICON)
            r.name:SetText(Coins(e.money))
            r.name:SetTextColor(1, 1, 1)
            r.count:SetText("")
        end
        r.sub:SetText((e.target or "?") .. "  ·  " .. date("%H:%M", e.time))
        r:Show()
    end
    for i = n + 1, #rows do rows[i]:Hide() end
    empty:SetShown(n == 0)
    frame:SetHeight(math.max(n, 1) * ROW_H + 50)
end

frame:SetScript("OnShow", Refresh)

local function Toggle()
    frame:SetShown(not frame:IsShown())
end

---------------------------------------------------------------------------
-- 4. Panneau d'options (Options > Add-ons)
---------------------------------------------------------------------------

local panel = CreateFrame("Frame")
panel.name = "StealHistory"

local ptitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
ptitle:SetPoint("TOPLEFT", 16, -16)
ptitle:SetText("StealHistory")

local psub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
psub:SetPoint("TOPLEFT", ptitle, "BOTTOMLEFT", 0, -8)
psub:SetText(T("Historique de Vol à la tire. /sh ouvre la fenêtre.",
               "Pick Pocket history. /sh opens the window."))

local refreshers = {}

local sliderCount = 0
local function Slider(anchor, x, y, min, max, step, label, key, onChange)
    sliderCount = sliderCount + 1
    local name = "StealHistorySlider" .. sliderCount
    local s = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x, y)
    s:SetWidth(220)
    s:SetMinMaxValues(min, max)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    _G[name .. "Low"]:SetText(min)
    _G[name .. "High"]:SetText(max)
    local function Label(v) _G[name .. "Text"]:SetText(label(v)) end
    s:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / step + 0.5) * step
        Label(v)
        if v == db[key] then return end
        db[key] = v
        onChange(v)
    end)
    refreshers[#refreshers + 1] = function() s:SetValue(db[key]); Label(db[key]) end
    return s
end

local function CheckBox(anchor, x, y, label, get, set)
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x, y)
    local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    text:SetText(label)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    refreshers[#refreshers + 1] = function() cb:SetChecked(get()) end
    return cb
end
local function Option(key) return function() return db[key] end, function(v) db[key] = v end end

local sCount = Slider(psub, 4, -30, 1, 20, 1,
    function(v) return T("Vols gardés : ", "Steals kept: ") .. v end, "max",
    function(v)
        for i = #db.history, v + 1, -1 do db.history[i] = nil end
        Refresh()
    end)

local sAlpha = Slider(sCount, 0, -36, 10, 100, 5,
    function(v) return T("Transparence de la fenêtre : ", "Window opacity: ") .. v .. " %" end, "alpha",
    ApplyVisibility)

local cbChat = CheckBox(sAlpha, -4, -30,
    T("Chat : « Vol le butin : x » au lieu du message normal",
      "Chat: \"Pickpocketed: x\" instead of the normal message"), Option("replaceChat"))
local cbShow = CheckBox(cbChat, 0, -4,
    T("Ouvrir la fenêtre après chaque vol", "Open the window after each steal"), Option("autoShow"))
local SetMinimapShown  -- défini avec le bouton de la minimap
local cbMinimap = CheckBox(cbShow, 0, -4,
    T("Icône autour de la minimap", "Minimap icon"),
    function() return not db.minimap.hide end,
    function(v) SetMinimapShown(v) end)

-- Visibilité : trois cases qui se comportent comme des boutons radio.
local visTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
visTitle:SetPoint("TOPLEFT", cbMinimap, "BOTTOMLEFT", 4, -16)
visTitle:SetText(T("Visibilité", "Visibility"))

local VIS = {
    { "always",   T("Tout le temps", "Always") },
    { "nocombat", T("Hors combat seulement (cachée en combat)", "Out of combat only (hidden in combat)") },
    { "fade",     T("En combat : plus petite et plus transparente", "In combat: smaller and faded") },
}
local anchor, visBoxes = visTitle, {}
for i, v in ipairs(VIS) do
    local cb = CheckBox(anchor, i == 1 and -4 or 0, i == 1 and -4 or 0, v[2],
        function() return db.visibility == v[1] end,
        function()
            db.visibility = v[1]
            for _, b in ipairs(visBoxes) do b:SetChecked(b.mode == db.visibility) end
            ApplyVisibility()
        end)
    cb.mode = v[1]
    visBoxes[i] = cb
    anchor = cb
end

local sCombat = Slider(anchor, 4, -24, 0, 100, 5,
    function(v) return T("Transparence en combat : ", "Combat opacity: ") .. v .. " %" end, "combatAlpha",
    ApplyVisibility)
local sScale = Slider(sCombat, 0, -36, 50, 100, 5,
    function(v) return T("Taille en combat : ", "Combat size: ") .. v .. " %" end, "combatScale",
    ApplyVisibility)

local clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
clear:SetSize(180, 24)
clear:SetPoint("TOPLEFT", sScale, "BOTTOMLEFT", -4, -30)
clear:SetText(T("Vider l'historique", "Clear history"))
clear:SetScript("OnClick", function() wipe(db.history); Refresh() end)

local show = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
show:SetSize(180, 24)
show:SetPoint("LEFT", clear, "RIGHT", 10, 0)
show:SetText(T("Afficher la fenêtre", "Show window"))
show:SetScript("OnClick", Toggle)

panel:SetScript("OnShow", function() for _, f in ipairs(refreshers) do f() end end)

local settingsCategory
local function RegisterPanel()
    if Settings and Settings.RegisterCanvasLayoutCategory then
        settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(settingsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local function OpenPanel()
    if settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel) -- 2e appel : bug connu du 1er affichage
    end
end

---------------------------------------------------------------------------
-- 5. Icône autour de la minimap
-- Clic gauche : fenêtre. Clic droit : options. Glisser : tourner autour.
---------------------------------------------------------------------------

local mm = CreateFrame("Button", "StealHistoryMinimapButton", Minimap)
mm:SetSize(31, 31)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local mmBg = mm:CreateTexture(nil, "BACKGROUND")
mmBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
mmBg:SetSize(20, 20)
mmBg:SetPoint("TOPLEFT", 7, -5)

local mmIcon = mm:CreateTexture(nil, "ARTWORK")
mmIcon:SetSize(17, 17)
mmIcon:SetPoint("TOPLEFT", 7, -6)
if SetPortraitToTexture then SetPortraitToTexture(mmIcon, ICON) else mmIcon:SetTexture(ICON) end

local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmBorder:SetSize(53, 53)
mmBorder:SetPoint("TOPLEFT")

local function PlaceMinimapButton()
    local a = math.rad(db.minimap.angle)
    local r = Minimap:GetWidth() / 2 + 5
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

SetMinimapShown = function(shown)
    db.minimap.hide = not shown
    mm:SetShown(shown)
end

mm:SetScript("OnClick", function(_, button)
    if button == "RightButton" then OpenPanel() else Toggle() end
end)
mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        db.minimap.angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
        PlaceMinimapButton()
    end)
end)
mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("StealHistory", 0.2, 1, 0.6)
    GameTooltip:AddLine(T("Clic gauche : historique des vols", "Left-click: steal history"), 1, 1, 1)
    GameTooltip:AddLine(T("Clic droit : options", "Right-click: options"), 1, 1, 1)
    GameTooltip:AddLine(T("Glisser : déplacer autour de la minimap", "Drag: move around the minimap"), 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
mm:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------------------
-- Événements et commande
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("LOOT_SLOT_CLEARED")
ev:RegisterEvent("LOOT_CLOSED")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        inCombat = event == "PLAYER_REGEN_DISABLED"
        ApplyVisibility()
        return
    end
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        StealHistoryDB = StealHistoryDB or {}
        for k, v in pairs(DEFAULTS) do
            if StealHistoryDB[k] == nil then StealHistoryDB[k] = v end
        end
        db = StealHistoryDB
        RegisterPanel()
        PlaceMinimapButton()
        mm:SetShown(not db.minimap.hide)
        ApplyVisibility()
    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, target, _, spellID = ...
        if spellID == PICK_POCKET then
            castAt = GetTime()
            castTarget = (target and target ~= "") and target or UnitName("target")
        end
    elseif event == "UNIT_SPELLCAST_FAILED" then
        local _, _, spellID = ...
        if spellID == PICK_POCKET then castAt = 0 end
    elseif event == "LOOT_OPENED" then
        OnLootOpened()
    elseif event == "LOOT_SLOT_CLEARED" then
        local s = stealing and slots[...]
        if s then
            slots[...] = nil
            Add(s)
            if db.autoShow then frame:Show() end
        end
    elseif event == "PLAYER_MONEY" then
        if InWindow() then
            local gained = GetMoney() - moneyBefore
            moneyBefore = GetMoney()
            if gained > 0 then
                Add({ money = gained })
                if db.autoShow then frame:Show() end
            end
        end
    elseif event == "LOOT_CLOSED" then
        if stealing then
            stealing = false
            windowEnd = GetTime() + 2  -- les messages du chat arrivent parfois après
        end
    end
end)

SLASH_STEALHISTORY1 = "/stealhistory"
SLASH_STEALHISTORY2 = "/sh"
SlashCmdList.STEALHISTORY = function(msg)
    msg = (msg or ""):lower()
    if msg == "options" or msg == "config" then
        OpenPanel()
    elseif msg == "clear" then
        wipe(db.history); Refresh()
        Print(T("historique vidé.", "history cleared."))
    elseif msg == "minimap" then
        SetMinimapShown(db.minimap.hide)
    elseif msg == "reset" then
        db.pos = nil
        Place()
    else
        Toggle()
    end
end
