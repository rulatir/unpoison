#!/bin/bash

src_dir="./all"
dst_dir="./smallified"
desired_size=2000

# Always match the number of CPU cores
jobs=$(nproc 2>/dev/null || echo 1)

# parse args
worker_mode=0
worker_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --worker)
            worker_mode=1
            shift
            ;;
        --file)
            worker_file="$2"; shift 2
            ;;
        --src)
            src_dir="$2"; shift 2
            ;;
        --dst)
            dst_dir="$2"; shift 2
            ;;
        --desired_size)
            desired_size="$2"; shift 2
            ;;
        *)
            # ignore unknown for now
            shift
            ;;
    esac
done

mkdir -p "$dst_dir"

if [[ "$worker_mode" -eq 0 ]]; then
    # DRIVER MODE
    tmpdir=$(mktemp -d)
    # Ensure cleanup of tempdir and any worker temp files
    cleanup() {
        # give workers a moment to finish writing
        sleep 0.05
        rm -rf -- "$tmpdir"
    }
    trap cleanup EXIT INT TERM

    # Build list of files once (preserve original find pattern)
    mapfile -t all_files < <(find "$src_dir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.tiff" -o -iname "*.jfif" -o -iname "*.heic" -o -iname "*.HEIC" \))

    if [[ ${#all_files[@]} -eq 0 ]]; then
        echo "No files found under $src_dir"
        exit 0
    fi

    echo "Launching up to $jobs concurrent workers to process ${#all_files[@]} files (src=$src_dir dst=$dst_dir)"

    running_pids=()
    running_outfiles=()
    running_files=()

    # helper: find index of finished pid (returns 0-based index or -1)
    find_finished_index() {
        for i in "${!running_pids[@]}"; do
            pid=${running_pids[i]}
            if ! kill -0 "$pid" 2>/dev/null; then
                # process no longer exists
                echo "$i"
                return 0
            fi
        done
        echo -1
        return 1
    }

    # iterate files, launching workers up to $jobs concurrently
    for file in "${all_files[@]}"; do
        # wait for a free slot if needed
        while (( ${#running_pids[@]} >= jobs )); do
            if wait -n 2>/dev/null; then
                : # reaped one child; now find which
            else
                # no wait -n; wait for the first pid
                wait "${running_pids[0]}" 2>/dev/null || true
            fi
            idx=$(find_finished_index)
            if [[ "$idx" -ge 0 ]]; then
                pid=${running_pids[idx]}
                wait "$pid" || true
                outfile=${running_outfiles[idx]}
                fpath=${running_files[idx]}
                cat -- "$outfile"
                rm -f -- "$outfile"
                # remove index
                unset 'running_pids[idx]' 'running_outfiles[idx]' 'running_files[idx]'
                # reindex
                running_pids=("${running_pids[@]}")
                running_outfiles=("${running_outfiles[@]}")
                running_files=("${running_files[@]}")
            fi
        done

        # create a per-worker tempfile for capturing output
        outfile=$(mktemp "$tmpdir/worker.XXXXXX.out")
        running_files+=("$file")
        # launch worker for just this file
        bash "$0" --worker --file "$file" --src "$src_dir" --dst "$dst_dir" --desired_size "$desired_size" >"$outfile" 2>&1 &
        pid=$!
        running_pids+=("$pid")
        running_outfiles+=("$outfile")
    done

    # wait for remaining workers and stream outputs as they finish
    while (( ${#running_pids[@]} > 0 )); do
        if wait -n 2>/dev/null; then
            :
        else
            wait "${running_pids[0]}" 2>/dev/null || true
        fi
        idx=$(find_finished_index)
        if [[ "$idx" -ge 0 ]]; then
            pid=${running_pids[idx]}
            wait "$pid" || true
            outfile=${running_outfiles[idx]}
            fpath=${running_files[idx]}
            cat -- "$outfile"
            rm -f -- "$outfile"
            unset 'running_pids[idx]' 'running_outfiles[idx]' 'running_files[idx]'
            running_pids=("${running_pids[@]}")
            running_outfiles=("${running_outfiles[@]}")
            running_files=("${running_files[@]}")
        fi
    done

    exit 0
fi

# WORKER MODE: must be invoked with --file <path>
if [[ -z "$worker_file" ]]; then
    echo "Worker mode requires --file <path>" >&2
    exit 2
fi

file="$worker_file"

# Determine the relative path and filename from source directory
rel_path="${file#$src_dir/}"

# Get original format and quality
format=$(magick identify -format '%m' "$file" 2>/dev/null || true)
quality=$(magick identify -format '%Q' "$file" 2>/dev/null || true)

# Set output extension and quality based on input format
if [ "${format,,}" = "jpeg" ]; then
    # Preserve original extension for JPEGs
    output_extension=".${file##*.}"
    # Use original quality, default to 95 if unknown
    quality=${quality:-95}
else
    output_extension=".jpg"
    quality=95
fi

# Modify destination path to use correct extension
dst_path="$dst_dir/${rel_path%.*}${output_extension}"

# Create the destination directory if it doesn't exist
mkdir -p "$(dirname "$dst_path")"

# Check the dimensions of the image using ImageMagick's identify command
dimensions=$(identify -format "%w %h" "$file" 2>/dev/null || echo "0 0")
read -r width height <<< "$dimensions"

# Check if resizing is necessary
if (( width > desired_size || height > desired_size )); then
    # Resize the image while preserving aspect ratio
    echo "Resizing $file -> $dst_path"
    magick "$file" -resize "${desired_size}x${desired_size}>" -format JPEG -quality "$quality" "$dst_path"
else

    # Get file extension (including the dot)
    file_ext_with_dot=".${file##*.}"
    file_ext_lower="${file_ext_with_dot,,}"

    # Determine the output extension
    if [[ "$file_ext_lower" == ".jpg" || "$file_ext_lower" == ".jpeg" ]]; then
        # If it's a jpeg extension, preserve it exactly as is
        output_extension="$file_ext_with_dot"
    else
        # Not a jpeg extension, use .jpg
        output_extension=".jpg"
    fi

    # Set destination path with correct extension
    dst_path="$dst_dir/${rel_path%.*}$output_extension"

    if [ "${format,,}" = "jpeg" ]; then
        if [[ "$file_ext_lower" == ".jpg" || "$file_ext_lower" == ".jpeg" ]]; then
            # File is already JPEG with .jpg/.jpeg extension - just copy
            echo "Copying $file -> $dst_path (JPG within size limits)"
            cp "$file" "$dst_path"
        else
            # File contains JPEG data but doesn't have JPG extension (e.g., JFIF)
            echo "Extracting JPEG data from $file -> $dst_path without recompression"

            # Create a temporary file
            temp_file=$(mktemp)

            # Use jpegtran to extract and copy the JPEG data without recompression
            jpegtran -copy all -optimize "$file" > "$temp_file"

            # Move the temp file to the destination
            mv "$temp_file" "$dst_path"
        fi
    else
        # For non-JPEGs, convert without resizing
        echo "Converting $file -> $dst_path (recompression required)"
        magick "$file" -format JPEG -quality "$quality" "$dst_path"
    fi

fi
