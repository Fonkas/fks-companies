-- Language: Config.Locale picks a file from locales/. Missing keys fall back to English.
local lang = Config.Locale or 'en'
if not (Locales and Locales[lang]) then
    print(('^3[fks-companies] Locale "%s" not found - using "en".^0'):format(tostring(lang)))
    lang = 'en'
end

Locale = {}
for k, v in pairs(Locales.en or {}) do Locale[k] = v end
for k, v in pairs(Locales[lang] or {}) do Locale[k] = v end

function _L(key, ...)
    local s = Locale[key] or key
    if select('#', ...) > 0 then
        local ok, res = pcall(string.format, s, ...)
        if ok then return res end
    end
    return s
end
