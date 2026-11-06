---------------------------------------------------------------------------
-- Company money. The balance only changes through Finance.Apply, which must run inside the company's
-- lock (WithLock('c' .. id)): it checks the balance in memory, writes the balance change and the ledger
-- row in ONE database transaction (plus any extra queries of the caller) and only then updates memory.
---------------------------------------------------------------------------
Finance = {}

function Finance.Key(c) return 'c' .. c.id end

--[[
    amount  signed (+ income / - expense)
    kind    transaction type (deposit, withdraw, expense, tax, register, store, purchase...)
    actor   { cid, name } | nil
    extra   more { query, values } to run in the same transaction (store stock, sale rows...)
    returns ok, error
]]
function Finance.Apply(c, amount, kind, actor, desc, extra)
    amount = Co.Money(amount)
    if not amount then return false, _L('invalid_amount') end
    local before = c.balance
    local after = Co.Money(before + amount)
    if after < 0 then return false, _L('company_no_funds') end
    local income = amount > 0 and amount or 0
    local expense = amount < 0 and -amount or 0

    local queries = {
        { query = 'UPDATE fks_companies SET balance = ?, total_income = total_income + ?, total_expenses = total_expenses + ? WHERE id = ?',
          values = { after, income, expense, c.id } },
        DB.TxQuery(c.id, kind, amount, before, after, actor, desc),
    }
    for _, q in ipairs(extra or {}) do queries[#queries + 1] = q end

    local ok = MySQL.transaction.await(queries)
    if not ok then return false, _L('error') end
    c.balance = after
    c.income = Co.Money(c.income + income)
    c.expenses = Co.Money(c.expenses + expense)
    Debug('company %d %s %s (%s -> %s) by %s', c.id, kind, amount, before, after, actor and actor.name or '-')
    TriggerEvent('fks-companies:server:transaction', c.id, kind, amount, after)
    return true
end

-- a ledger row that does not move money (failed tax collection)
function Finance.Note(c, kind, actor, desc)
    local q = DB.TxQuery(c.id, kind, 0, c.balance, c.balance, actor, desc)
    MySQL.insert.await(q.query, q.values)
end

local function Amount(v)
    local n = Co.Money(v)
    if not n or n <= 0 or n > Config.Finance.maxTransaction then return nil end
    return n
end
Finance.Amount = Amount

---------------------------------------------------------------------------
-- Deposit / withdraw (player cash <-> company balance)
---------------------------------------------------------------------------
Callback('deposit', function(src, P, companyId, value)
    local c, err = Access(src, P, companyId, { perm = 'deposit' })
    if not c then return false, err end
    local amount = Amount(value)
    if not amount then return false, _L('invalid_amount') end

    return WithLock(Finance.Key(c), function()
        if P.money('cash') + 0.0001 < amount then return false, _L('not_enough_cash') end
        if not P.remove('cash', amount, 'fks-companies deposit') then return false, _L('not_enough_cash') end
        local ok, e = Finance.Apply(c, amount, 'deposit', Actor(P), _L('tx_deposit_desc'))
        if not ok then
            P.add('cash', amount, 'fks-companies deposit refund')     -- nothing was written: give it back
            return false, e
        end
        DB.Activity(c.id, 'deposit', Actor(P), _L('act_deposit', P.name, Co.Fmt(amount)))
        return true, _L('deposited', Co.Fmt(amount)), c.balance
    end)
end)

Callback('withdraw', function(src, P, companyId, value)
    local c, err = Access(src, P, companyId, { perm = 'withdraw' })
    if not c then return false, err end
    local amount = Amount(value)
    if not amount then return false, _L('invalid_amount') end

    return WithLock(Finance.Key(c), function()
        if c.balance + 0.0001 < amount then return false, _L('company_no_funds') end
        local ok, e = Finance.Apply(c, -amount, 'withdraw', Actor(P), _L('tx_withdraw_desc'))
        if not ok then return false, e end
        if not P.add('cash', amount, 'fks-companies withdraw') then
            -- the framework refused the cash: put the money back in the company
            Finance.Apply(c, amount, 'refund', Actor(P), _L('tx_withdraw_failed'))
            return false, _L('error')
        end
        DB.Activity(c.id, 'withdraw', Actor(P), _L('act_withdraw', P.name, Co.Fmt(amount)))
        return true, _L('withdrew', Co.Fmt(amount)), c.balance
    end)
end)

-- ledger page: { balance, income, expenses, rows, total, page, pages }
Callback('ledger', function(src, P, companyId, page)
    local c, err = Access(src, P, companyId, { perm = 'access_ledger', inactive = true })
    if not c then return false, err end
    local size = Config.Finance.historyPageSize
    local total = DB.CountTransactions(c.id)
    local pages = math.max(1, math.ceil(total / size))
    page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
    local rows = {}
    for _, r in ipairs(DB.Transactions(c.id, size, (page - 1) * size)) do
        rows[#rows + 1] = {
            id = r.id, type = r.type, amount = Co.Money(r.amount), before = Co.Money(r.balance_before), after = Co.Money(r.balance_after),
            actor = r.actor_name, desc = r.description, at = Co.Date(r.created_at),
        }
    end
    local t = c.tax
    local tax = t.enabled and Config.Taxes.enabled and { type = t.type, amount = t.amount, interval = t.interval, nextAt = t.nextAt and Co.Date(t.nextAt) or nil } or false
    return true, { balance = c.balance, income = c.income, expenses = c.expenses, rows = rows, total = total, page = page, pages = pages, tax = tax }
end, { noLimit = true })

---------------------------------------------------------------------------
-- Automatic taxes
---------------------------------------------------------------------------
local function TaxDue(c)
    local t = c.tax
    if t.type == 'percent' then return Co.Money(c.balance * math.max(0, math.min(100, t.amount)) / 100) end
    return Co.Money(t.amount)
end

local function Collect(c)
    local t = c.tax
    local due = TaxDue(c)
    local now = os.time()
    local nextAt = now + math.max(Config.Taxes.minInterval, t.interval) * 60
    local policy = Config.Taxes.failPolicy

    WithLock(Finance.Key(c), function()
        if due <= 0 then
            -- percentage of an empty balance: nothing to take, not a failure
        elseif c.balance + 0.0001 >= due then
            local ok = Finance.Apply(c, -due, 'tax', nil, _L('tx_tax_desc', t.type == 'percent' and (t.amount .. '%') or Co.Fmt(t.amount)))
            if ok then t.failures = 0 end
        else
            local paid = 0
            if policy == 'partial' and c.balance > 0 then
                paid = c.balance
                Finance.Apply(c, -paid, 'tax', nil, _L('tx_tax_partial', Co.Fmt(paid), Co.Fmt(due)))
            end
            t.failures = t.failures + 1
            Finance.Note(c, 'tax_failed', nil, _L('tx_tax_failed_desc', Co.Fmt(due - paid), t.failures))
            DB.Activity(c.id, 'tax_failed', nil, _L('act_tax_failed', Co.Fmt(due - paid)))
            if policy == 'suspend' and t.failures >= Config.Taxes.suspendAfter then
                SetTimeout(0, function() SetCompanyStatus(c, 'suspended', _L('reason_taxes'), nil) end)
            end
        end
        t.nextAt = nextAt
        MySQL.update.await('UPDATE fks_companies SET tax_next_at = ?, tax_failures = ? WHERE id = ?', { nextAt, t.failures, c.id })
    end)
end

CreateThread(function()
    while not Loaded do Wait(500) end
    while true do
        if Config.Taxes.enabled then
            local now = os.time()
            for _, c in pairs(Companies) do
                if IsActive(c) and c.tax.enabled and c.tax.amount > 0 then
                    if not c.tax.nextAt then
                        c.tax.nextAt = now + math.max(Config.Taxes.minInterval, c.tax.interval) * 60
                        MySQL.update('UPDATE fks_companies SET tax_next_at = ? WHERE id = ?', { c.tax.nextAt, c.id })
                    elseif c.tax.nextAt <= now then
                        Collect(c)
                    end
                end
            end
        end
        Wait(math.max(10, Config.Taxes.checkEvery) * 1000)
    end
end)
