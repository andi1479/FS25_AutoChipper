--
-- AutoChipper for FS25
-- Adds "auto-chip nearby wood" to every vehicle with the WoodCrusher specialization
-- (e.g. Heizomat HM 10-500 KF, Jenz HEM 922 DQ Cobra hybrid).
--
-- While enabled and the chipper is turned on, loose cut wood pieces lying around the
-- chipper are hopped into the intake one by one and chipped with the game's own
-- WoodCrusher logic (wood chips, sound, particles). Everything runs on the server.
--

AutoChipper = {}
AutoChipper.MOD_NAME = g_currentModName
AutoChipper.SPEC_NAME = g_currentModName .. ".autoChipper"
AutoChipper.SPEC_TABLE_NAME = "spec_" .. AutoChipper.SPEC_NAME

AutoChipper.RADIUS = 15                 -- m, search radius around the chipper
AutoChipper.MAX_LENGTH = 5              -- m, longer pieces are left alone
AutoChipper.MAX_HEIGHT_ABOVE_GROUND = 1.5 -- m, ignore pieces lying on trailers / held by cranes
AutoChipper.SCAN_INTERVAL = 1000        -- ms between area scans
AutoChipper.HOP_DELAY = 400             -- ms a piece sits in the intake before it is chipped
AutoChipper.HOP_INTERVAL = 600          -- ms between two pieces
AutoChipper.DEBUG = false               -- log every chipped and skipped piece to log.txt

function AutoChipper.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(WoodCrusher, specializations)
end

function AutoChipper.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "setAutoChipperEnabled", AutoChipper.setAutoChipperEnabled)
    SpecializationUtil.registerFunction(vehicleType, "autoChipperOverlapCallback", AutoChipper.autoChipperOverlapCallback)
end

function AutoChipper.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", AutoChipper)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", AutoChipper)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", AutoChipper)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", AutoChipper)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", AutoChipper)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", AutoChipper)
end

function AutoChipper:onLoad(savegame)
    local spec = self[AutoChipper.SPEC_TABLE_NAME]
    if spec == nil then
        spec = {}
        self[AutoChipper.SPEC_TABLE_NAME] = spec
    end

    spec.isEnabled = false
    spec.actionEvents = {}
    spec.scanTimer = 0
    spec.hopTimer = 0
    spec.hopShape = nil
    spec.foundShapes = {}
    spec.candidates = {}

    spec.texts = {}
    spec.texts.enable = g_i18n:getText("action_autoChipperEnable", AutoChipper.MOD_NAME)
    spec.texts.disable = g_i18n:getText("action_autoChipperDisable", AutoChipper.MOD_NAME)
    spec.texts.statusOn = g_i18n:getText("info_autoChipperOn", AutoChipper.MOD_NAME)
    spec.texts.statusTurnOn = g_i18n:getText("info_autoChipperTurnOn", AutoChipper.MOD_NAME)
end

function AutoChipper:onDelete()
    -- don't leave a piece floating in the air without physics
    local spec = self[AutoChipper.SPEC_TABLE_NAME]
    if spec ~= nil and spec.hopShape ~= nil and entityExists(spec.hopShape) then
        addToPhysics(spec.hopShape)
    end
end

function AutoChipper:onReadStream(streamId, connection)
    self:setAutoChipperEnabled(streamReadBool(streamId), true)
end

function AutoChipper:onWriteStream(streamId, connection)
    local spec = self[AutoChipper.SPEC_TABLE_NAME]
    streamWriteBool(streamId, spec.isEnabled)
end

function AutoChipper:setAutoChipperEnabled(isEnabled, noEventSend)
    local spec = self[AutoChipper.SPEC_TABLE_NAME]
    if isEnabled == spec.isEnabled then
        return
    end

    AutoChipperToggleEvent.sendEvent(self, isEnabled, noEventSend)

    spec.isEnabled = isEnabled
    spec.scanTimer = 0
    spec.candidates = {}
    if not isEnabled and spec.hopShape ~= nil then
        -- chip the piece that is already in the intake instead of leaving it floating there
        AutoChipper.finishHop(self, spec)
    end

    AutoChipper.updateActionEventText(self)
    self:raiseActive()
