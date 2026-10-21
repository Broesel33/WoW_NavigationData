-- Localization: every player-facing text (chat output, announcements, list and window labels, command help) lives in the
-- two tables at the end of this file. A deDE client gets German, every other client gets English; a missing German
-- translation falls back to English (AGENTS.md). The texts are string.format templates and the code refers to them only
-- by key through WowVisionNavigationText / Say / Warn / Print. Target names stay data (nameDe / nameEn).
WowVisionNavigationLocalization = {}
local L = WowVisionNavigationLocalization

-- Spoken DynTarget names (concept B3a): the row carries a name key and the place behind the crossing (nameAreaId = AreaTable ID,
-- nameMapId = map ID, nameParam = English name from the data as the fallback); the client names the place in its own
-- language (C_Map.GetAreaInfo / GetRealZoneText), the template comes from the table (dyn.<key>).
local function DynPlaceName(target)
    if type(target.nameAreaId) == "number" and C_Map and type(C_Map.GetAreaInfo) == "function" then
        local ok, name = pcall(C_Map.GetAreaInfo, target.nameAreaId)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if type(target.nameMapId) == "number" and type(GetRealZoneText) == "function" then
        local ok, name = pcall(GetRealZoneText, target.nameMapId)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if type(target.nameParam) == "string" and target.nameParam ~= "" then return target.nameParam end
    return nil
end

-- 4.54: targets of a zone that would be spoken alike carry a suffix from the export (lower/upper level, height or number)
local function NameSuffix(target)
    local suffix = target.nameSuffix
    if type(suffix) ~= "table" or type(suffix.key) ~= "string" then return "" end
    local template = L.Lookup("dyn.suffix." .. suffix.key)
    if template == nil then return "" end
    if template:find("%d", 1, true) then
        if type(suffix.value) ~= "number" then return "" end
        return string.format(template, suffix.value)
    end
    return template
end

local function DynName(target)
    local key = target.nameKey
    if type(key) ~= "string" or key == "" then return nil end
    local template = L.Lookup("dyn." .. key)
    if template == nil then return nil end
    if not template:find("%s", 1, true) then return template .. NameSuffix(target) end
    return string.format(template, DynPlaceName(target) or L.Lookup("dyn.unknown_destination") or "?") .. NameSuffix(target)
end

-- Target names are display data; stable IDs and routing remain locale independent.
function WowVisionNavigationTargetName(target)
    if type(target) ~= "table" then return "" end
    local spoken = DynName(target)
    if spoken then return spoken end
    local english = target.nameEn or target.nameEnglish
    local german = target.nameDe or target.nameGerman
    if WowVisionNavigationLocalization.IsGerman() and type(german) == "string" and german ~= "" then
        return german .. NameSuffix(target)
    end
    if type(english) == "string" and english ~= "" then return english .. NameSuffix(target) end
    if type(german) == "string" and german ~= "" then return german .. NameSuffix(target) end
    return tostring(target.id or "")
end

local PREFIX = "|cff33ff99[WowVision Navigation]|r "
local WARN_PREFIX = "|cffff3333[WowVision Navigation]|r "

-- What the client reports about its language (diagnosis, /vn lang): GetLocale(), the textLocale setting, GAME_LOCALE.
local function Reported(call, ...)
    if type(call) ~= "function" then return nil end
    local ok, value = pcall(call, ...)
    return ok and type(value) == "string" and value or nil
end

function L.Signals()
    return Reported(GetLocale), Reported(GetCVar, "textLocale"), type(_G.GAME_LOCALE) == "string" and _G.GAME_LOCALE or nil
end

local function IsGermanCode(code)
    return type(code) == "string" and code:lower():sub(1, 2) == "de"
end

-- German texts for a German client, English for everyone else (AGENTS.md). The language is decided at every call (never
-- cached at load time) from the saved choice (/vn lang de|en) or else from the client: a German text setting is enough,
-- GetLocale() alone is not trusted. A client that reports nothing German gets English.
function L.IsGerman()
    local db = _G.WowVisionNavigationDB
    local choice = type(db) == "table" and db.language or nil
    if choice == "de" then return true end
    if choice == "en" then return false end
    local locale, textLocale, gameLocale = L.Signals()
    return IsGermanCode(locale) or IsGermanCode(textLocale) or IsGermanCode(gameLocale)
end

-- The template for a key in the client language, nil if there is none (German falls back to English).
function L.Lookup(key)
    return (L.IsGerman() and L.de[key]) or L.en[key]
end

-- Formatted text. An unknown key is returned as it is, so that a missing entry is visible instead of silent.
function L.Text(key, ...)
    local text = L.Lookup(key)
    if text == nil then return tostring(key) end
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then return formatted end
    end
    return text
end

function WowVisionNavigationText(key, ...) return L.Text(key, ...) end
function WowVisionNavigationSay(key, ...) print(PREFIX .. L.Text(key, ...)) end
function WowVisionNavigationWarn(key, ...) print(WARN_PREFIX .. L.Text(key, ...)) end
-- Chat line with the addon prefix for a text that is already localized (reasons returned by other modules).
function WowVisionNavigationPrint(text) print(PREFIX .. tostring(text)) end

-- Display name of a target category key (the exporter writes English keys such as quest_giver).
function L.Category(key)
    local number = type(key) == "string" and key:match("^object_type_(%d+)$")
    if number then return L.Text("category.object_type", number) end
    return L.Lookup("category." .. tostring(key)) or tostring(key)
end

function WowVisionNavigationCategories(list)
    local names = {}
    for index, key in ipairs(list or {}) do names[index] = L.Category(key) end
    return table.concat(names, ", ")
end

-- Node types are the English keys terrain | indoor | water | unknown internally.
function WowVisionNavigationNodeTypeName(key) return L.Text("nodetype." .. tostring(key)) end

-- Command words: the German words stay valid and every German word has an English alias, on all clients. The core
-- works with the English word.
L.commandAliases = {
    sprache = "lang", komfort = "comfort", ankunft = "arrival",
    hier = "here", neu = "new", direkt = "direct", ebene = "level", fein = "fine", endanflug = "finalapproach",
    rueckfall = "fallback", ["rückfall"] = "fallback", aktion = "action", weiter = "continue",
    toleranz = "tolerance", leiche = "corpse", gruppe = "group", stopp = "stop", hilfe = "help",
}

function WowVisionNavigationNormalizeCommand(message)
    local word, rest = message:match("^(%S+)(.*)$")
    if not word then return message end
    local canonical = L.commandAliases[word] or (word:match("^r[uü]e?ckfall$") and "fallback")
    return canonical and (canonical .. rest) or message
end

L.helpKeys = { "help_title", "help_open", "help_direct", "help_here", "help_status", "help_stop", "help_prevnext", "help_new", "help_level", "help_radius", "help_finalapproach", "help_fallback", "help_showauto", "help_action", "help_live", "help_quest", "help_log", "help_lang", "help_comfort", "help_arrival", "help_key" }

-- /vn help: the command words of the client language.
function WowVisionNavigationHelp()
    for _, key in ipairs(L.helpKeys) do WowVisionNavigationSay(key) end
end


