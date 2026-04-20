#!/bin/bash

if [ "$USER" = "root" ]; then
  echo "[${0##*/}] Error: This script must not be run as root."
  exit 1
fi

set -e

DISK_MOUNT_PATH="${DISK_MOUNT_PATH:-}"

if [[ -z "$DISK_MOUNT_PATH" ]]; then
  echo "[${0##*/}] Error: DISK_MOUNT_PATH is not set."
  exit 1
fi

DISK_VENV_PATH="${DISK_VENV_PATH:-$DISK_MOUNT_PATH/.venv/3.12/k8s}"

sudo chown -R "$USER" "$HOME"
sudo chown -R "$USER" "$DISK_MOUNT_PATH"
sudo chown -R root "$DISK_MOUNT_PATH/lost+found"

cd "$HOME"

# install common bin tools
command -v man >/dev/null 2>&1 || sudo apt install -y man
command -v less >/dev/null 2>&1 || sudo apt install -y less
command -v bc >/dev/null 2>&1 || sudo apt install -y bc
command -v ag >/dev/null 2>&1 || sudo apt install -y silversearcher-ag
command -v zsh >/dev/null 2>&1 || sudo apt install -y zsh

# install on-my-zsh if it doesn't exist
if [ ! -d ".oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

mkdir -p "$DISK_MOUNT_PATH/.home"

# save and restore *rc and *history in disk .home/, so they persist across different jobsets.
for item in .bashrc .bash_history .zshrc .zsh_history; do
    touch "$HOME/$item"
    if ! [ -f "$DISK_MOUNT_PATH/.home/$item" ]; then
        cp "$HOME/$item" "$DISK_MOUNT_PATH/.home/$item"
    fi
    # make item in $HOME a symlink, so changes are made to item on disk.
    for i in {1..3}; do
        ln -f -s "$DISK_MOUNT_PATH/.home/$item" "$HOME/$item"
        if [ -L "$HOME/$item" ]; then
            break
        fi
        echo "[${0##*/}] Warning: Failed to create symlink for $item (trial $i), retrying..."
        sleep 1
    done
    if [ ! -L "$HOME/$item" ]; then
        echo "[${0##*/}] Error: Failed to create symlink for $item, changes won't be saved"
    fi
done

mkdir -p "$DISK_MOUNT_PATH/.bin"

# install gcloud ($HOME/.bin) if it doesn't exist
export PATH=$PATH:$HOME/.bin/google-cloud-sdk/bin
if ! command -v gcloud >/dev/null 2>&1; then
    echo "Installing gcloud CLI..."
    curl https://sdk.cloud.google.com | sudo bash -s -- --disable-prompts --install-dir=$HOME/.bin | grep -v '^google-cloud-sdk/'
    sudo $(which gcloud) components install gke-gcloud-auth-plugin --quiet
    set +e
    for rc in .zshrc .bashrc; do
        if ! grep -q "google-cloud-sdk/bin" "$HOME/$rc"; then
            echo 'export PATH=$PATH:$HOME/.bin/google-cloud-sdk/bin' >> "$HOME/$rc"
            echo 'source $HOME/.bin/google-cloud-sdk/completion.zsh.inc' >> "$HOME/$rc"
        fi
    done
    set -e
else
    echo "gcloud already installed."
fi

# install kubectl if it doesn't exist
if ! command -v kubectl >/dev/null 2>&1; then
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
else
    echo "kubectl already installed."
fi

# install btop if it doesn't exist
if ! command -v btop >/dev/null 2>&1; then
    if [ ! -d "$DISK_MOUNT_PATH/.bin/btop" ]; then
        # for the latest version, see: https://github.com/aristocratos/btop/releases
        curl -L https://github.com/aristocratos/btop/releases/download/v1.4.6/btop-x86_64-unknown-linux-musl.tbz | tar -xj -C "$DISK_MOUNT_PATH/.bin"
    fi
    echo "Installing btop..."
    (cd "$DISK_MOUNT_PATH/.bin/btop" && sudo make install)
fi

# add some login commands
for rc in .bashrc .zshrc; do
    if ! grep -q "HF_HUB_DISABLE_XET" "$HOME/$rc"; then
        # disble XET for hf (cause download stuck)
        echo 'export HF_HUB_DISABLE_XET=1' >> "$HOME/$rc"
        # enter venv when login
        echo "source $DISK_VENV_PATH/bin/activate" >> "$HOME/$rc"
        # goto mount disk when login
        echo "cd $DISK_MOUNT_PATH" >> "$HOME/$rc"
    fi
    if ! grep -q ".local/bin" "$HOME/$rc"; then
        echo 'export PATH=$HOME/.local/bin:$PATH' >> "$HOME/$rc"
    fi
done
