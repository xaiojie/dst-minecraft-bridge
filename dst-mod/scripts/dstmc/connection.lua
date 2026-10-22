local json = require("json")
local world = require("dstmc/world")
local camera = require("dstmc/camera")
local Identity = require("components/dstmcidentity")
local M = {}
-- The single acceptance gate in mc/src/main/java/dev/jay/dstmc/server/WorldExchange.java
-- accepts exactly this dimension, region and MC origin. It returns WORLD_MISMATCH for
-- anything else rather than re-pairing, so these are contract values, not tunables.
local REGION, MC_DIMENSION, MC_ORIGIN = "ground", "dst_mc_bridge:stage", {x=0,y=64,z=0}
local session, generation, pending, camera_pending, last_exchange, enabled = nil,0,false,false,0,false
-- Authoritative key from the last lease; the native pins the newest frame anyway,
-- so a fresh /v2/status round trip per camera cycle is wasted latency.
local last_key
local now = GetTimeRealSeconds
local function request(port,path,body,callback)
    TheSim:QueryServer("http://127.0.0.1:"..port..path,function(raw,success,code)
        local ok,value=pcall(json.decode,raw or "")
        callback(success and code==200 and ok and value or nil)
    end,body and "POST" or "GET",body and json.encode(body) or nil)
end
-- The native may answer with a newer frame than the requested one when the
-- requested slot rotated out during the round trip; pose and pixels of the
-- response always belong to the key it returns, so that key is authoritative.
local function sessionkey(k,s)
    if not s or type(k)~="table" or type(k.id)~="number" or type(k.pair)~="table" then return false end
    if k.epoch~=s.epoch then return false end
    for _,field in ipairs({"dst_world","dst_shard","mc_world","mc_dimension","region"}) do
        if k.pair[field]~=s.pair[field] then return false end
    end
    return true
end
local function samekey(a,b)
    if not a or not b or a.id~=b.id or a.epoch~=b.epoch or not a.pair or not b.pair then return false end
    for _,field in ipairs({"dst_world","dst_shard","mc_world","mc_dimension","region"}) do
        if a.pair[field]~=b.pair[field] then return false end
    end
    return true
end
-- Drop the current pairing but stay enabled: a restarted MC, a rotated epoch or a
-- temporarily empty stream must re-handshake instead of disabling the bridge for
-- the rest of the session. M.Release() below is the explicit, permanent stop.
local function reset_session()
    last_key=nil
    generation=generation+1
    local key=camera.Key()
    camera.Release()
    if session and key then request(39380,"/v2/camera/applied",{protocol=2,pair=session.pair,epoch=session.epoch,key=key,applied=false},function() end) end
    session=nil
end
function M.Release()
    enabled=false
    reset_session()
end
local function handshake()
    if pending then return end
    local identity=world.LocalWorld()
    if not identity then return end
    pending=true;local token=generation
    request(39379,"/v2/status",nil,function(status)
        if token~=generation then pending=false;return end
        if not status or status.protocol~=2 or status.fixture or not status.mc_world then pending=false;return end
        local pair={dst_world=identity.world_uuid,dst_shard=identity.shard,mc_world=status.mc_world,mc_dimension=MC_DIMENSION,region=REGION}
        local epoch=Identity.NewUUID()
        request(39379,"/v2/handshake",{protocol=2,pair=pair,epoch=epoch,dst_origin=world.Origin(),mc_origin=MC_ORIGIN},function(value)
            pending=false
            if token~=generation then return end
            if value and value.epoch==epoch and value.pair.dst_world==identity.world_uuid then last_key=nil;session=value;print("DSTMC_PAIRED "..json.encode(value.pair)) end
        end)
    end)
end
local function lease(key,token,expected)
    request(39380,"/v2/camera/lease",{protocol=2,pair=expected.pair,epoch=expected.epoch,key=key},function(value)
        if token~=generation or session~=expected then camera_pending=false;return end
        if not value or not value.lease or not sessionkey(value.lease.key,expected) then camera_pending=false;return end
        local leased=value.lease.key
        last_key=leased
        local applied=camera.ApplyLease(value.lease)
        if not applied then camera_pending=false;reset_session();return end
        -- The wrapper applies this pose on the next camera update, then confirms it there.
        M.ack={key=leased,session=expected,generation=token}
    end)
end
local function updatecamera()
    if camera_pending or not session then return end
    camera_pending=true;local token=generation;local expected=session
    if last_key then lease(last_key,token,expected);return end
    request(39379,"/v2/status",nil,function(status)
        if token~=generation or session~=expected then camera_pending=false;return end
        if not status or status.epoch~=expected.epoch then camera_pending=false;reset_session();return end
        -- PAIRED with a temporarily empty stream (MC switching dimension, resize):
        -- keep the pairing and try again on the next camera update.
        if not status.latest_frame then camera_pending=false;return end
        lease(status.latest_frame,token,expected)
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
            pending=false;if token==generation and not value then reset_session() end
        end)
    end
end
function M.Start(connect)
    enabled=connect
    camera.Install(M.Update)
end
return M
