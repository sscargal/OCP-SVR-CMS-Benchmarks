#!/usr/bin/env bash
#
# gen_report.sh - Generate a Markdown summary report from an mlc.sh output directory.
#
# Usage: gen_report.sh <mlc.sh-output-directory>
#
# Writes <directory>/summary_report.md summarizing the run: system info,
# which tests ran and whether they succeeded, and tables comparing peak
# latency/bandwidth per Socket->Node and per DRAM+CXL interleave pair.
# Pure bash/awk/grep - no Python, no new dependencies. Safe to re-run
# standalone at any time against an existing output directory.

set -u

SCRIPT_NAME=${0##*/}

usage() {
  echo "Usage: ${SCRIPT_NAME} <mlc.sh-output-directory>"
  echo
  echo "Writes <directory>/summary_report.md summarizing an mlc.sh benchmark run."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

DIR="${1%/}"

if [[ ! -d "${DIR}" ]]; then
  echo "ERROR: '${DIR}' is not a directory" >&2
  exit 1
fi

LOG="${DIR}/mlc.sh.log"
REPORT="${DIR}/summary_report.md"

# Exclude the report itself (and any prior copy) from every scan below.
is_report_file() {
  case "${1##*/}" in
    summary_report.md|*_report.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Recognizability gate: refuse to write a garbage report against an
# unrelated directory.
recognizable=0
for pattern in 'idle_latency_*.txt' 'bw_node*.txt' 'bw_ramp.results.*.csv' 'bw_ramp_interleave.results.*.csv'; do
  for f in "${DIR}"/${pattern}; do
    if [[ -e "${f}" ]]; then
      recognizable=1
      break 2
    fi
  done
done
if [[ "${recognizable}" -eq 0 ]]; then
  echo "ERROR: '${DIR}' contains no recognizable mlc.sh output files" >&2
  exit 1
fi

#################################################################################################
# System info (from mlc.sh.log; degrades to n/a if the log is missing)
#################################################################################################

sut_hostname="n/a"
sut_platform="n/a"
sut_mlc_ver="n/a"
sut_mlc_sh_ver="n/a"
sut_invocation="n/a"
sut_sockets_in_system="n/a"
sut_cores_per_socket="n/a"
sut_numa_nodes="n/a"
sut_started="n/a"
sut_ended="n/a"
sut_duration="n/a"
run_status="Unknown (log missing)"
log_missing_note=""

base_dir_name="${DIR##*/}"
if [[ "${base_dir_name}" =~ ^mlc\.sh\.(.+)\.[0-9]{4}-[0-9]{4}$ ]]; then
  sut_hostname="${BASH_REMATCH[1]}"
fi

log_error_lines=()
if [[ -f "${LOG}" ]]; then
  sut_mlc_sh_ver=$(grep -m1 '^mlc.sh Version ' "${LOG}" | awk '{print $3}')
  sut_invocation=$(grep -m1 -E '^mlc\.sh .*-' "${LOG}")
  sut_started=$(grep -m1 '^Started: ' "${LOG}" | cut -d' ' -f2-)
  sut_sockets_in_system=$(grep -m1 'Number of Physcial Sockets:' "${LOG}" | awk -F: '{print $NF}' | xargs)
  sut_cores_per_socket=$(grep -m1 '^CPU cores per socket:' "${LOG}" | awk -F: '{print $NF}' | xargs)
  sut_numa_nodes=$(grep -m1 'Number of NUMA Node(s):' "${LOG}" | awk -F: '{print $NF}' | xargs)
  sut_platform=$(grep -m1 -oE 'Detected .* platform' "${LOG}")
  sut_mlc_ver=$(grep -m1 -oE 'Intel\(R\) Memory Latency Checker - v[0-9.]+' "${LOG}" | grep -oE 'v[0-9.]+')

  if grep -q '^mlc.sh Completed' "${LOG}"; then
    run_status="Completed"
    sut_ended=$(grep -m1 '^Ended: ' "${LOG}" | cut -d' ' -f2-)
    sut_duration=$(grep -m1 '^Duration: ' "${LOG}" | cut -d' ' -f2-)
  else
    run_status="In progress / incomplete"
  fi

  mapfile -t log_error_lines < <(grep -iE 'error|fail|cannot|denied|not found' "${LOG}" \
    | grep -viE 'latency optimized mode|Random bandwidth option is supported only' \
    | sort -u | head -10)

  [[ -z "${sut_mlc_sh_ver}" ]] && sut_mlc_sh_ver="n/a"
  [[ -z "${sut_invocation}" ]] && sut_invocation="n/a"
  [[ -z "${sut_started}" ]] && sut_started="n/a"
  [[ -z "${sut_sockets_in_system}" ]] && sut_sockets_in_system="n/a"
  [[ -z "${sut_cores_per_socket}" ]] && sut_cores_per_socket="n/a"
  [[ -z "${sut_numa_nodes}" ]] && sut_numa_nodes="n/a"
  [[ -z "${sut_platform}" ]] && sut_platform="n/a"
  [[ -z "${sut_mlc_ver}" ]] && sut_mlc_ver="n/a"
  [[ -z "${sut_ended}" ]] && sut_ended="n/a"
  [[ -z "${sut_duration}" ]] && sut_duration="n/a"
else
  log_missing_note="\`mlc.sh.log\` not found in this directory - system info and log-based error scanning are unavailable."
fi

#################################################################################################
# Topology discovery + peak bandwidth/latency per (socket, node)
#################################################################################################

declare -A NODE_TYPE   # NODE_TYPE[socket:node] = DRAM|CXL|unknown
declare -A IDLE_SEQ    # IDLE_SEQ[socket:node]  = ns
declare -A IDLE_RAND   # IDLE_RAND[socket:node] = ns
declare -A PEAK_BW     # PEAK_BW[socket:node]   = "bw|cores|lat|maxcores"

for f in "${DIR}"/bw_ramp.results.node_*.R.seq.*.socket_*.csv; do
  [[ -e "${f}" ]] || continue
  base="${f##*/}"
  node=$(echo "${base}" | sed -E 's/^bw_ramp\.results\.node_([0-9]+)\..*/\1/')
  sock=$(echo "${base}" | sed -E 's/.*\.socket_([0-9]+)\.csv$/\1/')
  key="${sock}:${node}"

  ratio=$(awk -F, 'NR==2{gsub(/"/,"",$3); print $3; exit}' "${f}")
  case "${ratio}" in
    100:0) NODE_TYPE[${key}]="DRAM" ;;
    0:100) NODE_TYPE[${key}]="CXL" ;;
    *) NODE_TYPE[${key}]="unknown" ;;
  esac

  PEAK_BW[${key}]=$(awk -F, 'NR>1 && $9!="" {
      v=$9+0
      if (v>mb) { mb=v; c=$5; l=$8 }
      last=$5
    }
    END { if (mb>0) printf "%.1f|%s|%s|%s", mb, c, l, last }' "${f}")

  idle_seq_file="${DIR}/idle_latency_seq_numa_node_${node}.socket_${sock}.txt"
  idle_rand_file="${DIR}/idle_latency_rand_numa_node_${node}.socket_${sock}.txt"
  [[ -f "${idle_seq_file}" ]] && IDLE_SEQ[${key}]=$(awk '/Each iteration took/{print $(NF-1); exit}' "${idle_seq_file}")
  [[ -f "${idle_rand_file}" ]] && IDLE_RAND[${key}]=$(awk '/Each iteration took/{print $(NF-1); exit}' "${idle_rand_file}")
