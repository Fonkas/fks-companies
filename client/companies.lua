---------------------------------------------------------------------------
-- Administration screens (drawn by fks-core):
--   /createnewcompany   creation form at the admin's position (temporary marker + blip until confirmed)
--   /managecompanies    every company: search / filters, editing, activity status, deletion, admin log
-- The server checks the admin permission again on every call.
---------------------------------------------------------------------------
local Fmt = Co.Fmt

local function PlayerOptions(players, none)
    local opts = { { value = '', label = none } }
    for _, p in ipairs(players or {}) do opts[#opts + 1] = { value = tostring(p.id), label = ('%s · ID %d'):format(p.name, p.id) } end
    return opts
end

local OnOff = { { value = 'off', label = _L('no') }, { value = 'on', label = _L('yes') } }
local TaxTypes = { { value = 'fixed', label = _L('tax_fixed') }, { value = 'percent', label = _L('tax_percent') } }

---------------------------------------------------------------------------
-- Taxes form (creation and /managecompanies): on/off, fixed or %, how often, and a plain sentence of what
-- will happen, updated while the admin changes it. n(field) = name of the field in this form.
---------------------------------------------------------------------------
local EveryLabel = Co.Every

-- how often: days (0 to 30) plus hours (0 to 23); the server keeps it at least Config.Taxes.minInterval
local function TaxInterval(v, n)
    local days = math.floor(math.max(0, math.min(30, tonumber(v[n('tax_days')]) or 0)))
    local hours = math.floor(math.max(0, math.min(23, tonumber(v[n('tax_hours')]) or 0)))
    return math.max(Config.Taxes.minInterval, days * 1440 + hours * 60)
end

local function AmountLabel(kind) return kind == 'percent' and _L('tax_amount_percent') or _L('tax_amount_fixed') end

local function TaxSummary(on, kind, amount, every)
    if not Config.Taxes.enabled then return _L('taxes_disabled_global') end
    if not on then return _L('tax_sum_off') end
    local when = EveryLabel(every)
    local text = kind == 'percent' and _L('tax_sum_percent', amount, when, Fmt(1000 * amount / 100)) or _L('tax_sum_fixed', Fmt(amount), when)
    return text .. ' ' .. _L('tax_policy_' .. Config.Taxes.failPolicy)
end

local function TaxFields(n, tax, act)
    local days = math.min(30, math.floor(tax.interval / 1440))
    local hours = math.floor((tax.interval - days * 1440) / 60) % 24
    return {
        { type = 'segmented', style = 'switch', name = n('tax_on'), label = _L('auto_tax'), options = OnOff, value = tax.enabled and 'on' or 'off', action = act },
        { type = 'segmented', name = n('tax_type'), label = _L('tax_type'), options = TaxTypes, value = tax.type, action = act },
        { type = 'number', id = n('tax_amount') .. '_f', name = n('tax_amount'), label = AmountLabel(tax.type), value = tax.amount, min = 0,
          max = tax.type == 'percent' and 100 or Config.Finance.maxTransaction, step = 1, action = act },
        { type = 'number', name = n('tax_days'), label = _L('tax_every_days'), value = days, min = 0, max = 30, step = 1, action = act },
        { type = 'number', name = n('tax_hours'), label = _L('tax_every_hours'), value = hours, min = 0, max = 23, step = 1, action = act },
        { type = 'text', id = n('tax_sum'), style = 'note', text = TaxSummary(tax.enabled, tax.type, tax.amount, tax.interval) },
    }
end

-- live: the sentence follows the form; the amount field only changes (label / limit) with the tax type,
-- so typing in it never loses the focus
local function TaxPatch(d, n)
    local v = d.values or {}
    local kind = v[n('tax_type')] == 'percent' and 'percent' or 'fixed'
    local patch = { [n('tax_sum')] = { text = TaxSummary(v[n('tax_on')] == 'on', kind, tonumber(v[n('tax_amount')]) or 0, TaxInterval(v, n)) } }
    if d.name == n('tax_type') then
        patch[n('tax_amount') .. '_f'] = { label = AmountLabel(kind), max = kind == 'percent' and 100 or Config.Finance.maxTransaction }
    end
    return { patch = patch }
end

-- the storage limits are optional in the config (false = no limit)
local function StorageMax(key) return Config.Storage[key] or nil end

---------------------------------------------------------------------------
-- Creation
---------------------------------------------------------------------------
local creating = nil     -- { coords, players, defaults, blip }
local function CrName(f) return 'cr_' .. f end

local function ClearCreation()
    if creating and creating.blip and DoesBlipExist(creating.blip) then RemoveBlip(creating.blip) end
    creating = nil
end

local function CreateView()
    local d = creating.defaults
    local c = creating.coords
    local function page(title, body) return { title = title, body = body } end
    return {
        eyebrow = _L('administration'), title = _L('new_company'), page = 'identity',
        tabs = {
            { page = 'identity', label = _L('cr_tab_identity') }, { page = 'finance', label = _L('cr_tab_finance') },
            { page = 'capacity', label = _L('cr_tab_capacity') }, { page = 'sale', label = _L('cr_tab_sale') },
        },
        pages = {
            identity = page(_L('cr_tab_identity'), {
                { type = 'text', style = 'note', text = _L('cr_location', ('%.1f, %.1f, %.1f'):format(c.x, c.y, c.z)) },
                { type = 'input', name = 'cr_name', label = _L('company_name'), max = 40, placeholder = _L('company_name_ph') },
                { type = 'grid', cols = 2, children = {
                    { type = 'input', name = 'cr_job', label = _L('company_job'), max = 60, placeholder = 'saloon' },
                    { type = 'input', name = 'cr_code', label = _L('company_code'), max = 32, optional = true, placeholder = 'VAL-SALOON' },
                } },
                { type = 'text', style = 'note', text = _L('cr_job_note') },
                { type = 'fco-select', name = 'cr_owner', label = _L('initial_owner'), options = PlayerOptions(creating.players, _L('no_owner')), value = '' },
                BlipPicker({ name = 'cr_blip', label = _L('blip'), value = d.blip, compact = true }),
                { type = 'textarea', name = 'cr_desc', label = _L('description'), max = 255, optional = true },
            }),
            finance = page(_L('cr_tab_finance'), (function()
                local body = {
                    { type = 'text', style = 'desc', text = _L('ledger_intro') },
                    { type = 'section', label = _L('initial_balance') },
                    { type = 'number', name = 'cr_balance', label = _L('initial_balance'), value = 0, min = 0, max = Config.Finance.maxTransaction, step = 100, quick = { 0, 500, 1000, 5000 } },
                    { type = 'text', style = 'note', text = _L('initial_balance_note') },
                    { type = 'section', label = _L('auto_tax') },
                }
                for _, f in ipairs(TaxFields(CrName, d.tax, 'c:tax')) do body[#body + 1] = f end
                return body
            end)()),
            capacity = page(_L('cr_tab_capacity'), {
                { type = 'section', label = _L('loc_boss_storage') },
                { type = 'grid', cols = 2, children = {
                    { type = 'number', name = 'cr_boss_slots', label = _L('slots'), value = d.storage.boss.slots, min = 1, max = StorageMax('maxSlots'), step = 5 },
                    { type = 'number', name = 'cr_boss_weight', label = _L('weight'), value = d.storage.boss.weight, min = 1, max = StorageMax('maxWeight'), step = 1000 },
                } },
                { type = 'section', label = _L('loc_general_storage') },
                { type = 'grid', cols = 2, children = {
                    { type = 'number', name = 'cr_gen_slots', label = _L('slots'), value = d.storage.general.slots, min = 1, max = StorageMax('maxSlots'), step = 5 },
                    { type = 'number', name = 'cr_gen_weight', label = _L('weight'), value = d.storage.general.weight, min = 1, max = StorageMax('maxWeight'), step = 1000 },
                } },
                { type = 'text', style = 'note', text = _L('storage_note') },
                { type = 'number', name = 'cr_max_emp', label = _L('max_employees'), value = d.maxEmployees, min = 1, max = Config.Creation.maxEmployeesLimit, step = 1 },
            }),
            sale = page(_L('cr_tab_sale'), {
                not d.marketplace and { type = 'text', style = 'note', text = _L('feature_disabled') } or nil,
                { type = 'segmented', style = 'switch', name = 'cr_sale', label = _L('for_sale'), options = OnOff, value = 'off' },
                { type = 'number', name = 'cr_price', label = _L('price'), value = d.minPrice, min = 0, max = Config.Marketplace.MaxPrice, step = 100 },
                { type = 'segmented', style = 'switch', name = 'cr_public', label = _L('public_listing'), options = OnOff, value = 'on' },
                { type = 'segmented', style = 'switch', name = 'cr_negotiable', label = _L('negotiable'), options = OnOff, value = 'off' },
                { type = 'text', style = 'note', text = _L('public_note') },
            }),
        },
        footer = {
            buttons = { { type = 'button', small = true, style = 'ghost', icon = 'x', label = _L('cancel'), action = 'c:cancel' } },
            main = { label = _L('create_company'), action = 'c:create', icon = 'check', requires = 'cr_name',
                     confirm = { title = _L('create_company'), text = _L('create_confirm'), ok = _L('create_company'), cancel = _L('cancel') } },
        },
    }
end

UI.On('c:tax', function(d) return TaxPatch(d, CrName) end)

UI.On('c:cancel', function()
    ClearCreation()
    return { close = true, toast = { text = _L('creation_cancelled') } }
end)

UI.On('c:create', function(d)
    local v = d.values or {}
    local num = tonumber
    local ok, msg = Call('admin:create', {
        name = v.cr_name, job = v.cr_job, code = v.cr_code, description = v.cr_desc,
        owner = v.cr_owner ~= '' and num(v.cr_owner) or nil, blip = num(v.cr_blip), coords = creating.coords,
        tax = { enabled = v.cr_tax_on == 'on', type = v.cr_tax_type, amount = num(v.cr_tax_amount), interval = TaxInterval(v, CrName) },
        balance = num(v.cr_balance),
        storage = { boss = { slots = num(v.cr_boss_slots), weight = num(v.cr_boss_weight) }, general = { slots = num(v.cr_gen_slots), weight = num(v.cr_gen_weight) } },
        maxEmployees = num(v.cr_max_emp),
        sale = { forSale = v.cr_sale == 'on', price = num(v.cr_price), public = v.cr_public ~= 'off', negotiable = v.cr_negotiable == 'on' },
    })
    if not ok then
        local errors
        if msg == _L('invalid_name') then errors = { cr_name = msg } elseif msg == _L('invalid_job') or (msg or ''):find(tostring(v.cr_job or '?'), 1, true) then errors = { cr_job = msg }
        elseif msg == _L('invalid_code') or msg == _L('code_taken') then errors = { cr_code = msg } end
        return { ok = false, error = msg, errors = errors }
    end
    ClearCreation()
    Notify(msg, 'success')
    return { close = true }
end)

OnUIClose(function() ClearCreation() end)

RegisterNetEvent('fks-companies:client:create', function(data)
    if UI.IsOpen() then return Notify(_L('close_other_window'), 'error') end
    ClearCreation()
    creating = data
    local c = data.coords
    creating.blip = Citizen.InvokeNative(0x554D9D53F696D002, 1664425300, c.x, c.y, c.z)
    SetBlipSprite(creating.blip, data.defaults.blip, true)
    Citizen.InvokeNative(0x9CB1A1623062F402, creating.blip, _L('new_company'))
    if not OpenView('create', CreateView()) then ClearCreation() return end
    -- marker on the ground where the company will be
    CreateThread(function()
        while creating do
            Citizen.InvokeNative(0x2A32FAA57B937173, 0x94FDAE17, c.x, c.y, c.z - 0.96, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                Config.Marker.scale[1], Config.Marker.scale[2], Config.Marker.scale[3], 242, 193, 78, 160, false, false, 2, false, nil, nil, false)
            Wait(0)
        end
    end)
end)

---------------------------------------------------------------------------
-- /managecompanies
---------------------------------------------------------------------------
local A = { list = {}, players = {}, filter = 'all', search = '', sel = nil, log = nil, logPage = 1 }

local FILTERS = { 'all', 'active', 'inactive', 'for_sale', 'not_for_sale', 'no_owner', 'no_employees' }

local function Matches(c)
    local f = A.filter
    if f == 'active' and c.status ~= 'active' then return false end
    if f == 'inactive' and c.status == 'active' then return false end
    if f == 'for_sale' and c.sale ~= 'for_sale' then return false end
    if f == 'not_for_sale' and c.sale == 'for_sale' then return false end
    if f == 'no_owner' and c.owner then return false end
    if f == 'no_employees' and c.employees > 0 then return false end
    local q = A.search:lower()
    if q ~= '' then
        local hay = ('%d %s %s %s %s'):format(c.id, c.name, c.code, c.job, c.owner or ''):lower()
        if not hay:find(q, 1, true) then return false end
    end
    return true
end

local STATUS_TONE = { active = 'good', inactive = 'bad', suspended = 'bad' }

local function ListRows()
    local rows = {}
    for _, c in ipairs(A.list) do
        if Matches(c) then
            rows[#rows + 1] = {
                value = c.id, title = c.name, tag = _L('status_' .. c.status),
                flag = c.sale == 'for_sale' and { text = _L('sale_for_sale'), tone = 'gold' } or nil,
                sub = ('#%d · %s · %s · %s'):format(c.id, c.code, c.job, c.owner or _L('no_owner')),
                details = { { type = 'kv', cols = 3, items = {
                    { label = _L('company_id'), value = ('#%d'):format(c.id) },
                    { label = _L('owner'), value = c.owner or _L('no_owner') },
                    { label = _L('company_job'), value = c.job },
                    { label = _L('employees'), value = ('%d / %d'):format(c.employees, c.maxEmployees) },
                    { label = _L('employees_on_duty'), value = tostring(c.onDuty) },
                    { label = _L('balance'), value = Fmt(c.balance), tone = 'gold' },
                    { label = _L('company_status'), value = _L('status_' .. c.status), tone = STATUS_TONE[c.status] },
                    { label = _L('sale_status'), value = _L('sale_' .. c.sale) },
                    { label = _L('price'), value = Fmt(c.price) },
                    { label = _L('created'), value = c.created },
                } } },
                actions = { { label = _L('manage'), icon = 'gear', small = true, action = 'a:open', value = c.id } },
            }
        end
    end
    return rows
end

local function ListPage()
    local filters = {}
    for _, f in ipairs(FILTERS) do filters[#filters + 1] = { value = f, label = _L('filter_' .. f) } end
    local rows = ListRows()
    return {
        title = _L('all_companies'), count = ('%d / %d'):format(#rows, #A.list), layout = 'wide',
        body = {
            { type = 'grid', template = '2fr 1fr', children = {
                { type = 'input', name = 'a_search', label = _L('search'), value = A.search, placeholder = _L('admin_search_ph'), live = true, action = 'a:search', throttle = 300 },
                { type = 'fco-select', name = 'a_filter', label = _L('filter'), options = filters, value = A.filter, action = 'a:filter' },
            } },
            { type = 'list', id = 'adminList', items = rows, hidden = #rows == 0 },
            { type = 'empty', id = 'adminEmpty', text = _L('no_companies'), hidden = #rows > 0 },
        },
        footer = { buttons = {
            { type = 'button', small = true, style = 'ghost', icon = 'quill', label = _L('admin_log'), action = 'a:log' },
            { type = 'button', small = true, style = 'ghost', icon = 'box', label = _L('archived_companies'), action = 'a:archived' },
        } },
    }
end

local function ArchivedPage()
    local rows = {}
    for _, r in ipairs(A.archived or {}) do
        rows[#rows + 1] = { value = r.id, title = r.name, tag = r.deleted, sub = ('#%d · %s'):format(r.id, r.code),
            actions = { { label = _L('delete_forever'), icon = 'x', small = true, style = 'danger', action = 'a:purgeOne', value = r.id,
                          confirm = { title = _L('purge_company'), text = _L('purge_archived_text', r.name), danger = true, ok = _L('delete_forever'), cancel = _L('cancel') } } } }
    end
    return { title = _L('archived_companies'), count = tostring(#rows), body = {
        { type = 'text', style = 'desc', text = _L('archived_desc') },
        #rows > 0 and { type = 'list', items = rows } or { type = 'empty', text = _L('no_archived') },
    }, footer = { main = #rows > 0 and { label = _L('purge_all_archived', #rows), action = 'a:purgeAll', icon = 'x',
        confirm = { title = _L('purge_all_archived', #rows), text = _L('purge_all_text'), danger = true, ok = _L('delete_forever'), cancel = _L('cancel') } } or false } }
end

-- detail pages (one company), names carry the id so values never leak between companies
local function N(field) return ('ad_%s_%d'):format(field, A.sel.id) end

local function DetailTabs()
    return { { page = 'd_info', label = _L('ad_tab_info') }, { page = 'd_money', label = _L('ad_tab_money') },
             { page = 'd_status', label = _L('ad_tab_status') }, { page = 'd_staff', label = _L('ad_tab_staff') },
             { page = 'd_delete', label = _L('ad_tab_delete') } }
end

local function Save(field, label) return { type = 'button', small = true, label = label or _L('save'), action = 'a:edit', value = field } end

local function InfoPage()
    local c = A.sel
    return { title = c.name, count = ('#%d'):format(c.id), tabs = DetailTabs(), body = {
        { type = 'section', label = _L('ad_identity') },
        { type = 'grid', template = '1fr auto', children = { { type = 'input', name = N('name'), label = _L('company_name'), value = c.name, max = 40 }, Save('name') } },
        { type = 'grid', template = '1fr auto', children = { { type = 'input', name = N('code'), label = _L('company_code'), value = c.code, max = 32 }, Save('code') } },
        { type = 'grid', template = '1fr auto', children = { { type = 'input', name = N('job'), label = _L('company_job'), value = c.job, max = 60 }, Save('job') } },
        { type = 'text', style = 'note', text = _L('ad_job_note') },
        { type = 'grid', template = '1fr auto', children = { { type = 'textarea', name = N('description'), label = _L('description'), value = c.description or '', max = 255 }, Save('description') } },
        BlipPicker({ name = N('blip'), label = _L('blip'), value = c.blip, current = c.blip, compact = true }),
        { type = 'row', align = 'center', children = { Save('blip') } },
        { type = 'section', label = _L('owner') },
        { type = 'kv', cols = 1, items = { { label = _L('current_owner'), value = c.owner or _L('no_owner'), tone = 'gold' } } },
        { type = 'grid', template = '1fr auto', children = { { type = 'fco-select', name = N('owner_player'), label = _L('owner_online'), options = PlayerOptions(A.players, '-'), value = '' }, Save('owner_player', _L('set_owner')) } },
        { type = 'grid', template = '1fr auto', children = { { type = 'input', name = N('owner_cid'), label = _L('owner_cid'), max = 60, placeholder = _L('owner_cid_ph') }, Save('owner_cid', _L('set_owner')) } },
        { type = 'button', small = true, style = 'danger', label = _L('remove_owner'), action = 'a:edit', value = 'owner_none',
          confirm = { title = _L('remove_owner'), text = _L('remove_owner_text'), danger = true, ok = _L('remove'), cancel = _L('cancel') } },
        { type = 'section', label = _L('ad_location') },
        { type = 'text', style = 'note', text = ('%.1f, %.1f, %.1f'):format(c.coords.x, c.coords.y, c.coords.z) },
        { type = 'row', align = 'center', children = {
            { type = 'button', small = true, icon = 'pin', label = _L('set_here'), action = 'a:edit', value = 'location',
              confirm = { title = _L('set_here'), text = _L('set_here_text'), ok = _L('set_here'), cancel = _L('cancel') } },
            { type = 'button', small = true, style = 'ghost', icon = 'fwd', label = _L('teleport'), action = 'a:tp' },
        } },
        { type = 'section', label = _L('ad_points') },
        { type = 'chips', name = N('points'), options = (function()
            local o = {}
            for _, k in ipairs({ 'boss_storage', 'general_storage', 'register', 'store' }) do
                if c.locations[k] then o[#o + 1] = { value = k, label = _L('loc_' .. k) } end
            end
            return o
        end)(), value = {} },
        { type = 'button', small = true, style = 'danger', label = _L('clear_points'), action = 'a:clearPoints' },
    } }
end

local function MoneyPage()
    local c = A.sel
    return { title = c.name, count = ('#%d'):format(c.id), tabs = DetailTabs(), body = {
        { type = 'kv', cols = 3, class = 'big', items = {
            { label = _L('balance'), value = Fmt(c.balance), tone = 'gold' },
            { label = _L('total_income'), value = Fmt(c.income), tone = 'good' },
            { label = _L('total_expenses'), value = Fmt(c.expenses), tone = 'bad' },
        } },
        { type = 'button', small = true, style = 'ghost', icon = 'coin', label = _L('set_balance'), action = 'a:balance',
          prompt = { title = _L('set_balance'), text = _L('set_balance_text'), fields = { { type = 'number', name = 'amount', value = c.balance, min = 0, max = Config.Finance.maxTransaction * 100, step = 100 } } } },
        { type = 'section', label = _L('auto_tax') },
        { type = 'grid', cols = 1, children = TaxFields(N, c.tax, 'a:tax') },
        Save('tax'),
        { type = 'section', label = _L('cr_tab_sale') },
        { type = 'segmented', style = 'switch', name = N('sale_on'), label = _L('for_sale'), options = OnOff, value = c.sale == 'for_sale' and 'on' or 'off' },
        { type = 'number', name = N('sale_price'), label = _L('price'), value = c.price, min = 0, max = Config.Marketplace.MaxPrice, step = 100 },
        { type = 'segmented', style = 'switch', name = N('sale_public'), label = _L('public_listing'), options = OnOff, value = c.salePublic and 'on' or 'off' },
        { type = 'segmented', style = 'switch', name = N('sale_neg'), label = _L('negotiable'), options = OnOff, value = c.saleNegotiable and 'on' or 'off' },
        { type = 'text', style = 'note', text = _L('ad_sale_note') },
        Save('sale'),
        { type = 'section', label = _L('ad_capacity') },
        { type = 'grid', cols = 2, children = {
            { type = 'number', name = N('boss_slots'), label = _L('boss_slots'), value = c.storage.boss.slots, min = 1, max = StorageMax('maxSlots'), step = 5 },
            { type = 'number', name = N('boss_weight'), label = _L('boss_weight'), value = c.storage.boss.weight, min = 1, max = StorageMax('maxWeight'), step = 1000 },
            { type = 'number', name = N('gen_slots'), label = _L('general_slots'), value = c.storage.general.slots, min = 1, max = StorageMax('maxSlots'), step = 5 },
            { type = 'number', name = N('gen_weight'), label = _L('general_weight'), value = c.storage.general.weight, min = 1, max = StorageMax('maxWeight'), step = 1000 },
        } },
        Save('storage'),
        { type = 'grid', template = '1fr auto', children = { { type = 'number', name = N('max_emp'), label = _L('max_employees'), value = c.maxEmployees, min = 1, max = Config.Creation.maxEmployeesLimit, step = 1 }, Save('maxEmployees') } },
        { type = 'section', label = _L('store') },
        { type = 'segmented', style = 'switch', name = N('store_on'), label = _L('store_state'), options = OnOff, value = c.store.enabled and 'on' or 'off', action = 'a:store' },
        { type = 'text', style = 'note', text = _L('ad_store_info', c.store.products) },
    } }
end

local function StatusPage()
    local c = A.sel
    local buttons = {}
    local function btn(status, label, style)
        return { type = 'button', small = true, style = style, label = label, action = 'a:status', value = status,
                 prompt = { title = label, text = _L('status_reason_text'), ok = label, danger = style == 'danger',
                            fields = { { type = 'input', name = 'reason', label = _L('reason'), max = 255, optional = true } } } }
    end
    if c.status == 'active' then
        buttons[#buttons + 1] = btn('suspended', _L('suspend'), 'danger')
        buttons[#buttons + 1] = btn('inactive', _L('deactivate'), 'ghost')
    elseif c.status == 'suspended' then
        buttons[#buttons + 1] = btn('active', _L('reactivate'))
        buttons[#buttons + 1] = btn('inactive', _L('deactivate'), 'ghost')
    else
        buttons[#buttons + 1] = btn('active', _L('activate'))
        buttons[#buttons + 1] = btn('suspended', _L('suspend'), 'danger')
    end
    return { title = c.name, count = ('#%d'):format(c.id), tabs = DetailTabs(), body = {
        { type = 'kv', cols = 2, class = 'big', items = {
            { label = _L('company_status'), value = _L('status_' .. c.status), tone = STATUS_TONE[c.status] },
            { label = _L('reason'), value = c.statusReason or '-' },
        } },
        { type = 'text', style = 'desc', text = _L('status_effects') },
        { type = 'row', align = 'center', children = buttons },
        { type = 'button', small = true, style = 'ghost', icon = 'quill', label = _L('company_log'), action = 'a:log', value = c.id },
    } }
end

-- deleting gets its own tab: archive (history kept) or delete for good
local function DeletePage()
    local c = A.sel
    return { title = c.name, count = ('#%d'):format(c.id), tabs = DetailTabs(), body = {
        { type = 'section', label = _L('danger_zone') },
        { type = 'text', style = 'desc', text = _L('delete_effects') },
        { type = 'grid', cols = 2, children = {
            { type = 'button', style = 'ghost', wide = true, icon = 'box', label = _L('archive_company'), action = 'a:delete', value = 'archive',
              prompt = { title = _L('archive_company'), danger = true, text = _L('archive_text', c.code), ok = _L('archive'),
                         fields = { { type = 'input', name = 'confirm', label = _L('company_code'), match = c.code } } } },
            { type = 'button', style = 'danger', wide = true, icon = 'x', label = _L('purge_company'), action = 'a:delete', value = 'purge',
              prompt = { title = _L('purge_company'), danger = true, text = _L('purge_text', c.code), ok = _L('delete_forever'),
                         fields = { { type = 'input', name = 'confirm', label = _L('company_code'), match = c.code } } } },
        } },
    } }
end

local function StaffPage()
    local c = A.sel
    local rows = {}
    for _, e in ipairs(c.staff or {}) do
        rows[#rows + 1] = { value = e.cid, title = e.name, tag = e.position,
            flag = e.onDuty and { text = _L('on_duty'), tone = 'good' } or nil,
            sub = ('%s · %s · %s'):format(e.cid, _L('hired_on', e.hired), e.online and _L('online') or _L('offline')) }
    end
    local pos = {}
    for _, p in ipairs(c.positions or {}) do pos[#pos + 1] = { text = ('%s (%d)'):format(p.name, p.grade), tone = p.boss and 'gold' or nil } end
    return { title = c.name, count = tostring(#rows), tabs = DetailTabs(), body = {
        { type = 'badges', items = pos },
        #rows > 0 and { type = 'list', expand = 'none', items = rows } or { type = 'empty', text = _L('no_employees') },
    } }
end

local function LogPage()
    local rows = {}
    for i, r in ipairs(A.log or {}) do
        rows[#rows + 1] = { value = i, title = ('%s · %s'):format(_L('log_' .. r.action) ~= 'log_' .. r.action and _L('log_' .. r.action) or r.action, r.company or ('#' .. tostring(r.companyId))),
                            tag = r.at, sub = ('%s%s'):format(r.admin, r.details and (' · ' .. r.details) or '') }
    end
    local nav = {}
    if A.logPage > 1 then nav[#nav + 1] = { type = 'button', small = true, style = 'ghost', icon = 'left', label = _L('newer'), action = 'a:logPage', value = A.logPage - 1 } end
    if #rows >= Config.AdminManagement.logPageSize then nav[#nav + 1] = { type = 'button', small = true, style = 'ghost', iconRight = 'right', label = _L('older'), action = 'a:logPage', value = A.logPage + 1 } end
    return { title = _L('admin_log'), count = _L('page_n', A.logPage), body = {
        #rows > 0 and { type = 'list', expand = 'none', items = rows } or { type = 'empty', text = _L('no_log') },
        #nav > 0 and { type = 'row', align = 'center', children = nav } or nil,
    } }
end

local function AdminView()
    local pages = { list = ListPage() }
    if A.sel then pages.d_info, pages.d_money, pages.d_status, pages.d_staff, pages.d_delete = InfoPage(), MoneyPage(), StatusPage(), StaffPage(), DeletePage() end
    if A.log then pages.log = LogPage() end
    if A.archived then pages.archived = ArchivedPage() end
    return { eyebrow = _L('administration'), title = _L('manage_companies'), page = 'list', layout = 'wide', pages = pages, hints = { { 'ESC', _L('back') } } }
end

local function FetchList()
    local ok, list, players = Call('admin:list')
    if not ok then return false, list end
    A.list, A.players = list, players or {}
    return true
end

local function FetchSel(id)
    local ok, c = Call('admin:get', id)
    if not ok then return false, c end
    A.sel = c
    return true
end

local function ListPatch()
    local rows = ListRows()
    return { patch = { adminList = { items = rows, hidden = #rows == 0 }, adminEmpty = { hidden = #rows > 0 }, count = { text = ('%d / %d'):format(#rows, #A.list) } } }
end

UI.On('a:search', function(d) A.search = tostring(d.value or '') return ListPatch() end)
UI.On('a:filter', function(d) A.filter = tostring(d.value or 'all') return ListPatch() end)

UI.On('a:open', function(d)
    local ok, err = FetchSel(d.value)
    if not ok then return { ok = false, error = err } end
    return { view = AdminView(), go = 'd_info' }
end)

-- after a change: fresh company + list, same page
local function AdminDone(ok, msg)
    if not ok then return { ok = false, error = msg } end
    FetchList()
    if A.sel and not FetchSel(A.sel.id) then A.sel = nil end
    return { toast = { text = msg, type = 'success' }, view = AdminView() }
end

UI.On('a:edit', function(d)
    local v = d.values or {}
    local f = d.value
    local num = tonumber
    local field, value = f, nil
    if f == 'name' or f == 'code' or f == 'job' or f == 'description' or f == 'blip' then value = v[N(f)]
    elseif f == 'owner_player' then field, value = 'owner', { player = num(v[N('owner_player')]) }
    elseif f == 'owner_cid' then field, value = 'owner', { cid = v[N('owner_cid')] }
    elseif f == 'owner_none' then field, value = 'owner', { none = true }
    elseif f == 'location' then value = true
    elseif f == 'tax' then value = { enabled = v[N('tax_on')] == 'on', type = v[N('tax_type')], amount = num(v[N('tax_amount')]), interval = TaxInterval(v, N) }
    elseif f == 'sale' then value = { forSale = v[N('sale_on')] == 'on', price = num(v[N('sale_price')]), public = v[N('sale_public')] ~= 'off', negotiable = v[N('sale_neg')] == 'on' }
    elseif f == 'storage' then value = { boss = { slots = num(v[N('boss_slots')]), weight = num(v[N('boss_weight')]) }, general = { slots = num(v[N('gen_slots')]), weight = num(v[N('gen_weight')]) } }
    elseif f == 'maxEmployees' then value = num(v[N('max_emp')])
    else return end
    local ok, msg = Call('admin:edit', A.sel.id, field, value)
    return AdminDone(ok, msg)
end)

UI.On('a:tax', function(d) return TaxPatch(d, N) end)

UI.On('a:store', function(d)
    local ok, msg = Call('admin:edit', A.sel.id, 'store', { enabled = d.value == 'on' })
    return AdminDone(ok, msg)
end)

UI.On('a:balance', function(d)
    local ok, msg = Call('admin:edit', A.sel.id, 'balance', tonumber((d.values or {}).amount))
    return AdminDone(ok, msg)
end)

UI.On('a:clearPoints', function(d)
    local pts = (d.values or {})[N('points')] or {}
    if #pts == 0 then return { ok = false, error = _L('choose_points') } end
    local last
    for _, k in ipairs(pts) do
        local ok, msg = Call('admin:edit', A.sel.id, 'clearLocation', k)
        if not ok then return { ok = false, error = msg } end
        last = msg
    end
    return AdminDone(true, last)
end)

UI.On('a:tp', function()
    local c = A.sel.coords
    local ped = PlayerPedId()
    SetEntityCoords(ped, c.x, c.y, c.z, false, false, false, false)
    return { toast = { text = _L('teleported'), type = 'success' } }
end)

UI.On('a:status', function(d)
    local ok, msg = Call('admin:status', A.sel.id, d.value, (d.values or {}).reason)
    return AdminDone(ok, msg)
end)

UI.On('a:delete', function(d)
    local ok, msg = Call('admin:delete', A.sel.id, (d.values or {}).confirm, d.value == 'purge' and 'purge' or 'archive')
    if not ok then return { ok = false, error = msg } end
    A.sel = nil
    FetchList()
    return { toast = { text = msg, type = 'success' }, view = AdminView(), back = true }
end)

local function FetchArchived()
    local ok, list = Call('admin:archived')
    if not ok then return false, list end
    A.archived = list
    return true
end

UI.On('a:archived', function()
    local ok, err = FetchArchived()
    if not ok then return { ok = false, error = err } end
    return { go = 'archived', data = ArchivedPage() }
end)

local function Purged(ok, msg)
    if not ok then return { ok = false, error = msg } end
    FetchArchived()
    return { toast = { text = msg, type = 'success' }, page = ArchivedPage() }
end
UI.On('a:purgeOne', function(d) return Purged(Call('admin:purgeArchived', tonumber(d.value))) end)
UI.On('a:purgeAll', function() return Purged(Call('admin:purgeArchived')) end)

local logFor = nil
UI.On('a:log', function(d)
    logFor = tonumber(d.value)
    A.logPage = 1
    local ok, rows = Call('admin:log', logFor, 1)
    if not ok then return { ok = false, error = rows } end
    A.log = rows
    return { go = 'log', data = LogPage() }
end)

UI.On('a:logPage', function(d)
    A.logPage = math.max(1, tonumber(d.value) or 1)
    local ok, rows = Call('admin:log', logFor, A.logPage)
    if not ok then return { ok = false, error = rows } end
    A.log = rows
    return { page = LogPage() }
end)

OnUIClose(function()
    A.sel, A.log, A.archived = nil, nil, nil
end)

RegisterNetEvent('fks-companies:client:admin', function()
    if UI.IsOpen() and ActiveView ~= 'admin' then return Notify(_L('close_other_window'), 'error') end
    local ok, err = FetchList()
    if not ok then return Notify(err, 'error') end
    A.search, A.filter = '', 'all'
    OpenView('admin', AdminView())
end)
