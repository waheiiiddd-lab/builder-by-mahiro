#!/usr/bin/env bash
# shellcheck disable=SC2164

set -euo pipefail

WORKDIR="$(pwd)"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"
KERNEL_PATCHES="$WORKDIR/kernel-patches"

KERNEL_NAME="$KERNELNAME"
KERNEL_BRANCH="$KERNELBRANCH"
USER="dev"
HOST="celoxx"
TIMEZONE="Asia/Jakarta"
KERNEL_DEFCONFIG="gki_defconfig"
KERNEL_REPO="https://github.com/rinnsakaguchi/android_kernel_common-5.10"

ANYKERNEL_REPO="https://github.com/rinnsakaguchi/AnyKernel3"
ANYKERNEL_BRANCH="master"
GKI_RELEASES_REPO="https://github.com/rinnsakaguchi/Anisphia-Release"
CLANG_BRANCH=""
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/f60b8b55282f002f594f452ce22dfd6cf1fd7e3c/clang-r596125.tar.gz"

make=$(command -v make)
export make

exec > >(tee "$WORKDIR/build.log") 2>&1
trap 'error "Failed at line $LINENO [$BASH_COMMAND]"' ERR

source "$WORKDIR/functions.sh"

sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null || export TZ="$TIMEZONE"

log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC"

# Gather kernel version info
cd "$KSRC"
LINUX_VERSION=$(make kernelversion)
LINUX_VERSION_CODE=${LINUX_VERSION//./}
KVER="$LINUX_VERSION"
# Extract only the major version digit for numeric comparison
LINUX_MAJOR="${LINUX_VERSION%%.*}"

DEFCONFIG_FILE=$(find "$KSRC/arch/arm64/configs" -name "$KERNEL_DEFCONFIG" -print -quit)
[[ -f "$DEFCONFIG_FILE" ]] || { error "Defconfig '$KERNEL_DEFCONFIG' not found"; exit 1; }

k_lastcommit=$(git -C "$KSRC" rev-parse --short HEAD)

log "Setting kernel variant..."
case "$VARIANT" in
  VNL)
    log "Building Vanilla kernel (no KernelSU)"
    ;;

  KSU)
    log "Building KernelSU"
    ;;

  KSUS)
    log "Building KernelSU + SuSFS"
    ;;

  *)
    error "Unknown VARIANT: $VARIANT"
    ;;
esac

