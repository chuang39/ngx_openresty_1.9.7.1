local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local NOTICE = ngx.NOTICE
local INFO = ngx.INFO


local timer = ngx.timer.at


local _M = {
    _VERSION = '0.20',
}



local start_time = nil
local total_request = nil
local total_valid = nil
local total_invalid = nil
local timedout_request = nil
local nobid = nil
local bid = nil
local last_total = nil
local last_invalid = nil
local last_timedout = nil
local last_nobid = nil
local last_bid = nil


local function record_qps()
    --log(WARN, "QPS=", (total_request-last_total), "  total=", total_request, " timedout_request=", timedout_request, " nobid=", nobid)
    log(WARN, (total_request-last_total), "\t", (total_invalid-last_invalid),"\t",(bid-last_bid),"\t",(timedout_request-last_timedout), "\t", (nobid-last_nobid),"\t", total_request, "\t", total_valid,"\t", total_invalid,"\t", bid,"\t",timedout_request,"\t", nobid)
    last_total = total_request
    last_invalid = total_invalid
    last_timedout = timedout_request
    last_nobid = nobid
    last_bid = bid
    timer(60, record_qps)
end

function _M.init()
    start_time = ngx.now()
    total_request = 0
    total_valid = 0
    total_invalid = 0
    timedout_request = 0
    nobid = 0
    bid = 0
    last_total = 0
    last_invalid = 0
    last_timedout = 0
    last_nobid = 0
    last_bid = 0
    timer(0, record_qps)

end

function _M.increment_total()
    total_request = total_request+1
end

function _M.increment_invalid()
    total_invalid = total_invalid+1
end

function _M.increment_valid()
    total_valid = total_valid+1
end

function _M.get_valid()
    return total_valid
end

function _M.increment_timedout()
    timedout_request = timedout_request+1
end

function _M.increment_nobid()
    nobid = nobid + 1
end

function _M.increment_bid()
    bid = bid + 1
end
return _M
