# --------------------------------------------------------------------------
#  helpers/catalog-update.ps1
#  Hugging Face GGUF catalog auto-update proposer for Script 43.
#  Implements spec/2025-batch/suggestions/01-catalog-auto-update.md.
#
#  Public functions:
#    Invoke-CatalogUpdateCheck  -- main entry point
#    Merge-CatalogProposals     -- --apply path (manual review then merge)
#
#  Behavior summary:
#    1. Read models-catalog.json, group existing entries by `family`.
#    2. Hit HF API per family (cached 6h under .cache/hf-<family>.json).
#    3. List *.gguf files in each repo's tree.
#    4. Filter out entries already present in the catalog (by HF page
#       host+path prefix match).
#    5. Write proposals to .proposed/catalog-additions-<date>.json.
#       Never mutate models-catalog.json directly (use --apply for that).
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

# -- Module-scope constants --------------------------------------------------
$script:HfApiBase           = "https://huggingface.co/api/models"
$script:HfRepoTreeApi       = "https://huggingface.co/api/models/{0}/tree/main?recursive=true"
$script:HfResolveBase       = "https://huggingface.co/{0}/resolve/main/{1}"
$script:HfPageBase          = "https://huggingface.co/{0}"
$script:CacheTtlHours       = 6
$script:MaxFamiliesPerRun   = 10
$script:MaxReposPerFamily   = 20
$script:MaxFilesPerRepo     = 50

# --------------------------------------------------------------------------
function Get-CatalogFamilyMap {
    param(
        [Parameter(Mandatory)] [string] $CatalogPath
    )

    $isMissing = -not (Test-Path -LiteralPath $CatalogPath)
    if ($isMissing) {
        Write-Log "Catalog file not found: $CatalogPath (failure: catalog missing for update check)" -Level "error"
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop
        $catalog = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "Failed to parse catalog JSON: $CatalogPath (failure: $($_.Exception.Message))" -Level "error"
        return $null
    }

    $hasModels = $catalog.PSObject.Properties.Name -contains "models"
    if (-not $hasModels) {
        Write-Log "Catalog has no 'models' array: $CatalogPath (failure: schema mismatch)" -Level "error"
        return $null
    }

    $families = @{}
    $existingPagePrefixes = New-Object System.Collections.Generic.HashSet[string]

    foreach ($model in $catalog.models) {
        $hasFamily = $model.PSObject.Properties.Name -contains "family"
        if (-not $hasFamily) { continue }
        $familyName = [string]$model.family
        $isFamilyBlank = [string]::IsNullOrWhiteSpace($familyName)
        if ($isFamilyBlank) { continue }

        if (-not $families.ContainsKey($familyName)) {
            $families[$familyName] = @()
        }
        $families[$familyName] += $model

        $hasPage = $model.PSObject.Properties.Name -contains "huggingfacePage"
        if ($hasPage -and -not [string]::IsNullOrWhiteSpace($model.huggingfacePage)) {
            $normalized = ($model.huggingfacePage.TrimEnd('/')).ToLowerInvariant()
            [void]$existingPagePrefixes.Add($normalized)
        }
    }

    return [pscustomobject]@{
        Families             = $families
        ExistingPagePrefixes = $existingPagePrefixes
        Catalog              = $catalog
    }
}

# --------------------------------------------------------------------------
function Get-FamilySearchTerm {
    param([string] $FamilyName)

    # Catalog families look like "Alibaba Qwen", "Meta Llama", "Google Gemma".
    # HF search works better with the brand suffix only.
    $tokens = $FamilyName -split '\s+' | Where-Object { $_ }
    $hasMultiple = $tokens.Count -gt 1
    if ($hasMultiple) { return $tokens[-1] }
    return $FamilyName
}

