$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$required = @(
    'README.md',
    'BUILDING-UBUNTU.md',
    'configure.sh',
    'mini-astra',
    'install.sh',
    'uninstall.sh',
    '.github/workflows/release.yml',
    'scripts/mini-astra.lua',
    'systemd/mini-astra.service'
)
foreach ($relative in $required) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required file: $relative"
    }
}

$wrapper = Get-Content (Join-Path $root 'mini-astra') -Raw
if ($wrapper -notmatch 'systemctl') { throw 'Wrapper has no systemd integration' }
if ($wrapper -notmatch 'health') { throw 'Wrapper has no health command' }

$config = Get-Content (Join-Path $root 'scripts/mini-astra.lua') -Raw
foreach ($route in @('/healthz','/readyz','/api/v1/status','/api/v1/streams')) {
    if ($config -notmatch [regex]::Escape($route)) { throw "Missing route: $route" }
}

$relay = Get-Content (Join-Path $root 'examples/relay.lua') -Raw
if ($relay -notmatch 'upstream = input:stream\(\)') { throw 'Relay has no upstream connection' }
if ($relay -notmatch 'timer\(') { throw 'Relay has no timer keepalive' }

$unit = Get-Content (Join-Path $root 'systemd/mini-astra.service') -Raw
foreach ($directive in @('ExecStart=','Restart=on-failure','NoNewPrivileges=true','User=mini-astra','MINI_ASTRA_STATE=')) {
    if ($unit -notmatch [regex]::Escape($directive)) { throw "Missing systemd directive: $directive" }
}

Write-Output 'Mini Astra static checks passed.'
