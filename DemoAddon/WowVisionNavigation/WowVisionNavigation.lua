--[[
WowVision Navigation - main module.
Only reads the game state (position, facing, target list) and produces audio/text output. It never touches
input or movement.
]]

WowVisionNavigationDB = WowVisionNavigationDB or {}
WowVisionNavigationMigrationState = WowVisionNavigationMigrationState or {
    -- This global session helper is not declared as a SavedVariable. It separates freshly set default values from an
    -- already used new database, in case the legacy bridge is loaded after the product addon.
    newDatabase = next(WowVisionNavigationDB) == nil,
}

-- SavedVariables keys that had German names before the English translation (step 3b). The old key is moved to the
-- new one once, so stored settings, the last error and the blockage telemetry survive the rename.
local RENAMED_DB_KEYS = {
    ["blockadeTelemetrie"] = "blockageTelemetry", ["letzterFehler"] = "lastError", ["feinpeilung"] = "fineBearing",
    ["endanflug"] = "finalApproach", ["engpassRueckfall"] = "chokeFallback",
}
-- Keys of features that no longer exist; a value that is still stored is removed once at load.
local REMOVED_DB_KEYS = { "navigationsProfil", "autoNeuberechnung" }

function WowVisionNavigationMigrateRenamedKeys()
    local db = WowVisionNavigationDB
    for old, new in pairs(RENAMED_DB_KEYS) do
        local value = db[old]
        if value ~= nil then
            if db[new] == nil then
                db[new] = value
            elseif type(db[new]) == "table" and type(value) == "table" then
                for _, entry in ipairs(value) do table.insert(db[new], entry) end
            end
            db[old] = nil
        end
    end
end

-- WoW derives the SavedVariables file from the folder name. The new TOC therefore cannot read the old file itself.
-- The small legacy addon loads it once under its former name and calls this function. The function is safe for both
-- possible load orders: if the bridge is loaded first, it is called on ADDON_LOADED of the new addon; if it is
-- loaded later, the bridge calls it directly.
function WowVisionNavigationImportLegacyDB()
    local legacy = rawget(_G, "AkustischeNavigationDB")
    if type(legacy) ~= "table" or legacy == WowVisionNavigationDB then return false end
    if WowVisionNavigationDB._legacyMigrationVersion == 1 then return false end

    -- Preferences and the last error have scalar keys. Existing new values win, so that an already used new state is
    -- not overwritten. Diagnostic sequences are merged so that no old logs are lost.
    for key, value in pairs(legacy) do
        local target = RENAMED_DB_KEYS[key] or key
        if key ~= "log" and key ~= "questProbes" and key ~= "blockadeTelemetrie"
            and (WowVisionNavigationDB[target] == nil or WowVisionNavigationMigrationState.newDatabase) then
            WowVisionNavigationDB[target] = value
        end
    end
    for _, key in ipairs({ "log", "questProbes", "blockadeTelemetrie" }) do
        local target = RENAMED_DB_KEYS[key] or key
        local oldEntries = legacy[key]
        if type(oldEntries) == "table" then
            local newEntries = WowVisionNavigationDB[target]
            if type(newEntries) ~= "table" then
                newEntries = {}
                WowVisionNavigationDB[target] = newEntries
            end
            for _, entry in ipairs(oldEntries) do table.insert(newEntries, entry) end
        end
    end
    -- Logs, blockage telemetry and existing quest probes are kept completely.
    -- New quest probes remain subject to the regular runtime limit.
    WowVisionNavigationDB._legacyMigrationVersion = 1
    return true
end

local ADDON_PATH = "Interface\\AddOns\\WowVisionNavigation\\Sounds\\"
local SOUND_CHANNEL = "Master"

-- ============================================================
-- 1. Coordinate conversion: normalized map position -> world coordinates
-- NOTE: This mapping is an assumption and NOT yet verified live.
-- See TechnischeDoku.md section 10.6 for the calibration test.
-- ============================================================

-- World rectangles (from UiMapAssignment.db2, see machbarkeit.md) per UiMapID. They come from the same generated
-- runtime register as the LoadOnDemand assignment. A new zone therefore needs no second, easily forgotten control
-- flow change in this file.
local ZONE_BOXES = {}
-- The world rectangles per UiMap come from the continent index (maps/<continent>/index.lua). They are built at
-- addon start because the data files come after the core in the TOC.
local function BuildZoneBoxes()
    wipe(ZONE_BOXES)
    local network = _G.WowVisionNavigationNavNetwork
    if not network then return end
    for _, zone in pairs(network.index) do
        for mapID, box in pairs(zone.worldBoxes or {}) do
            ZONE_BOXES[mapID] = box
        end
    end
end

local function NormalizedToWorld(mapID, nx, ny)
    if next(ZONE_BOXES) == nil then BuildZoneBoxes() end
    local box = ZONE_BOXES[mapID]
    if not box then return nil, nil end
    -- The normalized X axis (map left->right) corresponds to world Y (west axis), the normalized Y axis (map
    -- top->bottom) corresponds to world X (north axis) - standard formula from UiMapAssignment.db2 (region0 = value at
    -- normalized 0/0, region1 = value at normalized 1/1).
    -- It used to be mirrored on the world Y axis (see TechnischeDoku.md section 10.6) - the player position was
    -- therefore calculated systematically wrong, and the distance sorting in the target list produced arbitrary
    -- "nearest" hits from other zones.
    local worldY = box.ymax - nx * (box.ymax - box.ymin)
    local worldX = box.xmax - ny * (box.xmax - box.xmin)
    return worldX, worldY
end

-- NOTE (verified with /vn log, 2026-06-26): in the open world of this client UnitPosition("player") returns 0 as the
-- third return value (height) throughout, never a real value - so the function is currently NOT usable for our
-- purposes (presumably it is only reliable in instances/interiors with their own height tracking). It is only
-- called for /vn log (diagnostics), NOT for any navigation decision - see TechnischeDoku.md section 10.6b. If
-- someone needs a height later (e.g. for the floor detection when choosing the route start node in buildings), first
-- find a different height source and verify it AGAIN in a live test, do not simply build this back in.
local function GetPlayerZ()
    local _, _, z = UnitPosition("player")
    return z
end

-- NOTE (fix 2026-06-28): indoors (e.g. in the abbey) C_Map.GetBestMapForUnit() often returns a SUBZONE map ID
-- ("Northshire Abbey"/"Main Hall") that is not entered in ZONE_BOXES - NormalizedToWorld() then returned nil and the
-- route could only be started with /vn hier (which uses the position of the target point instead of the live
-- position). Fix: probe all known ZONE_BOXES maps directly instead of relying on GetBestMapForUnit() -
-- C_Map.GetPlayerMapPosition() also works for the parent zone map while one is inside a building/subzone (just as
-- the normal world map keeps showing the player marker indoors).
local function GetPlayerWorldPosition()
    local activeZone = WowVisionNavigationZoneLoader
        and WowVisionNavigationZoneLoader.activeZone
    if activeZone and activeZone.nativeMapId
        and type(_G.UnitPosition) == "function" then
        local ok, x, y, _, nativeMapID = pcall(_G.UnitPosition, "player")
        -- The native map id already identifies the instance. A box is only a plausibility check when the index delivers one;
        -- an index without it (the exported instance entries carry none) must not discard every position of the instance.
        local box = activeZone.nativeWorldBox
        if ok and nativeMapID == activeZone.nativeMapId
            and type(x) == "number" and type(y) == "number"
            and (not box or (x >= box.xmin and x <= box.xmax and y >= box.ymin and y <= box.ymax)) then
            return x, y, nativeMapID
        end
    end
    if activeZone and activeZone.nativeMapId then
        for mapID in pairs(activeZone.uiMaps or {}) do
            local pos = C_Map.GetPlayerMapPosition(mapID, "player")
            if pos then
                local nx, ny = pos:GetXY()
                local wx, wy = NormalizedToWorld(mapID, nx, ny)
                if wx then return wx, wy, mapID end
            end
        end
        return nil
    end
    for mapID in pairs(ZONE_BOXES) do
        local pos = C_Map.GetPlayerMapPosition(mapID, "player")
        if pos then
            local nx, ny = pos:GetXY()
            local wx, wy = NormalizedToWorld(mapID, nx, ny)
            if wx then
                return wx, wy, mapID
            end
        end
    end
    return nil
end

-- ============================================================
-- 2. Network connection (schema 7, concept chapters 7 and 7a)
-- ============================================================
-- Graph, funnel and guidance of the old schemas are gone. Waypoints, attachment cells and the A* search live in
-- NavNetwork.lua, arrival, height and re-entry in Guidance.lua. Only the thin accessors that the rest of the core
-- has always used under these names remain here.
local NavNetwork = _G.WowVisionNavigationNavNetwork
local Guidance = _G.WowVisionNavigationGuidance
local VIRT_BASE_ID = NavNetwork.VIRT_BASE

-- Block penalties of the route (runtime detour, dropped at the end of the route): EdgePenalties[a][b] in yards
local EdgePenalties = {}

local function EdgeKey(a, b)
    if a > b then a, b = b, a end
    return tostring(a) .. "_" .. tostring(b)
end

local function NodeExists(id)
    return NavNetwork.Exists(id)
end

-- Returns x, y, z in yards.
local function NodePosition(id)
    return NavNetwork.Position(id)
end

-- Node type keys: terrain | indoor | water (the display name comes from Localization.lua, key nodetype.<type>).
local NODE_TYPE_NAME = { OPEN = "terrain", FINE = "indoor", WATER = "water" }
local function NodeType(id)
    if id == nil then return "terrain" end
    if id >= VIRT_BASE_ID then
        local v = NavNetwork.virt[id]
        return v and v.water and "water" or "terrain"
    end
    return NODE_TYPE_NAME[NavNetwork.Area(id) or "OPEN"] or "terrain"
end

-- Automatic waypoints are called "Auto: <type>"; the type comes from the base code (chapter 5) and its display name
-- from Localization.lua (keys autoname.<type>; announcements use basecode.<type>, German on a deDE client).
local AUTO_TYPES = {
    { 8, "water_exit" }, { 64, "zone_border" }, { 32, "action" }, { 2, "gate" }, { 16, "level_change" },
    { 4, "road_junction" }, { 128, "target_access" }, { 512, "branch" }, { 1, "corner" }, { 256, "coverage" },
}
function NodeDisplayName(id)
    local bits = NavNetwork.Bits(id)
    local name = "waypoint"
    for _, entry in ipairs(AUTO_TYPES) do
        if bits % (entry[1] * 2) >= entry[1] then name = entry[2]; break end
    end
    -- The height (whole yards) closes the name: the player finds re-entry points on the right level.
    local _, _, z = NavNetwork.Position(id)
    local label = WowVisionNavigationText("auto_prefix_z", WowVisionNavigationText("autoname." .. name),
        math.floor((z or 0) + 0.5))
    return label, label
end


local function ShowAutoPoints()
    return WowVisionNavigationDB.showauto == true
end

local function AutomaticListEntry(target)
    if target.autoGenerated == true then return true end
    if type(target.id) == "string" and target.id:match("^node_") then return true end
    return type(target.nameEn) == "string" and target.nameEn:match("^Auto: ") ~= nil
        or type(target.nameDe) == "string" and target.nameDe:match("^Auto: ") ~= nil
end

-- TargetCatalog is mandatory and loaded before Core by the TOC.

local function TargetName(target)
    if target and target.layerResolution and _G.WowVisionNavigationTargetSelection then
        return _G.WowVisionNavigationTargetSelection:Describe(target,target.layerResolution)
    end
    return _G.WowVisionNavigationTargetName(target)
end

