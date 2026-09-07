-- UBK workspace presentation. Existing position signals and watch histories are
-- inputs, never rewritten by sorting/filtering. Load after UBK_TableUI.lua.
_G.UBKPositionWatchUI = {}
local P=_G.UBKPositionWatchUI
local T=_G.UBKTableUI
local professionCache={}

local function Positive(v)
    v=tonumber(v); return v and v==v and v>0 and v<math.huge and v or nil
end
local function Call(ctx,method,item)
    local api=ctx.API or _G.UniversalBasisKeeperAPI
    if type(api)~="table" or type(api[method])~="function" then return nil end
    local ok,value,extra=pcall(api[method],api,item)
    if ok then return value,extra end
    return nil
end
local function ID(item) return tonumber(tostring(item or ""):match("^i:(%d+)") or tostring(item or ""):match("item:(%d+)") or item) end
local function Plain(s) return tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","") end
local function Money(ctx,value)
    if not T.Available(value) then return "n/a" end
    -- WoW coin formatters commonly clamp negative values, so preserve the sign.
    local abs=math.abs(value)
    local text=ctx.Money and ctx.Money(abs) or string.format("%.2fg",abs/10000)
    return (value<0 and "-" or "")..text
end
local function Date(value)
    value=Positive(value)
    if not value or type(date)~="function" then return "n/a" end
    local ok,result=pcall(date,"%Y-%m-%d",value)
    return ok and result or "n/a"
end
local function Percent(value) return T.Available(value) and string.format("%.1f%%",value*100) or "n/a" end
local function DisplayName(ctx,row)
    return ctx.ItemTexture and ("|T"..tostring(ctx.ItemTexture(row.itemString))..":14:14:0:0|t "..row.name) or row.name
end

-- Recipes are the authoritative profession map for the current faction/realm.
-- Type-derived professions supplement recipes the account has not learned.
function P.ProfessionIndex(ctx)
    local realm=type(GetRealmName)=="function" and GetRealmName() or nil
    local faction=type(UnitFactionGroup)=="function" and UnitFactionGroup("player") or nil
    if (not realm or not faction) then
        local runtime=Call(ctx,"GetRuntimeContext")
        if type(runtime)=="table" then realm=realm or runtime.realm; faction=faction or runtime.faction end
    end
    local db=_G.TradeSkillMasterDB
    local key="f@"..tostring(faction).." - "..tostring(realm).."@internalData@crafts"
    local crafts=type(db)=="table" and db[key] or nil
    if type(crafts)~="table" then return {} end
    local count=0; for _ in pairs(crafts) do count=count+1 end
    if professionCache.crafts==crafts and professionCache.count==count and professionCache.key==key then return professionCache.index end
    local index={}
    local function Add(item,profession)
        if type(item)~="string" or type(profession)~="string" then return end
        index[item]=index[item] or {}; index[item][profession]=true
    end
    for _,recipe in pairs(crafts) do
        if type(recipe)=="table" then
            Add(recipe.itemString,recipe.profession)
            for item in pairs(recipe.mats or {}) do Add(item,recipe.profession) end
        end
    end
    professionCache={crafts=crafts,count=count,key=key,index=index}
    return index
end

-- Explicit quest-token names prevent arbitrary Quest items being mislabelled
-- as reputation goods; all other uncached categories remain Unknown.
local reputationNames={
    ["arcane tome"]=true,["fel armament"]=true,["mark of sargeras"]=true,["mark of kil'jaeden"]=true,
    ["firewing signet"]=true,["sunfury signet"]=true,["obsidian warbeads"]=true,
    ["zaxxis insignia"]=true,["unidentified plant parts"]=true,["fertile spores"]=true,
    ["sanguine hibiscus"]=true,["glowcap"]=true,["arakkoa feather"]=true,["bog lord tendril"]=true,
}
local qualityNames={[0]="Poor",[1]="Common",[2]="Uncommon",[3]="Rare",[4]="Epic",[5]="Legendary",[6]="Artifact",[7]="Heirloom"}