done

node_keys_sorted=$(printf '%s\n' "${!PEAK_BW[@]}" | sort -t: -k1,1n -k2,2n)

#################################################################################################
# Interleave pair discovery + peak bandwidth/latency (seq only)
#################################################################################################

declare -A ILEAVE_PEAK  # ILEAVE_PEAK[socket:dnode:cnode:wtype] = "bw|cores|lat|ratio"
declare -A ILEAVE_SEEN
ileave_keys=()

for f in "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.seq.*.socket_*.csv; do
  [[ -e "${f}" ]] || continue
  base="${f##*/}"
  dnode=$(echo "${base}" | sed -E 's/^bw_ramp_interleave\.results\.node_([0-9]+)\.node_[0-9]+\..*/\1/')
  cnode=$(echo "${base}" | sed -E 's/^bw_ramp_interleave\.results\.node_[0-9]+\.node_([0-9]+)\..*/\1/')
  wtype=$(echo "${base}" | sed -E 's/^bw_ramp_interleave\.results\.node_[0-9]+\.node_[0-9]+\.(W[0-9]+)\..*/\1/')
  sock=$(echo "${base}" | sed -E 's/.*\.socket_([0-9]+)\.csv$/\1/')
  key="${sock}:${dnode}:${cnode}:${wtype}"
  if [[ -z "${ILEAVE_SEEN[${key}]:-}" ]]; then
    ILEAVE_SEEN[${key}]=1
    ileave_keys+=("${key}")
  fi
