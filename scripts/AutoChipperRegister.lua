--
-- AutoChipper for FS25
-- Adds the autoChipper specialization to every vehicle type that has a WoodCrusher.
--

local modName = g_currentModName

local function addAutoChipperToWoodCrushers(typeManager)
    if typeManager.typeName ~= "vehicle" then
        return
    end

    local specName = modName .. ".autoChipper"
    if typeManager.specializationManager:getSpecializationByName(specName) == nil then
        Logging.error("AutoChipper: specialization '%s' not found", specName)
        return
    end

    for typeName, typeEntry in pairs(typeManager:getTypes()) do
        if SpecializationUtil.hasSpecialization(WoodCrusher, typeEntry.specializations) and typeEntry.specializationsByName[specName] == nil then
            typeManager:addSpecialization(typeName, specName)
        end
    end
end

TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, addAutoChipperToWoodCrushers)
