-- Embedded under Position Intelligence. This file creates no standalone window.
_G.UBKProspectingUI = _G.UBKProspectingUI or {}
local UI = _G.UBKProspectingUI

local function Money(ctx, value, signed)
    if type(value) ~= "number" then return "—" end
    local text
    if ctx.Money then text = ctx.Money(math.abs(value))
    else text = string.format("%.2fg", math.abs(value) / 10000) end
    if value < 0 then return "|cffff7777-" .. text .. "|r" end
    if signed and value > 0 then return "|cff66ee99+" .. text .. "|r" end
    return text
end

local function Text(ctx, parent, style, x, y, value)
    local f = ctx.MakeText and ctx.MakeText(parent, style) or parent:CreateFontString(nil, "OVERLAY", style or "GameFontHighlightSmall")
    f:SetPoint("TOPLEFT", x, y)
    f:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    f:SetJustifyH("LEFT")
    f:SetText(value)
    return f
end

local function Tooltip(ctx, frame, row)
    if not GameTooltip then return end
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:AddLine(row.name .. " — one prospect = 5 ores", 1, .82, 0)
    GameTooltip:AddLine("Jewelcrafting " .. row.requiredSkill .. " required. Raw gems only.", .75, .85, 1)
    GameTooltip:AddLine(" ")
    if row.yieldWarning then
        GameTooltip:AddLine("YIELD VERIFICATION NEEDED", 1, .4, .2)
        GameTooltip:AddLine(row.yieldWarning, 1, .7, .4, true)
        GameTooltip:AddLine(" ")
    end
    GameTooltip:AddLine("Basis cost for 5: " .. Money(ctx, row.basisCost), 1, 1, 1, true)
    GameTooltip:AddLine("Expected net raw-gem revenue: " .. Money(ctx, row.expectedNetRevenue), 1, 1, 1, true)
    GameTooltip:AddLine("Basis profit per prospect: " .. Money(ctx, row.basisProfit, true), 1, 1, 1, true)
    GameTooltip:AddLine("Ranked cost source: " .. row.costSource .. " | Cost for 5: " .. Money(ctx, row.planningBatchCost), .8, .9, 1, true)
    GameTooltip:AddLine("Expected profit = sum(expected raw gem quantity x its loaded minimum buyout) x 0.95 - (5 x ore acquisition cost).", .8, .9, 1, true)
    GameTooltip:AddLine(string.format("Owned: %s  |  Known cost: %s  |  Unknown cost: %s", tostring(row.owned or "?"), tostring(row.knownQty or "?"), tostring(row.unresolvedQty or "?")), .8, .8, .8, true)
    if row.knownProspects then
        GameTooltip:AddLine(tostring(row.knownProspects) .. " five-ore batches have known acquisition cost in the ownership snapshot.", .8, .8, .8, true)
    end
    if row.status == "Last-basis scenario" then
        GameTooltip:AddLine("This is the last trusted basis scenario; no current owned batch is asserted.", 1, .7, .3, true)
    elseif row.status == "Known-cost portion" then
        GameTooltip:AddLine("Basis applies only to known-cost units. Unknown units are not priced as free.", 1, .7, .3, true)
    end
    if not row.basis and row.recordedBatchCost then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Planning cost for 5: " .. Money(ctx, row.recordedBatchCost) .. " (" .. tostring(row.recordedSource) .. ")", .75, .85, 1, true)
        GameTooltip:AddLine("History-based planning profit: " .. Money(ctx, row.recordedProfit, true), .75, .85, 1, true)
        GameTooltip:AddLine("Historical purchase cost is a planning reference; it does not establish a basis for unresolved stock.", .75, .85, 1, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Loaded ore recent each: " .. Money(ctx, row.oreRecent), 1, 1, 1, true)
    GameTooltip:AddLine("Loaded ore buyout each: " .. Money(ctx, row.oreBuyout), 1, 1, 1, true)
    GameTooltip:AddLine("Profit if buying 5 at that price: " .. Money(ctx, row.buyoutProfit, true), 1, 1, 1, true)
    GameTooltip:AddLine("Break-even ore purchase price each: " .. Money(ctx, row.breakEvenOreBuyout), .8, .85, .9, true)
    GameTooltip:AddLine("Prospect versus selling those 5 ores: " .. Money(ctx, row.prospectVsOreSale, true), .8, .85, .9, true)
    GameTooltip:AddLine("Purchase comparisons use loaded minimum buyouts; available quantity and live price must be checked in the AH.", .75, .75, .75, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Expected raw output per prospect / loaded buyout each", 1, .82, 0)
    for _, output in ipairs(row.outputs) do
        GameTooltip:AddDoubleLine(output.name .. " x" .. string.format("%.4f", output.expectedPerProspect), Money(ctx, output.minBuyout), .9, .9, .9, .9, .9, .9)
    end
    if not row.completePrices then
        GameTooltip:AddLine("Missing buyouts: " .. table.concat(row.missingOutputs, ", ") .. ". Full revenue and profit are withheld.", 1, .45, .35, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Burning Crusade yields use the local baseline when valid, strengthened by your complete prospecting results. Sample averages do not guarantee a particular profit.", .7, .8, .9, true)
    if row.learningNote then GameTooltip:AddLine(row.learningNote,.7,.8,.9,true) end
    GameTooltip:AddLine("Revenue deducts the 5% AH cut. Dust/powder and other byproduct revenue, failed-auction deposits, and gem cuts are excluded.", .7, .8, .9, true)
    GameTooltip:AddLine("This comparison does not change UBK's prospecting or basis-allocation behavior.", .7, .8, .9, true)
    if ctx.ShowMarketItem then GameTooltip:AddLine("Click to inspect this ore.", .5, .9, 1) end
    GameTooltip:Show()
end

function UI.ShowIgnorePrompt(ctx,continueAction)
    local api=ctx.API or _G.UniversalBasisKeeperAPI
    local rows,err=api:GetIgnoredProspectingOres()
    if not rows or #rows==0 then
        if not rows then ctx.UI.prospectingError=err;if ctx.RenderPage then ctx.RenderPage() end
        elseif continueAction then continueAction()
        else ctx.UI.prospectingError="No prospectable ores are on TSM's saved Destroying ignore list.";if ctx.RenderPage then ctx.RenderPage() end end
        return
    end
    local f=UI.ignorePrompt
    if not f then
        f=CreateFrame("Frame","UBKProspectingIgnorePrompt",UIParent,"BackdropTemplate");UI.ignorePrompt=f
        f:SetSize(510,350);f:SetPoint("CENTER");f:EnableMouse(true);f:SetMovable(true);f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart",function(self)self:StartMoving()end);f:SetScript("OnDragStop",function(self)self:StopMovingOrSizing()end)
        if f.SetBackdrop then f:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background-Dark",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=24,edgeSize=24,insets={left=7,right=7,top=7,bottom=7}}) end
        f.title=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge");f.title:SetPoint("TOPLEFT",22,-22);f.title:SetText("Ores ignored by TSM Destroying")
        f.body=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall");f.body:SetPoint("TOPLEFT",22,-58);f.body:SetWidth(466);f.body:SetJustifyH("LEFT")
        f.remove=CreateFrame("Button",nil,f,"UIPanelButtonTemplate");f.remove:SetSize(226,28);f.remove:SetPoint("BOTTOMLEFT",22,23);f.remove:SetText("Remove listed ores from ignore")
        f.keep=CreateFrame("Button",nil,f,"UIPanelButtonTemplate");f.keep:SetSize(208,28);f.keep:SetPoint("BOTTOMRIGHT",-22,23);f.keep:SetText("Keep ignored")
        if _G.UBKWindowFocus then _G.UBKWindowFocus.Register(f) end
        if UISpecialFrames then UISpecialFrames[#UISpecialFrames+1]="UBKProspectingIgnorePrompt" end
    end
    local items,lines={}, {"These ores are on TSM's saved ignore list:"}
    for _,row in ipairs(rows) do
        items[#items+1]=row.itemString
        lines[#lines+1]="• "..row.name..(row.sessionIgnored and " (also skipped this session)" or "")
    end
    lines[#lines+1]="\nRemove these listed ores so TSM can offer them for prospecting? Other ignored items stay unchanged."
    lines[#lines+1]="Temporary session skips require a reload. This does not prospect any items."
    f.body:SetText(table.concat(lines,"\n"))
    f.remove:SetScript("OnClick",function()
        local ok,message=api:RemoveIgnoredProspectingOres(items)
        f:Hide();ctx.UI.prospectingError=message
        if ctx.RenderPage then ctx.RenderPage() end
        if ok and continueAction then continueAction() end
    end)
    f.keep:SetScript("OnClick",function()f:Hide();if continueAction then continueAction() end end)
    f:Show();if _G.UBKWindowFocus then _G.UBKWindowFocus.Raise(f) end
end

function UI.Render(ctx)
    local parent = ctx.UI.content
    local api = ctx.API or _G.UniversalBasisKeeperAPI
    local startY = ctx.y or -96
    if type(api) ~= "table" or type(api.GetProspectingRows) ~= "function" or not _G.UBKTableUI then
        Text(ctx, parent, "GameFontHighlight", 0, startY, "The UBK prospecting comparison is unavailable. Check that UBK and its table module are enabled.")
        return
    end
    local rows = ctx.UI.prospectingRows or {}
    local meta = ctx.UI.prospectingMeta or {}
    local age = "timestamp unavailable"
    if meta.marketTime and type(date) == "function" then age = date("%Y-%m-%d %H:%M", meta.marketTime) end
    local button
    if ctx.MakeButton then button = ctx.MakeButton(parent, "Load & Rank Ores", 168, 27)
    else button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate"); button:SetSize(168,27); button:SetText("Load & Rank Ores") end
    button:SetPoint("TOPLEFT", 0, startY)
    button:SetScript("OnClick", function()
        -- Only this explicit request rebuilds the comparison. Sorting and page
        -- rendering operate on the same price/basis snapshot until pressed again.
        local ok, freshRows, freshMeta = pcall(api.GetProspectingRows, api)
        if ok and type(freshRows) == "table" then
            ctx.UI.prospectingRows = freshRows
            ctx.UI.prospectingMeta = freshMeta or {}
            ctx.UI.prospectingError = freshMeta and freshMeta.error or nil
            ctx.UI.prospectingSort = {key="rankProfit", ascending=false, page=1}
        else
            ctx.UI.prospectingError = "Ore comparison could not load: " .. tostring(freshRows or "no data returned")
        end
        if ctx.RenderPage then ctx.RenderPage() end
    end)
    if ctx.AddButtonTooltip then
        ctx.AddButtonTooltip(button, "Load & Rank Ores", "Read the latest loaded TSM prices and UBK acquisition costs for all seven TBC prospectable ores, then rank by expected raw-gem profit per five ores.", "This refreshes the local comparison; it does not run an Auction House scan. History-only costs are labeled. Missing cost or output quotes stay unavailable.")
    end
    local destroy=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate");destroy:SetSize(174,27);destroy:SetText("Open TSM Destroying")
    destroy:SetPoint("TOPLEFT",179,startY)
    local function UpdateDestroy() destroy:SetEnabled(api.GetBagProspectableOres and #api:GetBagProspectableOres()>0) end
    UpdateDestroy();destroy:RegisterEvent("BAG_UPDATE_DELAYED")
    destroy:SetScript("OnHide",function(self) self:UnregisterEvent("BAG_UPDATE_DELAYED") end)
    destroy:SetScript("OnShow",function(self) self:RegisterEvent("BAG_UPDATE_DELAYED");UpdateDestroy() end)
    destroy:SetScript("OnEvent",function() if destroy:IsShown() then UpdateDestroy() end end)
    destroy:SetScript("OnClick",function()
        UI.ShowIgnorePrompt(ctx,function()
            local ok,err=api:OpenTSMDestroying()
            if not ok then ctx.UI.prospectingError=err;if ctx.RenderPage then ctx.RenderPage() end end
        end)
    end)
    if ctx.AddButtonTooltip then ctx.AddButtonTooltip(destroy,"Open TSM Destroying","Available with more than five of one prospectable ore in your current bags, counting across stacks. Bank and other-character stock do not qualify.","Runs /tsm destroy. TSM still checks your profession, skill and ignored items; you choose and perform every prospect there.") end
    local ignored,ignoreError=api:GetIgnoredProspectingOres()
    local review=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate");review:SetSize(187,27);review:SetPoint("TOPLEFT",365,startY)
    review:SetText(ignored and (#ignored>0 and ("Ignored ores: "..#ignored.." — Review") or "Ore ignore list: clear") or "Check ignored ores")
    review:SetEnabled(not ignored or #ignored>0)
    review:SetScript("OnClick",function()UI.ShowIgnorePrompt(ctx)end)
    if ctx.AddButtonTooltip then ctx.AddButtonTooltip(review,"TSM Destroying ignore list",ignoreError or "Checks all supported prospectable ores on TSM's saved ignore list, including ores not currently in your bags. Review the names before choosing whether to remove them.","No ignores change until you accept. Other ignored items are preserved; session skips remain separate.") end
    Text(ctx, parent, "GameFontHighlightSmall", 564, startY-6, "Automatic learning • all ores")
    Text(ctx, parent, "GameFontDisableSmall", 0, startY-34, ctx.UI.prospectingError or (ctx.UI.prospectingRows and ("Loaded realm data: " .. age .. " | 5% AH cut; no cut-gem or byproduct revenue. Scroll horizontally for all columns.") or "Press Load & Rank Ores to compare acquisition costs, ore recent/minimum buyout, and expected raw-gem sale value."))
    if _G.UBKProspectingSessions then
        local costs=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate");costs:SetSize(150,25);costs:SetPoint("TOPLEFT",0,startY-57);costs:SetText("Resolve Ore Costs")
        costs:SetScript("OnClick",function() _G.UBKProspectingSessions:ReviewCosts() end)
        local status=Text(ctx,parent,"GameFontHighlightSmall",160,startY-61,_G.UBKProspectingSessions:Status())
        status:SetWidth(math.max(200,parent:GetWidth()-164));status:SetHeight(38)
    end
    ctx.UI.prospectingSort = ctx.UI.prospectingSort or {key="rankProfit", ascending=false, page=1}
    local function money(key, signed) return function(r) return Money(ctx, r[key], signed) end end
    local columns = {
        {key="samples",label="Prospects",width=84,align="RIGHT",tooltip="Your complete observed five-ore batches. Hover an ore for baseline weighting and learning status."},
        {key="name", label="Ore", width=155, align="LEFT", text=function(r) return r.name .. (r.yieldWarning and " (!)" or "") end, tooltip="TBC prospectable common ores only. Hover a row for its raw gem yields and source costs."},
        {key="owned", label="Owned", width=52, align="RIGHT", tooltip="Current TSM/UBK ownership snapshot. Quantity does not multiply the profit ranking."},
        {key="costSource", label="Cost source", width=106, align="LEFT", tooltip="UBK basis: trusted acquisition cost, or its labeled last-basis scenario. Buy history: actual TSM purchases used only for planning. Unknown inventory remains unresolved."},
        {key="planningBatchCost", label="Cost / 5", width=98, align="RIGHT", text=money("planningBatchCost"), tooltip="Five times trusted UBK ore basis, otherwise actual recorded purchase or merchant planning cost. Market estimates never become acquisition costs."},
        {key="oreRecent", label="Ore recent / 1", width=109, align="RIGHT", text=money("oreRecent"), tooltip="Loaded DBRecent per ore, for context only. It is not used as your owned ore's cost or as raw-gem sale revenue."},
        {key="oreBuyout", label="Ore min / 1", width=99, align="RIGHT", text=money("oreBuyout"), tooltip="Latest loaded DBMinBuyout per ore, for a possible new purchase. This never replaces owned acquisition basis."},
        {key="expectedNetRevenue", label="Raw net / 5", width=106, align="RIGHT", text=money("expectedNetRevenue"), tooltip="Sum of expected raw gem quantities times each gem's loaded DBMinBuyout, minus 5% AH cut. Withheld if any output price or yield is invalid."},
        {key="rankProfit", label="Profit / 5", width=108, align="RIGHT", text=money("rankProfit", true), tooltip="Expected raw net revenue minus acquisition/planning cost of five ores. The Cost source column tells you whether this uses trusted UBK basis or historical purchase cost. Quantity never changes profit per prospect."},
        {key="buyoutProfit", label="Buy profit / 5", width=110, align="RIGHT", text=money("buyoutProfit", true), tooltip="Expected raw gem net revenue minus buying five ores at their loaded minimum buyout. Check live price and available quantity before buying."},
        {key="breakEvenOreBuyout", label="Break-even / 1", width=116, align="RIGHT", text=money("breakEvenOreBuyout"), tooltip="Expected raw-gem net revenue divided by five. This is the ore's break-even purchase value for prospecting, before failed auction deposits or a profit allowance."},
        {key="pricedOutputs", label="Quotes", width=60, align="RIGHT", text=function(r) return r.priceCoverage end, tooltip="Raw-gem prices available / required. Every output needs a positive loaded minimum buyout before full expected revenue or profit appears."},
    }
    local result = _G.UBKTableUI.Render(ctx, {
        parent=parent, x=0, y=startY-104, width=parent:GetWidth(), height=260,
        rowHeight=30, columns=columns, rows=rows, state=ctx.UI.prospectingSort,
        onChange=function() if ctx.RenderPage then ctx.RenderPage() end end,
        onClick=function(row) if ctx.ShowMarketItem then ctx.ShowMarketItem(row.itemString) end end,
        onEnter=function(frame,row) Tooltip(ctx, frame, row) end,
        emptyText="Press Load & Rank Ores to build the comparison.",
    })
    Text(ctx, parent, "GameFontDisableSmall", 0, startY-374, "(!) Missing or inconsistent local yield data: profit is withheld. Hover for the reason, cost coverage and raw outputs.")
    Text(ctx, parent, "GameFontDisableSmall", 0, startY-397, "Random yields and future sales are uncertain. Ore asks are cached, not a live AH scan. Failed-auction deposits are excluded.")
    if result then result.loadButton = button end
    return result
end

function UI.RenderInspector(ctx,row,top)
    local parent=ctx.UI.content
    local head=Text(ctx,parent,"GameFontHighlightSmall",12,-top,"Current raw-gem yields per FIVE ores • "..tostring(row.samples or 0).." learned prospects")
    head:SetHeight(22)
    local source=Text(ctx,parent,"GameFontDisableSmall",12,-(top+25),tostring(row.yieldSource or "Unavailable"));source:SetHeight(22)
    local note=Text(ctx,parent,"GameFontHighlightSmall",12,-(top+49),row.yieldWarning or row.learningNote or "Expected amounts over many prospects; individual results vary.");note:SetHeight(36)
    ctx.UI.oreYieldSort=ctx.UI.oreYieldSort or {key="expectedPerProspect",ascending=false,page=1}
    _G.UBKTableUI.Render(ctx,{parent=parent,x=12,y=-(top+90),width=parent:GetWidth()-24,height=164,rowHeight=26,
        rows=row.outputs,state=ctx.UI.oreYieldSort,onChange=ctx.RenderPage,
        columns={{key="name",label="Raw gem",width=240},
            {key="expectedPerProspect",label="Expected / 5 ore",width=180,text=function(r)return string.format("%.4f",r.expectedPerProspect) end},
            {key="minBuyout",label="Loaded gem min / 1",width=180,text=function(r)return Money(ctx,r.minBuyout) end}},
        emptyText="No usable yield data yet. Complete prospects build your local dataset."})
    local foot=Text(ctx,parent,"GameFontDisableSmall",12,-(top+260),"Expected quantity is not drop chance: one prospect can yield multiple gems. Rates match Shredder's current estimator; prices are loaded quotes.")
    foot:SetHeight(36)
end
