#!/bin/bash

# Check if a filename was provided
if [ -z "$1" ]; then
  echo "Usage: $0 <input_file>"
  exit 1
fi

work_dir=$(dirname "$1")

input_file="$1"
output_file="${input_file%.*}.merged.mkv"

echo "Reading $input_file for chapters..."

chapter_file="${work_dir}/${input_file%.*}.chapters.csv"
echo 'chapter,uid,start,end,segmentuid' >"$chapter_file"

# Save each chapter's info into the array
mkvinfo "$input_file" | awk '
BEGIN { chapter_number = 1 }
/Chapter UID/ && !uid_set {uid=$NF; uid_set=1}
/Chapter time start/ {start=$NF}
/Chapter time end/ {end=$NF}
/Chapter segment UID/ {segment=$0; sub(/.*: /, "", segment)}
/Chapter atom/ && start != "" && end != "" && uid != "" {
  print_chapter()
  start=""; end=""; segment=""; uid=""; uid_set=0
}
END {
  if (start != "" && end != "" && uid != "") {
    print_chapter()
  }
}
function print_chapter() {
  printf "Chapter %d UID: %s Start: %s End: %s", chapter_number, uid, start, end;
  if (segment != "") {
    printf ", Segment UID: %s", segment;
  }
  print ""
  chapter_number++
}' | while read -r chapter_info; do
  chapter=$(echo "$chapter_info" | awk '{print $2}')
  uid=$(echo "$chapter_info" | awk '{print $4}')
  start=$(echo "$chapter_info" | awk '{print $6}')
  end=$(echo "$chapter_info" | awk '{print $8}')
  segment=$(echo "$chapter_info" | awk '{for(i=11; i<=NF; i++) printf "%s ", $i; printf "\n"}' | sed 's/ $//')
  echo "$chapter,$uid,$start,$end$segment" >>"$chapter_file"
done

# If the video does not have any remote segmentuids, exit
segmentuid_found=$(awk -F, 'NR > 1 && $5 != ""' "$chapter_file")

if [[ -z "$segmentuid_found" ]]; then
  echo "No remote segmentuids found. Exiting."
  exit 1
fi

echo "Remote segmentuids found. Proceeding."

# Define an array for other files
other_files=(*.mkv) # Adjust the glob pattern or file list as needed

# Output file
segments_file="${work_dir}/segments.csv"

# Create the CSV file with header
echo 'filename,segmentuid' >"$segments_file"

