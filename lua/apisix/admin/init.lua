local core = require("apisix.core")
local route = require("resty.radixtree")
local plugin = require("apisix.plugin")
local get_method = ngx.req.get_method
local str_lower = string.lower
local require = require
local ngx = ngx
local reload_event = "/apisix/admin/plugins/reload"
local events


local resources = {
    routes    = require("apisix.admin.routes"),
    services  = require("apisix.admin.services"),
    upstreams = require("apisix.admin.upstreams"),
    consumers = require("apisix.admin.consumers"),
    schema    = require("apisix.admin.schema"),
    ssl       = require("apisix.admin.ssl"),
    plugins   = require("apisix.admin.plugins"),
}


local _M = {version = 0.3}
local router


local function run()
    local uri_segs = core.utils.split_uri(ngx.var.uri)
    core.log.info("uri: ", core.json.delay_encode(uri_segs))

    -- /apisix/admin/schema/route
    local seg_res, seg_id = uri_segs[4], uri_segs[5]
    local seg_sub_path = core.table.concat(uri_segs, "/", 6)
    if seg_res == "schema" and seg_id == "plugins" then
        -- /apisix/admin/schema/plugins/limit-count
        seg_res, seg_id = uri_segs[5], uri_segs[6]
        seg_sub_path = core.table.concat(uri_segs, "/", 7)
    end

    local resource = resources[seg_res]
    if not resource then
        core.response.exit(404)
    end

    local method = str_lower(get_method())
    if not resource[method] then
        core.response.exit(404)
    end

    ngx.req.read_body()
    local req_body = ngx.req.get_body_data()

    if req_body then
        local data, err = core.json.decode(req_body)
        if not data then
            core.log.error("invalid request body: ", req_body, " err: ", err)
            core.response.exit(400, {error_msg = "invalid request body",
                                     req_body = req_body})
        end

        req_body = data
    end

    local code, data = resource[method](seg_id, req_body, seg_sub_path)
    if code then
        core.response.exit(code, data)
    end
end


local function get_plugins_list()
    local plugins = resources.plugins.get_plugins_list()
    core.response.exit(200, plugins)
end


local function post_reload_plugins()
    local success, err = events.post(reload_event, get_method(), ngx.time())
    if not success then
        core.response.exit(500, err)
    end

    core.response.exit(200, success)
end


local function reload_plugins(data, event, source, pid)
    core.log.info("start to hot reload plugins")
    plugin.load()
end


local uri_route = {
    {
        path = [[/apisix/admin/*]],
        handler = run,
        method = {"GET", "PUT", "POST", "DELETE", "PATCH"},
    },
    {
        path = [[/apisix/admin/plugins/list]],
        handler = get_plugins_list,
        method = {"GET", "PUT", "POST", "DELETE"},
    },
    {
        path = reload_event,
        handler = post_reload_plugins,
        method = {"PUT"},
    },
}


function _M.init_worker()
    local local_conf = core.config.local_conf()
    if not local_conf.apisix or not local_conf.apisix.enable_admin then
        return
    end

    router = route.new(uri_route)
    events = require("resty.worker.events")

    events.register(reload_plugins, reload_event, "PUT")
end


function _M.get()
    return router
end


return _M
