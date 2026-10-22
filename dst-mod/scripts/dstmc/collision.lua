local transform=require('dstmc/transform')
local M={};local session;local blocks,meshes,walls={},{},{};local revision=-1
local dirs={{-1,0,0},{1,0,0},{0,-1,0},{0,1,0},{0,0,-1},{0,0,1}}
local faces={{{0,0,0},{0,0,1},{0,1,1},{0,1,0}},{{1,0,1},{1,0,0},{1,1,0},{1,1,1}},{{0,0,1},{0,0,0},{1,0,0},{1,0,1}},{{0,1,0},{0,1,1},{1,1,1},{1,1,0}},{{1,0,0},{0,0,0},{0,1,0},{1,1,0}},{{0,0,1},{1,0,1},{1,1,1},{0,1,1}}}
local function key(c)return c.x..':'..c.y..':'..c.z end
local function region(c)return math.floor(c.x/16)..':'..math.floor(c.z/16)end
function M.Clear()
    for _,e in pairs(meshes)do if e:IsValid()then e:Remove()end end
    for _,p in pairs(walls)do TheWorld.Pathfinder:RemoveWall(p.x,p.y,p.z)end
    blocks,meshes,walls={},{},{};revision=-1;session=nil
end
function M.Bind(s)M.Clear();session=s end
function M.Revision()return revision end
function M.Apply(delta)
    if not session or type(delta)~='table' then return false end
    if delta.revision<revision then return true end
    if not delta.full and delta.from~=revision then revision=-1;return false end
    if delta.revision==revision and not delta.full then return true end
    local nextblocks={};if not delta.full then for k,v in pairs(blocks)do nextblocks[k]=v end end
    local dirty={}
    for _,c in pairs(blocks)do if delta.full then dirty[region(c)]=true end end
    for _,change in ipairs(delta.changes)do local c=change.cell
        nextblocks[key(c)]=change.state~='minecraft:air' and c or nil;dirty[region(c)]=true
        for _,d in ipairs(dirs)do dirty[region({x=c.x+d[1],z=c.z+d[3]})]=true end
    end
    local staged={};local newwalls={}
    local ok,err=pcall(function()
        local vertices={}
        for _,c in pairs(nextblocks)do
            local r=region(c)
            if dirty[r]then
                vertices[r]=vertices[r] or {}
                for face,d in ipairs(dirs)do if not nextblocks[key({x=c.x+d[1],y=c.y+d[2],z=c.z+d[3]})]then
                    -- X reflection reverses winding. Vertices are relative to fixed DST origin.
                    for _,index in ipairs({1,3,2,1,4,3})do local v=faces[face][index];local a=vertices[r]
                        a[#a+1]=-(c.x+v[1]-session.mc_origin.x);a[#a+1]=c.y+v[2]-session.mc_origin.y;a[#a+1]=c.z+v[3]-session.mc_origin.z
                    end
                end end
            end
            if c.y<session.mc_origin.y+1.8 and c.y+1>session.mc_origin.y then
                local p=transform.ToDST(session,{x=c.x+.5,y=session.mc_origin.y,z=c.z+.5});newwalls[p.x..':'..p.z]=p
            end
        end
        for r,v in pairs(vertices)do if #v>0 then
            local e=CreateEntity();staged[r]=e;e.entity:AddTransform();local physics=e.entity:AddPhysics();e:AddTag('CLASSIFIED');e:AddTag('dstmc_bridge');e.persists=false
            e.Transform:SetPosition(session.dst_origin.x,session.dst_origin.y,session.dst_origin.z)
            physics:SetMass(0);physics:SetCollisionGroup(COLLISION.OBSTACLES);physics:SetCollisionMask(COLLISION.CHARACTERS,COLLISION.GIANTS,COLLISION.ITEMS,COLLISION.FLYERS)
            physics:SetTriangleMesh(v);physics:SetDontRemoveOnSleep(true)
        end end
    end)
    if not ok then for _,e in pairs(staged)do e:Remove()end;print('DSTMC_COLLISION_FAILED '..tostring(err));return false end
    -- All replacements exist before old shapes are released; failures preserve the old revision.
    for r in pairs(dirty)do if meshes[r]then meshes[r]:Remove()end;meshes[r]=staged[r]end
    for k,p in pairs(walls)do if not newwalls[k]then TheWorld.Pathfinder:RemoveWall(p.x,p.y,p.z)end end
    for k,p in pairs(newwalls)do if not walls[k]then TheWorld.Pathfinder:AddWall(p.x,p.y,p.z)end end
    blocks,walls,revision=nextblocks,newwalls,delta.revision;return true
end
return M
