# Koha 16.11 → 26.05 Server Migration

Migration of the `atslibrary` Koha instance from the legacy server onto a fresh
Debian 13 (Trixie) host, driven by `koha_migrate_new_server.sh`.

## Status: all 11 phases complete — functionally verified, not yet production-hardened

| Phase | Description | State |
|-------|-------------|-------|
| 1 | Install `koha-common` + MariaDB | Done |
| 2 | Configure Apache (modules, ports 81/82) | Done |
| 3 | Create Koha instance `atslibrary` | Done |
| 4 | Transfer + restore database from old server | Done — dump `atslibrary-2026-08-16.sql.gz` |
| 5 | MariaDB 11.x compatibility patches | Done |
| 6 | Schema upgrade (16.11 → 26.05) | Done — needed 2 manual interventions, see Findings |
| 7 | Apache vhost for Plack | Done — `configtest` Syntax OK |
| 8 | Locale + log ownership | Done — `en_US.utf8` generated |
| 9 | Start/restart services, HTTP smoke test | Done — staff + OPAC HTTP 200 |
| 10 | Rebuild Zebra search indexes | Done — 16,393 biblios indexed |
| 11 | Reset staff passwords | Done — 3 accounts |

Database verified at Koha `26.0502000`, 295 tables, `utf8mb4` /
`utf8mb4_unicode_ci`:

| Biblios | Biblioitems | Items | Patrons | Checkouts | Historical checkouts |
|---------|-------------|-------|---------|-----------|----------------------|
| 16,393 | 16,393 | 26,533 | 445 | 405 | 11,373 |

### Verified working

- Staff (`:81`) and OPAC (`:82`) both return HTTP 200 in ~0.16 s via Plack.
- Authenticated staff login succeeds (tested as superlibrarian `Emmy`, session
  established), proving Apache → Plack → Koha → MariaDB end to end.
- Catalogue search returns results (8,947 hits for a keyword query) via the
  61 MB Zebra biblio index. Zero errors in `zebra-error.log`.
- Plack, Zebra, indexer and both background workers running; `apache2`,
  `mariadb`, `memcached`, `koha-common`, `rabbitmq-server` all enabled at boot.
- Standard Koha cron installed (`cron.daily/koha-common`): fines, overdue and
  advance notices, holds expiry, DB cleanup, and `koha-run-backups --days 2`.

### Not production-ready yet

Seven hardening items remain and **none are done**. In order of risk: no HTTPS,
empty MariaDB root password, a shared staff password, an un-closed cutover gap
against the old server, 2-day local-only backups, DNS, and decommissioning.
Treat the instance as LAN-internal until the first three are addressed. Full
detail and commands in **Production hardening** below.

## Environment

| Item | Value |
|------|-------|
| New server (this host) | `192.168.20.252` — Debian 13 Trixie |
| Old server | `192.168.20.254` — Koha 16.11 |
| Koha instance | `atslibrary` |
| Koha version installed | `26.05.02-1` (koha-community stable repo) |
| MariaDB | `11.8.6` |
| Database | `koha_atslibrary` |
| Koha DB user | `koha_atslibrary` (password in `/etc/koha/sites/atslibrary/koha-conf.xml`) |
| Domain suffix | `.atseminary.ac.ke` |
| Staff interface | port `81`, hostname `atslibrary-intra.atseminary.ac.ke` |
| OPAC | port `82`, hostname `atslibrary.atseminary.ac.ke` |
| Migration logs | `/root/koha-migration-<YYYYMMDD-HHMMSS>.log` (one per run) |

## Required credentials

### 1. Root SSH access to the old server (satisfied)

This was the original blocker and is no longer needed: the dumps were copied to
`/root/` by hand. Required again only if the database must be re-pulled from
`192.168.20.254`.

Note that key-based auth was never established — `ssh-copy-id` failed with
"No identities found" because this host has no private key — so any further
transfer prompts for the old server's root password. Never paste that password
into a script, a shell one-liner, or this file.