function P.Classify(ctx,itemString,name,index)
    local id=ID(itemString)
    local info={}
    if id and type(GetItemInfo)=="function" then
        local ok,n,link,q,level,minLevel,kind,subkind,stack,equip,texture,vendor,classID,subclassID,bind=pcall(GetItemInfo,id)
        if ok then info={name=n,quality=q,kind=kind,subkind=subkind,classID=classID,subclassID=subclassID,bind=bind,equip=equip} end
    end
    if id and not info.classID and type(GetItemInfoInstant)=="function" then
        local ok,_,kind,subkind,equip,_,classID,subclassID=pcall(GetItemInfoInstant,id)
        if ok then info.kind=info.kind or kind; info.subkind=info.subkind or subkind; info.equip=info.equip or equip; info.classID=classID; info.subclassID=subclassID end
    end
    local professions={}
    for profession in pairs((index or P.ProfessionIndex(ctx))[itemString] or {}) do professions[profession]=true end
    local label=Plain(info.name or name):lower()
    local kind,sub=(info.kind or ""):lower(),(info.subkind or ""):lower()
    local category=info.subkind or info.kind or "Unknown"
    local function Add(...) for i=1,select("#",...) do professions[select(i,...)]=true end end
    if reputationNames[label] then category="Reputation tokens"
    elseif (info.classID==2 or info.classID==4 or kind=="weapon" or kind=="armor") and info.bind==2 then category="BoEs"
    elseif info.classID==3 or kind=="gem" then category="Gems"; Add("Jewelcrafting")
    elseif label:find(" ore$",1) then category="Ore"; Add("Mining","Jewelcrafting","Engineering","Blacksmithing")
    elseif label:find(" bar$",1) then category="Bars"; Add("Mining","Blacksmithing","Engineering")
    elseif sub=="cloth" or label:find("cloth$",1) or label:find("^bolt of ",1) then category="Cloth"; Add("Tailoring")
    elseif sub=="herb" or sub=="herbs" then category="Herbs"; Add("Alchemy","Herbalism")
    elseif sub=="enchanting" then category="Enchanting mats"; Add("Enchanting")
    elseif sub=="leather" or sub=="leatherworking" then category="Leather"; Add("Leatherworking")
    elseif sub=="elemental" or label:find("^primal ",1) or label:find("^mote of ",1) then category="Elementals"
    elseif sub=="potion" or sub=="potions" then category="Potions"; Add("Alchemy")
    elseif sub=="elixir" or sub=="elixirs" then category="Elixirs"; Add("Alchemy")
    elseif sub=="flask" or sub=="flasks" then category="Flasks"; Add("Alchemy")
    elseif sub=="cooking" or sub=="food & drink" then category="Food / Cooking"; Add("Cooking")
    elseif info.classID==1 or kind=="container" then category="Bags"
    elseif info.classID==9 or kind=="recipe" then category="Recipes"
    elseif info.classID==2 or kind=="weapon" then category="Weapons"
    elseif info.classID==4 or kind=="armor" then category="Armor"
    elseif info.classID==7 or kind=="trade goods" then category=info.subkind or "Trade goods"
    end
    if next(professions)==nil then professions[category=="Unknown" and "Unknown" or "Other / resale"]=true end
    local list={} for profession in pairs(professions) do list[#list+1]=profession end; table.sort(list)
    return {itemType=category,professions=professions,profession=table.concat(list,", "),quality=info.quality or "UNKNOWN",qualityName=info.quality and (_G["ITEM_QUALITY"..info.quality.."_DESC"] or qualityNames[info.quality]) or "Unknown"}
end

-- Call exactly once when AddWatch creates a NEW record, after its first market
-- snapshot. Calling on an existing watch never backfills today's values as old.
function P.CaptureWatchStart(ctx,itemString,w,isNew)
    if not isNew or type(w)~="table" or w.ubkWatchStart~=nil then return false end
    local now=type(time)=="function" and time() or 0
    local market=Call(ctx,"GetMarketContext",itemString)
    market=type(market)=="table" and market or {}
    local basis=Positive(Call(ctx,"GetAcquisitionCost",itemString))
    local firstAcquired,acquisitionSource=Call(ctx,"GetFirstAcquisitionTime",itemString)
    local rt,rg
    local api=ctx.API or _G.UniversalBasisKeeperAPI
    if api and type(api.GetMarketDataTimes)=="function" then local ok,a,b=pcall(api.GetMarketDataTimes,api); if ok then rt,rg=a,b end end
    w.ubkWatchStart={schema=1,capturedAt=now,basis=basis,minbuyout=Positive(market.minbuyout),firstAcquiredAt=Positive(firstAcquired),acquisitionSource=acquisitionSource,realmDataTime=Positive(rt),regionDataTime=Positive(rg)}
    return true
end

function P.WatchRows(ctx)
    local db=ctx.EnsureDB(); local rows={}; local index=P.ProfessionIndex(ctx)
    for itemString,w in pairs(db.watchlist or {}) do
        if type(w)=="table" then
            local name=w.name or (ctx.ItemName and ctx.ItemName(itemString)) or itemString
            local cls=P.Classify(ctx,itemString,name,index)
            local market=Call(ctx,"GetMarketContext",itemString)
            market=type(market)=="table" and market or {}
            local first,firstSource=Call(ctx,"GetFirstAcquisitionTime",itemString)
            local start=type(w.ubkWatchStart)=="table" and w.ubkWatchStart or {}
            local liveFirst,storedFirst=Positive(first),Positive(start.firstAcquiredAt)
            -- Preserve earlier captured evidence if the current ledger has been pruned.
            local earliest=liveFirst and storedFirst and math.min(liveFirst,storedFirst) or liveFirst or storedFirst
            cls.itemString=itemString; cls.name=Plain(name); cls.watch=w; cls.market=market
            cls.watchedAt=Positive(w.addedAt); cls.firstAcquiredAt=earliest; cls.acquisitionSource=(storedFirst and (not liveFirst or storedFirst<liveFirst)) and start.acquisitionSource or firstSource or start.acquisitionSource
            cls.initialBasis=Positive(start.basis); cls.initialMinbuyout=Positive(start.minbuyout)
            cls.minbuyout=Positive(market.minbuyout); cls.saleRate=tonumber(market.saleRate)
            cls.currentBasis=Positive(Call(ctx,"GetAcquisitionCost",itemString))
            cls.goldValue=cls.minbuyout
            rows[#rows+1]=cls
        end
    end
    return rows
end

function P.PositionRows(ctx)
    local source=ctx.PositionIntelligenceRows(); local rows,total={},0; local index=P.ProfessionIndex(ctx)
    for _,original in ipairs(source or {}) do
        local row={}; for key,value in pairs(original) do row[key]=value end
        local cls=P.Classify(ctx,row.itemString,row.name,index)
        for key,value in pairs(cls) do row[key]=value end
        row.name=Plain(row.name or row.itemString)
        row.saleRate=row.market and tonumber(row.market.saleRate) or nil
        local fullyCovered=row.trustedBasis and (tonumber(row.unresolved) or 0)==0 and (tonumber(row.known) or 0)>=(tonumber(row.owned) or 0)
        row.originalStance=row.stance
        row.stance=fullyCovered and row.stance or "COST NEEDED"
        row.unitProfit=fullyCovered and row.netPerUnit or nil
        row.totalProfit=fullyCovered and row.netCovered or nil
        row.knownInvested=fullyCovered and row.invested or nil
        total=total+(tonumber(row.knownInvested) or 0)
        row.goldValue=row.unitProfit
        rows[#rows+1]=row
    end
    for _,row in ipairs(rows) do row.costShare=row.knownInvested and total>0 and row.knownInvested/total or nil end
    return rows,total
end

local function HeaderButton(ctx,text,x,y,width,fn)
    local b=ctx.MakeButton(ctx.UI.content,text,width,24); b:SetPoint("TOPLEFT",x,y); b:SetScript("OnClick",fn); return b
end
local function TooltipLine(text,r,g,b)
    if text and GameTooltip then GameTooltip:AddLine(tostring(text),r or .86,g or .86,b or .86,true) end
end
local function WatchTooltip(ctx,owner,row)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner,"ANCHOR_RIGHT"); TooltipLine(row.name,1,.82,.3)
    TooltipLine(row.itemType.." | "..row.qualityName.." | "..row.profession,.6,.85,1)
    TooltipLine("Watch started: "..Date(row.watchedAt).." | earliest recorded acquisition: "..Date(row.firstAcquiredAt))
    if row.acquisitionSource then TooltipLine("Acquisition date evidence: "..row.acquisitionSource,.65,.8,.7) end
    TooltipLine("Initial basis: "..Money(ctx,row.initialBasis).." | initial Min Buyout: "..Money(ctx,row.initialMinbuyout))
    TooltipLine("Current basis: "..Money(ctx,row.currentBasis).." | latest loaded Min Buyout: "..Money(ctx,row.minbuyout))
    TooltipLine("Region sale rate: "..Percent(row.saleRate).." | sold/day: "..tostring(row.market.soldPerDay or "n/a"))
    if not row.watch.ubkWatchStart then TooltipLine("This watch predates start-value capture. Its initial basis and initial market price were not recorded.",1,.7,.35) end
    if not row.firstAcquiredAt then TooltipLine("No dated acquisition record is available. The watch date is not an acquisition date.",1,.7,.35) end
    local current,previous=row.watch.current or {},row.watch.previous or {}
    if current.cachedPrice and previous.cachedPrice and previous.cachedPrice>0 then TooltipLine(string.format("Saved reference change since previous watch update: %+.1f%%",(current.cachedPrice/previous.cachedPrice-1)*100)) end
    if current.signals and #current.signals>0 then TooltipLine("Signals: "..table.concat(current.signals," | ")) end
    TooltipLine("Click: Market Inspector | Right-click: remove from Watchlist",.6,.9,1)
    TooltipLine("Min Buyout uses currently loaded TSM data; sale rate is regional.",.66,.66,.66)
    GameTooltip:Show()
end
local function PositionTooltip(ctx,owner,row)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner,"ANCHOR_RIGHT"); TooltipLine(row.name,1,.82,.3)
    TooltipLine(row.itemType.." | "..row.qualityName.." | "..row.profession,.6,.85,1)
    TooltipLine(row.stance or "Unknown",1,.8,.35)
    TooltipLine("Evidence: "..tostring(row.certainty or "Forming").." ("..tostring(row.seen or 1).." matching updates)",.58,.88,1)
    if row.stance=="COST NEEDED" then
        TooltipLine("Resolve acquisition costs before acting on this position.",1,.65,.3)
        TooltipLine("Untrusted market signal from the previous engine: "..tostring(row.originalStance or "Unknown")..". This is not a basis-backed recommendation.",.75,.75,.75)
    else
        TooltipLine(row.action or row.reason)
        if row.action and row.reason then TooltipLine(row.reason,.75,.75,.75) end
    end
    TooltipLine("Basis: "..Money(ctx,row.basis).." ("..tostring(row.basisSource or "UBK")..")")
    if row.stance=="COST NEEDED" then
        TooltipLine("Profit unavailable: this position lacks fully covered, trusted acquisition basis. Resolve its costs before treating a market estimate as profit.",1,.65,.3)
    elseif row.unitProfit==nil then
        TooltipLine("Profit unavailable: no usable loaded sale-price reference exists for this item.",1,.65,.3)
    end
    TooltipLine("Loaded reference: "..Money(ctx,row.recent).." | profit per unit: "..Money(ctx,row.unitProfit))
    TooltipLine("Owned: "..tostring(row.owned or 0).." | known: "..tostring(row.known or 0).." | unresolved: "..tostring(row.unresolved or 0))
    TooltipLine("Total estimated profit: "..Money(ctx,row.totalProfit).." | trusted invested: "..Money(ctx,row.knownInvested))
    TooltipLine("Share of fully costed positions: "..Percent(row.costShare).." | net ROI: "..Percent(row.stance~="COST NEEDED" and row.realizedNetPct or nil))
    if row.signals and #row.signals>0 then TooltipLine("Signals: "..table.concat(row.signals," | ")) end
    TooltipLine("Liquidity: "..tostring(row.market and row.market.liquidity or "UNKNOWN").." | regional sale rate: "..Percent(row.saleRate))
    if row.paidRunner then TooltipLine("Sell to cover the position's current basis: "..tostring(row.recoveryQty).." units; remaining paid runner: "..tostring(row.paidRunnerQty).." units.",.55,1,.65) end
    if row.stance~="COST NEEDED" then
        TooltipLine("Price ladder per item",1,.82,.3)
        for _,step in ipairs({{"Buy all through",row.buy15},{"Buy some through",row.buy10},{"Sell slow from",row.sell5},{"Sell lightly from",row.sell15},{"Sell hard from",row.sell25}}) do TooltipLine(step[1]..": "..Money(ctx,step[2])) end
    end
    TooltipLine("Profits include the 5% AH cut"..(row.depositKnown and (" and one failed 24h deposit of "..Money(ctx,row.deposit24).." per item.") or "; vendor value was unavailable for a deposit reserve."),.72,.72,.72)
    TooltipLine("These are loaded-data sale estimates. Quantity is separate from the per-unit opportunity rank.",.7,.7,.7)
    TooltipLine("Click: Market Inspector | Right-click: watch item",.6,.9,1)
    GameTooltip:Show()
end

function P.RenderWatch(ctx)
    ctx.PageTitle("Watchlist","Initial acquisition and watch dates stay separate. Click any header to sort; missing historical values stay n/a.")
    local state=ctx.UI.ubkWatchTable or {key="name",ascending=true,page=1}; ctx.UI.ubkWatchTable=state
    local rows=P.WatchRows(ctx)
    HeaderButton(ctx,"Refresh loaded data",6,-58,152,function() ctx.RefreshWatchlist(false); if ctx.CPCaptureAndAlert then ctx.CPCaptureAndAlert("watch-refresh") end; ctx.RenderPage() end)
    local help=ctx.MakeText(ctx.UI.content,"GameFontDisableSmall"); help:SetPoint("TOPLEFT",168,-64); help:SetWidth(ctx.UI.content:GetWidth()-180); help:SetText("Hover rows for history and signals. Use the bottom scrollbar for more columns.")
    T.DrawFilters(ctx,rows,state,-91,"Buyout / unit")
    local columns={
        {key="name",label="Item",width=176,text=function(r)return DisplayName(ctx,r)end},
        {key="itemType",label="Type",width=108},
        {key="profession",label="Profession",width=142,tooltip="Every matching profession is retained; the filter includes any match."},
        {key="quality",label="Quality",width=85,value=function(r)return tonumber(r.quality)end,text=function(r)return r.qualityName end},
        {key="firstAcquiredAt",label="Acquired",width=97,text=function(r)return Date(r.firstAcquiredAt)end,tooltip="Earliest actual dated acquisition still evidenced by your accounting records. May predate UBK. It is not a guarantee of your first-ever purchase."},
        {key="watchedAt",label="Watch date",width=97,text=function(r)return Date(r.watchedAt)end,tooltip="When you first added this watch entry."},
        {key="initialBasis",label="Start basis",width=112,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.initialBasis)end,tooltip="Trusted per-unit UBK basis captured when this watch started. Legacy missing values are unavailable."},
        {key="initialMinbuyout",label="Start buyout",width=112,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.initialMinbuyout)end,tooltip="Loaded DBMinBuyout captured at watch creation, only when capture was installed and price available."},
        {key="minbuyout",label="Min Buyout",width=112,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.minbuyout)end,tooltip="Latest DBMinBuyout currently loaded in TSM. Not a live AH listing guarantee."},
        {key="currentBasis",label="Basis now",width=112,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.currentBasis)end},
        {key="saleRate",label="Sale rate",width=83,align="RIGHT",ascending=false,text=function(r)return Percent(r.saleRate)end,tooltip="TSM regional sale rate. It is not your personal sell-through rate."},
    }
    return T.Render(ctx,{parent=ctx.UI.content,x=6,y=-126,width=ctx.UI.content:GetWidth()-12,height=ctx.UI.content:GetHeight()-132,columns=columns,rows=T.FilterRows(rows,state),state=state,onChange=ctx.RenderPage,onClick=function(r)ctx.ShowMarketItem(r.itemString)end,onRightClick=function(r)ctx.RemoveWatch(r.itemString);ctx.RenderPage()end,onEnter=function(owner,r)WatchTooltip(ctx,owner,r)end,emptyText="No watches match. Add an item using Watch in Market Inspector."})
