#requires -version 2.0
function Write-Program
{
    <#
    .Synopsis
        Creates an application to run a PowerShell command.
    .Description
        Creates an application to run a PowerShell command.  
        
        The application will wrap any cmdlet and any function stored in a module and create a .exe
        
        The .exe will support all of the same parameters of the core cmdlet.
        
        You can use this to allow users to simply double click a script, rather than making a user import a module manually.
        
        All of the text output from the EXE will be shown when the EXE is complete.  Streaming is not yet supported.
    .Example
        Write-Program -Command Get-Process
        
        .\Get-Process.exe 
        
        .\Get-Process.exe -Name powershell*
    #>
    param(
    # The name of the command you're wrapping
    [Parameter(Mandatory=$true,
        ValueFromPipelineByPropertyName=$true)]
    [Alias('Name')]
    [String]$Command,
    
    # the path the command is outputting to
    [string]$OutputPath,
    
    # If this is set, the command will be a windows application.  
    # It will no longer display help or errors, but PowerShell can continue while it is running
    [switch]$WindowsApplication,
    
    # If set, this will keep the Program Debug Database (PDB file) generated by Add-Type.      
    #
    # Otherwise, this value will be thrown away    
    [switch]$KeepDebugInformation
    )
    
    process {
        $commandName = $command
        $realCommand = Get-Command $commandName | 
            Select-Object -First 1 
        if (-not $realCommand) {
            Write-Error "$command Not Found"
            return
        }        
        if ($realCommand -isnot [Management.Automation.FunctionInfo] -and
            $realCommand -isnot [Management.Automation.CmdletInfo]) {
            Write-Error "Cannot create programs that are not in a module on disk"
            return
        }
        
        if ($realCommand.Module -and -not $realCommand.Module.Path) {
            Write-Error "Cannot create programs that are not in a module on disk"
            return
        }
        
        $namespaces = '
using System;
using System.Collections;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
'

        if ($windowsApplication) {
            $namespaces += '
using System.Windows;
using System.Windows.Controls;
'
        }

        $code = $namespaces + @'

public class Program {
    public static void Main(string[] args) {
        Collection<Object> arguments = PowerShell
            .Create()
            .AddScript(@"
$positionalParameters = New-Object Collections.ObjectModel.Collection[string]
$namedParameters = @{}
$args = @($args)
for ($i =0 ; $i -lt $args.Count; $i++) {
    if ($args[$i] -like '-*') {       
        # Named Value
        if ($args[$i] -like '-*:*') {
            # Coupled Named Value
            $parameter = $args[$i].Substring(1, $args[$i].IndexOf(':') - 1)
            $value = $args[$i].Substring($args[$i].IndexOf(':') + 1)
            $namedParameters[$parameter] = $value
        } elseif ($args[$i + 1] -notlike '-*') {
            # The next argument is the value
            if (-not ($args[$i + 1])) {
                # Really a switch, because there is no additional argument
                $namedParameters[$args[$i].Substring(1)] = $true
            } else {
                $namedParameters[$args[$i].Substring(1)] = $args[$i + 1]
                $i++ # Incremenet $i so we don't end up reusing the value
            }
        } else {
            # Assume Switch        
            $namedParameters[$args[$i].Substring(1)] = $true
        }
    } else {
        # Assume Positional Parameter    
        $positionalParameters.Add($args[$i])
    }
}
$positionalParameters 
$namedParameters")
    .AddParameters(args)
    .Invoke<Object>();    
    
    
    IDictionary namedParameters = null;
    StringCollection positionalParameters = new StringCollection();
    for (int i = 0; i < arguments.Count; i++)
    {
        if (arguments[i] is IDictionary)
        {
            namedParameters = arguments[i] as IDictionary;
        }
        if (arguments[i] is string)
        {
            positionalParameters.Add(arguments[i] as string);
        }
    }    
'@


        $code += @"
        Runspace rs = RunspaceFactory.CreateRunspace();
        rs.ApartmentState = System.Threading.ApartmentState.STA;
        rs.ThreadOptions = PSThreadOptions.ReuseThread;
        rs.Open();

        PowerShell powerShellCommand = PowerShell.Create()
            .AddCommand("Set-ExecutionPolicy")
            .AddParameter("Scope","Process")
            .AddParameter("Force")
            .AddArgument("Bypass");
        powerShellCommand.Runspace = rs;
        powerShellCommand.Invoke();
        powerShellCommand.Dispose();
        

"@    
        # If the command is in a module, we'll want to go ahead and import 
        # it.  Let's not assume it's globally available, and import by absolute path
        if ($realCommand.Module) {
            # Unfortunately, real module path is not always the module path in powershell
            $realModulePath = $realCommand.Module.Path            
            $mayberealPath = Join-Path (Split-Path $realModulePath) "$($realCommand.Module.Name).psd1"
            if ((Test-Path $mayberealPath))  {
                 $realModulePath  = $mayberealPath 
            }
            $code += @"
        powerShellCommand = PowerShell.Create()
               .AddCommand("Import-Module", false)
               .AddArgument("$($mayberealPath.Replace('\','\\'))");
        powerShellCommand.Runspace = rs;      
        try {
            powerShellCommand.Invoke();
            powerShellCommand.Dispose();
        } catch (Exception ex) {
            $(if (-not $WindowsApplication) { 'Console.WriteLine(ex.Message);' })
            $(if ($WindowsApplication) { 'MessageBox.Show(ex.Message);' })
        }
"@

        }
    
        $sma = 'System.Management.Automation, Version=1.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35, ProcessorArchitecture=MSIL'    
        if ($realCommand.PSSnapin -and 
            $realCommand.PSSnapin.AssemblyName -ne $sma) {
            $code += @"
        powerShellCommand = PowerShell.Create()
               .AddCommand("Add-PSSnapin", false)
               .AddArgument("$($realCommand.PSSnapin.Name)");
        powerShellCommand.Runspace = rs;      
        try {
            powerShellCommand.Invoke();
            powerShellCommand.Dispose();
        } catch (Exception ex) {
            Console.WriteLine(ex.Message);
        }
"@        
        }

        $code += @"   
        if (namedParameters.Contains("?")) {
            powerShellCommand = PowerShell.Create()
               .AddCommand("Get-Help")
               .AddArgument("$commandName");            
            powerShellCommand.Runspace = rs;

        } else {
            powerShellCommand = PowerShell.Create()
                .AddCommand("$commandName");
            powerShellCommand.Runspace = rs;

            if (namedParameters != null) {
                powerShellCommand.AddParameters(namedParameters);
            }
                
            if (positionalParameters != null) {
                powerShellCommand.AddParameters(positionalParameters);
            }        
        }                        
        
        try {            
            foreach (string str in PowerShell.Create().AddCommand("Out-String").Invoke<string>(powerShellCommand.Invoke())) {                
                Console.WriteLine(str.Trim(System.Environment.NewLine.ToCharArray()));
            }        
        } catch (Exception ex){
            $(if (-not $WindowsApplication) { 'Console.WriteLine(ex.Message);' })
            $(if ($WindowsApplication) { 'MessageBox.Show(ex.Message);' })
        }        
        
        powerShellCommand.Dispose();
        rs.Close();
        rs.Dispose();
    }
}
"@

            
        # Get the output type
        if ($windowsApplication) {
            $outputType = "windowsApplication"
        } else {
            $outputType = "consoleapplication"   
        }
        
        
        if (-not $outputPath) { $outputPath = ".\$commandName.exe" } 
        
        # resolve the output path
        $unresolvedPath = $psCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath("$outputPath")
        if ($unresolvedPath -notlike '*.exe') {
            Write-Warning '$unresolvedPath is not an .exe'            
        }
        $outputPath = $unresolvedPath 
    
        $addTypeParameters = @{
            TypeDefinition=$code
            Language='CSharpVersion3'
            OutputType=$outputType
            Outputassembly=$outputPath
        }
        
        Write-Verbose "
Application Code:

$Code
"
        
        if ($windowsApplication) {
            $addTypeParameters.ReferencedAssemblies = "PresentationFramework","PresentationCore","WindowsBase"
        }        
        Add-Type @addTypeParameters 
        if (Test-Path $outputPath) {
            $pdbPath = $outputPath.Replace('.exe','.pdb')
            if (-not $KeepDebugInformation) {
                Remove-Item -LiteralPath $pdbPath -ErrorAction SilentlyContinue
            }            
        }
        
        Get-Item -LiteralPath $outputPath -ErrorAction SilentlyContinue

    
    }
}