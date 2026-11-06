---------------------------------------------------------------------------
-- Company marketplace (buyer side): every public listing (/companies) or the one at a company's door
-- (also the non-public ones). Buying asks for a confirmation and the server re-checks everything.
---------------------------------------------------------------------------
Market = {}

local list, cash, at = {}, 0, nil
local Fmt = Co.Fmt

local function Rows()
    local rows = {}
    for _, l in ipairs(list) do
        local blip = Co.BlipByHash[l.blip]
        local items = {
            { label = _L('price'), value = Fmt(l.price), tone = 'gold' },
            { label = _L('employees'), value = tostring(l.employees) },
            { label = _L('owner'), value = l.owner or _L('no_owner') },
            { label = _L('store'), value = l.store and _L('enabled') or _L('disabled') },
            l.balance and { label = _L('balance'), value = Fmt(l.balance) } or nil,
            l.income and { label = _L('total_income'), value = Fmt(l.income), tone = 'good' } or nil,
            l.expenses and { label = _L('total_expenses'), value = Fmt(l.expenses), tone = 'bad' } or nil,
            { label = _L('listed_on'), value = l.listedAt },
            { label = _L('location'), value = ('%.0f, %.0f'):format(l.coords.x, l.coords.y) },
        }
        local actions = {}
        if not l.mine then
            actions[#actions + 1] = { label = _L('buy_for', Fmt(l.price)), icon = 'coin', small = true, action = 'k:buy', value = l.id, disabled = cash + 0.0001 < l.price,
                confirm = { title = _L('buy_company'), text = _L('buy_company_text', l.name, Fmt(l.price)), ok = _L('buy'), cancel = _L('cancel') } }
        end
        rows[#rows + 1] = {
            value = l.id, title = l.name, tag = Fmt(l.price),
            flag = l.negotiable and { text = _L('negotiable'), tone = 'gold' } or (l.mine and { text = _L('yours'), tone = 'gold' } or nil),
            sub = ('%s · %s'):format(l.code, blip and blip.label or ''),
            details = {
                l.description and l.description ~= '' and { type = 'text', style = 'desc', text = l.description } or nil,
                { type = 'kv', cols = 2, items = items },
            },
            actions = actions,
        }
    end
    return rows
end

local function View()
    local rows = Rows()
    return {
        eyebrow = _L('marketplace'), title = at and (list[1] and list[1].name or _L('marketplace')) or _L('companies_for_sale'),
        subtitle = _L('market_sub'), count = tostring(#rows),
        body = {
            { type = 'text', style = 'desc', text = _L('market_desc') },
            #rows > 0 and { type = 'list', items = rows } or { type = 'empty', text = _L('no_listings') },
        },
        footer = { money = { cash = cash } },
        hints = { { 'ESC', _L('close') } },
    }
end

local function Fetch()
    local ok, l, c = Call('market:list', at)
    if not ok then return false, l end
    list, cash = l, c or 0
    return true
end

UI.On('k:buy', function(d)
    local price
    for _, l in ipairs(list) do if l.id == d.value then price = l.price end end
    if not price then return end
    local ok, msg = Call('market:buy', d.value, price)
    if not ok then
        Fetch()
        return { ok = false, error = msg, view = View() }
    end
    PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0)
    Notify(msg, 'success')
    return { close = true }
end)

function Market.Open(companyId)
    at = companyId
    local ok, err = Fetch()
    if not ok then return Notify(err, 'error') end
    if at and #list == 0 then return Notify(_L('not_for_sale'), 'error') end
    OpenView('market', View())
end

if Config.Marketplace.Enabled and Config.Marketplace.Command then
    RegisterCommand(Config.Marketplace.Command, function()
        if not Bridge.IsLoggedIn() or UI.IsOpen() then return end
        Market.Open(nil)
    end, false)
end
