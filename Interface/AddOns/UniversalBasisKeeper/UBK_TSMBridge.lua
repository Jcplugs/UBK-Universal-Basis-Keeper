-- UBK-owned bridge, loaded by TSM's TOC only. It never runs from UBK's TOC.
-- The installer checks the local TSM version and records a reversible TOC edit.
local TSM=select(2,...)
if type(TSM)~="table" or not TSM.LibTSMTypes then return end
local B={version=1,ready=false,postSerial=0,postStatus={}}
_G.UBKTSMGroupBridge=B
local Group=TSM.LibTSMTypes:Include("Group")
local GroupOperation=TSM.LibTSMTypes:Include("GroupOperation")
local Operation=TSM.LibTSMTypes:Include("Operation")
local CustomString=TSM.LibTSMTypes:Include("CustomString")
local TempTable=TSM.LibTSMUtil:Include("BaseType.TempTable")
local wanted={postCap="10",stackSize="1",keepQuantity="0",minPrice="110% ubksellbasis",normalPrice="175% ubksellbasis",maxPrice="500% ubksellbasis",priceReset="none",aboveMax="maxPrice",undercut="1c",bidPercent=1}
local function Check() assert(B.ready,"TSM group integration is not ready.") end
local function Notify(name,...)
    local sale=_G.UBKBasisSale
    if sale and type(sale[name])=="function" then pcall(sale[name],sale,...) end
end
function B.ItemKey(link) Check(); return Group.TranslateItemString(TSM_API.ToItemString(link)) end
function B.Journal()
    if type(_G.UBKBasisSaleJournal)~="table" then _G.UBKBasisSaleJournal={schema=1,profiles={}} end
    local db=_G.UBKBasisSaleJournal
    assert(db.schema==1 and type(db.profiles)=="table","The session journal needs a compatible UBK version.")
    return db
end
function B.Profile() Check(); return TSM_API.GetActiveProfile() end
function B.Profiles() Check(); local out={}; TSM_API.GetProfiles(out); return out end
function B.SetProfile(profile) Check(); if TSM_API.GetActiveProfile()~=profile then TSM_API.SetActiveProfile(profile) end end
function B.Exists(path) Check(); return path==false or path=="" or Group.Exists(path) end
function B.Path(item)
    Check()
    if not Group.IsItemInGroup(item) then return false end
    local path=Group.GetPathByItem(item)
    return path~=Group.GetRootPath() and path or false
