Option Explicit

If WScript.Arguments.Count < 2 Then
    WScript.Quit 2
End If

Dim shell, command, exitCode
Set shell = CreateObject("WScript.Shell")
command = """" & WScript.Arguments(0) & """ """ & WScript.Arguments(1) & """ --daemon"
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
