# =====================================================================
#  Instalator agenta OHZ AfiFarm (wywolywany z ZAINSTALUJ.bat)
#  1) kopiuje pliki do C:\OHZ_AFI
#  2) tworzy zadanie w Harmonogramie zadan: codziennie 10:00 i 21:00,
#     z najwyzszymi uprawnieniami, uruchamiane takze po wlaczeniu
#     komputera, jesli pora zostala przegapiona
#  3) pyta o haslo konta agenta i zapisuje je zaszyfrowane
#  4) wykonuje pierwszy, pelny eksport (400 dni)
#  Niczego nie zmienia w AfiFarm.
# =====================================================================
$ErrorActionPreference = 'Stop'
$CEL = 'C:\OHZ_AFI'
$ZADANIE = 'OHZ AfiFarm eksport'
$zrodlo = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ''
Write-Host '  INSTALACJA AGENTA OHZ AfiFarm' -ForegroundColor Green
Write-Host '  ------------------------------'
try {
    # 1. Kopiowanie plikow
    if (-not (Test-Path $CEL)) { [void](New-Item -ItemType Directory -Path $CEL) }
    if ($zrodlo.TrimEnd('\') -ne $CEL) {
        foreach ($f in (Get-ChildItem $zrodlo | Where-Object { -not $_.PSIsContainer -and $_.Name -notmatch '^(log.*|ostatnia_wysylka)\.txt$' -and $_.Name -ne 'haslo_agenta.dat' })) {
            Copy-Item $f.FullName (Join-Path $CEL $f.Name) -Force
        }
    }
    Write-Host ('  [1/4] Pliki skopiowane do ' + $CEL)

    # 2. Zadanie w Harmonogramie
    $uzytk = $env:USERDOMAIN + '\' + $env:USERNAME
    $jutro = (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>OHZ Bobrowniki: odczyt danych z AfiFarm (tylko odczyt) i wysylka do aplikacji.</Description></RegistrationInfo>
  <Triggers>
    <CalendarTrigger><StartBoundary>${jutro}T10:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>
    <CalendarTrigger><StartBoundary>${jutro}T21:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>$uzytk</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$CEL\ohz_afi_sync.ps1"</Arguments>
      <WorkingDirectory>$CEL</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    $xmlPlik = Join-Path $env:TEMP 'ohz_afi_zadanie.xml'
    [IO.File]::WriteAllText($xmlPlik, $xml, [Text.Encoding]::Unicode)
    $wynik = & schtasks.exe /Create /TN $ZADANIE /XML $xmlPlik /F 2>&1
    Remove-Item $xmlPlik -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { throw ('Nie udalo sie utworzyc zadania: ' + ($wynik | Out-String)) }
    Write-Host ('  [2/4] Zadanie "' + $ZADANIE + '" utworzone: codziennie 10:00 i 21:00')

    # 3. Haslo agenta
    Write-Host '  [3/4] Haslo konta agenta'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $CEL 'ustaw_haslo.ps1')
    if (-not (Test-Path (Join-Path $CEL 'haslo_agenta.dat'))) { throw 'Nie ustawiono hasla agenta - uruchom ZAINSTALUJ.bat jeszcze raz.' }

    # 4. Pierwszy pelny eksport
    Write-Host '  [4/4] Pierwszy, pelny eksport (400 dni) - to moze potrwac 1-3 minuty...'
    Write-Host ''
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $CEL 'ohz_afi_sync.ps1') -Pelny
    $kod = $LASTEXITCODE
    Write-Host ''
    if ($kod -eq 0 -and (Test-Path (Join-Path $CEL 'ostatnia_wysylka.txt'))) {
        Write-Host '  GOTOWE. Agent zainstalowany i dane wyslane do aplikacji.' -ForegroundColor Green
        Write-Host '  Sprawdz w aplikacji: zakladka "Stado (AfiFarm)".' -ForegroundColor Green
    } elseif ($kod -eq 0) {
        Write-Host '  Agent zainstalowany, ale wysylka do internetu sie nie udala.' -ForegroundColor Yellow
        Write-Host '  Plik z danymi zapisano na PULPICIE (OHZ_AfiFarm_....json).' -ForegroundColor Yellow
        Write-Host ('  Szczegoly bledu: ' + $CEL + '\log.txt') -ForegroundColor Yellow
    } else {
        Write-Host '  Agent zainstalowany, ale eksport zakonczyl sie BLEDEM.' -ForegroundColor Red
        Write-Host ('  Szczegoly: ' + $CEL + '\log.txt  (wyslij ten plik Claude)') -ForegroundColor Red
    }
} catch {
    Write-Host ''
    Write-Host ('  BLAD INSTALACJI: ' + $_) -ForegroundColor Red
}
