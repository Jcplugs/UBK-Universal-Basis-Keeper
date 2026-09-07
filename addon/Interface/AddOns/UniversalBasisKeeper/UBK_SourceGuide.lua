-- Read-only inventory of the installed UBK price bridge and its custom aliases.
-- No source, crafting operation, material override, or user ledger is changed.
_G.UBKSourceGuide = {}
local Guide=_G.UBKSourceGuide
local UI={nativeState={key="name",ascending=true,page=1},aliasState={key="name",ascending=true,page=1}}
local nativeDefinitions={
    ubksellbasis={
        name="ubksellbasis",description="Basis captured for the active Sell Above Basis session.",
        formula="selected item's confirmed session basis",
        detail="Uses the trusted acquisition basis captured when you confirmed a temporary selling session. If acquisition basis was unavailable, a fully costed recipe supplied material basis. The price is fixed for this session.",
        example="Example: a 5g session basis produces 5g50s minimum, 8g75s normal, and 25g maximum. Returning the item ends this session quote.",
        missing="No active session, no selected item, or unresolved costs: no value. This source is intended for UBK's temporary selling operation.",
    },
    ubkbasis={
        name="ubkbasis",description="Trusted acquisition basis in UBK's known-cost pool.",
        formula="known-cost pool value / known quantity",
        detail="Reads proven UBK acquisition cost. Unknown-cost units are excluded from that pool, never assigned zero. A trusted last basis can remain available at zero stock. Untrusted or unreviewed economic values do not become acquisition basis.",
        example="Example: 10 known-cost gems bought for 50g total give 5g each. An unknown extra gem is not silently included as free.",
        missing="Without trusted UBK cost, this source returns no value. It does not substitute an auction-market price.",
    },
    ubkmatcost={
        name="ubkmatcost",description="UBK basis, then recorded average purchases, then vendor cost.",
        formula="first(ubkbasis, avgbuy, vendorbuy)",
        detail="For material planning, use trusted UBK acquisition basis first. If unavailable, use TSM's quantity-weighted recorded purchase average, then its recorded merchant quote. These fallbacks do not write invented costs into UBK inventory.",
        example="Example: UBK basis of 5g wins even if the market says 8g. With no UBK basis, a recorded average purchase of 4g becomes the planning cost. A vial can use its vendor price when no purchase average exists.",
        missing="Missing all three recorded cost inputs leaves the material cost unavailable. DBMarket and DBRecent are not cost fallbacks.",
    },
    ubkcrafting={
        name="ubkcrafting",description="Known recipe reagent cost, divided by its output quantity.",
        formula="sum(reagent quantity * ubkmatcost(reagent)) / recipe output quantity",
        detail="Adds each learned recipe's reagent quantities at UBK material cost and divides by the recipe's output count. When multiple known recipes create the same item, it uses the lowest fully costed recipe. It is per output item, not the cost of the whole batch.",
        example="Example: one 5g uncut gem produces one cut gem, so every such cut costs 5g. A 10g recipe producing two items costs 5g per item.",
        missing="A recipe with any missing reagent cost cannot supply a value. Unknown recipes stay unavailable. Market sale prices are separate from crafting cost.",
    },
}

local function Text(ctx,parent,font)
    if ctx.MakeText then return ctx.MakeText(parent,font) end
    local f=parent:CreateFontString(nil,"OVERLAY",font or "GameFontHighlightSmall");f:SetJustifyH("LEFT");return f
end
local function Button(ctx,parent,label,w,h)
    if ctx.MakeButton then return ctx.MakeButton(parent,label,w,h) end
    local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate");b:SetSize(w,h);b:SetText(label);return b
end
local function Availability(value)
    if value==true then return "Available" end
    if value==false then return "Not registered" end
    return "Not reported"
end

function Guide.Read(ctx)
    local api=ctx.API or _G.UniversalBasisKeeperAPI
    if type(api)~="table" or type(api.GetPricingIntegrationInfo)~="function" then return nil,"The cost-source status service is unavailable. Check that UBK and its interface are the same version." end
    local ok,info=pcall(api.GetPricingIntegrationInfo,api,nil)
    if not ok or type(info)~="table" then return nil,"UBK could not read the current TSM source configuration." end
    return info
end

