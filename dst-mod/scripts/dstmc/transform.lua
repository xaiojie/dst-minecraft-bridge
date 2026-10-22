local M={}
function M.ToMC(s,p) return {x=s.mc_origin.x-(p.x-s.dst_origin.x),y=s.mc_origin.y+p.y-s.dst_origin.y,z=s.mc_origin.z+p.z-s.dst_origin.z} end
function M.ToDST(s,p) return {x=s.dst_origin.x-(p.x-s.mc_origin.x),y=s.dst_origin.y+p.y-s.mc_origin.y,z=s.dst_origin.z+p.z-s.mc_origin.z} end
function M.BoxToMC(s,b)
    local a,c=M.ToMC(s,b.min),M.ToMC(s,b.max)
    return {min={x=math.min(a.x,c.x),y=math.min(a.y,c.y),z=math.min(a.z,c.z)},max={x=math.max(a.x,c.x),y=math.max(a.y,c.y),z=math.max(a.z,c.z)}}
end
function M.SameSession(a,b)
    if not a or not b or a.epoch~=b.epoch or not a.pair or not b.pair then return false end
    for _,k in ipairs({'dst_world','dst_shard','mc_world','mc_dimension','region'})do if a.pair[k]~=b.pair[k] then return false end end
    return true
end
return M
