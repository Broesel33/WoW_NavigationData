-- Independent provider snapshots. No provider owns a physical graph node.
WowVisionNavigationTargetCatalog = { providers = {}, revision = 0 }
local C = WowVisionNavigationTargetCatalog
local forbidden = { nodeId=true, node_id=true, endNodeId=true, reachable=true,
    attachment_edge=true, targetDistance=true, node_distance=true,
    route_attachment_point=true, attachment_corridor=true }
local kinds = {npc=true,mob=true,creature=true,gameobject=true,herb=true,mining=true,
    mailbox=true,search_area=true,transit_facility=true,zone_transition=true,live=true}

local function denseArray(value)
    if type(value) ~= "table" then return false end
    local count, maximum = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return false end
        count=count+1;maximum=math.max(maximum,key)
    end
    return count==maximum
end

function C.Finite(value)
    return (not issecretvalue or not issecretvalue(value)) and type(value) == "number"
        and value == value and value ~= math.huge and value ~= -math.huge
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("cyclic provider payload") end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do
        if forbidden[key] then error("target contains graph binding: " .. tostring(key)) end
        if type(child) == "function" or type(child) == "userdata" or type(child) == "thread" then
            error("target payload must be data")
        end
        result[key] = copy(child, seen)
    end
    seen[value] = nil
    return result
end

-- coordinateSpace and source (provenance) are per-row fields of live providers and DynTargets. A row that ExpandCatalog made from
-- a compact catalogue has neither: the space is the catalogue's constant ("world"), the provenance is not shipped. A value that
-- is present has to be valid.
function C.Validate(target)
    if type(target) ~= "table" or type(target.id) ~= "string" or target.id == ""
        or not C.Finite(target.x) or not C.Finite(target.y)
        or not C.Finite(target.nativeMapId) or target.nativeMapId < 0
        or target.nativeMapId % 1 ~= 0
        or (target.coordinateSpace ~= nil and target.coordinateSpace ~= "world")
        or type(target.nameEn) ~= "string" or target.nameEn == ""
        or (target.source ~= nil and (type(target.source) ~= "table" or type(target.source.provider) ~= "string"
            or target.source.provider == ""))
        or not kinds[target.kind] then
        return false, "invalid target contract"
    end
    if target.z ~= nil and not C.Finite(target.z) then return false, "invalid Z" end
    if target.zStatus ~= (target.z == nil and "unknown" or "known") then
        return false, "Z/status mismatch (zero is a known height)"
    end
    if target.levels ~= nil then        -- 4.54: certified level heights of a target without a source height
        if type(target.levels) ~= "table" or target.z ~= nil then return false, "invalid levels" end
        for _, h in ipairs(target.levels) do
            if not C.Finite(h) then return false, "invalid levels" end
        end
    end
    if target.surface ~= nil and target.surface ~= "land" and target.surface ~= "water" then
        return false, "invalid surface"
    end
    return true
end

-- Interaction authorization belongs to the physical capture certificate, not a provider.
function C:CertifiedInteraction(nav,target)
    if type(nav) ~= "table" or nav.packageLayoutVersion ~= 3 then return false end
    if not target.layerResolution or target.layerResolution.quality ~= "exact" then return false end
    for _,capture in ipairs(nav.interactionCaptures or {}) do
        local equal = true
        for _,key in ipairs({"x","y","z","nativeMapId","waitpointProofId","approachProofId",
            "interactionMode","activationMode","facilityRole","waitingRadius",
            "activationPreX","activationPreY","activationPreZ","activationCaptureRadius",
            "boardingHintStatus","boardingDirX","boardingDirY","boardingPreviewDistance"}) do
            if key == "x" or key == "y" or key == "z" then
                if not self.Finite(capture[key]) or not self.Finite(target[key])
                    or math.floor(capture[key]*10+0.5) ~= math.floor(target[key]*10+0.5) then
                    equal=false;break
                end
            elseif capture[key] ~= target[key] then equal=false;break end
        end
        if equal then return true end
    end
    return false
end

