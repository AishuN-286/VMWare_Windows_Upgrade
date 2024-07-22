﻿param(
    #Vsphare Params
    $VcenterServers = "195.201.164.158,195.201.164.158",
    $AuthUser = "administrator",
    $AuthPassword = "Wigtra@2020",
    $ToEmail = "gpk.pandey.neeraj@gmail.com",
    $FromEmail = "no_reply@notification.com"
)

$SMTP_USER = "abc@gmail.com"
$SMTP_PASS = "abc"

Function Start-Log {
    param(
        [string]$LogFileName
    )
    $Location = (Join-Path $PSScriptRoot $LogFileName)
    New-Item -ItemType file $Location -Force | Out-Null
    $Global:LogFileLocation = $Location
}

Function Log-Info {
    param(
        [string]$Message
    )
    
    $logEntry = [pscustomobject]@{
        log_level = "INFO"
        message   = $Message
    }
    $logEntry | Export-Csv -Path $Global:LogFileLocation -Encoding ASCII -Append -NoTypeInformation -Force 
}

Function Log-Error {
    param(
        [string]$Message
    )
    $logEntry = [pscustomobject]@{
        log_level = "ERROR"
        message   = $Message
    }
    $logEntry | Export-Csv -Path $Global:LogFileLocation -Encoding ASCII -Append -NoTypeInformation -Force
}

Function Archive-Report {
    param(
        $FileName
    )
    $ArchiveDir = Join-Path $PSScriptRoot "Archive"
    [System.IO.Directory]::CreateDirectory($ArchiveDir) | Out-Null
    if (Test-Path $FileName) {
        Move-Item $FileName -Destination $ArchiveDir -Force
    }
}


function Send-StageStatusEmail {
    param (
        $FromEmail,
        $ToEmail,
        $Subject,
        $ReportPath
    )
    
    $logs = Import-Csv $Global:LogFileLocation
    $Password = $SMTP_PASS | ConvertTo-SecureString -AsPlainText -Force
    $AuthUser = $SMTP_USER
    $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $AuthUser, $Password
    $EmailParams = @{
        from       = $FromEmail
        to         = $ToEmail
        subject    = $Subject
        smtpserver = "smtp-relay.brevo.com"
        port       = 587
        UseSsl     = $true
        credential = $Credential
        BodyAsHtml = $true
    }

    $MailMessage = '<!DOCTYPE html><html><head></head><body>'
    if (-not (test-path $ReportPath)) {
        $MailMessage += '<p>Hello Team,<br><br>Your initiated, Vcenter Licence Report, has been completed without final report. Please contact your administrator.</br></br></p>'
    }
    else {
        $MailMessage += '<p>Hello Team,<br><br>Your initiated, Vcenter Licence Report, has been completed. Please check the logs below and take appropriate action.</br></br></p>'
        $EmailParams['Attachments'] = $ReportPath
    }

    $MailMessage += '<h3>Logs</h3><table style="font-family: arial, sans-serif;border-collapse: collapse;width: 50%;">'
    $MailMessage += '<tr><th style="border: 1px solid #dddddd;text-align: left;padding: 8px;word-wrap:break-word;">Type</th>'
    $MailMessage += '<th style="border: 1px solid #dddddd;text-align: left;padding: 8px;word-wrap:break-word;">Message</th></tr>'

    for ($i = 0; $i -lt $logs.Length; $i++) {
        if ($logs[$i].log_level -eq 'PROGRESS') { continue }
        $bgcolor = if ($i % 2 -eq 0) { "#dddddd" } else { "#FFFFFF" }
        $msgcolor = if ($logs[$i].log_level -eq 'ERROR') { "red" } else { "black" }
        $MailMessage += '<tr style="background-color:{0}"><td style="border: 1px solid #dddddd;text-align: left;padding: 8px;word-wrap:break-word; color:{1};">{2}</td>' -f $bgcolor, $msgcolor, $logs[$i].log_level
        $MailMessage += '<td style="border: 1px solid #dddddd;text-align: left;padding: 8px;word-wrap:break-word;">{0}</td></tr>' -f $logs[$i].message
    }
    $MailMessage += "</table></body></html></table><br><br>Regards,<br>Windows Migration Team"
    
    $EmailParams['body'] = $MailMessage
    
    Send-MailMessage @EmailParams
}

$VcenterLicenceReportFile = Join-Path $PSScriptRoot "HostUptimeReport.xlsx"
Start-Log -LogFileName "log_VcenterLicence.csv"
Archive-Report $VcenterLicenceReportFile
$ErrorActionPreference = "Stop"

try {
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

    [array]$VcenterServers = $VcenterServers -split "," | select -Unique
    $SecurePassword = $AuthPassword | ConvertTo-SecureString -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential($AuthUser, $SecurePassword)
    $VcenterLicenceReport = @()

    foreach ($server in $VcenterServers) {
        try {
            $server = $server.trim()
            Log-Info -Message "Trying to connect to VIServer '$server'."
            Connect-VIServer -Server $server -Credential $Credential
            Log-Info -Message "Connected to VIServer."
            Log-Info -Message "Generating licence report for VIServer."
            foreach ($LicenceManager in (Get-View LicenceManager)) {
                foreach ($licence in $LicenceManager.Licences) {
                    $LicenceExpiryInfo = $licence.Properties | ? { $_.Key -eq 'expirationDate' } | select -expand Value
                    if ($licence.Name -eq 'Product Evaluation') {
                        $expirationDate = 'Evaluation'
                    }
                    elseif ($null -eq $licenseExpiryInfo) {
                        $expirationDate = 'Never'
                    }
                    else {
                        $expirationDate = $licenseExpiryInfo
                    }
                    $VcenterLicenceReport += New-Object psobject -Property @{
                        VcenterServer  = $server
                        Name           = $licence.name
                        LicenceKey     = $license.LicenseKey
                        ExpirationDate = $expirationDate
                    }
                }
            }
            Disconnect-VIServer -Server $server -Confirm:$false | Out-Null
        }
        catch {
            Log-Error -Message "Failed to query licence report from VIServer."
            Log-Error -Message $("ErrorRecord : {0}, CommandName: {1}, Message: {2}" -f $_.Exception.ErrorRecord, $_.Exception.CommandName, $_.Exception.Message)
        }
    }
    if ($VcenterLicenceReport) {
        Log-Info -Message "Generating consolidated report."
        $VcenterLicenceReport | Export-Excel $VcenterLicenceReportFile -WorksheetName "VcenterLicenceReport" 
    }
}
catch {
    Log-Error -Message $("ErrorRecord : {0}, CommandName: {1}, Message: {2}" -f $_.Exception.ErrorRecord, $_.Exception.CommandName, $_.Exception.Message)
}
finally {
    Send-StageStatusEmail -FromEmail $FromEmail -ToEmail $($ToEmail -split ",") -Subject "Vcenter Licence Report." -ReportPath $VcenterLicenceReportFile
}