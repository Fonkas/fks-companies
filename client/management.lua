---------------------------------------------------------------------------
-- The company window (drawn by fks-core): General · Management · Ledger · Customization.
-- Tabs and buttons only show what the player's position allows; the server checks every action again.
-- Customization pages live in client/customization.lua (Management.Custom*).
---------------------------------------------------------------------------
Management = { D = nil, ledger = nil, page = 1 }
local M = Management

local function D() return M.D end
local function P(perm) return D() and (D().boss or D().perms[perm] == true) end
M.P = P

local function Fmt(n) return Co.Fmt(n) end

---------------------------------------------------------------------------
-- Fetching
---------------------------------------------------------------------------
function M.Fetch()
    local ok, d = Call('open')
    if not ok then return false, d end
    M.D = d
    return true
end

-- answer of a handler after a change: toast + fresh data, staying on `page` (or going there)
function M.Done(ok, msg, page)
    if not ok then return { ok = false, error = msg } end
    local fetched, err = M.Fetch()
    if not fetched then
        M.Close()
        return { toast = { text = msg, type = 'success' }, close = true }
    end
    local res = { toast = { text = msg, type = 'success' }, view = M.View() }
    if page then res.go = page end
    return res
end

---------------------------------------------------------------------------
-- General
---------------------------------------------------------------------------
local function GeneralPage()
    local d = D()
    local body = {}
    local blip = Co.BlipByHash[d.blip]
    body[#body + 1] = { type = 'medals', size = 'big', cols = 1, action = 'm:noop', items = {
        { img = blip and Co.BlipImage(blip.name) or nil, icon = 'flag', label = d.name, sub = ('%s · %s'):format(d.code, d.job) },
    } }
    if d.description and d.description ~= '' then body[#body + 1] = { type = 'text', style = 'sub', text = d.description } end
    body[#body + 1] = { type = 'kv', cols = 4, items = {
        { label = _L('owner'), value = d.owner, tone = 'gold' },
        { label = _L('your_position'), value = Me.position or '-' },
        { label = _L('employees'), value = ('%d / %d'):format(d.employees, d.maxEmployees) },
        { label = _L('employees_on_duty'), value = tostring(d.onDuty), tone = d.onDuty > 0 and 'good' or 'bad' },
    } }
    if d.overview then
        local o = d.overview
        body[#body + 1] = { type = 'section', label = _L('finances') }
        body[#body + 1] = { type = 'kv', cols = 3, class = 'big', items = {
            { label = _L('balance'), value = Fmt(o.balance), tone = 'gold' },
            { label = _L('total_income'), value = Fmt(o.income), tone = 'good' },
            { label = _L('total_expenses'), value = Fmt(o.expenses), tone = 'bad' },
        } }
        body[#body + 1] = { type = 'section', label = _L('recent_activity') }
        local rows = {}
        for i, a in ipairs(o.activity) do rows[#rows + 1] = { value = i, title = a.text, sub = a.at } end
        body[#body + 1] = #rows > 0 and { type = 'list', expand = 'none', items = rows } or { type = 'empty', text = _L('no_activity') }
    end
    if P('edit_info') then
        body[#body + 1] = { type = 'button', small = true, style = 'ghost', icon = 'quill', label = _L('edit_description'), action = 'm:description',
            prompt = { title = _L('edit_description'), fields = { { type = 'textarea', name = 'text', value = d.description or '', max = 255 } } } }
    end
    if not d.boss then
        body[#body + 1] = { type = 'button', small = true, style = 'danger', icon = 'x', label = _L('quit_company'), action = 'm:quit',
            confirm = { title = _L('quit_company'), text = _L('quit_confirm', d.name), danger = true, ok = _L('quit'), cancel = _L('cancel') } }
    end
    return { body = body }
end

---------------------------------------------------------------------------
-- Management: hire, staff, positions, sale
---------------------------------------------------------------------------
local function ManagementPage()
    local d = D()
    local items = {}
    if P('hire') then items[#items + 1] = { value = 'hire', icon = 'quill', label = _L('hire_employee'), sub = _L('hire_sub'), go = 'hire' } end
    if d.staff then items[#items + 1] = { value = 'staff', icon = 'user', label = _L('employee_list'), sub = _L('n_employees', d.employees), go = 'staff' } end
    if P('manage_positions') then items[#items + 1] = { value = 'positions', icon = 'grid', label = _L('positions'), sub = _L('n_positions', #d.positions), go = 'positions' } end
    if d.boss and Config.Marketplace.Enabled and Config.Marketplace.AllowPlayerSales then
        items[#items + 1] = { value = 'sell', icon = 'coin', label = _L('sell_company'), sub = d.sale.status == 'for_sale' and _L('listed_for', Fmt(d.sale.price)) or _L('not_listed_short'), go = 'sell' }
    end
    if #items == 0 then return { body = { { type = 'empty', text = _L('nothing_to_manage') } } } end
    return { body = { { type = 'medals', size = 'big', cols = 2, action = 'm:noop', items = MenuIcons(items) } } }
end

local function NearbyPlayers()
    local list = {}
    local me = PlayerId()
    local pos = GetEntityCoords(PlayerPedId())
    for _, pl in ipairs(GetActivePlayers()) do
        if pl ~= me then
            local dd = #(GetEntityCoords(GetPlayerPed(pl)) - pos)
            if dd <= Config.Contracts.maxDistance then
                list[#list + 1] = { value = tostring(GetPlayerServerId(pl)), label = ('ID %s · %d m'):format(GetPlayerServerId(pl), math.floor(dd)) }
            end
        end
    end
    return list
end

local function AssignablePositions()
    local d = D()
    local list = {}
    for _, p in ipairs(d.positions) do
        if not p.boss and (d.boss or p.grade < d.me.grade) then
            list[#list + 1] = { value = tostring(p.id), label = ('%s (%d)'):format(p.name, p.grade) }
        end
    end
    return list
end
M.AssignablePositions = AssignablePositions

local function HirePage()
    local near = NearbyPlayers()
    local positions = AssignablePositions()
    local body = { { type = 'text', style = 'desc', text = _L('hire_desc') } }
    if #positions == 0 then
        body[#body + 1] = { type = 'empty', text = _L('no_positions_to_assign') }
        return { title = _L('hire_employee'), body = body }
    end
    if #near > 0 then
        near[#near + 1] = { value = 'manual', label = _L('other_id') }
        body[#body + 1] = { type = 'fco-select', name = 'h_target', label = _L('player_nearby'), options = near, value = near[1].value }
    end
    body[#body + 1] = { type = 'input', name = 'h_id', label = _L('player_server_id'), placeholder = '12', max = 6, optional = #near > 0 }
    body[#body + 1] = { type = 'fco-select', name = 'h_position', label = _L('position'), options = positions, value = positions[#positions].value }
    body[#body + 1] = { type = 'textarea', name = 'h_desc', label = _L('job_description'), max = Config.Contracts.descriptionMax, optional = true, placeholder = _L('job_description_ph') }
    return {
        title = _L('hire_employee'), body = body,
        footer = { main = { label = _L('send_contract'), action = 'm:hire', icon = 'quill' } },
    }
end

local function StaffPage()
    local d = D()
    local rows = {}
    local positions = AssignablePositions()
    for _, e in ipairs(d.staff or {}) do
        local me = e.cid == d.me.cid
        local manageable = not me and not e.boss and (d.boss or e.grade < d.me.grade)
        local actions = {}
        if manageable and P('promote') then actions[#actions + 1] = { label = _L('promote'), icon = 'up', small = true, action = 'm:promote', value = e.cid } end
        if manageable and P('demote') then actions[#actions + 1] = { label = _L('demote'), icon = 'down', small = true, style = 'ghost', action = 'm:demote', value = e.cid } end
        if manageable and P('manage_positions') and #positions > 0 then
            actions[#actions + 1] = { label = _L('change_position'), icon = 'grid', small = true, style = 'ghost', action = 'm:setPosition', value = e.cid,
                prompt = { title = _L('change_position_of', e.name), fields = { { type = 'fco-select', name = 'position', label = _L('position'), options = positions, value = tostring(e.positionId) } } } }
        end
        if e.onDuty and (me or manageable) and P('manage_duty') then
            actions[#actions + 1] = { label = _L('take_off_duty'), icon = 'release', small = true, style = 'ghost', action = 'm:offDuty', value = e.cid }
        end
        if manageable and P('dismiss') then
            actions[#actions + 1] = { label = _L('dismiss'), icon = 'x', small = true, style = 'danger', action = 'm:dismiss', value = e.cid,
                confirm = { title = _L('dismiss'), text = _L('dismiss_confirm', e.name, d.name), danger = true, ok = _L('dismiss'), cancel = _L('cancel') } }
        end
        rows[#rows + 1] = {
            value = e.cid, title = e.name, tag = e.position,
            flag = e.onDuty and { text = _L('on_duty'), tone = 'good' } or nil,
            sub = ('%s · %s'):format(_L('hired_on', e.hired), e.online and _L('online') or _L('offline')),
            details = { { type = 'kv', cols = 3, items = {
                { label = _L('position'), value = e.position, tone = e.boss and 'gold' or nil },
                { label = _L('grade'), value = tostring(e.grade) },
                { label = _L('duty_status'), value = e.onDuty and _L('on_duty') or _L('off_duty'), tone = e.onDuty and 'good' or nil },
            } } },
            actions = actions,
        }
    end
    return { title = _L('employee_list'), count = ('%d / %d'):format(#rows, d.maxEmployees),
             body = { #rows > 0 and { type = 'list', items = rows } or { type = 'empty', text = _L('no_employees') } } }
end

-- positions + editor
local editing = nil      -- position being edited (nil = new)
local editSeq = 0        -- fresh field names per editor (form values survive between pages)

local function PermLabel(key) return _L('perm_' .. key) end

local function PositionsPage()
    local d = D()
    local rows = {}
    for _, p in ipairs(d.positions) do
        local badges = {}
        if p.boss then
            badges[1] = { text = _L('all_permissions'), tone = 'gold' }
        else
            for _, perm in ipairs(Permissions.List) do
                if p.perms[perm.key] then badges[#badges + 1] = { text = PermLabel(perm.key) } end
            end
        end
        local editable = not p.boss and (d.boss or p.grade < d.me.grade)
        local actions = {}
        if editable then
            actions[#actions + 1] = { label = _L('edit'), icon = 'quill', small = true, action = 'm:editPosition', value = p.id }
            actions[#actions + 1] = { label = _L('delete'), icon = 'x', small = true, style = 'danger', action = 'm:deletePosition', value = p.id,
                disabled = p.count > 0,
                confirm = { title = _L('delete_position'), text = _L('delete_position_confirm', p.name), danger = true, ok = _L('delete'), cancel = _L('cancel') } }
        end
        rows[#rows + 1] = {
            value = p.id, title = p.name, tag = _L('grade_n', p.grade),
            flag = p.boss and { text = _L('boss'), tone = 'gold' } or nil,
            sub = _L('n_employees', p.count) .. (p.description and p.description ~= '' and (' · ' .. p.description) or ''),
            details = { #badges > 0 and { type = 'badges', items = badges } or { type = 'text', style = 'note', text = _L('no_permissions') },
                        p.boss and { type = 'text', style = 'note', text = _L('boss_locked') } or nil },
            actions = actions,
        }
    end
    return {
        title = _L('positions'), count = tostring(#rows),
        desc = _L('positions_desc'),
        body = { { type = 'list', items = rows } },
        footer = { main = { label = _L('new_position'), action = 'm:editPosition', icon = 'plus' } },
    }
end

local function EditorPage()
    local d = D()
    local p = editing
    editSeq = editSeq + 1
    local s = editSeq
    local body = {
        { type = 'grid', cols = 2, children = {
            { type = 'input', name = 'pe_name_' .. s, label = _L('position_name'), value = p and p.name or '', max = 40, placeholder = _L('position_name_ph') },
            { type = 'number', name = 'pe_grade_' .. s, label = _L('grade'), value = p and p.grade or 0, min = 0, max = math.max(0, (d.boss and Config.Creation.bossGrade or d.me.grade) - 1), step = 1 },
        } },
        { type = 'input', name = 'pe_desc_' .. s, label = _L('description'), value = p and p.description or '', max = 255, optional = true },
        { type = 'text', style = 'note', text = _L('grade_note') },
    }
    for _, g in ipairs(Permissions.Groups) do
        local opts, on = {}, {}
        for _, perm in ipairs(Permissions.List) do
            if perm.group == g then
                local mine = d.boss or d.perms[perm.key]
                opts[#opts + 1] = { value = perm.key, label = PermLabel(perm.key), disabled = not mine }
                if p and p.perms[perm.key] then on[#on + 1] = perm.key end
            end
        end
        body[#body + 1] = { type = 'section', label = _L('perm_group_' .. g) }
        body[#body + 1] = { type = 'chips', name = ('pe_perm_%s_%d'):format(g, s), options = opts, value = on }
    end
    M.editorSeq = s
    return {
        title = p and _L('edit_position', p.name) or _L('new_position'), body = body,
        footer = { main = { label = _L('save_position'), action = 'm:savePosition', icon = 'check' } },
    }
end

local function SellPage()
    local d = D()
    local M2 = Config.Marketplace
    if d.sale.status == 'for_sale' then
        return { title = _L('sell_company'), body = {
            { type = 'kv', cols = 2, class = 'big', items = {
                { label = _L('sale_status'), value = _L('sale_for_sale'), tone = 'good' },
                { label = _L('price'), value = Fmt(d.sale.price), tone = 'gold' },
            } },
            { type = 'text', style = 'desc', text = d.sale.mine and _L('listing_yours') or _L('listing_admin') },
            d.sale.mine and { type = 'button', wide = true, style = 'danger', icon = 'x', label = _L('cancel_listing'), action = 'm:cancelSale',
                confirm = { title = _L('cancel_listing'), text = _L('cancel_listing_confirm'), ok = _L('cancel_listing'), cancel = _L('back') } } or nil,
        } }
    end
    return { title = _L('sell_company'), body = {
        { type = 'text', style = 'desc', text = _L('sell_desc', Fmt(M2.MinPrice), Fmt(M2.MaxPrice)) },
        { type = 'number', name = 'sale_price', label = _L('price'), value = M2.MinPrice, min = M2.MinPrice, max = M2.MaxPrice, step = 100, quick = { 1000, 5000, 10000 } },
        { type = 'kv', cols = 1, items = {
            { label = _L('sale_payment'), value = _L('sale_payment_cash') },
            { label = _L('sale_after'), value = Config.Marketplace.PreviousOwner == 'demote' and _L('sale_after_demote') or _L('sale_after_dismiss') },
        } },
    }, footer = { main = { label = _L('review_sale'), action = 'm:listSale', icon = 'coin' } } }
end

---------------------------------------------------------------------------
-- Ledger
---------------------------------------------------------------------------
local TX_ICON = { deposit = '+', withdraw = '-', register = '+', store = '+', tax = '-', tax_failed = '!', expense = '-', refund = '±', admin = '±' }

local function LedgerPage()
    local L = M.ledger
    if not L then return { body = { { type = 'empty', text = _L('loading') } } } end
    local rows = {}
    for _, r in ipairs(L.rows) do
        rows[#rows + 1] = {
            value = r.id, title = r.desc or _L('tx_' .. r.type),
            tag = (r.amount >= 0 and '+ ' or '- ') .. Fmt(math.abs(r.amount)),
            flag = r.type == 'tax_failed' and { text = _L('failed'), tone = 'bad' } or nil,
            sub = ('%s · %s · %s'):format(_L('tx_' .. r.type), r.at, r.actor or _L('system')),
            details = { { type = 'kv', cols = 2, items = {
                { label = _L('tx_type'), value = ('%s %s'):format(TX_ICON[r.type] or '', _L('tx_' .. r.type)) },
                { label = _L('amount'), value = Fmt(r.amount), tone = r.amount >= 0 and 'good' or 'bad' },
                { label = _L('balance_before'), value = Fmt(r.before) },
                { label = _L('balance_after'), value = Fmt(r.after) },
                { label = _L('responsible'), value = r.actor or _L('system') },
                { label = _L('date'), value = r.at },
            } }, r.desc and { type = 'text', style = 'note', text = r.desc } or nil },
        }
    end
    local quick = { 10, 100, 1000 }
    local buttons = {}
    if P('deposit') then
        buttons[#buttons + 1] = { type = 'button', icon = 'plus', label = _L('deposit'), action = 'm:deposit',
            prompt = { title = _L('deposit'), text = _L('deposit_text', Fmt(D().cash)), fields = { { type = 'number', name = 'amount', label = _L('amount'), value = 10, min = 0.01, max = Config.Finance.maxTransaction, step = 1, quick = quick } } } }
    end
    if P('withdraw') then
        buttons[#buttons + 1] = { type = 'button', icon = 'minus', style = 'ghost', label = _L('withdraw'), action = 'm:withdraw',
            prompt = { title = _L('withdraw'), text = _L('withdraw_text', Fmt(L.balance)), fields = { { type = 'number', name = 'amount', label = _L('amount'), value = 10, min = 0.01, max = Config.Finance.maxTransaction, step = 1, quick = quick } } } }
    end
    local nav = {}
    if L.page > 1 then nav[#nav + 1] = { type = 'button', small = true, style = 'ghost', icon = 'left', label = _L('newer'), action = 'm:ledgerPage', value = L.page - 1 } end
    if L.page < L.pages then nav[#nav + 1] = { type = 'button', small = true, style = 'ghost', iconRight = 'right', label = _L('older'), action = 'm:ledgerPage', value = L.page + 1 } end
    return {
        count = _L('page_of', L.page, L.pages),
        body = {
            { type = 'kv', cols = 3, class = 'big', items = {
                { label = _L('balance'), value = Fmt(L.balance), tone = 'gold' },
                { label = _L('total_income'), value = Fmt(L.income), tone = 'good' },
                { label = _L('total_expenses'), value = Fmt(L.expenses), tone = 'bad' },
            } },
            { type = 'kv', cols = 2, items = {
                { label = _L('auto_tax'), value = L.tax and (L.tax.type == 'percent' and _L('tax_short_percent', L.tax.amount, Co.Every(L.tax.interval))
                    or _L('tax_short_fixed', Fmt(L.tax.amount), Co.Every(L.tax.interval))) or _L('no_taxes'), tone = L.tax and 'bad' or 'good' },
                { label = _L('next_tax'), value = L.tax and L.tax.nextAt or '-' },
            } },
            #buttons > 0 and { type = 'row', align = 'center', children = buttons } or nil,
            { type = 'section', label = _L('history') },
            { type = 'text', style = 'note', text = _L('ledger_help') },
            #rows > 0 and { type = 'list', items = rows } or { type = 'empty', text = _L('no_transactions') },
            #nav > 0 and { type = 'row', align = 'center', children = nav } or nil,
        },
    }
end

local function FetchLedger(page)
    local ok, L = Call('ledger', D().id, page or M.page)
    if ok then M.ledger, M.page = L, L.page end
    return ok, L
end

---------------------------------------------------------------------------
-- View
---------------------------------------------------------------------------
function M.View()
    local d = D()
    local tabs, pages = {}, {}
    tabs[#tabs + 1] = { page = 'general', label = _L('tab_general') }
    pages.general = GeneralPage()
    local manage = P('hire') or d.staff or P('manage_positions') or d.boss
    if manage then
        tabs[#tabs + 1] = { page = 'management', label = _L('tab_management') }
        pages.management = ManagementPage()
        pages.hire = HirePage()
        pages.staff = StaffPage()
        pages.positions = PositionsPage()
        pages.editor = EditorPage()
        pages.sell = SellPage()
    end
    if P('access_ledger') then
        tabs[#tabs + 1] = { page = 'ledger', label = _L('tab_ledger') }
        pages.ledger = LedgerPage()
    end
    if M.CustomAllowed() then
        tabs[#tabs + 1] = { page = 'customization', label = _L('tab_customization') }
        for id, pg in pairs(M.CustomPages()) do pages[id] = pg end
    end
    return {
        eyebrow = _L('company'), title = d.name, page = M.startPage and pages[M.startPage] and M.startPage or 'general',
        tabs = tabs, pages = pages, layout = 'wide',       -- landscape panel, like /managecompanies
        footer = { money = { cash = d.cash } },
        hints = { { 'ESC', _L('close') } },
    }
end

---------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------
UI.On('m:noop', function() end)

-- ledger loads when its tab is opened
OnUIPage(function(d)
    if ActiveView ~= 'management' then return end
    if d.to == 'ledger' then
        local ok, err = FetchLedger(1)
        if not ok then return { ok = false, error = err } end
        return { page = LedgerPage() }
    end
    if d.to == 'hire' then return { page = HirePage() } end
    if M.OnPage then return M.OnPage(d) end
end)

UI.On('m:ledgerPage', function(d)
    local ok, err = FetchLedger(tonumber(d.value))
    if not ok then return { ok = false, error = err } end
    return { page = LedgerPage() }
end)

local function Money(name, d)
    local amount = tonumber((d.values or {}).amount)
    local ok, msg = Call(name, D().id, amount)
    if not ok then return { ok = false, error = msg } end
    PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0)
    M.Fetch()
    FetchLedger(1)
    return { toast = { text = msg, type = 'success' }, view = M.View() }
end
UI.On('m:deposit', function(d) return Money('deposit', d) end)
UI.On('m:withdraw', function(d) return Money('withdraw', d) end)

UI.On('m:description', function(d)
    local ok, msg = Call('description', D().id, (d.values or {}).text or '')
    return M.Done(ok, msg)
end)

UI.On('m:quit', function()
    local ok, msg = Call('staff:quit', D().id)
    if not ok then return { ok = false, error = msg } end
    M.Close()
    return { toast = { text = msg, type = 'inform' }, close = true }
end)

UI.On('m:hire', function(d)
    local v = d.values or {}
    local target = v.h_target and v.h_target ~= 'manual' and v.h_target or v.h_id
    if not tonumber(target) then return { ok = false, error = _L('invalid_target'), errors = { h_id = _L('invalid_target') } } end
    local ok, msg = Call('hire', D().id, tonumber(target), tonumber(v.h_position), v.h_desc)
    if not ok then return { ok = false, error = msg } end
    return { toast = { text = msg, type = 'success' }, back = true }
end)

local function Staff(name, d, extra)
    local ok, msg = Call(name, D().id, d.value, extra)
    return M.Done(ok, msg)
end
UI.On('m:promote', function(d) return Staff('staff:promote', d) end)
UI.On('m:demote', function(d) return Staff('staff:demote', d) end)
UI.On('m:dismiss', function(d) return Staff('staff:dismiss', d) end)
UI.On('m:offDuty', function(d) return Staff('staff:offDuty', d) end)
UI.On('m:setPosition', function(d) return Staff('staff:setPosition', d, tonumber((d.values or {}).position)) end)

UI.On('m:editPosition', function(d)
    editing = nil
    for _, p in ipairs(D().positions) do if p.id == tonumber(d.value) then editing = p end end
    return { go = 'editor', data = EditorPage() }
end)

UI.On('m:savePosition', function(d)
    local v, s = d.values or {}, M.editorSeq
    local perms = {}
    for _, g in ipairs(Permissions.Groups) do
        for _, k in ipairs(v[('pe_perm_%s_%d'):format(g, s)] or {}) do perms[k] = true end
    end
    local name = v['pe_name_' .. s]
    if not name or name == '' then return { ok = false, error = _L('invalid_position_name'), errors = { ['pe_name_' .. s] = _L('invalid_position_name') } } end
    local ok, msg = Call('position:save', D().id, {
        id = editing and editing.id or nil, name = name, grade = tonumber(v['pe_grade_' .. s]), description = v['pe_desc_' .. s], perms = perms,
    })
    if not ok then return { ok = false, error = msg } end
    local res = M.Done(ok, msg)
    res.back = true
    return res
end)

UI.On('m:deletePosition', function(d)
    local ok, msg = Call('position:delete', D().id, d.value)
    return M.Done(ok, msg)
end)

UI.On('m:listSale', function(d)
    local price = tonumber((d.values or {}).sale_price)
    if not price then return { ok = false, error = _L('invalid_price') } end
    local sure = UI.Confirm({ title = _L('confirm_sale'), text = _L('confirm_sale_text', D().name, Fmt(price)), ok = _L('list_for_sale'), cancel = _L('cancel') })
    if not sure then return end
    local ok, msg = Call('sale:list', D().id, price)
    return M.Done(ok, msg)
end)

UI.On('m:cancelSale', function()
    local ok, msg = Call('sale:cancel', D().id)
    return M.Done(ok, msg)
end)

OnUIClose(function()
    M.D, M.ledger, M.startPage = nil, nil, nil
end)

function M.Close()
    M.D, M.ledger = nil, nil
end

-- opens the window (startPage = tab to land on, e.g. after placing something)
function Management.Open(startPage)
    local ok, err = M.Fetch()
    if not ok then return Notify(err, 'error') end
    M.startPage = startPage
    if not OpenView('management', M.View(), { hideHud = false }) then return end
    PlaySoundFrontend('INFO', 'HUD_SHOP_SOUNDSET', true, 0)
    local c = Companies[M.D.id]
    if c then
        CloseWhenAway(vector3(c.coords.x, c.coords.y, c.coords.z), Config.Placement.maxDistance + 10.0, function() return ActiveView == 'management' end)
    end
    if startPage == 'ledger' then
        FetchLedger(1)
        UI.SetPage('ledger', LedgerPage())
    end
end

-- someone changed my position / permissions while the window is open: rebuild it
AddEventHandler('fks-companies:client:meChanged', function(me)
    if ActiveView ~= 'management' or not M.D then return end
    if not me.company or me.company ~= M.D.id or not me.active then UI.Close() return end
    if M.Fetch() then UI.Update(M.View()) end
end)
