#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Message Trace Report - package integrity tests (Pester 5 or later).
    Author  : Nicolas Fabert
    Version : 1.1.1

    The cases tagged RealSignature need a release package signed by the owner: they are skipped unless the
    environment variable MTR_RELEASE_PACKAGE names the folder of a package after New-MtrPackage.ps1 -Seal.
    The other cases run the real verifier on a fixture copy whose Authenticode checks are replaced by a no-op, so that the
    manifest, the inventory, the hashes and the folder rules are exercised before the owner signs.
#>
BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Source = Join-Path $script:RepoRoot 'package'
    $script:Pwsh = Join-Path $PSHOME 'pwsh.exe'
    $script:FixtureNumber = 0
    $script:Fixture = $null

    # The manifest writer of the package builder, used as is.
    $signer = '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
    $version = (Import-PowerShellDataFile (Join-Path $script:Source 'MessageTraceReport.psd1')).ModuleVersion
    $configRelative = 'config\MessageTraceReport.config.psd1'
    $builderPath = Join-Path $script:RepoRoot 'tools\New-MtrPackage.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$null, [ref]$null)
    foreach ($name in 'Get-RelativeFile', 'Write-Manifest') {
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
        if ($null -eq $function) { throw "The builder function $name is missing." }
        . ([scriptblock]::Create($function.Extent.Text))
    }

    function New-FixtureTemplate {
        $template = Join-Path $TestDrive 'template'
        Copy-Item -LiteralPath $script:Source -Destination $template -Recurse
        foreach ($folder in 'bin', 'data', 'logs', 'reports') {
            Remove-Item -LiteralPath (Join-Path $template $folder) -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath (Join-Path $template 'PackageIntegrity.psd1') -ErrorAction SilentlyContinue
        # A release package holds the HTML guides only.
        Remove-Item -LiteralPath (Join-Path $template 'docs\images') -Recurse -Force
        Get-ChildItem -LiteralPath (Join-Path $template 'docs') -Filter '*.md' | Remove-Item
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'CHANGELOG.md') -Destination $template
        # The test copy of the verifier does not check Authenticode: everything else is the delivered code.
        $verifier = Join-Path $template 'src\Test-PackageIntegrity.ps1'
        $text = [IO.File]::ReadAllText($verifier)
        $stubbed = [regex]::Replace($text, '(?s)function Assert-OwnerSignature\(\[string\]\$Path\) \{.*?\r?\n\}\r?\n', "function Assert-OwnerSignature([string]`$Path) { }`r`n")
        if ($stubbed -ceq $text) { throw 'The owner-signature check was not found in the verifier.' }
        [IO.File]::WriteAllText($verifier, $stubbed, [Text.UTF8Encoding]::new($false))
        [void](Write-Manifest $template)
        $template
    }
    function Reset-Fixture([switch]$Source) {
        Remove-Module MessageTraceReport -Force -ErrorAction SilentlyContinue
        $script:FixtureNumber++
        $script:Fixture = Join-Path $TestDrive ('package-{0:D4}' -f $script:FixtureNumber)
        Copy-Item -LiteralPath $script:Template -Destination $script:Fixture -Recurse
        # A source checkout: the file copied at build time is absent.
        if ($Source) { Remove-Item -LiteralPath (Join-Path $script:Fixture 'CHANGELOG.md') }
    }
    function Invoke-Guard([string[]]$Switch = @()) {
        $verifier = Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1'
        $arguments = @{ Root = $script:Fixture }
        foreach ($name in $Switch) { $arguments[$name] = $true }
        & $verifier @arguments 3> $null
    }
    function Invoke-Child([string]$Command) {
        $output = & $script:Pwsh -NoProfile -NonInteractive -Command $Command 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
    }
    function Edit-Protected([string]$Path) {
        if ([IO.Path]::GetExtension($Path) -in '.ps1', '.psm1', '.psd1') {
            [IO.File]::WriteAllText($Path, "# Evidence-only tamper`r`n" + [IO.File]::ReadAllText($Path), [Text.UTF8Encoding]::new($true))
        } else { [IO.File]::AppendAllBytes($Path, [Text.Encoding]::ASCII.GetBytes("`r`n# Evidence-only tamper")) }
    }
    $script:Template = New-FixtureTemplate
    $script:Entries = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:Template 'PackageIntegrity.psd1')).Files)
}

