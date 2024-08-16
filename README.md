
# HelloID-Conn-Prov-Target-Zermelo

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<br />
<p align="center">
  <img src="https://www.tools4ever.nl/connector-logos/zermelo-logo.png" width="500">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-Zermelo](#helloid-conn-prov-target-zermelo)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [API Documentation](#api-documentation)
  - [Getting started](#getting-started)
    - [Provisioning PowerShell V2 connector](#provisioning-powershell-v2-connector)
      - [Correlation configuration](#correlation-configuration)
      - [Field mapping](#field-mapping)
    - [Configuration settings](#configuration-settings)
    - [Remarks](#remarks)
      - [Important changes in version `1.1.0`](#important-changes-in-version-110)
        - [Create a user (and student) account without assigning a department/school](#create-a-user-and-student-account-without-assigning-a-departmentschool)
        - [School or classroom changes](#school-or-classroom-changes)
      - [Creating user and student accounts](#creating-user-and-student-accounts)
      - [Only the user account is managed](#only-the-user-account-is-managed)
      - [Dynamic calculation of school year](#dynamic-calculation-of-school-year)
      - [Setting classroom information](#setting-classroom-information)
      - [Delete user](#delete-user)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-Zermelo_ is a _Target_ connector. Zermelo is an LMS and provides a set of REST API's that allow you to programmatically interact with its data. The HelloID connector uses the API endpoints listed in the table below.

| Endpoint              | Description                                                          |
| --------------------- | -------------------------------------------------------------------- |
| /users                | Create and manage user and student accounts                          |
| /departmentOfBranches | Retrieve information about the classroom and school year information |
| /studentInDepartments | Manage student `departmentOfBranch` information                      |

## API Documentation

The API documentation can be found on: https://support.zermelo.nl/guides/developers-api/examples/synchronizing-students#synchronizing-students_creating-students
A swagger interface can be found on: https://{customer}.zportal.nl/static/swagger

## Getting started

> [!IMPORTANT]
> The initial release of our connector, `version 1.0.0`, is built upon several fundamental assumptions. Make sure to verify if these assumptions apply to your environment and make changes accordingly __See also:__ [Underlying assumptions](#underlying-assumptions)

The following lifecycle actions are available:

| Action             | Description                          |
| ------------------ | ------------------------------------ |
| create.ps1         | PowerShell _create_ lifecycle action |
| delete.ps1         | PowerShell _delete_ lifecycle action |
| update.ps1         | PowerShell _update_ lifecycle action |
| configuration.json | -                                    |
| fieldMapping.json  | -                                    |

### Provisioning PowerShell V2 connector

#### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _Zermelo_ to a person in _HelloID_.

To properly setup the correlation:

1. Open the `Correlation` tab.

2. Specify the following configuration:

    | Setting                   | Value                             |
    | ------------------------- | --------------------------------- |
    | Enable correlation        | `True`                            |
    | Person correlation field  | `PersonContext.Person.ExternalId` |
    | Account correlation field | `code`                            |

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

#### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.

### Configuration settings

The following settings are required in order to use this connector:

| Setting         | Description                                                                   | Mandatory | Default value            |
| --------------- | ----------------------------------------------------------------------------- | --------- | ------------------------ |
| Token           | The ApiToken to authorize against the Zermelo API                             | Yes       | -                        |
| BaseUrl         | The URL of the Zermelo environment                                            | Yes       | -                        |
| SchoolNameField | Mapping field name for the school or organization from the primary contract.  | Yes       | "Organization.Name"      |
| ClassroomField  | Mapping field name for the classroom or department from the primary contract. | Yes       | "Department.DisplayName" |

### Remarks

#### Important changes in version `1.1.0`

##### Create a user (and student) account without assigning a department/school

From version `1.1.0` its possible to create a user (and student) account without assigning a department/school. This means that; if a person within HelloID does not have a school / classRoom available, its still possible to create a Zermelo account.

To accommodate this change the following changes have been made:

- The department assignment has been moved to the _update_ lifecycle action.
- A conditional `if ($actionContext.AccountCorrelated)` statement is added to the _update_ lifecycle action that will execute directly after correlation.
  - Note that this will __only__ assign the department and will not update the user account.
- The `participationWeight` field is added to the fieldMapping with a default value of `1.00`. This field is used within the JSON payload to update -or assign- a 'departmentOfBranch'.

##### School or classroom changes

Starting from version `1.1.0`, we've introduced additional logic to ensure that if either the school or classroom changes, the 'departmentOfBranch' will be updated accordingly. See also: [Setting classroom information](#setting-classroom-information)

To accommodate this change the following changes have been made:

- To update the school or classroom, a comparison is made using `$personContext.PersonDifferences.PrimaryContract`.
- The fields used for comparison are configurable via the [configuration](#configuration-settings). Ensure these fields align with the fieldMapping.

#### Creating user and student accounts

According to the official documentation of the Zermelo API, the procedure for creating a user account and a student account consists of two separate steps. Initially, the user account is created using the `/users` endpoint. Subsequently, the student account is created using the `/students` endpoint. However, contrary to the information provided in the official documentation, the process appears to be slightly different, and it seems that, creating a user account through the `/users` endpoint, while including the attribute `isStudent = true`, is sufficient to create a student account.

> [!IMPORTANT]
> For the initial `1.0.0` release of the connector, we based our implementation on the assumption that, creating a user while including the attribute `isStudent = true`, is sufficient to create a student account.

#### Only the user account is managed

In the `create` lifecycle action, we have made the assumption that we only need to handle the correlation of the user account. This is because, by creating the user account with the attribute `isStudent = true`, we are able to -simultaneously- create the student account.

> [!IMPORTANT]
> Modifications to attributes associated with the student account should be made by updating the corresponding attributes in the user account. This means that, from the perspective of HelloID, only the user account is managed and considered the __primary entity__.

#### Dynamic calculation of school year

The schoolYear is calculated dynamically based on the `StartDate` of the primary contract.

This means that; if a student commences on the: `1st of March 2023`, and the `PrimaryContract.StartDate` is set to the: `1st of March 2023`, the current school year should be: `2022-2023`.

> [!NOTE]
> Prior to the end of July, the ongoing school year is identified as `2022/2023`. Starting from the 1st of August, the current school year transitions to `2023/2024`

This mechanism ensures that the SchoolYear property accurately reflects the academic period during which the student accounts are created.

Translated to PowerShell, this will appear as follows:

```powershell
function Get-CurrentSchoolYear {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [DateTime]
        $StartDate
    )

    $currentDate = Get-Date
    $year = $currentDate.Year

    # Determine the start and end dates of the current school year
    if ($currentDate.Month -lt 8) {
        $startYear = $year - 1
        $endYear = $year
    } else {
        $startYear = $year
        $endYear = $year + 1
    }

    Write-Output "$startYear-$endYear"
}
```

#### Setting classroom information

Our initial `1.0.0` release of the connector is based on the following assumptions:

- The `PrimaryContract.Department.DisplayName` corresponds to the assigned classroom for the student.
- The `PrimaryContract.Organization.Name` corresponds to the name of the school.
- The `PrimaryContract.StartDate` represents the date when the school year is scheduled to commence.

> [!IMPORTANT]
> In the Netherlands, the date when the school year is scheduled to commence typically is on the 1st of August of the current year.

We have learned that, by creating the user account with the attribute `isStudent = true`, we are able to -simultaneously- create the student account. See also: [Creating user and student accounts](#creating-user-and-student-accounts)

Subsequently, a student account can be assigned a `studentInDepartments` entity, which contains information about the classroom and, by extension, the school and school year. This assignment can only be achieved by performing a lookup and matching equivalent data.

The following data is available to us in HelloID:

| Name                                   | Description    | Where to find in Zermelo                            | Value              |
| -------------------------------------- | -------------- | --------------------------------------------------- | ------------------ |
| Person.ExternalId                      | Student number | __/Student__<br>userCode                            | <br>0000001        |
| PrimaryContract.Department.DisplayName | Classroom      | __/StudentInDepartment__<br> departmentOfBranchCode | <br>e2             |
| PrimaryContract.StartDate              | School year    | __/DepartmentOfBranch__<br>schoolInSchoolYearName   | <br>Tavu 2023-2024 |
| PrimaryContract.Organization.Name      | School name    | __/SchoolInYear__<br> schoolName                    | <br>Tavu           |

To assign the `studentInDepartment` entity, the following data is required:

| Attribute           | Description                                                                                                                         |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| student             | The unique identifier of the student                                                                                                |
| departmentOfBranch  | The unique identifier of a `DepartmentOfBranch` entity                                                                              |
| participationWeight | The portion of a student's grade based on their class involvement. This value must be a decimal and has a default value of: `1.00`. |

To obtain the `departmentOfBranch` information, it is necessary to perform a lookup in the `departmentOfBranch` endpoint. The matching criteria involve making the following comparisons:

- `departmentOfBranchCode` with the `PrimaryContract.Department.DisplayName`
- `schoolInSchoolYearName` with the `PrimaryContract.StartDate` and `PrimaryContract.Organization.Name`

For a visual representation of the relationships between the different entities, refer to the UML diagram below:

![um](./assets/uml.png)

#### Delete user

Currently the `delete` lifecycle action is set to _archive_ the user account using a `PUT` method.

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

> [!TIP]
>  _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com/forum/helloid-connectors/provisioning/4793-helloid-conn-prov-target-zermelo)_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/

