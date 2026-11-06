---------------------------------------------------------------------------
-- World: the props of every placed point (storages, register) and the store NPC, spawned locally when the
-- player is close, and the prompts at each point. Cheap when far away: one distance pass per second over
-- the companies; the per-frame prompt loop only runs next to a point.
---------------------------------------------------------------------------
local spawned = {}       -- [companyId] = { [kind] = { entity, key } }   key = what it was spawned from
local nearby = {}        -- [companyId] = true (within Config.Interact.propDistance)

local PROP_KINDS = { 'boss_storage', 'general_storage', 'register' }

local function Key(l, extra) return ('%.2f|%.2f|%.2f|%.1f|%s|%s'):format(l.x, l.y, l.z, l.h or 0, tostring(l.model), tostring(extra)) end

local function Despawn(id, kind)
    local s = spawned[id] and spawned[id][kind]
    if not s then return end
    if DoesEntityExist(s.entity) then DeleteEntity(s.entity) end
    spawned[id][kind] = nil
end

local function DespawnAll(id)
    for kind in pairs(spawned[id] or {}) do Despawn(id, kind) end
    spawned[id] = nil
end

-- brings the entities of one company in line with its current state (no duplicates: same key = keep).
-- Spawning yields (models, outfits), so one refresh per company runs at a time; a change that arrives
-- meanwhile runs another pass right after.
local busy, dirty = {}, {}
local DoRefresh
local function Refresh(id)
    if busy[id] then dirty[id] = true return end
    busy[id] = true
    repeat
        dirty[id] = nil
        local ok, err = pcall(DoRefresh, id)
        if not ok then print(('^1[fks-companies] refresh %s: %s^0'):format(id, err)) end
    until not dirty[id]
    busy[id] = nil
end

function DoRefresh(id)
    local c = Companies[id]
    if not c or not nearby[id] then DespawnAll(id) return end
    spawned[id] = spawned[id] or {}
    local active = c.status == 'active'

    for _, kind in ipairs(PROP_KINDS) do
        local l = active and c.locations[kind]
        local model = l and (l.model or Config.Props[kind][1])
        local key = l and Key(l, model)
        local s = spawned[id][kind]
        if not l then
            Despawn(id, kind)
        elseif not s or s.key ~= key or not DoesEntityExist(s.entity) then
            Despawn(id, kind)
            local obj = ValidModel(model) and SpawnProp(model, l) or nil
            if obj then spawned[id][kind] = { entity = obj, key = key } end
        end
    end

    -- the store NPC only while the store is open (nobody on duty)
    local l = c.locations.store
    local open = active and c.store.open and l ~= nil
    if not open then
        Despawn(id, 'store')
    else
        local model = l.model or c.store.model or Config.Store.DefaultModel
        local key = Key(l, model)
        local s = spawned[id].store
        if not s or s.key ~= key or not DoesEntityExist(s.entity) then
            Despawn(id, 'store')
            local ped = SpawnNpc(model, l)
            if ped then spawned[id].store = { entity = ped, key = key } end
        end
    end
end

OnCompanyChange(function(id, c)
    if not c then DespawnAll(id) nearby[id] = nil return end
    CreateThread(function() Refresh(id) end)
end)

-- one pass per second: which companies are close enough to have their props
CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        local range = Config.Interact.propDistance
        for id, c in pairs(Companies) do
            local near = #(pos - vector3(c.coords.x, c.coords.y, c.coords.z)) < range + Config.Placement.maxDistance
            if near ~= (nearby[id] == true) then
                nearby[id] = near or nil
                Refresh(id)
            elseif near and spawned[id] then
                -- an entity can be removed by the game (cleanup): put it back
                for kind, s in pairs(spawned[id]) do
                    if not DoesEntityExist(s.entity) then spawned[id][kind] = nil Refresh(id) break end
                end
            end
        end
        Wait(1000)
    end
end)

