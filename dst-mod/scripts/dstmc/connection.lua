local json = require("json")
local world = require("dstmc/world")
local camera = require("dstmc/camera")
local Identity = require("components/dstmcidentity")
local M = {}
local session, generation, pending, camera_pending, last_exchange, enabled = nil,0,false,false,0,false
local now = GetTimeRealSeconds
local function request(port,path,body,callback)
    TheSim:QueryServer("http://127.0.0.1:"..port..path,function(raw,success,code)
        local ok,value=pcall(json.decode,raw or "")
        callback(success and code==200 and ok and value or nil)
    end,body and "POST" or "GET",body and json.encode(body) or nil)
end
local function samekey(a,b)
    if not a or not b or a.id~=b.id or a.epoch~=b.epoch or not a.pair or not b.pair then return false end
    for _,field in ipairs({"dst_world","dst_shard","mc_world","mc_dimension","region"}) do
        if a.pair[field]~=b.pair[field] then return false end
    end
    return true
end
function M.Release()
    enabled=false
    generation=generation+1
    local key=camera.Key()
    camera.Release()
    if session and key then request(39380,"/v2/camera/applied",{protocol=2,pair=session.pair,epoch=session.epoch,key=key,applied=false},function() end) end
    session=nil
end
local function handshake()
    if pending then return end
    local identity=world.LocalWorld()
    if not identity then return end
    pending=true;local token=generation
    request(39379,"/v2/status",nil,function(status)
        if token~=generation then pending=false;return end
        if not status or status.protocol~=2 or status.fixture or not status.mc_world then pending=false;return end
        local pair={dst_world=identity.world_uuid,dst_shard=identity.shard,mc_world=status.mc_world,mc_dimension="dst_mc_bridge:stage",region="first-person-test"}
        local epoch=Identity.NewUUID()
        request(39379,"/v2/handshake",{protocol=2,pair=pair,epoch=epoch,dst_origin=world.Origin(),mc_origin={x=.5,y=64,z=.5}},function(value)
            pending=false
            if token~=generation then return end
            if value and value.epoch==epoch and value.pair.dst_world==identity.world_uuid then session=value;print("DSTMC_PAIRED "..json.encode(value.pair)) end
        end)
    end)
end
local function updatecamera()
    if camera_pending or not session then return end
    camera_pending=true;local token=generation;local expected=session
    request(39379,"/v2/status",nil,function(status)
        if token~=generation or session~=expected then camera_pending=false;return end
        if not status or status.epoch~=expected.epoch or not status.latest_frame then camera_pending=false;M.Release();return end
        local key=status.latest_frame
        request(39380,"/v2/camera/lease",{protocol=2,pair=expected.pair,epoch=expected.epoch,key=key},function(value)
            if token~=generation or session~=expected then camera_pending=false;return end
            if not value or not value.lease or not samekey(value.lease.key,key) then camera_pending=false;return end
            if not camera.ApplyLease(value.lease) then camera_pending=false;M.Release();return end
            -- The wrapper applies this pose on the next camera update, then confirms it there.
            M.ack={key=key,session=expected,generation=token}
        end)
    end)
end
function M.Update()
    if not enabled or not world.LocalWorld() then return end
    if M.ack then
        local ack=M.ack;M.ack=nil
        if ack.generation==generation and samekey(camera.Key(),ack.key) then
            request(39380,"/v2/camera/applied",{protocol=2,pair=ack.session.pair,epoch=ack.session.epoch,key=ack.key,applied=true},function(value)
                camera_pending=false
                if ack.generation==generation and (not value or not value.accepted) then camera.Release() end
            end)
        else camera_pending=false end
    end
    if not session then if now()-last_exchange>=1 then last_exchange=now();handshake() end;return end
    updatecamera()
    if not pending and now()-last_exchange>=.05 then
        pending=true;last_exchange=now();local token=generation
        request(39379,"/v2/exchange",{protocol=2,pair=session.pair,epoch=session.epoch,commands={},damage_events={}},function(value)
            pending=false;if token==generation and not value then M.Release() end
        end)
    end
end
function M.Start(connect)
    enabled=connect
    camera.Install(M.Update)
end
return M
