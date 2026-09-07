local frames={}
function CreateFrame() local f={};function f:RegisterEvent() end;function f:SetScript(k,v) self[k]=v end;frames[#frames+1]=f;return f end
function GetBuildInfo() return "x",nil,nil,20506 end
function time() return 1234 end
function GetTime() return 5 end
C_Timer={After=function(delay,fn) if delay<1 then fn() end end}
UniversalBasisKeeperDB={}
dofile(ADDON_ROOT.."/UBK_ProspectingLearning.lua")
local Learn=UBKProspectingLearning
local function observation(ore,qty) return {succeeded=true,closed=true,completeLoot=true,before={[ore]=15},outputs={[7910]=qty}} end
local sample=observation(2770,3)
assert(Learn:Commit(sample,{[2770]=10}))
assert(not Learn:Commit(sample,{[2770]=10}),"Duplicate prospect counted")
local outputs,warning,source,n,note=Learn:Estimate(2770,{[7910]=.2},nil,"baseline")
assert(math.abs(outputs[7910]-23/105)<.000000001 and n==1 and not warning,"Per-five baseline weighting wrong")
sample=observation(2770,0);assert(Learn:Commit(sample,{[2770]=10}));outputs=Learn:Estimate(2770,{[7910]=.2},nil,"baseline");assert(math.abs(outputs[7910]-23/110)<.000000001,"Zero-output prospect did not reduce mean")
sample=observation(2770,1);assert(not Learn:Commit(sample,{[2770]=5}),"Ten-ore change accepted")
sample=observation(2770,1);sample.before[2771]=10;assert(not Learn:Commit(sample,{[2770]=10,[2771]=5}),"Two changed ores accepted")
sample=observation(2770,1);sample.completeLoot=false;assert(not Learn:Commit(sample,{[2770]=10}),"Incomplete loot learned")
sample=observation(2770,1);sample.succeeded=false;assert(not Learn:Commit(sample,{[2770]=10}),"Failed cast learned")
-- A previous installation's disabled toggle cannot stop automatic learning.
UniversalBasisKeeperDB.prospectingLearning.thorium=false
for i=1,19 do assert(Learn:Commit(observation(10620,2),{[10620]=10})) end
outputs,warning=Learn:Estimate(10620,{[7910]=900},"inconsistent prior","baseline");assert(warning and outputs[7910]==.4,"Invalid Thorium baseline leaked into estimate")
assert(Learn:Commit(observation(10620,2),{[10620]=10}))
outputs,warning,source,n=Learn:Estimate(10620,{[7910]=900},"inconsistent prior","baseline")
assert(not warning and n==20 and outputs[7910]==.4,"Observed Thorium estimate not enabled at sample minimum")
local retained=UniversalBasisKeeperDB.prospectingLearning.ores[10620]
dofile(ADDON_ROOT.."/UBK_ProspectingLearning.lua");Learn=UBKProspectingLearning
assert(UniversalBasisKeeperDB.prospectingLearning.ores[10620]==retained,"Existing samples were replaced on load")
outputs,warning,source,n=Learn:Estimate(10620,{[7910]=900},"inconsistent prior","baseline")
assert(not warning and n==20 and outputs[7910]==.4,"Legacy disabled flag suppressed learned rates after reload")
for _,ore in ipairs({2770,2771,2772,3858,10620,23424,23425}) do
    local before=UniversalBasisKeeperDB.prospectingLearning.ores[ore]
    local batches=before and before.batches or 0
    assert(Learn:Commit(observation(ore,2),{[ore]=10}),"Supported ore did not learn automatically: "..ore)
    assert(UniversalBasisKeeperDB.prospectingLearning.ores[ore].batches==batches+1)
end
-- Exercise actual event ordering, duplicate loot notifications and byproducts.
local priorIron=UniversalBasisKeeperDB.prospectingLearning.ores[2772]
local priorIronBatches,priorIronGems=priorIron.batches,priorIron.outputs[7910]
local oreQty,lootSlots=15,0
NUM_BAG_SLOTS=0
C_Container={GetContainerNumSlots=function() return 1 end,GetContainerItemInfo=function() return {itemID=2772,stackCount=oreQty} end}
function GetNumLootItems() return lootSlots end
function GetLootSlotLink(slot) return "|Hitem:"..(slot==1 and 7910 or 999999).."|hitem|h" end
function GetLootSlotInfo(slot) return nil,nil,slot==1 and 2 or 1 end
local event=frames[#frames].OnEvent
event(nil,"UNIT_SPELLCAST_START","player","cast-1",31252)
oreQty=10;event(nil,"UNIT_SPELLCAST_SUCCEEDED","player","cast-1",31252)
lootSlots=2;event(nil,"LOOT_READY");event(nil,"LOOT_OPENED");event(nil,"LOOT_CLOSED");event(nil,"LOOT_CLOSED")
local learned=UniversalBasisKeeperDB.prospectingLearning.ores[2772]
assert(learned.batches==priorIronBatches+1 and learned.outputs[7910]==priorIronGems+2 and not learned.outputs[999999],"Live-event batch was duplicated or byproducts included")
print("PASS: five-ore evidence, ambiguous/incomplete/failed casts rejected, duplicate events ignored, zero-output denominator, per-five baseline blend, invalid Thorium prior excluded, automatic learning for all seven ores, retained samples / legacy off flag ignored, sample minimum, actual cast/loot event flow, byproducts excluded")