---------------------------------------------------------------------------
-- Ground marker on the company point (Config.Marker): flat, always there while the player is close
---------------------------------------------------------------------------
local groundZ = {}       -- [companyId] = { key, z }  ground under the point (the point is saved at the admin's hips)

local function MarkerZ(c)
    local key = ('%.2f|%.2f|%.2f'):format(c.coords.x, c.coords.y, c.coords.z)
    local g = groundZ[c.id]
    if g and g.key == key then return g.z end
    local ok, z = GetGroundZFor_3dCoord(c.coords.x, c.coords.y, c.coords.z + 1.0, false)
    -- no ground found (not streamed yet): use the usual hips offset and try again later
    if not ok or math.abs(z - c.coords.z) > 3.0 then return c.coords.z - 0.98 end
    groundZ[c.id] = { key = key, z = z }
    return z
end

CreateThread(function()
    local M = Config.Marker
    if not M or not M.enabled then return end
    local sx, sy, sz = M.scale[1], M.scale[2], M.scale[3]
    local r, g, b, a = M.color[1], M.color[2], M.color[3], M.color[4]
    while true do
        local wait = 1000
        local pos = GetEntityCoords(PlayerPedId())
        for id, c in pairs(Companies) do
            if nearby[id] and c.status == 'active' and (M.showTo ~= 'employees' or Me.company == id)
                and #(pos - vector3(c.coords.x, c.coords.y, c.coords.z)) < M.distance then
                wait = 0
                Citizen.InvokeNative(0x2A32FAA57B937173, 0x94FDAE17, c.coords.x, c.coords.y, MarkerZ(c) + 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    sx, sy, sz, r, g, b, a, false, false, 2, false, nil, nil, false)                         -- DrawMarker
            end
        end
        Wait(wait)
    end
end)

---------------------------------------------------------------------------
-- Prompts
---------------------------------------------------------------------------
local group = Prompts.Group()
local pMain = Prompts.Make(group, Config.Keys.interact, _L('p_manage'))
local pBuy = Prompts.Make(group, Config.Keys.secondary, _L('p_offer'))
local pBoss = Prompts.Make(group, Config.Keys.interact, _L('p_boss_storage'))
local pGeneral = Prompts.Make(group, Config.Keys.interact, _L('p_general_storage'))
local pRegister = Prompts.Make(group, Config.Keys.interact, _L('p_register'))
local pStore = Prompts.Make(group, Config.Keys.interact, _L('p_store'))
local ALL = { pMain, pBuy, pBoss, pGeneral, pRegister, pStore }


local function Dist(pos, l) return l and #(pos - vector3(l.x, l.y, l.z)) or math.huge end

-- what is offered at this spot: list of { prompt, run } + the group label
local function Offers(c, pos)
    local d = Config.Interact.distance
    local mine = Me.company == c.id
    local list, label = {}, c.name
    if c.status ~= 'active' then return list, label end

    if Dist(pos, c.coords) <= d then
        if mine and Can('open_management') then list[#list + 1] = { pMain, function() Management.Open() end } end
        if c.forSale then list[#list + 1] = { pBuy, function() Market.Open(c.id) end } end
    end
    if mine and Can('access_boss_storage') and Dist(pos, c.locations.boss_storage) <= d then
        list[#list + 1] = { pBoss, function()
            local ok, err = Call('storage', c.id, 'boss')
            if not ok then Notify(err, 'error') end
        end }
        label = _L('loc_boss_storage')
    end
    if mine and Can('access_general_storage') and Dist(pos, c.locations.general_storage) <= d then
        list[#list + 1] = { pGeneral, function()
            local ok, err = Call('storage', c.id, 'general')
            if not ok then Notify(err, 'error') end
        end }
        label = _L('loc_general_storage')
    end
    if mine and Dist(pos, c.locations.register) <= d then
        list[#list + 1] = { pRegister, function() Register.Open(c.id) end }
        label = _L('loc_register')
    end
    if c.store.open and Dist(pos, c.locations.store) <= d + 0.5 then
        list[#list + 1] = { pStore, function() Store.Open(c.id) end }
        label = c.name
    end
    return list, label
end

-- The offers are worked out every checkInterval; in between the same prompts stay up every frame. A prompt is
-- only hidden when it is no longer offered (or the player walks off / opens a window), so nothing blinks.
local visible = {}       -- [prompt] = true while shown

local function ShowOnly(shown)
    for _, p in ipairs(ALL) do
        local on = shown[p] ~= nil
        if (visible[p] == true) ~= on then
            Prompts.Show(p, on)
            visible[p] = on or nil
        end
    end
end

local function Hide() ShowOnly({}) end

CreateThread(function()
    while true do
        local wait = 1000
        local shown
        local label
        if Bridge.IsLoggedIn() and not Placement.active and CanAct() then
            local pos = GetEntityCoords(PlayerPedId())
            local best, bestD
            for id, c in pairs(Companies) do
                if nearby[id] then
                    local dd = #(pos - vector3(c.coords.x, c.coords.y, c.coords.z))
                    if dd < Config.Interact.nearCompany + Config.Placement.maxDistance and (not bestD or dd < bestD) then best, bestD = c, dd end
                end
            end
            if best then
                wait = Config.Interact.checkInterval
                local list
                list, label = Offers(best, pos)
                if #list > 0 then
                    shown = {}
                    for _, o in ipairs(list) do shown[o[1]] = o[2] end
                end
            end
        end

        if not shown then
            Hide()
            Wait(wait)
        else
            ShowOnly(shown)
            -- every frame until the next check: keep the group active, fire a completed prompt
            local t = GetGameTimer() + Config.Interact.checkInterval
            local fired
            while GetGameTimer() < t and CanAct() and not Placement.active do
                Prompts.Active(group, label)
                for p, run in pairs(shown) do
                    if Prompts.Done(p) then fired = run break end
                end
                if fired then break end
                Wait(0)
            end
            -- no Wait between two passes: a frame without Prompts.Active makes the group text blink
            if fired or not CanAct() or Placement.active then
                Hide()
                if fired then fired() end
                Wait(0)
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(spawned) do DespawnAll(id) end
    for _, p in ipairs(ALL) do PromptDelete(p) end
end)
