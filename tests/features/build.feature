Feature: LFS Build

  Scenario: Build minimal profile with sysvinit
    Given a configuration file "config/build.conf" with default settings
    And a temporary output directory
    When I run the builder with profile "minimal" and init "sysvinit"
    Then the build should succeed
    And an ISO file named "lfs-installer.iso" should be created
    And the build info file should contain the profile "minimal"

  Scenario: Build with custom profile and no live system
    Given a configuration file "config/build.conf" with default settings
    And I override the live system to disabled
    When I run the builder with profile "server"
    Then the build should succeed
    And the ISO file should exist
    And the logs should show "Live system disabled"