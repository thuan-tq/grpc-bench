#!/bin/bash
# capture_pprof.sh
#
# Captures CPU and memory (heap) pprof profiles from a running benchmark
# process, over a fixed time window, using the pprof HTTP endpoint main.go
# already exposes via -pprof-addr (net/http/pprof). Run this against a
# benchmark binary that's currently executing with e.g. -pprof-addr
# localhost:6060 -iterations <enough to outlast the window>.
#
# Usage: ./capture_pprof.sh [pprof_addr] [duration_seconds] [out_dir] [binary_path]
#   pprof_addr:       host:port the benchmark was started with. Default: localhost:6060
#   duration_seconds: length of the CPU profile / memory-diff window (e.g. 60 or 90). Default: 60
#   out_dir:          where profiles are written; one directory per day, shared across
#                     repeated captures. Default: $HOME/alts_benchmark/results/pprof_<date>
#   binary_path:      benchmark binary to symbolize against in the printed pprof commands (optional)

ADDR="${1:-localhost:6060}"
DURATION="${2:-60}"
OUT_DIR="${3:-"$HOME/alts_benchmark/results/pprof_$(date +%Y%m%d)"}"
BINARY="${4:-}"

# Multiple captures can land in the same day directory, so tag filenames with
# a per-run time so they don't overwrite each other.
RUN_TS="$(date +%H%M%S)"

BASE_URL="http://$ADDR/debug/pprof"

if ! curl -sf "$BASE_URL/" -o /dev/null; then
    echo "❌ Error: could not reach pprof endpoint at $BASE_URL"
    echo "   Make sure the benchmark binary is running with -pprof-addr $ADDR"
    exit 1
fi

mkdir -p "$OUT_DIR"
echo "Capturing profiles from $BASE_URL into $OUT_DIR"
echo "Window: ${DURATION}s"

HEAP_BEFORE="$OUT_DIR/heap_before_${RUN_TS}.pb.gz"
CPU_PROFILE="$OUT_DIR/cpu_${DURATION}s_${RUN_TS}.pb.gz"
HEAP_AFTER="$OUT_DIR/heap_after_${RUN_TS}.pb.gz"

echo " -> Heap snapshot (before)..."
curl -s "$BASE_URL/heap" -o "$HEAP_BEFORE" || { echo "❌ Failed to capture heap_before"; exit 1; }

echo " -> CPU profile (blocking for ${DURATION}s)..."
curl -s "$BASE_URL/profile?seconds=$DURATION" -o "$CPU_PROFILE" || { echo "❌ Failed to capture CPU profile"; exit 1; }

echo " -> Heap snapshot (after)..."
curl -s "$BASE_URL/heap" -o "$HEAP_AFTER" || { echo "❌ Failed to capture heap_after"; exit 1; }

echo "✅ Done. Files in $OUT_DIR:"
ls -la "$OUT_DIR"

echo ""
echo "--------------------------------------------------"
echo "Analyze with:"
echo "  CPU:          go tool pprof -http=:8081 ${BINARY:+"$BINARY "}\"$CPU_PROFILE\""
echo "  Heap (after): go tool pprof -http=:8081 ${BINARY:+"$BINARY "}\"$HEAP_AFTER\""
echo "  Heap diff:    go tool pprof -http=:8081 -base \"$HEAP_BEFORE\" ${BINARY:+"$BINARY "}\"$HEAP_AFTER\""
echo "--------------------------------------------------"
