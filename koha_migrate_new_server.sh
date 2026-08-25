#!/bin/bash
# =============================================================================
# STEP 2 OF 2: Koha 16.11 → 26.05 Migration Script
# Run this on the NEW server (Debian 13 Trixie — fresh OS install)
#
# Prerequisites on new server before running:
#   1. Debian 13 (Trixie) installed with SSH access as root
#   2. Internet access for package downloads
#   3. The SQL dump from the old server copied to /root/
#      (filename like: atslibrary-YYYY-MM-DD.sql.gz)
#
# Usage:
#   1. Edit the CONFIGURATION section below
#   2. Copy your SQL dump to /root/ on this server
#   3. Run:  bash koha_migrate_new_server.sh
# =============================================================================

# =============================================================================
# CONFIGURATION — Edit these to match your environment
# =============================================================================
INSTANCE="atslibrary"           # Koha instance name (must match old server)
OLD_SERVER_IP="192.168.20.254"  # IP of the old Koha server (to pull the dump)
DOMAIN=".atseminary.ac.ke"      # Domain suffix
INTRAPORT="81"                  # Staff (intranet) port
OPACPORT="82"                   # OPAC port
INTRASUFFIX="-intra"            # Staff hostname suffix

# Temporary password set for all staff accounts (Phase 11). Never hardcode a
# real password here -- this file is tracked in git. Set it in the
# environment before running, e.g.:
#   ADMIN_TEMP_PASS="$(pwgen -sy 20 1)" bash koha_migrate_new_server.sh
ADMIN_TEMP_PASS="${ADMIN_TEMP_PASS:?Set ADMIN_TEMP_PASS in the environment before running, e.g. ADMIN_TEMP_PASS=\$(pwgen -sy 20 1) bash koha_migrate_new_server.sh}"
# =============================================================================

set -euo pipefail
LOGFILE="/root/koha-migration-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "============================================================"
echo " Koha 16.11 → 26.05 Migration"
echo " $(date)"
echo " Log: $LOGFILE"
echo "============================================================"
echo ""
echo "Instance  : $INSTANCE"
echo "Domain    : $DOMAIN"
echo "Staff URL : http://${INSTANCE}${INTRASUFFIX}${DOMAIN}:${INTRAPORT}/"
echo "OPAC URL  : http://${INSTANCE}${DOMAIN}:${OPACPORT}/"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Helper: print step header
step() {
  echo ""
  echo "══════════════════════════════════════════"
  echo " $*"
  echo "══════════════════════════════════════════"
}
die() {
  echo "ERROR: $*" >&2
  exit 1
}
# ─────────────────────────────────────────────────────────────────────────────

# =============================================================================
# PHASE 1 — Install Koha packages
# =============================================================================
step "PHASE 1: Installing Koha and MariaDB"

apt-get update -qq
apt-get install -y -qq gpg curl wget apt-transport-https ca-certificates python3

# Add Koha GPG key and repository
wget -qO- https://debian.koha-community.org/koha/gpg.asc |
  gpg --dearmor >/usr/share/keyrings/koha-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/koha-keyring.gpg] \
https://debian.koha-community.org/koha stable main" \
  >/etc/apt/sources.list.d/koha.list

apt-get update -qq
apt-get install -y koha-common mariadb-server
echo "Installed: $(dpkg -l koha-common | grep '^ii' | awk '{print $3}')"

# =============================================================================
# PHASE 2 — Configure Apache
# =============================================================================
step "PHASE 2: Configuring Apache"

a2enmod rewrite cgi headers proxy_http
a2dissite 000-default 2>/dev/null || true
systemctl restart apache2

# Add ports 81 and 82 to ports.conf
if ! grep -q "Listen ${INTRAPORT}" /etc/apache2/ports.conf; then
  echo "Listen ${INTRAPORT}" >>/etc/apache2/ports.conf
fi
if ! grep -q "Listen ${OPACPORT}" /etc/apache2/ports.conf; then
  echo "Listen ${OPACPORT}" >>/etc/apache2/ports.conf
fi

# =============================================================================
# PHASE 3 — Configure Koha site settings and create instance
# =============================================================================
step "PHASE 3: Creating Koha instance"

