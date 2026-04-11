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

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
    Write-Log $Message
}

function Write-Success {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
    Write-Log $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
    Write-Log "WARN: $Message"
}

function Write-Err {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Log "ERROR: $Message"
}

function Get-ExistingKvId {
    param([string]$Name)
    try {
        Write-Log "Checking if KV namespace '$Name' already exists..."
        $output = npx wrangler kv namespace list 2>&1 | Out-String

        if ($output -match "\[") {
            $json = $output | ConvertFrom-Json
            if ($json -is [Array]) {
                $existing = $json | Where-Object { $_.title -eq $Name } | Select-Object -First 1
                if ($null -ne $existing) {
                    Write-Log "Found existing KV: $Name with ID: $($existing.id)"
                    return $existing.id
                }
            } elseif ($null -ne $json -and $json.title -eq $Name) {
                Write-Log "Found existing KV: $Name with ID: $($json.id)"
                return $json.id
            }
        }
        Write-Log "KV namespace '$Name' does not exist"
        return $null
    } catch {
        Write-Log "Error checking KV existence: $_"
        return $null
    }
}

function New-KvNamespace {
    param([string]$Name)

    Write-Log "Creating new KV namespace: $Name"

    try {
        $output = npx wrangler kv namespace create $Name --binding "C" --update-config 2>&1 | Out-String
        Write-Log "Wrangler output: $output"

        if ($output -match "id = `"(.*?)`"") {
            $kvId = $matches[1]
            Write-Success "KV created successfully with ID: $kvId"
            return $kvId
        }

        if ($output -match "Error|error|ERROR") {
            Write-Err "KV creation failed: $output"
            return $null
        }

        Write-Err "Failed to extract KV ID from output"
        return $null
    } catch {
        Write-Err "Exception during KV creation: $_"
        return $null
    }
}

function Update-WranglerTomlConfig {
    param(
        [string]$KvId,
        [string]$KvName
    )

    Write-Log "Updating wrangler.toml with KV ID: $KvId"

    if (-not (Test-Path $WranglerToml)) {
        Write-Err "wrangler.toml not found at: $WranglerToml"
        return $false
    }

    try {
        $content = Get-Content $WranglerToml -Raw -Encoding UTF8

        if ($content -match '(id\s*=\s*")[^"]*(")') {
            $content = $content -replace ($matches[1] + '[^"]*' + $matches[2]), ($matches[1] + $KvId + $matches[2])
            Write-Log "Updated existing KV ID in wrangler.toml"
        } elseif ($content -match '\[\[kv_namespaces\]\]') {
            $content = $content -replace '(\[\[kv_namespaces\]\][\s\S]*?)(id\s*=\s*")[^"]*(")', "`$1$($KvId)`$3"
            Write-Log "Added KV ID to existing [[kv_namespaces]] section"
        } else {
            Write-Log "No existing [[kv_namespaces]] section, appending..."
            $kvSection = @"

[[kv_namespaces]]
binding = "C"
id = "$KvId"
"@
            if ($content -notLike "`n`n*") {
                $content += "`n`n"
            }
            $content += $kvSection
        }

        Set-Content -Path $WranglerToml -Value $content -Encoding UTF8 -NoNewline
        Write-Success "wrangler.toml updated successfully"
        return $true
    } catch {
        Write-Err "Failed to update wrangler.toml: $_"
        return $false
    }
}

function Find-DocumentationFiles {
    $docExtensions = @("*.md", "*.txt", "*.json", "*.yaml", "*.yml")
    $excludeDirs = @("node_modules", ".git", "dist", "build", "coverage")

    $docs = @()
    foreach ($ext in $docExtensions) {
        $docs += Get-ChildItem -Path $ProjectDir -Recurse -Include $ext -File -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -notmatch ($excludeDirs -join '|') }
    }
    return $docs
}

function Update-DocumentationKvId {
    param(
        [string]$OldKvId,
        [string]$NewKvId,
        [string]$KvName
    )

    if ([string]::IsNullOrEmpty($OldKvId)) {
        Write-Log "No old KV ID provided, skipping documentation update"
        return
    }

    Write-Log "Checking documentation files for KV ID updates..."

    $docs = Find-DocumentationFiles
    $updatedCount = 0

    foreach ($doc in $docs) {
        try {
            $content = Get-Content $doc.FullName -Raw -Encoding UTF8
            if ($content -match [regex]::Escape($OldKvId)) {
                $newContent = $content -replace [regex]::Escape($OldKvId), $NewKvId
                Set-Content -Path $doc.FullName -Value $newContent -Encoding UTF8
                Write-Log "Updated KV ID in: $($doc.FullName)"
                $updatedCount++
            }
        } catch {
            Write-Warn "Failed to update $($doc.FullName): $_"
        }
    }

    if ($updatedCount -gt 0) {
        Write-Success "Updated $updatedCount documentation file(s)"
    } else {
        Write-Log "No documentation files needed updating"
    }
}

function Main {
    Write-Host ""
    Write-Host "========== KV Namespace Management ==========" -ForegroundColor Cyan
    Write-Log "Starting KV namespace management for: $KvName"

    if (-not (Test-Path $WranglerToml)) {
        Write-Err "wrangler.toml not found at: $WranglerToml"
        exit 1
    }

    $currentKvId = $null
    $content = Get-Content $WranglerToml -Raw -Encoding UTF8
    if ($content -match 'id\s*=\s*"(.*?)"') {
        $currentKvId = $matches[1]
        Write-Log "Current KV ID in wrangler.toml: $currentKvId"
    }

    Set-Location $ProjectDir

    $existingKvId = Get-ExistingKvId -Name $KvName

    $kvIdToUse = $null
    $isNewKv = $false

    if ($null -ne $existingKvId) {
        Write-Info "KV namespace '$KvName' already exists with ID: $existingKvId"
        $kvIdToUse = $existingKvId

        if ($existingKvId -eq $currentKvId) {
            Write-Info "Current wrangler.toml already uses this KV ID, no update needed"
        } else {
            Write-Info "Updating wrangler.toml to use existing KV ID..."
            $success = Update-WranglerTomlConfig -KvId $kvIdToUse -KvName $KvName
            if (-not $success) {
                Write-Err "Failed to update wrangler.toml"
                exit 1
            }
            if ($null -ne $currentKvId) {
                Update-DocumentationKvId -OldKvId $currentKvId -NewKvId $kvIdToUse -KvName $KvName
            }
        }
    } else {
        Write-Info "KV namespace '$KvName' does not exist, creating new one..."
        $kvIdToUse = New-KvNamespace -Name $KvName

        if ([string]::IsNullOrEmpty($kvIdToUse)) {
            Write-Err "Failed to create KV namespace"
            exit 1
        }

        $isNewKv = $true
        $success = Update-WranglerTomlConfig -KvId $kvIdToUse -KvName $KvName

        if (-not $success) {
            Write-Err "Failed to update wrangler.toml"
            exit 1
        }

        if ($null -ne $currentKvId) {
            Update-DocumentationKvId -OldKvId $currentKvId -NewKvId $kvIdToUse -KvName $KvName
        }
    }

    Write-Host ""
    Write-Host "========== SUCCESS ==========" -ForegroundColor Green
    if ($isNewKv) {
        Write-Success "New KV namespace created: $KvName"
    } else {
        Write-Success "Using existing KV namespace: $KvName"
    }
    Write-Success "KV ID: $kvIdToUse"
    Write-Success "wrangler.toml: Updated"
    Write-Host ""
    Write-Host "Next: npm run deploy" -ForegroundColor Cyan
    Write-Log "Done"
}

Main
