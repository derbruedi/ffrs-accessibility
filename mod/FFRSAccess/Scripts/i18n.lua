-- Laedt die Sprache aus locales/<code>.lang. Die Dateien sind UTF-8 ohne BOM.
local I18N = {}

local function scriptDir()
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    return info and info.source and info.source:match("^@(.*[\\/])") or ""
end

local root = scriptDir()
local packs = {}
local currentCode = nil
local fallbackCode = "de-DE"
local current = nil
local fallback = nil
local warned = {}

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unescape(value)
    return value:gsub("\\t", "\t"):gsub("\\r", "\r"):gsub("\\n", "\n"):gsub("\\\\", "\\")
end

local function readPack(code)
    if packs[code] ~= nil then
        return packs[code] or nil
    end
    local file = io.open(root .. "locales\\" .. code .. ".lang", "rb")
    if not file then
        packs[code] = false
        return nil
    end
    local pack = { sections = {}, code = code }
    local section = "meta"
    local first = true
    for rawLine in file:lines() do
        local raw = rawLine
        if first then
            raw = raw:gsub("^\239\187\191", "")
            first = false
        end
        local line = trim(raw)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local name = line:match("^%[([%w_.-]+)%]$")
            if name then
                section = name
                pack.sections[section] = pack.sections[section] or {}
            else
                local key, value = line:match("^([%w_.-]+)%s*=%s*(.*)$")
                if key then
                    pack.sections[section] = pack.sections[section] or {}
                    pack.sections[section][key] = unescape(value)
                end
            end
        end
    end
    file:close()
    local meta = pack.sections.meta or {}
    pack.code = meta.code or code
    pack.nativeName = meta.native_name or code
    pack.fallback = meta.fallback or "de-DE"
    packs[code] = pack
    packs[pack.code] = pack
    return pack
end

local function availableCodes()
    local codes = {}
    local pipe = io.popen and io.popen('dir /b "' .. root:gsub('"', '') .. 'locales\\*.lang" 2>nul')
    if pipe then
        for line in pipe:lines() do
            local code = line:match("^(.-)%.lang$")
            if code and code ~= "" then
                codes[#codes + 1] = code
            end
        end
        pipe:close()
    end
    if #codes == 0 then
        codes = { "de-DE", "zh-CN" }
    end
    return codes
end

local function normalize(code)
    return trim(code or ""):gsub("_", "-"):lower()
end

local function resolveCulture(code)
    code = normalize(code)
    if code == "" then
        return nil
    end
    local direct = io.open(root .. "locales\\" .. trim(code) .. ".lang", "rb")
    if direct then
        direct:close()
        return trim(code)
    end
    local codes = availableCodes()
    for _, candidate in ipairs(codes) do
        if normalize(candidate) == code then
            return candidate
        end
    end
    if code:match("^zh") then
        for _, candidate in ipairs(codes) do
            if normalize(candidate):match("^zh") then
                return candidate
            end
        end
    end
    if code:match("^de") then
        for _, candidate in ipairs(codes) do
            if normalize(candidate):match("^de") then
                return candidate
            end
        end
    end
    local base = code:match("^([a-z]+)")
    local found = nil
    if base then
        for _, candidate in ipairs(codes) do
            if normalize(candidate):match("^" .. base .. "%-") then
                if found then
                    return nil
                end
                found = candidate
            end
        end
    end
    return found
end

local function detectCulture()
    if StaticFindObject and FName then
        local ok, value = pcall(function()
            local library = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
            if not library or not library:IsValid() then
                return nil
            end
            local result = library:GetCurrentCulture()
            return type(result) == "string" and result or result:ToString()
        end)
        if ok and value and value ~= "" then
            return value
        end
    end
    return os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or os.getenv("LANG")
end

local function readSetting()
    local file = io.open(root .. "..\\language.txt", "rb")
    if not file then
        return "auto"
    end
    local value = trim((file:read("*a") or ""):gsub("^\239\187\191", ""))
    file:close()
    return value ~= "" and value or "auto"
end

local function diagnose(message)
    print("[FFRSAccess][i18n] " .. tostring(message) .. "\n")
end

local function choose()
    local setting = readSetting()
    local requested = setting
    if normalize(setting) == "auto" then
        requested = detectCulture() or "de-DE"
    end
    local code = resolveCulture(requested)
    if not code and normalize(requested) ~= "" and not normalize(requested):match("^auto") then
        diagnose("Sprache nicht gefunden: " .. tostring(requested) .. ", nutze " .. fallbackCode)
    end
    current = readPack(code or fallbackCode)
    if not current then
        current = readPack(fallbackCode)
    end
    fallback = readPack(fallbackCode)
    if not fallback then
        diagnose("Rueckfallsprache fehlt: " .. fallbackCode)
        fallback = current
    end
    currentCode = current and current.code or fallbackCode
end

local function lookup(pack, key)
    if not pack then
        return nil
    end
    local section = pack.sections.mod or {}
    return section[key]
end

local function format(text, vars)
    if not vars then
        return text
    end
    return (text:gsub("{([%w_.-]+)}", function(name)
        local value = vars[name]
        if value == nil then
            return "{" .. name .. "}"
        end
        return tostring(value)
    end))
end

local function text(key, vars)
    local value = lookup(current, key) or lookup(fallback, key)
    if not value then
        local warning = currentCode .. ":" .. tostring(key)
        if not warned[warning] then
            warned[warning] = true
            diagnose("Text fehlt: " .. warning)
        end
        return tostring(key)
    end
    return format(value, vars)
end

local T = setmetatable({}, { __call = function(_, key, vars) return text(key, vars) end })
function T.plural(key, count, vars)
    local values = {}
    if vars then
        for name, value in pairs(vars) do
            values[name] = value
        end
    end
    values.count = count
    local suffix = count == 1 and ".one" or ".other"
    return text(key .. suffix, values)
end
function T.code()
    return currentCode
end
function T.nativeName()
    return current and current.nativeName or currentCode
end
function T.reload()
    packs = {}
    current, fallback = nil, nil
    choose()
end

choose()
return T
