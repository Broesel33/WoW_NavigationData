-- Live sources use the same optional-Z contract; snapshots never alter NavData.
WowVisionNavigationTargetProviders = {}
local P = WowVisionNavigationTargetProviders
local finite = WowVisionNavigationTargetCatalog.Finite

function P:WorldTarget(id,name,x,y,z,map,provider)
    if not finite(x) or not finite(y) or not finite(map) then return nil end
    if z ~= nil and not finite(z) then return nil end
    return {id=id,kind="live",nameEn=name,nameDe=name,category={"live"},
        x=x,y=y,z=z,zStatus=z==nil and "unknown" or "known",nativeMapId=map,
        coordinateSpace="world",source={provider=provider,record=id},
        updatedAt=type(GetTime)=="function" and GetTime() or 0}
end

function P:MapTarget(id,name,map,nx,ny,provider)
    if not finite(nx) or not finite(ny) or nx<0 or nx>1 or ny<0 or ny>1 then return nil end
    local area
    for _,candidate in pairs(WowVisionNavigationNavNetwork.index) do
        if candidate.worldBoxes and candidate.worldBoxes[map] then
            if area then return nil end
            area=candidate
        end
    end
    if not area then return nil end
    local nativeMap = area.nativeMapId
    if nativeMap == nil then return nil end
    -- The client's own map data first (C_Map.GetWorldPosFromMapPos), the embedded box only as fallback: the one shared
    -- conversion of NavNetwork.lua, the same as for the player position (the UiMap frame of some zones differs between clients).
    local x,y=WowVisionNavigationNavNetwork.NormalizedToWorld(map,nx,ny,nativeMap)
    if not x then return nil end
    local target=self:WorldTarget(id,name,x,y,nil,nativeMap,provider)
    if target then target.zoneId=area.zoneId end
    return target
end

function P:GroupMember(unit)
    if type(UnitPosition)~="function" or (type(UnitExists)=="function" and not UnitExists(unit)) then return nil end
    local ok,x,y,z,map=pcall(UnitPosition,unit)
    if not ok then return nil end
    -- Player UnitPosition Z is not certified in this client; adapters do not invent height.
    local name=type(UnitName)=="function" and UnitName(unit) or unit
    local target=self:WorldTarget("group:"..unit,name or unit,x,y,nil,map,"wow_api")
    if target then target.expiresAt=target.updatedAt+30;target.unit=unit end
    return target
end

function P:Corpse()
    if not C_DeathInfo or type(C_DeathInfo.GetCorpseMapPosition)~="function" or not C_Map
        or type(C_Map.GetBestMapForUnit)~="function" then return nil end
    local map=C_Map.GetBestMapForUnit("player")
    local ok,position=pcall(C_DeathInfo.GetCorpseMapPosition,map)
    if not ok or not position or type(position.GetXY)~="function" then return nil end
    local xyOk,x,y=pcall(position.GetXY,position)
    if not xyOk then return nil end
    return self:MapTarget("corpse",WowVisionNavigationText("corpse_name"),map,x,y,"wow_api")
end