function C:Changed()
    self.revision = self.revision + 1
    if WowVisionNavigationTargetSelection then WowVisionNavigationTargetSelection.pending = nil end
    if type(WowVisionNavigationTargetCatalogChanged)=="function" then
        WowVisionNavigationTargetCatalogChanged()
    end
    -- Existing navigation is user-owned; revisions never trigger automatic replanning.
end

function C:RegisterProvider(id, version)
    if type(id) ~= "string" or id == "" or version ~= 1 then return false, "unsupported provider" end
    if self.providers[id] then return self.providers[id].version == version end
    self.providers[id] = { version=version, revision=nil, targets={} }
    return true
end

-- Compact logical catalogue (the only format of the logical layer, TechnicalDocumentation/05). The file carries per-file constants in its header
-- (coordinateSpace, nativeMapId, default availability) and, per target, only what differs:
--   classes[i] = { kind, category (string, or list of strings), entry (number or false), nameEn, nameDe (absent = nameEn),
--                  a = availability (absent = header default), s = search aliases (absent = none) }
--   targets[j] = { id, class index, x, y, z (absent = unknown height), l = levels (z absent), r = radius, p = true (approx) }
-- ExpandCatalog turns the rows into the tables the rest of the core reads (target rows without the provenance, which stays in the
-- pipeline report, and without the constants that were lifted into the header). Everything is validated here; the expanded rows
-- are cached on the catalogue until another continent is activated.
C.LOGICAL_FORMAT = 2

local function expandClass(raw)
    if type(raw) ~= "table" then return nil end
    local kind, category, entry, nameEn, nameDe = raw[1], raw[2], raw[3], raw[4], raw[5]
    if not kinds[kind] or type(nameEn) ~= "string" or nameEn == "" then return nil end
    if nameDe == nil then nameDe = nameEn elseif type(nameDe) ~= "string" or nameDe == "" then return nil end
    if type(category) == "string" then category = { category } end
    if type(category) ~= "table" or #category == 0 then return nil end
    for index = 1, #category do
        if type(category[index]) ~= "string" or category[index] == "" then return nil end
    end
    if entry == false then entry = nil elseif entry ~= nil and not C.Finite(entry) then return nil end
    local availability = raw.a
    if availability ~= nil and (type(availability) ~= "string" or availability == "") then return nil end
    local aliases = raw.s
    if aliases ~= nil then
        if type(aliases) ~= "table" then return nil end
        for index = 1, #aliases do
            if type(aliases[index]) ~= "string" then return nil end
        end
    end
    return { kind = kind, category = category, entry = entry, nameEn = nameEn, nameDe = nameDe,
        availability = availability, aliases = aliases }
end

function C.ExpandCatalog(catalog)
    if type(catalog) ~= "table" then return nil, "missing catalogue" end
    if catalog.expanded then return catalog.expanded end
    local classes, rows, map = catalog.classes, catalog.targets, catalog.nativeMapId
    local default = catalog.availability
    if default == nil then default = "static" end
    if type(classes) ~= "table" or type(rows) ~= "table" or type(default) ~= "string"
        or not C.Finite(map) or map < 0 or map % 1 ~= 0 then
        return nil, "invalid compact catalogue header"
    end
    local expandedClasses = {}
    for index = 1, #classes do
        local class = expandClass(classes[index])
        if not class then return nil, "invalid target class " .. index end
        expandedClasses[index] = class
    end
    local result, seen = {}, {}
    for index = 1, #rows do
        local row = rows[index]
        if type(row) ~= "table" then return nil, "invalid target row " .. index end
        local id, class, x, y, z = row[1], expandedClasses[row[2]], row[3], row[4], row[5]
        if type(id) ~= "string" or id == "" or not class or not C.Finite(x) or not C.Finite(y) then
            return nil, "invalid target row " .. index
        end
        if seen[id] then return nil, "duplicate target ID" end
        seen[id] = true
        local levels, radius = row.l, row.r
        if z ~= nil and not C.Finite(z) then return nil, "invalid Z" end
        if levels ~= nil then               -- 4.54: certified level heights of a target without a source height
            if type(levels) ~= "table" or z ~= nil then return nil, "invalid levels" end
            for level = 1, #levels do
                if not C.Finite(levels[level]) then return nil, "invalid levels" end
            end
        end
        if radius ~= nil and (not C.Finite(radius) or radius <= 0) then return nil, "invalid radius" end
        result[index] = {
            id = id, kind = class.kind, entry = class.entry, nameEn = class.nameEn, nameDe = class.nameDe,
            category = class.category, searchAliases = class.aliases, nativeMapId = map, x = x, y = y, z = z,
            zStatus = z == nil and "unknown" or "known", availability = class.availability or default,
            levels = levels, radius = radius, approx = row.p and true or nil,
        }
    end
    catalog.expanded = result
    return result
