# ============================================================
# Conector Wifito <-> CyberPlanet  ·  Sucursal: LINCOLN OXXO
# Cada 3 min saca una instantanea de Windows de cyber.mdb (CyberPlanet lo
# tiene bloqueado), la comprime y la manda a Wifito. Una vez al dia (despues
# de las 6:00) manda ademas cyberback.mdb (el historial de cajas cerradas),
# por partes. NUNCA modifica CyberPlanet: solo copia y envia.
# Funciona en Windows 7 (PowerShell 2.0) y en Windows 10/11 (PowerShell 5.1).
#
# Se instala ESCONDIDO en la carpeta de Musica para que nadie lo borre.
# Instalar (PowerShell normal, "Ejecutar como administrador"):
#   powershell -ExecutionPolicy Bypass -File .\conector.ps1 -Instalar
# Probar una vez sin instalar:      ... -File .\conector.ps1
# Forzar el historial ahora mismo:  ... -File .\conector.ps1 -Historial
# Quitar la tarea programada:       ... -File .\conector.ps1 -Desinstalar
# ============================================================
param([switch]$Instalar, [switch]$Desinstalar, [switch]$Historial)
$ErrorActionPreference = 'Stop'
$VERSION = '2.7'
$URL     = 'https://wifito.io/api/cyberplanet/conector/LINCOLN%20OXXO'
$CLAVE   = 'e4d2a653436406d06e7abc633413e89197c15584db30bc40'
$ORIGEN  = 'C:\Program Files (x86)\TenaxSoft\CyberPlanet\cyber.mdb'
$MINUTOS = 3
$TAREA   = 'Wifito Conector CyberPlanet'
$TROZO   = 900KB
$SCRIPT  = $MyInvocation.MyCommand.Definition
$RAIZMUS = [Environment]::GetFolderPath('MyMusic')
if (-not $RAIZMUS -or "$RAIZMUS".Trim() -eq '') { $RAIZMUS = Join-Path $env:USERPROFILE 'Music' }
$CARPETA = Join-Path $RAIZMUS 'WifitoConector'
# El registro y la marca del historial van JUNTO al script (SYSTEM no ve el perfil del usuario).
$SITIO = Split-Path -Parent $SCRIPT
if ($Instalar) { $SITIO = $CARPETA }
New-Item -ItemType Directory -Force -Path $SITIO | Out-Null
$LOG   = Join-Path $SITIO 'conector.log'
$MARCA = Join-Path $SITIO 'historial.txt'
function Log($m) {
  $l = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
  try { Add-Content -Path $LOG -Value $l -Encoding UTF8 } catch { }
  Write-Host $l
  try { if ((Get-Item $LOG).Length -gt 1MB) { Move-Item $LOG ($LOG + '.1') -Force } } catch { }
}
# HTTPS: TLS 1.2. En Windows 7 con PowerShell 2.0, .NET no lo tiene: entonces se
# envia con WinHTTP de Windows (el mismo que usa Windows Update), que si lo tiene
# si la PC tiene la actualizacion KB3140245.
[Net.ServicePointManager]::Expect100Continue = $false
$USAR_WINHTTP = $false
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072 }
catch {
  $USAR_WINHTTP = $true
  Log 'AVISO: este PowerShell no tiene TLS 1.2: se envia con WinHTTP de Windows. Si el envio falla, instala la actualizacion KB3140245 o Windows Management Framework 5.1 en esta PC.'
}

# Envio por WinHTTP (Windows 7 / PowerShell 2.0 sin TLS 1.2 en .NET).
function Enviar-WinHttp([string]$destino, [byte[]]$datos, [string]$tipo) {
  $w = New-Object -ComObject 'WinHttp.WinHttpRequest.5.1'
  $w.SetTimeouts(30000, 60000, 300000, 300000)
  $w.Open('POST', $destino, $false)
  # Opcion 9 = protocolos seguros: 2560 = TLS 1.1 + TLS 1.2 (o solo TLS 1.2 = 2048).
  try { $w.Option(9) = 2560 } catch { try { $w.Option(9) = 2048 } catch { } }
  $w.SetRequestHeader('Content-Type', $tipo)
  $w.SetRequestHeader('X-Clave-Conector', $CLAVE)
  $w.SetRequestHeader('X-Version', $VERSION)
  try { $w.Send($datos) }
  catch { throw ('WinHTTP: ' + $_.Exception.Message + ' -- Si es un error de seguridad o de conexion, instala la actualizacion KB3140245 de Windows 7 o Windows Management Framework 5.1 en esta PC.') }
  $txt = $w.ResponseText
  $st = [int]$w.Status
  if ($st -lt 200 -or $st -ge 300) { throw ('HTTP ' + $st + ': ' + $txt) }
  return $txt
}

