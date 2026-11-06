---------------------------------------------------------------------------
-- Company stores: employees put items from their own inventory on sale, customers buy them at the NPC
-- while nobody is on duty.
--
-- Checkout (inside the company lock):
--   1. validate everything (store open, products, prices, stock, cash, carry capacity)
--   2. take the cash
--   3. ONE database transaction: stock, sale + lines, company balance + ledger
--   4. give the items; if one fails, everything is undone (items taken back, cash refunded, stock and
--      balance restored, sale marked rolled_back)
-- Items never reach the customer before step 3 succeeded.
---------------------------------------------------------------------------
local S = Config.Store
local Viewers = {}       -- [companyId] = { [src] = true } customers with the store window open

local function Products(c)
    local list = {}
    for _, p in pairs(c.products) do
        if not p.img then p.img = Framework.ItemImage(p.item) end
        list[#list + 1] = { item = p.item, label = p.label, quantity = p.quantity, price = p.price, description = p.description, img = p.img,
                            listedBy = p.listedBy }
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    return list
end

-- customers looking at this store get the new stock / prices
local function PushStock(c)
    local v = Viewers[c.id]
    if not v or not next(v) then return end
    local list = Products(c)
    for src in pairs(v) do TriggerClientEvent('fks-companies:client:storeStock', src, c.id, list) end
end

function StoreClosedForViewers(c)
    local v = Viewers[c.id]
    if not v or StoreOpen(c) then return end
    for src in pairs(v) do TriggerClientEvent('fks-companies:client:storeClosed', src, c.id) end
    Viewers[c.id] = nil
end

AddEventHandler('playerDropped', function()
    local src = source
    for _, v in pairs(Viewers) do v[src] = nil end
end)

---------------------------------------------------------------------------
-- Settings (owner / manage_store)
---------------------------------------------------------------------------
Callback('store:settings', function(src, P, companyId, d)
    if not S.Enabled then return false, _L('feature_disabled') end
    local c, err = Access(src, P, companyId, { perm = 'manage_store' })
    if not c then return false, err end
    d = type(d) == 'table' and d or {}
    if d.enabled ~= nil then
        c.store.enabled = d.enabled == true
        MySQL.update.await('UPDATE fks_companies SET store_enabled = ? WHERE id = ?', { c.store.enabled and 1 or 0, c.id })
        DB.Activity(c.id, 'store', Actor(P), _L(c.store.enabled and 'act_store_on' or 'act_store_off', P.name))
    end
    if d.model then
        local valid = false
        for _, m in ipairs(S.Models) do if m == d.model then valid = true end end
        if not valid then return false, _L('invalid_model') end
        c.store.model = d.model
        MySQL.update.await('UPDATE fks_companies SET store_model = ? WHERE id = ?', { d.model, c.id })
        if c.locations.store then
            c.locations.store.model = d.model
            MySQL.update('UPDATE fks_company_locations SET model = ? WHERE company_id = ? AND kind = \'store\'', { d.model, c.id })
        end
    end
    Sync(c)
    StoreClosedForViewers(c)
    return true, _L('saved')
end)

---------------------------------------------------------------------------
-- Stock management (manage_store_inventory)
---------------------------------------------------------------------------
Callback('store:manage', function(src, P, companyId)
    local c, err = Access(src, P, companyId, { perm = 'manage_store_inventory' })
    if not c then return false, err end
    local count = 0
    for _ in pairs(c.products) do count = count + 1 end
    return true, { products = Products(c), inventory = Framework.InventoryItems(src), max = S.MaxProductsPerCompany, count = count,
                   allowPrice = S.AllowPriceChanges, allowWithdraw = S.AllowStockWithdrawal, minPrice = S.MinPrice, maxPrice = S.MaxPrice }
end, { noLimit = true })

local function Price(v)
    local n = Co.Money(v)
    if not n or n < S.MinPrice or n > S.MaxPrice then return nil end
    return n
end

