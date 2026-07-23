#!/bin/bash
# run_alts_benchmarks.sh

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$HOME/alts_benchmark/results"
SLEEP_TIME=1                  # Cooldown seconds between runs

CONFIG_FILE="${1:-"$BENCH_DIR/default.conf"}"
OUT_DIR="$2"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

echo "Reading configuration from: $CONFIG_FILE"

# Static Map of known binaries to branch labels (for output filenames)
declare -A BIN_MAP=(
    ["client_master"]="master"
    ["client_16kb"]="alts-max-frame-size-16kb"
    ["client_32kb"]="alts-max-frame-size-32kb"
    ["client_1m"]="alts-max-frame-size-1m"
    ["client_128kb"]="alts-max-frame-size-128k"
    ["client_default_64kb"]="alts-default-frame-size-64kb"
    ["client_default_32kb"]="alts-default-frame-size-32kb"
    ["client_default_512kb"]="alts-default-frame-size-512kb"
)

# Parse Config Function
parse_config() {
    local config_file="$1"
    
    # Initialize config variables
    CONFIG_LOOPS=""
    CONFIG_PROJECT_ID=""
    CONFIG_BUCKET=""
    CONFIG_BINARIES=()
    CONFIG_ITERATIONS=""
    CONFIG_WORKERS=""
    CONFIG_OBJECT_SIZES=()
    CONFIG_WRITE_BUF_SIZE=""
    CONFIG_READ_BUF_SIZE=""
    CONFIG_TEST_DOWNLOAD=""
    CONFIG_TRANSPORTS=()
    CONFIG_PPROF_ADDR=""
    CONFIG_DOWNLOAD_OBJECT=""
    CONFIG_MEM_STATS=""
    CONFIG_MEM_MONITOR_INTERVAL=""

    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Strip whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [ -z "$key" ] && continue

        case "$key" in
            loops) CONFIG_LOOPS="$value" ;;
            project-id|projectId) CONFIG_PROJECT_ID="$value" ;;
            bucket) CONFIG_BUCKET="$value" ;;
            binaries)
                IFS=',' read -r -a CONFIG_BINARIES <<< "$value"
                ;;
            iterations) CONFIG_ITERATIONS="$value" ;;
            workers) CONFIG_WORKERS="$value" ;;
            object-size|objectSize)
                IFS=',' read -r -a CONFIG_OBJECT_SIZES <<< "$value"
                ;;
            write-buffer-size|writeBufferSize) CONFIG_WRITE_BUF_SIZE="$value" ;;
            read-buffer-size|readBufferSize) CONFIG_READ_BUF_SIZE="$value" ;;
            test-download|testDownload) CONFIG_TEST_DOWNLOAD="$value" ;;
            transport)
                IFS=',' read -r -a CONFIG_TRANSPORTS <<< "$value"
                ;;
            pprof-addr|pprofAddr) CONFIG_PPROF_ADDR="$value" ;;
            download-object|downloadObject) CONFIG_DOWNLOAD_OBJECT="$value" ;;
            mem-stats|memStats) CONFIG_MEM_STATS="$value" ;;
            mem-monitor-interval|memMonitorInterval) CONFIG_MEM_MONITOR_INTERVAL="$value" ;;
            *) echo "Warning: Unknown config key: $key" ;;
        esac
    done < "$config_file"
}

parse_config "$CONFIG_FILE"

# Apply Defaults and Config
LOOPS="${CONFIG_LOOPS:-5}"
PROJECT_ID="${CONFIG_PROJECT_ID:-"directpath-security-manual"}"
BUCKET="${CONFIG_BUCKET:-"lwge-gcs-test-bucket"}"
BINARIES=("${CONFIG_BINARIES[@]}")

if [ ${#BINARIES[@]} -eq 0 ]; then
    echo "❌ Error: No binaries specified in config."
    exit 1
fi

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="results_$(date +%Y%m%d_%H%M%S)"
fi

# Construct command line arguments for main.go
CMD_ARGS=("-project-id" "$PROJECT_ID" "-bucket" "$BUCKET")
[ -n "$CONFIG_ITERATIONS" ] && CMD_ARGS+=("-iterations" "$CONFIG_ITERATIONS")
[ -n "$CONFIG_WORKERS" ] && CMD_ARGS+=("-workers" "$CONFIG_WORKERS")
[ -n "$CONFIG_WRITE_BUF_SIZE" ] && CMD_ARGS+=("-write-buffer-size" "$CONFIG_WRITE_BUF_SIZE")
[ -n "$CONFIG_READ_BUF_SIZE" ] && CMD_ARGS+=("-read-buffer-size" "$CONFIG_READ_BUF_SIZE")
[ "$CONFIG_TEST_DOWNLOAD" = "true" ] && CMD_ARGS+=("-test-download")
[ -n "$CONFIG_PPROF_ADDR" ] && CMD_ARGS+=("-pprof-addr" "$CONFIG_PPROF_ADDR")
[ -n "$CONFIG_DOWNLOAD_OBJECT" ] && CMD_ARGS+=("-download-object" "$CONFIG_DOWNLOAD_OBJECT")
[ "$CONFIG_MEM_STATS" = "true" ] && CMD_ARGS+=("-mem-stats")
[ -n "$CONFIG_MEM_MONITOR_INTERVAL" ] && CMD_ARGS+=("-mem-monitor-interval" "$CONFIG_MEM_MONITOR_INTERVAL")

for size in "${CONFIG_OBJECT_SIZES[@]}"; do
    CMD_ARGS+=("-object-size" "$size")
done

for t in "${CONFIG_TRANSPORTS[@]}"; do
    CMD_ARGS+=("-transport" "$t")
done

mkdir -p "$RESULTS_DIR/$OUT_DIR"
echo "Starting ALTS targeted benchmarks with $LOOPS loops."
echo "Results directory: $RESULTS_DIR/$OUT_DIR/"
echo "Command args for binaries: ${CMD_ARGS[@]}"

for i in $(seq 1 $LOOPS); do
    echo -e "\n=========================================="
    echo "   Starting Benchmark Loop #$i of $LOOPS"
    echo "=========================================="

    for bin in "${BINARIES[@]}"; do
        if [ ! -f "$BENCH_DIR/bin/$bin" ]; then
            echo "⚠️  Binary $bin not found in $BENCH_DIR/bin/, skipping..."
            continue
        fi

        branch_label=${BIN_MAP[$bin]}
        if [ -z "$branch_label" ]; then
            branch_label=$bin
        fi

        outfile="$RESULTS_DIR/$OUT_DIR/grpc_test_${branch_label}_default.txt"

        echo -e "\n==========================================" >> "$outfile"
        echo "   Running Benchmark Run #$i of $LOOPS" >> "$outfile"
        echo "==========================================" >> "$outfile"

        echo "  ▶️  Running Test [Binary: $bin (Label: $branch_label)] -> $(basename "$outfile")"
        
        # Run the pre-built binary with dynamic args
        "$BENCH_DIR/bin/$bin" "${CMD_ARGS[@]}" >> "$outfile" 2>&1

        echo "     [Cooling down sockets & GC for $SLEEP_TIME seconds...]"
        sleep "$SLEEP_TIME"
    done
done

echo ""
echo "✅ Targeted matrix automation complete! Results saved in $RESULTS_DIR/$OUT_DIR/"
