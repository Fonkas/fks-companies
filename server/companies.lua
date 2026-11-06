---------------------------------------------------------------------------
-- Companies: creation (admin), status, ownership, placed points, identity (name / blip), storages and the
-- data of the management window.
---------------------------------------------------------------------------
local LOC_KINDS = { boss_storage = true, general_storage = true, register = true, store = true }

local function Clamp(v, lo, hi, def)
    v = math.floor(tonumber(v) or def)
    return math.max(lo, math.min(hi, v))
end

local function ValidJob(job)
    return type(job) == 'string' and job:match('^[%w_%-]+$') and #job <= 60
end

local function ValidCode(code)
    return type(code) == 'string' and code:match('^[%w_%-]+$') and #code >= 2 and #code <= 32
end

function CodeTaken(code, exceptId)
    for _, c in pairs(Companies) do
        if c.code:lower() == code:lower() and c.id ~= exceptId then return true end
    end
    local id = MySQL.scalar.await('SELECT id FROM fks_companies WHERE code = ?', { code })
    return id ~= nil and id ~= exceptId
end

-- normalises the tax settings sent by the admin UI
function ParseTax(d)
    local t = type(d) == 'table' and d or {}
    local def = Config.Taxes.default
    local kind = t.type == 'percent' and 'percent' or 'fixed'
    local amount = Co.Money(t.amount) or def.amount
    if kind == 'percent' then amount = math.max(0, math.min(100, amount)) else amount = math.max(0, math.min(Config.Finance.maxTransaction, amount)) end
    return {
        enabled = t.enabled == true and Config.Taxes.enabled,
        type = kind, amount = amount,
        interval = Clamp(t.interval, Config.Taxes.minInterval, 60 * 24 * 60, def.interval),
    }
end

function ParseStorage(d)
    d = type(d) == 'table' and d or {}
    local S = Config.Storage
    local function one(v, def)
        v = type(v) == 'table' and v or {}
        -- no configured limit: still an INT the inventories can handle
        return { slots = Clamp(v.slots, 1, S.maxSlots or 1000000, def.slots), weight = Clamp(v.weight, 1, S.maxWeight or 2000000000, def.weight) }
    end
    return { boss = one(d.boss, S.boss), general = one(d.general, S.general) }
end

function ParseSale(d)
    d = type(d) == 'table' and d or {}
    local M = Config.Marketplace
    local price = Co.Money(d.price) or 0
    local forSale = d.forSale == true and M.Enabled
    if forSale and (price < M.MinPrice or price > M.MaxPrice) then return nil end
    return { forSale = forSale, price = math.max(0, price), negotiable = d.negotiable == true, public = d.public ~= false }
end

---------------------------------------------------------------------------
-- Positions of a new company: Boss + Config.Creation.defaultPositions
---------------------------------------------------------------------------
local function DefaultPositionQueries(id, job)
    local list = { { query = 'INSERT INTO fks_company_positions (company_id, name, grade, is_boss, permissions) VALUES (?, ?, ?, 1, ?)',
                     values = { id, Config.Creation.bossName, Config.Creation.bossGrade, json.encode(Permissions.All()) } } }
    for _, p in ipairs(Config.Creation.defaultPositions or {}) do
        -- RSG: only grades that exist in rsg-core/shared/jobs.lua
        if p.grade < Config.Creation.bossGrade and Framework.JobGradeExists(job, p.grade) then
            list[#list + 1] = { query = 'INSERT INTO fks_company_positions (company_id, name, grade, is_boss, permissions) VALUES (?, ?, ?, 0, ?)',
                                values = { id, p.name, p.grade, json.encode(Permissions.Clean(p.permissions)) } }
        end
    end
    return list
end

function ReloadPositions(c)
    c.positions = {}
    for _, r in ipairs(MySQL.query.await('SELECT * FROM fks_company_positions WHERE company_id = ?', { c.id }) or {}) do
        c.positions[r.id] = PositionFromRow(r)
    end
end

