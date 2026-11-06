---------------------------------------------------------------------------
-- Company marketplace: owners (or admins) list a company, players buy it with cash on hand.
--
-- Buying runs inside the company lock, so two buyers can never both get it: the first one sets the
-- listing to 'pending', the second one finds it is no longer for sale. The seller is paid in cash on hand
-- through fks_company_payouts (one row per sale, unique): straight away when online, in the framework's
-- table when offline (Config.Marketplace.OfflinePayment = 'database' and the account is not connected),
-- or on their next character load. A payout row is claimed (pending -> paid) before any money moves.
---------------------------------------------------------------------------
local M = Config.Marketplace

-- status: 'not_for_sale' | 'for_sale' | 'pending' | 'sold'
function SetSale(c, d)
    local s = c.sale
    if d.status then s.status = d.status end
    if d.price then s.price = d.price end
    if d.negotiable ~= nil then s.negotiable = d.negotiable end
    if d.public ~= nil then s.public = d.public end
    if d.seller ~= nil then s.seller = d.seller or nil end
    s.listedAt = s.status == 'for_sale' and (d.listedAt or s.listedAt or os.time()) or nil
    MySQL.update.await([[UPDATE fks_companies SET sale_status = ?, sale_price = ?, sale_negotiable = ?, sale_public = ?, sale_seller_cid = ?, sale_listed_at = ?
        WHERE id = ?]], { s.status, s.price, s.negotiable and 1 or 0, s.public and 1 or 0, s.seller, s.listedAt, c.id })
    Sync(c)
end

---------------------------------------------------------------------------
-- Owner lists / cancels
---------------------------------------------------------------------------
Callback('sale:list', function(src, P, companyId, price)
    if not M.Enabled or not M.AllowPlayerSales then return false, _L('feature_disabled') end
    local c, cid = Access(src, P, companyId, { boss = true })
    if not c then return false, cid end
    price = Co.Money(price)
    if not price or price < M.MinPrice or price > M.MaxPrice then return false, _L('invalid_price_range', Co.Fmt(M.MinPrice), Co.Fmt(M.MaxPrice)) end
    return WithLock(Finance.Key(c), function()
        if c.sale.status == 'for_sale' or c.sale.status == 'pending' then return false, _L('already_listed') end
        SetSale(c, { status = 'for_sale', price = price, seller = cid, public = true, negotiable = M.AllowNegotiation, listedAt = os.time() })
        DB.Activity(c.id, 'sale_list', Actor(P), _L('act_sale_list', P.name, Co.Fmt(price)))
        return true, _L('listed', Co.Fmt(price))
    end)
end)

Callback('sale:cancel', function(src, P, companyId)
    local c, cid = Access(src, P, companyId, { boss = true })
    if not c then return false, cid end
    return WithLock(Finance.Key(c), function()
        if c.sale.status ~= 'for_sale' then return false, _L('not_listed') end
        if c.sale.seller ~= cid then return false, _L('listed_by_admin') end
        SetSale(c, { status = 'not_for_sale', seller = false })
        DB.Activity(c.id, 'sale_cancel', Actor(P), _L('act_sale_cancel', P.name))
        return true, _L('listing_cancelled')
    end)
end)

---------------------------------------------------------------------------
-- Browsing
---------------------------------------------------------------------------
local function Listing(c, me)
    local loc = c.coords
    local item = {
        id = c.id, name = c.name, code = c.code, blip = c.blip, price = c.sale.price, negotiable = c.sale.negotiable and M.AllowNegotiation,
        description = c.description, employees = EmployeeCount(c), coords = { x = loc.x, y = loc.y, z = loc.z },
        owner = c.owner and c.owner.name or nil, mine = me and c.owner and c.owner.cid == me or false,
        store = c.store.enabled, listedAt = Co.Date(c.sale.listedAt),
    }
    local privacy = M.FinancialPrivacy
    if privacy == 'balance' or privacy == 'full' then item.balance = c.balance end
    if privacy == 'full' then item.income, item.expenses = c.income, c.expenses end
    return item
end

