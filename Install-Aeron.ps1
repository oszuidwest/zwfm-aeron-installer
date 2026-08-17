<#
.SYNOPSIS
Installs PostgreSQL 17 and AerOn Studio on a clean Windows server.

.DESCRIPTION
Verifies and installs both products, creates the database and users, and
configures PostgreSQL, network access, and Windows Firewall.

.EXAMPLE
.\Install-Aeron.ps1
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'This is an interactive installer whose output is intentionally host-oriented.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword', 'PasswordFile',
    Justification = 'PasswordFile is an ACL-protected file path, not a password.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseSingularNouns', '', Scope = 'Function', Target = 'Read-ClientNetworks|Wait-ForPostgres',
    Justification = 'Networks is the returned collection; Postgres is the product name.'
)]
param(
    # Full EnterpriseDB installer version. Pinned to major 17: the install
    # dir, data dir, port convention, and service name below all assume it.
    [ValidatePattern('^17\.\d+-\d+$')]
    [string]$PgFullVersion = '17.11-1',

    [string]$PgInstallDir = 'C:\Program Files\PostgreSQL\17',
    [string]$PgDataDir    = 'C:\Aeron Database\PostgreSQL\17\Database',

    [string]$PgHost = '127.0.0.1',
    # AerOn convention: '54' followed by the PostgreSQL major version.
    [ValidateRange(1024, 65535)]
    [int]$PgPort = 5417,

    [ValidatePattern('^[a-z_][a-z0-9_]*$')]
    [string]$PgDatabase = 'aeron_prod_db',
    [ValidatePattern('^[a-z_][a-z0-9_]*$')]
    [string]$PgSchema = 'aeron',

    [ValidatePattern('^[a-z_][a-z0-9_]*$')]
    [string]$PgSuperUser = 'postgres',
    [ValidatePattern('^[a-z_][a-z0-9_]*$')]
    [string]$AeronDbAdmin = 'aeron_dba',
    [ValidatePattern('^[a-z_][a-z0-9_]*$')]
    [string]$AeronAppUser = 'aeron_app_user',
    [ValidatePattern('^[a-z_][a-z0-9_]*$')]
    [string]$AeronAppRole = 'aeron_app_role',

    [string]$PgServiceName = 'postgresql-17-x64-aeron',

    # Each AerOn Studio client uses about 50 connections.
    [ValidateRange(50, 2000)]
    [int]$MaxConnections = 200,

    # Allowed IPv4 CIDRs, for example '192.168.1.0/24'. Prompts when omitted.
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$')]
    [string[]]$ClientNetworks = @(),

    # Optional SHA-256 pin for the signed PostgreSQL installer.
    [string]$PgInstallerSha256,

    # These two change as a pair on every AerOn Studio release.
    [string]$AeronStudioVersion = '2.1.4.14',
    # Required SHA-256 pin for the unsigned AerOn installer.
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$AeronInstallerSha256 = '96BE60F4FB3AF07A8B0E6D4693977CA8176F1089BF492557E596865955C8AE8E',

    # Initial station values. AerOn 2.1.4.14 double-quotes shortname during
    # first-run database creation; the installer repairs that failed insert.
    [ValidateNotNullOrEmpty()]
    [string]$RadioLongName = 'Broadcast Partners',
    [ValidateNotNullOrEmpty()]
    [string]$RadioShortName = 'Radio 1',
    [ValidateNotNullOrEmpty()]
    [string]$RadioLocation = 'Terneuzen',

    # ACL-protected file for automation: superuser=..., dba=..., appuser=...
    # Deleted after reading. Do not pass passwords on the command line.
    [string]$PasswordFile,

    # Download and verify AerOn Studio without starting its installer.
    [switch]$SkipAeronInstall
)

$ErrorActionPreference = 'Stop'

# Avoid the expensive progress UI in Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Keep in sync with the ClientNetworks ValidatePattern (attribute arguments
# cannot reference variables).
$CidrPattern = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'

