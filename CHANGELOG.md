# Change Log

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com), and this project adheres to [Semantic Versioning](https://semver.org)

## [1.1.0] - 08-08-2024

- From version `1.1.0` its possible to create a user account without assigning a department/school.
- Moved the department assignment to the _update_ lifecycle action.
- Added `if ($actionContext.AccountCorrelated)` statement, to trigger the _update_ lifecycle action directly after correlation.
    > [!NOTE]
    > Only the departmentOfBranch will be updated after initial correlation.
- Added `participationWeight` field to the fieldMapping with a default value of `1.00`.
- Removed fieldMapping attribute `code` from both the _update_ and _delete_ lifecycle actions. The `$actionContext.References.Account` is used instead.
- Because the _personDifferences_ are used to verify if the department must be updated, two additional configuration settings  `SchoolNameField` and `ClassroomField` have been added.

## [1.0.1] - 28-06-2024

- Updated the lifecycle actions.
- Added the `participationWeight` attribute within the JSON payload when adding a _departmentOfBranch_.

## [1.0.0] - 11-03-2024

This is the first official release of _HelloID-Conn-Prov-Target-Zermelo_. This release is based on template version _1.0.1_.
