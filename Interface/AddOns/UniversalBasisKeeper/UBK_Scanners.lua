-- UBK Scanners v1.6.1a
-- Candidate discovery lives here. UBK owns accounting facts; UBK owns action
-- presentation. This module never buys, bids, posts, cancels, or mutates TSM.

local ADDON = ...
local VERSION = "1.6.1a"
local frame = CreateFrame("Frame")
local cache = {rows=nil, realmTime=nil, regionTime=nil, scope=nil, builtAt=0}

local function Now()
    return type(time)=="function" and time() or 0
end

local function Copy(value)
    if type(value)~="table" then return value end
    local out={}
    for key,item in pairs(value) do out[Copy(key)]=Copy(item) end
    return out
end

local function Core()
    local api=_G.UniversalBasisKeeperAPI
    if type(api)=="table" then return api end
    return nil
end

local function ScopeKey()
    local api=Core()
    if api and type(api.GetRuntimeContext)=="function" then
        local ok,ctx=pcall(api.GetRuntimeContext,api)
        if ok and type(ctx)=="table" and type(ctx.realmKey)=="string" and ctx.realmKey~="" then
            return ctx.realmKey,ctx.realm,ctx.faction
        end
    end
    local realm=(GetRealmName and GetRealmName()) or "Unknown"
    local faction=(UnitFactionGroup and UnitFactionGroup("player")) or "Neutral"
    return realm.."-"..faction,realm,faction
end

local function EnsureScope()
    if type(UBKScannersDB)~="table" then UBKScannersDB={} end
    local root=UBKScannersDB
    root.schema=1
    root.scopes=type(root.scopes)=="table" and root.scopes or {}
    local key,realm,faction=ScopeKey()
    local scope=root.scopes[key]
    if type(scope)~="table" then scope={}; root.scopes[key]=scope end
    scope.schema=1
    scope.realm=realm
    scope.faction=faction
    scope.chum=type(scope.chum)=="table" and scope.chum or {}
    scope.chum.blocked=type(scope.chum.blocked)=="table" and scope.chum.blocked or {}
    scope.migration=type(scope.migration)=="table" and scope.migration or {}
    return scope,key
end

local function Invalidate()
    cache.rows=nil
    cache.realmTime=nil
    cache.regionTime=nil
    cache.scope=nil
    cache.builtAt=0
end

local function MigrateLegacyChumState()
    local scope,key=EnsureScope()
    if scope.migration.legacyChumBlockedAt then return false end
    local oldRoot=_G.UBKInterfaceDB
    local oldScope=type(oldRoot)=="table" and type(oldRoot.scopes)=="table" and oldRoot.scopes[key] or nil
    if type(oldScope)~="table" then return false,"legacy UBK state is not loaded" end
    local blocked=type(oldScope)=="table" and type(oldScope.chumScanner)=="table" and oldScope.chumScanner.blocked or nil
    local copied=0
    if type(blocked)=="table" then
        for itemString,row in pairs(blocked) do
            if scope.chum.blocked[itemString]==nil then
                scope.chum.blocked[itemString]=Copy(row)
                copied=copied+1
            end
        end
    end
    scope.migration.legacyChumBlockedAt=Now()
    scope.migration.legacyChumBlockedCount=copied
    Invalidate()
    return copied>0,copied
end

local function MarketTimes(api)
    if not api or type(api.GetMarketDataTimes)~="function" then return nil,nil end
    local ok,realmTime,regionTime=pcall(api.GetMarketDataTimes,api)
    if not ok then return nil,nil end
    return tonumber(realmTime),tonumber(regionTime)
end

local function LiveEvidence(api,itemString,radarByItem)
    local live=nil
    if type(api.GetShredderLiveStock)=="function" then
        local ok,result=pcall(api.GetShredderLiveStock,api,itemString)
        if ok and type(result)=="table" then
            live=Copy(result)
            live.evidenceSource="exact stock"
        end
    end
    local radar=radarByItem and radarByItem[itemString] or nil
    if radar and (not live or (tonumber(radar.seenAt) or 0)>(tonumber(live.updatedAt) or 0)) then
        live=Copy(radar)
        live.evidenceSource="Radar book"
    end
    return live
