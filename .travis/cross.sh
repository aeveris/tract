#!/bin/sh

set -ex

export DEBIAN_FRONTEND=noninteractive

if [ `whoami` != "root" ]
then
    SUDO=sudo
fi

if [ `uname` = "Linux" ]
then
    $SUDO rm -f /etc/apt/sources.list.d/dotnetdev.list /etc/apt/sources.list.d/microsoft-prod.list
    $SUDO apt-get update
    if [ -z "$TRAVIS" -a -z "$GITHUB_WORKFLOW" ]
    then
        $SUDO apt-get -y upgrade
        $SUDO apt-get install -y unzip wget curl python awscli build-essential
    fi
else
    sysctl -n machdep.cpu.brand_string
    brew install coreutils
fi

ROOT=$(dirname $(dirname $(realpath $0)))

which rustup || curl https://sh.rustup.rs -sSf | sh -s -- -y

PATH=$PATH:$HOME/.cargo/bin

which cargo-dinghy || ( mkdir -p /tmp/cargo-dinghy
if [ `arch` = x86_64 ]
then
    cd /tmp/cargo-dinghy
    if [ `uname` = "Darwin" ]
    then
        NAME=macos
    else
        NAME=linux
    fi
    VERSION=0.4.61
    wget -q https://github.com/snipsco/dinghy/releases/download/$VERSION/cargo-dinghy-$NAME-$VERSION.tgz -O cargo-dinghy.tgz
    tar vzxf cargo-dinghy.tgz --strip-components 1
    mv cargo-dinghy $HOME/.cargo/bin
else
    cargo install cargo-dinghy
fi
)