$PgBinDir  = Join-Path $PgInstallDir 'bin'
$Psql      = Join-Path $PgBinDir 'psql.exe'
$PgIsReady = Join-Path $PgBinDir 'pg_isready.exe'

$InstallerDownloadDir = Join-Path ([System.IO.Path]::GetTempPath()) 'zwfm-aeron-installer'
[System.IO.Directory]::CreateDirectory($InstallerDownloadDir) | Out-Null

# A pre-seeded installer next to the script wins (offline installs, see
# README); downloads land in the temp directory. Every file is verified below.
function Resolve-InstallerPath([string]$FileName) {
    $preSeeded = Join-Path $PSScriptRoot $FileName
    if (Test-Path $preSeeded) { $preSeeded } else { Join-Path $InstallerDownloadDir $FileName }
}

$PgInstallerUrl  = "https://get.enterprisedb.com/postgresql/postgresql-$PgFullVersion-windows-x64.exe"
$PgInstallerPath = Resolve-InstallerPath "postgresql-$PgFullVersion-windows-x64.exe"

$AeronInstallerFileName = "SetupAeron$AeronStudioVersion.exe"
$AeronInstallerUrl = "https://github.com/oszuidwest/zwfm-aeron-installer/releases/download/aeron-studio-$AeronStudioVersion/$AeronInstallerFileName"
$AeronInstallerPath = Resolve-InstallerPath $AeronInstallerFileName

$ConnectOptionsTxt = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'ConnectOptions.txt'

$PostgresqlConf = Join-Path $PgDataDir 'postgresql.conf'
$PgHbaConf      = Join-Path $PgDataDir 'pg_hba.conf'
$AeronConf      = Join-Path $PgDataDir 'aeron.conf'


# Helpers

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Read-PasswordTwice([string]$Account) {
    while ($true) {
        $pw1 = [System.Net.NetworkCredential]::new('', (Read-Host "Enter password for '$Account'" -AsSecureString)).Password
        if ([string]::IsNullOrWhiteSpace($pw1)) {
            Write-Host 'Password may not be empty.' -ForegroundColor Yellow
            continue
        }
        $pw2 = [System.Net.NetworkCredential]::new('', (Read-Host "Repeat password for '$Account'" -AsSecureString)).Password
        if ($pw1 -ne $pw2) {
            Write-Host 'Passwords do not match, try again.' -ForegroundColor Yellow
            continue
        }
        return $pw1
    }
}

function Read-ClientNetworks {
    Write-Host ''
    Write-Host 'The database is only reachable from the networks you enter here'
    Write-Host '(pg_hba.conf and the firewall rule). Local IPv4 addresses of this machine:'
    try {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' } |
            ForEach-Object { Write-Host ("  {0}/{1}" -f $_.IPAddress, $_.PrefixLength) }
    } catch {
        Write-Host '  (could not list local addresses)'
    }
    while ($true) {
        $answer = Read-Host 'Allowed client networks, comma separated CIDR (e.g. 192.168.1.0/24)'
        $nets = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $invalid = @($nets | Where-Object { $_ -notmatch $CidrPattern })
        if ($nets.Count -gt 0 -and $invalid.Count -eq 0) { return $nets }
        Write-Host 'Enter at least one valid IPv4 CIDR (a.b.c.d/nn).' -ForegroundColor Yellow
    }
}

function ConvertTo-SqlLiteral([string]$Value) {
    return $Value -replace "'", "''"
}

# Set-Content -Encoding UTF8 adds a BOM in Windows PowerShell 5.1.
function Write-Utf8File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# SIDs keep the ACL independent of the Windows display language.
function Protect-File([string]$Path) {
    & icacls $Path /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: could not restrict permissions on $Path" -ForegroundColor Yellow
    }
}

function Get-Installer([string]$Url, [string]$OutFile, [string]$Name) {
    if (Test-Path $OutFile) {
        Write-Host "$Name already present, skipping download (file is still verified below)."
        return
    }
    Write-Host "Downloading $Name..."
    Write-Host "  $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    Write-Host "  Saved to $OutFile"
}

