#!/bin/bash

# Author: Alexander Rodin <rodin.alexander@gmail.com>
# License: MIT

PATCHES=()
ROOT_DIRS=()
OPTIONS=()
CONFIGS=()
DEPS=()
BUILD_DEPS=()
CCACHE_DIR="ccache"
MAINTAINER="nginx-dpkg-build <nginx-dpkg-build@github.com>"
while getopts "hp:s:r:b:o:c:d:k:m:a:i:zn-:" opt; do
    case $opt in
        h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -s <suffix>     - specify suffix added to the resulting packages (required)"
            echo "  -d <dist>       - specify target distribution as docker image (e.g. ubuntu:14.04, required)"
            echo "  -z              - build on the host system without docker (alternative to specifying -d)"
            echo "  -b <build dir>  - directory for building (default is nginx-<suffix>_<dist>)"
            echo "  -p <patch>      - add patch to the source tree"
            echo "  -r <root tree>  - add directory with root tree (containing e.g. usr and var dirs) to the package"
            echo "  -o <flag>       - pass option to the configure script (e.g. -o'--with-libatomic')"
            echo "  -c <config>     - add config file or directory for installation into /etc/nginx"
            echo "  -a <package>    - require runtime dependency (e.g. libatomic1)"
            echo "  -i <package>    - require buildtime dependency (e.g. libatomic-ops-dev)"
            echo "  -k <ccache dir> - directory for ccache (default is ccache)"
            echo "  -m <maintainer> - set maintainer name (default is 'nginx-dpkg-build <nginx-dpkg-build@github.com>')"
            echo "  -n              - don't run dpkg-buildpackage"
            echo "  -h              - show this help"
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
        a)
            DEPS+=("$OPTARG")
            ;;
        i)
            BUILD_DEPS+=("$OPTARG")
            ;;
        k)
            CCACHE_DIR="$OPTARG"
            ;;
        m)
            MAINTAINER="$OPTARG"
            ;;
        n)
            NO_BUILD=1
            ;;
        z)
            INSIDE_CONTAINER=1
            ;;
        ?)
            exit 1
            ;;
    esac
done

# checking that suffix is specified
[ "$SUFFIX" ] || { echo -e "Error: suffix is not specified.\nRun $0 -h to get help."; exit 1; }

# checking out target distribution
[ "$DOCKER_IMAGE" ] || [ "$INSIDE_CONTAINER" ] ||
    { echo -e "Error: either -d <target distribution> or -z flag is required.\nRun $0 -h to get help."; exit 1; }

# setting default build directory name if it is not specified
[ -z "$BUILD_DIR" ] && BUILD_DIR="nginx-$SUFFIX" && [ "$DOCKER_IMAGE" ] && BUILD_DIR=$(echo "${BUILD_DIR}_${DOCKER_IMAGE}" | tr : _)

# removing trailing slash from build dir path if any
BUILD_DIR=$(echo "$BUILD_DIR" | sed 's#/*$##')

# creating build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# creating ccache directory
mkdir -p "$CCACHE_DIR"

