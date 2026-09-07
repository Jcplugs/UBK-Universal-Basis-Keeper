-- UBK interface actions. Loaded after the core; never changes acquisition lots,
-- quantities, pool value, or the native material-cost calculation.
local API = _G.UniversalBasisKeeperAPI
if type(API) ~= "table" then return end

local SOURCE = "ubkmatcost"
local PURCHASE_SOURCE = "first(avgbuy,vendorbuy)"
local ownershipFields = {"protectedFormula", "protectedFormulaValue", "formulaOverride",
    "formulaOverrideAt", "formulaOverrideBy", "costProvenance", "userCostClassification"}
local acquisitionCache = {}

local function Now()
    return type(time) == "function" and time() or 0
end

local function Positive(value)
    return type(value) == "number" and value > 0 and value == value and value < math.huge
end

local function ItemKey(itemArg)
    -- Accounting can retain a legacy item suffix even for a plain reagent.
    -- The native material API and watchlist use its base item ID.
    local direct = type(itemArg) == "string" and (itemArg:match("^i:(%d+):") or itemArg:match("^i:(%d+)$"))
    local value = direct and "i:" .. direct or API:ResolveItem(itemArg)
    local id = type(value) == "string" and tonumber(value:match("^i:(%d+)$")) or nil
    return id and id > 0 and "i:" .. tostring(id) or nil
end

local function Scope()
    local context = API:GetRuntimeContext()
    local root = _G.UniversalBasisKeeperDB
    local db = type(root) == "table" and type(root.realms) == "table"
        and type(context) == "table" and root.realms[context.realmKey] or nil
    return db, context
end

local function Material(itemArg)
    local itemString = ItemKey(itemArg)
    local db, context = Scope()
    if not itemString or type(db) ~= "table" or type(db.items) ~= "table" then
        return nil, "UBK has no tracked material state for that item."
    end
    if context.supported == false or (type(db.setup) == "table" and db.setup.status ~= "complete") then
        return nil, "Finish UBK setup in this realm and faction before changing cost ownership."
    end
    local state = db.items[itemString]
    if type(state) ~= "table" then return nil, "That item is not tracked by UBK." end
    if type(_G.UBK_GetTSMMatsTable) ~= "function" then return nil, "The UBK material bridge is unavailable." end
    local mats, err = _G.UBK_GetTSMMatsTable()
    local entry = type(mats) == "table" and mats[itemString] or nil
    if type(entry) ~= "table" then return nil, err or "TSM has no material entry for this item." end
    return {itemString=itemString, db=db, state=state, entry=entry}
end

local function WriteState(db)
    db.tsmWrite = type(db.tsmWrite) == "table" and db.tsmWrite or {}
    local write = db.tsmWrite
    for _, key in ipairs({"backups", "lastWritten", "pausedItems", "basisOwnershipHistory"}) do
        write[key] = type(write[key]) == "table" and write[key] or {}
    end
    return write
end

local function Native(value)
    return type(value) == "string" and value:lower():gsub("%s", "") == SOURCE
end

local function ValidSource(source)
    local tsm = _G.TSM_API
    if type(tsm) ~= "table" or type(tsm.IsCustomPriceValid) ~= "function" then return false end
    local ok, valid = pcall(tsm.IsCustomPriceValid, source)
    return ok and valid and true or false
end

local function RegisteredNative(source)
    if not ValidSource(source) then return false end
    local tsm = _G.TSM_API
    if type(tsm.GetPriceSourceKeys) ~= "function" then return false end
    local keys = {}
    local ok = pcall(tsm.GetPriceSourceKeys, keys)
    if not ok then return false end
    for _, key in ipairs(keys) do if tostring(key):lower() == source then return true end end
    return false
end

