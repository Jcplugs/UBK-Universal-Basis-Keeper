-- Learn only from a successful Prospecting cast, a complete loot snapshot,
-- and exactly five ore disappearing from one bagged ore type. Never casts.
_G.UBKProspectingLearning={priorBatches=20,minimumBatches=20}
local Learn=_G.UBKProspectingLearning
local ores={[2770]=true,[2771]=true,[2772]=true,[3858]=true,[10620]=true,[23424]=true,[23425]=true}
local gems={}
for _,id in ipairs({774,818,1206,1210,1529,1705,3864,7909,7910,12361,12364,12799,12800,21929,23077,23079,23107,23112,23117,23436,23437,23438,23439,23440,23441}) do gems[id]=true end
local function Supported()
    local _,_,_,build=GetBuildInfo();build=tonumber(build)
    return build and build>=20500 and build<30000
end
local function DB()
    if type(UniversalBasisKeeperDB)~="table" then UniversalBasisKeeperDB={} end
    local root=UniversalBasisKeeperDB
    if type(root.prospectingLearning)~="table" then root.prospectingLearning={schema=1,client="BCC",ores={},rejected=0} end
    local db=root.prospectingLearning
    if db.schema~=1 or db.client~="BCC" or type(db.ores)~="table" then return nil end
    return db
end
function Learn:Validate(observation,after)
    if type(observation)~="table" or not observation.succeeded or not observation.completeLoot or not observation.closed or not observation.before or type(after)~="table" then return nil,"Incomplete cast or loot evidence" end
    local found
    for id in pairs(ores) do
        local difference=(observation.before[id] or 0)-(after[id] or 0)
        if difference~=0 then
            if difference~=5 or found then return nil,"Bag ore changes were ambiguous" end
            found=id
        end
    end
    if not found then return nil,"No complete five-ore input" end
    local outputs={}
    for id,qty in pairs(observation.outputs or {}) do
        if not gems[id] or type(qty)~="number" or qty<0 or qty~=math.floor(qty) or qty>100 then return nil,"Invalid raw gem output" end
        outputs[id]=qty
    end
    return found,outputs
end
function Learn:Commit(observation,after)
    if not observation or observation.recorded then return false end
    local db=DB();if not db then return false end
    local ore,outputs=self:Validate(observation,after)
    if not ore then db.rejected=(db.rejected or 0)+1;return false end
    observation.recorded=true
    local sample=db.ores[ore]
    if type(sample)~="table" then sample={batches=0,outputs={}};db.ores[ore]=sample end
    sample.batches=sample.batches+1
    for id,qty in pairs(outputs) do sample.outputs[id]=(sample.outputs[id] or 0)+qty end
    sample.updatedAt=time()
    return true
end
function Learn:Estimate(ore,prior,priorWarning,source)
    local db=DB();local sample=db and db.ores[ore]
    local n=type(sample)=="table" and tonumber(sample.batches) or 0
    local validPrior=not priorWarning and type(prior)=="table" and next(prior)~=nil
    if not n or n<1 then return prior,priorWarning,source,0,"No personal samples yet. Complete prospects are learned automatically." end
    local out={};local weight=validPrior and self.priorBatches or 0
    if validPrior then for gem,value in pairs(prior) do out[gem]=value*5*weight end end
    for gem,qty in pairs(sample.outputs or {}) do if gems[gem] then out[gem]=(out[gem] or 0)+qty end end
    for gem,qty in pairs(out) do out[gem]=qty/((weight+n)*5) end
    local warning
    if not validPrior and n<self.minimumBatches then warning=string.format("Learning: %d/%d complete prospects. No reliable baseline is available; profit is withheld until the minimum sample count.",n,self.minimumBatches)
    elseif next(out)==nil then warning="No raw gems observed yet; a raw-gem profit estimate is unavailable." end
    local label=validPrior and ("Local yield baseline + "..n.." personal prospects") or ("Experimental personal yields: "..n.." prospects")
    local note=string.format("%d observed five-ore prospects; baseline weight %d prospects. Sample averages are estimates, not a confidence guarantee. Unobserved rare outputs may still occur.",n,weight)
    return out,warning,label,n,note
