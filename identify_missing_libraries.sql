-- ============================================================================
-- identify_missing_libraries.sql
--
-- Read-only diagnostics for items with no homebranch/holdingbranch, i.e.
-- records that trigger:
--   "Item with itemnumber=X does not have home and holding library defined"
-- on catalogue/detail.pl?...&audit=1 and related staff/API pages.
--
-- Nothing in this script modifies data.
-- Run with: sudo koha-mysql <instance> < identify_missing_libraries.sql
-- ============================================================================

-- 1. Summary counts
SELECT
    (SELECT COUNT(*) FROM items WHERE homebranch IS NULL OR homebranch = '')       AS items_null_homebranch,
    (SELECT COUNT(*) FROM items WHERE holdingbranch IS NULL OR holdingbranch = '') AS items_null_holdingbranch,
    (SELECT COUNT(*) FROM items WHERE (homebranch IS NULL OR homebranch = '')
                                    OR (holdingbranch IS NULL OR holdingbranch = '')) AS items_missing_either;

-- 2. Full list of affected items
SELECT i.itemnumber, i.biblionumber, i.homebranch, i.holdingbranch,
       i.barcode, i.itype, i.dateaccessioned
FROM items i
WHERE (i.homebranch IS NULL OR i.homebranch = '')
   OR (i.holdingbranch IS NULL OR i.holdingbranch = '')
ORDER BY i.dateaccessioned, i.itemnumber;

-- 3. Distribution by accession year (helps identify which import batch(es) are the source)
SELECT YEAR(dateaccessioned) AS accession_year, COUNT(*) AS affected_items
FROM items
WHERE (homebranch IS NULL OR homebranch = '')
   OR (holdingbranch IS NULL OR holdingbranch = '')
GROUP BY accession_year
ORDER BY accession_year;

-- 4. Valid branches defined in this instance (the only acceptable values to backfill with)
SELECT branchcode, branchname FROM branches;

-- 5. Any circulation activity (issues/reserves) on affected items -- check before any bulk fix
SELECT 'issues' AS source, itemnumber FROM issues
WHERE itemnumber IN (SELECT itemnumber FROM items WHERE homebranch IS NULL OR holdingbranch IS NULL)
UNION ALL
SELECT 'reserves' AS source, itemnumber FROM reserves
WHERE itemnumber IN (SELECT itemnumber FROM items WHERE homebranch IS NULL OR holdingbranch IS NULL);

-- 6. Frameworks where 952$a (homebranch) / 952$b (holdingbranch) are not mandatory
--    and have no defaultvalue -- the gap that lets this recur via manual cataloguing
SELECT frameworkcode, tagfield, tagsubfield, kohafield, mandatory, defaultvalue
FROM marc_subfield_structure
WHERE kohafield IN ('items.homebranch', 'items.holdingbranch')
ORDER BY kohafield, frameworkcode;

-- 7. Import batch(es) responsible, where determinable (branchcode override left NULL
--    on a batch strongly correlates with items lacking 952$a/$b ending up with no branch)
SELECT import_batch_id, batch_type, branchcode, overlay_action, import_status,
       file_name, upload_timestamp
FROM import_batches
ORDER BY upload_timestamp;
