# US Flood Vulnerability Solution — Snowflake World Tour Chicago 2026 HOL

An end-to-end flood vulnerability analysis platform built on Snowflake, combining open geospatial data from Overture Maps, FEMA risk indices, and CDC social vulnerability data to identify at-risk buildings across Louisiana.

## What You Will Build

- A geospatial pipeline identifying **3.56M Louisiana buildings** within FEMA flood zones
- A **social vulnerability overlay** linking flood exposure to community resilience
- **Cortex AI document intelligence** to parse Louisiana's State Hazard Mitigation Plan
- A **Cortex Agent** that answers questions using both structured data AND policy documents
- An interactive **Streamlit dashboard** with map visualizations and AI Q&A

## Snowflake Features Covered

| Feature | Purpose |
|---|---|
| Snowflake Marketplace | Overture Maps Buildings (2.3B global footprints) |
| Geospatial + H3 Functions | Spatial joins, hexagonal risk mapping |
| Internal Stages | Loading FEMA NRI + CDC SVI CSV data |
| Cortex PARSE_DOCUMENT | Extracting text from flood policy PDFs |
| Cortex Search | Semantic search over policy documents |
| Cortex COMPLETE | AI-generated risk summaries |
| Cortex Agent | Unified Q&A over structured data + unstructured documents |
| Streamlit in Snowflake | Interactive 4-tab vulnerability dashboard |
| Dynamic Tables | Auto-refreshing risk alert pipeline |

---

## Repository Structure

```
flood-resilience/
├── .snowflake/cortex/skills/
│   └── deploy-streamlit-flood-dashboard/
│       └── SKILL.md                        ← Cortex Code skill for deterministic deployment
├── notebooks/
│   └── flood_vulnerability_hol.ipynb       ← Main HOL notebook (Labs 1-8)
├── streamlit/
│   ├── .streamlit/
│   │   └── config.toml                    ← Snowflake brand theme (buttons, colours)
│   ├── flood_dashboard.py                 ← Streamlit app (pydeck maps + altair charts)
│   └── environment.yml                    ← Package dependencies (pydeck, altair, pandas)
├── semantic_model/
│   └── flood_risk_model.yaml              ← Semantic model for Cortex Analyst
├── agent/
│   ├── flood_risk_agent_spec.json         ← Cortex Agent spec (structured + unstructured)
│   └── create_agent.sql                   ← SQL to create the agent
├── data/
│   ├── fema_nri/
│   │   └── NRI_CensusTracts_Louisiana.csv ← FEMA National Risk Index (1,376 tracts)
│   ├── cdc_svi/
│   │   └── SVI_2022_LA.csv               ← CDC Social Vulnerability Index (1,379 tracts)
│   ├── parish_centroids/
│   │   └── LA_Parish_Centroids.csv       ← 64 Louisiana parish centroids (lat/lon)
│   └── policy_docs/
│       ├── Louisiana_Hazard_Mitigation_Plan_2024_Intro.pdf
│       └── Louisiana_Hazard_Mitigation_Plan_2024_Strategies.pdf
```

---

## Quick Start (Step by Step)

### Prerequisites

- Snowflake account with **ACCOUNTADMIN** role (trial accounts work)
- A web browser (Chrome recommended)

---

### Step 1 — Install Overture Maps Buildings from Marketplace

This gives you access to 2.3 billion building footprints worldwide.

