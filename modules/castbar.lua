local addon = select(2, ...)


-- ============================================================================
-- CASTBAR MODULE FOR DRAGONUI
-- Original code by Neticsoul
-- ============================================================================

local _G = _G
local pairs, ipairs = pairs, ipairs
local min, max, abs, floor, ceil = math.min, math.max, math.abs, math.floor, math.ceil
local format, gsub = string.format, string.gsub
local GetTime = GetTime
local UnitExists, UnitGUID = UnitExists, UnitGUID
local UnitCastingInfo, UnitChannelInfo = UnitCastingInfo, UnitChannelInfo
local UnitAura, GetSpellTexture, GetSpellInfo = UnitAura, GetSpellTexture, GetSpellInfo

local TEXTURE_PATH = "Interface\\AddOns\\DragonUI\\Textures\\CastbarOriginal\\"
local TEXTURES = {
    atlas = TEXTURE_PATH .. "uicastingbar2x",
    atlasSmall = TEXTURE_PATH .. "uicastingbar",
    standard = TEXTURE_PATH .. "CastingBarStandard2",
    channel = TEXTURE_PATH .. "CastingBarChannel",
    interrupted = TEXTURE_PATH .. "CastingBarInterrupted2",
    spark = TEXTURE_PATH .. "CastingBarSpark"
}

local UV_COORDS = {
    background = {0.0009765625, 0.4130859375, 0.3671875, 0.41796875},
    border = {0.412109375, 0.828125, 0.001953125, 0.060546875},
    flash = {0.0009765625, 0.4169921875, 0.2421875, 0.30078125},
    spark = {0.076171875, 0.0859375, 0.796875, 0.9140625},
    borderShield = {0.000976562, 0.0742188, 0.796875, 0.970703},
    textBorder = {0.001953125, 0.412109375, 0.00390625, 0.11328125}
}

local CHANNEL_TICKS = {
    -- Warlock
    ["Drain Soul"] = 5,
    ["Drain Life"] = 5,
    ["Drain Mana"] = 5,
    ["Rain of Fire"] = 4,
    ["Hellfire"] = 15,
    ["Ritual of Summoning"] = 5,
    -- Priest
    ["Mind Flay"] = 3,
    ["Mind Control"] = 8,
    ["Penance"] = 2,
    -- Mage
    ["Blizzard"] = 8,
    ["Evocation"] = 4,
    ["Arcane Missiles"] = 5,
    -- Druid/Others
    ["Tranquility"] = 4,
    ["Hurricane"] = 10,
    ["First Aid"] = 8
}

local MAX_TICKS = 15

-- ============================================================================
-- MODULE STATE
-- ============================================================================

local CastbarModule = {
    frames = {},
    initialized = false
}

-- Initialize frames for each castbar type (RetailUI pattern: statusBar flags only)
for _, unitType in ipairs({"player", "target", "focus"}) do
    CastbarModule.frames[unitType] = {}
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function GetConfig(unitType)
    local cfg = addon.db and addon.db.profile and addon.db.profile.castbar
    if not cfg then
        return nil
    end

    if unitType == "player" then
        return cfg
    end

    return cfg[unitType]
end

local function IsEnabled(unitType)
    local cfg = GetConfig(unitType)
    return cfg and cfg.enabled
end

local function GetSpellIcon(spellName, texture)
    if texture and texture ~= "" then
        return texture
    end

    if spellName then
        local icon = GetSpellTexture(spellName)
        if icon then
            return icon
        end

        -- Search in spellbook
        for i = 1, 1024 do
            local name, _, icon = GetSpellInfo(i, BOOKTYPE_SPELL)
            if not name then
                break
            end
            if name == spellName and icon then
                return icon
            end
        end
    end

    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function ParseCastTimes(startTime, endTime)
    local start = (startTime or 0) / 1000
    local finish = (endTime or 0) / 1000
    local duration = finish - start

    -- Sanity check for duration
    if duration > 3600 or duration < 0 then
        duration = 3.0
    end

    return start, finish, duration
end

-- ============================================================================
-- FADE SYSTEM - Intelligent fade management following RetailUI pattern
-- ============================================================================

local function RestoreCastbarVisibility(unitType)
    local frames = CastbarModule.frames[unitType]
    if not frames then return end
    
    -- Ensure container exists before trying to show it
    if not frames.container then
        CreateCastbar(unitType)
    end
    
    -- RetailUI pattern: Cancel any active fades and restore full visibility on container
    local container = frames.container
    if container then
        UIFrameFadeRemoveFrame(container)
        container:SetAlpha(1.0)
        container.fadeOutEx = false
        container:Show()  -- Ensure container is visible
    end
    
    -- CRITICAL: Also cancel fade on the castbar itself in case it was set
    local castbar = frames.castbar
    if castbar then
        UIFrameFadeRemoveFrame(castbar)
        castbar:SetAlpha(1.0)
        castbar.fadeOutEx = false
    end
    
    -- Restore all text elements that should be visible
    local textElements = {
        frames.castText, frames.castTextCompact, frames.castTextCentered, 
        frames.castTimeText, frames.castTimeTextCompact
    }
    
    for _, element in ipairs(textElements) do
        if element then
            UIFrameFadeRemoveFrame(element)
            element:SetAlpha(1.0)
        end
    end
    
    -- Restore textBackground if it exists
    if frames.textBackground then
        UIFrameFadeRemoveFrame(frames.textBackground)
        frames.textBackground:SetAlpha(1.0)
    end
    
    -- Restore other elements
    if frames.icon then
        UIFrameFadeRemoveFrame(frames.icon)
        frames.icon:SetAlpha(1.0)
    end
end

local function FadeOutCastbar(unitType, duration)
    local frames = CastbarModule.frames[unitType]
    if not frames then return end
    
    -- RetailUI pattern: Fade entire container - unified and simple
    local container = frames.container
    if container then
        container.fadeOutEx = true
        UIFrameFadeOut(container, duration or 1, 1.0, 0.0, function()
            -- OnFinished callback: Hide container and reset flags
            container:Hide()
            container.fadeOutEx = false
        end)
    end
end

-- ============================================================================
-- TEXTURE AND LAYER MANAGEMENT
-- ============================================================================

local function ForceStatusBarLayer(statusBar)
    if not statusBar then
        return
    end

    -- ✅ SOLO configurar UNA VEZ, no en cada frame
    local texture = statusBar:GetStatusBarTexture()
    if texture and texture.SetDrawLayer and not statusBar._layerForced then
        texture:SetDrawLayer('BORDER', 0)
        statusBar._layerForced = true -- Marcar como configurado
    end
end

local function CreateTextureClipping(statusBar)
    statusBar.UpdateTextureClipping = function(self, progress, isChanneling)
        local texture = self:GetStatusBarTexture()
        if not texture then
            return
        end

        if isChanneling then
            -- CHANNELING: Ocultar desde la derecha (texture se "corta" de derecha a izquierda)
            local clampedProgress = math.max(0.01, math.min(0.99, progress))
            texture:ClearAllPoints()
            texture:SetAllPoints(self)
            texture:SetTexCoord(0, clampedProgress, 0, 1)
        else
            -- CASTING: Normal (texture se "llena" de izquierda a derecha)
            local clampedProgress = math.max(0.01, math.min(0.99, progress))
            texture:SetTexCoord(0, clampedProgress, 0, 1)
            texture:ClearAllPoints()
            texture:SetAllPoints(self)
        end
    end