# Process each file
for file in "${other_files[@]}"; do
  echo "Reading $file for Segment UID..."

  segment_uid=$(mkvinfo "$file" | awk '
    /Segment:/ { in_segment=1 }
    /Chapters/ { in_segment=0 }
    in_segment && /Segment UID:/ { print }
  ' | awk '{for(i=5; i<=NF; i++) printf "%s ", $i; printf "\n"}' | sed 's/ $//')

  # Append filename and Segment UID to the CSV file
  echo "$file,$segment_uid" >>"$segments_file"
done

# === Merge Logic: split, recalculate chapters, concatenate ===

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

# Lookup filename by segment UID from segments.csv
find_file_by_segmentuid() {
  local target_uid="$1"
  awk -F, -v uid="$target_uid" 'NR > 1 && $2 == uid { print $1; exit }' "$segments_file"
}

# Convert HH:MM:SS.NNNNNNNNN to nanoseconds
timestamp_to_ns() {
  local ts="$1"
  local h="${ts%%:*}"; ts="${ts#*:}"
  local m="${ts%%:*}"; ts="${ts#*:}"
  local s="${ts%%.*}"
  local ns="${ts#*.}"
  ns="${ns}000000000"; ns="${ns:0:9}"
  echo $(( (10#$h * 3600 + 10#$m * 60 + 10#$s) * 1000000000 + 10#$ns ))
}

# Convert nanoseconds to HH:MM:SS.NNNNNNNNN
ns_to_timestamp() {
  local total_ns=$1
  local h=$((total_ns / 3600000000000))
  local remainder=$((total_ns % 3600000000000))
  local m=$((remainder / 60000000000))
  remainder=$((remainder % 60000000000))
  local s=$((remainder / 1000000000))
  local ns=$((remainder % 1000000000))
  printf "%02d:%02d:%02d.%09d" "$h" "$m" "$s" "$ns"
}

# --- Read chapters into arrays ---
declare -a ch_nums=() ch_uids=() ch_starts=() ch_ends=() ch_segments=()
idx=0
while IFS=',' read -r chapter uid start end segmentuid; do
  [[ "$chapter" == "chapter" ]] && continue
  ch_nums[$idx]="$chapter"
  ch_uids[$idx]="$uid"
  ch_starts[$idx]="$start"
  ch_ends[$idx]="$end"
  ch_segments[$idx]="${segmentuid:-}"
  ((idx++))
done <"$chapter_file"
total_chapters=$idx
echo "Found $total_chapters chapters."

# --- Group chapters: consecutive local chapters together, remote chapters standalone ---
declare -a group_types=() group_si=() group_ei=()
gidx=0
i=0
while [ $i -lt $total_chapters ]; do
  if [[ -n "${ch_segments[$i]}" ]]; then
    group_types[$gidx]="remote"
    group_si[$gidx]=$i
    group_ei[$gidx]=$i
    ((gidx++))
    ((i++))
  else
    group_types[$gidx]="local"
    group_si[$gidx]=$i
    while [ $i -lt $total_chapters ] && [[ -z "${ch_segments[$i]}" ]]; do
      ((i++))
    done
    group_ei[$gidx]=$((i - 1))
    ((gidx++))
  fi
done
total_groups=$gidx
echo "Built $total_groups segment groups."

# --- Extract each group into a temporary MKV segment ---
declare -a segment_files=()
declare -a new_ch_starts=() new_ch_ends=()
running_ns=0

for ((g = 0; g < total_groups; g++)); do
  si=${group_si[$g]}
  ei=${group_ei[$g]}
  seg_file="$temp_dir/segment_${g}.mkv"
  start_ts="${ch_starts[$si]}"
  end_ts="${ch_ends[$ei]}"

  if [[ "${group_types[$g]}" == "local" ]]; then
    echo "[$((g + 1))/$total_groups] Local chapters $((si + 1))-$((ei + 1)): $start_ts -> $end_ts from $input_file"
    mkvmerge -o "$seg_file" --no-chapters \
      --split "parts:${start_ts}-${end_ts}" "$input_file"
  else
    remote_uid="${ch_segments[$si]}"
    remote_file=$(find_file_by_segmentuid "$remote_uid")
    if [[ -z "$remote_file" ]]; then
      echo "ERROR: No file found for segment UID: $remote_uid"
      exit 1
    fi
    echo "[$((g + 1))/$total_groups] Remote chapter $((si + 1)): $start_ts -> $end_ts from $remote_file"
    mkvmerge -o "$seg_file" --no-chapters \
      --split "parts:${start_ts}-${end_ts}" "$remote_file"
  fi

  # mkvmerge may append -001 to the output filename when --split is used
  if [ ! -f "$seg_file" ] && [ -f "${seg_file%.*}-001.mkv" ]; then
    mv "${seg_file%.*}-001.mkv" "$seg_file"
  fi

  if [ ! -f "$seg_file" ]; then
    echo "ERROR: Failed to extract segment for group $((g + 1))"
    exit 1
  fi

  segment_files+=("$seg_file")

  # Recalculate chapter timestamps relative to the merged timeline
  group_base_ns=$(timestamp_to_ns "$start_ts")
  for ((c = si; c <= ei; c++)); do
    ch_start_ns=$(timestamp_to_ns "${ch_starts[$c]}")
    ch_end_ns=$(timestamp_to_ns "${ch_ends[$c]}")
    new_ch_starts[$c]=$(ns_to_timestamp $((running_ns + ch_start_ns - group_base_ns)))
    new_ch_ends[$c]=$(ns_to_timestamp $((running_ns + ch_end_ns - group_base_ns)))
  done

  # Advance the running timeline by this group's duration
  group_end_ns=$(timestamp_to_ns "$end_ts")
  running_ns=$((running_ns + group_end_ns - group_base_ns))
done

echo "Total merged duration: $(ns_to_timestamp $running_ns)"

# --- Generate Matroska chapters XML ---
chapters_xml="$temp_dir/chapters.xml"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<Chapters>'
  echo '  <EditionEntry>'
  for ((c = 0; c < total_chapters; c++)); do
    echo '    <ChapterAtom>'
    echo "      <ChapterTimeStart>${new_ch_starts[$c]}</ChapterTimeStart>"
    echo "      <ChapterTimeEnd>${new_ch_ends[$c]}</ChapterTimeEnd>"
    echo "      <ChapterUID>${ch_uids[$c]}</ChapterUID>"
    echo '    </ChapterAtom>'
  done
  echo '  </EditionEntry>'
  echo '</Chapters>'
} >"$chapters_xml"

echo "Generated chapters XML with recalculated timestamps."

# --- Concatenate all segments into the final merged MKV ---
merge_args=(-o "$output_file" --chapters "$chapters_xml")
for ((g = 0; g < ${#segment_files[@]}; g++)); do
  if [ $g -gt 0 ]; then
    merge_args+=("+" "${segment_files[$g]}")
  else
    merge_args+=("${segment_files[$g]}")
  fi
done

echo "Merging ${#segment_files[@]} segments into $output_file ..."
mkvmerge "${merge_args[@]}"

echo "Done! Output: $output_file"