end

---------------------------------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------------------------------

function AutoChipper:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient then
        local spec = self[AutoChipper.SPEC_TABLE_NAME]
        self:clearActionEventsTable(spec.actionEvents)
        if isActiveForInputIgnoreSelection then
            local _, actionEventId = self:addActionEvent(spec.actionEvents, InputAction.AUTOCHIPPER_TOGGLE, self, AutoChipper.actionEventToggle, false, true, false, true, nil)
            g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_HIGH)
            AutoChipper.updateActionEventText(self)
        end
    end
end

function AutoChipper.actionEventToggle(self, actionName, inputValue, callbackState, isAnalog)
    local spec = self[AutoChipper.SPEC_TABLE_NAME]
    self:setAutoChipperEnabled(not spec.isEnabled)
end

function AutoChipper.updateActionEventText(self)
    local spec = self[AutoChipper.SPEC_TABLE_NAME]
    local actionEvent = spec.actionEvents[InputAction.AUTOCHIPPER_TOGGLE]
    if actionEvent ~= nil then
        g_inputBinding:setActionEventText(actionEvent.actionEventId, spec.isEnabled and spec.texts.disable or spec.texts.enable)
    end
end

---------------------------------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------------------------------

function AutoChipper:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self[AutoChipper.SPEC_TABLE_NAME]
    if not spec.isEnabled then
        return
    end

    if self.isClient and isActiveForInputIgnoreSelection then
        if self:getIsTurnedOn() then
            g_currentMission:addExtraPrintText(string.format(spec.texts.statusOn, AutoChipper.MAX_LENGTH, AutoChipper.RADIUS))
        else
            g_currentMission:addExtraPrintText(spec.texts.statusTurnOn)
        end
    end

    if not self.isServer then
        return
    end

    self:raiseActive()

    if not self:getIsTurnedOn() then
        return
    end

    -- piece currently sitting in the intake
    if spec.hopShape ~= nil then
        spec.hopTimer = spec.hopTimer - dt
        if spec.hopTimer <= 0 then
            AutoChipper.finishHop(self, spec)
            spec.hopTimer = AutoChipper.HOP_INTERVAL - AutoChipper.HOP_DELAY
        end
        return
    end

    if spec.hopTimer > 0 then
        spec.hopTimer = spec.hopTimer - dt
        return
    end

    spec.scanTimer = spec.scanTimer - dt
    if spec.scanTimer <= 0 then
        spec.scanTimer = AutoChipper.SCAN_INTERVAL
        AutoChipper.scanArea(self, spec)
    end

    -- take the nearest valid piece
    while #spec.candidates > 0 do
        local shape = table.remove(spec.candidates, 1)
        if AutoChipper.getIsShapeValid(self, shape) then
            AutoChipper.startHop(self, spec, shape)
            break
        end
    end
end

