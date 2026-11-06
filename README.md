# fks-companies

Company management for RedM (**VORP** and **RSG**): create a company anywhere on the map and let players run it —
employment contracts, custom positions and permissions, a ledger with automatic taxes, two storages, a cash register
with duty, an NPC store that sells while nobody is on duty, a company marketplace and a full admin panel.

Every screen is drawn by **fks-core**; this resource ships no NUI page of its own. The contract, the payment request and four
components (a dropdown, the blip grid, the store with its cart and the stock screen) are an fks-core *extension*
(`ui/documents.js` + `ui/documents.css` loaded into the fks-core frame), so the server still runs a single NUI. The dropdown
replaces the native `<select>`, whose popup RedM's browser draws as a broken texture.

Available in 7 languages.

> License: **GPL-3.0-or-later** — see [LICENSE](LICENSE). Changes per version: [CHANGELOG.md](CHANGELOG.md).

---

## Installation

1. Put `fks-companies` in your resources folder.
2. Start it **after** its dependencies:

```cfg
ensure ox_lib
ensure oxmysql
ensure vorp_core          # or rsg-core
ensure vorp_inventory     # or rsg-inventory / ox_inventory
ensure fks-core           # 2.1.2 or newer
ensure fks-companies
```

3. The tables are created on start. You can also import `sql/install.sql` by hand (same statements).
4. Edit `shared/config.lua` (language, prices, distances, blacklist...).

### Dependencies

