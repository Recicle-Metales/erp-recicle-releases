param(
    [Parameter(Mandatory)][ValidateSet('Bascula', 'Embarques')][string] $Edition,
    [Parameter(Mandatory)][version] $Version,
    [switch] $ExistingInstaller,
    [ValidateRange(60, 900)][int] $UploadTimeoutSec = 300
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { throw 'Falta RELEASES_TOKEN.' }

$repo = 'Recicle-Metales/erp-recicle-releases'
$base = "https://api.github.com/repos/$repo"
$headers = @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$isEmbarques = $Edition -eq 'Embarques'
$tag = if ($isEmbarques) { "embarques-v$Version" } else { "v$Version" }
$manifestFile = if ($isEmbarques) { 'latest-embarques.json' } else { 'latest.json' }
$prefix = if ($isEmbarques) { 'ERP-Recicle-Embarques-Setup' } else { 'ERP-Recicle-Setup' }
$installerName = "$prefix-$Version.exe"
if (-not $ExistingInstaller) {
    $installer = Get-Item "installer/output/$installerName"
    if ($installer.Length -lt 100000) { throw 'El instalador generado es demasiado pequeño.' }
}

function Invoke-GitHub($Method, $Uri, $Body = $null) {
    $request = @{ Method = $Method; Uri = $Uri; Headers = $headers; TimeoutSec = 45 }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = $Body | ConvertTo-Json -Depth 8 -Compress
    }
    $response = Invoke-RestMethod @request
    $response
}

Write-Host "Consultando el canal $Edition."
$manifestUri = "$base/contents/${manifestFile}?ref=main"
$current = Invoke-GitHub GET $manifestUri
$old = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($current.content)) | ConvertFrom-Json
if ([version]$old.version -gt $Version) { throw 'El canal ya anuncia una versión superior.' }

Write-Host "Buscando la publicación $tag."
try { $release = Invoke-GitHub GET "$base/releases/tags/$tag" }
catch {
    if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
    $release = @(Invoke-GitHub GET "$base/releases?per_page=100") |
        Where-Object tag_name -EQ $tag | Select-Object -First 1
}
if (-not $release) {
    if ($ExistingInstaller) { throw "No existe el release $tag." }
    $name = if ($isEmbarques) { "ERP Recicle Embarques $Version" } else { "ERP Recicle $Version" }
    $notes = if ($isEmbarques) {
        if ($Version -eq [version]'0.1.19') { 'Sincroniza el catálogo de materiales administrado por Báscula y envía sus identificadores a Inventarios.' } elseif ($Version -eq [version]'0.1.17') { 'Envía entradas y salidas confirmadas a Inventarios PT con cola local y reintentos.' } else { 'Asigna varias pesadas del mismo lote a un renglón SGC y conserva el saldo para futuras cargas.' }
    } elseif ($Version -eq [version]'0.20.11') {
        'Publica el catálogo maestro de materiales para Embarques e Inventarios.'
    } else {
        'Relaciona las pesadas de entrada escaneadas en Cargas por su folio individual.'
    }
    $release = Invoke-GitHub POST "$base/releases" @{
        tag_name = $tag; target_commitish = 'main'; name = $name; body = $notes; draft = $true
    }
}

