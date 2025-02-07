# ---------------------------
# Author: vijay.venkatachalam@traceable.ai
# ---------------------------

#!/bin/bash

# ---------------------------
# Part 1: Clean up roles before publishing
# ---------------------------

# Input variables for role management
CLIENT_ID="EnterYourclientId"
CLIENT_SECRET="EnterYourclientSecret"
ORG_ID="EnterYourOrgID"
USER_ID="EnterYourUserID"

# Log directory and timestamp
LOG_DIR="/home/ec2-user/Mulesoft/logs"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOG_DIR}/dev-publish-job_${TIMESTAMP}.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Start logging
log "Combined script started."

# Fetch ACCESS_TOKEN dynamically
log "Fetching access token..."
ACCESS_TOKEN=$(curl -s -w "\n%{http_code}" --location --request POST 'https://anypoint.mulesoft.com/accounts/api/v2/oauth2/token' \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "client_secret=$CLIENT_SECRET" \
    --data-urlencode 'grant_type=client_credentials')

# Extract the response body and status code
ACCESS_TOKEN_BODY=$(echo "$ACCESS_TOKEN" | sed '$d')
ACCESS_TOKEN_STATUS=$(echo "$ACCESS_TOKEN" | tail -n1)

if [[ "$ACCESS_TOKEN_STATUS" -ne 200 ]]; then
    log "Error: Failed to fetch access token. HTTP Status: $ACCESS_TOKEN_STATUS. Response: $ACCESS_TOKEN_BODY"
    exit 1
fi

# Extract the access token
ACCESS_TOKEN=$(echo "$ACCESS_TOKEN_BODY" | jq -r ".access_token")

if [[ -z "$ACCESS_TOKEN" ]]; then
    log "Error: Access token is empty. Response: $ACCESS_TOKEN_BODY"
    exit 1
fi
log "Access token retrieved successfully."

# Base API URL
BASE_URL="https://anypoint.mulesoft.com/accounts/api/organizations/$ORG_ID"

# Fetch total number of roles
log "Fetching total number of roles for user ID: $USER_ID..."
ROLES_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/users/$USER_ID/roles?offset=0&limit=1" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json")

ROLES_BODY=$(echo "$ROLES_RESPONSE" | sed '$d')
ROLES_STATUS=$(echo "$ROLES_RESPONSE" | tail -n1)

if [[ "$ROLES_STATUS" -ne 200 ]]; then
    log "Error: Failed to fetch roles. HTTP Status: $ROLES_STATUS. Response: $ROLES_BODY"
    exit 1
fi

NUMBER_OF_ROLES=$(echo "$ROLES_BODY" | jq -r '.total')

if [[ -z "$NUMBER_OF_ROLES" || "$NUMBER_OF_ROLES" -eq 0 ]]; then
    log "Error: No roles found for user ID: $USER_ID. Response: $ROLES_BODY"
    exit 1
fi
log "Total number of roles: $NUMBER_OF_ROLES."

# Calculate number of loops
LIMIT=100
NUMBER_OF_LOOPS=$(( (NUMBER_OF_ROLES + LIMIT - 1) / LIMIT ))

# Role deletion counters
ASSET_ADMIN_COUNT=0
PROJECT_ADMIN_COUNT=0

# Iterate through roles
for ((i=0; i<NUMBER_OF_LOOPS; i++)); do
  OFFSET=$((i * LIMIT))
  
  # Fetch roles
  log "Fetching roles batch (offset: $OFFSET, limit: $LIMIT)..."
  ROLES_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/users/$USER_ID/roles?offset=$OFFSET&limit=$LIMIT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json")

  ROLES_BODY=$(echo "$ROLES_RESPONSE" | sed '$d')
  ROLES_STATUS=$(echo "$ROLES_RESPONSE" | tail -n1)

  if [[ "$ROLES_STATUS" -ne 200 ]]; then
      log "Error: Failed to fetch roles. HTTP Status: $ROLES_STATUS. Response: $ROLES_BODY"
      exit 1
  fi

  log "Roles fetched successfully. HTTP Status: $ROLES_STATUS."

  # Parse roles and check for Asset Administrator and Project Administrator
  echo "$ROLES_BODY" | jq -c '.data[]' | while read -r ROLE; do
    ROLE_NAME=$(echo "$ROLE" | jq -r '.name')
    ROLE_ID=$(echo "$ROLE" | jq -r '.role_id')
    
    if [[ "$ROLE_NAME" == "Asset Administrator" && $ASSET_ADMIN_COUNT -lt 1 ]]; then
      DELETE_URL="$BASE_URL/users/$USER_ID/roles/$ROLE_ID"
      log "Deleting Asset Administrator role: $DELETE_URL."
      DELETE_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "$DELETE_URL" \
        -H "Authorization: Bearer $ACCESS_TOKEN")
      
      DELETE_STATUS=$(echo "$DELETE_RESPONSE" | tail -n1)
      if [[ "$DELETE_STATUS" -eq 200 ]]; then
          log "Asset Administrator role deleted successfully."
      else
          log "Error: Failed to delete Asset Administrator role. HTTP Status: $DELETE_STATUS."
      fi
      ASSET_ADMIN_COUNT=$((ASSET_ADMIN_COUNT + 1))
    fi
    
    if [[ "$ROLE_NAME" == "Project Administrator" && $PROJECT_ADMIN_COUNT -lt 1 ]]; then
      DELETE_URL="$BASE_URL/users/$USER_ID/roles/$ROLE_ID"
      log "Deleting Project Administrator role: $DELETE_URL."
      DELETE_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "$DELETE_URL" \
        -H "Authorization: Bearer $ACCESS_TOKEN")
      
      DELETE_STATUS=$(echo "$DELETE_RESPONSE" | tail -n1)
      if [[ "$DELETE_STATUS" -eq 200 ]]; then
          log "Project Administrator role deleted successfully."
      else
          log "Error: Failed to delete Project Administrator role. HTTP Status: $DELETE_STATUS."
      fi
      PROJECT_ADMIN_COUNT=$((PROJECT_ADMIN_COUNT + 1))
    fi
    
    if [[ $ASSET_ADMIN_COUNT -ge 1 && $PROJECT_ADMIN_COUNT -ge 1 ]]; then
      log "Both target roles deleted. Exiting loop."
      break 2
    fi
  done
done

log "Role management script completed."

# ---------------------------
# Part 2: Publish assets script
# ---------------------------

log "Starting asset publishing process..."

# Kill any existing Java process running the integration JAR
log "Checking for existing Java processes..."
EXISTING_PID=$(pgrep -f "integrations-mulesoft")
if [ -n "$EXISTING_PID" ]; then
  log "Found existing Java processes with PIDs: $EXISTING_PID. Terminating each..."
  for PID in $EXISTING_PID; do
    log "Terminating process with PID: $PID"
    kill -9 "$PID"
    log "Process with PID: $PID terminated."
  done
else
  log "No existing Java processes found."
fi

# Start the new Java process and output logs
log "Starting new Java process..."
nohup java -Dspring.config.additional-location=file:/home/ec2-user/Mulesoft/application-dev.yml -Dmanagement.server.port=8081 -jar /home/ec2-user/Mulesoft/integrations-mulesoft-0.1.66.jar >> "$LOG_FILE" 2>&1 &
log "Java process started with nohup. Logs are being written to $LOG_FILE"

log "Combined script completed successfully.
