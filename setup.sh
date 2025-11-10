#!/bin/bash

# Repository URLs configuration
GITEE_MIRROR="https://gitee.com/mirrors"
GITHUB_YSYX_B_STAGE_CI_REPO="https://github.com/sashimi-yzh/ysyx-submit-test.git"

RED='\e[31m'
GREEN='\e[32m'
NC='\e[0m'
WHITE_ON_BLACK='\e[37;40m'

# helper output functions
info() {
    echo -e "${WHITE_ON_BLACK}$*${NC}"
}
success() {
    echo -e "${GREEN}$*${NC}"
}
error() {
    echo -e "${RED}$*${NC}" >&2
}

# set terminal to plain black background + white
printf '%b' "${WHITE_ON_BLACK}"
# restore colors on exit
trap 'printf "%b" "${NC}"' EXIT

retry_run() {
    local cmd=("$@")
    local retries=3
    local attempt=1

    while [ $attempt -le $retries ]; do
        info "Running command: ${cmd[*]}"
        "${cmd[@]}"
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            return 0
        else
            if [ $attempt -lt $retries ]; then
                local next_attempt=$((attempt + 1))
                info "Command failed (attempt ${attempt}/${retries}), retrying ..."
            fi
        fi
        attempt=$((attempt + 1))
    done

    error "Command '${cmd[*]}' failed $retries times, exiting ..."
    exit 1
}

setup_env() {
    # apt update & upgrade
    retry_run sudo apt update
    retry_run sudo apt upgrade -y

    # git check
    if command -v git &> /dev/null; then
        local user_name
        user_name=$(git config user.name)
        if [ -z "$user_name" ]; then
            error "Error: git user.name not configured."
            info "Please run 'git config --global user.name \"Your Name\"' to set your name."
            exit 1
        fi

        local user_email
        user_email=$(git config user.email)
        if [ -z "$user_email" ]; then
            error "Error: git user.email not configured."
            info "Please run 'git config --global user.email \"you@example.com\"' to set your email."
            exit 1
        fi
    else
        retry_run sudo apt install -y git
        info "Git installed. Please config git user.name and user.email before rerun this script."
        exit 1
    fi

    # install packages
    retry_run sudo apt install -y vim wget curl openjdk-17-jdk \
        gcc g++ gdb make build-essential autoconf scons \
        python-is-python3 help2man perl flex bison ccache \
        libreadline-dev libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev \
        g++-riscv64-linux-gnu llvm llvm-dev
    # fix compile error using riscv64-linux-gnu
    sudo sed -i 's|^# include <gnu/stubs-ilp32.h>|//# include <gnu/stubs-ilp32.h>|' /usr/riscv64-linux-gnu/include/gnu/stubs.h
    # install verilator
    if command -v verilator &> /dev/null; then
        info "Verilator is already installed."
    else
        retry_run git clone ${GITEE_MIRROR}/Verilator.git /tmp/verilator
        cd /tmp/verilator
        git checkout stable
        autoconf
        ./configure
        make -j$(nproc)
        sudo make install
        cd -
        rm -rf /tmp/verilator
    fi

    success "Environment setup completed."
}

