Testing the installer
=====================

This is currently done manually, using Docker and various other host OSes.
We should find a sane way to do this in a performant manner.

On each OS, I run:

```sh
curl -fSs https://get-nats.io/install.sh | sh
curl -O https://get-nats.io/install.sh
sh ./install.sh -c nightly -f

nats
```

If testing changes before pushing, just `docker cp` the script into a running
image, leaving it as clean and free of other supporting changes as possible.


## Results

### Alpine

```sh
docker run -it --rm alpine
  apk add curl
```

Works; led to adapting checksum handling to the busybox sha256sum command.

### Arch Linux

```sh
docker run -it --rm archlinux
  pacman -Sy
  pacman -S unzip
```

Works.

### Ubuntu

```sh
docker run -it --rm ubuntu
  apt update
  apt install curl unzip
```

Works.

### Fedora

```sh
docker run -it --rm fedora
  dnf install unzip
```

Works; led to discovering Fedora drops _xargs(1)_ and some unhappiness.
Workaround implemented; prior to workaround, Fedora worked after
`dnf install findutils`.

### FreeBSD

Currently fails because nsc is not built for FreeBSD.

