WowVisionNavigationTargetSelection = {}
local S = WowVisionNavigationTargetSelection

function S:Describe(target,result)
    local name = WowVisionNavigationTargetName(target)
    if result and result.quality == "approximate" and (result.delta3D or result.deltaXY or 0) >= 1 then
        name = name .. WowVisionNavigationText("desc_inexact", result.delta3D or result.deltaXY or 0,
            result.zUnknown and WowVisionNavigationText("desc_horizontal_unknown") or
            (result.zOutOfTolerance and WowVisionNavigationText("desc_vertical") or ""))
    elseif result and result.quality == "ambiguous" then
        name = name .. WowVisionNavigationText(result.levelUnknown and "desc_level_unknown" or "desc_pick_height")
    elseif result and result.quality == "unroutable" then
        name = name .. WowVisionNavigationText("desc_no_point")
    end
    if result and result.normalizedWater then
        name = name .. WowVisionNavigationText("desc_water", result.divingDepth or 0)
    end
    return name
end

function S:Prepare(nav,target,context,start)
    local result = WowVisionNavigationTargetResolver:Resolve(nav,target,context)
    if result.quality == "ambiguous" and result.bands then
        self.pending = {nav=nav,target=target,context=context,start=start,
            catalogRevision=WowVisionNavigationTargetCatalog.revision,bandCount=#result.bands}
        -- unknown target height: "height unknown"; known height that fits no band: the conflict text (since 4.41)
        WowVisionNavigationSay(result.levelUnknown and "level_prompt"
            or (result.zConflict and "band_prompt_conflict" or "band_prompt"))
        for i,band in ipairs(result.bands) do
            local reachable = false
            for _,candidate in ipairs(band.candidates) do
                if not context.route or context.route(candidate.id) then reachable=true;break end
            end
            local noPath = reachable and "" or WowVisionNavigationText("band_no_path")
            if band.level then
                print(WowVisionNavigationText("level_line", i, band.zMin, noPath))
            else
                print(WowVisionNavigationText("band_line", i, band.zMin,band.zMax,band.nearest,noPath))
            end
        end
        return false,result
    end
    self.pending = nil
    if result.endNodeId == nil then
        WowVisionNavigationPrint(tostring(result.reason or WowVisionNavigationText("target_unresolvable")))
        return false,result
    end
    return start(target,result,context),result
end

function S:Command(msg)
    msg = WowVisionNavigationNormalizeCommand(msg)
    local command,value = msg:match("^%s*(%S+)%s*(.-)%s*$")
    -- the command word arrives normalized (German words and English aliases, see WowVisionNavigationNormalizeCommand)
    if command == "radius" or command == "tolerance" then
        WowVisionNavigationDB = WowVisionNavigationDB or {}
        local radius,tolerance = WowVisionNavigationTargetResolver:Settings()
        if value ~= "" then
            local number = tonumber(value)
            if not WowVisionNavigationTargetCatalog.Finite(number) or
                (command == "radius" and number <= 0) or (command == "tolerance" and number < 0) then
                WowVisionNavigationSay("invalid_value")
                return true
            end
            WowVisionNavigationDB[command == "radius" and "targetRadius" or "targetTolerance"] = number
            self.pending = nil
            radius,tolerance = WowVisionNavigationTargetResolver:Settings()
        end
        WowVisionNavigationSay("radius_status",radius,tolerance)
        return true
    elseif command == "level" then
        local pending,index = self.pending,tonumber(value)
        if not pending or not index or index%1 ~= 0 or index < 1
            or index > (pending.bandCount or 0) or pending.nav ~= NavData
            or pending.catalogRevision ~= WowVisionNavigationTargetCatalog.revision then
            WowVisionNavigationSay("no_open_level_selection")
        else
            if pending.context.route and WowVisionNavigationLayerTargetContext then
                local current = WowVisionNavigationLayerTargetContext(pending.context.footOnly)
                if not current then
                    WowVisionNavigationSay("start_not_determined")
                    return true
                end
                pending.context = current
            end
            pending.context.heightBand = index
            self:Prepare(pending.nav,pending.target,pending.context,pending.start)
        end
        return true
    elseif command == "corpse" or command == "group" then
        local providers = WowVisionNavigationTargetProviders
        local unit = value == "" and "party1" or value
        local raidNumber = tonumber(unit:match("^raid(%d+)$"))
        local validRaid = raidNumber and raidNumber >= 1 and raidNumber <= 40
        if command == "group" and not unit:match("^party[1-4]$")
            and not validRaid and unit ~= "target" then
            WowVisionNavigationSay("group_usage")
            return true
        end
        local target
        if command == "corpse" then target = providers:Corpse()
        else target = providers:GroupMember(unit) end
        if target and WowVisionNavigationLayerTargetStart then
            target.layeredTarget = true
            WowVisionNavigationLayerTargetStart(target,nil,nil,nil,true)
        else
            WowVisionNavigationSay("no_live_coordinates")
        end
        return true
    end
    return false
end
