---------------------------------------------------------------------------
-- Server state: every company lives in memory (loaded once from the database) and that memory is the
-- authoritative state. Changes are validated, written to the database, applied to memory and then
-- synchronised to the clients:
--   * public state (name, blip, points, duty count, store open) -> every client
--   * personal state (my company, my position, my permissions, my duty) -> only that player
-- Financial data never goes into the public state.
---------------------------------------------------------------------------
Companies = {}           -- [id] = company
EmployeeOf = {}          -- [cid] = companyId (one company per character)
Loaded = false

local RES = GetCurrentResourceName()

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
function Notify(src, msg, kind, title)
    Bridge.Notify(src, { title = title or _L('companies'), description = msg, type = kind or 'inform' })
end

function Debug(...)
    if Config.Debug then print(('[fks-companies] ' .. select(1, ...)):format(select(2, ...))) end
end

-- per-key mutex: financial / ownership / stock operations of one company never run at the same time
local locks = {}
function WithLock(key, fn, ...)
    local waited = 0
    while locks[key] do
        Wait(0)
        waited = waited + 1
        if waited > 3000 then return false, _L('busy') end     -- ~ a few seconds: never hang a callback
    end
    locks[key] = true
    local res = table.pack(pcall(fn, ...))
    locks[key] = nil
    if not res[1] then
        print(('^1[fks-companies] %s failed: %s^0'):format(tostring(key), tostring(res[2])))
        return false, _L('error')
    end
    return table.unpack(res, 2, res.n)
end

-- anti-spam per player per action
local lastCall = {}
local function Limited(src, name)
    local now = GetGameTimer()
    local t = lastCall[src]
    if not t then t = {} lastCall[src] = t end
    if t[name] and now - t[name] < (Config.RateLimit or 400) then return true end
    t[name] = now
    return false
end

-- callback with rate limit + loaded character: fn(src, P, ...) -> ok, result...
function Callback(name, fn, opts)
    lib.callback.register('fks-companies:' .. name, function(src, ...)
        if not (opts and opts.noLimit) and Limited(src, name) then return false, _L('too_fast') end
        local P = Bridge.GetPlayer(src)
        if not P then return false, _L('no_character') end
        local res = table.pack(pcall(fn, src, P, ...))
        if not res[1] then
            print(('^1[fks-companies] callback %s failed: %s^0'):format(name, tostring(res[2])))
            return false, _L('error')
        end
        return table.unpack(res, 2, res.n)
    end)
end

function Actor(P) return { cid = tostring(P.cid), name = P.name } end

function PedCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

function Near(src, c, dist)
    local pos = PedCoords(src)
    return pos ~= nil and c ~= nil and #(pos - vector3(c.x, c.y, c.z)) <= dist
end

function Vec(c) return vector3(c.x, c.y, c.z) end

---------------------------------------------------------------------------
-- Building companies from rows
---------------------------------------------------------------------------
local function Num(v) return tonumber(v) or 0 end
local function Bool(v) return v == true or v == 1 or v == '1' end

function Company(id) return Companies[tonumber(id) or -1] end

local function FromRow(r)
    return {
        id = r.id, code = r.code, name = r.name, job = r.job, description = r.description,
        owner = r.owner_cid and { cid = tostring(r.owner_cid), name = r.owner_name } or nil,
        coords = { x = r.x, y = r.y, z = r.z, h = r.heading or 0.0 },
        blip = Num(r.blip),
        balance = Co.Money(r.balance) or 0, income = Co.Money(r.total_income) or 0, expenses = Co.Money(r.total_expenses) or 0,
        maxEmployees = Num(r.max_employees),
        status = r.status, statusReason = r.status_reason,
        tax = { enabled = Bool(r.tax_enabled), type = r.tax_type, amount = Co.Money(r.tax_amount) or 0,
                interval = Num(r.tax_interval), nextAt = r.tax_next_at, failures = Num(r.tax_failures) },
        storage = { boss = { slots = Num(r.boss_slots), weight = Num(r.boss_weight) },
                    general = { slots = Num(r.general_slots), weight = Num(r.general_weight) } },
        store = { enabled = Bool(r.store_enabled), model = r.store_model },
        sale = { status = r.sale_status, price = Co.Money(r.sale_price) or 0, negotiable = Bool(r.sale_negotiable),
                 public = Bool(r.sale_public), seller = r.sale_seller_cid and tostring(r.sale_seller_cid) or nil, listedAt = r.sale_listed_at },
        createdBy = r.created_by, createdAt = r.created_at,
        positions = {}, employees = {}, locations = {}, products = {}, duty = {},
    }
