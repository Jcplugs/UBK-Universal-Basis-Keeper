local Sale=_G.UBKBasisSale
if not Sale then return end
local UI={selected={},sort={key="name",ascending=true,page=1}}
local Render
local function Text(parent,template) return parent:CreateFontString(nil,"OVERLAY",template or "GameFontHighlightSmall") end
local function Button(parent,label,w,h)
    local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate"); b:SetSize(w,h); b:SetText(label); return b
end
local function Money(value)
    local api=_G.UniversalBasisKeeperAPI
    return value and api and api.FormatMoney and api:FormatMoney(value) or "n/a"
end
local function Clear()
    for _,child in ipairs({UI.content:GetChildren()}) do child:Hide() end
    for _,region in ipairs({UI.content:GetRegions()}) do region:Hide() end
end
local function Tooltip(frame,row)
    if not GameTooltip then return end
    GameTooltip:SetOwner(frame,"ANCHOR_RIGHT")
    local api=_G.TSM_API
    local link=api and api.GetItemLink and api.GetItemLink(row.itemString)
    if link then GameTooltip:SetHyperlink(link) else GameTooltip:AddLine(row.name or row.itemString) end
    GameTooltip:AddLine("Original group: "..tostring(row.groupDisplay),.8,.8,.8,true)
    GameTooltip:AddLine(row.reason or row.basisSource or "Basis saved for this session",1,.8,.3,true)
    GameTooltip:Show()
