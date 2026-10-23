-- Local file rendezvous avoids TheSim:QueryServer's multi-frame dispatch delay.
-- Files contain only control metadata; image pixels stay in the leased mmap ring.
local json=require('json')
local identity=require('components/dstmcidentity')
local M={};local directory,pending,windows_path
function M.Bind(path)
    if type(path)~='string' then return false end
    local drive=path:match('^%a:[/\\]')~=nil
    local unc=path:sub(1,2)=='\\\\'
    if (path:sub(1,1)=='/' or drive or unc) and io and os and os.rename then directory=path;windows_path=drive or unc;return true end
    return false
end
function M.Active()return directory~=nil end
function M.Close()directory=nil;pending=nil;windows_path=nil end
function M.Request(path,body,callback)
    if not directory or pending then return false end
    local id=identity.NewUUID();local temporary=directory..'/request-'..id..'.tmp'
    local f=io.open(temporary,'w');if not f then M.Close();return false end
    local ok=pcall(function()
        f:write(json.encode({id=id,path=path,body=body}));f:close()
        -- Lua's Windows rename cannot replace an existing file. There is only
        -- one producer and one outstanding request; readers safely skip the
        -- brief absent-file interval and never see partial JSON.
        if windows_path then os.remove(directory..'/request.json')end
        assert(os.rename(temporary,directory..'/request.json'))
    end)
    if not ok then pcall(function()f:close()end);os.remove(temporary);M.Close();return false end
    pending={id=id,callback=callback,at=GetTimeRealSeconds()};return true
end
function M.Poll()
    if not pending then return end
    local f=io.open(directory..'/response.json','r');local value
    if f then local raw=f:read('*a');f:close();if #raw<=16384 then local ok,decoded=pcall(json.decode,raw);if ok then value=decoded end end end
    if value and value.id==pending.id then local callback=pending.callback;pending=nil;callback(value.value)
    elseif GetTimeRealSeconds()-pending.at>.75 then local callback=pending.callback;M.Close();callback(nil)end
end
return M