end

function PositionFromRow(r)
    local ok, perms = pcall(json.decode, r.permissions or '{}')
    return { id = r.id, name = r.name, grade = Num(r.grade), isBoss = Bool(r.is_boss), description = r.description,
             perms = Permissions.Clean(ok and perms or {}) }
end

function EmployeeFromRow(r)
    return { id = r.id, cid = tostring(r.cid), name = r.name, positionId = r.position_id, hiredAt = r.hired_at, contractId = r.contract_id }
end

function LocationFromRow(r)
    return { x = r.x, y = r.y, z = r.z, h = r.heading or 0.0, model = r.model }
end

function ProductFromRow(r)
    return { id = r.id, item = r.item, label = r.label, quantity = Num(r.quantity), price = Co.Money(r.price) or 0,
             description = r.description, listedBy = r.listed_by_name, listedAt = r.listed_at, img = nil }
end

function AddCompanyFromRow(r)
    local c = FromRow(r)
    Companies[c.id] = c
    return c
end

---------------------------------------------------------------------------
-- Derived state
---------------------------------------------------------------------------
function BossPosition(c)
    for _, p in pairs(c.positions) do if p.isBoss then return p end end
end

function DutyCount(c)
    local n = 0
    for _ in pairs(c.duty) do n = n + 1 end
    return n
end

function EmployeeCount(c)
    local n = 0
    for _ in pairs(c.employees) do n = n + 1 end
    return n
end

function IsActive(c) return c and c.status == 'active' end

-- is the NPC store selling right now?
function StoreOpen(c)
    if not Config.Store.Enabled or not IsActive(c) or not c.store.enabled or not c.locations.store then return false end
    if Config.Store.RequireZeroEmployeesOnDuty and DutyCount(c) > 0 then return false end
    return true
end

-- what every client may know about a company
function PublicState(c)
    local locs = {}
    for kind, l in pairs(c.locations) do locs[kind] = { x = l.x, y = l.y, z = l.z, h = l.h, model = l.model } end
    return {
        id = c.id, name = c.name, job = c.job, blip = c.blip, coords = c.coords, status = c.status,
        onDuty = DutyCount(c), locations = locs,
        store = { enabled = c.store.enabled, open = StoreOpen(c), model = c.store.model or Config.Store.DefaultModel },
        forSale = Config.Marketplace.Enabled and IsActive(c) and c.sale.status == 'for_sale' or false,
    }
end

---------------------------------------------------------------------------
-- Synchronisation
---------------------------------------------------------------------------
local pending, flushing = {}, false

-- coalesces several changes of the same company in one tick into one event
function Sync(c)
    if not c or not Config.CompanySync.Enabled then return end
    pending[c.id] = true
    if flushing then return end
    flushing = true
    SetTimeout(0, function()
        for id in pairs(pending) do
            local co = Companies[id]
            if co then TriggerClientEvent('fks-companies:client:company', -1, id, PublicState(co)) end
        end
        pending, flushing = {}, false
        TriggerEvent('fks-companies:server:synced')
    end)
end

function SyncRemove(id)
    TriggerClientEvent('fks-companies:client:remove', -1, id)
end

