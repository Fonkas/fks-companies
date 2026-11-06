---------------------------------------------------------------------------
-- Framework compatibility layer (server). Everything fks-core's Bridge does not cover yet lives here, once
-- for VORP and once for RSG: setting jobs (online / offline), crediting cash to an offline character,
-- listing a player's items and item pictures. The rest of the resource only calls Framework.* / Bridge.*.
---------------------------------------------------------------------------
Framework = {}

local function IsVorp() return Bridge.Framework() == 'vorp' end
local function IsRsg() return Bridge.Framework() == 'rsg' end

-- server id + bridge player of the character `cid` when that character is loaded
function Framework.Online(cid)
    if not cid then return nil end
    cid = tostring(cid)
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local P = Bridge.GetPlayer(src)
        if P and tostring(P.cid) == cid then return src, P end
    end
end

-- is the ACCOUNT that owns this character connected (maybe in the character selection)?
-- VORP: characters.identifier (steam) · RSG: players.license
function Framework.AccountOnline(cid)
    local ident
    if IsVorp() then
        ident = MySQL.scalar.await('SELECT identifier FROM characters WHERE charidentifier = ?', { tonumber(cid) or cid })
    elseif IsRsg() then
        ident = MySQL.scalar.await('SELECT license FROM players WHERE citizenid = ?', { cid })
    end
    if not ident then return false, false end
    for _, id in ipairs(GetPlayers()) do
        for _, v in ipairs(GetPlayerIdentifiers(id) or {}) do
            if v == ident then return true, true end
        end
    end
    return false, true
end

-- character name of an offline character (nil when it does not exist)
function Framework.OfflineName(cid)
    if IsVorp() then
        local r = MySQL.single.await('SELECT firstname, lastname FROM characters WHERE charidentifier = ?', { tonumber(cid) or cid })
        return r and ('%s %s'):format(r.firstname or '', r.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '') or nil
    elseif IsRsg() then
        local r = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { cid })
        local ci = r and r.charinfo and json.decode(r.charinfo)
        return ci and ('%s %s'):format(ci.firstname or '', ci.lastname or '') or nil
    end
end

---------------------------------------------------------------------------
-- Jobs
---------------------------------------------------------------------------
local function RsgJob(job)
    local rsg = Bridge.RSG()
    return rsg and rsg.Shared and rsg.Shared.Jobs and rsg.Shared.Jobs[job]
end

-- RSG needs the job and grade in rsg-core/shared/jobs.lua; VORP accepts any job / grade
function Framework.JobGradeExists(job, grade)
    if not IsRsg() then return true end
    local j = RsgJob(job)
    if not j then return false end
    return j.grades ~= nil and (j.grades[tostring(grade)] ~= nil or j.grades[grade] ~= nil)
end

function Framework.JobExists(job)
    if not IsRsg() then return true end
    return RsgJob(job) ~= nil
end

-- ok, error key
function Framework.SetJob(src, job, grade, label)
    grade = math.floor(tonumber(grade) or 0)
    local rsg, vorp = Bridge.RSG(), Bridge.VORP()
    if rsg then
        local P = rsg.Functions.GetPlayer(src)
        if not P then return false, 'player_offline' end
        local ok, res = pcall(P.Functions.SetJob, job, grade)
        if not ok or res == false then
            print(('^1[fks-companies] rsg-core could not set job "%s" grade %d - add it to rsg-core/shared/jobs.lua^0'):format(job, grade))
            return false, 'job_missing'
        end
    elseif vorp then
        local user = vorp.getUser(src)
        local char = user and user.getUsedCharacter
        if not char then return false, 'player_offline' end
        local ok = pcall(function()
            char.setJob(job, true)
            char.setJobGrade(grade, true)
            char.setJobLabel(label or job)
        end)
        if not ok then return false, 'error' end
    else
        return false, 'error'
    end
    TriggerClientEvent('fks-companies:client:jobChanged', src)
    return true
end

-- offline character: written in the framework's own table (the framework reads it on the next login)
function Framework.SetJobOffline(cid, job, grade, label)
    grade = math.floor(tonumber(grade) or 0)
    if IsVorp() then
        MySQL.update.await('UPDATE characters SET job = ?, jobgrade = ?, joblabel = ? WHERE charidentifier = ?',
            { job, grade, label or job, tonumber(cid) or cid })
        return true
    elseif IsRsg() then
        local j = RsgJob(job) or {}
        local g = j.grades and (j.grades[tostring(grade)] or j.grades[grade]) or {}
        local data = {
            name = job, label = j.label or label or job, payment = g.payment or 0, onduty = false,
            type = j.type, isboss = g.isboss == true, grade = { name = g.name or tostring(grade), level = grade },
        }
        MySQL.update.await('UPDATE players SET job = ? WHERE citizenid = ?', { json.encode(data), cid })
        return true
    end
    return false
end

-- online (through the framework) or offline (database)
function Framework.SetJobAny(cid, job, grade, label)
    local src = Framework.Online(cid)
    if src then return Framework.SetJob(src, job, grade, label) end
    return Framework.SetJobOffline(cid, job, grade, label)
