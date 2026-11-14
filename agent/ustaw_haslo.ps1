# =====================================================================
#  Ustawienie hasla agenta OHZ AfiFarm (wywolywane z USTAW_HASLO.bat
#  i z instalatora). Haslo konta agent@ohz-bobrowniki.app jest sprawdzane
#  w Firebase i zapisywane ZASZYFROWANE w pliku haslo_agenta.dat.
#  Odszyfrowac je moze tylko ten sam uzytkownik Windows na tym komputerze.
# =====================================================================
$ErrorActionPreference = 'Stop'
$KLUCZ = 'AIzaSyC3vYPG90_aMEaKWJuhmzD1tj5lXT8Zh5o'
$KONTO = 'agent@ohz-bobrowniki.app'
$katalog = Split-Path -Parent $MyInvocation.MyCommand.Path
$hasloPlik = Join-Path $katalog 'haslo_agenta.dat'

function JS([string]$s) {
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

Write-Host ''
Write-Host '  HASLO AGENTA OHZ AfiFarm' -ForegroundColor Green
Write-Host ('  Wpisz haslo konta ' + $KONTO + ' (ustawione w Firebase).')
Write-Host '  Podczas pisania nic sie nie wyswietla - to normalne.'
Write-Host ''
for ($proba = 1; $proba -le 3; $proba++) {
    $ss = Read-Host '  Haslo' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { $haslo = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $haslo) { continue }
    try { [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072) } catch {}
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('Content-Type', 'application/json; charset=utf-8')
    $ok = $false; $blad = ''
    try {
        $odp = $wc.UploadString('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + $KLUCZ, 'POST', '{"email":' + (JS $KONTO) + ',"password":' + (JS $haslo) + ',"returnSecureToken":true}')
        if ($odp -match '"idToken"') { $ok = $true }
    } catch [Net.WebException] {
        $blad = $_.Exception.Message
        if ($_.Exception.Response) { try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $blad += ' ' + $sr.ReadToEnd() } catch {} }
    }
    $haslo = $null
    if ($ok) {
        Set-Content -Path $hasloPlik -Value ($ss | ConvertFrom-SecureString) -Encoding ASCII
        Write-Host '  OK - haslo poprawne i zapisane.' -ForegroundColor Green
        exit 0
    }
    if ($blad -match 'INVALID_LOGIN_CREDENTIALS|INVALID_PASSWORD|EMAIL_NOT_FOUND') {
        Write-Host '  Zle haslo albo brak konta agent@ohz-bobrowniki.app w Firebase. Sprobuj jeszcze raz.' -ForegroundColor Yellow
    } else {
        Write-Host ('  Nie udalo sie polaczyc z Firebase (internet?): ' + $blad) -ForegroundColor Yellow
        Write-Host '  Haslo zapisane bez sprawdzenia - agent sprawdzi je przy wysylce.' -ForegroundColor Yellow
        Set-Content -Path $hasloPlik -Value ($ss | ConvertFrom-SecureString) -Encoding ASCII
        exit 0
    }
}
Write-Host '  Haslo NIE zostalo zapisane. Uruchom USTAW_HASLO.bat ponownie.' -ForegroundColor Red
exit 1
