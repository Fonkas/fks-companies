---------------------------------------------------------------------------
-- Permissions (server). Every action of the resource goes through Access() before it touches anything.
-- The Boss has every permission; others have the ones of their position. A suspended / inactive company
-- refuses everything except reading.
---------------------------------------------------------------------------

-- { perm = true } of a character in a company
function PermsOf(c, cid)
    local e = c and c.employees[tostring(cid)]
    local pos = e and c.positions[e.positionId]
    if not pos then return {} end
    if pos.isBoss then return Permissions.All() end
    return pos.perms
end

function IsBoss(c, cid)
    local e = c and c.employees[tostring(cid)]
    local pos = e and c.positions[e.positionId]
    return pos ~= nil and pos.isBoss and c.owner ~= nil and c.owner.cid == tostring(cid)
end

function Can(c, cid, perm)
    if IsBoss(c, cid) then return true end
    return PermsOf(c, cid)[perm] == true
end

-- grade of a character inside their company (-1 = not an employee)
function GradeOf(c, cid)
    local e = c and c.employees[tostring(cid)]
    local pos = e and c.positions[e.positionId]
    return pos and pos.grade or -1
end

--[[
    The company of the player + checks. opts:
      perm     = permission needed (nil = just be an employee)
      boss     = must be the Boss
      inactive = allowed while the company is suspended / inactive (read only screens)
    returns c, cid | nil, error text
]]
function Access(src, P, companyId, opts)
    opts = opts or {}
    local cid = tostring(P.cid)
    local c = Companies[EmployeeOf[cid]]
    if not c or (companyId ~= nil and c.id ~= tonumber(companyId)) then return nil, _L('not_employee') end
    if not opts.inactive and not IsActive(c) then return nil, _L('company_inactive') end
    if opts.boss and not IsBoss(c, cid) then return nil, _L('boss_only') end
    if opts.perm and not Can(c, cid, opts.perm) then return nil, _L('no_permission') end
    return c, cid
end

-- may `actor` act on `target`? (only on lower grades; nobody acts on the Boss; nobody acts on themselves)
function Outranks(c, actorCid, targetCid)
    if tostring(actorCid) == tostring(targetCid) then return false end
    if IsBoss(c, targetCid) then return false end
    if IsBoss(c, actorCid) then return true end
    return GradeOf(c, actorCid) > GradeOf(c, targetCid)
end

function IsAdmin(src)
    return Bridge.IsAdmin(src, Config.AdminManagement.AllowedGroups or Config.AdminGroups)
end