end
function B.Move(item,path) Check(); assert(B.Exists(path),"The destination group no longer exists."); Group.SetItemGroup(item,path~=false and path~="" and path or nil) end
function B.IsBusy() Check(); return TSM.UI.AuctionUI.IsScanning() and true or false end
-- Use TSM's own ignore-list service, never edit its saved table directly.
local prospectableOres={[2770]=true,[2771]=true,[2772]=true,[3858]=true,[10620]=true,[23424]=true,[23425]=true}
function B.GetIgnoredProspectingOres()
    Check()
    local service=TSM.Destroying
    if not service or type(service.CreateIgnoreQuery)~="function" then return nil,"TSM's Destroying ignore list is unavailable." end
    local query=service.CreateIgnoreQuery():Select("itemString","name","ignoreSession")
    local ok,rows=pcall(function()
        local out={}
        for _,item,name,session in query:Iterator() do
            local id=type(item)=="string" and tonumber(item:match("^i:(%d+)$"))
            if prospectableOres[id] then out[#out+1]={itemString=item,name=name or item,sessionIgnored=session==true} end
        end
        table.sort(out,function(a,b)return a.name<b.name end)
        return out
    end)
    query:Release()
    if not ok then return nil,tostring(rows) end
    return rows
end
function B.RemoveIgnoredProspectingOres(items)
    Check()
    if type(items)~="table" then return false,"No ignored ores selected." end
    local rows,err=B.GetIgnoredProspectingOres();if not rows then return false,err end
    local current={};for _,row in ipairs(rows) do current[row.itemString]=row end
    -- Validate the complete request before changing anything; never touch gear or herbs.
    for _,item in ipairs(items) do
        local id=type(item)=="string" and tonumber(item:match("^i:(%d+)$"))
        if not prospectableOres[id] then return false,"Only supported prospectable ores can be removed here." end
    end
    local removed,sessionCount,seen=0,0,{}
    for _,item in ipairs(items) do
        if current[item] and not seen[item] then
            seen[item]=true
            local ok,why=pcall(TSM.Destroying.ForgetIgnoreItemPermanent,item)
            if not ok then return false,"Removed "..removed.." ore ignores before TSM reported an error: "..tostring(why) end
            removed=removed+1
            if current[item].sessionIgnored then sessionCount=sessionCount+1 end
        end
    end
    return true,"Removed "..removed.." ore(s) from TSM's Destroying ignore list."..(sessionCount>0 and " Some were also skipped for this session; reload to clear those temporary skips." or "")
end

function B.IsAuctionScanBusy()
    Check()
    local ui=TSM.UI and TSM.UI.AuctionUI
    return ui and type(ui.IsScanning)=="function" and ui.IsScanning()==true or false
end

function B.GetBuyLedgerCSV()
    Check()
    local transactions=TSM.Accounting and TSM.Accounting.Transactions
    if not transactions or type(transactions.CreateQuery)~="function" then return nil end
    if not B.buyLedgerWatch then
        -- Observe the transaction table without executing a history query.
        -- The callback invalidates both row inserts and changes to combined buys.
        B.buyLedgerWatch=transactions.CreateQuery():ResetJoins():ResetVirtualFields()
            :SetUpdateCallback(function() B.buyLedgerCSV=nil end)
    end
    if B.buyLedgerCSV then return B.buyLedgerCSV end
    local CSV=TSM.LibTSMUtil:Include("Format.CSV")
    -- Accounting's general UI query joins every row to TSM's group database.
    -- This export only uses native transaction columns; those joins add no data.
    local query=transactions.CreateQuery():ResetJoins():ResetVirtualFields()
        :Equal("type","buy"):Equal("isCurrentRealm",true)
        :Select("itemString","stackSize","quantity","price","otherPlayer","player","time","source")
    local encoder
    local ok,result=pcall(function()
        encoder=CSV.EncodeStart({"itemString","stackSize","quantity","price","otherPlayer","player","time","source"})
        for _,item,stack,qty,price,seller,buyer,stamp,source in query:Iterator() do
            CSV.EncodeAddRowDataRaw(encoder,item,stack,qty,price,seller,buyer,stamp,source)
        end
        local csv=CSV.EncodeEnd(encoder)
        encoder=nil
        return csv
    end)
    query:Release(not ok)
    if not ok then
        if encoder then
            TempTable.Release(encoder.lineParts)
            TempTable.Release(encoder.lines)
            TempTable.Release(encoder)
        end
        error(result)
    end
    B.buyLedgerCSV=result
    return result
end
function B.BrowseItem(item)
    Check()
    local ui=TSM.UI and TSM.UI.AuctionUI
    local shopping=ui and ui.Shopping
    if not ui or not shopping or type(shopping.StartItemSearch)~="function" then return false,"TSM Browse integration is unavailable." end
    if ui.IsScanning() then return false,"Finish the active TSM scan first." end
    local L=TSM.Locale.GetTable()
    if not ui.IsVisible() or not ui.IsPageOpen(L["Browse"]) then return false,"Open the Auction House and select TSM Browse, then click again." end
    local link=TSM_API.GetItemLink(item)
    if not link then return false,"The item's link is still loading. Try again after hovering it." end
    shopping.StartItemSearch(link)
    return true
end
function B.Invalidate() CustomString.InvalidateCache("UBKSellBasis") end
function B.BagItems()
    Check()
    local result,lookup={},{}
    local count=C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
    for bag=0,(NUM_BAG_SLOTS or 4) do
        for slot=1,count(bag) do
            local info
            if C_Container and C_Container.GetContainerItemInfo then info=C_Container.GetContainerItemInfo(bag,slot)
            else
                local icon,qty,locked,quality,_,_,link,_,_,id,isBound=GetContainerItemInfo(bag,slot)
                if link then info={iconFileID=icon,stackCount=qty,isLocked=locked,quality=quality,hyperlink=link,itemID=id,isBound=isBound} end
            end
            if info and info.hyperlink and not info.isBound then
                local key=B.ItemKey(info.hyperlink)
                if key then
                    local row=lookup[key]
                    if not row then
                        row={itemString=key,name=TSM_API.GetItemName(key) or key,qty=0,original=B.Path(key),quality=info.quality,locked=false}
                        result[#result+1]=row; lookup[key]=row
                    end
                    row.qty=row.qty+(info.stackCount or 0); row.locked=row.locked or info.isLocked
                end
            end
        end
    end
    return result
end
local function ValidateOperation(name,expected)
    if not Operation.Exists("Auctioning",name) then return false,"The session's Auctioning operation was removed." end
    Operation.UpdateFromRelationships("Auctioning",name)
    local settings=Operation.GetSettings("Auctioning",name)
    for key,value in pairs(wanted) do
        if expected and (key=="minPrice" or key=="normalPrice" or key=="maxPrice" or key=="postCap") then value=expected[key] end
        if settings[key]~=value then return false,"The session operation was edited ("..key.."). Restore the requested settings before starting a new session." end
        if settings.relationships and settings.relationships[key] then return false,"The session operation has linked settings. Remove those links before using it." end
    end
    if settings.stackSizeIsCap~=false or settings.matchStackSize~=false then return false,"Sell Above Basis requires exact single-item stacks." end
    return true
end
function B.ValidateBucket(config)
    Check()
    if type(config)~="table" or not Group.Exists(config.group) then return false,"The temporary group was removed." end
    local ok,err=ValidateOperation(config.operation,config.settings); if not ok then return false,err end
    local count=0
    for _,name in GroupOperation.Iterator(config.group,"Auctioning") do
        count=count+1; if name~=config.operation then return false,"The temporary group has a different Auctioning operation." end
    end
    if count~=1 or not GroupOperation.HasOverride(config.group,"Auctioning") then return false,"The temporary group must use only its own Auctioning operation." end
    for _,kind in Operation.TypeIterator() do
        if kind~="Auctioning" then
            for _ in GroupOperation.Iterator(config.group,kind) do return false,"The temporary group has an extra "..kind.." operation. Clear it before using this session." end
            if not GroupOperation.HasOverride(config.group,kind) then return false,"The temporary group is inheriting "..kind.." operations." end
        end
    end
    return true
end
function B.ConfigureBucket(config,options)
    local valid,err=B.ValidateBucket(config);if not valid then return false,err end
    local sale=_G.UBKBasisSale
    local p,why
    if sale then p,why=sale:ValidateSettings(options) end
    if not p then return false,why or "UBK posting settings are unavailable." end
    local nextSettings={}
    for key,value in pairs(wanted) do nextSettings[key]=value end
    nextSettings.minPrice=tostring(p.minPct).."% ubksellbasis"
    nextSettings.normalPrice=tostring(p.normalPct).."% ubksellbasis"
    nextSettings.maxPrice=tostring(p.maxPct).."% ubksellbasis"
    nextSettings.postCap=tostring(p.postCap)
    local settings=Operation.GetSettings("Auctioning",config.operation)
    for key,value in pairs(nextSettings) do settings[key]=value end
    settings.stackSize="1";settings.stackSizeIsCap=false;settings.matchStackSize=false
    config.settings=nextSettings
    return B.ValidateBucket(config)
end
function B.CreateBucket()
    Check()
    local base,opbase="zz - sell above basis","UBK - Sell Above Basis"
    local group,op=base,opbase
    local index=2
    while Group.Exists(group) do group=base.." ("..index..")"; index=index+1 end
    index=2
    while Operation.Exists("Auctioning",op) do op=opbase.." ("..index..")"; index=index+1 end
    Operation.Create("Auctioning",op)
    local settings=Operation.GetSettings("Auctioning",op)
    for key,value in pairs(wanted) do settings[key]=value end
    settings.duration=2; settings.stackSizeIsCap=false; settings.matchStackSize=false
    -- Only this newly-created group is changed. Existing groups and operations
    -- are never reset, copied over, removed, or assigned another operation.
    GroupOperation.CreateGroup(group)
    for _,kind in Operation.TypeIterator() do
        GroupOperation.SetOverride(group,kind,true)
        local names={}; for _,name in GroupOperation.Iterator(group,kind) do names[#names+1]=name end
        for i=#names,1,-1 do GroupOperation.Remove(group,kind,i) end
    end
    GroupOperation.Add(group,"Auctioning",op)
    local config={group=group,operation=op}
    local ok,err=B.ValidateBucket(config); assert(ok,err)
    return config
end
function B.Repath(path,old,new)
    if path==old then return new end
    if type(path)=="string" and Group.IsChild(path,old) then return Group.JoinPath(new,Group.GetRelativePath(path,old)) end
    return path
end
local function RegisterPrices()
    if B.sourcesRegistered then return end
    local metadata=C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local _,_,_,interface=GetBuildInfo();interface=tonumber(interface)
    if not interface or interface<20500 or interface>=30000 then B.error="This UBK integration supports TBC Anniversary only."; return end
    if not metadata or metadata("TradeSkillMaster","Version")~="v4.14.76" then B.error="This TSM version needs a checked UBK integration update."; return end
    local sources={
        {"UBKBasis","Trusted UBK acquisition basis","GetAcquisitionCost"},
        {"UBKMatCost","UBK materials: acquisition, recorded purchases, vendor","GetMaterialCost"},
        {"UBKCrafting","Crafting cost from UBK material basis","GetRecipeBasisCost"},
    }
    for _,spec in ipairs(sources) do
        local method=spec[3]
        if not CustomString.IsSourceRegistered(spec[1]:lower()) and not CustomString.IsCustomSourceRegistered(spec[1]:lower()) then
            CustomString.RegisterSource("UBK",spec[1],spec[2],function(item)
                local api=_G.UniversalBasisKeeperAPI
                return api and api[method] and api[method](api,item) or nil
            end,CustomString.SOURCE_TYPE.VOLATILE)
        end
    end
    if CustomString.IsSourceRegistered("ubksellbasis") or CustomString.IsCustomSourceRegistered("ubksellbasis") then B.error="The UBKSellBasis source name is already in use."; return end
    CustomString.RegisterSource("UBK","UBKSellBasis","Basis captured for the active Sell Above Basis session",function(item)
        local sale=_G.UBKBasisSale
        return sale and sale.GetSaleBasis and sale:GetSaleBasis(item) or nil
    end,CustomString.SOURCE_TYPE.VOLATILE)
    B.sourcesRegistered=true
end
-- A prepared TSM post queue already contains computed prices. Re-reading a
-- volatile source alone cannot protect that queue after more gems are made.
function B.InstallPendingPostGuard()
    local post=TSM.Auctioning and TSM.Auctioning.PostScan
    if not post or type(post.DoProcess)~="function" then return false end
    if B.pendingPostGuard then return true end
    local original=post.DoProcess
    post.DoProcess=function(...)
        local p=_G.UBKProspectingSessions
        local session=B.Journal().session
        if p and session and session.profile==B.Profile() then
            for _,entry in ipairs(session.items or {}) do
                if entry.state~="returned" and p:Pending(entry.item) then
                    print("|cffffcc00UBK:|r Posting blocked: this Sell Above Basis session contains pending prospecting gems. Return Items, or reload and settle before running a fresh Post Scan.")
                    -- No PostAuction call, no queue skip, no forced confirmation.
                    return false,true
                end
            end
        end
        return original(...)
    end
    B.pendingPostGuard=true
    return true
end

local function InitializeGroups()
    if not B.sourcesRegistered or B.ready then return end
    B.InstallPendingPostGuard()
    hooksecurefunc(GroupOperation,"MoveGroup",function(old,new) Notify("GroupRenamed",old,new) end)
    hooksecurefunc(TSM.Auctioning.PostScan,"Prepare",function()
        B.postSerial=B.postSerial+1; B.postStatus={processed=0,confirmed=0,failed=0,total=0}; B.postScanStarted=true
        Notify("PostScanStarted",B.postSerial)
    end)
    B.statusSubscription=TSM.Auctioning.PostScan.StatusQueryPublisher():CallFunction(function(data)
        local processed,confirmed,failed,total=TempTable.UnpackAndRelease(data)
        B.postStatus={processed=processed,confirmed=confirmed,failed=failed,total=total}
    end):Stored()
    B.ready=true
end
hooksecurefunc(TSM,"OnInitialize",function() local ok,err=pcall(RegisterPrices); if not ok then B.error=tostring(err) end end)
local startup=CreateFrame("Frame")
startup:RegisterEvent("PLAYER_LOGIN")
startup:SetScript("OnEvent",function() C_Timer.After(.1,function()
    local ok,err=pcall(InitializeGroups)
    if not ok then B.error="TSM group integration could not initialize: "..tostring(err); B.ready=false end
end) end)

-- Recovery also runs when UBK itself is disabled on the next character. The
-- loader and journal belong to TSM, so an inactive UI cannot strand a session.
function B.RecoverOnLogin()
    if not B.ready then return end
    local db=B.Journal(); local session=db.session
    if not session then return end
    local prior=B.Profile()
    local ok,err=pcall(function()
        if session.profile~=prior then
            local found=false; for _,name in ipairs(B.Profiles()) do if name==session.profile then found=true end end
            assert(found,"The original TSM profile was deleted.")
            B.SetProfile(session.profile)
        end
        local pending=false
        for _,entry in ipairs(session.items or {}) do
            if entry.state~="returned" then
                local current=B.Path(entry.item)
                if current==entry.original then entry.state="returned";entry.error=nil
                elseif not B.Exists(entry.original) then pending=true;entry.state="conflict";entry.error="Original group was deleted: "..tostring(entry.original)
                elseif current and current~=session.group then pending=true;entry.state="conflict";entry.error="Item was moved to another group: "..current
                else B.Move(entry.item,entry.original); assert(B.Path(entry.item)==entry.original,"Group return could not be verified.");entry.state="returned";entry.error=nil end
            end
        end
        session.phase=pending and "conflict" or "returned"
        if not pending then db.lastSession=session; db.session=nil end
        B.Invalidate()
    end)
    local resetOK,resetError=pcall(B.SetProfile,prior)
    if not ok or not resetOK then session.phase="conflict";session.error=tostring(not ok and err or resetError);db.session=session end
    if db.session then print("|cffffcc00UBK:|r A Sell Above Basis return needs review. Its original groups are preserved in the return journal. Open /ubksell with UBK enabled.")
    else print("|cff33ff99UBK:|r Recovered the previous Sell Above Basis session. Items are back in their original groups.") end
end
local recover=CreateFrame("Frame");recover:RegisterEvent("PLAYER_LOGIN")
recover:SetScript("OnEvent",function() C_Timer.After(.25,function() local ok,err=pcall(B.RecoverOnLogin); if not ok then print("|cffff7777UBK:|r Group-return recovery needs review: "..tostring(err)) end end) end)
