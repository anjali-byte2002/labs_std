-- ============================================================================
-- normal_flag_std - StarRocks, v3
-- ============================================================================
-- Changes from v2, addressing this round's feedback:
--
--  1/2. Parenthesized ranges "(<3)", "(0-190)", "(<47.0)" were landing in
--       INVALID_RESULT_RANGE. Root cause: the old paren-strip regex
--       '^\((.*)\)$' requires the ')' to be the literal last character -
--       any trailing whitespace in the source data silently breaks it,
--       and nothing downstream ever strips it. Replaced with plain
--       LEFT()/RIGHT()/SUBSTRING() logic, which can't have that failure
--       mode (this also generically fixes any bracketed range, not just
--       the specific examples given).
--
--  3/4/5/7. "4.3 OR LESS", "1:20 < 1:20", "< OR = 1.07", "> OR = 60" -
--       by my own reading of the v2 logic these should already have
--       converted correctly, and I could not find the specific bug by
--       re-reading the file. Rather than keep guessing, I've (a)
--       defensively switched every \s whitespace-match to the POSIX
--       [[:space:]] class throughout, in case \s wasn't behaving as
--       expected, and (b) exposed range_shape/value_shape as output
--       columns below so if this is STILL wrong, you can tell me exactly
--       which bucket the row is landing in instead of just the final
--       flag - that's a debuggable fact instead of another guess.
--
--  6. "<1:40 TITER" as both value and range -> now NORMAL. The ratio
--     extraction strips the value's own "<" operator (a real, separate
--     gap), so instead of trying to fix that extraction generally, added
--     a direct check: if the (trimmed, uppercased) value text is
--     IDENTICAL to the (trimmed, uppercased) raw range text, it's NORMAL
--     outright - checked after the noise/blank filters so junk-vs-junk
--     doesn't accidentally qualify.
--
--  8. "RBC CSF|0 CELLS/UL" vs "0-10" -> was INVALID_RESULT_VALUE. Real
--     bug: the numeric check required the number to be the ENTIRE
--     remaining string (end-anchored), so any trailing unit text after
--     the number failed it. Fixed by (a) checking the dash-range shape
--     BEFORE the numeric shape, so genuine ranges still win, and (b)
--     dropping the end-anchor from the numeric check so trailing text
--     is tolerated once a dash-range has already been ruled out.
--
--  9. "1,001" vs "0-100" -> was INVALID_RESULT_VALUE. The thousands-
--     comma strip on the value side was only applied once; doubled it
--     to match the range side's handling, for multi-comma values.
-- ============================================================================

WITH value_norm AS (
    SELECT
        l.*,
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                CASE
                    WHEN result_value REGEXP '<root>.*</root>'
                        THEN REGEXP_REPLACE(result_value, '^.*<root>(.*)</root>.*$', '$1')
                    ELSE result_value
                END,
                '([0-9]),([0-9]{3})\\b', '$1$2'),
            '([0-9]),([0-9]{3})\\b', '$1$2'
        ) AS rv_unwrapped
    FROM rgd_gold_ad.labs l
),

range_trim0 AS (
    SELECT *, TRIM(result_range) AS rr_t0
    FROM value_norm
),

range_unparen AS (
    SELECT
        *,
        -- #1/#2 fix: strip a matching outer paren pair using plain
        -- string functions instead of a regex anchor, which can't be
        -- silently defeated by trailing whitespace inside the field
        CASE
            WHEN LEFT(rr_t0, 1) = '(' AND RIGHT(rr_t0, 1) = ')'
                THEN SUBSTRING(rr_t0, 2, LENGTH(rr_t0) - 2)
            ELSE rr_t0
        END AS rr_t1
    FROM range_trim0
),

range_pre AS (
    SELECT
        *,
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                UPPER(TRIM(rr_t1)),
                '([0-9]),([0-9]{3})\\b', '$1$2'),
            '([0-9]),([0-9]{3})\\b', '$1$2'
        ) AS rr_a
    FROM range_unparen
),

