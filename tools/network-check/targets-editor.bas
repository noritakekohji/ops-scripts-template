Attribute VB_Name = "TargetsEditor"
Option Explicit

' ============================================================================
' targets-editor  -  Export "Targets" sheet to network-check targets.lst
'
' Sheet layout (data starts at row 2):
'   A: Enabled   B: Section   C: Host   D: Port   E: Expected   F: Description
'
' Output contract:
'   - UTF-8 without BOM, LF line endings
'   - 4-field format: <host>, <port>, <expected>, <description>
'   - Section change emits a blank line + "# ---- <Section> ----" comment
'   - Only rows with Enabled = "on" are exported. "off" / empty is skipped.
' ============================================================================

Private Const SHEET_NAME As String = "Targets"
Private Const FIRST_DATA_ROW As Long = 2
Private Const COL_ENABLED As Long = 1
Private Const COL_SECTION As Long = 2
Private Const COL_HOST As Long = 3
Private Const COL_PORT As Long = 4
Private Const COL_EXPECTED As Long = 5
Private Const COL_DESC As Long = 6

Public Sub ExportTargets()
    Dim ws As Worksheet
    On Error Resume Next
    Set ws = ThisWorkbook.Worksheets(SHEET_NAME)
    On Error GoTo 0
    If ws Is Nothing Then
        MsgBox "Sheet '" & SHEET_NAME & "' not found.", vbCritical, "targets-editor"
        Exit Sub
    End If

    Dim lastRow As Long
    lastRow = ws.Cells(ws.Rows.Count, COL_HOST).End(xlUp).Row
    If lastRow < FIRST_DATA_ROW Then
        MsgBox "No data rows (row 2 and below are empty).", vbExclamation, "targets-editor"
        Exit Sub
    End If

    Dim errs As String
    errs = ValidateRows(ws, lastRow)
    If Len(errs) > 0 Then
        MsgBox "Validation failed. Fix the highlighted cells:" & vbCrLf & errs, _
               vbCritical, "targets-editor"
        Exit Sub
    End If

    Dim outPath As Variant
    outPath = Application.GetSaveAsFilename( _
        InitialFileName:="targets.lst", _
        FileFilter:="Target list (*.lst),*.lst,All files (*.*),*.*")
    If VarType(outPath) = vbBoolean Then Exit Sub   ' user cancelled

    WriteUtf8NoBomLf CStr(outPath), BuildContent(ws, lastRow)
    MsgBox "Exported: " & outPath, vbInformation, "targets-editor"
End Sub

' Returns "" when all rows are valid; otherwise a CRLF-joined error summary.
' Invalid cells get a light red interior; valid cells are reset.
Private Function ValidateRows(ByVal ws As Worksheet, ByVal lastRow As Long) As String
    Dim r As Long, errs As String
    Dim enabled As String, host As String, port As String, expected As String

    For r = FIRST_DATA_ROW To lastRow
        ws.Range(ws.Cells(r, COL_ENABLED), ws.Cells(r, COL_DESC)).Interior.ColorIndex = xlNone

        If RowHasErrorValue(ws, r) Then
            errs = errs & "Row " & r & ": Cell contains an error value (#N/A etc.)" & vbCrLf
        Else
            enabled = LCase$(Trim$(CStr(ws.Cells(r, COL_ENABLED).Value)))
            host = Trim$(CStr(ws.Cells(r, COL_HOST).Value))
            port = Trim$(CStr(ws.Cells(r, COL_PORT).Value))
            expected = LCase$(Trim$(CStr(ws.Cells(r, COL_EXPECTED).Value)))

            If enabled <> "on" And enabled <> "off" And Len(enabled) > 0 Then
                ws.Cells(r, COL_ENABLED).Interior.Color = RGB(255, 200, 200)
                errs = errs & "Row " & r & ": Enabled must be on / off / (empty)" & vbCrLf
            End If

            If Len(host) = 0 Then
                ws.Cells(r, COL_HOST).Interior.Color = RGB(255, 200, 200)
                errs = errs & "Row " & r & ": Host is empty" & vbCrLf
            ElseIf InStr(host, ",") > 0 Then
                ws.Cells(r, COL_HOST).Interior.Color = RGB(255, 200, 200)
                errs = errs & "Row " & r & ": Host must not contain ','" & vbCrLf
            End If

            If Not IsValidPort(port) Then
                ws.Cells(r, COL_PORT).Interior.Color = RGB(255, 200, 200)
                errs = errs & "Row " & r & ": Port must be 1-65535 or '-'" & vbCrLf
            End If

            If expected <> "ok" And expected <> "ng" And expected <> "-" And Len(expected) > 0 Then
                ws.Cells(r, COL_EXPECTED).Interior.Color = RGB(255, 200, 200)
                errs = errs & "Row " & r & ": Expected must be ok / ng / -" & vbCrLf
            End If
        End If
    Next r

    ValidateRows = errs
