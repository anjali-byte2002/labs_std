-- ============================================================================
-- Labs normal_flag standardization -- rgd_gold_ad.labs
-- Computes normal_flag_std from result_value vs. result_range per business
-- rules (numeric range comparison / qualitative passthrough / invalid
-- detection). Read-only SELECT -- no ALTER TABLE / write access required.
--
-- RULES IMPLEMENTED
--   Numeric result_value vs. a parsed numeric result_range:
--     within range        -> 'NORMAL'
--     above the range      -> 'HIGH'
--     below the range      -> 'LOW'
--   Qualitative/text result_value (e.g. 'TURBID', 'Negative', bacteria
--   names): normal_flag_std = the raw result_range value, passed through
--   for secondary-stage standardization (per spec -- not resolved here).
--   Noise in result_value (e.g. '# 1', '# 4', '(NOTE)', and similar
--   note-referral / insurance-merge-field artifacts found in the live
--   data) -> 'INVALID_RESULT_VALUE'.
--   result_range NULL, blank, or unparseable -> 'INVALID_RESULT_RANGE'.
--
-- RANGE FORMATS HANDLED (result_range has ~5,158 distinct raw strings;
-- these cover the large majority by volume):
--   plain dash range      '32.0-36.0', '-9.9-3.3', '0-2/hpf' (unit suffix
--                          ignored), '(6.2-8.2)' (wrapping parens stripped)
--   TO-separated           '-9.9 TO +3.3'
--   space-signed pair      '-3 +3'
--   single bound            '>=60', '<=1.0', '>59', '<200'
--   textual "OR ="          '> OR = 60', '< OR = 0.15'
--   combined double bound   '>2-<10' (strict on both sides)
--   bare point reference    '0', '500 ng/mL' (leading number = the
--                            reference point; only reachable when
--                            result_value is itself non-numeric, e.g. a
--                            qualitative drug-screen cutoff -- see below)
--   qualitative text         'NEGATIVE', 'Clear', 'NON-REACTIVE', etc.
--                            (used as the Q4 passthrough source)
--
-- A negative low bound followed directly by a second number with NO
-- explicit sign (e.g. '-9.9-3.3') is interpreted as the mandatory range
-- separator, not a second negative sign -- so this parses as -9.9 to
-- +3.3, matching the equivalent 'TO'-worded form of the same range seen
-- elsewhere in the data ('-9.9 TO +3.3'). An explicit '+'/'-' on the
-- second number (from spaced or TO-worded forms) is always honored.
--
-- result_value HANDLING: values wrapped in an XML envelope
-- ("<?xml ...?> <root>1.0</root>") are unwrapped before classification.
--
-- ENGINE QUIRK WORKED AROUND: CAST(REGEXP_SUBSTR(...) AS DECIMAL(n,m))
-- truncates to the integer part on this DB (confirmed: '-9.9' -> -9.0000)
-- -- CAST(... AS DOUBLE) does not have this bug, so DOUBLE is used
-- throughout for all extracted numeric values.
--
-- KNOWN LIMITATIONS (fall to INVALID_RESULT_RANGE / INVALID_RESULT_VALUE
-- rather than being silently guessed at):
--   - Titer/ratio ranges ('<1:240', '<1:20')
--   - Prose cutoffs ('Cutoff 300 ng/mL')
--   - Hybrid qualitative+numeric ranges ('Negative:0-30', 'None Seen, 0-2')
--   - A result_value that is itself a range rather than a single value
--     ('0-2', '3-5' as the *value*, e.g. urinalysis microscopy counts)
--   - Long free-text lab disclaimers in result_value (fall through to the
--     qualitative passthrough branch, which is harmless since their
--     result_range is typically blank anyway)
--
-- VERIFIED 2026-08-20 against the live table (3,514,614 rows):
--   NORMAL                2,159,690  (61.4%)
--   INVALID_RESULT_RANGE    423,161  (12.0%)
--   HIGH                    265,519   (7.6%)
--   INVALID_RESULT_VALUE    258,104   (7.3%)
--   LOW                     236,830   (6.7%)
--   qualitative passthrough (~171k rows spread across ~hundreds of
--     distinct result_range text values -- 'NEGATIVE', 'Clear',
--     'NON-REACTIVE', etc.)
-- ============================================================================

