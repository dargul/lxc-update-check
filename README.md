# lxc-update-check

[![Latest Release](https://img.shields.io/github/v/release/dargul/lxc-update-check)](https://github.com/dargul/lxc-update-check/releases/latest)

lxc-update-check.sh – checks all LXC containers of a proxmox host for updates
and writes the result as an HTML report. VMs are not looked at.

Checked per container:
1. Apps installed via community-scripts (ProxmoxVE helper scripts):<br>
   - installed version against the project's latest release
3. Docker containers inside the LXC:<br>
   - running image against the current image in the registry (Docker Hub, ghcr.io, lscr.io, quay.io …)  
5. System packages (apt, apk, dnf, pacman)  

![Screenshot of the report main page.](/resources/lxc-update-check-main.png)

<br>

## Installation
1. Put the script lxc-update-check.sh __on your proxmox host__
2. Make it executable
```
chmod +x lxc-update-check.sh
```
3. Initial installation of the web server, HTML pages and cron job
```
./lxc-update-check.sh --install
```
<br>

## Commands
```
./lxc-update-check.sh <option>
```
|options|description|
|---|---|
|[without option] |run a scan now |
|--install|once: set up cron job (schedule configurable) + web server|
|--refresh <LXC_ID>|re-check container <LXC_ID> only|
|--snapshot <LXC_ID> pre_update|snapshot of container <LXC_ID>, then re-check it|
|--uninstall|remove cron job + web server again|
|--help|list all options|

<br>

## Configuration
Apps that run neither via a community-script nor via Docker can be declared
with a small file **inside the container**:  
```
   /etc/lxc-update-check.conf  
      name=Gitea  
      repo=go-gitea/gitea  
      version_cmd=gitea --version | awk '{print $3}'  
```  
>[!NOTE]
>Instead of version_cmd a fixed version=1.2.3 works too; for a community-scripts app without /usr/bin/update the line script=<script name> is enough
<br>

|Files after installation| |
|:---|:---|
|/etc/lxc-update-check/config|settings (port, language, exclusions …)|
|/etc/lxc-update-check/lang/*.lang|language files with all texts of the report|
|/var/www/lxc-updates/|HTML report site and assets|

<br>

## How to use
In your browser: __<pve_ip>:8090__  

Report page:
|Button|Description|
|:---|:---|
|![Ceck Now](/resources/check_now.png)|Re-checks everything  |
|![Settings](/resources/settings.png)|Shows and changes the configuration (with the password from /etc/lxc-update-check/web-password) and links to a help page.  |
|![Show Packages](/resources/show_packages.png)|Shows all system packages with updates  |
|![the arrow button (↑)](/resources/update.png)|Re-checks a single container  |
|![Snapshot](/resources/snapshot.png)|Creates a snapshot if supported by filesystem  |
|![List Snapshots](/resources/list_snapshots.png)<&nbsp;>![List Snapshots Badge](/resources/list_snapshots_badge.png)|List existing snapshots on container (badge shows number of snapshots available)  |
|![Info](/resources/info.png)|Info on how to maintain snapshots  |

<br>

>[!NOTE]
>The script installs no updates. The only change it can make is a snapshot that you start yourself with the camera button (password required). Inside the containers a scan merely refreshes the package lists (apt-get update etc.). The help page lists the commands to snapshot and update a container by hand.
