-- fks-companies · Copyright (C) 2026 FKS · Licensed under the GNU GPL v3 or later (see LICENSE)
fx_version 'cerulean'
game 'rdr3'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
lua54 'yes'

name 'fks-companies'
author 'FKS'
description 'Company management for RedM (VORP / RSG): employees, contracts, positions, ledger, taxes, storages, register, duty, NPC stores and a company marketplace'
version '1.0.0'
license 'GPL-3.0-or-later'
fks_core_version '2.1.2' -- minimum fks-core version (VORP / RSG bridge, shared UI, notifications)

shared_scripts {
    '@ox_lib/init.lua',
    '@fks-core/import.lua',
    'shared/config.lua',
    'locales/*.lua',
    'shared/locales.lua',
    'shared/blips.lua',
    'shared/permissions.lua',
    'shared/utils.lua',
}

client_scripts {
    'client/main.lua',
    'client/placement.lua',
    'client/interactions.lua',
    'client/documents.lua',
    'client/register.lua',
    'client/management.lua',
    'client/customization.lua',
    'client/store.lua',
    'client/market.lua',
    'client/companies.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/db.lua',
    'server/framework.lua',
    'server/main.lua',
    'server/permissions.lua',
    'server/finances.lua',
    'server/companies.lua',
    'server/employees.lua',
    'server/billing.lua',
    'server/marketplace.lua',
    'server/store.lua',
    'server/admin.lua',
}

-- the contract / bill documents are an fks-core UI extension (loaded into the fks-core NUI, no ui_page here)
files {
    'ui/documents.js',
    'ui/documents.css',
    'sql/install.sql',
    'ui/icons/*.png',     -- menu button pictures (Config.MenuIcons)
    -- 'html/blips/*.png',  -- uncomment only with Config.BlipImages.source = 'local' and the PNGs in html/blips (see README)
}

-- + fks-core 2.1.2+ (shared UI and VORP / RSG bridge) - https://github.com/Fonkas/fks-core
-- + a framework (vorp_core or rsg-core) and an inventory (vorp_inventory, rsg-inventory or ox_inventory)
dependencies {
    'ox_lib',
    'oxmysql',
}