-- ============================================================================
-- Labs normal_flag standardization -- rgd_gold_ad.labs -- v2
-- Adds: ratio/titer parsing, qualitative Positive/Negative match-vs-range
-- comparison (replacing straight passthrough), microscopy quantity-word
-- HIGH override, and a range-canonicalization bug fix ("< = N" spacing).
-- Read-only SELECT -- no ALTER TABLE / write access required.
-- ============================================================================

WITH value_norm AS (
    SELECT
        l.*,
        CASE
            WHEN result_value REGEXP '<root>.*</root>'
                THEN REGEXP_REPLACE(result_value, '^.*<root>(.*)</root>.*$', '$1')
            ELSE result_value
        END AS rv_unwrapped
    FROM rgd_gold_ad.labs l
),

range_norm AS (
    SELECT
        *,
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(
                            UPPER(TRIM(REGEXP_REPLACE(result_range, '^\\((.*)\\)$', '$1'))),
                            '>\\s*OR\\s*=', '>='),
                        '<\\s*OR\\s*=', '<='),
                    '\\bTO\\b', '-'),
                '^(-[0-9]+\\.?[0-9]*)\\s+(\\+[0-9]+\\.?[0-9]*)$', '$1-$2'
            ),
            '([<>])\\s*=', '$1='          -- NEW: "< = 11" -> "<=11" (space between operator and '=')
        ) AS rr_canon0
    FROM value_norm
),

range_ratio_norm AS (
    SELECT
        *,
        CASE
            WHEN rr_canon0 REGEXP '[0-9]+\\s*:\\s*[0-9]+' THEN
                REGEXP_REPLACE(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(rr_canon0, '^(NEG\\w*|NON\\s*-?\\s*REA\\w*)\\s*:?\\s*\\(?\\s*', ''),
                        '\\)\\s*$', ''
                    ),
                    '[0-9]+\\s*:\\s*([0-9]+)', '$1'
                )
            ELSE rr_canon0
        END AS rr_canon
    FROM range_norm
),

shape_classified AS (
    SELECT
        *,
        TRIM(rv_unwrapped) AS rv,
        -- NEW: value-side ratio/titer + Negative-prefix normalization,
        -- folded into a form the existing numeric/qualitative machinery
        -- already understands (bare denominator, or literal 'NEGATIVE').
        CASE
            WHEN UPPER(TRIM(rv_unwrapped)) REGEXP '^(NEG\\w*|NON\\s*-?\\s*REA\\w*)' THEN 'NEGATIVE'
            WHEN TRIM(rv_unwrapped) REGEXP '[0-9]+\\s*:\\s*[0-9]+'
                THEN REGEXP_REPLACE(TRIM(rv_unwrapped), '^.*?[0-9]+\\s*:\\s*([0-9]+).*$', '$1')
            ELSE TRIM(rv_unwrapped)
        END AS rv2,
        CASE
            WHEN rr_canon IS NULL OR TRIM(rr_canon) = '' THEN 'blank'
            WHEN rr_canon REGEXP '^[<>]=?\\s*-?[0-9]+\\.?[0-9]*\\s*-\\s*[<>]=?\\s*-?[0-9]+\\.?[0-9]*'
                THEN 'combined'
            WHEN rr_canon REGEXP '^[<>]=?\\s*-?[0-9]+\\.?[0-9]*'
                THEN 'single_bound'
            WHEN rr_canon REGEXP '^-?[0-9]+\\.?[0-9]*\\s*-\\s*[+-]?[0-9]+\\.?[0-9]*'
                THEN 'plain_range'
            WHEN rr_canon REGEXP '^[0-9]+\\.?[0-9]*'
                THEN 'point'
            WHEN rr_canon NOT REGEXP '[0-9]'
                THEN 'qualitative'
            ELSE 'unparseable'
        END AS range_shape
    FROM range_ratio_norm
),

