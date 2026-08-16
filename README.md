# Koha 16.11 → 26.05 Server Migration

Migration of the `atslibrary` Koha instance from the legacy server onto a fresh
Debian 13 (Trixie) host, driven by `koha_migrate_new_server.sh`.

## Status: BLOCKED at Phase 4 (awaiting credentials)

| Phase | Description | State |
|-------|-------------|-------|
| 1 | Install `koha-common` + MariaDB | Done |
| 2 | Configure Apache (modules, ports 81/82) | Done |
| 3 | Create Koha instance `atslibrary` | Done |
| 4 | Transfer + restore database from old server | **Blocked — no SQL dump on this host** |
| 5 | MariaDB 11.x compatibility patches | Not started |
| 6 | Schema upgrade (16.11 → 26.05, ~500 migrations) | Not started |
| 7 | Apache vhost for Plack | Not started |
| 8 | Locale + log ownership | Not started |
| 9 | Start/restart services, HTTP smoke test | Not started |
| 10 | Rebuild Zebra search indexes | Not started |
| 11 | Reset staff passwords | Not started |

`koha_atslibrary` currently exists but contains **0 tables** — it is the empty
database created by `koha-create`, not a partial restore. Nothing is at risk of
being left half-migrated; Phase 4 validates the dump *before* it drops anything.

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

Only **one** credential is missing to finish the migration.

### 1. Root SSH access to the old server (REQUIRED — this is the blocker)

Needed solely to pull the SQL dump from `192.168.20.254`. The old server offers
`publickey,password`; this host currently has **no private key** for it
(`/root/.ssh/` holds only `authorized_keys`, which governs inbound access here).

Supply it in one of two ways — never paste the password into a script, a shell
one-liner, or this file:

```bash
# Option A (preferred) — install a key once, then the migration runs unattended.
# Prompts for the old server's root password a single time.
ssh-copy-id root@192.168.20.254

# Option B — copy the dump by hand, then the script needs no SSH at all.
scp root@192.168.20.254:/var/spool/koha/atslibrary/*.sql.gz /root/
```

Option A is preferable when the old server has no recent dump, because the
script will then invoke `koha-dump atslibrary` remotely and fetch the result.

### 2. MariaDB root on this host (already usable — but insecure)

The script runs `mysql` as the local root account with no credentials, which
works today because **MariaDB `root@localhost` has an empty password** and uses
`mysql_native_password`. No action is needed to complete the migration, but set
a password (or switch to `unix_socket` auth) before this host serves traffic.

### 3. Temporary staff password (Phase 11)

Phase 11 overwrites the password of **every** account with `flags > 0`, because
passwords may have changed on the old server after the dump was taken. The value
comes from `ADMIN_TEMP_PASS` in the script's CONFIGURATION block.

- Change it from the committed default before running Phase 11.
- It is echoed to stdout *and* into the log file at the end of the run — treat
  `/root/koha-migration-*.log` as sensitive, and require a password change at
  first login.

## Completing the migration

Once the dump is on this host (or key auth is in place):

```bash
cd /root
./koha_migrate_new_server.sh
```

Re-running the whole script is safe. Phases 1-3 are idempotent: packages are
already installed, `a2enmod` reports "already enabled", and Phase 3 detects the
existing instance and skips `koha-create`. Execution resumes effectively at
Phase 4. Expect the schema upgrade in Phase 6 to take several minutes.

### Verifying success

The script fails loudly (`die`) if the upgrade does not reach version 26, and
prints a summary with biblio/item/patron counts. Manual checks:

```bash
mysql koha_atslibrary -Ne "SELECT value FROM systempreferences WHERE variable='Version';"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:81/   # staff, expect 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:82/   # OPAC
koha-plack --status atslibrary
```

### Post-migration tasks

1. Log in and confirm the data looks correct.
2. Have every staff member change their own password.
3. Point DNS for `atslibrary.atseminary.ac.ke` and
   `atslibrary-intra.atseminary.ac.ke` at `192.168.20.252`.
4. Set a MariaDB root password (see Credentials section 2).
5. Decommission the old server once satisfied.

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
