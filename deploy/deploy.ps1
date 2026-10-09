#!/usr/bin/env pwsh
# Push one zone to the nameservers and verify parity.
# Transport is base64 over ssh to avoid CRLF mangling by PowerShell pipes.
# Usage:
#   .\deploy\deploy.ps1 -Zone example.com -ZoneFile .\zones\example.com.zone
#   .\deploy\deploy.ps1 -Zone example.com -ZoneFile .\zones\example.com.zone `
#     -Servers ([ordered]@{ 'ns1' = '192.0.2.53'; 'ns2' = '192.0.2.154' })
param(
  [Parameter(Mandatory = $true)][string]$Zone,
  [Parameter(Mandatory = $true)][string]$ZoneFile,
  [System.Collections.Specialized.OrderedDictionary]$Servers = [ordered]@{
    'ns1' = '166.1.2.48'   # nameserver 1
    'ns2' = '62.109.10.170' # nameserver 2
  }
)
$ErrorActionPreference = 'Stop'
$key = (Resolve-Path (Join-Path $PSScriptRoot '..\..\.setup\id_ed25519_bc')).Path
$zonePath = (Resolve-Path $ZoneFile).Path

# LF-normalized zone in temp
$zoneLf = Join-Path $env:TEMP ('{0}.zone' -f $Zone)
[IO.File]::WriteAllText($zoneLf, ((Get-Content $zonePath -Raw) -replace "`r", ""), (New-Object System.Text.UTF8Encoding($false)))
$b64zone = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zoneLf))
$b64inst = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path (Join-Path $PSScriptRoot 'install-nsd.sh')).Path))

foreach ($h in $Servers.GetEnumerator()) {
  "== deploy $($h.Key) ($($h.Value))"
  ssh -i $key -o IdentitiesOnly=yes "root@$($h.Value)" "echo $b64zone | base64 -d > /tmp/$Zone.zone" 2>&1 | Out-Null
  $out = ssh -i $key -o IdentitiesOnly=yes "root@$($h.Value)" "echo $b64inst | base64 -d | bash -s $Zone" 2>&1
  $out | Where-Object { $_ -match 'host ip|OK:|FATAL|not found|error|failed' }
}

"== parity check (queried at our own servers)"
foreach ($h in $Servers.GetEnumerator()) {
  $a = Resolve-DnsName $Zone     -Server $h.Value -DnsOnly -NoHostsFile -ErrorAction SilentlyContinue | Where-Object QueryType -eq A
  $w = Resolve-DnsName "www.$Zone" -Server $h.Value -DnsOnly -NoHostsFile -ErrorAction SilentlyContinue | Where-Object QueryType -eq A
  "$($h.Key): apex -> $($a.IPAddress) | www -> $($w.IPAddress)"
}