# Update koha-sites.conf
cat >/etc/koha/koha-sites.conf <<SITESCONF
DOMAIN="${DOMAIN}"
INTRAPORT="${INTRAPORT}"
INTRAPREFIX=""
INTRASUFFIX="${INTRASUFFIX}"
OPACPORT="${OPACPORT}"
OPACPREFIX=""
OPACSUFFIX=""
DEFAULTSQL=""
ZEBRA_MARC_FORMAT="marc21"
ZEBRA_LANGUAGE="en"
USE_MEMCACHED="yes"
MEMCACHED_SERVERS="127.0.0.1:11211"
MEMCACHED_PREFIX="koha_"
SITESCONF

# Idempotent: a re-run after a later phase failed must not abort here.
if [ -f "/etc/koha/sites/${INSTANCE}/koha-conf.xml" ]; then
  echo "Instance '$INSTANCE' already exists — skipping koha-create."
else
  koha-create --create-db "$INSTANCE"
  echo "Instance '$INSTANCE' created."
fi

# =============================================================================
# PHASE 4 — Transfer and restore database
# =============================================================================
step "PHASE 4: Restoring database from old server"

# Locate the newest local dump.
# IMPORTANT: a non-matching glob makes `ls` exit non-zero, and with
# `set -e` + `pipefail` that would abort the script silently before the
# remote-transfer fallback below could ever run. Hence the `|| true`.
find_local_dump() {
  ls -t /root/${INSTANCE}-*.sql.gz 2>/dev/null | head -1 || true
}

DUMP_FILE=$(find_local_dump)

if [ -n "$DUMP_FILE" ]; then
  echo "Found local dump: $DUMP_FILE"
else
  echo "No local dump matching /root/${INSTANCE}-*.sql.gz."
  echo "Attempting transfer from old server ${OLD_SERVER_IP}..."

  command -v ssh >/dev/null 2>&1 && command -v scp >/dev/null 2>&1 ||
    die "ssh/scp not available (apt-get install openssh-client), or copy the dump to /root/ manually."

  # Multiplex one connection across the ssh/scp calls below so a password is
  # requested at most once when key-based auth is not configured.
  SSH_CTL="/tmp/koha-migrate-ssh-${INSTANCE}.ctl"
  SSH_OPTS=(
    -o ConnectTimeout=15
    -o ControlMaster=auto
    -o ControlPath="$SSH_CTL"
    -o ControlPersist=120
  )
  cleanup_ssh() {
    ssh "${SSH_OPTS[@]}" -O exit "root@${OLD_SERVER_IP}" 2>/dev/null || true
    rm -f "$SSH_CTL"
  }
  trap cleanup_ssh EXIT

  REMOTE_DIR="/var/spool/koha/${INSTANCE}"

  ssh "${SSH_OPTS[@]}" "root@${OLD_SERVER_IP}" true ||
    die "Cannot reach root@${OLD_SERVER_IP} over SSH. Fix connectivity/credentials, or copy the dump to /root/ manually."

  # Newest existing dump on the old server, if any.
  REMOTE_DUMP=$(ssh "${SSH_OPTS[@]}" "root@${OLD_SERVER_IP}" \
    "ls -t ${REMOTE_DIR}/${INSTANCE}-*.sql.gz 2>/dev/null | head -1" || true)

  if [ -z "$REMOTE_DUMP" ]; then
    echo "No dump present on the old server — generating one with koha-dump..."
    ssh "${SSH_OPTS[@]}" "root@${OLD_SERVER_IP}" "koha-dump ${INSTANCE}" ||
      die "koha-dump failed on ${OLD_SERVER_IP}. Create the dump manually and copy it to /root/."
    REMOTE_DUMP=$(ssh "${SSH_OPTS[@]}" "root@${OLD_SERVER_IP}" \
      "ls -t ${REMOTE_DIR}/${INSTANCE}-*.sql.gz 2>/dev/null | head -1" || true)
    [ -n "$REMOTE_DUMP" ] ||
      die "koha-dump reported success but no dump appeared in ${REMOTE_DIR} on ${OLD_SERVER_IP}."
  fi

  echo "Copying ${REMOTE_DUMP} from ${OLD_SERVER_IP}..."
  scp "${SSH_OPTS[@]}" "root@${OLD_SERVER_IP}:${REMOTE_DUMP}" /root/ ||
    die "Transfer of ${REMOTE_DUMP} from ${OLD_SERVER_IP} failed."

  cleanup_ssh
  trap - EXIT

  DUMP_FILE=$(find_local_dump)
  [ -n "$DUMP_FILE" ] ||
    die "Dump was transferred but no /root/${INSTANCE}-*.sql.gz is present. Check /root/ and retry."
