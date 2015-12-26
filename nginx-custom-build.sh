#!/bin/bash

BUILD_DIR=build
while getopts "hp:s:r:b:o:c:n" opt; do
    case $opt in
        h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -s <suffix>     - specify suffix added to the resulting packages (required)"
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
        p)
            PATCHES+="$OPTARG"$'\n'
            ;;
        r)
            ROOT_DIRS+="$OPTARG"$'\n'
            ;;
        b)
            BUILD_DIR="$OPTARG"
            ;;
        o)
            OPTIONS+="$OPTARG"$'\n'
            ;;
        c)
            CONFIGS+="$OPTARG"$'\n'
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

# creating directory for building
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# obtaining sources
pushd "$BUILD_DIR"
apt-get source nginx || exit 1
NGINX_DIR="$BUILD_DIR/$(ls | head -n1)"
popd

# applying patches
IFS=$'\n'
for PATCH in $PATCHES; do
    cp "$PATCH" "$NGINX_DIR/debian/patches/$(basename $PATCH)" || exit 1
    echo $(basename $PATCH) >> "$NGINX_DIR/debian/patches/series"
done

# copying configs
for CONFIG in $CONFIGS; do
    cp -R "$CONFIG" "$NGINX_DIR/debian/conf/" || exit 1
done

# copying additional files to to debain/root
mkdir -p "$NGINX_DIR/debian/root"
for ROOT_DIR in $ROOT_DIRS; do
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
IFS=$'\n'
for OPTION in $OPTIONS; do
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