L.en = {
    -- routes and navigation
    ["recalc_manual"] = "Recalculated.",
    ["recalc_blocked"] = "The way there seems to be blocked.",
    ["height_not_confirmed"] = "The height is not confirmed. ",
    ["action_module_missing"] = "Action module missing",
    ["suffix_horizontal"] = " horizontally",
    -- target list
    ["enter_sets_start"] = "Enter sets the start point",
    ["enter_starts_route"] = "Enter starts the route",
    -- diagnostic log
    ["log_distance"] = " WaypointDistance=%.1f",
    ["log_comment"] = " Comment=%s",
    -- quests
    ["quest_area_questie"] = "Questie target area found",
    ["quest_area_blizzard"] = "Blizzard quest area found",
    -- commands
    ["state_on"] = "on",
    ["state_off"] = "off",
    ["ordinal_last"] = "last",
    ["ordinal_first"] = "first",
    -- docks
    ["vehicle_tram"] = "the Deeprun Tram",
    ["vehicle_boat"] = "the ship",
    ["vehicle_zeppelin"] = "the zeppelin",
    ["vehicle_lift"] = "the elevator",
    ["vehicle_other"] = "the vehicle",
    -- target selection
    ["desc_horizontal_unknown"] = " horizontal, height unknown",
    ["desc_vertical"] = " vertical",
    ["band_no_path"] = ", no network path from the current start",
    -- target categories (display names of the category keys written by the exporter)
    ["category.quest_giver"] = "quest giver",
    ["category.trainer"] = "trainer",
    ["category.vendor"] = "vendor",
    ["category.flight_master"] = "flight master",
    ["category.innkeeper"] = "innkeeper",
    ["category.banker"] = "banker",
    ["category.stable_master"] = "stable master",
    ["category.auctioneer"] = "auctioneer",
    ["category.spirit_healer"] = "spirit healer",
    ["category.spirit_guide"] = "spirit guide",
    ["category.npc_or_mob"] = "NPC or mob",
    ["category.door"] = "door",
    ["category.switch"] = "switch",
    ["category.quest_item"] = "quest item",
    ["category.chest"] = "chest",
    ["category.book"] = "book",
    ["category.object"] = "object",
    ["category.trap"] = "trap",
    ["category.chair"] = "chair",
    ["category.spell_focus"] = "spell focus",
    ["category.sign"] = "sign",
    ["category.interaction_object"] = "interaction object",
    ["category.mailbox"] = "mailbox",
    ["category.anvil"] = "anvil",
    ["category.forge"] = "forge",
    ["category.fishing_spot"] = "fishing spot",
    ["category.capture_point"] = "capture point",
    ["category.destructible_building"] = "destructible building",
    ["category.guild_bank"] = "guild bank",
    ["category.trapdoor"] = "trapdoor",
    ["category.herb_or_ore"] = "herb or ore",
    ["category.zone_transition"] = "zone transition",
    ["category.waypoint"] = "waypoint",
    ["category.orientation"] = "orientation",
    ["category.transit"] = "transit",
    ["category.transport"] = "transport",
    ["category.boat"] = "boat",
    ["category.tram"] = "tram",
    ["category.dungeon"] = "dungeon",
    ["category.portal"] = "portal",
    ["category.zeppelin"] = "zeppelin",
    ["category.lift"] = "lift",
    ["category.live"] = "live",
    ["category.object_type"] = "object type %s",
    -- node types
    ["nodetype.terrain"] = "terrain",
    ["nodetype.indoor"] = "indoor",
    ["nodetype.water"] = "water",
    ["nodetype.unknown"] = "unknown",
    -- automatic waypoints: names in the target list ("Auto: <English type>", both languages)
    ["autoname.water_exit"] = "Water exit",
    ["autoname.zone_border"] = "Zone border",
    ["autoname.action"] = "Action",
    ["autoname.gate"] = "Gate",
    ["autoname.level_change"] = "Level change",
    ["autoname.road_junction"] = "Road junction",
    ["autoname.target_access"] = "Target access",
    ["autoname.branch"] = "Branch",
    ["autoname.corner"] = "Corner",
    ["autoname.coverage"] = "Coverage",
    ["autoname.waypoint"] = "Waypoint",
    -- base codes of the waypoints (announcements)
    ["auto_prefix_z"] = "Auto: %s (Z %d)",   -- the height lets the player find re-entry points on the right level
    ["basecode.water_exit"] = "Water exit",
    ["basecode.zone_border"] = "Zone border",
    ["basecode.action"] = "Action",
    ["basecode.gate"] = "Gate",
    ["basecode.level_change"] = "Level change",
    ["basecode.road_junction"] = "Road junction",
    ["basecode.target_access"] = "Target access",
    ["basecode.branch"] = "Branch",
    ["basecode.corner"] = "Corner",
    ["basecode.coverage"] = "Coverage",
    ["basecode.waypoint"] = "Waypoint",
    -- live targets
    ["corpse_name"] = "Own corpse",
    -- help
    ["help_title"] = "Commands (German or English words work on every client):",
    ["help_open"] = "/vn - opens the target list for routes",
    ["help_direct"] = "/vn direct - free orientation to exactly one target (no route)",
    ["help_here"] = "/vn here - sets a start point (the NPC or place where you are standing)",
    ["help_status"] = "/vn status - shows the navigation state",
    ["help_stop"] = "/vn stop - ends the navigation",
    ["help_prevnext"] = "/vn prev, /vn next - one waypoint back or forward",
    ["help_new"] = "/vn new - recalculates the route from the current position",
    ["help_level"] = "/vn level <number> - chooses a height band when the target is ambiguous",
    ["help_radius"] = "/vn radius <yards>, /vn tolerance <yards> - attachment radius and height tolerance",
    ["help_finalapproach"] = "/vn finalapproach [on|off] - forced guidance shortly before choke points",
    ["help_fallback"] = "/vn fallback [on|off] - one waypoint back when drifting sideways in front of choke points",
    ["help_showauto"] = "/vn showauto On|Off - show automatic waypoints in the lists",
    ["help_action"] = "/vn action, /vn continue - instructions and confirmation at portals and vehicles",
    ["help_live"] = "/vn corpse, /vn group <unit> - the target is your own corpse or a group member",
    ["help_quest"] = "/vn q, /vn qselect <number>, /vn qprobe - quest area navigation and diagnostics",
    ["help_log"] = "/vn log [comment], /vn logshow, /vn logclear - diagnostic log",
    ["help_lang"] = "/vn lang [de|en|auto] - shows or sets the text language (auto = follow the game client)",
    ["help_comfort"] = "/vn comfort [0-300] - comfort level in percent (default 50): how much longer a route may be to stay on roads",
    ["help_arrival"] = "/vn arrival [yards] - minimum arrival radius at waypoints (0 = off, 10 at most); without a value it shows the setting",
    ["help_key"] = "Key I aligns you roughly to the current waypoint.",
    ["comfort_status"] = "Comfort level: %s percent (a road route may be up to %s times as long as the shortest one; 0 = always the shortest).",
    ["comfort_set"] = "Comfort level set to %s percent.",
    ["comfort_invalid"] = "Invalid comfort level '%s'. Use a number from 0 to 300, e.g. /vn comfort 50.",
    ["comfort_recalculated"] = "The running navigation is recalculated with the new level.",
    ["arrival_status"] = "Minimum arrival radius: %s yards. A waypoint counts as reached within the larger of this value and its own radius.",
    ["arrival_status_off"] = "Minimum arrival radius: off, the radii of the waypoints apply. Set one with /vn arrival 1.",
    ["arrival_set"] = "Minimum arrival radius set to %s yards.",
    ["arrival_off"] = "Minimum arrival radius turned off, the radii of the waypoints apply.",
    ["arrival_invalid"] = "Invalid arrival radius '%s'. Use a number from 0 to 10 yards, e.g. /vn arrival 1.5; 0 turns it off.",
    ["lang_status"] = "Text language: %s (setting: %s; client reports GetLocale=%s, textLocale=%s, GAME_LOCALE=%s). Change it with /vn lang de|en|auto.",
    ["lang_set"] = "Text language set to %s.",
    ["lang_usage"] = "Usage: /vn lang [de|en|auto]",
    ["lang_name_de"] = "German",
    ["lang_name_en"] = "English",
    ["lang_auto"] = "auto",
    ["lang_none"] = "none",
    -- routes and navigation
    ["route_recalculated"] = "%s New route with %d waypoints - go back to the last waypoint and then follow the tones.",
    ["recalc_no_alternative"] = "The way there seems to be blocked and there is no alternative route. Try going around it sideways or cancel with /vn stop.",
    ["boarding_no_direction_proof"] = "The boarding point has no valid direction proof on this map.",
    ["direct_invalid_coordinates"] = "This target has no valid coordinates; direct orientation not started.",
    ["direct_position_unavailable"] = "Player position currently unavailable; direct orientation not started.",
    ["direct_started"] = "Direct orientation to '%s' started: %.0f yards 2D straight line. No route; walk freely.",
    ["activation_proof_invalid"] = "The activation target has no valid proof contract.",
    ["player_position_unknown"] = "Could not determine your position. Are you in a supported zone?",
    ["floor_ambiguous"] = "Your floor is not unique at this position (height unclear). Use /vn here and choose a nearby known point or passage as the start.",
    ["no_network_attachment"] = "No attachment to the route network found at your position.",
    ["no_route_found"] = "No route to this target found.",
    ["action_route_invalid"] = "The action route has an invalid directed segment.",
    ["route_started_from"] = "Route from '%s' to '%s' started (%d waypoints).",
    ["route_started"] = "Route to '%s' started (%d waypoints).",
    ["approx_target"] = "Approximate target position.",
    ["arrival_not_bindable"] = "The arrival cannot be bound to the local target graph.",
    ["confirmed_exit"] = "confirmed exit",
    ["no_unique_start"] = "No unique start; use /vn here.",
    ["inexact_target_no_anchor"] = "An inexact target is no proven height anchor; choose a physical point with /vn here.",
    ["target_source_gone"] = "Target source no longer available; no route restarted.",
    ["stop_position_unavailable"] = "Player position unavailable; direct orientation ended.",
    ["stop_boarding_point_reached"] = "Boarding orientation point '%s' reached.",
    ["stop_boarding_proof_changed"] = "Boarding point proof or map changed; orientation ended.",
    ["stop_direct_reached"] = "Target '%s' reached; direct orientation ended.",
    ["stop_internal_error"] = "Internal error: waypoint not found.",
    ["stop_target_position_reached"] = "Target position '%s' reached!",
    ["prepoint_reached_unresolved"] = "Prepoint reached. The acoustic guidance keeps following the checked path to the local activation area.",
    ["prepoint_reached_go_through"] = "Prepoint reached. Walk straight ahead through the entrance or portal; the acoustic guidance stays active until the activation area.",
    ["activation_position_reached"] = "Position of the local activation area reached. %sA journey is not confirmed here; the route stays active.",
    ["activation_area_entered"] = "In the geometric activation area. Keep walking straight ahead; only an observed map change confirms the transition. The route stays active until then.",
    ["last_waypoint_careful"] = "Last physical waypoint reached. Move carefully towards the target; the last stretch is unchecked.",
    ["wait_proof_invalid"] = "The waiting point proof is invalid; no boarding instruction.",
    ["action_blocked"] = "Action blocked: %s",
    ["stop_water_net_ends"] = "The network ends %.1f yards from the water surface position; diving depth %.1f yards. Cover the remaining way and the diving yourself, the last stretch is unchecked.",
    ["stop_net_ends"] = "The network ends %.1f yards%s from the target; search the surroundings yourself. The last stretch is unchecked.",
    ["stop_safe_approach_reached"] = "Safe approach point for '%s' reached!",
    ["stop_target_reached"] = "Target '%s' reached!",
    -- target list
    ["list_title"] = "WowVision Navigation - target selection",
    ["list_hint_default"] = "Type to filter. Arrow keys: list. Enter: start route. Escape: close.",
    ["row_distance"] = " (%.0f yards)",
    ["row_in_zone"] = ", %s",
    ["entry_distance"] = ", %.0f yards away",
    ["entry_layer"] = ", level %d",
    ["selected_entry_speech"] = "%d of %d: %s [%s]%s%s%s",
    ["no_hits"] = "No hits for this filter.",
    ["no_target_selected"] = "No target selected.",
    ["start_point_set"] = "Start point set to '%s'. The next route with /vn starts from there.",
    ["dock_no_wait_proof"] = "The dock has no valid waiting point proof.",
    ["list_closed"] = "Target list closed.",
    ["enter_starts_direct"] = "Enter starts the direct orientation",
    ["list_hint_action"] = "Type to filter. Arrow keys: list. %s. Escape: close.",
    ["list_opened"] = "Target list opened, %d targets nearby sorted. Type to filter, arrow keys up/down to browse, Home/End to jump to the start/end, %s, Escape closes the list.",
    -- WowVision window
    ["wv_filter_label"] = "Enter a filter and confirm with Enter (from 2 letters)",
    ["wv_filter_hint"] = "Enter updates the result list",
    ["wv_info_start"] = "Choose the NPC or place where you are standing now as the start point",
    ["wv_info_direct"] = "Direct orientation without a route: choose a target by distance",
    ["wv_info_target"] = "Nearest reachable targets, sorted by distance",
    ["wv_no_targets"] = "No targets found",
    ["i_correction_failed"] = "I follow-up correction failed: %s",
    ["i_alignment_failed"] = "I alignment failed: %s",
    ["wv_window_failed"] = "WowVision window failed (%s), using the simple target window.",
    -- diagnostic log
    ["log_entry"] = "#%d [%s] Zone=%s/%s Map=%s norm=(%.4f,%.4f) world=(%s,%s) Facing=%.2f Target=%s%s%s",
    -- quests
    ["quest_none_selected"] = "No quest selected. Open the quest log with WowVision and choose a concrete quest.",
    ["quest_modern_no_info"] = "The modern quest log API returns no entry information. No route was started.",
    ["quest_modern_unreadable"] = "The modern quest log API could not read the quest entries. No route was started.",
    ["quest_modern_no_entry"] = "The modern quest log selection does not point to a concrete quest entry. No route was started.",
    ["quest_api_unavailable"] = "The quest log API is not available on this client.",
    ["quest_selection_not_quest"] = "The WowVision selection is not a concrete quest. Please choose a quest entry instead of a zone header.",
    ["probe_saved_no_quest"] = "Quest probe #%d saved, but no quest is selected. Open the quest log with WowVision, choose a concrete quest and run /vn qprobe again.",
    ["probe_saved"] = "Quest probe #%d saved: '%s', quest ID %s, %d objective(s). No route was started.",
    ["probe_reload_hint"] = "For permanent evaluation run /reload now or log out.",
    ["questie_no_point"] = "Questie delivers no routable target point for the next open objective of the selected quest '%s'. No route was started.",
    ["no_point_anywhere"] = "Neither Blizzard nor the optional Questie database deliver a routable target point for the selected quest '%s'. No route was started.",
    ["quest_map_unsupported"] = "The map of the quest target is not supported yet. No route was started.",
    ["quest_area_name"] = "Quest area: %s",
    ["quest_area_found"] = "%s; the coordinate is resolved in the physical network without a fixed target binding.",
    ["quest_modern_unreadable_short"] = "The modern quest log API could not read the quest entries.",
    ["quest_classic_unreadable"] = "The classic quest log API could not read the quest entries.",
    ["qselect_usage_number"] = "Use /vn qselect with a positive whole number, for example /vn qselect 1.",
    ["qselect_only_n"] = "There are only %d concrete quest(s) in the quest log.",
    ["qselect_modern_failed"] = "The modern quest log selection failed: %s",
    ["qselect_classic_failed"] = "The classic quest log selection failed: %s",
    ["qselect_unsupported"] = "This client provides no function to select a quest.",
    -- commands
    ["stop_manual"] = "Navigation ended manually.",
    ["action_module_unavailable"] = "Action module not available.",
    ["action_no_phase"] = "No matching action phase.",
    ["status_direct_distance"] = ", %.0f yards 2D straight line",
    ["status_direct"] = "Direct orientation to '%s'%s; no route and no intermediate waypoints.",
    ["status_direct_note"] = "Final approach and choke-point fallback do not apply to the direct orientation.",
    ["status_en_route"] = "On the way to '%s', waypoint %d of %d.",
    ["no_active_navigation"] = "No active navigation.",
    ["status_final_approach"] = "Final-approach guidance (only left/right/away on the last %.1f yards before a choke point): %s (/vn finalapproach to toggle).",
    ["status_choke_fallback"] = "Choke-point fallback (when drifting sideways in front of a choke point, go back one waypoint): %s (/vn fallback to toggle).",
    ["status_sku_tone"] = "SKU navigation tone: nav%s (fixed default tone).",
    ["direct_list_position_unavailable"] = "Player position currently unavailable; direct target list not opened.",
    ["direct_no_waypoints"] = "The direct orientation has no intermediate waypoints. You can end it with /vn stop.",
    ["already_at_waypoint"] = "Already at the %s waypoint of the path.",
    ["waypoint_selected"] = "Waypoint %d of %d selected (type: %s).",
    ["showauto_usage"] = "Use /vn showauto On or /vn showauto Off.",
    ["showauto_status"] = "Show automatic points: %s.",
    ["autonew_removed"] = "Automatic recalculation on blockage no longer exists. You recalculate a new route yourself with /vn new.",
    ["fine_removed"] = "The former fine bearing has been replaced by the 5-degree SKU beacons. The fixed default tone nav%s is active.",
    ["finalapproach_usage"] = "Unknown value. Use /vn finalapproach on or /vn finalapproach off (without a value it is toggled).",
    ["finalapproach_on"] = "Final-approach guidance ON (default). On the last two and a half meters before a choke point you only hear three commands: tone left = target is on the left, tone right = target is on the right, tone back = you are looking away. Turn until the side flips - the alignment click lies in between, and on that course you fit through.",
    ["finalapproach_off"] = "Final-approach guidance OFF. The normal direction announcement applies again even right before a choke point.",
    ["fallback_usage"] = "Unknown value. Use /vn fallback on or /vn fallback off (without a value it is toggled).",
    ["fallback_on"] = "Choke-point fallback ON (default). If you stray sideways from the route in front of a narrow spot and get stuck there, I automatically guide you back one waypoint instead of continuing to point you at the gap.",
    ["fallback_off"] = "Choke-point fallback OFF. You then always stay aligned to the next waypoint; you can step back by hand with /vn prev.",
    ["direct_no_recalculation"] = "The direct orientation has no route to recalculate. Choose a route target with /vn.",
    ["position_not_determinable"] = "Position currently not determinable, please walk a little and try again.",
    ["qselect_done"] = "Quest %s selected: %s (quest ID %d).",
    ["qselect_usage"] = "Use /vn qselect 1, /vn qselect 2 and so on. Headers are not counted.",
    ["log_saved"] = "Diagnostic entry saved: %s",
    ["log_total"] = "In total %d entries. /vn logshow to display them, /reload or log out to save permanently.",
    ["log_none"] = "No diagnostic entries yet.",
    ["log_cleared"] = "Diagnostic log cleared.",
    ["unknown_command"] = "Unknown command. /vn opens route targets, /vn direct the free target orientation, /vn here sets a start point. /vn help lists all commands.",
    ["command_error"] = "ERROR: %s",
    -- key I alignment
    ["i_no_alignment_target"] = "No safely proven alignment target for the I key.",
    ["i_unsupported"] = "This client does not provide the safe I alignment.",
    ["position_or_facing_unknown"] = "Position or facing currently not determinable.",
    ["waypoint_already_reached"] = "The current waypoint has already been reached.",
    -- zone loader
    ["reason_activation_map_changed"] = "Native map change observed after the activation area; journey order ended. Destination not confirmed.",
    ["reason_map_changed_guidance_done"] = "Map change observed; activation guidance finished.",
    ["zone_load_failed"] = "%s The route network is not built for safety reasons; please check the addon files. Other zones stay usable; this zone is only loaded again after /reload.",
    ["zone_data_invalid"] = "Zone data '%s' is invalid: %s.",
    ["catalog_invalid"] = "Target catalog invalid: %s.",
    ["zone_data_activated"] = "Zone data for %s activated.",
    ["stop_zone_changed"] = "Navigation ended because of a zone change.",
    ["zone_file_not_loaded"] = "The zone file for '%s' is not loaded.",
    ["stop_outside_zones"] = "Navigation ended outside a supported zone.",
    ["zone_data_not_ready"] = "No navigation data is ready for the current zone yet. If the map position is unknown, it is checked again automatically.",
    -- startup
    ["startup_banner"] = "Core loaded; zone data is only loaded in a supported zone. /vn opens route targets, /vn direct the free target orientation, /vn here sets the start point, /vn status, /vn stop, /vn prev, /vn next, /vn new, /vn showauto On|Off, /vn finalapproach on|off (forced guidance shortly before choke points, currently %s), /vn fallback on|off (one waypoint back when drifting sideways in front of a choke point, currently %s), the I key aligns you roughly to the current target point, SKU navigation tone nav%s (fixed default tone). /vn help lists all commands.",
    ["startup_quest_select"] = "Select a quest: /vn qselect 1, /vn qselect 2 and so on; quest log headers are not counted.",
    ["startup_quest_probe"] = "Quest API diagnostics: /vn qprobe. To the target of the selected quest: /vn q.",
    -- actions
    ["action_nav_data_missing"] = "NavData missing",
    ["action_zone_mismatch"] = "Action target zone or transit phase does not match",
    ["action_payload_invalid"] = "Action payload invalid or duplicate",
    ["action_conditions_missing"] = "Conditions missing",
    ["action_entry_unconfirmed"] = "Entry not confirmed",
    ["action_entry_unknown"] = "Entry unknown",
    ["action_missing"] = "Action missing",
    ["action_approach_prepoint"] = "Go to the safe prepoint of %s.",
    ["action_waiting"] = "Wait at the prepoint. /vn action repeats the instructions; /vn continue only confirms this action.",
    ["action_none_active_short"] = "No active action",
    ["action_boarding"] = "Only board when the vehicle is safely present; then confirm with /vn continue.",
    ["action_activating"] = "Use the portal or entrance yourself; the arrival is only confirmed after the matching target signal.",
    ["action_boarded"] = "Boarding confirmed. The ride is running; wait for a safe stop.",
    ["action_activated"] = "Activation confirmed. Target map and arrival are being checked.",
    ["action_no_confirmation"] = "No confirmation is possible in this phase",
    ["action_cancelled"] = "Action cancelled: %s",
    ["action_arrival_proven"] = "Arrival proven. Disembark safely and reach the prepoint.",
    ["action_complete"] = "Action completed; the route continues.",
    ["action_timeout"] = "Action cancelled because of a timeout.",
    ["action_none_active"] = "No active action.",
    ["action_status"] = "Action %s: %s.",
    -- docks
    ["dock_reached"] = "Dock '%s' reached. Wait here for %s. Board when you hear the arrival.",
    ["dock_boarding_hint"] = " A direction tone shows the boarding direction; with I you can also align yourself.",
    ["dock_passive_set"] = "Counterpart dock '%s' noted. Wait for the vehicle, board by ear and get off at the destination stop. Afterwards choose the dock again for a local route.",
    -- target resolver
    ["res_stale"] = "Target position is outdated",
    ["res_no_native_map"] = "Native map binding missing",
    ["res_other_map"] = "Different native map",
    ["res_band_invalid"] = "Height band invalid",
    ["res_ambiguous"] = "Several height bands; /vn level <number>",
    ["res_z_conflict"] = "The known target height fits no network band; /vn level <number>",
    ["res_no_point"] = "No admissible network point within the attachment radius",
    ["res_no_path"] = "No admissible network path within the attachment radius",
    -- target selection
    ["desc_inexact"] = " (inexact +%.1f yards%s)",
    ["desc_pick_height"] = " (choose height)",
    ["desc_level_unknown"] = " (level unknown)",
    ["res_level_unknown"] = "Level of the target unknown; /vn level <number>",
    ["level_prompt"] = "The level of this target is unknown. /vn level <number> chooses the level:",
    ["level_line"] = "%d: level at Z %.1f%s",
    ["desc_no_point"] = " (no admissible network point within the radius)",
    ["desc_water"] = " (water surface, diving depth %.1f yards)",
    ["band_prompt"] = "Target height unknown. /vn level <number> chooses a height band:",
    ["dyn.dungeon_entrance"] = "Dungeon entrance: %s",
    ["dyn.portal"] = "Portal to %s",
    ["dyn.dock_ship"] = "Ship dock to %s",
    ["dyn.dock_zeppelin"] = "Zeppelin dock to %s",
    ["dyn.on_ship"] = "On the ship to %s",
    ["dyn.tram_entrance"] = "Deeprun Tram entrance",
    ["dyn.tram_dock"] = "Tram dock toward %s",
    ["dyn.in_tram"] = "In the tram toward %s",
    ["dyn.elevator"] = "Elevator: %s",
    ["dyn.zone_transition"] = "Crossing to %s",
    ["dyn.unknown_destination"] = "unknown destination",
    ["dyn.suffix.lower"] = " (lower)",
    ["dyn.suffix.upper"] = " (upper)",
    ["dyn.suffix.z"] = " (Z %d)",
    ["dyn.suffix.number"] = " (%d)",
    ["dyn.boarding_boat"] = "On the ship",
    ["dyn.boarding_zeppelin"] = "On the zeppelin",
    ["dyn.boarding_vehicle"] = "At the vehicle",
    ["band_prompt_conflict"] = "The known target height fits no network band. /vn level <number> chooses a height band:",
    ["res_no_route_from_start"] = "There is no network path from the current position to the target. Try /vn new at another place.",
    ["band_line"] = "%d: Z %.1f–%.1f, nearest network point %.1f yards%s",
    ["target_unresolvable"] = "Target cannot be resolved",
    ["invalid_value"] = "Invalid value; the setting is kept.",
    ["radius_status"] = "Attachment radius %.1f yards (XY); height band tolerance %.1f yards (total Z span).",
    ["no_open_level_selection"] = "No valid open level selection.",
    ["start_not_determined"] = "The current start is not safely determined; the level selection stays open.",
    ["group_usage"] = "/vn group party1..party4, raid1..raid40 or target",
    ["no_live_coordinates"] = "No valid live target coordinates available.",
}