fi

# Validate before dropping the existing database.
[ -f "$DUMP_FILE" ] || die "SQL dump not found. Copy it to /root/ and retry."
[ -s "$DUMP_FILE" ] || die "SQL dump '$DUMP_FILE' is empty — the dump or transfer failed."
gzip -t "$DUMP_FILE" 2>/dev/null ||
  die "SQL dump '$DUMP_FILE' is not a valid gzip file (truncated or corrupt transfer)."

echo "Using dump: $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"

# Get the Koha DB user for the instance
KOHA_DB_USER=$(xmlstarlet sel -t -v 'yazgfs/config/user' \
  /etc/koha/sites/${INSTANCE}/koha-conf.xml)
echo "DB user: $KOHA_DB_USER"

# Drop/recreate the database as utf8mb4 from the start
mysql -e "DROP DATABASE IF EXISTS koha_${INSTANCE};"
mysql -e "CREATE DATABASE koha_${INSTANCE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "GRANT ALL PRIVILEGES ON koha_${INSTANCE}.* TO '${KOHA_DB_USER}'@'localhost';"

# Import dump — convert charset declarations to utf8mb4 inline.
# NOTE: We do NOT pre-convert to utf8mb4 here because some tables have
# primary keys (e.g. columns_settings 4×VARCHAR(255)) that would exceed
# the 3072-byte InnoDB key limit in utf8mb4. The upgrade script handles
# those tables with VARCHAR(191) reductions. We load in native utf8 and
# let koha-upgrade-schema do the conversion properly with our patches.
echo "Restoring database (this may take a few minutes)..."
zcat "$DUMP_FILE" | mysql koha_${INSTANCE}
echo "Database restored."

# =============================================================================
# PHASE 5 — Apply patches for MariaDB 11.x compatibility
# =============================================================================
step "PHASE 5: Applying MariaDB 11.x compatibility patches"

UPD_PL="/usr/share/koha/intranet/cgi-bin/installer/data/mysql/updatedatabase.pl"
DB_REVS="/usr/share/koha/intranet/cgi-bin/installer/data/mysql/db_revs"

# Back up original updatedatabase.pl.
# Finding 5 fix: only take the backup if one doesn't already exist. If the
# script is re-run after a Phase 6 failure, $UPD_PL may already be patched;
# unconditionally copying it over ${UPD_PL}.orig would destroy the last
# pristine copy, so a later restore would re-apply Patch 1 on top of itself.
if [ -f "${UPD_PL}.orig" ]; then
  echo "${UPD_PL}.orig already exists — leaving it as the pristine backup."
else
  cp "$UPD_PL" "${UPD_PL}.orig"
fi

# ── Patch 1: updatedatabase.pl ───────────────────────────────────────────────
# In MariaDB 10.6+, ALTER TABLE ... CONVERT TO CHARACTER SET raises error 1832
# even with foreign_key_checks=0 when FK constraints are on the columns being
# converted. The migration at version 17.12.00.016 attempts this bulk utf8mb4
# conversion. We patch it to:
#   a) Drop all FK constraints before conversion (so CONVERT works)
#   b) Shrink columns_settings primary key columns to VARCHAR(191) so the
#      composite PK (4 columns) fits within InnoDB's 3072-byte key limit
#      once stored as utf8mb4 (4 bytes/char vs 3 bytes/char for utf8mb3).

python3 <<'PYEOF'
import sys

UPD_PL = "/usr/share/koha/intranet/cgi-bin/installer/data/mysql/updatedatabase.pl"
MARKER = "MariaDB 11.x compatibility patch"

with open(UPD_PL, 'r') as f:
    lines = f.readlines()

