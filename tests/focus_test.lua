local function frame(parent)
 local f={parent=parent,strata="HIGH",visible=true,hooks={},children={}}
 if parent then parent.children[#parent.children+1]=f end
 function f:GetParent() return self.parent end
 function f:GetChildren() return table.unpack(self.children) end
 function f:GetFrameStrata() return self.strata end
 function f:SetFrameStrata(v) self.strata=v end
 function f:Raise() self.raised=true end
 function f:SetToplevel() end
 function f:HookScript(name,fn) self.hooks[name]=fn end
 function f:IsShown() return self.visible and (not self.parent or self.parent:IsShown()) end
 function f:Hide() self.visible=false end
 function f:RegisterEvent() end
 function f:SetScript() end
 return f
end
UIParent=frame(); WorldFrame=frame();function CreateFrame() return frame() end
function InCombatLockdown() return false end
dofile(ADDON_ROOT.."/UBK_WindowFocus.lua")
local Focus=UBKWindowFocus
local main=frame(UIParent);local child=frame(main);local nested=frame(main);local nestedButton=frame(nested)
local sources=frame(UIParent);local sourceCell=frame(sources)
Focus.Register(main);Focus.Register(nested);Focus.Register(sources)
Focus.Raise(sourceCell)
assert(sources.strata=="HIGH" and main.strata=="MEDIUM" and nested.strata=="MEDIUM","Sources did not come to front")
Focus.Raise(child)
assert(main.strata=="HIGH" and sources.strata=="MEDIUM" and Focus.IsSelected(main),"Main could not trade focus")
Focus.Raise(nestedButton)
assert(nested.strata=="HIGH" and main.strata=="MEDIUM","Nearest registered dialog was grouped with main")
main:Hide();assert(sources:IsShown(),"Closing main closed independent Sources")
local tsm=frame(UIParent);tsm.strata="HIGH";local tsmControl=frame(tsm)
Focus.SelectExternal(tsmControl)
assert(sources.strata=="MEDIUM" and not Focus.IsSelected(sources),"TSM selection did not lower UBK")
print("PASS: Sources and main trade focus, nested dialog independently raised, Sources survives main close, external TSM click lowers UBK")
