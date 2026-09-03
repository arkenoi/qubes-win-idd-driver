// wgcprobe (P8 minimal) - WGC broker-viability probe.
// Answers: does GraphicsCaptureSession::IsSupported() activate AND deliver one non-blank
// frame from THIS context? Prints winsta/session/desktop so a SYSTEM/session-0 false
// negative (the 2026-08-01 0x8007000E) is distinguishable from a real 'not supported'.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <inspectable.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>              // IGraphicsCaptureItemInterop
#include <windows.graphics.directx.direct3d11.interop.h>   // CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <mutex>
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "windowsapp.lib")
using namespace winrt;
using namespace winrt::Windows::Graphics;                       // SizeInt32
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;              // DirectXPixelFormat
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;  // IDirect3DDevice/Surface
namespace meta = winrt::Windows::Foundation::Metadata;
static const wchar_t* kSess  = L"Windows.Graphics.Capture.GraphicsCaptureSession";
static const wchar_t* kFrame = L"Windows.Graphics.Capture.Direct3D11CaptureFrame";
static std::string W2U(const wchar_t* w){ if(!w||!*w) return {}; int n=WideCharToMultiByte(CP_UTF8,0,w,-1,nullptr,0,nullptr,nullptr); std::string s(n>1?(size_t)n-1:0,'\0'); if(n>1) WideCharToMultiByte(CP_UTF8,0,w,-1,&s[0],n,nullptr,nullptr); return s; }
static std::string UObj(HANDLE h){ if(!h) return {}; wchar_t b[256]{}; DWORD need=0; if(GetUserObjectInformationW(h,UOI_NAME,b,(DWORD)sizeof(b),&need)) return W2U(b); return {}; }
struct D3D { com_ptr<ID3D11Device> dev; com_ptr<ID3D11DeviceContext> ctx; IDirect3DDevice rt{nullptr}; };
static bool MakeD3D(D3D& d){
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT; // MANDATORY for WGC interop
  if (FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,flags,nullptr,0,D3D11_SDK_VERSION,d.dev.put(),nullptr,d.ctx.put())))
    if (FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,flags,nullptr,0,D3D11_SDK_VERSION,d.dev.put(),nullptr,d.ctx.put())))
      return false;
  com_ptr<IDXGIDevice> dxgi = d.dev.as<IDXGIDevice>();
  com_ptr<::IInspectable> insp;
  if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), insp.put()))) return false;
  d.rt = insp.as<IDirect3DDevice>();
  return true;
}
static GraphicsCaptureItem ItemForWindow(HWND hwnd){
  auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
  GraphicsCaptureItem item{nullptr};
  check_hresult(interop->CreateForWindow(hwnd, guid_of<GraphicsCaptureItem>(),
      reinterpret_cast<void**>(put_abi(item))));   // reinterpret_cast<void**> REQUIRED (was the C2664 bug)
  return item;
}
static GraphicsCaptureItem ItemForMonitor(HMONITOR mon){
  auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
  GraphicsCaptureItem item{nullptr};
  check_hresult(interop->CreateForMonitor(mon, guid_of<GraphicsCaptureItem>(),
      reinterpret_cast<void**>(put_abi(item))));
  return item;
}
static com_ptr<ID3D11Texture2D> TexFromSurface(IDirect3DSurface const& s){
  auto access = s.as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
  com_ptr<ID3D11Texture2D> tex;
  check_hresult(access->GetInterface(guid_of<ID3D11Texture2D>(), tex.put_void()));
  return tex;
}
static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l){
  if (m == WM_PAINT){ PAINTSTRUCT ps; HDC dc=BeginPaint(h,&ps); RECT rc; GetClientRect(h,&rc);
    for (int y=0;y<rc.bottom;y+=4){ HBRUSH br=CreateSolidBrush(RGB((y*3)&0xFF,(y*5)&0xFF,0x90));
      RECT ln{0,y,rc.right,y+4}; FillRect(dc,&ln,br); DeleteObject(br); }
    EndPaint(h,&ps); return 0; }
  return DefWindowProcW(h,m,w,l);
}
static HWND MakeOwnWindow(){
  WNDCLASSW wc{}; wc.lpfnWndProc=WndProc; wc.hInstance=GetModuleHandleW(nullptr);
  wc.lpszClassName=L"wgcprobeMinWin"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); RegisterClassW(&wc);
  HWND h=CreateWindowExW(0,L"wgcprobeMinWin",L"wgcprobe",WS_OVERLAPPEDWINDOW|WS_VISIBLE,
      CW_USEDEFAULT,CW_USEDEFAULT,640,480,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
  ShowWindow(h,SW_SHOWNORMAL); UpdateWindow(h); return h;
}
static void Pump(DWORD ms){ DWORD end=GetTickCount()+ms; MSG msg;
  for(;;){ while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}
    if((LONG)(GetTickCount()-end)>=0) break; Sleep(4); } }
