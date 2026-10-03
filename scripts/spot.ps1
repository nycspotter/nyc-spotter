# NYC rare-aircraft schedule builder.
# 1. Worldwide: finds airborne XL types / special-livery tails whose route is to or from EWR/JFK/LGA.
# 2. Locally (NYC area): records when rare aircraft land at and take off from the three airports.
# 3. Learns recurring flights from those records and builds today's arrival/departure schedule.
# 4. Sends ntfy alerts: inbound, landed (with likely departure), 1h reminders, morning digest.
# Runs on GitHub Actions (pwsh 7) and locally on Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root    = Split-Path -Parent $PSScriptRoot
$dataDir = Join-Path $root 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$cfg  = Get-Content (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$utf8 = New-Object System.Text.UTF8Encoding $false
$inv  = [Globalization.CultureInfo]::InvariantCulture
$now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# ---------- time (New York) ----------
try   { $tz = [TimeZoneInfo]::FindSystemTimeZoneById('America/New_York') }
catch { $tz = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time') }
function Get-NyTime([long]$ts) { [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime, $tz) }
function Get-DayKey($t) { [int]$t.ToString('yyyyMMdd', $inv) }
function Format-Hm([int]$m) { $m = (($m % 1440) + 1440) % 1440; '{0:00}:{1:00}' -f [int][Math]::Floor($m / 60), ($m % 60) }
function Format-In([long]$sec) {
  $m = [int][Math]::Round($sec / 60)
  if ($m -lt 60) { return "약 ${m}분 후" }
  return "약 $([int][Math]::Floor($m / 60))시간 $($m % 60)분 후"
}
$ny     = Get-NyTime $now
$today  = Get-DayKey $ny
$dow    = [int]$ny.DayOfWeek
$nowMin = $ny.Hour * 60 + $ny.Minute

# ---------- json helpers ----------
function ConvertTo-Hash($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
    return $h
  }
  if ($o -is [System.Collections.IList]) { return ,@($o | ForEach-Object { ConvertTo-Hash $_ }) }
  return $o
}
function Read-Data($name) {
  $p = Join-Path $dataDir $name
  if (Test-Path $p) { return ConvertTo-Hash (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) }
  return @{}
}
function Write-Data($name, $obj) {
  [IO.File]::WriteAllText((Join-Path $dataDir $name), (ConvertTo-Json -InputObject $obj -Depth 10 -Compress), $utf8)
}
function Get-Json($url) { Invoke-RestMethod -Uri $url -TimeoutSec 25 -Headers @{ 'User-Agent' = 'nyc-spotter-board' } }

# ---------- config ----------
function Get-Map($obj) {
  $h = @{}
  if ($null -ne $obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name.ToUpper()] = $p.Value } }
  return $h
}
$xlTypes    = Get-Map $cfg.xl_types
$milTypes   = Get-Map $cfg.military_types
$milCalls   = Get-Map $cfg.military_callsign_prefixes
$liveries   = Get-Map $cfg.special_liveries
$watchTypes = Get-Map $cfg.watch_types
$watchRegs  = Get-Map $cfg.watch_registrations
$watchFlights = Get-Map $cfg.watch_flights

