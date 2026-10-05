-- ============================================================
-- Create the Flood Risk Agent
-- Combines structured data (Cortex Analyst) + policy documents (Cortex Search)
-- Requires FLOOD_RISK_SEMANTIC_VIEW (built with CoCo in Lab 7B, or by the
-- Lab 7B (Fallback) cell in the notebook)
-- ============================================================

CREATE OR REPLACE AGENT FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_AGENT
FROM SPECIFICATION $$
{
  "models": {
    "orchestration": "auto"
  },
  "orchestration": {
    "budget": {
      "seconds": 900,
      "tokens": 400000
    }
  },
  "instructions": {
    "orchestration": "You are a Louisiana flood risk analyst. You have access to two tools: (1) query_flood_data for structured analysis of 3.5M buildings, 64 parishes, FEMA risk scores, CDC social vulnerability, and flood zone designations; (2) search_policy_docs for finding information from Louisiana's 2024 State Hazard Mitigation Plan including mitigation strategies, levee projects, historical disaster impacts, and policy recommendations. When a user asks about risk statistics, building counts, parish comparisons, or vulnerability scores, use query_flood_data. When a user asks about mitigation plans, policy strategies, historical events, levee projects, or government programs, use search_policy_docs. For comprehensive answers, use both tools.",
    "response": "Provide concise, data-driven answers. When presenting numbers, format them clearly. When referencing policy documents, cite the source document name. If combining structured data with policy context, clearly distinguish between quantitative findings and policy recommendations."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "query_flood_data",
        "description": "Query structured flood risk data for Louisiana. Contains 3.56M building footprints with flood zone designations (VE=coastal high hazard, AE=inland flood, X500=moderate, X=minimal), FEMA National Risk Index scores (0-100), CDC Social Vulnerability Index (0-1), composite vulnerability scores, expected annual losses in dollars, and parish-level summaries. Use for questions about building counts in flood zones, parish risk rankings, social vulnerability, expected annual losses, critical infrastructure at risk."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "search_policy_docs",
        "description": "Search Louisiana 2024 State Hazard Mitigation Plan for policy information, mitigation strategies, historical flood events, levee and infrastructure projects, federal and state funding programs, and disaster preparedness recommendations. Use for questions about what mitigation actions are planned, what happened during Hurricane Katrina or Ida, what flood protection infrastructure exists, what government programs fund flood mitigation."
      }
    }
  ],
  "tool_resources": {
    "query_flood_data": {
      "execution_environment": {
        "query_timeout": 299,
        "type": "warehouse",
        "warehouse": "FLOOD_WH"
      },
      "semantic_view": "FLOOD_ANALYTICS.FLOOD.FLOOD_RISK_SEMANTIC_VIEW"
    },
    "search_policy_docs": {
      "search_service": "FLOOD_ANALYTICS.FLOOD.FLOOD_POLICY_SEARCH"
    }
  }
}
$$;

-- Verify agent was created
SHOW AGENTS IN SCHEMA FLOOD_ANALYTICS.FLOOD;

-- To use the agent:
-- 1. Snowsight -> AI & ML -> Snowflake CoWork (formerly Snowflake Intelligence) -> select FLOOD_RISK_AGENT
-- 2. Ask questions like:
--    "Which parishes have the highest flood risk and what mitigation plans exist for them?"
--    "How many buildings are in coastal flood zones?"
--    "What does the state plan say about levee improvements?"
