#!/bin/bash
# koha-check-missing-itemtypes.sh
#
# Monitors a Koha instance for items/biblioitems that have no resolvable
# item type (the condition that previously caused 500 errors in
# Koha::Item::_status()). Intended to run periodically via cron.
#
# Usage: koha-check-missing-itemtypes.sh <instance_name>

INSTANCE="${1:-atslibrary}"
LOGFILE="/var/log/koha/${INSTANCE}/itemtype-audit.log"

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null

BROKEN_ITEMS=$(koha-mysql "$INSTANCE" -N -e "
SELECT COUNT(*)
FROM items i
JOIN biblioitems bi ON bi.biblionumber = i.biblionumber
WHERE (i.itype IS NULL OR i.itype = '')
  AND (bi.itemtype IS NULL OR bi.itemtype = '');
")

TIMESTAMP=$(date -Iseconds)

if [ "$BROKEN_ITEMS" -gt 0 ]; then
    echo "${TIMESTAMP} ALERT: ${BROKEN_ITEMS} item(s) with no resolvable item type found in ${INSTANCE}" | tee -a "$LOGFILE"
    exit 1
else
    echo "${TIMESTAMP} OK: no items with missing item type in ${INSTANCE}" >> "$LOGFILE"
    exit 0
fi
