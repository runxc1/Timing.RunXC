#Requires -Version 5.1
<#
.SYNOPSIS
  Publish timing.runXC.run migrations to a hosted Supabase project.
.DESCRIPTION
  Paste-a-keys-and-it-does-the-rest version of `supabase db push`. Prompts
  (without echoing) for anything not already set in the environment, then:
      supabase login  ->  supabase link  ->  supabase db push
  Where to find each value in the Supabase dashboard:
    Project ref   - URL: https://supabase.com/dashboard/project/<ref>/...
    Access token  - account avatar (bottom left) -> Access tokens -> Create
    DB password   - Project Settings -> Database -> Postgres password
  Equivalent one-time CI setup lives in .github/workflows/deploy-supabase.yml.
.EXAMPLE
  .\scripts\publish-supabase.ps1
#>
param(
  [string]$ProjectRef = $env:SUPABASE_PROJECT_REF,
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

if (-not $ProjectRef) {
  $ProjectRef = (Read-Host 'Supabase project ref (from the dashboard URL)').Trim()
}
if (-not $ProjectRef) { throw 'A project ref is required.' }

$token = if ($env:SUPABASE_ACCESS_TOKEN) { $env:SUPABASE_ACCESS_TOKEN } else {
  Convert-SecureStringToPlain (Read-Host 'Access token (dashboard > account > Access tokens)' -AsSecureString)
}
$dbpw = if ($env:SUPABASE_DB_PASSWORD) { $env:SUPABASE_DB_PASSWORD } else {
  Convert-SecureStringToPlain (Read-Host 'Database password (Project Settings > Database)' -AsSecureString)
}

if (-not $token) { throw 'SUPABASE_ACCESS_TOKEN is required.' }
if (-not $dbpw) { throw 'SUPABASE_DB_PASSWORD is required.' }

$cliOnPath = if ($UseNpx) { $null } else { Get-Command supabase -ErrorAction SilentlyContinue }
if (-not $cliOnPath) {
  Write-Host 'Supabase CLI not found on PATH - using npx (one-time download).' -ForegroundColor Yellow
}

# Child processes inherit these; nothing is written to disk.
$env:SUPABASE_ACCESS_TOKEN = $token
$env:SUPABASE_DB_PASSWORD = $dbpw

function Invoke-Supabase([string[]]$CliArgs) {
  if ($cliOnPath) { & supabase @CliArgs } else { & npx --yes supabase@latest @CliArgs }
  if ($LASTEXITCODE -ne 0) { throw "supabase $($CliArgs[0]) failed (exit code $LASTEXITCODE)" }
}

Push-Location (Join-Path $PSScriptRoot '..')
try {
  Invoke-Supabase @('login')
  Invoke-Supabase @('link', '--project-ref', $ProjectRef)
  Invoke-Supabase @('db', 'push')
  Write-Host ''
  Write-Host "Migrations applied to Supabase project '$ProjectRef'." -ForegroundColor Green
} finally {
  Pop-Location
}
