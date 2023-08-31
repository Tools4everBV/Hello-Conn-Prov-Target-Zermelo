#################################################
# HelloID-Conn-Prov-Target-Zermelo-Update
#
# Version: 1.0.0
#################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$pd = $personDifferences | ConvertFrom-Json
$aRef = $accountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Student account mapping
$studentAccount = [PSCustomObject]@{
    userCode  = $p.ExternalId
    firstName = $p.Name.GivenName
    prefix    = $p.Name.FamilyNamePrefix
    lastName  = $p.Name.FamilyName
    email     = $p.Contact.Business.Email
}

# Student account mapping
$userAccount = [PSCustomObject]@{
    code      = $p.ExternalId
    firstName = $p.Name.GivenName
    prefix    = $p.Name.FamilyNamePrefix
    lastName  = $p.Name.FamilyName
    email     = $p.Contact.Business.Email
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


function ConvertStringHashTableToObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $HashTableString
    )

    $trimmedString = $HashTableString.TrimStart('@{').TrimEnd('}')
    $keyValuePairs = $trimmedString -split ';'
    $hashTable = @{}
    foreach ($pair in $keyValuePairs) {
        $key, $value = $pair -split '=', 2
        $hashTable[$key.Trim()] = $value.Trim()
    }

    Write-Output $hashTable
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
    # Verify if the [$aRef] has a value
    if ([string]::IsNullOrEmpty($($aRef))) {
        throw 'Mandatory attribute [aRef] is empty.'
    }

    if ($aRef -ne $p.ExternalId){
        throw "aRef [$aRef] does not match with [$($p.ExternalId)]"
    }

    if ([string]::IsNullOrEmpty($department)) {
        throw  'The mandatory property [$department] used to look up the department is empty. Please verify your script mapping.'
    }
    if ([string]::IsNullOrEmpty($school)) {
        throw 'The mandatory property [$school] used to look up the department is empty. Please verify your script mapping.'
    }
    if ([string]::IsNullOrEmpty($startDate)) {
        throw 'The mandatory property [$startDate] used to look up the department is empty. Please verify your script mapping.'
    }

    # Validate the student account
    try {
        $responseStudent = Get-ZermeloAccount -Code $aRef -Type 'students'
    } catch {
        throw
    }

    $actions = @()
    # Compare Zermelo student account
    $splatCompareProperties = @{
        ReferenceObject  = @($responseStudent[0].PSObject.Properties)
        DifferenceObject = @($studentAccount.PSObject.Properties)
    }
    $studentPropertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({$_.SideIndicator -eq '=>'})
    if ($studentPropertiesChanged -and ($null -ne $responseStudent)) {
        $actions += "Update-Account"
        $dryRunMessage = "Account property(s) required to update: [$($studentPropertiesChanged.name -join ",")]"
    } elseif (-not($studentPropertiesChanged)) {
        $actions += 'NoChanges'
        $dryRunMessage = 'No changes will be made to the account during enforcement'
    } elseif ($null -eq $responseStudent) {
        $actions += 'NotFound'
        $dryRunMessage = "Zermelo account for: [$($p.DisplayName)] not found. Possibly deleted"
    }
    Write-Verbose $dryRunMessage

    # Check whether or not the contract department (classroom) has been updated
    if (-not[string]::IsNullOrEmpty($pd.PrimaryContract.Department.DisplayName)){
        $pdHash = ConvertStringHashTableToObject -HashTableString $pd.PrimaryContract.Department.DisplayName
        if ($pdHash.Change -eq 'updated'){
            $actions += 'Update-Department'
            $dryRunMessage = "Updating department to: [$($pdHash.New)]"

            # Determine which departmentOfBranch will be assigned to the student
            try {
                $departmentToAssign = Get-DepartmentToAssignFromPrimaryContract -SchoolName $school -DepartmentName $department -ContractStartDate $startDate
            } catch {
                throw
            }
        } else {
            $actions += 'NoChanges'
            $dryRunMessage = 'No changes will be made to the department during enforcement'
        }
    }
    Write-Verbose $dryRunMessage

    # Add a informational message showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Information "[DryRun] $dryRunMessage"
    }

    if (-not($dryRun -eq $true)) {
        foreach ($action in $actions){
            switch ($action) {
                'Update-Account' {
                    Write-Verbose "Updating Zermelo account with accountReference: [$aRef]"
                    $splatUpdateUserParams = @{
                        Endpoint    = 'users'
                        Method      = 'POST'
                        Body        = ($userAccount | ConvertTo-Json)
                        ContentType = 'application/json'
                    }
                    $null = Invoke-ZermeloRestMethod @splatUpdateUserParams

                    $success = $true
                    $auditLogs.Add([PSCustomObject]@{
                        Message = 'Update account was successful'
                        IsError = $false
                    })
                    break
                }

                'Update-Department'{
                    Write-Verbose "Updating department for Zermelo account with accountReference: [$aRef]"
                    if ($pdHash.Change -eq 'updated'){
                        $splatStudentInDepartmentParams = @{
                            Endpoint = 'studentsindepartments'
                            Method   = 'POST'
                            Body = @{
                                departmentOfBranch = $departmentToAssign.id
                                student = $userAccount.code
                            } | ConvertTo-Json
                            ContentType = 'application/json'
                        }
                        $null = Invoke-ZermeloRestMethod @splatStudentInDepartmentParams

                        $success = $true
                        $auditLogs.Add([PSCustomObject]@{
                            Message = 'Update department was successful'
                            IsError = $false
                        })
                        break
                    }
                }

                'NoChanges' {
                    Write-Verbose "No changes to Zermelo account with accountReference: [$aRef]"

                    $success = $true
                    $auditLogs.Add([PSCustomObject]@{
                        Message = 'No changes will be made to the account during enforcement'
                        IsError = $false
                    })
                    break
                }

                'NotFound' {
                    Write-Verbose "Zermelo account for: [$($p.DisplayName)] not found. Possibly deleted"

                    $success = $false
                    $auditLogs.Add([PSCustomObject]@{
                        Message = "Zermelo account for: [$($p.DisplayName)] not found. Possibly deleted"
                        IsError = $true
                    })
                    break
                }
            }
        }
    }
} catch {
    $errorObject = Resolve-ZermeloError -ErrorRecord $_
    $success = $false
    $auditMessage = "Could not update Zermelo account. Error: $($errorObject.FriendlyMessage)"
    Write-Verbose "Error at Line '$($_.InvocationInfo.ScriptLineNumber)': $($_.InvocationInfo.Line). Error: $($errorObject.ErrorDetails)"
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
} finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Account   = $account
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