Describe 'Signed manifest and verifier' {
    BeforeEach { Reset-Fixture }
    It 'accepts the distribution, the same files as a source checkout, and each in its own mode' {
        (Invoke-Guard @('Distribution')).Status | Should -Be 'Valid'
        (Invoke-Guard).Status | Should -Be 'Valid (files only)'
        (Invoke-Guard @('DevelopmentMode')).Status | Should -Be 'Valid (DevelopmentMode)'
        Reset-Fixture -Source
        (Invoke-Guard).Status | Should -Be 'Valid (files only)'
        { Invoke-Guard @('Distribution') } | Should -Throw
    }
    It 'refuses -Distribution together with -DevelopmentMode' {
        { Invoke-Guard @('Distribution', 'DevelopmentMode') } | Should -Throw -ExpectedMessage '*cannot be combined*'
    }
    It 'lists every shipped file except the editable configuration' {
        $paths = @($script:Entries.Path)
        $paths | Should -Contain 'Invoke-MessageTraceReport.ps1'
        $paths | Should -Contain 'src\Engine.Route.cs'
        $paths | Should -Contain 'docs\MessageTraceReport-UserGuide.html'
        $paths | Should -Contain 'CHANGELOG.md'
        $paths | Should -Not -Contain 'config\MessageTraceReport.config.psd1'
        $paths | Should -Not -Contain 'PackageIntegrity.psd1'
        $paths.Count | Should -Be (@($paths | Select-Object -Unique).Count)
    }
    It 'accepts the edited configuration and the generated folders' {
        Add-Content (Join-Path $script:Fixture 'config\MessageTraceReport.config.psd1') '# Fictitious customization'
        foreach ($folder in 'bin', 'data', 'logs', 'reports') {
            [void][IO.Directory]::CreateDirectory((Join-Path $script:Fixture $folder))
            Set-Content (Join-Path $script:Fixture "$folder\generated.txt") 'generated'
        }
        (Invoke-Guard @('Distribution')).Status | Should -Be 'Valid'
    }
    It 'rejects a tampered file, for every protected entry' {
        foreach ($entry in $script:Entries) {
            Reset-Fixture
            Edit-Protected (Join-Path $script:Fixture $entry.Path)
            # The signature check of the fixture verifier is stubbed: the refusal comes from the hash.
            { Invoke-Guard @('Distribution') } | Should -Throw -ExpectedMessage '*SHA256 mismatch*' -Because $entry.Path
        }
    }
    It 'rejects a missing file, for every protected entry' {
        foreach ($entry in $script:Entries) {
            Reset-Fixture
            Remove-Item -LiteralPath (Join-Path $script:Fixture $entry.Path)
            { Invoke-Guard @('Distribution') } | Should -Throw -Because $entry.Path
        }
    }
    It 'rejects an unexpected file' {
        foreach ($relative in 'extra.ps1', 'extra.cmd', 'MessageTraceReport.cer', 'vip.csv', 'src\extra.cs', 'src\extra.ps1', 'lib\sqlite\extra.dll', 'templates\extra.html', 'docs\extra.html', 'docs\images\extra.png', 'config\extra.psd1') {
            Reset-Fixture
            [void][IO.Directory]::CreateDirectory((Split-Path (Join-Path $script:Fixture $relative) -Parent))
            Set-Content (Join-Path $script:Fixture $relative) 'not executable'
            { Invoke-Guard } | Should -Throw -ExpectedMessage '*unexpected stable file*Move your own files*out of the tool folder*MessageTraceReport-data*download the ZIP again*' -Because $relative
        }
    }
    It 'rejects a second copy of the verifier, and one that does not belong to the package root' {
        $other = Join-Path $TestDrive 'other-root'
        [void][IO.Directory]::CreateDirectory((Join-Path $other 'src'))
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') -Destination (Join-Path $other 'src')
        { & (Join-Path $other 'src\Test-PackageIntegrity.ps1') -Root $script:Fixture 3> $null } | Should -Throw -ExpectedMessage '*verifier must belong to this package root*'
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Fixture 'tools'))
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1') -Destination (Join-Path $script:Fixture 'tools')
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*unexpected stable file*'
    }
    It 'rejects a junction in a protected subtree' {
        $outside = Join-Path $TestDrive 'junction-target'
        [void][IO.Directory]::CreateDirectory($outside)
        foreach ($relative in 'src', 'lib\sqlite', 'templates', 'docs', 'config') {
            Reset-Fixture
            $link = Join-Path $script:Fixture $relative
            Remove-Item -LiteralPath $link -Recurse -Force
            New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
            try { { Invoke-Guard } | Should -Throw -Because $relative }
            finally { (Get-Item -LiteralPath $link -Force).Delete() }
        }
    }
    It 'rejects an absent manifest and a manifest of the wrong shape' {
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'PackageIntegrity.psd1')
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*PackageIntegrity.psd1 is missing. Download the release ZIP again*releases/latest*-DevelopmentMode*'
        Reset-Fixture
        Copy-Item -LiteralPath (Join-Path $script:Fixture 'MessageTraceReport.psd1') -Destination (Join-Path $script:Fixture 'PackageIntegrity.psd1') -Force
        { Invoke-Guard } | Should -Throw -ExpectedMessage '*unsupported or incomplete manifest schema*'
    }
    It 'rejects a manifest that omits, duplicates, adds or retargets an entry' {
        $manifestPath = Join-Path $script:Fixture 'PackageIntegrity.psd1'
        $original = [IO.File]::ReadAllText($manifestPath)
        $lines = $original -split "`r?`n"
        $first = ($lines | Where-Object { $_ -match "^\s+@\{ Path = '" })[0]
        $variants = @{
            omit      = ($lines | Where-Object { $_ -ne $first }) -join "`r`n"
            duplicate = $original.Replace($first, "$first`r`n$first")
            add       = $original.Replace($first, "$first`r`n        @{ Path = 'src\extra.ps1'; Sha256 = '$('A' * 64)' }")
            retarget  = $original.Replace($first, ($first -replace "Path = '[^']+'", "Path = 'src\extra.ps1'"))
            badhash   = $original.Replace($first, ($first -replace "Sha256 = '[0-9A-F]{64}'", "Sha256 = '$('0' * 64)'"))
        }
        foreach ($name in $variants.Keys) {
            [IO.File]::WriteAllText($manifestPath, $variants[$name], [Text.UTF8Encoding]::new($false))
            { Invoke-Guard } | Should -Throw -Because $name
        }
    }
}