# Manda bytes por POST y devuelve la respuesta (texto). Lanza error con el detalle del servidor.
function Enviar-Bytes([string]$destino, [byte[]]$datos, [string]$tipo) {
  if ($USAR_WINHTTP) { return Enviar-WinHttp $destino $datos $tipo }
  $req = [Net.HttpWebRequest]::Create($destino)
  $req.Method = 'POST'
  $req.ContentType = $tipo
  $req.Timeout = 300000
  $req.ReadWriteTimeout = 300000
  $req.Headers.Add('X-Clave-Conector', $CLAVE)
  $req.Headers.Add('X-Version', $VERSION)
  $req.ContentLength = $datos.Length
  try {
    $s = $req.GetRequestStream(); $s.Write($datos, 0, $datos.Length); $s.Close()
    $resp = $req.GetResponse()
  } catch {
    $ex = $_.Exception
    while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
    if ($ex -and $ex.Response) {
      $sr = New-Object IO.StreamReader($ex.Response.GetResponseStream())
      $txt = $sr.ReadToEnd(); $sr.Close()
      throw ('HTTP ' + [int]$ex.Response.StatusCode + ': ' + $txt)
    }
    throw
  }
  $sr = New-Object IO.StreamReader($resp.GetResponseStream())
  $txt = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
  return $txt
}
function Enviar-Error($msg) {
  try {
    $t = "$msg" -replace '\\', '\\' -replace '"', '\"' -replace [char]13, ' ' -replace [char]10, ' '
    $json = '{"error":"' + $t + '"}'
    Enviar-Bytes ($URL + '/error') ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' | Out-Null
  } catch { }
}
# Manda un archivo comprimido: de un jalon si cabe, o por partes de 900 KB.
function Enviar-Archivo([string]$ruta, [string]$tipo) {
  $largo = (Get-Item $ruta).Length
  if ($tipo -eq 'vivo' -and $largo -le $TROZO) {
    return Enviar-Bytes $URL ([IO.File]::ReadAllBytes($ruta)) 'application/octet-stream'
  }
  $total = [int][math]::Ceiling($largo / $TROZO)
  $id = (Get-Date).ToString('yyyyMMddHHmmss')
  $extra = ''
  if ($tipo -eq 'vivo') { $extra = '&tipo=vivo' }
  $fs = [IO.File]::OpenRead($ruta)
  $resp = ''
  try {
    for ($p = 1; $p -le $total; $p++) {
      $len = [int][math]::Min($TROZO, $largo - $fs.Position)
      $parte = New-Object byte[] $len
      $leidos = 0
      while ($leidos -lt $len) { $n = $fs.Read($parte, $leidos, $len - $leidos); if ($n -le 0) { break }; $leidos += $n }
      $u = $URL + '/historial?id=' + $id + '&parte=' + $p + '&total=' + $total + $extra
      $resp = Enviar-Bytes $u $parte 'application/octet-stream'
    }
  } finally { $fs.Close() }
  return ('(' + $total + ' partes) ' + $resp)
}
# Copia un archivo bloqueado usando una instantanea de Windows (VSS).
function Copiar-ConSombra($ruta, $destino) {
  $enlace = Join-Path $env:SystemDrive 'wifito_sombra'
  $sc = $null
  try {
    if (-not (Test-Path $ruta)) { throw ('No encuentro ' + $ruta) }
    # Las instantaneas necesitan el servicio "Instantaneas de volumen" (VSS). Si esta deshabilitado, se pone en Manual.
    $svc = Get-WmiObject Win32_Service -Filter "Name='VSS'"
    if ($svc -and $svc.StartMode -eq 'Disabled') {
      cmd /c sc config VSS start= demand | Out-Null
      Log 'El servicio Instantaneas de volumen (VSS) estaba deshabilitado: se puso en Manual.'
    }
    $unidad = (Split-Path -Qualifier $ruta) + '\'
    $r = (Get-WmiObject -List Win32_ShadowCopy).Create($unidad, 'ClientAccessible')
    if ($r.ReturnValue -ne 0) { throw ('No se pudo crear la instantanea (codigo ' + $r.ReturnValue + ')') }
    $sc = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $r.ShadowID }
    if (Test-Path $enlace) { cmd /c rmdir "$enlace" | Out-Null }
    cmd /c mklink /d "$enlace" ($sc.DeviceObject + '\') | Out-Null
    Copy-Item (Join-Path $enlace $ruta.Substring(3)) $destino -Force
  } finally {
    if (Test-Path $enlace) { cmd /c rmdir "$enlace" | Out-Null }
    if ($sc) { try { $sc.Delete() } catch { } }
  }
}
# La copia sirve solo si es una base de Access (empieza con "Standard Jet DB" o
# "Standard ACE DB"). En algunas PCs la instantanea sale del tamano correcto
# pero toda en ceros: esa no se manda.
function EsBaseAccess($ruta) {
  try {
    $fs = New-Object IO.FileStream($ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $b = New-Object byte[] 20; $n = $fs.Read($b, 0, 20) } finally { $fs.Close() }
    if ($n -lt 20) { return $false }
    $t = [Text.Encoding]::ASCII.GetString($b, 4, 15)
    return ($t -eq 'Standard Jet DB' -or $t -eq 'Standard ACE DB')
  } catch { return $false }
}
# Copia leyendo el archivo abierto en modo compartido (CyberPlanet lo deja leer
# aunque lo tenga abierto). Se usa si la instantanea sale mal.
function Copiar-Compartido($ruta, $destino) {
  $in = New-Object IO.FileStream($ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $out = [IO.File]::Create($destino)
    try {
      $buf = New-Object byte[] 65536
      while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n) }
    } finally { $out.Close() }
  } finally { $in.Close() }
}
# Comprime con GZip por bloques (poca memoria, sirve para archivos grandes).
function Comprimir($origenArch, $destinoArch) {
  $in = [IO.File]::OpenRead($origenArch)
  $out = [IO.File]::Create($destinoArch)
  $gz = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionMode]::Compress)
  $buf = New-Object byte[] 65536
  try {
    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $gz.Write($buf, 0, $n) }
  } finally { $gz.Close(); $out.Close(); $in.Close() }
}

