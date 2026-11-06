-- FF Resonance Zugang: Sprachausgabe ueber Prism/NVDA.
-- Sagt fokussierte Menueeintraege, geaenderte Werte und neu geoeffnete Bildschirme an.

local BRIDGE_DLL = "ffrs_speech.dll"
local PIPE_PATH = [[\\.\pipe\ffrs_speech]]
local TICK_MS = 200
local SCREEN_READ_DELAY_SECONDS = 0.4
local MAX_WALK_DEPTH = 40
local HOOK_DISCOVERY_INTERVAL_SECONDS = 1
local DUPLICATE_FOCUS_WINDOW_SECONDS = 0.25
local FOCUS_EVENT_NAMES = { "BP_OnIsFocused", "BP_OnFocused" }
local FOCUS_TIME_CURRENT = 0 -- EEnhancedMenu_FocuedTimeType::Current

-- Blueprint-Klassen mit eigenem Fokus-Ereignis. Sie werden erst beim Laden des jeweiligen
-- Menues angelegt, deshalb versucht tryRegisterFocusHooks die Registrierung immer wieder.
-- Alle uebrigen Button-Klassen findet discoverFocusHooks zur Laufzeit.
local FOCUS_HOOKS = {
    "/Game/UI/Foundation/Button/WBP_ListEntryButtonBase.WBP_ListEntryButtonBase_C:BP_OnIsFocused",
    "/Game/UI/Common/Button/LeftLine/Widget/WBP_LeftLineButton.WBP_LeftLineButton_C:BP_OnIsFocused",
    "/Game/UI/Common/Button/Primary/Widget/WBP_PrimaryButton.WBP_PrimaryButton_C:BP_OnIsFocused",
    "/Game/UI/Battle/Command/Finish/Widget/WBP_FinishCmdEntry.WBP_FinishCmdEntry_C:BP_OnIsFocused",
    "/Game/UI/Vision/Common/VisionPanel/WBP_VisionPanel.WBP_VisionPanel_C:BP_OnIsFocused",
    "/Game/UI/Common/Action/Widget/WBP_ActionEntryBase.WBP_ActionEntryBase_C:BP_OnFocused",
    "/Game/UI/Mastery/Widget/Entry/WBP_MasteryEntryBase.WBP_MasteryEntryBase_C:BP_OnFocused",
    "/Game/UI/Option/Entry/Widget/WBP_OP_GameoverCommand.WBP_OP_GameoverCommand_C:BP_OnFocused",
    "/Game/UI/Option/Entry/Widget/WBP_OP_ResetButton.WBP_OP_ResetButton_C:BP_OnFocused",
    "/Game/UI/Option/Entry/Widget/WBP_OP_Subheader.WBP_OP_Subheader_C:BP_OnFocused",
    "/Game/UI/Option/Entry/Widget/WBP_OP_Command.WBP_OP_Command_C:BP_OnFocused",
    "/Game/UI/Option/Entry/Widget/WBP_OP_Input.WBP_OP_Input_C:BP_OnFocused",
    "/Game/UI/Coliseum/Widget/Command/WBP_Collossseum_CommandEntry.WBP_Collossseum_CommandEntry_C:BP_OnFocused",
    "/Game/UI/INN/Widget/WBP_Facility_Command.WBP_Facility_Command_C:BP_OnFocused",
    "/Game/UI/SavePoint/Widget/WBP_SavePoint_Command.WBP_SavePoint_Command_C:BP_OnFocused",
}

local CLASS_PATHS = {
    TextBlock = "/Script/UMG.TextBlock",
    RichTextBlock = "/Script/UMG.RichTextBlock",
    UserWidget = "/Script/UMG.UserWidget",
    PanelWidget = "/Script/UMG.PanelWidget",
    WidgetSwitcher = "/Script/UMG.WidgetSwitcher",
    ListViewBase = "/Script/UMG.ListViewBase",
    ButtonEvent = "/Script/EnhancedUI.CPP_WBP_ButtonEvent",
    Activatable = "/Script/CommonUI.CommonActivatableWidget",
    MenuBase = "/Script/EnhancedUI.CPP_WBP_MenuBase",
    MenuPath = "/Script/EnhancedUI.CPP_EU_WBP_MenuPath",
    RadioButtonList = "/Script/mucha.CPP_CommonMenu_RadioButtonList",
    DialogLayout = "/Script/mucha.CPP_WBP_DialogLayout",
    TextWindow = "/Script/mucha.CPP_WBP_TextWindow",
    MapUnitPlayable = "/Script/mucha.CPP_MapUnit_Playable",
}

-- Pathfinder: Einheiten in Zentimetern, wie in der Unreal Engine.
local WALK_PROBE_SECONDS = 0.4
local WALK_DETOUR_SECONDS = 1.2
local WALK_DETOUR_MAX_SECONDS = 5
local WALK_DETOUR_ANGLES = { 60, -60, 100, -100, 140, -140 }
local WALK_PROGRESS_STEP = 100
local WALK_GIVE_UP_SECONDS = 15
local MOVE_INPUT_ACTION = "/Game/Input/Action/Map/IA_Map_UnitMove.IA_Map_UnitMove"
local INJECT_INPUT_FUNCTION = "/Script/EnhancedInput.EnhancedInputSubsystemInterface:InjectInputVectorForAction"
local WALK_ARRIVAL_DISTANCE = 200
local WALK_MIN_PROGRESS = 30
local WALK_POINT_REACHED_DISTANCE = 100
local STEER_TICK_MS = 1 -- praktisch jeder Frame: eine eingespeiste Eingabe gilt nur fuer einen Frame
local GIMMICK_STATE_DEACTIVE = 1 -- eMapGimmickState::Deactive
local DIRECTION_NAMES = { "vorne", "vorne rechts", "rechts", "hinten rechts", "hinten", "hinten links", "links", "vorne links" }

local QUEST_CATEGORY = "Questziel"
local TARGET_CATEGORIES = { QUEST_CATEGORY, "Aufträge", "Story-Ereignisse", "Personen", "Gegner", "Schätze", "Ausgänge", "Türen", "Speicherpunkte", "Objekte", "Erkunden" }
local NPC_NAMES_FILE = "npc_names.txt"
local PICKUP_MAX_DISTANCE = 500
-- Spielbare Figuren reden in Gespraechen mit, ihr Name gehoert nie zur angesprochenen Person.
local NON_NPC_SPEAKERS = { ["Rain"] = true, ["Lasswell"] = true, ["Fina"] = true, ["???"] = true }

-- Gesuchte Klassen, die speziellen zuerst. Ohne eMapInteractType gilt die Kategorie der Klasse,
-- CPP_FieldObject hat keine, weil darunter auch unsichtbare Ausloeser und Waende fallen.
-- Der dritte Wert steht fuer unsichtbare Volumen, bei denen bHidden nichts aussagt.
local TARGET_SOURCES = {
    { "CPP_MapUnit_NPC", { "Personen", "Person" } },
    { "CPP_MapGimmick_TreasureBox", { "Schätze", "Schatztruhe" } },
    { "CPP_MapGimmick_SavePoint", { "Speicherpunkte", "Speicherpunkt" } },
    { "CPP_MapGimmick_Object_DoorBase", { "Ausgänge", "Tür" } },
    { "CPP_MapGimmick_Trigger_DoorBase", { "Ausgänge", "Tür" } },
    { "CPP_MapGimmick_Warp", { "Ausgänge", "Ausgang" } },
    { "CPP_MapTransitionTrigger", { "Ausgänge", "Ausgang" }, true },
    { "CPP_MapEncount", { "Gegner", "Begegnungsgebiet" }, true },
    { "CPP_MapGimmick_EventTrigger", { "Story-Ereignisse", "Story-Ereignis" } },
    { "CPP_MapGimmick_InteractEventTrigger", { "Objekte", "Untersuchen" } },
    { "CPP_FieldObject", nil },
}

local DIAGNOSTIC_CLASSES = { "RecastNavMesh", "NavMeshBoundsVolume", "CPP_MapTransitionTrigger", "Character","CPP_Unit", "CPP_MapUnit", "CPP_MapUnit_NPC", "CPP_MapUnit_SpawnActor", "CPP_MapUnit_Object",
    "CPP_FieldObject", "CPP_MapGimmick", "CPP_MapEncount", "CPP_MapMonsterHabitatRange", "CPP_BtlUnit" }
local DIAGNOSTIC_ACTOR_FIELDS = { "m_MapInteractType", "interactType", "m_MapObjectType", "bHidden", "m_GimmickCondition", "m_MapUnitId" }
local DIAGNOSTIC_ACTOR_LIMIT = 40

local RELATION_ENEMIES = 2 -- eRelation::Enemies
local TARGET_STATE_MAIN = 1 -- eSkillTargetSelectStateType::Main
local BATTLE_END_DELAY_SECONDS = 1
local RESULT_TEXT_STABLE_SECONDS = 0.4
local RESULT_DATA_HOOK = "/Script/mucha.CPP_WBP_Btl_Result_Page_Reward:SetResultData"

-- eMapInteractType: Kategorie und Ansage. Fehlende Typen landen unter "Objekte".
local INTERACT_TYPES = {
    [1] = { "Personen", "Person" },
    [2] = { "Personen", "Personengruppe" },
    [3] = { "Personen", "Gesprächspunkt" },
    [4] = { "Objekte", "Untersuchen" },
    [5] = { "Objekte", "Untersuchen" },
    [6] = { "Objekte", "Untersuchen" },
    [7] = { "Objekte", "Untersuchen" },
    [8] = { "Objekte", "Mechanismus" },
    [9] = { "Personen", "Handelsschiff" },
    [10] = { "Gegner", "Kampf" },
    [11] = { "Schätze", "Schatztruhe" },
    [12] = { "Objekte", "Esper" },
    [13] = { "Ausgänge", "Tür" },
    [14] = { "Objekte", "Fahrzeug" },
    [15] = { "Objekte", "Schiff" },
    [16] = { "Ausgänge", "Anlegestelle" },
    [17] = { "Personen", "Laden" },
    [18] = { "Personen", "Waffenladen" },
    [19] = { "Personen", "Rüstungsladen" },
    [20] = { "Personen", "Accessoireladen" },
    [21] = { "Personen", "Gasthaus" },
    [22] = { "Personen", "Auftragstafel" },
    [23] = { "Personen", "Bank" },
    [24] = { "Personen", "Chocoboladen" },
    [25] = { "Personen", "Chocoborennen" },
    [26] = { "Personen", "Musikladen" },
    [28] = { "Personen", "Wahrsager" },
    [29] = { "Personen", "Kolosseum" },
    [30] = { "Personen", "Kolosseum" },
    [31] = { "Personen", "Kolosseum" },
    [32] = { "Personen", "Visionsladen" },
    [33] = { "Speicherpunkte", "Speicherpunkt" },
    [34] = { "Ausgänge", "Ausgang" },
    [35] = { "Ausgänge", "Ausgang" },
    [36] = { "Objekte", "Wahrzeichen" },
    [37] = { "Ausgänge", "Stadt" },
    [38] = { "Ausgänge", "Dungeon" },
}

-- Bildschirme, deren Text als Textur gerendert ist und daher nicht auslesbar ist.
local SCREEN_TEXT_OVERRIDES = {
    WBP_DemoIntroductionLayout_C = "Danke für den Download von Final Fantasy Resonance. "
        .. "Tauche ein in die Mysterien, die das Schicksal der Welt gestalten, "
        .. "und erlebe in dieser Demo das komplette erste Kapitel. "
        .. "Einschränkungen der Demo: Maximale Charakterstufe: 15, maximaler Visionsmeisterschaftsrang: 5. "
        .. "Gespeicherte Daten können in die Vollversion übertragen werden. "
        .. "Schmiede unzerstörbare Freundschaften, nutze die Kraft der Visionen "
        .. "und beschwöre eine mächtige Esper. "
        .. "Nun tauche ein in eine Geschichte über Vergeltung, Verbundenheit und Hoffnung, "
        .. "Hoffnung, die in den Kristallen widerhallt. Schließen.",
}

-- Text_VariationValue steht als unsichtbarer Platzhalter (9999) in jeder LP/MP-Anzeige, der Toast
-- als {VisionName}-Vorlage in Ausruestungsmenues, die Werteliste zeigt Symbole statt Namen.
local IGNORED_WIDGET_NAMES = {
    Text_ApplicationVersion = true,
    Text_Separete = true,
    Text_VariationValue = true,
    WBP_Toast = true,
    WBP_EquipTooltip_ParamList = true,
}

local speechPipe = nil
local registeredHooks = {}
local failedHooks = {}
local discoveredClasses = {}
local nextHookDiscovery = 0
local classCache = {}
local focusedEntry = nil
local focusedPath = nil
local focusedText = nil
local lastFocusSpeech = nil
local lastFocusSpeechAt = 0
local activeDialog = nil
local activeDialogPath = nil
local dialogMenuPathLogged = {}
local loggedTreeClasses = {}
local spokenTalkText = nil
local onTalkLine = nil
local describePickup = nil
local spokenDialogMessage = nil
local pendingTalkText = nil
local pagedScreenText = nil
local knownScreens = {}
local pendingScreens = {}
local topScreen = nil

local function log(message)
    print("[FFRSAccess] " .. tostring(message) .. "\n")
end

local function bridgeCandidates()
    local candidates = {}
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local scriptsDir = info and info.source and info.source:match("^@(.*[\\/])")
    if scriptsDir then
        table.insert(candidates, scriptsDir .. "..\\bin\\" .. BRIDGE_DLL)
    end
    table.insert(candidates, "ue4ss\\Mods\\FFRSAccess\\bin\\" .. BRIDGE_DLL)
    table.insert(candidates, "Mods\\FFRSAccess\\bin\\" .. BRIDGE_DLL)
    return candidates
end

local function startBridge()
    if not (package and package.loadlib) then
        log("package.loadlib ist nicht verfuegbar")
        return false
    end
    for _, path in ipairs(bridgeCandidates()) do
        local start, err = package.loadlib(path, "ffrs_start")
        if start then
            start()
            log("Sprachbruecke geladen: " .. path)
            return true
        end
        log("Sprachbruecke nicht geladen (" .. path .. "): " .. tostring(err))
    end
    return false
end

local function speak(text, interrupt)
    if not speechPipe or not text or text == "" then
        return
    end
    local line = (text:gsub("[\r\n]+", " "))
    local ok, err = pcall(function()
        speechPipe:write((interrupt and "1" or "0") .. line .. "\n")
        speechPipe:flush()
    end)
    if ok then
        log("Ansage: " .. line)
    else
        log("Pipe-Fehler: " .. tostring(err))
    end
end

local function isA(object, className)
    local class = classCache[className]
    if not class or not class:IsValid() then
        class = StaticFindObject(CLASS_PATHS[className])
        classCache[className] = class
    end
    return class:IsValid() and object:IsA(class)
end

local function objectPath(object)
    local fullName = object:GetFullName()
    return fullName and fullName:match("^%S+%s+(.+)$")
end

local function shortClassName(object)
    local fullName = object:GetFullName()
    return fullName and fullName:match("^(%S+)") or ""
end

local function objectName(object)
    local path = objectPath(object)
    return path and path:match("([^.:]+)$") or ""
end

