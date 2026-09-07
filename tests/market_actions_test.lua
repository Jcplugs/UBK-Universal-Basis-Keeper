local api={};UniversalBasisKeeperAPI=api
local scanning=false;local auction=true
function api:GetShredderState()return {liveScanning=scanning}end
function api:IsAuctionVisible()return auction end
local selected
UBKTSMGroupBridge={ready=true,BrowseItem=function(item)selected=item;return true end}
assert(loadfile(ADDON_ROOT..'/UBK_MarketActions.lua'))()
assert(api:BrowseMarketItem('i:22861') and selected=='i:22861')
selected=nil;scanning=true;assert(not api:BrowseMarketItem('i:22861') and not selected)
scanning=false;auction=false;assert(not api:BrowseMarketItem('i:22861') and not selected)
local bags={};NUM_BAG_SLOTS=4
C_Container={GetContainerNumSlots=function(bag)return #(bags[bag] or {})end,GetContainerItemInfo=function(bag,slot)return bags[bag][slot]end}
local command;SlashCmdList={TSM=function(cmd)command=cmd end}
function InCombatLockdown()return false end
bags[0]={{itemID=23425,stackCount=5}};assert(#api:GetBagProspectableOres()==0 and not api:OpenTSMDestroying())
bags[1]={{itemID=23425,stackCount=1}};assert(#api:GetBagProspectableOres()==1 and api:OpenTSMDestroying() and command=='destroy')
bags[0]={{itemID=23425,stackCount=3}};bags[1]={{itemID=23424,stackCount=3}};assert(#api:GetBagProspectableOres()==0,'Different ore types combined')
bags[0]={{itemID=23426,stackCount=100}};bags[1]={};assert(#api:GetBagProspectableOres()==0,'Nonprospectable ore enabled destroying')
bags[-1]={{itemID=23425,stackCount=100}};assert(#api:GetBagProspectableOres()==0,'Bank stock enabled destroying')
bags[0]={{itemID=23425,stackCount=6}};InCombatLockdown=function()return true end;command=nil;assert(not api:OpenTSMDestroying() and not command)
print('PASS: current-item TSM handoff, scan/closed-AH guards, >5 same-ore bag threshold across stacks, no bank/nonprospectable ore, exact destroy command, combat guard')
