-- Mini Astra operational configuration + stream engine.
-- Compatible with the embedded Lua API in Astra 4.4.187.
--
-- Address model follows the Cesbo 5.x convention:
--   input : dvb://11262-h-30000#pnr=1937&adapter=0&type=S2
--           udp://239.2.2.10:2000        rtp://239.2.2.10:2000
--           file:///ruta/video.ts?loop=1
--   output: udp://enp1s0@230.2.2.10:2000
--           rtp://enp1s0@230.2.2.10:2000
--
-- IMPORTANT: the route callback is invoked twice per connection:
--   * request table -> serve the response
--   * request == nil -> connection closed, never send anything

local bind_addr = os.getenv("MINI_ASTRA_BIND") or "127.0.0.1"
local bind_port = tonumber(os.getenv("MINI_ASTRA_PORT") or "8000")
local state_path = os.getenv("MINI_ASTRA_STATE") or "/var/lib/mini-astra/streams.json"
local dvb_enabled = (os.getenv("MINI_ASTRA_DVB") or "1") ~= "0"

--------------------------------------------------------------------------
-- utilidades
--------------------------------------------------------------------------

local ifaddr_list = nil
if utils and utils.ifaddrs then
    local ok, res = pcall(utils.ifaddrs)
    if ok and type(res) == "table" then ifaddr_list = res end
end

local function resolve_localaddr(name)
    if not name or name == "" then return nil end
    if name:match("^%d+%.%d+%.%d+%.%d+$") then return name end
    local entry = ifaddr_list and ifaddr_list[name]
    if entry and entry.ipv4 and entry.ipv4[1] then return entry.ipv4[1] end
    return nil
end

local function json_escape(value)
    value = tostring(value)
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\r", "\\r")
    value = value:gsub("\n", "\\n")
    return value
end

local function js(value)
    return '"' .. json_escape(value) .. '"'
end

local function split_fragment(addr)
    local base, fragment = addr:match("^([^#]*)#?(.*)$")
    local params = {}
    for pair in fragment:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=?(.*)$")
        if k then params[k] = v end
    end
    return base, params
end

local function parse_hostport(value)
    local host, port = value:match("^([^:/]+):(%d+)$")
    if not host then return nil end
    return host, tonumber(port)
end

--------------------------------------------------------------------------
-- estado de streams
--------------------------------------------------------------------------

local streams = {}

local function find_stream(id)
    for index, stream in ipairs(streams) do
        if stream.id == id then return stream, index end
    end
    return nil, nil
end

