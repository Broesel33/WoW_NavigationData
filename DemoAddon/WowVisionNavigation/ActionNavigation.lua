-- Directed, user-guided facility actions. No movement or interaction is triggered.
local Actions = { current = nil, byId = {}, announce = nil, onComplete = nil }
_G.WowVisionNavigationActionNavigation = Actions

local function now()
    return type(_G.GetTime) == "function" and _G.GetTime() or 0
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function inVolume(volume, position)
    if type(volume) ~= "table" or type(position) ~= "table" or not finite(position.x)
        or not finite(position.y) or not finite(position.z) then return false end
    local dx, dy, dz = position.x - volume.x, position.y - volume.y,
        position.z - volume.z
    if not finite(dx) or not finite(dy) or not finite(dz) then return false end
    if volume.type == "sphere" then
        return finite(volume.radius) and volume.radius > 0
            and dx * dx + dy * dy + dz * dz <= volume.radius * volume.radius
    end
    if volume.type == "oriented_box" and finite(volume.half_x)
        and finite(volume.half_y) and finite(volume.half_z)
        and finite(volume.yaw_radians) then
        local c, s = math.cos(volume.yaw_radians), math.sin(volume.yaw_radians)
        local lx, ly = c * dx + s * dy, -s * dx + c * dy
        return math.abs(lx) <= volume.half_x and math.abs(ly) <= volume.half_y
            and math.abs(dz) <= volume.half_z
    end
    return false
end

-- Kind-specific phase texts (Localization keys): a dive transition is dived into and surfaced from by the player himself, so the portal
-- texts do not fit it. An action kind without an entry uses the generic text of the phase.
local KIND_TEXT = {
    dive = { approach = "action_approach_prepoint.dive", waiting = "action_waiting.dive", activating = "action_activating.dive" },
    surface = { approach = "action_approach_prepoint.surface", waiting = "action_waiting.surface", activating = "action_activating.surface" },
}

local function phaseText(action, phase, generic, ...)
    local specific = type(action) == "table" and KIND_TEXT[action.kind] or nil
    return WowVisionNavigationText(specific and specific[phase] or generic, ...)
end

local function speak(self, message)
    if type(self.announce) == "function" then self.announce(message) end
end

local function enter(self, phase, message)
    local current = self.current
    if not current or current.phase == phase then return false end
    current.phase = phase
    current.enteredAt = now()
    if message then speak(self, message) end
    return true
end

function Actions:Reset(preserveCurrent)
    if not preserveCurrent then self.current = nil end
    self.byId = {}
end

function Actions:Initialize(navData, announce, onComplete, preserveCurrent)
    if type(navData) ~= "table" then return false, WowVisionNavigationText("action_nav_data_missing") end
    if preserveCurrent and (not self.current or not self.current.action
        or self.current.action.toZoneId ~= navData.zoneId
        or (self.current.phase ~= "travelling" and self.current.phase ~= "disembarking")) then
        return false, WowVisionNavigationText("action_zone_mismatch")
    end
    self:Reset(preserveCurrent)
    self.announce = announce
    self.onComplete = onComplete
    -- Schema 7: the actions of a zone arrive with the zone (AddActions, called when NavNetwork decodes it)
    return true
end

function Actions:AddActions(list)
    for _, action in ipairs(list or {}) do
        if type(action) ~= "table" or type(action.id) ~= "string" or self.byId[action.id]
            or type(action.fromNode) ~= "number" or type(action.toZoneId) ~= "number"
            or not finite(action.cost) or action.cost <= 0 then
            return false, WowVisionNavigationText("action_payload_invalid")
        end
        self.byId[action.id] = action
    end
    return true
end

function Actions:CanTraverse(action, context)
    if type(action) ~= "table" or type(action.conditions) ~= "table" then
        return false, WowVisionNavigationText("action_conditions_missing")
    end
    local conditions = action.conditions
    if conditions.status == "unconditional" and conditions.proof then return true end
    if conditions.status == "resolved" and conditions.proof
        and type(context) == "table" and type(context.evaluate) == "function" then
        local ok, result = pcall(context.evaluate, conditions.expression)
        if ok and result == true then return true end
        return false, WowVisionNavigationText("action_entry_unconfirmed")
    end
    return false, WowVisionNavigationText("action_entry_unknown")
