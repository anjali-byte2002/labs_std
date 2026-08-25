-- ============================================================================
-- normal_flag_std - MySQL port of the StarRocks v3 query
-- ============================================================================
--
--  1. Backreference syntax: CORRECTED after testing. MySQL's regex
--     engine (ICU-based) actually uses the SAME $1, $2 syntax as
--     StarRocks for backreferences in REGEXP_REPLACE - confirmed by
--     testing REGEXP_REPLACE(...,'\\1') and getting back a bare "1"
--     (MySQL's own string-literal unescaping strips the backslash as
--     an escape character before the regex engine ever sees it, so \1
--     is not a backreference here - it's just the literal digit with
--     a consumed backslash). All replacements below use $1/$2.
--
--  2. No REGEXP_EXTRACT in MySQL: StarRocks' REGEXP_EXTRACT(str, pattern,
--     pos) lets you pull a specific numbered capture group. MySQL only
--     has REGEXP_SUBSTR(str, pattern), which returns the whole match.
--     - Every REGEXP_EXTRACT(..., 0) (pos=0 = "whole match") converts
--       directly to REGEXP_SUBSTR(...) with no other change.
--     - The two places that needed a SPECIFIC group (range_word1 = group
--       1, range_word2 = group 2, used for the ordinal quantity-band
--       comparison) are rewritten as a guarded REGEXP_REPLACE that
--       matches the whole string and replaces it with just that group's
--       backreference - guarded by a separate REGEXP check first, since
--       REGEXP_REPLACE returns the ORIGINAL string unchanged (not NULL)
--       when the pattern doesn't match, which would otherwise leak
--       garbage into the ordinal lookup.
--
--  3. Version requirements: CAST(... AS DOUBLE) needs MySQL 8.0.17+.
--     REGEXP/REGEXP_REPLACE/REGEXP_SUBSTR (ICU-based) need MySQL 8.0.4+.
--     Run SELECT VERSION(); first if unsure.
--
--
-- ============================================================================

WITH value_norm AS (
    SELECT
        l.*,
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                CASE
                    WHEN result_value REGEXP '<root>.*</root>'
                        THEN REGEXP_REPLACE(REGEXP_REPLACE(result_value, '^.*<root>', ''), '</root>.*$', '')
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
        REGEXP_SUBSTR(rr_canon, '[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+') AS list_bound_tok
    FROM shape_classified
),

