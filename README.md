# Koha 16.11 → 26.05 Server Migration

Migration of the `atslibrary` Koha instance from the legacy server onto a fresh
Debian 13 (Trixie) host, driven by `koha_migrate_new_server.sh`.

## Status: LIVE IN PRODUCTION (2026-10-03) — cut over to 192.168.1.251; hardening is now urgent, not optional

The validation project closed on 2026-08-27 after two successful test-network
runs (`192.168.20.252`, then `192.168.20.251`). On **2026-10-03**, the same
script was used to cut `atslibrary` over for real on the production network:
source `192.168.1.254` → destination `192.168.1.251` (see **Production
migration run** below). Findings 4, 5 and 6 required zero manual intervention
for the second consecutive run; Finding 3 recurred and was fixed the same way;
Findings 7 and 8 were reproduced and fixed with the same unmodified scripts.
The instance is live and serving the real `atslibrary` collection.

**This changes the urgency of Production hardening below.** Every item there
(no HTTPS, empty MariaDB root password, shared staff password, 2-day
local-only backups, DNS, old-server decommissioning) now applies to a live
production system handling real patron data, not a test replica. Treat it as
the immediate next work, not deferred follow-up. The ~4,629 legacy items with
no barcode (Finding 8's "Not fixed" note) remain a separate, lower-priority
item.

### Original run (192.168.20.252) — phase-by-phase

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
manual intervention below. Findings 4, 5 and 6 are now fixed in
`koha_migrate_new_server.sh` itself (2026-08-25, ahead of a fresh run against
`192.168.20.251`), so a from-scratch re-run elsewhere should no longer need
those manual interventions — but do not run it against `atslibrary` on this
host, since Phase 4 still unconditionally drops `koha_atslibrary` and would
discard the Finding 7/8 data fixes, which live only in the database, not the
script.

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

Nine issues were hit across two migration runs: four defects in
`koha_migrate_new_server.sh` (items 1, 4, 5 and 6), three data problems in the
source database (items 3, 7 and 8), one anomaly in the transferred dumps
(item 2), and one environment/provisioning defect hit on a freshly cloned VM
(item 9).

Fix status — **items 1, 4, 5 and 6 are now fixed in the script itself**
(items 4-6 were originally worked around by hand on this host on 2026-08-16,
then fixed in `koha_migrate_new_server.sh` on 2026-08-25 ahead of a fresh run
against a new host, `192.168.20.251`). Items 7 and 8 were found after the
migration was already considered complete (via 500 error reports) and are fully
fixed on `atslibrary` — see below; they are data problems in the source
database, not script defects, so they're addressed with the standalone,
re-runnable `apply_*_fix_*.sql` scripts rather than folded into the script.
Item 9 is a one-off VM provisioning defect (stale `/etc/hosts`), fixed directly
on the affected host with no script or data change required. See **Second
migration run** below for how items 3, 4, 5, 6 and 9 played out on
`192.168.20.251`.

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

### 4. Phase 5 Patch 2 missed multi-line statements (script defect — fixed 2026-08-25)

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

Originally fixed by patching the installed `db_revs` files directly on this host,
with the script's own Patch 2 regexes left unchanged. **Now fixed in the script
itself (2026-08-25):** the three patterns were replaced with brace-bounded
equivalents that tolerate whitespace/newlines around the delimiters —
`\$dbh->do\(\s*qq?\{[^{}]*DROP FOREIGN KEY[^{}]*\}\s*\)` (and the `q|...|` /
double-quoted variants) — plus a negative lookbehind so an already-`eval{}`-wrapped
call is left alone on a re-run, and a `perl -c` gate (reverting the file if it
fails to compile) after every edit.

### 5. Phase 5 re-patch hazard (script defect — fixed 2026-08-25)

Phase 5 ran `cp $UPD_PL $UPD_PL.orig` unconditionally. If the script were re-run
after a Phase 6 failure, that would copy the *already patched* file over the
pristine backup, so the eventual restore would restore a patched file and Patch 1
would be applied twice. Worked around on this host by resuming with
`koha-upgrade-schema atslibrary` directly instead of re-running the script.

**Now fixed in the script:** the backup is skipped if `${UPD_PL}.orig` already
exists, and Patch 1's insertion is guarded by a marker check (skips if the
MariaDB-11.x-patch comment is already present), so a re-run after a partial
failure is a safe no-op instead of double-patching.

