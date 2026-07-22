# Bridge Windows SSH agent (Bitwarden) to WSL via npiperelay + socat
# Sourced from ~/.bashrc

# Socket lives outside ~/.ssh so the Copilot CLI sandbox (which denies ~/.ssh to
# keep key material out of reach) can still connect to the bridged agent. The
# socket only relays signing requests to the Windows Bitwarden agent — no private
# key ever traverses it — so exposing ~/.ssh-agent to the sandbox is safe.
export SSH_AUTH_SOCK="$HOME/.ssh-agent/agent.sock"

_start_agent_bridge() {
  mkdir -p "$HOME/.ssh-agent"
  rm -f "$SSH_AUTH_SOCK"
  (setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork \
    EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork &) \
    >/dev/null 2>&1
}

# If socat isn't running, start it.
# If it is running but the agent is broken, kill and restart.
# Timeout prevents blocking when the Windows SSH agent pipe is unresponsive.
if ! pgrep -f "socat.*$SSH_AUTH_SOCK" >/dev/null 2>&1; then
  _start_agent_bridge
elif ! timeout 2 ssh-add -l >/dev/null 2>&1; then
  pkill -f "socat.*agent.sock"
  _start_agent_bridge
  if ! timeout 2 ssh-add -l >/dev/null 2>&1; then
    echo -e "\033[33m⚠ SSH agent unreachable — is Bitwarden running on Windows?\033[0m" >&2
  fi
fi

unset -f _start_agent_bridge
