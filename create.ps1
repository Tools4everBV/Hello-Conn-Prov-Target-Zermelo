#########################################
# HelloID-Conn-Prov-Target-Zermelo-Create
#
# Version: 1.0.0
#########################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# User account mapping
$account = [PSCustomObject]@{
    code      = $p.ExternalId
    isStudent = $true
    firstName = $p.Name.GivenName
    prefix    = $p.Name.FamilyNamePrefix
    lastName  = $p.Name.FamilyName
    email     = $p.Contact.Business.Email
}

$updateAccount = [PSCustomObject]@{
    code      = $p.ExternalId
    isStudent = $true
}

# Department / schoolyear mapping
# These values are used in the `Get-DepartmentToAssignFromPrimaryContract` function to calculate the correct department
$department = $p.PrimaryContract.Department.DisplayName
$school     = $p.PrimaryContract.Organization.Name
$startDate  = [DateTime]$p.PrimaryContract.StartDate

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

# By default, we assume that both the user and student account are not present
$isUserAccountCreated = $false
$IsStudentAccountCreated = $false

#region functions
function Get-ZermeloAccount {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $Code,

        [Parameter(Mandatory)]
        [string]
        $Type
    )

    $splatParams = @{
        Method = 'GET'
    }

    switch ($Type){
        'users'{
            $splatParams['Endpoint'] = "users/$Code"
            (Invoke-ZermeloRestMethod @splatParams).response.data
        }

        'students'{
            $splatParams['Endpoint'] = "students/$Code"
            (Invoke-ZermeloRestMethod @splatParams).response.data
        }
    }
}

function Get-DepartmentToAssignFromPrimaryContract {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $SchoolName,

        [Parameter(Mandatory)]
        [string]
        $DepartmentName,

        [Parameter(Mandatory)]
        [DateTime]
        $ContractStartDate
    )

    try {
        $splatParams = @{
            Method   = 'GET'
            Endpoint = 'departmentsofbranches'
        }
        $responseDepartments = (Invoke-ZermeloRestMethod @splatParams).response.data
        [DateTime]$currentSchoolYear = Get-CurrentSchoolYear -ContractStartDate $ContractStartDate

        if ($null -ne $responseDepartments) {
            $contractStartDate = $currentSchoolYear
            $schoolNameToMatch = $SchoolName
            $schoolYearToMatch = "$($contractStartDate.Year)" +'-'+ "$($contractStartDate.AddYears(1).Year)"

            $lookup = $responseDepartments | Group-Object -AsHashTable -Property 'code'
            $departments = $lookup[$DepartmentName]
            $departmentToAssign = $departments | Where-Object {$_.schoolInSchoolYearName -match "$schoolNameToMatch $schoolYearToMatch"}
            Write-Output $departmentToAssign
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-CurrentSchoolYear {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [DateTime]
        $ContractStartDate
    )

    $currentDate = Get-Date
    $year = $currentDate.Year

    # Determine the start and end dates of the current school year
    if ($currentDate.Month -lt 8) {
        $startYear = $year - 1
    } else {
        $startYear = $year
    }

    $schoolYearStartDate = (Get-Date -Year $startYear)

    Write-Output $schoolYearStartDate
}

function Resolve-ZermeloError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorRecord
    )
    process {
        $errorObject = [PSCustomObject]@{
            ScriptLineNumber = $ErrorRecord.InvocationInfo.ScriptLineNumber
            Line             = $ErrorRecord.InvocationInfo.Line
            ErrorDetails     = $ErrorRecord.Exception.Message
            FriendlyMessage  = $ErrorRecord.Exception.Message
        }

        try {
            if ($ErrorRecord.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') {
                $rawErrorObject = ($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json).response
                $errorObject.ErrorDetails = "Code: [$($rawErrorObject.status)], Message: [$($rawErrorObject.message)], Details: [$($rawErrorObject.details)], EventId: [$($rawErrorObject.eventId)]"
                $errorObject.FriendlyMessage = $rawErrorObject.message
            } elseif ($ErrorRecord.Exception.GetType().FullName -eq 'System.Net.WebException') {
                if ($ErrorRecord.Exception.InnerException.Message){
                    $errorObject.FriendlyMessage = $($ErrorRecord.Exception.InnerException.Message)
                } else {
                    $streamReaderResponse = [System.IO.StreamReader]::new($ErrorRecord.Exception.Response.GetResponseStream()).ReadToEnd()
                    if (-not[string]::IsNullOrEmpty($streamReaderResponse)){
                        $rawErrorObject = ($streamReaderResponse | ConvertFrom-Json).response
                        $errorObject.ErrorDetails = "Code: [$($rawErrorObject.status)], Message: [$($rawErrorObject.message)], Details: [$($rawErrorObject.details)], EventId: [$($rawErrorObject.eventId)]"
                        $errorObject.FriendlyMessage = $rawErrorObject.message
                    }
                }
            } elseif ($ErrorRecord.Exception.GetType().FullName -eq 'System.Net.Http.HttpRequestException') {
                $errorObject.FriendlyMessage = $($ErrorRecord.Exception.Message)
            } else {
                $errorObject.FriendlyMessage = $($ErrorRecord.Exception.Message)
            }
        } catch {
            $errorObject.FriendlyMessage = "Received an unexpected response, error: $($ErrorRecord.Exception.Message)"
        }

        Write-Output $errorObject
    }
}

