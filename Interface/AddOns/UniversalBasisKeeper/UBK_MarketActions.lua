-- Player-clicked UI handoffs. Never buys, destroys, or casts.
local API=_G.UniversalBasisKeeperAPI
if type(API)~="table" then return end
function API:BrowseMarketItem(item)
    local state=self.GetShredderState and self:GetShredderState() or {}
    if state.liveScanning then return false,"Finish the UBK AH scan first." end
    if not self.IsAuctionVisible or not self:IsAuctionVisible() then return false,"Open the Auction House and select TSM Browse first." end
    local bridge=_G.UBKTSMGroupBridge
    if not bridge or not bridge.ready or type(bridge.BrowseItem)~="function" then return false,"UBK's TSM Browse integration is unavailable. Update the integration with the next UBK installer." end
    local ok,result,message=pcall(bridge.BrowseItem,item)
    if not ok then return false,"TSM could not start that search: "..tostring(result) end
    return result,message
end
function API:GetBagProspectableOres(minimum)
    local ores={2770,2771,2772,3858,10620,23424,23425};local valid,counts={},{}
    for _,id in ipairs(ores) do valid[id]=true end
    local slots=C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
    if type(slots)~="function" then return {} end
    for bag=0,(NUM_BAG_SLOTS or 4) do
        for slot=1,(slots(bag) or 0) do
            local id,qty
            if C_Container and C_Container.GetContainerItemInfo then
                local info=C_Container.GetContainerItemInfo(bag,slot);id=info and info.itemID;qty=info and info.stackCount
            elseif type(GetContainerItemInfo)=="function" then
                local _,count,_,_,_,_,link,_,_,itemID=GetContainerItemInfo(bag,slot)
                id=itemID or (link and tonumber(link:match("item:(%d+)")));qty=count
            end
            if valid[id] then counts[id]=(counts[id] or 0)+(tonumber(qty) or 0) end
        end
    end
    local rows={}
    for _,id in ipairs(ores) do if (counts[id] or 0)>=(minimum or 6) then rows[#rows+1]={itemString="i:"..id,quantity=counts[id]} end end
    return rows
end
function API:OpenTSMDestroying()
    if #self:GetBagProspectableOres()==0 then return false,"Carry more than five of one prospectable ore in your bags." end
    if InCombatLockdown and InCombatLockdown() then return false,"Leave combat before opening TSM Destroying." end
    if _G.UBKProspectingSessions then local ready,why=_G.UBKProspectingSessions:Preflight();if not ready then return false,why end end
    local handler=SlashCmdList and SlashCmdList.TSM
    if type(handler)~="function" then return false,"TSM's slash command is unavailable." end
    local ok,err=pcall(handler,"destroy")
    return ok,not ok and tostring(err) or nil
end

function API:GetIgnoredProspectingOres()
    local b=_G.UBKTSMGroupBridge
    if not b or not b.ready or type(b.GetIgnoredProspectingOres)~="function" then return nil,"UBK's TSM ignore-list integration is unavailable." end
    local ok,rows,err=pcall(b.GetIgnoredProspectingOres)
    if not ok then return nil,tostring(rows) end
    return rows,err
end
function API:RemoveIgnoredProspectingOres(items)
    if InCombatLockdown and InCombatLockdown() then return false,"Leave combat before changing TSM's ignore list." end
    local b=_G.UBKTSMGroupBridge
    if not b or not b.ready or type(b.RemoveIgnoredProspectingOres)~="function" then return false,"UBK's TSM ignore-list integration is unavailable." end
    local ok,result,err=pcall(b.RemoveIgnoredProspectingOres,items)
    if not ok then return false,tostring(result) end
    return result,err
end