end

-- ============================================================================
-- BLIZZARD CASTBAR MANAGEMENT
-- ============================================================================

local function HideBlizzardCastbar(unitType)
    local frames = {
        player = CastingBarFrame,
        target = TargetFrameSpellBar,
        focus = FocusFrameSpellBar
    }

    local frame = frames[unitType]
    if not frame then
        return
    end

    --  More aggressive hiding to prevent interference
    frame:Hide()
    frame:SetAlpha(0)

    if unitType == "target" then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -5000, -5000)
        frame:SetSize(1, 1) -- Minimize size

        --  Disable Blizzard's own show/hide logic
        if frame.SetScript then
            frame:SetScript("OnShow", function(self)
                self:Hide()
            end)
        end
    else
        if frame.SetScript then
            frame:SetScript("OnShow", function(self)
                self:Hide()
            end)
        end
    end
end

local function ShowBlizzardCastbar(unitType)
    local frames = {
        player = CastingBarFrame,
        target = TargetFrameSpellBar,
        focus = FocusFrameSpellBar
    }

    local frame = frames[unitType]
    if not frame then
        return
    end

    frame:SetAlpha(1)
    if frame.SetScript then
        frame:SetScript("OnShow", nil)
    end

    if unitType == "target" then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", TargetFrame, "BOTTOMLEFT", 25, -5)
    end
end

-- ============================================================================
-- CHANNEL TICKS SYSTEM
-- ============================================================================

local function CreateChannelTicks(parent, ticksTable)
    for i = 1, MAX_TICKS do
        local tick = parent:CreateTexture('Tick' .. i, 'ARTWORK', nil, 1)
        tick:SetTexture('Interface\\ChatFrame\\ChatFrameBackground')
        tick:SetVertexColor(0, 0, 0, 0.75)
        tick:SetSize(3, max(parent:GetHeight() - 2, 10))
        tick:Hide()
        ticksTable[i] = tick
    end
end

local function UpdateChannelTicks(parent, ticksTable, spellName)
    -- Hide all ticks first
    for i = 1, MAX_TICKS do
        if ticksTable[i] then
            ticksTable[i]:Hide()
        end
    end

    local tickCount = CHANNEL_TICKS[spellName]

    if not tickCount or tickCount <= 1 then
        return
    end

    local width = parent:GetWidth()
    local height = parent:GetHeight()
    local tickDelta = width / tickCount

    for i = 1, min(tickCount - 1, MAX_TICKS) do
        if ticksTable[i] then
            ticksTable[i]:SetSize(3, max(height - 2, 10))
            ticksTable[i]:ClearAllPoints()
            ticksTable[i]:SetPoint('CENTER', parent, 'LEFT', i * tickDelta, 0)
            ticksTable[i]:Show()
        end
    end
end

local function HideAllTicks(ticksTable)
    for i = 1, MAX_TICKS do
        if ticksTable[i] then
            ticksTable[i]:Hide()
        end
    end
end

-- ============================================================================
-- SHIELD SYSTEM
-- ============================================================================

local function CreateShield(parent, icon, frameName, iconSize)
    if not parent or not icon then
        return nil
    end

    local shield = CreateFrame("Frame", frameName .. "Shield", parent)
    shield:SetFrameLevel(parent:GetFrameLevel() - 1)
    shield:SetSize(iconSize * 1.8, iconSize * 2.0)

    local texture = shield:CreateTexture(nil, "ARTWORK", nil, 3)
    texture:SetAllPoints(shield)
    texture:SetTexture(TEXTURES.atlas)
    texture:SetTexCoord(unpack(UV_COORDS.borderShield))
    texture:SetVertexColor(1, 1, 1, 1)

    shield:ClearAllPoints()
    shield:SetPoint("CENTER", icon, "CENTER", 0, -4)
    shield:Hide()

    return shield
end

-- ============================================================================
-- AURA OFFSET SYSTEM
-- ============================================================================

-- ============================================================================
-- UNIFIED AURA OFFSET SYSTEM
-- ============================================================================
local function GetAuraOffset(unit)
    local cfg = GetConfig(unit)
    if not cfg or not cfg.autoAdjust then
        return 0
    end

    if not UnitExists(unit) then
        return 0
    end

    local buffCount = 0
    local debuffCount = 0

    -- Count auras using unified method
    if unit == "target" then
        -- Target uses direct UnitBuff/UnitDebuff
        for i = 1, 40 do
            if UnitBuff(unit, i) then
                buffCount = buffCount + 1
            else
                break
            end
        end
        for i = 1, 40 do
            if UnitDebuff(unit, i) then
                debuffCount = debuffCount + 1
            else
                break
            end
        end
    else
        -- Focus uses UnitAura method
        local index = 1
        while index <= 40 do
            local name = UnitAura(unit, index, "HELPFUL")
            if not name then
                break
            end
            buffCount = buffCount + 1
            index = index + 1
        end
        
        index = 1
        while index <= 40 do
            local name = UnitAura(unit, index, "HARMFUL")
            if not name then
                break
            end
            debuffCount = debuffCount + 1
            index = index + 1
        end
    end

    if buffCount == 0 and debuffCount == 0 then
        return 0
    end

    -- Unified offset calculation
    local AURAS_PER_ROW = 6
    local BUFF_ROW_HEIGHT = 10
    local DEBUFF_ROW_HEIGHT = 24
    local totalOffset = 0

    -- Count buff rows (only additional rows)
    if buffCount > 0 then
        local buffRows = math.ceil(buffCount / AURAS_PER_ROW)
        if buffRows > 1 then
            totalOffset = totalOffset + ((buffRows - 1) * BUFF_ROW_HEIGHT)
        end
    end

    -- Add debuff offset if any debuffs exist
    if debuffCount > 0 then
        totalOffset = totalOffset + DEBUFF_ROW_HEIGHT
    end

    return totalOffset
end

local function ApplyAuraOffset(unit)
    local frames = CastbarModule.frames[unit]
    if not frames.castbar or not frames.castbar:IsVisible() then
        return
    end

    local cfg = GetConfig(unit)
    if not cfg or not cfg.enabled or not cfg.autoAdjust then
        return
    end

    local offset = GetAuraOffset(unit)
    local anchorFrame = _G[cfg.anchorFrame] or _G[unit:gsub("^%l", string.upper) .. "Frame"] or UIParent

    -- RetailUI pattern: Position container instead of individual castbar
    if not frames.container then
        CreateCastbar(unitType)
    end
    
    frames.container:ClearAllPoints()
    frames.container:SetPoint(cfg.anchor, anchorFrame, cfg.anchorParent, cfg.x_position, cfg.y_position - offset)
    
    -- Set castbar size on container
    frames.container:SetSize(cfg.sizeX or 200, cfg.sizeY or 16)
end