function Invoke-ZermeloRestMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Endpoint,

        [object]
        $Body,

        [string]
        $ContentType = 'application/json'
    )

    process {
        $baseUrl = "$($config.BaseUrl)/api/v3"
        try {
            $headers = [System.Collections.Generic.Dictionary[[String],[String]]]::new()
            $headers.Add('Authorization', "Bearer $($config.Token)")

            $splatParams = @{
                Uri         = "$baseUrl/$Endpoint"
                Headers     = $Headers
                Method      = $Method
                ContentType = $ContentType
            }

            if ($Body){
                Write-Verbose 'Adding body to request'
                $splatParams['Body'] = $Body
            }
            Invoke-RestMethod @splatParams -Verbose:$false
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}
#endregion

try {
    # Verify if the [account.code] has a value
    if ([string]::IsNullOrEmpty($($account.code))) {
        throw 'Mandatory attribute [account.code] is empty. Please make sure it is correctly mapped'
    }

    if ([string]::IsNullOrEmpty($department)) {
        throw 'Mandatory property [$department] to define the department is empty. Verify your script mapping.'
    }

    # Validate the user account
    try {
        $responseUser = Get-ZermeloAccount -Code $account.code -Type 'users'
        if ($null -ne $responseUser) {
            $isUserAccountCreated = $true
        }
    } catch {
        if ($_.Exception.Response.StatusCode -eq 'NotFound') {
            $isUserAccountCreated = $false
        } else {
            throw
        }
    }

    # Validate the student account
    try {
        $responseStudent = Get-ZermeloAccount -Code $account.code -Type 'students'
        if ($null -ne $responseStudent) {
            $isStudentAccountCreated = $true
        }
    } catch {
        if ($_.Exception.Response.StatusCode -eq 'NotFound') {
            $IsStudentAccountCreated = $false
        } else {
            throw
        }
    }

    # If both the user and student account don't exist, create the user account (with the isStudent set to true) and correlate
    # Note that 'isStudent = $true' will automatically create the student account
    if (-not($isUserAccountCreated) -and (-not($isStudentAccountCreated))){
        $action = 'Create-Correlate'
    }

    # If we have a user account but no student account, update the student account (with isStudent) and correlate
    # Note that 'isStudent = $true' will automatically create the student account
    if ($isUserAccountCreated -eq $true -and -not $isStudentAccountCreated){
        $action = 'Create-StudentAccount-Correlate-User'
    }

    # If we have a student account but no user account, create the user account (with isStudent) and correlate
    # Note that 'isStudent = $true' will automatically create the student account
    if ($isStudentAccountCreated -eq $true -and -not $isUserAccountCreated){
        $action = 'Create-UserAccount-Correlate-User'
    }

    # If we have both a user and student account, match the userCode. If a match is found, correlate
    if ($isUserAccountCreated -and $isStudentAccountCreated){
        if ($responseUser.response.data.code -eq $responseStudent.response.data.userCode) {
            $action = 'Correlate'
        }
    }

    # If, in the configuration, the boolean 'UpdatePersonOnCorrelate' is set to true, update the user account
    if ($($config.UpdatePersonOnCorrelate)){
        $action = 'Update-UserAccount-Correlate'
    }

    # Determine which departmentOfBranch will be assigned to the student
    try {
        $departmentToAssign = Get-DepartmentToAssignFromPrimaryContract -SchoolName $school -DepartmentName $department -ContractStartDate $startDate
    } catch {
        throw
    }

    # Add an informational message showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Information "[DryRun] $action Zermelo account for: [$($p.DisplayName)], will be executed during enforcement. Department of student is: [$($departmentToAssign.Id)]"
    }

    if (-not($dryRun -eq $true)) {
        switch ($action) {
            # If both the user and student account don't exist, create the user account (with the isStudent set to true) and correlate
            # Note that 'isStudent = $true' will automatically create the student account
            'Create-Correlate'{
                Write-Verbose 'Creating Zermelo user and student account and correlating user account'
                $splatCreateUserParams = @{
                    Endpoint    = 'users'
                    Method      = 'POST'
                    Body        = ($account | ConvertTo-Json)
                    ContentType = 'application/json'
                }
                $responseCreateAccount = Invoke-ZermeloRestMethod @splatCreateUserParams

                # Verify that we have a student account
                if ($responseCreateAccount.response.data){
                    $splatGetStudentAccount = @{
                        Endpoint = "students/$($account.code)"
                        Method   = 'GET'
                    }
                    $responseGetStudentAccount = Invoke-ZermeloRestMethod @splatGetStudentAccount

                    # If we have a student account, assign the correct department (classroom / schoolyear)
                    if ($responseGetStudentAccount.response.data){
                        $splatStudentInDepartmentParams = @{
                            Endpoint = 'studentsindepartments'
                            Method   = 'POST'
                            Body = @{
                                departmentOfBranch = $departmentToAssign.id
                                student = $account.code
                            } | ConvertTo-Json
                            ContentType = 'application/json'
                        }
                        $null = Invoke-ZermeloRestMethod @splatStudentInDepartmentParams
                    }
                }
                $accountReference = $responseCreateAccount.response.data.code
                break
            }

            # If we have a user account but no student account, update the student account (with isStudent) and correlate
            # Note that 'isStudent = $true' will automatically create the student account
            'Create-StudentAccount-Correlate-User'{
                Write-Verbose 'Creating Zermelo student account and correlating user account'
                $splatCreateStudentParams = @{
                    Endpoint    = 'users'
                    Method      = 'POST'
                    Body        = $updateAccount | ConvertTo-Json
                    ContentType = 'application/json'
                }
                $responseCreateStudentAccount = Invoke-ZermeloRestMethod @splatCreateStudentParams

                # If we have a student account, assign the correct department (classroom / schoolyear)
                if ($responseCreateStudentAccount.response.data.code){
                    $splatStudentInDepartmentParams = @{
                        Endpoint = 'studentsindepartments'
                        Method   = 'POST'
                        Body = @{
                            departmentOfBranch = $departmentToAssign.id
                            student = $account.code
                        } | ConvertTo-Json
                        ContentType = 'application/json'
                    }
                    $null = Invoke-ZermeloRestMethod @splatStudentInDepartmentParams
                }
                $accountReference = $responseCreateStudentAccount.response.data.code
                break
            }

            'Create-UserAccount-Correlate-User' {
                Write-Verbose 'Creating Zermelo user and student account and correlating user account'
                $splatCreateUserParams = @{
                    Endpoint    = 'users'
                    Method      = 'POST'
                    Body        = ($account | ConvertTo-Json)
                    ContentType = 'application/json'
                }
                $responseCreateAccount = Invoke-ZermeloRestMethod @splatCreateUserParams

                # Verify that we have a student account
                if ($responseCreateAccount.response.data){
                    $splatGetStudentAccount = @{
                        Endpoint = "students/$($account.code)"
                        Method   = 'GET'
                    }
                    $responseGetStudentAccount = Invoke-ZermeloRestMethod @splatGetStudentAccount

                    # If we have a student account, assign the correct department (classroom / schoolyear)
                    if ($responseGetStudentAccount.response.data){
                        $splatStudentInDepartmentParams = @{
                            Endpoint = 'studentsindepartments'
                            Method   = 'POST'
                            Body = @{
                                departmentOfBranch = $departmentToAssign.id
                                student = $account.code
                            } | ConvertTo-Json
                            ContentType = 'application/json'
                        }
                        $null = Invoke-ZermeloRestMethod @splatStudentInDepartmentParams
                    }
                }
                $accountReference = $responseCreateAccount.response.data.code
                break
            }

            # If we have both a user and student account, match the userCode. If a match is found, correlate
            'Correlate'{
                Write-Verbose 'Correlating Zermelo user account'
                $accountReference = $account.code
                break
            }

            # If, in the configuration, the boolean 'UpdatePersonOnCorrelate' is set to true, update the user account
            'Update-UserAccount-Correlate'{
                Write-Verbose 'Updating and correlating Zermelo user account'
                $splatUpdateUserParams = @{
                    Endpoint    = 'users'
                    Method      = 'POST'
                    Body        = $account | ConvertTo-Json
                    ContentType = 'application/json'
                }
                $responseUpdateAccount = Invoke-ZermeloRestMethod @splatUpdateUserParams
                # Assign the correct department (classroom / schoolyear)
                if ($responseUpdateAccount.response.data.code){
                    $splatStudentInDepartmentParams = @{
                        Endpoint = 'studentsindepartments'
                        Method   = 'POST'
                        Body = @{
                            departmentOfBranch = $currentDepartment.id
                            student = $account.code
                        } | ConvertTo-Json
                        ContentType = 'application/json'
                    }
                    $null = Invoke-ZermeloRestMethod @splatStudentInDepartmentParams
                }
                $accountReference = $responseUpdateAccount.response.data.code
            }
        }

        $success = $true
        $auditLogs.Add([PSCustomObject]@{
                Message = "$action account was successful. AccountReference is: [$accountReference]"
                IsError = $false
            })
    }
} catch {
    $errorObject = Resolve-ZermeloError -ErrorRecord $_
    $success = $false
    $auditMessage = "Could not $action Zermelo account. Error: $($errorObject.FriendlyError)"
    Write-Verbose "Error at Line '$($_.InvocationInfo.ScriptLineNumber)': $($_.InvocationInfo.Line). Error: $($errorObject.ErrorDetails)"
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
} finally {
    $result = [PSCustomObject]@{
        Success          = $success
        AccountReference = $accountReference
        Auditlogs        = $auditLogs
        Account          = $account
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
