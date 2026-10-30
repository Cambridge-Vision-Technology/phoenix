Feature: Native Phoenix package
  Scenario: Start the native Phoenix package offline
    Then the built native package serves health, UI, a manifest asset and projects in isolated TEST state and stops cleanly
