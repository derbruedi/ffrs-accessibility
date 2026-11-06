// Prueft die Sprachbruecke ohne Spiel, mit denselben Schritten wie die Lua-Mod.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdio>
#include <string>

static std::string ToUtf8(const wchar_t *text) {
  int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
  result.resize(size - 1);
  return result;
}

int wmain(int argc, wchar_t **argv) {
  if (argc < 3) {
    fprintf(stderr, "Aufruf: speak_test <ffrs_speech.dll> <text>\n");
    return 2;
  }
  HMODULE bridge = LoadLibraryExW(argv[1], nullptr, 0);
  if (!bridge) {
    fprintf(stderr, "DLL nicht geladen: %lu\n", GetLastError());
    return 1;
  }
  auto start = reinterpret_cast<int (*)(void *)>(GetProcAddress(bridge, "ffrs_start"));
  if (!start) {
    fprintf(stderr, "ffrs_start fehlt\n");
    return 1;
  }
  start(nullptr);

  FILE *pipe = fopen("\\\\.\\pipe\\ffrs_speech", "wb");
  if (!pipe) {
    perror("Pipe");
    return 1;
  }
  fprintf(pipe, "1%s\n", ToUtf8(argv[2]).c_str());
  fflush(pipe);
  fclose(pipe);
  Sleep(3000);
  return 0;
}
