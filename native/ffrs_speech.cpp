// Sprachbruecke zwischen UE4SS-Lua und Prism.
//
// UE4SS exportiert keine Lua-C-API, daher ist ein klassisches Lua-C-Modul nicht moeglich.
// Lua laedt diese DLL per package.loadlib und schreibt danach Zeilen in eine Named Pipe:
//   <Prioritaet><UTF-8-Text>\n     Prioritaet: '1' = unterbricht, '0' = reiht sich ein
//   T<Note>[,<Note>...]\n     spielt leise Toene nacheinander
//     Note: <Hertz>:<Millisekunden>[:<Balance -1 links bis 1 rechts>[:<Lautstaerke, 1 = normal>]]
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmsystem.h>
#include <objbase.h>

#include <prism.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

const wchar_t kPipeName[] = L"\\\\.\\pipe\\ffrs_speech";
constexpr DWORD kPipeBufferSize = 64 * 1024;

decltype(&prism_config_init) p_config_init;
decltype(&prism_init) p_init;
decltype(&prism_registry_acquire_best) p_acquire_best;
decltype(&prism_backend_initialize) p_backend_initialize;
decltype(&prism_backend_output) p_backend_output;
decltype(&prism_error_string) p_error_string;

std::wstring g_dir;
HANDLE g_pipe = INVALID_HANDLE_VALUE;
FILE *g_log = nullptr;

void Log(const char *format, const char *a = "", const char *b = "") {
  if (!g_log) return;
  SYSTEMTIME t;
  GetLocalTime(&t);
  fprintf(g_log, "[%02d:%02d:%02d.%03d] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
  fprintf(g_log, format, a, b);
  fputc('\n', g_log);
  fflush(g_log);
}

std::wstring OwnDirectory() {
  HMODULE self = nullptr;
  GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                     reinterpret_cast<LPCWSTR>(&OwnDirectory), &self);
  wchar_t path[MAX_PATH * 4];
  DWORD length = GetModuleFileNameW(self, path, static_cast<DWORD>(std::size(path)));
  std::wstring result(path, length);
  return result.substr(0, result.find_last_of(L'\\'));
}

// Lua 5.4 laedt ohne LOAD_WITH_ALTERED_SEARCH_PATH, deshalb wuerde eine feste
// Abhaengigkeit auf prism.dll im Mod-Ordner nicht gefunden.
bool LoadPrism() {
  std::wstring path = g_dir + L"\\prism.dll";
  HMODULE prism = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (!prism) {
    Log("prism.dll konnte nicht geladen werden");
    return false;
  }
  bool ok = true;
  auto resolve = [&](auto &target, const char *name) {
    target = reinterpret_cast<std::remove_reference_t<decltype(target)>>(GetProcAddress(prism, name));
    if (!target) {
      Log("Prism-Funktion fehlt: %s", name);
      ok = false;
    }
  };
  resolve(p_config_init, "prism_config_init");
  resolve(p_init, "prism_init");
  resolve(p_acquire_best, "prism_registry_acquire_best");
  resolve(p_backend_initialize, "prism_backend_initialize");
  resolve(p_backend_output, "prism_backend_output");
  resolve(p_error_string, "prism_error_string");
  return ok;
}

PrismBackend *CreateBackend() {
  if (!LoadPrism()) return nullptr;
  PrismConfig config = p_config_init();
  PrismContext *context = p_init(&config);
  if (!context) {
    Log("prism_init fehlgeschlagen");
    return nullptr;
  }
  PrismBackend *backend = p_acquire_best(context);
  if (!backend) {
    Log("Kein Prism-Backend verfuegbar");
    return nullptr;
  }
  PrismError error = p_backend_initialize(backend);
  if (error != PRISM_OK && error != PRISM_ERROR_ALREADY_INITIALIZED) {
    Log("prism_backend_initialize: %s", p_error_string(error));
    return nullptr;
  }
  Log("Prism bereit");
  return backend;
}

constexpr int kSampleRate = 44100;
constexpr double kToneVolume = 0.16;
constexpr double kAttackSeconds = 0.006;
constexpr double kDecayRate = 3.5;
constexpr double kOvertone = 0.2;

// Sinus mit weichem Einsatz und Ausklingen, klingt wie eine leise Glocke statt wie ein Piepser.
void AppendNote(std::vector<int16_t> &samples, double hertz, double seconds, double balance, double volume) {
  const double pi = 3.14159265358979323846;
  const int count = static_cast<int>(seconds * kSampleRate);
  const double left = std::min(1.0, 1.0 - balance) * volume;
  const double right = std::min(1.0, 1.0 + balance) * volume;
  for (int i = 0; i < count; ++i) {
    const double t = static_cast<double>(i) / kSampleRate;
    const double attack = t < kAttackSeconds ? t / kAttackSeconds : 1.0;
    const double progress = static_cast<double>(i) / count;
    // Der letzte Abschnitt laeuft auf null aus, damit am Notenende kein Knacken entsteht.
    const double release = progress > 0.9 ? (1.0 - progress) / 0.1 : 1.0;
    const double envelope = attack * release * std::exp(-kDecayRate * progress);
    const double wave = std::sin(2 * pi * hertz * t) + kOvertone * std::sin(4 * pi * hertz * t);
    const double sample = wave * envelope * kToneVolume * 32767 / (1.0 + kOvertone);
    samples.push_back(static_cast<int16_t>(sample * left));
    samples.push_back(static_cast<int16_t>(sample * right));
  }
}