### 6. Phase 8 locale generation is a no-op on Debian (script defect — fixed 2026-08-25)

The script ran `locale-gen en_US.UTF-8`. Debian's `locale-gen` **ignores
arguments** and regenerates only what is uncommented in `/etc/locale.gen`, where
`en_US.UTF-8` was still commented out. The following
`dpkg-reconfigure --frontend=noninteractive locales` reads the same file, so it
was equally ineffective. Result: `locale -a` showed no `en_US` at all, despite
Koha requiring it, and the script would have reported success.

Fixed on this host by uncommenting the entry first:

```bash
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
```

`locale -a` now reports `en_US.utf8`. **Now fixed in the script itself:** it runs
the same `sed` + `locale-gen` sequence, then verifies with
`locale -a | grep -q '^en_US.utf8$'` and `die`s with a clear message if the
locale still isn't present, instead of assuming success.

### 7. Missing item types across nearly the entire collection (data problem in the source database — fixed)

Discovered days after the migration was signed off, via a staff 500 error on
`catalogue/detail.pl?biblionumber=44945&audit=1`:

```
Item with itemnumber=42445 does not have an itype value, additionally no item
type defined for biblionumber=44945
```

`items.itype` was NULL for **26,492 of 26,533 items (99.8%)**, and
`biblioitems.itemtype` was NULL for 16,388 records — leaving **26,475 items with
no resolvable item type at all** (item-level and biblio-level fallback both
empty). Root cause is in the *source* data, not this migration: affected
biblios' MARCXML (e.g. biblio 44945) contains no `942` or `952` fields at all,
confirming items were bulk-loaded directly into the `biblio`/`biblioitems`/`items`
tables on the old 16.11 server (or earlier) rather than catalogued through MARC,
and item type was simply never populated. `koha_migrate_new_server.sh` only
moves and upgrades the schema — it does not touch item-level data — so it neither
caused nor could have caught this.

Missing item type is more than a cosmetic gap: `Koha::Item::_status()`
(`Koha/Item.pm` line 1672) calls `$self->item_type->notforloan` without a
definedness check, so any item with no resolvable type throws
`Can't call method "notforloan" on an undefined value` and 500s the staff detail
page and the `/api/v1/biblios/{id}/items` endpoint it depends on.

A secondary, still-live gap made this hard to fix by hand: the `CAT` and `KIN`
cataloguing frameworks had **no `942` tag/subfield structure at all** (only the
Default framework did), so catalogers using them had no way to set item type via
the MARC editor.

**Fix applied to `atslibrary` (2026-08-16):**

- `identify_missing_itemtypes.sql` — read-only diagnostics (counts, full broken-item
  list, itemtype list, frameworks missing the `942$c` mapping).
- `apply_itemtype_fix_20260816.sql` — idempotent, transactional fix:
  backfills `items.itype` / `biblioitems.itemtype` (4 physical Kindle e-readers,
  identified by title, got `KINDLE`; everything else defaulted to `BOOK`, the
  only other item type defined in this system), then copies the full `942` block
  from the Default framework into `CAT` and `KIN` so cataloging can set item type
  going forward. Run with `koha-mysql atslibrary < apply_itemtype_fix_20260816.sql`,
  followed by a `Koha::Caches->flush_all` and a `koha-rebuild-zebra -f -v atslibrary`
  (item type is indexed).
- `koha-check-missing-itemtypes.sh` — deployed to
  `/usr/local/sbin/koha-check-missing-itemtypes.sh` with a daily cron entry
  (`/etc/cron.d/koha-itemtype-audit`) so a regression is caught before it 500s a
  patron or staff member again.