# Finding 5 fix: skip re-insertion if this file was already patched (e.g. a
# re-run after a later phase failed, before Phase 6 restored the .orig). The
# original script had no such guard, so a second run would insert the whole
# FK-drop block a second time.
if any(MARKER in line for line in lines):
    print("updatedatabase.pl already carries the MariaDB 11.x patch — skipping.")
    sys.exit(0)

# Find the SET foreign_key_checks = 0 line inside migration 17.12.00.016
# (the one at ~line 19066 in 26.05.01 — search by content to be version-safe)
insert_after = None
in_target_migration = False
for i, line in enumerate(lines):
    if "$DBversion = '17.12.00.016'" in line:
        in_target_migration = True
    if in_target_migration and "SET foreign_key_checks = 0" in line:
        insert_after = i
        break

if insert_after is None:
    print("ERROR: Could not find target line in updatedatabase.pl")
    sys.exit(1)

print(f"Patching updatedatabase.pl at line {insert_after + 1}")

insertion = """
    # ── MariaDB 11.x compatibility patch ──────────────────────────────────────
    # MariaDB 10.6+ raises error 1832 (Cannot change column: used in FK) even
    # with foreign_key_checks=0 when CONVERT TO CHARACTER SET is used. Drop all
    # FK constraints first so the conversion succeeds, then subsequent upgrade
    # migrations recreate the ones they need.
    {
        my $fk_sth = $dbh->prepare(q|
            SELECT TABLE_NAME, CONSTRAINT_NAME
            FROM information_schema.TABLE_CONSTRAINTS
            WHERE CONSTRAINT_TYPE = 'FOREIGN KEY'
            AND CONSTRAINT_SCHEMA = DATABASE()
            ORDER BY TABLE_NAME
        |);
        $fk_sth->execute();
        while (my ($tbl, $fk) = $fk_sth->fetchrow_array()) {
            eval { $dbh->do(qq|ALTER TABLE `$tbl` DROP FOREIGN KEY `$fk`|) };
        }
    }
    # Fix columns_settings: its PRIMARY KEY on 4x VARCHAR(255) would be
    # 4x255x4 = 4080 bytes in utf8mb4, exceeding InnoDB's 3072-byte limit.
    if (column_exists('columns_settings', 'module')) {
        $dbh->do(q|ALTER TABLE columns_settings
            MODIFY module     VARCHAR(191) NOT NULL,
            MODIFY page       VARCHAR(191) NOT NULL,
            MODIFY tablename  VARCHAR(191) NOT NULL,
            MODIFY columnname VARCHAR(191) NOT NULL|);
    }
"""

lines.insert(insert_after + 1, insertion)

with open(UPD_PL, 'w') as f:
    f.writelines(lines)

print("updatedatabase.pl patched successfully.")
PYEOF

# ── Patch 2: db_revs/*.pl DROP FOREIGN KEY guards ────────────────────────────
# Because we dropped all FK constraints above, later db_revs migrations that
# try to DROP specific FK constraints (in order to recreate them differently)
# will fail with "Can't DROP FOREIGN KEY; check that it exists".
# Wrap those $dbh->do() calls in eval{} so a missing FK is silently ignored.
#
# Finding 4 fix: the original regexes required `do(q{`/`})` etc. to be
# immediately adjacent, so multi-line calls like
#   $dbh->do(
#       q{ ALTER TABLE ... DROP FOREIGN KEY afv_fk }
#   );
# were silently skipped. `\s*` now tolerates whitespace/newlines around the
# delimiters. The character classes stay brace/pipe-bounded ([^{}]*, [^|]*)
# rather than a bare `.*?`, which previously matched across an unrelated
# $dbh->do( ... an `if` block ... ) and corrupted a file — see README Finding 4.
#
# Finding 5 fix: each already-wrapped call is left alone on a re-run (the
# lookbehind/lookahead below skip anything already inside `eval { ... }`),
# so this step is now idempotent instead of double-wrapping.

python3 <<'PYEOF'
import os, re, glob, subprocess, sys

db_revs_dir = "/usr/share/koha/intranet/cgi-bin/installer/data/mysql/db_revs"
patched_files = []
failed_files = []

