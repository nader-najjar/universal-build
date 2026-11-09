###############################################################################
# PROJECT CONTEXT
###############################################################################

PROJECT_DIRECTORY="$(pwd -P)"
readonly PROJECT_DIRECTORY

###############################################################################
# ARGUMENT HANDLING
###############################################################################

print_usage() {
  cat <<'USAGE'
Usage: universal-build <command>

Run from the project root.

Commands:
  build                      Run the project's native build.
  clean                      Remove build output.
  ide-paths                  Print toolchain paths for editor setup.
  update-toolchain-lock      Create or update the Nix lockfile.
  update-idiomatic-lock      Update the language dependency lockfile.
  shell <command>            Run a command in the project's build environment.
  --help, -h                 Show this help.
USAGE
}

usage_error() {
  printf '\033[31mUNIVERSAL BUILD: %s\033[0m\n' "$1" >&2
  print_usage >&2
  exit 2
}

validate_arguments() {
  [[ "$#" -gt 0 ]] || usage_error "A command is required."

  case "$1" in
    --help|-h|clean|build|ide-paths|update-toolchain-lock|update-idiomatic-lock)
      [[ "$#" -eq 1 ]] || usage_error "Command '$1' does not accept arguments."
      ;;
    shell)
      [[ "$#" -ge 2 ]] || usage_error "shell requires a command to run."
      ;;
    *)
      usage_error "Unknown command: $1"
      ;;
  esac
}

###############################################################################
# ERROR REPORTING
###############################################################################

fail() {
  printf '\033[31mUNIVERSAL BUILD: %s\033[0m\n' "$1" >&2
  exit 1
}

###############################################################################
# DIRECTORY REMOVAL
###############################################################################

remove_directory() {
  local directory="$1"

  # Nix runtime directories are read-only; make them writable before removal.
  if [[ -d "$directory" ]]; then
    find "$directory" -type d -exec chmod u+w {} +
  fi

  rm -rf -- "$directory"
}

###############################################################################
# BUILD ENVIRONMENT
###############################################################################

run_in_build_environment() {
  [[ -f "$PROJECT_DIRECTORY/flake.lock" ]] ||
    fail "Missing flake.lock in $PROJECT_DIRECTORY. Create the project lockfile first."

  nix \
    --extra-experimental-features 'nix-command flakes' \
    develop \
    --no-update-lock-file \
    "$PROJECT_DIRECTORY#buildtime" \
    --command "$@"
}

###############################################################################
# BUILD CONFIGURATION
###############################################################################

load_build_configuration() {
  # Expand BUILD_COMMAND inside the project environment.
  # shellcheck disable=SC2016
  BUILD_COMMAND="$(run_in_build_environment sh -eu -c 'printf "%s" "${BUILD_COMMAND:-}"')"

  # Expand RELEASE_TYPE inside the project environment.
  # shellcheck disable=SC2016
  RELEASE_TYPE="$(run_in_build_environment sh -eu -c 'printf "%s" "${RELEASE_TYPE:-}"')"
}

validate_build_configuration() {
  [[ -n "$BUILD_COMMAND" ]] || fail "Missing BUILD_COMMAND in flake.nix#buildtime."
  [[ -n "$RELEASE_TYPE" ]] || fail "Missing RELEASE_TYPE in flake.nix#buildtime."

  case "$RELEASE_TYPE" in
    static|executable|container)
      ;;
    *)
      fail "RELEASE_TYPE must be static, executable, or container; got '$RELEASE_TYPE'."
      ;;
  esac
}

###############################################################################
# RELEASE ARTIFACTS
###############################################################################

prepare_release_directory() {
  remove_directory "$PROJECT_DIRECTORY/build/release"
  rm -f -- "$PROJECT_DIRECTORY/build/release-artifact.tar.gz"
}

validate_idiomatic_artifacts() {
  local artifacts_directory="$PROJECT_DIRECTORY/build/release/idiomatic-artifacts"

  [[ -d "$artifacts_directory" ]] ||
    fail "BUILD_COMMAND must create build/release/idiomatic-artifacts."
  [[ -n "$(find "$artifacts_directory" -type f -print -quit)" ]] ||
    fail "build/release/idiomatic-artifacts is empty."
}

###############################################################################
# RELEASE PACKAGING
###############################################################################

build_and_copy_runtime() {
  local runtime_store_path
  runtime_store_path="$(nix \
    --extra-experimental-features 'nix-command flakes' \
    build \
    --no-update-lock-file \
    --no-link \
    --print-out-paths \
    "$PROJECT_DIRECTORY#runtime")"

  local execution_script="$runtime_store_path/bin/execute"
  [[ -f "$execution_script" && -x "$execution_script" ]] ||
    fail "The runtime package must provide executable bin/execute."

  nix \
    --extra-experimental-features 'nix-command flakes' \
    copy \
    --no-check-sigs \
    --to "$PROJECT_DIRECTORY/build/release/runtime-artifacts" \
    "$runtime_store_path"

  ln -s -- "$execution_script" "$PROJECT_DIRECTORY/build/release/execution-script-symlink"
}

