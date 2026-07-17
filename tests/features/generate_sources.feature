Feature: Generate sources list

  Scenario: Running --generate-sources-list creates sources.list
    Given a temporary directory
    And a mock sources list from the internet
    When I run the builder with --generate-sources-list
    Then the file packages/sources.list should exist
    And it should contain URLs from the mock sources