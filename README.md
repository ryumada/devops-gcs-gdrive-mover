# GCS to Google Drive Data Mover (`gcs-to-gdrive.sh`)

A robust, production-ready bash script designed to transfer or move files and folders from **Google Cloud Storage (GCS)** to **Google Drive (GDrive)**.

The script connects using separate **Google Service Account JSON keys**, generating RS256 JWT bearer tokens programmatically via `openssl` and `curl` without requiring `gcloud` CLI or external Python SDKs.

---

## Features

- **Programmatic Authentication**: Uses OpenSSL to create and sign RS256 JWT assertions, exchanging them directly with Google's OAuth2 endpoint (`https://oauth2.googleapis.com/token`).
- **Separate Service Account Keys**:
  - `GCS_SERVICE_ACCOUNT_KEY` with scope `https://www.googleapis.com/auth/devstorage.read_write`
  - `GDRIVE_SERVICE_ACCOUNT_KEY` with scope `https://www.googleapis.com/auth/drive`
- **In-Memory Token Caching**: Tokens are cached and automatically refreshed prior to expiration (1-hour window), ensuring smooth transfers for large batches without redundant API calls.
- **25 MiB Default Chunk Size**: Default resumable upload chunk size is set to **25 MiB** (`26214400` bytes = 100 × 256 KiB) for optimal network throughput while preserving pause/resume resilience.
- **Safe Move Behavior**: By default, verifies the upload on Google Drive (checks HTTP status 200/201 and valid File ID) before safely deleting the source object from GCS.
- **Copy Mode**: Use `--keep-source` (or `--copy-only`) to transfer without deleting from GCS.
- **Single File & Prefix (Folder) Support**: Seamlessly transfers a single object (`gs://bucket/file.ext`) or all objects under a prefix (`gs://bucket/folder/`) with pagination.
- **Shared Drive Support**: Full compatibility with Google Shared Drives (`supportsAllDrives=true`).
- **Dry Run**: Preview what would be downloaded, uploaded, and deleted using `--dry-run`.

---

## Architecture & Workflow

```
+-------------------------------------------------------------------------------+
|                             CLI / .env Configuration                          |
|  - GCS_SERVICE_ACCOUNT_KEY      - GDRIVE_SERVICE_ACCOUNT_KEY                  |
|  - GDRIVE_FOLDER_ID             - GDRIVE_CHUNK_SIZE (Default: 25 MiB)         |
|  - Source gs://bucket/path...   - MOVE_MODE (Default: move, opt: keep-source) |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
|                    Programmatic JWT Generation & OAuth2 Token                 |
|                                                                               |
|   [GCS SA JSON] ----> RS256 JWT ----> GCS Bearer Token (devstorage.read_write)|
|   [GDrive SA JSON] -> RS256 JWT ----> GDrive Bearer Token (drive)             |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
|                          Target Inspection (GCS REST API)                     |
|                                                                               |
|   Check Source: Is it a single object or prefix (folder)?                     |
|   - Single Object -> Prepare 1 transfer task                                  |
|   - Prefix/Folder -> List all matching objects with pagination                |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+---------------------------------------------------------------------------------+
|                       Per-Object Processing Loop                                |
|                                                                                 |
|   1. Query GCS Object Metadata (size, mimeType, md5Hash)                        |
|   2. Download Object to local buffer or temp dir                                |
|   3. Initiate Google Drive Resumable Session:                                   |
|      POST https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable |
|      Header: X-Upload-Content-Length: <size>                                    |
|      Metadata: {"name": "<object_name>", "parents": ["<folder_id>"]}            |
|   4. Upload in 25 MiB Chunks:                                                   |
|      PUT <session_uri>                                                          |
|      Header: Content-Range: bytes START-END/TOTAL                               |
|      Retry failed chunks with backoff and range query                           |
+---------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
|                      Upload Verification & Move Action                        |
|                                                                               |
|   Did upload return HTTP 200/201 and valid Google Drive File ID?              |
|          |                                                                    |
|         YES                                              NO                   |
|          |                                                |                   |
|          v                                                v                   |
|   Is Move Mode active?                             Log error & abort          |
|   (default: YES)                                                              |
|     |            \                                                            |
|    YES           NO (--keep-source)                                           |
|     |              \                                                          |
|     v               v                                                         |
|   Delete from GCS   Retain in GCS                                             |
|   (DELETE REST API)                                                           |
|     |               /                                                         |
|     +-------+------+                                                          |
|             v                                                                 |
|   Clean up local temp file & proceed to next object                           |
+-------------------------------------------------------------------------------+
```

