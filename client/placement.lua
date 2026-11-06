---------------------------------------------------------------------------
-- Placement: the fks-gangs idea (a see-through preview in front of the player, confirm to put it there)
-- with full control over the preview:
--   arrows   move it (relative to the camera)      Q / E   higher / lower
--   Z / X    rotate                                G       drop it on the ground
--   SHIFT    faster                                ENTER   confirm · BACKSPACE cancel
-- Works with props (storages, register) and peds (store NPC). Returns { x, y, z, h } or nil.
---------------------------------------------------------------------------
Placement = { active = false }

local K = Config.Placement.keys

local function Pressed(key) return IsControlPressed(0, key) or IsDisabledControlPressed(0, key) end
local function Just(key) return IsControlJustPressed(0, key) or IsDisabledControlJustPressed(0, key) end

local function Ground(x, y, z)
    local ok, gz = GetGroundZFor_3dCoord(x, y, z + 1.0, false)
    return ok and gz or z
end

local function CamForward()
    local rot = GetGameplayCamRot(2)
    local h = math.rad(rot.z)
    return vector3(-math.sin(h), math.cos(h), 0.0), vector3(math.cos(h), math.sin(h), 0.0)
end

-- opts = { model, ped = bool, center = vector3 (company point), maxDistance, label }
function Placement.Start(opts)
    if Placement.active then return nil end
    local hash = LoadModel(opts.model)
    if not hash then Notify(_L('invalid_model'), 'error') return nil end
    Placement.active = true

    local ped = PlayerPedId()
    local start = GetEntityCoords(ped) + GetEntityForwardVector(ped) * Config.Placement.startDistance
    local lift = opts.ped and 1.0 or 0.0          -- a ped's origin is at its hips, not its feet
    local pos = vector3(start.x, start.y, Ground(start.x, start.y, start.z) + lift)
    local heading = (GetEntityHeading(ped) + 180.0) % 360.0
    -- the preview ped shows turned around compared with the spawned NPC: draw it 180° off so it matches
    local turn = opts.ped and 180.0 or 0.0
    local ghost
    if opts.ped then
        ghost = CreatePed(hash, pos.x, pos.y, pos.z, (heading + turn) % 360.0, false, false, false, false)
        PedOutfit(ghost)
        SetEntityInvincible(ghost, true)
        SetBlockingOfNonTemporaryEvents(ghost, true)
        ClearPedTasksImmediately(ghost)
    else
        ghost = CreateObject(hash, pos.x, pos.y, pos.z, false, false, false, false, false)
    end
    SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z, false, false, false)
    SetEntityHeading(ghost, (heading + turn) % 360.0)
    SetEntityAlpha(ghost, 170, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)

    local L = Config.Placement.keyLabels
    UI.Caption({ text = _L('placing', opts.label or ''), hints = {
        { L.move, _L('pl_move') }, { L.height, _L('pl_height') }, { L.rotate, _L('pl_rotate') },
        { L.snap, _L('pl_ground') }, { L.fast, _L('pl_fast') }, { L.confirm, _L('pl_confirm') }, { L.cancel, _L('cancel') },
    } })

    local maxDist = opts.maxDistance or Config.Placement.maxDistance
    local result
    local warned = 0
    while Placement.active do
        Wait(0)
        for _, k in pairs(K) do DisableControlAction(0, k, true) end
        DisableControlAction(0, 0x07CE1E61, true)   -- attack
        DisableControlAction(0, 0xF84FA74F, true)   -- aim

        local fast = Pressed(K.fast) and Config.Placement.fastFactor or 1.0
        local step, hstep, rstep = Config.Placement.moveStep * fast, Config.Placement.heightStep * fast, Config.Placement.rotateStep * fast
        local fwd, right = CamForward()
        local move = vector3(0.0, 0.0, 0.0)
        if Pressed(K.forward) then move = move + fwd * step end
        if Pressed(K.back) then move = move - fwd * step end
        if Pressed(K.right) then move = move + right * step end
        if Pressed(K.left) then move = move - right * step end
        if Pressed(K.up) then move = move + vector3(0.0, 0.0, hstep) end
        if Pressed(K.down) then move = move - vector3(0.0, 0.0, hstep) end
        if Pressed(K.rotLeft) then heading = (heading + rstep) % 360.0 end
        if Pressed(K.rotRight) then heading = (heading - rstep) % 360.0 end

        local nextPos = pos + move
        local me = GetEntityCoords(PlayerPedId())
        -- stays near the player (20 m) and inside the company area
        if #(nextPos - me) <= 20.0 and (not opts.center or #(nextPos - opts.center) <= maxDist) then
            pos = nextPos
        elseif #move > 0 and GetGameTimer() > warned then
            warned = GetGameTimer() + 2500
            Notify(_L('place_too_far', math.floor(maxDist)), 'warning')
        end
        if Just(K.snap) then pos = vector3(pos.x, pos.y, Ground(pos.x, pos.y, pos.z - lift) + lift) end

        SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z, false, false, false)
        SetEntityHeading(ghost, (heading + turn) % 360.0)
        -- marker under the preview: green inside the area
        Citizen.InvokeNative(0x2A32FAA57B937173, 0x94FDAE17, pos.x, pos.y, pos.z - lift - 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            0.6, 0.6, 0.05, 120, 200, 90, 140, false, false, 2, false, nil, nil, false)                      -- DrawMarker

        if Just(K.confirm) then
            result = { x = pos.x, y = pos.y, z = pos.z, h = heading }
            Placement.active = false
        elseif Just(K.cancel) or IsEntityDead(PlayerPedId()) or (opts.center and #(me - opts.center) > maxDist + 30.0) then
            Placement.active = false
        end
    end

    DeleteEntity(ghost)
    SetModelAsNoLongerNeeded(hash)
    UI.Caption(false)
    return result
end

function Placement.Cancel() Placement.active = false end

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and Placement.active then
        Placement.active = false
        UI.Caption(false)
    end
end)