Describe 'Integrity at the entry points' {
    BeforeEach { Reset-Fixture }
    It 'refuses to start the entry script from a changed package, before any database or compiled work' {
        foreach ($relative in 'src\Engine.Route.cs', 'lib\sqlite\runtimes\win-x64\e_sqlite3.dll', 'src\Test-PackageIntegrity.ps1', 'MessageTraceReport.psm1') {
            Reset-Fixture
            Edit-Protected (Join-Path $script:Fixture $relative)
            $run = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-MessageTraceReport.ps1')' -Mode Status; 'EXIT=' + `$LASTEXITCODE")
            $run.Text | Should -Match 'Package integrity'
            $run.Text | Should -Not -Match 'No database yet|EXIT=0'
            Test-Path -LiteralPath (Join-Path $script:Fixture 'data') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:Fixture 'bin') | Should -BeFalse
        }
    }
    It 'refuses a tampered verifier before the module is imported' {
        Edit-Protected (Join-Path $script:Fixture 'src\Test-PackageIntegrity.ps1')
        { Import-Module (Join-Path $script:Fixture 'MessageTraceReport.psd1') -Force -ErrorAction Stop } | Should -Throw -ExpectedMessage '*Package integrity:*'
    }
    It 'does not run a verifier that lacks the owner signature, even from an otherwise correct package' {
        # The fixture verifier is unsigned: the module and the entry script must refuse it instead of executing it.
        { Import-Module (Join-Path $script:Fixture 'MessageTraceReport.psd1') -Force -ErrorAction Stop } | Should -Throw -ExpectedMessage '*owner signature*'
        $run = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-MessageTraceReport.ps1')' -Mode Status -DevelopmentMode; 'EXIT=' + `$LASTEXITCODE")
        $run.Text | Should -Match 'owner signature'
    }
    It 'reaches the configuration check with -DevelopmentMode and a missing or empty configuration, without a Package integrity message' {
        Reset-Fixture -Source
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'PackageIntegrity.psd1')
        $empty = Join-Path $TestDrive 'empty.config.psd1'
        Set-Content -LiteralPath $empty -Value '@{}'
        foreach ($config in (Join-Path $TestDrive 'missing.psd1'), $empty) {
            $run = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-MessageTraceReport.ps1')' -Mode Status -DevelopmentMode -ConfigPath '$config' 3>`$null; 'EXIT=' + `$LASTEXITCODE")
            $run.Text | Should -Match 'Configuration file not found|Tenant\.TenantId is required'
            $run.Text | Should -Not -Match 'Package integrity:'
        }
    }    It 'accepts an unverified source checkout only with -DevelopmentMode' {
        Reset-Fixture -Source
        Remove-Item -LiteralPath (Join-Path $script:Fixture 'PackageIntegrity.psd1')
        $plain = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-MessageTraceReport.ps1')' -Mode Status; 'EXIT=' + `$LASTEXITCODE")
        $plain.Text | Should -Match 'PackageIntegrity.psd1 is missing\. Download the release ZIP again .*releases/latest.*-DevelopmentMode'
        $development = Invoke-Child ("& '$(Join-Path $script:Fixture 'Invoke-MessageTraceReport.ps1')' -Mode Status -DevelopmentMode 3>&1 | Out-String")
        $development.Text | Should -Match 'DevelopmentMode: no package manifest'
        # One warning per process: the module does not repeat it at import or engine initialization.
        ([regex]::Matches($development.Text, 'no package manifest|no PackageIntegrity\.psd1')).Count | Should -Be 1
    }
}

Describe 'Engine compilation' {
    It 'compiles the verified sources in memory: no compiled assembly is written to or loaded from the disk' {
        $root = Join-Path $TestDrive 'engine-package'
        Copy-Item -LiteralPath $script:Source -Destination $root -Recurse
        # A planted assembly in bin\ must be ignored, whatever its name.
        $bin = Join-Path $root 'bin'
        [void][IO.Directory]::CreateDirectory($bin)
        Set-Content -LiteralPath (Join-Path $bin 'MessageTraceReport.Engine.0000000000000000.dll') -Value 'not an assembly'
        $before = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object FullName)
        $command = "Import-Module '$root\MessageTraceReport.psd1' -Force 3>`$null; Initialize-MtrEngine -Root '$root'; `$a = [MessageTraceReport.Store].Assembly; 'LOCATION=[' + `$a.Location + ']'"
        $run = Invoke-Child $command
        $run.Text | Should -Match 'LOCATION=\[\]'
        $after = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object FullName)
        @($after | Where-Object { $_ -notin $before }) | Should -BeNullOrEmpty
        Get-ChildItem -LiteralPath $root -Recurse -Filter '*.dll' | Where-Object { $_.FullName -notlike '*\lib\sqlite\*' -and $_.FullName -notlike "$bin\*" } | Should -BeNullOrEmpty
    }
}
Describe 'Documentation' {
    It 'regenerates the HTML guides from their Markdown sources without a difference' {
        foreach ($name in 'MessageTraceReport-UserGuide', 'MessageTraceReport-Guide') {
            $target = Join-Path $TestDrive "$name.html"
            & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'tools\Build-Documentation.ps1') -Source (Join-Path $script:Source "docs\$name.md") -Destination $target | Out-Null
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:Source "docs\$name.html") -Algorithm SHA256).Hash -Because $name
        }
    }
}

