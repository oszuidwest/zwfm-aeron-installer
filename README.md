# AerOn Studio + PostgreSQL 17

`Install-Aeron.ps1` installeert PostgreSQL 17 en AerOn Studio op een schone Windows x64-server. Het vervangt het oude PostgreSQL 13-installatiepad; backups blijven de verantwoordelijkheid van [zwfm-aerontoolbox](https://github.com/oszuidwest/zwfm-aerontoolbox).

## Vereisten

- Een schone Windows x64-server zonder service `postgresql-17-x64-aeron` of bestaand PostgreSQL 17-datacluster op het doelpad.
- Een verhoogde PowerShell 5.1-shell en internettoegang, of beide installers vooraf naast het script.
- De CIDR-netwerken van alle AerOn-clients én van `zwfm-aerontoolbox`.
- Unieke wachtwoorden voor `postgres`, `aeron_dba` en `aeron_app_user`.

## Installeren

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Install-Aeron.ps1
```

Het script:

1. downloadt en verifieert de PostgreSQL-installer en de gepinde custom AerOn-build `2.1.4.14`;
2. installeert PostgreSQL 17 op poort `5417`;
3. maakt database `aeron_prod_db`, schema `aeron` en de benodigde rollen;
4. configureert SCRAM-authenticatie, `pg_hba.conf`, tuning en een CIDR-beperkte firewallregel;
5. schrijft tijdelijk `ConnectOptions.txt` en start de interactieve AerOn-installer.

### Parameters

| Parameter | Standaard | Doel |
|---|---|---|
| `-ClientNetworks` | prompt | Toegestane IPv4-CIDR's voor `pg_hba.conf` en Windows Firewall |
| `-PgFullVersion` | `17.11-1` | EDB PostgreSQL-installer |
| `-MaxConnections` | `200` | Maximumaantal PostgreSQL-verbindingen |
| `-AeronInstallerSha256` | hash van `2.1.4.14` | Verplichte trust anchor voor de ongesigneerde custom AerOn-installer; alleen wijzigen bij een bewuste upgrade |
| `-PgInstallerSha256` | leeg | Extra SHA-256-pin naast de verplichte EDB-handtekeningcontrole |
| `-NoAutoTune` | uit | Gebruik statische waarden in plaats van hardware-afhankelijke tuning |
| `-PasswordFile` | leeg | Alleen voor testautomatisering; wordt na inlezen verwijderd |
| `-SkipAeronInstall` | uit | Sla alleen de interactieve AerOn-installatie over |

## Direct na installatie

1. Open `ConnectOptions.txt` als administrator en zet de twee opgeslagen applicatiewachtwoorden in een wachtwoordmanager.
2. Verwijder `ConnectOptions.txt` handmatig zodra AerOn en de toolbox zijn geconfigureerd.
3. Start AerOn en verbind als `aeron_dba` met host `127.0.0.1`, poort `5417` en database `aeron_prod_db`.
4. Configureer en test de backupketen hieronder voordat de server productie overneemt.

`ConnectOptions.txt` is alleen een tijdelijk overdrachtsbestand. Het staat in `.gitignore`, maar mag ook buiten Git nooit blijven liggen. Het script wijzigt bewust geen ACL's van de AerOn-datamap of `Aeron.ini`.

### Custom AerOn-build

Deze installatie gebruikt bewust AerOn Studio `2.1.4.14`, omdat die een voor deze omgeving benodigde bugfix bevat en nieuwer is dan de build achter de leveranciers-URL `SetupAeronLatest.exe`. De installer staat niet in de Git-geschiedenis maar als asset bij release `aeron-studio-2.1.4.14`:

- bestand: `SetupAeron2.1.4.14.exe`;
- grootte: `330134240` bytes;
- SHA-256: `96be60f4fb3af07a8b0e6d4693977ca8176f1089bf492557e596865955c8ae8e`;
- Authenticode: niet ondertekend.

Het script accepteert een reeds aanwezig bestand naast `Install-Aeron.ps1`, maar voert het pas uit nadat de SHA-256-pin overeenkomt. Zonder lokaal bestand downloadt het exact dezelfde release-asset. Er is geen automatische fallback naar `Latest`: een ontbrekende custom build moet zichtbaar falen.

### Wat mag `aeron_app_user`?

Via `aeron_app_role` heeft deze gebruiker:

- `CONNECT` op `aeron_prod_db` en `USAGE` op schema `aeron`;
- `ALL` op alle tabellen die `aeron_dba` in dat schema maakt: onder meer `SELECT`, `INSERT`, `UPDATE`, `DELETE` en `TRUNCATE`;
- `USAGE` en `SELECT` op de bijbehorende sequences.

Daarmee kan de gebruiker database-inhoud voor muziekinvoer, instellingen, playlists en commercials lezen en wijzigen, voor zover AerOn die handelingen als tabeldata opslaat. Audiobestanden zelf vallen onder filesystemrechten, niet onder PostgreSQL.

De gebruiker is geen database- of schema-eigenaar en kan daarom geen database, rollen of schemaobjecten beheren zoals `aeron_dba` dat kan. Gebruik `aeron_dba` voor de eerste AerOn-run en schema-upgrades. Beschouw `aeron_app_user` niet als een read-only account: door `DELETE` en `TRUNCATE` kan het ook veel data verwijderen.

## Backups met zwfm-aerontoolbox

De toolbox is de bron van waarheid voor geplande backups. Configureer daarin minimaal:

```json
{
  "database": {
    "host": "<database-host>",
    "port": "5417",
    "name": "aeron_prod_db",
    "user": "aeron_app_user",
    "password": "<uit-de-wachtwoordmanager>",
    "schema": "aeron",
    "sslmode": "disable"
  },
  "backup": {
    "enabled": true,
    "path": "/backups",
    "retention_days": 30,
    "max_backups": 10,
    "default_compression": 9,
    "timeout_minutes": 30,
    "scheduler": {
      "enabled": true,
      "schedule": "0 3 * * *"
    }
  }
}
```

Pas retentie, planning en eventuele S3-configuratie aan op het eigen beleid. Houd rekening met het werkelijke gedrag van de toolbox:

- hij maakt een custom-format dump van alleen schema `aeron`;
- hij verwijdert een gedeeltelijk bestand wanneer `pg_dump` faalt;
- hij controleert daarna met `pg_restore --list` of het archief leesbaar is;
- S3-upload gebeurt na de lokale backup en heeft een aparte status;
- lokale retentie verwijdert dezelfde backup ook uit de gekoppelde S3-opslag;
- hij bevat geen restorefunctie.

`pg_restore --list` is een structurele controle, geen bewijs dat de data herstelbaar en bruikbaar is. Een periodieke restoretest blijft nodig.

> [!IMPORTANT]
> Bij Docker moet `backup.path` exact `/backups` zijn, zoals in het voorbeeld hierboven. De voorbeeld-compose mount de persistente hostmap daar. De waarde `./backups` verwijst door de container-`WORKDIR` naar `/app/backups` en valt buiten die mount; die backups verdwijnen bij vervanging van de container.

> [!IMPORTANT]
> De toolbox moet `pg_dump` en `pg_restore` versie 17 of nieuwer gebruiken tegen deze PostgreSQL 17-server. De huidige toolbox-Dockerfile installeert nog `postgresql16-client`; die image moet vóór de migratie naar een PostgreSQL 17-client worden bijgewerkt. Controleer in de container met `pg_dump --version` en `pg_restore --version`.

Zet het netwerk van de toolbox in `-ClientNetworks`. Anders blokkeren zowel `pg_hba.conf` als Windows Firewall de backupverbinding.

`config.json` van de toolbox bevat database- en mogelijk S3-credentials. Houd het bestand buiten Git, mount het read-only en beperk de leesrechten op hostniveau. Zorg ook dat de gemounte backupmap niet door andere lokale gebruikers beschrijfbaar is.

De toolbox gebruikt dezelfde databasegebruiker voor zijn normale functies en `pg_dump`. `aeron_app_user` heeft daarvoor voldoende tabel- en sequencerechten en voorkomt dat de toolbox database-eigenaar wordt. Gebruik `aeron_dba` wel voor restores en schemawijzigingen.

## Migreren vanaf PostgreSQL 13

De toolbox-dump bevat geen PostgreSQL-rollen en geen database-instellingen zoals `search_path`. Herstel daarom altijd in de lege database die dit installatiescript heeft gemaakt.

1. Installeer PostgreSQL 17 met dit script en start AerOn nog niet.
2. Controleer dat het doelschema nog geen tabellen bevat:

   ```powershell
   & 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -h 127.0.0.1 -p 5417 -U aeron_dba -d aeron_prod_db -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'aeron';"
   ```

   Verwacht `0`. Stop bij iedere andere uitkomst.

3. Maak vlak voor de cutover een nieuwe toolbox-backup van de PostgreSQL 13-bron. Wacht op `success: true` en, indien gebruikt, afzonderlijk op een geslaagde S3-sync.
4. Download of kopieer het `.dump`-bestand naar de nieuwe server en valideer het daar:

   ```powershell
   & 'C:\Program Files\PostgreSQL\17\bin\pg_restore.exe' --list 'C:\pad\naar\aeron-backup.dump' *> $null
   if ($LASTEXITCODE -ne 0) { throw 'Backupvalidatie mislukt' }
   ```

5. Herstel als `aeron_dba` met de PostgreSQL 17-tools:

   ```powershell
   & 'C:\Program Files\PostgreSQL\17\bin\pg_restore.exe' `
     --host=127.0.0.1 --port=5417 --username=aeron_dba `
     --dbname=aeron_prod_db --clean --if-exists --no-owner `
     --exit-on-error --single-transaction 'C:\pad\naar\aeron-backup.dump'
   ```

   Dit commando is destructief voor bestaande objecten in de doeldatabase. Gebruik het alleen op de gecontroleerd lege migratiedatabase.

6. Controleer `SHOW search_path`, schema/table-eigenaarschap en een login als `aeron_app_user`. Start daarna AerOn en controleer functioneel de data.
7. Wijs de toolbox pas dan naar host/poort van PostgreSQL 17, maak direct een nieuwe backup en voer op een aparte testdatabase een volledige restoretest uit.

## Beheer

- Service: `postgresql-17-x64-aeron`
- Poort: `5417`
- Datadir: `C:\Aeron Database\PostgreSQL\17\Database`
- PostgreSQL-log: `C:\Aeron Database\PostgreSQL\17\Database\log`
- Configuratie: `aeron.conf` en `pg_hba.conf` in de datadir

Bij een wijziging van de toolbox-host moeten zowel `pg_hba.conf` als de firewallregel worden aangepast. Netwerktoegang geldt alleen voor `aeron_prod_db`; de PostgreSQL-superuser blijft beperkt tot localhost.

## Publiek publiceren

- Commit nooit `ConnectOptions.txt`, passwordfiles, installers, dumps, `config.json` van de toolbox of andere lokale secrets. De custom AerOn-installer wordt uitsluitend als GitHub Release asset gedistribueerd.
- Controleer vóór de eerste push de volledige worktree én Git-geschiedenis op credentials.
- Gebruik voorbeeldwaarden in documentatie; publiceer geen hostnamen, IP-adressen, bucketnamen, objectnamen of productievolumes.
- Activeer op GitHub secret scanning en push protection.

Zie [VERANTWOORDING.md](VERANTWOORDING.md) voor ontwerpkeuzes en de geanonimiseerde teststatus.