---------------------------------------------------------------------------
-- Employment records (used by hiring, ownership changes and admin tools)
---------------------------------------------------------------------------
-- adds / moves `cid` into the company with that position and sets their framework job. ok, err
function Employ(c, cid, name, position, contractId)
    cid = tostring(cid)
    local other = EmployeeOf[cid]
    if other and other ~= c.id then return false, _L('already_employed') end
    local e = c.employees[cid]
    if e then
        MySQL.update.await('UPDATE fks_company_employees SET position_id = ? WHERE id = ?', { position.id, e.id })
        e.positionId = position.id
    else
        local now = os.time()
        local id = MySQL.insert.await([[INSERT INTO fks_company_employees (company_id, cid, active_cid, name, position_id, contract_id, status, hired_at)
            VALUES (?, ?, ?, ?, ?, ?, 'active', ?)]], { c.id, cid, cid, name, position.id, contractId, now })
        if not id then return false, _L('already_employed') end
        e = { id = id, cid = cid, name = name, positionId = position.id, hiredAt = now, contractId = contractId }
        c.employees[cid] = e
        EmployeeOf[cid] = c.id
    end
    Framework.SetJobAny(cid, c.job, position.grade, c.name)
    return true
end

-- removes `cid` from the company: job, permissions, duty, record (kept as terminated)
function Unemploy(c, cid, by)
    cid = tostring(cid)
    local e = c.employees[cid]
    if not e then return false end
    MySQL.update.await([[UPDATE fks_company_employees SET status = 'terminated', active_cid = NULL, terminated_at = ?, terminated_by = ? WHERE id = ?]],
        { os.time(), by, e.id })
    if e.contractId then MySQL.update('UPDATE fks_company_contracts SET status = \'terminated\' WHERE id = ?', { e.contractId }) end
    if c.duty[cid] then SetDuty(c, cid, false, 'dismissed') end
    c.employees[cid] = nil
    EmployeeOf[cid] = nil
    Framework.Unemploy(cid)
    SyncMeCid(cid)
    return true
end

---------------------------------------------------------------------------
-- Ownership (purchase, admin change). newOwner = { cid, name } | nil
---------------------------------------------------------------------------
function SetOwner(c, newOwner, why)
    local boss = BossPosition(c)
    local old = c.owner
    if old and newOwner and old.cid == newOwner.cid then return true end
    if newOwner and EmployeeOf[newOwner.cid] and EmployeeOf[newOwner.cid] ~= c.id then return false, _L('already_employed') end

    -- previous Boss: dismissed or demoted to the highest normal position
    if old and c.employees[old.cid] then
        local keep = Config.Marketplace.PreviousOwner == 'demote' and why ~= 'delete'
        local best
        if keep then
            for _, p in pairs(c.positions) do
                if not p.isBoss and (not best or p.grade > best.grade) then best = p end
            end
        end
        if best then Employ(c, old.cid, c.employees[old.cid].name, best) else Unemploy(c, old.cid, why) end
        SyncMeCid(old.cid)
    end

    c.owner = newOwner
    MySQL.update.await('UPDATE fks_companies SET owner_cid = ?, owner_name = ? WHERE id = ?',
        { newOwner and newOwner.cid or nil, newOwner and newOwner.name or nil, c.id })
    if newOwner and boss then
        local ok, err = Employ(c, newOwner.cid, newOwner.name, boss)
        if not ok then return false, err end
        SyncMeCid(newOwner.cid)
    end
    Sync(c)
    return true
end

---------------------------------------------------------------------------
-- Status: active / inactive / suspended
---------------------------------------------------------------------------
function SetCompanyStatus(c, status, reason, src)
    if status ~= 'active' and status ~= 'inactive' and status ~= 'suspended' then return false end
    c.status, c.statusReason = status, reason
    MySQL.update.await('UPDATE fks_companies SET status = ?, status_reason = ?, status_changed_at = ? WHERE id = ?',
        { status, reason, os.time(), c.id })
    if status ~= 'active' then
        for cid in pairs(c.duty) do SetDuty(c, cid, false, 'inactive') end
        if c.sale.status == 'for_sale' then SetSale(c, { status = 'not_for_sale' }) end
        StoreClosedForViewers(c)
    end
    if status == 'active' then c.tax.failures = 0 end
    DB.Activity(c.id, 'status', nil, _L('act_status', _L('status_' .. status)))
    Sync(c)
    SyncCompanyMembers(c)
    return true