end

-- trusted: the rows come from ExpandCatalog (validated, freshly built): no second copy and no second validation.
function C:ReplaceSnapshot(id, revision, targets, trusted)
    local provider = self.providers[id]
    if not provider or type(revision) ~= "string" or revision == "" or not denseArray(targets) then
        return false, "provider/revision missing"
    end
    if trusted then
        self.providers[id] = { version=1, revision=revision, targets=targets }
        self:Changed()
        return true
    end
    local ok, cloned = pcall(copy, targets)
    if not ok then return false, cloned end
    local seen = {}
    for index, target in ipairs(cloned) do
        local valid, reason = self.Validate(target)
        if not valid then return false, reason end
        if seen[target.id] then return false, "duplicate target ID" end
        seen[target.id] = true
    end
    for key in pairs(cloned) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #cloned then
            return false, "target array has holes or keyed records"
        end
    end
    self.providers[id] = { version=1, revision=revision, targets=cloned }
    self:Changed()
    return true
end

function C:ApplyDelta(id, base, revision, upserts, removed)
    local provider = self.providers[id]
    if not provider or provider.revision ~= base then return false, "base revision mismatch" end
    if not denseArray(upserts) or not denseArray(removed) then return false, "invalid delta" end
    local rows, order, seen = {}, {}, {}
    for _, target in ipairs(provider.targets) do rows[target.id] = target; order[#order+1] = target.id end
    for _, targetId in ipairs(removed) do
        if type(targetId) ~= "string" then return false, "invalid removed ID" end
        rows[targetId] = nil
    end
    for _, target in ipairs(upserts) do
        local valid, reason = self.Validate(target)
        if not valid or seen[target.id] then return false, reason or "duplicate upsert" end
        seen[target.id] = true
        if not rows[target.id] then order[#order+1] = target.id end
        rows[target.id] = target
    end
    local result, emitted = {}, {}
    for _, targetId in ipairs(order) do
        if rows[targetId] and not emitted[targetId] then
            result[#result+1] = rows[targetId]; emitted[targetId] = true
        end
    end
    return self:ReplaceSnapshot(id, revision, result)
end

function C:UnregisterProvider(id)
    if not self.providers[id] then return false end
    self.providers[id] = nil
    self:Changed()
    return true
end

-- zones: set { [zoneId] = true } of the active continent, a single zoneId, or nil (everything).
function C:List(zones)
    local result, ids = {}, {}
    for id in pairs(self.providers) do ids[#ids+1] = id end
    table.sort(ids)
    local function wanted(target)
        if target.zoneId == nil or zones == nil then return true end
        if type(zones) == "table" then return zones[target.zoneId] == true end
        return target.zoneId == zones
    end
    for _, providerId in ipairs(ids) do
        local provider = self.providers[providerId]
        for _, target in ipairs(provider.targets) do
            if wanted(target) then
                local item = copy(target)
                item.providerId, item.providerRevision = providerId, provider.revision
                item.catalogKey = providerId .. ":" .. target.id
                item.zoneId = item.zoneId or provider.zoneId
                result[#result+1] = item
            end
        end
    end
    return result
end

-- Activates the catalogs of all zones of a continent (concept 7a: the logical and dyn targets of the zones of one
-- continent form one catalog). zones: { { zoneId, logical, dynamic }, ... }
function C:ActivateZones(nav, zones)
    if type(nav) ~= "table" or nav.packageLayoutVersion ~= 3 or nav.targetPoints ~= nil then
        return false,"Only physical package layout 3 is supported"
    end
    local staged = { providers={}, revision=self.revision }
    staged.Changed=function(self) self.revision=self.revision+1 end
    setmetatable(staged, {__index=self})
    local expanded = {}
    for _, zone in ipairs(zones) do
        for _, entry in ipairs({{zone.logical, "package_logical_", "logical"}, {zone.dynamic, "package_dyn_", "dyn"}}) do
            local catalog, id = entry[1], entry[2] .. zone.zoneId
            -- schema 1 = the target contract. The logical layer is the compact format 2 only (ExpandCatalog; the verbose rows of
            -- the older exports are no longer read); the dyn layer is a list of rows without a format.
            local compact = entry[3] == "logical"
            if type(catalog) ~= "table" or catalog.schema ~= 1 or catalog.zoneId ~= zone.zoneId
                or catalog.layer ~= entry[3] or catalog.coordinateSpace ~= "world" or type(catalog.targets) ~= "table" then
                return false, "missing or mismatched target catalog (zone " .. tostring(zone.zoneId) .. ")"
            end
            if compact and catalog.format ~= C.LOGICAL_FORMAT or not compact and catalog.format ~= nil then
                return false, "unsupported target catalog format " .. tostring(catalog.format) .. " (zone " .. tostring(zone.zoneId)
                    .. ", " .. entry[3] .. " layer; the logical layer needs format " .. C.LOGICAL_FORMAT
                    .. "); rebuild the zone or update the targets of the zone with the pipeline"
            end
            staged:RegisterProvider(id, 1)
            local ok, reason
            if compact then
                local rows
                rows, reason = C.ExpandCatalog(catalog)
                if rows then
                    expanded[catalog] = true
                    ok, reason = staged:ReplaceSnapshot(id, catalog.payloadSha256, rows, true)
                end
            else
                ok, reason = staged:ReplaceSnapshot(id, catalog.payloadSha256, catalog.targets)
            end
            if not ok then return false, reason end
            staged.providers[id].zoneId = zone.zoneId       -- the lists show the zone name behind every entry
        end
    end
    for id in pairs(self.providers) do
        if id:find("^package_") then self.providers[id] = nil end
    end
    for id, provider in pairs(staged.providers) do self.providers[id] = provider end
    for catalog in pairs(self.expandedCatalogs or {}) do        -- rows of the continent that is left are expanded again when needed
        if not expanded[catalog] then catalog.expanded = nil end
    end
    self.expandedCatalogs = expanded
    self.activeNav = nav
    self:Changed()
    return true
end

function C:Deactivate()
    local removed = false
    for id in pairs(self.providers) do
        if id:find("^package_") then self.providers[id] = nil; removed = true end
    end
    for catalog in pairs(self.expandedCatalogs or {}) do catalog.expanded = nil end
    self.expandedCatalogs = nil
    self.activeNav = nil
    if removed then self:Changed() end
end

-- Consumer bridge: ephemeral views; never repopulates NavData.zielpunkte.
-- predicate (optional): only targets for which it returns true are resolved and returned (lists of transit facilities
-- or single-id lookups must not resolve the whole catalog).
function WowVisionNavigationTargetList(nav, predicate)
    if type(nav) ~= "table" then return {} end
    if nav.packageLayoutVersion ~= 3 or nav.targetPoints ~= nil then return {} end
    local list = C:List(nav.zoneSet)
    if predicate then
        local filtered = {}
        for _, target in ipairs(list) do
            if predicate(target) then filtered[#filtered + 1] = target end
        end
        list = filtered
    end
    for _, target in ipairs(list) do
        target.reachable = true -- visible known target, resolution still required at selection
        target.layeredTarget = true
        if WowVisionNavigationTargetResolver and WowVisionNavigationNavNetwork.PointZoneLoaded(target.x,target.y) then
            local result = WowVisionNavigationTargetResolver:Resolve(nav,target)
            target.layerResolution=result
            if target.type == "transit_facility" and result.quality=="exact" then
                target.nodeId=result.endNodeId
            end
        end
    end
    return list
end