# Watchlist from open GitHub issues titled "watch flight LH400" / "watch type A346" / "watch reg D-AIHW".
# The site's ☆ buttons open a pre-filled issue; closing the issue removes the item.
$issueWatch = New-Object System.Collections.ArrayList
if ($env:GITHUB_TOKEN -and $env:GITHUB_REPOSITORY) {
  try {
    $issues = Invoke-RestMethod -Uri "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)/issues?state=open&per_page=100" -TimeoutSec 20 `
      -Headers @{ Authorization = "Bearer $($env:GITHUB_TOKEN)"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'nyc-spotter-board' }
    foreach ($is in $issues) {
      if ($is.pull_request -or "$($is.title)" -notmatch '^\s*watch\s+(flight|type|reg)\s+(\S+)') { continue }
      $kind = $Matches[1].ToLower(); $val = $Matches[2].ToUpper()
      switch ($kind) {
        'flight' { $watchFlights[$val] = '⭐ 관심 편' }
        'type'   { $watchTypes[$val]   = '⭐ 관심 기종' }
        'reg'    { $watchRegs[$val]    = '⭐ 관심 기체' }
      }
      [void]$issueWatch.Add([ordered]@{ kind = $kind; value = $val; url = "$($is.html_url)" })
    }
  } catch { Write-Warning "GitHub issues watchlist failed: $($_.Exception.Message)" }
}
$alertKinds = @($cfg.alert_kinds)
$airports   = @{}
foreach ($ap in $cfg.airports) { $airports[$ap.code] = $ap }

# ---------- state ----------
$state = Read-Data 'state.json'
foreach ($k in 'routes', 'last', 'alerted') { if ($null -eq $state[$k]) { $state[$k] = @{} } }
$events = New-Object System.Collections.ArrayList
$hist = Read-Data 'history.json'
if ($hist.events) { foreach ($e in $hist.events) { [void]$events.Add($e) } }
$newEvents = New-Object System.Collections.ArrayList
$alerts    = New-Object System.Collections.ArrayList

# ---------- helpers ----------
function Get-DistanceNm($lat1, $lon1, $lat2, $lon2) {
  $toRad = [Math]::PI / 180
  $dLat = ($lat2 - $lat1) * $toRad
  $dLon = ($lon2 - $lon1) * $toRad
  $a = [Math]::Pow([Math]::Sin($dLat / 2), 2) +
       [Math]::Cos($lat1 * $toRad) * [Math]::Cos($lat2 * $toRad) * [Math]::Pow([Math]::Sin($dLon / 2), 2)
  return 3440.065 * 2 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1 - $a))
}

function Get-Tags($callsign, $reg, $type, $dbFlags) {
  $tags = @()
  $isMil = ([int]$dbFlags -band 1) -ne 0
  $milNote = $null
  if ($type -and $milTypes.ContainsKey($type)) { $isMil = $true; $milNote = $milTypes[$type] }
  foreach ($prefix in $milCalls.Keys) {
    if ($callsign -and $callsign.StartsWith($prefix)) { $isMil = $true; $milNote = $milCalls[$prefix]; break }
  }
  # the ADS-B database's "military" flag also covers state/VIP aircraft (e.g. Qatar Amiri Flight)
  if ($isMil -and -not $milNote) { $milNote = '군·정부 등록 기체 (DB 표시)' }
  if ($isMil) { $tags += [ordered]@{ kind = 'military'; note = $milNote } }
  if ($type -and $xlTypes.ContainsKey($type))  { $tags += [ordered]@{ kind = 'xl';     note = $xlTypes[$type] } }
  if ($reg -and $liveries.ContainsKey($reg))   { $tags += [ordered]@{ kind = 'livery'; note = $liveries[$reg] } }
  if ($reg -and $watchRegs.ContainsKey($reg))  { $tags += [ordered]@{ kind = 'watch';  note = $watchRegs[$reg] } }
  elseif ($type -and $watchTypes.ContainsKey($type)) { $tags += [ordered]@{ kind = 'watch'; note = $watchTypes[$type] } }
  elseif ($callsign -and $watchFlights.ContainsKey($callsign)) { $tags += [ordered]@{ kind = 'watch'; note = $watchFlights[$callsign] } }
  return ,$tags
}

function Get-Info($a) {
  $gnd  = "$($a.alt_baro)" -eq 'ground'
  $cs   = "$($a.flight)".Trim().ToUpper()
  $reg  = "$($a.r)".Trim().ToUpper()
  $type = "$($a.t)".Trim().ToUpper()
  $tags = Get-Tags $cs $reg $type $a.dbFlags
  return [ordered]@{
    hex  = "$($a.hex)".ToLower()
    cs   = $cs; reg = $reg; type = $type
    gnd  = $gnd
    alt  = if ($gnd) { 0 } elseif ($null -ne $a.alt_baro) { [int]$a.alt_baro } else { $null }
    rate = if ($null -ne $a.baro_rate) { [int]$a.baro_rate } elseif ($null -ne $a.geom_rate) { [int]$a.geom_rate } else { 0 }
    gs   = if ($null -ne $a.gs) { [double]$a.gs } else { 0 }
    lat  = $a.lat; lon = $a.lon
    tags = $tags
    kinds = @($tags | ForEach-Object { $_.kind })
  }
}

$script:lookups = 0
function Get-Route($cs) {
  # callsign -> { o = origin IATA, d = destination IATA } via adsbdb, cached in state
  if (-not $cs) { return $null }
  $c = $state.routes[$cs]
  if ($c) {
    $ttl = if ($c.d) { 3 * 86400 } else { 86400 }
    if (($now - [long]$c.ts) -lt $ttl) { return $c }
  }
  if ($script:lookups -ge [int]$cfg.max_route_lookups_per_run) { return $c }
  $script:lookups++
  $r = @{ o = $null; d = $null; ts = $now }
  Start-Sleep -Milliseconds 300
  try {
    $fr = (Get-Json "https://api.adsbdb.com/v0/callsign/$cs").response.flightroute
    if ($fr) { $r.o = "$($fr.origin.iata_code)"; $r.d = "$($fr.destination.iata_code)" }
  } catch {
    # 404 = route unknown (cache it); anything else is temporary, so try again next run
    if ("$($_.Exception.Message)" -notmatch '404') { return $c }
  }
  $state.routes[$cs] = $r
  return $r
}

function Add-Event($ev, $ap, $i, $cs, [long]$ts) {
  foreach ($e in $events) {
    if ($e.hex -eq $i.hex -and $e.ev -eq $ev -and [Math]::Abs($ts - [long]$e.ts) -lt 10800) { return $null }
  }
  $t = Get-NyTime $ts
  $e = [ordered]@{
    ts = $ts; day = (Get-DayKey $t); dow = [int]$t.DayOfWeek; min = $t.Hour * 60 + $t.Minute
    ev = $ev; ap = $ap; hex = $i.hex; cs = $cs; type = $i.type; reg = $i.reg; kinds = $i.kinds
  }
  [void]$events.Add($e)
  [void]$newEvents.Add($e)
  return $e
}

$kindLabel = @{ military = 'MIL/GOV'; xl = 'XL'; livery = 'LIVERY'; watch = 'WATCH' }
function Get-KindText($kinds) { (@($kinds | ForEach-Object { $kindLabel[$_] }) -join '/') }
function Get-NoteText($tags) { (@($tags | Where-Object { $_.note } | ForEach-Object { "$($_.note)" } | Select-Object -Unique) -join ', ') }
function Add-Alert($key, $kinds, $title, $body, $click) {
  if ($state.alerted.ContainsKey($key)) { return }
  if ($null -ne $kinds -and @($kinds | Where-Object { $alertKinds -contains $_ }).Count -eq 0) { return }
  $state.alerted[$key] = $now
  [void]$alerts.Add(@{ title = $title; body = $body; click = $click })
}
$globe = 'https://globe.adsb.lol/?icao='

# ---------- 1. worldwide watch: rare aircraft flying to / from NYC ----------
# adsb.lol rate-limits bursts, so each run checks only a few types (rotating through the list)
# and tail numbers go to adsb.fi. Results are kept in state between runs.
$typeList = @($xlTypes.Keys | Sort-Object)
$perRun   = [Math]::Min([int]$cfg.type_queries_per_run, $typeList.Count)
$start    = if ($null -ne $state.type_cursor) { [int]$state.type_cursor % [Math]::Max($typeList.Count, 1) } else { 0 }
$watchUrls = @()
for ($n = 0; $n -lt $perRun; $n++) { $watchUrls += "https://api.adsb.lol/v2/type/$($typeList[($start + $n) % $typeList.Count])" }
$state.type_cursor = ($start + $perRun) % [Math]::Max($typeList.Count, 1)
$regList  = @((@($liveries.Keys) + @($watchRegs.Keys)) | Sort-Object -Unique)
if ($regList.Count -gt 0) {
  $regPerRun = [Math]::Min([int]$cfg.reg_queries_per_run, $regList.Count)
  $regStart  = if ($null -ne $state.reg_cursor) { [int]$state.reg_cursor % $regList.Count } else { 0 }
  for ($n = 0; $n -lt $regPerRun; $n++) { $watchUrls += "https://opendata.adsb.fi/api/v2/registration/$($regList[($regStart + $n) % $regList.Count])" }
  $state.reg_cursor = ($regStart + $regPerRun) % $regList.Count
}

$worldAc = @{}
foreach ($u in $watchUrls) {
  for ($try = 1; $try -le 2; $try++) {
    Start-Sleep -Milliseconds 3000
    try {
      $res = Get-Json $u
      foreach ($a in @($res.ac)) { if ($a -and $a.hex) { $worldAc["$($a.hex)".ToLower()] = $a } }
      break
    } catch {
      if ($try -eq 2 -or "$($_.Exception.Message)" -notmatch '429') { Write-Warning "$u failed: $($_.Exception.Message)"; break }
      Start-Sleep -Seconds 8
    }
  }
}

# flights found in earlier runs stay listed until they should have landed / left the area
if ($null -eq $state.inbound)  { $state.inbound  = @{} }
if ($null -eq $state.outbound) { $state.outbound = @{} }
foreach ($hex in @($worldAc.Keys)) {
  $i = Get-Info $worldAc[$hex]
  if ($i.gnd -or -not $i.cs -or $null -eq $i.lat -or $i.kinds.Count -eq 0) { continue }
  $route = Get-Route $i.cs
  if (-not $route -or -not $route.o -or -not $route.d) { continue }
  if ($airports.ContainsKey($route.d)) {
    $ap   = $airports[$route.d]
    $dist = Get-DistanceNm $i.lat $i.lon $ap.lat $ap.lon
    $eta  = $now + [long]($dist / [Math]::Max($i.gs, 150) * 3600) + 600   # + ~10 min for descent and approach
    $state.inbound[$i.hex] = [ordered]@{
      hex = $i.hex; cs = $i.cs; reg = $i.reg; type = $i.type; tags = $i.tags; kinds = $i.kinds
      origin = $route.o; ap = $route.d; dist_nm = [Math]::Round($dist); eta = $eta; ts = $now
    }
    $etaNy = Get-NyTime $eta
    Add-Alert "in|$($i.hex)|$($i.cs)" $i.kinds `
      "[$(Get-KindText $i.kinds)] $($i.type) $($i.reg) $($route.o)->$($route.d) ETA $($etaNy.ToString('HH:mm', $inv))" `
      "$($route.d) 도착 예정 $($etaNy.ToString('HH:mm', $inv)) ($(Format-In ($eta - $now)))`n$($route.o) 출발 · 편명 $($i.cs)`n$(Get-NoteText $i.tags)" `
      "$globe$($i.hex)"
  } elseif ($airports.ContainsKey($route.o)) {
    $ap   = $airports[$route.o]
    $dist = Get-DistanceNm $i.lat $i.lon $ap.lat $ap.lon
    $state.outbound[$i.hex] = [ordered]@{
      hex = $i.hex; cs = $i.cs; reg = $i.reg; type = $i.type; tags = $i.tags; kinds = $i.kinds
      ap = $route.o; dest = $route.d; dist_nm = [Math]::Round($dist); ts = $now
    }
    if ($dist -le 300) {   # departed recently; local tracking may have missed the takeoff
      [void](Add-Event 'dep' $route.o $i $i.cs ($now - [long]($dist / [Math]::Max($i.gs, 150) * 3600)))
    }
  }
}

