-- UBK interface v1.6
-- All interface functions are part of Universal Basis Keeper.
-- Does not own acquisition accounting and never auto-buys / bids / posts / cancels.

local ADDON = ...
local frame = CreateFrame("Frame")
local API
local UI = { rows = {}, page = "home", radarFilter = "ALL", selectedItem = nil, radarPage = 1, listPage = 1, shredMode = "opportunities", coverageFilter = "all", positionFilter = "QUICK", chumSelected = nil, chumFilter = "LEADS", homeStatus = nil, detailParent = nil, crossFilter = "ALL", crossDetailKey = nil, testArenaSession = nil, testArenaReturnView = nil }
local VERSION = "1.6"
local ROWS = 15

-- Universal UBK layout canvas. The entire workshop is always laid out at one
-- known logical size, then the root frame is scaled as a unit. This prevents
-- fixed-pixel child layouts from collapsing into each other when the user
-- makes the visible window smaller.
local DESIGN_WIDTH, DESIGN_HEIGHT = 1120, 700
local MIN_UI_SCALE, MAX_UI_SCALE = .75, 1.30
local function ClampUIScale(v)
    v=tonumber(v) or 1
    local maxScale=MAX_UI_SCALE
    if UIParent and UIParent.GetWidth and UIParent.GetHeight then
        local sw,sh=UIParent:GetWidth(),UIParent:GetHeight()
        if sw and sh and sw>0 and sh>0 then
            maxScale=math.min(maxScale,(sw*.96)/DESIGN_WIDTH,(sh*.96)/DESIGN_HEIGHT)
        end
    end
    maxScale=math.max(MIN_UI_SCALE,maxScale)
    return math.max(MIN_UI_SCALE,math.min(maxScale,v))
end

-- The workshop remains fully player-driven. The two starred
-- workspaces are flagships, not access tiers. No access gate exists.
local INVITE_STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:14:14:0:0|t"
local CROSS_PRESSURE_LABEL = INVITE_STAR.." Cross-Pressure"
local POSITION_INTELLIGENCE_LABEL = INVITE_STAR.." Position Intelligence"

-- A private companion may provide transient evidence through this narrow
-- runtime surface. The public core never serializes or copies provider data.
local function EvidenceProvider()
    local provider=_G.UBKInterfaceEvidenceProvider
    if type(provider)~="table" or type(provider.IsActive)~="function" then return nil end
    local ok,active=pcall(provider.IsActive,provider)
    return ok and active and provider or nil
end
local TRANSIENT_PROVIDER_STATE={conclusions={},alerts={}}

local function Now() return type(time)=="function" and time() or 0 end
local function Copy(v)
    if type(v)~="table" then return v end
    local o={} for k,x in pairs(v) do o[k]=Copy(x) end return o
end
local function Money(v)
    if API and API.FormatMoney then return API:FormatMoney(v) end
    v=tonumber(v) or 0; return string.format("%.2fg",v/10000)
end
local function Pct(v) return v and string.format("%.1f%%",v*100) or "—" end
local function Age(ts)
    ts=tonumber(ts); if not ts or ts<=0 then return "unknown" end
    local d=math.max(0,Now()-ts)
    if d<60 then return tostring(math.floor(d)).."s" end
    if d<3600 then return tostring(math.floor(d/60)).."m" end
    if d<86400 then return string.format("%.1fh",d/3600) end
    return string.format("%.1fd",d/86400)
end
local function JoinSignals(t)
    if type(t)~="table" or #t==0 then return "—" end
    return table.concat(t,"  ")
end
local function AddButtonTooltip(button,title,body,extra)
    if not button or not title or not body then return end
    button:SetScript("OnEnter",function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
            GameTooltip:AddLine(title,1,.82,0)
            GameTooltip:AddLine(body,1,1,1,true)
            if extra and extra~="" then GameTooltip:AddLine(extra,.55,.85,1,true) end
            GameTooltip:Show()
        end
    end)
    button:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
end
local function ScopeKey()
    local realm=(GetRealmName and GetRealmName()) or "Unknown"
    local faction=(UnitFactionGroup and UnitFactionGroup("player")) or "Neutral"
    if (realm=="" or realm=="Unknown") and API and type(API.GetRuntimeContext)=="function" then
        local ok,ctx=pcall(API.GetRuntimeContext,API)
        if ok and type(ctx)=="table" then
            realm=(ctx.realm and ctx.realm~="") and ctx.realm or realm
            faction=(ctx.faction and ctx.faction~="") and ctx.faction or faction
        end
    end
    return realm.."-"..faction,realm,faction
end
local function EnsureDB()
    if type(UBKInterfaceDB)~="table" then UBKInterfaceDB={} end
    local root=UBKInterfaceDB; root.schema=6
    root.scopes=type(root.scopes)=="table" and root.scopes or {}
    root.characters=type(root.characters)=="table" and root.characters or {}
    local key,realm,faction=ScopeKey()
    local db=root.scopes[key]
    if type(db)~="table" then db={}; root.scopes[key]=db end
    db.schema=6; db.realm=realm; db.faction=faction
    if type(db.watchlist)~="table" then db.watchlist={} end
    if type(db.crossPressure)~="table" then db.crossPressure={} end
    local cp=db.crossPressure
    cp.schema=2
    if type(cp.snapshots)~="table" then cp.snapshots={} end
    if type(cp.alertState)~="table" then cp.alertState={} end
    if type(db.marketEvidence)~="table" then db.marketEvidence={} end
    local evidence=db.marketEvidence
    evidence.schema=1
    if type(evidence.datasets)~="table" then evidence.datasets={} end
    if type(evidence.datasetOrder)~="table" then evidence.datasetOrder={} end
    if type(evidence.conclusions)~="table" then evidence.conclusions={} end
    if type(db.chumScanner)~="table" then db.chumScanner={} end
    db.chumScanner.schema=1
    if type(db.chumScanner.blocked)~="table" then db.chumScanner.blocked={} end
    if type(db.settings)~="table" then db.settings={} end
    if db.settings.loginSummary==nil then db.settings.loginSummary=true end
    if db.settings.openOnLogin==nil then db.settings.openOnLogin=false end
    if db.settings.alertSignalChanges==nil then db.settings.alertSignalChanges=true end
    if db.windowX==nil then db.windowX=0 end
    if db.windowY==nil then db.windowY=0 end
    -- v1.1.6 migration: old UBK resized its logical canvas directly. Preserve
    -- roughly the same on-screen footprint, but move that preference into a
    -- single root-frame scale so every page keeps the full design geometry.
    if db.uiScale==nil then
        local legacyW=tonumber(db.width) or 1060
        local legacyH=tonumber(db.height) or 650
        db.uiScale=ClampUIScale(math.min(legacyW/DESIGN_WIDTH,legacyH/DESIGN_HEIGHT))
    else
        db.uiScale=ClampUIScale(db.uiScale)
    end
    db.width=DESIGN_WIDTH
    db.height=DESIGN_HEIGHT
    local char=(UnitName("player") or "Unknown").." - "..realm
    root.characters[char]={realm=realm,faction=faction,lastSeen=Now()}
    return db
end

local function NeedAPI(silent)
    API=_G.UniversalBasisKeeperAPI
    if type(API)~="table" then
        if not silent then print("|cffff7777Universal Basis Keeper:|r Universal Basis Keeper universal build is required.") end
        return false
    end
    return true
end

local function ScannerModule()
    local scanners=_G.UBKScannersAPI
    return type(scanners)=="table" and scanners or nil
end

local function MarketDatasetIdentity()
    if not NeedAPI(true) or type(API.GetMarketDataTimes)~="function" then return nil,nil end
    local ok,realmTime,regionTime=pcall(API.GetMarketDataTimes,API)
    if not ok then return nil,nil end
    realmTime=tonumber(realmTime); regionTime=tonumber(regionTime)
    if realmTime and realmTime<=0 then realmTime=nil end
    if regionTime and regionTime<=0 then regionTime=nil end
    if not realmTime and not regionTime then return nil,nil end
    local stamp=math.max(realmTime or 0,regionTime or 0)
    return tostring(realmTime or 0)..":"..tostring(regionTime or 0),stamp,realmTime,regionTime
end

