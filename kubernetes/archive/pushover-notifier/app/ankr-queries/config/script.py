import requests
import psycopg2
import yaml
import os
import json

# Load configuration
with open("config.yaml", "r") as f:
    config = yaml.safe_load(f)

# Pushover credentials
PUSHOVER_API_URL = "https://api.pushover.net/1/messages.json"
PUSHOVER_API_TOKEN = os.environ["PUSHOVER_API_TOKEN"]
PUSHOVER_USER_KEY = os.environ["PUSHOVER_USER_KEY"]

# PostgreSQL connection
connection = psycopg2.connect(
    dbname=os.environ["POSTGRES_DB"],
    user=os.environ["POSTGRES_USER"],
    password=os.environ["POSTGRES_PASS"],
    host=os.environ["POSTGRES_HOST"],
    port=os.environ.get("POSTGRES_PORT", "5432"),
)
cursor = connection.cursor()

# Create the database structure
cursor.execute("""
CREATE TABLE IF NOT EXISTS ankr_queries_transactions (
    id SERIAL PRIMARY KEY,
    address VARCHAR NOT NULL,
    tx_hash VARCHAR NOT NULL,
    blockchain VARCHAR NOT NULL,
    timestamp VARCHAR NOT NULL
);
""")
connection.commit()


# Send notification using Pushover
def send_pushover_notification(title, message):
    payload = {
        'token': PUSHOVER_API_TOKEN,
        'user': PUSHOVER_USER_KEY,
        'html': 1,
        'title': title,
        'message': message
    }
    response = requests.post(PUSHOVER_API_URL, data=payload)
    response.raise_for_status()

# Process new transactions
def process_new_transactions(address, memo):

    url = "https://rpc.ankr.com/multichain/?ankr_getTransactionsByAddress"
    headers = {"Content-Type": "application/json"}
    payload = {
      "id": 1,
      "jsonrpc": "2.0",
      "method": "ankr_getTransactionsByAddress",
      "params": {
          "address": f"{address}",
          "descOrder": True
      }
    }
    response = requests.post(url, headers=headers, data=json.dumps(payload))
    if response.status_code != 200:
        print(f"Failed to fetch transactions: {response.text}")
        return

    for tx in response.json()["result"]["transactions"]:
        tx_hash = tx['hash']
        timestamp = tx['timestamp']
        blockchain = tx['blockchain']

        cursor.execute("""
        SELECT COUNT(*) FROM ankr_queries_transactions WHERE address=%s AND tx_hash=%s AND blockchain=%s;
        """, (address, tx_hash, blockchain))
        exists = cursor.fetchone()[0]

        if not exists:
            cursor.execute("""
            INSERT INTO ankr_queries_transactions (address, tx_hash, blockchain, timestamp)
            VALUES (%s, %s, %s, %s);
            """, (address, tx_hash, blockchain, timestamp))
            connection.commit()

            send_pushover_notification(
                f"New Transaction: {memo}",
                f"Transaction Hash: <a href=\"http://www.debank.com/profile/{address}/history\">{tx_hash}</a><br>Blockchain: {blockchain}<br>Timestamp: {timestamp}"
            )

# Main function
def main():
    for entry in config["addresses"]:
        address = entry["address"]
        memo = entry["memo"]
        process_new_transactions(address, memo)

if __name__ == "__main__":
    main()
