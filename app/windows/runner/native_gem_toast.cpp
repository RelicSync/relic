#include "native_gem_toast.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace {

constexpr wchar_t kToastClassName[] = L"RelicNativeGemToast";
constexpr UINT_PTR kTimerId = 1;
constexpr int kTimerMs = 16;
constexpr double kDurationMs = 1150.0;
constexpr double kPi = 3.14159265358979323846;

struct ToastState {
  HWND hwnd = nullptr;
  ULONGLONG start_ms = 0;
  int width = 112;
  int height = 112;
  double scale = 1.0;
};

ToastState* g_active_toast = nullptr;

double Clamp01(double v) {
  return std::clamp(v, 0.0, 1.0);
}

double EaseOutCubic(double v) {
  v = Clamp01(v);
  const double inv = 1.0 - v;
  return 1.0 - inv * inv * inv;
}

double EaseInCubic(double v) {
  v = Clamp01(v);
  return v * v * v;
}

double EaseInOutCubic(double v) {
  v = Clamp01(v);
  return v < 0.5 ? 4.0 * v * v * v
                 : 1.0 - std::pow(-2.0 * v + 2.0, 3.0) / 2.0;
}

double EaseOutBack(double v) {
  v = Clamp01(v);
  constexpr double c1 = 1.70158;
  constexpr double c3 = c1 + 1.0;
  return 1.0 + c3 * std::pow(v - 1.0, 3.0) + c1 * std::pow(v - 1.0, 2.0);
}

uint32_t PremulArgb(int r, int g, int b, int a) {
  a = std::clamp(a, 0, 255);
  r = std::clamp((r * a + 127) / 255, 0, 255);
  g = std::clamp((g * a + 127) / 255, 0, 255);
  b = std::clamp((b * a + 127) / 255, 0, 255);
  return (static_cast<uint32_t>(a) << 24) |
         (static_cast<uint32_t>(r) << 16) |
         (static_cast<uint32_t>(g) << 8) |
         static_cast<uint32_t>(b);
}

void BlendPremul(uint32_t* dst, int r, int g, int b, int a) {
  if (a <= 0) {
    return;
  }
  const uint32_t src = PremulArgb(r, g, b, a);
  const int sa = (src >> 24) & 0xff;
  const int sr = (src >> 16) & 0xff;
  const int sg = (src >> 8) & 0xff;
  const int sb = src & 0xff;

  const uint32_t old = *dst;
  const int da = (old >> 24) & 0xff;
  const int dr = (old >> 16) & 0xff;
  const int dg = (old >> 8) & 0xff;
  const int db = old & 0xff;
  const int inv = 255 - sa;

  const int oa = sa + (da * inv + 127) / 255;
  const int outr = sr + (dr * inv + 127) / 255;
  const int outg = sg + (dg * inv + 127) / 255;
  const int outb = sb + (db * inv + 127) / 255;
  *dst = (static_cast<uint32_t>(oa) << 24) |
         (static_cast<uint32_t>(outr) << 16) |
         (static_cast<uint32_t>(outg) << 8) |
         static_cast<uint32_t>(outb);
}

struct PointD {
  double x;
  double y;
};

constexpr std::array<PointD, 5> kGemPath = {{
    {5.0, 4.0},
    {19.0, 4.0},
    {21.5, 9.0},
    {12.0, 21.0},
    {2.5, 9.0},
}};

constexpr std::array<std::array<PointD, 2>, 7> kFacetLines = {{
    {{{2.5, 9.0}, {21.5, 9.0}}},
    {{{9.0, 4.0}, {8.0, 9.0}}},
    {{{8.0, 9.0}, {12.0, 21.0}}},
    {{{15.0, 4.0}, {16.0, 9.0}}},
    {{{16.0, 9.0}, {12.0, 21.0}}},
    {{{5.0, 4.0}, {8.0, 9.0}}},
    {{{19.0, 4.0}, {16.0, 9.0}}},
}};

bool IsInsideGemPath(PointD p) {
  bool inside = false;
  for (size_t i = 0, j = kGemPath.size() - 1; i < kGemPath.size(); j = i++) {
    const PointD a = kGemPath[i];
    const PointD b = kGemPath[j];
    const bool crosses = ((a.y > p.y) != (b.y > p.y)) &&
                         (p.x < (b.x - a.x) * (p.y - a.y) /
                                    (b.y - a.y + 0.0000001) +
                                a.x);
    if (crosses) {
      inside = !inside;
    }
  }
  return inside;
}

