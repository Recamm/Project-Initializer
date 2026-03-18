param(
    [string]$ConfigPath,
    [string]$Profile = "camil-default",
    [switch]$All,
    [switch]$PromptOnly,
    [switch]$NonInteractive,
    [switch]$AllowHighRisk,
    [int]$Retries = 2
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $scriptDir "initializer.config.json"
}

$logsDir = Join-Path $scriptDir "logs"
if (-not (Test-Path -LiteralPath $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir | Out-Null
}
$logFile = Join-Path $logsDir ("initializer_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
try {
    Start-Transcript -Path $logFile -Force | Out-Null
} catch {
    Write-Host "No se pudo iniciar transcript de log: $($_.Exception.Message)" -ForegroundColor Yellow
}

function Stop-WithError {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

function Invoke-WebRequestCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$OutFile,
        [string]$Method = "Get",
        [int]$TimeoutSec = 30
    )

    $cmd = Get-Command Invoke-WebRequest -ErrorAction Stop
    $params = @{
        Uri = $Uri
        ErrorAction = "Stop"
    }

    if ($OutFile) {
        $params.OutFile = $OutFile
    }
    if ($Method -and $cmd.Parameters.ContainsKey("Method")) {
        $params.Method = $Method
    }
    if ($TimeoutSec -gt 0 -and $cmd.Parameters.ContainsKey("TimeoutSec")) {
        $params.TimeoutSec = $TimeoutSec
    }
    if ($cmd.Parameters.ContainsKey("UseBasicParsing")) {
        $params.UseBasicParsing = $true
    }

    return Invoke-WebRequest @params
}

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonText
    )

    $cmd = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($cmd.Parameters.ContainsKey("Depth")) {
        return $JsonText | ConvertFrom-Json -Depth 20
    }
    return $JsonText | ConvertFrom-Json
}

function Test-Prerequisites {
    $missing = @()
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { $missing += "node" }
    if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { $missing += "npx" }

    if ($missing.Count -gt 0) {
        Stop-WithError ("Faltan prerequisitos: {0}. Instala Node.js y volve a ejecutar." -f ($missing -join ", "))
    }

    try {
        $null = Invoke-WebRequestCompat -Uri "https://raw.githubusercontent.com" -Method "Head" -TimeoutSec 8
        Write-Host "Conectividad OK: acceso a raw.githubusercontent.com" -ForegroundColor DarkGreen
    } catch {
        Write-Host "No se pudo validar conectividad a internet. Continuo, pero puede fallar la instalacion." -ForegroundColor Yellow
    }
}

function Resolve-NpxExecutable {
    # En Windows, Start-Process puede fallar con ciertos shims de npx.
    # Priorizamos npx.cmd/npx.exe para invocar un ejecutable valido.
    $candidates = @("npx")
    if ($env:OS -eq "Windows_NT") {
        $candidates = @("npx.cmd", "npx.exe", "npx")
    }

    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) {
            if ($cmd.Source) {
                return $cmd.Source
            }
            return $candidate
        }
    }

    Stop-WithError "No se encontro un ejecutable valido para npx en PATH."
}

function Load-Config {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Stop-WithError ("No existe archivo de configuracion: {0}" -f $Path)
    }

    try {
        $jsonText = Get-Content -LiteralPath $Path -Raw
        return ConvertFrom-JsonCompat -JsonText $jsonText
    } catch {
        Stop-WithError ("No se pudo leer/parsear la configuracion JSON: {0}" -f $_.Exception.Message)
    }
}

function Get-DefaultItems {
    param([object]$Config)

    $result = @()
    foreach ($task in $Config.tasks) {
        $result += [pscustomobject]@{
            Id = $task.id
            Label = $task.label
            Type = $task.type
            Repo = $task.repo
            Skill = $task.skill
            RiskHint = if ($task.riskHint) { $task.riskHint } else { "low" }
            Selected = [bool]$task.defaultSelected
        }
    }
    return $result
}