-- puts `qty` of `item` from the employee's inventory into the store (new product or more stock)
Callback('store:add', function(src, P, companyId, item, qty, price)
    if not S.Enabled then return false, _L('feature_disabled') end
    local c, err = Access(src, P, companyId, { perm = 'manage_store_inventory' })
    if not c then return false, err end
    if type(item) ~= 'string' or #item > 80 or Framework.Blacklisted(item) then return false, _L('item_blacklisted') end
    if not Bridge.ItemExists(item) then return false, _L('item_unknown') end
    qty = math.floor(tonumber(qty) or 0)
    if qty < 1 or qty > S.MaxStockPerProduct then return false, _L('invalid_amount') end

    return WithLock(Finance.Key(c), function()
        local p = c.products[item]
        local count = 0
        for _ in pairs(c.products) do count = count + 1 end
        if not p and count >= S.MaxProductsPerCompany then return false, _L('store_full', S.MaxProductsPerCompany) end
        local newPrice = Price(price)
        if not p and not newPrice then return false, _L('invalid_price_range', Co.Fmt(S.MinPrice), Co.Fmt(S.MaxPrice)) end
        if p and (not S.AllowPriceChanges or not newPrice) then newPrice = p.price end
        if p and p.quantity + qty > S.MaxStockPerProduct then return false, _L('stock_limit', S.MaxStockPerProduct) end
        if Bridge.ItemCount(src, item) < qty then return false, _L('not_enough_items') end
        if not Bridge.RemoveItem(src, item, qty) then return false, _L('not_enough_items') end

        local label = Bridge.ItemLabel(item)
        local now = os.time()
        local ok = pcall(MySQL.insert.await, [[INSERT INTO fks_company_products (company_id, item, label, quantity, price, listed_by_cid, listed_by_name, listed_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE quantity = quantity + VALUES(quantity), price = VALUES(price), updated_at = VALUES(updated_at)]],
            { c.id, item, label, qty, newPrice, tostring(P.cid), P.name, now, now })
        if not ok then
            Bridge.AddItem(src, item, qty)                              -- give the items back
            return false, _L('error')
        end
        if p then
            p.quantity, p.price = p.quantity + qty, newPrice
        else
            local id = MySQL.scalar.await('SELECT id FROM fks_company_products WHERE company_id = ? AND item = ?', { c.id, item })
            c.products[item] = { id = id, item = item, label = label, quantity = qty, price = newPrice, listedBy = P.name, listedAt = now }
        end
        DB.Activity(c.id, 'stock_add', Actor(P), _L('act_stock_add', P.name, qty, label, Co.Fmt(newPrice)))
        PushStock(c)
        return true, _L('stock_added', qty, label)
    end)
end)

Callback('store:price', function(src, P, companyId, item, price)
    if not S.AllowPriceChanges then return false, _L('feature_disabled') end
    local c, err = Access(src, P, companyId, { perm = 'manage_store_inventory' })
    if not c then return false, err end
    local newPrice = Price(price)
    if not newPrice then return false, _L('invalid_price_range', Co.Fmt(S.MinPrice), Co.Fmt(S.MaxPrice)) end
    return WithLock(Finance.Key(c), function()
        local p = c.products[item]
        if not p then return false, _L('product_unknown') end
        MySQL.update.await('UPDATE fks_company_products SET price = ?, updated_at = ? WHERE id = ?', { newPrice, os.time(), p.id })
        DB.Activity(c.id, 'price', Actor(P), _L('act_price', P.name, p.label, Co.Fmt(p.price), Co.Fmt(newPrice)))
        p.price = newPrice
        PushStock(c)
        return true, _L('price_set', p.label, Co.Fmt(newPrice))
    end)
end)

-- takes unsold units back into the employee's inventory; qty = 'all' removes the product
Callback('store:withdraw', function(src, P, companyId, item, qty)
    if not S.AllowStockWithdrawal then return false, _L('feature_disabled') end
    local c, err = Access(src, P, companyId, { perm = 'manage_store_inventory' })
    if not c then return false, err end
    return WithLock(Finance.Key(c), function()
        local p = c.products[item]
        if not p then return false, _L('product_unknown') end
        local n = qty == 'all' and p.quantity or math.floor(tonumber(qty) or 0)
        if n < 0 or n > p.quantity then return false, _L('invalid_amount') end
        if n > 0 and not Bridge.CanCarry(src, item, n) then return false, _L('inventory_full') end
        local left = p.quantity - n
        local remove = qty == 'all'
        -- items first: if the inventory refuses them nothing else changed
        if n > 0 and not Bridge.AddItem(src, item, n) then return false, _L('inventory_full') end
        local ok = pcall(function()
            if remove then
                MySQL.update.await('DELETE FROM fks_company_products WHERE id = ?', { p.id })
            else
                MySQL.update.await('UPDATE fks_company_products SET quantity = ?, updated_at = ? WHERE id = ?', { left, os.time(), p.id })
            end
        end)
        if not ok then
            if n > 0 then Bridge.RemoveItem(src, item, n) end
            return false, _L('error')
        end
        if remove then c.products[item] = nil else p.quantity = left end
        DB.Activity(c.id, 'stock_remove', Actor(P), _L('act_stock_remove', P.name, n, p.label))
        PushStock(c)
        return true, n > 0 and _L('stock_withdrawn', n, p.label) or _L('product_removed', p.label)
    end)
end)

---------------------------------------------------------------------------
-- Customers
---------------------------------------------------------------------------
local function AtStore(src, c)
    local l = c.locations.store
    return l and Near(src, l, Config.Interact.distance + 3.0)
end

Callback('store:open', function(src, P, companyId)
    local c = Company(companyId)
    if not c or not StoreOpen(c) then return false, _L('store_closed') end
    if not AtStore(src, c) then return false, _L('too_far') end
    Viewers[c.id] = Viewers[c.id] or {}
    Viewers[c.id][src] = true
    return true, { id = c.id, name = c.name, code = c.code, blip = c.blip, description = c.description, products = Products(c),
                   cash = P.money('cash'), maxQty = S.MaxPurchaseQuantity, blipImg = Co.BlipByHash[c.blip] and Co.BlipImage(Co.BlipByHash[c.blip].name) or nil }
end, { noLimit = true })

RegisterNetEvent('fks-companies:server:storeLeave', function(id)
    local v = Viewers[tonumber(id) or -1]
    if v then v[source] = nil end
end)

--[[ cart = { { item = 'apple', qty = 3, price = 2.0 }, ... } (price = what the customer saw) ]]
Callback('store:buy', function(src, P, companyId, cart)
    local c = Company(companyId)
    if not c then return false, _L('company_unknown') end
    if type(cart) ~= 'table' or #cart == 0 or #cart > 50 then return false, _L('cart_empty') end

    return WithLock(Finance.Key(c), function()
        -- 1. validation
        if not IsActive(c) then return false, _L('company_inactive') end
        if not StoreOpen(c) then return false, _L('store_closed') end
        if not AtStore(src, c) then return false, _L('too_far') end
        local lines, total, seen = {}, 0, {}
        for _, l in ipairs(cart) do
            local item = type(l) == 'table' and l.item
            local qty = math.floor(tonumber(type(l) == 'table' and l.qty) or 0)
            local p = type(item) == 'string' and c.products[item]
            if not p then return false, _L('product_gone') end
            if seen[item] then return false, _L('error') end
            seen[item] = true
            if qty < 1 or qty > S.MaxPurchaseQuantity then return false, _L('invalid_amount') end
            if qty > p.quantity then return false, _L('not_enough_stock', p.label, p.quantity) end
            if Co.Money(l.price) ~= p.price then return false, _L('price_changed_item', p.label, Co.Fmt(p.price)) end
            lines[#lines + 1] = { p = p, qty = qty, price = p.price, sub = Co.Money(p.price * qty) }
            total = Co.Money(total + p.price * qty)
        end
        if total <= 0 then return false, _L('cart_empty') end
        if P.money('cash') + 0.0001 < total then return false, _L('not_enough_cash') end
        for _, l in ipairs(lines) do
            if not Bridge.CanCarry(src, l.p.item, l.qty) then return false, _L('cant_carry', l.p.label) end
        end

        -- 2. cash
        if not P.remove('cash', total, 'fks-companies store') then return false, _L('not_enough_cash') end

        -- 3. one transaction: stock + sale + lines + balance + ledger
        local saleId = MySQL.insert.await("INSERT INTO fks_company_store_sales (company_id, customer_cid, customer_name, total, status, created_at) VALUES (?, ?, ?, ?, 'completed', ?)",
            { c.id, tostring(P.cid), P.name, total, os.time() })
        if not saleId then
            P.add('cash', total, 'fks-companies store refund')
            return false, _L('error')
        end
        local extra, names = {}, {}
        for _, l in ipairs(lines) do
            extra[#extra + 1] = { query = 'UPDATE fks_company_products SET quantity = quantity - ?, updated_at = ? WHERE id = ?', values = { l.qty, os.time(), l.p.id } }
            extra[#extra + 1] = { query = 'INSERT INTO fks_company_store_sale_items (sale_id, item, label, quantity, price) VALUES (?, ?, ?, ?, ?)',
                                  values = { saleId, l.p.item, l.p.label, l.qty, l.price } }
            names[#names + 1] = ('%dx %s'):format(l.qty, l.p.label)
        end
        local desc = _L('tx_store_desc', P.name, table.concat(names, ', ')):sub(1, 255)
        local ok = Finance.Apply(c, total, 'store', { cid = tostring(P.cid), name = P.name }, desc, extra)
        if not ok then
            MySQL.update('DELETE FROM fks_company_store_sales WHERE id = ?', { saleId })
            P.add('cash', total, 'fks-companies store refund')
            return false, _L('error')
        end
        for _, l in ipairs(lines) do l.p.quantity = l.p.quantity - l.qty end

        -- 4. items (compensate on failure)
        local given = {}
        for _, l in ipairs(lines) do
            if Bridge.AddItem(src, l.p.item, l.qty) then
                given[#given + 1] = l
            else
                for _, g in ipairs(given) do Bridge.RemoveItem(src, g.p.item, g.qty) end
                local back = {}
                for _, r in ipairs(lines) do
                    r.p.quantity = r.p.quantity + r.qty
                    back[#back + 1] = { query = 'UPDATE fks_company_products SET quantity = quantity + ? WHERE id = ?', values = { r.qty, r.p.id } }
                end
                back[#back + 1] = { query = "UPDATE fks_company_store_sales SET status = 'rolled_back' WHERE id = ?", values = { saleId } }
                Finance.Apply(c, -total, 'refund', { cid = tostring(P.cid), name = P.name }, _L('tx_store_rollback', P.name), back)
                P.add('cash', total, 'fks-companies store refund')
                PushStock(c)
                return false, _L('cant_carry', l.p.label)
            end
        end

        DB.Activity(c.id, 'store_sale', { cid = tostring(P.cid), name = P.name }, _L('act_store_sale', P.name, Co.Fmt(total)))
        PushStock(c)
        return true, _L('purchase_done', Co.Fmt(total)), Products(c), P.money('cash')
    end)
end)
