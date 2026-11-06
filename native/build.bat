@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

set ROOT=%~dp0..
set OUT=%ROOT%\build
if not exist "%OUT%" mkdir "%OUT%"

cl /nologo /std:c++17 /O2 /MT /EHsc /W3 /utf-8 /I"%ROOT%\third_party\prism\include" ^
   /Fo"%OUT%\\" /Fe"%OUT%\ffrs_speech.dll" /LD "%~dp0ffrs_speech.cpp" ole32.lib winmm.lib || exit /b 1

cl /nologo /std:c++17 /O2 /MT /W3 /utf-8 /D_CRT_SECURE_NO_WARNINGS ^
   /Fo"%OUT%\\" /Fe"%OUT%\speak_test.exe" "%~dp0speak_test.cpp" || exit /b 1

copy /y "%ROOT%\third_party\prism\bin\prism.dll" "%OUT%\" >nul
echo Build OK
