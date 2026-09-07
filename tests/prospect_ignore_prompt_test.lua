local function Frame()
 local f={scripts={}}
 local no=function()end
 for _,k in ipairs({'SetSize','SetPoint','EnableMouse','SetMovable','RegisterForDrag','SetBackdrop','SetWidth','SetJustifyH','StartMoving','StopMovingOrSizing'})do f[k]=no end
 function f:SetText(t)self.text=t end
 function f:SetScript(k,fn)self.scripts[k]=fn end
 function f:CreateFontString()return Frame()end
 function f:Show()self.visible=true end
 function f:Hide()self.visible=false end
 return f
end
function CreateFrame()return Frame()end
UISpecialFrames={}
local removed,continued=0,0
local api={GetIgnoredProspectingOres=function()return {{itemString='i:10620',name='Thorium Ore'},{itemString='i:23425',name='Adamantite Ore'}}end,
RemoveIgnoredProspectingOres=function(_,items)assert(#items==2 and items[1]=='i:10620' and items[2]=='i:23425');removed=removed+1;return true,'Removed' end}
local ctx={API=api,UI={},RenderPage=function()end}
assert(loadfile(ADDON_ROOT..'/UBK_ProspectingUI.lua'))()
UBKProspectingUI.ShowIgnorePrompt(ctx,function()continued=continued+1 end)
local f=UBKProspectingUI.ignorePrompt;assert(removed==0 and continued==0 and f.visible,'Opening review mutated ignores')
f.scripts={} -- frame-level escape/close never accepts the action
f.keep.scripts.OnClick();assert(removed==0 and continued==1 and not f.visible,'Keep ignored changed settings')
UBKProspectingUI.ShowIgnorePrompt(ctx);assert(removed==0)
f.remove.scripts.OnClick();assert(removed==1 and not f.visible and ctx.UI.prospectingError=='Removed')
print('PASS: ignore prompt lists exact ores, opening/declining does not mutate, explicit acceptance calls removal, optional Destroying continuation remains separate')
