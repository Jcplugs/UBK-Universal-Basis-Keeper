-- UBK raw-gem prospecting comparison. Read-only; no buying, casting or basis writes.
-- Uses the local TSM yield baseline and complete personal prospecting samples.
-- This distributable file contains no external prospecting yield coefficients.
-- amountOfMats is expected RAW gems per ONE ore; a prospect consumes FIVE ores.
-- Deliberately excludes retail/Panda data, dust/byproduct income, and cut gems.
-- TSM yield estimates are not a promise for an individual prospect or small batch.
local API = _G.UniversalBasisKeeperAPI
if type(API) ~= "table" then return end
local BATCH_SIZE, NET_AH_FACTOR = 5, 0.95
-- Only public item facts live in the distributed addon. Expected yields are
-- generated on the user's PC from their separately installed TSM data.
local ORE_FACTS = {
    [2770]={name="Copper Ore",skill=20,quality=1},
    [2771]={name="Tin Ore",skill=50,quality=1},
    [2772]={name="Iron Ore",skill=125,quality=1},
    [3858]={name="Mithril Ore",skill=175,quality=1},
    [10620]={name="Thorium Ore",skill=250,quality=1},
    [23424]={name="Fel Iron Ore",skill=275,quality=1},
    [23425]={name="Adamantite Ore",skill=325,quality=1},
}
local function SupportedClient()
    if type(GetBuildInfo)=="function" then
        local _,_,_,build = GetBuildInfo()
        build=tonumber(build)
        if build then return build>=20500 and build<30000 end
    end
    return WOW_PROJECT_BURNING_CRUSADE_CLASSIC ~= nil and WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
end
local function Data()
    local data = _G.UBKProspectingData
    if type(data)=="table" and data.schema==1 and data.client=="BCC" and type(data.ores)=="table" then return data end
    return nil
end
local function Definition(id)
    local fact=ORE_FACTS[id]
    if not fact then return nil end
    local data=Data()
    local imported=data and data.ores[id]
    local outputs=type(imported)=="table" and type(imported.outputs)=="table" and imported.outputs or {}
    local warning
    if type(imported)=="table" then warning=imported.warning else warning="Prospecting yields are not imported. Run the UBK installer with TSM installed for this TBC client." end
    if next(outputs)==nil then warning="Prospecting yields are not imported. Run the UBK installer with TSM installed for this TBC client." end
    local source=data and data.source or "Yield data unavailable"
    local samples,note=0,nil
    if _G.UBKProspectingLearning then outputs,warning,source,samples,note=_G.UBKProspectingLearning:Estimate(id,outputs,warning,source) end
    return {name=fact.name,skill=fact.skill,quality=fact.quality,outputs=outputs,warning=warning,source=source,samples=samples,learningNote=note}
end
local FALLBACK_NAMES = {
    [774] = "Malachite",
    [818] = "Tigerseye",
    [1206] = "Moss Agate",
    [1210] = "Shadowgem",
    [1529] = "Jade",
    [1705] = "Lesser Moonstone",
    [2770] = "Copper Ore",
    [2771] = "Tin Ore",
    [2772] = "Iron Ore",
    [3858] = "Mithril Ore",
    [3864] = "Citrine",
    [7909] = "Aquamarine",
    [7910] = "Star Ruby",
    [10620] = "Thorium Ore",
    [12361] = "Blue Sapphire",
    [12364] = "Huge Emerald",
    [12799] = "Large Opal",
    [12800] = "Azerothian Diamond",
    [21929] = "Flame Spessarite",
    [23077] = "Blood Garnet",
    [23079] = "Deep Peridot",
    [23107] = "Shadow Draenite",
    [23112] = "Golden Draenite",
    [23117] = "Azure Moonstone",
    [23424] = "Fel Iron Ore",
    [23425] = "Adamantite Ore",
    [23436] = "Living Ruby",
    [23437] = "Talasite",
    [23438] = "Star of Elune",
    [23439] = "Noble Topaz",
    [23440] = "Dawnstone",
    [23441] = "Nightseye",
}

local function Positive(value)
    return type(value) == "number" and value > 0 and value < math.huge and value or nil
end

local function Quantity(value)
    return type(value) == "number" and value >= 0 and value < math.huge and math.floor(value) or nil
end

local function ItemID(value)
    if type(value) == "number" then
        return value > 0 and value < math.huge and value == math.floor(value) and value or nil
    end
    if type(value) ~= "string" then return nil end
    return tonumber(value:match("^i:(%d+)$") or value:match("^(%d+)$") or value:match("|Hitem:(%d+):"))
