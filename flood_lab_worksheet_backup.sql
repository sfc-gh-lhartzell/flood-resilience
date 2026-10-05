-- ============================================================
-- FLOOD RESILIENCE HOL - WORKSHEET BACKUP
-- Use this if the notebook won't start (SPCS container capacity).
-- Runs on a warehouse only - no container needed.
--
-- HOW TO USE:
--   1. Do README Steps 1-2 first (Marketplace Overture install +
--      Git workspace named exactly "flood-resilience").
--   2. Open this file in your workspace, set role ACCOUNTADMIN.
--   3. Run section by section top to bottom (Cmd/Ctrl+Enter per
--      statement, or select a block and run). Step 1.4 takes 3-5 min.
--   4. Then build the agent with CoCo: paste the notebook Lab 7B
--      prompts into the CoCo panel. Only if that fails, uncomment
--      the FALLBACK section at the bottom.
-- ============================================================


-- ############################################################
-- Lab 1: Environment Setup
-- ############################################################

-- ============================================================
-- STEP 1.1: Create database, schema, and warehouse
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE  IF NOT EXISTS FLOOD_ANALYTICS;
CREATE SCHEMA    IF NOT EXISTS FLOOD_ANALYTICS.FLOOD;

CREATE WAREHOUSE IF NOT EXISTS FLOOD_WH
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND   = 120
  AUTO_RESUME    = TRUE
  COMMENT        = 'Warehouse for Flood Vulnerability HOL';

USE DATABASE  FLOOD_ANALYTICS;
USE SCHEMA    FLOOD;
USE WAREHOUSE FLOOD_WH;

SELECT CURRENT_DATABASE(), CURRENT_SCHEMA(), CURRENT_WAREHOUSE();

-- ============================================================
-- STEP 1.3: Verify Overture Maps Buildings is installed
-- ============================================================
-- Sample 10 Louisiana buildings to confirm access
SELECT
    ID,
    NAMES['primary']::STRING AS NAME,
    SUBTYPE,
    CLASS,
    HEIGHT,
    NUM_FLOORS,
    BBOX
FROM OVERTURE_MAPS_BUILDINGS.CARTO.BUILDING
WHERE BBOX:xmin >= -94.05
  AND BBOX:xmax <= -88.82
  AND BBOX:ymin >=  28.93
  AND BBOX:ymax <=  33.02
LIMIT 10;

-- ============================================================
-- STEP 1.4: Extract Louisiana buildings + compute H3 indices
-- ⏳ This scans ~2.3B global rows — expect 3-5 min on MEDIUM
-- ============================================================
CREATE OR REPLACE TABLE BUILDINGS_LA AS
SELECT
    ID,
    NAMES['primary']::STRING                          AS NAME,
    SUBTYPE,
    CLASS,
    HEIGHT,
    NUM_FLOORS,
    GEOMETRY,
    BBOX,
    ST_X(ST_CENTROID(GEOMETRY))                       AS LONGITUDE,
    ST_Y(ST_CENTROID(GEOMETRY))                       AS LATITUDE,
    H3_POINT_TO_CELL_STRING(ST_CENTROID(GEOMETRY), 8) AS H3_INDEX_8,
    H3_POINT_TO_CELL_STRING(ST_CENTROID(GEOMETRY), 6) AS H3_INDEX_6
FROM OVERTURE_MAPS_BUILDINGS.CARTO.BUILDING
WHERE BBOX:xmin >= -94.05
  AND BBOX:xmax <= -88.82
  AND BBOX:ymin >=  28.93
  AND BBOX:ymax <=  33.02;

-- Expected: ~3-4 million buildings
SELECT COUNT(*) AS TOTAL_LA_BUILDINGS FROM BUILDINGS_LA;


-- ############################################################
-- Lab 2: Load FEMA & CDC Reference Data
-- ############################################################

-- ============================================================
-- STEP 2.1: Create internal stage and CSV file format
-- ============================================================
CREATE OR REPLACE STAGE FLOOD_DATA_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Stage for FEMA NRI, CDC SVI CSVs and policy PDFs';

CREATE OR REPLACE FILE FORMAT CSV_FORMAT
  TYPE                         = 'CSV'
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  PARSE_HEADER                 = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  NULL_IF                      = ('', 'NULL', 'None', 'NA', '-999')
  EMPTY_FIELD_AS_NULL          = TRUE;

-- Confirm stage is ready
SHOW STAGES LIKE 'FLOOD_DATA_STAGE';

-- ============================================================
-- STEP 2.2: Load parish centroids, FEMA NRI and CDC SVI data
-- (feeds the Lab 3 join: Buildings -> Parish -> NRI/SVI risk profiles)
--
-- Join strategy:
-- 1. Load parish centroids (64 parishes with lat/lon)
-- 2. Aggregate NRI + SVI to parish level (filtering -999 sentinels)
-- 3. For each H3 hex, find the nearest parish centroid (HAVERSINE)
-- 4. Join buildings to their H3 hex -> parish -> risk profile
-- ============================================================

-- Step A: Upload workspace CSVs to stage and load tables
COPY FILES INTO @FLOOD_DATA_STAGE/parish/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('data/parish_centroids/LA_Parish_Centroids.csv');

COPY FILES INTO @FLOOD_DATA_STAGE/nri/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('data/fema_nri/NRI_CensusTracts_Louisiana.csv');

COPY FILES INTO @FLOOD_DATA_STAGE/svi/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('data/cdc_svi/SVI_2022_LA.csv');

-- Load parish centroids
CREATE OR REPLACE TABLE PARISH_CENTROIDS (
    STCOFIPS  STRING,
    PARISH    STRING,
    LATITUDE  FLOAT,
    LONGITUDE FLOAT
);

COPY INTO PARISH_CENTROIDS
FROM @FLOOD_DATA_STAGE/parish/
FILE_FORMAT = CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'CONTINUE';

SELECT COUNT(*) AS PARISH_COUNT FROM PARISH_CENTROIDS;

-- Load FEMA NRI data
CREATE OR REPLACE TABLE FEMA_NRI
USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(INFER_SCHEMA(
        LOCATION => '@FLOOD_DATA_STAGE/nri/',
        FILE_FORMAT => 'CSV_FORMAT'
    ))
);

COPY INTO FEMA_NRI
FROM @FLOOD_DATA_STAGE/nri/
FILE_FORMAT = CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'CONTINUE';

SELECT COUNT(*) AS NRI_TRACT_COUNT FROM FEMA_NRI;

-- Load CDC SVI data
CREATE OR REPLACE TABLE CDC_SVI
USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(INFER_SCHEMA(
        LOCATION => '@FLOOD_DATA_STAGE/svi/',
        FILE_FORMAT => 'CSV_FORMAT'
    ))
);

COPY INTO CDC_SVI
FROM @FLOOD_DATA_STAGE/svi/
FILE_FORMAT = CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR = 'CONTINUE';

SELECT COUNT(*) AS SVI_TRACT_COUNT FROM CDC_SVI;

