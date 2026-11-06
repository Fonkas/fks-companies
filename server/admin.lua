---------------------------------------------------------------------------
-- Administration (/managecompanies): every company, editing, activity status, deletion and the admin log.
-- Every callback checks the admin permission again; every change is written to fks_company_admin_log.
---------------------------------------------------------------------------
local A = Config.AdminManagement

local function Row(c)
    return {
        id = c.id, code = c.code, name = c.name, job = c.job, owner = c.owner and c.owner.name or nil, ownerCid = c.owner and c.owner.cid or nil,
        employees = EmployeeCount(c), maxEmployees = c.maxEmployees, balance = c.balance, status = c.status, statusReason = c.statusReason,
        sale = c.sale.status, price = c.sale.price, salePublic = c.sale.public, saleNegotiable = c.sale.negotiable,
        onDuty = DutyCount(c), created = Co.Date(c.createdAt), blip = c.blip, description = c.description,
        tax = c.tax, storage = c.storage, store = { enabled = c.store.enabled, model = c.store.model, products = (function()
            local n = 0 for _ in pairs(c.products) do n = n + 1 end return n end)() },
        coords = c.coords, locations = (function() local t = {} for k in pairs(c.locations) do t[k] = true end return t end)(),
        income = c.income, expenses = c.expenses,
    }
end

local function Admin(src)
    if not A.Enabled then return false end
    return IsAdmin(src)
end

RegisterCommand(A.Command, function(src)
    if src == 0 then return print('[fks-companies] only in game') end
    if not Admin(src) then return Notify(src, _L('no_permission'), 'error') end
    TriggerClientEvent('fks-companies:client:admin', src)
end, false)
CreateThread(function()
    Wait(2000)
    TriggerClientEvent('chat:addSuggestion', -1, '/' .. A.Command, _L('cmd_manage_help'), {})
end)

