local transform=require('dstmc/transform')
local M={};local revision=0;local entities={}
function M.Find(id)local e=entities[id];return e and e:IsValid() and e or nil end
function M.Sample(session)
    revision=revision+1;local bodies={};entities={}
    if not ThePlayer then return {revision=revision,bodies=bodies} end
    local x,y,z=ThePlayer.Transform:GetWorldPosition()
    for _,e in ipairs(TheSim:FindEntities(x,y,z,32,nil,{'INLIMBO','FX','CLASSIFIED','dstmc_bridge'}))do
        if e~=ThePlayer and e.components.health and not e.components.health:IsDead() and e.components.combat then
            if not e.components.dstmcidentity then e:AddComponent('dstmcidentity') end
            local id=e.components.dstmcidentity.world_uuid;entities[id]=e
            local ex,ey,ez=e.Transform:GetWorldPosition();local r=math.max(.2,e:GetPhysicsRadius(.4))
            -- DST exposes cylinder radius, but no Lua collision height accessor.
            -- Explicit body profiles can override the conservative humanoid height.
            local height=e:HasTag('epic') and 4 or e:HasTag('smallcreature') and .6 or 1.8
            bodies[#bodies+1]={id=id,box=transform.BoxToMC(session,{min={x=ex-r,y=ey,z=ez-r},max={x=ex+r,y=ey+height,z=ez+r}}),health=e.components.health.currenthealth,max_health=e.components.health.maxhealth,revision=revision}
        end
    end
    return {revision=revision,bodies=bodies}
end
return M
