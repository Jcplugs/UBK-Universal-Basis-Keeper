function strsplit(sep,s)local out={};for v in (s..sep):gmatch('(.-)'..sep) do out[#out+1]=v end;return table.unpack(out) end
assert(loadfile(ADDON_ROOT..'/UBK_PurchaseLedger.lua'))()
local P=UBKPurchaseLedger
local function parse(line)
 local item,_,qty,price,seller,buyer,stamp,source=strsplit(',',line)
 qty=tonumber(qty);price=tonumber(price);stamp=tonumber(stamp)
 if qty and price and stamp then return item,qty,price,stamp,buyer,seller,source end
end
local rows={};local db={items={},cutoffTime=0,processedCounts={},processedPurchaseQty={}}
for i=1,50000 do
 local line='i:23441,1,1,300000,Seller,Buyer,'..i..',Auction'
 rows[#rows+1]=line;db.processedPurchaseQty[P.Key(line)]=1
end
for i=1,90 do rows[#rows+1]='i:23440,1,1,'..(290000+(i%3)*10000)..',Seller,Buyer,'..(50000+i)..',Auction' end
local csv=table.concat(rows,'\n');local queue={};local parsed=0;local prepared
local function schedule(fn) queue[#queue+1]=fn end
P.PrepareBatch(csv,db,function(line)parsed=parsed+1;return parse(line)end,{Buyer=true},0,schedule,function(result)prepared=result end)
assert(parsed==0 and not prepared,'Preparation blocked caller')
while #queue>0 do
 local before=parsed;table.remove(queue,1)()
 assert(parsed-before<=300,'History exceeded per-frame row budget')
 assert(next(db.items)==nil,'Read-only preparation changed basis')
end
assert(parsed==50090 and #prepared.rows==90,'History repeated or old rows retained for commit')
local cost=0
for _,row in ipairs(prepared.rows) do cost=cost+row[3]*row[4];db.processedPurchaseQty[row[11]]=row[10] end
assert(cost==27000000,'Mixed purchase costs changed')
prepared=nil;P.PrepareBatch(csv,db,parse,{Buyer=true},0,schedule,function(result)prepared=result end)
while #queue>0 do table.remove(queue,1)() end
assert(#prepared.rows==0,'Replay selected settled quantities')
local line='i:23441,1,1,149591,Doniyen,Buyer,50000,Auction'
local claims={};local index=P.InvoiceIndex(line..'\n'..line,parse,0,50010,'Buyer')
local invoice={itemString='i:23441',qty=1,unitPrice=149591,seller='Doniyen',expectedPurchaseAt=50000}
for i=1,2 do local match=assert(P.FindInvoice(index,claims,invoice));assert(match.occurrence==i);claims[match.line]=i end
assert(not P.FindInvoice(index,claims,invoice),'Identical invoices claimed too often')
invoice.seller='Wrong';assert(not P.FindInvoice(index,{},invoice),'Seller mismatch accepted')
invoice.seller='Doniyen';invoice.expectedPurchaseAt=49000;assert(not P.FindInvoice(index,{},invoice),'Time mismatch accepted')
assert(not P.FindInvoice(P.InvoiceIndex(line,parse,0,50010,'Other'),{},invoice),'Other buyer included')
print('PASS: 50,000 historical + 90 new purchases parsed once in <=300-row steps, exact 2,700g cost, read-only preparation, empty replay, duplicate invoice/seller/time/buyer guards')

local function source(file)local f=assert(io.open(ADDON_ROOT..'/'..file));local s=f:read('*a');f:close();return s end
local core=source('UniversalBasisKeeper.lua')
local a=assert(core:find('function _G.UBKInternal.AuctionBusy()',1,true))
local b=assert(core:find('-- UBK v1.3.1 Loot',a,true))
_G.UBKInternal={};_G.UBKTSMGroupBridge={ready=true,IsAuctionScanBusy=function()return false end}
local commits=0;local reads=0
C_Timer={After=function(_,fn)schedule(fn)end}
function IsSupportedRealm()return true end
function GetRealmDB()return db end
function SetupAllowsProcessing()return true end
function GetTSMBuyLedger()reads=reads+1;return csv end
function UBK_CurrentFactionCharacters()return {Buyer=true} end
function ParseBuyLine(line)return parse(line)end
function ProcessLedger(_,_,batch)assert(not P.AnySourceOpen());assert(batch);commits=commits+1 end
function time()return 60000 end
BASIS_CUTOVER_TIME=0;mailboxSessionOpen=false
assert(load(core:sub(a,b-1)))()
local I=UBKInternal
local function drain()local count=0;while #queue>0 do count=count+1;assert(count<1000,'Unbounded retry');table.remove(queue,1)() end end
local function event(name) local change=P.SourceEvent(name,db,time());if change=='close' then I.ScheduleAccountingSettlement() end end
for _,names in ipairs({{'MAIL_SHOW','MAIL_CLOSED'},{'AUCTION_HOUSE_SHOW','AUCTION_HOUSE_CLOSED'},{'TRADE_SHOW','TRADE_CLOSED'},{'MERCHANT_SHOW','MERCHANT_CLOSED'},{'LOOT_OPENED','LOOT_CLOSED'}}) do
 local previous=commits;local previousReads=reads
 event(names[1]);for i=1,200 do I.ScheduleRefresh() end;drain()
 assert(commits==previous and reads==previousReads and db.accountingCapture.pending,'Open window performed accounting')
 event(names[2]);for i=1,200 do I.ScheduleRefresh() end
 assert(#queue==1,'Refresh storm created multiple jobs')
 drain();assert(commits==previous+1 and reads==previousReads+1 and not db.accountingCapture.pending,'Close did not settle exactly once')
end
-- Reopening during preparation invalidates the snapshot, even if closed again
-- before its next step. The new snapshot is prepared once the old job releases.
event('MAIL_SHOW');event('MAIL_CLOSED');table.remove(queue,1)();table.remove(queue,1)()
local previous=commits
event('TRADE_SHOW');event('TRADE_CLOSED');drain();assert(commits==previous+1)
-- Overlapping sources: only the last close releases the batch.
event('MAIL_SHOW');event('AUCTION_HOUSE_SHOW');event('MAIL_CLOSED');assert(#queue==0)
event('AUCTION_HOUSE_CLOSED');drain();assert(not P.AnySourceOpen())
-- A read failure unlocks the queue and keeps the persisted evidence marker.
local original=GetTSMBuyLedger
function GetTSMBuyLedger()error('test unavailable')end
event('MAIL_SHOW');event('MAIL_CLOSED');drain();assert(not P.settlementPending and db.accountingCapture.pending)
GetTSMBuyLedger=original;I.ScheduleRefresh();drain();assert(not db.accountingCapture.pending)
-- Normal logout retains a pending marker; fresh runtime state can resume it.
event('TRADE_SHOW');P.windows={};P.generation=0;I.ScheduleRefresh();drain();assert(not db.accountingCapture.pending)
print('PASS: all five source types defer accounting, event storms coalesce, reopen invalidates old snapshot, overlapping windows wait for final close, failed reads retain evidence/unlock, saved pending session resumes')

-- Exercise the actual core event handler, including the mailbox-local flag.
-- A real interaction-manager close must pass through the full legacy cleanup.
local callback
_G.events={SetScript=function(_,_,fn)callback=fn end}
local start=assert(core:find('events:SetScript("OnEvent", function',1,true))
local finish=assert(core:find('-- BEGIN UBK PROSPECT ACCOUNTING ADAPTER',start,true))
assert(load(core:sub(start,finish-1)))()
Enum={PlayerInteractionType={MailInfo=17,Auctioneer=21,Merchant=5,TradePartner=1,Banker=8}}
UBKLiveTooltip={SetMailbox=function(open)UBKLiveTooltip.mailboxOpen=open end}
mailLootHook={};mailboxSessionOpen=true;mailboxBaselinePending=true
P.SourceEvent('MAIL_SHOW',db,time())
local before=commits
callback(nil,'PLAYER_INTERACTION_MANAGER_FRAME_HIDE',Enum.PlayerInteractionType.MailInfo)
assert(not mailboxSessionOpen and not mailboxBaselinePending and not UBKLiveTooltip.mailboxOpen,'Modern close failed mailbox cleanup')
assert(not P.AnySourceOpen() and #queue==1,'Modern close left accounting source open')
drain();assert(commits==before+1,'Modern mailbox close did not settle')
assert(core:find('events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")',1,true),'Modern event not registered')
for _,entry in ipairs({{'Auctioneer','AUCTION_HOUSE_CLOSED'},{'Merchant','MERCHANT_CLOSED'},{'TradePartner','TRADE_CLOSED'}}) do
 assert(P.NormalizeEvent('PLAYER_INTERACTION_MANAGER_FRAME_HIDE',Enum.PlayerInteractionType[entry[1]],Enum.PlayerInteractionType)==entry[2])
end
local generation=P.generation
callback(nil,'PLAYER_INTERACTION_MANAGER_FRAME_HIDE',Enum.PlayerInteractionType.Banker)
assert(P.generation==generation and #queue==0,'Untracked service close changed accounting')
assert(P.NormalizeEvent('PLAYER_INTERACTION_MANAGER_FRAME_HIDE',nil,{})==nil)
assert(P.NormalizeEvent('MAIL_CLOSED',nil,{})=='MAIL_CLOSED')
-- Both client notifications for one close cannot double-settle a purchase.
mailboxSessionOpen=true;P.SourceEvent('MAIL_SHOW',db,time());before=commits
callback(nil,'PLAYER_INTERACTION_MANAGER_FRAME_HIDE',Enum.PlayerInteractionType.MailInfo)
callback(nil,'MAIL_CLOSED');drain();assert(commits==before+1,'Duplicate close notifications doubled settlement')
print('PASS: actual core interaction-manager mailbox close clears both source and collection flags, schedules settlement, ignores unrelated services, handles missing enums, and tolerates both modern/legacy notifications')