# Each DROP-FOREIGN-KEY do() call, already-adjacent or spread across lines,
# optionally preceded by "eval { " (in which case it's already guarded and
# must be left alone so reruns don't double-wrap it).
PATTERNS = [
    # q{...} / qq{...} — brace-bounded, cannot escape its own literal
    re.compile(r'(?<!eval \{ )(\$dbh->do\(\s*qq?\{[^{}]*DROP FOREIGN KEY[^{}]*\}\s*\))'),
    # "..."  — double-quoted, with backslash-escape support
    re.compile(r'(?<!eval \{ )(\$dbh->do\(\s*"(?:[^"\\]|\\.)*DROP FOREIGN KEY(?:[^"\\]|\\.)*"\s*\))'),
    # q|...| — pipe-bounded
    re.compile(r'(?<!eval \{ )(\$dbh->do\(\s*q\|[^|]*DROP FOREIGN KEY[^|]*\|\s*\))'),
]

for filepath in sorted(glob.glob(os.path.join(db_revs_dir, "*.pl"))):
    with open(filepath, "r") as f:
        content = f.read()

    if "DROP FOREIGN KEY" not in content:
        continue

    original = content
    for pattern in PATTERNS:
        content = pattern.sub(r'eval { \1 }', content)

    if content == original:
        continue

    with open(filepath, "w") as f:
        f.write(content)

    # Finding 4 fix: gate every edit on a syntax check. A bad regex match
    # (e.g. spanning an unrelated block) must be caught here, not hundreds
    # of migrations later.
    check = subprocess.run(
        ["perl", "-c", filepath],
        env={**os.environ, "PERL5LIB": "/usr/share/koha/lib"},
        capture_output=True, text=True,
    )
    if check.returncode != 0:
        with open(filepath, "w") as f:
            f.write(original)
        failed_files.append((os.path.basename(filepath), check.stderr.strip()))
        continue

    patched_files.append(os.path.basename(filepath))

print(f"Patched {len(patched_files)} db_revs file(s): {', '.join(patched_files)}")

if failed_files:
    print("ERROR: the following file(s) failed perl -c after patching and were reverted:")
    for name, err in failed_files:
        print(f"  {name}: {err}")
    sys.exit(1)
PYEOF

echo "Patches applied."

# =============================================================================
# PHASE 6 — Run database schema upgrade
# =============================================================================
step "PHASE 6: Running Koha schema upgrade (16.11 → 26.05)"
echo "This will take several minutes — upgrading through ~500 migrations..."

# Clean up any orphan user_permissions rows that reference non-existent
# permissions (these accumulate over years and block FK recreation in 21.12.x)
echo "Cleaning up orphan user_permissions rows..."
mysql koha_${INSTANCE} -e "
    DELETE up FROM user_permissions up
    LEFT JOIN permissions p ON up.module_bit = p.module_bit AND up.code = p.code
    WHERE p.module_bit IS NULL;
" && echo "Orphan rows removed."

# Run the upgrade
koha-upgrade-schema "$INSTANCE"

# Verify upgrade completed
DB_VERSION=$(mysql koha_${INSTANCE} -Ne \
  "SELECT value FROM systempreferences WHERE variable='Version';" \
  2>/dev/null | tr -d '|' | xargs)
echo ""
echo "Database version after upgrade: $DB_VERSION"
[[ "$DB_VERSION" == 26* ]] || die "Upgrade did not reach Koha 26. Check the log."

# Restore original updatedatabase.pl (patches no longer needed post-upgrade)
cp "${UPD_PL}.orig" "$UPD_PL"
rm -f "${UPD_PL}.orig"
echo "updatedatabase.pl restored to original."

# =============================================================================
# PHASE 7 — Configure Apache vhost properly for Plack + static files
# =============================================================================
step "PHASE 7: Configuring Apache vhost"

# Koha 26 with Plack needs DocumentRoot + the version-stripping RewriteRule
# added explicitly to the vhost (they exist in apache-shared-intranet.conf
# but that file is NOT included when using the Plack variant).
cat >/etc/apache2/sites-available/${INSTANCE}.conf <<APACHECONF
# Koha instance ${INSTANCE} Apache config.