-- ============================================================================
-- TEXT MANAGEMENT
-- ============================================================================

local function SetTextMode(unitType, mode)
    local frames = CastbarModule.frames[unitType]
    if not frames then
        return
    end

    local elements = {frames.castText, frames.castTextCompact, frames.castTextCentered, frames.castTimeText,
                      frames.castTimeTextCompact}

    -- Hide all text elements first
    for _, element in ipairs(elements) do
        if element then
            element:Hide()
        end
    end

    -- Show appropriate elements based on mode
    if mode == "simple" then
        if frames.castTextCentered then
            frames.castTextCentered:Show()
        end
    else
        local cfg = GetConfig(unitType)
        local isCompact = cfg and cfg.compactLayout

        if isCompact then
            if frames.castTextCompact then
                frames.castTextCompact:Show()
            end
            if frames.castTimeTextCompact then
                frames.castTimeTextCompact:Show()
            end
        else
            if frames.castText then
                frames.castText:Show()
            end
            if frames.castTimeText then
                frames.castTimeText:Show()
            end
        end
    end
end

local function SetCastText(unitType, text)
    local cfg = GetConfig(unitType)
    if not cfg then
        return
    end

    local textMode = cfg.text_mode or "simple"
    SetTextMode(unitType, textMode)

    local frames = CastbarModule.frames[unitType]
    if not frames then
        return
    end

    if textMode == "simple" then
        if frames.castTextCentered then
            frames.castTextCentered:SetText(text)
        end
    else
        if frames.castText then
            frames.castText:SetText(text)
        end
        if frames.castTextCompact then
            frames.castTextCompact:SetText(text)
        end
    end
end
local function UpdateTimeText(unitType)
    local frames = CastbarModule.frames[unitType]
    if not frames or not frames.castbar then
        return
    end
    local castbar = frames.castbar

    if unitType == "player" then
        if not frames.timeValue and not frames.timeMax then
            return
        end
    else
        if not frames.castTimeText and not frames.castTimeTextCompact then
            return
        end
    end

    local cfg = GetConfig(unitType)
    if not cfg then
        return
    end

    local seconds = 0
    local secondsMax = (castbar.endTime or 0) - (castbar.startTime or 0)

    if castbar.castingEx or castbar.channelingEx then
        local currentTime = GetTime()
        local elapsed = currentTime - (castbar.startTime or 0)
        
        if castbar.castingEx then
            -- CASTING: Mostrar tiempo restante (cuenta atrás)
            seconds = max(0, secondsMax - elapsed)
        else
            -- CHANNELING: Mostrar tiempo restante directo (drena)
            seconds = max(0, secondsMax - elapsed)
        end
    end

    local timeText = format('%.' .. (cfg.precision_time or 1) .. 'f', seconds)
    local fullText

    if cfg.precision_max and cfg.precision_max > 0 then
        local maxText = format('%.' .. cfg.precision_max .. 'f', secondsMax)
        fullText = timeText .. ' / ' .. maxText
    else
        fullText = timeText .. 's'
    end

    if unitType == "player" then
        local textMode = cfg.text_mode or "simple"
        if textMode ~= "simple" and frames.timeValue and frames.timeMax then
            frames.timeValue:SetText(timeText)
            frames.timeMax:SetText(' / ' .. format('%.' .. (cfg.precision_max or 1) .. 'f', secondsMax))
        end
    else
        if frames.castTimeText then
            frames.castTimeText:SetText(fullText)
        end
        if frames.castTimeTextCompact then
            frames.castTimeTextCompact:SetText(fullText)
        end
    end
end

-- ============================================================================
-- CASTBAR CREATION
-- ============================================================================

local function CreateTextElements(parent, unitType)
    local fontSize = unitType == "player" and 'GameFontHighlight' or 'GameFontHighlightSmall'
    local elements = {}

    -- Main cast text
    elements.castText = parent:CreateFontString(nil, 'OVERLAY', fontSize)
    elements.castText:SetPoint('BOTTOMLEFT', parent, 'BOTTOMLEFT', unitType == "player" and 8 or 6, 2)
    elements.castText:SetJustifyH("LEFT")

    -- Compact cast text
    elements.castTextCompact = parent:CreateFontString(nil, 'OVERLAY', fontSize)
    elements.castTextCompact:SetPoint('BOTTOMLEFT', parent, 'BOTTOMLEFT', unitType == "player" and 8 or 6, 2)
    elements.castTextCompact:SetJustifyH("LEFT")
    elements.castTextCompact:Hide()

    -- Centered text for simple mode
    elements.castTextCentered = parent:CreateFontString(nil, 'OVERLAY', fontSize)
    elements.castTextCentered:SetPoint('BOTTOM', parent, 'BOTTOM', 0, 1)
    elements.castTextCentered:SetPoint('LEFT', parent, 'LEFT', unitType == "player" and 8 or 6, 0)
    elements.castTextCentered:SetPoint('RIGHT', parent, 'RIGHT', unitType == "player" and -8 or -6, 0)
    elements.castTextCentered:SetJustifyH("CENTER")
    elements.castTextCentered:Hide()

    -- Time text
    elements.castTimeText = parent:CreateFontString(nil, 'OVERLAY', fontSize)
    elements.castTimeText:SetPoint('BOTTOMRIGHT', parent, 'BOTTOMRIGHT', unitType == "player" and -8 or -6, 2)
    elements.castTimeText:SetJustifyH("RIGHT")

    -- Compact time text
    elements.castTimeTextCompact = parent:CreateFontString(nil, 'OVERLAY', fontSize)
    elements.castTimeTextCompact:SetPoint('BOTTOMRIGHT', parent, 'BOTTOMRIGHT', unitType == "player" and -8 or -6, 2)
    elements.castTimeTextCompact:SetJustifyH("RIGHT")
    elements.castTimeTextCompact:Hide()

    -- Player-specific time elements
    if unitType == "player" then
        elements.timeValue = parent:CreateFontString(nil, 'OVERLAY', fontSize)
        elements.timeValue:SetPoint('BOTTOMRIGHT', parent, 'BOTTOMRIGHT', -50, 2)
        elements.timeValue:SetJustifyH("RIGHT")

        elements.timeMax = parent:CreateFontString(nil, 'OVERLAY', fontSize)
        elements.timeMax:SetPoint('LEFT', elements.timeValue, 'RIGHT', 2, 0)
        elements.timeMax:SetJustifyH("LEFT")
    end

    return elements