bounds_extracted AS (
    SELECT
        *,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_SUBSTR(rr_canon, '^[<>]=?') IN ('>', '>=')
                     THEN CAST(REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '^[<>]=?\\s*-?[0-9]+\\.?[0-9]*'), '-?[0-9]+\\.?[0-9]*$') AS DOUBLE)
                     ELSE NULL END
            WHEN 'plain_range' THEN
                CAST(REGEXP_SUBSTR(rr_canon, '^-?[0-9]+\\.?[0-9]*') AS DOUBLE)
            WHEN 'point' THEN
                CAST(REGEXP_SUBSTR(rr_canon, '^[0-9]+\\.?[0-9]*') AS DOUBLE)
            WHEN 'combined' THEN
                CAST(REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '^[<>]=?\\s*-?[0-9]+\\.?[0-9]*'), '-?[0-9]+\\.?[0-9]*$') AS DOUBLE)
            ELSE NULL
        END AS low_val,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_SUBSTR(rr_canon, '^[<>]=?') IN ('>', '>=')
                     THEN REGEXP_SUBSTR(rr_canon, '^[<>]=?')
                     ELSE NULL END
            WHEN 'plain_range' THEN '>='
            WHEN 'point' THEN '>='
            WHEN 'combined' THEN REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '^[<>]=?\\s*-?[0-9]+\\.?[0-9]*'), '^[<>]=?')
            ELSE NULL
        END AS low_op,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_SUBSTR(rr_canon, '^[<>]=?') IN ('<', '<=')
                     THEN CAST(REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '^[<>]=?\\s*-?[0-9]+\\.?[0-9]*'), '-?[0-9]+\\.?[0-9]*$') AS DOUBLE)
                     ELSE NULL END
            WHEN 'plain_range' THEN
                CAST(
                    REGEXP_REPLACE(
                        SUBSTRING(
                            REGEXP_SUBSTR(rr_canon, '^-?[0-9]+\\.?[0-9]*\\s*-\\s*[+-]?[0-9]+\\.?[0-9]*'),
                            LENGTH(REGEXP_SUBSTR(rr_canon, '^-?[0-9]+\\.?[0-9]*')) + 1
                        ),
                        '^\\s*-\\s*', ''
                    ) AS DOUBLE
                )
            WHEN 'point' THEN
                CAST(REGEXP_SUBSTR(rr_canon, '^[0-9]+\\.?[0-9]*') AS DOUBLE)
            WHEN 'combined' THEN
                CAST(REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '[<>]=?\\s*-?[0-9]+\\.?[0-9]*$'), '-?[0-9]+\\.?[0-9]*$') AS DOUBLE)
            ELSE NULL
        END AS high_val,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_SUBSTR(rr_canon, '^[<>]=?') IN ('<', '<=')
                     THEN REGEXP_SUBSTR(rr_canon, '^[<>]=?')
                     ELSE NULL END
            WHEN 'plain_range' THEN '<='
            WHEN 'point' THEN '<='
            WHEN 'combined' THEN REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '[<>]=?\\s*-?[0-9]+\\.?[0-9]*$'), '^[<>]=?')
            ELSE NULL
        END AS high_op
    FROM shape_classified
),

