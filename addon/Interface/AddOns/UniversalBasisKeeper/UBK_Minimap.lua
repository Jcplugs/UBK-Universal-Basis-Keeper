-- A lightweight draggable minimap launcher; no additional library dependency.
local button
local function Settings()
    if type(UniversalBasisKeeperDB)~="table" then UniversalBasisKeeperDB={} end
    if type(UniversalBasisKeeperDB.minimap)~="table" then UniversalBasisKeeperDB.minimap={angle=215} end
    return UniversalBasisKeeperDB.minimap
end
local function Position()
    local radians=(tonumber(Settings().angle) or 215)*math.pi/180
    local radius=(Minimap:GetWidth()/2)+8
    button:ClearAllPoints(); button:SetPoint("CENTER",Minimap,"CENTER",math.cos(radians)*radius,math.sin(radians)*radius)
end
local function Create()
    if button or not Minimap then return end
    button=CreateFrame("Button","UBKMinimapButton",Minimap)
    button:SetSize(32,32); button:SetFrameStrata("MEDIUM"); button:SetFrameLevel(Minimap:GetFrameLevel()+8)
    button:RegisterForClicks("LeftButtonUp","RightButtonUp"); button:RegisterForDrag("LeftButton")
    local icon=button:CreateTexture(nil,"ARTWORK"); icon:SetSize(20,20); icon:SetPoint("CENTER"); icon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Emerald_02")
    local border=button:CreateTexture(nil,"OVERLAY"); border:SetSize(54,54); border:SetPoint("TOPLEFT"); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    button:SetScript("OnClick",function(_,which)
        if which=="RightButton" and _G.UBKBasisSale then _G.UBKBasisSale:Show()
        elseif _G.UBKInterface_Show then _G.UBKInterface_Show("home") end
    end)
    button:SetScript("OnDragStart",function(self)
        self:SetScript("OnUpdate",function()
            local x,y=GetCursorPosition(); local scale=Minimap:GetEffectiveScale(); local cx,cy=Minimap:GetCenter()
            local dx,dy=x/scale-cx,y/scale-cy
            local angle=math.atan2 and math.atan2(dy,dx) or math.atan(dy,dx)
            Settings().angle=angle*180/math.pi; Position()
        end)
    end)
    button:SetScript("OnDragStop",function(self) self:SetScript("OnUpdate",nil) end)
    button:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_LEFT"); GameTooltip:AddLine("Universal Basis Keeper",1,.82,.2)
        GameTooltip:AddLine("Left-click: open UBK",1,1,1); GameTooltip:AddLine("Right-click: Sell Above Basis",1,1,1)
        GameTooltip:AddLine("Drag to move around the minimap",.7,.7,.7); GameTooltip:Show()
    end)
    button:SetScript("OnLeave",function() GameTooltip:Hide() end)
    Position(); button:Show()
end
local events=CreateFrame("Frame"); events:RegisterEvent("PLAYER_LOGIN"); events:SetScript("OnEvent",Create)