local function ObserveMarketDataset(reason)
    local fingerprint,stamp=MarketDatasetIdentity()
    if not fingerprint then return false,"no-data" end
    local db=EnsureDB(); local e=db.marketEvidence
    if not e.legacyMigrated then
        local seen={}
        for _,legacy in ipairs(db.crossPressure.snapshots or {}) do
            local legacyStamp=tonumber(legacy.dataTime)
            local legacyKey=legacy.datasetFingerprint or (legacyStamp and legacyStamp>0 and ("legacy:"..tostring(legacyStamp)) or nil)
            if legacyKey and legacyKey~=fingerprint and not seen[legacyKey] then
                seen[legacyKey]=true
                if #e.datasetOrder>=30 then
                    local oldest=table.remove(e.datasetOrder,1)
                    if oldest then e.datasets[oldest]=nil end
                end
                e.datasets[legacyKey]={stamp=legacyStamp,observedAt=tonumber(legacy.capturedAt) or 0,reason="retained-snapshot"}
                e.datasetOrder[#e.datasetOrder+1]=legacyKey
            end
        end
        e.observedCount=math.min(30,#e.datasetOrder)
        e.legacyMigrated=true
    end
    if e.datasets[fingerprint] then
        e.currentFingerprint=fingerprint; e.currentStamp=stamp
        return false,"same-data"
    end
    if #e.datasetOrder>=30 then
        local oldest=table.remove(e.datasetOrder,1)
        if oldest then e.datasets[oldest]=nil end
    end
    e.datasets[fingerprint]={stamp=stamp,observedAt=Now(),reason=reason or "observed"}
    e.datasetOrder[#e.datasetOrder+1]=fingerprint
    e.currentFingerprint=fingerprint; e.currentStamp=stamp
    e.observedCount=math.min(30,(tonumber(e.observedCount) or 0)+1)
    return true,fingerprint
end

local function MarketEvidenceCount()
    local e=EnsureDB().marketEvidence
    return math.min(30,tonumber(e.observedCount) or #e.datasetOrder)
end

local function PruneConclusionEvidence(e)
    local rows={}
    for key,row in pairs(e.conclusions or {}) do rows[#rows+1]={key=key,at=tonumber(row.lastSeenAt) or 0} end
    if #rows<=400 then return end
    table.sort(rows,function(a,b) return a.at>b.at end)
    for i=401,#rows do e.conclusions[rows[i].key]=nil end
end

local function ConclusionCertainty(kind,key,signature,obviousWin,supportsProgress,sourceFingerprint,sourceStamp)
    local fingerprint,stamp=sourceFingerprint,tonumber(sourceStamp)
    if not fingerprint then fingerprint,stamp=MarketDatasetIdentity() end
    local e=EnsureDB().marketEvidence
    local entity=tostring(kind).."|"..tostring(key)
    local provider=EvidenceProvider()
    local conclusions=provider and TRANSIENT_PROVIDER_STATE.conclusions or e.conclusions
    if supportsProgress==false or not fingerprint then
        conclusions[entity]=nil
        return "Forming",1,.55
    end
    local dataAge=stamp and math.max(0,Now()-stamp) or 0
    if obviousWin and dataAge<=21600 then return "Highly Actionable",3,.90 end
    if not sourceFingerprint then ObserveMarketDataset("engine") end
    local row=conclusions[entity]
    if type(row)~="table" then row={}; conclusions[entity]=row end
    -- Three-Seen means three genuinely distinct AppHelper datasets, not merely
    -- three changes away from the immediately previous fingerprint. Keep a
    -- bounded fingerprint ledger for the current conclusion signature so an
    -- older AppData replay (A -> B -> A) cannot manufacture the third sighting.
    if row.signature~=signature then
        row.signature=signature
        row.seen=1
        row.fingerprints={[fingerprint]=true}
        row.fingerprintOrder={fingerprint}
        row.lastFingerprint=fingerprint
        row.lastDatasetStamp=stamp
    else
        if type(row.fingerprints)~="table" then
            row.fingerprints={}
            row.fingerprintOrder={}
            if row.lastFingerprint then
                row.fingerprints[row.lastFingerprint]=true
                row.fingerprintOrder[1]=row.lastFingerprint
            end
        end
        if type(row.fingerprintOrder)~="table" then row.fingerprintOrder={} end
    end
    if row.lastFingerprint~=fingerprint and not row.fingerprints[fingerprint] then
        local gap=(tonumber(stamp) or 0)-(tonumber(row.lastDatasetStamp) or tonumber(stamp) or 0)
        if gap<=21600 then
            row.seen=math.min(3,(tonumber(row.seen) or 0)+1)
        else
            row.seen=1
        end
        row.fingerprints[fingerprint]=true
        row.fingerprintOrder[#row.fingerprintOrder+1]=fingerprint
        while #row.fingerprintOrder>30 do
            local oldest=table.remove(row.fingerprintOrder,1)
            if oldest then row.fingerprints[oldest]=nil end
        end
        row.lastFingerprint=fingerprint
        row.lastDatasetStamp=stamp
    end
    row.lastSeenAt=Now()
    if not provider then PruneConclusionEvidence(e) end
    local seen=math.max(1,math.min(3,tonumber(row.seen) or 1))
    if dataAge>86400 then seen=1
    elseif dataAge>21600 then seen=math.max(1,seen-1) end
    if seen>=3 then return "Highly Actionable",seen,.90 end
    if seen==2 then return "Strengthening",seen,.72 end
    return "Forming",seen,.55
end
local function Resolve(text)
    if not NeedAPI(true) then return nil end
    return API:ResolveItem(text)
end
local function ItemName(item) return API and API:GetItemName(item) or tostring(item or "") end


-- ============================================================================
-- Cross-Pressure — lead/lag market learning
-- ============================================================================
-- A Cross-Pressure relationship is directional: a cheaper DRIVER can widen the
-- margin on a shared craft, increasing demand for another reagent (TARGET). UBK
-- never assumes the relationship is causal from correlation alone; every row
-- carries the shared recipe explanation, the observed history, and the current
-- recipe-basket support check. UBK acquisition accounting is never modified.

local CPCaptureAndAlert

local CROSS_PRESSURE_RECIPES = {
    healing = {name="Elixir of Healing Power", output="i:22825", outputName="Elixir of Healing Power", reagents={{item="i:22786",name="Dreaming Glory",qty=1},{item="i:13464",name="Golden Sansam",qty=1}}},
    agility = {name="Elixir of Major Agility", output="i:22831", outputName="Elixir of Major Agility", reagents={{item="i:22789",name="Terocone",qty=1},{item="i:22785",name="Felweed",qty=2}}},
    adept = {name="Adept's Elixir", output="i:28103", outputName="Adept's Elixir", reagents={{item="i:13463",name="Dreamfoil",qty=1},{item="i:22785",name="Felweed",qty=1}}},
    primalmight = {name="Primal Might", output="i:23571", outputName="Primal Might", reagents={{item="i:22451",name="Primal Air",qty=1},{item="i:22452",name="Primal Earth",qty=1},{item="i:21885",name="Primal Water",qty=1},{item="i:21884",name="Primal Fire",qty=1},{item="i:22457",name="Primal Mana",qty=1}}},
    spellcloth = {name="Spellcloth", output="i:24271", outputName="Spellcloth", reagents={{item="i:21842",name="Bolt of Imbued Netherweave",qty=1},{item="i:22457",name="Primal Mana",qty=1},{item="i:21884",name="Primal Fire",qty=1}}},
    earthstorm = {name="Earthstorm Diamond", output="i:25867", outputName="Earthstorm Diamond", reagents={{item="i:23079",name="Deep Peridot",qty=3},{item="i:23107",name="Shadow Draenite",qty=3},{item="i:23112",name="Golden Draenite",qty=3},{item="i:22452",name="Primal Earth",qty=2},{item="i:21885",name="Primal Water",qty=2}}},
    skyfire = {name="Skyfire Diamond", output="i:25868", outputName="Skyfire Diamond", reagents={{item="i:23077",name="Blood Garnet",qty=3},{item="i:21929",name="Flame Spessarite",qty=3},{item="i:23117",name="Azure Moonstone",qty=3},{item="i:21884",name="Primal Fire",qty=2},{item="i:22451",name="Primal Air",qty=2}}},
}

local CROSS_PRESSURE_RELATIONS = {
    {key="dreaming_sansam",driver="i:22786",driverName="Dreaming Glory",target="i:13464",targetName="Golden Sansam",recipe="healing"},
    {key="golden_earth",driver="i:23112",driverName="Golden Draenite",target="i:22452",targetName="Primal Earth",recipe="earthstorm"},
    {key="air_earth",driver="i:22451",driverName="Primal Air",target="i:22452",targetName="Primal Earth",recipe="primalmight"},
    {key="air_fire",driver="i:22451",driverName="Primal Air",target="i:21884",targetName="Primal Fire",recipe="skyfire"},
    {key="imbued_fire",driver="i:21842",driverName="Bolt of Imbued Netherweave",target="i:21884",targetName="Primal Fire",recipe="spellcloth"},
    {key="terocone_felweed",driver="i:22789",driverName="Terocone",target="i:22785",targetName="Felweed",recipe="agility"},
    {key="dreamfoil_felweed",driver="i:13463",driverName="Dreamfoil",target="i:22785",targetName="Felweed",recipe="adept"},
}

local function CPMedian(values)
    local x={} for _,v in ipairs(values or {}) do if tonumber(v) then x[#x+1]=tonumber(v) end end
    if #x==0 then return nil end
    table.sort(x)
    local n=#x
    if n%2==1 then return x[(n+1)/2] end
    return (x[n/2]+x[n/2+1])/2
end

local function CPMarketPoint(itemString)
    if not NeedAPI(true) or not API.GetMarketContext then return nil end
    local m=API:GetMarketContext(itemString)
    if type(m)~="table" then return nil end
    local p=tonumber(m.recent) or tonumber(m.minbuyout) or tonumber(m.dbmarket) or tonumber(m.realmReference)
    if not p or p<=0 then return nil end
    return {price=p,recent=m.recent,minbuyout=m.minbuyout,dbmarket=m.dbmarket,realmReference=m.realmReference,regionReference=m.regionReference,saleRate=m.saleRate,soldPerDay=m.soldPerDay,liquidity=m.liquidity,vendorSell=m.vendorSell}
end

local function CPRecipePoint(recipe)
    if type(recipe)~="table" then return nil end
    local output=CPMarketPoint(recipe.output)
    local basket=0
    local complete=true
    for _,r in ipairs(recipe.reagents or {}) do
        local p=CPMarketPoint(r.item)
        if p and p.price then basket=basket+p.price*(tonumber(r.qty) or 1) else complete=false end
    end
    local outputValue=output and output.price or nil
    return {basketCost=complete and basket or nil,outputPrice=outputValue,margin=(complete and outputValue) and (outputValue-basket) or nil,ratio=(complete and basket>0 and outputValue) and (outputValue/basket) or nil}
end

local function CPCaptureSnapshot(reason)
    if not NeedAPI(true) then return false,"UBK API unavailable" end
    local db=EnsureDB(); local cp=db.crossPressure
    local fingerprint,stamp,realmTime,regionTime=MarketDatasetIdentity()
    if not fingerprint then return false,"no-data" end
    for _,snapshot in ipairs(cp.snapshots) do
        if snapshot.datasetFingerprint==fingerprint or (not snapshot.datasetFingerprint and tonumber(snapshot.dataTime)==stamp) then
            return false,"same-data"
        end
    end
    local items={}
    local seen={}
    local function AddItem(item)
        if seen[item] then return end; seen[item]=true
        local p=CPMarketPoint(item); if p then items[item]=p end
    end
    for _,rel in ipairs(CROSS_PRESSURE_RELATIONS) do AddItem(rel.driver); AddItem(rel.target) end
    for _,recipe in pairs(CROSS_PRESSURE_RECIPES) do
        AddItem(recipe.output)
        for _,r in ipairs(recipe.reagents or {}) do AddItem(r.item) end
    end
    local recipes={}
    for key,recipe in pairs(CROSS_PRESSURE_RECIPES) do recipes[key]=CPRecipePoint(recipe) end
    cp.snapshots[#cp.snapshots+1]={datasetFingerprint=fingerprint,dataTime=stamp,realmDataTime=realmTime,regionDataTime=regionTime,capturedAt=Now(),reason=reason or "refresh",items=items,recipes=recipes}
    while #cp.snapshots>(tonumber(cp.maxSnapshots) or 48) do table.remove(cp.snapshots,1) end
    ObserveMarketDataset(reason or "cross-pressure")
    return true,cp.snapshots[#cp.snapshots]
end

local function CPDelta(a,b)
    a=tonumber(a); b=tonumber(b)
    if not a or not b or a<=0 then return nil end
    return (b/a)-1
end

local function CPProviderPrior(rel)
    local provider=EvidenceProvider()
    if not provider or type(provider.GetCrossPressurePrior)~="function" then return {} end
    local ok,result=pcall(provider.GetCrossPressurePrior,provider,rel.key)
    return ok and type(result)=="table" and result or {}
end
local function CPEvidence(rel)
    local db=EnsureDB(); local cp=db.crossPressure; local snaps=cp.snapshots or {}
    local returns={}; local liveEvents=0; local liveWins=0
    for i=2,#snaps-1 do
        local prev,cur,nxt=snaps[i-1],snaps[i],snaps[i+1]
        local pa=prev.items and prev.items[rel.driver]; local ca=cur.items and cur.items[rel.driver]
        local pb=prev.items and prev.items[rel.target]; local cb=cur.items and cur.items[rel.target]
        local nb=nxt.items and nxt.items[rel.target]
        local ad=pa and ca and CPDelta(pa.price,ca.price) or nil
        local bd=pb and cb and CPDelta(pb.price,cb.price) or nil
        local support=cur.recipes and cur.recipes[rel.recipe]
        local supported=(not support or not support.ratio) or support.ratio>=(tonumber(cp.craftSupportRatio) or .95)
        if ad and bd and ad<=-(tonumber(cp.driverDropPct) or .08) and bd<(tonumber(cp.targetAlreadyMovedPct) or .05) and supported and cb and nb then
            local response=CPDelta(cb.price,nb.price)
            if response then
                liveEvents=liveEvents+1; returns[#returns+1]=response
                if response>=(tonumber(cp.winRisePct) or .05) then liveWins=liveWins+1 end
            end
        end
    end
    local prior=CPProviderPrior(rel)
    local events=(tonumber(prior.events) or 0)+liveEvents; local wins=(tonumber(prior.wins) or 0)+liveWins
    for _,v in ipairs(prior.returns or {}) do returns[#returns+1]=v end
    return {events=events,wins=wins,hitRate=events>0 and wins/events or nil,median=CPMedian(returns),liveEvents=liveEvents,liveWins=liveWins,priorEvents=tonumber(prior.events) or 0,priorWins=tonumber(prior.wins) or 0}
end

local function CPFindRecentSetup(rel, snaps, cp)
    local n=#(snaps or {})
    local ttl=math.max(0,tonumber(cp.signalTTLUpdates) or 3)
    local first=math.max(2,n-ttl)
    for i=n,first,-1 do
        local prev,evt=snaps[i-1],snaps[i]
        local pA=prev and prev.items and prev.items[rel.driver]; local eA=evt and evt.items and evt.items[rel.driver]
        local pB=prev and prev.items and prev.items[rel.target]; local eB=evt and evt.items and evt.items[rel.target]
        local ad=pA and eA and CPDelta(pA.price,eA.price) or nil
        local bd=pB and eB and CPDelta(pB.price,eB.price) or nil
        local support=evt and evt.recipes and evt.recipes[rel.recipe]
        local supported=(not support or not support.ratio) or support.ratio>=(tonumber(cp.craftSupportRatio) or .95)
        if ad and bd and ad<=-(tonumber(cp.driverDropPct) or .08) and bd<(tonumber(cp.targetAlreadyMovedPct) or .05) and supported then
            return {index=i,ageUpdates=n-i,prev=prev,event=evt,baselineDriver=pA.price,baselineTarget=pB.price,eventDriver=eA.price,eventTarget=eB.price,driverMove=ad,targetMove=bd}
        end
    end
    return nil
end

local function CPCurrent(rel)
    local db=EnsureDB(); local cp=db.crossPressure; local snaps=cp.snapshots or {}; local n=#snaps
    local ev=CPEvidence(rel)
    local row={rel=rel,evidence=ev,status="LEARNING"}
    if n<1 then return row end
    local cur=snaps[n]; local cA=cur.items and cur.items[rel.driver]; local cB=cur.items and cur.items[rel.target]
    row.driverPrice=cA and cA.price or nil; row.targetPrice=cB and cB.price or nil
    local support=cur.recipes and cur.recipes[rel.recipe]; row.recipe=support
    row.craftSupported=(not support or not support.ratio) or support.ratio>=(tonumber(cp.craftSupportRatio) or .95)

    local basis=NeedAPI(true) and API.GetBasisInfo and API:GetBasisInfo(rel.target) or nil
    row.ownedQty=basis and tonumber(basis.observedQty) or 0
    row.basis=basis and tonumber(basis.basis) or nil
    row.basisTrusted=basis and basis.trustedForRadar==true or false
    row.unresolvedQty=basis and tonumber(basis.unresolvedQty) or 0

    -- A setup remains actionable for a few distinct AppHelper updates after the
    -- initial driver shock. This avoids losing the play simply because the
    -- following update shows A flat while B is still waiting to reprice.
    local setup=CPFindRecentSetup(rel,snaps,cp)
    row.setup=setup
    if setup then
        row.driverMove=setup.driverMove; row.targetMove=setup.targetMove
        row.driverTriggerPrice=setup.baselineDriver*(1-(tonumber(cp.driverDropPct) or .08))
        row.targetBaselinePrice=setup.baselineTarget
    else
        -- No active event: show the prices that would arm the NEXT setup.
        row.driverTriggerPrice=row.driverPrice and row.driverPrice*(1-(tonumber(cp.driverDropPct) or .08)) or nil
        row.targetBaselinePrice=row.targetPrice
    end

    local baselineB=tonumber(row.targetBaselinePrice)
    local med=tonumber(ev.median) or tonumber(cp.winRisePct) or .05
    med=math.max(tonumber(cp.winRisePct) or .05,med)
    local scalePct=math.max(tonumber(cp.winRisePct) or .05, med*(tonumber(cp.scaleOutFraction) or .60))
    row.buyCeiling=baselineB and baselineB*(1+(tonumber(cp.targetAlreadyMovedPct) or .05)) or nil
    row.scaleOutPrice=baselineB and baselineB*(1+scalePct) or nil
    row.exitPrice=baselineB and baselineB*(1+med) or nil
    row.expectedMovePct=med
    if row.targetPrice and row.exitPrice and row.targetPrice>0 then
        row.netRoom=((row.exitPrice*(1-(tonumber(cp.ahCutPct) or .05)))/row.targetPrice)-1
    end

    local evidenceReady=ev.events>=3 and (ev.hitRate or 0)>=.67
    local targetBelowCeiling=row.targetPrice and row.buyCeiling and row.targetPrice<=row.buyCeiling
    local targetAtScale=row.targetPrice and row.scaleOutPrice and row.targetPrice>=row.scaleOutPrice
    local targetAtExit=row.targetPrice and row.exitPrice and row.targetPrice>=row.exitPrice
    local driverStillCheap=setup and row.driverPrice and setup.baselineDriver and row.driverPrice<=setup.baselineDriver
    local enoughNet=(not row.netRoom) or row.netRoom>=(tonumber(cp.minNetEdgePct) or .05)

    if setup and row.ownedQty>0 and targetAtExit then
        row.status="EXIT NOW"
        row.action=string.format("POSITION %d: EXIT / SELL HARD now at %s or better.",row.ownedQty,Money(row.targetPrice))
    elseif setup and row.ownedQty>0 and targetAtScale then
        row.status="SCALE OUT"
        row.action=string.format("POSITION %d: SCALE OUT now; historical-median exit is %s.",row.ownedQty,Money(row.exitPrice))
    elseif setup and not row.craftSupported then
        row.status="ABORT"
        row.action="ABORT new buys: shared-craft support weakened enough to invalidate this setup."
    elseif setup and not driverStillCheap then
        row.status="ABORT"
        row.action=string.format("ABORT new buys: %s rebounded to its pre-drop price, so the cheap-input pressure is gone.",rel.driverName)
    elseif setup and targetBelowCeiling and evidenceReady and enoughNet then
        row.status="BUY NOW"
        row.action=string.format("DO IT: buy %s at %s or less. Do not chase above %s.",rel.targetName,Money(row.targetPrice),Money(row.buyCeiling))
    elseif setup and targetBelowCeiling then
        row.status="WATCH"
        if not evidenceReady then
            row.action=string.format("WATCH: setup is armed, but evidence is only %d/%d. Max entry remains %s.",ev.wins or 0,ev.events or 0,Money(row.buyCeiling))
        else
            row.action=string.format("WATCH: only %.1f%% projected net room after AH cut; require %.1f%%.",(row.netRoom or 0)*100,(tonumber(cp.minNetEdgePct) or .05)*100)
        end
    elseif setup then
        row.status="NO CHASE"
        row.action=string.format("NO NEW BUY: %s already crossed the %s ceiling.",rel.targetName,Money(row.buyCeiling))
    elseif n>=1 and ev.events>=2 then
        row.status="WAIT"
        row.action=string.format("WAIT until %s <= %s. If that happens, only buy %s <= %s.",rel.driverName,Money(row.driverTriggerPrice),rel.targetName,Money(row.buyCeiling))
    else
        row.status="LEARNING"
        row.action="LEARN: collect more distinct AppHelper updates before trading this relationship."
    end

    if setup and row.ownedQty>0 and row.status~="EXIT NOW" and row.status~="SCALE OUT" then
        row.positionAction=string.format("YOUR %s POSITION: HOLD below %s; SCALE OUT >= %s; EXIT >= %s.",rel.targetName,Money(row.scaleOutPrice),Money(row.scaleOutPrice),Money(row.exitPrice))
    elseif setup and row.ownedQty<=0 then
        row.positionAction=string.format("IF YOU ALREADY OWN %s: SCALE OUT >= %s; EXIT >= %s.",rel.targetName,Money(row.scaleOutPrice),Money(row.exitPrice))
    end
    local vendorSell=cB and tonumber(cB.vendorSell) or nil
    local deposit24=vendorSell and vendorSell>0 and vendorSell*.30 or 0
    local realized=row.targetPrice and row.basis and row.basis>0 and (((row.targetPrice*.95)-deposit24)/row.basis)-1 or nil
    row.obviousWin=row.ownedQty>0 and row.basisTrusted and row.unresolvedQty==0 and realized and realized>=.60 or false
    row.realizedNetPct=realized
    local setupStamp=(setup and setup.event and tonumber(setup.event.dataTime)) or 0
    local supportsProgress=row.status~="LEARNING" and row.driverPrice~=nil and row.targetPrice~=nil
    local sourceFingerprint=cur.datasetFingerprint or (cur.dataTime and ("legacy:"..tostring(cur.dataTime)) or nil)
    row.certainty,row.seen,row.confidenceGrade=ConclusionCertainty("cross",rel.key,tostring(row.status).."|"..tostring(setupStamp),row.obviousWin,supportsProgress,sourceFingerprint,cur.dataTime)
    return row
end

local function CPAllRows()
    local rows={} for _,rel in ipairs(CROSS_PRESSURE_RELATIONS) do rows[#rows+1]=CPCurrent(rel) end
    local rank={["EXIT NOW"]=1,["SCALE OUT"]=2,["BUY NOW"]=3,ABORT=4,WATCH=5,["NO CHASE"]=6,WAIT=7,LEARNING=8}
    table.sort(rows,function(a,b)
        local ar,br=rank[a.status] or 9,rank[b.status] or 9
        if ar~=br then return ar<br end
        local ae,be=a.evidence or {},b.evidence or {}
        if (ae.hitRate or -1)~=(be.hitRate or -1) then return (ae.hitRate or -1)>(be.hitRate or -1) end
        return tostring(a.rel.targetName)<tostring(b.rel.targetName)
    end)
    return rows
end

CPCaptureAndAlert=function(reason)
    local ok,result=CPCaptureSnapshot(reason)
    if not ok then return ok,result end
    local db=EnsureDB(); local cp=db.crossPressure
    local alertState=EvidenceProvider() and TRANSIENT_PROVIDER_STATE.alerts or cp.alertState
    local alertsEnabled=db.settings and db.settings.alertSignalChanges~=false
    for _,row in ipairs(CPAllRows()) do
        local rel=row.rel or {}
        local setupStamp=(row.setup and row.setup.event and tonumber(row.setup.event.dataTime)) or 0
        local signature=tostring(row.status or "?").."|"..tostring(setupStamp)
        local old=alertState[rel.key]
        alertState[rel.key]=signature
        local meaningful=(row.status=="BUY NOW" or row.status=="WATCH" or row.status=="SCALE OUT" or row.status=="EXIT NOW" or row.status=="ABORT" or row.status=="NO CHASE")
        if alertsEnabled and meaningful and old~=signature then
            local a=row.driverPrice and Money(row.driverPrice) or "?"
            local b=row.targetPrice and Money(row.targetPrice) or "?"
            local ceiling=row.buyCeiling and Money(row.buyCeiling) or "?"
            print(string.format("|cffffcc00★ CROSS:|r %s → %s — |cffffffff%s|r. %s %s • %s %s • %s ceiling %s",rel.driverName or "trigger material",rel.targetName or "candidate material",row.status or "?",rel.driverName or "Trigger",a,rel.targetName or "Candidate",b,rel.targetName or "Candidate",ceiling))
            if row.action then print("  "..tostring(row.action)) end
        end
    end
    return ok,result
end

local POSITION_CACHE = {rows=nil,totalInvested=0,realmTime=nil,regionTime=nil,scope=nil,builtAt=0}

local function PositionMarketDataTimes()
    if not API or type(API.GetMarketDataTimes)~="function" then return nil,nil end
    local ok,realmTime,regionTime=pcall(API.GetMarketDataTimes,API)
    if not ok then return nil,nil end
    return tonumber(realmTime),tonumber(regionTime)
end

local function InvalidatePositionIntelligenceCache()
    POSITION_CACHE.rows=nil
    POSITION_CACHE.totalInvested=0
    POSITION_CACHE.realmTime=nil
    POSITION_CACHE.regionTime=nil
    POSITION_CACHE.scope=nil
    POSITION_CACHE.builtAt=0
end

local function PositionIntelligenceRows(force)
    if not NeedAPI(true) then return {},0 end
    local realmTime,regionTime=PositionMarketDataTimes()
    local scope=ScopeKey()
    if not force and POSITION_CACHE.rows
        and POSITION_CACHE.realmTime==realmTime
        and POSITION_CACHE.regionTime==regionTime
        and POSITION_CACHE.scope==scope then
        return POSITION_CACHE.rows,POSITION_CACHE.totalInvested
    end

    if type(API.GetPositionInputs)~="function" then return {},0 end
    local inputOK,inputs=pcall(API.GetPositionInputs,API)
    if not inputOK or type(inputs)~="table" then return {},0 end
    local scanners=ScannerModule()
    local cfgOK,cfg=false,nil
    if scanners then cfgOK,cfg=pcall(scanners.GetSettings,scanners) end
    cfg=cfgOK and type(cfg)=="table" and cfg or {}
    local rows,totalInvested={},0
    ObserveMarketDataset("position-intelligence")

    for _,input in ipairs(inputs) do
        local itemString=input.itemString
        local owned=tonumber(input.observedQty) or 0
        local market={}
        if type(API.GetMarketContext)=="function" then
            local marketOK,result=pcall(API.GetMarketContext,API,itemString)
            if marketOK and type(result)=="table" then market=result end
        end
        local genuineBasis=tonumber(input.basis)
        local trustedBasis=genuineBasis and genuineBasis>0 and input.trustedForRadar==true and (tonumber(input.unresolvedQty) or 0)==0
        local unitBasis=(genuineBasis and genuineBasis>0 and genuineBasis) or tonumber(market.dbmarket)
        local basisProxy=not (genuineBasis and genuineBasis>0) and unitBasis and unitBasis>0 or false
        if owned>0 and unitBasis and unitBasis>0 then
            local known=basisProxy and owned or math.max(0,tonumber(input.knownQty) or 0)
            local invested=known*unitBasis
            local recent=tonumber(market.recent) or tonumber(market.minbuyout) or tonumber(market.dbmarket) or tonumber(market.cachedLow)
            -- Successful auctions return their deposit. For a conservative exit
            -- reference, reserve one failed 24-hour faction-AH listing when TSM
            -- exposes vendor-sell value (24h deposit = 30% of vendor value).
            local vendorSell=tonumber(market.vendorSell)
            local deposit24=vendorSell and vendorSell>0 and vendorSell*.30 or 0
            local signals={}
            local cachedLow=tonumber(market.cachedLow)
            local ratio=cachedLow and unitBasis>0 and (cachedLow/unitBasis) or nil
            if ratio and ratio<=(tonumber(cfg.deepCostPct) or .65) then signals[#signals+1]="DEEP"
            elseif ratio and ratio<=(tonumber(cfg.lowCostPct) or .75) then signals[#signals+1]="LOW" end
            if market.liquidity=="ACTIVE" then signals[#signals+1]="FAST"
            elseif market.liquidity=="THIN" then signals[#signals+1]="THIN" end
            local regionRatio=tonumber(market.regionRatio)
            if regionRatio and regionRatio<=(tonumber(cfg.regionDiscountLook) or .80) then signals[#signals+1]="REGION CHEAP" end
            local signalSet={} for _,signal in ipairs(signals) do signalSet[signal]=true end
            local positive=0
            for _,signal in ipairs({"DEEP","LOW","REGION CHEAP","FAST","SHELF"}) do if signalSet[signal] then positive=positive+1 end end
            local row={
                itemString=itemString,name=input.name or ItemName(itemString),owned=owned,known=known,
                unresolved=tonumber(input.unresolvedQty) or 0,basis=unitBasis,invested=invested,
                basisProxy=basisProxy,basisSource=basisProxy and "DBMarket proxy" or (input.sourceLabel or "Universal Basis Keeper"),trustedBasis=trustedBasis,
                recent=recent,market=market,signals=signals,positiveSignals=positive,
                buy10=unitBasis*.90,buy15=unitBasis*.85,
                deposit24=deposit24,depositKnown=vendorSell and vendorSell>0 or false,
                sell5=((unitBasis*1.05)+deposit24)/.95,
                sell15=((unitBasis*1.15)+deposit24)/.95,
                sell25=((unitBasis*1.25)+deposit24)/.95,
            }
            rows[#rows+1]=row; totalInvested=totalInvested+invested
        end
    end
    for _,row in ipairs(rows) do
        row.share=totalInvested>0 and row.invested/totalInvested or 0
        row.delta=row.recent and row.basis>0 and (row.recent/row.basis)-1 or nil
        local thin=false for _,signal in ipairs(row.signals) do if signal=="THIN" then thin=true end end
        if row.recent and row.recent>=row.sell25 then
            row.stance="SELL HARD"
            row.action="Get yours on now. This is the strongest fee-aware sell window."
            row.reason="HUGE uptick: the current loaded price clears your 25% net-profit exit after the Auction House cut and posting-risk reserve."
        elseif row.recent and row.recent>=row.sell15 then
            row.stance="SELL LIGHTLY"
            row.action="Post part of the position. Do not dump the whole stack."
            row.reason="The price is nicely above normal and clears your 15% net-profit exit, but has not reached SELL HARD."
        elseif row.recent and row.recent>=row.sell5 then
            row.stance="HOLD / SELL SLOW"
            row.action="Post small amounts and let buyers come to you."
            row.reason="The price clears your 5% net-profit exit but not the stronger sell levels. There is profit available without rushing the position out."
        elseif row.share>=.25 then
            row.stance="NO ADD"
            row.action="Do not increase this position."
            row.reason="This item already represents at least 25% of your known UBK invested value. Concentration risk wins over a merely attractive price."
        elseif row.recent and row.recent<=row.buy15 and row.positiveSignals>=2 and not thin and row.share<.15 then
            row.stance="BUY ALL OF THEM"
            row.action="Buy every listing at or below "..Money(row.buy15)..". Do not chase above that ceiling."
            row.reason="Very cheap: the loaded price is at least 15% below basis, multiple positive signals agree, liquidity is not marked THIN, and this position is still below 15% of known invested value."
        elseif row.recent and row.recent<=row.buy10 and row.positiveSignals>=1 and not thin and row.share<.20 then
            row.stance="BUY SOME"
            row.action="Buy a starter amount at or below "..Money(row.buy10)..", then refresh and reassess."
            row.reason="Cheap enough to improve your basis: the loaded price is at least 10% below basis, supporting context is present, liquidity is not marked THIN, and this position remains below 20% of known invested value."
        elseif thin then
            row.stance="WATCH / THIN"
            row.action="Watch only; do not treat a thin market like a dependable entry."
            row.reason="Thin liquidity makes both the quoted price and your eventual exit less reliable."
        elseif not row.recent then
            row.stance="NO RECENT DATA"
            row.action="Wait for a usable TSM recent-realm reference."
            row.reason="TSM has not exposed a usable recent realm price for this item, so UBK cannot place it honestly on the ladder."
        else
            row.stance="HOLD"
            row.action="Hold. No high-confidence buy or fee-aware sell is active."
            row.reason="The loaded price has not crossed a guarded buy level or a profitable sell level with the required supporting context."
        end
        local realized=row.recent and row.basis>0 and (((row.recent*.95)-row.deposit24)/row.basis)-1 or nil
        row.realizedNetPct=realized
        row.netPerUnit=row.recent and ((row.recent*.95)-row.deposit24-row.basis) or nil
        row.netCovered=row.netPerUnit and row.netPerUnit*math.min(row.owned,row.known) or nil
        row.netSalePerUnit=row.recent and ((row.recent*.95)-row.deposit24) or nil
        local currentCoveredBasis=row.basis*math.min(row.owned,row.known)
        row.recoveryQty=row.netSalePerUnit and row.netSalePerUnit>0 and math.ceil(currentCoveredBasis/row.netSalePerUnit) or nil
        row.paidRunnerQty=row.recoveryQty and math.max(0,row.owned-row.recoveryQty) or 0
        -- Quick Wins is deliberately plain math, not a hidden score. It only
        -- admits fully covered, trusted positions that clear 15% after the AH
        -- cut and posting-risk reserve, while refusing markets marked THIN.
        row.quickWin=row.trustedBasis and row.unresolved==0 and row.known>=row.owned and realized and realized>=.15 and row.market.liquidity~="THIN" or false
        row.paidRunner=row.quickWin and row.paidRunnerQty>0 or false
        row.obviousWin=row.trustedBasis and realized and realized>=.60 or false
        row.certainty,row.seen,row.confidenceGrade=ConclusionCertainty("position",row.itemString,row.stance,row.obviousWin,row.stance~="NO RECENT DATA")
    end
    local rank={['SELL HARD']=1,['BUY ALL OF THEM']=2,['SELL LIGHTLY']=3,['BUY SOME']=4,['HOLD / SELL SLOW']=5,['NO ADD']=6,['WATCH / THIN']=7,['HOLD']=8,['NO RECENT DATA']=9}
    table.sort(rows,function(a,b)
        local ar,br=rank[a.stance] or 10,rank[b.stance] or 10
        if ar~=br then return ar<br end
        if a.invested~=b.invested then return a.invested>b.invested end
        return tostring(a.name)<tostring(b.name)
    end)
    POSITION_CACHE.rows=rows
    POSITION_CACHE.totalInvested=totalInvested
    POSITION_CACHE.realmTime=realmTime
    POSITION_CACHE.regionTime=regionTime
    POSITION_CACHE.scope=scope
    POSITION_CACHE.builtAt=Now()
    return rows,totalInvested
end


local function ItemID(item)
    if type(item)=="number" then return item end
    local s=tostring(item or "")
    local id=s:match("|Hitem:(%d+)") or s:match("^item:(%d+)") or s:match("^i:(%d+)") or s:match("^(%d+)$")
    return id and tonumber(id) or nil
end
local function ItemTexture(item)
    local id=ItemID(item)
    local tex
    if id and type(GetItemIcon)=="function" then
        local ok,v=pcall(GetItemIcon,id)
        if ok then tex=v end
    end
    if not tex and id and type(GetItemInfoInstant)=="function" then
        local ok,a,b,c,d,v=pcall(GetItemInfoInstant,id)
        if ok then tex=v end
    end
    if not tex and type(GetItemInfo)=="function" then
        local ok,a,b,c,d,e,f,g,h,i,j=pcall(GetItemInfo,id or item)
        if ok then tex=j end
    end
    return tex or "Interface\\Icons\\INV_Misc_QuestionMark"
end
local function ItemTextureTag(item,size)
    local tex=ItemTexture(item)
    size=tonumber(size) or 14
    return "|T"..tostring(tex)..":"..size..":"..size..":0:0|t"
end
local function ItemLink(item)
    local raw=tostring(item or "")
    if raw:find("|Hitem:",1,true) then return raw end
    local id=ItemID(item)
    if id and type(GetItemInfo)=="function" then
        local ok,_,link=pcall(GetItemInfo,id)
        if ok and type(link)=="string" and link~="" then return link end
    end
    return nil
end
local function ShowItemTooltip(owner,item,anchor)
    if not GameTooltip then return end
    local id=ItemID(item)
    GameTooltip:SetOwner(owner,anchor or "ANCHOR_RIGHT")
    if id and GameTooltip.SetHyperlink then
        local ok=pcall(function() GameTooltip:SetHyperlink("item:"..id) end)
        if ok then GameTooltip:Show(); return end
    end
    GameTooltip:AddLine(ItemName(item),1,.82,0)
    GameTooltip:AddLine("Item information is still loading.",.75,.75,.75,true)
    GameTooltip:Show()
end
local function InsertItemIntoChat(item)
    local link=ItemLink(item)
    if not link then
        print("|cffff7777Universal Basis Keeper:|r item link is not cached yet; hover the item once and try Shift-click again.")
        return false
    end
    -- Market Inspector uses Shift-click capture only while its input has focus.
    -- A deliberate Shift-click on a UBK item should instead behave like a normal
    -- WoW item link, so release that focus before asking chat to insert it.
    if UI.marketEditBox and UI.marketEditBox.ClearFocus then UI.marketEditBox:ClearFocus() end
    if type(ChatEdit_InsertLink)=="function" then
        local ok,result=pcall(ChatEdit_InsertLink,link)
        if ok and result then return true end
    end
    if type(ChatFrame_OpenChat)=="function" then
        local ok=pcall(ChatFrame_OpenChat,link.." ")
        if ok then return true end
    end
    print("|cffff7777Universal Basis Keeper:|r open a chat edit box, then Shift-click the item again.")
    return false
end

local function GetSignalsForLive(r)
    local s={}
    local scanners=ScannerModule()
    local cfg=scanners and scanners:GetSettings() or {}
    if r.costRatio and r.costRatio <= (cfg.deepCostPct or .65) then s[#s+1]="DEEP"
    elseif r.costRatio and r.costRatio <= (cfg.lowCostPct or .75) then s[#s+1]="LOW" end
    if r.liquidity=="ACTIVE" then s[#s+1]="FAST" elseif r.liquidity=="THIN" then s[#s+1]="THIN" end
    if r.regionLiveRatio and r.regionLiveRatio <= (cfg.regionDiscountLook or .80) then s[#s+1]="REGION CHEAP" end
    if r.shelfStatus=="LOOK" then s[#s+1]="SHELF" end
    if r.category=="rare" then s[#s+1]="RARE" end
    return s
end
local function HasSignal(signals, needle)
    if needle=="ALL" then return true end
    for _,v in ipairs(signals or {}) do if v==needle then return true end end
    return false
end

local function SnapshotWatchItem(itemString)
    if not NeedAPI(true) then return nil end
    local intel=API:GetCachedIntelligence(itemString)
    if not intel then return nil end
    local realmTime,regionTime=API:GetMarketDataTimes()
    -- Watch history is public SavedVariables state. Never copy the basis result
    -- because a private runtime provider may have attached owner-only evidence.
    -- The public signal labels and market references are sufficient for change
    -- detection and remain safe when the provider disappears.
    return {at=Now(),realmDataTime=realmTime,regionDataTime=regionTime,cachedPrice=intel.cachedPrice,costRatio=intel.costRatio,signals=Copy(intel.signals),market=Copy(intel.market)}
end
local function SameSignalSet(a,b)
    local x,y={},{} for _,v in ipairs(a or {}) do x[v]=true end for _,v in ipairs(b or {}) do y[v]=true end
    for k in pairs(x) do if not y[k] then return false end end for k in pairs(y) do if not x[k] then return false end end return true
end
local function RefreshWatchlist(login)
    if not NeedAPI(true) then return end
    local db=EnsureDB(); local changed=0; local count=0
    for itemString,w in pairs(db.watchlist) do
        count=count+1
        local old=w.current and Copy(w.current) or nil
        local cur=SnapshotWatchItem(itemString)
        if cur then
            w.previous=old; w.current=cur; w.lastSeen=Now(); w.name=ItemName(itemString)
            if old and (not SameSignalSet(old.signals,cur.signals) or old.cachedPrice~=cur.cachedPrice) then changed=changed+1 end
        end
    end
    if login and db.settings.loginSummary and count>0 then
        local rt,rg=API:GetMarketDataTimes()
        print(string.format("|cffffcc00Universal Basis Keeper:|r watchlist refreshed on login — %d item%s, %d changed. Realm data %s old; region data %s old.",count,count==1 and "" or "s",changed,Age(rt),Age(rg)))
        if db.settings.alertSignalChanges and changed>0 then
            for itemString,w in pairs(db.watchlist) do
                if w.previous and w.current and not SameSignalSet(w.previous.signals,w.current.signals) then
                    print(string.format("  |cff66ccffWATCH:|r %s — %s -> %s",w.name or ItemName(itemString),JoinSignals(w.previous.signals),JoinSignals(w.current.signals)))
                end
            end
        end
    end
end
local function AddWatch(itemString)
    if not itemString then return end
    local db=EnsureDB(); local isNew=db.watchlist[itemString]==nil
    local w=db.watchlist[itemString] or {addedAt=Now()}; db.watchlist[itemString]=w
    w.name=ItemName(itemString); w.current=SnapshotWatchItem(itemString); w.lastSeen=Now()
    if _G.UBKPositionWatchUI then _G.UBKPositionWatchUI.CaptureWatchStart({API=API},itemString,w,isNew) end
    print("|cff33ff99UBK:|r watching "..w.name..".")
end
local function RemoveWatch(itemString)
    local db=EnsureDB(); if db.watchlist[itemString] then print("|cffffcc00Universal Basis Keeper:|r removed "..(db.watchlist[itemString].name or ItemName(itemString)).." from watchlist.") end
    db.watchlist[itemString]=nil
end

local function MakeButton(parent,text,w,h)
    local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate"); b:SetSize(w or 100,h or 24); b:SetText(text); return b
end
local function MakeText(parent,template)
    local t=parent:CreateFontString(nil,"OVERLAY",template or "GameFontHighlightSmall"); t:SetJustifyH("LEFT"); return t
end
local function ClearContent()
    if not UI.content then return end
    if UI.marketEditBox then
        if UI.marketEditBox.ClearFocus then UI.marketEditBox:ClearFocus() end
        UI.marketEditBox=nil
    end
    if UI.chumEditBox then
        if UI.chumEditBox.ClearFocus then UI.chumEditBox:ClearFocus() end
        UI.chumEditBox=nil
    end
    for _,c in ipairs({UI.content:GetChildren()}) do c:Hide() end
    for _,r in pairs({UI.content:GetRegions()}) do if r~=UI.content.bg then r:Hide() end end
end
local RenderPage
local NavigateRoot
local HandleEscape
local LeaveTestArena
local function SaveWindowGeometry(f, db)
    if not f or not db then return end
    local cx,cy=f:GetCenter()
    local px,py=UIParent:GetCenter()
    if cx and cy and px and py then
        db.windowX=cx-px
        db.windowY=cy-py
    end
    db.uiScale=ClampUIScale(f.GetScale and f:GetScale() or db.uiScale)
    db.width=DESIGN_WIDTH
    db.height=DESIGN_HEIGHT
end

local function ApplyUIScale(scale,announce)
    local db=EnsureDB()
    db.uiScale=ClampUIScale(scale)
    if UI.root and UI.root.SetScale then UI.root:SetScale(db.uiScale) end
    if announce then print(string.format("|cff33ff99Universal Basis Keeper:|r window scale %.0f%%.",db.uiScale*100)) end
    return db.uiScale
end

local function BeginScaleSizing(driver,f,db)
    if not driver or not f or UI.scaleSizing then return end
    local x,y=GetCursorPosition()
    UI.scaleSizing={driver=driver,frame=f,db=db,startX=x,startY=y,startScale=f:GetScale() or 1}
    driver:SetScript("OnUpdate",function(self)
        local st=UI.scaleSizing
        if not st or st.driver~=self then return end
        local cx,cy=GetCursorPosition()
        local parentScale=(UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
        if not parentScale or parentScale<=0 then parentScale=1 end
        local dx=(cx-st.startX)/parentScale
        local dy=(st.startY-cy)/parentScale
        local dw=dx/DESIGN_WIDTH
        local dh=dy/DESIGN_HEIGHT
        local delta=math.abs(dw)>=math.abs(dh) and dw or dh
        st.frame:SetScale(ClampUIScale(st.startScale+delta))
    end)
end

local function EndScaleSizing(driver,f,db)
    if driver then driver:SetScript("OnUpdate",nil) end
    UI.scaleSizing=nil
    if f and db then SaveWindowGeometry(f,db) end
    if UI.content and RenderPage then RenderPage() end
end

local function RegisterSpecialFrame(frameName)
    if type(UISpecialFrames)~="table" or not frameName then return end
    for _,name in ipairs(UISpecialFrames) do if name==frameName then return end end
    table.insert(UISpecialFrames,frameName)
end

local function RegisterEscapeClose()
    -- The main UBK frame uses contextual Escape navigation instead of Blizzard's
    -- one-shot UISpecialFrames close. Resolve dialogs are still registered as
    -- special frames so Escape can dismiss them immediately.
end

local function GoldLine(parent,point,y)
    local line=parent:CreateTexture(nil,"ARTWORK")
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetVertexColor(.70,.46,.12,.92)
    line:SetHeight(1)
    line:SetPoint(point.."LEFT",10,y)
    line:SetPoint(point.."RIGHT",-10,y)
    return line
end

local function AddWorkshopChrome(f)
    local header=f:CreateTexture(nil,"BACKGROUND")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background-Dark")
    header:SetPoint("TOPLEFT",8,-8); header:SetPoint("TOPRIGHT",-8,-8); header:SetHeight(58)
    header:SetVertexColor(.19,.135,.045,.98)

    local headerGlow=f:CreateTexture(nil,"BORDER")
    headerGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerGlow:SetPoint("TOPLEFT",10,-10); headerGlow:SetPoint("TOPRIGHT",-10,-10); headerGlow:SetHeight(4)
    headerGlow:SetVertexColor(.86,.55,.12,.30)

    local footer=f:CreateTexture(nil,"BACKGROUND")
    footer:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background-Dark")
    footer:SetPoint("BOTTOMLEFT",8,8); footer:SetPoint("BOTTOMRIGHT",-8,8); footer:SetHeight(54)
    footer:SetVertexColor(.12,.078,.022,.99)

    GoldLine(f,"TOP",-67)
    GoldLine(f,"BOTTOM",63)

    local emblem=f:CreateTexture(nil,"ARTWORK")
    emblem:SetTexture("Interface\\Icons\\INV_Misc_Gem_Emerald_02")
    emblem:SetSize(62,62); emblem:SetPoint("TOPLEFT",9,-7)
    UI.goblinEmblem=emblem

    local gear=f:CreateTexture(nil,"ARTWORK")
    gear:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
    gear:SetSize(30,30); gear:SetPoint("BOTTOMLEFT",23,17); gear:SetAlpha(.76)

    local coins=f:CreateTexture(nil,"ARTWORK")
    coins:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    coins:SetSize(30,30); coins:SetPoint("BOTTOMRIGHT",30,17); coins:SetAlpha(.86)

    local footerLabel=MakeText(f,"GameFontDisableSmall")
    footerLabel:SetPoint("BOTTOMLEFT",60,19)
    footerLabel:SetText("UNIVERSAL BASIS KEEPER")
    footerLabel:SetTextColor(.72,.55,.23)

    local footerTip=MakeText(f,"GameFontDisableSmall")
    footerTip:SetPoint("BOTTOMRIGHT",-64,19)
    footerTip:SetText("Esc: back  •  drag: move  •  Shift-drag/corner: scale")
    footerTip:SetTextColor(.72,.55,.23)
end

local function MakeMinimapLauncher(name,iconPath,y,label,onClick,tooltipTitle)
    if _G[name] then return _G[name] end
    if not Minimap then return nil end
    local b=CreateFrame("Button",name,Minimap)
    b:SetSize(34,34); b:SetFrameStrata("MEDIUM")
    if b.SetFrameLevel and Minimap.GetFrameLevel then b:SetFrameLevel((Minimap:GetFrameLevel() or 0)+8) end
    b:SetPoint("TOPLEFT",Minimap,"TOPRIGHT",5,y)
    b:RegisterForClicks("LeftButtonUp","RightButtonUp")

    local icon=b:CreateTexture(nil,"BACKGROUND")
    icon:SetTexture(iconPath); icon:SetSize(25,25); icon:SetPoint("CENTER",0,0)

    local border=b:CreateTexture(nil,"OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(56,56); border:SetPoint("TOPLEFT",-11,11)

    local tag=b:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    tag:SetPoint("BOTTOM",0,-1); tag:SetText(label or ""); tag:SetTextColor(1,.82,.25)

    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:SetScript("OnClick",function()
        if onClick then onClick() end
    end)
    b:SetScript("OnEnter",function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self,"ANCHOR_LEFT")
            GameTooltip:AddLine(tooltipTitle or "UBK / Universal Basis Keeper",1,.82,0)
            GameTooltip:AddLine("Click to open the UBK / UBK interface.",1,1,1,true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    return b
end

local function OpenHomeFromMinimap()
    if _G.UBKInterface_Show then _G.UBKInterface_Show("home") end
end

local function CreateMinimapLaunchers()
    if UI.minimapBuilt then return end
    UI.minimapBuilt=true
    if _G.UBKInterfaceMinimapButton then _G.UBKInterfaceMinimapButton:Hide() end
    UI.ubkMinimap=MakeMinimapLauncher(
        "UniversalBasisKeeperMinimapButton",
        "Interface\\Icons\\INV_Misc_Gear_01",
        -18,"UBK",OpenHomeFromMinimap,"Universal Basis Keeper"
    )
end

local function CreateWindow()
    if UI.root then return end
    local db=EnsureDB(); local template=BackdropTemplateMixin and "BackdropTemplate" or nil
    local f=CreateFrame("Frame","UBKInterfaceFrame",UIParent,template); UI.root=f
    f:SetSize(DESIGN_WIDTH,DESIGN_HEIGHT); f:SetScale(ClampUIScale(db.uiScale)); f:SetPoint("CENTER",UIParent,"CENTER",db.windowX,db.windowY); f:SetFrameStrata("HIGH"); f:SetToplevel(true)
    if _G.UBKWindowFocus then _G.UBKWindowFocus.Register(f) end
    f:SetMovable(true)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    if f.SetResizable then f:SetResizable(false) end
    f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    if f.EnableKeyboard and f.SetPropagateKeyboardInput then
        f:EnableKeyboard(true)
        f:SetPropagateKeyboardInput(true)
        f:SetScript("OnKeyDown",function(self,key)
            if key=="ESCAPE" and HandleEscape then
                local focus=type(GetCurrentKeyBoardFocus)=="function" and GetCurrentKeyBoardFocus() or nil
                if focus and focus~=self then
                    self:SetPropagateKeyboardInput(true)
                    return
                end
                self:SetPropagateKeyboardInput(false)
                HandleEscape()
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)
        f:SetScript("OnKeyUp",function(self) self:SetPropagateKeyboardInput(true) end)
    else
        -- Compatibility fallback for unusual hosts lacking keyboard propagation.
        RegisterSpecialFrame("UBKInterfaceFrame")
    end
    f:SetScript("OnDragStart",function(self)
        if IsShiftKeyDown and IsShiftKeyDown() then
            UI.shiftSizing=true
            BeginScaleSizing(self,self,db)
        else
            UI.shiftSizing=false
            self:StartMoving()
        end
    end)
    f:SetScript("OnDragStop",function(self)
        if UI.shiftSizing or UI.scaleSizing then
            EndScaleSizing(self,self,db)
        else
            self:StopMovingOrSizing()
            SaveWindowGeometry(self,db)
            if UI.content and RenderPage then RenderPage() end
        end
        UI.shiftSizing=false
    end)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=24,edgeSize=24,
            insets={left=7,right=7,top=7,bottom=7}
        })
        f:SetBackdropColor(.018,.014,.009,.985)
        f:SetBackdropBorderColor(.66,.44,.13,1)
    end

    AddWorkshopChrome(f)

    local title=MakeText(f,"GameFontNormalLarge")
    title:SetPoint("TOPLEFT",72,-17)
    title:SetText("UNIVERSAL BASIS KEEPER")
    title:SetTextColor(1,.80,.24)

    local motto=MakeText(f,"GameFontNormalSmall")
    motto:SetPoint("TOPLEFT",73,-40)
    motto:SetText("Every item has a price. Your inventory has a story.")
    motto:SetTextColor(.42,.93,.20)

    local ver=MakeText(f,"GameFontDisableSmall")
    ver:SetPoint("TOPRIGHT",-49,-42)
    ver:SetText(VERSION)

    local close=CreateFrame("Button",nil,f,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-6,-6)

    local resize=CreateFrame("Button",nil,f)
    resize:SetSize(25,25); resize:SetPoint("BOTTOMRIGHT",-9,10)
    resize:EnableMouse(true); resize:RegisterForDrag("LeftButton")
    resize:SetScript("OnDragStart",function(self) BeginScaleSizing(self,f,db) end)
    resize:SetScript("OnDragStop",function(self) EndScaleSizing(self,f,db) end)
    local rt=resize:CreateTexture(nil,"OVERLAY"); rt:SetAllPoints(); rt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resize:SetScript("OnEnter",function() rt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight") end)
    resize:SetScript("OnLeave",function() rt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up") end)

    UI.nav=CreateFrame("Frame",nil,f,template)
    UI.nav:SetPoint("TOPLEFT",14,-73); UI.nav:SetPoint("BOTTOMLEFT",14,69); UI.nav:SetWidth(154)
    if UI.nav.SetBackdrop then
        UI.nav:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=12,edgeSize=10,insets={left=3,right=3,top=3,bottom=3}})
        UI.nav:SetBackdropColor(.035,.028,.014,.91); UI.nav:SetBackdropBorderColor(.46,.31,.09,.88)
    end

    UI.contentShell=CreateFrame("Frame",nil,f,template)
    UI.contentShell:SetPoint("TOPLEFT",176,-73); UI.contentShell:SetPoint("BOTTOMRIGHT",-15,69)
    if UI.contentShell.SetBackdrop then
        UI.contentShell:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=12,edgeSize=10,insets={left=3,right=3,top=3,bottom=3}})
        UI.contentShell:SetBackdropColor(.015,.014,.010,.84); UI.contentShell:SetBackdropBorderColor(.38,.27,.08,.76)
    end
    UI.content=CreateFrame("Frame",nil,UI.contentShell)
    UI.content:SetAllPoints(UI.contentShell)

    local tabs={
        {"home","Home","UBK accounting, cost coverage, and actions for your current positions."},
        {"chum","Chum Scanner","Read completed TSM/AppHelper scan data against trusted UBK basis and flag bait-shaped lows without requiring the Auction House."},
        {"cross",CROSS_PRESSURE_LABEL,"Linked-market lead/lag playbooks with a named trigger material, named candidate material, entry ceiling, scale-out, exit guidance, event lesson, and recipe-market search controls."},
        {"position",POSITION_INTELLIGENCE_LABEL,"Position-level basis, ownership, recent-market, liquidity, concentration, and fee-aware exit intelligence."},
        {"market","Market Inspector","Inspect UBK basis beside currently loaded TSM/AppHelper market context."},
        {"watch","Watchlist","Review saved markets and changes between distinct AppHelper updates."},
        {"coverage","Cost Coverage","Review complete, partial, unknown, protected, and unresolved UBK cost coverage."},
        {"settings","Settings","Adjust the active tools with examples of how each setting affects their results."},
    }
    UI.navButtons={}
    local y=-9
    for _,spec in ipairs(tabs) do
        local b=MakeButton(UI.nav,spec[2],142,29); b:SetPoint("TOPLEFT",6,y); y=y-33
        UI.navButtons[spec[1]]=b
        b:SetScript("OnClick",function()
            if spec[1]=="coverage" then UI.coverageSection="coverage" end
            if spec[1]=="position" then UI.positionSection="positions" end
            if NavigateRoot then NavigateRoot(spec[1]) end
        end)
        AddButtonTooltip(b,spec[2],spec[3] or "Open this UBK workspace.",spec[4])
    end

    local navHint=MakeText(UI.nav,"GameFontDisableSmall")
    navHint:SetPoint("BOTTOMLEFT",8,12); navHint:SetPoint("RIGHT",-7,0)
    navHint:SetText("UBK owns the basis.\nYou choose the next move.")
    navHint:SetTextColor(.58,.52,.40)

    RegisterEscapeClose()
    f:Hide()
end

local function PageTitle(text,sub)
    local t=MakeText(UI.content,"GameFontNormalLarge")
    t:SetPoint("TOPLEFT",10,-8); t:SetText(text); t:SetTextColor(1,.78,.22)
    if sub then
        local s=MakeText(UI.content,"GameFontDisableSmall")
        s:SetPoint("TOPLEFT",10,-34); s:SetPoint("RIGHT",-10,0); s:SetHeight(14); s:SetText(sub)
        if s.SetWordWrap then s:SetWordWrap(false) end
        if s.SetNonSpaceWrap then s:SetNonSpaceWrap(false) end
        local hit=CreateFrame("Frame",nil,UI.content)
        hit:SetPoint("TOPLEFT",8,-28); hit:SetPoint("TOPRIGHT",-8,-28); hit:SetHeight(25); hit:EnableMouse(true)
        hit:SetScript("OnEnter",function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self,"ANCHOR_CURSOR")
                GameTooltip:AddLine(text,1,.82,0)
                GameTooltip:AddLine(sub,.92,.92,.92,true)
                GameTooltip:Show()
            end
        end)
        hit:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    end
    local line=UI.content:CreateTexture(nil,"ARTWORK")
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetVertexColor(.48,.31,.08,.72)
    line:SetPoint("TOPLEFT",8,-51); line:SetPoint("TOPRIGHT",-8,-51); line:SetHeight(1)
end
local function RowsFor(topOffset,reserveBottom)
    local h=(UI.content and UI.content.GetHeight and UI.content:GetHeight()) or 560
    return math.max(2,math.min(ROWS,math.floor((h-(topOffset or 100)-(reserveBottom or 36))/30)))
end
local function AddPager(total,perPage)
    perPage=math.max(1,tonumber(perPage) or ROWS)
    local pages=math.max(1,math.ceil(total/perPage)); if UI.listPage>pages then UI.listPage=pages end
    local prev=MakeButton(UI.content,"<",32,22); prev:SetPoint("BOTTOMRIGHT",-92,0); prev:SetEnabled(UI.listPage>1); prev:SetScript("OnClick",function() UI.listPage=math.max(1,UI.listPage-1); RenderPage() end)
    local info=MakeText(UI.content,"GameFontDisableSmall"); info:SetPoint("RIGHT",prev,"LEFT",-8,0); info:SetText(string.format("%d / %d",UI.listPage,pages))
    local nextb=MakeButton(UI.content,">",32,22); nextb:SetPoint("LEFT",prev,"RIGHT",4,0); nextb:SetEnabled(UI.listPage<pages); nextb:SetScript("OnClick",function() UI.listPage=math.min(pages,UI.listPage+1); RenderPage() end)
end
local function Row(parent,y,text,onClick,onRight)
    local b=CreateFrame("Button",nil,parent)
    b:SetHeight(28); b:SetPoint("TOPLEFT",6,y); b:SetPoint("RIGHT",-6,0)
    b:RegisterForClicks("LeftButtonUp","RightButtonUp")
    local bg=b:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); bg:SetTexture("Interface\\Buttons\\WHITE8X8"); bg:SetVertexColor(.06,.05,.028,.42)
    local fs=MakeText(b,"GameFontHighlightSmall"); fs:SetPoint("LEFT",6,0); fs:SetPoint("RIGHT",-6,0); fs:SetText(text); b.text=fs
    b:SetScript("OnClick",function(self,button) if button=="RightButton" and onRight then onRight() elseif onClick then onClick() end end)
    b:SetScript("OnEnter",function(self) bg:SetVertexColor(.18,.12,.035,.76); self.text:SetTextColor(1,.82,.25) end)
    b:SetScript("OnLeave",function(self) bg:SetVertexColor(.06,.05,.028,.42); self.text:SetTextColor(1,1,1) end)
    return b
end

local function ItemRow(parent,y,item,text,onClick,onRight,rightLabel,rightClick,rightWidth)
    local b=CreateFrame("Button",nil,parent)
    b:SetHeight(28); b:SetPoint("TOPLEFT",6,y); b:SetPoint("RIGHT",-6,0)
    b:RegisterForClicks("LeftButtonUp","RightButtonUp")

    local bg=b:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); bg:SetTexture("Interface\\Buttons\\WHITE8X8"); bg:SetVertexColor(.06,.05,.028,.48)
    local accent=b:CreateTexture(nil,"ARTWORK"); accent:SetTexture("Interface\\Buttons\\WHITE8X8"); accent:SetVertexColor(.67,.43,.10,.58); accent:SetWidth(2); accent:SetPoint("TOPLEFT",0,0); accent:SetPoint("BOTTOMLEFT",0,0)

    local icon=b:CreateTexture(nil,"ARTWORK")
    icon:SetSize(24,24); icon:SetPoint("LEFT",4,0); icon:SetTexture(ItemTexture(item))
    local iconBorder=b:CreateTexture(nil,"OVERLAY")
    iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2"); iconBorder:SetSize(28,28); iconBorder:SetPoint("CENTER",icon,"CENTER",0,0)

    local right
    local rightSpace=6
    if rightLabel and rightClick then
        local actionWidth=tonumber(rightWidth) or 96
        right=MakeButton(b,rightLabel,actionWidth,22)
        right:SetPoint("RIGHT",-3,0)
        right:SetScript("OnClick",function() rightClick() end)
        rightSpace=actionWidth+9
    end

    local fs=MakeText(b,"GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT",34,-3); fs:SetPoint("BOTTOMRIGHT",-rightSpace,3); fs:SetJustifyV("MIDDLE"); fs:SetText(text); b.text=fs
    if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(false) end

    b:SetScript("OnClick",function(self,button)
        if IsShiftKeyDown and IsShiftKeyDown() and button=="LeftButton" then
            InsertItemIntoChat(item)
            return
        end
        if button=="RightButton" and onRight then onRight()
        elseif onClick then onClick() end
    end)
    b:SetScript("OnEnter",function(self)
        bg:SetVertexColor(.19,.13,.035,.82); self.text:SetTextColor(1,.84,.28)
        ShowItemTooltip(self,item,"ANCHOR_RIGHT")
    end)
    b:SetScript("OnLeave",function(self)
        bg:SetVertexColor(.06,.05,.028,.48); self.text:SetTextColor(1,1,1)
        if GameTooltip then GameTooltip:Hide() end
    end)
    b.icon=icon; b.actionButton=right
    return b
end

local function CaptureView()
    return {
        page=UI.page,
        listPage=UI.listPage,
        radarFilter=UI.radarFilter,
        shredMode=UI.shredMode,
        coverageFilter=UI.coverageFilter,
        coverageSection=UI.coverageSection,
        positionSection=UI.positionSection,
        positionFilter=UI.positionFilter,
        chumFilter=UI.chumFilter,
        chumSelected=UI.chumSelected,
        crossFilter=UI.crossFilter,
        crossDetailKey=UI.crossDetailKey,
        reviewSelected=UI.reviewSelected,
        selectedItem=(UI.page=="market") and UI.selectedItem or nil,
    }
end

local function RestoreView(view)
    view=type(view)=="table" and view or {page="home"}
    UI.page=view.page or "home"
    UI.listPage=tonumber(view.listPage) or 1
    UI.radarFilter=view.radarFilter or UI.radarFilter or "ALL"
    UI.shredMode=view.shredMode or UI.shredMode or "opportunities"
    UI.coverageFilter=view.coverageFilter or UI.coverageFilter or "all"
    UI.coverageSection=view.coverageSection or "coverage"
    UI.positionSection=view.positionSection or "positions"
    UI.positionFilter=view.positionFilter or UI.positionFilter or "QUICK"
    UI.chumFilter=view.chumFilter or UI.chumFilter or "LEADS"
    UI.chumSelected=view.chumSelected
    UI.crossFilter=view.crossFilter or UI.crossFilter or "ALL"
    UI.crossDetailKey=view.crossDetailKey
    UI.reviewSelected=view.reviewSelected
    UI.selectedItem=view.selectedItem
    UI.detailParent=nil
    RenderPage()
end

NavigateRoot=function(page)
    page=page or "home"
    if page=="radar" then page="chum" end
    if page=="review" then page="coverage"; UI.coverageSection="review"; UI.reviewSelected=nil end
    if page=="shredder" or page=="prospecting" then page="position"; UI.positionSection="prospecting" end
    if page=="zippy" or page=="talk" or page=="profit" then page="home" end
    if UI.page=="testarena" and page~="testarena" then
        UI.testArenaSession=nil
        UI.testArenaReturnView=nil
    end
    UI.page=page
    UI.listPage=1
    UI.detailParent=nil
    UI.selectedItem=nil
    if page=="cross" then UI.crossDetailKey=nil end
    if page=="chum" then UI.chumFilter=UI.chumFilter or "LEADS" end
    RenderPage()
end

local function ShowMarketItem(itemString)
    if not itemString then return end
    -- Preserve exactly where the user came from. Escape from the item detail can
    -- then return to the same Cost Coverage filter, Radar page, Shredder mode,
    -- Watchlist page, etc., instead of forcing a trip through Home.
    if not (UI.page=="market" and UI.selectedItem and UI.detailParent) then
        UI.detailParent=CaptureView()
    end
    UI.selectedItem=itemString
    UI.page="market"
    RenderPage()
end


HandleEscape=function()
    if _G.UBKSourceGuideFrame and _G.UBKSourceGuideFrame:IsShown() and (not _G.UBKWindowFocus or _G.UBKWindowFocus.IsSelected(_G.UBKSourceGuideFrame)) then _G.UBKSourceGuideFrame:Hide(); return end
    if UI.resolveConfirmDialog and UI.resolveConfirmDialog.IsShown and UI.resolveConfirmDialog:IsShown() then
        UI.resolveConfirmDialog:Hide()
        return
    end
    if UI.resolveDialog and UI.resolveDialog.IsShown and UI.resolveDialog:IsShown() then
        UI.resolveDialog:Hide()
        return
    end
    if UI.page=="testarena" then LeaveTestArena(); return end
    if UI.page=="market" and UI.selectedItem then
        local parent=UI.detailParent
        if parent then
            RestoreView(parent)
        else
            UI.selectedItem=nil
            UI.listPage=1
            RenderPage()
        end
        return
    end
    if UI.page=="coverage" and UI.coverageSection=="review" and UI.reviewSelected then
        UI.reviewSelected=nil
        RenderPage()
        return
    end
    if UI.page=="coverage" and UI.coverageSection=="review" then
        UI.coverageSection="coverage"
        UI.listPage=1
        RenderPage()
        return
    end
    if UI.page=="position" and UI.positionSection and UI.positionSection~="positions" then
        UI.positionSection="positions"
        UI.listPage=1
        RenderPage()
        return
    end
    if UI.page~="home" then
        NavigateRoot("home")
        return
    end
    if UI.root then UI.root:Hide() end
end


local function CreateResolveConfirmDialog()
    if UI.resolveConfirmDialog then return UI.resolveConfirmDialog end
    local template=BackdropTemplateMixin and "BackdropTemplate" or nil
    local d=CreateFrame("Frame","UBKInterfaceResolveConfirmDialog",UI.root or UIParent,template)
    RegisterSpecialFrame("UBKInterfaceResolveConfirmDialog")
    d:SetSize(570,390); d:SetPoint("CENTER",UI.root or UIParent,"CENTER",0,0)
    d:SetFrameStrata("HIGH"); d:SetFrameLevel((UI.root and UI.root:GetFrameLevel() or 1)+30)
    if _G.UBKWindowFocus then _G.UBKWindowFocus.Register(d) end
    d:EnableMouse(true); d:SetMovable(true); d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart",function(self) self:StartMoving() end)
    d:SetScript("OnDragStop",function(self) self:StopMovingOrSizing() end)
    if d.SetBackdrop then
        d:SetBackdrop({
            bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=24,edgeSize=24,
            insets={left=7,right=7,top=7,bottom=7}
        })
        d:SetBackdropColor(.025,.018,.010,.995)
        d:SetBackdropBorderColor(.82,.53,.14,1)
    end

    local title=MakeText(d,"GameFontNormalLarge")
    title:SetPoint("TOPLEFT",22,-18); title:SetText("Confirm Cost Resolution")
    title:SetTextColor(1,.80,.24)

    local close=CreateFrame("Button",nil,d,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-6,-6)
    close:SetScript("OnClick",function() d:Hide() end)

    local iconButton=CreateFrame("Button",nil,d)
    iconButton:SetSize(46,46); iconButton:SetPoint("TOPLEFT",24,-53)
    iconButton:RegisterForClicks("LeftButtonUp")
    local icon=iconButton:CreateTexture(nil,"ARTWORK"); icon:SetAllPoints(); iconButton.icon=icon; d.icon=icon
    iconButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    iconButton:SetScript("OnEnter",function(self) if d.itemString then ShowItemTooltip(self,d.itemString,"ANCHOR_RIGHT") end end)
    iconButton:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    iconButton:SetScript("OnClick",function() if d.itemString and IsShiftKeyDown and IsShiftKeyDown() then InsertItemIntoChat(d.itemString) end end)

    local itemName=MakeText(d,"GameFontNormal")
    itemName:SetPoint("TOPLEFT",82,-56); itemName:SetPoint("RIGHT",-26,0); itemName:SetTextColor(1,.82,.25); d.itemNameText=itemName
    local qtyText=MakeText(d,"GameFontHighlight")
    qtyText:SetPoint("TOPLEFT",82,-80); qtyText:SetPoint("RIGHT",-26,0); d.qtyText=qtyText

    local question=MakeText(d,"GameFontHighlight")
    question:SetPoint("TOPLEFT",24,-118); question:SetWidth(522)
    if question.SetWordWrap then question:SetWordWrap(true) end
    question:SetJustifyH("LEFT"); d.question=question

    local basis=MakeText(d,"GameFontNormal")
    basis:SetPoint("TOPLEFT",question,"BOTTOMLEFT",0,-16); basis:SetWidth(522)
    if basis.SetWordWrap then basis:SetWordWrap(true) end
    basis:SetJustifyH("LEFT"); basis:SetTextColor(1,.82,.25); d.basisText=basis

    local caution=MakeText(d,"GameFontHighlightSmall")
    caution:SetPoint("TOPLEFT",basis,"BOTTOMLEFT",0,-16); caution:SetWidth(522)
    if caution.SetWordWrap then caution:SetWordWrap(true) end
    caution:SetJustifyH("LEFT")
    caution:SetText("Only the unresolved units are being changed. Units whose acquisition cost is already known keep their existing history and cost.")
    d.caution=caution

    local status=MakeText(d,"GameFontHighlightSmall")
    status:SetPoint("TOPLEFT",caution,"BOTTOMLEFT",0,-12); status:SetWidth(522); status:SetTextColor(1,.35,.25); d.status=status
    if status.SetWordWrap then status:SetWordWrap(true) end

    local cancel=MakeButton(d,"Cancel",82,24); cancel:SetPoint("BOTTOMRIGHT",-22,20)
    cancel:SetScript("OnClick",function() d:Hide() end)
    local back=MakeButton(d,"Back",72,24); back:SetPoint("RIGHT",cancel,"LEFT",-8,0)
    back:SetScript("OnClick",function()
        d:Hide()
        if UI.resolveDialog then UI.resolveDialog:Show(); UI.resolveDialog.edit:SetFocus() end
    end)
    local confirm=MakeButton(d,"Confirm Resolve",126,24); confirm:SetPoint("RIGHT",back,"LEFT",-8,0); d.confirmButton=confirm

    local function LayoutDialog()
        local qh=math.max(28,tonumber(question.GetStringHeight and question:GetStringHeight()) or 28)
        local bh=math.max(34,tonumber(basis.GetStringHeight and basis:GetStringHeight()) or 34)
        local ch=math.max(30,tonumber(caution.GetStringHeight and caution:GetStringHeight()) or 30)
        question:SetHeight(qh); basis:SetHeight(bh); caution:SetHeight(ch)
        local wanted=118+qh+16+bh+16+ch+12+34+18+24+22
        d:SetHeight(math.max(360,math.min(520,wanted)))
    end

    local function RefreshFromPreview(preview,priceText)
        d.itemString=preview.itemString
        d.prospecting=preview.prospecting==true;d.resolutionToken=preview.resolutionToken
        d.priceText=priceText
        d.expectedUnresolved=tonumber(preview.unresolvedQty) or 0
        d.expectedKnown=tonumber(preview.knownQty) or 0
        d.expectedCurrentBasis=tonumber(preview.currentBasis) or 0
        d.expectedProjectedBasis=tonumber(preview.projectedBasis) or 0
        d.itemNameText:SetText(preview.name or ItemName(d.itemString)); d.itemNameText:SetTextColor(_G.UBKItemRules.QualityColor(d.itemString))
        d.icon:SetTexture(ItemTexture(d.itemString))
        local uq=d.expectedUnresolved
        local kw=d.expectedKnown
        local owned=tonumber(preview.observedQty) or (uq+kw)
        d.qtyText:SetText(string.format("%d unresolved  •  %d known  •  %d owned",uq,kw,owned))
        d.question:SetText(string.format(
            "Are you sure you want to resolve %d unknown unit%s at %s per unit?",
            uq,uq==1 and "" or "s",Money(preview.enteredUnitPrice)))
        local itemNameText=preview.name or ItemName(d.itemString)
        if d.expectedCurrentBasis>0 then
            d.basisText:SetText(string.format(
                "If you confirm, %s's UBK basis will change from %s to approximately %s per unit.",
                itemNameText,Money(d.expectedCurrentBasis),Money(d.expectedProjectedBasis)))
        else
            d.basisText:SetText(string.format(
                "If you confirm, UBK will establish an approximate %s per-unit basis for %s.",
                Money(d.expectedProjectedBasis),itemNameText))
        end
        if d.prospecting then
            d.qtyText:SetText(string.format("%d unknown consumed ore  •  %d unknown remaining ore",preview.pendingInputQty,preview.stockUnresolvedQty))
            d.basisText:SetText("Consumed ore cost goes to its saved prospecting session. Remaining unknown ore joins its existing cost pool. Completed sessions settle after reload.")
        end
        d.status:SetText("")
        LayoutDialog()
    end
    d.RefreshFromPreview=RefreshFromPreview

    confirm:SetScript("OnClick",function()
        if not d.itemString or not d.priceText then return end
        local previewMethod=d.prospecting and API.PreviewProspectingOreCost or API.PreviewResolveUnresolved
        local ok,latest=previewMethod(API,d.itemString,d.priceText)
        if not ok then
            d.status:SetText(type(latest)=="string" and latest or "UBK could not re-check this resolution.")
            LayoutDialog()
            return
        end
        local latestUnresolved=tonumber(latest.unresolvedQty) or 0
        local latestKnown=tonumber(latest.knownQty) or 0
        local latestCurrent=tonumber(latest.currentBasis) or 0
        local latestProjected=tonumber(latest.projectedBasis) or 0
        local changed = (d.prospecting and latest.resolutionToken~=d.resolutionToken) or latestUnresolved~=d.expectedUnresolved or latestKnown~=d.expectedKnown
            or math.abs(latestCurrent-d.expectedCurrentBasis)>0.5 or math.abs(latestProjected-d.expectedProjectedBasis)>0.5
        if changed then
            RefreshFromPreview(latest,d.priceText)
            d.status:SetText("Your inventory or basis changed while this confirmation was open. Review the updated numbers, then confirm again.")
            LayoutDialog()
            return
        end
        local resolveMethod=d.prospecting and API.ResolveProspectingOreCost or API.ResolveUnresolved
        local resolved,result=resolveMethod(API,d.itemString,d.priceText,d.resolutionToken)
        if not resolved then
            d.status:SetText(type(result)=="string" and result or "UBK could not resolve these units.")
            LayoutDialog()
            return
        end
        local returnView=d.returnView
        d:Hide()
        if UI.resolveDialog then UI.resolveDialog:Hide() end
        if returnView then RestoreView(returnView) else RenderPage() end
    end)

    d:Hide()
    UI.resolveConfirmDialog=d
    return d
end

local function ShowResolveConfirmation(preview,priceText)
    local d=CreateResolveConfirmDialog()
    d.returnView=UI.resolveDialog and UI.resolveDialog.returnView or CaptureView()
    d.RefreshFromPreview(preview,priceText)
    if UI.resolveDialog then UI.resolveDialog:Hide() end
    d:Show()
end

local function CreateResolveUnknownDialog()
    if UI.resolveDialog then return UI.resolveDialog end
    local template=BackdropTemplateMixin and "BackdropTemplate" or nil
    local d=CreateFrame("Frame","UBKInterfaceResolveUnknownDialog",UI.root or UIParent,template)
    RegisterSpecialFrame("UBKInterfaceResolveUnknownDialog")
    d:SetSize(570,400); d:SetPoint("CENTER",UI.root or UIParent,"CENTER",0,0)
    d:SetFrameStrata("HIGH"); d:SetFrameLevel((UI.root and UI.root:GetFrameLevel() or 1)+20)
    if _G.UBKWindowFocus then _G.UBKWindowFocus.Register(d) end
    d:EnableMouse(true); d:SetMovable(true); d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart",function(self) self:StartMoving() end)
    d:SetScript("OnDragStop",function(self) self:StopMovingOrSizing() end)
    if d.SetBackdrop then
        d:SetBackdrop({
            bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=24,edgeSize=24,
            insets={left=7,right=7,top=7,bottom=7}
        })
        d:SetBackdropColor(.025,.018,.010,.99)
        d:SetBackdropBorderColor(.72,.47,.12,1)
    end

    local title=MakeText(d,"GameFontNormalLarge")
    title:SetPoint("TOPLEFT",22,-18); title:SetText("Resolve Unknown Cost")
    title:SetTextColor(1,.80,.24)

    local close=CreateFrame("Button",nil,d,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-6,-6)

    local iconButton=CreateFrame("Button",nil,d)
    iconButton:SetSize(46,46); iconButton:SetPoint("TOPLEFT",24,-53)
    iconButton:RegisterForClicks("LeftButtonUp")
    local icon=iconButton:CreateTexture(nil,"ARTWORK"); icon:SetAllPoints(); iconButton.icon=icon; d.icon=icon
    iconButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    iconButton:SetScript("OnEnter",function(self) if d.itemString then ShowItemTooltip(self,d.itemString,"ANCHOR_RIGHT") end end)
    iconButton:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    iconButton:SetScript("OnClick",function() if d.itemString and IsShiftKeyDown and IsShiftKeyDown() then InsertItemIntoChat(d.itemString) end end)

    local itemName=MakeText(d,"GameFontNormal")
    itemName:SetPoint("TOPLEFT",82,-56); itemName:SetPoint("RIGHT",-26,0); itemName:SetTextColor(1,.82,.25); d.itemNameText=itemName
    local qtyText=MakeText(d,"GameFontHighlight")
    qtyText:SetPoint("TOPLEFT",82,-80); qtyText:SetPoint("RIGHT",-26,0); d.qtyText=qtyText

    local explain=MakeText(d,"GameFontHighlightSmall")
    explain:SetPoint("TOPLEFT",24,-116); explain:SetWidth(522)
    if explain.SetWordWrap then explain:SetWordWrap(true) end
    explain:SetJustifyH("LEFT"); d.explain=explain

    local prompt=MakeText(d,"GameFontNormalSmall")
    prompt:SetPoint("TOPLEFT",explain,"BOTTOMLEFT",0,-18)
    prompt:SetText("Resolve each unresolved unit at:")
    prompt:SetTextColor(1,.80,.24); d.prompt=prompt

    local edit=CreateFrame("EditBox",nil,d,"InputBoxTemplate")
    edit:SetSize(165,26); edit:SetPoint("TOPLEFT",prompt,"BOTTOMLEFT",3,-8); edit:SetAutoFocus(false); d.edit=edit
    local hint=MakeText(d,"GameFontDisableSmall")
    hint:SetPoint("LEFT",edit,"RIGHT",12,0); hint:SetText("Examples: 15g70s   85s5c")

    local status=MakeText(d,"GameFontHighlightSmall")
    status:SetPoint("TOPLEFT",edit,"BOTTOMLEFT",-3,-14); status:SetWidth(522); status:SetTextColor(1,.35,.25); d.status=status
    if status.SetWordWrap then status:SetWordWrap(true) end

    local cancel=MakeButton(d,"Cancel",82,24); cancel:SetPoint("BOTTOMRIGHT",-22,20)
    cancel:SetScript("OnClick",function() d:Hide() end)
    local review=MakeButton(d,"Review",92,24); review:SetPoint("RIGHT",cancel,"LEFT",-8,0); d.resolveButton=review

    local function LayoutDialog()
        local eh=math.max(72,tonumber(explain.GetStringHeight and explain:GetStringHeight()) or 72)
        local sh=math.max(22,tonumber(status.GetStringHeight and status:GetStringHeight()) or 22)
        explain:SetHeight(eh); status:SetHeight(sh)
        local wanted=116+eh+18+16+8+26+14+sh+18+24+22
        d:SetHeight(math.max(370,math.min(540,wanted)))
    end
    d.Layout=LayoutDialog

    local function ReviewResolve()
        if not d.itemString then return end
        local price=(d.edit and d.edit:GetText()) or ""
        if price:match("^%s*$") then
            d.status:SetText("Enter a positive per-unit cost first.")
            LayoutDialog()
            return
        end
        local previewMethod=d.prospecting and API.PreviewProspectingOreCost or API.PreviewResolveUnresolved
        local ok,preview=previewMethod(API,d.itemString,price)
        if not ok then
            d.status:SetText(type(preview)=="string" and preview or "UBK could not preview this resolution.")
            LayoutDialog()
            return
        end
        ShowResolveConfirmation(preview,price)
    end
    review:SetScript("OnClick",ReviewResolve)
    edit:SetScript("OnEnterPressed",function(self) self:ClearFocus(); ReviewResolve() end)
    edit:SetScript("OnEscapePressed",function(self) self:ClearFocus(); d:Hide() end)
    d:Hide()
    UI.resolveDialog=d
    return d
end

local function ShowResolveUnknownDialog(itemString,prospecting)
    local sessions=_G.UBKProspectingSessions
    if not prospecting and sessions and sessions:Pending(itemString) then
        local ore=sessions:SourceOre(itemString)
        if ore then sessions:PromptOre(ore) else print("|cffffcc00UBK:|r Prospecting evidence is incomplete; this output stays blocked.") end
        return
    end
    if GameTooltip then GameTooltip:Hide() end
    local b=API:GetBasisInfo(itemString)
    if not prospecting and (not b or (tonumber(b.unresolvedQty) or 0)<=0) then
        print("|cffff7777Universal Basis Keeper:|r that item no longer has unresolved inventory.")
        RenderPage()
        return
    end
    b=b or {itemString=itemString}
    local d=CreateResolveUnknownDialog()
    d.prospecting=prospecting==true
    d.prompt:SetText(prospecting and "Tell me the ore's basis (per ore):" or "Resolve each unresolved unit at:")
    d.returnView=CaptureView()
    local unresolved=tonumber(b.unresolvedQty) or 0
    local known=tonumber(b.knownQty) or 0
    local owned=tonumber(b.observedQty) or (known+unresolved)
    local unitWord=unresolved==1 and "unit" or "units"
    d.itemString=b.itemString or itemString
    d.itemNameText:SetText(b.name or ItemName(d.itemString)); d.itemNameText:SetTextColor(_G.UBKItemRules.QualityColor(d.itemString))
    d.qtyText:SetText(string.format("%d unresolved %s  •  %d known  •  %d owned",unresolved,unitWord,known,owned))
    d.explain:SetText(string.format(
        "UBK already has a trusted cost for part of this inventory, but %d %s still have no known acquisition cost. Those unresolved items are excluded from your current basis rather than treated as free. If you know their cost, enter the per-unit amount below. UBK will apply it only to those %d unresolved %s and blend them with the known-cost inventory; it will not rebase the %d known unit%s. You'll review the projected new basis before anything changes.",
        unresolved,unitWord,unresolved,unitWord,known,known==1 and "" or "s"))
    if prospecting then
        local consumed=sessions and sessions:UnknownInput(itemString) or 0
        d.qtyText:SetText(string.format("%d unknown consumed ore  •  %d unknown remaining ore",consumed,unresolved))
        d.explain:SetText("Tell UBK what this ore cost per unit. Purchase records and captured buyer-mail invoices are checked first. Your entry resolves remaining unknown ore and the unknown inputs of saved prospects; existing known costs are preserved. Gems stay pending until the session is settled after reload. Review the exact quantities before confirming.")
    end
    d.icon:SetTexture(ItemTexture(d.itemString))
    d.edit:SetText(""); d.status:SetText("")
    if d.Layout then d.Layout() end
    d:Show(); d.edit:SetFocus()
end

local function InvalidateChumCache()
    local scanners=ScannerModule()
    if scanners and type(scanners.Invalidate)=="function" then scanners:Invalidate() end
end

local function ChumScannerRows(force)
    local scanners=ScannerModule()
    if not scanners or type(scanners.GetRows)~="function" then return {} end
    local ok,rows=pcall(scanners.GetRows,scanners,force==true)
    return ok and type(rows)=="table" and rows or {}
end

local function ChumRowByItem(rows,itemString)
    for _,row in ipairs(rows or {}) do if row.itemString==itemString then return row end end
    return nil
end

local function ChumStatusColor(status)
    local scanners=ScannerModule()
    if scanners and type(scanners.GetStatusColor)=="function" then return scanners:GetStatusColor(status) end
    return "|cffaaaaaa"
end

local function ChumIsLeadStatus(status)
    local scanners=ScannerModule()
    return scanners and type(scanners.IsLeadStatus)=="function" and scanners:IsLeadStatus(status) or false
end

local function RenderChumScanner()
    PageTitle("Chum Scanner","UBK Scanners reads completed TSM/AppHelper data against trusted UBK basis. A lead is not a buy; exact book evidence only upgrades the shape when it already exists.")
    local rows=ChumScannerRows(false)
    local eb=CreateFrame("EditBox",nil,UI.content,"InputBoxTemplate"); eb:SetSize(244,26); eb:SetPoint("TOPLEFT",8,-58); eb:SetAutoFocus(false); eb:SetText(UI.chumSelected and ItemName(UI.chumSelected) or "")
    UI.chumEditBox=eb
    local inspect=MakeButton(UI.content,"Select",66,24); inspect:SetPoint("LEFT",eb,"RIGHT",7,0)
    inspect:SetScript("OnClick",function()
        local item=Resolve(eb:GetText())
        local basis=item and API.GetBasisInfo and API:GetBasisInfo(item) or nil
        if item and basis and tonumber(basis.basis) and tonumber(basis.basis)>0 then UI.chumSelected=item; UI.listPage=1; InvalidateChumCache(); RenderPage()
        elseif item then UI.chumStatus="UBK has no positive witnessed basis for that item, so Chum Scanner will not value it from database ghosts."; RenderPage()
        else UI.chumStatus="Couldn't resolve that item. Use an item link, item ID, or exact known name."; RenderPage() end
    end)
    local refresh=MakeButton(UI.content,"Read Loaded Scan",126,24); refresh:SetPoint("LEFT",inspect,"RIGHT",7,0)
    refresh:SetScript("OnClick",function() InvalidateChumCache(); UI.chumStatus="Re-read the completed TSM/AppHelper data. No Auction House query was sent."; RenderPage() end)
    AddButtonTooltip(refresh,"Read Loaded Scan","Rebuild every Chum lead from the TSM/AppHelper and AuctionDB data already loaded in this WoW session.","This is available away from the Auction House and never sends an auction query.")

    rows=ChumScannerRows(false)
    local selected=ChumRowByItem(rows,UI.chumSelected)
    local block=MakeButton(UI.content,selected and selected.blocked and "Allow Add" or "Block Add",86,24); block:SetPoint("LEFT",refresh,"RIGHT",7,0); block:SetEnabled(selected~=nil)
    block:SetScript("OnClick",function()
        if not selected then return end
        local scanners=ScannerModule()
        if not scanners or type(scanners.SetBlocked)~="function" then UI.chumStatus="UBK Scanners is unavailable; the exposure guard was not changed."; RenderPage(); return end
        local newBlocked=not selected.blocked
        local ok=select(1,scanners:SetBlocked(selected.itemString,newBlocked))
        if ok and newBlocked then UI.chumStatus="Marked "..selected.name.." BLOCKED / WATCH ONLY."
        elseif ok then UI.chumStatus="Removed the manual NO ADD block from "..selected.name.."."
        else UI.chumStatus="UBK Scanners could not change that exposure guard." end
        InvalidateChumCache(); RenderPage()
    end)
    AddButtonTooltip(block,"Manual exposure guard","Mark the selected market BLOCKED / WATCH ONLY, or remove that manual guard.","The guard changes Chum Scanner advice only; it does not alter UBK basis, TSM operations, or any auction.")
    local tsm=MakeButton(UI.content,"Search TSM",88,24); tsm:SetPoint("LEFT",block,"RIGHT",7,0); tsm:SetEnabled(selected~=nil)
    tsm:SetScript("OnClick",function() if selected then API:OpenInTSM({itemString=selected.itemString,itemName=selected.name}) end end)
    AddButtonTooltip(tsm,"Search selected item in TSM","Perform the existing player-clicked exact-item handoff to TSM Browse.","Open the Auction House and TSM Browse when you want this optional live follow-up.")

    local exact=MakeButton(UI.content,"Exact Check",88,24); exact:SetPoint("LEFT",tsm,"RIGHT",7,0)
    local auctionOpen=API.IsAuctionVisible and API:IsAuctionVisible()
    local shredState=API.GetShredderState and API:GetShredderState() or {}
    exact:SetEnabled(selected~=nil and auctionOpen and not shredState.liveScanning)
    if shredState.liveScanning then exact:SetText("Checking…") end
    exact:SetScript("OnClick",function()
        if not selected or not API.StartShredderLiveStockRefresh then return end
        local okStart,err=API:StartShredderLiveStockRefresh({selected.itemString})
        UI.chumStatus=okStart and ("Optional exact-book check started for "..selected.name..".") or ("Exact check did not start: "..tostring(err or "unknown reason"))
        RenderPage()
    end)
    AddButtonTooltip(exact,"Optional exact-book check","When you are at the Auction House, inspect the selected item's front tail and shelf depth.","Chum Scanner itself already works from the completed loaded scan; this optional check never buys, posts, cancels, or bids.")

    local summary=MakeText(UI.content,"GameFontHighlightSmall"); summary:SetPoint("TOPLEFT",8,-94); summary:SetPoint("RIGHT",-8,0); summary:SetHeight(48)
    if selected then
        local low=selected.liveFresh and selected.live and tonumber(selected.live.low) or selected.loadedLow
        local ratio=low and selected.basis>0 and low/selected.basis or nil
        local source=selected.liveFresh and selected.live and ((tonumber(selected.live.updatedAt) or tonumber(selected.live.seenAt)) and (selected.live.evidenceSource.." • "..Age(tonumber(selected.live.updatedAt) or tonumber(selected.live.seenAt))) or selected.live.evidenceSource) or "loaded scan"
        summary:SetText(string.format("%s%s|r  %s   •   low %s / basis %s (%s)   •   exposure %s   •   %s\n%s",ChumStatusColor(selected.status),selected.status,selected.name,low and Money(low) or "—",Money(selected.basis),ratio and Pct(ratio) or "—",selected.risk,source,selected.reason))
    else
        local leads=0 for _,row in ipairs(rows) do if ChumIsLeadStatus(row.status) then leads=leads+1 end end
        summary:SetText(string.format("%d UBK-basis market%s read from completed data • %d trusted lead%s. Select a row for the evidence sentence and exposure guard.",#rows,#rows==1 and "" or "s",leads,leads==1 and "" or "s"))
    end

    local filters={{"LEADS","Leads"},{"ALL","All Basis"},{"BLOCKED","Blocked"}}
    local x=8
    for _,spec in ipairs(filters) do
        local b=MakeButton(UI.content,spec[2],86,21); b:SetPoint("TOPLEFT",x,-151); x=x+92
        if UI.chumFilter==spec[1] then b:Disable() end
        b:SetScript("OnClick",function() UI.chumFilter=spec[1]; UI.listPage=1; RenderPage() end)
    end
    local status=MakeText(UI.content,"GameFontDisableSmall"); status:SetPoint("TOPLEFT",292,-155); status:SetPoint("RIGHT",-8,0); status:SetText(UI.chumStatus or "Right-click a row to add it to Watchlist. Loaded-data leads remain honest about missing book depth.")

    local visible={}
    for _,row in ipairs(rows) do
        local lead=ChumIsLeadStatus(row.status)
        if UI.chumFilter=="ALL" or (UI.chumFilter=="BLOCKED" and row.blocked) or (UI.chumFilter=="LEADS" and lead) then visible[#visible+1]=row end
    end
    local perPage=RowsFor(181,44); local start=(UI.listPage-1)*perPage+1
    for i=start,math.min(#visible,start+perPage-1) do
        local row=visible[i]
        local low=row.liveFresh and row.live and tonumber(row.live.low) or row.loadedLow
        local ratio=low and row.basis>0 and low/row.basis or nil
        local color=ChumStatusColor(row.status)
        local txt=string.format("%s%-15s|r  %-22s  low %8s  basis %8s  %7s  %s",color,row.status,row.name,low and Money(low) or "—",Money(row.basis),ratio and Pct(ratio) or "—",row.risk)
        ItemRow(UI.content,-181-(i-start)*30,row.itemString,txt,function() UI.chumSelected=row.itemString; RenderPage() end,function() AddWatch(row.itemString) end,"TSM",function() API:OpenInTSM({itemString=row.itemString,itemName=row.name}) end,58)
    end
    if #visible==0 then local empty=MakeText(UI.content); empty:SetPoint("TOPLEFT",8,-188); empty:SetText(UI.chumFilter=="LEADS" and "No bait-shaped leads in the completed loaded scan. All Basis still shows the full trusted-basis set." or "No markets match this filter.") end
    AddPager(#visible,perPage)
end

local function MarketLinkCaptureActive()
    -- An open chat draft has priority over any lingering Inspector field focus.
    if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return false end
    local eb=UI.marketEditBox
    return UI.root and UI.root:IsShown() and UI.page=="market" and eb and eb.HasFocus and eb:HasFocus()
end

local function CaptureMarketItemLink(link)
    if not MarketLinkCaptureActive() or type(link)~="string" then return false end
    if not link:find("|Hitem:",1,true) then return false end
    local item=Resolve(link)
    if not item then return false end
    UI.selectedItem=item
    if UI.marketEditBox and UI.marketEditBox.SetText then UI.marketEditBox:SetText(link) end
    -- Defer the redraw until the modified-click handler has unwound. This keeps the
    -- Blizzard/TSM click stack untouched while still making inspection feel instant.
    if C_Timer and C_Timer.After then
        C_Timer.After(0,function()
            if UI.root and UI.root:IsShown() and UI.page=="market" then RenderPage() end
        end)
    else
        RenderPage()
    end
    return true
end

local function InstallMarketLinkCapture()
    if UI.marketLinkCaptureInstalled then return end
    UI.marketLinkCaptureInstalled=true

    -- Bag/item buttons normally enter through HandleModifiedItemClick. Put UBK first
    -- only while its Market Inspector field has focus, then leave every other click
    -- completely untouched for TSM, chat, dress-up, etc.
    if type(_G.HandleModifiedItemClick)=="function" then
        local originalHandleModifiedItemClick=_G.HandleModifiedItemClick
        _G.HandleModifiedItemClick=function(link,...)
            if IsShiftKeyDown and IsShiftKeyDown() and CaptureMarketItemLink(link) then return true end
            return originalHandleModifiedItemClick(link,...)
        end
    end

    -- Some TSM tables route Shift-click through its own item helper and then call
    -- SetItemRef directly. Catch that path too so a TSM result can be inspected in UBK.
    if type(_G.SetItemRef)=="function" then
        local originalSetItemRef=_G.SetItemRef
        _G.SetItemRef=function(link,text,button,...)
            local candidate=(type(text)=="string" and text~="") and text or link
            if IsShiftKeyDown and IsShiftKeyDown() and CaptureMarketItemLink(candidate) then return end
            return originalSetItemRef(link,text,button,...)
        end
    end

    -- Keep compatibility with addons / Blizzard paths which insert links through the
    -- chat-link helper instead of HandleModifiedItemClick.
    if type(_G.ChatEdit_InsertLink)=="function" then
        local originalChatEditInsertLink=_G.ChatEdit_InsertLink
        _G.ChatEdit_InsertLink=function(link,...)
            if IsShiftKeyDown and IsShiftKeyDown() and CaptureMarketItemLink(link) then return true end
            return originalChatEditInsertLink(link,...)
        end
    end
end

local function RenderMarket()
    PageTitle("Market Inspector","Inspect UBK basis beside TSM market context. Hover the item for its full tooltip; Shift-click the icon or name to link it in chat.")
    local eb=CreateFrame("EditBox",nil,UI.content,"InputBoxTemplate"); eb:SetSize(310,28); eb:SetPoint("TOPLEFT",8,-58); eb:SetAutoFocus(false); eb:SetText(UI.selectedItem and ItemName(UI.selectedItem) or "")
    UI.marketEditBox=eb
    -- Click the field first, then Shift-click an item in bags or TSM to inspect it.
    -- UBK captures links only while this exact field has focus.
    eb:HookScript("OnMouseDown",function(self) self:SetFocus() end)
    eb:HookScript("OnEscapePressed",function(self) self:ClearFocus() end)
    local inspect=MakeButton(UI.content,"Inspect",90,24); inspect:SetPoint("LEFT",eb,"RIGHT",8,0)
    inspect:SetScript("OnClick",function()
        local item=Resolve(eb:GetText())
        if item then
            if not UI.selectedItem then UI.detailParent=CaptureView() end
            UI.selectedItem=item
            RenderPage()
        else
            print("|cffff7777Universal Basis Keeper:|r couldn't resolve that item. Use an item link, item ID, or exact known name.")
        end
    end)
    local item=UI.selectedItem
    local ctx={UI=UI,API=API,MakeText=MakeText,MakeButton=MakeButton,Money=Money,Age=Age,RenderPage=RenderPage,AddButtonTooltip=AddButtonTooltip}
    local materialPlan=item and _G.UBKMaterialScan.SelectPlan(ctx,item)
    local prospect=item and API.GetProspectingInfo and API:GetProspectingInfo(item)
    local scan=MakeButton(UI.content,"Scan Now",100,24)
    scan:SetPoint("LEFT",inspect,"RIGHT",8,0); scan:SetEnabled(item~=nil)
    local scanState=API.GetShredderState and API:GetShredderState() or {}
    if scanState.liveScanning then scan:SetText("Scanning…"); scan:Disable() end
    scan:SetScript("OnClick",function()
        eb:ClearFocus()
        if not item then return end
        local ok,err=API:ScanMarketItem(item)
        if not ok then print("|cffffcc00UBK:|r "..tostring(err)) end
        RenderPage()
    end)
    AddButtonTooltip(scan,"Scan the inspected item","Searches the open Auction House for this exact item and updates the live minimum buyout and stock shown here. Finish other AH scans first.","Uses the inspected item even if you have typed another name without clicking Inspect. Live quotes stay separate from TSM's App snapshot and your acquisition basis. No auctions are bought or posted.")
    local mats=MakeButton(UI.content,"Scan Mats",92,24); mats:SetPoint("LEFT",scan,"RIGHT",8,0)
    mats:SetEnabled(materialPlan~=nil and not scanState.liveScanning)
    mats:SetScript("OnClick",function()
        eb:ClearFocus();if not materialPlan then return end
        UI.materialPaneItem=item
        local ok,err=API:ScanCraftingMaterials(item,materialPlan.recipeID)
        UI.materialError=not ok and err or nil;UI.materialErrorItem=item
        RenderPage()
    end)
    AddButtonTooltip(mats,"Scan recipe materials",materialPlan and "Quote the recorded recipe's AH reagents. Vendor supplies such as vials stay off the AH list; their vendor BUY quotes appear in the table." or "No recorded recipe. Open the relevant profession so TSM can learn it, then inspect again.","Quantities are for one craft. Shopping estimates never overwrite paid basis. Finish other AH scans first.")
    local browse=MakeButton(UI.content,"TSM Browse",106,24);browse:SetPoint("LEFT",mats,"RIGHT",8,0)
    browse:SetEnabled(item~=nil and not scanState.liveScanning)
    browse:SetScript("OnClick",function()
        eb:ClearFocus();if not item then return end
        local ok,err=API:BrowseMarketItem(item)
        if not ok then print("|cffffcc00UBK:|r "..tostring(err)) end
    end)
    AddButtonTooltip(browse,"Search this item in TSM Browse","Start TSM's exact-item search for the currently inspected item, not its materials. Open the Auction House and select TSM Browse first.","TSM handles the results and any purchases. Finish other scans first.")
    local quote=item and API.GetShredderLiveStock and API:GetShredderLiveStock(item)
    local scanStatus=MakeText(UI.content,"GameFontHighlightSmall")
    scanStatus:SetPoint("TOPLEFT",746,-56); scanStatus:SetPoint("RIGHT",-6,0); scanStatus:SetHeight(38)
    if scanState.liveScanning then
        scanStatus:SetText(scanState.liveStatus or "Scanning the Auction House…")
    elseif quote then
        local value=quote.low and Money(quote.low) or "No buyout listings"
        local stamp=type(date)=="function" and date("%H:%M:%S",quote.updatedAt or 0) or tostring(quote.updatedAt or "unknown")
        scanStatus:SetText("Live: "..value.." • "..tostring(quote.units or 0).." units\n"..stamp..(quote.complete and " • complete" or " • partial"))
    else scanStatus:SetText("Live AH quote: not scanned yet") end
    if not item then
        local h=MakeText(UI.content); h:SetPoint("TOPLEFT",8,-100); h:SetPoint("RIGHT",-8,0)
        h:SetText("Choose an item from Positions, Prospecting, Watchlist, or Cost Coverage, or enter one above. Shift-clicking an item into this field also opens its Inspector detail.")
        return
    end

    local intel=API:GetCachedIntelligence(item); local basis=intel and intel.basis; local m=intel and intel.market
    local deOutputs=(API.GetExpectedDisenchantOutputs and API:GetExpectedDisenchantOutputs(item)) or {}
    local isShredderItem=type(deOutputs)=="table" and #deOutputs>0

    -- A real item surface: one clean icon, normal item tooltip, and normal
    -- Shift-click-to-chat behavior. No decorative box around another box.
    local selectedButton=CreateFrame("Button",nil,UI.content)
    selectedButton:SetSize(44,44); selectedButton:SetPoint("TOPLEFT",8,-96); selectedButton:RegisterForClicks("LeftButtonUp")
    local selectedIcon=selectedButton:CreateTexture(nil,"ARTWORK"); selectedIcon:SetAllPoints(); selectedIcon:SetTexture(ItemTexture(item))
    selectedButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    selectedButton:SetScript("OnEnter",function(self) ShowItemTooltip(self,item,"ANCHOR_RIGHT") end)
    selectedButton:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    selectedButton:SetScript("OnClick",function() if IsShiftKeyDown and IsShiftKeyDown() then InsertItemIntoChat(item) end end)

    local nameButton=CreateFrame("Button",nil,UI.content)
    nameButton:SetHeight(24); nameButton:SetPoint("TOPLEFT",60,-100); nameButton:SetPoint("RIGHT",-290,0); nameButton:RegisterForClicks("LeftButtonUp")
    local title=MakeText(nameButton,"GameFontNormal")
    title:SetPoint("LEFT",0,0); title:SetPoint("RIGHT",0,0); title:SetText(ItemName(item)); title:SetTextColor(_G.UBKItemRules.QualityColor(item))
    nameButton:SetScript("OnEnter",function(self) ShowItemTooltip(self,item,"ANCHOR_RIGHT") end)
    nameButton:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    nameButton:SetScript("OnClick",function() if IsShiftKeyDown and IsShiftKeyDown() then InsertItemIntoChat(item) end end)

    local watch=MakeButton(UI.content,"Watch",72,22); watch:SetPoint("TOPRIGHT",-4,-99); watch:SetScript("OnClick",function() AddWatch(item); RenderPage() end)
    local liveButton=MakeButton(UI.content,"Update AH Stock",116,22); liveButton:SetPoint("RIGHT",watch,"LEFT",-8,0)
    local auctionOpen=API.IsAuctionVisible and API:IsAuctionVisible()
    local shredState=API.GetShredderState and API:GetShredderState() or {}
    liveButton:SetShown(isShredderItem)
    liveButton:SetEnabled(isShredderItem and auctionOpen and not shredState.liveScanning)
    if shredState.liveScanning then liveButton:SetText("Updating AH…") end
    liveButton:SetScript("OnClick",function()
        if not API.StartShredderLiveStockRefresh then return end
        local ok,err=API:StartShredderLiveStockRefresh({item})
        if not ok and err then print("|cffff7777Shredder:|r "..tostring(err)) end
        RenderPage()
    end)
    liveButton:SetScript("OnEnter",function(self)
        if GameTooltip then
            GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
            GameTooltip:AddLine("Update this item's AH stock",1,.82,0)
            GameTooltip:AddLine(auctionOpen and "Run a user-triggered exact AH check for this item and refresh Shredder's live-stock cache." or "Open the Auction House / TSM Auction UI to refresh live stock.",1,1,1,true)
            GameTooltip:Show()
        end
    end)
    liveButton:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)

    local basisLine=MakeText(UI.content,"GameFontHighlight")
    basisLine:SetPoint("TOPLEFT",12,-151); basisLine:SetPoint("RIGHT",-8,0); basisLine:SetHeight(22)
    basisLine:SetText(basis and basis.vendorTrash and ("Vendor trash: "..(basis.vendorSell and Money(basis.vendorSell) or "vendor quote not loaded").." vendor sell value each") or basis and ("UBK basis: "..(basis.basis and Money(basis.basis) or "none").."  •  "..tostring(basis.provenanceDisplay or basis.provenance)) or "UBK basis: no tracked state")
    local coverageLine=MakeText(UI.content,"GameFontHighlight")
    coverageLine:SetPoint("TOPLEFT",12,-182); coverageLine:SetPoint("RIGHT",-280,0); coverageLine:SetHeight(22)
    coverageLine:SetText(basis and basis.vendorTrash and "Cost coverage: vendor trash does not need acquisition-cost review" or basis and string.format("Cost coverage: %d known / %d owned; %d unresolved",basis.knownQty or 0,basis.observedQty or 0,basis.unresolvedQty or 0) or "Cost coverage: no tracked state")
    local resolve=MakeButton(UI.content,"Resolve Unknown",126,24)
    resolve:SetPoint("TOPRIGHT",-4,-178); resolve:SetEnabled(basis~=nil and (tonumber(basis.unresolvedQty) or 0)>0)
    if basis and basis.prospectingPending then
        resolve:SetText("Inspect Ore Cost");resolve:SetEnabled(true)
        coverageLine:SetText(basis.prospectingStatus or "Reload to settle prospecting basis")
    end
    resolve:SetScript("OnClick",function() ShowResolveUnknownDialog(item) end)
    AddButtonTooltip(resolve,"Resolve unknown units","Enter the actual per-unit cost of the unresolved units. The existing cost-resolution dialog opens over this Inspector, and the Inspector stays on this item.","Already costed units keep their acquisition history. Review the projected result before applying it.")
    local ownership=API.GetBasisPricingOwnershipInfo and API:GetBasisPricingOwnershipInfo(item)
    if ownership and (ownership.protected or ownership.canRestore) then
        local label=ownership.protected and "Use Basis Pricing" or "Restore Formula"
        local own=MakeButton(UI.content,label,128,24); own:SetPoint("RIGHT",resolve,"LEFT",-8,0)
        own:SetScript("OnClick",function()
            local ok,result
            if ownership.protected then ok,result=API:AdoptBasisPricing(item) else ok,result=API:RestoreBasisPricingOverride(item) end
            if not ok then print("|cffff7777UBK:|r "..tostring(result))
            elseif result.costPending then print("|cffffcc00UBK:|r Basis pricing selected. Cost stays unavailable until a recorded acquisition or vendor cost exists.")
            elseif result.reloadRecommended then print("|cff33ff99UBK:|r Material cost selected. /reload refreshes TSM's cached crafting displays.") end
            RenderPage()
        end)
        AddButtonTooltip(own,label,ownership.protected and "Replace the protected formula with UBK material pricing. Stock TSM receives the recorded material cost through UBK's normal write bridge; an available native integration stays native. The previous formula is saved for restoration." or "Restore the formula saved when you chose basis pricing. UBK pauses automatic material writes for this item so the restored formula stays in place.","This changes cost-source ownership only. It does not change inventory quantities, acquisition lots, or paid costs. Stock TSM may need /reload to refresh cached crafting displays.")
    end
    local integration=API.GetPricingIntegrationInfo and API:GetPricingIntegrationInfo(item)
    local detailTop=218
    local extraPane=(materialPlan and UI.materialPaneItem==item) or (prospect and UI.prospectPaneItem==item)
    if integration and not extraPane then
        local sourcePanel=CreateFrame("Frame",nil,UI.content); sourcePanel:SetPoint("TOPLEFT",12,-214); sourcePanel:SetPoint("RIGHT",-8,0); sourcePanel:SetHeight(61); sourcePanel:EnableMouse(true)
        local nativeParts,aliasParts={},{}
        for _,source in ipairs(integration.native or {}) do
            if source.available then nativeParts[#nativeParts+1]=source.key.." "..(source.value and Money(source.value) or "n/a") end
            if #(source.aliases or {})>0 then aliasParts[#aliasParts+1]=table.concat(source.aliases,", ").." → "..source.key end
        end
        local texts={
            integration.label..(#nativeParts>0 and (": "..table.concat(nativeParts," • ")) or ""),
            #aliasParts>0 and ("Configured aliases: "..table.concat(aliasParts,"; ")) or "Configured aliases: no UBK aliases in this TSM configuration",
            "Material source: "..(integration.materialExists and tostring(integration.materialOverride or integration.materialDefault or "TSM default") or "not a TSM material entry")
                .." • Evidence: "..(integration.acquisition and (integration.acquisition.source.." "..Money(integration.acquisition.value)) or "no recorded cost available"),
        }
        for index,text in ipairs(texts) do
            local line=MakeText(sourcePanel,index==1 and "GameFontHighlightSmall" or "GameFontDisableSmall")
            line:SetPoint("TOPLEFT",0,-(index-1)*20); line:SetPoint("RIGHT",0,0); line:SetHeight(18)
            if line.SetWordWrap then line:SetWordWrap(false) end; line:SetText(text)
        end
        sourcePanel:SetScript("OnEnter",function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:AddLine("UBK / TSM source chain",1,.82,0)
            for _,source in ipairs(integration.native or {}) do
                GameTooltip:AddLine(source.key..": "..(source.available and "registered" or "not registered").." • item value "..(source.value and Money(source.value) or "unavailable"),.8,.9,1,true)
            end
            GameTooltip:AddLine("This item's TSM material override: "..tostring(integration.materialOverride or "none"),1,1,1,true)
            GameTooltip:AddLine("Default material formula: "..tostring(integration.materialDefault or "TSM default"),.8,.8,.8,true)
            GameTooltip:AddLine("Default crafted-value formula: "..tostring(integration.craftingDefault or "TSM default"),.8,.8,.8,true)
            for _,alias in ipairs(integration.aliases or {}) do
                GameTooltip:AddLine(alias.name.." = "..alias.expression.." • "..(alias.value and Money(alias.value) or "item value unavailable"),.85,.8,.65,true)
            end
            if integration.integration=="material-write" then GameTooltip:AddLine("Stock TSM receives UBK's maintained material cost through its existing material entry. /reload can refresh TSM's cached crafting displays.",.7,.85,.7,true) end
            GameTooltip:AddLine("These are your loaded sources. UBK does not create or change custom aliases from this view.",.7,.7,.7,true)
            GameTooltip:Show()
        end)
        sourcePanel:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
        detailTop=284
    end
    if materialPlan or prospect then
        local marketTab=MakeButton(UI.content,"Market details",122,24);marketTab:SetPoint("TOPLEFT",12,-detailTop)
        marketTab:SetScript("OnClick",function() UI.materialPaneItem=nil;UI.prospectPaneItem=nil;RenderPage() end)
        local extra=MakeButton(UI.content,materialPlan and "Crafting materials" or "Prospecting rates",150,24)
        extra:SetPoint("LEFT",marketTab,"RIGHT",8,0)
        extra:SetScript("OnClick",function()
            if materialPlan then UI.materialPaneItem=item;UI.prospectPaneItem=nil else UI.prospectPaneItem=item;UI.materialPaneItem=nil end
            RenderPage()
        end)
        if materialPlan and UI.materialPaneItem==item then
            if UI.materialErrorItem~=item then UI.materialError=nil end
            _G.UBKMaterialScan.Render(ctx,item,detailTop+32);return
        elseif prospect and UI.prospectPaneItem==item then
            _G.UBKProspectingUI.RenderInspector(ctx,prospect,detailTop+32);return
        end
        detailTop=detailTop+34
    end
    local lines={}
    if prospect then
        lines[#lines+1]="Prospecting: "..tostring(prospect.samples or 0).." learned prospects. Open Prospecting rates above for current raw-gem yields per five ores."
    end
    if m then
        lines[#lines+1]="AuctionDB min buyout: "..(m.minbuyout and Money(m.minbuyout) or "n/a")
        lines[#lines+1]="Realm market / recent / historical: "..(m.dbmarket and Money(m.dbmarket) or "n/a").." / "..(m.recent and Money(m.recent) or "n/a").." / "..(m.historical and Money(m.historical) or "n/a")
        lines[#lines+1]="Regional reference: "..(m.regionReference and Money(m.regionReference) or "n/a").."  •  region ratio "..Pct(m.regionRatio)
        lines[#lines+1]=string.format("Liquidity: %s  •  sale rate %s  •  sold/day %s",tostring(m.liquidity or "UNKNOWN"),m.saleRate and string.format("%.3f",m.saleRate) or "n/a",m.soldPerDay and string.format("%.2f",m.soldPerDay) or "n/a")
    end
    if isShredderItem then
        local de=deOutputs
        if #de>0 then
            local parts={}
            for i,row in ipairs(de) do
                if i>4 then parts[#parts+1]="…"; break end
                local mv=row.market and (row.market.dbmarket or row.market.recent or row.market.historical) or nil
                parts[#parts+1]=string.format("%s %.2fx %s @ %s • %s%s",ItemTextureTag(row.itemString,16),tonumber(row.expectedQty) or 0,row.name or ItemName(row.itemString),mv and Money(mv) or "n/a",row.liquidity or "UNKNOWN",row.market and row.market.soldPerDay and (" • "..string.format("%.1f/day",row.market.soldPerDay)) or "")
            end
            lines[#lines+1]="Expected disenchant outputs: "..table.concat(parts,"  |  ")
        end
    end
    if API.GetShredderLiveStock then
        local live=API:GetShredderLiveStock(item)
        if live then
            local complete=live.complete and "complete" or "partial"
            local nextText=live.nextPrice and Money(live.nextPrice) or "none seen"
            lines[#lines+1]=string.format("Shredder AH stock (%s, %s old): %d units seen • %d profitable • profitable through %s • next %s",complete,Age(live.updatedAt),tonumber(live.units) or 0,tonumber(live.profitableUnits) or 0,live.maxProfitablePrice and Money(live.maxProfitablePrice) or "—",nextText)
        end
    end
    lines[#lines+1]="Cached signals: "..JoinSignals(intel and intel.signals)
    local rt,rg=API:GetMarketDataTimes(); lines[#lines+1]="Loaded AppHelper/AuctionDB data age: realm "..Age(rt).." • region "..Age(rg)
    local body=MakeText(UI.content,"GameFontHighlight"); body:SetPoint("TOPLEFT",12,-detailTop); body:SetPoint("RIGHT",-8,0); body:SetJustifyH("LEFT"); body:SetText(table.concat(lines,"\n\n"))
end

local function CrossRecipeText(recipe)
    local parts={}
    for _,reagent in ipairs((recipe and recipe.reagents) or {}) do
        parts[#parts+1]=string.format("%dx [%s]",tonumber(reagent.qty) or 1,reagent.name or ItemName(reagent.item))
    end
    return table.concat(parts," + ").." → ["..tostring((recipe and recipe.outputName) or "crafted output").."]"
end

local function RenderCrossPressureDetail(r,cp)
    local rel=r.rel or {}; local evidence=r.evidence or {}; local recipe=CROSS_PRESSURE_RECIPES[rel.recipe] or {}
    PageTitle("Cross Event: ["..tostring(rel.driverName or "Trigger material").."] → ["..tostring(rel.targetName or "Candidate material").."]","What moved, why the markets are linked, why UBK chose the ceiling, and exact TSM searches for every connected market.")
    local back=MakeButton(UI.content,"< Back to Cross-Pressure",174,24); back:SetPoint("TOPLEFT",0,-58)
    back:SetScript("OnClick",function() UI.crossDetailKey=nil; RenderPage() end)

    local eventTitle=MakeText(UI.content,"GameFontNormal"); eventTitle:SetPoint("TOPLEFT",0,-94); eventTitle:SetText("WHAT EVENT DID UBK SEE?"); eventTitle:SetTextColor(1,.78,.22)
    local eventBody=MakeText(UI.content,"GameFontHighlightSmall"); eventBody:SetPoint("TOPLEFT",4,-116); eventBody:SetPoint("RIGHT",-6,0); eventBody:SetHeight(58)
    if r.setup then
        eventBody:SetText(string.format("[%s] fell %+.1f%%, from %s to %s, between loaded AppHelper updates. During that same event, [%s] moved %+.1f%%, from %s to %s. The event is %d update%s old; current prices are %s and %s.",rel.driverName,(r.driverMove or 0)*100,Money(r.setup.baselineDriver),Money(r.setup.eventDriver),rel.targetName,(r.targetMove or 0)*100,Money(r.setup.baselineTarget),Money(r.setup.eventTarget),r.setup.ageUpdates or 0,(r.setup.ageUpdates or 0)==1 and "" or "s",r.driverPrice and Money(r.driverPrice) or "unavailable",r.targetPrice and Money(r.targetPrice) or "unavailable"))
    else
        eventBody:SetText(string.format("No active cascade is armed right now. UBK is waiting for [%s] to reach %s or lower while [%s] remains at or below %s. Those two named conditions define the next event UBK is watching for.",rel.driverName,r.driverTriggerPrice and Money(r.driverTriggerPrice) or "its trigger",rel.targetName,r.buyCeiling and Money(r.buyCeiling) or "its ceiling"))
    end
    if eventBody.SetWordWrap then eventBody:SetWordWrap(true) end

    local craftTitle=MakeText(UI.content,"GameFontNormal"); craftTitle:SetPoint("TOPLEFT",0,-184); craftTitle:SetText("WHY THESE MATERIALS CAN MOVE TOGETHER"); craftTitle:SetTextColor(1,.78,.22)
    local craftBody=MakeText(UI.content,"GameFontHighlightSmall"); craftBody:SetPoint("TOPLEFT",4,-206); craftBody:SetPoint("RIGHT",-6,0); craftBody:SetHeight(88)
    local economics="Current recipe economics are incomplete in the loaded snapshot."
    if r.recipe and r.recipe.basketCost and r.recipe.outputPrice then
        economics=string.format("The current reagent basket is %s and the crafted-output reference is %s, a gross spread of %s before other costs.",Money(r.recipe.basketCost),Money(r.recipe.outputPrice),Money((r.recipe.outputPrice or 0)-(r.recipe.basketCost or 0)))
    end
    craftBody:SetText(string.format("Recipe connection: %s. When [%s] becomes cheaper while [%s] and the crafted output have not already repriced, the full recipe can become more attractive to craft. More crafting can create follow-on demand for every co-reagent, including [%s]. %s UBK treats this as an evidence-backed lead/lag hypothesis—not proof that one item alone caused the move.",CrossRecipeText(recipe),rel.driverName,rel.targetName,rel.targetName,economics))
    if craftBody.SetWordWrap then craftBody:SetWordWrap(true) end

    local reasonTitle=MakeText(UI.content,"GameFontNormal"); reasonTitle:SetPoint("TOPLEFT",0,-304); reasonTitle:SetText("WHY THIS ACTION AND THIS CEILING?"); reasonTitle:SetTextColor(1,.78,.22)
    local reasonBody=MakeText(UI.content,"GameFontHighlightSmall"); reasonBody:SetPoint("TOPLEFT",4,-326); reasonBody:SetPoint("RIGHT",-6,0); reasonBody:SetHeight(102)
    local evidenceText=evidence.events and evidence.events>0 and string.format("The observed record is %d wins in %d events, with a median later [%s] response of %s.",evidence.wins or 0,evidence.events or 0,rel.targetName,evidence.median and string.format("%+.1f%%",evidence.median*100) or "unavailable") or "UBK does not yet have enough distinct observations to describe a stable response."
    local ceilingText=r.buyCeiling and string.format("The %s ceiling is %s: the highest candidate price UBK will still treat as not having already chased the event. Above that line, the expected move may be partly spent and the remaining room becomes less attractive.",rel.targetName,Money(r.buyCeiling)) or "UBK needs more loaded market history before it can name a candidate ceiling."
    reasonBody:SetText(string.format("Current assessment: %s\n%s %s Scale-out and exit references apply to [%s], not [%s].",tostring(r.action or r.status or "No action"),ceilingText,evidenceText,rel.targetName,rel.driverName))
    if reasonBody.SetWordWrap then reasonBody:SetWordWrap(true) end

    local searchTitle=MakeText(UI.content,"GameFontNormal"); searchTitle:SetPoint("TOPLEFT",0,-438); searchTitle:SetText("OPEN A LINKED MARKET IN TSM BROWSE"); searchTitle:SetTextColor(1,.78,.22)
    local searchHelp=MakeText(UI.content,"GameFontDisableSmall"); searchHelp:SetPoint("TOPLEFT",4,-458); searchHelp:SetPoint("RIGHT",-6,0); searchHelp:SetText("Each button performs a separate exact-item handoff. Use them one at a time to compare the trigger, candidate, every co-reagent, and the crafted output.")
    local markets={}; local seen={}
    for _,reagent in ipairs(recipe.reagents or {}) do
        if not seen[reagent.item] then seen[reagent.item]=true; markets[#markets+1]={item=reagent.item,name=reagent.name or ItemName(reagent.item),kind=(reagent.item==rel.driver and "TRIGGER" or (reagent.item==rel.target and "CANDIDATE" or "CO-REAGENT"))} end
    end
    if recipe.output and not seen[recipe.output] then markets[#markets+1]={item=recipe.output,name=recipe.outputName or ItemName(recipe.output),kind="OUTPUT"} end
    for index,market in ipairs(markets) do
        local col=(index-1)%3; local row=math.floor((index-1)/3)
        local button=MakeButton(UI.content,market.kind..": "..market.name,284,25); button:SetPoint("TOPLEFT",col*294,-486-row*31)
        local marketItem,marketName=market.item,market.name
        button:SetScript("OnClick",function()
            API:OpenInTSM({itemString=marketItem,itemName=marketName})
        end)
        AddButtonTooltip(button,"Search ["..marketName.."]",
            "Place ["..marketName.."] into the visible TSM Browse field as an exact-item search and submit it.",
            "This lets you inspect the "..tostring(market.kind or "linked").." market separately instead of assuming every material in the event moved together. Open the Auction House and TSM Browse first.",
            "The live listings can differ from UBK's loaded AppHelper reference because players may have posted, purchased, or cancelled auctions since that dataset was created.")
    end
end

RenderCrossPressure=function()
    local db=EnsureDB(); local cp=db.crossPressure
    if UI.crossDetailKey then
        for _,detailRel in ipairs(CROSS_PRESSURE_RELATIONS) do
            if detailRel.key==UI.crossDetailKey then RenderCrossPressureDetail(CPCurrent(detailRel),cp); return end
        end
        UI.crossDetailKey=nil
    end
    PageTitle(CROSS_PRESSURE_LABEL.." Playbook","Rows name both markets. Explain / Search shows the event, shared recipe, reasoning, and every connected TSM market.")
    local refresh=MakeButton(UI.content,"Capture Loaded Data",132,24); refresh:SetPoint("TOPLEFT",0,-58)
    refresh:SetScript("OnClick",function()
        local ok,why=CPCaptureAndAlert("manual")
        UI.homeStatus=ok and "Cross-Pressure captured a new AppHelper snapshot." or (why=="same-data" and "Cross-Pressure already has this AppHelper update." or "Cross-Pressure could not capture this market snapshot.")
        RenderPage()
    end)
    AddButtonTooltip(refresh,"Capture Loaded Data",
        "Record one new Cross-Pressure snapshot from the TSM/AppHelper market data currently loaded in this WoW session.",
        "UBK captures each linked trigger, candidate, co-reagent, and crafted-output reference together so later snapshots can reveal a lead/lag event. It ignores a duplicate AppHelper timestamp and does not scan the live Auction House.",
        "A genuinely newer AppHelper dataset can change event age, evidence, recipe support, and WAIT / BUY / SCALE / EXIT assessments. Current UBK ownership or basis can separately change position guidance.")
    local arena=MakeButton(UI.content,"Show Test Arena",132,24); arena:SetPoint("TOPRIGHT",-2,-58)
    arena:SetScript("OnClick",function() OpenTestArena("cross") end)
    AddButtonTooltip(arena,"Cross-Pressure Test Arena","Practice the workflow with the Golden Geese casebook.","Practice never reads or changes live basis, evidence, inventory, conclusions, queues, or Auction House actions.")
    local count=MakeText(UI.content,"GameFontDisableSmall"); count:SetPoint("LEFT",refresh,"RIGHT",10,0)
    count:SetText(string.format("%d snapshots • loaded-data capture only • no live Auction House scan",#(cp.snapshots or {})))

    local access=MakeText(UI.content,"GameFontDisableSmall"); access:SetPoint("TOPLEFT",4,-86); access:SetPoint("RIGHT",-6,0); access:SetHeight(14)
    access:SetText("|cff66ff77UBK WORKSPACE|r • every action remains player-click driven")
    if access.SetWordWrap then access:SetWordWrap(false) end

    local explain=MakeText(UI.content,"GameFontDisableSmall"); explain:SetPoint("TOPLEFT",4,-108); explain:SetPoint("RIGHT",-6,0); explain:SetHeight(14)
    explain:SetText("Row 1 = named markets + evidence. Row 2 = named action. Use Explain / Search for the event, recipe connection, reasoning, and TSM buttons.")
    if explain.SetWordWrap then explain:SetWordWrap(false) end

    local rows=CPAllRows(); local shown={}
    local actionFilter=UI.crossFilter or "ALL"
    for _,r in ipairs(rows) do
        local include=actionFilter=="ALL" or r.status==actionFilter or (actionFilter=="ACT" and (r.status=="BUY NOW" or r.status=="EXIT NOW" or r.status=="SCALE OUT")) or (actionFilter=="POSITION" and r.ownedQty and r.ownedQty>0)
        if include then shown[#shown+1]=r end
    end
    local filters={{"ALL","All",88},{"ACT","Act Now",88},{"WAIT","Wait",88},{"POSITION","I Own Target",112},{"WATCH","Watch",88}}
    local filterTips={
        ALL={"Show every Cross-Pressure relationship in its current assessment state.","Rows stay ordered by urgency first, then evidence strength, then candidate name."},
        ACT={"Show only BUY NOW, SCALE OUT, and EXIT NOW relationships.","This is the short list where the currently loaded evidence and prices support an immediate player decision."},
        WAIT={"Show relationships waiting for the named trigger market to reach its trigger price.","These are not buy calls yet; the required environmental price event has not happened."},
        POSITION={"Show every relationship whose candidate material UBK currently sees in your inventory.","Use this to put existing exposure ahead of new opportunities, including HOLD, SCALE OUT, EXIT, or risk guidance."},
        WATCH={"Show armed relationships that UBK is deliberately preventing from becoming BUY NOW yet.","The price event exists, but evidence strength or projected room still fails a safety bar."},
    }
    local x=0
    for _,f in ipairs(filters) do
        local w=f[3] or 88; local b=MakeButton(UI.content,f[2],w,22); b:SetPoint("TOPLEFT",x,-134); x=x+w+5
        b:SetScript("OnClick",function() UI.crossFilter=f[1]; UI.listPage=1; RenderPage() end)
        local tip=filterTips[f[1]]
        AddButtonTooltip(b,f[2].." Cross-Pressure Results",tip[1],tip[2].." This button filters the completed playbooks; it does not capture data or open an AH search.","A new loaded-data capture, expiring event age, changing recipe economics, or different UBK ownership/basis can move a relationship into another assessment.")
        if actionFilter==f[1] and b.LockHighlight then b:LockHighlight() end
    end

    local h=(UI.content and UI.content.GetHeight and UI.content:GetHeight()) or 560
    local perPage=math.max(2,math.min(8,math.floor((h-200)/46)))
    local start=(UI.listPage-1)*perPage+1; local finish=math.min(#shown,start+perPage-1)
    for i=start,finish do
        local r=shown[i]; local rel=r.rel; local e=r.evidence or {}; local rec=CROSS_PRESSURE_RECIPES[rel.recipe] or {}
        local hist=e.events>0 and string.format("%d/%d",e.wins,e.events) or "0/0"
        local med=e.median and string.format("%+.1f%%",e.median*100) or "—"
        local curA=r.driverPrice and Money(r.driverPrice) or "?"; local curB=r.targetPrice and Money(r.targetPrice) or "?"
        local arm=r.driverTriggerPrice and Money(r.driverTriggerPrice) or "?"; local ceiling=r.buyCeiling and Money(r.buyCeiling) or "?"
        local statusColor={
            ["BUY NOW"]="|cff33ff99",["EXIT NOW"]="|cffff6666",["SCALE OUT"]="|cffffaa33",ABORT="|cffff6666",WATCH="|cffffcc00",["NO CHASE"]="|cffaaaaaa",WAIT="|cff66ccff",LEARNING="|cffaaaaaa"
        }
        local status=(statusColor[r.status] or "|cffffffff")..r.status.."|r"
        local own=(r.ownedQty or 0)>0 and string.format(" • OWN %d",r.ownedQty) or ""
        local scale=r.scaleOutPrice and Money(r.scaleOutPrice) or "?"; local exit=r.exitPrice and Money(r.exitPrice) or "?"
        local grade=tostring(r.certainty or "Forming")
        local line1=string.format("%s  %s %s → %s %s   •   %s • med %s%s • %s",status,rel.driverName,curA,rel.targetName,curB,hist,med,own,grade)
        local line2
        if r.status=="BUY NOW" then line2=string.format("BUY [%s] <= %s NOW   •   SCALE >= %s   •   EXIT >= %s",rel.targetName,ceiling,scale,exit)
        elseif r.status=="WAIT" then line2=string.format("WAIT FOR [%s] <= %s  →  THEN [%s] <= %s",rel.driverName,arm,rel.targetName,ceiling)
        elseif r.status=="EXIT NOW" then line2=string.format("EXIT [%s] NOW at %s+   •   current %s",rel.targetName,exit,curB)
        elseif r.status=="SCALE OUT" then line2=string.format("SCALE OUT [%s] NOW   •   finish EXIT >= %s",rel.targetName,exit)
        elseif r.status=="NO CHASE" then line2=string.format("NO CHASE: [%s] > %s   •   SCALE %s / EXIT %s",rel.targetName,ceiling,scale,exit)
        elseif r.status=="ABORT" then line2="ABORT: "..tostring(r.action or "pressure invalidated")
        elseif r.status=="WATCH" then line2=string.format("ARMED / WATCH [%s] <= %s   •   SCALE %s   •   EXIT %s",rel.targetName,ceiling,scale,exit)
        else line2="LEARN: collect more distinct AppHelper updates before trading this pair." end
        local txt=line1.."\n"..line2
        local row=ItemRow(UI.content,-166-(i-start)*46,rel.target,txt,function() ShowMarketItem(rel.target) end,function() AddWatch(rel.target) end,"Explain / Search",function() UI.crossDetailKey=rel.key; RenderPage() end,132)
        row:SetHeight(42)
        if row.text then row.text:SetJustifyH("LEFT"); row.text:SetJustifyV("MIDDLE"); if row.text.SetWordWrap then row.text:SetWordWrap(false) end end
        if row.actionButton then
            AddButtonTooltip(row.actionButton,"Explain / Search: ["..rel.targetName.."]",
                "Open this relationship's teaching page: the observed event, shared recipe, action reasoning, ceiling, evidence, and every connected market.",
                "Opening the page does not scan anything. Its separate trigger, candidate, co-reagent, and output buttons let you choose which exact TSM Browse search to run.",
                "A later Cross-Pressure capture, changed recipe references, or changed UBK ownership/basis can alter the explanation and recommended action.")
        end
        row:SetScript("OnEnter",function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
                GameTooltip:AddLine(rel.driverName.." → "..rel.targetName,1,.82,0)
                GameTooltip:AddLine("Shared crafted output: ["..tostring(rec.name or rel.recipe).."]",1,1,1,true)
                GameTooltip:AddLine("Recipe: "..CrossRecipeText(rec),.8,.85,.92,true)
                GameTooltip:AddLine("PLAYBOOK",.45,.9,1)
                GameTooltip:AddLine("["..rel.driverName.."] trigger: "..(r.driverTriggerPrice and Money(r.driverTriggerPrice) or "need more data").."   Current: "..curA,.9,.9,.9,true)
                GameTooltip:AddLine("["..rel.targetName.."] buy ceiling: "..(r.buyCeiling and Money(r.buyCeiling) or "need more data").."   Current: "..curB,.9,.9,.9,true)
                GameTooltip:AddLine("["..rel.targetName.."] scale-out: "..(r.scaleOutPrice and Money(r.scaleOutPrice) or "?").."   Exit: "..(r.exitPrice and Money(r.exitPrice) or "?"),.9,.9,.9,true)
                if r.netRoom then GameTooltip:AddLine(string.format("Projected room to median exit after %.0f%% AH cut: %+.1f%%",(cp.ahCutPct or .05)*100,r.netRoom*100),.9,.9,.9,true) end
                GameTooltip:AddLine(r.action or "",1,.82,.25,true)
                GameTooltip:AddLine("Evidence grade: "..tostring(r.certainty or "Forming").." ("..tostring(r.seen or 1).." of 3 matching updates)",.58,.88,1,true)
                if r.positionAction then GameTooltip:AddLine(r.positionAction,.45,1,.65,true) end
                if (r.ownedQty or 0)>0 then GameTooltip:AddLine(string.format("UBK sees %d owned%s",r.ownedQty,r.basis and (" • basis "..Money(r.basis)) or ""),.75,.9,.75,true) end
                GameTooltip:AddLine(string.format("Evidence: %d/%d wins • median next response %s • live %d/%d",e.wins or 0,e.events or 0,med,e.liveWins or 0,e.liveEvents or 0),.75,.75,.75,true)
                if r.setup then GameTooltip:AddLine(string.format("Current setup age: %d AppHelper update%s",r.setup.ageUpdates or 0,(r.setup.ageUpdates or 0)==1 and "" or "s"),.7,.7,.7,true) end
                if r.recipe and r.recipe.basketCost and r.recipe.outputPrice then
                    GameTooltip:AddLine("Shared-craft reagent basket: "..Money(r.recipe.basketCost).."   Output ref: "..Money(r.recipe.outputPrice),.75,.75,.75,true)
                end
                GameTooltip:AddLine("Why these prices:",.8,.8,.95)
                GameTooltip:AddLine("The trigger must become meaningfully cheaper while the candidate has not already consumed the expected move. The named ceiling prevents chasing.",.6,.7,.85,true)
                GameTooltip:AddLine("Scale-out and exit levels are derived from the response observed across distinct loaded-data updates.",.6,.7,.85,true)
                GameTooltip:AddLine("Left-click: inspect ["..rel.targetName.."]   Right-click: watch it",.45,.9,1,true)
                GameTooltip:AddLine("Explain / Search: event lesson + separate TSM buttons for every linked market",.45,1,.65,true)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    end
    if #shown==0 then local e=MakeText(UI.content); e:SetPoint("TOPLEFT",4,-174); e:SetText("No relationships match this filter yet.") end
    AddPager(#shown,perPage)
end

-- TEST ARENA BOUNDARY
-- Everything between this marker and the end marker is a disposable, synthetic
-- practice machine. It deliberately has its own fixtures, conclusion ledger,
-- inventory ledger, and reducers. Do not route these functions through UBK,
-- TSM, the Auction House, the evidence provider, or SavedVariables.
local TEST_ARENA_TABS = {cross=true,position=true}
local GOLDEN_GEESE_UPDATES = {
    {fingerprint="golden-geese-1",title="Baseline",terocone=65000,felweed=15000,flask=150000},
    {fingerprint="golden-geese-2",title="Trigger",terocone=52000,felweed=15000,flask=138000},
    {fingerprint="golden-geese-3",title="Second agreement",terocone=51000,felweed=15100,flask=140000},
    {fingerprint="golden-geese-4",title="Third agreement",terocone=50000,felweed=15200,flask=143000},
    {fingerprint="golden-geese-5",title="Contradiction",terocone=66000,felweed=15500,flask=125000},
}
local GOLDEN_GEESE_RECIPE = {terocone=1,felweed=2,vial=1,vialPrice=4000,batch=20,ahCut=.05}

local function TestArenaCopy(value)
    if type(value)~="table" then return value end
    local out={}
    for key,child in pairs(value) do out[TestArenaCopy(key)]=TestArenaCopy(child) end
    return out
end

local function TestArenaMoney(value)
    local negative=(tonumber(value) or 0)<0
    local copper=math.max(0,math.floor(math.abs(tonumber(value) or 0)+.5))
    local gold=math.floor(copper/10000)
    local silver=math.floor((copper%10000)/100)
    local coins=copper%100
    local text
    if gold>0 and coins>0 then text=string.format("%dg%02ds%02dc",gold,silver,coins)
    elseif gold>0 and silver>0 then text=string.format("%dg%02ds",gold,silver)
    elseif gold>0 then text=string.format("%dg",gold)
    elseif silver>0 and coins>0 then text=string.format("%ds%02dc",silver,coins)
    elseif silver>0 then text=string.format("%ds",silver)
    else text=string.format("%dc",coins) end
    return negative and ("-"..text) or text
end

local function TestArenaCertainty(seen)
    seen=math.max(1,math.min(3,tonumber(seen) or 1))
    if seen>=3 then return "Highly Actionable" end
    if seen==2 then return "Strengthening" end
    return "Forming"
end

local function TestArenaAdvanceConclusion(previous,signature)
    local seen=(type(previous)=="table" and previous.signature==signature) and math.min(3,(tonumber(previous.seen) or 0)+1) or 1
    return {signature=signature,seen=seen,certainty=TestArenaCertainty(seen)}
end

local function TestArenaObserveUpdate(session,index)
    if type(session)~="table" then return nil,false,"Practice session is unavailable." end
    index=math.floor(tonumber(index) or 0)
    local update=GOLDEN_GEESE_UPDATES[index]
    local nextState=TestArenaCopy(session)
    if not update then
        nextState.lastMessage="There is no later market update in this five-update casebook. Reset to replay it."
        return nextState,false,nextState.lastMessage
    end
    if nextState.observed[update.fingerprint] then
        nextState.lastMessage="Duplicate rejected. This market update was already observed, so no practice evidence or conclusion advanced."
        return nextState,false,nextState.lastMessage
    end
    if index~=(tonumber(nextState.updateIndex) or 0)+1 then
        nextState.lastMessage="Practice updates must be observed in order. Nothing changed."
        return nextState,false,nextState.lastMessage
    end

    nextState.updateIndex=index
    nextState.observed[update.fingerprint]=true
    nextState.observedCount=(tonumber(nextState.observedCount) or 0)+1
    nextState.history[#nextState.history+1]=TestArenaCopy(update)

    if index==1 then
        nextState.crossConclusion={signature="baseline",seen=0,certainty="Waiting"}
    elseif index<=4 then
        nextState.crossConclusion=TestArenaAdvanceConclusion(nextState.crossConclusion,"felweed-pressure")
    else
        nextState.crossConclusion=TestArenaAdvanceConclusion(nextState.crossConclusion,"pressure-broke")
    end
    nextState.positionConclusion=TestArenaAdvanceConclusion(nextState.positionConclusion,"felweed-fee-aware-sale")
    nextState.lastMessage=index==1
        and "Baseline loaded into a fresh practice ledger. Advance the market when you are ready."
        or (index==5
            and "The rebound contradicts the earlier Cross-Pressure setup. Its practice conclusion returned to Forming."
            or (update.title.." accepted as a distinct practice update."))
    return nextState,true,nextState.lastMessage
end

local function NewTestArenaSession(activeTab)
    if not TEST_ARENA_TABS[activeTab] then activeTab="cross" end
    local session={
        activeTab=activeTab,
        wallet=5000000,
        inventory={
            felweed={qty=80,basisTotal=960000},
            terocone={qty=0,basisTotal=0},
            flask={qty=0,basisTotal=0},
        },
        observed={},observedCount=0,history={},updateIndex=0,
        crossConclusion=nil,positionConclusion=nil,realizedProfit=0,lastMessage="",
    }
    local seeded=TestArenaObserveUpdate(session,1)
    return seeded
end

local function TestArenaUnitBasis(position)
    if type(position)~="table" or (tonumber(position.qty) or 0)<=0 then return nil end
    return (tonumber(position.basisTotal) or 0)/(tonumber(position.qty) or 1)
end

local function TestArenaCraftable(session)
    if type(session)~="table" then return 0 end
    local inv=session.inventory or {}
    local terocone=inv.terocone or {}; local felweed=inv.felweed or {}
    return math.max(0,math.min(
        GOLDEN_GEESE_RECIPE.batch,
        math.floor(tonumber(terocone.qty) or 0),
        math.floor((tonumber(felweed.qty) or 0)/GOLDEN_GEESE_RECIPE.felweed),
        math.floor((tonumber(session.wallet) or 0)/GOLDEN_GEESE_RECIPE.vialPrice)
    ))
end

local function TestArenaCanBuy(session)
    if type(session)~="table" then return false end
    local index=tonumber(session.updateIndex) or 0
    local inv=session.inventory or {}; local terocone=inv.terocone or {}; local felweed=inv.felweed or {}
    local update=GOLDEN_GEESE_UPDATES[index]
    local cost=update and update.terocone*GOLDEN_GEESE_RECIPE.batch or nil
    return index>=2 and index<=4
        and (tonumber(terocone.qty) or 0)==0
        and (tonumber(felweed.qty) or 0)>=GOLDEN_GEESE_RECIPE.batch*GOLDEN_GEESE_RECIPE.felweed
        and cost and (tonumber(session.wallet) or 0)>=cost
end

local function TestArenaReduce(session,action,value)
    if type(session)~="table" then return nil,false,"Practice session is unavailable." end
    if action=="NEXT_UPDATE" then
        return TestArenaObserveUpdate(session,(tonumber(session.updateIndex) or 0)+1)
    elseif action=="IMPORT_SAME_UPDATE" then
        return TestArenaObserveUpdate(session,tonumber(session.updateIndex) or 0)
    elseif action=="RESET" then
        local reset=NewTestArenaSession(TEST_ARENA_TABS[value] and value or session.activeTab)
        reset.lastMessage="Practice reset. A new 500g ledger and the original synthetic inventory are ready."
        return reset,true,reset.lastMessage
    elseif action=="SWITCH_TAB" then
        if not TEST_ARENA_TABS[value] then
            local unchanged=TestArenaCopy(session)
            unchanged.lastMessage="That practice workspace does not exist. Nothing changed."
            return unchanged,false,unchanged.lastMessage
        end
        local switched=TestArenaCopy(session)
        switched.activeTab=value
        switched.lastMessage=(value=="cross" and "Cross-Pressure practice is open." or "Position Intelligence practice is open.")
        return switched,true,switched.lastMessage
    end

    local nextState=TestArenaCopy(session)
    local update=GOLDEN_GEESE_UPDATES[nextState.updateIndex]
    local inv=nextState.inventory
    if action=="BUY_TEROCONE" then
        if not TestArenaCanBuy(nextState) then
            nextState.lastMessage="That practice purchase is not available. Wait for the cheap Terocone setup and keep enough gold and paired Felweed for the batch."
            return nextState,false,nextState.lastMessage
        end
        local qty=GOLDEN_GEESE_RECIPE.batch
        local spent=qty*update.terocone
        nextState.wallet=nextState.wallet-spent
        inv.terocone.qty=inv.terocone.qty+qty
        inv.terocone.basisTotal=inv.terocone.basisTotal+spent
        nextState.lastMessage="Practice purchase complete: 20 Terocone entered the synthetic ledger at the current casebook price."
        return nextState,true,nextState.lastMessage
    elseif action=="CRAFT_GEESE" then
        local qty=TestArenaCraftable(nextState)
        if qty<=0 then
            nextState.lastMessage="No complete Golden Geese batch is craftable yet. Buy Terocone and keep paired Felweed plus vial gold available."
            return nextState,false,nextState.lastMessage
        end
        local felweedUsed=qty*GOLDEN_GEESE_RECIPE.felweed
        local felweedBasis=(TestArenaUnitBasis(inv.felweed) or 0)*felweedUsed
        local teroconeBasis=(TestArenaUnitBasis(inv.terocone) or 0)*qty
        local vialSpend=qty*GOLDEN_GEESE_RECIPE.vialPrice
        local craftedBasis=felweedBasis+teroconeBasis+vialSpend
        inv.felweed.qty=inv.felweed.qty-felweedUsed
        inv.felweed.basisTotal=math.max(0,inv.felweed.basisTotal-felweedBasis)
        inv.terocone.qty=inv.terocone.qty-qty
        inv.terocone.basisTotal=math.max(0,inv.terocone.basisTotal-teroconeBasis)
        nextState.wallet=nextState.wallet-vialSpend
        inv.flask.qty=inv.flask.qty+qty
        inv.flask.basisTotal=inv.flask.basisTotal+craftedBasis
        nextState.lastMessage=string.format("Practice craft complete: %d Flask%s of The Golden Geese now carry the basis of the materials actually consumed.",qty,qty==1 and "" or "s")
        return nextState,true,nextState.lastMessage
    elseif action=="SELL_GEESE" then
        local qty=math.floor(tonumber(inv.flask.qty) or 0)
        if qty<=0 then
            nextState.lastMessage="There are no practice flasks to sell. Nothing changed."
            return nextState,false,nextState.lastMessage
        end
        local basisReleased=tonumber(inv.flask.basisTotal) or 0
        local net=math.floor((qty*update.flask)*(1-GOLDEN_GEESE_RECIPE.ahCut)+.5)
        nextState.wallet=nextState.wallet+net
        nextState.realizedProfit=(tonumber(nextState.realizedProfit) or 0)+(net-basisReleased)
        inv.flask.qty=0
        inv.flask.basisTotal=0
        nextState.lastMessage=string.format("Practice sale complete: %d Golden Geese left the synthetic position. The ledger retained the fee-aware realized result.",qty)
        return nextState,true,nextState.lastMessage
    end

    nextState.lastMessage="Unknown practice action rejected. No inventory, basis, gold, or evidence changed."
    return nextState,false,nextState.lastMessage
end

local function TestArenaCrossAssessment(session)
    local index=tonumber(session and session.updateIndex) or 1
    local update=GOLDEN_GEESE_UPDATES[index] or GOLDEN_GEESE_UPDATES[1]
    local conclusion=session.crossConclusion or {certainty="Waiting",seen=0}
    if index==1 then
        return "WAITING FOR A MARKET EVENT","The baseline is recorded. Advance the casebook to see whether one material moves before the rest of the recipe.",conclusion
    elseif index<=4 then
        local action=conclusion.certainty=="Highly Actionable" and "HIGHLY ACTIONABLE: FELWEED PRESSURE" or (conclusion.certainty..": FELWEED PRESSURE")
        local reason=index==2
            and "Terocone broke lower while Felweed held near its baseline. The first supporting observation has formed a possible linked-market opportunity."
            or "Terocone remains cheap while Felweed has barely repriced. A distinct update agreed with the same linked-market conclusion."
        return action,reason,conclusion
    end
    return "FORMING: STAND DOWN","Terocone rebounded above its baseline while the fictional flask weakened. That contradiction broke the earlier conclusion instead of quietly preserving its streak.",conclusion
end

local function TestArenaPositionAssessment(session)
    local update=GOLDEN_GEESE_UPDATES[session.updateIndex] or GOLDEN_GEESE_UPDATES[1]
    local flask=session.inventory.flask
    local flaskBasis=TestArenaUnitBasis(flask)
    if (tonumber(flask.qty) or 0)>0 and flaskBasis and flaskBasis>0 then
        local feeAware=(update.flask*(1-GOLDEN_GEESE_RECIPE.ahCut))/flaskBasis-1
        if feeAware>=.60 then
            return "OBVIOUS WIN — HIGHLY ACTIONABLE","The current synthetic Flask price leaves an unusually large realized-profit window over the trusted practice basis, even after the Auction House cut. Additional sightings are not required.","Highly Actionable",3
        elseif feeAware>0 then
            return "SELLING WINDOW","The current synthetic Flask price clears its practice basis after the Auction House cut. The position can be sold deliberately from the button below.",session.positionConclusion.certainty,session.positionConclusion.seen
        end
        return "HOLD","The current synthetic Flask price does not clear its attached practice basis after the Auction House cut.",session.positionConclusion.certainty,session.positionConclusion.seen
    end
    local conclusion=session.positionConclusion or {certainty="Forming",seen=1}
    return conclusion.certainty..": FELWEED SALE WINDOW","The current synthetic Felweed price remains above the trusted 1g20s practice basis. Repeated distinct updates strengthen the same fee-aware position conclusion.",conclusion.certainty,conclusion.seen
end

local function AddGoldenGeeseTooltip(button)
    if not button then return end
    button:SetScript("OnEnter",function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
        GameTooltip:AddLine("Flask of The Golden Geese",1,.50,0)
        GameTooltip:AddLine("Consumable — Flask",1,1,1)
        GameTooltip:AddLine("Requires Level 65",1,1,1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Use: Increases your Stamina and Spirit by 18 for 2 hours. Your character sheet also claims that your Intellect has increased by 18.",.25,1,.25,true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("While within 30 yards of another player under this effect, you form Team Golden Geese.",1,1,1,true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Team Golden Geese: The first avoidable mechanic failed by either Goose is attributed to the nearest non-Goose party member instead.",1,.82,0,true)
        GameTooltip:AddLine("If either player is caught cheating, the encounter immediately advances to its next phase.",1,1,1,true)
        GameTooltip:AddLine("In the event of a tie, a coin is flipped. Tails never fails.",1,1,1,true)
        GameTooltip:AddLine("This effect persists through death. Your guild standard always appears unsullied.",1,1,1,true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("“Good luck to you, sir.”",1,.82,0,true)
        GameTooltip:AddLine("Gives the illusion of sportsmanship.",1,.82,0,true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Upon a party wipe:",1,1,1)
        GameTooltip:AddLine("Both players gain Undefeated, Technically, begin squawking uncontrollably, and display an 18–0 record above their heads for 10 seconds.",.25,1,.25,true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
end

local function TestArenaPanel(parent,x,y,w,h,title)
    local template=BackdropTemplateMixin and "BackdropTemplate" or nil
    local p=CreateFrame("Frame",nil,parent,template); p:SetPoint("TOPLEFT",x,y); p:SetSize(w,h)
    if p.SetBackdrop then
        p:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=12,edgeSize=10,insets={left=3,right=3,top=3,bottom=3}})
        p:SetBackdropColor(.025,.023,.015,.96); p:SetBackdropBorderColor(.55,.36,.10,.95)
    end
    local t=MakeText(p,"GameFontNormal"); t:SetPoint("TOPLEFT",10,-9); t:SetPoint("RIGHT",-8,0); t:SetText(title); t:SetTextColor(1,.80,.25)
    return p
end

LeaveTestArena=function()
    local returnView=UI.testArenaReturnView or {page=(UI.testArenaSession and UI.testArenaSession.activeTab) or "home"}
    UI.testArenaSession=nil
    UI.testArenaReturnView=nil
    RestoreView(returnView)
end

OpenTestArena=function(kind)
    if not TEST_ARENA_TABS[kind] then return false end
    UI.testArenaReturnView=CaptureView()
    UI.testArenaSession=NewTestArenaSession(kind)
    UI.page="testarena"
    RenderPage()
    return true
end

local function TestArenaRun(action,value)
    local state,ok=TestArenaReduce(UI.testArenaSession,action,value)
    if state then UI.testArenaSession=state end
    RenderPage()
    return ok
end

local function RenderTestArena()
    local session=UI.testArenaSession
    if type(session)~="table" then
        session=NewTestArenaSession("cross")
        UI.testArenaSession=session
    end
    local update=GOLDEN_GEESE_UPDATES[session.updateIndex] or GOLDEN_GEESE_UPDATES[1]
    PageTitle("TEST ARENA — Flask of The Golden Geese","Operate synthetic Cross-Pressure and Position Intelligence with a fresh, disposable practice ledger.")

    local disclosure=MakeText(UI.content,"GameFontHighlightSmall")
    disclosure:SetPoint("TOPLEFT",10,-61); disclosure:SetPoint("RIGHT",-10,0); disclosure:SetHeight(18); disclosure:SetJustifyH("CENTER")
    disclosure:SetText("|cff66ff77PRACTICE ONLY • 500g FAKE WALLET • NO LIVE DATA, QUEUES, INVENTORY, OR ACTIONS|r")

    local cross=MakeButton(UI.content,"Cross-Pressure Practice",210,27); cross:SetPoint("TOPLEFT",8,-84)
    cross:SetScript("OnClick",function() TestArenaRun("SWITCH_TAB","cross") end)
    local position=MakeButton(UI.content,"Position Intelligence Practice",230,27); position:SetPoint("LEFT",cross,"RIGHT",8,0)
    position:SetScript("OnClick",function() TestArenaRun("SWITCH_TAB","position") end)
    local current=session.activeTab=="position" and position or cross
    if current.LockHighlight then current:LockHighlight() end
    AddButtonTooltip(cross,"Cross-Pressure Practice","Advance five synthetic market updates and watch a linked-market conclusion form, strengthen, become actionable, then break on contradiction.","This practice ledger is never offered to the live engine.")
    AddButtonTooltip(position,"Position Intelligence Practice","Review fake basis and inventory, buy a casebook batch, craft Golden Geese, and realize a synthetic sale.","Every reducer is local to this disposable session.")

    local progress=MakeText(UI.content,"GameFontNormalSmall"); progress:SetPoint("TOPLEFT",8,-121); progress:SetWidth(430)
    progress:SetText(string.format("Update %d of %d: %s  •  %d distinct practice dataset%s accepted",session.updateIndex,#GOLDEN_GEESE_UPDATES,update.title,session.observedCount,session.observedCount==1 and "" or "s"))
    progress:SetTextColor(1,.78,.22)
    local same=MakeButton(UI.content,"Import Same Update",146,24); same:SetPoint("TOPRIGHT",-162,-116)
    same:SetScript("OnClick",function() TestArenaRun("IMPORT_SAME_UPDATE") end)
    AddButtonTooltip(same,"Try a Duplicate Import","Offer the current synthetic dataset to the practice ledger again.","The duplicate is rejected and cannot advance either practice conclusion.")
    local nextb=MakeButton(UI.content,"Next Market Update",154,24); nextb:SetPoint("TOPRIGHT",-2,-116); nextb:SetEnabled(session.updateIndex<#GOLDEN_GEESE_UPDATES)
    nextb:SetScript("OnClick",function() TestArenaRun("NEXT_UPDATE") end)
    AddButtonTooltip(nextb,"Next Market Update","Load the next distinct Golden Geese casebook market.","The fifth update deliberately contradicts the earlier Cross-Pressure conclusion.")

    local left=TestArenaPanel(UI.content,8,-153,425,230,session.activeTab=="cross" and "SYNTHETIC MARKET HISTORY" or "SYNTHETIC POSITION LEDGER")
    local leftBody=MakeText(left,"GameFontHighlightSmall"); leftBody:SetPoint("TOPLEFT",12,-36); leftBody:SetPoint("RIGHT",-10,0); leftBody:SetHeight(182)
    if session.activeTab=="cross" then
        local history={}
        for _,seen in ipairs(session.history) do
            history[#history+1]=string.format("%d. %-18s  Tero %7s  Felweed %7s  Flask %7s",#history+1,seen.title,TestArenaMoney(seen.terocone),TestArenaMoney(seen.felweed),TestArenaMoney(seen.flask))
        end
        leftBody:SetText(table.concat(history,"\n").."\n\nThe recipe connects 1 Terocone, 2 Felweed, and 1 Imbued Vial to one fictional flask. The prices above exist only in this casebook.")
    else
        local felweed=session.inventory.felweed; local terocone=session.inventory.terocone; local flask=session.inventory.flask
        local function PositionLine(name,position)
            local basis=TestArenaUnitBasis(position)
            return string.format("%-18s %3d owned  •  %s basis each",name,math.floor(tonumber(position.qty) or 0),basis and TestArenaMoney(basis) or "no active")
        end
        leftBody:SetText(string.format("Fake wallet: |cffffd36a%s|r\n\n%s\n%s\n%s\n\nRealized practice result: %s\nCurrent fake market: Felweed %s • Golden Geese %s",TestArenaMoney(session.wallet),PositionLine("Felweed",felweed),PositionLine("Terocone",terocone),PositionLine("Golden Geese",flask),TestArenaMoney(session.realizedProfit),TestArenaMoney(update.felweed),TestArenaMoney(update.flask)))
    end
    if leftBody.SetWordWrap then leftBody:SetWordWrap(true) end

    local right=TestArenaPanel(UI.content,442,-153,442,230,session.activeTab=="cross" and "CROSS-PRESSURE CONCLUSION" or "POSITION INTELLIGENCE CONCLUSION")
    local rightBody=MakeText(right,"GameFontHighlightSmall"); rightBody:SetPoint("TOPLEFT",12,-36); rightBody:SetPoint("RIGHT",-10,0); rightBody:SetHeight(182)
    if session.activeTab=="cross" then
        local heading,reason,conclusion=TestArenaCrossAssessment(session)
        rightBody:SetText(string.format("|cffffd36a%s|r\n\n%s\n\nRepeated support: %d distinct supporting update%s.\n\nUse the fake purchase and craft controls below to act on the casebook without touching the Auction House.",heading,reason,tonumber(conclusion.seen) or 0,(tonumber(conclusion.seen) or 0)==1 and "" or "s"))
    else
        local heading,reason,certainty,seen=TestArenaPositionAssessment(session)
        rightBody:SetText(string.format("|cffffd36a%s|r\n\n%s\n\nPractice certainty: %s after %d supporting update%s.\n\nSelling releases only the basis attached to the fake flasks; untouched Felweed keeps its own basis.",heading,reason,certainty,tonumber(seen) or 0,(tonumber(seen) or 0)==1 and "" or "s"))
    end
    if rightBody.SetWordWrap then rightBody:SetWordWrap(true) end

    local buy=MakeButton(UI.content,"Buy 20 Terocone",148,27); buy:SetPoint("TOPLEFT",8,-397); buy:SetEnabled(TestArenaCanBuy(session))
    buy:SetScript("OnClick",function() TestArenaRun("BUY_TEROCONE") end)
    AddButtonTooltip(buy,"Practice Purchase","Buy twenty synthetic Terocone at the current casebook price.","Available only while the cheap-Terocone setup is intact and the fake ledger can support the paired batch.")
    local craftable=TestArenaCraftable(session)
    local craft=MakeButton(UI.content,craftable>0 and ("Craft "..craftable.." Golden Geese") or "Craft Golden Geese",184,27); craft:SetPoint("LEFT",buy,"RIGHT",8,0); craft:SetEnabled(craftable>0)
    craft:SetScript("OnClick",function() TestArenaRun("CRAFT_GEESE") end)
    AddButtonTooltip(craft,"Practice Craft","Convert available synthetic materials into as many as twenty Golden Geese.","The reducer first validates the whole batch, then moves its actual practice basis atomically.")
    local sell=MakeButton(UI.content,"Sell Golden Geese",160,27); sell:SetPoint("LEFT",craft,"RIGHT",8,0); sell:SetEnabled((tonumber(session.inventory.flask.qty) or 0)>0)
    sell:SetScript("OnClick",function() TestArenaRun("SELL_GEESE") end)
    AddButtonTooltip(sell,"Practice Sale","Sell every synthetic Golden Geese currently held at this update's casebook price.","The fake wallet receives proceeds after the Auction House cut; no game action exists behind this button.")
    local goose=MakeButton(UI.content,"[Flask of The Golden Geese]",224,27); goose:SetPoint("TOPRIGHT",-2,-397)
    local gooseText=goose.GetFontString and goose:GetFontString() or nil; if gooseText then gooseText:SetTextColor(1,.50,0) end
    AddGoldenGeeseTooltip(goose)

    local status=TestArenaPanel(UI.content,8,-437,876,54,"LAST PRACTICE RESULT")
    local statusBody=MakeText(status,"GameFontHighlightSmall"); statusBody:SetPoint("TOPLEFT",12,-31); statusBody:SetPoint("RIGHT",-10,0); statusBody:SetText(session.lastMessage or "")
    if statusBody.SetWordWrap then statusBody:SetWordWrap(true) end

    local reset=MakeButton(UI.content,"Reset Practice",150,28); reset:SetPoint("TOPLEFT",8,-502)
    reset:SetScript("OnClick",function() TestArenaRun("RESET",session.activeTab) end)
    AddButtonTooltip(reset,"Reset Test Arena","Discard this practice ledger and create a fresh one with 500g and the original Felweed position.","Reset affects no live data and retains only which practice tab you are viewing.")
    local leave=MakeButton(UI.content,"Leave Practice",178,28); leave:SetPoint("TOPRIGHT",-2,-502)
    leave:SetScript("OnClick",LeaveTestArena)
    AddButtonTooltip(leave,"Leave Test Arena","Discard the entire practice session and return to the exact live view that opened it.","No synthetic state crosses back into the live workspace.")
    local note=MakeText(UI.content,"GameFontDisableSmall"); note:SetPoint("TOPLEFT",174,-499); note:SetPoint("RIGHT",leave,"LEFT",-12,0); note:SetHeight(32); note:SetJustifyH("CENTER")
    note:SetText("Fresh each entry • memory only • resettable • every buy, craft, and sale is fictional")
end
-- END TEST ARENA BOUNDARY

local function ContinueTSMImportAfterReview()
    if not UI.importWorkflowActive then return false end
    local remaining=API:GetReviewItems() or {}
    if #remaining>0 then return false end
    local called,ok,info=pcall(function() return API:FinishTSMImportReview() end)
    if not called or not ok then
        local why=called and info or ok
        UI.homeStatus="Cost Review is clear, but UBK could not finish the import: "..tostring(why or "unknown reason")
        print("|cffff7777UBK:|r "..UI.homeStatus)
        return false
    end
    UI.importWorkflowActive=false
    UI.homeStatus="TSM import and Cost Review are complete. Your accounting is ready."
    print("|cff33ff99UBK:|r "..UI.homeStatus)
    NavigateRoot("home")
    return true
end

local function RenderReview()
    PageTitle("Cost Coverage / Cost Review","Review acquisition evidence, classify world drops, or resolve the cost of unknown units.")
    local coverage=MakeButton(UI.content,"< Cost Coverage",144,24); coverage:SetPoint("TOPLEFT",0,-54)
    coverage:SetScript("OnClick",function() UI.coverageSection="coverage"; UI.listPage=1; RenderPage() end)
    local rows=API:GetReviewItems() or {}; local selected=UI.reviewSelected
    local rowTop=92
    if UI.importWorkflowActive then
        local progress=MakeText(UI.content,"GameFontNormalSmall")
        progress:SetPoint("LEFT",coverage,"RIGHT",12,0); progress:SetPoint("RIGHT",-4,0)
        progress:SetText(string.format("TSM import  •  %d question%s remaining",#rows,#rows==1 and "" or "s"))
        progress:SetTextColor(.62,1,.34)
    end
    UI.reviewSort=UI.reviewSort or {key="name",ascending=true,page=1}
    local grid=_G.UBKTableUI
    if grid then
        grid.Render({UI=UI,MakeText=MakeText,MakeButton=MakeButton},{y=-rowTop,
            height=math.max(125,UI.content:GetHeight()-rowTop-112),rows=rows,state=UI.reviewSort,
            columns={
                {key="name",label="Item",width=180,value=function(r) return r.name end},
                {key="custom",label="Existing cost / formula",width=210,value=function(r) return r.customValue end,
                    text=function(r) return type(r.customValue)=="number" and Money(r.customValue) or tostring(r.customValue or "none") end},
                {key="unresolvedQty",label="Unknown",width=78,align="RIGHT"},
                {key="observedQty",label="Owned",width=70,align="RIGHT"},
                {key="reason",label="Review reason",width=270},
            },onChange=RenderPage,onClick=function(r) UI.reviewSelected=r.itemString; RenderPage() end,
            onEnter=function(frame,r) ShowItemTooltip(frame,r.itemString,"ANCHOR_RIGHT") end,
            emptyText="No outstanding cost reviews."})
    end
    if #rows==0 then
        UI.reviewSelected=nil
    else
        local item=selected and API:GetBasisInfo(selected) or nil
        local meta=MakeText(UI.content,"GameFontDisableSmall"); meta:SetPoint("BOTTOMLEFT",0,62); meta:SetWidth(900); meta:SetJustifyH("LEFT")
        if item then
            local capture=item.lastLootCapture
            local captureText=nil
            if type(capture)=="table" then
                local bits={}
                if tonumber(capture.capturedAt) and tonumber(capture.capturedAt)>0 and type(date)=="function" then bits[#bits+1]=date("%Y-%m-%d %I:%M %p",tonumber(capture.capturedAt)) end
                local place={}
                if capture.zone and capture.zone~="" then place[#place+1]=capture.zone end
                if capture.subZone and capture.subZone~="" and capture.subZone~=capture.zone then place[#place+1]=capture.subZone end
                if #place>0 then bits[#bits+1]=table.concat(place," / ") end
                if tonumber(capture.mapID) then bits[#bits+1]="map "..tostring(capture.mapID) end
                if #bits>0 then captureText="Captured loot: "..table.concat(bits," • ") end
            end
            local basisText=item.worldDropUnitBasis and ("95% world basis: "..Money(item.worldDropUnitBasis)) or "95% world basis: no usable reference yet"
            local refText=item.worldDropReferenceKind and (" from "..tostring(item.worldDropReferenceKind)) or ""
            meta:SetText((captureText and (captureText.."   |   ") or "")..basisText..refText)
        else
            meta:SetText("Select an item above. Captured loot can retain its timestamp and zone/subzone context for provenance review.")
        end

        local lab=MakeText(UI.content,"GameFontNormal"); lab:SetPoint("BOTTOMLEFT",0,36); lab:SetText(item and ("Selected: "..ItemTextureTag(item.itemString,16).." "..item.name) or "Select an item above")
        local manual=MakeButton(UI.content,"Trust as Manual Cost",150,24); manual:SetPoint("BOTTOMLEFT",0,4); manual:SetEnabled(item~=nil); manual:SetScript("OnClick",function()
            if item then local ok=API:Classify(item.itemString,"manual"); if ok then UI.reviewSelected=nil; if not ContinueTSMImportAfterReview() then RenderPage() end end end
        end)
        local world=MakeButton(UI.content,"World Drop / Found / Farmed",200,24); world:SetPoint("LEFT",manual,"RIGHT",8,0); world:SetEnabled(item~=nil and item.worldDropUnitBasis~=nil); world:SetScript("OnClick",function()
            if item then local ok=API:Classify(item.itemString,"world"); if ok then UI.reviewSelected=nil; if not ContinueTSMImportAfterReview() then RenderPage() end end end
        end)
        world:SetScript("OnEnter",function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self,"ANCHOR_TOP")
            GameTooltip:AddLine("World Drop / Found / Farmed",1,.82,0)
            GameTooltip:AddLine("Tell UBK these unresolved units came from the world rather than a purchase.",1,1,1,true)
            if item and item.worldDropUnitBasis then
                GameTooltip:AddLine("Working basis: "..Money(item.worldDropUnitBasis).." each (95% rule).",.55,1,.65,true)
                if item.worldDropReferenceKind then GameTooltip:AddLine("Reference: "..tostring(item.worldDropReferenceKind),.75,.75,.75,true) end
            else
                GameTooltip:AddLine("No positive UBK/reference value is available yet, so UBK will not invent a cost.",1,.45,.35,true)
            end
            if item and type(item.lastLootCapture)=="table" then GameTooltip:AddLine("A captured loot timestamp/location record is attached to this item.",.55,.8,1,true) end
            GameTooltip:Show()
        end)
        world:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
        local econ=MakeButton(UI.content,"Economic Value",120,24); econ:SetPoint("LEFT",world,"RIGHT",8,0); econ:SetEnabled(item~=nil); econ:SetScript("OnClick",function() if item then local ok=API:Classify(item.itemString,"economic"); if ok then UI.reviewSelected=nil; if not ContinueTSMImportAfterReview() then RenderPage() end end end end)
        local inspect=MakeButton(UI.content,"Inspect Market",110,24); inspect:SetPoint("LEFT",econ,"RIGHT",8,0); inspect:SetEnabled(item~=nil); inspect:SetScript("OnClick",function() if item then ShowMarketItem(item.itemString) end end)
        local resolve=MakeButton(UI.content,"Resolve Unknown",126,24); resolve:SetPoint("LEFT",inspect,"RIGHT",8,0); resolve:SetEnabled(item~=nil and (tonumber(item.unresolvedQty) or 0)>0)
        resolve:SetScript("OnClick",function() if item then ShowResolveUnknownDialog(item.itemString) end end)
    end
end

local function RenderCoverage()
    if UI.coverageSection=="review" then RenderReview(); return end
    PageTitle("Cost Coverage",(_G.UBKInternal and _G.UBKInternal.AccountingStatus and _G.UBKInternal.AccountingStatus()) or "Filter by cost status. Click any header to sort; each item has its own cost action.")
    local reviewButton=MakeButton(UI.content,"Cost Review",132,24); reviewButton:SetPoint("TOPRIGHT",-4,-58)
    reviewButton:SetScript("OnClick",function() UI.coverageSection="review"; UI.listPage=1; RenderPage() end)
    AddButtonTooltip(reviewButton,"Cost Review","Open the acquisition-evidence review section inside Cost Coverage.","Classify manual costs and world drops, or resolve unknown units using UBK's existing review tools.")
    local c=API:GetCoverage() or {}
    local ready=type(c.ready)=="table" and c.ready or {}
    local partial=type(c.partial)=="table" and c.partial or {}
    local unknown=type(c.unknown)=="table" and c.unknown or {}
    local review=type(c.review)=="table" and c.review or {}
    local protected=type(c.protected)=="table" and c.protected or {}
    local zeroStock=type(c.zeroStock)=="table" and c.zeroStock or {}

    local specs={
        {"all","ALL",nil,86},
        {"ready","READY",ready,112},
        {"partial","PARTIAL / SAFE",partial,142},
        {"unknown","UNKNOWN COST",unknown,132},
        {"review","REVIEW",review,110},
        {"protected","FORMULA-PROTECTED",protected,166},
        {"zeroStock","ZERO-STOCK",zeroStock,126},
    }
    local counts={ready=#ready,partial=#partial,unknown=#unknown,review=#review,protected=#protected,zeroStock=#zeroStock}
    counts.all=#ready+#partial+#unknown+#review+#protected+#zeroStock
    UI.coverageFilter=UI.coverageFilter or "all"

    local x,y=0,-58
    for i,spec in ipairs(specs) do
        if i==5 then x=0; y=-88 end
        local key,label,list,w=spec[1],spec[2],spec[3],spec[4]
        local b=MakeButton(UI.content,string.format("%s %d",label,counts[key] or 0),w,24)
        b:SetPoint("TOPLEFT",x,y); x=x+w+6
        if key==UI.coverageFilter then
            local fs=b.GetFontString and b:GetFontString() or nil
            if fs then fs:SetTextColor(1,.82,.20) end
            if b.LockHighlight then b:LockHighlight() end
        end
        b:SetScript("OnClick",function()
            UI.coverageFilter=key; UI.listPage=1; if UI.coverageSort then UI.coverageSort.page=1 end; RenderPage()
        end)
        b:SetScript("OnEnter",function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
                GameTooltip:AddLine(label.." — "..tostring(counts[key] or 0).." item"..((counts[key] or 0)==1 and "" or "s"),1,.82,0)
                if key=="all" then
                    GameTooltip:AddLine("Click to show every Cost Coverage category in the list below.",1,1,1,true)
                else
                    GameTooltip:AddLine("Click to show only "..label.." items in the list below.",1,1,1,true)
                end
                if key=="partial" then GameTooltip:AddLine("PARTIAL / SAFE items have a trusted basis for some units while unresolved units remain excluded.",.75,.75,.75,true) end
                if key=="review" then GameTooltip:AddLine("REVIEW is the category that requires a provenance decision.",.75,.75,.75,true) end
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    end

    UI.coverageSort=UI.coverageSort or {key="name",ascending=true,page=1}
    _G.UBKTableUI.DrawSearch({UI=UI,MakeText=MakeText,MakeButton=MakeButton},UI.content,UI.coverageSort,446,-94,360,RenderPage)
    local categoryLists={ready=ready,partial=partial,unknown=unknown,review=review,protected=protected,zeroStock=zeroStock}
    local categoryLabels={ready="READY",partial="PARTIAL / SAFE",unknown="UNKNOWN COST",review="REVIEW",protected="FORMULA-PROTECTED",zeroStock="ZERO-STOCK"}
    local order={"partial","unknown","review","ready","protected","zeroStock"}
    local rows={}
    local function AddCategory(key)
        for _,item in ipairs(categoryLists[key] or {}) do
            local name=API.GetItemName and API:GetItemName(item) or item
            if _G.UBKTableUI.NameMatches(name,UI.coverageSort.search) then rows[#rows+1]={kind=categoryLabels[key],key=key,item=item} end
        end
    end
    if UI.coverageFilter=="all" then
        for _,key in ipairs(order) do AddCategory(key) end
    elseif categoryLists[UI.coverageFilter] then
        AddCategory(UI.coverageFilter)
    else
        UI.coverageFilter="all"
        for _,key in ipairs(order) do AddCategory(key) end
    end

    local showing=MakeText(UI.content,"GameFontDisableSmall")
    showing:SetPoint("TOPLEFT",0,-118)
    showing:SetText("Showing: "..(UI.coverageFilter=="all" and "ALL CATEGORIES" or (categoryLabels[UI.coverageFilter] or "ALL CATEGORIES")))
    showing:SetTextColor(.72,.62,.40)

    for _,xrow in ipairs(rows) do
        local b=API:GetBasisInfo(xrow.item)
        xrow.itemString=xrow.item; xrow.name=b and b.name or xrow.item
        xrow.known=b and tonumber(b.knownQty) or 0
        xrow.owned=b and tonumber(b.observedQty) or 0
        xrow.unresolved=b and tonumber(b.unresolvedQty) or 0
        xrow.basis=b and b.basis or nil
        local ownership=API.GetBasisPricingOwnershipInfo and API:GetBasisPricingOwnershipInfo(xrow.item)
        if ownership and ownership.protected then xrow.action="Use Basis Pricing"; xrow.actionKind="adopt"
        elseif xrow.unresolved>0 then xrow.action="Resolve Unknown"; xrow.actionKind="resolve"
        elseif ownership and ownership.canRestore then xrow.action="Restore Formula"; xrow.actionKind="restore"
        elseif xrow.key=="review" then xrow.action="Review Cost"; xrow.actionKind="review" end
    end
    local function TakeAction(row)
        if row.actionKind=="resolve" then ShowResolveUnknownDialog(row.itemString); return
        elseif row.actionKind=="review" then UI.coverageSection="review"; UI.reviewSelected=row.itemString; RenderPage(); return end
        local ok,result
        if row.actionKind=="adopt" then ok,result=API:AdoptBasisPricing(row.itemString)
        elseif row.actionKind=="restore" then ok,result=API:RestoreBasisPricingOverride(row.itemString) end
        if not ok then print("|cffff7777UBK:|r "..tostring(result or "No cost action is available."))
        elseif result.costPending then print("|cffffcc00UBK:|r Basis pricing selected for "..row.name..". Cost stays unavailable until a recorded acquisition or vendor cost exists.")
        elseif result.reloadRecommended then print("|cff33ff99UBK:|r Material cost selected for "..row.name..". /reload refreshes TSM's cached crafting displays.") end
        RenderPage()
    end
    local function ActionHelp(row)
        if row.actionKind=="adopt" then return "Use UBK basis / recorded purchase / vendor cost. Stock TSM receives a material cost through UBK's normal write bridge; an available native integration stays native. The previous formula is saved. Unknown costs remain unavailable. Stock TSM may need /reload to refresh cached displays." end
        if row.actionKind=="restore" then return "Restore the saved formula and pause automatic cost writes for this item. Acquisition records and inventory do not change." end
        if row.actionKind=="resolve" then return "Enter the actual per-unit cost for only the unknown units. Review the projected blended basis before applying it. Known units are not rebased." end
        return "Review the acquisition evidence for this item inside Cost Coverage."
    end
    UI.coverageSort=UI.coverageSort or {key="name",ascending=true,page=1}
    local grid=_G.UBKTableUI
    if grid then
        grid.Render({UI=UI,MakeText=MakeText,MakeButton=MakeButton},{y=-143,
            height=math.max(145,UI.content:GetHeight()-149),rows=rows,state=UI.coverageSort,
            columns={
                {key="name",label="Item",width=184},
                {key="kind",label="Cost status",width=162},
                {key="known",label="Known",width=64,align="RIGHT"},
                {key="owned",label="Owned",width=64,align="RIGHT"},
                {key="unresolved",label="Unknown",width=74,align="RIGHT"},
                {key="basis",label="Basis / unit",width=100,align="RIGHT",text=function(r) return r.basis and Money(r.basis) or "n/a" end},
                {key="action",label="Cost action",width=148,action=TakeAction,actionText=function(r) return r.action end,actionTooltip=ActionHelp},
            },onChange=RenderPage,onClick=function(r) ShowMarketItem(r.itemString) end,
            onEnter=function(frame,r) ShowItemTooltip(frame,r.itemString,"ANCHOR_RIGHT") end,
            emptyText="No items match this name and cost category. Clear the name search or choose ALL."})
    end
end

local SETTING_SPECS={
    {"deepCostPct","DEEP ≤ % of trusted cost",true},{"lowCostPct","LOW ≤ % of trusted cost",true},{"regionDiscountLook","REGION CHEAP ≤ % of region",true},
    {"saleRateStrong","FAST sale rate threshold",false},{"saleRateHealthy","Healthy sale rate threshold",false},{"soldPerDayStrong","FAST sold/day threshold",false},{"soldPerDayHealthy","Healthy sold/day threshold",false},
    {"highEndCachedPct","High-end cached prefilter ≤ %",true},{"commonCachedPct","Common cached prefilter ≤ %",true},{"rareCachedPct","Rare cached prefilter ≤ %",true},
}
local function ImportNewestTSMData()
    if not API or type(API.ImportNewestTSMData)~="function" then
        UI.homeStatus="This UBK build does not expose the TSM import workflow."
        print("|cffff7777UBK:|r "..UI.homeStatus)
        RenderPage()
        return
    end
    local called,ok,info=pcall(function() return API:ImportNewestTSMData() end)
    if not called or not ok then
        local why=called and info or ok
        UI.homeStatus="TSM import did not complete: "..tostring(why or "unknown reason")
        print("|cffff7777UBK:|r "..UI.homeStatus)
        RenderPage()
        return
    end
    info=type(info)=="table" and info or {}
    RefreshWatchlist(false)
    InvalidatePositionIntelligenceCache()
    if CPCaptureAndAlert then CPCaptureAndAlert("tsm-import") end
    local reviews=tonumber(info.reviewCount) or 0
    local place=tostring(info.realm or "Unknown realm").." - "..tostring(info.faction or "Unknown faction")
    if reviews>0 then
        UI.importWorkflowActive=true
        UI.homeStatus=string.format("TSM data imported for %s. Resolve %d cost question%s in Cost Coverage to finish.",place,reviews,reviews==1 and "" or "s")
        print("|cffffcc00UBK:|r "..UI.homeStatus)
        UI.coverageSection="review"
        UI.reviewSelected=nil
        NavigateRoot("coverage")
        return
    end
    UI.importWorkflowActive=false
    UI.homeStatus=info.marketChanged and ("Newest loaded TSM/AppHelper data imported for "..place..". Your accounting is ready.")
        or ("TSM/AppHelper data was already current for "..place.."; UBK accounting was checked.")
    print("|cff33ff99UBK:|r "..UI.homeStatus)
    NavigateRoot("home")
end

local function RenderHome()
    PageTitle("Universal Basis Keeper","Your acquisition costs, positions, and market work in one place.")
    local sell=MakeButton(UI.content,"Sell Above Basis",170,27); sell:SetPoint("TOPRIGHT",-8,-4)
    sell:SetScript("OnClick",function() if _G.UBKBasisSale then _G.UBKBasisSale:Show() end end)
    local unavailable={}
    local function SafeTable(method)
        if not API or type(API[method])~="function" then unavailable[method]=true; return {} end
        local ok,result=pcall(function() return API[method](API) end)
        if ok and type(result)=="table" then return result end
        unavailable[method]=true
        return {}
    end
    local setup=SafeTable("GetSetupStatus")
    local coverage=SafeTable("GetCoverage")
    local review=SafeTable("GetReviewItems")
    local shred=SafeTable("GetShredderState")
    local context=SafeTable("GetRuntimeContext")
    local _,fallbackRealm,fallbackFaction=ScopeKey()
    local realm=(context.realm and context.realm~="") and context.realm or fallbackRealm
    local faction=(context.faction and context.faction~="") and context.faction or fallbackFaction
    local function Count(key)
        return type(coverage[key])=="table" and #coverage[key] or 0
    end
    local total=Count("ready")+Count("partial")+Count("unknown")+Count("review")+Count("protected")+Count("zeroStock")
    local status=MakeText(UI.content,"GameFontHighlightSmall")
    status:SetPoint("TOPLEFT",10,-62); status:SetPoint("RIGHT",-10,0)
    status:SetText(string.format("%s - %s   |   Setup: %s   |   %s coverage items   |   %s cost questions",realm or "Unknown realm",faction or "Neutral",tostring(setup.status or "unavailable"):upper(),unavailable.GetCoverage and "unavailable" or tostring(total),unavailable.GetReviewItems and "unavailable" or tostring(#review)))
    local note=MakeText(UI.content,"GameFontDisableSmall")
    note:SetPoint("TOPLEFT",10,-85); note:SetPoint("RIGHT",-10,0)
    note:SetText(next(unavailable) and "Some UBK services are unavailable. Unavailable counts are not zero; check that UBK and its interface are the same version."
        or UI.homeStatus or "Open a coverage category to resolve its costs, or choose a workspace for the positions you are working on.")
    if note.SetWordWrap then note:SetWordWrap(true) end

    local import=MakeButton(UI.content,setup.status=="pending" and "Import TSM / Begin Setup" or "Import Newest TSM Data",250,30)
    import:SetPoint("TOPLEFT",10,-121); import:SetScript("OnClick",ImportNewestTSMData)
    import:SetEnabled(API and type(API.ImportNewestTSMData)=="function")
    AddButtonTooltip(import,"Import Newest TSM Data","Refresh UBK from the TSM data loaded in this session. Any outstanding acquisition-cost questions open inside Cost Coverage; completed imports return here.","If the desktop app refreshed AppHelper while you were logged in, /reload first so WoW loads that update.")
    local refresh=MakeButton(UI.content,"Refresh UBK Accounting",220,30)
    refresh:SetPoint("LEFT",import,"RIGHT",12,0)
    refresh:SetEnabled(API and type(API.RefreshAccounting)=="function")
    refresh:SetScript("OnClick",function()
        local ok,result=pcall(function() return API:RefreshAccounting() end)
        if ok and result then UI.homeStatus="UBK accounting refresh completed."; InvalidatePositionIntelligenceCache()
        elseif ok then UI.homeStatus="UBK accounting refresh did not complete."
        else UI.homeStatus="UBK accounting refresh failed: "..tostring(result) end
        RenderPage()
    end)
    AddButtonTooltip(refresh,"Refresh UBK Accounting","Process newly recorded purchase and inventory evidence now. Resolve remaining unknown quantities in Cost Coverage.","This uses recorded evidence and does not assign invented costs.")
    local evidenceCount=MarketEvidenceCount()
    local maturity=MakeText(UI.content,"GameFontDisableSmall")
    maturity:SetPoint("TOPLEFT",510,-122); maturity:SetWidth(390)
    maturity:SetText(evidenceCount>=30 and "Market evidence: Mature (30+ distinct updates)" or string.format("Market evidence: %d / 30 distinct updates",evidenceCount))
    maturity:SetTextColor(evidenceCount>=30 and .38 or 1,evidenceCount>=30 and 1 or .78,evidenceCount>=30 and .42 or .25)
    if maturity.SetWordWrap then maturity:SetWordWrap(true) end

    local function CoverageAction(filter,section)
        UI.coverageFilter=filter or "all"
        UI.coverageSection=section or "coverage"
        UI.reviewSelected=nil
        NavigateRoot("coverage")
    end
    local leftTitle=MakeText(UI.content,"GameFontNormal")
    leftTitle:SetPoint("TOPLEFT",10,-177); leftTitle:SetText("COST COVERAGE")
    local countTitle=MakeText(UI.content,"GameFontNormalSmall")
    countTitle:SetPoint("TOPLEFT",218,-178); countTitle:SetWidth(60); countTitle:SetJustifyH("RIGHT"); countTitle:SetText("Items")
    local actionTitle=MakeText(UI.content,"GameFontNormalSmall")
    actionTitle:SetPoint("TOPLEFT",304,-178); actionTitle:SetText("Action")
    local rightTitle=MakeText(UI.content,"GameFontNormal")
    rightTitle:SetPoint("TOPLEFT",510,-177); rightTitle:SetText("YOUR WORKSPACES")
    local header=UI.content:CreateTexture(nil,"ARTWORK")
    header:SetColorTexture(.55,.43,.23,1); header:SetHeight(1)
    header:SetPoint("TOPLEFT",10,-195); header:SetPoint("TOPRIGHT",-20,-195)
    local specs={
        {"ready","Ready",Count("ready"),"Inspect","See items whose recorded cost covers their inventory."},
        {"partial","Partial / safe",Count("partial"),"Resolve","Review known-cost units alongside quantities still missing a cost."},
        {"unknown","Unknown cost",Count("unknown"),"Resolve","Open items that need acquisition evidence or a cost decision."},
        {"review","Cost questions",#review,"Review","Open the Cost Review section within Cost Coverage.","review"},
        {"protected","Formula-protected",Count("protected"),"Review formulas","Inspect protected formulas and choose which items should use basis pricing."},
        {"zeroStock","Zero-stock",Count("zeroStock"),"Inspect","Review recorded costs for items with no current tracked stock."},
    }
    for i,spec in ipairs(specs) do
        local y=-207-(i-1)*35
        local label=MakeText(UI.content,"GameFontHighlightSmall")
        label:SetPoint("TOPLEFT",14,y-6); label:SetWidth(198); label:SetText(spec[2])
        local count=MakeText(UI.content,"GameFontNormalSmall")
        local missing=spec[6]=="review" and unavailable.GetReviewItems or (spec[6]~="review" and unavailable.GetCoverage)
        count:SetPoint("TOPLEFT",218,y-6); count:SetWidth(60); count:SetJustifyH("RIGHT"); count:SetText(missing and "n/a" or tostring(spec[3]))
        local b=MakeButton(UI.content,spec[4],172,26); b:SetPoint("TOPLEFT",304,y)
        b:SetEnabled(not missing)
        b:SetScript("OnClick",function() CoverageAction(spec[1],spec[6]) end)
        AddButtonTooltip(b,spec[2],spec[5])
        local line=UI.content:CreateTexture(nil,"ARTWORK"); line:SetColorTexture(.26,.24,.18,1)
        line:SetSize(470,1); line:SetPoint("TOPLEFT",10,y-31)
    end
    local all=MakeButton(UI.content,"Open All Cost Coverage",466,28); all:SetPoint("TOPLEFT",10,-428)
    all:SetEnabled(not unavailable.GetCoverage)
    all:SetScript("OnClick",function() CoverageAction("all") end)
    AddButtonTooltip(all,"All Cost Coverage","Open the full coverage list, with Cost Review available on the same page.")
    local function NavButton(y,label,page,tip,section)
        local b=MakeButton(UI.content,label,390,28); b:SetPoint("TOPLEFT",510,y)
        b:SetScript("OnClick",function()
            if page=="position" then UI.positionSection=section or "positions" end
            NavigateRoot(page)
        end)
        AddButtonTooltip(b,label,tip)
    end
    NavButton(-207,POSITION_INTELLIGENCE_LABEL,"position","Review holdings, unit value, acquisition basis, and sale opportunities.")
    NavButton(-242,"Chum Scanner","chum","Find unusually low loaded prices against trusted UBK basis; available away from the Auction House.")
    NavButton(-277,CROSS_PRESSURE_LABEL,"cross","Keep track of the linked markets and material plays you are working on.")
    NavButton(-312,"Market Inspector","market","Inspect an item's acquisition basis and loaded market data, with cost resolution beside the coverage row.")
    NavButton(-347,"Watchlist","watch","Compare watched markets and sort their dates, values, types, and sale activity.")
    NavButton(-382,"Ore Prospecting","position","Compare ore acquisition costs with expected raw-gem proceeds inside Position Intelligence.","prospecting")
    NavButton(-428,"Settings","settings","Adjust cost-discount signals, liquidity labels, alerts, and window scale.")
    local health=MakeText(UI.content,"GameFontDisableSmall")
    health:SetPoint("TOPLEFT",10,-480); health:SetPoint("RIGHT",-20,0)
    local coverageText=unavailable.GetCoverage and "Coverage data is unavailable." or string.format("Coverage: %d ready  |  %d partial  |  %d unknown  |  %d review  |  %d formula-protected  |  %d zero-stock",Count("ready"),Count("partial"),Count("unknown"),Count("review"),Count("protected"),Count("zeroStock"))
    local transformText=unavailable.GetShredderState and "Transform tracking is unavailable." or string.format("Transform tracking: %s  |  %d pending inventory settlements",tostring(shred.enchanter or "not configured"),tonumber(shred.pendingTransforms) or 0)
    health:SetText(coverageText.."\n"..transformText)
    if health.SetWordWrap then health:SetWordWrap(true) end
end

local function RenderSettings()
    PageTitle("Settings","Hover an input for its units, a worked example, and where it applies. These values do not change acquisition costs.")
    local scanners=ScannerModule()
    local settingsLoaded,cfg=false,{}
    if scanners and type(scanners.GetSettings)=="function" then
        local ok,result=pcall(scanners.GetSettings,scanners)
        if ok and type(result)=="table" then settingsLoaded=true; cfg=result end
    end
    local help={
        deepCostPct={"Percent of trusted cost","DEEP marks a cached price at or below this share of trusted unit basis. It takes priority over LOW in Watchlist and Position Intelligence signals.","Enter 65 for 65%. At a 10g basis (100,000c), a loaded price of 6g50s or less is DEEP."},
        lowCostPct={"Percent of trusted cost","LOW marks a cached price at or below this share of trusted unit basis, when it did not already qualify as DEEP. Used by Watchlist and Position Intelligence signals.","Enter 75 for 75%. At a 10g basis, 7g50s or less is LOW; with DEEP at 65%, 6g50s or less is DEEP instead."},
        regionDiscountLook={"Percent of regional reference","REGION CHEAP compares the loaded cached price with the available regional price reference. That reference averages available regional market, historical, and sale-average prices. Used by cached market signals and contextual scoring.","Enter 80 for 80%. If the regional reference is 20g, a loaded price of 16g or less qualifies. This does not change your basis."},
        saleRateStrong={"Sale rate as a fraction (0 to 1)","The market receives an ACTIVE / FAST liquidity label when regional sale rate reaches this threshold OR sold/day reaches the FAST sold/day threshold. It is regional activity, not a promise that your listing will sell.","Enter 0.20 for a 20% sale rate. A rate of 0.20 qualifies even if sold/day is below its separate FAST threshold."},
        saleRateHealthy={"Sale rate as a fraction (0 to 1)","If neither FAST threshold is met, the market is HEALTHY when regional sale rate reaches this value OR sold/day reaches the Healthy sold/day threshold. Positive activity below both healthy thresholds is THIN.","Enter 0.08 for 8%. With FAST at 0.20, a rate of 0.10 is HEALTHY unless sold/day independently qualifies it as FAST."},
        soldPerDayStrong={"Regional items sold per day","The market receives an ACTIVE / FAST liquidity label when regional average sold/day reaches this value OR sale rate reaches the FAST sale-rate threshold. Used in market context, Watchlist, and Position Intelligence.","Enter 5 for five items per day. Sold/day of 6 qualifies even with a sale rate below the FAST threshold. This is not six guaranteed sales on your realm."},
        soldPerDayHealthy={"Regional items sold per day","If neither FAST threshold is met, sold/day at this value or higher produces HEALTHY liquidity. Sale rate can independently produce the same label; positive activity below both thresholds is THIN.","Enter 1 for one item per day. With FAST at 5, 2 sold/day is HEALTHY unless the sale rate independently qualifies as FAST."},
    }
    UI.settingBoxes={}
    local row=0
    for _,s in ipairs(SETTING_SPECS) do
        if help[s[1]] then
            row=row+1
            local y=-82-(row-1)*47
            local l=MakeText(UI.content,"GameFontHighlightSmall")
            l:SetPoint("TOPLEFT",12,y); l:SetWidth(300); l:SetText(s[2])
            local eb=CreateFrame("EditBox",nil,UI.content,"InputBoxTemplate")
            eb:SetSize(110,26); eb:SetPoint("TOPLEFT",326,y+5); eb:SetAutoFocus(false)
            local v=cfg[s[1]]
            local original=v~=nil and (s[3] and string.format("%.1f",v*100) or tostring(v)) or ""
            eb:SetText(original)
            eb:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
            local details=help[s[1]]
            AddButtonTooltip(eb,s[2].." — "..details[1],details[2],details[3])
            UI.settingBoxes[s[1]]={box=eb,pct=s[3],original=original,value=v,label=s[2]}
            local unit=MakeText(UI.content,"GameFontDisableSmall")
            unit:SetPoint("LEFT",eb,"RIGHT",12,0)
            unit:SetText(s[3] and "%" or (s[1]:find("saleRate",1,true) and "0–1" or "items/day"))
        end
    end
    local status=MakeText(UI.content,"GameFontHighlightSmall")
    status:SetPoint("TOPLEFT",12,-466); status:SetWidth(482)
    if status.SetWordWrap then status:SetWordWrap(true) end
    status:SetText(not settingsLoaded and "UBK's settings service is unavailable. Its values could not be loaded; no defaults have been substituted."
        or UI.settingsStatus or "Only edited fields are applied. Stored values stay unchanged when you open this page.")
    local save=MakeButton(UI.content,"Apply Settings",180,28); save:SetPoint("TOPLEFT",12,-426)
    save:SetEnabled(settingsLoaded)
    save:SetScript("OnClick",function()
        local module=ScannerModule()
        if not settingsLoaded or not module or type(module.SetSetting)~="function" then status:SetText("The settings service is unavailable."); return end
        local edits={}
        for key,o in pairs(UI.settingBoxes) do
            local text=o.box:GetText()
            if text~=o.original then
                local v=tonumber(text)
                if not v or v~=v or v==math.huge or v==-math.huge or v<0 or (key:find("saleRate",1,true) and v>1) then
                    status:SetText(o.label..": enter a nonnegative number"..(key:find("saleRate",1,true) and " from 0 to 1." or "."))
                    o.box:SetFocus(); return
                end
                edits[#edits+1]={key=key,value=o.pct and v/100 or v,previous=o.value}
            end
        end
        if #edits==0 then status:SetText("No settings changed."); return end
        for index,edit in ipairs(edits) do
            local called,ok=pcall(module.SetSetting,module,edit.key,edit.value)
            if not called or not ok then
                local restored=true
                for prior=1,index-1 do
                    local old=edits[prior]
                    local restoredCall,restoredOK=pcall(module.SetSetting,module,old.key,old.previous)
                    if not restoredCall or not restoredOK then restored=false end
                end
                status:SetText("Could not apply "..edit.key..(restored and ". Previously changed fields were restored." or ". Some earlier fields could not be restored; reopen Settings to check their saved values.")); return
            end
        end
        InvalidatePositionIntelligenceCache()
        RefreshWatchlist(false)
        UI.settingsStatus="Settings applied. Watchlist and position signals will use the new thresholds."
        RenderPage()
    end)
    AddButtonTooltip(save,"Apply Settings","Validate every edited field before saving it. Percent fields use 65 for 65%; sale-rate fields use 0.20 for 20%.","Rebuilds cached position signals and refreshes Watchlist context without sending an Auction House query.")
    local db=EnsureDB()
    local prefTitle=MakeText(UI.content,"GameFontNormal")
    prefTitle:SetPoint("TOPLEFT",550,-66); prefTitle:SetText("DISPLAY AND ALERTS")
    local login=MakeButton(UI.content,db.settings.loginSummary and "Login Summary: ON" or "Login Summary: OFF",270,28)
    login:SetPoint("TOPLEFT",550,-94)
    login:SetScript("OnClick",function() db.settings.loginSummary=not db.settings.loginSummary; RenderPage() end)
    AddButtonTooltip(login,"Login Summary","Print the number of watched items, changed observations, and loaded market-data ages when you log in.","Saved for this realm and faction; it does not open a scan.")
    local changes=MakeButton(UI.content,db.settings.alertSignalChanges and "Signal Alerts: ON" or "Signal Alerts: OFF",270,28)
    changes:SetPoint("TOPLEFT",550,-133)
    changes:SetScript("OnClick",function() db.settings.alertSignalChanges=not db.settings.alertSignalChanges; RenderPage() end)
    AddButtonTooltip(changes,"Signal Alerts","Show changed Watchlist signal labels with the login summary, and meaningful Cross-Pressure state changes when evidence is captured.","A price update may change LOW to DEEP or move a playbook to WATCH. An alert is informational; it places no orders.")
    local scaleLabel=MakeText(UI.content,"GameFontNormalSmall")
    scaleLabel:SetPoint("TOPLEFT",550,-191); scaleLabel:SetText(string.format("UBK Window Scale: %.0f%%",(db.uiScale or 1)*100))
    local sx=550
    for _,pct in ipairs({75,90,100,115,130}) do
        local b=MakeButton(UI.content,tostring(pct).."%",56,24); b:SetPoint("TOPLEFT",sx,-216); sx=sx+60
        b:SetScript("OnClick",function() ApplyUIScale(pct/100,true); RenderPage() end)
        AddButtonTooltip(b,"Window scale: "..pct.."%","Scale the full UBK window, including text, rows, and controls. The layout keeps its column alignment.","Drag the lower-right corner, or Shift-drag the window, to choose another size. Your available screen area can limit the applied scale.")
    end
    local note=MakeText(UI.content,"GameFontDisableSmall")
    note:SetPoint("TOPLEFT",550,-266); note:SetWidth(338)
    note:SetText("Cost signals compare loaded prices with your basis; liquidity describes regional activity.\n\nThese controls do not change TSM operations or acquisition costs.")
    if note.SetWordWrap then note:SetWordWrap(true) end
    local enchanterTitle=MakeText(UI.content,"GameFontNormalSmall")
    enchanterTitle:SetPoint("TOPLEFT",note,"BOTTOMLEFT",0,-16); enchanterTitle:SetHeight(20); enchanterTitle:SetText("Disenchanting character")
    local enchanter=CreateFrame("EditBox",nil,UI.content,"InputBoxTemplate")
    enchanter:SetSize(195,25); enchanter:SetPoint("TOPLEFT",enchanterTitle,"BOTTOMLEFT",5,-8); enchanter:SetAutoFocus(false)
    local shredLoaded,shredState=false,{}
    if API and type(API.GetShredderState)=="function" then
        local ok,result=pcall(API.GetShredderState,API)
        if ok and type(result)=="table" then shredLoaded=true; shredState=result end
    end
    enchanter:SetText(type(shredState.enchanter)=="string" and shredState.enchanter or "")
    enchanter:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
    AddButtonTooltip(enchanter,"Disenchanting character","Enter the character name exactly as it appears in TSM's inventory records. Owned to Shred uses this choice to distinguish gear ready in that character's bags from gear stored or held by other characters.","Example: enter Enchantingalt to identify that character's bags as READY. A blank field means no character has been chosen. This setting does not send mail or disenchant items.")
    local enchanterStatus=MakeText(UI.content,"GameFontDisableSmall")
    enchanterStatus:SetPoint("TOPLEFT",enchanter,"BOTTOMLEFT",-5,-10); enchanterStatus:SetWidth(338); enchanterStatus:SetHeight(44)
    enchanterStatus:SetText(not shredLoaded and "The disenchanting settings could not be loaded." or UI.enchanterStatus or (shredState.enchanter and "Used only for Owned to Shred location guidance." or "Choose a character to enable location guidance."))
    if enchanterStatus.SetWordWrap then enchanterStatus:SetWordWrap(true) end
    local setEnchanter=MakeButton(UI.content,"Save Character",125,26); setEnchanter:SetPoint("LEFT",enchanter,"RIGHT",16,0)
    setEnchanter:SetEnabled(shredLoaded and API and type(API.SetShredderEnchanter)=="function")
    setEnchanter:SetScript("OnClick",function()
        if not shredLoaded or not API or type(API.SetShredderEnchanter)~="function" then enchanterStatus:SetText("The disenchanting settings service is unavailable."); return end
        local called,ok,err=pcall(API.SetShredderEnchanter,API,enchanter:GetText())
        if not called or not ok then enchanterStatus:SetText("Character was not saved: "..tostring(called and err or ok)); return end
        UI.enchanterStatus="Character saved. Owned to Shred will use this name for location guidance."
        enchanter:ClearFocus(); RenderPage()
    end)
    local sources=MakeButton(UI.content,"TSM Sources & Integration",300,28); sources:SetPoint("TOPLEFT",enchanterStatus,"BOTTOMLEFT",0,-18)
    sources:SetEnabled(type(_G.UBKSourceGuide)=="table" and type(_G.UBKSourceGuide.Show)=="function")
    sources:SetScript("OnClick",function()
        if type(_G.UBKSourceGuide)=="table" and type(_G.UBKSourceGuide.Show)=="function" then
            _G.UBKSourceGuide.Show({UI=UI,API=API,MakeText=MakeText,MakeButton=MakeButton,Money=Money})
        end
    end)
    AddButtonTooltip(sources,"TSM Sources & Integration","Read UBK's native TSM sources, their cost rules, and the custom aliases currently using them.","This reference does not create aliases or change your TSM operations.")
end

local function InterfaceContext()
    return {
        UI=UI,API=API,MakeButton=MakeButton,MakeText=MakeText,Money=Money,Age=Age,
        ItemName=ItemName,ItemTexture=ItemTexture,ShowItemTooltip=ShowItemTooltip,
        ShowMarketItem=ShowMarketItem,AddWatch=AddWatch,RemoveWatch=RemoveWatch,
        RefreshWatchlist=RefreshWatchlist,PositionIntelligenceRows=PositionIntelligenceRows,
        InvalidatePositionIntelligenceCache=InvalidatePositionIntelligenceCache,
        EnsureDB=EnsureDB,PageTitle=PageTitle,AddPager=AddPager,RowsFor=RowsFor,
        RenderPage=RenderPage,CPCaptureAndAlert=CPCaptureAndAlert,
        AddButtonTooltip=AddButtonTooltip,OpenTestArena=OpenTestArena,
    }
end

local function RenderPositionWorkspace()
    local ctx=InterfaceContext()
    local section=UI.positionSection or "positions"
    if section=="prospecting" then
        PageTitle("Shredder — Ore Prospecting","Read the loaded ore and raw-gem prices, then compare the expected gold return from five ore.")
        if _G.UBKProspectingUI then _G.UBKProspectingUI.Render(ctx) end
    elseif section=="disenchant" then
        if _G.UBKShredInventoryUI then _G.UBKShredInventoryUI.Render(ctx) end
    else
        ctx.TableTopOffset=38
        if _G.UBKPositionWatchUI then _G.UBKPositionWatchUI.RenderPositions(ctx) end
    end
    for i,spec in ipairs({{"positions","Positions",128},{"prospecting","Shredder: Ores",150},{"disenchant","Owned to Shred",150}}) do
        local x=i==1 and 6 or (i==2 and 142 or 300)
        local button=MakeButton(UI.content,spec[2],spec[3],25)
        button:SetPoint("TOPLEFT",x,-54)
        if spec[1]==section then button:Disable() end
        button:SetScript("OnClick",function() UI.positionSection=spec[1]; UI.listPage=1; RenderPage() end)
    end
end

RenderPage=function()
    CreateWindow(); ClearContent()
    local activePage=UI.page=="testarena" and UI.testArenaSession and UI.testArenaSession.activeTab or UI.page
    for key,b in pairs(UI.navButtons or {}) do
        if key==activePage and b.LockHighlight then b:LockHighlight()
        elseif b.UnlockHighlight then b:UnlockHighlight() end
    end
    -- The Test Arena is intentionally dispatched before the UBK dependency
    -- check. Its fixtures and reducers are self-contained and never need a
    -- live engine, SavedVariables, TSM, or Auction House state.
    if UI.page=="testarena" then RenderTestArena(); return end
    if not NeedAPI(false) then return end
    if UI.page=="home" then RenderHome()
    elseif UI.page=="chum" then RenderChumScanner()
    elseif UI.page=="cross" then RenderCrossPressure()
    elseif UI.page=="position" then RenderPositionWorkspace()
    elseif UI.page=="market" then RenderMarket()
    elseif UI.page=="watch" then if _G.UBKPositionWatchUI then _G.UBKPositionWatchUI.RenderWatch(InterfaceContext()) end
    elseif UI.page=="coverage" then RenderCoverage()
    elseif UI.page=="settings" then RenderSettings() end
    if _G.UBKWindowFocus then _G.UBKWindowFocus.RegisterChildren(UI.root) end
end

local function IsCraftHostVisible(root)
    return root and ((root.IsVisible and root:IsVisible()) or (not root.IsVisible and root.IsShown and root:IsShown())) and true or false
end

local function TSMCraftHostFor(child)
    local candidate=child
    for _=1,40 do
        if not candidate or candidate==UIParent or candidate==WorldFrame then return nil end
        local name=candidate.GetName and candidate:GetName() or ""
        -- These are the actual debug names assigned by TSM UIElements.CreateFrame.
        -- Main, Auction, Crafting, Mailing and Vendor use LargeApplicationFrame;
        -- Banking and smaller TSM windows use ApplicationFrame.
        if type(name)=="string" and (name:match("^TSM_FRAME:LargeApplicationFrame:") or name:match("^TSM_FRAME:ApplicationFrame:") or name:match("^TSM_FRAME:OverlayApplicationFrame:")) then return candidate end
        candidate=candidate.GetParent and candidate:GetParent() or nil
    end
    return nil
end

local function FindTSMAuctionRoot()
    -- Historical helper name retained for the existing event hook. The host is
    -- now any visible TSM application window, never an auction action button.
    UI.craftHosts=UI.craftHosts or setmetatable({},{__mode="k"})
    local function Remember(candidate)
        local root=TSMCraftHostFor(candidate)
        if not root then return end
        local info=UI.craftHosts[root]
        if not info then
            info={}; UI.craftHosts[root]=info
            if root.HookScript then
                root:HookScript("OnShow",function(self) UI.craftActiveRoot=self end)
                root:HookScript("OnMouseDown",function(self) UI.craftActiveRoot=self; UI.craftClickedRoot=self end)
            end
        end
        local visible=IsCraftHostVisible(root)
        if visible and not info.visible then UI.craftActiveRoot=root end
        info.visible=visible
    end
    -- ApplicationFrame registers the root itself in UISpecialFrames, even
    -- though TSM clears ordinary debug-frame globals after constructing them.
    for _,name in ipairs(UISpecialFrames or {}) do Remember(_G[name]) end
    for _,name in ipairs({"TSMCraftingBtn","TSMAuctioningBtn","TSMCancelAuctionBtn","TSMShoppingBuyoutBtn","TSMDestroyBtn"}) do Remember(_G[name]) end
    Remember(UI.craftProfessionRoot)
    for root,info in pairs(UI.craftHosts) do info.visible=IsCraftHostVisible(root) end
    if IsCraftHostVisible(UI.craftClickedRoot) then UI.craftActiveRoot=UI.craftClickedRoot end
    UI.craftClickedRoot=nil
    if IsCraftHostVisible(UI.craftActiveRoot) then return UI.craftActiveRoot end
    local selected,level
    for root,info in pairs(UI.craftHosts) do
        if info.visible then
            local candidateLevel=root.GetFrameLevel and root:GetFrameLevel() or 0
            if not selected or candidateLevel>(level or 0) then selected=root;level=candidateLevel end
        end
    end
    UI.craftActiveRoot=selected
    return selected
end

local function GetTSMCraftNextButton()
    local b=_G.TSMCraftingBtn
    return b and type(b.Click)=="function" and b or nil
end

local function IsTSMProfessionWindowOpen()
    local api=_G.TSM_API
    if type(api)=="table" and type(api.IsUIVisible)=="function" then
        local ok,visible=pcall(api.IsUIVisible,"CRAFTING")
        if ok and visible then return true end
    end
    if IsCraftHostVisible(UI.craftProfessionRoot) then return true end
    if IsCraftHostVisible(_G.TradeSkillFrame) or IsCraftHostVisible(_G.CraftFrame) then return true end
    return IsCraftHostVisible(GetTSMCraftNextButton())
end

local function GetTSMCraftingQueueCount()
    if type(_G.TradeSkillMasterDB)~="table" then return 0,false end
    local faction=UnitFactionGroup and UnitFactionGroup("player") or nil
    local realm=GetRealmName and GetRealmName() or nil
    if not faction or not realm then return 0,false end
    local queue=_G.TradeSkillMasterDB["f@"..faction.." - "..realm.."@internalData@craftingQueue"]
    if type(queue)~="table" then return 0,false end
    local total=0
    for _,qty in pairs(queue) do
        qty=tonumber(qty) or 0
        if qty>0 and qty<math.huge then total=total+qty end
    end
    return total,true
end

local function IsTSMCraftNextReady()
    if InCombatLockdown and InCombatLockdown() then return false,"Craft Next is unavailable during combat." end
    if not IsTSMProfessionWindowOpen() then return false,"Open a profession window to use Craft Next." end
    local b=GetTSMCraftNextButton()
    if not b or not IsCraftHostVisible(b) then return false,"Open TSM's Crafting page so its Craft Next action is available." end
    local queued,known=GetTSMCraftingQueueCount()
    if known and queued<=0 then return false,"TSM crafting queue is empty." end
    if not b.IsEnabled or not b:IsEnabled() then return false,"TSM Craft Next is not ready yet." end
    if known then return true,string.format("TSM Craft Next is ready — %d queued craft%s.",queued,queued==1 and "" or "s") end
    return true,"TSM Craft Next is ready."
end

local function UpdateCraftAssistant()
    local b=UI.craftNextButton
    if not b then return end
    if not IsCraftHostVisible(UI.craftAttachedRoot) or not IsTSMProfessionWindowOpen() then
        UI.craftNextReady=false
        UI.craftNextStatus="Open a TSM window and a profession window to use Craft Next."
        b:Hide()
        return
    end
    local ready,msg=IsTSMCraftNextReady()
    UI.craftNextReady=ready; UI.craftNextStatus=msg
    b:SetText("Craft Next"); b:SetEnabled(ready); b:SetAlpha(ready and 1 or .65); b:Show()
end

local function ClickTSMCraftNext()
    local source=GetTSMCraftNextButton()
    local ready,msg=IsTSMCraftNextReady()
    if not source or not ready then
        print("|cffffcc00UBK Craft:|r "..tostring(msg or "Craft Next is not ready."))
        UpdateCraftAssistant()
        return
    end
    -- The only crafting action in this feature: a real player click delegates
    -- exactly once. TSM chooses what and how much its own button can craft.
    local ok,err=pcall(function() source:Click("LeftButton") end)
    if not ok then print("|cffff4444UBK Craft:|r "..tostring(err)) end
    if C_Timer and C_Timer.After then C_Timer.After(.10,UpdateCraftAssistant) end
end

local function AnchorAuctionControls(root)
    local craft=UI.craftNextButton
    if not root or not craft or (InCombatLockdown and InCombatLockdown()) then return end
    -- Parent stays UIParent so this additional control is outside TSM's layout
    -- and clipping hierarchy. Match effective scale without resizing TSM.
    local rootScale=root.GetEffectiveScale and root:GetEffectiveScale() or 1
    local parentScale=UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
    if craft.SetScale and parentScale>0 then craft:SetScale(rootScale/parentScale) end
    craft:SetWidth(142); craft:ClearAllPoints(); craft:SetPoint("TOP",root,"BOTTOM",0,-6)
    if root.GetFrameStrata then craft:SetFrameStrata(root:GetFrameStrata()) end
    if root.GetFrameLevel then craft:SetFrameLevel(root:GetFrameLevel()+10) end
    UI.craftAttachedRoot=root
end

local function AttachCraftAssistant(root)
    if not root or not IsCraftHostVisible(root) then UpdateCraftAssistant(); return false end
    local b=UI.craftNextButton
    if not b then
        if InCombatLockdown and InCombatLockdown() then return false end
        b=MakeButton(UIParent,"Craft Next",142,26); UI.craftNextButton=b
        b:SetScript("OnClick",ClickTSMCraftNext)
        b:SetScript("OnEnter",function(self)
            if not GameTooltip then return end
            local _,message=IsTSMCraftNextReady()
            GameTooltip:SetOwner(self,"ANCHOR_BOTTOM")
            GameTooltip:AddLine("UBK Craft Next",1,.82,0)
            GameTooltip:AddLine(message or "Waiting for TSM.",1,1,1,true)
            GameTooltip:AddLine("One click runs TSM's Craft Next button once. TSM controls the current recipe and quantity.",.75,.75,.75,true)
            GameTooltip:AddLine("Follows the TSM window you select while a profession window is open.",.55,.85,1,true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    end
    AnchorAuctionControls(root)
    UpdateCraftAssistant()
    return true
end

local function StartCraftAssistantTicker()
    if UI.craftTicker or not C_Timer or not C_Timer.NewTicker then return end
    local function UpdateHost()
        local api=_G.TSM_API
        if not UI.craftCallbackRegistered and type(api)=="table" and type(api.RegisterUICallback)=="function" then
            local ok=pcall(api.RegisterUICallback,"CRAFTING","UniversalBasisKeeper:CraftNext",function(shown,root)
                UI.craftProfessionRoot=shown and root or nil
                if shown and root then UI.craftActiveRoot=root end
                local host=FindTSMAuctionRoot()
                if host then AttachCraftAssistant(host) else UpdateCraftAssistant() end
            end)
            if ok then UI.craftCallbackRegistered=true end
        end
        local root=FindTSMAuctionRoot()
        if root then AttachCraftAssistant(root) else UpdateCraftAssistant() end
    end
    if not UI.craftFocusEvents then
        local events=CreateFrame("Frame"); UI.craftFocusEvents=events
        local mouseRegistered=pcall(events.RegisterEvent,events,"GLOBAL_MOUSE_DOWN")
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
        events:RegisterEvent("PLAYER_REGEN_DISABLED")
        events:SetScript("OnEvent",function(_,event)
            if mouseRegistered and event=="GLOBAL_MOUSE_DOWN" then
                local focus
                if type(GetMouseFoci)=="function" then
                    local foci=GetMouseFoci(); focus=type(foci)=="table" and not foci.GetParent and foci[1] or foci
                elseif type(GetMouseFocus)=="function" then focus=GetMouseFocus() end
                local root=TSMCraftHostFor(focus)
                if IsCraftHostVisible(root) then UI.craftActiveRoot=root; UI.craftClickedRoot=root end
            end
            UpdateHost()
        end)
    end
    UI.craftTicker=C_Timer.NewTicker(.25,UpdateHost)
    UpdateHost()
end

local function AttachAuctionCraftAssistant()
    StartCraftAssistantTicker()
    local root=FindTSMAuctionRoot()
    return root and AttachCraftAssistant(root) or false
end

local function HideLegacyUBKMarketOverlays()
    -- The UBK workspace is the visible interface. Keep UBK's old
    -- frames available for legacy slash-command diagnostics, but never leave
    -- them covering TSM just because the engine is running.
    if _G.UBKShelfScoutBadge then _G.UBKShelfScoutBadge:Hide() end
    if _G.UBKShelfScoutPanel then _G.UBKShelfScoutPanel:Hide() end
    if _G.UBKGoblinRadarPanel then _G.UBKGoblinRadarPanel:Hide() end
end

local function Show(page,options)
    CreateWindow()
    options=type(options)=="table" and options or {}
    if page=="coverage" then UI.coverageSection=options.coverageSection or "coverage"; UI.coverageFilter=options.coverageFilter or "all" end
    if page=="position" then UI.positionSection=options.positionSection or "positions" end
    if page=="crossdemo" or page=="positiondemo" then
        local kind=page=="positiondemo" and "position" or "cross"
        UI.page=kind
        UI.listPage=1
        UI.crossDetailKey=nil
        OpenTestArena(kind)
    elseif page then
        NavigateRoot(page)
    else
        NavigateRoot("home")
    end
    UI.root:Show()
    if _G.UBKWindowFocus then _G.UBKWindowFocus.Raise(UI.root) end
end

_G.UBKInterface_Show=Show
_G.UBKInterface_Show=Show
_G.UBKUI_Show=Show
_G.UBKInterface_ShredderUpdated=function()
    if UI.root and UI.root:IsShown() and (UI.page=="position" or UI.page=="market" or UI.page=="chum") then
        if UI.page=="chum" then InvalidateChumCache() end
        RenderPage()
    end
end
_G.UBKInterfaceAPI={version=VERSION,Show=function(_,page) Show(page) end,ShowReview=function() Show("review") end,GetScope=function() local key,realm,faction=ScopeKey(); return key,realm,faction end,GetAccessInfo=function() return {channel="STANDARD",engineAvailable=true,crossPressureUnlocked=true,positionIntelligenceUnlocked=true,chumScannerModule=type(_G.UBKScannersAPI)=="table",open=true} end}
function _G.UBKInterfaceAPI:ShowProspectingOreCost(item)
    if UI.resolveDialog and UI.resolveDialog:IsShown() then return end
    if UI.resolveConfirmDialog and UI.resolveConfirmDialog:IsShown() then return end
    _G.UBKProspectAccounting.Refresh()
    if API.GetBagProspectableOres then for _,row in ipairs(API:GetBagProspectableOres(1)) do
        if row.itemString==item then _G.UBKProspectAccounting.Input(item,row.quantity) end
    end end
    UI.selectedItem=item;Show("market")
    local info=API:GetBasisInfo(item)
    local consumed=_G.UBKProspectingSessions:UnknownInput(item)
    if consumed<=0 and info and (info.unresolvedQty or 0)<=0 then
        print("|cff33ff99UBK:|r This ore has no unknown cost to enter. Reload to settle completed prospects; review Cost Coverage if its existing cost is untrusted.")
        return
    end
    ShowResolveUnknownDialog(item,true)
end
_G.UBKInterfaceAPI=_G.UBKInterfaceAPI

_G.UBKInterfaceCommand=function(msg)
    local function RunCommand()
        msg=(msg or ""):lower():gsub("^%s+",""):gsub("%s+$","")
        if msg=="home" or msg=="radar" or msg=="chum" or msg=="bait" or msg=="cross" or msg=="pressure" or msg=="crossdemo" or msg=="position" or msg=="positions" or msg=="positiondemo" or msg=="shredder" or msg=="shred" or msg=="prospecting" or msg=="market" or msg=="watch" or msg=="review" or msg=="coverage" or msg=="settings" then
            local page=msg
            if msg=="shred" then page="shredder" elseif msg=="pressure" then page="cross" elseif msg=="positions" then page="position" elseif msg=="bait" then page="chum" end
            Show(page)
        elseif msg=="refresh" then RefreshWatchlist(false); CPCaptureAndAlert("slash-refresh"); if UI.root and UI.root:IsShown() then RenderPage() end
        elseif msg=="scale" then local db=EnsureDB(); print(string.format("|cff33ff99Universal Basis Keeper:|r window scale %.0f%%. Use /ubk scale 75-130, the Settings presets, or drag the lower-right corner.",(db.uiScale or 1)*100))
        elseif msg=="scale reset" then ApplyUIScale(.95,true)
        else
            local p=msg:match("^scale%s+(%d+%.?%d*)$")
            if p then ApplyUIScale((tonumber(p) or 100)/100,true) else Show("home") end
        end
    end
    local ok,err=pcall(RunCommand)
    if not ok then
        print("|cffff4444Universal Basis Keeper UI error:|r "..tostring(err))
        print("|cffffff66UBK:|r The slash command loaded, but the window hit a compatibility error. Include this message and the UBK version when reporting the issue.")
    end
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:SetScript("OnEvent",function(_,event,name)
    if event=="ADDON_LOADED" and name==ADDON then EnsureDB(); return end
    if event=="PLAYER_LOGIN" then
        HideLegacyUBKMarketOverlays()
        InstallMarketLinkCapture()
        StartCraftAssistantTicker()
        CreateMinimapLaunchers()
        print("|cff33ff99UBK "..VERSION..":|r loaded. Type /ubk to open Home; /ubk dock opens the basis dock.")
        C_Timer.After(4,function() if NeedAPI(false) then RefreshWatchlist(true); CPCaptureAndAlert("login"); local db=EnsureDB(); if db.settings.openOnLogin then Show("watch") end end end)
    elseif event=="AUCTION_HOUSE_SHOW" then
        HideLegacyUBKMarketOverlays()
        StartCraftAssistantTicker()
        -- TSM builds its auction frame lazily. Retry briefly while it opens;
        -- the shared ticker then follows whichever TSM window is selected.
        local tries=0; local function TryAttach() tries=tries+1; if AttachAuctionCraftAssistant() or tries>=20 then return end; C_Timer.After(.25,TryAttach) end; TryAttach()
    end
end)
