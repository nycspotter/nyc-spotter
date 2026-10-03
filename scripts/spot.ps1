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
  if ($isMil) { $tags += [ordered]@{ kind = 'military'; note = $milNote } }
  if ($type -and $xlTypes.ContainsKey($type))  { $tags += [ordered]@{ kind = 'xl';     note = $xlTypes[$type] } }
  if ($reg -and $liveries.ContainsKey($reg))   { $tags += [ordered]@{ kind = 'livery'; note = $liveries[$reg] } }
  if ($reg -and $watchRegs.ContainsKey($reg))  { $tags += [ordered]@{ kind = 'watch';  note = $watchRegs[$reg] } }
  elseif ($type -and $watchTypes.ContainsKey($type)) { $tags += [ordered]@{ kind = 'watch'; note = $watchTypes[$type] } }
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

$kindLabel = @{ military = 'MIL'; xl = 'XL'; livery = 'LIVERY'; watch = 'WATCH' }
function Get-KindText($kinds) { (@($kinds | ForEach-Object { $kindLabel[$_] }) -join '/') }
function Get-NoteText($tags) { (@($tags | Where-Object { $_.note } | ForEach-Object { $_.note }) -join ', ') }
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
$ground = New-Object System.Collections.ArrayList
$landed = New-Object System.Collections.ArrayList

foreach ($a in $feed.list) {
  if ($null -eq $a.lat -or $null -eq $a.lon) { continue }
  $i = Get-Info $a
  if ($i.kinds.Count -eq 0) { continue }

  $near = $null; $dist = [double]::MaxValue
  foreach ($ap in $cfg.airports) {
    $d = Get-DistanceNm $a.lat $a.lon $ap.lat $ap.lon
    if ($d -lt $dist) { $dist = $d; $near = $ap.code }
  }
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
      Add-Alert "mil|$($i.hex)|$today" @('military') "[MIL] $($i.type) $($i.cs) $where" `
        "지금 $(if ($atAp) { "$near 부근" } else { 'NYC 상공' }) $($i.alt) ft`n$(Get-NoteText $i.tags)" "$globe$($i.hex)"
    }
    $state.last[$i.hex] = @{ ap = $(if ($atAp) { $near } else { $null }); gnd = $false; ts = $now; cs = $i.cs }
  } else {
    $state.last[$i.hex] = @{ ap = $null; gnd = $true; ts = $now; cs = $cs }
  }
}

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
foreach ($p in $patterns) {
  if (-not $p.today) { continue }
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
  if ($s) { $s.dest = $o.dest; $s.status = 'done' }
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
foreach ($s in $schedSorted) {
  if ($s.status -ne 'expected') { continue }
  $until = $s.min - $nowMin
  if ($until -le 0 -or $until -gt $remind) { continue }
  $evKo = if ($s.ev -eq 'arr') { '도착' } else { '출발' }
  $evEn = if ($s.ev -eq 'arr') { 'ARR' } else { 'DEP' }
  Add-Alert "rem|$($s.ev)|$($s.ap)|$($s.cs)|$today" $s.kinds "[$(Get-KindText $s.kinds)] $($s.type) $($s.ap) $evEn ~$(Format-Hm $s.min) ($($s.cs))" `
    "약 ${until}분 후 $($s.ap) $evKo 예상 · 편명 $($s.cs)`n최근 $($s.days)일 관측 기준 예상 시간이에요" $null
}

if ($nowMin -ge [int]$cfg.digest_hour * 60 -and $state.digest_day -ne $today) {
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
  patterns = @($patterns | Sort-Object { [int]$_.min })
  recent   = @($events | Sort-Object { [long]$_.ts } -Descending | Select-Object -First 40)
})

Write-Host ("{0}: world rare {1} (to NYC {2}, from NYC {3}), local {4}, on ground {5}, new events {6}, patterns {7}, today {8}, alerts {9}, route lookups {10}" -f
  $feed.source, $worldAc.Count, $inbound.Count, $outbound.Count, $feed.list.Count, $ground.Count, $newEvents.Count, $patterns.Count, $schedSorted.Count, $alerts.Count, $script:lookups)
