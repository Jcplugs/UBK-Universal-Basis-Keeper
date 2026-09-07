assert(loadfile(ADDON_ROOT..'/UBK_TableUI.lua'))()
local T=UBKTableUI
assert(T.NameMatches('|cff00ff00Iron Ore|r',' IRON ') and T.NameMatches('Flask of Blinding Light','blinding'))
assert(not T.NameMatches('Iron Ore','.*') and not T.NameMatches('Tin Ore','iron'),'Search interpreted patterns or wrong name')
local rows={}
for i=1,200 do rows[#rows+1]={itemString='i:'..i,name=i==190 and 'Iron Ore' or 'Other',basis=i*10000,selectable=i~=191,profession='Mining',professions={Mining=true},quality=1,itemType='Ore'}end
local found=T.FilterRows(rows,{search='iron',profession='Mining',itemType='Ore',quality='1'})
assert(#found==1 and found[1].itemString=='i:190','Search restricted to first page')
assert(#T.FilterRows(rows,{search='iron',profession='Alchemy'})==0,'Search ignored category filters')
local low,high,err=T.BasisRange('190','192');assert(not err)
local selected,count=T.SelectEligible(T.RangeRows(rows,low,high));assert(count==2 and selected['i:190'] and selected['i:192'] and not selected['i:191'],'Range/eligibility or inclusive endpoints failed')
selected,count=T.SelectEligible(rows);assert(count==199 and selected['i:200'],'Select All stopped at visible page')
low,high,err=T.BasisRange('200','100');assert(err)
low,high,err=T.BasisRange('bad','');assert(err)
low,high,err=T.BasisRange('','10.50');assert(not low and high==105000 and not err)
assert(#T.RangeRows({{basis=nil}},100,nil)==0,'Unknown basis passed monetary bounds')
print('PASS: case-insensitive literal search across 200 rows, combined filters, inclusive gold boundaries, invalid ranges, all-page selection and unavailable-item exclusions')