End Function

' True when any cell in COL_ENABLED..COL_DESC holds an error value (#N/A etc.).
' Offending cells are highlighted; CStr on such a value raises error 13.
Private Function RowHasErrorValue(ByVal ws As Worksheet, ByVal r As Long) As Boolean
    Dim c As Long
    For c = COL_ENABLED To COL_DESC
        If IsError(ws.Cells(r, c).Value) Then
            ws.Cells(r, c).Interior.Color = RGB(255, 200, 200)
            RowHasErrorValue = True
        End If
    Next c
End Function

' Strict: empty or '-' (ping-only), or digits 0-9 only within 1-65535.
' IsNumeric is NOT used: it accepts "1,000" / "1e3" which would corrupt
' the 4-field output format.
Private Function IsValidPort(ByVal port As String) As Boolean
    Dim i As Long, ch As String
    If port = "-" Or Len(port) = 0 Then
        IsValidPort = True
        Exit Function
    End If
    For i = 1 To Len(port)
        ch = Mid$(port, i, 1)
        If ch < "0" Or ch > "9" Then
            IsValidPort = False
            Exit Function
        End If
    Next i
    If Len(port) > 5 Then
        IsValidPort = False
    Else
        IsValidPort = (CLng(port) >= 1 And CLng(port) <= 65535)
    End If
End Function

' Builds the full file content. Lines are joined with LF only.
' Rows with Enabled <> "on" (case-insensitive) are skipped entirely; their
' Section is treated as if it did not exist.
Private Function BuildContent(ByVal ws As Worksheet, ByVal lastRow As Long) As String
    Dim sb As String, r As Long
    Dim enabled As String, section As String, prevSection As String
    Dim host As String, port As String, expected As String, desc As String

    sb = "# Network connectivity check target list" & vbLf & _
         "# Generated by targets-editor.xlsm (only Enabled=on rows are included)" & vbLf & _
         "#" & vbLf & _
         "# 4-field format: <host>, <port>, <expected>, <description>" & vbLf & _
         "#   expected: ok (expect reachable) / ng (expect unreachable) / - (no eval)" & vbLf & _
         "#   port:     TCP port number, or '-' for ping-only" & vbLf

    prevSection = Chr$(0)   ' sentinel: never equals a real section
    For r = FIRST_DATA_ROW To lastRow
        enabled = LCase$(Trim$(CStr(ws.Cells(r, COL_ENABLED).Value)))
        host = Trim$(CStr(ws.Cells(r, COL_HOST).Value))
        If enabled = "on" And Len(host) > 0 Then
            section = Trim$(CStr(ws.Cells(r, COL_SECTION).Value))
            port = Trim$(CStr(ws.Cells(r, COL_PORT).Value))
            expected = LCase$(Trim$(CStr(ws.Cells(r, COL_EXPECTED).Value)))
            desc = Trim$(CStr(ws.Cells(r, COL_DESC).Value))
            If Len(port) = 0 Then port = "-"
            If Len(expected) = 0 Then expected = "-"

            If section <> prevSection Then
                sb = sb & vbLf
                If Len(section) > 0 Then
                    sb = sb & "# ---- " & section & " ----" & vbLf
                End If
                prevSection = section
            End If
            sb = sb & host & ", " & port & ", " & expected & ", " & desc & vbLf
        End If
    Next r

    BuildContent = sb
End Function

' Writes content as UTF-8 WITHOUT BOM. ADODB's utf-8 charset always writes a
' 3-byte BOM, so re-read the text stream as binary from position 3 and save.
Private Sub WriteUtf8NoBomLf(ByVal filePath As String, ByVal content As String)
    Dim textStream As Object, binStream As Object
    Set textStream = CreateObject("ADODB.Stream")
    textStream.Type = 2                 ' adTypeText
    textStream.Charset = "utf-8"
    textStream.Open
    textStream.WriteText content

    textStream.Position = 0
    textStream.Type = 1                 ' adTypeBinary
    textStream.Position = 3             ' skip BOM (EF BB BF)

    Set binStream = CreateObject("ADODB.Stream")
    binStream.Type = 1
    binStream.Open
    textStream.CopyTo binStream
    binStream.SaveToFile filePath, 2    ' adSaveCreateOverWrite
    binStream.Close
    textStream.Close
End Sub