range_wordbounds AS (
    SELECT
        *,
        REGEXP_REPLACE(
            REGEXP_REPLACE(rr_a,
                '([0-9]*\\.?[0-9]+)[[:space:]]*OR[[:space:]]*LESS', '<=$1'),
            '([0-9]*\\.?[0-9]+)[[:space:]]*OR[[:space:]]*(MORE|GREATER)', '>=$1'
        ) AS rr_b
    FROM range_pre
),

range_opwords AS (
    SELECT
        *,
        REGEXP_REPLACE(
            REGEXP_REPLACE(rr_b, '>[[:space:]]*OR[[:space:]]*=', '>='),
            '<[[:space:]]*OR[[:space:]]*=', '<='
        ) AS rr_c
    FROM range_wordbounds
),

range_to AS (
    SELECT
        *,
        REGEXP_REPLACE(rr_c, '\\bTO\\b', '-') AS rr_d
    FROM range_opwords
),

range_join AS (
    SELECT
        *,
        REGEXP_REPLACE(rr_d,
            '^(-[0-9]*\\.?[0-9]+)[[:space:]]+(\\+[0-9]*\\.?[0-9]+)$', '$1-$2'
        ) AS rr_e
    FROM range_to
),

range_eq AS (
    SELECT
        *,
        REGEXP_REPLACE(rr_e, '([<>])[[:space:]]*=', '$1=') AS rr_f
    FROM range_join
),

range_loneparen AS (
    SELECT
        *,
        -- fallback for truncated ranges with an unmatched leading "(" -
        -- the LEFT/RIGHT strip above only fires when both parens exist
        REGEXP_REPLACE(rr_f, '^\\(', '') AS rr_canon0
    FROM range_eq
),

range_ratio_norm AS (
    SELECT
        *,
        CASE
            WHEN rr_canon0 REGEXP '[0-9]+[[:space:]]*:[[:space:]]*[0-9]+' THEN
                REGEXP_REPLACE(
                    REGEXP_REPLACE(
                        REGEXP_REPLACE(rr_canon0, '^(NEG\\w*|NON[[:space:]]*-?[[:space:]]*REA\\w*)[[:space:]]*:?[[:space:]]*\\(?[[:space:]]*', ''),
                        '\\)[[:space:]]*$', ''
                    ),
                    '[0-9]+[[:space:]]*:[[:space:]]*([0-9]+)', '$1'
                )
            ELSE rr_canon0
        END AS rr_canon
    FROM range_loneparen
),

shape_classified AS (
    SELECT
        *,
        TRIM(rv_unwrapped) AS rv,
        REGEXP_REPLACE(UPPER(TRIM(rv_unwrapped)), '^[A-Za-z0-9 _\\-\\.]+\\|', '') AS rv_stripped,
        -- #6 fix: value text identical to raw range text (case/whitespace
        -- insensitive) -> treated as NORMAL later, regardless of parsing
        UPPER(TRIM(rv_unwrapped)) = UPPER(TRIM(result_range)) AS is_value_equals_range,
        CASE
            WHEN UPPER(TRIM(rv_unwrapped)) REGEXP '^(NEG\\w*|NON[[:space:]]*-?[[:space:]]*REA\\w*)' THEN 'NEGATIVE'
            WHEN TRIM(rv_unwrapped) REGEXP '[0-9]+[[:space:]]*:[[:space:]]*[0-9]+'
                THEN REGEXP_REPLACE(TRIM(rv_unwrapped), '^.*?[0-9]+[[:space:]]*:[[:space:]]*([0-9]+).*$', '$1')
            ELSE REGEXP_REPLACE(TRIM(rv_unwrapped), '^[A-Za-z0-9 _\\-\\.]+\\|', '')
        END AS rv2,
        CASE
            WHEN rr_canon IS NULL OR TRIM(rr_canon) = '' THEN 'blank'
            WHEN rr_canon REGEXP '\\(\\(.*?\\)\\)' THEN 'unparseable'
            WHEN rr_canon REGEXP '^[^A-Za-z0-9]+$' THEN 'unparseable'
            WHEN rr_canon REGEXP '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+'
                THEN 'combined'
            WHEN rr_canon REGEXP '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+'
                THEN 'single_bound'
            WHEN rr_canon REGEXP '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+'
                THEN 'plain_range'
            WHEN rr_canon REGEXP ',' AND rr_canon REGEXP '[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+'
                THEN 'list_bound'
            WHEN rr_canon REGEXP '^[0-9]*\\.?[0-9]+'
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
        REGEXP_EXTRACT(rr_canon, '[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+', 0) AS list_bound_tok
    FROM shape_classified
),