end

local function SafeMethod(name, ...)
    if type(API[name]) ~= "function" then return nil end
    local ok, value = pcall(API[name], API, ...)
    return ok and value or nil
end

local function Price(source, item)
    local tsm = _G.TSM_API
    if type(tsm) ~= "table" or type(tsm.GetCustomPriceValue) ~= "function" then return nil end
    local ok, value = pcall(tsm.GetCustomPriceValue, source, item)
    return ok and Positive(value) or nil
end

local function Name(id)
    local item = "i:" .. id
    local name = SafeMethod("GetItemName", item)
    if type(name) == "string" and name ~= "" and name ~= item then return name end
    return FALLBACK_NAMES[id] or item
end

local function Round(value)
    return value and math.floor(value + 0.5) or nil
end

-- Pure evaluator used by the UI and regression tests. Owned basis, historical
-- planning costs and hypothetical new purchases are kept in separate fields.
local function Evaluate(oreID, input)
    oreID = ItemID(oreID)
    local definition = oreID and Definition(oreID)
    if not definition then return nil, "This ore is not in the TBC prospectable-ore table." end
    input = type(input) == "table" and input or {}
    local basis = Positive(input.basis)
    local recorded = Positive(input.recordedCost)
    local buyout = Positive(input.oreBuyout)
    local owned, known = Quantity(input.observedQty), Quantity(input.knownQty)
    local unresolved = Quantity(input.unresolvedQty)
    local row = {
        itemID=oreID, itemString="i:" .. oreID, name=input.name or definition.name,
        profession="Jewelcrafting", itemType="Ore", quality=definition.quality,
        requiredSkill=definition.skill, batchSize=BATCH_SIZE, outputs={},
        owned=owned, knownQty=known, unresolvedQty=unresolved,
        knownProspects=owned and known and math.floor(math.min(owned, known) / BATCH_SIZE) or nil,
        basis=basis, basisCost=basis and basis * BATCH_SIZE or nil,
        recordedCost=recorded, recordedSource=input.recordedSource,
        recordedBatchCost=recorded and recorded * BATCH_SIZE or nil,
        oreRecent=Positive(input.oreRecent), oreBuyout=buyout, buyoutCost=buyout and buyout * BATCH_SIZE or nil,
        marketTime=Positive(input.marketTime), pricedOutputs=0, outputCount=0,
        missingOutputs={}, totalExpectedGems=0, partialGrossRevenue=0,
        excludesByproducts=true, excludesFailedDeposits=true,
        yieldSource=definition.source, samples=definition.samples, learningNote=definition.learningNote,
        yieldWarning=definition.warning, yieldValidated=definition.warning == nil,
    }
    local prices = type(input.gemPrices) == "table" and input.gemPrices or {}
    local names = type(input.gemNames) == "table" and input.gemNames or {}
    for gemID, perOre in pairs(definition.outputs) do
        local count = perOre * BATCH_SIZE
        local price = Positive(prices[gemID]) or Positive(prices["i:" .. gemID])
        local output = {
            itemID=gemID, itemString="i:" .. gemID,
            name=names[gemID] or FALLBACK_NAMES[gemID] or "i:" .. gemID,
            expectedPerProspect=count, minBuyout=price,
            expectedGross=price and price * count or nil,
        }
        row.outputs[#row.outputs + 1] = output
        row.outputCount = row.outputCount + 1
        row.totalExpectedGems = row.totalExpectedGems + count
        if price then
            row.pricedOutputs = row.pricedOutputs + 1
            row.partialGrossRevenue = row.partialGrossRevenue + price * count
        else
            row.missingOutputs[#row.missingOutputs + 1] = output.name
        end
    end
    table.sort(row.outputs, function(a,b) return a.itemID < b.itemID end)
    table.sort(row.missingOutputs)
    row.completePrices = row.outputCount > 0 and row.pricedOutputs == row.outputCount
    row.priceCoverage = string.format("%d/%d", row.pricedOutputs, row.outputCount)
    if row.yieldValidated and row.completePrices and Positive(row.partialGrossRevenue) then
        row.expectedGrossRevenue = Round(row.partialGrossRevenue)
        row.expectedNetRevenue = Round(row.partialGrossRevenue * NET_AH_FACTOR)
        row.basisProfit = row.basisCost and Round(row.partialGrossRevenue * NET_AH_FACTOR - row.basisCost) or nil
        row.ownedProfit = row.knownProspects and row.knownProspects > 0 and row.basisProfit or nil
        row.recordedProfit = row.recordedBatchCost and Round(row.partialGrossRevenue * NET_AH_FACTOR - row.recordedBatchCost) or nil
        row.buyoutProfit = row.buyoutCost and Round(row.partialGrossRevenue * NET_AH_FACTOR - row.buyoutCost) or nil
        row.breakEvenOreBuyout = Round(row.partialGrossRevenue * NET_AH_FACTOR / BATCH_SIZE)
        -- Selling those same five raw ores is an alternative to prospecting.
        row.prospectVsOreSale = buyout and Round(row.partialGrossRevenue * NET_AH_FACTOR - buyout * BATCH_SIZE * NET_AH_FACTOR) or nil
    end
    row.planningBatchCost = row.basisCost or row.recordedBatchCost
    row.rankProfit = row.basisProfit or row.recordedProfit
    row.costSource = basis and "UBK basis" or (recorded and (input.recordedSource == "Recorded vendor price" and "Vendor quote" or "Buy history") or "Unavailable")
    if not row.yieldValidated then
        row.status = "Yield verification needed"
    elseif not row.completePrices then
        row.status = "Missing gem prices"
    elseif not basis then
        row.status = recorded and "History cost only" or "No trusted basis"
    elseif not owned or owned == 0 then
        row.status = "Last-basis scenario"
    elseif unresolved and unresolved > 0 then
        row.status = "Known-cost portion"
    elseif row.knownProspects and row.knownProspects == 0 then
        row.status = "Fewer than 5 costed"
    elseif row.basisProfit and row.basisProfit > 0 then
        row.status = "Expected profit"
    else
        row.status = "Expected loss"
    end
    return row
end

_G.UBKProspectingMath = {Evaluate=Evaluate, batchSize=BATCH_SIZE, version=1}

function API:GetProspectingInfo(itemArg)
    local id = ItemID(itemArg)
    if not id or not ORE_FACTS[id] then return nil, "This ore cannot be compared for TBC prospecting." end
    if not SupportedClient() then return nil,"Prospecting comparison supports TBC Anniversary only." end
    local item = "i:" .. id
    local info = SafeMethod("GetBasisInfo", item)
    info = type(info) == "table" and info or {}
    local basis = Positive(SafeMethod("GetAcquisitionCost", item))
    local recorded, recordedSource = basis, basis and "UBK acquisition basis" or nil
    if not recorded then
        recorded = Price("avgbuy", item)
        recordedSource = recorded and "TSM recorded average purchase" or nil
    end
    if not recorded then
        recorded = Price("vendorbuy", item)
        recordedSource = recorded and "Recorded vendor price" or nil
    end
    local prices, names = {}, {}
    for gemID in pairs(Definition(id).outputs) do
        prices[gemID] = Price("dbminbuyout", "i:" .. gemID)
        names[gemID] = Name(gemID)
    end
    return Evaluate(id, {
        name=Name(id), basis=basis, recordedCost=recorded, recordedSource=recordedSource,
        observedQty=info.observedQty, knownQty=info.knownQty, unresolvedQty=info.unresolvedQty,
        oreRecent=Price("dbrecent", item), oreBuyout=Price("dbminbuyout", item), gemPrices=prices, gemNames=names,
        marketTime=SafeMethod("GetMarketDataTimes"),
    })
end

function API:GetProspectingRows()
    if not SupportedClient() then return {}, {error="Prospecting comparison supports TBC Anniversary only.",batchSize=BATCH_SIZE} end
    local rows = {}
    local warnings=0
    for id in pairs(ORE_FACTS) do
        local row = self:GetProspectingInfo(id)
        if row then rows[#rows + 1] = row; if row.yieldWarning then warnings=warnings+1 end end
    end
    table.sort(rows, function(a,b)
        if a.rankProfit ~= b.rankProfit then
            if a.rankProfit == nil then return false end
            if b.rankProfit == nil then return true end
            return a.rankProfit > b.rankProfit
        end
        return a.name < b.name
    end)
    return rows, {
        batchSize=BATCH_SIZE, marketTime=SafeMethod("GetMarketDataTimes"),
        yieldSource=Data() and Data().source or "Local yield import unavailable", saleSource="DBMinBuyout",
        auctionCut=1-NET_AH_FACTOR, excludesByproducts=true, yieldWarnings=warnings,
        excludedRevenue="Dust, powder, and all other byproducts; no gem cuts.",
        note="Expected values over many prospects. Loaded buyouts are not live stock or guaranteed sales. Failed auction deposits are excluded.",
    }
end
