Omarchy plugins are simply cloned via git behind the scenes (with `omarchy plugin add`). There are no post-install hooks that run automatically during installation, intentionally so, to prevent plugins from running arbitrary root commands without explicit user consent.

More importantly, attempting to run `install.sh` automatically via the UI (using `pkexec`) would re-introduce the exact same security vulnerability we just fixed! Here is why:

To run `install.sh` automatically, we would need to call `pkexec ~/.config/.../install.sh`. But `install.sh` is inside the user-writable plugin folder. If we trigger a GUI password prompt for it, a malicious background app could swap out `install.sh` with a virus *while* the password prompt is on the screen. The user types their password, and the virus is executed as root.

This is why the security review required us to use a root-owned path with a strict PolKit policy. The **only** secure way to bootstrap this root environment is for the user to manually type `sudo extras/install.sh` in their own trusted terminal.

This is standard practice for Linux desktop applets that require root (like advanced power managers or VPN managers). 
