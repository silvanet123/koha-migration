-- ============================================================================
-- apply_itemtype_fix_20260816.sql
--
-- Full data-fix migration for missing Koha item types (see
-- identify_missing_itemtypes.sql for the diagnostic queries this addresses).
--
-- Phase 2: backfill items.itype / biblioitems.itemtype for records with no
--          resolvable item type.
-- Phase 5: add the missing 942 tag/subfield mapping (biblioitems.itemtype)
--          to the CAT and KIN frameworks so catalogers can set item type via
--          the MARC editor going forward, and so the item-level itype field
--          renders/behaves correctly on the item edit screen for those
--          frameworks (this is the fix that closes the gap that allowed the
--          data to go missing for records catalogued under CAT/KIN).
--
-- Both phases already ran successfully against atslibrary on 2026-08-16.
-- This file is kept as the authoritative, re-runnable record of the full
-- migration (e.g. to replay against another instance in the same state).
-- Run with: sudo koha-mysql <instance> < apply_itemtype_fix_20260816.sql
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Phase 2: backfill item types
-- ---------------------------------------------------------------------------
START TRANSACTION;

-- Kindle devices first (narrow, explicit set)
UPDATE biblioitems bi
JOIN biblio b ON b.biblionumber = bi.biblionumber
SET bi.itemtype = 'KINDLE'
WHERE (bi.itemtype IS NULL OR bi.itemtype = '')
  AND b.biblionumber IN (53282, 53283, 53284, 54083);

UPDATE items i
JOIN biblio b ON b.biblionumber = i.biblionumber
SET i.itype = 'KINDLE'
WHERE (i.itype IS NULL OR i.itype = '')
  AND b.biblionumber IN (53282, 53283, 53284, 54083);

-- Everything else defaults to BOOK
UPDATE biblioitems
SET itemtype = 'BOOK'
WHERE itemtype IS NULL OR itemtype = '';

UPDATE items
SET itype = 'BOOK'
WHERE itype IS NULL OR itype = '';

COMMIT;

-- ---------------------------------------------------------------------------
-- Phase 5: fix the CAT / KIN framework MARC mapping gap (prevent recurrence)
--
-- The CAT and KIN frameworks had no 942 tag/subfield structure at all, so
-- they had no biblioitems.itemtype mapping (942$c) unlike the Default
-- framework. This copies the full 942 block (tag + all subfields, including
-- $c -> biblioitems.itemtype, mandatory=1) from Default into CAT and KIN.
-- Guarded with NOT EXISTS so it is safe to re-run.
-- ---------------------------------------------------------------------------
START TRANSACTION;

-- Copy the 942 tag structure entry into CAT and KIN frameworks
INSERT INTO marc_tag_structure (tagfield, liblibrarian, libopac, repeatable, mandatory, important, ind1_defaultvalue, ind2_defaultvalue, authorised_value, frameworkcode)
SELECT tagfield, liblibrarian, libopac, repeatable, mandatory, important, ind1_defaultvalue, ind2_defaultvalue, authorised_value, 'CAT'
FROM marc_tag_structure
WHERE frameworkcode = '' AND tagfield = '942'
  AND NOT EXISTS (SELECT 1 FROM marc_tag_structure WHERE frameworkcode = 'CAT' AND tagfield = '942');

INSERT INTO marc_tag_structure (tagfield, liblibrarian, libopac, repeatable, mandatory, important, ind1_defaultvalue, ind2_defaultvalue, authorised_value, frameworkcode)
SELECT tagfield, liblibrarian, libopac, repeatable, mandatory, important, ind1_defaultvalue, ind2_defaultvalue, authorised_value, 'KIN'
FROM marc_tag_structure
WHERE frameworkcode = '' AND tagfield = '942'
  AND NOT EXISTS (SELECT 1 FROM marc_tag_structure WHERE frameworkcode = 'KIN' AND tagfield = '942');

-- Copy all 942 subfields (including $c -> biblioitems.itemtype) into CAT and KIN
INSERT INTO marc_subfield_structure
    (tagfield, tagsubfield, liblibrarian, libopac, repeatable, mandatory, important, kohafield, tab,
     authorised_value, authtypecode, value_builder, isurl, hidden, frameworkcode, seealso, link,
     defaultvalue, maxlength, display_order)
SELECT
     tagfield, tagsubfield, liblibrarian, libopac, repeatable, mandatory, important, kohafield, tab,
     authorised_value, authtypecode, value_builder, isurl, hidden, 'CAT', seealso, link,
     defaultvalue, maxlength, display_order
FROM marc_subfield_structure
WHERE frameworkcode = '' AND tagfield = '942'
  AND NOT EXISTS (
      SELECT 1 FROM marc_subfield_structure mss2
      WHERE mss2.frameworkcode = 'CAT' AND mss2.tagfield = '942' AND mss2.tagsubfield = marc_subfield_structure.tagsubfield
  );

INSERT INTO marc_subfield_structure
    (tagfield, tagsubfield, liblibrarian, libopac, repeatable, mandatory, important, kohafield, tab,
     authorised_value, authtypecode, value_builder, isurl, hidden, frameworkcode, seealso, link,
     defaultvalue, maxlength, display_order)
SELECT
     tagfield, tagsubfield, liblibrarian, libopac, repeatable, mandatory, important, kohafield, tab,
     authorised_value, authtypecode, value_builder, isurl, hidden, 'KIN', seealso, link,
     defaultvalue, maxlength, display_order
FROM marc_subfield_structure
WHERE frameworkcode = '' AND tagfield = '942'
  AND NOT EXISTS (
      SELECT 1 FROM marc_subfield_structure mss2
      WHERE mss2.frameworkcode = 'KIN' AND mss2.tagfield = '942' AND mss2.tagsubfield = marc_subfield_structure.tagsubfield
  );

COMMIT;

-- NOTE: after running Phase 5 against a live instance, flush Koha's cache so
-- the framework structure change takes effect without a service restart:
--   sudo koha-shell <instance> -c "perl -e 'use Koha::Caches; Koha::Caches->get_instance->flush_all;'"
