#!/bin/bash

# Configuration
src_dir="./all"
dst_dir="./smallified"
target_sizes=("720" "480")  # Must be sorted in descending order
target_quality=75  # Quality level (mapped to CRF)
accepted_formats=("mp4" "mov" "webm" "mkv" "avi")
compatible_codecs=("h264" "mpeg4")  # Removed hevc, focus on h264 compatibility
preferred_codec="h264"  # Changed from hevc to h264
strip_audio="yes"  # Remove audio if "yes"
max_jobs=4
worker_script="worker_ffmpeg.sh"
error_log="./ffmpeg_errors.log"

# Convert src_dir to absolute path
src_dir=$(realpath "$src_dir")

# Clear the error log
: > "$error_log"

# Function to write the worker script
write_worker_script() {
    local -n cmd_array=$1
    : > "$worker_script"
    echo "#!/bin/bash" > "$worker_script"
    echo "
run_ffmpeg() {
    local sync=false
    if [[ \"\$1\" == \"-s\" ]]; then
        sync=true
        shift
    fi
    local cmd=\"\$1\"
    echo \"Running: \$cmd\" >> \"$error_log\"
    while (( \$(jobs -r | wc -l) >= $max_jobs )); do
        sleep 1
    done
    if \$sync; then
        bash -c \"\$cmd\" >> \"$error_log\" 2>&1
    else
        bash -c \"\$cmd\" >> \"$error_log\" 2>&1 &
    fi
}
" >> "$worker_script"
    for cmd in "${cmd_array[@]}"; do
        echo "$cmd" >> "$worker_script"
    done
    echo "wait" >> "$worker_script"
    chmod +x "$worker_script"
}

# Function to get video information
get_video_info() {
    local file="$1"
    local width height codec container

    # Extract video stream properties using a better output format
    # The problem is that -of csv=p=0 adds commas to the output
    # Using default=noprint_wrappers=1:nokey=1 gives clean values
    width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$file")
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$file")
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file")
    container=$(ffprobe -v error -show_entries format=format_name -of default=noprint_wrappers=1:nokey=1 "$file")
    
    # Add instrumentation to see exactly what values we're getting - send to stderr
    echo "DEBUG: file='$file'" >&2
    echo "DEBUG: width='$width'" >&2
    echo "DEBUG: height='$height'" >&2
    echo "DEBUG: codec='$codec'" >&2
    echo "DEBUG: container='$container'" >&2

    # Validate extracted values
    if [[ -z "$width" || -z "$height" || -z "$codec" ]]; then
        echo "ERROR: Missing or invalid metadata for file $file. Skipping." >&2
        exit 1
    fi

    echo "${width} ${height} ${codec} ${container}"
}

# Function to generate the common encoding parameters
get_encoding_params() {
    local crf=$1
    
    echo "-c:v libx264 \
  -crf $crf \
  -preset slower \
  -tune grain \
  -movflags +faststart \
  -g 24 -keyint_min 24 -sc_threshold 30 \
  -aq-mode 3 -aq-strength 0.9 \
  -refs 5 \
  -bf 3 \
  -b_strategy 2 \
  -temporal-aq 1 \
  -psy-rd 1.0:0.15 \
  -rc-lookahead 48 \
  -x264opts no-dct-decimate:no-fast-pskip=1 \
  -deblock -1:-1 \
  -an"
}

# Step 1: Capture filenames into an array
files=()
while IFS= read -r -d '' file; do
    files+=("$file")
done < <(find "$src_dir" -type f -print0)

# Step 2: Process each file
for file in "${files[@]}"; do
    ext="${file##*.}"
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    # Check if file format is accepted
    if [[ " ${accepted_formats[*]} " == *" $ext_lower "* ]]; then
        rel_path="${file#$src_dir/}"
        dir_name=$(dirname "$rel_path")
        base_name="$(basename "${rel_path%.*}")"  # Get basename without extension

        # Get video details
        read -r width height codec container <<< "$(get_video_info "$file")"

        input_file="$file"
        sync_flag="-s"
        commands=()
        post_process_commands=()
        
        # Calculate enhanced CRF value once
        enhanced_crf=$((100 - target_quality - 5))
        # Get encoding parameters once
        encoding_params=$(get_encoding_params $enhanced_crf)

        for size in "${target_sizes[@]}"; do
            dst_path="$dst_dir/$dir_name/${base_name}-${size}p.mp4"
            mkdir -p "$(dirname "$dst_path")"
            copied_path="$dst_dir/$dir_name/${base_name}-${size}p-copied.mp4"
            transcoded_path="$dst_dir/$dir_name/${base_name}-${size}p-transcoded.mp4"

            # Determine if resizing is needed
            resize_needed=false
            echo "DEBUG: Before comparison - width='$width', height='$height', size='$size'" >&2
            if (( width != size && height != size )); then
                echo "DEBUG: Resize needed" >&2
                resize_needed=true
            fi

            # Determine ffmpeg commands
            if [[ "$resize_needed" == false && "$ext_lower" == "mp4" && " ${compatible_codecs[*]} " == *" $codec "* ]]; then
                # Create both copied and transcoded versions
                ffmpeg_cmd_copied="ffmpeg -y -i \"$input_file\" -c:v copy -an \"$copied_path\""
                ffmpeg_cmd_transcoded="ffmpeg -y -i \"$input_file\" $encoding_params \"$transcoded_path\""

                # Add commands to the list
                commands+=("run_ffmpeg $sync_flag $(printf "%q" "$ffmpeg_cmd_copied")")
                commands+=("run_ffmpeg $sync_flag $(printf "%q" "$ffmpeg_cmd_transcoded")")
                
                # Add post-processing command to compare file sizes and handle appropriately
                post_process_commands+=("compare_transcoded_size \"$copied_path\" \"$transcoded_path\" \"$dst_path\"")

                # Use the copied version as input for further shrinkings
                input_file="$copied_path"
            else
                # Transcode with resizing or enforce quality
                # Adjust for orientation
                if (( width > height )); then
                    # Landscape: Resize by height
                    scale_filter="scale=-2:$size"
                else
                    # Portrait: Resize by width
                    scale_filter="scale=$size:-2"
                fi
                
                ffmpeg_cmd="ffmpeg -y -i \"$input_file\" -vf $scale_filter $encoding_params \"$dst_path\""
                commands+=("run_ffmpeg $sync_flag $(printf "%q" "$ffmpeg_cmd")")
            fi
        done

        # Modify the worker script to include the comparison function and post-processing
        : > "$worker_script"
        echo "#!/bin/bash" > "$worker_script"
        
        # Add the asymmetric comparison function
        echo "
# Function to compare transcoded file size to copied file size
# If transcoded is larger, delete it and rename copied to final
# If transcoded is smaller, leave both for human evaluation
compare_transcoded_size() {
    local copied_file=\"\$1\"
    local transcoded_file=\"\$2\"
    local final_file=\"\$3\"
    
    # Check if both files exist
    if [[ ! -f \"\$copied_file\" || ! -f \"\$transcoded_file\" ]]; then
        echo \"ERROR: One of the files does not exist: \$copied_file or \$transcoded_file\" >> \"$error_log\"
        return 1
    fi
    
    # Get file sizes
    local copied_size=\$(stat -c %s \"\$copied_file\")
    local transcoded_size=\$(stat -c %s \"\$transcoded_file\")
    
    echo \"DEBUG: copied_size='\$copied_size', transcoded_size='\$transcoded_size'\" >&2
    echo \"Size comparison: Copied (\$copied_size bytes) vs Transcoded (\$transcoded_size bytes)\" >&2
    
    # Asymmetric comparison logic
    echo \"DEBUG: Before comparison - transcoded_size='\$transcoded_size', copied_size='\$copied_size'\" >&2
    if (( transcoded_size >= copied_size )); then
        echo \"Transcoded file is larger than or equal to copied file. Deleting transcoded and renaming copied.\" >&2
        # Remove transcoded file (it's larger AND worse quality)
        rm \"\$transcoded_file\"
        # Rename copied file to final name
        mv \"\$copied_file\" \"\$final_file\"
    else
        echo \"Transcoded file is smaller. Leaving both files for human evaluation.\" >&2
        # Leave both files intact for human evaluation
        # Rename copied file to clearer name to indicate it's the lossless copy
        dir_name=\$(dirname \"\$copied_file\")
        base_name=\$(basename \"\$copied_file\" | sed 's/-copied//')
        mv \"\$copied_file\" \"\${dir_name}/\${base_name%.*}-lossless.mp4\"
    fi
}

run_ffmpeg() {
    local sync=false
    if [[ \"\$1\" == \"-s\" ]]; then
        sync=true
        shift
    fi
    local cmd=\"\$1\"
    echo \"Running: \$cmd\" >> \"$error_log\"
    while (( \$(jobs -r | wc -l) >= $max_jobs )); do
        sleep 1
    done
    if \$sync; then
        bash -c \"\$cmd\" >> \"$error_log\" 2>&1
    else
        bash -c \"\$cmd\" >> \"$error_log\" 2>&1 &
    fi
}
" >> "$worker_script"

        # Add the ffmpeg commands
        for cmd in "${commands[@]}"; do
            echo "$cmd" >> "$worker_script"
        done
        
        # Wait for all ffmpeg processes to complete
        echo "wait" >> "$worker_script"
        
        # Add the post-processing commands
        for cmd in "${post_process_commands[@]}"; do
            echo "$cmd" >> "$worker_script"
        done
        
        chmod +x "$worker_script"
        # Immediate resumption check right before handing control to the worker:
        # If any expected final already exists, snapshot this worker for later re-run and skip executing it now.
        for __dst_size in "${target_sizes[@]}"; do
            __dst="$dst_dir/$dir_name/${base_name}-${__dst_size}p.mp4"
            if [[ -f "${__dst}" ]]; then
                 interrupted_worker_script="interrupted-$worker_script"
                 cp -f "$worker_script" "$interrupted_worker_script"
                 chmod +x "$interrupted_worker_script" 2>/dev/null || true
                 echo "Wrote interrupted worker snapshot: $interrupted_worker_script" >&2
                 # Skip running this worker and continue with the next input file
                 continue 2
             fi
        done
        bash "$worker_script"
    fi
done

# --- End of main processing: execute and remove interrupted snapshot if present ---
# Only execute the snapshot if the in-memory variable was set when the snapshot was created.
if [[ -n "${interrupted_worker_script:-}" && -f "$interrupted_worker_script" ]]; then
    echo "Executing interrupted worker script: $interrupted_worker_script" >&2
    bash "$interrupted_worker_script"
    rm -f "$interrupted_worker_script"
fi
