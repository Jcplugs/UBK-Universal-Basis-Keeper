-- Refresh our own lines without rebuilding the bag/mail tooltip or adding copies.
_G.UBKLiveTooltip={}
function _G.UBKLiveTooltip.Render(tip,state,item,basisOf,money)
    if _G.UBKLiveTooltip.Suppress and _G.UBKLiveTooltip.Suppress(tip) then return end
    if not tip.GetName or not tip.NumLines then return end
    local name=tip:GetName();if not name then return end
    local live=tip.__ubkLiveBasis
    if not live or live.item~=item then live={item=item,lines={},texts={}};tip.__ubkLiveBasis=live end
    local function Line(key,text,r,g,b)
        if live.texts[key]==text then return end
        if not live.lines[key] and text~="" then
            tip:AddLine(text,r,g,b);live.lines[key]=tip:NumLines()
        end
        local font=live.lines[key] and _G[name.."TextLeft"..live.lines[key]]
        if font then font:SetText(text);font:SetTextColor(r,g,b) end
        live.texts[key]=text
    end
    local known=state and (tonumber(state.qty) or 0) or 0
    local unresolved=state and (tonumber(state.bootstrapUnresolved) or 0) or 0
    local basis=state and basisOf(state) or 0
    local main
    if known>0 and basis>0 then main="UBK Basis: "..money(basis).."  |  known "..known
    elseif unresolved>0 then main="UBK Basis: unresolved ("..unresolved.." owned units)"
    elseif basis>0 then main="UBK last historical basis: "..money(basis).." (no known-cost stock)"
    else main="UBK Basis: no recorded acquisition cost" end
    Line("basis",main,.25,1,.55)
    Line("unknown",known>0 and unresolved>0 and ("UBK unresolved inventory: "..unresolved) or "",1,.65,.2)
    Line("mailbox",(_G.UBKInternal and _G.UBKInternal.AccountingStatus and _G.UBKInternal.AccountingStatus()) or "",1,.65,.2)
    Line("purchaseIntegration",_G.UBKPurchaseLedger and _G.UBKPurchaseLedger.liveUnavailable and "UBK live purchases: update UBK’s TSM Integration" or "",1,.45,.2)
    local prospect=_G.UBKProspectingSessions
    local reason=prospect and prospect:Reason(item)
    Line("prospecting",reason and ("UBK Prospecting: "..reason) or "",1,.65,.2)
    local loot=state and (tonumber(state.lootImputedQty) or 0) or 0
    Line("loot",loot>0 and ("UBK farmed/looted: "..loot.." units @ 95% imputed basis") or "",.55,.85,1)
end

-- Per-account preference. Hiding other addons' visible tooltips does not
-- guarantee they skip their own builders; UBK skips its own work before rendering.
function _G.UBKLiveTooltip.SetMailbox(open,muted)
    local live=_G.UBKLiveTooltip
    live.mailboxOpen=open==true;live.mailboxMuted=muted==true
    for _,name in ipairs({'GameTooltip','ItemRefTooltip','ShoppingTooltip1','ShoppingTooltip2'}) do
        local tip=_G[name]
        if tip and tip.HookScript and not tip.__ubkMailboxHook then
            tip.__ubkMailboxHook=true
            tip:HookScript('OnShow',function(t)
                if live.mailboxOpen and live.mailboxMuted then t:Hide() end
            end)
        end
        if tip and tip.Hide and live.mailboxOpen and live.mailboxMuted then tip:Hide() end
    end
end
function _G.UBKLiveTooltip.Suppress(tip)
    if _G.UBKLiveTooltip.mailboxOpen and _G.UBKLiveTooltip.mailboxMuted then
        if tip and tip.Hide then tip:Hide() end
        return true
    end
    return false
end
