local json = require("json")
local world = require("dstmc/world")
local camera = require("dstmc/camera")
local Identity = require("components/dstmcidentity")
local gameplay=require("dstmc/gameplay")
local mailbox=require("dstmc/mailbox")
local M = {}
-- The single acceptance gate in mc/src/main/java/dev/jay/dstmc/server/WorldExchange.java
-- accepts exactly this dimension, region and MC origin. It returns WORLD_MISMATCH for
-- anything else rather than re-pairing, so these are contract values, not tunables.
local REGION, MC_DIMENSION, MC_ORIGIN = "ground", "dst_mc_bridge:stage", {x=0,y=64,z=0}
local session, generation, pending, camera_pending, last_exchange, enabled = nil,0,false,false,0,false
-- Authoritative key from the last lease; the native pins the newest frame anyway,
-- so a fresh /v2/status round trip per camera cycle is wasted latency.
local last_key
local peer_seen,request_at,camera_at,camera_request=0,0,0,0
local now = GetTimeRealSeconds
local function request(port,path,body,callback)
    if port==39380 and mailbox.Active() and mailbox.Request(path,body,callback)then return end
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
    mailbox.Close()
    M.ack=nil;pending=false;camera_pending=false;camera_request=camera_request+1
    gameplay.Release()
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
    pending=true;request_at=now();local token=generation
    request(39379,"/v2/status",nil,function(status)
        if token~=generation then return end
        if not status or status.protocol~=2 or status.fixture or not status.mc_world then pending=false;return end
        local pair={dst_world=identity.world_uuid,dst_shard=identity.shard,mc_world=status.mc_world,mc_dimension=MC_DIMENSION,region=REGION}
        local epoch=Identity.NewUUID()
        request(39379,"/v2/handshake",{protocol=2,pair=pair,epoch=epoch,dst_origin=world.Origin(),mc_origin=MC_ORIGIN},function(value)
            if token~=generation then return end
            pending=false
            if value and value.epoch==epoch and value.pair.dst_world==identity.world_uuid then last_key=nil;session=value;peer_seen=now();gameplay.Bind(value);print("DSTMC_PAIRED "..json.encode(value.pair)) end
        end)
    end)
end
local function acceptlease(value,token,expected,operation)
    if token~=generation or session~=expected or operation~=camera_request then return end
    if not value or not value.lease or not sessionkey(value.lease.key,expected) then camera_pending=false;return end
    if value.mailbox and not mailbox.Active()then mailbox.Bind(value.mailbox)end
    peer_seen=now();gameplay.Owner(value.input_owner)
    if value.input_owner=='DST' then camera.Release();camera_pending=false;return end
    local leased=value.lease.key;last_key=leased
    if not camera.ApplyLease(value.lease)then camera_pending=false;reset_session();return end
    M.ack={key=leased,session=expected,generation=token,operation=operation}
end
local function lease(key,token,expected,operation)
    camera_at=now()
    request(39380,"/v2/camera/lease",{protocol=2,pair=expected.pair,epoch=expected.epoch,key=key},function(value)acceptlease(value,token,expected,operation)end)
end
local function updatecamera()
    if camera_pending or not session then return end
    camera_pending=true;camera_at=now();camera_request=camera_request+1;local operation=camera_request;local token=generation;local expected=session
    if last_key then lease(last_key,token,expected,operation);return end
    request(39379,"/v2/status",nil,function(status)
        if token~=generation or session~=expected or operation~=camera_request then return end
        if not status or status.epoch~=expected.epoch then camera_pending=false;reset_session();return end
        -- PAIRED with a temporarily empty stream (MC switching dimension, resize):
        -- keep the pairing and try again on the next camera update.
        if not status.latest_frame then camera_pending=false;return end
        lease(status.latest_frame,token,expected,operation)
    end)
end
function M.Update()
    if not enabled or not world.LocalWorld() then return end
    if session and now()-peer_seen>2.5 then reset_session() end
    if pending and now()-request_at>3 then reset_session() end
    if camera_pending and now()-camera_at>2 then
        camera_request=camera_request+1;camera_pending=false;M.ack=nil;mailbox.Close();camera.Release()
    end
    gameplay.Update()
    if M.ack then
        local ack=M.ack;M.ack=nil
        if ack.generation==generation and ack.operation==camera_request and samekey(camera.Key(),ack.key) then
            local cycling=mailbox.Active();camera_at=now();camera_request=camera_request+1;local operation=camera_request
            request(39380,cycling and "/v2/camera/cycle" or "/v2/camera/applied",{protocol=2,pair=ack.session.pair,epoch=ack.session.epoch,key=ack.key,applied=true},function(value)
                if ack.generation~=generation or session~=ack.session or operation~=camera_request then return end
                if cycling then acceptlease(value,ack.generation,ack.session,operation)
                else camera_pending=false;if not value or not value.accepted then camera.Release()end end
            end)
        else camera_pending=false end
    end
    mailbox.Poll() -- after ACK: a newly read pose is applied by the next camera update
    if not session then if now()-last_exchange>=1 then last_exchange=now();handshake() end;return end
    updatecamera()
    if not pending and now()-last_exchange>=.05 then
        pending=true;last_exchange=now();request_at=now();local token=generation;local expected=session
        local payload,damage=gameplay.Sample()
        request(39379,"/v2/exchange",{protocol=2,pair=expected.pair,epoch=expected.epoch,commands={{kind='world_snapshot',payload=payload}},damage_events=damage},function(value)
            if token~=generation or session~=expected then return end
            pending=false
            if not value or not gameplay.Accept(value,payload) then reset_session()else peer_seen=now()end
        end)
    end
end
function M.Start(connect)
    enabled=connect
    camera.Install(M.Update)
end
return M