setup_repo() {
    # clone repo
    retry_run git clone --depth 1 -b $1 ${GITHUB_YSYX_B_STAGE_CI_REPO} ysyx-workbench
    # create activate.sh
    echo "export B_EXAM_HOME=$(pwd)" > activate.sh
    echo "export YSYX_HOME=\$B_EXAM_HOME/ysyx-workbench" >> activate.sh
    echo "export NEMU_HOME=\$YSYX_HOME/nemu" >> activate.sh
    echo "export AM_HOME=\$YSYX_HOME/abstract-machine" >> activate.sh
    echo "export NAVY_HOME=\$YSYX_HOME/navy-apps" >> activate.sh
    echo "export NPC_HOME=\$YSYX_HOME/npc" >> activate.sh
    echo "export NVBOARD_HOME=\$YSYX_HOME/nvboard" >> activate.sh
    echo "export PATH=\$B_EXAM_HOME/bin:\$PATH" >> activate.sh
    source activate.sh
    # cd into workbench
    cd $YSYX_HOME
    # disable git tracer
    echo ".git_commit:" >> Makefile
    echo -e "\t@echo git tracer is disabled" >> Makefile
    # clone other repos
    retry_run git clone --depth 1 https://github.com/NJU-ProjectN/am-kernels
    retry_run git clone --depth 1 https://github.com/NJU-ProjectN/rt-thread-am
    retry_run git clone --depth 1 https://github.com/NJU-ProjectN/nvboard
    retry_run git clone --depth 1 https://github.com/NJU-ProjectN/fceux-am
    retry_run git clone --depth 1 -b ysyx6 https://github.com/OSCPU/ysyxSoC
    retry_run git clone --depth 1 https://github.com/NJU-ProjectN/riscv-tests-am
    retry_run git clone --depth 1 https://github.com/NJU-ProjectN/riscv-arch-test-am
    # download nes rom
    cd $YSYX_HOME/fceux-am/nes
    retry_run wget -O rom.tar.bz2 https://box.nju.edu.cn/f/3e56938d9d8140a7bb75/\?dl\=1
    tar -xjf rom.tar.bz2
    rm rom.tar.bz2
    # apply patches
    cd $YSYX_HOME/rt-thread-am
    git am $YSYX_HOME/patch/rt-thread-am/*
    cd $YSYX_HOME/ysyxSoC
    git am $YSYX_HOME/patch/ysyxSoC/*
    # rtt init
    make -C $YSYX_HOME/rt-thread-am/bsp/abstract-machine init
    # clean up
    make -C $YSYX_HOME/nemu clean
    make -C $YSYX_HOME/am-kernels clean-all
    make -C $YSYX_HOME/npc clean
    # git clone ssh -> https
    sed -i -e 's+git@github.com:+https://github.com/+' $YSYX_HOME/ysyxSoC/.gitmodules
    sed -i -e 's+git@github.com:+https://github.com/+' $YSYX_HOME/nemu/tools/capstone/Makefile || true
    sed -i -e 's+git@github.com:+https://github.com/+' $YSYX_HOME/nemu/tools/spike-diff/Makefile || true
    # install mill
    mkdir -p $YSYX_HOME/../bin
    MILL_VERSION=0.11.13
    if [[ -e $YSYX_HOME/npc/.mill-version ]]; then
        MILL_VERSION=`cat $YSYX_HOME/npc/.mill-version`
    fi
    info "Downloading mill with version $MILL_VERSION"
    retry_run sh -c "curl -L https://github.com/com-lihaoyi/mill/releases/download/$MILL_VERSION/$MILL_VERSION > $YSYX_HOME/../bin/mill"
    chmod +x $YSYX_HOME/../bin/mill
    # generate verilog for ysyxSoC
    PATH=$YSYX_HOME/../bin:$PATH
    retry_run make -C $YSYX_HOME/ysyxSoC dev-init
    retry_run make -C $YSYX_HOME/ysyxSoC verilog

    success "Student repo setup completed, run 'source activate.sh' to activate the environment."
}

clean_repo() {
    YSYX_HOME=$(pwd)/ysyx-workbench

    cd $YSYX_HOME
    git clean -xdf
    rm -rf ./.git

    cd $YSYX_HOME/am-kernels
    git clean -xdf
    rm -rf ./.git

    cd $YSYX_HOME/rt-thread-am
    git clean -xdf
    rm -rf ./.git

    cd $YSYX_HOME/nvboard
    git clean -xdf
    rm -rf ./.git

    cd $YSYX_HOME/fceux-am
    git add -f nes/rom/*.nes
    git clean -xdf
    rm -rf ./.git

    cd $YSYX_HOME/ysyxSoC
    git add -f build/ysyxSoCFull.v
    git clean -xdf
    rm -rf ./.git

    cd $YSYX_HOME/riscv-tests-am
    git clean -xdf
    rm -rf ./.git

    cd $YSYX_HOME/riscv-arch-test-am
    git clean -xdf
    rm -rf ./.git
}

if [ -z "$1" ]; then
    error "Error: No argument specified."
    info "Usage: $0 {env|repo|clean}"
    exit 1
fi

case "$1" in
    env)
        setup_env
        ;;
    repo)
        setup_repo $2 
        ;;
    clean)
        clean_repo
        ;;
    *)
        error "Error: Unknown argument '$1'."
        info "Usage: $0 {env|repo|clean}"
        exit 1
        ;;
esac
