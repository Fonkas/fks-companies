Config = Config or {}

-- Server console: "up to date" / "OUTDATED" compared with GitHub, and a warning when fks-core is missing
Config.VersionCheck = {
    enabled  = true,
    repo     = 'Fonkas/fks-companies',    -- GitHub "user/repository"
    branch   = 'main',
    interval = 12,                       -- check again every X hours (0 = only on start)
    coreUrl  = 'https://github.com/Fonkas/fks-core',
}

Config.Debug = false                    -- true: prints every financial / admin action in the server console

-- Language: 'en' | 'pt' (PT-PT) | 'br' (PT-BR) | 'es' | 'fr' | 'de' | 'it' (files in locales/; missing keys fall back to English)
Config.Locale = 'en'

---------------------------------------------------------------------------
-- Framework / inventory (read by the fks-core bridge)
---------------------------------------------------------------------------
Config.Framework = 'auto'               -- 'auto' | 'vorp' | 'rsg'
Config.Inventory = 'auto'               -- 'auto' | 'vorp_inventory' | 'rsg-inventory' | 'ox_inventory'
Config.RSGGoldAccount = nil             -- not used by this script (everything is paid in cash)

-- Money: every payment of this script uses cash on hand ('cash'). The bank is never touched.
Config.MoneyAccount = 'cash'

-- Job integration
Config.Jobs = {
    unemployed      = 'unemployed',     -- job given to dismissed employees
    unemployedGrade = 0,
    syncOnLoad      = true,             -- on character load, give an employee their company job / grade again if it changed
}

-- Administrators: VORP groups / RSG permissions (the `command` ACE and the console are always allowed)
Config.AdminGroups = { 'admin', 'superadmin' }

---------------------------------------------------------------------------
-- Company creation (/createnewcompany)
---------------------------------------------------------------------------
Config.Creation = {
    command          = 'createnewcompany',
    defaultBlip      = 819673798,       -- blip_shop_market_stall
    defaultMaxEmployees = 15,
    maxEmployeesLimit   = 100,          -- highest value an admin can set
    defaultPositions = {                -- created for every new company (the Boss is always added on top)
        { name = 'Manager',  grade = 3, permissions = { 'open_management', 'view_overview', 'hire', 'promote', 'demote', 'access_ledger', 'deposit', 'access_general_storage', 'charge_customers', 'manage_store_inventory', 'manage_duty' } },
        { name = 'Employee', grade = 1, permissions = { 'open_management', 'view_overview', 'deposit', 'access_general_storage', 'charge_customers', 'manage_store_inventory' } },
        { name = 'Trainee',  grade = 0, permissions = { 'access_general_storage', 'charge_customers' } },
    },
    bossName  = 'Boss',
    bossGrade = 4,                      -- framework grade of the Boss (RSG: the job must have this grade)
}

---------------------------------------------------------------------------
-- Storages: slots = grid slots (ox / rsg) and item capacity on vorp_inventory · weight in grams (ox / rsg)
---------------------------------------------------------------------------
Config.Storage = {
    boss    = { slots = 50,  weight = 100000 },
    general = { slots = 100, weight = 200000 },
    maxSlots  = false,                  -- highest value an admin can set (false = no limit)
    maxWeight = false,                  -- same for the weight (false = no limit)
    props = {
        boss_storage    = 'p_strongbox01x',
        general_storage = 'p_chest01x',
    },
}

-- Props an owner can choose for the storages / register (the first one is the default)
Config.Props = {
    boss_storage    = { 'p_strongbox01x', 'p_safe01x', 'p_chest01x' },
    general_storage = { 'p_chest01x', 'p_trunk04x', 'p_crate06x' },
    register        = { 'p_register03x', 'p_register01x', 'p_cashregister01x' },
}

---------------------------------------------------------------------------
-- Interaction
---------------------------------------------------------------------------
Config.Interact = {
    distance      = 2.0,                -- distance to a company point for its prompt
    propDistance  = 60.0,               -- props / NPCs spawn within this distance
    checkInterval = 500,                -- ms between "am I near a point?" checks (only near a company)
    nearCompany   = 80.0,               -- the precise checks only run within this distance of a company
}

