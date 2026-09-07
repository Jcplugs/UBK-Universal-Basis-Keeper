local frameEvents={}
function CreateFrame() local f={}; function f:RegisterEvent() end; function f:SetScript(name,fn) self[name]=fn end; frameEvents[#frameEvents+1]=f; return f end
C_Timer={After=function(_,fn) fn() end}
function InCombatLockdown() return false end
function time() return 100 end
function UnitName() return "BankTest" end
local profile="Main"
local groups={Main={Crafts=true,Resale=true,Elsewhere=true},AltProfile={Other=true}}
local paths={Main={["i:1"]="Crafts",["i:2"]="Resale"},AltProfile={}}
local journal={schema=1,profiles={}}
local failMove
local b={ready=true,postStatus={},postSerial=0}
_G.UBKTSMGroupBridge=b
function b.Profile() return profile end
function b.Profiles() return {"Main","AltProfile"} end
function b.SetProfile(p) profile=p end
function b.Journal() return journal end
function b.IsBusy() return false end
function b.Exists(path) return path==false or groups[profile][path] end
function b.Path(item) return paths[profile][item] or false end
function b.Move(item,path)
 paths[profile][item]=path or nil
 if failMove==item then failMove=nil; error("Injected failure AFTER assignment") end
end
function b.Invalidate() end
function b.CreateBucket() groups[profile].Bucket=true; return {group="Bucket",operation="SessionOp"} end
function b.ValidateBucket() return true end
function b.BagItems()
 return {{itemString="i:1",name="Alpha",qty=12,original=b.Path("i:1")},{itemString="i:2",name="Beta",qty=4,original=b.Path("i:2")},{itemString="i:3",name="Uncosted",qty=1,original=false},{itemString="i:4",name="Ungrouped",qty=1,original=false}}
end
function b.Repath(path,old,new) return path==old and new or path end
TSM_API={GetGroupItems=function(group,_,out) for item,path in pairs(paths[profile]) do if path==group then out[#out+1]=item end end end}
UniversalBasisKeeperAPI={GetAcquisitionCost=function(_,item) return item~="i:3" and 50000 or nil end,GetRecipeBasisCost=function() end}
UBKItemRules={VendorTrash=function() return false end}
dofile(ADDON_ROOT.."/UBK_BasisSale.lua")
local Sale=UBKBasisSale
local function check(ok,msg) assert(ok,msg) end
local function begin(items) local ok,s=Sale:Begin(items or {["i:1"]=true,["i:2"]=true}); check(ok,s); return s end
local session=begin()
check(paths.Main["i:1"]=="Bucket" and paths.Main["i:2"]=="Bucket","Move failed")
check(session.items[1].original=="Crafts" and session.items[2].original=="Resale","Original groups not captured")
check(Sale:GetSaleBasis("i:1")==50000 and Sale:GetSaleBasis("i:3")==nil,"Snapshot source failed closed")
check(not Sale:Begin({["i:4"]=true}),"Nested session allowed")
local ok,msg=Sale:Restore("test");check(ok,msg)
check(paths.Main["i:1"]=="Crafts" and paths.Main["i:2"]=="Resale" and not journal.session,"Original groups not restored")
check(Sale:GetSaleBasis("i:1")==nil,"Session price leaked after restoration")
begin({["i:4"]=true}); check(Sale:Restore("ungrouped")); check(not paths.Main["i:4"],"Ungrouped item got a fabricated return group")
failMove="i:2"
ok,msg=Sale:Begin({["i:1"]=true,["i:2"]=true});check(not ok,"Injected failure ignored")
check(paths.Main["i:1"]=="Crafts" and paths.Main["i:2"]=="Resale" and not journal.session,"Partial move was not reversed")
session=begin(); paths.Main["i:1"]="Elsewhere"
ok=Sale:Restore("conflict");check(not ok and journal.session and paths.Main["i:1"]=="Elsewhere","External move overwritten")
check(paths.Main["i:2"]=="Resale","Nonconflicting item not returned")
paths.Main["i:1"]="Crafts";check(Sale:Restore("resolved")); check(not journal.session,"Corrected conflict not cleared")
session=begin({["i:1"]=true});groups.Main.Crafts=nil
check(not Sale:Restore("deleted origin") and journal.session,"Deleted original group silently recreated")
groups.Main.Crafts=true;check(Sale:Restore("recovered origin"))
session=begin();profile="AltProfile";ok,msg=Sale:Restore("other toon profile");check(ok,msg)
check(profile=="AltProfile" and paths.Main["i:1"]=="Crafts" and paths.Main["i:2"]=="Resale","Cross-profile recovery failed")
profile="Main";session=begin({["i:1"]=true}); groups.Main.NewCrafts=true;groups.Main.Crafts=nil;Sale:GroupRenamed("Crafts","NewCrafts")
check(Sale:Restore("renamed origin") and paths.Main["i:1"]=="NewCrafts","Group rename was not followed")
session=begin({["i:1"]=true});_G.UBKBasisSaleJournal=journal
-- Simulate reloading the addon and firing PLAYER_LOGIN with a persisted journal.
dofile(ADDON_ROOT.."/UBK_BasisSale.lua");frameEvents[#frameEvents].OnEvent(nil,"PLAYER_LOGIN")
check(not journal.session and paths.Main["i:1"]=="NewCrafts","Next-login recovery failed")
Sale=UBKBasisSale
local count=0; Sale.ShowReturnPrompt=function() count=count+1 end
session=begin({["i:1"]=true});Sale:PostScanStarted(7);b.postStatus={total=10,confirmed=4,failed=0}
Sale:CheckCompletion();check(count==0,"Prompt interrupted pending Post/Skip choices")
b.postStatus.confirmed=10;Sale:CheckCompletion();Sale:CheckCompletion();check(count==1,"Completion prompt was missed or repeated")
check(Sale:Restore("done"))
ok,msg=Sale:Begin({["i:3"]=true});check(not ok and not journal.session,"Missing basis allowed")
print("PASS: selection, full pre-move journal, captured prices, no nested session, original/ungrouped return, rollback after a setter writes then fails, external move conflict, deleted and renamed origins, cross-profile recovery, login recovery, completion prompt waits for Post/Skip, missing-cost rejection")
-- User posting settings must validate before any group move.
Sale=UBKBasisSale
if Sale:HasPending() then assert(Sale:Restore('custom settings fixture')) end
local p,e=Sale:ValidateSettings({minPct='120',normalPct='190',maxPct='600',postCap='7'})
assert(p and p.postCap==7 and p.normalPct==190)
assert(not Sale:ValidateSettings({minPct=200,normalPct=150,maxPct=500,postCap=10}))
assert(not Sale:ValidateSettings({minPct=110,normalPct=175,maxPct=500,postCap=1.5}))
assert(not Sale:ValidateSettings({minPct=0,normalPct=175,maxPct=500,postCap=10}))
local configured
function b.ConfigureBucket(config,options)configured=options;return true end
local ok,session=Sale:Begin({['i:1']=true,['i:2']=true},p);assert(ok,session)
assert(session.pricing.postCap==7 and configured.maxPct==600 and session.items[1].postQuantity==7 and session.items[2].postQuantity==4,'Custom prices/count or available-bag cap lost')
assert(Sale:Restore('custom settings return'))
print('PASS: ordered positive posting percentages, whole single-item cap, session snapshot, bag-limited preview and original-group return with custom settings')
-- A pending prospect blocks existing positive acquisition AND recipe costs.
local prospectBlocked=true
b.pendingPostGuard=true
UBKProspectingSessions={Pending=function(_,item)return prospectBlocked and item=='i:1' end,Reason=function()return 'Reload to settle prospecting basis' end}
local staleSelection={['i:1']=true}
assert(Sale:Cost('i:1')==nil,'Pending gem fell back to a known acquisition / recipe cost')
local rows=Sale:BagRows();local lookup={};for _,r in ipairs(rows)do lookup[r.itemString]=r end
assert(not lookup['i:1'].selectable and lookup['i:1'].reason=='Reload to settle prospecting basis')
dofile(ADDON_ROOT..'/UBK_TableUI.lua')
local selected=UBKTableUI.SelectEligible(rows);assert(not selected['i:1'],'Select All included a pending gem')
assert(not Sale:Begin(staleSelection) and not journal.session,'Stale checkbox moved a pending gem')
prospectBlocked=false;begin(staleSelection);assert(Sale:GetSaleBasis('i:1')==50000)
prospectBlocked=true;assert(Sale:GetSaleBasis('i:1')==nil,'Already-active session leaked its cached basis after new prospecting')
assert(Sale:Restore('pending-output test'));UBKProspectingSessions=nil
print('PASS: pending output exclusion from price fallback, rows, bulk selection, stale confirmation and already-active session source; return journal remains usable')