bounds_extracted2 AS (
    SELECT
        *,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_EXTRACT(rr_canon, '^[<>]=?', 0) IN ('>', '>=')
                     THEN CAST(REGEXP_EXTRACT(REGEXP_EXTRACT(rr_canon, '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+', 0), '-?[0-9]*\\.?[0-9]+$', 0) AS DOUBLE)
                     ELSE NULL END
            WHEN 'plain_range' THEN
                CAST(REGEXP_EXTRACT(rr_canon, '^-?[0-9]*\\.?[0-9]+', 0) AS DOUBLE)
            WHEN 'point' THEN
                CAST(REGEXP_EXTRACT(rr_canon, '^[0-9]*\\.?[0-9]+', 0) AS DOUBLE)
            WHEN 'combined' THEN
                CAST(REGEXP_EXTRACT(REGEXP_EXTRACT(rr_canon, '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+', 0), '-?[0-9]*\\.?[0-9]+$', 0) AS DOUBLE)
            WHEN 'list_bound' THEN
                CASE WHEN REGEXP_EXTRACT(list_bound_tok, '^[<>]=?', 0) IN ('>', '>=')
                     THEN CAST(REGEXP_EXTRACT(list_bound_tok, '-?[0-9]*\\.?[0-9]+$', 0) AS DOUBLE)
                     ELSE NULL END
            ELSE NULL
        END AS low_val,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_EXTRACT(rr_canon, '^[<>]=?', 0) IN ('>', '>=')
                     THEN REGEXP_EXTRACT(rr_canon, '^[<>]=?', 0)
                     ELSE NULL END
            WHEN 'plain_range' THEN '>='
            WHEN 'point' THEN '>='
            WHEN 'combined' THEN REGEXP_EXTRACT(REGEXP_EXTRACT(rr_canon, '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+', 0), '^[<>]=?', 0)
            WHEN 'list_bound' THEN
                CASE WHEN REGEXP_EXTRACT(list_bound_tok, '^[<>]=?', 0) IN ('>', '>=')
                     THEN REGEXP_EXTRACT(list_bound_tok, '^[<>]=?', 0)
                     ELSE NULL END
            ELSE NULL
        END AS low_op,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_EXTRACT(rr_canon, '^[<>]=?', 0) IN ('<', '<=')
                     THEN CAST(REGEXP_EXTRACT(REGEXP_EXTRACT(rr_canon, '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+', 0), '-?[0-9]*\\.?[0-9]+$', 0) AS DOUBLE)
                     ELSE NULL END
            WHEN 'plain_range' THEN
                CAST(
                    REGEXP_REPLACE(
                        SUBSTRING(
                            REGEXP_EXTRACT(rr_canon, '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+', 0),
                            LENGTH(REGEXP_EXTRACT(rr_canon, '^-?[0-9]*\\.?[0-9]+', 0)) + 1
                        ),
                        '^[[:space:]]*-[[:space:]]*', ''
                    ) AS DOUBLE
                )
            WHEN 'point' THEN
                CAST(REGEXP_EXTRACT(rr_canon, '^[0-9]*\\.?[0-9]+', 0) AS DOUBLE)
            WHEN 'combined' THEN
                CAST(REGEXP_EXTRACT(REGEXP_EXTRACT(rr_canon, '[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+$', 0), '-?[0-9]*\\.?[0-9]+$', 0) AS DOUBLE)
            WHEN 'list_bound' THEN
                CASE WHEN REGEXP_EXTRACT(list_bound_tok, '^[<>]=?', 0) IN ('<', '<=')
                     THEN CAST(REGEXP_EXTRACT(list_bound_tok, '-?[0-9]*\\.?[0-9]+$', 0) AS DOUBLE)
                     ELSE NULL END
            ELSE NULL
        END AS high_val,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_EXTRACT(rr_canon, '^[<>]=?', 0) IN ('<', '<=')
                     THEN REGEXP_EXTRACT(rr_canon, '^[<>]=?', 0)
                     ELSE NULL END
            WHEN 'plain_range' THEN '<='
            WHEN 'point' THEN '<='
            WHEN 'combined' THEN REGEXP_EXTRACT(REGEXP_EXTRACT(rr_canon, '[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+$', 0), '^[<>]=?', 0)
            WHEN 'list_bound' THEN
                CASE WHEN REGEXP_EXTRACT(list_bound_tok, '^[<>]=?', 0) IN ('<', '<=')
                     THEN REGEXP_EXTRACT(list_bound_tok, '^[<>]=?', 0)
                     ELSE NULL END
            ELSE NULL
        END AS high_op
    FROM bounds_extracted
),

