#!/bin/sh
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Shorten home directory to ~
home="$HOME"
short_cwd=$(echo "$cwd" | sed "s|^$home|~|")

# Git branch (skip optional locks to avoid blocking)
git_branch=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" -c core.hooksPath=/dev/null --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi

# Build a progress bar: $1=percentage(0-100), $2=width
make_bar() {
  _pct="$1"
  _width="$2"
  _pct_int=$(printf "%.0f" "$_pct")
  _filled=$(( _pct_int * _width / 100 ))
  _empty=$(( _width - _filled ))
  _bar=""
  _i=0
  while [ $_i -lt $_filled ]; do
    _bar="${_bar}█"
    _i=$(( _i + 1 ))
  done
  _i=0
  while [ $_i -lt $_empty ]; do
    _bar="${_bar}░"
    _i=$(( _i + 1 ))
  done
  printf "%s" "$_bar"
}

# Format reset timestamp as dd.MM.yyyy HH:mm
format_resets_at() {
  _resets="$1"
  # GNU/uutils coreutils (Linux sandbox) parse epochs as -d @EPOCH;
  # BSD/macOS uses -r EPOCH. Try GNU first, fall back to BSD.
  date -d "@$_resets" "+%d.%m.%Y %H:%M" 2>/dev/null \
    || date -r "$_resets" "+%d.%m.%Y %H:%M" 2>/dev/null
}

# --- Line 1: directory / git branch / model ---
dir_part=""
if [ -n "$short_cwd" ]; then
  if [ -n "$git_branch" ]; then
    dir_part=$(printf "%s  %s" "$short_cwd" "$git_branch")
  else
    dir_part="$short_cwd"
  fi
fi

printf "\033[2m%s\033[0m  \033[2m%s\033[0m" "${dir_part:-$cwd}" "$model"

# --- Line 2: context bar | session timer | weekly stats ---
line2=""

# Context token usage bar
if [ -n "$used" ]; then
  ctx_bar=$(make_bar "$used" 20)
  ctx_int=$(printf "%.0f" "$used")
  ctx_part=$(printf "Ctx [%s] %d%%" "$ctx_bar" "$ctx_int")
  line2="$ctx_part"
fi

# 5-hour session usage bar + time until reset
if [ -n "$five_pct" ]; then
  five_bar=$(make_bar "$five_pct" 10)
  five_int=$(printf "%.0f" "$five_pct")
  five_part=$(printf "5h [%s] %d%%" "$five_bar" "$five_int")
  if [ -n "$five_resets" ]; then
    five_resets_on=$(format_resets_at "$five_resets")
    five_part=$(printf "%s resets on %s" "$five_part" "$five_resets_on")
  fi
  if [ -n "$line2" ]; then
    line2=$(printf "%s  |  %s" "$line2" "$five_part")
  else
    line2="$five_part"
  fi
fi

# Weekly (7-day) usage bar + time until reset
if [ -n "$week_pct" ]; then
  week_bar=$(make_bar "$week_pct" 10)
  week_int=$(printf "%.0f" "$week_pct")
  week_part=$(printf "7d [%s] %d%%" "$week_bar" "$week_int")
  if [ -n "$week_resets" ]; then
    week_resets_on=$(format_resets_at "$week_resets")
    week_part=$(printf "%s resets on %s" "$week_part" "$week_resets_on")
  fi
  if [ -n "$line2" ]; then
    line2=$(printf "%s  |  %s" "$line2" "$week_part")
  else
    line2="$week_part"
  fi
fi

if [ -n "$line2" ]; then
  printf "\n\033[2m%s\033[0m" "$line2"
fi