end
local function BagCounts()
    local out={};for id in pairs(ores) do out[id]=0 end
    local slots=C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
    for bag=0,(NUM_BAG_SLOTS or 4) do
        for slot=1,slots(bag) do
            local id,qty
            if C_Container and C_Container.GetContainerItemInfo then local info=C_Container.GetContainerItemInfo(bag,slot);id=info and info.itemID;qty=info and info.stackCount
            else local _,count,_,_,_,_,link,_,_,itemID=GetContainerItemInfo(bag,slot);id=itemID or (link and tonumber(link:match("item:(%d+)")));qty=count end
            if id then out[id]=(out[id] or 0)+(qty or 0) end
        end
    end
    return out
end
local pending,serial=nil,0
function Learn:IsProspectLoot() return pending and pending.succeeded and not pending.closed or false end
local function CaptureLoot()
    if not pending or not pending.succeeded or pending.completeLoot then return end
    local slots=GetNumLootItems();if not slots or slots<1 then return end
    local output,all,slotData={},{},{}
    for slot=1,slots do
        local link=GetLootSlotLink(slot);local id=link and tonumber(link:match("item:(%d+)"))
        local _,_,quantity=GetLootSlotInfo(slot)
        -- Missing links cannot be safely inferred from later bag gains.
        if not id or type(quantity)~="number" or quantity<1 then return end
        if gems[id] then output[id]=(output[id] or 0)+quantity end
        all["i:"..id]=(all["i:"..id] or 0)+quantity
        slotData[slot]={id=id,qty=quantity}
    end
    pending.outputs=output;pending.completeLoot=true
    pending.allOutputs=all;pending.lootSlots=slotData;pending.cleared={}
    if _G.UBKProspectingSessions then
        local ore=Learn:Validate({succeeded=true,completeLoot=true,closed=true,before=pending.before,outputs=output},BagCounts())
        _G.UBKProspectingSessions:Capture(pending,ore,all)
    end
end
local function Finish(observation)
    if pending~=observation then return end
    if GetTime()-observation.startedAt<=120 then
        local after=BagCounts()
        local ore=Learn:Validate(observation,after)
        Learn:Commit(observation,after)
        if _G.UBKProspectingSessions and observation.allOutputs then
            local delivered=true
            for slot,row in pairs(observation.lootSlots or {}) do
                if not observation.cleared[slot] then delivered=false end
            end
            if not delivered then
                delivered=true
                for item,qty in pairs(observation.allOutputs) do
                    local id=tonumber(item:match("%d+"))
                    if (after[id] or 0)-(observation.before[id] or 0)<qty then delivered=false end
                end
            end
            _G.UBKProspectingSessions:Complete(observation,ore,observation.allOutputs,delivered)
        end
    end
    pending=nil
end
local events=CreateFrame("Frame")
for _,event in ipairs({"UNIT_SPELLCAST_START","UNIT_SPELLCAST_SUCCEEDED","UNIT_SPELLCAST_FAILED","UNIT_SPELLCAST_INTERRUPTED","LOOT_READY","LOOT_OPENED","LOOT_SLOT_CLEARED","LOOT_CLOSED","PLAYER_LOGOUT"}) do events:RegisterEvent(event) end
events:SetScript("OnEvent",function(_,event,unit,guid,spellID)
    if not Supported() then return end
    if event=="UNIT_SPELLCAST_START" and unit=="player" then
        if pending and pending.closed then Finish(pending) end
        pending=nil
        if spellID==31252 then
            serial=serial+1
            local before=BagCounts()
            local basisBefore=_G.UBKProspectingSessions and _G.UBKProspectingSessions:BeforeCast(before)
            pending={serial=serial,guid=guid,before=before,basisBefore=basisBefore,startedAt=GetTime()}
            local current=pending
            C_Timer.After(120,function() if pending==current then pending=nil end end)
        end
    elseif event=="UNIT_SPELLCAST_SUCCEEDED" and unit=="player" and spellID==31252 and pending and pending.guid==guid then
        pending.succeeded=true;CaptureLoot()
    elseif (event=="UNIT_SPELLCAST_FAILED" or event=="UNIT_SPELLCAST_INTERRUPTED") and unit=="player" and pending and pending.guid==guid then pending=nil
    elseif (event=="LOOT_READY" or event=="LOOT_OPENED") and pending then CaptureLoot()
    elseif event=="LOOT_SLOT_CLEARED" and pending then
        if pending.cleared then pending.cleared[tonumber(unit)]=true end
    elseif event=="LOOT_CLOSED" and pending then
        pending.closed=true;local current=pending;C_Timer.After(.25,function() Finish(current) end)
    elseif event=="PLAYER_LOGOUT" then if pending and pending.closed then Finish(pending) end;pending=nil end
end)
