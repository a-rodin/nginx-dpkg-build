#!/bin/bash

# Author: Alexander Rodin <rodin.alexander@gmail.com>
# License: MIT

BUILD_DIR=build
PATCHES=()
ROOT_DIRS=()
OPTIONS=()
CONFIGS=()
while getopts "hp:s:r:b:o:c:d:n" opt; do
    case $opt in
        h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -s <suffix>     - specify suffix added to the resulting packages (required)"
            echo "  -d <dist>       - specify target distribution as docker image (e.g. ubuntu:14.04)"
            echo "  -p <patch>      - add patch to the source tree"
            echo "  -r <root tree>  - add directory with root tree (containing e.g. usr and var dirs) to the package"
            echo "  -b <build dir>  - directory for building (default is $BUILD_DIR)"
            echo "  -o <flag>       - pass option to the configure script (e.g. -o'--with-libatomic')"
            echo "  -c <config>     - add config file or directory for installation into /etc/nginx"
            echo "  -n              - don't run dpkg-buildpackage"
            echo "  -h              - show this help"
            echo "To run the script one have to install nginx build dependencies. It could be done by running command"
            echo "  sudo apt-get install build-dep nginx"
            exit 1
            ;;
        s)
            SUFFIX="$OPTARG"
            ;;
        d)
            DOCKER_IMAGE="$OPTARG"
            ;;
        p)
            PATCHES+=("$OPTARG")
            ;;
        r)
            ROOT_DIRS+=("$OPTARG")
            ;;
        b)
            BUILD_DIR="$OPTARG"
            ;;
        o)
            OPTIONS+=("$OPTARG")
            ;;
        c)
            CONFIGS+=("$OPTARG")
            ;;
        n)
            NO_BUILD=1
            ;;
        ?)
            exit 1
            ;;
    esac
done

# checking that suffix is specified
[ "$SUFFIX" ] || { echo -e "Error: suffix is not specified. Run $0 -h to view help."; exit 1; }

# creating build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [ "$DOCKER_IMAGE" ]; then
    # preparing command line arguments for docker
    DOCKER_OPTIONS=("-s" "$SUFFIX")
    DOCKER_VOLUMES=("-v" "$PWD/$0:/mnt/$0")
    for PATCH in "${PATCHES[@]}"; do
        DOCKER_VOLUMES+=("-v" "$PWD/$PATCH:/mnt/$PATCH")
        DOCKER_OPTIONS+=("-p" "/mnt/$PATCH")
    done
    for ROOT_DIR in "${ROOT_DIRS[@]}"; do
        DOCKER_VOLUMES+=("-v" "$PWD/$ROOT_DIR:/mnt/$ROOT_DIR")
        DOCKER_OPTIONS+=("-p" "/mnt/$ROOT_DIR")
    done
    DOCKER_VOLUMES+=("-v" "$PWD/$BUILD_DIR:/mnt/$BUILD_DIR")
    DOCKER_OPTIONS+=("-b" "/mnt/$BUILD_DIR")
    for OPTION in "${OPTIONS[@]}"; do
        DOCKER_OPTIONS+=("-o" "$OPTION")
    done
    for CONFIG in "${CONFIGS[@]}"; do
        DOCKER_VOLUMES+=("-v" "$PWD/$CONFIG:/mnt/$CONFIG")
        DOCKER_OPTIONS+=("-c" "/mnt/$CONFIG")
    done
    [ "$NO_BUILD" ] && DOCKER_OPTIONS+=("-n")

    # building docker image with build dependencies to avoid installing build dependencies on each run
    DOCKER_IMAGE_BUILD="nginx-dpkg-$DOCKER_IMAGE"
    echo -e "FROM $DOCKER_IMAGE\nRUN apt-get update && apt-get build-dep -y nginx" | docker build -t "$DOCKER_IMAGE_BUILD" -

    # running the script inside of a docker container and exiting
    echo docker run -i "${DOCKER_VOLUMES[@]}" "$DOCKER_IMAGE_BUILD" bash "/mnt/$0" "${DOCKER_OPTIONS[@]}"
    docker run -it "${DOCKER_VOLUMES[@]}" "$DOCKER_IMAGE_BUILD" bash && exit 0 || exit 1
fi