# Download Clang
CLANG_DIR="$WORKDIR/clang"
CLANG_BIN="${CLANG_DIR}/bin"
if [[ -z "$CLANG_BRANCH" ]]; then
  log "Downloading Clang..."
  aria2c -x16 -s16 -k1M "$CLANG_URL" -o clang-archive
  mkdir -p "$CLANG_DIR"
  case "$(basename $CLANG_URL)" in
    *.tar.* | *.tgz)
      tar -xf clang-archive -C "$CLANG_DIR"
      ;;
    *.7z)
      7z x clang-archive -o"${CLANG_DIR}/" -bd -y > /dev/null
      ;;
    *)
      error "Unsupported file format"
      ;;
  esac
  rm clang-archive

  if [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
    && [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv "$SINGLE_DIR"/* "$CLANG_DIR"/
    rm -rf "$SINGLE_DIR"
  fi
else
  log "Cloning Clang..."
  git clone --depth=1 -q "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi

# Clone GNU Assembler
log "Cloning GNU Assembler..."
GAS_DIR="$WORKDIR/gas"
git clone --depth=1 -q \
  https://android.googlesource.com/platform/prebuilts/gas/linux-x86 \
  -b main \
  "$GAS_DIR"

export PATH="${CLANG_BIN}:${GAS_DIR}:$PATH"

COMPILER_STRING=$(clang --version | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

cd "$KSRC"

# Variant setup
DEFCONFIG="$DEFCONFIG_FILE"

sed -i '/CONFIG_KSU/d' "$DEFCONFIG"
sed -i '/CONFIG_KSU_SUSFS/d' "$DEFCONFIG"

if [ "$VARIANT" == "KSU" ] || [ "$VARIANT" == "KSUS" ]; then
    # Patch KernelSU-Next
    curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" | bash -s dev-susfs
    
    # Patch All Managers
    echo "Patching All Managers Support..."
    if [ -d "KernelSU-Next" ]; then
        patch -p1 -d KernelSU-Next < $KERNEL_PATCHES/ksu/ksun-add-more-managers-support.patch || exit 1
    else
        echo "Error: KernelSU-Next directory not found!" && exit 1
    fi
fi

if [ "$VARIANT" == "KSU" ]; then
    echo "CONFIG_KSU=y" >> "$DEFCONFIG"
    echo "# CONFIG_KSU_SUSFS is not set" >> "$DEFCONFIG"
    echo "ENABLE_SUSFS=false" >> "$GITHUB_ENV"
    
elif [ "$VARIANT" == "KSUS" ]; then
    # SuSFS Logic
    git clone https://gitlab.com/simonpunk/susfs4ksu/ -b gki-android12-5.10 sus
    rm -rf sus/.git
    cp -r sus/kernel_patches/fs . && cp -r sus/kernel_patches/include .
    patch -p1 < sus/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch || exit 1
    rm -rf sus

    echo "CONFIG_KSU=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS=y" >> "$DEFCONFIG"

    if [ -f "drivers/kernelsu/supercalls.c" ]; then
        sed -i 's|#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME|#if 0 /* Disabled to fix build */|' drivers/kernelsu/supercalls.c || true
    fi
    echo "ENABLE_SUSFS=true" >> "$GITHUB_ENV"

else
    echo "ENABLE_SUSFS=false" >> "$GITHUB_ENV"
fi

# Clean old values
sed -i '/CONFIG_HZ/d' "$DEFCONFIG"
sed -i '/CONFIG_LTO_CLANG/d' "$DEFCONFIG"
sed -i '/CONFIG_LTO_CLANG_THIN/d' "$DEFCONFIG"
sed -i '/CONFIG_LTO_CLANG_FULL/d' "$DEFCONFIG"

# Apply tuning config
echo "CONFIG_LTO_CLANG=y" >> "$DEFCONFIG"
echo "CONFIG_LTO_CLANG_THIN=y" >> "$DEFCONFIG"

# set localversion
if [[ $TODO == "kernel" ]]; then
  if [[ $STATUS == "BETA" ]]; then
    SUFFIX="$k_lastcommit"
  else
    SUFFIX="$RELEASE"
  fi
  config --set-str CONFIG_LOCALVERSION "-$KERNEL_NAME"
  config --disable CONFIG_LOCALVERSION_AUTO
  sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion
fi

# Declare needed variables
export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"

KBUILD_BUILD_TIMESTAMP=$(date)
export KBUILD_BUILD_TIMESTAMP
export KCFLAGS="-w"

MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  "-j$(nproc --all)"
  "O=$OUTDIR"
)

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"
if [[ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]]; then
  KMI_CHECK="$WORKDIR/py/kmi-check-6.x.py"
else
  KMI_CHECK="$WORKDIR/py/kmi-check-5.x.py"
fi

text=$(
  cat << EOF
*Kernel Version*: \`${LINUX_VERSION}\`
*Build Date*: \`${KBUILD_BUILD_TIMESTAMP}\`
*Variant*: \`${VARIANT}\`
*Compiler*: \`${COMPILER_STRING}\`
*Kernol commit*: [${k_lastcommit}](${KERNEL_REPO}/commit/${k_lastcommit})
EOF
)

## Build GKI
log "Generating config..."
make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"
make "${MAKE_ARGS[@]}" olddefconfig

# Upload defconfig
if [[ $TODO == "defconfig" ]]; then
  log "Uploading defconfig..."
  upload_file "$OUTDIR/.config"
  exit 0
fi

# Build the actual kernel
log "Building kernel..."
make "${MAKE_ARGS[@]}"

# Check KMI Function symbol
if [[ $(echo "$LINUX_VERSION_CODE" | head -c1) -eq 6 ]]; then
  $KMI_CHECK "$KSRC/android/abi_gki_aarch64.stg" "$MODULE_SYMVERS" || true
else
  $KMI_CHECK "$KSRC/android/abi_gki_aarch64.xml" "$MODULE_SYMVERS" || true
fi

BUILD_DATE=$(date +"%Y%m%d-%H%M")
AK3_ZIP_NAME="$KERNEL_NAME-$KVER-$VARIANT-$BUILD_DATE.zip"
## Post-compiling stuff
cd "$WORKDIR"

# Clone AnyKernel
log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

# Zip the anykernel
cd anykernel
log "Zipping anykernel..."
cp "$KERNEL_IMAGE" .
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./*
cd "$OLDPWD"

if [[ $STATUS != "BETA" ]]; then
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> "$GITHUB_ENV"
  mkdir -p "$WORKDIR/artifacts"
  mv "$WORKDIR"/*.zip "$WORKDIR/artifacts"
fi

if [[ $STATUS == "BETA" ]]; then
  upload_file "$WORKDIR/$AK3_ZIP_NAME" "$text"
  upload_file "$WORKDIR/build.log"
else
  send_msg "✅ Build Succeeded for $VARIANT variant."
fi

exit 0
