# Verantwoording

Dit document legt de belangrijkste keuzes achter `Install-Aeron.ps1` vast. Het is bewust geschikt gemaakt voor een publieke repository: namen van personen, interne paden en netwerkdetails, productievolumes, backupobjecten en credentials zijn weggelaten.

## Scope

Het script verzorgt alleen een schone installatie van PostgreSQL 17 en AerOn Studio. Het maakt geen backups en bevat geen eigen backupplanner of restoretooling. Daarvoor wordt het bestaande project [zwfm-aerontoolbox](https://github.com/oszuidwest/zwfm-aerontoolbox) hergebruikt.

De installatie maakt:

- database `aeron_prod_db`;
- schema `aeron`;
- eigenaar `aeron_dba` zonder `CREATEDB`;
- operationele datagebruiker `aeron_app_user` via `aeron_app_role`;
- database-`search_path` `"$user", aeron, public`;
- default privileges voor toekomstige tabellen en sequences van `aeron_dba`.

## Verschillen met het legacy-installatiepad

| Keuze | Reden |
|---|---|
| PostgreSQL 17 op poort 5417 | Nieuwe major op een herkenbare, niet-standaardpoort |
| SCRAM-SHA-256 | Moderne PostgreSQL-wachtwoordauthenticatie |
| Geen tijdelijke `trust`-configuratie | Een afgebroken installatie laat geen wachtwoordloze toegang achter |
| Expliciete CIDR's in `pg_hba.conf` én Windows Firewall | Alleen bekende clients en de toolbox kunnen de database bereiken |
| Superuser alleen vanaf localhost | Het netwerkpad heeft geen superuser nodig |
| `ALTER DEFAULT PRIVILEGES` | AerOn-tabellen krijgen bij creatie direct de benodigde applicatierechten |
| Geen `synchronous_commit=off` of `wal_level=minimal` | PostgreSQL-defaults voorkomen onnodig dataverlies en houden herstelopties open |
| Geen ingebouwde backupcode | `zwfm-aerontoolbox` bestaat al en is de operationele backupvoorziening |
| Geen ACL-beheer voor `Aeron.ini` | Bewuste beheerkeuze voor de afgesloten doelomgeving; valt buiten dit installatiescript |

`aeron_app_role` krijgt `ALL` op tabellen en `USAGE, SELECT` op sequences die `aeron_dba` in schema `aeron` maakt. Daardoor kan `aeron_app_user` alle dagelijkse tabeldata lezen en muteren, inclusief verwijderen en trunceren. De rol krijgt bewust geen schema-eigenaarschap of `CREATE` op het schema; DDL en upgrades blijven bij `aeron_dba`. Toegang tot audiobestanden is een afzonderlijke filesystemkwestie.

## Credential-afhandeling

- Interactieve invoer gebruikt gemaskeerde prompts.
- Wachtwoorden worden niet als commandlineparameter geaccepteerd.
- Een tijdelijk EDB-optionfile en tijdelijke SQL-bestanden worden in `finally`-paden verwijderd.
- Het PostgreSQL-superuserwachtwoord komt niet in `ConnectOptions.txt`.
- `ConnectOptions.txt` bevat wel de twee applicatiewachtwoorden, krijgt een beperkte ACL en moet na configuratie handmatig worden verwijderd.
- `.gitignore` sluit bekende lokale secret-, installer- en backupbestanden uit. Dat is een vangnet, geen vervanging voor controle vóór een push.

## Backup- en restorecontract met zwfm-aerontoolbox

De implementatie van de toolbox is als bron van waarheid gevolgd:

1. `pg_dump` schrijft custom format met compressie en `--schema=aeron`.
2. Bij een dumpfout wordt het gedeeltelijke lokale bestand verwijderd.
3. Na de dump voert de toolbox `pg_restore --list` uit.
4. Een optionele S3-upload loopt daarna apart; lokale backupstatus en S3-status zijn dus niet hetzelfde.
5. Retentie op leeftijd en aantal verwijdert lokale backups en vraagt ook verwijdering van het overeenkomstige S3-object aan.
6. De toolbox automatiseert geen restore.

Daaruit volgen drie operationele eisen:

- de installer moet rollen, database, `search_path`, schema-eigenaarschap en default privileges blijven aanmaken, want een schema-only dump bevat niet al die cluster- en databaseconfiguratie;
- een succesvolle `pg_restore --list` is alleen een structurele archiefcontrole; een volledige restoretest is de herstelgarantie;
- lokale en remote retentie mogen niet als onafhankelijke bewaarlagen worden beschouwd.

De toolbox kan de bestaande `aeron_app_user` hergebruiken: diens tabel- en sequencerechten volstaan voor de toolboxfuncties en `pg_dump`. Voor restore en DDL blijft `aeron_dba` nodig. Een extra backuprol is daarom niet toegevoegd.

Voor Docker moet `backup.path` `/backups` zijn. De voorbeeld-compose mount die map, terwijl `./backups` door de container-`WORKDIR` naar `/app/backups` verwijst en dus niet persistent is. De toolboxconfiguratie bevat secrets en de backupmap bevat alle database-inhoud; beide vereisen beperkte hostrechten.

### PostgreSQL-clientversie

Een `pg_dump`-client mag niet ouder zijn dan de server-major waarop hij aansluit. Voor PostgreSQL 17 is dus clientversie 17 of nieuwer nodig. Tijdens deze review bevatte de toolbox-Dockerfile nog `postgresql16-client`. Dat is een migratieblokkade voor nieuwe PG17-backups en moet in de toolbox worden opgelost voordat de backupconfiguratie naar PG17 wijst.

## Verificatiestatus

In een wegwerp-Windows-omgeving zijn zonder productie-identificerende details gecontroleerd:

- volledige installatie en herinstallatie vanaf een schoon snapshot;
- serviceaccount, poort, tuning en durable PostgreSQL-defaults;
- SCRAM-logins voor de database-eigenaar en applicatiegebruiker;
- schema, `search_path`, database-ACL's en default privileges;
- dubbele netwerkbeperking via Windows Firewall en `pg_hba.conf`;
- succesvolle AerOn-start en schema-aanmaak op PostgreSQL 17;
- restore van een custom-format PostgreSQL 13-dump op PostgreSQL 17;
- functionele AerOn-start op de herstelde dataset.

Nog als operationele gate uitvoeren in de echte doelomgeving:

- de toolbox upgraden naar PostgreSQL 17-clienttools;
- `backup.path` op `/backups` zetten wanneer Docker Compose wordt gebruikt;
- de toolbox-host opnemen in de toegestane CIDR's;
- een nieuwe backup vanaf PostgreSQL 17 maken;
- S3-status afzonderlijk controleren als S3 is ingeschakeld;
- die backup volledig herstellen in een aparte testdatabase en functioneel openen.

## Bewust geaccepteerde grenzen

- De benodigde custom AerOn-build `2.1.4.14` is niet door de leverancier ondertekend. Het script accepteert daarom uitsluitend de gepinde SHA-256 `96be60f4fb3af07a8b0e6d4693977ca8176f1089bf492557e596865955c8ae8e`; de EDB-installer vereist daarnaast een geldige leveranciershandtekening.
- De custom installer is met toestemming als GitHub Release asset opgenomen. Hij blijft buiten de Git-geschiedenis vanwege zijn omvang en auteursrechtelijke status. De release-asset valt niet onder een eventuele opensourcelicentie van dit installatiescript.
- Er is bewust geen fallback naar `SetupAeronLatest.exe`, omdat die URL momenteel een oudere build zonder de benodigde bugfix levert.
- TLS wordt niet afgedwongen zolang clientondersteuning niet formeel is vastgesteld. De verbinding blijft beperkt tot expliciete CIDR's op een vertrouwd netwerk.
- Het script automatiseert geen beheer van `Aeron.ini` of de AerOn-datamap.
- Het script is bedoeld voor een verse server, niet als in-place major-upgrade.

## Publicatiecontrole

Voor de eerste publieke push:

1. controleer `git status` en de volledige inhoud van alle te committen bestanden;
2. zoek naar wachtwoorden, tokens, private keys, interne hostnamen/IP's, bucketnamen en lokale gebruikerspaden;
3. roteer ieder credential dat ooit in een gedeelde of gepubliceerde geschiedenis heeft gestaan;
4. activeer secret scanning en push protection in GitHub;
5. herhaal de controle bij iedere wijziging aan voorbeelden, logs of testdocumentatie.
