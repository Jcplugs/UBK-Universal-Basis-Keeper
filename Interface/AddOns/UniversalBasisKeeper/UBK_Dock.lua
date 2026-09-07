-- UBK Basis Dock: a small accounting summary and shortcuts into the UBK workspace.
-- This module reads current core/cache data only; it does not index sale history.

local VERSION = "1.6"
local UI = {page="home", pages={}, nav={}}

local function Core()
    return type(_G.UniversalBasisKeeperAPI)=="table" and _G.UniversalBasisKeeperAPI or nil
end

local function Call(api,method,...)
    if type(api)~="table" or type(api[method])~="function" then return nil end
    local ok,a,b=pcall(api[method],api,...)
    if ok then return a,b end
    return nil
end

local function Money(value)
    value=tonumber(value) or 0
    local text=Call(Core(),"FormatMoney",math.abs(value))
    if text then return (value<0 and "-" or "")..tostring(text) end
    local copper=math.floor(math.abs(value)+.5)
    return string.format("%s%dg %02ds %02dc",value<0 and "-" or "",math.floor(copper/10000),math.floor(copper%10000/100),copper%100)
end

local function Age(stamp)
    stamp=tonumber(stamp)
    if not stamp or stamp<=0 then return "not loaded" end
    local now=type(time)=="function" and time() or stamp
    local seconds=math.max(0,now-stamp)
    if seconds<60 then return "less than 1 minute" end
    if seconds<3600 then return string.format("%d minutes",math.floor(seconds/60)) end
    if seconds<86400 then return string.format("%.1f hours",seconds/3600) end
    return string.format("%.1f days",seconds/86400)
end

local function Context()
    local ctx=Call(Core(),"GetRuntimeContext")
    if type(ctx)=="table" then return ctx end
    return {realm=GetRealmName and GetRealmName() or "",faction=UnitFactionGroup and UnitFactionGroup("player") or ""}
end

local function FactionCharacters()
    if type(_G.UBK_CurrentFactionCharacters)=="function" then
        local ok,value=pcall(_G.UBK_CurrentFactionCharacters)
        if ok and type(value)=="table" then return value end
    end
    local player=UnitName and UnitName("player") or nil
    return player and {[player]=true} or {}
end

local function GoldSnapshot()
    local ctx=Context()
    local out={total=0,characters=0}
    if type(_G.TradeSkillMasterDB)~="table" then return out end
    for character in pairs(FactionCharacters()) do
        local key="s@"..tostring(character).." - "..tostring(ctx.faction).." - "..tostring(ctx.realm).."@internalData@money"
        local value=tonumber(_G.TradeSkillMasterDB[key])
        if value then out.total=out.total+value; out.characters=out.characters+1 end
    end
    return out
end

local function CoverageSummary()
    local value=Call(Core(),"GetCoverage")
    value=type(value)=="table" and value or {}
    local out={available=next(value)~=nil}
    for _,key in ipairs({"ready","partial","unknown","review","protected","zeroStock"}) do
        out[key]=type(value[key])=="table" and #value[key] or 0
    end
    return out
end

local function PositionSummary()
    local rows=Call(Core(),"GetPositionInputs")
    local out={available=type(rows)=="table",items=0,coveredItems=0,coveredQty=0,basisValue=0,unresolvedQty=0}
    for _,row in ipairs(type(rows)=="table" and rows or {}) do
        local qty=math.max(0,tonumber(row.observedQty) or 0)
        local unresolved=math.max(0,tonumber(row.unresolvedQty) or 0)
        local basis=tonumber(row.basis)
        if qty>0 then
            out.items=out.items+1
            out.unresolvedQty=out.unresolvedQty+unresolved
            if basis and basis>0 and row.trustedForRadar==true and unresolved<=0 then
                out.coveredItems=out.coveredItems+1
                out.coveredQty=out.coveredQty+qty
                out.basisValue=out.basisValue+qty*basis
            end
        end
    end
    return out
end

local function Snapshot()
    local realmTime,regionTime=Call(Core(),"GetMarketDataTimes")
    local scan=Call(_G.UBKScannersAPI,"GetCachedSummary")
    return {gold=GoldSnapshot(),coverage=CoverageSummary(),positions=PositionSummary(),
        realmTime=realmTime,regionTime=regionTime,scanner=type(scan)=="table" and scan or {built=false}}
end

-- Preserve the existing saved location. Old conversation/history tables are not read or changed.
local function GetUIDB()
    if type(_G.UniversalBasisKeeperDB)~="table" then _G.UniversalBasisKeeperDB={} end
    local db=_G.UniversalBasisKeeperDB
    db.ui=type(db.ui)=="table" and db.ui or {}
    db.ui.dock=type(db.ui.dock)=="table" and db.ui.dock or {}
    return db.ui.dock
