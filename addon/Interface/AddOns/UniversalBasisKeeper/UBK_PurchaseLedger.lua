-- Quantity checkpoints survive TSM combining repeated buys into a growing row.
_G.UBKPurchaseLedger={}
local P=_G.UBKPurchaseLedger
function P.Key(line)
    local item,stack,_,price,seller,buyer,stamp,source=strsplit(",",line)
    if not source then return nil end
    return table.concat({item,stack,price,seller,buyer,stamp,source},"\031")
end
function P.Prepare(db)
    if type(db.processedPurchaseQty)=="table" then return end
    local units={}
    for line,count in pairs(db.processedCounts or {}) do
        local key=P.Key(line);local _,_,qty=strsplit(",",line);qty=tonumber(qty)
        if key and qty and qty>0 and tonumber(count) and count>0 then units[key]=(units[key] or 0)+qty*count end
    end
    db.processedPurchaseQty=units
end
function P.Take(db,seen,line,qty)
    local key=P.Key(line)
    if not key then return 0 end
    seen[key]=(seen[key] or 0)+qty
    local previous=tonumber(db.processedPurchaseQty[key]) or 0
    return math.min(qty,math.max(0,seen[key]-previous)),key,seen[key]
end

-- Read-only preparation: yield while examining old history, then commit only
-- unseen purchase quantities in the existing, non-yielding accounting pass.
function P.PrepareBatch(csv,db,parse,characters,cutover,schedule,done)
    P.Prepare(db)
    local nextLine=(csv or ''):gmatch('[^\r\n]+')
    local counts,units,rows={},{},{}
    local maxTime=tonumber(db.lastLedgerTime) or tonumber(db.cutoffTime) or cutover
    local function Step()
        local n=0
        while n<300 do
            local line=nextLine()
            if not line then done({rows=rows,maxSeenTime=maxTime,db=db});return end
            n=n+1
            local item,qty,price,stamp,buyer,seller,source=parse(line)
            local state=item and db.items[item]
            local cutoff=state and (tonumber(state.cutoffTime) or tonumber(db.cutoffTime) or cutover)
            if item and characters[buyer or ''] and (not state or stamp>cutoff) then
                local key=P.Key(line)
                if key then
                    counts[line]=(counts[line] or 0)+1
                    units[key]=(units[key] or 0)+qty
                    if units[key]>(tonumber(db.processedPurchaseQty[key]) or 0) then
                        rows[#rows+1]={line,item,qty,price,stamp,buyer,seller,source,counts[line],units[key],key}
                    end
                    maxTime=math.max(maxTime,stamp)
                end
            end
        end
        schedule(Step)
    end
    schedule(Step)
end
function P.Iterate(csv,prepared,parse)
    if prepared then
        local index=0
        return function()
            index=index+1;local row=prepared.rows[index]
            if row then return (unpack or table.unpack)(row) end
        end
    end
    local nextLine=(csv or ''):gmatch('[^\r\n]+')
    return function()
        local line=nextLine()
        if line then return line,parse(line) end
    end
end

-- A scan shares one lookup, rather than exporting/parsing all history for
-- every invoice. Keep identical-row multiplicity and existing claim counters.
function P.InvoiceIndex(csv,parse,lower,now,buyer)
    local buckets,byLine={},{}
    for line in (csv or ''):gmatch('[^\r\n]+') do
        local item,qty,price,stamp,who,seller,source=parse(line)
        if item and source=='Auction' and (not buyer or who==buyer) and stamp>=lower and stamp<=now+120 then
            local row=byLine[line]
            if row then row.count=row.count+1
            else
                row={line=line,qty=qty,price=price,stamp=stamp,seller=seller,count=1}
                byLine[line]=row
                local key=item..'\031'..qty..'\031'..math.floor(price)
                buckets[key]=buckets[key] or {};table.insert(buckets[key],row)
            end
        end
    end
    return buckets
end
function P.FindInvoice(index,claims,info)
    local best
    local expected=tonumber(info.expectedPurchaseAt) or 0
    local price=tonumber(info.unitPrice) or 0
    for rounded=math.floor(price)-1,math.floor(price)+1 do
        local key=info.itemString..'\031'..info.qty..'\031'..rounded
        for _,row in ipairs(index[key] or {}) do
            if row.count>(tonumber(claims[row.line]) or 0)
                and math.abs(row.price-price)<=1
                and (expected<=0 or math.abs(row.stamp-expected)<=300)
                and (not row.seller or row.seller=='' or not info.seller or info.seller=='' or row.seller==info.seller)
                and (not best or row.stamp>best.timestamp) then
                best={line=row.line,occurrence=(tonumber(claims[row.line]) or 0)+1,timestamp=row.stamp}
            end
        end
    end
    return best
end

-- Transaction windows are capture-only. The small persistent marker survives
-- a normal logout; receipt lots and TSM's ledger retain the actual evidence.
P.windows={}
P.generation=0
P.sourceEvents={
    AUCTION_HOUSE_SHOW={"Auction House",true}, AUCTION_HOUSE_CLOSED={"Auction House",false},
    MAIL_SHOW={"Mailbox",true}, MAIL_CLOSED={"Mailbox",false},
    TRADE_SHOW={"Trade",true}, TRADE_CLOSED={"Trade",false},
    MERCHANT_SHOW={"Vendor",true}, MERCHANT_CLOSED={"Vendor",false},
    LOOT_OPENED={"Loot",true}, LOOT_CLOSED={"Loot",false},
}
function P.AnySourceOpen() return next(P.windows)~=nil end
function P.SourceEvent(event,db,now)
    local e=P.sourceEvents[event]
    if not e then return nil end
    P.generation=P.generation+1
    P.windows[e[1]]=e[2] and true or nil
    db.accountingCapture=db.accountingCapture or {sources={}}
    local capture=db.accountingCapture
    capture.sources=capture.sources or {}
    capture.sources[e[1]]=true
    capture.pending=true
    capture.lastEventAt=now
    return e[2] and "open" or "close"
end
function P.Status(db)
    if P.AnySourceOpen() then
        local names={};for name in pairs(P.windows) do names[#names+1]=name end;table.sort(names)
        return "Recording evidence: "..table.concat(names,", ")..". Basis settles after transaction windows close."
    end
    if P.settlementPending or (db and db.accountingCapture and db.accountingCapture.pending) then
        return "Accounting settlement pending. Showing the last settled basis."
    end
end

-- Anniversary uses the interaction manager to close services. Keep legacy
-- close events too; do not infer closure from a hidden Blizzard replacement UI.
P.interactionCloses={MailInfo="MAIL_CLOSED",Auctioneer="AUCTION_HOUSE_CLOSED",Merchant="MERCHANT_CLOSED",TradePartner="TRADE_CLOSED"}
function P.NormalizeEvent(event,interaction,types)
    if event~="PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then return event end
    if interaction==nil or type(types)~="table" then return nil end
    for name,closed in pairs(P.interactionCloses) do
        if types[name]~=nil and interaction==types[name] then return closed end
    end
end
