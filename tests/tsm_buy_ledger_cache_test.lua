-- Test UBK's bridge against small service doubles. No TSM source is bundled.
local function eq(actual,expected,message)
    assert(actual==expected,(message or 'mismatch')..': '..tostring(actual)..' ~= '..tostring(expected))
end
local columns={'itemString','stackSize','quantity','price','otherPlayer','player','time','source'}
local header=table.concat(columns,',')
local s={queries=0,iterations=0,encoded=0,liveTemps=0,liveQueries=0,watchers={}}
s.rows={
    {type='buy',isCurrentRealm=true,itemString='i:23424',stackSize=20,quantity=40,price=123,otherPlayer='Seller',player='Buyer',time=100,source='Auction'},
    {type='sale',isCurrentRealm=true,itemString='i:23424',stackSize=1,quantity=1,price=555,otherPlayer='Other',player='Buyer',time=101,source='Auction'},
    {type='buy',isCurrentRealm=false,itemString='i:23425',stackSize=20,quantity=20,price=900,otherPlayer='Seller',player='Alt',time=102,source='Auction'},
}
local allocated={}
local temp={}
local function acquire()
    local value={};allocated[value]=true;s.liveTemps=s.liveTemps+1;return value
end
function temp.Release(value)
    assert(allocated[value],'double or foreign temporary-table release')
    allocated[value]=nil;s.liveTemps=s.liveTemps-1
end
-- These doubles verify the CSV call contract and resource ownership, rather
-- than reproducing TSM's encoder implementation or depending on its source.
local csv={}
function csv.EncodeStart(keys)
    eq(table.concat(keys,','),header,'CSV column order')
    local encoder=acquire();encoder.lines=acquire();encoder.lineParts=acquire()
    encoder.output={header};return encoder
