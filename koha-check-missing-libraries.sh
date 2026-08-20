#!/bin/bash
# koha-check-missing-libraries.sh
#
# Monitors a Koha instance for items that have no resolvable home/holding
# library (the condition that previously caused 500 errors on
# catalogue/detail.pl?...&audit=1: "Item with itemnumber=X does not have
# home and holding library defined"). Intended to run periodically via cron.
#
# Usage: koha-check-missing-libraries.sh <instance_name>

INSTANCE="${1:-atslibrary}"
LOGFILE="/var/log/koha/${INSTANCE}/library-audit.log"

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null

BROKEN_ITEMS=$(koha-mysql "$INSTANCE" -N -e "
SELECT COUNT(*)
FROM items
WHERE (homebranch IS NULL OR homebranch = '')
   OR (holdingbranch IS NULL OR holdingbranch = '');
")

TIMESTAMP=$(date -Iseconds)

if [ "$BROKEN_ITEMS" -gt 0 ]; then
    echo "${TIMESTAMP} ALERT: ${BROKEN_ITEMS} item(s) with no home/holding library found in ${INSTANCE}" | tee -a "$LOGFILE"
    exit 1
else
    echo "${TIMESTAMP} OK: no items with missing home/holding library in ${INSTANCE}" >> "$LOGFILE"
    exit 0
fi