end
local function CreateCastbar(unitType)
    if CastbarModule.frames[unitType].castbar then
        return
    end

    local frameName = 'DragonUI' .. unitType:sub(1, 1):upper() .. unitType:sub(2) .. 'Castbar'
    local frames = CastbarModule.frames[unitType]

    -- Create unified container frame (RetailUI pattern)
    frames.container = CreateFrame('Frame', frameName .. 'Container', UIParent)
    frames.container:SetFrameStrata("MEDIUM")
    frames.container:SetFrameLevel(10)
    frames.container:SetSize(256, 16)  -- Default size - will be updated by positioning functions
    frames.container:SetPoint("CENTER", UIParent, "CENTER", 0, -150)  -- Default position - will be updated
    frames.container:Hide()

    -- Main StatusBar (as child of container)
    frames.castbar = CreateFrame('StatusBar', frameName, frames.container)
    frames.castbar:SetFrameLevel(1)  -- Relative to container
    frames.castbar:SetAllPoints(frames.container)  -- Fill entire container
    frames.castbar:SetMinMaxValues(0, 1)
    frames.castbar:SetValue(0)
    
    -- RetailUI pattern: Add simple state flags directly to statusBar
    frames.castbar.castingEx = false
    frames.castbar.channelingEx = false
    frames.castbar.fadeOutEx = false
    frames.castbar.selfInterrupt = false

    -- Background
    local bg = frames.castbar:CreateTexture(nil, 'BACKGROUND')
    bg:SetTexture(TEXTURES.atlas)
    bg:SetTexCoord(unpack(UV_COORDS.background))
    bg:SetAllPoints()

    -- StatusBar texture
    frames.castbar:SetStatusBarTexture(TEXTURES.standard)
    local texture = frames.castbar:GetStatusBarTexture()
    if texture then
        texture:SetVertexColor(1, 1, 1, 1)  -- RetailUI texture color reset
    end
    frames.castbar:SetStatusBarColor(1, 0.7, 0, 1)

    -- Border
    local border = frames.castbar:CreateTexture(nil, 'ARTWORK', nil, 0)
    border:SetTexture(TEXTURES.atlas)
    border:SetTexCoord(unpack(UV_COORDS.border))
    border:SetPoint("TOPLEFT", frames.castbar, "TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", frames.castbar, "BOTTOMRIGHT", 2, -2)

    -- Channel ticks
    frames.ticks = {}
    CreateChannelTicks(frames.castbar, frames.ticks)

    -- Flash
    frames.flash = frames.castbar:CreateTexture(nil, 'OVERLAY')
    frames.flash:SetTexture(TEXTURES.atlas)
    frames.flash:SetTexCoord(unpack(UV_COORDS.flash))
    frames.flash:SetBlendMode('ADD')
    frames.flash:SetAllPoints()
    frames.flash:Hide()

    -- Icon y otros elementos...
    frames.icon = frames.castbar:CreateTexture(frameName .. "Icon", 'ARTWORK')
    frames.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    frames.icon:Hide()

    -- Icon border
    local iconBorder = frames.castbar:CreateTexture(nil, 'ARTWORK')
    iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    iconBorder:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    iconBorder:SetVertexColor(0.8, 0.8, 0.8, 1)
    iconBorder:Hide()
    frames.icon.Border = iconBorder

    -- Shield (for target/focus)
    if unitType ~= "player" then
        frames.shield = CreateShield(frames.castbar, frames.icon, frameName, 20)
    end

    -- Apply texture clipping system
    CreateTextureClipping(frames.castbar)

    -- Text background frame y elementos de texto (as child of container)
    frames.textBackground = CreateFrame('Frame', frameName .. 'TextBG', frames.container)
    frames.textBackground:SetFrameLevel(2)  -- Relative to container

    local textBg = frames.textBackground:CreateTexture(nil, 'BACKGROUND')
    if unitType == "player" then
        textBg:SetTexture(TEXTURES.atlas)
        textBg:SetTexCoord(0.001953125, 0.410109375, 0.00390625, 0.11328125)
    else
        textBg:SetTexture(TEXTURES.atlasSmall)
        textBg:SetTexCoord(unpack(UV_COORDS.textBorder))
    end
    textBg:SetAllPoints()

    -- Create text elements
    local textElements = CreateTextElements(frames.textBackground, unitType)
    for key, element in pairs(textElements) do
        frames[key] = element
    end

    -- Background frame (as child of container)
    if unitType ~= "player" then
        frames.background = CreateFrame('Frame', frameName .. 'Background', frames.container)
        frames.background:SetFrameLevel(0)  -- Behind everything in container
        frames.background:SetAllPoints(frames.castbar)
    else
        frames.background = frames.textBackground
    end

    -- OnUpdate handler
    frames.castbar:SetScript('OnUpdate', function(self, elapsed)
        CastbarModule:OnUpdate(unitType, self, elapsed)
    end)
end

-- ============================================================================
-- CASTING EVENT HANDLERS
-- ============================================================================
function CastbarModule:HandleCastStart_Simple(unitType, unit, isChanneling)
    local spell, displayName, icon, startTime, endTime

    if isChanneling then
        spell, _, displayName, icon, startTime, endTime = UnitChannelInfo(unit)
    else
        spell, _, displayName, icon, startTime, endTime = UnitCastingInfo(unit)
    end

    if not spell then
        return
    end

    self:RefreshCastbar(unitType)

    local frames = self.frames[unitType]
    local castbar = frames.castbar

    -- RetailUI pattern: Set GUID for target/focus verification
    if unitType == "target" or unitType == "focus" then
        castbar.unit = UnitGUID(unit)
    end

    local start, finish, duration = ParseCastTimes(startTime, endTime)
    
    -- RetailUI pattern: Store times directly in statusBar frame
    castbar.startTime = start
    castbar.endTime = finish
    
    -- CRITICAL: Cancel any active fade when starting new cast (spam protection)
    castbar.fadeOutEx = false
    if frames.container then
        frames.container.fadeOutEx = false
    end

    -- RetailUI pattern: Always use 0-1 range for StatusBar
    castbar:SetMinMaxValues(0, 1)
    
    -- RetailUI pattern: Always use 0-1 range, StatusBar handles visual correctly
    if isChanneling then
        -- CHANNELING: Start at 1.0 (full)
        castbar:SetValue(1.0)
        castbar.channelingEx = true
        castbar.castingEx = false
        -- Initialize texture clipping for channeling
        if castbar.UpdateTextureClipping then
            castbar:UpdateTextureClipping(1.0, true)
        end
    else
        -- CASTING: Start at 0.0 (empty)  
        castbar:SetValue(0.0)
        castbar.castingEx = true
        castbar.channelingEx = false
        -- Initialize texture clipping for casting
        if castbar.UpdateTextureClipping then
            castbar:UpdateTextureClipping(0.0, false)
        end
    end
    
    -- RetailUI pattern: Container handles visibility - individual elements shown as needed
    -- RestoreCastbarVisibility already handles showing the container
    RestoreCastbarVisibility(unitType)
    
    if frames.background and frames.background ~= frames.textBackground then
        frames.background:Show()
    end

    if frames.spark then
        frames.spark:Show()
    end
    if frames.flash then
        frames.flash:Hide()
    end

    HideAllTicks(frames.ticks)

    -- Set texture based on type
    if isChanneling then
        frames.castbar:SetStatusBarTexture(TEXTURES.channel)
        frames.castbar:SetStatusBarColor(unitType == "player" and 0 or 1, 1, unitType == "player" and 1 or 1, 1)
        UpdateChannelTicks(frames.castbar, frames.ticks, spell)
        -- RetailUI pattern: Reset texture color to see real texture colors
        local texture = frames.castbar:GetStatusBarTexture()
        if texture then
            texture:SetVertexColor(1, 1, 1, 1)
        end
    else
        frames.castbar:SetStatusBarTexture(TEXTURES.standard)
        frames.castbar:SetStatusBarColor(1, 0.7, 0, 1)
        -- RetailUI pattern: Reset texture color to see real texture colors
        local texture = frames.castbar:GetStatusBarTexture()
        if texture then
            texture:SetVertexColor(1, 1, 1, 1)
        end
    end

    ForceStatusBarLayer(frames.castbar)
    SetCastText(unitType, displayName)

 

    -- Configure icon and other elements...
    local cfg = GetConfig(unitType)
    if frames.icon and cfg and cfg.showIcon then
        frames.icon:SetTexture(GetSpellIcon(displayName, icon))
        frames.icon:Show()
        if frames.icon.Border then
            frames.icon.Border:Show()
        end
    else
        if frames.icon then
            frames.icon:Hide()
        end
        if frames.icon and frames.icon.Border then
            frames.icon.Border:Hide()
        end
    end

    if frames.textBackground then
        frames.textBackground:Show()
        frames.textBackground:ClearAllPoints()
        frames.textBackground:SetSize(frames.castbar:GetWidth(), unitType == "player" and 22 or 20)
        frames.textBackground:SetPoint("TOP", frames.castbar, "BOTTOM", 0, unitType == "player" and 6 or 8)
    end
