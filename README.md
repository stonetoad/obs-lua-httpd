# obs-lua-httpd

A very minimal webserver as an OBS plugin in Lua.

Specifically we provide cross-origin isolation headers to
enable SharedArrayBuffer use. This is required for Godot web projects to run.

This is fairly feature complete for my own use currently, but pull requests and bug reports are welcome.
