# Backup maken en terugzetten

Gebruik [zwfm-aerontoolbox](https://github.com/oszuidwest/zwfm-aerontoolbox) om backups te maken. Terugzetten doe je met `pg_restore` op de databaseserver.

De procedure is niet gekoppeld aan een specifieke bronversie van PostgreSQL. De backup moet een leesbare custom-format dump van het schema `aeron` zijn. Op de PostgreSQL 17-doelserver gebruik je de meegeleverde versie 17-tools.

## Toolbox instellen

Neem het netwerk van de toolbox op in `-ClientNetworks` wanneer je `Install-Aeron.ps1` uitvoert. Anders blokkeren zowel PostgreSQL als Windows Firewall de verbinding.

Gebruik minimaal de volgende instellingen in `config.json` van de toolbox:

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

`config.json` bevat database- en eventueel S3-inloggegevens: houd het bestand buiten Git, mount het read-only en beperk de leesrechten op de host.

Pas de bewaartermijn, planning en eventuele S3-configuratie aan je eigen beleid aan. De toolbox heeft PostgreSQL-clienttools van minimaal versie 17 nodig: de Docker-image voldoet daaraan, maar draai je de toolbox buiten Docker, installeer die tools dan zelf (achtergrond: [VERANTWOORDING.md](VERANTWOORDING.md)).

Gebruik je Docker Compose, dan moet `backup.path` exact `/backups` zijn. De voorbeeldconfiguratie koppelt de persistente hostmap aan die locatie. Met `./backups` schrijft de container naar `/app/backups`; die bestanden verdwijnen wanneer de container wordt vervangen.

## Backup maken

Met de scheduler uit het voorbeeld maakt de toolbox iedere nacht om 03:00 uur een backup. Je kunt ook direct een backup starten via de API:

```sh
curl -X POST http://localhost:8080/api/db/backup \
  -H "X-API-Key: <api-sleutel>" \
  -H "Content-Type: application/json" \
  -d '{}'
```

Controleer daarna de status:

```sh
curl http://localhost:8080/api/db/backup/status \
  -H "X-API-Key: <api-sleutel>"
```

De backup is klaar wanneer `running` `false` is, `success` `true` is en een `filename` is ingevuld. Gebruik je S3, controleer dan ook afzonderlijk of `s3_sync.synced` `true` is.

De toolbox controleert iedere nieuwe backup met `pg_restore --list`. Dat toont aan dat het archief leesbaar is, maar niet dat AerOn na een restore correct werkt. Voer daarom periodiek de volledige terugzetprocedure hieronder uit op een aparte testserver.

## Backup terugzetten

Deze procedure vervangt de bestaande objecten in het schema `aeron` van de doeldatabase. Maak eerst een extra backup als de doeldatabase nog bereikbaar is, en controleer host, poort en databasenaam.

1. Sluit AerOn Studio en stop andere processen die naar de doeldatabase schrijven.

2. Zorg dat de doelserver met `Install-Aeron.ps1` is ingericht. Het script maakt de database, rollen en instellingen aan die niet in de toolbox-backup zitten.

3. Kopieer het `.dump`-bestand naar de doelserver en controleer of het leesbaar is:

   ```powershell
   & 'C:\Program Files\PostgreSQL\17\bin\pg_restore.exe' --list 'C:\pad\naar\aeron-backup.dump' *> $null
   if ($LASTEXITCODE -ne 0) { throw 'Backupvalidatie mislukt' }
   ```

4. Zet de backup terug als `aeron_dba`:

   ```powershell
   & 'C:\Program Files\PostgreSQL\17\bin\pg_restore.exe' `
     --host=127.0.0.1 --port=5417 --username=aeron_dba `
     --dbname=aeron_prod_db --clean --if-exists --no-owner `
     --exit-on-error --single-transaction 'C:\pad\naar\aeron-backup.dump'
   ```

5. Start AerOn Studio en controleer of de verwachte gegevens aanwezig en bruikbaar zijn. Controleer ook of aanmelden als `aeron_app_user` werkt.

6. Maak na een restore op de productieserver meteen een nieuwe backup en controleer daarvan de status.

## Rechten en opslag

De gebruiker `aeron_app_user` heeft voldoende rechten voor de toolbox en `pg_dump`. Gebruik `aeron_dba` voor restores en schemawijzigingen.

Zorg dat andere lokale gebruikers niet naar de backupmap kunnen schrijven.

Lokale retentie verwijdert dezelfde backup ook uit de gekoppelde S3-opslag. Beschouw lokaal en S3 daarom niet als twee onafhankelijke bewaarlagen.

[Terug naar de installatiehandleiding](README.md) · [Achtergrond bij het backupcontract](VERANTWOORDING.md)