local function load_state()
    if not (json and json.load) then return end
    local data = json.load(state_path)
    if type(data) == "table" then
        for _, stream in ipairs(data) do
            if type(stream) == "table" and stream.id then
                streams[#streams + 1] = stream
            end
        end
    end
end

local function save_state()
    if json and json.save then
        json.save(state_path, streams)
    end
end

local runtime = {}

--------------------------------------------------------------------------
-- construccion del pipeline
--------------------------------------------------------------------------

local function parse_input(addr)
    local scheme, rest = addr:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then return nil, "dirección sin esquema (usa udp://, rtp://, dvb:// o file://)" end
    scheme = scheme:lower()

    local base, params = split_fragment(rest)

    if scheme == "udp" or scheme == "rtp" then
        local host, port = parse_hostport(base)
        if not host then return nil, "formato esperado udp://host:puerto" end
        return { kind = scheme, host = host, port = port, params = params }

    elseif scheme == "file" then
        local path = base
        if path:sub(1, 1) ~= "/" then
            path = "/" .. path:gsub("^/+", "")
        end
        return { kind = "file", path = path, params = params }

    elseif scheme == "dvb" then
        if not dvb_enabled then
            return nil, "DVB deshabilitado en este proceso (MINI_ASTRA_DVB=0)"
        end
        local freq, pol, rate = base:match("^(%d+)%-(%a+)%-(%d+)$")
        if not freq then
            return nil, "formato esperado dvb://frecuencia-polarizacion-simbolrate#pnr=N"
        end
        local pol_code = pol:lower()
        if pol_code ~= "h" and pol_code ~= "v" and pol_code ~= "l" and pol_code ~= "r" then
            return nil, "polarización inválida (usa h o v)"
        end
        local pnr = tonumber(params.pnr)
        if params.pnr and (not pnr or pnr < 1) then
            return nil, "pnr inválido"
        end
        local adapter = tonumber(params.adapter or "0")
        if not adapter or adapter < 0 then return nil, "adapter inválido" end
        return {
            kind = "dvb", frequency = tonumber(freq), polarization = pol_code,
            symbolrate = tonumber(rate), pnr = pnr, adapter = adapter,
            dvb_type = params.type or "S2", params = params,
        }
    end

    return nil, "esquema no soportado: " .. scheme
end

local function parse_output(addr)
    local scheme, rest = addr:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then return nil, "dirección sin esquema" end
    scheme = scheme:lower()
    if scheme ~= "udp" and scheme ~= "rtp" then
        return nil, "salida soportada: udp:// o rtp://"
    end

    local base, params = split_fragment(rest)

    local localpart, hostport = base:match("^([^@]+)@(.+)$")
    if not localpart then hostport = base end

    local host, port = parse_hostport(hostport)
    if not host then return nil, "formato esperado udp://[interfaz@]grupo:puerto" end

    local localaddr = nil
    if localpart then
        localaddr = resolve_localaddr(localpart)
        if not localaddr then
            return nil, "interfaz desconocida: " .. localpart
        end
    end

    return {
        kind = scheme, host = host, port = port, localaddr = localaddr,
        ttl = tonumber(params.ttl) , params = params,
    }
end

local function stop_stream(id)
    local rt = runtime[id]
    if not rt then return end
    runtime[id] = nil
    rt.outputs = nil
    rt.channel = nil
    rt.input = nil
    collectgarbage()
end

local function start_stream(stream)
    stop_stream(stream.id)

    if not stream.enabled then return true end

    local first_input = stream.inputs and stream.inputs[1]
    if not first_input or first_input == "" then
        return false, "la lista de entrada está vacía"
    end

    local conf, err = parse_input(first_input)
    if not conf then return false, err end

    local rt = { outputs = {} }

    local ok, input = pcall(function()
        if conf.kind == "udp" or conf.kind == "rtp" then
            return udp_input({
                addr = conf.host, port = conf.port,
                rtp = (conf.kind == "rtp"),
                socket_size = 4 * 1024 * 1024,
            })
        elseif conf.kind == "file" then
            return file_input({
                filename = conf.path,
                loop = (conf.params.loop == "1" or conf.params.loop == "true"),
            })
        elseif conf.kind == "dvb" then
            return dvb_input({
                adapter = conf.adapter,
                type = conf.dvb_type,
                frequency = conf.frequency,
                symbolrate = conf.symbolrate,
                polarization = conf.polarization,
                timeout = 3,
            })
        end
    end)

    if not ok or not input then
        return false, "no se pudo abrir la entrada: " .. tostring(input)
    end
    rt.input = input

    local upstream = input:stream()

    if conf.kind == "dvb" and conf.pnr then
        local ch_ok, channel_mod = pcall(function()
            return channel({ upstream = upstream, pnr = conf.pnr, name = stream.name })
        end)
        if ch_ok and channel_mod then
            rt.channel = channel_mod
            upstream = channel_mod:stream()
        end
    end

    for index, out_addr in ipairs(stream.outputs or {}) do
        if out_addr ~= "" then
            local out, out_err = parse_output(out_addr)
            if not out then
                stop_stream(stream.id)
                return false, "salida #" .. index .. ": " .. tostring(out_err)
            end
            local out_ok, out_mod = pcall(function()
                return udp_output({
                    upstream = upstream,
                    addr = out.host,
                    port = out.port,
                    localaddr = out.localaddr,
                    ttl = out.ttl or 32,
                    rtp = (out.kind == "rtp"),
                })
            end)
            if not out_ok or not out_mod then
                stop_stream(stream.id)
                return false, "no se pudo crear la salida #" .. index .. ": " .. tostring(out_mod)
            end
            rt.outputs[index] = out_mod
        end
    end

    rt.running = true
    runtime[stream.id] = rt
    return true
end

--------------------------------------------------------------------------
-- adaptadores DVB y escaneo de transponder
--------------------------------------------------------------------------

local scan = { status = "idle", services = {}, started = 0, config = nil }
local scan_mods = {}

local function adapters_list()
    if not dvbls then return {} end
    local ok, res = pcall(dvbls)
    if ok and type(res) == "table" then return res end
    return {}
end

local function adapter_exists(index)
    for _, item in ipairs(adapters_list()) do
        if tonumber(item.adapter) == index then return true end
    end
    return false
end

local function dvb_address(cfg, pnr)
    return string.format("dvb://%d-%s-%d#pnr=%d&adapter=%d&type=%s",
        cfg.frequency, cfg.polarization, cfg.symbolrate, pnr, cfg.adapter, cfg.type)
end

local function scan_add(pnr)
    for _, service in ipairs(scan.services) do
        if service.pnr == pnr then return service end
    end
    local entry = { pnr = pnr, name = "", provider = "" }
    scan.services[#scan.services + 1] = entry
    return entry
end

local function scan_on_data(data)
    if type(data) ~= "table" or not scan.config then return end

    if data.psi == "pat" and data.programs then
        for _, program in ipairs(data.programs) do
            local pnr = tonumber(program.pnr)
            if pnr and pnr > 0 then scan_add(pnr) end
        end

    elseif data.psi == "sdt" and data.services then
        for _, service in ipairs(data.services) do
            local pnr = tonumber(service.sid)
            if pnr and pnr > 0 then
                local entry = scan_add(pnr)
                for _, descriptor in ipairs(service.descriptors or {}) do
                    if descriptor.type_name == "service" then
                        entry.name = descriptor.service_name or entry.name
                        entry.provider = descriptor.service_provider or entry.provider
                    end
                end
            end
        end

    elseif data.analyze and data.total then
        scan.on_air = data.on_air
        scan.bitrate = data.total.bitrate
    end
end

local function scan_stop()
    scan_mods.analyze = nil
    scan_mods.input = nil
    collectgarbage()
end

local function scan_start(opts)
    local adapter = tonumber(opts.adapter or 0)
    if not adapter_exists(adapter) then
        return false, "adaptador " .. tostring(adapter) .. " no detectado (usa dvbls)"
    end

    local frequency = tonumber(opts.frequency)
    local symbolrate = tonumber(opts.symbolrate)
    if not frequency or frequency <= 0 then return false, "frecuencia inválida" end
    if not symbolrate or symbolrate <= 0 then return false, "symbolrate inválido" end

    local polarization = (opts.polarization or "h"):lower()
    if polarization ~= "h" and polarization ~= "v" then
        return false, "polarización debe ser h o v"
    end

    local dvb_type = (opts.type or "S2"):upper()

    if scan.status == "running" then return false, "ya hay un escaneo en curso" end

    scan_stop()

    scan.services = {}
    scan.on_air = nil
    scan.bitrate = nil
    scan.config = {
        adapter = adapter, frequency = frequency, symbolrate = symbolrate,
        polarization = polarization, type = dvb_type,
        diseqc = tonumber(opts.diseqc) or 0,
        timeout = tonumber(opts.timeout) or 12,
    }

    local ok, err = pcall(function()
        scan_mods.input = dvb_input({
            adapter = adapter,
            type = dvb_type,
            frequency = frequency,
            symbolrate = symbolrate,
            polarization = polarization,
            diseqc = tonumber(opts.diseqc) or 0,
            timeout = 3,
        })
        if not scan_mods.input then error("no se pudo abrir el adaptador") end
        scan_mods.analyze = analyze({
            upstream = scan_mods.input:stream(),
            name = "scan",
            callback = scan_on_data,
        })
    end)

    if not ok then
        scan_stop()
        scan.status = "error"
        scan.error = tostring(err)
        return false, scan.error
    end

    scan.status = "running"
    scan.error = nil
    scan.started = os.time()

    scan_mods.timer = timer({
        interval = 1,
        callback = function(t)
            if scan.status ~= "running" then
                t:close()
                return
            end
            if os.time() - scan.started >= scan.config.timeout then
                scan.status = "done"
                scan_mods.timer = nil
                t:close()
                scan_stop()
            end
        end,
    })

    return true
end

local function adapters_json()
    local parts = {}
    for _, item in ipairs(adapters_list()) do
        parts[#parts + 1] = table.concat({
            '{"adapter":', tostring(tonumber(item.adapter) or 0),
            ',"device":', tostring(tonumber(item.device) or 0),
            ',"type":', js(item.type or ""),
            ',"frontend":', js(item.frontend or ""),
            ',"busy":', tostring(item.busy == true),
            ',"error":', js(item.error or ""),
            '}',
        })
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function scan_json()
    local parts = {}
    for index, service in ipairs(scan.services) do
        local address = ""
        if scan.config then address = dvb_address(scan.config, service.pnr) end
        parts[#parts + 1] = table.concat({
            '{"pnr":', tostring(service.pnr),
            ',"name":', js(service.name or ""),
            ',"provider":', js(service.provider or ""),
            ',"address":', js(address),
            '}',
        })
    end
    local elapsed = 0
    if scan.started > 0 then elapsed = os.time() - scan.started end
    return table.concat({
        '{"status":', js(scan.status),
        ',"elapsed":', tostring(elapsed),
        ',"on_air":', tostring(scan.on_air == true),
        ',"bitrate":', tostring(tonumber(scan.bitrate) or 0),
        ',"error":', js(scan.error or ""),
        ',"services":[', table.concat(parts, ","), ']}',
    })
