-- ============================================================
-- Interview-ready example queries against finance.db
-- Each one demonstrates a specific SQL technique worth talking
-- through: window functions, CTEs, joins, self-joins, etc.
-- ============================================================

-- 1. JOIN across 3 fact tables via a view + revenue ranking
--    Technique: multi-table join, view reuse, ORDER BY / LIMIT
SELECT co.ticker, co.company_name, s.sector_name,
       i.fiscal_year, i.revenue, r.net_margin, r.roe
FROM income_statement i
JOIN v_company_overview co ON co.company_id = i.company_id
JOIN v_financial_ratios r ON r.company_id = i.company_id AND r.fiscal_year = i.fiscal_year
JOIN sectors s ON s.sector_name = co.sector_name
WHERE i.fiscal_year = 2025
ORDER BY i.revenue DESC;


-- 2. Window function: revenue growth YoY per company
--    Technique: LAG() window function partitioned by company
SELECT
    co.ticker,
    i.fiscal_year,
    i.revenue,
    LAG(i.revenue) OVER (PARTITION BY i.company_id ORDER BY i.fiscal_year) AS prior_year_revenue,
    ROUND(
        (i.revenue - LAG(i.revenue) OVER (PARTITION BY i.company_id ORDER BY i.fiscal_year))
        / LAG(i.revenue) OVER (PARTITION BY i.company_id ORDER BY i.fiscal_year) * 100, 2
    ) AS revenue_growth_pct
FROM income_statement i
JOIN companies co ON co.company_id = i.company_id
ORDER BY co.ticker, i.fiscal_year;


-- 3. Window function: rank companies by ROE within their own sector, per year
--    Technique: RANK() with PARTITION BY sector + year
SELECT
    s.sector_name,
    co.ticker,
    r.fiscal_year,
    r.roe,
    RANK() OVER (PARTITION BY s.sector_name, r.fiscal_year ORDER BY r.roe DESC) AS roe_rank_in_sector
FROM v_financial_ratios r
JOIN companies co ON co.company_id = r.company_id
JOIN sectors s ON s.sector_id = co.sector_id
WHERE r.fiscal_year = 2025
ORDER BY s.sector_name, roe_rank_in_sector;


-- 4. CTE + aggregate: sector-level average margins, most profitable sector first
--    Technique: CTE, GROUP BY, AVG
WITH sector_margins AS (
    SELECT s.sector_name, r.fiscal_year, r.net_margin, r.gross_margin
    FROM v_financial_ratios r
    JOIN companies co ON co.company_id = r.company_id
    JOIN sectors s ON s.sector_id = co.sector_id
)
SELECT sector_name,
       fiscal_year,
       ROUND(AVG(net_margin), 4) AS avg_net_margin,
       ROUND(AVG(gross_margin), 4) AS avg_gross_margin,
       COUNT(*) AS company_count
FROM sector_margins
GROUP BY sector_name, fiscal_year
HAVING fiscal_year = 2025
ORDER BY avg_net_margin DESC;


-- 5. Moving average on daily prices: 20-day rolling average close price
--    Technique: window frame (ROWS BETWEEN ... PRECEDING)
-- Swap 'AAPL' for any ticker actually in your companies table.
SELECT
    co.ticker,
    sp.price_date,
    sp.close_price,
    ROUND(AVG(sp.close_price) OVER (
        PARTITION BY sp.company_id
        ORDER BY sp.price_date
        ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    ), 2) AS moving_avg_20d
FROM stock_prices sp
JOIN companies co ON co.company_id = sp.company_id
WHERE co.ticker = 'AAPL'
ORDER BY sp.price_date;


-- 6. Self-join / correlated subquery: companies whose latest close is
--    more than 20% below their 2-year high
--    Technique: correlated subquery, HAVING-style filter via WHERE
SELECT co.ticker,
       latest.price_date AS latest_date,
       latest.close_price AS latest_close,
       peak.max_close AS two_year_high,
       ROUND((latest.close_price - peak.max_close) / peak.max_close * 100, 1) AS pct_off_high
