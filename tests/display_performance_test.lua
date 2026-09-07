-- Exercise the actual display and membership functions without loading WoW.
local file=assert(io.open(ADDON_ROOT..'/UniversalBasisKeeper.lua','r'))
local source=file:read('*a');file:close()
local function section(first,last)
 local start=assert(source:find(first,1,true),'missing '..first)
 local ending=assert(source:find(last,start,true),'missing '..last)
 return source:sub(start,ending-1)
end
local order=section('local BASIS_ORDER =','local function IsLiteralMoney')
local reset=section('function _G.UBKSetupInternal.ResetDiscoveryForSetup','function _G.UBKSetupInternal.SetupBegin')
local peek=section('function _G.UBKInternal.PeekRealmDB()','function _G.UBKInternal.ShelfCommand')
local status=section('function _G.UBKInternal.AccountingStatus()','function _G.UBKInternal.ScheduleRefresh()')
local tooltip=section('function UBK_AddBasisToTooltip(tooltip)','-- UBK Shredder engine')
local code=[=[
local BASIS_SEEDS={}
local REALM_KEY='Test-Horde'
_G.UBKSetupInternal={}; _G.UBKInternal={}
UBK_PURCHASE_UNIVERSE_SCHEMA=1
function time() return 123 end
local function EnsureUniversalState(db) db.universal={} end
local heavyReads=0
local function GetRealmDB() heavyReads=heavyReads+1;error('display triggered hydration') end
local function IsUniversalExcluded() return false end
local function GetUnitBasis(s) return s.value/s.qty end
local function FormatMoney(n) return tostring(n) end
]=] ..
order ..
reset ..
peek ..
status ..
[=[
EnsureOrderItem('i:2');EnsureOrderItem('i:1')
for i=1,10000 do EnsureOrderItem('i:2');EnsureOrderItem('i:1') end
assert(#BASIS_ORDER==2 and BASIS_ORDER[1]=='i:2' and BASIS_ORDER[2]=='i:1','order/dedup changed')
local resetDB={}
UBKSetupInternal.ResetDiscoveryForSetup(resetDB,'empty')
EnsureOrderItem('i:1');EnsureOrderItem('i:2')
assert(#BASIS_ORDER==2 and BASIS_ORDER[1]=='i:1','reset left stale membership')
local book={items={['i:2']={qty=5,value=100,lastBasis=20}},accountingCapture={pending=true}}
UniversalBasisKeeperDB={realms={['Test-Horde']=book,['Other-Alliance']={items={}}}}
assert(UBKInternal.PeekRealmDB()==book)
local rendered=0
UBKLiveTooltip={Suppress=function() return false end,Render=function(t,s,item)
 rendered=rendered+1;t.__ubkLiveBasis={};assert(s==book.items[item])
end}
UBKPurchaseLedger={Status=function(db) return db and db.accountingCapture and db.accountingCapture.pending end}
local tip={hooks={}}
function tip:GetItem() return 'test','item:2' end
function tip:HookScript(name,fn) self.hooks[name]=fn end
GameTooltip=tip; ItemRefTooltip=nil; UBK_TOOLTIP_HOOKS_INSTALLED=false
]=] ..
tooltip ..
[=[
UBK_AddBasisToTooltip(tip)
UBK_InstallTooltipHooks()
for i=1,100 do tip.hooks.OnUpdate(tip,.2) end
assert(rendered==101 and heavyReads==0,'tooltip unexpectedly hydrated')
assert(UBKInternal.AccountingStatus()==true and heavyReads==0)
book.accountingCapture.pending=false
assert(UBKInternal.AccountingStatus()==false,'status cached stale pending state')
book.items['i:2'].value=125
tip.hooks.OnUpdate(tip,.2)
assert(book.items['i:2'].qty==5 and book.items['i:2'].value==125,'read mutated books')
for _,bad in ipairs({false,1,'bad',{},{realms={}},{realms={['Test-Horde']=5}},{realms={['Test-Horde']={items=9}}}}) do
 UniversalBasisKeeperDB=bad
 assert(UBKInternal.PeekRealmDB()==nil)
 tip.__ubkBasisItem=nil
 UBK_AddBasisToTooltip(tip)
 assert(tip.__ubkBasisItem==nil,'uninitialized item was marked rendered')
 tip.hooks.OnUpdate(tip,.2)
 assert(UBKInternal.AccountingStatus()==nil)
end
UniversalBasisKeeperDB=nil
assert(UBKInternal.PeekRealmDB()==nil)
assert(heavyReads==0)
print('UBK regression PASS: order, duplicates, setup reset, realm scoping, live status, tooltip reads, missing/malformed DB, cost preservation')
]=]
assert(load(code,'UBK display regression'))()