# ¿Esta ventana de PowerShell se abrio como administrador? (funciona en PowerShell 2.0)
function EsAdmin {
  $yo = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$MSG_ADMIN = 'Esta ventana NO es de administrador. Cierrala, busca Windows PowerShell, dale clic derecho > Ejecutar como administrador (arriba debe decir "Administrador:") y vuelve a pegar el comando.'
# PowerShell de 32 bits en un Windows de 64 bits no puede usar las instantaneas.
if ($env:PROCESSOR_ARCHITEW6432) { Log 'Usa el PowerShell normal (de 64 bits), no el de SysWOW64.'; exit 1 }
if ($Desinstalar) {
  schtasks /Delete /TN "$TAREA" /F | Out-Null
  Log 'Tarea programada eliminada.'; exit 0
}
if ($Instalar) {
  if (-not (EsAdmin)) { Log ('ERROR: ' + $MSG_ADMIN); exit 1 }
  # Limpia una instalacion vieja en ProgramData, si existe.
  $viejo = Join-Path $env:ProgramData 'WifitoConector'
  if ($env:ProgramData -and (Test-Path $viejo)) { try { Remove-Item $viejo -Recurse -Force } catch { } }
  New-Item -ItemType Directory -Force -Path $CARPETA | Out-Null
  $destino = Join-Path $CARPETA 'conector.ps1'
  # Si ya estaba instalado (oculto), se le quita lo oculto para poder reemplazarlo.
  if (Test-Path $destino) { cmd /c attrib -h -s "$destino" | Out-Null }
  if ($SCRIPT -ne $destino) { Copy-Item -Path $SCRIPT -Destination $destino -Force }
  # Esconde la carpeta y el script (oculto + sistema) para que no se vean ni se borren.
  cmd /c attrib +h +s "$CARPETA" | Out-Null
  cmd /c attrib +h +s "$destino" | Out-Null
  $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $destino + '"'
  schtasks /Create /TN "$TAREA" /TR $cmd /SC MINUTE /MO $MINUTOS /RU SYSTEM /RL HIGHEST /F | Out-Null
  if ($LASTEXITCODE -ne 0) { Log ('ERROR: no se pudo crear la tarea programada (codigo ' + $LASTEXITCODE + '). ' + $MSG_ADMIN); exit 1 }
  Log ('Instalado y escondido en: ' + $CARPETA + ' . Corre cada ' + $MINUTOS + ' minutos como SYSTEM. PowerShell ' + $PSVersionTable.PSVersion + '. Primera prueba ahora...')
  $Historial = $true   # la primera vez rescata toda la historia
}

# ---- 0) Cual base usa CyberPlanet de verdad ----
# No siempre es cyber.mdb: hay PCs donde CyberPlanet trabaja en otra base de su
# carpeta (por ejemplo cyberTT.mdb) y el cyber.mdb se quedo viejo o en blanco.
# En Windows 7, si CyberPlanet no corre como administrador, sus cambios van a
# la carpeta escondida VirtualStore de cada usuario.
# 1o) En la carpeta de CyberPlanet (y su VirtualStore): cualquier cyber*.mdb que
#     sea base de Access buena (menos cyberback*), prefiriendo la que esta
#     abierta (tiene su .ldb) y luego la modificada mas recientemente.
# 2o) Si ahi no hay ninguna: la ruta recordada (ruta.txt) o, una vez al dia,
#     una busqueda en todo el disco. Nunca se usan respaldos (rutas con
#     "backup"): esos se quedan atrasados.
$RUTA_GUARDADA = Join-Path $SITIO 'ruta.txt'
$BUSQUEDA      = Join-Path $SITIO 'busqueda.txt'
$USADA         = Join-Path $SITIO 'usada.txt'
function Sirve-Base($f) {
  if ($f.PSIsContainer -or $f.Extension -ne '.mdb') { return $false }
  if ($f.Name -like 'cyberback*') { return $false }
  if ($f.FullName -like '*backup*' -or $f.FullName -like '*WifitoConector*') { return $false }
  return (EsBaseAccess $f.FullName)
}
function Mejor-Base($lista) {
  $mejor = $null; $mejorAbierta = $false
  foreach ($f in $lista) {
    $abierta = Test-Path -LiteralPath ([IO.Path]::ChangeExtension($f.FullName, '.ldb'))
    if (-not $mejor -or ($abierta -and -not $mejorAbierta) -or ($abierta -eq $mejorAbierta -and $f.LastWriteTime -gt $mejor.LastWriteTime)) { $mejor = $f; $mejorAbierta = $abierta }
  }
  return $mejor
}
function Buscar-Cyber($configurada) {
  $raiz = $env:SystemDrive + '\'
  $perfiles = @(Get-ChildItem -Path (Join-Path $raiz 'Users') -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })
  $dirs = @()
  foreach ($r in @((Split-Path $configurada).Substring(3), 'Program Files (x86)\TenaxSoft\CyberPlanet', 'Program Files\TenaxSoft\CyberPlanet')) {
    $dirs += (Join-Path $raiz $r)
    foreach ($p in $perfiles) { $dirs += (Join-Path $p.FullName ('AppData\Local\VirtualStore\' + $r)) }
  }
  $buenas = @()
  if ((Test-Path -LiteralPath $configurada) -and (EsBaseAccess $configurada)) { $buenas += (Get-Item -LiteralPath $configurada -Force) }
  foreach ($d in ($dirs | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    $buenas += @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'cyber*.mdb' -and (Sirve-Base $_) })
  }
  $mejor = Mejor-Base $buenas
  if (-not $mejor -and (Test-Path -LiteralPath $RUTA_GUARDADA)) {
    $g = "$(Get-Content -LiteralPath $RUTA_GUARDADA | Select-Object -First 1)".Trim()
    if ($g -and (Test-Path -LiteralPath $g)) { $f = Get-Item -LiteralPath $g -Force; if (Sirve-Base $f) { $mejor = $f } }
  }
  if (-not $mejor) {
    $hoyB = (Get-Date).ToString('yyyy-MM-dd')
    $yaBusco = $false
    if (Test-Path -LiteralPath $BUSQUEDA) { $yaBusco = ((Get-Content -LiteralPath $BUSQUEDA | Select-Object -First 1) -eq $hoyB) }
    if (-not $yaBusco) {
      Set-Content -LiteralPath $BUSQUEDA -Value $hoyB -Encoding ASCII
      Log 'Buscando la base de CyberPlanet en todo el disco (una vez al dia, puede tardar unos minutos)...'
      $todos = @(Get-ChildItem -Path $raiz -Recurse -Force -Filter 'cyber*.mdb' -ErrorAction SilentlyContinue | Where-Object { Sirve-Base $_ })
      $mejor = Mejor-Base $todos
      if ($mejor) { Set-Content -LiteralPath $RUTA_GUARDADA -Value $mejor.FullName -Encoding UTF8 }
      else { Log 'No encontre ninguna base de CyberPlanet buena en el disco (los respaldos no cuentan).' }
    }
  }
  if ($mejor) { return $mejor.FullName }
  return $configurada
}
$ORIGEN_CONF = $ORIGEN
$ORIGEN = Buscar-Cyber $ORIGEN
$antes = ''
if (Test-Path -LiteralPath $USADA) { $antes = "$(Get-Content -LiteralPath $USADA | Select-Object -First 1)".Trim() }
if ($ORIGEN -ne $antes) {
  try { Set-Content -LiteralPath $USADA -Value $ORIGEN -Encoding UTF8 } catch { }
  Log ('Base de CyberPlanet: ' + $ORIGEN)
}

# ---- 1) Envio en vivo de cyber.mdb (siempre) ----
$copia = Join-Path $SITIO 'cyber_copia.mdb'
$gzc   = Join-Path $SITIO 'cyber_copia.gz'
# 1o instantanea de Windows; si falla o sale en blanco, copia directa en modo compartido.
$metodo = ''
$errSombra = ''
$errDirecta = ''
try {
  Copiar-ConSombra $ORIGEN $copia
  if (EsBaseAccess $copia) { $metodo = 'instantanea' } else { $errSombra = 'la copia salio en blanco (no es una base de Access)' }
} catch { $errSombra = $_.Exception.Message }
if (-not $metodo) {
  try {
    Copiar-Compartido $ORIGEN $copia
    if (EsBaseAccess $copia) { $metodo = 'directa' } else { $errDirecta = 'la copia salio en blanco (no es una base de Access)' }
  } catch { $errDirecta = $_.Exception.Message }
}
if (-not $metodo) {
  Remove-Item $copia -Force -ErrorAction SilentlyContinue
  $info = ''
  try { $fi = Get-Item $ORIGEN; $info = ' Archivo: ' + $ORIGEN + ' (' + [math]::Round($fi.Length / 1KB) + ' KB, modificado ' + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ').' } catch { $info = ' No encuentro ' + $ORIGEN + '.' }
  $motivo = 'No se pudo sacar una copia buena de cyber.mdb. Instantanea: ' + $errSombra + '. Copia directa: ' + $errDirecta + '.' + $info
  if (-not (EsAdmin)) { $motivo = $motivo + ' -- ' + $MSG_ADMIN }
  Log ('ERROR al copiar: ' + $motivo); Enviar-Error ('Copia: ' + $motivo); exit 1
}
if ($metodo -eq 'directa') { Log ('AVISO: la instantanea no sirvio (' + $errSombra + '); se uso la copia directa.') }
try {
  Comprimir $copia $gzc
  $kb = [math]::Round((Get-Item $gzc).Length / 1KB)
  $resp = Enviar-Archivo $gzc 'vivo'
  Log ('OK: enviado ' + $kb + ' KB -> ' + $resp)
} catch {
  Log ('ERROR al enviar: ' + $_.Exception.Message)
} finally {
  Remove-Item $copia -Force -ErrorAction SilentlyContinue
  Remove-Item $gzc -Force -ErrorAction SilentlyContinue
}

# ---- 2) Historial (cyberback.mdb): una vez al dia despues de las 6:00, o forzado con -Historial ----
$hoy = (Get-Date).ToString('yyyy-MM-dd')
$yaHoy = $false
if (Test-Path $MARCA) { $yaHoy = ((Get-Content $MARCA | Select-Object -First 1) -eq $hoy) }
if ($Historial -or ((Get-Date).Hour -ge 6 -and -not $yaHoy)) {
  # De donde sacar el historial: primero el respaldo de CyberPlanet (no esta bloqueado),
  # si no, una instantanea del cyberback*.mdb junto a cyber.mdb.
  $back = $null
  $dirBack = 'C:\BackUp CyberPlanet'
  if (Test-Path $dirBack) {
    $back = Get-ChildItem -Path $dirBack -Recurse -Filter 'cyberback*.mdb' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  $copiaH = Join-Path $SITIO 'cyberback_copia.mdb'
  $gzh    = Join-Path $SITIO 'cyberback_copia.gz'
  try {
    if ($back) {
      Copy-Item $back.FullName $copiaH -Force
    } else {
      $junto = Get-ChildItem -Path (Split-Path $ORIGEN) -Filter 'cyberback*.mdb' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if (-not $junto) { throw 'No encontre cyberback.mdb (ni respaldo ni junto a cyber.mdb)' }
      Copiar-ConSombra $junto.FullName $copiaH
    }
    Comprimir $copiaH $gzh
    $kb = [math]::Round((Get-Item $gzh).Length / 1KB)
    $resp = Enviar-Archivo $gzh 'historial'
    Set-Content -Path $MARCA -Value $hoy -Encoding ASCII
    Log ('OK: historial enviado (' + $kb + ' KB) -> ' + $resp)
  } catch {
    Log ('ERROR historial: ' + $_.Exception.Message); Enviar-Error ('Historial: ' + $_.Exception.Message)
  } finally {
    Remove-Item $copiaH -Force -ErrorAction SilentlyContinue
    Remove-Item $gzh -Force -ErrorAction SilentlyContinue
  }
}