# --------------------------------------------------------------------------
function Get-HfFamilyResults {
    param(
        [Parameter(Mandatory)] [string] $CacheDir,
        [Parameter(Mandatory)] [string] $FamilyName,
        [Parameter(Mandatory)] [string] $SearchTerm
    )

    $isCacheMissing = -not (Test-Path -LiteralPath $CacheDir)
    if ($isCacheMissing) {
        try {
            New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null
        } catch {
            Write-Log "Failed to create cache directory: $CacheDir (failure: $($_.Exception.Message))" -Level "error"
            return $null
        }
    }

    $safeName  = ($FamilyName -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLowerInvariant()
    $cacheFile = Join-Path $CacheDir ("hf-{0}.json" -f $safeName)

    $hasCache = Test-Path -LiteralPath $cacheFile
    if ($hasCache) {
        $cacheAge = (Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime
        $isFresh  = $cacheAge.TotalHours -lt $script:CacheTtlHours
        if ($isFresh) {
            try {
                $cached = Get-Content -LiteralPath $cacheFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                Write-Log "[CACHED] $FamilyName -> $cacheFile (age: $([int]$cacheAge.TotalMinutes)m)" -Level "info"
                return $cached
            } catch {
                Write-Log "Cache read failed, refetching: $cacheFile (failure: $($_.Exception.Message))" -Level "warn"
            }
        }
    }

    $query = [System.Uri]::EscapeDataString("$SearchTerm gguf")
    $url   = "{0}?search={1}&sort=lastModified&limit={2}" -f $script:HfApiBase, $query, $script:MaxReposPerFamily

    Write-Log "[CHECK] $FamilyName -> $url" -Level "info"

    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30 -ErrorAction Stop -UserAgent "gitmap-v6-catalog-update/1.0"
    } catch {
        Write-Log "HF API request failed for family '$FamilyName' at $url (failure: $($_.Exception.Message))" -Level "error"
        return $null
    }

    try {
        ($response | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $cacheFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "Failed to write cache file: $cacheFile (failure: $($_.Exception.Message))" -Level "warn"
    }

    return $response
}

# --------------------------------------------------------------------------
function Get-RepoGgufFiles {
    param(
        [Parameter(Mandatory)] [string] $CacheDir,
        [Parameter(Mandatory)] [string] $RepoId
    )

    $safeRepo  = ($RepoId -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLowerInvariant()
    $cacheFile = Join-Path $CacheDir ("tree-{0}.json" -f $safeRepo)

    $hasCache = Test-Path -LiteralPath $cacheFile
    if ($hasCache) {
        $cacheAge = (Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime
        $isFresh  = $cacheAge.TotalHours -lt $script:CacheTtlHours
        if ($isFresh) {
            try {
                return Get-Content -LiteralPath $cacheFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Write-Log "Tree cache read failed: $cacheFile (failure: $($_.Exception.Message))" -Level "warn"
            }
        }
    }

    $url = $script:HfRepoTreeApi -f $RepoId
    try {
        $tree = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30 -ErrorAction Stop -UserAgent "gitmap-v6-catalog-update/1.0"
    } catch {
        Write-Log "HF tree request failed for repo '$RepoId' at $url (failure: $($_.Exception.Message))" -Level "warn"
        return @()
    }

    $ggufFiles = @($tree | Where-Object {
        ($_.PSObject.Properties.Name -contains "type") -and
        ($_.type -eq "file") -and
        ($_.PSObject.Properties.Name -contains "path") -and
        ($_.path -like "*.gguf")
    })

    try {
        ($ggufFiles | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $cacheFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "Failed to write tree cache: $cacheFile (failure: $($_.Exception.Message))" -Level "warn"
    }

    return $ggufFiles
}

# --------------------------------------------------------------------------
function New-ProposalEntry {
    param(
        [Parameter(Mandatory)] [string] $FamilyName,
        [Parameter(Mandatory)] [object] $Repo,
        [Parameter(Mandatory)] [object] $File
    )

    $repoId    = [string]$Repo.id
    $fileName  = Split-Path -Leaf ([string]$File.path)
    $page      = $script:HfPageBase    -f $repoId
    $download  = $script:HfResolveBase -f $repoId, ([string]$File.path)

    # ID placeholder: <last-segment-of-repo>-<file-stem>, lowercased.
    $repoLeaf  = ($repoId -split '/')[-1]
    $fileStem  = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $idCandidate = ("{0}-{1}" -f $repoLeaf, $fileStem).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $idCandidate = $idCandidate.Trim('-')

    $sizeBytes = 0
    $hasSize   = $File.PSObject.Properties.Name -contains "size"
    if ($hasSize) { $sizeBytes = [int64]$File.size }
    $sizeGb    = if ($sizeBytes -gt 0) { [math]::Round($sizeBytes / 1GB, 2) } else { 0 }

    return [ordered]@{
        id                = $idCandidate
        displayName       = "TODO $repoLeaf"
        family            = $FamilyName
        parameters        = "TODO"
        quantization      = "TODO"
        fileSizeGB        = $sizeGb
        fileName          = $fileName
        ramRequiredGB     = 0
        ramRecommendedGB  = 0
        isCoding          = $false
        isReasoning       = $false
        isVoice           = $false
        isWriting         = $false
        isMultilingual    = $false
        isChat            = $false
        rating            = [ordered]@{
            coding    = 0
            reasoning = 0
            speed     = 0
            overall   = 0
        }
        bestFor           = "TODO"
        notes             = "TODO"
        source            = "TODO"
        license           = "TODO"
        downloadUrl       = $download
        huggingfacePage   = $page
        sha256            = ""
        proposalMeta      = [ordered]@{
            repoId        = $repoId
            sizeBytes     = $sizeBytes
            lastModified  = if ($Repo.PSObject.Properties.Name -contains "lastModified") { [string]$Repo.lastModified } else { "" }
            downloads     = if ($Repo.PSObject.Properties.Name -contains "downloads")    { [int]$Repo.downloads }       else { 0 }
            likes         = if ($Repo.PSObject.Properties.Name -contains "likes")        { [int]$Repo.likes }           else { 0 }
        }
    }
}

# --------------------------------------------------------------------------
function Test-RepoAlreadyKnown {
    param(
        [Parameter(Mandatory)] [object] $Repo,
        [Parameter(Mandatory)] $ExistingPagePrefixes
    )

    $repoId   = [string]$Repo.id
    $repoPage = ($script:HfPageBase -f $repoId).TrimEnd('/').ToLowerInvariant()

    foreach ($prefix in $ExistingPagePrefixes) {
        $isExact      = $repoPage -eq $prefix
        $isUnderPath  = $repoPage.StartsWith($prefix + "/")
        $isParent     = $prefix.StartsWith($repoPage + "/")
        if ($isExact -or $isUnderPath -or $isParent) { return $true }
    }
    return $false
}

# --------------------------------------------------------------------------
function Invoke-CatalogUpdateCheck {
    param(
        [Parameter(Mandatory)] [string] $CatalogPath,
        [Parameter(Mandatory)] [string] $ScriptDir,
        [string] $FamilyFilter = "",
        [switch] $Apply
    )

    Write-Log "Catalog auto-update check starting (catalog: $CatalogPath)" -Level "info"

    $loaded = Get-CatalogFamilyMap -CatalogPath $CatalogPath
    $isLoadFailed = $null -eq $loaded
    if ($isLoadFailed) { return }

    $cacheDir    = Join-Path $ScriptDir ".cache"
    $proposedDir = Join-Path $ScriptDir ".proposed"

    foreach ($dir in @($cacheDir, $proposedDir)) {
        $isMissing = -not (Test-Path -LiteralPath $dir)
        if ($isMissing) {
            try {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            } catch {
                Write-Log "Failed to create directory: $dir (failure: $($_.Exception.Message))" -Level "error"
                return
            }
        }
    }

    $familyNames = @($loaded.Families.Keys | Sort-Object)
    $hasFilter   = -not [string]::IsNullOrWhiteSpace($FamilyFilter)
    if ($hasFilter) {
        $familyNames = @($familyNames | Where-Object { $_ -ieq $FamilyFilter -or $_ -ilike "*$FamilyFilter*" })
        $isEmptyAfterFilter = $familyNames.Count -eq 0
        if ($isEmptyAfterFilter) {
            Write-Log "No catalog families matched filter '$FamilyFilter'." -Level "warn"
            return
        }
    }

    $familiesToScan = @($familyNames | Select-Object -First $script:MaxFamiliesPerRun)
    Write-Log "Scanning $($familiesToScan.Count) families (cap: $script:MaxFamiliesPerRun)..." -Level "info"

    $proposals = @()
    $stats = [ordered]@{
        familiesScanned = 0
        reposExamined   = 0
        ggufFilesFound  = 0
        skippedKnown    = 0
        proposalsAdded  = 0
    }

    foreach ($family in $familiesToScan) {
        $stats.familiesScanned++
        $searchTerm = Get-FamilySearchTerm -FamilyName $family
        $repos = Get-HfFamilyResults -CacheDir $cacheDir -FamilyName $family -SearchTerm $searchTerm
        $isNoRepos = $null -eq $repos
        if ($isNoRepos) { continue }

        foreach ($repo in $repos) {
            $stats.reposExamined++
            $isKnown = Test-RepoAlreadyKnown -Repo $repo -ExistingPagePrefixes $loaded.ExistingPagePrefixes
            if ($isKnown) {
                $stats.skippedKnown++
                continue
            }

            $files = Get-RepoGgufFiles -CacheDir $cacheDir -RepoId $repo.id
            $hasFiles = $files.Count -gt 0
            if (-not $hasFiles) { continue }

            $files = @($files | Select-Object -First $script:MaxFilesPerRepo)
            foreach ($file in $files) {
                $stats.ggufFilesFound++
                $proposal = New-ProposalEntry -FamilyName $family -Repo $repo -File $file
                $proposals += $proposal
                $stats.proposalsAdded++
                Write-Log "[NEW] $family :: $($repo.id) :: $($file.path)" -Level "success"
            }
        }
    }

    $hasProposals = $proposals.Count -gt 0
    if (-not $hasProposals) {
        Write-Log "No new GGUF candidates found across $($stats.familiesScanned) families." -Level "info"
        return
    }

    $stamp        = Get-Date -Format "yyyy-MM-dd-HHmmss"
    $proposalFile = Join-Path $proposedDir ("catalog-additions-{0}.json" -f $stamp)

    $payload = [ordered]@{
        generatedAt = (Get-Date -Format "o")
        catalogPath = $CatalogPath
        familyFilter = $FamilyFilter
        stats       = $stats
        proposals   = $proposals
    }

    try {
        ($payload | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $proposalFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "Failed to write proposal file: $proposalFile (failure: $($_.Exception.Message))" -Level "error"
        return
    }

    Write-Log "[PROPOSE] Wrote $($proposals.Count) proposal(s) to: $proposalFile" -Level "success"
    Write-Log ("Summary: families={0} repos={1} ggufFiles={2} known={3} proposed={4}" -f `
        $stats.familiesScanned, $stats.reposExamined, $stats.ggufFilesFound, `
        $stats.skippedKnown, $stats.proposalsAdded) -Level "info"

    if ($Apply) {
        Merge-CatalogProposals -CatalogPath $CatalogPath -ProposalFile $proposalFile
    } else {
        Write-Log "Review the proposal file then re-run with --apply to merge." -Level "info"
    }
}

# --------------------------------------------------------------------------
function Merge-CatalogProposals {
    param(
        [Parameter(Mandatory)] [string] $CatalogPath,
        [Parameter(Mandatory)] [string] $ProposalFile
    )

    $isProposalMissing = -not (Test-Path -LiteralPath $ProposalFile)
    if ($isProposalMissing) {
        Write-Log "Proposal file not found: $ProposalFile (failure: cannot apply, file missing)" -Level "error"
        return
    }

    try {
        $payload = Get-Content -LiteralPath $ProposalFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $catalog = Get-Content -LiteralPath $CatalogPath  -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "Failed to read JSON during merge (catalog: $CatalogPath, proposals: $ProposalFile, failure: $($_.Exception.Message))" -Level "error"
        return
    }

    $existingIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $catalog.models) { [void]$existingIds.Add([string]$m.id) }

    $merged = @($catalog.models)
    $appended = 0
    foreach ($p in $payload.proposals) {
        $isDup = $existingIds.Contains([string]$p.id)
        if ($isDup) {
            Write-Log "Skipping duplicate id during merge: $($p.id)" -Level "warn"
            continue
        }
        $merged += $p
        [void]$existingIds.Add([string]$p.id)
        $appended++
    }

    $catalog.models = $merged

    $backup = "$CatalogPath.bak"
    try {
        Copy-Item -LiteralPath $CatalogPath -Destination $backup -Force -ErrorAction Stop
        ($catalog | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $CatalogPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "Failed to apply merge to catalog: $CatalogPath (failure: $($_.Exception.Message))" -Level "error"
        return
    }

    Write-Log "Merged $appended new proposal(s) into catalog. Backup: $backup" -Level "success"
}