done

if [[ "${#ileave_keys[@]}" -gt 0 ]]; then
  ileave_keys_sorted=$(printf '%s\n' "${ileave_keys[@]}" | sort -t: -k1,1n -k2,2n -k3,3n -k4,4)
else
  ileave_keys_sorted=""
fi

for key in ${ileave_keys_sorted}; do
  IFS=':' read -r sock dnode cnode wtype <<< "${key}"
  files=("${DIR}"/bw_ramp_interleave.results.node_${dnode}.node_${cnode}.${wtype}.seq.*.socket_${sock}.csv)
  ILEAVE_PEAK[${key}]=$(awk -F, 'FNR>1 && $8!="" {
      gsub(/"/,"",$3)
      v=$8+0
      if (v>mb) { mb=v; c=$4; l=$7; r=$3 }
    }
    END { if (mb>0) printf "%.1f|%s|%s|%s", mb, c, l, r }' "${files[@]}")
done

# Known MLC limitation: interleave rand files (from pre-fix mlc.sh runs) can
# never contain real data - random access is unsupported for W21/W23/W27.
rand_interleave_present=0
for f in "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.rand.*.socket_*.csv; do
  if [[ -e "${f}" ]]; then
    rand_interleave_present=1
    break
  fi
done

#################################################################################################
# Data-completeness scan (flag genuinely unexplained blank data)
#################################################################################################

unexplained_blank_files=()
for f in "${DIR}"/bw_ramp.results.*.csv "${DIR}"/bw_ramp_interleave.results.*.seq.*.csv; do
  [[ -e "${f}" ]] || continue
  blank=$(awk -F, 'NR>1 { n++; if ($NF=="") b++ } END { print (n>0 && n==b) ? "1" : "0" }' "${f}")
  if [[ "${blank}" == "1" ]]; then
    unexplained_blank_files+=("${f##*/}")
  fi
done

if [[ "${#log_error_lines[@]}" -gt 0 || "${#unexplained_blank_files[@]}" -gt 0 ]] && [[ "${run_status}" == "Completed" ]]; then
  run_status="Completed with warnings"
fi

#################################################################################################
# Anomaly detection: bandwidth that peaks early then declines >20% by the
# highest core count tested (e.g. CXL link saturation/back-pressure).
#################################################################################################

anomalies=()
for key in ${node_keys_sorted}; do
  IFS='|' read -r bw cores lat maxcores <<< "${PEAK_BW[${key}]:-}"
  [[ -z "${bw:-}" ]] && continue
  IFS=':' read -r sock node <<< "${key}"
  f=$(ls "${DIR}"/bw_ramp.results.node_${node}.R.seq.*.socket_${sock}.csv 2>/dev/null | head -1)
  [[ -z "${f}" ]] && continue
  tail_bw=$(awk -F, -v mc="${maxcores}" 'NR>1 && $5==mc && $9!="" {print $9+0; exit}' "${f}")
  if [[ -n "${tail_bw:-}" ]]; then
    drop_pct=$(awk -v peak="${bw}" -v tail="${tail_bw}" 'BEGIN { if (peak>0) printf "%.0f", ((peak-tail)/peak)*100; else print 0 }')
    if [[ "${drop_pct}" -gt 20 ]]; then
      anomalies+=("Socket ${sock} -> Node ${node} (${NODE_TYPE[${key}]:-unknown}) bandwidth peaks at ${cores} of ${maxcores} cores tested (${bw} MB/s) then declines ${drop_pct}% to ${tail_bw} MB/s by ${maxcores} cores - possible bandwidth saturation/back-pressure.")
    fi
  fi
done

#################################################################################################
# Charts
#################################################################################################

png_files=()
for f in "${DIR}"/*.png; do
  [[ -e "${f}" ]] && png_files+=("${f##*/}")
