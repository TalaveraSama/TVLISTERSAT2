-- Mini Astra operational configuration.
-- Compatible with the embedded Lua API in Astra 4.4.187.
-- This is an independent control/status layer, not the Cesbo 5.x API.
--
-- IMPORTANT: in this API the route callback is invoked twice per connection:
--   * with a request table  -> serve the response
--   * with request == nil   -> the connection was closed (do NOT send anything)
-- Calling server:send() with request == nil writes to an already closed socket.

local bind_addr = os.getenv("MINI_ASTRA_BIND") or "127.0.0.1"
local bind_port = tonumber(os.getenv("MINI_ASTRA_PORT") or "8000")
local config_path = os.getenv("MINI_ASTRA_STATE") or "/var/lib/mini-astra/streams.json"

local streams = {
    {
        id = "control",
        type = "http",
        status = "running",
        endpoint = bind_addr .. ":" .. bind_port,
    },
}

local function json_escape(value)
    value = tostring(value)
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\r", "\\r")
    value = value:gsub("\n", "\\n")
    return value
end

local function json_string(value)
    return '"' .. json_escape(value) .. '"'
end

local function json_stream(stream)
    return string.format(
        '{"id":%s,"type":%s,"status":%s,"endpoint":%s}',
        json_string(stream.id),
        json_string(stream.type),
        json_string(stream.status),
        json_string(stream.endpoint)
    )
end

local function streams_json()
    local result = {}
    for _, stream in ipairs(streams) do
        result[#result + 1] = json_stream(stream)
    end
    return "[" .. table.concat(result, ",") .. "]"
end

local function status_json()
    return string.format(
        '{"name":"mini-astra","version":%s,"status":"ok","api":"v1","streams":%s}',
        json_string(astra.version),
        streams_json()
    )
end

local function response(server, client, code, content_type, content)
    server:send(client, {
        code = code,
        headers = {
            "Content-Type: " .. content_type,
            "Cache-Control: no-store",
            "Connection: close",
        },
        content = content,
    })
end

-- Every handler must ignore the close notification (request == nil).
local function on_status(server, client, request)
    if not request then return end
    response(server, client, 200, "application/json", status_json())
end

local function on_streams(server, client, request)
    if not request then return end
    response(server, client, 200, "application/json", streams_json())
end

local function on_health(server, client, request)
    if not request then return end
    response(server, client, 200, "text/plain; charset=utf-8", "ok\n")
end

local function on_ready(server, client, request)
    if not request then return end
    response(server, client, 200, "application/json", '{"status":"ready"}')
end

local function on_not_found(server, client, request)
    if not request then return end
    response(server, client, 404, "application/json",
        '{"error":"not found","hint":"/health /api/v1/status /api/v1/streams"}')
end

http_server({
    addr = bind_addr,
    port = bind_port,
    route = {
        { "/health", on_health },
        { "/healthz", on_health },
        { "/readyz", on_ready },
        { "/api/v1/status", on_status },
        { "/api/v1/streams", on_streams },
        { "/*", on_not_found },
    },
})

log.info("mini-astra listening on " .. bind_addr .. ":" .. bind_port)
