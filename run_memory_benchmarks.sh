#!/bin/bash
# run_memory_benchmarks.sh
#
# Companion to run_alts_benchmarks.sh: runs the same binary/config matrix but
# wraps each invocation with `time` to capture peak resident set size (RSS)
# instead of relying on the benchmark's own latency output. Kept as a separate
# script so the latency pipeline (run_alts_benchmarks.sh -> analyze.py) is
# untouched; results land in their own mem_test_*.txt files.

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

# Parse Config Function (same schema as run_alts_benchmarks.sh / default.conf)
parse_config() {
    local config_file="$1"

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

    while IFS='=' read -r key value || [ -n "$key" ]; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

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
    OUT_DIR="results_memory_$(date +%Y%m%d_%H%M%S)"
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

for size in "${CONFIG_OBJECT_SIZES[@]}"; do
    CMD_ARGS+=("-object-size" "$size")
done

for t in "${CONFIG_TRANSPORTS[@]}"; do
    CMD_ARGS+=("-transport" "$t")
done

# Pick a `time` invocation that reports peak RSS, and how to read its output.
# GNU time (Linux, "time -v"):  "Maximum resident set size (kbytes): N"
# BSD time  (macOS, "time -l"): "N  maximum resident set size"          (bytes)
TIME_BIN="/usr/bin/time"
probe_out="$(mktemp)"
if "$TIME_BIN" -v true >/dev/null 2>"$probe_out"; then
    TIME_FLAG="-v"
elif "$TIME_BIN" -l true >/dev/null 2>"$probe_out"; then
    TIME_FLAG="-l"
else
    echo "❌ Error: '$TIME_BIN' supports neither -v (GNU) nor -l (BSD) on this system."
    rm -f "$probe_out"
    exit 1
fi
rm -f "$probe_out"

# Extracts peak RSS in KB from a captured `time` report, regardless of flavor.
extract_peak_rss_kb() {
    local time_output_file="$1"
    if [ "$TIME_FLAG" = "-v" ]; then
        grep "Maximum resident set size" "$time_output_file" | grep -oE '[0-9]+'
    else
        local bytes
        bytes=$(grep "maximum resident set size" "$time_output_file" | grep -oE '[0-9]+')
        [ -n "$bytes" ] && echo $(( bytes / 1024 ))
    fi
}

mkdir -p "$RESULTS_DIR/$OUT_DIR"
echo "Starting memory benchmarks with $LOOPS loops."
echo "Results directory: $RESULTS_DIR/$OUT_DIR/"
echo "Command args for binaries: ${CMD_ARGS[@]}"
echo "Using: $TIME_BIN $TIME_FLAG"

for i in $(seq 1 $LOOPS); do
    echo -e "\n=========================================="
    echo "   Starting Memory Benchmark Loop #$i of $LOOPS"
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

        outfile="$RESULTS_DIR/$OUT_DIR/mem_test_${branch_label}_default.txt"
        time_report="$(mktemp)"

        echo -e "\n==========================================" >> "$outfile"
        echo "   Running Memory Run #$i of $LOOPS" >> "$outfile"
        echo "==========================================" >> "$outfile"

        echo "  ▶️  Running Test [Binary: $bin (Label: $branch_label)] -> $(basename "$outfile")"

        # stdout (benchmark's own log/latency output) goes straight to outfile;
        # stderr is `time`'s report, captured separately so it can be parsed.
        "$TIME_BIN" "$TIME_FLAG" "$BENCH_DIR/bin/$bin" "${CMD_ARGS[@]}" >> "$outfile" 2>"$time_report"
        cat "$time_report" >> "$outfile"

        peak_kb="$(extract_peak_rss_kb "$time_report")"
        if [ -n "$peak_kb" ]; then
            echo "Peak RSS (KB): $peak_kb" >> "$outfile"
            echo "     Peak RSS: ${peak_kb} KB"
        else
            echo "     ⚠️  Could not parse peak RSS from $TIME_BIN output"
        fi

        rm -f "$time_report"

        echo "     [Cooling down sockets & GC for $SLEEP_TIME seconds...]"
        sleep "$SLEEP_TIME"
    done
done

echo ""
echo "✅ Memory benchmark matrix complete! Results saved in $RESULTS_DIR/$OUT_DIR/"