```bash
scp root@192.168.20.254:/var/spool/koha/atslibrary/*.sql.gz /root/
```

### 2. MariaDB root on this host (already usable — but insecure)

The script runs `mysql` as the local root account with no credentials, which
works today because **MariaDB `root@localhost` has an empty password** and uses
`mysql_native_password`. No action is needed to complete the migration, but set
a password (or switch to `unix_socket` auth) before this host serves traffic.

### 3. Temporary staff password (Phase 11 — already applied)

Phase 11 has run. All **3** accounts with `flags > 0` (`Emmy` superlibrarian,
`deb`, `edn`) now share the single value of `ADMIN_TEMP_PASS` from the script's
CONFIGURATION block, and `login_attempts` was cleared. No non-staff account was
touched.

- The value is still the **committed default**, so it is known to anyone who can
  read the script. Rotate it — see Production hardening step 3.
- It was applied by running the Phase 11 block manually with the password passed
  through an environment variable, so it was **not** written to any migration
  log. Running the script's Phase 11 as-is would echo it to stdout and into
  `/root/koha-migration-*.log`.

## Re-running the script (don't)

**Do not re-run `koha_migrate_new_server.sh` against this instance.** Phase 4
unconditionally drops `koha_atslibrary` and re-imports the 16.11 dump, which
would discard the completed upgrade and require repeating Phase 6 and every
manual intervention below. If the migration must ever be redone from scratch, fix
the defects in Findings 4, 5 and 6 first.

Phases 7-11 were therefore run individually. Commands actually used — note the
corrected locale handling, which differs from the script:

```bash
# 7  vhost written to /etc/apache2/sites-available/atslibrary.conf (Plack variant)
#    a2ensite atslibrary && apache2ctl configtest && systemctl reload apache2
# 8  sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
#    chown -R atslibrary-koha:atslibrary-koha /var/log/koha/atslibrary/
# 9  koha-enable atslibrary && koha-plack --enable atslibrary
#    koha-plack --restart atslibrary && koha-zebra --restart atslibrary
#    koha-worker --restart atslibrary && systemctl restart apache2
# 10 koha-rebuild-zebra -v -f atslibrary
# 11 the Phase 11 perl block, with ADMIN_TEMP_PASS supplied via the environment
```

The original `koha-create` vhost is preserved at
`/root/atslibrary.conf.koha-create.bak`.

### Verifying success

The script fails loudly (`die`) if the upgrade does not reach version 26, and
prints a summary with biblio/item/patron counts. Manual checks:

```bash
mysql koha_atslibrary -Ne "SELECT value FROM systempreferences WHERE variable='Version';"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:81/   # staff, expect 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:82/   # OPAC
koha-plack --status atslibrary
```

### Post-migration checks

Data and the full web stack are verified (see "Verified working" above). All
remaining operational work is in **Production hardening** below.

## Migration findings

Six issues were hit: four defects in `koha_migrate_new_server.sh` (items 1, 4, 5
and 6), one data problem in the source database (item 3), and one anomaly in the
transferred dumps (item 2).

Fix status — **only item 1 is fixed in the script itself.** Items 4, 5 and 6 were
worked around on this host and remain defects in `koha_migrate_new_server.sh`; a
future run elsewhere would hit all three again.

### 1. Silent abort at Phase 4 (script defect — fixed)

Exit code 2 with no error message. Full analysis under "Fixed defect" below.
Root cause was a non-matching glob under `set -e`/`pipefail`, not a database
fault. Also fixed alongside it: `koha-create` now skipped when the instance
exists, so re-runs reach Phase 4.

### 2. Four dumps arrived, two of them empty

