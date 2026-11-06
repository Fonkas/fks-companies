---------------------------------------------------------------------------
-- Customization tab of the company window: points (storages, register, store NPC) with the placement
-- tool, identity (name / blip gallery) and the store (settings, products from the employee's inventory).
---------------------------------------------------------------------------
local M = Management
local P = function(perm) return M.P(perm) end
local function D() return M.D end
local Fmt = Co.Fmt

local store = nil        -- last store:manage answer

function M.CustomAllowed()
    return P('manage_customization') or P('manage_storage_locations') or P('manage_register') or P('change_name') or P('change_blip')
        or P('manage_store') or P('manage_store_inventory')
end

---------------------------------------------------------------------------
-- Main customization page
---------------------------------------------------------------------------
local LOCS = {
    { kind = 'boss_storage', perm = 'manage_storage_locations', icon = 'lock' },
    { kind = 'general_storage', perm = 'manage_storage_locations', icon = 'box' },
    { kind = 'register', perm = 'manage_register', icon = 'coin' },
}

local function Models(kind)
    local list = {}
    for _, m in ipairs(Config.Props[kind] or {}) do
        if ValidModel(m) then list[#list + 1] = { value = m, label = m } end
    end
    return list
end

local function CustomPage()
    local d = D()
    local body = {}
    local locs = {}
    for _, l in ipairs(LOCS) do
        if P(l.perm) then
            local placed = d.locations[l.kind]
            local models = Models(l.kind)
            locs[#locs + 1] = {
                value = l.kind, icon = l.icon, label = _L('loc_' .. l.kind), sub = placed and _L('move_it') or _L('not_placed'), warn = not placed,
                action = 'm:place',
                prompt = #models > 1 and { title = _L('loc_' .. l.kind), text = _L('choose_prop'),
                    fields = { { type = 'fco-select', name = 'model', label = _L('prop'), options = models, value = placed and placed.model or models[1].value } } } or nil,
            }
        end
    end
    if #locs > 0 then
        body[#body + 1] = { type = 'section', label = _L('locations') }
        body[#body + 1] = { type = 'medals', size = 'normal', cols = 3, items = MenuIcons(locs) }
        body[#body + 1] = { type = 'text', style = 'note', text = _L('locations_note', math.floor(Config.Placement.maxDistance)) }
    end

    local id = {}
    local N, B = Config.Identity.nameChange, Config.Identity.blipChange
    if P('change_name') and N.enabled then
        id[#id + 1] = { value = 'name', icon = 'quill', label = _L('change_name'), sub = Fmt(N.price), action = 'm:rename',
            prompt = { title = _L('change_name'), text = _L('change_name_text', Fmt(N.price)), ok = _L('buy'),
                fields = { { type = 'input', name = 'name', value = d.name, max = N.maxLength, required = true } } } }
    end
    if P('change_blip') and B.enabled then
        id[#id + 1] = { value = 'blip', icon = 'flag', label = _L('change_blip'), sub = Fmt(B.price), go = 'blips' }
    end
    if #id > 0 then
        body[#body + 1] = { type = 'section', label = _L('identity') }
        body[#body + 1] = { type = 'medals', size = 'normal', cols = 2, items = MenuIcons(id) }
        body[#body + 1] = { type = 'text', style = 'note', text = _L('identity_note') }
    end

    if Config.Store.Enabled and (P('manage_store') or P('manage_store_inventory')) then
        body[#body + 1] = { type = 'section', label = _L('store') }
        body[#body + 1] = { type = 'kv', cols = 3, items = {
            { label = _L('store_state'), value = d.store.enabled and _L('enabled') or _L('disabled'), tone = d.store.enabled and 'good' or 'bad' },
            { label = _L('store_now'), value = d.store.open and _L('store_open') or _L('store_closed_short'), tone = d.store.open and 'good' or nil },
            { label = _L('products'), value = tostring(d.store.products) },
        } }
        local items = {}
        if P('manage_store') then items[#items + 1] = { value = 'store', icon = 'gear', label = _L('store_settings'), go = 'storeSettings' } end
        if P('manage_store_inventory') then items[#items + 1] = { value = 'products', icon = 'bag', label = _L('store_products'), go = 'products' } end
        body[#body + 1] = { type = 'medals', size = 'normal', cols = 2, items = MenuIcons(items) }
    end
    if #body == 0 then body[1] = { type = 'empty', text = _L('nothing_to_customize') } end
    return { body = body }
end

---------------------------------------------------------------------------
-- Blip gallery (round icon grid: search and categories run in the NUI, nothing to send back until saving)
---------------------------------------------------------------------------
local function BlipsPage()
    local d = D()
    local price = Fmt(Config.Identity.blipChange.price)
    return {
        title = _L('change_blip'), layout = 'wide',
        body = {
            BlipPicker({ name = 'blip_pick', current = d.blip }),
            { type = 'text', style = 'note', text = _L('blip_pick_note', price) },
        },
        footer = { main = { label = _L('save_blip', price), action = 'm:saveBlip', icon = 'check', requires = 'blip_pick',
            confirm = { title = _L('change_blip'), text = _L('blip_confirm_generic', price), ok = _L('buy'), cancel = _L('cancel') } } },
    }
end

UI.On('m:saveBlip', function(d)
    local blip = tonumber((d.values or {}).blip_pick)
    if not blip then return { ok = false, error = _L('no_blip_selected') } end
    if blip == D().blip then return { ok = false, error = _L('same_blip') } end
    local ok, msg = Call('setBlip', D().id, blip)
    if ok then PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0) end
    local res = M.Done(ok, msg)
    if ok then res.back = true end
    return res
end)

UI.On('m:rename', function(d)
    local ok, msg = Call('rename', D().id, (d.values or {}).name)
    if ok then PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0) end
    return M.Done(ok, msg)
end)

---------------------------------------------------------------------------
-- Placing points
---------------------------------------------------------------------------
local function PlaceFlow(kind, model)
    local d = D()
    local c = Companies[d.id]
    if not c then return end
    local id = d.id
    UI.Close()
    Wait(200)
    local res = Placement.Start({ model = model, ped = kind == 'store', label = _L('loc_' .. kind),
        center = vector3(c.coords.x, c.coords.y, c.coords.z), maxDistance = Config.Placement.maxDistance })
    if not res then Notify(_L('place_cancelled'), 'inform') return Management.Open('customization') end
    local ok, msg = Call('place', id, kind, res, model)
    Notify(msg or _L('error'), ok and 'success' or 'error')
    Management.Open(kind == 'store' and 'storeSettings' or 'customization')
end

UI.On('m:place', function(d)
    local kind = d.value
    local models = Models(kind)
    local model = (d.values or {}).model or (models[1] and models[1].value)
    if kind == 'store' then model = (d.values or {}).store_model or D().store.model end
    if not model then return { ok = false, error = _L('invalid_model') } end
    SetTimeout(0, function() PlaceFlow(kind, model) end)
end)

---------------------------------------------------------------------------
-- Store settings
---------------------------------------------------------------------------
local function StoreSettingsPage()
    local d = D()
    local models = {}
    for _, m in ipairs(Config.Store.Models) do if ValidModel(m) then models[#models + 1] = { value = m, label = m } end end
    local reason
    if not d.store.enabled then reason = _L('store_reason_disabled')
    elseif not d.locations.store then reason = _L('store_reason_npc')
    elseif not d.store.open then reason = _L('store_reason_duty') end
    return {
        title = _L('store_settings'),
        body = {
            { type = 'text', style = 'desc', text = _L('store_settings_desc') },
            { type = 'segmented', style = 'switch', label = _L('store_state'), value = d.store.enabled and 'on' or 'off', action = 'm:storeToggle',
              options = { { value = 'off', label = _L('disabled') }, { value = 'on', label = _L('enabled') } } },
            #models > 0 and { type = 'fco-select', name = 'store_model', label = _L('npc_model'), options = models, value = d.store.model, action = 'm:storeModel' } or nil,
            { type = 'kv', cols = 2, items = {
                { label = _L('npc'), value = d.locations.store and _L('placed_short') or _L('not_placed'), tone = d.locations.store and 'good' or 'bad' },
                { label = _L('store_now'), value = d.store.open and _L('store_open') or _L('store_closed_short'), tone = d.store.open and 'good' or nil },
            } },
            reason and { type = 'text', style = 'note', text = reason } or nil,
            { type = 'button', wide = true, icon = 'pin', label = d.locations.store and _L('move_npc') or _L('place_npc'), action = 'm:place', value = 'store' },
        },
    }
end

UI.On('m:storeToggle', function(d)
    local ok, msg = Call('store:settings', D().id, { enabled = d.value == 'on' })
    if not ok then return { ok = false, error = msg } end
    M.Fetch()
    return { toast = { text = msg, type = 'success' }, page = StoreSettingsPage() }
end)

UI.On('m:storeModel', function(d)
    local ok, msg = Call('store:settings', D().id, { model = d.value })
    if not ok then return { ok = false, error = msg } end
    M.Fetch()
    return { toast = { text = msg, type = 'success' } }
end)

---------------------------------------------------------------------------
-- Products
---------------------------------------------------------------------------
local function FetchStore()
    local ok, s = Call('store:manage', D().id)
    if ok then store = s end
    return ok, s
end

local function ProductsPage()
    if not store then return { title = _L('store_products'), body = { { type = 'empty', text = _L('loading') } } } end
    local products, listed = {}, {}
    for _, p in ipairs(store.products) do
        listed[p.item] = p
        local actions = {
            { label = _L('add_stock'), icon = 'plus', action = 'm:addStock', value = p.item,
              prompt = { title = _L('add_stock_of', p.label), text = _L('add_stock_text'), fields = { { type = 'number', name = 'qty', label = _L('quantity'), value = 1, min = 1, max = Config.Store.MaxStockPerProduct, step = 1, quick = { 1, 10, 50 } } } } },
        }
        if store.allowPrice then
            actions[#actions + 1] = { label = _L('change_price'), icon = 'coin', style = 'ghost', action = 'm:setPrice', value = p.item,
                prompt = { title = _L('change_price_of', p.label), fields = { { type = 'number', name = 'price', label = _L('unit_price'), value = p.price, min = store.minPrice, max = store.maxPrice, step = 1 } } } }
        end
        if store.allowWithdraw then
            actions[#actions + 1] = { label = _L('withdraw_stock'), icon = 'take', style = 'ghost', action = 'm:withdrawStock', value = p.item, disabled = p.quantity < 1,
                prompt = { title = _L('withdraw_stock_of', p.label), fields = { { type = 'number', name = 'qty', label = _L('quantity'), value = p.quantity, min = 1, max = math.max(1, p.quantity), step = 1 } } } }
            actions[#actions + 1] = { label = _L('remove_product'), icon = 'x', style = 'danger', action = 'm:removeProduct', value = p.item,
                confirm = { title = _L('remove_product'), text = _L('remove_product_text', p.label, p.quantity), danger = true, ok = _L('remove'), cancel = _L('cancel') } }
        end
        products[#products + 1] = {
            item = p.item, label = p.label, img = p.img, price = p.price, quantity = p.quantity, actions = actions,
            sub = (p.quantity < 1 and _L('sold_out') or _L('in_stock', p.quantity)) .. (p.listedBy and (' · ' .. _L('listed_by', p.listedBy)) or ''),
        }
    end

    local inventory = {}
    local full = #store.products >= store.max
    for _, it in ipairs(store.inventory or {}) do
        local existing = listed[it.name]
        local fields = { { type = 'number', name = 'li_qty', label = _L('quantity_to_list'), value = math.min(it.count, 10), min = 1, max = it.count, step = 1, quick = { 1, 5, 10, it.count } } }
        if not existing or store.allowPrice then
            fields[#fields + 1] = { type = 'number', name = 'li_price', label = _L('unit_price'), value = existing and existing.price or 1, min = store.minPrice, max = store.maxPrice, step = 1, quick = { 1, 5, 10 } }
        end
        inventory[#inventory + 1] = {
            name = it.name, label = it.label, img = it.img,
            sub = _L('you_have', it.count) .. (existing and (' · ' .. _L('already_listed_item')) or ''),
            action = { label = existing and _L('restock') or _L('list_item'), icon = 'plus', style = existing and 'ghost' or nil, value = it.name, action = 'm:listItem',
                disabled = full and not existing,
                prompt = { title = it.label, text = existing and _L('already_listed_note', existing.quantity, Fmt(existing.price)) or _L('list_item_note'), ok = _L('list_item'), fields = fields } },
        }
    end
    return {
        title = _L('store_products'), count = ('%d / %d'):format(#store.products, store.max), layout = 'wide',
        desc = _L('add_product_desc'),
        body = { { type = 'fco-stock', products = products, inventory = inventory, labels = {
            store = _L('store_products'), storeCount = ('%d / %d'):format(#store.products, store.max), inventory = _L('your_inventory'),
            search = _L('store_search_ph'), empty = _L('no_products'), emptyInv = _L('no_items_to_list'), noResults = _L('no_results'),
        } } },
    }
end

M.OnPage = function(d)
    if d.to == 'products' then
        local ok, err = FetchStore()
        if not ok then return { ok = false, error = err } end
        return { page = ProductsPage() }
    end
    if d.to == 'blips' then return { page = BlipsPage() } end
end

local function StoreDone(ok, msg, page)
    if not ok then return { ok = false, error = msg } end
    FetchStore()
    M.Fetch()
    local res = { toast = { text = msg, type = 'success' }, view = M.View() }
    if page then res.go = page end
    return res
end

UI.On('m:listItem', function(d)
    local v = d.values or {}
    local ok, msg = Call('store:add', D().id, d.value, tonumber(v.li_qty), tonumber(v.li_price))
    return StoreDone(ok, msg)
end)

UI.On('m:addStock', function(d)
    local ok, msg = Call('store:add', D().id, d.value, tonumber((d.values or {}).qty), nil)
    return StoreDone(ok, msg)
end)

UI.On('m:setPrice', function(d)
    local ok, msg = Call('store:price', D().id, d.value, tonumber((d.values or {}).price))
    return StoreDone(ok, msg)
end)

UI.On('m:withdrawStock', function(d)
    local ok, msg = Call('store:withdraw', D().id, d.value, tonumber((d.values or {}).qty))
    return StoreDone(ok, msg)
end)

UI.On('m:removeProduct', function(d)
    local ok, msg = Call('store:withdraw', D().id, d.value, 'all')
    return StoreDone(ok, msg)
end)

function M.CustomPages()
    return { customization = CustomPage(), blips = BlipsPage(), storeSettings = StoreSettingsPage(), products = ProductsPage() }
end

OnUIClose(function()
    store = nil
end)