end

function P.RenderPositions(ctx)
    local offset=tonumber(ctx.TableTopOffset) or 0
    ctx.PageTitle("Position Intelligence","Find sale opportunities by profit per item. Filter your positions, then hover an item for its action, evidence, and exit prices.")
    local state=ctx.UI.ubkPositionTable or {key="unitProfit",ascending=false,page=1,stance=ctx.UI.positionFilter or "QUICK"}; ctx.UI.ubkPositionTable=state
    local rows,total=P.PositionRows(ctx)
    local stances={{value="QUICK",label="Quick Wins"},{value="ALL",label="All"},{value="SELL",label="Sell"},{value="ADD",label="Add"},{value="RISK",label="Risk"},{value="REVIEW",label="Cost review"}}
    T.Picker(ctx,ctx.UI.content,6,-58-offset,176,"Show",state.stance,stances,function(v) state.stance=v; ctx.UI.positionFilter=v; state.page=1; ctx.RenderPage() end,"Quick Wins retains the existing complete-cost, liquidity, and 15% net-return requirements. Default ordering is profit per item, highest first.")
    HeaderButton(ctx,"Refresh positions",190,-58-offset,140,function() if ctx.InvalidatePositionIntelligenceCache then ctx.InvalidatePositionIntelligenceCache() else ctx.PositionIntelligenceRows(true) end; state.page=1;ctx.RenderPage()end)
    local summary=ctx.MakeText(ctx.UI.content,"GameFontDisableSmall"); summary:SetPoint("TOPLEFT",652,-64-offset); summary:SetWidth(ctx.UI.content:GetWidth()-662); summary:SetText(tostring(#rows).." positions | trusted invested "..Money(ctx,total).." | hover for evidence")
    T.DrawSearch(ctx,ctx.UI.content,state,342,-64-offset,300,ctx.RenderPage)
    T.DrawFilters(ctx,rows,state,-91-offset,"Profit / unit")
    local filtered=T.FilterRows(rows,state)
    local shown={}
    for _,row in ipairs(filtered) do
        local s=state.stance
        local include=s=="ALL" or (s=="QUICK" and row.quickWin)
            or (s=="SELL" and (row.stance=="SELL HARD" or row.stance=="SELL LIGHTLY" or row.stance=="HOLD / SELL SLOW"))
            or (s=="ADD" and (row.stance=="BUY ALL OF THEM" or row.stance=="BUY SOME"))
            or (s=="RISK" and (row.stance=="NO ADD" or row.stance=="WATCH / THIN" or row.stance=="NO RECENT DATA"))
            or (s=="REVIEW" and row.stance=="COST NEEDED")
        if include then shown[#shown+1]=row end
    end
    local columns={
        {key="name",label="Item",width=178,text=function(r)return DisplayName(ctx,r)end},
        {key="stance",label="Assessment",width=133},
        {key="itemType",label="Type",width=85},
        {key="basis",label="Basis",width=100,align="RIGHT",ascending=false,value=function(r)return not r.basisProxy and r.basis or nil end,text=function(r)return Money(ctx,not r.basisProxy and r.basis or nil)end,tooltip="Per-item acquisition basis. Unproven market proxies are not acquisition costs and remain unavailable here."},
        {key="recent",label="Price ref.",width=100,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.recent)end,tooltip="The existing position engine's loaded recent-realm reference. Hover for the full context."},
        {key="unitProfit",label="Profit / unit",width=110,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.unitProfit)end,color=function(r)if r.unitProfit then if r.unitProfit>=0 then return .5,1,.65 else return 1,.45,.35 end end end,tooltip="Loaded sale proceeds after fees/reserve minus trusted acquisition basis. Default ranking. A 20g/unit opportunity ranks above 10g/unit regardless of quantity."},
        {key="owned",label="Qty",width=48,align="RIGHT",ascending=false},
        {key="totalProfit",label="Total profit",width=112,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.totalProfit)end,tooltip="Estimated profit if the fully costed position sells at the loaded price; not realized profit."},
        {key="saleRate",label="Sale rate",width=80,align="RIGHT",ascending=false,text=function(r)return Percent(r.saleRate)end},
    }
    return T.Render(ctx,{parent=ctx.UI.content,x=6,y=-126-offset,width=ctx.UI.content:GetWidth()-12,height=ctx.UI.content:GetHeight()-132-offset,columns=columns,minWidth=ctx.UI.content:GetWidth()-12,rows=shown,state=state,onChange=ctx.RenderPage,onClick=function(r)ctx.ShowMarketItem(r.itemString)end,onRightClick=function(r)ctx.AddWatch(r.itemString)end,onEnter=function(owner,r)PositionTooltip(ctx,owner,r)end,emptyText="No positions match these filters. Choose All to review the remaining positions."})
end
