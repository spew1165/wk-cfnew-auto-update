# step-kv.ps1 - Create KV Namespace and bind to Worker
# Usage: .\step-kv.ps1 <KVName>

param(
    [Parameter(Mandatory=$true)]
    [string]$KvName
)

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$WranglerToml = Join-Path $ProjectDir "wrangler.toml"
$LogFile = Join-Path $ScriptDir "step-kv.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] $Message"
    Write-Host $logMsg
    Add-Content -Path $LogFile -Value $logMsg -Encoding UTF8
}

function Write-Err {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Log "ERROR: $Message"
}

function Generate-RandomSuffix {
    $chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    $result = "-"
    for ($i = 0; $i -lt 4; $i++) {
        $result += $chars[(Get-Random -Maximum $chars.Length)]
    }
    return $result
}

function Test-KvExists {
    param([string]$Name)
    try {
        $output = npx wrangler kv namespace list 2>&1 | Out-String
        if ($output -match "\[") {
            $json = $output | ConvertFrom-Json
            if ($json -is [Array]) {
                return ($null -ne ($json | Where-Object { $_.title -eq $Name }))
            } elseif ($null -ne $json) {
                return ($json.title -eq $Name)
            }
        }
        return $false
    } catch {
        return $false
    }
}

function New-KvNamespace {
    param([string]$Name)

    Write-Log "Creating KV: $Name"

    $output = npx wrangler kv namespace create $Name --binding "C" --update-config 2>&1 | Out-String

    Write-Log "Output: $output"

    if ($output -match "id = `"(.*?)`"") {
        return $matches[1]
    }

    Write-Err "Failed to extract KV ID"
    return $null
}

function Update-WranglerToml {
    param([string]$KvId)

    Write-Log "Updating wrangler.toml with KV ID: $KvId"

    if (-not (Test-Path $WranglerToml)) {
        Write-Err "wrangler.toml not found"
        return $false
    }

    $content = Get-Content $WranglerToml -Raw -Encoding UTF8

    $newContent = $content + "`n`n[[kv_namespaces]]`n`nbinding = `"C`"`nid = `"$KvId`""

    Set-Content -Path $WranglerToml -Value $newContent -Encoding UTF8 -NoNewline

    Write-Log "wrangler.toml updated"
    return $true
}

# Main
Write-Host ""
Write-Host "========== KV Creation Script ==========" -ForegroundColor Cyan
Write-Log "Starting KV creation for: $KvName"

Set-Location $ProjectDir

$finalName = $KvName
$maxAttempts = 10
$attempt = 0

while ($attempt -lt $maxAttempts) {
    if (-not (Test-KvExists -Name $finalName)) {
        break
    }
    $suffix = Generate-RandomSuffix
    $finalName = "$KvName$suffix"
    $attempt++
}

if ($attempt -ge $maxAttempts) {
    Write-Err "Failed to generate unique name"
    exit 1
}

Write-Host "Using KV name: $finalName" -ForegroundColor Yellow

$kvId = New-KvNamespace -Name $finalName

if ([string]::IsNullOrEmpty($kvId)) {
    Write-Err "Failed to create KV"
    exit 1
}

Write-Host "KV created: $kvId" -ForegroundColor Green

$success = Update-WranglerToml -KvId $kvId

if (-not $success) {
    Write-Err "Failed to update wrangler.toml"
    exit 1
}

Write-Host ""
Write-Host "========== SUCCESS ==========" -ForegroundColor Green
Write-Host "KV Name: $finalName"
Write-Host "KV ID: $kvId"
Write-Host "wrangler.toml: Updated"
Write-Host ""
Write-Host "Next: npm run deploy"
Write-Log "Done"
