#!/bin/bash

# Check if a filename was provided
if [ -z "$1" ]; then
  echo "Usage: $0 <input_file_or_dir> [output_file_or_dir]"
  exit 1
fi

# Build file list
if [ -d "$1" ]; then
  input_dir="${1%/}"
  input_files=("$input_dir"/*.mkv)
  if [ ${#input_files[@]} -eq 0 ] || [ ! -e "${input_files[0]}" ]; then
    echo "No MKV files found in $input_dir"
    exit 1
  fi
  # When input is a directory, $2 must be a directory (or omitted)
  if [ -n "$2" ] && [ ! -d "$2" ]; then
    mkdir -p "$2"
  fi
else
  input_files=("$1")
fi

output_arg="${2:-}"

# Resolve output path for a given input file
resolve_output() {
  local infile="$1"
  if [ -n "$output_arg" ]; then
    if [ -d "$output_arg" ]; then
      echo "${output_arg%/}/$(basename "${infile%.*}.merged.mkv")"
    else
      # Exact file path (only valid for single-file mode)
      echo "$output_arg"
    fi
  else
    echo "${infile%.*}.merged.mkv"
  fi
}

# --- Build segment UID lookup (once, shared across all files) ---
work_dir="$(pwd)"
segments_file="${work_dir}/segments.csv"

# Scan all MKV files for their segment UIDs
all_mkv=(*.mkv)
echo 'filename,segmentuid' >"$segments_file"
for file in "${all_mkv[@]}"; do
  echo "Reading $file for Segment UID..."
  segment_uid=$(mkvinfo "$file" | awk '
    /Segment:/ { in_segment=1 }
    /Chapters/ { in_segment=0 }
    in_segment && /Segment UID:/ { print }
  ' | awk '{for(i=5; i<=NF; i++) printf "%s ", $i; printf "\n"}' | sed 's/ $//')
  echo "$file,$segment_uid" >>"$segments_file"
done

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

# === Process a single input file ===
process_file() {
  local input_file="$1"
  local output_file="$2"

  echo ""
  echo "========================================="
  echo "Processing: $input_file -> $output_file"
  echo "========================================="

  local chapter_file="${input_file%.*}.chapters.csv"
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

  # If the video does not have any remote segmentuids, skip
  local segmentuid_found
  segmentuid_found=$(awk -F, 'NR > 1 && $5 != ""' "$chapter_file")

  if [[ -z "$segmentuid_found" ]]; then
    echo "No remote segmentuids found in $input_file. Skipping."
    return 0
  fi

  echo "Remote segmentuids found. Proceeding."

  local temp_dir
  temp_dir=$(mktemp -d)

  # --- Read chapters into arrays ---
  local -a ch_nums=() ch_uids=() ch_starts=() ch_ends=() ch_segments=()
  local idx=0
  while IFS=',' read -r chapter uid start end segmentuid; do
    [[ "$chapter" == "chapter" ]] && continue
    ch_nums[$idx]="$chapter"
    ch_uids[$idx]="$uid"
    ch_starts[$idx]="$start"
    ch_ends[$idx]="$end"
    ch_segments[$idx]="${segmentuid:-}"
    ((idx++))
  done <"$chapter_file"
  local total_chapters=$idx
  echo "Found $total_chapters chapters."

  # --- Group chapters: consecutive local chapters together, remote chapters standalone ---
  local -a group_types=() group_si=() group_ei=()
  local gidx=0 i=0
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
  local total_groups=$gidx
  echo "Built $total_groups segment groups."

  # --- Extract each group into a temporary MKV segment ---
  local -a segment_files=()
  local -a new_ch_starts=() new_ch_ends=()
  local running_ns=0

  for ((g = 0; g < total_groups; g++)); do
    local si=${group_si[$g]}
    local ei=${group_ei[$g]}
    local seg_file="$temp_dir/segment_${g}.mkv"
    local start_ts="${ch_starts[$si]}"
    local end_ts="${ch_ends[$ei]}"

    if [[ "${group_types[$g]}" == "local" ]]; then
      echo "[$((g + 1))/$total_groups] Local chapters $((si + 1))-$((ei + 1)): $start_ts -> $end_ts from $input_file"
      mkvmerge -o "$seg_file" --no-chapters \
        --split "parts:${start_ts}-${end_ts}" "$input_file"
    else
      local remote_uid="${ch_segments[$si]}"
      local remote_file
      remote_file=$(find_file_by_segmentuid "$remote_uid")
      if [[ -z "$remote_file" ]]; then
        echo "ERROR: No file found for segment UID: $remote_uid"
        rm -rf "$temp_dir"
        return 1
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
      rm -rf "$temp_dir"
      return 1
    fi

    segment_files+=("$seg_file")

    # Recalculate chapter timestamps relative to the merged timeline
    local group_base_ns
    group_base_ns=$(timestamp_to_ns "$start_ts")
    for ((c = si; c <= ei; c++)); do
      local ch_start_ns ch_end_ns
      ch_start_ns=$(timestamp_to_ns "${ch_starts[$c]}")
      ch_end_ns=$(timestamp_to_ns "${ch_ends[$c]}")
      new_ch_starts[$c]=$(ns_to_timestamp $((running_ns + ch_start_ns - group_base_ns)))
      new_ch_ends[$c]=$(ns_to_timestamp $((running_ns + ch_end_ns - group_base_ns)))
    done

    # Advance the running timeline by this group's duration
    local group_end_ns
    group_end_ns=$(timestamp_to_ns "$end_ts")
    running_ns=$((running_ns + group_end_ns - group_base_ns))
  done

  echo "Total merged duration: $(ns_to_timestamp $running_ns)"

  # --- Generate Matroska chapters XML ---
  local chapters_xml="$temp_dir/chapters.xml"
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
  local -a merge_args=(-o "$output_file" --chapters "$chapters_xml")
  for ((g = 0; g < ${#segment_files[@]}; g++)); do
    if [ $g -gt 0 ]; then
      merge_args+=("+" "${segment_files[$g]}")
    else
      merge_args+=("${segment_files[$g]}")
    fi
  done

  echo "Merging ${#segment_files[@]} segments into $output_file ..."
  mkvmerge "${merge_args[@]}"

  rm -rf "$temp_dir"
  echo "Done! Output: $output_file"
}

# === Main loop: process each input file ===
success=0
fail=0
skipped=0

for infile in "${input_files[@]}"; do
  out=$(resolve_output "$infile")
  if process_file "$infile" "$out"; then
    # Check if it was skipped (no remote segments) vs actually merged
    if [ -f "$out" ]; then
      ((success++))
    else
      ((skipped++))
    fi
  else
    ((fail++))
  fi
done

echo ""
echo "===== Summary ====="
echo "Processed: ${#input_files[@]} file(s)"
echo "Merged:    $success"
echo "Skipped:   $skipped (no remote segments)"
echo "Failed:    $fail"
