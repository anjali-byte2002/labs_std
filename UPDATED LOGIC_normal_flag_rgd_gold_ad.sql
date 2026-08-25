-- ============================================================================
-- Labs normal_flag standardization -- rgd_gold_ad.labs -- v3
-- Read-only SELECT -- no ALTER TABLE / write access required.
--
-- normal_flag       = raw value straight from source (unchanged, untouched)
-- normal_flag_std   = standardized value, constrained to EXACTLY:
--                        NORMAL, ABNORMAL, LOW, HIGH,
--                        INVALID_RESULT_RANGE, INVALID_RESULT_VALUE
--                      Everything else (bare 'point' reference ranges,
--                      the old qualitative-passthrough raw text, any
--                      other fallthrough) -> 'NS'.
--
-- Two changes vs. the prior version:
--   1. range_shape = 'point' (a bare-number reference like '0' or
--      '500 ng/mL' -- the leading number is a cutoff/reference value,
--      not a true bound pair) no longer runs through the LOW/NORMAL/HIGH
--      numeric comparison. Too ambiguous to call a direction on -- goes
--      straight to 'NS'.
--   2. The final SELECT wraps the whole CASE in an outer collapse: only
--      the six canonical labels pass through as-is; every other value
--      (including the old qualitative result_range passthrough text)
--      becomes 'NS'.
-- All other numeric range formats (plain dash range, TO-separated,
-- space-signed pair, single bound, textual "OR =", combined double
-- bound) are UNCHANGED and still compute LOW/NORMAL/HIGH as before.
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
            '([<>])\\s*=', '$1='
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
        -- 'point' still computes low_val/high_val here for CTE-shape
        -- consistency, but these are unused for 'point' rows now --
        -- see the final CASE, which shortcuts range_shape = 'point'
        -- straight to 'NS' before ever reaching the comparison logic.
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
        REGEXP_REPLACE(UPPER(TRIM(rv)), '^[A-Z0-9 _]+\\|', '')
            REGEXP '^(OCC|FEW|MANY|MODERATE|MOD|NUMEROUS|RARE|PACKED)([[:space:]]|\\(|/)' AS is_microscopy_high,
        CASE
            WHEN rv2 IS NULL OR rv2 = '' THEN 'blank'
            WHEN UPPER(rv2) REGEXP '^#\\s*[0-9]+$' THEN 'noise'
            WHEN UPPER(rv2) REGEXP '^\\*?\\(?\\[?\\s*(PLEASE\\s+)?(SEE\\s+)?(FOOT)?NOTES?\\s*:?\\s*\\)?\\]?$' THEN 'noise'
            WHEN rv2 REGEXP '\\(\\(INSURANCEDETAILS\\)\\)' THEN 'noise'
            WHEN rv2 REGEXP '^[=<>]{0,2}\\s*-?[0-9]+\\.?[0-9]*\\s*$' THEN 'numeric'
            WHEN rv2 REGEXP '^-?[0-9]+\\.?[0-9]*\\s*-\\s*[+-]?[0-9]+\\.?[0-9]*' THEN 'range'
            WHEN TRIM(rv2) REGEXP '^[1-4]?\\+' THEN 'qualitative'
            WHEN rv2 NOT REGEXP '[0-9]' THEN 'qualitative'
            ELSE 'unparseable'
        END AS value_shape,
        CAST(REGEXP_SUBSTR(rv2, '-?[0-9]+\\.?[0-9]*') AS DOUBLE) AS rv_numeric,
        CASE WHEN rv2 REGEXP '^-?[0-9]+\\.?[0-9]*\\s*-\\s*[+-]?[0-9]+\\.?[0-9]*'
            THEN CAST(REGEXP_SUBSTR(rv2, '^-?[0-9]+\\.?[0-9]*') AS DOUBLE)
            ELSE NULL END AS rv_low,
        CASE WHEN rv2 REGEXP '^-?[0-9]+\\.?[0-9]*\\s*-\\s*[+-]?[0-9]+\\.?[0-9]*'
            THEN CAST(
                REGEXP_REPLACE(
                    SUBSTRING(
                        REGEXP_SUBSTR(rv2, '^-?[0-9]+\\.?[0-9]*\\s*-\\s*[+-]?[0-9]+\\.?[0-9]*'),
                        LENGTH(REGEXP_SUBSTR(rv2, '^-?[0-9]+\\.?[0-9]*')) + 1
                    ),
                    '^\\s*-\\s*', ''
                ) AS DOUBLE
            )
            ELSE NULL END AS rv_high,
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
),

raw_flag AS (
    SELECT
        *,
        CASE
            WHEN is_microscopy_high = 1 THEN 'HIGH'
            WHEN value_shape = 'noise' THEN 'INVALID_RESULT_VALUE'
            WHEN value_shape = 'blank' THEN 'INVALID_RESULT_VALUE'

            -- Bare 'point' reference range -> too ambiguous for a
            -- directional call. Checked ahead of the blank/unparseable
            -- range check ('point' is a distinct, successfully-parsed
            -- shape) and ahead of every numeric/range comparison below.
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
                CASE WHEN FIND_IN_SET(value_qual_canon, REGEXP_REPLACE(range_qual_canon, '\\s*[,-]\\s*', ',')) > 0
                     THEN 'NORMAL' ELSE 'ABNORMAL' END
            WHEN value_shape = 'qualitative' THEN result_range
            ELSE 'INVALID_RESULT_VALUE'
        END AS raw_flag_val
    FROM value_classified
)

SELECT
    gold_row_id, ndid, psid, resultid, test_panel_name, test_parameter,
    result_value, result_range, normal_flag,
    range_shape, value_shape,
    -- Final collapse: only these six canonical labels survive as-is;
    -- everything else (the 'point'->NS case above, and any leaked
    -- qualitative-passthrough raw text) becomes 'NS'.
    CASE
        WHEN raw_flag_val IN ('NORMAL','ABNORMAL','LOW','HIGH','INVALID_RESULT_RANGE','INVALID_RESULT_VALUE')
            THEN raw_flag_val
        ELSE 'NS'
    END AS normal_flag_std_final
FROM raw_flag;
