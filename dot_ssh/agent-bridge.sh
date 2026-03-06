# Bridge Windows SSH agent (Bitwarden) to WSL via npiperelay + socat
# Sourced from ~/.bashrc

export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"

if ! pgrep -f "socat.*$SSH_AUTH_SOCK" >/dev/null 2>&1; then
  rm -f "$SSH_AUTH_SOCK"
  (setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork \
    EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork &) \
    >/dev/null 2>&1
fi
