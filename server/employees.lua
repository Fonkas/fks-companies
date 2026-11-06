---------------------------------------------------------------------------
-- Employees: employment contracts (hire), staff actions (position, promote, demote, dismiss) and the
-- custom positions with their permissions.
---------------------------------------------------------------------------
local Contracts = {}     -- [token] = pending contract (also in fks_company_contracts)

local function Token()
    local s = ''
    for _ = 1, 24 do s = s .. string.char(({ math.random(48, 57), math.random(97, 122) })[math.random(2)]) end
    return s
end

local function Pending(c)
    local n = 0
    for _, k in pairs(Contracts) do if k.company == c.id then n = n + 1 end end
    return n
end

local function ContractView(k, c)
    return {
        token = k.token, company = c.name, code = c.code, employer = k.employerName, employerRole = k.employerRole,
        employee = k.employeeName, position = k.positionName, grade = k.grade, description = k.description,
        date = os.date('%d / %m / %Y'), expires = k.expiresAt - os.time(), number = ('%s-%05d'):format(c.code, k.id),
        permissions = k.permsList,
    }
end

local function PermList(pos)
    local list = {}
    local perms = pos.isBoss and Permissions.All() or pos.perms
    for _, p in ipairs(Permissions.List) do
        if perms[p.key] then list[#list + 1] = _L('perm_' .. p.key) end
    end
    return list
end

---------------------------------------------------------------------------
-- Hire: the employer sends a contract to a player id
---------------------------------------------------------------------------
Callback('hire', function(src, P, companyId, target, positionId, description)
    local c, cid = Access(src, P, companyId, { perm = 'hire' })
    if not c then return false, cid end
    target = tonumber(target)
    if not target or target == src or not GetPlayerName(target) then return false, _L('invalid_target') end
    local T = Bridge.GetPlayer(target)
    if not T then return false, _L('player_offline') end
    local tcid = tostring(T.cid)
    if EmployeeOf[tcid] then return false, _L('target_employed') end
    if not Near(src, PedCoords(target), Config.Contracts.maxDistance) then return false, _L('target_far') end
    if EmployeeCount(c) + Pending(c) >= c.maxEmployees then return false, _L('company_full', c.maxEmployees) end
    for _, k in pairs(Contracts) do
        if k.employeeCid == tcid then return false, _L('contract_pending') end
    end

    local pos = c.positions[tonumber(positionId) or -1]
    if not pos or pos.isBoss then return false, _L('invalid_position') end
    if not IsBoss(c, cid) and pos.grade >= GradeOf(c, cid) then return false, _L('position_too_high') end
    if not Framework.JobGradeExists(c.job, pos.grade) then return false, _L('job_missing_rsg', ('%s/%d'):format(c.job, pos.grade)) end

    local now = os.time()
    local mine = c.positions[c.employees[cid].positionId]
    local k = {
        token = Token(), company = c.id, employerCid = cid, employerName = P.name, employerRole = mine and mine.name or '',
        employeeCid = tcid, employeeName = T.name, employeeSrc = target, positionId = pos.id, positionName = pos.name, grade = pos.grade,
        description = Co.Text(description, Config.Contracts.descriptionMax, 0) or '', createdAt = now,
        expiresAt = now + Config.Contracts.expiration, employerSrc = src, permsList = PermList(pos),
    }
    k.id = MySQL.insert.await([[INSERT INTO fks_company_contracts
        (token, company_id, employer_cid, employer_name, employee_cid, employee_name, position_id, position_name, description, status, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)]],
        { k.token, c.id, cid, P.name, tcid, T.name, pos.id, pos.name, k.description, now, k.expiresAt })
    if not k.id then return false, _L('error') end
    Contracts[k.token] = k
    TriggerClientEvent('fks-companies:client:contract', target, ContractView(k, c))
    return true, _L('contract_sent', T.name)
end)

local function Close(k, status)
    Contracts[k.token] = nil
    MySQL.update('UPDATE fks_company_contracts SET status = ? WHERE id = ? AND status = \'pending\'', { status, k.id })
end

-- the target answers. Only the character the contract was made for, while it is pending and not expired.
Callback('contract:answer', function(src, P, token, accept)
    local k = type(token) == 'string' and Contracts[token]
    if not k or k.employeeCid ~= tostring(P.cid) then return false, _L('contract_invalid') end
    local c = Companies[k.company]
    if os.time() > k.expiresAt then
        Close(k, 'expired')
        return false, _L('contract_expired')
    end
    if not accept then
        Close(k, 'declined')
        if k.employerSrc and GetPlayerName(k.employerSrc) then Notify(k.employerSrc, _L('contract_declined_by', P.name), 'error') end
        return true, _L('contract_declined')
    end
    if not IsActive(c) then Close(k, 'cancelled') return false, _L('company_inactive') end

    return WithLock('c' .. c.id, function()
        if Contracts[token] ~= k then return false, _L('contract_invalid') end           -- answered twice
        local pos = c.positions[k.positionId]
        if not pos or pos.isBoss then Close(k, 'cancelled') return false, _L('invalid_position') end
        if EmployeeOf[tostring(P.cid)] then Close(k, 'cancelled') return false, _L('already_employed') end
        if EmployeeCount(c) >= c.maxEmployees then Close(k, 'cancelled') return false, _L('company_full', c.maxEmployees) end

        Contracts[token] = nil
        local now = os.time()
        local n = MySQL.update.await([[UPDATE fks_company_contracts SET status = 'signed', signature = ?, signed_at = ?
            WHERE id = ? AND status = 'pending']], { P.name, now, k.id })
        if (n or 0) ~= 1 then return false, _L('contract_invalid') end
        local ok, err = Employ(c, P.cid, P.name, pos, k.id)
        if not ok then
            MySQL.update('UPDATE fks_company_contracts SET status = \'cancelled\' WHERE id = ?', { k.id })
            return false, err
        end
        DB.Activity(c.id, 'hire', { cid = k.employerCid, name = k.employerName }, _L('act_hire', k.employerName, P.name, pos.name))
        if k.employerSrc and GetPlayerName(k.employerSrc) then
            Notify(k.employerSrc, _L('contract_signed_by', P.name), 'success')
            SyncMe(k.employerSrc)
        end
        SyncMe(src)
        return true, _L('hired_welcome', c.name, pos.name), P.name
    end)
end)

-- expired contracts
CreateThread(function()
    while true do
        Wait(5000)
        local now = os.time()
        for _, k in pairs(Contracts) do
            if now > k.expiresAt then
                Close(k, 'expired')
                TriggerClientEvent('fks-companies:client:contractClosed', k.employeeSrc, k.token)
                if k.employerSrc and GetPlayerName(k.employerSrc) then Notify(k.employerSrc, _L('contract_expired_for', k.employeeName), 'warning') end
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, k in pairs(Contracts) do
        if k.employeeSrc == src then Close(k, 'cancelled') end
    end
end)

---------------------------------------------------------------------------
-- Staff actions
---------------------------------------------------------------------------
local function Target(c, cid)
    cid = tostring(cid or '')
    return c.employees[cid] and cid or nil
end

local function Moved(c, P, tcid, pos, kind)
    local e = c.employees[tcid]
    local ok = Employ(c, tcid, e.name, pos)
    if not ok then return false, _L('error') end
    DB.Activity(c.id, kind, Actor(P), _L('act_' .. kind, P.name, e.name, pos.name))
    SyncMeCid(tcid)
    local s = Framework.Online(tcid)
    if s then Notify(s, _L('you_' .. kind, pos.name, c.name), kind == 'demote' and 'warning' or 'success') end
    return true, _L('staff_' .. kind, e.name, pos.name)
end

-- next position above / below a grade (never the Boss)
local function Neighbour(c, grade, dir)
    local best
    for _, p in pairs(c.positions) do
        if not p.isBoss then
            if dir > 0 and p.grade > grade and (not best or p.grade < best.grade) then best = p end
            if dir < 0 and p.grade < grade and (not best or p.grade > best.grade) then best = p end
        end
    end
    return best
end

Callback('staff:setPosition', function(src, P, companyId, targetCid, positionId)
    local c, cid = Access(src, P, companyId, { perm = 'manage_positions' })
    if not c then return false, cid end
    local tcid = Target(c, targetCid)
    if not tcid or not Outranks(c, cid, tcid) then return false, _L('cannot_manage') end
    local pos = c.positions[tonumber(positionId) or -1]
    if not pos or pos.isBoss then return false, _L('invalid_position') end
    if not IsBoss(c, cid) and pos.grade >= GradeOf(c, cid) then return false, _L('position_too_high') end
    if c.employees[tcid].positionId == pos.id then return false, _L('same_position') end
    if not Framework.JobGradeExists(c.job, pos.grade) then return false, _L('job_missing_rsg', ('%s/%d'):format(c.job, pos.grade)) end
    return Moved(c, P, tcid, pos, pos.grade > GradeOf(c, tcid) and 'promote' or 'demote')
end)

Callback('staff:promote', function(src, P, companyId, targetCid)
    local c, cid = Access(src, P, companyId, { perm = 'promote' })
    if not c then return false, cid end
    local tcid = Target(c, targetCid)
    if not tcid or not Outranks(c, cid, tcid) then return false, _L('cannot_manage') end
    local pos = Neighbour(c, GradeOf(c, tcid), 1)
    if not pos then return false, _L('no_higher_position') end
    if not IsBoss(c, cid) and pos.grade >= GradeOf(c, cid) then return false, _L('position_too_high') end
    if not Framework.JobGradeExists(c.job, pos.grade) then return false, _L('job_missing_rsg', ('%s/%d'):format(c.job, pos.grade)) end
    return Moved(c, P, tcid, pos, 'promote')
end)

Callback('staff:demote', function(src, P, companyId, targetCid)
    local c, cid = Access(src, P, companyId, { perm = 'demote' })
    if not c then return false, cid end
    local tcid = Target(c, targetCid)
    if not tcid or not Outranks(c, cid, tcid) then return false, _L('cannot_manage') end
    local pos = Neighbour(c, GradeOf(c, tcid), -1)
    if not pos then return false, _L('no_lower_position') end
    if not Framework.JobGradeExists(c.job, pos.grade) then return false, _L('job_missing_rsg', ('%s/%d'):format(c.job, pos.grade)) end
    return Moved(c, P, tcid, pos, 'demote')
end)

Callback('staff:dismiss', function(src, P, companyId, targetCid)
    local c, cid = Access(src, P, companyId, { perm = 'dismiss' })
    if not c then return false, cid end
    local tcid = Target(c, targetCid)
    if tcid == cid then return false, _L('cannot_dismiss_self') end
    if not tcid or not Outranks(c, cid, tcid) then return false, _L('cannot_manage') end
    local name = c.employees[tcid].name
    return WithLock('employ:' .. tcid, function()
        Unemploy(c, tcid, P.name)
        DB.Activity(c.id, 'dismiss', Actor(P), _L('act_dismiss', P.name, name))
        local s = Framework.Online(tcid)
        if s then Notify(s, _L('you_dismissed', c.name), 'error') end
        return true, _L('staff_dismissed', name)
    end)
end)

-- leaving on your own (not the Boss)
Callback('staff:quit', function(src, P, companyId)
    local c, cid = Access(src, P, companyId, { inactive = true })
    if not c then return false, cid end
    if IsBoss(c, cid) then return false, _L('boss_cannot_quit') end
    Unemploy(c, cid, P.name)
    DB.Activity(c.id, 'quit', Actor(P), _L('act_quit', P.name))
    return true, _L('you_quit', c.name)
end)

Callback('staff:offDuty', function(src, P, companyId, targetCid)
    local c, cid = Access(src, P, companyId, { perm = 'manage_duty' })
    if not c then return false, cid end
    local tcid = Target(c, targetCid)
    if not tcid or (tcid ~= cid and not Outranks(c, cid, tcid)) then return false, _L('cannot_manage') end
    if not c.duty[tcid] then return false, _L('not_on_duty') end
    SetDuty(c, tcid, false, 'forced')
    return true, _L('staff_off_duty', c.employees[tcid].name)
end)

Callback('staff:list', function(src, P, companyId)
    local c, cid = Access(src, P, companyId)
    if not c then return false, cid end
    return true, EmployeesList(c), PositionsList(c)
end, { noLimit = true })

---------------------------------------------------------------------------
-- Positions
---------------------------------------------------------------------------
local function CleanPerms(c, cid, perms)
    perms = Permissions.Clean(perms)
    if IsBoss(c, cid) then return perms end
    -- nobody can hand out a permission they do not have themselves
    local mine = PermsOf(c, cid)
    for k in pairs(perms) do if not mine[k] then perms[k] = nil end end
    return perms
end

Callback('position:save', function(src, P, companyId, d)
    local c, cid = Access(src, P, companyId, { perm = 'manage_positions' })
    if not c then return false, cid end
    if type(d) ~= 'table' then return false, _L('error') end
    local name = Co.Text(d.name, 40, 2)
    if not name then return false, _L('invalid_position_name') end
    local grade = math.floor(tonumber(d.grade) or -1)
    local boss = BossPosition(c)
    if grade < 0 or grade >= (boss and boss.grade or Config.Creation.bossGrade) then return false, _L('invalid_grade', (boss and boss.grade or 1) - 1) end
    if not IsBoss(c, cid) and grade >= GradeOf(c, cid) then return false, _L('position_too_high') end
    if not Framework.JobGradeExists(c.job, grade) then return false, _L('job_missing_rsg', ('%s/%d'):format(c.job, grade)) end
    for _, p in pairs(c.positions) do
        if p.grade == grade and p.id ~= tonumber(d.id) then return false, _L('grade_taken', grade, p.name) end
    end
    local desc = Co.Text(d.description, 255, 0)
    local perms = CleanPerms(c, cid, d.perms)

    local id = tonumber(d.id)
    if id then
        local p = c.positions[id]
        if not p then return false, _L('invalid_position') end
        if p.isBoss then return false, _L('boss_locked') end
        if not IsBoss(c, cid) and p.grade >= GradeOf(c, cid) then return false, _L('position_too_high') end
        MySQL.update.await('UPDATE fks_company_positions SET name = ?, grade = ?, description = ?, permissions = ? WHERE id = ?',
            { name, grade, desc, json.encode(perms), id })
        local gradeChanged = p.grade ~= grade
        p.name, p.grade, p.description, p.perms = name, grade, desc, perms
        -- employees in it: new grade in the framework, new permissions on their screen
        for ecid, e in pairs(c.employees) do
            if e.positionId == id then
                if gradeChanged then Framework.SetJobAny(ecid, c.job, grade, c.name) end
                SyncMeCid(ecid)
            end
        end
        DB.Activity(c.id, 'position', Actor(P), _L('act_position_edit', P.name, name))
    else
        local count = 0
        for _ in pairs(c.positions) do count = count + 1 end
        if count >= 20 then return false, _L('too_many_positions') end
        id = MySQL.insert.await('INSERT INTO fks_company_positions (company_id, name, grade, is_boss, description, permissions) VALUES (?, ?, ?, 0, ?, ?)',
            { c.id, name, grade, desc, json.encode(perms) })
        if not id then return false, _L('grade_taken', grade, '?') end
        c.positions[id] = { id = id, name = name, grade = grade, isBoss = false, description = desc, perms = perms }
        DB.Activity(c.id, 'position', Actor(P), _L('act_position_new', P.name, name))
    end
    return true, _L('position_saved', name), PositionsList(c)
end)

Callback('position:delete', function(src, P, companyId, id)
    local c, cid = Access(src, P, companyId, { perm = 'manage_positions' })
    if not c then return false, cid end
    local p = c.positions[tonumber(id) or -1]
    if not p then return false, _L('invalid_position') end
    if p.isBoss then return false, _L('boss_locked') end
    if not IsBoss(c, cid) and p.grade >= GradeOf(c, cid) then return false, _L('position_too_high') end
    for _, e in pairs(c.employees) do
        if e.positionId == p.id then return false, _L('position_in_use') end
    end
    for _, k in pairs(Contracts) do
        if k.positionId == p.id then return false, _L('position_in_use') end
    end
    MySQL.update.await('DELETE FROM fks_company_positions WHERE id = ?', { p.id })
    c.positions[p.id] = nil
    DB.Activity(c.id, 'position', Actor(P), _L('act_position_delete', P.name, p.name))
    return true, _L('position_deleted', p.name), PositionsList(c)
end)

-- pending contracts of a company go away with it (deletion / suspension)
function CancelContracts(c)
    for _, k in pairs(Contracts) do
        if k.company == c.id then
            Close(k, 'cancelled')
            TriggerClientEvent('fks-companies:client:contractClosed', k.employeeSrc, k.token)
        end
    end
end
