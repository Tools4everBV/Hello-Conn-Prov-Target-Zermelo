#################################################
# HelloID-Conn-Prov-Target-Zermelo-Update
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


function ConvertTo-HashTableToObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $string
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
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
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

    Write-Verbose "Verifying if a Zermelo account for [$($personContext.Person.DisplayName)] exists"
    # Validate the user account
    try {
        $correlatedAccount = Get-ZermeloAccount -Code $actionContext.References.Account -Type 'users'
        $outputContext.PreviousData = $correlatedAccount
    } catch {
        throw
    }

    # Always compare the account against the current account in target system
    $actions = @()
    if ($null -ne $correlatedAccount) {
    # Compare Zermelo account
        $splatCompareProperties = @{
            ReferenceObject  = @($correlatedAccount[0].PSObject.Properties)
            DifferenceObject = @($actionContext.Data.PSObject.Properties)
        }
        $studentPropertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({$_.SideIndicator -eq '=>'})
        if ($studentPropertiesChanged -and ($null -ne $correlatedAccount)) {
            $actions += "Update-Account"
            $dryRunMessage = "Account property(s) required to update: [$($studentPropertiesChanged.name -join ",")]"
        } elseif (-not($studentPropertiesChanged)) {
            $actions += 'NoChanges'
            $dryRunMessage = 'No changes will be made to the account during enforcement'
        } elseif ($null -eq $correlatedAccount) {
            $actions += 'NotFound'
            $dryRunMessage = "Zermelo account for: [$($personContext.Person.DisplayName)] not found. Possibly deleted"
        }
        Write-Verbose $dryRunMessage
    }

    # Check whether or not the contract department (classroom) has been updated
    if (-not[string]::IsNullOrEmpty($personContext.PreviousPerson.PrimaryContract.Department.DisplayName)){
        $pdHashtable = ConvertTo-HashTableToObject -String $personContext.PreviousPerson.PrimaryContract.Department.DisplayName
        if ($pdHashtable.Change -eq 'updated'){
            $actions += 'Update-Department'
            $dryRunMessage = "Updating department to: [$($pdHashtable.New)]"

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
        } else {
            $actions += 'NoChanges'
            $dryRunMessage = 'No changes will be made to the department during enforcement'
        }
    }

    # Add a message and the result of each of the validations showing what will happen during enforcement
    if ($actionContext.DryRun -eq $true) {
        Write-Verbose "[DryRun] $dryRunMessage" -Verbose
    }

    # Process
    if (-not($actionContext.DryRun -eq $true)) {
        switch ($action) {
            'Update-Account' {
                Write-Verbose "Updating Zermelo account with accountReference: [$($actionContext.References.Account)]"
                $splatUpdateUserParams = @{
                    Endpoint    = 'users'
                    Method      = 'POST'
                    Body        = ($actionContext.Data | ConvertTo-Json)
                    ContentType = 'application/json'
                }
                $null = Invoke-ZermeloRestMethod @splatUpdateUserParams

                $outputContext.success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = 'Update account was successful'
                    IsError = $false
                })
                break
            }

            'Update-Department'{
                Write-Verbose "Updating department for Zermelo account with accountReference: [$($actionContext.References.Account)]"
                if ($pdHash.Change -eq 'updated'){
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

                    $outputContext.success = $true
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                        Message = 'Update department was successful'
                        IsError = $false
                    })
                    break
                }
            }

            'NoChanges' {
                Write-Verbose "No changes to Zermelo account with accountReference: [$($actionContext.References.Account)]"

                $outputContext.success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = 'No changes will be made to the account during enforcement'
                    IsError = $false
                })
                break
            }

            'NotFound' {
                Write-Verbose "Zermelo account for: [$($personContext.Person.DisplayName)] not found. Possibly deleted"

                $outputContext.success = $false
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Zermelo account for: [$($personContext.Person.DisplayName)] not found. Possibly deleted"
                    IsError = $true
                })
                break
            }
        }
    }
} catch {
    $outputContext.Success  = $false
    $errorObject = Resolve-ZermeloError -ErrorRecord $_
    $auditMessage = "Could not update Zermelo account. Error: $($errorObject.FriendlyMessage)"
    Write-Verbose "Error at Line '$($_.InvocationInfo.ScriptLineNumber)': $($_.InvocationInfo.Line). Error: $($errorObject.ErrorDetails)"
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