double DistToSegment(PointD p, PointD a, PointD b) {
  const double vx = b.x - a.x;
  const double vy = b.y - a.y;
  const double wx = p.x - a.x;
  const double wy = p.y - a.y;
  const double len2 = vx * vx + vy * vy;
  const double t = len2 <= 0.0 ? 0.0 : std::clamp((wx * vx + wy * vy) / len2, 0.0, 1.0);
  const double dx = p.x - (a.x + t * vx);
  const double dy = p.y - (a.y + t * vy);
  return std::sqrt(dx * dx + dy * dy);
}

double DistToGemOutline(PointD p) {
  double best = 1000.0;
  for (size_t i = 0; i < kGemPath.size(); ++i) {
    const PointD a = kGemPath[i];
    const PointD b = kGemPath[(i + 1) % kGemPath.size()];
    best = std::min(best, DistToSegment(p, a, b));
  }
  return best;
}

void DrawGem(uint32_t* pixels,
             int width,
             int height,
             double t,
             double dpi_scale) {
  const double pop = EaseOutBack(t / 0.28);
  const double scale = 0.60 + 0.40 * pop;
  const double up = EaseOutCubic(t / 0.42);
  const double down = EaseInCubic((t - 0.50) / 0.50);
  const double jump = std::max(0.0, up - down) * 17.0 * dpi_scale;
  const double spin = EaseInOutCubic((t - 0.16) / 0.76) * 2.0 * kPi;
  const double width_spin = 0.22 + 0.78 * std::abs(std::cos(spin));
  const double fade_in = EaseOutCubic(t / 0.12);
  const double fade_out = 1.0 - EaseInCubic((t - 0.82) / 0.18);
  const double opacity = Clamp01(fade_in * fade_out);

  const double cx = width / 2.0;
  const double cy = height / 2.0 - jump;
  const double mark_size = 54.0 * dpi_scale * scale;
  const double unit_x = mark_size / 24.0 * width_spin;
  const double unit_y = mark_size / 24.0;

  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const double px = x + 0.5;
      const double py = y + 0.5;
      uint32_t* dst = pixels + y * width + x;

      const PointD p = {
          12.0 + (px - cx) / std::max(0.001, unit_x),
          12.0 + (py - cy) / std::max(0.001, unit_y),
      };
      const double outline = DistToGemOutline(p);
      if (!IsInsideGemPath(p) && outline < 3.0) {
        const double glow = std::pow(Clamp01((3.0 - outline) / 3.0), 2.0);
        BlendPremul(dst, 218, 164, 62,
                    static_cast<int>(34.0 * glow * opacity));
      }

      constexpr std::array<PointD, 4> samples = {{
          {-0.25, -0.25},
          {0.25, -0.25},
          {-0.25, 0.25},
          {0.25, 0.25},
      }};
      int covered = 0;
      for (const PointD sample : samples) {
        const PointD sp = {
            12.0 + (px + sample.x - cx) / std::max(0.001, unit_x),
            12.0 + (py + sample.y - cy) / std::max(0.001, unit_y),
        };
        if (IsInsideGemPath(sp)) {
          ++covered;
        }
      }
      if (covered == 0) {
        continue;
      }

      const double edge = covered / 4.0;
      const double top_light = Clamp01((21.0 - p.y) / 17.0);
      const bool left = px < cx;
      const bool top = p.y < 9.0;
      int r = 218;
      int g = 164;
      int b = 62;
      if (top) {
        r += 22;
        g += 18;
        b += 8;
      }
      if (left) {
        r -= 12;
        g -= 10;
      }
      r = static_cast<int>(r + 28.0 * top_light);
      g = static_cast<int>(g + 22.0 * top_light);
      b = static_cast<int>(b + 10.0 * top_light);
      BlendPremul(dst, r, g, b, static_cast<int>(235.0 * edge * opacity));

      double facet_dist = 1000.0;
      for (const auto& line : kFacetLines) {
        facet_dist = std::min(facet_dist, DistToSegment(p, line[0], line[1]));
      }
      const double facet_width = 0.42;
      if (facet_dist < facet_width) {
        const double facet_alpha = Clamp01((facet_width - facet_dist) / facet_width);
        BlendPremul(dst, 255, 239, 196,
                    static_cast<int>(38.0 * facet_alpha * edge * opacity));
      }
    }
  }
}

