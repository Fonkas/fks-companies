---------------------------------------------------------------------------
-- Cash register (client): go on / off duty and charge a customer. Drawn by fks-core.
---------------------------------------------------------------------------
Register = {}

local current = nil      -- company id while the register window is open

local function NearbyPlayers()
    local list = {}
    local me = PlayerId()
    local pos = GetEntityCoords(PlayerPedId())
    for _, pl in ipairs(GetActivePlayers()) do
        if pl ~= me then
            local d = #(GetEntityCoords(GetPlayerPed(pl)) - pos)
            if d <= Config.Billing.maxDistance then
                list[#list + 1] = { value = tostring(GetPlayerServerId(pl)), label = ('%s · %d m'):format(GetPlayerServerId(pl), math.floor(d)) }
            end
        end
    end
    table.sort(list, function(a, b) return tonumber(a.value) < tonumber(b.value) end)
    return list
end

local function View()
    local c = Companies[current]
    local body = {
        { type = 'kv', cols = 2, class = 'big', items = {
            { label = _L('duty_status'), value = Me.onDuty and _L('on_duty') or _L('off_duty'), tone = Me.onDuty and 'good' or 'bad' },
            { label = _L('employees_on_duty'), value = tostring(c and c.onDuty or 0) },
        } },
        { type = 'button', wide = true, icon = Me.onDuty and 'release' or 'check', label = Me.onDuty and _L('go_off_duty') or _L('go_on_duty'),
          action = 'r:duty', value = not Me.onDuty, style = Me.onDuty and 'ghost' or nil },
    }
    if c and c.store.enabled and Config.Store.RequireZeroEmployeesOnDuty then
        body[#body + 1] = { type = 'text', style = 'note', text = _L('duty_store_note') }
    end
    if Can('charge_customers') then
        local near = NearbyPlayers()
        body[#body + 1] = { type = 'section', label = _L('charge_customer') }
        body[#body + 1] = { type = 'text', style = 'desc', text = _L('charge_desc') }
        if #near > 0 then
            body[#body + 1] = { type = 'fco-select', name = 'target', label = _L('customer_nearby'), options = near, value = near[1].value }
        else
            body[#body + 1] = { type = 'input', name = 'target', label = _L('customer_id'), placeholder = '12', max = 6 }
        end
        body[#body + 1] = { type = 'number', name = 'amount', label = _L('amount'), value = 1, min = 0.01, max = Config.Finance.maxTransaction, step = 1, quick = { 5, 10, 50, 100 } }
        body[#body + 1] = { type = 'input', name = 'desc', label = _L('payment_desc'), max = Config.Billing.descriptionMax, optional = true, placeholder = _L('payment_desc_ph') }
        body[#body + 1] = { type = 'button', wide = true, icon = 'coin', label = _L('send_bill'), action = 'r:charge', requires = 'target' }
    end
    return { eyebrow = c and c.name or '', title = _L('loc_register'), subtitle = _L('register_sub'), body = body, hints = { { 'ESC', _L('close') } } }
end

UI.On('r:duty', function(d)
    local ok, msg = Call('duty', current, d.value == true)
    if not ok then return { ok = false, error = msg } end
    Wait(150)   -- the personal state arrives right behind the answer
    return { toast = { text = msg, type = 'success' }, view = View() }
end)

UI.On('r:charge', function(d)
    local v = d.values or {}
    local ok, msg = Call('charge', current, tonumber(v.target), tonumber(v.amount), v.desc)
    if not ok then return { ok = false, error = msg } end
    return { toast = { text = msg, type = 'success' } }
end)

OnUIClose(function() current = nil end)

function Register.Open(id)
    local c = Companies[id]
    if not c or not c.locations.register then return end
    current = id
    if not OpenView('register', View()) then current = nil return end
    local l = c.locations.register
    CloseWhenAway(vector3(l.x, l.y, l.z), Config.Interact.distance + 3.0, function() return current == id and ActiveView == 'register' end)
end

-- the duty state changed while the window is open (forced off, distance...)
AddEventHandler('fks-companies:client:meChanged', function()
    if current and ActiveView == 'register' then UI.Update(View()) end
end)
