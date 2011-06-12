﻿function Initialize-EventHandler
{
    param()
    try {
        $resource = Get-Resource
        $parent = Get-ParentControl -ErrorAction SilentlyContinue
    } catch {
        Write-Debug "$_"
    }
    if ($parent) { 
        $namedControls = Get-ChildControl -OutputNamedControl -Control $parent 
        if ($namedControls) { 
            foreach ($nc in $namedControls.GetEnumerator()) {
                Set-Variable -Name $nc.Key -Value $nc.Value                         
            }
        }
        if ($parent.Name) { 
            Set-Variable -Name $parent.Name -Value $parent
        }
        if ($parent.GetValue -and
            $($controlname = $parent.GetValue([ShowUI.ShowUISetting]::ControlNameProperty);$controlName))
        {
            Set-Variable -Name $controlname -Value $parent
            Remove-Variable -Name ControlName
        }
    }
    
    if ($resource) {    
        foreach ($nc in $resource.GetEnumerator()) {
            if ($nc.Key -and 'Scripts', 'Timers', 'EventHandlers' -notcontains $nc.Key) {
                Set-Variable -Name $nc.Key -Value $nc.Value                         
            }        
        }
    }
}