-- Derive FLOOD_ZONES from NRI inland/coastal flood data
CREATE OR REPLACE TABLE FLOOD_ZONES AS
SELECT
    TRACTFIPS,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High') THEN 'VE'
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High') THEN 'AE'
        WHEN IFLD_RISKR = 'Relatively Moderate' OR CFLD_RISKR = 'Relatively Moderate' THEN 'X500'
        ELSE 'X'
    END AS FLOOD_ZONE,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High') THEN 'Coastal High Hazard Area'
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High') THEN 'Special Flood Hazard Area'
        WHEN IFLD_RISKR = 'Relatively Moderate' OR CFLD_RISKR = 'Relatively Moderate' THEN '500-Year Floodplain'
        ELSE 'Minimal Flood Hazard'
    END AS ZONE_DESCRIPTION,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High') THEN TRUE
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High') THEN TRUE
        ELSE FALSE
    END AS IN_SFHA
FROM FEMA_NRI;

-- Step B: Aggregate NRI + SVI to parish (county) level
-- NOTE: SVI uses -999 as sentinel for missing data - filter these out
CREATE OR REPLACE TABLE COUNTY_RISK_PROFILE AS
SELECT
    nri.STCOFIPS,
    nri.COUNTY                                          AS PARISH,
    ROUND(AVG(nri.RISK_SCORE), 2)                       AS RISK_SCORE,
    MAX(nri.RISK_RATNG)                                 AS RISK_RATNG,
    ROUND(AVG(nri.EAL_VALT), 2)                         AS EXPECTED_ANNUAL_LOSS,
    ROUND(AVG(nri.EAL_VALB), 2)                         AS EAL_BUILDINGS,
    ROUND(AVG(nri.IFLD_RISKS), 2)                       AS INLAND_FLOOD_RISK_SCORE,
    MAX(nri.IFLD_RISKR)                                 AS INLAND_FLOOD_RISK_RATING,
    ROUND(AVG(nri.CFLD_RISKS), 2)                       AS COASTAL_FLOOD_RISK_SCORE,
    MAX(nri.CFLD_RISKR)                                 AS COASTAL_FLOOD_RISK_RATING,
    ROUND(AVG(nri.HRCN_RISKS), 2)                       AS HURRICANE_RISK_SCORE,
    MAX(nri.HRCN_RISKR)                                 AS HURRICANE_RISK_RATING,
    MODE(fz.FLOOD_ZONE)                                 AS FLOOD_ZONE,
    MODE(fz.ZONE_DESCRIPTION)                           AS ZONE_DESCRIPTION,
    COUNT(CASE WHEN fz.IN_SFHA THEN 1 END) > COUNT(*)/2 AS IN_SFHA,
    ROUND(AVG(CASE WHEN svi.RPL_THEMES >= 0 THEN svi.RPL_THEMES END), 4) AS SVI_OVERALL,
    ROUND(AVG(CASE WHEN svi.RPL_THEME1 >= 0 THEN svi.RPL_THEME1 END), 4) AS SVI_SOCIOECONOMIC,
    ROUND(AVG(CASE WHEN svi.RPL_THEME2 >= 0 THEN svi.RPL_THEME2 END), 4) AS SVI_HOUSEHOLD,
    ROUND(AVG(CASE WHEN svi.RPL_THEME4 >= 0 THEN svi.RPL_THEME4 END), 4) AS SVI_HOUSING_TRANSPORT,
    ROUND(AVG(CASE WHEN svi.EPL_MOBILE >= 0 THEN svi.EPL_MOBILE END), 4) AS MOBILE_HOME_PCT,
    ROUND(AVG(CASE WHEN svi.EPL_NOVEH >= 0 THEN svi.EPL_NOVEH END), 4)  AS NO_VEHICLE_PCT,
    ROUND(AVG(CASE WHEN svi.EPL_AGE65 >= 0 THEN svi.EPL_AGE65 END), 4)  AS ELDERLY_PCT,
    SUM(CASE WHEN svi.E_TOTPOP > 0 THEN svi.E_TOTPOP ELSE 0 END)        AS TRACT_POPULATION
FROM FEMA_NRI nri
LEFT JOIN FLOOD_ZONES fz  ON nri.TRACTFIPS = fz.TRACTFIPS
LEFT JOIN CDC_SVI     svi ON nri.TRACTFIPS = svi.FIPS
GROUP BY nri.STCOFIPS, nri.COUNTY;

SELECT COUNT(*) AS PARISH_COUNT FROM COUNTY_RISK_PROFILE;

-- Step C: Map each H3 hex to its nearest parish using HAVERSINE
-- ~4800 distinct H3 hexes x 64 parishes = fast cross join
CREATE OR REPLACE TABLE H3_PARISH_MAP AS
SELECT H3_INDEX_6, STCOFIPS
FROM (
    SELECT
        h.H3_INDEX_6,
        pc.STCOFIPS,
        ROW_NUMBER() OVER (
            PARTITION BY h.H3_INDEX_6
            ORDER BY HAVERSINE(
                ST_Y(H3_CELL_TO_POINT(h.H3_INDEX_6)),
                ST_X(H3_CELL_TO_POINT(h.H3_INDEX_6)),
                pc.LATITUDE,
                pc.LONGITUDE
            )
        ) AS RN
    FROM (SELECT DISTINCT H3_INDEX_6 FROM BUILDINGS_LA) h
    CROSS JOIN PARISH_CENTROIDS pc
)
WHERE RN = 1;

-- Step D: Build final building-level flood risk table
CREATE OR REPLACE TABLE BUILDING_FLOOD_RISK AS
SELECT
    b.ID                                               AS BUILDING_ID,
    b.NAME                                             AS BUILDING_NAME,
    b.SUBTYPE,
    b.CLASS,
    b.HEIGHT,
    b.NUM_FLOORS,
    b.LONGITUDE,
    b.LATITUDE,
    b.H3_INDEX_8,
    b.H3_INDEX_6,
    cr.STCOFIPS                                        AS TRACTFIPS,
    cr.STCOFIPS,
    cr.PARISH,
    cr.RISK_SCORE                                      AS NRI_RISK_SCORE,
    cr.RISK_RATNG                                      AS NRI_RISK_RATING,
    cr.INLAND_FLOOD_RISK_SCORE,
    cr.INLAND_FLOOD_RISK_RATING,
    cr.COASTAL_FLOOD_RISK_SCORE,
    cr.COASTAL_FLOOD_RISK_RATING,
    cr.HURRICANE_RISK_SCORE,
    cr.HURRICANE_RISK_RATING,
    cr.EXPECTED_ANNUAL_LOSS,
    cr.EAL_BUILDINGS,
    cr.FLOOD_ZONE,
    cr.ZONE_DESCRIPTION,
    cr.IN_SFHA                                         AS IN_SPECIAL_FLOOD_HAZARD_AREA,
    cr.SVI_OVERALL,
    cr.SVI_SOCIOECONOMIC,
    cr.SVI_HOUSEHOLD,
    cr.SVI_HOUSING_TRANSPORT,
    cr.MOBILE_HOME_PCT,
    cr.NO_VEHICLE_PCT,
    cr.ELDERLY_PCT,
    cr.TRACT_POPULATION,
    ROUND(
        COALESCE(cr.RISK_SCORE, 0) * 0.40 +
        COALESCE(cr.SVI_OVERALL, 0) * 100 * 0.30 +
        CASE cr.FLOOD_ZONE
            WHEN 'VE'   THEN 100
            WHEN 'AE'   THEN 80
            WHEN 'X500' THEN 40
            ELSE              10
        END * 0.30
    , 2)                                               AS COMPOSITE_VULNERABILITY_SCORE
