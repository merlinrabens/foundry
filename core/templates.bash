# core/templates.bash — Template rendering, helpers
[ "${_CORE_TEMPLATES_LOADED:-}" = "1" ] && return 0
_CORE_TEMPLATES_LOADED=1

render_template() {
  local template_file="$1"
  shift
  # Copy template to temp file, then do in-place replacements
  local tmp
  tmp=$(mktemp)
  cp "$template_file" "$tmp"
  while [ $# -gt 0 ]; do
    local key="${1%%=*}"
    local val="${1#*=}"
    # Write value to file so perl reads it safely (handles newlines, special chars)
    local val_file
    val_file=$(mktemp)
    printf '%s' "$val" > "$val_file"
    perl -pi -e "
      BEGIN { local \$/; open F, '$val_file'; \$r = <F>; close F; chomp \$r; }
      s/\\Q{{${key}}}\\E/\$r/g;
    " "$tmp"
    rm -f "$val_file"
    shift
  done
  cat "$tmp"
  rm -f "$tmp"
}

detect_pkg_manager() {
  local dir="$1"
  if [ -f "$dir/pnpm-lock.yaml" ]; then echo "pnpm"
  elif [ -f "$dir/yarn.lock" ]; then echo "yarn"
  elif [ -f "$dir/package-lock.json" ]; then echo "npm"
  elif [ -f "$dir/pyproject.toml" ]; then echo "uv"
  elif [ -f "$dir/requirements.txt" ]; then echo "pip"
  else echo "none"; fi
}

sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

generate_task_id() {
  local name="$1" project="$2"
  local clean proj
  clean=$(basename "$name" .md | head -c 40)
  clean=$(sanitize "$clean")
  proj=$(sanitize "$project")
  echo "${proj}-${clean}"
}