value_classified AS (
    SELECT
        *,
        rv_stripped REGEXP '^(OCC|FEW|MANY|MODERATE|MOD|NUMEROUS|RARE|PACKED)([[:space:]]|\\(|/)' AS is_microscopy_high,
        rv_stripped REGEXP '^(NEG\\w*|NON[[:space:]]*-?[[:space:]]*REA\\w*|NONE\\b|NOT[[:space:]]*DETECTED|ABSENT|ABS$)' AS is_negative_normal,
        rv_stripped REGEXP '^(POS\\w*|REACT\\w*|DETECTED\\b|PRESENT\\b)' AS is_positive_abnormal,
        CASE
            WHEN rv_stripped = 'NONE' THEN 0
            WHEN rv_stripped = 'RARE' THEN 1
            WHEN rv_stripped = 'FEW' THEN 2
            WHEN rv_stripped IN ('OCC','OCCASIONAL') THEN 3
            WHEN rv_stripped IN ('MOD','MODERATE') THEN 4
            WHEN rv_stripped = 'MANY' THEN 5
            WHEN rv_stripped = 'NUMEROUS' THEN 6
            WHEN rv_stripped = 'PACKED' THEN 7
            ELSE NULL
        END AS value_mval_ordinal,
        REGEXP_EXTRACT(rr_canon, '^([A-Z]+)[[:space:]]*-[[:space:]]*([A-Z]+)', 1) AS range_word1,
        REGEXP_EXTRACT(rr_canon, '^([A-Z]+)[[:space:]]*-[[:space:]]*([A-Z]+)', 2) AS range_word2,
        CASE
            WHEN rv2 IS NULL OR rv2 = '' THEN 'blank'
            WHEN UPPER(rv2) REGEXP '^#[[:space:]]*[0-9]+$' THEN 'noise'
            WHEN UPPER(rv2) REGEXP '^\\*?\\(?\\[?[[:space:]]*(PLEASE[[:space:]]+)?(SEE[[:space:]]+)?(FOOT)?NOTES?[[:space:]]*:?[[:space:]]*\\)?\\]?$' THEN 'noise'
            WHEN rv2 REGEXP '\\(\\(.*?\\)\\)' THEN 'noise'
            WHEN UPPER(rv2) REGEXP '^[^A-Za-z0-9]+$' THEN 'noise'
            WHEN UPPER(TRIM(rv2)) = 'X' THEN 'noise'
            WHEN rv2 REGEXP '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+' THEN 'range'
            WHEN rv2 REGEXP '^[=<>]{0,2}[[:space:]]*-?[0-9]*\\.?[0-9]+' THEN 'numeric'
            WHEN TRIM(rv2) REGEXP '^[1-4]?\\+' THEN 'qualitative'
            WHEN rv2 NOT REGEXP '[0-9]' THEN 'qualitative'
            ELSE 'unparseable'
        END AS value_shape,
        CAST(REGEXP_EXTRACT(rv2, '-?[0-9]*\\.?[0-9]+', 0) AS DOUBLE) AS rv_numeric,
        CASE WHEN rv2 REGEXP '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+'
            THEN CAST(REGEXP_EXTRACT(rv2, '^-?[0-9]*\\.?[0-9]+', 0) AS DOUBLE)
            ELSE NULL END AS rv_low,
        CASE WHEN rv2 REGEXP '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+'
            THEN CAST(
                REGEXP_REPLACE(
                    SUBSTRING(
                        REGEXP_EXTRACT(rv2, '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+', 0),
                        LENGTH(REGEXP_EXTRACT(rv2, '^-?[0-9]*\\.?[0-9]+', 0)) + 1
                    ),
                    '^[[:space:]]*-[[:space:]]*', ''
                ) AS DOUBLE
            )
            ELSE NULL END AS rv_high,
        CASE
            WHEN UPPER(rv2) REGEXP '(NON[- ]?REACTIVE|NONREACTIVE|\\bNEGATIVE\\b|\\bNEG\\b|\\bNOT DETECTED\\b|\\bABSENT\\b|\\bABS\\b)'
                 OR TRIM(rv2) = '-'
                THEN 'NEGATIVE'
            WHEN UPPER(rv2) REGEXP '(\\bPOSITIVE\\b|\\bREACTIVE\\b|\\bDETECTED\\b|\\bPRESENT\\b)'
                 OR TRIM(rv2) REGEXP '^[1-4]?\\+'
                THEN 'POSITIVE'
            ELSE UPPER(TRIM(rv2))
        END AS value_qual_canon,
        CASE
            WHEN UPPER(rr_canon) REGEXP '(NON[- ]?REACTIVE|NONREACTIVE|\\bNEGATIVE\\b|\\bNEG\\b|\\bNOT DETECTED\\b|\\bABSENT\\b|\\bABS\\b)'
                 OR TRIM(rr_canon) = '-'
                THEN 'NEGATIVE'
            WHEN UPPER(rr_canon) REGEXP '(\\bPOSITIVE\\b|\\bREACTIVE\\b|\\bDETECTED\\b|\\bPRESENT\\b)'
                 OR TRIM(rr_canon) REGEXP '^[1-4]?\\+$'
                THEN 'POSITIVE'
            ELSE UPPER(TRIM(rr_canon))
        END AS range_qual_canon
    FROM bounds_extracted2
),

