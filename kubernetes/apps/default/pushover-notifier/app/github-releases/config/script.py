import os
import requests
import yaml
import psycopg2
from psycopg2 import sql
from datetime import datetime
from requests.exceptions import HTTPError

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
    try:
        response = requests.get(f"https://api.github.com/repos/{repo_name}/releases/latest")
        response.raise_for_status()
        release_data = response.json()
        return release_data["tag_name"], release_data["published_at"]
    except HTTPError as e:
        if e.response.status_code == 404:
            # Handle the case where the release is not found
            # For example, return None or check for tags instead
            return None, None
        else:
            raise

# Function to check if tag should be ignored
def should_ignore_tag(tag_name, ignore_list):
    return any(ignore_str in tag_name for ignore_str in ignore_list)

# Modified function to check for latest tag
def check_latest_tag(repo_name, ignore_list):
    response = requests.get(f"https://api.github.com/repos/{repo_name}/tags")
    response.raise_for_status()
    tags = response.json()

    for tag in tags:
        tag_name = tag["name"]
        if should_ignore_tag(tag_name, ignore_list):
            continue  # Skip this tag as it's in the ignore list

        commit_url = tag["commit"]["url"]
        commit_response = requests.get(commit_url)
        commit_response.raise_for_status()
        commit_data = commit_response.json()
        commit_date = commit_data["commit"]["committer"]["date"]

        return tag_name, commit_date

    return None, None  # No valid tags found

# Send pushover notification
def send_pushover_notification(repo_name, tag_name):
    payload = {
        "token": PUSHOVER_API_TOKEN,
        "user": PUSHOVER_USER_KEY,
        "html": "1",
        "message": f'New stable release {tag_name} for repository <a href="https://github.com/{repo_name}">{repo_name}</a> is available.'
    }
    response = requests.post(PUSHOVER_API_URL, data=payload)
    response.raise_for_status()

# Main function
def main():
    create_table()

    for repo_config in config["repositories"]:
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

        with conn.cursor() as cursor:
            print(f"Updating database for {repo_name}...")
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
                print(f"New release for {repo_name} found, sending notification.")
                send_pushover_notification(repo_name, latest_tag)
            else:
                print(f"No new release to update for {repo_name}.")

if __name__ == "__main__":
    main()
