-- Owned disenchant work and settled output history, embedded in Positions.
-- This view reads UBK's existing pipeline/history. It never starts a scan or
-- modifies acquisition accounting, transfers, or transformations.
_G.UBKShredInventoryUI = {}
local S = _G.UBKShredInventoryUI

local function Number(value)
    value=tonumber(value)
    return value and value==value and value>=0 and value<math.huge and value or nil
end
local function Positive(value)
    value=Number(value)
    return value and value>0 and value or nil
end
local function Plain(value)
    return tostring(value or ""):gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")
end
local function Name(ctx,item,fallback)
    return Plain(fallback or (ctx.ItemName and ctx.ItemName(item)) or item or "Unknown item")
end
local function Money(ctx,value)
    if not Positive(value) then return "Unknown" end
    return ctx.Money and ctx.Money(value) or string.format("%.2fg",value/10000)
end
local function Date(value)
    return Positive(value) and type(date)=="function" and date("%Y-%m-%d %H:%M",value) or "Unknown"
end
local function Read(ctx,method)
    local api=ctx.API or _G.UniversalBasisKeeperAPI
    if type(api)~="table" or type(api[method])~="function" then return nil,"UBK's "..method.." service is unavailable." end
    local ok,result=pcall(api[method],api)
    if not ok or type(result)~="table" then return nil,"UBK could not read the current "..(method=="GetShredderHistory" and "disenchant history." or "owned disenchant inventory.") end
    return result
end

