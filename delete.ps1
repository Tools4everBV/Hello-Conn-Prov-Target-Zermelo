#########################################
# HelloID-Conn-Prov-Target-Zermelo-Delete
#
# Version: 1.0.1
# Provisioning PowerShell V1
#########################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Student account mapping
$account = [PSCustomObject]@{
    code     = $aRef #$p.ExternalId
    archived = $true
}

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

    Write-Verbose "Verifying if a $Name account for [$($p.DisplayName)] exists"
    try {
        $responseUser = Get-ZermeloAccount -Code $aRef -Type 'users'
    } catch {
        if ($_.Exception.Response.StatusCode -eq 'NotFound') {
            $action = 'NotFound'
            $dryRunMessage = "$Name account for: [`$(`$p.DisplayName)] not found. Possibly already deleted. Skipping action"
        } else {
            throw
        }
    }

    if ($responseUser){
        $action = 'Found'
        $dryRunMessage = "Delete $Name account for: [$($p.DisplayName)] will be executed during enforcement"
    }
    Write-Verbose $dryRunMessage

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        Write-Verbose "Deleting $Name account with accountReference: [$aRef]"

        switch ($action){
            'Found'{
                $splatUpdateUserParams = @{
                    Endpoint    = "users/$aRef"
                    Method      = 'PUT'
                    Body        = ($account | ConvertTo-Json)
                    ContentType = 'application/json'
                }
                $null = Invoke-ZermeloRestMethod @splatUpdateUserParams
                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                    Message = 'Delete account was successful'
                    IsError = $false
                })
                break
            }

            'NotFound'{
                $auditLogs.Add([PSCustomObject]@{
                    Message = "$Name account for: [$($p.DisplayName)] not found. Possibly already deleted. Skipping action"
                    IsError = $false
                })
                break
            }
        }

        $success = $true
    }
} catch {
    $errorObject = Resolve-ZermeloError -ErrorRecord $_
    $success = $false
    $auditMessage = "Could not delete Zermelo account. Error: $($errorObject.FriendlyError)"
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