FROM BUILDINGS_LA b
JOIN H3_PARISH_MAP hpm ON b.H3_INDEX_6 = hpm.H3_INDEX_6
JOIN COUNTY_RISK_PROFILE cr ON hpm.STCOFIPS = cr.STCOFIPS;

SELECT COUNT(*) AS BUILDINGS_WITH_RISK_DATA FROM BUILDING_FLOOD_RISK;

-- ============================================================
-- STEP 2.3: Create CDC Social Vulnerability Index (SVI) table
-- The SVI ranks census tracts on 16 social factors across 4 themes:
--   Theme 1: Socioeconomic Status
--   Theme 2: Household Characteristics (age, disability)
--   Theme 3: Racial & Ethnic Minority Status
--   Theme 4: Housing Type & Transportation (mobile homes, no vehicle)
-- RPL_THEMES = overall percentile rank (0-1, higher = more vulnerable)
-- ============================================================
CREATE OR REPLACE TABLE CDC_SVI (
    ST          STRING,
    STATE       STRING,
    ST_ABBR     STRING,
    STCNTY      STRING,
    COUNTY      STRING,
    FIPS        STRING,     -- 11-digit FIPS join key (matches TRACTFIPS in NRI)
    LOCATION    STRING,
    AREA_SQMI   FLOAT,
    E_TOTPOP    FLOAT,      -- Total population estimate
    RPL_THEME1  FLOAT,      -- Socioeconomic vulnerability percentile (0-1)
    EPL_POV150  FLOAT,      -- % below 150% poverty line
    EPL_UNEMP   FLOAT,
    EPL_HBURD   FLOAT,      -- Housing cost burden
    EPL_NOHSDP  FLOAT,
    EPL_UNINSUR FLOAT,      -- Uninsured population
    RPL_THEME2  FLOAT,      -- Household characteristics percentile
    EPL_AGE65   FLOAT,      -- Age 65+ (evacuation difficulty)
    EPL_AGE17   FLOAT,
    EPL_DISABL  FLOAT,      -- Disability
    EPL_SNGPNT  FLOAT,
    EPL_LIMENG  FLOAT,
    RPL_THEME3  FLOAT,      -- Racial/ethnic minority percentile
    EPL_MINRTY  FLOAT,
    RPL_THEME4  FLOAT,      -- Housing/transport percentile
    EPL_MUNIT   FLOAT,
    EPL_MOBILE  FLOAT,      -- Mobile homes (structurally vulnerable to flooding)
    EPL_CROWD   FLOAT,
    EPL_NOVEH   FLOAT,      -- No vehicle (evacuation barrier)
    EPL_GROUPQ  FLOAT,
    RPL_THEMES  FLOAT,      -- OVERALL SVI score (0-1) — primary metric
    F_TOTAL     FLOAT
);

-- ⚠️ Upload SVI_2022_LA.csv to @FLOOD_DATA_STAGE/svi/ first!
COPY INTO CDC_SVI
FROM @FLOOD_DATA_STAGE/svi/
FILE_FORMAT          = CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
ON_ERROR             = 'CONTINUE';

-- ✅ Verify: SVI scores of 0.75+ indicate high social vulnerability
SELECT
    COUNT(*)                               AS TRACT_COUNT,
    ROUND(AVG(RPL_THEMES), 3)              AS AVG_SVI,
    COUNT(CASE WHEN RPL_THEMES >= 0.75 THEN 1 END) AS HIGH_VULN_TRACTS,
    COUNT(CASE WHEN RPL_THEMES < 0.25  THEN 1 END) AS LOW_VULN_TRACTS
FROM CDC_SVI;

-- ============================================================
-- STEP 2.4: Derive FEMA flood zone designations from NRI ratings
-- 
-- FEMA flood zone → insurance requirement:
--   VE (Coastal High Hazard)      → Mandatory flood insurance
--   AE (1% annual chance inland)  → Mandatory flood insurance
--   X500 (0.2% annual chance)     → Insurance recommended
--   X (minimal hazard)            → No requirement
-- ============================================================
CREATE OR REPLACE TABLE FLOOD_ZONES AS
SELECT
    TRACTFIPS,
    COUNTY    AS PARISH,
    STCOFIPS,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High') THEN 'VE'
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High') THEN 'AE'
        WHEN IFLD_RISKR  = 'Relatively Moderate'           THEN 'X500'
        ELSE 'X'
    END AS FLOOD_ZONE,
    CASE
        WHEN CFLD_RISKR IN ('Very High', 'Relatively High')
            THEN 'Coastal High Hazard — mandatory flood insurance'
        WHEN IFLD_RISKR IN ('Very High', 'Relatively High')
            THEN '1% Annual Chance Inland Flood — mandatory flood insurance'
        WHEN IFLD_RISKR  = 'Relatively Moderate'
            THEN '0.2% Annual Chance Flood — insurance recommended'
        ELSE 'Minimal Flood Hazard'
    END AS ZONE_DESCRIPTION,
    -- SFHA = Special Flood Hazard Area (AE or VE zones — mandatory insurance)
    (CFLD_RISKR IN ('Very High', 'Relatively High')
     OR IFLD_RISKR IN ('Very High', 'Relatively High')) AS IN_SFHA,
    IFLD_RISKS AS INLAND_FLOOD_RISK_SCORE,
    CFLD_RISKS AS COASTAL_FLOOD_RISK_SCORE,
    HRCN_RISKS AS HURRICANE_RISK_SCORE
FROM FEMA_NRI;

-- Distribution of flood zones
SELECT
    FLOOD_ZONE,
    ZONE_DESCRIPTION,
    COUNT(*) AS TRACTS,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS PCT_OF_TRACTS
FROM FLOOD_ZONES
GROUP BY 1, 2
ORDER BY TRACTS DESC;


-- ############################################################
-- Lab 3: Geospatial Flood Risk Analysis
-- ############################################################