function Test-Installer {
    param(
        [string]$Path,
        [string]$ExpectedSubjectPattern,
        [string]$ExpectedSha256,
        [switch]$RequireSignature
    )
    $hash = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
    Write-Host "  File    : $Path"
    Write-Host "  SHA-256 : $hash"
    if ($ExpectedSha256) {
        if ($hash -ne $ExpectedSha256) {
            throw "SHA-256 mismatch for $Path (expected $ExpectedSha256)"
        }
        Write-Host '  SHA-256 pin matches.'
    }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    switch ($sig.Status) {
        'Valid' {
            Write-Host ("  Signed  : {0}" -f $sig.SignerCertificate.Subject)
            if ($ExpectedSubjectPattern -and ($sig.SignerCertificate.Subject -notmatch $ExpectedSubjectPattern)) {
                throw "Unexpected Authenticode signer on ${Path}: $($sig.SignerCertificate.Subject)"
            }
        }
        'NotSigned' {
            if ($RequireSignature) {
                throw "$Path is not Authenticode-signed."
            }
            Write-Host '  WARNING : file is not Authenticode-signed; the mandatory' -ForegroundColor Yellow
            Write-Host '            SHA-256 pin is the trust anchor for this file.' -ForegroundColor Yellow
        }
        default {
            # An invalid signature is never accepted as unsigned.
            throw "Authenticode signature on $Path is not valid (status: $($sig.Status))."
        }
    }
}

function Invoke-Psql {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'psql requires separate username and PGPASSWORD values.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'The plaintext value is exposed only through PGPASSWORD for the child process.'
    )]
    param([string]$User, [string]$Password, [string]$Database, [string]$Sql, [switch]$Scalar)

    # Native argument quoting is unreliable in Windows PowerShell 5.1.
    # PGPASSWORD avoids a temporary trust rule.
    $sqlFile = (New-TemporaryFile).FullName
    Write-Utf8File -Path $sqlFile -Content $Sql
    try {
        $env:PGPASSWORD = $Password
        $env:PGCLIENTENCODING = 'UTF8'
        $psqlArgs = @('-v', 'ON_ERROR_STOP=1', '-h', $PgHost, '-p', $PgPort, '-U', $User, '-X', '-q')
        if ($Scalar) { $psqlArgs += @('-t', '-A') }
        if ($Database) { $psqlArgs += @('-d', $Database) }
        $psqlArgs += @('-f', $sqlFile)
        $output = @(& $Psql @psqlArgs)
        if ($LASTEXITCODE -ne 0) {
            throw "psql failed (user=$User db=$Database)"
        }
        if ($Scalar) {
            return @($output | ForEach-Object { $_.Trim() } | Where-Object { $_ })[-1]
        }
        $output
    } finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        # SQL statements may contain passwords.
        Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue
    }
}

