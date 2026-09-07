-- Read-only recipe shopping quotes. Never changes basis, recipes or operations.
local API = _G.UniversalBasisKeeperAPI
if type(API) ~= "table" then return end
local M = {requests={}}
_G.UBKMaterialScan = M
-- Known reagent-vendor vials remain off the AH list even without a loaded price.
-- Identity only: vendor BUY prices always come from the user's live TSM API.
local VIALS = {[3371]=true,[3372]=true,[8925]=true,[18256]=true}
local function Positive(n) return type(n)=="number" and n>0 and n<math.huge and n==n and n or nil end
local function Key(value)
    if type(value)=="number" then value="i:"..value end
    local id=type(value)=="string" and tonumber(value:match("^i:(%d+)") or value:match("|Hitem:(%d+)"))
    if not id and API.ResolveItem then local resolved=API:ResolveItem(value);id=type(resolved)=="string" and tonumber(resolved:match("^i:(%d+)")) end
    return id and id>0 and "i:"..id or nil,id
end
local function Price(source,item)
    if not TSM_API or type(TSM_API.GetCustomPriceValue)~="function" then return nil end
    local ok,value=pcall(TSM_API.GetCustomPriceValue,source,item)
    return ok and Positive(value) or nil
end
local function Vendor(item)
    local _,id=Key(item);local price=Price("vendorbuy",item)
    return VIALS[id] or price~=nil,price
end
local function Name(item)
    return API.GetItemName and API:GetItemName(item) or item
end
local function State() return API.GetShredderState and API:GetShredderState() or {} end
local function RequestKey(plan) return plan.itemString.."/"..tostring(plan.recipeID) end

