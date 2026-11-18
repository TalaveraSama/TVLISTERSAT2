-- Mini Astra example: relay one UDP MPEG-TS input to one UDP output.
-- Usage: ./astra examples/relay.lua
-- Replace the addresses with the interfaces/ports used in your lab.

local input = udp_input({
    addr = os.getenv("MINI_ASTRA_INPUT_ADDR") or "239.10.10.10",
    port = tonumber(os.getenv("MINI_ASTRA_INPUT_PORT") or "5000"),
    socket_size = 4 * 1024 * 1024,
})

local output = udp_output({
    upstream = input:stream(),
    addr = os.getenv("MINI_ASTRA_OUTPUT_ADDR") or "239.10.10.20",
    port = tonumber(os.getenv("MINI_ASTRA_OUTPUT_PORT") or "6000"),
})

log.info("mini-astra relay started")

timer({
    interval = 3600,
    callback = function() end,
})
