##################################################
# HelloID-Conn-Prov-Target-Zermelo-Delete
# PowerShell V2
##################################################

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
                Write-Information 'Adding body to request'
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

    Write-Information "Verifying if a Zermelo account for [$($personContext.Person.DisplayName)] exists"
    try {
        $correlatedAccount = Get-ZermeloAccount -Code $actionContext.References.Account -Type 'users'
    } catch {
        if ($_.Exception.Response.StatusCode -eq 'NotFound') {
            $action = 'NotFound'
            $dryRunMessage = "$Name account for: [$($personContext.Person.DisplayName)] not found. Possibly already deleted. Skipping action"
        } else {
            throw
        }
    }

    if ($null -ne $correlatedAccount) {
        $action = 'DeleteAccount'
        $dryRunMessage = "Delete Zermelo account: [$($actionContext.References.Account)] for person: [$($personContext.Person.DisplayName)] will be executed during enforcement"
    } else {
        $action = 'NotFound'
        $dryRunMessage = "Zermelo account: [$($actionContext.References.Account)] for person: [$($personContext.Person.DisplayName)] could not be found, possibly indicating that it could be deleted, or the account is not correlated"
    }

    # Add a message and the result of each of the validations showing what will happen during enforcement
    if ($actionContext.DryRun -eq $true) {
        Write-Information "[DryRun] $dryRunMessage" -Verbose
    }

    # Process
    if (-not($actionContext.DryRun -eq $true)) {
        switch ($action) {
            'DeleteAccount' {
                Write-Information "Deleting Zermelo account with accountReference: [$($actionContext.References.Account)]"
                $splatUpdateUserParams = @{
                    Endpoint    = "users/$($actionContext.References.Account)"
                    Method      = 'PUT'
                    Body        = ($actionContext.Data | ConvertTo-Json)
                    ContentType = 'application/json'
                }
                $null = Invoke-ZermeloRestMethod @splatUpdateUserParams
                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = 'Delete account was successful'
                    IsError = $false
                })
                break
            }

            'NotFound' {
                $outputContext.Success  = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Zermelo account: [$($actionContext.References.Account)] for person: [$($personContext.Person.DisplayName)] could not be found, possibly indicating that it could be deleted, or the account is not correlated"
                    IsError = $false
                })
                break
            }
        }
    }
} catch {
    $outputContext.success = $false
    $errorObject = Resolve-ZermeloError -ErrorRecord $_
    Write-Verbose $errorObject
    $auditMessage = "Could not delete Zermelo account. Error: $($errorObject.FriendlyError)"
    Write-Warning "Error at Line '$($_.InvocationInfo.ScriptLineNumber)': $($_.InvocationInfo.Line). Error: $($errorObject.ErrorDetails)"
    $outputContext.AuditLogs.Add([PSCustomObject]@{
        Message = $auditMessage
        IsError = $true
    })
}
