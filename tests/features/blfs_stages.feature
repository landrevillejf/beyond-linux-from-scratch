Feature: BLFS Build Stages
  Scenarios for the new BLFS stages: blfs-libs, xorg, wayland,
  display-manager, desktop dispatcher, and init system dispatching.

  # ── BLFS core libraries stage ──────────────────────────────────────────

  Scenario: BLFS libs stage is included when a desktop is requested
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "xfce" and init "systemd"
    Then the build should succeed
    And the build stages should include "blfs-libs"
    And the build stages should include "xorg"
    And the build stages should include "wayland"
    And the build stages should include "display-manager"

  Scenario: BLFS libs stage is excluded when desktop is none
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "minimal" and init "sysvinit"
    Then the build should succeed
    And the build stages should not include "blfs-libs"
    And the build stages should not include "xorg"
    And the build stages should not include "wayland"
    And the build stages should not include "display-manager"

  # ── Desktop dispatcher ─────────────────────────────────────────────────

  Scenario: GNOME desktop stage is included for gnome profile
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "gnome"
    Then the build should succeed
    And the build stages should include "desktop"
    And the build stages should include "configure-desktop"

  Scenario: KDE desktop stage is included for kde profile
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "kde"
    Then the build should succeed
    And the build stages should include "desktop"

  Scenario: LXQt desktop stage is included for lxqt profile
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "lxqt"
    Then the build should succeed
    And the build stages should include "desktop"

  # ── Init system dispatching ───────────────────────────────────────────

  Scenario: systemd init system is used for xfce profile
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "xfce"
    Then the build should succeed
    And the build stages should include "init-system"
    And the environment variable "INIT_SYSTEM" should be "systemd"

  Scenario: sysvinit init system is used for minimal profile
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "minimal" and init "sysvinit"
    Then the build should succeed
    And the environment variable "INIT_SYSTEM" should be "sysvinit"

  Scenario: openrc init system is accepted
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "xfce" and init "openrc"
    Then the build should succeed
    And the environment variable "INIT_SYSTEM" should be "openrc"

  Scenario: runit init system is accepted
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "xfce" and init "runit"
    Then the build should succeed
    And the environment variable "INIT_SYSTEM" should be "runit"

  Scenario: s6 init system is accepted
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "xfce" and init "s6"
    Then the build should succeed
    And the environment variable "INIT_SYSTEM" should be "s6"

  # ── Phosh / ARM profiles ──────────────────────────────────────────────

  Scenario: brax3 profile has phosh desktop
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "brax3"
    Then the build should succeed
    And the build stages should include "blfs-libs"
    And the build stages should include "desktop"