end

---------------------------------------------------------------------------
-- Creation (/createnewcompany)
---------------------------------------------------------------------------
Bridge.RegisterAdminCommand(Config.Creation.command, _L('cmd_create_help'), {}, function(src)
    if src == 0 then return print('[fks-companies] only in game') end
    if not IsAdmin(src) then return Notify(src, _L('no_permission'), 'error') end
    local pos = PedCoords(src)
    if not pos then return end
    local players = {}
    for _, p in ipairs(Bridge.Players()) do players[#players + 1] = { id = p.id, name = p.name } end
    TriggerClientEvent('fks-companies:client:create', src, {
        coords = { x = pos.x, y = pos.y, z = pos.z, h = GetEntityHeading(GetPlayerPed(src)) },
        players = players,
        defaults = {
            blip = Config.Creation.defaultBlip, maxEmployees = Config.Creation.defaultMaxEmployees,
            storage = { boss = Config.Storage.boss, general = Config.Storage.general },
            tax = Config.Taxes.default, taxesEnabled = Config.Taxes.enabled,
            marketplace = Config.Marketplace.Enabled, minPrice = Config.Marketplace.MinPrice,
        },
    })
end, Config.AdminManagement.AllowedGroups or Config.AdminGroups)

lib.callback.register('fks-companies:admin:create', function(src, d)
    if not IsAdmin(src) or type(d) ~= 'table' then return false, _L('no_permission') end
    local name = Co.Text(d.name, 40, 3)
    if not name then return false, _L('invalid_name') end
    if not ValidJob(d.job) then return false, _L('invalid_job') end
    if not Framework.JobExists(d.job) then return false, _L('job_missing_rsg', d.job) end
    if not Framework.JobGradeExists(d.job, Config.Creation.bossGrade) then
        return false, _L('job_missing_rsg', ('%s/%d'):format(d.job, Config.Creation.bossGrade))
    end
    local code = d.code and d.code ~= '' and d.code or nil
    if code and not ValidCode(code) then return false, _L('invalid_code') end
    if code and CodeTaken(code) then return false, _L('code_taken') end
    local c0 = type(d.coords) == 'table' and d.coords
    local pos = PedCoords(src)
    if not c0 or not pos or #(pos - vector3(tonumber(c0.x) or 0, tonumber(c0.y) or 0, tonumber(c0.z) or 0)) > 50.0 then
        return false, _L('too_far')
    end
    local blip = tonumber(d.blip) or Config.Creation.defaultBlip
    if not Co.BlipByHash[blip] then blip = Config.Creation.defaultBlip end
    local tax = ParseTax(d.tax)
    local storage = ParseStorage(d.storage)
    local sale = ParseSale(d.sale)
    if not sale then return false, _L('invalid_price') end
    local maxEmp = Clamp(d.maxEmployees, 1, Config.Creation.maxEmployeesLimit, Config.Creation.defaultMaxEmployees)

    local owner
    if d.owner and tonumber(d.owner) then
        local OP = Bridge.GetPlayer(tonumber(d.owner))
        if not OP then return false, _L('player_offline') end
        if EmployeeOf[tostring(OP.cid)] then return false, _L('owner_employed') end
        owner = Actor(OP)
    end

    local now = os.time()
    local id = MySQL.insert.await([[INSERT INTO fks_companies
        (code, name, job, description, x, y, z, heading, blip, max_employees, status,
         tax_enabled, tax_type, tax_amount, tax_interval, tax_next_at,
         boss_slots, boss_weight, general_slots, general_weight, store_enabled,
         sale_status, sale_price, sale_negotiable, sale_public, sale_listed_at, created_by, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
        code or ('TMP-' .. now .. math.random(100, 999)), name, d.job, Co.Text(d.description, 255),
        c0.x, c0.y, c0.z, tonumber(c0.h) or 0.0, blip, maxEmp,
        tax.enabled and 1 or 0, tax.type, tax.amount, tax.interval, tax.enabled and (now + tax.interval * 60) or nil,
        storage.boss.slots, storage.boss.weight, storage.general.slots, storage.general.weight, Config.Store.DefaultEnabled and 1 or 0,
        sale.forSale and 'for_sale' or 'not_for_sale', sale.price, sale.negotiable and 1 or 0, sale.public and 1 or 0,
        sale.forSale and now or nil, Bridge.CharacterName(src), now,
    })
    if not id then return false, _L('error') end
    if not code then
        code = ('CO-%04d'):format(id)
        MySQL.update.await('UPDATE fks_companies SET code = ? WHERE id = ?', { code, id })
    end
    MySQL.transaction.await(DefaultPositionQueries(id, d.job))

    local c = AddCompanyFromRow(MySQL.single.await('SELECT * FROM fks_companies WHERE id = ?', { id }))
    ReloadPositions(c)
    if owner then SetOwner(c, owner, 'create') end
    if sale.forSale and owner then
        -- listed with an owner: the owner is the seller and gets paid
        c.sale.seller = owner.cid
        MySQL.update.await('UPDATE fks_companies SET sale_seller_cid = ? WHERE id = ?', { owner.cid, c.id })
    end

    -- starting money from the administration: a normal ledger entry, so the history explains the first balance
    local start = Co.Money(d.balance)
    if start and start > 0 and start <= Config.Finance.maxTransaction then
        WithLock(Finance.Key(c), function()
            return Finance.Apply(c, start, 'admin', { name = Bridge.CharacterName(src) }, _L('tx_initial_balance'))
        end)
    end

    DB.Activity(c.id, 'created', nil, _L('act_created', name))
    DB.AdminLog(src, c.id, name, 'create', ('job=%s code=%s owner=%s'):format(c.job, c.code, owner and owner.name or '-'))
    Sync(c)
    return true, _L('company_created', name, c.code), c.id
end)

---------------------------------------------------------------------------
-- Management window data
---------------------------------------------------------------------------
local function PositionsList(c)
    local list = {}
    for _, p in pairs(c.positions) do
        local n = 0
        for _, e in pairs(c.employees) do if e.positionId == p.id then n = n + 1 end end
        list[#list + 1] = { id = p.id, name = p.name, grade = p.grade, boss = p.isBoss, description = p.description, perms = p.perms, count = n }
    end
    table.sort(list, function(a, b) return a.grade > b.grade end)
    return list
end
_G.PositionsList = PositionsList

local function EmployeesList(c)
    local list = {}
    for cid, e in pairs(c.employees) do
        local p = c.positions[e.positionId]
        list[#list + 1] = {
            cid = cid, name = e.name, position = p and p.name or '-', positionId = e.positionId, grade = p and p.grade or 0,
            boss = p and p.isBoss or false, hired = Co.Date(e.hiredAt), onDuty = c.duty[cid] ~= nil, online = Framework.Online(cid) ~= nil,
        }
    end
    table.sort(list, function(a, b) if a.grade ~= b.grade then return a.grade > b.grade end return a.name < b.name end)
    return list
end
_G.EmployeesList = EmployeesList

Callback('open', function(src, P)
    local c, cid = Access(src, P, nil, { inactive = true })
    if not c then return false, cid end
    if not IsActive(c) then return false, _L('company_inactive') end
    if not Can(c, cid, 'open_management') then return false, _L('no_permission') end
    local perms = PermsOf(c, cid)
    local boss = IsBoss(c, cid)
    local data = {
        id = c.id, code = c.code, name = c.name, job = c.job, description = c.description, blip = c.blip,
        owner = c.owner and c.owner.name or _L('no_owner'), boss = boss, perms = perms, me = { cid = cid, grade = GradeOf(c, cid), name = P.name },
        employees = EmployeeCount(c), maxEmployees = c.maxEmployees, onDuty = DutyCount(c),
        positions = PositionsList(c),
        locations = {},
        store = { enabled = c.store.enabled, model = c.store.model or Config.Store.DefaultModel, open = StoreOpen(c), products = 0 },
        sale = { status = c.sale.status, price = c.sale.price, mine = c.sale.seller ~= nil and c.sale.seller == cid },
        prices = { name = Config.Identity.nameChange, blip = Config.Identity.blipChange },
        cash = P.money('cash'),
    }
    for kind, l in pairs(c.locations) do data.locations[kind] = { model = l.model } end
    for _ in pairs(c.products) do data.store.products = data.store.products + 1 end
    if Can(c, cid, 'view_overview') then
        data.overview = { balance = c.balance, income = c.income, expenses = c.expenses, activity = {} }
        for _, a in ipairs(DB.RecentActivity(c.id, 8)) do
            data.overview.activity[#data.overview.activity + 1] = { text = a.message, at = Co.Date(a.created_at) }
        end
    end
    if Can(c, cid, 'hire') or Can(c, cid, 'dismiss') or Can(c, cid, 'promote') or Can(c, cid, 'demote') or Can(c, cid, 'manage_duty') or Can(c, cid, 'manage_positions') then
        data.staff = EmployeesList(c)
    end
    return true, data
end)

---------------------------------------------------------------------------
-- Placing the storages / register / store NPC
---------------------------------------------------------------------------
local LOC_PERM = { boss_storage = 'manage_storage_locations', general_storage = 'manage_storage_locations', register = 'manage_register', store = 'manage_store' }

local function ValidModel(kind, model)
    if kind == 'store' then
        for _, m in ipairs(Config.Store.Models) do if m == model then return true end end
        return false
    end
    for _, m in ipairs(Config.Props[kind] or {}) do if m == model then return true end end
    return false
end

Callback('place', function(src, P, companyId, kind, c0, model)
    if not LOC_KINDS[kind] then return false, _L('error') end
    local c, err = Access(src, P, companyId, { perm = LOC_PERM[kind] })
    if not c then return false, err end
    if type(c0) ~= 'table' then return false, _L('error') end
    local x, y, z, h = tonumber(c0.x), tonumber(c0.y), tonumber(c0.z), tonumber(c0.h) or 0.0
    if not x or not y or not z then return false, _L('error') end
    local point = vector3(x, y, z)
    if #(point - Vec(c.coords)) > Config.Placement.maxDistance + 1.0 then return false, _L('place_too_far', math.floor(Config.Placement.maxDistance)) end
    if not Near(src, point, 25.0) then return false, _L('too_far') end
    if not ValidModel(kind, model) then model = kind == 'store' and (c.store.model or Config.Store.DefaultModel) or (Config.Props[kind] or {})[1] end

    MySQL.insert.await([[INSERT INTO fks_company_locations (company_id, kind, x, y, z, heading, model, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE x = VALUES(x), y = VALUES(y), z = VALUES(z), heading = VALUES(heading), model = VALUES(model), updated_at = VALUES(updated_at)]],
        { c.id, kind, x, y, z, h % 360.0, model, os.time() })
    c.locations[kind] = { x = x, y = y, z = z, h = h % 360.0, model = model }
    if kind == 'store' then
        c.store.model = model
        MySQL.update('UPDATE fks_companies SET store_model = ? WHERE id = ?', { model, c.id })
    end
    DB.Activity(c.id, 'place', Actor(P), _L('act_place', P.name, _L('loc_' .. kind)))
    Sync(c)
    return true, _L('placed', _L('loc_' .. kind))
end)

---------------------------------------------------------------------------
-- Storages
---------------------------------------------------------------------------
function StashId(c, kind) return ('fks_company_%d_%s'):format(c.id, kind) end

Callback('storage', function(src, P, companyId, kind)
    if kind ~= 'boss' and kind ~= 'general' then return false, _L('error') end
    local c, err = Access(src, P, companyId, { perm = kind == 'boss' and 'access_boss_storage' or 'access_general_storage' })
    if not c then return false, err end
    local loc = c.locations[kind .. '_storage']
    if not loc or not Near(src, loc, Config.Interact.distance + 2.5) then return false, _L('too_far') end
    local S = c.storage[kind]
    Bridge.OpenStash(src, StashId(c, kind), _L('stash_' .. kind, c.name), S.slots, S.weight, S.slots)
    return true
end)

---------------------------------------------------------------------------
-- Identity: name / blip (paid from the company balance)
---------------------------------------------------------------------------
local function ApplyName(c, name)
    c.name = name
    MySQL.update.await('UPDATE fks_companies SET name = ? WHERE id = ?', { name, c.id })
    -- job label of the online employees (VORP shows it in its menus)
    for cid, e in pairs(c.employees) do
        local s = Framework.Online(cid)
        local pos = c.positions[e.positionId]
        if s and pos and Bridge.Framework() == 'vorp' then Framework.SetJob(s, c.job, pos.grade, name) end
    end
    Sync(c)
    SyncCompanyMembers(c)
end
_G.ApplyName = ApplyName

local function ApplyBlip(c, blip)
    c.blip = blip
    MySQL.update.await('UPDATE fks_companies SET blip = ? WHERE id = ?', { blip, c.id })
    Sync(c)
end
_G.ApplyBlip = ApplyBlip

local function Purchase(c, P, kind, old, new, price)
    MySQL.insert('INSERT INTO fks_company_purchases (company_id, kind, old_value, new_value, price, actor_cid, actor_name, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        { c.id, kind, tostring(old), tostring(new), price, tostring(P.cid), P.name, os.time() })
end

Callback('rename', function(src, P, companyId, value)
    local cfg = Config.Identity.nameChange
    if not cfg.enabled then return false, _L('feature_disabled') end
    local c, err = Access(src, P, companyId, { perm = 'change_name' })
    if not c then return false, err end
    local name = Co.Text(value, cfg.maxLength, cfg.minLength)
    if not name then return false, _L('invalid_name') end
    if name == c.name then return false, _L('same_name') end
    return WithLock(Finance.Key(c), function()
        local price = Co.Money(cfg.price) or 0
        if price > 0 then
            local ok, e = Finance.Apply(c, -price, 'expense', Actor(P), _L('tx_rename', c.name, name))
            if not ok then return false, e end
        end
        local old = c.name
        ApplyName(c, name)
        Purchase(c, P, 'name', old, name, price)
        DB.Activity(c.id, 'rename', Actor(P), _L('act_rename', P.name, old, name))
        return true, _L('renamed', name)
    end)
end)

Callback('setBlip', function(src, P, companyId, hash)
    local cfg = Config.Identity.blipChange
    if not cfg.enabled then return false, _L('feature_disabled') end
    local c, err = Access(src, P, companyId, { perm = 'change_blip' })
    if not c then return false, err end
    hash = tonumber(hash)
    if not hash or not Co.BlipAllowed(hash) then return false, _L('blip_not_allowed') end
    if hash == c.blip then return false, _L('same_blip') end
    local b = Co.BlipByHash[hash]
    return WithLock(Finance.Key(c), function()
        local price = Co.Money(cfg.price) or 0
        if price > 0 then
            local ok, e = Finance.Apply(c, -price, 'expense', Actor(P), _L('tx_blip', b.label))
            if not ok then return false, e end
        end
        local old = c.blip
        ApplyBlip(c, hash)
        Purchase(c, P, 'blip', old, hash, price)
        DB.Activity(c.id, 'blip', Actor(P), _L('act_blip', P.name, b.label))
        return true, _L('blip_changed', b.label)
    end)
end)

Callback('description', function(src, P, companyId, value)
    local c, err = Access(src, P, companyId, { perm = 'edit_info' })
    if not c then return false, err end
    local text = Co.Text(value, 255, 0) or nil
    c.description = text
    MySQL.update.await('UPDATE fks_companies SET description = ? WHERE id = ?', { text, c.id })
    DB.Activity(c.id, 'info', Actor(P), _L('act_info', P.name))
    return true, _L('saved')
end)