L.de = {
    -- routes and navigation
    ["recalc_manual"] = "Neu berechnet.",
    ["recalc_blocked"] = "Der Weg dort scheint versperrt.",
    ["height_not_confirmed"] = "Die Hoehe ist nicht bestaetigt. ",
    ["action_module_missing"] = "Aktionsmodul fehlt",
    ["suffix_horizontal"] = " horizontal",
    -- target list
    ["enter_sets_start"] = "Enter setzt den Startpunkt",
    ["enter_starts_route"] = "Enter startet die Route",
    -- diagnostic log
    ["log_distance"] = " DistanzWegpunkt=%.1f",
    ["log_comment"] = " Kommentar=%s",
    -- quests
    ["quest_area_questie"] = "Questie-Zielgebiet gefunden",
    ["quest_area_blizzard"] = "Blizzard-Questgebiet gefunden",
    -- commands
    ["state_on"] = "an",
    ["state_off"] = "aus",
    ["ordinal_last"] = "letzten",
    ["ordinal_first"] = "ersten",
    -- docks
    ["vehicle_tram"] = "die Tiefenbahn",
    ["vehicle_boat"] = "das Schiff",
    ["vehicle_zeppelin"] = "den Zeppelin",
    ["vehicle_lift"] = "den Aufzug",
    ["vehicle_other"] = "das Transportmittel",
    -- target selection
    ["desc_horizontal_unknown"] = " horizontal, Höhe unbekannt",
    ["desc_vertical"] = " vertikal",
    ["band_no_path"] = ", kein Netzweg vom aktuellen Start",
    -- target categories (display names of the category keys written by the exporter)
    ["category.quest_giver"] = "questgeber",
    ["category.trainer"] = "ausbilder",
    ["category.vendor"] = "haendler",
    ["category.flight_master"] = "flugmeister",
    ["category.innkeeper"] = "gasthausbesitzer",
    ["category.banker"] = "bankier",
    ["category.stable_master"] = "stallmeister",
    ["category.auctioneer"] = "auktionator",
    ["category.spirit_healer"] = "geistheiler",
    ["category.spirit_guide"] = "geistführer",
    ["category.npc_or_mob"] = "npc_oder_mob",
    ["category.door"] = "tuer",
    ["category.switch"] = "schalter",
    ["category.quest_item"] = "questgegenstand",
    ["category.chest"] = "kiste",
    ["category.book"] = "buch",
    ["category.object"] = "objekt",
    ["category.trap"] = "falle",
    ["category.chair"] = "stuhl",
    ["category.spell_focus"] = "zauberfokus",
    ["category.sign"] = "schild",
    ["category.interaction_object"] = "interaktionsobjekt",
    ["category.mailbox"] = "briefkasten",
    ["category.anvil"] = "amboss",
    ["category.forge"] = "schmiede",
    ["category.fishing_spot"] = "angelstelle",
    ["category.capture_point"] = "eroberungspunkt",
    ["category.destructible_building"] = "zerstoerbares_gebaeude",
    ["category.guild_bank"] = "gildenbank",
    ["category.trapdoor"] = "falltuer",
    ["category.herb_or_ore"] = "rohstoff_kraut_oder_erz",
    ["category.zone_transition"] = "uebergang",
    ["category.waypoint"] = "wegpunkt",
    ["category.orientation"] = "orientierung",
    ["category.transit"] = "transit",
    ["category.transport"] = "transport",
    ["category.boat"] = "schiff",
    ["category.tram"] = "tiefenbahn",
    ["category.dungeon"] = "dungeon",
    ["category.portal"] = "portal",
    ["category.zeppelin"] = "zeppelin",
    ["category.lift"] = "aufzug",
    ["category.live"] = "live",
    ["category.object_type"] = "objekt_typ_%s",
    -- node types
    ["nodetype.terrain"] = "gelaende",
    ["nodetype.indoor"] = "rauminnen",
    ["nodetype.water"] = "wasser",
    ["nodetype.unknown"] = "unbekannt",
    -- automatic waypoints: names in the target list ("Auto: <English type>", both languages)
    ["autoname.water_exit"] = "Water exit",
    ["autoname.zone_border"] = "Zone border",
    ["autoname.action"] = "Action",
    ["autoname.gate"] = "Gate",
    ["autoname.level_change"] = "Level change",
    ["autoname.road_junction"] = "Road junction",
    ["autoname.target_access"] = "Target access",
    ["autoname.branch"] = "Branch",
    ["autoname.corner"] = "Corner",
    ["autoname.coverage"] = "Coverage",
    ["autoname.waypoint"] = "Waypoint",
    -- base codes of the waypoints (announcements)
    ["auto_prefix_z"] = "Auto: %s (Z %d)",   -- the height lets the player find re-entry points on the right level
    ["basecode.water_exit"] = "Wasserausstieg",
    ["basecode.zone_border"] = "Zonengrenze",
    ["basecode.action"] = "Aktion",
    ["basecode.gate"] = "Tor",
    ["basecode.level_change"] = "Treppe",
    ["basecode.road_junction"] = "Straßenkreuzung",
    ["basecode.target_access"] = "Zielzugang",
    ["basecode.branch"] = "Abzweigung",
    ["basecode.corner"] = "Ecke",
    ["basecode.coverage"] = "Abdeckung",
    ["basecode.waypoint"] = "Wegpunkt",
    -- live targets
    ["corpse_name"] = "Eigene Leiche",
    -- help
    ["help_title"] = "Befehle (deutsche oder englische Woerter gelten auf jedem Client):",
    ["help_open"] = "/vn - oeffnet die Zielliste fuer Routen",
    ["help_direct"] = "/vn direkt - freie Orientierung zu genau einem Ziel (ohne Route)",
    ["help_here"] = "/vn hier - setzt einen Startpunkt (der NPC oder Ort, an dem du stehst)",
    ["help_status"] = "/vn status - zeigt den Stand der Navigation",
    ["help_stop"] = "/vn stop - beendet die Navigation",
    ["help_prevnext"] = "/vn prev, /vn next - einen Wegpunkt zurueck bzw. vor",
    ["help_new"] = "/vn neu - berechnet die Route von der aktuellen Position neu",
    ["help_level"] = "/vn ebene <Nummer> - waehlt einen Hoehenbereich, wenn das Ziel mehrdeutig ist",
    ["help_radius"] = "/vn radius <Yards>, /vn toleranz <Yards> - Anschlussradius und Hoehentoleranz",
    ["help_finalapproach"] = "/vn endanflug [an|aus] - Zwangsfuehrung kurz vor Engstellen",
    ["help_fallback"] = "/vn rueckfall [an|aus] - einen Wegpunkt zurueck bei seitlichem Abdriften vor Engstellen",
    ["help_showauto"] = "/vn showauto On|Off - automatische Wegpunkte in den Listen anzeigen",
    ["help_action"] = "/vn aktion, /vn weiter - Anleitung und Bestaetigung bei Portalen und Transportmitteln",
    ["help_live"] = "/vn leiche, /vn gruppe <Einheit> - Ziel ist die eigene Leiche bzw. ein Gruppenmitglied",
    ["help_quest"] = "/vn q, /vn qselect <Nummer>, /vn qprobe - Questgebiet-Navigation und Diagnose",
    ["help_log"] = "/vn log [Kommentar], /vn logshow, /vn logclear - Diagnoseprotokoll",
    ["help_lang"] = "/vn sprache [de|en|auto] - zeigt oder setzt die Textsprache (auto = der Spielclient bestimmt sie)",
    ["help_comfort"] = "/vn komfort [0-300] - Komfortstufe in Prozent (Standard 50): wie viel laenger eine Route sein darf, um auf Strassen zu bleiben",
    ["help_arrival"] = "/vn ankunft [Yards] - Mindest-Ankunftsradius an Wegpunkten (0 = aus, höchstens 10); ohne Wert nennt der Befehl die Einstellung",
    ["help_key"] = "Taste I richtet dich ungefaehr zum aktuellen Wegpunkt aus.",
    ["comfort_status"] = "Komfortstufe: %s Prozent (eine Strassenroute darf bis zu %s mal so lang sein wie die kuerzeste; 0 = immer die kuerzeste).",
    ["comfort_set"] = "Komfortstufe auf %s Prozent gestellt.",
    ["comfort_invalid"] = "Ungueltige Komfortstufe '%s'. Gib eine Zahl von 0 bis 300 an, z. B. /vn komfort 50.",
    ["comfort_recalculated"] = "Die laufende Navigation wird mit der neuen Stufe neu berechnet.",
    ["arrival_status"] = "Mindest-Ankunftsradius: %s Yards. Ein Wegpunkt gilt als erreicht, sobald du innerhalb des größeren Wertes aus dieser Einstellung und seinem eigenen Radius bist.",
    ["arrival_status_off"] = "Mindest-Ankunftsradius: aus, es gelten die Radien der Wegpunkte. Stelle einen mit /vn ankunft 1 ein.",
    ["arrival_set"] = "Mindest-Ankunftsradius auf %s Yards gestellt.",
    ["arrival_off"] = "Mindest-Ankunftsradius ausgeschaltet, es gelten die Radien der Wegpunkte.",
    ["arrival_invalid"] = "Ungültiger Ankunftsradius '%s'. Gib eine Zahl von 0 bis 10 Yards an, z. B. /vn ankunft 1,5; 0 schaltet ihn aus.",
    ["lang_status"] = "Textsprache: %s (Einstellung: %s; Client meldet GetLocale=%s, textLocale=%s, GAME_LOCALE=%s). Aendern mit /vn sprache de|en|auto.",
    ["lang_set"] = "Textsprache auf %s gestellt.",
    ["lang_usage"] = "Benutzung: /vn sprache [de|en|auto]",
    ["lang_name_de"] = "Deutsch",
    ["lang_name_en"] = "Englisch",
    ["lang_auto"] = "auto",
    ["lang_none"] = "keine",
    -- routes and navigation
    ["route_recalculated"] = "%s Neue Route mit %d Wegpunkten - geh zurueck zum letzten Wegpunkt und folge dann den Toenen.",
    ["recalc_no_alternative"] = "Der Weg dort scheint versperrt und es gibt keine Ausweichroute. Versuch es seitlich oder brich mit /vn stop ab.",
    ["boarding_no_direction_proof"] = "Einsteigpunkt hat keinen gueltigen Richtungsnachweis auf dieser Karte.",
    ["direct_invalid_coordinates"] = "Dieses Ziel hat keine gueltigen Koordinaten; direkte Orientierung nicht gestartet.",
    ["direct_position_unavailable"] = "Spielerposition gerade nicht verfuegbar; direkte Orientierung nicht gestartet.",
    ["direct_started"] = "Direkte Orientierung zu '%s' gestartet: %.0f Yards 2D-Luftlinie. Keine Route; laufe frei.",
    ["activation_proof_invalid"] = "Aktivierungsziel hat keinen gueltigen Proof-Vertrag.",
    ["player_position_unknown"] = "Spielerposition konnte nicht ermittelt werden. Bist du in einer unterstuetzten Zone?",
    ["floor_ambiguous"] = "Dein Stockwerk ist an dieser Position nicht eindeutig (Hoehe unklar). Nutze /vn hier und waehle einen nahen bekannten Punkt oder Durchgang als Start.",
    ["no_network_attachment"] = "Kein Anschluss an das Wegenetz an deiner Position gefunden.",
    ["no_route_found"] = "Keine Route zu diesem Ziel gefunden.",
    ["action_route_invalid"] = "Aktionsroute hat einen ungueltigen gerichteten Abschnitt.",
    ["route_started_from"] = "Route von '%s' zu '%s' gestartet (%d Wegpunkte).",
    ["route_started"] = "Route zu '%s' gestartet (%d Wegpunkte).",
    ["approx_target"] = "Ungefaehre Zielposition.",
    ["arrival_not_bindable"] = "Ankunft kann nicht an den lokalen Zielgraphen gebunden werden.",
    ["confirmed_exit"] = "bestaetigter Ausstieg",
    ["no_unique_start"] = "Kein eindeutiger Start; /vn hier verwenden.",
    ["inexact_target_no_anchor"] = "Ungenaues Ziel ist kein bewiesener Höhenanker; physischen Punkt mit /vn hier wählen.",
    ["target_source_gone"] = "Zielquelle nicht mehr verfügbar; keine Route neu gestartet.",
    ["stop_position_unavailable"] = "Spielerposition nicht verfuegbar; direkte Orientierung beendet.",
    ["stop_boarding_point_reached"] = "Einsteig-Orientierungspunkt '%s' erreicht.",
    ["stop_boarding_proof_changed"] = "Einsteigpunkt-Nachweis oder Karte geaendert; Orientierung beendet.",
    ["stop_direct_reached"] = "Ziel '%s' erreicht; direkte Orientierung beendet.",
    ["stop_internal_error"] = "Interner Fehler: Wegpunkt nicht gefunden.",
    ["stop_target_position_reached"] = "Zielposition '%s' erreicht!",
    ["prepoint_reached_unresolved"] = "Vorpunkt erreicht. Die akustische Fuehrung folgt weiter dem geprueften Weg zur lokalen Aktivierungsflaeche.",
    ["prepoint_reached_go_through"] = "Vorpunkt erreicht. Gehe geradeaus durch den Eingang oder das Portal; die akustische Fuehrung bleibt bis zur Aktivierungsflaeche aktiv.",
    ["activation_position_reached"] = "Position der lokalen Aktivierungsflaeche erreicht. %sEine Reise ist hier nicht bestaetigt; die Route bleibt aktiv.",
    ["activation_area_entered"] = "Im geometrischen Aktivierungsbereich. Gehe geradeaus weiter; erst ein beobachteter Kartenwechsel bestaetigt den Uebergang. Die Route bleibt bis dahin aktiv.",
    ["last_waypoint_careful"] = "Letzter physischer Wegpunkt erreicht. Bewege dich vorsichtig aufs Ziel zu; die letzte Strecke ist ungeprüft.",
    ["wait_proof_invalid"] = "Wartepunkt-Nachweis ist ungueltig; keine Einsteiganweisung.",
    ["action_blocked"] = "Aktion gesperrt: %s",
    ["stop_water_net_ends"] = "Netz endet %.1f Yards von der Wasseroberflächenposition; Tauchtiefe %.1f Yards. Restlichen Weg und Tauchen selbst übernehmen, letzte Strecke ungeprüft.",
    ["stop_net_ends"] = "Netz endet %.1f Yards%s vom Ziel; Umgebung selbst absuchen. Letzte Strecke ungeprüft.",
    ["stop_safe_approach_reached"] = "Sicherer Annaeherungspunkt fuer '%s' erreicht!",
    ["stop_target_reached"] = "Ziel '%s' erreicht!",
    -- target list
    ["list_title"] = "WowVision Navigation - Zielauswahl",
    ["list_hint_default"] = "Tippen zum Filtern. Pfeiltasten: Liste. Enter: Route starten. Escape: Schliessen.",
    ["row_distance"] = " (%.0f Yards)",
    ["row_in_zone"] = ", %s",
    ["entry_distance"] = ", %.0f Yards entfernt",
    ["entry_layer"] = ", Ebene %d",
    ["selected_entry_speech"] = "%d von %d: %s [%s]%s%s%s",
    ["no_hits"] = "Keine Treffer fuer diesen Filter.",
    ["no_target_selected"] = "Kein Ziel ausgewaehlt.",
    ["start_point_set"] = "Startpunkt auf '%s' gesetzt. Naechste Route mit /vn startet von dort aus.",
    ["dock_no_wait_proof"] = "Anleger hat keinen gueltigen Wartepunkt-Nachweis.",
    ["list_closed"] = "Zielliste geschlossen.",
    ["enter_starts_direct"] = "Enter startet die direkte Orientierung",
    ["list_hint_action"] = "Tippen zum Filtern. Pfeiltasten: Liste. %s. Escape: Schliessen.",
    ["list_opened"] = "Zielliste geoeffnet, %d Ziele in der Naehe sortiert. Tippen zum Filtern, Pfeiltasten Hoch/Runter zum Durchblaettern, Pos1/Ende zum Sprung an Anfang/Ende, %s, Escape schliesst die Liste.",
    -- WowVision window
    ["wv_filter_label"] = "Filter eingeben und mit Enter bestaetigen (ab 2 Buchstaben)",
    ["wv_filter_hint"] = "Enter aktualisiert die Ergebnisliste",
    ["wv_info_start"] = "Waehle den NPC oder Ort, an dem du jetzt stehst, als Startpunkt",
    ["wv_info_direct"] = "Direkte Orientierung ohne Route: waehle ein Ziel nach Entfernung",
    ["wv_info_target"] = "Naechstgelegene erreichbare Ziele, sortiert nach Entfernung",
    ["wv_no_targets"] = "Keine Ziele gefunden",
    ["i_correction_failed"] = "I-Nachkorrektur fehlgeschlagen: %s",
    ["i_alignment_failed"] = "I-Ausrichtung fehlgeschlagen: %s",
    ["wv_window_failed"] = "WowVision-Fenster fehlgeschlagen (%s), nutze einfaches Zielfenster.",
    -- diagnostic log
    ["log_entry"] = "#%d [%s] Zone=%s/%s Map=%s norm=(%.4f,%.4f) welt=(%s,%s) Blick=%.2f Ziel=%s%s%s",
    -- quests
    ["quest_none_selected"] = "Keine Quest ausgewaehlt. Oeffne das Questlog mit WowVision und waehle eine konkrete Quest.",
    ["quest_modern_no_info"] = "Die moderne Questlog-API liefert keine Eintragsinformationen. Es wurde keine Route gestartet.",
    ["quest_modern_unreadable"] = "Die moderne Questlog-API konnte die Questeintraege nicht lesen. Es wurde keine Route gestartet.",
    ["quest_modern_no_entry"] = "Die moderne Questlog-Auswahl verweist auf keinen konkreten Questeintrag. Es wurde keine Route gestartet.",
    ["quest_api_unavailable"] = "Die Questlog-API ist auf diesem Client nicht verfuegbar.",
    ["quest_selection_not_quest"] = "Die WowVision-Auswahl ist keine konkrete Quest. Bitte waehle einen Questeintrag statt einer Gebietsueberschrift.",
    ["probe_saved_no_quest"] = "Quest-Probe #%d gespeichert, aber keine Quest ist ausgewaehlt. Oeffne das Questlog mit WowVision, waehle eine konkrete Quest und fuehre /vn qprobe erneut aus.",
    ["probe_saved"] = "Quest-Probe #%d gespeichert: '%s', Quest-ID %s, %d Ziel(e). Keine Route wurde gestartet.",
    ["probe_reload_hint"] = "Fuer die dauerhafte Auswertung jetzt /reload ausfuehren oder ausloggen.",
    ["questie_no_point"] = "Questie liefert fuer das naechste offene Ziel der ausgewaehlten Quest '%s' keinen routbaren Zielpunkt. Es wurde keine Route gestartet.",
    ["no_point_anywhere"] = "Weder Blizzard noch die optionale Questie-Datenbank liefern fuer die ausgewaehlte Quest '%s' einen routbaren Zielpunkt. Es wurde keine Route gestartet.",
    ["quest_map_unsupported"] = "Die Karte des Questziels wird noch nicht unterstuetzt. Es wurde keine Route gestartet.",
    ["quest_area_name"] = "Questgebiet: %s",
    ["quest_area_found"] = "%s; Koordinate wird ohne feste Zielbindung im physischen Netz aufgelöst.",
    ["quest_modern_unreadable_short"] = "Die moderne Questlog-API konnte die Questeintraege nicht lesen.",
    ["quest_classic_unreadable"] = "Die klassische Questlog-API konnte die Questeintraege nicht lesen.",
    ["qselect_usage_number"] = "Benutze /vn qselect mit einer positiven ganzen Zahl, zum Beispiel /vn qselect 1.",
    ["qselect_only_n"] = "Es gibt nur %d konkrete Quest(s) im Questlog.",
    ["qselect_modern_failed"] = "Die moderne Questlog-Auswahl ist fehlgeschlagen: %s",
    ["qselect_classic_failed"] = "Die klassische Questlog-Auswahl ist fehlgeschlagen: %s",
    ["qselect_unsupported"] = "Dieser Client stellt keine Funktion zum Auswaehlen einer Quest bereit.",
    -- commands
    ["stop_manual"] = "Navigation manuell beendet.",
    ["action_module_unavailable"] = "Aktionsmodul nicht verfuegbar.",
    ["action_no_phase"] = "Keine passende Aktionsphase.",
    ["status_direct_distance"] = ", %.0f Yards 2D-Luftlinie",
    ["status_direct"] = "Direkte Orientierung zu '%s'%s; keine Route und keine Zwischenwegpunkte.",
    ["status_direct_note"] = "Endanflug und Engpass-Rückfall gelten nicht für die direkte Orientierung.",
    ["status_en_route"] = "Unterwegs zu '%s', Wegpunkt %d von %d.",
    ["no_active_navigation"] = "Keine aktive Navigation.",
    ["status_final_approach"] = "Endanflug-Fuehrung (nur links/rechts/weg auf den letzten %.1f Yards vor einer Engstelle): %s (/vn endanflug zum Umschalten).",
    ["status_choke_fallback"] = "Engpass-Rueckfall (bei seitlichem Abdriften vor einer Engstelle einen Wegpunkt zurueck): %s (/vn rueckfall zum Umschalten).",
    ["status_sku_tone"] = "SKU-Navigationston: nav%s (fester Standardton).",
    ["direct_list_position_unavailable"] = "Spielerposition gerade nicht verfuegbar; direkte Zielliste nicht geoeffnet.",
    ["direct_no_waypoints"] = "Direkte Orientierung hat keine Zwischenwegpunkte. Mit /vn stop kannst du sie beenden.",
    ["already_at_waypoint"] = "Bereits am %s Wegpunkt des Pfades.",
    ["waypoint_selected"] = "Wegpunkt %d von %d ausgewaehlt (Typ: %s).",
    ["showauto_usage"] = "Benutze /vn showauto On oder /vn showauto Off.",
    ["showauto_status"] = "Automatische Punkte anzeigen: %s.",
    ["autonew_removed"] = "Automatische Neuberechnung bei Blockade gibt es nicht mehr. Eine neue Route berechnest du mit /vn neu selbst.",
    ["fine_removed"] = "Die fruehere Feinpeilung ist durch die 5-Grad-SKU-Beacons ersetzt. Aktiv ist der feste Standardton nav%s.",
    ["finalapproach_usage"] = "Unbekannte Angabe. Benutze /vn endanflug an oder /vn endanflug aus (ohne Angabe wird umgeschaltet).",
    ["finalapproach_on"] = "Endanflug-Fuehrung EINGESCHALTET (Voreinstellung). Auf den letzten zweieinhalb Metern vor einer Engstelle hoerst du nur noch drei Kommandos: Ton links = Ziel liegt links, Ton rechts = Ziel liegt rechts, Ton hinten = du schaust weg. Dreh dich, bis die Seite kippt - dazwischen liegt der Ausrichtungs-Klick, und auf diesem Kurs passt du durch.",
    ["finalapproach_off"] = "Endanflug-Fuehrung AUSGESCHALTET. Auch kurz vor einer Engstelle gilt wieder die normale Richtungsansage.",
    ["fallback_usage"] = "Unbekannte Angabe. Benutze /vn rueckfall an oder /vn rueckfall aus (ohne Angabe wird umgeschaltet).",
    ["fallback_on"] = "Engpass-Rueckfall EINGESCHALTET (Voreinstellung). Wenn du vor einer Engstelle seitlich von der Strecke abkommst und dort haengenbleibst, fuehre ich dich automatisch einen Wegpunkt zurueck, statt dich weiter auf die Luecke zu zeigen.",
    ["fallback_off"] = "Engpass-Rueckfall AUSGESCHALTET. Du bleibst dann immer auf den naechsten Wegpunkt ausgerichtet; zurueckschalten kannst du von Hand mit /vn prev.",
    ["direct_no_recalculation"] = "Direkte Orientierung hat keine Route zum Neuberechnen. Waehle mit /vn ein Routenziel.",
    ["position_not_determinable"] = "Position gerade nicht bestimmbar, bitte kurz laufen und noch einmal versuchen.",
    ["qselect_done"] = "Quest %s ausgewaehlt: %s (Quest-ID %d).",
    ["qselect_usage"] = "Benutze /vn qselect 1, /vn qselect 2 und so weiter. Kopfzeilen werden nicht mitgezaehlt.",
    ["log_saved"] = "Diagnose-Eintrag gespeichert: %s",
    ["log_total"] = "Insgesamt %d Einträge. /vn logshow zum Anzeigen, /reload oder ausloggen zum dauerhaften Speichern.",
    ["log_none"] = "Noch keine Diagnose-Einträge vorhanden.",
    ["log_cleared"] = "Diagnose-Protokoll geleert.",
    ["unknown_command"] = "Unbekannter Befehl. /vn oeffnet Routenziele, /vn direkt die freie Zielorientierung, /vn hier setzt einen Startpunkt. /vn hilfe listet alle Befehle.",
    ["command_error"] = "FEHLER: %s",
    -- key I alignment
    ["i_no_alignment_target"] = "Kein sicher belegtes Ausrichtungsziel fuer Taste I.",
    ["i_unsupported"] = "Dieser Client stellt die sichere I-Ausrichtung nicht bereit.",
    ["position_or_facing_unknown"] = "Position oder Blickrichtung gerade nicht bestimmbar.",
    ["waypoint_already_reached"] = "Der aktuelle Wegpunkt ist bereits erreicht.",
    -- zone loader
    ["reason_activation_map_changed"] = "Nativer Kartenwechsel nach Aktivierungsbereich beobachtet; Reiseauftrag beendet. Zielort nicht bestaetigt.",
    ["reason_map_changed_guidance_done"] = "Kartenwechsel beobachtet; Aktivierungsfuehrung abgeschlossen.",
    ["zone_load_failed"] = "%s Das Wegenetz wird aus Sicherheitsgruenden nicht aufgebaut; bitte Addon-Dateien pruefen. Andere Zonen bleiben nutzbar; diese Zone wird erst nach /reload erneut geladen.",
    ["zone_data_invalid"] = "Zonendaten '%s' sind ungueltig: %s.",
    ["catalog_invalid"] = "Zielkatalog ungueltig: %s.",
    ["zone_data_activated"] = "Gebietsdaten fuer %s wurden aktiviert.",
    ["stop_zone_changed"] = "Navigation wegen Gebietswechsel beendet.",
    ["zone_file_not_loaded"] = "Die Zonendatei fuer '%s' ist nicht geladen.",
    ["stop_outside_zones"] = "Navigation ausserhalb eines unterstuetzten Gebiets beendet.",
    ["zone_data_not_ready"] = "Fuer die aktuelle Zone sind noch keine Navigationsdaten bereit. Bei unbekannter Kartenposition wird automatisch erneut geprueft.",
    -- startup
    ["startup_banner"] = "Kern geladen; Gebietsdaten werden erst in einer unterstuetzten Zone nachgeladen. /vn oeffnet Routenziele, /vn direkt die freie Zielorientierung, /vn hier setzt den Startpunkt, /vn status, /vn stop, /vn prev, /vn next, /vn neu, /vn showauto On|Off, /vn endanflug an|aus (Zwangsfuehrung kurz vor Engstellen, aktuell %s), /vn rueckfall an|aus (bei seitlichem Abdriften vor einer Engstelle einen Wegpunkt zurueck, aktuell %s), Taste I richtet dich ungefaehr zum aktuellen Zielpunkt aus, SKU-Navigationston nav%s (fester Standardton). /vn hilfe listet alle Befehle.",
    ["startup_quest_select"] = "Quest auswaehlen: /vn qselect 1, /vn qselect 2 und so weiter; Questlog-Kopfzeilen werden nicht mitgezaehlt.",
    ["startup_quest_probe"] = "Quest-API-Diagnose: /vn qprobe. Zum Ziel der ausgewaehlten Quest: /vn q.",
    -- actions
    ["action_nav_data_missing"] = "NavData fehlt",
    ["action_zone_mismatch"] = "Aktionszielgebiet oder Transitphase passt nicht",
    ["action_payload_invalid"] = "Aktionspayload ungueltig oder doppelt",
    ["action_conditions_missing"] = "Bedingungen fehlen",
    ["action_entry_unconfirmed"] = "Zutritt nicht bestaetigt",
    ["action_entry_unknown"] = "Zutritt unbekannt",
    ["action_missing"] = "Aktion fehlt",
    ["action_approach_prepoint"] = "Zum sicheren Vorpunkt von %s gehen.",
    ["action_waiting"] = "Warte am Vorpunkt. /vn aktion wiederholt die Anleitung; /vn weiter bestaetigt nur diese Aktion.",
    ["action_none_active_short"] = "Keine aktive Aktion",
    ["action_boarding"] = "Nur bei sicher anwesendem Fahrzeug einsteigen; danach /vn weiter bestaetigen.",
    ["action_activating"] = "Portal oder Eingang selbst benutzen; Ankunft wird erst nach passendem Zielsignal bestaetigt.",
    ["action_boarded"] = "Einstieg bestaetigt. Fahrt laeuft; auf sicheren Halt warten.",
    ["action_activated"] = "Aktivierung bestaetigt. Zielkarte und Ankunft werden geprueft.",
    ["action_no_confirmation"] = "In dieser Phase ist keine Bestaetigung moeglich",
    ["action_cancelled"] = "Aktion abgebrochen: %s",
    ["action_arrival_proven"] = "Ankunft belegt. Sicher aussteigen und Vorpunkt erreichen.",
    ["action_complete"] = "Aktion abgeschlossen; Route wird fortgesetzt.",
    ["action_timeout"] = "Aktion wegen Zeitueberschreitung abgebrochen.",
    ["action_none_active"] = "Keine aktive Aktion.",
    ["action_status"] = "Aktion %s: %s.",
    -- docks
    ["dock_reached"] = "Anleger '%s' erreicht. Hier auf %s warten. Steige ein, wenn du die Ankunft hoerst.",
    ["dock_boarding_hint"] = " Ein Richtungston zeigt die Einsteigrichtung; mit I kannst du dich zusaetzlich ausrichten.",
    ["dock_passive_set"] = "Gegenanleger '%s' vorgemerkt. Warte auf das Transportmittel, steige nach Gehoer ein und am Zielhalt aus. Waehle danach den Anleger erneut fuer eine lokale Route.",
    -- target resolver
    ["res_stale"] = "Zielposition ist veraltet",
    ["res_no_native_map"] = "Native Kartenbindung fehlt",
    ["res_other_map"] = "Andere native Karte",
    ["res_band_invalid"] = "Höhenbereich ungültig",
    ["res_ambiguous"] = "Mehrere Höhenbereiche; /vn ebene <Nummer>",
    ["res_z_conflict"] = "Bekannte Zielhöhe passt zu keinem Netzband; /vn ebene <Nummer>",
    ["res_no_point"] = "Kein zulässiger Netzpunkt im Anschlussradius",
    ["res_no_path"] = "Kein zulässiger Netzweg innerhalb des Anschlussradius",
    -- target selection
    ["desc_inexact"] = " (ungenau +%.1f Yards%s)",
    ["desc_pick_height"] = " (Höhe auswählen)",
    ["desc_level_unknown"] = " (Ebene unbekannt)",
    ["res_level_unknown"] = "Ebene des Ziels unbekannt; /vn ebene <Nummer>",
    ["level_prompt"] = "Die Ebene dieses Ziels ist unbekannt. /vn ebene <Nummer> wählt die Ebene:",
    ["level_line"] = "%d: Ebene bei Z %.1f%s",
    ["desc_no_point"] = " (kein zulässiger Netzpunkt im Radius)",
    ["desc_water"] = " (Wasseroberfläche, Tauchtiefe %.1f Yards)",
    ["band_prompt"] = "Zielhöhe unbekannt. /vn ebene <Nummer> wählt einen Höhenbereich:",
    ["dyn.dungeon_entrance"] = "Dungeon-Eingang: %s",
    ["dyn.portal"] = "Portal nach %s",
    ["dyn.dock_ship"] = "Anleger Schiff nach %s",
    ["dyn.dock_zeppelin"] = "Anleger Zeppelin nach %s",
    ["dyn.on_ship"] = "Am Schiff nach %s",
    ["dyn.tram_entrance"] = "Eingang Tiefenbahn",
    ["dyn.tram_dock"] = "Anleger Tiefenbahn Richtung %s",
    ["dyn.in_tram"] = "In der Bahn Richtung %s",
    ["dyn.elevator"] = "Aufzug: %s",
    ["dyn.zone_transition"] = "Übergang nach %s",
    ["dyn.unknown_destination"] = "unbekanntes Ziel",
    ["dyn.suffix.lower"] = " (unten)",
    ["dyn.suffix.upper"] = " (oben)",
    ["dyn.suffix.z"] = " (Z %d)",
    ["dyn.suffix.number"] = " (%d)",
    ["dyn.boarding_boat"] = "Am Schiff",
    ["dyn.boarding_zeppelin"] = "Am Zeppelin",
    ["dyn.boarding_vehicle"] = "Am Fahrzeug",
    ["band_prompt_conflict"] = "Bekannte Zielhöhe passt zu keinem Netzband. /vn ebene <Nummer> wählt einen Höhenbereich:",
    ["res_no_route_from_start"] = "Vom aktuellen Standort gibt es keinen Netzweg zum Ziel. Versuche /vn neu an einer anderen Stelle.",
    ["band_line"] = "%d: Z %.1f–%.1f, nächster Netzpunkt %.1f Yards%s",
    ["target_unresolvable"] = "Ziel nicht auflösbar",
    ["invalid_value"] = "Ungültiger Wert; Einstellung bleibt erhalten.",
    ["radius_status"] = "Anschlussradius %.1f Yards (XY); Höhenbereichstoleranz %.1f Yards (gesamte Z-Spanne).",
    ["no_open_level_selection"] = "Keine gültige offene Ebenenauswahl.",
    ["start_not_determined"] = "Aktueller Start nicht sicher bestimmt; Ebenenauswahl bleibt offen.",
    ["group_usage"] = "/vn gruppe party1..party4, raid1..raid40 oder target",
    ["no_live_coordinates"] = "Keine gültigen Live-Zielkoordinaten verfügbar.",
}
