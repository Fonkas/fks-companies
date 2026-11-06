---------------------------------------------------------------------------
-- Client state: the public state of every company (from the server, kept up to date by events) and the
-- personal state of this player (company, position, permissions, duty). Map blips follow both.
---------------------------------------------------------------------------
Companies = {}           -- [id] = public state
Me = {}                  -- { cid, company, companyName, position, grade, boss, perms, onDuty, active }

local blips = {}         -- [id] = blip handle
local changeCbs = {}     -- cb(id, company|nil) on every company change

function OnCompanyChange(cb) changeCbs[#changeCbs + 1] = cb end
local function Changed(id, c) for _, cb in ipairs(changeCbs) do cb(id, c) end end

function Notify(msg, kind)
    Bridge.Notify({ title = _L('companies'), description = msg, type = kind or 'inform' })
end

-- server callback: ok, ... (a failed callback never throws)
function Call(name, ...)
    local res = table.pack(pcall(lib.callback.await, 'fks-companies:' .. name, false, ...))
    if not res[1] then return false, _L('error') end
    return table.unpack(res, 2, res.n)
end

function Can(perm)
    return Me.company ~= nil and Me.active and (Me.boss or (Me.perms and Me.perms[perm] == true))
end

function MyCompany() return Me.company and Companies[Me.company] or nil end

---------------------------------------------------------------------------
-- Blips: sprite = company blip, colour = green (someone on duty) / red (nobody)
---------------------------------------------------------------------------
local function ClearBlip(id)
    if blips[id] and DoesBlipExist(blips[id]) then RemoveBlip(blips[id]) end
    blips[id] = nil
end

local function DrawBlip(c)
    ClearBlip(c.id)
    if c.status ~= 'active' and not Config.Blips.showInactive then return end
    local blip = Citizen.InvokeNative(0x554D9D53F696D002, 1664425300, c.coords.x, c.coords.y, c.coords.z)   -- BlipAddForCoords
    SetBlipSprite(blip, c.blip, true)
    Citizen.InvokeNative(0x9CB1A1623062F402, blip, c.name)                                                 -- SetBlipName
    local mod = c.status ~= 'active' and 'BLIP_MODIFIER_MP_COLOR_26' or (c.onDuty > 0 and Config.Blips.colorOnDuty or Config.Blips.colorOffDuty)
    Citizen.InvokeNative(0x662D364ABF16DE2F, blip, joaat(mod))                                              -- BlipAddModifier
    blips[c.id] = blip
end

---------------------------------------------------------------------------
-- State from the server
---------------------------------------------------------------------------
local function Set(id, c)
    Companies[id] = c
    DrawBlip(c)
    Changed(id, c)
end

RegisterNetEvent('fks-companies:client:company', function(id, c)
    if type(c) ~= 'table' then return end
    Set(id, c)
end)

RegisterNetEvent('fks-companies:client:remove', function(id)
    Companies[id] = nil
    ClearBlip(id)
    Changed(id, nil)
end)

RegisterNetEvent('fks-companies:client:me', function(me)
    Me = type(me) == 'table' and me or {}
    TriggerEvent('fks-companies:client:meChanged', Me)
end)

local function Load()
    local ok, list, me = pcall(lib.callback.await, 'fks-companies:state', false)
    if not ok or type(list) ~= 'table' then return end
    for id in pairs(Companies) do ClearBlip(id) end
    Companies = {}
    for _, c in ipairs(list) do Set(c.id, c) end
    Me = type(me) == 'table' and me or {}
    TriggerEvent('fks-companies:client:meChanged', Me)
    -- command suggestions (chat started after us, or we restarted)
    TriggerEvent('chat:addSuggestion', '/' .. Config.Creation.command, _L('cmd_create_help'), {})
    TriggerEvent('chat:addSuggestion', '/' .. Config.AdminManagement.Command, _L('cmd_manage_help'), {})
    if Config.Marketplace.Enabled and Config.Marketplace.Command then
        TriggerEvent('chat:addSuggestion', '/' .. Config.Marketplace.Command, _L('cmd_market_help'), {})
    end
end

Bridge.OnLoaded(Load)                                                        -- character loaded / resource restart
RegisterNetEvent('fks-companies:client:refresh', function() if Bridge.IsLoggedIn() then Load() end end)
Bridge.OnUnloaded(function() Me = {} TriggerEvent('fks-companies:client:meChanged', Me) end)

---------------------------------------------------------------------------
-- Native prompts (same helpers as the other FKS scripts)
---------------------------------------------------------------------------
Prompts = {}

local function Var(text) return CreateVarString(10, 'LITERAL_STRING', text) end

function Prompts.Group() return GetRandomIntInRange(0, 0xffffff) end

function Prompts.Make(group, key, text)
    local p = PromptRegisterBegin()
    PromptSetControlAction(p, key)
    PromptSetText(p, Var(text))
    PromptSetEnabled(p, false)
    PromptSetVisible(p, false)
    PromptSetStandardMode(p, true)
    PromptSetGroup(p, group, 0)
    PromptRegisterEnd(p)
    return p
end

function Prompts.Text(p, text) PromptSetText(p, Var(text)) end
function Prompts.Show(p, on) PromptSetVisible(p, on) PromptSetEnabled(p, on) end
function Prompts.Active(group, label) PromptSetActiveGroupThisFrame(group, Var(label)) end
function Prompts.Done(p) return PromptHasStandardModeCompleted(p) end

---------------------------------------------------------------------------
-- Models / peds / props
---------------------------------------------------------------------------
function LoadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local t = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < t do Wait(10) end
    return HasModelLoaded(hash) and hash or nil
end

-- the round menu buttons: own picture per button value when Config.MenuIcons is on (see config)
function MenuIcons(items)
    local M = Config.MenuIcons
    if M and M.enabled then
        for _, it in ipairs(items) do
            if it.value then it.img = M.path:gsub('{name}', it.value) end
        end
    end
    return items
end

function ValidModel(model)
    return IsModelValid(type(model) == 'number' and model or joaat(model))
end

-- RedM peds are invisible until they wear an outfit
function PedOutfit(ped)
    Citizen.InvokeNative(0x283978A15512B2FE, ped, true)                              -- SetRandomOutfitVariation
    local t = GetGameTimer() + 3000
    while not Citizen.InvokeNative(0xA0BC8FAED8CFEB3C, ped) and GetGameTimer() < t do  -- IsPedReadyToRender
        Wait(10)
    end
    Citizen.InvokeNative(0xCC8CA3E88256E58F, ped, false, true, true, true, false)    -- UpdatePedVariation
    SetEntityVisible(ped, true)
end

-- local objects only: every client spawns its own copy, so nothing is duplicated over the network
function SpawnProp(model, c)
    local hash = LoadModel(model)
    if not hash then return nil end
    local obj = CreateObject(hash, c.x, c.y, c.z, false, false, false, false, false)
    -- CreateObject lifts the model by its bounding box; the placement preview did not, so put it exactly where it was confirmed
    SetEntityCoordsNoOffset(obj, c.x, c.y, c.z, false, false, false)
    SetEntityHeading(obj, c.h or 0.0)
    FreezeEntityPosition(obj, true)
    SetModelAsNoLongerNeeded(hash)
    return obj
end

function SpawnNpc(model, c)
    local hash = LoadModel(model)
    if not hash then return nil end
    local h = c.h or 0.0
    local ped = CreatePed(hash, c.x, c.y, c.z, h, false, false, false, false)
    PedOutfit(ped)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    -- no task may turn it: same position and heading as the confirmed preview
    ClearPedTasksImmediately(ped)
    SetEntityCoordsNoOffset(ped, c.x, c.y, c.z, false, false, false)
    SetEntityHeading(ped, h)
    FreezeEntityPosition(ped, true)
    TaskStandStill(ped, -1)
    SetModelAsNoLongerNeeded(hash)
    -- the ped's motion can still settle on its spawn facing during the first frames: keep the heading
    CreateThread(function()
        for _ = 1, 10 do
            Wait(100)
            if not DoesEntityExist(ped) then return end
            if math.abs(((GetEntityHeading(ped) - h + 180.0) % 360.0) - 180.0) > 1.0 then SetEntityHeading(ped, h) end
        end
    end)
    return ped
end

---------------------------------------------------------------------------
-- Blip picker (fco-blips, ui/documents.js): every allowed blip in one round-icon grid, searched and filtered in
-- the NUI. p = { name, value?, current?, label?, compact?, action? }
---------------------------------------------------------------------------
local blipItems, blipCats

function BlipPicker(p)
    if not blipItems then
        blipItems, blipCats = {}, {}
        local present = {}
        for _, b in ipairs(BlipCatalogue) do
            if Co.BlipAllowed(b.hash) then
                blipItems[#blipItems + 1] = { v = b.hash, i = Co.BlipImage(b.name), l = b.label, c = b.cat, n = b.name }
                present[b.cat] = true
            end
        end
        for _, cat in ipairs(Config.Blips.categories) do
            if present[cat] then blipCats[#blipCats + 1] = { value = cat, label = _L('cat_' .. cat) } end
        end
    end
    p.type = 'fco-blips'
    p.items, p.cats = blipItems, blipCats
    p.labels = {
        search = _L('blip_search_ph'), all = _L('cat_all'), current = _L('current_blip'), selected = _L('selected_blip'),
        none = _L('no_blip_selected'), empty = _L('no_blips'), results = _L('n_results', '%d'),
    }
    return p
end

function CanAct()
    local ped = PlayerPedId()
    return not IsEntityDead(ped) and not IsPedOnMount(ped) and not IsPedInAnyVehicle(ped, false) and not UI.IsOpen()
end

---------------------------------------------------------------------------
-- The `close` action has one handler per script: every file adds its own
---------------------------------------------------------------------------
local closeCbs = {}
function OnUIClose(cb) closeCbs[#closeCbs + 1] = cb end
UI.On('close', function(d)
    ActiveView = nil
    for _, cb in ipairs(closeCbs) do cb(d) end
end)

-- every navigation: the first module that answers wins
local pageCbs = {}
function OnUIPage(cb) pageCbs[#pageCbs + 1] = cb end
UI.On('page', function(d)
    for _, cb in ipairs(pageCbs) do
        local res = cb(d)
        if res then return res end
    end
end)

-- which of our windows is open ('management', 'register', 'store', 'market', 'admin', 'create'): opening one
-- replaces the other, so every module checks this before updating "its" window
ActiveView = nil
function OpenView(name, view, opts)
    local ok = UI.Open(view, opts)
    if ok then ActiveView = name end
    return ok
end

-- closes the panel when the player walks away from `pos` (or `stillOpen()` turns false)
function CloseWhenAway(pos, dist, stillOpen)
    CreateThread(function()
        while stillOpen() do
            if #(GetEntityCoords(PlayerPedId()) - pos) > dist then UI.Close() break end
            Wait(500)
        end
    end)
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(blips) do ClearBlip(id) end
end)