foreach ($k in @($state.inbound.Keys))  { if ($now -gt [long]$state.inbound[$k].eta + 1800) { $state.inbound.Remove($k) } }
foreach ($k in @($state.outbound.Keys)) { if ($now - [long]$state.outbound[$k].ts -gt 3 * 3600) { $state.outbound.Remove($k) } }
$inbound  = @($state.inbound.Values)
$outbound = @($state.outbound.Values)

# ---------- 2. local: landings and takeoffs at EWR / JFK / LGA ----------
function Get-Local {
  $lat = $cfg.center.lat; $lon = $cfg.center.lon; $r = $cfg.local_radius_nm
  foreach ($s in @(
      @{ url = "https://opendata.adsb.fi/api/v2/lat/$lat/lon/$lon/dist/$r"; key = 'aircraft' },
      @{ url = "https://api.adsb.lol/v2/point/$lat/$lon/$r"; key = 'ac' })) {
    try {
      $list = (Get-Json $s.url).($s.key)
      if ($null -ne $list) { return @{ source = ([uri]$s.url).Host; list = @($list) } }
    } catch { Write-Warning "$($s.url) failed: $($_.Exception.Message)" }
  }
  throw 'All ADS-B sources failed'
}
$feed = Get-Local

# runway ends are magnetic designators; ADS-B tracks and METAR winds are true
function Get-AngleDiff([double]$a, [double]$b) { [Math]::Abs((($a - $b + 540) % 360) - 180) }
function Get-RunwayTrue($end) { ([int]$end * 10 + [double]$cfg.magnetic_variation + 360) % 360 }
function Get-RunwayEnd($code, [double]$track) {
  $best = $null; $bestDiff = 25
  foreach ($end in $airports[$code].runways) {
    $diff = Get-AngleDiff $track (Get-RunwayTrue $end)
    if ($diff -le $bestDiff) { $best = $end; $bestDiff = $diff }
  }
  return $best
}
$rwyVotes = @{}
foreach ($ap in $cfg.airports) { $rwyVotes[$ap.code] = @{ arr = @{}; dep = @{} } }

