-- StealHistory : historique de ce qui a été volé avec Vol à la tire.
--  1. Repère le butin ouvert juste après un Vol à la tire et l'enregistre.
--  2. Remplace dans le chat « Vous recevez le butin : x » par « Vol le butin : x ».
--  3. Fenêtre façon cadre de butin avec les N derniers vols (5 par défaut).

local ADDON, ns = ...
local L = ns.L
local _, class = UnitClass("player")
if class ~= "ROGUE" then return end

local PICK_POCKET = 921
local ICON = "Interface\\AddOns\\StealHistory\\Media\\icon"
local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"


local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

-- visibility : "always" (tout le temps) ou "nocombat" (cachée en combat).
-- combatReduce : avec "always", en combat la fenêtre passe à combatAlpha
-- et combatScale.
local DEFAULTS = {
    max = 5, replaceChat = true, autoShow = false,
    alpha = 100, visibility = "always", combatReduce = false, combatAlpha = 40, combatScale = 70,
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
local moneyBefore = 0      -- argent au moment du sort

local Refresh  -- fenêtre, définie plus bas
local debug = false  -- /sh debug

local function Add(entry)
    entry.target = castTarget
    entry.time = time()
    table.insert(db.history, 1, entry)
    for i = #db.history, db.max + 1, -1 do db.history[i] = nil end
    if entry.money then db.total = (db.total or 0) + entry.money end
    -- On ouvre d'abord : OnShow remplit la liste, et une erreur dans la mise
    -- à jour ne peut plus empêcher l'ouverture.
    local f = StealHistoryFrame
    if db.autoShow and not f:IsShown() then f:Show() else Refresh() end
    if debug then
        Print(("vol enregistré (%s) | autoShow=%s, fenêtre=%s, visible=%s, alpha=%.2f, combat=%s"):format(
            entry.link or (entry.money .. " cuivre"), tostring(db.autoShow), tostring(f:IsShown()),
            tostring(f:IsVisible()), f:GetEffectiveAlpha(), tostring(InCombatLockdown())))
    end
end

-- Vol en cours : sort lancé il y a moins de 2 s, fenêtre de butin ouverte,
-- ou fermée depuis moins de 2 s (le chat et l'argent arrivent parfois après).
local function InWindow()
    return stealing or GetTime() < windowEnd or GetTime() - castAt < 2
end

-- LOOT_READY (ramassage auto) puis LOOT_OPENED : le premier des deux suffit.
local function OnLootOpened()
    if stealing or GetTime() - castAt > 2 then return end
    castAt = 0
    stealing = true
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

-- Les objets sont enregistrés depuis le message « Vous recevez le butin » :
-- avec le ramassage auto, la fenêtre de butin est souvent déjà vide quand
-- l'addon la lit, alors que le message arrive toujours.
local function RecordLoot(msg)
    for _, pat in ipairs(PATTERNS.CHAT_MSG_LOOT) do
        local link, count = msg:match(pat)
        if link and link:find("|Hitem:") then
            Add({ link = link, count = tonumber(count) or 1 })
            return
        end
    end
end

local function ChatFilter(_, event, msg, ...)
    if not db.replaceChat or not InWindow() then return false end
    for _, pat in ipairs(PATTERNS[event]) do
        local what, count = msg:match(pat)
        if what then
            if count then what = what .. " x" .. count end
            return false, L.STOLE:format(what), ...
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

local ROW_H, WIDTH = 44, 290  -- 3 colonnes : icône, nom + cible, heure

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
    local reduced = inCombat and db.visibility == "always" and db.combatReduce
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

-- Bandeau du titre en trois morceaux (bouts fixes, milieu étiré) : il
-- s'élargit avec le texte sans déformer ses extrémités.
local HEADER_TEX = "Interface\\DialogFrame\\UI-DialogBox-Header"
local headerFrame = CreateFrame("Frame", nil, frame)  -- au-dessus de la bordure de la fenêtre
headerFrame:SetAllPoints()
headerFrame:SetFrameLevel(frame:GetFrameLevel() + 10)
-- Icône en haut à gauche, comme le cadre de butin.
local portrait = headerFrame:CreateTexture(nil, "OVERLAY")
portrait:SetSize(46, 46)
portrait:SetPoint("TOPLEFT", -14, 14)
portrait:SetTexture(ICON)  -- icône carrée telle quelle, sans cercle

local header = headerFrame:CreateTexture(nil, "ARTWORK")
header:SetTexture(HEADER_TEX)
header:SetTexCoord(0.31, 0.67, 0, 0.63)
header:SetSize(100, 40)
header:SetPoint("TOP", 12, 12)
local headerL = headerFrame:CreateTexture(nil, "ARTWORK")
headerL:SetTexture(HEADER_TEX)
headerL:SetTexCoord(0.21, 0.31, 0, 0.63)
headerL:SetSize(30, 40)
headerL:SetPoint("RIGHT", header, "LEFT")
local headerR = headerFrame:CreateTexture(nil, "ARTWORK")
headerR:SetTexture(HEADER_TEX)
headerR:SetTexCoord(0.67, 0.77, 0, 0.63)
headerR:SetSize(30, 40)
headerR:SetPoint("LEFT", header, "RIGHT")
local title = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", header, "TOP", 0, -14)
local TITLE = L.TITLE

-- Titre + total des pièces volées à sa droite ; le bandeau suit la largeur.
local function UpdateTitle()
    local total = db.total or 0
    title:SetText(total > 0 and (TITLE .. "   |cffffffff" .. Coins(total) .. "|r") or TITLE)
    header:SetWidth(math.max(60, title:GetStringWidth() + 16))
end

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -4, -4)

local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("TOP", 0, -50)
empty:SetText(L.EMPTY)

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
    nameFrame:SetSize(WIDTH - 120, 64)
    nameFrame:SetPoint("LEFT", r.icon, "RIGHT", -10, 0)

    r.name = r:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -3)
    r.name:SetWidth(WIDTH - 145)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    r.sub = r:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.sub:SetWidth(WIDTH - 145)
    r.sub:SetJustifyH("LEFT")
    r.sub:SetWordWrap(false)

    r.time = r:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    r.time:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r.time:SetJustifyH("RIGHT")

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
            -- Nom et couleur de qualité tirés du lien : « |cffffffff|Hitem:…|h[Nom]|h|r ».
            local color = e.link:match("|c(%x%x%x%x%x%x%x%x)") or "ffffffff"
            local name = e.name or e.link:match("%[(.-)%]") or e.link
            local icon = e.icon or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(e.link))
                or (GetItemIcon and GetItemIcon(e.link))
            r.icon:SetTexture(icon or ICON)
            r.name:SetText("|c" .. color .. name .. "|r")
            r.count:SetText((e.count or 1) > 1 and e.count or "")
        else
            r.icon:SetTexture(COIN_ICON)
            r.name:SetText(Coins(e.money))
            r.name:SetTextColor(1, 1, 1)
            r.count:SetText("")
        end
        r.sub:SetText(e.target or "?")
        r.time:SetText(date("%H:%M", e.time))
        r:Show()
    end
    for i = n + 1, #rows do rows[i]:Hide() end
    empty:SetShown(n == 0)
    UpdateTitle()
    frame:SetHeight(math.max(n, 1) * ROW_H + 50)
