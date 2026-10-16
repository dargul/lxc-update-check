# lxc-update-check

lxc-update-check.sh – checks all LXC containers of a Proxmox host for updates
and writes the result as an HTML report. VMs are not looked at.

Checked per container:
1. Apps installed via community-scripts (ProxmoxVE helper scripts):<br>
   - installed version against the project's latest release
3. Docker containers inside the LXC:<br>
   - running image against the current image in the registry (Docker Hub, ghcr.io, lscr.io, quay.io …)  
5. System packages (apt, apk, dnf, pacman)  

### Commands
```
./lxc-update-check.sh <option>
```
|options|description|
|---|---|
|[without option] |run a scan now |
|--install|once: set up cron job (schedule configurable) + web server|
|--refresh 104|re-check container 104 only|
|--snapshot 104 pre_update|snapshot of container 104, then re-check it|
|--uninstall|remove cron job + web server again|
|--help|list all options|

Apps that run neither via a community-script nor via Docker can be declared
with a small file inside the container:  
/etc/lxc-update-check.conf  
  name=Gitea  
  repo=go-gitea/gitea  
  version_cmd=gitea --version | awk '{print $3}'  
>instead of version_cmd a fixed version=1.2.3 works too; for a community-scripts app without /usr/bin/update the line script=<script name> is enough

Files after installation:  
   /etc/lxc-update-check/config         settings (port, language, exclusions …)  
   /etc/lxc-update-check/lang/*.lang    language files with all texts of the report  

In the report: "Check now" re-checks everything, the arrow button (↑) re-checks a
single container, "Settings" shows and changes the configuration (with the
password from /etc/lxc-update-check/web-password) and links to a help page.
The script installs no updates. The only change it can make is a snapshot that you
start yourself with the camera button (password required). Inside the containers a
scan merely refreshes the package lists (apt-get update etc.).
The help page lists the commands to snapshot and update a container by hand.