$ground = New-Object System.Collections.ArrayList
$landed = New-Object System.Collections.ArrayList

foreach ($a in $feed.list) {
  if ($null -eq $a.lat -or $null -eq $a.lon) { continue }
  $i = Get-Info $a

  $near = $null; $dist = [double]::MaxValue
  foreach ($ap in $cfg.airports) {
    $d = Get-DistanceNm $a.lat $a.lon $ap.lat $ap.lon
    if ($d -lt $dist) { $dist = $d; $near = $ap.code }
  }

  # every low arrival/departure near an airport votes for the runway direction in use
  if (-not $i.gnd -and $dist -le 8 -and $null -ne $i.alt -and $i.alt -le 3000 -and $null -ne $a.track) {
    $flow = if ($i.rate -le -300) { 'arr' } elseif ($i.rate -ge 300) { 'dep' } else { $null }
    $end  = if ($flow) { Get-RunwayEnd $near ([double]$a.track) } else { $null }
    if ($end) {
      $v = $rwyVotes[$near][$flow]
      $v[$end] = 1 + $(if ($v.ContainsKey($end)) { $v[$end] } else { 0 })
    }
  }

  if ($i.kinds.Count -eq 0) { continue }
  $atAp = $dist -le $cfg.airport_radius_nm -and ($i.gnd -or ($null -ne $i.alt -and $i.alt -le 3000))
  $prev = $state.last[$i.hex]
  $cs   = if ($i.cs) { $i.cs } elseif ($prev) { "$($prev.cs)" } else { '' }

  if ($i.gnd -and $atAp) {
    if ($prev -and -not $prev.gnd) {
      $e = Add-Event 'arr' $near $i $cs $now
      if ($e) { [void]$landed.Add(@{ info = $i; ev = $e }) }
    }
    $since = if ($prev -and $prev.gnd -and $prev.since) { [long]$prev.since } elseif ($prev) { $now } else { $null }
    $state.last[$i.hex] = @{ ap = $near; gnd = $true; ts = $now; cs = $cs; since = $since }
    [void]$ground.Add([ordered]@{ hex = $i.hex; cs = $cs; reg = $i.reg; type = $i.type; tags = $i.tags; kinds = $i.kinds; ap = $near; since = $since })
  } elseif (-not $i.gnd) {
    if ($prev -and $prev.gnd -and $prev.ap) {
      [void](Add-Event 'dep' $prev.ap $i $i.cs $now)
    } elseif (-not $prev -and $atAp -and $i.rate -ge 300) {
      [void](Add-Event 'dep' $near $i $i.cs $now)
    }
    if ($i.kinds -contains 'military' -and $dist -le $cfg.overhead_radius_nm -and $null -ne $i.alt -and $i.alt -le $cfg.overhead_max_alt_ft) {
      $where = if ($atAp) { "at $near" } else { 'over NYC' }
      Add-Alert "mil|$($i.hex)|$today" @('military') "[MIL/GOV] $($i.type) $($i.cs) $where" `
        "지금 $(if ($atAp) { "$near 부근" } else { 'NYC 상공' }) $($i.alt) ft`n$(Get-NoteText $i.tags)" "$globe$($i.hex)"
    }
    $state.last[$i.hex] = @{ ap = $(if ($atAp) { $near } else { $null }); gnd = $false; ts = $now; cs = $i.cs }
  } else {
    $state.last[$i.hex] = @{ ap = $null; gnd = $true; ts = $now; cs = $cs }
  }
}

# ---------- runways in use: traffic first, wind as fallback ----------
$metar = @{}
try {
  $ids = (@($cfg.airports | ForEach-Object { 'K' + $_.code }) -join ',')
  $list = Get-Json "https://aviationweather.gov/api/data/metar?ids=$ids&format=json"   # assign first so the array enumerates on PS 5.1
  foreach ($m in $list) {
    if ($m.icaoId) { $metar["$($m.icaoId)".Substring(1)] = $m }
  }
} catch { Write-Warning "METAR failed: $($_.Exception.Message)" }