1. Log in to **Snowsight** (https://app.snowflake.com)
2. Click **Marketplace** in the left sidebar
3. Click **Snowflake Marketplace**
4. In the search bar, type **"Overture Maps - Buildings"**
5. Find the listing by **CARTO** and click on it
6. Click the blue **Get** button (top right)
7. In the dialog, click on options and then set the database name to **`OVERTURE_MAPS_BUILDINGS`**. Make sure there is only one underscore between MAPS and BUILDINGS.
8. In the roles dropdown, select **PUBLIC**
9. Click **Get** again to confirm
10. Wait for the share to be mounted (takes ~30 seconds)

> **How to verify:** Go to **Data → Databases** in the left sidebar. You should see `OVERTURE_MAPS_BUILDINGS` listed.

---

### Step 2 — Create a Git Workspace
This lab runs as a **Notebook in a Workspace** (not the legacy notebook experience). You'll connect the GitHub repo directly to a workspace.
#### 2a. Create the Workspace from Git
1. In Snowsight, click **Projects** in the left sidebar
2. Click **Workspaces**
3. Open the workspace dropdown (top left) → **From Git repository**
4. In the dialog:
   - **Repository URL**: `https://github.com/sfc-gh-lhartzell/flood-resilience`
   - **API Integration**: Click **+ Create a new API integration**
     - **Integration name**: `FLOODS` (must be CAPITAL LETTERS)
     - **Allowed domain**: `github.com`
     - Don't see **Create a new API integration**? Switch to `ACCOUNTADMIN`, or run this in a SQL file and then select `FLOODS` from the dropdown:
       ```sql
       USE ROLE ACCOUNTADMIN;
       CREATE OR REPLACE API INTEGRATION FLOODS
         API_PROVIDER = git_https_api
         API_ALLOWED_PREFIXES = ('https://github.com')
         ALLOWED_AUTHENTICATION_SECRETS = ALL
         ENABLED = TRUE;
       ```
   - **Authentication**: Public repository
     - Click **Create**
   - **Workspace name**: `flood-resilience` (must be exactly this; the notebook reads files from this path)
5. Click **Create**
6. Wait for the workspace to sync with the repository
#### 2b. Open the Notebook and Connect to a Service
1. In the workspace file explorer, navigate to `notebooks/`
2. Click on `flood_vulnerability_hol.ipynb`
3. The notebook will open in the workspace notebook editor
4. You will be prompted to connect to a service:
   - Click **+ Create Service**
   - Accept the default settings (or choose a name)
   - Click **Create**
   - Wait for the service to start (takes ~30 seconds)
5. Set the notebook context:
   - **Database**: `FLOOD_ANALYTICS` (will be created by the first cell)
   - **Schema**: `FLOOD`
   - **Warehouse**: `FLOOD_WH` (will be created by the first cell)
> **Tip:** All files (data CSVs, PDFs, Streamlit app) are accessible directly from the workspace — no manual file uploads needed.
---
### Step 3 — Run the Notebook
The notebook handles **everything automatically** — data uploads, table creation, and deployments are all done via `COPY FILES INTO` from the workspace. No manual file uploads are needed.
Simply run the notebook cells in order (top to bottom). Each lab section is marked with a heading.
| Lab | What it does | Time |
|---|---|---|
| Lab 1 | Setup database/warehouse + extract Louisiana buildings | 3-5 min |
| Lab 2 | Load FEMA NRI + CDC SVI data from workspace to stage | 1 min |
| Lab 3 | Build flood risk tables + parish summary | 2-4 min |
| Lab 4 | Dynamic table for real-time alerts | 1 min |
| Lab 5 | Upload policy PDFs + Cortex AI document intelligence | 2 min |
| Lab 6 | Verify all tables for Cortex Analyst | 1 min |
| Lab 7 | Streamlit dashboard deployment | 1 min |
| Lab 8 | Deploy Cortex Agent | 1 min |
> **Total runtime:** ~15-20 minutes on a MEDIUM warehouse.

---
### Step 4 — Deploy the Streamlit Dashboard
The notebook includes a deployment cell that automates this, or you can run the SQL manually:
```sql
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
```
**What you'll see — 4 tabs:**

| Tab | Content |
|---|---|
| Parish Overview | Altair bar chart of flood zone exposure + bubble scatter (NRI vs SVI) |
| Building Explorer | **Pydeck PolygonLayer** rendering actual building footprints colour-coded by vulnerability, with interactive tooltips |
| H3 Heatmap | **Pydeck H3HexagonLayer** 2D hexagonal vulnerability heatmap + donut risk distribution |
| AI Insights | Ask Cortex AI any question about flood risk; see key statistics |

**Key features:**
- **Snowflake brand styling** via `.streamlit/config.toml` — cyan buttons, clean white UI
- **Building polygon rendering** — actual Overture Maps geometries from `BUILDINGS_LA.GEOMETRY`
- **Altair charts** — gradient bar charts, scatter plots, histograms with interactive tooltips
- **Pydeck maps** — `PolygonLayer` for buildings, `H3HexagonLayer` for hex heatmap

**Try these questions in the AI Insights tab:**
- *"Which parish has the highest percentage of buildings in flood zones?"*
- *"What is the total expected annual loss for the top 5 most vulnerable parishes?"*
- *"How does social vulnerability correlate with flood exposure?"*

---

### Step 6 — Use Cortex Analyst (Structured Data Q&A)

Cortex Analyst lets you ask natural language questions that automatically generate SQL.

1. In Snowsight, click **AI & ML** in the left sidebar
2. Click **Cortex Analyst**
3. Click **+ New Chat** (or **New Conversation**)
4. When prompted to select a semantic model, choose:
   - **Stage**: `@FLOOD_ANALYTICS.FLOOD.FLOOD_DATA_STAGE/semantic/flood_risk_model.yaml`
5. Start asking questions!

**Try these questions:**
- *"Which parish has the highest composite flood vulnerability score?"*
- *"How many buildings are in FEMA Special Flood Hazard Areas by parish?"*
- *"What is the total expected annual loss statewide?"*
- *"Which parishes have both high social vulnerability (SVI > 0.7) and high flood exposure?"*
- *"How many hospitals and schools are in flood zones?"*

> **What happens:** Cortex Analyst reads the semantic model, understands your table structure, and generates SQL to answer your question. You'll see both the SQL and the results.

---

### Step 7 — Deploy the Cortex Agent (Structured + Unstructured Q&A)

The Cortex Agent is the most powerful interface — it combines **structured data** (building counts, risk scores, parish statistics) with **unstructured policy documents** (mitigation plans, historical events, levee projects) in a single conversational experience.

**Create the agent:**

1. In Snowsight, click **Projects** in the left sidebar
2. Click **Worksheets** → **+ SQL Worksheet**
3. Paste the entire contents of `agent/create_agent.sql` from this repo
4. Click **Run All** (or select all and press Ctrl+Enter)
5. You should see: `Agent FLOOD_RISK_AGENT successfully created.`

**Use the agent:**

6. In Snowsight, click **AI & ML** in the left sidebar
7. Click **Snowflake CoWork** (formerly Snowflake Intelligence) or **Agents**
8. You should see `FLOOD_RISK_AGENT` listed — click on it
9. Start a conversation!

**Try these questions (the agent will automatically choose the right tool):**

| Question | Tools Used | What You Get |
|---|---|---|
| *"Which 5 parishes have the highest flood vulnerability?"* | Structured data | Parish rankings with scores |
| *"What does the state mitigation plan say about levee projects?"* | Policy docs | Relevant excerpts from the PDF |
| *"Which parishes are most at risk and what federal programs can help them?"* | Both tools | Data-driven risk ranking + policy context |
| *"What happened during Hurricane Katrina and how many buildings are still in flood zones?"* | Both tools | Historical context + current exposure stats |
| *"What mitigation strategies are planned for coastal Louisiana?"* | Policy docs | State plan strategies and projects |
| *"Compare the social vulnerability of Orleans Parish vs Jefferson Parish"* | Structured data | SVI scores and building exposure side-by-side |

> **How it works:** The agent has two tools:
> - **query_flood_data** — generates SQL queries against your 3.56M building database
> - **search_policy_docs** — searches through the parsed Louisiana Hazard Mitigation Plan PDFs
>
> It automatically decides which tool to use (or both) based on your question.

---

## Data Sources

| Dataset | Source | License |
|---|---|---|
| Overture Maps Buildings | CARTO / Overture Maps Foundation | ODbL |
| FEMA National Risk Index | hazards.fema.gov | Public Domain |
| CDC Social Vulnerability Index 2022 | atsdr.cdc.gov | Public Domain |
| Louisiana State Hazard Mitigation Plan 2024 | gohsep.la.gov | Public Domain |

---

## Architecture

```
MARKETPLACE              STAGES                     CORTEX AI
Overture Maps     →   FEMA NRI CSV          →   PARSE_DOCUMENT
Buildings         →   CDC SVI CSV           →   Cortex Search
                  →   Policy PDFs           →   Cortex COMPLETE
        ↓                  ↓                          ↓
              FLOOD_ANALYTICS.FLOOD schema
        ┌──────────────────────────────────┐
        │ BUILDINGS_LA    FEMA_NRI         │
        │ CDC_SVI         FLOOD_ZONES      │
        │ BUILDING_FLOOD_RISK              │
        │ PARISH_FLOOD_SUMMARY             │
        │ H3_FLOOD_RISK_MAP                │
        │ FLOOD_RISK_ALERTS (Dynamic TBL)  │
        └──────────────────────────────────┘
                          ↓
              ┌────────────────────────┐
              │   CORTEX AGENT         │
              │   (FLOOD_RISK_AGENT)   │
              │                        │
              │  Tool 1: Analyst       │
              │  (structured SQL)      │
              │                        │
              │  Tool 2: Search        │
              │  (policy documents)    │
              └────────────────────────┘
                          ↓
              STREAMLIT DASHBOARD
              SNOWFLAKE COWORK
```

---

## Backup: Notebook Won't Start (Container Capacity)

Workspace notebooks need an SPCS container. If the region runs out of capacity and your notebook won't start, use the worksheet version instead. It runs on a warehouse, so no container is needed.

1. Complete Steps 1–2 above (the workspace must be named exactly `flood-resilience`).
2. In your workspace, open **`flood_lab_worksheet_backup.sql`**.
3. Run it **section by section**, top to bottom, as `ACCOUNTADMIN`.
4. Build the agent in Semantic Studio (notebook Lab 7B), or uncomment the **FALLBACK** section at the bottom of the file.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `Database 'OVERTURE_MAPS_BUILDINGS' does not exist` | Go to Marketplace and install "Overture Maps - Buildings" by CARTO |
| `COPY INTO fails with column count mismatch` | The notebook uses `PARSE_HEADER = TRUE` and `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` — make sure you ran the CSV_FORMAT cell first |
| `Agent says "search_service not provided"` | Make sure you're using the latest `create_agent.sql` — the field must be `search_service` not `cortex_search_service` |
| `Cortex Search returns no results` | Run `ALTER STAGE FLOOD_POLICY_DOCS REFRESH;` then wait 60 seconds for indexing |
| `H3_CELL_TO_BOUNDARY_WKT not found` | Use `ST_ASWKT(H3_CELL_TO_BOUNDARY(...))` instead — the notebook has been fixed |
| `SVI shows negative values (-999)` | These are CDC sentinel values — the notebook filters them with `CASE WHEN >= 0` |
| `st.pydeck_chart() got unexpected keyword argument 'height'` | Remove `height` parameter — not supported in Snowflake Streamlit runtime |
| `st.map() got unexpected keyword argument 'latitude'` | Use pydeck instead of st.map |
| All parishes show 100% in flood zones | `PCT_IN_SFHA` must use tract-level FLOOD_ZONES table, not the parish-level boolean |
| Annual loss shows trillions | Use `MAX()` not `SUM()` for parish EAL (it's a parish-level value duplicated per building) |
| Pydeck tooltips show `{field}` as literal text | Use `PolygonLayer` with flat dataframe, not `GeoJsonLayer` with nested properties |

---

## Lab Overview

| Lab | Topic | Time |
|---|---|---|
| 1 | Environment setup + Overture Buildings extraction | 10 min |
| 2 | Load FEMA NRI + CDC SVI + derive Flood Zones | 15 min |
| 3 | Geospatial flood risk analysis (H3 spatial joins) | 20 min |
| 4 | Dynamic Tables for automated risk alerts | 10 min |
| 5 | Cortex AI — parse policy PDFs + semantic search | 20 min |
| 6 | Cortex Analyst — natural language data Q&A | 5 min |
| 7 | Streamlit dashboard deployment | 10 min |
| 8 | Cleanup (optional) | — |

**Total: ~90 minutes**

---

*Originally built by Fawad Qureshi for Snowflake Summit 2026; adapted for World Tour Chicago 2026 | Data: Overture Maps / CARTO · FEMA NRI · CDC SVI · Louisiana GOHSEP*
