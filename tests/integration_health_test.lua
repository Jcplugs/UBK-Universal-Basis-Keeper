local function run(bridge,lateReady)
 local queue,chat,sounds={}, {}, 0
 local callback
 UBKTSMGroupBridge=bridge
 C_Timer={After=function(_,fn)queue[#queue+1]=fn end}
 CreateFrame=function()return {RegisterEvent=function(_,event)assert(event=="PLAYER_LOGIN")end,SetScript=function(_,_,fn)callback=fn end}end
 SOUNDKIT={RAID_WARNING=12345}
 PlaySound=function(id,channel)assert(id==12345 and channel=="Master");sounds=sounds+1 end
 local oldPrint=print;print=function(text)chat[#chat+1]=text end
 dofile(ADDON_ROOT.."/UBK_IntegrationHealth.lua")
 callback();callback()
 local steps=0
 while #queue>0 do
  steps=steps+1;assert(steps<=15)
  if lateReady and steps==10 then UBKTSMGroupBridge={ready=true,sourcesRegistered=true} end
  table.remove(queue,1)()
 end
 callback();assert(#queue==0)
 print=oldPrint
 return chat,sounds,steps
end
local chat,sounds,steps=run(nil)
assert(#chat==1 and sounds==1 and steps==15)
assert(chat[1]:find("UBK Loaded Incorrectly, TSM-UBK integration failure. Please run installer again to patch.",1,true))
chat,sounds=run({ready=true,sourcesRegistered=true});assert(#chat==0 and sounds==0)
chat,sounds=run({ready=false,sourcesRegistered=false},true);assert(#chat==0 and sounds==0)
chat,sounds=run({ready=true,sourcesRegistered=false});assert(#chat==1 and sounds==1)
print("PASS: missing/incomplete integration warns once with raid sound; healthy and delayed initialization stay quiet; startup checks bounded")
