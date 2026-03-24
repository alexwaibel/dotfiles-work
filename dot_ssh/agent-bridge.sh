# Bridge Windows SSH agent (Bitwarden) to WSL via npiperelay + socat
# Sourced from ~/.bashrc

export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"

_start_agent_bridge() {
  rm -f "$SSH_AUTH_SOCK"
  (setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork \
    EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork &) \
    >/dev/null 2>&1
}

# If socat isn't running, start it.
# If it is running but the agent is broken, kill and restart.
if ! pgrep -f "socat.*$SSH_AUTH_SOCK" >/dev/null 2>&1; then
  _start_agent_bridge
elif ! ssh-add -l >/dev/null 2>&1; then
  pkill -f "socat.*agent.sock"
  _start_agent_bridge
fi

unset -f _start_agent_bridge