Describe 'Owner signatures' -Tag 'RealSignature' {
    BeforeAll {
        $script:Release = $env:MTR_RELEASE_PACKAGE
        $script:Skip = (-not $script:Release) -or (-not (Test-Path -LiteralPath (Join-Path $script:Release 'PackageIntegrity.psd1')))
        $script:SkipReason = 'MTR_RELEASE_PACKAGE names no sealed release package folder (New-MtrPackage.ps1 -Seal)'
    }
    It 'requires valid timestamped owner signatures on the PowerShell files and the manifest' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $names = @((Import-PowerShellDataFile (Join-Path $script:Release 'PackageIntegrity.psd1')).Files.Path | Where-Object { $_ -match '\.ps(m1|d1|1)$' }) + 'PackageIntegrity.psd1'
        $names.Count | Should -BeGreaterThan 10
        foreach ($name in $names) {
            $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $script:Release $name)
            [string]$signature.Status | Should -Be 'Valid' -Because $name
            $signature.SignerCertificate.Thumbprint | Should -BeExactly '0F28E442889F17B5F4D251E8F96E7CC6E2C9C6D6'
            $signature.TimeStamperCertificate | Should -Not -BeNullOrEmpty
        }
    }
    It 'accepts the sealed package with the real verifier' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        (& (Join-Path $script:Release 'src\Test-PackageIntegrity.ps1') -Root $script:Release -Distribution).Status | Should -Be 'Valid'
    }
    It 'accepts the committed package with the real verifier' {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Source 'PackageIntegrity.psd1'))) { Set-ItResult -Skipped -Because 'package\PackageIntegrity.psd1 is not committed (before signing)'; return }
        (& (Join-Path $script:Source 'src\Test-PackageIntegrity.ps1') -Root $script:Source).Status | Should -Be 'Valid (files only)'
    }
    It 'rejects a cryptographically valid manifest with its timestamp removed' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs
        $copy = Join-Path $TestDrive 'real-timestamp'
        Copy-Item -LiteralPath $script:Release -Destination $copy -Recurse
        $path = Join-Path $copy 'PackageIntegrity.psd1'
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        $text = $encoding.GetString([IO.File]::ReadAllBytes($path))
        $match = [regex]::Match($text, '(?ms)^# SIG # Begin signature block\r?\n(?<Data>.*?)^# SIG # End signature block\r?\n?\z')
        $match.Success | Should -BeTrue
        $cms = [Security.Cryptography.Pkcs.SignedCms]::new()
        $cms.Decode([Convert]::FromBase64String((($match.Groups['Data'].Value -replace '(?m)^#\s?', '') -replace '\s', '')))
        foreach ($attribute in @($cms.SignerInfos[0].UnsignedAttributes)) {
            foreach ($value in $attribute.Values) {
                $cms.SignerInfos[0].RemoveUnsignedAttribute([Security.Cryptography.AsnEncodedData]::new($attribute.Oid, $value.RawData))
            }
        }
        $base64 = [Convert]::ToBase64String($cms.Encode())
        $lines = for ($i = 0; $i -lt $base64.Length; $i += 64) { '# ' + $base64.Substring($i, [Math]::Min(64, $base64.Length - $i)) }
        [IO.File]::WriteAllBytes($path, $encoding.GetBytes($text.Substring(0, $match.Index) +
            "# SIG # Begin signature block`r`n" + ($lines -join "`r`n") + "`r`n# SIG # End signature block`r`n"))
        [string](Get-AuthenticodeSignature -LiteralPath $path).Status | Should -Be 'Valid'
        (Get-AuthenticodeSignature -LiteralPath $path).TimeStamperCertificate | Should -BeNullOrEmpty
        { & (Join-Path $copy 'src\Test-PackageIntegrity.ps1') -Root $copy -Distribution } | Should -Throw -ExpectedMessage '*expected trusted, timestamped owner signature*'
    }
    It 'rejects an altered manifest and a copy with one changed byte' {
        if ($script:Skip) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $copy = Join-Path $TestDrive 'real-signature'
        Copy-Item -LiteralPath $script:Release -Destination $copy -Recurse
        [IO.File]::AppendAllBytes((Join-Path $copy 'src\Engine.Route.cs'), [byte[]](32))
        { & (Join-Path $copy 'src\Test-PackageIntegrity.ps1') -Root $copy -Distribution } | Should -Throw -ExpectedMessage '*SHA256 mismatch*'
        Copy-Item -LiteralPath (Join-Path $script:Release 'src\Engine.Route.cs') -Destination (Join-Path $copy 'src\Engine.Route.cs') -Force
        $path = Join-Path $copy 'PackageIntegrity.psd1'
        [IO.File]::WriteAllText($path, "# Changed`r`n" + [IO.File]::ReadAllText($path), [Text.UTF8Encoding]::new($true))
        { & (Join-Path $copy 'src\Test-PackageIntegrity.ps1') -Root $copy -Distribution } | Should -Throw -ExpectedMessage '*expected trusted, timestamped owner signature*'
    }
}