function API:GetCraftMaterialPlans(itemArg)
    local item=Key(itemArg)
    if not item then return {},"Inspect a crafted item first." end
    local context=self:GetRuntimeContext()
    if not context or context.supported==false then return {},"Recipe shopping supports TBC Anniversary." end
    local scope="f@"..tostring(context.faction).." - "..tostring(context.realm).."@internalData@crafts"
    local crafts=type(TradeSkillMasterDB)=="table" and TradeSkillMasterDB[scope]
    local plans={}
    for id,recipe in pairs(type(crafts)=="table" and crafts or {}) do
        if type(recipe)=="table" and Key(recipe.itemString)==item and type(recipe.mats)=="table" and Positive(tonumber(recipe.numResult)) then
            local rows,valid,total,complete={},true,0,true
            local quantities={}
            for reagent,quantity in pairs(recipe.mats) do
                local key=Key(reagent);quantity=tonumber(quantity)
                if not key or not Positive(quantity) or quantity~=math.floor(quantity) then valid=false;break end
                quantities[key]=(quantities[key] or 0)+quantity
            end
            for reagent,quantity in pairs(quantities) do
                local cost=self.GetMaterialCost and Positive(self:GetMaterialCost(reagent))
                rows[#rows+1]={itemString=reagent,quantity=quantity}
                if cost then total=total+cost*quantity else complete=false end
            end
            if valid and #rows>0 then
                table.sort(rows,function(a,b)return a.itemString<b.itemString end)
                local signature={tostring(recipe.numResult)}
                for _,row in ipairs(rows) do signature[#signature+1]=row.itemString.."="..row.quantity end
                plans[#plans+1]={itemString=item,recipeID=tostring(id),outputQuantity=tonumber(recipe.numResult),reagents=rows,
                    signature=table.concat(signature,";"),recordedTotal=complete and total or nil}
            end
        end
    end
    table.sort(plans,function(a,b)
        if (a.recordedTotal~=nil)~=(b.recordedTotal~=nil) then return a.recordedTotal~=nil end
        local av=a.recordedTotal and a.recordedTotal/a.outputQuantity
        local bv=b.recordedTotal and b.recordedTotal/b.outputQuantity
        if av and av~=bv then return av<bv end
        return a.recipeID<b.recipeID
    end)
    return plans,#plans==0 and "No recorded recipe. Open the relevant profession so TSM can learn it, then inspect again." or nil
end

function M.SelectPlan(ctx,item)
    local plans,err=API:GetCraftMaterialPlans(item)
    ctx.UI.materialRecipe=ctx.UI.materialRecipe or {}
    local selected=ctx.UI.materialRecipe[item]
    for _,plan in ipairs(plans) do if plan.recipeID==selected then return plan,plans end end
    if plans[1] then ctx.UI.materialRecipe[item]=plans[1].recipeID end
    return plans[1],plans,err
end

function API:ScanCraftingMaterials(itemArg,recipeID)
    local plans,err=self:GetCraftMaterialPlans(itemArg)
    local plan
    for _,candidate in ipairs(plans) do if candidate.recipeID==tostring(recipeID) then plan=candidate;break end end
    if not plan then return false,err or "Choose a recorded recipe before scanning its materials." end
    local queue,vendors={},{}
    for _,row in ipairs(plan.reagents) do
        local vendor=Vendor(row.itemString)
        if vendor then vendors[row.itemString]=true else queue[#queue+1]=row.itemString end
    end
    local request={signature=plan.signature,vendors=vendors,requestedAt=type(time)=="function" and time() or 0}
    if #queue>0 then
        if not self.IsAuctionVisible or not self:IsAuctionVisible() then return false,"Open the Auction House, then click Scan Mats." end
        if type(QueryAuctionItems)~="function" then return false,"The exact-item Auction House scanner is unavailable." end
        for _,item in ipairs(queue) do
            local _,id=Key(item)
            if type(GetItemInfo)~="function" or not GetItemInfo(id) then
                if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
                return false,"Material names are still loading. Hover the reagents or try Scan Mats again."
            end
        end
        local ok,message=self:StartShredderLiveStockRefresh(queue)
        if not ok then return false,message end
        local state=State();request.token=state.liveToken;request.startedAt=state.liveStartedAt
    end
    M.requests[RequestKey(plan)]=request
    return true,#queue==0 and "Vendor supplies only; no Auction House queries needed." or "Scanning the recipe's Auction House materials."
end

function M.Snapshot(plan)
    local request=M.requests[RequestKey(plan)]
    if request and request.signature~=plan.signature then request=nil end
    local state=State()
    local running=request and request.token and state.liveScanning and state.liveToken==request.token and state.liveStartedAt==request.startedAt
    local result={rows={},recordedTotal=0,quoteTotal=0,outputQuantity=plan.outputQuantity,complete=true,limited=false}
    local recordedComplete,quotedComplete=true,true
    for _,reagent in ipairs(plan.reagents) do
        local item=reagent.itemString
        local vendor,vendorPrice=Vendor(item)
        vendor=vendor or (request and request.vendors[item]) or false
        local row={itemString=item,name=Name(item),quantity=reagent.quantity,source=vendor and "Vendor" or "AH"}
        row.materialCost=API.GetMaterialCost and Positive(API:GetMaterialCost(item))
        if row.materialCost then result.recordedTotal=result.recordedTotal+row.materialCost*row.quantity else recordedComplete=false end
        if vendor then
            row.unitQuote=vendorPrice;row.status=vendorPrice and "Vendor buy quote" or "Vendor price needed"
        else
            local quote=API.GetShredderLiveStock and API:GetShredderLiveStock(item)
            local fresh=request and request.token and request.startedAt and quote and quote.scanToken==request.token and quote.scanStartedAt==request.startedAt
            if fresh then
                row.unitQuote=Positive(quote.low);row.atMinimum=quote.lowUnits;row.updatedAt=quote.updatedAt
                row.status=not row.unitQuote and (quote.complete and "No buyouts found" or "None seen; partial") or (quote.complete and "Scanned" or "Partial scan")
                if not quote.complete then result.complete=false end
                if row.unitQuote and (tonumber(row.atMinimum) or 0)<row.quantity then row.status=row.status.."; low stock";result.limited=true end
            else row.status=running and "Queued / scanning" or "Not scanned in this run" end
        end
        if row.unitQuote then row.lineQuote=row.unitQuote*row.quantity;result.quoteTotal=result.quoteTotal+row.lineQuote else quotedComplete=false end
        result.rows[#result.rows+1]=row
    end
    if not recordedComplete then result.recordedTotal=nil end
    if not quotedComplete then result.quoteTotal=nil;result.complete=false end
    result.recordedPerOutput=result.recordedTotal and result.recordedTotal/plan.outputQuantity
    result.quotePerOutput=result.quoteTotal and result.quoteTotal/plan.outputQuantity
    result.status=running and (state.liveStatus or "Scanning materials…") or (request and "Material quotes from this recipe scan. Hover rows for quote details." or "Click Scan Mats to quote the AH reagents. Vendor supplies are excluded from the scan.")
    return result
end

function M.Render(ctx,item,top)
    local plan,plans,err=M.SelectPlan(ctx,item)
    local parent=ctx.UI.content
    local function Line(y,text,font,height)
        local label=ctx.MakeText(parent,font or "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT",12,-y);label:SetPoint("RIGHT",-10,0);label:SetHeight(height or 20);label:SetText(text)
        return label
    end
    if not plan then Line(top,err);return end
    local options={}
    for _,p in ipairs(plans) do options[#options+1]={value=p.recipeID,label=p.recipeID.." ("..p.outputQuantity.." output)"} end
    _G.UBKTableUI.Picker(ctx,parent,12,-top,286,"Recipe",plan.recipeID,options,function(id)
        ctx.UI.materialRecipe[item]=id;ctx.UI.materialError=nil;ctx.RenderPage()
    end,"Uses a learned TSM recipe. Quantities are for ONE craft, with its recorded output count. With multiple recipes, the initial choice is the lowest fully costed recipe per output.")
    local snapshot=M.Snapshot(plan)
    Line(top+31,ctx.UI.materialError or snapshot.status,"GameFontDisableSmall")
    ctx.UI.materialSort=ctx.UI.materialSort or {key="name",ascending=true,page=1}
    local function money(key) return function(row)return row[key] and ctx.Money(row[key]) or "—" end end
    _G.UBKTableUI.Render(ctx,{parent=parent,x=12,y=-(top+56),width=parent:GetWidth()-24,minWidth=parent:GetWidth()-24,height=180,rowHeight=27,
        rows=snapshot.rows,state=ctx.UI.materialSort,onChange=ctx.RenderPage,
        columns={
            {key="name",label="Material",width=168},
            {key="quantity",label="Need",width=45,align="RIGHT"},
            {key="source",label="Buy from",width=72},
            {key="materialCost",label="UBK cost / 1",width=104,align="RIGHT",text=money("materialCost"),tooltip="Material planning cost: trusted UBK basis, then recorded average purchases, then vendor buy. Current AH quotes never replace it."},
            {key="unitQuote",label="Quote / 1",width=98,align="RIGHT",text=money("unitQuote"),tooltip="AH minimum observed in this recipe scan, or TSM vendorbuy. Vendor sell value is never used."},
            {key="lineQuote",label="Need × quote",width=109,align="RIGHT",text=money("lineQuote"),tooltip="Minimum unit price multiplied by recipe quantity. An estimate, not a promise that this quantity can be purchased at that price."},
            {key="atMinimum",label="At AH min",width=76,align="RIGHT",tooltip="Observed units offered at the minimum unit price. AH stacks may require buying more than your recipe needs."},
            {key="status",label="Quote status",width=156},
        },onEnter=function(owner,row)
            if not GameTooltip then return end
            GameTooltip:SetOwner(owner,"ANCHOR_RIGHT");GameTooltip:AddLine(row.name,1,.82,.3)
            GameTooltip:AddLine(row.quantity.." needed for one craft; "..plan.outputQuantity.." output item(s).",1,1,1,true)
            GameTooltip:AddLine(row.source=="Vendor" and "Vendor BUY quote from TSM. Check merchant availability and discounts; this reagent is not sent to the AH scanner." or "This recipe scan's lowest observed unit buyout. Check available quantities and whole-stack purchase costs before buying.",.8,.9,1,true)
            if row.updatedAt then GameTooltip:AddLine("AH quote age: "..ctx.Age(row.updatedAt),.8,.8,.8,true) end
            GameTooltip:AddLine(row.status,1,.8,.4,true);GameTooltip:Show()
        end})
    local recorded=snapshot.recordedTotal and ctx.Money(snapshot.recordedTotal) or "incomplete"
    local shopping=snapshot.quoteTotal and ctx.Money(snapshot.quoteTotal) or "incomplete"
    local flags=(not snapshot.complete and " • partial / missing quotes" or "")..(snapshot.limited and " • cheapest stock is limited" or "")
    Line(top+242,"One craft: UBK material cost "..recorded.." | Minimum-price estimate "..shopping..flags,"GameFontHighlightSmall",20)
    Line(top+266,"Per output: cost "..(snapshot.recordedPerOutput and ctx.Money(snapshot.recordedPerOutput) or "incomplete").." | quote estimate "..(snapshot.quotePerOutput and ctx.Money(snapshot.quotePerOutput) or "incomplete")..". Quantities and whole stacks can raise the actual bill.","GameFontDisableSmall",30)
end
