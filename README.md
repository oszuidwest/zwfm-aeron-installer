# AerOn Studio + PostgreSQL 17

Met `Install-Aeron.ps1` installeer je PostgreSQL 17 en AerOn Studio op een schone Windows x64-server. Het script richt ook de database, gebruikers, netwerktoegang en Windows Firewall in.

Het installatiescript maakt zelf geen backups. Daarvoor gebruikt deze omgeving [zwfm-aerontoolbox](https://github.com/oszuidwest/zwfm-aerontoolbox); zie [Backup maken en terugzetten](BACKUP.md) voor de configuratie en herstelprocedure.

## Voor je begint

Zorg voor:

- een schone Windows x64-server zonder de service `postgresql-17-x64-aeron` of een bestaand PostgreSQL 17-datacluster in de doelmap;
- PowerShell 5.1, gestart als administrator;
- internettoegang, of beide installers vooraf in dezelfde map als het script;
- de IPv4-netwerken die toegang moeten krijgen, genoteerd als CIDR, bijvoorbeeld `192.168.1.0/24`;
- drie verschillende wachtwoorden voor `postgres`, `aeron_dba` en `aeron_app_user`.

Neem ook het netwerk van `zwfm-aerontoolbox` op in de toegestane netwerken. Anders kan de toolbox de database niet bereiken.

## Installeren

Open PowerShell als administrator, ga naar de map met het script en voer uit:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Install-Aeron.ps1
```

Het script vraagt om de drie databasewachtwoorden en de toegestane IPv4-netwerken en voert daarna deze stappen uit:

1. downloadt en controleert de installers;
2. installeert PostgreSQL 17 op poort `5417`;
3. maakt de database, het schema en de gebruikers aan;
4. configureert de database- en firewalltoegang;
5. opent `ConnectOptions.txt` met de benodigde verbindingsgegevens;
6. start de interactieve installer van AerOn Studio;
7. herstelt de mislukte eerste `radio`-insert van AerOn `2.1.4.14` en start AerOn opnieuw.

Laat AerOn na de installatie starten en houd het PowerShell-venster open. AerOn `2.1.4.14` kan tijdens zijn automatische database-initialisatie een SQL-fout tonen, nog voordat de interface bruikbaar is; het script herstelt dit zelf en laat bestaande radiorecords ongemoeid. Meldt het script dat de workaround niet is toegepast, start AerOn Studio dan handmatig opnieuw.

Bewaar het wachtwoord van `postgres` meteen in een wachtwoordmanager. Dit wachtwoord wordt niet in `ConnectOptions.txt` of een ander bestand opgeslagen.

De gebruikte AerOn-versie is de gepinde custom build `2.1.4.14`. De achtergrond en controlewaarden staan in [VERANTWOORDING.md](VERANTWOORDING.md).

## Na de installatie

1. Bewaar de twee applicatiewachtwoorden uit `ConnectOptions.txt` in een wachtwoordmanager.
2. Start AerOn Studio en maak verbinding met:

   | Instelling | Waarde          |
   | ---------- | --------------- |
   | Host       | `127.0.0.1`     |
   | Poort      | `5417`          |
   | Database   | `aeron_prod_db` |
   | Gebruiker  | `aeron_dba`     |

3. Controleer in AerOn of de database correct wordt aangemaakt en geopend.
4. Verwijder `ConnectOptions.txt` zodra AerOn en de toolbox zijn ingesteld.
5. Richt de backups in volgens [BACKUP.md](BACKUP.md) en voer een restoretest uit voordat de server in productie gaat.

`ConnectOptions.txt` is een tijdelijk bestand met gevoelige informatie en staat op het bureaublad van de installerende gebruiker. Het staat in `.gitignore` en krijgt beperkte bestandsrechten, maar dat vervangt het verwijderen niet.

## Veelgebruikte parameters

Je hoeft voor een normale interactieve installatie geen parameters mee te geven.

| Parameter | Standaard | Gebruik |
| --- | --- | --- |
| `-ClientNetworks` | interactieve invoer | Toegestane IPv4-CIDR's voor PostgreSQL en Windows Firewall |
| `-PgFullVersion` | `17.11-1` | Versie van de EDB PostgreSQL-installer |
| `-MaxConnections` | `200` | Maximumaantal PostgreSQL-verbindingen |
| `-RadioLongName` | `Broadcast Partners` | Lange naam voor het eerste radiorecord |
| `-RadioShortName` | `Radio 1` | Korte naam voor het eerste radiorecord |
| `-RadioLocation` | `Terneuzen` | Locatie voor het eerste radiorecord |
| `-SkipAeronInstall` | uit | Download en verifieer AerOn Studio, maar start de installer niet |

De parameters `-PasswordFile` en `-PgInstallerSha256` zijn bedoeld voor testautomatisering of een gecontroleerde installerupgrade; `-AeronStudioVersion` en `-AeronInstallerSha256` wijzigen samen bij iedere AerOn-release. Bekijk de parameterbeschrijvingen in `Install-Aeron.ps1` voordat je ze gebruikt.

## Beheer

| Onderdeel       | Waarde                                         |
| --------------- | ---------------------------------------------- |
| Windows-service | `postgresql-17-x64-aeron`                      |
| Poort           | `5417`                                         |
| Datamap         | `C:\Aeron Database\PostgreSQL\17\Database`     |
| PostgreSQL-log  | `C:\Aeron Database\PostgreSQL\17\Database\log` |
| Configuratie    | `aeron.conf` en `pg_hba.conf` in de datamap    |

Verandert het netwerkadres van een AerOn-client of de toolbox? Pas dan zowel `pg_hba.conf` als de Windows Firewall-regel aan en herstart daarna de service `postgresql-17-x64-aeron`. De PostgreSQL-superuser blijft alleen vanaf de server zelf bereikbaar.

## Meer informatie

- [Backup maken en terugzetten](BACKUP.md)
- [Ontwerpkeuzes, beveiliging en verificatiestatus](VERANTWOORDING.md)