$releaseUri = "$base/releases/$($release.id)"
$assets = @(Invoke-GitHub GET "$releaseUri/assets")
if ($ExistingInstaller) {
    $existing = $assets | Where-Object { $_.name -ceq $installerName -and $_.state -eq 'uploaded' } | Select-Object -First 1
    if (-not $existing -or $existing.size -lt 100000 -or $existing.digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "El release no contiene el instalador completo $installerName con SHA-256."
    }
} else {
    $files = @($installer)
    if (-not $isEmbarques) {
        $previews = @(Get-ChildItem 'artifacts/label-previews/*.pdf')
        if ($previews.Count -lt 3) { throw 'No se generaron las muestras digitales.' }
        $stable = Join-Path $installer.Directory.FullName 'ERP-Recicle-Setup.exe'
        Copy-Item -LiteralPath $installer.FullName -Destination $stable -Force
        $files += (Get-Item -LiteralPath $stable)
        $files += $previews
    }
    foreach ($file in $files) {
        $asset = $assets | Where-Object name -CEQ $file.Name | Select-Object -First 1
        $localDigest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($asset -and $asset.state -eq 'uploaded') {
            if ($asset.digest -ne "sha256:$localDigest") { throw "La huella del archivo existente $($file.Name) no coincide." }
            continue
        }
        if ($asset -and $release.draft -and $asset.state -eq 'starter') {
            Write-Host "Retirando la carga incompleta de $($file.Name)."
            $null = Invoke-GitHub DELETE "$base/releases/assets/$($asset.id)"
        } elseif ($asset) {
            throw "GitHub dejó incompleto el archivo $($file.Name). Revisa la publicación antes de reintentar."
        }
        if (-not $release.draft) { throw "La publicación ya es pública y no contiene $($file.Name)." }
        Write-Host "Subiendo $($file.Name) ($($file.Length) bytes)."
        $upload = $release.upload_url.Split('{')[0] + '?name=' + [Uri]::EscapeDataString($file.Name)
        # Use the same managed HTTP transport as the metadata requests. InFile
        # sends the installer as binary; authorization stays in this process.
        try {
            $asset = Invoke-RestMethod -Method Post -Uri $upload -Headers $headers `
                -ContentType 'application/octet-stream' -InFile $file.FullName -TimeoutSec $UploadTimeoutSec
        } catch {
            # A lost HTTP response can follow a completed upload. Reconcile it
            # before reporting failure; never replace an already uploaded file.
            $asset = @(Invoke-GitHub GET "$releaseUri/assets") |
                Where-Object { $_.name -ceq $file.Name -and $_.state -eq 'uploaded' } |
                Select-Object -First 1
            if (-not $asset -or $asset.digest -ne "sha256:$localDigest") {
                throw "GitHub no confirmó la subida de $($file.Name). La copia verificada sigue disponible para reintentar."
            }
        }
        if ($asset.state -ne 'uploaded' -or $asset.digest -ne "sha256:$localDigest") {
            throw "La huella del archivo $($file.Name) no coincide."
        }
    }
}
if ($release.draft) {
    $latest = if ($isEmbarques) { 'false' } else { 'true' }
    $null = Invoke-GitHub PATCH $releaseUri @{ draft = $false; make_latest = $latest }
}
$published = Invoke-GitHub GET "$base/releases/tags/$tag"
$asset = @(Invoke-GitHub GET "$base/releases/$($published.id)/assets") |
    Where-Object { $_.name -ceq $installerName -and $_.state -eq 'uploaded' } | Select-Object -First 1
$expected = "https://github.com/$repo/releases/download/$tag/$($installerName)"
if ($published.draft -or $asset.digest -notmatch '^sha256:[a-f0-9]{64}$' -or $asset.browser_download_url -cne $expected) {
    throw 'No se pudo verificar el instalador publicado.'
}
$digest = $asset.digest.Substring(7)
$probe = Invoke-WebRequest -Uri $expected -Method Head -TimeoutSec 45
if ($probe.StatusCode -ne 200 -or [long]($probe.Headers['Content-Length'] | Select-Object -First 1) -ne $asset.size) {
    throw 'El enlace público no confirmó el tamaño del instalador.'
}
$current = Invoke-GitHub GET $manifestUri
$old = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($current.content)) | ConvertFrom-Json
if ([version]$old.version -gt $Version) { throw 'El canal ya anuncia una versión superior.' }
if ([version]$old.version -eq $Version -and $old.sha256 -eq $digest -and $old.installerUrl -eq $expected) { exit 0 }
if ([version]$old.version -eq $Version) { throw 'El canal ya anuncia esta versión con otro instalador.' }
$manifest = @{
    version = "$Version"; installerUrl = $expected; sha256 = $digest
    publishedAt = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json
$content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($manifest))
$null = Invoke-GitHub PUT "$base/contents/$manifestFile" @{
    message = "Publicar $Edition $Version"; content = $content; sha = $current.sha; branch = 'main'
}
$verified = Invoke-GitHub GET $manifestUri
$result = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($verified.content)) | ConvertFrom-Json
if ($result.version -ne "$Version" -or $result.installerUrl -cne $expected -or $result.sha256 -cne $digest) {
    throw 'El canal no confirmó el instalador publicado.'
}
Write-Host "Canal $Edition actualizado a $Version."