function S.InventoryRows(ctx)
    local source,err=Read(ctx,"GetShredderPipeline")
    if not source then return {},err end
    local rows={}
    for _,raw in ipairs(source) do
        if type(raw)=="table" then
            local locations={}
            for _,place in ipairs(type(raw.locations)=="table" and raw.locations or {}) do locations[#locations+1]=tostring(place) end
            table.sort(locations)
            rows[#rows+1]={
                itemString=raw.itemString,name=Name(ctx,raw.itemString,raw.itemName),qty=Number(raw.qty),
                status=raw.status or "OWNED",location=#locations>0 and table.concat(locations,", ") or nil,
                basis=raw.trusted==true and Positive(raw.basis) or nil,
                source=raw.acquisitionSource,raw=raw,
            }
        end
    end
    return rows
end

function S.HistoryRows(ctx)
    local source,err=Read(ctx,"GetShredderHistory")
    if not source then return {},err end
    local rows={}
    for _,raw in ipairs(source) do
        if type(raw)=="table" then
            local outputs={}
            for item,quantity in pairs(type(raw.outputs)=="table" and raw.outputs or {}) do
                outputs[#outputs+1]={itemString=item,name=Name(ctx,item),quantity=Number(quantity)}
            end
            table.sort(outputs,function(a,b) if a.name~=b.name then return a.name<b.name end; return tostring(a.itemString)<tostring(b.itemString) end)
            local labels={}
            for _,output in ipairs(outputs) do labels[#labels+1]=tostring(output.quantity or "?").." x "..output.name end
            rows[#rows+1]={
                itemString=raw.sourceItem,name=Name(ctx,raw.sourceItem),time=Positive(raw.time),
                sourceCost=raw.sourceTrusted~=false and Positive(raw.sourceCost) or nil,
                outputs=outputs,outputText=#labels>0 and table.concat(labels,", ") or nil,
                status=raw.status,raw=raw,
            }
        end
    end
    return rows
end

local function Line(text,r,g,b)
    if GameTooltip then GameTooltip:AddLine(text,r or .9,g or .9,b or .9,true) end
end
local function Tooltip(ctx,owner,row,history)
    if not GameTooltip then return end
    local normal=false
    if type(ctx.ShowItemTooltip)=="function" then
        normal=pcall(ctx.ShowItemTooltip,owner,row.itemString,"ANCHOR_RIGHT")
    else
        GameTooltip:SetOwner(owner,"ANCHOR_RIGHT")
        local id=tostring(row.itemString or ""):match("^i:(%d+)") or tostring(row.itemString or ""):match("item:(%d+)")
        if id and GameTooltip.SetHyperlink then normal=pcall(GameTooltip.SetHyperlink,GameTooltip,"item:"..id) end
    end
    if not normal then GameTooltip:SetOwner(owner,"ANCHOR_RIGHT"); Line(row.name,1,.82,.3) end
    Line(" ")
    if history then
        Line("Settled disenchant record",1,.82,.3)
        Line("Recorded: "..Date(row.time))
        Line("Source cost: "..Money(ctx,row.sourceCost))
        Line("Status: "..tostring(row.status or "Unknown"))
        if #row.outputs>0 then
            Line("Actual output materials:",.6,.85,1)
            for _,output in ipairs(row.outputs) do Line(tostring(output.quantity or "?").." x "..output.name) end
        else Line("No output materials were recorded.",1,.7,.35) end
        if not row.sourceCost then Line("The source cost is unknown; these outputs are not valued as free.",1,.7,.35) end
    else
        Line("Owned to shred",1,.82,.3)
        Line("Qualifying quantity: "..tostring(row.qty or "Unknown").." | "..tostring(row.status))
        Line("Acquisition basis each: "..Money(ctx,row.basis))
        Line("Acquisition evidence: "..tostring(row.source or "Unknown"))
        Line("Locations (character: units): "..tostring(row.location or "Unknown"))
        local details={
            {"Ready",row.raw.readyQty},{"In mail",row.raw.pendingMailQty},{"Other characters",row.raw.otherQty},
            {"Stored",row.raw.storedQty},{"Listed",row.raw.listedQty},
        }
        local parts={}
        for _,detail in ipairs(details) do if Number(detail[2]) then parts[#parts+1]=detail[1].." "..tostring(detail[2]) end end
        if #parts>0 then Line(table.concat(parts," | "),.7,.8,.9) end
        Line("Qualifying quantity is capped by recorded acquisition evidence and current ownership. Location totals describe all copies of this item.",.7,.8,.9)
        if not row.basis then Line("A trusted acquisition basis is not available; resolve costs in Cost Coverage.",1,.7,.35) end
    end
    if ctx.ShowMarketItem then Line("Click to open Market Inspector.",.55,.9,1) end
    GameTooltip:Show()
end

function S.Render(ctx)
    if ctx.PageTitle then ctx.PageTitle("Owned to Shred","Review your owned disenchantable items and their recorded output history.") end
    local ui=ctx.UI
    local parent=ui.content
    local top=ctx.y or -96
    local tableUI=_G.UBKTableUI
    if not tableUI then
        local text=ctx.MakeText(parent,"GameFontHighlightSmall")
        text:SetPoint("TOPLEFT",6,top); text:SetText("The UBK table module is unavailable.")
        return
    end
    ui.shredInventoryMode=ui.shredInventoryMode=="history" and "history" or "inventory"
    for index,spec in ipairs({{"inventory","Inventory"},{"history","History"}}) do
        local mode,label=spec[1],spec[2]
        local b=ctx.MakeButton(parent,label,112,25); b:SetPoint("TOPLEFT",6+(index-1)*120,top)
        b:SetScript("OnClick",function() ui.shredInventoryMode=mode; if ctx.RenderPage then ctx.RenderPage() end end)
        if mode==ui.shredInventoryMode and b.LockHighlight then b:LockHighlight() end
        b:SetScript("OnEnter",function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); Line(label,1,.82,.3)
                Line(mode=="history" and "Read the actual output materials and transferred source costs from UBK's settled disenchant records." or "Show already-owned disenchantable gear with qualifying UBK acquisition evidence. No Auction House search is started.")
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave",function() if GameTooltip then GameTooltip:Hide() end end)
    end
    local history=ui.shredInventoryMode=="history"
    local rows,err
    if history then rows,err=S.HistoryRows(ctx) else rows,err=S.InventoryRows(ctx) end
    local info=ctx.MakeText(parent,"GameFontDisableSmall")
    info:SetPoint("TOPLEFT",6,top-37); info:SetPoint("RIGHT",parent,"RIGHT",-8,0)
    info:SetText(err or (history and "Settled disenchant history. Outputs are actual recorded materials; unknown source costs remain unknown."
        or "Already-owned gear with acquisition evidence. Click an item to inspect it; mail and disenchant actions remain yours."))
    local columns,state
    if history then
        ui.shredHistorySort=ui.shredHistorySort or {key="time",ascending=false,page=1}
        state=ui.shredHistorySort
        columns={
            {key="time",label="Date",width=135,ascending=false,text=function(r)return Date(r.time)end,tooltip="Timestamp of the recorded disenchant. Newest first initially."},
            {key="name",label="Source item",width=185,tooltip="Item consumed by the recorded disenchant. Click a row to inspect it."},
            {key="sourceCost",label="Source cost",width=110,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.sourceCost)end,tooltip="Recorded source acquisition cost transferred into the actual output. Missing or untrusted source cost remains Unknown."},
            {key="outputText",label="Actual output materials",width=335,text=function(r)return r.outputText or "Unknown"end,tooltip="Recorded quantities and materials, not expected random yields. Hover the row to see every output."},
            {key="status",label="Cost transfer status",width=165,text=function(r)return r.status or "Unknown"end,tooltip="UBK's recorded settlement status for the source and its output materials."},
        }
    else
        ui.shredInventorySort=ui.shredInventorySort or {key="name",ascending=true,page=1}
        state=ui.shredInventorySort
        columns={
            {key="name",label="Item",width=188,tooltip="Owned disenchantable gear. Initially sorted A-Z; click any header to change ordering."},
            {key="qty",label="Qty",width=54,align="RIGHT",ascending=false,tooltip="Quantity supported by acquisition evidence, capped at current ownership. Legacy copies do not inflate this count."},
            {key="status",label="Status",width=115,tooltip="READY, NEEDS MAIL, IN TRANSIT, STORED, LISTED, or OWNED from UBK's existing pipeline."},
            {key="location",label="Location",width=242,text=function(r)return r.location or "Unknown"end,tooltip="Character and current quantity, as supplied by UBK/TSM. Hover to see the full location list."},
            {key="basis",label="Basis / item",width=116,align="RIGHT",ascending=false,text=function(r)return Money(ctx,r.basis)end,tooltip="Trusted UBK acquisition basis for one item. A missing or untrusted cost remains Unknown."},
            {key="source",label="Acquisition source",width=165,text=function(r)return r.source or "Unknown"end,tooltip="Qualifying acquisition evidence such as AH, trade, or captured loot. Sorting does not modify that evidence."},
        }
    end
    local width=parent:GetWidth()-12
    local height=math.max(150,parent:GetHeight()+top-74)
    return tableUI.Render(ctx,{
        parent=parent,x=6,y=top-63,width=width,height=height,columns=columns,rows=rows,state=state,
        onChange=ctx.RenderPage,
        onClick=function(row) if row.itemString and ctx.ShowMarketItem then ctx.ShowMarketItem(row.itemString) end end,
        onEnter=function(owner,row) Tooltip(ctx,owner,row,history) end,
        emptyText=err or (history and "No settled disenchant records have been captured yet." or "No owned disenchantable gear currently qualifies for this inventory view."),
    })
end
