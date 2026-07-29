# ZeApp shell configuration
# Loaded by /etc/profile via profile.d mechanism

# Enable ash command history with arrow keys
export HISTFILE="$HOME/.ash_history"
export HISTSIZE=1000

# Point ENV to .ashrc so interactive ash picks up line-editing config
export ENV="$HOME/.ashrc"

# iSH guests cannot call sethostname(2), so keep the Ze product identity in
# the interactive shell prompt instead of relying on a kernel hostname that
# may have been persisted by an older rootfs image.
export PS1='root@ze:\w# '

# URL interception: $BROWSER is injected directly into the process envp
# by ISHShellExecutor.m / ISHKernel.m so it is visible even in non-login
# shells (which never source profile.d). The xdg-open / sensible-browser
# / www-browser / x-www-browser / gnome-open / kde-open wrappers live as
# real files in default_mount/usr/local/bin/ and are overlaid on every
# boot. Nothing to do here.