-- Ground marker on the company point (where it was created and where it is managed)
Config.Marker = {
    enabled  = true,
    showTo   = 'all',                   -- 'all' | 'employees' (only the company's own employees see it)
    distance = 25.0,                    -- drawn within this distance of the point
    scale    = { 1.2, 1.2, 0.12 },      -- width, depth, height (low = flat on the ground)
    color    = { 242, 193, 78, 120 },   -- r, g, b, alpha
}

Config.Keys = {
    interact   = 0xCEFD9220,            -- E
    secondary  = 0x760A9C6F,            -- G
}

-- Placement (storages, register, store NPC). Same idea as fks-gangs (see-through preview in front of you),
-- plus height and free movement.
Config.Placement = {
    maxDistance   = 40.0,               -- how far from the company point things can be placed
    startDistance = 1.5,                -- preview starts this far in front of the player
    moveStep      = 0.03,               -- per frame
    heightStep    = 0.01,
    rotateStep    = 1.5,                -- degrees per frame
    fastFactor    = 4.0,                -- holding SHIFT
    keys = {
        confirm   = 0xC7B5340A,         -- ENTER
        cancel    = 0x156F7119,         -- BACKSPACE
        forward   = 0x6319DB71,         -- ARROW UP
        back      = 0x05CA7C52,         -- ARROW DOWN
        left      = 0xA65EBAB4,         -- ARROW LEFT
        right     = 0xDEB34313,         -- ARROW RIGHT
        up        = 0xDE794E3E,         -- Q  higher
        down      = 0xCEFD9220,         -- E  lower
        rotLeft   = 0x26E9DC00,         -- Z  rotate left
        rotRight  = 0x8CC9CD42,         -- X  rotate right
        snap      = 0x760A9C6F,         -- G  put it on the ground
        fast      = 0x8FFC75D6,         -- SHIFT
    },
    keyLabels = {
        confirm = 'ENTER', cancel = 'BACKSPACE', move = '↑ ↓ ← →', height = 'Q / E', rotate = 'Z / X', snap = 'G', fast = 'SHIFT',
    },
}

---------------------------------------------------------------------------
-- Ledger, taxes, identity
---------------------------------------------------------------------------
Config.Finance = {
    maxTransaction   = 1000000,         -- largest single deposit / withdrawal / charge
    historyPageSize  = 25,
}

Config.Taxes = {
    enabled          = true,            -- master switch (each company still has its own setting)
    default = { enabled = false, type = 'fixed', amount = 50, interval = 1440 },  -- interval in minutes
    minInterval      = 10,
    checkEvery       = 60,              -- seconds between tax checks on the server
    -- what happens when the company cannot pay:
    --   'skip'      = record the failure and try again next interval
    --   'partial'   = take whatever is left and record the rest as failed
    --   'suspend'   = record the failure and suspend the company after `suspendAfter` failures in a row
    failPolicy       = 'skip',
    suspendAfter     = 3,
}

Config.Identity = {
    nameChange = { enabled = true, price = 500, minLength = 3, maxLength = 40 },
    blipChange = { enabled = true, price = 250 },
}

-- Blip gallery. The femga repository only lists the texture names (no images), so the pictures come from:
--   'remote' : femga.com's public previews (works out of the box, needs internet on the client)
--   'local'  : html/blips/{name}.png inside this resource (download the "without bg" pack from the README of
--              the femga repository and unzip it there - see README.md)
Config.BlipImages = {
    source = 'remote',
    remote = 'https://femga.com:8080/images/samples/ui_textures_no_bg/blips/{name}.png',
    ['local'] = 'nui://fks-companies/html/blips/{name}.png',
}

-- Own pictures for the round menu buttons (Management, Customization), from ui/icons/{name}.png (white symbol,
-- transparent background, square 256x256). false = the built-in fks-core icons. Names: hire, staff, positions, sell, boss_storage, general_storage,
-- register, name, blip, store, products. A missing picture falls back to the built-in icon.
Config.MenuIcons = {
    enabled = true,
    path = 'nui://fks-companies/ui/icons/{name}.png',
}

-- Which blips can be chosen: 'all' = every blip of shared/blips.lua except `disabled`;
-- or a list of texture names / hashes that are the ONLY ones allowed.
Config.Blips = {
    allowed  = 'all',
    disabled = {                        -- never offered (mission / objective markers that confuse players)
        'blip_objective', 'blip_objective_minor', 'blip_overlay_ring', 'blip_overlay_white',
    },
    categories = { 'shops', 'ambient', 'horses', 'weapons', 'animals', 'missions', 'story', 'strangers', 'minigames', 'overlays', 'online', 'other' },
    colorOnDuty  = 'BLIP_MODIFIER_MP_COLOR_8',   -- green: at least one employee on duty
    colorOffDuty = 'BLIP_MODIFIER_MP_COLOR_2',   -- red: nobody on duty
    showInactive = false,               -- inactive / suspended companies keep their blip (grey) instead of hiding it
}

---------------------------------------------------------------------------
-- Duty
---------------------------------------------------------------------------
Config.Duty = {
    maxDistance   = 200.0,              -- an employee on duty farther than this from the company goes off duty
    checkInterval = 10,                 -- seconds between server distance checks (only players on duty are checked)
}

---------------------------------------------------------------------------
-- Cash register / payment requests
---------------------------------------------------------------------------
Config.Billing = {
    expiration     = 60,                -- seconds before a payment request expires
    maxDistance    = 10.0,              -- customer must be this close to the employee
    descriptionMax = 120,
    cooldown       = 5,                 -- seconds between two requests from the same employee
}

-- Employment contracts
Config.Contracts = {
    expiration     = 120,               -- seconds the target has to sign
    maxDistance    = 15.0,              -- the target must be near the employer
    descriptionMax = 400,
}

---------------------------------------------------------------------------
-- Company marketplace
---------------------------------------------------------------------------
Config.Marketplace = {
    Enabled              = true,
    Command              = 'companies',  -- opens the list of companies for sale (nil = no command)
    AllowPlayerSales     = true,
    AllowNegotiation     = false,        -- shows "negotiable" on listings (the price is still the price)
    RequireCashOnPurchase = true,        -- buyers always pay with cash on hand
    SellerPaymentAccount = 'cash',       -- always cash on hand (never the bank)
    MinPrice             = 100,
    MaxPrice             = 10000000,
    PreviousOwner        = 'dismiss',    -- what happens to the old Boss: 'dismiss' | 'demote' (to the highest position)
    -- what buyers can see of the finances: 'none' | 'balance' | 'full' (balance + income + expenses)
    FinancialPrivacy     = 'balance',
    -- offline seller payment: 'database' credits the framework table right away (when the account is not
    -- connected); otherwise it is credited on their next character load. Every payout is recorded once.
    OfflinePayment       = 'database',
}

---------------------------------------------------------------------------
-- Administration (/managecompanies)
---------------------------------------------------------------------------
Config.AdminManagement = {
    Enabled       = true,
    Command       = 'managecompanies',
    AllowedGroups = { 'admin', 'superadmin' },
    logPageSize   = 50,
}

---------------------------------------------------------------------------
-- Company stores (NPC shop that opens while nobody is on duty)
---------------------------------------------------------------------------
Config.Store = {
    Enabled                    = true,
    DefaultEnabled             = false,
    RequireZeroEmployeesOnDuty = true,
    Blacklist = {                       -- item names exactly as in your inventory
        'money', 'gold', 'dollar', 'goldbar', 'lockpick',
    },
    BlacklistPrefixes = { 'weapon_', 'ammo_' },   -- every item starting with these (weapons / ammo)
    AllowPriceChanges   = true,
    AllowStockWithdrawal = true,
    MaxProductsPerCompany = 100,
    MaxPurchaseQuantity  = 100,         -- per product per purchase
    MaxStockPerProduct   = 10000,
    MinPrice             = 0.01,
    MaxPrice             = 100000,
    PaymentMethod        = 'cash',
    DefaultModel         = 'u_m_m_valgenstoreowner_01',
    Models = {                          -- NPC models the owner can choose
        'u_m_m_valgenstoreowner_01', 'u_m_m_sdtrapper_01', 'a_m_m_valtownfolk_01', 'a_f_m_valtownfolk_01',
        's_m_m_tailor_01', 'u_m_m_nbxgeneralstoreowner_01', 'a_m_m_rhdtownfolk_01',
    },
    ItemImagePath = nil,                -- nil = the inventory's own pictures; or e.g. 'nui://my_images/{name}.png'
    -- a missing picture shows a neutral box (ui/documents.js)
}

Config.CompanySync = {
    Enabled         = true,
    RealTimeUpdates = true,
}

-- Anti-spam: minimum ms between two calls of the same action by the same player
Config.RateLimit = 400
