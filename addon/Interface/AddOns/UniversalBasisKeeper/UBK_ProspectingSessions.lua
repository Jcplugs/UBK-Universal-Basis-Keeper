-- Actual input costs and actual loot only. No market quote becomes ore basis.
-- The journal and cost pools share one SavedVariables file. Settlement is a
-- non-yielding, staged commit; repeating login/refresh cannot replay its costs.
_G.UBKProspectingSessions={}
local P=_G.UBKProspectingSessions
local A=_G.UBKProspectAccounting
local currentID
local function VendorByproduct(item) return item=="i:24235" end
local ores={[2770]=true,[2771]=true,[2772]=true,[3858]=true,[10620]=true,[23424]=true,[23425]=true}
local function Positive(n) return type(n)=="number" and n>0 and n==n and n<math.huge end
local function Item(id) return "i:"..id end
local function Journal(create)
    local db=create and A.DB() or A.Peek()
    if not db then return nil end
    if create and not db.prospectSessions then db.prospectSessions={schema=1,nextID=0,records={}} end
    local j=db.prospectSessions
    if j and j.schema==1 and type(j.records)=="table" then return j end
end
function P:Pending(item)
    local j=Journal();local qty=0
    if j then for _,r in ipairs(j.records) do
        if not r.settled then qty=qty+((r.outputs and r.outputs[item]) or 0) end
    end end
    return qty>0,qty
end
function P:SourceOre(item)
    local j=Journal()
    if j then for _,r in ipairs(j.records) do if not r.settled and r.outputs[item] and r.ore then return Item(r.ore) end end end
end
function P:Reason(item)
    local pending=self:Pending(item)
    if not pending then return nil end
    local j=Journal()
    for _,r in ipairs(j.records) do
        if not r.settled and r.outputs[item] then
            if not r.complete or r.inventoryChanged then return "Prospecting evidence incomplete; review ore session before selling" end
            if (r.unknownQty or 0)>0 then return "Resolve the ore's cost, then reload to settle prospecting basis" end
        end
    end
    return "Reload to settle prospecting basis"
end
function P:BeforeCast(counts)
    A.Refresh() -- live ledger and captured buyer invoices before any ore leaves
    local snap={}
    for ore,qty in pairs(counts) do if ores[ore] and qty>=5 then snap[ore]=A.Input(Item(ore),qty) end end
    return snap