end

function Actions:Start(actionId, context)
    local action = self.byId[actionId]
    if not action then return false, WowVisionNavigationText("action_missing") end
    local allowed, reason = self:CanTraverse(action, context)
    if not allowed then return false, reason end
    self:Cancel(nil)
    self.current = { action = action, phase = nil, enteredAt = now(), activated = false,
                     sourceEntered = false, sourceLeft = false, confirmed = false }
    enter(self, "approach", phaseText(action, "approach", "action_approach_prepoint", actionId))
    return true
end

function Actions:ReachedPrepoint()
    if not self.current or self.current.phase ~= "approach" then return false end
    return enter(self, "waiting", phaseText(self.current.action, "waiting", "action_waiting"))
end

function Actions:Confirm()
    local current = self.current
    if not current then return false, WowVisionNavigationText("action_none_active_short") end
    if current.phase == "waiting" then
        if current.action.activation.mode == "board" then
            enter(self, "boarding", WowVisionNavigationText("action_boarding"))
        else
            enter(self, "activating", phaseText(current.action, "activating", "action_activating"))
        end
        return true
    end
    if current.phase == "boarding" then
        current.confirmed = true
        current.activated = true
        enter(self, "travelling", WowVisionNavigationText("action_boarded"))
        return true
    end
    if current.phase == "activating" then
        current.confirmed = true
        current.activated = true
        enter(self, "travelling", WowVisionNavigationText("action_activated"))
        return true
    end
    return false, WowVisionNavigationText("action_no_confirmation")
end

function Actions:Observe(observation)
    local current = self.current
    if not current or type(observation) ~= "table" then return false end
    local action = current.action
    if observation.type == "death" or observation.type == "reload"
        or observation.type == "unexpected_map" or observation.type == "lost_position" then
        self:Cancel(WowVisionNavigationText("action_cancelled", observation.type))
        return false
    end
    local position = observation.position
    if position and observation.nativeMapId == action.fromNativeMap then
        if inVolume(action.sourceVolume, position) then
            current.sourceEntered = true
        elseif current.activated and current.sourceEntered then
            current.sourceLeft = true
        end
    end
    if current.phase ~= "travelling" then return false end
    if not current.activated or observation.nativeMapId ~= action.toNativeMap
        or not inVolume(action.arrivalVolume, position) then return false end
    if action.arrival.mode == "same_map_distinct_volume" then
        if not current.sourceLeft or observation.zReliable ~= true then return false end
    elseif action.arrival.mode == "transport_stop_volume" then
        if observation.transportStopped ~= true or observation.zReliable ~= true then
            return false
        end
    else
        if observation.mapChanged ~= true or observation.zReliable ~= true then return false end
    end
    if enter(self, "disembarking", WowVisionNavigationText("action_arrival_proven")) then
        return true
    end
    return false
end

function Actions:ReachedExit()
    local current = self.current
    if not current or current.phase ~= "disembarking" then return false end
    local action = current.action
    enter(self, "complete", WowVisionNavigationText("action_complete"))
    if type(self.onComplete) == "function" then self.onComplete(action) end
    self.current = nil
    return true
end

function Actions:Tick()
    local current = self.current
    if not current then return false end
    local timeout = current.action.timing and current.action.timing.timeout_seconds
    if not finite(timeout) or timeout <= 0 or now() - current.enteredAt > timeout then
        self:Cancel(WowVisionNavigationText("action_timeout"))
        return false
    end
    return true
end

function Actions:Status()
    if not self.current then return WowVisionNavigationText("action_none_active") end
    return WowVisionNavigationText("action_status", self.current.action.id, self.current.phase)
end

function Actions:Cancel(message)
    if self.current and message then speak(self, message) end
    self.current = nil
end
