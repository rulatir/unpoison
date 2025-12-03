#!/usr/bin/env bash

# smoke_test_magick.sh
# Self-contained smoke test: creates a large synthetic image and runs two magick
# invocations (single-threaded and multi-threaded) to sample CPU usage.

set -u

print_usage() {
    cat <<'USAGE'
Usage: smoke_test_magick.sh

This self-contained script creates a synthetic large image and runs two tests
(single-threaded and multi-threaded) to sample magick's CPU usage. No arguments.

USAGE
}

# Create a synthetic large image for the test and ensure cleanup on exit
TMP_INPUT=$(mktemp --suffix=.png)
trap 'rm -f "${TMP_INPUT}"' EXIT

printf 'Creating synthetic test image: %s (this may take a few seconds)...\n' "$TMP_INPUT"
# Use a fractal/plasma image to create CPU- and memory-work for magick
magick -size 8000x8000 plasma:fractal -normalize "$TMP_INPUT" >/dev/null 2>&1 || {
    echo "Failed to create synthetic image with magick. Aborting." >&2
    exit 1
}

FILE="$TMP_INPUT"
DESIRED_SIZE=2000
THREADS_ARG=$(nproc)
NPROC=$(nproc)

printf "Smoke test for: %s\n" "$FILE"
printf "Desired size: %s\n" "$DESIRED_SIZE"
printf "Host reported logical CPUs: %s\n" "$NPROC"

printf "\n-- magick version --\n"
if command -v magick >/dev/null 2>&1; then
    magick -version | sed -n '1,5p'
else
    echo "magick command not found in PATH. Install ImageMagick to run this test." >&2
    exit 3
fi

# Helper: run a magick command under specified env and sample CPU
run_and_sample() {
    local label="$1"
    local magick_threads="$2"
    local omp_threads="$3"

    printf "\n== %s: MAGICK_THREAD_LIMIT=%s OMP_NUM_THREADS=%s ==\n" "$label" "$magick_threads" "$omp_threads"

    local tmpout
    tmpout=$(mktemp --suffix=.jpg)

    # log files
    local samples
    samples=$(mktemp)

    # start time
    local start_ts
    local end_ts
    start_ts=$(date +%s.%N)

    # start magick in background; redirect stdout/stderr to /dev/null to keep output clean
    env MAGICK_THREAD_LIMIT="$magick_threads" OMP_NUM_THREADS="$omp_threads" magick "$FILE" -resize "${DESIRED_SIZE}x${DESIRED_SIZE}>" -quality 95 "$tmpout" >/dev/null 2>&1 &
    local pid=$!

    # sample %CPU while process is running
    while kill -0 "$pid" 2>/dev/null; do
        # ps prints %CPU as a float-like number; trim whitespace
        ps -p "$pid" -o %cpu= 2>/dev/null | awk '{print $1}' >> "$samples" || true
        sleep 0.2
    done

    wait "$pid" 2>/dev/null || true
    end_ts=$(date +%s.%N)

    # compute elapsed time
    local elapsed
    elapsed=$(awk "BEGIN {print $end_ts - $start_ts}")

    # compute avg and peak CPU from samples
    local avg_cpu
    local peak_cpu
    if [ -s "$samples" ]; then
        avg_cpu=$(awk '{sum+=$1; n++} END { if (n>0) printf "%.2f", sum/n; else print "0"}' "$samples")
        peak_cpu=$(awk 'BEGIN{m=0} {if($1>m)m=$1} END{printf "%.2f", m}' "$samples")
    else
        avg_cpu="0"
        peak_cpu="0"
    fi

    # output file size
    local out_size
    out_size=$(stat --printf='%s' "$tmpout" 2>/dev/null || echo 0)

    printf "Result for %s: elapsed=%ss, avg_cpu=%s%%, peak_cpu=%s%%, out_size=%s bytes\n" "$label" "$elapsed" "$avg_cpu" "$peak_cpu" "$out_size"

    # print a short sample of the CPU log (first/last 5 entries) for debugging
    echo "Sampled %CPU (first 5):"
    head -n5 "$samples" || true
    echo "Sampled %CPU (last 5):"
    tail -n5 "$samples" || true

    # clean up
    rm -f "$samples" "$tmpout"
}

# Run two tests: single-threaded and multi-threaded (threads specified by user)
run_and_sample "single-threaded" 1 1
run_and_sample "multi-threaded" "$THREADS_ARG" "$THREADS_ARG"

printf "\nSmoke test complete. If multi-threaded run shows significantly higher avg/peak CPU than single-threaded, your magick is using multiple cores per invocation.\n"

exit 0