function Apply-ProfileSelection {
    param(
        [array]$Items,
        [object]$Config,
        [string]$ProfileName
    )

    $profile = $Config.profiles | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if (-not $profile) {
        Stop-WithError ("Perfil no encontrado: {0}" -f $ProfileName)
    }

    foreach ($i in $Items) { $i.Selected = $false }
    foreach ($taskId in $profile.taskIds) {
        $target = $Items | Where-Object { $_.Id -eq $taskId } | Select-Object -First 1
        if ($target) { $target.Selected = $true }
    }

    return $profile
}

function Apply-PromptOnlySelection {
    param([array]$Items)

    foreach ($i in $Items) {
        $i.Selected = ($i.Type -eq "prompt-download")
    }
}

function Apply-AllSelection {
    param([array]$Items)
    foreach ($i in $Items) { $i.Selected = $true }
}

function Draw-Menu {
    param(
        [array]$Items,
        [int]$CurrentIndex,
        [string]$ActiveProfile
    )

    Clear-Host
    Write-Host "==============================================================" -ForegroundColor DarkCyan
    Write-Host "              PROJECT INITIALIZER - INTERACTIVE" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor DarkCyan
    Write-Host ("Active profile: {0}" -f $ActiveProfile) -ForegroundColor Gray
    Write-Host "Up/Down move | Space toggle | Enter run | A all | N none | P cycle profile" -ForegroundColor Gray
    Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $cursor = if ($i -eq $CurrentIndex) { ">" } else { " " }
        $flag = if ($Items[$i].Selected) { "[X]" } else { "[ ]" }
        $line = "{0} {1} {2}" -f $cursor, $flag, $Items[$i].Label

        if ($i -eq $CurrentIndex) {
            Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
        } else {
            Write-Host $line -ForegroundColor White
        }
    }

    Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray
}

function Confirm-HighRisk {
    param(
        [pscustomobject]$Item,
        [switch]$Allow,
        [switch]$IsNonInteractive
    )

    if ($Item.RiskHint -ne "high") { return $true }
    if ($Allow) { return $true }

    if ($IsNonInteractive) {
        Write-Host ("Saltando {0} por riesgo alto en modo no interactivo. Usa -AllowHighRisk para permitir." -f $Item.Label) -ForegroundColor Yellow
        return $false
    }

    Write-Host "" 
    Write-Host ("ALERTA: {0} esta marcada como HIGH RISK." -f $Item.Label) -ForegroundColor Yellow
    $answer = Read-Host "Queres continuar con esta instalacion? (y/n)"
    return ($answer -match "^(y|yes|s|si)$")
}

function Invoke-CommandWithRetry {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$RetryCount,
        [string]$DisplayCommand
    )

    $attempt = 0
    $lastCode = 1
    $lastError = ""

    do {
        $attempt++
        Write-Host ("Intento {0}/{1}: {2}" -f $attempt, ($RetryCount + 1), $DisplayCommand) -ForegroundColor DarkGray

        try {
            if ($env:OS -eq "Windows_NT") {
                # En Windows, cmd.exe maneja correctamente wrappers .cmd/.bat como npx.cmd.
                $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/d", "/s", "/c", $DisplayCommand -NoNewWindow -Wait -PassThru -WorkingDirectory $WorkingDirectory
            } else {
                $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -WorkingDirectory $WorkingDirectory
            }
            $lastCode = $process.ExitCode
            if ($lastCode -eq 0) {
                return [pscustomobject]@{ Success = $true; ExitCode = 0; Error = "" }
            }
        } catch {
            $lastCode = -1
            $lastError = $_.Exception.Message
            Write-Host ("Error ejecutando comando: {0}" -f $lastError) -ForegroundColor Yellow
        }

        if ($attempt -le $RetryCount) {
            Start-Sleep -Seconds 2
            Write-Host "Reintentando por fallo transitorio..." -ForegroundColor Yellow
        }
    } while ($attempt -le $RetryCount)

    return [pscustomobject]@{ Success = $false; ExitCode = $lastCode; Error = $lastError }
}

