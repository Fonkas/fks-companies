---------------------------------------------------------------------------
-- Company store (customer side): product grid with the cart on the side, drawn by fks-core with the fco-shop
-- component. Nothing is bought until "Confirm purchase", and the server checks everything again (store open,
-- stock, prices, cash on hand, inventory space).
---------------------------------------------------------------------------
Store = {}

local S = nil            -- { id, name, products, cash, maxQty, ... } from store:open

local LABELS = {
    search = _L('store_search_ph'), cart = _L('cart'), total = _L('total'), cash = _L('your_cash'), buy = _L('confirm_purchase'),
    note = _L('cash_only'), add = _L('add_to_cart'), stock = _L('in_stock', '%d'), soldOut = _L('sold_out'), remove = _L('remove'),
    cartEmpty = _L('cart_is_empty'), units = _L('n_units', '%d'), noCash = _L('not_enough_cash_note'), empty = _L('store_empty'),
    noResults = _L('no_results'), confirmTitle = _L('confirm_purchase'), confirmText = _L('checkout_text', '%s', '%d'),
    pay = _L('pay'), cancel = _L('cancel'), adjusted = _L('cart_adjusted'),
}

---------------------------------------------------------------------------
-- One page: products on the left, the cart on the right (fco-shop in ui/documents.js keeps the cart)
---------------------------------------------------------------------------
local function View()
    return {
        eyebrow = _L('store'), title = S.name, layout = 'wide', page = 'shop',
        pages = { shop = {
            desc = S.description or _L('store_welcome'),
            body = { { type = 'fco-shop', id = 'shop', products = S.products, cash = S.cash, maxQty = S.maxQty, action = 's:checkout', labels = LABELS } },
        } },
        footer = { main = false, money = { cash = S.cash } }, hints = { { 'ESC', _L('close') } },
    }
end

---------------------------------------------------------------------------
-- Checkout: the cart comes from the NUI; the server checks everything again (prices, stock, cash, space)
---------------------------------------------------------------------------
UI.On('s:checkout', function(d)
    if not S then return end
    local list = {}
    for _, l in ipairs(type(d.value) == 'table' and d.value or {}) do
        local qty = math.floor(tonumber(l.qty) or 0)
        if type(l.item) == 'string' and qty > 0 then list[#list + 1] = { item = l.item, qty = qty, price = tonumber(l.price) } end
    end
    if #list == 0 then return { ok = false, error = _L('cart_empty') } end
    local ok, msg, products, cash = Call('store:buy', S.id, list)
    -- refused: the cart stays as it is so the player can fix it
    if not ok then return { ok = false, error = msg } end
    PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0)
    if products then S.products = products end
    if cash then S.cash = cash end
    return { toast = { text = msg, type = 'success' }, view = View() }
end)

---------------------------------------------------------------------------
-- Live updates from the server
---------------------------------------------------------------------------
RegisterNetEvent('fks-companies:client:storeStock', function(id, products)
    if not S or S.id ~= id or ActiveView ~= 'store' then return end
    S.products = products
    -- the component keeps the cart and trims it to the new stock (it tells the player)
    UI.Patch('shop', { products = products })
end)

RegisterNetEvent('fks-companies:client:storeClosed', function(id)
    if not S or S.id ~= id then return end
    if ActiveView == 'store' then UI.Close() end
    Notify(_L('store_now_closed'), 'warning')
end)

OnUIClose(function()
    if S then TriggerServerEvent('fks-companies:server:storeLeave', S.id) end
    S = nil
end)

function Store.Open(id)
    local ok, data = Call('store:open', id)
    if not ok then return Notify(data, 'error') end
    S = data
    if not OpenView('store', View()) then S = nil return end
    PlaySoundFrontend('INFO', 'HUD_SHOP_SOUNDSET', true, 0)
    local c = Companies[id]
    local l = c and c.locations.store
    if l then CloseWhenAway(vector3(l.x, l.y, l.z), Config.Interact.distance + 3.0, function() return ActiveView == 'store' and S ~= nil end) end
end

-- the store closed while browsing (someone went on duty, suspended...) - also covered by storeClosed
OnCompanyChange(function(id, c)
    if S and S.id == id and ActiveView == 'store' and (not c or not c.store.open) then
        UI.Close()
        Notify(_L('store_now_closed'), 'warning')
    end
end)
