local ngx_sem  = require "ngx.semaphore"
local ringbuffer = require "resty.bid_proxy.ringbuffer"
local ljson_decoder = require "json_decoder"
local uuid = require "uuid"
local mmh3 = require "murmurhash3"

local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local NOTICE = ngx.NOTICE
local INFO = ngx.INFO

local timer = ngx.timer.at
local tcp = ngx.socket.tcp

local _M = {
    _VERSION = '0.20',
    decoder=ljson_decoder.new()
}
local mt = {
    __index = _M
}

local q_dict = {}

function _M.init_queue(host)
    log(WARN, "Dispatcher initializes queue id=", #q_dict+1, " host=", host)
    q_dict[#q_dict+1] =  {
        host = host,
        list = ringbuffer:new(100, #q_dict+1),
        req_dict = {},
        connection_status = false
    }
    return #q_dict
end

function _M.p(sema)
    local res, err = sema:wait(0.06)
    return res, err
end

local function restart_dispatcher(queue, host, index)

end

local function receiver(premature, host, index)
    local q = q_dict[index]

    local sock, err = tcp()
    local ok, err = sock:connect(host, 9324)
    --local ok, err = sock:connect(host, 10000)
    if not ok then
        log(ERR, "Receiver failed to connect ", host, " qid ", index)
        q.connection_status = false
        q.list:clear_pending()
        timer(1, receiver, host, index)
        return 
    end
    log(WARN, "Dispatcher initializes receiver id=", index, " host=", host)

    q.connection_status = true
    local sthread = ngx.thread.spawn(sender, sock, index)

    local read_stream = sock:receiveuntil("\r\n")

    local instance = ljson_decoder.new()

    while true do
        local ret_data, err, partial = read_stream()
        if err then
            log(ERR, "Receiver got connection failure for qid=", index)
            q.connection_status = false
            q.list:clear_pending()
            if q.list.sem_write_event:count() < 0 then
                q.list.sem_write_event:post(1)
            end
            ngx.thread.wait(sthread)
            timer(1, receiver, host, index)
            return 
        end
 
        if ret_data then
            local output, err_decode = instance:decode(ret_data)
            local node = nil
            if output then
                node =  q.req_dict[output.requestid]
            else
                log(ERR, "============== ret_data:", ret_data," Error:", err, " partial:", partial, "error_decode:", err_decode)
            end
            if node then
                log(INFO, "Receiver output_requestid=", output.requestid, "  node_requestid=", node.requestid, "  nodeid=", node.nodeid, "  semacount=", node.semaphore:count())
                q.req_dict[output.requestid] = nil
                if output.result == "ok" then 
		    node.response = output.response
                else
		    node.response = nil
                end
                node.semaphore:post()
                log(INFO, "Receiver done output_requestid=", output.requestid, "  node_requestid=", node.requestid, "  nodeid=", node.nodeid, "  semacount=", node.semaphore:count())
            end
        end
    end

end


local data = nil

function sender(sock, index)
    log(WARN, "Dispatcher initializes sender id=", index)

    local q = q_dict[index]

    while true do
        local res, err = q.list.sem_write_event:wait(10000)
        if not q.connection_status then
             log(ERR, "Sender got connection failure for qid=", index)
             return
        end

        if res then
            local cur = q.list:get_pending()
            if cur ~= nil then

                -- TODO: optimize string concatenation
                local buf = ""
                --local buft = {}
                while cur ~= nil  do
                    buf = cur.message.."\r\n"..buf
                    --buft[#buft+1] = cur.message
                    cur = cur.next
                end
                --local buf = table.concat(buft, "_DEL_")

                q.list:clear_pending()
                log(ERR, "=====", buf)
                local bytes, err = sock:send(buf)
                if err then
                    log(ERR, "Sender got connection failure for qid=", index)
                    return 
                end
            end

        end
    end
end

local host_dict = {
    ["nexage.fractionalmedia.com"]="nexage",
    ["dev.fractionalmedia.com"]="nexage",
    ["mopub.fractionalmedia.com"]="mopub",
}

function _M.get_ssp(host)
    return host_dict[host]
end

local function get_nexage_fmid(data)
    if data and data.device and data.device.ext then
        return data.device.ext.nex_ifa
    else
        return nil
    end
end

local function get_mopub_fmid(data)
    if data and data.device and data.device.ext then
        return data.device.ext.idfa
    else
        return nil
    end
end

local ssp_dict={
    nexage=get_nexage_fmid,
    mopub=get_mopub_fmid
}

function _M.get_fmid(ssp, data)
    return ssp_dict[ssp](data)
end

function _M.spawn_dispatcher(host, index)
    timer(0, receiver, host, index)
end

function _M.shard(fmid)
    
    local output = mmh3.hash32(fmid, 45562)
    return output % 2 + 1
end

function _M.insert_req(fmid, shard_id, ssp, data)
    local q = q_dict[shard_id]
    if not q.connection_status then
        return nil, "socket is not connected."
    end 

    local node, err = q.list:pop()
    if node==nil then
        return nil, "ringbuffer is full"
    end

    local bidid = uuid.generate_random()
    bidid = bidid.."__"..(50+shard_id)
    local request = "{\"request\":\"target2\",\"requestid\":" .. node.requestid .. ",\"ssp\":\""..ssp.."\",\"alwaysbid\":\"0\",\"fm_userid\":\""..fmid .. "\",\"fm_id_src\":\"idfa\",\"bid id\":\""..bidid.."\",\"bidrequest\":"..data.."}"
    
    node.message = request
    q.req_dict[node.requestid] = node
    if q.list.sem_write_event:count() <= 0 then
        q.list.sem_write_event:post(1)
    end
    return node, nil
end

function _M.free_req(shard_id, node)
    local q = q_dict[shard_id]
    q.req_dict[node.requestid] = nil

    -- If request is timed out and semaphore post in receiver is also scheduled,
    -- semaphore count may be >0. 
    if node.semaphore:count() ~= 0 then
        log(NOTICE, "dispatcher: clear semaphore requestid=", node.requestid, "  nodeid=", node.nodeid, " semacount=", node.semaphore:count())
        node.semaphore = ngx_sem:new(0)
    end
    node.message = nil
    node.resopnse = nil
    node.request_id = nil

    q.list:set_complete(node)
end

return _M
