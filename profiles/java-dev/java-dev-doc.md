# Java Development Profile (`java-dev`)

The `java-dev` profile transforms a minimal LFS/BLFS system into a full‑fledged Java development workstation.  
It installs the Eclipse Temurin JDK, build tools (Maven, Gradle), application servers (Tomcat, Jenkins), container runtime (Docker), orchestration CLI (kubectl), Spring Boot CLI, and Node.js for front‑end work.  
Everything is installed under `/opt`, with environment variables and service management configured automatically.

## What’s included

| Component         | Version   | Location                 | Service |
|-------------------|-----------|--------------------------|---------|
| OpenJDK (Temurin) | 21.0.8    | `/opt/jdk-21.0.8`        | –       |
| Maven             | 3.9.9     | `/opt/maven`             | –       |
| Gradle            | 8.13      | `/opt/gradle`            | –       |
| Apache Tomcat     | 10.1.39   | `/opt/tomcat`            | tomcat  |
| Node.js           | 22.14.0   | `/opt/node`              | –       |
| Docker (static)   | 27.4.1    | `/usr/local/bin/docker`  | docker  |
| kubectl           | 1.32.3    | `/usr/local/bin/kubectl` | –       |
| Jenkins           | 2.492.2   | `/opt/jenkins`           | jenkins |
| Spring Boot CLI   | 3.2.0     | `/opt/spring-boot-cli`   | –       |

Additionally, global npm packages (yarn, pnpm, TypeScript, pm2, etc.) are installed.

## Prerequisites

- A working LFS or BLFS 13.0 installation with basic networking.
- The system must be **root** (the script will refuse to run otherwise).
- Required host tools: `wget`, `tar`, `unzip`. The script will attempt to install them automatically if missing, using the detected package manager (`apt`, `dnf`, `pacman`, etc.).
- At least **6 GB** of free disk space in `/opt` and `/sources`.

## Quick start

1. Ensure you are in the LFS chroot environment or on the host where the target root filesystem is mounted.
2. Download or copy the `12-install-java-dev.sh` script to the target system.
3. Run as root:
   ```bash
   sudo bash 12-install-java-dev.sh
   ```
4. Once finished, log out and back in (or `source /etc/profile.d/*.sh`) to activate the new environment variables.

## Environment configuration

All environment variables are placed in `/etc/profile.d/` and are automatically sourced on login:

- `/etc/profile.d/java.sh` – `JAVA_HOME`, `PATH`
- `/etc/profile.d/maven.sh` – `MAVEN_HOME`, `PATH`
- `/etc/profile.d/gradle.sh` – `GRADLE_HOME`, `PATH`
- `/etc/profile.d/node.sh` – `NODE_HOME`, `PATH`
- `/etc/profile.d/spring.sh` – `SPRING_HOME`, `PATH`
- `/etc/profile.d/java-dev.sh` – JVM options (`JAVA_OPTS`, `MAVEN_OPTS`, `GRADLE_OPTS`) and handy aliases/functions.

For the default user `lfsuser`, the aliases and functions are also copied to `~/.java-dev-aliases.sh` and sourced from `~/.bashrc`.

## Services

The script detects the active init system (`systemd` or `sysvinit`) and installs appropriate service units:

- **Tomcat** – runs on port `8080`
- **Docker** – the daemon is configured but **not started** by default
- **Jenkins** – runs on port `8080` (change the port in `/etc/systemd/system/jenkins.service` if it conflicts with Tomcat)

Start/stop with:
```bash
# systemd
systemctl start tomcat
systemctl start docker
systemctl start jenkins

# sysvinit
/etc/init.d/tomcat start
/etc/init.d/docker start
/etc/init.d/jenkins start
```

## Customisation

All versions can be overridden by setting environment variables **before** running the script:

```bash
JAVA_VERSION=21.0.9 MAVEN_VERSION=3.9.9 bash 12-install-java-dev.sh
```

See the top of the script for the full list (`JAVA_VERSION`, `MAVEN_VERSION`, `GRADLE_VERSION`, `TOMCAT_VERSION`, `NODE_VERSION`, `DOCKER_VERSION`, `JENKINS_VERSION`, `KUBECTL_VERSION`, `SPRING_BOOT_VERSION`).

## Aliases and helper functions

After installation, the following aliases are available globally:

| Alias / Function    | Description |
|---------------------|-------------|
| `mci`, `mcp`, `mct` | Maven clean install / package / test |
| `gb`, `gt`          | Gradle build / test |
| `k`                 | kubectl |
| `d`                 | docker |
| `new-maven-project <name>` | Create a quickstart Maven project |
| `new-spring-project <name>` | Create a Spring Boot web project |
| `java-run <class>`  | Compile and run a single Java file |
| `dev-status`        | Show installed Java/dev versions |

## Disk usage

After installation, `/opt` will consume approximately 1.5–2 GB, and `/sources` contains downloaded archives (cleaned up automatically after a successful run). You can safely remove the contents of `/sources` once installation is complete.

## Upgrading

To upgrade a component, re‑run the script with the new version number:

```bash
TOMCAT_VERSION=10.1.40 bash 12-install-java-dev.sh
```

Existing configuration files in `/etc/profile.d/` and service units will be overwritten, but previous installations under `/opt` remain (you may manually remove old version directories).

## Troubleshooting

- **Download errors**: The script retries downloads three times. If it still fails, check your internet connection or the URL (versions may have been updated). You can manually download the file and place it in `/sources`.
- **Service not starting**: Check logs with `journalctl -u <service>` (systemd) or the script’s output. Ensure the required user (`tomcat`, `jenkins`) exists and the `/opt` permissions are correct.
- **Command not found**: Log out and back in, or run `source /etc/profile.d/java.sh` (and the other profile files) to update your shell’s environment.

## Integration with LFS/BLFS Builder

The `java-dev` profile is part of the LFS/BLFS Builder profiles. In `builder.py`, selecting `--profile java-dev` runs this script automatically during the `12-install-java-dev.sh` stage, after the base system and desktop are installed. All environment variables are also exported by the builder, so the JVM optimizations are applied to the build process itself.

---

For more details, see the full LFS/BLFS Builder documentation.