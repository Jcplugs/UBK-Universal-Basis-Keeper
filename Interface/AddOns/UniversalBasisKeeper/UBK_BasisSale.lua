-- Temporary group moves with a write-ahead return journal. The bridge saves
-- this journal in the SAME SavedVariables file as TSM's group membership.
_G.UBKBasisSale={}
local Sale=_G.UBKBasisSale
local function Bridge()
    local b=_G.UBKTSMGroupBridge
    if not b or not b.ready then return nil,(b and b.error) or "Sell Above Basis needs UBK's checked TSM integration. No items were moved." end
    return b
end
local function Stamp() return time and time() or 0 end
local function Positive(v) return type(v)=="number" and v>0 and v==v and v<math.huge end
local function Say(text) print("|cff33ff99UBK:|r "..text) end
local function Pending(session)
    for _,entry in ipairs(session and session.items or {}) do if entry.state~="returned" then return true end end
    return false
end
function Sale:GetSession()
    local b=Bridge(); if not b then return nil end
    return b.Journal().session
end
function Sale:HasPending() return Pending(self:GetSession()) end
function Sale:Cost(item)
    if _G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(item) then return nil,_G.UBKProspectingSessions:Reason(item) end
    local api=_G.UniversalBasisKeeperAPI
    if not api then return nil,"UBK is still loading" end
    if _G.UBKItemRules and _G.UBKItemRules.VendorTrash(item) then return nil,"Vendor trash" end
    local value=api:GetAcquisitionCost(item)
    if Positive(value) then return value,"Acquisition basis" end
    value=api:GetRecipeBasisCost(item)
    if Positive(value) then return value,"Recipe material basis" end
    return nil,"Resolve acquisition or material costs first"
end
function Sale:GetSaleBasis(item)
    if _G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(item) then return nil end
    local b=Bridge(); if not b then return nil end
    local session=b.Journal().session
    if not session or session.phase~="active" or session.profile~=b.Profile() then return nil end
    for _,entry in ipairs(session.items) do
        if entry.item==item and entry.state=="moved" then return Positive(entry.basis) and entry.basis or nil end
    end
    return nil
end
function Sale:BagRows()
    local b,err=Bridge(); if not b then return {},err end
    local ok,rows=pcall(b.BagItems); if not ok then return {},"TSM's bag data is not ready: "..tostring(rows) end
    for _,row in ipairs(rows) do
        row.basis,row.basisSource=self:Cost(row.itemString)
        if row.locked then row.reason="Item is locked" elseif not row.basis then row.reason=row.basisSource end
        row.selectable=not row.reason
        if row.basis then row.min=row.basis*1.10; row.normal=row.basis*1.75; row.max=row.basis*5 end
        row.groupDisplay=row.original or "Base Group (ungrouped)"
    end
    table.sort(rows,function(a,b) return tostring(a.name):lower()<tostring(b.name):lower() end)
    return rows
end
function Sale:ValidateSettings(input)
    input=input or {}
    local out={minPct=tonumber(input.minPct or 110),normalPct=tonumber(input.normalPct or 175),maxPct=tonumber(input.maxPct or 500),postCap=tonumber(input.postCap or 10)}
    for _,key in ipairs({"minPct","normalPct","maxPct","postCap"}) do
        if not Positive(out[key]) then return nil,"Enter positive numbers for all posting settings." end
    end
    if out.minPct>out.normalPct or out.normalPct>out.maxPct then return nil,"Posting percentages must satisfy minimum ≤ normal ≤ maximum." end
    if out.postCap~=math.floor(out.postCap) or out.postCap>50000 then return nil,"Posting quantity must be a whole number from 1 to 50000 single-item auctions." end
    for _,key in ipairs({"minPct","normalPct","maxPct"}) do
        if out[key]>100000 or math.abs(out[key]*100-math.floor(out[key]*100+.5))>.000001 then return nil,"Use posting percentages up to 100000, with at most two decimal places." end
    end
    return out
