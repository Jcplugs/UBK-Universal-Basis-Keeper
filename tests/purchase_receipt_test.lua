local function source(file)local f=assert(io.open(ADDON_ROOT..'/'..file));local s=f:read('*a');f:close();return s end
function strsplit(sep,s) local out={};for word in (s..sep):gmatch('(.-)'..sep)do out[#out+1]=word end;return table.unpack(out) end
assert(loadfile(ADDON_ROOT..'/UBK_PurchaseLedger.lua'))()
local core=source('UniversalBasisKeeper.lua')
local function extract(a,b) return core:sub(assert(core:find(a,1,true)),assert(core:find(b,1,true))-1) end
local parser=extract('local function ParseBuyLine','local function EnsureUnresolvedLots'):gsub('local function ParseBuyLine','function ParseBuyLine',1)
assert(load(parser))()
function EnsureUnresolvedLots(state)return state.unresolvedLots or {} end
LATE_LEDGER_MATCH_WINDOW=1800
assert(load(extract('local function MatchUnresolvedLotsToLedger','local function RecordAppliedMailLot'):gsub('local function MatchUnresolvedLotsToLedger','function MatchUnresolvedLotsToLedger',1)))()
local db
function IsSupportedRealm()return true end
function TryLegacyMigration()end
function GetRealmDB()return db end
function SetupAllowsProcessing()return true end
function UBK_CurrentFactionCharacters()return {Buyer=true} end
function UnitName()return 'Buyer' end
function time()return 1010 end
function RepairKnownTest6Race()return 0 end
function AddShredEligibleQty(s,q)s.shredEligibleQty=(s.shredEligibleQty or 0)+q end
function AutoSyncTSM()end
local pendingMatched,appliedMatched=0,0
function ConsumePendingMailMatch(_,_,qty)pendingMatched=pendingMatched+qty end
function ConsumeAppliedMailMatch(_,_,qty)local n=math.min(qty,appliedMatched);appliedMatched=appliedMatched-n;return n end
function DropMailLots()end
function RefreshCostReviews()end
local inventory=105;local inventoryReads=0
function GetRealmTrackedQuantities()inventoryReads=inventoryReads+1;return {['i:23425']=inventory},true end
function ApplyOutflow(s,target)local n=s.qty-target;s.value=s.value*target/s.qty;s.qty=target;return n end
function AddUnresolvedLot(s,q)s.bootstrapUnresolved=(s.bootstrapUnresolved or 0)+q end
function ReduceUnresolvedForOutflow()error('unexpected unresolved outflow')end
function ApplyMailLots()return 0,0,0 end
BASIS_SEEDS={['i:23425']={name='Ore'}};BASIS_ORDER={'i:23425'};BASIS_CUTOVER_TIME=0
local csv
function GetTSMBuyLedger()return csv end
mailboxSessionOpen=true;mailLootHook={burstActive=true}
assert(load(extract('ProcessLedger = function','local function GetTSMVersion')))()
local function line(q,price,buyer)return 'i:23425,1,'..q..','..(price or 200)..',Seller,'..(buyer or 'Buyer')..',1000,Auction' end
local function reset()
 db={cutoffTime=900,processedCounts={},items={['i:23425']={qty=10,value=10000,pending=0,lastObserved=105,bootstrapUnresolved=95,unresolvedLots={{qty=95,detectedAt=1005}}}}}
 UBKPurchaseLedger.Prepare(db)
end
reset();csv=line(95)
local records,qty=ProcessLedger(true);assert(records==0 and qty==0)
mailboxSessionOpen=false
local callbacks={};local batch
UBKPurchaseLedger.PrepareBatch(csv,db,ParseBuyLine,UBK_CurrentFactionCharacters(),0,function(fn)callbacks[#callbacks+1]=fn end,function(result)batch=result end)
while #callbacks>0 do table.remove(callbacks,1)() end
records,qty=ProcessLedger(true,false,batch)
local s=db.items['i:23425'];assert(records==1 and qty==95 and s.qty==105 and s.value==29000 and s.bootstrapUnresolved==0 and inventoryReads==1,'95 purchased unresolved units not converted after close')
assert(s.pending==0,'Already observed units left pending')
records,qty=ProcessLedger(true,true);assert(records==0 and qty==0 and s.qty==105,'Repeated receipt doubled cost')
csv=line(96);records,qty=ProcessLedger(true,true);assert(qty==1 and s.qty==106 and s.value==29200,'Growing TSM row added its full quantity again')
mailLootHook.burstActive=false;inventory=106;ProcessLedger(true);assert(s.qty==106 and s.pending==0,'Mailbox close counted another purchase')
-- Checkpoint survives reload / saved CSV taking over, and current faction is enforced.
db.processedPurchaseQty=UBKPurchaseLedger and db.processedPurchaseQty;ProcessLedger(true);assert(s.qty==106)
csv=line(96)..'\n'..line(95,200,'OtherFaction');ProcessLedger(true);assert(s.qty==106,'Foreign faction entered basis')
-- Existing legacy processed rows seed quantities, including identical occurrences.
local old={processedCounts={[line(10)]=2}};UBKPurchaseLedger.Prepare(old)
local new,key,total=UBKPurchaseLedger.Take(old,{},line(25),25);assert(new==5 and total==25,'Legacy checkpoints were not migrated')
-- Invoice already applied: live ledger must consume its evidence without adding cost.
reset();s=db.items['i:23425'];s.qty=105;s.value=29000;s.bootstrapUnresolved=0;s.unresolvedLots={};appliedMatched=95;csv=line(95)
mailLootHook.burstActive=true;records,qty=ProcessLedger(true,true);assert(qty==0 and s.qty==105 and s.value==29000 and appliedMatched==0,'Invoice and live transaction counted twice')
-- Tooltip updates an existing line while held open, never duplicates it.
assert(loadfile(ADDON_ROOT..'/UBK_LiveTooltip.lua'))()
local tip={n=0};function tip:GetName()return 'TestTip' end;function tip:NumLines()return self.n end
function tip:AddLine(text)self.n=self.n+1;_G['TestTipTextLeft'..self.n]={text=text,SetText=function(f,t)f.text=t end,SetTextColor=function()end}end
local function basis(st)return st.qty>0 and st.value/st.qty or 0 end
UBKLiveTooltip.Render(tip,s,'i:23425',basis,tostring);local n=tip.n;local before=TestTipTextLeft1.text
s.qty=s.qty+1;s.value=s.value+200;UBKLiveTooltip.Render(tip,s,'i:23425',basis,tostring)
assert(tip.n==n and TestTipTextLeft1.text~=before,'Open tooltip stayed stale or duplicated lines')
print('PASS: 95 paid units resolved after mailbox close; repeated and growing records, faction isolation, invoice dedupe, legacy quantity migration, settled inventory and open-tooltip refresh')
-- The same ledger arithmetic still handles 90 mixed-price single-unit increments.
BASIS_SEEDS={['i:23440']={name='Dawnstone'}};BASIS_ORDER={'i:23440'}
function GetRealmTrackedQuantities()return {['i:23440']=inventory},true end
local openingValue=12*350000
inventory=12;db={cutoffTime=900,processedCounts={},items={['i:23440']={qty=12,value=openingValue,pending=0,lastObserved=12,bootstrapUnresolved=0,unresolvedLots={}}}}
mailLootHook.burstActive=true;appliedMatched=0
local function dawn(q,p)return 'i:23440,1,'..q..','..p..',Seller,Buyer,1000,Auction' end
local paid=0
for i=1,90 do
 local rows={};local left=i
 for _,price in ipairs({290000,300000,310000}) do local q=math.min(30,left);left=left-q;if q>0 then rows[#rows+1]=dawn(q,price) end end
 csv=table.concat(rows,'\n');paid=paid+(i<=30 and 290000 or (i<=60 and 300000 or 310000))
 local prior=db.items['i:23440'].value/db.items['i:23440'].qty
 local _,qty=ProcessLedger(true,true);local st=db.items['i:23440']
 assert(qty==1 and st.qty==12+i and st.value==openingValue+paid,'Dawnstone paid amounts were missed or multiplied')
 assert(st.value/st.qty~=prior,'Dawnstone basis did not move on collection')
 ProcessLedger(true,true);assert(st.qty==12+i,'Repeated collection pass doubled a Dawnstone')
end
inventory=102;mailLootHook.burstActive=false;ProcessLedger(true)
local dawnstone=db.items['i:23440']
assert(dawnstone.qty==102 and dawnstone.value==31200000 and dawnstone.pending==0 and dawnstone.bootstrapUnresolved==0)
ProcessLedger(true);assert(dawnstone.value==31200000,'Saved/live replay changed the paid value')
-- A captured invoice can still be applied when a CSV is temporarily unavailable.
csv=nil;inventory=103
function ApplyMailLots(_,item,gain)
 assert(item=='i:23440' and gain==1)
 dawnstone.qty=dawnstone.qty+1;dawnstone.value=dawnstone.value+300000
 return 1,300000,1
end
ProcessLedger(true);assert(dawnstone.qty==103 and dawnstone.value==31500000,'Missing CSV prevented captured invoice delivery')
-- Purchase matching must never consume a prospect reservation.
local reserved={bootstrapUnresolved=3,unresolvedLots={{qty=2,detectedAt=1005,source='prospecting-pending'},{qty=1,detectedAt=1005,source='unexplained'}}}
assert(MatchUnresolvedLotsToLedger(reserved,3,1000)==1 and reserved.bootstrapUnresolved==2 and reserved.unresolvedLots[1].qty==2)
print('PASS: 90 Dawnstones at 29g/30g/31g collected individually; each paid amount updates the pool, repeated passes and saved/live replay do not double-count; invoice-only delivery works without CSV; prospect reservations cannot be claimed as purchases')