# OPAC
<VirtualHost *:${OPACPORT}>
  <IfVersion >= 2.4>
   Define instance "${INSTANCE}"
  </IfVersion>
   Include /etc/koha/apache-shared.conf
   Include /etc/koha/apache-shared-opac-plack.conf

   DocumentRoot /usr/share/koha/opac/htdocs
   <Directory /usr/share/koha/opac/htdocs>
      Options +FollowSymLinks
      AllowOverride None
      Require all granted
   </Directory>

   # Strip Koha version from cache-busted filenames (e.g. opac.css_26.0501000 -> opac.css)
   RewriteRule ^(.*)_[0-9]{2}\.[0-9]{7}\.(js|css)$ \$1.\$2 [L]

   ServerName ${INSTANCE}${DOMAIN}
   SetEnv KOHA_CONF "/etc/koha/sites/${INSTANCE}/koha-conf.xml"
   AssignUserID ${INSTANCE}-koha ${INSTANCE}-koha

   ErrorLog    /var/log/koha/${INSTANCE}/opac-error.log
   TransferLog /var/log/koha/${INSTANCE}/opac-access.log
</VirtualHost>

# Intranet (Staff)
<VirtualHost *:${INTRAPORT}>
  <IfVersion >= 2.4>
   Define instance "${INSTANCE}"
  </IfVersion>
   Include /etc/koha/apache-shared.conf
   Include /etc/koha/apache-shared-intranet-plack.conf

   DocumentRoot /usr/share/koha/intranet/htdocs
   <Directory /usr/share/koha/intranet/htdocs>
      Options +FollowSymLinks
      AllowOverride None
      Require all granted
   </Directory>

   # Strip Koha version from cache-busted filenames
   RewriteRule ^(.*)_[0-9]{2}\.[0-9]{7}\.(js|css)$ \$1.\$2 [L]

   ServerName ${INSTANCE}${INTRASUFFIX}${DOMAIN}
   SetEnv KOHA_CONF "/etc/koha/sites/${INSTANCE}/koha-conf.xml"
   AssignUserID ${INSTANCE}-koha ${INSTANCE}-koha

   ErrorLog    /var/log/koha/${INSTANCE}/intranet-error.log
   TransferLog /var/log/koha/${INSTANCE}/intranet-access.log
</VirtualHost>
APACHECONF

a2ensite "$INSTANCE"
apache2ctl configtest
systemctl reload apache2
echo "Apache vhost configured."

# =============================================================================
# PHASE 8 — Enable locale and fix log file ownership
# =============================================================================
step "PHASE 8: Post-install configuration"

# Koha 26 requires en_US.UTF-8 locale.
# Finding 6 fix: Debian's locale-gen ignores command-line arguments entirely
# and only regenerates locales that are uncommented in /etc/locale.gen, so
# `locale-gen en_US.UTF-8` was a silent no-op whenever that line was still
# commented out — the script would report success with en_US never actually
# generated. Uncomment the line first, then verify the result explicitly.
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
dpkg-reconfigure --frontend=noninteractive locales
locale -a | grep -q '^en_US.utf8$' ||
  die "en_US.utf8 locale was not generated. Check /etc/locale.gen and re-run 'locale-gen'."
echo "Locale en_US.utf8 confirmed present."

# Fix log file ownership — Apache/Plack startup creates some log files as root,
# but Plack runs as the koha user and can't write to them
chown -R ${INSTANCE}-koha:${INSTANCE}-koha /var/log/koha/${INSTANCE}/

# =============================================================================
# PHASE 9 — Start / restart all services
# =============================================================================
step "PHASE 9: Starting Koha services"

koha-enable "$INSTANCE"
systemctl restart apache2
koha-plack --restart "$INSTANCE"
koha-zebra --restart "$INSTANCE"
koha-worker --restart "$INSTANCE"

sleep 4 # Let Plack fully start before testing

