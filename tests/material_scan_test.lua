local api={};UniversalBasisKeeperAPI=api
function api:GetRuntimeContext()return {realm='Realm',faction='Faction',supported=true}end
local prices={['i:18256']=300};local basis={['i:22793']=50000,['i:22791']=20000,['i:22794']=150000,['i:18256']=300}
TSM_API={GetCustomPriceValue=function(source,item)assert(source=='vendorbuy','Used market/sell as vendor purchase cost');return prices[item] end}
function api:GetMaterialCost(item)return basis[item]end
function api:GetItemName(item)return item end
local state={liveToken=0};local stock={};local queued,queueCalls
queueCalls=0
function api:GetShredderState()return state end
function api:GetShredderLiveStock(item)return stock[item]end
function api:IsAuctionVisible()return true end
function api:StartShredderLiveStockRefresh(items)queued=items;queueCalls=queueCalls+1;state={liveScanning=true,liveToken=state.liveToken+1,liveStartedAt=123};return true end
function QueryAuctionItems()end
function GetItemInfo(id)return 'name'..id end
function time()return 1000 end
local recipe={itemString='i:22861',numResult=2,mats={['i:22793']=3,['i:22791']=7,['i:22794']=1,['i:18256']=1}}
TradeSkillMasterDB={['f@Faction - Realm@internalData@crafts']={[1]=recipe},['f@Other - Realm@internalData@crafts']={[2]=recipe}}
assert(loadfile(ADDON_ROOT..'/UBK_MaterialScan.lua'))()
local plans=api:GetCraftMaterialPlans('i:22861');assert(#plans==1 and plans[1].outputQuantity==2 and #plans[1].reagents==4)
local p=plans[1];assert(p.recordedTotal==440300)
assert(api:ScanCraftingMaterials('i:22861','1') and #queued==3)
for _,item in ipairs(queued)do assert(item~='i:18256' and item~='i:22861')end
for _,item in ipairs(queued)do stock[item]={low=100,lowUnits=20,complete=true,scanToken=0,scanStartedAt=123}end
local snap=UBKMaterialScan.Snapshot(p);assert(snap.quoteTotal==nil,'Old quote reused')
for _,item in ipairs(queued)do stock[item].scanToken=state.liveToken;stock[item].scanStartedAt=122 end
assert(UBKMaterialScan.Snapshot(p).quoteTotal==nil,'Wrong scan start accepted')
for _,item in ipairs(queued)do stock[item].scanStartedAt=123 end
state.liveScanning=false;snap=UBKMaterialScan.Snapshot(p)
assert(snap.complete and snap.quoteTotal==1400 and snap.quotePerOutput==700 and snap.recordedTotal==440300,'Quantities, vendor price or output division wrong')
stock['i:22791'].lowUnits=1;stock['i:22791'].complete=false;snap=UBKMaterialScan.Snapshot(p);assert(not snap.complete and snap.limited and snap.quoteTotal==1400)
stock['i:22791'].low=nil;assert(UBKMaterialScan.Snapshot(p).quoteTotal==nil,'Missing reagent valued as free')
prices['i:18256']=nil;assert(api:ScanCraftingMaterials('i:22861','1') and #queued==3,'Unknown-price vial searched at AH')
assert(UBKMaterialScan.Snapshot(p).quoteTotal==nil,'Invented missing vial price')
local calls=queueCalls
api.IsAuctionVisible=function()return false end;assert(not api:ScanCraftingMaterials('i:22861','1') and calls==queueCalls)
api.IsAuctionVisible=function()return true end;GetItemInfo=function()end
assert(not api:ScanCraftingMaterials('i:22861','1') and calls==queueCalls,'Uncached material created incomplete queue')
recipe.mats={['i:18256']=1};prices['i:18256']=300
api.IsAuctionVisible=function()return false end
assert(api:ScanCraftingMaterials('i:22861','1') and calls==queueCalls,'Vendor-only plan started scanner with empty queue')
assert(not api:ScanCraftingMaterials('i:1','1') and calls==queueCalls)
recipe.mats={['i:22793']=-3};assert(#api:GetCraftMaterialPlans('i:22861')==0,'Malformed recipe accepted')
assert(basis['i:22793']==50000 and prices['i:18256']==300,'Read-only plan changed source data')
print('PASS: recipe/faction scope, quantities/output, vendor exclusions including unknown-price vials, no empty scans, complete quote totals, missing/partial/low-stock states, stale-scan rejection, unavailable AH/cache')
