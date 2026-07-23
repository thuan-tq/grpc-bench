#!/bin/bash
# build_benchmarks.sh

GRPC_DIR="$HOME/alts_benchmark/grpc-go"
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function build_binary {
    local branch=$1
    local bin_name=$2

    echo "=========================================="
    echo " 🔄 Preparing to build $bin_name from $branch"
    echo "=========================================="

    echo " -> Checking out $branch..."
    cd "$GRPC_DIR" || exit 1
    git checkout "$branch" || { echo "❌ Failed to checkout $branch!"; return 1; }

    echo " -> Compiling $bin_name..."
    cd "$BENCH_DIR" || exit 1
    mkdir -p bin
    go build -o "bin/$bin_name" . || { echo "❌ Failed to build $bin_name!"; return 1; }
    
    echo "✅ Successfully built $bin_name"
    echo "=========================================="
}

# Run the compilation sequence
# We use 'return 1' in function so we can continue if one fails,
# but we might want to exit if crucial ones fail.
# For now, just try to build all.

build_binary "master" "client_master"
build_binary "alts-max-frame-size-16kb" "client_16kb"
build_binary "alts-max-frame-size-32kb" "client_32kb"
build_binary "alts-max-frame-size-128k" "client_128kb"
build_binary "alts-max-frame-size-1m" "client_1m"
build_binary "alts-default-frame-size-32kb" "client_default_32kb"
build_binary "alts-default-frame-size-64kb" "client_default_64kb"
build_binary "alts-default-frame-size-512kb" "client_default_512kb"
