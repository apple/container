# Ubuntu 26.10 container machine image for the README demo
# (docs/assets/demo/landing-movie.tape). Adapted from the Ubuntu 24.04 example
# in docs/container-machine.md:
# - ubuntu-standard adds the familiar Ubuntu command-line tools, and
#   libpam-systemd, which registers login sessions with systemd-logind and
#   brings in systemd-sysv, whose /sbin/init boots systemd as PID 1;
# - sudo lets the machine user run commands as root;
# - apt-utils lets apt configure packages without debconf warnings.
# debconf is set to its noninteractive frontend, because the image has no
# dialog or readline frontend and would otherwise warn on every install.
# Recommended packages are skipped, which leaves out hardware, desktop, and
# cloud extras that don't apply to a container machine. The apt package lists
# are kept so the demo can `apt install` without an `apt update` first.
FROM ubuntu:26.10

ENV container container

RUN echo 'APT::Install-Recommends "false";' >/etc/apt/apt.conf.d/99no-recommends && \
    apt-get update && \
    apt-get install -y apt-utils sudo ubuntu-standard && \
    echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

RUN >/etc/machine-id

RUN systemctl set-default multi-user.target
RUN systemctl mask \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
      systemd-update-utmp.service \
      systemd-tmpfiles-setup.service \
      console-getty.service
