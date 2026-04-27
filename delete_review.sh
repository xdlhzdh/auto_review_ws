#!/bin/bash

# Check if the required arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <repoName> <commitId>"
    exit 1
fi

# Assign arguments to variables
REPO_NAME=$1
COMMIT_ID=$2

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

pushd "$SCRIPT_DIR"/auto_review_ui >/dev/null || exit 1

export $(grep -v '^#' .env | xargs)

# Debugging: Print variable values
echo "REPO_NAME: $REPO_NAME"
echo "COMMIT_ID: $COMMIT_ID"

# Test SQL commands without BEGIN/COMMIT
psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -c "DELETE FROM \"ReviewFeedback\" WHERE \"repoName\" = '$REPO_NAME' AND \"commitId\" = '$COMMIT_ID';"
psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -c "DELETE FROM \"Review\" WHERE \"repoName\" = '$REPO_NAME' AND \"commitId\" = '$COMMIT_ID';"

# Check the exit status of the psql command
if [ $? -eq 0 ]; then
    echo "Successfully deleted review records for repoName='$REPO_NAME' and commitId='$COMMIT_ID'."
    popd >/dev/null || exit 1
    exit 0
else
    echo "Failed to delete review records. Please check the database connection and input parameters."
    popd >/dev/null || exit 1
    exit 1
fi