case "$PLATFORM" in
    "raspbian")
        [ -e $HOME/cached/raspitools ] || git clone --depth 1 https://github.com/raspberrypi/tools $HOME/cached/raspitools
        TOOLCHAIN=$HOME/cached/raspitools/arm-bcm2708/arm-rpi-4.9.3-linux-gnueabihf
        export RUSTC_TRIPLE=arm-unknown-linux-gnueabihf
        rustup target add $RUSTC_TRIPLE
        echo "[platforms.$PLATFORM]\nrustc_triple='$RUSTC_TRIPLE'\ntoolchain='$TOOLCHAIN'" > $HOME/.dinghy.toml
        cargo dinghy --platform $PLATFORM build --release -p tract -p example-tensorflow-mobilenet-v2
        ;;

    "aarch64-linux-android"|"armv7-linux-androideabi"|"i686-linux-android"|"x86_64-linux-android")
        case "$PLATFORM" in
            "aarch64-linux-android")
                ANDROID_CPU=aarch64
                RUSTC_TRIPLE=aarch64-linux-android
                ;;
            "armv7-linux-androideabi")
                ANDROID_CPU=armv7
                RUSTC_TRIPLE=armv7-linux-androideabi
                ;;
            "i686-linux-android")
                ANDROID_CPU=i686
                RUSTC_TRIPLE=i686-linux-android
                ;;
            "x86_64-linux-android")
                ANDROID_CPU=x86_64
                RUSTC_TRIPLE=x86_64-linux-android
                ;;
        esac

        if [ -e /usr/local/lib/android/sdk/ndk-bundle ]
        then
            export ANDROID_NDK_HOME=/usr/local/lib/android/sdk/ndk-bundle
        else
            export ANDROID_SDK_HOME=$HOME/cached/android-sdk
            [ -e $ANDROID_SDK_HOME ] || ./.travis/android-ndk.sh
        fi

        rustup target add $RUSTC_TRIPLE
        cargo dinghy --platform auto-android-$ANDROID_CPU build -p tract-linalg
        ;;

    "aarch64-apple-ios")
        rustup target add aarch64-apple-ios
        cargo dinghy --platform auto-ios-aarch64 build -p tract-linalg
        ;;

    "aarch64-unknown-linux-gnu" | "armv6vfp-unknown-linux-gnueabihf" | "armv7-unknown-linux-gnueabihf" | \
    "aarch64-unknown-linux-musl" | "armv7-unknown-linux-musl" )

        case "$PLATFORM" in
            "aarch64-unknown-linux-gnu")
                export ARCH=aarch64
                export QEMU_ARCH=aarch64
                export RUSTC_TRIPLE=$ARCH-unknown-linux-gnu
                export DEBIAN_TRIPLE=$ARCH-linux-gnu
                ;;
            "armv6vfp-unknown-linux-gnueabihf")
                export ARCH=armv6vfp
                export QEMU_ARCH=arm
                export QEMU_OPTS="-cpu cortex-a15"
                export RUSTC_TRIPLE=arm-unknown-linux-gnueabihf
                export DEBIAN_TRIPLE=arm-linux-gnueabihf
                ;;
            "armv7-unknown-linux-gnueabihf")
                export ARCH=armv7
                export QEMU_ARCH=arm
                export QEMU_OPTS="-cpu cortex-a15"
                export RUSTC_TRIPLE=armv7-unknown-linux-gnueabihf
                export DEBIAN_TRIPLE=arm-linux-gnueabihf
                export TARGET_CC=$DEBIAN_TRIPLE-gcc
                export TRACT_CPU_ARM32_NEON=true
                export DINGHY_TEST_ARGS="--env TRACT_CPU_ARM32_NEON=true"
                ;;
            "aarch64-unknown-linux-musl")
                export ARCH=aarch64
                export QEMU_ARCH=aarch64
                export RUSTC_TRIPLE=$ARCH-unknown-linux-musl
                export CUSTOM_TC=`pwd`/aarch64-linux-musl-cross
                [ -d "$CUSTOM_TC" ] || curl -s http://musl.cc/aarch64-linux-musl-cross.tgz | tar zx
                ;;
            "armv7-unknown-linux-musl")
                export ARCH=armv7
                export QEMU_ARCH=arm
                export RUSTC_TRIPLE=armv7-unknown-linux-musleabihf
                export CUSTOM_TC=`pwd`/armv7l-linux-musleabihf-cross
                export TRACT_CPU_ARM32_NEON=true
                export DINGHY_TEST_ARGS="--env TRACT_CPU_ARM32_NEON=true"
                [ -d "$CUSTOM_TC" ] || curl -s http://musl.cc/armv7l-linux-musleabihf-cross.tgz | tar zx
                export TARGET_CFLAGS="-mfpu=neon"
                ;;
            *)
                echo "unsupported platform $PLATFORM"
                exit 1
                ;;
        esac

        mkdir -p $ROOT/target/$RUSTC_TRIPLE
        echo "[platforms.$PLATFORM]\nrustc_triple='$RUSTC_TRIPLE'" > .dinghy.toml
        if [ -n "$DEBIAN_TRIPLE" ]
        then
            echo "deb_multiarch='$DEBIAN_TRIPLE'" >> .dinghy.toml
        fi
        if [ -n "$CUSTOM_TC" ]
        then
            echo "toolchain='$CUSTOM_TC'" >> .dinghy.toml
        fi
        echo "[script_devices.qemu-$ARCH]\nplatform='$PLATFORM'\npath='$ROOT/target/$RUSTC_TRIPLE/qemu'" >> .dinghy.toml

        echo "#!/bin/sh\nexe=\$1\nshift\n/usr/bin/qemu-$QEMU_ARCH $QEMU_OPTS -L /usr/$DEBIAN_TRIPLE/ \$exe --test-threads 1 \"\$@\"" > $ROOT/target/$RUSTC_TRIPLE/qemu
        chmod +x $ROOT/target/$RUSTC_TRIPLE/qemu

        DINGHY_TEST_ARGS="$DINGHY_TEST_ARGS --env PROPTEST_MAX_SHRINK_ITERS=100000000"

        if [ -n "$DEBIAN_TRIPLE" ]
        then
            $SUDO apt-get -y install binutils-$DEBIAN_TRIPLE gcc-$DEBIAN_TRIPLE 
        fi
        $SUDO apt-get -y install qemu-system-arm qemu-user libssl-dev pkg-config
        rustup target add $RUSTC_TRIPLE
        qemu-$QEMU_ARCH --version
        cargo dinghy --platform $PLATFORM test --release -p tract-linalg $DINGHY_TEST_ARGS -- --nocapture
        cargo dinghy --platform $PLATFORM test --release -p tract-core $DINGHY_TEST_ARGS
        cargo dinghy --platform $PLATFORM build --release -p tract -p example-tensorflow-mobilenet-v2
        ;;

    "wasm32-unknown-unknown")
        rustup target add wasm32-unknown-unknown
        cargo check --target wasm32-unknown-unknown -p tract-onnx -p tract-tensorflow
        ;;
    *)
        echo "Don't know what to do for platform: $PLATFORM"
        exit 2
        ;;
esac

if [ -n "$AWS_ACCESS_KEY_ID" -a -e "target/$RUSTC_TRIPLE/release/tract" ]
then
    export RUSTC_TRIPLE
    TASK_NAME=`.travis/make_bundle.sh`
    aws s3 cp $TASK_NAME.tgz s3://tract-ci-builds/tasks/$PLATFORM/$TASK_NAME.tgz
fi