FROM companies co
JOIN (
    SELECT company_id, price_date, close_price
    FROM stock_prices sp1
    WHERE price_date = (SELECT MAX(price_date) FROM stock_prices sp2 WHERE sp2.company_id = sp1.company_id)
) latest ON latest.company_id = co.company_id
JOIN (
    SELECT company_id, MAX(close_price) AS max_close
    FROM stock_prices
    GROUP BY company_id
) peak ON peak.company_id = co.company_id
WHERE (latest.close_price - peak.max_close) / peak.max_close <= -0.20
ORDER BY pct_off_high;


-- 7. CTE chain: free cash flow trend + simple 3-year CAGR per company
--    Technique: multiple CTEs, first/last value via window functions
WITH fcf AS (
    SELECT company_id, fiscal_year, free_cash_flow
    FROM cash_flow_statement
),
bounds AS (
    SELECT company_id,
           FIRST_VALUE(free_cash_flow) OVER (PARTITION BY company_id ORDER BY fiscal_year) AS start_fcf,
           FIRST_VALUE(free_cash_flow) OVER (PARTITION BY company_id ORDER BY fiscal_year DESC) AS end_fcf,
           COUNT(*) OVER (PARTITION BY company_id) AS n_years
    FROM fcf
)
SELECT co.ticker,
       b.start_fcf,
       b.end_fcf,
       ROUND((POWER(b.end_fcf / NULLIF(b.start_fcf, 0), 1.0 / (b.n_years - 1)) - 1) * 100, 2) AS fcf_cagr_pct
FROM (SELECT DISTINCT company_id, start_fcf, end_fcf, n_years FROM bounds) b
JOIN companies co ON co.company_id = b.company_id
WHERE b.start_fcf > 0
ORDER BY fcf_cagr_pct DESC;


-- 8. Liquidity screen with CASE-based risk flag
--    Technique: CASE expression, multi-condition filter
SELECT co.ticker,
       r.fiscal_year,
       r.current_ratio,
       r.debt_to_equity,
       CASE
           WHEN r.current_ratio < 1.0 THEN 'Liquidity risk'
           WHEN r.debt_to_equity > 2.0 THEN 'Leverage risk'
           ELSE 'Healthy'
       END AS risk_flag
FROM v_financial_ratios r
JOIN companies co ON co.company_id = r.company_id
WHERE r.fiscal_year = 2025
ORDER BY risk_flag, r.current_ratio;


-- 9. Volatility ranking: annualized std dev of daily returns per company (2025)
--    Technique: derived table for daily returns, aggregate STDDEV substitute
--    (SQLite has no native STDEV, so it's computed manually from AVG of squared deviations)
WITH daily_returns AS (
    SELECT
        company_id,
        price_date,
        (close_price - LAG(close_price) OVER (PARTITION BY company_id ORDER BY price_date))
            / LAG(close_price) OVER (PARTITION BY company_id ORDER BY price_date) AS daily_return
    FROM stock_prices
    WHERE price_date >= '2025-01-01'
),
stats AS (
    SELECT company_id,
           AVG(daily_return) AS mean_return,
           AVG(daily_return * daily_return) - AVG(daily_return) * AVG(daily_return) AS variance
    FROM daily_returns
    WHERE daily_return IS NOT NULL
    GROUP BY company_id
)
SELECT co.ticker,
       ROUND(SQRT(variance) * SQRT(252) * 100, 2) AS annualized_volatility_pct
FROM stats s
JOIN companies co ON co.company_id = s.company_id
ORDER BY annualized_volatility_pct DESC;


-- 10. Glossary lookup with pattern matching
--     Technique: LIKE filter, useful as a "knowledge base" query
SELECT term, category, definition, formula
FROM glossary
WHERE category = 'Liquidity' OR term LIKE '%Ratio%'
ORDER BY category, term;