$runways = [ordered]@{}
foreach ($ap in $cfg.airports) {
  $code  = $ap.code
  $votes = $rwyVotes[$code]
  $arr = @($votes.arr.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key })
  $dep = @($votes.dep.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key })
  $m = $metar[$code]
  $wdir = if ($m -and "$($m.wdir)" -match '^\d+$') { [int]$m.wdir } else { $null }   # 'VRB' -> null
  $wspd = if ($m -and $null -ne $m.wspd) { [int]$m.wspd } else { $null }
  $basis = 'traffic'
  if ($arr.Count -eq 0 -and $dep.Count -eq 0) {
    $basis = 'none'
    if ($null -ne $wdir -and $wspd -ge 5) {
      # land and take off into the wind
      $best = $null; $bestDiff = 360
      foreach ($end in $ap.runways) {
        $diff = Get-AngleDiff $wdir (Get-RunwayTrue $end)
        if ($diff -lt $bestDiff) { $best = $end; $bestDiff = $diff }
      }
      $arr = @($best); $dep = @($best); $basis = 'wind'
    }
  }
  $runways[$code] = [ordered]@{
    arr = $arr; dep = $dep; basis = $basis
    votes = [int](@(@($votes.arr.Values) + @($votes.dep.Values)) | Measure-Object -Sum).Sum
    wind_dir = $wdir; wind_spd = $wspd; wind_gust = $(if ($m) { $m.wgst } else { $null })
    metar = $(if ($m) { "$($m.rawOb)" } else { $null })
  }
}

# ---------- planned schedule from AeroDataBox (needs the AERODATABOX_KEY secret) ----------
# Fetches each airport's full day of scheduled arrivals/departures (two 12-hour windows = 2 calls),
# flags the rare ones and sends a "today/tomorrow at JFK" summary. Calls are counted per month.
$sc   = $cfg.schedule
$plan = Read-Data 'planned.json'
foreach ($k in 'days', 'slots', 'usage') { if ($null -eq $plan[$k]) { $plan[$k] = @{} } }
$monthKey = $ny.ToString('yyyy-MM', $inv)
if ($null -eq $plan.usage[$monthKey]) { $plan.usage[$monthKey] = 0 }

# AeroDataBox gives a model name ("Airbus A340-600"); map it to ICAO type codes. Order matters.
$typeFromModel = @(
  @('A380', 'A388'), @('747-8', 'B748'), @('747-4\d*LCF|Dreamlifter', 'BLCF'), @('747-4', 'B744'), @('747-2', 'B742'),
  @('747SP', 'B74S'), @('A340-6', 'A346'), @('A340-5', 'A345'), @('A340-3', 'A343'), @('A340-2', 'A342'),
  @('An-?124', 'A124'), @('An-?225', 'A225'), @('Beluga ?XL', 'A337'), @('Beluga|A300-600ST', 'A3ST'),
  @('MD-11', 'MD11'), @('DC-10', 'DC10'), @('Il-?96', 'IL96'), @('Il-?76', 'IL76'), @('C-17', 'C17'), @('C-5', 'C5M'),
  @('777-?F|777-2\d*LR|777 Freighter', 'B77L'), @('777-3', 'B77W'), @('777-2', 'B772'), @('787-10', 'B78X'),
  @('787-9', 'B789'), @('787-8', 'B788'), @('A350-1000', 'A35K'), @('A350', 'A359'), @('A330-9', 'A339'),
  @('A330-3', 'A333'), @('A330-2', 'A332'), @('767-4', 'B764'), @('767-3', 'B763'), @('757-2', 'B752'),
  @('A321', 'A321'), @('A320', 'A320'), @('A220-3', 'BCS3'), @('737', 'B738'))
function Get-TypeFromModel($model) {
  foreach ($p in $typeFromModel) { if ("$model" -match $p[0]) { return $p[1] } }
  return ''
}

# rare-flight tags for a scheduled flight; re-run every time so watchlist changes apply to stored days too
function Set-PlanKinds($item) {
  $tags = Get-Tags $item.cs $item.reg $item.type 0
  if ($sc.government_airline_pattern -and $item.airline -match $sc.government_airline_pattern -and -not ($tags | Where-Object { $_.kind -eq 'military' })) {
    $tags += [ordered]@{ kind = 'military'; note = $item.airline }
  }
  $numKey = "$($item.num)".Replace(' ', '').ToUpper()
  if ($numKey -and $watchFlights.ContainsKey($numKey) -and -not ($tags | Where-Object { $_.kind -eq 'watch' })) {
    $tags += [ordered]@{ kind = 'watch'; note = "$($watchFlights[$numKey])" }
  }
  $item.kinds = @($tags | ForEach-Object { $_.kind })
  $item.note  = Get-NoteText $tags
}