function AutoChipper.scanArea(self, spec)
    spec.foundShapes = {}
    local x, y, z = getWorldTranslation(self.rootNode)
    overlapSphere(x, y, z, AutoChipper.RADIUS, "autoChipperOverlapCallback", self, CollisionFlag.TREE, true, false, true, false)

    local candidates = {}
    for shape, _ in pairs(spec.foundShapes) do
        if AutoChipper.getIsShapeValid(self, shape) then
            local sx, sy, sz = AutoChipper.getShapeCenter(shape)
            table.insert(candidates, {shape = shape, distance = MathUtil.vector3Length(sx - x, sy - y, sz - z)})
        end
    end
    table.sort(candidates, function(a, b) return a.distance < b.distance end)

    spec.candidates = {}
    for _, candidate in ipairs(candidates) do
        table.insert(spec.candidates, candidate.shape)
    end

    if AutoChipper.DEBUG then
        local numFound = 0
        for _ in pairs(spec.foundShapes) do
            numFound = numFound + 1
        end
        if numFound ~= spec.lastNumFound or #spec.candidates ~= spec.lastNumCandidates then
            spec.lastNumFound, spec.lastNumCandidates = numFound, #spec.candidates
            Logging.info("AutoChipper: scan found %d wood pieces in range, %d can be chipped", numFound, #spec.candidates)
        end
    end
    spec.foundShapes = {}
end

function AutoChipper:autoChipperOverlapCallback(objectId, ...)
    if objectId ~= nil and objectId ~= 0 and entityExists(objectId)
        and getHasClassId(objectId, ClassIds.MESH_SPLIT_SHAPE) and getSplitType(objectId) ~= 0
        and getRigidBodyType(objectId) == RigidBodyType.DYNAMIC then
        self[AutoChipper.SPEC_TABLE_NAME].foundShapes[objectId] = true
    end
end

function AutoChipper.getIsShapeValid(self, shape)
    local isValid, reason = AutoChipper.checkShape(self, shape)
    if not isValid and AutoChipper.DEBUG and reason ~= nil and shape ~= nil then
        -- log each skipped piece only once
        local spec = self[AutoChipper.SPEC_TABLE_NAME]
        spec.loggedShapes = spec.loggedShapes or {}
        if spec.loggedShapes[shape] ~= reason then
            spec.loggedShapes[shape] = reason
            Logging.info("AutoChipper: skipped piece %d - %s", shape, reason)
        end
    end
    return isValid
end

function AutoChipper.checkShape(self, shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return false, nil
    end
    if getRigidBodyType(shape) ~= RigidBodyType.DYNAMIC then
        return false, "not a loose piece"
    end
    if g_currentMission.nodeToObject[shape] ~= nil then
        return false, "belongs to a vehicle"
    end

    local splitType = g_splitShapeManager:getSplitTypeByIndex(getSplitType(shape))
    if splitType == nil or splitType.woodChipsPerLiter <= 0 then
        return false, "wood type gives no chips"
    end

    -- already being fed through the normal intake
    local woodCrusher = self.spec_woodCrusher
    if woodCrusher.moveTriggerNodes[shape] ~= nil or woodCrusher.crushNodes[shape] ~= nil then
        return false, nil
    end

    local length = AutoChipper.getShapeLength(shape)
    if length > AutoChipper.MAX_LENGTH then
        return false, string.format("too long (%.1f m)", length)
    end

    local cx, cy, cz = AutoChipper.getShapeCenter(shape)
    local vx, vy, vz = getWorldTranslation(self.rootNode)
    if MathUtil.vector3Length(cx - vx, cy - vy, cz - vz) > AutoChipper.RADIUS + 1 then
        return false, nil
    end

    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz)
    if cy - terrainY > AutoChipper.MAX_HEIGHT_ABOVE_GROUND then
        return false, string.format("too high above ground (%.1f m)", cy - terrainY)
    end

    -- stop when the chipper cannot take any more chips
    if self:getFillUnitFreeCapacity(woodCrusher.fillUnitIndex) <= 0 then
        return false, "chipper is full"
    end

    return true, nil
end

function AutoChipper.getShapeLength(shape)
    -- same length definition the game uses for wood prices (WoodContainer / WoodUnloadTrigger)
    local sizeX, sizeY, sizeZ = getSplitShapeStats(shape)
    return math.max(sizeX or 0, sizeY or 0, sizeZ or 0)
end

function AutoChipper.getShapeCenter(shape)
    -- real center of mass; branch pieces keep the axes of the original tree, so their local Y is not their length axis
    local lx, ly, lz = getCenterOfMass(shape)
    if lx ~= nil then
        return localToWorld(shape, lx, ly, lz)
    end
    local x, y, z = getShapeWorldBoundingSphere(shape)
    return x, y, z
end

---------------------------------------------------------------------------------------------------
-- Quick hop
---------------------------------------------------------------------------------------------------

function AutoChipper.startHop(self, spec, shape)
    local woodCrusher = self.spec_woodCrusher
    local refNode = woodCrusher.cutNode or woodCrusher.moveTriggers[1] or self.rootNode

    -- target: 1 m in front of the cut plane, inside the infeed (pieces travel along +X of the cut node)
    local cx, cy, cz = getWorldTranslation(refNode)
    local fx, fy, fz = localDirectionToWorld(refNode, 1, 0, 0)
    local tx, ty, tz = cx - fx, cy - fy, cz - fz

    -- volume and center of mass only work while the piece is still in physics
    spec.hopVolume = getVolume(shape) or 0
    spec.hopSplitType = g_splitShapeManager:getSplitTypeByIndex(getSplitType(shape))
    local comX, comY, comZ = getCenterOfMass(shape)
    if comX == nil then
        comX, comY, comZ = 0, 0, 0
    end

    -- out of physics so it can't collide with the chipper or tractor
    removeFromPhysics(shape)

    -- move the piece so its center of mass lands at the target, keeping its orientation
    local wx, wy, wz = localToWorld(shape, comX, comY, comZ)
    local ox, oy, oz = getWorldTranslation(shape)
    local parent = getParent(shape)
    setTranslation(shape, worldToLocal(parent, ox + tx - wx, oy + ty - wy, oz + tz - wz))

    spec.hopShape = shape
    spec.hopTimer = AutoChipper.HOP_DELAY
end

function AutoChipper.finishHop(self, spec)
    local shape = spec.hopShape
    spec.hopShape = nil
    if shape == nil or not entityExists(shape) then
        return
    end

    -- same as WoodCrusher.crushSplitShape, but with the volume measured before the hop
    local woodCrusher = self.spec_woodCrusher
    local splitType = spec.hopSplitType
    local volume = spec.hopVolume or 0
    if volume <= 0 then
        volume = getVolume(shape) or 0
    end

    deleteSplitShape(shape)
    woodCrusher.crushingTime = 1000

    if splitType ~= nil and splitType.woodChipsPerLiter > 0 and volume > 0 then
        self:onCrushedSplitShape(splitType, volume)
    end

    if AutoChipper.DEBUG then
        local liters = 0
        if splitType ~= nil then
            liters = volume * splitType.volumeToLiter * splitType.woodChipsPerLiter
        end
        Logging.info("AutoChipper: chipped piece, volume %.3f m3 -> %.0f l wood chips, fill level now %.0f l", volume, liters, self:getFillUnitFillLevel(woodCrusher.fillUnitIndex))
    end
end

---------------------------------------------------------------------------------------------------
-- Event
---------------------------------------------------------------------------------------------------

AutoChipperToggleEvent = {}
local AutoChipperToggleEvent_mt = Class(AutoChipperToggleEvent, Event)

InitEventClass(AutoChipperToggleEvent, "AutoChipperToggleEvent")

function AutoChipperToggleEvent.emptyNew()
    return Event.new(AutoChipperToggleEvent_mt)
end

function AutoChipperToggleEvent.new(object, isEnabled)
    local self = AutoChipperToggleEvent.emptyNew()
    self.object = object
    self.isEnabled = isEnabled
    return self
end

function AutoChipperToggleEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.isEnabled = streamReadBool(streamId)
    self:run(connection)
end

function AutoChipperToggleEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    streamWriteBool(streamId, self.isEnabled)
end

function AutoChipperToggleEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.object)
    end

    if self.object ~= nil and self.object:getIsSynchronized() then
        self.object:setAutoChipperEnabled(self.isEnabled, true)
    end
end

function AutoChipperToggleEvent.sendEvent(vehicle, isEnabled, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(AutoChipperToggleEvent.new(vehicle, isEnabled), nil, nil, vehicle)
        else
            g_client:getServerConnection():sendEvent(AutoChipperToggleEvent.new(vehicle, isEnabled))
        end
    end
end