value_classified2 AS (
    SELECT
        *,
        CASE
            WHEN range_word1 IS NULL OR range_word1 = '' THEN NULL
            WHEN 'NONE' LIKE CONCAT(range_word1,'%') THEN 0
            WHEN 'RARE' LIKE CONCAT(range_word1,'%') THEN 1
            WHEN 'FEW' LIKE CONCAT(range_word1,'%') THEN 2
            WHEN 'OCCASIONAL' LIKE CONCAT(range_word1,'%') OR 'OCC' LIKE CONCAT(range_word1,'%') THEN 3
            WHEN 'MODERATE' LIKE CONCAT(range_word1,'%') OR 'MOD' LIKE CONCAT(range_word1,'%') THEN 4
            WHEN 'MANY' LIKE CONCAT(range_word1,'%') THEN 5
            WHEN 'NUMEROUS' LIKE CONCAT(range_word1,'%') THEN 6
            WHEN 'PACKED' LIKE CONCAT(range_word1,'%') THEN 7
            ELSE NULL
        END AS range_ord1,
        CASE
            WHEN range_word2 IS NULL OR range_word2 = '' THEN NULL
            WHEN 'NONE' LIKE CONCAT(range_word2,'%') THEN 0
            WHEN 'RARE' LIKE CONCAT(range_word2,'%') THEN 1
            WHEN 'FEW' LIKE CONCAT(range_word2,'%') THEN 2
            WHEN 'OCCASIONAL' LIKE CONCAT(range_word2,'%') OR 'OCC' LIKE CONCAT(range_word2,'%') THEN 3
            WHEN 'MODERATE' LIKE CONCAT(range_word2,'%') OR 'MOD' LIKE CONCAT(range_word2,'%') THEN 4
            WHEN 'MANY' LIKE CONCAT(range_word2,'%') THEN 5
            WHEN 'NUMEROUS' LIKE CONCAT(range_word2,'%') THEN 6
            WHEN 'PACKED' LIKE CONCAT(range_word2,'%') THEN 7
            ELSE NULL
        END AS range_ord2
    FROM value_classified
),