-- ============================================================
-- STEP 3.1: Create the master building-level flood risk table
-- Joins: Buildings → H3 Parish Map → County Risk Profile
-- Join strategy: buildings.H3_INDEX_6 → parish map → risk profile
-- ============================================================
CREATE OR REPLACE TABLE BUILDING_FLOOD_RISK AS
SELECT
    b.ID                                               AS BUILDING_ID,
    b.NAME                                             AS BUILDING_NAME,
    b.SUBTYPE,
    b.CLASS,
    b.HEIGHT,
    b.NUM_FLOORS,
    b.LONGITUDE,
    b.LATITUDE,
    b.H3_INDEX_8,
    b.H3_INDEX_6,
    cr.STCOFIPS                                        AS TRACTFIPS,
    cr.STCOFIPS,
    cr.PARISH,
    cr.RISK_SCORE                                      AS NRI_RISK_SCORE,
    cr.RISK_RATNG                                      AS NRI_RISK_RATING,
    cr.INLAND_FLOOD_RISK_SCORE,
    cr.INLAND_FLOOD_RISK_RATING,
    cr.COASTAL_FLOOD_RISK_SCORE,
    cr.COASTAL_FLOOD_RISK_RATING,
    cr.HURRICANE_RISK_SCORE,
    cr.HURRICANE_RISK_RATING,
    cr.EXPECTED_ANNUAL_LOSS,
    cr.EAL_BUILDINGS,
    cr.FLOOD_ZONE,
    cr.ZONE_DESCRIPTION,
    cr.IN_SFHA                                         AS IN_SPECIAL_FLOOD_HAZARD_AREA,
    cr.SVI_OVERALL,
    cr.SVI_SOCIOECONOMIC,
    cr.SVI_HOUSEHOLD,
    cr.SVI_HOUSING_TRANSPORT,
    cr.MOBILE_HOME_PCT,
    cr.NO_VEHICLE_PCT,
    cr.ELDERLY_PCT,
    cr.TRACT_POPULATION,
    ROUND(
        COALESCE(cr.RISK_SCORE, 0) * 0.40 +
        COALESCE(cr.SVI_OVERALL, 0) * 100 * 0.30 +
        CASE cr.FLOOD_ZONE
            WHEN 'VE'   THEN 100
            WHEN 'AE'   THEN 80
            WHEN 'X500' THEN 40
            ELSE              10
        END * 0.30
    , 2)                                               AS COMPOSITE_VULNERABILITY_SCORE
FROM BUILDINGS_LA b
JOIN H3_PARISH_MAP hpm ON b.H3_INDEX_6 = hpm.H3_INDEX_6
JOIN COUNTY_RISK_PROFILE cr ON hpm.STCOFIPS = cr.STCOFIPS;

SELECT COUNT(*) AS BUILDINGS_WITH_RISK_DATA FROM BUILDING_FLOOD_RISK;

-- ============================================================
-- STEP 3.2: Parish-level flood risk summary table
-- NOTE: EXPECTED_ANNUAL_LOSS and EAL_BUILDINGS are parish-level
-- values (same for every building in a parish), so use MAX not SUM
-- NOTE: FLOOD_ZONE is parish-level (MODE of tracts). Use tract-level
-- FLOOD_ZONES table for accurate SFHA percentages.
-- ============================================================
CREATE OR REPLACE TABLE PARISH_FLOOD_SUMMARY AS
WITH parish_sfha AS (
    SELECT
        cr.STCOFIPS,
        ROUND(COUNT(CASE WHEN fz.IN_SFHA THEN 1 END) * 100.0 / COUNT(*), 1) AS PCT_IN_SFHA
    FROM FEMA_NRI nri
    JOIN FLOOD_ZONES fz ON nri.TRACTFIPS = fz.TRACTFIPS
    JOIN COUNTY_RISK_PROFILE cr ON nri.STCOFIPS = cr.STCOFIPS
    GROUP BY cr.STCOFIPS
)
SELECT
    b.PARISH,
    COUNT(*)                                                  AS TOTAL_BUILDINGS,
    ROUND(COUNT(*) * MAX(ps.PCT_IN_SFHA) / 100.0, 0)          AS BUILDINGS_IN_SFHA,
    MAX(ps.PCT_IN_SFHA)                                       AS PCT_IN_SFHA,
    ROUND(AVG(b.NRI_RISK_SCORE), 2)                           AS AVG_NRI_RISK_SCORE,
    ROUND(AVG(b.SVI_OVERALL), 3)                              AS AVG_SVI_SCORE,
    ROUND(AVG(b.COMPOSITE_VULNERABILITY_SCORE), 2)            AS AVG_COMPOSITE_SCORE,
    ROUND(MAX(b.EXPECTED_ANNUAL_LOSS), 0)                     AS TOTAL_EXPECTED_ANNUAL_LOSS,
    ROUND(MAX(b.EAL_BUILDINGS), 0)                            AS BUILDING_EXPECTED_ANNUAL_LOSS,
    COUNT(CASE WHEN b.FLOOD_ZONE = 'VE'   THEN 1 END)         AS BUILDINGS_COASTAL_ZONE,
    COUNT(CASE WHEN b.FLOOD_ZONE = 'AE'   THEN 1 END)         AS BUILDINGS_RIVERINE_ZONE,
    COUNT(CASE WHEN b.FLOOD_ZONE = 'X500' THEN 1 END)         AS BUILDINGS_MODERATE_ZONE,
    COUNT(CASE WHEN b.SVI_OVERALL >= 0.75  THEN 1 END)        AS HIGH_SOCIAL_VULN_BUILDINGS
FROM BUILDING_FLOOD_RISK b
JOIN parish_sfha ps ON b.STCOFIPS = ps.STCOFIPS
WHERE b.PARISH IS NOT NULL
GROUP BY b.PARISH
ORDER BY AVG_COMPOSITE_SCORE DESC;

SELECT
    PARISH, TOTAL_BUILDINGS, BUILDINGS_IN_SFHA, PCT_IN_SFHA,
    AVG_NRI_RISK_SCORE, AVG_SVI_SCORE, AVG_COMPOSITE_SCORE,
    TO_CHAR(TOTAL_EXPECTED_ANNUAL_LOSS, '$999,999,999') AS ANNUAL_LOSS
FROM PARISH_FLOOD_SUMMARY
ORDER BY PCT_IN_SFHA DESC
LIMIT 10;

-- ============================================================
-- STEP 3.3: H3 hexagonal risk heatmap table (for visualization)
-- Resolution 6 hexagons (~36km across) for readable map tiles
-- ============================================================
CREATE OR REPLACE TABLE H3_FLOOD_RISK_MAP AS
SELECT
    H3_INDEX_6,
    ST_ASWKT(H3_CELL_TO_BOUNDARY(H3_INDEX_6))          AS HEX_BOUNDARY_WKT,
    COUNT(*)                                      AS BUILDING_COUNT,
    COUNT(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 END)
                                                  AS BUILDINGS_AT_RISK,
    ROUND(AVG(COMPOSITE_VULNERABILITY_SCORE), 2)  AS AVG_VULNERABILITY,
    ROUND(AVG(NRI_RISK_SCORE), 2)                 AS AVG_NRI_SCORE,
    ROUND(AVG(SVI_OVERALL), 3)                    AS AVG_SVI,
    ROUND(SUM(EXPECTED_ANNUAL_LOSS), 0)           AS TOTAL_EAL,
    MAX(PARISH)                                   AS PRIMARY_PARISH
FROM BUILDING_FLOOD_RISK
GROUP BY H3_INDEX_6
HAVING COUNT(*) >= 10
ORDER BY AVG_VULNERABILITY DESC;

-- Top 10 highest-risk hexagons
SELECT
    H3_INDEX_6, PRIMARY_PARISH, BUILDING_COUNT,
    BUILDINGS_AT_RISK, AVG_VULNERABILITY, AVG_SVI,
    TO_CHAR(TOTAL_EAL, '$999,999,999') AS TOTAL_EAL