-- Zone name of a target for the lists: localized by the client (C_Map.GetMapInfo of the UiMap of the zone; the maps whose
-- world box is the box of the zone's own map, subzone maps such as Northshire do not count). Without the API the name of
-- the package index (English) is the fallback. Cached per zone.
local zoneNameCache = {}
local function LocalizedZoneName(zoneId, zone)
    local cached = zoneNameCache[zoneId]
    if cached ~= nil then return cached or nil end
    local name
    if C_Map and type(C_Map.GetMapInfo) == "function" and zone then
        local ids, seen = { zoneId }, { [zoneId] = true }
        local own = zone.worldBoxes and zone.worldBoxes[zoneId]
        local others = {}
        for mapId in pairs(zone.uiMaps or {}) do
            local box = zone.worldBoxes and zone.worldBoxes[mapId]
            if not seen[mapId] and own and box and box.xmin == own.xmin and box.xmax == own.xmax
                and box.ymin == own.ymin and box.ymax == own.ymax then
                others[#others + 1] = mapId
            end
        end
        table.sort(others)
        for _, mapId in ipairs(others) do ids[#ids + 1] = mapId end
        for _, mapId in ipairs(ids) do
            local ok, info = pcall(C_Map.GetMapInfo, mapId)
            if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
                name = info.name
                break
            end
        end
    end
    name = name or (zone and zone.name)
    zoneNameCache[zoneId] = name or false
    return name
end

local function TargetZoneName(target)
    local zone = NavNetwork.index[target.zoneId]
    if zone then return LocalizedZoneName(target.zoneId, zone) end
    return target.zoneName
end

-- Real waypoint behind a (possibly virtual) ID. A link-point attachment has no anchor of its own.
local function AnchorNode(id)
    if id == nil then return nil end
    if id < VIRT_BASE_ID then return id end
    return nil
end

-- Choke (gate): half width in yd or nil. Drives the final approach, the fallback and the click tolerance.
local function ChokeRadius(id)
    return Guidance.Choke(id)
end

-- In the water: swimming at the surface or submerged (diving). A route start there binds to water points only.
function PlayerIsSwimming()
    for _, name in ipairs({ "IsSwimming", "IsSubmerged" }) do
        local query = _G[name]
        if type(query) == "function" then
            local ok, inWater = pcall(query)
            if ok and inWater == true then return true end
        end
    end
    return false
end

-- A* search on the network. startId/targetId are real waypoints, link points or bindings from NavNetwork.Bind.
-- Returns the waypoint sequence (including link-point attachments), the edge list and the result object.
local function AStar(startId, targetId, footOnly)
    local result, reason = NavNetwork.RouteIds(startId, targetId, EdgePenalties, footOnly)
    if not result then return nil, reason end
    return result.path, result.edges, result
end


-- ============================================================
-- 3. Audio-Leitsignal
-- ============================================================

-- Confirmed by a live test: with correct geometry (coordinate bug AND angle formula both right now) left/right still
-- sounds swapped - so it does come from the sound files themselves (swapped stereo panning), not from the
-- calculation. Therefore the file names for left/right are assigned swapped again here.
local DIRECTION_SOUNDS = {
    "dir_front", "dir_front_left", "dir_left", "dir_back_left",
    "dir_back", "dir_back_right", "dir_right", "dir_front_right",
}

-- 10.6bm (fine bearing): the same ladder with 16 instead of 8 steps, but only in the FRONT half circle. Index 1 =
-- front, then clockwise in 22.5-degree steps. From index 5 on (i.e. |deviation| > 78.75 degrees) the ladder falls
-- back to the coarse 45-degree sectors: behind the player a finer resolution gains nothing (the player turns around
-- anyway) and would only cost additional sounds.
-- NOTE: left/right are historically assigned swapped in the file names (see the comment above DIRECTION_SOUNDS);
-- the "_fine" files follow exactly the same assignment.
-- Deliberately with explicit indices: the indices 6..12 (rear half circle) intentionally stay empty and fall back to
-- the coarse 45-degree ladder.
local DIRECTION_SOUNDS_FINE = {
    [1]  = "dir_front",             -- Deviation   0.00 -  11.25 degrees (pan  0.00)
    [2]  = "dir_front_left_fine",  --             11.25 -  33.75 left (Pan -0.25)
    [3]  = "dir_front_left",       --             33.75 -  56.25 left (Pan -0.50)
    [4]  = "dir_left_fine",        --             56.25 -  78.75 left (Pan -0.75)
    [5]  = "dir_left",             --             78.75 - 101.25 left (Pan -1.00)
    [13] = "dir_right",            --             78.75 - 101.25 right (Pan  1.00)
    [14] = "dir_right_fine",       --             56.25 -  78.75 right (Pan  0.75)
    [15] = "dir_front_right",      --             33.75 -  56.25 right (Pan  0.50)
    [16] = "dir_front_right_fine", --             11.25 -  33.75 right (Pan  0.25)
}

-- Computes the sector (1 = front, clockwise) from the facing and the target angle.
local function SectorFromAngle(playerViewDirection, angleToTarget)
    local diff = (angleToTarget - playerViewDirection) % (2 * math.pi)
    local sectorSize = (2 * math.pi) / 8
    local sector = math.floor((diff + sectorSize / 2) / sectorSize) % 8
    return sector + 1
end

-- Fine sector 1..16 (22.5 degrees wide, 1 = exactly ahead). Only meant as a refinement: where the fine ladder has
-- no entry, the coarse 45-degree sector still applies.
local function FineSectorFromAngle(playerViewDirection, angleToTarget)
    local diff = (angleToTarget - playerViewDirection) % (2 * math.pi)
    local sectorSize = (2 * math.pi) / 16
    return math.floor((diff + sectorSize / 2) / sectorSize) % 16 + 1
end

local function PlayDirectionSound(sectorIndex, fineSectorIndex)
    local name = fineSectorIndex and DIRECTION_SOUNDS_FINE[fineSectorIndex]
    PlaySoundFile(ADDON_PATH .. (name or DIRECTION_SOUNDS[sectorIndex]) .. ".ogg", SOUND_CHANNEL)
end

-- After a listening test the user picked nav6 as the clearly most pleasant SKU beacon. SKU also knows large
-- waypoints; our graph deliberately has NO waypoint size, so the same fixed sound applies to all waypoints without
-- exception.
local SKU_NAV_STANDARD = 6
local SKU_NAV_BASENAME = "beacon6"
local SKU_BEACON_ANGLE_STEP = 5       -- degrees, original resolution of the SKU files
local SKU_BEACON_MAX_LEVEL = 30           -- groesste ausgelieferte Distanz-/Lautstaerkestufe
local SKU_BEACON_MIN_INTERVAL = 0.30
local SKU_BEACON_MAX_INTERVAL = 0.70

-- SKU computes its sign opposite to our live-confirmed convention (positive = target on the left). The reversal here
-- makes sure the stereo position recorded with SKU still lies on the correct headphone side.
local function SkuAngleLevel(signedDeviation)
    local degrees = -math.deg(signedDeviation or 0)
    -- This is exactly SKU's quantization: 0 degrees selects the 5-degree file, after that always the next higher
    -- 5-degree step. Do not "round" - this keeps the selection and the original sound congruent.
    local level = (math.floor(degrees / SKU_BEACON_ANGLE_STEP) + 1) * SKU_BEACON_ANGLE_STEP
    if level < -180 then level = -180 elseif level > 180 then level = 180 end
    return level
end

local function SkuDistanceLevel(distance)
    -- SKU navigation mode -3: raise the distance by four yards and then quantize in groups of six. The same level also
    -- selects its volume variant at standard volume.
    local level = math.floor((math.floor(distance or 0) + 5) / 6)
    if level < 0 then level = 0 elseif level > SKU_BEACON_MAX_LEVEL then level = SKU_BEACON_MAX_LEVEL end
    return level
end

local function SkuBeaconInterval(signedDeviation)
    -- Also SKU mode -3: before the target the anchor accelerates from 0.7 to 0.3 seconds. So it remains a continuous
    -- spatial reference point even in the straight-ahead window.
    local deviationDegrees = math.abs(math.deg(signedDeviation or 0))
    local interval = SKU_BEACON_MIN_INTERVAL + math.min(deviationDegrees, 18) / 45
    if interval > SKU_BEACON_MAX_INTERVAL then interval = SKU_BEACON_MAX_INTERVAL end
    return interval
end

local function PlaySkuBeacon(signedDeviation, distance)
    local angle = SkuAngleLevel(signedDeviation)
    local level = SkuDistanceLevel(distance)
    PlaySoundFile(ADDON_PATH .. "SkuBeacon\\nav" .. SKU_NAV_STANDARD .. "\\" .. SKU_NAV_BASENAME .. ";" ..
        angle .. ";" .. level .. ".mp3", SOUND_CHANNEL)
end

local function PlaySkuClick(name)
    PlaySoundFile(ADDON_PATH .. "SkuBeacon\\clickclack\\" .. name .. ".mp3", SOUND_CHANNEL)
end

local function PlayEventSound(name)
    PlaySoundFile(ADDON_PATH .. name .. ".ogg", SOUND_CHANNEL)
end

-- ============================================================
-- 4. Live-Fuehrung
-- ============================================================

local Navigation = {
    active = false,
    path = nil,
    directTarget = nil,             -- free single-target orientation mode without A*/funnel/route
    pathIndex = nil,
    targetName = nil,
    targetStatus = nil,
    lastBeepTime = 0,
    lastClickTime = 0,
    skuStraightAhead = nil,              -- last state of the click/clack zone
    lastNodeId = nil,
    lastBumpTime = 0,
    blockageCheckX = nil,
    blockageCheckY = nil,
    blockageCheckTime = 0,
    blockageLastViewDirection = nil,
    lastMovementDetectedTime = nil,
    manualStartNode = nil,  -- set by /vn hier, see StartNavigationToNode
    manualStartName = nil,
    -- Blockade-Eskalation (konzept.md 5.2, siehe HandleBlockage):
    blockageStuckSince = nil,          -- GetTime() since when the player has been stuck continuously
    blockageEscalated = false,       -- trigger only ONE escalation level per stuck episode
    blockagesPerEdge = {},          -- [edgeKey] = number of blockage episodes of this route
    lastConfirmedNode = nil, -- last waypoint that was actually REACHED (exact position)
    -- Stagnation detection "moves but does not get closer" (10.6ba, see CheckApproach): sliding window on the distance
    -- to the current waypoint.
    stagnationRefDistance = nil,      -- distance to the waypoint at the start of the window
    stagnationRefTime = nil,         -- GetTime() at the start of the window
    stagnationTravel = 0,        -- seitdem zurueckgelegte Weglaenge (2D, aufsummiert)
    stagnationLastX = nil,
    stagnationLastY = nil,
    segmentProgressMax = nil,      -- monotonic projection onto the current route edge (10.6bc)
}

-- ============================================================
-- 4a. Height and layer state of the route (chapter 7 points 2 and 8)
-- ============================================================
-- The WoW API delivers no live height (TechnischeDoku 10.6b). The HeightAnchor contract (30 s / 40 yd) of the old
-- schemas is replaced by the route state:
--   height    - height on the current link, linearly interpolated between the end points (only during a route, after
--               /vn hier or after an action arrival).
--   preferred - the most recently steered waypoints (layer of the route state). If several stacked attachment cells
--               lie above the start position, the cell attached to one of these waypoints wins. Without a match
--               nothing is guessed: "height unclear", then /vn hier or /vn ebene.
-- A fall or a measured deviation above 4 yd sets the height to "uncertain" (log only).
--   last      - the last height that was known (since 4.41): it survives the end of a route and chooses the height band
--               of a start without any height (the band nearest to it) before the player is asked.
local HeightAnchor = { height = nil, preferred = nil, last = nil }
local HEIGHT_DEVIATION_UNCERTAIN = 4.0

local function SetHeightAnchor(height, x, y)
    HeightAnchor.height = height
    if height ~= nil then HeightAnchor.last = height end
end

local function SetRouteState(previousId, waypointId)
    local set = {}
    for _, id in ipairs({ previousId or false, waypointId or false }) do
        if id and id < VIRT_BASE_ID then set[id] = true end
    end
    if next(set) ~= nil then HeightAnchor.preferred = set end
end

local function EstimatedHeightForSearch(x, y)
    if PlayerIsSwimming() then return nil end
    return HeightAnchor.height
end

-- Binds a position to the network (cell, attachment choice by field mask). Returns id (node or link point),
-- binding | nil, reason ("ambiguous" | "no_attachment" | "zone data not loaded"), options with candidates
local function StartBinding(x, y)
    local options = { swimming = PlayerIsSwimming(), preferred = HeightAnchor.preferred, lastHeight = HeightAnchor.last }
    local binding, reason = NavNetwork.Bind(x, y, EstimatedHeightForSearch(x, y), options)
    if not binding then return nil, reason, options end
    return NavNetwork.BindingId(binding), binding, options
end

local function NextNodeWithHeightAnchor(x, y)
    local id = StartBinding(x, y)
    return id
end

-- Without a known height several floors can describe the same X/Y position. Then nothing is guessed.
local function StartPositionAmbiguous(x, y)
    local _, reason = StartBinding(x, y)
    return reason == "ambiguous"
end

-- Start check when the route list opens (/vn): the player hears at once that the start is not unique instead of choosing a
-- target first and meeting the same message at the route start. A start chosen with /vn here is already settled. Returns
-- true when the start is usable. (Global: the file is at the limit of file locals.)
function WowVisionNavigationCheckStartAtOpen()
    if Navigation.manualStartNode then return true end
    local x, y = GetPlayerWorldPosition()
    if not x then
        WowVisionNavigationSay("player_position_unknown")
        return false
    end
    local id, reason = StartBinding(x, y)
    if id then return true end
    WowVisionNavigationSay(reason == "ambiguous" and "floor_ambiguous" or "no_network_attachment")
    return false
end

-- Route from a start attachment; finds it no way, the other start attachments of the cell and of the cells next to it are
-- tried before "no network path" (chapter 7, since 4.41). Returns path, edges, result, usedStartId | nil, reason.
local function RouteFromStart(startId, endId, footOnly, x, y)
    local path, edges, result = AStar(startId, endId, footOnly)
    if path or not x then return path, edges, result, startId end
    local reason = edges
    local options = { swimming = PlayerIsSwimming(), preferred = HeightAnchor.preferred, lastHeight = HeightAnchor.last }
    local list = NavNetwork.StartBindings(x, y, EstimatedHeightForSearch(x, y), options)
    for _, binding in ipairs(list or {}) do
        if binding.id ~= startId then
            local alternative, alternativeEdges, alternativeResult = AStar(binding.id, endId, footOnly)
            if alternative then return alternative, alternativeEdges, alternativeResult, binding.id end
        end
    end
    return nil, reason
end

-- ARRIVAL (chapter 7 point 6): a waypoint counts as reached when the player stands within the arrival radius, has
-- passed the gate line in link direction, or (open area) has crossed the angle bisector and still stands in the
-- attachment cell whose attachment is the next waypoint. Radius and gate half width come from the data (S10 points 4
-- and 5).
local ARRIVAL_TARGET_RADIUS = 1.5     -- yards: end point at the target position (logical target)

local function SegmentProgressOf(x, y, fromId, toId)
    return Guidance.SegmentProgress(x, y, fromId, toId)
end

local function WaypointIsReached(x, y, distance, waypointId, previousId, afterId)
    if Navigation.waitTargetId and not afterId then
        local featureModule = _G.WowVisionNavigationDockNavigation
        local target
        for _, candidate in ipairs(WowVisionNavigationTargetList(NavData, function(t) return t.id == Navigation.waitTargetId end, true)) do
            if candidate.id == Navigation.waitTargetId then target = candidate; break end
        end
        -- The normal arrival radius can be larger than the proven waiting area. Then keep guiding to the pier.
        if not featureModule or not featureModule:WaitAreaReached(target, x, y, NavData) then
            return false
        end
    end
    local reached, rule = Guidance.Reached({
        x = x, y = y, px = Navigation.previousX, py = Navigation.previousY,
        z = EstimatedHeightForSearch(x, y), swimming = PlayerIsSwimming(),
        waypointId = waypointId, previousId = previousId, nextId = afterId,
    })
    Navigation.lastArrivalRule = reached and rule or nil
    return reached
end
local ALIGNMENT_TOLERANCE = math.rad(8)  -- degrees tolerance for the "exactly aligned" click
local ALIGNMENT_CLICK_INTERVAL = 0.2
-- 10.6bk: at a GATE 8 degrees are not enough. The click is meant to say "on this course you fit through the gap" -
-- and that is a function of gap width AND distance: at 7 yards 8 degrees already correspond to 0.98 yards of lateral
-- offset, while the 0.95-yard gap of the abbey main hall only allows +-0.475 yards. The tolerance is therefore
-- derived geometrically at gate waypoints: atan(choke radius / distance). It never becomes LARGER than the previous
-- 8 degrees and not smaller than ALIGNMENT_TOLERANCE_MIN, so that it can still be hit with the player's
-- mouse/keyboard resolution at all.
local ALIGNMENT_TOLERANCE_MIN = math.rad(2.5)
local function AlignmentToleranceFor(waypointId, distance)
    local radius = ChokeRadius(waypointId)
    if not radius or not distance or distance <= radius then return ALIGNMENT_TOLERANCE end
    local tol = math.atan(radius / distance)
    if tol < ALIGNMENT_TOLERANCE_MIN then tol = ALIGNMENT_TOLERANCE_MIN end
    if tol > ALIGNMENT_TOLERANCE then tol = ALIGNMENT_TOLERANCE end
    return tol
end

-- ============================================================
-- 4a2. Fine bearing (10.6bm)
-- ============================================================
-- SIXTH failure in the same main hall. 10.6bl predicted that another waypoint fix would not help any more, because
-- with eight 45-degree sectors a lateral offset of tan(22.5) * distance = 0.414 * distance is the hard physical limit
-- of the announcement. At the failed gate that is 1.04 yards from a 2.50-yard run-up against a target circle of
-- 0.35 - a ratio of 3:1. The live log of the sixth run confirms it exactly: the bearing ray was free of walls at
-- all five blockage positions, yet the lateral distance still grew to 1.55 / 1.88 / 3.87 / 2.42 / 1.89 yards. The
-- user was not blocked - he simply could not hold the course acoustically more finely than the announcement
-- resolves it.
--
-- Two steps, both purely angle based and therefore effective everywhere (NO special treatment of individual
-- waypoints, edges or buildings):
--
--   (1) 16 instead of 8 sectors in the front half circle. This is no new sound vocabulary: in the sound files the
--       direction is carried exclusively by the stereo panning (pan = deviation / 90 degrees), the four new files
--       only fill the gaps of the pan ladder at +-0.25 and +-0.75. For the listener the same tone moves more finely
--       in the stereo image, he does not have to learn to distinguish anything new. Maximum angle error
--       22.5 -> 11.25 degrees, lateral offset factor 0.414 -> 0.199.
--
--   (2) Continuous approach cadence in the foremost sector. Panning hardly helps any further near the center axis
--       (small pan differences are hard to distinguish there), so a SECOND, completely quantization-free quantity
--       takes over there: the repetition rate. Between the click tolerance and 11.25 degrees the tone interval is
--       contracted steplessly from the normal (distance dependent) value to the click interval. The tone therefore
--       audibly speeds up the more exactly one turns in, and in the end merges seamlessly into the alignment click.
--       On this last degree there is thus no sector boundary at all any more - exactly what 10.6bl demanded as a
--       "more continuous direction announcement on the last meters".
--
-- Can be switched off with /vn fein aus (then exactly the old behavior: 8 sectors, purely distance dependent
-- cadence), following the example of the meanwhile removed /vn autoNew from 10.6bi.
local FINE_SECTOR_HALF_WIDTH = math.pi / 16   -- 11.25 degrees
local function FineBearingOn()
    return WowVisionNavigationDB and WowVisionNavigationDB.fineBearing ~= false
end

-- Tone interval in seconds. Base value as before: faster the closer the target. New: if the deviation already lies
-- in the foremost fine sector, the interval is additionally interpolated steplessly towards the click interval (at
-- |deviation| = click tolerance it reaches it exactly).
local function ToneInterval(distance, deviation, alignmentTolerance)
    local base = math.max(0.25, math.min(2.0, distance / 15))
    if not FineBearingOn() or deviation >= FINE_SECTOR_HALF_WIDTH then return base end
    local span = FINE_SECTOR_HALF_WIDTH - alignmentTolerance
    if span <= 0 then return base end
    local share = (deviation - alignmentTolerance) / span   -- 0 = fast drauf, 1 = Sektorrand
    if share < 0 then share = 0 elseif share > 1 then share = 1 end
    local target = math.min(base, ALIGNMENT_CLICK_INTERVAL)
    return target + (base - target) * share
end

local BLOCKAGE_CHECK_INTERVAL = 0.5  -- seconds without noticeable movement despite an attempt to walk
local BLOCKAGE_MIN_MOVEMENT = 1.0  -- yards - below this it counts as "stuck"
-- ============================================================
-- 4a3. Final-approach forced guidance (10.6bp)
-- ============================================================
-- NINTH failure, for the THIRD time at the same gap of the abbey main hall. 10.6bn named two candidates for exactly
-- this case and explicitly demanded that no further geometry fix be built from the eighth failure on. This is
-- candidate (b): a forced guidance on the last meters made of a few clearly separated commands instead of a
-- quantized bearing.
--
-- Why exactly this, derived from the measurement (TechnischeDoku 10.6bp):
-- Even with the fine bearing (10.6bm) the announcement is quantized in 22.5-degree sectors; the target circle of a
-- gate is, however, narrower than a sector (at the gate of the main hall: click tolerance atan(0.46 / 3.20) =
-- 8.2 degrees against 11.25 degrees sector half width). On the last meters the player therefore hears the SAME tone
-- across a whole sector and gets no feedback whether a turn puts him in a better or worse position - he can only
-- guess. This is exactly what the ninth run shows: both main hall blockages carry the signature "no_approach" (in
-- the 10-second window the player demonstrably covered >= 5 yards), and the facing was 30 and 151 degrees off the
-- bearing, while 204-242 degrees were free all around.
--
-- The forced guidance turns the problem around: in the final approach to a choke point there are only THREE
-- distinguishable outputs left - "target is on the left", "target is on the right", "you are looking away" - and on
-- top of that the unchanged alignment click as the fourth, absorbing output. The course is thus no longer to be
-- guessed but to be found by INTERVAL BISECTION: turn until the side flips; the click lies in between. The
-- resolution of this search depends only on the click tolerance (i.e. on the real gap width, 10.6bk), no longer on
-- the sector width.
--
-- Completely generic: it is triggered exclusively by ChokeRadius() (i.e. by the choke points from 10.6bj and the
-- gate corners from 10.6bk, worldwide) and the remaining distance. No ID list, no building reference. Can be
-- switched off with /vn endanflug aus, following the example of the meanwhile removed /vn autoNew (10.6bi) and
-- /vn fein (10.6bm).
-- Upper limit, so that the forced guidance really is only the final approach: at most twice the run-up distance. It
-- is deliberately larger than the run-up distance (ANLAUF_ABSTAND) itself, because in the ninth run exactly the case
-- occurred that needs the guidance: the player had drifted away from the run-up point and stood 3.20 instead of
-- 2.50 yards in front of the gate. A limit of exactly 2.50 would not have taken effect there.
local FINAL_APPROACH_DISTANCE = 5.0   -- yards: forced guidance in front of a gate (double run-up of 2.5 yd)
local FINAL_APPROACH_REVERSAL = math.rad(75)           -- above this: "you are looking away", not "correct"
local FINAL_APPROACH_INTERVAL = 0.30                -- fixed, fast cadence (the side counts, not the speed)
local FINAL_APPROACH_SECTOR_LEFT = 3                -- dir_left      (target is on the left)
local FINAL_APPROACH_SECTOR_RIGHT = 7               -- dir_right     (target is on the right)
local FINAL_APPROACH_SECTOR_AWAY = 5                  -- dir_back      (you are looking away)

local function FinalApproachOn()
    return WowVisionNavigationDB and WowVisionNavigationDB.finalApproach ~= false
end

-- True if the active waypoint is a choke point, lies at most FINAL_APPROACH_DISTANCE away - AND the sector
-- announcement can no longer resolve its target circle mathematically.
--
-- The third condition is the actual derived trigger and replaces a guessed threshold: the target circle of a choke
-- point appears from `distance` under the half angle atan(radius / distance). If this half angle is SMALLER than half
-- the sector width of the fine bearing (11.25 degrees), the whole target circle fits into a single sector - the
-- player then hears the same tone across the whole target area and gets no feedback any more whether a turn puts him
-- in a better or worse position. Exactly there and only there the forced guidance takes over. Closer in (larger half
-- angle) the normal announcement resolves again, and the usual guidance stays unchanged.
local function FinalApproachActive(waypointId, distance)
    if not FinalApproachOn() then return false end
    if not distance or distance > FINAL_APPROACH_DISTANCE or distance <= 0 then return false end
    local radius = ChokeRadius(waypointId)
    if not radius then return false end
    return math.atan(radius / distance) < FINE_SECTOR_HALF_WIDTH
end

-- The sector index of the forced guidance for a signed angular deviation (positive = target is to the left of the
-- view, same convention as signedDeviation in the OnUpdate). Factored out so that test_addon_lua.py can check it
-- without game state.
local function FinalApproachSector(signedDeviation)
    if math.abs(signedDeviation) > FINAL_APPROACH_REVERSAL then return FINAL_APPROACH_SECTOR_AWAY end
    if signedDeviation > 0 then return FINAL_APPROACH_SECTOR_LEFT end
    return FINAL_APPROACH_SECTOR_RIGHT
end

local BLOCKAGE_SOUND_INTERVAL = 0.5  -- minimum gap between two blockage beeps (maximum rate)

-- Purely reading detection of "running against a wall": IsPlayerMoving() is true as long as the player holds a
-- movement key - on a real wall collision it can however flicker very briefly between true/false (the server stops
-- the movement, the next step briefly toggles back to "moving"), whereby logic that stubbornly checks for
-- "continuously true" resets the 1-second measurement prematurely every time, before it takes effect. Hence a 0.5 s
-- tolerance window here: "tries to walk" is retained across short dropouts. Input/movement is therefore never
-- interfered with, only the movement intent is read.
local BLOCKAGE_MOVEMENT_TOLERANCE = 0.5

-- ============================================================
-- 4b. Blockage escalation (konzept.md 5.2): react instead of only alerting
-- ============================================================
-- Until now "running against the wall" only produced a beep. New, in levels (exactly ONE level is triggered per
-- stuck episode; the level depends on how often it has already happened on the SAME edge):
--   Level 1 (first blockage on this edge): side-step hint - the most frequent cause is "slightly beside the
--     edge" (door frame/furniture edge), one step to the side fixes that.
--   Level 2 (repeated blockage on the same edge): the edge gets a high, session-local extra weight
--     (EdgePenalties, dropped at the end of the route) and the route is recalculated FROM THE LAST CONFIRMED
--     WAYPOINT (exactly known position, not the 2D estimate) - the voxel graph almost always offers an alternative
--     way.
--   Level 3 (telemetry, on every level-2 blockage): coordinates + edge into the SavedVariables
--     (WowVisionNavigationDB.blockageTelemetry) - pipeline input: repeated blockages at the same spot are an
--     automatic check order for exactly this voxel region, NO reason for special-case code in the addon.
local BLOCKAGE_ESCALATION_WAIT_TIME = 1.5  -- seconds of continuous sticking until escalation
local BLOCKAGE_EDGE_PENALTY = 1000.0      -- extra weight in yards (practically: use the edge only
                                           -- as the very last option)

-- SECOND STUCK SIGNATURE (10.6ba): "moves but does not get closer".
-- CheckBlockage() below detects only the hard case "position delta practically zero despite attempt to walk"
-- (running against a wall). Proven live on 2026-09-05: the blind user walked around for 40 seconds without reaching
-- the current waypoint (the distance dropped only from 7.79 to 5.63 yards in 33 s) - the position deltas were
-- consistently LARGE enough to reset the stuck episode at every measurement. WowVisionNavigationDB.blockageTelemetry
-- therefore stayed empty although the navigation had effectively come to a standstill.
-- This is now detected via a sliding window on the DISTANCE TO THE CURRENT WAYPOINT: if it does not drop by at least
-- STAGNATION_MIN_APPROACH yards over STAGNATION_WINDOW seconds although the player covered at least
-- STAGNATION_MIN_TRAVEL yards of way in that time, the same escalation runs as in the frozen case.
-- Calibration (generic, not tailored to this case): 2 yards in 10 seconds are ~0.2 yards/s, i.e. about 3 % of the
-- walking speed - below any plausible real approach. The waypoint distances of the pipeline are 0.2-6 yards, so a
-- healthy segment is completed long before the window expires. The travel distance condition cleanly separates this
-- case from the "frozen" case, which still belongs to CheckBlockage() (no double escalation).
local STAGNATION_WINDOW = 10.0            -- seconds observation window
local STAGNATION_MIN_APPROACH = 2.0     -- yards by which the distance has to drop within the window
local STAGNATION_MIN_TRAVEL = 5.0      -- yards of way covered in the window ("moves")

-- If the player has already passed an entrance, the next nominal waypoint can lie behind him and a later waypoint of
-- the same, already validated route in front of him. Exactly then a blockage must not recalculate from the old outer
-- node. The re-entry is deliberately limited locally: at most ten waypoints ahead, at most five yards away, in the
-- height band of the current anchor and at least 0.5 yards closer than the current waypoint. In addition the player
-- must lie inside the offline certified free-space circle around the candidate. This circle lies completely inside
-- one convex Recast polygon; the direct segment to the candidate that arises is thereby proven walkable.
local BLOCKAGE_REENTRY_RADIUS = 5.0
local BLOCKAGE_REENTRY_MAX_STEPS = 10
local BLOCKAGE_REENTRY_MAX_HEIGHT_DEVIATION = 3.0
local BLOCKAGE_REENTRY_MIN_IMPROVEMENT = 0.5

-- Reset the window (route start, reached waypoint, recalculation, route end).
local function ResetApproach()
    Navigation.stagnationRefDistance = nil
    Navigation.stagnationRefTime = nil
    Navigation.stagnationTravel = 0
    Navigation.stagnationLastX = nil
    Navigation.stagnationLastY = nil
    Navigation.segmentProgressMax = nil
end

-- Local re-entry (B14, chapter 2a): if after a detected stagnation the player stands in an attachment cell whose
-- attachment is a later point of the existing route (field bit of the player's field set) and this point is closer
-- than the current waypoint, the route continues there. The segment player -> attachment is checked on the standard
-- mesh (S10), the rest of the route stays unchanged. There is no recalculation and no new waypoint.
local function TryRouteReentry(x, y)
    if not Navigation.active or not Navigation.path or not Navigation.pathIndex then return false end
    local currentIndex = Navigation.pathIndex
    local bestIndex, bestDistance = Guidance.Reenter(Navigation.path, currentIndex, x, y,
        EstimatedHeightForSearch(x, y), { swimming = PlayerIsSwimming() })
    if not bestIndex then return false end

    local remainingPath = {}
    for i = bestIndex, #Navigation.path do
        remainingPath[#remainingPath + 1] = Navigation.path[i]
    end
    Navigation.path = remainingPath
    Navigation.pathIndex = 1
    Navigation.lastConfirmedNode = nil
    Navigation.lastRouteRecalculationTime = GetTime()
    Navigation.blockageCheckX = nil
    Navigation.blockageStuckSince = nil
    Navigation.blockageEscalated = false
    Navigation.skuStraightAhead = nil
    ResetApproach()
    PlayEventSound("rerouted")
    return true, bestIndex - currentIndex, bestDistance, Guidance.ArrivalRadius(remainingPath[1])
end

-- ============================================================
-- 4c. Automatic recalculation on blockage: permanently OFF (10.6bi, 10.6dg)
-- ============================================================
-- The reasoning is in TechnischeDoku 10.6bi: redirecting to a completely new route without being asked is the most
-- expensive of all reactions for a blind player (he does not know the new way, it regularly leads back outside), and
-- in the live run of 2026-09-06 exactly this automatism produced a four-minute oscillation. The former switch
-- /vn autoNew was therefore removed in 10.6dg: once a route is started, it is up to the user how to follow it - it
-- must never be redirected automatically again. Still unaffected are: the certified route re-entry (10.6be/bf, that
-- is the same checked path, not a new route) and /vn neu by hand. A lateral deviation does not start a route.

-- ------------------------------------------------------------
-- CHOKE-POINT FALLBACK (TechnischeDoku 10.6bq)
-- ------------------------------------------------------------
-- Finding from the NINTH live run, which 10.6bp itself documented but did not evaluate: the `pathIndex` falls back
-- between 05:57:47 (9) and 05:58:05 (8) and is back at 9 at 05:58:30. No code path except `/vn prev` and `/vn next`
-- can do that - so the user switched one step back BY HAND because he noticed that it freed him from the tangled
-- situation. Exactly this move is automated here.
--
-- Why this is necessary (measurement, not assumption). Since 10.6bl a run-up waypoint ANLAUF_ABSTAND = 2.5 yards away
-- with a generous tolerance stands in front of a choke point. If the player drifts sideways on the short run-up
-- segment - measured in the fifth run from 0.52 over 2.40 to 3.32 yards of lateral distance - he aims at the choke
-- point from a position from which there is no straight line through the gap. The announcement still stays on the
-- choke point; nothing brings him back to the run-up segment. New routes are only calculated manually; the
-- certified re-entry (10.6be/bf) practically no longer carries on smoothed routes (funnel corners have no free-space
-- certificate, 10.6bg), and the automatic recalculation is OFF at the user's request (10.6bi). Since 10.6bg there is
-- therefore NO mechanism that brings a sideways drifted player back in front of a choke point.
--
-- What the fallback does: it sets `pathIndex` back by exactly ONE step, i.e. to the run-up waypoint the player had
-- already reached. That is no new way and no recalculation - it is the same, already proven path, just one stage
-- earlier. The corridor guarantee from 10.6bg thus stays untouched word for word: not a single new waypoint and not a
-- single new segment arises.
--
-- Four conditions, all derived, none guessed:
--   1. The active waypoint is a CHOKE POINT (ChokeRadius ~= nil, i.e. a narrow spot from 10.6bj or a gate corner from
--      10.6bk). Only there is the target circle so small that a lateral offset makes it unreachable - in an open hall
--      the fallback would be unnecessary and only disturbing.
--   2. The player is farther from the ideal line than the UNSHORTENED arrival tolerance of the previous waypoint.
--      This tolerance is exactly the radius within which the arrival at the run-up point was granted to him; whoever
--      is farther out demonstrably is no longer on the run-up segment. The threshold thus comes from the already
--      existing rule set and is no new number.
--   3. There is a previous waypoint at all (pathIndex > 1).
--   4. Lock against oscillating: the same pathIndex triggers a fallback at most every FALLBACK_LOCK seconds, and only
--      ONE step is ever gone back.
local FALLBACK_LOCK = 20.0   -- seconds during which the same waypoint does not fall back again

local function ChokeFallbackOn()
    return WowVisionNavigationDB and WowVisionNavigationDB.chokeFallback ~= false
end

-- The actual re-planning step. Since 10.6dg only reachable by hand via /vn neu - the blockage escalation no longer
-- calls it automatically. The edge penalty deliberately belongs here and not in the escalation: a penalty without a
-- subsequent re-planning would silently bend a later route requested by the user.
local function PerformRecalculation(x, y, fromId, toId, trigger)
    if not Navigation.active or not Navigation.path or Navigation.directTarget then return end
    -- The penalty lies on the connection between the two waypoints (real waypoints only), so that A* sees it.
    local penaltyFrom, penaltyTo = AnchorNode(fromId), AnchorNode(toId)
    if penaltyFrom and penaltyTo and penaltyFrom ~= penaltyTo then
        EdgePenalties[penaltyFrom] = EdgePenalties[penaltyFrom] or {}
        EdgePenalties[penaltyTo] = EdgePenalties[penaltyTo] or {}
        EdgePenalties[penaltyFrom][penaltyTo] = (EdgePenalties[penaltyFrom][penaltyTo] or 0) + BLOCKAGE_EDGE_PENALTY
        EdgePenalties[penaltyTo][penaltyFrom] = (EdgePenalties[penaltyTo][penaltyFrom] or 0) + BLOCKAGE_EDGE_PENALTY
    end

    -- The user explicitly requested a replan: resolve the current provider
    -- coordinates again, never silently reuse yesterday's physical endpoint.
    if Navigation.layerTargetSource then return WowVisionNavigationLayerTargetNew() end

    -- New start: the current position, bound to the network (cell, field mask, route state).
    local targetId = Navigation.targetBindingId
    local startId = targetId and StartBinding(x, y) or nil
    local newPath
    if startId then
        local path = RouteFromStart(startId, targetId, nil, x, y)
        newPath = path and NavNetwork.SteeringTargets(path) or nil
        if newPath and Navigation.logicalTarget then newPath[#newPath + 1] = Navigation.logicalTarget end
    end
    if newPath and #newPath > 1 then
        PlayEventSound("rerouted")
        Navigation.path = newPath
        Navigation.pathIndex = 1
        Navigation.lastRouteRecalculationTime = GetTime()
        ResetApproach()
        WowVisionNavigationSay("route_recalculated",
            WowVisionNavigationText(trigger == "manual" and "recalc_manual" or "recalc_blocked"),
            #newPath)
        return true
    end
    WowVisionNavigationSay("recalc_no_alternative")
    return false
end

local function HandleBlockage(x, y, kind)
    if not Navigation.active or not Navigation.path or Navigation.directTarget then return end
    local toId = Navigation.path[Navigation.pathIndex]
    local fromId = Navigation.pathIndex > 1 and Navigation.path[Navigation.pathIndex - 1] or nil

    local count = 1
    local key
    if fromId then
        key = EdgeKey(fromId, toId)
        count = (Navigation.blockagesPerEdge[key] or 0) + 1
        Navigation.blockagesPerEdge[key] = count
    end

    -- Telemetry for the pipeline (initialization nil-safe, in case the SavedVariables table comes from an older
    -- version). 10.6ba: now written at EVERY escalation level, not only from level 2 - a single stuck episode is already
    -- a usable check order for exactly this voxel region, and exactly this data trail was missing in the live test of
    -- 2026-09-05.
    WowVisionNavigationDB.blockageTelemetry = WowVisionNavigationDB.blockageTelemetry or {}
    local telemetryEntry = {
        timestamp = date("%Y-%m-%d %H:%M:%S"),
        kind = kind or "frozen",   -- "eingefroren" | "keine_annaeherung" (10.6ba)
        worldX = x,
        worldY = y,
        estimatedHeight = HeightAnchor.height,
        edgeFrom = fromId,
        edgeTo = toId,
        blockagesOnEdge = count,
        targetName = Navigation.targetName,
        pathIndex = Navigation.pathIndex,
        pathLength = #Navigation.path,
    }

    -- 10.6bo: These four fields were missing from the blockage telemetry until now, although exactly they decided the
    -- last three diagnoses and have been listed three times as an open point in section 12 since 10.6bm. Without them
    -- every evaluation had to borrow the facing from a randomly simultaneous `/vn log` entry (10.6bm) or recompute the
    -- distance offline (10.6bn/10.6bo). They cost nothing and change no behavior.
    --   viewDirection        - do I walk at all where the announcement points?
    --   bearing              - target direction to the active waypoint (same convention:
    --                          math.atan2(dy, dx) over world x/y, directly comparable with GetPlayerFacing, see
    --                          10.6bm)
    --   distanceToWaypoint   - separates "does not get closer" from "does not arrive"
    --   isPlayerMoving       - separates the real collision case from the announcement question
    if toId then
        local zx, zy = NodePosition(toId)
        local dx, dy = zx - x, zy - y
        telemetryEntry.bearing = math.atan2(dy, dx) % (2 * math.pi)
        telemetryEntry.distanceToWaypoint = math.sqrt(dx * dx + dy * dy)
        telemetryEntry.waypointX, telemetryEntry.waypointY = zx, zy
    end
    if GetPlayerFacing then
        telemetryEntry.viewDirection = GetPlayerFacing()
    end
    if IsPlayerMoving then
        telemetryEntry.isPlayerMoving = IsPlayerMoving()
    end

    -- 10.6bp: three fields that were missing for the evaluation of the ninth run.
    --   playerSpeed   - IsPlayerMoving() only reads the MOVEMENT INTENT (key held) and flickers on a real wall
    --                   collision (see comment at BLOCKAGE_MOVEMENT_TOLERANCE). It is therefore NO proof for "the
    --                   client blocks" - but exactly this was noted as the decision rule in 10.6bo.
    --                   GetUnitSpeed("player") returns the actual speed in yards/s and really separates the two
    --                   cases: 0 with a held key = real collision, 0 without a held key = the player simply
    --                   stands.
    --   lateralDistance - distance to the ideal line of the current segment (the quantity that has been the only
    --                   consistently conspicuous one since 10.6bl).
    --   finalApproach - was the forced guidance from 10.6bp active at this moment?
    if GetUnitSpeed then
        local ok, speed = pcall(GetUnitSpeed, "player")
        -- Retail/Classic secure APIs can deliver a numerically typed secret value. Neither compare it nor store it in
        -- SavedVariables.
        if ok and (not issecretvalue or not issecretvalue(speed))
            and type(speed) == "number" then
            telemetryEntry.playerSpeed = speed
        end
    end
    if fromId and toId then
        local _t, lateral = SegmentProgressOf(x, y, fromId, toId)
        telemetryEntry.lateralDistance = lateral
    end
    telemetryEntry.finalApproach =
        FinalApproachActive(toId, telemetryEntry.distanceToWaypoint) and true or false

    table.insert(WowVisionNavigationDB.blockageTelemetry, telemetryEntry)

    -- 10.6be: The live case of 2026-09-06 was already three waypoints further in the abbey while the addon was still
    -- steering an outer node behind the player. Before the hint, the edge penalty and the recalculation the local
    -- re-entry is therefore tried first.
    --
    -- 10.6bf: Until here the attempt ran ONLY for kind == "no_approach". That was an unrelated restriction: the re-entry
    -- proves its admissibility purely geometrically (certified free-space circle in the convex Recast polygon +
    -- identical polygon ID on all skipped edges). This proof says nothing about WHY the player does not advance. This
    -- is exactly what the live run of 2026-09-06, 15:37:12 failed on: the second stuck episode on the same edge carried
    -- the signature "frozen", so the re-entry was skipped although a valid certificate existed at exactly this position
    -- (node 150652, 4.66 yards distance at 4.8 yards of certified radius, polygon 172). Instead of continuing, the
    -- only door edge was penalized with 1000 yards and rerouted from an outdated outer node - the result was the
    -- 131-waypoint outer loop. "Standing pressed against the door frame" is even the more typical case of an entrance
    -- already passed than walking around.
    local reentered, skipped, reentryDistance,
        reentryRadius, reentryPoly =
        TryRouteReentry(x, y)
    if reentered then
        if key then Navigation.blockagesPerEdge[key] = nil end
        telemetryEntry.reaction = "route_reentry"
        telemetryEntry.skippedWaypoints = skipped
        telemetryEntry.reentryDistance = reentryDistance
        telemetryEntry.reentryRadius = reentryRadius
        telemetryEntry.reentryPoly = reentryPoly
        return true
    end

    -- 10.6bq: choke-point fallback (reasoning see the comment block at FALLBACK_LOCK).
    -- Stands directly behind the certified re-entry and before every escalation level: it is the weaker but always
    -- available intervention (same path, one stage back), and it should take effect BEFORE an edge penalty or a
    -- recalculation comes into play.
    if ChokeFallbackOn() and Navigation.pathIndex > 1 and fromId and toId
        and ChokeRadius(toId) then
        local _t, lateral = SegmentProgressOf(x, y, fromId, toId)
        -- Limit: the arrival radius of the previous waypoint within which the arrival at the run-up point was granted to him
        -- (data, no number of our own).
        local limit = Guidance.ArrivalRadius(fromId) or ARRIVAL_TARGET_RADIUS
        local now = GetTime()
        local last = Navigation.fallbackTimePerIndex or {}
        if lateral and lateral > limit
            and (now - (last[Navigation.pathIndex] or -999)) >= FALLBACK_LOCK then
            last[Navigation.pathIndex] = now
            Navigation.fallbackTimePerIndex = last
            Navigation.pathIndex = Navigation.pathIndex - 1
            if key then Navigation.blockagesPerEdge[key] = nil end
            ResetApproach()
            telemetryEntry.reaction = "choke_fallback"
            telemetryEntry.fallbackLateral = lateral
            telemetryEntry.fallbackLimit = limit
            telemetryEntry.fallbackAfterIndex = Navigation.pathIndex
            PlayEventSound("rerouted")
            return true
        end
    end

    -- Telemetry is retained; automatic deviation/turn hints are silent.
    telemetryEntry.reaction = "recalculation_suppressed"

end

-- See the comment block above HandleBlockage (10.6ba): detects "moves but does not get closer" and triggers the same
-- escalation as the frozen case.
local function CheckApproach(x, y, distance, now)
    if Navigation.stagnationLastX then
        local dx, dy = x - Navigation.stagnationLastX, y - Navigation.stagnationLastY
        local step = math.sqrt(dx * dx + dy * dy)
        -- GetUnitSpeed measures real translation, while IsPlayerMoving can also report mere turning as movement. Position
        -- noise while turning must therefore not add up over ten seconds to an invented travel distance. On very old clients
        -- without GetUnitSpeed the previous position-based way remains as a fallback.
        local translational
        if type(GetUnitSpeed) == "function" then
            local ok, speed = pcall(GetUnitSpeed, "player")
            if ok and (not issecretvalue or not issecretvalue(speed))
                and type(speed) == "number" then
                translational = speed > 0.1
            end
        end
        if translational == true or translational == nil then
            Navigation.stagnationTravel = (Navigation.stagnationTravel or 0) + step
        end
    end
    Navigation.stagnationLastX, Navigation.stagnationLastY = x, y

    if not Navigation.stagnationRefTime then
        Navigation.stagnationRefDistance, Navigation.stagnationRefTime = distance, now
        Navigation.stagnationTravel = 0
        return
    end
    -- Real progress against the FIXED reference value of the window: start the window anew.
    -- The reference value is deliberately NOT updated at every small improvement - otherwise slow but steady progress
    -- (0.5 yards per measurement) would be wrongly counted as stagnation, because the reference point moves along.
    if distance <= Navigation.stagnationRefDistance - STAGNATION_MIN_APPROACH then
        Navigation.stagnationRefDistance, Navigation.stagnationRefTime = distance, now
        Navigation.stagnationTravel = 0
        return
    end
    if (now - Navigation.stagnationRefTime) < STAGNATION_WINDOW then return end
    if (Navigation.stagnationTravel or 0) < STAGNATION_MIN_TRAVEL then
        -- The player hardly moves - that is the "frozen" case handled by CheckBlockage(). Extend the window instead of
        -- escalating twice here.
        Navigation.stagnationRefTime = now
        return
    end
    ResetApproach()
    return HandleBlockage(x, y, "no_approach")
end

local function CheckBlockage(x, y, now)
    if Navigation.directTarget then return end
    -- IsPlayerMoving() is also true when turning on the spot. A changed player view direction is therefore an
    -- unambiguous signal that this measurement window does not prove a forward blockage. The angle comparison is modulo
    -- 2*pi, so that the transition between 359 and 0 degrees does not appear as a large turn.
    local viewDirection = type(GetPlayerFacing) == "function" and GetPlayerFacing() or nil
    local isTurning = false
    if viewDirection and Navigation.blockageLastViewDirection then
        local delta = ((viewDirection - Navigation.blockageLastViewDirection + math.pi)
            % (2 * math.pi)) - math.pi
        isTurning = math.abs(delta) > math.rad(0.5)
    end
    Navigation.blockageLastViewDirection = viewDirection
    if isTurning then
        Navigation.lastMovementDetectedTime = nil
        Navigation.blockageCheckX = nil
        Navigation.blockageStuckSince = nil
        Navigation.blockageEscalated = false
        return
    end
    if IsPlayerMoving() then
        Navigation.lastMovementDetectedTime = now
    end
    local triesToWalk = (now - (Navigation.lastMovementDetectedTime or -999)) < BLOCKAGE_MOVEMENT_TOLERANCE
    if not triesToWalk then
        Navigation.blockageCheckX = nil
        Navigation.blockageStuckSince = nil
        Navigation.blockageEscalated = false
        return
    end
    if not Navigation.blockageCheckX then
        Navigation.blockageCheckX, Navigation.blockageCheckY, Navigation.blockageCheckTime = x, y, now
        return
    end
    if now - Navigation.blockageCheckTime < BLOCKAGE_CHECK_INTERVAL then
        return
    end
    local dx = x - Navigation.blockageCheckX
    local dy = y - Navigation.blockageCheckY
    local movedDistance = math.sqrt(dx * dx + dy * dy)
    if movedDistance < BLOCKAGE_MIN_MOVEMENT then
        if now - Navigation.lastBumpTime >= BLOCKAGE_SOUND_INTERVAL then
            -- Something in between: clearly more audible than the original checkbox click, but not as shrill/annoying as the
            -- alarm clock - the short, clear "whisper" notification.
            PlaySound(SOUNDKIT.TELL_MESSAGE, SOUND_CHANNEL)
            Navigation.lastBumpTime = now
        end
        -- Escalation (konzept.md 5.2): only when the sticking has lasted uninterrupted for a while, and only once per
        -- episode - the beep above keeps running independently.
        Navigation.blockageStuckSince = Navigation.blockageStuckSince or now
        if Navigation.active and not Navigation.blockageEscalated
            and (now - Navigation.blockageStuckSince) >= BLOCKAGE_ESCALATION_WAIT_TIME then
            Navigation.blockageEscalated = true
            HandleBlockage(x, y)
        end
    else
        -- The player advances again - end the stuck episode, the next blockage may escalate again.
        Navigation.blockageStuckSince = nil
        Navigation.blockageEscalated = false
    end
    Navigation.blockageCheckX, Navigation.blockageCheckY, Navigation.blockageCheckTime = x, y, now
end

local function StopNavigation(reason, transitRetained, waitContextRetained)
    if _G.WowVisionNavigationDockNavigation and not waitContextRetained then
        _G.WowVisionNavigationDockNavigation:Reset(false)
    end
    if _G.WowVisionNavigationAlignStatus then
        _G.WowVisionNavigationAlignStatus.wowVisionGeneration = nil
        WowVisionNavigationAlignFineCancel()
    end
    if _G.WowVisionNavigationActionNavigation and not transitRetained then
        _G.WowVisionNavigationActionNavigation:Cancel(nil)
    end
    Navigation.pendingAction = nil
    if not transitRetained then Navigation.actionContinuation = nil end
    Navigation.active = false
    Navigation.path = nil
    Navigation.directTarget = nil
    Navigation.logicalTarget = nil
    Navigation.logicalPrepoint = nil
    Navigation.logicalWarned = nil
    Navigation.waitTargetId = nil
    Navigation.activationTargetId = nil
    Navigation.activationTarget = nil
    Navigation.activationPrepointAnnounced = nil
    Navigation.activationCaptureAnnounced = nil
    Navigation.footOnly = nil
    Navigation.targetBindingId = nil
    HeightAnchor.height = nil
    Navigation.targetStatus = nil
    Navigation.layerTargetResult = nil
    Navigation.layerTargetSource = nil
    -- The blockage state of the route expires at the route end (konzept.md 5.2): the temporary edge penalties are a
    -- runtime detour for THIS route, not a permanent graph rating (the permanent evaluation runs over the telemetry in
    -- the pipeline).
    wipe(EdgePenalties)
    Navigation.blockagesPerEdge = {}
    Navigation.lastConfirmedNode = nil
    Navigation.blockageStuckSince = nil
    Navigation.blockageEscalated = false
    ResetApproach()
    if reason then
        WowVisionNavigationPrint(reason)
    end
end

-- A single target as free orientation, not as a (not even trivial) route. The target coordinates come directly from
-- the same checked list entry as for /vn; no graph search or world travel is started.
function WowVisionNavigationStartDirect(entry)
    if entry and entry.boardingTargetId then
        local featureModule = _G.WowVisionNavigationDockNavigation
        local current
        for _, target in ipairs(WowVisionNavigationTargetList(NavData, function(t) return t.id == entry.boardingTargetId end, true)) do
            if target.id == entry.boardingTargetId and featureModule then
                current = featureModule:BoardingTarget(target, NavData); break
            end
        end
        if not current then
            WowVisionNavigationWarn("boarding_no_direction_proof")
            return false
        end
        entry = current
    end
    if type(entry) ~= "table" or type(entry.nameDe) ~= "string"
        or type(entry.x) ~= "number" or type(entry.y) ~= "number"
        or entry.x ~= entry.x or entry.y ~= entry.y
        or math.abs(entry.x) == math.huge
        or math.abs(entry.y) == math.huge then
        WowVisionNavigationSay("direct_invalid_coordinates")
        return false
    end
    local x, y = GetPlayerWorldPosition()
    if not x then
        WowVisionNavigationSay("direct_position_unavailable")
        return false
    end
    StopNavigation(nil)
    Navigation.active = true
    Navigation.directTarget = {
        x = entry.x, y = entry.y, name = TargetName(entry),
        boardingTargetId = entry.boardingTargetId, arrivalRadius = entry.arrivalRadius,
        navFingerprint = entry.navFingerprint, waitpointFingerprint = entry.waitpointFingerprint,
        lastX = x, lastY = y,
    }
    Navigation.targetName = TargetName(entry)
    Navigation.pathIndex = nil
    Navigation.lastBeepTime = 0
    Navigation.skuStraightAhead = nil
    local dx, dy = entry.x - x, entry.y - y
    WowVisionNavigationSay("direct_started", TargetName(entry), math.sqrt(dx * dx + dy * dy))
    return true
end

-- Course changes of a route: waypoints at which the direction changes by more than the click tolerance.
local function CountCourseChanges(path)
    local count = 0
    for i = 2, #path - 1 do
        local ax, ay = NodePosition(path[i - 1])
        local bx, by = NodePosition(path[i])
        local cx, cy = NodePosition(path[i + 1])
        local u, v = math.atan2(by - ay, bx - ax), math.atan2(cy - by, cx - bx)
        local delta = math.abs(((v - u + math.pi) % (2 * math.pi)) - math.pi)
        if delta > ALIGNMENT_TOLERANCE then count = count + 1 end
    end
    return count
end

local function StartNavigationToNode(targetNodeId, targetName, targetStatus, footOnly,
                                       waitTargetId, activationTargetId, logicalSource, logicalResult)
    local activationTarget
    if activationTargetId then
        for _, candidate in ipairs(WowVisionNavigationTargetList(NavData, function(t) return t.id == activationTargetId end, true)) do
            if candidate.id == activationTargetId then activationTarget = candidate; break end
        end
        local featureModule = _G.WowVisionNavigationTransitActivation
        if not featureModule or not featureModule:IsActivationTarget(activationTarget, NavData)
            or activationTarget.nodeId ~= targetNodeId then
            WowVisionNavigationWarn("activation_proof_invalid")
            return false
        end
    end
    local startId, startName, startX, startY
    if Navigation.manualStartNode and
        ((NodeType(Navigation.manualStartNode) == "water") ~= PlayerIsSwimming()) then
        Navigation.manualStartNode, Navigation.manualStartName = nil, nil
    end
    if Navigation.manualStartNode then
        -- A manual start point (set by /vn hier) takes precedence over the automatic detection: it is based on a known target
        -- point with exact x/y/z coordinates. It is discarded after use, because it refers to "where I am standing RIGHT
        -- NOW", not to future routes.
        startId = Navigation.manualStartNode
        startName = Navigation.manualStartName
        Navigation.manualStartNode = nil
        Navigation.manualStartName = nil
    else
        local x, y = GetPlayerWorldPosition()
        if not x then
            WowVisionNavigationSay("player_position_unknown")
            return false
        end
        local id, bindingOrReason = StartBinding(x, y)
        if not id then
            if bindingOrReason == "ambiguous" then
                WowVisionNavigationSay("floor_ambiguous")
            else
                WowVisionNavigationSay("no_network_attachment")
            end
            return false
        end
        startId = id
        startX, startY = x, y
    end
    local path, pathEdges, routeResult = RouteFromStart(startId, targetNodeId, footOnly, startX, startY)
    if not path then
        WowVisionNavigationSay("no_route_found")
        return false
    end
    local pendingAction = nil
    for _, edge in ipairs(pathEdges or {}) do
        if edge.action then
            local action = edge.action
            if not action.fromNode or not action.toNode then
                WowVisionNavigationSay("action_route_invalid")
                return false
            end
            -- the waiting context (dock, tram stop) and the foot-only route travel with the route after the action
            pendingAction = { actionId = action.id, targetId = targetNodeId,
                              targetName = targetName, targetStatus = targetStatus,
                              waitTargetId = waitTargetId, footOnly = footOnly }
            local truncated = {}
            for _, id in ipairs(path) do
                truncated[#truncated + 1] = id
                if id == action.fromNode then break end
            end
            path = truncated
            break
        end
    end
    -- Steering targets are the waypoints of the route, nothing else (chapter 7 point 5).
    local rawLength = #path
    path = NavNetwork.SteeringTargets(path)
    -- A new foot/transit stage ends a previously reached dock beacon; it must not jump on again after the end of that
    -- route.
    if _G.WowVisionNavigationDockNavigation then
        _G.WowVisionNavigationDockNavigation:Reset(false)
    end
    Navigation.rawPathLength = rawLength
    Navigation.searchNodes = routeResult and routeResult.expansions or nil
    Navigation.courseChanges = CountCourseChanges(path)
    Navigation.announcements = 0
    if _G.WowVisionNavigationAlignStatus then
        _G.WowVisionNavigationAlignStatus.wowVisionGeneration = nil
        WowVisionNavigationAlignFineCancel()
    end
    Navigation.active = true
    Navigation.path = path
    Navigation.pendingAction = pendingAction
    Navigation.directTarget = nil
    Navigation.targetBindingId = targetNodeId
    -- The first waypoint is the attachment of the start cell; Arrival advances along the same path.
    Navigation.pathIndex = 1
    Navigation.targetName = targetName
    Navigation.targetStatus = targetStatus or "directly_reachable"
    Navigation.footOnly = footOnly and true or false
    Navigation.waitTargetId = waitTargetId
    Navigation.activationTargetId = activationTargetId
    Navigation.activationTarget = activationTarget
    Navigation.activationPrepointAnnounced = false
    Navigation.activationCaptureAnnounced = false
    Navigation.lastRouteRecalculationTime = GetTime()
    Navigation.lastBeepTime = 0
    Navigation.skuStraightAhead = nil
    Navigation.previousX, Navigation.previousY = nil, nil
    ResetApproach()
    local _, _, startHeight = NodePosition(path[1])
    SetHeightAnchor(startHeight)
    SetRouteState(nil, path[1])
    Navigation.AppendLogicalTarget(logicalSource,logicalResult)
    NavNetwork.KeepVirtual(Navigation.path, targetNodeId)
    if startName then
        WowVisionNavigationSay("route_started_from", startName, targetName, #path)
    else
        WowVisionNavigationSay("route_started", targetName, #path)
    end
    -- 4.38 S1b: a target from a target update has no ZIEL waypoint; the guidance ends at the attachment cell, then the final
    -- approach goes to the coordinate (the logical end point), which the map does not prove
    if logicalSource and logicalSource.approx == true then WowVisionNavigationSay("approx_target") end
    return true
end

-- An unchecked finish stays outside of graph, funnel and height proofs.
function Navigation.AppendLogicalTarget(source,result)
    if not source or not result or Navigation.pendingAction or Navigation.logicalTarget or not Navigation.path then return end
    -- A certified interaction (dock waiting point, activation area) ends at its own waypoint: the transit modules take
    -- over there. A logical end point behind it would end the route as "target reached" before they act.
    if result.quality == "exact" and (source.interactionMode == "manual_wait" or source.activationMode == "walk_into_trigger") then
        return
    end
    if type(source.x) ~= "number" or type(source.y) ~= "number" then return end
    local physical=Navigation.path[#Navigation.path]
    local _,_,z=NodePosition(physical)
    local id=NavNetwork.NewVirtual({x=source.x,y=source.y,z=source.z or z,type="logical"})
    Navigation.path[#Navigation.path+1]=id
    Navigation.logicalTarget=id
    Navigation.logicalPrepoint=physical
end

function WowVisionNavigationActionArrival(action)
    local pending = Navigation.actionContinuation
    Navigation.actionContinuation = nil
    if not pending then return false end
    if pending.actionId ~= action.id or action.toZoneId ~= (NavData and NavData.zoneId)
        or type(action.toNode) ~= "number" or not NodeExists(action.toNode) then
        WowVisionNavigationSay("arrival_not_bindable")
        return false
    end
    local x, y = GetPlayerWorldPosition()
    if not x then return false end
    local _, _, z = NodePosition(action.toNode)
    SetHeightAnchor(z, x, y)
    Navigation.manualStartNode = action.toNode
    Navigation.manualStartName = WowVisionNavigationText("confirmed_exit")
    local started = StartNavigationToNode(pending.targetId, pending.targetName,
                                  pending.targetStatus,pending.footOnly,pending.waitTargetId,nil,pending.layerTargetSource,pending.layerTargetResult)
    if started then
        Navigation.layerTargetResult = pending.layerTargetResult
        Navigation.layerTargetSource = pending.layerTargetSource
        Navigation.AppendLogicalTarget(pending.layerTargetSource,pending.layerTargetResult)
    end
    return started
end

function WowVisionNavigationLayerTargetContext(footOnly,startOverride)
    local startId = startOverride or Navigation.manualStartNode
    local px,py
    if not startId then
        local x,y = GetPlayerWorldPosition()
        if not x then return nil end
        startId = StartBinding(x,y)
        px,py = x,y
    end
    if not startId then return nil end
    local context = {footOnly=footOnly,startNodeId=startId}
    context.route = function(endId)
        local path,_,result,used = RouteFromStart(context.startNodeId,endId,footOnly,px,py)
        if not path then return nil end
        context.startNodeId = used        -- the start attachment that found the way stays the start of this selection
        return path,result.cost
    end
    return context
end

function WowVisionNavigationLayerTargetStart(target,asStart,startOverride,onResolved,forceRouteTarget,travelOrder)
    local selection = _G.WowVisionNavigationTargetSelection
    if not selection or not NavData then return false end
    local context = asStart and {} or WowVisionNavigationLayerTargetContext(
        target.interactionMode == "manual_wait" or target.activationMode == "walk_into_trigger",startOverride)
    if not context then
        WowVisionNavigationSay("no_unique_start")
        return false
    end
    return selection:Prepare(NavData,target,context,function(source,result,resolvedContext)
        if asStart and result.quality ~= "exact" then
            WowVisionNavigationSay("inexact_target_no_anchor")
            return false
        end
        local view = {}
        for key,value in pairs(source) do view[key]=value end
        view.layeredResolved,view.layerResolution=true,result
        view.nodeId,view.reachable=result.endNodeId,true
        view.attachmentStatus=result.quality
        -- A nearby route does not reach a certified interaction capture.
        if result.quality ~= "exact" then
            view.interactionMode,view.activationMode=nil,nil
        end
        -- A live target delivered by a command (Questie, corpse, group) is always a route target. A "here" or direct mode
        -- still left over from the list window must not reinterpret the selection as a start anchor/direct action, especially
        -- after /vn ebene.
        local started
        if (forceRouteTarget or travelOrder) and WowVisionNavigationLayerResolvedRouteStart then
            started = WowVisionNavigationLayerResolvedRouteStart(view,travelOrder,resolvedContext.startNodeId)
        else
            started = WowVisionNavigationSelectListEntry(view,nil,resolvedContext.startNodeId)
        end
        if started and not asStart then
            -- The start node of a live route is often exactly below the player. If it were only worked off silently in the next
            -- OnUpdate, the first audible direction beacon would be omitted unnecessarily, of all things after /vn ebene. We skip
            -- it only when the XY proximity was really reached; a distant or uncertain first node stays a normal waypoint.
            if result.zUnknown and Navigation.active and Navigation.path
                and Navigation.pathIndex == 1 and #Navigation.path > 1
                and Navigation.path[1] ~= Navigation.logicalPrepoint then
                local playerX, playerY = GetPlayerWorldPosition()
                local startX, startY = NodePosition(Navigation.path[1])
                if playerX and startX then
                    local dx, dy = startX - playerX, startY - playerY
                    if dx * dx + dy * dy <= 2.25 then
                        Navigation.pathIndex = 2
                    end
                end
            end
            Navigation.layerTargetResult=result
            Navigation.layerTargetSource={}
            for key,value in pairs(source) do Navigation.layerTargetSource[key]=value end
            if Navigation.pendingAction then
                Navigation.pendingAction.layerTargetResult=result
                Navigation.pendingAction.layerTargetSource=Navigation.layerTargetSource
            end
        end
        if started and not asStart then Navigation.AppendLogicalTarget(source,result) end
        if started and onResolved then onResolved(view,result) end
        return started
    end)
end

function WowVisionNavigationLayerTargetNew()
    local source=Navigation.layerTargetSource
    if not source then return false end
    local target=source
    local catalog=_G.WowVisionNavigationTargetCatalog
    local providers=_G.WowVisionNavigationTargetProviders
    if source.providerId then
        target=nil
        target=catalog and catalog:Find(source.providerId,source.id) or nil
    elseif source.unit then
        target=providers and providers:GroupMember(source.unit) or nil
    elseif source.id=="corpse" then
        target=providers and providers:Corpse() or nil
    end
    local penalties={}
    for key,value in pairs(EdgePenalties) do penalties[key]=value end
    StopNavigation(nil)
    for key,value in pairs(penalties) do EdgePenalties[key]=value end
    if not target then
        WowVisionNavigationSay("target_source_gone")
        return false
    end
    -- Unknown height remains a fresh numbered selection, never an auto-choice.
    return WowVisionNavigationLayerTargetStart(target)
end

function WowVisionNavigationPlayerPosition()
    return GetPlayerWorldPosition()
end

local updateAccumulator = 0
local UPDATE_INTERVAL = 0.25
-- Normal navigation needs no high polling rate. As soon as the current target is a fully certified 0.5-yard capture
-- field, however, up to 1.75 yards would be possible between two 0.25 s samples at about 7 yd/s - the field could be
-- skipped without our being allowed to "overrun" it as uncertain afterwards. Only in this local state we therefore
-- read five times as often (every 0.05 s); outside of it the previous 0.25 s cycle stays unchanged.
local CAPTURE_UPDATE_INTERVAL = 0.05

local function NavigationCaptureInterval()
    return UPDATE_INTERVAL
end

-- Own update cycle, independent of the navigation: the blockage detection should ALWAYS run (even without an active
-- route), so that one generally notices when running against a wall/obstacle somewhere - not only during a guided
-- route.
local blockageAccumulator = 0
local blockageFrame = CreateFrame("Frame")
blockageFrame:SetScript("OnUpdate", function(_, elapsed)
    -- Single-target orientation uses neither the blockage check nor the periodic height anchor of the graph route. Both
    -- would be technically meaningless here.
    if Navigation.directTarget or (_G.WowVisionNavigationActionNavigation
        and _G.WowVisionNavigationActionNavigation.current) then return end
    blockageAccumulator = blockageAccumulator + elapsed
    if blockageAccumulator < UPDATE_INTERVAL then return end
    blockageAccumulator = 0

    local x, y = GetPlayerWorldPosition()
    if not x then return end

    local blockageOk, blockageError = pcall(CheckBlockage, x, y, GetTime())
    if not blockageOk then
        WowVisionNavigationDB.lastError = {
            timestamp = date("%Y-%m-%d %H:%M:%S"),
            command = "CheckBlockage (OnUpdate)",
            failure = tostring(blockageError),
        }
    end

    -- There is no layer estimation in water (WATER cells are 2D).
    if PlayerIsSwimming() then HeightAnchor.height = nil end
end)

local frame = CreateFrame("Frame")
frame:SetScript("OnUpdate", function(_, elapsed)
    local alignment = _G.WowVisionNavigationAlignStatus
    local turnFlags = _G.WowVision and _G.WowVision.movement and _G.WowVision.movement.flags
    if alignment and alignment.fine and turnFlags and (turnFlags.turnLeft or turnFlags.turnRight) then
        alignment.wowVisionGeneration = nil
        WowVisionNavigationAlignFineCancel()
    end
    local actionModule = _G.WowVisionNavigationActionNavigation
    if actionModule then
        actionModule:Tick()
        if actionModule.current and type(_G.UnitPosition) == "function" then
            local ok, x, y, z, nativeMap = pcall(_G.UnitPosition, "player")
            if ok and type(x) == "number" and type(y) == "number"
                and type(z) == "number" and type(nativeMap) == "number" then
                local action = actionModule.current.action
                actionModule:Observe({ nativeMapId = nativeMap,
                    position = { x = x, y = y, z = z },
                    mapChanged = action.fromNativeMap ~= action.toNativeMap
                        and nativeMap == action.toNativeMap,
                    -- UnitPosition Z is not live-verified in this client. A mere map change must therefore not prove the exit level.
                    zReliable = false, transportStopped = false })
            end
        end
    end
    local waitModule = not Navigation.active and _G.WowVisionNavigationDockNavigation
    if not Navigation.active and not (waitModule and waitModule.reached) then return end
    updateAccumulator = updateAccumulator + elapsed
    if updateAccumulator < NavigationCaptureInterval() then return end
    updateAccumulator = 0

    local x, y = GetPlayerWorldPosition()
    if not x then
        if Navigation.directTarget then
            StopNavigation(WowVisionNavigationText("stop_position_unavailable"))
        elseif waitModule then
            waitModule:Reset(false)
        end
        return
    end

    if not Navigation.active then
        local _, beaconX, beaconY, reachedName = waitModule:BeaconTarget(x, y, NavData)
        if not beaconX then return end
        if reachedName then
            PlayEventSound("target_reached")
            StopNavigation(WowVisionNavigationText("stop_boarding_point_reached", reachedName))
            return
        end
        local ok, viewDirection = pcall(GetPlayerFacing)
        if not ok or (issecretvalue and issecretvalue(viewDirection))
            or type(viewDirection) ~= "number" or viewDirection ~= viewDirection
            or math.abs(viewDirection) == math.huge then return end
        local dx, dy = beaconX - x, beaconY - y
        local distance = math.sqrt(dx * dx + dy * dy)
        local angle = math.atan2(dy, dx)
        local deviation = ((angle - viewDirection + math.pi) %
            (2 * math.pi)) - math.pi
        local now = GetTime()
        if now - (Navigation.lastBeepTime or 0) >= SkuBeaconInterval(deviation) then
            PlaySkuBeacon(deviation, distance)
            Navigation.lastBeepTime = now
        end
        return
    end

    if Navigation.directTarget then
        -- Free walking to exactly ONE target: no route, no corridor or blockage logic and no intermediate arrival. The 2D
        -- proximity is deliberately the same size as the announced straight-line distance.
        local target = Navigation.directTarget
        local boardingReached = false
        if target.boardingTargetId then
            local featureModule = _G.WowVisionNavigationDockNavigation
            if not featureModule or not featureModule:DirectTargetValid(target, NavData) then
                StopNavigation(WowVisionNavigationText("stop_boarding_proof_changed"))
                return
            end
            boardingReached = featureModule:PointReached(target, target.x, target.y, x, y, target.arrivalRadius)
        end
        local dx, dy = target.x - x, target.y - y
        local distance = math.sqrt(dx * dx + dy * dy)
        if boardingReached or distance <= (target.arrivalRadius or 3.0) then
            PlayEventSound("target_reached")
            StopNavigation(WowVisionNavigationText("stop_direct_reached", target.name))
            return
        end
        local angle = math.atan2(dy, dx)
        local viewDirection = GetPlayerFacing() or 0
        local deviation = ((angle - viewDirection + math.pi) %
            (2 * math.pi)) - math.pi
        local tolerance = math.rad(Navigation.skuStraightAhead and 10 or 6)
        local straightAhead = math.abs(deviation) <= tolerance
        if Navigation.skuStraightAhead == nil then
            if straightAhead then PlaySkuClick("click") end
            Navigation.skuStraightAhead = straightAhead
        elseif Navigation.skuStraightAhead ~= straightAhead then
            PlaySkuClick(straightAhead and "click" or "clack")
            Navigation.skuStraightAhead = straightAhead
        end
        local now = GetTime()
        if now - Navigation.lastBeepTime >= SkuBeaconInterval(deviation) then
            PlaySkuBeacon(deviation, distance)
            Navigation.lastBeepTime = now
        end
        return
    end

    Navigation.previousX, Navigation.previousY = Navigation.currentX, Navigation.currentY
    Navigation.currentX, Navigation.currentY = x, y
    local waypointId = Navigation.path[Navigation.pathIndex]
    if not NodeExists(waypointId) then
        StopNavigation(WowVisionNavigationText("stop_internal_error"))
        return
    end
    local waypointX, waypointY, waypointZ = NodePosition(waypointId)

    local dx, dy = waypointX - x, waypointY - y
    -- Deliberately pure 2D distance (no z): verified with /vn log that UnitPosition("player") in the open world of this
    -- client simply returns 0 as the height (no real value) - see the GetPlayerZ() comment above and TechnischeDoku.md
    -- section 10.6b. A 3D distance would have made EVERY waypoint appear "89 yards away" and triggered an endless
    -- recalculation loop.
    local distance = math.sqrt(dx * dx + dy * dy)
    if waypointId == Navigation.logicalTarget then
        if distance <= Guidance.EffectiveRadius(ARRIVAL_TARGET_RADIUS) then
            PlayEventSound("target_reached")
            StopNavigation(WowVisionNavigationText("stop_target_position_reached", Navigation.targetName))
            return
        end
        local angle=((math.atan2(dy,dx)-(GetPlayerFacing() or 0)+math.pi)%(2*math.pi))-math.pi
        local straight=math.abs(angle)<=math.rad(Navigation.skuStraightAhead and 10 or 6)
        if Navigation.skuStraightAhead ~= straight then PlaySkuClick(straight and "click" or "clack") end
        Navigation.skuStraightAhead=straight
        local now=GetTime()
        if now-Navigation.lastBeepTime>=SkuBeaconInterval(angle) then
            PlaySkuBeacon(angle,distance)
            Navigation.lastBeepTime=now
        end
        return
    end
    -- Advance the height (chapter 7 point 8): linearly along the current link between two waypoints.
    do
        local previousId = Navigation.pathIndex > 1 and Navigation.path[Navigation.pathIndex - 1] or nil
        local estimated = Guidance.Height(previousId, waypointId, x, y)
        if estimated then HeightAnchor.height = estimated; HeightAnchor.last = estimated end
    end

    -- A position deviation never starts a new route on its own.
    -- A new path is calculated manually only with /vn neu.

    local previousWaypointId = Navigation.pathIndex > 1 and Navigation.path[Navigation.pathIndex - 1] or nil
    -- The FOLLOWING waypoint determines how sharp the corner is here and thereby how much tolerance is acceptable without
    -- cutting the corner through a wall (10.6bh).
    local afterWaypointId = Navigation.path[Navigation.pathIndex + 1]
    local activationModule = _G.WowVisionNavigationTransitActivation
    local activationTarget = Navigation.activationTarget
    if activationTarget and not Navigation.activationPrepointAnnounced
        and activationModule:PrepointReached(activationTarget, x, y) then
        Navigation.activationPrepointAnnounced = true
        if activationTarget.actionSemanticStatus == "unresolved" then
            WowVisionNavigationSay("prepoint_reached_unresolved")
        else
            WowVisionNavigationSay("prepoint_reached_go_through")
        end
    end
    local lastActivation = activationTarget and Navigation.pathIndex >= #Navigation.path
    local activationObservation
    if lastActivation and activationTarget.actionSemanticStatus == "unresolved"
        and type(_G.UnitPosition) == "function" then
        local ok, _, _, _, nativeMap = pcall(_G.UnitPosition, "player")
        if ok and type(nativeMap) == "number" then activationObservation = {nativeMapId=nativeMap} end
    end
    local activationInside, activationObservationMode
    if lastActivation then
        activationInside, activationObservationMode = activationModule:CaptureReached(
            activationTarget, x, y, activationObservation)
    end
    if lastActivation and activationInside then
        if not Navigation.activationCaptureAnnounced then
            Navigation.activationCaptureAnnounced = true
            if activationTarget.actionSemanticStatus == "unresolved" then
                WowVisionNavigationSay("activation_position_reached",
                    activationObservationMode == "xy_only" and WowVisionNavigationText("height_not_confirmed") or "")
            else
                WowVisionNavigationSay("activation_area_entered")
            end
        end
        return
    end
    if not lastActivation and (not Navigation.logicalTarget or afterWaypointId ~= Navigation.logicalTarget or distance <= Guidance.EffectiveRadius(ARRIVAL_TARGET_RADIUS))
        and WaypointIsReached(x, y, distance, waypointId,
                                                     previousWaypointId, afterWaypointId ~= Navigation.logicalTarget and afterWaypointId or nil) then
        if Navigation.logicalTarget and afterWaypointId == Navigation.logicalTarget and not Navigation.logicalWarned
            and Navigation.layerTargetResult.quality ~= "exact" then
            Navigation.logicalWarned=true
            WowVisionNavigationSay("last_waypoint_careful")
        end
        Navigation.lastConfirmedNode = waypointId
        if Navigation.pathIndex >= #Navigation.path then
            if Navigation.waitTargetId then
                local target
                for _, candidate in ipairs(WowVisionNavigationTargetList(NavData, function(t) return t.id == Navigation.waitTargetId end, true)) do
                    if candidate.id == Navigation.waitTargetId then target = candidate; break end
                end
                local featureModule = _G.WowVisionNavigationDockNavigation
                local isDock = featureModule and featureModule:IsDock(target, NavData)
                StopNavigation(nil)
                if isDock then
                    PlayEventSound("target_reached")
                    featureModule:Arrival(target, NavData, x, y)
                    Navigation.lastBeepTime = GetTime()
                else
                    WowVisionNavigationWarn("wait_proof_invalid")
                end
                return
            end
            if Navigation.pendingAction then
                local pending = Navigation.pendingAction
                StopNavigation(nil)
                local mod = _G.WowVisionNavigationActionNavigation
                local started, reason = mod and mod:Start(pending.actionId, nil)
                if not started then
                    WowVisionNavigationSay("action_blocked", tostring(reason or WowVisionNavigationText("action_module_missing")))
                    return
                end
                Navigation.actionContinuation = pending
                mod:ReachedPrepoint()
                return
            end
            if Navigation.layerTargetResult and Navigation.layerTargetResult.quality ~= "exact" then
                local result = Navigation.layerTargetResult
                if result.normalizedWater then
                    StopNavigation(WowVisionNavigationText("stop_water_net_ends",
                        result.delta3D or result.deltaXY or 0,result.divingDepth or 0))
                else
                    StopNavigation(WowVisionNavigationText("stop_net_ends",
                        result.delta3D or result.deltaXY or 0,result.zUnknown and WowVisionNavigationText("suffix_horizontal") or ""))
                end
                return
            end
            PlayEventSound("target_reached")
            if Navigation.targetStatus == "approach_only" then
                StopNavigation(WowVisionNavigationText("stop_safe_approach_reached",
                    Navigation.targetName))
            else
                StopNavigation(WowVisionNavigationText("stop_target_reached", Navigation.targetName))
            end
            return
        else
            PlayEventSound("waypoint_reached")
            Navigation.announcements = (Navigation.announcements or 0) + 1
            Navigation.pathIndex = Navigation.pathIndex + 1
            SetRouteState(waypointId, Navigation.path[Navigation.pathIndex])
            -- New waypoint = new reference distance for the stagnation detection (10.6ba).
            ResetApproach()
            return
        end
    end

    -- Stagnation detection (10.6ba): only AFTER the arrival check, so that the window only runs on a waypoint that is
    -- actually still being steered to.
    local approachOk, routeChanged = pcall(
        CheckApproach, x, y, distance, GetTime())
    if not approachOk then
        WowVisionNavigationDB.lastError = {
            timestamp = date("%Y-%m-%d %H:%M:%S"),
            command = "CheckApproach (OnUpdate)",
            failure = tostring(routeChanged),
        }
    elseif routeChanged then
        -- CheckApproach has replaced the path. All local dx/dy/distance values of this tick still refer to the old waypoint
        -- and must not trigger a direction tone any more.
        return
    end

    -- NO sign adjustment here (a previous version had inserted -dy, based on a theoretical assumption about the sense of
    -- rotation of GetPlayerFacing() - refuted by a /vn log measurement with real movement: real delta X/Y vs. logged
    -- facing matches math.atan2(dy, dx) to about 9 degrees, with the -dy variant it was about 200 degrees off). The
    -- original left/right problem instead lay in the sound files themselves (see DIRECTION_SOUNDS above).
    local angleToTarget = math.atan2(dy, dx)
    local viewDirection = GetPlayerFacing() or 0
    local sector = SectorFromAngle(viewDirection, angleToTarget)

    local now = GetTime()

    -- Precise alignment detection. The SKU beacon stays active as a continuous stereo anchor INSIDE this zone as well;
    -- click and clack only mark the change into and out of it. This way it is audible at any time where the waypoint
    -- lies, without producing an intrusive permanent click.
    local signedDeviation = ((angleToTarget - viewDirection + math.pi) % (2 * math.pi)) - math.pi
    -- 10.6bk: at a gate waypoint the click tolerance is the angular width of the gap.
    local alignmentTolerance = AlignmentToleranceFor(Navigation.path[Navigation.pathIndex],
                                                          distance)
    local straightAhead = math.abs(signedDeviation) <= alignmentTolerance
    if Navigation.skuStraightAhead == nil then
        -- At the route start it is no "leaving" of the zone. Only a start that is already exactly aligned gets the positive
        -- click confirmation.
        if straightAhead then PlaySkuClick("click") end
        Navigation.skuStraightAhead = straightAhead
    elseif Navigation.skuStraightAhead ~= straightAhead then
        PlaySkuClick(straightAhead and "click" or "clack")
        Navigation.skuStraightAhead = straightAhead
    end

    if not straightAhead and FinalApproachActive(waypointId, distance) then
        -- 10.6bp: on the last FINAL_APPROACH_DISTANCE yards in front of a choke point the quantized bearing is replaced by
        -- three clearly separated commands. The SKU file gets the fixed angle left/right/back for this; its sound thus stays
        -- new, the proven final-approach logic however unchanged.
        if now - Navigation.lastBeepTime >= FINAL_APPROACH_INTERVAL then
            local finalApproachSector = FinalApproachSector(signedDeviation)
            local finalApproachAngle = finalApproachSector == FINAL_APPROACH_SECTOR_LEFT and math.pi / 2
                or finalApproachSector == FINAL_APPROACH_SECTOR_RIGHT and -math.pi / 2
                or math.pi
            PlaySkuBeacon(finalApproachAngle, distance)
            Navigation.lastBeepTime = now
        end
    else
        -- The SKU anchor is active in all directions and repeats faster in front. Its MP3 files deliver the full 5-degree
        -- stereo resolution instead of the previous maximum of 16 direction sectors.
        local interval = SkuBeaconInterval(signedDeviation)
        if now - Navigation.lastBeepTime >= interval then
            PlaySkuBeacon(signedDeviation, distance)
            Navigation.lastBeepTime = now
        end
    end
end)

-- ============================================================
-- 5. Target list (operable by keyboard and screen reader)
-- ============================================================
-- Operating concept: input field for filtering (free text), arrow keys to browse the list, Enter key to start the
-- route, Escape to close. Every selection is additionally output as chat text, so that external screen reader/read
-- aloud addons (e.g. via "read chat") can make the content accessible - no speech output engine of our own is
-- required.

local ListFrame = CreateFrame("Frame", "WowVisionNavigationListFrame", UIParent, "BackdropTemplate")
ListFrame:SetSize(420, 480)
ListFrame:SetPoint("CENTER")
ListFrame:SetMovable(true)
ListFrame:EnableMouse(true)
ListFrame:SetClampedToScreen(true)
ListFrame:Hide()

local TitleText = ListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
TitleText:SetPoint("TOP", 0, -16)
TitleText:SetText(WowVisionNavigationText("list_title"))

local HintText = ListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
HintText:SetPoint("TOP", TitleText, "BOTTOM", 0, -6)
HintText:SetText(WowVisionNavigationText("list_hint_default"))

local FilterBox = CreateFrame("EditBox", nil, ListFrame, "InputBoxTemplate")
FilterBox:SetSize(360, 24)
FilterBox:SetPoint("TOP", HintText, "BOTTOM", 0, -14)
FilterBox:SetAutoFocus(false)

local filteredList = {}
local selectionIndex = 1
-- "target" (normal route), "start" (/vn hier) or "direct" (a single free orientation anchor). Both target window
-- variants share this mode.
local SelectionMode = "target"
-- Resolution of a list entry without a route context. It depends on the target data, the settings and the network only, so it
-- is kept until one of them changes: opening the list again must not resolve thousands of targets anew. (Global: the file is at
-- the limit of file locals.)
function WowVisionNavigationResolveListed(target)
    local catalog=_G.WowVisionNavigationTargetCatalog
    local radius,tolerance=WowVisionNavigationTargetResolver:Settings()
    local store=Navigation.resolveCache
    if not (store and store.nav==NavData and store.revision==catalog.revision
        and store.radius==radius and store.tolerance==tolerance) then
        store={nav=NavData,revision=catalog.revision,radius=radius,tolerance=tolerance,results={}}
        Navigation.resolveCache=store
    end
    local key=target.expiresAt==nil and target.catalogKey or nil      -- an expiring target is resolved afresh every time
    local result=key and store.results[key]
    if not result then
        result=WowVisionNavigationTargetResolver:Resolve(NavData,target,{})
        if key then store.results[key]=result end
    end
    return result
end

-- Range within which in start point mode (/vn hier) raw door nodes are offered for selection in addition to real
-- target points - important when no NPC is nearby.
local NODE_SELECTION_RADIUS = 60.0

-- The text a list filter searches in: everything the row says except the distance (which changes while walking) - the name in
-- both languages with the search aliases, the category group, the level and the zone (localized and English). "Zephras" finds
-- every target of Zephras Isle, not only the ones with the word in their name.
-- zoneId: the zone of the provider, for a stored row or a class of a compact catalogue that carries none of its own.
local function TargetSearchText(entry, zoneId)
    local parts = { TargetName(entry) or "", entry.nameDe or "", entry.nameEn or "", WowVisionNavigationCategories(entry.category) }
    for _, alias in ipairs(entry.searchAliases or {}) do parts[#parts + 1] = alias end
    if entry.layerNumber then parts[#parts + 1] = WowVisionNavigationText("entry_layer", entry.layerNumber) end
    zoneId = entry.zoneId or zoneId
    local zone = zoneId and NavNetwork.index[zoneId]
    local zoneName = zone and LocalizedZoneName(zoneId, zone) or entry.zoneName
    if zoneName then parts[#parts + 1] = zoneName end
    if zone and zone.name then parts[#parts + 1] = zone.name end
    return table.concat(parts, " | "):lower()
end

local function TargetMatchesFilter(entry, filterLower, zoneId)
    return filterLower == "" or TargetSearchText(entry, zoneId):find(filterLower, 1, true) ~= nil
end

-- The search of the target list (/vn, /vn direkt, /vn hier). Nothing is prepared before it: the window opens empty and this runs when
-- the player confirms the search field. At most WowVisionNavigationTargetCatalog.SEARCH_LIMIT entries come back, the nearest ones in the
-- order of the list (distance). The text is tested once per class of a compact catalogue, the distance is taken from the compact
-- rows, and a row becomes a table (and is resolved) only when it is among the nearest hits, so the work is bounded by the limit and not
-- by the number of matches. Navigation.searchInfo = { total = matches before the reachability check, limit, shown, capped }.
-- filterText "": no text filter, the nearest targets of the zone scope. No position: catalogue order.
function Navigation.SearchTargets(filterText)
    local catalog = _G.WowVisionNavigationTargetCatalog
    local limit = catalog.SEARCH_LIMIT
    local info = { total = 0, limit = limit, shown = 0, capped = false }
    Navigation.searchInfo = info
    if type(_G.NavData) ~= "table" then return {} end
    local filterLower = (filterText or ""):match("^%s*(.-)%s*$"):lower()
    local mode, auto = SelectionMode, ShowAutoPoints()
    local radius, tolerance = WowVisionNavigationTargetResolver:Settings()
    local dock = _G.WowVisionNavigationDockNavigation
    local dockGeneration = dock and dock.generation or 0
    local x, y = GetPlayerWorldPosition()
    -- The cache survives the closing of the window; a decoded zone (generation) can turn an unchecked entry into a checked one.
    local cache = Navigation.listCache
    if cache and cache.nav == NavData and cache.revision == catalog.revision and cache.mode == mode and cache.filter == filterLower
        and cache.radius == radius and cache.tolerance == tolerance and cache.auto == auto and cache.dockGeneration == dockGeneration
        and cache.generation == NavNetwork.generation and cache.x == x and cache.y == y then
        Navigation.searchInfo = cache.info
        return cache.list
    end
    local generation = NavNetwork.generation
    local function accept(entry, zoneId)
        return (auto or not AutomaticListEntry(entry)) and TargetMatchesFilter(entry, filterLower, zoneId)
    end
    local n, rows, owners, d2 = 0, {}, {}, {}
    if mode ~= "start" or x then
        n, rows, owners, d2 = catalog:Scan(NavData.zoneSet, NavData.nativeMapId, accept, x, y, mode == "start" and 200 * 200 or nil)
    end
    local function ready(entry, distance2)       -- an entry that already is a table: boarding point, door node
        n = n + 1
        rows[n], owners[n], d2[n] = entry, false, distance2
    end
    -- Both lists offer the same proof-bound boarding direction on site.
    if mode ~= "start" and dock then
        for _, entry in ipairs(dock:BoardingTargets(x, y, NavData)) do
            if entry.reachable and TargetMatchesFilter(entry, filterLower) then
                ready(entry, x and (entry.x - x) ^ 2 + (entry.y - y) ^ 2 or 0)
            end
        end
    end
    -- Door nodes (showauto): not every place has an NPC within hearing range. Since the voxel graph there are no "portal" nodes and no
    -- level indication any more; choke points/doors come sparsely from NavData.knoten_label ("durchgang", the key is the 1-based Lua
    -- index). In start point mode (/vn hier) they are offered whatever the search says.
    if auto and x then
        for _, id in ipairs(NavNetwork.NodesWithin(NavData.zoneId, x, y, NODE_SELECTION_RADIUS)) do
            local kx, ky, kz = NodePosition(id)
            local distance2 = (kx - x) ^ 2 + (ky - y) ^ 2
            if distance2 <= NODE_SELECTION_RADIUS ^ 2 then
                local nameDe, nameEn = NodeDisplayName(id)
                local point = nameDe and {
                    id = "node_" .. id, nameDe = nameDe, nameEn = nameEn,
                    category = { "waypoint" }, x = kx, y = ky, z = kz,
                    nodeId = id,
                }
                if point and (mode == "start" or TargetMatchesFilter(point, filterLower)) then ready(point, distance2) end
            end
        end
    end
    info.total = n
    -- Walk the candidates nearest first until the limit is reached. A hit that is not reachable (checked zone) or an automatic ID is
    -- skipped, so more candidates than the limit may be read; the order is stable, a longer prefix extends the shorter one.
    local list, count, position, want, volatile = {}, 0, 0, limit * 2, false
    while true do
        local order = catalog.Nearest(d2, n, want)
        for j = position + 1, #order do
            position = j
            local i = order[j]
            local owner, item = owners[i], rows[i]
            if owner then
                item = catalog:Materialize(owner, item)
                if not auto and AutomaticListEntry(item) then
                    item = nil
                else
                    item.layeredTarget, item.reachable = true, true
                    -- Zones are decoded on demand: a target of a zone that no route has needed yet is offered without
                    -- a check and resolved when it is selected.
                    if item.expiresAt ~= nil then volatile = true end
                    if mode ~= "direct" and NavNetwork.PointZoneLoaded(item.x, item.y) then
                        local result = WowVisionNavigationResolveListed(item)
                        item.layerResolution = result
                        item.reachable = result.endNodeId ~= nil or result.bands ~= nil
                    end
                    if not item.reachable then item = nil end
                end
            end
            if item then
                count = count + 1
                list[count] = item
                item.distanceFromPlayer = x and math.sqrt(d2[i]) or nil
                if count >= limit then break end
            end
        end
        if count >= limit or #order >= n then break end
        want = want * 4
    end
    info.shown, info.capped = count, count >= limit and position < n
    Navigation.listCache = not volatile and { nav = NavData, revision = catalog.revision, mode = mode, filter = filterLower,
        radius = radius, tolerance = tolerance, auto = auto, dockGeneration = dockGeneration, generation = generation,
        x = x, y = y, list = list, info = info } or nil
    return list
end

local function UpdateFilter()
    wipe(filteredList)
    selectionIndex = 1
    for _, entry in ipairs(Navigation.SearchTargets(FilterBox:GetText())) do table.insert(filteredList, entry) end
    FilterBox.searched = true
end

local RowHeight = 18
local VisibleCount = 18
local RowFrames = {}
for i = 1, VisibleCount do
    local row = ListFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row:SetPoint("TOPLEFT", 20, -100 - (i - 1) * RowHeight)
    row:SetWidth(380)
    row:SetJustifyH("LEFT")
    RowFrames[i] = row
end

local function DrawList()
    for i = 1, VisibleCount do
        local entry = filteredList[i]
        if entry then
            local marker = (i == selectionIndex) and "> " or "  "
            local distanceText = entry.distanceFromPlayer and WowVisionNavigationText("row_distance", entry.distanceFromPlayer) or ""
            local zoneName = TargetZoneName(entry)
            local zoneText = zoneName and WowVisionNavigationText("row_in_zone", zoneName) or ""
            RowFrames[i]:SetText(string.format("%s%s [%s]%s%s", marker, TargetName(entry),
                WowVisionNavigationCategories(entry.category), distanceText, zoneText))
        else
            RowFrames[i]:SetText("")
        end
    end
end

function WowVisionNavigationTargetCatalogChanged()
    Navigation.listCache=nil
    if not NavData or NavData.packageLayoutVersion ~= 3 or not FilterBox or not ListFrame then return end
    -- Loading only activates the catalog, not the closed target list. An open window that has not searched yet stays empty; one
    -- that shows hits is searched again with its text (the hits are sorted by distance already).
    if not ListFrame:IsShown() or not rawget(FilterBox, "searched") then return end
    UpdateFilter()
    DrawList()
end

-- Outputs the currently selected list entry as chat text. This is the only place where a blind player learns which
-- entry is currently marked - the visual marker (">") in DrawList is not sufficient for that.
local function AnnounceSelection()
    local entry = filteredList[selectionIndex]
    if entry then
        local distanceText = entry.distanceFromPlayer and WowVisionNavigationText("entry_distance", entry.distanceFromPlayer) or ""
        local layerText = entry.layerNumber and WowVisionNavigationText("entry_layer", entry.layerNumber) or ""
        local zoneName = TargetZoneName(entry)
        local zoneText = zoneName and WowVisionNavigationText("row_in_zone", zoneName) or ""
        WowVisionNavigationSay("selected_entry_speech",
            selectionIndex, #filteredList, TargetName(entry),
            WowVisionNavigationCategories(entry.category), layerText, distanceText, zoneText)
    else
        WowVisionNavigationSay("no_hits")
    end
end

-- Both UI paths use exactly the same selection action. Only the new mode starts a single-target anchor; the previous
-- modes stay unchanged.
function WowVisionNavigationSelectListEntry(entry,travelOrder,startOverride)
    if entry and entry.layeredTarget and not entry.layeredResolved then
        if SelectionMode == "direct" then return WowVisionNavigationStartDirect(entry) end
        return WowVisionNavigationLayerTargetStart(entry,SelectionMode == "start")
    end
    if entry and entry.boardingTargetId and SelectionMode ~= "start" then
        return WowVisionNavigationStartDirect(entry)
    end
    if not entry or not entry.nodeId then
        WowVisionNavigationSay("no_target_selected")
        return false
    end
    if SelectionMode == "start" then
        if _G.WowVisionNavigationDockNavigation then
            _G.WowVisionNavigationDockNavigation:Reset(false)
        end
        Navigation.manualStartNode = entry.nodeId
        Navigation.manualStartName = TargetName(entry)
        -- /vn hier delivers an exactly known height as a real anchor.
        if entry.z then
            SetHeightAnchor(entry.z, entry.x, entry.y)
        end
        WowVisionNavigationSay("start_point_set", TargetName(entry))
        return true
    elseif SelectionMode == "direct" then
        return WowVisionNavigationStartDirect(entry)
    end
    local dock = _G.WowVisionNavigationDockNavigation
    if entry.interactionMode == "manual_wait" and dock then
        local targetZone = NavNetwork.index[entry.zoneId or (NavData and NavData.zoneId)]
        local fingerprint = targetZone and targetZone.fingerprint
        if dock:ChoosePassive(entry, NavData, fingerprint) then
            StopNavigation(nil, nil, true)
            return true
        end
        if not dock:IsDock(entry, NavData) then
            WowVisionNavigationWarn("dock_no_wait_proof")
            return false
        end
    end
    local waitpoint = entry.interactionMode == "manual_wait"
    StopNavigation(nil)
    -- Resolver and actual route must use the same safe start. After a delayed level selection it comes from the
    -- re-checked context.
    if startOverride ~= nil then Navigation.manualStartNode = startOverride end
    return StartNavigationToNode(entry.nodeId, TargetName(entry),
        entry.attachmentStatus, waitpoint, waitpoint and entry.id or nil,
        entry.activationMode == "walk_into_trigger" and entry.id or nil,entry,entry.layerResolution)
end

-- Live commands are processed independently of the most recently opened list mode. The mode is switched only for the
-- one shared selection action and restored unchanged afterwards.
function WowVisionNavigationLayerResolvedRouteStart(entry,travelOrder,startOverride)
    local previousMode = SelectionMode
    SelectionMode = "target"
    local started = WowVisionNavigationSelectListEntry(entry,travelOrder,startOverride)
    SelectionMode = previousMode
    return started
end

-- The search reads the catalogue of the zone scope (at most SEARCH_LIMIT hits come back) and then triggers a screen reader
-- announcement. It must therefore never run in OnTextChanged or in a timer started from it: letters only change the
-- EditBox. The window opens without a list; the first Enter (also on an empty field) and every Enter after a change of the text
-- searches. The Enter after that activates the marked hit.
function WowVisionNavigationUpdateFilterNow()
    FilterBox.filterGeneration = (rawget(FilterBox, "filterGeneration") or 0) + 1
    FilterBox.filterDirty = false
    UpdateFilter()
    DrawList()
    if Navigation.searchInfo and Navigation.searchInfo.capped then
        WowVisionNavigationSay("search_capped", Navigation.searchInfo.shown, Navigation.searchInfo.total)
    end
    AnnounceSelection()
end

FilterBox:SetScript("OnTextChanged", function(_, byUser)
    if byUser == false then return end
    FilterBox.filterGeneration = (rawget(FilterBox, "filterGeneration") or 0) + 1
    FilterBox.filterDirty = true
end)

FilterBox:SetScript("OnEnterPressed", function()
    if rawget(FilterBox, "filterDirty") or not rawget(FilterBox, "searched") then
        WowVisionNavigationUpdateFilterNow()
        return
    end
    local entry = filteredList[selectionIndex]
    if WowVisionNavigationSelectListEntry(entry) then
        ListFrame:Hide()
    end
end)

FilterBox:SetScript("OnEscapePressed", function()
    FilterBox.filterGeneration = (rawget(FilterBox, "filterGeneration") or 0) + 1
    FilterBox.filterDirty = false
    ListFrame:Hide()
    WowVisionNavigationSay("list_closed")
end)

FilterBox:SetScript("OnKeyDown", function(_, key)
    -- An input not yet accepted with Enter deliberately has no new list. In this state the arrow keys must operate
    -- neither the expensive scan nor the old list. Before the first search there is nothing to browse.
    if rawget(FilterBox, "filterDirty") or not rawget(FilterBox, "searched") then return end
    if key == "DOWN" then
        selectionIndex = math.min(selectionIndex + 1, #filteredList)
        DrawList()
        AnnounceSelection()
    elseif key == "UP" then
        selectionIndex = math.max(selectionIndex - 1, 1)
        DrawList()
        AnnounceSelection()
    elseif key == "HOME" then
        selectionIndex = 1
        DrawList()
        AnnounceSelection()
    elseif key == "END" then
        selectionIndex = #filteredList
        DrawList()
        AnnounceSelection()
    end
end)

ListFrame:SetScript("OnShow", function()
    FilterBox.filterGeneration = (rawget(FilterBox, "filterGeneration") or 0) + 1
    FilterBox.filterDirty = false
    -- Opening builds no list: the search field only. The targets are searched when the player confirms the field with Enter.
    FilterBox.searched = false
    wipe(filteredList)
    selectionIndex = 1
    FilterBox:SetText("")
    DrawList()
    FilterBox:SetFocus()
    local action = SelectionMode == "direct" and WowVisionNavigationText("enter_starts_direct")
        or (SelectionMode == "start" and WowVisionNavigationText("enter_sets_start")
            or WowVisionNavigationText("enter_starts_route"))
    HintText:SetText(WowVisionNavigationText("list_hint_action", action))
    WowVisionNavigationSay("list_opened", action)
end)

ListFrame:SetScript("OnHide", function()
    -- Debounce callbacks still waiting must neither filter an already closed window anew nor trigger a delayed screen
    -- reader announcement.
    FilterBox.filterGeneration = (rawget(FilterBox, "filterGeneration") or 0) + 1
    FilterBox.filterDirty = false
end)

local CloseButton = CreateFrame("Button", nil, ListFrame, "UIPanelCloseButton")
CloseButton:SetPoint("TOPRIGHT", -4, -4)

-- ============================================================
-- 5b. WowVision integration: real target window navigable with arrow keys
-- ============================================================
-- The ListFrame above (chat text announcements) is only a makeshift. If WowVision is installed, the target list is
-- built as a regular WowVision window instead (list of buttons, operable through its own navigator/TTS engine -
-- arrow keys move the focus, every entry is read aloud automatically, Enter/click starts the route, Escape closes),
-- exactly like WowVision's own atlas window (core/navigation/maps/ui.lua) or the Sku addon.

local WOWVISION_WINDOW_NAME = "wowVisionNavigationTargets"
local WowVisionAvailable = false
-- Counts openings of the window: the screen state (filter, result list) is reset at every new opening, even if
-- WowVision reuses the same screen table.
local WowVisionOpenings = 0

-- Delivers the hits of a confirmed search (at most SEARCH_LIMIT, nearest first); an empty text lists the nearest targets of the zone
-- scope. Navigation.searchInfo says whether the limit cut the list. The window calls this on Enter only, never while it opens.
local function TargetListForWowVision(filterText)
    return Navigation.SearchTargets(filterText)
end

-- Builds module and window exactly once as soon as WowVision is safely loaded (via PLAYER_LOGIN, because our addon
-- loads alphabetically before WowVision and its global table would not exist yet at our own ADDON_LOADED time).
-- WowVision >= 0.9.0 uses the graph framework (core/graph, see docs/developer/graph-ui.md): a window is a render
-- function that rebuilds the node graph on every tick. The model is WowVision's own atlas window
-- (core/navigation/maps/ui.lua). The old Dataset/Element/DataList API (hasUI, gen:Element, WowVision.Dataset) no
-- longer exists.
local function BuildWowVisionIntegration()
    if not (WowVision and WowVision.base and WowVision.UIHost and WowVision.graph
        and WowVision.graph.nodes and WowVision.graph.ControlId) then
        return false
    end
    local graph = WowVision.graph
    local nodes, ControlId = graph.nodes, graph.ControlId
    local featureModule = WowVision.base:createModule("wowVisionNavigation")
    featureModule:setLabel("WowVision Navigation")

    -- Own, real input field (invisible): Tab/Enter on the filter node gives it the keyboard focus. Typed letters only change the
    -- text; Enter confirms it and searches (the window opens without a list, so the first Enter on an empty field lists the
    -- nearest targets). Enter returns the focus to the list, Escape returns it without searching.
    local filterBox = CreateFrame("EditBox", "WowVisionNavigationFilterBox", UIParent)
    filterBox:SetSize(300, 20)
    filterBox:SetPoint("TOP", UIParent, "TOP", 0, -140)
    filterBox:SetFontObject(ChatFontNormal)
    filterBox:SetAlpha(0)
    filterBox:SetAutoFocus(false)
    filterBox:EnableMouse(false)
    -- One row of the result list as the graph shows it: the key of the node, the spoken label and the entry. Built once per search,
    -- not at every render (the graph is rebuilt regularly and a search can return a thousand entries).
    local function ResultRows(list)
        local rows, seen = {}, {}
        for _, entry in ipairs(list) do
            local key = tostring(entry.id or entry.nodeId or entry.nameDe)
            seen[key] = (seen[key] or 0) + 1
            if seen[key] > 1 then key = key .. "#" .. seen[key] end
            local distanceText = (entry.distanceFromPlayer and entry.distanceFromPlayer < math.huge)
                and WowVisionNavigationText("entry_distance", entry.distanceFromPlayer) or ""
            -- Announce the level only for indoor targets with a known floor number (see build_nav_data.py:
            -- EBENEN_CLUSTER_ABSTAND) - helps to confirm when setting a manual start point (/vn hier) that one has chosen the
            -- right NPC.
            local layerText = entry.layerNumber and WowVisionNavigationText("entry_layer", entry.layerNumber) or ""
            local zoneName = TargetZoneName(entry)
            local zoneText = zoneName and WowVisionNavigationText("row_in_zone", zoneName) or ""
            rows[#rows + 1] = { key = key, entry = entry, label = string.format("%s, %s%s%s%s", TargetName(entry),
                WowVisionNavigationCategories(entry.category), layerText, distanceText, zoneText) }
        end
        return rows
    end
    -- Runs the search of the screen for its text and keeps the result on the screen. The cut-off message is spoken at once (chat
    -- line for the screen reader) and stays as the first node of the list.
    local function Search(screen)
        screen._searched = true
        screen._showauto = ShowAutoPoints()
        local ok, list = pcall(TargetListForWowVision, screen._filter)
        if not ok then
            screen._list, screen._rows, screen._info = {}, {}, nil
            WowVisionNavigationSay("search_failed", tostring(list))
            return
        end
        screen._list, screen._info = list, Navigation.searchInfo
        screen._rows = ResultRows(list)
        if screen._info and screen._info.capped then
            WowVisionNavigationSay("search_capped", screen._info.shown, screen._info.total)
        else
            WowVisionNavigationSay("search_done", #list)
        end
    end
    local function ApplyFilter(box)
        local screen = box.currentScreen
        if screen and (screen._filterDirty or not screen._searched) then
            screen._filter = box:GetText() or ""
            screen._filterDirty = false
            Search(screen)
        end
    end
    filterBox:SetScript("OnTextChanged", function(box, byUser)
        local screen = box.currentScreen
        if byUser and screen then
            screen._filterDirty = true
            screen._filterGeneration = (screen._filterGeneration or 0) + 1
        end
    end)
    filterBox:SetScript("OnEnterPressed", function(box)
        ApplyFilter(box)
        box:ClearFocus()
    end)
    filterBox:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)

    local function render(builder, screen)
        filterBox.currentScreen = screen
        if screen._opening ~= WowVisionOpenings then
            screen._opening = WowVisionOpenings
            screen._filter = ""
            screen._filterDirty = false
            screen._filterGeneration = (screen._filterGeneration or 0) + 1
            screen._list, screen._rows, screen._info, screen._searched = nil, nil, nil, false     -- opening builds no list
            filterBox:SetText("")
            -- As in the former window: the focus is in the search field immediately, one can start typing without Enter.
            -- Slightly delayed so that the graph has announced the first node beforehand.
            if C_Timer and C_Timer.After then
                local opening = WowVisionOpenings
                C_Timer.After(0.3, function()
                    if opening == WowVisionOpenings and filterBox.currentScreen == screen then
                        filterBox:SetFocus()
                    end
                end)
            end
        end
        -- The list is searched on Enter only (and again when showauto changes under a shown list), never on opening or per tick.
        if screen._searched and screen._showauto ~= ShowAutoPoints() then Search(screen) end

        builder:pushContext("targetnavigation", "Zielnavigation")

        builder:beginStop("filter")
        builder:addItem(ControlId.structural("filter"), nodes.proxyEditBox({
            editBox = filterBox,
            label = WowVisionNavigationText("wv_filter_label"),
        }))

        -- WowVision re-renders the graph regularly. Even recreating the up to 40 target nodes can slow down keyboard input,
        -- even if the hit list is cached. As long as the real EditBox has the focus, the graph therefore consists only of the
        -- filter field; only Enter ends the focus and makes the confirmed result list visible.
        if filterBox:HasFocus() then
            builder:addItem(ControlId.structural("filterhint"), nodes.text({
                label = WowVisionNavigationText("wv_filter_hint"),
            }))
            builder:popContext()
            return
        end

        -- Filter field and list lie in the SAME tab stop, so that the down arrow leads from the search field into the list
        -- (arrow keys do not cross stops). The first step is an announcement of what the list is about, then the targets by
        -- distance.
        builder:addItem(ControlId.structural("listinfo"), nodes.text({
            label = SelectionMode == "start"
                and WowVisionNavigationText("wv_info_start")
                or (SelectionMode == "direct"
                    and WowVisionNavigationText("wv_info_direct")
                    or WowVisionNavigationText("wv_info_target")),
        }))
        if not screen._searched then
            -- Opened, nothing searched yet: only the search field and what to do with it.
            builder:addItem(ControlId.structural("searchhint"), nodes.text({ label = WowVisionNavigationText("wv_search_hint") }))
            builder:popContext()
            return
        end
        local info = screen._info
        if info and info.capped then
            builder:addItem(ControlId.structural("capped"), nodes.text({
                label = WowVisionNavigationText("search_capped", info.shown, info.total),
            }))
        end
        if #screen._list == 0 then
            builder:addItem(ControlId.structural("empty"), nodes.text({ label = WowVisionNavigationText("wv_no_targets") }))
        end
        for _, row in ipairs(screen._rows) do
            local entry = row.entry
            builder:addItem(ControlId.structural("target:" .. row.key), nodes.button({
                label = row.label,
                onActivate = function()
                    if WowVisionNavigationSelectListEntry(entry) then
                        WowVision.UIHost:closeWindow(WOWVISION_WINDOW_NAME)
                    end
                end,
            }))
        end
        builder:popContext()
    end

    featureModule:registerWindow({
        type = "ManualWindow",
        name = WOWVISION_WINDOW_NAME,
        graphScreen = { render = render, captureClose = true },
    })

    featureModule:enable()

    -- WowVision >= 0.9.0 binds the I key itself (maps/turnToWaypoint, knows only WowVision's own route and otherwise says
    -- "Kein aktiver Wegpunkt") and thereby overrides our SetOverrideBindingClick. So hook in there: if OUR route is
    -- running, the I key aligns to our waypoint, otherwise WowVision's original takes effect unchanged.
    local maps = WowVision.base.navigation and WowVision.base.navigation.maps
    if maps and type(maps.turnToWaypoint) == "function" and not maps.wowVisionNavigationHook then
        maps.wowVisionNavigationHook = true
        local original = maps.turnToWaypoint
        -- WowVision's closed-loop turn normally reports its completion with "Blickrichtung" (facing; optionally followed by
        -- the waypoint name). For our I binding the turn itself is the complete feedback. A waypoint name used only
        -- internally marks exactly this call, so that only its completion announcement is dropped and all other WowVision
        -- speech output stays unchanged.
        local silentWaypointName = WowVisionNavigationAlignStatus.silentWaypointName
        local originalSpeak = WowVision.speak
        WowVision.speak = function(self, text, ...)
            local viewDirectionText = maps.L and maps.L["Facing"]
            -- Secret strings (secret values, e.g. tooltip or buffer texts under taint) must not be compared; they are never our
            -- internal announcement.
            local secret = issecretvalue ~= nil and issecretvalue(text)
            if not secret and viewDirectionText and text == viewDirectionText .. " " .. silentWaypointName then
                -- WowVision's turn is frame-delayed. By its completion our pathIndex may already have advanced to the next
                -- waypoint; in addition the current WowVision implementation, despite its closed-loop comment, works with only ONE
                -- sweep. The completion check defined under 7a therefore now measures against the then really active waypoint and
                -- corrects in a limited way. Only afterwards the internal announcement stays silent as before.
                if type(WowVisionNavigationAlignWowVisionFinished) == "function" then
                    local ok, failure = pcall(WowVisionNavigationAlignWowVisionFinished)
                    if not ok then
                        WowVisionNavigationSay("i_correction_failed", tostring(failure))
                    end
                end
                return
            end
            return originalSpeak(self, text, ...)
        end
        -- Do not keep only for the fallback: current WowVision versions have a closed, frame-delayed and calibrated turn
        -- here. Our I function hands it our own active waypoint instead of using the outdated open SKU timing.
        maps.wowVisionNavigationOriginalTurnToWaypoint = original
        maps.turnToWaypoint = function(self, ...)
            if (Navigation.active and (Navigation.path or Navigation.directTarget))
                or (_G.WowVisionNavigationDockNavigation
                    and (_G.WowVisionNavigationDockNavigation.reached
                         or _G.WowVisionNavigationDockNavigation.passive)) then
                local ok, failure = pcall(WowVisionNavigationAlignToActiveWaypoint)
                if not ok then
                    WowVisionNavigationSay("i_alignment_failed", tostring(failure))
                end
                return ok
            end
            return original(self, ...)
        end
    end
    return true
end

-- Opens the target list via WowVision if available; otherwise fall back to the chat text window.
-- mode: "target" (default), "start" (/vn hier) or "direct" (/vn direkt).
local function OpenTargetWindow(mode)
    -- Opening builds no list (the player's search does, see Navigation.SearchTargets); the result of the last search stays cached
    -- under its key (a result with expiring entries is never cached).
    SelectionMode = mode or "target"
    -- Only the route list needs a usable start; /vn here is the remedy and /vn direct needs no route.
    if SelectionMode == "target" then WowVisionNavigationCheckStartAtOpen() end
    if WowVisionAvailable then
        WowVisionOpenings = WowVisionOpenings + 1
        local success, failure = pcall(function()
            WowVision.UIHost:openWindow(WOWVISION_WINDOW_NAME)
        end)
        if success then
            return
        end
        WowVisionNavigationSay("wv_window_failed", tostring(failure))
    end
    ListFrame:Show()
end

local wowVisionInitFrame = CreateFrame("Frame")
wowVisionInitFrame:RegisterEvent("PLAYER_LOGIN")
wowVisionInitFrame:SetScript("OnEvent", function()
    local success, result = pcall(BuildWowVisionIntegration)
    WowVisionAvailable = success and result or false
    -- WowVision also activates its own click overrides only during PLAYER_LOGIN. Our ADDON_LOADED override can therefore
    -- be displaced again despite equal priority. A zero-second timer runs after all handlers of this event and sets I
    -- finally. The global function is long defined when the event fires (the file was then executed completely); the name
    -- resolution only happens in the callback.
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, function() WowVisionNavigationRegisterKeyI() end)
    else
        WowVisionNavigationRegisterKeyI()
    end
end)

-- ============================================================
-- 6. Diagnostic log (/vn log)
-- ============================================================
-- Instead of asking the user to remember positions "roughly" (hardly practicable for a blind player anyway),
-- /vn log writes a complete diagnostic snapshot into the SavedVariables. The file can then be evaluated without the
-- user having to log anything himself. Purely reading - nothing is sent to the game.
-- NOTE: This initialization must NOT run at the top file level - WoW loads SavedVariables only AFTER the execution of
-- the addon file, but BEFORE ADDON_LOADED, and replaces the whole global table in doing so. An initialization up here
-- would therefore be overwritten again as soon as a (even empty) SavedVariables file exists - that was the cause of
-- the error "bad argument #1 to 'insert' (table expected, got nil)" at /vn log. The actual initialization is
-- therefore now in the ADDON_LOADED handler further below.

-- Calls a boolean WoW API function safely. IMPORTANT: "func and func() or nil" is a classic Lua pitfall here - if the
-- function returns `false`, "false or nil" would evaluate to nil and thereby confuse "false" with "not available"
-- (exactly this bug was in isPlayerMoving until now). Hence explicitly without "or" here.
local function SafeBool(func)
    if not func then return nil end
    local ok, result = pcall(func)
    if not ok then return nil end
    return result
end

local function CreateLogEntry(comment)
    local mapID = C_Map.GetBestMapForUnit("player")
    local nx, ny
    if mapID then
        local pos = C_Map.GetPlayerMapPosition(mapID, "player")
        if pos then nx, ny = pos:GetXY() end
    end
    local wx, wy = GetPlayerWorldPosition()
    -- Fix 2026-07-04: GetPlayerZ() ALWAYS returns 0 in the open world (10.6b) - as a result distanceToWaypoint3D and
    -- heightDifferenceToWaypoint were wrong in EVERY log entry (kzp - 0 = kzp). For the 3D diagnostic fields the height
    -- anchor estimate (konzept.md 5.1) is now used; the raw API value is additionally logged as worldZRaw.
    -- Pure diagnostic fix: the navigation logic itself still deliberately uses 2D distances.
    local wzRoh = GetPlayerZ()
    local wz = HeightAnchor.height or wzRoh
    local viewDirection = GetPlayerFacing()

    local entry = {
        timestamp = date("%Y-%m-%d %H:%M:%S"),
        mapID = mapID,
        normalizedX = nx, normalizedY = ny,
        worldX = wx, worldY = wy, worldZ = wz, worldZRaw = wzRoh,
        viewDirection = viewDirection,
        zone = GetZoneText and GetZoneText() or nil,
        subzone = GetSubZoneText and GetSubZoneText() or nil,
        navigationActive = Navigation.active,
        navigationTarget = Navigation.targetName,
        isPlayerMoving = SafeBool(IsPlayerMoving),
        -- Suggested by the user (2026-06-26): IsIndoors()/IsOutdoors() are real WoW APIs and independent of our own
        -- (possibly faulty) building detection - a good cross-check whether our node classification (indoors/outdoors) at
        -- this spot matches reality at all.
        isIndoorsPerAPI = SafeBool(IsIndoors),
        isOutdoorsPerAPI = SafeBool(IsOutdoors),
        blockageCheckX = Navigation.blockageCheckX,
        blockageCheckY = Navigation.blockageCheckY,
        -- Height anchor state (konzept.md 5.1) - for cross-checking the estimate in the game.
        estimatedHeight = HeightAnchor.height,
        comment = comment,
    }

    if Navigation.active and Navigation.path then
        local waypointId = Navigation.path[Navigation.pathIndex]
        entry.currentWaypointId = waypointId
        if NodeExists(waypointId) then
            local kxp, kyp, kzp = NodePosition(waypointId)
            entry.currentWaypointType = NodeType(waypointId)
            entry.currentWaypointZ = kzp
            if wx then
                local dx, dy = kxp - wx, kyp - wy
                local dz = wz and (kzp - wz) or 0
                entry.distanceToWaypoint = math.sqrt(dx * dx + dy * dy)
                entry.distanceToWaypoint3D = math.sqrt(dx * dx + dy * dy + dz * dz)
                entry.heightDifferenceToWaypoint = wz and (kzp - wz) or nil
            end
        end
        entry.pathIndex = Navigation.pathIndex
        entry.pathLength = #Navigation.path
        -- count levels of the report (chapter 9): 3 activated steering targets, 4 course changes, 5 announcements
        entry.countLevel3SteeringTargets = Navigation.pathIndex
        entry.countLevel3Total = #Navigation.path
        entry.countLevel4CourseChanges = Navigation.courseChanges
        entry.countLevel5Announcements = Navigation.announcements or 0
        entry.searchNodes = Navigation.searchNodes
        if waypointId and waypointId < VIRT_BASE_ID and NodeExists(waypointId) then
            local bits = NavNetwork.Bits(waypointId)
            local names = {}
            for _, entry in ipairs(AUTO_TYPES) do
                if bits % (entry[1] * 2) >= entry[1] then names[#names + 1] = entry[2] end
            end
            entry.waypointBaseCode = table.concat(names, "+")
            entry.waypointArea = NavNetwork.Area(waypointId)
            entry.waypointRadius = NavNetwork.Radius(waypointId)
            entry.waypointGateHalfWidth = NavNetwork.GateHalfWidth(waypointId)
            entry.arrivalRule = Navigation.lastArrivalRule
        end
    end

    table.insert(WowVisionNavigationDB.log, entry)
    return entry
end

local function FormatLogEntry(e, index)
    return WowVisionNavigationText("log_entry",
        index, e.timestamp, tostring(e.zone), tostring(e.subzone), tostring(e.mapID),
        e.normalizedX or -1, e.normalizedY or -1,
        e.worldX and string.format("%.1f", e.worldX) or "?",
        e.worldY and string.format("%.1f", e.worldY) or "?",
        e.viewDirection or -1, tostring(e.navigationTarget),
        e.distanceToWaypoint and WowVisionNavigationText("log_distance", e.distanceToWaypoint) or "",
        e.comment and WowVisionNavigationText("log_comment", e.comment) or ""
    )
end

-- ============================================================
-- 6a. Quest API probe (/vn qprobe)
-- ============================================================
-- MoP Classic demonstrably provides the classic quest log. Which POI/waypoint APIs are also available on this
-- concrete Interface 50504 client and what they return for different target kinds has to be measured live before the
-- actual quest navigation. /vn qprobe therefore only reads the quest currently selected in the quest log (the user
-- can make the selection with WowVision) and writes a serializable snapshot into the SavedVariables. The command
-- selects no quest and starts no route. For the context-dependent Retail POIs it briefly sets Blizzard's map context
-- to the player and parent maps and restores the previous context afterwards.

local QUEST_PROBE_MAX_SNAPSHOTS = 20
local QUEST_PROBE_MAX_TABLE_ENTRIES = 100
local QUEST_PROBE_MAX_DEPTH = 5

local function QuestProbePack(...)
    return { n = select("#", ...), ... }
end

-- Also converts modern API tables and vector objects into SavedVariables-safe values. Limits prevent an unexpectedly
-- large or cyclic Blizzard table from bloating the SavedVariables.
local function QuestProbeSerialize(value, depth, seen)
    local typeName = type(value)
    if typeName == "nil" or typeName == "string" or typeName == "number" or typeName == "boolean" then
        return value
    end
    if typeName == "table" then
        if depth >= QUEST_PROBE_MAX_DEPTH then
            return { __type = "table", __truncated = "max_depth" }
        end
        if seen[value] then
            return { __type = "table", __truncated = "cycle" }
        end
        seen[value] = true
        local copy = {}
        local count = 0
        for key, content in pairs(value) do
            count = count + 1
            if count > QUEST_PROBE_MAX_TABLE_ENTRIES then
                copy.__truncated = "too_many_entries"
                break
            end
            local keyType = type(key)
            local safeKey = key
            if keyType ~= "string" and keyType ~= "number" then
                safeKey = tostring(key)
            end
            copy[safeKey] = QuestProbeSerialize(content, depth + 1, seen)
        end
        seen[value] = nil
        return copy
    end

    local description = { __type = typeName, text = tostring(value) }
    -- Depending on the client a UiMapPoint can be a table or userdata. If GetXY exists, save the normalized coordinates
    -- explicitly instead of just a useless object address.
    local hasMethod, getXY = pcall(function() return value.GetXY end)
    if hasMethod and type(getXY) == "function" then
        local ok, x, y = pcall(getXY, value)
        if ok then
            description.x = x
            description.y = y
        end
    end
    return description
end

-- Runs an optional API and preserves both success and error. Return values are stored individually with their Lua
-- type, so that nil gaps and API variants stay visible.
local function QuestProbeCall(probe, name, func, ...)
    local entry = { available = type(func) == "function" }
    probe.calls[name] = entry
    if not entry.available then return nil end

    local packed = QuestProbePack(pcall(func, ...))
    entry.success = packed[1] == true
    if not entry.success then
        entry.failure = tostring(packed[2])
        return packed
    end

    entry.returnValues = {}
    for i = 2, packed.n do
        local value = packed[i]
        entry.returnValues[i - 1] = {
            typeName = type(value),
            value = QuestProbeSerialize(value, 0, {}),
        }
    end
    return packed
end

local function QuestProbeTitleFromPack(packed, index)
    if not packed or packed[1] ~= true or not packed[2] then return nil end
    return {
        index = index,
        title = packed[2],
        level = packed[3],
        questTag = QuestProbeSerialize(packed[4], 0, {}),
        isHeader = packed[5],
        isCollapsed = packed[6],
        completionStatus = packed[7],
        frequency = packed[8],
        questID = packed[9],
        startEvent = packed[10],
        displayQuestID = packed[11],
        isOnMap = packed[12],
        hasLocalPOI = packed[13],
        isTask = packed[14],
        isBounty = packed[15],
        isStory = packed[16],
        isHidden = packed[17],
        scaled = packed[18],
    }
end

-- Retail/Forever delivers quest log rows as tables. The normalization to the classic record is deliberately central
-- here: quest navigation and probe must not be coupled to a specific quest log interface (or its selection index).
local function QuestProbeTitleFromInfo(info, index)
    if type(info) ~= "table" then return nil end
    return {
        index = index,
        title = info.title,
        level = info.level or info.questLevel,
        questTag = QuestProbeSerialize(info.questTag, 0, {}),
        isHeader = info.isHeader == true,
        isCollapsed = info.isCollapsed == true,
        completionStatus = info.isComplete,
        frequency = info.frequency,
        questID = tonumber(info.questID),
        startEvent = info.startEvent,
        displayQuestID = info.displayQuestID,
        isOnMap = info.isOnMap,
        hasLocalPOI = info.hasLocalPOI,
        isTask = info.isTask,
        isBounty = info.isBounty,
        isStory = info.isStory,
        isHidden = info.isHidden,
        scaled = info.isScaling,
    }
end

-- Reads the selection first via the modern, ID-based contract. The index is determined afterwards only through the
-- official entry list, so that the following legacy APIs (if present) see the right entry. If the modern contract is
-- missing, the classic WowVision path stays active unchanged.
local function ReadSelectedQuest()
    local modern = C_QuestLog and type(C_QuestLog.GetSelectedQuest) == "function"
    if modern then
        local okSelection, questID = pcall(C_QuestLog.GetSelectedQuest)
        questID = okSelection and tonumber(questID) or nil
        if not questID or questID <= 0 then
            return nil, WowVisionNavigationText("quest_none_selected")
        end
        if type(C_QuestLog.GetNumQuestLogEntries) ~= "function"
            or type(C_QuestLog.GetInfo) ~= "function" then
            return nil, WowVisionNavigationText("quest_modern_no_info")
        end
        local okCount, count = pcall(C_QuestLog.GetNumQuestLogEntries)
        count = okCount and tonumber(count) or nil
        if not count or count < 0 then
            return nil, WowVisionNavigationText("quest_modern_unreadable")
        end
        for index = 1, count do
            local okInfo, info = pcall(C_QuestLog.GetInfo, index)
            local quest = okInfo and QuestProbeTitleFromInfo(info, index) or nil
            if quest and quest.questID == questID and not quest.isHeader then
                return quest
            end
        end
        return nil, WowVisionNavigationText("quest_modern_no_entry")
    end

    if type(GetQuestLogSelection) ~= "function" or type(GetQuestLogTitle) ~= "function" then
        return nil, WowVisionNavigationText("quest_api_unavailable")
    end
    local okIndex, questlogIndex = pcall(GetQuestLogSelection)
    questlogIndex = okIndex and tonumber(questlogIndex) or nil
    if not questlogIndex or questlogIndex <= 0 then
        return nil, WowVisionNavigationText("quest_none_selected")
    end

    local titlePack = QuestProbePack(pcall(GetQuestLogTitle, questlogIndex))
    local quest = QuestProbeTitleFromPack(titlePack, questlogIndex)
    if not quest or quest.isHeader or not quest.questID or quest.questID == 0 then
        return nil, WowVisionNavigationText("quest_selection_not_quest")
    end
    return quest
end

local function CreateQuestProbe()
    local probe = {
        schemaVersion = 2,
        timestamp = date("%Y-%m-%d %H:%M:%S"),
        calls = {},
        apiAvailable = {},
        questlog = {},
        trackedQuestlogIndices = {},
        maps = {},
    }

    local api = probe.apiAvailable
    api.GetQuestLogSelection = type(GetQuestLogSelection) == "function"
    api.GetNumQuestLogEntries = type(GetNumQuestLogEntries) == "function"
    api.GetQuestLogTitle = type(GetQuestLogTitle) == "function"
    api.GetNumQuestLeaderBoards = type(GetNumQuestLeaderBoards) == "function"
    api.GetQuestLogLeaderBoard = type(GetQuestLogLeaderBoard) == "function"
    api.GetNumQuestWatches = type(GetNumQuestWatches) == "function"
    api.GetQuestIndexForWatch = type(GetQuestIndexForWatch) == "function"
    api.IsQuestWatched = type(IsQuestWatched) == "function"
    api.QuestPOIGetIconInfo = type(QuestPOIGetIconInfo) == "function"
    api.GetQuestUiMapID = type(GetQuestUiMapID) == "function"
    api.QuestHasPOIInfo = type(QuestHasPOIInfo) == "function"
    api.GetQuestPOIBlobCount = type(GetQuestPOIBlobCount) == "function"
    api.GetQuestPOIs = type(GetQuestPOIs) == "function"
    api.GetQuestPOILeaderBoard = type(GetQuestPOILeaderBoard) == "function"
    api.GetTaskInfo = type(GetTaskInfo) == "function"
    api.QuestIsFromAreaTrigger = type(QuestIsFromAreaTrigger) == "function"
    api.QuestMapUpdateAllQuests = type(QuestMapUpdateAllQuests) == "function"
    api.GetQuestWorldMapAreaID = type(GetQuestWorldMapAreaID) == "function"
    api.C_QuestLog_GetQuestsOnMap = C_QuestLog and type(C_QuestLog.GetQuestsOnMap) == "function" or false
    api.C_QuestLog_GetNextWaypoint = C_QuestLog and type(C_QuestLog.GetNextWaypoint) == "function" or false
    api.C_QuestLog_GetNextWaypointForMap = C_QuestLog and type(C_QuestLog.GetNextWaypointForMap) == "function" or false
    api.C_QuestLog_GetNextWaypointText = C_QuestLog and type(C_QuestLog.GetNextWaypointText) == "function" or false
    api.C_QuestLog_GetMapForQuestPOIs = C_QuestLog and type(C_QuestLog.GetMapForQuestPOIs) == "function" or false
    api.C_QuestLog_SetMapForQuestPOIs = C_QuestLog and type(C_QuestLog.SetMapForQuestPOIs) == "function" or false
    api.C_QuestLog_GetDistanceSqToQuest = C_QuestLog and type(C_QuestLog.GetDistanceSqToQuest) == "function" or false
    api.C_QuestLog_GetQuestObjectives = C_QuestLog and type(C_QuestLog.GetQuestObjectives) == "function" or false
    api.C_QuestLog_GetSelectedQuest = C_QuestLog and type(C_QuestLog.GetSelectedQuest) == "function" or false
    api.C_QuestLog_GetNumQuestLogEntries = C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function" or false
    api.C_QuestLog_GetInfo = C_QuestLog and type(C_QuestLog.GetInfo) == "function" or false
    api.C_SuperTrack_GetSuperTrackedQuestID = C_SuperTrack and type(C_SuperTrack.GetSuperTrackedQuestID) == "function" or false
    api.C_TaskQuest_GetQuestZoneID = C_TaskQuest and type(C_TaskQuest.GetQuestZoneID) == "function" or false

    local selectionPack = QuestProbeCall(probe, "GetQuestLogSelection", GetQuestLogSelection)
    local selectionIndex = selectionPack and selectionPack[1] and tonumber(selectionPack[2]) or nil
    if selectionIndex == 0 then selectionIndex = nil end
    probe.selectionQuestlogIndex = selectionIndex

    local countPack = QuestProbeCall(probe, "GetNumQuestLogEntries", GetNumQuestLogEntries)
    local entryCount = countPack and countPack[1] and tonumber(countPack[2]) or 0
    probe.questlogEntries = entryCount
    probe.questlogQuests = countPack and countPack[1] and tonumber(countPack[3]) or nil

    local modernSelectionPack = QuestProbeCall(probe, "C_QuestLog.GetSelectedQuest",
        C_QuestLog and C_QuestLog.GetSelectedQuest or nil)
    local modernQuestID = modernSelectionPack and modernSelectionPack[1]
        and tonumber(modernSelectionPack[2]) or nil
    local modernCountPack = QuestProbeCall(probe, "C_QuestLog.GetNumQuestLogEntries",
        C_QuestLog and C_QuestLog.GetNumQuestLogEntries or nil)
    local modernCount = modernCountPack and modernCountPack[1]
        and tonumber(modernCountPack[2]) or 0

    if type(GetQuestLogTitle) == "function" then
        for index = 1, entryCount do
            local titlePack = QuestProbePack(pcall(GetQuestLogTitle, index))
            local quest = QuestProbeTitleFromPack(titlePack, index)
            if quest then
                quest.selected = index == selectionIndex
                if type(IsQuestWatched) == "function" then
                    local ok, tracked = pcall(IsQuestWatched, index)
                    if ok then quest.tracked = tracked end
                end
                table.insert(probe.questlog, quest)
                if quest.selected then probe.selectedQuest = quest end
            end
        end
    elseif type(C_QuestLog) == "table" and type(C_QuestLog.GetInfo) == "function" then
        probe.questlogEntries = modernCount
        for index = 1, modernCount do
            local infoPack = QuestProbeCall(probe, "C_QuestLog.GetInfo(" .. tostring(index) .. ")",
                C_QuestLog.GetInfo, index)
            local quest = infoPack and infoPack[1] and QuestProbeTitleFromInfo(infoPack[2], index) or nil
            if quest then
                quest.selected = quest.questID == modernQuestID and not quest.isHeader
                table.insert(probe.questlog, quest)
            end
        end
    end

    local selectedQuest, selectionError = ReadSelectedQuest()
    if selectedQuest then
        probe.selectedQuest = selectedQuest
        probe.selectionQuestlogIndex = selectedQuest.index
    elseif selectionError then
        probe.selectionError = selectionError
    end

    local watchesPack = QuestProbeCall(probe, "GetNumQuestWatches", GetNumQuestWatches)
    local watchCount = watchesPack and watchesPack[1] and tonumber(watchesPack[2]) or 0
    if type(GetQuestIndexForWatch) == "function" then
        for watchIndex = 1, watchCount do
            local ok, questlogIndex = pcall(GetQuestIndexForWatch, watchIndex)
            if ok and questlogIndex then
                table.insert(probe.trackedQuestlogIndices, questlogIndex)
            end
        end
    end

    QuestProbeCall(probe, "GetSuperTrackedQuestID", GetSuperTrackedQuestID)
    QuestProbeCall(probe, "C_SuperTrack.GetSuperTrackedQuestID",
        C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID or nil)
    QuestProbeCall(probe, "C_QuestLog.GetSuperTrackedQuestID",
        C_QuestLog and C_QuestLog.GetSuperTrackedQuestID or nil)

    local mapID
    if C_Map and type(C_Map.GetBestMapForUnit) == "function" then
        local mapPack = QuestProbeCall(probe, "C_Map.GetBestMapForUnit",
            C_Map.GetBestMapForUnit, "player")
        mapID = mapPack and mapPack[1] and mapPack[2] or nil
    end
    probe.playerMapID = mapID

    -- Examine the current map plus parent maps. Depending on the target kind, quest POIs lie on the subzone, zone or
    -- continent map.
    local knownMaps = {}
    local currentMap = mapID
    for _ = 1, 8 do
        if not currentMap or knownMaps[currentMap] then break end
        knownMaps[currentMap] = true
        local mapEntry = { mapID = currentMap }
        table.insert(probe.maps, mapEntry)
        if C_Map and type(C_Map.GetMapInfo) == "function" then
            local ok, info = pcall(C_Map.GetMapInfo, currentMap)
            if ok and info then
                mapEntry.info = QuestProbeSerialize(info, 0, {})
                local parentID = tonumber(info.parentMapID)
                currentMap = parentID and parentID > 0 and parentID or nil
            else
                currentMap = nil
            end
        else
            currentMap = nil
        end
    end

    local quest = probe.selectedQuest
    if quest and not quest.isHeader then
        local questID = quest.questID
        local questlogIndex = quest.index

        local targetCountPack = QuestProbeCall(probe, "GetNumQuestLeaderBoards",
            GetNumQuestLeaderBoards, questlogIndex)
        local targetCount = targetCountPack and targetCountPack[1]
            and tonumber(targetCountPack[2]) or 0
        quest.targets = {}
        if type(GetQuestLogLeaderBoard) == "function" then
            for targetIndex = 1, targetCount do
                local ok, text, typeName, done = pcall(GetQuestLogLeaderBoard, targetIndex, questlogIndex)
                local target = {
                    index = targetIndex,
                    success = ok,
                }
                if ok then
                    target.text = text
                    target.typeName = typeName
                    target.done = done
                else
                    target.failure = tostring(text)
                end
                table.insert(quest.targets, target)
            end
        end

        QuestProbeCall(probe, "GetQuestLogQuestText", GetQuestLogQuestText)
        QuestProbeCall(probe, "GetQuestLogCompletionText", GetQuestLogCompletionText)
        QuestProbeCall(probe, "GetQuestLogSpecialItemInfo", GetQuestLogSpecialItemInfo,
            questlogIndex)
        QuestProbeCall(probe, "GetQuestLink", GetQuestLink, questlogIndex)
        QuestProbeCall(probe, "IsQuestComplete", IsQuestComplete, questID)
        QuestProbeCall(probe, "GetQuestWorldMapAreaID", GetQuestWorldMapAreaID, questID)
        QuestProbeCall(probe, "QuestPOIGetIconInfo", QuestPOIGetIconInfo, questID)
        QuestProbeCall(probe, "GetQuestUiMapID(false)", GetQuestUiMapID, questID, false)
        QuestProbeCall(probe, "GetQuestUiMapID(true)", GetQuestUiMapID, questID, true)
        QuestProbeCall(probe, "QuestHasPOIInfo", QuestHasPOIInfo, questID)
        QuestProbeCall(probe, "GetQuestPOIBlobCount", GetQuestPOIBlobCount, questID)
        QuestProbeCall(probe, "GetTaskInfo", GetTaskInfo, questID)
        QuestProbeCall(probe, "QuestIsFromAreaTrigger", QuestIsFromAreaTrigger, questID)

        QuestProbeCall(probe, "C_QuestLog.GetQuestObjectives",
            C_QuestLog and C_QuestLog.GetQuestObjectives or nil, questID)
        QuestProbeCall(probe, "C_QuestLog.IsComplete",
            C_QuestLog and C_QuestLog.IsComplete or nil, questID)
        QuestProbeCall(probe, "C_QuestLog.ReadyForTurnIn",
            C_QuestLog and C_QuestLog.ReadyForTurnIn or nil, questID)
        QuestProbeCall(probe, "C_QuestLog.GetNextWaypoint",
            C_QuestLog and C_QuestLog.GetNextWaypoint or nil, questID)
        QuestProbeCall(probe, "C_QuestLog.GetNextWaypointText",
            C_QuestLog and C_QuestLog.GetNextWaypointText or nil, questID)
        QuestProbeCall(probe, "C_QuestLog.GetDistanceSqToQuest",
            C_QuestLog and C_QuestLog.GetDistanceSqToQuest or nil, questID)
        QuestProbeCall(probe, "C_TaskQuest.GetQuestZoneID",
            C_TaskQuest and C_TaskQuest.GetQuestZoneID or nil, questID)

        -- Retail prepares the global POI list the same way: set the map, update quests, only then read
        -- GetQuestPOIs/QuestHasPOIInfo. Without this context a quest can wrongly look like "without a point". The previous
        -- context is restored at the end.
        local poiContextPack = QuestProbeCall(probe, "C_QuestLog.GetMapForQuestPOIs",
            C_QuestLog and C_QuestLog.GetMapForQuestPOIs or nil)
        local previousPOIMap = poiContextPack and poiContextPack[1]
            and tonumber(poiContextPack[2]) or nil

        for _, map in ipairs(probe.maps) do
            local id = map.mapID
            QuestProbeCall(probe, "C_QuestLog.GetQuestsOnMap(" .. tostring(id) .. ")",
                C_QuestLog and C_QuestLog.GetQuestsOnMap or nil, id)
            QuestProbeCall(probe, "C_QuestLog.GetNextWaypointForMap(" .. tostring(id) .. ")",
                C_QuestLog and C_QuestLog.GetNextWaypointForMap or nil, questID, id)
            QuestProbeCall(probe, "C_TaskQuest.GetQuestLocation(" .. tostring(id) .. ")",
                C_TaskQuest and C_TaskQuest.GetQuestLocation or nil, questID, id)
            QuestProbeCall(probe, "C_QuestLog.SetMapForQuestPOIs(" .. tostring(id) .. ")",
                C_QuestLog and C_QuestLog.SetMapForQuestPOIs or nil, id)
            QuestProbeCall(probe, "QuestMapUpdateAllQuests(" .. tostring(id) .. ")",
                QuestMapUpdateAllQuests)
            QuestProbeCall(probe, "GetQuestPOIs(" .. tostring(id) .. ")", GetQuestPOIs)
            QuestProbeCall(probe, "QuestHasPOIInfo(" .. tostring(id) .. ")",
                QuestHasPOIInfo, questID)
            QuestProbeCall(probe, "GetQuestPOIBlobCount(" .. tostring(id) .. ")",
                GetQuestPOIBlobCount, questID)
        end

        local restoreMap = previousPOIMap or tonumber(mapID)
        if restoreMap then
            QuestProbeCall(probe,
                "C_QuestLog.SetMapForQuestPOIs(restore:" .. tostring(restoreMap) .. ")",
                C_QuestLog and C_QuestLog.SetMapForQuestPOIs or nil, restoreMap)
            QuestProbeCall(probe, "QuestMapUpdateAllQuests(restore)",
                QuestMapUpdateAllQuests)
        end
    end

    WowVisionNavigationDB.questProbes = WowVisionNavigationDB.questProbes or {}
    table.insert(WowVisionNavigationDB.questProbes, probe)
    while #WowVisionNavigationDB.questProbes > QUEST_PROBE_MAX_SNAPSHOTS do
        table.remove(WowVisionNavigationDB.questProbes, 1)
    end
    local ordinal = #WowVisionNavigationDB.questProbes

    if not quest or quest.isHeader then
        WowVisionNavigationSay("probe_saved_no_quest", ordinal)
    else
        WowVisionNavigationSay("probe_saved", ordinal,
            tostring(quest.title), tostring(quest.questID), #(quest.targets or {}))
    end
    WowVisionNavigationSay("probe_reload_hint")
    return probe
end

-- ============================================================
-- 6b. Quest area navigation (/vn q), phase 1
-- ============================================================
-- The live finding 10.6ch shows: WowVision sets GetQuestLogSelection(), and C_QuestLog.GetQuestsOnMap() delivers
-- quest-ID-exact normalized map points. This phase therefore guides to Blizzard's search/interaction area. It
-- explicitly does not yet claim to have hit a concrete mob, item or turn-in NPC exactly.

local QUEST_POI_MAX_NODE_DISTANCE = 40.0

-- Order: current map, its parents and then further already mapped UiMaps. This keeps the POI coordinate in the map
-- space the client is currently using; a smaller subarea can still be found as a fallback. New zones only need a new
-- ZONE_BOXES entry, no quest-related special rule.
local function QuestPOIMaps()
    local result, seen = {}, {}
    local function Add(mapID)
        mapID = tonumber(mapID)
        if mapID and ZONE_BOXES[mapID] and not seen[mapID] then
            seen[mapID] = true
            table.insert(result, mapID)
        end
    end

    local currentMap
    if C_Map and type(C_Map.GetBestMapForUnit) == "function" then
        local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then currentMap = mapID end
    end
    local visited = {}
    for _ = 1, 8 do
        currentMap = tonumber(currentMap)
        if not currentMap or currentMap <= 0 or visited[currentMap] then break end
        visited[currentMap] = true
        Add(currentMap)
        if not C_Map or type(C_Map.GetMapInfo) ~= "function" then break end
        local ok, info = pcall(C_Map.GetMapInfo, currentMap)
        if not ok or not info then break end
        currentMap = info.parentMapID
    end

    local rest = {}
    for mapID, box in pairs(ZONE_BOXES) do
        if not seen[mapID] then
            local areaSize = (box.xmax - box.xmin) * (box.ymax - box.ymin)
            table.insert(rest, { mapID = mapID, areaSize = areaSize })
        end
    end
    table.sort(rest, function(a, b)
        if a.areaSize == b.areaSize then return a.mapID < b.mapID end
        return a.areaSize < b.areaSize
    end)
    for _, entry in ipairs(rest) do Add(entry.mapID) end
    return result
end

local function QuestPOIOnMap(questID, mapID)
    if not C_QuestLog or type(C_QuestLog.GetQuestsOnMap) ~= "function" then return nil end
    local ok, pois = pcall(C_QuestLog.GetQuestsOnMap, mapID)
    if not ok or type(pois) ~= "table" then return nil end
    for _, poi in ipairs(pois) do
        if tonumber(poi.questID) == tonumber(questID) then
            local nx, ny = tonumber(poi.x), tonumber(poi.y)
            if nx and ny and nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
                return { mapID = mapID, nx = nx, ny = ny, source = "C_QuestLog.GetQuestsOnMap" }
            end
        end
    end
    return nil
end

local function FindQuestPOI(questID)
    local maps = QuestPOIMaps()
    for _, mapID in ipairs(maps) do
        local poi = QuestPOIOnMap(questID, mapID)
        if poi then return poi end
    end

    -- Classic fallback. The live test shows the same coordinates as GetQuestsOnMap, but without its own map ID; it is
    -- therefore only usable together with the currently supported map space.
    if type(QuestPOIGetIconInfo) == "function" and maps[1] then
        local ok, completed, nx, ny = pcall(QuestPOIGetIconInfo, questID)
        nx, ny = tonumber(nx), tonumber(ny)
        if ok and nx and ny and nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1 then
            return {
                mapID = maps[1], nx = nx, ny = ny,
                completed = completed,
                source = "QuestPOIGetIconInfo",
            }
        end
    end
    return nil
end

-- Questie is an optional, version-matching data supplier. We read only its already loaded runtime data and change
-- neither the Questie configuration nor map pins. The stable public ready contract protects against half-finished
-- data; for the actual coordinates Questie 11.38.0 currently only releases internal, defensively encapsulated
-- modules. If this contract is missing in a future version, the fallback simply stays inactive.
Navigation.FindQuestieTargetPoints = function(questID, targetIndex)
    local questie = rawget(_G, "Questie")
    local loader = rawget(_G, "QuestieLoader")
    if type(questie) ~= "table" or type(questie.API) ~= "table"
        or questie.API.isReady ~= true or type(loader) ~= "table"
        or type(loader.ImportModule) ~= "function" then return {} end

    local okDB, questieDB = pcall(loader.ImportModule, loader, "QuestieDB")
    local okZone, zoneDB = pcall(loader.ImportModule, loader, "ZoneDB")
    if not okDB or not okZone or type(questieDB) ~= "table"
        or type(zoneDB) ~= "table" or type(questieDB.GetQuest) ~= "function"
        or type(zoneDB.GetUiMapIdByAreaId) ~= "function" then return {} end

    local okQuest, questieQuest = pcall(questieDB.GetQuest, questID)
    if not okQuest or type(questieQuest) ~= "table" then return {} end
    targetIndex = tonumber(targetIndex)
    local result, seen = {}, {}
    local function Add(areaID, coordinates, kind)
        if type(coordinates) ~= "table" then return end
        local okMap, mapID = pcall(zoneDB.GetUiMapIdByAreaId, zoneDB, tonumber(areaID))
        mapID = okMap and tonumber(mapID) or nil
        if not mapID then return end
        for _, pair in pairs(coordinates) do
            local x = type(pair) == "table" and tonumber(pair[1]) or nil
            local y = type(pair) == "table" and tonumber(pair[2]) or nil
            -- Questie stores zone coordinates in percent. -1/-1 marks instance entrances and is no safe navigation point without
            -- an additional dungeon contract.
            if x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
                local key = tostring(mapID) .. ":" .. tostring(x) .. ":" .. tostring(y)
                if not seen[key] then
                    seen[key] = true
                    table.insert(result, {
                        mapID = mapID, nx = x / 100, ny = y / 100,
                        source = "QuestieDB", questieKind = kind,
                    })
                end
            end
        end
    end

    -- Exploration, event and location targets carry their coordinates directly on the matching ObjectiveData entry. The
    -- case is thereby generic and not tied to quest 62.
    local targetData = targetIndex and type(questieQuest.ObjectiveData) == "table"
        and questieQuest.ObjectiveData[targetIndex] or nil
    if type(targetData) == "table" and type(targetData.Coordinates) == "table" then
        for areaID, coordinates in pairs(targetData.Coordinates) do
            Add(areaID, coordinates, targetData.Type or "event")
        end
    end

    -- For creature, object and item targets the open objective already prepared by Questie has a spawnList. It is only
    -- read if it exists for exactly the same live objective index; there are no text or name heuristics.
    local liveTarget = targetIndex and type(questieQuest.Objectives) == "table"
        and questieQuest.Objectives[targetIndex] or nil
    if type(liveTarget) == "table" and type(liveTarget.spawnList) == "table" then
        for _, spawnData in pairs(liveTarget.spawnList) do
            if type(spawnData) == "table" and type(spawnData.Spawns) == "table" then
                for areaID, coordinates in pairs(spawnData.Spawns) do
                    Add(areaID, coordinates, liveTarget.Type or "spawn")
                end
            end
        end
    end
    return result
end

-- Questie only delivers coordinates; the network projection is done by the resolver.
Navigation.BestQuestieTargetPoint = function(questID, targetIndex)
    local points = Navigation.FindQuestieTargetPoints(questID, targetIndex)
    local playerX, playerY = GetPlayerWorldPosition()
    local best, bestScore
    for _, point in ipairs(points) do
        local worldX, worldY = NormalizedToWorld(point.mapID, point.nx, point.ny)
        if worldX then
            local score = 0
            if playerX then
                local dx,dy=worldX-playerX,worldY-playerY
                score=dx*dx+dy*dy
            end
            if not bestScore or score < bestScore then
                best,bestScore=point,score
                best.worldX,best.worldY=worldX,worldY
            end
        end
    end
    return best
end
local function StartQuestPOIFallback(quest, targetIndex, forceQuestie)
    local poi
    if forceQuestie then
        -- This explicit mode is no fallback: the coordinate necessarily comes from Questie's objective record for the next
        -- open quest objective.
        if targetIndex then
            poi = Navigation.BestQuestieTargetPoint(quest.questID, targetIndex)
        end
    else
        poi = FindQuestPOI(quest.questID)
        if not poi and targetIndex then
            poi = Navigation.BestQuestieTargetPoint(quest.questID, targetIndex)
        end
    end
    if not poi then
        if forceQuestie then
            WowVisionNavigationSay("questie_no_point", tostring(quest.title))
        else
            WowVisionNavigationSay("no_point_anywhere", tostring(quest.title))
        end
        return
    end

    local worldX, worldY = poi.worldX, poi.worldY
    if not worldX then worldX, worldY = NormalizedToWorld(poi.mapID, poi.nx, poi.ny) end
    if not worldX then
        WowVisionNavigationSay("quest_map_unsupported")
        return
    end

    if NavData.packageLayoutVersion == 3 and _G.WowVisionNavigationTargetProviders then
        local target = _G.WowVisionNavigationTargetProviders:WorldTarget(
            "quest:" .. quest.questID,WowVisionNavigationText("quest_area_name", tostring(quest.title)),
            worldX,worldY,nil,NavData.nativeMapId,poi.source=="QuestieDB" and "questie" or "wow_api")
        if target then target.layeredTarget=true;target.availability="area" end
        WowVisionNavigationSay("quest_area_found",
            WowVisionNavigationText(poi.source=="QuestieDB" and "quest_area_questie" or "quest_area_blizzard"))
        return target and WowVisionNavigationLayerTargetStart(target,nil,nil,nil,true)
    end

end

-- ============================================================
-- 6c. Live quest coordinates: Blizzard first, Questie fallback or explicit source
-- ============================================================
-- No offline QuestData or permanent objective/node bindings are consumed.
local function QuestTargetDone(quest, targetIndex)
    if C_QuestLog and type(C_QuestLog.GetQuestObjectives) == "function" then
        local ok, targets = pcall(C_QuestLog.GetQuestObjectives, quest.questID)
        if ok and type(targets) == "table" and targets[targetIndex] then
            local target = targets[targetIndex]
            return target.finished == true or target.isComplete == true
        end
    end
    if type(GetQuestLogLeaderBoard) == "function" then
        local ok, _, _, done = pcall(GetQuestLogLeaderBoard, targetIndex, quest.index)
        return ok and done == true
    end
    return false
end

local function FirstUnfinishedQuestIndex(quest)
    if C_QuestLog and type(C_QuestLog.GetQuestObjectives) == "function" then
        local ok, targets = pcall(C_QuestLog.GetQuestObjectives, quest.questID)
        if ok and type(targets) == "table" then
            for i, target in ipairs(targets) do
                if not (target.finished == true or target.isComplete == true) then return i end
            end
            return nil
        end
    end
    if type(GetNumQuestLeaderBoards) == "function" then
        local ok, count = pcall(GetNumQuestLeaderBoards, quest.index)
        if ok and tonumber(count) then
            for i = 1, count do if not QuestTargetDone(quest, i) then return i end end
            return nil
        end
    end
    return nil
end

local function StartQuestNavigation(forceQuestie)
    local quest, failure = ReadSelectedQuest()
    if not quest then WowVisionNavigationPrint(failure); return end
    return StartQuestPOIFallback(quest,FirstUnfinishedQuestIndex(quest),forceQuestie == true)
end
-- The quest log selection is deliberately kept separate from the navigation. It starts no route and can therefore
-- change neither graph nor waypoints. The number at qselect counts only real quests, never zone headers, so that it
-- stably means 1, 2, 3 ... for screen reader users.
Navigation.ReadQuestlogQuests = function()
    local result = {}
    if C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function"
        and type(C_QuestLog.GetInfo) == "function" then
        local okCount, count = pcall(C_QuestLog.GetNumQuestLogEntries)
        count = okCount and tonumber(count) or nil
        if not count then return nil, WowVisionNavigationText("quest_modern_unreadable_short") end
        for index = 1, count do
            local okInfo, info = pcall(C_QuestLog.GetInfo, index)
            local quest = okInfo and QuestProbeTitleFromInfo(info, index) or nil
            if quest and quest.questID and quest.questID > 0 and not quest.isHeader then
                table.insert(result, quest)
            end
        end
        return result
    end
    if type(GetNumQuestLogEntries) ~= "function" or type(GetQuestLogTitle) ~= "function" then
        return nil, WowVisionNavigationText("quest_api_unavailable")
    end
    local okCount, count = pcall(GetNumQuestLogEntries)
    count = okCount and tonumber(count) or nil
    if not count then return nil, WowVisionNavigationText("quest_classic_unreadable") end
    for index = 1, count do
        local quest = QuestProbeTitleFromPack(QuestProbePack(pcall(GetQuestLogTitle, index)), index)
        if quest and quest.questID and quest.questID > 0 and not quest.isHeader then
            table.insert(result, quest)
        end
    end
    return result
end

Navigation.SetQuestSelection = function(ordinal)
    ordinal = tonumber(ordinal)
    if not ordinal or ordinal < 1 or ordinal ~= math.floor(ordinal) then
        return nil, WowVisionNavigationText("qselect_usage_number")
    end
    local quests, failure = Navigation.ReadQuestlogQuests()
    if not quests then return nil, failure end
    local quest = quests[ordinal]
    if not quest then
        return nil, WowVisionNavigationText("qselect_only_n", #quests)
    end
    if C_QuestLog and type(C_QuestLog.SetSelectedQuest) == "function" then
        local ok, apiError = pcall(C_QuestLog.SetSelectedQuest, quest.questID)
        if not ok then return nil, WowVisionNavigationText("qselect_modern_failed", tostring(apiError)) end
    elseif type(SelectQuestLogEntry) == "function" then
        local ok, apiError = pcall(SelectQuestLogEntry, quest.index)
        if not ok then return nil, WowVisionNavigationText("qselect_classic_failed", tostring(apiError)) end
    else
        return nil, WowVisionNavigationText("qselect_unsupported")
    end
    return quest
end

-- ============================================================
-- 7. Slash-Befehle
-- ============================================================

SLASH_WOWVISIONNAVIGATION1 = "/vn"
SLASH_WOWVISIONNAVIGATION2 = "/wowvisionnavigation"

-- The wrapper catches runtime errors and outputs them as chat text instead of showing them only in the (purely
-- visual, inaccessible for screen readers) Lua error window.
-- /vn lang [de|en|auto]: saves the text language choice and shows what the client reports and the language in use.
local function LanguageCommand(argument)
    local L = WowVisionNavigationLocalization
    argument = argument:match("^%s*(.-)%s*$")
    local function Name(choice)
        if choice == "de" then return WowVisionNavigationText("lang_name_de") end
        if choice == "en" then return WowVisionNavigationText("lang_name_en") end
        return WowVisionNavigationText("lang_auto")
    end
    if argument == "de" or argument == "en" or argument == "auto" then
        WowVisionNavigationDB.language = argument ~= "auto" and argument or nil
        WowVisionNavigationSay("lang_set", Name(argument))
    elseif argument ~= "" then
        WowVisionNavigationSay("lang_usage")
        return
    end
    local locale, textLocale, gameLocale = L.Signals()
    local none = WowVisionNavigationText("lang_none")
    WowVisionNavigationSay("lang_status", Name(L.IsGerman() and "de" or "en"), Name(WowVisionNavigationDB.language),
        locale or none, textLocale or none, gameLocale or none)
end

-- Recalculates the running route from the current position (/vn neu and a changed comfort level). Returns true when a
-- recalculation was started.
local function RecalculateRunningRoute(announce)
    if Navigation.directTarget then
        if announce then WowVisionNavigationSay("direct_no_recalculation") end
    elseif not Navigation.active or not Navigation.path then
        if announce then WowVisionNavigationSay("no_active_navigation") end
    else
        local x, y = GetPlayerWorldPosition()
        if not x then
            if announce then WowVisionNavigationSay("position_not_determinable") end
        else
            local toId = Navigation.path[Navigation.pathIndex]
            local fromId = Navigation.pathIndex > 1 and Navigation.path[Navigation.pathIndex - 1] or nil
            PerformRecalculation(x, y, fromId, toId, "manual")
            return true
        end
    end
    return false
end

-- /vn comfort [p]: comfort level 0 to 300 percent (4.34), saved; without a value it announces the current level.
local function ComfortCommand(argument)
    argument = argument:match("^%s*(.-)%s*$")
    if argument == "" then
        WowVisionNavigationSay("comfort_status", string.format("%g", NavNetwork.comfort), string.format("%g", NavNetwork.ROAD_MAX_RATIO))
        return
    end
    local number = tonumber((argument:gsub("%%$", ""):gsub(",", ".")))
    if not number or not NavNetwork.SetComfort(number) then
        WowVisionNavigationSay("comfort_invalid", argument)
        return
    end
    WowVisionNavigationDB.comfort = number
    WowVisionNavigationSay("comfort_set", string.format("%g", number))
    if Navigation.active and Navigation.path and not Navigation.directTarget then
        WowVisionNavigationSay("comfort_recalculated")
        RecalculateRunningRoute(false)
    end
end

-- /vn arrival [yards]: minimum arrival radius (0 to 10 yd, 0 = off), saved; without a value it announces the setting.
-- The effective radius of a waypoint is max(radius of the data, setting), see Guidance.EffectiveRadius. (Global: the file is
-- at the limit of file locals.)
function WowVisionNavigationArrivalCommand(argument)
    argument = argument:match("^%s*(.-)%s*$")
    if argument == "" then
        local minimum = Guidance.MinArrivalRadius()
        if minimum > 0 then
            WowVisionNavigationSay("arrival_status", string.format("%g", minimum))
        else
            WowVisionNavigationSay("arrival_status_off")
        end
        return
    end
    local number = tonumber((argument:gsub(",", ".")))
    if not number or number ~= number or number < 0 or number > 10 then
        WowVisionNavigationSay("arrival_invalid", argument)
        return
    end
    if number == 0 then
        WowVisionNavigationDB.arrivalMin = nil
        WowVisionNavigationSay("arrival_off")
        return
    end
    WowVisionNavigationDB.arrivalMin = number
    WowVisionNavigationSay("arrival_set", string.format("%g", number))
end

local function ExecuteSlashCommand(msg)
    -- The German command words and their English aliases are both valid; the core works with the English word.
    local msgLower = WowVisionNavigationNormalizeCommand(msg:lower())
    if _G.WowVisionNavigationTargetSelection and
        _G.WowVisionNavigationTargetSelection:Command(msgLower) then return end
    -- Data-dependent commands may only run after the LoadOnDemand package matching the current zone has passed its
    -- contract AND BuildGraph has completed successfully. Status/diagnostic/settings commands stay usable outside of
    -- mapped zones as well.
    local needsZoneData = msgLower == "" or msgLower == "here"
        or msgLower == "direct" or msgLower == "new"
        or msgLower == "q" or msgLower == "q questie fix"
    if needsZoneData then
        local loader = _G.WowVisionNavigationZoneLoader
        if type(loader) ~= "table" or not loader:DataReadyOrReport() then return end
    end
    if msgLower == "help" then
        WowVisionNavigationHelp()
    elseif msgLower == "lang" or msgLower:match("^lang%s") then
        LanguageCommand(msgLower:sub(5))
    elseif msgLower == "comfort" or msgLower:match("^comfort%s") then
        ComfortCommand(msgLower:sub(8))
    elseif msgLower == "arrival" or msgLower:match("^arrival%s") then
        WowVisionNavigationArrivalCommand(msgLower:sub(8))
    elseif msgLower == "stop" then
        if _G.WowVisionNavigationTargetSelection then
            _G.WowVisionNavigationTargetSelection.pending = nil
        end
        StopNavigation(WowVisionNavigationText("stop_manual"))
    elseif msgLower == "action" then
        local mod = _G.WowVisionNavigationActionNavigation
        WowVisionNavigationPrint(mod and mod:Status() or WowVisionNavigationText("action_module_unavailable"))
    elseif msgLower == "continue" then
        local mod = _G.WowVisionNavigationActionNavigation
        if not mod then
            WowVisionNavigationPrint(WowVisionNavigationText("action_module_unavailable"))
        else
            local ok, reason
            if mod.current and mod.current.phase == "disembarking" then
                ok = mod:ReachedExit()
            else
                ok, reason = mod:Confirm()
            end
            if not ok then
                WowVisionNavigationPrint(tostring(reason or WowVisionNavigationText("action_no_phase")))
            end
        end
    elseif msgLower == "status" then
        if Navigation.directTarget then
            local x, y = GetPlayerWorldPosition()
            local target = Navigation.directTarget
            local distanceText = ""
            if x then
                local dx, dy = target.x - x, target.y - y
                distanceText = WowVisionNavigationText("status_direct_distance",
                    math.sqrt(dx * dx + dy * dy))
            end
            WowVisionNavigationSay("status_direct",
                target.name, distanceText)
            print(WowVisionNavigationText("status_direct_note"))
        elseif Navigation.active then
            WowVisionNavigationSay("status_en_route",
                Navigation.targetName, Navigation.pathIndex, #Navigation.path)
        else
            WowVisionNavigationSay("no_active_navigation")
        end
        WowVisionNavigationSay("status_final_approach", FINAL_APPROACH_DISTANCE,
            WowVisionNavigationText(FinalApproachOn() and "state_on" or "state_off"))
        WowVisionNavigationSay("status_choke_fallback",
            WowVisionNavigationText(ChokeFallbackOn() and "state_on" or "state_off"))
        WowVisionNavigationSay("status_sku_tone", SKU_NAV_STANDARD)
    elseif msgLower == "here" then
        -- Manual start point: opens the same searchable list, but a selection only sets "I am standing here right now" (e.g.
        -- an NPC one hears) instead of starting a route. Solves the problem that the WoW API delivers no real player height
        -- (see TechnischeDoku.md section 10.6b) - via a known target point with exact x/y/z coordinates as a reference this
        -- becomes unnecessary.
        OpenTargetWindow("start")
    elseif msgLower == "direct" then
        if not GetPlayerWorldPosition() then
            WowVisionNavigationSay("direct_list_position_unavailable")
            return
        end
        OpenTargetWindow("direct")
    elseif msgLower == "prev" or msgLower == "next" then
        -- Manual forward/backward jump in the current path - helpful if a single waypoint (e.g. at a door) cannot be reached
        -- or one made a mistake.
        if Navigation.directTarget then
            WowVisionNavigationSay("direct_no_waypoints")
        elseif not Navigation.active or not Navigation.path then
            WowVisionNavigationSay("no_active_navigation")
        else
            local newIndex = Navigation.pathIndex + (msgLower == "next" and 1 or -1)
            newIndex = math.max(1, math.min(newIndex, #Navigation.path))
            if newIndex == Navigation.pathIndex then
                WowVisionNavigationSay("already_at_waypoint",
                    WowVisionNavigationText(msgLower == "next" and "ordinal_last" or "ordinal_first"))
            else
                Navigation.pathIndex = newIndex
                local nodeId = Navigation.path[Navigation.pathIndex]
                SetRouteState(Navigation.path[newIndex - 1], nodeId)
                WowVisionNavigationSay("waypoint_selected",
                    Navigation.pathIndex, #Navigation.path, WowVisionNavigationNodeTypeName(NodeExists(nodeId) and NodeType(nodeId) or "unknown"))
            end
        end
    elseif msgLower == "showauto" or msgLower:match("^showauto%s") then
        local arg = msgLower:match("^showauto%s+(%S+)$")
        if arg == "on" or arg == "an" or arg == "ja" then
            WowVisionNavigationDB.showauto = true
        elseif arg == "off" or arg == "aus" or arg == "nein" then
            WowVisionNavigationDB.showauto = false
        elseif arg ~= nil or msgLower ~= "showauto" then
            WowVisionNavigationSay("showauto_usage")
            return
        end
        WowVisionNavigationSay("showauto_status", ShowAutoPoints() and "On" or "Off")
        Navigation.listCache = nil
        if ListFrame:IsShown() and rawget(FilterBox, "searched") then
            UpdateFilter()
            DrawList()
        end
    elseif msgLower == "autonew" or msgLower:match("^autonew%s") then
        -- 10.6dg: The former switch is removed. Automatic redirecting on blockage must never happen again - the user decides
        -- himself how to follow a route.
        WowVisionNavigationSay("autonew_removed")
    elseif msgLower == "fine" or msgLower:match("^fine%s") then
        -- The former 16-sector option is technically replaced by the fixed 5-degree SKU files. An apparent switch would be
        -- misleading.
        WowVisionNavigationSay("fine_removed", SKU_NAV_STANDARD)
    elseif msgLower == "finalapproach" or msgLower:match("^finalapproach%s") then
        -- 10.6bp: switch for the forced guidance on the last 2.5 yards in front of a choke point (only left / right /
        -- you-look-away instead of a quantized bearing). Default ON; "aus" restores exactly the behavior of 10.6bm/bn.
        local arg = msgLower:match("^finalapproach%s+(%S+)$")
        local newValue
        if arg == nil then
            newValue = not FinalApproachOn()
        elseif arg == "an" or arg == "ein" or arg == "on" or arg == "1" then
            newValue = true
        elseif arg == "aus" or arg == "off" or arg == "0" then
            newValue = false
        else
            WowVisionNavigationSay("finalapproach_usage")
            return
        end
        WowVisionNavigationDB.finalApproach = newValue
        if newValue then
            WowVisionNavigationSay("finalapproach_on")
        else
            WowVisionNavigationSay("finalapproach_off")
        end
    elseif msgLower == "fallback" or msgLower:match("^fallback%s") then
        -- 10.6bq: switch for the automatic fallback to the previous waypoint if the player has strayed sideways from the
        -- route in front of a narrow spot. Default ON; "aus" restores exactly the behavior of 10.6bp.
        local arg = msgLower:match("^fallback%s+(%S+)$")
        local newValue
        if arg == nil then
            newValue = not ChokeFallbackOn()
        elseif arg == "an" or arg == "ein" or arg == "on" or arg == "1" then
            newValue = true
        elseif arg == "aus" or arg == "off" or arg == "0" then
            newValue = false
        else
            WowVisionNavigationSay("fallback_usage")
            return
        end
        WowVisionNavigationDB.chokeFallback = newValue
        if newValue then
            WowVisionNavigationSay("fallback_on")
        else
            WowVisionNavigationSay("fallback_off")
        end
    elseif msgLower == "new" then
        -- Manual recalculation - the replacement for the disabled automatism.
        RecalculateRunningRoute(true)
    elseif msgLower:match("^qselect%s+") then
        local ordinal = msg:match("^[Qq][Ss][Ee][Ll][Ee][Cc][Tt]%s+(%S+)%s*$")
        local quest, failure = Navigation.SetQuestSelection(ordinal)
        if quest then
            WowVisionNavigationSay("qselect_done",
                tostring(ordinal), tostring(quest.title), quest.questID)
        else
            WowVisionNavigationPrint(tostring(failure))
        end
    elseif msgLower == "qselect" then
        WowVisionNavigationSay("qselect_usage")
    elseif msgLower == "q" then
        StartQuestNavigation()
    elseif msgLower == "q questie fix" then
        StartQuestNavigation(true)
    elseif msgLower == "qprobe" then
        CreateQuestProbe()
    elseif msgLower == "log" or msgLower:match("^log ") then
        local comment = msg:match("^[Ll][Oo][Gg]%s+(.+)$")
        local entry = CreateLogEntry(comment)
        WowVisionNavigationSay("log_saved",
            FormatLogEntry(entry, #WowVisionNavigationDB.log))
        WowVisionNavigationSay("log_total", #WowVisionNavigationDB.log)
    elseif msgLower == "logshow" then
        if #WowVisionNavigationDB.log == 0 then
            WowVisionNavigationSay("log_none")
        else
            for i, e in ipairs(WowVisionNavigationDB.log) do
                print(FormatLogEntry(e, i))
            end
        end
    elseif msgLower == "logclear" then
        wipe(WowVisionNavigationDB.log)
        WowVisionNavigationSay("log_cleared")
    elseif msgLower == "" then
        OpenTargetWindow()
    else
        WowVisionNavigationSay("unknown_command")
    end
end

SlashCmdList["WOWVISIONNAVIGATION"] = function(msg)
    msg = strtrim(msg or "")
    local success, failure = pcall(ExecuteSlashCommand, msg)
    if not success then
        -- Additionally write the error text into the SavedVariables (visible after /reload), so that it can be evaluated
        -- without the player having to type off a speech output.
        WowVisionNavigationDB.lastError = {
            timestamp = date("%Y-%m-%d %H:%M:%S"),
            command = msg,
            failure = tostring(failure),
        }
        WowVisionNavigationSay("command_error", tostring(failure))
    end
end

-- ============================================================
-- 7a. Key I: roughly align to the active route
-- ============================================================
-- SKU binds the I key to `GameWorldObjectsTurnToWp()`. The implementation there turns only the camera with
-- MoveViewLeft/Right and afterwards hands its facing once to the character via MouselookStart/MouselookStop. No
-- movement or interaction API is called. The APIs used here are not marked as protected in the MoP Classic API
-- catalog; in particular TurnLeft/RightStart, MoveForwardStart, MoveAndSteerStart or a SecureAction are deliberately
-- NOT used.
--
-- A key press starts a limited alignment. Small residual angles are corrected closed-loop with slow camera pulses
-- and a freshly measured character direction. This table and function are deliberately named globally: the addon
-- file is already at the Lua 5.1 limit of 200 simultaneously visible file locals. Function locals are separate from
-- that; one more file-level `local` would make the addon be rejected at load time.
WowVisionNavigationAlignStatus = WowVisionNavigationAlignStatus or {
    keyName = "I", fullTurnTime = 0.5, angleOffset = 5, timer = nil, generation = 0,
    silentWaypointName = "\001WowVisionNavigation\001",
    wowVisionMaxAttempts = 3, wowVisionToleranceDegrees = 5,
    fineToleranceDegrees = 1.5, fineLimitDegrees = 15, fineCorrectionLimitDegrees = 45, fineMaxAttempts = 4,
}

function WowVisionNavigationAlignFineCancel()
    local status = WowVisionNavigationAlignStatus
    local fine = status.fine
    status.fine = nil
    if fine then
        MoveViewLeftStop()
        MoveViewRightStop()
        if fine.savedYaw then SetCVar("cameraYawMoveSpeed", fine.savedYaw) end
    end
end

function WowVisionNavigationAlignFineStep(generation)
    local status = WowVisionNavigationAlignStatus
    if status.wowVisionGeneration ~= generation then return false end
    if not C_Timer or type(C_Timer.After) ~= "function"
        or type(GetCVar) ~= "function" or type(SetCVar) ~= "function"
        or type(MoveViewLeftStart) ~= "function" or type(MoveViewRightStart) ~= "function"
        or type(MouselookStart) ~= "function" or type(MouselookStop) ~= "function" then
        status.wowVisionGeneration = nil
        return false
    end
    WowVisionNavigationAlignFineCancel()
    local fine = { savedYaw = GetCVar("cameraYawMoveSpeed"), generation = generation }
    status.fine = fine
    -- Synchronize camera and character; the snap only becomes visible in the following frame.
    MouselookStart()
    MouselookStop()
    C_Timer.After(0.05, function()
        if status.fine ~= fine or status.wowVisionGeneration ~= generation then return end
        local id, targetX, targetY = WowVisionNavigationAlignmentTarget()
        local x, y = GetPlayerWorldPosition()
        local ok, facing = pcall(GetPlayerFacing)
        local flags = _G.WowVision and _G.WowVision.movement and _G.WowVision.movement.flags
        if not id or not x or not ok or (issecretvalue and issecretvalue(facing))
            or type(facing) ~= "number" or facing ~= facing
            or math.abs(facing) == math.huge or (flags and (flags.turnLeft or flags.turnRight)) then
            WowVisionNavigationAlignFineCancel()
            status.wowVisionGeneration = nil
            return
        end
        local dx, dy = targetX - x, targetY - y
        local angle = ((math.atan2(dy, dx) - facing + math.pi) % (2 * math.pi)) - math.pi
        local degrees = math.abs(math.deg(angle))
        if dx * dx + dy * dy < 0.0001 or degrees <= (status.fineToleranceDegrees or 1.5) then
            WowVisionNavigationAlignFineCancel()
            status.wowVisionGeneration = nil
            return
        end
        if degrees > (status.fineCorrectionLimitDegrees or 45) then
            -- The initial camera snap can result in a larger angle than measured before the key press if the camera direction
            -- differs.
            WowVisionNavigationAlignFineCancel()
            if status.wowVisionAttempts >= (status.wowVisionMaxAttempts or 3) then
                status.wowVisionGeneration = nil
                return
            end
            status.wowVisionAttempts = status.wowVisionAttempts + 1
            WowVisionNavigationAlignWowVisionStep(id, targetX, targetY, generation)
            return
        end
        status.wowVisionWaypointId = id
        status.fineAttempts = (status.fineAttempts or 0) + 1
        -- At small angles the speed also drops. The frame and coasting distance can thereby not swallow the whole residual
        -- angle.
        local speed = math.max(12, math.min(60, degrees * 2))
        local duration = math.max(0.02, math.min(0.5, degrees / speed))
        SetCVar("cameraYawMoveSpeed", speed)
        if angle > 0 then MoveViewRightStart(1) else MoveViewLeftStart(1) end
        C_Timer.After(duration, function()
            if status.fine ~= fine or status.wowVisionGeneration ~= generation then return end
            MoveViewLeftStop()
            MoveViewRightStop()
            C_Timer.After(0.15, function()
                if status.fine ~= fine or status.wowVisionGeneration ~= generation then return end
                MouselookStart()
                MouselookStop()
                C_Timer.After(0.05, function()
                    if status.fine ~= fine or status.wowVisionGeneration ~= generation then return end
                    WowVisionNavigationAlignFineCancel()
                    WowVisionNavigationAlignWowVisionFinished()
                end)
            end)
        end)
    end)
    return true
end

-- Starts exactly one sweep of WowVision's own calibrated turn. The waypoint is copied synchronously into WowVision's
-- private turn state; `maps.path` may therefore be restored directly afterwards. The separate helper is used both by
-- the key press and by the completion check. Global because of the Lua 5.1 limit for file locals.
function WowVisionNavigationAlignWowVisionStep(waypointId, targetX, targetY, generation)
    local status = WowVisionNavigationAlignStatus
    if status.wowVisionGeneration ~= generation then return false end
    local maps = _G.WowVision and _G.WowVision.base and _G.WowVision.base.navigation
        and _G.WowVision.base.navigation.maps
    local wowVisionTurn = maps and maps.wowVisionNavigationOriginalTurnToWaypoint
    if not maps or type(wowVisionTurn) ~= "function" then return false end

    status.wowVisionWaypointId = waypointId
    status.wowVisionTargetX, status.wowVisionTargetY = targetX, targetY
    local oldPath = maps.path
    maps.path = { currentWaypoint = {
        x = targetX, y = targetY, n = status.silentWaypointName,
    } }
    local ok, result = pcall(wowVisionTurn, maps)
    maps.path = oldPath
    status.wowVisionStepToken = (status.wowVisionStepToken or 0) + 1
    local token = status.wowVisionStepToken
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(2, function()
            -- On manual abort WowVision's completion announcement is missing.
            if status.wowVisionGeneration == generation
                and status.wowVisionStepToken == token and not status.fine then
                status.wowVisionGeneration = nil
            end
        end)
    end
    if not ok then
        if status.wowVisionGeneration == generation then status.wowVisionGeneration = nil end
        error(result)
    end
    if result == false and status.wowVisionGeneration == generation then
        status.wowVisionGeneration = nil
    end
    return result ~= false
end

-- WowVision reports the completion only after camera stop, coasting and mouselook snap. Exactly this point in time is
-- suitable for a reliable check. The check deliberately uses the same live-verified world coordinates as the beacon,
-- not an estimate of the sweep duration. A zero-second timer cleanly leaves WowVision's finishTurn/speak call before
-- the next correction begins, if applicable.
function WowVisionNavigationAlignmentTarget()
    if not Navigation.active or (not Navigation.directTarget
        and (not Navigation.path or not Navigation.pathIndex)) then
        local featureModule = _G.WowVisionNavigationDockNavigation
        local x, y = GetPlayerWorldPosition()
        if featureModule and x then return featureModule:AlignmentTarget(x, y, NavData) end
        return nil
    end
    local direct = Navigation.directTarget
    if direct and direct.boardingTargetId then
        local featureModule = _G.WowVisionNavigationDockNavigation
        if not featureModule or not featureModule:DirectTargetValid(direct, NavData) then return nil end
    end
    local waypointId = direct and "direct" or Navigation.path[Navigation.pathIndex]
    if not direct and (not waypointId or not NodeExists(waypointId)) then return nil end
    local targetX, targetY
    if direct then targetX, targetY = direct.x, direct.y
    else targetX, targetY = NodePosition(waypointId) end
    return waypointId, targetX, targetY
end

function WowVisionNavigationAlignWowVisionFinished()
    local status = WowVisionNavigationAlignStatus
    local generation = status.wowVisionGeneration
    if not generation then return end

    local function CheckAndCorrect()
        if status.wowVisionGeneration ~= generation then return end
        local waypointId, targetX, targetY = WowVisionNavigationAlignmentTarget()
        if not waypointId then status.wowVisionGeneration = nil; return end
        local targetChanged = waypointId ~= status.wowVisionWaypointId
        local correct = false
        local remainingDegrees
        if not targetChanged then
            local x, y = GetPlayerWorldPosition()
            local ok, viewDirection = pcall(GetPlayerFacing)
            if not x or not ok or (issecretvalue and issecretvalue(viewDirection))
                or type(viewDirection) ~= "number" or viewDirection ~= viewDirection
                or math.abs(viewDirection) == math.huge then
                status.wowVisionGeneration = nil
                return
            end
            local dx, dy = targetX - x, targetY - y
            if dx * dx + dy * dy < 0.0001 then
                correct = true
            else
                local bearing = math.atan2(dy, dx)
                local deviation = ((bearing - viewDirection + math.pi) % (2 * math.pi)) - math.pi
                remainingDegrees = math.abs(math.deg(deviation))
                correct = remainingDegrees <= (status.fineToleranceDegrees or 1.5)
            end
        end

        if not correct and remainingDegrees and remainingDegrees <= (status.fineCorrectionLimitDegrees or 45)
            and (status.fineAttempts or 0) < (status.fineMaxAttempts or 4) then
            WowVisionNavigationAlignFineStep(generation)
            return
        end
        if correct or (status.fineAttempts or 0) >= (status.fineMaxAttempts or 4)
            or status.wowVisionAttempts >= (status.wowVisionMaxAttempts or 3) then
            status.wowVisionGeneration = nil
            return
        end
        status.wowVisionAttempts = status.wowVisionAttempts + 1
        local ok, failure = pcall(WowVisionNavigationAlignWowVisionStep,
            waypointId, targetX, targetY, generation)
        if not ok then
            WowVisionNavigationSay("i_correction_failed", tostring(failure))
        end
    end

    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, CheckAndCorrect)
    else
        CheckAndCorrect()
    end
end

function WowVisionNavigationAlignToActiveWaypoint()
    local status = WowVisionNavigationAlignStatus
    -- A further key press during a turn starts no second camera sweep with competing stop/snap timers.
    if status.wowVisionGeneration then return true end
    local waypointId, targetX, targetY = WowVisionNavigationAlignmentTarget()
    if not waypointId then
        WowVisionNavigationSay("i_no_alignment_target")
        return false
    end

    -- WowVision Forever now turns closed-loop: first synchronize camera/character, wait one frame, turn in two speed
    -- levels, wait for the coasting and synchronize again. The old SKU imitation below cannot do this reliably on the
    -- Retail engine. `turnToWaypoint` reads the waypoint synchronously from `maps.path` and copies it into its internal
    -- turn state; a small path adapter may therefore be inserted for exactly this call and the real WowVision path
    -- restored immediately afterwards.
    local maps = _G.WowVision and _G.WowVision.base and _G.WowVision.base.navigation
        and _G.WowVision.base.navigation.maps
    local wowVisionTurn = maps and maps.wowVisionNavigationOriginalTurnToWaypoint
    if maps and type(wowVisionTurn) == "function" then
        status.generation = status.generation + 1
        status.wowVisionGeneration = status.generation
        status.wowVisionAttempts = 1
        status.fineAttempts = 0
        local x, y = GetPlayerWorldPosition()
        local ok, facing = pcall(GetPlayerFacing)
        if x and ok and not (issecretvalue and issecretvalue(facing))
            and type(facing) == "number" and facing == facing and math.abs(facing) < math.huge then
            local angle = ((math.atan2(targetY - y, targetX - x) - facing + math.pi)
                % (2 * math.pi)) - math.pi
            if math.abs(math.deg(angle)) <= (status.fineLimitDegrees or 15) then
                return WowVisionNavigationAlignFineStep(status.wowVisionGeneration)
            end
        end
        return WowVisionNavigationAlignWowVisionStep(
            waypointId, targetX, targetY, status.wowVisionGeneration)
    end

    -- Compatibility fallback for WowVision versions without a turn function of their own.
    status.wowVisionGeneration = nil
    if type(MoveViewLeftStart) ~= "function" or type(MoveViewLeftStop) ~= "function"
        or type(MoveViewRightStart) ~= "function" or type(MoveViewRightStop) ~= "function"
        or type(MouselookStart) ~= "function" or type(MouselookStop) ~= "function" then
        WowVisionNavigationSay("i_unsupported")
        return false
    end

    local x, y = GetPlayerWorldPosition()
    local viewDirection = GetPlayerFacing()
    if not x or not viewDirection then
        WowVisionNavigationSay("position_or_facing_unknown")
        return false
    end
    local dx, dy = targetX - x, targetY - y
    if dx * dx + dy * dy < 0.0001 then
        WowVisionNavigationSay("waypoint_already_reached")
        return false
    end

    -- `deviation` uses the same, live-confirmed world convention as the beacon. SKU turns with the opposite sign
    -- (`facing - bearing`) and then corrects by five degrees beyond the target; both details are kept for a familiar I
    -- behavior.
    local bearing = math.atan2(dy, dx)
    local deviation = ((bearing - viewDirection + math.pi) % (2 * math.pi)) - math.pi
    local degrees = -math.deg(deviation)
    if degrees < 0 then degrees = degrees - status.angleOffset
    else degrees = degrees + status.angleOffset end

    if status.timer and type(status.timer.Cancel) == "function" then
        pcall(status.timer.Cancel, status.timer)
    end
    status.generation = status.generation + 1
    local generation = status.generation
    local oldYawSpeed = type(GetCVar) == "function" and GetCVar("cameraYawMoveSpeed") or nil
    if type(SetView) == "function" then SetView(2) end
    if oldYawSpeed and type(SetCVar) == "function" then
        SetCVar("cameraYawMoveSpeed", 180 / status.fullTurnTime)
    end

    local duration = math.abs(degrees) * (status.fullTurnTime / 180) / 4
    if degrees < 0 then MoveViewRightStart(4) else MoveViewLeftStart(4) end
    local function Complete()
        if generation ~= status.generation then return end
        MoveViewRightStop()
        MoveViewLeftStop()
        if oldYawSpeed and type(SetCVar) == "function" then
            SetCVar("cameraYawMoveSpeed", oldYawSpeed)
        end
        -- Not protected according to the MoP Classic API: takes over the just set camera direction once. No movement, no
        -- targeting and no interaction follows.
        MouselookStart()
        MouselookStop()
        status.timer = nil
    end
    if C_Timer and type(C_Timer.NewTimer) == "function" then
        status.timer = C_Timer.NewTimer(duration, Complete)
    elseif C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(duration, Complete)
    else
        Complete()
    end
    return true
end

if not _G["WowVisionNavigationAlignButton"] then
    CreateFrame("Button", "WowVisionNavigationAlignButton", UIParent)
end
-- A CLICK override does not reliably trigger a hidden button. The button has neither texture nor size anyway and
-- therefore stays visually invisible, but it must be shown and registered for key press events for the key click.
-- WowVision's own InputManager uses exactly this pattern for its override buttons as well.
if type(_G["WowVisionNavigationAlignButton"].RegisterForClicks) == "function" then
    _G["WowVisionNavigationAlignButton"]:RegisterForClicks("AnyDown")
end
_G["WowVisionNavigationAlignButton"]:Show()

-- Common entry for the direct click override. If this addon has no active route, WowVision's own waypoint function is
-- retained. The wrapper installed in BuildWowVisionIntegration delegates to the original saved there in this case.
function WowVisionNavigationExecuteKeyI()
    local dock = _G.WowVisionNavigationDockNavigation
    if (Navigation.active and (Navigation.path or Navigation.directTarget))
        or (dock and (dock.reached or dock.passive)) then
        return WowVisionNavigationAlignToActiveWaypoint()
    end
    local maps = _G.WowVision and _G.WowVision.base and _G.WowVision.base.navigation
        and _G.WowVision.base.navigation.maps
    if maps and type(maps.turnToWaypoint) == "function" then
        return maps:turnToWaypoint()
    end
    return false
end

_G["WowVisionNavigationAlignButton"]:SetScript("OnClick", function()
    local ok, failure = pcall(WowVisionNavigationExecuteKeyI)
    if not ok then
        WowVisionNavigationSay("i_alignment_failed", tostring(failure))
    end
end)

-- May be called repeatedly: at our own ADDON_LOADED for clients without WowVision and once more after PLAYER_LOGIN,
-- after WowVision has activated its bindings.
function WowVisionNavigationRegisterKeyI()
    if type(SetOverrideBindingClick) ~= "function"
        or (type(InCombatLockdown) == "function" and InCombatLockdown()) then
        return false
    end
    SetOverrideBindingClick(_G["WowVisionNavigationAlignButton"], true, "I",
        "WowVisionNavigationAlignButton")
    return true
end

-- Removes without exception every runtime state derived from zone data. The function is deliberately global: this
-- file is at the Lua 5.1 limit of 200 file locals. On a switch WoW cannot unload the old addon; therefore only its
-- unchanged raw data tables are cached in the loader, while graph, route, guidance, quest/target lists and height
-- anchor are created anew.
function WowVisionNavigationClearZoneState(reason, transitRetained)
    local continuation = transitRetained and Navigation.actionContinuation or nil
    StopNavigation(Navigation.active and reason or nil, transitRetained, true)
    if _G.WowVisionNavigationDockNavigation then
        _G.WowVisionNavigationDockNavigation:ZoneLoaded(nil)
    end
    if _G.WowVisionNavigationActionNavigation then
        _G.WowVisionNavigationActionNavigation:Reset(transitRetained)
    end
    NavNetwork.Reset()
    wipe(EdgePenalties)
    -- These four helpers are code, not zone-dependent runtime state. They lie on Navigation only because of the Lua 5.1
    -- limit for file locals and must survive the reset at addon start as well as every later zone change.
    local readQuestlogQuests = Navigation.ReadQuestlogQuests
    local setQuestSelection = Navigation.SetQuestSelection
    local findQuestieTargetPoints = Navigation.FindQuestieTargetPoints
    local bestQuestieTargetPoint = Navigation.BestQuestieTargetPoint
    local searchTargets = Navigation.SearchTargets
    local listNodes = Navigation.ListNodes
    local appendLogicalTarget = Navigation.AppendLogicalTarget
    wipe(Navigation)
    Navigation.ReadQuestlogQuests = readQuestlogQuests
    Navigation.SetQuestSelection = setQuestSelection
    Navigation.FindQuestieTargetPoints = findQuestieTargetPoints
    Navigation.BestQuestieTargetPoint = bestQuestieTargetPoint
    Navigation.SearchTargets = searchTargets
    Navigation.ListNodes = listNodes
    Navigation.AppendLogicalTarget = appendLogicalTarget
    Navigation.actionContinuation = continuation
    Navigation.active = false
    Navigation.lastBeepTime = 0
    Navigation.lastClickTime = 0
    Navigation.lastBumpTime = 0
    Navigation.blockageCheckTime = 0
    Navigation.blockageEscalated = false
    Navigation.blockagesPerEdge = {}
    HeightAnchor.height, HeightAnchor.preferred, HeightAnchor.last = nil, nil, nil
    wipe(filteredList)
    selectionIndex = 1
    SelectionMode = "target"
    FilterBox:SetText("")
    ListFrame:Hide()
end

-- Zone state machine (continent concept, chapter 7a). The zone files are in memory since login (TOC); this loader
-- only decides which zone the player is in, decodes it on demand and activates the target catalogs of the whole
-- continent. It stays global (Lua limit of 200 file locals).
WowVisionNavigationZoneLoader = {
    state = "waiting", -- wartet | laedt | bereit | fehlgeschlagen
    baseReady = false,
    activeZone = nil,
    retryScheduled = false,
    retryCounter = 0,
    maxRetries = 12,
    retrySeconds = 0.5,
    zones = {},
}

-- Builds the zone table from the continent index (NavNetwork.index).
function WowVisionNavigationZoneLoader:BuildIndex()
    NavNetwork.LoadIndex()
    self.zones = {}
    for id, zone in pairs(NavNetwork.index) do
        self.zones[id] = {
            name = zone.name, slug = zone.dir, zoneId = id, base = zone.base,
            uiMaps = zone.uiMaps, worldBoxes = zone.worldBoxes, continent = zone.continent,
            -- instance maps have a native map of their own; open-world zones share the continent map
            nativeMapId = zone.instance and zone.nativeMapId or nil,
            coordinateMapId = zone.nativeMapId, nativeWorldBox = zone.nativeWorldBox,
            fingerprint = zone.fingerprint, files = zone.files,
        }
    end
end

function WowVisionNavigationZoneLoader:FindZoneForMap(mapID)
    for _, zoneInfo in pairs(self.zones) do
        if zoneInfo.uiMaps[mapID] then return zoneInfo end
    end
    return nil
end

function WowVisionNavigationZoneLoader:FindZoneForNativeMap(mapID)
    local found = nil
    for _, zoneInfo in pairs(self.zones) do
        if zoneInfo.nativeMapId == mapID then
            if found then return nil, false end
            found = zoneInfo
        end
    end
    return found, true
end

function WowVisionNavigationZoneLoader:IsSharedNativeMap(mapID)
    for _, zoneInfo in pairs(self.zones) do
        if zoneInfo.nativeMapId == nil and zoneInfo.coordinateMapId == mapID then
            return true
        end
    end
    return false
end

function WowVisionNavigationZoneLoader:DetermineZone()
    local nativeMapID = nil
    if type(_G.UnitPosition) == "function" then
        local ok, _, _, _, mapID = pcall(_G.UnitPosition, "player")
        if ok and (not issecretvalue or not issecretvalue(mapID))
            and type(mapID) == "number" and mapID >= 0 then
            nativeMapID = mapID
        end
    end
    if type(_G.GetInstanceInfo) == "function" then
        local ok, instanceMapID = pcall(function()
            return select(8, _G.GetInstanceInfo())
        end)
        if ok and (not issecretvalue or not issecretvalue(instanceMapID))
            and type(instanceMapID) == "number" and instanceMapID > 0 then
            if nativeMapID ~= nil and nativeMapID ~= instanceMapID then
                return nil, false, nil
            end
            nativeMapID = instanceMapID
        end
    end
    if nativeMapID ~= nil then
        local zoneInfo, unambiguous = self:FindZoneForNativeMap(nativeMapID)
        if not unambiguous then return nil, false, nil end
        if zoneInfo then return zoneInfo, true, nativeMapID end
        -- Shared world maps are split by UiMap/Area according to the register.
        -- Another known but unregistered native map must never fall back into the previously active zone through a possibly
        -- outdated UI parent map.
        if not self:IsSharedNativeMap(nativeMapID) then return nil, true, nativeMapID end
    end
    if type(_G.C_Map) ~= "table" or type(_G.C_Map.GetBestMapForUnit) ~= "function" then
        return nil, false, nativeMapID
    end
    local ok, mapID = pcall(_G.C_Map.GetBestMapForUnit, "player")
    if not ok or type(mapID) ~= "number" then return nil, false, nativeMapID end

    local seen = {}
    for _ = 1, 16 do
        if seen[mapID] then return nil, false, nativeMapID end
        seen[mapID] = true
        local zoneInfo = self:FindZoneForMap(mapID)
        if zoneInfo then
            if nativeMapID ~= nil and zoneInfo.coordinateMapId ~= nativeMapID then
                return nil, true, nativeMapID
            end
            return zoneInfo, true, nativeMapID
        end
        if type(_G.C_Map.GetMapInfo) ~= "function" then break end
        local infoOk, info = pcall(_G.C_Map.GetMapInfo, mapID)
        if not infoOk or type(info) ~= "table" then return nil, false, nativeMapID end
        if type(info.parentMapID) ~= "number" or info.parentMapID <= 0 then
            return nil, true, nativeMapID -- valide Kartenkette endet ausserhalb jedes registrierten Gebiets
        end
        mapID = info.parentMapID
    end

    -- Compatibility path for clients without GetMapInfo: a registered parent map only counts if GetPlayerMapPosition
    -- delivers a real position within 0..1. Missing APIs or implausible values are "not yet known", never a guessed zone
    -- assignment.
    if type(_G.C_Map.GetMapInfo) ~= "function"
        and type(_G.C_Map.GetPlayerMapPosition) == "function" then
        for _, zoneInfo in pairs(self.zones) do
            for registeredMap in pairs(zoneInfo.uiMaps) do
                local posOk, pos = pcall(_G.C_Map.GetPlayerMapPosition, registeredMap, "player")
                if posOk and pos and type(pos.GetXY) == "function" then
                    local xyOk, x, y = pcall(pos.GetXY, pos)
                    if xyOk and type(x) == "number" and type(y) == "number"
                        and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                        if nativeMapID == nil or zoneInfo.coordinateMapId == nativeMapID then
                            return zoneInfo, true, nativeMapID
                        end
                    end
                end
            end
        end
        return nil, true, nativeMapID
    end
    return nil, false, nativeMapID
end

-- Identity of the continent for the target catalogs and the consumers of NavData: one shim table per continent,
-- mutated in place when the player moves to another zone of the same continent.
-- The capture records of a decoded zone join the continent's NavData (once per zone).
function WowVisionNavigationZoneLoader.AddInteractionCaptures(nav, zone)
    if type(nav) ~= "table" or type(zone) ~= "table" or not nav.captureZones or nav.captureZones[zone.id] then return end
    nav.captureZones[zone.id] = true
    for _, capture in ipairs(zone.captures or {}) do
        nav.interactionCaptures[#nav.interactionCaptures + 1] = capture
    end
end

local function ContinentNavData(zoneInfo)
    local zones = {}
    for id, other in pairs(WowVisionNavigationZoneLoader.zones) do
        if other.continent == zoneInfo.continent then zones[id] = true end
    end
    local nav = {
        schema_version = 7, packageLayoutVersion = 3, targetSchemaVersion = 1,
        continent = zoneInfo.continent, nativeMapId = zoneInfo.coordinateMapId, zoneSet = zones,
        zoneId = zoneInfo.zoneId, zone_base = zoneInfo.base, exportFingerprint = zoneInfo.fingerprint,
        uiMap = next(zoneInfo.uiMaps),
        -- the transit modules (dock, activation) require the proof schemas and the capture records of the zone data
        waitpoint_schema = 1, waitpointFingerprint = zoneInfo.fingerprint,
        approach_schema = 1, approachFingerprint = zoneInfo.fingerprint,
        interactionCaptures = {}, captureZones = {},
    }
    for id, zone in pairs(NavNetwork.zones) do
        if zones[id] then WowVisionNavigationZoneLoader.AddInteractionCaptures(nav, zone) end
    end
    return nav
end

function WowVisionNavigationZoneLoader:Deactivate(reason, targetZone, activationCompleted)
    local mod = _G.WowVisionNavigationActionNavigation
    local transitRetained = targetZone and mod and mod.current
        and mod.current.action.toZoneId == targetZone.zoneId
        and (mod.current.phase == "travelling" or mod.current.phase == "disembarking")
    self.transitTargetZone = transitRetained and targetZone.zoneId or nil
    local activation = Navigation.activationTarget
    if activationCompleted then
        reason = WowVisionNavigationText("reason_activation_map_changed")
    elseif activation and targetZone and targetZone.nativeMapId
        and activation.nativeMapId ~= targetZone.nativeMapId then
        reason = WowVisionNavigationText("reason_map_changed_guidance_done")
    end
    if self.activeZone or NavNetwork.NodeCount() > 0 then
        WowVisionNavigationClearZoneState(reason, transitRetained)
    end
    _G.NavData = nil
    if _G.WowVisionNavigationTargetCatalog then _G.WowVisionNavigationTargetCatalog:Deactivate() end
    if _G.WowVisionNavigationTargetSelection then _G.WowVisionNavigationTargetSelection.pending=nil end
    self.activeZone = nil
    self.state = "waiting"
end

function WowVisionNavigationZoneLoader:Failure(zoneInfo, text)
    WowVisionNavigationClearZoneState(nil)
    _G.NavData = nil
    if _G.WowVisionNavigationTargetCatalog then _G.WowVisionNavigationTargetCatalog:Deactivate() end
    self.activeZone = nil
    self.state = "failed"
    self.failures = self.failures or {}
    if zoneInfo then self.failures[zoneInfo.zoneId] = text end
    WowVisionNavigationWarn("zone_load_failed", text)
    return false
end

-- Activates a zone: decode on demand, catalogs of the continent, NavData shim. A move between two zones of the same
-- continent keeps the running route (one graph, chapter 7a).
function WowVisionNavigationZoneLoader:ActivatePackage(zoneInfo)
    local nav = _G.NavData
    local sameContinent = nav and nav.continent == zoneInfo.continent
    if not sameContinent then
        WowVisionNavigationClearZoneState(nil, self.transitTargetZone == zoneInfo.zoneId)
    end
    NavNetwork.activeMapId = zoneInfo.coordinateMapId
    local zone, reason = NavNetwork.LoadZone(zoneInfo.zoneId)
    if not zone then
        return self:Failure(zoneInfo, WowVisionNavigationText("zone_data_invalid", tostring(zoneInfo.name), tostring(reason)))
    end
    if not sameContinent then
        nav = ContinentNavData(zoneInfo)
        _G.NavData = nav
        if _G.WowVisionNavigationTargetCatalog then
            local zones = {}
            for id in pairs(nav.zoneSet) do
                zones[#zones + 1] = { zoneId = id, logical = (_G.WVN7Logical or {})[id], dynamic = (_G.WVN7Dyn or {})[id] }
            end
            local ok, why = _G.WowVisionNavigationTargetCatalog:ActivateZones(nav, zones)
            if not ok then return self:Failure(zoneInfo, WowVisionNavigationText("catalog_invalid", tostring(why))) end
        end
        if _G.WowVisionNavigationDockNavigation then
            _G.WowVisionNavigationDockNavigation:ZoneLoaded(nav)
        end
    else
        nav.zoneId, nav.zone_base, nav.exportFingerprint = zoneInfo.zoneId, zoneInfo.base, zoneInfo.fingerprint
        nav.waitpointFingerprint, nav.approachFingerprint = zoneInfo.fingerprint, zoneInfo.fingerprint
        nav.uiMap = next(zoneInfo.uiMaps)
    end
    self.transitTargetZone = nil
    self.activeZone = zoneInfo
    self.state = "ready"
    self.retryScheduled = false
    if not sameContinent then
        WowVisionNavigationSay("zone_data_activated", tostring(zoneInfo.name or zoneInfo.zoneId))
    end
    self:PreloadNeighbours(zoneInfo)
    return true
end

-- Prepares the first /vn in a zone: decodes the zones that share a seam with it (index, one zone per frame). Called at every
-- activation, so entering the next zone prepares its neighbours the same way. Zones stay in memory (NavNetwork.decoded): the memory
-- grows with the zones visited or adjacent to them, not with the continent. The target list is not prepared here (the search
-- resolves what it returns). WowVisionNavigationDB.preload = false switches it off.
function WowVisionNavigationZoneLoader:PreloadNeighbours(zoneInfo)
    local nav = _G.NavData
    local timer = _G.C_Timer
    if not nav or WowVisionNavigationDB.preload == false or type(timer) ~= "table" or type(timer.After) ~= "function" then return end
    local pending = {}
    for _, id in ipairs(NavNetwork.NeighbourZones(zoneInfo.zoneId)) do
        if nav.zoneSet[id] and not NavNetwork.decoded[id] and NavNetwork.ZoneAvailable(id) then pending[#pending + 1] = id end
    end
    self.preloadToken = (self.preloadToken or 0) + 1
    local token, index = self.preloadToken, 0
    local loader = self
    local function step()
        if _G.NavData ~= nav or loader.preloadToken ~= token then return end     -- another zone or continent meanwhile
        index = index + 1
        if pending[index] then
            NavNetwork.LoadZone(pending[index])
            return timer.After(0, step)
        end
        -- Nothing is resolved in advance: a search resolves the nearest hits it returns (at most one thousand), and keeps them.
    end
    timer.After(0, step)
end

function WowVisionNavigationZoneLoader:LoadZone(zoneInfo, activationCompleted)
    if self.activeZone == zoneInfo and self.state == "ready" then return true end
    if self.failures and self.failures[zoneInfo.zoneId] then
        self.state = "failed"
        return false
    end
    local old = self.activeZone
    if old and old.continent ~= zoneInfo.continent then
        self:Deactivate(WowVisionNavigationText("stop_zone_changed"), zoneInfo, activationCompleted)
    end
    if not NavNetwork.ZoneAvailable(zoneInfo.zoneId) then
        return self:Failure(zoneInfo, WowVisionNavigationText("zone_file_not_loaded", tostring(zoneInfo.name)))
    end
    return self:ActivatePackage(zoneInfo)
end

function WowVisionNavigationZoneLoader:ScheduleRetry()
    if self.retryScheduled or self.state == "loading"
        or self.retryCounter >= self.maxRetries then return end
    if type(_G.C_Timer) ~= "table" or type(_G.C_Timer.After) ~= "function" then return end
    self.retryScheduled = true
    self.retryCounter = self.retryCounter + 1
    _G.C_Timer.After(self.retrySeconds, function()
        self.retryScheduled = false
        self:CheckCurrentZone("map API retry")
    end)
end

function WowVisionNavigationZoneLoader:CheckCurrentZone(reason)
    if not self.baseReady or self.state == "loading" then return false end
    local zoneInfo, safelyDetermined, nativeMapID = self:DetermineZone()
    if not safelyDetermined then
        self:ScheduleRetry()
        return false
    end
    -- B5: after the geometric activation area a change of the native map ends the activation guidance.
    local activation = Navigation.activationTarget
    local mod = _G.WowVisionNavigationActionNavigation
    local activationCompleted = activation and Navigation.activationCaptureAnnounced
        and activation.activationMode == "walk_into_trigger" and not (mod and mod.current)
        and type(activation.nativeMapId) == "number" and type(nativeMapID) == "number"
        and nativeMapID ~= activation.nativeMapId or false
    if not zoneInfo then
        if mod and mod.current and (mod.current.phase == "travelling"
            or mod.current.phase == "disembarking") then
            self:ScheduleRetry()
            return false
        end
        self:Deactivate(self.activeZone and
            WowVisionNavigationText("stop_outside_zones") or nil,
            nil, activationCompleted)
        return false
    end
    return self:LoadZone(zoneInfo, activationCompleted)
end

function WowVisionNavigationZoneLoader:DataReadyOrReport()
    if self:CheckCurrentZone("command") then return true end
    if self.state ~= "failed" then
        WowVisionNavigationSay("zone_data_not_ready")
    end
    return false
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("ZONE_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if event == "PLAYER_DEAD" then
        StopNavigation(nil)
    elseif event == "ADDON_LOADED" and addonName == "WowVisionNavigation" then
        WowVisionNavigationImportLegacyDB()
        WowVisionNavigationMigrateRenamedKeys()
        NavNetwork.memory.login = collectgarbage("count")
        WowVisionNavigationZoneLoader:BuildIndex()
        NavNetwork.onZoneLoaded = function(zone)
            WowVisionNavigationZoneLoader.AddInteractionCaptures(_G.NavData, zone)
            local actions = _G.WowVisionNavigationActionNavigation
            if actions and #zone.actions > 0 then actions:AddActions(zone.actions) end
        end
        if _G.WowVisionNavigationActionNavigation then
            _G.WowVisionNavigationActionNavigation:Initialize({}, function(message)
                WowVisionNavigationPrint(message)
            end, function(action)
                if type(_G.WowVisionNavigationActionArrival) == "function" then
                    _G.WowVisionNavigationActionArrival(action)
                end
            end, false)
        end
        NavNetwork.ActionAllowed = function(action)
            local actions = _G.WowVisionNavigationActionNavigation
            return actions ~= nil and actions:CanTraverse(action, nil) == true
        end
        BuildZoneBoxes()
        if WowVisionNavigationDB.showauto == nil then WowVisionNavigationDB.showauto = false end
        WowVisionNavigationDB.log = WowVisionNavigationDB.log or {}
        WowVisionNavigationDB.questProbes = WowVisionNavigationDB.questProbes or {}
        -- Blockage telemetry (konzept.md 5.2 level 3): same initialization rule as .log - do NOT initialize at the top file
        -- level (SavedVariables replace the global table only after the file execution, see the comment in section 6).
        WowVisionNavigationDB.blockageTelemetry = WowVisionNavigationDB.blockageTelemetry or {}
        -- 10.6bm: default ON, deliberately set only if the key does not exist at all yet - otherwise an explicit "aus" of the
        -- user could not be distinguished from "never set" and a later change of the default would override it.
        if WowVisionNavigationDB.fineBearing == nil then
            WowVisionNavigationDB.fineBearing = true
        end
        -- Comfort level (4.34): an invalid or missing saved value means the default.
        if not NavNetwork.SetComfort(WowVisionNavigationDB.comfort) then
            WowVisionNavigationDB.comfort = nil
            NavNetwork.SetComfort(NavNetwork.COMFORT_DEFAULT)
        end
        -- The former, meanwhile ineffective route profile and the /vn autoNew switch (10.6dg) are removed: automatic
        -- redirecting on blockage must never happen again. A value still stored in the SavedVariables (or imported from an
        -- old legacy SavedVariables file, e.g. a "true" for autoNew) is removed once on load, so that it can never take
        -- effect.
        for _, removedKey in ipairs(REMOVED_DB_KEYS) do WowVisionNavigationDB[removedKey] = nil end
        -- SetOverrideBindingClick corresponds to the actual SKU binding way. The binding is set at addon load, never changed
        -- during combat and not saved. The button is deliberately no SecureActionButton.
        WowVisionNavigationRegisterKeyI()
        WowVisionNavigationZoneLoader.baseReady = true
        WowVisionNavigationSay("startup_banner",
            WowVisionNavigationText(WowVisionNavigationDB.finalApproach ~= false and "state_on" or "state_off"),
            WowVisionNavigationText(WowVisionNavigationDB.chokeFallback ~= false and "state_on" or "state_off"),
            SKU_NAV_STANDARD)
        WowVisionNavigationSay("startup_quest_select")
        WowVisionNavigationSay("startup_quest_probe")
        WowVisionNavigationZoneLoader:CheckCurrentZone("addon start")
    elseif event ~= "ADDON_LOADED" and WowVisionNavigationZoneLoader.baseReady then
        -- Real zone/world events only reset the limited API retry budget. The state machine itself prevents every second load
        -- or graph build.
        WowVisionNavigationZoneLoader.retryCounter = 0
        WowVisionNavigationZoneLoader:CheckCurrentZone(event)
    end
end)
