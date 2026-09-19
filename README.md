# Finance Analytics Database

A SQL-based financial analytics platform built on real company data, with
company fundamentals and daily stock prices pulled from WRDS (Compustat
and CRSP), modeled in a normalized SQLite database, and visualized in a
3-page Power BI dashboard.

## Overview

The project covers the full pipeline from raw data to finished dashboard:

- **Data sourcing** - annual fundamentals (income statement, balance
  sheet, cash flow statement) and daily OHLCV pricing for 12 companies
  across 6+ GICS sectors, pulled directly from Compustat and CRSP via WRDS.
- **Database design** - a normalized relational schema in SQLite, with
  dimension tables for companies and sectors, fact tables for financials
  and prices, and SQL views that compute financial ratios (margins,
  liquidity, leverage, returns, EPS) on the fly rather than storing them,
  so the numbers are always consistent with the underlying data.
- **Analysis** - a library of SQL queries covering window functions
  (rolling averages, YoY growth, in-sector rankings), CTEs, correlated
  subqueries, and volatility calculations.
- **Visualization** - a 3-page Power BI dashboard (Overview, Stock
  Prices, Risk & Liquidity) connected directly to the database.

## Data

- **Source:** WRDS (Wharton Research Data Services) - Compustat for
  fundamentals, CRSP for daily prices, joined via the CRSP/Compustat
  Merged link table.
- **Coverage:** 12 companies (AAPL, MSFT, JPM, XOM, JNJ, WMT, CAT, NEE,
  PG, GS, UNH, HON), spanning Technology, Financials, Energy, Healthcare,
  Consumer Staples, Industrials, and Utilities.
- **Time range:** 5 years of annual fundamentals (2021-2025), 2 years of
  daily prices (2024-2025).
- **Sector classification:** GICS (Global Industry Classification
  Standard) sector codes, the same industry-standard classification used
  by Bloomberg and Morningstar.

## Database design

The schema separates raw financial data (income statement, balance sheet,
cash flow statement, daily prices) from derived analytics. Ratios like
ROE, current ratio, debt-to-equity, and free cash flow margin are computed
through SQL views joining across the underlying tables, rather than stored
as static values - keeping the analytics layer consistent with the source
data at all times.

```
companies ─ sectors
    │
    ├── income_statement
    ├── balance_sheet
    ├── cash_flow_statement
    └── stock_prices

v_financial_ratios   (margins, liquidity, leverage, ROE/ROA, EPS)
v_company_overview   (company + sector reference view)
```

## Dashboard

Built in Power BI, connected live to the SQLite database:

- **Overview** - company and sector-level KPIs, sector profitability, and
  revenue trends.
- **Stock Prices** - daily price history with rolling averages.
- **Risk & Liquidity** - liquidity and leverage positioning across the
  portfolio, with the underlying ratio data available in table form.

## Tech stack

SQL (SQLite) | Python (data pipeline) | Power BI | WRDS/Compustat/CRSP

---

*Built as an independent project to apply SQL and financial data analysis
skills to a real, non-trivial dataset. From raw data acquisition through
to a finished analytics dashboard.*