The `scp` glob pulled `atslibrary-2019-01-13.sql.gz` and
`atslibrary-2025-09-06.sql.gz` at **0 bytes** alongside the two valid 27 MB
dumps. Phase 4 selects newest-by-mtime and validated `gzip -t`, so the good
`2026-08-16` dump (344 MB uncompressed, `mysqldump` from MySQL 5.5.62) was used.
Had the empty files sorted newest, the size/gzip guards would have aborted
rather than wiping the database with an empty import.

### 3. Orphaned permission row blocked migration 21.12.00.016 (data)

The upgrade stopped at `21.12.00.016` (Bug 30060, adds a primary key and FK to
`user_permissions`) with:

```
Cannot add or update a child row: a foreign key constraint fails
(`koha_atslibrary`.`#sql-alter-...`, CONSTRAINT `user_permissions_ibfk_2`
FOREIGN KEY (`module_bit`, `code`) REFERENCES `permissions` (`module_bit`, `code`))
```

Exactly one row was orphaned: borrowernumber 100 (`deb`), `module_bit=11`,
`code='suggestions_manage'`. Cause: `suggestions_manage` is **relocated** from
`module_bit` 11 (acquisition) to 12 (suggestions) partway through the upgrade.
The script's Phase 6 pre-cleanup only deletes rows orphaned relative to the
*16.11* `permissions` table, so it cannot catch an orphan created mid-upgrade.

Resolved by remapping rather than deleting, preserving the user's access:

```sql
UPDATE user_permissions SET module_bit=12
 WHERE borrowernumber=100 AND module_bit=11 AND code='suggestions_manage';
```

The script's pre-cleanup `DELETE` would have silently revoked her
purchase-suggestion permission instead. A durable fix is to re-run the orphan
cleanup (or prefer remapping) immediately before `21.12.00.016` rather than once
at the start of Phase 6.

### 4. Phase 5 Patch 2 missed multi-line statements (script defect — NOT fixed in script)

The upgrade then stopped at `24.06.00.024` (Bug 35044) with
`Can't DROP FOREIGN KEY 'afv_fk'` — the FK was absent because Patch 1 drops all
FKs at `17.12.00.016`. Patch 2 is supposed to wrap such drops in `eval {}`, but
its regexes require `do(q{` and `})` to be adjacent, so multi-line calls like

```perl
$dbh->do(
    q{
        ALTER TABLE additional_field_values DROP FOREIGN KEY afv_fk
    }
);
```

were skipped. Patch 2 caught only 9 files; **21** actually needed wrapping.

A first repair attempt used a non-greedy `.*?`, which in `231200023.pl` matched
from an unrelated `$dbh->do(` across an `if` block's closing brace to a distant
`DROP FOREIGN KEY`, producing a Perl syntax error. A `perl -c` check caught it.
Recovery and correct fix:

1. Reverted every `db_revs/*.pl` from the cached package
   (`dpkg-deb -x /var/cache/apt/archives/koha-common_26.05.02-1_all.deb`).
2. Re-patched with brace-bounded classes (`[^{}]*`, `[^|]*`) that cannot escape
   their own SQL literal — 21 files wrapped.
3. Gated on `PERL5LIB=/usr/share/koha/lib perl -c` for all 21 (0 failures).

**Lesson:** always syntax-check generated Perl edits before resuming an upgrade;
unchecked corruption surfaces later as a far more confusing migration failure.

Important: this was fixed by patching the installed `db_revs` files directly. The
script's Patch 2 regexes were **not** updated, so it still only handles the
single-line form. To fix it there, replace the three patterns with brace-bounded
equivalents allowing whitespace after `do(`:
`\$dbh->do\(\s*qq?\{[^{}]*DROP FOREIGN KEY[^{}]*\}\s*\)` (and the `q|...|` /
double-quoted variants), and add a `perl -c` gate over every file it edits.

### 5. Phase 5 re-patch hazard (script defect — NOT fixed)

