# =====================================================================
#  OHZ Bobrowniki - agent AfiFarm -> Firebase           wersja 1.1
#
#  TYLKO CZYTA baze AfiFarm (SQL Server .\SAEAFIKIM, bazy afi_db).
#  Wysyla do Firebase (projekt aplikacji OHZ) surowe dane:
#    afi/meta     - grupy AfiFarm, stan stada dzien po dniu, czas wysylki
#    afi/krowy    - kazda krowa: grupy, wycielenia, inseminacje, badania,
#                   zasuszenia, wyjscia, zdarzenia, pedometr, kolczyk
#    afi_dni/RRRR-MM-DD - mleko, aktywnosc, przewodnosc na krowe w danym dniu
#  Wszystkie obliczenia (alarmy, statystyki) robi aplikacja.
#  Gdy nie ma internetu - zapisuje plik JSON na pulpicie (do wczytania
#  w aplikacji: Stado -> Ustawienia -> Wczytaj plik).
#
#  Uruchamianie:  ohz_afi_sync.ps1            - ostatnie dni (zwykle)
#                 ohz_afi_sync.ps1 -Pelny     - pelna historia (400 dni)
#                 ohz_afi_sync.ps1 -DoPliku   - tylko plik na pulpit
#  Zgodny z Windows 7 / PowerShell 2.0. Wymaga uprawnien administratora.
#
#  1.1: agent loguje sie do Firebase na konto agent@ohz-bobrowniki.app
#       (baza jest zamknieta dla niezalogowanych). Haslo jest zapisane
#       zaszyfrowane w pliku haslo_agenta.dat (ustawia je USTAW_HASLO.bat,
#       odczytac je moze tylko ten sam uzytkownik Windows na tym komputerze).
# =====================================================================
param([switch]$Pelny, [switch]$DoPliku)

# ---------------- KONFIGURACJA ----------------
$PROJEKT    = 'ohz-bobrowniki-po-app'
$KLUCZ      = 'AIzaSyC3vYPG90_aMEaKWJuhmzD1tj5lXT8Zh5o'
$SERWER     = '.\SAEAFIKIM'
$BAZA       = 'afi_db'
$DNI_PELNY  = 400     # ile dni historii przy pelnym eksporcie
$DNI_ZWYKLY = 4       # ile ostatnich dni przy zwyklym uruchomieniu
$KONTO      = 'agent@ohz-bobrowniki.app'
$WERSJA     = '1.1'
# ----------------------------------------------

$ErrorActionPreference = 'Stop'
$katalog = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPlik = Join-Path $katalog 'log.txt'
$hasloPlik = Join-Path $katalog 'haslo_agenta.dat'
$start = Get-Date

function Log([string]$t) {
    $l = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $t
    Write-Host $l
    try {
        if ((Test-Path $logPlik) -and ((Get-Item $logPlik).Length -gt 300KB)) {
            Move-Item $logPlik (Join-Path $katalog 'log_poprzedni.txt') -Force
        }
        Add-Content -Path $logPlik -Value $l -Encoding UTF8
    } catch {}
}