done

#################################################################################################
# Raw output file inventory (grouped counts, not an itemized list)
#################################################################################################

human_size() {
  awk -v b="${1}" 'BEGIN {
    if (b>=1048576) printf "%.1f MiB", b/1048576
    else if (b>=1024) printf "%.1f KiB", b/1024
    else printf "%d B", b
  }'
}

group_stats() {  # prints "count|totalbytes" for the given glob patterns
  local n=0 total=0 sz
  for f in "$@"; do
    [[ -e "${f}" ]] || continue
    is_report_file "${f}" && continue
    n=$((n + 1))
    sz=$(stat -c '%s' "${f}" 2>/dev/null || echo 0)
    total=$((total + sz))
  done
  echo "${n}|${total}"
}

read -r idle_count idle_bytes <<< "$(group_stats "${DIR}"/idle_latency_*.txt | tr '|' ' ')"
read -r bwtxt_count bwtxt_bytes <<< "$(group_stats "${DIR}"/bw_node*.txt | tr '|' ' ')"
read -r ramp_count ramp_bytes <<< "$(group_stats "${DIR}"/bw_ramp.results.*.csv | tr '|' ' ')"
read -r ileave_count ileave_bytes <<< "$(group_stats "${DIR}"/bw_ramp_interleave.results.*.csv | tr '|' ' ')"
read -r png_count png_bytes <<< "$(group_stats "${DIR}"/*.png | tr '|' ' ')"
log_bytes=0
log_count=0
if [[ -f "${LOG}" ]]; then
  log_count=1
  log_bytes=$(stat -c '%s' "${LOG}" 2>/dev/null || echo 0)
fi

# Everything else not matched above and not the report itself.
declare -A KNOWN_BASENAMES
for f in "${DIR}"/idle_latency_*.txt "${DIR}"/bw_node*.txt "${DIR}"/bw_ramp.results.*.csv \
         "${DIR}"/bw_ramp_interleave.results.*.csv "${DIR}"/*.png "${LOG}"; do
  [[ -e "${f}" ]] && KNOWN_BASENAMES["${f##*/}"]=1
done
other_count=0
other_bytes=0
for f in "${DIR}"/*; do
  [[ -f "${f}" ]] || continue
  base="${f##*/}"
  is_report_file "${f}" && continue
  [[ -n "${KNOWN_BASENAMES[${base}]:-}" ]] && continue
  other_count=$((other_count + 1))
  sz=$(stat -c '%s' "${f}" 2>/dev/null || echo 0)
  other_bytes=$((other_bytes + sz))
done

total_count=$((idle_count + bwtxt_count + ramp_count + ileave_count + png_count + log_count + other_count))
total_bytes=$((idle_bytes + bwtxt_bytes + ramp_bytes + ileave_bytes + png_bytes + log_bytes + other_bytes))

#################################################################################################
# Tests Run status per socket
#################################################################################################

sockets_sorted=$(printf '%s\n' "${!PEAK_BW[@]}" | cut -d: -f1 | sort -n -u)