| Resource | Why |
|---|---|
| [fks-core](https://github.com/Fonkas/fks-core) 2.1.2+ | VORP / RSG bridge (players, money, items, storages, admin check), the shared UI, notifications |
| ox_lib | server callbacks (`lib.callback`) |
| oxmysql | database |
| vorp_core **or** rsg-core | framework |
| vorp_inventory, rsg-inventory **or** ox_inventory | items, storages, item pictures |

---

## Framework setup

`Config.Framework = 'auto'` detects the framework (`rsg-core` first, then `vorp_core`); `Config.Inventory = 'auto'` detects
ox_inventory → rsg-inventory → vorp_inventory. Set them by hand if you run more than one.

### VORP
- Jobs and grades are free text: a company job (`saloon`) and its grades work without any setup.
- The job label of the employees is the company name (it follows renames).
- Offline payments are written to `characters.money` (by `charidentifier`).
- Character ID = `charidentifier`.

### RSG
- **The company job must exist in `rsg-core/shared/jobs.lua`** with every grade you use: the Boss grade
  (`Config.Creation.bossGrade`, default 4) and the grades of the positions. The resource refuses to create a company,
  a position or a promotion whose grade does not exist, instead of failing silently. Example:

```lua
['saloon'] = {
    label = 'Saloon', defaultDuty = false, offDutyPay = false,
    grades = {
        ['0'] = { name = 'Trainee', payment = 0 },
        ['1'] = { name = 'Employee', payment = 0 },
        ['3'] = { name = 'Manager', payment = 0 },
        ['4'] = { name = 'Boss', isboss = true, payment = 0 },
    },
},
```

- Our duty is mirrored into rsg-core's job duty (`SetJobDuty`) when that function exists.
- Offline payments are written to `players.money` → `cash` (by `citizenid`).
- Character ID = `citizenid`.
- Tested locally against VORP only; the RSG paths use the same rsg-core APIs fks-core and fks-gangs already use.

---

## Administrators

Admins are the groups in `Config.AdminManagement.AllowedGroups` (VORP user/character group, RSG permission) plus anyone with
the `command` ACE. The server checks it again on every admin action.

### `/createnewcompany`
Opens the creation form at your position (a marker and a temporary blip show where the company will be):

- **Identity**: name, framework job, internal ID (unique, e.g. `VAL-SALOON`; empty = `CO-0001`), initial owner (an online player — they become the Boss and get the job), blip, description.
- **Finances**: starting balance (recorded in the ledger as an administration entry) and the automatic tax: on/off,
  fixed amount or % of the balance, how often (1 h ... 7 days). A sentence under the form says exactly what will happen.
- **Capacity**: boss / general storage slots and weight (no upper limit unless you set `Config.Storage.maxSlots` /
  `maxWeight`), max employees.
- **Sale**: list it straight away, price, public or not, negotiable.

The company is saved on confirm and survives restarts. Cancel (or ESC) leaves nothing behind.

### `/managecompanies`
- **List** with search (ID, name, code, job, owner) and filters: all · active · inactive/suspended · for sale · not for sale · without owner · without employees. Every row shows ID, name, owner, job, employees, on duty, balance, status, sale status, price and creation date.
- **Company** tab: name, internal ID, job (every employee gets the new job, online and offline), description, blip, owner (online player, character ID, or none), move the company point to you, teleport, remove placed points.
- **Money & settings**: set balance (recorded in the ledger), taxes, sale listing (price, public, negotiable), storage capacities, max employees, store on/off.
- **Status**: activate, deactivate, suspend, reactivate (with a reason). Inactive/suspended companies: management closes for employees, everyone goes off duty, the store NPC disappears, the listing closes. Nothing is lost.
- **Delete** (type the internal ID to confirm), two options. Both: employees lose the job, positions, points, products and storages are deleted, the listing closes.
  - **Archive**: the company row, ledger, activity and sales are kept (`deleted_at`) for auditing.
  - **Delete for good**: every row of the company is deleted. Only the admin log line and money still owed to a seller (pending marketplace payout) stay.
  - **Archived companies** (button on the list): delete archived companies for good, one by one or all at once.
- **Admin log**: every admin action (create, delete, suspend, reactivate, every edit, marketplace sales) with the admin and the time.

---

## Players

### Company point (E)
A flat marker on the ground shows the point where the company was created and is managed (`Config.Marker`: size,
colour, distance, everyone or employees only).

Opens the company window for employees with **Open company management**. If the company is for sale, **G** shows the offer to anyone.

| Tab | What |
|---|---|
| General | name, blip, owner, employees, on duty, balance / income / expenses, recent activity (needs *View overview*), leave the company |
| Management | hire (contract), employee list (promote, demote, change position, take off duty, dismiss), positions & permissions, sell company (Boss) |
| Ledger | balance, deposit / withdraw (cash on hand), paginated history: type, amount, responsible, date, description, balance before / after |
| Customization | place storages / register, change name / blip (paid from the company balance), store settings and products |

### Employment contracts
The employer picks a nearby player (or an ID), a position below their own and a job description. The target gets a
frontier-style contract; **Accept & sign** writes their character name as a handwritten signature, stores the signed contract,
gives the job and grade and adds them to the company. Contracts expire (`Config.Contracts.expiration`), only the intended
character can sign, one pending contract per player, and accepting twice is impossible.

### Positions & permissions
The Boss always has every permission and cannot be edited or deleted. Other positions have a name, a grade (= framework job
grade) and toggles. Nobody manages people of their own grade or higher, nobody assigns a position at or above their own, and nobody
can grant a permission they do not have.

| Permission | | Permission | |
|---|---|---|---|
| `open_management` | open the company window | `access_ledger` | ledger tab |
| `view_overview` | balance / activity on General | `deposit` / `withdraw` | move money |
| `edit_info` | description | `charge_customers` | register payment requests |
| `hire` / `dismiss` | staff | `access_boss_storage` | boss storage |
| `promote` / `demote` | staff | `access_general_storage` | general storage |
| `manage_positions` | positions + change someone's position | `manage_storage_locations` | place storages |
| `manage_duty` | take someone off duty | `manage_register` | place the register |
| `manage_customization` | customization tab | `change_name` / `change_blip` | identity purchases |
| `manage_store` | store on/off, NPC model / place | `manage_store_inventory` | list / restock / price / withdraw products |

Selling the company is Boss only.

### Placement
Storages, register and the store NPC use the fks-gangs style see-through preview, plus full control:
arrows move (relative to the camera) · **Q / E** height · **Z / X** rotate · **G** drop to the ground · **SHIFT** faster ·
**ENTER** confirm · **BACKSPACE** cancel. Position, height and rotation are saved and synced to every player.
Everything must stay within `Config.Placement.maxDistance` of the company point.

### Cash register
- **Go on / off duty** (at the register).
- **Charge a customer**: nearby player, amount, description. The customer gets a payment request (cash only), which expires after `Config.Billing.expiration`. One open request per customer, nobody else can answer it, and it can only be paid once.

### Duty and the map blip
- Green blip = at least one employee on duty, red = nobody (`Config.Blips.colorOnDuty / colorOffDuty`).
- Off duty automatically: more than `Config.Duty.maxDistance` (200 m) from the company (checked by the server every `checkInterval` s, only for players on duty), disconnecting, changing character, being dismissed, the company being suspended.
- Restarting the resource restores the duty of players still connected and close enough (kept on the player's state bag) and drops everyone else.

### NPC store
- Enable it and place the NPC under Customization → Store. The NPC is only there while the store is enabled, the company is active and **nobody is on duty** (`Config.Store.RequireZeroEmployeesOnDuty`). Going on duty closes it at once, also for customers who are browsing.
- Employees with `manage_store_inventory` list items **from their own inventory** (quantity + unit price); the units leave their inventory into the store stock. They can restock, change prices, withdraw units and remove products.
- `Config.Store.Blacklist` (exact names) and `BlacklistPrefixes` (`weapon_`, `ammo_`) are refused on the server.
- Customers get one screen: the products (inventory pictures, price, stock, search) on the left and the cart on the right
  (quantities, subtotal, total, their cash) with **Confirm purchase**. Cash on hand only. If the stock changes while they
  browse, the cart is trimmed and they are told.
- Employees manage the store on one screen too: the store products (restock, price, take back, remove) next to their own
  inventory (search, **List** with quantity and price).
- Checkout validates store open, products, prices (a changed price is refused), stock, cash and inventory space, then takes the cash, writes stock + sale + ledger in one transaction, and only then gives the items. If giving an item fails, everything is undone.

### Marketplace
- The Boss lists the company (price within `MinPrice` / `MaxPrice`) and can cancel while nobody has bought it. Admins can list any company.
- `/companies` lists the public offers; non-public offers can only be bought at the company point.
- Buying: cash on hand, the buyer becomes the Boss, the employees stay, the previous Boss is dismissed (or demoted, `Config.Marketplace.PreviousOwner`). Two simultaneous buyers: only one gets it.
- **The seller is paid in cash on hand**, also offline: one payout row per sale (unique), claimed before any money moves. Online → credited at once. Offline → written to the framework table (`OfflinePayment = 'database'`) when their account is not connected, otherwise credited on their next character load.
- What buyers see of the finances: `Config.Marketplace.FinancialPrivacy` (`none`, `balance`, `full`).

---

## Blip gallery

The [femga blips folder](https://github.com/femga/rdr3_discoveries/tree/master/useful_info_from_rpfs/textures/blips) has **no
images**: it is one README listing 321 texture names and hashes, with previews hosted on femga.com. `shared/blips.lua` is a local
catalogue generated from it (name, sprite hash, category, readable label) — the gallery is searchable and filtered by category.

Pictures (`Config.BlipImages.source`):
- `'remote'` (default): femga.com's public previews, nothing to install (the client needs internet).
- `'local'`: download the "without bg" pack linked in that README, unzip the PNGs into `html/blips/` (e.g. `html/blips/blip_shop_store.png`), uncomment the `'html/blips/*.png'` line in
  `fxmanifest.lua` and set `source = 'local'`.

The gallery is a grid of round icons with search and category filters (also in `/createnewcompany` and `/managecompanies`).
Restrict the choice with `Config.Blips.allowed` (a list of names / hashes) or `Config.Blips.disabled`. A missing picture shows a neutral box.

---

## Item pictures

The store uses the inventory's own pictures, by item name: `nui://vorp_inventory/html/img/items/<name>.png`,
`nui://rsg-inventory/html/images/<image>` (the item's `image` field) or `nui://ox_inventory/web/images/<image>`.
Set `Config.Store.ItemImagePath` (e.g. `'nui://my_images/{name}.png'`) to use your own folder.

---

## Security notes

- Every money, ownership, staff, stock and placement action is validated on the server: permission, company active, distance to the point, amounts (no negatives, no NaN, `Config.Finance.maxTransaction`), prices and stock from the server's memory — never the client's.
- Money moves inside a per-company lock; the balance and its ledger row are written in one database transaction.
- Rate limit per player per action (`Config.RateLimit`), contract tokens bound to the character, bill IDs bound to the customer, one payout per sale.
- Financial data is never broadcast: clients receive name, blip, points, duty count and store state only; balances are sent only to players allowed to see them.

## Exports (server)

```lua
exports['fks-companies']:GetCompany(id)         -- public state of a company
exports['fks-companies']:GetPlayerCompany(src)  -- { company, position, grade, boss, perms, onDuty, active }
exports['fks-companies']:IsOnDuty(src)
```

Server events: `fks-companies:server:transaction` (companyId, type, amount, newBalance) · `fks-companies:server:duty` (companyId, cid, on, reason).

## Languages
`Config.Locale` in `shared/config.lua`:

| Code | Language |
|---|---|
| `en` | English |
| `pt` | Português (Portugal) |
| `br` | Português (Brasil) |
| `es` | Español |
| `fr` | Français |
| `de` | Deutsch |
| `it` | Italiano |

Missing keys fall back to English. To add a language, copy `locales/en.lua` to `locales/xx.lua`, rename `Locales.en` to
`Locales.xx`, translate the strings (keep every `%s`, `%%` and `**`) and set `Config.Locale = 'xx'`.

## Menu icons
The round buttons of the Management and Customization tabs use the pictures in `ui/icons/{name}.png`
(white symbol on a transparent background, 256x256). Replace a file to change an icon; `Config.MenuIcons.enabled = false`
goes back to the built-in fks-core icons. The prompts used to draw them are in [docs/icon-prompts.md](docs/icon-prompts.md).

## Updates
On start (and every `Config.VersionCheck.interval` hours) the server console shows `up to date (vX)` or `OUTDATED` by
comparing the `version` in `fxmanifest.lua` with the one on GitHub (`Config.VersionCheck.repo`, branch `main`).
It also warns, with the download link, when fks-core is not running. `Config.VersionCheck.enabled = false` turns it off.

## License
GNU General Public License v3.0 or later — see [LICENSE](LICENSE).