function Repair-AeronInitialRadio {
    Write-Step "Apply AerOn $AeronStudioVersion initial-radio workaround"
    Write-Host 'AerOn may show its known SQL error before its interface becomes usable.'
    Write-Host 'Leave this PowerShell window open; the script will repair'
    Write-Host 'the missing radio record and restart AerOn automatically.'

    for ($i = 0; $i -lt 120; $i++) {
        $tableExists = Invoke-Psql -Scalar -User $AeronDbAdmin -Password $PwdDbAdmin -Database $PgDatabase `
            -Sql "SELECT CASE WHEN to_regclass('$PgSchema.radio') IS NULL THEN 0 ELSE 1 END;"
        if ($tableExists -eq '1') { break }
        Start-Sleep -Seconds 5
    }
    if ($tableExists -ne '1') {
        Write-Host 'WARNING: AerOn did not create the radio table within 10 minutes.' -ForegroundColor Yellow
        Write-Host 'The initial-radio workaround was not applied.' -ForegroundColor Yellow
        return
    }

    # Let AerOn finish its failing INSERT before repairing the empty table.
    Start-Sleep -Seconds 3

    $existingRadioCount = Invoke-Psql -Scalar -User $AeronDbAdmin -Password $PwdDbAdmin -Database $PgDatabase `
        -Sql "SELECT count(*) FROM $PgSchema.radio WHERE radioid = 1;"
    if ([int]$existingRadioCount -gt 0) {
        Write-Host 'Radio record 1 already exists; workaround is not needed.'
        return
    }

    Invoke-Psql -User $AeronDbAdmin -Password $PwdDbAdmin -Database $PgDatabase -Sql @"
INSERT INTO $PgSchema.radio (radioid, longname, shortname, location)
VALUES (1, '$(ConvertTo-SqlLiteral $RadioLongName)', '$(ConvertTo-SqlLiteral $RadioShortName)', '$(ConvertTo-SqlLiteral $RadioLocation)');
"@
    Write-Host "Inserted radio 1: $RadioLongName / $RadioShortName / $RadioLocation"

    $aeronProcess = Get-Process -Name Aeron -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $aeronProcess) {
        Write-Host 'AerOn is not running. Start it manually to continue its setup.' -ForegroundColor Yellow
        return
    }

    # AerOn was just launched argument-less by its own installer, so a plain
    # relaunch of the same executable is enough. Capture the path first:
    # reading it from an already-exited process throws.
    $aeronExePath = $aeronProcess.Path
    Stop-Process -Id $aeronProcess.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $restartedAeron = Start-Process -FilePath $aeronExePath -PassThru
    Start-Sleep -Seconds 5
    if ($restartedAeron.HasExited) {
        Write-Host 'WARNING: AerOn exited right after the restart; start it manually.' -ForegroundColor Yellow
        return
    }
    Write-Host 'AerOn restarted successfully after applying the workaround.'
}

function Wait-ForPostgres {
    for ($i = 0; $i -lt 30; $i++) {
        & $PgIsReady -h $PgHost -p $PgPort *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    throw "PostgreSQL did not become ready on ${PgHost}:${PgPort}"
}


# Preflight (before the hardware detection below; CIM/storage queries are slow)

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'This script requires 64-bit Windows.'
}

if (Test-Path (Join-Path $PgDataDir 'PG_VERSION')) {
    throw "Data directory $PgDataDir already contains a database cluster. This script only supports clean installations."
}

if (Get-Service -Name $PgServiceName -ErrorAction SilentlyContinue) {
    throw "Service $PgServiceName already exists. This script only supports clean installations."
}


# Tuning

# Based on PGTune's mixed profile and the PostgreSQL 17 documentation. PG17 on
# Windows caps work_mem and maintenance_work_mem at 2047 MB and does not
# support effective_io_concurrency.

function Get-AeronTuning {
    $totalMemMB = [long]([math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB))
    $cpuCores   = [Environment]::ProcessorCount

    $sharedBuffersMB = [long][math]::Max(128, [math]::Floor($totalMemMB / 4))

    $effectiveCacheMB = [long][math]::Max(512, [math]::Floor($totalMemMB * 3 / 4))

    $maintenanceMB = [long][math]::Min(2047, [math]::Max(64, [math]::Floor($totalMemMB / 16)))

    $maxParallelMaintenance = [math]::Min(4, [math]::Ceiling($cpuCores / 2))

    # (RAM - shared_buffers) / ((connections + parallel workers) * 3) / 2
    $workMemMB = [long][math]::Floor((($totalMemMB - $sharedBuffersMB) / (($MaxConnections + $cpuCores) * 3)) / 2)
    $workMemMB = [long][math]::Min(2047, [math]::Max(4, $workMemMB))

    $randomPageCost = $null
    try {
        $driveLetter = ([System.IO.Path]::GetPathRoot($PgDataDir)).Substring(0, 1)
        $diskNumber = (Get-Partition -DriveLetter $driveLetter | Get-Disk).Number
        $mediaType = (Get-PhysicalDisk -DeviceNumber $diskNumber -ErrorAction Stop).MediaType
        if ($mediaType -eq 'SSD') { $randomPageCost = '1.1' }
        elseif ($mediaType -eq 'HDD') { $randomPageCost = '4.0' }
    } catch {
        # RAID controllers and VMs may hide the media type.
        $randomPageCost = $null
    }

    return [pscustomobject]@{
        TotalMemMB             = $totalMemMB
        CpuCores               = $cpuCores
        SharedBuffersMB        = $sharedBuffersMB
        EffectiveCacheMB       = $effectiveCacheMB
        MaintenanceMB          = $maintenanceMB
        WorkMemMB              = $workMemMB
        MaxWorkerProcesses     = $cpuCores
        MaxParallelWorkers     = $cpuCores
        MaxParallelMaintenance = $maxParallelMaintenance
        RandomPageCost         = $randomPageCost
    }
}