function Get-Fids($code, $date) {
  $items = New-Object System.Collections.ArrayList
  foreach ($w in @(@('00:00', '11:59'), @('12:00', '23:59'))) {
    if ([int]$plan.usage[$monthKey] -ge [int]$sc.monthly_call_budget) { Write-Warning 'AeroDataBox monthly call budget reached'; return $null }
    $plan.usage[$monthKey] = [int]$plan.usage[$monthKey] + 1
    $url = "https://aerodatabox.p.rapidapi.com/flights/airports/iata/$code/${date}T$($w[0])/${date}T$($w[1])" +
           '?withLeg=true&direction=Both&withCancelled=false&withCodeshared=false&withCargo=true&withPrivate=false&withLocation=false'
    try {
      $res = Invoke-RestMethod -Uri $url -TimeoutSec 30 -Headers @{ 'X-RapidAPI-Key' = $env:AERODATABOX_KEY; 'X-RapidAPI-Host' = 'aerodatabox.p.rapidapi.com' }
    } catch { Write-Warning "AeroDataBox $code $date failed: $($_.Exception.Message)"; return $null }
    Start-Sleep -Milliseconds 1200
    foreach ($dir in 'arrivals', 'departures') {
      foreach ($f in @($res.$dir)) {
        if (-not $f) { continue }
        $here  = if ($dir -eq 'arrivals') { $f.arrival } else { $f.departure }
        $there = if ($dir -eq 'arrivals') { $f.departure } else { $f.arrival }
        if ("$($here.scheduledTime.local)" -notmatch '^(\d{4}-\d{2}-\d{2})[ T](\d{2}):(\d{2})') { continue }
        $min = [int]$Matches[2] * 60 + [int]$Matches[3]
        $rmin = $null
        if ("$($here.revisedTime.local)" -match '^\d{4}-\d{2}-\d{2}[ T](\d{2}):(\d{2})') { $rmin = [int]$Matches[1] * 60 + [int]$Matches[2] }
        $num = "$($f.number)".Trim()
        $cs  = "$($f.callSign)".Replace(' ', '').ToUpper()
        if (-not $cs -and $f.airline.icao -and $num -match '(\d+[A-Z]?)$') { $cs = "$($f.airline.icao)$($Matches[1])".ToUpper() }
        $model = "$($f.aircraft.model)"
        $item = [ordered]@{
          ev = $(if ($dir -eq 'arrivals') { 'arr' } else { 'dep' }); min = $min; rmin = $rmin
          num = $num; cs = $cs; airline = "$($f.airline.name)"; type = (Get-TypeFromModel $model); model = $model
          reg = "$($f.aircraft.reg)".ToUpper(); other = "$($there.airport.iata)"; kinds = @(); note = ''
        }
        Set-PlanKinds $item
        [void]$items.Add($item)
      }
    }
  }
  return ,@($items | Sort-Object { [int]$_.min })
}

