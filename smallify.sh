#!/bin/bash

src_dir="./all"
dst_dir="./smallified"
desired_size=2000

# Create the destination directory if it doesn't exist
mkdir -p "$dst_dir"

# Find all image files in the source directory and its subdirectories
find "$src_dir" -type f -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.tiff" -o -iname "*.jfif" -o -iname "*.heic" -o -iname "*.HEIC" | while read -r file; do
    # Determine the relative path and filename from source directory
    rel_path="${file#$src_dir/}"
    
    # Get original format and quality
    format=$(magick identify -format '%m' "$file")
    quality=$(magick identify -format '%Q' "$file")
    
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
    dimensions=$(identify -format "%w %h" "$file")
    read -r width height <<< "$dimensions"
    
    # Check if resizing is necessary
    if (( width > $desired_size || height > $desired_size )); then
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
done