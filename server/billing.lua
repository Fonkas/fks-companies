---------------------------------------------------------------------------
-- Cash register: duty and charging customers.
--
-- Duty lives on the server (c.duty[cid] = src) and on the player's state bag (Player(src).state.fksDuty),
-- which survives a restart of this resource: on start the duty of every connected player is restored if it is
-- still valid (still employed, company active, close enough) and dropped otherwise. Leaving the server,
-- changing character, being dismissed, moving away or a suspended company take the player off duty.
---------------------------------------------------------------------------

-- the only place duty changes. reason: nil (by hand) | 'distance' | 'dropped' | 'dismissed' | 'inactive' | 'forced' | 'relog'
function SetDuty(c, cid, on, reason)
    cid = tostring(cid)
    local src = on and Framework.Online(cid) or c.duty[cid]
    if on then
        if not src then return false end
        -- on duty somewhere else? (cannot happen with one job, but never trust it)
        for _, other in pairs(Companies) do
            if other.id ~= c.id and other.duty[cid] then other.duty[cid] = nil Sync(other) end
        end
        c.duty[cid] = src
    else
        if not c.duty[cid] then return false end
        c.duty[cid] = nil
    end
    if src and GetPlayerName(src) then
        Player(src).state:set('fksDuty', on and { company = c.id, cid = cid } or nil, false)
        Framework.SetDuty(src, on)
        SyncMe(src)
        if reason == 'distance' then Notify(src, _L('duty_off_distance', math.floor(Config.Duty.maxDistance)), 'warning')
        elseif reason == 'forced' then Notify(src, _L('duty_off_forced'), 'warning')
        elseif reason == 'inactive' then Notify(src, _L('duty_off_inactive'), 'warning') end
    end
    Sync(c)
    if on then StoreClosedForViewers(c) end
    TriggerEvent('fks-companies:server:duty', c.id, cid, on, reason)
    return true
end

Callback('duty', function(src, P, companyId, on)
    local c, cid = Access(src, P, companyId)
    if not c then return false, cid end
    local reg = c.locations.register
    if not reg then return false, _L('no_register') end
    if not Near(src, reg, Config.Interact.distance + 2.5) then return false, _L('too_far') end
    on = on == true
    if (c.duty[cid] ~= nil) == on then return false, on and _L('already_on_duty') or _L('not_on_duty') end
    SetDuty(c, cid, on)
    DB.Activity(c.id, on and 'duty_on' or 'duty_off', Actor(P), _L(on and 'act_duty_on' or 'act_duty_off', P.name))
    return true, on and _L('duty_on') or _L('duty_off')
end)

-- distance / relog checks: only players on duty, every Config.Duty.checkInterval seconds
CreateThread(function()
    while not Loaded do Wait(500) end
    while true do
        Wait(math.max(2, Config.Duty.checkInterval) * 1000)
        for _, c in pairs(Companies) do
            for cid, src in pairs(c.duty) do
                local P = GetPlayerName(src) and Bridge.GetPlayer(src)
                if not P or tostring(P.cid) ~= cid or not c.employees[cid] then
                    SetDuty(c, cid, false, 'relog')
                else
                    local pos = PedCoords(src)
                    if pos and #(pos - Vec(c.coords)) > Config.Duty.maxDistance then SetDuty(c, cid, false, 'distance') end
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, c in pairs(Companies) do
        for cid, s in pairs(c.duty) do
            if s == src then SetDuty(c, cid, false, 'dropped') end
        end
    end
end)

-- RSG character logout (back to the selection screen)
RegisterNetEvent('RSGCore:Server:OnPlayerUnload', function()
    local src = source
    for _, c in pairs(Companies) do
        for cid, s in pairs(c.duty) do
            if s == src then SetDuty(c, cid, false, 'relog') end
        end
    end
end)

-- a new character on the same player: whatever duty the old one had is gone
AddEventHandler('fks-companies:server:characterLoaded', function(src, cid)
    for _, c in pairs(Companies) do
        for dcid, s in pairs(c.duty) do
            if s == src and dcid ~= cid then SetDuty(c, dcid, false, 'relog') end
        end
    end
    local st = Player(src).state.fksDuty
    if st and st.cid ~= cid then Player(src).state:set('fksDuty', nil, false) end
end)

