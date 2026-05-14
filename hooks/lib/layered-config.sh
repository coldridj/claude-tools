#!/bin/bash
# Shared test helper: run a hook with isolated default / user / project
# config files written from string contents.
#
# Sourced by per-hook test.sh scripts. Closes the BUGS.md gap "Layered-config
# testing is structurally absent across three hooks" — covers path-guard and
# read-guard. bash-guard intentionally uses a single-file config model and is
# excluded; see BUGS.md for the discrepancy note.
#
# Usage (after sourcing this file):
#
#   layered_run \
#     --hook "$HOOK" \
#     --kind path-guard \
#     --default '[secret]\n/etc/passwd' \
#     --user    '[protected]\n.user-secret' \
#     --project '[protected]\n.proj-secret' \
#     --input   '{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd","old_string":"a","new_string":"b"}}'
#
# After the call, three variables are set in the caller's scope:
#   HOOK_RC      — the hook's exit code
#   HOOK_STDOUT  — captured stdout
#   HOOK_STDERR  — captured stderr
#
# Temp dirs are cleaned up before returning.
#
# Supported --kind values: path-guard, read-guard.
# (bash-guard uses a different config model; see BUGS.md.)

layered_run() {
  local hook="" kind="" default_cfg="" user_cfg="" project_cfg="" input=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hook)    hook="$2"; shift 2 ;;
      --kind)    kind="$2"; shift 2 ;;
      --default) default_cfg="$2"; shift 2 ;;
      --user)    user_cfg="$2"; shift 2 ;;
      --project) project_cfg="$2"; shift 2 ;;
      --input)   input="$2"; shift 2 ;;
      *) echo "layered_run: unknown arg '$1'" >&2; return 2 ;;
    esac
  done

  if [ -z "$hook" ] || [ -z "$kind" ] || [ -z "$input" ]; then
    echo "layered_run: --hook, --kind, --input required" >&2
    return 2
  fi

  local hook_dir_var default_basename leaf_basename
  case "$kind" in
    path-guard)
      hook_dir_var="PATH_GUARD_HOOK_DIR"
      default_basename="default.path-guard"
      leaf_basename=".path-guard"
      ;;
    read-guard)
      hook_dir_var="READ_GUARD_HOOK_DIR"
      default_basename="default.read-guard"
      leaf_basename=".read-guard"
      ;;
    *)
      echo "layered_run: unsupported --kind '$kind' (path-guard|read-guard only)" >&2
      return 2
      ;;
  esac

  local hook_dir home_dir proj_dir
  hook_dir=$(mktemp -d)
  home_dir=$(mktemp -d)
  proj_dir=$(mktemp -d)
  mkdir -p "$home_dir/.claude"
  printf '%b' "$default_cfg" > "$hook_dir/$default_basename"
  printf '%b' "$user_cfg"    > "$home_dir/.claude/$leaf_basename"
  printf '%b' "$project_cfg" > "$proj_dir/$leaf_basename"

  local stdout_file stderr_file rc=0
  stdout_file=$(mktemp); stderr_file=$(mktemp)

  if printf '%s' "$input" \
      | HOME="$home_dir" \
        CLAUDE_PROJECT_DIR="$proj_dir" \
        env "$hook_dir_var=$hook_dir" \
        bash "$hook" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  HOOK_STDOUT=$(cat "$stdout_file")
  HOOK_STDERR=$(cat "$stderr_file")
  HOOK_RC=$rc

  rm -rf "$hook_dir" "$home_dir" "$proj_dir"
  rm -f "$stdout_file" "$stderr_file"
}