local function LastAdoption(info)
    local write = info.db.tsmWrite
    local histories = type(write) == "table" and write.basisOwnershipHistory
    local history = type(histories) == "table" and histories[info.itemString]
    return type(history) == "table" and history[#history] or nil, write
end

local function IsManaged(info, last, write)
    if Native(info.entry.customValue) and RegisteredNative(SOURCE) then return true end
    if not last or last.restoredAt then return false end
    if info.entry.customValue == (last.target or last.source) then return true end
    -- Normal UBK automatic writes may have advanced a literal as acquisitions
    -- changed. Recognize only a value the normal bridge recorded as its own.
    local written = type(write) == "table" and type(write.lastWritten) == "table" and write.lastWritten[info.itemString]
    return type(written) == "table" and written.value == info.entry.customValue
end

local function PreviousFormula(state, current)
    if type(current) == "string" and not Native(current) then return current end
    if type(state.protectedFormulaValue) == "string" and not Native(state.protectedFormulaValue) then
        return state.protectedFormulaValue
    end
    return nil
end

-- A protected formula is an ownership marker, not evidence of purchase cost.
-- If it hid a retained-purchase provenance, recover only that documented label.
-- All other provenance questions and all unknown quantities remain untouched.
local function UnprotectedProvenance(state)
    local qty, value = tonumber(state.qty) or 0, tonumber(state.value) or 0
    local unknown = tonumber(state.bootstrapUnresolved) or 0
    local seed = tostring(state.seedSource or "")
    if qty > 0 and value > 0 then
        if seed == "retained-purchases" or seed == "partial-purchase-history"
            or seed == "retained-purchases+existing-literal" then
            return unknown > 0 and "partial-history" or "purchase-history"
        end
        if (tonumber(state.buysQty) or 0) > 0 then return "purchase-ledger" end
    end
    if qty == 0 and (tonumber(state.historicalBuyQty) or 0) > 0
        and (tonumber(state.historicalBuyValue) or 0) > 0 then return "historical-only" end
    return "unresolved"
end

function API:PreviewAdoptBasisPricing(itemArg)
    local info, err = Material(itemArg)
    if not info then return false, err end
    local cost = type(self.GetMaterialCost) == "function" and self:GetMaterialCost(info.itemString) or nil
    if not Positive(cost) then cost = nil end
    local source, integration
    if RegisteredNative(SOURCE) then source, integration = SOURCE, "native"
    elseif cost then source, integration = tostring(math.max(1, math.floor(cost + .5))) .. "c", "material-write"
    else source, integration = PURCHASE_SOURCE, "recorded-purchases" end
    if not ValidSource(source) then return false, "TSM is not ready to accept a supported material cost; the current formula was kept." end
    return true, {itemString=info.itemString, source=source, integration=integration, previous=info.entry.customValue,
        previousFormula=PreviousFormula(info.state, info.entry.customValue), cost=cost,
        costPending=cost == nil, protected=info.state.protectedFormula == true and not info.state.formulaOverride}
end

function API:GetBasisPricingOwnershipInfo(itemArg)
    local info = Material(itemArg)
    if not info then return nil end
    local last, write = LastAdoption(info)
    local managed = IsManaged(info, last, write)
    return {native=Native(info.entry.customValue), managed=managed, protected=info.state.protectedFormula == true and not info.state.formulaOverride,
        previousFormula=PreviousFormula(info.state, info.entry.customValue),
        canRestore=managed and type(last) == "table" and not last.restoredAt,
        adoptedAt=last and last.at or nil}
end

-- Called only from a player's per-item action. It deliberately uses the same
-- scoped material table and backup/lastWritten records as /ubk own + /ubk write.
function API:AdoptBasisPricing(itemArg)
    local ok, preview = self:PreviewAdoptBasisPricing(itemArg)
    if not ok then return false, preview end
    local info, err = Material(preview.itemString)
    if not info then return false, err end
    local state, entry = info.state, info.entry
    local ownership = self:GetBasisPricingOwnershipInfo(info.itemString)
    if ownership.managed and state.protectedFormula ~= true and state.costProvenance ~= "formula-protected"
        and state.userCostClassification ~= "formula-protected" then return true, preview end

    local write = WriteState(info.db)
    local previous = entry.customValue
    local stamp = Now()
    local player = type(UnitName) == "function" and UnitName("player") or nil
    local record = {at=stamp, by=player, source=preview.source, target=preview.source, integration=preview.integration,
        hadCustom=previous ~= nil, previous=previous,
        previousFormula=preview.previousFormula, fields={}, paused=write.pausedItems[info.itemString]}
    for _, key in ipairs(ownershipFields) do
        record.fields[key] = {present=state[key] ~= nil, value=state[key]}
    end
    -- Keep the original /ubk restore backup. Never overwrite earlier evidence.
    if type(write.backups[info.itemString]) ~= "table" then
        write.backups[info.itemString] = {hadCustom=previous ~= nil, value=previous, capturedAt=stamp,
            capturedBy=player, source="UBK cost-coverage ownership"}
    end
    entry.customValue = preview.source
    if entry.customValue ~= preview.source then return false, "TSM did not accept the UBK material cost." end
    write.basisOwnershipHistory[info.itemString] = type(write.basisOwnershipHistory[info.itemString]) == "table"
        and write.basisOwnershipHistory[info.itemString] or {}
    local history = write.basisOwnershipHistory[info.itemString]
    history[#history + 1] = record
    if preview.previousFormula then state.protectedFormulaValue = preview.previousFormula end
    state.protectedFormula = false
    state.formulaOverride = true
    state.formulaOverrideAt, state.formulaOverrideBy = stamp, player
    if state.costProvenance == "formula-protected" then state.costProvenance = UnprotectedProvenance(state) end
    if state.userCostClassification == "formula-protected" then state.userCostClassification = nil end
    record.appliedFields = {}
    for _, key in ipairs(ownershipFields) do record.appliedFields[key] = {present=state[key] ~= nil, value=state[key]} end
    write.pausedItems[info.itemString] = nil
    write.lastWritten[info.itemString] = {value=preview.source, previous=previous, at=stamp, by=player,
        source="UBK cost-coverage ownership"}
    write.writes = (tonumber(write.writes) or 0) + (previous ~= preview.source and 1 or 0)
    preview.cost = type(self.GetMaterialCost) == "function" and self:GetMaterialCost(info.itemString) or nil
    if not Positive(preview.cost) then preview.cost = nil end
    preview.costPending = preview.cost == nil
    if preview.integration ~= "native" and preview.cost then
        -- Clearing a stale ownership marker may uncover a previously blocked
        -- retained-purchase basis. Use it immediately in an unmodified TSM.
        local target = tostring(math.max(1, math.floor(preview.cost + .5))) .. "c"
        if ValidSource(target) then
            entry.customValue = target; record.target = target; record.source = target
            record.integration = "material-write"; preview.source = target; preview.integration = "material-write"
            write.lastWritten[info.itemString].value = target
        end
    end
    preview.reloadRecommended = preview.integration ~= "native"
    return true, preview
end

function API:RestoreBasisPricingOverride(itemArg)
    local info, err = Material(itemArg)
    if not info then return false, err end
    local write = WriteState(info.db)
    local history = write.basisOwnershipHistory[info.itemString]
    local last = type(history) == "table" and history[#history] or nil
    if not last or last.restoredAt then return false, "There is no active cost-coverage adoption to restore." end
    if not IsManaged(info, last, write) then return false, "TSM's cost has changed since adoption; the newer value was kept." end
    local restore = last.previousFormula or (last.hadCustom and last.previous or nil)
    info.entry.customValue = restore
    for _, key in ipairs(ownershipFields) do
        local previous = last.fields[key]
        local applied = last.appliedFields and last.appliedFields[key]
        -- A later purchase or explicit cost review may have updated provenance.
        -- Restore ownership without rewinding those newer accounting decisions.
        local untouched = not applied or (applied.present == (info.state[key] ~= nil) and applied.value == info.state[key])
        if untouched then
            if previous and previous.present then info.state[key] = previous.value else info.state[key] = nil end
        end
    end
    -- Pause this item so autosync cannot immediately replace the restored formula.
    write.pausedItems[info.itemString] = true
    last.restoredAt, last.restoredBy = Now(), type(UnitName) == "function" and UnitName("player") or nil
    last.restoredValue = restore
    write.restores = (tonumber(write.restores) or 0) + 1
    return true, {itemString=info.itemString, value=restore}
end

-- Read the installed configuration instead of assuming any personal alias
-- exists. This is an explanation surface only: it never installs or changes
-- custom sources, crafting/auction operations, or default material settings.
function API:GetPricingIntegrationInfo(itemArg)
    local itemString = itemArg ~= nil and ItemKey(itemArg) or nil
    if itemArg ~= nil and not itemString then return nil end
    local db, context = Scope()
    local tsm = _G.TradeSkillMasterDB
    local api = _G.TSM_API
    local function Price(source)
        if not itemString then return nil end
        if type(api) ~= "table" or type(api.GetCustomPriceValue) ~= "function" then return nil end
        local ok, value = pcall(api.GetCustomPriceValue, source, itemString)
        return ok and Positive(value) and value or nil
    end
    local custom = type(tsm) == "table" and tsm["g@ @userData@customPriceSources"] or nil
    custom = type(custom) == "table" and custom or {}
    local aliases = {}
    for name, expression in pairs(custom) do
        if type(name) == "string" and type(expression) == "string" then aliases[name:lower()] = expression end
    end
    local nativeKeys = {ubkbasis=true, ubkmatcost=true, ubkcrafting=true, ubksellbasis=true}
    local function NativeReferences(expression, seen, references)
        for token in tostring(expression):lower():gmatch("[%a_][%w_]*") do
            if nativeKeys[token] then references[token] = true end
            if aliases[token] and not seen[token] then
                seen[token] = true
                NativeReferences(aliases[token], seen, references)
            end
        end
    end
    local native = {}
    for _, key in ipairs({"ubkbasis", "ubkmatcost", "ubkcrafting", "ubksellbasis"}) do
        local direct = {}
        for name, expression in pairs(aliases) do
            if expression:lower():gsub("%s", "") == key then direct[#direct + 1] = name end
        end
        table.sort(direct)
        native[#native + 1] = {key=key, available=RegisteredNative(key), value=Price(key), aliases=direct}
    end
    local configured = {}
    for name, expression in pairs(aliases) do
        local found, references = {}, {}
        NativeReferences(expression, {[name]=true}, found)
        for key in pairs(found) do references[#references + 1] = key end
        table.sort(references)
        if #references > 0 then
            configured[#configured + 1] = {name=name, expression=expression, value=Price(name),
                available=ValidSource(name), references=references}
        end
    end
    table.sort(configured, function(a,b) return a.name < b.name end)
    local mats = type(_G.UBK_GetTSMMatsTable) == "function" and _G.UBK_GetTSMMatsTable() or nil
    local entry = type(mats) == "table" and mats[itemString] or nil
    local basis = itemString and type(self.GetAcquisitionCost) == "function" and self:GetAcquisitionCost(itemString) or nil
    local acquisition = Positive(basis) and {source="UBK known-cost pool", value=basis} or nil
    if not acquisition then
        local paid = Price("avgbuy")
        if paid then acquisition = {source="TSM recorded purchase average (avgbuy)", value=paid} end
    end
    if not acquisition then
        local vendor = Price("vendorbuy")
        if vendor then acquisition = {source="TSM recorded vendor quote (vendorbuy)", value=vendor} end
    end
    return {itemString=itemString, native=native, aliases=configured,
        fallbacks={{key="avgbuy",available=ValidSource("avgbuy"),value=Price("avgbuy")},
            {key="vendorbuy",available=ValidSource("vendorbuy"),value=Price("vendorbuy")}},
        integration=native[2].available and "native" or "material-write",
        label=native[2].available and "Native UBK price sources" or "Standard TSM: UBK material cost write-through",
        materialOverride=type(entry) == "table" and entry.customValue or nil,
        materialDefault=type(tsm) == "table" and tsm["g@ @craftingOptions@defaultMatCostMethod"] or nil,
        craftingDefault=type(tsm) == "table" and tsm["g@ @craftingOptions@defaultCraftPriceMethod"] or nil,
        materialExists=type(entry) == "table", acquisition=acquisition,
        scope=type(context) == "table" and context.realmKey or nil}
end

-- Earliest retained purchase evidence, not discovery time and not watch date.
-- The core index already checks positive paid prices, Auction/Vendor/Trade,
-- current realm and current-faction character ownership.
function API:GetFirstAcquisitionTime(itemArg)
    local itemString = ItemKey(itemArg)
    if not itemString then return nil end
    local db, context = Scope()
    if type(context) ~= "table" or not context.realm or not context.realmKey then return nil end
    local tsm = _G.TradeSkillMasterDB
    local csv = type(tsm) == "table" and tsm["r@" .. context.realm .. "@internalData@csvBuys"] or nil
    local chars = type(_G.UBK_CurrentFactionCharacters) == "function" and _G.UBK_CurrentFactionCharacters() or {}
    local charKeys = {}; for name in pairs(chars) do charKeys[#charKeys + 1] = name end; table.sort(charKeys)
    local signature = context.realmKey .. "\031" .. table.concat(charKeys, "\031")
    if acquisitionCache.csv ~= csv or acquisitionCache.signature ~= signature then
        local index = type(_G.UBK_BuildUniversalPurchaseIndex) == "function" and _G.UBK_BuildUniversalPurchaseIndex() or {}
        local earliest = {}
        for key, records in pairs(type(index) == "table" and index or {}) do
            local baseItem = ItemKey(key)
            for _, purchase in ipairs(records) do
                local at = tonumber(purchase.time)
                if baseItem and Positive(at) and Positive(tonumber(purchase.qty)) and Positive(tonumber(purchase.price)) then
                    if not earliest[baseItem] or at < earliest[baseItem] then earliest[baseItem] = at end
                end
            end
        end
        acquisitionCache = {csv=csv, signature=signature, earliest=earliest}
    end
    local earliest = acquisitionCache.earliest and acquisitionCache.earliest[itemString] or nil
    local evidence = earliest and "TSM purchase record" or nil
    -- Paid buyer-mail records belong to this realm/faction DB. Their capture
    -- date is evidence of acquisition; unresolved/loot discovery dates are not.
    local mail = type(db) == "table" and db.mailCapture or nil
    for _, kind in ipairs({"pendingLots", "appliedLots"}) do
        local lots = type(mail) == "table" and type(mail[kind]) == "table" and mail[kind][itemString] or nil
        for _, lot in ipairs(type(lots) == "table" and lots or {}) do
            local at = tonumber(lot.capturedAt)
            if Positive(at) and Positive(tonumber(lot.qty)) and Positive(tonumber(lot.unitPrice))
                and (not earliest or at < earliest) then earliest, evidence = at, "Paid buyer-mail capture" end
        end
    end
    return earliest, evidence
end

-- One explicit exact-item query using UBK's existing serial AH scan pipeline.
function API:ScanMarketItem(itemArg)
    local itemString=ItemKey(itemArg)
    if not itemString then return false,"Inspect a valid item before scanning." end
    if not self.IsAuctionVisible or not self:IsAuctionVisible() then return false,"Open the Auction House, then click Scan Now." end
    if type(QueryAuctionItems)~="function" then return false,"This client's exact-item Auction House scanner is unavailable." end
    local id=tonumber(itemString:match("^i:(%d+)$"))
    local name=type(GetItemInfo)=="function" and GetItemInfo(id)
    if not name then return false,"Item information is still loading. Hover the item and try Scan Now again." end
    return self:StartShredderLiveStockRefresh({itemString})
end
