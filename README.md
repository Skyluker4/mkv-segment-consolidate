# mkv-segment-consolidate.sh — MKV Segment Linking Resolver

A Bash script that merges MKV files using [Matroska segment linking](https://www.matroska.org/technical/chapters.html#linked-segments) (ordered chapters with external segment UIDs) into single, self-contained MKV files — **without re-encoding**.

## Problem

Some MKV releases use segment linking to share content (e.g. OP/ED sequences) across multiple episodes via external segment references. This means playback depends on all linked files being present in the same directory, and many players don't support it well.

This script resolves those external references by extracting the relevant portions from each source file and concatenating them into a single MKV with recalculated chapter timestamps.

## Requirements

- **[MKVToolNix](https://mkvtoolnix.download/)** (`mkvmerge`, `mkvinfo`) — must be in `$PATH`
- **Bash 4+**

## Usage

```bash
./mkv-segment-consolidate.sh <input_files_or_dir...> [options]
```

### Arguments

| Argument             | Description                                                                 |
| -------------------- | --------------------------------------------------------------------------- |
| `input_files_or_dir` | One or more MKV files or directories. Directories are searched recursively. |

### Options

| Option                | Description                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `-o <path>`           | Output file (single input) or directory (multiple inputs). Defaults to `<input>.merged.mkv` alongside the original. |
| `--prepend <prefix>`  | Prepend a string to the output file's title metadata.                                                               |
| `--append <suffix>`   | Append a string to the output file's title metadata.                                                                |
| `--include <pattern>` | Only process files whose filename matches this regular expression.                                                  |
| `--exclude <pattern>` | Skip files whose filename matches this regular expression.                                                          |
| `-h`, `--help`        | Show help and exit.                                                                                                 |

When both `--include` and `--exclude` are given, `--include` is applied first.

## Examples

**Single file:**

```bash
./mkv-segment-consolidate.sh 02.mkv
# Output: 02.merged.mkv
```

**Single file with custom output path:**

```bash
./mkv-segment-consolidate.sh 02.mkv -o ./out/episode_02.mkv
```

**All files in current directory, output to a separate folder:**

```bash
./mkv-segment-consolidate.sh ./ -o ./out/
```

**Process only numbered episodes, skip specials:**

```bash
./mkv-segment-consolidate.sh ./ --include '^[0-9]' --exclude '^(SP|ED|OP)'
```

**Add title metadata:**

```bash
./mkv-segment-consolidate.sh ./ --prepend "My Show - " --append " [BD]"
# e.g. file 02.mkv gets title "My Show - 02 [BD]"
```

**Multiple specific files:**

```bash
./mkv-segment-consolidate.sh 02.mkv 03.mkv 04.mkv -o ./out/
```

## How It Works

1. **Parse chapters** — Reads chapter information from the input MKV using `mkvinfo`, identifying which chapters reference external segments via segment UIDs.
2. **Build segment UID map** — Scans all MKV files in the working directory to build a lookup table mapping segment UIDs to filenames.
3. **Group chapters** — Groups consecutive local chapters together; remote (externally-linked) chapters become standalone groups.
4. **Extract segments** — Uses `mkvmerge --split parts:` to extract each group's time range from the correct source file (no re-encoding).
5. **Recalculate timestamps** — Computes new chapter timestamps for a continuous merged timeline.
6. **Generate chapters XML** — Creates Matroska-format chapter metadata with the recalculated timestamps.
7. **Concatenate** — Joins all segments using `mkvmerge` append mode with the new chapters embedded.

Files without remote segment UIDs are automatically skipped. A summary of merged/skipped/failed files is printed at the end.

## License

Public domain. Use however you like.