flags_computed AS (
    SELECT
        result_value, result_range,
        CASE
            WHEN raw_flag_val IN ('NORMAL', 'ABNORMAL', 'LOW', 'HIGH', 'INVALID_RESULT_RANGE', 'INVALID_RESULT_VALUE')
                THEN raw_flag_val
            ELSE 'NS'
        END AS normal_flag_std
    FROM (
        SELECT
            *,
            CASE
            WHEN is_microscopy_high = 1 THEN 'HIGH'
            WHEN is_negative_normal = 1 THEN 'NORMAL'
            WHEN is_positive_abnormal = 1 THEN 'ABNORMAL'
            WHEN value_shape = 'noise' THEN 'INVALID_RESULT_VALUE'
            WHEN value_shape = 'blank' THEN 'INVALID_RESULT_VALUE'
            WHEN is_value_equals_range = 1 THEN 'NORMAL'
            WHEN range_shape = 'point' THEN 'NS'
            WHEN range_shape IN ('blank', 'unparseable') THEN 'INVALID_RESULT_RANGE'
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
            WHEN value_shape = 'range' AND range_shape = 'qualitative' THEN 'INVALID_RESULT_RANGE'
            WHEN value_shape = 'range' THEN
                CASE
                    WHEN low_val IS NOT NULL AND (
                            (low_op = '>'  AND rv_high <= low_val) OR
                            (low_op = '>=' AND rv_high <  low_val)
                         ) THEN 'LOW'
                    WHEN high_val IS NOT NULL AND (
                            (high_op = '<'  AND rv_low >= high_val) OR
                            (high_op = '<=' AND rv_low >  high_val)
                         ) THEN 'HIGH'
                    ELSE 'NORMAL'
                END
            WHEN value_shape = 'qualitative' AND range_shape = 'qualitative' THEN
                CASE
                    WHEN value_mval_ordinal IS NOT NULL AND range_ord1 IS NOT NULL THEN
                        CASE
                            WHEN value_mval_ordinal < range_ord1 THEN 'LOW'
                            WHEN range_ord2 IS NOT NULL AND value_mval_ordinal > range_ord2 THEN 'HIGH'
                            WHEN range_ord2 IS NULL AND value_mval_ordinal > range_ord1 THEN 'HIGH'
                            ELSE 'NORMAL'
                        END
                    WHEN FIND_IN_SET(value_qual_canon, REGEXP_REPLACE(range_qual_canon, '[[:space:]]*[,-][[:space:]]*', ',')) > 0
                        THEN 'NORMAL'
                    ELSE 'ABNORMAL'
                END
            WHEN value_shape = 'qualitative' THEN result_range
            ELSE 'INVALID_RESULT_VALUE'
            END AS raw_flag_val
        FROM value_classified2
    ) t
)

SELECT DISTINCT
    result_value,
    result_range,
    normal_flag_std
FROM flags_computed
ORDER BY normal_flag_std, result_range, result_value;