end

local function Assess(row)
    local basis=tonumber(row.basis)
    if not row.trustedBasis or not basis or basis<=0 or (tonumber(row.unresolved) or 0)>0 then
        return "BASIS BLOCKED","UBK does not have complete trusted acquisition basis for this item, so Scanners refuses to call its low price bait."
    end

    local live=row.live
    if live and row.liveFresh then
        local low=tonumber(live.low)
        local ratio=low and low>0 and low/basis or nil
        local frontQty=tonumber(live.tailQty) or tonumber(live.lowUnits)
        local frontPosts=tonumber(live.tailPosts) or tonumber(live.lowPosts)
        local shelfLow=tonumber(live.shelfLow) or tonumber(live.nextLevelPrice)
        local recovery=tonumber(live.recovery)
        if not recovery and low and low>0 and shelfLow and shelfLow>low then recovery=(shelfLow/low)-1 end
        local tinyFront=frontQty and frontPosts and frontQty<=5 and frontPosts<=3
        local denseShelf=(tonumber(live.shelfQty) or 0)>=math.max(8,(frontQty or 1)*1.15) and (tonumber(live.shelfPosts) or 0)>=4
        local separated=shelfLow and recovery and recovery>=.08
        if ratio and ratio<=.95 and tinyFront and separated and (denseShelf or live.shelfStatus=="LOOK") then
            return "LIKELY CHUM","A tiny live front tail sits below trusted basis and at least 8% beneath a deeper shelf. That is bait-shaped structure, not an instruction to buy."
        elseif ratio and ratio<=.90 and tinyFront and separated then
            return "BAIT-SHAPED","The exact book has a tiny separated low below basis, but the shelf behind it is not deep enough to call likely chum."
        elseif ratio and ratio<=.90 and ((frontQty or 0)>=8 or (frontPosts or 0)>=4) and (not recovery or recovery<.06) then
            return "REAL BREAK?","Several units share the low and there is no clean recovery shelf. Treat this as possible repricing."
        elseif ratio and ratio<=.85 then
            return "DEEP LIVE","The exact low is deeply below basis, but the book shape does not isolate a tiny bait tail."
        end
        return "NO LIVE BAIT","The recent exact book does not show a small separated low below trusted basis."
    end

    local low=tonumber(row.loadedLow)
    if not low or low<=0 then return "NO LOADED LOW","The completed TSM data has no usable realm low for this item." end
    local ratio=low/basis
    local reference=tonumber(row.loadedReference)
    local gap=reference and reference>low and (reference/low)-1 or 0
    if ratio<=.85 and gap>=.10 then
        return "CHUM LEAD","The loaded low is at least 15% below trusted basis and at least 10% below the broader realm reference. Loaded data cannot prove depth."
    elseif ratio<=.85 then
        return "DEEP LEAD","The loaded low is at least 15% below trusted basis. Treat it as a lead until book depth distinguishes bait from a genuine break."
    elseif ratio<=.98 and gap>=.15 then
        return "PRICE-GAP LEAD","The loaded low is below trusted basis and sharply detached from the broader realm reference. Depth confirmation is missing."
    elseif ratio<1 then
        return "UNDER BASIS","The completed scan is below trusted basis, but the discount or reference gap is not large enough to look bait-shaped."
    end
    return "NO BAIT","The completed scan is not below trusted basis."
end

local function IsLeadStatus(status)
    return status=="LIKELY CHUM" or status=="BAIT-SHAPED" or status=="CHUM LEAD" or status=="PRICE-GAP LEAD"
        or status=="DEEP LIVE" or status=="DEEP LEAD" or status=="REAL BREAK?" or status=="UNDER BASIS"
end