end

local function Raise()
    local root=UI.root
    if not root then return end
    local focus=_G.UBKWindowFocus
    if type(focus)=="table" and type(focus.Raise)=="function" then focus.Raise(root)
    else root:SetFrameStrata("MEDIUM"); root:SetToplevel(true); root:Raise() end
end

local function OpenWorkspace(page,filter)
    if type(_G.UBKInterface_Show)=="function" then
        local options=filter and {coverageFilter=filter,coverageSection=filter=="review" and "review" or "coverage"} or nil
        _G.UBKInterface_Show(page or "home",options)
    elseif UI.status then
        UI.status:SetText("UBK workspace is not loaded. Check the UniversalBasisKeeper installation.")
    end
end

local function Text(parent,font)
    local text=parent:CreateFontString(nil,"OVERLAY",font or "GameFontHighlight")
    text:SetJustifyH("LEFT"); text:SetJustifyV("TOP")
    return text
end

local function Tooltip(target,title,body)
    target:HookScript("OnEnter",function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
        GameTooltip:SetText(title)
        GameTooltip:AddLine(body,1,1,1,true)
        GameTooltip:Show()
    end)
    target:HookScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
end

local function Button(parent,label,width,action)
    local button=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate")
    button:SetSize(width or 138,26); button:SetText(label)
    button:HookScript("OnMouseDown",Raise)
    button:SetScript("OnClick",action)
    return button
end

local function Backdrop(target)
    if type(target.SetBackdrop)~="function" then return end
    target:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=16,edgeSize=14,insets={left=3,right=3,top=3,bottom=3}})
    target:SetBackdropColor(.025,.030,.042,.98)
    target:SetBackdropBorderColor(.48,.38,.18,1)
end

local function Line(parent,x,y,width)
    local line=parent:CreateTexture(nil,"ARTWORK")
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetVertexColor(.29,.34,.39,1)
    line:SetPoint("TOPLEFT",x,y); line:SetSize(width,1)
    return line
end

local function Page(name,title,description)
    local page=CreateFrame("Frame",nil,UI.content)
    page:SetAllPoints(); page:Hide(); page.rows={}
    local heading=Text(page,"GameFontNormalLarge")
    heading:SetPoint("TOPLEFT",20,-18); heading:SetText(title)
    local sub=Text(page,"GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT",20,-45); sub:SetSize(654,34); sub:SetText(description)
    UI.pages[name]=page
    return page
end

local function SummaryRow(page,key,index,label,buttonLabel,action,tip)
    local y=-90-(index-1)*61
    local name=Text(page,"GameFontNormal")
    name:SetPoint("TOPLEFT",20,y); name:SetSize(466,17); name:SetText(label)
    local value=Text(page,"GameFontHighlightSmall")
    value:SetPoint("TOPLEFT",20,y-21); value:SetSize(466,29)
    local button=Button(page,buttonLabel,146,action)
    button:SetPoint("TOPRIGHT",-20,y-5)
    if tip then Tooltip(button,buttonLabel,tip) end
    Line(page,20,y-54,654)
    page.rows[key]=value
end

local function RenderHome(snapshot)
    local page=UI.pages.home
    local c,p,g,scan=snapshot.coverage,snapshot.positions,snapshot.gold,snapshot.scanner
    page.rows.gold:SetText(g.characters>0 and string.format("%s across %d cached characters",Money(g.total),g.characters) or "No character gold data loaded from TSM yet.")
    page.rows.positions:SetText(p.available and string.format("%s basis / %d fully covered items / %d units",Money(p.basisValue),p.coveredItems,p.coveredQty) or "UBK position inputs are not ready yet.")
    page.rows.coverage:SetText(c.available and string.format("%d ready / %d partial / %d unknown / %d formula-protected",c.ready,c.partial,c.unknown,c.protected) or "UBK coverage is not ready yet.")
    page.rows.review:SetText(string.format("%d open reviews / %d unresolved owned units",c.review,p.unresolvedQty))
    page.rows.chum:SetText(scan.built and string.format("%d basis markets / %d leads / %d manual blocks",scan.total or 0,scan.leads or 0,scan.blocked or 0) or "No census loaded yet. Open Chum to inspect the current candidates.")
    page.rows.market:SetText(string.format("Realm: %s / Region: %s",Age(snapshot.realmTime),Age(snapshot.regionTime)))
end