# ---------------- JSON (PowerShell 2.0 nie ma ConvertTo-Json) ----------------
function JS([string]$s) {
    if ($s -eq $null) { return 'null' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 34) { [void]$sb.Append('\"') }
        elseif ($c -eq 92) { [void]$sb.Append('\\') }
        elseif ($c -lt 32 -or $c -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function N($v) { if ($v -eq $null -or $v -is [DBNull]) { return 'null' } return ([string][long]$v) }
$BAZA_DATY = New-Object DateTime(1899, 12, 30)
function Iso([int]$d) { return $BAZA_DATY.AddDays($d).ToString('yyyy-MM-dd') }

# ---------------- SQL (tylko SELECT) ----------------
$conn = $null
function Q([string]$sql) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = 'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED; ' + $sql
    $cmd.CommandTimeout = 300
    $da = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt = New-Object System.Data.DataTable
    [void]$da.Fill($dt)
    return , $dt
}
function Dodaj($hash, $kl, $wartosc) {
    if (-not $hash.ContainsKey($kl)) { $hash[$kl] = New-Object System.Collections.ArrayList }
    [void]$hash[$kl].Add($wartosc)
}
function Ostatnie($lista, [int]$ile) {
    if ($lista -eq $null) { return @() }
    $n = $lista.Count
    if ($n -le $ile) { return @($lista) }
    return @($lista.GetRange($n - $ile, $ile).ToArray())
}

# ---------------- WYSYLKA DO FIREBASE ----------------
function Http([string]$url, [string]$body, [string]$token) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072) } catch {}
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('Content-Type', 'application/json; charset=utf-8')
    if ($token) { $wc.Headers.Add('Authorization', 'Bearer ' + $token) }
    try {
        return $wc.UploadString($url, 'POST', $body)
    } catch [Net.WebException] {
        $m = $_.Exception.Message
        if ($_.Exception.Response) {
            try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $m += ' | ' + $sr.ReadToEnd() } catch {}
        }
        throw $m
    }
}
# Logowanie konta agenta -> zwraca token waznym 1 godzine
function Zaloguj {
    if (-not (Test-Path $hasloPlik)) { throw 'Brak hasla agenta. Uruchom USTAW_HASLO.bat i wpisz haslo konta agent@ohz-bobrowniki.app.' }
    $ss = (Get-Content $hasloPlik | Select-Object -First 1) | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { $haslo = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $url = 'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + $KLUCZ
    try {
        $odp = Http $url ('{"email":' + (JS $KONTO) + ',"password":' + (JS $haslo) + ',"returnSecureToken":true}') $null
    } catch {
        if ("$_" -match 'INVALID_LOGIN_CREDENTIALS|INVALID_PASSWORD|EMAIL_NOT_FOUND') { throw 'Zle haslo agenta albo brak konta agent@ohz-bobrowniki.app w Firebase. Uruchom USTAW_HASLO.bat.' }
        throw ('Logowanie do Firebase nieudane: ' + $_)
    }
    $haslo = $null
    if ($odp -match '"idToken"\s*:\s*"([^"]+)"') { return $matches[1] }
    throw 'Logowanie do Firebase: brak tokenu w odpowiedzi'
}
$TOKEN = $null
function Wyslij([string]$body) {
    $url = 'https://firestore.googleapis.com/v1/projects/' + $PROJEKT + '/databases/(default)/documents:commit?key=' + $KLUCZ
    [void](Http $url $body $TOKEN)
}
function Zapis([string]$sciezka, [string]$json, [string]$extra) {
    $esc = $json.Replace('\', '\\').Replace('"', '\"')
    return '{"update":{"name":"projects/' + $PROJEKT + '/databases/(default)/documents/' + $sciezka + '","fields":{"j":{"stringValue":"' + $esc + '"}' + $extra + '}}}'
}

# =====================================================================
try {
    Log ('Start agenta ' + $WERSJA + $(if ($Pelny) { ' (PELNY eksport)' } else { '' }) + $(if ($DoPliku) { ' (tylko plik)' } else { '' }))
    $conn = New-Object System.Data.SqlClient.SqlConnection('Server=' + $SERWER + ';Database=' + $BAZA + ';Integrated Security=SSPI;Connect Timeout=20;Application Name=OHZ_agent_tylko_odczyt')
    $conn.Open()

    $DZIS = [int](Q "SELECT DATEDIFF(day, '18991230', GETDATE())").Rows[0][0]
    $ileDni = $(if ($Pelny) { $DNI_PELNY } else { $DNI_ZWYKLY })
    $OD = $DZIS - $ileDni + 1
    $OKNO = $DZIS - $DNI_PELNY - 30          # zakres zdarzen do kart krow
    $MASKA = 16777216                     # ID >= tej wartosci = zwierzeta historyczne (numer uzyty ponownie)
    Log ('Dzis = ' + $DZIS + ' (' + (Iso $DZIS) + '), dni ' + (Iso $OD) + ' .. ' + (Iso $DZIS))

    # ---------- 1. Dane dzienne (mleko, aktywnosc) ----------
    $dm = Q ("SELECT [Date], CowID, Milk, Act, Cond, LactationNum, [Time] FROM DailyMilk WITH (NOLOCK) WHERE [Date] >= " + $OD + " AND CowID > 0 AND CowID < " + $MASKA + " ORDER BY [Date], CowID")
    $dni = @{}       # iso -> json
    $sb = $null; $dzien = -1; $pierwszy = $true
    foreach ($r in $dm.Rows) {
        $d = [int]$r[0]
        if ($d -ne $dzien) {
            if ($sb) { [void]$sb.Append('}}'); $dni[(Iso $dzien)] = $sb.ToString() }
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append('{"d":' + $d + ',"c":{')
            $dzien = $d; $pierwszy = $true
        }
        if (-not $pierwszy) { [void]$sb.Append(',') }
        $pierwszy = $false
        [void]$sb.Append('"' + [string][long]$r[1] + '":[' + (N $r[2]) + ',' + (N $r[3]) + ',' + (N $r[4]) + ',' + (N $r[5]) + ',' + (N $r[6]) + ']')
    }
    if ($sb) { [void]$sb.Append('}}'); $dni[(Iso $dzien)] = $sb.ToString() }
    Log ('DailyMilk: ' + $dm.Rows.Count + ' wierszy, dni: ' + $dni.Count)

    # ---------- 2. Krowy ----------
    $grupy = @{}; $wyc = @{}; $ins = @{}; $pd = @{}; $zas = @{}; $wyj = @{}; $wej = @{}; $ev = @{}; $st = @{}; $ostatnio = @{}
    function Widziana($id, [int]$d) { if (-not $ostatnio.ContainsKey($id) -or $ostatnio[$id] -lt $d) { $ostatnio[$id] = $d } }

    foreach ($r in (Q ("SELECT CowID, [Date], NewGroup FROM ChangeGroup WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA + " ORDER BY CowID, [Date], [Order]")).Rows) {
        $id = [string][long]$r[0]; Dodaj $grupy $id ('[' + [int]$r[1] + ',' + (N $r[2]) + ']'); Widziana $id ([int]$r[1])
    }
    foreach ($r in (Q ("SELECT CowID, [Date] FROM Calving WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA + " ORDER BY CowID, [Date]")).Rows) {
        $id = [string][long]$r[0]; Dodaj $wyc $id ([string][int]$r[1]); Widziana $id ([int]$r[1])
    }
    foreach ($r in (Q ("SELECT CowID, [Date], IDBull FROM Inseminator WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA + " AND [Date] >= " + $OKNO + " ORDER BY CowID, [Date]")).Rows) {
        $id = [string][long]$r[0]; Dodaj $ins $id ('[' + [int]$r[1] + ',' + (N $r[2]) + ']'); Widziana $id ([int]$r[1])
    }
    foreach ($r in (Q ("SELECT CowID, [Date], EventCode FROM PDPlus WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA + " AND [Date] >= " + $OKNO + " ORDER BY CowID, [Date]")).Rows) {
        $id = [string][long]$r[0]; Dodaj $pd $id ('[' + [int]$r[1] + ',' + (N $r[2]) + ']')
    }
    foreach ($r in (Q ("SELECT CowID, [Date] FROM Dry WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA + " ORDER BY CowID, [Date]")).Rows) {
        $id = [string][long]$r[0]; Dodaj $zas $id ([string][int]$r[1]); Widziana $id ([int]$r[1])
    }
    foreach ($r in (Q ("SELECT CowID, [Date], Type FROM Exits WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA + " ORDER BY CowID, [Date]")).Rows) {
        $id = [string][long]$r[0]; $wyj[$id] = @([int]$r[1], (N $r[2]))
    }
    foreach ($r in (Q ("SELECT CowID, [Date] FROM Entry WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA + " ORDER BY CowID, [Date]")).Rows) {
        $id = [string][long]$r[0]; $wej[$id] = [int]$r[1]; Widziana $id ([int]$r[1])
    }
    foreach ($r in (Q ("SELECT CowID, [Date], EventCode, Status FROM Events WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA + " ORDER BY CowID, [Date]")).Rows) {
        $id = [string][long]$r[0]; $d = [int]$r[1]
        if ($d -ge $OKNO) { Dodaj $ev $id ('[' + $d + ',' + (N $r[2]) + ']') }
        if (-not ($r[3] -is [DBNull])) { $st[$id] = [string][long]$r[3] }
        Widziana $id $d
    }
    foreach ($r in (Q ("SELECT CowID, MAX([Date]) FROM DailyMilk WITH (NOLOCK) WHERE [Date] >= " + ($DZIS - 60) + " AND CowID > 0 AND CowID < " + $MASKA + " GROUP BY CowID")).Rows) {
        Widziana ([string][long]$r[0]) ([int]$r[1])
    }
    $ped = @{}
    foreach ($r in (Q ("SELECT CowID, Tag FROM Act10 WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA)).Rows) { $ped[[string][long]$r[0]] = (N $r[1]) }
    $kol = @{}
    foreach ($r in (Q ("SELECT CowID, RegNumber FROM Registration WITH (NOLOCK) WHERE CowID > 0 AND CowID < " + $MASKA)).Rows) {
        if (-not ($r[1] -is [DBNull])) { $kol[[string][long]$r[0]] = ([string]$r[1]).Trim() }
    }

    $kb = New-Object System.Text.StringBuilder
    [void]$kb.Append('{"d":' + $DZIS + ',"k":{')
    $pierwszy = $true; $ileAkt = 0; $ileWyj = 0
    foreach ($id in $ostatnio.Keys) {
        $ostWej = -1
        if ($wej.ContainsKey($id)) { $ostWej = $wej[$id] }
        if ($wyc.ContainsKey($id)) { $lw = [int]$wyc[$id][$wyc[$id].Count - 1]; if ($lw -gt $ostWej) { $ostWej = $lw } }
        $wyszla = $false; $dWyj = 0
        if ($wyj.ContainsKey($id)) { $dWyj = $wyj[$id][0]; if ($dWyj -ge $ostWej) { $wyszla = $true } }
        $aktywna = (-not $wyszla) -and ($ostatnio[$id] -ge ($DZIS - 1100))
        if (-not $aktywna -and -not ($wyszla -and $dWyj -ge $OKNO)) { continue }
        if ($aktywna) { $ileAkt++ } else { $ileWyj++ }
        if (-not $pierwszy) { [void]$kb.Append(',') }
        $pierwszy = $false
        [void]$kb.Append('"' + $id + '":{"a":' + $(if ($aktywna) { 1 } else { 0 }))
        if ($grupy.ContainsKey($id)) { [void]$kb.Append(',"g":[' + [string]::Join(',', (Ostatnie $grupy[$id] 30)) + ']') }
        if ($wyc.ContainsKey($id)) { [void]$kb.Append(',"c":[' + [string]::Join(',', (Ostatnie $wyc[$id] 5)) + ']') }
        if ($ins.ContainsKey($id)) { [void]$kb.Append(',"i":[' + [string]::Join(',', (Ostatnie $ins[$id] 12)) + ']') }
        if ($pd.ContainsKey($id)) { [void]$kb.Append(',"p":[' + [string]::Join(',', (Ostatnie $pd[$id] 6)) + ']') }
        if ($zas.ContainsKey($id)) { [void]$kb.Append(',"z":[' + [string]::Join(',', (Ostatnie $zas[$id] 3)) + ']') }
        if ($wyj.ContainsKey($id)) { [void]$kb.Append(',"w":[' + $wyj[$id][0] + ',' + $wyj[$id][1] + ']') }
        if ($wej.ContainsKey($id)) { [void]$kb.Append(',"n":' + $wej[$id]) }
        if ($ev.ContainsKey($id)) { [void]$kb.Append(',"e":[' + [string]::Join(',', (Ostatnie $ev[$id] 40)) + ']') }
        if ($st.ContainsKey($id)) { [void]$kb.Append(',"s":' + $st[$id]) }
        if ($ped.ContainsKey($id)) { [void]$kb.Append(',"t":' + $ped[$id]) }
        if ($kol.ContainsKey($id)) { [void]$kb.Append(',"r":' + (JS $kol[$id])) }
        [void]$kb.Append('}')
    }
    [void]$kb.Append('}}')
    $krowyJson = $kb.ToString()
    Log ('Krowy: aktywne ' + $ileAkt + ', wybrakowane w oknie ' + $ileWyj + ', rozmiar ' + [Math]::Round($krowyJson.Length / 1024) + ' KB')
    if ($krowyJson.Length -gt 900000) { Log 'UWAGA: dane krow blisko limitu Firebase (1 MB na dokument) - daj znac Claude' }

    # ---------- 3. Meta: grupy i stado ----------
    $mb = New-Object System.Text.StringBuilder
    [void]$mb.Append('{"v":' + (JS $WERSJA) + ',"ts":' + (JS ((Get-Date).ToString('yyyy-MM-dd HH:mm'))) + ',"d":' + $DZIS + ',"od":' + $OD + ',"pelny":' + $(if ($Pelny) { 1 } else { 0 }) + ',"grupy":{')
    $pierwszy = $true
    foreach ($r in (Q 'SELECT GroupStatus, Description FROM GroupCode WITH (NOLOCK) ORDER BY GroupStatus').Rows) {
        if (-not $pierwszy) { [void]$mb.Append(',') }; $pierwszy = $false
        [void]$mb.Append('"' + (N $r[0]) + '":' + (JS (([string]$r[1]).Trim())))
    }
    [void]$mb.Append('},"stado":[')
    $pierwszy = $true
    foreach ($r in (Q ("SELECT [Date], Milk, MilkCows, MilkStatus, DryStatus, HeiferStatus, MaleStatus FROM HerdState WITH (NOLOCK) WHERE Herd = 1 AND [Date] >= " + ($DZIS - $DNI_PELNY) + " ORDER BY [Date]")).Rows) {
        if (-not $pierwszy) { [void]$mb.Append(',') }; $pierwszy = $false
        [void]$mb.Append('[' + (N $r[0]) + ',' + (N $r[1]) + ',' + (N $r[2]) + ',' + (N $r[3]) + ',' + (N $r[4]) + ',' + (N $r[5]) + ',' + (N $r[6]) + ']')
    }
    [void]$mb.Append('],"komp":' + (JS $env:COMPUTERNAME) + '}')
    $metaJson = $mb.ToString()
    $conn.Close(); $conn = $null

    # ---------- 4. Wysylka ----------
    $wyslano = $false
    if (-not $DoPliku) {
        try {
            $TOKEN = Zaloguj
            Log ('Zalogowano jako ' + $KONTO)
            $paczka = New-Object System.Collections.ArrayList
            $rozmiar = 0; $ileDoc = 0
            $klucze = @($dni.Keys | Sort-Object)
            foreach ($iso in $klucze) {
                $w = Zapis ('afi_dni/' + $iso) $dni[$iso] (',"d":{"integerValue":"' + ($dni[$iso].Substring(5, 5)) + '"}')
                [void]$paczka.Add($w); $rozmiar += $w.Length
                if ($rozmiar -gt 700000 -or $paczka.Count -ge 60) {
                    Wyslij ('{"writes":[' + [string]::Join(',', $paczka.ToArray()) + ']}'); $ileDoc += $paczka.Count
                    $paczka.Clear(); $rozmiar = 0
                }
            }
            [void]$paczka.Add((Zapis 'afi/krowy' $krowyJson ''))
            [void]$paczka.Add((Zapis 'afi/meta' $metaJson ''))
            Wyslij ('{"writes":[' + [string]::Join(',', $paczka.ToArray()) + ']}'); $ileDoc += $paczka.Count
            $wyslano = $true
            Log ('WYSLANO do Firebase: ' + $ileDoc + ' dokumentow')
            Set-Content -Path (Join-Path $katalog 'ostatnia_wysylka.txt') -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm') + '  OK  ' + $ileDoc + ' dok.') -Encoding UTF8
        } catch {
            Log ('BLAD wysylki: ' + $_)
        }
    }
    if (-not $wyslano) {
        $pulpit = [Environment]::GetFolderPath('Desktop')
        if (-not $pulpit -or -not (Test-Path $pulpit)) { $pulpit = $katalog }
        $plik = Join-Path $pulpit ('OHZ_AfiFarm_' + (Get-Date).ToString('yyyy-MM-dd_HHmm') + '.json')
        $fb = New-Object System.Text.StringBuilder
        [void]$fb.Append('{"ohz_afi":1,"meta":' + $metaJson + ',"krowy":' + $krowyJson + ',"dni":{')
        $pierwszy = $true
        foreach ($iso in @($dni.Keys | Sort-Object)) {
            if (-not $pierwszy) { [void]$fb.Append(',') }; $pierwszy = $false
            [void]$fb.Append('"' + $iso + '":' + $dni[$iso])
        }
        [void]$fb.Append('}}')
        [IO.File]::WriteAllText($plik, $fb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Log ('Zapisano plik awaryjny: ' + $plik)
    }
    Log ('Koniec, czas ' + [Math]::Round(((Get-Date) - $start).TotalSeconds) + ' s')
    exit 0
} catch {
    Log ('BLAD: ' + $_)
    if ($conn) { try { $conn.Close() } catch {} }
    exit 1
}
