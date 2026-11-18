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

local function index_html()
    return [[<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mini Astra</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
         background: #0f1115; color: #e6e8ee; }
  header { padding: 18px 24px; border-bottom: 1px solid #232733;
           display: flex; align-items: baseline; gap: 12px; }
  header h1 { margin: 0; font-size: 19px; font-weight: 600; }
  header .ver { color: #8b93a7; font-size: 13px; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: #3ddc84;
         display: inline-block; margin-right: 6px; }
  main { padding: 24px; display: grid; gap: 18px; max-width: 980px; }
  .card { background: #161a22; border: 1px solid #232733; border-radius: 10px; padding: 16px 18px; }
  .card h2 { margin: 0 0 12px; font-size: 13px; text-transform: uppercase;
             letter-spacing: .08em; color: #8b93a7; font-weight: 600; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #232733; font-size: 14px; }
  th { color: #8b93a7; font-weight: 500; font-size: 12px; text-transform: uppercase; letter-spacing: .05em; }
  tr:last-child td { border-bottom: 0; }
  code { background: #0b0d12; padding: 2px 6px; border-radius: 5px; font-size: 13px; }
  a { color: #6aa8ff; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .kv { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #1c2029; }
  .kv:last-child { border-bottom: 0; }
  .kv span:first-child { color: #8b93a7; }
  .err { color: #ff6b6b; }
  footer { padding: 0 24px 24px; color: #5d6577; font-size: 12px; }
</style>
</head>
<body>
<header>
  <h1>Mini Astra</h1>
  <span class="ver" id="ver">cargando…</span>
</header>
<main>
  <div class="card">
    <h2>Estado</h2>
    <div class="kv"><span>Servicio</span><span id="svc">—</span></div>
    <div class="kv"><span>API</span><span id="api">—</span></div>
    <div class="kv"><span>Motor</span><span id="engine">—</span></div>
    <div class="kv"><span>Actualizado</span><span id="ts">—</span></div>
  </div>
  <div class="card">
    <h2>Streams</h2>
    <table>
      <thead><tr><th>ID</th><th>Tipo</th><th>Estado</th><th>Endpoint</th></tr></thead>
      <tbody id="rows"><tr><td colspan="4">cargando…</td></tr></tbody>
    </table>
  </div>
  <div class="card">
    <h2>Endpoints</h2>
    <div class="kv"><span>Salud</span><span><a href="/healthz">/healthz</a></span></div>
    <div class="kv"><span>Preparado</span><span><a href="/readyz">/readyz</a></span></div>
    <div class="kv"><span>Estado</span><span><a href="/api/v1/status">/api/v1/status</a></span></div>
    <div class="kv"><span>Streams</span><span><a href="/api/v1/streams">/api/v1/streams</a></span></div>
  </div>
</main>
<footer>Mini Astra · capa de control propia sobre Astra 4.4.187 · no es la interfaz de Cesbo 5.65</footer>
<script>
function el(id) { return document.getElementById(id); }
async function refresh() {
  try {
    const r = await fetch('/api/v1/status', { cache: 'no-store' });
    const d = await r.json();
    el('ver').textContent = 'v' + d.version;
    el('svc').innerHTML = '<span class="dot"></span>' + d.status;
    el('api').textContent = d.api;
    el('engine').textContent = d.name;
    el('ts').textContent = new Date().toLocaleTimeString();
    const rows = (d.streams || []).map(s =>
      '<tr><td><code>' + s.id + '</code></td><td>' + s.type + '</td><td>' +
      s.status + '</td><td><code>' + s.endpoint + '</code></td></tr>').join('');
    el('rows').innerHTML = rows || '<tr><td colspan="4">sin streams</td></tr>';
  } catch (e) {
    el('ver').textContent = 'sin conexión';
    el('rows').innerHTML = '<tr><td colspan="4" class="err">' + e + '</td></tr>';
  }
}
refresh();
setInterval(refresh, 3000);
</script>
</body>
</html>
]]
end

local function on_index(server, client, request)
    if not request then return end
    response(server, client, 200, "text/html; charset=utf-8", index_html())
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
        { "/", on_index },
        { "/index.html", on_index },
        { "/health", on_health },
        { "/healthz", on_health },
        { "/readyz", on_ready },
        { "/api/v1/status", on_status },
        { "/api/v1/streams", on_streams },
        { "/*", on_not_found },
    },
})

log.info("mini-astra listening on " .. bind_addr .. ":" .. bind_port)