function Execute-CommandItem {
    param(
        [pscustomobject]$Item,
        [string]$WorkingDirectory,
        [int]$RetryCount,
        [switch]$AllowHighRisk,
        [switch]$IsNonInteractive
    )

    Write-Host ""
    Write-Host ("Running: {0}" -f $Item.Label) -ForegroundColor Yellow

    if (-not $IsNonInteractive) {
        try {
            while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
        } catch {
            # Ignorar cuando no hay consola interactiva (ej. ejecucion por pipe/redireccion)
        }
    }

    if (-not (Confirm-HighRisk -Item $Item -Allow:$AllowHighRisk -IsNonInteractive:$IsNonInteractive)) {
        return [pscustomobject]@{
            Label = $Item.Label
            Success = $false
            ExitCode = 2
            Detail = "Bloqueado por politica de riesgo."
            RetryCommand = "npx skills add {repo} --skill {skill}"
        }
    }

    $npxExecutable = Resolve-NpxExecutable

    if ($Item.Type -eq "skill-add") {
        $commandLine = "npx skills add $($Item.Repo) --skill $($Item.Skill)"
        $filePath = $npxExecutable
        $arguments = @("skills", "add", $Item.Repo, "--skill", $Item.Skill)
    } elseif ($Item.Type -eq "skills-update") {
        $commandLine = "npx skills update"
        $filePath = $npxExecutable
        $arguments = @("skills", "update")
    } else {
        return [pscustomobject]@{
            Label = $Item.Label
            Success = $false
            ExitCode = 1
            Detail = "Tipo de comando no soportado"
            RetryCommand = ""
        }
    }

    Write-Host "Interactive installer enabled in this same terminal." -ForegroundColor DarkGray
    $run = Invoke-CommandWithRetry -FilePath $filePath -Arguments $arguments -WorkingDirectory $WorkingDirectory -RetryCount $RetryCount -DisplayCommand $commandLine

    $detail = $Item.Label
    if (-not $run.Success -and $run.Error) {
        $detail = $run.Error
    }

    return [pscustomobject]@{
        Label = $Item.Label
        Success = $run.Success
        ExitCode = $run.ExitCode
        Detail = $detail
        RetryCommand = $commandLine
    }
}