end
function CastbarModule:HandleCastStop_Simple(unitType, wasInterrupted, isChannelStop)
    local frames = self.frames[unitType]
    local castbar = frames.castbar

    -- RetailUI pattern: GUID verification for target/focus
    if unitType == "target" then
        if castbar.unit ~= UnitGUID("target") then
            return
        end
    elseif unitType == "focus" then
        if castbar.unit ~= UnitGUID("focus") then
            return
        end
    end

    if not (castbar.castingEx or castbar.channelingEx) and not wasInterrupted then
        return
    end

    local cfg = GetConfig(unitType)
    if not cfg then
        return
    end

    -- RetailUI pattern: Clear casting/channeling flags
    castbar.castingEx = false
    castbar.channelingEx = false
    
    -- RetailUI pattern: selfInterrupt ONLY for channel stops
    castbar.selfInterrupt = isChannelStop or false

    if wasInterrupted or castbar.selfInterrupt then
        -- Show interrupted state
        if frames.shield then frames.shield:Hide() end
        if frames.spark then frames.spark:Hide() end
        if frames.flash then frames.flash:Hide() end
        HideAllTicks(frames.ticks)

        castbar:SetStatusBarTexture(TEXTURES.interrupted)
        castbar:SetStatusBarColor(1, 0, 0, 1)
        castbar:SetValue(1.0)  -- Always full for interrupted display
        -- Reset texture clipping to show full interrupted texture
        local texture = castbar:GetStatusBarTexture()
        if texture then
            texture:SetTexCoord(0, 1, 0, 1)  -- Show complete texture
            texture:SetVertexColor(1, 1, 1, 1)
        end

        SetCastText(unitType, "Interrupted")
        
        -- RetailUI pattern: Fade all elements consistently
        FadeOutCastbar(unitType, 1)

    else
        -- Normal completion
        if frames.spark then frames.spark:Hide() end
        if frames.shield then frames.shield:Hide() end
        HideAllTicks(frames.ticks)

        -- Reset texture clipping to show full completion texture
        local texture = castbar:GetStatusBarTexture()
        if texture then
            texture:SetTexCoord(0, 1, 0, 1)  -- Show complete texture for flash
        end

        if frames.flash then
            frames.flash:Show()
            addon.core:ScheduleTimer(function()
                if frames.flash then
                    frames.flash:Hide()
                end
            end, 0.3)
        end

        -- RetailUI pattern: Fade all elements consistently  
        FadeOutCastbar(unitType, 1)
    end
end

function CastbarModule:HandleCastFailed_Simple(unitType)
    local frames = self.frames[unitType]
    local castbar = frames.castbar
    
    if not castbar then
        return
    end
    
    -- RetailUI pattern: FAILED events do NOTHING to textures/colors
    -- Let the casting continue normally without any visual changes
    -- This prevents interfering with the ongoing cast visualization
    
    -- DO NOT fade like RetailUI - let cast continue normally
end


-- ============================================================================
-- UPDATE HANDLER
-- ============================================================================
function CastbarModule:OnUpdate(unitType, castbar, elapsed)
    local frames = self.frames[unitType]
    if not frames then
        return
    end
    local cfg = GetConfig(unitType)

    if not cfg or not cfg.enabled then
        return
    end

    -- RetailUI pattern: Exact same logic as RetailUI CastingBarFrame_OnUpdate
    if castbar.channelingEx or castbar.castingEx then
        local currentTime, value, remainingTime = GetTime(), 0, 0
        
        if castbar.castingEx then
            remainingTime = min(currentTime, castbar.endTime) - castbar.startTime
            value = remainingTime / (castbar.endTime - castbar.startTime)
        elseif castbar.channelingEx then
            remainingTime = castbar.endTime - currentTime
            value = remainingTime / (castbar.endTime - castbar.startTime)
        end

        castbar:SetValue(value)

        -- Apply texture clipping for smooth visual effect
        if castbar.UpdateTextureClipping then
            castbar:UpdateTextureClipping(value, castbar.channelingEx)
        end

        if currentTime > castbar.endTime then
            castbar.castingEx, castbar.channelingEx = false, false
            -- RetailUI pattern: Actually start fade when cast completes
            FadeOutCastbar(unitType, 1)
        end

        -- Update spark position using RetailUI pattern
        if frames.spark and frames.spark:IsShown() then
            frames.spark:ClearAllPoints()
            frames.spark:SetPoint('CENTER', castbar, 'LEFT', value * castbar:GetWidth(), 0)
        end

        UpdateTimeText(unitType)
    end
end
-- ============================================================================
-- CASTBAR REFRESH
-- ============================================================================