end

frame:SetScript("OnShow", Refresh)
frame:SetScript("OnHide", function()
    if debug then Print("fenêtre fermée par :\n" .. debugstack(2, 4, 0)) end
end)

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
psub:SetText(L.SUBTITLE)

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
    function(v) return L.KEPT:format(v) end, "max",
    function(v)
        for i = #db.history, v + 1, -1 do db.history[i] = nil end
        Refresh()
    end)

local sAlpha = Slider(sCount, 0, -36, 10, 100, 5,
    function(v) return L.OPACITY:format(v) end, "alpha",
    ApplyVisibility)

local cbChat = CheckBox(sAlpha, -4, -30,
    L.CHAT_OPT:format(L.STOLE:format("x")), Option("replaceChat"))
local cbShow = CheckBox(cbChat, 0, -4,
    L.AUTOSHOW, Option("autoShow"))
local SetMinimapShown  -- défini avec le bouton de la minimap
local cbMinimap = CheckBox(cbShow, 0, -4,
    L.MINIMAP,
    function() return not db.minimap.hide end,
    function(v) SetMinimapShown(v) end)

-- Visibilité : trois cases qui se comportent comme des boutons radio.
local visTitle = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
visTitle:SetPoint("TOPLEFT", cbMinimap, "BOTTOMLEFT", 4, -16)
visTitle:SetText(L.VISIBILITY)

