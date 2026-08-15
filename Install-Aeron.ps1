##############################################################################
##
##  Unattended installation of PostgreSQL 17 + AerOn Studio
##
##  Modernized replacement for the legacy Install-Postgresql-Aeron.ps1
##  (Broadcast Partners, 2022) which targeted PostgreSQL 13.
##
##  What this script does, fully automated:
##    1. Prompts (masked) for the three database passwords and for the
##       client networks (CIDR) that may reach the database.
##    2. Downloads the PostgreSQL 17 installer (EnterpriseDB) and the
##       custom AerOn Studio 2.1.4.14 installer and verifies the
##       Authenticode signature of the PostgreSQL installer. The AerOn
##       installer is not signed by the vendor, so its SHA-256 is pinned.
##    3. Installs PostgreSQL 17 unattended (no pgAdmin, no Stack Builder).
##    4. Creates users aeron_dba / aeron_app_user, role aeron_app_role,
##       database aeron_prod_db and schema aeron (search_path aeron,public)
##       using password authentication (no temporary trust rules).
##    5. Installs aeron.conf (tuned for this machine's RAM/CPU/disk) and a
##       pg_hba.conf with scram-sha-256, restricted to the given networks.
##    6. Adds a Windows firewall rule restricted to those networks.
##    7. Writes ConnectOptions.txt (ACL-restricted, without the superuser
##       password) next to this script.
##    8. Starts the AerOn Studio installer (interactive) and reports its
##       exit code.
##
##  Post-install (manual):
##    - First run of AerOn Studio: connect as aeron_dba (see
##      ConnectOptions.txt). AerOn creates its tables on first run;
##      aeron_app_user gets access to them
##      automatically via the default privileges set during installation.
##
##  Run from an elevated PowerShell prompt:
##    Set-ExecutionPolicy Bypass -Scope Process -Force
##    .\Install-Aeron.ps1
##
##############################################################################

#Requires -Version 5.1

param(
    # Full EnterpriseDB installer version, see https://www.enterprisedb.com/downloads
    # 17.11 (released 2026-08-13) fixes multiple security issues, some of
    # which allow code execution. Do not pin an older version.
    [ValidatePattern('^\d+\.\d+-\d+$')]
    [string]$PgFullVersion = '17.11-1',

    [string]$PgInstallDir = 'C:\Program Files\PostgreSQL\17',
    [string]$PgDataDir    = 'C:\Aeron Database\PostgreSQL\17\Database',

    [string]$PgHost = '127.0.0.1',
    # Convention: '54' + major version (legacy PG13 used 5413)
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

    # Required by AerOn: each AerOn Studio client uses about 50 connections
    [ValidateRange(50, 2000)]
    [int]$MaxConnections = 200,

    # IPv4 networks (CIDR) from which AerOn clients may connect, e.g.
    # '192.168.1.0/24'. Used in pg_hba.conf and the firewall rule. If empty,
    # the script prompts for them.
    [string[]]$ClientNetworks = @(),

    # Optional PostgreSQL pin and mandatory-by-default AerOn custom-build pin.
    # Override the AerOn value only when deliberately replacing the installer.
    [string]$PgInstallerSha256,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$AeronInstallerSha256 = '96BE60F4FB3AF07A8B0E6D4693977CA8176F1089BF492557E596865955C8AE8E',

    # Unattended mode for TEST/AUTOMATION runs: path to an ACL-protected
    # file with three lines: superuser=..., dba=..., appuser=...
    # The file is deleted after reading. Interactive (masked) prompts are
    # used when this is not provided. Never pass passwords on the command
    # line; they would be visible in process listings.
    [string]$PasswordFile,

    # Do not start the interactive AerOn Studio installer at the end
    # (useful for unattended test runs; the installer is still downloaded
    # and verified)
    [switch]$SkipAeronInstall,

    # Skip automatic hardware-based tuning and use conservative static
    # values (the legacy PG13 aeron.conf settings)
    [switch]$NoAutoTune
)

$ErrorActionPreference = 'Stop'
$ScriptPath = $PSScriptRoot

# Speeds up Invoke-WebRequest considerably
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CidrPattern = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'

