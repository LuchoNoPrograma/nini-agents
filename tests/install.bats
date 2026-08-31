#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  export PATH="/usr/bin:$PATH"
  export GIT_BASH_BIN="$(command -v bash)"
  export NINI_AGENTS_BIN_LINK="$MULTICLI_SCRATCH/bin/nini-agents"
  export MULTICLI_BIN_LINK="$MULTICLI_SCRATCH/bin/multi-cli"
  mkdir -p "$(dirname "$NINI_AGENTS_BIN_LINK")"
}

teardown() {
  unset GIT_BASH_BIN NINI_AGENTS_BIN_LINK NINI_AGENTS_INSTALL_DIR NINI_AGENTS_REPO
  unset MULTICLI_BIN_LINK MULTICLI_INSTALL_DIR MULTICLI_REPO
  teardown_scratch
}

@test "matrix: install rejects an unknown option (+1 related)" {
  # Case 1: install rejects an unknown option
  run "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh" --wat

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option '--wat'"* ]]

  teardown
  setup

  # Case 2: install rejects placeholder repository URLs
  run env NINI_AGENTS_REPO="https://github.com/<owner>/<repo>.git" \
    NINI_AGENTS_BIN_LINK="$NINI_AGENTS_BIN_LINK" MULTICLI_BIN_LINK="$MULTICLI_BIN_LINK" \
    "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"NINI_AGENTS_REPO/MULTICLI_REPO contains a placeholder"* ]]
}

@test "matrix: install requires git for GitHub installs (+1 related)" {
  # Case 1: install requires git for GitHub installs
  local empty_bin="$MULTICLI_SCRATCH/empty-bin"
  mkdir -p "$empty_bin"

  run env PATH="$empty_bin" NINI_AGENTS_REPO="https://github.com/LuchoNoPrograma/nini-agents.git" \
    NINI_AGENTS_BIN_LINK="$NINI_AGENTS_BIN_LINK" MULTICLI_BIN_LINK="$MULTICLI_BIN_LINK" \
    "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"git is required to install Nini Agents from GitHub"* ]]

  teardown
  setup

  # Case 2: install refuses to reuse a non-git directory
  export NINI_AGENTS_INSTALL_DIR="$MULTICLI_SCRATCH/existing-install"
  mkdir -p "$NINI_AGENTS_INSTALL_DIR"
  printf 'not a checkout\n' > "$NINI_AGENTS_INSTALL_DIR/README.txt"

  run env NINI_AGENTS_INSTALL_DIR="$NINI_AGENTS_INSTALL_DIR" \
    NINI_AGENTS_BIN_LINK="$NINI_AGENTS_BIN_LINK" MULTICLI_BIN_LINK="$MULTICLI_BIN_LINK" \
    NINI_AGENTS_REPO="https://github.com/LuchoNoPrograma/nini-agents.git" \
    "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"exists but is not a Git checkout"* ]]
}

@test "install rejects a cloned repository that lacks the nini-agents entrypoint" {
  local remote_repo="$MULTICLI_SCRATCH/remote.git"
  local source_repo="$MULTICLI_SCRATCH/source"
  export NINI_AGENTS_INSTALL_DIR="$MULTICLI_SCRATCH/installed"
  git init --bare "$remote_repo" >/dev/null
  git init "$source_repo" >/dev/null
  (
    cd "$source_repo"
    git config user.name "Codex"
    git config user.email "codex@example.invalid"
    printf 'just docs\n' > README.md
    git add README.md
    git commit -m "init" >/dev/null
    git remote add origin "$remote_repo"
    git push origin HEAD:main >/dev/null
  )

  run env NINI_AGENTS_INSTALL_DIR="$NINI_AGENTS_INSTALL_DIR" \
    NINI_AGENTS_BIN_LINK="$NINI_AGENTS_BIN_LINK" MULTICLI_BIN_LINK="$MULTICLI_BIN_LINK" \
    NINI_AGENTS_REPO="$remote_repo" \
    "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"does not contain the nini-agents entrypoint"* ]]
}

@test "local install writes a launcher that execs the repo entrypoint" {
  run env NINI_AGENTS_BIN_LINK="$NINI_AGENTS_BIN_LINK" MULTICLI_BIN_LINK="$MULTICLI_BIN_LINK" \
    "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh" --local

  [ "$status" -eq 0 ]
  [ -f "$NINI_AGENTS_BIN_LINK" ]
  [ -f "$MULTICLI_BIN_LINK" ]
  grep -Fq "exec $MULTICLI_REPO_ROOT/nini-agents" "$NINI_AGENTS_BIN_LINK"
  grep -Fq "exec $MULTICLI_REPO_ROOT/multi-cli" "$MULTICLI_BIN_LINK"
  [[ "$output" == *"Primary launcher at $NINI_AGENTS_BIN_LINK"* ]]
  [[ "$output" == *"Compatibility launcher at $MULTICLI_BIN_LINK"* ]]
}

@test "local install registers the profile alias directory idempotently" {
  local alias_dir="$MULTICLI_HOME/bin"

  run env SHELL=/bin/bash NINI_AGENTS_BIN_LINK="$NINI_AGENTS_BIN_LINK" MULTICLI_BIN_LINK="$MULTICLI_BIN_LINK" \
    "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh" --local

  [ "$status" -eq 0 ]
  [ -f "$HOME/.bashrc" ]
  grep -Fq "export PATH=$alias_dir:\"\$PATH\"" "$HOME/.bashrc"
  [[ "$output" == *"Added $alias_dir to PATH in $HOME/.bashrc"* ]]

  run env SHELL=/bin/bash NINI_AGENTS_BIN_LINK="$NINI_AGENTS_BIN_LINK" MULTICLI_BIN_LINK="$MULTICLI_BIN_LINK" \
    "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh" --local

  [ "$status" -eq 0 ]
  [ "$(grep -Fc "$alias_dir" "$HOME/.bashrc")" -eq 1 ]
  [[ "$output" == *"Profile alias directory is already configured: $alias_dir"* ]]
}

@test "local install does not follow a shell-profile symlink" {
  local outside="$MULTICLI_SCRATCH/outside-bashrc"
  printf 'keep me\n' > "$outside"
  ln -s "$outside" "$HOME/.bashrc"

  run env SHELL=/bin/bash NINI_AGENTS_BIN_LINK="$NINI_AGENTS_BIN_LINK" MULTICLI_BIN_LINK="$MULTICLI_BIN_LINK" \
    "$GIT_BASH_BIN" "$MULTICLI_REPO_ROOT/install/install.sh" --local

  [ "$status" -eq 0 ]
  [ -L "$HOME/.bashrc" ]
  [ "$(cat "$outside")" = "keep me" ]
  [[ "$output" == *"cannot update $HOME/.bashrc safely"* ]]
}
