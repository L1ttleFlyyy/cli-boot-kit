#!/usr/bin/env bash

IN_CN=
ping -c 1 -W 2 github.com || IN_CN="yes"
if [ -n "$IN_CN" ]; then
    echo "Detected CN network, applying workarounds"; sleep 1;
    curl -LO https://testingcf.jsdelivr.net/gh/ittuann/GitHub-IP-hosts@main/hosts
    cat hosts | sudo tee -a /etc/hosts
fi
ping -c 1 -W 2 github.com || (echo "can't connect to github" && exit 1)

set -e  # Exit on error
set -u  # Exit on undefined variable

pause_echo() { echo $*; sleep 1; }

FILENAME=$(basename $0)

if [ "$EUID" -eq 0 ]; then 
    NEW_USER=l1ttleflyyy
    if ! id $NEW_USER; then
        pause_echo "creating normal user $NEW_USER"
        useradd -m -s /bin/bash $NEW_USER
        usermod -aG sudo $NEW_USER
        # Allow passwordless sudo for this user
        echo "$NEW_USER ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$NEW_USER
        sudo chmod 440 /etc/sudoers.d/$NEW_USER
        id $NEW_USER
    fi
    cp "$0" "/home/$NEW_USER/$FILENAME"
    chown $NEW_USER:$NEW_USER "/home/$NEW_USER/$FILENAME"
    chmod +x "/home/$NEW_USER/$FILENAME"
    cd /home/$NEW_USER
    su - $NEW_USER -c "/home/$NEW_USER/$FILENAME"
    exit
fi

pause_echo "setting up ssh"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat << 'EOF' > ~/.ssh/authorized_keys
# Add SSH public keys here.
EOF

chmod 600 ~/.ssh/authorized_keys

pause_echo "change ssh config to port 60022"
sudo sed -i '/^[[:space:]]*[^#]*Port[[:space:]]\+22/s/^/#/' /etc/ssh/sshd_config
sudo tee /etc/ssh/sshd_config.d/10-myconfig.conf << 'EOF' > /dev/null
Port 60022
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 20

Protocol 2
X11Forwarding no
UsePAM yes
EOF

sudo sshd -t && echo "✅ SSH config valid" || (echo "❌ SSH config invalid"; exit 1)

sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
sudo ss -antup | grep "60022"

pause_echo "SSH server restarted"

pause_echo "change kernel config"
sudo tee /etc/sysctl.d/00-local.conf << 'EOF' > /dev/null
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.all.accept_ra=2
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
EOF
sudo sysctl --system
sudo sysctl net.ipv4.tcp_available_congestion_control

pause_echo "installing necesary packages"
sudo timedatectl set-timezone America/Los_Angeles
sudo apt update && sudo apt install -y git build-essential ufw fail2ban zsh

pause_echo "setup ufw"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default allow routed
sudo ufw allow 60022/tcp
sudo ufw --force enable
sudo ufw status verbose

pause_echo "setup fail2ban"

sudo tee /etc/fail2ban/jail.d/ssh.local << 'EOF' > /dev/null
[sshd]
enabled = true
filter = sshd[mode=aggressive]
backend = systemd
logpath = systemd-journal
maxretry = 3
banaction = ufw
bantime = 432000
findtime = 10800
ignoreip = 127.0.0.0/8 100.123.123.0/24 ::1
EOF

sudo systemctl enable fail2ban
sudo systemctl start fail2ban
sleep 2
sudo fail2ban-client status sshd

pause_echo "installing homebrew"
sudo apt update
sudo apt-get install -y build-essential procps curl file git
if [ -n "$IN_CN" ]; then
    export HOMEBREW_INSTALL_FROM_API=1
    export HOMEBREW_API_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"
    export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git"
    export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/homebrew-core.git"
    git clone --depth=1 https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/install.git brew-install
    NONINTERACTIVE=1 /bin/bash brew-install/install.sh
    rm -rf brew-install
    git -C "/home/linuxbrew/.linuxbrew/Homebrew" remote set-url origin https://mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git
else
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
brew doctor

pause_echo "install necesary packages"
brew install neovim tmux chezmoi fzf ripgrep fd eza eget tmux-mem-cpu-load fastfetch tlrc

pause_echo "set up env via chezmoi"
chezmoi init l1ttleflyyy --apply

pause_echo "default to zsh"
command -v zsh | sudo tee -a /etc/shells
sudo chsh -s "$(command -v zsh)" "${USER}"

setup_tailscale(){
pause_echo "installing tailscale"
curl -fsSL https://tailscale.com/install.sh | sh

pause_echo "config udp offloading for tailscale"
sudo apt install -y ethtool

sudo tee /etc/systemd/system/tailscale-network-optimize.service << 'EOF' > /dev/null
[Unit]
Description=Tailscale Network Optimization
After=networking.service
Wants=networking.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/usr/sbin/ethtool -K $(/usr/sbin/ip -o route get 8.8.8.8 | cut -f 5 -d " ") rx-udp-gro-forwarding on rx-gro-list off'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-network-optimize
sudo systemctl status --no-pager tailscale-network-optimize
}

if [ -z "$IN_CN" ]; then
    setup_tailscale;
fi

pause_echo "Upgrading system..."
sudo apt update && sudo apt upgrade -y
tput bel && sleep 1 && tput bel