Verified via an authenticated smoke test (temporary superlibrarian password, set
and restored via `Koha::Patrons->set_password`, never logged): the original URL
and its underlying API call both now return HTTP 200 with `effective_item_type_id
"BOOK"`, and `plack-api-error.log` shows no new occurrences of the crash.

**Not fixed — a training/process gap, not a script or config bug:** one item
(added 2026-07-20, after this migration) was still saved with a blank item type
under the *Default* framework, which already had the `942$c` mapping marked
mandatory. Koha only enforces "mandatory" item subfields with client-side JS on
the Add/Edit item screen, not a hard server-side check, so it can still be saved
blank. No further automated fix is possible here without a code change to Koha
itself; mitigate with staff training and/or the monitoring cron above.

### 8. Items missing home and holding library (data problem in the source database — fixed)

Discovered the same way as item 7: a staff 500 error on
`catalogue/detail.pl?biblionumber=54120&audit=1`:

```
Item with itemnumber=61839 does not have home and holding library defined
```

`items.homebranch` / `items.holdingbranch` were NULL for 14 items across 11
biblios at first discovery, then found to affect **4,629 items** system-wide
once checked comprehensively (spanning accession dates from 2017 through 2026,
87% from the 2017-2018 bulk load). Root cause traced via `import_batches`:
batch id 8 (`2017.01.30_Mandarin_Export_New_&_ICM_Joined_Deduplicated_ATSMAIN.mrc`,
imported 2017-02-01) was run with `branchcode` left `NULL`, so any source MARC
record lacking `952$a`/`$b` produced an item with no branch at all — the same
class of defect as item 7's missing `942$c`, just for a different item field.

The same secondary gap applied here too: `952$a` (homebranch) and `952$b`
(holdingbranch) were not `mandatory` and had no `defaultvalue` in **any**
framework (Default, `CAT`, `KIN`), so staff using the manual Add/Edit item
screen had nothing stopping them from leaving the branch blank either.

**Fix applied to `atslibrary` (2026-08-17/20) — only the 14 items actually
causing 500 errors were backfilled at first; the remaining historical items
with no barcode but valid branches were investigated separately and are
*not* part of this fix (see the barcode note below).** All items with a
missing branch (the 14, confirmed to have no active checkouts/holds) were
backfilled to `ATSMAIN`, the only library defined in this instance:

- `identify_missing_libraries.sql` — read-only diagnostics (counts, full
  affected-item list, accession-year distribution, framework mandatory/default
  gaps, and the responsible `import_batches` row).
- `apply_library_fix_20260820.sql` — idempotent, transactional fix: backfills
  `items.homebranch` / `items.holdingbranch` to `ATSMAIN`, adds a schema-level
  `DEFAULT 'ATSMAIN'` to both columns (so any future insert that omits them —
  manual, bulk import, or API — no longer defaults to NULL), then sets
  `mandatory=1` and `defaultvalue='ATSMAIN'` on `952$a`/`952$b` across Default,
  `CAT` and `KIN`, mirroring the `942$c` fix for item 7. Run with
  `koha-mysql atslibrary < apply_library_fix_20260820.sql`, followed by
  `koha-plack --restart atslibrary` to refresh the cached framework structures.
- `koha-check-missing-libraries.sh` — deployed to
  `/usr/local/sbin/koha-check-missing-libraries.sh` with a daily cron entry
  (`/etc/cron.d/koha-library-audit`), since a bulk import can still write an
  explicit `NULL` and bypass both the schema default and the GUI mandatory
  check.

Verified: the originally-failing URL and the staff/OPAC homepages all return
HTTP 200, and `SELECT COUNT(*) FROM items WHERE homebranch IS NULL OR
holdingbranch IS NULL` returns 0.

**Not fixed — a separate, lower-severity finding:** ~4,629 items (mostly from
the same 2017-2018 batch) have a valid branch but no barcode. This does not
cause a 500 and was left untouched at the site owner's request; if it needs
remediating for production, treat it as a distinct finding rather than folding
it into this script, since auto-generating barcodes for legacy records risks
colliding with physical labels that were never entered into Koha.