FROM H3_FLOOD_RISK_MAP
LIMIT 10;

-- ============================================================
-- STEP 3.4: Critical infrastructure at flood risk
-- Hospitals, schools, fire stations in flood zones = high priority
-- ============================================================
SELECT
    CLASS,
    COUNT(*)                                                  AS TOTAL,
    COUNT(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 END)  AS IN_SFHA,
    ROUND(
        COUNT(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 1
    )                                                         AS PCT_IN_SFHA,
    ROUND(AVG(COMPOSITE_VULNERABILITY_SCORE), 2)              AS AVG_VULN_SCORE,
    ROUND(AVG(SVI_OVERALL), 3)                                AS AVG_COMMUNITY_SVI
FROM BUILDING_FLOOD_RISK
WHERE CLASS IN (
    'hospital', 'clinic', 'doctors',
    'school', 'kindergarten', 'university',
    'fire_station', 'police',
    'government', 'courthouse',
    'church', 'nursing_home', 'community_centre', 'social_facility'
)
GROUP BY CLASS
ORDER BY PCT_IN_SFHA DESC NULLS LAST;


-- ############################################################
-- Lab 4: Dynamic Tables — Automated Risk Scoring Pipeline
-- ############################################################

-- ============================================================
-- STEP 4.1: Dynamic Table for automated flood risk alerts
-- Refreshes hourly; escalates tracts by risk level
-- ============================================================
CREATE OR REPLACE DYNAMIC TABLE FLOOD_RISK_ALERTS
  TARGET_LAG = '1 hour'
  WAREHOUSE  = FLOOD_WH
  COMMENT    = 'Auto-refreshing tract-level risk alerts for Emergency Management'
AS
SELECT
    PARISH,
    TRACTFIPS,
    COUNT(*)                                              AS BUILDINGS_AT_RISK,
    ROUND(AVG(COMPOSITE_VULNERABILITY_SCORE), 2)          AS AVG_VULNERABILITY_SCORE,
    ROUND(SUM(EAL_BUILDINGS), 0)                          AS TOTAL_BUILDING_EAL,
    ROUND(AVG(SVI_OVERALL), 3)                            AS AVG_SVI_SCORE,
    COUNT(CASE WHEN CLASS IN ('hospital','clinic','fire_station','school') THEN 1 END)
                                                          AS CRITICAL_INFRA_COUNT,
    CASE
        WHEN AVG(COMPOSITE_VULNERABILITY_SCORE) >= 70 THEN 'CRITICAL'
        WHEN AVG(COMPOSITE_VULNERABILITY_SCORE) >= 50 THEN 'HIGH'
        WHEN AVG(COMPOSITE_VULNERABILITY_SCORE) >= 30 THEN 'MODERATE'
        ELSE 'LOW'
    END                                                   AS RISK_LEVEL,
    CURRENT_TIMESTAMP()                                   AS LAST_CALCULATED
FROM BUILDING_FLOOD_RISK
WHERE IN_SPECIAL_FLOOD_HAZARD_AREA = TRUE
GROUP BY PARISH, TRACTFIPS;

-- Check alert distribution
SELECT RISK_LEVEL, COUNT(*) AS TRACT_COUNT
FROM FLOOD_RISK_ALERTS
GROUP BY RISK_LEVEL
ORDER BY TRACT_COUNT DESC;


-- ############################################################
-- Lab 5: Cortex AI — Policy Document Intelligence
-- ############################################################

-- ============================================================
-- STEP 5.1: Create stage for policy PDFs and upload documents
-- ============================================================
CREATE OR REPLACE STAGE FLOOD_POLICY_DOCS
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = 'Louisiana flood policy PDFs for Cortex AI analysis';

COPY FILES INTO @FLOOD_POLICY_DOCS/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('data/policy_docs/Louisiana_Hazard_Mitigation_Plan_2024_Intro.pdf',
       'data/policy_docs/Louisiana_Hazard_Mitigation_Plan_2024_Strategies.pdf');

ALTER STAGE FLOOD_POLICY_DOCS REFRESH;

SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED
FROM DIRECTORY(@FLOOD_POLICY_DOCS)
ORDER BY LAST_MODIFIED DESC;

-- ============================================================
-- STEP 5.2: Parse PDFs with Cortex PARSE_DOCUMENT
-- LAYOUT mode preserves headings, paragraphs, and tables
-- ⏳ ~30-60 seconds per PDF
-- ============================================================
CREATE OR REPLACE TABLE PARSED_POLICY_DOCS AS
SELECT
    RELATIVE_PATH                       AS FILE_NAME,
    SIZE                                AS FILE_SIZE_BYTES,
    SNOWFLAKE.CORTEX.PARSE_DOCUMENT(
        @FLOOD_POLICY_DOCS,
        RELATIVE_PATH
        --,        {'mode': 'LAYOUT'}
    )                                   AS PARSED_CONTENT,
    PARSED_CONTENT:content::STRING      AS FULL_TEXT,
    CURRENT_TIMESTAMP()                 AS PARSED_AT
FROM DIRECTORY(@FLOOD_POLICY_DOCS)
WHERE RELATIVE_PATH LIKE '%.pdf';

-- Preview extracted text
SELECT
    FILE_NAME,
    FILE_SIZE_BYTES,
    LENGTH(FULL_TEXT) AS TEXT_CHARS,
    LEFT(FULL_TEXT, 500) AS TEXT_PREVIEW
FROM PARSED_POLICY_DOCS;

-- ============================================================
-- STEP 5.3: Chunk documents into searchable segments
-- Smaller chunks (200-800 chars) produce better vector search results
-- ============================================================
CREATE OR REPLACE TABLE POLICY_DOC_CHUNKS AS
SELECT
    FILE_NAME,
    chunk.INDEX              AS CHUNK_INDEX,
    TRIM(chunk.VALUE::STRING) AS CHUNK_TEXT,
    LENGTH(TRIM(chunk.VALUE::STRING)) AS CHUNK_LENGTH
FROM PARSED_POLICY_DOCS,
    LATERAL FLATTEN(INPUT => SPLIT(FULL_TEXT, '\n\n')) AS chunk
WHERE LENGTH(TRIM(chunk.VALUE::STRING)) > 80;

SELECT FILE_NAME, COUNT(*) AS CHUNKS, SUM(CHUNK_LENGTH) AS TOTAL_CHARS
FROM POLICY_DOC_CHUNKS
GROUP BY FILE_NAME;

-- ============================================================
-- STEP 5.4: Create Cortex Search service
-- Builds a semantic vector index over all policy document chunks
-- Enables hybrid keyword + semantic search
-- ============================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE FLOOD_POLICY_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES FILE_NAME, CHUNK_INDEX
  WAREHOUSE  = FLOOD_WH
  TARGET_LAG = '1 day'
AS (
    SELECT CHUNK_TEXT, FILE_NAME, CHUNK_INDEX
    FROM POLICY_DOC_CHUNKS
);

-- Test semantic search — try different questions!
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'FLOOD_ANALYTICS.FLOOD.FLOOD_POLICY_SEARCH',
        '{
            "query": "What flood mitigation projects are planned for coastal Louisiana parishes?",
            "columns": ["CHUNK_TEXT", "FILE_NAME"],
            "limit": 3
        }'
    )
) AS SEARCH_RESULTS;

