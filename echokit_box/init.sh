#!/bin/bash

cd $HOME

# install rust
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
fi

# Initialize the ESP development environment
# https://narukara.github.io/rust-on-esp-book-zh-cn

# install espup
# https://narukara.github.io/rust-on-esp-book-zh-cn/installation/riscv-and-xtensa.html
cargo install --locked espup
espup install

cargo install --locked espflash

# https://narukara.github.io/rust-on-esp-book-zh-cn/installation/std-requirements.html
cargo install --locked ldproxy

cargo install --locked cargo-generate