function FullState()
    local list = {}
    for _, c in pairs(Companies) do list[#list + 1] = PublicState(c) end
    return list
end

-- the personal state of one player: company, position, permissions, duty
function Me(src)
    local P = Bridge.GetPlayer(src)
    if not P then return nil end
    local cid = tostring(P.cid)
    local c = Companies[EmployeeOf[cid]]
    if not c then return { cid = cid } end
    local e = c.employees[cid]
    local pos = e and c.positions[e.positionId]
    return {
        cid = cid, company = c.id, companyName = c.name, position = pos and pos.name, grade = pos and pos.grade,
        boss = pos and pos.isBoss or false, perms = PermsOf(c, cid), onDuty = c.duty[cid] ~= nil, active = IsActive(c),
    }
end

function SyncMe(src)
    if src then TriggerClientEvent('fks-companies:client:me', src, Me(src)) end
end

function SyncMeCid(cid)
    local src = Framework.Online(cid)
    if src then SyncMe(src) end
end

-- everyone in a company (after a position / permission change)
function SyncCompanyMembers(c)
    for cid in pairs(c.employees) do SyncMeCid(cid) end
end

lib.callback.register('fks-companies:state', function(src)
    while not Loaded do Wait(100) end
    return FullState(), Me(src)
end)

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------
CreateThread(function()
    local data = DB.LoadAll()
    for _, r in ipairs(data.companies) do AddCompanyFromRow(r) end
    for _, r in ipairs(data.positions) do
        local c = Companies[r.company_id]
        if c then c.positions[r.id] = PositionFromRow(r) end
    end
    for _, r in ipairs(data.employees) do
        local c = Companies[r.company_id]
        if c then
            local e = EmployeeFromRow(r)
            c.employees[e.cid] = e
            EmployeeOf[e.cid] = c.id
        end
    end
    for _, r in ipairs(data.locations) do
        local c = Companies[r.company_id]
        if c then c.locations[r.kind] = LocationFromRow(r) end
    end
    for _, r in ipairs(data.products) do
        local c = Companies[r.company_id]
        if c then c.products[r.item] = ProductFromRow(r) end
    end
    Loaded = true
    local n = 0
    for _ in pairs(Companies) do n = n + 1 end
    print(('[fks-companies] loaded ^2%d^0 companies'):format(n))
    TriggerEvent('fks-companies:server:loaded')
    TriggerClientEvent('fks-companies:client:refresh', -1)
end)

-- character loaded: their state, their job (if it drifted), pending payouts, contracts
Bridge.OnCharacterLoaded(function(src)
    CreateThread(function()
        while not Loaded do Wait(200) end
        Wait(1500)  -- let the framework finish loading the character
        local P = Bridge.GetPlayer(src)
        if not P then return end
        local cid = tostring(P.cid)
        local c = Companies[EmployeeOf[cid]]
        if c then
            local e = c.employees[cid]
            local pos = e and c.positions[e.positionId]
            e.name = P.name
            if Config.Jobs.syncOnLoad and pos and (P.job ~= c.job or tonumber(P.grade) ~= pos.grade) then
                Framework.SetJob(src, c.job, pos.grade, c.name)
            end
        end
        SyncMe(src)
        TriggerEvent('fks-companies:server:characterLoaded', src, cid)
    end)
end)

AddEventHandler('playerDropped', function()
    lastCall[source] = nil
end)

---------------------------------------------------------------------------
-- Exports for other resources (read only)
---------------------------------------------------------------------------
exports('GetCompany', function(id)
    local c = Company(id)
    return c and PublicState(c) or nil
end)
exports('GetPlayerCompany', function(src)
    return Me(src)
end)
exports('IsOnDuty', function(src)
    local m = Me(src)
    return m and m.onDuty or false
end)

---------------------------------------------------------------------------
-- fks-core missing / version check
---------------------------------------------------------------------------
CreateThread(function()
    local state = GetResourceState('fks-core')
    if not Bridge or (state ~= 'started' and state ~= 'starting') then
        print('^1================================================================^0')
        print(('^1[%s] MISSING REQUIRED DEPENDENCY: fks-core^0 (%s)'):format(RES, state))
        print(('^1[%s]^0 download: %s'):format(RES, Config.VersionCheck.coreUrl))
        print(('^1[%s]^0 then add ^3ensure fks-core^0 before ^3ensure %s^0 in server.cfg'):format(RES, RES))
        print('^1================================================================^0')
        return
    end
    if Config.VersionCheck.enabled then
        Bridge.CheckVersion(Config.VersionCheck.repo, { branch = Config.VersionCheck.branch, interval = Config.VersionCheck.interval })
    end
end)
