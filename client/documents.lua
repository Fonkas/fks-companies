---------------------------------------------------------------------------
-- Documents: the employment contract and the payment request, drawn by ui/documents.js inside the
-- fks-core NUI (an fks-core extension: still one NUI frame). The answer always goes to the server, which
-- checks the contract token / bill id against this character.
---------------------------------------------------------------------------
local showing = nil      -- { kind = 'contract' | 'bill', id }

UI.Extend({ js = 'ui/documents.js', css = 'ui/documents.css' })

local function Texts(keys)
    local t = {}
    for k, key in pairs(keys) do t[k] = _L(key) end
    return t
end

local CONTRACT = Texts({
    eyebrow = 'doc_c_eyebrow', title = 'doc_c_title', number = 'doc_number', between = 'doc_c_between', represented = 'doc_c_represented',
    ['and'] = 'doc_c_and', agreed = 'doc_c_agreed', position = 'doc_c_position', grade = 'doc_c_grade', employer = 'doc_c_employer',
    start = 'doc_c_start', immediately = 'doc_c_immediately', duties = 'doc_c_duties', authority = 'doc_c_authority', clauses = 'doc_c_clauses',
    employerSig = 'doc_c_employer_sig', employeeSig = 'doc_c_employee_sig', accept = 'doc_c_accept', decline = 'doc_c_decline',
    signing = 'doc_c_signing', failed = 'error', expires = 'doc_expires',
})

local BILL = Texts({
    eyebrow = 'doc_b_eyebrow', number = 'doc_number', clerk = 'doc_b_clerk', ['for'] = 'doc_b_for', amount = 'doc_b_amount',
    note = 'doc_b_note', pay = 'doc_b_pay', decline = 'doc_b_decline', paid = 'doc_b_paid', failed = 'error', expires = 'doc_expires',
})

RegisterNetEvent('fks-companies:client:contract', function(d)
    if type(d) ~= 'table' then return end
    d.text = CONTRACT
    showing = { kind = 'contract', id = d.token }
    PlaySoundFrontend('INFO', 'HUD_SHOP_SOUNDSET', true, 0)
    UI.ExtSend('contract:show', d)
end)

RegisterNetEvent('fks-companies:client:bill', function(d)
    if type(d) ~= 'table' then return end
    d.text = BILL
    showing = { kind = 'bill', id = d.id }
    PlaySoundFrontend('INFO', 'HUD_SHOP_SOUNDSET', true, 0)
    UI.ExtSend('bill:show', d)
end)

local function Closed(id)
    if showing and showing.id == id then
        showing = nil
        UI.ExtSend('doc:hide', { id = id })
    end
end
RegisterNetEvent('fks-companies:client:contractClosed', Closed)
RegisterNetEvent('fks-companies:client:billClosed', Closed)

UI.OnExt('contract', function(d)
    local ok, msg, signature = Call('contract:answer', d.token, d.accept == true)
    if ok then
        showing = nil
        if d.accept then PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0) end
        Notify(msg, d.accept and 'success' or 'inform')
    end
    return { ok = ok == true, message = msg, signature = signature }
end)

UI.OnExt('bill', function(d)
    local ok, msg = Call('bill:answer', d.id, d.accept == true)
    if ok then
        showing = nil
        if d.accept then PlaySoundFrontend('PURCHASE', 'Ledger_Sounds', true, 0) end
        Notify(msg, d.accept and 'success' or 'inform')
    end
    return { ok = ok == true, message = msg }
end)

-- the document ran out of time on screen
UI.OnExt('closed', function()
    showing = nil
    return {}
end)

-- fks-core restarted: the extension is loaded again, a document on screen is gone
UI.OnExt('restart', function()
    showing = nil
    UI.ExtFocus(false)
end)