end
function Sale:Begin(selected,settings)
    local b,err=Bridge(); if not b then return false,err end
    if _G.UBKProspectingSessions and not b.pendingPostGuard then return false,"Update UBK’s TSM Integration before using Sell Above Basis with prospecting settlement." end
    if self:HasPending() then return false,"Return the current session's items before starting another." end
    if b.IsBusy() or (InCombatLockdown and InCombatLockdown()) then return false,"Finish the current AH scan or combat before moving groups." end
    local pricing,priceError=self:ValidateSettings(settings);if not pricing then return false,priceError end
    local rows,rowError=self:BagRows(); if rowError then return false,rowError end
    local lookup={}; for _,row in ipairs(rows) do lookup[row.itemString]=row end
    local items={}
    for item,checked in pairs(selected or {}) do
        if checked then
            local row=lookup[item]
            if not row or not row.selectable then return false,"A selected item is unavailable or has no trustworthy basis. Refresh the bag list." end
            items[#items+1]={item=item,name=row.name,original=row.original or false,basis=row.basis,basisSource=row.basisSource,quantity=row.qty,postQuantity=math.min(row.qty,pricing.postCap),state="prepared"}
        end
    end
    if #items==0 then return false,"Tick at least one bag item." end
    table.sort(items,function(a,b) return a.item<b.item end)
    local db=b.Journal(); local profile=b.Profile()
    local config=db.profiles[profile]
    local ok,result=pcall(function()
        if not config then config=b.CreateBucket(); db.profiles[profile]=config end
        local valid,why=b.ValidateBucket(config); assert(valid,why)
        -- Refuse to adopt arbitrary items already occupying a temporary bucket.
        local existing={}; TSM_API.GetGroupItems(config.group,true,existing)
        assert(next(existing)==nil,"The temporary group already contains items without a return journal. Move those items out in TSM first.")
        for _,entry in ipairs(items) do assert(b.Path(entry.item)==entry.original,"An item's group changed during selection. Refresh the bag list.") end
        if b.ConfigureBucket then local configured,why=b.ConfigureBucket(config,pricing);assert(configured,why)
        elseif pricing.minPct~=110 or pricing.normalPct~=175 or pricing.maxPct~=500 or pricing.postCap~=10 then error("Update UBK's TSM integration before using custom posting settings.") end
        local session={pricing=pricing,schema=1,profile=profile,group=config.group,operation=config.operation,createdAt=Stamp(),phase="moving",items=items,character=UnitName and UnitName("player") or ""}
        db.session=session -- record EVERY original group before the first move
        for _,entry in ipairs(items) do
            assert(b.Path(entry.item)==entry.original,"An item's group changed during the move.")
            b.Move(entry.item,session.group)
            assert(b.Path(entry.item)==session.group,"TSM did not confirm a requested group move.")
            entry.state="moved"
        end
        session.phase="active"; b.Invalidate()
        return session
    end)
    if not ok then
        local session=db.session
        if Pending(session) then self:Restore("move failed") end
        return false,"The move stopped: "..tostring(result)
    end
    self.lastPromptSerial=nil
    return true,result
end
-- Always verify current membership: return only items still in the temporary
-- group or ungrouped. A deliberate move to another real group is a conflict.
function Sale:Restore(reason)
    local b,err=Bridge(); if not b then return false,err end
    local db=b.Journal(); local session=db.session
    if not Pending(session) then return true,"No temporary group moves remain." end
    if b.IsBusy() or (InCombatLockdown and InCombatLockdown()) then return false,"Finish the AH scan or combat before returning items." end
    local prior=b.Profile()
    local ok,failure=pcall(function()
        if session.profile~=prior then
            local profiles=b.Profiles(); local exists=false
            for _,name in ipairs(profiles) do if name==session.profile then exists=true end end
            assert(exists,"The original TSM profile was removed. The return journal has been preserved.")
            b.SetProfile(session.profile)
            assert(b.Profile()==session.profile,"TSM did not activate the original profile.")
        end
        session.phase="restoring"
        for _,entry in ipairs(session.items) do
            if entry.state~="returned" then
                local current=b.Path(entry.item)
                if current==entry.original then entry.state="returned"; entry.error=nil
                elseif not b.Exists(entry.original) then entry.state="conflict"; entry.error="Original group was deleted: "..tostring(entry.original)
                elseif current~=session.group and current~=false then entry.state="conflict"; entry.error="Item was moved to another group: "..tostring(current)
                else
                    -- Journal remains pending if a setter throws before/after its write.
                    b.Move(entry.item,entry.original)
                    assert(b.Path(entry.item)==entry.original,"TSM could not verify the return group.")
                    entry.state="returned"; entry.error=nil
                end
            end
        end
        session.phase=Pending(session) and "conflict" or "returned"; session.returnedAt=Stamp(); session.returnReason=reason
        b.Invalidate()
    end)
    local resetOK,resetError=pcall(b.SetProfile,prior)
    if not ok or not resetOK then
        session.error=tostring(not ok and failure or resetError)
        return false,"Return is incomplete; its journal is preserved. "..session.error
    end
    if Pending(session) then return false,"Some original groups changed. Review the preserved return journal in Sell Above Basis." end
    db.lastSession=session; db.session=nil
    return true,"Items returned to their original groups. Existing group operations were preserved."
end
function Sale:GroupRenamed(old,new)
    local b=Bridge(); if not b then return end
    local db=b.Journal(); local profile=b.Profile(); local config=db.profiles[profile]
    if config then config.group=b.Repath(config.group,old,new) end
    local session=db.session
    if session and session.profile==profile then
        session.group=b.Repath(session.group,old,new)
        for _,entry in ipairs(session.items) do entry.original=b.Repath(entry.original,old,new) end
    end
end
function Sale:PostScanStarted(serial)
    local session=self:GetSession()
    if session and session.phase=="active" then session.postSerial=serial; session.scanSeen=true end
end
function Sale:CheckCompletion()
    local b=Bridge(); local session=b and b.Journal().session
    if not session or session.phase~="active" or not session.scanSeen or self.lastPromptSerial==session.postSerial then return end
    local status=b.postStatus or {}
    -- Waiting for the price scan alone is insufficient: leave TSM's Post/Skip
    -- decisions intact until every queued auction is confirmed or skipped.
    if not b.IsBusy() and ((status.total or 0)==0 or ((status.confirmed or 0)+(status.failed or 0))>=(status.total or 0)) then
        self.lastPromptSerial=session.postSerial
        if self.ShowReturnPrompt then self:ShowReturnPrompt() end
    end
end
local events=CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN"); events:RegisterEvent("PLAYER_LOGOUT"); events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:SetScript("OnEvent",function(_,event)
    if event=="PLAYER_LOGIN" then
        C_Timer.After(1,function()
            local raw=_G.UBKBasisSaleJournal
            if raw and Pending(raw.session) then
                local ok,message=Sale:Restore("login / reload recovery"); Say(message); if not ok and Sale.Show then Sale:Show() end
            end
        end)
    elseif event=="PLAYER_LOGOUT" then
        if Sale:HasPending() then Sale:Restore("logout recovery") end
    elseif Sale:HasPending() and Sale.ShowReturnPrompt then C_Timer.After(.2,function() Sale:ShowReturnPrompt() end) end
end)
local elapsed=0
events:SetScript("OnUpdate",function(_,delta)
    elapsed=elapsed+delta; if elapsed<.4 then return end; elapsed=0
    local b=Bridge(); local session=b and b.Journal().session
    if session and session.phase=="active" and session.profile~=b.Profile() then
        local ok,message=Sale:Restore("profile change"); Say(message); if not ok then session.phase="conflict" end
    else Sale:CheckCompletion() end
end)