local function RenderBasis(snapshot)
    local page=UI.pages.basis
    local c=snapshot.coverage
    for _,key in ipairs({"ready","partial","unknown","review","protected","zeroStock"}) do
        page.rows[key]:SetText(c.available and string.format("%d items",c[key]) or "Coverage is not ready yet.")
    end
    page.footer:SetText(string.format("Covered basis: %s across %d items. Resolve unknown units in Cost Coverage.",Money(snapshot.positions.basisValue),snapshot.positions.coveredItems))
end

local function Render()
    local snapshot=Snapshot()
    RenderHome(snapshot); RenderBasis(snapshot)
end

local function ShowPage(name)
    name=UI.pages[name] and name or "home"
    UI.page=name
    for key,page in pairs(UI.pages) do page:SetShown(key==name) end
    for key,button in pairs(UI.nav) do button:SetEnabled(key~=name) end
    Render()
end

local function CreateHome()
    local page=Page("home","Basis Dock","Current accounting and loaded market context. Open the relevant workspace directly from each row.")
    SummaryRow(page,"gold",1,"Liquid gold","Open UBK Home",function() OpenWorkspace("home") end,"TSM's cached balances for this realm and faction. Visit each character to refresh its saved balance.")
    SummaryRow(page,"positions",2,"Covered positions","View Positions",function() OpenWorkspace("position") end,"This is the acquisition cost of fully covered owned inventory. For example, 10 items at 5g basis contribute 50g.")
    SummaryRow(page,"coverage",3,"Cost coverage","Open Coverage",function() OpenWorkspace("coverage") end,"Review trusted, partial, unknown and formula-protected costs without leaving your holdings behind.")
    SummaryRow(page,"review",4,"Needs a cost decision","Review Costs",function() OpenWorkspace("coverage","review") end,"Bring the Cost Coverage review section forward for items awaiting a cost or provenance decision.")
    SummaryRow(page,"chum",5,"Chum scanner","Open Chum",function() OpenWorkspace("chum") end,"Open the retained Chum scanner. The summary here reads its cached census; opening this dock does not run a scan.")
    SummaryRow(page,"market",6,"Loaded market data age","Open Settings",function() OpenWorkspace("settings") end,"These ages describe data already loaded in this WoW session. Reload WoW after the desktop helper writes newer AppData to load that update.")
    local note=Text(page,"GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT",20,16); note:SetSize(654,30)
    note:SetText("Basis records what you paid. Market references help judge whether selling is worthwhile.")
end

local function CreateBasis()
    local page=Page("basis","Basis & Coverage","Choose a category to open Cost Coverage. Review and resolution stay together in the main UBK workspace.")
    local specs={
        {"ready","Trusted basis","View Ready","Costed inventory with trusted provenance."},
        {"partial","Partially costed inventory","Resolve Partial","Some units have a known basis. Resolving the rest preserves the already costed units."},
        {"unknown","Unknown acquisition cost","Resolve Unknown","Enter a supported acquisition cost for inventory whose cost is not yet known."},
        {"review","Open cost reviews","Review Costs","Open the review section within Cost Coverage."},
        {"protected","Formula-protected materials","Review Formulas","Review materials with a protected custom formula and use the explicit basis-pricing action when appropriate."},
        {"zeroStock","Zero-stock cost records","View Zero Stock","Inspect retained cost history for items with no current observed stock."},
    }
    for index,spec in ipairs(specs) do
        local key=spec[1]
        SummaryRow(page,key,index,spec[2],spec[3],function() OpenWorkspace("coverage",key) end,spec[4])
    end
    page.footer=Text(page,"GameFontDisableSmall")
    page.footer:SetPoint("BOTTOMLEFT",20,16); page.footer:SetSize(654,30)
end

local function RefreshAccounting()
    local api=Core()
    if not api or type(api.RefreshAccounting)~="function" then
        UI.status:SetText("UBK accounting is not ready yet.")
        return
    end
    local ok,result=pcall(api.RefreshAccounting,api)
    if not ok or result==false then UI.status:SetText("Accounting could not refresh. Open Cost Coverage for details."); return end
    Render()
    UI.status:SetText("Accounting refreshed from the current loaded data.")
end

