"""
Pull real company fundamentals (Compustat) and daily prices (CRSP) from
WRDS via direct SQL, then load them into the SAME schema as finance.db
(see schema.sql) so everything downstream — the ratio views, the example
queries, the Power BI connection — keeps working unchanged.

RUN THIS ON YOUR OWN MACHINE, NOT IN A SANDBOX WITHOUT WRDS ACCESS.
Requires: pip install wrds pandas
You'll be prompted for your WRDS username/password the first time
(or set up a .pgpass file so it's passwordless after that — WRDS's
docs cover this under "Setting up a .pgpass file").
"""
import wrds
import sqlite3
import pandas as pd

# ---------------------------------------------------------------
# 1. Pick your companies. Compustat identifies firms by `gvkey`,
#    CRSP by `permno` — they're linked via the CCM link table.
#    Swap these tickers for whichever companies you want.
# ---------------------------------------------------------------
TICKERS = ['AAPL', 'MSFT', 'JPM', 'XOM', 'JNJ', 'WMT',
           'CAT', 'NEE', 'PG', 'GS', 'UNH', 'HON']

START_YEAR = 2021
END_YEAR = 2025
PRICE_START = '2024-01-01'
PRICE_END = '2025-12-31'

# Standard GICS sector codes, as carried on Compustat's comp.company.gsector
# field — an industry-standard classification (used by Bloomberg, Morningstar,
# etc.), not something specific to this project. Fixed regardless of which
# tickers you pick.
GICS_SECTORS = {
    '10': 'Energy',
    '15': 'Materials',
    '20': 'Industrials',
    '25': 'Consumer Discretionary',
    '30': 'Consumer Staples',
    '35': 'Health Care',
    '40': 'Financials',
    '45': 'Information Technology',
    '50': 'Communication Services',
    '55': 'Utilities',
    '60': 'Real Estate',
}


