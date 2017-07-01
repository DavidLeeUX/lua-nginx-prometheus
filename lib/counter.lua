local cjson = require('cjson')
local resty_consul = require('resty.consul')
local json_decode = cjson.decode
local ngx = ngx
local ngx_log = ngx.log
local ngx_err = ngx.ERR
local timer_at = ngx.timer.at
local ngx_sleep = ngx.sleep
local delay = 300  -- 10s

local _M = {}

function _M.init()
    uris = ngx.shared.uri_by_host
    global_set = ngx.shared.global_set
    global_set:set("initted", false)
    global_set:set("looped", false)
    prometheus = require("prometheus").init("prometheus_metrics") 
    metric_get_consul = prometheus:counter("nginx_consul_get_total", "Number of query uri from consul", {"status"})
    metric_latency = prometheus:histogram("nginx_http_request_duration_seconds", "HTTP request latency status", {"host", "status", "scheme", "method", "endpoint"})
end

function _M.sync_consul()
    local consul = resty_consul:new({ host = consul_host, port = consul_port })
    local res, err = consul:get_decoded("/kv/domain/Value")
    if res == nil then
        ngx_log(ngx_err, err)
        metric_get_consul:inc(1, {"failed"})
        return false
    else
        metric_get_consul:inc(1, {"succ"})
    end
    local hosts, err = json_decode(res[1]['Value'])
    if hosts == nil then
        ngx_log(ngx_err, err)
        return false
    end
    for i=1, #hosts do
        local host = hosts[i]
        local get_uri_by_host, err = consul:get_decoded("/kv/domain/" .. host .. "/routers")
        if get_uri_by_host == nil then
            ngx_log(ngx_err, err)
            return false
        end
        uris:set(host, get_uri_by_host[1]['Value'])
    end
    return true
    -- ngx_log(ngx_err, table.concat(uris:get_keys()))
end

function _M.first_init()
    local initted = global_set:get("initted")
    if initted == false then
        global_set:set("initted", true)
        local handler
        function handler(premature)
            if not _M.sync_consul() then
                ngx_log(ngx_err, "Call sync_consul failed!")
                return
            end
        end
        local ok, err = timer_at(0, handler)
        if not ok then
            ngx_log(ngx_err, "Call timer_at failed: ", err)
            return
        end
        ngx_log(ngx_err, "First initialize load consul data!")
    end
end

function _M.loop_load()
    local loop_handler
    function loop_handler(premature)
        ngx_log(ngx_err, "Timer prematurely expired: ", premature)
        ngx_log(ngx_err, "Worker exiting: ", ngx.worker.exiting())
        if not premature then
            if _M.sync_consul() then
                local ok, err = timer_at(delay, loop_handler)
                if not ok then
                    ngx_log(ngx_err, "Call timer_at failed: ", err)
                    return
                end
                ngx_log(ngx_err, "Looping in timer!")
            end
        else
            global_set:set("looped", false)
        end
    end
    if global_set:get("looped") == false then
        if 0 == ngx.worker.id() then
            local ok, err = timer_at(delay, loop_handler)
            if not ok then
                ngx_log(ngx_err, "Call timer_at failed: ", err)
                return
            end
            global_set:set("looped", true)
            ngx_log(ngx_err, "Starting loop load consul data!")
        end
    end
end

function _M.log()
    _M.first_init()
    _M.loop_load()
    local request_host = ngx.var.host
    local request_uri = ngx.unescape_uri(ngx.var.uri)
    local request_status = ngx.var.status
    local request_scheme = ngx.var.scheme
    local request_method = ngx.var.request_method
    local get_all_hosts = uris:get_keys()
    if get_all_hosts == nil then
        ngx_log(ngx_err, "Dict is empty！")
        return
    end
    for j=1, #get_all_hosts do
        if get_all_hosts[j] == request_host then
            local def_uri = json_decode(uris:get(get_all_hosts[j]))
            if def_uri == nil then
                ngx_log(ngx_err, "Decode uris err!")
                return
            end
            for k=1, #def_uri do
                if ngx.re.find(request_uri, def_uri[k], 'isjo') ~= nil then
                    metric_latency:observe(ngx.now() - ngx.req.start_time(), {request_host, request_status, request_scheme, request_method, def_uri[k]})
                end
            end
        end
    end
end

return _M