std::vector<char> BuildWave(const std::string &notes) {
  std::vector<int16_t> samples;
  size_t position = 0;
  while (position < notes.size()) {
    size_t end = notes.find(',', position);
    if (end == std::string::npos) end = notes.size();
    double hertz = 0, balance = 0, volume = 1;
    int milliseconds = 0;
    if (sscanf_s(notes.substr(position, end - position).c_str(), "%lf:%d:%lf:%lf", &hertz, &milliseconds, &balance,
                 &volume) >= 2 &&
        hertz > 0 && milliseconds > 0 && milliseconds <= 2000) {
      AppendNote(samples, hertz, milliseconds / 1000.0, std::clamp(balance, -1.0, 1.0), std::clamp(volume, 0.0, 2.0));
    }
    position = end + 1;
  }
  const uint32_t data_size = static_cast<uint32_t>(samples.size() * sizeof(int16_t));
  const uint32_t riff_size = 36 + data_size;
  const uint32_t format_size = 16;
  const uint16_t pcm = 1, channels = 2, bits = 16, block_align = 4;
  const uint32_t rate = kSampleRate, byte_rate = kSampleRate * 4;
  std::vector<char> wave;
  auto append = [&wave](const void *source, size_t size) {
    const char *bytes = static_cast<const char *>(source);
    wave.insert(wave.end(), bytes, bytes + size);
  };
  append("RIFF", 4);
  append(&riff_size, 4);
  append("WAVEfmt ", 8);
  append(&format_size, 4);
  append(&pcm, 2);
  append(&channels, 2);
  append(&rate, 4);
  append(&byte_rate, 4);
  append(&block_align, 2);
  append(&bits, 2);
  append("data", 4);
  append(&data_size, 4);
  append(samples.data(), data_size);
  return wave;
}

// Eigener Thread, damit Toene die Sprachausgabe nicht aufhalten.
DWORD WINAPI ToneThread(LPVOID parameter) {
  auto *wave = static_cast<std::vector<char> *>(parameter);
  PlaySoundW(reinterpret_cast<LPCWSTR>(wave->data()), nullptr, SND_MEMORY | SND_SYNC | SND_NODEFAULT);
  delete wave;
  return 0;
}

void PlayTones(const std::string &notes) {
  auto *wave = new std::vector<char>(BuildWave(notes));
  HANDLE thread = CreateThread(nullptr, 0, ToneThread, wave, 0, nullptr);
  if (thread) {
    CloseHandle(thread);
  } else {
    delete wave;
  }
}

void SpeakLine(PrismBackend *backend, const std::string &line) {
  if (line.size() < 2) return;
  if (line[0] == 'T') {
    PlayTones(line.substr(1));
    return;
  }
  bool interrupt = line[0] == '1';
  std::string text = line.substr(1);
  PrismError error = p_backend_output(backend, text.c_str(), interrupt);
  if (error == PRISM_OK) {
    Log("GESPROCHEN: %s", text.c_str());
  } else {
    Log("FEHLER %s bei: %s", p_error_string(error), text.c_str());
  }
}

DWORD WINAPI PipeThread(LPVOID) {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  PrismBackend *backend = CreateBackend();

  std::string pending;
  char buffer[4096];
  for (;;) {
    // ERROR_NO_DATA: Der Client hat schon wieder geschlossen, seine Daten liegen aber noch im Puffer.
    BOOL connected = ConnectNamedPipe(g_pipe, nullptr);
    DWORD connect_error = connected ? ERROR_SUCCESS : GetLastError();
    if (connected || connect_error == ERROR_PIPE_CONNECTED || connect_error == ERROR_NO_DATA) {
      DWORD read = 0;
      while (ReadFile(g_pipe, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
        pending.append(buffer, read);
        size_t newline;
        while ((newline = pending.find('\n')) != std::string::npos) {
          if (backend) SpeakLine(backend, pending.substr(0, newline));
          pending.erase(0, newline + 1);
        }
      }
    }
    DisconnectNamedPipe(g_pipe);
    pending.clear();
  }
}

}  // namespace

// Wird von Lua als lua_CFunction aufgerufen; der lua_State bleibt ungenutzt, 0 = keine Rueckgabewerte.
extern "C" __declspec(dllexport) int ffrs_start(void *) {
  if (g_pipe != INVALID_HANDLE_VALUE) return 0;

  g_dir = OwnDirectory();
  g_log = _wfsopen((g_dir + L"\\ffrs_speech.log").c_str(), L"w", _SH_DENYNO);

  // Die Pipe entsteht schon hier, damit Lua sie direkt nach der Rueckkehr oeffnen kann.
  g_pipe = CreateNamedPipeW(kPipeName, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1,
                            kPipeBufferSize, kPipeBufferSize, 0, nullptr);
  if (g_pipe == INVALID_HANDLE_VALUE) {
    Log("Pipe konnte nicht erstellt werden");
    return 0;
  }
  HANDLE thread = CreateThread(nullptr, 0, PipeThread, nullptr, 0, nullptr);
  if (thread) CloseHandle(thread);
  return 0;
}
