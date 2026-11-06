---------------------------------------------------------------------------
-- Company permissions. The Boss always has all of them; every other position gets the ones the owner
-- turns on. The server checks them on every action (server/permissions.lua).
---------------------------------------------------------------------------
Permissions = {}

-- order = order of the toggles in the position editor; group = section in the editor
Permissions.List = {
    { key = 'open_management',          group = 'general' },
    { key = 'view_overview',            group = 'general' },
    { key = 'edit_info',                group = 'general' },
    { key = 'hire',                     group = 'staff' },
    { key = 'dismiss',                  group = 'staff' },
    { key = 'promote',                  group = 'staff' },
    { key = 'demote',                   group = 'staff' },
    { key = 'manage_positions',         group = 'staff' },
    { key = 'manage_duty',              group = 'staff' },
    { key = 'access_ledger',            group = 'money' },
    { key = 'deposit',                  group = 'money' },
    { key = 'withdraw',                 group = 'money' },
    { key = 'charge_customers',         group = 'money' },
    { key = 'access_boss_storage',      group = 'storage' },
    { key = 'access_general_storage',   group = 'storage' },
    { key = 'manage_storage_locations', group = 'storage' },
    { key = 'manage_register',          group = 'storage' },
    { key = 'manage_customization',     group = 'identity' },
    { key = 'change_name',              group = 'identity' },
    { key = 'change_blip',              group = 'identity' },
    { key = 'manage_store',             group = 'store' },
    { key = 'manage_store_inventory',   group = 'store' },
}

Permissions.Groups = { 'general', 'staff', 'money', 'storage', 'identity', 'store' }

Permissions.Valid = {}
for _, p in ipairs(Permissions.List) do Permissions.Valid[p.key] = true end

-- keeps only known permission keys: accepts { key = true } or { 'key', ... }
function Permissions.Clean(t)
    local out = {}
    if type(t) ~= 'table' then return out end
    for k, v in pairs(t) do
        if type(k) == 'number' and type(v) == 'string' and Permissions.Valid[v] then out[v] = true
        elseif type(k) == 'string' and Permissions.Valid[k] and v == true then out[k] = true end
    end
    return out
end

function Permissions.All()
    local out = {}
    for k in pairs(Permissions.Valid) do out[k] = true end
    return out
end