function Send-PlanDigest($code, $date, $flights, $label) {
  $rare = @($flights | Where-Object { @($_.kinds).Count -gt 0 })
  if ($rare.Count -eq 0) { return }
  $lines = $rare | Select-Object -First 15 | ForEach-Object {
    "$(Format-Hm $_.min) $(if ($_.ev -eq 'arr') { "도착 $($_.other)발" } else { "출발 $($_.other)행" }) $($_.num) $(if ($_.type) { $_.type } else { $_.model })$(if ($_.note) { " · $($_.note)" })"
  }
  $more = if ($rare.Count -gt 15) { "`n… 외 $($rare.Count - 15)편은 사이트에서" } else { '' }
  Add-Alert "plan|$code|$date|$label" $null "[PLAN] $code $date rare $($rare.Count)" "$label $code 레어 $($rare.Count)편`n$($lines -join "`n")$more" $null
}

if ($sc -and $env:AERODATABOX_KEY) {
  $todayStr = $ny.ToString('yyyy-MM-dd', $inv)
  foreach ($code in @($sc.airports)) {
    $jobs = @()
    foreach ($slot in @($sc.fetch_plan)) {
      $slotKey = "$code|$todayStr|$($slot.hour)"
      if ($ny.Hour -ge [int]$slot.hour -and -not $plan.slots.ContainsKey($slotKey)) { $jobs += @{ key = $slotKey; offset = [int]$slot.day_offset } }
    }
    # first run of the day without data: fetch today right away
    if (-not $plan.days.ContainsKey("$code|$todayStr") -and -not ($jobs | Where-Object { $_.offset -eq 0 })) {
      $jobs += @{ key = "$code|$todayStr|boot"; offset = 0 }
    }
    foreach ($job in $jobs) {
      # after a failed fetch, wait an hour before trying that slot again
      $failKey = "fail|$($job.key)"
      if ($plan.slots.ContainsKey($failKey) -and ($now - [long]$plan.slots[$failKey]) -lt 3600) { continue }
      $date = $ny.AddDays($job.offset).ToString('yyyy-MM-dd', $inv)
      $flights = Get-Fids $code $date
      if ($null -eq $flights) { $plan.slots[$failKey] = $now; continue }
      $plan.slots[$job.key] = $now
      $plan.days["$code|$date"] = [ordered]@{ fetched = $now; flights = $flights }
      Send-PlanDigest $code $date $flights $(if ($job.offset -eq 0) { '오늘' } else { '내일' })
    }
  }
}
foreach ($day in @($plan.days.Values)) { foreach ($it in @($day.flights)) { Set-PlanKinds $it } }
# keep yesterday onward; slot markers for a few days
$yesterday = $ny.AddDays(-1).ToString('yyyy-MM-dd', $inv)
foreach ($k in @($plan.days.Keys))  { if (($k -split '\|')[1] -lt $yesterday) { $plan.days.Remove($k) } }
foreach ($k in @($plan.slots.Keys)) { if ($now - [long]$plan.slots[$k] -gt 3 * 86400) { $plan.slots.Remove($k) } }

# ---------- 3. learn recurring flights ----------
$keep = $now - 30 * 86400
$events = [System.Collections.ArrayList]@($events | Where-Object { [long]$_.ts -ge $keep } | Sort-Object { [long]$_.ts })
$cut  = $now - [int]$cfg.pattern_days * 86400
$week = $now - 7 * 86400
$groups = @{}
foreach ($e in $events) {
  if ([long]$e.ts -lt $cut -or -not $e.cs) { continue }
  $k = "$($e.ev)|$($e.ap)|$($e.cs)"
  if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.ArrayList }
  [void]$groups[$k].Add($e)
}
$patterns = New-Object System.Collections.ArrayList
foreach ($k in $groups.Keys) {
  $g = @($groups[$k])
  $days = @($g | ForEach-Object { [int]$_.day } | Sort-Object -Unique)
  if ($days.Count -lt 2) { continue }
  $mins   = @($g | ForEach-Object { [int]$_.min } | Sort-Object)
  $dows   = @($g | ForEach-Object { [int]$_.dow } | Sort-Object -Unique)
  $recent = @($g | Where-Object { [long]$_.ts -ge $week } | ForEach-Object { [int]$_.day } | Sort-Object -Unique)
  $last   = $g[-1]
  $daily  = $recent.Count -ge 3
  [void]$patterns.Add([ordered]@{
    ev = $last.ev; ap = $last.ap; cs = $last.cs; type = $last.type; reg = $last.reg; kinds = @($last.kinds)
    min = $mins[[int][Math]::Floor($mins.Count / 2)]
    days = $days.Count; dows = $dows; daily = $daily; last_ts = [long]$last.ts
    today = ($daily -or ($dows -contains $dow))
  })
}

# ---------- 4. today's schedule ----------
$sched = New-Object System.Collections.ArrayList
function Find-Sched($ev, $ap, $cs, $type = $null, $min = $null) {
  foreach ($s in $sched) { if ($s.ev -eq $ev -and $s.ap -eq $ap -and $s.cs -eq $cs) { return $s } }
  # Same flight under a different callsign (e.g. UAE201 one day, UAE8ER the next):
  # match an expected entry with the same airline, airport, type and a time within 2 hours.
  if ($type -and $null -ne $min -and $cs -and $cs.Length -ge 3) {
    $airline = $cs.Substring(0, 3)
    foreach ($s in $sched) {
      if ($s.ev -eq $ev -and $s.ap -eq $ap -and $s.type -eq $type -and $s.status -eq 'expected' -and
          $s.cs -and $s.cs.StartsWith($airline) -and [Math]::Abs([int]$s.min - [int]$min) -le 120) { return $s }
    }
  }
  return $null
}
function New-Sched($ev, $ap, $x, $min, $status, $source) {
  $s = [ordered]@{
    ev = $ev; ap = $ap; cs = $x.cs; type = $x.type; reg = $x.reg; hex = $x.hex; kinds = @($x.kinds)
    min = $min; status = $status; source = $source
    eta = $null; origin = $null; dest = $null; days = $null; daily = $false
  }
  [void]$sched.Add($s)
  return $s
}
# rare flights from today's published schedule come first; learned patterns only fill gaps
$todayStr = $ny.ToString('yyyy-MM-dd', $inv)
foreach ($code in @($sc.airports)) {
  $d = $plan.days["$code|$todayStr"]
  if (-not $d) { continue }
  foreach ($it in @($d.flights)) {
    if (@($it.kinds).Count -eq 0 -or (Find-Sched $it.ev $code $it.cs)) { continue }
    $s = New-Sched $it.ev $code $it ([int]$it.min) 'expected' 'schedule'
    $s.hex = $null; $s.model = $it.model; $s.num = $it.num; $s.rmin = $it.rmin; $s.airline = $it.airline
    if ($it.ev -eq 'arr') { $s.origin = $it.other } else { $s.dest = $it.other }
  }
}
foreach ($p in $patterns) {
  if (-not $p.today -or (Find-Sched $p.ev $p.ap $p.cs $p.type $p.min)) { continue }
  $s = New-Sched $p.ev $p.ap $p ([int]$p.min) 'expected' 'pattern'
  $s.hex = $null; $s.days = $p.days; $s.daily = $p.daily
}
foreach ($e in $events) {
  if ([int]$e.day -ne $today) { continue }
  $s = Find-Sched $e.ev $e.ap $e.cs $e.type ([int]$e.min)
  if (-not $s) { $s = New-Sched $e.ev $e.ap $e ([int]$e.min) 'done' 'seen' }
  $s.status = 'done'; $s.min = [int]$e.min; $s.reg = $e.reg; $s.hex = $e.hex; $s.cs = $e.cs
}
foreach ($b in $inbound) {
  $etaNy  = Get-NyTime $b.eta
  $etaMin = $etaNy.Hour * 60 + $etaNy.Minute + $(if ((Get-DayKey $etaNy) -ne $today) { 1440 } else { 0 })
  $s = Find-Sched 'arr' $b.ap $b.cs $b.type $etaMin
  if (-not $s) { $s = New-Sched 'arr' $b.ap $b $etaMin 'airborne' 'live' }
  if ($s.status -ne 'done') { $s.status = 'airborne'; $s.min = $etaMin; $s.eta = $b.eta; $s.cs = $b.cs }
  $s.origin = $b.origin; $s.reg = $b.reg; $s.hex = $b.hex
}
foreach ($o in $outbound) {
  $s = Find-Sched 'dep' $o.ap $o.cs
  # only mark today's departure as gone if it was due by now; otherwise it's yesterday's flight still en route
  if ($s -and [int]$s.min -le $nowMin + 30) { $s.dest = $o.dest; $s.status = 'done' }
}
foreach ($s in $sched) {
  if ($s.status -eq 'expected' -and $s.min -lt $nowMin - 60) { $s.status = 'unseen' }
}
$schedSorted = @($sched | Sort-Object { [int]$_.min })

# likely departure for rare aircraft sitting on the ground: same airline + type, departing later today
function Find-NextDep($x) {
  if (-not $x.cs -or $x.cs.Length -lt 3) { return $null }
  $airline = $x.cs.Substring(0, 3)
  $best = $null
  foreach ($p in $patterns) {
    if ($p.ev -ne 'dep' -or $p.ap -ne $x.ap -or -not $p.today -or $p.type -ne $x.type) { continue }
    if (-not $p.cs.StartsWith($airline) -or $p.min -lt $nowMin - 30) { continue }
    if ($null -eq $best -or $p.min -lt $best.min) { $best = $p }
  }
  if ($best) { return [ordered]@{ cs = $best.cs; min = $best.min } }
  return $null
}
foreach ($g in $ground) { $g.next_dep = Find-NextDep $g }

# ---------- 5. alerts ----------
foreach ($l in $landed) {
  $i = $l.info; $e = $l.ev
  $nd = Find-NextDep ([ordered]@{ cs = $e.cs; ap = $e.ap; type = $i.type })
  $depText = if ($nd) { "출발 예상: $($nd.cs) $(Format-Hm $nd.min)" } else { '출발 시간은 아직 학습 전이에요' }
  Add-Alert "arr|$($i.hex)|$today" $i.kinds "[$(Get-KindText $i.kinds)] $($i.type) $($i.reg) landed $($e.ap)" `
    "$($e.ap) 도착 $(Format-Hm $e.min) · 편명 $($e.cs)`n$depText`n$(Get-NoteText $i.tags)" "$globe$($i.hex)"
}