$Tune = Get-AeronTuning
$HardwareSummary = "$($Tune.TotalMemMB) MB RAM, $($Tune.CpuCores) logical cpu cores"

if ($Tune.RandomPageCost) {
    $RandomPageCostLine = "random_page_cost = $($Tune.RandomPageCost)"
} else {
    $RandomPageCostLine = "# random_page_cost = 1.1   # uncomment if the database disk is an SSD (disk type could not be detected)"
}


# Generated configuration

# Keep PostgreSQL's durable defaults; the legacy configuration traded crash
# safety for performance by disabling synchronous commits.
$AeronConfContent = @"
# PostgreSQL configuration file for AerOn Studio
# Loaded from postgresql.conf via:  include_if_exists = 'aeron.conf'
# Auto-tuned for this machine: $HardwareSummary

# Connections
listen_addresses = '*'
port = $PgPort
max_connections = $MaxConnections   # Each AerOn Studio client uses about 50 connections

# Authentication
password_encryption = scram-sha-256

# Memory
shared_buffers = $($Tune.SharedBuffersMB)MB
temp_buffers = 80MB   # legacy AerOn vendor setting (per session!)
work_mem = $($Tune.WorkMemMB)MB
maintenance_work_mem = $($Tune.MaintenanceMB)MB
effective_cache_size = $($Tune.EffectiveCacheMB)MB

# Background writer (AerOn vendor settings)
bgwriter_delay = 100ms
bgwriter_lru_maxpages = 200     # 0-1000 max buffers written/round

# Parallel queries
max_worker_processes = $($Tune.MaxWorkerProcesses)
max_parallel_workers_per_gather = 0  # for AerOn Studio best setting is 0 (vendor guidance)
max_parallel_workers = $($Tune.MaxParallelWorkers)
max_parallel_maintenance_workers = $($Tune.MaxParallelMaintenance)

# Checkpoints and WAL
checkpoint_timeout = 10min
checkpoint_completion_target = 0.9
min_wal_size = 1GB
max_wal_size = 4GB
# Keep the durable PostgreSQL defaults for synchronous_commit and wal_level.

# Planner
$RandomPageCostLine
# effective_io_concurrency is unsupported on Windows.

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%a.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_line_prefix = '%t [%p]: [%l-1] %d %u %a %h '
log_lock_waits = on
log_temp_files = 0

# Locale
client_encoding = UTF8

# TCP keepalives
tcp_keepalives_idle = 60
tcp_keepalives_interval = 60
tcp_keepalives_count = 10

# Autovacuum and analyze (AerOn vendor settings)
# Lower thresholds keep bloat and planner statistics current under the continuously updated playout workload.
autovacuum_naptime = 15s
autovacuum_vacuum_cost_limit = 1000
autovacuum_vacuum_threshold = 40
autovacuum_vacuum_scale_factor = 0.01
autovacuum_analyze_threshold = 40
autovacuum_analyze_scale_factor = 0.005
autovacuum_vacuum_insert_threshold = 50
autovacuum_vacuum_insert_scale_factor = 0.005
"@


# Installation

