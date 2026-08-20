-- ============================================================================
-- apply_library_fix_20260820.sql
--
-- Full data-fix migration for items missing home/holding library (see
-- identify_missing_libraries.sql for the diagnostic queries this addresses).
--
-- Phase 1: backfill items.homebranch / items.holdingbranch for records with
--          neither defined.
-- Phase 2: give the columns a schema-level default so any future insert
--          (manual, bulk import, or API) that omits these fields is
--          auto-populated instead of silently defaulting to NULL.
-- Phase 3: make 952$a / 952$b mandatory with a pre-filled default in every
--          framework (Default, CAT, KIN), so the cataloguing GUI blocks
--          saving an item with no branch going forward (mirrors the 942$c
--          fix applied for the item-type finding).
--
-- This instance has exactly one library (ATSMAIN). If a second branch is
-- ever added, DO NOT replay this script as-is -- the ATSMAIN default below
-- would silently misassign new items to the wrong branch.
--
-- Already run successfully against atslibrary on 2026-08-17/20. Kept as the
-- authoritative, re-runnable record of the fix (e.g. to replay against
-- another single-branch instance in the same state, such as production
-- during cutover).
-- Run with: sudo koha-mysql <instance> < apply_library_fix_20260820.sql
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Phase 1: backfill missing home/holding library
-- ---------------------------------------------------------------------------
START TRANSACTION;

UPDATE items
SET homebranch = 'ATSMAIN'
WHERE homebranch IS NULL OR homebranch = '';

UPDATE items
SET holdingbranch = 'ATSMAIN'
WHERE holdingbranch IS NULL OR holdingbranch = '';

COMMIT;

-- ---------------------------------------------------------------------------
-- Phase 2: schema-level default (prevent recurrence regardless of insert path)
-- ---------------------------------------------------------------------------
ALTER TABLE items
    MODIFY homebranch varchar(10) DEFAULT 'ATSMAIN',
    MODIFY holdingbranch varchar(10) DEFAULT 'ATSMAIN';

-- ---------------------------------------------------------------------------
-- Phase 3: enforce branch entry in the cataloguing GUI (all frameworks)
-- ---------------------------------------------------------------------------
START TRANSACTION;

UPDATE marc_subfield_structure
SET mandatory = 1, defaultvalue = 'ATSMAIN'
WHERE kohafield IN ('items.homebranch', 'items.holdingbranch')
  AND frameworkcode IN ('', 'CAT', 'KIN');

COMMIT;

-- NOTE: after running Phase 3 against a live instance, restart Plack (or
-- flush Koha's cache) so the framework structure change takes effect:
--   sudo koha-plack --restart <instance>
-- or:
--   sudo koha-shell <instance> -c "perl -e 'use Koha::Caches; Koha::Caches->get_instance->flush_all;'"
