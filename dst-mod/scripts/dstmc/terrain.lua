local transform=require('dstmc/transform')
local M={};local revision=0
function M.Sample(session)
    revision=revision+1;local result={revision=revision,ground={},obstacles={}}
    local x,y,z=ThePlayer.Transform:GetWorldPosition();local center=transform.ToMC(session,{x=x,y=y,z=z})
    local floorY=math.floor(session.mc_origin.y-1)
    for cz=math.floor(center.z)-32,math.floor(center.z)+32 do
        local start=nil
        for cx=math.floor(center.x)-32,math.floor(center.x)+33 do
            local p=transform.ToDST(session,{x=cx+.5,y=session.mc_origin.y,z=cz+.5})
            local walk=cx<=math.floor(center.x)+32 and TheWorld.Map:IsPassableAtPoint(p.x,0,p.z) and not TheWorld.Map:IsOceanAtPoint(p.x,0,p.z)
            if walk and not start then start=cx end
            if not walk and start then result.ground[#result.ground+1]={x=start,y=floorY,z=cz,length=cx-start};start=nil end
        end
    end
    for _,e in ipairs(TheSim:FindEntities(x,0,z,34,nil,{'INLIMBO','FX','CLASSIFIED','dstmc_bridge'}))do
        if e~=ThePlayer and e.Physics and not e.components.locomotor and (e.components.workable or e:HasTag('wall') or e:HasTag('structure')) then
            local r=e:GetPhysicsRadius(0)
            if r>0 then local ex,ey,ez=e.Transform:GetWorldPosition()
                result.obstacles[#result.obstacles+1]=transform.BoxToMC(session,{min={x=ex-r,y=ey,z=ez-r},max={x=ex+r,y=ey+2,z=ez+r}})
            end
        end
    end
    return result
end
return M
