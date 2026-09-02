#include "native_gem_toast.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

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

// --- The Relic mark ---------------------------------------------------------
//
// The gold shard, transcribed from `lib/widgets/relic_mark.dart`, which took it
// from `logo-mark.svg`. The control points below are that path's, verbatim, so
// the two files can be diffed against each other and stay in step.
//
// What used to be here was the old faceted gem: five points in a 24x24 box,
// seven facet lines and a glow behind it. It survived the 2026 restyle because
// it lives in C++ rather than in the widget tree, so it is not what anyone
// greps for when they change the mark. The file name and the `showGemToast`
// channel are vestigial and deliberately left alone; renaming them would break
// the Dart side for nothing.
constexpr double kMarkVw = 148.0;
constexpr double kMarkVh = 150.0;

// A cubic runs from the previous point through c1 and c2 to `to`. A line
// ignores the control points.
struct PathOp {
  bool cubic;
  PointD c1;
  PointD c2;
  PointD to;
};

constexpr PointD kMarkStart = {27.4388, 140.916};

constexpr std::array<PathOp, 12> kMarkOps = {{
    {false, {0, 0}, {0, 0}, {132.709, 140.969}},
    {true, {140.828, 140.973}, {146.838, 133.421}, {145.013, 125.51}},
    {false, {0, 0}, {0, 0}, {121.339, 22.9363}},
    {true, {120.235, 18.1532}, {116.458, 14.4442}, {111.656, 13.4276}},
    {false, {0, 0}, {0, 0}, {80.9218, 6.92219}},
    {true, {76.2452, 5.93228}, {71.4106, 7.66958}, {68.4338, 11.4098}},
    {false, {0, 0}, {0, 0}, {52.6439, 31.2487}},
    {false, {0, 0}, {0, 0}, {20.1246, 72.1069}},
    {false, {0, 0}, {0, 0}, {4.33476, 91.9458}},
    {true, {1.35791, 95.686}, {0.749738, 100.787}, {2.76379, 105.122}},
    {false, {0, 0}, {0, 0}, {15.9997, 133.613}},
    {true, {18.0679, 138.064}, {22.53, 140.913}, {27.4388, 140.916}},
}};

// Every cubic here rounds a corner a few units across, so eight steps already
// puts each segment well under a device pixel at the size this draws.
constexpr int kCubicSteps = 8;

// The outline as a closed polygon in viewBox units, flattened once on first
// use rather than per frame.
const std::vector<PointD>& MarkPolygon() {
  static const std::vector<PointD> poly = [] {
    std::vector<PointD> out;
    out.push_back(kMarkStart);
    for (const PathOp& op : kMarkOps) {
      const PointD from = out.back();
      if (!op.cubic) {
        out.push_back(op.to);
        continue;
      }
      for (int i = 1; i <= kCubicSteps; ++i) {
        const double t = static_cast<double>(i) / kCubicSteps;
        const double u = 1.0 - t;
        out.push_back({
            u * u * u * from.x + 3 * u * u * t * op.c1.x +
                3 * u * t * t * op.c2.x + t * t * t * op.to.x,
            u * u * u * from.y + 3 * u * u * t * op.c1.y +
                3 * u * t * t * op.c2.y + t * t * t * op.to.y,
        });
      }
    }
    return out;
  }();
  return poly;
}

struct Rgb {
  int r;
  int g;
  int b;
};

// The brand gradient, not to be restyled: #FFE24A -> #FFCE06 -> #F2A93B.
//
// The Dart side builds it with LinearGradient's default begin and end, which
// resolve to the centre-left and centre-right of the shader rect it passes.
// So what actually renders is a horizontal ramp from x=30 to x=130 in viewBox
// units, not the diagonal the rect's two corners suggest. Matching what the
// app draws matters more here than matching what its comment says.
constexpr double kGradX0 = 30.0;
constexpr double kGradX1 = 130.0;
constexpr Rgb kGradStops[3] = {{255, 226, 74}, {255, 206, 6}, {242, 169, 59}};

Rgb MarkColorAt(double vx) {
  const double t = Clamp01((vx - kGradX0) / (kGradX1 - kGradX0));
  const bool first_half = t < 0.5;
  const Rgb a = first_half ? kGradStops[0] : kGradStops[1];
  const Rgb b = first_half ? kGradStops[1] : kGradStops[2];
  const double f = first_half ? t * 2.0 : (t - 0.5) * 2.0;
  return {
      static_cast<int>(std::lround(a.r + (b.r - a.r) * f)),
      static_cast<int>(std::lround(a.g + (b.g - a.g) * f)),
      static_cast<int>(std::lround(a.b + (b.b - a.b) * f)),
  };
}

// Vertical resolution of the fill: four sub-scanlines a row.
constexpr int kSubScanlines = 4;