value_classified AS (
    SELECT
        *,
        -- NEW: microscopy quantity-word HIGH override, checked ahead of
        -- everything else -- 'occ/hpf', 'few/lpf', 'many/hpf', 'FEW
        -- (10-25/HPF)', etc. A leading test-name|-prefix (e.g. "URBC|") is
        -- stripped first. Explicitly does NOT match 'none/hpf' or a bare
        -- numeric count-range like '0-5/hpf' (anchored to the presence
        -- word at the start, so 'NONE-OCC/LPF' is correctly excluded too).
        REGEXP_REPLACE(UPPER(TRIM(rv)), '^[A-Z0-9 _]+\\|', '')
            REGEXP '^(OCC|FEW|MANY|MODERATE|MOD|NUMEROUS|RARE|PACKED)([[:space:]]|\\(|/)' AS is_microscopy_high,
        CASE
            WHEN rv2 IS NULL OR rv2 = '' THEN 'blank'
            WHEN UPPER(rv2) REGEXP '^#\\s*[0-9]+$' THEN 'noise'
            WHEN UPPER(rv2) REGEXP '^\\*?\\(?\\[?\\s*(PLEASE\\s+)?(SEE\\s+)?(FOOT)?NOTES?\\s*:?\\s*\\)?\\]?$' THEN 'noise'
            WHEN rv2 REGEXP '\\(\\(INSURANCEDETAILS\\)\\)' THEN 'noise'
            WHEN rv2 REGEXP '^[=<>]{0,2}\\s*-?[0-9]+\\.?[0-9]*\\s*$' THEN 'numeric'
            -- NEW: a grade symbol followed by descriptive text (e.g. "1+
            -- (small)", "2+ trace") is still a semi-quantitative
            -- qualitative result, not "unparseable" just because it has
            -- a digit in it -- route it to the qualitative comparison.
            WHEN TRIM(rv2) REGEXP '^[1-4]?\\+' THEN 'qualitative'
            WHEN rv2 NOT REGEXP '[0-9]' THEN 'qualitative'
            ELSE 'unparseable'
        END AS value_shape,
        CAST(REGEXP_SUBSTR(rv2, '-?[0-9]+\\.?[0-9]*') AS DOUBLE) AS rv_numeric,
        -- NEW: qualitative Positive/Negative synonym + grade-symbol
        -- canonicalization, applied to BOTH value and range, for the
        -- match-vs-range comparison rule below.
        CASE
            WHEN UPPER(TRIM(rv2)) REGEXP '^(POSITIVE|POS|REACTIVE|DETECTED|PRESENT)$'
                 OR TRIM(rv2) REGEXP '^[1-4]?\\+'
                THEN 'POSITIVE'
            WHEN UPPER(TRIM(rv2)) REGEXP '^(NEGATIVE|NEG|NON[- ]?REACTIVE|NONREACTIVE|NOT DETECTED|ABSENT)$'
                 OR TRIM(rv2) = '-'
                THEN 'NEGATIVE'
            ELSE UPPER(TRIM(rv2))
        END AS value_qual_canon,
        CASE
            WHEN UPPER(TRIM(rr_canon)) REGEXP '^(POSITIVE|POS|REACTIVE|DETECTED|PRESENT)$'
                 OR TRIM(rr_canon) REGEXP '^[1-4]?\\+$'
                THEN 'POSITIVE'
            WHEN UPPER(TRIM(rr_canon)) REGEXP '^(NEGATIVE|NEG|NON[- ]?REACTIVE|NONREACTIVE|NOT DETECTED|ABSENT)$'
                 OR TRIM(rr_canon) = '-'
                THEN 'NEGATIVE'
            ELSE UPPER(TRIM(rr_canon))
        END AS range_qual_canon
    FROM bounds_extracted
)

SELECT
    gold_row_id, ndid, psid, resultid, test_panel_name, test_parameter,
    result_value, result_range, normal_flag,
    range_shape, value_shape,
    CASE
        -- 0. Microscopy quantity-word override wins outright (occ/hpf,
        --    few/lpf, many/hpf, moderate, etc. -- a found nonzero count).
        WHEN is_microscopy_high = 1 THEN 'HIGH'

        -- 1. Noise in result_value always wins, regardless of range.
        WHEN value_shape = 'noise' THEN 'INVALID_RESULT_VALUE'
        WHEN value_shape = 'blank' THEN 'INVALID_RESULT_VALUE'

        -- 2. Range must be usable before anything else is evaluated.
        WHEN range_shape IN ('blank', 'unparseable') THEN 'INVALID_RESULT_RANGE'

        -- 3. Numeric result_value (incl. ratio/titer denominators folded
        --    into rv2 above) -> compare against the parsed numeric range.
        WHEN value_shape = 'numeric' AND range_shape = 'qualitative' THEN 'INVALID_RESULT_RANGE'
        WHEN value_shape = 'numeric' THEN
            CASE
                WHEN low_val IS NOT NULL AND (
                        (low_op = '>'  AND rv_numeric <= low_val) OR
                        (low_op = '>=' AND rv_numeric <  low_val)
                     ) THEN 'LOW'
                WHEN high_val IS NOT NULL AND (
                        (high_op = '<'  AND rv_numeric >= high_val) OR
                        (high_op = '<=' AND rv_numeric >  high_val)
                     ) THEN 'HIGH'
                ELSE 'NORMAL'
            END

        -- 4. Qualitative (text) result_value -> compare the canonicalized
        --    value against the canonicalized range: match -> NORMAL,
        --    mismatch -> ABNORMAL (replaces the old straight-passthrough
        --    rule, which just copied result_range verbatim regardless of
        --    whether it actually matched result_value).
        -- Some result_range values are a comma-separated LIST of multiple
        -- acceptable qualitative states, not a single value -- e.g.
        -- "Colorless, Straw, Yellow" or "Clear, Slt Hazy, Hazy, Slt
        -- Cloudy" or "Negative, Trace". Confirmed via live data: strict
        -- equality falsely flags a legitimate listed value (e.g. value
        -- "Yellow" vs range "Colorless, Straw, Yellow") as ABNORMAL when
        -- the raw normal_flag says Normal.
        -- NOTE: a plain substring check ("range LIKE %value%") is NOT
        -- safe here -- confirmed live regression where value "CLOUDY"
        -- false-matched inside range token "SLT CLOUDY" (a different,
        -- lesser severity grade), flipping a true Abnormal to Normal.
        -- FIND_IN_SET on a whitespace-normalized comma list gives exact
        -- token membership instead, which resolves both the list-range
        -- case AND avoids the substring false-positive.
        -- A hyphen is ALSO treated as a list separator here (not just a
        -- numeric-range dash) -- confirmed live: "Yellow-Amber" is a
        -- color-spectrum reference range where both endpoints ("Yellow",
        -- "Amber") individually carry normal_flag='N', the dominant
        -- pattern by volume (2,301 + 180 rows). True Positive/Negative
        -- hyphenated synonyms ("NON-REACTIVE") are already intercepted by
        -- the canonical POSITIVE/NEGATIVE mapping above and never reach
        -- this branch as a raw hyphenated string, so splitting on '-'
        -- here is safe. Known residual limitation: a value between the
        -- two endpoints but not equal to either (e.g. "Colorless" vs
        -- "Yellow-Amber", 313 rows) still reads ABNORMAL here despite
        -- normal_flag='N' -- resolving that would require an actual
        -- clinical color-order lookup, not a text-parsing rule, so it is
        -- deliberately left flagged rather than guessed at.
        WHEN value_shape = 'qualitative' AND range_shape = 'qualitative' THEN
            CASE WHEN FIND_IN_SET(value_qual_canon, REGEXP_REPLACE(range_qual_canon, '\\s*[,-]\\s*', ',')) > 0
                 THEN 'NORMAL' ELSE 'ABNORMAL' END
        WHEN value_shape = 'qualitative' THEN result_range

        -- 5. Anything left (value has digits but doesn't parse cleanly)
        --    is flagged rather than silently guessed at.
        ELSE 'INVALID_RESULT_VALUE'
    END AS normal_flag_std
FROM value_classified;
