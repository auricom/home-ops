import os
import requests
import yaml
import psycopg2
from psycopg2 import sql
from datetime import datetime

# Load configuration file
with open("config.yaml", "r") as config_file:
    config = yaml.safe_load(config_file)

# Pushover credentials
PUSHOVER_API_URL = "https://api.pushover.net/1/messages.json"
PUSHOVER_API_TOKEN = os.environ["PUSHOVER_API_TOKEN"]
PUSHOVER_USER_KEY = os.environ["PUSHOVER_USER_KEY"]

# PostgreSQL connection
conn = psycopg2.connect(
    dbname=os.environ["POSTGRES_DB"],
    user=os.environ["POSTGRES_USER"],
    password=os.environ["POSTGRES_PASS"],
    host=os.environ["POSTGRES_HOST"],
    port=os.environ.get("POSTGRES_PORT", "5432"),
)

# Create table if not exists
def create_table():
    with conn.cursor() as cursor:
        cursor.execute("""
        CREATE TABLE IF NOT EXISTS github_releases (
            repo_name VARCHAR(255) PRIMARY KEY,
            latest_release VARCHAR(255),
            release_date TIMESTAMP
        )
        """)
        conn.commit()

# Check for new release
def check_new_release(repo_name):
    response = requests.get(f"https://api.github.com/repos/{repo_name}/releases/latest")
    response.raise_for_status()
    release_data = response.json()
    return release_data["tag_name"], release_data["published_at"]

# Send pushover notification
def send_pushover_notification(repo_name, tag_name):
    payload = {
        "token": PUSHOVER_API_TOKEN,
        "user": PUSHOVER_USER_KEY,
        "message": f"New stable release {tag_name} for repository {repo_name} is available."
    }
    response = requests.post(PUSHOVER_API_URL, data=payload)
    response.raise_for_status()

# Main function
def main():
    create_table()
    for repo_name in config["repositories"]:
        latest_tag, release_date = check_new_release(repo_name)
        release_date = datetime.strptime(release_date, "%Y-%m-%dT%H:%M:%SZ")

        with conn.cursor() as cursor:
            cursor.execute("""
            INSERT INTO github_releases (repo_name, latest_release, release_date)
            VALUES (%s, %s, %s)
            ON CONFLICT (repo_name) DO UPDATE
            SET latest_release = EXCLUDED.latest_release,
                release_date = EXCLUDED.release_date
            WHERE EXCLUDED.release_date > github_releases.release_date
            RETURNING *
            """, (repo_name, latest_tag, release_date))
            result = cursor.fetchone()
            conn.commit()

            if result:
                send_pushover_notification(repo_name, latest_tag)

if __name__ == "__main__":
    main()
