# frozen_string_literal: true

SimpleCov.root Dir.pwd
SimpleCov.coverage_dir "tests/coverage/out/bash"
SimpleCov.track_files "{multi-cli,lib/*.sh,scripts/*.sh}"
SimpleCov.add_filter "/tests/"