if [ "$DOCKER_IMAGE" ]; then
    # preparing command line arguments for docker
    DOCKER_OPTIONS=("-s" "$SUFFIX" "-z")
    DOCKER_VOLUMES=("-v" "$PWD/$0:/mnt/$0")
    DEPS_STRIPPED=()
    BUILD_DEPS_STRIPPED=()
    for PATCH in "${PATCHES[@]}"; do
        DOCKER_VOLUMES+=("-v" "$PWD/$PATCH:/mnt/$PATCH")
        DOCKER_OPTIONS+=("-p" "/mnt/$PATCH")
    done
    for ROOT_DIR in "${ROOT_DIRS[@]}"; do
        DOCKER_VOLUMES+=("-v" "$PWD/$ROOT_DIR:/mnt/$ROOT_DIR")
        DOCKER_OPTIONS+=("-p" "/mnt/$ROOT_DIR")
    done
    DOCKER_VOLUMES+=("-v" "$PWD/$BUILD_DIR:/mnt/$BUILD_DIR-target")
    DOCKER_OPTIONS+=("-b" "/mnt/$BUILD_DIR")
    for OPTION in "${OPTIONS[@]}"; do
        DOCKER_OPTIONS+=("-o" "$OPTION")
    done
    for CONFIG in "${CONFIGS[@]}"; do
        DOCKER_VOLUMES+=("-v" "$PWD/$CONFIG:/mnt/$CONFIG")
        DOCKER_OPTIONS+=("-c" "/mnt/$CONFIG")
    done
    for DEP in "${DEPS[@]}"; do
        DOCKER_OPTIONS+=("-a" "$DEP")
        DEPS_STRIPPED+=($(echo "$DEP" | sed 's/ .*$//'))
    done
    for BUILD_DEP in "${BUILD_DEPS[@]}"; do
        DOCKER_OPTIONS+=("-i" "$BUILD_DEP")
        BUILD_DEPS_STRIPPED+=($(echo "$BUILD_DEP" | sed 's/ .*$//'))
    done
    DOCKER_VOLUMES+=("-v" "$PWD/$CCACHE_DIR:/mnt/$CCACHE_DIR")
    DOCKER_OPTIONS+=("-k" "$CCACHE_DIR")
    DOCKER_OPTIONS+=("-m" "$MAINTAINER")
    [ "$NO_BUILD" ] && DOCKER_OPTIONS+=("-n")

    # building docker image with build dependencies to avoid installing build dependencies on each run
    DOCKER_IMAGE_BUILD="nginx-dpkg-$DOCKER_IMAGE"
    (docker build -t "$DOCKER_IMAGE_BUILD" - << EOF
        FROM $DOCKER_IMAGE
        RUN sed -i 's/^deb \(.*\)/deb \1\ndeb-src \1/g' /etc/apt/sources.list
        RUN apt-get update && apt-get build-dep -y nginx && apt-get install -y ccache
        RUN apt-get install -y ${DEPS_STRIPPED[@]} ${BUILD_DEPS_STRIPPED[@]}
EOF
    ) || { echo "Error: unable to build docker image"; exit 1; }

    # running the script inside of a docker container and exiting
    docker run --rm -i "${DOCKER_VOLUMES[@]}" "$DOCKER_IMAGE_BUILD" bash "/mnt/$0" "${DOCKER_OPTIONS[@]}" && exit 0 || exit 1
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
        Build-Depends:*)
            for BUILD_DEP in "${BUILD_DEPS[@]}"; do
                LINE="$LINE, $BUILD_DEP"
            done
            ;;
        Depends:*)
            (echo "$PACKAGE" | egrep -qv "(doc|dbg)$") && for DEP in "${DEPS[@]}"; do
                LINE="$LINE, $DEP"
            done
            ;;
    esac
    echo "$LINE"
done < control > control.tmp
mv control.tmp control

# altering mentions of nginx-common in rules file
sed -i -re "s|nginx-common|nginx-$SUFFIX-common|g" rules

# adding configure options to the rules file
for OPTION in "${OPTIONS[@]}"; do
    RULES_OPTIONS+="\n\t\t\t$OPTION \\\\"
done
sed -i -re "s|common_configure_flags.*$|\0$RULES_OPTIONS|" rules

# adding entry about modifications to the changelog
cat > changelog.tmp << EOF
$(head -n1 changelog | sed 's/)/~'$SUFFIX')/')

  * Build nginx-$SUFFIX packages.

 -- $MAINTAINER  $(date --rfc-822)

$(cat changelog)

EOF
mv changelog.tmp changelog

popd

# building the packages
if [ ! "$NO_BUILD" ]; then
    export CCACHE_DIR="/mnt/$CCACHE_DIR"
    export PATH="/usr/lib/ccache:$PATH"
    pushd "$NGINX_DIR"
    dpkg-buildpackage
    popd
fi

# moving built data to the mounted build dir because dpkg-buildpackage fails to handle user permissions in mounted volumes
[ "$INSIDE_CONTAINER" ] && [ -d "$BUILD_DIR-target" && mv "$BUILD_DIR"/*  "$BUILD_DIR-target"
