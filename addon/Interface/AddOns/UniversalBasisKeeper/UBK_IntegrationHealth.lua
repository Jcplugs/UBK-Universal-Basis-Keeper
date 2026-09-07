-- Readiness check only. The installer supplies TSM's checked bridge loader.
-- No saved-data writes and no repeated polling after startup.
local message = "UBK Loaded Incorrectly, TSM-UBK integration failure. Please run installer again to patch."
local started, warned = false, false
local function Check(remaining)
    local bridge = _G.UBKTSMGroupBridge
    if bridge and bridge.ready == true and bridge.sourcesRegistered == true then return end
    if remaining > 0 then
        C_Timer.After(1, function() Check(remaining - 1) end)
        return
    end
    if warned then return end
    warned = true
    print("|cffff4444" .. message .. "|r")
    if type(PlaySound) == "function" and SOUNDKIT and SOUNDKIT.RAID_WARNING then
        pcall(PlaySound, SOUNDKIT.RAID_WARNING, "Master")
    end
end
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    if started then return end
    started = true
    -- TSM and the bridge initialize during login. Allow that startup to finish.
    C_Timer.After(1, function() Check(14) end)
end)