local function StatusColor(status)
    if status=="LIKELY CHUM" then return "|cff33ff99" end
    if status=="BAIT-SHAPED" or status=="CHUM LEAD" or status=="PRICE-GAP LEAD" then return "|cffffd36a" end
    if status=="REAL BREAK?" or status=="BASIS BLOCKED" then return "|cffff7777" end
    if status=="DEEP LIVE" or status=="DEEP LEAD" or status=="UNDER BASIS" then return "|cff66ccff" end
    return "|cffaaaaaa"
end

local function BuildRows(force)
    local api=Core()
    if not api or type(api.GetChumScannerInputs)~="function" then return {} end
    local realmTime,regionTime=MarketTimes(api)
    local _,scopeKey=EnsureScope()
    if not force and cache.rows and cache.realmTime==realmTime and cache.regionTime==regionTime and cache.scope==scopeKey then
        return cache.rows
    end

    local ok,inputs=pcall(api.GetChumScannerInputs,api)
    inputs=ok and type(inputs)=="table" and inputs or {}
    local radarByItem={}
    if type(api.GetRadarState)=="function" then
        local radarOK,radar=pcall(api.GetRadarState,api)
        if radarOK and type(radar)=="table" then
            for _,result in ipairs(radar.results or {}) do
                if result.itemString then radarByItem[result.itemString]=result end
            end
        end
    end

    local scope=EnsureScope()
    local blocked=scope.chum.blocked
    local invested=0
    for _,input in ipairs(inputs) do
        local owned=math.max(0,tonumber(input.observedQty) or 0)
        local basis=tonumber(input.basis)
        if basis and basis>0 then invested=invested+owned*basis end
    end

    local rows={}
    for _,input in ipairs(inputs) do
        local basis=tonumber(input.basis)
        if basis and basis>0 then
            local market=type(input.market)=="table" and input.market or {}
            local row={
                itemString=input.itemString,
                name=input.name or tostring(input.itemString),
                basis=basis,
                trustedBasis=input.trustedForRadar==true,
                unresolved=tonumber(input.unresolvedQty) or 0,
                owned=math.max(0,tonumber(input.observedQty) or 0),
                known=math.max(0,tonumber(input.knownQty) or 0),
                sourceLabel=input.sourceLabel or "UBK",
                market=Copy(market),
                loadedLow=tonumber(market.minbuyout) or tonumber(market.recent) or tonumber(market.dbmarket),
                loadedReference=tonumber(market.recent) or tonumber(market.dbmarket) or tonumber(market.historical),
                blocked=blocked[input.itemString] and true or false,
            }
            row.share=invested>0 and row.owned*row.basis/invested or 0
            row.live=LiveEvidence(api,row.itemString,radarByItem)
            local liveAt=row.live and (tonumber(row.live.updatedAt) or tonumber(row.live.seenAt)) or nil
            row.liveFresh=liveAt and liveAt>0 and math.max(0,Now()-liveAt)<=1800 or false
            row.status,row.reason=Assess(row)
            row.risk=row.blocked and "BLOCKED" or (row.share>=.25 and "NO ADD" or (row.share>=.15 and "HEAVY" or (row.owned<=0 and "ZERO STOCK" or "ROOM")))
            rows[#rows+1]=row
        end
    end

    local rank={
        ["LIKELY CHUM"]=1,["BAIT-SHAPED"]=2,["CHUM LEAD"]=3,["PRICE-GAP LEAD"]=4,["DEEP LIVE"]=5,["DEEP LEAD"]=6,
        ["REAL BREAK?"]=7,["UNDER BASIS"]=8,["NO LIVE BAIT"]=9,["NO BAIT"]=10,["NO LOADED LOW"]=11,["BASIS BLOCKED"]=12,
    }
    table.sort(rows,function(a,b)
        local ar,br=rank[a.status] or 20,rank[b.status] or 20
        if ar~=br then return ar<br end
        local aa=a.loadedLow and a.basis>0 and a.loadedLow/a.basis or 99
        local bb=b.loadedLow and b.basis>0 and b.loadedLow/b.basis or 99
        if aa~=bb then return aa<bb end
        return tostring(a.name)<tostring(b.name)
    end)
    cache.rows=rows
    cache.realmTime=realmTime
    cache.regionTime=regionTime
    cache.scope=scopeKey
    cache.builtAt=Now()
    return rows
end

_G.UBKScannersAPI={version=VERSION}

function _G.UBKScannersAPI:GetRows(force)
    return Copy(BuildRows(force==true))
end

function _G.UBKScannersAPI:GetRow(itemString,force)
    for _,row in ipairs(BuildRows(force==true)) do
        if row.itemString==itemString then return Copy(row) end
    end
    return nil
end

function _G.UBKScannersAPI:Invalidate()
    Invalidate()
end

function _G.UBKScannersAPI:IsLeadStatus(status)
    return IsLeadStatus(status)
end

function _G.UBKScannersAPI:GetStatusColor(status)
    return StatusColor(status)
end

function _G.UBKScannersAPI:SetBlocked(itemString,blocked)
    if type(itemString)~="string" then return false,"invalid item" end
    local scope=EnsureScope()
    if blocked then scope.chum.blocked[itemString]={blockedAt=Now()} else scope.chum.blocked[itemString]=nil end
    Invalidate()
    return true
end

local function Summarize(rows)
    local result={total=#rows,leads=0,blocked=0,basisBlocked=0,builtAt=cache.builtAt,statuses={}}
    for _,row in ipairs(rows) do
        result.statuses[row.status]=(result.statuses[row.status] or 0)+1
        if IsLeadStatus(row.status) then result.leads=result.leads+1 end
        if row.blocked then result.blocked=result.blocked+1 end
        if row.status=="BASIS BLOCKED" then result.basisBlocked=result.basisBlocked+1 end
    end
    return result
end

function _G.UBKScannersAPI:GetSummary(force)
    return Summarize(BuildRows(force==true))
end

function _G.UBKScannersAPI:GetCachedSummary()
    if not cache.rows then return {built=false,total=0,leads=0,blocked=0,basisBlocked=0,builtAt=0,statuses={}} end
    local result=Summarize(cache.rows)
    result.built=true
    return result
end

function _G.UBKScannersAPI:GetSettings()
    local api=Core()
    return api and type(api.GetRadarSettings)=="function" and api:GetRadarSettings() or {}
end

function _G.UBKScannersAPI:SetSetting(key,value)
    local api=Core()
    if not api or type(api.SetRadarSetting)~="function" then return false,"UBK core is unavailable" end
    local ok,why=api:SetRadarSetting(key,value)
    if ok then Invalidate() end
    return ok,why
end

function _G.UBKScannersAPI:StartRadar(category)
    local api=Core()
    if not api or type(api.StartRadar)~="function" then return false,"UBK Radar is unavailable" end
    return api:StartRadar(category)
end

function _G.UBKScannersAPI:StopRadar()
    local api=Core()
    if api and type(api.StopRadar)=="function" then return api:StopRadar() end
end

function _G.UBKScannersAPI:GetRadarState()
    local api=Core()
    return api and type(api.GetRadarState)=="function" and api:GetRadarState() or {active=false,results={}}
end

SLASH_UBKSCANNERS1="/ubkscan"
SlashCmdList.UBKSCANNERS=function(msg)
    msg=(msg or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    if msg=="refresh" then
        local summary=_G.UBKScannersAPI:GetSummary(true)
        print(string.format("|cff33ff99UBK Scanners:|r %d basis markets, %d lead%s, %d blocked.",summary.total,summary.leads,summary.leads==1 and "" or "s",summary.blocked))
    elseif type(_G.UBKUI_Show)=="function" then
        _G.UBKUI_Show("settings")
    else
        print("|cffffcc00UBK Scanners:|r use /ubk scans after UBK finishes loading.")
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent",function(_,event,name)
    if event=="ADDON_LOADED" and name==ADDON then
        EnsureScope()
    elseif event=="PLAYER_LOGIN" then
        if C_Timer and C_Timer.After then C_Timer.After(2,MigrateLegacyChumState) else MigrateLegacyChumState() end
        print("|cff33ff99UBK Scanners "..VERSION..":|r loaded. Candidate discovery is read-only; /ubk scans opens tuning.")
    end
end)