function Guide.Rows(info)
    local byKey={}
    for _,source in ipairs(info and info.native or {}) do byKey[source.key]=source end
    local native={}
    for _,key in ipairs({"ubkbasis","ubkmatcost","ubkcrafting","ubksellbasis"}) do
        local definition=nativeDefinitions[key]
        local row={};for k,v in pairs(definition)do row[k]=v end
        local status=byKey[key]
        row.available=status and status.available
        row.status=Availability(row.available)
        row.kind="native"
        row.aliases=status and status.aliases or {}
        native[#native+1]=row
    end
    local aliases={}
    for _,source in ipairs(info and info.aliases or {}) do
        local references={};for _,key in ipairs(source.references or {})do references[#references+1]=key end
        table.sort(references)
        aliases[#aliases+1]={name=source.name,formula=source.expression,description=source.expression,
            references=references,inputs=table.concat(references,", "),available=source.available,
            status=source.available==true and "Available" or (source.available==false and "Invalid / missing input" or "Not reported"),kind="alias"}
    end
    return native,aliases
end

-- Display-only expansion of the aliases already identified by the core API.
-- The shared API owns reference discovery and availability, not this window.
function Guide.Chain(row,aliases)
    local index={};for _,alias in ipairs(aliases or {})do index[alias.name]=alias end
    local lines,seen={},{}
    local function Add(current,depth)
        if seen[current.name] then return end
        seen[current.name]=true
        lines[#lines+1]=current.name.." = "..tostring(current.formula or "n/a")
        if depth>=12 then lines[#lines+1]="Further links omitted from this tooltip; inspect their source rows.";return end
        for token in tostring(current.formula or ""):lower():gmatch("[%a_][%w_]*") do
            if index[token] then Add(index[token],depth+1) end
        end
    end
    Add(row,0)
    return lines
end

local function Tooltip(owner,row,aliases)
    if not GameTooltip then return end
    GameTooltip:SetOwner(owner,"ANCHOR_RIGHT")
    GameTooltip:AddLine(row.name,1,.82,.3)
    GameTooltip:AddLine("TSM status: "..row.status,.7,.85,1,true)
    if row.kind=="native" then
        GameTooltip:AddLine(row.detail,.9,.9,.9,true)
        GameTooltip:AddLine(row.example,.6,1,.7,true)
        GameTooltip:AddLine(row.missing,1,.75,.4,true)
        if #row.aliases>0 then GameTooltip:AddLine("Direct custom aliases: "..table.concat(row.aliases,", "),.65,.85,1,true) end
        if row.name=="ubkmatcost" then GameTooltip:AddLine("The example expression describes the native source's fallback order; this window does not create a custom source.",.7,.7,.7,true) end
    else
        GameTooltip:AddLine("Installed custom source chain:",1,.82,.3)
        for _,line in ipairs(Guide.Chain(row,aliases))do GameTooltip:AddLine(line,.9,.9,.9,true)end
        GameTooltip:AddLine("UBK inputs: "..row.inputs,.6,1,.7,true)
        GameTooltip:AddLine("The formula is read from your current TSM configuration. Availability validates the expression; a particular item may still have no price.",.75,.75,.75,true)
    end
    GameTooltip:AddLine("Click to select the source text below the tables for copying.",.65,.85,1,true)
    GameTooltip:Show()
end

local function ClearContent()
    for _,child in ipairs({UI.content:GetChildren()})do child:Hide()end
    for _,region in ipairs({UI.content:GetRegions()})do region:Hide()end
end

local function Render()
    local ctx=UI.ctx
    ClearContent()
    local info,err=Guide.Read(ctx)
    local native,aliases=Guide.Rows(info)
    UI.snapshot=info;UI.nativeRows=native;UI.aliasRows=aliases
    local title=Text(ctx,UI.content,"GameFontNormalSmall");title:SetPoint("TOPLEFT",0,0);title:SetWidth(866)
    title:SetText(err or (info and info.label) or "Cost-source status unavailable")
    title:SetTextColor(err and 1 or .65,err and .65 or .85,err and .4 or 1)
    local fallback=Text(ctx,UI.content,"GameFontHighlightSmall");fallback:SetPoint("TOPLEFT",0,-22);fallback:SetWidth(866)
    local statuses={}
    for _,source in ipairs(info and info.fallbacks or {})do statuses[#statuses+1]=source.key..": "..Availability(source.available)end
    fallback:SetText(#statuses>0 and ("Recorded cost fallbacks — "..table.concat(statuses," | ")) or "Recorded cost fallbacks: avgbuy / vendorbuy availability not reported")
    local nativeTitle=Text(ctx,UI.content,"GameFontNormal");nativeTitle:SetPoint("TOPLEFT",0,-49);nativeTitle:SetText("UBK PRICE SOURCES")
    local selected=UI.selected or ""
    local function Select(row)
        UI.selected=row.kind=="native" and row.name or row.formula
        UI.formula:SetText(UI.selected or "");UI.formula:SetFocus();UI.formula:HighlightText()
        UI.detail:SetText(row.kind=="native" and row.example or (row.name.." uses "..row.inputs..". Hover its row for the complete linked formulas."))
    end
    local grid=_G.UBKTableUI
    if not grid then title:SetText("The UBK table module is unavailable.");return end
    grid.Render(ctx,{parent=UI.content,x=0,y=-69,width=866,height=180,minWidth=866,
        columns={{key="name",label="Source",width=145},{key="description",label="What it means",width=549},{key="status",label="TSM availability",width=172}},
        rows=native,state=UI.nativeState,onChange=Render,onClick=Select,onEnter=function(owner,row)Tooltip(owner,row,aliases)end})
    local aliasTitle=Text(ctx,UI.content,"GameFontNormal");aliasTitle:SetPoint("TOPLEFT",0,-257);aliasTitle:SetText("YOUR UBK-CONNECTED CUSTOM SOURCES ("..#aliases..")")
    grid.Render(ctx,{parent=UI.content,x=0,y=-278,width=866,height=169,minWidth=866,
        columns={{key="name",label="Custom source",width=145},{key="formula",label="Installed formula",width=368},{key="inputs",label="UBK inputs",width=205},{key="status",label="TSM availability",width=148}},
        rows=aliases,state=UI.aliasState,onChange=Render,onClick=Select,onEnter=function(owner,row)Tooltip(owner,row,aliases)end,
        emptyText="No UBK-connected custom sources are configured. This window does not create any."})
    local label=Text(ctx,UI.content,"GameFontDisableSmall");label:SetPoint("TOPLEFT",0,-455);label:SetText("Selected source / formula — click the field and press Ctrl+C to copy")
    local edit=CreateFrame("EditBox",nil,UI.content,"InputBoxTemplate");edit:SetPoint("TOPLEFT",5,-477);edit:SetSize(850,25);edit:SetAutoFocus(false);edit:SetText(selected);UI.formula=edit
    edit:SetScript("OnEscapePressed",function(self)self:ClearFocus()end)
    -- It is a local copy buffer; typing here never writes a TSM setting.
    local detail=Text(ctx,UI.content,"GameFontHighlightSmall");detail:SetPoint("TOPLEFT",0,-511);detail:SetWidth(866);detail:SetHeight(43);detail:SetWordWrap(true);UI.detail=detail
    detail:SetText(not info and "Source availability could not be read. The definitions explain the available UBK cost methods; they do not confirm a working TSM connection."
        or (info.integration=="native" and "Your installed TSM recognizes UBK's native source bridge. Available means registered; item values still need recorded costs and known recipes."
        or "Standard TSM can receive supported material costs through UBK's material write-through. Native UBK names require a compatible price-source bridge; this window does not add one."))
    if _G.UBKWindowFocus then _G.UBKWindowFocus.RegisterChildren(UI.root)end
end

function Guide.Show(ctx)
    ctx=ctx or {};UI.ctx=ctx
    if not UI.root then
        local frame=CreateFrame("Frame","UBKSourceGuideFrame",UIParent,"BackdropTemplate");UI.root=frame
        frame:SetSize(900,644);frame:SetPoint("CENTER",UIParent,"CENTER",0,0);frame:EnableMouse(true);frame:SetMovable(true);frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart",function(self)self:StartMoving()end);frame:SetScript("OnDragStop",function(self)self:StopMovingOrSizing()end)
        if frame.SetBackdrop then frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=24,edgeSize=24,insets={left=7,right=7,top=7,bottom=7}});frame:SetBackdropColor(.025,.022,.015,1)end
        local title=Text(ctx,frame,"GameFontNormalLarge");title:SetPoint("TOPLEFT",17,-17);title:SetText("Available Cost Sources")
        local subtitle=Text(ctx,frame,"GameFontDisableSmall");subtitle:SetPoint("TOPLEFT",17,-43);subtitle:SetWidth(866);subtitle:SetText("Read your installed sources and how they connect. Hover for definitions and gold examples.")
        local close=Button(ctx,frame,"Close",75,23);close:SetPoint("TOPRIGHT",-14,-13);close:SetScript("OnClick",function()frame:Hide()end)
        local refresh=Button(ctx,frame,"Refresh sources",126,23);refresh:SetPoint("RIGHT",close,"LEFT",-8,0);refresh:SetScript("OnClick",Render)
        UI.content=CreateFrame("Frame",nil,frame);UI.content:SetPoint("TOPLEFT",17,-76);UI.content:SetSize(866,554)
        if _G.UBKWindowFocus then _G.UBKWindowFocus.Register(frame)else frame:SetFrameStrata("HIGH");frame:SetToplevel(true)end
        if type(UISpecialFrames)=="table" then UISpecialFrames[#UISpecialFrames+1]="UBKSourceGuideFrame"end
    end
    Render();UI.root:Show()
    if _G.UBKWindowFocus then _G.UBKWindowFocus.Raise(UI.root)else UI.root:Raise()end
    return UI.root
end