end
function csv.EncodeAddRowDataRaw(encoder,...)
    eq(select('#',...),8,'CSV row arity')
    s.encoded=s.encoded+1
    if s.fail then s.fail=false;error('injected export error') end
    encoder.output[#encoder.output+1]=table.concat({...},',')
end
function csv.EncodeEnd(encoder)
    local result=table.concat(encoder.output,'\n')
    temp.Release(encoder.lineParts);temp.Release(encoder.lines);temp.Release(encoder)
    return result
end
local transactions={}
function transactions.CreateQuery()
    s.queries=s.queries+1;s.liveQueries=s.liveQueries+1
    local q={filters={},joins=true,virtual=true}
    function q:ResetJoins()self.joins=false;return self end
    function q:ResetVirtualFields()assert(not self.joins);self.virtual=false;return self end
    function q:Equal(key,value)self.filters[key]=value;return self end
    function q:Select(...)
        self.fields={...};eq(table.concat(self.fields,','),header,'query column order');return self
    end
    function q:SetUpdateCallback(callback)
        assert(not self.joins and not self.virtual,'watch retained UI joins')
        self.callback=callback;s.watchers[self]=true;return self
    end
    function q:Iterator()
        assert(not self.callback,'watcher executed a full-history query')
        assert(not self.joins and not self.virtual,'export retained UI joins')
        eq(self.filters.type,'buy','transaction scope');eq(self.filters.isCurrentRealm,true,'realm scope')
        s.iterations=s.iterations+1
        local index=0
        return function()
            while index<#s.rows do
                index=index+1;local row=s.rows[index];local matches=true
                for key,value in pairs(self.filters) do if row[key]~=value then matches=false end end
                if matches then
                    local values={index}
                    for _,field in ipairs(self.fields) do values[#values+1]=row[field] end
                    return table.unpack(values)
                end
            end
        end
    end
    function q:Release(abort)
        assert(not self.released,'query released twice')
        self.released=true;s.liveQueries=s.liveQueries-1;s.watchers[self]=nil;s.lastAbort=abort
    end
    return q
end
local env=setmetatable({},{__index=_G});env._G=env
env.hooksecurefunc=function()end
env.CreateFrame=function()return {RegisterEvent=function()end,SetScript=function()end}end
local lib={Include=function(_,name)
    if name=='Format.CSV' then return csv end
    if name=='BaseType.TempTable' then return temp end
    return {}
end}
local tsm={LibTSMTypes=lib,LibTSMUtil=lib,Accounting={Transactions=transactions}}
assert(loadfile(ADDON_ROOT..'/UBK_TSMBridge.lua','t',env))('TradeSkillMaster',tsm)
local b=env.UBKTSMGroupBridge
assert(not pcall(b.GetBuyLedgerCSV),'uninitialized bridge exported purchases')
b.ready=true
local function invalidate()
    local count=0
    for q in pairs(s.watchers) do count=count+1;q.callback(q) end
    eq(count,1,'one persistent transaction watcher')
end
local function expected(...)
    local result={header}
    for n=1,select('#',...) do result[#result+1]=select(n,...) end
    return table.concat(result,'\n')
end
local first='i:23424,20,40,123,Seller,Buyer,100,Auction'
eq(b.GetBuyLedgerCSV(),expected(first),'initial export')
for _=1,100 do eq(b.GetBuyLedgerCSV(),expected(first),'cached export') end
eq(s.iterations,1,'unchanged history rescanned');eq(s.queries,2,'unchanged history allocated queries')
eq(s.encoded,1,'unchanged history re-encoded');eq(s.liveQueries,1,'export query leaked');eq(s.liveTemps,0)

-- TSM combines repeated buys by changing quantity on an existing row.
s.rows[1].quantity=60;invalidate()
local combined='i:23424,20,60,123,Seller,Buyer,100,Auction'
eq(b.GetBuyLedgerCSV(),expected(combined),'combined quantity not refreshed')
eq(s.iterations,2);eq(b.GetBuyLedgerCSV(),expected(combined));eq(s.iterations,2)

-- Separate identical rows retain multiplicity; no deduplication is allowed.
local duplicate={};for key,value in pairs(s.rows[1]) do duplicate[key]=value end
s.rows[#s.rows+1]=duplicate;invalidate()
eq(b.GetBuyLedgerCSV(),expected(combined,combined),'duplicate purchase row lost')
table.remove(s.rows,1);invalidate()
eq(b.GetBuyLedgerCSV(),expected(combined),'deleted purchase row retained')

duplicate.price=130;duplicate.otherPlayer='';invalidate();invalidate();invalidate()
local before=s.iterations
local changed='i:23424,20,60,130,,Buyer,100,Auction'
eq(b.GetBuyLedgerCSV(),expected(changed),'updated price or blank field lost')
eq(s.iterations,before+1,'update burst did not coalesce')

invalidate();s.fail=true
local ok,err=pcall(b.GetBuyLedgerCSV)
assert(not ok and tostring(err):find('injected export error',1,true),'export error hidden')
eq(b.buyLedgerCSV,nil,'partial export cached');eq(s.liveTemps,0,'encoder resources leaked')
eq(s.liveQueries,1,'failed export query leaked');eq(s.lastAbort,true,'iterator failure not aborted')
eq(b.GetBuyLedgerCSV(),expected(changed),'retry after failure changed data')
eq(s.liveTemps,0)

duplicate.isCurrentRealm=false;invalidate()
eq(b.GetBuyLedgerCSV(),header,'foreign-realm or sale row exported')
before=s.iterations
eq(b.GetBuyLedgerCSV(),header,'empty export changed');eq(s.iterations,before,'empty history not cached')
tsm.Accounting=nil
eq(b.GetBuyLedgerCSV(),nil,'missing Accounting service returned stale cache')
eq(s.liveQueries,1);eq(s.liveTemps,0)
print('PASS: purchase CSV exact columns/units and duplicate rows, unchanged-history cache, combined quantity/deletion/price invalidation, coalesced updates, query/encoder cleanup, retry and empty-history cache')