Write-Host ''
Write-Host 'PostgreSQL 17 + AerOn Studio unattended installation' -ForegroundColor Green
Write-Host '-----------------------------------------------------'
Write-Host "PostgreSQL version : $PgFullVersion"
Write-Host "Install directory  : $PgInstallDir"
Write-Host "Data directory     : $PgDataDir"
Write-Host "Port               : $PgPort"
Write-Host "Service name       : $PgServiceName"
Write-Host "Database           : $PgDatabase (schema: $PgSchema)"
Write-Host "Initial radio      : $RadioLongName / $RadioShortName / $RadioLocation"
Write-Host "Detected hardware  : $HardwareSummary"
Write-Host "Tuning             : shared_buffers=$($Tune.SharedBuffersMB)MB work_mem=$($Tune.WorkMemMB)MB maintenance_work_mem=$($Tune.MaintenanceMB)MB effective_cache_size=$($Tune.EffectiveCacheMB)MB"

Write-Step 'Database passwords'
$UnattendedMode = [bool]$PasswordFile
if ($UnattendedMode) {
    Write-Host "Reading passwords from $PasswordFile (test/automation mode); the file is deleted after reading."
    if (-not (Test-Path $PasswordFile)) {
        throw "Password file not found: $PasswordFile"
    }
    $pwds = @{}
    Get-Content $PasswordFile | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*(.+?)\s*$') { $pwds[$Matches[1]] = $Matches[2] }
    }
    Remove-Item $PasswordFile -Force
    foreach ($key in 'superuser', 'dba', 'appuser') {
        if (-not $pwds[$key]) { throw "Password file is missing key '$key' (expected lines: superuser=..., dba=..., appuser=...)" }
    }
    $PwdSuperUser = $pwds['superuser']
    $PwdDbAdmin   = $pwds['dba']
    $PwdAppUser   = $pwds['appuser']
} else {
    Write-Host "The passwords for $AeronDbAdmin and $AeronAppUser are written to"
    Write-Host "ConnectOptions.txt (ACL-restricted). The $PgSuperUser password is NOT"
    Write-Host 'written anywhere: store it in your password manager now.'
    $PwdSuperUser = Read-PasswordTwice $PgSuperUser
    $PwdDbAdmin   = Read-PasswordTwice $AeronDbAdmin
    $PwdAppUser   = Read-PasswordTwice $AeronAppUser
}

Write-Step 'Client networks'
if ($ClientNetworks.Count -eq 0) {
    $ClientNetworks = Read-ClientNetworks
}
Write-Host ("Database and firewall will allow: {0} (plus localhost)" -f ($ClientNetworks -join ', '))

Write-Step 'Download installers'
Get-Installer -Url $PgInstallerUrl -OutFile $PgInstallerPath -Name "PostgreSQL $PgFullVersion installer"
Get-Installer -Url $AeronInstallerUrl -OutFile $AeronInstallerPath -Name "AerOn Studio $AeronStudioVersion custom installer"

Write-Step 'Verify installers'
Write-Host 'PostgreSQL installer (Authenticode signature required):'
Test-Installer -Path $PgInstallerPath -ExpectedSubjectPattern 'EnterpriseDB' -ExpectedSha256 $PgInstallerSha256 -RequireSignature
Write-Host 'AerOn Studio installer (vendor Nextwave Broadcast does not sign installers):'
Test-Installer -Path $AeronInstallerPath -ExpectedSha256 $AeronInstallerSha256

Write-Step "Install PostgreSQL $PgFullVersion (unattended)"

# NetworkService avoids creating a local Windows account. The temporary option
# file contains the superuser password and is removed after installation.
$PgOptionFile = (New-TemporaryFile).FullName
$OptionFileContent = @"
mode=unattended
unattendedmodeui=minimal
enable-components=server,commandlinetools
disable-components=pgAdmin,stackbuilder
prefix=$PgInstallDir
datadir=$PgDataDir
superaccount=$PgSuperUser
superpassword=$PwdSuperUser
servicename=$PgServiceName
serverport=$PgPort
"@

