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

# If GITHUB_MIRROR is set, route all GitHub ops via it,
# then revert the config after this script finishes (success or failure).
# So the submodule of submodue can also be cloned via the mirror.
if [ -n "$GITHUB_MIRROR" ]; then
    git config --global url."${GITHUB_MIRROR}https://github.com/".insteadOf "https://github.com/"
    trap 'printf "%b" "${NC}";git config --global --unset-all "url.${GITHUB_MIRROR}https://github.com/".insteadOf "https://github.com/"' EXIT
fi

# Only use sudo when not running as root, since Ubuntu base images does not have sudo installed
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

retry_run() {
    local cmd=("$@")
    local retries=5
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

# Sanity check for required tools
sanity_check() {
    local -a cmds=(git wget curl gcc g++ gdb make autoconf scons python3 perl flex bison ccache javac riscv64-linux-gnu-gcc)
    local missing=()

    for c in "${cmds[@]}"; do
        if ! command -v "$c" &> /dev/null; then
            missing+=("$c")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        error "Sanity check failed. Missing required tools:"
        for m in "${missing[@]}"; do
            error "  - $m"
        done
        error "Please run '$0 env' to install the required tools and re-run this command."
        exit 1
    fi
}

check_git_config() {
    local name email

    name=$(git config --global user.name 2>/dev/null)
    email=$(git config --global user.email 2>/dev/null)

    if [ -z "$name" ]; then
        read -rp "Git user.name is not set. Please enter your name: " name
        if [ -n "$name" ]; then
            git config --global user.name "$name"
            success "Set git user.name to '$name'"
        fi
    fi

    if [ -z "$email" ]; then
        read -rp "Git user.email is not set. Please enter your email: " email
        if [ -n "$email" ]; then
            git config --global user.email "$email"
            success "Set git user.email to '$email'"
        fi
    fi
}

setup_env() {
    # apt update & upgrade
    retry_run $SUDO apt update
    retry_run $SUDO apt upgrade -y

    # git check
    if ! command -v git &> /dev/null; then
        retry_run $SUDO apt install -y git
    fi
    # git config check
    check_git_config

    # install packages
    retry_run $SUDO apt install -y vim wget curl openjdk-17-jdk \
        gcc g++ gdb make build-essential autoconf scons \
        python-is-python3 help2man perl flex bison ccache \
        libreadline-dev libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev \
        g++-riscv64-linux-gnu llvm llvm-dev
    # fix compile error using riscv64-linux-gnu
    $SUDO sed -i 's|^# include <gnu/stubs-ilp32.h>|//# include <gnu/stubs-ilp32.h>|' /usr/riscv64-linux-gnu/include/gnu/stubs.h
    # install verilator
    if command -v verilator &> /dev/null; then
        info "Verilator is already installed."
    else
        TMPDIR="$(mktemp -d)"
        retry_run git clone --depth 1 -b stable ${GITEE_MIRROR}/Verilator.git "$TMPDIR"
        cd $TMPDIR
        autoconf
        ./configure
        make -j$(nproc)
        $SUDO make install
        cd -
        rm -rf $TMPDIR
    fi

    success "Environment setup completed."
}

setup_repo() {
	if [ -d "ysyx-workbench" ]; then
		error "Directory 'ysyx-workbench' already exists in $(pwd)."
		info "If you want to re-clone, please remove or move this directory first."
		exit 1
	fi

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
    echo -e "\ndefine git_commit\n\t@echo git tracer is disabled\nendef" >> Makefile
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
    make -C $YSYX_HOME/am-kernels clean-all clean
    make -C $YSYX_HOME/npc clean
    # git clone ssh -> https
    sed -i -e "s+git@github.com:+https://github.com/+" $YSYX_HOME/ysyxSoC/.gitmodules
    sed -i -e "s+git@github.com:+https://github.com/+" $YSYX_HOME/nemu/tools/capstone/Makefile || true
    sed -i -e "s+git@github.com:+https://github.com/+" $YSYX_HOME/nemu/tools/spike-diff/Makefile || true
    # install mill
    mkdir -p $YSYX_HOME/../bin
    MILL_VERSION=0.11.13
    if [[ -e $YSYX_HOME/npc/.mill-version ]]; then
        MILL_VERSION=`cat $YSYX_HOME/npc/.mill-version`
    fi
    info "Downloading mill with version $MILL_VERSION"
    retry_run sh -c "curl -L ${GITHUB_MIRROR}https://github.com/com-lihaoyi/mill/releases/download/$MILL_VERSION/$MILL_VERSION > $YSYX_HOME/../bin/mill"
    chmod +x $YSYX_HOME/../bin/mill
    # generate verilog for ysyxSoC
    PATH=$YSYX_HOME/../bin:$PATH
    retry_run make -C $YSYX_HOME/ysyxSoC dev-init
    retry_run make -C $YSYX_HOME/ysyxSoC verilog

    success "Student repo setup completed, run 'source activate.sh' to activate the environment."
}

clean_repo() {
    # Use mutiple ways to clean just in case
    make -C $YSYX_HOME/nemu clean
    make -C $YSYX_HOME/am-kernels clean-all clean
    make -C $YSYX_HOME/npc clean

    pushd .

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

    popd
}

pack_repo() {
    # Require YSYX_HOME to be set by the user (activate.sh).
    # `clean` and other pre-pack steps need additional environment variables
    # so we do not set YSYX_HOME automatically here.
    if [ -z "$YSYX_HOME" ]; then
        error "Environment variable YSYX_HOME is not set. Please run 'source activate.sh' before running 'pack'."
       exit 1
    fi

    # Get student ID (current branch) from the repo
    BRANCH_NAME_STUDENT_ID=$(git -C "$YSYX_HOME" branch --show-current)

    PLAIN_ARCHIVE="${BRANCH_NAME_STUDENT_ID}-ysyx-workbench.tar.bz2"
    ENCRYPTED_ARCHIVE="${BRANCH_NAME_STUDENT_ID}-ysyx-b-exam.tar.bz2"
	if [ ! -d "$YSYX_HOME" ]; then
		error "Directory 'ysyx-workbench' not found in $(pwd). Aborting."
		exit 1
	fi

	info "Running pre-pack clean targets..."
	make -C "$YSYX_HOME/nemu" clean || true
	make -C "$YSYX_HOME/am-kernels" clean-all clean || true
	make -C "$YSYX_HOME/npc" clean || true

	# Unencrypted archive. Including .git, for TA refrence
	info "Creating plain archive: $PLAIN_ARCHIVE"
    if [ ! -d "${YSYX_HOME}/.git" ]; then
		error "Directory 'ysyx-workbench' does not contain .git. Aborting."
		exit 1
	fi
	tar cjf "$PLAIN_ARCHIVE" ysyx-workbench

	info "Running clean_repo to strip VCS metadata..."
	clean_repo

    # If a key file already exists, reuse it as the key.
    if [ -f ysyx-b-exam-key.txt ]; then
        read -r KEY < ysyx-b-exam-key.txt
        info "Using existing encryption key from ysyx-b-exam-key.txt"
    else
        KEY=$(base64 /dev/random | head -c 16)
        # Write key to file without adding a trailing newline
        printf "%s" "$KEY" > ysyx-b-exam-key.txt
    fi

    info "Creating encrypted archive: $ENCRYPTED_ARCHIVE"
    tar cj ysyx-workbench activate.sh bin | openssl aes256 -k "$KEY" > "$ENCRYPTED_ARCHIVE"

    success "Pack completed."
    info "Plain archive: $GREEN$PLAIN_ARCHIVE"
    info "Encrypted archive: $GREEN$ENCRYPTED_ARCHIVE"
    info "Encryption key: $RED$KEY"
}

# Unpack a non-encrypted student archive to the current directory.
unpack_repo() {
        # The script expects exactly one file matching '*-ysyx-workbench.tar.bz2'.
        shopt -s nullglob
        matches=( *-ysyx-workbench.tar.bz2 )
        shopt -u nullglob

        if [ ${#matches[@]} -eq 0 ]; then
            error "No '*-ysyx-workbench.tar.bz2' archive found in $(pwd)."
            exit 1
        fi

        if [ ${#matches[@]} -gt 1 ]; then
            error "Multiple '*-ysyx-workbench.tar.bz2' archives found in $(pwd):"
            for f in "${matches[@]}"; do
                info "  - $f"
            done
            error "Please ensure only one such archive is present and retry."
            exit 1
        fi

        ARCHIVE="${matches[0]}"
        info "Found archive: $ARCHIVE. Extracting..."
        tar xjf "$ARCHIVE"
        success "Extraction completed."
}

if [ -z "$1" ]; then
    error "Error: No argument specified."
    info "Usage: $0 {env|repo|pack|unpack}"
    exit 1
fi

case "$1" in
    env)
        setup_env
        ;;
    repo)
        sanity_check
        check_git_config
        setup_repo $2 
        ;;
    pack)
        sanity_check
        check_git_config
        pack_repo
        ;;
    unpack)
        unpack_repo
        ;;
    *)
        error "Error: Unknown argument '$1'."
        info "Usage: $0 {env|repo|pack}"
        exit 1
        ;;
esac
