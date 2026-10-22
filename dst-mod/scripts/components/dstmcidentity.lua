local function uuid()
    return ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
        return string.format("%x", c == "x" and math.random(0, 15) or math.random(8, 11))
    end)
end
local Identity = Class(function(self, inst)
    self.inst = inst
    self.world_uuid = uuid()
    self.shard = tostring(TheShard:GetShardId())
end)
function Identity:OnSave() return {world_uuid=self.world_uuid, shard=self.shard} end
function Identity:OnLoad(data)
    if data and type(data.world_uuid) == "string" and data.world_uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
        self.world_uuid = data.world_uuid
    end
    -- Shard identity is the actual loaded shard; a copied cave cannot impersonate Master.
    self.shard = tostring(TheShard:GetShardId())
end
Identity.NewUUID = uuid
return Identity
