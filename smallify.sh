#!/bin/bash

src_dir=${1-"./all"}
dst_dir=${2-"./smallified"}
desired_size=${3-1600}

# Create the destination directory if it doesn't exist
mkdir -p "$dst_dir"

# Find all JPEG files in the source directory and its subdirectories
find "$src_dir" -type f -name "*.jpg" -o -name "*.jpeg" | while read -r file; do
    # Determine the relative path and filename from source directory
    rel_path="${file#$src_dir/}"
    
    # Determine the destination path and filename
    dst_path="$dst_dir/$rel_path"
    
    # Create the destination directory if it doesn't exist
    mkdir -p "$(dirname "$dst_path")"
    
    # Check the dimensions of the image using ImageMagick's identify command
    dimensions=$(identify -format "%w %h" "$file")
    read -r width height <<< "$dimensions"
    
    # Check if resizing is necessary
    if (( width > $desired_size || height > $desired_size )); then
        # Resize the image while preserving aspect ratio
        convert "$file" -resize "${desired_size}x${desired_size}>" "$dst_path"
    else
        # Copy the image to the destination directory
        cp "$file" "$dst_path"
    fi
done 
