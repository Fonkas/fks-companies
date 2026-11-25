---------------------------------------------------------------------------
-- FKS Banking integration (Config.FKS_Banking). With it on, fks-banking sends the money of company bills
-- (/billing -> "Company bill") here: it goes into the company balance through Finance.Apply, so it shows in
-- the company ledger (management panel) as "Bank bill" with the bill number, the payer and the reason.
-- Off (default): the exports below refuse and fks-banking hides the company bill option.
---------------------------------------------------------------------------
local BANKING = 'fks-banking'

-- the active company of a job (company bills are written in the name of the writer's job)
local function CompanyByJob(job)
    if type(job) ~= 'string' then return nil end
    for _, c in pairs(Companies) do
        if c.job == job and IsActive(c) then return c end
    end
end

-- is the integration on? (fks-banking asks before showing company bills)
exports('BankingEnabled', function()
    return Config.FKS_Banking == true and Loaded == true
end)

-- { id, name } of the active company of a job, or nil
exports('GetCompanyByJob', function(job)
    if Config.FKS_Banking ~= true then return nil end
    local c = CompanyByJob(job)
    return c and { id = c.id, name = c.name } or nil
end)

-- a paid company bill: credits the company. Returns ok, error. Only fks-banking may call it.
exports('AddBillIncome', function(job, amount, payerName, number, reason)
    if Config.FKS_Banking ~= true then return false, 'disabled' end
    if GetInvokingResource() ~= BANKING then return false, 'not_allowed' end
    local c = CompanyByJob(job)
    if not c then return false, 'no_company' end
    amount = Finance.Amount(amount)
    if not amount then return false, 'invalid_amount' end
    local desc = Co.Text(_L('tx_bank_bill_desc', tostring(number), tostring(payerName), tostring(reason or '-')), 255) or _L('tx_bank_bill')
    return WithLock(Finance.Key(c), function()
        local ok, err = Finance.Apply(c, amount, 'bank_bill', { cid = nil, name = tostring(payerName) }, desc)
        if not ok then return false, err end
        DB.Activity(c.id, 'bank_bill', nil, desc)
        return true
    end)
end)

-- warn in the console when the integration is on but fks-banking is not running
CreateThread(function()
    if Config.FKS_Banking ~= true then return end
    Wait(10000)
    local state = GetResourceState(BANKING)
    if state ~= 'started' and state ~= 'starting' then
        print(('^3[fks-companies] Config.FKS_Banking is true but %s is not running (%s): company bills will not work^0'):format(BANKING, state))
    end
end)