end
function P:Capture(observation,ore,outputs)
    if observation.basisRecord then return observation.basisRecord end
    local j=Journal(true);if not j or not next(outputs) then return nil end
    if not currentID then j.nextID=j.nextID+1;currentID=j.nextID end
    local r={session=currentID,ore=ore,outputs={},byproducts={},vendorPrices={},prices={},beforeOwned={},at=time(),complete=false,character=UnitName("player")}
    for item,qty in pairs(outputs) do
        if type(item)~="string" or not item:match("^i:%d+$") or not Positive(qty) or qty~=math.floor(qty) then return nil end
        if VendorByproduct(item) then
            r.byproducts[item]=qty
            r.vendorPrices[item]=A.VendorSell(item)
        else
        r.outputs[item]=qty
        -- Freeze the first available quote for each output in this ore session.
        for _,prior in ipairs(j.records) do
            if prior.session==currentID and prior.ore==ore and prior.prices[item] then r.prices[item]=prior.prices[item];break end
        end
        r.prices[item]=r.prices[item] or A.Quote(item)
        r.beforeOwned[item]=A.Observe(item)
        A.Track(item)
        end
    end
    j.records[#j.records+1]=r;observation.basisRecord=r
    local bridge=_G.UBKTSMGroupBridge
    if bridge and bridge.Invalidate then pcall(bridge.Invalidate) end
    if _G.UBKBasisSale and _G.UBKBasisSale.RefreshPending then _G.UBKBasisSale:RefreshPending() end
    return r
end
function P:Complete(observation,ore,outputs,delivered)
    local r=observation.basisRecord or self:Capture(observation,ore,outputs)
    if not r or r.complete then return false end
    r.ore=ore or r.ore
    if not ore or not ores[ore] or not delivered then r.error="Incomplete five-ore / loot delivery evidence";return false end
    local input=observation.basisBefore and observation.basisBefore[ore]
    r.unknownQty=input and input.unknownQty or 5
    r.knownCost=input and input.knownCost or 0
    r.inputProvenance=input and input.provenance or "unknown"
    r.inputOwnedBefore=input and input.owned;r.inputBuysBefore=input and input.buysQty
    r.complete=true
    if r.unknownQty>0 then C_Timer.After(0,function() P:PromptOre(Item(ore)) end) end
    return true
end
function P:NoteOutflow(item)
    local j=Journal();if not j then return end
    for _,r in ipairs(j.records) do
        if not r.settled and r.outputs[item] then r.inventoryChanged=true;r.error="Output inventory left before settlement; preserved for review" end
    end
end
function P:UnknownInput(item)
    local j=Journal();local qty=0;local ids={}
    if j then for index,r in ipairs(j.records) do
        if not r.settled and r.complete and r.ore and Item(r.ore)==item and (r.unknownQty or 0)>0 then
            qty=qty+r.unknownQty;ids[#ids+1]=index..":"..r.unknownQty
        end
    end end
    return qty,table.concat(ids,",")
end
function P:InputSyncPending(item)
    local j=Journal();local latest
    if j then for _,r in ipairs(j.records) do
        if not r.settled and r.complete and r.ore and Item(r.ore)==item then latest=r end
    end end
    if not latest or not latest.inputOwnedBefore then return false end
    local db=A.Peek();local state=db and db.items[item]
    local newBuys=math.max(0,(state and tonumber(state.buysQty) or 0)-(latest.inputBuysBefore or 0))
    return A.Observe(item)>latest.inputOwnedBefore-5+newBuys
end
function P:ResolveInputs(item,copper)
    local j=Journal();if not j then return end
    for _,r in ipairs(j.records) do
        if not r.settled and r.complete and r.ore and Item(r.ore)==item and (r.unknownQty or 0)>0 then
            r.knownCost=(r.knownCost or 0)+r.unknownQty*copper
            r.resolvedOreQty=r.unknownQty;r.resolvedOreUnit=copper;r.unknownQty=0
            r.inputProvenance="player-confirmed ore cost";r.resolvedAt=time()
        end
    end
end
function P:PromptOre(item)
    if InCombatLockdown and InCombatLockdown() then return false end
    local ui=_G.UBKInterfaceAPI
    if ui and ui.ShowProspectingOreCost then ui:ShowProspectingOreCost(item);return true end
    return false
end
function P:Preflight()
    local api=_G.UniversalBasisKeeperAPI
    A.Refresh()
    for _,row in ipairs(api:GetBagProspectableOres()) do
        local input=A.Input(row.itemString,row.quantity)
        if (input.unknownQty or 5)>0 then self:PromptOre(row.itemString);return false,"Tell UBK this ore's basis before opening Destroying; then click Open TSM Destroying again." end
    end
    return true
end
function P:ReviewCosts()
    local j=Journal()
    if j then for _,r in ipairs(j.records) do
        if not r.settled and r.ore and (r.unknownQty or 0)>0 then return self:PromptOre(Item(r.ore)) end
    end end
    local ok,message=self:Preflight()
    if ok then print("|cff33ff99UBK:|r Ore costs are ready. Reload to settle completed prospecting; incomplete sessions stay blocked for review.") end
    return ok,message
end
function P:Plan(records)
    local plan={outputs={},allocations={},cost=0,inputCost=0,byproducts={},vendorCredit=0,records=records,method="relative market value"}
    local weights={};local allPrices=true
    for _,r in ipairs(records) do
        if not r.complete or r.inventoryChanged then return nil,r.error or "Incomplete prospecting evidence" end
        if (r.unknownQty or 0)>0 then return nil,"Ore cost needs resolution" end
        if not Positive(r.knownCost) then return nil,"Missing input cost" end
        plan.inputCost=plan.inputCost+r.knownCost
        local byproducts={}
        for item,qty in pairs(r.byproducts or {}) do byproducts[item]=qty end
        -- Pre-credit session records stored powder among ordinary outputs.
        for item,qty in pairs(r.outputs) do if VendorByproduct(item) then
            if byproducts[item] then return nil,"Duplicate powder evidence; review session" end
            byproducts[item]=qty
        end end
        for item,qty in pairs(byproducts) do
            if not VendorByproduct(item) or not Positive(qty) or qty~=math.floor(qty) then return nil,"Invalid powder evidence" end
            local price=r.vendorPrices and r.vendorPrices[item]
            if price==nil then price=A.VendorSell(item) end
            if type(price)~="number" or price<0 or price~=price or price==math.huge then return nil,"Waiting for Thorium Powder vendor sell value" end
            plan.vendorCredit=plan.vendorCredit+qty*price
            plan.byproducts[item]=(plan.byproducts[item] or 0)+qty
        end
        for item,qty in pairs(r.outputs) do
            if not VendorByproduct(item) then
            plan.outputs[item]=(plan.outputs[item] or 0)+qty
            if not Positive(r.prices[item]) then allPrices=false
            else weights[item]=(weights[item] or 0)+qty*r.prices[item] end
            end
        end
    end
    plan.cost=math.max(0,plan.inputCost-plan.vendorCredit)
    plan.vendorSurplus=math.max(0,plan.vendorCredit-plan.inputCost)
    if not allPrices then
        -- One common unit system for the WHOLE pool. Never mix gold and counts.
        weights={};for item,qty in pairs(plan.outputs) do weights[item]=qty end
        plan.method="quantity fallback: incomplete market references"
    end
    local total,keys=0,{}
    for item,weight in pairs(weights) do total=total+weight;keys[#keys+1]=item end
    table.sort(keys)
    if total<=0 or #keys==0 then return nil,"No confirmed outputs" end
    local allocated=0
    for index,item in ipairs(keys) do
        local cost=index==#keys and (plan.cost-allocated) or plan.cost*weights[item]/total
        plan.allocations[item]=cost;allocated=allocated+cost
    end
    return plan
end
function P:Settle()
    local j=Journal();if not j then return 0 end
    local groups,order={},{}
    for _,r in ipairs(j.records) do
        -- Records from this login remain provisional, even after resolving ore.
        if not r.settled and r.session~=currentID then
            local key=r.session..":"..tostring(r.ore)
            if not groups[key] then groups[key]={};order[#order+1]=key end
            groups[key][#groups[key]+1]=r
        end
    end
    local n=0
    for _,key in ipairs(order) do
        local records=groups[key];local plan,err=self:Plan(records)
        if plan then
            local ok,why=A.Settle(plan)
            if ok then
                n=n+1
                print("|cff33ff99UBK:|r Settled prospecting basis for ".._G.UniversalBasisKeeperAPI:GetItemName(Item(records[1].ore)).." ("..plan.method..").")
            else err=why end
        end
        if err then for _,r in ipairs(records) do r.settleError=err end end
    end
    return n
end
function P:Status()
    local j=Journal();local casts,qty,unknown,incomplete=0,0,0,0
    if j then for _,r in ipairs(j.records) do if not r.settled then
        casts=casts+1;for _,q in pairs(r.outputs) do qty=qty+q end
        unknown=unknown+(r.unknownQty or 0)
        if not r.complete or r.inventoryChanged then incomplete=incomplete+1 end
    end end end
    return string.format("Pending: %d prospects / %d outputs. Unknown ore: %d. Evidence reviews: %d. Reload before selling or crafting outputs.",casts,qty,unknown,incomplete)
end
local event=CreateFrame("Frame");event:RegisterEvent("PLAYER_LOGIN")
event:SetScript("OnEvent",function()
    C_Timer.After(2,function() A.Refresh();P:Settle()
        local j=Journal();if j then for _,r in ipairs(j.records) do
            if not r.settled and r.ore and (r.unknownQty or 0)>0 then P:PromptOre(Item(r.ore));break end
        end end
    end)
end)
