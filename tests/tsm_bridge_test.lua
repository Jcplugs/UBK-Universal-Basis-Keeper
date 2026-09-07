local frames={}
function CreateFrame() local f={};function f:RegisterEvent() end;function f:SetScript(k,v) self[k]=v end;frames[#frames+1]=f;return f end
C_Timer={After=function(_,fn) fn() end}
function hooksecurefunc(t,key,hook) local old=t[key];assert(type(old)=="function",key);t[key]=function(...) local result={old(...)};hook(...);return table.unpack(result) end end
function GetBuildInfo() return "x",nil,nil,20506 end
C_AddOns={GetAddOnMetadata=function() return "v4.14.76" end}
local groups={['zz - sell above basis']={Auctioning={override=true,'ExistingOp'},Crafting={override=true,'Craft'}} ,Crafts={Auctioning={override=true,'OriginalPost'},Crafting={override=true,'Craft'}}}
local items={["i:1"]="Crafts"}
local ops={['UBK - Sell Above Basis']={minPrice='old'},OriginalPost={minPrice='original'}}
local group={GetRootPath=function() return "" end,TranslateItemString=function(s)return s end,Exists=function(s)return groups[s]~=nil end,IsItemInGroup=function(s)return items[s]~=nil end,GetPathByItem=function(s)return items[s] or "" end,SetItemGroup=function(s,p)items[s]=p end,IsChild=function()return false end,JoinPath=function(a,b)return a..b end,GetRelativePath=function(s)return s end}
local operation={}
function operation.Exists(_,name) return ops[name]~=nil end
function operation.GetSettings(_,name) return assert(ops[name]) end
function operation.Create(_,name) assert(not ops[name]);ops[name]={relationships={}} end
function operation.UpdateFromRelationships() end
function operation.TypeIterator() return ipairs({'Auctioning','Crafting'}) end
local groupOps={}
function groupOps.Iterator(path,kind) return ipairs(groups[path][kind]) end
function groupOps.HasOverride(path,kind) return groups[path][kind].override end
function groupOps.SetOverride(path,kind,enabled) groups[path][kind].override=enabled end
function groupOps.CreateGroup(path) assert(not groups[path]);groups[path]={Auctioning={'RootPost'},Crafting={'RootCraft'}} end
function groupOps.Remove(path,kind,index) table.remove(groups[path][kind],index) end
function groupOps.Add(path,kind,op) table.insert(groups[path][kind],op);groups[path][kind].override=true end
function groupOps.MoveGroup(old,new) groups[new]=groups[old];groups[old]=nil;for item,p in pairs(items)do if p==old then items[item]=new end end end
local prices={};local custom={}
local price={SOURCE_TYPE={NORMAL='normal',VOLATILE='volatile'}}
function price.IsSourceRegistered(key)return prices[key]~=nil end
function price.IsCustomSourceRegistered(key)return custom[key]~=nil end
function price.RegisterSource(module,key,label,fn,kind) assert(not prices[key:lower()]);prices[key:lower()]={fn=fn,kind=kind} end
function price.InvalidateCache() end
local sourceModules={Group=group,GroupOperation=groupOps,Operation=operation,CustomString=price}
local statusCallback
local publisher={CallFunction=function(self,fn)statusCallback=fn;return self end,Stored=function()return {}end}
local currentProfile='Main'
TSM_API={GetActiveProfile=function()return currentProfile end,GetProfiles=function(out)out[1]='Main';out[2]='Other';end,SetActiveProfile=function(p)currentProfile=p end,ToItemString=function(s)return s end}
local tsm={LibTSMTypes={Include=function(_,key)return assert(sourceModules[key]) end},LibTSMUtil={Include=function(_,key) assert(key=='BaseType.TempTable');return {UnpackAndRelease=function(data)return table.unpack(data)end} end},UI={AuctionUI={IsScanning=function()return false end}},Auctioning={PostScan={Prepare=function()return 1 end,StatusQueryPublisher=function()return publisher end}},OnInitialize=function()end}
assert(loadfile(ADDON_ROOT..'/UBK_TSMBridge.lua'))('TradeSkillMaster',tsm)
local b=UBKTSMGroupBridge
assert(not b.ready,'Bridge initialized before TSM data')
tsm.OnInitialize()
for _,frame in ipairs(frames) do frame.OnEvent() end
assert(b.ready and prices.ubkbasis.kind=='volatile' and prices.ubksellbasis.kind=='volatile','Source registration or deferred readiness incorrect')
local config=b.CreateBucket()
assert(config.group=='zz - sell above basis (2)' and config.operation=='UBK - Sell Above Basis (2)','Existing names overwritten')
assert(groups.Crafts.Auctioning[1]=='OriginalPost' and groups.Crafts.Crafting[1]=='Craft' and ops['UBK - Sell Above Basis'].minPrice=='old','Existing groups/operations changed')
assert(#groups[config.group].Crafting==0 and groups[config.group].Crafting.override and #groups[config.group].Auctioning==1,'Temporary group inherited unrelated operations')
assert(b.ValidateBucket(config),'New operation failed validation')
assert(ops[config.operation].minPrice=='110% ubksellbasis' and ops[config.operation].normalPrice=='175% ubksellbasis' and ops[config.operation].maxPrice=='500% ubksellbasis' and ops[config.operation].postCap=='10' and ops[config.operation].stackSize=='1' and ops[config.operation].priceReset=='none','Requested pricing not configured')
ops[config.operation].minPrice='1c';assert(not b.ValidateBucket(config),'Edited session operation accepted');ops[config.operation].minPrice='110% ubksellbasis'
b.Move('i:1',config.group);assert(b.Path('i:1')==config.group);b.Move('i:1',false);assert(b.Path('i:1')==false,'Ungrouping did not use nil')
statusCallback({10,9,1,10});assert(b.postStatus.failed==1 and b.postStatus.total==10,'Posting callback lost queue values')
-- TSM-side recovery still works without the UBK addon/UI loaded.
UBKBasisSale=nil
items['i:1']=config.group
b.Journal().session={profile='Main',group=config.group,items={{item='i:1',original='Crafts',state='moved'}}}
currentProfile='Other';b.RecoverOnLogin()
assert(items['i:1']=='Crafts' and not b.Journal().session and currentProfile=='Other','Disabled-addon / other-profile recovery failed')
print('PASS: deferred bridge readiness, four sources, existing names and operations preserved, exact requested prices, unrelated inheritance removed only on new bucket, edited-operation rejection, exact nil ungrouping, queue callback, TSM-side recovery without UBK on another profile')
-- New draft integrations are narrow read/click adapters to TSM's loaded services.
local selectedLink;local page='Browse';local busy=false
TSM_API.GetItemLink=function(item)return '|Hitem:'..item:match('%d+')..':|hitem|h' end
tsm.Locale={GetTable=function()return {Browse='Browse'}end}
tsm.UI.AuctionUI.IsScanning=function()return busy end
tsm.UI.AuctionUI.IsVisible=function()return true end
tsm.UI.AuctionUI.IsPageOpen=function(name)return page==name end
tsm.UI.AuctionUI.Shopping={StartItemSearch=function(link)selectedLink=link end}
assert(b.BrowseItem('i:22861') and selectedLink:find('22861'))
selectedLink=nil;page='Auctioning';assert(not b.BrowseItem('i:22861') and selectedLink==nil,'Handoff went to Auctioning')
page='Browse';busy=true;assert(not b.BrowseItem('i:22861'));busy=false
local released=false;local filters={};local query={}
function query:Equal(k,v)filters[k]=v;return self end
function query:Select(...)self.fields={...};return self end
function query:Iterator()local done=false;return function()if done then return end;done=true;return 1,'i:23425',1,95,200,'Seller','Buyer',1000,'Auction' end end
function query:Release()released=true end
tsm.Accounting={Transactions={CreateQuery=function()return query end}}
local oldInclude=tsm.LibTSMUtil.Include
tsm.LibTSMUtil.Include=function(self,key)
 if key~='Format.CSV' then return oldInclude(self,key) end
 return {EncodeStart=function(keys)return {table.concat(keys,',')}end,EncodeAddRowDataRaw=function(out,...)out[#out+1]=table.concat({...},',')end,EncodeEnd=function(out)return table.concat(out,'\n')end}
end
local csv=b.GetBuyLedgerCSV()
assert(released and filters.type=='buy' and filters.isCurrentRealm==true and csv:find('i:23425,1,95,200,Seller,Buyer,1000,Auction',1,true),'Live purchases not read/released in saved CSV units')
print('PASS: checked TSM Browse adapter refuses Auctioning/busy state; live buy query scopes realm/type, preserves stack/quantity/unit price and releases query')
-- Pricing edits affect only the verified UBK operation; stacks stay exactly one.
UBKBasisSale={ValidateSettings=function(_,p)return p end}
assert(b.ConfigureBucket(config,{minPct=120,normalPct=190,maxPct=600,postCap=7}))
local settings=ops[config.operation]
assert(settings.minPrice=='120% ubksellbasis' and settings.normalPrice=='190% ubksellbasis' and settings.maxPrice=='600% ubksellbasis' and settings.postCap=='7' and settings.stackSize=='1' and settings.stackSizeIsCap==false and settings.matchStackSize==false)
settings.stackSize='2';assert(not b.ValidateBucket(config),'Stack size edit escaped validation');settings.stackSize='1'
settings.minPrice='1c';assert(not b.ConfigureBucket(config,{minPct=110,normalPct=175,maxPct=500,postCap=10}),'Externally edited operation overwritten')
assert(ops.OriginalPost.minPrice=='original','Original operation changed')
print('PASS: custom percentages and cap applied to owned operation only; exact singles and external-edit protection retained')
-- Ignore-list review is read-only; acceptance removes only displayed prospectable ores.
local ignored={['i:10620']={name='Thorium Ore',session=true},['i:23425']={name='Adamantite Ore'},['i:99999']={name='Ignored gear'}}
local ignoreReleased=0;local removals={}
tsm.Destroying={CreateIgnoreQuery=function()
 local q={};function q:Select(...)return self end
 function q:Iterator()local key;return function()key=next(ignored,key);if key then return key,key,ignored[key].name,ignored[key].session end end end
 function q:Release()ignoreReleased=ignoreReleased+1 end
 return q
end,ForgetIgnoreItemPermanent=function(item)assert(ignored[item]);removals[#removals+1]=item;ignored[item]=nil end}
local ores=b.GetIgnoredProspectingOres();assert(#ores==2 and #removals==0 and ignoreReleased==1)
local ok=b.RemoveIgnoredProspectingOres({'i:10620','i:99999'});assert(not ok and #removals==0,'Invalid request partly changed ignore list')
ignored['i:2770']={name='Copper Ore'} -- Added after the player saw the prompt.
local ok,msg=b.RemoveIgnoredProspectingOres({'i:10620','i:23425','i:10620'})
assert(ok and #removals==2 and ignored['i:99999'] and ignored['i:2770'] and msg:find('reload'),'Unlisted ignores changed or session skip hidden')
assert(b.RemoveIgnoredProspectingOres({'i:10620'}) and #removals==2,'Already removed entry failed or repeated')
print('PASS: ore-only ignore inspection, query release, full-request validation, snapshot-only/idempotent removal, other ignores preserved and session-skip guidance')
-- Once TSM has computed a queue price, a later prospect must also block the
-- final processing call; invalidating a price source alone is insufficient.
local postCalls=0
function tsm.Auctioning.PostScan.DoProcess(value) postCalls=postCalls+1;return 'original',value end
assert(b.InstallPendingPostGuard())
local oldSession=b.Journal().session
b.Journal().session={profile=b.Profile(),items={{item='i:12361',state='moved'}}}
UBKProspectingSessions={Pending=function(_,item)return item=='i:12361' end}
local result,noRetry=tsm.Auctioning.PostScan.DoProcess('token')
assert(result==false and noRetry==true and postCalls==0,'Previously prepared queue posted pending gems')
UBKProspectingSessions.Pending=function()return false end
result,noRetry=tsm.Auctioning.PostScan.DoProcess('token')
assert(result=='original' and noRetry=='token' and postCalls==1,'Clear session changed original posting arguments/results')
b.Journal().session=oldSession;UBKProspectingSessions=nil
print('PASS: final TSM post-processing guard stops already-prepared queues containing pending Sell Above Basis gems; ordinary post behavior/arguments preserved when clear')