-- « Tout le temps » / « Hors combat » s'excluent ; sous « Tout le temps »,
-- la réduction en combat et ses deux réglages (grisés sinon).
local visBoxes, reduceWidgets = {}, {}
local function UpdateVisibilityOptions()
    for _, b in ipairs(visBoxes) do b:SetChecked(b.mode == db.visibility) end
    local on = db.visibility == "always"
    for _, w in ipairs(reduceWidgets) do
        w:SetAlpha(on and 1 or 0.4)
        w:EnableMouse(on)
    end
end
local function VisBox(anchor, x, y, mode, label)
    local cb = CheckBox(anchor, x, y, label,
        function() return db.visibility == mode end,
        function()
            db.visibility = mode
            UpdateVisibilityOptions()
            ApplyVisibility()
        end)
    cb.mode = mode
    visBoxes[#visBoxes + 1] = cb
    return cb
end

local cbAlways = VisBox(visTitle, -4, -4, "always", L.VIS_ALWAYS)
local cbReduce = CheckBox(cbAlways, 24, -2, L.VIS_FADE,
    function() return db.combatReduce end,
    function(v) db.combatReduce = v; ApplyVisibility() end)
local sCombat = Slider(cbReduce, 8, -24, 0, 100, 5,
    function(v) return L.COMBAT_OPACITY:format(v) end, "combatAlpha",
    ApplyVisibility)
local sScale = Slider(sCombat, 0, -36, 50, 100, 5,
    function(v) return L.COMBAT_SIZE:format(v) end, "combatScale",
    ApplyVisibility)
reduceWidgets = { cbReduce, sCombat, sScale }
local cbNoCombat = VisBox(sScale, -32, -24, "nocombat", L.VIS_NOCOMBAT)
refreshers[#refreshers + 1] = UpdateVisibilityOptions

local clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
clear:SetSize(180, 24)
clear:SetPoint("TOPLEFT", cbNoCombat, "BOTTOMLEFT", 4, -20)
clear:SetText(L.CLEAR)
clear:SetScript("OnClick", function() wipe(db.history); db.total = 0; Refresh() end)

local show = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
show:SetSize(180, 24)
show:SetPoint("LEFT", clear, "RIGHT", 10, 0)
show:SetText(L.SHOW)
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
    GameTooltip:AddLine(L.MM_LEFT, 1, 1, 1)
    GameTooltip:AddLine(L.MM_RIGHT, 1, 1, 1)
    GameTooltip:AddLine(L.MM_DRAG, 0.6, 0.6, 0.6)
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
ev:RegisterEvent("LOOT_READY")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("CHAT_MSG_LOOT")
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
        if db.visibility == "fade" then  -- ancien 3e mode -> case à part
            db.visibility, db.combatReduce = "always", true
        end
        if not db.total then  -- première fois : total des pièces déjà dans l'historique
            db.total = 0
            for _, e in ipairs(db.history) do db.total = db.total + (e.money or 0) end
        end
        RegisterPanel()
        PlaceMinimapButton()
        mm:SetShown(not db.minimap.hide)
        ApplyVisibility()
    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, target, _, spellID = ...
        if spellID == PICK_POCKET then
            castAt = GetTime()
            moneyBefore = GetMoney()
            castTarget = (target and target ~= "") and target or UnitName("target")
        end
    elseif event == "UNIT_SPELLCAST_FAILED" then
        local _, _, spellID = ...
        if spellID == PICK_POCKET then castAt = 0 end
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        OnLootOpened()
    elseif event == "CHAT_MSG_LOOT" then
        if InWindow() then RecordLoot(...) end
    elseif event == "PLAYER_MONEY" then
        if InWindow() then
            local gained = GetMoney() - moneyBefore
            moneyBefore = GetMoney()
            if gained > 0 then
                Add({ money = gained })
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
        wipe(db.history); db.total = 0; Refresh()
        Print(L.CLEARED)
    elseif msg == "debug" then
        debug = not debug
        Print("debug " .. (debug and "on" or "off"))
    elseif msg == "minimap" then
        SetMinimapShown(db.minimap.hide)
    elseif msg == "reset" then
        db.pos = nil
        Place()
    else
        Toggle()
    end
end