$PgBinDir  = Join-Path $PgInstallDir 'bin'
$Psql      = Join-Path $PgBinDir 'psql.exe'
$PgIsReady = Join-Path $PgBinDir 'pg_isready.exe'

$PgInstallerUrl  = "https://get.enterprisedb.com/postgresql/postgresql-$PgFullVersion-windows-x64.exe"
$PgInstallerPath = Join-Path $ScriptPath "postgresql-$PgFullVersion-windows-x64.exe"

$AeronStudioVersion = '2.1.4.14'
$AeronReleaseTag = "aeron-studio-$AeronStudioVersion"
$AeronInstallerFileName = "SetupAeron$AeronStudioVersion.exe"
$AeronInstallerUrl = "https://github.com/oszuidwest/zwfm-aeron-installer/releases/download/$AeronReleaseTag/$AeronInstallerFileName"
$AeronInstallerPath = Join-Path $ScriptPath $AeronInstallerFileName

$ConnectOptionsTxt = Join-Path $ScriptPath 'ConnectOptions.txt'

$PostgresqlConf = Join-Path $PgDataDir 'postgresql.conf'
$PgHbaConf      = Join-Path $PgDataDir 'pg_hba.conf'
$AeronConf      = Join-Path $PgDataDir 'aeron.conf'