has_match() {  # $1 = glob pattern (already expanded by caller context)
  local f
  for f in "$@"; do
    [[ -e "${f}" ]] && return 0
  done
  return 1
}

#################################################################################################
# Write the report
#################################################################################################

{
  echo "# Intel MLC Benchmark Summary"
  echo
  echo "- **Report generated:** $(date -u '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- **Source directory:** \`${DIR}\`"
  echo "- **Run status:** ${run_status}"
  echo

  echo "## System Under Test"
  echo
  echo "| Field | Value |"
  echo "|-------|-------|"
  echo "| Hostname | ${sut_hostname} |"
  echo "| Platform (MLC-detected) | ${sut_platform} |"
  echo "| MLC version | ${sut_mlc_ver} |"
  echo "| mlc.sh version | ${sut_mlc_sh_ver} |"
  echo "| Invocation | \`${sut_invocation}\` |"
  echo "| Physical sockets in system | ${sut_sockets_in_system} |"
  echo "| Cores per socket | ${sut_cores_per_socket} |"
  echo "| NUMA nodes in system | ${sut_numa_nodes} |"
  echo "| Started | ${sut_started} |"
  echo "| Ended | ${sut_ended} |"
  echo "| Duration | ${sut_duration} |"
  echo
  if [[ -n "${log_missing_note}" ]]; then
    echo "> ${log_missing_note}"
    echo
  fi

  echo "## Topology Tested"
  echo
  echo "| Socket | Node | Type |"
  echo "|--------|------|------|"
  for key in ${node_keys_sorted}; do
    IFS=':' read -r sock node <<< "${key}"
    echo "| ${sock} | ${node} | ${NODE_TYPE[${key}]:-unknown} |"
  done
  echo

  echo "## Tests Run"
  echo
  echo "| Socket | Test | Status |"
  echo "|--------|------|--------|"
  for sock in ${sockets_sorted}; do
    if has_match "${DIR}"/idle_latency_*_numa_node_*.socket_${sock}.txt; then
      echo "| ${sock} | Idle Latency | Done |"
    else
      echo "| ${sock} | Idle Latency | Not run |"
    fi
    if has_match "${DIR}"/bw_node*.socket_${sock}.txt; then
      echo "| ${sock} | Fixed-pattern Bandwidth | Done |"
    else
      echo "| ${sock} | Fixed-pattern Bandwidth | Not run |"
    fi
    if has_match "${DIR}"/bw_ramp.results.*.socket_${sock}.csv; then
      echo "| ${sock} | Bandwidth Ramp | Done |"
    else
      echo "| ${sock} | Bandwidth Ramp | Not run |"
    fi
    if has_match "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.seq.*.socket_${sock}.csv; then
      echo "| ${sock} | Interleave Ramp (seq) | Done |"
    else
      echo "| ${sock} | Interleave Ramp (seq) | Not run |"
    fi
    if has_match "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.rand.*.socket_${sock}.csv; then
      echo "| ${sock} | Interleave Ramp (rand) | Known MLC limitation |"
    fi
  done
  echo

  echo "## Peak Results by Socket -> Node"
  echo
  echo "| Socket | Node | Type | Idle Lat seq (ns) | Idle Lat rand (ns) | Peak BW (MB/s) | @ Cores | Lat @ Peak (ns) | Max Cores Tested |"
  echo "|--------|------|------|--------------------|---------------------|----------------|---------|------------------|-------------------|"
  for key in ${node_keys_sorted}; do
    IFS=':' read -r sock node <<< "${key}"
    IFS='|' read -r bw cores lat maxcores <<< "${PEAK_BW[${key}]:-}"
    echo "| ${sock} | ${node} | ${NODE_TYPE[${key}]:-unknown} | ${IDLE_SEQ[${key}]:-n/a} | ${IDLE_RAND[${key}]:-n/a} | ${bw:-no data} | ${cores:-} | ${lat:-} | ${maxcores:-} |"
  done
  echo

  if [[ -n "${ileave_keys_sorted}" ]]; then
    echo "## Interleave Peak Results (DRAM + CXL, seq)"
    echo
    echo "| Socket | DRAM Node | CXL Node | Traffic | Peak BW (MB/s) | @ Cores | Lat @ Peak (ns) | Best Ratio (DRAM:CXL) |"
    echo "|--------|-----------|----------|---------|----------------|---------|------------------|------------------------|"
    for key in ${ileave_keys_sorted}; do
      IFS=':' read -r sock dnode cnode wtype <<< "${key}"
      IFS='|' read -r bw cores lat ratio <<< "${ILEAVE_PEAK[${key}]:-}"
      echo "| ${sock} | ${dnode} | ${cnode} | ${wtype} | ${bw:-no data} | ${cores:-} | ${lat:-} | ${ratio:-} |"
    done
    echo
  fi

  echo "## Observations / Potential Issues"
  echo
  obs_any=0
  for a in "${anomalies[@]:-}"; do
    [[ -z "${a}" ]] && continue
    echo "- ${a}"
    obs_any=1
  done
  if [[ "${rand_interleave_present}" -eq 1 ]]; then
    echo "- Interleave random-access (W21/W23/W27) data found with blank Latency/Bandwidth fields - this is a documented, permanent MLC restriction (random access is only supported for traffic types R, W2, W5, W6), not a failure. Current mlc.sh no longer attempts this combination."
    obs_any=1
  fi
  if [[ "${#unexplained_blank_files[@]}" -gt 0 ]]; then
    echo "- The following result file(s) contain no usable data and do not match a known limitation - worth investigating:"
    for bf in "${unexplained_blank_files[@]}"; do
      echo "  - \`${bf}\`"
    done
    obs_any=1
  fi
  if [[ "${#log_error_lines[@]}" -gt 0 ]]; then
    echo "- ${#log_error_lines[@]} distinct error/warning line(s) found in \`mlc.sh.log\`:"
    for el in "${log_error_lines[@]}"; do
      echo "  - \`${el}\`"
    done
    obs_any=1
  fi
  if [[ -n "${log_missing_note}" ]]; then
    echo "- ${log_missing_note}"
    obs_any=1
  fi
  if [[ "${obs_any}" -eq 0 ]]; then
    echo "- None detected."
  fi
  echo

  echo "## Charts"
  echo
  if [[ "${#png_files[@]}" -gt 0 ]]; then
    for p in "${png_files[@]}"; do
      echo "- \`${p}\`"
    done
  else
    echo "No chart images found. Generate them with:"
    echo
    echo "\`\`\`"
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
    echo "${script_dir}/.venv/bin/python ${script_dir}/gen_plot.py -d \"${DIR}\""
    echo "\`\`\`"
  fi
  echo

  echo "## Raw Output Files"
  echo
  echo "| Group | Count | Total Size |"
  echo "|-------|-------|------------|"
  echo "| Idle latency (idle_latency_*.txt) | ${idle_count} | $(human_size "${idle_bytes}") |"
  echo "| Fixed-pattern bandwidth (bw_node*.txt) | ${bwtxt_count} | $(human_size "${bwtxt_bytes}") |"
  echo "| Per-node bandwidth ramp (bw_ramp.results.*.csv) | ${ramp_count} | $(human_size "${ramp_bytes}") |"
  echo "| Interleave ramp (bw_ramp_interleave.results.*.csv) | ${ileave_count} | $(human_size "${ileave_bytes}") |"
  echo "| Charts (*.png) | ${png_count} | $(human_size "${png_bytes}") |"
  echo "| Log (mlc.sh.log) | ${log_count} | $(human_size "${log_bytes}") |"
  if [[ "${other_count}" -gt 0 ]]; then
    echo "| Other files | ${other_count} | $(human_size "${other_bytes}") |"
  fi
  echo "| **Total** | ${total_count} | $(human_size "${total_bytes}") |"
} > "${REPORT}"

echo "Report written to: ${REPORT}"
