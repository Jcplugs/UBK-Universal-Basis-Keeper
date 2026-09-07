-- UBK v1.6
--
-- TBC Anniversary companion with first-run TSM import/review.
-- Account-wide, faction-aware acquisition-basis engine for every purchased item, with optional TSM material integration.
-- Runtime TSM Accounting is authoritative for purchases. Non-crafting purchases are tracked
-- by UBK without creating fake TSM materials. No account-specific purchase-history snapshot
-- or pre-seeded economic data is distributed with this build.
--
-- TSM v4.14.76 note:
-- TSM's live crafting cost path reads the faction-realm mats table directly. Its Crafting
-- Reports material table has an internal cache which an external addon cannot safely refresh
-- through a public API, so /reload may be useful after first-time writes.
--
-- Canonical command: /ubk

local ADDON = ...
local events = CreateFrame("Frame")

local REALM_NAME = ""
local FACTION_NAME = ""
local REALM_KEY = ""
local TSM_BUY_KEY = ""
local TSM_MATS_KEY = ""
local TSM_EXPECTED_VERSION = "v4.14.76"
local UNIVERSAL_SCHEMA = 2
local MAIL_CAPTURE_SCHEMA = 2
local COST_AUDIT_SCHEMA = 2
UBK_PURCHASE_UNIVERSE_SCHEMA = 1
local REVIEW_SCHEMA = 2

local function RefreshRuntimeKeys()
    local function RuntimePattern(text)
        return tostring(text or ""):gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    end
    local function RealmFromTSM(character, faction)
        if type(TradeSkillMasterDB) ~= "table" or not character or character == "" or not faction or faction == "" then return nil end
        local found = {}
        local characterPattern = "^s@" .. RuntimePattern(character) .. " %- " .. RuntimePattern(faction) .. " %- (.-)@"
        for key in pairs(TradeSkillMasterDB) do
            if type(key) == "string" then
                local candidate = key:match(characterPattern)
                if candidate and candidate ~= "" then found[candidate] = true end
            end
        end
        local only = nil
        for candidate in pairs(found) do
            if only and only ~= candidate then return nil end
            only = candidate
        end
        if only then return only end

        -- A brand-new character may not have character quantity rows yet. A single
        -- faction-realm mats table is still safe evidence; multiple realms are not.
        local matsPattern = "^f@" .. RuntimePattern(faction) .. " %- (.-)@internalData@mats$"
        for key in pairs(TradeSkillMasterDB) do
            if type(key) == "string" then
                local candidate = key:match(matsPattern)
                if candidate and candidate ~= "" then found[candidate] = true end
            end
        end
        only = nil
        for candidate in pairs(found) do
            if only and only ~= candidate then return nil end
            only = candidate
        end
        return only
    end
    local realm = (GetRealmName and GetRealmName()) or ""
    if realm == "" or realm == "Unknown" then realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or "" end
    local faction = (UnitFactionGroup and UnitFactionGroup("player")) or ""
    if realm == "" or realm == "Unknown" then
        realm = RealmFromTSM((UnitName and UnitName("player")) or "", faction) or ""
    end
    REALM_NAME = realm
    FACTION_NAME = faction
    REALM_KEY = REALM_NAME .. "-" .. FACTION_NAME
    TSM_BUY_KEY = "r@" .. REALM_NAME .. "@internalData@csvBuys"
    TSM_MATS_KEY = "f@" .. FACTION_NAME .. " - " .. REALM_NAME .. "@internalData@mats"
    if type(_G.UniversalBasisKeeperAPI) == "table" then
        _G.UniversalBasisKeeperAPI.realmKey = REALM_KEY
        _G.UniversalBasisKeeperAPI.realmName = REALM_NAME
        _G.UniversalBasisKeeperAPI.factionName = FACTION_NAME
    end
end

RefreshRuntimeKeys()

-- Distribution build deliberately ships with no historical item-cost evidence.
-- Every account starts empty and learns only from that account's own TSM ledger,
-- buyer-mail capture, inventory observations, or explicit manual classification.
local HISTORICAL_COST_AUDIT = {}

-- No account-specific economic/opportunity values are distributed.
local MANUAL_ECONOMIC_VALUES = {}

local ROOT_SCHEMA = 1
local BASIS_SCHEMA = 1
local WRITE_SCHEMA = 2
local BASIS_CUTOVER_TIME = 0
local BASIS_SNAPSHOT = "ubk-1.4-live-tsm"
local REFRESH_DELAY_FAST = 0.5
local REFRESH_DELAY_SLOW = 2.0
local TICK_SECONDS = 15
local MAIL_SCAN_DELAY = 0.8
local MAIL_BASELINE_DELAY = 1.5
local LATE_LEDGER_MATCH_WINDOW = 1800
local MAIL_TSM_DEDUPE_WINDOW = 86400

local tickerStarted = false
local warnedUnsupportedClient = false
local mailboxSessionOpen = false
local mailboxBaselinePending = false
local mailLootHook = {
    installed = false,
    originalTakeInboxItem = nil,
    originalAutoLootMailItem = nil,
    takeWrapper = nil,
    autoWrapper = nil,
    installedAt = 0,
    recentCalls = {},
    captureArmed = false,
    burstActive = false,
    settleGeneration = 0,
}


-- Fresh distribution build: no item IDs, quantities, or costs are pre-seeded.
-- Materials are discovered from the local TSM material table after login.
local BASIS_SEEDS = {}

local BASIS_ORDER = {}

local function EnsureOrderItem(itemString)
    for _, existing in ipairs(BASIS_ORDER) do
        if existing == itemString then return end
    end
    BASIS_ORDER[#BASIS_ORDER + 1] = itemString
end

local function IsLiteralMoney(text)
    if type(text) ~= "string" then return false end
    local compact = text:lower():gsub("%s+", "")
    if compact == "" then return false end
    return compact:match("^%d+%.?%d*g%d*%.?%d*s%d*%.?%d*c$") ~= nil
        or compact:match("^%d+%.?%d*g%d*%.?%d*s$") ~= nil
        or compact:match("^%d+%.?%d*g%d*%.?%d*c$") ~= nil
        or compact:match("^%d+%.?%d*g$") ~= nil
        or compact:match("^%d+%.?%d*s%d*%.?%d*c$") ~= nil
        or compact:match("^%d+%.?%d*s$") ~= nil
        or compact:match("^%d+%.?%d*c$") ~= nil
end

local function ParseMoney(text)
    if type(text) ~= "string" then return nil end
    local compact = text:lower():gsub(",", ""):gsub("%s+", "")
    if compact == "" or not IsLiteralMoney(compact) then return nil end
    local g = tonumber(compact:match("([%d%.]+)g")) or 0
    local s = tonumber(compact:match("([%d%.]+)s")) or 0
    local c = tonumber(compact:match("([%d%.]+)c")) or 0
    local copper = g * 10000 + s * 100 + c
    if copper < 0 then return nil end
    return math.floor(copper + 0.5)
end

local QUANTITY_TABLES = {
    bagQuantity = true,
    bankQuantity = true,
    mailQuantity = true,
    auctionQuantity = true,
}

local function IsSupportedRealm()
    RefreshRuntimeKeys()
    local _, _, _, interface = GetBuildInfo()
    interface = tonumber(interface) or 0
    return REALM_NAME ~= "" and (FACTION_NAME == "Horde" or FACTION_NAME == "Alliance") and interface >= 20500 and interface < 30000
end

local function EscapePattern(text)
    return tostring(text or ""):gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

local function TSMCharacterQuantityPattern()
    RefreshRuntimeKeys()
    return "^s@(.+) %- " .. EscapePattern(FACTION_NAME) .. " %- " .. EscapePattern(REALM_NAME) .. "@internalData@([%a]+Quantity)$"
end

local function TSMCharacterPrefixPattern()
    RefreshRuntimeKeys()
    return "^s@(.+) %- " .. EscapePattern(FACTION_NAME) .. " %- " .. EscapePattern(REALM_NAME) .. "@"
end

function UBK_GetCurrentPendingMailTable()
    RefreshRuntimeKeys()
    if type(TradeSkillMasterDB) ~= "table" then return nil end
    local key = "f@"..FACTION_NAME.." - "..REALM_NAME.."@internalData@pendingMail"
    local pending = TradeSkillMasterDB[key]
    return type(pending)=="table" and pending or nil
end

function UBK_CurrentFactionCharacters()
    local out = {}
    if type(TradeSkillMasterDB) == "table" then
        local pattern = TSMCharacterPrefixPattern()
        for key in pairs(TradeSkillMasterDB) do
            if type(key) == "string" then
                local character = key:match(pattern)
                if character and character ~= "" then out[character] = true end
            end
        end
    end
    local current = UnitName and UnitName("player") or nil
    if current and current ~= "" then out[current] = true end
    return out
end

local function RoundCopper(value)
    if not value then return 0 end
    return math.floor(value + 0.5)
end

local function FormatMoney(copper)
    copper = RoundCopper(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then
        return string.format("%dg%02ds%02dc", g, s, c)
    elseif s > 0 then
        return string.format("%ds%02dc", s, c)
    else
        return string.format("%dc", c)
    end
end

local function NormalizeName(text)
    return (text or ""):lower():gsub("[%s%p_]", "")
end

local function IsUniversalExcluded(itemString)
    return _G.UBKItemRules.VendorTrash(itemString)
end

local function ResolveItem(text)
    text = text or ""
    local directID = text:match("|Hitem:(%d+)") or text:match("^%s*i:(%d+)%s*$") or text:match("^%s*(%d+)%s*$")
    if directID then
        local direct = "i:" .. tostring(tonumber(directID))
        if BASIS_SEEDS[direct] then return direct end
    end
    local n = NormalizeName(text)
    if n == "" then return nil end
    for itemString, seed in pairs(BASIS_SEEDS) do
        if NormalizeName(seed.name) == n then return itemString end
        for _, alias in ipairs(seed.aliases or {}) do
            if NormalizeName(alias) == n then return itemString end
        end
    end
    return nil
end

local function EnsureRootDB()
    if type(UniversalBasisKeeperDB) ~= "table" then
        UniversalBasisKeeperDB = {}
    end
    local root = UniversalBasisKeeperDB
    if root.schema ~= ROOT_SCHEMA then
        root.schema = ROOT_SCHEMA
    end
    if type(root.realms) ~= "table" then
        root.realms = {}
    end
    if type(root.migrations) ~= "table" then root.migrations = {} end
    if type(root.characters) ~= "table" then root.characters = {} end
    RefreshRuntimeKeys()
    if REALM_NAME ~= "" and UnitName("player") then
        local ck = (UnitName("player") or "Unknown") .. " - " .. REALM_NAME
        root.characters[ck] = {realm=REALM_NAME, faction=FACTION_NAME, lastSeen=time and time() or 0}
    end
    return root
end

local function NewRealmDB()
    local now = time and time() or 0
    local db = {
        schema = BASIS_SCHEMA, readOnly = false, integrationMode = "setup-pending",
        snapshot = BASIS_SNAPSHOT, cutoffTime = now, lastLedgerTime = now,
        processedCounts = {}, items = {}, createdAt = now, activitySinceSeed = false,
        lastProcessor = nil, lastProcessAt = 0,
        setup = {status="pending", createdAt=now, historyMode=nil, profilePrepared=false},
    }
    return db
end

local function EnsureWriteState(db)
    if type(db.tsmWrite) ~= "table" then
        db.tsmWrite = {}
    end
    local writeState = db.tsmWrite
    if type(writeState.backups) ~= "table" then writeState.backups = {} end
    if type(writeState.lastWritten) ~= "table" then writeState.lastWritten = {} end
    if type(writeState.pausedItems) ~= "table" then writeState.pausedItems = {} end
    if type(writeState.externalDrift) ~= "table" then writeState.externalDrift = {} end
    local setupPending = type(db.setup)=="table" and (db.setup.status=="pending" or db.setup.status=="review")
    if writeState.schema ~= WRITE_SCHEMA then
        writeState.schema = WRITE_SCHEMA
        writeState.mode = setupPending and "manual" or "automatic"
        writeState.autoEnabledAt = writeState.mode=="automatic" and (time and time() or 0) or nil
    elseif writeState.mode == nil then
        writeState.mode = setupPending and "manual" or "automatic"
    elseif setupPending then
        writeState.mode = "manual"
    end
    writeState.writes = tonumber(writeState.writes) or 0
    writeState.restores = tonumber(writeState.restores) or 0
    writeState.autoWrites = tonumber(writeState.autoWrites) or 0
    db.readOnly = false
    db.integrationMode = writeState.mode == "automatic" and "automatic-tsm-write" or "manual-tsm-write"
    return writeState
end

local function EnsureUniversalState(db)
    if type(db.universal) ~= "table" then
        db.universal = {
            schema = UNIVERSAL_SCHEMA,
            mode = (type(db.setup)=="table" and db.setup.status~="complete") and "preview" or "active",
            createdAt = time and time() or 0,
            discovered = 0,
            seeded = 0,
            unresolved = 0,
        }
    end
    local universal = db.universal
    universal.schema = UNIVERSAL_SCHEMA
    if universal.mode ~= "active" and universal.mode ~= "preview" then universal.mode = "active" end
    universal.discovered = tonumber(universal.discovered) or 0
    universal.seeded = tonumber(universal.seeded) or 0
    universal.unresolved = tonumber(universal.unresolved) or 0
    if type(universal.meta) ~= "table" then universal.meta = {} end
    return universal
end

local function EnsureMailCapture(db)
    if type(db.mailCapture) ~= "table" then
        db.mailCapture = {
            schema = MAIL_CAPTURE_SCHEMA,
            armed = false,
            activeCounts = {},
            pendingLots = {},
            capturedRecords = 0,
            capturedQty = 0,
            capturedValue = 0,
            appliedRecords = 0,
            appliedQty = 0,
            appliedValue = 0,
            lastScanAt = 0,
        }
    end
    local mc = db.mailCapture
    mc.schema = MAIL_CAPTURE_SCHEMA
    if type(mc.activeCounts) ~= "table" then mc.activeCounts = {} end
    if type(mc.pendingLots) ~= "table" then mc.pendingLots = {} end
    if type(mc.appliedLots) ~= "table" then mc.appliedLots = {} end
    if type(mc.preLootSeen) ~= "table" then mc.preLootSeen = {} end
    if type(mc.tsmInvoiceClaims) ~= "table" then mc.tsmInvoiceClaims = {} end
    if type(mc.preLootBypass) ~= "table" then mc.preLootBypass = {} end
    if type(mc.preLootVisibleClaims) ~= "table" then mc.preLootVisibleClaims = {} end
    mc.preLootCapturedRecords = tonumber(mc.preLootCapturedRecords) or 0
    mc.preLootCapturedQty = tonumber(mc.preLootCapturedQty) or 0
    mc.preLootMatchedPending = tonumber(mc.preLootMatchedPending) or 0
    mc.tsmInvoiceMatchedRecords = tonumber(mc.tsmInvoiceMatchedRecords) or 0
    mc.tsmInvoiceMatchedQty = tonumber(mc.tsmInvoiceMatchedQty) or 0
    mc.capturedRecords = tonumber(mc.capturedRecords) or 0
    mc.capturedQty = tonumber(mc.capturedQty) or 0
    mc.capturedValue = tonumber(mc.capturedValue) or 0
    mc.appliedRecords = tonumber(mc.appliedRecords) or 0
    mc.appliedQty = tonumber(mc.appliedQty) or 0
    mc.appliedValue = tonumber(mc.appliedValue) or 0
    mc.tsmDedupedRecords = tonumber(mc.tsmDedupedRecords) or 0
    mc.tsmDedupedQty = tonumber(mc.tsmDedupedQty) or 0
    mc.tsmPendingDedupedRecords = tonumber(mc.tsmPendingDedupedRecords) or 0
    mc.tsmPendingDedupedQty = tonumber(mc.tsmPendingDedupedQty) or 0
    mc.importNext = mc.importNext == true
    return mc
end

local function HydrateUniversalSeeds(db)
    local universal = EnsureUniversalState(db)
    for itemString, meta in pairs(universal.meta) do
        if type(meta) == "table" and meta.name and not IsUniversalExcluded(itemString) then
            if not BASIS_SEEDS[itemString] then
                BASIS_SEEDS[itemString] = {
                    name = meta.name,
                    aliases = type(meta.aliases) == "table" and meta.aliases or {},
                    custom = true,
                }
            end
            EnsureOrderItem(itemString)
        end
    end
end

local function HydrateCustomSeeds(db)
    if type(db.customSeeds) ~= "table" then db.customSeeds = {} end
    for itemString, meta in pairs(db.customSeeds) do
        if type(meta) == "table" and meta.name and not IsUniversalExcluded(itemString) then
            if not BASIS_SEEDS[itemString] then
                BASIS_SEEDS[itemString] = {
                    name = meta.name,
                    aliases = type(meta.aliases) == "table" and meta.aliases or {},
                    custom = true,
                }
            end
            EnsureOrderItem(itemString)
        end
    end
end

local function EnsureItemStates(db)
    for itemString, seed in pairs(BASIS_SEEDS) do
        if type(db.items[itemString]) ~= "table" and seed.qty and seed.basis then
            db.items[itemString] = {
                qty = seed.qty,
                value = seed.qty * seed.basis,
                lastBasis = seed.basis,
                pending = 0,
                lastObserved = seed.qty,
                buysQty = 0,
                buysValue = 0,
                buysRecords = 0,
                lastBuyTime = 0,
                lastBuyer = nil,
                buyers = {},
                unexplainedGain = 0,
            }
        elseif type(db.items[itemString]) == "table" then
            local state = db.items[itemString]
            if not state.lastBasis or tonumber(state.lastBasis) <= 0 then
                local qty = tonumber(state.qty) or 0
                local value = tonumber(state.value) or 0
                if qty > 0 and value > 0 then
                    state.lastBasis = value / qty
                elseif seed.basis then
                    state.lastBasis = seed.basis
                end
            end
        end
    end
end

local function GetRealmDB()
    RefreshRuntimeKeys()
    if _G.UniversalBasisKeeperAPI then
        _G.UniversalBasisKeeperAPI.realmKey = REALM_KEY
        _G.UniversalBasisKeeperAPI.realmName = REALM_NAME
        _G.UniversalBasisKeeperAPI.factionName = FACTION_NAME
    end
    local root = EnsureRootDB()
    local db = root.realms[REALM_KEY]
    if type(db) ~= "table" or db.schema ~= BASIS_SCHEMA or type(db.items) ~= "table" then
        db = NewRealmDB()
        root.realms[REALM_KEY] = db
    end
    -- Upgrade compatibility: older UBK databases may already contain deliberate,
    -- accepted basis state without a setup object. Preserve that state instead of
    -- forcing an established installation through first-run setup again.
    if type(db.setup) ~= "table" then
        local hasLegacyItems = false
        for _ in pairs(db.items or {}) do hasLegacyItems = true; break end
        if hasLegacyItems then
            db.setup = {status="complete", historyMode="legacy-upgrade", profilePrepared=true, completedAt=time and time() or 0}
        else
            db.setup = {status="pending", createdAt=time and time() or 0, historyMode=nil, profilePrepared=false}
        end
    end
    HydrateCustomSeeds(db)
    EnsureUniversalState(db)
    EnsureMailCapture(db)
    HydrateUniversalSeeds(db)
    EnsureItemStates(db)
    EnsureWriteState(db)
    return db
end

local function CopyTable(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do
        out[CopyTable(k)] = CopyTable(v)
    end
    return out
end

local function TryLegacyMigration(silent)
    -- Distribution build never imports another player's historical addon state.
    return false
end

local function GetUnitBasis(state)
    if not state then return 0 end
    local qty = tonumber(state.qty) or 0
    local value = tonumber(state.value) or 0
    if qty > 0 then
        local basis = value / qty
        if basis > 0 then state.lastBasis = basis end
        return basis
    end
    return tonumber(state.lastBasis) or 0
end

local function GetTSMBuyLedger()
    RefreshRuntimeKeys()
    local bridge=_G.UBKTSMGroupBridge
    if bridge and bridge.ready and type(bridge.GetBuyLedgerCSV)=="function" then
        local ok,csv=pcall(bridge.GetBuyLedgerCSV)
        if ok and type(csv)=="string" then
            _G.UBKPurchaseLedger.liveUnavailable=false
            return csv
        end
    end
    if bridge and bridge.ready and type(bridge.GetBuyLedgerCSV)~="function" then
        _G.UBKPurchaseLedger.liveUnavailable=true
        if not _G.UBKPurchaseLedger.warnedIntegration then
            _G.UBKPurchaseLedger.warnedIntegration=true
            print("|cffffcc00UBK:|r Update UBK's TSM Integration together with UBK for live purchase costs. Currently using saved purchase history.")
        end
    end
    if type(TradeSkillMasterDB) ~= "table" then return nil end
    local csv = TradeSkillMasterDB[TSM_BUY_KEY]
    if type(csv) ~= "string" or csv == "" then return nil end
    return csv
end

function UBK_GetSupplementalBuyLedger()
    -- Kept as a compatibility hook for callers from older versions. Public
    -- releases deliberately distribute no supplemental player ledger.
    return nil
end

function UBK_IsTSMMaterial(itemString)
    local mats = GetTSMMatsTable and UBK_GetTSMMatsTable() or nil
    return type(mats) == "table" and type(mats[itemString]) == "table"
end

local function GetRealmTrackedQuantities(withDetails)
    local result = {}
    local details = withDetails and {} or nil
    for itemString in pairs(BASIS_SEEDS) do result[itemString] = 0 end

    if type(TradeSkillMasterDB) ~= "table" then return result, false, details end

    local foundAny = false
    for key, value in pairs(TradeSkillMasterDB) do
        if type(key) == "string" and type(value) == "table" then
            local character, kind = key:match(TSMCharacterQuantityPattern())
            if character and kind and QUANTITY_TABLES[kind] then
                foundAny = true
                for itemString in pairs(BASIS_SEEDS) do
                    local qty = tonumber(value[itemString]) or 0
                    result[itemString] = result[itemString] + qty
                    if details and qty > 0 then
                        details[itemString] = details[itemString] or {}
                        details[itemString][character] = details[itemString][character] or {}
                        details[itemString][character][kind] = qty
                    end
                end
            end
        end
    end
    -- TSM itself counts faction-realm pendingMail as inventory owned by the
    -- recipient. Mirror that here so mailing a Shredder item between our own
    -- characters never looks like an economic outflow followed by a free gain.
    local pending = UBK_GetCurrentPendingMailTable()
    if pending then
        foundAny = true
        for character, items in pairs(pending) do
            if type(items)=="table" then
                for itemString in pairs(BASIS_SEEDS) do
                    local qty=tonumber(items[itemString]) or 0
                    if qty>0 then
                        result[itemString]=(result[itemString] or 0)+qty
                        if details then
                            details[itemString]=details[itemString] or {}
                            details[itemString][character]=details[itemString][character] or {}
                            details[itemString][character].pendingMailQuantity=(tonumber(details[itemString][character].pendingMailQuantity) or 0)+qty
                        end
                    end
                end
            end
        end
    end

    return result, foundAny, details
end

local function GetRealmQuantityForItem(itemString)
    if type(TradeSkillMasterDB) ~= "table" then return 0, false end
    local total, foundAny = 0, false
    for key, value in pairs(TradeSkillMasterDB) do
        if type(key) == "string" and type(value) == "table" then
            local _, kind = key:match(TSMCharacterQuantityPattern())
            if kind and QUANTITY_TABLES[kind] then
                foundAny = true
                total = total + (tonumber(value[itemString]) or 0)
            end
        end
    end
    local pending=UBK_GetCurrentPendingMailTable()
    if pending then
        foundAny=true
        for _,items in pairs(pending) do if type(items)=="table" then total=total+(tonumber(items[itemString]) or 0) end end
    end
    return total, foundAny
end

local GetShredEligibleQty, AddShredEligibleQty, RemoveShredEligibleQty

local function ApplyOutflow(state, newQty)
    if not state or newQty < 0 or newQty >= state.qty then return 0 end
    local oldQty = state.qty
    local basis = GetUnitBasis(state)
    state.qty = newQty
    state.value = basis * newQty
    if basis > 0 then state.lastBasis = basis end
    local removed = oldQty - newQty
    -- Shredder provenance is intentionally conservative: any realm outflow can
    -- consume qualifying shred inventory. Reducing this counter first prevents
    -- an old/legacy copy from becoming eligible merely because qualifying copies
    -- of the same item were bought and later left the account.
    if RemoveShredEligibleQty then RemoveShredEligibleQty(state, removed) end
    return removed
end

local AutoSyncTSM
local DiscoverUniversalMaterials

local function ParseBuyLine(line)
    if not line or line == "" or line:find("^itemString,") then return nil end
    local itemString, stackSize, quantity, price, otherPlayer, player, timestamp, source = strsplit(",", line)
    if not itemString then return nil end
    if source ~= "Auction" and source ~= "Vendor" and source ~= "Trade" then return nil end

    quantity = tonumber(quantity)
    price = tonumber(price)
    timestamp = tonumber(timestamp)
    if not quantity or quantity <= 0 or not price or price < 0 or not timestamp then return nil end

    return itemString, quantity, price, timestamp, player, otherPlayer, source
end


local function EnsureUnresolvedLots(state)
    if type(state.unresolvedLots) ~= "table" then state.unresolvedLots = {} end
    return state.unresolvedLots
end

local function UnresolvedLotsQty(state)
    local total = 0
    local lots = type(state.unresolvedLots) == "table" and state.unresolvedLots or nil
    if lots then
        for _, lot in ipairs(lots) do total = total + math.max(0, tonumber(lot.qty) or 0) end
    end
    return total
end

local function AddUnresolvedLot(state, qty, source, note)
    qty = tonumber(qty) or 0
    if qty <= 0 then return 0 end
    state.bootstrapUnresolved = (tonumber(state.bootstrapUnresolved) or 0) + qty
    state.unexplainedGain = tonumber(state.bootstrapUnresolved) or 0
    local lots = EnsureUnresolvedLots(state)
    lots[#lots + 1] = {
        qty = qty,
        detectedAt = time and time() or 0,
        source = source,
        note = note,
    }
    return qty
end

local function ReduceUnresolvedForOutflow(state, qty)
    qty = tonumber(qty) or 0
    local total = tonumber(state.bootstrapUnresolved) or 0
    if qty <= 0 or total <= 0 then return 0 end

    local lots = EnsureUnresolvedLots(state)
    local lotQty = UnresolvedLotsQty(state)
    local legacyQty = math.max(0, total - lotQty)
    local removed = math.min(qty, legacyQty)
    qty = qty - removed

    local i = 1
    while qty > 0 and i <= #lots do
        local lot = lots[i]
        local lq = tonumber(lot.qty) or 0
        if lq <= 0 then
            table.remove(lots, i)
        else
            local take = math.min(qty, lq)
            lot.qty = lq - take
            qty = qty - take
            removed = removed + take
            if lot.qty <= 0 then table.remove(lots, i) else i = i + 1 end
        end
    end

    state.bootstrapUnresolved = math.max(0, total - removed)
    state.unexplainedGain = tonumber(state.bootstrapUnresolved) or 0
    if removed > 0 and RemoveShredEligibleQty then RemoveShredEligibleQty(state, removed) end
    return removed
end

-- Current-owned provenance counter for Shredder's Owned Pipeline. buySources is
-- cumulative history, so using it directly can resurrect a legacy item after the
-- qualifying copy was sold/destroyed. shredEligibleQty is instead a conservative
-- current quantity: qualifying acquisitions add to it and every realm outflow
-- reduces it. Existing states migrate once from the strongest evidence available.
GetShredEligibleQty = function(state)
    if type(state) ~= "table" then return 0 end
    if state.shredEligibleQty ~= nil then
        state.shredEligibleQty = math.max(0, tonumber(state.shredEligibleQty) or 0)
        return state.shredEligibleQty
    end

    local sources = type(state.buySources) == "table" and state.buySources or {}
    local evidence = math.max(0, tonumber(sources["Auction"]) or 0)
        + math.max(0, tonumber(sources["Auction Mail"]) or 0)
        + math.max(0, tonumber(sources["Trade"]) or 0)
        + math.max(0, tonumber(state.lootImputedQty) or 0)
        + math.max(0, tonumber(state.lootReviewedQty) or 0)
    for _, lot in ipairs(type(state.unresolvedLots) == "table" and state.unresolvedLots or {}) do
        if tostring(lot.source or "") == "loot" then
            evidence = evidence + math.max(0, tonumber(lot.qty) or 0)
        end
    end
    if evidence <= 0 and state.firstSeenLootReview == true then
        evidence = math.max(0, tonumber(state.bootstrapUnresolved) or 0)
    end
    local modeled = math.max(0, tonumber(state.qty) or 0) + math.max(0, tonumber(state.bootstrapUnresolved) or 0)
    state.shredEligibleQty = math.min(modeled, evidence)
    return state.shredEligibleQty
end

AddShredEligibleQty = function(state, qty)
    qty = math.max(0, tonumber(qty) or 0)
    if type(state) ~= "table" or qty <= 0 then return 0 end
    local current = GetShredEligibleQty(state)
    state.shredEligibleQty = current + qty
    return qty
end

RemoveShredEligibleQty = function(state, qty)
    qty = math.max(0, tonumber(qty) or 0)
    if type(state) ~= "table" or qty <= 0 then return 0 end
    local current = GetShredEligibleQty(state)
    local removed = math.min(current, qty)
    state.shredEligibleQty = current - removed
    return removed
end

local function MatchUnresolvedLotsToLedger(state, qty, purchaseTime)
    qty = tonumber(qty) or 0
    purchaseTime = tonumber(purchaseTime) or 0
    if qty <= 0 or purchaseTime <= 0 then return 0 end

    local lots = EnsureUnresolvedLots(state)
    local matched = 0
    local i = 1
    while i <= #lots and qty > 0 do
        local lot = lots[i]
        local lq = tonumber(lot.qty) or 0
        local detectedAt = tonumber(lot.detectedAt) or 0
        local delta = detectedAt - purchaseTime
        if lq <= 0 then
            table.remove(lots, i)
        elseif lot.source~="prospecting-pending" and detectedAt > 0 and delta >= -5 and delta <= LATE_LEDGER_MATCH_WINDOW then
            local take = math.min(qty, lq)
            lot.qty = lq - take
            qty = qty - take
            matched = matched + take
            if lot.qty <= 0 then table.remove(lots, i) else i = i + 1 end
        else
            i = i + 1
        end
    end

    if matched > 0 then
        state.bootstrapUnresolved = math.max(0, (tonumber(state.bootstrapUnresolved) or 0) - matched)
        state.unexplainedGain = tonumber(state.bootstrapUnresolved) or 0
    end
    return matched
end

local function RecordAppliedMailLot(db, itemString, qty, unitPrice, seller, capturedAt)
    qty = tonumber(qty) or 0
    unitPrice = tonumber(unitPrice) or 0
    if qty <= 0 or unitPrice <= 0 then return end
    local mc = EnsureMailCapture(db)
    mc.appliedLots[itemString] = type(mc.appliedLots[itemString]) == "table" and mc.appliedLots[itemString] or {}
    local lots = mc.appliedLots[itemString]
    lots[#lots + 1] = {
        qty = qty,
        unitPrice = unitPrice,
        seller = seller or "",
        capturedAt = tonumber(capturedAt) or (time and time() or 0),
    }
    while #lots > 50 do table.remove(lots, 1) end
end

local function ConsumeAppliedMailMatch(db, itemString, qty, unitPrice, seller, purchaseTime)
    qty = tonumber(qty) or 0
    unitPrice = tonumber(unitPrice) or 0
    purchaseTime = tonumber(purchaseTime) or 0
    if qty <= 0 or unitPrice <= 0 then return 0 end

    local mc = EnsureMailCapture(db)
    local lots = mc.appliedLots[itemString]
    if type(lots) ~= "table" then return 0 end

    local matched = 0
    local i = 1
    while i <= #lots and qty > 0 do
        local lot = lots[i]
        local lq = tonumber(lot.qty) or 0
        local lp = tonumber(lot.unitPrice) or 0
        local capturedAt = tonumber(lot.capturedAt) or 0
        local samePrice = math.abs(lp - unitPrice) < 1.01
        local sameSeller = seller == nil or seller == "" or lot.seller == nil or lot.seller == "" or lot.seller == seller
        local timeFits = purchaseTime <= 0 or capturedAt <= 0 or
            (capturedAt >= purchaseTime - 60 and capturedAt - purchaseTime <= MAIL_TSM_DEDUPE_WINDOW)

        if lq <= 0 then
            table.remove(lots, i)
        elseif samePrice and sameSeller and timeFits then
            local take = math.min(qty, lq)
            lot.qty = lq - take
            qty = qty - take
            matched = matched + take
            if lot.qty <= 0 then table.remove(lots, i) else i = i + 1 end
        else
            i = i + 1
        end
    end

    if #lots == 0 then mc.appliedLots[itemString] = nil end
    if matched > 0 then
        mc.tsmDedupedQty = mc.tsmDedupedQty + matched
        mc.tsmDedupedRecords = mc.tsmDedupedRecords + 1
    end
    return matched
end

local function RepairKnownTest6Race(db, currentQty, silent)
    -- No legacy player-specific repair fingerprints exist in the universal build.
    return 0
end

local function MailPendingTotals(db, itemString)
    local mc = EnsureMailCapture(db)
    local lots = mc.pendingLots[itemString]
    local qty, value, records = 0, 0, 0
    if type(lots) == "table" then
        for _, lot in ipairs(lots) do
            local lq = tonumber(lot.qty) or 0
            local lp = tonumber(lot.unitPrice) or 0
            if lq > 0 and lp >= 0 then
                qty = qty + lq
                value = value + lq * lp
                records = records + 1
            end
        end
    end
    return qty, value, records
end

local function QueueMailLot(db, itemString, qty, totalPaid, seller, signature)
    if not itemString or IsUniversalExcluded(itemString) then return false end
    if not db.items[itemString] then UBK_EnsurePurchasedItemForLedger(db, itemString, qty, time and time() or 0) end
    if not db.items[itemString] or not BASIS_SEEDS[itemString] then return false end
    qty = tonumber(qty) or 0
    totalPaid = tonumber(totalPaid) or 0
    if qty <= 0 or totalPaid <= 0 then return false end
    local mc = EnsureMailCapture(db)
    mc.pendingLots[itemString] = type(mc.pendingLots[itemString]) == "table" and mc.pendingLots[itemString] or {}
    local unitPrice = totalPaid / qty
    mc.pendingLots[itemString][#mc.pendingLots[itemString] + 1] = {
        qty = qty,
        unitPrice = unitPrice,
        totalPaid = totalPaid,
        seller = seller,
        capturedAt = time and time() or 0,
        signature = signature,
    }
    mc.capturedRecords = mc.capturedRecords + 1
    mc.capturedQty = mc.capturedQty + qty
    mc.capturedValue = mc.capturedValue + totalPaid
    return true, mc.pendingLots[itemString][#mc.pendingLots[itemString]]
end

local function DropMailLots(db, itemString, qty)
    qty = tonumber(qty) or 0
    if qty <= 0 then return 0 end
    local mc = EnsureMailCapture(db)
    local lots = mc.pendingLots[itemString]
    if type(lots) ~= "table" then return 0 end
    local dropped = 0
    local i = 1
    while i <= #lots and qty > 0 do
        local lot = lots[i]
        local lq = tonumber(lot.qty) or 0
        if lq <= 0 then
            table.remove(lots, i)
        else
            local take = math.min(qty, lq)
            lot.qty = lq - take
            qty = qty - take
            dropped = dropped + take
            if lot.qty <= 0 then table.remove(lots, i) else i = i + 1 end
        end
    end
    if #lots == 0 then mc.pendingLots[itemString] = nil end
    return dropped
end

local function ConsumePendingMailMatch(db, itemString, qty, unitPrice, seller, purchaseTime)
    qty = tonumber(qty) or 0
    unitPrice = tonumber(unitPrice) or 0
    purchaseTime = tonumber(purchaseTime) or 0
    if qty <= 0 or unitPrice <= 0 then return 0 end

    local mc = EnsureMailCapture(db)
    local lots = mc.pendingLots[itemString]
    if type(lots) ~= "table" then return 0 end

    local matched = 0
    local i = 1
    while i <= #lots and qty > 0 do
        local lot = lots[i]
        local lq = tonumber(lot.qty) or 0
        local lp = tonumber(lot.unitPrice) or 0
        local capturedAt = tonumber(lot.capturedAt) or 0
        local samePrice = math.abs(lp - unitPrice) < 1.01
        local sameSeller = seller == nil or seller == "" or lot.seller == nil or lot.seller == "" or lot.seller == seller
        local timeFits = purchaseTime <= 0 or capturedAt <= 0 or
            (capturedAt >= purchaseTime - 120 and capturedAt - purchaseTime <= MAIL_TSM_DEDUPE_WINDOW)

        if lq <= 0 then
            table.remove(lots, i)
        elseif samePrice and sameSeller and timeFits then
            local take = math.min(qty, lq)
            lot.qty = lq - take
            qty = qty - take
            matched = matched + take
            if lot.qty <= 0 then table.remove(lots, i) else i = i + 1 end
        else
            i = i + 1
        end
    end

    if #lots == 0 then mc.pendingLots[itemString] = nil end
    if matched > 0 then
        mc.tsmPendingDedupedQty = (tonumber(mc.tsmPendingDedupedQty) or 0) + matched
        mc.tsmPendingDedupedRecords = (tonumber(mc.tsmPendingDedupedRecords) or 0) + 1
    end
    return matched
end

local function ApplyMailLots(db, itemString, qtyNeeded)
    qtyNeeded = tonumber(qtyNeeded) or 0
    if qtyNeeded <= 0 then return 0, 0, 0 end
    local state = db.items[itemString]
    if not state then return 0, 0, 0 end
    local mc = EnsureMailCapture(db)
    local lots = mc.pendingLots[itemString]
    if type(lots) ~= "table" then return 0, 0, 0 end

    local appliedQty, appliedValue, appliedRecords = 0, 0, 0
    local i = 1
    while i <= #lots and qtyNeeded > 0 do
        local lot = lots[i]
        local lq = tonumber(lot.qty) or 0
        local lp = tonumber(lot.unitPrice) or 0
        if lq <= 0 or lp <= 0 then
            table.remove(lots, i)
        else
            local take = math.min(qtyNeeded, lq)
            local value = take * lp
            state.qty = (tonumber(state.qty) or 0) + take
            state.value = (tonumber(state.value) or 0) + value
            state.buysQty = (tonumber(state.buysQty) or 0) + take
            state.buysValue = (tonumber(state.buysValue) or 0) + value
            state.buysRecords = (tonumber(state.buysRecords) or 0) + 1
            state.buySources = type(state.buySources) == "table" and state.buySources or {}
            state.buySources["Auction Mail"] = (tonumber(state.buySources["Auction Mail"]) or 0) + take
            AddShredEligibleQty(state, take)
            if state.costProvenance ~= "manual-economic" then
                if state.costProvenance == "legacy-unverified" or (tonumber(state.bootstrapUnresolved) or 0) > 0 then
                    state.costProvenance = "partial-history"
                elseif state.costProvenance ~= "manual-acquisition" and state.costProvenance ~= "history-corroborated" and state.costProvenance ~= "accepted-opening" then
                    state.costProvenance = "mail-purchase"
                end
            end
            state.lastBuyer = UnitName("player") or state.lastBuyer
            state.lastBuyTime = math.max(tonumber(state.lastBuyTime) or 0, tonumber(lot.capturedAt) or 0)
            if state.qty > 0 then state.lastBasis = state.value / state.qty end
            RecordAppliedMailLot(db, itemString, take, lp, lot.seller, lot.capturedAt)

            lot.qty = lq - take
            qtyNeeded = qtyNeeded - take
            appliedQty = appliedQty + take
            appliedValue = appliedValue + value
            appliedRecords = appliedRecords + 1
            if lot.qty <= 0 then table.remove(lots, i) else i = i + 1 end
        end
    end
    if #lots == 0 then mc.pendingLots[itemString] = nil end
    mc.appliedRecords = mc.appliedRecords + appliedRecords
    mc.appliedQty = mc.appliedQty + appliedQty
    mc.appliedValue = mc.appliedValue + appliedValue
    return appliedQty, appliedValue, appliedRecords
end

local function GetInboxBuyerInvoice(index, subIndex)
    if type(GetInboxInvoiceInfo) ~= "function" or type(GetInboxItem) ~= "function" then return nil end
    local invoiceType, invoiceName, seller, bid, buyout, _, _, _, _, _, invoiceCount = GetInboxInvoiceInfo(index)
    if invoiceType ~= "buyer" then return nil end

    local attachmentIndex = tonumber(subIndex) or 1
    local itemName, itemID, _, attachmentCount = GetInboxItem(index, attachmentIndex)
    if not itemID and type(GetInboxItemLink) == "function" then
        local link = GetInboxItemLink(index, attachmentIndex)
        itemID = link and tonumber(link:match("item:(%d+)")) or nil
    end
    if not itemID then return nil end

    -- TSM 4.14.76 computes auction-buy unit price from invoice bid / invoice count,
    -- then records the attachment quantity. Mirror that behavior so mail fallback
    -- and durable TSM Accounting rows compare in the same units.
    local invoiceQty = tonumber(invoiceCount) or 0
    local attachmentQty = tonumber(attachmentCount) or 0
    local qty = attachmentQty > 0 and attachmentQty or invoiceQty
    if qty <= 0 then return nil end

    local paidInvoice = tonumber(bid) or 0
    if paidInvoice <= 0 then paidInvoice = tonumber(buyout) or 0 end
    if paidInvoice <= 0 then return nil end
    local unitPrice = invoiceQty > 0 and (paidInvoice / invoiceQty) or (paidInvoice / qty)
    local totalPaid = unitPrice * qty

    local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(index)
    daysLeft = tonumber(daysLeft) or 0
    local now = time and time() or 0
    local expectedPurchaseAt = (now > 0 and daysLeft > 0) and (now + (daysLeft - 30) * 86400) or 0
    return {
        itemString = "i:" .. tostring(itemID),
        name = itemName or invoiceName or ("Item " .. tostring(itemID)),
        qty = qty,
        totalPaid = totalPaid,
        unitPrice = unitPrice,
        seller = seller or "",
        subject = subject or "",
        daysLeft = daysLeft,
        expectedPurchaseAt = expectedPurchaseAt,
    }
end

function UBK_EnsurePurchasedItemForLedger(db, itemString, purchaseQty, purchaseTime)
    if not itemString or IsUniversalExcluded(itemString) then return nil end
    local state = db.items[itemString]
    if state then return state end

    local universal = EnsureUniversalState(db)
    universal.meta = type(universal.meta) == "table" and universal.meta or {}
    local itemID = tonumber(itemString:match("i:(%d+)"))
    local liveName = itemID and GetItemInfo and GetItemInfo(itemID) or nil
    local name = liveName or itemString
    local mats = UBK_GetTSMMatsTable and UBK_GetTSMMatsTable() or nil
    local isMaterial = type(mats) == "table" and type(mats[itemString]) == "table"
    universal.meta[itemString] = universal.meta[itemString] or {
        name = name, aliases = {tostring(tonumber(itemString:match("i:(%d+)")) or "")},
        trackedAt = time and time() or 0, source = "live-purchase", tsmMaterial = isMaterial,
    }
    if not BASIS_SEEDS[itemString] then BASIS_SEEDS[itemString] = {name=name, aliases=universal.meta[itemString].aliases or {}, custom=true} end
    EnsureOrderItem(itemString)

    local observed, haveInventory = GetRealmQuantityForItem(itemString)
    observed = haveInventory and observed or 0
    local q = math.max(0, tonumber(purchaseQty) or 0)
    state = {
        qty=0, value=0, lastBasis=0, pending=0,
        lastObserved=math.max(0, observed - q),
        buysQty=0, buysValue=0, buysRecords=0, lastBuyTime=0, lastBuyer=nil,
        buyers={}, buySources={}, unexplainedGain=0, bootstrapUnresolved=0,
        shredEligibleQty=0,
        cutoffTime=math.max(0, (tonumber(purchaseTime) or 0) - 1),
        autoDiscovered=true, stagedUniversal=isMaterial, tsmMaterial=isMaterial,
        trackingClass=isMaterial and "tsm-material" or "purchased-item",
        basisReady=false, seedSource="live-purchase-awaiting-ledger", costProvenance="unresolved",
        discoveredAt=time and time() or 0,
    }
    db.items[itemString] = state
    return state
end

local ProcessLedger
local RefreshCostReviews
local ApplyHistoricalCostAudit

local function MailInvoiceSignature(info)
    if not info then return nil end
    return table.concat({
        info.itemString or "", tostring(tonumber(info.qty) or 0), tostring(RoundCopper(info.totalPaid)),
        tostring(info.seller or ""), tostring(info.subject or "")
    }, "\031")
end

local function ClaimMatchingPendingMailLot(db, info)
    local mc = EnsureMailCapture(db)
    local lots = mc.pendingLots[info.itemString]
    if type(lots) ~= "table" then return false end
    local targetUnit = tonumber(info.unitPrice) or 0
    for _, lot in ipairs(lots) do
        if not lot.preLootClaimed
            and (tonumber(lot.qty) or 0) == (tonumber(info.qty) or 0)
            and math.abs((tonumber(lot.unitPrice) or 0) - targetUnit) <= 1
            and (tostring(lot.seller or "") == "" or tostring(info.seller or "") == "" or tostring(lot.seller or "") == tostring(info.seller or "")) then
            lot.preLootClaimed = true
            lot.preLootClaimedAt = time and time() or 0
            mc.preLootMatchedPending = (tonumber(mc.preLootMatchedPending) or 0) + 1
            return true
        end
    end
    return false
end

-- TSM normally records the auction purchase before the item is collected from mail.
-- If that durable Accounting row already exists, it is the authority and the mail
-- fallback must NOT queue the same purchase again. This function claims one matching
-- TSM row for one buyer invoice so identical auctions remain count-safe.
local function ClaimTSMAccountingForInvoice(db, info, index)
    if not info or not index then return false, false end
    local mc = EnsureMailCapture(db)
    local best = _G.UBKPurchaseLedger.FindInvoice(index, mc.tsmInvoiceClaims, info)
    if not best then return false, false end
    mc.tsmInvoiceClaims[best.line] = best.occurrence
    mc.tsmInvoiceMatchedRecords = (tonumber(mc.tsmInvoiceMatchedRecords) or 0) + 1
    mc.tsmInvoiceMatchedQty = (tonumber(mc.tsmInvoiceMatchedQty) or 0) + info.qty
    return true, (tonumber(db.processedCounts[best.line]) or 0) >= best.occurrence
end

mailLootHook.finalizeCapture = function(info, token)
    if not info or not IsSupportedRealm() then return false end
    local db = GetRealmDB()
    local mc = EnsureMailCapture(db)
    if not mc.armed or not db.items[info.itemString] or not BASIS_SEEDS[info.itemString] or IsUniversalExcluded(info.itemString) then
        return false
    end

    -- Do not inspect TSM Accounting here. TSM's MAIL_OPENING thread may still be
    -- mutating mailbox indices. Secure the copied invoice only; the settled ledger
    -- pass de-duplicates this fallback against TSM afterward.
    local matchedPending = ClaimMatchingPendingMailLot(db, info)
    if not matchedPending then
        local ok, lot = QueueMailLot(db, info.itemString, info.qty, info.totalPaid, info.seller, "preloot:" .. tostring(token or MailInvoiceSignature(info) or ""))
        if ok and lot then
            lot.preLootClaimed = true
            lot.preLootClaimedAt = time and time() or 0
        end
    end

    mc.preLootCapturedRecords = (tonumber(mc.preLootCapturedRecords) or 0) + 1
    mc.preLootCapturedQty = (tonumber(mc.preLootCapturedQty) or 0) + info.qty
    if mc.verbose then
        print(string.format("|cff33ff99UBK AH mail:|r secured %s x%d for %s.",
            BASIS_SEEDS[info.itemString].name,info.qty,FormatMoney(info.totalPaid)))
    end
    return true
end

mailLootHook.capturePreLoot = function(index, subIndex)
    if not IsSupportedRealm() or not mailboxSessionOpen or mailboxBaselinePending or not mailLootHook.captureArmed then return false end

    -- The synchronous hook is intentionally tiny: copy the invoice, mark the
    -- mailbox busy, schedule deferred bookkeeping, and immediately return control
    -- to TSM / Blizzard so attachment indices cannot go stale behind UBK work.
    local info = GetInboxBuyerInvoice(index, subIndex)
    if not info or not BASIS_SEEDS[info.itemString] or IsUniversalExcluded(info.itemString) then return false end

    local signature = MailInvoiceSignature(info) or ""
    local shortToken = table.concat({tostring(index or 0), tostring(subIndex or 1), signature}, "\031")
    -- Suppress only duplicate API calls against the SAME stable inbox state (for
    -- example AutoLootMailItem -> TakeInboxItem nesting). MAIL_INBOX_UPDATE clears
    -- this table, so a different identical auction which shifts into the same mail
    -- index is still captured normally.
    if mailLootHook.recentCalls[shortToken] then return false end
    mailLootHook.recentCalls[shortToken] = true

    mailLootHook.burstActive = true
    mailLootHook.settleGeneration = (tonumber(mailLootHook.settleGeneration) or 0) + 1
    local generation = mailLootHook.settleGeneration
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() mailLootHook.finalizeCapture(info, shortToken) end)
        C_Timer.After(1.50, function()
            if mailboxSessionOpen and generation == mailLootHook.settleGeneration then
                mailLootHook.burstActive = false
            end
        end)
    else
        mailLootHook.finalizeCapture(info, shortToken)
        mailLootHook.burstActive = false
    end
    return true
end

local function InstallMailLootHooks()
    if type(TakeInboxItem) == "function" and TakeInboxItem ~= mailLootHook.takeWrapper then
        local original = TakeInboxItem
        local wrapper
        wrapper = function(index, subIndex, ...)
            mailLootHook.capturePreLoot(index, subIndex)
            return original(index, subIndex, ...)
        end
        mailLootHook.originalTakeInboxItem = original
        mailLootHook.takeWrapper = wrapper
        TakeInboxItem = wrapper
        mailLootHook.installed = true
        mailLootHook.installedAt = time and time() or 0
    end

    if type(AutoLootMailItem) == "function" and AutoLootMailItem ~= mailLootHook.autoWrapper then
        local original = AutoLootMailItem
        local wrapper
        wrapper = function(index, ...)
            mailLootHook.capturePreLoot(index, nil)
            return original(index, ...)
        end
        mailLootHook.originalAutoLootMailItem = original
        mailLootHook.autoWrapper = wrapper
        AutoLootMailItem = wrapper
        mailLootHook.installed = true
        mailLootHook.installedAt = time and time() or 0
    end
end

local function ScanAuctionMail(silent, auditOnly)
    if not IsSupportedRealm() then return 0, 0 end
    if type(GetInboxNumItems) ~= "function" or type(GetInboxInvoiceInfo) ~= "function" then
        if not silent then print("|cffff7777UBK:|r auction-mail invoice API is unavailable on this client.") end
        return 0, 0
    end

    local db = GetRealmDB()
    local mc = EnsureMailCapture(db)
    local inboxItems = GetInboxNumItems()
    local numItems = tonumber(inboxItems) or 0
    local currentCounts = {}
    local infoBySignature = {}
    local visibleTracked, visibleQty = 0, 0

    for index = 1, numItems do
        local info = GetInboxBuyerInvoice(index)
        if info and db.items[info.itemString] and BASIS_SEEDS[info.itemString] and not IsUniversalExcluded(info.itemString) then
            local signature = table.concat({info.itemString, tostring(info.qty), tostring(RoundCopper(info.totalPaid)), info.seller or "", info.subject or ""}, "\031")
            currentCounts[signature] = (currentCounts[signature] or 0) + 1
            infoBySignature[signature] = info
            visibleTracked = visibleTracked + 1
            visibleQty = visibleQty + info.qty
            if auditOnly and not silent then
                print(string.format("  %s: %d for %s (%s each)%s", BASIS_SEEDS[info.itemString].name, info.qty, FormatMoney(info.totalPaid), FormatMoney(info.unitPrice), info.seller ~= "" and (" from " .. info.seller) or ""))
            end
        end
    end

    if auditOnly then
        if not silent then print(string.format("|cffffcc00UBK mail audit:|r %d tracked buyer invoice(s), %d unit(s) currently visible.", visibleTracked, visibleQty)) end
        return visibleTracked, visibleQty
    end

    if not mc.armed then
        mc.activeCounts = currentCounts
        mc.armed = true
        mc.armedAt = time and time() or 0
        mc.lastScanAt = mc.armedAt
        if not silent then
            print(string.format("|cff33ff99UBK:|r Auction-mail capture ARMED with %d existing tracked buyer invoice(s) baselined. Future new invoices will be costed; existing mail was not imported.", visibleTracked))
        end
        return 0, 0
    end

    local now=time and time() or 0
    local index=_G.UBKPurchaseLedger.InvoiceIndex(GetTSMBuyLedger(),ParseBuyLine,
        math.max(tonumber(db.cutoffTime) or BASIS_CUTOVER_TIME,now-7*86400),now,UnitName and UnitName("player"))
    local newRecords, newQty = 0, 0
    for signature, count in pairs(currentCounts) do
        local previous = tonumber(mc.activeCounts[signature]) or 0
        local claimed = tonumber(mc.preLootVisibleClaims[signature]) or 0
        local growth = math.max(0, count - previous)
        if growth > 0 and claimed > 0 then
            local skip = math.min(growth, claimed)
            growth = growth - skip
            mc.preLootVisibleClaims[signature] = claimed - skip
        end
        if growth > 0 then
            local info = infoBySignature[signature]
            for _ = 1, growth do
                local tsmMatched, alreadyProcessed = ClaimTSMAccountingForInvoice(db, info, index)
                if tsmMatched then
                    mc.preLootBypass[signature] = (tonumber(mc.preLootBypass[signature]) or 0) + 1
                    if not silent then
                        print(string.format("|cff33ff99UBK AH mail:|r matched %s x%d at %s each to TSM Accounting%s; fallback not needed.",
                            BASIS_SEEDS[info.itemString].name, info.qty, FormatMoney(info.unitPrice), alreadyProcessed and " [already costed]" or ""))
                    end
                elseif QueueMailLot(db, info.itemString, info.qty, info.totalPaid, info.seller, signature) then
                    newRecords = newRecords + 1
                    newQty = newQty + info.qty
                    if not silent then
                        print(string.format("|cff33ff99UBK AH mail:|r captured %s x%d for %s (%s each) as fallback.", BASIS_SEEDS[info.itemString].name, info.qty, FormatMoney(info.totalPaid), FormatMoney(info.unitPrice)))
                    end
                end
            end
        end
    end
    mc.activeCounts = currentCounts
    mc.lastScanAt = time and time() or 0
    return newRecords, newQty
end

local function FinishMailboxBaseline()
    local db = GetRealmDB()
    local mc = EnsureMailCapture(db)
    if mc.importNext and not mc.armed then
        -- Explicit user opt-in: treat every currently visible tracked buyer invoice
        -- as a new acquisition instead of baselining it away.
        mc.armed = true
        mc.activeCounts = {}
        mc.importNext = false
        local records, qty = ScanAuctionMail(false, false)
        print(string.format("|cff33ff99UBK:|r imported %d current tracked buyer invoice(s) / %d unit(s) and ARMED capture.", records or 0, qty or 0))
    else
        ScanAuctionMail(false, false)
    end
    mailboxBaselinePending = false
    mailLootHook.captureArmed = mc.armed == true
    ProcessLedger(true)
end

local function SetupAllowsProcessing(db)
    return type(db)=="table" and type(db.setup)=="table" and (db.setup.status=="review" or db.setup.status=="complete")
end

ProcessLedger = function(silent, receiptPass, prepared)
    if not IsSupportedRealm() then return 0, 0 end
    -- Record transaction evidence while windows are open; settle after close.
    local mailBusy=mailboxSessionOpen and mailLootHook.burstActive
    if mailboxSessionOpen or _G.UBKPurchaseLedger.AnySourceOpen() then return 0, 0 end
    if _G.UBKPurchaseLedger.settlementPending and not prepared then return 0, 0 end
    if _G.UBKInternal and _G.UBKInternal.AuctionBusy and _G.UBKInternal.AuctionBusy() then
        _G.UBKInternal.DeferAuctionRefresh()
        return 0, 0
    end
    TryLegacyMigration(true)

    local db = GetRealmDB()
    if not SetupAllowsProcessing(db) then return 0, 0 end
    -- Let an optional legacy sale observer capture newly appended rows against the current
    -- pre-outflow basis state. Its byte-length gate makes unchanged ledgers an
    -- O(1) check, while this ordering prevents sold unresolved units from being
    -- mistaken for fully costed inventory after reconciliation.
    if type(_G.UBKZippy_ProcessSales)=="function" then pcall(_G.UBKZippy_ProcessSales,false) end
    if not mailBusy and DiscoverUniversalMaterials then DiscoverUniversalMaterials(db, true) end
    if not mailBusy and ApplyHistoricalCostAudit then ApplyHistoricalCostAudit(db, true) end
    if not mailBusy and _G.UBKShredderInternal and _G.UBKShredderInternal.CaptureNewHistory then
        _G.UBKShredderInternal.CaptureNewHistory(db, true)
    end
    local csv = prepared and "" or GetTSMBuyLedger()
    if not csv then
        if not silent then print("|cffffcc00UBK:|r TSM's buy ledger is not available yet.") end
        csv="" -- Invoice-backed arrivals still reconcile without a CSV snapshot.
    end

    local currentQty, haveInventory = {},false
    if not mailBusy then currentQty,haveInventory=GetRealmTrackedQuantities(false) end
    local changed = false
    if haveInventory and RepairKnownTest6Race(db, currentQty, silent) > 0 then changed = true end

    -- Settle already-visible outflow before new buys are folded in. This preserves
    -- moving-average chronology when TSM's inventory cache is current.
    if haveInventory then
        for itemString, state in pairs(db.items) do
            local observed = currentQty[itemString] or 0
            local lastObserved = tonumber(state.lastObserved) or ((tonumber(state.qty) or 0) + (tonumber(state.bootstrapUnresolved) or 0))
            local pending = tonumber(state.pending) or 0
            if pending <= 0 and observed < lastObserved then
                if _G.UBKProspectingSessions then _G.UBKProspectingSessions:NoteOutflow(itemString) end
                local outflow = lastObserved - observed
                local unresolved = tonumber(state.bootstrapUnresolved) or 0
                if unresolved > 0 then
                    local take = math.min(unresolved, outflow)
                    local removed = ReduceUnresolvedForOutflow(state, take)
                    outflow = outflow - removed
                    if removed > 0 then changed = true end
                end
                if outflow > 0 and (tonumber(state.qty) or 0) > 0 then
                    local targetQty = math.max(0, (tonumber(state.qty) or 0) - outflow)
                    if ApplyOutflow(state, targetQty) > 0 then changed = true end
                end
            end
        end
    end

    _G.UBKPurchaseLedger.Prepare(db)
    local seenCounts,seenUnits = {},{}
    local addedQty = 0
    local addedValue = 0
    local addedRecords = 0
    local addedByItem = {}
    local maxSeenTime = prepared and prepared.maxSeenTime or db.lastLedgerTime or db.cutoffTime or BASIS_CUTOVER_TIME
    local factionCharacters = UBK_CurrentFactionCharacters()

    for line,itemString,qty,price,timestamp,buyer,seller,source,preparedOccurrence,preparedUnits,preparedKey
        in _G.UBKPurchaseLedger.Iterate(csv,prepared,ParseBuyLine) do
        local state = itemString and db.items[itemString] or nil
        if itemString and qty and price and timestamp and factionCharacters[buyer or ""] and not state then
            state = UBK_EnsurePurchasedItemForLedger(db, itemString, qty, timestamp)
        end
        local itemCutoff = state and (tonumber(state.cutoffTime) or tonumber(db.cutoffTime) or BASIS_CUTOVER_TIME) or nil
        if itemString and state and BASIS_SEEDS[itemString] and factionCharacters[buyer or ""] and timestamp > itemCutoff then
            seenCounts[line] = (seenCounts[line] or 0) + 1
            local occurrence = preparedOccurrence or seenCounts[line]
            local newQty,quantityKey,quantitySeen
            if preparedUnits then
                quantityKey,quantitySeen=preparedKey,preparedUnits
                newQty=math.min(qty,math.max(0,preparedUnits-(tonumber(db.processedPurchaseQty[preparedKey]) or 0)))
            else newQty,quantityKey,quantitySeen=_G.UBKPurchaseLedger.Take(db,seenUnits,line,qty) end
            if newQty > 0 then
                qty=newQty
                local mailMatched = 0
                if source == "Auction" then
                    -- Pending mail fallback is discarded when the matching durable TSM
                    -- row arrives; an already-applied fallback is deducted from this row.
                    ConsumePendingMailMatch(db, itemString, qty, price, seller, timestamp)
                    mailMatched = ConsumeAppliedMailMatch(db, itemString, qty, price, seller, timestamp)
                end

                local accountQty = math.max(0, qty - mailMatched)
                if accountQty > 0 then
                    local purchaseValue = accountQty * price
                    local lateMatched = MatchUnresolvedLotsToLedger(state, accountQty, timestamp)

                    state.qty = (tonumber(state.qty) or 0) + accountQty
                    state.value = (tonumber(state.value) or 0) + purchaseValue
                    state.pending = (tonumber(state.pending) or 0) + math.max(0, accountQty - lateMatched)
                    if state.qty > 0 then state.lastBasis = state.value / state.qty end
                    state.buysQty = (tonumber(state.buysQty) or 0) + accountQty
                    state.buysValue = (tonumber(state.buysValue) or 0) + purchaseValue
                    state.buysRecords = (tonumber(state.buysRecords) or 0) + 1
                    state.lastBuyTime = math.max(tonumber(state.lastBuyTime) or 0, timestamp)
                    state.lastBuyer = buyer or state.lastBuyer
                    state.buyers = type(state.buyers) == "table" and state.buyers or {}
                    state.buySources = type(state.buySources) == "table" and state.buySources or {}
                    if buyer and buyer ~= "" then
                        state.buyers[buyer] = (tonumber(state.buyers[buyer]) or 0) + accountQty
                    end
                    if source and source ~= "" then
                        state.buySources[source] = (tonumber(state.buySources[source]) or 0) + accountQty
                    end
                    if source == "Auction" or source == "Trade" then
                        AddShredEligibleQty(state, accountQty)
                    end
                    if state.costProvenance ~= "manual-economic" then
                        if state.costProvenance == "legacy-unverified" or (tonumber(state.bootstrapUnresolved) or 0) > 0 then
                            state.costProvenance = "partial-history"
                        elseif state.costProvenance == "manual-loot-basis" then
                            state.costProvenance = "mixed-trusted"
                        elseif state.costProvenance ~= "manual-acquisition" and state.costProvenance ~= "history-corroborated" and state.costProvenance ~= "accepted-opening" then
                            state.costProvenance = "purchase-ledger"
                        end
                    end
                    if state.autoDiscovered and (tonumber(state.bootstrapUnresolved) or 0) <= 0 then
                        state.basisReady = true
                    end

                    addedQty = addedQty + accountQty
                    addedValue = addedValue + purchaseValue
                    addedRecords = addedRecords + 1
                    addedByItem[itemString] = (addedByItem[itemString] or 0) + accountQty
                    changed = true
                elseif mailMatched > 0 then
                    changed = true
                end

                db.processedPurchaseQty[quantityKey]=quantitySeen
                db.processedCounts[line] = occurrence
            end
            if timestamp > maxSeenTime then maxSeenTime = timestamp end
        end
    end

    db.lastLedgerTime = maxSeenTime

    -- Let TSM's realm inventory cache confirm that ledger buys physically arrived.
    if haveInventory then
        for itemString, state in pairs(db.items) do
            local observed = currentQty[itemString] or 0
            local lastObserved = tonumber(state.lastObserved) or observed
            local pending = tonumber(state.pending) or 0

            if observed > lastObserved and pending > 0 then
                local increase = observed - lastObserved
                local settled = math.min(pending, increase)
                local newPending = math.max(0, pending - increase)
                if newPending ~= pending then changed = true end
                state.pending = newPending
                -- If a TSM-accounted purchase and its AH invoice were both visible,
                -- TSM wins. Drop the same quantity from the mail fallback queue.
                if settled > 0 then DropMailLots(db, itemString, settled) end
            end

            local unresolved = tonumber(state.bootstrapUnresolved) or 0
            local modeled = (tonumber(state.qty) or 0) + unresolved
            if (tonumber(state.pending) or 0) <= 0 and observed < modeled then
                if _G.UBKProspectingSessions then _G.UBKProspectingSessions:NoteOutflow(itemString) end
                local outflow = modeled - observed
                if unresolved > 0 then
                    local take = math.min(unresolved, outflow)
                    local removed = ReduceUnresolvedForOutflow(state, take)
                    unresolved = tonumber(state.bootstrapUnresolved) or 0
                    outflow = outflow - removed
                    if removed > 0 then changed = true end
                end
                if outflow > 0 and (tonumber(state.qty) or 0) > 0 then
                    local targetQty = math.max(0, (tonumber(state.qty) or 0) - outflow)
                    if ApplyOutflow(state, targetQty) > 0 then changed = true end
                end
            elseif (tonumber(state.pending) or 0) <= 0 and observed > modeled then
                local gain = observed - modeled
                local mailQty, _, mailRecords = ApplyMailLots(db, itemString, gain)
                if mailQty > 0 then
                    gain = gain - mailQty
                    modeled = modeled + mailQty
                    changed = true
                    if not silent then
                        print(string.format("|cff33ff99UBK:|r matched %d %s unit%s to %d Auction House buyer-mail invoice%s; basis is now %s.",
                            mailQty, BASIS_SEEDS[itemString].name, mailQty == 1 and "" or "s", mailRecords, mailRecords == 1 and "" or "s", FormatMoney(GetUnitBasis(state))))
                    end
                end
                if gain>0 and _G.UBKProspectAccounting and _G.UBKProspectingSessions then
                    local reserved=_G.UBKProspectAccounting.ReserveGain(state,itemString,gain)
                    gain=gain-reserved;modeled=modeled+reserved
                    if reserved>0 then changed=true end
                end
                if gain > 0 and _G.UBKLootInternal and _G.UBKLootInternal.ApplyObservedGain then
                    local lootMatched = _G.UBKLootInternal.ApplyObservedGain(db, itemString, state, gain, silent)
                    if lootMatched and lootMatched > 0 then
                        gain = math.max(0, gain - lootMatched)
                        modeled = modeled + lootMatched
                        unresolved = tonumber(state.bootstrapUnresolved) or 0
                        changed = true
                    end
                end
                if gain > 0 then
                    AddUnresolvedLot(state, gain, "unexplained")
                    unresolved = tonumber(state.bootstrapUnresolved) or 0
                    changed = true
                end
            end

            state.unexplainedGain = tonumber(state.bootstrapUnresolved) or 0
            if state.autoDiscovered then
                state.basisReady = GetUnitBasis(state) > 0
            end
            state.lastObserved = observed
        end
    end

    db.lastProcessor = UnitName("player")
    db.lastProcessAt = time and time() or 0
    if changed then db.activitySinceSeed = true end

    if addedRecords > 0 and not silent then
        print(string.format("|cff33ff99UBK:|r folded in %d new TSM purchase record%s, %d tracked item unit%s, %s spent.",
            addedRecords, addedRecords == 1 and "" or "s",
            addedQty, addedQty == 1 and "" or "s", FormatMoney(addedValue)))
        for _, itemString in ipairs(BASIS_ORDER) do
            if addedByItem[itemString] then
                local seed = BASIS_SEEDS[itemString]
                local state = db.items[itemString]
                print(string.format("  %s: +%d -> %s basis", seed.name, addedByItem[itemString], FormatMoney(GetUnitBasis(state))))
            end
        end
    end

    if not mailBusy and _G.UBKShredderInternal and _G.UBKShredderInternal.SettlePendingTransforms then
        if _G.UBKShredderInternal.SettlePendingTransforms(db, silent) > 0 then changed = true end
    end
    if not mailBusy and _G.UBKProspectingSessions then _G.UBKProspectingSessions:Settle() end
    if RefreshCostReviews then RefreshCostReviews(db, false) end
    if AutoSyncTSM then AutoSyncTSM(true) end
    return addedRecords, addedQty
end

local function GetTSMVersion()
    local getter = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    if not getter then return nil end
    local ok, value = pcall(getter, "TradeSkillMaster", "Version")
    if ok then return value end
    return nil
end

local function FormatTSMPrice(copper)
    copper = RoundCopper(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then
        return string.format("%dg%02ds%02dc", g, s, c)
    elseif s > 0 then
        return string.format("%ds%02dc", s, c)
    else
        return string.format("%dc", c)
    end
end

function UBK_GetTSMMatsTable()
    RefreshRuntimeKeys()
    if type(TradeSkillMasterDB) ~= "table" then
        return nil, "TradeSkillMasterDB is not loaded"
    end
    local mats = TradeSkillMasterDB[TSM_MATS_KEY]
    if type(mats) ~= "table" then
        return nil, "TSM material table is unavailable"
    end
    return mats
end

local function GetTSMCustomValue(itemString)
    local mats = UBK_GetTSMMatsTable()
    if not mats then return nil, false end
    local entry = mats[itemString]
    if type(entry) ~= "table" then return nil, false end
    return entry.customValue, true
end


local function EnsureCostReviewState(db)
    if type(db.costAudit) ~= "table" then db.costAudit = {} end
    db.costAudit.schema = COST_AUDIT_SCHEMA
    if type(db.costAudit.applied) ~= "table" then db.costAudit.applied = {} end
    if type(db.costReview) ~= "table" then db.costReview = {} end
    db.costReview.schema = REVIEW_SCHEMA
    if type(db.costReview.items) ~= "table" then db.costReview.items = {} end
    return db.costAudit, db.costReview
end

local AUDIT_VERSION = "universal-v1"

local function CostAuditClass(itemString)
    local manual = MANUAL_ECONOMIC_VALUES[itemString]
    if manual then return "manual-economic", manual end
    local audit = HISTORICAL_COST_AUDIT[itemString]
    if not audit then return "no-audit", nil end
    local sq = tonumber(audit.snapshotQty) or 0
    local rq = tonumber(audit.retainedQty) or 0
    if sq > 0 and rq >= sq and (tonumber(audit.retainedBasis) or 0) > 0 then
        return "history-full", audit
    elseif rq > 0 and (tonumber(audit.retainedBasis) or 0) > 0 then
        return "history-partial", audit
    elseif (tonumber(audit.historyQty) or 0) > 0 then
        return "historical-only", audit
    end
    return "legacy-unverified", audit
end

local function CostProvenanceLabel(state, itemString)
    if state and state.userCostClassification then return state.userCostClassification end
    if state and state.costProvenance then return state.costProvenance end
    if MANUAL_ECONOMIC_VALUES[itemString] then return "manual-economic" end
    if state then
        if state.protectedFormula and not state.formulaOverride then return "formula-protected" end
        if state.manuallySeeded then return "manual-acquisition" end
        if not state.autoDiscovered and BASIS_SEEDS[itemString] and BASIS_SEEDS[itemString].qty and BASIS_SEEDS[itemString].basis then
            return "accepted-opening"
        end
        local source = tostring(state.seedSource or "")
        if source == "retained-purchases" then return "purchase-history" end
        if source == "partial-purchase-history" then return "partial-history" end
        if source == "existing-literal" or source == "legacy-literal-unverified" then return "legacy-unverified" end
        if source == "retained-purchases+existing-literal" then return "partial-history" end
        if (tonumber(state.buysQty) or 0) > 0 then return "purchase-ledger" end
    end
    local class = CostAuditClass(itemString)
    return class
end

local PROVENANCE_DISPLAY = {
    ["history-corroborated"] = "HISTORY-CORROBORATED OPENING",
    ["accepted-opening"] = "ACCEPTED OPENING BASIS",
    ["manual-acquisition"] = "MANUAL ACQUISITION COST",
    ["manual-loot-basis"] = "MANUAL LOOT / FARMED BASIS",
    ["manual-economic"] = "MANUAL ECONOMIC VALUE",
    ["purchase-history"] = "TSM PURCHASE HISTORY",
    ["partial-history"] = "PARTIAL KNOWN COST",
    ["purchase-ledger"] = "LIVE TSM PURCHASE LEDGER",
    ["mail-purchase"] = "AH BUYER-MAIL FALLBACK",
    ["shredder-transfer"] = "SHREDDER TRANSFER",
    ["mixed-trusted"] = "MIXED TRUSTED ACQUISITION",
    ["legacy-unverified"] = "LEGACY LITERAL - REVIEW",
    ["formula-protected"] = "TSM FORMULA - PROTECTED",
    ["historical-only"] = "HISTORICAL PURCHASE EVIDENCE",
    ["history-full"] = "HISTORICAL PURCHASE EVIDENCE",
    ["history-partial"] = "PARTIAL HISTORICAL EVIDENCE",
    ["unresolved"] = "UNRESOLVED",
    ["no-audit"] = "NO HISTORICAL AUDIT",
}

local function CostProvenanceDisplay(state, itemString)
    local p = CostProvenanceLabel(state, itemString)
    return PROVENANCE_DISPLAY[p] or tostring(p or "unknown")
end

local function CostTrustedForRadar(state, itemString)
    if IsUniversalExcluded(itemString) then return false end
    if state and state.needsCostReview then return false end
    local provenance = CostProvenanceLabel(state, itemString)
    if provenance == "manual-economic" or provenance == "legacy-unverified" or provenance == "no-audit"
        or provenance == "formula-protected" or provenance == "unresolved" then
        return false
    end
    if provenance == "manual-acquisition" or provenance == "manual-loot-basis" or provenance == "accepted-opening" or provenance == "history-corroborated"
        or provenance == "purchase-history" or provenance == "partial-history" or provenance == "purchase-ledger"
        or provenance == "mail-purchase" or provenance == "historical-only" or provenance == "history-full"
        or provenance == "history-partial" or provenance == "shredder-transfer" or provenance == "mixed-trusted" then
        return state and GetUnitBasis(state) > 0
    end
    if state and ((tonumber(state.buysQty) or 0) > 0 or (tonumber(state.buysRecords) or 0) > 0) then
        return GetUnitBasis(state) > 0
    end
    return false
end

local function ReviewFingerprint(customValue, unresolved, observed, reason)
    -- Quantity changes (especially while collecting mail) and UBK's own moving
    -- mycost writes must not spam review alerts. A review re-alerts only if its
    -- provenance question / anchored legacy value changes, or after it is cleared
    -- and later becomes open again.
    return tostring(customValue or "<none>") .. "|" .. tostring(reason or "")
end

local function QueueCostReview(db, itemString, reason, quiet)
    if _G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(itemString) then return false end
    if IsUniversalExcluded(itemString) then return false end
    if not db or not itemString or not BASIS_SEEDS[itemString] then return false end
    local _, review = EnsureCostReviewState(db)
    local state = db.items[itemString]
    local custom = GetTSMCustomValue(itemString)
    local unresolved = state and (tonumber(state.bootstrapUnresolved) or 0) or 0
    local observed = state and (tonumber(state.lastObserved) or ((tonumber(state.qty) or 0) + unresolved)) or 0
    local row = review.items[itemString]
    if type(row) ~= "table" then row = {}; review.items[itemString] = row end
    row.itemString = itemString
    row.reason = reason or row.reason or "Unverified legacy literal"
    if not row.open or row.referenceValue == nil then
        local audited = state and tonumber(state.auditLegacyLiteral) or nil
        row.referenceValue = (audited and audited > 0) and FormatMoney(audited) or custom
    end
    row.customValue = row.referenceValue or custom
    row.currentValue = custom
    row.unresolved = unresolved
    row.observed = observed
    row.open = true
    row.updatedAt = time and time() or 0
    local fingerprint = ReviewFingerprint(row.customValue, unresolved, observed, row.reason)
    if row.lastAlertFingerprint ~= fingerprint then
        if quiet then
            row.pendingAlertFingerprint = fingerprint
            return false
        end
        row.lastAlertFingerprint = fingerprint
        row.pendingAlertFingerprint = nil
        row.lastAlertAt = row.updatedAt
        print(string.format("|cffff9933UBK REVIEW:|r %s needs a cost decision: %d unresolved / %d observed; custom value %s. %s. Use |cffffffff/ubk detail [%s]|r or |cffffffff/ubk review|r.",
            BASIS_SEEDS[itemString].name, unresolved, observed, tostring(custom or "<none>"), tostring(row.reason or "Historical provenance needs review"), BASIS_SEEDS[itemString].name))
        return true
    end
    return false
end

local function ClearCostReview(db, itemString)
    local _, review = EnsureCostReviewState(db)
    local row = review.items[itemString]
    if type(row) == "table" then
        if row.open then
            -- A genuinely resolved review may alert again if a future condition
            -- opens a new review. Repeated refreshes while open remain silent.
            row.lastAlertFingerprint = nil
            row.pendingAlertFingerprint = nil
            row.referenceValue = nil
        end
        row.open = false
        row.resolvedAt = time and time() or 0
    end
end

RefreshCostReviews = function(db, quiet)
    if not db then return end
    local mats = UBK_GetTSMMatsTable()
    for itemString, state in pairs(db.items or {}) do
        if IsUniversalExcluded(itemString) or (_G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(itemString)) then
            ClearCostReview(db,itemString)
        elseif BASIS_SEEDS[itemString] then
            local current = mats and mats[itemString] and mats[itemString].customValue or nil
            local provenance = CostProvenanceLabel(state, itemString)
            local unresolved = tonumber(state.bootstrapUnresolved) or 0
            local observed = tonumber(state.lastObserved) or ((tonumber(state.qty) or 0) + unresolved)
            local literalExists = IsLiteralMoney(current)
            local importUnresolved = type(db.setup)=="table" and db.setup.historyMode=="import" and unresolved>0 and observed>0 and state.userCostClassification~="leave-unresolved"
            local lootReview = state.firstSeenLootReview == true and unresolved > 0 and observed > 0 and state.userCostClassification ~= "leave-unresolved"
            if ((state.needsCostReview or provenance == "legacy-unverified") and literalExists and observed > 0) or importUnresolved or lootReview then
                QueueCostReview(db, itemString, state.reviewReason or (lootReview and "First-seen looted inventory has no established UBK basis" or (literalExists and "Existing literal lacks sufficient acquisition evidence" or "Some inventory has no proven acquisition cost")), quiet)
            else
                ClearCostReview(db, itemString)
            end
        end
    end
end

ApplyHistoricalCostAudit = function(db, quiet)
    if not db then return 0 end
    local costAudit = EnsureCostReviewState(db)
    local changed = 0

    for itemString, state in pairs(db.items or {}) do
        if state.costAuditVersion ~= AUDIT_VERSION then
            local audit = HISTORICAL_COST_AUDIT[itemString]
            local manual = MANUAL_ECONOMIC_VALUES[itemString]
            if audit then
                local auditedName = tostring(audit.name or "")
                local seed = BASIS_SEEDS[itemString]
                if auditedName ~= "" and seed and (not seed.name or tostring(seed.name):match("^Item %d+$")) then
                    seed.name = auditedName
                    local universal = EnsureUniversalState(db)
                    if type(universal.meta[itemString]) == "table" then universal.meta[itemString].name = auditedName end
                end
                state.auditSnapshotQty = tonumber(audit.snapshotQty) or 0
                state.auditRetainedQty = tonumber(audit.retainedQty) or 0
                state.auditRetainedBasis = tonumber(audit.retainedBasis) or 0
                state.auditHistoryQty = tonumber(audit.historyQty) or 0
                state.auditHistoryAvg = tonumber(audit.historyAvg) or 0
                state.auditHistoryRecords = tonumber(audit.historyRecords) or 0
                state.auditLastPurchaseAt = tonumber(audit.lastPurchaseAt) or 0
                state.auditLegacyLiteral = tonumber(audit.literal) or 0
                state.auditReference = tostring(audit.reference or "2026-08-31-084556")
            end

            if state.userCostClassification == "manual-economic" or state.userCostClassification == "manual-acquisition" then
                state.costProvenance = state.userCostClassification
                state.needsCostReview = false
                ClearCostReview(db, itemString)
            elseif manual then
                state.costProvenance = "manual-economic"
                state.economicValue = tonumber(manual.value) or 0
                state.provenanceNote = manual.note
                state.needsCostReview = false
                ClearCostReview(db, itemString)
                changed = changed + 1
            elseif state.manuallySeeded then
                state.costProvenance = "manual-acquisition"
                local manualBasis = GetUnitBasis(state)
                local auditBasis = audit and (tonumber(audit.retainedBasis) or 0) or 0
                local full = audit and (tonumber(audit.snapshotQty) or 0) > 0 and (tonumber(audit.retainedQty) or 0) >= (tonumber(audit.snapshotQty) or 0)
                local delta = full and manualBasis > 0 and auditBasis > 0 and math.abs(manualBasis - auditBasis) / auditBasis or nil
                state.auditOpeningDelta = delta
                if full and delta and delta > 0.20 then
                    state.provenanceNote = string.format("Manual acquisition basis retained, but preserved purchase evidence differs %.1f%%; human review requested before Radar trusts it.", delta * 100)
                    state.reviewReason = "Manual acquisition basis differs materially from preserved purchase evidence"
                    state.needsCostReview = true
                else
                    state.provenanceNote = state.provenanceNote or (full and delta and string.format("Manual acquisition basis is supported by preserved purchase evidence (retained-lot estimate differs %.1f%%).", delta * 100)
                        or "Explicitly seeded acquisition basis; account-local provenance retained as supporting evidence when available.")
                    state.needsCostReview = false
                end
            elseif not state.autoDiscovered and BASIS_SEEDS[itemString] and BASIS_SEEDS[itemString].qty and BASIS_SEEDS[itemString].basis then
                local opening = tonumber(BASIS_SEEDS[itemString].basis) or 0
                local auditBasis = audit and (tonumber(audit.retainedBasis) or 0) or 0
                local full = audit and (tonumber(audit.snapshotQty) or 0) > 0 and (tonumber(audit.retainedQty) or 0) >= (tonumber(audit.snapshotQty) or 0)
                local delta = full and auditBasis > 0 and math.abs(opening - auditBasis) / auditBasis or nil
                state.auditOpeningDelta = delta
                if full and delta and delta <= 0.20 then
                    state.costProvenance = "history-corroborated"
                    state.provenanceNote = string.format("Accepted UBK opening basis is corroborated by preserved purchase history (retained-lot estimate differs %.1f%%).", delta * 100)
                    state.needsCostReview = false
                else
                    state.costProvenance = "accepted-opening"
                    state.provenanceNote = full and "Accepted UBK opening basis retained; preserved history differs materially, so it is flagged for human review rather than silently rewritten."
                        or "Accepted UBK opening basis retained; preserved TSM history does not fully cover the opening inventory, so Radar will not trust it until reviewed."
                    state.reviewReason = full and "Accepted opening basis differs materially from preserved purchase evidence"
                        or "Accepted opening basis is not fully covered by preserved purchase history"
                    state.needsCostReview = true
                end
            elseif state.autoDiscovered then
                local source = tostring(state.seedSource or "")
                if state.protectedFormula and not state.formulaOverride then
                    state.costProvenance = "formula-protected"
                    state.needsCostReview = false
                elseif source == "retained-purchases" then
                    state.costProvenance = "purchase-history"
                    state.provenanceNote = "Known-cost pool came directly from retained TSM purchase history."
                    state.needsCostReview = false
                elseif source == "partial-purchase-history" then
                    state.costProvenance = "partial-history"
                    state.provenanceNote = "Known units came from TSM purchase history; remaining units stay unresolved and excluded."
                    state.needsCostReview = false
                elseif source == "existing-literal" or source == "legacy-literal-unverified" then
                    local buys = tonumber(state.buysQty) or 0
                    if buys <= 0 then
                        -- Earlier builds could promote every observed unit to known cost solely
                        -- because TSM contained a literal. Undo only that unsafe seed.
                        local observed = tonumber(state.lastObserved) or ((tonumber(state.qty) or 0) + (tonumber(state.bootstrapUnresolved) or 0))
                        if (tonumber(state.qty) or 0) > 0 then
                            state.qty = 0
                            state.value = 0
                            state.lastBasis = 0
                            state.bootstrapUnresolved = math.max(tonumber(state.bootstrapUnresolved) or 0, observed)
                            state.unexplainedGain = state.bootstrapUnresolved
                            changed = changed + 1
                        end
                        state.seedSource = "legacy-literal-unverified"
                        state.costProvenance = "legacy-unverified"
                        state.provenanceNote = "Existing TSM literal had no acquisition evidence; inventory was returned to unresolved for review."
                        state.reviewReason = "Existing literal was previously used as cost without purchase evidence"
                        state.needsCostReview = observed > 0
                    else
                        state.costProvenance = "partial-history"
                        state.provenanceNote = "Real post-cutover purchases exist, but the older literal-seeded component is not independently proven."
                        state.reviewReason = "Real purchases are mixed with an older unverified literal-seeded component"
                        state.needsCostReview = true
                    end
                elseif source == "retained-purchases+existing-literal" then
                    state.costProvenance = "partial-history"
                    state.provenanceNote = "Purchase-backed units are trusted; literal-padded opening units require review."
                    state.reviewReason = "Opening pool mixed purchase history with a legacy literal"
                    state.needsCostReview = true
                elseif source == "zero-stock-awaiting-acquisition" or source == "unresolved" then
                    state.costProvenance = "unresolved"
                    state.needsCostReview = false
                elseif (tonumber(state.buysQty) or 0) > 0 then
                    state.costProvenance = "purchase-ledger"
                    state.needsCostReview = false
                end
            elseif (tonumber(state.buysQty) or 0) > 0 then
                state.costProvenance = "purchase-ledger"
                state.needsCostReview = false
            end

            state.costAuditVersion = AUDIT_VERSION
        end
    end

    costAudit.applied[AUDIT_VERSION] = {
        at = time and time() or 0,
        changed = changed,
        snapshot = BASIS_SNAPSHOT,
    }
    RefreshCostReviews(db, quiet)
    if changed > 0 and not quiet then
        print(string.format("|cff33ff99UBK audit:|r applied cost-provenance safeguards to %d material state%s.", changed, changed == 1 and "" or "s"))
    end
    return changed
end

local function PrintCostReview()
    local db = GetRealmDB()
    ApplyHistoricalCostAudit(db, true)
    RefreshCostReviews(db, true)
    local _, review = EnsureCostReviewState(db)
    local open = {}
    for itemString, row in pairs(review.items) do
        if type(row) == "table" and row.open then open[#open + 1] = {itemString = itemString, row = row} end
    end
    table.sort(open, function(a, b) return BASIS_SEEDS[a.itemString].name < BASIS_SEEDS[b.itemString].name end)
    if #open == 0 then
        print("|cff33ff99UBK REVIEW:|r no outstanding custom-price questions.")
        return
    end
    print(string.format("|cffffcc00UBK REVIEW:|r %d item%s need human judgment:", #open, #open == 1 and "" or "s"))
    for _, entry in ipairs(open) do
        local row = entry.row
        print(string.format("  %s: %d unresolved / %d observed; custom %s — %s",
            BASIS_SEEDS[entry.itemString].name, tonumber(row.unresolved) or 0, tonumber(row.observed) or 0,
            tostring(row.customValue or "<none>"), tostring(row.reason or "review")))
    end
    print("  |cffaaaaaaMANUAL = trust the current literal as acquisition cost for the currently unresolved units; future real purchases blend into that basis.|r")
    print("  |cffaaaaaaECONOMIC = preserve the literal as an opportunity/crafting value (for example Primal Nether); it is not AH acquisition cost and Radar ignores it.|r")
    print("  |cffaaaaaaMANUAL = trust the current literal for unresolved units. ECONOMIC = keep that literal as an opportunity value, not acquisition cost.|r")
    print("  |cffaaaaaaIf no literal exists, use /ubk resolve <item> <price>, or /ubk classify <item> unresolved to deliberately leave those units unknown.|r")
end

_G.UBKWorldDropInternal = _G.UBKWorldDropInternal or {}

function _G.UBKWorldDropInternal.CaptureWorldLocation()
    local zone = nil
    if type(GetRealZoneText) == "function" then zone = GetRealZoneText() end
    if (not zone or zone == "") and type(GetZoneText) == "function" then zone = GetZoneText() end
    local subZone = type(GetSubZoneText) == "function" and GetSubZoneText() or nil
    local mapID = nil
    local x, y = nil, nil
    if C_Map and type(C_Map.GetBestMapForUnit) == "function" then
        local ok, value = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then mapID = tonumber(value) end
    end
    if mapID and C_Map and type(C_Map.GetPlayerMapPosition) == "function" then
        local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
        if ok and pos then
            if type(pos.GetXY) == "function" then
                local okxy, px, py = pcall(pos.GetXY, pos)
                if okxy then x, y = tonumber(px), tonumber(py) end
            else
                x, y = tonumber(pos.x), tonumber(pos.y)
            end
        end
    end
    return {
        capturedAt = time and time() or 0,
        character = UnitName and UnitName("player") or nil,
        zone = zone,
        subZone = subZone,
        mapID = mapID,
        x = x,
        y = y,
    }
end

function _G.UBKWorldDropInternal.Reference(state, itemString)
    if IsUniversalExcluded(itemString) then local _,vendor=_G.UBKItemRules.VendorTrash(itemString); return vendor,"vendor sell value" end
    if type(state) ~= "table" then return nil, nil end
    local capture = state.lastLootCapture
    local capturedBasis = type(capture) == "table" and tonumber(capture.basisAtCapture) or 0
    if capturedBasis and capturedBasis > 0 then return capturedBasis, "captured pre-loot UBK basis" end
    local knownQty = math.max(0, tonumber(state.qty) or 0)
    local currentBasis = tonumber(GetUnitBasis(state)) or 0
    local provenance = CostProvenanceLabel(state, itemString)
    local untrusted = provenance == "manual-economic" or provenance == "legacy-unverified" or provenance == "no-audit"
        or provenance == "formula-protected" or provenance == "unresolved"
    if knownQty > 0 and currentBasis > 0 and not untrusted then return currentBasis, "current trusted UBK basis" end
    if type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function" then
        for _, source in ipairs({"fairvalue", "dbrecent", "dbmarket", "dbhistorical"}) do
            local ok, value = pcall(TSM_API.GetCustomPriceValue, source, itemString)
            value = ok and tonumber(value) or 0
            if value and value > 0 then return value, "TSM " .. source end
        end
    end
    local literal = ParseMoney(GetTSMCustomValue(itemString))
    if literal and literal > 0 then return literal, "review literal" end
    return nil, nil
end

function _G.UBKWorldDropInternal.ApplyClassification(db, itemString, state)
    if not db or not itemString or type(state) ~= "table" then return false, "item is not tracked by UBK" end
    if IsUniversalExcluded(itemString) then
        local _,vendor=_G.UBKItemRules.VendorTrash(itemString)
        if vendor==nil then return false,"The vendor sell quote is not loaded yet. Hover the item and try again." end
        -- Preserve purchased lots and prior records; vendor recovery is not paid basis.
        state.vendorUnitValue=vendor
        state.userCostClassification="vendor-trash"
        state.worldSourceConfirmed=true
        state.worldSourceUnitBasis=vendor
        state.firstSeenLootReview=false
        state.needsCostReview=false
        state.reviewReason=nil
        ClearCostReview(db,itemString)
        return true,vendor,0,"vendor sell value"
    end
    local reference, referenceKind = _G.UBKWorldDropInternal.Reference(state, itemString)
    if not reference or reference <= 0 then
        return false, "UBK has no positive basis/reference to apply the 95% world-drop rule to."
    end
    local unit = reference * 0.95
    local unresolved = math.max(0, tonumber(state.bootstrapUnresolved) or tonumber(state.unexplainedGain) or 0)
    if unresolved > 0 then
        state.qty = (tonumber(state.qty) or 0) + unresolved
        state.value = (tonumber(state.value) or 0) + unresolved * unit
        state.bootstrapUnresolved = 0
        state.unexplainedGain = 0
        state.lastBasis = state.qty > 0 and state.value / state.qty or unit
        state.lootReviewedQty = (tonumber(state.lootReviewedQty) or 0) + unresolved
        state.lootReviewedValue = (tonumber(state.lootReviewedValue) or 0) + unresolved * unit
        state.worldSourceQty = (tonumber(state.worldSourceQty) or 0) + unresolved
        state.worldSourceValue = (tonumber(state.worldSourceValue) or 0) + unresolved * unit
    end
    state.pending = 0
    state.unresolvedLots = {}
    state.basisReady = GetUnitBasis(state) > 0
    local observed = GetRealmQuantityForItem(itemString)
    state.lastObserved = tonumber(observed) or state.lastObserved
    db.activitySinceSeed = true
    state.userCostClassification = "manual-loot-basis"
    state.costProvenance = "manual-loot-basis"
    state.provenanceNote = string.format("User confirmed world-drop/found/farmed provenance; working basis set at 95%% of %s.", referenceKind or "review reference")
    state.worldSourceConfirmed = true
    state.worldSourceConfirmedAt = time and time() or 0
    state.worldSourceReference = reference
    state.worldSourceReferenceKind = referenceKind
    state.worldSourceUnitBasis = unit
    state.firstSeenLootReview = false
    state.needsCostReview = false
    state.reviewReason = nil
    state.userClassifiedAt = time and time() or 0
    ClearCostReview(db, itemString)
    AutoSyncTSM(true)
    return true, unit, unresolved, referenceKind
end

local function ClassifyCost(rest)
    rest = rest or ""
    local kind = rest:match("%s+(%S+)%s*$")
    local materialText = kind and rest:sub(1, #rest - #kind - 1) or nil
    kind = kind and kind:lower() or nil
    if kind == "loot" or kind == "farmed" or kind == "found" then kind = "world" end
    local itemString = materialText and ResolveItem(materialText) or nil
    if not itemString or (kind ~= "economic" and kind ~= "manual" and kind ~= "unresolved" and kind ~= "world") then
        print("|cffff7777UBK:|r usage: /ubk classify <item> economic|manual|world|unresolved")
        return
    end
    local db = GetRealmDB()
    local state = db.items[itemString]
    if not state then print("|cffff7777UBK:|r item is not tracked by UBK."); return end
    if kind == "unresolved" then
        state.userCostClassification="leave-unresolved"; state.needsCostReview=false; state.reviewReason=nil; state.userClassifiedAt=time and time() or 0
        ClearCostReview(db,itemString)
        print(string.format("|cff33ff99UBK:|r %s will remain unresolved until future purchase evidence or /ubk resolve supplies a cost. TSM's existing material value is left untouched.",BASIS_SEEDS[itemString].name))
        return
    end

    -- A loot/farmed review already means the user is answering a provenance question.
    -- Keep the MANUAL button convenient: on those rows it follows the exact same 95%
    -- world-drop path as the explicit WORLD button. On ordinary reviews MANUAL retains
    -- its historical meaning: trust the current literal at 100% as acquisition cost.
    if kind == "world" or (kind == "manual" and state.firstSeenLootReview == true) then
        local ok, unit, unresolved, referenceKind = _G.UBKWorldDropInternal.ApplyClassification(db, itemString, state)
        if not ok then
            print("|cffff7777UBK:|r " .. tostring(unit or "Could not apply the world-drop basis rule."))
            return
        end
        if IsUniversalExcluded(itemString) then
            print("|cff66ccffUBK:|r Vendor trash: "..FormatMoney(unit).." vendor sell value each. No acquisition-cost review is needed.")
            return
        end
        print(string.format("|cff66ccffUBK WORLD DROP:|r %s%s confirmed as dropped/found/farmed at 95%% of %s (%s each).",
            BASIS_SEEDS[itemString].name,
            unresolved and unresolved > 0 and string.format(" x%d", unresolved) or "",
            tostring(referenceKind or "working reference"), FormatMoney(unit)))
        return
    end

    local current = GetTSMCustomValue(itemString)
    local literal = ParseMoney(current)
    if not literal or literal <= 0 then
        print("|cffff7777UBK:|r the current TSM material value is not a literal money value; use /ubk resolve <item> <price>, classify world, or classify unresolved.")
        return
    end
    if kind == "economic" then
        state.userCostClassification = "manual-economic"
        state.costProvenance = "manual-economic"
        state.economicValue = literal
        state.provenanceNote = "User-classified economic/opportunity value."
        state.needsCostReview = false
        state.userClassifiedAt = time and time() or 0
        ClearCostReview(db, itemString)
        print(string.format("|cff33ff99UBK:|r %s classified as MANUAL ECONOMIC VALUE at %s. Crafting math keeps it; Goblin Radar will not treat it as AH acquisition cost.",
            BASIS_SEEDS[itemString].name, FormatMoney(literal)))
        AutoSyncTSM(true)
    else
        local unresolved = tonumber(state.bootstrapUnresolved) or 0
        if unresolved > 0 then
            state.qty = (tonumber(state.qty) or 0) + unresolved
            state.value = (tonumber(state.value) or 0) + unresolved * literal
            state.bootstrapUnresolved = 0
            state.unexplainedGain = 0
            state.lastBasis = state.qty > 0 and state.value / state.qty or literal
            state.buySources = type(state.buySources) == "table" and state.buySources or {}
            state.buySources["Manual Classified Cost"] = (tonumber(state.buySources["Manual Classified Cost"]) or 0) + unresolved
        end
        state.userCostClassification = "manual-acquisition"
        state.costProvenance = "manual-acquisition"
        state.provenanceNote = "User confirmed existing literal as actual acquisition cost."
        state.needsCostReview = false
        state.userClassifiedAt = time and time() or 0
        ClearCostReview(db, itemString)
        print(string.format("|cff33ff99UBK:|r %s classified as MANUAL ACQUISITION COST. %s is now trusted for mycost%s.",
            BASIS_SEEDS[itemString].name, FormatMoney(GetUnitBasis(state)), unresolved > 0 and string.format(" (%d unresolved unit%s resolved)", unresolved, unresolved == 1 and "" or "s") or ""))
        AutoSyncTSM(true)
    end
end

local function PrintTSMCompatibilityWarning()
    local version = GetTSMVersion()
    if version and version ~= TSM_EXPECTED_VERSION then
        print(string.format("|cffffaa00UBK:|r this write bridge was validated against TSM %s; you have %s. Dry-run first.", TSM_EXPECTED_VERSION, version))
    end
end

local function CaptureTSMBackup(db, itemString, currentValue)
    local writeState = EnsureWriteState(db)
    if type(writeState.backups[itemString]) == "table" then
        return writeState.backups[itemString], false
    end
    local backup = {
        hadCustom = currentValue ~= nil,
        value = currentValue,
        capturedAt = time and time() or 0,
        capturedBy = UnitName("player"),
        tsmVersion = GetTSMVersion(),
    }
    writeState.backups[itemString] = backup
    return backup, true
end

local function DryRunOne(itemString)
    local seed = BASIS_SEEDS[itemString]
    local db = GetRealmDB()
    local state = db.items[itemString]
    local current, exists = GetTSMCustomValue(itemString)
    if not exists then
        print(string.format("  |cffff7777%s: TSM material entry missing - WILL NOT WRITE|r", seed.name))
        return false
    end
    local dryBasis = state and state.costProvenance == "manual-economic" and (tonumber(state.economicValue) or 0) or GetUnitBasis(state)
    local default = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB["g@ @craftingOptions@defaultMatCostMethod"] or nil
    local native = (current == "ubkbasis" or current == "ubkmatcost") and current
        or (default == "ubkbasis" or default == "ubkmatcost") and default
    local target = native or FormatTSMPrice(dryBasis)
    local shownCurrent = current == nil and "<default/no custom value>" or tostring(current)
    local same = current == target
    print(string.format("  %s: TSM |cffffffff%s|r -> UBK |cff33ff99%s|r%s",
        seed.name, shownCurrent, target, same and " |cffaaaaaa(already matches)|r" or ""))
    return not same
end

local function DryRun(target)
    ProcessLedger(true)
    PrintTSMCompatibilityWarning()
    target = NormalizeName(target)
    print("|cffffcc00UBK universal TSM dry run|r |cffaaaaaa(no values are changed)|r")
    if target == "" or target == "all" then
        local changes = 0
        for _, itemString in ipairs(BASIS_ORDER) do
            if DryRunOne(itemString) then changes = changes + 1 end
        end
        print(string.format("|cffaaaaaa%d tracked material%s would change.|r", changes, changes == 1 and "" or "s"))
        return
    end
    local itemString = ResolveItem(target)
    if itemString then
        DryRunOne(itemString)
    else
        print("|cffff7777UBK:|r unknown tracked material. Example: /ubk dryrun dawnstone")
    end
end

local function WriteOne(itemString, quiet)
    local seed = BASIS_SEEDS[itemString]
    local db = GetRealmDB()
    local state = db.items[itemString]
    local universal = EnsureUniversalState(db)
    if state and state.autoDiscovered and state.stagedUniversal and universal.mode ~= "active" then
        if not quiet then print(string.format("|cffffaa00UBK:|r %s is staged by Universal preview. Use /ubk universal on before UBK owns its TSM value.", seed.name)) end
        return false, false
    end
    local unresolvedQty = state and (tonumber(state.bootstrapUnresolved) or 0) or 0
    local manualEconomic = state and state.costProvenance == "manual-economic"
    if state and state.autoDiscovered and state.protectedFormula and not state.formulaOverride then
        if not quiet then print(string.format("|cffffaa00UBK:|r %s already has a formula custom cost; Universal is protecting it. Use /ubk own <material> to explicitly hand it to UBK.", seed.name)) end
        return false, false
    end
    local mats, err = UBK_GetTSMMatsTable()
    if not mats then
        if not quiet then print("|cffff7777UBK:|r "..err..".") end
        return false, false
    end
    local entry = mats[itemString]
    if type(entry) ~= "table" then
        if not quiet then print(string.format("|cffff7777UBK:|r %s is not present in TSM's material table; refusing to create an internal TSM entry.", seed.name)) end
        return false, false
    end
    local current = entry.customValue
    -- Native UBK source is already live; never freeze it back to a literal.
    if current == "ubkbasis" or current == "ubkmatcost" then return true, false end
    local basis = manualEconomic and (tonumber(state.economicValue) or 0) or GetUnitBasis(state)
    if not basis or basis <= 0 then
        if not quiet then print(string.format("|cffff7777UBK:|r %s has no valid positive basis; refusing to write 0 into TSM.", seed.name)) end
        return false, false
    end
    local default = TradeSkillMasterDB["g@ @craftingOptions@defaultMatCostMethod"]
    local target = (default == "ubkbasis" or default == "ubkmatcost") and default or FormatTSMPrice(basis)
    CaptureTSMBackup(db, itemString, current)
    if current == target then
        if not quiet then
            print(string.format("|cff33ff99UBK:|r %s already matches %s%s; no write needed.", seed.name, target,
                manualEconomic and " manual economic value" or ""))
        end
        return true, false
    end
    local ok, writeErr = pcall(function() entry.customValue = target end)
    if not ok or entry.customValue ~= target then
        if not quiet then print(string.format("|cffff7777UBK:|r failed to write %s: %s", seed.name, tostring(writeErr or "TSM rejected the change"))) end
        return false, false
    end
    local writeState = EnsureWriteState(db)
    writeState.lastWritten[itemString] = {
        value = target,
        previous = current,
        at = time and time() or 0,
        by = UnitName("player"),
        tsmVersion = GetTSMVersion(),
    }
    writeState.writes = (tonumber(writeState.writes) or 0) + 1
    if not quiet then
        if unresolvedQty > 0 then
            print(string.format("|cff33ff99UBK:|r wrote %s TSM material value: %s -> %s using %d known-cost unit(s); %d unresolved unit(s) remain excluded from mycost.",
                seed.name, tostring(current or "<default>"), target, tonumber(state.qty) or 0, unresolvedQty))
        else
            print(string.format("|cff33ff99UBK:|r wrote %s TSM material value: %s -> %s.", seed.name, tostring(current or "<default>"), target))
        end
    end
    return true, true
end

local function IsPaused(writeState, itemString)
    return type(writeState.pausedItems) == "table" and writeState.pausedItems[itemString] == true
end

AutoSyncTSM = function(silent)
    local db = GetRealmDB()
    if type(db.setup)=="table" and db.setup.status~="complete" then return 0 end
    local writeState = EnsureWriteState(db)
    if writeState.mode ~= "automatic" then return 0 end
    local changed = 0
    for _, itemString in ipairs(BASIS_ORDER) do
        if db.items[itemString] and BASIS_SEEDS[itemString] and not IsPaused(writeState, itemString) then
            local state = db.items[itemString]
            if not state.tsmMaterial and not UBK_IsTSMMaterial(itemString) then
                -- Purchase-only items have a UBK basis for UBK/tooltips but must never
                -- cause UBK to manufacture a fake row in TSM's crafting-material table.
            else
            local universal = EnsureUniversalState(db)
            local universalAllowed = not state.autoDiscovered or not state.stagedUniversal or universal.mode == "active"
            local basis = state.costProvenance == "manual-economic" and (tonumber(state.economicValue) or 0) or GetUnitBasis(state)
            local basisAvailable = basis > 0
            local formulaAllowed = not state.autoDiscovered or not state.protectedFormula or state.formulaOverride
            if universalAllowed and basisAvailable and formulaAllowed then
            local current = GetTSMCustomValue(itemString)
            local default = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB["g@ @craftingOptions@defaultMatCostMethod"] or nil
            local native = (current == "ubkbasis" or current == "ubkmatcost") and current
                or (default == "ubkbasis" or default == "ubkmatcost") and default
            local target = native or (basis > 0 and FormatTSMPrice(basis) or nil)
            if target and current ~= target then
                writeState.externalDrift[itemString] = {
                    foundAt = time and time() or 0,
                    from = current,
                    to = target,
                    by = UnitName("player"),
                }
                local ok, didChange = WriteOne(itemString, true)
                if ok and didChange then
                    changed = changed + 1
                    writeState.autoWrites = (tonumber(writeState.autoWrites) or 0) + 1
                end
            else
                -- Capture the pre-UBK value even when it already matches, so restore
                -- has deterministic behavior after automatic ownership begins.
                CaptureTSMBackup(db, itemString, current)
            end
            end
            end
        end
    end
    if changed > 0 and not silent then
        print(string.format("|cff33ff99UBK:|r automatic TSM sync updated %d tracked material%s.", changed, changed == 1 and "" or "s"))
    end
    return changed
end

local function ExtractItemAndPrice(rest)
    rest = rest or ""
    local itemID = rest:match("|Hitem:(%d+)")
    local priceText
    if itemID then
        priceText = rest:match("|h|r%s+(.+)$") or rest:match("|h%s+(.+)$")
    else
        local token, after = rest:match("^%s*(%S+)%s*(.-)%s*$")
        if token then
            itemID = token:match("^i:(%d+)$") or token:match("^(%d+)$")
            priceText = after ~= "" and after or nil
        end
    end
    if not itemID then return nil, nil end
    return "i:" .. tostring(tonumber(itemID)), priceText
end

local function GetItemDisplayName(itemString)
    local itemID = tonumber(itemString and itemString:match("i:(%d+)"))
    if not itemID then return itemString end
    local name = GetItemInfo and GetItemInfo(itemID) or nil
    return name or ("Item " .. itemID)
end

-- A few universally useful material names are kept as a fallback because
-- GetItemInfo can be cold when a material is first discovered. We still prefer
-- the live client name whenever it is available.
UBK_KNOWN_ITEM_NAMES = {}

function UBK_MaterialName(itemString)
    local seed = BASIS_SEEDS[itemString]
    local current = seed and seed.name or nil
    if current and not tostring(current):match("^Item %d+$") then return current end
    local itemID = tonumber(itemString and itemString:match("i:(%d+)"))
    if itemID and GetItemInfo then
        local liveName = GetItemInfo(itemID)
        if liveName then
            if seed then seed.name = liveName end
            return liveName
        end
    end
    local fallback = itemID and UBK_KNOWN_ITEM_NAMES[itemID] or nil
    if fallback then
        if seed then seed.name = fallback end
        return fallback
    end
    return current or (itemID and ("Item " .. itemID)) or tostring(itemString)
end

function UBK_BuildUniversalPurchaseIndex()
    local index = {}
    local newest = {}
    local mergedCounts = {}
    local factionCharacters = UBK_CurrentFactionCharacters()

    local function MergeLedger(csv)
        if type(csv) ~= "string" or csv == "" then return end
        local localCounts = {}
        for line in csv:gmatch("[^\r\n]+") do
            localCounts[line] = (localCounts[line] or 0) + 1
        end
        for line, count in pairs(localCounts) do
            if count > (mergedCounts[line] or 0) then mergedCounts[line] = count end
        end
    end

    -- Index the current account's TSM Accounting rows as a multiset so repeated,
    -- identical purchases remain count-safe.
    MergeLedger(GetTSMBuyLedger())

    for line, occurrenceCount in pairs(mergedCounts) do
        local itemString, qty, price, timestamp, buyer, _, source = ParseBuyLine(line)
        if itemString and qty and price and timestamp and price > 0 and factionCharacters[buyer or ""] and not IsUniversalExcluded(itemString) then
            index[itemString] = index[itemString] or {}
            index[itemString][#index[itemString] + 1] = {qty = qty * occurrenceCount, price = price, time = timestamp, source = source}
            newest[itemString] = math.max(tonumber(newest[itemString]) or 0, timestamp)
        end
    end
    for _, records in pairs(index) do
        table.sort(records, function(a, b)
            if a.time == b.time then return a.price > b.price end
            return a.time > b.time
        end)
    end
    return index, newest
end

local function SeedUniversalState(db, itemString, entry, records, newestTime)
    local importing = type(db.setup)=="table" and db.setup.historyMode=="import"
    local observed, haveInventory = GetRealmQuantityForItem(itemString)
    if not haveInventory then observed = 0 end
    local remaining = observed
    local covered = 0
    local value = 0
    local sources = {}
    for _, rec in ipairs(records or {}) do
        if remaining <= 0 then break end
        local take = math.min(remaining, tonumber(rec.qty) or 0)
        if take > 0 then
            covered = covered + take
            value = value + take * (tonumber(rec.price) or 0)
            remaining = remaining - take
            if rec.source then sources[rec.source] = (sources[rec.source] or 0) + take end
        end
    end

    local literal = nil
    local currentCustom = type(entry) == "table" and entry.customValue or nil
    local protectedFormula = currentCustom ~= nil and currentCustom ~= "ubkbasis" and currentCustom ~= "ubkmatcost" and not IsLiteralMoney(currentCustom)
    local historicalQty, historicalValue = 0, 0
    for _, rec in ipairs(records or {}) do
        local rq = tonumber(rec.qty) or 0
        local rp = tonumber(rec.price) or 0
        if rq > 0 and rp > 0 then historicalQty = historicalQty + rq; historicalValue = historicalValue + rq * rp end
    end
    local historicalBasis = historicalQty > 0 and (historicalValue / historicalQty) or 0
    if importing and IsLiteralMoney(currentCustom) then literal = ParseMoney(currentCustom) end

    local seedSource = "unresolved"
    local unresolved = math.max(0, observed - covered)
    if observed > 0 and covered >= observed then
        unresolved = 0
        seedSource = "retained-purchases"
    elseif observed == 0 then
        covered = 0
        value = 0
        unresolved = 0
        seedSource = "zero-stock-awaiting-acquisition"
    elseif covered > 0 then
        seedSource = literal and "retained-purchases+existing-literal" or "partial-purchase-history"
    elseif literal then
        -- A pre-existing literal is evidence to REVIEW, not evidence of what the
        -- inventory actually cost. UBK leaves the units unresolved until TSM
        -- purchase history, buyer-mail capture, or the user explicitly classifies it.
        seedSource = MANUAL_ECONOMIC_VALUES[itemString] and "manual-economic" or "legacy-literal-unverified"
    end

    local state = {
        qty = covered,
        value = value,
        lastBasis = covered > 0 and value / covered or historicalBasis,
        pending = 0,
        lastObserved = observed,
        buysQty = 0,
        buysValue = 0,
        buysRecords = 0,
        lastBuyTime = 0,
        lastBuyer = nil,
        buyers = {},
        buySources = sources,
        shredEligibleQty = math.min(observed, math.max(0, tonumber(sources["Auction"]) or 0) + math.max(0, tonumber(sources["Trade"]) or 0)),
        unexplainedGain = unresolved,
        bootstrapUnresolved = unresolved,
        cutoffTime = tonumber(newestTime) or (time and time() or 0),
        autoDiscovered = true,
        stagedUniversal = type(entry) == "table",
        tsmMaterial = type(entry) == "table",
        trackingClass = type(entry) == "table" and "tsm-material" or "purchased-item",
        historicalBuyQty = historicalQty,
        historicalBuyValue = historicalValue,
        basisReady = covered > 0,
        seedSource = seedSource,
        seedLiteral = currentCustom,
        seedLiteralCopper = literal,
        costProvenance = MANUAL_ECONOMIC_VALUES[itemString] and "manual-economic"
            or (protectedFormula and "formula-protected"
            or (seedSource == "legacy-literal-unverified" and "legacy-unverified"
            or (covered > 0 and unresolved > 0 and "partial-history"
            or (covered > 0 and "purchase-history" or "unresolved")))),
        economicValue = MANUAL_ECONOMIC_VALUES[itemString] and MANUAL_ECONOMIC_VALUES[itemString].value or nil,
        provenanceNote = MANUAL_ECONOMIC_VALUES[itemString] and MANUAL_ECONOMIC_VALUES[itemString].note or nil,
        needsCostReview = importing and unresolved > 0,
        reviewReason = importing and unresolved > 0 and (literal and "Imported inventory is not fully covered by purchase history; existing TSM literal is available as evidence" or "Imported inventory is not fully covered by purchase history and has no literal TSM cost") or nil,
        protectedFormula = protectedFormula,
        protectedFormulaValue = protectedFormula and currentCustom or nil,
        discoveredAt = time and time() or 0,
    }
    return state
end

DiscoverUniversalMaterials = function(db, silent)
    if type(TradeSkillMasterDB) ~= "table" then return nil end
    db = db or GetRealmDB()
    local mats = UBK_GetTSMMatsTable() or {}
    local universal = EnsureUniversalState(db)
    universal.meta = type(universal.meta) == "table" and universal.meta or {}

    local function Register(itemString, source, isMaterial)
        if type(itemString) ~= "string" or not itemString:match("^i:%d+$") or IsUniversalExcluded(itemString) then return end
        local name = GetItemDisplayName(itemString)
        local meta = universal.meta[itemString]
        if type(meta) ~= "table" then
            meta = {
                name = name,
                aliases = {tostring(tonumber(itemString:match("i:(%d+)")))},
                trackedAt = time and time() or 0,
                source = source,
                tsmMaterial = isMaterial and true or false,
            }
            universal.meta[itemString] = meta
        else
            if (not meta.name or meta.name:match("^Item %d+$")) and name and not name:match("^Item %d+$") then meta.name = name end
            if isMaterial then meta.tsmMaterial = true end
            if source == "purchase-history" and meta.source ~= "universal-tsm-material" then meta.source = source end
        end
        if not BASIS_SEEDS[itemString] then
            BASIS_SEEDS[itemString] = {name = meta.name or name, aliases = meta.aliases or {}, custom = true}
        end
        EnsureOrderItem(itemString)
    end

    local tsmRows = 0
    for itemString, entry in pairs(mats) do
        if type(itemString) == "string" and itemString:match("^i:%d+$") and type(entry) == "table" then
            tsmRows = tsmRows + 1
            Register(itemString, "universal-tsm-material", true)
            if type(db.items[itemString]) == "table" then
                db.items[itemString].tsmMaterial = true
                db.items[itemString].trackingClass = "tsm-material"
            end
        end
    end

    local purchaseIndex, newest = {}, {}
    local setup = type(db.setup) == "table" and db.setup or {}
    local doHistoryBootstrap = setup.status ~= "pending" and setup.historyMode ~= "empty"
        and tonumber(db.purchaseUniverseSchema) ~= UBK_PURCHASE_UNIVERSE_SCHEMA
    if doHistoryBootstrap then
        purchaseIndex, newest = UBK_BuildUniversalPurchaseIndex()
        for itemString in pairs(purchaseIndex) do
            Register(itemString, "purchase-history", type(mats[itemString]) == "table")
        end
    end

    local seededNow, purchasedNow = 0, 0
    for _, itemString in ipairs(BASIS_ORDER) do
        if type(db.items[itemString]) ~= "table" then
            local entry = mats[itemString]
            local records = doHistoryBootstrap and purchaseIndex[itemString] or nil
            if entry or records then
                db.items[itemString] = SeedUniversalState(db, itemString, entry, records, newest[itemString])
                seededNow = seededNow + 1
                if records and not entry then purchasedNow = purchasedNow + 1 end
            end
        end
    end

    if doHistoryBootstrap then
        db.purchaseUniverseSchema = UBK_PURCHASE_UNIVERSE_SCHEMA
        db.purchaseUniverseBootstrappedAt = time and time() or 0
        db.purchaseUniverseSource = "live-tsm"
    end

    local autoTotal, seeded, unresolved, zeroStock, existing, protected, purchasedItems = 0, 0, 0, 0, 0, 0, 0
    for _, itemString in ipairs(BASIS_ORDER) do
        local state = db.items[itemString]
        if state then
            if state.trackingClass == "purchased-item" or not state.tsmMaterial then purchasedItems = purchasedItems + 1 end
            if state.autoDiscovered then
                autoTotal = autoTotal + 1
                if state.protectedFormula and not state.formulaOverride then protected = protected + 1 end
                if (tonumber(state.qty) or 0) > 0 and GetUnitBasis(state) > 0 then seeded = seeded + 1 else zeroStock = zeroStock + 1 end
                if (tonumber(state.bootstrapUnresolved) or 0) > 0 then unresolved = unresolved + 1 end
            else
                existing = existing + 1
            end
        end
    end

    universal.discovered = autoTotal
    universal.seeded = seeded
    universal.unresolved = unresolved
    universal.zeroStock = zeroStock
    universal.existing = existing
    universal.protected = protected
    universal.purchasedItems = purchasedItems
    universal.lastDiscoveryAt = time and time() or 0
    universal.tsmRows = tsmRows

    if doHistoryBootstrap and not silent then
        print(string.format("|cff33ff99UBK:|r purchase-universe migration complete: %d total tracked item%s, including %d non-crafting purchased item%s. Historical purchase evidence was merged without double-counting archived/live duplicates.",
            autoTotal, autoTotal == 1 and "" or "s", purchasedItems, purchasedItems == 1 and "" or "s"))
    elseif seededNow > 0 and not silent then
        print(string.format("|cff33ff99UBK:|r discovered %d new tracked item%s.", seededNow, seededNow == 1 and "" or "s"))
    end
    return universal
end

function UBK_UniversalBuckets(db)
    local universal = DiscoverUniversalMaterials(db, true) or EnsureUniversalState(db)
    ApplyHistoricalCostAudit(db, true)
    RefreshCostReviews(db, true)

    local buckets = {
        ready = {},
        partial = {},
        unknown = {},
        protected = {},
        zeroStock = {},
        review = {},
        activeAuto = 0,
    }
    local _, reviewState = EnsureCostReviewState(db)

    for _, itemString in ipairs(BASIS_ORDER) do
        local state = db.items[itemString]
        if state and not IsUniversalExcluded(itemString) then
            local formulaBlocked = state.protectedFormula and not state.formulaOverride
            local provenance = CostProvenanceLabel(state, itemString)
            local economic = provenance == "manual-economic"
            local unresolvedQty = tonumber(state.bootstrapUnresolved) or 0
            local basis = GetUnitBasis(state)

            local reviewRow = reviewState.items[itemString]
            local reviewOpen = type(reviewRow) == "table" and reviewRow.open

            if reviewOpen then
                -- REVIEW is intentionally exclusive in this human-facing census.
                -- An item which needs judgment should never simultaneously look "READY".
                buckets.review[#buckets.review + 1] = itemString
            elseif formulaBlocked then
                buckets.protected[#buckets.protected + 1] = itemString
            elseif economic then
                -- An intentional economic/opportunity value is neither unknown
                -- acquisition cost nor a normal purchase basis. Treat it as ready
                -- for its intended crafting-value purpose, while Radar still ignores it.
                buckets.ready[#buckets.ready + 1] = itemString
            elseif basis > 0 and unresolvedQty > 0 then
                buckets.partial[#buckets.partial + 1] = itemString
            elseif basis > 0 then
                buckets.ready[#buckets.ready + 1] = itemString
            elseif unresolvedQty > 0 then
                buckets.unknown[#buckets.unknown + 1] = itemString
            else
                buckets.zeroStock[#buckets.zeroStock + 1] = itemString
            end

            if state.autoDiscovered and universal.mode == "active" and basis > 0 and not formulaBlocked and not reviewOpen then
                buckets.activeAuto = buckets.activeAuto + 1
            end
        end
    end

    local function sortByName(list)
        table.sort(list, function(a, b)
            local an = UBK_MaterialName(a)
            local bn = UBK_MaterialName(b)
            return tostring(an) < tostring(bn)
        end)
    end
    sortByName(buckets.ready)
    sortByName(buckets.partial)
    sortByName(buckets.unknown)
    sortByName(buckets.protected)
    sortByName(buckets.zeroStock)
    sortByName(buckets.review)

    return universal, buckets
end

local function PrintUniversalSummary(showItems)
    local db = GetRealmDB()
    local universal, buckets = UBK_UniversalBuckets(db)

    print(string.format("|cffffcc00UBK Cost Coverage|r: %s; TSM material rows %d; all tracked item states classified below.",
        universal.mode == "active" and "ACTIVE" or "PREVIEW ONLY",
        tonumber(universal.tsmRows) or 0))
    print(string.format("  |cff33ff99READY %d|r  |cff66ccffPARTIAL / SAFE %d|r  |cffffcc00UNKNOWN COST %d|r  |cffff5555REVIEW NEEDED %d|r  |cff66ccffFORMULA-PROTECTED %d|r  |cff888888ZERO-STOCK %d|r",
        #buckets.ready, #buckets.partial, #buckets.unknown, #buckets.review, #buckets.protected, #buckets.zeroStock))
    print("  |cffaaaaaaPARTIAL / SAFE means mycost is live from proven units; older unknown units are excluded, never valued at zero.|r")
    print("  |cffaaaaaaUNKNOWN COST is diagnostic, not a failure. Use /ubk universal unknown to see every currently owned item with no proven cost.|r")
    print("  |cffff5555Only REVIEW NEEDED asks you to make a judgment.|r Use /ubk review. |cffaaaaaaFORMULA-PROTECTED is intentional TSM territory, not an error.|r")
    print("  |cffaaaaaaUBK never invents TSM material rows or craft records; it only adopts material rows TSM already knows.|r")

    if universal.mode ~= "active" then
        print("  |cff33ff99No newly discovered TSM custom values have been changed.|r Use /ubk universal on only after this preview looks sane.")
    else
        print(string.format("  %d universal material(s) currently have a positive known-cost basis eligible for automatic TSM ownership.", buckets.activeAuto))
    end

    if showItems then
        print("  |cffaaaaaaDetailed census requested. /ubk universal partial and /ubk universal unknown are usually easier to read.|r")
        if #buckets.ready > 0 then
            print("|cff33ff99READY:|r")
            for _, itemString in ipairs(buckets.ready) do
                local state = db.items[itemString]
                print(string.format("  %s (%s): %d @ %s |cffaaaaaa[%s]|r",
                    UBK_MaterialName(itemString), itemString, tonumber(state.qty) or 0,
                    FormatMoney(GetUnitBasis(state)), tostring(state.seedSource or "purchase")))
            end
        end
        if #buckets.partial > 0 then
            print("|cff66ccffPARTIAL / SAFE — mycost active; unknown legacy units excluded:|r")
            for _, itemString in ipairs(buckets.partial) do
                local state = db.items[itemString]
                local known = tonumber(state.qty) or 0
                local unknown = tonumber(state.bootstrapUnresolved) or 0
                local total = known + unknown
                local coverage = total > 0 and (known / total * 100) or 0
                print(string.format("  %s (%s): %d known @ %s; %d legacy-unknown excluded (%.0f%% cost coverage)",
                    UBK_MaterialName(itemString), itemString, known, FormatMoney(GetUnitBasis(state)), unknown, coverage))
            end
        end
        if #buckets.unknown > 0 then
            print("|cffffcc00UNKNOWN COST — no positive known basis yet:|r")
            for _, itemString in ipairs(buckets.unknown) do
                local state = db.items[itemString]
                print(string.format("  %s (%s): %d owned unit(s) have no proven cost |cffaaaaaa[%s]|r",
                    UBK_MaterialName(itemString), itemString, tonumber(state.bootstrapUnresolved) or 0,
                    tostring(state.seedSource or "unknown")))
            end
        end
        if #buckets.protected > 0 then
            print("|cff66ccffFORMULA-PROTECTED — TSM formula preserved:|r")
            for _, itemString in ipairs(buckets.protected) do
                local state = db.items[itemString]
                print(string.format("  %s (%s): %s", UBK_MaterialName(itemString), itemString, tostring(state.protectedFormulaValue or "<formula>")))
            end
        end
    end
end

function UBK_PrintUniversalPartial()
    local db = GetRealmDB()
    local _, buckets = UBK_UniversalBuckets(db)
    if #buckets.partial == 0 then
        print("|cff33ff99UBK PARTIAL / SAFE:|r none. Every positive basis is either fully costed or formula-protected.")
        return
    end
    print(string.format("|cff66ccffUBK PARTIAL / SAFE:|r %d item%s have a trusted UBK basis plus older unknown units that are excluded:",
        #buckets.partial, #buckets.partial == 1 and "" or "s"))
    for _, itemString in ipairs(buckets.partial) do
        local state = db.items[itemString]
        local known = tonumber(state.qty) or 0
        local unknown = tonumber(state.bootstrapUnresolved) or 0
        local total = known + unknown
        local coverage = total > 0 and (known / total * 100) or 0
        print(string.format("  |cff33ff99%s|r: %d known @ %s; %d legacy-unknown excluded; %.0f%% cost coverage. |cffaaaaaaSAFE — mycost remains live.|r",
            UBK_MaterialName(itemString), known, FormatMoney(GetUnitBasis(state)), unknown, coverage))
    end
    print("  |cffaaaaaaThese do NOT require manual fixing unless you specifically want to cost the older unknown units.|r")
end

function UBK_UnknownCostExplanation(state, itemString, reviewOpen)
    if reviewOpen then
        return "REVIEW NEEDED: an existing custom/literal value needs your provenance decision."
    end
    local historyQty = tonumber(state.auditHistoryQty) or 0
    local historyRecords = tonumber(state.auditHistoryRecords) or 0
    local retainedQty = tonumber(state.auditRetainedQty) or 0
    local source = tostring(state.seedSource or "")
    if historyQty > 0 and retainedQty <= 0 then
        return string.format("Historical purchases exist (%d units / %d record%s), but UBK cannot prove those buys are the units still owned.",
            historyQty, historyRecords, historyRecords == 1 and "" or "s")
    elseif source == "legacy-literal-unverified" or CostProvenanceLabel(state, itemString) == "legacy-unverified" then
        return "An old literal exists, but UBK has no acquisition evidence supporting it; the literal is not trusted as cost."
    elseif source == "zero-stock-awaiting-acquisition" then
        return "UBK first knew this item at zero stock; currently owned units arrived without a priced acquisition record."
    elseif source == "unresolved" then
        return "Current stock was observed without a priced acquisition record."
    end
    return "No retained purchase evidence maps to the currently owned units; this may be farmed, dropped, crafted, transferred, or legacy stock."
end

function UBK_PrintUniversalUnknown()
    local db = GetRealmDB()
    local _, buckets = UBK_UniversalBuckets(db)
    if #buckets.unknown == 0 then
        print("|cff33ff99UBK UNKNOWN COST:|r none. Every currently owned tracked item has at least some proven cost basis.")
        return
    end

    local _, reviewState = EnsureCostReviewState(db)
    print(string.format("|cffffcc00UBK UNKNOWN COST INVENTORY:|r %d currently owned item%s have no positive proven acquisition basis.",
        #buckets.unknown, #buckets.unknown == 1 and "" or "s"))
    print("  |cffaaaaaaThis is a diagnostic list, not a list of failures. UBK has deliberately refused to invent a cost.|r")

    for _, itemString in ipairs(buckets.unknown) do
        local state = db.items[itemString]
        local reviewRow = reviewState.items[itemString]
        local reviewOpen = type(reviewRow) == "table" and reviewRow.open
        local custom, exists = GetTSMCustomValue(itemString)
        local customText = exists and tostring(custom or "<default/no literal>") or "<no TSM material row>"
        local flag = reviewOpen and " |cffff5555[REVIEW NEEDED]|r" or " |cffffcc00[UNKNOWN — NO ACTION REQUIRED]|r"
        print(string.format("  |cffffffff%s|r (%s): %d owned; TSM value %s;%s",
            UBK_MaterialName(itemString), itemString, tonumber(state.bootstrapUnresolved) or 0, customText, flag))
        print(string.format("    |cffaaaaaa%s|r", UBK_UnknownCostExplanation(state, itemString, reviewOpen)))
        if reviewOpen then
            print(string.format("    |cffffcc00Use /ubk detail [%s], then classify manual if this was a real starting cost or economic if it is an opportunity/value proxy.|r",
                UBK_MaterialName(itemString)))
        end
    end
    print("  |cffaaaaaaREVIEW NEEDED items are intentionally not duplicated here; /ubk review is the action queue.|r")
    print("  |cffaaaaaaIf you recognize an UNKNOWN item as something you actually bought, tell me before manually assigning a price; account-local evidence may still be recoverable.|r")
end

local function UniversalCommand(rest)
    local db = GetRealmDB()
    local universal = DiscoverUniversalMaterials(db, false) or EnsureUniversalState(db)
    local command = NormalizeName(rest)
    if command == "on" or command == "adopt" or command == "active" then
        universal.mode = "active"
        universal.activatedAt = time and time() or 0
        universal.activatedBy = UnitName("player")
        PrintTSMCompatibilityWarning()
        print("|cff33ff99UBK:|r Universal Materials ACTIVE. Costed discovered materials may now be auto-owned; unknown-cost materials remain untouched.")
        AutoSyncTSM(false)
        PrintUniversalSummary(false)
    elseif command == "off" or command == "preview" or command == "pause" then
        universal.mode = "preview"
        universal.previewAt = time and time() or 0
        print("|cffffcc00UBK:|r Universal Materials returned to PREVIEW. Existing written values are left in place; newly discovered materials will not be auto-written.")
        PrintUniversalSummary(false)
    elseif command == "unknown" or command == "unknowns" or command == "uncosted" then
        UBK_PrintUniversalUnknown()
    elseif command == "partial" or command == "safe" then
        UBK_PrintUniversalPartial()
    elseif command == "all" or command == "detail" or command == "details" then
        PrintUniversalSummary(true)
    elseif command == "review" then
        if rest=="list" or type(_G.UBKUI_Show)~="function" then PrintCostReview() else _G.UBKUI_Show("review") end
    elseif command == "list" or command == "status" or command == "" then
        PrintUniversalSummary(false)
    else
        print("|cffff7777UBK:|r /ubk universal [list|unknown|partial|review|all|on|off]")
        PrintUniversalSummary(false)
    end
end

local function TrackMaterial(rest)
    local itemString, priceText = ExtractItemAndPrice(rest)
    if not itemString then
        print("|cffff7777UBK:|r use /ubk track <itemLink|itemID> [starting price].")
        return
    end
    local db = GetRealmDB()
    if db.items[itemString] and BASIS_SEEDS[itemString] then
        local state = db.items[itemString]
        if state.autoDiscovered then
            print(string.format("|cffffcc00UBK:|r %s is already universally discovered. Use /ubk set %s <price> to resolve/rebase it manually if needed.", BASIS_SEEDS[itemString].name, itemString))
        else
            print(string.format("|cffffcc00UBK:|r %s is already tracked at %s.", BASIS_SEEDS[itemString].name, FormatMoney(GetUnitBasis(state))))
        end
        return
    end
    local mats = UBK_GetTSMMatsTable() or {}
    local isMaterial = type(mats[itemString]) == "table"
    local startingBasis = priceText and ParseMoney(priceText) or nil
    local currentCustom = isMaterial and mats[itemString].customValue or nil
    if not startingBasis and IsLiteralMoney(currentCustom) then
        startingBasis = ParseMoney(currentCustom)
    end
    if not startingBasis then
        if isMaterial then
            print(string.format("|cffffaa00UBK:|r %s has no literal TSM money value to adopt. Supply the opening basis explicitly, e.g. /ubk track %s 20g.", GetItemDisplayName(itemString), itemString))
        else
            print(string.format("|cffffaa00UBK:|r %s is not a TSM crafting material, which is fine; supply its opening acquisition basis explicitly, e.g. /ubk track %s 20g.", GetItemDisplayName(itemString), itemString))
        end
        return
    end

    local qty, haveInventory = GetRealmQuantityForItem(itemString)
    if not haveInventory then
        print("|cffff7777UBK:|r TSM realm inventory cache is unavailable; visit/login once TSM is loaded, then track it.")
        return
    end
    local name = GetItemDisplayName(itemString)
    db.customSeeds = type(db.customSeeds) == "table" and db.customSeeds or {}
    db.customSeeds[itemString] = {
        name = name,
        aliases = {tostring(tonumber(itemString:match("i:(%d+)")))},
        trackedAt = time and time() or 0,
        source = "user-track",
    }
    BASIS_SEEDS[itemString] = {name = name, aliases = db.customSeeds[itemString].aliases, custom = true}
    EnsureOrderItem(itemString)
    db.items[itemString] = {
        qty = qty,
        value = qty * startingBasis,
        lastBasis = startingBasis,
        pending = 0,
        lastObserved = qty,
        buysQty = 0,
        buysValue = 0,
        buysRecords = 0,
        lastBuyTime = 0,
        lastBuyer = nil,
        buyers = {},
        unexplainedGain = 0,
        cutoffTime = time and time() or 0,
        manuallySeeded = true,
        tsmMaterial = isMaterial,
        stagedUniversal = isMaterial,
        trackingClass = isMaterial and "tsm-material" or "manual-item",
        userCostClassification = "manual-acquisition",
        costProvenance = "manual-acquisition",
        provenanceNote = "User explicitly enrolled this opening acquisition basis.",
        needsCostReview = false,
    }
    local writeState = EnsureWriteState(db)
    writeState.pausedItems[itemString] = nil
    print(string.format("|cff33ff99UBK:|r now tracking %s: opening qty %d @ %s. Future TSM Auction, Vendor, and priced Trade purchases will fold into this basis.%s", name, qty, FormatMoney(startingBasis), isMaterial and " TSM material integration is eligible." or " This is a purchase-only UBK item; no fake TSM material row will be created."))
    AutoSyncTSM(false)
end

local function SetOwnershipTarget(rest)
    local itemString = ResolveItem(rest)
    if not itemString then
        print("|cffff7777UBK:|r use /ubk own <material> for a universally discovered material.")
        return
    end
    local db = GetRealmDB()
    local state = db.items[itemString]
    if not state or not state.autoDiscovered then
        print("|cffffaa00UBK:|r that material is already an existing/manual UBK material; it does not need Universal ownership approval.")
        return
    end
    if GetUnitBasis(state) <= 0 then
        print(string.format("|cffffaa00UBK:|r %s has no positive known-cost basis yet; ownership remains blocked.", BASIS_SEEDS[itemString].name))
        return
    end
    state.formulaOverride = true
    state.formulaOverrideAt = time and time() or 0
    state.formulaOverrideBy = UnitName("player")
    print(string.format("|cff33ff99UBK:|r %s explicitly handed to UBK. Its pre-UBK TSM value will be backed up before any write.", BASIS_SEEDS[itemString].name))
    AutoSyncTSM(false)
end

local function SetBasisTarget(rest)
    local target, priceText = rest:match("^%s*(%S+)%s+(.+)%s*$")
    if not target or not priceText then
        print("|cffff7777UBK:|r use /ubk set <material> <price>, e.g. /ubk set dawnstone 15g25s")
        return
    end
    local itemString = ResolveItem(target)
    if not itemString then
        local maybeItem = target:match("^i:(%d+)$") or target:match("^(%d+)$")
        if maybeItem and BASIS_SEEDS["i:"..maybeItem] then itemString = "i:"..maybeItem end
    end
    if not itemString then
        print("|cffff7777UBK:|r unknown tracked material.")
        return
    end
    if IsUniversalExcluded(itemString) then
        print("|cffffcc00UBK:|r that material is intentionally excluded from UBK ownership.")
        return
    end
    local copper = ParseMoney(priceText)
    if not copper then
        print("|cffff7777UBK:|r invalid price. Use TSM-style money such as 15g25s or 14s.")
        return
    end
    local db = GetRealmDB()
    local state = db.items[itemString]
    local observed, haveInventory = GetRealmQuantityForItem(itemString)
    local poolQty = haveInventory and observed or (tonumber(state.qty) or 0)
    state.qty = poolQty
    state.value = poolQty * copper
    state.lastBasis = copper
    state.bootstrapUnresolved = 0
    state.unexplainedGain = 0
    state.pending = 0
    state.lastObserved = poolQty
    state.basisReady = true
    state.manualBasisSetAt = time and time() or 0
    state.manualBasisSetBy = UnitName("player")
    state.seedSource = "manual-rebase"
    state.userCostClassification = "manual-acquisition"
    state.costProvenance = "manual-acquisition"
    state.provenanceNote = "User deliberately rebased the current realm pool."
    state.needsCostReview = false
    ClearCostReview(db, itemString)
    state.formulaOverride = true
    print(string.format("|cff33ff99UBK:|r %s basis set to %s across the current %d-unit realm pool; unresolved inventory cleared and cost provenance recorded as MANUAL ACQUISITION.", BASIS_SEEDS[itemString].name, FormatMoney(copper), poolQty))
    AutoSyncTSM(false)
end

local function SetPause(target, paused)
    local db = GetRealmDB()
    local writeState = EnsureWriteState(db)
    target = NormalizeName(target)
    if target == "all" then
        for _, itemString in ipairs(BASIS_ORDER) do
            writeState.pausedItems[itemString] = paused and true or nil
        end
        print(string.format("|cffffcc00UBK:|r automatic TSM writing %s for all tracked materials.", paused and "PAUSED" or "RESUMED"))
        if not paused then AutoSyncTSM(false) end
        return
    end
    local itemString = ResolveItem(target)
    if not itemString then
        print("|cffff7777UBK:|r unknown tracked material.")
        return
    end
    writeState.pausedItems[itemString] = paused and true or nil
    print(string.format("|cffffcc00UBK:|r %s automatic TSM writing for %s.", paused and "paused" or "resumed", BASIS_SEEDS[itemString].name))
    if not paused then AutoSyncTSM(false) end
end

local function SetAutoMode(target)
    local db = GetRealmDB()
    local writeState = EnsureWriteState(db)
    target = NormalizeName(target)
    if target == "on" then
        writeState.mode = "automatic"
        db.integrationMode = "automatic-tsm-write"
        print("|cff33ff99UBK:|r automatic TSM writing ON.")
        AutoSyncTSM(false)
    elseif target == "off" then
        writeState.mode = "manual"
        db.integrationMode = "manual-tsm-write"
        print("|cffffcc00UBK:|r automatic TSM writing OFF. Accounting continues; TSM values will not be changed automatically.")
    else
        print(string.format("|cffffcc00UBK:|r automatic TSM writing is %s. Use /ubk auto on or /ubk auto off.", writeState.mode == "automatic" and "ON" or "OFF"))
    end
end

local function WriteTarget(target)
    ProcessLedger(true)
    PrintTSMCompatibilityWarning()
    target = NormalizeName(target)
    if target == "" then
        print("|cffff7777UBK:|r use /ubk write <material> or /ubk write all.")
        return
    end
    if target == "all" then
        local okCount, changed = 0, 0
        for _, itemString in ipairs(BASIS_ORDER) do
            local ok, didChange = WriteOne(itemString, true)
            if ok then okCount = okCount + 1 end
            if didChange then changed = changed + 1 end
        end
        print(string.format("|cff33ff99UBK:|r TSM write complete: %d/%d tracked materials checked; %d changed.", okCount, #BASIS_ORDER, changed))
        print("|cffaaaaaa/reload is recommended now so every TSM Crafting UI cache rebuilds from the new material values.|r")
        return
    end
    local itemString = ResolveItem(target)
    if not itemString then
        print("|cffff7777UBK:|r unknown tracked material. Example: /ubk write livingruby")
        return
    end
    local ok, changed = WriteOne(itemString, false)
    if ok and changed then
        print("|cffaaaaaa/reload is recommended before judging every TSM Crafting UI surface.|r")
    end
end

local function RestoreOne(itemString, quiet)
    local seed = BASIS_SEEDS[itemString]
    local db = GetRealmDB()
    local writeState = EnsureWriteState(db)
    local backup = writeState.backups[itemString]
    if type(backup) ~= "table" then
        if not quiet then print(string.format("|cffffaa00UBK:|r no pre-UBK TSM backup exists for %s; nothing restored.", seed.name)) end
        return false, false
    end
    local mats, err = UBK_GetTSMMatsTable()
    if not mats then
        if not quiet then print("|cffff7777UBK:|r "..err..".") end
        return false, false
    end
    local entry = mats[itemString]
    if type(entry) ~= "table" then
        if not quiet then print(string.format("|cffff7777UBK:|r %s is no longer present in TSM's material table; refusing to reconstruct TSM internals.", seed.name)) end
        return false, false
    end
    local before = entry.customValue
    local restoreValue = backup.hadCustom and backup.value or nil
    local ok, restoreErr = pcall(function() entry.customValue = restoreValue end)
    if not ok or entry.customValue ~= restoreValue then
        if not quiet then print(string.format("|cffff7777UBK:|r failed to restore %s: %s", seed.name, tostring(restoreErr or "TSM rejected the change"))) end
        return false, false
    end
    writeState.restores = (tonumber(writeState.restores) or 0) + 1
    local changed = before ~= restoreValue
    if not quiet then
        print(string.format("|cff33ff99UBK:|r restored %s TSM material value: %s -> %s.", seed.name, tostring(before or "<default>"), tostring(restoreValue or "<default>")))
    end
    return true, changed
end

local function RestoreTarget(target)
    target = NormalizeName(target)
    if target == "" then
        print("|cffff7777UBK:|r use /ubk restore <material> or /ubk restore all")
        return
    end
    if target == "all" then
        local restored, changed = 0, 0
        for _, itemString in ipairs(BASIS_ORDER) do
            local ok, didChange = RestoreOne(itemString, true)
            if ok then restored = restored + 1 end
            if didChange then changed = changed + 1 end
        end
        print(string.format("|cff33ff99UBK:|r restore complete: %d backups available; %d TSM values changed back.", restored, changed))
        print("|cffaaaaaa/reload is recommended now so every TSM Crafting UI cache rebuilds.|r")
        return
    end
    local itemString = ResolveItem(target)
    if not itemString then
        print("|cffff7777UBK:|r unknown tracked material. Example: /ubk restore dawnstone")
        return
    end
    local ok, changed = RestoreOne(itemString, false)
    if ok and changed then
        print("|cffaaaaaa/reload is recommended before judging every TSM Crafting UI surface.|r")
    end
end

local function PrintBackups()
    local db = GetRealmDB()
    local writeState = EnsureWriteState(db)
    print("|cffffcc00UBK pre-write TSM backups|r")
    local count = 0
    for _, itemString in ipairs(BASIS_ORDER) do
        local backup = writeState.backups[itemString]
        if type(backup) == "table" then
            count = count + 1
            print(string.format("  %s: %s |cffaaaaaa(captured by %s)|r", BASIS_SEEDS[itemString].name, tostring(backup.hadCustom and backup.value or "<default>"), backup.capturedBy or "unknown"))
        end
    end
    if count == 0 then print("  No TSM values have been written by UBK yet.") end
end

local function PrintList()
    ProcessLedger(true)
    local db = GetRealmDB()
    local currentQty, haveInventory = GetRealmTrackedQuantities(false)
    local writeState = EnsureWriteState(db)
    local universal = DiscoverUniversalMaterials(db, true) or EnsureUniversalState(db)
    print(string.format("|cffffcc00Universal Basis Keeper (UBK) universal|r |cffaaaaaa(account-wide; TSM ownership %s; Universal %s)|r", writeState.mode == "automatic" and "ON" or "OFF", string.upper(universal.mode or "preview")))
    for _, itemString in ipairs(BASIS_ORDER) do
        local seed = BASIS_SEEDS[itemString]
        local state = db.items[itemString]
        if state and not state.autoDiscovered then
            local observed = haveInventory and (currentQty[itemString] or 0) or nil
            local extra
            if observed ~= nil and observed ~= state.qty then
                extra = string.format(" |cffaaaaaa(pool %d / TSM %d)|r", state.qty, observed)
            else
                extra = string.format(" |cffaaaaaa(qty %d)|r", state.qty)
            end
            if (tonumber(state.pending) or 0) > 0 then extra = extra .. string.format(" |cffffaa00pending %d|r", state.pending) end
            if (tonumber(state.bootstrapUnresolved) or tonumber(state.unexplainedGain) or 0) > 0 then extra = extra .. string.format(" |cffff7777+%d unresolved|r", tonumber(state.bootstrapUnresolved) or tonumber(state.unexplainedGain) or 0) end
            if IsPaused(writeState, itemString) then extra = extra .. " |cffffaa00TSM write paused|r" end
            print(string.format("  |cffffffff%s|r  %s%s", seed.name, FormatMoney(GetUnitBasis(state)), extra))
        end
    end
    print(string.format("  |cff33ff99Universal discovery:|r %d new TSM materials; %d with known basis; %d carrying unresolved units; %d zero-stock waiting.", tonumber(universal.discovered) or 0, tonumber(universal.seeded) or 0, tonumber(universal.unresolved) or 0, tonumber(universal.zeroStock) or 0))
    print("  |cffaaaaaaNo material is pre-seeded or specially excluded in this distribution build.|r")
    print("|cffaaaaaa/ubk universal list for the new-material audit; /ubk detail <material>; /ubk set <material> <price>|r")
end

local function PrintDetail(itemString)
    ProcessLedger(true)
    local seed = BASIS_SEEDS[itemString]
    local db = GetRealmDB()
    local state = db.items[itemString]
    local currentQty, haveInventory = GetRealmTrackedQuantities(false)
    local observed = haveInventory and (currentQty[itemString] or 0) or nil

    print(string.format("|cffffcc00UBK - %s|r", seed.name))
    print(string.format("  Current basis: |cffffffff%s|r", FormatMoney(GetUnitBasis(state))))
    print(string.format("  Basis pool: %d raw; pool value %s", state.qty, FormatMoney(state.value)))
    if observed ~= nil then
        print(string.format("  TSM realm-owned snapshot: %d raw", observed))
    else
        print("  TSM realm-owned snapshot: unavailable")
    end
    print(string.format("  Since cutover: %d bought in %d ledger record%s for %s",
        tonumber(state.buysQty) or 0,
        tonumber(state.buysRecords) or 0,
        (tonumber(state.buysRecords) or 0) == 1 and "" or "s",
        FormatMoney(tonumber(state.buysValue) or 0)))
    if state.lastBuyer then
        print(string.format("  Most recent tracked buyer: %s", state.lastBuyer))
    end
    if (tonumber(state.lootImputedQty) or 0) > 0 then
        print(string.format("  Farmed/looted: %d unit(s), %s imputed working value at the 95%% pre-loot-basis rule",
            tonumber(state.lootImputedQty) or 0, FormatMoney(tonumber(state.lootImputedValue) or 0)))
    end
    print(string.format("  Pending inventory-cache settlement: %d", tonumber(state.pending) or 0))
    local unresolved = tonumber(state.bootstrapUnresolved) or tonumber(state.unexplainedGain) or 0
    if unresolved > 0 then
        local observedForCoverage = observed or ((tonumber(state.qty) or 0) + unresolved)
        local coverage = observedForCoverage > 0 and ((tonumber(state.qty) or 0) / observedForCoverage) or 0
        print(string.format("  |cffffaa00Unresolved inventory: %d unit(s)|r", unresolved))
        print(string.format("  Known-cost coverage: %d / %d unit(s) (%0.1f%%)", tonumber(state.qty) or 0, observedForCoverage, coverage * 100))
        print("  |cffaaaaaaUnresolved units are excluded from the average, never valued at zero. Priced TSM purchases continue to move mycost normally.|r")
    end
    local mailQty, mailValue, mailRecords = MailPendingTotals(db, itemString)
    if mailQty > 0 then
        print(string.format("  |cff33ff99Queued AH-mail fallback:|r %d unit(s) in %d invoice(s), %s total", mailQty, mailRecords, FormatMoney(mailValue)))
    end
    local tsmValue, exists = GetTSMCustomValue(itemString)
    if exists then
        print(string.format("  TSM custom material value: |cffffffff%s|r", tostring(tsmValue or "<default>")))
    end
    local provenance = CostProvenanceLabel(state, itemString)
    print(string.format("  Cost provenance: |cffffffff%s|r", CostProvenanceDisplay(state, itemString)))
    if state.provenanceNote then print("  |cffaaaaaa" .. tostring(state.provenanceNote) .. "|r") end
    if state.auditHistoryRecords and tonumber(state.auditHistoryRecords) > 0 then
        local coverageText = string.format("%d / %d", tonumber(state.auditRetainedQty) or 0, tonumber(state.auditSnapshotQty) or 0)
        local refWord = state.auditReference == "2026-08-31-1458" and "reference" or "opening"
        print(string.format("  Historical audit: %s %s units covered; retained-lot estimate %s; preserved-history avg %s across %d purchase record(s).",
            coverageText, refWord, FormatMoney(tonumber(state.auditRetainedBasis) or 0), FormatMoney(tonumber(state.auditHistoryAvg) or 0), tonumber(state.auditHistoryRecords) or 0))
    elseif state.auditSnapshotQty and tonumber(state.auditSnapshotQty) > 0 then
        local refWord = state.auditReference == "2026-08-31-1458" and "reference" or "opening"
        print(string.format("  Historical audit: 0 / %d %s units have preserved purchase records.", tonumber(state.auditSnapshotQty) or 0, refWord))
    end
    if provenance == "manual-economic" then
        print(string.format("  Economic/opportunity value used for TSM crafting math: |cffffffff%s|r", FormatMoney(tonumber(state.economicValue) or 0)))
    end
    if state.needsCostReview then
        print("  |cffff9933REVIEW REQUIRED:|r this existing literal is not accepted as acquisition evidence. /ubk review")
    end

    local writeState = EnsureWriteState(db)
    local universal = EnsureUniversalState(db)
    local ownership = writeState.mode == "automatic" and "AUTOMATIC" or "manual"
    if state.autoDiscovered and state.stagedUniversal and universal.mode ~= "active" then ownership = "STAGED / PREVIEW" end
    if unresolved > 0 and GetUnitBasis(state) > 0 then ownership = ownership .. " (known-cost basis; unresolved excluded)" end
    print(string.format("  TSM ownership: %s%s", ownership, IsPaused(writeState, itemString) and " (this material paused)" or ""))
    print("  |cffaaaaaaUse /ubk set <material> <price> to deliberately change the UBK basis; direct TSM edits are reverted while automatic ownership is active.|r")
end

local function PrintCaches(itemString)
    local seed = BASIS_SEEDS[itemString]
    local totals, haveInventory, details = GetRealmTrackedQuantities(true)
    if not haveInventory then
        print("|cffff7777UBK:|r TSM realm inventory caches are unavailable.")
        return
    end

    print(string.format("|cffffcc00UBK cache map - %s|r |cffaaaaaa(total %d)|r", seed.name, totals[itemString] or 0))
    local chars = details and details[itemString] or nil
    if not chars then
        print("  No cached quantity on any character.")
        return
    end

    local names = {}
    for character in pairs(chars) do names[#names + 1] = character end
    table.sort(names)
    for _, character in ipairs(names) do
        local kinds = chars[character]
        local total = 0
        local parts = {}
        for _, kind in ipairs({"bagQuantity", "bankQuantity", "mailQuantity", "auctionQuantity"}) do
            local qty = tonumber(kinds[kind]) or 0
            if qty > 0 then
                total = total + qty
                local label = kind:gsub("Quantity$", "")
                parts[#parts + 1] = label .. " " .. qty
            end
        end
        print(string.format("  %s: %d  |cffaaaaaa(%s)|r", character, total, table.concat(parts, ", ")))
    end
end

local function ReconcileOne(itemString)
    local db = GetRealmDB()
    local currentQty, haveInventory = GetRealmTrackedQuantities(false)
    if not haveInventory then
        print("|cffff7777UBK:|r TSM realm inventory cache is unavailable; nothing reconciled.")
        return false
    end

    local state = db.items[itemString]
    local observed = currentQty[itemString] or 0
    local oldQty = state.qty
    local basis = GetUnitBasis(state)
    state.qty = observed
    state.value = basis * observed
    if basis > 0 then state.lastBasis = basis end
    state.pending = 0
    state.lastObserved = observed
    state.unexplainedGain = 0
    db.activitySinceSeed = true

    print(string.format("|cffffcc00UBK:|r reconciled %s quantity %d -> %d; basis remains %s.",
        BASIS_SEEDS[itemString].name, oldQty, observed, FormatMoney(basis)))
    return true
end

local function ResolveUnresolved(itemString, priceText)
    if _G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(itemString) then return false,_G.UBKProspectingSessions:Reason(itemString) end
    local copper = ParseMoney(priceText)
    if not copper or copper <= 0 then
        local msg="Resolve needs a positive per-unit price. Example: 1g57s23c"
        print("|cffff7777UBK:|r "..msg)
        return false,msg
    end
    local db = GetRealmDB()
    local state = db.items[itemString]
    local itemName = (BASIS_SEEDS[itemString] and BASIS_SEEDS[itemString].name) or UBK_MaterialName(itemString) or tostring(itemString)
    if type(state) ~= "table" then
        local msg=string.format("%s is not currently tracked by UBK.", itemName)
        print("|cffffcc00UBK:|r "..msg)
        return false,msg
    end
    local unresolved = tonumber(state.bootstrapUnresolved) or tonumber(state.unexplainedGain) or 0
    if unresolved <= 0 then
        local msg=string.format("%s has no unresolved units to resolve.", itemName)
        print("|cffffcc00UBK:|r "..msg)
        return false,msg
    end
    local resolvingLoot = state.firstSeenLootReview == true
    state.qty = (tonumber(state.qty) or 0) + unresolved
    state.value = (tonumber(state.value) or 0) + unresolved * copper
    state.lastBasis = state.qty > 0 and state.value / state.qty or copper
    if resolvingLoot then
        state.lootReviewedQty = (tonumber(state.lootReviewedQty) or 0) + unresolved
        state.lootReviewedValue = (tonumber(state.lootReviewedValue) or 0) + unresolved * copper
    else
        state.buysQty = (tonumber(state.buysQty) or 0) + unresolved
        state.buysValue = (tonumber(state.buysValue) or 0) + unresolved * copper
        state.buysRecords = (tonumber(state.buysRecords) or 0) + 1
        state.buySources = type(state.buySources) == "table" and state.buySources or {}
        state.buySources["Manual Resolve"] = (tonumber(state.buySources["Manual Resolve"]) or 0) + unresolved
    end
    state.bootstrapUnresolved = 0
    state.unexplainedGain = 0
    state.pending = 0
    state.unresolvedLots = {}
    state.basisReady = GetUnitBasis(state) > 0
    state.userCostClassification = resolvingLoot and "manual-loot-basis" or "manual-acquisition"
    state.costProvenance = resolvingLoot and "manual-loot-basis" or "manual-acquisition"
    state.provenanceNote = resolvingLoot and "User supplied the starting working basis for first-seen looted/farmed inventory." or "User supplied an acquisition cost for previously unresolved units."
    state.firstSeenLootReview = false
    state.needsCostReview = false
    ClearCostReview(db, itemString)
    local observed = GetRealmQuantityForItem(itemString)
    state.lastObserved = tonumber(observed) or state.lastObserved
    db.activitySinceSeed = true
    print(string.format("|cff33ff99UBK:|r resolved %d previously-unresolved %s at %s each; blended basis is now %s.", unresolved, itemName, FormatMoney(copper), FormatMoney(GetUnitBasis(state))))
    AutoSyncTSM(false)
    return true
end

local function PrintMailStatus(audit)
    local db = GetRealmDB()
    local mc = EnsureMailCapture(db)
    if audit then
        print("|cffffcc00UBK current Auction House buyer invoices:|r")
        ScanAuctionMail(false, true)
    end
    local queuedQty, queuedValue, queuedRecords = 0, 0, 0
    for itemString in pairs(mc.pendingLots) do
        local q, v, r = MailPendingTotals(db, itemString)
        queuedQty, queuedValue, queuedRecords = queuedQty + q, queuedValue + v, queuedRecords + r
    end
    print(string.format("|cffffcc00UBK Auction-Mail Capture:|r %s; queued fallback %d record(s) / %d unit(s) / %s.", mc.armed and "ARMED" or "NOT ARMED", queuedRecords, queuedQty, FormatMoney(queuedValue)))
    print(string.format("  Captured lifetime fallback: %d record(s), %d unit(s), %s. Applied fallback: %d unit(s), %s.", mc.capturedRecords, mc.capturedQty, FormatMoney(mc.capturedValue), mc.appliedQty, FormatMoney(mc.appliedValue)))
    print(string.format("  Pre-loot guard: %d invoice(s) / %d unit(s) secured; %d fallback unit(s) later de-duplicated to durable TSM Accounting.",
        tonumber(mc.preLootCapturedRecords) or 0, tonumber(mc.preLootCapturedQty) or 0, tonumber(mc.tsmPendingDedupedQty) or 0))
    if not mc.armed then print("  |cffaaaaaaOpen a mailbox once (or run /ubk mail while it is open) to baseline existing mail and arm future invoice capture.|r") end
end

local function PrintStatus()
    print("|cff33ff99UBK build:|r v1.6 - dock + basis/provenance + ledger intelligence + scanner inputs + transformation accounting")
    TryLegacyMigration(true)
    local db = GetRealmDB()
    ApplyHistoricalCostAudit(db, true)
    local csv = GetTSMBuyLedger()
    local writeState = EnsureWriteState(db)
    print(string.format("|cffffcc00UBK:|r schema %d; %s TSM WRITE integration; snapshot %s; cutoff %d; last ledger %d.",
        db.schema or 0,
        writeState.mode == "automatic" and "AUTOMATIC" or "MANUAL",
        db.snapshot or "unknown",
        db.cutoffTime or 0,
        db.lastLedgerTime or 0))
    print(string.format("  TSM version: %s (validated %s); writes %d; automatic writes %d; restores %d.",
        GetTSMVersion() or "unknown", TSM_EXPECTED_VERSION, tonumber(writeState.writes) or 0, tonumber(writeState.autoWrites) or 0, tonumber(writeState.restores) or 0))
    print(string.format("  Current toon: %s; TSM ledger: %s; last processor: %s.",
        UnitName("player") or "unknown",
        csv and "available" or "unavailable",
        db.lastProcessor or "none"))
    local mc = EnsureMailCapture(db)
    local mq, mv, mr = 0, 0, 0
    for itemString in pairs(mc.pendingLots) do local q, v, r = MailPendingTotals(db, itemString); mq, mv, mr = mq + q, mv + v, mr + r end
    print(string.format("  Auction-mail fallback: %s; queued %d invoice(s) / %d unit(s) / %s.", mc.armed and "ARMED" or "not armed", mr, mq, FormatMoney(mv)))
    print(string.format("  Mail/TSM de-duplication: %d applied-mail record(s) / %d unit(s) recognized as already costed; %d pending-mail record(s) / %d unit(s) discarded in favor of durable TSM Accounting.",
        tonumber(mc.tsmDedupedRecords) or 0, tonumber(mc.tsmDedupedQty) or 0, tonumber(mc.tsmPendingDedupedRecords) or 0, tonumber(mc.tsmPendingDedupedQty) or 0))
    print(string.format("  Pre-loot mail guard: %s; %d invoice(s) / %d unit(s) secured with deferred TSM reconciliation.",
        mailLootHook.installed and "INSTALLED" or "not installed yet", tonumber(mc.preLootCapturedRecords) or 0, tonumber(mc.preLootCapturedQty) or 0))
    local _, review = EnsureCostReviewState(db)
    local reviewCount = 0
    for _, row in pairs(review.items) do if type(row) == "table" and row.open then reviewCount = reviewCount + 1 end end
    print(string.format("  Cost provenance audit: %s; outstanding human reviews: %d.", AUDIT_VERSION, reviewCount))
    if type(db.test6bRepair) == "table" then
        print(string.format("  Legacy repair state: %d unit(s).", tonumber(db.test6bRepair.repairedQty) or 0))
    end
    local universal = DiscoverUniversalMaterials(db, true) or EnsureUniversalState(db)
    print(string.format("  Tracked / discovered materials: %d. Universal mode: %s; TSM material rows: %d.", #BASIS_ORDER, string.upper(universal.mode or "preview"), tonumber(universal.tsmRows) or 0))
    print("  TSM Auction/Vendor/Trade buys are costed; AH buyer-mail invoices are fallback only. Unresolved gains stay excluded, but no longer freeze mycost from real purchases.")
    if _G.UBKShredderInternal then
        local sh=_G.UBKShredderInternal.EnsureState(db); local rt=_G.UBKShredderInternal.runtime
        print(string.format("  Shredder: %s; enchanter %s; %d cached candidate(s); %d pending transform(s); %d settled shred(s).",
            rt.scanning and "SCANNING" or "ready", tostring(sh.enchanter or "choose enchanter"), #(sh.cache and sh.cache.candidates or {}), #(sh.pendingTransforms or {}), #(sh.history or {})))
    end
    print("  Fresh-start build: no material IDs, quantities, or prices are distributed.")
end

-- ============================================================================
-- Shelf Scout - passive TSM Shopping market-structure observer + opt-in Goblin Radar
-- ============================================================================
-- Shelf Scout never sends auction queries and never buys anything. It watches the
-- auction-list pages TSM Shopping already requested, reconstructs the unit-price
-- ladder, highlights thin cheap tails beneath denser shelves, and independently
-- flags live lows that are unusually cheap relative to the TSM custom source "mycost".

local SHELF_SCOUT_SCHEMA = 3
local SHELF_SCOUT_HISTORY_MAX = 30
local SHELF_SCOUT_PAGE_SETTLE_DELAY = 0.08
local shelfRuntime = {
    hookInstalled = false,
    pendingQuery = nil,
    querySerial = 0,
    pages = {},
    current = nil,
    candidates = {},
    badge = nil,
    panel = nil,
    panelLines = {},
    ownNames = {},
    lastDebug = nil,
}

-- Goblin Radar is deliberately NOT a persistent mode. Shelf Scout remains passive
-- unless the user explicitly presses one of the Radar scan buttons (or runs the
-- corresponding slash command). A Radar scan may send serialized AH queries, but
-- it never buys, bids, cancels, posts, or changes TSM operations.
local GOBLIN_RADAR_SCHEMA = 2
local GOBLIN_RADAR_RESULT_MAX = 24
local goblinRuntime = {
    panel = nil,
    rows = {},
    scanActive = false,
    scanToken = 0,
    queue = {},
    queueIndex = 0,
    category = nil,
    results = {},
    current = nil,
    lastStatus = "Passive. Pick a candidate list when you want to hunt.",
    lastTSMQueryAt = 0,
    lastTSMQueryName = nil,
    queryRetries = 0,
    activity = {},
}
local GoblinShowPanel
local GoblinRefreshPanel
local GoblinHandleCapturedPage
local GoblinStopScan

-- User-triggered Shredder live-stock refresh. This is deliberately separate from
-- the local TSM cache scan: it sends exact-item AH queries only while the user has
-- the Auction House open, and serializes them so it does not compete with itself.
_G.UBKShredderLiveRuntime = _G.UBKShredderLiveRuntime or {
    active=false,
    token=0,
    queue={},
    queueIndex=0,
    current=nil,
    queryRetries=0,
    maxPages=10,
    lastStatus="No live AH stock refresh has been run this session.",
}

local function EnsureShelfScoutState(db)
    if type(db.shelfScout) ~= "table" then db.shelfScout = {} end
    local ss = db.shelfScout
    ss.schema = SHELF_SCOUT_SCHEMA
    if ss.enabled == nil then ss.enabled = true end
    if ss.debug == nil then ss.debug = false end
    if type(ss.history) ~= "table" then ss.history = {} end
    -- Migrate legacy shelf-only history in place so an existing SavedVariables
    -- file displays correctly after the schema-2 value-radar upgrade.
    for _, h in ipairs(ss.history) do
        if type(h) == "table" and not h.shelfStatus and (h.status == "LOOK" or h.status == "WEAK") and h.shelfLow then
            h.shelfStatus = h.status
        end
    end
    if type(ss.config) ~= "table" then ss.config = {} end
    local c = ss.config
    if c.shelfBandPct == nil then c.shelfBandPct = 0.025 end
    if c.minRecoveryPct == nil then c.minRecoveryPct = 0.06 end
    if c.lookRecoveryPct == nil then c.lookRecoveryPct = 0.08 end
    if c.minCliffPct == nil then c.minCliffPct = 0.015 end
    if c.stepPct == nil then c.stepPct = 0.018 end
    if c.minShelfPosts == nil then c.minShelfPosts = 4 end
    if c.minShelfQty == nil then c.minShelfQty = 8 end
    if c.maxTailPosts == nil then c.maxTailPosts = 14 end
    if c.lookScore == nil then c.lookScore = 8 end
    if c.weakScore == nil then c.weakScore = 6 end
    -- Value Radar is intentionally independent from shelf detection. "mycost"
    -- is a user-controlled TSM custom source (currently matprice). UBK only
    -- highlights unusually cheap live listings relative to that source.
    if c.deepCostPct == nil then c.deepCostPct = 0.65 end
    if c.lowCostPct == nil then c.lowCostPct = 0.75 end

    if type(ss.goblin) ~= "table" then ss.goblin = {} end
    local g = ss.goblin
    g.schema = GOBLIN_RADAR_SCHEMA
    if type(g.config) ~= "table" then g.config = {} end
    local gc = g.config
    if gc.highEndMinValue == nil then gc.highEndMinValue = 80000 end -- 8g
    if gc.highEndCachedPct == nil then gc.highEndCachedPct = 0.90 end
    if gc.highEndLivePct == nil then gc.highEndLivePct = 0.65 end
    if gc.commonMinValue == nil then gc.commonMinValue = 5000 end -- 50s
    if gc.commonCachedPct == nil then gc.commonCachedPct = 0.82 end
    if gc.commonLivePct == nil then gc.commonLivePct = 0.65 end
    if gc.rareMinValue == nil then gc.rareMinValue = 20000 end -- 2g
    if gc.rareCachedPct == nil then gc.rareCachedPct = 0.82 end
    if gc.rareLivePct == nil then gc.rareLivePct = 0.60 end
    if gc.rareLoosePct == nil then gc.rareLoosePct = 0.75 end
    if gc.rareMaxPosts == nil then gc.rareMaxPosts = 12 end
    if gc.rareLooseMaxPosts == nil then gc.rareLooseMaxPosts = 6 end
    if gc.maxSingleCategory == nil then gc.maxSingleCategory = 18 end
    if gc.maxAllCategory == nil then gc.maxAllCategory = 12 end
    if gc.maxExactPages == nil then gc.maxExactPages = 4 end
    if gc.querySettleDelay == nil then gc.querySettleDelay = 0.18 end
    -- TSM AuctionDB/AppHelper-derived market intelligence. These values
    -- affect Radar ranking / context only. They never alter UBK acquisition basis.
    if gc.marketContext == nil then gc.marketContext = true end
    if gc.saleRateStrong == nil then gc.saleRateStrong = 0.20 end
    if gc.saleRateHealthy == nil then gc.saleRateHealthy = 0.08 end
    if gc.soldPerDayStrong == nil then gc.soldPerDayStrong = 5 end
    if gc.soldPerDayHealthy == nil then gc.soldPerDayHealthy = 1 end
    if gc.regionDiscountLook == nil then gc.regionDiscountLook = 0.80 end
    return ss
end

local function ShelfPct(value)
    return string.format("%.1f%%", (tonumber(value) or 0) * 100)
end

local function ShelfShortMoney(copper)
    copper = math.max(0, RoundCopper(copper or 0))
    if copper >= 10000 then
        local gold = copper / 10000
        if gold >= 100 then return string.format("%.0fg", gold) end
        if gold >= 10 then return string.format("%.1fg", gold) end
        return string.format("%.2fg", gold)
    end
    return FormatMoney(copper)
end

local function ShelfAccountNames()
    wipe(shelfRuntime.ownNames)
    local player = UnitName("player")
    if player then shelfRuntime.ownNames[player:lower()] = true end
    if type(TradeSkillMasterDB) ~= "table" then return end
    for key in pairs(TradeSkillMasterDB) do
        if type(key) == "string" then
            local character = key:match(TSMCharacterPrefixPattern())
            if character and character ~= "" then
                shelfRuntime.ownNames[character:lower()] = true
            end
        end
    end
end

local function ShelfSellerIsOurs(seller)
    if not seller or seller == "" then return false end
    local short = seller:match("^([^-]+)") or seller
    return shelfRuntime.ownNames[short:lower()] and true or false
end

local function ShelfShoppingActive()
    local db = GetRealmDB()
    local ss = EnsureShelfScoutState(db)
    if not ss.enabled then return false end
    local auctionVisible = false
    if type(TSM_API) == "table" and type(TSM_API.IsUIVisible) == "function" then
        local ok, result = pcall(TSM_API.IsUIVisible, "AUCTION")
        auctionVisible = ok and result and true or false
    end
    if not auctionVisible then return false end

    local shopping = _G.TSMShoppingBuyoutBtn
    if shopping and shopping.IsShown then return shopping:IsShown() and true or false end
    return false
end

local function ShelfItemStringFromLink(link)
    local id = type(link) == "string" and link:match("|Hitem:(%d+)") or nil
    return id and ("i:" .. tostring(tonumber(id))) or nil
end

local function ShelfGetReferenceValue(itemString)
    if not itemString or type(TSM_API) ~= "table" or type(TSM_API.GetCustomPriceValue) ~= "function" then return nil end
    local ok, value = pcall(TSM_API.GetCustomPriceValue, "fairvalue", itemString)
    if ok and type(value) == "number" and value > 0 then return value end
    ok, value = pcall(TSM_API.GetCustomPriceValue, "dbrecent", itemString)
    if ok and type(value) == "number" and value > 0 then return value end
    return nil
end

local function ShelfGetMyCost(itemString)
    if not itemString then return nil end
    local db = GetRealmDB()
    local state = db and db.items and db.items[itemString] or nil

    -- UBK deliberately trusts acquisition provenance before trusting a raw TSM literal.
    -- This prevents an old guessed custom material value from masquerading as a
    -- resale basis. Manual economic values (for example Primal Nether) remain valid
    -- for crafting math but are intentionally excluded from AH flip signals.
    if state and CostTrustedForRadar(state, itemString) then
        local value = GetUnitBasis(state)
        if value and value > 0 then return value, CostProvenanceLabel(state, itemString) end
    end

    -- If UBK has no state yet, only fully verified account-local cost evidence may
    -- serve as a temporary cost reference. Once Universal discovery runs, the state
    -- becomes authoritative.
    if not state then
        local class, audit = CostAuditClass(itemString)
        if class == "history-full" and audit and (tonumber(audit.retainedBasis) or 0) > 0 then
            return tonumber(audit.retainedBasis), class
        end
    end
    return nil, state and CostProvenanceLabel(state, itemString) or nil
end

local function ShelfValueStatus(lowPrice, mycost, cfg)
    if not lowPrice or lowPrice <= 0 or not mycost or mycost <= 0 then return nil, nil end
    local ratio = lowPrice / mycost
    if ratio <= cfg.deepCostPct then return "DEEP", ratio end
    if ratio <= cfg.lowCostPct then return "LOW", ratio end
    return nil, ratio
end

local function ShelfDisplayStatus(candidate)
    if not candidate then return nil end
    if candidate.shelfStatus and candidate.valueStatus then
        return candidate.shelfStatus .. " + " .. candidate.valueStatus
    end
    return candidate.shelfStatus or candidate.valueStatus
end

local function ShelfStatusColor(candidate)
    if not candidate then return "|cff888888" end
    if candidate.shelfStatus == "LOOK" then return "|cff33ff99" end
    if candidate.valueStatus == "DEEP" then return "|cff66ccff" end
    return "|cffffcc00"
end

local function ShelfCandidatePriority(candidate)
    if not candidate then return -1 end
    local priority = 0
    if candidate.shelfStatus == "LOOK" then
        priority = priority + 400
    elseif candidate.shelfStatus == "WEAK" then
        priority = priority + 200
    end
    if candidate.valueStatus == "DEEP" then
        priority = priority + 150
    elseif candidate.valueStatus == "LOW" then
        priority = priority + 50
    end
    priority = priority + (tonumber(candidate.score) or 0)
    return priority
end

local function ShelfCollapseLevels(records)
    local byPrice, prices = {}, {}
    for _, rec in ipairs(records) do
        local price = rec.unitPrice
        if price and price > 0 and rec.quantity and rec.quantity > 0 then
            local level = byPrice[price]
            if not level then
                level = { price = price, qty = 0, posts = 0, cost = 0 }
                byPrice[price] = level
                prices[#prices + 1] = price
            end
            level.qty = level.qty + rec.quantity
            level.posts = level.posts + 1
            level.cost = level.cost + rec.buyout
        end
    end
    table.sort(prices)
    local levels = {}
    for _, price in ipairs(prices) do levels[#levels + 1] = byPrice[price] end
    return levels
end

local function ShelfCountSteps(levels, lastIndex, stepPct)
    local count = 0
    for i = 2, lastIndex do
        local prev, cur = levels[i - 1].price, levels[i].price
        if prev > 0 and ((cur / prev) - 1) >= stepPct then count = count + 1 end
    end
    return count
end

local function ShelfAnalyze(records, itemString, itemName)
    local db = GetRealmDB()
    local ss = EnsureShelfScoutState(db)
    local cfg = ss.config
    local levels = ShelfCollapseLevels(records)
    if #levels == 0 then return nil, levels end

    local marketLow = levels[1].price
    local mycost, costProvenance = ShelfGetMyCost(itemString)
    local valueStatus, costRatio = ShelfValueStatus(marketLow, mycost, cfg)

    local bestShelf = nil
    if #levels >= 3 then
        for startIndex = 2, #levels do
            local shelfLow = levels[startIndex].price
            local shelfHighLimit = shelfLow * (1 + cfg.shelfBandPct)
            local shelfQty, shelfPosts, shelfCost, shelfHigh = 0, 0, 0, shelfLow
            local endIndex = startIndex
            while endIndex <= #levels and levels[endIndex].price <= shelfHighLimit do
                local level = levels[endIndex]
                shelfQty = shelfQty + level.qty
                shelfPosts = shelfPosts + level.posts
                shelfCost = shelfCost + level.cost
                shelfHigh = level.price
                endIndex = endIndex + 1
            end

            local tailQty, tailPosts, tailCost = 0, 0, 0
            for i = 1, startIndex - 1 do
                tailQty = tailQty + levels[i].qty
                tailPosts = tailPosts + levels[i].posts
                tailCost = tailCost + levels[i].cost
            end
            local tailLow = levels[1].price
            local tailHigh = levels[startIndex - 1].price
            local recovery = tailLow > 0 and (shelfLow / tailLow - 1) or 0
            local cliff = tailHigh > 0 and (shelfLow / tailHigh - 1) or 0
            local steps = ShelfCountSteps(levels, startIndex - 1, cfg.stepPct)
            local shelfRatio = tailQty > 0 and shelfQty / tailQty or math.huge

            if tailPosts > 0
                and tailPosts <= cfg.maxTailPosts
                and shelfPosts >= cfg.minShelfPosts
                and shelfQty >= cfg.minShelfQty
                and shelfQty >= math.max(cfg.minShelfQty, tailQty * 1.15)
                and recovery >= cfg.minRecoveryPct
                and (cliff >= cfg.minCliffPct or steps >= 2) then

                local score = 0
                if recovery >= 0.15 then score = score + 3 elseif recovery >= cfg.lookRecoveryPct then score = score + 2 else score = score + 1 end
                if cliff >= 0.05 then score = score + 2 elseif cliff >= cfg.minCliffPct then score = score + 1 end
                if shelfPosts >= 10 then score = score + 2 elseif shelfPosts >= cfg.minShelfPosts then score = score + 1 end
                if shelfRatio >= 3 then score = score + 2 elseif shelfRatio >= 1.5 then score = score + 1 end
                if tailPosts <= 5 then score = score + 2 elseif tailPosts <= 9 then score = score + 1 end
                if tailCost <= 5000000 then score = score + 2 elseif tailCost <= 15000000 then score = score + 1 end -- 500g / 1500g
                if steps >= 2 then score = score + 1 end

                local reference = ShelfGetReferenceValue(itemString)
                if reference and shelfLow > reference * 1.50 then score = score - 2 end

                local shelfStatus = score >= cfg.lookScore and recovery >= cfg.lookRecoveryPct and "LOOK" or (score >= cfg.weakScore and "WEAK" or nil)
                if shelfStatus then
                    local candidate = {
                        shelfStatus = shelfStatus,
                        score = score,
                        itemString = itemString,
                        itemName = itemName or itemString or "Unknown item",
                        low = tailLow,
                        tailHigh = tailHigh,
                        shelfLow = shelfLow,
                        shelfHigh = shelfHigh,
                        tailQty = tailQty,
                        tailPosts = tailPosts,
                        tailCost = tailCost,
                        shelfQty = shelfQty,
                        shelfPosts = shelfPosts,
                        recovery = recovery,
                        cliff = cliff,
                        steps = steps,
                        reference = reference,
                        seenAt = time and time() or 0,
                    }
                    if not bestShelf or candidate.score > bestShelf.score or (candidate.score == bestShelf.score and candidate.recovery > bestShelf.recovery) then
                        bestShelf = candidate
                    end
                end
            end
        end
    end

    -- A value signal can stand on its own. This is what lets normal Browse /
    -- Shopping scans surface "cheap for us" listings even when there is no
    -- resettable shelf. It is still only a LOOK-AT-THIS signal, never BUY.
    if not bestShelf and not valueStatus then return nil, levels end

    local candidate = bestShelf or {
        score = 0,
        itemString = itemString,
        itemName = itemName or itemString or "Unknown item",
        low = marketLow,
        seenAt = time and time() or 0,
    }
    candidate.mycost = mycost
    candidate.costProvenance = costProvenance
    candidate.costRatio = costRatio
    candidate.valueStatus = valueStatus
    candidate.status = ShelfDisplayStatus(candidate)
    candidate.priority = ShelfCandidatePriority(candidate)
    return candidate, levels
end

local function ShelfStoreHistory(candidate)
    if not candidate then return end
    local ss = EnsureShelfScoutState(GetRealmDB())
    local history = ss.history
    local key = tostring(candidate.itemString or candidate.itemName) .. ":" .. tostring(candidate.shelfLow or "value")
    for i = #history, 1, -1 do
        if history[i].key == key then table.remove(history, i) end
    end
    table.insert(history, 1, {
        key = key,
        status = candidate.status,
        shelfStatus = candidate.shelfStatus,
        valueStatus = candidate.valueStatus,
        itemString = candidate.itemString,
        itemName = candidate.itemName,
        low = candidate.low,
        mycost = candidate.mycost,
        costProvenance = candidate.costProvenance,
        costRatio = candidate.costRatio,
        shelfLow = candidate.shelfLow,
        shelfHigh = candidate.shelfHigh,
        tailQty = candidate.tailQty,
        tailPosts = candidate.tailPosts,
        tailCost = candidate.tailCost,
        shelfQty = candidate.shelfQty,
        shelfPosts = candidate.shelfPosts,
        recovery = candidate.recovery,
        cliff = candidate.cliff,
        steps = candidate.steps,
        score = candidate.score,
        priority = candidate.priority,
        seenAt = candidate.seenAt,
    })
    while #history > SHELF_SCOUT_HISTORY_MAX do table.remove(history) end
end

local function ShelfCreateUI()
    if shelfRuntime.badge then return end
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    local badge = CreateFrame("Button", "UBKShelfScoutBadge", UIParent, template)
    badge:SetSize(260, 24)
    badge:SetFrameStrata("DIALOG")
    badge:EnableMouse(true)
    if badge.SetBackdrop then
        badge:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        badge:SetBackdropColor(0.04, 0.04, 0.04, 0.95)
        badge:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    end
    badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    badge.text:SetPoint("LEFT", 7, 0)
    badge.text:SetPoint("RIGHT", -7, 0)
    badge.text:SetJustifyH("LEFT")
    badge.text:SetText("UBK Shelf Scout: waiting")
    badge:Hide()
    shelfRuntime.badge = badge

    local panel = CreateFrame("Frame", "UBKShelfScoutPanel", UIParent, template)
    panel:SetSize(430, 278)
    panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -60, -170)
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if panel.SetBackdrop then
        panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        panel:SetBackdropColor(0.02, 0.02, 0.02, 0.96)
    end
    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", 12, -10)
    panel.title:SetText("UBK Shelf Scout |cff888888(passive)|r")
    panel.goblinBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.goblinBtn:SetSize(112, 20)
    panel.goblinBtn:SetPoint("TOPRIGHT", -10, -6)
    panel.goblinBtn:SetText("Goblin Radar")
    panel.goblinBtn:SetScript("OnClick", function()
        if GoblinShowPanel then GoblinShowPanel() end
    end)
    panel.current = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.current:SetPoint("TOPLEFT", 12, -32)
    panel.current:SetPoint("TOPRIGHT", -12, -32)
    panel.current:SetJustifyH("LEFT")
    panel.current:SetText("Waiting for a TSM Shopping scan.")
    panel.detail = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.detail:SetPoint("TOPLEFT", 12, -52)
    panel.detail:SetPoint("TOPRIGHT", -12, -52)
    panel.detail:SetJustifyH("LEFT")
    panel.detail:SetText("Passive by default. Goblin Radar only queries after you press a scan button.")
    panel.heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.heading:SetPoint("TOPLEFT", 12, -88)
    panel.heading:SetText("Recent candidates")
    for i = 1, 7 do
        local line = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", 12, -88 - i * 24)
        line:SetPoint("RIGHT", -12, 0)
        line:SetJustifyH("LEFT")
        line:SetText("")
        shelfRuntime.panelLines[i] = line
    end
    panel.footer = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.footer:SetPoint("BOTTOMLEFT", 12, 10)
    panel.footer:SetText("/ubk shelf status  •  /ubk goblin show  •  click badge to hide/show")
    panel:Hide()
    shelfRuntime.panel = panel
    badge:SetScript("OnClick", function()
        if panel:IsShown() then panel:Hide() else panel:Show() end
    end)
    badge:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("UBK Shelf Scout", 1, 0.82, 0)
        local c = shelfRuntime.current
        if c then
            GameTooltip:AddLine(c.itemName .. " — " .. tostring(c.status or "candidate"), 1, 1, 1)
            if c.mycost and c.costRatio then
                GameTooltip:AddLine(string.format("Live low: %s = %s of mycost (%s)", ShelfShortMoney(c.low), ShelfPct(c.costRatio), ShelfShortMoney(c.mycost)), 0.65, 0.9, 1)
            end
            if c.shelfStatus then
                GameTooltip:AddLine(string.format("Cheap tail: %d posts / %d units / %s", c.tailPosts or 0, c.tailQty or 0, ShelfShortMoney(c.tailCost)), 0.9, 0.9, 0.9)
                GameTooltip:AddLine(string.format("Shelf: %s–%s (%d posts / %d units)", ShelfShortMoney(c.shelfLow), ShelfShortMoney(c.shelfHigh), c.shelfPosts or 0, c.shelfQty or 0), 0.9, 0.9, 0.9)
                GameTooltip:AddLine(string.format("Recovery %s • cliff %s • %d stepped drops", ShelfPct(c.recovery), ShelfPct(c.cliff), c.steps or 0), 0.9, 0.9, 0.9)
            elseif c.valueStatus then
                GameTooltip:AddLine("Value signal only — no conservative shelf detected.", 0.9, 0.9, 0.9)
            end
            GameTooltip:AddLine("Candidate only — you decide whether it is resellable.", 0.6, 0.8, 1)
        else
            GameTooltip:AddLine("No shelf or mycost value candidate in the current result set.", 0.75, 0.75, 0.75)
        end
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

local function ShelfAnchorBadge()
    ShelfCreateUI()
    local badge = shelfRuntime.badge
    local buy = _G.TSMShoppingBuyoutBtn

    -- Keep the badge inside TSM's own Shopping frame hierarchy. Test 7 used
    -- UIParent + DIALOG strata, which made the badge float above unrelated TSM
    -- windows (Groups / Operations / Settings) when they overlapped Shopping.
    -- Parenting it to the Buyout button gives us TSM's visibility and layering
    -- automatically: if Shopping is hidden or another TSM window is in front,
    -- Shelf Scout behaves like part of Shopping instead of a global overlay.
    if buy and buy.IsShown and buy:IsShown() then
        if badge:GetParent() ~= buy then badge:SetParent(buy) end
        if buy.GetFrameStrata and badge.SetFrameStrata then
            badge:SetFrameStrata(buy:GetFrameStrata())
        end
        if buy.GetFrameLevel and badge.SetFrameLevel then
            badge:SetFrameLevel((buy:GetFrameLevel() or 0) + 1)
        end
        badge:ClearAllPoints()
        badge:SetPoint("BOTTOMRIGHT", buy, "TOPRIGHT", 0, 5)
        return true
    end

    -- There is deliberately no UIParent fallback. A Shelf Scout badge without
    -- a visible Shopping Buyout button has no useful context and risks bleeding
    -- through other windows.
    if badge:GetParent() ~= UIParent then badge:SetParent(UIParent) end
    badge:ClearAllPoints()
    badge:Hide()
    return false
end

local function ShelfRefreshPanel()
    ShelfCreateUI()
    local badge, panel = shelfRuntime.badge, shelfRuntime.panel
    local current = shelfRuntime.current
    if current then
        local statusColor = ShelfStatusColor(current)
        local costText = current.mycost and current.costRatio and string.format("  %s mycost", ShelfPct(current.costRatio)) or ""
        if current.shelfStatus then
            badge.text:SetText(string.format("%sUBK %s|r  %s  %s → %s  +%s%s",
                statusColor, current.status or current.shelfStatus, current.itemName, ShelfShortMoney(current.low), ShelfShortMoney(current.shelfLow), ShelfPct(current.recovery), costText))
            panel.current:SetText(string.format("%s%s|r  %s", statusColor, current.status or current.shelfStatus, current.itemName))
            local detail = string.format("Tail %d posts / %d units / %s  •  shelf %s–%s (%d posts / %d units)  •  recovery %s  •  cliff %s",
                current.tailPosts or 0, current.tailQty or 0, ShelfShortMoney(current.tailCost), ShelfShortMoney(current.shelfLow), ShelfShortMoney(current.shelfHigh), current.shelfPosts or 0, current.shelfQty or 0, ShelfPct(current.recovery), ShelfPct(current.cliff))
            if current.mycost and current.costRatio then
                detail = detail .. string.format("  •  low %s of mycost %s", ShelfPct(current.costRatio), ShelfShortMoney(current.mycost))
            end
            panel.detail:SetText(detail)
        else
            badge.text:SetText(string.format("%sUBK %s|r  %s  %s = %s mycost",
                statusColor, current.status or current.valueStatus or "VALUE", current.itemName, ShelfShortMoney(current.low), ShelfPct(current.costRatio)))
            panel.current:SetText(string.format("%s%s|r  %s", statusColor, current.status or current.valueStatus or "VALUE", current.itemName))
            panel.detail:SetText(string.format("Live low %s  •  mycost %s  •  %s of mycost  •  no conservative shelf detected",
                ShelfShortMoney(current.low), ShelfShortMoney(current.mycost), ShelfPct(current.costRatio)))
        end
    else
        badge.text:SetText("|cff888888UBK Shelf Scout|r  no shelf/value candidate")
        panel.current:SetText(shelfRuntime.pendingQuery and ("Scanning: " .. tostring(shelfRuntime.pendingQuery.name or "?")) or "Waiting for a TSM Shopping scan.")
        panel.detail:SetText("No conservative shelf or LOW/DEEP mycost candidate yet. This is not a buy recommendation.")
    end
    local ss = EnsureShelfScoutState(GetRealmDB())
    for i = 1, #shelfRuntime.panelLines do
        local h = ss.history[i]
        if h then
            local color = ShelfStatusColor(h)
            if h.shelfStatus then
                local costSuffix = h.mycost and h.costRatio and ("  " .. ShelfPct(h.costRatio) .. " cost") or ""
                shelfRuntime.panelLines[i]:SetText(string.format("%s%s|r  %s  %s → %s  +%s%s",
                    color, h.status or h.shelfStatus or "?", h.itemName or h.itemString or "?", ShelfShortMoney(h.low), ShelfShortMoney(h.shelfLow), ShelfPct(h.recovery), costSuffix))
            else
                shelfRuntime.panelLines[i]:SetText(string.format("%s%s|r  %s  %s = %s mycost",
                    color, h.status or h.valueStatus or "?", h.itemName or h.itemString or "?", ShelfShortMoney(h.low), ShelfPct(h.costRatio)))
            end
        else
            shelfRuntime.panelLines[i]:SetText("")
        end
    end
    -- With standalone Universal Basis Keeper installed, keep Shelf Scout as an
    -- analysis engine only. UBK owns the visible market UI; the old Shopping
    -- badge would duplicate information and cover TSM results. The diagnostic
    -- /ubk shelf show panel remains available when explicitly requested.
    if type(_G.UBKInterface_Show) == "function" then
        badge:Hide()
    else
        local anchored = ShelfAnchorBadge()
        if anchored and ShelfShoppingActive() then badge:Show() else badge:Hide() end
    end
end

local function ShelfAnalyzeCurrentPages()
    local grouped = {}
    for _, pageRecords in pairs(shelfRuntime.pages) do
        for _, rec in ipairs(pageRecords) do
            local key = rec.itemString or ("name:" .. tostring(rec.name or "?"))
            if not grouped[key] then grouped[key] = { itemString = rec.itemString, name = rec.name, records = {} } end
            grouped[key].records[#grouped[key].records + 1] = rec
        end
    end

    local best = nil
    local debugItems = {}
    for _, info in pairs(grouped) do
        local candidate, levels = ShelfAnalyze(info.records, info.itemString, info.name)
        debugItems[#debugItems + 1] = { name = info.name, itemString = info.itemString, records = #info.records, levels = #levels, candidate = candidate }
        if candidate then
            local candidatePriority = tonumber(candidate.priority) or ShelfCandidatePriority(candidate)
            local bestPriority = best and (tonumber(best.priority) or ShelfCandidatePriority(best)) or -1
            local candidateTie = candidate.recovery or (candidate.costRatio and (1 - candidate.costRatio)) or 0
            local bestTie = best and (best.recovery or (best.costRatio and (1 - best.costRatio)) or 0) or -1
            if not best or candidatePriority > bestPriority or (candidatePriority == bestPriority and candidateTie > bestTie) then
                best = candidate
            end
        end
    end
    shelfRuntime.current = best
    shelfRuntime.lastDebug = { query = shelfRuntime.pendingQuery, items = debugItems }
    if best and (not shelfRuntime.pendingQuery or (shelfRuntime.pendingQuery.source ~= "goblin" and shelfRuntime.pendingQuery.source ~= "shredder")) then ShelfStoreHistory(best) end
    ShelfRefreshPanel()
end

local function ShelfCaptureAuctionPage(serial, page)
    local pending = shelfRuntime.pendingQuery
    if not pending or pending.serial ~= serial or pending.page ~= page then return end
    if pending.source ~= "goblin" and pending.source ~= "shredder" and not ShelfShoppingActive() then return end
    local num, total = GetNumAuctionItems("list")
    num = tonumber(num) or 0
    total = tonumber(total) or num
    local records = {}
    local missingLinks = 0
    for i = 1, num do
        local name, _, stackSize, _, _, _, _, _, _, buyout, _, _, _, seller = GetAuctionItemInfo("list", i)
        stackSize = tonumber(stackSize) or 0
        buyout = tonumber(buyout) or 0
        if stackSize > 0 and buyout > 0 and not ShelfSellerIsOurs(seller) then
            local link = GetAuctionItemLink("list", i)
            if not link then missingLinks = missingLinks + 1 end
            local itemString = ShelfItemStringFromLink(link)
            records[#records + 1] = {
                name = name,
                itemString = itemString,
                quantity = stackSize,
                buyout = buyout,
                unitPrice = math.floor(buyout / stackSize + 0.5),
                seller = seller,
            }
        end
    end
    shelfRuntime.pages[page] = records
    pending.totalAuctions = total
    pending.pageRows = num
    local ss = EnsureShelfScoutState(GetRealmDB())
    if ss.debug then
        print(string.format("|cff66ccffUBK Shelf:|r page %d for '%s': %d rows (%d total), %d usable, %d links pending.", page, tostring(pending.name or ""), num, total, #records, missingLinks))
    end
    ShelfAnalyzeCurrentPages()
    if pending.source == "goblin" and GoblinHandleCapturedPage then
        GoblinHandleCapturedPage(page, num, total)
    elseif pending.source == "shredder" and _G.UBKShredderInternal and _G.UBKShredderInternal.HandleLiveCapturedPage then
        _G.UBKShredderInternal.HandleLiveCapturedPage(page, num, total)
    end
end

local function ShelfOnAuctionListUpdate()
    local pending = shelfRuntime.pendingQuery
    if not pending then return end
    if pending.source ~= "goblin" and pending.source ~= "shredder" and not ShelfShoppingActive() then return end
    -- Read the page immediately. TSM may advance to the next page within a frame,
    -- and the legacy AH API exposes only the currently loaded page.
    ShelfCaptureAuctionPage(pending.serial, pending.page)
end

local function ShelfQueryHook(name, minLevel, maxLevel, page, usable, quality, getAll, exact)
    if getAll then return end
    local db = GetRealmDB()
    local ss = EnsureShelfScoutState(db)
    page = tonumber(page) or 0

    local goblinWatching = goblinRuntime.scanActive and goblinRuntime.current
        and tostring(name or "") == tostring(goblinRuntime.current.name or "")
        and page == (tonumber(goblinRuntime.current.page) or 0)
    local shredderRT = _G.UBKShredderLiveRuntime
    local shredderWatching = shredderRT and shredderRT.active and shredderRT.current
        and tostring(name or "") == tostring(shredderRT.current.name or "")
        and page == (tonumber(shredderRT.current.page) or 0)
    -- Explicit Radar/Shredder scans must still be capturable even if passive Shelf
    -- Scout is disabled. The setting controls passive inspection, not user-clicked
    -- live query workflows.
    if not ss.enabled and not goblinWatching and not shredderWatching then return end
    if not goblinWatching and not shredderWatching and not ShelfShoppingActive() then return end

    local source = goblinWatching and "goblin" or (shredderWatching and "shredder" or "tsm")
    if source == "tsm" then
        goblinRuntime.lastTSMQueryAt = GetTime and GetTime() or 0
        goblinRuntime.lastTSMQueryName = name
    end
    local signature = table.concat({ tostring(name or ""), tostring(minLevel or ""), tostring(maxLevel or ""), tostring(quality or ""), tostring(exact and 1 or 0) }, "|")
    if page == 0 or not shelfRuntime.pendingQuery or shelfRuntime.pendingQuery.signature ~= signature or shelfRuntime.pendingQuery.source ~= source then
        shelfRuntime.querySerial = shelfRuntime.querySerial + 1
        wipe(shelfRuntime.pages)
        shelfRuntime.current = nil
    end
    shelfRuntime.pendingQuery = {
        serial = shelfRuntime.querySerial,
        signature = signature,
        name = name or "",
        page = page,
        source = source,
        hookedAt = GetTime and GetTime() or 0,
    }
    if ss.debug then
        local label = source == "goblin" and "Goblin Radar" or (source == "shredder" and "Shredder" or "TSM")
        print(string.format("|cff66ccffUBK Shelf:|r watching %s query '%s' page %d.", label, tostring(name or ""), page))
    end
    ShelfRefreshPanel()
end

local function ShelfInstallHook()
    if shelfRuntime.hookInstalled or type(QueryAuctionItems) ~= "function" or type(hooksecurefunc) ~= "function" then return false end
    hooksecurefunc("QueryAuctionItems", ShelfQueryHook)
    shelfRuntime.hookInstalled = true
    ShelfAccountNames()
    ShelfCreateUI()
    return true
end

local function ShelfCloseUI()
    if shelfRuntime.badge then shelfRuntime.badge:Hide() end
    if shelfRuntime.panel then shelfRuntime.panel:Hide() end
end

local function ShelfPrintStatus(verbose)
    local ss = EnsureShelfScoutState(GetRealmDB())
    print(string.format("|cffffcc00UBK Shelf Scout:|r %s; query hook %s; passive unless Goblin Radar is explicitly started.", ss.enabled and "ON" or "OFF", shelfRuntime.hookInstalled and "installed" or "not installed"))
    print(string.format("  Shelf: LOOK score %d, WEAK %d, recovery ≥ %s, shelf band %s, tail ≤ %d posts.", ss.config.lookScore, ss.config.weakScore, ShelfPct(ss.config.minRecoveryPct), ShelfPct(ss.config.shelfBandPct), ss.config.maxTailPosts))
    print(string.format("  Value Radar: DEEP ≤ %s mycost; LOW ≤ %s mycost. mycost is evaluated through TSM for each live item.", ShelfPct(ss.config.deepCostPct), ShelfPct(ss.config.lowCostPct)))
    print("  Passive Shelf Scout never sends queries. Goblin Radar may send serialized exact-item queries only after you press a scan button; neither mode ever buys.")
    if shelfRuntime.pendingQuery then
        print(string.format("  Last query: %s page %d; captured pages %d.", tostring(shelfRuntime.pendingQuery.name or ""), tonumber(shelfRuntime.pendingQuery.page) or 0, (function() local n=0 for _ in pairs(shelfRuntime.pages) do n=n+1 end return n end)()))
    end
    if shelfRuntime.current then
        local c = shelfRuntime.current
        local color = ShelfStatusColor(c)
        if c.shelfStatus then
            local costSuffix = c.mycost and c.costRatio and string.format("; %s of mycost %s", ShelfPct(c.costRatio), ShelfShortMoney(c.mycost)) or ""
            print(string.format("  Current: %s%s|r %s; %s -> shelf %s; tail %d posts/%d units/%s; recovery %s%s.",
                color, c.status or c.shelfStatus, c.itemName, ShelfShortMoney(c.low), ShelfShortMoney(c.shelfLow), c.tailPosts or 0, c.tailQty or 0, ShelfShortMoney(c.tailCost), ShelfPct(c.recovery), costSuffix))
        else
            print(string.format("  Current: %s%s|r %s; %s = %s of mycost %s; no conservative shelf.",
                color, c.status or c.valueStatus or "VALUE", c.itemName, ShelfShortMoney(c.low), ShelfPct(c.costRatio), ShelfShortMoney(c.mycost)))
        end
    end
    if verbose and shelfRuntime.lastDebug then
        for _, d in ipairs(shelfRuntime.lastDebug.items or {}) do
            print(string.format("  debug: %s (%s) %d records / %d price levels / %s", tostring(d.name or "?"), tostring(d.itemString or "?"), d.records or 0, d.levels or 0, d.candidate and (d.candidate.status .. " score " .. d.candidate.score) or "no candidate"))
        end
    end
end

-- ============================================================================
-- Goblin Radar - user-triggered candidate generator + exact-item AH scout
-- ============================================================================

local function GoblinPrice(source, itemString)
    if not itemString or type(TSM_API) ~= "table" or type(TSM_API.GetCustomPriceValue) ~= "function" then return nil end
    local ok, value = pcall(TSM_API.GetCustomPriceValue, source, itemString)
    if ok and type(value) == "number" and value > 0 then return value end
    return nil
end

-- TSM's public custom-price API is our intentionally stable boundary to
-- AppHelper/AuctionDB. UBK does not parse AppData.lua directly. This keeps
-- acquisition accounting isolated while still letting Radar use TSM's decoded
-- realm / region market and liquidity statistics.
goblinRuntime.MarketContext = function(itemString)
    local m = {
        dbmarket = GoblinPrice("dbmarket", itemString),
        minbuyout = GoblinPrice("dbminbuyout", itemString),
        recent = GoblinPrice("dbrecent", itemString),
        historical = GoblinPrice("dbhistorical", itemString),
        regionMarket = GoblinPrice("dbregionmarketavg", itemString),
        regionHistorical = GoblinPrice("dbregionhistorical", itemString),
        regionSaleAvg = GoblinPrice("dbregionsaleavg", itemString),
        saleRate = GoblinPrice("dbregionsalerate", itemString),
        soldPerDay = GoblinPrice("dbregionsoldperday", itemString),
        vendorSell = GoblinPrice("vendorsell", itemString),
    }
    local regionTotal, regionN = 0, 0
    for _, v in ipairs({ m.regionMarket, m.regionHistorical, m.regionSaleAvg }) do
        if v and v > 0 then regionTotal, regionN = regionTotal + v, regionN + 1 end
    end
    m.regionReference = regionN > 0 and (regionTotal / regionN) or nil
    local realmTotal, realmN = 0, 0
    for _, v in ipairs({ m.dbmarket, m.recent, m.historical }) do
        if v and v > 0 then realmTotal, realmN = realmTotal + v, realmN + 1 end
    end
    m.realmReference = realmN > 0 and (realmTotal / realmN) or nil
    -- Decision workspaces use the newest decoded realm observation first,
    -- then the current minimum, then the broader realm average.
    m.cachedLow = m.recent or m.minbuyout or m.dbmarket
    if m.cachedLow and m.regionReference and m.regionReference > 0 then
        m.regionRatio = m.cachedLow / m.regionReference
    end
    if m.cachedLow and m.realmReference and m.realmReference > 0 then
        m.realmRatio = m.cachedLow / m.realmReference
    end
    return m
end

goblinRuntime.LiquidityLabel = function(m, cfg)
    if not m then return "UNKNOWN", 0 end
    local rate, perDay = tonumber(m.saleRate), tonumber(m.soldPerDay)
    if (rate and rate >= cfg.saleRateStrong) or (perDay and perDay >= cfg.soldPerDayStrong) then
        return "ACTIVE", 12
    end
    if (rate and rate >= cfg.saleRateHealthy) or (perDay and perDay >= cfg.soldPerDayHealthy) then
        return "HEALTHY", 6
    end
    if (rate and rate > 0) or (perDay and perDay > 0) then
        return "THIN", -3
    end
    return "UNKNOWN", 0
end

goblinRuntime.MarketScore = function(m, cfg)
    if not m then return 0 end
    local _, liquidityScore = goblinRuntime.LiquidityLabel(m, cfg)
    local score = liquidityScore
    if m.regionRatio then
        if m.regionRatio <= 0.60 then score = score + 14
        elseif m.regionRatio <= cfg.regionDiscountLook then score = score + 8
        elseif m.regionRatio >= 1.25 then score = score - 5 end
    end
    if m.realmRatio and m.realmRatio <= 0.75 then score = score + 4 end
    return score
end

local function GoblinItemName(itemString)
    if type(TSM_API) == "table" and type(TSM_API.GetItemName) == "function" then
        local ok, name = pcall(TSM_API.GetItemName, itemString)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    local id = type(itemString) == "string" and tonumber(itemString:match("^i:(%d+)")) or nil
    if id and type(GetItemInfo) == "function" then
        local name = GetItemInfo(id)
        if name then return name end
    end
    return nil
end

local function GoblinItemLink(itemString)
    if type(TSM_API) == "table" and type(TSM_API.GetItemLink) == "function" then
        local ok, link = pcall(TSM_API.GetItemLink, itemString)
        if ok and type(link) == "string" and not link:find("Unknown Item", 1, true) then return link end
    end
    local id = type(itemString) == "string" and tonumber(itemString:match("^i:(%d+)")) or nil
    if id and type(GetItemInfo) == "function" then
        local _, link = GetItemInfo(id)
        return link
    end
    return nil
end

local function GoblinItemQuality(itemString)
    local link = GoblinItemLink(itemString)
    if link and type(GetItemInfo) == "function" then
        local _, _, quality = GetItemInfo(link)
        if type(quality) == "number" then return quality end
    end
    local id = type(itemString) == "string" and tonumber(itemString:match("^i:(%d+)")) or nil
    if id and type(GetItemInfo) == "function" then
        local _, _, quality = GetItemInfo(id)
        if type(quality) == "number" then return quality end
    end
    return nil
end

local function GoblinGroupPath(itemString)
    if type(TSM_API) ~= "table" or type(TSM_API.GetGroupPathByItem) ~= "function" then return nil end
    local ok, path = pcall(TSM_API.GetGroupPathByItem, itemString)
    return ok and path or nil
end

local function GoblinCollectUniverse()
    local universe = {}
    if type(TSM_API) == "table" and type(TSM_API.GetGroupPaths) == "function" and type(TSM_API.GetGroupItems) == "function" then
        local paths = {}
        local ok = pcall(TSM_API.GetGroupPaths, paths)
        if ok then
            for _, path in ipairs(paths) do
                local items = {}
                if pcall(TSM_API.GetGroupItems, path, false, items) then
                    for _, itemString in ipairs(items) do
                        if type(itemString) == "string" and not universe[itemString] then
                            universe[itemString] = { itemString = itemString, groupPath = path, isMaterial = false }
                        end
                    end
                end
            end
        end
    end
    local db = GetRealmDB()
    if db and type(db.items) == "table" then
        for itemString, state in pairs(db.items) do
            if type(itemString) == "string" and not universe[itemString] then
                universe[itemString] = { itemString = itemString, groupPath = GoblinGroupPath(itemString), isMaterial = state and state.tsmMaterial and true or false, ubkTracked = true }
            elseif universe[itemString] then
                universe[itemString].ubkTracked = true
            end
        end
    end
    local mats = UBK_GetTSMMatsTable()
    if type(mats) == "table" then
        for itemString in pairs(mats) do
            if type(itemString) == "string" then
                if not universe[itemString] then
                    universe[itemString] = { itemString = itemString, groupPath = GoblinGroupPath(itemString), isMaterial = true }
                else
                    universe[itemString].isMaterial = true
                end
            end
        end
    end
    return universe
end

local function GoblinCachedInfo(info)
    local itemString = info.itemString
    info.name = info.name or GoblinItemName(itemString)
    info.quality = info.quality or GoblinItemQuality(itemString)
    info.groupPath = info.groupPath or GoblinGroupPath(itemString)
    info.mycost, info.costProvenance = ShelfGetMyCost(itemString)
    info.fair = GoblinPrice("fairvalue", itemString)
    info.market = goblinRuntime.MarketContext(itemString)
    info.recent = info.market.recent
    info.cachedLow = info.market.cachedLow
    info.value = math.max(info.mycost or 0, info.fair or 0, info.recent or 0, info.market.regionReference or 0)
    local cached = info.cachedLow or info.recent
    info.costCachedRatio = info.mycost and cached and info.mycost > 0 and (cached / info.mycost) or nil
    info.fairCachedRatio = info.fair and cached and info.fair > 0 and (cached / info.fair) or nil
    info.regionCachedRatio = info.market.regionRatio
    return info
end

local function GoblinSortSeeds(list)
    table.sort(list, function(a, b)
        if (a.seedScore or 0) ~= (b.seedScore or 0) then return (a.seedScore or 0) > (b.seedScore or 0) end
        return tostring(a.name or a.itemString) < tostring(b.name or b.itemString)
    end)
end

local function GoblinBuildCategory(category, limit)
    local ss = EnsureShelfScoutState(GetRealmDB())
    local cfg = ss.goblin.config
    local universe = GoblinCollectUniverse()
    local list = {}
    for _, raw in pairs(universe) do
        local info = GoblinCachedInfo(raw)
        if info.name and info.value > 0 then
            local ratio = nil
            local include = false
            local score = 0
            if category == "high" then
                ratio = info.costCachedRatio or info.fairCachedRatio
                include = info.isMaterial and info.value >= cfg.highEndMinValue and ratio and ratio <= cfg.highEndCachedPct
                if include then
                    score = (1 - ratio) * 180 + math.min(info.value / 10000, 100) * 0.20 + goblinRuntime.MarketScore(info.market, cfg)
                end
            elseif category == "common" then
                ratio = info.costCachedRatio or info.fairCachedRatio
                local qualityOK = info.quality == nil or info.quality <= 1
                include = qualityOK and info.value >= cfg.commonMinValue and ratio and ratio <= cfg.commonCachedPct
                if include then
                    score = (1 - ratio) * 150 + math.min(info.value / 10000, 50) * 0.10 + (info.isMaterial and 4 or 0) + goblinRuntime.MarketScore(info.market, cfg)
                end
            elseif category == "rare" then
                ratio = info.fairCachedRatio or info.costCachedRatio
                local qualityOK = info.quality == 2 or info.quality == 3
                local sparseCached = info.recent == nil and info.fair and info.fair >= cfg.rareMinValue
                include = qualityOK and info.value >= cfg.rareMinValue and ((ratio and ratio <= cfg.rareCachedPct) or sparseCached)
                if include then
                    score = (ratio and (1 - ratio) * 150 or 25) + math.min(info.value / 10000, 100) * 0.15 + (sparseCached and 10 or 0) + goblinRuntime.MarketScore(info.market, cfg)
                end
            end
            if include then
                info.category = category
                info.seedScore = score
                list[#list + 1] = info
            end
        end
    end
    GoblinSortSeeds(list)
    while #list > limit do table.remove(list) end
    return list
end

local function GoblinBuildQueue(category)
    local cfg = EnsureShelfScoutState(GetRealmDB()).goblin.config
    if category == "all" then
        local combined, seen = {}, {}
        for _, cat in ipairs({ "high", "common", "rare" }) do
            for _, info in ipairs(GoblinBuildCategory(cat, cfg.maxAllCategory)) do
                if not seen[info.itemString] then
                    seen[info.itemString] = true
                    combined[#combined + 1] = info
                end
            end
        end
        GoblinSortSeeds(combined)
        return combined
    end
    return GoblinBuildCategory(category, cfg.maxSingleCategory)
end

local function GoblinCategoryName(category)
    if category == "high" then return "High-End Materials" end
    if category == "common" then return "Flippable Common" end
    if category == "rare" then return "Uncommon & Rare" end
    if category == "all" then return "Full Market Sweep" end
    return tostring(category or "Candidates")
end

local function GoblinCanQueryNow()
    if type(CanSendAuctionQuery) ~= "function" then return true end
    local ok, canQuery = pcall(CanSendAuctionQuery)
    return ok and canQuery and true or false
end

local function GoblinAuctionVisible()
    if type(TSM_API) == "table" and type(TSM_API.IsUIVisible) == "function" then
        local ok, visible = pcall(TSM_API.IsUIVisible, "AUCTION")
        if ok and visible then return true end
    end
    return false
end

local function GoblinResultReason(category, shelfCandidate, low, posts, qty, mycost, fair, cfg)
    local costRatio = mycost and mycost > 0 and low / mycost or nil
    local fairRatio = fair and fair > 0 and low / fair or nil
    if category == "high" then
        if costRatio and costRatio <= cfg.highEndLivePct then return "DEEP RESALE", costRatio, fairRatio end
        if shelfCandidate and shelfCandidate.shelfStatus == "LOOK" and (not costRatio or costRatio <= 0.72) then return "THIN SHELF", costRatio, fairRatio end
        if not mycost and fairRatio and fairRatio <= 0.55 then return "DEEP VS FAIR", costRatio, fairRatio end
    elseif category == "common" then
        if costRatio and costRatio <= cfg.commonLivePct then return "DEEP", costRatio, fairRatio end
        if fairRatio and fairRatio <= 0.60 then return "MISPRICE", costRatio, fairRatio end
        if shelfCandidate and shelfCandidate.shelfStatus == "LOOK" then return "SHELF", costRatio, fairRatio end
        if shelfCandidate and shelfCandidate.shelfStatus == "WEAK" and costRatio and costRatio <= 0.75 then return "WEAK + LOW", costRatio, fairRatio end
    elseif category == "rare" then
        if posts <= cfg.rareMaxPosts and fairRatio and fairRatio <= cfg.rareLivePct then return "SCARCE MISPRICE", costRatio, fairRatio end
        if posts <= cfg.rareLooseMaxPosts and fairRatio and fairRatio <= cfg.rareLoosePct then return "SCARCE LOW", costRatio, fairRatio end
        if posts <= cfg.rareMaxPosts and costRatio and costRatio <= 0.60 then return "SCARCE DEEP", costRatio, fairRatio end
        if shelfCandidate and shelfCandidate.shelfStatus and posts <= 20 then return "THIN SHELF", costRatio, fairRatio end
    end
    return nil, costRatio, fairRatio
end

local function GoblinEvaluateCurrent(entry)
    local records = {}
    for _, pageRecords in pairs(shelfRuntime.pages) do
        for _, rec in ipairs(pageRecords) do
            if rec.itemString == entry.itemString or (not rec.itemString and rec.name == entry.name) then
                records[#records + 1] = rec
            end
        end
    end
    if #records == 0 then return nil end
    local low, posts, qty = nil, 0, 0
    for _, rec in ipairs(records) do
        if not low or rec.unitPrice < low then low = rec.unitPrice end
        posts = posts + 1
        qty = qty + (rec.quantity or 0)
    end
    if not low or low <= 0 then return nil end
    local shelfCandidate = ShelfAnalyze(records, entry.itemString, entry.name)
    local mycost = ShelfGetMyCost(entry.itemString)
    local fair = GoblinPrice("fairvalue", entry.itemString)
    local market = goblinRuntime.MarketContext(entry.itemString)
    local cfg = EnsureShelfScoutState(GetRealmDB()).goblin.config
    local reason, costRatio, fairRatio = GoblinResultReason(entry.category, shelfCandidate, low, posts, qty, mycost, fair, cfg)
    if not reason then return nil end
    local discount = 0
    if costRatio then discount = math.max(discount, 1 - costRatio) end
    if fairRatio then discount = math.max(discount, 1 - fairRatio) end
    local regionLiveRatio = market.regionReference and market.regionReference > 0 and (low / market.regionReference) or nil
    local realmLiveRatio = market.realmReference and market.realmReference > 0 and (low / market.realmReference) or nil
    local liquidity = goblinRuntime.LiquidityLabel(market, cfg)
    local score = discount * 200 + goblinRuntime.MarketScore(market, cfg)
    if regionLiveRatio then
        if regionLiveRatio <= 0.60 then score = score + 18
        elseif regionLiveRatio <= cfg.regionDiscountLook then score = score + 10
        elseif regionLiveRatio >= 1.25 then score = score - 6 end
    end
    if shelfCandidate and shelfCandidate.shelfStatus == "LOOK" then score = score + 80 elseif shelfCandidate and shelfCandidate.shelfStatus == "WEAK" then score = score + 35 end
    if entry.category == "rare" then score = score + math.max(0, 20 - posts) * 2 end
    return {
        itemString = entry.itemString,
        itemName = entry.name,
        category = entry.category,
        reason = reason,
        low = low,
        posts = posts,
        qty = qty,
        mycost = mycost,
        fair = fair,
        costRatio = costRatio,
        fairRatio = fairRatio,
        market = market,
        liquidity = liquidity,
        regionLiveRatio = regionLiveRatio,
        realmLiveRatio = realmLiveRatio,
        shelfStatus = shelfCandidate and shelfCandidate.shelfStatus or nil,
        shelfLow = shelfCandidate and shelfCandidate.shelfLow or nil,
        shelfHigh = shelfCandidate and shelfCandidate.shelfHigh or nil,
        tailQty = shelfCandidate and shelfCandidate.tailQty or nil,
        tailPosts = shelfCandidate and shelfCandidate.tailPosts or nil,
        tailCost = shelfCandidate and shelfCandidate.tailCost or nil,
        shelfQty = shelfCandidate and shelfCandidate.shelfQty or nil,
        shelfPosts = shelfCandidate and shelfCandidate.shelfPosts or nil,
        cliff = shelfCandidate and shelfCandidate.cliff or nil,
        recovery = shelfCandidate and shelfCandidate.recovery or nil,
        score = score,
        seenAt = time and time() or 0,
    }
end

local function GoblinRecordActivity(entry, result)
    if not entry then return end
    local a = {
        itemString = entry.itemString,
        itemName = entry.name or GoblinItemName(entry.itemString) or entry.itemString,
        kept = result and true or false,
        reason = result and (result.reason or "candidate") or "no qualifying live signal",
        low = result and result.low or nil,
        costRatio = result and result.costRatio or nil,
        shelfStatus = result and result.shelfStatus or nil,
        seenAt = time and time() or 0,
    }
    table.insert(goblinRuntime.activity, 1, a)
    while #goblinRuntime.activity > 8 do table.remove(goblinRuntime.activity) end
end

local function GoblinSortResults()
    table.sort(goblinRuntime.results, function(a, b)
        if (a.score or 0) ~= (b.score or 0) then return (a.score or 0) > (b.score or 0) end
        return tostring(a.itemName or a.itemString) < tostring(b.itemName or b.itemString)
    end)
    while #goblinRuntime.results > GOBLIN_RADAR_RESULT_MAX do table.remove(goblinRuntime.results) end
end

local function GoblinStopReason(message)
    goblinRuntime.scanActive = false
    goblinRuntime.current = nil
    goblinRuntime.lastStatus = message or "Stopped. Shelf analysis remains active in Universal Basis Keeper."
    if GoblinRefreshPanel then GoblinRefreshPanel() end
end

GoblinStopScan = function(message)
    GoblinStopReason(message or "Goblin Radar stopped. Shelf analysis remains active in Universal Basis Keeper.")
end

local function GoblinSendCurrentPage()
    if not goblinRuntime.scanActive or not goblinRuntime.current then return end
    if not GoblinAuctionVisible() then
        GoblinStopReason("Auction House / TSM Auction UI is not open. Radar stopped.")
        return
    end
    if not GoblinCanQueryNow() then
        goblinRuntime.queryRetries = (goblinRuntime.queryRetries or 0) + 1
        if goblinRuntime.queryRetries > 80 then
            GoblinStopReason("AH query throttle did not clear. Radar stopped safely.")
            return
        end
        C_Timer.After(0.20, GoblinSendCurrentPage)
        return
    end
    goblinRuntime.queryRetries = 0
    local cur = goblinRuntime.current
    goblinRuntime.lastStatus = string.format("Scanning %d/%d: %s (page %d)", goblinRuntime.queueIndex, #goblinRuntime.queue, cur.name, (cur.page or 0) + 1)
    if GoblinRefreshPanel then GoblinRefreshPanel() end
    local ok, err = pcall(QueryAuctionItems, cur.name, nil, nil, cur.page or 0, false, nil, false, true)
    if not ok then
        GoblinStopReason("AH query failed safely: " .. tostring(err))
    end
end

local function GoblinStartNext()
    if not goblinRuntime.scanActive then return end
    goblinRuntime.queueIndex = goblinRuntime.queueIndex + 1
    local entry = goblinRuntime.queue[goblinRuntime.queueIndex]
    if not entry then
        goblinRuntime.scanActive = false
        goblinRuntime.current = nil
        GoblinSortResults()
        goblinRuntime.lastStatus = string.format("Done: %d item%s scanned; %d candidate%s worth inspecting.", #goblinRuntime.queue, #goblinRuntime.queue == 1 and "" or "s", #goblinRuntime.results, #goblinRuntime.results == 1 and "" or "s")
        if GoblinRefreshPanel then GoblinRefreshPanel() end
        return
    end
    wipe(shelfRuntime.pages)
    shelfRuntime.current = nil
    goblinRuntime.current = {
        itemString = entry.itemString,
        name = entry.name,
        category = entry.category,
        page = 0,
        entry = entry,
    }
    C_Timer.After(0.12, GoblinSendCurrentPage)
end

GoblinHandleCapturedPage = function(page, num, total)
    if not goblinRuntime.scanActive or not goblinRuntime.current then return end
    local cur = goblinRuntime.current
    if tonumber(page) ~= tonumber(cur.page) then return end
    local cfg = EnsureShelfScoutState(GetRealmDB()).goblin.config
    local pageSize = 50
    cur.totalResults = tonumber(total) or tonumber(num) or 0
    cur.totalPages = math.max(1, math.min(cfg.maxExactPages or 1, math.ceil(math.max(1, cur.totalResults) / pageSize)))
    local hasMore = (tonumber(num) or 0) >= pageSize and ((page + 1) * pageSize) < (tonumber(total) or 0)
    if hasMore and page + 1 < cfg.maxExactPages then
        cur.page = page + 1
        C_Timer.After(cfg.querySettleDelay, GoblinSendCurrentPage)
        return
    end
    local result = GoblinEvaluateCurrent(cur.entry)
    if result then
        local replaced = false
        for i, existing in ipairs(goblinRuntime.results) do
            if existing.itemString == result.itemString then
                goblinRuntime.results[i] = result
                replaced = true
                break
            end
        end
        if not replaced then goblinRuntime.results[#goblinRuntime.results + 1] = result end
        GoblinSortResults()
    end
    GoblinRecordActivity(cur.entry, result)
    if GoblinRefreshPanel then GoblinRefreshPanel() end
    C_Timer.After(cfg.querySettleDelay, GoblinStartNext)
end

local function GoblinStartScan(category)
    local ss = EnsureShelfScoutState(GetRealmDB())
    if not ss.enabled then
        print("|cffff7777UBK:|r Shelf Scout is OFF. Turn it on before using Goblin Radar.")
        return
    end
    if not GoblinAuctionVisible() then
        print("|cffff7777UBK:|r open the Auction House with the TSM Auction UI first.")
        return
    end
    if goblinRuntime.scanActive then GoblinStopReason("Previous Radar scan replaced by a new candidate list.") end
    local now = GetTime and GetTime() or 0
    if goblinRuntime.lastTSMQueryAt and now - goblinRuntime.lastTSMQueryAt < 0.8 then
        print("|cffffaa00UBK:|r TSM is still actively querying. Let that scan settle for a moment, then press the Radar button again.")
        return
    end
    local queue = GoblinBuildQueue(category)
    wipe(goblinRuntime.queue)
    for _, entry in ipairs(queue) do goblinRuntime.queue[#goblinRuntime.queue + 1] = entry end
    wipe(goblinRuntime.results)
    wipe(goblinRuntime.activity)
    goblinRuntime.queueIndex = 0
    goblinRuntime.category = category
    goblinRuntime.scanToken = goblinRuntime.scanToken + 1
    goblinRuntime.scanActive = #goblinRuntime.queue > 0
    if #goblinRuntime.queue == 0 then
        goblinRuntime.lastStatus = "No cached pre-candidates matched " .. GoblinCategoryName(category) .. ". Passive mode unchanged."
        if GoblinRefreshPanel then GoblinRefreshPanel() end
        return
    end
    goblinRuntime.lastStatus = string.format("Loaded %d %s pre-candidate%s. Starting exact AH checks...", #goblinRuntime.queue, GoblinCategoryName(category), #goblinRuntime.queue == 1 and "" or "s")
    if GoblinRefreshPanel then GoblinRefreshPanel() end
    GoblinStartNext()
end

local function GoblinOpenInTSM(result)
    if not result or not result.itemString then return false end
    if goblinRuntime.scanActive then
        print("|cffffaa00UBK:|r stop or finish the active UBK scan before opening a result in TSM.")
        return false
    end
    if not GoblinAuctionVisible() then
        print("|cffff7777UBK:|r open TSM > Browse at the Auction House first.")
        return false
    end
    if type(ChatEdit_GetActiveWindow) == "function" and ChatEdit_GetActiveWindow() then
        print("|cffffaa00UBK:|r close the active chat edit box first; otherwise WoW will put the item link into chat instead of handing it to TSM Browse.")
        return false
    end
    local link = GoblinItemLink(result.itemString)
    if not link then
        print("|cffff7777UBK:|r item link is not cached yet for " .. tostring(result.itemName or result.itemString) .. ".")
        return false
    end
    if type(ChatEdit_InsertLink) == "function" then
        local ok, accepted = pcall(ChatEdit_InsertLink, link)
        if ok and accepted then
            goblinRuntime.lastStatus = "Handed " .. tostring(result.itemName or result.itemString) .. " to TSM Browse for an item search."
            if GoblinRefreshPanel then GoblinRefreshPanel() end
            return true
        end
    end
    print("|cffff7777UBK:|r could not hand that item to TSM Browse automatically.")
    return false
end

local function GoblinRowText(r)
    local cat = r.category == "high" and "MAT" or (r.category == "common" and "COMMON" or "RARE")
    local ratio = ""
    if r.costRatio then ratio = "  " .. ShelfPct(r.costRatio) .. " mycost"
    elseif r.fairRatio then ratio = "  " .. ShelfPct(r.fairRatio) .. " fair" end
    local shelf = r.shelfLow and r.recovery and string.format("  shelf %s +%s", ShelfShortMoney(r.shelfLow), ShelfPct(r.recovery)) or ""
    local market = ""
    if r.liquidity and r.liquidity ~= "UNKNOWN" then market = market .. "  " .. r.liquidity end
    if r.regionLiveRatio and r.regionLiveRatio <= 0.85 then market = market .. "  " .. ShelfPct(r.regionLiveRatio) .. " region" end
    return string.format("[%s] %s — %s  %s%s%s%s", cat, r.reason or "LOOK", r.itemName or r.itemString, ShelfShortMoney(r.low), ratio, shelf, market)
end

local function GoblinCreateUI()
    if goblinRuntime.panel then return end
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    local panel = CreateFrame("Frame", "UBKGoblinRadarPanel", UIParent, template)
    panel:SetSize(670, 440)
    panel:SetPoint("CENTER", UIParent, "CENTER", 110, 20)
    panel:SetFrameStrata("HIGH")
    panel:SetFrameLevel(80)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if panel.SetBackdrop then
        panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        panel:SetBackdropColor(0.02, 0.02, 0.02, 0.97)
    end
    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", 14, -12)
    panel.title:SetText("UBK Goblin Radar")
    panel.subtitle = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.subtitle:SetPoint("TOPLEFT", 14, -32)
    panel.subtitle:SetText("Always passive until YOU press a scan. Radar queries only; never buys.")

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local buttons = {
        { key = "high", text = "High-End Materials", width = 142 },
        { key = "common", text = "Common Market Flips", width = 146 },
        { key = "rare", text = "Uncommon & Rare", width = 132 },
        { key = "all", text = "Full Market Sweep", width = 140 },
    }
    local x = 14
    for _, spec in ipairs(buttons) do
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetSize(spec.width, 24)
        b:SetPoint("TOPLEFT", x, -58)
        b:SetText(spec.text)
        b:SetScript("OnClick", function() GoblinStartScan(spec.key) end)
        x = x + spec.width + 6
    end
    panel.stop = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.stop:SetSize(64, 24)
    panel.stop:SetPoint("TOPRIGHT", -14, -58)
    panel.stop:SetText("Stop")
    panel.stop:SetScript("OnClick", function() GoblinStopScan("Radar stopped by you. Shelf analysis remains active in Universal Basis Keeper.") end)

    panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.status:SetPoint("TOPLEFT", 14, -92)
    panel.status:SetPoint("RIGHT", -14, 0)
    panel.status:SetJustifyH("LEFT")
    panel.status:SetText(goblinRuntime.lastStatus)

    panel.heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.heading:SetPoint("TOPLEFT", 14, -122)
    panel.heading:SetText("Confirmed candidates — click a row to hand that item to TSM Browse")

    for i = 1, 11 do
        local row = CreateFrame("Button", nil, panel)
        row:SetHeight(24)
        row:SetPoint("TOPLEFT", 12, -126 - i * 25)
        row:SetPoint("RIGHT", -12, 0)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetAllPoints()
        row.text:SetJustifyH("LEFT")
        row:SetScript("OnClick", function(self) if self.result then GoblinOpenInTSM(self.result) end end)
        row:SetScript("OnEnter", function(self)
            local r = self.result
            if not r or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(r.itemName or r.itemString, 1, 0.82, 0)
            GameTooltip:AddLine((r.reason or "Candidate") .. " — " .. GoblinCategoryName(r.category), 1, 1, 1)
            GameTooltip:AddLine(string.format("Live low %s • %d posts / %d units", ShelfShortMoney(r.low), r.posts or 0, r.qty or 0), 0.9, 0.9, 0.9)
            if r.mycost and r.costRatio then GameTooltip:AddLine(string.format("%s of mycost %s", ShelfPct(r.costRatio), ShelfShortMoney(r.mycost)), 0.65, 0.9, 1) end
            if r.fair and r.fairRatio then GameTooltip:AddLine(string.format("%s of fairvalue %s", ShelfPct(r.fairRatio), ShelfShortMoney(r.fair)), 0.8, 0.8, 0.8) end
            if r.market then
                if r.market.regionReference and r.regionLiveRatio then GameTooltip:AddLine(string.format("%s of regional reference %s", ShelfPct(r.regionLiveRatio), ShelfShortMoney(r.market.regionReference)), 0.75, 0.85, 1) end
                if r.market.dbmarket then GameTooltip:AddLine("TSM realm market " .. ShelfShortMoney(r.market.dbmarket), 0.75, 0.75, 0.75) end
                if r.market.saleRate or r.market.soldPerDay then
                    GameTooltip:AddLine(string.format("Regional liquidity: %s • sale rate %s • sold/day %s", tostring(r.liquidity or "UNKNOWN"), r.market.saleRate and string.format("%.3f", r.market.saleRate) or "n/a", r.market.soldPerDay and string.format("%.2f", r.market.soldPerDay) or "n/a"), 0.75, 0.9, 0.75)
                end
            end
            if r.shelfLow and r.recovery then GameTooltip:AddLine(string.format("Shelf %s • recovery %s", ShelfShortMoney(r.shelfLow), ShelfPct(r.recovery)), 0.8, 1, 0.8) end
            GameTooltip:AddLine("Click: open exact item search in TSM Browse", 0.6, 0.8, 1)
            GameTooltip:AddLine("Candidate only. UBK never buys.", 1, 0.75, 0.45)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        goblinRuntime.rows[i] = row
    end
    panel.footer = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.footer:SetPoint("BOTTOMLEFT", 14, 12)
    panel.footer:SetText("UBK v1.6: basis + live shelf + TSM AuctionDB context • candidate only; never buys")
    panel:Hide()
    goblinRuntime.panel = panel
end

GoblinRefreshPanel = function()
    GoblinCreateUI()
    local panel = goblinRuntime.panel
    panel.status:SetText(goblinRuntime.lastStatus or "Passive.")
    panel.stop:SetEnabled(goblinRuntime.scanActive and true or false)
    for i, row in ipairs(goblinRuntime.rows) do
        local result = goblinRuntime.results[i]
        row.result = result
        if result then
            row.text:SetText(GoblinRowText(result))
            row:Show()
        else
            row.text:SetText("")
            row:Hide()
        end
    end
end

GoblinShowPanel = function()
    GoblinCreateUI()
    GoblinRefreshPanel()
    goblinRuntime.panel:Show()
end

local function GoblinPrintStatus()
    print(string.format("|cffffcc00UBK Goblin Radar:|r %s", goblinRuntime.scanActive and "SCANNING (user-triggered)" or "PASSIVE / idle"))
    print("  High-End Materials: cached prefilter <= 90%; confirmed resale candidate generally <= 65% mycost or a strong thin shelf.")
    print("  Common Market Flips: cached prefilter <= 82%; confirms deep mycost/fairvalue discounts or usable shelf structure.")
    print("  Uncommon/Rare: grouped items with sparse/cheap cached data; confirms low live quantity plus a deep fairvalue discount.")
    print("  TSM AuctionDB/AppHelper context: realm/region value + regional sale rate/sold-per-day improve ranking; these NEVER modify mycost.")
    print("  Radar sends serialized exact-item AH queries only after you explicitly start it. It never buys, bids, posts, cancels, or changes TSM operations.")
    if goblinRuntime.category then
        print(string.format("  Last list: %s; %d queued; %d confirmed.", GoblinCategoryName(goblinRuntime.category), #goblinRuntime.queue, #goblinRuntime.results))
    end
end

goblinRuntime.PrintMarket = function(itemArg)
    local itemString = ResolveItem(itemArg)
    if not itemString then
        print("|cffff7777UBK:|r usage: /ubk goblin market <item link or item id>")
        return
    end
    local name = GoblinItemName(itemString) or itemString
    local m = goblinRuntime.MarketContext(itemString)
    local cfg = EnsureShelfScoutState(GetRealmDB()).goblin.config
    local liquidity = goblinRuntime.LiquidityLabel(m, cfg)
    local mycost, provenance = ShelfGetMyCost(itemString)
    print(string.format("|cffffcc00UBK Market Context:|r %s (%s)", name, itemString))
    if mycost then print(string.format("  trusted mycost: %s (%s)", ShelfShortMoney(mycost), tostring(provenance or "trusted"))) else print("  trusted mycost: none") end
    if m.minbuyout then print("  AuctionDB min buyout: " .. ShelfShortMoney(m.minbuyout)) end
    if m.dbmarket then print("  realm market: " .. ShelfShortMoney(m.dbmarket)) end
    if m.recent then print("  realm recent: " .. ShelfShortMoney(m.recent)) end
    if m.historical then print("  realm historical: " .. ShelfShortMoney(m.historical)) end
    if m.regionReference then print("  regional reference: " .. ShelfShortMoney(m.regionReference)) end
    if m.regionMarket then print("    region market avg: " .. ShelfShortMoney(m.regionMarket)) end
    if m.regionHistorical then print("    region historical: " .. ShelfShortMoney(m.regionHistorical)) end
    if m.regionSaleAvg then print("    region sale avg: " .. ShelfShortMoney(m.regionSaleAvg)) end
    print(string.format("  liquidity: %s • sale rate %s • sold/day %s", liquidity, m.saleRate and string.format("%.3f", m.saleRate) or "n/a", m.soldPerDay and string.format("%.2f", m.soldPerDay) or "n/a"))
    print("  |cffaaaaaaMarket data is TSM AuctionDB/AppHelper-derived context only; it cannot change UBK acquisition basis.|r")
end

local function GoblinCommand(rest)
    local raw = Trim(rest or "")
    local arg = NormalizeName(raw)
    local marketArg = raw:match("^[Mm][Aa][Rr][Kk][Ee][Tt]%s+(.+)$")
    if marketArg then
        goblinRuntime.PrintMarket(marketArg)
    elseif arg == "show" or arg == "" then
        GoblinShowPanel()
        GoblinPrintStatus()
    elseif arg == "high" or arg == "mats" or arg == "material" then
        GoblinShowPanel()
        GoblinStartScan("high")
    elseif arg == "common" or arg == "flip" or arg == "flips" then
        GoblinShowPanel()
        GoblinStartScan("common")
    elseif arg == "rare" or arg == "uncommon" then
        GoblinShowPanel()
        GoblinStartScan("rare")
    elseif arg == "all" or arg == "hardcore" then
        GoblinShowPanel()
        GoblinStartScan("all")
    elseif arg == "stop" then
        GoblinStopScan("Radar stopped by you. Shelf analysis remains active in Universal Basis Keeper.")
    elseif arg == "clear" then
        wipe(goblinRuntime.results)
        goblinRuntime.lastStatus = "Radar results cleared. Passive mode unchanged."
        GoblinRefreshPanel()
    elseif arg == "status" then
        GoblinPrintStatus()
    elseif arg == "hide" then
        if goblinRuntime.panel then goblinRuntime.panel:Hide() end
    else
        print("|cffff7777UBK:|r /ubk goblin [show|high|common|rare|all|market <item>|stop|clear|status|hide]")
    end
end


-- ============================================================================
-- Personal cost tooltip - works for crafting and non-crafting purchases
-- ============================================================================
UBK_TOOLTIP_HOOKS_INSTALLED = UBK_TOOLTIP_HOOKS_INSTALLED or false
function UBK_AddBasisToTooltip(tooltip)
    if _G.UBKLiveTooltip.Suppress(tooltip) then return end
    if not tooltip or not tooltip.GetItem then return end
    local _, link = tooltip:GetItem()
    local itemID = type(link) == "string" and link:match("item:(%d+)") or nil
    if not itemID then return end
    local itemString = "i:" .. tostring(tonumber(itemID))
    if IsUniversalExcluded(itemString) then return end
    if tooltip.__ubkBasisItem == itemString then return end
    tooltip.__ubkBasisItem = itemString
    local db = GetRealmDB()
    local state = db and db.items and db.items[itemString] or nil
    local known = state and (tonumber(state.qty) or 0) or 0
    local unresolved = state and (tonumber(state.bootstrapUnresolved) or 0) or 0
    local basis = state and GetUnitBasis(state) or nil

    _G.UBKLiveTooltip.Render(tooltip,state,itemString,GetUnitBasis,FormatMoney)

    -- Shredder context belongs at the bottom of the normal item tooltip. The
    -- Destroy source remains TSM's expected disenchant value; live stock is only
    -- shown when the user explicitly refreshed it at the Auction House.
    local internal=_G.UBKShredderInternal
    if internal and internal.ExpectedDestroyValue and internal.EnsureState then
        -- Do not ask TSM to evaluate its Destroy price source for herbs, gems,
        -- keys, consumables, or other items which cannot be disenchanted. This
        -- hook runs on every ordinary item tooltip, so the cheap local item-class
        -- gate prevents needless custom-price work while browsing the AH or a
        -- remote BagBrother bank.
        local eligible=false
        if type(internal.IsDisenchantableGear)=="function" then
            local ok,result=pcall(internal.IsDisenchantableGear,itemString)
            eligible=ok and result==true
        end
        if not eligible then return end
        local destroy=internal.ExpectedDestroyValue(itemString)
        if destroy and destroy>0 then
            local sh=internal.EnsureState(db)
            local live=sh.cache and sh.cache.liveStock and sh.cache.liveStock[itemString] or nil
            local candidate=sh.cache and sh.cache.candidateByItem and sh.cache.candidateByItem[itemString] or nil
            local comparePrice,compareLabel=nil,nil
            if known>0 and basis and basis>0 then
                comparePrice=basis; compareLabel="UBK basis"
            elseif live and tonumber(live.low) and tonumber(live.low)>0 then
                comparePrice=tonumber(live.low); compareLabel="live buy"
            elseif candidate and tonumber(candidate.buyout) and tonumber(candidate.buyout)>0 then
                comparePrice=tonumber(candidate.buyout); compareLabel="cached buy"
            end
            if comparePrice and comparePrice>0 then
                local edge=destroy-comparePrice
                local roi=edge/comparePrice
                local sign=edge>=0 and "+" or "-"
                tooltip:AddLine(string.format("UBK Shredder: DE %s  |  %s%s (%+.1f%%) vs %s",FormatMoney(destroy),sign,FormatMoney(math.abs(edge)),roi*100,compareLabel),0.45,0.95,0.75)
            else
                tooltip:AddLine("UBK Shredder: expected DE value "..FormatMoney(destroy),0.45,0.95,0.75)
            end
            if live then
                local age=math.max(0,(time and time() or 0)-(tonumber(live.updatedAt) or 0))
                local ageText=age<60 and (tostring(math.floor(age)).."s") or (age<3600 and (tostring(math.floor(age/60)).."m") or string.format("%.1fh",age/3600))
                local scope=live.complete and "AH stock" or "AH stock (partial scan)"
                local through=live.maxProfitablePrice and FormatMoney(live.maxProfitablePrice) or "none"
                local nextText=live.nextPrice and FormatMoney(live.nextPrice) or "none seen"
                tooltip:AddLine(string.format("UBK %s: %d unit%s seen  |  %d profitable  |  through %s  |  next %s  |  %s old",scope,tonumber(live.units) or 0,(tonumber(live.units) or 0)==1 and "" or "s",tonumber(live.profitableUnits) or 0,through,nextText,ageText),0.72,0.86,1,true)
            else
                tooltip:AddLine("UBK AH listings: not scanned yet. This is market availability, not your paid acquisition basis. (Inspector → Scan Now)",0.62,0.70,0.82,true)
            end
        end
    end
end

function UBK_InstallTooltipHooks()
    if UBK_TOOLTIP_HOOKS_INSTALLED then return end
    UBK_TOOLTIP_HOOKS_INSTALLED = true
    for _, tooltip in ipairs({_G.GameTooltip, _G.ItemRefTooltip}) do
        if tooltip and tooltip.HookScript then
            tooltip:HookScript("OnTooltipSetItem", UBK_AddBasisToTooltip)
            tooltip:HookScript("OnTooltipCleared", function(self) self.__ubkBasisItem = nil;self.__ubkLiveBasis=nil end)
            tooltip:HookScript("OnUpdate",function(self,elapsed)
                if _G.UBKLiveTooltip.mailboxOpen or _G.UBKLiveTooltip.Suppress(self) then return end
                self.__ubkBasisElapsed=(self.__ubkBasisElapsed or 0)+(elapsed or 0)
                if self.__ubkBasisElapsed<0.20 or not self.__ubkLiveBasis then return end
                self.__ubkBasisElapsed=0
                local item=self.__ubkBasisItem
                local db=item and GetRealmDB()
                if db then _G.UBKLiveTooltip.Render(self,db.items[item],item,GetUnitBasis,FormatMoney) end
            end)
        end
    end
end

-- ============================================================================
-- UBK Shredder engine
-- ============================================================================
-- The implementation lives on a global table instead of adding a large number of
-- top-level locals. UBK's main Lua chunk is already close to WoW Lua's local-variable
-- ceiling. The engine remains generic; each installation may designate its
-- own enchanter.
_G.UBKShredderInternal = _G.UBKShredderInternal or {}
_G.UBKShredderInternal.runtime = _G.UBKShredderInternal.runtime or {
    scanning=false, threadId=nil, lastError=nil, lastScanAt=0, lastScanCount=0,
}

function _G.UBKShredderInternal.EnsureState(db)
    if type(db.shredder) ~= "table" then db.shredder = {} end
    local sh = db.shredder
    sh.schema = 1
    if type(sh.enchanter) ~= "string" or sh.enchanter:match("^%s*$") then sh.enchanter = nil end
    if type(sh.settings) ~= "table" then sh.settings = {} end
    if sh.settings.minProfit == nil then sh.settings.minProfit = 10000 end -- 1g
    if sh.settings.minROI == nil then sh.settings.minROI = 0.20 end
    if sh.settings.maxBuyout == nil then sh.settings.maxBuyout = 2500000 end -- 250g
    if sh.settings.maxCandidates == nil then sh.settings.maxCandidates = 150 end
    if type(sh.processedDestroyCounts) ~= "table" then sh.processedDestroyCounts = {} end
    if type(sh.pendingTransforms) ~= "table" then sh.pendingTransforms = {} end
    if type(sh.history) ~= "table" then sh.history = {} end
    if type(sh.cache) ~= "table" then sh.cache = { candidates={}, generatedAt=0, status="Not scanned yet." } end
    if type(sh.cache.candidates) ~= "table" then sh.cache.candidates = {} end
    if type(sh.cache.candidateByItem) ~= "table" then
        sh.cache.candidateByItem = {}
        for _, row in ipairs(sh.cache.candidates) do
            if type(row)=="table" and type(row.itemString)=="string" then sh.cache.candidateByItem[row.itemString]=row end
        end
    end
    if type(sh.cache.liveStock) ~= "table" then sh.cache.liveStock = {} end
    return sh
end

function _G.UBKShredderInternal.GetHistoryTable()
    if type(TradeSkillMasterDB) ~= "table" then return nil end
    local all = TradeSkillMasterDB["g@ @internalData@destroyingHistory"]
    if type(all) ~= "table" then all = TradeSkillMasterDB["g@internalData@destroyingHistory"] end
    if type(all) ~= "table" then return nil end
    local de = all[13262] or all["13262"]
    return type(de) == "table" and de or nil
end

function _G.UBKShredderInternal.BaseItemString(itemString)
    if type(itemString) ~= "string" then return nil end
    local id = itemString:match("^i:(%d+)")
    return id and ("i:"..id) or itemString
end

function _G.UBKShredderInternal.DestroySignature(entry)
    if type(entry) ~= "table" then return nil end
    local parts = { tostring(tonumber(entry.time) or 0), tostring(entry.item or "") }
    local keys = {}
    for itemString in pairs(type(entry.result)=="table" and entry.result or {}) do keys[#keys+1]=itemString end
    table.sort(keys)
    for _, itemString in ipairs(keys) do
        parts[#parts+1] = tostring(itemString).."="..tostring(tonumber(entry.result[itemString]) or 0)
    end
    return table.concat(parts, "|")
end

function _G.UBKShredderInternal.BaselineDestroyHistory(db, quiet)
    local sh = _G.UBKShredderInternal.EnsureState(db)
    if sh.destroyBaselineDone then return false end
    local entries = _G.UBKShredderInternal.GetHistoryTable()
    local counts, newest, total = {}, 0, 0
    if entries then
        for _, entry in ipairs(entries) do
            local sig = _G.UBKShredderInternal.DestroySignature(entry)
            if sig then
                counts[sig] = (counts[sig] or 0) + 1
                newest = math.max(newest, tonumber(entry.time) or 0)
                total = total + 1
            end
        end
    end
    sh.processedDestroyCounts = counts
    sh.destroyBaselineDone = true
    sh.destroyBaselineAt = time and time() or 0
    sh.destroyBaselineNewest = newest
    sh.destroyBaselineRecords = total
    if not quiet then
        print(string.format("|cff33ff99UBK Shredder:|r armed after baselining %d existing TSM disenchant record%s. Only new destroys will transfer cost.", total, total==1 and "" or "s"))
    end
    return true
end

function _G.UBKShredderInternal.SourcePool(db, itemString, virtual)
    local exact = db.items[itemString] and itemString or nil
    local base = _G.UBKShredderInternal.BaseItemString(itemString)
    local key = exact or (base and db.items[base] and base) or nil
    if not key then return nil, nil end
    if virtual[key] then return key, virtual[key] end
    local state = db.items[key]
    local pool = {
        known = math.max(0, tonumber(state.qty) or 0),
        unresolved = math.max(0, tonumber(state.bootstrapUnresolved) or 0),
        basis = GetUnitBasis(state),
        trusted = CostTrustedForRadar(state, key) and true or false,
    }
    virtual[key] = pool
    return key, pool
end

function _G.UBKShredderInternal.ExpectedDestroyValue(itemString)
    if type(TSM_API) ~= "table" or type(TSM_API.GetCustomPriceValue) ~= "function" then return nil end
    local ok, value = pcall(TSM_API.GetCustomPriceValue, "Destroy", itemString)
    value = ok and tonumber(value) or nil
    return value and value > 0 and value or nil
end

function _G.UBKShredderInternal.CaptureNewHistory(db, quiet)
    local sh = _G.UBKShredderInternal.EnsureState(db)
    if not sh.destroyBaselineDone then
        _G.UBKShredderInternal.BaselineDestroyHistory(db, quiet)
        return 0
    end
    local entries = _G.UBKShredderInternal.GetHistoryTable()
    if not entries then return 0 end
    local seen, virtual, captured = {}, {}, 0
    for _, entry in ipairs(entries) do
        local sig = _G.UBKShredderInternal.DestroySignature(entry)
        if sig then
            seen[sig] = (seen[sig] or 0) + 1
            local occurrence = seen[sig]
            local already = tonumber(sh.processedDestroyCounts[sig]) or 0
            if occurrence > already then
                local sourceKey, pool = _G.UBKShredderInternal.SourcePool(db, entry.item, virtual)
                local sourceCost, sourceTrusted = nil, false
                if pool then
                    -- Mirror UBK's conservative outflow policy: unresolved units leave first.
                    if pool.unresolved > 0 then
                        pool.unresolved = pool.unresolved - 1
                    elseif pool.known > 0 then
                        pool.known = pool.known - 1
                        if pool.trusted and pool.basis and pool.basis > 0 then
                            sourceCost = pool.basis
                            sourceTrusted = true
                        end
                    end
                end
                sh.pendingTransforms[#sh.pendingTransforms+1] = {
                    signature=sig, occurrence=occurrence,
                    time=tonumber(entry.time) or (time and time() or 0),
                    sourceItem=entry.item, sourceStateItem=sourceKey,
                    sourceCost=sourceCost, sourceTrusted=sourceTrusted,
                    expectedDestroyValue=_G.UBKShredderInternal.ExpectedDestroyValue(entry.item),
                    outputs=CopyTable(type(entry.result)=="table" and entry.result or {}),
                    capturedAt=time and time() or 0,
                }
                sh.processedDestroyCounts[sig] = occurrence
                captured = captured + 1
            end
        end
    end
    if captured > 0 and not quiet then
        print(string.format("|cff33ff99UBK Shredder:|r captured %d new disenchant result%s for UBK cost transfer.", captured, captured==1 and "" or "s"))
    end
    return captured
end

function _G.UBKShredderInternal.EnsureTransformItem(db, itemString)
    local state = db.items[itemString]
    if state then return state end
    state = UBK_EnsurePurchasedItemForLedger(db, itemString, 0, time and time() or 0)
    if state then
        state.trackingClass = state.tsmMaterial and "tsm-material" or "transformed-item"
        state.seedSource = "shredder-output"
        state.costProvenance = "unresolved"
    end
    return state
end

function _G.UBKShredderInternal.OutputMarketWeight(itemString, qty)
    qty = tonumber(qty) or 0
    local price = GoblinPrice("dbmarket", itemString) or GoblinPrice("dbrecent", itemString) or GoblinPrice("dbhistorical", itemString)
    if price and price > 0 then return price * qty, price end
    return math.max(1, qty), nil
end

function _G.UBKShredderInternal.CanSettleTransform(db, tr)
    if type(tr.outputs) ~= "table" or not next(tr.outputs) then return false end
    for itemString, qty in pairs(tr.outputs) do
        qty = math.max(0, tonumber(qty) or 0)
        if qty > 0 then
            local state = db.items[itemString]
            local observed = GetRealmQuantityForItem(itemString)
            if state then
                local unresolved = tonumber(state.bootstrapUnresolved) or 0
                local modeled = (tonumber(state.qty) or 0) + unresolved
                local available = unresolved + math.max(0, (tonumber(observed) or 0) - modeled)
                if available + 0.0001 < qty then return false end
            else
                if (tonumber(observed) or 0) + 0.0001 < qty then return false end
            end
        end
    end
    return true
end

function _G.UBKShredderInternal.ResolveOutputAsKnown(db, itemString, qty, cost)
    local state = _G.UBKShredderInternal.EnsureTransformItem(db, itemString)
    if not state then return false end
    qty = math.max(0, tonumber(qty) or 0)
    if qty <= 0 then return true end
    local observed = GetRealmQuantityForItem(itemString)
    local unresolvedBefore = tonumber(state.bootstrapUnresolved) or 0
    local reclass = math.min(unresolvedBefore, qty)
    if reclass > 0 then ReduceUnresolvedForOutflow(state, reclass) end
    local remaining = qty - reclass
    local modeledAfter = (tonumber(state.qty) or 0) + (tonumber(state.bootstrapUnresolved) or 0)
    local unmodeled = math.max(0, (tonumber(observed) or 0) - modeledAfter)
    local newKnown = math.min(remaining, unmodeled)
    local totalKnown = reclass + newKnown
    if totalKnown + 0.0001 < qty then return false end

    state.qty = (tonumber(state.qty) or 0) + totalKnown
    state.value = (tonumber(state.value) or 0) + (tonumber(cost) or 0)
    state.lastBasis = GetUnitBasis(state)
    state.shredQty = (tonumber(state.shredQty) or 0) + totalKnown
    state.shredValue = (tonumber(state.shredValue) or 0) + (tonumber(cost) or 0)
    local prior = CostProvenanceLabel(state, itemString)
    if prior == "unresolved" or prior == "no-audit" or prior == "shredder-transfer" then
        state.costProvenance = "shredder-transfer"
    else
        state.costProvenance = "mixed-trusted"
    end
    state.basisReady = GetUnitBasis(state) > 0
    state.lastObserved = tonumber(observed) or state.lastObserved
    return true
end

function _G.UBKShredderInternal.ResolveOutputAsUnknown(db, itemString, qty)
    local state = _G.UBKShredderInternal.EnsureTransformItem(db, itemString)
    if not state then return false end
    qty = math.max(0, tonumber(qty) or 0)
    if qty <= 0 then return true end
    local observed = GetRealmQuantityForItem(itemString)
    local unresolved = tonumber(state.bootstrapUnresolved) or 0
    local modeled = (tonumber(state.qty) or 0) + unresolved
    local unmodeled = math.max(0, (tonumber(observed) or 0) - modeled)
    local alreadyAvailable = math.min(unresolved, qty)
    local need = qty - alreadyAvailable
    if need > 0 then
        local add = math.min(need, unmodeled)
        if add > 0 then AddUnresolvedLot(state, add) end
        alreadyAvailable = alreadyAvailable + add
    end
    state.lastObserved = tonumber(observed) or state.lastObserved
    return alreadyAvailable + 0.0001 >= qty
end

function _G.UBKShredderInternal.SettlePendingTransforms(db, quiet)
    local sh = _G.UBKShredderInternal.EnsureState(db)
    local settled, keep = 0, {}
    for _, tr in ipairs(sh.pendingTransforms) do
        if _G.UBKShredderInternal.CanSettleTransform(db, tr) then
            local allocations, weightTotal = {}, 0
            if tr.sourceCost and tr.sourceCost > 0 then
                for itemString, qty in pairs(tr.outputs) do
                    local weight = _G.UBKShredderInternal.OutputMarketWeight(itemString, qty)
                    allocations[itemString] = weight
                    weightTotal = weightTotal + weight
                end
            end
            local okAll = true
            if tr.sourceCost and tr.sourceCost > 0 and weightTotal > 0 then
                local assigned, lastKey = 0, nil
                local keys = {}
                for itemString in pairs(tr.outputs) do keys[#keys+1]=itemString end
                table.sort(keys)
                for i, itemString in ipairs(keys) do
                    lastKey = itemString
                    local cost
                    if i == #keys then cost = math.max(0, tr.sourceCost - assigned)
                    else
                        cost = tr.sourceCost * ((allocations[itemString] or 0) / weightTotal)
                        assigned = assigned + cost
                    end
                    allocations[itemString] = cost
                    if not _G.UBKShredderInternal.ResolveOutputAsKnown(db, itemString, tr.outputs[itemString], cost) then okAll=false; break end
                end
            else
                for itemString, qty in pairs(tr.outputs) do
                    allocations[itemString] = nil
                    if not _G.UBKShredderInternal.ResolveOutputAsUnknown(db, itemString, qty) then okAll=false; break end
                end
            end

            if okAll then
                local actualMarketValue=0
                for itemString,qty in pairs(tr.outputs or {}) do
                    local mv=GoblinPrice("dbmarket",itemString) or GoblinPrice("dbrecent",itemString) or GoblinPrice("dbhistorical",itemString)
                    if mv and mv>0 then actualMarketValue=actualMarketValue+mv*(tonumber(qty) or 0) end
                end
                tr.settledAt = time and time() or 0
                tr.allocations = allocations
                tr.actualMarketValue = actualMarketValue>0 and actualMarketValue or nil
                tr.actualMarketEdge = tr.actualMarketValue and tr.sourceCost and (tr.actualMarketValue-tr.sourceCost) or nil
                tr.status = tr.sourceCost and tr.sourceCost > 0 and "COST TRANSFERRED" or "SOURCE COST UNKNOWN"
                sh.history[#sh.history+1] = tr
                while #sh.history > 250 do table.remove(sh.history, 1) end
                settled = settled + 1
                if not quiet then
                    local src = GoblinItemName(tr.sourceItem) or tr.sourceItem
                    if tr.sourceCost and tr.sourceCost > 0 then
                        print(string.format("|cff33ff99UBK Shredder:|r transferred %s basis from %s into the actual disenchant output.", FormatMoney(tr.sourceCost), tostring(src)))
                    else
                        print(string.format("|cffffcc00UBK Shredder:|r recorded %s's actual output, but source acquisition cost was not trusted; outputs remain unresolved.", tostring(src)))
                    end
                end
            else
                keep[#keep+1] = tr
            end
        else
            keep[#keep+1] = tr
        end
    end
    sh.pendingTransforms = keep
    return settled
end

function _G.UBKShredderInternal.IsDisenchantableGear(itemString)
    if type(itemString) ~= "string" then return false end
    local classId, quality
    if type(GetItemInfoInstant) == "function" then
        local _, _, _, _, _, c = GetItemInfoInstant(itemString)
        classId = tonumber(c)
    end
    if type(GetItemInfo) == "function" then
        local _, _, q, _, _, className, _, _, _, _, _, c = GetItemInfo(itemString)
        quality = tonumber(q)
        classId = classId or tonumber(c)
        if not classId and type(className)=="string" then
            local low = className:lower()
            if low:find("weapon",1,true) then classId=2 elseif low:find("armor",1,true) then classId=4 end
        end
    end
    -- Reject known non-gear before asking TSM to evaluate Destroy. This keeps the
    -- cached AuctionDB pass fast even when thousands of herbs, ore, gems, etc. exist.
    if classId and classId ~= 2 and classId ~= 4 then return false end
    if quality and (quality < 2 or quality > 4) then return false end
    local destroy = _G.UBKShredderInternal.ExpectedDestroyValue(itemString)
    if not destroy then return false end
    return true, destroy
end

function _G.UBKShredderInternal.ExpectedOutputs(itemString)
    -- Do not depend on TSM's private addon namespace. External addons cannot
    -- access the private TSM table used by its own Threading / Conversion modules.
    -- TSM's public Destroy source remains the authority for EV; this compact TBC
    -- model is only for showing likely output composition and output liquidity.
    local out = {}
    if type(itemString) ~= "string" then return out end
    local classId, quality, itemLevel = nil, nil, nil
    if type(GetItemInfoInstant) == "function" then
        local _, _, _, _, _, c = GetItemInfoInstant(itemString)
        classId = tonumber(c)
    end
    if type(GetItemInfo) == "function" then
        local _, _, q, ilvl, _, className, _, _, _, _, _, c = GetItemInfo(itemString)
        quality, itemLevel = tonumber(q), tonumber(ilvl)
        classId = classId or tonumber(c)
        if not classId and type(className)=="string" then
            local low=className:lower()
            if low:find("weapon",1,true) then classId=2 elseif low:find("armor",1,true) then classId=4 end
        end
    end
    if (classId ~= 2 and classId ~= 4) or not quality or not itemLevel then return out end
    local weapon = classId == 2
    local function Add(item, qty)
        qty=tonumber(qty) or 0
        if qty<=0 then return end
        local m=goblinRuntime.MarketContext(item)
        local cfg=EnsureShelfScoutState(GetRealmDB()).goblin.config
        out[#out+1]={itemString=item,name=GoblinItemName(item) or item,expectedQty=qty,market=CopyTable(m),liquidity=goblinRuntime.LiquidityLabel(m,cfg)}
    end
    -- TBC-era expected quantities. Tiny 0.5% cross-expansion crystal chances are
    -- intentionally omitted from the display model; TSM's Destroy EV still includes
    -- its own full conversion math.
    if quality == 2 then -- uncommon / green
        if itemLevel >= 100 then
            Add("i:22445", weapon and 0.77 or 2.55) -- Arcane Dust
            Add("i:22446", weapon and 1.10 or 0.33) -- Greater Planar Essence
            Add("i:22449", 0.03)                    -- Large Prismatic Shard
        elseif itemLevel >= 80 then
            Add("i:22445", weapon and 0.55 or 1.80)
            Add("i:22447", weapon and 1.85 or 0.55) -- Lesser Planar Essence
            Add("i:22448", 0.03)                    -- Small Prismatic Shard
        elseif itemLevel >= 66 then
            Add("i:22445", weapon and 0.44 or 1.50)
            Add("i:22447", weapon and 1.175 or 0.34)
            Add("i:22448", 0.03)
        end
    elseif quality == 3 then -- rare / blue
        if itemLevel >= 100 then Add("i:22449",1.0)
        elseif itemLevel >= 66 then Add("i:22448",1.0)
        elseif itemLevel >= 56 then Add("i:14344",1.0) end
    elseif quality == 4 then -- epic / purple
        if itemLevel >= 105 then Add("i:22450",1.666)
        elseif itemLevel >= 95 then Add("i:22450",1.50)
        elseif itemLevel >= 56 then Add("i:20725", itemLevel >= 61 and 1.666 or 1.0) end
    end
    table.sort(out,function(a,b) return (a.expectedQty or 0)>(b.expectedQty or 0) end)
    return out
end

function _G.UBKShredderInternal.OutputLiquidity(outputs)
    local rank = {UNKNOWN=0, THIN=1, HEALTHY=2, ACTIVE=3}
    local best, bestRank = "UNKNOWN", 0
    for _, row in ipairs(outputs or {}) do
        local r = rank[row.liquidity or "UNKNOWN"] or 0
        if r > bestRank then best, bestRank = row.liquidity, r end
    end
    return best
end

function _G.UBKShredderInternal.BuildCandidate(itemString, minBuyout)
    minBuyout = tonumber(minBuyout)
    if not minBuyout or minBuyout <= 0 then return nil end
    local ok, destroy = _G.UBKShredderInternal.IsDisenchantableGear(itemString)
    if not ok or not destroy then return nil end
    local db = GetRealmDB()
    local sh = _G.UBKShredderInternal.EnsureState(db)
    if minBuyout > (tonumber(sh.settings.maxBuyout) or math.huge) then return nil end
    local profit = destroy - minBuyout
    local roi = minBuyout > 0 and profit / minBuyout or nil
    if profit < (tonumber(sh.settings.minProfit) or 0) or not roi or roi < (tonumber(sh.settings.minROI) or 0) then return nil end
    local outputs = _G.UBKShredderInternal.ExpectedOutputs(itemString)
    local liquidity = _G.UBKShredderInternal.OutputLiquidity(outputs)
    local market = goblinRuntime.MarketContext(itemString)
    local resale = market and (market.dbmarket or market.recent or market.historical) or nil
    local cfg = EnsureShelfScoutState(db).goblin.config
    local directLiquidity = goblinRuntime.LiquidityLabel(market, cfg)
    local recommendation = "SHRED"
    if resale and resale > destroy * 1.35 and (directLiquidity == "ACTIVE" or directLiquidity == "HEALTHY") then recommendation = "FLIP LOOK" end
    local score = roi * 100 + math.min(100, math.max(0, profit / 10000))
    if liquidity == "ACTIVE" then score=score+15 elseif liquidity=="HEALTHY" then score=score+8 elseif liquidity=="THIN" then score=score-3 end
    return {
        itemString=itemString, itemName=GoblinItemName(itemString) or itemString,
        buyout=minBuyout, destroyValue=destroy, profit=profit, roi=roi,
        outputLiquidity=liquidity, outputs=outputs, market=CopyTable(market), resaleValue=resale,
        directLiquidity=directLiquidity, recommendation=recommendation, score=score,
    }
end

function _G.UBKShredderInternal.BuildScanUniverse()
    local seen, items = {}, {}
    local function Add(itemString)
        if type(itemString) ~= "string" or not itemString:match("^i:%d+") or seen[itemString] then return end
        seen[itemString]=true; items[#items+1]=itemString
    end
    -- TSMItemInfoDB is a public SavedVariables global. It gives us TSM's known item
    -- universe without reaching into TSM's private addon namespace.
    if type(TSMItemInfoDB)=="table" and type(TSMItemInfoDB.itemStrings)=="table" then
        for _,blob in ipairs(TSMItemInfoDB.itemStrings) do
            if type(blob)=="string" then
                for itemString in blob:gmatch("[^\2]+") do Add(itemString) end
            end
        end
    end
    -- Always include anything UBK already knows, even if TSM's item cache is sparse.
    local db=GetRealmDB()
    for itemString in pairs(type(db.items)=="table" and db.items or {}) do Add(itemString) end
    -- And include explicitly grouped TSM items when the public group API is available.
    if type(TSM_API)=="table" and type(TSM_API.GetGroupPaths)=="function" and type(TSM_API.GetGroupItems)=="function" then
        local paths={}
        if pcall(TSM_API.GetGroupPaths,paths) then
            for _,path in ipairs(paths) do
                local grouped={}
                if pcall(TSM_API.GetGroupItems,path,false,grouped) then for _,itemString in ipairs(grouped) do Add(itemString) end end
            end
        end
    end
    table.sort(items)
    return items
end

function _G.UBKShredderInternal.FinishPublicScan(ok, err)
    local rt=_G.UBKShredderInternal.runtime
    local rows=type(rt.scanRows)=="table" and rt.scanRows or {}
    table.sort(rows,function(a,b)
        if (a.score or 0)~=(b.score or 0) then return (a.score or 0)>(b.score or 0) end
        if (a.profit or 0)~=(b.profit or 0) then return (a.profit or 0)>(b.profit or 0) end
        return tostring(a.itemName)<tostring(b.itemName)
    end)
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db)
    local maxRows=math.max(10,tonumber(sh.settings.maxCandidates) or 150)
    while #rows>maxRows do table.remove(rows) end
    rt.scanning=false; rt.lastError=err; rt.lastScanAt=time and time() or 0
    rt.lastScanCount=tonumber(rt.scanExamined) or 0
    sh.cache.candidates=rows
    sh.cache.candidateByItem={}
    for _,row in ipairs(rows) do
        if type(row)=="table" and type(row.itemString)=="string" then sh.cache.candidateByItem[row.itemString]=row end
    end
    sh.cache.generatedAt=rt.lastScanAt
    sh.cache.examined=rt.lastScanCount
    if ok then
        sh.cache.status=string.format("Cached scan complete: %d TSM-known items checked, %d Shredder candidate%s retained. DBMinBuyout is preferred; DBRecent is fallback. Right-click a candidate to live-confirm.",rt.lastScanCount,#rows,#rows==1 and "" or "s")
    else
        sh.cache.status="Shredder scan failed: "..tostring(err or "unknown error")
    end
    rt.scanItems=nil; rt.scanRows=nil; rt.scanIndex=nil; rt.scanExamined=nil
    if _G.UBKInterface_ShredderUpdated then pcall(_G.UBKInterface_ShredderUpdated) end
end

function _G.UBKShredderInternal.ProcessPublicScanBatch(token)
    local rt=_G.UBKShredderInternal.runtime
    if not rt.scanning or token~=rt.scanGeneration then return end
    local items=rt.scanItems or {}
    local first=tonumber(rt.scanIndex) or 1
    -- TSM price sources can be expensive. Keep each frame's local work small so
    -- a large item cache does not make the Auction House appear frozen.
    local last=math.min(#items,first+29)
    for i=first,last do
        local itemString=items[i]
        rt.scanExamined=(tonumber(rt.scanExamined) or 0)+1
        local cached=GoblinPrice("dbminbuyout",itemString)
        local source="DBMinBuyout"
        if not cached then cached=GoblinPrice("dbrecent",itemString); source="DBRecent" end
        if cached and cached>0 then
            local row=_G.UBKShredderInternal.BuildCandidate(itemString,cached)
            if row then row.cachedPriceSource=source; rt.scanRows[#rt.scanRows+1]=row end
        end
    end
    rt.scanIndex=last+1
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db)
    if rt.scanIndex>#items then
        _G.UBKShredderInternal.FinishPublicScan(true,nil)
        return
    end
    sh.cache.status=string.format("Scanning TSM item cache locally: %d / %d checked…",last,#items)
    if C_Timer and C_Timer.After then
        C_Timer.After(0.01,function() _G.UBKShredderInternal.ProcessPublicScanBatch(token) end)
    else
        -- TBC Anniversary provides C_Timer; this fallback is only for unusual hosts/tests.
        _G.UBKShredderInternal.ProcessPublicScanBatch(token)
    end
end

function _G.UBKShredderInternal.StartScan()
    local rt=_G.UBKShredderInternal.runtime
    if rt.scanning then return false,"scan already running" end
    if type(TSM_API)~="table" or type(TSM_API.GetCustomPriceValue)~="function" then return false,"TSM public price API is unavailable" end
    local items=_G.UBKShredderInternal.BuildScanUniverse()
    if #items==0 then return false,"TSM item cache is empty; open TSM once and try again" end
    rt.scanGeneration=(tonumber(rt.scanGeneration) or 0)+1
    rt.scanning=true; rt.lastError=nil; rt.scanItems=items; rt.scanRows={}; rt.scanIndex=1; rt.scanExamined=0
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db)
    sh.cache.status=string.format("Scanning %d TSM-known items locally — no live AH queries…",#items)
    local token=rt.scanGeneration
    if C_Timer and C_Timer.After then C_Timer.After(0,function() _G.UBKShredderInternal.ProcessPublicScanBatch(token) end)
    else _G.UBKShredderInternal.ProcessPublicScanBatch(token) end
    return true
end


function _G.UBKShredderInternal.LiveFinalizeCurrent()
    local rt=_G.UBKShredderLiveRuntime
    local cur=rt and rt.current
    if not cur then return end
    local db=GetRealmDB()
    local sh=_G.UBKShredderInternal.EnsureState(db)
    local records={}
    for _,pageRecords in pairs(shelfRuntime.pages or {}) do
        for _,rec in ipairs(pageRecords or {}) do
            if rec.itemString==cur.itemString or (not rec.itemString and rec.name==cur.name) then
                records[#records+1]=rec
            end
        end
    end
    local destroy=_G.UBKShredderInternal.ExpectedDestroyValue(cur.itemString)
    local minProfit=tonumber(sh.settings.minProfit) or 0
    local minROI=tonumber(sh.settings.minROI) or 0
    local maxBuyout=tonumber(sh.settings.maxBuyout) or math.huge
    local threshold=nil
    if destroy and destroy>0 then
        local profitLimit=destroy-minProfit
        local roiLimit=destroy/(1+math.max(0,minROI))
        threshold=math.min(maxBuyout,profitLimit,roiLimit)
        if threshold<=0 then threshold=nil end
    end
    local shelfCandidate,levels=ShelfAnalyze(records,cur.itemString,cur.name)
    local low,units,posts,profitableUnits,profitablePosts,maxProfitablePrice,nextPrice=nil,0,0,0,0,nil,nil
    for _,rec in ipairs(records) do
        local price=tonumber(rec.unitPrice) or 0
        local qty=math.max(0,tonumber(rec.quantity) or 0)
        if price>0 and qty>0 then
            posts=posts+1; units=units+qty
            if not low or price<low then low=price end
            if threshold and price<=threshold then
                profitablePosts=profitablePosts+1; profitableUnits=profitableUnits+qty
                if not maxProfitablePrice or price>maxProfitablePrice then maxProfitablePrice=price end
            elseif threshold and price>threshold and (not nextPrice or price<nextPrice) then
                nextPrice=price
            end
        end
    end
    local totalPages=tonumber(cur.totalPages) or 1
    local pagesScanned=0 for _ in pairs(shelfRuntime.pages or {}) do pagesScanned=pagesScanned+1 end
    local complete=totalPages<=(tonumber(rt.maxPages) or 10)
    local now=time and time() or 0
    sh.cache.liveStock[cur.itemString]={
        itemString=cur.itemString,name=cur.name,updatedAt=now,
        scanToken=rt.token,scanStartedAt=rt.startedAt,
        low=low,units=units,posts=posts,totalRows=tonumber(cur.totalResults) or posts,
        lowUnits=levels and levels[1] and levels[1].qty or nil,
        lowPosts=levels and levels[1] and levels[1].posts or nil,
        nextLevelPrice=levels and levels[2] and levels[2].price or nil,
        nextLevelUnits=levels and levels[2] and levels[2].qty or nil,
        nextLevelPosts=levels and levels[2] and levels[2].posts or nil,
        levelCount=levels and #levels or 0,
        shelfStatus=shelfCandidate and shelfCandidate.shelfStatus or nil,
        shelfLow=shelfCandidate and shelfCandidate.shelfLow or nil,
        shelfHigh=shelfCandidate and shelfCandidate.shelfHigh or nil,
        tailQty=shelfCandidate and shelfCandidate.tailQty or nil,
        tailPosts=shelfCandidate and shelfCandidate.tailPosts or nil,
        tailCost=shelfCandidate and shelfCandidate.tailCost or nil,
        shelfQty=shelfCandidate and shelfCandidate.shelfQty or nil,
        shelfPosts=shelfCandidate and shelfCandidate.shelfPosts or nil,
        recovery=shelfCandidate and shelfCandidate.recovery or nil,
        cliff=shelfCandidate and shelfCandidate.cliff or nil,
        profitableUnits=profitableUnits,profitablePosts=profitablePosts,
        maxProfitablePrice=maxProfitablePrice,nextPrice=nextPrice,
        threshold=threshold,destroyValue=destroy,
        complete=complete,pagesScanned=pagesScanned,totalPages=totalPages,
    }
end

function _G.UBKShredderInternal.LiveStop(message)
    local rt=_G.UBKShredderLiveRuntime
    if not rt then return end
    rt.active=false
    rt.current=nil
    rt.lastStatus=message or "Live AH stock refresh stopped."
    if _G.UBKInterface_ShredderUpdated then pcall(_G.UBKInterface_ShredderUpdated) end
end

function _G.UBKShredderInternal.LiveSendCurrentPage()
    local rt=_G.UBKShredderLiveRuntime
    if not rt or not rt.active or not rt.current then return end
    if not GoblinAuctionVisible() then
        _G.UBKShredderInternal.LiveStop("Auction House / TSM Auction UI closed. Live stock refresh stopped safely.")
        return
    end
    if not GoblinCanQueryNow() then
        rt.queryRetries=(tonumber(rt.queryRetries) or 0)+1
        if rt.queryRetries>80 then
            _G.UBKShredderInternal.LiveStop("AH query throttle did not clear. Live stock refresh stopped safely.")
            return
        end
        C_Timer.After(0.20,_G.UBKShredderInternal.LiveSendCurrentPage)
        return
    end
    rt.queryRetries=0
    local cur=rt.current
    rt.lastStatus=string.format("Updating AH stock %d/%d: %s (page %d)",rt.queueIndex,#rt.queue,cur.name,(cur.page or 0)+1)
    if _G.UBKInterface_ShredderUpdated then pcall(_G.UBKInterface_ShredderUpdated) end
    local ok,err=pcall(QueryAuctionItems,cur.name,nil,nil,cur.page or 0,false,nil,false,true)
    if not ok then _G.UBKShredderInternal.LiveStop("AH stock query failed safely: "..tostring(err)) end
end

function _G.UBKShredderInternal.LiveStartNext()
    local rt=_G.UBKShredderLiveRuntime
    if not rt or not rt.active then return end
    rt.queueIndex=rt.queueIndex+1
    local entry=rt.queue[rt.queueIndex]
    if not entry then
        local count=#rt.queue
        _G.UBKShredderInternal.LiveStop(string.format("Live AH stock refreshed for %d item%s.",count,count==1 and "" or "s"))
        return
    end
    wipe(shelfRuntime.pages)
    shelfRuntime.current=nil
    rt.current={itemString=entry.itemString,name=entry.name,page=0,totalPages=1,totalResults=0}
    C_Timer.After(0.12,_G.UBKShredderInternal.LiveSendCurrentPage)
end

function _G.UBKShredderInternal.HandleLiveCapturedPage(page,num,total)
    local rt=_G.UBKShredderLiveRuntime
    if not rt or not rt.active or not rt.current then return end
    local cur=rt.current
    if tonumber(page)~=tonumber(cur.page) then return end
    local pageSize=50
    cur.totalResults=tonumber(total) or tonumber(num) or 0
    cur.totalPages=math.max(1,math.ceil(math.max(1,cur.totalResults)/pageSize))
    local hasMore=(tonumber(num) or 0)>=pageSize and ((page+1)*pageSize)<cur.totalResults
    if hasMore and page+1<math.min(cur.totalPages,tonumber(rt.maxPages) or 10) then
        cur.page=page+1
        C_Timer.After(0.18,_G.UBKShredderInternal.LiveSendCurrentPage)
        return
    end
    _G.UBKShredderInternal.LiveFinalizeCurrent()
    if _G.UBKInterface_ShredderUpdated then pcall(_G.UBKInterface_ShredderUpdated) end
    C_Timer.After(0.18,_G.UBKShredderInternal.LiveStartNext)
end

function _G.UBKShredderInternal.StartLiveStockRefresh(itemStrings)
    local rt=_G.UBKShredderLiveRuntime
    if rt.active then return false,"live AH stock refresh is already running" end
    if goblinRuntime.scanActive then return false,"A UBK scan is currently using the Auction House query lane; let it finish first" end
    if not GoblinAuctionVisible() then return false,"open the Auction House with the TSM Auction UI first" end
    local now=GetTime and GetTime() or 0
    if goblinRuntime.lastTSMQueryAt and now-goblinRuntime.lastTSMQueryAt<0.8 then
        return false,"TSM is still actively querying; let that search settle for a moment and try again"
    end
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db)
    local source=type(itemStrings)=="table" and itemStrings or {}
    if #source==0 then
        for _,row in ipairs(sh.cache.candidates or {}) do source[#source+1]=row.itemString end
    end
    local seen,queue={},{}
    for _,value in ipairs(source) do
        local itemString=type(value)=="table" and value.itemString or value
        itemString=_G.UBKShredderInternal.BaseItemString(itemString)
        if itemString and not seen[itemString] then
            local name=GoblinItemName(itemString)
            if name and name~="" then
                seen[itemString]=true
                queue[#queue+1]={itemString=itemString,name=name}
            end
        end
    end
    if #queue==0 then return false,"no items were available to refresh" end
    rt.token=(tonumber(rt.token) or 0)+1
    rt.startedAt=now
    rt.queue=queue; rt.queueIndex=0; rt.current=nil
    rt.queryRetries=0; rt.active=true
    rt.lastStatus=string.format("Queued %d item%s for live AH stock refresh.",#queue,#queue==1 and "" or "s")
    _G.UBKShredderInternal.LiveStartNext()
    return true
end

function _G.UBKShredderInternal.GetLocationDetails(itemString)
    local details = {}
    if type(TradeSkillMasterDB) ~= "table" then return details end
    local pattern = TSMCharacterQuantityPattern()
    for key, value in pairs(TradeSkillMasterDB) do
        if type(key)=="string" and type(value)=="table" then
            local character, kind = key:match(pattern)
            if character and kind and QUANTITY_TABLES[kind] then
                local qty = tonumber(value[itemString]) or 0
                if qty > 0 then
                    details[character] = details[character] or {}
                    details[character][kind] = qty
                end
            end
        end
    end
    local pending=UBK_GetCurrentPendingMailTable()
    if pending then
        for character,items in pairs(pending) do
            local qty=type(items)=="table" and (tonumber(items[itemString]) or 0) or 0
            if qty>0 then details[character]=details[character] or {}; details[character].pendingMailQuantity=qty end
        end
    end
    return details
end

function _G.UBKShredderInternal.PendingMailTo(character, itemString)
    if type(TradeSkillMasterDB) ~= "table" then return 0 end
    RefreshRuntimeKeys()
    local key = "f@"..FACTION_NAME.." - "..REALM_NAME.."@internalData@pendingMail"
    local pending = TradeSkillMasterDB[key]
    local byChar = type(pending)=="table" and pending[character] or nil
    return type(byChar)=="table" and (tonumber(byChar[itemString]) or 0) or 0
end

local function ShredderEligibleAcquisitionEvidence(state)
    -- Owned Pipeline eligibility is based on CURRENT qualifying provenance, not
    -- merely on historical purchase totals. Qualifying origins are AH/Auction
    -- buyer mail, player trade receipts recorded by TSM, and UBK-captured loot.
    if type(state) ~= "table" then return 0, nil end
    local evidenceQty = GetShredEligibleQty(state)
    if evidenceQty <= 0 then return 0, nil end

    local labels = {}
    local sources = type(state.buySources) == "table" and state.buySources or {}
    if (tonumber(sources["Auction"]) or 0) > 0 or (tonumber(sources["Auction Mail"]) or 0) > 0 then labels[#labels + 1] = "AH" end
    if (tonumber(sources["Trade"]) or 0) > 0 then labels[#labels + 1] = "TRADE" end
    local lootEvidence=(tonumber(state.lootImputedQty) or 0)+(tonumber(state.lootReviewedQty) or 0)
    if lootEvidence <= 0 then
        for _,lot in ipairs(type(state.unresolvedLots)=="table" and state.unresolvedLots or {}) do
            if tostring(lot.source or "") == "loot" and (tonumber(lot.qty) or 0)>0 then lootEvidence=lootEvidence+(tonumber(lot.qty) or 0) end
        end
    end
    if lootEvidence > 0 or state.firstSeenLootReview == true then labels[#labels + 1] = "LOOT" end
    return evidenceQty, (#labels>0 and table.concat(labels, " + ") or "QUALIFIED")
end

function _G.UBKShredderInternal.GetPipeline()
    local db = GetRealmDB()
    local sh = _G.UBKShredderInternal.EnsureState(db)
    local rows = {}
    local ench = sh.enchanter
    for itemString, state in pairs(db.items or {}) do
        local observed = GetRealmQuantityForItem(itemString)
        local evidenceQty, acquisitionSource = ShredderEligibleAcquisitionEvidence(state)
        if observed and observed > 0 and evidenceQty > 0 then
            local ok, destroy = _G.UBKShredderInternal.IsDisenchantableGear(itemString)
            if ok and destroy then
                -- Never let legacy/pre-UBK copies inflate Owned Pipeline counts. The
                -- displayed quantity is capped at the amount supported by qualifying
                -- acquisition evidence and by what TSM says is still owned now.
                local pipelineQty = math.min(math.max(0, tonumber(observed) or 0), evidenceQty)
                local basis = GetUnitBasis(state)
                local trusted = CostTrustedForRadar(state, itemString)
                local d = _G.UBKShredderInternal.GetLocationDetails(itemString)
                local e = d and d[ench] or nil
                local pendingTo = _G.UBKShredderInternal.PendingMailTo(ench, itemString)
                local ready = e and (tonumber(e.bagQuantity) or 0) or 0
                local stored = e and (tonumber(e.bankQuantity) or 0) or 0
                local mailed = math.max(pendingTo, e and (tonumber(e.pendingMailQuantity) or 0) or 0, e and (tonumber(e.mailQuantity) or 0) or 0)
                local listed = 0
                local other = 0
                local locations = {}
                for char, kinds in pairs(d or {}) do
                    local bag=(tonumber(kinds.bagQuantity) or 0); local bank=(tonumber(kinds.bankQuantity) or 0); local mail=(tonumber(kinds.mailQuantity) or 0); local auc=(tonumber(kinds.auctionQuantity) or 0)
                    listed = listed + auc
                    if char ~= ench then other = other + bag + bank end
                    if bag+bank+mail+auc>0 then locations[#locations+1]=string.format("%s:%d",char,bag+bank+mail+auc) end
                end
                local status
                if not ench then status="CHOOSE ENCHANTER"
                elseif ready > 0 then status="READY"
                elseif mailed > 0 then status="IN TRANSIT"
                elseif other > 0 then status="NEEDS MAIL"
                elseif stored > 0 then status="STORED"
                elseif listed > 0 then status="LISTED"
                else status="OWNED" end
                rows[#rows+1] = {
                    itemString=itemString, itemName=GoblinItemName(itemString) or itemString,
                    qty=pipelineQty, observedQty=observed, acquisitionEvidenceQty=evidenceQty, acquisitionSource=acquisitionSource,
                    basis=basis>0 and basis or nil, trusted=trusted and true or false,
                    destroyValue=destroy, expectedProfit=(trusted and basis and basis>0) and (destroy-basis) or nil,
                    roi=(trusted and basis and basis>0) and ((destroy-basis)/basis) or nil,
                    status=status, needsEnchanter=not ench, readyQty=ready, pendingMailQty=mailed, otherQty=other, storedQty=stored, listedQty=listed,
                    locations=locations, outputs=_G.UBKShredderInternal.ExpectedOutputs(itemString),
                }
            end
        end
    end
    local order={READY=1,["NEEDS MAIL"]=2,["IN TRANSIT"]=3,STORED=4,OWNED=5,LISTED=6}
    table.sort(rows,function(a,b)
        local ao,bo=order[a.status] or 99,order[b.status] or 99
        if ao~=bo then return ao<bo end
        if (a.expectedProfit or -math.huge)~=(b.expectedProfit or -math.huge) then return (a.expectedProfit or -math.huge)>(b.expectedProfit or -math.huge) end
        return tostring(a.itemName)<tostring(b.itemName)
    end)
    return rows
end

-- ============================================================================
-- UBK 1.4 public API - stable boundary for companion intelligence addons
-- ============================================================================
-- The API deliberately exposes accounting facts and read-only market context while
-- keeping SavedVariables internals private. Companion addons should use this table
-- rather than reaching into UniversalBasisKeeperDB directly.
_G.UniversalBasisKeeperAPI = _G.UniversalBasisKeeperAPI or {}
_G.UniversalBasisKeeperAPI.version = "1.6"
_G.UBKAPI = _G.UniversalBasisKeeperAPI
_G.UniversalBasisKeeperAPI.realmKey = REALM_KEY
_G.UniversalBasisKeeperAPI.realmName = REALM_NAME
_G.UniversalBasisKeeperAPI.factionName = FACTION_NAME
_G.UniversalBasisKeeperAPI._allowedSettings = {
    deepCostPct=true, lowCostPct=true, highEndCachedPct=true, highEndLivePct=true,
    commonCachedPct=true, commonLivePct=true, rareCachedPct=true, rareLivePct=true,
    rareLoosePct=true, saleRateStrong=true, saleRateHealthy=true, soldPerDayStrong=true,
    soldPerDayHealthy=true, regionDiscountLook=true, maxSingleCategory=true, maxAllCategory=true,
}

function _G.UniversalBasisKeeperAPI:IsSupportedRealm()
    return IsSupportedRealm()
end


function _G.UniversalBasisKeeperAPI:GetSetupStatus()
    RefreshRuntimeKeys()
    local db=GetRealmDB(); return CopyTable(db.setup or {})
end

function _G.UniversalBasisKeeperAPI:GetRuntimeContext()
    RefreshRuntimeKeys()
    local realmTime, regionTime = self:GetMarketDataTimes()
    local result = {
        realm=REALM_NAME,
        faction=FACTION_NAME,
        realmKey=REALM_KEY,
        supported=IsSupportedRealm(),
        tsmLoaded=type(TradeSkillMasterDB)=="table" and type(TSM_API)=="table",
        realmDataTime=realmTime,
        regionDataTime=regionTime,
    }
    return result
end

function _G.UniversalBasisKeeperAPI:ResolveItem(text)
    text = tostring(text or "")
    local directID = text:match("|Hitem:(%d+)") or text:match("^%s*i:(%d+)%s*$") or text:match("^%s*(%d+)%s*$")
    if directID then return "i:" .. tostring(tonumber(directID)) end
    local tracked = ResolveItem(text)
    if tracked then return tracked end
    local needle = NormalizeName(text)
    if needle == "" then return nil end
    local universe = GoblinCollectUniverse()
    for itemString in pairs(universe) do
        local name = GoblinItemName(itemString)
        if name and NormalizeName(name) == needle then return itemString end
    end
    return nil
end

function _G.UniversalBasisKeeperAPI:GetItemName(itemArg)
    local itemString = self:ResolveItem(itemArg) or itemArg
    return GoblinItemName(itemString) or UBK_MaterialName(itemString) or tostring(itemString or "")
end

-- BEGIN UBK BASIS-ONLY TSM PRICE API
-- These getters deliberately avoid GetBasisInfo / GetRealmDB: TSM calls price
-- sources frequently, and neither market lookups nor database hydration belongs
-- in that read path. Native TSM UBKBasis / UBKCrafting sources cache only for the
-- current frame; the next frame observes ledger and recipe changes immediately.
function _G.UniversalBasisKeeperAPI:GetAcquisitionCost(itemArg)
    local itemID = type(itemArg) == "number" and itemArg
        or (type(itemArg) == "string" and (itemArg:match("^i:(%d+)") or itemArg:match("^%d+$") or itemArg:match("|Hitem:(%d+)")))
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then return nil end
    local itemString = "i:" .. tostring(itemID)
    local root = _G.UniversalBasisKeeperDB
    local db = type(root) == "table" and type(root.realms) == "table" and root.realms[REALM_KEY] or nil
    if type(db) ~= "table" or type(db.items) ~= "table" then return nil end
    if type(db.setup) == "table" and db.setup.status ~= "complete" then return nil end
    local state = db.items[itemString]
    if type(state) ~= "table" or not CostTrustedForRadar(state, itemString) then return nil end
    -- Unknown units are excluded from UBK's known-cost pool, never assigned zero.
    -- At zero stock an already established, trusted last basis remains useful.
    local qty = tonumber(state.qty) or 0
    local basis = qty > 0 and ((tonumber(state.value) or 0) / qty) or tonumber(state.lastBasis)
    if not basis or basis <= 0 or basis ~= basis or basis == math.huge then return nil end
    return math.max(1, math.floor(basis + 0.5))
end

-- A recipe can be costed after an ingredient has been used up. Keep inventory
-- basis strict, while material planning can use recorded purchases and the
-- known merchant price. Neither fallback queries an auction-market estimate.
function _G.UniversalBasisKeeperAPI:GetMaterialCost(itemArg)
    local basis = self:GetAcquisitionCost(itemArg)
    if basis then return basis end
    local itemID = type(itemArg) == "number" and itemArg
        or (type(itemArg) == "string" and (itemArg:match("^i:(%d+)") or itemArg:match("^%d+$") or itemArg:match("|Hitem:(%d+)")))
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then return nil end
    local itemString = "i:" .. tostring(itemID)
    local api = _G.TSM_API
    if type(api) ~= "table" or type(api.GetCustomPriceValue) ~= "function" then return nil end
    for _, source in ipairs({"avgbuy", "vendorbuy"}) do
        local ok, value = pcall(api.GetCustomPriceValue, source, itemString)
        if ok and type(value) == "number" and value > 0 and value < math.huge then
            return math.max(1, math.floor(value + 0.5))
        end
    end
    return nil
end

function _G.UniversalBasisKeeperAPI:GetRecipeBasisCost(itemArg)
    local itemID = type(itemArg) == "number" and itemArg
        or (type(itemArg) == "string" and (itemArg:match("^i:(%d+)") or itemArg:match("^%d+$") or itemArg:match("|Hitem:(%d+)")))
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then return nil end
    local itemString = "i:" .. tostring(itemID)
    local craftsKey = "f@" .. FACTION_NAME .. " - " .. REALM_NAME .. "@internalData@crafts"
    local crafts = type(_G.TradeSkillMasterDB) == "table" and _G.TradeSkillMasterDB[craftsKey] or nil
    if type(crafts) ~= "table" then return nil end
    local lowest = nil
    for _, recipe in pairs(crafts) do
        if type(recipe) == "table" and recipe.itemString == itemString and type(recipe.mats) == "table" then
            local resultQty = tonumber(recipe.numResult)
            if resultQty and resultQty > 0 and resultQty < math.huge then
                local total, hasMats, valid = 0, false, true
                for reagent, quantity in pairs(recipe.mats) do
                    quantity = tonumber(quantity)
                    local basis = self:GetMaterialCost(reagent)
                    if not quantity or quantity <= 0 or quantity ~= quantity or quantity == math.huge or not basis then
                        valid = false
                        break
                    end
                    hasMats = true
                    total = total + basis * quantity
                end
                if valid and hasMats and total > 0 and total < math.huge then
                    local perItem = math.max(1, math.floor(total / resultQty + 0.5))
                    if not lowest or perItem < lowest then lowest = perItem end
                end
            end
        end
    end
    return lowest
end
-- END UBK BASIS-ONLY TSM PRICE API

function _G.UniversalBasisKeeperAPI:GetBasisInfo(itemArg)
    local itemString = self:ResolveItem(itemArg) or itemArg
    if type(itemString) ~= "string" then return nil end
    local db = GetRealmDB()
    local state = db and db.items and db.items[itemString] or nil
    local observed = GetRealmQuantityForItem(itemString)
    local pendingQty = MailPendingTotals(db, itemString)
    local reviewOpen = false
    local _, review = EnsureCostReviewState(db)
    if review and type(review.items[itemString]) == "table" then reviewOpen = review.items[itemString].open == true end
    local basis = state and GetUnitBasis(state) or 0
    local known = state and (tonumber(state.qty) or 0) or 0
    local unresolved = state and (tonumber(state.bootstrapUnresolved) or 0) or 0
    local trusted = state and CostTrustedForRadar(state, itemString) or false
    local tsmValue = GetTSMCustomValue(itemString)
    local worldRef, worldRefKind = nil, nil
    if state then worldRef, worldRefKind = _G.UBKWorldDropInternal.Reference(state, itemString) end
    local lootCapture = state and state.lastLootCapture or nil
    if not lootCapture and state and type(state.unresolvedLots) == "table" then
        local newest = nil
        for _, lot in ipairs(state.unresolvedLots) do
            if type(lot) == "table" and tostring(lot.source or "") == "loot" then
                local at = tonumber(lot.detectedAt) or 0
                if not newest or at > (tonumber(newest.capturedAt) or 0) then
                    newest = { capturedAt = at, qty = tonumber(lot.qty) or 0, source = "loot" }
                end
            end
        end
        lootCapture = newest
    end
    local result = {
        prospectingPending = _G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(itemString) or false,
        prospectingStatus = _G.UBKProspectingSessions and _G.UBKProspectingSessions:Reason(itemString) or nil,
        itemString = itemString,
        name = GoblinItemName(itemString) or UBK_MaterialName(itemString) or itemString,
        basis = basis > 0 and basis or nil,
        knownQty = known,
        unresolvedQty = unresolved,
        observedQty = tonumber(observed) or 0,
        pendingMailQty = tonumber(pendingQty) or 0,
        provenance = CostProvenanceLabel(state, itemString),
        provenanceDisplay = CostProvenanceDisplay(state, itemString),
        trustedForRadar = trusted and true or false,
        reviewOpen = reviewOpen,
        tsmCustomValue = tsmValue,
        coverage = (tonumber(observed) or 0) > 0 and math.min(1, known / math.max(1, tonumber(observed) or 0)) or nil,
        userClassification = state and state.userCostClassification or nil,
        lastLootCapture = lootCapture,
        worldSourceConfirmed = state and state.worldSourceConfirmed == true or false,
        worldSourceConfirmedAt = state and tonumber(state.worldSourceConfirmedAt) or nil,
        worldDropReference = worldRef,
        worldDropReferenceKind = worldRefKind,
        worldDropUnitBasis = IsUniversalExcluded(itemString) and worldRef or (worldRef and worldRef > 0 and (worldRef * 0.95) or nil),
    }
    if IsUniversalExcluded(itemString) then
        result.basis=nil; result.knownQty=0; result.unresolvedQty=0; result.reviewOpen=false; result.coverage=nil
        result.provenance="vendor-trash"; result.provenanceDisplay="VENDOR TRASH"; result.vendorTrash=true
        local _,vendor=_G.UBKItemRules.VendorTrash(itemString); result.vendorSell=vendor
    end
    local provider=_G.UniversalBasisKeeperEvidenceProvider
    if type(provider)=="table" and type(provider.IsActive)=="function" and type(provider.GetBasisInfo)=="function" then
        local activeOK,active=pcall(provider.IsActive,provider)
        if activeOK and active then
            local ok,extra=pcall(provider.GetBasisInfo,provider,itemString,CopyTable(result))
            -- Provider output is deliberately namespaced and transient. Core
            -- callers must never mistake it for UBK-owned accounting fields or
            -- copy it into UniversalBasisKeeperDB.
            if ok and type(extra)=="table" then result.transientProvider=CopyTable(extra) end
        end
    end
    return result
end

function _G.UniversalBasisKeeperAPI:GetReviewItems()
    local db = GetRealmDB()
    local _, review = EnsureCostReviewState(db)
    local result = {}
    for itemString, row in pairs(review.items or {}) do
        if type(row) == "table" and row.open and not IsUniversalExcluded(itemString) then
            local basis = self:GetBasisInfo(itemString)
            result[#result + 1] = {
                itemString = itemString,
                name = basis and basis.name or GoblinItemName(itemString) or itemString,
                reason = row.reason or "Cost provenance needs review",
                customValue = row.customValue,
                unresolvedQty = row.unresolvedQty or (basis and basis.unresolvedQty) or 0,
                observedQty = row.observedQty or (basis and basis.observedQty) or 0,
                provenance = basis and basis.provenance or nil,
            }
        end
    end
    table.sort(result, function(a,b) return tostring(a.name) < tostring(b.name) end)
    return result
end

function _G.UniversalBasisKeeperAPI:Classify(itemArg, mode)
    local itemString = self:ResolveItem(itemArg) or itemArg
    if _G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(itemString) then return false,_G.UBKProspectingSessions:Reason(itemString) end
    mode = NormalizeName(mode)
    if mode == "loot" or mode == "farmed" or mode == "found" then mode = "world" end
    if type(itemString) ~= "string" or (mode ~= "manual" and mode ~= "economic" and mode ~= "world") then return false, "invalid item or classification" end
    ClassifyCost(itemString .. " " .. mode)
    local info = self:GetBasisInfo(itemString)
    if mode == "manual" then
        return info and (info.userClassification == "manual-acquisition" or info.userClassification == "manual-loot-basis"), info
    elseif mode == "world" then
        return info and (info.userClassification == "manual-loot-basis" or info.userClassification == "vendor-trash"), info
    else
        return info and info.userClassification == "manual-economic", info
    end
end

function _G.UniversalBasisKeeperAPI:PreviewResolveUnresolved(itemArg, priceText)
    local itemString = self:ResolveItem(itemArg) or itemArg
    if type(itemString) ~= "string" then return false, "UBK could not resolve that item." end
    local copper = ParseMoney(priceText)
    if not copper or copper <= 0 then
        return false, "Enter a positive per-unit cost, for example 15g70s or 85s5c."
    end
    local db = GetRealmDB()
    local state = db and db.items and db.items[itemString] or nil
    if type(state) ~= "table" then
        return false, "That item is not currently tracked by UBK."
    end
    local unresolved = tonumber(state.bootstrapUnresolved) or tonumber(state.unexplainedGain) or 0
    if unresolved <= 0 then
        return false, "That item no longer has unresolved inventory."
    end
    local known = tonumber(state.qty) or 0
    local currentBasis = GetUnitBasis(state)
    local currentValue = tonumber(state.value) or (known * currentBasis)
    local projectedQty = known + unresolved
    local projectedValue = currentValue + unresolved * copper
    local projectedBasis = projectedQty > 0 and (projectedValue / projectedQty) or copper
    local observed = GetRealmQuantityForItem(itemString)
    return true, {
        itemString = itemString,
        name = GoblinItemName(itemString) or UBK_MaterialName(itemString) or itemString,
        knownQty = known,
        unresolvedQty = unresolved,
        observedQty = tonumber(observed) or (known + unresolved),
        currentBasis = currentBasis > 0 and currentBasis or nil,
        enteredUnitPrice = copper,
        projectedBasis = projectedBasis,
        projectedQty = projectedQty,
        projectedValue = projectedValue,
    }
end

function _G.UniversalBasisKeeperAPI:ResolveUnresolved(itemArg, priceText)
    local itemString = self:ResolveItem(itemArg) or itemArg
    if type(itemString) ~= "string" then return false, "UBK could not resolve that item." end
    local before = self:GetBasisInfo(itemString)
    if not before or (tonumber(before.unresolvedQty) or 0) <= 0 then
        return false, "That item no longer has unresolved inventory."
    end
    local ok, err = ResolveUnresolved(itemString, priceText)
    if not ok then return false, err or "UBK could not resolve those units." end
    return true, self:GetBasisInfo(itemString)
end

function _G.UniversalBasisKeeperAPI:GetCoverage()
    local db = GetRealmDB()
    -- UBK_UniversalBuckets returns (universalSummary, buckets). The old API
    -- accidentally returned the summary table as though it were the buckets,
    -- which made UBK Coverage try to take #nil. Always take the second return.
    local _, buckets = UBK_UniversalBuckets(db)
    buckets = type(buckets) == "table" and buckets or {}
    return {
        ready = CopyTable(type(buckets.ready)=="table" and buckets.ready or {}),
        partial = CopyTable(type(buckets.partial)=="table" and buckets.partial or {}),
        unknown = CopyTable(type(buckets.unknown)=="table" and buckets.unknown or {}),
        review = CopyTable(type(buckets.review)=="table" and buckets.review or {}),
        protected = CopyTable(type(buckets.protected)=="table" and buckets.protected or {}),
        zeroStock = CopyTable(type(buckets.zeroStock)=="table" and buckets.zeroStock or {}),
    }
end

-- One bounded ownership census for Position Intelligence. It includes owned
-- items without a positive UBK basis so UBK may use DBMarket as an explicit
-- acquisition-basis proxy; genuine UBK basis remains the only authority for
-- the Obvious Win shortcut.
function _G.UniversalBasisKeeperAPI:GetPositionInputs()
    local db=GetRealmDB()
    local quantities=GetRealmTrackedQuantities(false)
    quantities=type(quantities)=="table" and quantities or {}
    local _,review=EnsureCostReviewState(db)
    local reviewItems=review and type(review.items)=="table" and review.items or {}
    local rows,seen={},{}
    local function Add(itemString)
        if seen[itemString] or IsUniversalExcluded(itemString) then return end
        seen[itemString]=true
        local observed=math.max(0,tonumber(quantities[itemString]) or 0)
        if observed<=0 then return end
        local state=db and db.items and db.items[itemString] or nil
        local basis=state and GetUnitBasis(state) or 0
        local reviewRow=reviewItems[itemString]
        rows[#rows+1]={
            itemString=itemString,
            name=GoblinItemName(itemString) or UBK_MaterialName(itemString) or itemString,
            observedQty=observed,
            knownQty=math.max(0,state and tonumber(state.qty) or 0),
            unresolvedQty=math.max(0,state and tonumber(state.bootstrapUnresolved) or 0),
            basis=basis>0 and basis or nil,
            trustedForRadar=state and CostTrustedForRadar(state,itemString) and true or false,
            reviewOpen=type(reviewRow)=="table" and reviewRow.open==true or false,
            sourceLabel=state and CostProvenanceDisplay(state,itemString) or nil,
        }
    end
    for _,itemString in ipairs(BASIS_ORDER) do Add(itemString) end
    for itemString in pairs(quantities) do Add(itemString) end
    table.sort(rows,function(a,b) return tostring(a.name)<tostring(b.name) end)
    return rows
end

-- One completed-data census for Chum Scanner. Unlike Position Intelligence,
-- this includes trusted historical-basis items even when current ownership is
-- zero, so a witnessed acquisition value can remain useful after a position
-- has been sold. It reads TSM's already-loaded AuctionDB/AppHelper values and
-- never sends an Auction House query.
function _G.UniversalBasisKeeperAPI:GetChumScannerInputs()
    local db=GetRealmDB()
    local quantities=GetRealmTrackedQuantities(false)
    quantities=type(quantities)=="table" and quantities or {}
    local cfg=EnsureShelfScoutState(db).goblin.config
    local rows={}
    for _,itemString in ipairs(BASIS_ORDER) do
        local state=db and db.items and db.items[itemString] or nil
        if state and not IsUniversalExcluded(itemString) then
            local basis=GetUnitBasis(state)
            if basis and basis>0 then
                local market=goblinRuntime.MarketContext(itemString)
                market=CopyTable(market)
                market.liquidity=goblinRuntime.LiquidityLabel(market,cfg)
                rows[#rows+1]={
                    itemString=itemString,
                    name=GoblinItemName(itemString) or UBK_MaterialName(itemString) or itemString,
                    basis=basis,
                    observedQty=math.max(0,tonumber(quantities[itemString]) or 0),
                    knownQty=math.max(0,tonumber(state.qty) or 0),
                    unresolvedQty=math.max(0,tonumber(state.bootstrapUnresolved) or tonumber(state.unexplainedGain) or 0),
                    trustedForRadar=CostTrustedForRadar(state,itemString) and true or false,
                    sourceLabel=CostProvenanceDisplay(state,itemString),
                    market=market,
                }
            end
        end
    end
    table.sort(rows,function(a,b) return tostring(a.name)<tostring(b.name) end)
    return rows
end

function _G.UniversalBasisKeeperAPI:GetMarketContext(itemArg)
    local itemString = self:ResolveItem(itemArg) or itemArg
    if type(itemString) ~= "string" then return nil end
    local m = goblinRuntime.MarketContext(itemString)
    local cfg = EnsureShelfScoutState(GetRealmDB()).goblin.config
    local liquidity = goblinRuntime.LiquidityLabel(m, cfg)
    m = CopyTable(m)
    m.liquidity = liquidity
    return m
end

function _G.UniversalBasisKeeperAPI:GetMarketDataTimes()
    local realmTime, regionTime = nil, nil
    if type(TSM) == "table" and type(TSM.AuctionDB) == "table" and type(TSM.AuctionDB.GetAppDataUpdateTimes) == "function" then
        local ok, a, b = pcall(TSM.AuctionDB.GetAppDataUpdateTimes)
        if ok then realmTime, regionTime = tonumber(a), tonumber(b) end
    end
    return realmTime, regionTime
end

function _G.UniversalBasisKeeperAPI:GetRadarSettings()
    local ss = EnsureShelfScoutState(GetRealmDB())
    local out = CopyTable(ss.goblin.config)
    out.deepCostPct = ss.config.deepCostPct
    out.lowCostPct = ss.config.lowCostPct
    return out
end

function _G.UniversalBasisKeeperAPI:SetRadarSetting(key, value)
    if not self._allowedSettings[key] then return false, "unsupported setting" end
    value = tonumber(value)
    if not value then return false, "value must be numeric" end
    local ss = EnsureShelfScoutState(GetRealmDB())
    if key == "deepCostPct" or key == "lowCostPct" then ss.config[key] = value else ss.goblin.config[key] = value end
    return true
end

function _G.UniversalBasisKeeperAPI:GetCachedIntelligence(itemArg)
    local itemString = self:ResolveItem(itemArg) or itemArg
    if type(itemString) ~= "string" then return nil end
    local basis = self:GetBasisInfo(itemString)
    local market = self:GetMarketContext(itemString)
    local cfg = self:GetRadarSettings()
    local price = market and market.cachedLow or nil
    local signals = {}
    local ratio = basis and basis.trustedForRadar and basis.basis and price and basis.basis > 0 and (price / basis.basis) or nil
    if ratio and ratio <= (cfg.deepCostPct or 0.65) then signals[#signals+1] = "DEEP"
    elseif ratio and ratio <= (cfg.lowCostPct or 0.75) then signals[#signals+1] = "LOW" end
    if market then
        if market.liquidity == "ACTIVE" then signals[#signals+1] = "FAST"
        elseif market.liquidity == "THIN" then signals[#signals+1] = "THIN" end
        if market.regionRatio and market.regionRatio <= (cfg.regionDiscountLook or 0.80) then signals[#signals+1] = "REGION CHEAP" end
    end
    return {itemString=itemString, name=self:GetItemName(itemString), basis=basis, market=market, cachedPrice=price, costRatio=ratio, signals=signals}
end

function _G.UniversalBasisKeeperAPI:StartRadar(category)
    if shelfRuntime.badge then shelfRuntime.badge:Hide() end
    if shelfRuntime.panel then shelfRuntime.panel:Hide() end
    if goblinRuntime.panel then goblinRuntime.panel:Hide() end
    category = NormalizeName(category)
    if category == "mats" or category == "material" then category = "high" end
    if category == "flip" or category == "flips" then category = "common" end
    if category == "uncommon" then category = "rare" end
    if category == "hardcore" then category = "all" end
    if category ~= "high" and category ~= "common" and category ~= "rare" and category ~= "all" then return false, "invalid category" end
    GoblinStartScan(category)
    return goblinRuntime.scanActive or #goblinRuntime.queue == 0
end

function _G.UniversalBasisKeeperAPI:StopRadar()
    GoblinStopScan("Radar stopped from Universal Basis Keeper. Shelf analysis remains active in Universal Basis Keeper.")
    return true
end

function _G.UniversalBasisKeeperAPI:GetRadarState()
    local cur = goblinRuntime.current
    return {
        active = goblinRuntime.scanActive and true or false,
        status = goblinRuntime.lastStatus,
        category = goblinRuntime.category,
        queue = #goblinRuntime.queue,
        queueIndex = goblinRuntime.queueIndex or 0,
        currentItem = cur and cur.itemString or nil,
        currentName = cur and cur.name or nil,
        currentPage = cur and ((cur.page or 0) + 1) or nil,
        maxPages = cur and (cur.totalPages or 1) or 1,
        confirmed = #goblinRuntime.results,
        activity = CopyTable(goblinRuntime.activity),
        results = CopyTable(goblinRuntime.results),
    }
end

function _G.UniversalBasisKeeperAPI:OpenInTSM(result)
    return GoblinOpenInTSM(result)
end

function _G.UniversalBasisKeeperAPI:IsAuctionVisible()
    return GoblinAuctionVisible() and true or false
end

function _G.UniversalBasisKeeperAPI:FormatMoney(copper)
    return ShelfShortMoney(copper)
end

function _G.UniversalBasisKeeperAPI:GetShredderState()
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db); local rt=_G.UBKShredderInternal.runtime
    local liveCount=0 for _ in pairs(sh.cache.liveStock or {}) do liveCount=liveCount+1 end
    local liveRT=_G.UBKShredderLiveRuntime or {}
    return {
        enchanter=sh.enchanter, settings=CopyTable(sh.settings), scanning=rt.scanning and true or false,
        cache=CopyTable(sh.cache), pendingTransforms=#(sh.pendingTransforms or {}), historyCount=#(sh.history or {}),
        baselineDone=sh.destroyBaselineDone and true or false, baselineRecords=sh.destroyBaselineRecords or 0,
        liveScanning=liveRT.active and true or false, liveStatus=liveRT.lastStatus,
        liveToken=liveRT.token,liveStartedAt=liveRT.startedAt,
        liveCachedItems=liveCount,
    }
end

function _G.UniversalBasisKeeperAPI:SetShredderEnchanter(name)
    name=tostring(name or ""):gsub("^%s+",""):gsub("%s+$","")
    if name=="" then return false,"character name required" end
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db); sh.enchanter=name
    return true
end

function _G.UniversalBasisKeeperAPI:SetShredderSetting(key,value)
    local allowed={minProfit=true,minROI=true,maxBuyout=true,maxCandidates=true}
    if not allowed[key] then return false,"unsupported Shredder setting" end
    value=tonumber(value); if not value then return false,"numeric value required" end
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db); sh.settings[key]=value
    return true
end

function _G.UniversalBasisKeeperAPI:StartShredderScan()
    return _G.UBKShredderInternal.StartScan()
end

function _G.UniversalBasisKeeperAPI:StartShredderLiveStockRefresh(itemStrings)
    return _G.UBKShredderInternal.StartLiveStockRefresh(itemStrings)
end

function _G.UniversalBasisKeeperAPI:GetShredderLiveStock(itemArg)
    local itemString=self:ResolveItem(itemArg) or itemArg
    itemString=_G.UBKShredderInternal.BaseItemString(itemString)
    if type(itemString)~="string" then return nil end
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db)
    local row=sh.cache.liveStock and sh.cache.liveStock[itemString] or nil
    return row and CopyTable(row) or nil
end

function _G.UniversalBasisKeeperAPI:GetShredderCandidates()
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db)
    return CopyTable(sh.cache.candidates or {})
end

function _G.UniversalBasisKeeperAPI:GetShredderPipeline()
    return CopyTable(_G.UBKShredderInternal.GetPipeline())
end

function _G.UniversalBasisKeeperAPI:GetShredderHistory()
    local db=GetRealmDB(); local sh=_G.UBKShredderInternal.EnsureState(db)
    local out={}; for i=#(sh.history or {}),1,-1 do out[#out+1]=CopyTable(sh.history[i]) end; return out
end

function _G.UniversalBasisKeeperAPI:GetExpectedDisenchantOutputs(itemArg)
    local itemString=self:ResolveItem(itemArg) or itemArg
    return CopyTable(_G.UBKShredderInternal.ExpectedOutputs(itemString))
end

function _G.UniversalBasisKeeperAPI:RefreshAccounting()
    ProcessLedger(true)
    return true
end

function _G.UniversalBasisKeeperAPI:ImportNewestTSMData()
    RefreshRuntimeKeys()
    if not IsSupportedRealm() then
        return false,"UBK could not establish a supported TBC realm and faction for this character. Log fully into the world, then try again."
    end
    if type(TradeSkillMasterDB)~="table" or type(TSM_API)~="table" then
        return false,"TSM is not fully loaded yet. Open TSM once, then try again."
    end

    local db=GetRealmDB()
    db.setup=type(db.setup)=="table" and db.setup or {status="pending"}
    local beforeRealm=tonumber(db.setup.lastTSMImportRealmTime)
    local beforeRegion=tonumber(db.setup.lastTSMImportRegionTime)
    local realmTime,regionTime=self:GetMarketDataTimes()
    local setupStarted=false
    local records=0

    if db.setup.status=="pending" then
        local ok,info=_G.UBKSetupInternal.SetupBegin("import",true)
        if not ok then return false,info end
        setupStarted=true
    elseif db.setup.status=="review" then
        DiscoverUniversalMaterials(db,true)
        ApplyHistoricalCostAudit(db,true)
        RefreshCostReviews(db,true)
    else
        DiscoverUniversalMaterials(db,true)
        -- ProcessLedger returns both record and unit counts. Capture the first
        -- value before converting it; passing the call directly to tonumber
        -- makes Lua treat the unit count as tonumber's optional numeric base.
        local processedRecords=ProcessLedger(true)
        records=tonumber(processedRecords) or 0
        RefreshCostReviews(db,true)
    end

    local _,review=EnsureCostReviewState(db)
    local open=0
    for _,row in pairs(review.items or {}) do if type(row)=="table" and row.open then open=open+1 end end
    db.setup.reviewCount=open
    db.setup.lastTSMImportAt=time and time() or 0
    db.setup.lastTSMImportRealmTime=tonumber(realmTime)
    db.setup.lastTSMImportRegionTime=tonumber(regionTime)

    if open==0 and db.setup.status=="review" then
        local finished,why=_G.UBKSetupInternal.SetupFinish(false)
        if not finished then return false,why end
    end

    local marketChanged=(tonumber(realmTime) or 0)~=(beforeRealm or 0) or (tonumber(regionTime) or 0)~=(beforeRegion or 0)
    return true,{
        realm=REALM_NAME,
        faction=FACTION_NAME,
        setupStarted=setupStarted,
        setupStatus=db.setup.status,
        reviewCount=open,
        recordsProcessed=records,
        marketChanged=marketChanged,
        realmDataTime=realmTime,
        regionDataTime=regionTime,
    }
end

function _G.UniversalBasisKeeperAPI:FinishTSMImportReview()
    RefreshRuntimeKeys()
    local db=GetRealmDB()
    if type(db.setup)~="table" or db.setup.status=="complete" then return true,0 end
    if db.setup.status~="review" then return false,"TSM import is not waiting for Cost Review." end
    return _G.UBKSetupInternal.SetupFinish(false)
end

_G.UBKInternal = _G.UBKInternal or {}
-- Legacy accounting integrations use this deliberately narrow internal
-- accessor. External modules continue to consume the public API.
function _G.UBKInternal.GetRealmDB()
    return GetRealmDB()
end

function _G.UBKInternal.ShelfCommand(rest)
    local ss = EnsureShelfScoutState(GetRealmDB())
    local arg = NormalizeName(rest)
    if arg == "on" or arg == "enable" then
        ss.enabled = true
        ShelfInstallHook()
        ShelfRefreshPanel()
        print("|cff33ff99UBK Shelf Scout:|r ON. Passive observation only.")
    elseif arg == "off" or arg == "disable" then
        ss.enabled = false
        ShelfCloseUI()
        print("|cffffcc00UBK Shelf Scout:|r OFF.")
    elseif arg == "debug" then
        ss.debug = not ss.debug
        print(string.format("|cffffcc00UBK Shelf Scout debug:|r %s", ss.debug and "ON" or "OFF"))
        ShelfPrintStatus(true)
    elseif arg == "clear" then
        wipe(ss.history)
        shelfRuntime.current = nil
        ShelfRefreshPanel()
        print("|cffffcc00UBK Shelf Scout:|r candidate history cleared.")
    elseif arg == "show" then
        ShelfCreateUI()
        shelfRuntime.panel:Show()
        ShelfRefreshPanel()
    elseif arg == "hide" then
        if shelfRuntime.panel then shelfRuntime.panel:Hide() end
    elseif arg == "status" or arg == "" then
        ShelfPrintStatus(false)
        ShelfCreateUI()
        if ShelfShoppingActive() then shelfRuntime.badge:Show() end
    else
        print("|cffff7777UBK:|r /ubk shelf [on|off|status|show|hide|clear|debug]")
    end
end

function _G.UBKInternal.Help()
    print("|cffffcc00UBK 1.6 - Universal Basis Keeper:|r")
    print("  /ubk                              open the UBK Home page")
    print("  /ubk dock                         open the compact basis dock")
    print("  /ubk interface                           open the UBK interface")
    print("  /ubk basis                        open basis and coverage options")
    print("  /ubk scans                        open scan tuning")
    print("  /ubk list                         print all tracked item bases")
    print("  /ubk setup                        first-run TSM history setup (or reopen setup dialog)")
    print("  /ubk detail <material>            show one item's accounting + TSM value")
    print("  /ubk refresh                      process the TSM ledger + automatic TSM sync now")
    print("  /ubk mail                         show Auction House buyer-mail fallback")
    print("  /ubk mail importnext              BEFORE first arm: deliberately import current tracked buyer mails on next mailbox open")
    print("  /ubk mailaudit                    list currently visible tracked AH buyer invoices")
    print("  /ubk resolve <material> <price>   cost ONLY the currently unresolved units at this per-unit price")
    print("  /ubk review                      ONLY items which need a human cost/provenance decision")
    print("  /ubk classify <item> economic    preserve literal as opportunity/crafting value; exclude it from acquisition profit")
    print("  /ubk classify <item> manual      trust literal as acquisition cost; future purchases blend normally")
    print("  /ubk classify <item> unresolved  deliberately leave old unknown units unresolved; keep TSM value untouched")
    print("  /ubk caches <material>            show which toon/bank/mail caches hold it")
    print("  /ubk reconcile <material|all>     force pool quantity to TSM realm quantity; basis unchanged")
    print("  /ubk universal                  review tracked purchase/material universe")
    print("  /ubk universal list             concise READY / PARTIAL-SAFE / UNKNOWN / REVIEW health summary")
    print("  /ubk universal unknown          name every owned material with NO proven cost and explain why")
    print("  /ubk universal partial          list safe partial-cost materials + cost coverage")
    print("  /ubk universal all              full diagnostic census (verbose)")
    print("  /ubk universal on               explicitly activate new universal TSM ownership")
    print("  /ubk universal off              stop auto-writing newly discovered materials")
    print("  /ubk track <itemLink|itemID> [price]  manually enroll / seed a material")
    print("  /ubk own <material>               explicitly let UBK replace an existing TSM formula")
    print("  /ubk set <material> <price>       deliberately rebase UBK + TSM together")
    print("  /ubk auto [on|off]                show/change automatic TSM ownership")
    print("  /ubk pause <material|all>         stop automatic TSM writes for selected material(s)")
    print("  /ubk resume <material|all>        resume automatic TSM writes")
    print("  /ubk dryrun [material|all]        preview current UBK -> TSM values")
    print("  /ubk write <material|all>         force a TSM sync manually")
    print("  /ubk restore <material|all>       restore exact pre-UBK TSM values")
    print("  /ubk backups                      show captured pre-write TSM values")
    print("  /ubk status                       show accounting / TSM integration status")
    print("  /ubk shelf [on|off|status|show|hide|clear|debug]  always-passive TSM Shopping shelf + mycost detector")
    print("  /ubk goblin market <item>     show TSM AuctionDB/AppHelper realm + regional market/liquidity context")
    print("  /ubk goblin [show|high|common|rare|all|market <item>|stop|clear|status|hide]  opt-in candidate generator + exact AH scout")
    print("|cffaaaaaaUniversal build: every purchased item can carry UBK basis; only real TSM crafting materials are eligible for matprice writes.|r")
end

_G.UBKSetupInternal = _G.UBKSetupInternal or {}
function _G.UBKSetupInternal.CountTSMSetupEvidence()
    local mats=UBK_GetTSMMatsTable(); local rows,literals,formulas=0,0,0
    for _,entry in pairs(mats or {}) do
        if type(entry)=="table" then rows=rows+1; if entry.customValue~=nil then if IsLiteralMoney(entry.customValue) then literals=literals+1 else formulas=formulas+1 end end end
    end
    local ledger=GetTSMBuyLedger(); local buys=0
    if type(ledger)=="string" then for _ in ledger:gmatch("[^\r\n]+") do buys=buys+1 end end
    return rows,literals,formulas,buys
end
function _G.UBKSetupInternal.PrepareCurrentTSMProfile(db)
    -- CostBootstrap is retired in 1.4. UBK uses the player's current TSM
    -- profile and existing custom sources exactly as found. It never clones a
    -- profile or installs/overwrites a custom-price formula during setup.
    local profile="current TSM profile"
    if type(TSM_API)=="table" and type(TSM_API.GetActiveProfile)=="function" then
        local ok,value=pcall(TSM_API.GetActiveProfile)
        if ok and type(value)=="string" and value~="" then profile=value end
    end
    db.setup.profilePrepared=true
    db.setup.profileName=profile
    db.setup.originalProfile=profile
    db.setup.sourceConflicts={}
    db.setup.costBootstrapRetired=true
    return true,{profile=profile,original=profile,conflicts={},mutated=false}
end
function _G.UBKSetupInternal.ResetDiscoveryForSetup(db,mode)
    db.items={}; db.processedCounts={}; db.processedPurchaseQty=nil; db.activitySinceSeed=false
    db.universal=nil; EnsureUniversalState(db)
    local now=time and time() or 0; db.cutoffTime=now; db.lastLedgerTime=now
    -- A preview may already have built discovery metadata. Import must rebuild
    -- its paid-purchase index; Start Empty must deliberately skip that history.
    db.purchaseUniverseSchema=mode=="empty" and UBK_PURCHASE_UNIVERSE_SCHEMA or nil
    db.purchaseUniverseBootstrappedAt=mode=="empty" and now or nil
    db.purchaseUniverseSource=mode=="empty" and "start-empty" or nil
    db.costReview=nil; db.costAudit=nil
    -- Runtime discovery names are rebuilt from the current TSM faction-realm table.
    for k in pairs(BASIS_SEEDS) do BASIS_SEEDS[k]=nil end
    for i=#BASIS_ORDER,1,-1 do BASIS_ORDER[i]=nil end
end
function _G.UBKSetupInternal.SetupBegin(mode,quiet)
    local db=GetRealmDB(); db.setup=type(db.setup)=="table" and db.setup or {}
    if mode~="import" and mode~="empty" then return false,"choose import or empty" end
    local ok,profile=_G.UBKSetupInternal.PrepareCurrentTSMProfile(db)
    if not ok then return false,profile end
    _G.UBKSetupInternal.ResetDiscoveryForSetup(db,mode)
    db.setup.status="review"; db.setup.historyMode=mode; db.setup.startedAt=time and time() or 0
    local ws=EnsureWriteState(db); ws.mode="manual"; db.integrationMode="setup-review"
    local u=EnsureUniversalState(db); u.mode="preview"
    DiscoverUniversalMaterials(db,true); ApplyHistoricalCostAudit(db,true); RefreshCostReviews(db,true)
    if mode=="import" then
        -- Mark the historical ledger as consumed by the bootstrap so future processing only sees new acquisitions.
        local csv=GetTSMBuyLedger(); local seen={}; local newest=db.lastLedgerTime or 0; local factionCharacters=UBK_CurrentFactionCharacters()
        if type(csv)=="string" then
            for line in csv:gmatch("[^\r\n]+") do
                local itemString,_,_,timestamp,buyer=ParseBuyLine(line)
                if itemString and factionCharacters[buyer or ""] and db.items[itemString] then seen[line]=(seen[line] or 0)+1; db.processedCounts[line]=seen[line]; newest=math.max(newest,tonumber(timestamp) or 0) end
            end
        end
        db.lastLedgerTime=newest
    end
    local _,review=EnsureCostReviewState(db); local open=0
    for _,row in pairs(review.items or {}) do if type(row)=="table" and row.open then open=open+1 end end
    db.setup.reviewCount=open
    if not quiet then
        print(string.format("|cff33ff99UBK SETUP:|r using %s unchanged. %d cost question%s need review.",tostring(db.setup.profileName or "the current TSM profile"),open,open==1 and "" or "s"))
        if open>0 then print("  Use |cffffffff/ubk review|r (or UBK > Cost Review), resolve/classify each question, then |cffffffff/ubk setup finish|r.") end
        print("  |cffaaaaaaCostBootstrap is retired; no TSM profile or custom-price formula was created or changed.|r")
    end
    return true,open
end
function _G.UBKSetupInternal.SetupFinish(force)
    local db=GetRealmDB(); if type(db.setup)~="table" or db.setup.status~="review" then return false,"setup is not waiting for review" end
    RefreshCostReviews(db,true); local _,review=EnsureCostReviewState(db); local open=0
    for _,row in pairs(review.items or {}) do if type(row)=="table" and row.open then open=open+1 end end
    if open>0 and not force then return false,string.format("%d review item%s remain; use /ubk review, or /ubk setup finish force only if you deliberately want to leave them unresolved",open,open==1 and "" or "s") end
    db.setup.status="complete"; db.setup.completedAt=time and time() or 0; db.setup.reviewCount=open
    local ws=EnsureWriteState(db); ws.mode="automatic"; ws.autoEnabledAt=time and time() or 0; db.integrationMode="automatic-tsm-write"
    EnsureUniversalState(db).mode="active"
    AutoSyncTSM(true)
    -- PLAYER_LOGIN skips periodic maintenance while first-run setup is pending.
    -- Start it now as well as on later logins, without requiring a reload.
    if type(_G.UBKInternal)=="table" then
        if type(_G.UBKInternal.StartTicker)=="function" then _G.UBKInternal.StartTicker() end
        if type(_G.UBKInternal.ScheduleRefresh)=="function" then _G.UBKInternal.ScheduleRefresh() end
    end
    return true,open
end
function _G.UBKSetupInternal.PrintSetupStatus()
    local db=GetRealmDB(); local rows,literals,formulas,buys=_G.UBKSetupInternal.CountTSMSetupEvidence(); local st=db.setup or {}
    local profile="<unknown>"; if type(TSM_API)=="table" and type(TSM_API.GetActiveProfile)=="function" then local ok,v=pcall(TSM_API.GetActiveProfile); if ok then profile=v end end
    print(string.format("|cffffcc00UBK SETUP:|r status=%s realm=%s faction=%s active-profile=%s",tostring(st.status or "pending"),REALM_NAME,FACTION_NAME,tostring(profile)))
    print(string.format("  TSM evidence: %d material rows, %d literal material prices, %d protected formulas, %d purchase-ledger rows.",rows,literals,formulas,buys))
    if st.profilePrepared then print(string.format("  TSM profile used unchanged: %s",tostring(st.profileName))) end
    if st.status=="pending" then print("  /ubk setup import  = reconstruct from your TSM history/prices + human review\n  /ubk setup empty   = start UBK accounting from now") end
end
function _G.UBKSetupInternal.ShowSetupDialog()
    local db=GetRealmDB(); if type(db.setup)~="table" or db.setup.status~="pending" then return end
    if type(StaticPopupDialogs)~="table" or type(StaticPopup_Show)~="function" then _G.UBKSetupInternal.PrintSetupStatus(); return end
    local rows,literals,formulas,buys=_G.UBKSetupInternal.CountTSMSetupEvidence()
    StaticPopupDialogs["UBK_UNIVERSAL_SETUP"]={
        text=string.format("UBK first-time setup\n\nTSM found %d material rows, %d literal prices, %d protected formulas, and %d purchase-history rows on %s-%s.\n\nIMPORT TSM reads the current profile unchanged, reconstructs what it safely can, then sends ambiguous inventory to human review.\n\nSTART EMPTY begins UBK accounting from now without importing old purchase history.\n\nCostBootstrap is retired: neither choice clones a profile or changes a custom-price formula.",rows,literals,formulas,buys,REALM_NAME,FACTION_NAME),
        button1="Import TSM", button2="Start Empty", timeout=0, whileDead=true, hideOnEscape=true, preferredIndex=3,
        OnAccept=function() local ok,info=_G.UBKSetupInternal.SetupBegin("import",false); if not ok then print("|cffff7777UBK SETUP:|r "..tostring(info)) elseif tonumber(info or 0)>0 and _G.UBKInterface_Show then C_Timer.After(.2,function() _G.UBKInterface_Show("review") end) end end,
        OnCancel=function(_,reason) if reason~="clicked" then return end local ok,info=_G.UBKSetupInternal.SetupBegin("empty",false); if not ok then print("|cffff7777UBK SETUP:|r "..tostring(info)) end end,
    }
    StaticPopup_Show("UBK_UNIVERSAL_SETUP")
end
function _G.UBKSetupInternal.SetupCommand(rest)
    local arg=NormalizeName(rest)
    if arg=="import" or arg=="history" then local ok,info=_G.UBKSetupInternal.SetupBegin("import",false); if not ok then print("|cffff7777UBK SETUP:|r "..tostring(info)) elseif tonumber(info or 0)>0 and _G.UBKInterface_Show then _G.UBKInterface_Show("review") end
    elseif arg=="empty" or arg=="new" then local ok,info=_G.UBKSetupInternal.SetupBegin("empty",false); if not ok then print("|cffff7777UBK SETUP:|r "..tostring(info)) end
    elseif arg=="finish" then local ok,info=_G.UBKSetupInternal.SetupFinish(false); print((ok and "|cff33ff99UBK SETUP:|r complete. Automatic maintenance is now enabled." or "|cffff7777UBK SETUP:|r "..tostring(info)))
    elseif arg=="finishforce" or arg=="force" then local ok,info=_G.UBKSetupInternal.SetupFinish(true); print((ok and "|cff33ff99UBK SETUP:|r complete with unresolved inventory deliberately left excluded from basis." or "|cffff7777UBK SETUP:|r "..tostring(info)))
    elseif arg=="" or arg=="status" then _G.UBKSetupInternal.PrintSetupStatus(); local db=GetRealmDB(); if db.setup and db.setup.status=="pending" then _G.UBKSetupInternal.ShowSetupDialog() end
    else print("|cffffcc00UBK SETUP:|r /ubk setup [import|empty|status|finish|finish force]") end
end

function _G.UBKInternal.SlashHandler(msg)
    if not IsSupportedRealm() then
        print("|cffff7777UBK:|r this universal build requires the TBC Classic client and a valid realm/faction context.")
        return
    end

    msg = msg or ""
    local command, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    command = (command or ""):lower()

    if command == "setup" then
        _G.UBKSetupInternal.SetupCommand(rest)
    elseif command == "" or command == "home" then
        if type(_G.UBKUI_Show)=="function" then _G.UBKUI_Show("home")
        elseif type(_G.UBKDock_Show)=="function" then _G.UBKDock_Show("home") else PrintList() end
    elseif command == "scale" then
        if type(_G.UBKInterfaceCommand)=="function" then _G.UBKInterfaceCommand("scale "..rest) end
    elseif command == "dock" then
        if type(_G.UBKDock_Show)=="function" then _G.UBKDock_Show(rest~="" and rest or "home") end
    elseif command == "interface" then
        local page=NormalizeName(rest)
        if page=="" then page="home" end
        if type(_G.UBKUI_Show)=="function" then _G.UBKUI_Show(page) else print("|cffff7777UBK:|r The UBK interface is unavailable; check the addon installation.") end
    elseif command == "basis" or command == "coverage" then
        if type(_G.UBKUI_Show)=="function" then _G.UBKUI_Show("coverage") else PrintList() end
    elseif command == "scan" or command == "scans" or command == "scanner" or command == "tune" or command == "settings" or command == "options" then
        if type(_G.UBKUI_Show)=="function" then _G.UBKUI_Show("settings") else print("|cffff7777UBK:|r The UBK interface is unavailable; check the addon installation.") end
    elseif command == "position" or command == "positions" or command == "watch" or command == "market" or command == "chum" or command == "cross" or command == "shredder" or command == "prospecting" then
        local page=command=="positions" and "position" or command
        if type(_G.UBKUI_Show)=="function" then _G.UBKUI_Show(page) end
    elseif command == "list" then
        local db=GetRealmDB(); if db.setup and db.setup.status=="pending" then _G.UBKSetupInternal.PrintSetupStatus() else PrintList() end
    elseif command == "refresh" then
        local records = ProcessLedger(false)
        if records == 0 then
            print("|cffffcc00UBK:|r refreshed. No new tracked TSM purchases since the last pass; automatic TSM sync also ran.")
        end
        PrintList()
    elseif command == "detail" then
        local itemString = ResolveItem(rest)
        if itemString then
            PrintDetail(itemString)
        else
            print("|cffff7777UBK:|r unknown tracked material. Example: /ubk detail dawnstone")
        end
    elseif command == "caches" or command == "cache" then
        local itemString = ResolveItem(rest)
        if itemString then
            PrintCaches(itemString)
        else
            print("|cffff7777UBK:|r use /ubk caches <material>")
        end
    elseif command == "reconcile" then
        local target = NormalizeName(rest)
        ProcessLedger(true)
        if target == "all" then
            print("|cffffaa00UBK:|r reconciling ALL assumes you've refreshed every relevant toon/bank/mail cache.")
            for _, itemString in ipairs(BASIS_ORDER) do ReconcileOne(itemString) end
        else
            local itemString = ResolveItem(rest)
            if itemString then
                ReconcileOne(itemString)
            else
                print("|cffff7777UBK:|r use /ubk reconcile <material> or /ubk reconcile all")
            end
        end
    elseif command == "mail" then
        local mailArg = NormalizeName(rest)
        local db = GetRealmDB()
        local mc = EnsureMailCapture(db)
        if mailArg == "tooltips off" or mailArg == "tooltips on" then
            mc.hideTooltips = mailArg == "tooltips off"
            _G.UBKLiveTooltip.SetMailbox(mailboxSessionOpen,mc.hideTooltips)
            print("|cff33ff99UBK:|r Mailbox tooltips "..(mc.hideTooltips and "OFF" or "ON").." for this account. Other locations are unchanged.")
        elseif mailArg == "importnext" or mailArg == "import" then
            if mc.armed then
                print("|cffff7777UBK:|r Auction-mail capture is already armed; importnext is only allowed before the first baseline to prevent double-counting.")
            else
                mc.importNext = true
                print("|cffffcc00UBK:|r IMPORT-NEXT armed. Open the mailbox next; all currently visible tracked AH buyer invoices will be deliberately imported as purchases, then normal capture will arm.")
                print("  |cffff7777Use this only when those current buyer mails are genuinely new purchases you want UBK to cost.|r")
            end
        else
            if mailboxSessionOpen then
                if type(CheckInbox) == "function" then CheckInbox() end
                -- Status never scans all purchase history during collection.
            end
            PrintMailStatus(false)
            if not mailboxSessionOpen then
                print("  |cffaaaaaaNo active mailbox session detected. Open a mailbox; UBK arms automatically and does not depend on Blizzard MailFrame being visible.|r")
            elseif mailboxBaselinePending then
                print("  |cffaaaaaaMailbox detected; waiting for the inbox refresh to finish before baselining existing mail.|r")
            end
        end
    elseif command == "mailaudit" then
        PrintMailStatus(true)
    elseif command == "review" then
        if rest=="list" or type(_G.UBKUI_Show)~="function" then PrintCostReview() else _G.UBKUI_Show("review") end
    elseif command == "classify" then
        ClassifyCost(rest)
    elseif command == "resolve" then
        local materialText, priceText = rest:match("^(.-)%s+([%d%.]+[gscGSC].*)$")
        local itemString = materialText and ResolveItem(materialText) or nil
        if itemString and priceText then
            ResolveUnresolved(itemString, priceText)
        else
            print("|cffff7777UBK:|r usage: /ubk resolve <material> <per-unit price>  Example: /ubk resolve mote of water 1g57s23c")
        end
    elseif command == "universal" or command == "materials" or command == "mats" then
        UniversalCommand(rest)
    elseif command == "track" then
        TrackMaterial(rest)
    elseif command == "own" or command == "adopt" then
        SetOwnershipTarget(rest)
    elseif command == "set" or command == "rebase" then
        SetBasisTarget(rest)
    elseif command == "auto" then
        SetAutoMode(rest)
    elseif command == "pause" then
        SetPause(rest, true)
    elseif command == "resume" then
        SetPause(rest, false)
    elseif command == "dryrun" or command == "preview" then
        DryRun(rest)
    elseif command == "write" then
        WriteTarget(rest)
    elseif command == "restore" then
        RestoreTarget(rest)
    elseif command == "backups" or command == "backup" then
        PrintBackups()
    elseif command == "status" then
        PrintStatus()
    elseif command == "shelf" or command == "shelfscout" then
        _G.UBKInternal.ShelfCommand(rest)
    elseif command == "goblin" or command == "radar" or command == "hardcore" then
        GoblinCommand(rest)
    elseif command == "help" or command == "?" then
        _G.UBKInternal.Help()
    else
        _G.UBKInternal.Help()
    end
end

SLASH_UNIVERSALBASISKEEPER1 = "/ubk"
SLASH_UNIVERSALBASISKEEPER2 = "/basis"
SLASH_UNIVERSALBASISKEEPER3 = "/ubkbasis"
SlashCmdList.UNIVERSALBASISKEEPER = _G.UBKInternal.SlashHandler

function _G.UBKInternal.AuctionBusy()
    local b=_G.UBKTSMGroupBridge
    if not b or not b.ready or type(b.IsAuctionScanBusy)~="function" then return false end
    local ok,busy=pcall(b.IsAuctionScanBusy)
    return ok and busy==true
end
function _G.UBKInternal.DeferAuctionRefresh()
    local internal=_G.UBKInternal
    if internal.auctionRefreshPending then return end
    internal.auctionRefreshPending=true
    C_Timer.After(0.5,function()
        internal.auctionRefreshPending=false
        if _G.UBKPurchaseLedger.AnySourceOpen() then return end
        if internal.AuctionBusy() then internal.DeferAuctionRefresh()
        else internal.ScheduleAccountingSettlement() end
    end)
end

function _G.UBKInternal.ScheduleAccountingSettlement()
    local p=_G.UBKPurchaseLedger
    if p.AnySourceOpen() or mailboxSessionOpen or not IsSupportedRealm() then return end
    if p.settlementPending then return end
    p.settlementPending=true
    local generation=p.generation
    local function Interrupted()
        if p.AnySourceOpen() or mailboxSessionOpen or generation~=p.generation then
            p.settlementPending=false
            if not p.AnySourceOpen() and not mailboxSessionOpen then _G.UBKInternal.ScheduleAccountingSettlement() end
            return true
        end
    end
    C_Timer.After(0.25,function()
        if Interrupted() then return end
        if _G.UBKInternal.AuctionBusy() then
            p.settlementPending=false;_G.UBKInternal.DeferAuctionRefresh();return
        end
        local db=GetRealmDB()
        if not SetupAllowsProcessing(db) then p.settlementPending=false;return end
        local okRead,csv=pcall(GetTSMBuyLedger)
        if not okRead then
            p.settlementPending=false
            print("|cffff7777UBK:|r Ledger unavailable; captured evidence is retained. "..tostring(csv));return
        end
        local okStart,whyStart=pcall(p.PrepareBatch,csv or "",db,ParseBuyLine,UBK_CurrentFactionCharacters(),BASIS_CUTOVER_TIME,
            function(step) C_Timer.After(0.01,function()
                if Interrupted() then return end
                local ok,why=pcall(step)
                if not ok then
                    p.settlementPending=false
                    print("|cffff7777UBK:|r Accounting preparation paused; captured evidence is retained. "..tostring(why))
                end
            end) end,
            function(prepared)
                if Interrupted() then return end
                if GetRealmDB()~=db then p.settlementPending=false;return end
                if _G.UBKInternal.AuctionBusy() then
                    p.settlementPending=false;_G.UBKInternal.DeferAuctionRefresh();return
                end
                local ok,why=pcall(ProcessLedger,true,false,prepared)
                p.settlementPending=false
                if not ok then
                    print("|cffff7777UBK:|r Accounting settlement paused; review Cost Coverage. "..tostring(why));return
                end
                if db.accountingCapture then
                    db.accountingCapture.pending=false
                    db.accountingCapture.sources={}
                    db.accountingCapture.lastSettledAt=time()
                end
            end)
        if not okStart then
            p.settlementPending=false
            print("|cffff7777UBK:|r Accounting preparation paused; captured evidence is retained. "..tostring(whyStart))
        end
    end)
end

function _G.UBKInternal.ScheduleReceiptRefresh()
    _G.UBKInternal.ScheduleAccountingSettlement()
end
function _G.UBKInternal.AccountingStatus()
    return _G.UBKPurchaseLedger.Status(GetRealmDB())
end
function _G.UBKInternal.ScheduleRefresh()
    _G.UBKInternal.ScheduleAccountingSettlement()
end
function _G.UBKInternal.StartTicker()
    if tickerStarted or not IsSupportedRealm() then return end
    local db=GetRealmDB(); if not SetupAllowsProcessing(db) then return end
    tickerStarted=true
    local function Tick()
        if not IsSupportedRealm() then return end
        _G.UBKInternal.ScheduleAccountingSettlement()
        C_Timer.After(TICK_SECONDS,Tick)
    end
    C_Timer.After(TICK_SECONDS,Tick)
end


-- ============================================================================
-- UBK v1.3.1 Loot Basis engine
--
-- Loot is NOT a purchase and is never silently valued at zero.
-- If the item already has a trusted UBK basis when the loot window opens, the
-- looted units enter the working basis at 95% of that pre-loot basis.
-- If there is no trusted basis yet, the observed units remain unresolved and
-- the item is placed into /ubk review for a human starting-basis decision.
-- ============================================================================
_G.UBKLootInternal = _G.UBKLootInternal or {}
_G.UBKLootRuntime = _G.UBKLootRuntime or { windowOpen=false, openedAt=0, windowSlots={}, location=nil }

function _G.UBKLootInternal.EnsureState(db)
    if type(db.lootCapture) ~= "table" then
        db.lootCapture = {
            schema = 1,
            pendingLots = {},
            capturedWindows = 0,
            capturedQty = 0,
            appliedQty = 0,
            imputedQty = 0,
            unresolvedQty = 0,
        }
    end
    local lc = db.lootCapture
    lc.schema = 1
    if type(lc.pendingLots) ~= "table" then lc.pendingLots = {} end
    lc.capturedWindows = tonumber(lc.capturedWindows) or 0
    lc.capturedQty = tonumber(lc.capturedQty) or 0
    lc.appliedQty = tonumber(lc.appliedQty) or 0
    lc.imputedQty = tonumber(lc.imputedQty) or 0
    lc.unresolvedQty = tonumber(lc.unresolvedQty) or 0
    return lc
end

function _G.UBKLootInternal.EnsureTrackedItem(db, itemString, itemName)
    if not db or not itemString or IsUniversalExcluded(itemString) then return nil end
    local state = db.items[itemString]
    if state then return state end

    state = UBK_EnsurePurchasedItemForLedger(db, itemString, 0, time and time() or 0)
    if not state then return nil end

    local observed = GetRealmQuantityForItem(itemString)
    observed = math.max(0, tonumber(observed) or 0)
    state.lastObserved = observed
    state.trackingClass = state.tsmMaterial and "tsm-material" or "looted-item"
    state.seedSource = "first-seen-loot"
    state.costProvenance = "unresolved"
    state.firstSeenLootReview = true
    state.needsCostReview = true
    state.reviewReason = "First-seen looted inventory has no established UBK basis"
    if itemName and BASIS_SEEDS[itemString] and (not BASIS_SEEDS[itemString].name or BASIS_SEEDS[itemString].name:match("^i:%d+$") or BASIS_SEEDS[itemString].name:match("^Item %d+$")) then
        BASIS_SEEDS[itemString].name = itemName
    end
    return state
end

function _G.UBKLootInternal.QueueLot(db, itemString, itemName, qty)
    if _G.UBKProspectingLearning and _G.UBKProspectingLearning:IsProspectLoot() then return 0 end
    qty = math.max(0, tonumber(qty) or 0)
    if qty <= 0 then return 0 end
    local state = _G.UBKLootInternal.EnsureTrackedItem(db, itemString, itemName)
    if not state then return 0 end

    local lc = _G.UBKLootInternal.EnsureState(db)
    lc.pendingLots[itemString] = type(lc.pendingLots[itemString]) == "table" and lc.pendingLots[itemString] or {}

    local trustedBasis = 0
    if CostTrustedForRadar(state, itemString) then trustedBasis = tonumber(GetUnitBasis(state)) or 0 end

    local where = type(_G.UBKLootRuntime.location) == "table" and _G.UBKLootRuntime.location or _G.UBKWorldDropInternal.CaptureWorldLocation()
    local lot = {
        qty = qty,
        capturedAt = time and time() or 0,
        character = UnitName and UnitName("player") or nil,
        basisAtCapture = trustedBasis > 0 and trustedBasis or 0,
        imputedUnit = trustedBasis > 0 and (trustedBasis * 0.95) or 0,
        source = "loot",
        zone = where and where.zone or nil,
        subZone = where and where.subZone or nil,
        mapID = where and where.mapID or nil,
        x = where and where.x or nil,
        y = where and where.y or nil,
    }
    table.insert(lc.pendingLots[itemString], lot)
    lc.capturedQty = lc.capturedQty + qty
    return qty
end

function _G.UBKLootInternal.CaptureLootWindow()
    if _G.UBKProspectingLearning and _G.UBKProspectingLearning:IsProspectLoot() then return 0 end
    if not IsSupportedRealm() then return 0 end
    local db = GetRealmDB()
    if not SetupAllowsProcessing(db) then return 0 end
    if _G.UBKLootRuntime.windowOpen then return 0 end
    _G.UBKLootRuntime.windowOpen = true
    _G.UBKLootRuntime.openedAt = time and time() or 0
    _G.UBKLootRuntime.windowSlots = {}
    _G.UBKLootRuntime.location = _G.UBKWorldDropInternal.CaptureWorldLocation()

    if type(GetNumLootItems) ~= "function" or type(GetLootSlotLink) ~= "function" then return 0 end
    local eligible = 0
    local slots = tonumber(GetNumLootItems()) or 0
    for slot = 1, slots do
        local link = GetLootSlotLink(slot)
        local itemID = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
        if itemID then
            local itemName, qty, locked, isQuestItem, itemQuality = nil, nil, false, false, nil
            if type(GetLootSlotInfo) == "function" then
                local texture, name, quantity, currencyID, quality, isLocked, quest = GetLootSlotInfo(slot)
                itemName = name
                itemQuality = quality
                qty = quantity
                locked = isLocked == true
                isQuestItem = quest == true
            end
            qty = math.max(1, tonumber(qty) or 1)
            if not locked and not isQuestItem and itemQuality~=0 then
                _G.UBKLootRuntime.windowSlots[slot] = {
                    itemString = "i:" .. tostring(itemID),
                    itemName = itemName,
                    qty = qty,
                    committed = false,
                }
                eligible = eligible + qty
            end
        end
    end
    local lc = _G.UBKLootInternal.EnsureState(db)
    lc.capturedWindows = lc.capturedWindows + 1
    return eligible
end

function _G.UBKLootInternal.CommitLootSlot(slot)
    slot = tonumber(slot)
    if not slot or not _G.UBKLootRuntime.windowOpen then return 0 end
    local row = type(_G.UBKLootRuntime.windowSlots) == "table" and _G.UBKLootRuntime.windowSlots[slot] or nil
    if type(row) ~= "table" or row.committed then return 0 end
    row.committed = true
    local db = GetRealmDB()
    if not SetupAllowsProcessing(db) then return 0 end
    return _G.UBKLootInternal.QueueLot(db, row.itemString, row.itemName, row.qty)
end

function _G.UBKLootInternal.CloseLootWindow()
    _G.UBKLootRuntime.windowOpen = false
    _G.UBKLootRuntime.openedAt = 0
    _G.UBKLootRuntime.windowSlots = {}
    _G.UBKLootRuntime.location = nil
end

function _G.UBKLootInternal.ApplyObservedGain(db, itemString, state, gain, silent)
    if _G.UBKProspectingSessions and _G.UBKProspectingSessions:Pending(itemString) then return 0 end
    gain = math.max(0, tonumber(gain) or 0)
    if gain <= 0 or not db or not state then return 0 end
    local lc = _G.UBKLootInternal.EnsureState(db)
    local lots = lc.pendingLots[itemString]
    if type(lots) ~= "table" then return 0 end

    local now = time and time() or 0
    local matched = 0
    local i = 1
    while i <= #lots and matched < gain do
        local lot = lots[i]
        local age = now - (tonumber(lot.capturedAt) or now)
        local lq = math.max(0, tonumber(lot.qty) or 0)
        if lq <= 0 or age > 600 then
            table.remove(lots, i)
        else
            local take = math.min(lq, gain - matched)
            state.lastLootTime = tonumber(lot.capturedAt) or now
            state.lastLootCapture = {
                capturedAt = tonumber(lot.capturedAt) or now,
                character = lot.character,
                zone = lot.zone,
                subZone = lot.subZone,
                mapID = tonumber(lot.mapID),
                x = tonumber(lot.x),
                y = tonumber(lot.y),
                basisAtCapture = tonumber(lot.basisAtCapture) or 0,
                imputedUnit = tonumber(lot.imputedUnit) or 0,
                qty = take,
                source = "loot",
            }
            local imputedUnit = tonumber(lot.imputedUnit) or 0
            if imputedUnit > 0 then
                local addValue = take * imputedUnit
                state.qty = (tonumber(state.qty) or 0) + take
                state.value = (tonumber(state.value) or 0) + addValue
                state.lastBasis = GetUnitBasis(state)
                state.lootImputedQty = (tonumber(state.lootImputedQty) or 0) + take
                state.lootImputedValue = (tonumber(state.lootImputedValue) or 0) + addValue
                state.lastLootTime = now
                state.basisReady = GetUnitBasis(state) > 0
                local prior = CostProvenanceLabel(state, itemString)
                if prior ~= "manual-economic" then state.costProvenance = "mixed-trusted" end
                lc.imputedQty = lc.imputedQty + take
                if not silent then
                    print(string.format("|cff66ccffUBK LOOT:|r %s x%d entered working basis at 95%% of pre-loot basis (%s each); new UBK basis %s.",
                        BASIS_SEEDS[itemString] and BASIS_SEEDS[itemString].name or itemString,
                        take, FormatMoney(imputedUnit), FormatMoney(GetUnitBasis(state))))
                end
            else
                AddUnresolvedLot(state, take, "loot", "First-seen loot has no established UBK basis")
                state.firstSeenLootReview = true
                state.needsCostReview = true
                state.reviewReason = "First-seen looted inventory has no established UBK basis"
                state.trackingClass = state.tsmMaterial and "tsm-material" or "looted-item"
                lc.unresolvedQty = lc.unresolvedQty + take
                if not silent then
                    print(string.format("|cffff9933UBK LOOT REVIEW:|r %s x%d has no established basis; added to /ubk review instead of inventing a value.",
                        BASIS_SEEDS[itemString] and BASIS_SEEDS[itemString].name or itemString, take))
                end
            end
            AddShredEligibleQty(state, take)
            lot.qty = lq - take
            matched = matched + take
            lc.appliedQty = lc.appliedQty + take
            if lot.qty <= 0 then table.remove(lots, i) else i = i + 1 end
        end
    end
    if #lots == 0 then lc.pendingLots[itemString] = nil end
    return matched
end


events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("MAIL_SHOW")
events:RegisterEvent("MAIL_INBOX_UPDATE")
events:RegisterEvent("MAIL_CLOSED")
events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
events:RegisterEvent("TRADE_SHOW")
events:RegisterEvent("TRADE_CLOSED")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("MERCHANT_CLOSED")
events:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
events:RegisterEvent("BANKFRAME_OPENED")
events:RegisterEvent("BANKFRAME_CLOSED")
events:RegisterEvent("LOOT_OPENED")
events:RegisterEvent("LOOT_SLOT_CLEARED")
events:RegisterEvent("LOOT_CLOSED")

events:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName == ADDON then
            RefreshRuntimeKeys()
            EnsureRootDB()
            if IsSupportedRealm() then
                GetRealmDB()
            end
        elseif addonName == "TradeSkillMaster" then
            RefreshRuntimeKeys()
            if IsSupportedRealm() then
                local db=GetRealmDB()
                if SetupAllowsProcessing(db) then DiscoverUniversalMaterials(db,true); _G.UBKInternal.ScheduleRefresh() end
                C_Timer.After(1.0,_G.UBKSetupInternal.ShowSetupDialog)
            end
            C_Timer.After(1, ShelfInstallHook)
            C_Timer.After(3, InstallMailLootHooks)
        elseif addonName == "Blizzard_AuctionUI" then
            ShelfInstallHook()
        end
        return
    end

    if event == "PLAYER_LOGOUT" then
        -- SavedVariables persist captured receipts and the pending marker.
        -- Resume the queued settlement on login; never scan history during logout.
        return
    end

    if not IsSupportedRealm() then
        if event == "PLAYER_LOGIN" and not warnedUnsupportedClient then warnedUnsupportedClient=true; print("|cffff7777UBK:|r universal package loaded outside the supported TBC Classic client; accounting is disabled.") end
        return
    end

    event=_G.UBKPurchaseLedger.NormalizeEvent(event,addonName,Enum and Enum.PlayerInteractionType)
    if not event then return end
    local sourceChange=_G.UBKPurchaseLedger.SourceEvent(event,GetRealmDB(),time())
    if sourceChange=="close" then _G.UBKInternal.ScheduleAccountingSettlement() end

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        RefreshRuntimeKeys()
        local db = GetRealmDB()
        if SetupAllowsProcessing(db) then
            DiscoverUniversalMaterials(db,true); _G.UBKInternal.ScheduleRefresh(); _G.UBKInternal.StartTicker()
        elseif db.setup and db.setup.status=="pending" then C_Timer.After(1.5,_G.UBKSetupInternal.ShowSetupDialog) end
        ShelfAccountNames()
        UBK_InstallTooltipHooks()
        ShelfInstallHook()
        C_Timer.After(2, ShelfInstallHook)
        C_Timer.After(3, InstallMailLootHooks)
    elseif event == "AUCTION_HOUSE_SHOW" then
        ShelfInstallHook()
        C_Timer.After(0.25, ShelfRefreshPanel)
        _G.UBKInternal.ScheduleRefresh()
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        ShelfOnAuctionListUpdate()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ShelfCloseUI()
        if goblinRuntime.scanActive then GoblinStopScan("Auction House closed. Radar stopped; passive mode remains available next time.") end
        if _G.UBKShredderLiveRuntime and _G.UBKShredderLiveRuntime.active and _G.UBKShredderInternal and _G.UBKShredderInternal.LiveStop then
            _G.UBKShredderInternal.LiveStop("Auction House closed. Shredder live-stock refresh stopped safely.")
        end
        if goblinRuntime.panel then goblinRuntime.panel:Hide() end
        _G.UBKInternal.ScheduleRefresh()
    elseif event == "LOOT_OPENED" then
        _G.UBKLootInternal.CaptureLootWindow()
        _G.UBKInternal.ScheduleRefresh()
    elseif event == "LOOT_SLOT_CLEARED" then
        _G.UBKLootInternal.CommitLootSlot(addonName)
        _G.UBKInternal.ScheduleRefresh()
    elseif event == "LOOT_CLOSED" then
        _G.UBKLootInternal.CloseLootWindow()
        _G.UBKInternal.ScheduleRefresh()
    elseif event == "MAIL_SHOW" then
        local setupDB=GetRealmDB(); if not SetupAllowsProcessing(setupDB) then return end
        mailboxSessionOpen = true
        _G.UBKLiveTooltip.SetMailbox(true,EnsureMailCapture(GetRealmDB()).hideTooltips)
        mailLootHook.recentCalls = {}
        mailLootHook.burstActive = false
        mailLootHook.settleGeneration = (tonumber(mailLootHook.settleGeneration) or 0) + 1
        InstallMailLootHooks()
        local db = GetRealmDB()
        local mc = EnsureMailCapture(db)
        mailLootHook.captureArmed = mc.armed == true
        if not mc.armed then
            mailboxBaselinePending = true
            mailLootHook.captureArmed = false
            print("|cffffcc00UBK 1.6:|r mailbox detected; baselining existing mail before capture is armed...")
            if type(CheckInbox) == "function" then CheckInbox() end
            C_Timer.After(MAIL_BASELINE_DELAY, function()
                if mailboxSessionOpen and mailboxBaselinePending then
                    FinishMailboxBaseline()
                end
            end)
        else
            mailLootHook.burstActive = true
            mailLootHook.settleGeneration = (tonumber(mailLootHook.settleGeneration) or 0) + 1
            local generation = mailLootHook.settleGeneration
            C_Timer.After(MAIL_SCAN_DELAY, function()
                if mailboxSessionOpen and generation == mailLootHook.settleGeneration then
                    mailLootHook.burstActive = false
                    -- Receipts are secured by the pre-loot hook; settle on close.
                end
            end)
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        _G.UBKInternal.ScheduleRefresh()
    elseif event == "MAIL_INBOX_UPDATE" then
        mailLootHook.recentCalls = {}
        if mailboxSessionOpen then
            if mailboxBaselinePending then
                FinishMailboxBaseline()
            else
                -- MAIL_INBOX_UPDATE fires repeatedly during TSM collect-all. Do not
                -- scan TSM Accounting or inventory on every mutation. Debounce until
                -- the inbox is quiet, then reconcile once.
                mailLootHook.burstActive = true
            mailLootHook.settleGeneration = (tonumber(mailLootHook.settleGeneration) or 0) + 1
            local generation = mailLootHook.settleGeneration
                C_Timer.After(1.25, function()
                    if mailboxSessionOpen and generation == mailLootHook.settleGeneration then
                        mailLootHook.burstActive = false
                        -- No history scan or cost resolution during collection.
                    end
                end)
            end
        end
    elseif event == "MAIL_CLOSED" then
        mailboxSessionOpen = false
        _G.UBKLiveTooltip.SetMailbox(false,false)
        mailboxBaselinePending = false
        mailLootHook.recentCalls = {}
        mailLootHook.captureArmed = false
        mailLootHook.burstActive = false
        mailLootHook.settleGeneration = (tonumber(mailLootHook.settleGeneration) or 0) + 1
        _G.UBKInternal.ScheduleAccountingSettlement()
    else
        _G.UBKInternal.ScheduleRefresh()
    end
end)

-- BEGIN UBK PROSPECT ACCOUNTING ADAPTER
-- Kept inside the core to use its scoped ledger, lot and provenance rules.
_G.UBKProspectAccounting={}
function _G.UBKProspectAccounting.Peek()
    local root=_G.UniversalBasisKeeperDB
    return root and root.realms and root.realms[REALM_KEY]
end
function _G.UBKProspectAccounting.DB()
    if not IsSupportedRealm() then return nil end
    local db=GetRealmDB()
    if not db or not db.setup or db.setup.status~="complete" then return nil end
    return db
end
function _G.UBKProspectAccounting.Refresh() ProcessLedger(true) end
function _G.UBKProspectAccounting.Observe(item)
    return math.max(0,tonumber(GetRealmQuantityForItem(item)) or 0)
end
function _G.UBKProspectAccounting.Track(item)
    local db=_G.UBKProspectAccounting.DB()
    if db then return _G.UBKShredderInternal.EnsureTransformItem(db,item) end
end
function _G.UBKProspectAccounting.VendorSell(item)
    local id=tonumber(tostring(item):match("^i:(%d+)$"))
    if id and type(GetItemInfo)=="function" then
        local name,_,_,_,_,_,_,_,_,_,price=GetItemInfo(id)
        if name and type(price)=="number" and price>=0 and price<math.huge then return price end
    end
    local price=GoblinPrice("vendorsell",item)
    if type(price)=="number" and price>=0 and price<math.huge then return price end
end
function _G.UBKProspectAccounting.Quote(item)
    for _,source in ipairs({"dbminbuyout","dbrecent","dbmarket","dbhistorical","vendorsell"}) do
        local value=GoblinPrice(source,item)
        if type(value)=="number" and value>0 and value<math.huge then return value end
    end
end
function _G.UBKProspectAccounting.Input(item,bagQty)
    local db=_G.UBKProspectAccounting.DB()
    if not db then return {unknownQty=5,knownCost=0,provenance="Complete UBK setup first"} end
    local state=_G.UBKShredderInternal.EnsureTransformItem(db,item)
    if not state then return {unknownQty=5,knownCost=0} end
    -- Actual bags are a lower bound on owned stock while TSM's cache catches up.
    local observed=math.max(tonumber(bagQty) or 0,_G.UBKProspectAccounting.Observe(item))
    local known=tonumber(state.qty) or 0
    local unknown=tonumber(state.bootstrapUnresolved) or 0
    local missing=math.max(0,observed-known-unknown)
    if missing>0 then AddUnresolvedLot(state,missing,"prospecting-input");unknown=unknown+missing end
    local trusted=CostTrustedForRadar(state,item)
    local basis=known>0 and (tonumber(state.value) or 0)/known or 0
    local unknownFive=math.min(5,unknown)
    if not trusted or basis<=0 or known<5-unknownFive then unknownFive=5 end
    return {unknownQty=unknownFive,knownCost=(5-unknownFive)*basis,provenance=CostProvenanceLabel(state,item),owned=observed,buysQty=tonumber(state.buysQty) or 0}
end
function _G.UBKProspectAccounting.ReservedQty(state)
    local n=0
    for _,lot in ipairs(state.unresolvedLots or {}) do if lot.source=="prospecting-pending" then n=n+(tonumber(lot.qty) or 0) end end
    return n
end
function _G.UBKProspectAccounting.ReserveGain(state,item,gain)
    local _,pending=_G.UBKProspectingSessions:Pending(item)
    local qty=math.min(gain,math.max(0,pending-_G.UBKProspectAccounting.ReservedQty(state)))
    if qty>0 then AddUnresolvedLot(state,qty,"prospecting-pending","Reload to settle ore session") end
    return qty
end
function _G.UBKProspectAccounting.RemoveReserved(state,qty)
    if _G.UBKProspectAccounting.ReservedQty(state)<qty then return false end
    local remaining=qty
    for _,lot in ipairs(state.unresolvedLots or {}) do
        if lot.source=="prospecting-pending" then
            local take=math.min(remaining,lot.qty);lot.qty=lot.qty-take;remaining=remaining-take
        end
    end
    state.bootstrapUnresolved=state.bootstrapUnresolved-qty
    state.unexplainedGain=state.bootstrapUnresolved
    return true
end
function _G.UBKProspectAccounting.Settle(plan)
    local db=_G.UBKProspectAccounting.DB();if not db then return false,"UBK setup is not complete" end
    local staged={}
    -- Validate and stage EVERY item before writing ANY cost or settlement marker.
    for item,qty in pairs(plan.outputs) do
        local state=db.items[item];local cost=plan.allocations[item]
        if not state or type(cost)~="number" or cost<0 or cost~=cost or cost==math.huge then return false,"Invalid allocation" end
        local observed=_G.UBKProspectAccounting.Observe(item)
        if (tonumber(state.bootstrapUnresolved) or 0)<qty or observed<(tonumber(state.qty) or 0)+qty then
            return false,"Waiting for unresolved output inventory; do not sell or craft it"
        end
        local copy=CopyTable(state)
        if not _G.UBKProspectAccounting.RemoveReserved(copy,qty) then return false,"Waiting for reserved prospect output inventory" end
        copy.qty=(tonumber(copy.qty) or 0)+qty;copy.value=(tonumber(copy.value) or 0)+cost
        copy.lastBasis=copy.value/copy.qty;copy.basisReady=copy.lastBasis>0
        copy.costProvenance=(tonumber(state.qty) or 0)>0 and "mixed-trusted" or "shredder-transfer"
        copy.provenanceNote="Actual ore cost allocated across the saved prospecting session ("..plan.method..")."
        copy.prospectQty=(tonumber(copy.prospectQty) or 0)+qty
        copy.prospectValue=(tonumber(copy.prospectValue) or 0)+cost
        copy.lastObserved=observed
        if copy.bootstrapUnresolved<=0 then copy.firstSeenLootReview=false;copy.needsCostReview=false end
        staged[item]=copy
    end
    -- No callbacks, yields, TSM calls or disk operations inside the commit.
    for item,copy in pairs(staged) do db.items[item]=copy end
    for _,r in ipairs(plan.records) do r.settled=true;r.settledAt=time();r.allocationMethod=plan.method;r.settleError=nil end
    plan.records[1].poolAllocations=CopyTable(plan.allocations)
    plan.records[1].poolCost=plan.cost
    plan.records[1].poolInputCost=plan.inputCost or plan.cost
    plan.records[1].poolVendorCredit=plan.vendorCredit or 0
    plan.records[1].poolVendorSurplus=plan.vendorSurplus or 0
    plan.records[1].poolByproducts=CopyTable(plan.byproducts or {})
    db.activitySinceSeed=true
    return true
end
function _G.UniversalBasisKeeperAPI:PreviewProspectingOreCost(item,priceText)
    local p=_G.UBKProspectingSessions
    if not p or not tostring(item):match("^i:%d+$") then return false,"Invalid ore" end
    local copper=ParseMoney(priceText)
    if not copper or copper<=0 or copper~=copper or copper==math.huge then return false,"Tell me the ore's basis per ore, for example 2g50s." end
    local db=_G.UBKProspectAccounting.DB();if not db then return false,"Complete UBK setup first." end
    _G.UBKProspectAccounting.Refresh()
    local state=db.items[item]
    if p:InputSyncPending(item) then return false,"TSM is still updating consumed ore inventory. Wait a moment, then press Review again." end
    local unknown,token=p:UnknownInput(item)
    local stock=state and (tonumber(state.bootstrapUnresolved) or 0) or 0
    if unknown+stock<=0 then return false,"No unknown ore remains. If its existing cost is untrusted, review the ore in Cost Coverage." end
    local known=state and (tonumber(state.qty) or 0) or 0
    local value=state and (tonumber(state.value) or 0) or 0
    return true,{prospecting=true,itemString=item,name=self:GetItemName(item),unresolvedQty=unknown+stock,
        pendingInputQty=unknown,stockUnresolvedQty=stock,knownQty=known,observedQty=_G.UBKProspectAccounting.Observe(item),
        currentBasis=known>0 and value/known or 0,enteredUnitPrice=copper,
        projectedBasis=known+stock>0 and (value+stock*copper)/(known+stock) or copper,
        resolutionToken=token.."|"..stock.."|"..known.."|"..value}
end
function _G.UniversalBasisKeeperAPI:ResolveProspectingOreCost(item,priceText,token)
    local ok,preview=self:PreviewProspectingOreCost(item,priceText)
    if not ok then return false,preview end
    if preview.resolutionToken~=token then return false,"Ore inventory or pending prospects changed; review again." end
    if preview.stockUnresolvedQty>0 then
        local resolved,err=ResolveUnresolved(item,priceText)
        if not resolved then return false,err end
    end
    _G.UBKProspectingSessions:ResolveInputs(item,preview.enteredUnitPrice)
    return true,preview
end
-- END UBK PROSPECT ACCOUNTING ADAPTER