try {
    Write-Utf8File -Path $PgOptionFile -Content $OptionFileContent
    $proc = Start-Process -FilePath $PgInstallerPath -ArgumentList "--optionfile `"$PgOptionFile`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "PostgreSQL installer exited with code $($proc.ExitCode). Check the bitrock_installer log in $env:TEMP. If the installation is partial, uninstall it (or remove service '$PgServiceName' and the data directory) before retrying."
    }
} finally {
    Remove-Item $PgOptionFile -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $PostgresqlConf)) {
    throw "PostgreSQL installation failed: $PostgresqlConf not found."
}
Write-Host 'PostgreSQL installed.'
Wait-ForPostgres

# Use the installer's password authentication; never enable temporary trust.
Write-Step "Create users, database $PgDatabase and schema $PgSchema"

Invoke-Psql -User $PgSuperUser -Password $PwdSuperUser -Database 'postgres' -Sql @"
CREATE USER $AeronDbAdmin WITH PASSWORD '$(ConvertTo-SqlLiteral $PwdDbAdmin)';
CREATE USER $AeronAppUser WITH PASSWORD '$(ConvertTo-SqlLiteral $PwdAppUser)';
CREATE ROLE $AeronAppRole;
GRANT $AeronAppRole TO $AeronAppUser;
COMMENT ON ROLE $AeronDbAdmin IS 'AerOn database owner';
COMMENT ON ROLE $AeronAppUser IS 'AerOn operational data user';
CREATE DATABASE $PgDatabase ENCODING UTF8 OWNER $AeronDbAdmin;
"@

Invoke-Psql -User $AeronDbAdmin -Password $PwdDbAdmin -Database $PgDatabase -Sql @"
REVOKE CONNECT ON DATABASE $PgDatabase FROM public;
GRANT CONNECT ON DATABASE $PgDatabase TO $AeronAppRole;
CREATE SCHEMA $PgSchema AUTHORIZATION $AeronDbAdmin;
ALTER DATABASE $PgDatabase SET search_path = "`$user", $PgSchema, public;
GRANT USAGE ON SCHEMA $PgSchema TO $AeronAppRole;
ALTER DEFAULT PRIVILEGES IN SCHEMA $PgSchema GRANT ALL ON TABLES TO $AeronAppRole;
ALTER DEFAULT PRIVILEGES IN SCHEMA $PgSchema GRANT USAGE, SELECT ON SEQUENCES TO $AeronAppRole;
"@

Write-Host 'Users, database and schema created.'

Write-Step 'Install aeron.conf and pg_hba.conf, restart service'

Write-Utf8File -Path $AeronConf -Content $AeronConfContent

# AerOn's TLS support is unconfirmed, so access is CIDR-restricted without
# requiring hostssl. See README.
$AeronHbaRules = @(foreach ($addr in (@('127.0.0.1/32') + $ClientNetworks)) {
    foreach ($user in $AeronDbAdmin, $AeronAppUser) {
        'host      {0,-15} {1,-15} {2,-15} scram-sha-256' -f $PgDatabase, $user, $addr
    }
}) -join "`r`n"

$PgHbaFinalContent = @"
# PostgreSQL client authentication file for AerOn Studio
# Documentation: https://www.postgresql.org/docs/17/auth-pg-hba-conf.html

# TYPE    DATABASE        USER            ADDRESS         METHOD

# Superuser access from localhost only
host      all             $PgSuperUser        127.0.0.1/32    scram-sha-256

# AerOn database access from localhost and the allowed client networks
$AeronHbaRules

# IPv6 local connections
host      all             all             ::1/128         scram-sha-256

# Replication connections from localhost
host      replication     all             127.0.0.1/32    scram-sha-256
host      replication     all             ::1/128         scram-sha-256
"@

if (-not (Test-Path (Join-Path $PgDataDir 'pg_hba-ori.conf'))) {
    Rename-Item -Path $PgHbaConf -NewName 'pg_hba-ori.conf'
}
Write-Utf8File -Path $PgHbaConf -Content $PgHbaFinalContent

Add-Content -Path $PostgresqlConf -Value "include_if_exists = 'aeron.conf'" -Encoding ASCII

Restart-Service -Name $PgServiceName
Wait-ForPostgres

Invoke-Psql -User $AeronDbAdmin -Password $PwdDbAdmin -Database $PgDatabase -Sql 'SELECT version();' | Out-Null
Write-Host 'Configuration active; password login verified.'

Write-Step 'Add Windows firewall rule'

$FirewallRuleName = 'PostgreSQL Database Server (AerOn)'
# A pre-existing rule can only come from a partial-failure re-run; update it
# so the firewall stays in lockstep with the freshly written pg_hba.conf.
if (Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -DisplayName $FirewallRuleName -Enabled True -Protocol TCP -LocalPort $PgPort -RemoteAddress $ClientNetworks
    Write-Host ("Existing firewall rule updated for TCP port {0}, remote addresses: {1}" -f $PgPort, ($ClientNetworks -join ', '))
} else {
    New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $PgPort -RemoteAddress $ClientNetworks | Out-Null
    Write-Host ("Firewall rule added for TCP port {0}, remote addresses: {1}" -f $PgPort, ($ClientNetworks -join ', '))
}

Write-Step 'Write ConnectOptions.txt'

$ConnectOptionsContent = @"
PostgreSQL database users:

Super user:
$PgSuperUser        password = (not stored; chosen during installation)

DB admin:
$AeronDbAdmin       password = $PwdDbAdmin

Operational data user:
$AeronAppUser  password = $PwdAppUser

Note: $AeronAppUser can read and change all AerOn table data, but does not own
the schema or database. Connect AerOn Studio as $AeronDbAdmin when it must
create or migrate database objects.

WARNING: this file contains plain-text passwords. Access is restricted to
Administrators/SYSTEM. Store the passwords in a password manager and delete
this file from this machine.


PostgreSQL connect options for AerOn Studio:

Server / Hostname = $PgHost
Port     = $PgPort
Database = $PgDatabase
Username = $AeronDbAdmin
"@
Write-Utf8File -Path $ConnectOptionsTxt -Content $ConnectOptionsContent
Protect-File -Path $ConnectOptionsTxt

if (-not $UnattendedMode) {
    notepad.exe $ConnectOptionsTxt
}

if ($SkipAeronInstall) {
    Write-Step 'AerOn Studio installer skipped (-SkipAeronInstall)'
    Write-Host "Run it manually later: $AeronInstallerPath"
    Write-Host ''
    Write-Host 'PostgreSQL installation completed (AerOn Studio installer skipped).' -ForegroundColor Green
} else {
    Write-Step 'Start AerOn Studio installer'
    Write-Host 'Follow the directions in the AerOn Studio installer.'
    Write-Host "Connect AerOn Studio to the database as user $AeronDbAdmin (see ConnectOptions.txt)."

    $AeronProc = Start-Process -FilePath $AeronInstallerPath -Wait -PassThru
    Write-Host ''
    if ($AeronProc.ExitCode -eq 0) {
        if ($AeronStudioVersion -eq '2.1.4.14') {
            # Best effort: a workaround failure must not abort an otherwise
            # completed installation or hide the remaining manual steps.
            try {
                Repair-AeronInitialRadio
            } catch {
                Write-Host "WARNING: the initial-radio workaround failed: $_" -ForegroundColor Yellow
                Write-Host 'Restart AerOn Studio to let it retry its initial setup.' -ForegroundColor Yellow
            }
        }
        Write-Host 'PostgreSQL and AerOn Studio installation completed.' -ForegroundColor Green
    } else {
        Write-Host "PostgreSQL installation completed, but the AerOn Studio installer exited with code $($AeronProc.ExitCode) (cancelled or failed)." -ForegroundColor Yellow
        Write-Host "Re-run it manually: $AeronInstallerPath"
    }
}
Write-Host ''
Write-Host 'Remaining manual steps:'
Write-Host "  1. Start AerOn Studio and connect as $AeronDbAdmin (see ConnectOptions.txt)."
Write-Host "     ($AeronAppUser gets access to the AerOn tables automatically via default privileges.)"
Write-Host '  2. Store the passwords in a password manager and delete ConnectOptions.txt.'
Write-Host '  3. Configure zwfm-aerontoolbox with PostgreSQL 17 client tools and test a restore.'
