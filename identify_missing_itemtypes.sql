-- identify_missing_itemtypes.sql
--
-- Read-only diagnostic script for Koha. Identifies items and biblioitems
-- that have no resolvable item type, i.e. records that will trigger:
--   "Item with itemnumber=X does not have an itype value, additionally
--    no item type defined for biblionumber=Y"
-- and the downstream 500 error in Koha::Item::_status()
-- (item_type->notforloan called on undef).
--
-- Run with:
--   sudo koha-mysql <instance> < identify_missing_itemtypes.sql
--
-- Nothing in this script modifies data.

-- 1. Summary counts
SELECT 'items with NULL/empty itype' AS metric, COUNT(*) AS total
FROM items
WHERE itype IS NULL OR itype = ''
UNION ALL
SELECT 'biblioitems with NULL/empty itemtype', COUNT(*)
FROM biblioitems
WHERE itemtype IS NULL OR itemtype = ''
UNION ALL
SELECT 'items with NO resolvable itemtype (item + biblio fallback both empty)', COUNT(*)
FROM items i
JOIN biblioitems bi ON bi.biblionumber = i.biblionumber
WHERE (i.itype IS NULL OR i.itype = '')
  AND (bi.itemtype IS NULL OR bi.itemtype = '')
UNION ALL
SELECT 'distinct biblios affected (no resolvable itemtype for at least one item)', COUNT(DISTINCT i.biblionumber)
FROM items i
JOIN biblioitems bi ON bi.biblionumber = i.biblionumber
WHERE (i.itype IS NULL OR i.itype = '')
  AND (bi.itemtype IS NULL OR bi.itemtype = '');

-- 2. Full list of items with no resolvable item type
-- (item-level itype missing AND biblio-level fallback missing)
-- This is the authoritative "broken" list to drive the migration.
SELECT
    i.itemnumber,
    i.biblionumber,
    i.biblioitemnumber,
    i.barcode,
    i.homebranch,
    i.holdingbranch,
    i.dateaccessioned,
    i.itype            AS item_itype,
    bi.itemtype         AS biblio_itemtype,
    b.title
FROM items i
JOIN biblioitems bi ON bi.biblionumber = i.biblionumber
JOIN biblio b        ON b.biblionumber = i.biblionumber
WHERE (i.itype IS NULL OR i.itype = '')
  AND (bi.itemtype IS NULL OR bi.itemtype = '')
ORDER BY i.biblionumber, i.itemnumber;

-- 3. Biblioitems with no itemtype, regardless of item-level status
-- (relevant for item-level_itypes=0 installs, and as a fallback source)
SELECT
    bi.biblioitemnumber,
    bi.biblionumber,
    b.title,
    bi.itemtype
FROM biblioitems bi
JOIN biblio b ON b.biblionumber = bi.biblionumber
WHERE bi.itemtype IS NULL OR bi.itemtype = ''
ORDER BY bi.biblionumber;

-- 4. Candidate records that may need a NON-default item type
-- Titles that look like they represent a distinct format (e.g. e-readers)
-- rather than a standard book. Review this list manually before applying
-- the bulk default in the migration step.
SELECT
    i.itemnumber,
    i.biblionumber,
    b.title,
    i.itype AS item_itype,
    bi.itemtype AS biblio_itemtype
FROM items i
JOIN biblioitems bi ON bi.biblionumber = i.biblionumber
JOIN biblio b        ON b.biblionumber = i.biblionumber
WHERE (i.itype IS NULL OR i.itype = '')
  AND (bi.itemtype IS NULL OR bi.itemtype = '')
  AND (
        b.title = 'Kindle'
     OR b.title LIKE '% Kindle'
     OR b.title LIKE 'Kindle %'
  )
ORDER BY i.biblionumber;

-- 5. Sanity check: valid item types currently defined in this system
SELECT itemtype, description, notforloan FROM itemtypes ORDER BY itemtype;

-- 6. Frameworks missing a 942$c -> biblioitems.itemtype mapping
-- (a framework with no mapping means catalogers using it can never set
-- the biblio-level item type through the MARC editor)
SELECT DISTINCT b.frameworkcode
FROM biblio b
LEFT JOIN marc_subfield_structure mss
       ON mss.frameworkcode = b.frameworkcode
      AND mss.kohafield = 'biblioitems.itemtype'
WHERE mss.tagfield IS NULL;