---

## Requirements

The script runs with standard UNIX command line tools:
- `bash` (v4.0+)
- `curl`
- `openssl`
- Standard POSIX utilities: `sed`, `grep`, `awk`, `tr`, `dd`
- *(Optional)* `jq` for optimized JSON parsing (falls back to POSIX tools if `jq` is absent).

---

## Setup & Prerequisites

### 1. Google Cloud Storage Service Account
1. In Google Cloud Console, create or select a Service Account for GCS.
2. Grant permissions:
   - **Storage Object Viewer** (to read & download objects)
   - **Storage Object Admin** (needed if moving / deleting objects from GCS)
3. Download the JSON key file (e.g. `./secrets/gcs-sa.json`).

### 2. Google Drive Service Account
1. Create or select a Service Account for Google Drive in Google Cloud Console.
2. Ensure the **Google Drive API** is enabled in the project.
3. Download the JSON key file (e.g. `./secrets/gdrive-sa.json`).
4. **Important**: Open Google Drive in your browser, select the destination folder (or Shared Drive), click **Share**, and add the GDrive Service Account's email (`client_email` in the JSON) with **Content Manager** or **Editor** permissions.

### 3. Configuration

Copy `.env.example` to `.env` and fill in your details:

```bash
cp .env.example .env
```

Edit `.env`:
```ini
GCS_SERVICE_ACCOUNT_KEY="./secrets/gcs-sa.json"
GDRIVE_SERVICE_ACCOUNT_KEY="./secrets/gdrive-sa.json"
GDRIVE_FOLDER_ID="1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs7"
GDRIVE_CHUNK_SIZE="26214400"
TEMP_DIR="/tmp"
KEEP_SOURCE="false"
```

---

## Usage

Make sure the script has execute permissions:
```bash
chmod +x gcs-to-gdrive.sh
```

### 1. Show Help
```bash
./gcs-to-gdrive.sh --help
```

### 2. Move a Single File
```bash
./gcs-to-gdrive.sh gs://my-bucket/backups/snapshot-20260910.tar.zst
```

### 3. Move an Entire Folder / Prefix
```bash
./gcs-to-gdrive.sh gs://my-bucket/database-exports/
```

### 4. Copy Without Deleting from GCS (`--keep-source`)
```bash
./gcs-to-gdrive.sh gs://my-bucket/reports/2026/ --keep-source
```

### 5. Dry-Run Simulation (No Changes Made)
```bash
./gcs-to-gdrive.sh gs://my-bucket/archive/ --dry-run
```

### 6. Passing Credentials and Options via CLI
All options can be provided on the command line, overriding `.env`:
```bash
./gcs-to-gdrive.sh gs://my-bucket/data.csv \
  --gcs-sa-key /path/to/gcs-sa.json \
  --gdrive-sa-key /path/to/gdrive-sa.json \
  --folder-id "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs7" \
  --chunk-size 26214400 \
  --name "custom-data.csv"
```

---

## Options Reference

| Option | Description | Default |
| :--- | :--- | :--- |
| `-s, --source <URI>` | Source GCS URI (`gs://bucket/file` or `gs://bucket/prefix/`) | Positional argument |
| `-d, --folder-id <ID>` | Destination Google Drive Folder ID | `GDRIVE_FOLDER_ID` from `.env` |
| `--gcs-sa-key <PATH>` | Path to GCS Service Account JSON key file | `GCS_SERVICE_ACCOUNT_KEY` from `.env` |
| `--gdrive-sa-key <PATH>` | Path to GDrive Service Account JSON key file | `GDRIVE_SERVICE_ACCOUNT_KEY` from `.env` |
| `--gcs-token <TOKEN>` | Direct GCS Bearer Access Token | `GCS_ACCESS_TOKEN` from `.env` |
| `--gdrive-token <TOKEN>` | Direct GDrive Bearer Access Token | `GDRIVE_ACCESS_TOKEN` from `.env` |
| `--chunk-size <BYTES>` | Chunk size for resumable uploads (multiple of 256 KiB) | `26214400` (25 MiB) |
| `--name <FILENAME>` | Custom target filename (single file only) | Original filename |
| `--keep-source`, `--copy-only` | Do not delete source file from GCS after upload | `false` (Move mode) |
| `--temp-dir <PATH>` | Local temporary directory for buffering | `/tmp` |
| `--dry-run` | Simulate actions without downloading, uploading, or deleting | `false` |
| `-h, --help` | Show command line options and usage | |
