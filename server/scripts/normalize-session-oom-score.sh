#!/usr/bin/env bash
set -euo pipefail

# Current SSH sessions inherited ssh.service's old OOMScoreAdjust=-900.
# Normalize only root user session scopes; leave system services alone.
changed=0
for cgroup_file in /proc/[0-9]*/cgroup; do
  [ -r "$cgroup_file" ] || continue
  if grep -q 'user.slice/user-0.slice/session-' "$cgroup_file"; then
    pid="${cgroup_file#/proc/}"
    pid="${pid%/cgroup}"
    if [ -w "/proc/$pid/oom_score_adj" ]; then
      printf '0\n' > "/proc/$pid/oom_score_adj" || true
      changed=$((changed + 1))
    fi
  fi
done

printf 'Normalized OOMScoreAdjust for %s current session processes.\n' "$changed"