function CastbarModule:RefreshCastbar(unitType)
    local cfg = GetConfig(unitType)
    if not cfg then
        return
    end

    if cfg.enabled then
        HideBlizzardCastbar(unitType)
    else
        ShowBlizzardCastbar(unitType)
        self:HideCastbar(unitType)
        return
    end

    if not self.frames[unitType].castbar then
        CreateCastbar(unitType)
    end

    local frames = self.frames[unitType]
    local frameName = 'DragonUI' .. unitType:sub(1, 1):upper() .. unitType:sub(2) .. 'Castbar'

    -- Calculate aura offset using unified function
    local auraOffset = cfg.autoAdjust and GetAuraOffset(unitType) or 0

    -- Calculate positioning for container
    -- (castbar fills container automatically via SetAllPoints)
    local anchorFrame = UIParent
    local anchorPoint = "CENTER"
    local relativePoint = "BOTTOM"
    local xPos = cfg.x_position or 0
    local yPos = cfg.y_position or 200

    if unitType == "player" then
        --  USAR ANCHOR FRAME PARA PLAYER CASTBAR (SISTEMA CENTRALIZADO)
        if self.anchor then
            anchorFrame = self.anchor
            anchorPoint = "CENTER"
            relativePoint = "CENTER"
            xPos = 0 -- Relativo al anchor, no offset adicional
            yPos = 0
        else
            -- Fallback si no hay anchor (modo legacy)
            anchorFrame = UIParent
            anchorPoint = "BOTTOM"
            relativePoint = "BOTTOM"
        end
    elseif unitType ~= "player" then
        anchorFrame = _G[cfg.anchorFrame] or (unitType == "target" and TargetFrame or FocusFrame) or UIParent
        anchorPoint = cfg.anchor or "CENTER"
        relativePoint = cfg.anchorParent or "BOTTOM"
    end

    -- RetailUI pattern: Position and size container instead of individual castbar
    if not frames.container then
        CreateCastbar(unitType)
    end
    
    frames.container:SetPoint(anchorPoint, anchorFrame, relativePoint, xPos, yPos - auraOffset)
    frames.container:SetSize(cfg.sizeX or 200, cfg.sizeY or 16)
    frames.container:SetScale(cfg.scale or 1)  -- Apply scale to container, not individual castbar

    -- Create spark if needed
    if not frames.spark then
        frames.spark = CreateFrame("Frame", frameName .. "Spark", UIParent)
        frames.spark:SetFrameStrata("MEDIUM")
        frames.spark:SetFrameLevel(11)
        frames.spark:SetSize(16, 16)
        frames.spark:Hide()

        local sparkTexture = frames.spark:CreateTexture(nil, 'ARTWORK')
        sparkTexture:SetTexture(TEXTURES.spark)
        sparkTexture:SetAllPoints()
        sparkTexture:SetBlendMode('ADD')
    end

    -- Spark needs its own scale (not inside container)
    frames.spark:SetScale(cfg.scale or 1)

    -- Position text background
    if frames.textBackground then
        frames.textBackground:ClearAllPoints()
        frames.textBackground:SetPoint('TOP', frames.castbar, 'BOTTOM', 0, unitType == "player" and 6 or 8)
        frames.textBackground:SetSize(cfg.sizeX or 200, unitType == "player" and 22 or 20)
        -- Text background scaling handled by container scale
    end

    -- Configure icon
    if frames.icon then
        local iconSize = cfg.sizeIcon or 20
        frames.icon:SetSize(iconSize, iconSize)
        frames.icon:ClearAllPoints()

        if unitType == "player" then
            frames.icon:SetPoint('TOPLEFT', frames.castbar, 'TOPLEFT', -(iconSize + 6), -1)
        else
            local iconScale = iconSize / 16
            frames.icon:SetPoint('RIGHT', frames.castbar, 'LEFT', -7 * iconScale, -4)
        end

        if frames.icon.Border then
            frames.icon.Border:ClearAllPoints()
            frames.icon.Border:SetPoint('CENTER', frames.icon, 'CENTER', 0, 0)
            frames.icon.Border:SetSize(iconSize * 1.7, iconSize * 1.7)
        end

        if frames.shield then
            if unitType == "player" then
                frames.shield:ClearAllPoints()
                frames.shield:SetPoint('CENTER', frames.icon, 'CENTER', 0, 0)
                frames.shield:SetSize(iconSize * 0.8, iconSize * 0.8)
            else
                frames.shield:SetSize(iconSize * 1.8, iconSize * 2.0)
            end
        end
    end

    -- Update spark size
    if frames.spark then
        local sparkSize = cfg.sizeY or 16
        frames.spark:SetSize(sparkSize, sparkSize * 2)
        -- Spark needs its own scale (not inside container)
        frames.spark:SetScale(cfg.scale or 1)
    end

    -- Update tick sizes
    if frames.ticks then
        for i = 1, MAX_TICKS do
            if frames.ticks[i] then
                -- ✅ CRITICAL: Usar la altura REAL del castbar después de SetSize/SetScale
                local realHeight = frames.castbar:GetHeight()
                frames.ticks[i]:SetSize(3, max(realHeight - 2, 10))
            end
        end
    end

    -- Set compact layout for target/focus
    if unitType ~= "player" then
        SetTextMode(unitType, cfg.text_mode or "simple")
    end

    -- Ensure proper frame levels
    frames.castbar:SetFrameLevel(10)
    if frames.background then
        frames.background:SetFrameLevel(9)
    end
    if frames.textBackground then
        frames.textBackground:SetFrameLevel(9)
    end

    HideBlizzardCastbar(unitType)

    if cfg.text_mode then
        SetTextMode(unitType, cfg.text_mode)
    end
end

function CastbarModule:HideCastbar(unitType)
    local frames = self.frames[unitType]

    -- RetailUI pattern: Hide entire container instead of individual elements
    if frames.container then
        frames.container:Hide()
    end
    
    -- Reset StatusBar flags
    local castbar = frames.castbar
    if castbar then
        castbar.castingEx = false
        castbar.channelingEx = false
        castbar.fadeOutEx = false
        castbar.selfInterrupt = false
        castbar.startTime = 0
        castbar.endTime = 0
        castbar.unit = nil
    end
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

function CastbarModule:HandleCastingEvent(event, unit)
    local unitType
    if unit == "player" then
        unitType = "player"
    elseif unit == "target" then
        unitType = "target"
    elseif unit == "focus" then
        unitType = "focus"
    else
        return
    end

    if not IsEnabled(unitType) then
        return
    end

    HideBlizzardCastbar(unitType)

    -- GUID verification for target/focus
    if unitType ~= "player" then
        local frames = self.frames[unitType]
        if not frames.castbar then
            return
        end

        if event == 'UNIT_SPELLCAST_START' or event == 'UNIT_SPELLCAST_CHANNEL_START' then
            frames.castbar.unit = UnitGUID(unit)
        else
            if frames.castbar.unit ~= UnitGUID(unit) then
                return
            end
        end
    end

    -- Event handling
    if event == 'UNIT_SPELLCAST_START' then
        self:HandleCastStart_Simple(unitType, unit, false)
    elseif event == 'UNIT_SPELLCAST_CHANNEL_START' then
        self:HandleCastStart_Simple(unitType, unit, true)
    elseif event == 'UNIT_SPELLCAST_STOP' then
        self:HandleCastStop_Simple(unitType, false)
    elseif event == 'UNIT_SPELLCAST_CHANNEL_STOP' then
        self:HandleCastStop_Simple(unitType, false, true)  -- selfInterrupt for channel stop only
    elseif event == 'UNIT_SPELLCAST_FAILED' then
        self:HandleCastFailed_Simple(unitType)
    elseif event == 'UNIT_SPELLCAST_INTERRUPTED' then
        self:HandleCastStop_Simple(unitType, true)
    elseif event == 'UNIT_SPELLCAST_CHANNEL_INTERRUPTED' then
        self:HandleCastStop_Simple(unitType, true)
    elseif event == 'UNIT_SPELLCAST_DELAYED' or event == 'UNIT_SPELLCAST_CHANNEL_UPDATE' then
        self:HandleCastDelayed_Simple(unitType, unit)
    end
end

