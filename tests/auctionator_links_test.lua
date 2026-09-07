local shifted,control,alt,active=true,false,false,false
local originalCalls,inserted,opened=0,0,0
function GetBuildInfo()return 'x',nil,nil,20506 end
function IsShiftKeyDown()return shifted end
function IsControlKeyDown()return control end
function IsAltKeyDown()return alt end
function ChatEdit_GetActiveWindow()return active and {} or nil end
function ChatEdit_InsertLink(link)assert(link:find('|Hitem:',1,true));inserted=inserted+1;return true end
function ChatFrame_OpenChat(link)assert(link:find('|Hitem:',1,true));opened=opened+1 end
C_Timer={After=function(_,fn)fn()end}
function CreateFrame()return {RegisterEvent=function()end,SetScript=function()end}end
local original=function(self,button,token)originalCalls=originalCalls+1;return button,token end
AuctionatorShoppingResultsRowMixin={OnClick=original}
local existing={OnClick=original,rowData={itemLink='|Hitem:23440|h[Dawnstone]|h'},script=original}
function existing:GetScript()return self.script end
function existing:SetScript(_,v)self.script=v end
local unrelated={OnClick=function()end}
function EnumerateFrames(f)if not f then return existing elseif f==existing then return unrelated end end
local oldOther=unrelated.OnClick
dofile(ADDON_ROOT..'/UBK_AuctionatorLinks.lua');assert(UBKAuctionatorLinks.Install())
existing:OnClick('LeftButton');assert(opened==1 and originalCalls==0 and inserted==0)
active=true;existing:OnClick('LeftButton');assert(inserted==1 and opened==1 and originalCalls==0)
control=true;local a,b=existing:OnClick('LeftButton','retained');assert(a=='LeftButton' and b=='retained' and originalCalls==1)
control=false;existing:OnClick('RightButton');assert(originalCalls==2)
shifted=false;existing:OnClick('LeftButton');assert(originalCalls==3)
assert(unrelated.OnClick==oldOther and existing.script==existing.OnClick)
assert(UBKAuctionatorLinks.Install());assert(originalCalls==3,'Repeat install recursed')
local f=assert(io.open(ADDON_ROOT..'/UBK_Interface.lua'));local s=f:read('*a');f:close()
local i=assert(s:find('local function MarketLinkCaptureActive()',1,true));local j=assert(s:find('local function CaptureMarketItemLink',i,true))
UI={root={IsShown=function()return true end},page='market',marketEditBox={HasFocus=function()return true end}}
assert(load(s:sub(i,j-1)..'\nTEST_CAPTURE_ACTIVE=MarketLinkCaptureActive'))()
assert(not TEST_CAPTURE_ACTIVE(),'Inspector consumed open chat link')
active=false;assert(TEST_CAPTURE_ACTIVE(),'Deliberate Inspector capture was lost')
print('PASS: Auctionator Shift-left links to active/new chat drafts without sending; Ctrl+Shift/search and normal/right clicks retain original behavior; existing/future rows patched, other frames untouched, idempotent install; chat priority over Inspector')
