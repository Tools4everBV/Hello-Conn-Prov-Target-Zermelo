#################################################
# HelloID-Conn-Prov-Target-Zermelo-Create
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

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
        $baseUrl = "$($actionContext.Configuration.BaseUrl)/api/v3"
        try {
            $headers = [System.Collections.Generic.Dictionary[[String],[String]]]::new()
            $headers.Add('Authorization', "Bearer $($actionContext.Configuration.Token)")

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
    # By default, we assume that both the user and student account are not present
    $isUserAccountCreated = $false
    $IsStudentAccountCreated = $false

    if ([string]::IsNullOrEmpty($($actionContext.Data.code))) {
        throw 'Mandatory attribute [code] is empty. Please make sure it is correctly mapped'
    }
    if ([string]::IsNullOrEmpty($actionContext.Data.classRoom)) {
        throw  'The mandatory property [classRoom] used to look up the department is empty. Please verify your script mapping.'
    }
    if ([string]::IsNullOrEmpty($actionContext.data.schoolName)) {
        throw 'The mandatory property [schoolName] used to look up the department is empty. Please verify your script mapping.'
    }
    if ([string]::IsNullOrEmpty($actionContext.Data.startDate)) {
        throw 'The mandatory property [startDate] used to look up the department is empty. Please verify your script mapping.'
    }

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.PersonField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [PersonFieldValue] is empty. Please make sure it is correctly mapped'
        }
    }

    # Validate the user account
    try {
        $responseUser = Get-ZermeloAccount -Code $actionContext.Data.code -Type 'users'
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
        $responseStudent = Get-ZermeloAccount -Code $actionContext.Data.code -Type 'students'
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

    # If we have a user account but no student account, update the user account (with isStudent) and correlate
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
        if ($responseUser.code -eq $responseStudent.userCode) {
            $action = 'Correlate'
            $outputContext.AccountReference = $responseUser.code
        }
    }

    # Determine which departmentOfBranch will be assigned to the student
    try {
        $splatGetDepartmentToAssign = @{
            SchoolName        = $actionContext.Data.schoolName
            DepartmentName    = $actionContext.Data.classRoom
            ContractStartDate = $actionContext.Data.startDate
        }
        $departmentToAssign = Get-DepartmentToAssignFromPrimaryContract @splatGetDepartmentToAssign
    } catch {
        throw
    }

    # Add a message and the result of each of the validations showing what will happen during enforcement
    if ($actionContext.DryRun -eq $true) {
        Write-Verbose "[DryRun] $action Zermelo account for: [$($personContext.Person.DisplayName)], will be executed during enforcement. Department of student is: [$($departmentToAssign.Id)]" -Verbose
    }

    # Process
    if (-not($actionContext.DryRun -eq $true)) {
        switch ($action) {
            'Create-Correlate' {
                Write-Verbose 'Creating and correlating Zermelo account'

                $splatCreateUserParams = @{
                    Endpoint    = 'users'
                    Method      = 'POST'
                    Body        = ($actionContext.Data | ConvertTo-Json)
                    ContentType = 'application/json'
                }
                $responseCreateAccount = Invoke-ZermeloRestMethod @splatCreateUserParams

                # Verify if the student account is created
                if ($responseCreateAccount.response.data){
                    $splatGetStudentAccount = @{
                        Endpoint = "students/$($actionContext.Data.code)"
                        Method   = 'GET'
                    }
                    $responseGetStudentAccount = Invoke-ZermeloRestMethod @splatGetStudentAccount

                    # If we have a student account, assign the correct department (classroom / school year)
                    if ($responseGetStudentAccount.response.data){
                        $splatStudentInDepartmentParams = @{
                            Endpoint = 'studentsindepartments'
                            Method   = 'POST'
                            Body = @{
                                departmentOfBranch = $departmentToAssign.id
                                student = $actionContext.Data.code
                            } | ConvertTo-Json
                            ContentType = 'application/json'
                        }
                        $null = Invoke-ZermeloRestMethod @splatStudentInDepartmentParams
                    }
                }
                $outputContext.Data = $responseCreateAccount.response.data
                $outputContext.AccountReference = $responseCreateAccount.response.data.code
                break
            }

            'Create-StudentAccount-Correlate-User'{
                Write-Verbose 'Creating Zermelo student account and correlating user account'
                $splatCreateStudentParams = @{
                    Endpoint    = 'users'
                    Method      = 'POST'
                    Body        = @{
                        code      = $actionContext.Data.Code
                        isStudent = $actionContext.Data.isStudent
                    } | ConvertTo-Json
                    ContentType = 'application/json'
                }
                $responseCreateStudentAccount = Invoke-ZermeloRestMethod @splatCreateStudentParams

                # If we have a student account, assign the correct department (classroom / school year)
                if ($responseCreateStudentAccount.response.data.code){
                    $splatStudentInDepartmentParams = @{
                        Endpoint = 'studentsindepartments'
                        Method   = 'POST'
                        Body = @{
                            departmentOfBranch = $departmentToAssign.id
                            student            = $actionContext.Data.code
                        } | ConvertTo-Json
                        ContentType = 'application/json'
                    }
                    $null = Invoke-ZermeloRestMethod @splatStudentInDepartmentParams
                }
                $outputContext.Data = $responseCreateAccount.response.data
                $outputContext.AccountReference = $responseCreateAccount.response.data.code
                break
            }

            'Create-UserAccount-Correlate-User' {
                Write-Verbose 'Creating Zermelo user and student account and correlating user account'
                $splatCreateUserParams = @{
                    Endpoint    = 'users'
                    Method      = 'POST'
                    Body        = ($actionContext.Data | ConvertTo-Json)
                    ContentType = 'application/json'
                }
                $responseCreateAccount = Invoke-ZermeloRestMethod @splatCreateUserParams

                # Verify that we have a student account
                if ($responseCreateAccount.response.data){
                    $splatGetStudentAccount = @{
                        Endpoint = "students/$($actionContext.Data.code)"
                        Method   = 'GET'
                    }
                    $responseGetStudentAccount = Invoke-ZermeloRestMethod @splatGetStudentAccount

                    # If we have a student account, assign the correct department (classroom / school year)
                    if ($responseGetStudentAccount.response.data){
                        $splatStudentInDepartmentParams = @{
                            Endpoint = 'studentsindepartments'
                            Method   = 'POST'
                            Body = @{
                                departmentOfBranch = $departmentToAssign.id
                                student = $actionContext.Data.code
                            } | ConvertTo-Json
                            ContentType = 'application/json'
                        }
                        $null = Invoke-ZermeloRestMethod @splatStudentInDepartmentParams
                    }
                }
                $outputContext.Data = $responseCreateAccount.response.data
                $outputContext.AccountReference = $responseCreateAccount.response.data.code
                break
            }

            # If we have both a user and student account, match the userCode. If a match is found, correlate
            'Correlate' {
                Write-Verbose 'Correlating Zermelo user account'
                $outputContext.Data = $responseUser.response.data
                $outputContext.AccountReference = $responseUser.response.data.code
                break
            }
        }

        $outputContext.Data = $responseCreateAccount.response.data
        $auditLogMessage = "$action account was successful. AccountReference is: [$($outputContext.AccountReference)"
        $outputContext.success = $true
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Action  = 'CreateAccount'
                Message = $auditLogMessage
                IsError = $false
            })
    }
} catch {
    $outputContext.success = $false
    $errorObject = Resolve-ZermeloError -ErrorRecord $_
    $auditMessage = "Could not $action Zermelo account. Error: $($errorObject.FriendlyMessage)"
    Write-Verbose "Error at Line '$($_.InvocationInfo.ScriptLineNumber)': $($_.InvocationInfo.Line). Error: $($errorObject.ErrorDetails)"
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