-- ============================================================
-- STEP 5.5: Cortex AI executive summary
-- Combines our structured risk data with LLM reasoning
-- ============================================================
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'llama3.1-70b',
    CONCAT(
        'You are a senior flood risk analyst for Louisiana Emergency Management. ',
        'Based on the parish-level flood risk data below, write a 3-paragraph executive summary covering:\n',
        '1. Which parishes face the highest combined flood and social vulnerability risk and why\n',
        '2. The relationship between poverty (SVI score) and flood exposure\n',
        '3. Top 3 actionable recommendations for emergency planners\n\n',
        'PARISH RISK DATA (top 15 by composite vulnerability):\n',
        (
            SELECT LISTAGG(
                PARISH || ': composite=' || AVG_COMPOSITE_SCORE ||
                ', SVI=' || AVG_SVI_SCORE ||
                ', ' || PCT_IN_SFHA || '% bldgs in flood zone' ||
                ', annual_loss=$' || TOTAL_EXPECTED_ANNUAL_LOSS,
                '\n'
            )
            FROM (
                SELECT * FROM PARISH_FLOOD_SUMMARY
                ORDER BY AVG_COMPOSITE_SCORE DESC
                LIMIT 15
            )
        )
    )
) AS EXECUTIVE_SUMMARY;


-- ############################################################
-- Lab 6: Verify Tables (Cortex Analyst runs inside your agent)
-- ############################################################

-- ============================================================
-- STEP 6.1: Verify all tables exist before building the semantic view
-- ============================================================
SELECT
    TABLE_NAME,
    TO_CHAR(ROW_COUNT, '999,999,999')           AS ROW_COUNT_FMT,
    ROUND(BYTES / 1024.0 / 1024.0, 1) || ' MB' AS SIZE
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'FLOOD'
  AND TABLE_TYPE   = 'BASE TABLE'
ORDER BY ROW_COUNT DESC NULLS LAST;


-- ############################################################
-- Lab 7: Streamlit Dashboard Verification
-- ############################################################

-- ============================================================
-- STEP 7.1: Final verification — all objects ready for dashboard
-- ============================================================
SELECT 'BUILDINGS_LA'         AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM BUILDINGS_LA
UNION ALL
SELECT 'FEMA_NRI',              COUNT(*) FROM FEMA_NRI
UNION ALL
SELECT 'CDC_SVI',               COUNT(*) FROM CDC_SVI
UNION ALL
SELECT 'FLOOD_ZONES',           COUNT(*) FROM FLOOD_ZONES
UNION ALL
SELECT 'BUILDING_FLOOD_RISK',   COUNT(*) FROM BUILDING_FLOOD_RISK
UNION ALL
SELECT 'PARISH_FLOOD_SUMMARY',  COUNT(*) FROM PARISH_FLOOD_SUMMARY
UNION ALL
SELECT 'H3_FLOOD_RISK_MAP',     COUNT(*) FROM H3_FLOOD_RISK_MAP
UNION ALL
SELECT 'FLOOD_RISK_ALERTS',     COUNT(*) FROM FLOOD_RISK_ALERTS
ORDER BY ROW_COUNT DESC;


-- ############################################################
-- Lab 7A: Deploy Streamlit Flood Dashboard
-- ############################################################

CREATE OR REPLACE STAGE FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

COPY FILES INTO @FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE/
FROM 'snow://workspace/USER$.PUBLIC."flood-resilience"/versions/live/'
FILES=('streamlit/flood_dashboard.py', 'streamlit/environment.yml', 'streamlit/.streamlit/config.toml');

CREATE OR REPLACE STREAMLIT FLOOD_ANALYTICS.FLOOD.FLOOD_VULNERABILITY_DASHBOARD
  ROOT_LOCATION  = '@FLOOD_ANALYTICS.FLOOD.STREAMLIT_STAGE/streamlit'
  MAIN_FILE      = 'flood_dashboard.py'
  QUERY_WAREHOUSE = FLOOD_WH
  TITLE          = 'Flood Vulnerability Dashboard';

--REPLACE THE ROLE WITH YOUR CURRENT USER ROLE 

GRANT USAGE ON DATABASE FLOOD_ANALYTICS TO ROLE ATTENDEE_ROLE;
GRANT USAGE ON SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT USAGE ON SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT CREATE SEMANTIC VIEW ON SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT CREATE SEMANTIC VIEW ON SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;

-- ============================================================
-- PRIVILEGES FOR: Create Agent
-- ============================================================
GRANT CREATE AGENT ON SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT CREATE AGENT ON SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;

-- ============================================================
-- PRIVILEGES FOR: Use Semantic Views (query via Cortex Analyst)
-- ============================================================
GRANT SELECT ON ALL SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON ALL SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT REFERENCES ON ALL SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT REFERENCES ON ALL SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA FLOOD_ANALYTICS.PUBLIC TO ROLE ATTENDEE_ROLE;

-- ============================================================
-- PRIVILEGES FOR: Agent tools (warehouse, stage, search, agent)
-- ============================================================
GRANT USAGE ON WAREHOUSE FLOOD_WH TO ROLE ATTENDEE_ROLE;
GRANT READ ON STAGE FLOOD_ANALYTICS.FLOOD.FLOOD_DATA_STAGE TO ROLE ATTENDEE_ROLE;
GRANT USAGE ON CORTEX SEARCH SERVICE FLOOD_ANALYTICS.FLOOD.FLOOD_POLICY_SEARCH TO ROLE ATTENDEE_ROLE;
GRANT USAGE ON FUTURE AGENTS IN SCHEMA FLOOD_ANALYTICS.FLOOD TO ROLE ATTENDEE_ROLE;


-- ############################################################
-- Lab 7B: Build Your Cortex Agent with Semantic Studio
-- ############################################################


-- ############################################################
-- Lab 7B (Fallback): Deploy Agent via SQL
-- ############################################################


-- ############################################################
-- Lab 7C (Fallback): Register Agent in Snowflake CoWork
-- ############################################################


-- ############################################################
-- Lab 8: Cleanup (Optional)
-- ############################################################

-- ============================================================
-- STEP 8.1: Cleanup — removes all lab objects
-- ⚠️ UNCOMMENT ONLY WHEN DONE WITH THE ENTIRE LAB
-- ============================================================

-- DROP DATABASE IF EXISTS FLOOD_ANALYTICS;
-- DROP WAREHOUSE IF EXISTS FLOOD_WH;

SELECT 'Cleanup skipped. Uncomment lines above when ready.' AS STATUS;


-- ############################################################
-- FALLBACK: create semantic view + agent, register in CoWork
-- Use the CoCo prompts in notebook Lab 7B first.
-- Only if that fails: select everything below and uncomment
-- (Cmd+/ or Ctrl+/), then run top to bottom.
-- ############################################################