# Verify Plack is accepting connections
PLACK_TEST=$(curl -sm 15 -o /dev/null -w "%{http_code}" http://localhost:${INTRAPORT}/ 2>/dev/null)
if [ "$PLACK_TEST" = "200" ]; then
  echo "Staff interface: HTTP $PLACK_TEST ✓"
else
  echo "WARNING: Staff interface returned HTTP $PLACK_TEST — check Plack logs"
fi

OPAC_TEST=$(curl -sm 15 -o /dev/null -w "%{http_code}" http://localhost:${OPACPORT}/ 2>/dev/null)
echo "OPAC interface:  HTTP $OPAC_TEST"

# =============================================================================
# PHASE 10 — Rebuild Zebra search indexes
# =============================================================================
step "PHASE 10: Rebuilding Zebra search indexes"
koha-rebuild-zebra -v -f "$INSTANCE" 2>&1 | tail -5
echo "Zebra reindex complete."

# =============================================================================
# PHASE 11 — Reset staff account passwords
# =============================================================================
step "PHASE 11: Resetting staff account passwords"

# Passwords in the Koha 16.11 dump may not match what staff currently use
# on the old server (passwords could have changed after the dump was taken).
# Set a known temporary password for all accounts with elevated permissions.

KOHA_CONF=/etc/koha/sites/${INSTANCE}/koha-conf.xml \
  PERL5LIB=/usr/share/koha/lib \
  perl <<PERLEOF
use Koha::Patrons;
use C4::Auth qw(checkpw_hash);

my \$new_pass = "${ADMIN_TEMP_PASS}";
my \$patrons = Koha::Patrons->search({ flags => { '>' => 0 } });

while (my \$patron = \$patrons->next) {
    \$patron->set_password({ password => \$new_pass, skip_validation => 1 });
    printf "  Reset: %-20s (borrowernumber: %d)\\n",
        \$patron->userid, \$patron->borrowernumber;
}

# Reset failed login counters
Koha::Patrons->search({ flags => { '>' => 0 } })
    ->update({ login_attempts => 0 });

print "\\nAll staff passwords set to: ${ADMIN_TEMP_PASS}\\n";
PERLEOF

# Flush memcached to clear any cached session state
echo "flush_all" | nc -w1 127.0.0.1 11211 2>/dev/null && echo "Memcached flushed." || true

# Final Plack restart to pick up locale + clean state
koha-plack --restart "$INSTANCE"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
step "Migration Complete"

DB_VERSION=$(mysql koha_${INSTANCE} -Ne \
  "SELECT value FROM systempreferences WHERE variable='Version';" \
  2>/dev/null | tr -d '|' | xargs)

BIBLIO_COUNT=$(mysql koha_${INSTANCE} -Ne "SELECT COUNT(*) FROM biblio;" 2>/dev/null | xargs)
ITEM_COUNT=$(mysql koha_${INSTANCE} -Ne "SELECT COUNT(*) FROM items;" 2>/dev/null | xargs)
PATRON_COUNT=$(mysql koha_${INSTANCE} -Ne "SELECT COUNT(*) FROM borrowers;" 2>/dev/null | xargs)

echo ""
echo "  Koha version    : $DB_VERSION"
echo "  Biblios         : $BIBLIO_COUNT"
echo "  Items           : $ITEM_COUNT"
echo "  Patrons         : $PATRON_COUNT"
echo ""
echo "  Staff URL : http://$(hostname -I | awk '{print $1}'):${INTRAPORT}/"
echo "  OPAC URL  : http://$(hostname -I | awk '{print $1}'):${OPACPORT}/"
echo ""
echo "  ┌─────────────────────────────────────────────────┐"
echo "  │  Temporary login credentials for all staff:     │"
echo "  │                                                  │"
echo "  │  Username: (their existing userid)               │"
echo "  │  Password: ${ADMIN_TEMP_PASS}              │"
echo "  └─────────────────────────────────────────────────┘"
echo ""

echo "  Staff accounts:"
mysql koha_${INSTANCE} -e \
  "SELECT userid, CONCAT(firstname,' ',surname) AS name, flags
     FROM borrowers WHERE flags > 0
     ORDER BY flags DESC LIMIT 10;" 2>/dev/null

echo ""
echo "  Next steps:"
echo "    1. Log in and verify data looks correct"
echo "    2. Each user should change their own password"
echo "    3. Update DNS to point ${INSTANCE}${DOMAIN} and"
echo "       ${INSTANCE}${INTRASUFFIX}${DOMAIN} to this server's IP"
echo "    4. Decommission the old server once satisfied"
echo ""
echo "  Full log saved to: $LOGFILE"
