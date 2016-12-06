# nginx-dpkg-build

This script simplifies making custom builds of [NGINX](https://nginx.org/en/) web server for Debian and Ubuntu systems. Earlier versions were published [here](https://gist.github.com/a-rodin/8406815dd05f39f10418).

The key features:
* Support for custom patches, configs, build flags, and arbitrary files in the target filesystem.
* Using of `dpkg-buildpackage`. The packages are built using the same procedure as the ones in the official repositories and based on the versions from the official repositories.
* Custom suffixes for package names allow the built packages to not be replaced by non-patched versions on system upgrade.
* Building for any Ubuntu and Debian version by running build environments in Docker containers.

## Dependencies

To run the script you should have either:
* Bash and Docker on any POSIX-compatible system;
* or Ubuntu/Debian system, same as the target one, with build dependencies installed by

   ```bash
   sudo apt-get build-dep -y nginx
   sudo apt-get install -y ccache
   ```
  Although the `ccache` requirement is not mandatory, it significantly speeds up subsequent rebuilds.

## Basic Usage

The basic usage is following:

```bash
./nginx-dpkg-build.sh -s mysuffix -d ubuntu:16.04
```
It rebuilds NGINX packages for Ubuntu 16.04, but the names of build packages look like `nginx-mysuffix` and `nginx-mysuffix-common` instead of generic `nginx` and `nginx-common`.

The build runs in a Docker container from the official Ubuntu image, the output files are located by default in `nginx-mysuffix_ubuntu_16.04` in the current subdirectory.

Alternatively, if you don't want to use Docker, you could specify `-z` flag instead of `-d`:

```
./nginx-dpkg-build.sh -s mysuffix -z
```
## Options

| Flag | Description | Example |
|------|-------------|----------|
| `-s <suffix>` | specify suffix added to the resulting packages (required) | `-s mysuffix` |
| `-d <dist>` | specify target distribution as a docker tag ([ubuntu](https://hub.docker.com/_/ubuntu/), [debian](https://hub.docker.com/_/debian/)) |  `-d debian:jessie` |
| `-z` | build on the host system without docker | |
| `-b <dir>` | specify build directory (default is `nginx-{suffix}_{dist}` | `-b ./build-dir` |
| `-p <patch>` | add patch to the source tree | `-p ./patch1.patch` |
| `-r <dir>` | copy files from the directory to the package's root dir | `-r ./root-dir` |
| `-o <flag>` | pass option to the configure script | `-o '--with-libatomic'` |
| `-c <config>` | add config file or directory for installation to /etc/nginx  | `-c nginx.conf` |
| `-m <module>` | add module's directory to compile it into nginx | `-m ./ngx_postgres/` |
| `-a <package>` | add dependency to the compiled package | `-a libatomic1` |
| `-u <package>` | add build dependency | `-u libatomic-ops-dev (>= 7.3)` |
| `-k <dir>` | directory for ccache  | `-k $HOME/.ccache` |
| `-i <name>` | maintainer's name and email for package changelog | `-i "Name <name@domain.com>"` |
| `-n` | don't run dpkg-buildpackage | |
| `-h` | show help | |

## Examples

### Adding PostgreSQL module
```bash
git clone https://github.com/FRiCKLE/ngx_postgres.git
./nginx-dpkg-build.sh -s postgres -u debian:jessie \
    -a postgresql-common -u postgresql-server-dev-all -m `ngx_postgres`
```

### Adding libatomic support
```bash
./nginx-dpkg-build.sh -s atomic -u ubuntu:14.04 \
    -a libatomic1 -u 'libatomic-ops-dev (>= 7.3)' -o '--with-libatomic'
```

### Publishing packages to PPA
This example assumes that you have a [launchpad](https://launchpad.net/) account and created a PPA repository.

You could build package as described previously, but should specify your name and email to be included to
the package:

```bash
./nginx-dpkg-build.sh -s mysuffix -i "My Name <my@email.com>" -d ubuntu:16.04
```

Then you could navigate to the build directory `nginx-mysuffix_ubuntu_16.04` and upload the changes to PPA
as described in the [upload instructions](https://help.launchpad.net/Packaging/PPA/Uploading). Note that you need to
have your GPG public key uploaded to launchpad in order to upload packages to PPA.
