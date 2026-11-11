# Plugin session helpers

Set `session_helper` once in a plugin configuration to an executable path.
Relative paths are resolved against `$HOME`. The launcher starts the helper
asynchronously alongside the game when the plugin is active and the executable
exists.

The helper inherits the runner environment, with `WINELOADER` set to the original
Wine loader. It receives these arguments in order:

1. The launch script's PID.
2. The original Wine loader's absolute path.
3. The Wine prefix's absolute path.

Standard output and standard error go to the launch log. During cleanup, the
launcher sends SIGTERM and gives the helper up to five seconds to exit before
sending SIGKILL and reaping it.

The helper should stay in the foreground and manage any child processes it
starts. A child can keep the Wine session open after the game's foreground
windows close. For a Windows child process that should end with the Wine
session, launch it as a Wine background process.
