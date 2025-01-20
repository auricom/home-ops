import logging
import os
from datetime import datetime
import requests
import yaml
from decouple import config
from requests.exceptions import HTTPError
import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT

log_level = logging.DEBUG if config("LOG_LEVEL", "") == "DEBUG" else logging.INFO

# Configuration
conf_path = "/config/config.yaml"
if not os.path.exists(conf_path):
    raise FileNotFoundError(f"Config file not found: {conf_path}")

with open(conf_path, "r") as file:
    conf = yaml.safe_load(file)

# Pushover credentials
PUSHOVER_API_URL = "https://api.pushover.net/1/messages.json"
PUSHOVER_APP_TOKEN = config("PUSHOVER_APP_TOKEN")
PUSHOVER_USER_KEY = config("PUSHOVER_USER_KEY")

# PostgreSQL connection parameters
DB_HOST = config("DB_HOST")
DB_PORT = config("DB_PORT", "5432")
DB_NAME = config("DB_NAME")
DB_USER = config("DB_USER")
DB_PASSWORD = config("DB_PASSWORD")

# Observability
healthchecks_id = config("HEALTHCHECKS_ID")

def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )

# Create table if not exists
def create_table():
    conn = get_db_connection()
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS github_releases (
                repo_name TEXT PRIMARY KEY,
                latest_release TEXT,
                release_date TIMESTAMP
            )
        """)
    conn.close()

# Check for new release
def check_new_release(repo_name):
    try:
        response = requests.get(
            f"https://api.github.com/repos/{repo_name}/releases/latest", timeout=5
        )
        response.raise_for_status()
        release_data = response.json()
        return release_data["tag_name"], release_data["published_at"]
    except HTTPError as e:
        if e.response.status_code == 404:
            return None, None
        else:
            raise

def should_ignore_tag(tag_name, ignore_list):
    return any(ignore_str in tag_name for ignore_str in ignore_list)

def check_latest_tag(repo_name, ignore_list):
    response = requests.get(f"https://api.github.com/repos/{repo_name}/tags", timeout=5)
    response.raise_for_status()
    tags = response.json()

    for tag in tags:
        tag_name = tag["name"]
        if should_ignore_tag(tag_name, ignore_list):
            continue

        commit_url = tag["commit"]["url"]
        commit_response = requests.get(commit_url, timeout=5)
        commit_response.raise_for_status()
        commit_data = commit_response.json()
        commit_date = commit_data["commit"]["committer"]["date"]

        return tag_name, commit_date

    return None, None

def send_pushover_notification(repo_name, tag_name):
    payload = {
        "token": PUSHOVER_APP_TOKEN,
        "user": PUSHOVER_USER_KEY,
        "html": "1",
        "message": f'New stable release {tag_name} for repository <a href="https://github.com/{repo_name}">{repo_name}</a> is available.',
    }
    response = requests.post(PUSHOVER_API_URL, data=payload, timeout=5, headers={'User-Agent': 'Python'})
    response.raise_for_status()

def main():
    create_table()
    conn = get_db_connection()

    try:
        for repo_config in conf["repositories"]:
            repo_name = repo_config["name"]
            check_type = repo_config.get("check", "releases")
            ignore_list = repo_config.get("ignore_tags_containing", [])

            print(f"Checking {check_type} for repository: {repo_name}")

            if check_type == "releases":
                latest_tag, release_date = check_new_release(repo_name)
                if latest_tag is None or release_date is None:
                    print(f"No release found for {repo_name}")
                    continue
            elif check_type == "tags":
                latest_tag, release_date = check_latest_tag(repo_name, ignore_list)
                if latest_tag is None or release_date is None:
                    print(f"No valid tags found for {repo_name}, moving to next repository.")
                    continue
            else:
                print(f"Invalid check type for {repo_name}: {check_type}")
                continue

            print(f"Latest tag for {repo_name}: {latest_tag}, published at: {release_date}")
            release_date = datetime.strptime(release_date, "%Y-%m-%dT%H:%M:%SZ")

            with conn.cursor() as cur:
                print(f"Updating database for {repo_name}...")
                cur.execute(
                    "SELECT release_date FROM github_releases WHERE repo_name = %s",
                    (repo_name,)
                )
                current = cur.fetchone()

                if not current or release_date > current[0]:
                    cur.execute("""
                        INSERT INTO github_releases (repo_name, latest_release, release_date)
                        VALUES (%s, %s, %s)
                        ON CONFLICT (repo_name)
                        DO UPDATE SET
                            latest_release = EXCLUDED.latest_release,
                            release_date = EXCLUDED.release_date
                    """, (repo_name, latest_tag, release_date))
                    conn.commit()

                    print(f"New release for {repo_name} found, sending notification.")
                    send_pushover_notification(repo_name, latest_tag)
                else:
                    print(f"No new release to update for {repo_name}.")

        try:
            requests.get(f"https://hc-ping.com/{healthchecks_id}", timeout=10)
        except requests.RequestException as e:
            print("Ping failed: %s" % e)

    finally:
        conn.close()

if __name__ == "__main__":
    main()