$remind = [int]$cfg.remind_before_min
$remindKinds = @($cfg.remind_kinds)
foreach ($s in $schedSorted) {
  if ($s.status -ne 'expected') { continue }
  if (@($s.kinds | Where-Object { $remindKinds -contains $_ }).Count -eq 0) { continue }
  $until = $s.min - $nowMin
  if ($until -le 0 -or $until -gt $remind) { continue }
  $evKo = if ($s.ev -eq 'arr') { '도착' } else { '출발' }
  $evEn = if ($s.ev -eq 'arr') { 'ARR' } else { 'DEP' }
  Add-Alert "rem|$($s.ev)|$($s.ap)|$($s.cs)|$today" $s.kinds "[$(Get-KindText $s.kinds)] $($s.type) $($s.ap) $evEn ~$(Format-Hm $s.min) ($($s.cs))" `
    "약 ${until}분 후 $($s.ap) $evKo 예상 · 편명 $($s.cs)`n최근 $($s.days)일 관측 기준 예상 시간이에요" $null
}

# learned-pattern digest is only needed when there's no published schedule
if (-not $env:AERODATABOX_KEY -and $nowMin -ge [int]$cfg.digest_hour * 60 -and $state.digest_day -ne $today) {
  $state.digest_day = $today
  $items = @($schedSorted | Where-Object { $_.source -eq 'pattern' -or $_.status -eq 'airborne' })
  if ($items.Count -gt 0) {
    $lines = $items | ForEach-Object {
      "$(Format-Hm $_.min) $(if ($_.ev -eq 'arr') { '도착' } else { '출발' }) $($_.ap) $($_.cs) $($_.type)"
    }
    [void]$alerts.Insert(0, @{ title = "Today's rare schedule ($($items.Count))"; body = ($lines -join "`n"); click = $null })
  }
}

if ($env:NTFY_TOPIC) {
  foreach ($al in @($alerts | Select-Object -First ([int]$cfg.max_alerts_per_run))) {
    $headers = @{ Title = $al.title; Tags = 'airplane'; Priority = 'high' }
    if ($al.click) { $headers.Click = $al.click }
    try {
      Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$($env:NTFY_TOPIC)" -TimeoutSec 15 `
        -Body ([Text.Encoding]::UTF8.GetBytes($al.body)) -Headers $headers | Out-Null
    } catch { Write-Warning "ntfy failed: $($_.Exception.Message)" }
  }
}

# ---------- 6. save ----------
foreach ($k in @($state.alerted.Keys)) { if ($now - [long]$state.alerted[$k] -gt 3 * 86400) { $state.alerted.Remove($k) } }
foreach ($k in @($state.routes.Keys))  { if ($now - [long]$state.routes[$k].ts -gt 7 * 86400) { $state.routes.Remove($k) } }
foreach ($k in @($state.last.Keys))    { if ($now - [long]$state.last[$k].ts -gt 86400) { $state.last.Remove($k) } }

Write-Data 'state.json'   $state
Write-Data 'history.json' ([ordered]@{ events = @($events) })
Write-Data 'schedule.json' ([ordered]@{
  updated  = $now
  date     = $ny.ToString('yyyy-MM-dd', $inv)
  now_min  = $nowMin
  source   = $feed.source
  today    = $schedSorted
  ground   = @($ground)
  runways  = $runways
  patterns = @($patterns | Sort-Object { [int]$_.min })
  recent   = @($events | Sort-Object { [long]$_.ts } -Descending | Select-Object -First 40)
  planned  = $plan.days
  schedule_usage = [ordered]@{ month = $monthKey; calls = [int]$plan.usage[$monthKey]; budget = [int]$sc.monthly_call_budget }
  repo     = "$($env:GITHUB_REPOSITORY)"
  watch    = @($issueWatch)
})
Write-Data 'planned.json' $plan

Write-Host ("{0}: world rare {1} (to NYC {2}, from NYC {3}), local {4}, on ground {5}, new events {6}, patterns {7}, today {8}, alerts {9}, route lookups {10}" -f
  $feed.source, $worldAc.Count, $inbound.Count, $outbound.Count, $feed.list.Count, $ground.Count, $newEvents.Count, $patterns.Count, $schedSorted.Count, $alerts.Count, $script:lookups)