// Accumulate one horizontal span into a row's coverage, with analytic partial
// coverage at both ends so edges land on fractions of a pixel rather than
// snapping to one.
void AddSpan(double* row, int width, double x0, double x1, double weight) {
  x0 = std::max(x0, 0.0);
  x1 = std::min(x1, static_cast<double>(width));
  if (x1 <= x0) {
    return;
  }
  const int first = static_cast<int>(x0);
  const int last = std::min(static_cast<int>(x1), width - 1);
  if (first >= last) {
    row[first] += (x1 - x0) * weight;
    return;
  }
  row[first] += (first + 1 - x0) * weight;
  for (int i = first + 1; i < last; ++i) {
    row[i] += weight;
  }
  row[last] += (x1 - last) * weight;
}

void DrawMark(uint32_t* pixels,
              int width,
              int height,
              double t,
              double dpi_scale) {
  // Timing is copied from the Dart GemToast in lib/widgets/gem_toast.dart so
  // the two read as one animation.
  const double pop = EaseOutBack(t / 0.28);
  const double scale = 0.60 + 0.40 * pop;
  const double up = EaseOutCubic(t / 0.42);
  const double down = EaseInCubic((t - 0.50) / 0.50);
  const double jump = std::max(0.0, up - down) * 17.0 * dpi_scale;
  const double spin = EaseInOutCubic((t - 0.16) / 0.76) * 2.0 * kPi;
  const double fade_in = EaseOutCubic(t / 0.12);
  const double fade_out = 1.0 - EaseInCubic((t - 0.82) / 0.18);
  const double opacity = Clamp01(fade_in * fade_out);
  if (opacity <= 0.0) {
    return;
  }

  // The coin flip, as a horizontal squeeze. Signed, so the mark mirrors once
  // it turns past edge-on the way a real face would; the 0.22 floor keeps a
  // sliver on screen at the crossing instead of blinking out for a frame.
  const double turn = std::cos(spin);
  const double squeeze =
      (0.22 + 0.78 * std::abs(turn)) * (turn < 0.0 ? -1.0 : 1.0);

  // 44 logical pixels tall, matching RelicIcon(size: 44) on the Dart side.
  const double unit_y = 44.0 * dpi_scale * scale / kMarkVh;
  const double unit_x = unit_y * squeeze;
  const double cx = width / 2.0;
  const double cy = height / 2.0 - jump;

  const std::vector<PointD>& outline = MarkPolygon();
  std::vector<PointD> pts(outline.size());
  double min_y = 1e9;
  double max_y = -1e9;
  for (size_t i = 0; i < outline.size(); ++i) {
    pts[i] = {cx + (outline[i].x - kMarkVw / 2.0) * unit_x,
              cy + (outline[i].y - kMarkVh / 2.0) * unit_y};
    min_y = std::min(min_y, pts[i].y);
    max_y = std::max(max_y, pts[i].y);
  }

  const int y0 = std::max(0, static_cast<int>(std::floor(min_y)));
  const int y1 = std::min(height - 1, static_cast<int>(std::ceil(max_y)));
  if (y1 < y0) {
    return;
  }

  // Scanline fill rather than testing every pixel against the polygon. The gem
  // this replaced was five points, so brute force was free; the shard flattens
  // to about forty, and this repaints a layered window at 60fps on the UI
  // thread, which is not the place to spend that.
  std::vector<double> coverage(width);
  std::vector<double> crossings;
  for (int y = y0; y <= y1; ++y) {
    std::fill(coverage.begin(), coverage.end(), 0.0);
    for (int sub = 0; sub < kSubScanlines; ++sub) {
      const double sy = y + (sub + 0.5) / kSubScanlines;
      crossings.clear();
      for (size_t i = 0, j = pts.size() - 1; i < pts.size(); j = i++) {
        const PointD a = pts[j];
        const PointD b = pts[i];
        // Half-open in y, so a vertex exactly on the sub-scanline is counted
        // once rather than twice. Also guarantees b.y != a.y below.
        if ((a.y <= sy) == (b.y <= sy)) {
          continue;
        }
        crossings.push_back(a.x + (sy - a.y) * (b.x - a.x) / (b.y - a.y));
      }
      std::sort(crossings.begin(), crossings.end());
      for (size_t k = 0; k + 1 < crossings.size(); k += 2) {
        AddSpan(coverage.data(), width, crossings[k], crossings[k + 1],
                1.0 / kSubScanlines);
      }
    }

    uint32_t* row = pixels + y * width;
    for (int x = 0; x < width; ++x) {
      const double cov = Clamp01(coverage[x]);
      if (cov <= 0.0) {
        continue;
      }
      // Back through the transform, so the gradient squeezes and mirrors with
      // the face instead of staying pinned to the window.
      const double vx = kMarkVw / 2.0 + (x + 0.5 - cx) / unit_x;
      const Rgb c = MarkColorAt(vx);
      BlendPremul(row + x, c.r, c.g, c.b,
                  static_cast<int>(std::lround(255.0 * cov * opacity)));
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
  DrawMark(pixels, state->width, state->height, t, state->scale);

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
      kToastClassName, L"Relic mark", WS_POPUP, x, y, state->width,
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
