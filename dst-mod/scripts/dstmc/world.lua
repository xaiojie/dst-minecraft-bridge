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
local active,controlled,saved_enabled,target=nil,nil,nil,nil
function M.Bind(session) M.Release();active=session end
function M.Release()
    if controlled and controlled:IsValid() and controlled.components.playercontroller and saved_enabled~=nil then controlled.components.playercontroller:Enable(saved_enabled)end
    active,controlled,saved_enabled,target=nil,nil,nil,nil
end
function M.ApplyPlayer(player,epoch,owner)
    if not active or active.epoch~=epoch or not ThePlayer or not player then return false end
    if owner=='DST' then
        if controlled and saved_enabled~=nil then controlled.components.playercontroller:Enable(saved_enabled)end
        controlled,saved_enabled,target=nil,nil,nil;return true
    end
    if controlled~=ThePlayer then
        controlled=ThePlayer;local controller=controlled.components.playercontroller
        if controller then saved_enabled=controller:IsEnabled();controller:Enable(false)end
    end
    target=player.position
    M.Update()
    return true
end
function M.Update()
    if not target or not active or controlled~=ThePlayer then return end
    if controlled.components.locomotor then controlled.components.locomotor:Stop()end
    if controlled.Physics then controlled.Physics:Stop();controlled.Physics:Teleport(target.x,target.y,target.z)
    else controlled.Transform:SetPosition(target.x,target.y,target.z)end
end
return M