Phase 5 runs `cp $UPD_PL $UPD_PL.orig` unconditionally. If the script is re-run
after a Phase 6 failure, that copies the *already patched* file over the pristine
backup, so the eventual restore restores a patched file and Patch 1 is applied
twice. Resuming with `koha-upgrade-schema atslibrary` directly avoids this.
`updatedatabase.pl` is currently pristine (`.orig` removed).

### 6. Phase 8 locale generation is a no-op on Debian (script defect — NOT fixed)

The script runs `locale-gen en_US.UTF-8`. Debian's `locale-gen` **ignores
arguments** and regenerates only what is uncommented in `/etc/locale.gen`, where
`en_US.UTF-8` was still commented out. The following
`dpkg-reconfigure --frontend=noninteractive locales` reads the same file, so it
is equally ineffective. Result: `locale -a` showed no `en_US` at all, despite
Koha requiring it, and the script would have reported success.

Fixed on this host by uncommenting the entry first:

```bash
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
```

`locale -a` now reports `en_US.utf8`. The script should be changed to do the same,
and to verify with `locale -a | grep -q en_US` rather than assuming success.

## Production hardening

Ordered by risk. **None of these are done.** The instance is functional but
should be treated as LAN-internal until at least steps 1-3 are complete.

### 1. Terminate TLS (highest priority)

Both interfaces serve plain HTTP on ports 81/82, so staff credentials, patron
records and session cookies cross the network in clear text — the verification
login performed during this migration sent its password unencrypted.

```bash
apt-get install -y certbot python3-certbot-apache   # or deploy an internal CA cert
a2enmod ssl
# add <VirtualHost *:443> blocks mirroring the :81/:82 vhosts, then redirect 81/82 -> 443
```

Koha must also be told it is behind HTTPS: set the `OPACBaseURL` and
`staffClientBaseURL` system preferences to their `https://` forms, or generated
links and cookie flags will stay on http.

### 2. Secure MariaDB root

`root@localhost` currently has an **empty password** with
`mysql_native_password`. Prefer socket auth so no credential needs storing, and
because it keeps the script's passwordless `mysql` calls working for root while
blocking password logins:

```bash
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;"
mysql -e "SELECT 1;"   # confirm root still works locally afterwards
```

### 3. Rotate the staff passwords

All 3 staff accounts share the committed `ADMIN_TEMP_PASS` default. Either have
each user set their own at first login, or assign distinct strong values
(`pwgen` is installed):

```bash
pwgen -sy 20 1
```

### 4. Close the cutover gap

The database reflects `192.168.20.254` as of **2026-08-16**. Any circulation on
the old server after that timestamp is not present here. Before go-live: stop
Apache/Plack there, take a final `koha-dump`, and either redo the restore against
it or accept the delta. Do not run both servers concurrently — divergent
circulation data cannot be merged afterwards.

### 5. Get backups off this host

`cron.daily/koha-common` runs `koha-run-backups --days 2 --output /var/spool/koha`
— only 2 days of retention, on the same disk as the database it protects. Add
off-host replication and rehearse a restore.

### 6. DNS

Point `atslibrary.atseminary.ac.ke` and `atslibrary-intra.atseminary.ac.ke` at
`192.168.20.252`. Each vhost is currently the only one on its port, so both
answer to any Host header; that stops being true once TLS/SNI or further vhosts
are added.

### 7. Decommission the old server

Only after the cutover gap is closed and the data has been checked in anger by
library staff.

## Cleanup steps

None of these are blocking; all are outstanding.

### Modified package files

21 files under `db_revs/` still carry the `eval {}` wrappers. They are inert now
that the upgrade is complete, and the next `koha-common` package upgrade will
silently overwrite them. To restore package integrity now:

```bash
# pristine copies extracted during recovery (152 MB — delete afterwards)
cp -f /tmp/kohadeb/usr/share/koha/intranet/cgi-bin/installer/data/mysql/db_revs/*.pl \
      /usr/share/koha/intranet/cgi-bin/installer/data/mysql/db_revs/
# or, if /tmp has been cleared:
apt-get install --reinstall koha-common
```