int main(int argc, char** argv){
  setvbuf(stdout,nullptr,_IONBF,0);   // qrexec pipe is fully-buffered; a crash must not eat output
  SetProcessDPIAware();
  init_apartment(apartment_type::multi_threaded);   // MTA required for CreateFreeThreaded; NO pump
  // ---- context proof ----
  wchar_t nb[256]; DWORD cch=256; std::string host,user;
  if(GetComputerNameW(nb,&cch)) host=W2U(nb); cch=256; if(GetUserNameW(nb,&cch)) user=W2U(nb);
  DWORD sid=0; ProcessIdToSessionId(GetCurrentProcessId(),&sid);
  std::string winsta=UObj(GetProcessWindowStation());
  std::string desktop=UObj(GetThreadDesktop(GetCurrentThreadId()));
  bool interactive=(winsta=="WinSta0");
  wchar_t bld[64]{}; DWORD cb=sizeof(bld); std::string osb;
  if(RegGetValueW(HKEY_LOCAL_MACHINE,L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",L"CurrentBuildNumber",RRF_RT_REG_SZ,nullptr,bld,&cb)==ERROR_SUCCESS) osb=W2U(bld);
  printf("wgcprobe host=%s user=%s session=%lu winsta=%s desktop=%s interactive=%d build=%s\n",
      host.c_str(),user.c_str(),(unsigned long)sid,winsta.c_str(),desktop.c_str(),interactive,osb.c_str());
  // ---- feature-presence (ApiInformation only; no symbol reference -> no SDK compile gate) ----
  bool borderApi=false, cursorApi=false, dirtyApi=false, dirtyModeApi=false;
  try{ borderApi   = meta::ApiInformation::IsPropertyPresent(kSess,L"IsBorderRequired");
       cursorApi   = meta::ApiInformation::IsPropertyPresent(kSess,L"IsCursorCaptureEnabled");
       dirtyModeApi= meta::ApiInformation::IsPropertyPresent(kSess,L"DirtyRegionMode");
       dirtyApi    = meta::ApiInformation::IsPropertyPresent(kFrame,L"DirtyRegions"); }catch(...){}
  // ---- P8: IsSupported, wrapped ----
  bool supported=false, threw=false; unsigned supHr=0;
  try{ supported = GraphicsCaptureSession::IsSupported(); }
  catch(hresult_error const& e){ threw=true; supHr=(unsigned)e.code().value; } // 0x8007000E lands here
  catch(...){ threw=true; supHr=0xFFFFFFFF; }
  printf("IsSupported=%d threw=%d hr=0x%08X borderApi=%d cursorApi=%d dirtyRegionsApi=%d dirtyModeApi=%d\n",
      supported,threw,supHr,borderApi,cursorApi,dirtyApi,dirtyModeApi);
  auto emitDead=[&](const char* stage,unsigned hr){
    printf("=== WGCPROBE JSON ===\n{\"brokerViable\":false,\"stage\":\"%s\",\"isSupported\":%s,"
      "\"hresult\":\"0x%08X\",\"itemCreated\":false,\"frameArrived\":false,\"nonBlank\":false,"
      "\"borderRequiredApi\":%s,\"dirtyRegionsApi\":%s,\"user\":\"%s\",\"session\":%lu,"
      "\"windowStation\":\"%s\",\"desktop\":\"%s\",\"interactive\":%s,\"build\":\"%s\"}\n",
      stage, supported?"true":"false", hr, borderApi?"true":"false", dirtyApi?"true":"false",
      user.c_str(),(unsigned long)sid,winsta.c_str(),desktop.c_str(),interactive?"true":"false",osb.c_str());
  };
  if(!supported){ emitDead("is_supported", supHr); return threw?4:1; }
  // ---- target: argv[1]=="mon" -> primary monitor (CreateForMonitor); else hex HWND ->
  //      Notepad -> own gradient window (CreateForWindow) ----
  bool monMode = (argc>=2 && _stricmp(argv[1],"mon")==0);
  HWND hwnd=nullptr; const char* how = monMode?"monitor":"argv"; bool ownWin=false;
  if(!monMode){
    if(argc>=2){ unsigned long long v=_strtoui64(argv[1],nullptr,16); if(v) hwnd=(HWND)(uintptr_t)v; }
    if(!hwnd){ hwnd=FindWindowW(L"Notepad",nullptr); if(hwnd) how="notepad"; }
    if(!hwnd){ hwnd=MakeOwnWindow(); ownWin=true; how="own"; Pump(500); }
    if(!hwnd || !IsWindow(hwnd)){ emitDead("target", 0); return 1; }
    ShowWindow(hwnd,SW_RESTORE); SetWindowPos(hwnd,HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW); Pump(200);
  }
  D3D d; if(!MakeD3D(d)){ emitDead("d3d", 0); return 1; }
  bool itemCreated=false, borderSet=false; unsigned borderHr=0;
  GraphicsCaptureItem item{nullptr};
  try{ item = monMode ? ItemForMonitor(MonitorFromPoint(POINT{0,0}, MONITOR_DEFAULTTOPRIMARY))
                      : ItemForWindow(hwnd); itemCreated=(item!=nullptr); }
  catch(hresult_error const& e){ emitDead("item",(unsigned)e.code().value); return 1; }
  catch(...){ emitDead("item",0xFFFFFFFF); return 1; }
  SizeInt32 isz=item.Size(); if(isz.Width<=0||isz.Height<=0){ isz={640,480}; }
  Direct3D11CaptureFramePool pool{nullptr}; GraphicsCaptureSession session{nullptr};
  try{
    pool=Direct3D11CaptureFramePool::CreateFreeThreaded(d.rt,DirectXPixelFormat::B8G8R8A8UIntNormalized,2,isz);
    session=pool.CreateCaptureSession(item);
    if(cursorApi){ try{ session.IsCursorCaptureEnabled(false); }catch(...){} }
    if(borderApi){ try{ session.IsBorderRequired(false); borderSet=true; }catch(hresult_error const& e){ borderHr=(unsigned)e.code().value; }catch(...){} }
  }catch(hresult_error const& e){ emitDead("pool",(unsigned)e.code().value); return 1; }
  catch(...){ emitDead("pool",0xFFFFFFFF); return 1; }
  // ---- one frame, no message pump: FrameArrived -> SetEvent ----
  HANDLE evt=CreateEventW(nullptr,FALSE,FALSE,nullptr); // auto-reset
  std::mutex mtx; Direct3D11CaptureFrame pending{nullptr};
  event_token token{};
  try{ token=pool.FrameArrived([&](Direct3D11CaptureFramePool const& s, winrt::Windows::Foundation::IInspectable const&){
        auto f=s.TryGetNextFrame(); if(f){ std::lock_guard<std::mutex> lk(mtx); pending=f; SetEvent(evt); } }); }catch(...){}
  try{ session.StartCapture(); }
  catch(hresult_error const& e){ CloseHandle(evt); emitDead("start",(unsigned)e.code().value); return 1; }
  catch(...){ CloseHandle(evt); emitDead("start",0xFFFFFFFF); return 1; }
  bool frameArrived=false, nonBlank=false; int framesSeen=0, distinct=0, cw=0, ch=0;
  DWORD deadline=GetTickCount()+8000;
  while((LONG)(GetTickCount()-deadline)<0){
    if(ownWin){ InvalidateRect(hwnd,nullptr,FALSE); }
    if(hwnd){ SetWindowPos(hwnd,HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE); RedrawWindow(hwnd,nullptr,nullptr,RDW_INVALIDATE|RDW_UPDATENOW); }
    Pump(0);
    if(WaitForSingleObject(evt,200)!=WAIT_OBJECT_0) continue;
    Direct3D11CaptureFrame frame{nullptr};
    { std::lock_guard<std::mutex> lk(mtx); frame=pending; pending=nullptr; }
    if(!frame) continue;
    frameArrived=true; framesSeen++;
    try{
      auto cs=frame.ContentSize(); cw=cs.Width; ch=cs.Height;
      auto tex=TexFromSurface(frame.Surface());
      D3D11_TEXTURE2D_DESC td{}; tex->GetDesc(&td);
      D3D11_TEXTURE2D_DESC sd=td; sd.Usage=D3D11_USAGE_STAGING; sd.BindFlags=0; sd.MiscFlags=0; sd.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
      com_ptr<ID3D11Texture2D> staging; check_hresult(d.dev->CreateTexture2D(&sd,nullptr,staging.put()));
      d.ctx->CopyResource(staging.get(),tex.get());
      D3D11_MAPPED_SUBRESOURCE mp{}; check_hresult(d.ctx->Map(staging.get(),0,D3D11_MAP_READ,0,&mp));
      int W=(int)td.Width,H=(int)td.Height,sx=W>64?W/64:1,sy=H>64?H/64:1;
      DWORD seen[16]; int seenN=0; unsigned long long nonZero=0;
      for(int y=0;y<H;y+=sy){ const BYTE* row=(const BYTE*)mp.pData+(size_t)y*mp.RowPitch;
        for(int x=0;x<W;x+=sx){ DWORD px=((const DWORD*)row)[x]&0x00FFFFFF; if(px) nonZero++;
          bool k=false; for(int i=0;i<seenN;i++) if(seen[i]==px){k=true;break;} if(!k&&seenN<16) seen[seenN++]=px; } }
      d.ctx->Unmap(staging.get(),0);
      distinct=seenN; nonBlank=(distinct>=2)&&(nonZero>0);
    }catch(...){ /* keep polling; a bad frame is not fatal */ }
    if(nonBlank) break;
  }
  try{ pool.FrameArrived(token); }catch(...){}
  try{ session.Close(); }catch(...){}
  Sleep(50);
  try{ pool.Close(); }catch(...){}
  CloseHandle(evt);
  bool brokerViable = supported && frameArrived && nonBlank;
  printf("frameArrived=%d framesSeen=%d nonBlank=%d content=%dx%d distinctColors=%d target=%s borderSet=%d\n",
      frameArrived,framesSeen,nonBlank,cw,ch,distinct,how,borderSet);
  printf("=== WGCPROBE JSON ===\n"
    "{\"brokerViable\":%s,\"isSupported\":true,\"hresult\":\"0x00000000\",\"itemCreated\":%s,"
    "\"frameArrived\":%s,\"nonBlank\":%s,\"framesSeen\":%d,\"contentW\":%d,\"contentH\":%d,"
    "\"distinctColors\":%d,\"target\":\"%s\",\"borderRequiredApi\":%s,\"borderDisableOk\":%s,"
    "\"borderDisableHr\":\"0x%08X\",\"cursorApi\":%s,\"dirtyRegionsApi\":%s,\"dirtyRegionModeApi\":%s,"
    "\"user\":\"%s\",\"session\":%lu,\"windowStation\":\"%s\",\"desktop\":\"%s\",\"interactive\":%s,\"build\":\"%s\"}\n",
    brokerViable?"true":"false", itemCreated?"true":"false", frameArrived?"true":"false", nonBlank?"true":"false",
    framesSeen,cw,ch,distinct,how, borderApi?"true":"false", borderSet?"true":"false", borderHr,
    cursorApi?"true":"false", dirtyApi?"true":"false", dirtyModeApi?"true":"false",
    user.c_str(),(unsigned long)sid,winsta.c_str(),desktop.c_str(),interactive?"true":"false",osb.c_str());
  if(ownWin) DestroyWindow(hwnd);
  return brokerViable?0:2;
}