local function widgetText(widget)
    local ok, text = pcall(function()
        return widget:GetText():ToString()
    end)
    if not ok or type(text) ~= "string" then
        return nil
    end
    -- Tastensymbole stecken als Bild im Markup (<img id="..."/>, Anleitungen <IA tag="Unit_Ride"/>); ihre Kennung
    -- ersetzt das Bild in der Ansage.
    text = text:gsub('<[^>]-id="([^"]*)"[^>]*>', " %1 "):gsub('<IA [^>]-tag="([^"]*)"[^>]*>', " %1 "):gsub("<[^>]*>", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return text ~= "" and text or nil
end

-- ESlateVisibility: 1 = Collapsed, 2 = Hidden
local function isHidden(widget)
    local ok, visibility = pcall(function()
        return widget:GetVisibility()
    end)
    return ok and (visibility == 1 or visibility == 2)
end

local walk

local function walkListEntries(list, options, out, depth)
    pcall(function()
        list:GetDisplayedEntryWidgets():ForEach(function(_, element)
            walk(element:get(), options, out, depth + 1)
        end)
    end)
end

local function appendText(out, text)
    if text and out[#out] ~= text then
        table.insert(out, text)
    end
end

-- Radio-Listen zeigen alle Optionen an; vorgelesen wird nur die gewaehlte.
local function walkRadioButtonList(list, options, out, depth)
    local choices = {}
    walk(list.WidgetTree.RootWidget, options, choices, depth + 1)
    local selected = choices[list.SelectedIndex + 1]
    if selected then
        appendText(out, selected)
    else
        for _, choice in ipairs(choices) do
            appendText(out, choice)
        end
    end
end

walk = function(widget, options, out, depth)
    if not widget or not widget:IsValid() or depth > MAX_WALK_DEPTH or isHidden(widget) then
        return
    end
    local name = objectName(widget)
    if IGNORED_WIDGET_NAMES[name] then
        return
    end
    if isA(widget, "TextBlock") or isA(widget, "RichTextBlock") then
        appendText(out, widgetText(widget))
        return
    end
    -- Der Geldbetrag steht ohne Einheit da, die Waehrung ist nur ein Symbol.
    if name:find("^WBP_Money") and isA(widget, "UserWidget") then
        local amount = {}
        walk(widget.WidgetTree.RootWidget, options, amount, depth + 1)
        if #amount > 0 then
            appendText(out, table.concat(amount, " ") .. " Gil")
        end
        return
    end
    if options.staticOnly and (isA(widget, "ButtonEvent") or isA(widget, "ListViewBase")) then
        return
    end
    if options.skipMenus and isA(widget, "MenuBase") then
        return
    end
    -- Aktivierbare Unterbildschirme werden ueber tickScreens eigenstaendig gelesen.
    if depth > 0 and not options.includeActivatable and isA(widget, "Activatable") then
        return
    end
    if isA(widget, "RadioButtonList") then
        walkRadioButtonList(widget, options, out, depth)
    elseif isA(widget, "UserWidget") then
        local tree = widget.WidgetTree
        if tree and tree:IsValid() then
            walk(tree.RootWidget, options, out, depth + 1)
        end
    elseif isA(widget, "WidgetSwitcher") then
        walk(widget:GetActiveWidget(), options, out, depth + 1)
    elseif isA(widget, "ListViewBase") then
        walkListEntries(widget, options, out, depth)
    elseif isA(widget, "PanelWidget") then
        for index = 0, widget:GetChildrenCount() - 1 do
            walk(widget:GetChildAt(index), options, out, depth + 1)
        end
    end
end

local function readTexts(root, options)
    local out = {}
    walk(root, options, out, 0)
    return (table.concat(out, ", "):gsub(", /, ", " von "):gsub(":, ", ": "):gsub(", ×, ", " × "))
end

local function currentMenuItem(menu)
    local item = nil
    menu.FocuedItemDataMap:ForEach(function(key, value)
        if key:get() == FOCUS_TIME_CURRENT then
            item = value:get().Widget
        end
    end)
    return item
end

-- Zusatzangaben in Menues. Als Tabelle, weil der Hauptblock an der Grenze von 200 lokalen Variablen liegt.
local menuInfo = {
    TOOLTIP_READ_DELAY_SECONDS = 0.3,
    -- Laengste Pause vor dem Hochzaehlen laut Log (05.11.) 1,4 s.
    RESULT_ZERO_HOLD_SECONDS = 2.5,
    DIALOG_READ_DELAY_SECONDS = 0.1,
    UNIT_CACHE_SECONDS = 2,
    -- Reihenfolge der Tabs ist eine Annahme aus EUI_ItemCategory, das Spiel zeigt nur Symbole.
    TAB_FALLBACK_NAMES = { "Alle", "Verbrauchsgegenstände", "Waffen", "Rüstungen", "Accessoires", "Wertsachen" },
    -- Widgetname und Rueckfall-Titel der Abschnitte in WBP_UnitEquippedList.
    EQUIP_SECTIONS = {
        { "WBP_ItemLIst", "Ausrüstung" },
        { "WBP_VisionList", "Vision" },
        { "WBP_UnitEquippedSkillList", "Fertigkeiten" },
    },
    CATEGORY_SPEECH_SECONDS = 1,
    SEARCH_INTERVAL_SECONDS = 1,
    ITEM_TYPE_EQUIPMENT = 3, -- eItemType::Equipment
    ACTION_CATEGORY_ITEM = 2, -- eActionCategory::Item
    ITEM_CATEGORY_ASSET = "/Game/UI/Common/Item/Category/Data/DA_ItemCategory.DA_ItemCategory",
    -- eUnitParameterType mit den Begriffen der Statusanzeige, in deren Reihenfolge.
    -- Die Zuordnung Staerke = Attack usw. und FP = EquipCost ist aus dieser Reihenfolge abgeleitet.
    EQUIPMENT_PARAMETERS = {
        { 1, "LP" }, { 2, "MP" }, { 3, "Bruchwert" },
        { 12, "Phys. Angr." }, { 13, "Phys. Vert." }, { 14, "Mag. Angr." }, { 15, "Mag. Vert." }, { 16, "Heiligkeit" },
        { 5, "Stärke" }, { 6, "Ausdauer" }, { 7, "Magie" }, { 8, "Geist" }, { 9, "Tempo" }, { 11, "FP" },
    },
    EQUIPMENT_TYPES = { [1] = "Waffe", [2] = "Rüstung", [3] = "Accessoire", [4] = "Vision" },
    -- eEquipmentDetailType, Rueckfall falls CPP_DA_ItemText nicht geladen ist.
    EQUIPMENT_DETAIL_TYPES = {
        [1] = "Großschwert", [2] = "Katana", [3] = "Bogen", [4] = "Hammer", [5] = "Grimoire", [6] = "Schusswaffe",
        [7] = "Stab", [8] = "Peitsche", [9] = "Schwere Rüstung", [10] = "Leichte Rüstung", [11] = "Robe",
    },
    -- Rueckfall nach dem letzten Teil des GameplayTags; die Sammelkategorie hat im Datenasset keinen Namen.
    CATEGORY_FALLBACK_NAMES = {
        all = "Alle", consumables = "Verbrauchsgegenstände", consumable = "Verbrauchsgegenstände", weapon = "Waffen",
        armor = "Rüstungen", accessory = "Accessoires", valuable = "Wertsachen", artifact = "Artefakte", vision = "Visionen",
    },
    defaults = {},
    itemLayout = nil,
    itemLayoutVM = nil,
    tooltipLayout = nil,
    tooltipVM = nil,
    nextTooltipSearch = 0,
    tooltipDue = 0,
    spokenTooltip = nil,
    hiddenTooltipLogged = nil,
    category = nil,
    categorySpokenAt = -100,
    tabs = nil,
    tabsLogged = false,
    focusButton = nil,
    focusedItemId = nil,
    equipmentCache = nil,
    unitCache = nil,
    unitCacheUntil = 0,
    unitCacheLogged = nil,
}

function menuInfo.defaultObject(className)
    local object = menuInfo.defaults[className]
    if not object or not object:IsValid() then
        object = StaticFindObject("/Script/mucha.Default__" .. className)
        menuInfo.defaults[className] = object
    end
    return object
end

function menuInfo.call(object, functionName, ...)
    local args = { ... }
    local ok, value = pcall(function()
        return object[functionName](object, table.unpack(args))
    end)
    return ok and value or nil
end

function menuInfo.toText(value)
    local ok, text = pcall(function()
        return type(value) == "string" and value or value:ToString()
    end)
    return ok and text ~= "" and text or nil
end

-- Spielbare Figuren als { id, parameter, name }. Die Gruppenplaetze allein reichen nicht: Laut Log
-- belegt in der Demo nur Lasswell einen Platz ("Gruppe 1 von 4"), Rain fehlt dort.
function menuInfo.partyUnits()
    local now = os.clock()
    if menuInfo.unitCache and now < menuInfo.unitCacheUntil then
        return menuInfo.unitCache
    end
    local party = menuInfo.defaultObject("CPP_BFL_SaveDataParty")
    local unitFunctions = menuInfo.defaultObject("CPP_BFL_Unit")
    local units = {}
    local seen = {}
    local function add(id)
        if type(id) ~= "number" or seen[id] then
            return
        end
        seen[id] = true
        local parameter = menuInfo.call(unitFunctions, "GetPlayableUnitParameterObj", id)
        if parameter and parameter:IsValid() then
            local name = menuInfo.toText(menuInfo.call(parameter, "GetUnitName"))
            if name then
                table.insert(units, { id = id, parameter = parameter, name = name })
            end
        end
    end
    for index = 0, (menuInfo.call(party, "GetPartyMax") or 4) - 1 do
        add(menuInfo.call(party, "GetPartyUnitIdFromIndex", index))
    end
    for _, parameter in ipairs(FindAllOf("CPP_UnitParameter") or {}) do
        if parameter:IsValid() then
            add(menuInfo.call(parameter, "GetUnitId"))
        end
    end
    menuInfo.unitCache, menuInfo.unitCacheUntil = units, now + menuInfo.UNIT_CACHE_SECONDS
    local names = {}
    for _, unit in ipairs(units) do
        table.insert(names, unit.id .. "=" .. unit.name)
    end
    local summary = table.concat(names, ", ")
    if summary ~= menuInfo.unitCacheLogged then
        menuInfo.unitCacheLogged = summary
        log("Figuren: " .. summary)
    end
    return units
end

-- Findet ein benanntes Widget auch dann, wenn es gerade ausgeblendet ist.
function menuInfo.findNamedWidget(widget, name, depth)
    if not widget or not widget:IsValid() or depth > MAX_WALK_DEPTH then
        return nil
    end
    if objectName(widget) == name then
        return widget
    end
    if isA(widget, "UserWidget") then
        local tree = widget.WidgetTree
        return tree and tree:IsValid() and menuInfo.findNamedWidget(tree.RootWidget, name, depth + 1) or nil
    end
    if isA(widget, "PanelWidget") then
        for index = 0, widget:GetChildrenCount() - 1 do
            local found = menuInfo.findNamedWidget(widget:GetChildAt(index), name, depth + 1)
            if found then
                return found
            end
        end
    end
    return nil
end

function menuInfo.containsWidget(widget, address, depth)
    if not widget or not widget:IsValid() or depth > MAX_WALK_DEPTH then
        return false
    end
    if widget:GetAddress() == address then
        return true
    end
    if isA(widget, "UserWidget") then
        local tree = widget.WidgetTree
        return tree and tree:IsValid() and menuInfo.containsWidget(tree.RootWidget, address, depth + 1) or false
    end
    if isA(widget, "PanelWidget") then
        for index = 0, widget:GetChildrenCount() - 1 do
            if menuInfo.containsWidget(widget:GetChildAt(index), address, depth + 1) then
                return true
            end
        end
    end
    return false
end

-- Ausruestung, Vision und Fertigkeiten liegen in einer Liste, leere Plaetze lauten alle "-".
-- Abschnitt und Platz der Zeile; Ergebnis je Zeile gemerkt, weil rowText im 200-ms-Takt laeuft.
function menuInfo.equipSlot(row)
    local address = row:GetAddress()
    if menuInfo.equipSlotRow == address then
        return menuInfo.equipSlotInfo
    end
    local layout = menuInfo.equipLayout
    if not layout or not layout:IsValid() then
        return nil
    end
    menuInfo.equipSlotRow, menuInfo.equipSlotInfo = address, nil
    local list = menuInfo.findNamedWidget(layout, "WBP_UnitEquippedList", 0)
    for _, section in ipairs(menuInfo.EQUIP_SECTIONS) do
        local sectionWidget = list and menuInfo.findNamedWidget(list, section[1], 0)
        local grid = sectionWidget and menuInfo.findNamedWidget(sectionWidget, "GridPanel_28", 0)
        -- Zwischen den Plaetzen liegen Spacer, sie zaehlen nicht mit.
        local count, slotIndex = 0, nil
        for index = 0, (grid and grid:GetChildrenCount() or 0) - 1 do
            local child = grid:GetChildAt(index)
            if shortClassName(child) ~= "Spacer" then
                count = count + 1
                if not slotIndex and menuInfo.containsWidget(child, address, 0) then
                    slotIndex = count
                end
            end
        end
        if slotIndex then
            local titleWidget = menuInfo.findNamedWidget(sectionWidget, "Text_Title", 0)
            local title = titleWidget and widgetText(titleWidget) or section[2]
            menuInfo.equipSlotInfo = { title = title, index = slotIndex, count = count }
            log(string.format("Ausruestungsplatz: %s %d von %d", title, slotIndex, count))
            return menuInfo.equipSlotInfo
        end
    end
    return nil
end
-- Q/E wechselt hier die Figur (Log 22:25: Shiden, Purpurklinge), ohne dass sie genannt wird.
function menuInfo.tickEquipFigure()
    local layout = menuInfo.equipLayout
    if not layout or not layout:IsValid() then
        menuInfo.equipFigure, menuInfo.equipFigureWidget = nil, nil
        return
    end
    local widget = menuInfo.equipFigureWidget
    if not widget or not widget:IsValid() then
        local status = menuInfo.findNamedWidget(layout, "WBP_UnitStatus_NameExp", 0)
        widget = status and menuInfo.findNamedWidget(status, "Text_Name", 0)
        menuInfo.equipFigureWidget = widget
    end
    local name = widget and widgetText(widget)
    if not name or name == menuInfo.equipFigure then
        return
    end
    local previous = menuInfo.equipFigure
    menuInfo.equipFigure = name
    -- In der Figurenliste sagt der Fokus den Namen schon selbst.
    if previous and menuInfo.focusedSlotRow() then
        log("Figur: " .. name)
        menuInfo.categorySpokenAt = os.clock()
        speak(name, true)
        menuInfo.respeakFocus()
    end
end

-- Weltkarte im Hauptmenue (WBP_WldMapLayout_C): Der Zeiger rastet an Orten ein (Ton Map.Target.On), das Spiel
-- zeigt dann Ortsname und Quests in WBP_WM_LandmarkQuestInfo; WBP_WldMap_IslandName nennt das Gebiet.
-- Angesagt wird, sobald der Text zwei Abfragen lang gleich bleibt (er fuellt sich nach und nach).
menuInfo.WORLD_MAP_PANELS = { "WBP_WldMap_IslandName", "WBP_WM_LandmarkQuestInfo" }

function menuInfo.tickWorldMap()
    local layout = menuInfo.worldMapLayout
    if not layout or not layout:IsValid() then
        menuInfo.worldMapWidgets, menuInfo.worldMapSpoken, menuInfo.worldMapPending = nil, nil, nil
        return
    end
    menuInfo.worldMapWidgets = menuInfo.worldMapWidgets or {}
    if not menuInfo.worldMapSpoken then
        -- Den Gebietsnamen sagt schon die Bildschirmansage beim Oeffnen.
        local island = menuInfo.findNamedWidget(layout, menuInfo.WORLD_MAP_PANELS[1], 0)
        menuInfo.worldMapSpoken = { [menuInfo.WORLD_MAP_PANELS[1]] = island and readTexts(island, {}) or nil }
    end
    menuInfo.worldMapPending = menuInfo.worldMapPending or {}
    for _, name in ipairs(menuInfo.WORLD_MAP_PANELS) do
        local widget = menuInfo.worldMapWidgets[name]
        if not widget or not widget:IsValid() then
            widget = menuInfo.findNamedWidget(layout, name, 0)
            menuInfo.worldMapWidgets[name] = widget
        end
        local text = widget and not isHidden(widget) and readTexts(widget, {}) or ""
        if text == "" then
            -- Zeiger hat den Ort verlassen: Derselbe Ort wird beim Wiederkommen erneut genannt.
            menuInfo.worldMapSpoken[name], menuInfo.worldMapPending[name] = nil, nil
        elseif text == menuInfo.worldMapPending[name] and text ~= menuInfo.worldMapSpoken[name] then
            menuInfo.worldMapSpoken[name] = text
            log("Weltkarte " .. name .. ": " .. text)
            speak(text, true)
        else
            menuInfo.worldMapPending[name] = text
        end
    end
end

-- In der Figurenauswahl ist der Name nicht sichtbar. Rueckfall: Abgleich der LP mit der Gruppe.
function menuInfo.unitRowName(row, text)
    local nameWidget = menuInfo.findNamedWidget(row, "UnitName", 0)
    local name = nameWidget and widgetText(nameWidget)
    if name then
        return name
    end
    local hitPoints, maxHitPoints = text:match("^LP, (%d+) von (%d+)")
    for _, unit in ipairs(menuInfo.partyUnits()) do
        if tostring(menuInfo.call(unit.parameter, "GetHitPoint")) == hitPoints
            and tostring(menuInfo.call(unit.parameter, "GetMaxHitPoint")) == maxHitPoints then
            return unit.name
        end
    end
    return nil
end

-- Auswahlliste der Ausruestung: Das Spiel zeigt nur das Zeichen "A" (ST_UI_EquipMenu EquipEquippedMark)
-- bzw. das Gesicht der tragenden Figur. Stand aus VM_UnitEquippableItem (IsEquipped, IsEquippedByOther, OwnerId).
function menuInfo.equippableState(row)
    local node = row
    while node and node:IsValid() and not isA(node, "Activatable") do
        if shortClassName(node) == "WBP_UnitEquippableItemEntry_C" then
            local viewModel = node.VM_UnitEquippableItem
            if not viewModel or not viewModel:IsValid() then
                return nil
            end
            if menuInfo.call(viewModel, "IsEquippedByOther") then
                local ok, ownerId = pcall(function()
                    return viewModel.InventoryData.OwnerId
                end)
                for _, unit in ipairs(menuInfo.partyUnits()) do
                    if ok and unit.id == ownerId then
                        return "ausgerüstet von " .. unit.name
                    end
                end
                return "von anderer Figur ausgerüstet"
            end
            return menuInfo.call(viewModel, "IsEquipped") and "ausgerüstet" or nil
        end
        node = node:GetOuter()
    end
    return nil
end

function menuInfo.rowText(row)
    local text = readTexts(row, {})
    local state = menuInfo.equippableState(row)
    if state then
        text = text:gsub("^A, ", "") .. ", " .. state
    end
    if state ~= menuInfo.equipStateLogged then
        menuInfo.equipStateLogged = state
        log("Ausruestungsstand: " .. tostring(state) .. " | " .. text)
    end
    local slot = menuInfo.equipSlot(row)
    if text == "-" then
        if not slot then
            return "Leer"
        end
        if slot.count > 1 then
            return string.format("%s, Platz %d von %d, Leer", slot.title, slot.index, slot.count)
        end
        return slot.title .. ", Leer"
    end
    -- Der einzelne Platz ist die Vision: Ihr Name allein verraet den Abschnitt nicht.
    if slot and slot.count == 1 and text ~= "" then
        return slot.title .. ", " .. text
    end
    if text:find("^LP, ") then
        local name = menuInfo.unitRowName(row, text)
        return name and (name .. ", " .. text) or text
    end
    return text
end

function menuInfo.equipmentDetailName(detailType)
    local name = nil
    local data = FindFirstOf("CPP_DA_ItemText")
    if data and data:IsValid() then
        pcall(function()
            data.EquipDetailTypeTextMap:ForEach(function(key, value)
                if key:get() == detailType then
                    name = menuInfo.toText(value:get())
                end
            end)
        end)
    end
    return name or menuInfo.EQUIPMENT_DETAIL_TYPES[detailType]
end

-- Art, Werte und ausruestende Figuren. Klassen kennt das Spiel nicht: Jede Figur hat
-- eigene Waffen- und Ruestungsarten (FUNIT_PLAYABLE_PARAMETER), daher werden Figuren genannt.
function menuInfo.describeEquipment(itemId)
    local items = menuInfo.defaultObject("CPP_BFL_Item")
    if menuInfo.call(items, "GetItemTypeById", itemId) ~= menuInfo.ITEM_TYPE_EQUIPMENT then
        return nil
    end
    local parts = {}
    local kind = {}
    table.insert(kind, menuInfo.EQUIPMENT_TYPES[menuInfo.call(items, "GetEquipmentTypeById", itemId)])
    table.insert(kind, menuInfo.equipmentDetailName(menuInfo.call(items, "GetEquipmentDetailType", itemId)))
    if #kind > 0 then
        table.insert(parts, table.concat(kind, ", "))
    end
    local values = {}
    for _, parameter in ipairs(menuInfo.EQUIPMENT_PARAMETERS) do
        local value = menuInfo.call(items, "GetEquipmentVariationParameter", itemId, parameter[1])
        if type(value) == "number" and value ~= 0 then
            table.insert(values, parameter[2] .. (value > 0 and " +" or " ") .. string.format("%d", value))
        end
    end
    if #values > 0 then
        table.insert(parts, table.concat(values, ", "))
    end
    local unitFunctions = menuInfo.defaultObject("CPP_BFL_Unit")
    local wearers = {}
    for _, unit in ipairs(menuInfo.partyUnits()) do
        if menuInfo.call(unitFunctions, "IsEquipableEquipment", unit.id, itemId) then
            table.insert(wearers, unit.name)
        end
    end
    table.insert(parts, #wearers > 0 and ("Ausrüstbar für " .. table.concat(wearers, ", ")) or "Für niemanden in der Gruppe")
    return table.concat(parts, ". ")
end

-- Einmal je Fokus: Die Abfrage durchsucht Objektlisten und wuerde im 200-ms-Takt das Spiel bremsen.
function menuInfo.cachedEquipment(itemId)
    if not itemId then
        return nil
    end
    local cache = menuInfo.equipmentCache
    if not cache or cache.id ~= itemId then
        cache = { id = itemId, text = menuInfo.describeEquipment(itemId) }
        menuInfo.equipmentCache = cache
    end
    return cache.text
end

-- Die Listenzeile traegt ihr Item selbst (WBP_ActionEntryBase_C.ActionKey).
function menuInfo.rowItemId(button)
    local node = button
    while node and node:IsValid() do
        if isA(node, "Activatable") then
            return nil
        end
        if shortClassName(node) == "WBP_ActionEntryBase_C" then
            local ok, id = pcall(function()
                local key = node.ActionKey
                return key.Category == menuInfo.ACTION_CATEGORY_ITEM and key.ID or nil
            end)
            return ok and type(id) == "number" and id > 0 and id or nil
        end
        node = node:GetOuter()
    end
    return nil
end

function menuInfo.tooltipItemId(viewModel)
    local ok, id = pcall(function()
        local key = viewModel.ActionKey
        return key.Category == menuInfo.ACTION_CATEGORY_ITEM and key.ID or nil
    end)
    if ok and type(id) == "number" and id > 0 then
        return id
    end
    ok, id = pcall(function()
        return viewModel:GetCurrentContentVM().ItemId
    end)
    return ok and type(id) == "number" and id > 0 and id or nil
end

function menuInfo.findTooltipVM()
    local now = os.clock()
    if (not menuInfo.tooltipVM or not menuInfo.tooltipVM:IsValid()) and now >= menuInfo.nextTooltipSearch then
        menuInfo.nextTooltipSearch = now + menuInfo.SEARCH_INTERVAL_SECONDS
        menuInfo.tooltipVM = FindFirstOf("CPP_VM_Tooltip")
    end
    local viewModel = menuInfo.tooltipVM
    return viewModel and viewModel:IsValid() and viewModel or nil
end

-- Das Tooltip-Fenster bleibt dauerhaft aktiviert und wechselt nur seinen Inhalt.
function menuInfo.tickTooltip()
    if os.clock() < menuInfo.tooltipDue then
        return
    end
    local layout = menuInfo.tooltipLayout
    local text = layout and layout:IsValid() and readTexts(layout, {}) or ""
    local viewModel = menuInfo.findTooltipVM()
    if text ~= "" and viewModel and not (viewModel.IsDisplayTooltip or viewModel.bDisplay) then
        if text ~= menuInfo.hiddenTooltipLogged then
            menuInfo.hiddenTooltipLogged = text
            log("Tooltip verborgen: " .. text)
        end
        text = ""
    end
    -- Waffen und Ruestungen ohne Beschreibung zeigen gar keinen Tooltip, die Zeile kennt ihr Item aber selbst.
    local itemId = menuInfo.focusedItemId or (text ~= "" and viewModel and menuInfo.tooltipItemId(viewModel)) or nil
    local equipment = menuInfo.cachedEquipment(itemId)
    if equipment then
        text = text == "" and equipment or (text:gsub("%.$", "") .. ". " .. equipment)
    end
    if text == "" then
        return
    end
    if text ~= menuInfo.spokenTooltip then
        menuInfo.spokenTooltip = text
        log("Tooltip (" .. tostring(itemId) .. "): " .. text)
        speak(text, false)
    end
end

function menuInfo.categoryName(tag, tagName)
    local data = StaticFindObject(menuInfo.ITEM_CATEGORY_ASSET)
    if data:IsValid() then
        for _, argument in ipairs({ tag, { TagName = FName(tagName) } }) do
            local ok, text = pcall(function()
                return data:GetCategoryName(argument):ToString()
            end)
            if ok and text ~= "" then
                return text
            end
        end
    end
    local leaf = (tagName:match("([^.]+)$") or tagName):lower()
    return menuInfo.CATEGORY_FALLBACK_NAMES[leaf] or leaf
end

-- Aktueller Tag des Viewmodels; laut Log 13:04 blieb er bei Q/E leer, daher zusaetzlich die Tabs.
function menuInfo.viewModelCategoryTag(layout)
    if not menuInfo.itemLayoutVM or not menuInfo.itemLayoutVM:IsValid() then
        local ok, viewModel = pcall(function()
            return layout.CPP_VM_ItemLayout
        end)
        menuInfo.itemLayoutVM = ok and viewModel and viewModel:IsValid() and viewModel or FindFirstOf("CPP_VM_ItemLayout")
    end
    local viewModel = menuInfo.itemLayoutVM
    if not viewModel or not viewModel:IsValid() then
        return nil, nil
    end
    local tag = viewModel.FocusCategory
    local tagName = tag.TagName:ToString()
    if tagName == "" or tagName == "None" then
        return nil, nil
    end
    return tag, tagName
end

-- Blueprint-Felder sind in den Dumps nicht enthalten: einmal alle Eigenschaften der Tab-Klasse loggen.
function menuInfo.logTabProperties(entry)
    if menuInfo.tabsLogged then
        return
    end
    menuInfo.tabsLogged = true
    local names = {}
    pcall(function()
        entry:GetClass():ForEachProperty(function(property)
            table.insert(names, property:GetFName():ToString())
        end)
    end)
    log("Tab-Felder: " .. table.concat(names, ", "))
end

-- Sucht in den Feldern des Tabs nach einem GameplayTag.
function menuInfo.tabEntryTag(entry)
    local found, foundName = nil, nil
    pcall(function()
        entry:GetClass():ForEachProperty(function(property)
            local fieldName = property:GetFName():ToString()
            if not found and (fieldName:find("Tag") or fieldName:find("Category")) then
                local ok, tagName = pcall(function()
                    return entry[fieldName].TagName:ToString()
                end)
                if ok and tagName ~= "" and tagName ~= "None" then
                    found, foundName = entry[fieldName], tagName
                end
            end
        end)
    end)
    return found, foundName
end

function menuInfo.findTabs(layout)
    local tabs = menuInfo.tabs
    if tabs and tabs.layout:IsValid() and tabs.layout:GetAddress() == layout:GetAddress()
        and tabs.grid:IsValid() and tabs.menu:IsValid() then
        return tabs
    end
    local root = menuInfo.findNamedWidget(layout, "WBP_InventoryCategoryTab", 0)
    local grid = root and menuInfo.findNamedWidget(root, "GridPanel_28", 0)
    local menu = root and menuInfo.findNamedWidget(root, "PathMenu", 0)
    if not grid or not menu then
        return nil
    end
    menuInfo.tabs = { layout = layout, grid = grid, menu = menu }
    return menuInfo.tabs
end

-- Index (ab 1) und Widget des gewaehlten Tabs: zuerst der Menuefokus, sonst der sichtbare Tab-Cursor.
function menuInfo.selectedTab(tabs)
    local ok, item = pcall(currentMenuItem, tabs.menu)
    local itemPath = ok and item and item:IsValid() and objectPath(item) or nil
    local count = tabs.grid:GetChildrenCount()
    for index = 0, count - 1 do
        local entry = tabs.grid:GetChildAt(index)
        if itemPath and itemPath:find(objectPath(entry), 1, true) == 1 then
            return index + 1, entry
        end
    end
    for index = 0, count - 1 do
        local entry = tabs.grid:GetChildAt(index)
        local cursor = menuInfo.findNamedWidget(entry, "WBP_SubTabCursor", 0)
        if cursor and not isHidden(cursor) and cursor:GetRenderOpacity() > 0 then
            return index + 1, entry
        end
    end
    return nil, nil
end

-- Liefert den Kategorienamen einmal je Wechsel (Q/E) im Gegenstaendemenue.
function menuInfo.takeCategoryChange()
    local layout = menuInfo.itemLayout
    if not layout or not layout:IsValid() then
        menuInfo.category, menuInfo.itemLayoutVM, menuInfo.tabs = nil, nil, nil
        return nil
    end
    local tag, tagName = menuInfo.viewModelCategoryTag(layout)
    local tabs = not tagName and menuInfo.findTabs(layout) or nil
    local index, entry = nil, nil
    if tabs then
        index, entry = menuInfo.selectedTab(tabs)
        if entry then
            menuInfo.logTabProperties(entry)
            tag, tagName = menuInfo.tabEntryTag(entry)
        end
    end
    local key = tagName or (index and ("Tab " .. index)) or nil
    if not key or key == menuInfo.category then
        return nil
    end
    menuInfo.category = key
    menuInfo.categorySpokenAt = os.clock()
    local name = tagName and menuInfo.categoryName(tag, tagName) or menuInfo.TAB_FALLBACK_NAMES[index] or key
    log("Kategorie: " .. key .. " (Tab " .. tostring(index) .. ") = " .. name)
    return name
end

function menuInfo.noteFocusChange(button)
    menuInfo.spokenTooltip, menuInfo.equipmentCache = nil, nil
    menuInfo.tooltipDue = os.clock() + menuInfo.TOOLTIP_READ_DELAY_SECONDS
    menuInfo.focusButton = button or menuInfo.focusButton
    menuInfo.focusedItemId = menuInfo.focusButton and menuInfo.focusButton:IsValid()
        and menuInfo.rowItemId(menuInfo.focusButton) or nil
end

function menuInfo.readMoney()
    -- In Gespraechen oeffnet G das Gespraechslog des Spiels (IMC_UI_Event_KBM).
    for _, className in ipairs({ "WBP_TalkEventLayout_C", "WBP_Backlog_C" }) do
        for _, screen in ipairs(FindAllOf(className) or {}) do
            if screen:IsValid() and screen:IsActivated() then
                log("Gil uebersprungen, aktiv: " .. className)
                return
            end
        end
    end
    local money = menuInfo.call(menuInfo.defaultObject("CPP_BFL_SaveDataPlayer"), "GetCurrentMoney")
    if type(money) == "number" then
        speak(string.format("%d Gil", money), true)
    else
        log("Gil nicht lesbar: " .. tostring(money))
        speak("Gil nicht lesbar.", true)
    end
end

-- Gleich nach einem Kategoriewechsel darf der neue Eintrag den Namen nicht abschneiden.
function menuInfo.mayInterrupt()
    return os.clock() - menuInfo.categorySpokenAt > menuInfo.CATEGORY_SPEECH_SECONDS
end

function menuInfo.tickCategory()
    local name = menuInfo.takeCategoryChange()
    if name then
        speak(name, true)
        -- Der Eintrag kam schon vor dem Kategoriewechsel und wurde eben unterbrochen.
        if focusedText and os.clock() - lastFocusSpeechAt < menuInfo.CATEGORY_SPEECH_SECONDS / 2 then
            speak(focusedText, false)
        end
    end
end

function menuInfo.focusedSlotRow()
    return focusedEntry and focusedEntry:IsValid() and menuInfo.equipSlot(focusedEntry) ~= nil
end

function menuInfo.respeakFocus()
    if focusedText then
        speak(focusedText, false)
    end
end

-- Vom fokussierten Button nach aussen zur Listenzeile: der aeusserste "Entry" gewinnt,
-- sonst das naechste Widget mit Text. Die Suche endet am umgebenden Bildschirm.
local function findFocusRow(button)
    local node = button
    local outermostEntry = nil
    local firstWithText = nil
    while node and node:IsValid() do
        if isA(node, "Activatable") then
            break
        end
        if isA(node, "UserWidget") then
            if shortClassName(node):find("Entry", 1, true) then
                outermostEntry = node
            end
            if not firstWithText and readTexts(node, {}) ~= "" then
                firstWithText = node
            end
        end
        node = node:GetOuter()
    end
    return outermostEntry or firstWithText or button
end

-- Der Fokus eines Dialogs darf seinen Text nicht abschneiden: "OK" kam vor der Item-Meldung und 30 ms danach noch einmal
-- als Unterbrechung (Log 09:55:07). Vor dem Lesen schweigt er, readDialog sagt ihn nach dem Text an. Danach unterbricht
-- nur ein anderer Eintrag, also ein Tastendruck.
function menuInfo.dialogFocusHandled(path, text)
    local root = path and path:match("^(.-DialogLayout[^.]*)")
    if not root then
        return false
    end
    -- Wird das Fenster nicht bald als Bildschirm erkannt, soll der Fokus nicht fuer immer stumm bleiben.
    if not knownScreens[root] then
        menuInfo.unreadSince = menuInfo.unreadRoot == root and menuInfo.unreadSince or os.clock()
        menuInfo.unreadRoot = root
        return os.clock() - menuInfo.unreadSince < 1
    end
    for _, pending in ipairs(pendingScreens) do
        if pending.screen:IsValid() and objectPath(pending.screen) == root then
            return true
        end
    end
    local previous = menuInfo.dialogFocusText
    menuInfo.dialogFocusText = text
    if text == previous then
        return true
    end
    if previous == nil then
        speak(text, false)
        return true
    end
    return false
end

local function setFocus(button, isFocused)
    local row = findFocusRow(button)
    local path = objectPath(row)
    if not isFocused then
        if path == focusedPath then
            focusedEntry, focusedPath, focusedText = nil, nil, nil
            menuInfo.focusButton, menuInfo.focusedItemId = nil, nil
        end
        return
    end
    if path == focusedPath then
        return
    end
    local text = menuInfo.rowText(row)
    if text == "" then
        log("Fokus ohne Text: " .. tostring(path))
        return
    end
    focusedEntry, focusedPath, focusedText = row, path, text
    menuInfo.noteFocusChange(button)
    local okCategory, category = pcall(menuInfo.takeCategoryChange)
    category = okCategory and category or nil
    -- Verschachtelte Buttons melden denselben Fokus mehrfach direkt hintereinander.
    local now = os.clock()
    if menuInfo.dialogFocusHandled(path, text) then
        lastFocusSpeech, lastFocusSpeechAt = text, now
        return
    end
    if category then
        speak(category .. ", " .. text, true)
    elseif text ~= lastFocusSpeech or now - lastFocusSpeechAt > DUPLICATE_FOCUS_WINDOW_SECONDS then
        speak(text, menuInfo.mayInterrupt())
    end
    lastFocusSpeech, lastFocusSpeechAt = text, now
end

local function onIsFocused(context, isFocused)
    local button = context:get()
    if button:IsValid() then
        setFocus(button, isFocused:get())
    end
end

local function onFocused(context)
    local button = context:get()
    if button:IsValid() then
        setFocus(button, true)
    end
end

local function registerFocusHook(path)
    if registeredHooks[path] or not StaticFindObject(path):IsValid() then
        return
    end
    local callback = path:find("BP_OnIsFocused", 1, true) and onIsFocused or onFocused
    local ok, err = pcall(RegisterHook, path, callback)
    if ok then
        registeredHooks[path] = true
        log("Fokus-Hook aktiv: " .. path)
    elseif not failedHooks[path] then
        -- Waehrend des Ladens ist die Klasse schon auffindbar, aber noch nicht hookbar: spaeter erneut versuchen.
        failedHooks[path] = true
        log("Fokus-Hook noch nicht moeglich: " .. path .. " " .. tostring(err))
    end
end

local function tryRegisterFocusHooks()
    for _, path in ipairs(FOCUS_HOOKS) do
        registerFocusHook(path)
    end
end

-- Haengt sich an die Fokus-Ereignisse einer Button-Klasse und ihrer Blueprint-Elternklassen.
local function hookClassChain(class)
    while class and class:IsValid() do
        local path = objectPath(class)
        if not path or path:find("/Script/", 1, true) == 1 then
            return
        end
        for _, eventName in ipairs(FOCUS_EVENT_NAMES) do
            registerFocusHook(path .. ":" .. eventName)
        end
        class = class:GetSuperStruct()
    end
end

-- Menue-Container melden ebenfalls Fokus, wuerden aber alle Eintraege auf einmal vorlesen.
local function discoverFocusHooks()
    local now = os.clock()
    if now < nextHookDiscovery then
        return
    end
    nextHookDiscovery = now + HOOK_DISCOVERY_INTERVAL_SECONDS
    for _, button in ipairs(FindAllOf("CPP_WBP_ButtonEvent") or {}) do
        local class = button:GetClass()
        local key = class:GetAddress()
        if not discoveredClasses[key] then
            discoveredClasses[key] = true
            if not isA(button, "MenuBase") and not isA(button, "MenuPath") then
                hookClassChain(class)
            end
        end
    end
end

-- Liest den Wert der fokussierten Zeile neu, damit Aenderungen per Links/Rechts hoerbar sind.
local function refreshFocusedValue()
    if not focusedEntry then
        return
    end
    if not focusedEntry:IsValid() then
        focusedEntry, focusedPath, focusedText = nil, nil, nil
        return
    end
    local text = menuInfo.rowText(focusedEntry)
    if text ~= "" and text ~= focusedText then
        focusedText = text
        menuInfo.noteFocusChange()
        speak(text, menuInfo.mayInterrupt())
    end
end

-- Nur der angezeigte Text hat Platzhalter wie {difficulty} bereits ersetzt, nicht DialogBoxInfo.
-- Die Antworten stecken im Menue und werden einzeln beim Fokus angesagt.
local function dialogMessage(dialog)
    return readTexts(dialog, { skipMenus = true })
end

local function screenText(screen)
    if isA(screen, "DialogLayout") then
        return dialogMessage(screen)
    end
    return SCREEN_TEXT_OVERRIDES[shortClassName(screen)] or readTexts(screen, { staticOnly = true })
end

local function logWidgetTree(widget, depth)
    if not widget or not widget:IsValid() or depth > MAX_WALK_DEPTH then
        return
    end
    -- Jeden Bildschirmtyp nur einmal aufzeichnen, das Log dient dem Nachbessern neuer Menues.
    if depth == 0 then
        local className = shortClassName(widget)
        if loggedTreeClasses[className] then
            return
        end
        loggedTreeClasses[className] = true
    end
    log(string.rep("  ", depth) .. shortClassName(widget) .. " " .. objectName(widget))
    if isA(widget, "UserWidget") then
        local tree = widget.WidgetTree
        if tree and tree:IsValid() then
            logWidgetTree(tree.RootWidget, depth + 1)
        end
    elseif isA(widget, "PanelWidget") then
        for index = 0, widget:GetChildrenCount() - 1 do
            logWidgetTree(widget:GetChildAt(index), depth + 1)
        end
    end
end

local function isInsideDialog(path)
    return path and activeDialogPath and path:find(activeDialogPath, 1, true) == 1
end

-- Das Fenster zeigt seine Gegenstaende in eigenen Eintraegen, damit sind auch Geschenke abgedeckt.
function menuInfo.dialogItems()
    local items = {}
    for _, item in ipairs(FindAllOf("WBP_DialogCustomContent_Item_C") or {}) do
        if item:IsValid() and isInsideDialog(objectPath(item)) then
            local text = readTexts(item, {})
            if text ~= "" then
                table.insert(items, text)
            end
        end
    end
    return table.concat(items, "; ")
end

-- Endet die Nachricht mit einem Doppelpunkt, steht der Rest ausserhalb des Nachrichtentexts.
local function completeDialogMessage(dialog, message)
    if not message:find(":$") then
        return message
    end
    local items = menuInfo.dialogItems()
    if items ~= "" then
        return message .. " " .. items
    end
    local ok, pickup = pcall(describePickup)
    if not ok then
        log("Fund nicht lesbar: " .. tostring(pickup))
    end
    return ok and pickup and (message .. " " .. pickup) or message
end

local function readDialog(dialog)
    activeDialog, activeDialogPath = dialog, objectPath(dialog)
    log("Dialog: " .. shortClassName(dialog))
    logWidgetTree(dialog, 0)
    local message = dialogMessage(dialog)
    spokenDialogMessage = message .. menuInfo.dialogItems()
    speak(completeDialogMessage(dialog, message), true)
    menuInfo.dialogFocusText = nil
    -- Der Fokus kam schon beim Oeffnen und hat auf die Nachricht gewartet.
    if isInsideDialog(focusedPath) then
        menuInfo.dialogFocusText = focusedText
        speak(focusedText, false)
    end
end

-- Die Analyse zeigt Elemente und Zustaende nur als Symbole. Namen aus den Spieltexten ("Feuerimmunitaet",
-- "Gift aufheben" usw.), Widerstandsarten aus ST_UI_BattleDamageProp; 9 "Stopp" ist dort nicht belegt.
menuInfo.ELEMENT_NAMES = { "Feuer", "Eis", "Wind", "Erde", "Blitz", "Wasser", "Licht", "Dunkel" }
menuInfo.RESISTANCE_NAMES = { "Schwäche", "Widerstanden", "Immun", "Absorbiert", "Reflektiert" }
menuInfo.CONDITION_NAMES = { "Gift", "Blind", "Schlaf", "Stumm", "Lähmung", "Konfus", "Stein", "Bann", "Stopp",
    "Tobsucht", "Todesurteil", "Gemach", "Sofortiger Tod" }

function menuInfo.eachValue(list, callback)
    if type(list) == "table" then
        for _, value in ipairs(list) do
            local ok, unwrapped = pcall(function()
                return value:get()
            end)
            callback(ok and unwrapped ~= nil and unwrapped or value)
        end
    elseif list ~= nil then
        list:ForEach(function(_, element)
            callback(element:get())
        end)
    end
end

function menuInfo.resistanceName(viewModel, resistance)
    local ok, name = pcall(function()
        local result = {}
        viewModel.ResistanceDA:FindResistanceProperty(resistance, result)
        return result.OutData.Name:ToString()
    end)
    return ok and name ~= "" and name or menuInfo.RESISTANCE_NAMES[resistance] or ("Art " .. tostring(resistance))
end

-- Gegner der letzten Zielauswahl, sonst der einzige analysierte Gegner.
function menuInfo.libraViewModel()
    local analyzed = {}
    for _, viewModel in ipairs(FindAllOf("CPP_VM_BtlUnitParam") or {}) do
        if viewModel:IsValid() then
            for _, id in ipairs(menuInfo.lastTargetIds or {}) do
                if viewModel.UniqueID == id then
                    return viewModel
                end
            end
            if viewModel.bIsAnalyzed then
                table.insert(analyzed, viewModel)
            end
        end
    end
    return #analyzed == 1 and analyzed[1] or nil
end

-- Liefert die Elementzeile und die Zustandszeile; nil, wenn nichts bekannt ist.
function menuInfo.libraDetails()
    local viewModel = menuInfo.libraViewModel()
    if not viewModel then
        log("Analyse: kein Gegner gefunden")
        return nil, nil
    end
    local groups, order = {}, {}
    local ok, err = pcall(function()
        menuInfo.eachValue(viewModel.ElemResistDataList, function(data)
            local element, resistance = data.element, data.resistance
            log(string.format("Analyse Element: %s %s %s", tostring(element), tostring(resistance), tostring(data.bIsAnalyzed)))
            if data.bIsAnalyzed and resistance ~= 0 and menuInfo.ELEMENT_NAMES[element] then
                if not groups[resistance] then
                    groups[resistance] = {}
                    table.insert(order, resistance)
                end
                table.insert(groups[resistance], menuInfo.ELEMENT_NAMES[element])
            end
        end)
    end)
    if not ok then
        log("Analyse Elemente nicht lesbar: " .. tostring(err))
    end
    table.sort(order)
    local elementParts = {}
    for _, resistance in ipairs(order) do
        table.insert(elementParts, menuInfo.resistanceName(viewModel, resistance) .. ": " .. table.concat(groups[resistance], ", "))
    end
    local conditions = {}
    ok, err = pcall(function()
        menuInfo.eachValue(viewModel:GetInvalidConditionList(), function(condition)
            table.insert(conditions, menuInfo.CONDITION_NAMES[condition] or ("Zustand " .. tostring(condition)))
        end)
    end)
    if not ok then
        log("Analyse Zustaende nicht lesbar: " .. tostring(err))
    end
    log("Analyse " .. tostring(viewModel.UniqueID) .. ": " .. table.concat(elementParts, "; ") .. " | " .. table.concat(conditions, ", "))
    return #elementParts > 0 and table.concat(elementParts, "; ") or nil, #conditions > 0 and table.concat(conditions, ", ") or nil
end

-- Setzt die Symbolinhalte hinter die Ueberschriften "Angriffselement" und "Widerstaende".
function menuInfo.libraText(text)
    local elements, conditions = menuInfo.libraDetails()
    local function insertAfter(source, heading, addition)
        local first, last = source:find(heading, 1, true)
        if not addition or not first then
            return source
        end
        return source:sub(1, last) .. ", " .. addition .. source:sub(last + 1)
    end
    return insertAfter(insertAfter(text, "Angriffselement", elements), "Widerstände", conditions)
end

local function readScreen(screen)
    local className = shortClassName(screen)
    if className:find("DBG", 1, true) then
        return
    end
    if isA(screen, "DialogLayout") then
        readDialog(screen)
        return
    end
    -- Textfenster wechseln den Text ohne neue Aktivierung, das erledigt tickTalkWindows.
    if isA(screen, "TextWindow") then
        logWidgetTree(screen, 0)
        return
    end
    -- Die Ergebnisseiten zaehlen hoch, das erledigt tickBattleResult.
    if className:find("^WBP_Btl_?Result") then
        logWidgetTree(screen, 0)
        return
    end
    -- Der Tooltip wechselt den Text ohne neue Aktivierung, das erledigt menuInfo.tickTooltip.
    if className == "WBP_TooltipLayout_C" then
        logWidgetTree(screen, 0)
        return
    end
    local text = screenText(screen)
    logWidgetTree(screen, 0)
    if text == "" then
        log("Bildschirm ohne Text: " .. className)
        return
    end
    log("Bildschirm: " .. className)
    if className == "WBP_Btl_LibraInfoDetailLayout_C" then
        local ok, extended = pcall(menuInfo.libraText, text)
        text = ok and extended or text
    end
    speak(text, false)
end

-- Ersatz fuer Buttons ohne Fokus-Ereignis: fragt die Menues im offenen Dialog direkt ab.
local function tickDialogFocus()
    if not activeDialog then
        return
    end
    if not activeDialog:IsValid() or not activeDialog:IsActivated() then
        activeDialog, activeDialogPath = nil, nil
        return
    end
    -- Manche Fenster fuellen ihren Text erst nach dem Oeffnen.
    local message = dialogMessage(activeDialog)
    local shown = message .. menuInfo.dialogItems()
    if message ~= "" and shown ~= spokenDialogMessage then
        spokenDialogMessage = shown
        speak(completeDialogMessage(activeDialog, message), true)
        if isInsideDialog(focusedPath) then
            menuInfo.dialogFocusText = focusedText
            speak(focusedText, false)
        end
    end
    -- Der gemerkte Menue-Eintrag hinkt dem Fokus-Ereignis hinterher und wuerde es ueberstimmen.
    if isInsideDialog(focusedPath) then
        return
    end
    for _, menu in ipairs(FindAllOf("CPP_WBP_MenuBase") or {}) do
        local menuPath = objectPath(menu)
        if isInsideDialog(menuPath) then
            local ok, item = pcall(currentMenuItem, menu)
            if not dialogMenuPathLogged[menuPath] then
                dialogMenuPathLogged[menuPath] = true
                log("Dialog-Menue: " .. shortClassName(menu) .. " Abfrage " .. (ok and "ok" or ("fehlgeschlagen: " .. tostring(item))))
            end
            if ok and item and item:IsValid() then
                setFocus(item, true)
            end
        end
    end
end

-- Der Text erscheint nach und nach, deshalb wird er erst angesagt, wenn er sich nicht mehr aendert.
local function tickTalkWindows()
    local current, currentWindow = nil, nil
    for _, window in ipairs(FindAllOf("CPP_WBP_TextWindow") or {}) do
        -- Sprechtexte in Kampfszenen (WBP_TalkBattle_Caption_C in WBP_BattleSequencerLay_C) werden nicht aktiviert.
        if window:IsValid() and (window:IsActivated() or shortClassName(window) == "WBP_TalkBattle_Caption_C")
                and not isHidden(window) then
            local text = readTexts(window, { staticOnly = true })
            if text ~= "" then
                current, currentWindow = text, window
            end
        end
    end
    if current and current == pendingTalkText and current ~= spokenTalkText then
        spokenTalkText = current
        speak(current, true)
        if onTalkLine then
            onTalkLine(current, currentWindow)
        end
    end
    pendingTalkText = current
    if not current then
        spokenTalkText = nil
    end
end

-- Tutorials blaettern ohne neue Aktivierung und ohne Fokuswechsel um.
local function tickPagedScreen()
    if not (topScreen and topScreen:IsValid() and topScreen:IsActivated()
            and shortClassName(topScreen):find("Tutorial", 1, true)) then
        pagedScreenText = nil
        return
    end
    local text = screenText(topScreen)
    if pagedScreenText and text ~= "" and text ~= pagedScreenText then
        speak(text, true)
    end
    pagedScreenText = text
end

local function tickScreens()
    local now = os.clock()
    local current = {}
    menuInfo.itemLayout, menuInfo.tooltipLayout, menuInfo.equipLayout = nil, nil, nil
    menuInfo.worldMapLayout = nil
    for _, screen in ipairs(FindAllOf("CommonActivatableWidget") or {}) do
        if screen:IsValid() and screen:IsActivated() then
            local path = objectPath(screen)
            current[path] = true
            local className = shortClassName(screen)
            if className == "WBP_ItemLayout_C" then
                menuInfo.itemLayout = screen
            elseif className == "WBP_TooltipLayout_C" then
                menuInfo.tooltipLayout = screen
            elseif className == "WBP_ActionEquipmentLayout_C" then
                menuInfo.equipLayout = screen
            elseif className == "WBP_WldMapLayout_C" then
                menuInfo.worldMapLayout = screen
            end
            if not knownScreens[path] then
                -- Meldungen sollen zusammen mit dem Fenster kommen; was spaeter einlaeuft, holt tickDialogFocus nach.
                local delay = isA(screen, "DialogLayout") and menuInfo.DIALOG_READ_DELAY_SECONDS or SCREEN_READ_DELAY_SECONDS
                table.insert(pendingScreens, { screen = screen, due = now + delay })
                nextHookDiscovery = 0
            end
        end
    end
    knownScreens = current

    for index = #pendingScreens, 1, -1 do
        local pending = pendingScreens[index]
        if now >= pending.due then
            table.remove(pendingScreens, index)
            if pending.screen:IsValid() and pending.screen:IsActivated() then
                topScreen = pending.screen
                readScreen(pending.screen)
            end
        end
    end
end

local function guarded(name, callback)
    return function()
        local ok, err = pcall(callback)
        if not ok then
            log(name .. " fehlgeschlagen: " .. tostring(err))
        end
    end
end

-- Diagnose fuer Fenster, die sich nicht als aktivierter Bildschirm melden: alle Fenster im Viewport mit Text.
function menuInfo.logVisibleWindows()
    for _, widget in ipairs(FindAllOf("UserWidget") or {}) do
        local ok, inViewport = pcall(function()
            return widget:IsValid() and widget:IsInViewport() and not isHidden(widget)
        end)
        if ok and inViewport then
            local textOk, text = pcall(readTexts, widget, {})
            text = textOk and text or ("Fehler " .. tostring(text))
            log(string.format("Sichtbar: %s %s aktiv %s: %s", shortClassName(widget), objectName(widget),
                tostring(isA(widget, "CommonActivatableWidget") and widget:IsActivated()), text:sub(1, 300)))
        end
    end
end

local function readCurrentScreen()
    pcall(menuInfo.logVisibleWindows)
    if topScreen and topScreen:IsValid() and topScreen:IsActivated() then
        readScreen(topScreen)
    end
    if focusedText then
        speak(focusedText, false)
    end
    if menuInfo.spokenTooltip then
        speak(menuInfo.spokenTooltip, false)
    end
end

-- version.txt legt das Setup neben den Ordner Scripts; ohne Datei (Entwicklerstand) bleibt die Ansage ohne Nummer.
function menuInfo.modVersion()
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local scriptsDir = info and info.source and info.source:match("^@(.*[\\/])")
    local file = scriptsDir and io.open(scriptsDir .. "..\\version.txt", "r")
    if not file then
        return ""
    end
    local version = (file:read("*l") or ""):match("^%s*(.-)%s*$")
    file:close()
    return version ~= "" and ("Version " .. version .. " ") or ""
end

if startBridge() then
    local pipe, err = io.open(PIPE_PATH, "wb")
    if pipe then
        speechPipe = pipe
        speak("Final Fantasy Resonance Zugang " .. menuInfo.modVersion() .. "geladen.", false)
    else
        log("Pipe nicht geoeffnet: " .. tostring(err))
    end
end

local selectedCategory = 1
local selectedTargetPath = nil
local activeWalk = nil
local pendingCategorySteps = 0
local pendingTargetSteps = 0
local pendingWalkToggle = false
local navigationFunctions = nil
local diagnosedLevel = nil
local moveInputAction = nil
local conditionFunctions = nil
local mapFunctions = nil
local mapNames = {}
-- Namen stehen als Schluessel der Namenstabellen des Spiels (ST_CharaName:CharaName0049) und werden in der
-- eingestellten Spielsprache gelesen. Eintraege mit fertigem Text (aeltere Staende) gelten unveraendert.
menuInfo.NAME_TABLES = {
    ST_CharaName = "/Game/Datatable/Strings/CharaName/ST_CharaName.ST_CharaName",
    ST_UnitName = "/Game/Datatable/Strings/ST_Unit/ST_UnitName.ST_UnitName",
}
-- Spielfiguren und ??? sprechen mit, sind aber nie die angesprochene Person.
menuInfo.PARTY_NAME_REFS = { "ST_CharaName:CharaName0001", "ST_CharaName:CharaName0002", "ST_CharaName:CharaName0003", "ST_CharaName:CharaName0004" }
menuInfo.nameRefs = {}
menuInfo.resolvedNames = {}

function menuInfo.gameText(ref)
    local tableName, key = ref:match("^(ST_[%w_]+):(.+)$")
    local tablePath = tableName and menuInfo.NAME_TABLES[tableName]
    if not tablePath then
        return ref
    end
    if menuInfo.resolvedNames[ref] then
        return menuInfo.resolvedNames[ref]
    end
    local ok, text = pcall(function()
        local library = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        return library:TextFromStringTable(FName(tablePath), key):ToString()
    end)
    -- Fehlschlaege nicht merken: Die Tabelle kann beim ersten Versuch noch nicht geladen sein.
    if not ok or not text or text == "" or text == key or text:find("MISSING") then
        menuInfo.logLearn("Schluessel nicht lesbar: " .. ref .. " (" .. tostring(text) .. ")")
        return nil
    end
    menuInfo.resolvedNames[ref] = text
    return text
end

-- Rueckrichtung zum Lernen: gesprochener Name -> Schluessel, aus allen Schluesseln in namen_spiel.txt.
function menuInfo.nameRef(text)
    if not menuInfo.refByText then
        local map = {}
        for key, ref in pairs(menuInfo.nameRefs) do
            if key:find("^Name:") then
                local resolved = menuInfo.gameText(ref)
                -- ST_CharaName vor ST_UnitName: Gleiche Texte gibt es in beiden.
                if resolved and (not map[resolved] or ref:find("^ST_CharaName")) then
                    map[resolved] = ref
                end
            end
        end
        if next(map) == nil then
            return nil
        end
        menuInfo.refByText = map
    end
    return menuInfo.refByText[text]
end

function menuInfo.isPartySpeaker(text)
    for _, ref in ipairs(menuInfo.PARTY_NAME_REFS) do
        if menuInfo.gameText(ref) == text then
            return true
        end
    end
    return false
end

local npcNames = setmetatable({}, {
    __index = function(_, key)
        local ref = menuInfo.nameRefs[key]
        return ref and menuInfo.gameText(ref) or nil
    end,
    __newindex = function(_, key, value)
        menuInfo.nameRefs[key] = value
    end,
})
local inputSubsystem = nil

local function distance2D(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
end

local function playerUnit()
    local controller = FindFirstOf("CPP_MuchaPlayerController")
    if not controller or not controller:IsValid() then
        return nil
    end
    local pawn = controller.Pawn
    if pawn and pawn:IsValid() and isA(pawn, "MapUnitPlayable") then
        return pawn, controller
    end
    return nil
end

local function interactTypeOf(actor)
    for _, propertyName in ipairs({ "m_MapInteractType", "interactType" }) do
        local ok, value = pcall(function()
            return actor[propertyName]
        end)
        if ok and type(value) == "number" and value ~= 0 then
            return value
        end
    end
    return nil
end

local function isSelectable(actor)
    local ok, excluded = pcall(function()
        return actor.bHidden
    end)
    if ok and excluded == true then
        return false
    end
    local stateOk, state = pcall(function()
        return actor.m_GimmickCondition
    end)
    return not (stateOk and state == GIMMICK_STATE_DEACTIVE)
end

local function callFunction(object, functionName)
    local ok, value = pcall(function()
        return object[functionName](object)
    end)
    return ok and value or nil
end

local function textOf(value)
    local ok, text = pcall(function()
        return value:ToString()
    end)
    return ok and text ~= "" and text or nil
end

-- Inhalt des naechsten Fundobjekts, also der Truhe, die gerade geoeffnet wurde.
describePickup = function()
    local pawn = playerUnit()
    if not pawn then
        return nil
    end
    local origin = pawn:K2_GetActorLocation()
    local nearest, nearestDistance = nil, PICKUP_MAX_DISTANCE
    for _, item in ipairs(FindAllOf("CPP_MapGimmick_ItemObjectBase") or {}) do
        if item:IsValid() then
            local distance = distance2D(item:K2_GetActorLocation(), origin)
            if distance < nearestDistance then
                nearest, nearestDistance = item, distance
            end
        end
    end
    if not nearest then
        return nil
    end
    local parts = {}
    local name = textOf(callFunction(nearest, "GetItemName"))
    if name then
        local count = nearest.m_ItemNum
        table.insert(parts, type(count) == "number" and count > 1 and (count .. " mal " .. name) or name)
    end
    if type(nearest.m_Money) == "number" and nearest.m_Money > 0 then
        table.insert(parts, nearest.m_Money .. " Gil")
    end
    log(string.format("Fund %s: Gegenstand %s, Anzahl %s, Geld %s", tostring(objectPath(nearest)),
        tostring(nearest.m_ItemId), tostring(nearest.m_ItemNum), tostring(nearest.m_Money)))
    return #parts > 0 and table.concat(parts, ", ") or nil
end

-- Leere Bedingungen gelten als erfuellt, nicht auswertbare auch: lieber ein Ziel zu viel als eines zu wenig.
local function conditionMet(condition)
    local ok, met = pcall(function()
        local text = condition:ToString()
        if text == "" then
            return true
        end
        if not conditionFunctions or not conditionFunctions:IsValid() then
            conditionFunctions = StaticFindObject("/Script/mucha.Default__CPP_BFL_Condition")
        end
        return conditionFunctions:IsMeetCondition(text, false)
    end)
    return not ok or met ~= false
end

local function isExitUsable(trigger)
    local ok, usable = pcall(function()
        if trigger.m_IsEventOnly then
            return false
        end
        -- pOpenDoor und m_Condition bleiben ungeprueft: Der Hausausgang C_15 fiel wegen pOpenDoor weg,
        -- C_13 (Log 23:09) galt als gesperrt und liess sich doch benutzen. Doppelte: navRoute.exitTargets.
        return true
    end)
    return not ok or usable
end

-- Der Ergebnisparameter ist je nach UE4SS-Stand direkt die Struktur oder ein Feld darin.
local function mapNameById(mapId)
    if type(mapId) ~= "number" or mapId <= 0 then
        return nil
    end
    if mapNames[mapId] == nil then
        local ok, name = pcall(function()
            if not mapFunctions or not mapFunctions:IsValid() then
                mapFunctions = StaticFindObject("/Script/mucha.Default__CPP_BFL_Map")
            end
            local result = {}
            mapFunctions:GetMapData(mapId, result)
            return textOf(result.Name) or (result.outMapData and textOf(result.outMapData.Name))
        end)
        mapNames[mapId] = ok and name or false
        log("Karte " .. mapId .. ": " .. tostring(name))
    end
    return mapNames[mapId] or nil
end

-- Die Punktnamen gibt es im Spiel nur japanisch und ohne deutsche Fassung, namen_spiel.txt uebersetzt sie.
-- Ohne Uebersetzung bleibt der Punkt unbenannt; viele sind Entwicklertexte wie "C04_409_01後のポイント".
function menuInfo.pointLabel(text)
    if not text then
        return nil
    end
    local translated = npcNames["Punkt " .. text]
    if translated then
        return translated
    end
    return not text:find("[\227-\233][\128-\191][\128-\191]") and not text:find("_", 1, true) and text or nil
end

local function transitionPointNames()
    local names = {}
    for _, point in ipairs(FindAllOf("CPP_MapTransitionPoint") or {}) do
        if point:IsValid() and type(point.m_PointID) == "number" then
            names[point.m_PointID] = menuInfo.pointLabel(textOf(point.m_PointName))
        end
    end
    return names
end

-- Punkt-IDs gelten je Karte: Ein Punkt der aktuellen Karte passt nur zu Uebergaengen, die in ihr bleiben.
function menuInfo.isSameMap(trigger, mapId)
    local ok, current = pcall(function()
        if not mapFunctions or not mapFunctions:IsValid() then
            mapFunctions = StaticFindObject("/Script/mucha.Default__CPP_BFL_Map")
        end
        return mapFunctions:GetCurrentMapId()
    end)
    if trigger.m_IsSameMapTrasition == true then
        return true
    end
    return ok and type(current) == "number" and mapId == current
end

-- GetMapName kennt nur das feste Ziel; Ausgaenge mit Bedingungen stehen in der Liste, das erste gueltige zaehlt.
local function exitTargetName(trigger, pointNames)
    local name = textOf(callFunction(trigger, "GetMapName"))
    local mapId, pointId = trigger.m_MapId, trigger.m_PointID
    local listed = false
    pcall(function()
        trigger.mTransitionDataList:ForEach(function(_, element)
            local data = element:get()
            if not listed and conditionMet(data.FlagCondition) then
                listed = true
                mapId, pointId = data.mapId, data.pointId
            end
        end)
    end)
    -- Innerhalb der Karte sagt der Zielpunkt mehr als der Kartenname, den GetMapName dort liefert.
    if menuInfo.isSameMap(trigger, mapId) and pointNames[pointId] then
        return pointNames[pointId]
    end
    return name or mapNameById(mapId) or nil
end

-- Zielkarte eines Ausgangs, nach derselben Regel wie exitTargetName.
function menuInfo.exitTargetMap(trigger)
    local mapId, listed = trigger.m_MapId, false
    pcall(function()
        trigger.mTransitionDataList:ForEach(function(_, element)
            local data = element:get()
            if not listed and conditionMet(data.FlagCondition) then
                listed = true
                mapId = data.mapId
            end
        end)
    end)
    return mapId
end

-- Zielnamen der Ausgaenge und der Tueren, die zu ihnen fuehren, nach Objektpfad.
local function exitNames()
    local names = {}
    local pointNames = transitionPointNames()
    for _, trigger in ipairs(FindAllOf("CPP_MapTransitionTrigger") or {}) do
        local name = trigger:IsValid() and exitTargetName(trigger, pointNames)
        if name then
            names[objectPath(trigger)] = name
            local door = trigger.pOpenDoor
            if door and door:IsValid() then
                names[objectPath(door)] = name
            end
        end
    end
    return names
end

local function transitionPointName(actor)
    local name = nil
    pcall(function()
        actor.m_TransitionDataList:ForEach(function(_, element)
            name = name or menuInfo.pointLabel(textOf(element:get().pTransitionPoint.m_PointName))
        end)
    end)
    return name
end

-- Diagnose: Den Wert selbst gibt es nicht zu lesen, die Bedingung laesst ihn aber per Halbierung ermitteln.
function menuInfo.progressValue(id)
    local low, high = 0, 4096
    while low < high do
        local middle = (low + high) // 2
        if conditionFunctions:IsMeetCondition("{progress:" .. id .. "}<=" .. middle, false) then
            high = middle
        else
            low = middle + 1
        end
    end
    return low
end

local function isEventTriggerActive(actor)
    local active = false
    local eventIds = {}
    local ok = pcall(function()
        actor.m_EventList:ForEach(function(_, element)
            local event = element:get()
            local met = conditionMet(event.Condition)
            active = active or met
            local text = tostring(textOf(event.Condition))
            local progressId = text:match("{progress:(%d+)}")
            table.insert(eventIds, event.EventId:ToString() .. " [" .. text .. "]"
                .. (progressId and (" Fortschritt " .. menuInfo.progressValue(progressId)) or "")
                .. (met and "" or " (inaktiv)"))
        end)
    end)
    local visible = conditionMet(actor.m_FlagCondition) and conditionMet(actor.VisibleCondition)
    log("Ereignis " .. tostring(objectPath(actor)) .. ": " .. table.concat(eventIds, ", ") .. ", sichtbar " .. tostring(visible))
    return not ok or (active and visible)
end

local function npcNamesPath()
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local scriptsDir = info and info.source and info.source:match("^@(.*[\\/])")
    return scriptsDir and (scriptsDir .. NPC_NAMES_FILE) or nil
end

-- Erst die Sprechernamen aus den Spieldaten (namen_spiel.txt), dann die mitgelieferten, die beim Spielen
-- gelernt wurden (namen_gelernt.txt), zuletzt die eigenen im Gespraech gemerkten.
local function loadNpcNames()
    local path = npcNamesPath()
    if not path then
        return
    end
    local files = {
        (path:gsub(NPC_NAMES_FILE .. "$", "namen_spiel.txt")),
        (path:gsub(NPC_NAMES_FILE .. "$", "namen_gelernt.txt")),
        path,
    }
    for _, filePath in ipairs(files) do
        local file = io.open(filePath, "r")
        if file then
            for line in file:lines() do
                local key, name = line:match("^(.-)\t(.+)$")
                if key then
                    npcNames[key] = name
                end
            end
            file:close()
        end
    end
    log("Namen geladen")
end

-- Das Spiel gibt Kartenfiguren keinen lesbaren Namen, erst der Sprecher im Gespraech verraet ihn.
-- Gemerkt wird er nur fuer diese Figur: m_MapUnitId ist das Aussehen, nicht der Name.
-- Gespeichert wird der Schluessel der Namenstabelle, damit der Name auch in anderen Spielsprachen stimmt;
-- nur wenn das Spiel den Namen nicht in seinen Tabellen hat, der Text selbst.
local function rememberNpcName(key, name)
    if npcNames[key] == name then
        return
    end
    local value = menuInfo.nameRef(name) or name
    npcNames[key] = value
    local path = npcNamesPath()
    local file = path and io.open(path, "a")
    if file then
        file:write(key .. "\t" .. value .. "\n")
        file:close()
    end
    log("Name gemerkt: " .. key .. " = " .. name .. " (" .. value .. ")")
end

-- Der Name kommt aus dem Sprecherfeld des Fensters; aus der Zeile geraten wuerde bei Zeilen ohne Sprecher
-- der Satzanfang zum Namen.
function menuInfo.speakerOf(window)
    local nameWidget = window and menuInfo.findNamedWidget(window, "Text_Name", 0)
    if not nameWidget then
        if not menuInfo.speakerFieldMissingLogged then
            menuInfo.speakerFieldMissingLogged = true
            log("Sprecherfeld fehlt in " .. (window and shortClassName(window) or "?"))
        end
        return nil
    end
    if isHidden(nameWidget) then
        return nil
    end
    local name = widgetText(nameWidget)
    return name and name:match("^%s*(.-)%s*$") or nil
end

-- Diagnose: warum kein Name gemerkt wurde, je Grund einmal.
menuInfo.learnLogged = {}
function menuInfo.logLearn(reason)
    if not menuInfo.learnLogged[reason] then
        menuInfo.learnLogged[reason] = true
        log("Name nicht gemerkt: " .. reason)
    end
end

local function learnNpcName(talkLine, window)
    local speaker = menuInfo.speakerOf(window)
    if not speaker or speaker == "" or #speaker > 40 or NON_NPC_SPEAKERS[speaker] or speaker:find("？")
            or menuInfo.isPartySpeaker(speaker) then
        menuInfo.logLearn("kein Sprecher (" .. tostring(speaker) .. ") in " .. (window and shortClassName(window) or "?"))
        return
    end
    local pawn = playerUnit()
    local npc = pawn and pawn.m_pInteractMapUnit
    local source = "m_pInteractMapUnit"
    if not npc or not npc:IsValid() then
        -- Waehrend des Gespraechs kann der Zeiger schon geleert sein; die Liste in Reichweite bleibt.
        npc, source = nil, "m_InteractMapUnitList"
        pcall(function()
            pawn.m_InteractMapUnitList:ForEach(function(_, unit)
                local value = unit:get()
                if not npc and value and value:IsValid() then
                    npc = value
                end
            end)
        end)
    end
    if not npc or not npc:IsValid() or type(npc.m_MapUnitId) ~= "number" then
        menuInfo.logLearn(speaker .. ": keine Figur in Reichweite (" .. source .. ")")
        return
    end
    rememberNpcName(objectPath(npc), speaker)
end

onTalkLine = function(talkLine, window)
    local ok, err = pcall(learnNpcName, talkLine, window)
    if not ok then
        log("Name merken fehlgeschlagen: " .. tostring(err))
    end
end

-- Karten eines Gebiets teilen sich sameMapId (Stadtteile melden sich mal mit der einen, mal mit der anderen ID).
function menuInfo.mapGroup(mapId)
    local ok, group = pcall(function()
        local result = {}
        menuInfo.defaultObject("CPP_BFL_Map"):GetMapData(mapId, result)
        return result.outMapData.sameMapId
    end)
    return ok and type(group) == "number" and group > 0 and group or mapId
end

-- Annehmbare Auftraege, wie sie das Spiel fuer das Auftragssymbol fuehrt: m_UniqueId des Auftraggebers auf der
-- aktuellen Karte, dazu die erwartete Figur (-1 = beliebig), weil IDs nur je Karte gelten.
function menuInfo.requestGivers()
    local givers = {}
    local titles = {}
    local ok, err = pcall(function()
        local currentGroup = menuInfo.mapGroup(menuInfo.defaultObject("CPP_BFL_Map"):GetCurrentMapId())
        local function addGiver(giver, unitId)
            if giver and giver.Data.Type == 1 and giver.mapId > 0 and menuInfo.mapGroup(giver.mapId) == currentGroup then
                givers[giver.Data.ID] = unitId
            end
        end
        -- Rueckgabewerte kommen als Lua-Tabelle, Felder im Spielspeicher als TArray. RequesterId war am 05.11.
        -- in den Tabellenelementen nil: Elemente evtl. noch verpackt, daher get() versuchen.
        local function each(list, callback)
            if list == nil then
                return
            elseif type(list) == "table" then
                for _, value in ipairs(list) do
                    if type(value) == "userdata" then
                        local ok, unwrapped = pcall(function()
                            return value:get()
                        end)
                        value = ok and unwrapped ~= nil and unwrapped or value
                    end
                    callback(value)
                end
            else
                list:ForEach(function(_, element)
                    callback(element:get())
                end)
            end
        end
        local list = menuInfo.defaultObject("CPP_BFL_Request"):GetAcceptableRequestList()
        if menuInfo.requestListType == nil then
            menuInfo.requestListType = type(list)
            log("Auftragsliste: " .. type(list) .. " " .. tostring(list))
        end
        each(list, function(request)
            if not menuInfo.requestElementLogged then
                menuInfo.requestElementLogged = true
                local keys = {}
                if type(request) == "table" then
                    for key in pairs(request) do
                        table.insert(keys, tostring(key))
                    end
                end
                log("Auftrag Element: " .. type(request) .. " " .. tostring(request) .. ", Felder " .. table.concat(keys, " ")
                    .. ", RequesterId " .. tostring(request.RequesterId) .. ", ID " .. tostring(request.ID))
            end
            addGiver(request.RequesterId, request.RequesterMapUnitId)
            each(request.SubRequesterIds, function(subGiver)
                addGiver(subGiver, -1)
            end)
            table.insert(titles, tostring(request.ID) .. " " .. tostring(textOf(request.Name)))
        end)
    end)
    local summary = ok and table.concat(titles, "; ") or ("fehlgeschlagen: " .. tostring(err))
    if summary ~= menuInfo.requestLogged then
        menuInfo.requestLogged = summary
        log("Auftraege annehmbar: " .. summary)
    end
    return givers
end

function menuInfo.isRequestGiver(actor, givers)
    local ok, matches = pcall(function()
        local unitId = givers[actor.m_UniqueId]
        return unitId ~= nil and (unitId < 0 or unitId == actor.m_MapUnitId)
    end)
    return ok and matches
end

-- Angesagt werden nur Woerter aus dem Spiel. Die internen Bezeichnungen (INTERACT_TYPES, TARGET_SOURCES) bleiben
-- Schluessel fuer Kategorien und Sortierung. Hauptwoerter: ST_UI_Word TreasureChest, ST_UI_Guide SAVEPOINT_en,
-- INN_en, SHOP_en, COLOSSEUM_en, VISIONUPGRADE_en, ST_UI_QuestMenu QuestGoal. Alles andere bekommt das Aktionswort,
-- das das Spiel am Objekt zeigt (FindInteractActionText), sonst das passende aus ST_UI_Interact.
-- Wie der Eintrag im Hauptmenue; zeigt die aktuellen Ziele aller angenommenen Auftraege.
menuInfo.REQUEST_CATEGORY = TARGET_CATEGORIES[2]

menuInfo.GAME_WORDS = {
    Schatztruhe = "Schatztruhe", Speicherpunkt = "Speicherpunkt", Gasthaus = "Gasthaus", Kolosseum = "Kolosseum",
    Laden = "Laden", Waffenladen = "Laden", ["Rüstungsladen"] = "Laden", Accessoireladen = "Laden",
    Chocoboladen = "Laden", Musikladen = "Laden", Visionsladen = "Visionsverbesserung", Ziel = "Ziel",
}
-- ST_UI_Interact: type_0001 Sprechen, type_0003 Oeffnen, type_0004 Weiter, type_0006 Kaempfen.
menuInfo.ACTION_FALLBACK = {
    Person = "Sprechen", Personengruppe = "Sprechen", ["Gesprächspunkt"] = "Sprechen", ["Tür"] = "Öffnen",
    Ausgang = "Weiter", Stadt = "Weiter", Dungeon = "Weiter", Wahrzeichen = "Weiter", Begegnungsgebiet = "Kämpfen",
    Kampf = "Kämpfen", Handelsschiff = "Mit Handelsschiff reden",
}
menuInfo.actionWords = {}

function menuInfo.actionWord(objectType, interactType)
    local key = tostring(objectType) .. ":" .. tostring(interactType)
    if menuInfo.actionWords[key] == nil then
        local ok, text = pcall(function()
            return textOf(StaticFindObject("/Script/mucha.Default__CPP_VM_ObjectInteract"):FindInteractActionText(objectType, interactType))
        end)
        menuInfo.actionWords[key] = ok and text or false
        log("Aktionswort " .. key .. ": " .. tostring(text))
    end
    return menuInfo.actionWords[key] or nil
end

function menuInfo.displayLabel(label, actor, objectType)
    if menuInfo.GAME_WORDS[label] then
        return menuInfo.GAME_WORDS[label]
    end
    local interactType = actor and interactTypeOf(actor)
    local word = interactType and menuInfo.actionWord(objectType or 2, interactType)
    return word or menuInfo.ACTION_FALLBACK[label] or label
end

local function targetLabel(actor, source, info, path)
    local label = info and info[2] or QUEST_CATEGORY
    if source[1] == "CPP_MapUnit_NPC" then
        return npcNames[path] or menuInfo.displayLabel(label, actor, 1)
    end
    -- Wahrzeichen der Weltkarte haengen an dem Ausgang, den sie markieren.
    if label == "Wahrzeichen" then
        local ok, name = pcall(function()
            local trigger = actor.TransitionTrigger
            return trigger:IsValid() and exitTargetName(trigger, {})
        end)
        if ok and name then
            return name
        end
    end
    if label == QUEST_CATEGORY or source[1] == "CPP_MapGimmick_EventTrigger" then
        return label
    end
    return menuInfo.displayLabel(label, actor, source[1] == "CPP_MapTransitionTrigger" and 3 or 2)
end

-- Die Questdaten gelten nur waehrend des Aufrufs, sie liegen direkt in der TMap.
local function withCurrentQuest(callback)
    local subsystem = FindFirstOf("CPP_QuestSubsystem")
    if not subsystem or not subsystem:IsValid() then
        return
    end
    local questId = subsystem.PreferredQuestId > 0 and subsystem.PreferredQuestId or subsystem.MainQuestId
    if questId <= 0 then
        return
    end
    subsystem.QuestDataMap:ForEach(function(key, value)
        if key:get() == questId then
            callback(value:get(), questId, subsystem)
        end
    end)
end

local function objectKey(objectType, id)
    return tostring(objectType) .. ":" .. tostring(id)
end

-- Markierte Minikarten-Eintraege und Objektziele der Quest, als Typ und ID.
local function questTargetKeys()
    local keys = {}
    local function addKey(typeData)
        keys[objectKey(typeData.Type, typeData.ID)] = true
    end
    local miniMapOk, miniMapError = pcall(function()
        FindFirstOf("CPP_MiniMapSubsystem").EntryDataMap:ForEach(function(_, value)
            local entry = value:get()
            if entry.bIsMarkedQuestTarget then
                addKey(entry.ObjectData.TypeData)
            end
        end)
    end)
    if not miniMapOk then
        log("Questziele Minikarte fehlgeschlagen: " .. tostring(miniMapError))
    end
    -- Objekt-IDs gelten je Karte: Der Punkt zaehlt nur auf seiner Zielkarte (DestinationKey), sonst nennt die
    -- Ansage die Zielkarte.
    menuInfo.questElsewhere = nil
    local questOk, questError = pcall(withCurrentQuest, function(quest)
        local currentGroup = menuInfo.mapGroup(menuInfo.defaultObject("CPP_BFL_Map"):GetCurrentMapId())
        quest.DestinationList:ForEach(function(_, element)
            local point = element:get()
            local mapId = point.DestinationKey.DestinationId
            local isMap = point.DestinationKey.Type == 0
            local onThisMap = isMap and menuInfo.mapGroup(mapId) == currentGroup
            log("Questpunkt: Typ " .. tostring(point.PointType) .. ", Objekt " .. tostring(point.IsPointToObject)
                .. " " .. objectKey(point.Object.Type, point.Object.ID) .. ", Karte " .. tostring(mapId)
                .. ", hier " .. tostring(onThisMap))
            if onThisMap and point.IsPointToObject and conditionMet(point.Condition) then
                addKey(point.Object)
            elseif isMap and not onThisMap then
                menuInfo.questElsewhere = mapNameById(mapId)
            end
        end)
    end)
    if not questOk then
        log("Questziele Quest fehlgeschlagen: " .. tostring(questError))
    end
    -- Was das Spiel fuer die Hauptgeschichte auf dieser Karte fuehrt, und die Karten, die es als aktuelle Ziele
    -- kennt (Zwischenhalte); Ausgaenge dorthin zaehlen als Questziel.
    local scenarioOk, scenarioError = pcall(function()
        menuInfo.eachValue(menuInfo.defaultObject("CPP_BFL_Scenario"):GetCurrentMainScenarioMapObjectList(), function(typeData)
            log("Szenario-Objekt: " .. objectKey(typeData.Type, typeData.ID))
            addKey(typeData)
        end)
    end)
    if not scenarioOk then
        log("Szenario-Objekte fehlgeschlagen: " .. tostring(scenarioError))
    end
    menuInfo.questMaps = {}
    local mapsOk, mapsError = pcall(function()
        local current = menuInfo.defaultObject("CPP_BFL_Map"):GetCurrentMapId()
        local currentGroup = menuInfo.mapGroup(current)
        menuInfo.eachValue(menuInfo.defaultObject("CPP_BFL_Scenario"):GetCurrentDestinationMapList(), function(mapId)
            log("Zielkarte: " .. tostring(mapId) .. " " .. tostring(mapNameById(mapId)))
            if type(mapId) == "number" and menuInfo.mapGroup(mapId) ~= currentGroup then
                menuInfo.questMaps[mapId] = true
            end
        end)
    end)
    if not mapsOk then
        log("Zielkarten fehlgeschlagen: " .. tostring(mapsError))
    end
    for key in pairs(keys) do
        log("Questziel gesucht: " .. key)
    end
    return keys
end

-- Liefert den passenden Schluessel. m_MapUnitId ist nur das Aussehen und taugt nicht zum Abgleich.
local function questTargetKey(actor, keys, sourceClass)
    local function matching(objectType, id)
        local key = type(id) == "number" and objectKey(objectType, id)
        return key and keys[key] and key or nil
    end
    local ok, key = pcall(function()
        if sourceClass == "CPP_MapUnit_NPC" then
            return matching(1, actor.m_UniqueId)
        elseif sourceClass == "CPP_MapTransitionPoint" then
            return matching(3, actor.m_PointID)
        end
        return matching(actor.m_MapObjectType, actor.m_UniqueId)
    end)
    if ok and key then
        return key
    end
    local typeDataOk, typeDataKey = pcall(function()
        return matching(actor.TypeData.Type, actor.TypeData.ID)
    end)
    return typeDataOk and typeDataKey or nil
end

local function exitLabel(label, name, actor, categoryName)
    if categoryName ~= "Ausgänge" then
        return label
    end
    -- Nur der Kartenname aus dem Spiel, ohne eigene Zusaetze wie "Ausgang nach".
    return name or transitionPointName(actor) or label
end

-- Liefert die Ziele einer Kategorie, das naechste zuerst.
-- Nur der Zustand im Spiel zaehlt, die Mod merkt sich nichts: geoeffnet (m_IsOpen, Truhen und Fundstuecke wie
-- Medaillen mit Typ Check) oder die Flag-Bedingung des Objekts gilt nicht mehr (Topf: !{flag:914}).
local function isOpenedItem(actor, interactType)
    local ok, opened = pcall(function()
        return actor.m_IsOpen
    end)
    if ok and opened == true then
        return true
    end
    local flagOk, flagCondition = pcall(function()
        return actor.m_FlagCondition
    end)
    return flagOk and flagCondition ~= nil and not conditionMet(flagCondition)
end

-- Eine geoeffnete Truhe steht noch da, sie ist nur leer; aufgehobene Fundstuecke sind weg.
local function isEmptyChest(actor, path)
    local ok, opened = pcall(function()
        return actor.m_IsOpen
    end)
    return ok and opened == true and path:find("TreasureBox", 1, true) ~= nil
end

local scanTargets
scanTargets = function(categoryName, origin)
    if categoryName == menuInfo.REQUEST_CATEGORY then
        return menuInfo.requestTargets(origin)
    end
    local targets = {}
    local seen = {}
    local questKeys = categoryName == QUEST_CATEGORY and questTargetKeys() or nil
    local sortsDoors = categoryName == "Ausgänge" or categoryName == "Türen"
    local exits = sortsDoors and exitNames() or {}
    local requestGivers = (categoryName == "Personen" or questKeys) and menuInfo.requestGivers() or {}
    local foundKeys = {}
    local sources = { table.unpack(TARGET_SOURCES) }
    if questKeys then
        table.insert(sources, { "CPP_MapTransitionPoint", nil })
    end
    for _, source in ipairs(sources) do
        for _, actor in ipairs(FindAllOf(source[1]) or {}) do
            local path = actor:IsValid() and objectPath(actor)
            if path and not seen[path] then
                seen[path] = true
                local interactType = interactTypeOf(actor)
                local info = interactType and INTERACT_TYPES[interactType] or source[2]
                if not info and interactType then
                    info = { "Objekte", "Objekt" }
                end
                -- Tueren ohne Zielangabe fuehren nur innerhalb der Karte weiter und sind keine Ausgaenge.
                if sortsDoors and info and info[2] == "Tür" then
                    local hasTarget = exits[path] or transitionPointName(actor)
                    info = { hasTarget and "Ausgänge" or "Türen", "Tür" }
                end
                local matches = false
                if questKeys then
                    local key = isSelectable(actor) and questTargetKey(actor, questKeys, source[1])
                    if key then
                        foundKeys[key] = true
                        matches = true
                    elseif source[1] == "CPP_MapTransitionTrigger" and isExitUsable(actor) then
                        local mapOk, mapId = pcall(menuInfo.exitTargetMap, actor)
                        matches = mapOk and menuInfo.questMaps[mapId] == true
                    end
                elseif info and info[1] == categoryName then
                    matches = source[3] or isSelectable(actor)
                    if matches and source[1] == "CPP_MapTransitionTrigger" then
                        matches = isExitUsable(actor)
                    elseif matches and (source[1] == "CPP_MapGimmick_InteractEventTrigger"
                        or source[1] == "CPP_MapGimmick_EventTrigger") then
                        matches = isEventTriggerActive(actor)
                    end
                end
                local emptyChest = matches and isEmptyChest(actor, path)
                if matches and (emptyChest or not isOpenedItem(actor, interactType)) then
                    local location = menuInfo.interactPoint(actor)
                    local label = exitLabel(targetLabel(actor, source, info, path), exits[path], actor, categoryName)
                    if emptyChest then
                        label = label .. ", leer"
                    end
                    if questKeys and source[1] == "CPP_MapTransitionTrigger" then
                        label = exitTargetName(actor, {}) or label
                    end
                    if source[1] == "CPP_MapUnit_NPC" and menuInfo.isRequestGiver(actor, requestGivers) then
                        label = label .. ", Auftrag"
                    end
                    -- Kartensymbole sind nur der markierte Ort, ihr Interaktionstyp sagt nichts ueber das Ziel.
                    if questKeys and path:find("MapIconPoint", 1, true) then
                        label = "Ziel"
                    end
                    table.insert(targets, {
                        actor = actor,
                        path = path,
                        label = label,
                        location = { X = location.X, Y = location.Y, Z = location.Z },
                        distance = distance2D(location, origin),
                    })
                end
            end
        end
    end
    for key in pairs(questKeys or {}) do
        if not foundKeys[key] then
            log("Questziel ohne Objekt: " .. key)
        end
    end
    -- Auch Uebergaenge tragen Story-Ereignisse, etwa der Sprung zur Sirene im Turm (C01_036_01 an
    -- BP_MapTransitionTrigger_C_1, {progress:0}==1230). Aktiv heisst: ein Eintrag in m_EventList ist erfuellt.
    if categoryName == "Story-Ereignisse" then
        for _, trigger in ipairs(FindAllOf("CPP_MapTransitionTrigger") or {}) do
            local path = trigger:IsValid() and objectPath(trigger)
            local hasEvents = path and pcall(function()
                return trigger.m_EventList:GetArrayNum() > 0 or error("leer")
            end)
            if hasEvents and isEventTriggerActive(trigger) then
                local location = trigger:K2_GetActorLocation()
                table.insert(targets, {
                    actor = trigger,
                    path = path,
                    label = "Story-Ereignis",
                    location = { X = location.X, Y = location.Y, Z = location.Z },
                    distance = distance2D(location, origin),
                })
            end
        end
    end
    -- Ist auf dieser Karte nichts markiert, fuehren meist die aktiven Story-Ereignisse weiter.
    if questKeys and #targets == 0 then
        log("Questziel: nichts markiert, nehme Story-Ereignisse")
        return scanTargets("Story-Ereignisse", origin)
    end
    table.sort(targets, function(a, b)
        return a.distance < b.distance
    end)
    return targets
end

-- Kartennetz aus den Spieldaten (research\extract\build_kartennetz.py): je Zeile Karte und Zielkarte eines
-- Ausgangs. Gespeichert wird rueckwaerts, die Suche laeuft von der Zielkarte aus.
function menuInfo.mapLinksTo()
    if menuInfo.mapLinks then
        return menuInfo.mapLinks
    end
    menuInfo.mapLinks = {}
    local path = npcNamesPath()
    local file = path and io.open((path:gsub(NPC_NAMES_FILE .. "$", "karte_netz.txt")), "r")
    local count = 0
    if file then
        for line in file:lines() do
            local from, to = line:match("^(%d+)\t(%d+)")
            if from then
                from, to = tonumber(from), tonumber(to)
                menuInfo.mapLinks[to] = menuInfo.mapLinks[to] or {}
                menuInfo.mapLinks[to][from] = true
                count = count + 1
            end
        end
        file:close()
    end
    log("Kartennetz: " .. count .. " Verbindungen")
    return menuInfo.mapLinks
end

-- Anzahl Kartenwechsel von jeder Karte bis zur Zielkarte.
function menuInfo.mapSteps(goalMap)
    menuInfo.mapStepCache = menuInfo.mapStepCache or {}
    if menuInfo.mapStepCache[goalMap] then
        return menuInfo.mapStepCache[goalMap]
    end
    local links = menuInfo.mapLinksTo()
    local steps, queue, head = { [goalMap] = 0 }, { goalMap }, 1
    while queue[head] do
        local mapId = queue[head]
        head = head + 1
        for from in pairs(links[mapId] or {}) do
            if not steps[from] then
                steps[from] = steps[mapId] + 1
                queue[#queue + 1] = from
            end
        end
    end
    menuInfo.mapStepCache[goalMap] = steps
    return steps
end

-- Aktuelle Ziele aller laufenden Auftraege, wie sie die Auftragshilfe zeigt: Quests ausser der Hauptgeschichte
-- (EQuestCategory Main = 1), begonnen oder laufend (EQuestProgression 1, 2), Punkte mit erfuellter Bedingung.
function menuInfo.requestDestinations()
    local destinations, summary = {}, {}
    local subsystem = FindFirstOf("CPP_QuestSubsystem")
    if not subsystem or not subsystem:IsValid() then
        return destinations
    end
    subsystem.QuestDataMap:ForEach(function(key, value)
        local quest = value:get()
        local questId, category, progression = key:get(), quest.Category, quest.Progression
        local name = textOf(quest.Name) or tostring(questId)
        if category == 1 or (progression ~= 1 and progression ~= 2) then
            if progression == 1 or progression == 2 then
                table.insert(summary, string.format("%d %s (Kategorie %s, Stand %s) nicht dabei", questId, name,
                    tostring(category), tostring(progression)))
            end
            return
        end
        quest.DestinationList:ForEach(function(_, element)
            local point = element:get()
            local isMap = point.DestinationKey.Type == 0
            local met = conditionMet(point.Condition)
            table.insert(summary, string.format("%d %s (Kategorie %s, Stand %s): Typ %s, Ziel %s:%s, Objekt %s %s, erfuellt %s",
                questId, name, tostring(category), tostring(progression), tostring(point.PointType),
                tostring(point.DestinationKey.Type), tostring(point.DestinationKey.DestinationId),
                tostring(point.IsPointToObject), objectKey(point.Object.Type, point.Object.ID), tostring(met)))
            if met and isMap then
                table.insert(destinations, {
                    questId = questId,
                    name = name,
                    mapId = point.DestinationKey.DestinationId,
                    object = point.IsPointToObject and objectKey(point.Object.Type, point.Object.ID) or nil,
                })
            end
        end)
    end)
    local text = table.concat(summary, " | ")
    if text ~= menuInfo.requestSummary then
        menuInfo.requestSummary = text
        log("Auftragsziele: " .. (text ~= "" and text or "keine"))
    end
    return destinations
end

-- Kategorie Auftraege: Ziele auf dieser Karte direkt, sonst der Ausgang, der am schnellsten zur Zielkarte fuehrt.
function menuInfo.requestTargets(origin)
    local byPath, targets = {}, {}
    local function add(actor, path, label, destination)
        local known = byPath[path]
        if known then
            known.label = known.label .. ", " .. destination.name
            known.questIds[destination.questId] = true
            return
        end
        local location = menuInfo.interactPoint(actor)
        byPath[path] = {
            actor = actor,
            path = path,
            label = label,
            questIds = { [destination.questId] = true },
            location = { X = location.X, Y = location.Y, Z = location.Z },
            distance = distance2D(location, origin),
        }
        table.insert(targets, byPath[path])
    end
    local ok, destinations = pcall(menuInfo.requestDestinations)
    if not ok then
        log("Auftragsziele fehlgeschlagen: " .. tostring(destinations))
        return targets
    end
    local currentMap = menuInfo.defaultObject("CPP_BFL_Map"):GetCurrentMapId()
    local currentGroup = menuInfo.mapGroup(currentMap)
    local here, away = {}, {}
    for _, destination in ipairs(destinations) do
        if menuInfo.mapGroup(destination.mapId) ~= currentGroup then
            table.insert(away, destination)
        elseif destination.object then
            here[destination.object] = destination
        else
            log("Auftragsziel ohne Objekt: " .. destination.name .. ", Karte " .. tostring(destination.mapId))
        end
    end
    if next(here) then
        local seen = {}
        local sources = { table.unpack(TARGET_SOURCES) }
        table.insert(sources, { "CPP_MapTransitionPoint", nil })
        for _, source in ipairs(sources) do
            for _, actor in ipairs(FindAllOf(source[1]) or {}) do
                local path = actor:IsValid() and objectPath(actor)
                if path and not seen[path] then
                    seen[path] = true
                    local key = isSelectable(actor) and questTargetKey(actor, here, source[1])
                    if key then
                        local interactType = interactTypeOf(actor)
                        local info = interactType and INTERACT_TYPES[interactType] or source[2]
                        local label = targetLabel(actor, source, info, path)
                        if label == QUEST_CATEGORY or path:find("MapIconPoint", 1, true) then
                            label = "Ziel"
                        end
                        add(actor, path, label .. ", " .. here[key].name, here[key])
                    end
                end
            end
        end
    end
    for _, destination in ipairs(away) do
        local steps = menuInfo.mapSteps(destination.mapId)
        local best, bestSteps = {}, math.huge
        for _, trigger in ipairs(FindAllOf("CPP_MapTransitionTrigger") or {}) do
            if trigger:IsValid() and isExitUsable(trigger) then
                local mapOk, mapId = pcall(menuInfo.exitTargetMap, trigger)
                local count = mapOk and not menuInfo.isSameMap(trigger, mapId) and steps[mapId]
                if count and count < bestSteps then
                    best, bestSteps = { trigger }, count
                elseif count and count == bestSteps then
                    table.insert(best, trigger)
                end
            end
        end
        local goalName = mapNameById(destination.mapId)
        if #best == 0 then
            log("Auftrag ohne Ausgang: " .. destination.name .. ", Karte " .. tostring(destination.mapId))
        end
        for _, trigger in ipairs(best) do
            local name = exitTargetName(trigger, {}) or menuInfo.displayLabel("Ausgang", trigger, 3)
            local label = name .. ", " .. destination.name
            if goalName and goalName ~= name then
                label = label .. ", Ziel: " .. goalName
            end
            add(trigger, objectPath(trigger), label, destination)
        end
    end
    table.sort(targets, function(a, b)
        return a.distance < b.distance
    end)
    return targets
end

local function fieldText(object, fieldName)
    local ok, value = pcall(function()
        return object[fieldName]
    end)
    return ok and (type(value) .. ":" .. tostring(value)) or "Fehler"
end

local function logActorDiagnostics(actor, origin)
    local parts = { shortClassName(actor), tostring(objectPath(actor)) }
    for _, fieldName in ipairs(DIAGNOSTIC_ACTOR_FIELDS) do
        table.insert(parts, fieldName .. "=" .. fieldText(actor, fieldName))
    end
    local talkOk, talkId = pcall(function()
        return actor.m_TalkData.TalkIdList[1]
    end)
    table.insert(parts, "TalkId=" .. (talkOk and tostring(talkId) or "-"))
    local locationOk, location = pcall(function()
        return actor:K2_GetActorLocation()
    end)
    table.insert(parts, "Meter=" .. (locationOk and tostring(math.floor(distance2D(location, origin) / 100)) or "?"))
    log("  " .. table.concat(parts, " "))
end

local function logMiniMapDiagnostics()
    local subsystem = FindFirstOf("CPP_MiniMapSubsystem")
    if not subsystem or not subsystem:IsValid() then
        log("Minikarte: kein Subsystem")
        return
    end
    local count = 0
    subsystem.EntryDataMap:ForEach(function(key, value)
        count = count + 1
        if count <= DIAGNOSTIC_ACTOR_LIMIT then
            local entry = value:get()
            local objectData = entry.ObjectData
            log(string.format("  Minikarte %s: Questziel %s, Referenz %s", tostring(key:get()),
                fieldText(entry, "bIsMarkedQuestTarget"), fieldText(objectData, "ReferenceActor")))
        end
    end)
    log("Minikarte: " .. count .. " Eintraege")
end

-- Einmal je Karte: zeigt im Log, was die Karte enthaelt und warum Ziele durch die Filter fallen.
local function logTargetDiagnostics(pawn, origin)
    local level = tostring((objectPath(pawn) or ""):match("^(.-):"))
    if level == diagnosedLevel then
        return
    end
    diagnosedLevel = level
    log("Diagnose Karte: " .. level)
    for _, className in ipairs(DIAGNOSTIC_CLASSES) do
        log("  " .. className .. ": " .. #(FindAllOf(className) or {}))
    end
    for _, className in ipairs({ "CPP_MapUnit_NPC", "CPP_MapGimmick", "CPP_MapEncount" }) do
        log("Akteure " .. className .. ":")
        for index, actor in ipairs(FindAllOf(className) or {}) do
            if index > DIAGNOSTIC_ACTOR_LIMIT then
                break
            end
            logActorDiagnostics(actor, origin)
        end
    end
    local ok, err = pcall(logMiniMapDiagnostics)
    if not ok then
        log("Minikarte fehlgeschlagen: " .. tostring(err))
    end
end

local function directionName(origin, location, controller)
    local yaw = controller.PlayerCameraManager:GetCameraRotation().Yaw
    local angle = math.deg(math.atan(location.Y - origin.Y, location.X - origin.X)) - yaw
    local sector = math.floor(((angle % 360) + 22.5) / 45) % 8
    return DIRECTION_NAMES[sector + 1]
end

-- Eigene Wegekarte: Tastet ab der Spielerposition per Kollisionsabfrage alles Begehbare ab, verteilt auf
-- viele Frames, und speichert das Ergebnis je Karte. Abfragen mit dem Kollisionsprofil der Figur, damit
-- auch unsichtbare Waende zaehlen und Ausloeser nicht stoeren.
local navGrid = {
    CELL = 75,
    MAX_RISE = 85,
    MAX_DROP = 85,
    SEAM_OFFSET = 3,
    -- Wie die Figur Stufen ueberwindet: Die Kapsel beginnt ueber dem Boden, ihre Oberkante bleibt auf Kopfhoehe.
    STEP_CLEARANCE = 45,
    -- Schmaler als die Figur, sonst verfehlt das Raster enge Durchgaenge. Haengt sie doch, sperrt blockAhead die Stelle.
    SCAN_RADIUS = 45,
    BUDGET_SECONDS = 0.003,
    -- Die Weltkarte ist um ein Vielfaches groesser als jedes Gebiet.
    SMALL_FIGURE_BUDGET_SECONDS = 0.006,
    SMALL_FIGURE_HEIGHT = 60,
    RETRY_SECONDS = 3,
    BLOCK_RADIUS = 75,
    OBSTACLE_REACH = 120,
    OBSTACLE_WORDS = {
        { "blockingbase", "Sperre" }, { "noentry", "Sperre" }, { "signboard", "Schild" }, { "npc", "Person" },
        { "tree", "Baum" }, { "rock", "Felsen" }, { "stone", "Felsen" }, { "cliff", "Klippe" }, { "fence", "Zaun" },
        { "wall", "Mauer" }, { "bridge", "Brücke" }, { "water", "Wasser" }, { "river", "Fluss" }, { "house", "Haus" },
        { "door", "Tür" }, { "bush", "Gebüsch" }, { "_col", "Geländekante" },
    },
    MAX_NODES = 100000,
    MAX_BLOCK_LOGS = 40,
    PROGRESS_SECONDS = 2,
    PROGRESS_TONE_MS = 220,
    PROGRESS_NOTES = { 262, 294, 330, 392, 440, 523, 587, 659, 784, 880 },
    FINISH_TONES = "523:180,659:180,784:420",
    nextTone = 0,
    CHECK_SECONDS = 0.5,
    GOAL_CELLS = 4,
    GOAL_HEIGHT = 400,
    SMOOTH_STRIDE = 4,
    SMOOTH_MAX = 40,
    DIRECTIONS = { { 1, 0, 2 }, { -1, 0, 1 }, { 0, 1, 4 }, { 0, -1, 3 } },
    COLOR = { R = 0, G = 0, B = 0, A = 0 },
    nodes = {},
    cells = {},
    frontier = {},
    head = 1,
    tail = 0,
    count = 0,
    scannedThisSession = {},
    nextCheck = 0,
}

function navGrid.cellOf(value)
    return math.floor(value / navGrid.CELL + 0.5)
end

function navGrid.nodeKey(ix, iy, z)
    return ix .. ":" .. iy .. ":" .. math.floor(z / 150 + 0.5)
end

function navGrid.prepareTraces(pawn)
    navGrid.pawn = pawn
    navGrid.system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    navGrid.radius, navGrid.halfHeight = navGrid.SCAN_RADIUS, 100
    navGrid.profile = FName("Pawn")
    pcall(function()
        -- Auf der Weltkarte ist die Figur deutlich kleiner als in den Gebieten.
        navGrid.radius = math.min(navGrid.SCAN_RADIUS, pawn.CapsuleComponent:GetScaledCapsuleRadius())
        navGrid.halfHeight = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
        navGrid.profile = pawn.CapsuleComponent:GetCollisionProfileName()
    end)
    navGrid.smallFigure = navGrid.halfHeight < navGrid.SMALL_FIGURE_HEIGHT
    navGrid.ignored = {}
    pcall(function()
        for _, unit in ipairs(FindAllOf("CPP_MapUnit_Playable") or {}) do
            table.insert(navGrid.ignored, unit)
        end
    end)
    -- Beides ist ungeprueft: Ignorierliste aus Lua und das Profil der Figur. Sonst einfachere Abfrage.
    local location = pawn:K2_GetActorLocation()
    local function works()
        local ok, ground = pcall(navGrid.groundBelow, location.X, location.Y, location.Z, location.Z - 1000)
        return ok and ground ~= nil
    end
    if not works() then
        log("Wegekarte: Abfrage mit Ignorierliste geht nicht")
        navGrid.ignored = {}
    end
    if not works() then
        log("Wegekarte: Kollisionsprofil der Figur geht nicht, nehme Pawn")
        navGrid.profile = FName("Pawn")
    end
    navGrid.disabled = not works()
    log("Wegekarte: Abfragen " .. (navGrid.disabled and "gehen nicht" or "bereit") .. string.format(", Radius %.0f, Hoehe %.0f, %d ignoriert",
        navGrid.radius, navGrid.halfHeight, #navGrid.ignored))
end

function navGrid.groundBelow(x, y, top, bottom)
    local hit = {}
    local color = navGrid.COLOR
    local function trace(atX, atY)
        return navGrid.system:LineTraceSingleByProfile(navGrid.pawn, { X = atX, Y = atY, Z = top }, { X = atX, Y = atY, Z = bottom },
            navGrid.profile, false, navGrid.ignored, 0, hit, true, color, color, 0)
    end
    -- Schloss: Die Treppe beginnt genau bei X -39600 auf dem Raster, eine Linie auf der Modellnaht trifft dort nichts.
    local found = trace(x, y) or trace(x + navGrid.SEAM_OFFSET, y + navGrid.SEAM_OFFSET)
    return found and hit.ImpactPoint.Z or nil, hit
end

-- Liefert true, wenn die Figur zwischen den beiden Bodenpunkten frei durchpasst.
function navGrid.sweepFree(fromX, fromY, fromGround, toX, toY, toGround)
    local clearance = math.min(navGrid.STEP_CLEARANCE, navGrid.halfHeight - navGrid.radius / 2)
    local halfHeight = navGrid.halfHeight - clearance / 2
    local lift = clearance + halfHeight
    local color = navGrid.COLOR
    local hit = {}
    local function sweep(radius)
        return navGrid.system:CapsuleTraceSingleByProfile(navGrid.pawn,
            { X = fromX, Y = fromY, Z = fromGround + lift }, { X = toX, Y = toY, Z = toGround + lift },
            radius, halfHeight, navGrid.profile, false, navGrid.ignored, 0, hit, true, color, color, 0)
    end
    local blocked = sweep(navGrid.radius)
    -- Weltkarte: Der Scan endete rund um Mitra nur mit "steckt fest", die Kapsel beruehrte das Gelaende schon am Start
    -- (Log 06:00). Das sagt nichts ueber die Richtung, daher schmaler pruefen; echte Waende treffen auch dann.
    if blocked and navGrid.smallFigure and hit.bStartPenetrating then
        hit = {}
        blocked = sweep(navGrid.radius / 2)
    end
    return not blocked, hit
end

-- Diagnose: Woran endet der Scan? Nur die ersten Stellen je Scan.
function navGrid.logBlocked(node, x, y, ground, hit)
    navGrid.blockLogs = (navGrid.blockLogs or 0) + 1
    if navGrid.blockLogs > navGrid.MAX_BLOCK_LOGS then
        return
    end
    local ok, text = pcall(function()
        if not ground then
            return "kein Boden"
        end
        return string.format("%s, Punkt %.0f %.0f %.0f, steckt fest %s", tostring(objectPath(hit.Component:Get())),
            hit.ImpactPoint.X, hit.ImpactPoint.Y, hit.ImpactPoint.Z, tostring(hit.bStartPenetrating))
    end)
    log(string.format("Wegekarte Grenze %.0f %.0f %.0f nach %.0f %.0f: %s", node.X, node.Y, node.Z, x, y, tostring(text)))
end

function navGrid.addNode(ix, iy, z)
    local key = navGrid.nodeKey(ix, iy, z)
    local node = navGrid.nodes[key]
    if node then
        return node, false
    end
    node = { ix = ix, iy = iy, X = ix * navGrid.CELL, Y = iy * navGrid.CELL, Z = z, links = {}, key = key }
    navGrid.nodes[key] = node
    navGrid.count = navGrid.count + 1
    local cellKey = ix .. ":" .. iy
    navGrid.cells[cellKey] = navGrid.cells[cellKey] or {}
    table.insert(navGrid.cells[cellKey], node)
    return node, true
end

-- Eigener Zaehler: Der Kopf der Warteschlange wird geleert, dort waere die Tabellenlaenge (#) nicht verlaesslich.
function navGrid.push(node)
    navGrid.tail = navGrid.tail + 1
    navGrid.frontier[navGrid.tail] = node
end

function navGrid.expand(node)
    for index, direction in ipairs(navGrid.DIRECTIONS) do
        if node.links[index] == nil then
            local ix, iy = node.ix + direction[1], node.iy + direction[2]
            local x, y = ix * navGrid.CELL, iy * navGrid.CELL
            local ground = navGrid.groundBelow(x, y, node.Z + navGrid.MAX_RISE, node.Z - navGrid.MAX_DROP)
            local free, hit = false, nil
            if ground then
                free, hit = navGrid.sweepFree(node.X, node.Y, node.Z, x, y, ground)
            end
            if free then
                local neighbor, isNew = navGrid.addNode(ix, iy, ground)
                node.links[index] = neighbor
                neighbor.links[direction[3]] = node
                if isNew then
                    navGrid.push(neighbor)
                end
            else
                node.links[index] = false
                navGrid.logBlocked(node, x, y, ground, hit)
            end
        end
    end
end

function navGrid.nearest(location, maxHeight)
    local floorZ = location.Z - (navGrid.halfHeight or 100)
    local baseX, baseY = navGrid.cellOf(location.X), navGrid.cellOf(location.Y)
    local best, bestScore = nil, math.huge
    for ix = baseX - 2, baseX + 2 do
        for iy = baseY - 2, baseY + 2 do
            for _, node in ipairs(navGrid.cells[ix .. ":" .. iy] or {}) do
                local height = math.abs(node.Z - floorZ)
                local score = distance2D(location, node) + height
                if height <= (maxHeight or 150) and score < bestScore then
                    best, bestScore = node, score
                end
            end
        end
    end
    return best
end

-- Startpunkt: naechster Rasterpunkt, den die Figur von ihrer Position aus erreicht.
function navGrid.seed(location)
    local floorZ = navGrid.groundBelow(location.X, location.Y, location.Z, location.Z - navGrid.halfHeight - navGrid.MAX_DROP)
    if not floorZ then
        log("Wegekarte: kein Boden unter der Figur bei " .. math.floor(location.X) .. " " .. math.floor(location.Y))
        return false
    end
    local baseX, baseY = navGrid.cellOf(location.X), navGrid.cellOf(location.Y)
    for ring = 0, 2 do
        for ix = baseX - ring, baseX + ring do
            for iy = baseY - ring, baseY + ring do
                local x, y = ix * navGrid.CELL, iy * navGrid.CELL
                local ground = navGrid.groundBelow(x, y, floorZ + navGrid.MAX_RISE, floorZ - navGrid.MAX_DROP)
                if ground and navGrid.sweepFree(location.X, location.Y, floorZ, x, y, ground) then
                    local node, isNew = navGrid.addNode(ix, iy, ground)
                    if isNew then
                        navGrid.push(node)
                        navGrid.complete = false
                    end
                    return true
                end
            end
        end
    end
    log("Wegekarte: kein freier Startpunkt bei " .. math.floor(location.X) .. " " .. math.floor(location.Y))
    return false
end

function navGrid.filePath(level)
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local scriptsDir = info and info.source and info.source:match("^@(.*[\\/])")
    local name = level:match("([^/%.]+)$") or "karte"
    -- Rasterweite im Namen: Dateien mit anderer Weite passen nicht zur aktuellen Rechnung.
    return scriptsDir and (scriptsDir .. "wege" .. navGrid.CELL .. "_" .. name:gsub("[^%w_]", "_") .. ".txt") or nil
end

function navGrid.save()
    local path = navGrid.filePath(navGrid.level)
    local file = path and io.open(path, "w")
    if not file then
        log("Wegekarte: Speichern nicht moeglich")
        return
    end
    for _, node in pairs(navGrid.nodes) do
        local parts = { node.ix, node.iy, math.floor(node.Z + 0.5) }
        for index = 1, #navGrid.DIRECTIONS do
            local link = node.links[index]
            table.insert(parts, link and math.floor(link.Z + 0.5) or "-")
        end
        file:write(table.concat(parts, " "), "\n")
    end
    file:close()
end

function navGrid.load(level)
    local path = navGrid.filePath(level)
    local file = path and io.open(path, "r")
    if not file then
        return false
    end
    local rows = {}
    for line in file:lines() do
        local ix, iy, z, a, b, c, d = line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
        if ix then
            table.insert(rows, { tonumber(ix), tonumber(iy), tonumber(z), { a, b, c, d } })
        end
    end
    file:close()
    for _, row in ipairs(rows) do
        navGrid.addNode(row[1], row[2], row[3])
    end
    for _, row in ipairs(rows) do
        local node = navGrid.nodes[navGrid.nodeKey(row[1], row[2], row[3])]
        for index, direction in ipairs(navGrid.DIRECTIONS) do
            local linkZ = tonumber(row[4][index])
            local target = linkZ and navGrid.nodes[navGrid.nodeKey(row[1] + direction[1], row[2] + direction[2], linkZ)]
            node.links[index] = target or false
        end
    end
    return #rows > 0
end

-- Fertige Karte aus den Spieldaten (research\extract\build_wege.py), Punkte liegen frei in ihrer Zelle.
function navGrid.loadPrebuilt(level)
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local scriptsDir = info and info.source and info.source:match("^@(.*[\\/])")
    local name = level:match("([^/%.]+)$") or "karte"
    local file = scriptsDir and io.open(scriptsDir .. "karte_" .. name .. ".txt", "r")
    if not file then
        return false
    end
    local rows = {}
    for line in file:lines() do
        local ix, iy, z, a, b, c, d, x, y = line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
        if ix then
            table.insert(rows, { tonumber(ix), tonumber(iy), tonumber(z), { a, b, c, d }, tonumber(x), tonumber(y) })
        end
    end
    file:close()
    for _, row in ipairs(rows) do
        local node = navGrid.addNode(row[1], row[2], row[3])
        node.X, node.Y = row[5], row[6]
    end
    for _, row in ipairs(rows) do
        local node = navGrid.nodes[navGrid.nodeKey(row[1], row[2], row[3])]
        for index, direction in ipairs(navGrid.DIRECTIONS) do
            local linkZ = tonumber(row[4][index])
            local target = linkZ and navGrid.nodes[navGrid.nodeKey(row[1] + direction[1], row[2] + direction[2], linkZ)]
            node.links[index] = target or false
        end
    end
    return #rows > 0
end

function navGrid.reset(level, useFile)
    navGrid.level = level
    navGrid.nodes, navGrid.cells, navGrid.frontier = {}, {}, {}
    navGrid.head, navGrid.tail, navGrid.count, navGrid.complete, navGrid.scanStarted = 1, 0, 0, false, nil
    navGrid.blockLogs = 0
    navGrid.prebuilt = useFile and navGrid.loadPrebuilt(level)
    if navGrid.prebuilt then
        navGrid.fromFile, navGrid.complete, navGrid.announceFinish = false, true, false
        navGrid.scannedThisSession[level] = true
        log("Wegekarte " .. level .. ": fertige Karte, " .. navGrid.count .. " Punkte")
        return
    end
    navGrid.fromFile = useFile and navGrid.load(level)
    navGrid.complete = navGrid.fromFile
    navGrid.announceFinish = not navGrid.fromFile
    navGrid.nextTone = os.clock() + navGrid.PROGRESS_SECONDS
    log("Wegekarte " .. level .. ": " .. (navGrid.fromFile and (navGrid.count .. " Punkte geladen") or "wird erfasst"))
    if not navGrid.fromFile then
        speak("Wegekarte wird erfasst.", false)
    end
end

function navGrid.checkMap()
    local pawn = playerUnit()
    if not pawn then
        navGrid.pawn = nil
        return
    end
    local path = objectPath(pawn) or ""
    local level = path:match("^[^:]+") or ""
    -- Direkt nach einer Szene lieferten die Abfragen keinen Boden (05.11. 21:33), danach blieb die Wegekarte
    -- fuer die ganze Karte aus. Deshalb im ausgeschalteten Zustand regelmaessig neu versuchen.
    local now = os.clock()
    if path ~= navGrid.pawnPath or not navGrid.pawn or (navGrid.disabled and now >= (navGrid.retryAt or 0)) then
        navGrid.pawnPath = path
        navGrid.retryAt = now + navGrid.RETRY_SECONDS
        navGrid.prepareTraces(pawn)
    end
    if navGrid.disabled then
        return
    end
    if level ~= navGrid.level then
        navGrid.reset(level, true)
    end
    local location = pawn:K2_GetActorLocation()
    if not navGrid.prebuilt and not navGrid.nearest(location) then
        navGrid.scanStarted = navGrid.scanStarted or os.clock()
        navGrid.seed(location)
    end
end

function navGrid.finishScan()
    navGrid.complete = true
    navGrid.scannedThisSession[navGrid.level] = true
    log(string.format("Wegekarte fertig: %d Punkte, %.1f s", navGrid.count, os.clock() - (navGrid.scanStarted or os.clock())))
    navGrid.scanStarted = nil
    navGrid.save()
    -- Spaetere Ergaenzungen, etwa nach einem Abstecher neben das Raster, laufen still.
    if navGrid.announceFinish then
        navGrid.announceFinish = false
        navGrid.playTones(navGrid.FINISH_TONES)
        speak("Wegekarte fertig.", false)
    end
end

function navGrid.playTones(notes)
    if speechPipe then
        pcall(function()
            speechPipe:write("T" .. notes .. "\n")
            speechPipe:flush()
        end)
    end
end

-- Die Gesamtgroesse einer Karte ist vor dem Scan unbekannt, Prozent gibt es daher nicht. Stattdessen
-- steigt der Ton mit jeder Verdopplung der erfassten Punkte; Stille heisst fertig oder pausiert.
function navGrid.tickProgress(now)
    if not navGrid.announceFinish or now < navGrid.nextTone then
        return
    end
    local notes = navGrid.PROGRESS_NOTES
    local step = math.floor(math.log(math.max(navGrid.count, 100) / 100, 2)) + 1
    navGrid.playTones(notes[math.min(step, #notes)] .. ":" .. navGrid.PROGRESS_TONE_MS)
    navGrid.nextTone = now + navGrid.PROGRESS_SECONDS
end

-- Laeuft jeden Frame mit festem Zeitbudget; pausiert, solange die Figur gesperrt ist (Szene, Kampf, Menue).
function navGrid.tick()
    local now = os.clock()
    if now >= navGrid.nextCheck then
        navGrid.nextCheck = now + navGrid.CHECK_SECONDS
        navGrid.checkMap()
    end
    if navGrid.disabled or navGrid.complete or not navGrid.pawn or not navGrid.pawn:IsValid()
        or navGrid.pawn.m_IsEnableUnitInput == false then
        return
    end
    navGrid.tickProgress(now)
    local stopAt = now + (navGrid.smallFigure and navGrid.SMALL_FIGURE_BUDGET_SECONDS or navGrid.BUDGET_SECONDS)
    while os.clock() < stopAt do
        local node = navGrid.frontier[navGrid.head]
        if not node then
            if navGrid.head > 1 then
                navGrid.finishScan()
            end
            return
        end
        navGrid.frontier[navGrid.head] = nil
        navGrid.head = navGrid.head + 1
        navGrid.expand(node)
        if navGrid.count >= navGrid.MAX_NODES then
            log("Wegekarte: Obergrenze erreicht")
            navGrid.frontier, navGrid.head, navGrid.tail = {}, 2, 1
        end
    end
end

-- Ein Fehler soll nicht jeden Frame das Log fluten: Scan dann fuer diese Sitzung abschalten.
function navGrid.safeTick()
    if navGrid.failed then
        return
    end
    local ok, err = pcall(navGrid.tick)
    if not ok then
        navGrid.failed = true
        log("Wegekarte abgeschaltet: " .. tostring(err))
    end
end

-- Wandtoene: Prueft rund um die Figur mit denselben Abfragen wie der Scan, ob der Weg frei ist. Die Richtungen gelten
-- relativ zur Kamera wie die Bewegungstasten. Stille heisst frei, je naeher die Wand, desto lauter der Ton.
navGrid.walls = {
    enabled = true,
    -- Anteil nach vorne, Anteil nach rechts, Hertz, Balance, Name
    DIRECTIONS = {
        { 1, 0, 880, 0, "vorne" },
        { 0, -1, 587, -1, "links" },
        { 0, 1, 587, 1, "rechts" },
        { -1, 0, 294, 0, "hinten" },
    },
    VOLUMES = { "1.4", "0.8", "0.45" },
    TONE_MS = 110,
    REPEAT_SECONDS = 1,
    RETRIGGER_SECONDS = 0.6,
    MAX_LOGS = 300,
    logs = 0,
    state = {},
    lastTone = {},
}

-- Liefert die Nummer des Schritts, an dem es nicht weitergeht, und den Grund. Ein Schritt ist so breit wie die Figur.
function navGrid.probeWall(x, y, z, dirX, dirY)
    local step = navGrid.radius * 2
    for index = 1, #navGrid.walls.VOLUMES do
        local toX, toY = x + dirX * step, y + dirY * step
        local ground = navGrid.groundBelow(toX, toY, z + navGrid.MAX_RISE, z - navGrid.MAX_DROP)
        if not ground then
            return index, nil
        end
        local free, hit = navGrid.sweepFree(x, y, z, toX, toY, ground)
        -- Steckt die Kapsel schon am Start im Gelaende, sagt das nichts ueber diese Richtung. bStartPenetrating ist aus
        -- Lua nicht brauchbar: Es las sich im Log auch bei 55 cm freier Strecke als true (Bitfeld), Time ist verlaesslich.
        if not free and (hit.Time or 1) > 0 then
            return index, hit
        end
        x, y, z = toX, toY, ground
    end
    return nil
end

function navGrid.logWall(direction, index, hit, location)
    local walls = navGrid.walls
    walls.logs = walls.logs + 1
    if walls.logs > walls.MAX_LOGS then
        return
    end
    local reason = "kein Boden"
    if hit then
        local ok, names = pcall(function()
            return navGrid.componentNames(hit.Component:Get())
        end)
        reason = ok and names or "unbekannt"
    end
    log(string.format("Wand %s, Schritt %d, bei %.0f %.0f: %s", direction[5], index, location.X, location.Y, reason))
end

function navGrid.tickWalls()
    local walls = navGrid.walls
    local pawn = navGrid.pawn
    local usable = walls.enabled and not navGrid.disabled and pawn and pawn:IsValid() and pawn.m_IsEnableUnitInput ~= false
    local controller = usable and select(2, playerUnit())
    local location = controller and pawn:K2_GetActorLocation()
    local floorZ = location and navGrid.groundBelow(location.X, location.Y, location.Z, location.Z - navGrid.halfHeight - navGrid.MAX_DROP)
    -- Ohne Boden faellt oder springt die Figur gerade. Nach einer Sperre gilt jede Wand wieder als neu.
    if not floorZ then
        walls.state, walls.location = {}, nil
        return
    end
    local moved = walls.location and distance2D(location, walls.location) > navGrid.radius / 4
    walls.location = { X = location.X, Y = location.Y }
    local yaw = math.rad(controller.PlayerCameraManager:GetCameraRotation().Yaw)
    local forwardX, forwardY = math.cos(yaw), math.sin(yaw)
    local rightX, rightY = -forwardY, forwardX
    local now = os.clock()
    local notes = {}
    for key, direction in ipairs(walls.DIRECTIONS) do
        local dirX = forwardX * direction[1] + rightX * direction[2]
        local dirY = forwardY * direction[1] + rightY * direction[2]
        local index, hit = navGrid.probeWall(location.X, location.Y, floorZ, dirX, dirY)
        local isNew = index and not walls.state[key]
        if isNew then
            navGrid.logWall(direction, index, hit, location)
        end
        walls.state[key] = index
        local since = now - (walls.lastTone[key] or -100)
        if index and ((isNew and since >= walls.RETRIGGER_SECONDS) or (moved and since >= walls.REPEAT_SECONDS)) then
            walls.lastTone[key] = now
            table.insert(notes, direction[3] .. ":" .. walls.TONE_MS .. ":" .. direction[4] .. ":" .. walls.VOLUMES[index])
        end
    end
    if #notes > 0 then
        navGrid.playTones(table.concat(notes, ","))
    end
end

function navGrid.toggleWalls()
    local walls = navGrid.walls
    walls.enabled = not walls.enabled
    walls.state, walls.location = {}, nil
    speak(walls.enabled and "Wandtöne an." or "Wandtöne aus.", true)
end

-- Erreichbarkeit ab einem Punkt: fuer jeden Knoten der Vorgaenger auf dem kuerzesten Weg.
function navGrid.flood(start)
    local previous, queue, head = { [start] = start }, { start }, 1
    while queue[head] do
        local node = queue[head]
        head = head + 1
        for index = 1, #navGrid.DIRECTIONS do
            local link = node.links[index]
            if link and not previous[link] then
                previous[link] = node
                queue[#queue + 1] = link
            end
        end
    end
    return previous
end

-- Grosse Ziele wie Ausgangs- und Begegnungsbereiche liegen mit ihrer Mitte oft hinter einer Wand,
-- gelten aber als erreicht, sobald ein begehbarer Punkt in ihrem Bereich liegt.
function navGrid.goalInsideBounds(previous, destination, actor)
    local origin, extent = {}, {}
    actor:GetActorBounds(false, origin, extent, false)
    local best, bestDistance = nil, math.huge
    for node in pairs(previous) do
        if math.abs(node.X - origin.X) <= extent.X and math.abs(node.Y - origin.Y) <= extent.Y
            and math.abs(node.Z - origin.Z) <= extent.Z + navGrid.halfHeight then
            local distance = distance2D(destination, node)
            if distance < bestDistance then
                best, bestDistance = node, distance
            end
        end
    end
    return best
end

function navGrid.chooseGoal(previous, destination, actor)
    local baseX, baseY = navGrid.cellOf(destination.X), navGrid.cellOf(destination.Y)
    local range = navGrid.GOAL_CELLS
    local best, bestScore = nil, math.huge
    for ix = baseX - range, baseX + range do
        for iy = baseY - range, baseY + range do
            for _, node in ipairs(navGrid.cells[ix .. ":" .. iy] or {}) do
                local height = math.abs(node.Z - destination.Z)
                local score = distance2D(destination, node) + height * 0.5
                if previous[node] and height <= navGrid.GOAL_HEIGHT and score < bestScore then
                    best, bestScore = node, score
                end
            end
        end
    end
    if best then
        return best, false
    end
    if actor then
        local ok, inside = pcall(navGrid.goalInsideBounds, previous, destination, actor)
        if ok and inside then
            return inside, false
        end
    end
    for node in pairs(previous) do
        local score = distance2D(destination, node) + math.abs(node.Z - destination.Z) * 0.5
        if score < bestScore then
            best, bestScore = node, score
        end
    end
    return best, true
end

-- Prueft nur vorhandene Kanten: Ist die gerade Linie zwischen zwei Knoten durchgehend begehbar?
function navGrid.lineFree(from, to)
    local current = from
    local steps = math.max(math.abs(to.ix - from.ix), math.abs(to.iy - from.iy)) * 2
    local function step(dx, dy)
        for index, direction in ipairs(navGrid.DIRECTIONS) do
            if direction[1] == dx and direction[2] == dy then
                return current.links[index] or nil
            end
        end
        return nil
    end
    for sample = 1, steps do
        local wantX = from.ix + math.floor((to.ix - from.ix) * sample / steps + 0.5)
        local wantY = from.iy + math.floor((to.iy - from.iy) * sample / steps + 0.5)
        local dx, dy = wantX - current.ix, wantY - current.iy
        if dx ~= 0 and dy ~= 0 then
            local viaX = step(dx, 0)
            local saved = current
            if viaX then
                current = viaX
                local final = step(0, dy)
                if final then
                    current = final
                else
                    current = saved
                    viaX = nil
                end
            end
            if not viaX then
                local viaY = step(0, dy)
                if not viaY then
                    return false
                end
                current = viaY
                local final = step(dx, 0)
                if not final then
                    return false
                end
                current = final
            end
        elseif dx ~= 0 or dy ~= 0 then
            local nextNode = step(dx, dy)
            if not nextNode then
                return false
            end
            current = nextNode
        end
    end
    return current == to
end

function navGrid.smooth(path)
    local result, index = { path[1] }, 1
    while index < #path do
        local reach = index + 1
        local candidate = math.min(index + navGrid.SMOOTH_STRIDE, #path)
        while candidate > reach and candidate - index <= navGrid.SMOOTH_MAX and navGrid.lineFree(path[index], path[candidate]) do
            reach = candidate
            candidate = math.min(candidate + navGrid.SMOOTH_STRIDE, #path)
            if candidate == reach then
                break
            end
        end
        table.insert(result, path[reach])
        index = reach
    end
    return result
end

function navGrid.route(origin, destination, actor)
    local start = navGrid.nearest(origin)
    if not start then
        return nil
    end
    local previous = navGrid.flood(start)
    local goal, partial = navGrid.chooseGoal(previous, destination, actor)
    if not goal then
        return nil
    end
    -- Ein Teilweg, der dem Ziel nicht naeher bringt, ist keiner.
    if partial and distance2D(goal, destination) > distance2D(origin, destination) - navGrid.CELL * 2 then
        return nil
    end
    local reversed, node = {}, goal
    while node ~= start do
        table.insert(reversed, node)
        node = previous[node]
    end
    local path = { start }
    for index = #reversed, 1, -1 do
        table.insert(path, reversed[index])
    end
    local smoothed = navGrid.smooth(path)
    local points, length, last = {}, 0, origin
    for _, point in ipairs(smoothed) do
        table.insert(points, { X = point.X, Y = point.Y, Z = point.Z })
        length = length + distance2D(last, point)
        last = point
    end
    return { points = points, length = length, partial = partial, source = "Wegekarte" }
end

-- Sperrt die Kanten vor der Figur in Laufrichtung, damit die Neuberechnung einen anderen Weg nimmt.
function navGrid.blockAhead(location, point)
    local node = navGrid.nearest(location)
    local length = distance2D(location, point)
    if not node or length <= 0 then
        return
    end
    local toX, toY = (point.X - location.X) / length, (point.Y - location.Y) / length
    for index, direction in ipairs(navGrid.DIRECTIONS) do
        local link = node.links[index]
        if link and direction[1] * toX + direction[2] * toY > 0.5 then
            node.links[index] = false
            link.links[direction[3]] = false
            log("Wegekarte: Kante gesperrt bei " .. node.key)
        end
    end
end

-- Nimmt alle Kanten rund um eine Stelle aus dem Raster; der Punkt der Figur bleibt, sonst faende sie von dort keinen Weg mehr.
-- Das naechste Speichern der Wegekarte uebernimmt die Sperre, ein Neu-Scan hebt sie auf.
function navGrid.blockAround(x, y, keep)
    local blocked = 0
    local baseX, baseY = navGrid.cellOf(x), navGrid.cellOf(y)
    for ix = baseX - 1, baseX + 1 do
        for iy = baseY - 1, baseY + 1 do
            for _, node in ipairs(navGrid.cells[ix .. ":" .. iy] or {}) do
                if node ~= keep and distance2D({ X = x, Y = y }, node) < navGrid.BLOCK_RADIUS then
                    for index, direction in ipairs(navGrid.DIRECTIONS) do
                        local link = node.links[index]
                        if link then
                            node.links[index] = false
                            link.links[direction[3]] = false
                            blocked = blocked + 1
                        end
                    end
                end
            end
        end
    end
    log(string.format("Wegekarte: %d Kanten gesperrt um %.0f %.0f", blocked, x, y))
end

-- Benennt ein Hindernis ueber den Namen seines Modells. Die Woerter sind geraten, bis die Log-Zeilen `Hindernis:` echte Namen zeigen.
function navGrid.obstacleWord(names)
    local text = names:lower()
    for _, entry in ipairs(navGrid.OBSTACLE_WORDS) do
        if text:find(entry[1], 1, true) then
            return entry[2]
        end
    end
    return nil
end

function navGrid.componentNames(component)
    local parts = { tostring(objectPath(component)) }
    pcall(function()
        table.insert(parts, tostring(objectPath(component.StaticMesh)))
    end)
    return table.concat(parts, " ")
end

-- Sucht, was vor der Figur steht: Kapsel fuer die Kollision, dazu eine Sichtlinie, weil das Gelaende der Weltkarte
-- ein einziges unsichtbares Kollisionsmodell ist (Wld_COL) und das Sichtbare davor mehr ueber die Stelle sagt.
function navGrid.identifyObstacle(pawn, location, point)
    local length = distance2D(location, point)
    if length <= 0 then
        return nil
    end
    local dirX, dirY = (point.X - location.X) / length, (point.Y - location.Y) / length
    local reach = navGrid.OBSTACLE_REACH
    local floorZ = location.Z - navGrid.halfHeight
    local free, hit = navGrid.sweepFree(location.X, location.Y, floorZ, location.X + dirX * reach, location.Y + dirY * reach, floorZ)
    local result = {}
    if not free then
        pcall(function()
            result.collision = navGrid.componentNames(hit.Component:Get())
            result.X, result.Y = hit.ImpactPoint.X, hit.ImpactPoint.Y
        end)
    end
    pcall(function()
        local sight, color = {}, navGrid.COLOR
        local eye = { X = location.X, Y = location.Y, Z = location.Z }
        local found = navGrid.system:LineTraceSingle(pawn, eye, { X = eye.X + dirX * reach * 2, Y = eye.Y + dirY * reach * 2, Z = eye.Z },
            0, true, navGrid.ignored, 0, sight, true, color, color, 0)
        if found then
            result.visible = navGrid.componentNames(sight.Component:Get())
            result.X, result.Y = result.X or sight.ImpactPoint.X, result.Y or sight.ImpactPoint.Y
        end
    end)
    log(string.format("Hindernis: bei %.0f %.0f, Kollision %s, sichtbar %s, Stelle %s %s", location.X, location.Y,
        tostring(result.collision), tostring(result.visible), tostring(result.X), tostring(result.Y)))
    local names = (result.visible or "") .. " " .. (result.collision or "")
    result.word = navGrid.obstacleWord(names)
    return result
end

-- Diagnose: Was steht zwischen Figur und Ziel?
function navGrid.logBlocker(location, destination)
    local ok, err = pcall(function()
        local floorZ = location.Z - navGrid.halfHeight
        local free, hit = navGrid.sweepFree(location.X, location.Y, floorZ, destination.X, destination.Y, floorZ)
        local component = not free and hit.Component:Get()
        log("Hindernis Richtung Ziel: " .. (free and "keines gefunden" or (objectPath(component) or "?")))
        for _, gimmick in ipairs(FindAllOf("BP_MapGimmick_NoEntry_C") or {}) do
            local position = gimmick:K2_GetActorLocation()
            log(string.format("Sperre %s bei %.0f %.0f %.0f, versteckt %s, Bedingung %s", objectName(gimmick), position.X, position.Y, position.Z,
                tostring(gimmick.bHidden), tostring(gimmick.m_FlagCondition:ToString())))
            log("Sperre Rueckweg " .. tostring(gimmick.m_ReturnDistance))
            gimmick.m_EventList:ForEach(function(_, element)
                local event = element:get()
                log("Sperre Ereignis " .. event.EventId:ToString() .. " [" .. tostring(textOf(event.Condition)) .. "], erfuellt "
                    .. tostring(conditionMet(event.Condition)))
            end)
        end
        -- Sperrobjekte in der Naehe: Steht davon eines zwischen Figur und Ziel?
        for _, blocker in ipairs(FindAllOf("CPP_MapGimmick_BlockingBase") or {}) do
            local position = blocker:K2_GetActorLocation()
            if distance2D(position, location) < 2000 then
                log(string.format("Sperrobjekt %s bei %.0f %.0f %.0f, Kollision %s", objectName(blocker), position.X, position.Y, position.Z,
                    tostring(blocker:GetActorEnableCollision())))
            end
        end
        for _, trigger in ipairs(FindAllOf("CPP_MapTransitionTrigger") or {}) do
            local origin, extent = {}, {}
            trigger:GetActorBounds(false, origin, extent, false)
            log(string.format("Ausgangsbereich %s: Mitte %.0f %.0f %.0f, halbe Groesse %.0f %.0f %.0f", objectName(trigger),
                origin.X, origin.Y, origin.Z, extent.X, extent.Y, extent.Z))
            local inside = false
            pcall(function()
                inside = location.X >= origin.X - extent.X and location.X <= origin.X + extent.X
                    and location.Y >= origin.Y - extent.Y and location.Y <= origin.Y + extent.Y
                    and location.Z >= origin.Z - extent.Z and location.Z <= origin.Z + extent.Z
            end)
            log(string.format("Ausgang %s: automatisch %s, nur Ereignis %s, Bedingung benutzt %s [%s], Figur drin %s, Kollision %s",
                objectName(trigger), tostring(trigger.m_IsAutoTransition), tostring(trigger.m_IsEventOnly), tostring(trigger.m_IsUseCondion),
                tostring(textOf(trigger.m_Condition)), tostring(inside), tostring(trigger:GetActorEnableCollision())))
            trigger.m_EventList:ForEach(function(_, element)
                log("Ausgang Ereignis " .. tostring(textOf(element:get().EventId)) .. " [" .. tostring(textOf(element:get().Condition)) .. "]")
            end)
        end
    end)
    if not ok then
        log("Hindernis-Abfrage fehlgeschlagen: " .. tostring(err))
    end
end

-- Wegpunkte aus dem NavMesh des Spiels. Das Spiel traegt sein Navmesh nicht als MainNavData ein,
-- ohne das liefert die Wegsuche nichts; der Eintrag muss nach einem Kartenwechsel erneuert werden.
local navRoute = {
    DOOR_EXIT_DISTANCE = 400,
    CHAIN_TIMEOUT_SECONDS = 15,
    CHAIN_ARRIVAL_DISTANCE = 800,
    JOURNEY_CALM_SECONDS = 1.5,
    JOURNEY_MAP_WAIT_SECONDS = 30,
    JOURNEY_NEAR_DISTANCE = 300,
    EXPLORE_MAX = 5,
    EXPLORE_MIN_DISTANCE = 1500,
    -- Suchbereich um das Ziel, weil viele Ziele neben oder ueber dem begehbaren Boden liegen.
    PROJECT_EXTENTS = {
        { X = 100, Y = 100, Z = 300 },
        { X = 300, Y = 300, Z = 800 },
        { X = 800, Y = 800, Z = 2000 },
    },
    FLOOR_HEIGHT = 300,
    END_DISTANCE = 60,
    SIDESTEP_SECONDS = 0.8,
    MAX_STUCK = 12,
    PROMPT_SECONDS = 0.5,
    -- eMapObjectType
    OBJECT_TYPE_NPC = 1,
    OBJECT_TYPE_GIMMICK = 2,
    actionWords = {},
}

function navRoute.ensureNavData()
    local chosen = nil
    for _, recast in ipairs(FindAllOf("RecastNavMesh") or {}) do
        if recast:IsValid() and (not chosen or objectName(recast):find("Default", 1, true)) then
            chosen = recast
        end
    end
    if not chosen then
        return nil
    end
    -- Nach einem Kartenwechsel kann kurz noch das alte System mitgefunden werden: alle versorgen.
    for _, system in ipairs(FindAllOf("NavigationSystemV1") or {}) do
        local main = system:IsValid() and system.MainNavData
        if system:IsValid() and not (main and main:IsValid()) then
            system.MainNavData = chosen
            log("Navmesh eingetragen: " .. objectName(chosen))
        end
    end
    return chosen
end

function navRoute.search(pawn, start, goal, context)
    local path = navigationFunctions:FindPathToLocationSynchronously(pawn, start, goal, context or pawn, nil)
    if not path or not path:IsValid() or path:GetPathLength() <= 0 then
        return nil
    end
    local points = {}
    path.PathPoints:ForEach(function(_, element)
        local point = element:get()
        table.insert(points, { X = point.X, Y = point.Y, Z = point.Z })
    end)
    if #points == 0 then
        return nil
    end
    return { points = points, length = path:GetPathLength(), partial = path:IsPartial() }
end

function navRoute.findUnchecked(pawn, origin, destination)
    if not navigationFunctions or not navigationFunctions:IsValid() then
        navigationFunctions = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    end
    local navData = navRoute.ensureNavData()
    if not navData then
        log("Weg: kein Navmesh gefunden")
        return nil
    end
    local start = { X = origin.X, Y = origin.Y, Z = origin.Z }
    local best = nil
    for _, extent in ipairs(navRoute.PROJECT_EXTENTS) do
        local goal = {}
        if navigationFunctions:K2_ProjectPointToNavigation(pawn, destination, goal, navData, nil, extent) then
            local route = navRoute.search(pawn, start, goal)
            -- Die kleine Figur der Weltkarte passt vielleicht zu keinem Navmesh: dann das Navmesh direkt angeben.
            if not route and navGrid.smallFigure then
                route = navRoute.search(pawn, start, goal, navData)
                if route and not navRoute.contextLogged then
                    navRoute.contextLogged = true
                    log("Weg ueber Navmesh als Kontext gefunden: " .. objectName(navData))
                end
            end
            if route and not route.partial then
                return route
            end
            best = best or route
        end
    end
    return best or navRoute.search(pawn, start, destination)
end

-- Erst das Navmesh; die eigene Wegekarte, wenn es nichts Vollstaendiges liefert oder die Figur darauf hing.
function navRoute.find(pawn, origin, destination, preferGrid, actor)
    local ok, route = pcall(navRoute.findUnchecked, pawn, origin, destination)
    if not ok then
        log("Wegsuche fehlgeschlagen: " .. tostring(route))
        route = nil
    end
    if route then
        route.source = "Navmesh"
    end
    -- Das Navmesh der Weltkarte kennt die Waende nicht und fuehrte in eine Sackgasse (14041 21426): fertige Karte zuerst.
    if preferGrid or navGrid.prebuilt or not route or route.partial then
        local gridOk, grid = pcall(navGrid.route, origin, destination, actor)
        if not gridOk then
            log("Wegekarte-Suche fehlgeschlagen: " .. tostring(grid))
        elseif grid and (not route or not grid.partial) then
            route = grid
        end
        -- Eine gespeicherte Karte kann veraltet sein (Tor inzwischen offen): einmal je Sitzung neu erfassen.
        if (not route or route.partial) and navGrid.fromFile and not navGrid.scannedThisSession[navGrid.level] then
            log("Wegekarte: kein vollstaendiger Weg, erfasse die Karte neu")
            navGrid.reset(navGrid.level, false)
        end
    end
    log(string.format("Weg von %.0f %.0f %.0f nach %.0f %.0f %.0f: %s", origin.X, origin.Y, origin.Z,
        destination.X, destination.Y, destination.Z, route and string.format("%s, %.0f cm, %d Punkte, teilweise %s",
            route.source, route.length, #route.points, tostring(route.partial)) or "keiner"))
    return route
end

-- Zeigt nur, was von der aktuellen Position aus wirklich erreichbar ist. Solange die Wegekarte
-- unfertig ist, laesst sich das nicht sagen, dann bleibt die Liste vollstaendig.
function navRoute.filterReachable(pawn, origin, targets, categoryName)
    local start = navGrid.complete and navGrid.nearest(origin)
    if not start then
        return targets
    end
    -- Bild hoch/runter fragt dieselbe Liste erneut ab: Auf der Weltkarte kostete die Pruefung 0,1 s je Ziel
    -- (05.11., 5 s je Schritt). Das Urteil gilt, solange Kategorie, Karte und Startpunkt gleich bleiben.
    local cacheKey = categoryName .. "|" .. tostring(navGrid.level) .. "|" .. tostring(start)
    if not navRoute.reachCache or navRoute.reachCache.key ~= cacheKey then
        navRoute.reachCache = { key = cacheKey, verdicts = {} }
    end
    local verdicts = navRoute.reachCache.verdicts
    local previous = nil
    local reachable, hidden = {}, 0
    for _, target in ipairs(targets) do
        local verdict = verdicts[target.path]
        if not verdict then
            previous = previous or navGrid.flood(start)
            verdict = {}
            local goal, partial = navGrid.chooseGoal(previous, target.location, target.actor)
            verdict.keep = goal and not partial
            -- Die fertige Karte kennt Waende, die dem Navmesh fehlen; dort entscheidet sie allein.
            if not verdict.keep and not navGrid.prebuilt then
                local ok, route = pcall(navRoute.findUnchecked, pawn, origin, target.location)
                verdict.keep = ok and route and not route.partial
            end
            if not verdict.keep and navRoute.mayUseDoors(categoryName, target) then
                local hop = navRoute.doorPath(pawn, origin, target.location, previous)
                if hop then
                    verdict.doorHops = hop.hops
                    verdict.keep = true
                end
            end
            verdicts[target.path] = verdict
        end
        local keep = verdict.keep
        target.doorHops = verdict.doorHops or target.doorHops
        -- Markierte Ziele bleiben auch ohne bekannten Weg waehlbar, mit Richtung und Entfernung.
        if not keep and (categoryName == QUEST_CATEGORY or categoryName == menuInfo.REQUEST_CATEGORY) then
            log("Questziel ohne bekannten Weg: " .. target.label .. " " .. target.path)
            keep = true
        end
        if keep then
            table.insert(reachable, target)
        else
            hidden = hidden + 1
            log("Nicht erreichbar: " .. target.label .. " " .. target.path)
        end
    end
    -- Eine gespeicherte Karte kann veraltet sein: einmal je Sitzung neu erfassen statt Ziele falsch auszublenden.
    if hidden > 0 and navGrid.fromFile and not navGrid.scannedThisSession[navGrid.level] then
        log("Wegekarte: Ziele nicht erreichbar, erfasse die Karte neu")
        navGrid.reset(navGrid.level, false)
        return targets
    end
    return reachable
end

-- Kartensymbole fuehren nirgends hin (BP_MapIconPoint_C_6), echte Ausgaenge stehen selbst in der Liste.
function navRoute.exitTargets(categoryName, targets)
    if categoryName ~= "Ausgänge" and categoryName ~= "Türen" then
        return targets
    end
    local kept = {}
    for _, target in ipairs(targets) do
        if not target.path:find("BP_MapIconPoint", 1, true) and not navRoute.isDoorOfExit(target, targets) then
            table.insert(kept, target)
        end
    end
    return kept
end

-- Tuer und Ausloesebereich dahinter sind ein Ausgang. Der Bereich bleibt: Die Figur geht dann direkt hindurch.
function navRoute.isDoorOfExit(target, targets)
    if not target.path:find("Door", 1, true) then
        return false
    end
    for _, other in ipairs(targets) do
        if other.path:find("MapTransitionTrigger", 1, true) and distance2D(target.location, other.location) < navRoute.DOOR_EXIT_DISTANCE
            and math.abs(target.location.Z - other.location.Z) < navRoute.FLOOR_HEIGHT then
            return true
        end
    end
    return false
end

-- Ziel ohne Spielobjekt: bietet nur, was Wegsuche und Laufen vom Akteur brauchen.
function navRoute.pointActor(path, location)
    return {
        IsValid = function() return true end,
        K2_GetActorLocation = function() return location end,
        GetFullName = function() return "Erkunden " .. path end,
        GetActorBounds = function() error("Punkt ohne Bereich") end,
    }
end

-- Die Enden des begehbaren Bereichs: jeweils der Punkt, der am weitesten von den bisherigen entfernt ist.
function navRoute.exploreTargets(origin)
    local start = navGrid.complete and navGrid.nearest(origin)
    if not start then
        return {}
    end
    local previous = navGrid.flood(start)
    local picks, targets = { origin }, {}
    while #targets < navRoute.EXPLORE_MAX do
        local best, bestDistance = nil, navRoute.EXPLORE_MIN_DISTANCE
        for node in pairs(previous) do
            local closest = math.huge
            for _, pick in ipairs(picks) do
                closest = math.min(closest, distance2D(node, pick))
            end
            if closest > bestDistance then
                best, bestDistance = node, closest
            end
        end
        if not best then
            break
        end
        table.insert(picks, best)
        local path = string.format("/Erkunden/%d/%d", best.X, best.Y)
        local location = { X = best.X, Y = best.Y, Z = best.Z }
        table.insert(targets, {
            actor = navRoute.pointActor(path, location),
            path = path,
            label = "Bereichsende",
            location = location,
            distance = distance2D(origin, best),
        })
    end
    return targets
end

function navRoute.targetsFor(categoryName, origin)
    if categoryName ~= "Erkunden" then
        local targets = scanTargets(categoryName, origin)
        if categoryName == "Ausgänge" or categoryName == "Türen" then
            local ok, err = pcall(navRoute.nameExits, targets)
            if not ok then
                log("Ausgangsnamen nicht lesbar: " .. tostring(err))
            end
        end
        return targets
    end
    navRoute.explored = navRoute.explored or navRoute.exploreTargets(origin)
    for _, target in ipairs(navRoute.explored) do
        target.distance = distance2D(origin, target.location)
    end
    return navRoute.explored
end

-- Alle Uebergaenge der Karte mit ihrem Zielpunkt; Punkte anderer Karten fehlen hier, destination bleibt dann leer.
function navRoute.doorLinks()
    if navRoute.links and navRoute.linksLevel == navGrid.level then
        return navRoute.links
    end
    local points = {}
    for _, point in ipairs(FindAllOf("CPP_MapTransitionPoint") or {}) do
        if point:IsValid() and type(point.m_PointID) == "number" then
            local position = point:K2_GetActorLocation()
            points[point.m_PointID] = { X = position.X, Y = position.Y, Z = position.Z + 100 }
        end
    end
    local links, inner = {}, 0
    for _, trigger in ipairs(FindAllOf("CPP_MapTransitionTrigger") or {}) do
        if trigger:IsValid() and not trigger.m_IsEventOnly then
            local mapId, pointId, listed = trigger.m_MapId, trigger.m_PointID, false
            pcall(function()
                trigger.mTransitionDataList:ForEach(function(_, element)
                    local data = element:get()
                    if not listed and conditionMet(data.FlagCondition) then
                        listed, mapId, pointId = true, data.mapId, data.pointId
                    end
                end)
            end)
            local position = trigger:K2_GetActorLocation()
            local destination = menuInfo.isSameMap(trigger, mapId) and points[pointId] or nil
            inner = inner + (destination and 1 or 0)
            table.insert(links, {
                actor = trigger,
                path = objectPath(trigger),
                pointId = pointId,
                location = { X = position.X, Y = position.Y, Z = position.Z },
                destination = destination,
            })
        end
    end
    navRoute.links, navRoute.linksLevel, navRoute.linkCache = links, navGrid.level, {}
    log(string.format("Uebergaenge: %d, davon innerhalb der Karte %d", #links, inner))
    return links
end

-- Verbindungen zwischen festen Punkten aendern sich kaum, das Ergebnis bleibt je Karte gemerkt.
function navRoute.pointsConnected(pawn, from, to, fromKey)
    local key = string.format("%s>%.0f:%.0f", fromKey, to.X, to.Y)
    local known = navRoute.linkCache[key]
    if known == nil then
        local ok, route = pcall(navRoute.findUnchecked, pawn, from, to)
        known = ok and route ~= nil and not route.partial
        navRoute.linkCache[key] = known
    end
    return known
end

-- Innerhalb einer Karte nennt das Spiel als Ziel nur die Karte selbst (alles "Mitra"). Darum Raeume aus den Wegen ableiten:
-- Was ohne Uebergang einen Ausgang aus der Karte erreicht, ist draussen, der Rest zaehlt je zusammenhaengendem Bereich als Raum.
function navRoute.linkRooms(pawn)
    local links = navRoute.doorLinks()
    if navRoute.roomNames and navRoute.roomLinks == links then
        return navRoute.roomNames
    end
    local exits, inner = {}, {}
    for _, link in ipairs(links) do
        table.insert(link.destination and inner or exits, link)
    end
    table.sort(inner, function(a, b)
        return a.pointId < b.pointId
    end)
    local names, rooms = {}, {}
    local pointNames = transitionPointNames()
    for _, link in ipairs(inner) do
        local key = tostring(link.pointId)
        -- Raeume haben im Spiel keinen Namen; nur Punktnamen mit Spielwort (namen_spiel.txt) werden genannt.
        local door = link.actor.pOpenDoor
        local name = pointNames[link.pointId]
        if name then
            names[link.path] = name
            if door and door:IsValid() then
                names[objectPath(door)] = name
            end
        end
        log(string.format("Raum: %s, Punkt %s: %s", objectName(link.actor), key, tostring(name)))
    end
    navRoute.roomNames, navRoute.roomLinks = names, links
    return names
end

function navRoute.nameExits(targets)
    local pawn = playerUnit()
    if pawn then
        local names = navRoute.linkRooms(pawn)
        for _, target in ipairs(targets) do
            target.label = names[target.path] or target.label
        end
    end
end

-- Breitensuche ueber die Uebergaenge: liefert den ersten Uebergang und ihre Anzahl bis zum Ziel.
function navRoute.doorPath(pawn, origin, destination, previous)
    local links = navRoute.doorLinks()
    if not previous then
        local start = navGrid.complete and navGrid.nearest(origin)
        previous = start and navGrid.flood(start)
    end
    local function fromOrigin(to)
        if previous then
            local goal, partial = navGrid.chooseGoal(previous, to)
            if goal and not partial then
                return true
            end
        end
        local ok, route = pcall(navRoute.findUnchecked, pawn, origin, to)
        return ok and route ~= nil and not route.partial
    end
    local queue, head, used = { { position = origin, hops = 0 } }, 1, {}
    while queue[head] do
        local entry = queue[head]
        head = head + 1
        local function reaches(to)
            if entry.hops == 0 then
                return fromOrigin(to)
            end
            return navRoute.pointsConnected(pawn, entry.position, to, entry.key)
        end
        if entry.hops > 0 and reaches(destination) then
            return { first = entry.first, hops = entry.hops }
        end
        for _, link in ipairs(links) do
            if link.destination and not used[link.path] and reaches(link.location) then
                used[link.path] = true
                table.insert(queue, {
                    position = link.destination,
                    key = tostring(link.pointId),
                    first = entry.first or link,
                    hops = entry.hops + 1,
                })
            end
        end
    end
    return nil
end

-- Ausgaenge innerhalb der Karte zeigt die Liste nur in Reichweite (Wunsch User), Wege aus der Karte auch hinter Tueren.
function navRoute.mayUseDoors(categoryName, target)
    if categoryName == "Türen" then
        return false
    end
    if categoryName ~= "Ausgänge" then
        return true
    end
    for _, link in ipairs(navRoute.doorLinks()) do
        if link.path == target.path then
            return link.destination == nil
        end
    end
    return false
end

function navRoute.hopsText(hops)
    return hops == 1 and "über 1 Übergang" or string.format("über %d Übergänge", hops)
end

function navRoute.describe(route)
    if not route then
        return navGrid.complete and "kein Weg bekannt" or "Wegekarte wird noch erfasst"
    end
    local meters = math.floor(route.length / 100 + 0.5)
    return string.format(route.partial and "Weg nur teilweise bekannt, %d Meter" or "Weg %d Meter", meters)
end

-- Aufzuege mit Schalter: Bedient wird der Schalter neben der Plattform (m_pActiveBoxComponent), nicht die Mitte.
function menuInfo.interactPoint(actor)
    local ok, at = pcall(function()
        local box = actor.m_pActiveBoxComponent
        return box and box:IsValid() and box:K2_GetComponentLocation()
    end)
    return ok and at or actor:K2_GetActorLocation()
end

-- Liegt ein Ziel auf anderer Hoehe ohne bekannten Weg, fuehrt meist ein Aufzug hin: den naechsten erreichbaren nennen.
function menuInfo.liftHint(pawn, origin, target)
    if math.abs(target.location.Z - origin.Z) < navRoute.FLOOR_HEIGHT then
        return ""
    end
    local best, bestRoute = nil, nil
    for _, lift in ipairs(navRoute.targetsFor("Objekte", origin)) do
        local ok, box = pcall(function()
            return lift.actor.m_pActiveBoxComponent
        end)
        if ok and box and box:IsValid() and lift.path ~= target.path then
            local route = navRoute.find(pawn, origin, lift.location, false, lift.actor)
            if route and not route.partial and (not bestRoute or route.length < bestRoute.length) then
                best, bestRoute = lift, route
            end
        end
    end
    if not best then
        return ""
    end
    log("Aufzug als Weg: " .. best.path)
    return ", weiter über " .. best.label .. ", " .. navRoute.describe(bestRoute)
end

function navRoute.reached(location, point)
    return distance2D(location, point) < WALK_POINT_REACHED_DISTANCE
        and math.abs(location.Z - point.Z) < navRoute.FLOOR_HEIGHT
end

-- Noch zu laufende Strecke entlang des Wegs; die Luftlinie kann auf einem Umweg sogar wachsen.
function navRoute.remaining(walk, location)
    if not walk.routed then
        return distance2D(location, menuInfo.interactPoint(walk.actor))
    end
    local total = distance2D(location, walk.points[walk.pointIndex])
    for index = walk.pointIndex, #walk.points - 1 do
        total = total + distance2D(walk.points[index], walk.points[index + 1])
    end
    return total
end

-- Manche Ausgaenge wechseln die Karte nicht von selbst, sondern erst auf Tastendruck im Ausloesebereich.
function navRoute.insideManualExit(trigger, location)
    if trigger.m_IsAutoTransition ~= false or trigger.m_IsEventOnly == true then
        return false
    end
    local origin, extent = {}, {}
    trigger:GetActorBounds(false, origin, extent, false)
    return math.abs(location.X - origin.X) <= extent.X and math.abs(location.Y - origin.Y) <= extent.Y
        and math.abs(location.Z - origin.Z) <= extent.Z
end

-- Beschreibt, was das Spiel gerade per Tastendruck anbietet.
function navRoute.currentPrompt(pawn)
    local location = pawn:K2_GetActorLocation()
    for _, trigger in ipairs(FindAllOf("CPP_MapTransitionTrigger") or {}) do
        local ok, inside = pcall(navRoute.insideManualExit, trigger, location)
        if ok and inside then
            return exitNames()[objectPath(trigger)] or menuInfo.displayLabel("Ausgang", trigger, 3)
        end
    end
    local prompt = nil
    pcall(function()
        pawn.m_pInteractMapGimmickList:ForEach(function(_, element)
            local gimmick = element:get()
            local interactType = interactTypeOf(gimmick)
            local info = interactType and INTERACT_TYPES[interactType]
            if not prompt and info and not isOpenedItem(gimmick, interactType) then
                local name = navRoute.roomNames and navRoute.roomNames[objectPath(gimmick)]
                prompt = navRoute.withAction(name or menuInfo.displayLabel(info[2], gimmick, 2), navRoute.OBJECT_TYPE_GIMMICK, interactType)
            end
        end)
    end)
    if prompt then
        return prompt
    end
    pcall(function()
        pawn.m_InteractMapUnitList:ForEach(function(_, element)
            local unit = element:get()
            if not prompt then
                local name = npcNames[objectPath(unit)]
                prompt = navRoute.withAction(name or menuInfo.displayLabel("Person", unit, 1), navRoute.OBJECT_TYPE_NPC, interactTypeOf(unit) or 0)
            end
        end)
    end)
    return prompt
end

-- Das Verb, das auch das Spiel am Objekt anzeigt, etwa "Öffnen" oder "Sprechen", in der Spielsprache.
function navRoute.withAction(name, objectType, interactType)
    local key = objectType .. ":" .. tostring(interactType)
    if navRoute.actionWords[key] == nil then
        local ok, text = pcall(function()
            return textOf(StaticFindObject("/Script/mucha.Default__CPP_VM_ObjectInteract"):FindInteractActionText(objectType, interactType))
        end)
        navRoute.actionWords[key] = ok and text or false
        log("Aktionswort " .. key .. ": " .. tostring(text))
    end
    local word = navRoute.actionWords[key]
    return word and word ~= name and (name .. ": " .. word) or name
end

function navRoute.tickPrompt()
    local now = os.clock()
    if now < (navRoute.nextPrompt or 0) then
        return
    end
    navRoute.nextPrompt = now + navRoute.PROMPT_SECONDS
    local pawn = playerUnit()
    if not pawn or pawn.m_IsEnableUnitInput == false then
        return
    end
    local prompt = navRoute.currentPrompt(pawn)
    if prompt ~= navRoute.lastPrompt then
        navRoute.lastPrompt = prompt
        log("Tastenhinweis: " .. tostring(prompt))
        if prompt then
            speak(prompt .. ", Enter drücken.", false)
        end
    end
end

-- Steht das Ziel in der Liste der Objekte, die das Spiel gerade zum Benutzen anbietet?
function navRoute.inInteractRange(pawn, actor)
    local wanted, found = objectPath(actor), false
    local exitOk, insideExit = pcall(navRoute.insideManualExit, actor, pawn:K2_GetActorLocation())
    if exitOk and insideExit then
        return true
    end
    for _, fieldName in ipairs({ "m_pInteractMapGimmickList", "m_InteractMapUnitList" }) do
        pcall(function()
            pawn[fieldName]:ForEach(function(_, element)
                found = found or objectPath(element:get()) == wanted
            end)
        end)
    end
    return found
end

-- Die Luftlinie allein genuegt nicht: Das Ziel kann direkt ueber oder unter der Figur liegen.
-- Bis zum Wegende laufen, sonst bleibt die Figur vor Truhen ausserhalb der Reichweite stehen.
function navRoute.finished(walk, location)
    local straight = distance2D(location, menuInfo.interactPoint(walk.actor))
    if navRoute.inInteractRange(walk.pawn, walk.actor) then
        return "arrived"
    end
    if not walk.routed then
        return straight <= WALK_ARRIVAL_DISTANCE and "arrived" or nil
    end
    local last = walk.points[#walk.points]
    if walk.pointIndex < #walk.points or math.abs(location.Z - last.Z) > navRoute.FLOOR_HEIGHT then
        return nil
    end
    if walk.stuckCount > 0 and straight <= WALK_ARRIVAL_DISTANCE then
        return "arrived"
    end
    if distance2D(location, last) <= navRoute.END_DISTANCE then
        return walk.partial and "deadEnd" or "arrived"
    end
    return nil
end

function navRoute.replan(walk, location)
    -- Das Navmesh kennt das Hindernis nicht und plant wieder hindurch (14041 21426, Log 06:57): gleich die Wegekarte nehmen.
    local route = navRoute.find(walk.pawn, location, menuInfo.interactPoint(walk.actor), walk.stuckCount >= 1, walk.actor)
    if route then
        walk.points, walk.pointIndex, walk.partial, walk.source = route.points, 1, route.partial, route.source
        walk.bestRemaining = navRoute.remaining(walk, location)
    end
end

-- Erste Seitenrichtung, in der die Kapsel wirklich frei ist; sonst die naechste der Reihe.
function navRoute.nextSidestep(walk, location, point)
    local length = distance2D(location, point)
    local toX, toY = (point.X - location.X) / math.max(length, 1), (point.Y - location.Y) / math.max(length, 1)
    local floorZ = location.Z - navGrid.halfHeight
    for offset = 1, #WALK_DETOUR_ANGLES do
        local index = (walk.detourIndex + offset - 1) % #WALK_DETOUR_ANGLES + 1
        local angle = math.rad(WALK_DETOUR_ANGLES[index])
        local dirX = toX * math.cos(angle) - toY * math.sin(angle)
        local dirY = toX * math.sin(angle) + toY * math.cos(angle)
        local ok, free = pcall(navGrid.sweepFree, location.X, location.Y, floorZ,
            location.X + dirX * navGrid.OBSTACLE_REACH, location.Y + dirY * navGrid.OBSTACLE_REACH, floorZ)
        if ok and free then
            walk.detourIndex = index
            return WALK_DETOUR_ANGLES[index]
        end
    end
    walk.detourIndex = walk.detourIndex % #WALK_DETOUR_ANGLES + 1
    return WALK_DETOUR_ANGLES[walk.detourIndex]
end

-- Haengt die Figur auf einem Weg, tritt sie kurz zur Seite und berechnet den Weg von dort neu.
function navRoute.updateStuck(walk, location, now)
    if now < walk.probeAt then
        return
    end
    local moved = distance2D(location, walk.probeLocation)
    walk.probeAt, walk.probeLocation = now + WALK_PROBE_SECONDS, { X = location.X, Y = location.Y }
    if moved < WALK_MIN_PROGRESS then
        walk.stuckCount = walk.stuckCount + 1
        walk.blocked = walk.stuckCount > navRoute.MAX_STUCK
        local point = walk.points[walk.pointIndex]
        local identified, obstacle = pcall(navGrid.identifyObstacle, walk.pawn, location, point)
        if not identified then
            log("Hindernis nicht bestimmbar: " .. tostring(obstacle))
            obstacle = nil
        end
        -- Die Stelle selbst sperren: blockAhead allein fand 11 Mal keine Kante (Log 06:57), die Wegekarte plante denselben Weg neu.
        navGrid.blockAhead(location, point)
        if obstacle and obstacle.X then
            navGrid.blockAround(obstacle.X, obstacle.Y, navGrid.nearest(location))
        end
        walk.detourAngle = navRoute.nextSidestep(walk, location, point)
        walk.detourUntil = now + navRoute.SIDESTEP_SECONDS
        log(string.format("Haengt bei %.0f %.0f %.0f, Seitenschritt %d Grad", location.X, location.Y, location.Z, walk.detourAngle))
        local word = obstacle and obstacle.word or "unbekannt"
        if word ~= walk.lastObstacle then
            walk.lastObstacle = word
            speak("Hindernis: " .. word .. ", suche neuen Weg.", false)
        end
    elseif walk.detourAngle ~= 0 and now >= walk.detourUntil then
        walk.detourAngle = 0
        navRoute.replan(walk, location)
    end
end

local function describeTarget(target, index, count, origin, pawn, controller)
    local meters = math.floor(target.distance / 100 + 0.5)
    local route = not target.doorHops and navRoute.find(pawn, origin, target.location, false, target.actor)
    local way = target.doorHops and navRoute.hopsText(target.doorHops) or navRoute.describe(route)
    if not target.doorHops and (not route or route.partial) then
        local hintOk, hint = pcall(menuInfo.liftHint, pawn, origin, target)
        way = way .. (hintOk and hint or "")
    end
    return string.format("%s, %s, Luftlinie %d Meter %s, %d von %d", target.label, way, meters,
        directionName(origin, target.location, controller), index, count)
end

local function selectTarget(steps)
    local pawn, controller = playerUnit()
    if not pawn then
        speak("Pathfinder hier nicht verfügbar.", true)
        return
    end
    local origin = pawn:K2_GetActorLocation()
    local diagnosticsOk, diagnosticsError = pcall(logTargetDiagnostics, pawn, origin)
    if not diagnosticsOk then
        log("Diagnose fehlgeschlagen: " .. tostring(diagnosticsError))
    end
    local categoryName = TARGET_CATEGORIES[selectedCategory]
    if steps == 0 then
        navRoute.explored = nil
        navRoute.reachCache = nil
    end
    local allTargets = navRoute.targetsFor(categoryName, origin)
    local targets = navRoute.exitTargets(categoryName, allTargets)
    if categoryName ~= "Erkunden" then
        targets = navRoute.filterReachable(pawn, origin, targets, categoryName)
    end
    if #targets == 0 then
        selectedTargetPath = nil
        if categoryName == QUEST_CATEGORY then
            speak(QUEST_CATEGORY .. ", hier nichts markiert."
                .. (menuInfo.questElsewhere and (" Ziel: " .. menuInfo.questElsewhere .. ".") or ""), true)
            return
        end
        speak(categoryName .. (#allTargets > 0 and ", nichts erreichbar." or ", nichts gefunden."), true)
        return
    end
    local index = 1
    if steps ~= 0 then
        for candidate, target in ipairs(targets) do
            if target.path == selectedTargetPath then
                index = (candidate - 1 + steps) % #targets + 1
                break
            end
        end
    end
    local target = targets[index]
    selectedTargetPath = target.path
    log(string.format("Ziel: %s %s %.0f %.0f %.0f", shortClassName(target.actor), target.path,
        target.location.X, target.location.Y, target.location.Z))
    local description = describeTarget(target, index, #targets, origin, pawn, controller)
    speak(steps == 0 and (categoryName .. ", " .. description) or description, true)
end

local function stepCategory(steps)
    selectedCategory = (selectedCategory - 1 + steps) % #TARGET_CATEGORIES + 1
    selectedTargetPath = nil
    selectTarget(0)
end


local function endWalk(message)
    if activeWalk then
        local pawn = activeWalk.pawn
        log(string.format("Gelaufen: %.0f cm, geplant %.0f cm", activeWalk.walked, activeWalk.planned))
        activeWalk = nil
        if pawn:IsValid() then
            pcall(function()
                pawn.m_InputActionValue = { X = 0, Y = 0 }
                pawn.Controller:StopMovement()
            end)
        end
    end
    if message then
        speak(message, true)
    end
end

function navRoute.startWalk()
    local pawn, controller = playerUnit()
    if not pawn then
        speak("Pathfinder hier nicht verfügbar.", true)
        return
    end
    if not selectedTargetPath then
        speak("Kein Ziel ausgewählt.", true)
        return
    end
    local origin = pawn:K2_GetActorLocation()
    local target = nil
    for _, candidate in ipairs(navRoute.targetsFor(TARGET_CATEGORIES[selectedCategory], origin)) do
        if candidate.path == selectedTargetPath then
            target = candidate
        end
    end
    if not target then
        speak("Das Ziel ist nicht mehr da.", true)
        return
    end
    local startedAt = os.clock()
    local route = navRoute.find(pawn, origin, target.location, false, target.actor)
    local goalLabel, hops = target.label, nil
    navRoute.chain = nil
    -- Das Ziel liegt in einem anderen Raum: erst zum ersten Uebergang, tickChain laeuft danach weiter.
    if not route or route.partial then
        local hop = navRoute.doorPath(pawn, origin, target.location)
        if hop then
            hops = hop.hops
            local link = hop.first
            log(string.format("Tuerweg zu %s: %d Uebergaenge, zuerst %s", goalLabel, hops, tostring(link.path)))
            navRoute.chain = { path = selectedTargetPath, expected = link.destination }
            target = { actor = link.actor, label = menuInfo.displayLabel("Ausgang", link.actor, 3), location = link.location, distance = distance2D(origin, link.location) }
            route = navRoute.find(pawn, origin, target.location, false, target.actor)
        end
    end
    -- Mit fertiger Wegekarte ist klar, dass hier gerade nichts hinfuehrt: nicht sinnlos gegen die Sperre laufen.
    -- Auf der Weltkarte darf die Figur es trotzdem versuchen: Der Scan laeuft von jedem neuen Punkt aus weiter.
    if not route and navGrid.complete and navGrid.smallFigure then
        navGrid.logBlocker(origin, target.location)
    elseif not route and navGrid.complete then
        navGrid.logBlocker(origin, target.location)
        speak("Kein Weg zu " .. target.label .. ", der Weg ist versperrt oder nicht begehbar.", true)
        return
    end
    activeWalk = {
        pawn = pawn,
        controller = controller,
        actor = target.actor,
        label = target.label,
        useInputAction = true,
        inputWasEnabled = pawn.m_IsEnableUnitInput == true,
        routed = route ~= nil,
        source = route and route.source,
        partial = route ~= nil and route.partial,
        stuckCount = 0,
        planned = route and route.length or target.distance,
        walked = 0,
        lastLocation = origin,
        bestRemaining = route and route.length or target.distance,
        bestAt = startedAt,
        probeAt = startedAt + WALK_PROBE_SECONDS,
        probeLocation = { X = origin.X, Y = origin.Y },
        detourIndex = 0,
        detourAngle = 0,
        detourSeconds = WALK_DETOUR_SECONDS,
        detourUntil = 0,
        points = route and route.points or { target.location },
        pointIndex = 1,
    }
    if hops then
        speak("Laufe zu " .. goalLabel .. ", " .. navRoute.hopsText(hops) .. ".", true)
    elseif route then
        speak("Laufe zu " .. target.label .. ", " .. navRoute.describe(route) .. ".", true)
    else
        speak((navGrid.complete and "Kein Weg bekannt" or "Wegekarte noch nicht fertig") .. ", laufe geradeaus zu " .. target.label .. ".", true)
    end
end

-- Questreise (Wunsch User 2026-11-05): Pos1 in der Kategorie Questziel laeuft Abschnitt fuer Abschnitt zum Ziel.
-- Neu geplant wird nur bei Start, nach gesperrter Eingabe (Szene, Kampf, Menue, Laden) und nach Kartenwechsel,
-- damit die Figur am Ziel stehen bleibt, bis man selbst Enter drueckt.
-- Bei Auftraegen folgt die Reise den Auftraegen des gewaehlten Eintrags (questIds) ueber alle Karten.
function navRoute.startJourney(questIds)
    navRoute.journey = { pending = true, level = navGrid.level, calmSince = os.clock() - navRoute.JOURNEY_CALM_SECONDS,
        questIds = questIds }
    log("Questreise gestartet")
    speak("Questreise gestartet.", true)
end

function navRoute.journeyPick(pawn, origin, categoryName, accept)
    local targets = navRoute.exitTargets(categoryName, navRoute.targetsFor(categoryName, origin))
    if categoryName ~= QUEST_CATEGORY then
        targets = navRoute.filterReachable(pawn, origin, targets, categoryName)
    end
    for _, target in ipairs(targets) do
        if not accept or accept(target) then
            return target
        end
    end
    return nil
end

-- Reihenfolge: markiertes Questziel hier, sonst Ausgang zur Zielkarte (oder hinaus aufs Feld), sonst ein
-- Story-Ereignis; Story-Ausloeser fuehrten bisher immer zur richtigen Szene.
function navRoute.planJourneyLeg(pawn)
    local journey = navRoute.journey
    local origin = pawn:K2_GetActorLocation()
    local categoryName = journey.questIds and menuInfo.REQUEST_CATEGORY or QUEST_CATEGORY
    local target = navRoute.journeyPick(pawn, origin, categoryName, journey.questIds and function(candidate)
        for questId in pairs(candidate.questIds or {}) do
            if journey.questIds[questId] then
                return true
            end
        end
        return false
    end)
    if target and (target.distance < navRoute.JOURNEY_NEAR_DISTANCE
            or (target.path == journey.arrivedPath and journey.arrivedLevel == navGrid.level)) then
        log("Questreise: am Ziel " .. target.label)
        return
    end
    local destination = not journey.questIds and menuInfo.questElsewhere
    if not target and journey.questIds then
        log("Questreise: kein Auftragsziel mehr")
        speak("Questreise: hier ist kein nächster Schritt bekannt.", true)
        return
    end
    if not target and destination then
        categoryName = "Ausgänge"
        target = navRoute.journeyPick(pawn, origin, categoryName, function(candidate)
            return candidate.label:find(destination, 1, true)
        end) or navRoute.journeyPick(pawn, origin, categoryName, function(candidate)
            return candidate.label:find("Feld", 1, true) or candidate.label:find("draußen", 1, true)
        end)
    end
    if not target then
        categoryName = "Story-Ereignisse"
        target = navRoute.journeyPick(pawn, origin, categoryName)
    end
    if not target then
        log("Questreise: kein Schritt, Ziel " .. tostring(destination))
        speak("Questreise: hier ist kein nächster Schritt bekannt" .. (destination and (". Ziel: " .. destination) or "") .. ".", true)
        return
    end
    for index, name in ipairs(TARGET_CATEGORIES) do
        if name == categoryName then
            selectedCategory = index
        end
    end
    selectedTargetPath = target.path
    log("Questreise: " .. categoryName .. ", " .. target.label .. " " .. target.path)
    navRoute.startWalk()
end

function navRoute.tickJourney()
    local journey = navRoute.journey
    if not journey then
        return
    end
    local pawn = playerUnit()
    if not pawn or pawn.m_IsEnableUnitInput == false then
        -- Automatische Uebergaenge eines Tuerwegs setzt tickChain fort, das ist kein neuer Abschnitt.
        if not navRoute.chain then
            journey.pending, journey.calmSince = true, nil
        end
        return
    end
    if navGrid.level ~= journey.level then
        journey.level, journey.pending, journey.calmSince = navGrid.level, true, nil
    end
    if not journey.pending or activeWalk or navRoute.chain then
        return
    end
    local now = os.clock()
    journey.calmSince = journey.calmSince or now
    local calm = now - journey.calmSince
    -- Auf neuen Karten erst die Wegekarte abwarten, sonst liefe die Figur geradeaus los.
    if calm < navRoute.JOURNEY_CALM_SECONDS or (not navGrid.complete and calm < navRoute.JOURNEY_MAP_WAIT_SECONDS) then
        return
    end
    journey.pending = false
    navRoute.planJourneyLeg(pawn)
end

local function toggleWalk()
    if activeWalk then
        navRoute.chain = nil
        endWalk(navRoute.journey and "Laufen abgebrochen, Questreise beendet." or "Laufen abgebrochen.")
        navRoute.journey = nil
        return
    end
    local categoryName = TARGET_CATEGORIES[selectedCategory]
    if categoryName == QUEST_CATEGORY or categoryName == menuInfo.REQUEST_CATEGORY then
        if navRoute.journey then
            navRoute.journey = nil
            log("Questreise beendet")
            speak("Questreise beendet.", true)
            return
        end
        local questIds = nil
        if categoryName == menuInfo.REQUEST_CATEGORY then
            local pawn = playerUnit()
            for _, candidate in ipairs(pawn and navRoute.targetsFor(categoryName, pawn:K2_GetActorLocation()) or {}) do
                if candidate.path == selectedTargetPath then
                    questIds = candidate.questIds
                end
            end
            if not questIds then
                speak("Kein Ziel ausgewählt.", true)
                return
            end
        end
        navRoute.startJourney(questIds)
        return
    end
    -- Ein eigenes Ziel ersetzt die Questreise.
    if navRoute.journey then
        navRoute.journey = nil
        log("Questreise beendet durch anderes Ziel")
    end
    navRoute.startWalk()
end

-- Nach dem Uebergang am Zielpunkt angekommen: den naechsten Abschnitt starten.
function navRoute.tickChain()
    local chain = navRoute.chain
    if not chain or activeWalk then
        return
    end
    if chain.path ~= selectedTargetPath then
        navRoute.chain = nil
        return
    end
    local now = os.clock()
    -- Die Frist beginnt erst am Ende des Abschnitts, lange Wege sollen nicht hineinzaehlen.
    chain.deadline = chain.deadline or now + navRoute.CHAIN_TIMEOUT_SECONDS
    local pawn = playerUnit()
    if pawn and pawn.m_IsEnableUnitInput ~= false and distance2D(pawn:K2_GetActorLocation(), chain.expected) < navRoute.CHAIN_ARRIVAL_DISTANCE then
        navRoute.chain = nil
        navRoute.startWalk()
    elseif now > chain.deadline then
        navRoute.chain = nil
        speak("Übergang hat nicht ausgelöst, Weg abgebrochen.", true)
    end
end

-- Am Ziel passiert nichts: Das Ziel kann nur ein Kartensymbol sein. Echte Uebergaenge in der Naehe nennen.
function navRoute.reportNearbyExits(pawn, actor, location)
    local _, controller = playerUnit()
    local names = exitNames()
    local nearest, nearestDistance, nearestCenter, nearestInside = nil, math.huge, nil, false
    log("Ziel am Ende: " .. tostring(objectPath(actor)))
    local function consider(object, kind)
        local origin, extent = {}, {}
        object:GetActorBounds(false, origin, extent, false)
        local inside = math.abs(location.X - origin.X) <= extent.X and math.abs(location.Y - origin.Y) <= extent.Y
            and math.abs(location.Z - origin.Z) <= extent.Z
        local distance = distance2D(location, origin)
        log(string.format("Uebergang %s %s: Mitte %.0f %.0f %.0f, halb %.0f %.0f %.0f, %.0f cm, drin %s, automatisch %s, Name %s",
            kind, objectName(object), origin.X, origin.Y, origin.Z, extent.X, extent.Y, extent.Z, distance, tostring(inside),
            tostring(object.m_IsAutoTransition), tostring(names[objectPath(object)])))
        if distance < nearestDistance then
            nearest, nearestDistance, nearestCenter, nearestInside = object, distance, origin, inside
        end
    end
    for _, trigger in ipairs(FindAllOf("CPP_MapTransitionTrigger") or {}) do
        if trigger:IsValid() then
            pcall(consider, trigger, "Ausgang")
        end
    end
    for _, door in ipairs(FindAllOf("CPP_MapGimmick_Object_DoorBase") or {}) do
        if door:IsValid() then
            pcall(consider, door, "Tuer")
        end
    end
    pcall(function()
        pawn.m_pInteractMapGimmickList:ForEach(function(_, element)
            log("Angebot: " .. objectName(element:get()))
        end)
    end)
    -- Der Weg hinaus kann auch ein anderes Objekt sein, und Zielpunkte zeigen, wohin Uebergaenge fuehren.
    for _, point in ipairs(FindAllOf("CPP_MapTransitionPoint") or {}) do
        if point:IsValid() then
            local position = point:K2_GetActorLocation()
            log(string.format("Zielpunkt %s: %.0f %.0f %.0f, ID %s, %.0f cm", objectName(point), position.X, position.Y, position.Z,
                tostring(point.m_PointID), distance2D(location, position)))
        end
    end
    for _, gimmick in ipairs(FindAllOf("CPP_MapGimmick") or {}) do
        if gimmick:IsValid() then
            local position = gimmick:K2_GetActorLocation()
            local distance = distance2D(location, position)
            if distance < 2000 then
                log(string.format("In der Naehe %s %s: %.0f %.0f %.0f, %.0f cm, versteckt %s, Typ %s", shortClassName(gimmick), objectName(gimmick),
                    position.X, position.Y, position.Z, distance, tostring(gimmick.bHidden), tostring(interactTypeOf(gimmick))))
            end
        end
    end
    if not nearest then
        speak("Kein echter Übergang auf dieser Karte.", false)
        return
    end
    local name = navRoute.linkRooms(pawn)[objectPath(nearest)] or names[objectPath(nearest)] or menuInfo.displayLabel("Ausgang", nearest, 3)
    if nearestInside then
        speak("Im Bereich von " .. name .. ".", false)
    else
        speak(string.format("Nächster Übergang: %s, %d Meter %s.", name, math.floor(nearestDistance / 100 + 0.5),
            directionName(location, nearestCenter, controller)), false)
    end
end

local function tickWalk()
    if not activeWalk then
        return
    end
    if not activeWalk.pawn:IsValid() or not activeWalk.actor:IsValid() then
        endWalk("Das Ziel ist nicht mehr da.")
        return
    end
    local location = activeWalk.pawn:K2_GetActorLocation()
    local remaining = navRoute.remaining(activeWalk, location)
    local finished = navRoute.finished(activeWalk, location)
    if finished == "arrived" then
        local inRange = navRoute.inInteractRange(activeWalk.pawn, activeWalk.actor)
        log("Ankunft: in Reichweite " .. tostring(inRange))
        local pawn, actor = activeWalk.pawn, activeWalk.actor
        if navRoute.journey and not navRoute.chain then
            navRoute.journey.arrivedPath, navRoute.journey.arrivedLevel = selectedTargetPath, navGrid.level
        end
        endWalk(activeWalk.label .. (inRange and " erreicht, in Reichweite." or " erreicht."))
        if not inRange and not navRoute.chain then
            local ok, err = pcall(navRoute.reportNearbyExits, pawn, actor, location)
            if not ok then
                log("Uebergaenge nicht lesbar: " .. tostring(err))
            end
        end
        return
    elseif finished == "deadEnd" then
        local goal = menuInfo.interactPoint(activeWalk.actor)
        local straight = distance2D(location, goal)
        navGrid.logBlocker(location, goal)
        local hintOk, hint = pcall(menuInfo.liftHint, activeWalk.pawn, location,
            { path = objectPath(activeWalk.actor), location = goal })
        endWalk(string.format("Weiter ist kein Weg bekannt, noch %d Meter", math.floor(straight / 100 + 0.5))
            .. (hintOk and hint or "") .. ".")
        return
    end
    -- Zwischensequenzen und Menues sperren die Eingabe, dann soll nichts mehr weiterlaufen.
    if activeWalk.inputWasEnabled and activeWalk.pawn.m_IsEnableUnitInput == false then
        -- Ein automatischer Uebergang sperrt die Eingabe schon vor dem Wegende, tickChain laeuft danach von selbst weiter.
        endWalk(not navRoute.chain and "Laufen unterbrochen." or nil)
        return
    end
    local now = os.clock()
    if remaining < activeWalk.bestRemaining - WALK_PROGRESS_STEP then
        activeWalk.bestRemaining, activeWalk.bestAt = remaining, now
        if not activeWalk.routed then
            activeWalk.detourIndex, activeWalk.detourSeconds = 0, WALK_DETOUR_SECONDS
        end
    elseif activeWalk.blocked or now - activeWalk.bestAt > WALK_GIVE_UP_SECONDS then
        navGrid.logBlocker(location, menuInfo.interactPoint(activeWalk.actor))
        endWalk(string.format("Weg blockiert, noch %d Meter.", math.floor(remaining / 100 + 0.5)))
    end
end

-- Ohne bekannten Weg: Bleibt die Figur haengen, probiert sie schraege Richtungen und laeuft
-- eine funktionierende Richtung laenger, bevor sie es wieder direkt versucht.
local function updateDetour(walk, location, now)
    if now < walk.probeAt then
        return
    end
    local moved = distance2D(location, walk.probeLocation)
    walk.probeAt, walk.probeLocation = now + WALK_PROBE_SECONDS, { X = location.X, Y = location.Y }
    if moved < WALK_MIN_PROGRESS then
        -- Eine Richtung, die dem Ziel nicht naeher gebracht hat, wird nicht verlaengert.
        local wasUseless = walk.detourStartedAt and walk.bestAt < walk.detourStartedAt
        if walk.detourAngle ~= 0 or walk.detourIndex == 0 or wasUseless then
            walk.detourIndex = walk.detourIndex % #WALK_DETOUR_ANGLES + 1
        else
            walk.detourSeconds = math.min(walk.detourSeconds * 1.5, WALK_DETOUR_MAX_SECONDS)
        end
        walk.detourAngle = WALK_DETOUR_ANGLES[walk.detourIndex]
        walk.detourStartedAt, walk.detourUntil = now, now + walk.detourSeconds
        log(string.format("Ausweichen: %d Grad fuer %.1f s", walk.detourAngle, walk.detourSeconds))
        if not walk.detourAnnounced then
            walk.detourAnnounced = true
            speak("Hindernis, weiche aus.", false)
        end
    elseif walk.detourAngle ~= 0 and now >= walk.detourUntil then
        walk.detourAngle = 0
    end
end

-- Dieselbe Groesse wie bei Tasteneingabe: X nach rechts, Y nach vorne, relativ zur Kamera.
local function walkInputValue(walk, directionX, directionY)
    local yaw = math.rad(walk.controller.PlayerCameraManager:GetCameraRotation().Yaw)
    local forward = directionX * math.cos(yaw) + directionY * math.sin(yaw)
    local right = -directionX * math.sin(yaw) + directionY * math.cos(yaw)
    return right, forward
end

-- Loest dieselbe Eingabeaktion aus wie die Bewegungstasten. Die Funktion gehoert zu einem Interface,
-- deshalb gibt es neben dem Methodenaufruf den Aufruf ueber das Funktionsobjekt.
local function injectMoveInput(right, forward)
    if not moveInputAction or not moveInputAction:IsValid() then
        moveInputAction = StaticFindObject(MOVE_INPUT_ACTION)
    end
    if not inputSubsystem or not inputSubsystem:IsValid() then
        inputSubsystem = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
    end
    local value = { X = right, Y = forward, Z = 0 }
    local methodOk, methodError = pcall(function()
        inputSubsystem:InjectInputVectorForAction(moveInputAction, value, {}, {})
    end)
    if methodOk then
        return true
    end
    local functionOk, functionError = pcall(function()
        StaticFindObject(INJECT_INPUT_FUNCTION)(inputSubsystem, moveInputAction, value, {}, {})
    end)
    if not functionOk then
        log("Eingabeaktion fehlgeschlagen: " .. tostring(methodError) .. " / " .. tostring(functionError))
    end
    return functionOk
end

-- Eingaben gelten nur fuer einen Frame, deshalb laeuft die Steuerung in eigenem, schnellerem Takt.
local function tickSteering()
    if not (activeWalk and activeWalk.pawn:IsValid()) then
        return
    end
    local location = activeWalk.pawn:K2_GetActorLocation()
    activeWalk.walked = activeWalk.walked + distance2D(location, activeWalk.lastLocation)
    activeWalk.lastLocation = location
    local point = activeWalk.points[activeWalk.pointIndex]
    while activeWalk.pointIndex < #activeWalk.points and navRoute.reached(location, point) do
        activeWalk.pointIndex = activeWalk.pointIndex + 1
        point = activeWalk.points[activeWalk.pointIndex]
    end
    local length = distance2D(location, point)
    if length > 0 then
        if activeWalk.routed then
            navRoute.updateStuck(activeWalk, location, os.clock())
            point = activeWalk.points[activeWalk.pointIndex]
            length = math.max(distance2D(location, point), 1)
        else
            updateDetour(activeWalk, location, os.clock())
        end
        local angle = math.rad(activeWalk.detourAngle)
        local toX, toY = (point.X - location.X) / length, (point.Y - location.Y) / length
        local directionX = toX * math.cos(angle) - toY * math.sin(angle)
        local directionY = toX * math.sin(angle) + toY * math.cos(angle)
        if activeWalk.useInputAction then
            local right, forward = walkInputValue(activeWalk, directionX, directionY)
            if not injectMoveInput(right, forward) then
                log("Eingabeaktion geht nicht, wechsle zu AddMovementInput")
                activeWalk.useInputAction = false
            end
        else
            activeWalk.pawn:AddMovementInput({ X = directionX, Y = directionY, Z = 0 }, 1.0, true)
        end
    end
end

-- Eigene Funktion, weil Lua je Funktion nur 200 lokale Namen erlaubt.
local tickBattle, readCurrentQuest
local function defineBattleAndQuest()

local battleUnitStates = {}
local lastTargetSelection = nil
local battleActive = false
local battleEndSince = nil
local enemiesAnnounced = false
local resultVisible = false
local resultAnnounced = false
local resultSummary = nil
local resultText = nil
local resultTextSince = 0
local resultTextSpoken = nil
local resultHookState = nil
local itemFunctions = nil

local function battleUnitName(unit)
    for _, functionName in ipairs({ "GetDuplicationUnitName", "GetUnitName" }) do
        local value = callFunction(unit.parameter, functionName)
        local ok, text = pcall(function()
            return type(value) == "string" and value or value:ToString()
        end)
        if ok and text and text ~= "" then
            return text
        end
    end
    return "Einheit " .. tostring(unit.id)
end

local function isEnemyUnit(unit)
    return callFunction(unit.viewModel, "GetRelation") == RELATION_ENEMIES
end

-- Die Anzeige-HP aendern sich mit dem sichtbaren Treffer, die echten HP eventuell schon vorher.
local function readBattleUnits()
    local units = {}
    for _, viewModel in ipairs(FindAllOf("CPP_VM_BtlUnitParam") or {}) do
        local parameter = viewModel:IsValid() and viewModel.BtlUnitParam
        if parameter and parameter:IsValid() then
            local hitPoints = callFunction(parameter, "GetDisplayHitPoint") or callFunction(parameter, "GetHitPoint")
            if type(hitPoints) == "number" then
                table.insert(units, {
                    key = objectPath(viewModel),
                    id = viewModel.UniqueID,
                    viewModel = viewModel,
                    parameter = parameter,
                    hitPoints = hitPoints,
                })
            end
        end
    end
    return units
end

local function announceHitPointChange(unit, change)
    local name = battleUnitName(unit)
    local enemy = isEnemyUnit(unit)
    log(string.format("HP %s (%s): %d, jetzt %d", name, enemy and "Gegner" or "Verbuendeter", change, unit.hitPoints))
    local parts = { name, change < 0 and (-change .. " Schaden") or (change .. " geheilt") }
    if unit.hitPoints <= 0 then
        table.insert(parts, enemy and "besiegt" or "kampfunfähig")
    elseif not enemy then
        table.insert(parts, "noch " .. unit.hitPoints .. " HP")
    end
    speak(table.concat(parts, ", "), false)
end

-- Erst melden, wenn der Wert einen Takt lang stabil ist, damit Trefferfolgen nicht zerhackt werden.
local function tickHitPoints(units)
    local nextStates = {}
    for _, unit in ipairs(units) do
        local state = battleUnitStates[unit.key] or { reported = unit.hitPoints, last = unit.hitPoints }
        if unit.hitPoints == state.last and unit.hitPoints ~= state.reported then
            announceHitPointChange(unit, unit.hitPoints - state.reported)
            state.reported = unit.hitPoints
        end
        state.last = unit.hitPoints
        nextStates[unit.key] = state
    end
    battleUnitStates = nextStates
end

local function selectedTargetIds(units)
    local ids = {}
    for _, selection in ipairs(FindAllOf("CPP_VM_BtlCmdUnitSelect") or {}) do
        if selection:IsValid() and #ids == 0 then
            selection.targetUniqueIdList:ForEach(function(_, element)
                table.insert(ids, element:get())
            end)
        end
    end
    if #ids == 0 then
        for _, unit in ipairs(units) do
            if unit.viewModel.TargetSelectState == TARGET_STATE_MAIN then
                table.insert(ids, unit.id)
            end
        end
    end
    return ids
end

local function describeBattleTarget(unit)
    local name = battleUnitName(unit)
    -- Gegner-HP verraet auch das Spiel erst nach einer Analyse.
    if isEnemyUnit(unit) and not unit.viewModel.bIsAnalyzed then
        return name
    end
    return string.format("%s, %d von %d HP", name, unit.hitPoints, callFunction(unit.parameter, "GetMaxHitPoint") or 0)
end

local function findActivated(className)
    for _, screen in ipairs(FindAllOf(className) or {}) do
        if screen:IsValid() and screen:IsActivated() then
            return screen
        end
    end
    return nil
end

local function tickTargetSelection(units)
    if not findActivated("WBP_BtlCmd_UnitSelect_C") then
        lastTargetSelection = nil
        return
    end
    local ids = selectedTargetIds(units)
    if #ids > 0 then
        menuInfo.lastTargetIds = ids
    end
    local selection = table.concat(ids, ",")
    if selection == "" or selection == lastTargetSelection then
        return
    end
    lastTargetSelection = selection
    local unitsById = {}
    for _, unit in ipairs(units) do
        unitsById[unit.id] = unit
    end
    local descriptions = {}
    for _, id in ipairs(ids) do
        if unitsById[id] then
            table.insert(descriptions, describeBattleTarget(unitsById[id]))
        end
    end
    log("Zielauswahl: " .. selection .. " = " .. table.concat(descriptions, "; "))
    speak(table.concat(descriptions, "; "), true)
end

local function itemName(itemId)
    if not itemFunctions or not itemFunctions:IsValid() then
        itemFunctions = StaticFindObject("/Script/mucha.Default__CPP_BFL_Item")
    end
    local ok, text = pcall(function()
        return itemFunctions:GetItemName(itemId):ToString()
    end)
    return ok and text ~= "" and text or ("Gegenstand " .. tostring(itemId))
end

local function eachResultElement(array, callback)
    local ok, err = pcall(function()
        array:ForEach(function(_, element)
            callback(element:get())
        end)
    end)
    if not ok then
        log("Ergebnisliste fehlgeschlagen: " .. tostring(err))
    end
end

local function describeResult(data)
    local parts = {}
    if data.totalExperience > 0 then
        table.insert(parts, data.totalExperience .. " Erfahrung")
    end
    if data.totalMoney > 0 then
        table.insert(parts, data.totalMoney .. " Gil")
    end
    if data.totalAp > 0 then
        table.insert(parts, data.totalAp .. " AP")
    end
    eachResultElement(data.itemDataList, function(item)
        table.insert(parts, item.Num .. " mal " .. itemName(item.ItemId))
    end)
    eachResultElement(data.unitDataList, function(unit)
        if unit.afterBattleLevel > unit.beforeBattleLevel then
            table.insert(parts, "Stufenaufstieg auf Stufe " .. unit.afterBattleLevel)
        end
    end)
    return #parts > 0 and ("Erhalten: " .. table.concat(parts, ", ")) or "Nichts erhalten."
end

local function onResultData(_, resultData)
    local ok, summary = pcall(describeResult, resultData:get())
    if ok then
        log("Ergebnisdaten: " .. summary)
        resultSummary = summary
    else
        log("Ergebnisdaten fehlgeschlagen: " .. tostring(summary))
    end
end

-- Waehrend des Ladens schlaegt RegisterHook fehl, deshalb bei jedem Takt erneut versuchen.
local function tryRegisterResultHook()
    if resultHookState == "aktiv" then
        return
    end
    local ok, err = pcall(RegisterHook, RESULT_DATA_HOOK, onResultData)
    if ok then
        resultHookState = "aktiv"
        log("Ergebnis-Hook aktiv")
    elseif resultHookState == nil then
        resultHookState = "wartet"
        log("Ergebnis-Hook noch nicht moeglich: " .. tostring(err))
    end
end

local function beginBattle()
    battleActive, enemiesAnnounced = true, false
    resultAnnounced, resultSummary, resultTextSpoken = false, nil, nil
    battleUnitStates = {}
    log("Kampf beginnt")
    speak("Kampf beginnt.", false)
end

local function announceEnemies(units)
    local names = {}
    for _, unit in ipairs(units) do
        if isEnemyUnit(unit) then
            table.insert(names, battleUnitName(unit))
        end
    end
    if #names > 0 then
        enemiesAnnounced = true
        log("Gegner: " .. table.concat(names, ", "))
        speak("Gegner: " .. table.concat(names, ", "), false)
    end
end

-- Die Kampfansicht bleibt den ganzen Kampf aktiv, kurze Luecken beenden ihn nicht.
local function tickBattleEnd()
    local now = os.clock()
    battleEndSince = battleEndSince or now
    if now - battleEndSince >= BATTLE_END_DELAY_SECONDS then
        battleActive, battleEndSince = false, nil
        log("Kampf beendet")
        if not resultAnnounced then
            speak("Kampf beendet.", false)
        end
    end
end

-- Die Seiten wechseln per Eingabe im selben Bildschirm und sind selbst aktivierbar.
local function resultPageText(layout)
    local page = layout.WBP_BtlResultPage_Layout.WidgetSwitcher:GetActiveWidget()
    if not page or not page:IsValid() then
        return ""
    end
    return readTexts(page, { includeActivatable = true })
end

function menuInfo.splitParts(text)
    local parts = {}
    for part in (text .. ", "):gmatch("(.-), ") do
        table.insert(parts, part)
    end
    return parts
end

-- Teile der Seite, die noch nicht gesprochen wurden, in Reihenfolge der Anzeige. Gezaehlt wird je Text, weil
-- "St." oder "EP" mehrfach vorkommen und neue Zeilen (Bonus) die Positionen verschieben.
function menuInfo.unspokenParts(parts, spokenCounts)
    local remaining = {}
    for part, count in pairs(spokenCounts) do
        remaining[part] = count
    end
    local unspoken, indices = {}, {}
    for index, part in ipairs(parts) do
        if (remaining[part] or 0) > 0 then
            remaining[part] = remaining[part] - 1
        else
            table.insert(unspoken, part)
            table.insert(indices, index)
        end
    end
    return unspoken, indices
end

-- Spaeter hochgezaehlte Werte der Wachstumsseite ("Nächste St.: 365") brauchen die Figur dazu, sonst ist unklar,
-- wessen Wert es ist. Jede Figur steht als "St., 8, ..., Name".
function menuInfo.growthUpdate(parts, indices)
    local nameOf, blockOf = {}, {}
    local block = 0
    for index, part in ipairs(parts) do
        if part == "St." then
            block = block + 1
        end
        blockOf[index] = block
        nameOf[block] = part
    end
    local out, lastBlock = {}, nil
    for _, index in ipairs(indices) do
        local current = blockOf[index]
        if current > 0 and current ~= lastBlock and index ~= #parts and blockOf[index + 1] == current then
            table.insert(out, nameOf[current])
        end
        lastBlock = current
        if parts[index - 1] == "St." then
            table.insert(out, "St.")
        end
        table.insert(out, parts[index])
    end
    return table.concat(out, ", ")
end

-- Die Seiten zeigen den Namen hinter den Werten ("St., 8, ..., Lasswell"), gesprochen wird er zuerst.
function menuInfo.resultSpeech(text)
    local parts = menuInfo.splitParts(text)
    local out = {}
    if parts[1] == "Wachstum" then
        local block = nil
        local function flush()
            if block then
                table.insert(out, table.remove(block))
                table.move(block, 1, #block, #out + 1, out)
            end
        end
        for _, part in ipairs(parts) do
            if part == "St." then
                flush()
                block = {}
            end
            table.insert(block or out, part)
        end
        flush()
    elseif parts[1] == "Stufenanstieg" then
        for index, part in ipairs(parts) do
            if part == "St." and parts[index + 2] then
                table.insert(parts, index, table.remove(parts, index + 2))
                break
            end
        end
        out = parts
    else
        return text
    end
    return table.concat(out, ", ")
end

-- Wie im Spiel nacheinander: Was neu erscheint, kommt, sobald es nicht mehr hochzaehlt. Werte stehen vor dem
-- Zaehlen kurz auf 0; ab dort wartet die Ansage, damit Begriff und Wert zusammen kommen.
local function tickResultText(layout)
    local text = resultPageText(layout)
    local now = os.clock()
    if text ~= resultText then
        resultText, resultTextSince = text, now
        return
    end
    local stableFor = now - resultTextSince
    if text == "" or stableFor < RESULT_TEXT_STABLE_SECONDS then
        return
    end
    local parts = menuInfo.splitParts(text)
    -- Stufenanstieg zeigt Figur fuer Figur dieselben Begriffe, dort beginnt mit dem Namen eine neue Seite.
    local pageKey = parts[1] .. (parts[1] == "Stufenanstieg" and ("|" .. tostring(parts[5])) or "")
    if not resultTextSpoken or resultTextSpoken.page ~= pageKey then
        resultTextSpoken = { page = pageKey, counts = {} }
    end
    local unspoken, indices = menuInfo.unspokenParts(parts, resultTextSpoken.counts)
    if stableFor < menuInfo.RESULT_ZERO_HOLD_SECONDS then
        for index, part in ipairs(unspoken) do
            if part == "0" then
                unspoken = table.move(unspoken, 1, index - 1, 1, {})
                indices = table.move(indices, 1, index - 1, 1, {})
                break
            end
        end
    end
    if #unspoken == 0 then
        return
    end
    local firstOnPage = next(resultTextSpoken.counts) == nil
    for _, part in ipairs(unspoken) do
        resultTextSpoken.counts[part] = (resultTextSpoken.counts[part] or 0) + 1
    end
    log("Ergebnisseite: " .. text)
    if parts[1] == "Wachstum" and not firstOnPage then
        speak(menuInfo.growthUpdate(parts, indices), false)
    elseif not firstOnPage and #indices == 1 and parts[indices[1]]:match("^%d+$") and indices[1] > 1 then
        -- Ein einzeln nachgezaehlter Wert ("8" nach dem Bonus) kommt mit seinem Begriff ("Erhaltene MSP").
        speak(parts[indices[1] - 1] .. ", " .. unspoken[1], false)
    else
        speak(menuInfo.resultSpeech(table.concat(unspoken, ", ")), firstOnPage)
    end
end

local function tickBattleResult()
    local layout = findActivated("CPP_WBP_Btl_ResultLayout")
    resultVisible = layout ~= nil
    if not layout then
        return
    end
    if not resultAnnounced then
        resultAnnounced = true
        log("Ergebnisbildschirm: " .. shortClassName(layout))
    end
    tickResultText(layout)
end

-- Die Zielzeile ("Begib dich zu den Kolobos-Ruinen") steht in der Questanzeige unter dem Questnamen. Die Quest
-- selbst fuehrt sie nicht, sie kommt aus ST_MainProgress.
local function questObjective(questName)
    local first = nil
    for _, entry in ipairs(FindAllOf("WBP_PreferredQuest_Entry_C") or {}) do
        if entry:IsValid() then
            local objective = widgetText(entry.Text_SubTitle)
            if objective then
                if widgetText(entry.Text_Title) == questName then
                    return objective
                end
                first = first or objective
            end
        end
    end
    return first
end

local function describeCurrentQuest()
    local description = nil
    withCurrentQuest(function(quest)
        description = questObjective(textOf(quest.Name))
        if not description then
            local destination = textOf(quest.DestinationTitle)
            description = destination and ("Ziel: " .. destination)
        end
    end)
    if description then
        return description
    end
    local widget = FindFirstOf("WBP_PreferredQuest_C")
    local text = widget and widget:IsValid() and readTexts(widget, { staticOnly = true }) or ""
    return text ~= "" and text or nil
end

-- Aenderungen meldet das Spiel selbst ("Auftrag aktualisiert, ..."), eine eigene Ansage kam frueher und doppelt.
function readCurrentQuest()
    local text = describeCurrentQuest()
    log("Quest: " .. tostring(text))
    speak(text or "Kein Questziel verfügbar.", true)
end

function tickBattle()
    tryRegisterResultHook()
    if findActivated("WBP_BattleLayout_C") then
        battleEndSince = nil
        if not battleActive then
            beginBattle()
        end
    elseif battleActive then
        tickBattleEnd()
    end
    if battleActive then
        local units = readBattleUnits()
        if not enemiesAnnounced then
            announceEnemies(units)
        end
        tickHitPoints(units)
        tickTargetSelection(units)
    end
    if battleActive or resultVisible then
        tickBattleResult()
    end
end

end
defineBattleAndQuest()

-- Mit Umschalt melden sich unter Umstaenden beide Tastenbelegungen, die Kategorie hat Vorrang.
local function tickPathfinderKeys()
    local categorySteps, targetSteps, walkToggle = pendingCategorySteps, pendingTargetSteps, pendingWalkToggle
    pendingCategorySteps, pendingTargetSteps, pendingWalkToggle = 0, 0, false
    if categorySteps ~= 0 then
        stepCategory(categorySteps)
    elseif targetSteps ~= 0 then
        selectTarget(targetSteps)
    end
    if walkToggle then
        toggleWalk()
    end
end

-- Diagnose: Welche Sounds und Meldungen spielt das Spiel? Nur Log, keine Ansage.
local soundLog = {
    registered = {},
    failed = {},
    HOOKS = {
        "/Script/mucha.CPP_BFL_Sound:PlaySound2D",
        "/Script/mucha.CPP_BFL_Sound:PlaySound2DByTag",
        "/Script/mucha.CPP_SoundSubsystem:PlaySound2D",
        "/Script/mucha.CPP_SoundManager:PlaySound2D",
        "/Script/mucha.CPP_SoundManager:PlaySound2DByIndex",
        "/Script/mucha.CPP_SoundManager:PlaySound2DByID",
        "/Script/mucha.CPP_SoundManager:PlaySound3D",
        "/Script/mucha.CPP_BFL_Sound:PlaySound3D",
        "/Script/mucha.CPP_TalkEventSequenceDirectorBase:PlaySE",
        "/Script/mucha.CPP_TalkEventBlueprint:PlaySE",
        "/Script/mucha.CPP_VM_QuestNotice:PlayNoticeSound",
        "/Script/mucha.CPP_VM_QuestNotice:ExecuteNotics",
        "/Script/mucha.CPP_WBP_ChatNotice:BP_SetTitle",
    },
}

function soundLog.describe(param)
    local ok, text = pcall(function()
        local value = param:get()
        if type(value) ~= "userdata" then
            return tostring(value)
        end
        local stringOk, result = pcall(function()
            return value:ToString()
        end)
        return stringOk and result or value.TagName:ToString()
    end)
    return ok and text or "?"
end

function soundLog.noticeText()
    local notice = FindFirstOf("WBP_QuestNotice_C")
    local ok, text = pcall(function()
        return notice and notice:IsValid() and readTexts(notice, {})
    end)
    return ok and text or "?"
end

function soundLog.register()
    for _, path in ipairs(soundLog.HOOKS) do
        if not soundLog.registered[path] and StaticFindObject(path):IsValid() then
            local ok, err = pcall(RegisterHook, path, function(_, ...)
                local parts = {}
                for _, param in ipairs({ ... }) do
                    table.insert(parts, soundLog.describe(param))
                end
                local name = path:match(":(.+)$")
                if name == "PlayNoticeSound" or name == "ExecuteNotics" then
                    table.insert(parts, tostring(soundLog.noticeText()))
                end
                log("Sound " .. path:match("%.(.+)$") .. ": " .. table.concat(parts, ", "))
            end)
            if ok then
                soundLog.registered[path] = true
                log("Sound-Hook aktiv: " .. path)
            elseif not soundLog.failed[path] then
                soundLog.failed[path] = true
                log("Sound-Hook noch nicht moeglich: " .. path .. " " .. tostring(err))
            end
        end
    end
end

local tickHooks = guarded("Hook-Registrierung", function()
    tryRegisterFocusHooks()
    soundLog.register()
end)
local tickDiscovery = guarded("Hook-Suche", discoverFocusHooks)
local tickDialog = guarded("Dialog-Abfrage", tickDialogFocus)
local tickTalk = guarded("Gespraechs-Abfrage", tickTalkWindows)
local tickPaged = guarded("Seiten-Abfrage", tickPagedScreen)
local tickKeys = guarded("Pathfinder-Tasten", tickPathfinderKeys)
local tickWalking = guarded("Laufen", tickWalk)
local tickSteer = guarded("Steuerung", tickSteering)
local tickBattleStatus = guarded("Kampf-Abfrage", tickBattle)
local tickValue = guarded("Wert-Aktualisierung", refreshFocusedValue)
local tickScreen = guarded("Bildschirm-Abfrage", tickScreens)
navRoute.guardedPrompt = guarded("Tastenhinweis", navRoute.tickPrompt)
menuInfo.guardedCategory = guarded("Kategorie-Abfrage", menuInfo.tickCategory)
menuInfo.guardedTooltip = guarded("Tooltip-Abfrage", menuInfo.tickTooltip)
menuInfo.guardedEquipFigure = guarded("Figuren-Abfrage", menuInfo.tickEquipFigure)
menuInfo.guardedWorldMap = guarded("Weltkarten-Abfrage", menuInfo.tickWorldMap)
navRoute.guardedChain = guarded("Tuerweg", navRoute.tickChain)
navRoute.guardedJourney = guarded("Questreise", navRoute.tickJourney)
navGrid.guardedWalls = guarded("Wandtoene", navGrid.tickWalls)

LoopInGameThreadWithDelay(TICK_MS, function()
    tickHooks()
    tickDiscovery()
    tickDialog()
    tickTalk()
    tickPaged()
    tickKeys()
    tickWalking()
    navRoute.guardedChain()
    navRoute.guardedJourney()
    navGrid.guardedWalls()
    tickBattleStatus()
    navRoute.guardedPrompt()
    menuInfo.guardedCategory()
    menuInfo.guardedEquipFigure()
    menuInfo.guardedWorldMap()
    tickValue()
    tickScreen()
    menuInfo.guardedTooltip()
end)

LoopInGameThreadWithDelay(STEER_TICK_MS, tickSteer)
LoopInGameThreadWithDelay(STEER_TICK_MS, navGrid.safeTick)

RegisterKeyBind(Key.R, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(guarded("Bildschirm vorlesen", readCurrentScreen))
end)

RegisterKeyBind(Key.T, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(guarded("Wandtoene umschalten", navGrid.toggleWalls))
end)

RegisterKeyBind(Key.END, function()
    ExecuteInGameThread(guarded("Quest vorlesen", readCurrentQuest))
end)

RegisterKeyBind(Key.G, function()
    ExecuteInGameThread(guarded("Gil vorlesen", menuInfo.readMoney))
end)

RegisterKeyBind(Key.PAGE_UP, { ModifierKey.SHIFT }, function()
    pendingCategorySteps = pendingCategorySteps - 1
end)
RegisterKeyBind(Key.PAGE_DOWN, { ModifierKey.SHIFT }, function()
    pendingCategorySteps = pendingCategorySteps + 1
end)
RegisterKeyBind(Key.PAGE_UP, function()
    pendingTargetSteps = pendingTargetSteps - 1
end)
RegisterKeyBind(Key.PAGE_DOWN, function()
    pendingTargetSteps = pendingTargetSteps + 1
end)
RegisterKeyBind(Key.HOME, function()
    pendingWalkToggle = true
end)

loadNpcNames()
log("gestartet")