copy_dockerfile() {
  [[ -f "$PROJECT_DIRECTORY/Dockerfile" ]] || fail "Container releases require a Dockerfile."
  cp -- "$PROJECT_DIRECTORY/Dockerfile" "$PROJECT_DIRECTORY/build/release/Dockerfile"
}

archive_release() {
  tar \
    --create \
    --gzip \
    --file "$PROJECT_DIRECTORY/build/release-artifact.tar.gz" \
    --directory "$PROJECT_DIRECTORY/build/release" \
    .
}

###############################################################################
# BUILD
###############################################################################

build() {
  load_build_configuration
  validate_build_configuration
  prepare_release_directory

  run_in_build_environment sh -eu -c "$BUILD_COMMAND"
  validate_idiomatic_artifacts

  case "$RELEASE_TYPE" in
    static)
      archive_release
      ;;
    executable)
      build_and_copy_runtime
      archive_release
      ;;
    container)
      build_and_copy_runtime
      copy_dockerfile
      archive_release
      ;;
  esac

  printf '\033[32mUNIVERSAL BUILD: BUILD SUCCESSFUL\033[0m\n'
}

###############################################################################
# TOOLCHAIN LOCK
###############################################################################

update_toolchain_lock() {
  nix \
    --extra-experimental-features 'nix-command flakes' \
    flake update \
    --flake "$PROJECT_DIRECTORY"

  printf '\033[32mUNIVERSAL BUILD: TOOLCHAIN LOCK UPDATE SUCCESSFUL\033[0m\n'
}

###############################################################################
# IDIOMATIC LOCK
###############################################################################

load_idiomatic_lock_configuration() {
  # Expand UPDATE_IDIOMATIC_LOCK_COMMAND inside the project environment.
  # shellcheck disable=SC2016
  UPDATE_IDIOMATIC_LOCK_COMMAND="$(run_in_build_environment sh -eu -c 'printf "%s" "${UPDATE_IDIOMATIC_LOCK_COMMAND:-}"')"
}

validate_idiomatic_lock_configuration() {
  [[ -n "$UPDATE_IDIOMATIC_LOCK_COMMAND" ]] ||
    fail "Missing UPDATE_IDIOMATIC_LOCK_COMMAND in flake.nix#buildtime."
}

update_idiomatic_lock() {
  load_idiomatic_lock_configuration
  validate_idiomatic_lock_configuration

  run_in_build_environment sh -eu -c "$UPDATE_IDIOMATIC_LOCK_COMMAND"

  printf '\033[32mUNIVERSAL BUILD: IDIOMATIC LOCK UPDATE SUCCESSFUL\033[0m\n'
}

###############################################################################
# IDE PATHS
###############################################################################

load_ide_configuration() {
  # Expand IDE_PATH_VARS inside the project environment.
  # shellcheck disable=SC2016
  IDE_PATH_VARS="$(run_in_build_environment sh -eu -c 'printf "%s" "${IDE_PATH_VARS:-}"')"
}

validate_ide_configuration() {
  [[ -n "$IDE_PATH_VARS" ]] || fail "Missing IDE_PATH_VARS in flake.nix#buildtime."
}

ide_paths() {
  load_ide_configuration
  validate_ide_configuration

  local names name value
  read -r -a names <<< "${IDE_PATH_VARS//$'\n'/ }"

  for name in "${names[@]}"; do
    value="$(run_in_build_environment printenv "$name")" ||
      fail "Could not read IDE path variable: $name"
    printf '\033[36mUNIVERSAL BUILD: %s=\033[0m%s\n' "$name" "$value"
  done

  printf '\033[32mUNIVERSAL BUILD: IDE PATHS PRINTED SUCCESSFULLY\033[0m\n'
}

###############################################################################
# CLEANUP
###############################################################################

clean() {
  remove_directory "$PROJECT_DIRECTORY/build"

  printf '\033[32mUNIVERSAL BUILD: CLEAN SUCCESSFUL\033[0m\n'
}

###############################################################################
# ENTRYPOINT
###############################################################################

main() {
  validate_arguments "$@"

  [[ -f "$PROJECT_DIRECTORY/flake.nix" ]] ||
    fail "Missing flake.nix in $PROJECT_DIRECTORY."

  local requested_command="$1"
  shift

  case "$requested_command" in
    --help|-h)
      print_usage
      ;;
    build)
      build
      ;;
    update-toolchain-lock)
      update_toolchain_lock
      ;;
    update-idiomatic-lock)
      update_idiomatic_lock
      ;;
    ide-paths)
      ide_paths
      ;;
    clean)
      clean
      ;;
    shell)
      run_in_build_environment "$@"
      ;;
  esac
}

main "$@"