bool RenderToastFrame(ToastState* state) {
  const ULONGLONG now = GetTickCount64();
  const double elapsed = static_cast<double>(now - state->start_ms);
  if (elapsed >= kDurationMs) {
    return false;
  }
  const double t = elapsed / kDurationMs;

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = state->width;
  bmi.bmiHeader.biHeight = -state->height;  // top-down DIB
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HDC screen_dc = GetDC(nullptr);
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  HBITMAP bitmap = CreateDIBSection(screen_dc, &bmi, DIB_RGB_COLORS, &bits,
                                    nullptr, 0);
  if (!bitmap || !bits) {
    if (bitmap) {
      DeleteObject(bitmap);
    }
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old_bitmap = SelectObject(mem_dc, bitmap);
  auto* pixels = static_cast<uint32_t*>(bits);
  std::fill(pixels, pixels + state->width * state->height, 0);
  DrawGem(pixels, state->width, state->height, t, state->scale);

  POINT src = {0, 0};
  RECT rect{};
  GetWindowRect(state->hwnd, &rect);
  POINT dst = {rect.left, rect.top};
  SIZE size = {state->width, state->height};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;

  UpdateLayeredWindow(state->hwnd, screen_dc, &dst, &size, mem_dc, &src, 0,
                      &blend, ULW_ALPHA);

  SelectObject(mem_dc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  return true;
}

LRESULT CALLBACK ToastWndProc(HWND hwnd,
                              UINT message,
                              WPARAM wparam,
                              LPARAM lparam) {
  auto* state =
      reinterpret_cast<ToastState*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  switch (message) {
    case WM_NCCREATE: {
      auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
      SetWindowLongPtr(hwnd, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(create->lpCreateParams));
      return TRUE;
    }
    case WM_TIMER:
      if (state && !RenderToastFrame(state)) {
        DestroyWindow(hwnd);
      }
      return 0;
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_DESTROY:
      KillTimer(hwnd, kTimerId);
      if (state) {
        if (g_active_toast == state) {
          g_active_toast = nullptr;
        }
        delete state;
      }
      return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

void EnsureToastClassRegistered() {
  static bool registered = false;
  if (registered) {
    return;
  }

  WNDCLASS wc{};
  wc.lpfnWndProc = ToastWndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kToastClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClass(&wc);
  registered = true;
}

RECT CursorMonitorWorkArea() {
  POINT cursor{};
  GetCursorPos(&cursor);
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfo(monitor, &info)) {
    return info.rcWork;
  }
  RECT fallback{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &fallback, 0);
  return fallback;
}

double DpiScaleForOwner(HWND owner) {
  if (!owner) {
    return 1.0;
  }
  using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
  HMODULE user32 = GetModuleHandleA("User32.dll");
  auto get_dpi_for_window = user32
                                ? reinterpret_cast<GetDpiForWindowFn>(
                                      GetProcAddress(user32, "GetDpiForWindow"))
                                : nullptr;
  const UINT dpi = get_dpi_for_window ? get_dpi_for_window(owner) : 96;
  return std::clamp(static_cast<double>(dpi) / 96.0, 0.85, 2.0);
}

}  // namespace

bool ShowNativeGemToast(HWND owner) {
  EnsureToastClassRegistered();

  if (g_active_toast && g_active_toast->hwnd) {
    DestroyWindow(g_active_toast->hwnd);
  }

  auto* state = new ToastState();
  state->scale = DpiScaleForOwner(owner);
  state->width = static_cast<int>(112.0 * state->scale);
  state->height = static_cast<int>(112.0 * state->scale);

  const RECT work = CursorMonitorWorkArea();
  const int x = work.left + ((work.right - work.left) - state->width) / 2;
  const int y = work.bottom - state->height - static_cast<int>(56 * state->scale);

  HWND hwnd = CreateWindowEx(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
          WS_EX_TOPMOST | WS_EX_NOACTIVATE,
      kToastClassName, L"Relic gem", WS_POPUP, x, y, state->width,
      state->height, nullptr, nullptr, GetModuleHandle(nullptr), state);

  if (!hwnd) {
    delete state;
    return false;
  }

  state->hwnd = hwnd;
  state->start_ms = GetTickCount64();
  g_active_toast = state;

  RenderToastFrame(state);
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  SetTimer(hwnd, kTimerId, kTimerMs, nullptr);
  return true;
}