function CastbarModule:HandleTargetChanged()
    local frames = self.frames.target
    local statusBar = frames.castbar

    if not statusBar then
        return
    end

    -- ✅ FIXED: Limpiar estado siempre que el GUID no coincida
    if UnitExists("target") and statusBar.unit == UnitGUID("target") then
        -- Same target, check if cast should still be visible
        if GetTime() > (statusBar.endTime or 0) then
            self:HideCastbar("target") -- ← Usar HideCastbar para limpieza completa
        else
            statusBar:Show()
        end
    else
        -- Different target or no target - CLEAN EVERYTHING
        self:HideCastbar("target") -- ← CRITICAL: Limpiar estado completo
    end

    HideBlizzardCastbar("target")

    -- Check if new target has active cast
    if UnitExists("target") and IsEnabled("target") then
        if UnitCastingInfo("target") then
            self:HandleCastingEvent('UNIT_SPELLCAST_START', "target")
        elseif UnitChannelInfo("target") then
            self:HandleCastingEvent('UNIT_SPELLCAST_CHANNEL_START', "target")
        end
        ApplyAuraOffset("target")
    end
end

function CastbarModule:HandleFocusChanged()
    local frames = self.frames.focus
    local statusBar = frames.castbar

    if not statusBar then
        return
    end

    -- ✅ FIXED: Misma lógica para focus
    if UnitExists("focus") and statusBar.unit == UnitGUID("focus") then
        -- Same focus, check if cast should still be visible
        if GetTime() > (statusBar.endTime or 0) then
            self:HideCastbar("focus") -- ← Usar HideCastbar para limpieza completa
        else
            statusBar:Show()
        end
    else
        -- Different focus or no focus - CLEAN EVERYTHING
        self:HideCastbar("focus") -- ← CRITICAL: Limpiar estado completo
    end

    HideBlizzardCastbar("focus")

    -- Check if new focus has active cast
    if UnitExists("focus") and IsEnabled("focus") then
        if UnitCastingInfo("focus") then
            self:HandleCastingEvent('UNIT_SPELLCAST_START', "focus")
        elseif UnitChannelInfo("focus") then
            self:HandleCastingEvent('UNIT_SPELLCAST_CHANNEL_START', "focus")
        end
        ApplyAuraOffset("focus")
    end
end

-- ============================================================================
-- Función de manejo de delays 
-- ============================================================================
function CastbarModule:HandleCastDelayed_Simple(unitType, unit)
    local frames = self.frames[unitType]
    local castbar = frames.castbar

    if not castbar or not (castbar.castingEx or castbar.channelingEx) then
        return
    end

    local spell, startTime, endTime

    if castbar.castingEx then
        spell, _, _, _, startTime, endTime = UnitCastingInfo(unit)
    else
        spell, _, _, _, startTime, endTime = UnitChannelInfo(unit)
    end

    if not spell then
        self:HideCastbar(unitType)
        return
    end

    -- RetailUI pattern: Update statusBar times for OnUpdate calculations
    local start = startTime / 1000
    local finish = endTime / 1000
    
    castbar.startTime = start
    castbar.endTime = finish
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================
local function OnEvent(self, event, unit, ...)
    if event == 'UNIT_AURA' and unit == 'target' then
        local cfg = GetConfig("target")
        if cfg and cfg.enabled and cfg.autoAdjust then
            addon.core:ScheduleTimer(function() ApplyAuraOffset("target") end, 0.05)
        end
    elseif event == 'UNIT_AURA' and unit == 'focus' then
        local cfg = GetConfig("focus")
        if cfg and cfg.enabled and cfg.autoAdjust then
            addon.core:ScheduleTimer(function() ApplyAuraOffset("focus") end, 0.05)
        end
    elseif event == 'PLAYER_TARGET_CHANGED' then
        CastbarModule:HandleTargetChanged()
    elseif event == 'PLAYER_FOCUS_CHANGED' then
        CastbarModule:HandleFocusChanged()
    elseif event == 'PLAYER_ENTERING_WORLD' then
        addon.core:ScheduleTimer(function()
            CastbarModule:RefreshCastbar("player")
            CastbarModule:RefreshCastbar("target")
            CastbarModule:RefreshCastbar("focus")

            addon.core:ScheduleTimer(function()
                if IsEnabled("player") then
                    HideBlizzardCastbar("player")
                end
                if IsEnabled("target") then
                    HideBlizzardCastbar("target")
                end
                if IsEnabled("focus") then
                    HideBlizzardCastbar("focus")
                end
            end, 1.0)
        end, 0.5)
    else
        CastbarModule:HandleCastingEvent(event, unit)
    end
end

-- Public API (simplified)
function addon.RefreshCastbar()
    CastbarModule:RefreshCastbar("player")
end

function addon.RefreshTargetCastbar()
    CastbarModule:RefreshCastbar("target")
end

-- Initialize
local eventFrame = CreateFrame('Frame', 'DragonUICastbarEventHandler')
local events = {'PLAYER_ENTERING_WORLD', 'UNIT_SPELLCAST_START', 'UNIT_SPELLCAST_DELAYED', 'UNIT_SPELLCAST_STOP',
                'UNIT_SPELLCAST_FAILED', 'UNIT_SPELLCAST_INTERRUPTED', 'UNIT_SPELLCAST_CHANNEL_START',
                'UNIT_SPELLCAST_CHANNEL_STOP', 'UNIT_SPELLCAST_CHANNEL_UPDATE', 'UNIT_AURA', 'PLAYER_TARGET_CHANGED',
                'PLAYER_FOCUS_CHANGED'}

for _, event in ipairs(events) do
    eventFrame:RegisterEvent(event)
end

eventFrame:SetScript('OnEvent', OnEvent)

-- Hook native WoW aura positioning
if TargetFrameSpellBar then
    hooksecurefunc('Target_Spellbar_AdjustPosition', function()
        local cfg = GetConfig("target")
        if cfg and cfg.enabled and cfg.autoAdjust then
            addon.core:ScheduleTimer(function() ApplyAuraOffset("target") end, 0.05)
        end
    end)
end

--  También necesitamos asegurar que el TargetFrameSpellBar no interfiera
if TargetFrameSpellBar then
    -- Disable Blizzard's own hiding logic that might interfere
    TargetFrameSpellBar:SetScript("OnHide", nil)
    TargetFrameSpellBar:SetScript("OnShow", function(self)
        local cfg = GetConfig("target")
        if cfg and cfg.enabled then
            self:Hide()
        end
    end)
end

-- ============================================================================
-- CENTRALIZED SYSTEM INTEGRATION
-- ============================================================================

-- Variables para el sistema centralizado
CastbarModule.anchor = nil
CastbarModule.initialized = false

-- Create auxiliary frame for anchoring (como party.lua)
local function CreateCastbarAnchorFrame()
    if CastbarModule.anchor then
        return CastbarModule.anchor
    end

    --  USAR FUNCIÓN CENTRALIZADA DE CORE.LUA
    CastbarModule.anchor = addon.CreateUIFrame(256, 16, "PlayerCastbar")

    --  PERSONALIZAR TEXTO PARA CASTBAR
    if CastbarModule.anchor.editorText then
        CastbarModule.anchor.editorText:SetText("Player Castbar")
    end

    return CastbarModule.anchor
