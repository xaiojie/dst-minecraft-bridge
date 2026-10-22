local M = {}
local lease, expires, installed, calibration = nil, 0, nil, nil
local hidden_player, saved_alpha = nil, nil
local now = GetTimeRealSeconds
local function finite(n) return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge end
local function vector(v) return type(v)=="table" and finite(v.x) and finite(v.y) and finite(v.z) end
local function restore_avatar()
    if hidden_player and hidden_player:IsValid() and hidden_player.AnimState then
        local r,g,b,a=hidden_player.AnimState:GetMultColour()
        if a==0 then hidden_player.AnimState:SetMultColour(r,g,b,saved_alpha) end
    end
    hidden_player=nil;saved_alpha=nil
end
local function hide_avatar()
    if hidden_player~=ThePlayer then restore_avatar() end
    if ThePlayer and ThePlayer:IsValid() and ThePlayer.AnimState then
        local r,g,b,a=ThePlayer.AnimState:GetMultColour()
        if hidden_player==nil or a~=0 then saved_alpha=a end
        hidden_player=ThePlayer
        -- Render tint only: entity visibility is queried by AI and must stay unchanged.
        hidden_player.AnimState:SetMultColour(r,g,b,0)
    end
end
local function apply(p)
    hide_avatar()
    TheSim:SetCameraPos(p.position.x,p.position.y,p.position.z)
    TheSim:SetCameraDir(p.forward.x,p.forward.y,p.forward.z)
    TheSim:SetCameraUp(p.up.x,p.up.y,p.up.z)
    TheSim:SetCameraFOV(2 * math.atan(1 / p.projection[6]) * 180 / math.pi)
end
function M.ApplyLease(value)
    local p = value and value.pose
    if not p or p.space~="DST" or not vector(p.position) or not vector(p.forward) or not vector(p.up) or type(p.projection)~="table" or not finite(p.projection[6]) or p.projection[6]<=0 then return false end
    -- Hold the applied pose until the next lease arrives; the connection loop
    -- re-leases several times a second, and a dead client must release it.
    lease=value;expires=now()+1.0
    return true
end
function M.Release() lease=nil;expires=0;calibration=nil;restore_avatar() end
function M.Key() return lease and lease.key end
function M.Calibrate()
    local p = require("dstmc/world").Origin()
    if not p then return false end
    M.Release()
    -- Bounded, no handshake and no saved transform. Fixed right/up landmarks can be compared.
    p.y=p.y+2
    calibration={position=p,forward={x=0,y=0,z=-1},up={x=0,y=1,z=0},projection={1,0,0,0,0,1,0,0,0,0,-1,-1,0,0,-2,0}}
    expires=now()+12
    print("DSTMC_CALIBRATION "..require("json").encode(calibration))
    return true
end
function M.Install(onupdate)
    if TheCamera == nil or installed == TheCamera then return end
    installed=TheCamera
    local original=installed.Update
    installed.Update=function(self,...)
        original(self,...)
        if now()>=expires then M.Release() end
        if calibration then apply(calibration) elseif lease then apply(lease.pose) end
        onupdate()
    end
end
return M
