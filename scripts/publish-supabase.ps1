#Requires -Version 5.1
<#
.SYNOPSIS
  Publish timing.runXC.run migrations to the hosted Supabase project.
.DESCRIPTION
  Runs `supabase db push` with as little typing as possible. Nothing secret is
  written to disk:

    * Access token - asked for once, handed to `supabase login --token`, which
      stores it in your OS credential store (Windows Credential Manager). Every
      later run reuses it silently.
    * Project ref  - remembered in %LOCALAPPDATA%\runxc-timing\publish.json
      ($XDG_CONFIG_HOME or ~/.local/share on Linux/macOS). If nothing is cached
      yet and exactly one project is linked to your account, it is picked up
      automatically and you are never asked.
    * DB password  - current CLIs connect through the management API, so this is
      not needed. It is only requested if a push actually fails on auth, and
      then it lives in the process environment for that run alone.

  .github/workflows/deploy-supabase.yml runs this same script with the token
  supplied as a secret instead of a credential store.
.EXAMPLE
  .\scripts\publish-supabase.ps1             # apply pending migrations
.EXAMPLE
  .\scripts\publish-supabase.ps1 -DryRun     # show what would be applied
.EXAMPLE
  .\scripts\publish-supabase.ps1 -Forget     # drop the cached project ref
#>
param(
  # Overrides the cached project ref for this run.
  [string]$ProjectRef = $env:SUPABASE_PROJECT_REF,
  # Report pending migrations without applying them.
  [switch]$DryRun,
  # Forget the cached project ref (the access token stays in your credential store).
  [switch]$Forget,
  # Force `npx supabase@latest` even when the CLI is on PATH.
  [switch]$UseNpx
)

$ErrorActionPreference = 'Stop'

function Convert-SecureStringToPlain([System.Security.SecureString]$Value) {
  if (-not $Value) { return $null }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$CacheRoot =
  if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA }
  elseif ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME }
  else { Join-Path $HOME '.local/share' }
$CacheDir = Join-Path $CacheRoot 'runxc-timing'
$CacheFile = Join-Path $CacheDir 'publish.json'

function Get-CachedProjectRef {
  if (-not (Test-Path $CacheFile)) { return $null }
  try {
    $json = Get-Content $CacheFile -Raw | ConvertFrom-Json
    if ($json.projectRef) { return $json.projectRef }
  } catch {
    Write-Warning "Ignoring unreadable cache at $CacheFile"
  }
  return $null
}

function Save-CachedProjectRef([string]$Ref) {
  if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
  @{ projectRef = $Ref; savedAt = (Get-Date).ToString('o') } |
    ConvertTo-Json -Compress | Set-Content -Path $CacheFile -Encoding UTF8
}

if ($Forget) {
  if (Test-Path $CacheFile) {
    Remove-Item $CacheFile -Force
    Write-Host "Cleared cached project ref ($CacheFile)." -ForegroundColor Green
  } else {
    Write-Host 'No cached project ref.' -ForegroundColor Yellow
  }
  Write-Host 'To also drop the stored access token: supabase logout' -ForegroundColor DarkGray
  return
}

# --- locate the CLI -------------------------------------------------------
$cliOnPath = if ($UseNpx) { $null } else { Get-Command supabase -ErrorAction SilentlyContinue }

function Invoke-Supabase([string[]]$CliArgs) {
  # Returns @{ ExitCode; Output }. Native stderr is merged in so callers can
  # match on message text instead of losing it to the error stream. The CLI
  # writes progress ("Initialising login role...") to stderr, which Windows
  # PowerShell 5.1 would otherwise raise as a NativeCommandError under
  # $ErrorActionPreference = 'Stop'.
  $ErrorActionPreference = 'Continue'
  if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
  }
  $raw = if ($cliOnPath) { & supabase @CliArgs 2>&1 } else { & npx --yes supabase@latest @CliArgs 2>&1 }
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { "$_" }) -join [Environment]::NewLine
  @{ ExitCode = $exitCode; Output = $text }
}

function ConvertFrom-CliJson([string]$Text) {
  # The CLI prefixes JSON with progress lines ("Initialising login role...") and
  # prints it pretty-printed, so parse from the first line that opens a brace.
  if (-not $Text) { return $null }
  $lines = $Text -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\{') {
      try {
        return (($lines[$i..($lines.Count - 1)] -join [Environment]::NewLine) | ConvertFrom-Json)
      } catch {
        Write-Verbose "Could not parse CLI JSON: $_"
        return $null
      }
    }
  }
  return $null
}