**Caveat for the single-branch default above:** if this instance ever gains a
second library, `apply_library_fix_20260820.sql` must **not** be replayed
as-is — the hard-coded `ATSMAIN` default would silently misassign new items to
the wrong branch. Re-derive the correct default (or make it per-import-batch)
before reusing this script.

### 9. Stale `/etc/hosts` entry broke RabbitMQ on a from-scratch install (environment defect — fixed)

Hit on the first boot of a second, separate migration target, `192.168.20.251`
(a freshly cloned Debian 13 VM). Phase 1 failed at `dpkg --configure`:

```
Setting up rabbitmq-server (4.0.5-6+deb13u2) ...
Job for rabbitmq-server.service failed because the control process exited with error code.
dpkg: error processing package rabbitmq-server (--configure):
 installed rabbitmq-server package post-installation script subprocess returned error exit status 1
dpkg: dependency problems prevent configuration of koha-common:
 koha-common depends on rabbitmq-server; however:
  Package rabbitmq-server is not configured yet.
```

systemd/`journalctl` showed only a generic exit-code failure; the real cause
was in RabbitMQ's own log (`/var/log/rabbitmq/rabbitmq-server.log`):

```
ERROR: epmd error for host Koha-New-V2: address (cannot connect to host/port)
```

`/etc/hosts` (auto-generated by the Proxmox VE template, inside a
`# --- BEGIN PVE --- / --- END PVE ---` block) mapped the box's own hostname
to a stale IP left over from provisioning (`192.168.20.152`) instead of its
real address (`192.168.20.251`, confirmed via `ip addr`). RabbitMQ's Erlang
runtime resolves the local hostname via `epmd` and tries to bind to that
address; since `192.168.20.152` wasn't assigned to any interface on the host,
the bind failed, and `koha-common` — which depends on `rabbitmq-server` —
could never configure either, aborting Phase 1 entirely.

Fixed by correcting the IP in that block of `/etc/hosts` to the host's real
address, then `dpkg --configure -a` completed cleanly with no further changes.
This is **not a defect in `koha_migrate_new_server.sh`** — it's specific to how
this VM template provisions `/etc/hosts` on clone/boot. Check
`ip addr`/`/etc/hosts` agreement before running the script on any freshly
cloned or templated VM.

## Second migration run: validating the fixes on 192.168.20.251 (2026-08-27)

A from-scratch run against a second, separate host (`192.168.20.251`, also
pulling from the same source server `192.168.20.254`) was carried out
specifically to validate the Finding 4/5/6 script fixes and confirm Findings 7
and 8 reproduce and can be re-applied cleanly against a fresh pull of the same
source data.

**Findings 4, 5 and 6 required zero manual intervention** — the schema upgrade
(16.11 → 26.05) ran through Phase 6 without any Perl patching, corruption, or
locale silent-failure, confirming the fixes hold on a clean run. Two issues
were still hit, both expected and independent of those fixes:

- **Finding 3 recurred** (the same orphaned `user_permissions` row —
  `borrowernumber 100`, `suggestions_manage`) — expected, since it's a data
  problem on `192.168.20.254` (the source), not something
  `koha_migrate_new_server.sh` addresses. Fixed with the same one-line remap,
  then resumed via `koha-upgrade-schema atslibrary` directly (per the Finding 5
  write-up) instead of re-running the whole script, which would have re-wiped
  Phase 4's completed restore.
- **Finding 9** (new, see above) blocked Phase 1 entirely on first boot; fixed
  by correcting `/etc/hosts`, unrelated to the migration script.

