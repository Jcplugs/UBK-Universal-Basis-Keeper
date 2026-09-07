local function source(name) local f=assert(io.open(ADDON_ROOT..'/'..name));local s=f:read('*a');f:close();return s end
local core=source('UniversalBasisKeeper.lua')
local adapterStart=assert(core:find('-- BEGIN UBK PROSPECT ACCOUNTING ADAPTER',1,true))
local adapter=core:sub(adapterStart)
REALM_KEY='Realm-Horde'
UniversalBasisKeeperDB={realms={}}
UniversalBasisKeeperAPI={GetItemName=function(_,item)return item end}
local db,owned,quotes,refreshes,frames,timers
function CopyTable(t) local c={};for k,v in pairs(t) do c[k]=type(v)=='table' and CopyTable(v) or v end;return c end
function GetRealmDB() return db end
function IsSupportedRealm()return true end
function GetRealmQuantityForItem(item)return owned[item] or 0 end
function ProcessLedger() refreshes=refreshes+1 end
function CostTrustedForRadar(s)return s.trusted~=false and not s.needsCostReview and (s.value or 0)>0 end
function CostProvenanceLabel(s)return s.costProvenance or 'purchase-ledger' end
function GoblinPrice(kind,item)return quotes[item] end
function AddUnresolvedLot(s,q,kind) s.bootstrapUnresolved=(s.bootstrapUnresolved or 0)+q;s.unresolvedLots=s.unresolvedLots or {};s.unresolvedLots[#s.unresolvedLots+1]={qty=q,source=kind} end
function ParseMoney(s) return tonumber(s:match('^(%d+)g$')) and tonumber(s:match('^(%d+)g$'))*10000 end
function ResolveUnresolved(item,price)
 local s=db.items[item];local n=s.bootstrapUnresolved
 s.qty=s.qty+n;s.value=s.value+n*ParseMoney(price);s.bootstrapUnresolved=0;s.unresolvedLots={};return true
end
function time()return 1000 end
function UnitName()return 'Player' end
function InCombatLockdown()return false end
function CreateFrame()local f={};function f:RegisterEvent()end;function f:SetScript(k,v)self[k]=v end;frames[#frames+1]=f;return f end
C_Timer={After=function(delay,fn)timers[#timers+1]=fn end}
UBKShredderInternal={EnsureTransformItem=function(_,item)
 if not db.items[item] then db.items[item]={qty=0,value=0,bootstrapUnresolved=0,unresolvedLots={}} end
 return db.items[item]
end}
local prompts={}
UBKInterfaceAPI={ShowProspectingOreCost=function(_,item)prompts[#prompts+1]=item end}
local function loadSession() frames={};timers={};assert(loadfile(ADDON_ROOT..'/UBK_ProspectingSessions.lua'))();return UBKProspectingSessions end
local function reset()
 db={setup={status='complete'},items={}};UniversalBasisKeeperDB.realms[REALM_KEY]=db
 owned={};quotes={};refreshes=0;prompts={}
 assert(load(adapter))();return loadSession(),UBKProspectAccounting
end
local function stock(item,n,value,unknown)
 db.items[item]={qty=n,value=value,bootstrapUnresolved=unknown or 0,unresolvedLots={}}
 owned[item]=n+(unknown or 0)
end
local function prospect(P,ore,outputs,cost,unknown,complete)
 local o={basisBefore={[ore]={knownCost=cost,unknownQty=unknown or 0}}}
 P:Capture(o,ore,outputs);P:Complete(o,ore,outputs,complete~=false)
 for item,qty in pairs(outputs) do
  owned[item]=(owned[item] or 0)+qty
  UBKProspectAccounting.ReserveGain(db.items[item],item,qty)
 end
 return o.basisRecord,o
end
-- Pool costs by session AND ore. Existing stock retains every copper.
local P,A=reset()
stock('i:12364',2,80000);quotes['i:12364']=90000;quotes['i:12361']=1000
prospect(P,10620,{['i:12364']=1},500000)
local r=prospect(P,10620,{['i:12361']=10},500000)
assert(P:Pending('i:12361') and P:Settle()==0,'Settled before reload')
assert(db.items['i:12361'].qty==0 and db.items['i:12364'].value==80000)
quotes['i:12364']=1;quotes['i:12361']=9999999 -- reload price update must not change weights
P=loadSession();assert(P:Settle()==1,'Reload did not settle completed pool')
assert(db.items['i:12364'].value==980000 and db.items['i:12361'].value==100000)
assert(db.items['i:12361'].qty==10 and db.items['i:12361'].value/10==10000,'Cheap gems received equal split')
assert(not P:Pending('i:12361') and P:Settle()==0,'Duplicate settlement')
P=loadSession();assert(P:Settle()==0 and db.items['i:12364'].value==980000,'Second reload doubled costs')
-- Ore isolation, partial-cost input, integer output conservation, loss preserved.
P,A=reset();quotes['i:7910']=20000;quotes['i:12361']=10000
local a=prospect(P,10620,{['i:7910']=1},700000)
local b=prospect(P,2770,{['i:12361']=1},100000)
P=loadSession();assert(P:Settle()==2)
assert(db.items['i:7910'].value==700000 and db.items['i:12361'].value==100000,'Different ores shared costs / loss erased')
-- Quantity fallback uses counts for every output, never counts mixed with copper.
P,A=reset();quotes['i:7910']=1000000
prospect(P,10620,{['i:7910']=1,['i:12361']=3},100001)
P=loadSession();assert(P:Settle()==1)
assert(math.abs(db.items['i:7910'].value-25000.25)<.0001 and db.items['i:12361'].value==75000.75)
assert(db.prospectSessions.records[1].allocationMethod:find('quantity fallback'))
-- Consumed LAST five ore can be resolved with zero ore remaining; no fake stock.
P,A=reset();quotes['i:7910']=1000
r=prospect(P,10620,{['i:7910']=1},0,5)
P=loadSession();assert(P:Settle()==0 and P:Pending('i:7910'))
local ok,preview=UniversalBasisKeeperAPI:PreviewProspectingOreCost('i:10620','2g')
assert(ok and preview.pendingInputQty==5 and preview.stockUnresolvedQty==0)
assert(not UniversalBasisKeeperAPI:ResolveProspectingOreCost('i:10620','2g','stale'),'Stale confirmation accepted')
assert(UniversalBasisKeeperAPI:ResolveProspectingOreCost('i:10620','2g',preview.resolutionToken))
assert(not db.items['i:10620'],'Consumed ore was recreated in inventory')
assert(P:Settle()==1 and db.items['i:7910'].value==100000)
-- Resolving during the active session still waits for reload.
P,A=reset();quotes['i:7910']=1000
r=prospect(P,10620,{['i:7910']=1},30000,2)
stock('i:10620',10,100000,3)
ok,preview=UniversalBasisKeeperAPI:PreviewProspectingOreCost('i:10620','2g')
assert(ok and preview.unresolvedQty==5 and preview.knownQty==10)
assert(UniversalBasisKeeperAPI:ResolveProspectingOreCost('i:10620','2g',preview.resolutionToken))
assert(db.items['i:10620'].qty==13 and db.items['i:10620'].value==160000 and r.knownCost==70000)
assert(P:Settle()==0)
P=loadSession();assert(P:Settle()==1 and db.items['i:7910'].value==70000)
-- Invalid/partial receipts and outflow cannot silently settle or release blocks.
P,A=reset();quotes['i:7910']=1000
r=prospect(P,10620,{['i:7910']=2},50000,0,false)
P=loadSession();assert(P:Settle()==0 and P:Pending('i:7910') and P:Reason('i:7910'):find('incomplete'))
P,A=reset();quotes['i:7910']=1000
r=prospect(P,10620,{['i:7910']=2},50000);P:NoteOutflow('i:7910')
P=loadSession();assert(P:Settle()==0 and P:Pending('i:7910'))
-- Atomicity: second output unavailable means the first output keeps its old pool.
P,A=reset();quotes['i:7910']=1000;quotes['i:12361']=1000
prospect(P,10620,{['i:7910']=1,['i:12361']=1},50000)
owned['i:12361']=0
P=loadSession();assert(P:Settle()==0 and db.items['i:7910'].qty==0 and db.items['i:7910'].value==0)
owned['i:12361']=1;assert(P:Settle()==1,'Inventory readiness could not recover')
-- The settlement consumes only reserved outputs, preserving other unknown lots.
P,A=reset();quotes['i:7910']=1000
stock('i:7910',0,0,4);db.items['i:7910'].unresolvedLots={{qty=4,source='unexplained'}}
prospect(P,10620,{['i:7910']=2},50000)
P=loadSession();assert(P:Settle()==1 and db.items['i:7910'].bootstrapUnresolved==4)
assert(db.items['i:7910'].unresolvedLots[1].qty==4)
-- Input lookup only uses current covered stock; historical-only and partial pools
-- never magically become five fully costed ores. Receipt refresh precedes lookup.
P,A=reset();stock('i:10620',5,75000)
local snap=P:BeforeCast({[10620]=5});assert(refreshes==1 and snap[10620].knownCost==75000 and snap[10620].unknownQty==0)
stock('i:10620',3,45000,2);snap=P:BeforeCast({[10620]=5})
assert(snap[10620].knownCost==45000 and snap[10620].unknownQty==2)
stock('i:10620',0,0);db.items['i:10620'].lastBasis=100000
snap=P:BeforeCast({[10620]=5});assert(snap[10620].unknownQty==5 and snap[10620].knownCost==0)
-- Scope isolation: switching realm/faction cannot expose another scope's pending.
prospect(P,10620,{['i:7910']=1},50000)
local other={setup={status='complete'},items={}};UniversalBasisKeeperDB.realms.Other=other
REALM_KEY='Other';db=other;assert(not P:Pending('i:7910'));REALM_KEY='Realm-Horde'
print('PASS: pooled relative-value allocation, ore/session isolation, frozen quotes, exact cost conservation, preserved losses, labeled fallback, existing-stock blend, reload idempotence, unknown consumed/remaining ore and stale preview guards, current-session hold, incomplete/outflow blocks, atomic multi-output settlement, reserved-lot separation, input coverage and scope isolation')
-- Run the actual cast/loot observer against the accounting adapter, including
-- pre-outflow cost capture, slot-delivery evidence, and duplicate notifications.
P,A=reset();stock('i:10620',10,100000);quotes['i:7910']=20000
local bag={{itemID=10620,stackCount=10},{itemID=7910,stackCount=0}}
NUM_BAG_SLOTS=0
C_Container={GetContainerNumSlots=function()return #bag end,GetContainerItemInfo=function(_,slot)return bag[slot] end}
function GetBuildInfo()return 'x',nil,nil,20506 end
function GetTime()return 10 end
local lootCount=0
function GetNumLootItems()return lootCount end
function GetLootSlotLink()return '|Hitem:7910|hgem|h' end
function GetLootSlotInfo()return nil,nil,2 end
dofile(ADDON_ROOT..'/UBK_ProspectingLearning.lua')
local e=frames[#frames].OnEvent
e(nil,'UNIT_SPELLCAST_START','player','receipt1',31252)
bag[1].stackCount=5;owned['i:10620']=5
e(nil,'UNIT_SPELLCAST_SUCCEEDED','player','receipt1',31252)
lootCount=1;e(nil,'LOOT_READY');e(nil,'LOOT_OPENED')
assert(P:Pending('i:7910') and UBKProspectingLearning:IsProspectLoot(),'Output not blocked while loot is open')
local capStart=assert(core:find('function _G.UBKLootInternal.CaptureLootWindow()',1,true))
local capEnd=assert(core:find('function _G.UBKLootInternal.CommitLootSlot',capStart,true))
UBKLootInternal={};assert(load(core:sub(capStart,capEnd-1)))()
assert(UBKLootInternal.CaptureLootWindow()==0,'Prospect loot entered ordinary imputation handler')
bag[2].stackCount=2;owned['i:7910']=2;e(nil,'LOOT_SLOT_CLEARED',1)
e(nil,'LOOT_CLOSED');timers[#timers]()
e(nil,'LOOT_CLOSED')
local records=db.prospectSessions.records
assert(#records==1 and records[1].complete and records[1].knownCost==50000 and records[1].unknownQty==0)
assert(not UBKProspectingLearning:IsProspectLoot(),'Prospect classification leaked to later normal loot')
assert(A.ReserveGain(db.items['i:7910'],'i:7910',2)==2)
P=loadSession();assert(P:Settle()==1 and db.items['i:7910'].value==50000)
print('PASS: actual cast/loot event flow captures pre-outflow ore cost, blocks outputs before collection, excludes ordinary imputation, validates delivery, deduplicates notifications and settles once after reload')
-- Input inventory lag cannot charge the already-consumed ore again as stock.
P,A=reset();stock('i:10620',0,0,10)
local before=P:BeforeCast({[10620]=10})
local obs={basisBefore=before};P:Capture(obs,10620,{['i:7910']=1});P:Complete(obs,10620,{['i:7910']=1},true)
local good,message=UniversalBasisKeeperAPI:PreviewProspectingOreCost('i:10620','2g')
assert(not good and message:find('still updating'),'Stale ore inventory allowed a double resolution')
owned['i:10620']=5;db.items['i:10620'].bootstrapUnresolved=5
assert(UniversalBasisKeeperAPI:PreviewProspectingOreCost('i:10620','2g'))
print('PASS: consumed ore inventory lag withholds resolution until the source quantity catches up')
-- Execute the real two-stage ore resolver with lightweight frame primitives.
local function widget()
 local f={visible=false,scripts={},text=''}
 local mt={__index=function(_,key)
  if key=='CreateTexture' then return function()return widget()end end
  if key=='GetFrameLevel' then return function()return 1 end end
  if key=='GetStringHeight' then return function()return 20 end end
  if key=='SetScript' then return function(self,k,v)self.scripts[k]=v end end
  if key=='SetText' then return function(self,t)self.text=t end end
  if key=='GetText' then return function(self)return self.text end end
  if key=='Show' then return function(self)self.visible=true end end
  if key=='Hide' then return function(self)self.visible=false end end
  if key=='IsShown' then return function(self)return self.visible end end
  return function()end
 end};return setmetatable(f,mt)
end
CreateFrame=function()return widget()end
function MakeText()return widget()end
function MakeButton()return widget()end
function RegisterSpecialFrame()end
function CaptureView()return {}end
function RestoreView()end
function RenderPage()end
function ItemName(item)return item end
function ItemTexture()return 'texture'end
function Money(v)return tostring(v)end
API=UniversalBasisKeeperAPI
function API:GetBasisInfo(item)local s=db.items[item] or {};return {itemString=item,name=item,knownQty=s.qty or 0,unresolvedQty=s.bootstrapUnresolved or 0,observedQty=owned[item] or 0}end
UBKItemRules={QualityColor=function()return 1,1,1 end}
UI={root=widget()};UIParent=widget()
local ui=source('UBK_Interface.lua')
local beginAt=assert(ui:find('local function CreateResolveConfirmDialog()',1,true))
local endAt=assert(ui:find('local function InvalidateChumCache()',beginAt,true))
assert(load(ui:sub(beginAt,endAt-1)..'\nTEST_SHOW_ORE_DIALOG=ShowResolveUnknownDialog'))()
TEST_SHOW_ORE_DIALOG('i:10620',true)
assert(UI.resolveDialog.visible and UI.resolveDialog.prompt.text=="Tell me the ore's basis (per ore):")
UI.resolveDialog.edit:SetText('2g');UI.resolveDialog.resolveButton.scripts.OnClick()
assert(UI.resolveConfirmDialog.visible and UI.resolveConfirmDialog.prospecting and not UI.resolveDialog.visible)
-- A new pending prospect invalidates the old confirmation token.
prospect(P,10620,{['i:7910']=1},0,5)
UI.resolveConfirmDialog.confirmButton.scripts.OnClick()
assert(UI.resolveConfirmDialog.status.text:find('changed') and P:UnknownInput('i:10620')==10)
UI.resolveConfirmDialog.confirmButton.scripts.OnClick()
assert(P:UnknownInput('i:10620')==0 and not UI.resolveConfirmDialog.visible)
stock('i:2770',0,0,3);TEST_SHOW_ORE_DIALOG('i:2770')
assert(not UI.resolveDialog.prospecting and UI.resolveDialog.prompt.text=='Resolve each unresolved unit at:','Ore mode leaked into ordinary resolver')
print('PASS: actual ore resolver prompt, separate preview/confirm, stale session re-review, consumed-plus-remaining resolution, and normal resolver mode reset')

-- Powder is recorded as a vendor credit, never priced from gem market weights.
P,A=reset();quotes['i:12361']=10000
local vendor=820;function A.VendorSell(item)assert(item=='i:24235');return vendor end
local o={basisBefore={[10620]={knownCost=50000,unknownQty=0}}}
P:Capture(o,10620,{['i:12361']=1,['i:24235']=1})
P:Complete(o,10620,o.allOutputs,true)
owned['i:12361']=1;A.ReserveGain(db.items['i:12361'],'i:12361',1)
assert(not P:Pending('i:24235') and not db.items['i:24235'],'Vendor powder entered gem reservations')
vendor=99999 -- captured vendor quote must remain frozen
P=loadSession();assert(P:Settle()==1)
assert(db.items['i:12361'].value==49180,'Powder vendor credit not subtracted')
local record=db.prospectSessions.records[1]
assert(record.poolInputCost==50000 and record.poolVendorCredit==820 and record.poolCost==49180)
assert(P:Settle()==0 and db.items['i:12361'].value==49180,'Powder credit replayed')
-- Missing vendor value blocks, known zero is valid, and large credit never
-- manufactures a negative gem basis. Keep excess credit explicitly recorded.
local row={complete=true,knownCost=500,unknownQty=0,outputs={['i:12361']=1},prices={['i:12361']=10000},byproducts={['i:24235']=1},vendorPrices={}}
vendor=nil;assert(not P:Plan({row}))
vendor=0;local plan=assert(P:Plan({row}));assert(plan.cost==500)
vendor=820;plan=assert(P:Plan({row}));assert(plan.cost==0 and plan.vendorSurplus==320)
row.byproducts={};row.outputs['i:24235']=1
plan=assert(P:Plan({row}));assert(not plan.outputs['i:24235'] and plan.vendorCredit==820,'Older session powder was treated as a gem')
print('PASS: actual powder capture, frozen vendor credit, powder sale does not reserve/block gem settlement, exact input/credit/gem-cost reconciliation, replay protection, missing/zero vendor values, excess credit, legacy output classification')
