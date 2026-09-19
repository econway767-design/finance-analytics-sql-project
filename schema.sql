-- ============================================================
-- Finance Analytics Database — Schema
-- SQLite. Designed for: Power BI reporting + SQL interview demo.
-- ============================================================
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------
-- Reference / dimension tables
-- ---------------------------------------------------------------
CREATE TABLE sectors (
    sector_id     INTEGER PRIMARY KEY,
    sector_name   TEXT NOT NULL UNIQUE
);

CREATE TABLE companies (
    company_id    INTEGER PRIMARY KEY,
    ticker        TEXT NOT NULL UNIQUE,
    company_name  TEXT NOT NULL,
    sector_id     INTEGER NOT NULL REFERENCES sectors(sector_id),
    country       TEXT NOT NULL,
    ipo_year      INTEGER,
    shares_out_m  REAL NOT NULL          -- shares outstanding, millions (for EPS/market cap)
);

-- ---------------------------------------------------------------
-- Fact tables: annual fundamentals (fiscal years)
-- ---------------------------------------------------------------
CREATE TABLE income_statement (
    company_id        INTEGER NOT NULL REFERENCES companies(company_id),
    fiscal_year        INTEGER NOT NULL,
    revenue             REAL NOT NULL,
    cogs                REAL NOT NULL,
    gross_profit        REAL NOT NULL,
    operating_expenses  REAL NOT NULL,
    operating_income    REAL NOT NULL,
    interest_expense    REAL NOT NULL,
    tax_expense         REAL NOT NULL,
    net_income           REAL NOT NULL,
    PRIMARY KEY (company_id, fiscal_year)
);

CREATE TABLE balance_sheet (
    company_id            INTEGER NOT NULL REFERENCES companies(company_id),
    fiscal_year             INTEGER NOT NULL,
    cash_and_equivalents     REAL NOT NULL,
    accounts_receivable      REAL NOT NULL,
    inventory                REAL NOT NULL,
    current_assets           REAL NOT NULL,
    total_assets              REAL NOT NULL,
    accounts_payable          REAL NOT NULL,
    current_liabilities       REAL NOT NULL,
    long_term_debt             REAL NOT NULL,
    total_liabilities          REAL NOT NULL,
    total_equity                REAL NOT NULL,
    PRIMARY KEY (company_id, fiscal_year)
);

CREATE TABLE cash_flow_statement (
    company_id              INTEGER NOT NULL REFERENCES companies(company_id),
    fiscal_year                INTEGER NOT NULL,
    operating_cash_flow          REAL NOT NULL,
    investing_cash_flow          REAL NOT NULL,
    financing_cash_flow          REAL NOT NULL,
    capital_expenditures          REAL NOT NULL,
    free_cash_flow                  REAL NOT NULL,
    dividends_paid                  REAL NOT NULL,
    PRIMARY KEY (company_id, fiscal_year)
);

-- ---------------------------------------------------------------
-- Fact table: daily market data
-- ---------------------------------------------------------------
CREATE TABLE stock_prices (
    company_id    INTEGER NOT NULL REFERENCES companies(company_id),
    price_date     TEXT NOT NULL,     -- ISO date 'YYYY-MM-DD'
    open_price      REAL NOT NULL,
    high_price       REAL NOT NULL,
    low_price         REAL NOT NULL,
    close_price        REAL NOT NULL,
    volume               INTEGER NOT NULL,
    PRIMARY KEY (company_id, price_date)
);

-- ---------------------------------------------------------------
-- Knowledge table: finance glossary (for "display finance knowledge")
-- ---------------------------------------------------------------
CREATE TABLE glossary (
    term_id       INTEGER PRIMARY KEY,
    term           TEXT NOT NULL UNIQUE,
    category        TEXT NOT NULL,     -- e.g. Valuation, Liquidity, Profitability, Market
    definition       TEXT NOT NULL,
    formula           TEXT              -- nullable: not every term has one
);

-- ---------------------------------------------------------------
-- Indexes to support common query patterns
-- ---------------------------------------------------------------
CREATE INDEX idx_income_year        ON income_statement(fiscal_year);
CREATE INDEX idx_balance_year       ON balance_sheet(fiscal_year);
CREATE INDEX idx_cashflow_year      ON cash_flow_statement(fiscal_year);
CREATE INDEX idx_prices_company     ON stock_prices(company_id);
CREATE INDEX idx_prices_date        ON stock_prices(price_date);
CREATE INDEX idx_companies_sector   ON companies(sector_id);

-- ---------------------------------------------------------------
-- Views: derived financial ratios computed via SQL (joins across
-- the three statements) rather than stored — this is the layer
-- worth walking through in an interview.
-- ---------------------------------------------------------------
CREATE VIEW v_financial_ratios AS
SELECT
    i.company_id,
    i.fiscal_year,
    ROUND(i.gross_profit / i.revenue, 4)                       AS gross_margin,
    ROUND(i.operating_income / i.revenue, 4)                   AS operating_margin,
    ROUND(i.net_income / i.revenue, 4)                          AS net_margin,
    ROUND(b.current_assets / b.current_liabilities, 2)          AS current_ratio,
    ROUND((b.current_assets - b.inventory) / b.current_liabilities, 2) AS quick_ratio,
    ROUND(b.total_liabilities / b.total_equity, 2)               AS debt_to_equity,
    ROUND(i.net_income / b.total_equity, 4)                       AS roe,
    ROUND(i.net_income / b.total_assets, 4)                        AS roa,
    ROUND(cf.free_cash_flow / i.revenue, 4)                         AS fcf_margin,
    ROUND(i.net_income / c.shares_out_m, 2)                          AS eps
FROM income_statement i
JOIN balance_sheet b        ON b.company_id = i.company_id AND b.fiscal_year = i.fiscal_year
JOIN cash_flow_statement cf ON cf.company_id = i.company_id AND cf.fiscal_year = i.fiscal_year
JOIN companies c            ON c.company_id = i.company_id;

CREATE VIEW v_company_overview AS
SELECT
    c.company_id,
    c.ticker,
    c.company_name,
    s.sector_name,
    c.country,
    c.ipo_year,
    c.shares_out_m
FROM companies c
JOIN sectors s ON s.sector_id = c.sector_id;
