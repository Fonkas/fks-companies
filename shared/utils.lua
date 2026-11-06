---------------------------------------------------------------------------
-- Shared helpers: money formatting, rounding, text cleaning, blip catalogue lookups.
---------------------------------------------------------------------------
Co = {}

-- 2 decimal places, never NaN / inf (nil when it is not a number)
function Co.Money(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return math.floor(v * 100 + 0.5) / 100
end

-- "$1,250" / "$12.50"
function Co.Fmt(n)
    n = tonumber(n) or 0
    local neg = n < 0
    n = math.abs(n)
    local int = math.floor(n)
    local cents = math.floor((n - int) * 100 + 0.5)
    if cents >= 100 then int, cents = int + 1, 0 end
    local s = tostring(int):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    if cents > 0 then s = ('%s.%02d'):format(s, cents) end
    return (neg and '-$' or '$') .. s
end

-- trims, collapses spaces, strips control chars and markup; nil when empty / too short
function Co.Text(v, max, min)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('[%c<>]', ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if max and #v > max then v = v:sub(1, max) end
    if #v < (min or 1) then return nil end
    return v
end

-- 'YYYY-MM-DD HH:MM'
function Co.Date(t)
    if not t then return '-' end
    return os.date('%Y-%m-%d %H:%M', math.floor(tonumber(t) or 0))
end

-- an interval in minutes as words: "1 day", "6 hours", "45 minutes"
function Co.Every(min)
    min = math.floor(tonumber(min) or 60)
    if min == 1440 then return _L('every_day') end
    if min % 1440 == 0 then return _L('every_days', math.floor(min / 1440)) end
    if min % 60 == 0 then return _L('every_hours', math.floor(min / 60)) end
    return _L('every_minutes', min)
end

---------------------------------------------------------------------------
-- Blip catalogue (shared/blips.lua)
---------------------------------------------------------------------------
Co.BlipByHash, Co.BlipByName = {}, {}
for _, b in ipairs(BlipCatalogue or {}) do
    Co.BlipByHash[b.hash] = b
    Co.BlipByName[b.name] = b
end

local function blipKey(v)
    if type(v) == 'number' then return Co.BlipByHash[v] end
    if type(v) == 'string' then return Co.BlipByName[v] or Co.BlipByHash[tonumber(v) or 0] end
end

-- is this blip offered to players? (Config.Blips.allowed / disabled)
local allowedSet, disabledSet
function Co.BlipAllowed(hash)
    local b = Co.BlipByHash[tonumber(hash) or 0]
    if not b then return false end
    if not disabledSet then
        disabledSet, allowedSet = {}, nil
        for _, v in ipairs(Config.Blips.disabled or {}) do
            local e = blipKey(v)
            if e then disabledSet[e.hash] = true end
        end
        if type(Config.Blips.allowed) == 'table' then
            allowedSet = {}
            for _, v in ipairs(Config.Blips.allowed) do
                local e = blipKey(v)
                if e then allowedSet[e.hash] = true end
            end
        end
    end
    if disabledSet[b.hash] then return false end
    if allowedSet and not allowedSet[b.hash] then return false end
    return true
end

function Co.BlipImage(name)
    local cfg = Config.BlipImages
    local path = cfg[cfg.source] or cfg.remote
    return (path:gsub('{name}', name))
end

---------------------------------------------------------------------------
-- Config validation: wrong values fall back to safe defaults (with a console warning)
---------------------------------------------------------------------------
local function Warn(path, value, default)
    print(('^3[fks-companies] config %s = %s is not valid, using %s^0'):format(path, tostring(value), tostring(default)))
end

local function OneOf(tbl, key, path, list, default)
    for _, v in ipairs(list) do if tbl[key] == v then return end end
    Warn(path, tbl[key], default)
    tbl[key] = default
end

local function Positive(tbl, key, path, default, allowZero)
    local v = tonumber(tbl[key])
    if not v or v ~= v or v < 0 or (v == 0 and not allowZero) then
        Warn(path, tbl[key], default)
        tbl[key] = default
    else
        tbl[key] = v
    end
end

do
    local C = Config
    OneOf(C.Taxes, 'failPolicy', 'Taxes.failPolicy', { 'skip', 'partial', 'suspend' }, 'skip')
    OneOf(C.Marketplace, 'PreviousOwner', 'Marketplace.PreviousOwner', { 'dismiss', 'demote' }, 'dismiss')
    OneOf(C.Marketplace, 'FinancialPrivacy', 'Marketplace.FinancialPrivacy', { 'none', 'balance', 'full' }, 'balance')
    OneOf(C.Marketplace, 'OfflinePayment', 'Marketplace.OfflinePayment', { 'database', 'login' }, 'database')
    OneOf(C.BlipImages, 'source', 'BlipImages.source', { 'remote', 'local' }, 'remote')
    Positive(C.Duty, 'maxDistance', 'Duty.maxDistance', 200.0)
    Positive(C.Duty, 'checkInterval', 'Duty.checkInterval', 10)
    Positive(C.Billing, 'expiration', 'Billing.expiration', 60)
    Positive(C.Contracts, 'expiration', 'Contracts.expiration', 120)
    Positive(C.Finance, 'maxTransaction', 'Finance.maxTransaction', 1000000)
    Positive(C.Finance, 'historyPageSize', 'Finance.historyPageSize', 25)
    Positive(C.Taxes, 'minInterval', 'Taxes.minInterval', 10)
    Positive(C.Placement, 'maxDistance', 'Placement.maxDistance', 40.0)
    Positive(C.Store, 'MaxProductsPerCompany', 'Store.MaxProductsPerCompany', 100)
    Positive(C.Store, 'MaxPurchaseQuantity', 'Store.MaxPurchaseQuantity', 100)
    Positive(C.Store, 'MaxStockPerProduct', 'Store.MaxStockPerProduct', 10000)
    Positive(C.Identity.nameChange, 'price', 'Identity.nameChange.price', 0, true)
    Positive(C.Identity.blipChange, 'price', 'Identity.blipChange.price', 0, true)
    Positive(C.Marketplace, 'MinPrice', 'Marketplace.MinPrice', 100)
    if C.Marketplace.MaxPrice < C.Marketplace.MinPrice then Warn('Marketplace.MaxPrice', C.Marketplace.MaxPrice, C.Marketplace.MinPrice * 100) C.Marketplace.MaxPrice = C.Marketplace.MinPrice * 100 end
    if not Co.BlipByHash[C.Creation.defaultBlip] then Warn('Creation.defaultBlip', C.Creation.defaultBlip, 819673798) C.Creation.defaultBlip = 819673798 end
    -- the marketplace and the stores always use cash on hand
    C.MoneyAccount, C.Marketplace.SellerPaymentAccount, C.Store.PaymentMethod = 'cash', 'cash', 'cash'
end
