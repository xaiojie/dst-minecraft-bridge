local M = {}
function M.LocalWorld()
    if TheWorld == nil or not TheWorld.ismastersim or TheWorld:HasTag("cave") or TheNet:IsDedicated() or ThePlayer == nil then return nil end
    return TheWorld.components.dstmcidentity
end
function M.Origin()
    if ThePlayer == nil then return nil end
    local x,y,z = ThePlayer.Transform:GetWorldPosition()
    return {x=x,y=y,z=z}
end
return M