##### Helper functions #######################################################

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function ConvertFrom-SecureStringPlain([securestring]$Secure) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-PasswordTwice([string]$Account) {
    while ($true) {
        $pw1 = ConvertFrom-SecureStringPlain (Read-Host "Enter password for '$Account'" -AsSecureString)
        if ([string]::IsNullOrWhiteSpace($pw1)) {
            Write-Host 'Password may not be empty.' -ForegroundColor Yellow
            continue
        }
        $pw2 = ConvertFrom-SecureStringPlain (Read-Host "Repeat password for '$Account'" -AsSecureString)
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

# Escape a string for use inside a single-quoted SQL literal
function ConvertTo-SqlLiteral([string]$Value) {
    return $Value -replace "'", "''"
}

# Write text as UTF-8 without BOM (Set-Content -Encoding UTF8 adds a BOM in
# Windows PowerShell 5.1; -Encoding ASCII would corrupt non-ASCII passwords)
function Write-Utf8File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# Restrict a file to Administrators and SYSTEM (language-independent SIDs)
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

# Verify a downloaded installer before it is executed as administrator.
# Both freshly downloaded and pre-existing files pass through this check.
function Test-Installer {
    param(
        [string]$Path,
        [string]$ExpectedSubjectPattern,  # regex the signer subject must match
        [string]$ExpectedSha256,          # optional pin
        [bool]$RequireSignature
    )
    $hash = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
    Write-Host "  File    : $Path"
    Write-Host "  SHA-256 : $hash"
    if ($ExpectedSha256) {
        if ($hash -ne $ExpectedSha256.ToUpperInvariant()) {
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
            Write-Host '  WARNING : file is not Authenticode-signed (vendor Nextwave' -ForegroundColor Yellow
            Write-Host '            Broadcast does not sign installers). The mandatory' -ForegroundColor Yellow
            Write-Host '            SHA-256 pin is the trust anchor for this file.' -ForegroundColor Yellow
        }
        default {
            # A broken/invalid signature is worse than no signature
            throw "Authenticode signature on $Path is not valid (status: $($sig.Status))."
        }
    }
}

function Invoke-Psql([string]$User, [string]$Password, [string]$Database, [string]$Sql) {
    # The SQL is passed via a temp file (-f) because multiline/quoted
    # arguments to native executables are unreliable in Windows PowerShell
    # 5.1. Authentication uses PGPASSWORD; there is no trust phase.
    $sqlFile = Join-Path $env:TEMP ("aeron-setup-{0}.sql" -f ([guid]::NewGuid().ToString('N')))
    Write-Utf8File -Path $sqlFile -Content $Sql
    try {
        $env:PGPASSWORD = $Password
        $env:PGCLIENTENCODING = 'UTF8'
        $psqlArgs = @('-v', 'ON_ERROR_STOP=1', '-h', $PgHost, '-p', $PgPort, '-U', $User, '-X', '-q')
        if ($Database) { $psqlArgs += @('-d', $Database) }
        $psqlArgs += @('-f', $sqlFile)
        & $Psql @psqlArgs
        if ($LASTEXITCODE -ne 0) {
            throw "psql failed (user=$User db=$Database)"
        }
    } finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        # The temp file may contain passwords
        Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForPostgres {
    for ($i = 0; $i -lt 30; $i++) {
        & $PgIsReady -h $PgHost -p $PgPort *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    throw "PostgreSQL did not become ready on ${PgHost}:${PgPort}"
}


##### Automatic hardware-based tuning ########################################

# Formulas follow PGTune (https://pgtune.leopard.in.ua, profile: mixed) and
# the PostgreSQL 17 documentation. Windows specifics:
#  - work_mem and maintenance_work_mem are capped at 2GB minus 1MB on
#    Windows up to and including PG17.
#  - effective_io_concurrency must NOT be set on Windows (no posix_fadvise;
#    any value other than 0 raises an error), so it is left at default.
# Settings whose computed value duplicates a PostgreSQL default (wal_buffers,
# default_statistics_target) are deliberately not set.

function Get-AeronTuning {
    $totalMemMB = [long]([math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB))
    $cpuCores   = [Environment]::ProcessorCount

    # shared_buffers: 25% of RAM (PostgreSQL docs recommendation)
    $sharedBuffersMB = [long][math]::Max(128, [math]::Floor($totalMemMB / 4))

    # effective_cache_size: 75% of RAM (planner hint, not an allocation)
    $effectiveCacheMB = [long][math]::Max(512, [math]::Floor($totalMemMB * 3 / 4))

    # maintenance_work_mem: RAM/16, Windows cap 2GB-1MB, minimum 64MB
    $maintenanceMB = [long][math]::Min(2047, [math]::Max(64, [math]::Floor($totalMemMB / 16)))

    # Parallel workers: worker processes = cpu cores;
    # per_gather stays 0 (AerOn vendor guidance);
    # maintenance workers = ceil(cores/2) capped at 4
    $maxWorkerProcesses = [math]::Max(1, $cpuCores)
    $maxParallelWorkers = [math]::Max(1, $cpuCores)
    $maxParallelMaintenance = [math]::Min(4, [math]::Max(1, [math]::Ceiling($cpuCores / 2)))

    # work_mem (pgtune, mixed profile):
    # (RAM - shared_buffers) / ((max_connections + max_parallel_workers) * 3) / 2
    $workMemMB = [long][math]::Floor((($totalMemMB - $sharedBuffersMB) / (($MaxConnections + $maxParallelWorkers) * 3)) / 2)
    $workMemMB = [long][math]::Min(2047, [math]::Max(4, $workMemMB))

    # random_page_cost: 1.1 for SSD/NVMe, 4.0 for spinning disk. Detect the
    # media type of the disk that holds the data directory (best effort).
    $randomPageCost = $null
    try {
        $driveLetter = ([System.IO.Path]::GetPathRoot($PgDataDir)).Substring(0, 1)
        $diskNumber = (Get-Partition -DriveLetter $driveLetter | Get-Disk).Number
        $mediaType = (Get-PhysicalDisk -DeviceNumber $diskNumber -ErrorAction Stop).MediaType
        if ($mediaType -eq 'SSD') { $randomPageCost = '1.1' }
        elseif ($mediaType -eq 'HDD') { $randomPageCost = '4.0' }
    } catch {
        # Media type unknown (RAID controller, VM, etc): leave at PG default
    }

    return [pscustomobject]@{
        TotalMemMB             = $totalMemMB
        CpuCores               = $cpuCores
        SharedBuffersMB        = $sharedBuffersMB
        EffectiveCacheMB       = $effectiveCacheMB
        MaintenanceMB          = $maintenanceMB
        WorkMemMB              = $workMemMB
        MaxWorkerProcesses     = $maxWorkerProcesses
        MaxParallelWorkers     = $maxParallelWorkers
        MaxParallelMaintenance = $maxParallelMaintenance
        RandomPageCost         = $randomPageCost
    }
}

if ($NoAutoTune) {
    # Conservative static values from the legacy PG13 aeron.conf
    $Tune = [pscustomobject]@{
        TotalMemMB = 0; CpuCores = 0
        SharedBuffersMB = 512; EffectiveCacheMB = 2048; MaintenanceMB = 128
        WorkMemMB = 8
        MaxWorkerProcesses = 6; MaxParallelWorkers = 6; MaxParallelMaintenance = 2
        RandomPageCost = $null
    }
    $TuneHeader = '# Static tuning values (legacy defaults, -NoAutoTune)'
} else {
    $Tune = Get-AeronTuning
    $TuneHeader = "# Auto-tuned for this machine: $($Tune.TotalMemMB) MB RAM, $($Tune.CpuCores) logical cpu cores"
}

if ($Tune.RandomPageCost) {
    $RandomPageCostLine = "random_page_cost = $($Tune.RandomPageCost)"
} else {
    $RandomPageCostLine = "# random_page_cost = 1.1   # uncomment if the database disk is an SSD (disk type could not be detected)"
}


##### Configuration file contents ############################################

# PostgreSQL tuning for AerOn Studio, loaded from postgresql.conf via
# include_if_exists. Structure based on the legacy aeron.conf (PG13);
# memory/parallel values are computed for this machine (see above).
# Durability settings (synchronous_commit, wal_level) and WAL sizing that
# matched PostgreSQL defaults are left at their safe defaults on purpose;
# the legacy 'synchronous_commit = off' risked losing committed
# transactions on a crash.
$AeronConfContent = @"
# PostgreSQL configuration file for AerOn Studio
# Loaded from postgresql.conf via:  include_if_exists = 'aeron.conf'
$TuneHeader

# - Connection settings
listen_addresses = '*'
port = $PgPort
max_connections = $MaxConnections   # Each AerOn Studio client uses about 50 connections

# - Authentication
password_encryption = scram-sha-256

# - Memory settings
shared_buffers = $($Tune.SharedBuffersMB)MB
temp_buffers = 80MB   # legacy AerOn vendor setting (per session!)
work_mem = $($Tune.WorkMemMB)MB
maintenance_work_mem = $($Tune.MaintenanceMB)MB
effective_cache_size = $($Tune.EffectiveCacheMB)MB

# - Background writer settings (legacy AerOn vendor settings)
bgwriter_delay = 100ms
bgwriter_lru_maxpages = 200     # 0-1000 max buffers written/round

# - Parallel query
max_worker_processes = $($Tune.MaxWorkerProcesses)
max_parallel_workers_per_gather = 0  # for AerOn Studio best setting is 0 (vendor guidance)
max_parallel_workers = $($Tune.MaxParallelWorkers)
max_parallel_maintenance_workers = $($Tune.MaxParallelMaintenance)

# - Checkpoint / WAL settings
checkpoint_timeout = 10min
checkpoint_completion_target = 0.9
min_wal_size = 1GB
max_wal_size = 4GB
# synchronous_commit, wal_level, wal_buffers: PostgreSQL defaults (durable).
# The legacy config set synchronous_commit=off and wal_level=minimal; that
# trades crash safety for speed and blocks pg_basebackup/replication.

# - Planner
$RandomPageCostLine
# Note: effective_io_concurrency must not be set on Windows (no posix_fadvise)

# - Logging
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
log_line_prefix = '%t [%p]: [%l-1] %d %u %a %h '
log_lock_waits = on
log_temp_files = 0

# - Locale and formatting
client_encoding = UTF8

# - TCP Keepalives
tcp_keepalives_idle = 60
tcp_keepalives_interval = 60
tcp_keepalives_count = 10
"@


##### Start ##################################################################

Write-Host ''
Write-Host 'PostgreSQL 17 + AerOn Studio unattended installation' -ForegroundColor Green
Write-Host '-----------------------------------------------------'
Write-Host "PostgreSQL version : $PgFullVersion"
Write-Host "Install directory  : $PgInstallDir"
Write-Host "Data directory     : $PgDataDir"
Write-Host "Port               : $PgPort"
Write-Host "Service name       : $PgServiceName"
Write-Host "Database           : $PgDatabase (schema: $PgSchema)"
if ($NoAutoTune) {
    Write-Host 'Tuning             : static legacy values (-NoAutoTune)'
} else {
    Write-Host "Detected hardware  : $($Tune.TotalMemMB) MB RAM, $($Tune.CpuCores) logical cpu cores"
    Write-Host "Tuning             : shared_buffers=$($Tune.SharedBuffersMB)MB work_mem=$($Tune.WorkMemMB)MB maintenance_work_mem=$($Tune.MaintenanceMB)MB effective_cache_size=$($Tune.EffectiveCacheMB)MB"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'This script requires an elevated (administrator) PowerShell.'
}

if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'This script requires 64-bit Windows.'
}

if (Test-Path $PgDataDir) {
    if (Test-Path (Join-Path $PgDataDir 'PG_VERSION')) {
        throw "Data directory $PgDataDir already contains a database cluster. This script only supports clean installations."
    }
}

if (Get-Service -Name $PgServiceName -ErrorAction SilentlyContinue) {
    throw "Service $PgServiceName already exists. This script only supports clean installations."
}

##### Step 1: passwords and client networks ##################################

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
$invalidNets = @($ClientNetworks | Where-Object { $_ -notmatch $CidrPattern })
if ($ClientNetworks.Count -eq 0 -or $invalidNets.Count -gt 0) {
    $ClientNetworks = Read-ClientNetworks
}
Write-Host ("Database and firewall will allow: {0} (plus localhost)" -f ($ClientNetworks -join ', '))

##### Step 2: download and verify installers #################################

Write-Step 'Download installers'
Get-Installer -Url $PgInstallerUrl -OutFile $PgInstallerPath -Name "PostgreSQL $PgFullVersion installer"
Get-Installer -Url $AeronInstallerUrl -OutFile $AeronInstallerPath -Name "AerOn Studio $AeronStudioVersion custom installer"

Write-Step 'Verify installers'
Write-Host 'PostgreSQL installer (Authenticode signature required):'
Test-Installer -Path $PgInstallerPath -ExpectedSubjectPattern 'EnterpriseDB' -ExpectedSha256 $PgInstallerSha256 -RequireSignature $true
Write-Host 'AerOn Studio installer:'
Test-Installer -Path $AeronInstallerPath -ExpectedSubjectPattern '' -ExpectedSha256 $AeronInstallerSha256 -RequireSignature $false

##### Step 3: install PostgreSQL #############################################

Write-Step "Install PostgreSQL $PgFullVersion (unattended)"

# Option file for the EnterpriseDB installer. The service runs as the
# built-in NetworkService account, so no local Windows user is created.
# The file contains the superuser password: it lives in the admin's TEMP
# directory and is removed immediately after the installer finishes.
$PgOptionFile = Join-Path $env:TEMP ("aeron-pg-install-{0}.opt" -f ([guid]::NewGuid().ToString('N')))
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

##### Step 4: users, database and schema #####################################
# Runs against the pg_hba.conf that the installer generated (password auth
# on localhost). No temporary trust rules are used: if the script aborts
# here, the cluster never had passwordless access.

Write-Step "Create users, database $PgDatabase and schema $PgSchema"

$SqlPwdDbAdmin = ConvertTo-SqlLiteral $PwdDbAdmin
$SqlPwdAppUser = ConvertTo-SqlLiteral $PwdAppUser

# As superuser: users, role and database
Invoke-Psql -User $PgSuperUser -Password $PwdSuperUser -Database 'postgres' -Sql @"
CREATE USER $AeronDbAdmin WITH PASSWORD '$SqlPwdDbAdmin';
CREATE USER $AeronAppUser WITH PASSWORD '$SqlPwdAppUser';
CREATE ROLE $AeronAppRole;
GRANT $AeronAppRole TO $AeronAppUser;
COMMENT ON ROLE $AeronDbAdmin IS 'AerOn database owner';
COMMENT ON ROLE $AeronAppUser IS 'AerOn operational data user';
"@

Invoke-Psql -User $PgSuperUser -Password $PwdSuperUser -Database 'postgres' -Sql "CREATE DATABASE $PgDatabase ENCODING UTF8 OWNER $AeronDbAdmin;"

# As database owner: schema, search_path and connect rights
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

##### Step 5: configuration (aeron.conf + pg_hba.conf) #######################

Write-Step 'Install aeron.conf and pg_hba.conf, restart service'

Write-Utf8File -Path $AeronConf -Content $AeronConfContent

# pg_hba.conf: scram-sha-256 only, network access restricted to the given
# client networks. TLS (hostssl + certificate verification) is not enforced
# yet because AerOn client support for it is unconfirmed; see README.
$NetworkRules = ($ClientNetworks | ForEach-Object {
    "host      $PgDatabase   $AeronDbAdmin       $_    scram-sha-256`r`n" +
    "host      $PgDatabase   $AeronAppUser   $_    scram-sha-256"
}) -join "`r`n"

$PgHbaFinalContent = @"
# PostgreSQL client authentication file for AerOn Studio
# Documentation: https://www.postgresql.org/docs/17/auth-pg-hba-conf.html

# TYPE    DATABASE        USER            ADDRESS         METHOD

# Superuser access from localhost only
host      all             $PgSuperUser        127.0.0.1/32    scram-sha-256

# AerOn database access from localhost
host      $PgDatabase   $AeronDbAdmin       127.0.0.1/32    scram-sha-256
host      $PgDatabase   $AeronAppUser   127.0.0.1/32    scram-sha-256

# AerOn database access from the allowed client networks
$NetworkRules

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

# Verify that password authentication works with the new configuration
Invoke-Psql -User $AeronDbAdmin -Password $PwdDbAdmin -Database $PgDatabase -Sql 'SELECT version();' | Out-Null
Write-Host 'Configuration active; password login verified.'

##### Step 6: firewall rule ##################################################

Write-Step 'Add Windows firewall rule'

$FirewallRuleName = 'PostgreSQL Database Server (AerOn)'
if (Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue) {
    Write-Host 'Firewall rule already exists; leaving it unchanged.'
} else {
    New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $PgPort -RemoteAddress $ClientNetworks | Out-Null
    Write-Host ("Firewall rule added for TCP port {0}, remote addresses: {1}" -f $PgPort, ($ClientNetworks -join ', '))
}

##### Step 7: connect options ################################################

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

##### Step 8: AerOn Studio installer #########################################

if ($SkipAeronInstall) {
    Write-Step 'AerOn Studio installer skipped (-SkipAeronInstall)'
    Write-Host "Run it manually later: $AeronInstallerPath"
    $AeronInstallOk = $null
} else {
    Write-Step 'Start AerOn Studio installer'
    Write-Host 'Follow the directions in the AerOn Studio installer.'
    Write-Host "Connect AerOn Studio to the database as user $AeronDbAdmin (see ConnectOptions.txt)."

    $AeronProc = Start-Process -FilePath $AeronInstallerPath -Wait -PassThru
    $AeronInstallOk = ($AeronProc.ExitCode -eq 0)
}

##### Done ###################################################################

Write-Host ''
if ($null -eq $AeronInstallOk) {
    Write-Host 'PostgreSQL installation completed (AerOn Studio installer skipped).' -ForegroundColor Green
} elseif ($AeronInstallOk) {
    Write-Host 'PostgreSQL and AerOn Studio installation completed.' -ForegroundColor Green
} else {
    Write-Host "PostgreSQL installation completed, but the AerOn Studio installer exited with code $($AeronProc.ExitCode) (cancelled or failed)." -ForegroundColor Yellow
    Write-Host "Re-run it manually: $AeronInstallerPath"
}
Write-Host ''
Write-Host 'Remaining manual steps:'
Write-Host "  1. Start AerOn Studio and connect as $AeronDbAdmin (see ConnectOptions.txt)."
Write-Host "     ($AeronAppUser gets access to the AerOn tables automatically via default privileges.)"
Write-Host '  2. Store the passwords in a password manager and delete ConnectOptions.txt.'
Write-Host '  3. Configure zwfm-aerontoolbox with PostgreSQL 17 client tools and test a restore.'
