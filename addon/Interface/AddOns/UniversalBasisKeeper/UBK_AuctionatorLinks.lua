-- TBC Auctionator's Shopping row uses Shift-click for search-fill. UBK makes
-- that click insert a chat draft; Ctrl+Shift retains Auctionator's old action.
-- No Auctionator files are edited and no message is sent automatically.
_G.UBKAuctionatorLinks={}
local Links=_G.UBKAuctionatorLinks
function Links.Install()
    if Links.installed then return true end
    local _,_,_,build=GetBuildInfo();build=tonumber(build)
    if not build or build<20500 or build>=30000 then return false end
    local mixin=_G.AuctionatorShoppingResultsRowMixin
    if type(mixin)~="table" or type(mixin.OnClick)~="function" then return false end
    local original=mixin.OnClick
    local function Click(self,button,...)
        local link=self.rowData and self.rowData.itemLink
        if button=="LeftButton" and IsShiftKeyDown() and not IsControlKeyDown() and not IsAltKeyDown()
            and type(link)=="string" and link:find("|Hitem:",1,true) then
            local active=ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
            if active and ChatEdit_InsertLink then
                if ChatEdit_InsertLink(link) then return end
            end
            if ChatFrame_OpenChat then ChatFrame_OpenChat(link.." ");return end
        end
        return original(self,button,...)
    end
    mixin.OnClick=Click
    -- XML may have instantiated reusable rows before UBK loaded. Update only
    -- rows carrying this exact method; all future rows use the patched mixin.
    if EnumerateFrames then
        local frame=EnumerateFrames()
        while frame do
            if frame.OnClick==original then
                frame.OnClick=Click
                if frame.GetScript and frame:GetScript("OnClick")==original then frame:SetScript("OnClick",Click) end
            end
            frame=EnumerateFrames(frame)
        end
    end
    Links.installed=true
    return true
end
local event=CreateFrame("Frame")
event:RegisterEvent("PLAYER_LOGIN");event:RegisterEvent("ADDON_LOADED")
event:SetScript("OnEvent",function(_,name,addon)
    if name=="PLAYER_LOGIN" or addon=="Auctionator" then C_Timer.After(0,Links.Install) end
end)
