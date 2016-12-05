# nginx-dpkg-build

A script that simplifies make of Ubuntu and Debian packages for custom builds of [https://nginx.org/en/](NGINX web server).

It supports adding custom patches, configure flags, and prepared configuration files to the builds.

The key feature is using of standard `dpkg-buildpackage` tool which is
[the official way](https://www.debian.org/doc/manuals/maint-guide/build.en.html) to build `.deb` packages. It means
that the `debian` folder created by the utility could be used with PPA repositories.

## Usage

The script is supposed to be executed on Ubuntu or Debian system of the same version as the target one.
The system should have deb-src repositories enabled in [sources list](https://wiki.debian.org/SourcesList).
In order to make the script work one have run before its execution this command:

```bash
sudo apt-get install build-dep nginx
```

Basic usage:

`./nginx-custom-build -s mysuffix [flags]`.

Flags list:

* `-s <suffix>` - specify suffix added to the resulting packages. This flag is required.
  Example: `./nginx-custom-build -s foo` creates packages named `foo-nginx-...`.
* `-p <patch filename>` - add patch to the source tree.  The patch filename should have a `.patch` extension.
* `-r <root dir>` - copy recursively the content of `root dir` to the package.
* `-b <build dir>` - directory where to place the built packages. Default value is content of `$BUILD_DIR` or
  the current directory.
* `-o "flag"` - pass flags to the `./configure` script. 
  Example: `-o"--with-libatomic"`.
* `-c config` - add config file to `/etc/nginx` directory. 
  Example: `-c nginx.conf`.
* `-n` - do not run `dpkg-buildpackage`, just obtain nginx sources and set up the `debian` subdirectory.
* `-h` - show help.