end

function Framework.Unemploy(cid)
    return Framework.SetJobAny(cid, Config.Jobs.unemployed, Config.Jobs.unemployedGrade, Config.Jobs.unemployed)
end

-- RSG keeps its own on-duty flag on the job: mirror ours into it (VORP has none)
function Framework.SetDuty(src, on)
    local rsg = Bridge.RSG()
    if not rsg then return end
    local P = rsg.Functions.GetPlayer(src)
    if P and P.Functions.SetJobDuty then pcall(P.Functions.SetJobDuty, on == true) end
end

---------------------------------------------------------------------------
-- Money: cash on hand only
---------------------------------------------------------------------------
-- credits cash to an OFFLINE character straight in the framework table. Returns true when one row changed.
function Framework.AddOfflineCash(cid, amount)
    amount = Co.Money(amount)
    if not amount or amount <= 0 then return false end
    if IsVorp() then
        local n = MySQL.update.await('UPDATE characters SET money = money + ? WHERE charidentifier = ?', { amount, tonumber(cid) or cid })
        return (n or 0) == 1
    elseif IsRsg() then
        local n = MySQL.update.await([[UPDATE players
            SET money = JSON_SET(money, '$.cash', CAST(COALESCE(JSON_EXTRACT(money, '$.cash'), 0) AS DECIMAL(14,2)) + ?)
            WHERE citizenid = ?]], { amount, cid })
        return (n or 0) == 1
    end
    return false
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
local imageCache = {}

-- picture of an item from the inventory in use (Config.Store.ItemImagePath wins)
function Framework.ItemImage(item)
    if imageCache[item] then return imageCache[item] end
    local img
    if Config.Store.ItemImagePath then
        img = Config.Store.ItemImagePath:gsub('{name}', item)
    else
        local inv = Bridge.Inventory()
        if inv == 'rsg-inventory' then
            local rsg = Bridge.RSG()
            local data = rsg and rsg.Shared and rsg.Shared.Items and rsg.Shared.Items[item]
            img = 'nui://rsg-inventory/html/images/' .. (data and data.image or (item .. '.png'))
        elseif inv == 'ox_inventory' then
            local ok, data = pcall(function() return exports.ox_inventory:Items(item) end)
            local i = ok and data and data.client and data.client.image
            img = (i and i:find('://')) and i or ('nui://ox_inventory/web/images/' .. (i or (item .. '.png')))
        else
            img = 'nui://vorp_inventory/html/img/items/' .. item .. '.png'
        end
    end
    imageCache[item] = img
    return img
end

-- blacklisted for the company stores? (exact names + prefixes, case-insensitive)
local black
function Framework.Blacklisted(item)
    if type(item) ~= 'string' then return true end
    if not black then
        black = {}
        for _, n in ipairs(Config.Store.Blacklist or {}) do black[n:lower()] = true end
    end
    local low = item:lower()
    if black[low] then return true end
    for _, p in ipairs(Config.Store.BlacklistPrefixes or {}) do
        if low:sub(1, #p) == p:lower() then return true end
    end
    return false
end

-- items the player carries, merged by name: { { name, label, count } } (weapons / blacklisted left out)
function Framework.InventoryItems(src)
    local inv = Bridge.Inventory()
    local merged, order = {}, {}
    local function add(name, label, count)
        count = math.floor(tonumber(count) or 0)
        if type(name) ~= 'string' or count < 1 or Framework.Blacklisted(name) then return end
        if not merged[name] then
            merged[name] = { name = name, label = label or Bridge.ItemLabel(name), count = 0 }
            order[#order + 1] = name
        end
        merged[name].count = merged[name].count + count
    end

    local ok, err = pcall(function()
        if inv == 'vorp_inventory' then
            for _, it in pairs(exports.vorp_inventory:getUserInventoryItems(src) or {}) do
                if it.type == nil or it.type == 'item_standard' then add(it.name, it.label, it.count) end
            end
        elseif inv == 'ox_inventory' then
            for _, it in pairs(exports.ox_inventory:GetInventoryItems(src) or {}) do add(it.name, it.label, it.count) end
        elseif inv == 'rsg-inventory' then
            local rsg = Bridge.RSG()
            local P = rsg and rsg.Functions.GetPlayer(src)
            for _, it in pairs(P and P.PlayerData.items or {}) do
                if it.type ~= 'weapon' then add(it.name, it.label, it.amount or it.count) end
            end
        end
    end)
    if not ok then print(('^1[fks-companies] could not read the inventory of %s: %s^0'):format(src, tostring(err))) end

    local list = {}
    for _, name in ipairs(order) do
        -- trust the inventory's own count (it is what RemoveItem will check)
        local it = merged[name]
        it.count = math.min(it.count, Bridge.ItemCount(src, name))
        if it.count > 0 then
            it.img = Framework.ItemImage(name)
            list[#list + 1] = it
        end
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    return list
end