-- public listings for the marketplace window; `at` = one company (non-public listings are only shown at it)
Callback('market:list', function(src, P, at)
    if not M.Enabled then return false, _L('feature_disabled') end
    local list = {}
    local cid = tostring(P.cid)
    for _, c in pairs(Companies) do
        if IsActive(c) and c.sale.status == 'for_sale' and (c.sale.public or c.id == tonumber(at)) then
            if not at or c.id == tonumber(at) then list[#list + 1] = Listing(c, cid) end
        end
    end
    table.sort(list, function(a, b) return a.price < b.price end)
    return true, list, P.money('cash'), EmployeeOf[cid]
end, { noLimit = true })

---------------------------------------------------------------------------
-- Payouts
---------------------------------------------------------------------------
-- claims the payout row; returns true only for the one caller that changed it from pending
local function Claim(id, method)
    local n = MySQL.update.await("UPDATE fks_company_payouts SET status = 'paid', method = ?, paid_at = ? WHERE id = ? AND status = 'pending'",
        { method, os.time(), id })
    return (n or 0) == 1
end

local function Unclaim(id)
    MySQL.update.await("UPDATE fks_company_payouts SET status = 'pending', method = NULL, paid_at = NULL WHERE id = ?", { id })
end

function PayOut(row)
    local cid = tostring(row.seller_cid)
    local amount = Co.Money(row.amount)
    local src, P = Framework.Online(cid)
    if src and P then
        if not Claim(row.id, 'online') then return false end
        if not P.add('cash', amount, 'fks-companies company sale') then Unclaim(row.id) return false end
        Notify(src, _L('sale_payout', Co.Fmt(amount), row.company_name or ''), 'success')
        return true
    end
    if M.OfflinePayment ~= 'database' then return false end           -- paid on next login
    local connected, exists = Framework.AccountOnline(cid)
    if connected or not exists then return false end                  -- in the character screen: paid on load
    if not Claim(row.id, 'offline') then return false end
    if not Framework.AddOfflineCash(cid, amount) then Unclaim(row.id) return false end
    Debug('offline payout %s to %s', amount, cid)
    return true
end

local function PendingFor(cid)
    return MySQL.query.await([[SELECT p.*, s.company_name FROM fks_company_payouts p
        LEFT JOIN fks_company_sales s ON s.id = p.sale_id WHERE p.seller_cid = ? AND p.status = 'pending']], { cid }) or {}
end

AddEventHandler('fks-companies:server:characterLoaded', function(_, cid)
    for _, row in ipairs(PendingFor(cid)) do PayOut(row) end
end)

-- retry anything still pending (a crash between steps, a failed offline write)
CreateThread(function()
    while not Loaded do Wait(500) end
    while true do
        for _, row in ipairs(MySQL.query.await([[SELECT p.*, s.company_name FROM fks_company_payouts p
            LEFT JOIN fks_company_sales s ON s.id = p.sale_id WHERE p.status = 'pending' LIMIT 50]]) or {}) do
            PayOut(row)
        end
        Wait(300000)
    end
end)

---------------------------------------------------------------------------
-- Buying
---------------------------------------------------------------------------
Callback('market:buy', function(src, P, companyId, expectedPrice)
    if not M.Enabled then return false, _L('feature_disabled') end
    local c = Company(companyId)
    if not c then return false, _L('company_unknown') end
    local cid = tostring(P.cid)

    local ok, msg, payout = WithLock(Finance.Key(c), function()
        if not IsActive(c) or c.sale.status ~= 'for_sale' then return false, _L('not_for_sale') end
        if not c.sale.public and not Near(src, c.coords, 15.0) then return false, _L('too_far') end
        local price = c.sale.price
        if Co.Money(expectedPrice) ~= price then return false, _L('price_changed', Co.Fmt(price)) end
        if c.owner and c.owner.cid == cid then return false, _L('own_company') end
        if EmployeeOf[cid] and EmployeeOf[cid] ~= c.id then return false, _L('buyer_employed') end
        if P.money('cash') + 0.0001 < price then return false, _L('not_enough_cash') end

        c.sale.status = 'pending'                                       -- nobody else can start now
        if not P.remove('cash', price, 'fks-companies company purchase') then
            c.sale.status = 'for_sale'
            return false, _L('not_enough_cash')
        end

        local seller = c.sale.seller
        local sellerName = seller and c.owner and c.owner.cid == seller and c.owner.name or (seller and Framework.OfflineName(seller)) or nil
        local now = os.time()
        local saleId = MySQL.insert.await([[INSERT INTO fks_company_sales (company_id, company_name, seller_cid, seller_name, buyer_cid, buyer_name, price, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)]], { c.id, c.name, seller, sellerName, cid, P.name, price, now })
        if not saleId then
            P.add('cash', price, 'fks-companies purchase refund')
            c.sale.status = 'for_sale'
            return false, _L('error')
        end
        local payoutRow
        if seller then
            local pid = MySQL.insert.await("INSERT INTO fks_company_payouts (sale_id, company_id, seller_cid, amount, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?)",
                { saleId, c.id, seller, price, now })
            payoutRow = { id = pid, seller_cid = seller, amount = price, company_name = c.name }
        end

        -- ownership: the buyer becomes the Boss, the old Boss loses it (Config.Marketplace.PreviousOwner)
        local owned, err = SetOwner(c, Actor(P), 'sale')
        if not owned then
            -- should not happen (checked above): undo everything
            MySQL.update.await('DELETE FROM fks_company_payouts WHERE sale_id = ?', { saleId })
            MySQL.update.await('DELETE FROM fks_company_sales WHERE id = ?', { saleId })
            P.add('cash', price, 'fks-companies purchase refund')
            c.sale.status = 'for_sale'
            return false, err
        end
        SetSale(c, { status = 'sold', seller = false })
        DB.Activity(c.id, 'sold', Actor(P), _L('act_sold', c.name, P.name, Co.Fmt(price), sellerName or _L('administration')))
        DB.AdminLog(src, c.id, c.name, 'market_sale', ('buyer=%s seller=%s price=%s'):format(P.name, sellerName or '-', price))
        return true, _L('bought_company', c.name, Co.Fmt(price)), payoutRow
    end)

    if ok and payout then CreateThread(function() PayOut(payout) end) end
    return ok, msg
end)