-- -- ============================================================
-- -- STEP 7B: Create Cortex Agent (Structured + Unstructured)
-- -- Combines Cortex Analyst (SQL) + Cortex Search (policy docs)
-- -- ============================================================
-- -- Step 1: Create the semantic view from the repo's YAML model
-- CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('FLOOD_ANALYTICS.FLOOD', $$
-- name: FLOOD_RISK_SEMANTIC_VIEW
-- description: >
--   Louisiana flood vulnerability analysis model.
--   Combines Overture Maps building footprints with FEMA National Risk Index,
--   CDC Social Vulnerability Index, and derived flood zone designations.
-- 
-- tables:
--   - name: BUILDING_FLOOD_RISK
--     base_table:
--       database: FLOOD_ANALYTICS
--       schema: FLOOD
--       table: BUILDING_FLOOD_RISK
--     description: >
--       Individual buildings in Louisiana with flood risk scores, FEMA flood zone designations,
--       and CDC social vulnerability data. Each row is one building.
--     dimensions:
--       - name: PARISH
--         expr: PARISH
--         description: Louisiana parish name (equivalent to county in other states)
--         data_type: TEXT
--         unique: false
--       - name: FLOOD_ZONE
--         expr: FLOOD_ZONE
--         description: >
--           FEMA flood zone designation.
--           VE = Coastal High Hazard (mandatory insurance),
--           AE = 1% annual chance inland flood (mandatory insurance),
--           X500 = 0.2% annual chance (moderate risk),
--           X = minimal flood hazard.
--         data_type: TEXT
--       - name: IN_SPECIAL_FLOOD_HAZARD_AREA
--         expr: IN_SPECIAL_FLOOD_HAZARD_AREA
--         description: >
--           TRUE if building is in a FEMA Special Flood Hazard Area (Zone AE or VE).
--           Buildings here require mandatory flood insurance if mortgaged.
--         data_type: BOOLEAN
--       - name: CLASS
--         expr: CLASS
--         description: >
--           Building type from Overture Maps (e.g. residential, commercial, hospital,
--           school, fire_station, church, nursing_home, government).
--         data_type: TEXT
--       - name: NRI_RISK_RATING
--         expr: NRI_RISK_RATING
--         description: >
--           FEMA NRI overall risk rating for the census tract:
--           Very High | Relatively High | Relatively Moderate | Relatively Low | Very Low
--         data_type: TEXT
--       - name: INLAND_FLOOD_RISK_RATING
--         expr: INLAND_FLOOD_RISK_RATING
--         description: FEMA NRI inland/riverine flooding risk rating for the tract
--         data_type: TEXT
--       - name: COASTAL_FLOOD_RISK_RATING
--         expr: COASTAL_FLOOD_RISK_RATING
--         description: FEMA NRI coastal flooding risk rating for the tract
--         data_type: TEXT
--       - name: TRACTFIPS
--         expr: TRACTFIPS
--         description: 11-digit census tract FIPS code
--         data_type: TEXT
--     measures:
--       - name: BUILDING_COUNT
--         expr: COUNT(BUILDING_ID)
--         description: Total number of buildings
--         data_type: NUMBER
--         default_aggregation: count
--       - name: COMPOSITE_VULNERABILITY_SCORE
--         expr: AVG(COMPOSITE_VULNERABILITY_SCORE)
--         description: >
--           Average composite vulnerability score (0-100) combining NRI risk (40%),
--           CDC social vulnerability (30%), and flood zone exposure (30%).
--           Higher score = more vulnerable.
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: NRI_RISK_SCORE
--         expr: AVG(NRI_RISK_SCORE)
--         description: Average FEMA NRI overall risk score for the tract (0-100)
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: SVI_OVERALL
--         expr: AVG(SVI_OVERALL)
--         description: >
--           Average CDC Social Vulnerability Index score (0-1).
--           0 = least vulnerable, 1 = most vulnerable.
--           Accounts for poverty, disability, age, mobile homes, no vehicle access.
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: EXPECTED_ANNUAL_LOSS
--         expr: SUM(EXPECTED_ANNUAL_LOSS)
--         description: Total expected annual dollar loss from all natural hazards in the census tract
--         data_type: NUMBER
--         default_aggregation: sum
--       - name: EAL_BUILDINGS
--         expr: SUM(EAL_BUILDINGS)
--         description: Expected annual dollar loss for buildings specifically
--         data_type: NUMBER
--         default_aggregation: sum
--       - name: BUILDINGS_IN_SFHA
--         expr: SUM(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 ELSE 0 END)
--         description: Number of buildings in FEMA Special Flood Hazard Areas
--         data_type: NUMBER
--         default_aggregation: sum
--       - name: PCT_IN_SFHA
--         expr: SUM(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 ELSE 0 END) * 100.0 / COUNT(*)
--         description: Percentage of buildings located in Special Flood Hazard Areas
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: MOBILE_HOME_PCT
--         expr: AVG(MOBILE_HOME_PCT)
--         description: >
--           Average CDC SVI mobile home percentile rank.
--           Mobile homes are structurally vulnerable to flooding.
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: NO_VEHICLE_PCT
--         expr: AVG(NO_VEHICLE_PCT)
--         description: >
--           Average CDC SVI no-vehicle percentile rank.
--           Higher = more residents without vehicle access (evacuation barrier).
--         data_type: NUMBER
--         default_aggregation: avg
-- 
--   - name: PARISH_FLOOD_SUMMARY
--     base_table:
--       database: FLOOD_ANALYTICS
--       schema: FLOOD
--       table: PARISH_FLOOD_SUMMARY
--     description: >
--       Parish-level aggregated flood risk statistics.
--       One row per Louisiana parish (64 total).
--     dimensions:
--       - name: PARISH
--         expr: PARISH
--         description: Louisiana parish name
--         data_type: TEXT
--         unique: true
--     measures:
--       - name: TOTAL_BUILDINGS
--         expr: SUM(TOTAL_BUILDINGS)
--         description: Total number of buildings in the parish
--         data_type: NUMBER
--         default_aggregation: sum
--       - name: BUILDINGS_IN_SFHA
--         expr: SUM(BUILDINGS_IN_SFHA)
--         description: Number of buildings in FEMA Special Flood Hazard Areas
--         data_type: NUMBER
--         default_aggregation: sum
--       - name: PCT_IN_SFHA
--         expr: AVG(PCT_IN_SFHA)
--         description: Percentage of buildings located in flood zones
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: AVG_COMPOSITE_SCORE
--         expr: AVG(AVG_COMPOSITE_SCORE)
--         description: Average composite vulnerability score for the parish (0-100)
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: AVG_NRI_RISK_SCORE
--         expr: AVG(AVG_NRI_RISK_SCORE)
--         description: Average FEMA NRI risk score for the parish
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: AVG_SVI_SCORE
--         expr: AVG(AVG_SVI_SCORE)
--         description: Average CDC Social Vulnerability Index score for the parish (0-1)
--         data_type: NUMBER
--         default_aggregation: avg
--       - name: TOTAL_EXPECTED_ANNUAL_LOSS
--         expr: SUM(TOTAL_EXPECTED_ANNUAL_LOSS)
--         description: Total expected annual dollar loss from all natural hazards
--         data_type: NUMBER
--         default_aggregation: sum
--       - name: BUILDING_EXPECTED_ANNUAL_LOSS
--         expr: SUM(BUILDING_EXPECTED_ANNUAL_LOSS)
--         description: Expected annual dollar loss for buildings specifically
--         data_type: NUMBER
--         default_aggregation: sum
-- 
-- verified_queries:
--   - name: most_vulnerable_parishes
--     question: "Which parishes have the highest composite flood vulnerability score?"
--     use_as_onboarding_question: true
--     sql: |
--       SELECT PARISH, AVG_COMPOSITE_SCORE, AVG_NRI_RISK_SCORE, AVG_SVI_SCORE,
--              PCT_IN_SFHA, TOTAL_EXPECTED_ANNUAL_LOSS
--       FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY
--       ORDER BY AVG_COMPOSITE_SCORE DESC
--       LIMIT 10
-- 
--   - name: buildings_in_flood_zones
--     question: "How many buildings are in FEMA Special Flood Hazard Areas by parish?"
--     use_as_onboarding_question: true
--     sql: |
--       SELECT PARISH, BUILDINGS_IN_SFHA, TOTAL_BUILDINGS, PCT_IN_SFHA
--       FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY
--       ORDER BY BUILDINGS_IN_SFHA DESC
-- 
--   - name: critical_infra_at_risk
--     question: "How many hospitals and schools are in flood zones?"
--     use_as_onboarding_question: true
--     sql: |
--       SELECT CLASS, COUNT(*) AS TOTAL,
--              SUM(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 ELSE 0 END) AS IN_SFHA,
--              ROUND(SUM(CASE WHEN IN_SPECIAL_FLOOD_HAZARD_AREA THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS PCT_IN_SFHA
--       FROM FLOOD_ANALYTICS.FLOOD.BUILDING_FLOOD_RISK
--       WHERE CLASS IN ('hospital','clinic','school','fire_station','nursing_home')
--       GROUP BY CLASS
--       ORDER BY PCT_IN_SFHA DESC
-- 
--   - name: high_svi_flood_overlap
--     question: "Which parishes have both high social vulnerability and high flood exposure?"
--     use_as_onboarding_question: true
--     sql: |
--       SELECT PARISH, AVG_SVI_SCORE, PCT_IN_SFHA, AVG_COMPOSITE_SCORE
--       FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY
--       WHERE AVG_SVI_SCORE >= 0.7
--         AND PCT_IN_SFHA   >= 30
--       ORDER BY AVG_COMPOSITE_SCORE DESC
-- 
--   - name: total_annual_loss
--     question: "What is the total expected annual loss statewide?"
--     use_as_onboarding_question: true
--     sql: |
--       SELECT
--         SUM(TOTAL_EXPECTED_ANNUAL_LOSS)      AS STATEWIDE_TOTAL_EAL,
--         SUM(BUILDING_EXPECTED_ANNUAL_LOSS)   AS STATEWIDE_BUILDING_EAL,
--         COUNT(*)                             AS PARISH_COUNT
--       FROM FLOOD_ANALYTICS.FLOOD.PARISH_FLOOD_SUMMARY
-- $$);
-- 
-- -- Step 2: Create the agent on top of the semantic view
-- CREATE OR REPLACE AGENT FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_AGENT
-- FROM SPECIFICATION $$
-- {
--   "models": {
--     "orchestration": "auto"
--   },
--   "orchestration": {
--     "budget": {
--       "seconds": 900,
--       "tokens": 400000
--     }
--   },
--   "instructions": {
--     "orchestration": "You are a Louisiana flood risk analyst. You have access to two tools: (1) query_flood_data for structured analysis of 3.5M buildings, 64 parishes, FEMA risk scores, CDC social vulnerability, and flood zone designations; (2) search_policy_docs for finding information from Louisiana's 2024 State Hazard Mitigation Plan including mitigation strategies, levee projects, historical disaster impacts, and policy recommendations. When a user asks about risk statistics, building counts, parish comparisons, or vulnerability scores, use query_flood_data. When a user asks about mitigation plans, policy strategies, historical events, levee projects, or government programs, use search_policy_docs. For comprehensive answers, use both tools.",
--     "response": "Provide concise, data-driven answers. When presenting numbers, format them clearly. When referencing policy documents, cite the source document name. If combining structured data with policy context, clearly distinguish between quantitative findings and policy recommendations.",
--     "sample_questions": [
--       {"question": "Which parish has the highest percentage of buildings in flood zones?"},
--       {"question": "What is the total expected annual loss for the top 5 most vulnerable parishes?"},
--       {"question": "How many hospitals and schools are in FEMA Special Flood Hazard Areas?"},
--       {"question": "Which parishes have both high social vulnerability and high flood exposure?"},
--       {"question": "What mitigation strategies does the 2024 Hazard Mitigation Plan recommend?"},
--       {"question": "What happened to Louisiana during Hurricane Katrina and Ida?"},
--       {"question": "What levee projects are planned or underway in Louisiana?"},
--       {"question": "What federal funding programs support flood mitigation in Louisiana?"},
--       {"question": "What is the statewide expected annual loss from flooding?"},
--       {"question": "Which parishes have the most critical infrastructure in coastal flood zones?"}
--     ]
--   },
--   "tools": [
--     {
--       "tool_spec": {
--         "type": "cortex_analyst_text_to_sql",
--         "name": "query_flood_data",
--         "description": "Query structured flood risk data for Louisiana. Contains 3.56M building footprints with flood zone designations (VE=coastal high hazard, AE=inland flood, X500=moderate, X=minimal), FEMA National Risk Index scores (0-100), CDC Social Vulnerability Index (0-1), composite vulnerability scores, expected annual losses in dollars, and parish-level summaries. Use for questions about building counts in flood zones, parish risk rankings, social vulnerability, expected annual losses, critical infrastructure at risk."
--       }
--     },
--     {
--       "tool_spec": {
--         "type": "cortex_search",
--         "name": "search_policy_docs",
--         "description": "Search Louisiana 2024 State Hazard Mitigation Plan for policy information, mitigation strategies, historical flood events, levee and infrastructure projects, federal and state funding programs, and disaster preparedness recommendations. Use for questions about what mitigation actions are planned, what happened during Hurricane Katrina or Ida, what flood protection infrastructure exists, what government programs fund flood mitigation."
--       }
--     }
--   ],
--   "tool_resources": {
--     "query_flood_data": {
--       "execution_environment": {
--         "query_timeout": 299,
--         "type": "warehouse",
--         "warehouse": "FLOOD_WH"
--       },
--       "semantic_view": "FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_SEMANTIC_VIEW"
--     },
--     "search_policy_docs": {
--       "search_service": "FLOOD_ANALYTICS.FLOOD.FLOOD_POLICY_SEARCH"
--     }
--   }
-- }
-- $$;
-- 
-- SHOW AGENTS IN SCHEMA FLOOD_ANALYTICS.FLOOD;
-- 
-- GRANT USAGE ON AGENT FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_AGENT TO ROLE ATTENDEE_ROLE;

-- CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;
-- 
-- ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
--   ADD AGENT FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_AGENT;
-- 
-- SELECT 'Agent registered in Snowflake Intelligence' AS STATUS;
