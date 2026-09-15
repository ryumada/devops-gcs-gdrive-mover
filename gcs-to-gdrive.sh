#!/usr/bin/env bash
set -e
# Category: Cloud Storage & Migration Utility
# Description: Moves data from Google Cloud Storage to Google Drive using programmatic Service Account authentication.
# Usage: ./gcs-to-gdrive.sh --source gs://bucket/path/ [OPTIONS]
# Dependencies: bash, curl, openssl, sed, grep, awk, tr, dd (jq optional)

# --- Path & Environment Detection ---
CURRENT_DIR=$(dirname "$(readlink -f "$0")")
ENV_FILE="$CURRENT_DIR/.env"

# --- Logging Functions & Colors ---
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[0;34m"
readonly COLOR_SUCCESS="\033[0;32m"
readonly COLOR_WARN="\033[1;33m"
readonly COLOR_ERROR="\033[0;31m"

log() {
  local color="$1"
  local emoji="$2"
  local message="$3"
  echo -e "${color}[$(date +"%Y-%m-%d %H:%M:%S")] ${emoji} ${message}${COLOR_RESET}" >&2
}

log_info() { log "${COLOR_INFO}" "ℹ️" "$1"; }
log_success() { log "${COLOR_SUCCESS}" "✅" "$1"; }
log_warn() { log "${COLOR_WARN}" "⚠️" "$1"; }
log_error() { log "${COLOR_ERROR}" "❌" "$1"; }

# --- Load Default Configuration from .env ---
load_env_val() {
  local key="$1"
  if [ -f "$ENV_FILE" ]; then
    grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//' || true
  fi
}

# --- Resolve Relative Paths for Files ---
resolve_file_path() {
  local p="$1"
  if [ -n "$p" ] && [[ "$p" != /* ]] && [ ! -f "$p" ]; then
    if [ -f "$CURRENT_DIR/$p" ]; then
      echo "$CURRENT_DIR/$p"
      return
    fi
  fi
  echo "$p"
}

# Default values & state
DEFAULT_CHUNK_SIZE=26214400 # 25 MiB (100 * 256 KiB)
GCS_SOURCE_URI=""
GCS_SERVICE_ACCOUNT_KEY="${GCS_SERVICE_ACCOUNT_KEY:-}"
GDRIVE_SERVICE_ACCOUNT_KEY="${GDRIVE_SERVICE_ACCOUNT_KEY:-}"
GCS_ACCESS_TOKEN="${GCS_ACCESS_TOKEN:-}"
GDRIVE_ACCESS_TOKEN="${GDRIVE_ACCESS_TOKEN:-}"
GDRIVE_FOLDER_ID="${GDRIVE_FOLDER_ID:-}"
GDRIVE_CHUNK_SIZE="${GDRIVE_CHUNK_SIZE:-$DEFAULT_CHUNK_SIZE}"
TEMP_DIR="${TEMP_DIR:-/tmp}"
KEEP_SOURCE="${KEEP_SOURCE:-false}"
DRY_RUN=false
CUSTOM_REMOTE_NAME=""

# Cached tokens and expirations
GCS_TOKEN_VALUE=""
GCS_TOKEN_EXPIRY=0
GDRIVE_TOKEN_VALUE=""
GDRIVE_TOKEN_EXPIRY=0

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [GCS_SOURCE_URI]

Transfers or moves files/folders from Google Cloud Storage to Google Drive using
programmatic Service Account authentication (generating RS256 JWT bearer tokens).

Arguments:
  GCS_SOURCE_URI               Source in GCS (e.g. gs://my-bucket/file.tar.gz or gs://my-bucket/prefix/)

Options:
  -s, --source <URI>           Source GCS URI (alternative to positional argument)
  -d, --folder-id <ID>         Target Google Drive Folder ID
  --gcs-sa-key <PATH>          Path to GCS Service Account JSON key file
  --gdrive-sa-key <PATH>       Path to Google Drive Service Account JSON key file
  --gcs-token <TOKEN>          Direct GCS OAuth2 Bearer Access Token (bypasses SA key)
  --gdrive-token <TOKEN>       Direct GDrive OAuth2 Bearer Access Token (bypasses SA key)
  --chunk-size <BYTES>         Resumable upload chunk size (multiple of 256 KiB, default: 26214400 / 25 MiB)
  --name <FILENAME>            Custom target filename on Google Drive (single file only)
  --keep-source, --copy-only   Retain source file(s) in GCS (default behavior is to MOVE/delete from GCS)
  --temp-dir <PATH>            Local temporary storage directory (default: /tmp)
  --dry-run                    Simulate operations without downloading, uploading, or deleting
  -h, --help                   Show this help message

Examples:
  # Move a single file from GCS to Google Drive:
  ./gcs-to-gdrive.sh gs://my-backup-bucket/daily/backup.tar.zst --folder-id "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs7"

  # Copy without deleting source from GCS:
  ./gcs-to-gdrive.sh gs://my-backup-bucket/logs/ --keep-source

  # Specify SA keys and 25 MiB chunks via CLI:
  ./gcs-to-gdrive.sh gs://my-bucket/archive.zip \\
    --gcs-sa-key ./secrets/gcs-sa.json \\
    --gdrive-sa-key ./secrets/gdrive-sa.json \\
    --folder-id "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs7"
EOF
}

# --- URL Encoding Helper ---
url_encode() {
  local string="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg x "$string" '$x|@uri'
  else
    local strlen=${#string}
    local encoded=""
    local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
      c="${string:$pos:1}"
      case "$c" in
        [-_.~a-zA-Z0-9] ) o="$c" ;;
        * ) printf -v o '%%%02X' "'$c" ;;
      esac
      encoded+="$o"
    done
    echo "$encoded"
  fi
}

# --- Programmatic OAuth2 Token Generation via Service Account JWT ---
generate_bearer_token_from_sa() {
  local sa_input="$1"
  local scope="$2"
  local sa_json_content=""

  if [ -f "$sa_input" ]; then
    sa_json_content=$(cat "$sa_input")
  elif [[ "$sa_input" =~ ^\{.*\}$ ]]; then
    sa_json_content="$sa_input"
  else
    log_error "Service Account key file or content '$sa_input' not found."
    return 1
  fi

  local client_email token_uri key_pem
  if command -v jq >/dev/null 2>&1; then
    client_email=$(echo "$sa_json_content" | jq -r '.client_email // empty')
    token_uri=$(echo "$sa_json_content" | jq -r '.token_uri // empty')
    key_pem=$(echo "$sa_json_content" | jq -r '.private_key // empty')
  else
    client_email=$(echo "$sa_json_content" | grep -o '"client_email": *"[^"]*"' | cut -d'"' -f4)
    token_uri=$(echo "$sa_json_content" | grep -o '"token_uri": *"[^"]*"' | cut -d'"' -f4)
    key_pem=$(echo "$sa_json_content" | grep -o '"private_key": *"[^"]*"' | sed 's/^"private_key": *"//;s/"$//')
  fi

  [ -z "$token_uri" ] && token_uri="https://oauth2.googleapis.com/token"

  if [ -z "$client_email" ] || [ -z "$key_pem" ]; then
    log_error "Could not extract client_email or private_key from Service Account JSON: $sa_input"
    return 1
  fi

  local b64url_cmd='openssl base64 -e -A | tr "+/" "-_" | tr -d "="'
  local now exp header_b64 claims claims_b64 unsigned_jwt sig_b64 jwt
  now=$(date +%s)
  exp=$((now + 3600))

  header_b64=$(echo -n '{"alg":"RS256","typ":"JWT"}' | eval "$b64url_cmd")
  claims="{\"iss\":\"$client_email\",\"scope\":\"$scope\",\"aud\":\"$token_uri\",\"exp\":$exp,\"iat\":$now}"
  claims_b64=$(echo -n "$claims" | eval "$b64url_cmd")

  unsigned_jwt="${header_b64}.${claims_b64}"

  # Sign using OpenSSL RSA-SHA256
  # Use printf '%b' to accurately interpret escaped newlines in PEM
  sig_b64=$(printf "%s" "$unsigned_jwt" | openssl dgst -sha256 -sign <(printf '%b' "$key_pem") -binary 2>/dev/null | eval "$b64url_cmd")

  if [ -z "$sig_b64" ]; then
    log_error "Failed to sign Service Account JWT with openssl."
    return 1
  fi

  jwt="${unsigned_jwt}.${sig_b64}"

  local token_response
  token_response=$(curl -s -X POST \
    -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion=$jwt" \
    "$token_uri")

  local token
  if command -v jq >/dev/null 2>&1; then
    token=$(echo "$token_response" | jq -r '.access_token // empty')
  else
    token=$(echo "$token_response" | grep -o '"access_token": *"[^"]*"' | cut -d'"' -f4)
  fi

  if [ -z "$token" ]; then
    log_error "OAuth2 token request failed."
    log_error "Response: $token_response"
    return 1
  fi

  echo "$token"
}

# --- Token Management with In-Memory Caching ---
get_gcs_token() {
  local force="${1:-false}"
  if [ -n "$GCS_ACCESS_TOKEN" ]; then
    echo "$GCS_ACCESS_TOKEN"
    return 0
  fi

  local now
  now=$(date +%s)
  if [ "$force" != "true" ] && [ -n "$GCS_TOKEN_VALUE" ] && [ "$now" -lt "$((GCS_TOKEN_EXPIRY - 120))" ]; then
    echo "$GCS_TOKEN_VALUE"
    return 0
  fi

  if [ -z "$GCS_SERVICE_ACCOUNT_KEY" ]; then
    log_error "GCS authentication missing. Please provide GCS_SERVICE_ACCOUNT_KEY in .env or via --gcs-sa-key."
    return 1
  fi

  log_info "Acquiring GCS bearer token programmatically..."
  local new_token
  new_token=$(generate_bearer_token_from_sa "$GCS_SERVICE_ACCOUNT_KEY" "https://www.googleapis.com/auth/devstorage.read_write")
  if [ -z "$new_token" ]; then
    return 1
  fi

  GCS_TOKEN_VALUE="$new_token"
  GCS_TOKEN_EXPIRY=$((now + 3600))
  echo "$GCS_TOKEN_VALUE"
}

get_gdrive_token() {
  local force="${1:-false}"
  if [ -n "$GDRIVE_ACCESS_TOKEN" ]; then
    echo "$GDRIVE_ACCESS_TOKEN"
    return 0
  fi

  local now
  now=$(date +%s)
  if [ "$force" != "true" ] && [ -n "$GDRIVE_TOKEN_VALUE" ] && [ "$now" -lt "$((GDRIVE_TOKEN_EXPIRY - 120))" ]; then
    echo "$GDRIVE_TOKEN_VALUE"
    return 0
  fi

  if [ -z "$GDRIVE_SERVICE_ACCOUNT_KEY" ]; then
    log_error "Google Drive authentication missing. Please provide GDRIVE_SERVICE_ACCOUNT_KEY in .env or via --gdrive-sa-key."
    return 1
  fi

  log_info "Acquiring Google Drive bearer token programmatically..."
  local new_token
  new_token=$(generate_bearer_token_from_sa "$GDRIVE_SERVICE_ACCOUNT_KEY" "https://www.googleapis.com/auth/drive")
  if [ -z "$new_token" ]; then
    return 1
  fi

  GDRIVE_TOKEN_VALUE="$new_token"
  GDRIVE_TOKEN_EXPIRY=$((now + 3600))
  echo "$GDRIVE_TOKEN_VALUE"
}

# --- Parse GCS URI ---
parse_gcs_uri() {
  local uri="$1"
  local without_proto="${uri#gs://}"
  local bucket="${without_proto%%/*}"
  local path="${without_proto#*/}"
  if [ "$bucket" = "$without_proto" ]; then
    path=""
  fi
  echo "$bucket|$path"
}

# --- GCS REST Operations ---
get_gcs_object_metadata() {
  local bucket="$1"
  local object="$2"
  local token="$3"

  [ -z "$token" ] && return 1

  local encoded_object
  encoded_object=$(url_encode "$object")

  local response
  response=$(curl -s -G \
    -H "Authorization: Bearer $token" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}/o/${encoded_object}")

  if echo "$response" | grep -q '"error":'; then
    log_error "GCS API error while inspecting gs://${bucket}/${object}:"
    log_error "$response"
    return 1
  fi

  local size contentType md5
  if command -v jq >/dev/null 2>&1; then
    size=$(echo "$response" | jq -r '.size // empty')
    contentType=$(echo "$response" | jq -r '.contentType // "application/octet-stream"')
    md5=$(echo "$response" | jq -r '.md5Hash // empty')
  else
    size=$(echo "$response" | grep -o '"size": *"[^"]*"' | cut -d'"' -f4)
    contentType=$(echo "$response" | grep -o '"contentType": *"[^"]*"' | cut -d'"' -f4)
    md5=$(echo "$response" | grep -o '"md5Hash": *"[^"]*"' | cut -d'"' -f4)
    [ -z "$contentType" ] && contentType="application/octet-stream"
  fi

  echo "${size}|${contentType}|${md5}"
}

list_gcs_objects() {
  local bucket="$1"
  local prefix="$2"
  local token="$3"

  [ -z "$token" ] && return 1

  local page_token=""
  while :; do
    local encoded_prefix
    encoded_prefix=$(url_encode "$prefix")
    local url="https://storage.googleapis.com/storage/v1/b/${bucket}/o?prefix=${encoded_prefix}"
    if [ -n "$page_token" ]; then
      local encoded_page_token
      encoded_page_token=$(url_encode "$page_token")
      url="${url}&pageToken=${encoded_page_token}"
    fi

    local response
    response=$(curl -s -H "Authorization: Bearer $token" "$url")

    if echo "$response" | grep -q '"error":'; then
      log_error "GCS API error while listing gs://${bucket}/${prefix}:"
      log_error "$response"
      return 1
    fi

    if command -v jq >/dev/null 2>&1; then
      echo "$response" | jq -r '.items[]? | select(.name | endswith("/") | not) | .name'
      page_token=$(echo "$response" | jq -r '.nextPageToken // empty')
    else
      echo "$response" | grep -o '"name": *"[^"]*"' | cut -d'"' -f4 | grep -v '/$' || true
      page_token=$(echo "$response" | grep -o '"nextPageToken": *"[^"]*"' | cut -d'"' -f4 || true)
    fi

    [ -z "$page_token" ] && break
  done
}

download_gcs_object() {
  local bucket="$1"
  local object="$2"
  local destination="$3"
  local token="$4"

  [ -z "$token" ] && return 1

  local encoded_object
  encoded_object=$(url_encode "$object")

  local http_status
  http_status=$(curl -s -w "%{http_code}" -o "$destination" \
    -H "Authorization: Bearer $token" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}/o/${encoded_object}?alt=media")

  if [ "$http_status" -ne 200 ]; then
    log_error "Failed to download gs://${bucket}/${object} from GCS (HTTP $http_status)."
    rm -f "$destination" 2>/dev/null || true
    return 1
  fi
  return 0
}

delete_gcs_object() {
  local bucket="$1"
  local object="$2"
  local token="$3"

  [ -z "$token" ] && return 1

  local encoded_object
  encoded_object=$(url_encode "$object")

  local http_status
  http_status=$(curl -s -w "%{http_code}" -X DELETE \
    -H "Authorization: Bearer $token" \
    "https://storage.googleapis.com/storage/v1/b/${bucket}/o/${encoded_object}")

  if [ "$http_status" -ne 204 ] && [ "$http_status" -ne 200 ]; then
    log_error "Failed to delete gs://${bucket}/${object} from GCS (HTTP $http_status)."
    return 1
  fi
  return 0
}

# --- Google Drive Resumable Chunked Upload ---
upload_file_to_gdrive() {
  local local_file="$1"
  local remote_name="$2"
  local folder_id="$3"
  local chunk_size="$4"
  local mime_type="$5"
  local token="$6"

  # Fallback to acquiring a fresh token if not provided
  if [ -z "$token" ]; then
    token=$(get_gdrive_token "true")
    if [ -z "$token" ]; then
      log_error "Failed to acquire Google Drive bearer token for upload."
      return 1
    fi
  fi

  local file_size
  file_size=$(wc -c < "$local_file" | tr -d ' ')
  [ -z "$mime_type" ] && mime_type="application/octet-stream"

  log_info "Initiating Google Drive resumable upload for '$remote_name' ($file_size bytes, chunk: $((chunk_size / 1024 / 1024)) MiB)..."
  [ -n "$folder_id" ] && log_info "Target Folder ID: $folder_id"

  # Construct upload metadata
  local metadata="{\"name\": \"$remote_name\""
  if [ -n "$folder_id" ]; then
    metadata="$metadata, \"parents\": [\"$folder_id\"]"
  fi
  metadata="$metadata}"

  local init_response
  init_response=$(curl -s -i -X POST \
    -H "Authorization: Bearer $token" \
    -H "X-Upload-Content-Type: $mime_type" \
    -H "X-Upload-Content-Length: $file_size" \
    -H "Content-Type: application/json; charset=UTF-8" \
    -d "$metadata" \
    "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true")

  local session_uri
  session_uri=$(echo "$init_response" | grep -i "^location:" | tr -d '\r' | awk '{print $2}')

  if [ -z "$session_uri" ]; then
    log_error "Failed to initiate Google Drive upload session."
    log_error "Response: $init_response"
    return 1
  fi

  # Handle 0-byte file edge case
  if [ "$file_size" -eq 0 ]; then
    local zero_res zero_status
    zero_res=$(curl -s -w "\n%{http_code}" -X PUT \
      -H "Content-Length: 0" \
      -H "Content-Range: bytes */0" \
      "$session_uri")
    zero_status=$(echo "$zero_res" | tail -n1)
    if [ "$zero_status" -eq 200 ] || [ "$zero_status" -eq 201 ]; then
      log_success "Uploaded empty file '$remote_name' to Google Drive."
      return 0
    else
      log_error "Failed to upload 0-byte file (HTTP $zero_status)."
      return 1
    fi
  fi

  local start_byte=0
  local chunk_index=0
  local max_retries=5
  local retry_count=0
  local uploaded_file_id=""

  while [ "$start_byte" -lt "$file_size" ]; do
    local end_byte=$((start_byte + chunk_size - 1))
    if [ "$end_byte" -ge "$file_size" ]; then
      end_byte=$((file_size - 1))
    fi

    local current_chunk_len=$((end_byte - start_byte + 1))
    local pct=$(( (end_byte + 1) * 100 / file_size ))

    log_info "Uploading bytes ${start_byte}-${end_byte}/${file_size} (${pct}%)..."

    local http_response http_status response_body
    http_response=$( (dd if="$local_file" bs="$chunk_size" skip="$chunk_index" count=1 status=none | \
      curl -s -w "\n%{http_code}" -X PUT \
        -H "Content-Length: $current_chunk_len" \
        -H "Content-Range: bytes ${start_byte}-${end_byte}/${file_size}" \
        --data-binary @- \
        "$session_uri") 2>/dev/null || true )

    http_status=$(echo "$http_response" | tail -n1)
    response_body=$(echo "$http_response" | sed '$d')

    if [ "$http_status" -eq 308 ]; then
      start_byte=$((end_byte + 1))
      chunk_index=$((chunk_index + 1))
      retry_count=0
    elif [ "$http_status" -eq 200 ] || [ "$http_status" -eq 201 ]; then
      if command -v jq >/dev/null 2>&1; then
        uploaded_file_id=$(echo "$response_body" | jq -r '.id // empty')
      else
        uploaded_file_id=$(echo "$response_body" | grep -o '"id": *"[^"]*"' | cut -d'"' -f4)
      fi
      break
    else
      retry_count=$((retry_count + 1))
      log_warn "Chunk upload failed (HTTP $http_status). Retry $retry_count of $max_retries in 5s..."
      if [ "$retry_count" -ge "$max_retries" ]; then
        log_error "Max retries reached for chunk. Upload aborted."
        return 1
      fi
      sleep 5

      # Query session for current uploaded byte offset
      local status_check range_header
      status_check=$(curl -s -i -X PUT \
        -H "Content-Range: bytes */$file_size" \
        "$session_uri" || true)

      range_header=$(echo "$status_check" | grep -i "^range:" | tr -d '\r')
      if [ -n "$range_header" ]; then
        local last_byte
        last_byte=$(echo "$range_header" | awk -F'-' '{print $2}')
        if [ -n "$last_byte" ] && [[ "$last_byte" =~ ^[0-9]+$ ]]; then
          start_byte=$((last_byte + 1))
          chunk_index=$((start_byte / chunk_size))
          log_info "Resuming upload from byte $start_byte."
        fi
      fi
    fi
  done

  if [ -z "$uploaded_file_id" ]; then
    log_error "Upload finished without returning a valid Google Drive file ID."
    return 1
  fi

  log_success "Uploaded '$remote_name' successfully to Google Drive (ID: $uploaded_file_id)"
  echo "$uploaded_file_id"
}

_safe_name() {
  echo "$1" | tr '/:' '__'
}

# --- Single Object Transfer Handler ---
transfer_single_object() {
  local bucket="$1"
  local object="$2"
  local remote_name="$3"
  local gcs_token="$4"
  local gdrive_token="$5"

  local target_name="$remote_name"
  [ -z "$target_name" ] && target_name=$(basename "$object")

  log_info "Inspecting gs://${bucket}/${object}..."
  local meta
  meta=$(get_gcs_object_metadata "$bucket" "$object" "$gcs_token")
  if [ -z "$meta" ]; then
    if [ "$DRY_RUN" = true ]; then
      log_warn "[DRY-RUN] Could not retrieve live metadata for gs://${bucket}/${object}. Simulating with estimated size."
      meta="0|application/octet-stream|simulated"
    else
      log_error "Could not retrieve metadata for gs://${bucket}/${object}."
      return 1
    fi
  fi

  local gcs_size gcs_mime gcs_md5
  gcs_size=$(echo "$meta" | cut -d'|' -f1)
  gcs_mime=$(echo "$meta" | cut -d'|' -f2)
  gcs_md5=$(echo "$meta" | cut -d'|' -f3)

  log_info "Source: gs://${bucket}/${object} (Size: $gcs_size bytes, Type: $gcs_mime)"

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Would download gs://${bucket}/${object} ($gcs_size bytes)"
    log_info "[DRY-RUN] Would upload to Google Drive as '$target_name' in folder '$GDRIVE_FOLDER_ID'"
    if [ "$KEEP_SOURCE" = true ]; then
      log_info "[DRY-RUN] Would retain gs://${bucket}/${object} in GCS (--keep-source)"
    else
      log_info "[DRY-RUN] Would delete gs://${bucket}/${object} from GCS after upload"
    fi
    return 0
  fi

  mkdir -p "$TEMP_DIR"
  local local_temp_file
  local_temp_file="${TEMP_DIR}/gcs_move_$(_safe_name "$bucket")_$(_safe_name "$object")_$$"

  # Trap cleanup on unexpected exit
  trap 'rm -f "$local_temp_file" 2>/dev/null || true' EXIT

  log_info "Downloading gs://${bucket}/${object} to local buffer ($local_temp_file)..."
  if ! download_gcs_object "$bucket" "$object" "$local_temp_file" "$gcs_token"; then
    log_error "Download failed for gs://${bucket}/${object}."
    rm -f "$local_temp_file" 2>/dev/null || true
    return 1
  fi

  local downloaded_size
  downloaded_size=$(wc -c < "$local_temp_file" | tr -d ' ')
  if [ "$downloaded_size" -ne "$gcs_size" ]; then
    log_error "Size mismatch! GCS size: $gcs_size, Downloaded size: $downloaded_size. Aborting."
    rm -f "$local_temp_file" 2>/dev/null || true
    return 1
  fi

  # Generate fresh Google Drive bearer token right before upload
  # to prevent token expiration if GCS download took a long time
  log_info "Acquiring fresh Google Drive bearer token before upload..."
  gdrive_token=$(get_gdrive_token "true")
  if [ -z "$gdrive_token" ]; then
    log_error "Failed to acquire fresh Google Drive bearer token before upload."
    rm -f "$local_temp_file" 2>/dev/null || true
    return 1
  fi

  log_info "Uploading to Google Drive..."
  local drive_file_id
  drive_file_id=$(upload_file_to_gdrive "$local_temp_file" "$target_name" "$GDRIVE_FOLDER_ID" "$GDRIVE_CHUNK_SIZE" "$gcs_mime" "$gdrive_token")

  rm -f "$local_temp_file" 2>/dev/null || true
  trap - EXIT

  if [ -z "$drive_file_id" ]; then
    log_error "Google Drive upload failed. Source gs://${bucket}/${object} will NOT be deleted."
    return 1
  fi

  log_info "Google Drive File ID: $drive_file_id"
  log_info "Link: https://drive.google.com/file/d/$drive_file_id/view"

  if [ "$KEEP_SOURCE" = true ]; then
    log_info "Source gs://${bucket}/${object} retained in GCS (--keep-source active)."
  else
    log_info "Deleting source object gs://${bucket}/${object} from GCS..."
    # Refresh GCS token in case download and upload duration exceeded token validity
    gcs_token=$(get_gcs_token)
    if delete_gcs_object "$bucket" "$object" "$gcs_token"; then
      log_success "Source gs://${bucket}/${object} deleted successfully from GCS."
    else
      log_warn "Failed to delete gs://${bucket}/${object} from GCS. Please remove manually."
      return 1
    fi
  fi

  return 0
}

# --- Main CLI Workflow ---
main() {
  # Initialize with values from .env if present (fallback to existing env vars)
  local val
  val=$(load_env_val "GCS_SERVICE_ACCOUNT_KEY"); [ -n "$val" ] && GCS_SERVICE_ACCOUNT_KEY="$val"
  val=$(load_env_val "GDRIVE_SERVICE_ACCOUNT_KEY"); [ -n "$val" ] && GDRIVE_SERVICE_ACCOUNT_KEY="$val"
  val=$(load_env_val "GCS_ACCESS_TOKEN"); [ -n "$val" ] && GCS_ACCESS_TOKEN="$val"
  val=$(load_env_val "GDRIVE_ACCESS_TOKEN"); [ -n "$val" ] && GDRIVE_ACCESS_TOKEN="$val"
  val=$(load_env_val "GDRIVE_FOLDER_ID"); [ -n "$val" ] && GDRIVE_FOLDER_ID="$val"
  val=$(load_env_val "GDRIVE_CHUNK_SIZE"); [ -n "$val" ] && GDRIVE_CHUNK_SIZE="$val"
  val=$(load_env_val "TEMP_DIR"); [ -n "$val" ] && TEMP_DIR="$val"
  val=$(load_env_val "KEEP_SOURCE")
  if [ "$val" = "true" ] || [ "$val" = "1" ]; then
    KEEP_SOURCE=true
  fi

  # Parse CLI arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--source)
        GCS_SOURCE_URI="$2"
        shift 2
        ;;
      --source=*)
        GCS_SOURCE_URI="${1#*=}"
        shift
        ;;
      -d|--folder-id)
        GDRIVE_FOLDER_ID="$2"
        shift 2
        ;;
      --folder-id=*)
        GDRIVE_FOLDER_ID="${1#*=}"
        shift
        ;;
      --gcs-sa-key)
        GCS_SERVICE_ACCOUNT_KEY="$2"
        shift 2
        ;;
      --gcs-sa-key=*)
        GCS_SERVICE_ACCOUNT_KEY="${1#*=}"
        shift
        ;;
      --gdrive-sa-key)
        GDRIVE_SERVICE_ACCOUNT_KEY="$2"
        shift 2
        ;;
      --gdrive-sa-key=*)
        GDRIVE_SERVICE_ACCOUNT_KEY="${1#*=}"
        shift
        ;;
      --gcs-token)
        GCS_ACCESS_TOKEN="$2"
        shift 2
        ;;
      --gcs-token=*)
        GCS_ACCESS_TOKEN="${1#*=}"
        shift
        ;;
      --gdrive-token)
        GDRIVE_ACCESS_TOKEN="$2"
        shift 2
        ;;
      --gdrive-token=*)
        GDRIVE_ACCESS_TOKEN="${1#*=}"
        shift
        ;;
      --chunk-size)
        GDRIVE_CHUNK_SIZE="$2"
        shift 2
        ;;
      --chunk-size=*)
        GDRIVE_CHUNK_SIZE="${1#*=}"
        shift
        ;;
      --name)
        CUSTOM_REMOTE_NAME="$2"
        shift 2
        ;;
      --name=*)
        CUSTOM_REMOTE_NAME="${1#*=}"
        shift
        ;;
      --keep-source|--copy-only)
        KEEP_SOURCE=true
        shift
        ;;
      --temp-dir)
        TEMP_DIR="$2"
        shift 2
        ;;
      --temp-dir=*)
        TEMP_DIR="${1#*=}"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      -*)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
      *)
        if [ -z "$GCS_SOURCE_URI" ]; then
          GCS_SOURCE_URI="$1"
        else
          log_error "Unexpected argument: $1"
          show_help
          exit 1
        fi
        shift
        ;;
    esac
  done

  # Validate Chunk Size
  if ! [[ "$GDRIVE_CHUNK_SIZE" =~ ^[0-9]+$ ]] || [ "$GDRIVE_CHUNK_SIZE" -le 0 ] || [ "$((GDRIVE_CHUNK_SIZE % 262144))" -ne 0 ]; then
    log_warn "Configured chunk size '$GDRIVE_CHUNK_SIZE' is invalid (must be a positive multiple of 262144 bytes / 256 KiB)."
    log_warn "Falling back to default chunk size: 26214400 bytes (25 MiB)."
    GDRIVE_CHUNK_SIZE=26214400
  fi

  # Resolve Relative Paths
  GCS_SERVICE_ACCOUNT_KEY=$(resolve_file_path "$GCS_SERVICE_ACCOUNT_KEY")
  GDRIVE_SERVICE_ACCOUNT_KEY=$(resolve_file_path "$GDRIVE_SERVICE_ACCOUNT_KEY")

  # Validate Required Parameters
  if [ -z "$GCS_SOURCE_URI" ]; then
    log_error "No GCS source URI specified. Please provide a gs:// URI."
    show_help
    exit 1
  fi

  if [[ "$GCS_SOURCE_URI" != gs://* ]]; then
    log_error "Invalid GCS source URI '$GCS_SOURCE_URI'. Must start with 'gs://'."
    exit 1
  fi

  if [ "$DRY_RUN" = false ]; then
    if [ -z "$GDRIVE_FOLDER_ID" ]; then
      log_warn "No Google Drive Folder ID provided (--folder-id or GDRIVE_FOLDER_ID). Uploading to root My Drive."
    fi
  fi

  log_info "Starting GCS to Google Drive Data Mover..."
  log_info "Source URI: $GCS_SOURCE_URI"
  [ -n "$GDRIVE_FOLDER_ID" ] && log_info "Target GDrive Folder: $GDRIVE_FOLDER_ID"
  log_info "Chunk Size: $((GDRIVE_CHUNK_SIZE / 1024 / 1024)) MiB ($GDRIVE_CHUNK_SIZE bytes)"
  if [ "$KEEP_SOURCE" = true ]; then
    log_info "Mode: COPY (source retained in GCS)"
  else
    log_info "Mode: MOVE (source deleted from GCS after verified upload)"
  fi
  [ "$DRY_RUN" = true ] && log_warn "DRY-RUN mode enabled. No actual file changes will be made."

  local parsed
  parsed=$(parse_gcs_uri "$GCS_SOURCE_URI")
  local bucket="${parsed%%|*}"
  local path="${parsed#*|}"

  if [ -z "$bucket" ]; then
    log_error "Could not parse bucket name from '$GCS_SOURCE_URI'."
    exit 1
  fi

  # Authenticate GCS and GDrive
  local gcs_token="" gdrive_token=""
  if [ "$DRY_RUN" = false ] || [ -n "$GCS_SERVICE_ACCOUNT_KEY" ] || [ -n "$GCS_ACCESS_TOKEN" ]; then
    gcs_token=$(get_gcs_token)
    if [ -z "$gcs_token" ]; then
      log_error "Unable to authenticate with Google Cloud Storage."
      exit 1
    fi
  fi

  if [ "$DRY_RUN" = false ]; then
    gdrive_token=$(get_gdrive_token)
    if [ -z "$gdrive_token" ]; then
      log_error "Unable to authenticate with Google Drive."
      exit 1
    fi
  fi

  # Determine whether source is a single file or a prefix/folder
  local is_prefix=false
  if [ -z "$path" ] || [[ "$path" == */ ]]; then
    is_prefix=true
  else
    local check_meta
    check_meta=$(get_gcs_object_metadata "$bucket" "$path" "$gcs_token" 2>/dev/null || true)
    if [ -z "$check_meta" ]; then
      if [ "$DRY_RUN" = true ] && [[ "$path" == *.* ]]; then
        is_prefix=false
      else
        is_prefix=true
      fi
    fi
  fi

  if [ "$is_prefix" = false ]; then
    # Single file transfer
    log_info "Processing single file: gs://${bucket}/${path}"
    if transfer_single_object "$bucket" "$path" "$CUSTOM_REMOTE_NAME" "$gcs_token" "$gdrive_token"; then
      log_success "Completed transfer for gs://${bucket}/${path}."
    else
      log_error "Transfer failed for gs://${bucket}/${path}."
      exit 1
    fi
  else
    # Prefix / Multi-file transfer
    log_info "Listing objects under gs://${bucket}/${path}..."
    local objects
    objects=$(list_gcs_objects "$bucket" "$path" "$gcs_token")

    if [ -z "$objects" ]; then
      log_warn "No objects found under gs://${bucket}/${path}."
      exit 0
    fi

    local total_count
    total_count=$(echo "$objects" | grep -c . || echo "0")
    log_info "Found $total_count object(s) to transfer."

    local current_idx=1
    local success_count=0
    local failure_count=0

    while IFS= read -r obj; do
      [ -z "$obj" ] && continue
      log_info "------------------------------------------------------------"
      log_info "Processing [$current_idx/$total_count]: gs://${bucket}/${obj}"

      if [ "$DRY_RUN" = false ]; then
        gcs_token=$(get_gcs_token)
        gdrive_token=$(get_gdrive_token)
      fi

      if transfer_single_object "$bucket" "$obj" "" "$gcs_token" "$gdrive_token"; then
        success_count=$((success_count + 1))
      else
        failure_count=$((failure_count + 1))
        log_error "Failed to transfer gs://${bucket}/${obj}."
      fi
      current_idx=$((current_idx + 1))
    done <<< "$objects"

    log_info "============================================================"
    log_info "Batch transfer summary: $success_count succeeded, $failure_count failed (out of $total_count)."
    if [ "$failure_count" -gt 0 ]; then
      exit 1
    fi
  fi

  log_success "All requested operations completed successfully!"
}

# Entry point guard
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