end

--------------------------------------------------------------------------
-- serializacion
--------------------------------------------------------------------------

local function addr_list_json(list)
    local parts = {}
    for _, value in ipairs(list or {}) do
        parts[#parts + 1] = js(value)
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function stream_json(stream)
    return table.concat({
        '{"id":', js(stream.id or ""),
        ',"name":', js(stream.name or ""),
        ',"enabled":', tostring(stream.enabled == true),
        ',"mps":', tostring(stream.mps == true),
        ',"description":', js(stream.description or ""),
        ',"inputs":', addr_list_json(stream.inputs),
        ',"outputs":', addr_list_json(stream.outputs),
        ',"running":', tostring(runtime[stream.id] ~= nil),
        ',"error":', js(stream.last_error or ""),
        '}',
    })
end

local function streams_json()
    local parts = {}
    for _, stream in ipairs(streams) do
        parts[#parts + 1] = stream_json(stream)
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function status_json()
    return table.concat({
        '{"name":"mini-astra","version":', js(astra.version),
        ',"status":"ok","api":"v1","dvb":', tostring(dvb_enabled),
        ',"streams":', streams_json(), '}',
    })
end

--------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------

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

local function reply_json(server, client, code, payload)
    response(server, client, code, "application/json", payload)
end

local function on_status(server, client, request)
    if not request then return end
    reply_json(server, client, 200, status_json())
end

local function on_streams(server, client, request)
    if not request then return end
    reply_json(server, client, 200, streams_json())
end

local function on_health(server, client, request)
    if not request then return end
    response(server, client, 200, "text/plain; charset=utf-8", "ok\n")
end

local function on_ready(server, client, request)
    if not request then return end
    reply_json(server, client, 200, '{"status":"ready"}')
end

local function apply_action(payload)
    local action = payload and payload.action or ""
    local incoming = payload and payload.stream or nil

    if action == "delete" then
        local stream, index = find_stream(incoming and incoming.id)
        if not stream then return false, "stream no encontrado" end
        stop_stream(stream.id)
        table.remove(streams, index)
        save_state()
        return true, "eliminado"
    end

    if action == "start" or action == "stop" then
        local stream = find_stream(incoming and incoming.id)
        if not stream then return false, "stream no encontrado" end
        if action == "stop" then
            stop_stream(stream.id)
            return true, "detenido"
        end
        local ok, err = start_stream(stream)
        stream.last_error = ok and nil or err
        return ok, err or "iniciado"
    end

    if action == "verify" then
        local problems = {}
        if not incoming then return false, "sin datos" end
        for _, addr in ipairs(incoming.inputs or {}) do
            local conf, err = parse_input(addr)
            if not conf then problems[#problems + 1] = "entrada: " .. tostring(err) end
        end
        for _, addr in ipairs(incoming.outputs or {}) do
            local conf, err = parse_output(addr)
            if not conf then problems[#problems + 1] = "salida: " .. tostring(err) end
        end
        if #problems == 0 then return true, "configuración válida" end
        return false, table.concat(problems, "; ")
    end

    -- save / clone
    if not incoming then return false, "falta el objeto stream" end
    local id = (incoming.id or ""):gsub("%s", "")
    if id == "" then return false, "el ID es obligatorio" end

    if action == "clone" then
        local base = find_stream(id)
        if not base then return false, "stream no encontrado" end
        local copy = {
            id = id .. "-copy" .. tostring(#streams + 1),
            name = (base.name or "") .. " copy",
            enabled = false, mps = base.mps,
            description = base.description,
            inputs = { }, outputs = { },
        }
        for _, v in ipairs(base.inputs or {}) do copy.inputs[#copy.inputs + 1] = v end
        for _, v in ipairs(base.outputs or {}) do copy.outputs[#copy.outputs + 1] = v end
        streams[#streams + 1] = copy
        save_state()
        return true, "clonado como " .. copy.id
    end

    local stream = find_stream(id)
    if not stream then
        stream = { id = id, inputs = {}, outputs = {} }
        streams[#streams + 1] = stream
    end

    stream.name = incoming.name or stream.name or id
    stream.enabled = incoming.enabled == true
    stream.mps = incoming.mps == true
    stream.description = incoming.description or ""

    stream.inputs = {}
    for _, v in ipairs(incoming.inputs or {}) do
        if type(v) == "string" and v ~= "" then stream.inputs[#stream.inputs + 1] = v end
    end
    stream.outputs = {}
    for _, v in ipairs(incoming.outputs or {}) do
        if type(v) == "string" and v ~= "" then stream.outputs[#stream.outputs + 1] = v end
    end

    if stream.enabled then
        local ok, err = start_stream(stream)
        stream.last_error = ok and nil or err
        if not ok then
            save_state()
            return false, err
        end
    else
        stop_stream(id)
        stream.last_error = nil
    end

    save_state()
    return true, "guardado"
end

local function on_api_streams(server, client, request)
    if not request then return end

    if request.method == "POST" then
        local payload = nil
        if request.content and json and json.decode then
            local ok, decoded = pcall(json.decode, request.content)
            if ok then payload = decoded end
        end
        if type(payload) ~= "table" then
            reply_json(server, client, 400, '{"ok":false,"message":"JSON inválido"}')
            return
        end
        local ok, message = apply_action(payload)
        reply_json(server, client, ok and 200 or 400,
            '{"ok":' .. tostring(ok) .. ',"message":' .. js(message) ..
            ',"streams":' .. streams_json() .. '}')
        return
    end

    reply_json(server, client, 200, streams_json())
end

--------------------------------------------------------------------------
-- interfaz
--------------------------------------------------------------------------

local function index_html()
    return [[<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mini Astra</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif;
         background: #ffffff; color: #2b2f36; }
  topbar, .topbar { display: block; }
  .topbar { border-bottom: 1px solid #dfe3e8; padding: 10px 16px;
            display: flex; gap: 18px; align-items: center; font-size: 14px; }
  .topbar a { color: #1a73e8; text-decoration: none; }
  .topbar a:hover { text-decoration: underline; }
  .topbar .search { flex: 1; max-width: 420px; color: #9aa3af; }
  .topbar .right { margin-left: auto; display: flex; gap: 16px; }
  .banner { padding: 7px 16px; font-size: 12.5px; background: #fff8e6;
            border-bottom: 1px solid #f0e0b8; color: #7a5c00; }
  main { padding: 16px; }
  .group { margin-bottom: 22px; }
  .group h3 { font-size: 12px; color: #98a1ad; font-weight: 600; margin: 0 0 8px; }
  .cards { display: flex; flex-wrap: wrap; gap: 10px; }
  .card { border: 1px solid #cfd6de; border-radius: 4px; background: #fff;
          min-width: 190px; max-width: 260px; padding: 7px 9px; cursor: pointer;
          position: relative; }
  .card:hover { border-color: #1a73e8; }
  .card .nm { font-size: 14px; margin-bottom: 2px; white-space: nowrap;
              overflow: hidden; text-overflow: ellipsis; padding-right: 22px; }
  .card .meta { font-size: 12px; color: #6b7480; }
  .card .dots { position: absolute; top: 6px; right: 8px; color: #9aa3af; }
  .card.on { border-color: #34a853; }
  .card.off { border-color: #d0d5dc; background: #fafbfc; }
  .card.err { border-color: #ea4335; }
  .overlay { position: fixed; inset: 0; background: rgba(20,24,30,.35);
             display: none; align-items: center; justify-content: center; z-index: 50; }
  .overlay.open { display: flex; }
  .editor { background: #fff; width: 720px; max-width: 96vw; max-height: 92vh;
            overflow: auto; border-radius: 6px; box-shadow: 0 12px 40px rgba(0,0,0,.25); }
  .tabs { display: flex; gap: 22px; padding: 14px 24px 0; border-bottom: 1px solid #e5e9ee; }
  .tabs span { padding-bottom: 10px; color: #4b5563; font-size: 13.5px; cursor: default; }
  .tabs span.active { color: #1a73e8; border-bottom: 2px solid #1a73e8; }
  .body { padding: 18px 24px 8px; }
  label.row { display: flex; align-items: center; gap: 8px; margin-bottom: 14px; font-size: 13px; }
  .field { margin-bottom: 14px; }
  .field > span { display: block; font-size: 11px; letter-spacing: .06em;
                  text-transform: uppercase; color: #9aa3af; margin-bottom: 5px; }
  input[type=text], textarea { width: 100%; border: 1px solid #cfd6de; border-radius: 3px;
                  padding: 7px 9px; font: inherit; color: inherit; background: #fff; }
  textarea { resize: vertical; min-height: 62px; }
  input[type=text]:focus, textarea:focus { outline: none; border-color: #1a73e8;
                  box-shadow: 0 0 0 2px rgba(26,115,232,.15); }
  .listhead { display: flex; justify-content: space-between; align-items: center;
              margin: 20px 0 8px; }
  .listhead h4 { margin: 0; font-size: 11px; letter-spacing: .06em;
                 text-transform: uppercase; color: #9aa3af; }
  .listhead a { font-size: 11px; letter-spacing: .06em; text-transform: uppercase;
                color: #1a73e8; cursor: pointer; }
  .addr { display: flex; gap: 8px; margin-bottom: 8px; align-items: center; }
  .addr input { flex: 1; font-family: ui-monospace, Consolas, monospace; font-size: 13px; }
  .addr .rm { border: 0; background: none; color: #ea4335; cursor: pointer; font-size: 16px; }
  .hint { font-size: 12px; color: #8b93a0; margin: 4px 0 0; }
  .footer { display: flex; justify-content: center; gap: 34px; padding: 18px 24px 22px; }
  .footer button { border: 0; background: none; color: #1a73e8; font-size: 12px;
                   letter-spacing: .07em; text-transform: uppercase; cursor: pointer; }
  .footer button.danger { color: #ea4335; }
  .footer button:disabled { color: #b9c0c9; cursor: default; }
  .msg { margin: 0 24px 14px; font-size: 13px; padding: 9px 11px; border-radius: 4px; display: none; }
  .msg.ok { display: block; background: #e8f5e9; color: #1e7b34; }
  .msg.bad { display: block; background: #fdecea; color: #b3261e; }
  .empty { color: #98a1ad; font-size: 13px; padding: 18px 0; }
</style>
</head>
<body>
<div class="topbar">
  <a href="/">Dashboard</a>
  <a href="/api/v1/streams">Sessions</a>
  <a href="/api/v1/status">Settings</a>
  <a href="/api/v1/status">Log</a>
  <span class="search">Click or press 'S' to search…</span>
  <span class="right">
    <a href="#" onclick="openAdapter();return false;">New Adapter</a>
    <a href="#" onclick="newStream();return false;">New Stream</a>
    <a href="/api/v1/status">View</a>
  </span>
</div>
<div class="banner" id="banner">Mini Astra · capa de control sobre Astra 4.4.187 · no es la interfaz de Cesbo 5.65</div>
<main>
  <div id="groups"></div>
</main>

<div class="overlay" id="overlay">
  <div class="editor">
    <div class="tabs">
      <span class="active">General</span><span>Groups</span><span>Service</span>
      <span>Remap</span><span>Backup</span><span>EPG</span><span>Advanced</span>
    </div>
    <div class="body">
      <label class="row"><input type="checkbox" id="f_enable"> Enable</label>
      <div class="field"><span>Name</span><input type="text" id="f_name" placeholder="America TV HD"></div>
      <div class="field"><span>ID</span><input type="text" id="f_id" placeholder="a0jt"></div>
      <label class="row"><input type="checkbox" id="f_mps"> Create Multi Program Stream</label>
      <div class="field"><span>Description</span><textarea id="f_desc"></textarea></div>

      <div class="listhead"><h4>Input list</h4><a onclick="addAddr('inputs')">New input</a></div>
      <div id="inputs"></div>
      <p class="hint">Ejemplos: dvb://11262-h-30000#pnr=1937&amp;adapter=0&amp;type=S2 ·
         udp://239.2.2.10:2000 · rtp://239.2.2.10:2000 · file:///srv/video.ts?loop=1</p>

      <div class="listhead"><h4>Output list</h4><a onclick="addAddr('outputs')">New output</a></div>
      <div id="outputs"></div>
      <p class="hint">Ejemplo: udp://enp1s0@230.2.2.10:2000 (interfaz@grupo:puerto) ·
         rtp://enp1s0@230.2.2.10:2000</p>

      <label class="row" style="margin-top:16px"><input type="checkbox" id="f_remove"> Remove</label>
    </div>
    <div class="msg" id="msg"></div>
    <div class="footer">
      <button onclick="apply()">Apply</button>
      <button onclick="cloneStream()">Clone</button>
      <button onclick="verify()">Analyze</button>
      <button onclick="closeEditor()">Cancel</button>
    </div>
  </div>
</div>

<div class="overlay" id="adapterOverlay">
  <div class="editor">
    <div class="tabs"><span class="active">Adapter</span><span>Scan</span></div>
    <div class="body">
      <div class="field"><span>Adaptador detectado</span><select id="a_sel"></select></div>
      <div class="field"><span>Tipo</span>
        <select id="a_type">
          <option value="S2">DVB-S2</option><option value="S">DVB-S</option>
          <option value="T2">DVB-T2</option><option value="T">DVB-T</option>
          <option value="C">DVB-C</option>
        </select>
      </div>
      <div class="field"><span>Frecuencia (MHz)</span><input type="text" id="a_freq" placeholder="11262"></div>
      <div class="field"><span>Symbolrate (kSym/s)</span><input type="text" id="a_sr" placeholder="30000"></div>
      <div class="field"><span>Polarización</span>
        <select id="a_pol"><option value="h">Horizontal</option><option value="v">Vertical</option></select>
      </div>
      <p class="hint">El escaneo sintoniza el transponder, lee PAT/SDT y devuelve los canales con su PNR.</p>
      <div class="listhead"><h4>Canales encontrados</h4><span class="meta" id="scan_state">—</span></div>
      <div id="scan_rows"></div>
    </div>
    <div class="msg" id="amsg"></div>
    <div class="footer">
      <button onclick="startScan()">Scan</button>
      <button onclick="closeAdapter()">Close</button>
    </div>
  </div>
</div>

<script>
var current = null;
var list = [];
function el(id) { return document.getElementById(id); }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function(c) {
  return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }

function render() {
  var host = el('groups');
  if (!list.length) {
    host.innerHTML = '<div class="empty">No hay streams. Pulsa <b>New Stream</b> para crear uno.</div>';
    return;
  }
  var cards = list.map(function(s) {
    var cls = s.running ? 'on' : (s.error ? 'err' : 'off');
    var meta = s.running ? 'activo' : (s.error ? esc(s.error) : 'detenido');
    return '<div class="card ' + cls + '" onclick="editStream(' + JSON.stringify(s.id).replace(/"/g,'&quot;') + ')">' +
      '<div class="dots">···</div>' +
      '<div class="nm">' + esc(s.name || s.id) + '</div>' +
      '<div class="meta">' + meta + '</div>' +
      '<div class="meta">' + (s.outputs && s.outputs[0] ? esc(s.outputs[0]) : 'sin salida') + '</div>' +
      '</div>';
  }).join('');
  host.innerHTML = '<div class="group"><h3>' + new Date().toLocaleTimeString() + '</h3>' +
                   '<div class="cards">' + cards + '</div></div>';
}

function refresh() {
  fetch('/api/v1/streams', {cache:'no-store'}).then(function(r){ return r.json(); })
    .then(function(d){ list = d || []; render(); })
    .catch(function(){ el('banner').textContent = 'sin conexión con Mini Astra'; });
}

function addrRow(kind, value) {
  var wrap = document.createElement('div');
  wrap.className = 'addr';
  var input = document.createElement('input');
  input.type = 'text';
  input.value = value || '';
  input.className = 'a_' + kind;
  var rm = document.createElement('button');
  rm.className = 'rm'; rm.textContent = '×';
  rm.onclick = function(){ wrap.remove(); };
  wrap.appendChild(input); wrap.appendChild(rm);
  return wrap;
}

function addAddr(kind, value) {
  el(kind).appendChild(addrRow(kind, value));
}

function collect(kind) {
  var out = [];
  el(kind).querySelectorAll('input').forEach(function(i){ if (i.value.trim()) out.push(i.value.trim()); });
  return out;
}

function showEditor(s) {
  current = s;
  el('f_enable').checked = s.enabled !== false;
  el('f_mps').checked = s.mps === true;
  el('f_name').value = s.name || '';
  el('f_id').value = s.id || '';
  el('f_desc').value = s.description || '';
  el('f_remove').checked = false;
  el('inputs').innerHTML = '';
  el('outputs').innerHTML = '';
  (s.inputs || []).forEach(function(v){ addAddr('inputs', v); });
  (s.outputs || []).forEach(function(v){ addAddr('outputs', v); });
  if (!(s.inputs || []).length) addAddr('inputs');
  if (!(s.outputs || []).length) addAddr('outputs');
  el('msg').className = 'msg';
  el('overlay').classList.add('open');
}

function newStream() {
  showEditor({id:'st' + Date.now().toString().slice(-6), name:'', inputs:[''], outputs:[''], enabled:true});
}

function editStream(id) {
  var found = list.filter(function(s){ return s.id === id; })[0];
  if (found) showEditor(found);
}

function closeEditor() { el('overlay').classList.remove('open'); }

/* ---- adaptador y escaneo ---- */
var scanTimer = null;

function openAdapter() {
  el('adapterOverlay').classList.add('open');
  el('amsg').className = 'msg';
  el('scan_rows').innerHTML = '';
  el('scan_state').textContent = '—';
  fetch('/api/v1/adapters', {cache:'no-store'}).then(function(r){ return r.json(); })
    .then(function(d){
      var sel = el('a_sel');
      sel.innerHTML = '';
      if (!d || !d.length) {
        sel.innerHTML = '<option value="">sin adaptadores DVB detectados</option>';
        el('scan_state').textContent = 'sin hardware';
        return;
      }
      d.forEach(function(a){
        var o = document.createElement('option');
        o.value = a.adapter;
        o.textContent = 'adapter' + a.adapter + ' · ' + (a.type || '?') +
                        (a.frontend ? ' · ' + a.frontend : '') + (a.busy ? ' · ocupado' : '');
        sel.appendChild(o);
      });
    })
    .catch(function(){ el('scan_state').textContent = 'error consultando adaptadores'; });
}

function closeAdapter() {
  el('adapterOverlay').classList.remove('open');
  if (scanTimer) { clearInterval(scanTimer); scanTimer = null; }
}

function startScan() {
  var body = {
    adapter: el('a_sel').value,
    type: el('a_type').value,
    frequency: el('a_freq').value,
    symbolrate: el('a_sr').value,
    polarization: el('a_pol').value  };
  if (!body.adapter && body.adapter !== '0') {
    el('amsg').className = 'msg bad';
    el('amsg').textContent = 'no hay adaptador seleccionado';
    return;
  }
  el('amsg').className = 'msg';
  el('scan_state').textContent = 'iniciando…';
  fetch('/api/v1/scan', {method:'POST', headers:{'Content-Type':'application/json'},
                         body: JSON.stringify(body)})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (!d.ok) {
        el('amsg').className = 'msg bad';
        el('amsg').textContent = d.message || 'error';
        el('scan_state').textContent = 'error';
        return;
      }
      pollScan();
      if (scanTimer) clearInterval(scanTimer);
      scanTimer = setInterval(pollScan, 1500);
    })
    .catch(function(e){ el('amsg').className = 'msg bad'; el('amsg').textContent = 'error: ' + e; });
}

function pollScan() {
  fetch('/api/v1/scan', {cache:'no-store'}).then(function(r){ return r.json(); })
    .then(function(d){
      el('scan_state').textContent = d.status + ' · ' + d.elapsed + 's · ' +
        (d.services ? d.services.length : 0) + ' canales';
      var rows = (d.services || []).map(function(s, i){
        return '<div class="addr"><input type="text" readonly value="' +
          esc((s.name || '(sin nombre)') + '  ·  PNR ' + s.pnr) + '">' +
          '<button class="rm" style="color:#1a73e8;font-size:12px" onclick="useChannel(' + i + ')">add</button></div>';
      }).join('');
      el('scan_rows').innerHTML = rows || '<div class="empty">sin canales todavía…</div>';
      if (d.status !== 'running') { clearInterval(scanTimer); scanTimer = null; }
      lastScan = d.services || [];
    })
    .catch(function(){});
}

var lastScan = [];
function useChannel(i) {
  var s = lastScan[i];
  if (!s) return;
  closeAdapter();
  showEditor({
    id: 'ch' + s.pnr,
    name: s.name || ('PNR ' + s.pnr),
    enabled: true,
    inputs: [s.address],
    outputs: [''],
    description: s.provider || ''
  });
}

function payload(action) {
  return { action: action, stream: {
    id: el('f_id').value.trim(),
    name: el('f_name').value.trim(),
    enabled: el('f_enable').checked,
    mps: el('f_mps').checked,
    description: el('f_desc').value,
    inputs: collect('inputs'),
    outputs: collect('outputs')
  }};
}

function send(action, done) {
  fetch('/api/v1/streams', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(payload(action))
  }).then(function(r){ return r.json(); }).then(function(d){
    list = d.streams || list; render();
    if (d.ok) { el('msg').className = 'msg ok'; el('msg').textContent = d.message || 'ok'; }
    else { el('msg').className = 'msg bad'; el('msg').textContent = d.message || 'error'; }
    if (done && d.ok) done();
  }).catch(function(e){
    el('msg').className = 'msg bad'; el('msg').textContent = 'error de red: ' + e;
  });
}

function apply() {
  if (el('f_remove').checked) { send('delete', closeEditor); return; }
  send('save', closeEditor);
}

function cloneStream() { send('clone', closeEditor); }
function verify() { send('verify'); }

refresh();
setInterval(function(){ if (!el('overlay').classList.contains('open')) refresh(); }, 4000);
</script>
</body>
</html>
]]
end

local function on_index(server, client, request)
    if not request then return end
    response(server, client, 200, "text/html; charset=utf-8", index_html())
end

local function on_adapters(server, client, request)
    if not request then return end
    reply_json(server, client, 200, adapters_json())
end

local function on_scan(server, client, request)
    if not request then return end

    if request.method == "POST" then
        local payload = nil
        if request.content and json and json.decode then
            local ok, decoded = pcall(json.decode, request.content)
            if ok then payload = decoded end
        end
        if type(payload) ~= "table" then
            reply_json(server, client, 400, '{"ok":false,"message":"JSON inválido"}')
            return
        end
        local ok, message = scan_start(payload)
        reply_json(server, client, ok and 200 or 400,
            '{"ok":' .. tostring(ok) .. ',"message":' .. js(message or "") ..
            ',"scan":' .. scan_json() .. '}')
        return
    end

    reply_json(server, client, 200, scan_json())
end

local function on_not_found(server, client, request)
    if not request then return end
    reply_json(server, client, 404,
        '{"error":"not found","hint":"/ /healthz /api/v1/status /api/v1/streams"}')
end

--------------------------------------------------------------------------
-- arranque
--------------------------------------------------------------------------

load_state()

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
        { "/api/v1/streams", on_api_streams },
        { "/api/v1/adapters", on_adapters },
        { "/api/v1/scan", on_scan },
        { "/*", on_not_found },
    },
})

for _, stream in ipairs(streams) do
    if stream.enabled then
        local ok, err = start_stream(stream)
        stream.last_error = ok and nil or err
    end
end
save_state()

log.info("mini-astra listening on " .. bind_addr .. ":" .. bind_port)