lib.callback.register('fks-companies:admin:list', function(src)
    if not Admin(src) then return false, _L('no_permission') end
    local list = {}
    for _, c in pairs(Companies) do list[#list + 1] = Row(c) end
    table.sort(list, function(a, b) return a.id < b.id end)
    local players = {}
    for _, p in ipairs(Bridge.Players()) do players[#players + 1] = { id = p.id, name = p.name } end
    return true, list, players
end)

lib.callback.register('fks-companies:admin:get', function(src, id)
    if not Admin(src) then return false, _L('no_permission') end
    local c = Company(id)
    if not c then return false, _L('company_unknown') end
    local r = Row(c)
    r.staff = EmployeesList(c)
    r.positions = PositionsList(c)
    return true, r
end)

lib.callback.register('fks-companies:admin:log', function(src, id, page)
    if not Admin(src) then return false, _L('no_permission') end
    page = math.max(1, math.floor(tonumber(page) or 1))
    local rows = {}
    for _, r in ipairs(DB.AdminHistory(tonumber(id), A.logPageSize, (page - 1) * A.logPageSize)) do
        rows[#rows + 1] = { action = r.action, admin = r.admin_name, company = r.company_name, companyId = r.company_id, details = r.details, at = Co.Date(r.created_at) }
    end
    return true, rows, page
end)

---------------------------------------------------------------------------
-- Edit (one field group per call, so every change is logged on its own)
---------------------------------------------------------------------------
local Edits = {}

function Edits.name(src, c, v)
    local name = Co.Text(v, Config.Identity.nameChange.maxLength, Config.Identity.nameChange.minLength)
    if not name then return false, _L('invalid_name') end
    local old = c.name
    ApplyName(c, name)
    return true, ('%s -> %s'):format(old, name)
end

function Edits.description(src, c, v)
    c.description = Co.Text(v, 255, 0)
    MySQL.update.await('UPDATE fks_companies SET description = ? WHERE id = ?', { c.description, c.id })
    return true, 'description'
end

function Edits.code(src, c, v)
    if type(v) ~= 'string' or not v:match('^[%w_%-]+$') or #v < 2 or #v > 32 then return false, _L('invalid_code') end
    if CodeTaken(v, c.id) then return false, _L('code_taken') end
    local old = c.code
    c.code = v
    MySQL.update.await('UPDATE fks_companies SET code = ? WHERE id = ?', { v, c.id })
    return true, ('%s -> %s'):format(old, v)
end

-- every employee gets the new job (online and offline)
function Edits.job(src, c, v)
    if type(v) ~= 'string' or not v:match('^[%w_%-]+$') or #v > 60 then return false, _L('invalid_job') end
    if not Framework.JobExists(v) then return false, _L('job_missing_rsg', v) end
    for _, p in pairs(c.positions) do
        if not Framework.JobGradeExists(v, p.grade) then return false, _L('job_missing_rsg', ('%s/%d'):format(v, p.grade)) end
    end
    local old = c.job
    c.job = v
    MySQL.update.await('UPDATE fks_companies SET job = ? WHERE id = ?', { v, c.id })
    for cid, e in pairs(c.employees) do
        local pos = c.positions[e.positionId]
        Framework.SetJobAny(cid, v, pos and pos.grade or 0, c.name)
        SyncMeCid(cid)
    end
    Sync(c)
    return true, ('%s -> %s'):format(old, v)
end

-- v = { player = server id } | { cid = 'character id' } | { none = true }
function Edits.owner(src, c, v)
    v = type(v) == 'table' and v or {}
    local new
    if v.none then
        new = nil
    elseif tonumber(v.player) then
        local P = Bridge.GetPlayer(tonumber(v.player))
        if not P then return false, _L('player_offline') end
        new = Actor(P)
    elseif v.cid and tostring(v.cid) ~= '' then
        local cid = tostring(v.cid)
        local src2, P = Framework.Online(cid)
        local name = P and P.name or Framework.OfflineName(cid)
        if not name then return false, _L('character_unknown') end
        new = { cid = cid, name = name }
    else
        return false, _L('error')
    end
    if new and EmployeeOf[new.cid] and EmployeeOf[new.cid] ~= c.id then return false, _L('owner_employed') end
    local old = c.owner and c.owner.name or '-'
    local ok, err = WithLock(Finance.Key(c), function()
        if c.sale.status == 'for_sale' and c.sale.seller then SetSale(c, { status = 'not_for_sale', seller = false }) end
        return SetOwner(c, new, 'admin')
    end)
    if not ok then return false, err end
    DB.Activity(c.id, 'owner', nil, _L('act_owner_admin', new and new.name or _L('no_owner')))
    return true, ('%s -> %s'):format(old, new and new.name or '-')
end

-- the admin's current position becomes the company point
function Edits.location(src, c)
    local pos = PedCoords(src)
    if not pos then return false, _L('error') end
    c.coords = { x = pos.x, y = pos.y, z = pos.z, h = GetEntityHeading(GetPlayerPed(src)) }
    MySQL.update.await('UPDATE fks_companies SET x = ?, y = ?, z = ?, heading = ? WHERE id = ?', { pos.x, pos.y, pos.z, c.coords.h, c.id })
    Sync(c)
    return true, ('%.1f %.1f %.1f'):format(pos.x, pos.y, pos.z)
end

function Edits.blip(src, c, v)
    local hash = tonumber(v)
    if not hash or not Co.BlipByHash[hash] then return false, _L('blip_not_allowed') end
    ApplyBlip(c, hash)
    return true, Co.BlipByHash[hash].name
end

function Edits.storage(src, c, v)
    local s = ParseStorage(v)
    c.storage = s
    MySQL.update.await('UPDATE fks_companies SET boss_slots = ?, boss_weight = ?, general_slots = ?, general_weight = ? WHERE id = ?',
        { s.boss.slots, s.boss.weight, s.general.slots, s.general.weight, c.id })
    return true, ('boss %d/%d general %d/%d'):format(s.boss.slots, s.boss.weight, s.general.slots, s.general.weight)
end

function Edits.tax(src, c, v)
    local t = ParseTax(v)
    c.tax.enabled, c.tax.type, c.tax.amount, c.tax.interval = t.enabled, t.type, t.amount, t.interval
    c.tax.nextAt = t.enabled and (os.time() + t.interval * 60) or nil
    MySQL.update.await('UPDATE fks_companies SET tax_enabled = ?, tax_type = ?, tax_amount = ?, tax_interval = ?, tax_next_at = ? WHERE id = ?',
        { t.enabled and 1 or 0, t.type, t.amount, t.interval, c.tax.nextAt, c.id })
    return true, ('%s %s %s every %d min'):format(t.enabled and 'on' or 'off', t.type, t.amount, t.interval)
end

function Edits.sale(src, c, v)
    local s = ParseSale(v)
    if not s then return false, _L('invalid_price_range', Co.Fmt(Config.Marketplace.MinPrice), Co.Fmt(Config.Marketplace.MaxPrice)) end
    if s.forSale and not IsActive(c) then return false, _L('company_inactive') end
    local old = ('%s %s'):format(c.sale.status, c.sale.price)
    local ok, err = WithLock(Finance.Key(c), function()
        if c.sale.status == 'pending' then return false, _L('sale_busy') end
        SetSale(c, {
            status = s.forSale and 'for_sale' or (c.sale.status == 'for_sale' and 'not_for_sale' or c.sale.status),
            price = s.price, negotiable = s.negotiable, public = s.public,
            seller = s.forSale and (c.owner and c.owner.cid or false) or false,
            listedAt = s.forSale and os.time() or nil,
        })
        return true
    end)
    if not ok then return false, err end
    return true, ('%s -> %s %s'):format(old, c.sale.status, c.sale.price)
end

function Edits.store(src, c, v)
    v = type(v) == 'table' and v or {}
    c.store.enabled = v.enabled == true
    MySQL.update.await('UPDATE fks_companies SET store_enabled = ? WHERE id = ?', { c.store.enabled and 1 or 0, c.id })
    Sync(c)
    StoreClosedForViewers(c)
    return true, c.store.enabled and 'store on' or 'store off'
end

function Edits.maxEmployees(src, c, v)
    local n = math.floor(tonumber(v) or 0)
    if n < 1 or n > Config.Creation.maxEmployeesLimit then return false, _L('invalid_amount') end
    c.maxEmployees = n
    MySQL.update.await('UPDATE fks_companies SET max_employees = ? WHERE id = ?', { n, c.id })
    return true, tostring(n)
end

-- remove a placed point (it can be placed again from Customization)
function Edits.clearLocation(src, c, v)
    if not c.locations[v] then return false, _L('error') end
    MySQL.update.await('DELETE FROM fks_company_locations WHERE company_id = ? AND kind = ?', { c.id, v })
    c.locations[v] = nil
    Sync(c)
    StoreClosedForViewers(c)
    return true, tostring(v)
end

function Edits.balance(src, c, v)
    local amount = Co.Money(v)
    if not amount or amount < 0 or amount > Config.Finance.maxTransaction * 100 then return false, _L('invalid_amount') end
    return WithLock(Finance.Key(c), function()
        local diff = Co.Money(amount - c.balance)
        if diff == 0 then return true, 'unchanged' end
        local ok, err = Finance.Apply(c, diff, 'admin', { cid = nil, name = Bridge.CharacterName(src) }, _L('tx_admin_balance'))
        if not ok then return false, err end
        return true, Co.Fmt(amount)
    end)
end

lib.callback.register('fks-companies:admin:edit', function(src, id, field, value)
    if not Admin(src) then return false, _L('no_permission') end
    local c = Company(id)
    if not c then return false, _L('company_unknown') end
    local fn = Edits[field]
    if not fn then return false, _L('error') end
    local ok, res = fn(src, c, value)
    if not ok then return false, res end
    DB.AdminLog(src, c.id, c.name, 'edit_' .. field, res)
    return true, _L('saved'), Row(c)
end)

---------------------------------------------------------------------------
-- Activity status
---------------------------------------------------------------------------
lib.callback.register('fks-companies:admin:status', function(src, id, status, reason)
    if not Admin(src) then return false, _L('no_permission') end
    local c = Company(id)
    if not c then return false, _L('company_unknown') end
    if status ~= 'active' and status ~= 'inactive' and status ~= 'suspended' then return false, _L('error') end
    if c.status == status then return false, _L('status_same') end
    local old = c.status
    reason = Co.Text(reason, 255, 0)
    SetCompanyStatus(c, status, reason, src)
    if status ~= 'active' then CancelContracts(c) end
    local action = status == 'active' and (old == 'suspended' and 'reactivate' or 'activate') or (status == 'suspended' and 'suspend' or 'deactivate')
    DB.AdminLog(src, c.id, c.name, action, reason)
    -- tell the employees online
    for cid in pairs(c.employees) do
        local s = Framework.Online(cid)
        if s then Notify(s, _L('company_status_now', c.name, _L('status_' .. status)), status == 'active' and 'success' or 'warning') end
    end
    return true, _L('status_set', _L('status_' .. status)), Row(c)
end)

---------------------------------------------------------------------------
-- Deletion. Both modes: employees lose the job, positions / points / products / storages go, the listing is
-- closed and the balance is written off.
--   'archive'  the company row, its ledger, activity, sales and admin log are kept (deleted_at) for auditing
--   'purge'    every row of the company is deleted for good; only the admin log line of the deletion and the
--              pending marketplace payouts (money still owed to a seller) are kept
---------------------------------------------------------------------------
-- rows of a company outside the cascading tables (positions, employees, contracts, locations, products cascade)
local function PurgeQueries(id)
    return {
        { query = 'DELETE FROM fks_company_transactions WHERE company_id = ?', values = { id } },
        { query = 'DELETE FROM fks_company_activity WHERE company_id = ?', values = { id } },
        { query = 'DELETE FROM fks_company_purchases WHERE company_id = ?', values = { id } },
        { query = 'DELETE FROM fks_company_store_sales WHERE company_id = ?', values = { id } },          -- items cascade
        { query = "DELETE FROM fks_company_payouts WHERE company_id = ? AND status = 'paid'", values = { id } },
        -- a sale with a pending payout keeps its row (the payout reads the company name from it)
        { query = "DELETE FROM fks_company_sales WHERE company_id = ? AND id NOT IN (SELECT sale_id FROM fks_company_payouts WHERE status = 'pending')", values = { id } },
        { query = 'DELETE FROM fks_companies WHERE id = ?', values = { id } },
    }
end

lib.callback.register('fks-companies:admin:delete', function(src, id, confirmCode, mode)
    if not Admin(src) then return false, _L('no_permission') end
    local c = Company(id)
    if not c then return false, _L('company_unknown') end
    if confirmCode ~= c.code then return false, _L('delete_confirm_wrong') end
    local purge = mode == 'purge'

    return WithLock(Finance.Key(c), function()
        if c.sale.status == 'pending' then return false, _L('sale_busy') end
        CancelContracts(c)
        for cid in pairs(c.duty) do SetDuty(c, cid, false, 'inactive') end
        c.status = 'inactive'
        StoreClosedForViewers(c)
        for cid in pairs(c.employees) do Unemploy(c, cid, 'deleted') end

        local balance = c.balance
        local q
        if purge then
            q = PurgeQueries(c.id)
        else
            q = {}
            if balance ~= 0 then q[#q + 1] = DB.TxQuery(c.id, 'admin', -balance, balance, 0, { name = Bridge.CharacterName(src) }, _L('tx_deleted')) end
            q[#q + 1] = { query = 'DELETE FROM fks_company_positions WHERE company_id = ?', values = { c.id } }
            q[#q + 1] = { query = 'DELETE FROM fks_company_locations WHERE company_id = ?', values = { c.id } }
            q[#q + 1] = { query = 'DELETE FROM fks_company_products WHERE company_id = ?', values = { c.id } }
            q[#q + 1] = { query = [[UPDATE fks_companies SET deleted_at = ?, status = 'inactive', balance = 0, owner_cid = NULL, owner_name = NULL,
                sale_status = 'not_for_sale', sale_seller_cid = NULL, store_enabled = 0, code = ? WHERE id = ?]],
                values = { os.time(), ('%s#%d'):format(c.code, c.id):sub(1, 32), c.id } }
        end
        if not MySQL.transaction.await(q) then return false, _L('error') end

        Bridge.DeleteStash(StashId(c, 'boss'))
        Bridge.DeleteStash(StashId(c, 'general'))
        Companies[c.id] = nil
        SyncRemove(c.id)
        DB.AdminLog(src, c.id, c.name, purge and 'purge' or 'delete', ('code=%s balance=%s employees removed'):format(c.code, balance))
        return true, _L(purge and 'company_purged' or 'company_deleted', c.name)
    end)
end)

-- archived companies (deleted before with 'archive'): delete them for good
lib.callback.register('fks-companies:admin:archived', function(src)
    if not Admin(src) then return false, _L('no_permission') end
    local rows = MySQL.query.await('SELECT id, code, name, deleted_at FROM fks_companies WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC') or {}
    local list = {}
    for _, r in ipairs(rows) do list[#list + 1] = { id = r.id, code = r.code, name = r.name, deleted = Co.Date(r.deleted_at) } end
    return true, list
end)

lib.callback.register('fks-companies:admin:purgeArchived', function(src, id)
    if not Admin(src) then return false, _L('no_permission') end
    local ids = {}
    local rows = MySQL.query.await('SELECT id, name FROM fks_companies WHERE deleted_at IS NOT NULL' .. (id and ' AND id = ?' or ''), id and { tonumber(id) } or {}) or {}
    if #rows == 0 then return false, _L('no_archived') end
    local q = {}
    for _, r in ipairs(rows) do
        if Companies[r.id] then return false, _L('error') end      -- never a live company
        ids[#ids + 1] = r.id
        for _, x in ipairs(PurgeQueries(r.id)) do q[#q + 1] = x end
    end
    if not MySQL.transaction.await(q) then return false, _L('error') end
    for _, r in ipairs(rows) do DB.AdminLog(src, r.id, r.name, 'purge', 'archived company deleted for good') end
    return true, _L('archived_purged', #ids)
end)
