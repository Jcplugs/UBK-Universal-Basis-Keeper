-- Shared click-to-front behavior for UBK's interface, dock and resolve dialogs.
-- TSM's Auction and Mailing roots use HIGH. We join that layer when selected,
-- and move our own windows behind another UI window when the player selects it.
_G.UBKWindowFocus = {}
local Focus = _G.UBKWindowFocus
local selected
local windows = setmetatable({}, {__mode="k"})
local hooked = setmetatable({}, {__mode="k"})
local below = {BACKGROUND="BACKGROUND", LOW="BACKGROUND", MEDIUM="LOW", HIGH="MEDIUM", DIALOG="HIGH", FULLSCREEN="HIGH", FULLSCREEN_DIALOG="HIGH", TOOLTIP="HIGH"}

local function OwnedRoot(frame)
    for _=1,40 do
        if not frame or frame==UIParent or frame==WorldFrame then break end
        if windows[frame] then return frame end
        frame=frame.GetParent and frame:GetParent() or nil
    end
    return nil
end

function Focus.Raise(frame)
    local root=OwnedRoot(frame) or (windows[frame] and frame)
    if not root then return end
    selected=root
    for window in pairs(windows) do
        if window.SetFrameStrata and (not window.IsProtected or not window:IsProtected() or not InCombatLockdown or not InCombatLockdown()) then
            window:SetFrameStrata(OwnedRoot(window)==root and "HIGH" or "MEDIUM")
        end
    end
    if root.Raise then root:Raise() end
    if frame~=root and frame.Raise then frame:Raise() end
end

function Focus.RegisterChildren(root)
    if not root or not root.GetChildren then return end
    for _,child in ipairs({root:GetChildren()}) do
        if not child.IsShown or child:IsShown() then
            if not hooked[child] and child.HookScript then
                local canHook=not child.HasScript or child:HasScript("OnMouseDown")
                if canHook then
                    child:HookScript("OnMouseDown",function(self) Focus.Raise(self) end)
                    hooked[child]=true
                end
            end
            Focus.RegisterChildren(child)
        end
    end
end

function Focus.Register(frame)
    if not frame or windows[frame] then return end
    windows[frame]=true
    if frame.SetToplevel then frame:SetToplevel(true) end
    if frame.SetFrameStrata then frame:SetFrameStrata("HIGH") end
    if frame.HookScript then
        frame:HookScript("OnMouseDown",function(self) Focus.Raise(self) end)
        frame:HookScript("OnShow",function(self) Focus.RegisterChildren(self); Focus.Raise(self) end)
    end
    Focus.RegisterChildren(frame)
end

function Focus.IsSelected(frame) return selected~=nil and selected==OwnedRoot(frame) end

function Focus.SelectExternal(frame)
    if not frame or OwnedRoot(frame) then return end
    local root=frame
    for _=1,40 do
        local parent=root.GetParent and root:GetParent() or nil
        if not parent or parent==UIParent or parent==WorldFrame then break end
        root=parent
    end
    if root==UIParent or root==WorldFrame or not root.GetFrameStrata then return end
    selected=nil
    local strata=below[root:GetFrameStrata()] or "MEDIUM"
    for window in pairs(windows) do
        if window.SetFrameStrata and (not window.IsProtected or not window:IsProtected() or not InCombatLockdown or not InCombatLockdown()) then window:SetFrameStrata(strata) end
    end
    -- The selected addon/game frame keeps its own geometry and strata.
end

local events=CreateFrame("Frame")
-- Modern Classic clients support this event; older hosts retain normal
-- top-level raising and the explicit UBK click hooks if they do not.
local registered=pcall(events.RegisterEvent,events,"GLOBAL_MOUSE_DOWN")
if registered then
    events:SetScript("OnEvent",function()
        local target
        if type(GetMouseFoci)=="function" then
            local foci=GetMouseFoci()
            target=type(foci)=="table" and not foci.GetParent and foci[1] or foci
        elseif type(GetMouseFocus)=="function" then target=GetMouseFocus() end
        if OwnedRoot(target) then Focus.Raise(target) else Focus.SelectExternal(target) end
    end)
end