end
local function Status(message) UI.message=message; if UI.root and UI.root:IsShown() then Render() end end
Render=function()
    Clear()
    local session=Sale:GetSession(); local pending=Sale:HasPending()
    local rows,err
    if pending then
        rows={}
        for _,entry in ipairs(session.items) do
            rows[#rows+1]={itemString=entry.item,name=entry.name,qty=entry.quantity,basis=entry.basis,basisSource=entry.basisSource,groupDisplay=entry.original or "Base Group (ungrouped)",reason=entry.error,state=entry.state,min=entry.basis*1.1,normal=entry.basis*1.75,max=entry.basis*5}
        end
    else rows,err=Sale:BagRows() end
    UI.pricingDraft=UI.pricingDraft or {minPct="110",normalPct="175",maxPct="500",postCap="10"}
    local pricing,priceError=Sale:ValidateSettings(pending and session.pricing or UI.pricingDraft)
    pricing=pricing or {minPct=110,normalPct=175,maxPct=500,postCap=10}
    for _,row in ipairs(rows or {}) do
        row.postQuantity=math.min(row.qty or 0,pricing.postCap)
        if row.basis then row.min=row.basis*pricing.minPct/100;row.normal=row.basis*pricing.normalPct/100;row.max=row.basis*pricing.maxPct/100 end
    end
    for _,row in ipairs(rows or {}) do
        if _G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(row.itemString) then
            row.reason=_G.UBKProspectingSessions:Reason(row.itemString)
            row.selectable=false;UI.selected[row.itemString]=nil
            row.basis=nil;row.min=nil;row.normal=nil;row.max=nil;row.postQuantity=0
        elseif not row.selectable then UI.selected[row.itemString]=nil end
    end
    local headline=Text(UI.content,"GameFontNormal")
    headline:SetPoint("TOPLEFT",6,-3); headline:SetPoint("RIGHT",-6,0); headline:SetHeight(30)
    headline:SetText(pending and ("Temporary group: "..session.group) or "Tick bag items to offer above their basis.")
    local info=Text(UI.content); info:SetPoint("TOPLEFT",6,-37); info:SetPoint("RIGHT",-6,0); info:SetHeight(44)
    info:SetText(pending and "Run a TSM Post Scan for this group and approve or skip auctions in TSM. Return Items restores the original groups. Pending moves are recovered at logout and on the next login / reload."
        or ("Up to "..pricing.postCap.." singles per item type • "..pricing.minPct.."% / "..pricing.normalPct.."% / "..pricing.maxPct.."% of basis before AH fees. Below minimum: do not post. Recorded acquisition or recipe material basis; no market-price fallback."))
    local columns={}
    if not pending then columns[#columns+1]={key="selected",label="Select",width=52,value=function(r) return UI.selected[r.itemString] and 1 or 0 end,checkbox=function(r) return UI.selected[r.itemString] end,checkEnabled=function(r) return r.selectable end,onCheck=function(r,value) UI.selected[r.itemString]=(r.selectable and value) or nil; Render() end} end
    columns[#columns+1]={key="name",label="Item",width=170}
    columns[#columns+1]={key="qty",label="In bags",width=58,align="RIGHT"}
    columns[#columns+1]={key="postQuantity",label="Offer up to",width=75,align="RIGHT"}
    columns[#columns+1]={key="groupDisplay",label="Original group",width=202}
    columns[#columns+1]={key="basis",label="Basis / item",width=87,align="RIGHT",text=function(r) return Money(r.basis) end}
    columns[#columns+1]={key="min",label="Min",width=80,align="RIGHT",text=function(r) return Money(r.min) end}
    columns[#columns+1]={key="normal",label="Normal",width=80,align="RIGHT",text=function(r) return Money(r.normal) end}
    columns[#columns+1]={key="max",label="Max",width=80,align="RIGHT",text=function(r) return Money(r.max) end}
    columns[#columns+1]={key="reason",label="Availability",width=280,text=function(r)return r.reason or "Ready" end}
    if pending then columns[#columns+1]={key="state",label="Return status",width=105} end
    local ctx={UI=UI,API=_G.UniversalBasisKeeperAPI,MakeText=Text,MakeButton=Button,RenderPage=Render}
    local T=_G.UBKTableUI
    T.DrawSearch(ctx,UI.content,UI.sort,6,-94,350,Render)
    local shown=rows or {};local tableY,height=-122,310
    if not pending then
        local classify=_G.UBKPositionWatchUI
        local index=classify and classify.ProfessionIndex(ctx) or {}
        for _,row in ipairs(rows or {}) do
            local meta=classify and classify.Classify(ctx,row.itemString,row.name,index) or {}
            row.professions=meta.professions;row.itemType=meta.itemType;row.quality=meta.quality
        end
        T.DrawFilters(ctx,rows or {},UI.sort,-122,"Basis / unit")
        local function Bound(label,x,key)
            local text=Text(UI.content,"GameFontDisableSmall");text:SetPoint("TOPLEFT",x,-162);text:SetText(label)
            local box=CreateFrame("EditBox",nil,UI.content,"InputBoxTemplate");box:SetSize(78,25);box:SetPoint("TOPLEFT",x+85,-156);box:SetAutoFocus(false);box:SetText(UI[key] or "")
            box:SetScript("OnTextChanged",function(self,user)if user then UI[key]=self:GetText() end end)
            box:SetScript("OnEnterPressed",function(self)self:ClearFocus();Render()end)
            box:SetScript("OnEscapePressed",function(self)self:ClearFocus()end)
            return box
        end
        Bound("Min basis (g)",6,"minBasis");Bound("Max basis (g)",183,"maxBasis")
        local low,high,rangeError=T.BasisRange(UI.minBasis,UI.maxBasis)
        shown=rangeError and {} or T.RangeRows(T.FilterRows(rows or {},UI.sort,"basis"),low,high)
        local matching=Button(UI.content,"Select Matching",136,25);matching:SetPoint("TOPLEFT",366,-156)
        matching:SetScript("OnClick",function()
            local lo,hi,e=T.BasisRange(UI.minBasis,UI.maxBasis)
            if e then UI.message=e;Render();return end
            local chosen=T.RangeRows(T.FilterRows(rows or {},UI.sort,"basis"),lo,hi)
            local count;UI.selected,count=T.SelectEligible(chosen)
            UI.message="Selected "..count.." eligible item types matching all filters and basis boundaries, across all pages.";Render()
        end)
        local all=Button(UI.content,"Select All",104,25);all:SetPoint("LEFT",matching,"RIGHT",7,0)
        all:SetScript("OnClick",function()local count;UI.selected,count=T.SelectEligible(rows);UI.message="Selected all "..count.." eligible bag item types, including items hidden by filters.";Render()end)
        local clear=Button(UI.content,"Clear Selection",132,25);clear:SetPoint("LEFT",all,"RIGHT",7,0)
        clear:SetScript("OnClick",function()UI.selected={};UI.message="Selection cleared.";Render()end)
        if rangeError then UI.message=rangeError end
        local specs={{"Min %","minPct",0},{"Normal %","normalPct",161},{"Max %","maxPct",342},{"Singles / type","postCap",501}}
        for _,spec in ipairs(specs) do
            local key=spec[2]
            local label=Text(UI.content,"GameFontDisableSmall");label:SetPoint("TOPLEFT",6+spec[3],-200);label:SetText(spec[1])
            local box=CreateFrame("EditBox",nil,UI.content,"InputBoxTemplate");box:SetSize(75,25);box:SetPoint("TOPLEFT",spec[3]+(key=="postCap" and 108 or 79),-193);box:SetAutoFocus(false);box:SetText(UI.pricingDraft[key])
            box:SetScript("OnTextChanged",function(self,user)if user then UI.pricingDraft[key]=self:GetText() end end)
            box:SetScript("OnEnterPressed",function(self)self:ClearFocus();Render()end)
            box:SetScript("OnEscapePressed",function(self)self:ClearFocus()end)
        end
        local apply=Button(UI.content,"Preview settings",145,25);apply:SetPoint("TOPLEFT",708,-193)
        apply:SetScript("OnClick",function()UI.message=nil;Render()end)
        tableY=-230;height=202
    else shown=T.FilterRows(shown,{search=UI.sort.search}) end
    local matched=Text(UI.content,"GameFontDisableSmall");matched:SetPoint("TOPLEFT",370,-94);matched:SetText(#shown.." of "..#(rows or {}).." item types match • all pages")
    T.Render(ctx,{parent=UI.content,rows=shown,columns=columns,state=UI.sort,x=4,y=tableY,width=924,minWidth=924,height=height,onChange=Render,onEnter=Tooltip,emptyText=err or "No matching bag items. Clear the search/boundaries or change filters. Missing-cost and locked items cannot be selected."})
    local detail=Text(UI.content); detail:SetPoint("TOPLEFT",6,-440); detail:SetPoint("RIGHT",-6,0); detail:SetHeight(48)
    detail:SetText(priceError or UI.message or err or (pending and (session.phase=="conflict" and "A return conflict is preserved. Hover its row to see the original group. Correct the item/group in TSM, then press Return Items again." or "Your original groups and their operations have not been edited.") or "Select only the items you want for this selling session. New purchases and other characters' bags are not added automatically."))
    local refresh=Button(UI.content,"Refresh Bags",122,28); refresh:SetPoint("BOTTOMLEFT",6,4); refresh:SetScript("OnClick",function() UI.message=nil; Render() end)
    local count=0; for _,row in ipairs(rows or {}) do if row.selectable and UI.selected[row.itemString] then count=count+1 end end
    local confirm=Button(UI.content,pending and "Return Items" or ("Confirm — move "..count.." item types"),260,30)
    confirm:SetPoint("BOTTOMRIGHT",-6,4); confirm:SetEnabled(pending or (count>0 and not priceError))
    confirm:SetScript("OnClick",function()
        if pending then local ok,message=Sale:Restore("Return Items button"); Status(message)
        else
            local fresh,why=Sale:ValidateSettings(UI.pricingDraft)
            if not fresh then Status(why);return end
            for key,value in pairs(pricing) do
                if fresh[key]~=value then UI.message="Posting settings changed. Review the updated prices and quantities, then Confirm again.";Render();return end
            end
            local ok,result=Sale:Begin(UI.selected,fresh)
            if ok then UI.selected={}; Status("Items moved. In TSM Auctioning, select only "..result.group.." and run your Post Scan.")
            else Status(result) end
        end
    end)
    if _G.UBKWindowFocus then _G.UBKWindowFocus.RegisterChildren(UI.root) end
end
function Sale:RefreshPending()
    if UI.root and UI.root:IsShown() then Render() end
end
function Sale:Show()
    if not UI.root then
        local f=CreateFrame("Frame","UBKBasisSaleFrame",UIParent,"BackdropTemplate"); UI.root=f
        f:SetSize(966,616); f:SetPoint("CENTER"); f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart",function(self) self:StartMoving() end); f:SetScript("OnDragStop",function(self) self:StopMovingOrSizing() end)
        if f.SetBackdrop then f:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=24,edgeSize=24,insets={left=7,right=7,top=7,bottom=7}}) end
        local title=Text(f,"GameFontNormalLarge"); title:SetPoint("TOPLEFT",22,-22); title:SetText("Sell Above Basis")
        local close=Button(f,"Close",76,26); close:SetPoint("TOPRIGHT",-20,-17); close:SetScript("OnClick",function() f:Hide() end)
        UI.content=CreateFrame("Frame",nil,f); UI.content:SetPoint("TOPLEFT",17,-69); UI.content:SetSize(932,525)
        if _G.UBKWindowFocus then _G.UBKWindowFocus.Register(f) end
        UISpecialFrames[#UISpecialFrames+1]="UBKBasisSaleFrame"
    end
    Render(); UI.root:Show()
    if _G.UBKWindowFocus then _G.UBKWindowFocus.Raise(UI.root) end
end
function Sale:ShowReturnPrompt()
    if not self:HasPending() then return end
    local f=UI.returnPrompt
    if not f then
        f=CreateFrame("Frame","UBKBasisSaleReturnPrompt",UIParent,"BackdropTemplate"); UI.returnPrompt=f
        f:SetSize(470,180); f:SetPoint("CENTER",0,120); f:EnableMouse(true)
        f:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=24,edgeSize=24,insets={left=7,right=7,top=7,bottom=7}})
        local title=Text(f,"GameFontNormalLarge"); title:SetPoint("TOPLEFT",24,-23); title:SetText("Done selling above basis?")
        local text=Text(f); text:SetPoint("TOPLEFT",24,-57); text:SetWidth(422); text:SetHeight(43); text:SetText("Move the items back to their original groups? Choosing No keeps this session until you return them or log out / reload.")
        local yes=Button(f,"Yes — move items back",224,30); yes:SetPoint("BOTTOMLEFT",23,23)
        yes:SetScript("OnClick",function() local ok,message=Sale:Restore("selling complete"); f:Hide(); UI.message=message; print("|cff33ff99UBK:|r "..message); if not ok then Sale:Show() elseif UI.root and UI.root:IsShown() then Render() end end)
        local no=Button(f,"No — keep this session",190,30); no:SetPoint("BOTTOMRIGHT",-23,23); no:SetScript("OnClick",function() f:Hide() end)
        if _G.UBKWindowFocus then _G.UBKWindowFocus.Register(f) end
        UISpecialFrames[#UISpecialFrames+1]="UBKBasisSaleReturnPrompt"
    end
    f:Show(); if _G.UBKWindowFocus then _G.UBKWindowFocus.Raise(f) end
end
SLASH_UBKBASISSALE1="/ubksell"
SlashCmdList.UBKBASISSALE=function() Sale:Show() end