After Phase 6 completed, Phases 7-11 were run via a small ad hoc resume script
(`resume_phases_7_11.sh`, not committed to this repo) extracted from the main
script's own Phase 7-11 blocks — needed only because Phase 6 had to be resumed
out-of-band via `koha-upgrade-schema` directly rather than through the main
script. Findings 7 and 8 were then reproduced (26,526 items with no `itype`;
14 items with no home/holding library, including the original `itemnumber
61839` from the first report) and fixed with the same `apply_itemtype_fix_20260816.sql`
/ `apply_library_fix_20260820.sql` scripts unchanged, confirming they're
portable across instances built from the same source data.

Final state on `192.168.20.251`: Koha `26.0503000`, 16,422 biblios, 26,567
items, 450 patrons, staff (`:81`) and OPAC (`:82`) both HTTP 200, and both
`identify_*.sql` diagnostics returning 0 affected rows. The same
production-hardening gaps documented for `192.168.20.252` apply here too (see
**Production hardening** below) — this host has not been hardened either.

## Production migration run: 192.168.1.251 (2026-10-03)

The real production cutover, distinct from the two test-network validation
runs above (`192.168.20.252`/`192.168.20.251`). Source `192.168.1.254` is the
actual production Koha 16.11 server (hostname `ATSagape`, same institution's
live `atslibrary` data — not a copy); destination `192.168.1.251` is a fresh
Debian 13 host on the real production network.

**Pre-flight:** verified passwordless root SSH in all directions (orchestrating
host → source, orchestrating host → destination, source ↔ destination — the
last of these needed `StrictHostKeyChecking=no` instead of `accept-new`, since
the source's older OpenSSH client doesn't support that option), confirmed the
destination's `/etc/hosts` correctly matched its real IP (no repeat of Finding
9), checked internet/DNS reachability, and confirmed a blank `koha-common`
install. The migration script and fix scripts were pulled fresh from this
GitHub repo rather than reusing a stale local copy that predated the Finding
4/5/6 fixes. `OLD_SERVER_IP` in the script's `CONFIGURATION` block (hardcoded
to the test network's `192.168.20.254`) was updated to the real source,
`192.168.1.254`, before running.

A fresh `koha-dump atslibrary` was taken on the source immediately before
starting, since data had changed since the cron-generated dump from earlier
that day — the script picks the newest dump by mtime, so this is the one it
used.

**Findings 4, 5 and 6 again required zero manual intervention** — the second
consecutive clean run (after `192.168.20.251`), now on real production data
and a different subnet, reinforcing that the script fixes are not network- or
dataset-specific.
**Finding 3 recurred** identically (`borrowernumber 100`, `suggestions_manage`)
and was fixed the same way, resuming via `koha-upgrade-schema atslibrary`
directly. **Findings 7 and 8** were reproduced (26,526 items with no `itype`;
14 items with no home/holding library, including the original `itemnumber
61839`) and fixed with the same unmodified `apply_itemtype_fix_20260816.sql` /
`apply_library_fix_20260820.sql` scripts. Both monitoring cron jobs were
deployed.

**Smoke test** (beyond the standard HTTP 200 checks): authenticated login was
verified for all three staff accounts directly against `C4::Auth::checkpw`
(not by scraping the login form, which Koha 26's CSRF middleware correctly
rejects without a token) — all three returned a successful auth. Catalogue
search (staff and OPAC) returned results via Zebra. Four separate biblio
detail pages, including the original Finding 8 URL
(`biblionumber=54120&audit=1`), all returned HTTP 200. `plack-intranet-error.log`
and `plack-api-error.log` were clean except for one expected CSRF warning from
the login-form test itself.

Final state: Koha `26.0503000`, 16,422 biblios, 26,567 items, **453** patrons
(slightly more than the `192.168.20.251` test run's 450, consistent with real
ongoing circulation activity on the production source). The temporary staff
password is stored in `/root/.koha_atslibrary_admin_temp_pass` on
`192.168.1.251` (root-only, never echoed to any log or chat transcript). This
run's scripts are tagged in this repo as `production-cutover-20261003`; its
host-side artefacts are archived under **Cleanup steps** below.

## Production hardening