end

--  FUNCIÓN PARA APLICAR POSICIÓN DESDE WIDGETS (COMO party.lua)
local function ApplyWidgetPosition()
    if not CastbarModule.anchor then
        return
    end

    if not addon.db or not addon.db.profile or not addon.db.profile.widgets then
        return
    end

    local widgetConfig = addon.db.profile.widgets.playerCastbar

    if widgetConfig and widgetConfig.posX and widgetConfig.posY then
        local anchor = widgetConfig.anchor or "BOTTOM"
        CastbarModule.anchor:ClearAllPoints()
        CastbarModule.anchor:SetPoint(anchor, UIParent, anchor, widgetConfig.posX, widgetConfig.posY)
    else
        -- Default position
        CastbarModule.anchor:ClearAllPoints()
        CastbarModule.anchor:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 270)
    end
end

--  FUNCIONES REQUERIDAS POR EL SISTEMA CENTRALIZADO
function CastbarModule:LoadDefaultSettings()
    if not addon.db.profile.widgets then
        addon.db.profile.widgets = {}
    end

    if not addon.db.profile.widgets.playerCastbar then
        addon.db.profile.widgets.playerCastbar = {
            anchor = "BOTTOM",
            posX = 0,
            posY = 270
        }
    end

    if not addon.db.profile.castbar then
        addon.db.profile.castbar = {}
    end
end

function CastbarModule:UpdateWidgets()
    ApplyWidgetPosition()
    --  REPOSICIONAR EL CASTBAR DEL PLAYER RELATIVO AL ANCHOR ACTUALIZADO
    if not InCombatLockdown() then
        -- El castbar del player debería seguir al anchor
        self:RefreshCastbar("player")
    end
end

--  FUNCIÓN PARA VERIFICAR SI EL CASTBAR DEBE ESTAR VISIBLE
local function ShouldPlayerCastbarBeVisible()
    local cfg = GetConfig("player")
    return cfg and cfg.enabled
end

--  FUNCIONES DE TESTEO PARA EL EDITOR
local function ShowPlayerCastbarTest()
    -- RetailUI pattern: Show container instead of individual elements
    local frames = CastbarModule.frames.player
    if not frames.container then
        CreateCastbar("player")
    end
    
    if frames.container then
        -- Show container with test cast
        frames.container:Show()
        
        -- Mostrar texto de prueba
        CastbarModule:ShowCastbar("player", "Fire ball", 0.5, 1, 1.5, false, false)
    end
end

local function HidePlayerCastbarTest()
    -- Ocultar el castbar de prueba
    CastbarModule:HideCastbar("player")
end

--  FUNCIÓN AUXILIAR PARA MOSTRAR CASTBAR (USADA EN TESTS)
function CastbarModule:ShowCastbar(unitType, spellName, currentValue, maxValue, duration, isChanneling, isInterrupted)
    -- Public API compatibility function - converts old parameters to new system
    local frames = self.frames[unitType]
    if not frames.castbar then
        self:RefreshCastbar(unitType)
        frames = self.frames[unitType]
    end

    if not frames.castbar then
        return
    end

    local castbar = frames.castbar
    local currentTime = GetTime()
    
    -- RetailUI pattern: Set StatusBar times and flags directly
    castbar.startTime = currentTime
    castbar.endTime = currentTime + (duration or maxValue or 1)
    castbar.castingEx = not isChanneling
    castbar.channelingEx = isChanneling
    castbar.fadeOutEx = false
    castbar.selfInterrupt = false

    -- Always use 0-1 range
    castbar:SetMinMaxValues(0, 1)
    
    -- Convert currentValue/maxValue to 0-1 range
    local progress = maxValue > 0 and (currentValue / maxValue) or 0
    if isChanneling then
        -- For channeling, invert the progress
        progress = 1 - progress
    end
    castbar:SetValue(progress)
    -- RetailUI pattern: Show entire container instead of individual elements
    if not frames.container then
        CreateCastbar(unitType)
    end
    
    frames.container:Show()
    
    -- Fix: Cancel any active fadeout and restore full visibility
    UIFrameFadeRemoveFrame(frames.container)
    frames.container:SetAlpha(1.0)

    if isInterrupted then
        castbar:SetStatusBarTexture(TEXTURES.interrupted)
        local texture = castbar:GetStatusBarTexture()
        if texture then
            texture:SetVertexColor(1, 1, 1, 1)  -- RetailUI texture color reset
        end
        castbar:SetStatusBarColor(1, 0, 0, 1)
        SetCastText(unitType, "Interrupted")
        castbar.selfInterrupt = true
    else
        if isChanneling then
            castbar:SetStatusBarTexture(TEXTURES.channel)
            local texture = castbar:GetStatusBarTexture()
            if texture then
                texture:SetVertexColor(1, 1, 1, 1)  -- RetailUI texture color reset
            end
            castbar:SetStatusBarColor(0, 1, 0, 1)
        else
            castbar:SetStatusBarTexture(TEXTURES.standard)
            local texture = castbar:GetStatusBarTexture()
            if texture then
                texture:SetVertexColor(1, 1, 1, 1)  -- RetailUI texture color reset
            end
            castbar:SetStatusBarColor(1, 0.7, 0, 1)
        end
        SetCastText(unitType, spellName)
    end

    if frames.textBackground then
        frames.textBackground:Show()
    end

    ForceStatusBarLayer(castbar)
end

--  FUNCIÓN DE INICIALIZACIÓN DEL SISTEMA CENTRALIZADO
local function InitializeCastbarForEditor()
    -- Crear el anchor frame
    CreateCastbarAnchorFrame()

    --  REGISTRO COMPLETO CON TODAS LAS FUNCIONES (COMO party.lua)
    addon:RegisterEditableFrame({
        name = "PlayerCastbar",
        frame = CastbarModule.anchor,
        configPath = {"widgets", "playerCastbar"}, --  CORREGIDO: Array en lugar de string
        hasTarget = ShouldPlayerCastbarBeVisible, --  Visibilidad condicional
        showTest = ShowPlayerCastbarTest, --  CORREGIDO: Minúscula como party.lua
        hideTest = HidePlayerCastbarTest, --  CORREGIDO: Minúscula como party.lua
        onHide = function()
            CastbarModule:UpdateWidgets()
        end, --  AÑADIDO: Para aplicar cambios
        LoadDefaultSettings = function()
            CastbarModule:LoadDefaultSettings()
        end,
        UpdateWidgets = function()
            CastbarModule:UpdateWidgets()
        end
    })

    CastbarModule.initialized = true

end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

--  Initialize centralized system for editor
InitializeCastbarForEditor()

--  LISTENER PARA CUANDO EL ADDON ESTÉ COMPLETAMENTE CARGADO
local readyFrame = CreateFrame("Frame")
readyFrame:RegisterEvent("ADDON_LOADED")
readyFrame:SetScript("OnEvent", function(self, event, addonName)
    if addonName == "DragonUI" then
        -- Aplicar posición del widget cuando el addon esté listo
        if CastbarModule.UpdateWidgets then
            CastbarModule:UpdateWidgets()
        end
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
