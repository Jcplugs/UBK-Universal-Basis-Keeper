function CreateFrame() return {RegisterEvent=function() end,SetScript=function() end} end
local quality={[1]=0,[2]=0,[3]=1,[4]=2,[5]=0}
local vendors={[1]=123,[2]=0,[3]=45,[4]=12}
function GetItemInfo(id) if quality[id]==nil then return end;return "item "..id,nil,quality[id],nil,nil,nil,nil,nil,nil,nil,vendors[id] end
ITEM_QUALITY_COLORS={[0]={r=.62,g=.62,b=.62},[1]={r=1,g=1,b=1},[2]={r=.12,g=1,b=0}}
dofile(ADDON_ROOT.."/UBK_ItemRules.lua")
assert(UBKItemRules.VendorTrash("i:1"));local gray,value=UBKItemRules.VendorTrash("i:2");assert(gray and value==0)
assert(not UBKItemRules.VendorTrash("i:99"));assert(not UBKItemRules.VendorTrash("i:3"))
local r,g,b=UBKItemRules.QualityColor("i:4");assert(r==.12 and g==1 and b==0,"Uncommon item not green")
r,g,b=UBKItemRules.QualityColor("i:3");assert(r==1 and g==1 and b==1,"Common item not white")
local function source(path) local f=assert(io.open(path));local s=f:read("*a");f:close();return s end
local core=source(ADDON_ROOT.."/UniversalBasisKeeper.lua")
local start=assert(core:find("function _G.UBKWorldDropInternal.Reference",1,true))
local finish=assert(core:find("local function ClassifyCost",start,true))
function IsUniversalExcluded(item) return UBKItemRules.VendorTrash(item) end
function GetUnitBasis(s) return s.qty>0 and s.value/s.qty or 0 end
function CostProvenanceLabel() return "manual-economic" end
function ParseMoney() end
function GetTSMCustomValue() end
function ClearCostReview(db,item) db.review[item]=nil end
function GetRealmQuantityForItem() return 1 end
local synced=0;function AutoSyncTSM() synced=synced+1 end
TSM_API={GetCustomPriceValue=function() return 100000 end}
UBKWorldDropInternal={};assert(load(core:sub(start,finish-1)))()
local state={qty=8,value=987654,bootstrapUnresolved=2,needsCostReview=true}
local db={review={["i:1"]=true}}
local ref,kind=UBKWorldDropInternal.Reference(state,"i:1");assert(ref==123 and kind=="vendor sell value","Grey used market reference")
local ok,unit=UBKWorldDropInternal.ApplyClassification(db,"i:1",state)
assert(ok and unit==123 and state.qty==8 and state.value==987654 and synced==0 and not db.review["i:1"],"Grey classification rewrote acquisition lots or TSM")
ok,unit=UBKWorldDropInternal.ApplyClassification(db,"i:2",state);assert(ok and unit==0,"Zero vendor value rejected")
assert(not UBKWorldDropInternal.ApplyClassification(db,"i:5",state),"Missing vendor quote invented a price")
state={qty=0,value=0,bootstrapUnresolved=1}
ok,unit=UBKWorldDropInternal.ApplyClassification(db,"i:4",state);assert(ok and unit==95000 and state.value==95000 and synced==1,"Non-grey world rule changed")
-- Loot quality skips uncached greys before the cost-discovery pipeline.
start=assert(core:find("function _G.UBKLootInternal.CaptureLootWindow",1,true));finish=assert(core:find("function _G.UBKLootInternal.CommitLootSlot",start,true))
function IsSupportedRealm() return true end;function SetupAllowsProcessing() return true end
function GetRealmDB() return db end
function GetNumLootItems() return 2 end
function GetLootSlotLink(slot) return "|Hitem:"..(slot==1 and 99 or 4).."|hItem|h" end
function GetLootSlotInfo(slot) return nil,"test",2,nil,slot==1 and 0 or 2,false,false end
UBKLootRuntime={};local lc={capturedWindows=0};UBKLootInternal={EnsureState=function() return lc end}
UBKWorldDropInternal.CaptureWorldLocation=function() return {} end
assert(load(core:sub(start,finish-1)))();assert(UBKLootInternal.CaptureLootWindow()==2 and not UBKLootRuntime.windowSlots[1] and UBKLootRuntime.windowSlots[2],"Uncached gray loot entered discovery")
-- Scan Now selects the resolved inspected item and stops cleanly without AH/cache.
UniversalBasisKeeperAPI={ResolveItem=function(_,x) return x end,IsAuctionVisible=function() return true end}
local api=UniversalBasisKeeperAPI;local queued
function api:StartShredderLiveStockRefresh(items) queued=items;return true end
QueryAuctionItems=function() end
local funcs=source(ADDON_ROOT.."/UBK_InterfaceTools.lua")
local keyStart=assert(funcs:find("local function ItemKey",1,true));local keyEnd=assert(funcs:find("local function Scope",keyStart,true))
local scanStart=assert(funcs:find("function API:ScanMarketItem",1,true))
assert(load("local API=UniversalBasisKeeperAPI\n"..funcs:sub(keyStart,keyEnd-1).."\n"..funcs:sub(scanStart)))()
assert(api:ScanMarketItem("i:4") and #queued==1 and queued[1]=="i:4","Scan chose wrong item")
api.IsAuctionVisible=function() return false end;queued=nil;assert(not api:ScanMarketItem("i:4") and queued==nil,"Closed AH still queried")
api.IsAuctionVisible=function() return true end;assert(not api:ScanMarketItem("i:99"),"Uncached name queried")
print("PASS: vendor-only grey classification including zero/missing quotes; purchase pool preserved; common/uncommon colors; non-grey rule unchanged; uncached grey loot skipped; one-item scan targets inspected item and rejects closed AH / missing cache")
