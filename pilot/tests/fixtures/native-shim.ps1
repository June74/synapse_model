param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

Write-Output ('SHIM_OK:' + ($Arguments -join '|'))