bounds_extracted2 AS (
    SELECT
        *,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_SUBSTR(rr_canon, '^[<>]=?') IN ('>', '>=')
                     THEN CAST(REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+'), '-?[0-9]*\\.?[0-9]+$') AS DOUBLE)
                     ELSE NULL END
            WHEN 'plain_range' THEN
                CAST(REGEXP_SUBSTR(rr_canon, '^-?[0-9]*\\.?[0-9]+') AS DOUBLE)
            WHEN 'point' THEN
                CAST(REGEXP_SUBSTR(rr_canon, '^[0-9]*\\.?[0-9]+') AS DOUBLE)
            WHEN 'combined' THEN
                CAST(REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+'), '-?[0-9]*\\.?[0-9]+$') AS DOUBLE)
            WHEN 'list_bound' THEN
                CASE WHEN REGEXP_SUBSTR(list_bound_tok, '^[<>]=?') IN ('>', '>=')
                     THEN CAST(REGEXP_SUBSTR(list_bound_tok, '-?[0-9]*\\.?[0-9]+$') AS DOUBLE)
                     ELSE NULL END
            ELSE NULL
        END AS low_val,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_SUBSTR(rr_canon, '^[<>]=?') IN ('>', '>=')
                     THEN REGEXP_SUBSTR(rr_canon, '^[<>]=?')
                     ELSE NULL END
            WHEN 'plain_range' THEN '>='
            WHEN 'point' THEN '>='
            WHEN 'combined' THEN REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+'), '^[<>]=?')
            WHEN 'list_bound' THEN
                CASE WHEN REGEXP_SUBSTR(list_bound_tok, '^[<>]=?') IN ('>', '>=')
                     THEN REGEXP_SUBSTR(list_bound_tok, '^[<>]=?')
                     ELSE NULL END
            ELSE NULL
        END AS low_op,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_SUBSTR(rr_canon, '^[<>]=?') IN ('<', '<=')
                     THEN CAST(REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '^[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+'), '-?[0-9]*\\.?[0-9]+$') AS DOUBLE)
                     ELSE NULL END
            WHEN 'plain_range' THEN
                CAST(
                    REGEXP_REPLACE(
                        SUBSTRING(
                            REGEXP_SUBSTR(rr_canon, '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+'),
                            LENGTH(REGEXP_SUBSTR(rr_canon, '^-?[0-9]*\\.?[0-9]+')) + 1
                        ),
                        '^[[:space:]]*-[[:space:]]*', ''
                    ) AS DOUBLE
                )
            WHEN 'point' THEN
                CAST(REGEXP_SUBSTR(rr_canon, '^[0-9]*\\.?[0-9]+') AS DOUBLE)
            WHEN 'combined' THEN
                CAST(REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+$'), '-?[0-9]*\\.?[0-9]+$') AS DOUBLE)
            WHEN 'list_bound' THEN
                CASE WHEN REGEXP_SUBSTR(list_bound_tok, '^[<>]=?') IN ('<', '<=')
                     THEN CAST(REGEXP_SUBSTR(list_bound_tok, '-?[0-9]*\\.?[0-9]+$') AS DOUBLE)
                     ELSE NULL END
            ELSE NULL
        END AS high_val,
        CASE range_shape
            WHEN 'single_bound' THEN
                CASE WHEN REGEXP_SUBSTR(rr_canon, '^[<>]=?') IN ('<', '<=')
                     THEN REGEXP_SUBSTR(rr_canon, '^[<>]=?')
                     ELSE NULL END
            WHEN 'plain_range' THEN '<='
            WHEN 'point' THEN '<='
            WHEN 'combined' THEN REGEXP_SUBSTR(REGEXP_SUBSTR(rr_canon, '[<>]=?[[:space:]]*-?[0-9]*\\.?[0-9]+$'), '^[<>]=?')
            WHEN 'list_bound' THEN
                CASE WHEN REGEXP_SUBSTR(list_bound_tok, '^[<>]=?') IN ('<', '<=')
                     THEN REGEXP_SUBSTR(list_bound_tok, '^[<>]=?')
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
        -- MySQL has no REGEXP_EXTRACT(str,pattern,group) - isolate group 1
        -- via REGEXP_REPLACE across the whole matched string, guarded by
        -- a REGEXP check first (REGEXP_REPLACE returns the ORIGINAL
        -- string unchanged, not NULL, when nothing matches)
        CASE WHEN rr_canon REGEXP '^([A-Z]+)[[:space:]]*-[[:space:]]*([A-Z]+)'
             THEN REGEXP_REPLACE(rr_canon, '^([A-Z]+)[[:space:]]*-[[:space:]]*([A-Z]+).*$', '$1')
             ELSE NULL END AS range_word1,
        CASE WHEN rr_canon REGEXP '^([A-Z]+)[[:space:]]*-[[:space:]]*([A-Z]+)'
             THEN REGEXP_REPLACE(rr_canon, '^([A-Z]+)[[:space:]]*-[[:space:]]*([A-Z]+).*$', '$2')
             ELSE NULL END AS range_word2,
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
        CAST(REGEXP_SUBSTR(rv2, '-?[0-9]*\\.?[0-9]+') AS DOUBLE) AS rv_numeric,
        CASE WHEN rv2 REGEXP '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+'
            THEN CAST(REGEXP_SUBSTR(rv2, '^-?[0-9]*\\.?[0-9]+') AS DOUBLE)
            ELSE NULL END AS rv_low,
        CASE WHEN rv2 REGEXP '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+'
            THEN CAST(
                REGEXP_REPLACE(
                    SUBSTRING(
                        REGEXP_SUBSTR(rv2, '^-?[0-9]*\\.?[0-9]+[[:space:]]*-[[:space:]]*[+-]?[0-9]*\\.?[0-9]+'),
                        LENGTH(REGEXP_SUBSTR(rv2, '^-?[0-9]*\\.?[0-9]+')) + 1
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