function Execute-PromptDownload {
    param(
        [pscustomobject]$Item,
        [array]$Sources,
        [string]$WorkingDirectory,
        [int]$RetryCount
    )

    $promptDir = Join-Path $WorkingDirectory "prompts"
    $outputFile = Join-Path $promptDir "v0.txt"

    Write-Host ""
    Write-Host ("Running: {0}" -f $Item.Label) -ForegroundColor Yellow

    try {
        if (-not (Test-Path -LiteralPath $promptDir)) {
            New-Item -ItemType Directory -Path $promptDir | Out-Null
        }

        $downloaded = $false
        $lastErrorText = ""

        foreach ($url in $Sources) {
            $attempt = 0
            do {
                $attempt++
                try {
                    Invoke-WebRequestCompat -Uri $url -OutFile $outputFile -Method "Get" -TimeoutSec 30 | Out-Null
                    $downloaded = $true
                    break
                } catch {
                    $lastErrorText = $_.Exception.Message
                    if ($attempt -le $RetryCount) {
                        Start-Sleep -Seconds 2
                    }
                }
            } while ($attempt -le $RetryCount)

            if ($downloaded) { break }
        }

        if (-not $downloaded) {
            throw ("No se pudo descargar Prompt.txt. Ultimo error: {0}" -f $lastErrorText)
        }

        return [pscustomobject]@{
            Label = $Item.Label
            Success = $true
            ExitCode = 0
            Detail = ("Saved to {0}" -f $outputFile)
            RetryCommand = ""
        }
    } catch {
        return [pscustomobject]@{
            Label = $Item.Label
            Success = $false
            ExitCode = 1
            Detail = $_.Exception.Message
            RetryCommand = ("Invoke-WebRequest -Uri <url> -OutFile `"{0}`"" -f $outputFile)
        }
    }
}

Test-Prerequisites
$config = Load-Config -Path $ConfigPath
$items = Get-DefaultItems -Config $config

$profileNames = @($config.profiles | ForEach-Object { $_.name })
if ($profileNames.Count -eq 0) {
    Stop-WithError "No hay perfiles definidos en initializer.config.json"
}
if (-not ($profileNames -contains $Profile)) {
    Stop-WithError ("Perfil invalido: {0}. Disponibles: {1}" -f $Profile, ($profileNames -join ", "))
}

$activeProfile = Apply-ProfileSelection -Items $items -Config $config -ProfileName $Profile

if ($PromptOnly) {
    Apply-PromptOnlySelection -Items $items
    $Profile = "prompt-only"
} elseif ($All) {
    Apply-AllSelection -Items $items
    $Profile = "all"
}

if (-not $NonInteractive -and -not $All -and -not $PromptOnly) {
    $currentIndex = 0
    $profileIndex = [array]::IndexOf($profileNames, $Profile)
    if ($profileIndex -lt 0) { $profileIndex = 0 }
    $startExecution = $false

    while (-not $startExecution) {
        Draw-Menu -Items $items -CurrentIndex $currentIndex -ActiveProfile $Profile
        $keyInfo = [Console]::ReadKey($true)

        switch ($keyInfo.Key) {
            ([System.ConsoleKey]::UpArrow) {
                if ($currentIndex -gt 0) { $currentIndex-- } else { $currentIndex = $items.Count - 1 }
            }
            ([System.ConsoleKey]::DownArrow) {
                if ($currentIndex -lt ($items.Count - 1)) { $currentIndex++ } else { $currentIndex = 0 }
            }
            ([System.ConsoleKey]::Spacebar) {
                $items[$currentIndex].Selected = -not $items[$currentIndex].Selected
            }
            ([System.ConsoleKey]::A) {
                Apply-AllSelection -Items $items
            }
            ([System.ConsoleKey]::N) {
                foreach ($entry in $items) { $entry.Selected = $false }
            }
            ([System.ConsoleKey]::P) {
                $profileIndex = ($profileIndex + 1) % $profileNames.Count
                $Profile = $profileNames[$profileIndex]
                [void](Apply-ProfileSelection -Items $items -Config $config -ProfileName $Profile)
            }
            ([System.ConsoleKey]::Enter) {
                $startExecution = $true
            }
        }
    }
}

Clear-Host
Write-Host "==============================================================" -ForegroundColor DarkCyan
Write-Host "Executing selected tasks..." -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor DarkCyan
Write-Host ("Log file: {0}" -f $logFile) -ForegroundColor DarkGray

$selectedItems = $items | Where-Object { $_.Selected }
if ($selectedItems.Count -eq 0) {
    Write-Host "No items selected. Nothing to run." -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

$results = @()
foreach ($item in $selectedItems) {
    if ($item.Type -eq "prompt-download") {
        $results += Execute-PromptDownload -Item $item -Sources $config.promptSources -WorkingDirectory $scriptDir -RetryCount $Retries
    } else {
        $results += Execute-CommandItem -Item $item -WorkingDirectory $scriptDir -RetryCount $Retries -AllowHighRisk:$AllowHighRisk -IsNonInteractive:$NonInteractive
    }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor DarkCyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor DarkCyan

$failedCount = 0
foreach ($result in $results) {
    if ($result.Success) {
        Write-Host ("[OK]   {0}" -f $result.Label) -ForegroundColor Green
    } else {
        $failedCount++
        Write-Host ("[FAIL] {0} (code {1})" -f $result.Label, $result.ExitCode) -ForegroundColor Red
        Write-Host ("       Reason: {0}" -f $result.Detail) -ForegroundColor DarkRed
        if ($result.RetryCommand) {
            Write-Host ("       Retry:  {0}" -f $result.RetryCommand) -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Gray
Write-Host "1) Revisa el log si hubo fallos." -ForegroundColor Gray
Write-Host ("2) Log path: {0}" -f $logFile) -ForegroundColor Gray
Write-Host "3) Reintenta solo los comandos fallidos con la linea Retry." -ForegroundColor Gray

if ($failedCount -eq 0) {
    Write-Host "All selected tasks completed successfully." -ForegroundColor Green
    $exitCode = 0
} else {
    Write-Host ("Completed with {0} failed task(s)." -f $failedCount) -ForegroundColor Yellow
    $exitCode = 1
}

try { Stop-Transcript | Out-Null } catch {}
exit $exitCode