Ordered by risk. **None of these are done, and this is now a live system.**
The instance should be treated as LAN-internal and at material risk until at
least steps 1-3 are complete — this is no longer a test replica.

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

### Done (2026-08-16)

Removed from `/root`: all three `koha-migration-*.log` files, `upgrade-resume.log`,
`upgrade-resume2.log`, `zebra-rebuild.log`, `migrate-wrapper.out`, the
`.migrate_exit` / `.upgrade_exit` / `.upgrade_exit2` / `.zebra_exit` markers, and
the two 0-byte corrupt dumps (`atslibrary-2019-01-13.sql.gz`,
`atslibrary-2025-09-06.sql.gz`).

The raw migration transcripts are therefore gone; the findings above are the
surviving record. None of the deleted files were tracked by git.

`/root` now holds only `README.md`, `koha_migrate_new_server.sh`, the two valid
dumps, `atslibrary.conf.koha-create.bak` (pre-Phase-7 vhost, kept so the Apache
change can be reverted) and the `.git` repository.

### Production host cleanup (192.168.1.251, 2026-10-03)

Unlike the 2026-08-16 cleanup on `192.168.20.252` (which deleted the raw
transcripts), the production run's artefacts were **archived, not deleted**,
since this is a live system and the audit trail has more value than tidiness.
Moved into `/root/migration-archive-20261003/` (mode `700`, root-only):

- `koha-migration-20261003-100946.log` — the main script's Phase 1-6 run log
- `koha-migration-resume-20261003-105652.log` — the Phase 7-11 resume run log
- `upgrade_resume.out` — output of the direct `koha-upgrade-schema atslibrary`
  call used to resume past the Finding 3 orphan-permission block
- `resume_phases_7_11.sh` — the ad hoc resume script itself (not committed to
  this repo, same as the `192.168.20.251` run — kept here for audit only)
- `atslibrary-2026-10-03.sql.gz` (26 MB) — the pre-upgrade dump; **the only
  rollback path** to the pre-migration state, same caveat as the "Dumps in
  /root" note below: keep until the cutover gap (hardening step 4) is closed
  and staff have verified the data

`migrate_run.out` and `resume_711.out` were deleted outright (not archived):
both were byte-for-byte duplicates of the two `.log` files above, since the
script's own `tee` to `$LOGFILE` and the launcher's `nohup ... > file`
redirect captured the identical stdout stream twice.

`/root` on `192.168.1.251` now holds only the tracked scripts (pulled fresh
from this repo), the two `identify_*.sql`/`apply_*_fix_*.sql` pairs, the
`.koha_atslibrary_admin_temp_pass` file, and the `migration-archive-20261003/`
directory.

### Still outstanding

None are blocking.

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

### Dumps in /root — deliberately retained

`atslibrary-2026-08-16.sql.gz` (26 MB) is the **only rollback path** to the
pre-upgrade state and must be kept until the cutover gap (hardening step 4) is
closed and staff have verified the data. `atslibrary-2026-08-15.sql.gz` is the
previous day's dump and is redundant once the newer one is proven good.

Both still exist on the old server under `/var/spool/koha/atslibrary/`, so loss
here is recoverable while `192.168.20.254` is alive — but that ceases to be true
at decommissioning. Move at least the `2026-08-16` dump off both hosts.

### Temporary artefacts outside /root

```bash
rm -rf /tmp/kohadeb /tmp/fix_fk_drops.py /tmp/fix_fk_drops2.py
```

`/tmp/kohadeb` (152 MB) holds the pristine `db_revs` copies extracted from the
cached `.deb`. **Keep it until the "Modified package files" item above is
actioned**, otherwise reverting those 21 files needs an
`apt-get install --reinstall koha-common`.

### Security

- MariaDB `root@localhost` still has an **empty password** (see Credentials 2).
- The migration logs have been deleted, so no on-disk artefact now exposes the
  schema or infrastructure detail. Future runs of the script will recreate
  world-readable (`0644`) logs in `/root` — and its Phase 11 writes the temporary
  staff password into them in clear text.
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