def main():
    db = wrds.Connection()  # prompts for WRDS username/password first run

    # -------------------------------------------------------------
    # 2. Map tickers -> gvkey (Compustat) and permno (CRSP) via the
    #    CRSP/Compustat Merged (CCM) link table.
    # -------------------------------------------------------------
    tickers_sql = "', '".join(TICKERS)
    link = db.raw_sql(f"""
        SELECT DISTINCT a.gvkey, a.lpermno AS permno, s.tic, c.conm, c.gsector
        FROM crsp.ccmxpf_linktable a
        JOIN comp.security s ON a.gvkey = s.gvkey
        JOIN comp.company c ON a.gvkey = c.gvkey
        WHERE s.tic IN ('{tickers_sql}')
          AND s.iid = '01'
          AND a.linktype IN ('LC', 'LU')
          AND a.linkprim IN ('P', 'C')
          AND (a.linkenddt IS NULL OR a.linkenddt >= '{START_YEAR}-01-01')
    """)
    print(link)

    gvkeys = "', '".join(link['gvkey'].unique())
    permnos = ", ".join(str(p) for p in link['permno'].unique())

    # -------------------------------------------------------------
    # 3. Pull annual fundamentals from Compustat (comp.funda).
    #    Field names below are the standard Compustat items.
    # -------------------------------------------------------------
    funda = db.raw_sql(f"""
        SELECT gvkey, fyear, datadate,
               sale AS revenue, cogs, xsga AS opex,
               oiadp AS operating_income, xint AS interest_expense,
               txt AS tax_expense, ni AS net_income,
               che AS cash, rect AS receivables, invt AS inventory,
               act AS current_assets, at AS total_assets,
               ap AS accounts_payable, lct AS current_liabilities,
               dltt AS long_term_debt, lt AS total_liabilities,
               seq AS total_equity,
               oancf AS operating_cf, ivncf AS investing_cf,
               fincf AS financing_cf, capx AS capex, dvc AS dividends_paid,
               csho AS shares_out_m
        FROM comp.funda
        WHERE gvkey IN ('{gvkeys}')
          AND fyear BETWEEN {START_YEAR} AND {END_YEAR}
          AND indfmt = 'INDL' AND datafmt = 'STD'
          AND popsrc = 'D' AND consol = 'C'
        ORDER BY gvkey, fyear
    """)

    # -------------------------------------------------------------
    # 4. Pull daily prices from CRSP.
    #    WRDS migrated CRSP to a new "CIZ" data format in early 2025 —
    #    the legacy crsp.dsf table was frozen at end-of-2024 and never
    #    received 2025 data. crsp.dsf_v2 is the current table, with
    #    renamed columns (dlycaldt, dlyopen, dlyhigh, dlylow, dlyprc, dlyvol).
    # -------------------------------------------------------------
    prices = db.raw_sql(f"""
        SELECT permno, dlycaldt AS date, dlyopen AS open_price, dlyhigh AS high_price,
               dlylow AS low_price, dlyprc AS close_price, dlyvol AS volume
        FROM crsp.dsf_v2
        WHERE permno IN ({permnos})
          AND dlycaldt BETWEEN '{PRICE_START}' AND '{PRICE_END}'
        ORDER BY permno, dlycaldt
    """)
    prices['close_price'] = prices['close_price'].abs()  # CRSP uses negative price for bid/ask midpoint

    # CRSP occasionally has gaps in open/high/low/volume on individual days even when
    # close is present. Drop rows with no close at all (unusable), then fall back to
    # close_price for any missing open/high/low, and 0 for missing volume — same
    # NOT NULL reasoning as the funda cleanup above.
    prices = prices.dropna(subset=['close_price'])
    for col in ['open_price', 'high_price', 'low_price']:
        prices[col] = prices[col].fillna(prices['close_price'])
    prices['volume'] = prices['volume'].fillna(0)

    db.close()

    # -------------------------------------------------------------
    # 5. Reshape into the same tables as schema.sql and load into
    #    a fresh SQLite file, finance_real.db.
    # -------------------------------------------------------------
    conn = sqlite3.connect("finance_real.db")
    with open("schema.sql") as f:
        conn.executescript(f.read())

    companies = link.rename(columns={'tic': 'ticker', 'conm': 'company_name'})
    companies['company_id'] = range(1, len(companies) + 1)
    companies['country'] = 'USA'
    companies['ipo_year'] = None

    # Real GICS sector classification, from Compustat's gsector code —
    # translate each company's code to its official sector name, then
    # build the sectors table from only the sectors actually present
    # (rather than inserting all 11 when you might only have 6-7 of them).
    # gsector sometimes comes back from WRDS as a float (e.g. 45.0) rather
    # than the string '45' — normalize before the dictionary lookup so
    # that doesn't silently fall through to "Unclassified" for everyone.
    companies['gsector'] = (
        companies['gsector'].astype(str).str.replace(r'\.0$', '', regex=True).str.zfill(2)
    )
    companies['sector_name'] = companies['gsector'].map(GICS_SECTORS).fillna('Unclassified')
    sector_names = sorted(companies['sector_name'].unique())
    sector_name_to_id = {name: i + 1 for i, name in enumerate(sector_names)}
    companies['sector_id'] = companies['sector_name'].map(sector_name_to_id)

    # Latest available shares outstanding (millions) per company, from Compustat's `csho`.
    # Computed BEFORE the fillna below, so a genuinely missing year doesn't get mistaken
    # for "zero shares outstanding" — we want the last real value, not the last zero.
    latest_shares = (
        funda.dropna(subset=['shares_out_m'])
        .sort_values('fyear')
        .groupby('gvkey')['shares_out_m']
        .last()
    )
    companies['shares_out_m'] = companies['gvkey'].map(latest_shares)
    # fallback for any company missing csho in the pulled window, so the insert never fails
    companies['shares_out_m'] = companies['shares_out_m'].fillna(1.0)

    # -------------------------------------------------------------
    # Real Compustat data has genuine gaps: financial companies (banks,
    # insurers — e.g. JPM, GS in the default ticker list) don't report
    # line items like COGS, inventory, or a current/non-current split
    # the way industrial companies do, so those cells come back NaN.
    # The schema requires NOT NULL, so we zero-fill anything not
    # applicable to that company rather than crash the load. This is a
    # simplification worth calling out if you're asked about it —
    # "not applicable" and "zero" aren't really the same thing for a
    # bank's inventory, but zero-filling keeps the schema consistent
    # across sectors without special-casing financial companies.
    # -------------------------------------------------------------
    funda_numeric_cols = [
        'revenue', 'cogs', 'opex', 'operating_income', 'interest_expense',
        'tax_expense', 'net_income', 'cash', 'receivables', 'inventory',
        'current_assets', 'total_assets', 'accounts_payable', 'current_liabilities',
        'long_term_debt', 'total_liabilities', 'total_equity', 'operating_cf',
        'investing_cf', 'financing_cf', 'capex', 'dividends_paid',
    ]
    funda[funda_numeric_cols] = funda[funda_numeric_cols].fillna(0)

    sectors_df = pd.DataFrame({
        'sector_id': list(sector_name_to_id.values()),
        'sector_name': list(sector_name_to_id.keys()),
    })
    sectors_df.to_sql('sectors', conn, if_exists='append', index=False)

    companies[['company_id', 'ticker', 'company_name', 'sector_id',
               'country', 'ipo_year', 'shares_out_m']].to_sql(
        'companies', conn, if_exists='append', index=False
    )

    # Cast permno to plain int on both sides before building the lookup dict —
    # one comes back as float from the link table, the other as int from CRSP,
    # and mismatched numeric types are a classic silent source of "0 rows matched".
    companies['permno'] = companies['permno'].astype(int)
    prices['permno'] = prices['permno'].astype(int)

    gvkey_to_id = dict(zip(companies['gvkey'], companies['company_id']))
    permno_to_id = dict(zip(companies['permno'], companies['company_id']))

    funda['company_id'] = funda['gvkey'].map(gvkey_to_id)
    funda['gross_profit'] = funda['revenue'] - funda['cogs']
    funda['free_cash_flow'] = funda['operating_cf'] - funda['capex']
    funda = funda.rename(columns={
        'fyear': 'fiscal_year',
        'opex': 'operating_expenses',
        'cash': 'cash_and_equivalents',
        'receivables': 'accounts_receivable',
        'operating_cf': 'operating_cash_flow',
        'investing_cf': 'investing_cash_flow',
        'financing_cf': 'financing_cash_flow',
        'capex': 'capital_expenditures',
    })

    funda[['company_id', 'fiscal_year', 'revenue', 'cogs', 'gross_profit',
           'operating_expenses', 'operating_income', 'interest_expense', 'tax_expense',
           'net_income']].to_sql('income_statement', conn, if_exists='append', index=False)

    funda[['company_id', 'fiscal_year', 'cash_and_equivalents', 'accounts_receivable', 'inventory',
           'current_assets', 'total_assets', 'accounts_payable',
           'current_liabilities', 'long_term_debt', 'total_liabilities',
           'total_equity']].to_sql('balance_sheet', conn, if_exists='append', index=False)

    funda[['company_id', 'fiscal_year', 'operating_cash_flow', 'investing_cash_flow',
           'financing_cash_flow', 'capital_expenditures', 'free_cash_flow',
           'dividends_paid']].to_sql('cash_flow_statement', conn, if_exists='append', index=False)

    prices['company_id'] = prices['permno'].map(permno_to_id)
    prices['price_date'] = prices['date'].astype(str)
    prices[['company_id', 'price_date', 'open_price', 'high_price',
            'low_price', 'close_price', 'volume']].to_sql(
        'stock_prices', conn, if_exists='append', index=False
    )

    conn.commit()
    conn.close()
    print("Done — wrote finance_real.db")


if __name__ == "__main__":
    main()
