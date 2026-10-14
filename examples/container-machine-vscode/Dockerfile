FROM swift:6.3.2-noble

# Install system dependencies for Swift + OpenSSH + systemd + containerization
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl ca-certificates git sudo systemd systemd-sysv openssh-server \
      binutils gpg vim libc6-dev libcurl4-openssl-dev libedit2 libgcc-s1 \
      unzip gnupg2 libgcc-13-dev libstdc++-13-dev libncurses-dev \
      libpython3-dev libsqlite3-0 libstdc++6 libxml2-dev libz3-dev \
      pkg-config tzdata zlib1g-dev \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Passwordless sudo for all users
RUN echo 'ALL ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/nopasswd \
 && chmod 0440 /etc/sudoers.d/nopasswd

# Configure OpenSSH for local-only use:
#   - Both password and public key auth enabled (no brute-force risk on loopback)
#   - UseDNS no             — skip reverse DNS lookup, avoids multi-second connect delay
#   - GSSAPIAuthentication no — skip GSSAPI negotiation, faster handshake
RUN mkdir -p /var/run/sshd \
 && ssh-keygen -A \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'                    /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/'     /etc/ssh/sshd_config \
 && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'         /etc/ssh/sshd_config \
 && echo 'UseDNS no'               >> /etc/ssh/sshd_config \
 && echo 'GSSAPIAuthentication no' >> /etc/ssh/sshd_config \
 && systemctl enable ssh

RUN systemctl mask getty@.service systemd-logind.service \
      apt-daily.timer apt-daily-upgrade.timer fstrim.timer || true

EXPOSE 22
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
