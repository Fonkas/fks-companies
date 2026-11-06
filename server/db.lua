---------------------------------------------------------------------------
-- Database: the tables of sql/install.sql are created on start (CREATE TABLE IF NOT EXISTS), so importing
-- the file by hand is optional. Everything is loaded into memory once (server/main.lua); after that the
-- memory is the authoritative state and every change is written through these helpers.
---------------------------------------------------------------------------
DB = { ready = false }

CreateThread(function()
    local sql = LoadResourceFile(GetCurrentResourceName(), 'sql/install.sql')
    if not sql then
        print('^1[fks-companies] sql/install.sql is missing^0')
        return
    end
    sql = sql:gsub('%-%-[^\n]*', '')                  -- comments
    for stmt in sql:gmatch('(.-);%s*\n') do
        if stmt:find('%S') then
            local ok, err = pcall(MySQL.query.await, stmt)
            if not ok then print(('^1[fks-companies] SQL error: %s^0'):format(tostring(err))) end
        end
    end
    DB.ready = true
end)

function DB.Wait()
    while not DB.ready do Wait(100) end
end

local function J(v) return v and json.encode(v) or nil end
DB.Json = J

function DB.LoadAll()
    DB.Wait()
    return {
        companies = MySQL.query.await('SELECT * FROM fks_companies WHERE deleted_at IS NULL') or {},
        positions = MySQL.query.await([[SELECT p.* FROM fks_company_positions p
            JOIN fks_companies c ON c.id = p.company_id AND c.deleted_at IS NULL]]) or {},
        employees = MySQL.query.await([[SELECT e.* FROM fks_company_employees e
            JOIN fks_companies c ON c.id = e.company_id AND c.deleted_at IS NULL WHERE e.status = 'active']]) or {},
        locations = MySQL.query.await('SELECT * FROM fks_company_locations') or {},
        products = MySQL.query.await('SELECT * FROM fks_company_products') or {},
    }
end

---------------------------------------------------------------------------
-- History rows
---------------------------------------------------------------------------
function DB.TxQuery(companyId, kind, amount, before, after, actor, desc)
    return {
        query = [[INSERT INTO fks_company_transactions
            (company_id, type, amount, balance_before, balance_after, actor_cid, actor_name, description, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        values = { companyId, kind, amount, before, after, actor and actor.cid or nil, actor and actor.name or nil, desc, os.time() },
    }
end

function DB.Activity(companyId, kind, actor, message)
    MySQL.insert('INSERT INTO fks_company_activity (company_id, kind, actor_cid, actor_name, message, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        { companyId, kind, actor and actor.cid or nil, actor and actor.name or nil, tostring(message):sub(1, 255), os.time() })
end

function DB.AdminLog(src, companyId, companyName, action, details)
    local adminId = src and src > 0 and (GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifierByType(src, 'steam')) or 'console'
    local adminName = src and src > 0 and ('%s (%s)'):format(Bridge.CharacterName(src) or '?', GetPlayerName(src) or '?') or 'console'
    MySQL.insert('INSERT INTO fks_company_admin_log (company_id, company_name, admin_id, admin_name, action, details, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { companyId, companyName, adminId, adminName, action, details and tostring(details):sub(1, 500) or nil, os.time() })
    if Config.Debug then print(('[fks-companies] admin %s: %s #%s %s'):format(adminName, action, tostring(companyId), tostring(details or ''))) end
end

function DB.Transactions(companyId, limit, offset)
    return MySQL.query.await([[SELECT id, type, amount, balance_before, balance_after, actor_name, description, created_at
        FROM fks_company_transactions WHERE company_id = ? ORDER BY id DESC LIMIT ? OFFSET ?]], { companyId, limit, offset or 0 }) or {}
end

function DB.CountTransactions(companyId)
    return MySQL.scalar.await('SELECT COUNT(*) FROM fks_company_transactions WHERE company_id = ?', { companyId }) or 0
end

function DB.RecentActivity(companyId, limit)
    return MySQL.query.await('SELECT kind, actor_name, message, created_at FROM fks_company_activity WHERE company_id = ? ORDER BY id DESC LIMIT ?',
        { companyId, limit }) or {}
end

function DB.AdminHistory(companyId, limit, offset)
    if companyId then
        return MySQL.query.await('SELECT * FROM fks_company_admin_log WHERE company_id = ? ORDER BY id DESC LIMIT ? OFFSET ?', { companyId, limit, offset or 0 }) or {}
    end
    return MySQL.query.await('SELECT * FROM fks_company_admin_log ORDER BY id DESC LIMIT ? OFFSET ?', { limit, offset or 0 }) or {}
end
