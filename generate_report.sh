#!/bin/bash
# generate_report.sh

if [ -z "$1" ]; then
    echo "Usage: $0 <results_folder_name>"
    echo "Example: $0 results_20260723_025847"
    exit 1
fi

FOLDER_NAME="$1"
SCRIPT_DIR="$(dirname "$0")"

# Configuration for remote VM
REMOTE_HOST="thuantq_google_com@nic0.alts-perf.us-central1-a.c.directpath-security-manual.internal.gcpnode.com"
REMOTE_BASE_DIR="~/alts_benchmark/results"

LOCAL_DIR="$HOME/alts_benchmark/results/$FOLDER_NAME"

echo "--------------------------------------------------"
echo "1. Creating local directory: $LOCAL_DIR"
echo "--------------------------------------------------"
mkdir -p "$LOCAL_DIR"

echo "--------------------------------------------------"
echo "2. Copying results from remote VM via scp..."
echo "--------------------------------------------------"
# Construct remote path
REMOTE_PATH="$REMOTE_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/*.txt"

echo "Running: scp \"$REMOTE_PATH\" \"$LOCAL_DIR/\""
scp "$REMOTE_PATH" "$LOCAL_DIR/"

if [ $? -ne 0 ]; then
    echo "❌ Failed to copy files from remote VM"
    exit 1
fi

echo "✅ Files copied successfully."

# Resolve to absolute path for the report
ABS_LOCAL_DIR="$(cd "$LOCAL_DIR" && pwd)"

echo "--------------------------------------------------"
echo "3. Generating report..."
echo "--------------------------------------------------"
# Run python script and save output to report.md
python3 "$SCRIPT_DIR/analyze.py" "$ABS_LOCAL_DIR" > "$ABS_LOCAL_DIR/report.md"

if [ $? -eq 0 ]; then
    echo "✅ Report generated successfully at $ABS_LOCAL_DIR/report.md"
    echo "--------------------------------------------------"
    cat "$ABS_LOCAL_DIR/report.md"
    echo "--------------------------------------------------"
else
    echo "❌ Failed to generate report"
    exit 1
fi
