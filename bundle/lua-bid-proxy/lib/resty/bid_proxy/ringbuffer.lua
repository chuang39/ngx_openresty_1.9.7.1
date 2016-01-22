local log = ngx.log
local ERR = ngx.ERR
local NOTICE = ngx.NOTICE

local setmetatable = setmetatable
local ngx_null = ngx.null

local ngx_sem  = require "ngx.semaphore"

local ok, new_tab = pcall(require, "table.new")
if not ok then
    log(NOTICE, "table.new was not found. Using old api.")
    new_tab = function (narr, nrec) return {} end
end


local _M = { _VERSION = "0.01" }
local mt = { __index = _M }

function _M.new(self, max_buffering, qid)
    local list = {
        head = nil,
        pending = nil,
        complete = nil,
        sem_write_event = ngx_sem:new(0),
        qid=qid,
        next_requestid=0
    }
    -- TODO: change {} to table.new?
    for i=1, max_buffering do
        list.head = {next=list.head, semaphore=ngx_sem:new(0), message=nil, response=nil, requestid=nil, nodeid=i}
    end
    return setmetatable(list, mt)
end

function _M.pop(self)
    local head = self.head
    local complete = self.complete

    if head == nil then
        if complete ~= nil then
            head = complete
            self.complete = nil
            log(NOTICE, "Ringbuffer : swapped buffers qid=", self.qid)
        else
            log(NOTICE, "Ringbuffer: head and complete are nil!! qid=", self.qid)
            return nil, "Ringbuffer crashed"
        end
    end

    if head.semaphore:count() ~= 0 then
        log(ERR, "!!!!!! Ringbuffer: semaphore count is not 0, count=", head.semaphore:count(), "  nodeid=", head.nodeid)
        return nil, "Ringbuffer return wrong semaphore"
    end

    local res = head
    self.head = head.next

    res.next = self.pending
    self.pending = res

    -- assign request id
    res.requestid = self.next_requestid
    if self.next_requestid < 100000 then
        self.next_requestid = res.requestid + 1
    else
        self.next_requestid = 0
    end

    return res, nil
end

function _M.get_pending(self)
    return self.pending
end

function _M.get_complete(self)
    return self.complete
end

function _M.set_complete(self, new_complete)
    new_complete.next = self.complete
    self.complete = new_complete
end

function _M.clear_pending(self)
    self.pending = nil
end

return _M
