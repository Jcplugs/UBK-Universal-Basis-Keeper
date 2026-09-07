-- Item treatment rules: vendor trash is not an acquisition-cost question.
_G.UBKItemRules = {}
function _G.UBKItemRules.VendorTrash(itemArg)
    local id=type(itemArg)=="number" and itemArg or (type(itemArg)=="string" and (itemArg:match("^i:(%d+)") or itemArg:match("item:(%d+)") or itemArg:match("^%d+$")))
    id=tonumber(id)
    if not id or type(GetItemInfo)~="function" then return false,nil end
    local name,_,quality,_,_,_,_,_,_,_,sell=GetItemInfo(id)
    if not name or quality~=0 then return false,nil end
    return true,type(sell)=="number" and sell>=0 and sell<math.huge and sell or nil
end

-- Keep names plain for sorting; use WoW's current quality only when drawing.
function _G.UBKItemRules.QualityColor(itemArg)
    local id=type(itemArg)=="number" and itemArg or (type(itemArg)=="string" and (itemArg:match("^i:(%d+)") or itemArg:match("item:(%d+)") or itemArg:match("^%d+$")))
    if type(GetItemInfo)~="function" or not tonumber(id) then return .65,.65,.65 end
    local name,_,quality=GetItemInfo(tonumber(id))
    local color=name and type(ITEM_QUALITY_COLORS)=="table" and ITEM_QUALITY_COLORS[quality]
    if color then return color.r,color.g,color.b end
    return .65,.65,.65
end
