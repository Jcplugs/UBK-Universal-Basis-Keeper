local f=assert(io.open(ADDON_ROOT..'/UniversalBasisKeeper.lua'))
local source=f:read('*a');f:close()
UBKProspectAccounting={}
assert(load(source:match('(function _G%.UBKProspectAccounting%.Observe%(item%).-\nend)')))()
for _,available in ipairs({true,false}) do
 for _,qty in ipairs({4,0,-3,'10','invalid'}) do
  GetRealmQuantityForItem=function()return qty,available end
  assert(UBKProspectAccounting.Observe('i:12364')==math.max(0,tonumber(qty) or 0))
 end
 GetRealmQuantityForItem=function()return nil,available end
 assert(UBKProspectAccounting.Observe('i:12364')==0)
end
print('PASS: production prospect observer accepts quantity plus true/false availability; numeric strings, nil, invalid and negative quantities remain bounded')