Push-Location (Join-Path $PSScriptRoot '..')
try {
  # --- authenticate ------------------------------------------------------
  # Child processes inherit SUPABASE_ACCESS_TOKEN, so an env var works without
  # touching the credential store; otherwise reuse what `supabase login` saved.
  if ($env:SUPABASE_ACCESS_TOKEN) {
    Write-Host 'Using SUPABASE_ACCESS_TOKEN from the environment.' -ForegroundColor DarkGray
  }
  $auth = Invoke-Supabase @('projects', 'list')
  if ($auth.ExitCode -ne 0 -and -not $env:SUPABASE_ACCESS_TOKEN) {
    Write-Host 'Not signed in to Supabase yet. Create a token at' -ForegroundColor Yellow
    Write-Host '  dashboard > account avatar (bottom left) > Access tokens > Create new token' -ForegroundColor DarkGray
    $secure = Read-Host 'Access token (cached in your credential store after this run)' -AsSecureString
    $token = Convert-SecureStringToPlain $secure
    if (-not $token) { throw 'An access token is required the first time.' }
    $login = Invoke-Supabase @('login', '--token', $token)
    if ($login.ExitCode -ne 0) { throw "supabase login failed:`n$($login.Output)" }
    Write-Host 'Signed in - later runs will not ask again.' -ForegroundColor Green
    $auth = Invoke-Supabase @('projects', 'list')
  }
  if ($auth.ExitCode -ne 0) { throw "Could not reach Supabase:`n$($auth.Output)" }

  # --- which project ----------------------------------------------------
  # The CLI marks the project this repo is linked to with `linked: true`, so a
  # single linked project needs no prompting at all.
  $projects = @()
  $parsed = ConvertFrom-CliJson $auth.Output
  if ($parsed) { $projects = @($parsed.projects) }

  if (-not $ProjectRef) { $ProjectRef = Get-CachedProjectRef }
  if (-not $ProjectRef) {
    $linked = @($projects | Where-Object { $_.linked })
    if ($linked.Count -eq 1) {
      $ProjectRef = $linked[0].ref
      Write-Host "Using linked project '$($linked[0].name)' ($ProjectRef)." -ForegroundColor DarkGray
    }
  }
  if (-not $ProjectRef) {
    if ($projects.Count) {
      Write-Host 'Known projects:' -ForegroundColor Yellow
      $projects | ForEach-Object { Write-Host ('  {0}  {1}' -f $_.ref, $_.name) }
    }
    $ProjectRef = (Read-Host 'Supabase project ref (from the dashboard URL)').Trim()
  }
  if (-not $ProjectRef) { throw 'A project ref is required.' }

  # --- link only when needed -------------------------------------------
  $alreadyLinked = @($projects | Where-Object { $_.ref -eq $ProjectRef -and $_.linked }).Count -gt 0
  if ($alreadyLinked) {
    Write-Host "Already linked to $ProjectRef." -ForegroundColor DarkGray
  } else {
    $link = Invoke-Supabase @('link', '--project-ref', $ProjectRef)
    if ($link.ExitCode -ne 0) { throw "supabase link failed:`n$($link.Output)" }
  }

  # --- push -------------------------------------------------------------
  $pushArgs = @('db', 'push')
  if ($DryRun) { $pushArgs += '--dry-run' }
  $push = Invoke-Supabase $pushArgs

  # Older CLIs (or restricted tokens) still want the Postgres password. Ask for
  # it only when the push actually complains, then retry once.
  if ($push.ExitCode -ne 0 -and -not $env:SUPABASE_DB_PASSWORD -and
      $push.Output -match '(?i)password|28P01|authentication') {
    Write-Host 'The database asked for a password (dashboard > Project Settings > Database).' -ForegroundColor Yellow
    $secure = Read-Host 'Database password (used for this run only)' -AsSecureString
    $dbpw = Convert-SecureStringToPlain $secure
    if ($dbpw) {
      $env:SUPABASE_DB_PASSWORD = $dbpw
      $push = Invoke-Supabase $pushArgs
    }
  }

  Write-Host $push.Output
  if ($push.ExitCode -ne 0) { throw "supabase db push failed (exit code $($push.ExitCode))" }

  Save-CachedProjectRef $ProjectRef
  if ($DryRun) {
    Write-Host "`nDry run complete - nothing was applied." -ForegroundColor Green
  } else {
    Write-Host "`nMigrations published to Supabase project '$ProjectRef'." -ForegroundColor Green
    Write-Host "Project ref cached in $CacheFile (no secrets stored there)." -ForegroundColor DarkGray
  }
} finally {
  Pop-Location
}