# obtaining sources
pushd "$BUILD_DIR"
apt-get source nginx || exit 1
NGINX_DIR="$BUILD_DIR/$(ls | head -n1)"
popd

# applying patches
for PATCH in "${PATCHES[@]}"; do
    cp "$PATCH" "$NGINX_DIR/debian/patches/$(basename $PATCH)" || exit 1
    echo $(basename $PATCH) >> "$NGINX_DIR/debian/patches/series"
done

# copying configs
for CONFIG in "${CONFIGS[@]}"; do
    cp -R "$CONFIG" "$NGINX_DIR/debian/conf/" || exit 1
done

# copying additional files to to debain/root
mkdir -p "$NGINX_DIR/debian/root"
for ROOT_DIR in "${ROOT_DIRS[@]}"; do
    cp -R "$ROOT_DIR/"* "$NGINX_DIR/debian/root" || exit 1
done
# adding these additional files to the install scripts (only to scripts for the packages
# that contain nginx executable)
pushd "$NGINX_DIR"
for SCRIPT in $(grep sbin debian/*.install | cut -f1 -d:); do
    if [ -x $SCRIPT ]; then
        # it's actually a Perl script
        find debian/root -type f | sed -re 's|^debian/root/(.*)/(.*)$|print "\0 \1\\n";|' >> $SCRIPT
    else
        # it's a plain text file
        find debian/root -type f | sed -re 's|^debian/root/(.*)/(.*)$|\0 \1|' >> $SCRIPT
    fi
done
popd

# adding suffixes to the scripts names
pushd "$NGINX_DIR/debian"
for FILE in $(ls | grep nginx-); do
    echo $FILE
    mv $FILE $(echo $FILE | sed "s/^nginx-/nginx-$SUFFIX-/g")
done

# adding suffixes to the control file
LINE=$(grep -n -m 1 '^Package:' control | cut -f1 -d:)
sed -i -re "$LINE,\$s/nginx/nginx-$SUFFIX/g" control
sed -i -re "s/package.nginx-/\0$SUFFIX-/g" rules

# removing line breaks in lists to simplify editing
sed -i -re ':a;N;$!ba;s/\n {3,}/ /g' control

# tweaking suffixes where necessary
sed -i -re "/^(Conflicts|Provides):/ s/nginx-$SUFFIX([^,$]*)/nginx\1, \0/g" control
sed -i -re "/^(Breaks|Replaces):/ s/nginx-$SUFFIX/nginx/g" control

# adding original package name to the Provides/Conflicts/Replaces sections to ensure that the 
# packages could replace conventional nginx packages from the distribution
IFS=$'\n'
while read LINE; do
    case "$LINE" in
        Package:*)
            PACKAGE=$(echo "$LINE" | sed -re "s/^.*nginx-$SUFFIX(.*)$/nginx\1/")
            unset HAS_PROVIDES
            unset HAS_CONFLICTS
            unset HAS_REPLACES
            [ "$PACKAGE" == "nginx" ] && HAS_CONFLICTS=1 # Don't add conflicts to nginx package
            ;;
        Provides:*)
            HAS_PROVIDES=1
            LINE="$LINE, $PACKAGE"
            ;;
        Conflicts:*)
            HAS_CONFLICTS=1
            LINE="$LINE, $PACKAGE"
            ;;
        Replaces:*)
            HAS_REPLACES=1
            LINE="$LINE, $PACKAGE"
            ;;
        Description:*)
            [ "$HAS_PROVIDES" ] || echo "Provides: $PACKAGE"
            [ "$HAS_CONFLICTS" ] || echo "Conflicts: $PACKAGE"
            [ "$HAS_REPLACES" ] || echo "Replaces: $PACKAGE"
            ;;
    esac
    echo "$LINE"
done < control > control.tmp
mv control.tmp control

# adding configure options to the rules file
for OPTION in "${OPTIONS[@]}"; do
    RULES_OPTIONS+="\n\t\t\t$OPTION \\\\"
done
sed -i -re "s|common_configure_flags.*$|\0$RULES_OPTIONS|" rules

popd

# building the packages
if [ ! "$NO_BUILD" ]; then
    pushd "$NGINX_DIR"
    dpkg-buildpackage
    popd
fi