-- restart of this resource: restore valid duty from the state bags
AddEventHandler('fks-companies:server:loaded', function()
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local st = Player(src).state.fksDuty
        if type(st) == 'table' then
            local c = Companies[tonumber(st.company)]
            local P = Bridge.GetPlayer(src)
            local pos = PedCoords(src)
            if c and P and IsActive(c) and tostring(P.cid) == st.cid and c.employees[st.cid] and pos and #(pos - Vec(c.coords)) <= Config.Duty.maxDistance then
                c.duty[st.cid] = src
                Sync(c)
            else
                Player(src).state:set('fksDuty', nil, false)
                Framework.SetDuty(src, false)
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Charging a customer: employee at the register -> payment request -> customer accepts -> cash to company
---------------------------------------------------------------------------
local Bills = {}          -- [id] = { company, from, fromCid, fromName, to, toCid, amount, desc, expires }
local billSeq = 0
local lastBill = {}       -- [src] = os.time() of the last request

local function OpenBillFor(target)
    for id, b in pairs(Bills) do if b.to == target then return id end end
end

Callback('charge', function(src, P, companyId, target, amount, desc)
    local c, cid = Access(src, P, companyId, { perm = 'charge_customers' })
    if not c then return false, cid end
    local reg = c.locations.register
    if not reg or not Near(src, reg, Config.Interact.distance + 2.5) then return false, _L('too_far') end
    if lastBill[src] and os.time() - lastBill[src] < Config.Billing.cooldown then return false, _L('too_fast') end

    target = tonumber(target)
    if not target or target == src or not GetPlayerName(target) then return false, _L('invalid_target') end
    local T = Bridge.GetPlayer(target)
    if not T then return false, _L('player_offline') end
    if not Near(src, PedCoords(target), Config.Billing.maxDistance) then return false, _L('target_far') end
    amount = Finance.Amount(amount)
    if not amount then return false, _L('invalid_amount') end
    if OpenBillFor(target) then return false, _L('bill_pending') end

    billSeq = billSeq + 1
    local id = billSeq
    local text = Co.Text(desc, Config.Billing.descriptionMax, 0) or ''
    Bills[id] = {
        id = id, company = c.id, from = src, fromCid = cid, fromName = P.name, to = target, toCid = tostring(T.cid), toName = T.name,
        amount = amount, desc = text, expires = os.time() + Config.Billing.expiration,
    }
    lastBill[src] = os.time()
    TriggerClientEvent('fks-companies:client:bill', target, {
        id = id, company = c.name, code = c.code, employee = P.name, amount = amount, desc = text,
        seconds = Config.Billing.expiration, number = ('%s-%06d'):format(c.code, id), date = os.date('%d / %m / %Y'),
    })
    return true, _L('bill_sent', Co.Fmt(amount), T.name)
end)

Callback('bill:answer', function(src, P, id, accept)
    local b = Bills[tonumber(id) or -1]
    if not b or b.to ~= src or b.toCid ~= tostring(P.cid) then return false, _L('bill_invalid') end
    Bills[b.id] = nil      -- one answer only
    local c = Companies[b.company]
    local function tell(msg, kind) if GetPlayerName(b.from) then Notify(b.from, msg, kind) end end

    if os.time() > b.expires then tell(_L('bill_expired_for', P.name), 'warning') return false, _L('bill_expired') end
    if not accept then tell(_L('bill_declined_by', P.name), 'error') return true, _L('bill_declined') end
    if not IsActive(c) then return false, _L('company_inactive') end

    return WithLock(Finance.Key(c), function()
        if P.money('cash') + 0.0001 < b.amount then
            tell(_L('bill_no_cash', P.name), 'error')
            return false, _L('not_enough_cash')
        end
        if not P.remove('cash', b.amount, 'fks-companies bill') then return false, _L('not_enough_cash') end
        local desc = b.desc ~= '' and _L('tx_register_desc', P.name, b.desc) or _L('tx_register_plain', P.name)
        local ok, e = Finance.Apply(c, b.amount, 'register', { cid = b.fromCid, name = b.fromName }, desc)
        if not ok then
            P.add('cash', b.amount, 'fks-companies bill refund')
            return false, e
        end
        DB.Activity(c.id, 'register', { cid = b.fromCid, name = b.fromName }, _L('act_register', b.fromName, Co.Fmt(b.amount), P.name))
        tell(_L('bill_paid_by', P.name, Co.Fmt(b.amount)), 'success')
        return true, _L('bill_paid', Co.Fmt(b.amount), c.name)
    end)
end)

CreateThread(function()
    while true do
        Wait(5000)
        local now = os.time()
        for id, b in pairs(Bills) do
            if now > b.expires then
                Bills[id] = nil
                TriggerClientEvent('fks-companies:client:billClosed', b.to, id)
                if GetPlayerName(b.from) then Notify(b.from, _L('bill_expired_for', b.toName), 'warning') end
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastBill[src] = nil
    for id, b in pairs(Bills) do
        if b.to == src or b.from == src then Bills[id] = nil end
    end
end)