### Dumps in /root

```bash
rm -f /root/atslibrary-2019-01-13.sql.gz /root/atslibrary-2025-09-06.sql.gz  # 0-byte, corrupt
```

Keep `atslibrary-2026-08-16.sql.gz` (26 MB) until the cutover is verified — it is
the only rollback path to the pre-upgrade state. `atslibrary-2026-08-15.sql.gz`
is byte-identical in size and redundant. Move the keeper off this host; it is
not covered by any backup here.

### Temporary artefacts

```bash
rm -rf /tmp/kohadeb /tmp/fix_fk_drops.py /tmp/fix_fk_drops2.py
rm -f /root/.migrate_exit /root/.upgrade_exit /root/.upgrade_exit2 /root/migrate-wrapper.out
```

`/root/upgrade-resume.log` and `upgrade-resume2.log` hold the Phase 6 migration
transcripts — worth retaining for audit, then deleting.

### Security

- MariaDB `root@localhost` still has an **empty password** (see Credentials 2).
- `/root/koha-migration-*.log`, `upgrade-resume*.log` and `zebra-rebuild.log` are
  world-readable (`0644`). They do **not** contain the staff password, because
  Phase 11 was run outside the script — but they do expose full schema and
  infrastructure detail. `chmod 600` them, or delete after audit.
- The `.gitignore` keeps logs, dumps, `.ssh/` and shell history out of git; keep
  it that way. `koha_migrate_new_server.sh` remains untracked — parameterise
  `ADMIN_TEMP_PASS` before committing it.

## Notes on the script

### Phase 4 — dump discovery and remote transfer

Resolution order: newest `/root/atslibrary-*.sql.gz` → newest
`/var/spool/koha/atslibrary/atslibrary-*.sql.gz` on the old server → generate one
remotely with `koha-dump`. The ssh/scp calls share one multiplexed connection
(`ControlMaster`/`ControlPersist`) so a password is requested at most once. The
dump is then checked for existence, non-zero size, and gzip integrity before the
database is dropped, so a truncated transfer cannot destroy the target database.

### Phases 5-6 — MariaDB 11.x compatibility

MariaDB 10.6+ raises error 1832 on `ALTER TABLE ... CONVERT TO CHARACTER SET`
when foreign keys reference the columns, even with `foreign_key_checks = 0`. This
breaks Koha migration `17.12.00.016`. The script patches `updatedatabase.pl` in
place to drop all FK constraints before that conversion, and shrinks the four
`columns_settings` primary-key columns to `VARCHAR(191)` so the composite key
fits InnoDB's 3072-byte limit under utf8mb4. Because those FKs are gone, later
`db_revs/*.pl` files that `DROP FOREIGN KEY` are rewritten to wrap those
statements in `eval {}`. The original `updatedatabase.pl` is restored from
`.orig` after a successful upgrade.

If the upgrade aborts mid-way, check for a leftover
`/usr/share/koha/intranet/cgi-bin/installer/data/mysql/updatedatabase.pl.orig`
and restore it manually before retrying, so patches are not applied twice.

### Fixed defect: silent abort at Phase 4

The first migration attempt exited with code **2** immediately after the Phase 4
banner, printing no error. Cause: the dump lookup was

```bash
DUMP_FILE=$(ls -t /root/${INSTANCE}-*.sql.gz 2>/dev/null | head -1)
```

With no matching file, `ls` exits 2; `set -o pipefail` propagated that through
the pipeline and `set -e` aborted the script on the assignment. The `2>/dev/null`
hid the reason. This ran *before* the fallback `scp` and the "SQL dump not found"
message, making both unreachable — the failure looked like a database error when
in fact no dump had ever been copied to the server. The lookup now ends in
`|| true` and the diagnostics are reachable.
