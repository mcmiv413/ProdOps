param (
    [switch]$DBMS_DEV,
    [switch]$destructive,
    $clonedir='', #Dir to create the clones in
    $githuburl='',
    $token = '', #API Token
    $scriptrepo='',
    $configrepo='',
    $productionorg = '',
    $betaorg = '', 
    $branchcleanday = '', #Day of week to run cleanup
    $branchcleanstartutc = '', #Cleanup window start time in UTC
    $branchcleanendutc = '' #Cleanup window end time in UTC
)
function remove-localbranchfolders
{
    $convertedtime = (get-date "0:00").touniversaltime()
    $convertedtime = $convertedtime.addhours(-$convertedtime.hour)
    $starttime = $convertedtime.Add($branchcleanstartutc)
    $endtime = $convertedtime.Add($branchcleanendutc)
    $UtcTime = $(Get-Date).ToUniversalTime()
    if ( $($UtcTime.DayOfWeek) -like $branchcleanday )
    {
        If ($UtcTime -gt $starttime -and $UtcTime -lt $endtime )
        {
            $branches = Get-ChildItem $clonedir -attributes D -Recurse -include "branch_*"
            foreach ($branch in $branches)
            {
                "Removing $($branch.fullname)"
                try { remove-item $branch.fullname -Recurse -Force }
                catch { Write-Warning "Could not remove $($branch.fullname)" }
                if ($?) { "Done Removing $($branch.fullname)"}
            }
        }

    }
    
}
Function Create-Clone
{
    param($repo,$folder='',$url)
    cmd /c "git clone $url $folder >> c:\temp\git.log 2>&1"
    if ( $? ) 
    { 
        if ( !$folder ) { "$repo repository successfully cloned to $pwd." }
        else { "$repo repository successfully cloned to $folder." }
    }
    else { "$repo Repository cloning failed."; get-content c:\temp\git.log}
    Remove-Item c:\temp\git.log
}
function get-repoinfo
{
    param ( $org )
    ($(invoke-webrequest "https://$githuburl/api/v3/users/$org/repos?per_page=200&type=org&sort=full_name&direction=asc&access_token=$token" -UseBasicParsing).Content | 
        ConvertFrom-Json) | 
        Where-Object { $_.name -like $scriptrepo -or $_.name -like $configrepo }
}
Function Set-CloneMaster
{
    param($org, $RootFolder, $configorg, [switch]$nobranch)
    $scriptrepoinfo = get-repoinfo -org $org 
    $configrepoinfo = get-repoinfo -org $configorg 
    foreach ($repo in $scriptrepoinfo)
    {
        write-debug "$($repo.name)"
        $repofolder = "$RootFolder\$($repo.name)"
        $scriptcloneurl = $($repo.clone_url).Replace('https://',"https://$token@")
        $configcloneurl = $($configrepoinfo.clone_url | Where-Object { $_ -match "$configrepo" }).Replace('https://',"https://$token@")
        if( !$(Test-Path -Path $repofolder)) { mkdir $repofolder -Force | out-null }
        Set-Location $repofolder
        if ( $($repo.name) -match "^$configrepo$" ) { $cloneurl = $configcloneurl }
        else { $cloneurl = $scriptcloneurl }
        if( !$(Test-GitStatus))
        {
            Create-Clone -repo $repo.name -folder $repofolder -url $cloneurl | tee-object $gitlog -append 
        }
        if (!$nobranch) 
        {
            cmd /c "git branch -r 2>&1" | 
            Where-Object { $_ -notmatch '/master$'} | 
            Select-Object -unique |
            ForEach-Object { 
                $script:newbranches += new-object -TypeName psobject -Property @{ 
                    Org = $org
                    Folder = $rootfolder
                    Repo = $repo.name
                    Branch = $_.split('/')[-1]
                    URL = $cloneurl
                } 
            }
        }
    }
}
Function Test-GitStatus
{
    $ErrorActionPreference = 'Stop'
    try { git status 2>&1 }
    catch { $ErrorActionPreference = 'Continue';return $false }
    $ErrorActionPreference = 'Continue'
    return $true
}
Function Set-CloneBranch
{
    param($branch)
    $branchname = $branch.branch
    $folder = $branch.folder
    $org = $branch.org
    $repo = $branch.repo
    $cloneurl = $branch.url
    Set-Location $folder
    $branchfolder = "$folder\branch_$branchname"
    if( !$(Test-Path -Path $branchfolder\$repo)) 
    { 
        mkdir $branchfolder -Force | out-null
        Set-Location $branchfolder
        if( !$(Test-GitStatus))
        {
            Create-Clone -repo $repo -url $cloneurl | tee-object $gitlog -append
            if (test-path $pwd\dbms_scripts) 
            { 
                Set-Location dbms_scripts; 
                cmd /c "git checkout $branchname 2>&1"  | tee-object $gitlog -append;
                if ($($(git remote -v) -join " ") -notlike "*$productionorg*"){ git remote add $($productionorg.ToLower()) "https://$token@$githuburl/$productionorg/$repo" }
                git remote set-url --push $($productionorg.ToLower()) NO-PUSHING 
                Set-Location ..
            } 
            if (test-path $pwd\dbms_config) { Set-Location dbms_config; cmd /c "git checkout $branchname 2>&1"  | tee-object $gitlog -append; Set-Location ..} 
        }
    }   
}
function Update-LocalGits()
{
	$gits = Get-ChildItem $clonedir -Recurse -Include .git -Force 
    if ($env:dbms_dev) { $gits = $gits | Where-Object { $_.fullname -notlike '*\fork\*'}}
    ForEach($git in $gits)
    {
		Push-Location $git.fullname
        "$($git.fullname)"
		Set-Location ..
		Set-GitEnforce
		Pop-Location
	}
}
function Set-GitEnforce()
{
	$status = @()
    cmd /c "git fetch --prune --all 2>&1"  | tee-object $gitlog -append 
    $status = cmd /c "git status 2>&1"  | tee-object $gitlog -append
    $porcelain = cmd /c "git status --porcelain 2>&1" | tee-object $gitlog -append
    $status += $porcelain
    switch -regex ($status)
    {
        'Changes not staged' { $modified = $porcelain | Where-Object { $_ -match '^ M ' -or $_ -match '^ D ' }}
        'Untracked' { $untracked = $porcelain | Where-Object { $_ -match '^\?\? ' } }
        default { $null }
    }
    "Fixing Modified/Deleted:" | tee-object $gitlog -append
    foreach ( $file in $modified )
    {
        "`t$($file.split(' ')[-1])" 2>&1  | tee-object $gitlog -append    
    }
    "Removing Untracked:" | tee-object $gitlog -append
    foreach ( $file in $untracked )
    {
        $filearray = $file.split(' ')
        $filename = $filearray[1..($filearray.Length-1)] -join ' '
        "`t$filename" 2>&1  | tee-object $gitlog -append
        
    }
    if ( $destructive ) 
    { 
        if ( $modified -or $untracked ) {
            cmd /c "git clean -df 2>&1" | tee-object $gitlog -append 
            cmd /c "git reset --hard HEAD" | tee-object $gitlog -append 
        }
    }
    if ($status -match 'is behind') 
    { 
        "Running Git Pull" | tee-object $gitlog -append
        cmd /c "git pull  2>&1"  | tee-object $gitlog -append  
    }
}
if ( $DBMS_DEV) 
{ 
    [Environment]::SetEnvironmentVariable("DBMS_DEV", $true, "Machine") 
    $env:DBMS_DEV = $true
}
remove-localbranchfolders
if( !$(Test-Path -Path $clonedir\logs\github)) { mkdir $clonedir\logs\github -Force | out-null }
$gitlog = "$clonedir\logs\github\gitlog$(get-date -f 'yyyyMMdd-HHmm').log"
Get-ChildItem "$clonedir\logs\github\" | Where-Object {!$_.psiscontainer -and $_.lastwritetime -lt (get-date).adddays(-7) } | remove-item -include *.*
$script:newbranches = @()
Set-CloneMaster -org $betaorg -RootFolder "$clonedir\beta" -configorg $betaorg
Set-CloneMaster -org $productionorg -RootFolder "$clonedir" -configorg $betaorg -nobranch
foreach ($branch in $newbranches)
{
    Set-CloneBranch -branch $branch 
}
Update-LocalGits
$CurrentValue = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
$modulepath = "$clonedir\$scriptrepo\modules"
#$modulepath = $(Get-ChildItem $psscriptroot\..\.. | Where-Object { $_ -like "*modules*" }).fullname
if ($currentvalue -notlike "*$modulepath*" ) { [Environment]::SetEnvironmentVariable("PSModulePath", $CurrentValue + ";$modulepath", "Machine") }
$CurrentConfigValue = [Environment]::GetEnvironmentVariable("DBMSConfigPath", "Machine")
$configpath = "$clonedir\$configrepo"
#$configpath = $($($(Get-ChildItem $psscriptroot\..\..\..\dbms_config -File)[0]).directory).fullname
if ( $CurrentConfigValue -notlike "*$configpath*" ) { [Environment]::SetEnvironmentVariable("DBMSConfigPath", $configpath, "Machine") }
$env:PSModulePath = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
$env:dbmsconfigpath = [Environment]::GetEnvironmentVariable("DBMSConfigPath", "Machine")