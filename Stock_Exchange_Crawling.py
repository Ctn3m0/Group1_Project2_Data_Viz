import requests
from bs4 import BeautifulSoup
import pandas as pd
from tqdm import tqdm
from tenacity import retry, stop_after_attempt, wait_exponential
import time
import itertools
import yfinance as yf

# Function to fetch currency codes (we'll scrape XE.com for available currencies)
def get_currency_codes():
    url = 'https://www.xe.com/currency/'
    response = requests.get(url)

    if response.status_code != 200:
        print("Failed to fetch currency codes.")
        return []

    soup = BeautifulSoup(response.text, 'html.parser')
    
    # Find all span elements with class "currencyCode"
    currency_spans = soup.find_all('span', class_='currencyCode')
    
    currency_codes = []
    for span in currency_spans:
        text = span.get_text(strip=True)
        code = text.split('-')[0].strip()  # get part before "-" and strip whitespace
        currency_codes.append(code)
    
    return currency_codes

# Fetch all available currency codes
currency_codes = get_currency_codes()

def get_usd_currency_history(to_currency, start_date, end_date):
    if to_currency == 'USD':
        return None  # Skip USD to USD
    ticker = f"USD{to_currency}=X"
    try:
        data = yf.download(ticker, start=start_date, end=end_date, progress=False)
        if not data.empty:
            # Remove the multi-level column if it exists
            if isinstance(data.columns, pd.MultiIndex):
                data.columns = data.columns.get_level_values(0)
            
            data = data.reset_index()  # Reset index so Date becomes a column
            data['currency_pair'] = f"USD/{to_currency}"  # Add the currency pair
            return data
        else:
            print(f"No data for {ticker}")
            return None
    except Exception as e:
        print(f"Failed to fetch {ticker}: {e}")
        return None

# Collect data
all_data = []

for to_curr in currency_codes:
    print(f"Fetching USD to {to_curr}...")
    data = get_usd_currency_history(to_curr, start_date='2024-08-20', end_date='2025-04-24')
    if data is not None:
        all_data.append(data)

# Merge all into a single dataframe
if all_data:
    final_df = pd.concat(all_data, axis=0)  # Vertically
    print(final_df.head())
    final_df.to_csv('usd_currency_pairs_history.csv', index=False)
else:
    print("No data collected.")


# Fetching stock data from Yahoo Finance
df_stock_ticker = pd.read_csv('nasdaq_screener_1745716292474.csv') #https://www.nasdaq.com/market-activity/stocks/screener
df_stock_ticker.head()

df_stock_ticker.shape

start_date = "2024-08-20"
end_date = "2025-04-24"

df_list = []  # List to store data for each ticker

tickers = df_stock_ticker['Symbol'].tolist()

for ticker in tickers:
    try:
        # Fetch historical data from Yahoo Finance
        stock_data = yf.download(ticker, start=start_date, end=end_date)
        
        # Add the 'symbol' column (for merging later)
        stock_data['Symbol'] = ticker
        
        # Check and remove multi-level columns (if they exist)
        if isinstance(stock_data.columns, pd.MultiIndex):
            stock_data.columns = stock_data.columns.get_level_values(0)

        stock_data = stock_data.reset_index()
        
        # Add the stock data to the list (without ticker header)
        df_list.append(stock_data)
        
    except Exception as e:
        print(f"Error fetching data for {ticker}: {e}")

df_combined = pd.concat(df_list, axis=0)
df_combined = df_combined.drop(columns=['Adj Close'])
df_combined.head(5)

df_stock_ticker = df_stock_ticker[['Name', 'Symbol', 'Sector', 'Market Cap', 'Country', 'Industry']]
df_stock_ticker.head(5)

df_stock_final = pd.merge(df_combined, df_stock_ticker, on='Symbol', how='inner')
df_stock_final.head(5)

df_stock_final.shape

df_stock_final.to_csv('stock_data.csv', index = False)

df_stock_final['Country'].nunique()