local function CreateWindow()
    if UI.root then return end
    local template=BackdropTemplateMixin and "BackdropTemplate" or nil
    local root=CreateFrame("Frame","UBKDockFrame",UIParent,template)
    UI.root=root
    root:SetSize(900,650); root:SetFrameStrata("MEDIUM"); root:SetToplevel(true)
    root:SetClampedToScreen(true); root:SetMovable(true); root:EnableMouse(true); root:RegisterForDrag("LeftButton")
    Backdrop(root)
    local db=GetUIDB()
    root:SetPoint(db.point or "CENTER",UIParent,db.relativePoint or "CENTER",tonumber(db.x) or 0,tonumber(db.y) or 0)
    root:SetScript("OnMouseDown",Raise)
    root:SetScript("OnDragStart",function(self) Raise(); self:StartMoving() end)
    root:SetScript("OnDragStop",function(self)
        self:StopMovingOrSizing()
        local point,_,relativePoint,x,y=self:GetPoint(1)
        local saved=GetUIDB(); saved.point=point; saved.relativePoint=relativePoint; saved.x=x; saved.y=y
    end)
    root:SetScript("OnShow",Raise)
    local close=CreateFrame("Button",nil,root,"UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",-4,-4)
    close:SetScript("OnClick",function() root:Hide() end)
    local title=Text(root,"GameFontNormalLarge")
    title:SetPoint("TOPLEFT",18,-17); title:SetText("|cffffcc00UBK|r  Basis Dock")
    local version=Text(root,"GameFontDisableSmall")
    version:SetPoint("TOPRIGHT",-45,-20); version:SetText(VERSION)
    Line(root,12,-49,876)

    local nav=CreateFrame("Frame",nil,root,template)
    nav:SetPoint("TOPLEFT",12,-61); nav:SetPoint("BOTTOMLEFT",12,45); nav:SetWidth(158); Backdrop(nav)
    local navTitle=Text(nav,"GameFontNormal")
    navTitle:SetPoint("TOPLEFT",12,-14); navTitle:SetText("BASIS DESK")
    for index,spec in ipairs({{"home","Dock Home"},{"basis","Basis Summary"}}) do
        local key=spec[1]
        local b=Button(nav,spec[2],134,function() ShowPage(key) end)
        b:SetPoint("TOPLEFT",12,-40-(index-1)*34); UI.nav[key]=b
    end
    Line(nav,12,-116,134)
    local links={{"home","Open UBK"},{"position","Positions"},{"chum","Chum Scanner"},{"cross","Cross-pressure"},{"watch","Watchlist"},{"settings","Settings"}}
    for index,spec in ipairs(links) do
        local key=spec[1]
        local b=Button(nav,spec[2],134,function() OpenWorkspace(key) end)
        b:SetPoint("TOPLEFT",12,-132-(index-1)*34)
    end
    local refresh=Button(nav,"Refresh Accounting",134,RefreshAccounting)
    refresh:SetPoint("BOTTOMLEFT",12,84)
    Tooltip(refresh,"Refresh Accounting","Refresh UBK from currently loaded inventory and accounting data. The existing cost and provenance rules remain in effect.")
    for index,spec in ipairs({{"list","Print Basis List"},{"status","Print Status"}}) do
        local key=spec[1]
        local b=Button(nav,spec[2],134,function()
            if type(_G.UBKInternal)=="table" and type(_G.UBKInternal.SlashHandler)=="function" then _G.UBKInternal.SlashHandler(key) end
        end)
        b:SetPoint("BOTTOMLEFT",12,84-index*34)
    end

    UI.content=CreateFrame("Frame",nil,root,template)
    UI.content:SetPoint("TOPLEFT",180,-61); UI.content:SetPoint("BOTTOMRIGHT",-12,45); Backdrop(UI.content)
    CreateHome(); CreateBasis()
    UI.status=Text(root,"GameFontHighlightSmall")
    UI.status:SetPoint("BOTTOMLEFT",20,15); UI.status:SetSize(856,20)
    UI.status:SetText("/ubk opens the main workspace. /ubk dock opens this summary.")
    local focus=_G.UBKWindowFocus
    if type(focus)=="table" and type(focus.Register)=="function" then focus.Register(root) end
    if type(UISpecialFrames)=="table" then
        local found=false
        for _,name in ipairs(UISpecialFrames) do if name=="UBKDockFrame" then found=true; break end end
        if not found then UISpecialFrames[#UISpecialFrames+1]="UBKDockFrame" end
    end
end

local function Show(page)
    if page=="scans" or page=="settings" then OpenWorkspace("settings"); return end
    CreateWindow()
    ShowPage(page or "home")
    UI.root:Show(); Raise()
end

_G.UBKDock_Show=Show
_G.UBKDockAPI={version=VERSION}
function _G.UBKDockAPI:Show(page) Show(page) end
function _G.UBKDockAPI:GetSnapshot() return Snapshot() end
function _G.UBKDockAPI:Refresh()
    if UI.root then Render() end
end
