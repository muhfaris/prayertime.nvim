#!/bin/bash
set -e

# Ensure plenary.nvim is available (test-only dependency; not needed at runtime)
if [ ! -d "plenary.nvim" ]; then
    echo "Cloning plenary.nvim for test dependencies (busted)..."
    git clone --depth 1 https://github.com/nvim-lua/plenary.nvim plenary.nvim
fi

# Run tests
echo "Running tests..."
nvim --headless -u NONE \
    --cmd "set rtp+=./plenary.nvim" \
    --cmd "set rtp+=." \
    +"lua dofile('test/ci_runner.lua')" \
    +qall
