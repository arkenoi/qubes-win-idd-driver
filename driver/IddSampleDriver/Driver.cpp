/*++

Copyright (c) Microsoft Corporation

Abstract:

    This module contains a sample implementation of an indirect display driver. See the included README.md file and the
    various TODO blocks throughout this file and all accompanying files for information on building a production driver.

    MSDN documentation on indirect displays can be found at https://msdn.microsoft.com/en-us/library/windows/hardware/mt761968(v=vs.85).aspx.

Environment:

    User Mode, UMDF

--*/

#include "Driver.h"
#include "Driver.tmh"

using namespace std;
using namespace Microsoft::IndirectDisp;
using namespace Microsoft::WRL;

#pragma region SampleMonitors

static constexpr DWORD IDD_SAMPLE_MONITOR_COUNT = 1;
// Qubes D4v2: IDD_SAMPLE_EDID_MONITOR_COUNT (0 = all EDID-less) is gone — the single
// monitor now always carries the stable Qubes EDID (s_QubesMonitor below). The sample's
// s_SampleMonitors table (two fake vendor EDIDs) is removed: ParseMonitorDescription no
// longer dispatches by EDID content, so the table had no remaining reference.

// Default modes reported for edid-less monitors. The first mode is set as preferred
static const struct IndirectSampleMonitor::SampleMonitorMode s_SampleDefaultModes[] =
{
    { 1920, 1080, 60 },
    { 1600,  900, 60 },
    { 1024,  768, 75 },
};

// ==============================
// Qubes D4v2: STABLE EDID identity.
// An EDID-less monitor gets a fresh display identity on every replug (observed: guest at
// \\.\DISPLAY29 after ~20 replugs) — the "runaway registry entries / random resolutions"
// failure mode (docs/RESEARCH-hypervisor-resize.md §6). A constant vendor/product/serial
// keeps ONE Enum\DISPLAY instance and ONE GraphicsDrivers\Configuration path across
// replugs, so the monitor below carries a fixed hand-built EDID:
//   vendor "QBS" (PNP id bits: Q=17,B=2,S=19 -> 0x4453 big-endian), product 0x0001 (LE),
//   serial 0x00000001 (LE), EDID 1.4, digital input (8 bpc), preferred detailed timing
//   1920x1080@60 (canonical 148.5 MHz CEA timing), range limits V 50-75 Hz / H 30-90 kHz,
//   name "QubesIDD", serial string "QBS0001", no extension blocks.
// CHECKSUM RULE (double-checked): byte 127 makes the sum of ALL 128 bytes == 0 mod 256,
// i.e. checksum = (256 - (sum of bytes 0..126) % 256) % 256. Here that gives 0x53; the
// generator asserted sum(edid) % 256 == 0 over the final 128 bytes.
// ==============================
static const struct IndirectSampleMonitor s_QubesMonitor =
{
    {
        0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x44,0x53,0x01,0x00,0x01,0x00,0x00,0x00,0x00,0x1E,0x01,
        0x04,0xA5,0x3C,0x22,0x78,0x2A,0x6C,0xE5,0xA5,0x55,0x50,0xA0,0x23,0x0B,0x50,0x54,0x21,0x08,0x00,
        0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x02,0x3A,0x80,
        0x18,0x71,0x38,0x2D,0x40,0x58,0x2C,0x45,0x00,0x56,0x50,0x21,0x00,0x00,0x1E,0x00,0x00,0x00,0xFD,
        0x00,0x32,0x4B,0x1E,0x5A,0x10,0x01,0x0A,0x20,0x20,0x20,0x20,0x20,0x20,0x00,0x00,0x00,0xFC,0x00,
        0x51,0x75,0x62,0x65,0x73,0x49,0x44,0x44,0x0A,0x20,0x20,0x20,0x20,0x00,0x00,0x00,0xFF,0x00,0x51,
        0x42,0x53,0x30,0x30,0x30,0x31,0x0A,0x20,0x20,0x20,0x20,0x20,0x00,0x53
    },
    {
        { 1920, 1080, 60 },
        { 1600,  900, 60 },
        { 1024,  768, 60 },
    },
    0
};

// ==============================
// Qubes D4 (PLAN-trackb-t2-modes.md §4 D4): extra modes declared at monitor arrival from
// a registry list the session side can rewrite. All registry modes are reported at 60 Hz
// and appended, deduplicated, to BOTH the monitor default-description mode list and the
// target mode list. Missing key/value or zero valid entries -> identical to the D0 build.
// ==============================
static constexpr WCHAR QUBES_IDD_MODES_KEY[] = L"SOFTWARE\\QubesIDD";
static constexpr WCHAR QUBES_IDD_MODES_VALUE[] = L"Modes";
static constexpr size_t QUBES_IDD_MAX_REG_MODES = 32; // cap on extra modes read from the registry
static constexpr DWORD QUBES_IDD_MODE_VSYNC = 60;
static constexpr DWORD QUBES_IDD_MIN_WIDTH = 640;
static constexpr DWORD QUBES_IDD_MAX_WIDTH = 16384;
static constexpr DWORD QUBES_IDD_MIN_HEIGHT = 480;
static constexpr DWORD QUBES_IDD_MAX_HEIGHT = 6144;

struct QubesRegistryMode
{
    DWORD Width;
    DWORD Height;
};

// Reads REG_MULTI_SZ 'Modes' from HKLM\SOFTWARE\QubesIDD (64-bit view). Each entry is
// 'WIDTHxHEIGHT', e.g. '2566x1022'. Malformed entries are skipped; dimensions are
// clamped into [640,16384] x [480,6144]; at most QUBES_IDD_MAX_REG_MODES entries.
//
// RELOAD MECHANISM (v1, deliberate): there is no timer and no IOCTL. This is read on the
// mode-list callbacks that run as part of monitor arrival, so after the session side
// rewrites the value it restarts the device (devcon restart / disable+enable), which
// re-runs arrival and re-reads this list.
static vector<QubesRegistryMode> QubesReadRegistryModes()
{
    vector<QubesRegistryMode> Modes;

    DWORD cbData = 0;
    LSTATUS Err = RegGetValueW(HKEY_LOCAL_MACHINE, QUBES_IDD_MODES_KEY, QUBES_IDD_MODES_VALUE,
        RRF_RT_REG_MULTI_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, nullptr, &cbData);
    if (Err != ERROR_SUCCESS || cbData < sizeof(WCHAR))
    {
        return Modes; // no key/value -> behave exactly like D0
    }

    vector<WCHAR> Data(cbData / sizeof(WCHAR) + 2, L'\0');
    Err = RegGetValueW(HKEY_LOCAL_MACHINE, QUBES_IDD_MODES_KEY, QUBES_IDD_MODES_VALUE,
        RRF_RT_REG_MULTI_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, Data.data(), &cbData);
    if (Err != ERROR_SUCCESS)
    {
        return Modes;
    }

    // Walk the MULTI_SZ: entries are NUL-separated, list ends at an empty string.
    for (const WCHAR* pEntry = Data.data(); *pEntry != L'\0'; pEntry += wcslen(pEntry) + 1)
    {
        if (Modes.size() >= QUBES_IDD_MAX_REG_MODES)
        {
            break;
        }

        WCHAR* pEnd = nullptr;
        unsigned long Width = wcstoul(pEntry, &pEnd, 10);
        if (pEnd == pEntry || *pEnd != L'x')
        {
            continue; // malformed: no leading number or no 'x' separator
        }

        const WCHAR* pHeight = pEnd + 1;
        unsigned long Height = wcstoul(pHeight, &pEnd, 10);
        if (pEnd == pHeight || *pEnd != L'\0')
        {
            continue; // malformed: no height number or trailing garbage
        }

        QubesRegistryMode Mode;
        Mode.Width  = min(max((DWORD) Width,  QUBES_IDD_MIN_WIDTH),  QUBES_IDD_MAX_WIDTH);
        Mode.Height = min(max((DWORD) Height, QUBES_IDD_MIN_HEIGHT), QUBES_IDD_MAX_HEIGHT);

        // Dedup within the registry list itself (post-clamp).
        bool bDuplicate = false;
        for (const auto& Existing : Modes)
        {
            if (Existing.Width == Mode.Width && Existing.Height == Mode.Height)
            {
                bDuplicate = true;
                break;
            }
        }
        if (!bDuplicate)
        {
            Modes.push_back(Mode);
        }
    }

    return Modes;
}


#pragma endregion

#pragma region helpers

static inline void FillSignalInfo(DISPLAYCONFIG_VIDEO_SIGNAL_INFO& Mode, DWORD Width, DWORD Height, DWORD VSync, bool bMonitorMode)
{
    Mode.totalSize.cx = Mode.activeSize.cx = Width;
    Mode.totalSize.cy = Mode.activeSize.cy = Height;

    // See https://docs.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_video_signal_info
    Mode.AdditionalSignalInfo.vSyncFreqDivider = bMonitorMode ? 0 : 1;
    Mode.AdditionalSignalInfo.videoStandard = 255;

    Mode.vSyncFreq.Numerator = VSync;
    Mode.vSyncFreq.Denominator = 1;
    Mode.hSyncFreq.Numerator = VSync * Height;
    Mode.hSyncFreq.Denominator = 1;

    Mode.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;

    Mode.pixelRate = ((UINT64) VSync) * ((UINT64) Width) * ((UINT64) Height);
}

static IDDCX_MONITOR_MODE CreateIddCxMonitorMode(DWORD Width, DWORD Height, DWORD VSync, IDDCX_MONITOR_MODE_ORIGIN Origin = IDDCX_MONITOR_MODE_ORIGIN_DRIVER)
{
    IDDCX_MONITOR_MODE Mode = {};

    Mode.Size = sizeof(Mode);
    Mode.Origin = Origin;
    FillSignalInfo(Mode.MonitorVideoSignalInfo, Width, Height, VSync, true);

    return Mode;
}

static IDDCX_TARGET_MODE CreateIddCxTargetMode(DWORD Width, DWORD Height, DWORD VSync)
{
    IDDCX_TARGET_MODE Mode = {};

    Mode.Size = sizeof(Mode);
    FillSignalInfo(Mode.TargetVideoSignalInfo.targetVideoSignalInfo, Width, Height, VSync, false);

    return Mode;
}

#pragma endregion

extern "C" DRIVER_INITIALIZE DriverEntry;

EVT_WDF_DRIVER_DEVICE_ADD IddSampleDeviceAdd;
EVT_WDF_DEVICE_D0_ENTRY IddSampleDeviceD0Entry;

EVT_IDD_CX_ADAPTER_INIT_FINISHED IddSampleAdapterInitFinished;
EVT_IDD_CX_ADAPTER_COMMIT_MODES IddSampleAdapterCommitModes;

EVT_IDD_CX_PARSE_MONITOR_DESCRIPTION IddSampleParseMonitorDescription;
EVT_IDD_CX_MONITOR_GET_DEFAULT_DESCRIPTION_MODES IddSampleMonitorGetDefaultModes;
EVT_IDD_CX_MONITOR_QUERY_TARGET_MODES IddSampleMonitorQueryModes;

EVT_IDD_CX_MONITOR_ASSIGN_SWAPCHAIN IddSampleMonitorAssignSwapChain;
EVT_IDD_CX_MONITOR_UNASSIGN_SWAPCHAIN IddSampleMonitorUnassignSwapChain;

struct IndirectDeviceContextWrapper
{
    IndirectDeviceContext* pContext;

    void Cleanup()
    {
        delete pContext;
        pContext = nullptr;
    }
};

struct IndirectMonitorContextWrapper
{
    IndirectMonitorContext* pContext;

    void Cleanup()
    {
        delete pContext;
        pContext = nullptr;
    }
};

// This macro creates the methods for accessing an IndirectDeviceContextWrapper as a context for a WDF object
WDF_DECLARE_CONTEXT_TYPE(IndirectDeviceContextWrapper);

WDF_DECLARE_CONTEXT_TYPE(IndirectMonitorContextWrapper);

extern "C" BOOL WINAPI DllMain(
    _In_ HINSTANCE hInstance,
    _In_ UINT dwReason,
    _In_opt_ LPVOID lpReserved)
{
    UNREFERENCED_PARAMETER(hInstance);
    UNREFERENCED_PARAMETER(lpReserved);
    UNREFERENCED_PARAMETER(dwReason);

    return TRUE;
}

_Use_decl_annotations_
extern "C" NTSTATUS DriverEntry(
    PDRIVER_OBJECT  pDriverObject,
    PUNICODE_STRING pRegistryPath
)
{
    WDF_DRIVER_CONFIG Config;
    NTSTATUS Status;

    WDF_OBJECT_ATTRIBUTES Attributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&Attributes);

    WDF_DRIVER_CONFIG_INIT(&Config,
        IddSampleDeviceAdd
    );

    Status = WdfDriverCreate(pDriverObject, pRegistryPath, &Attributes, &Config, WDF_NO_HANDLE);
    if (!NT_SUCCESS(Status))
    {
        return Status;
    }

    return Status;
}

_Use_decl_annotations_
NTSTATUS IddSampleDeviceAdd(WDFDRIVER Driver, PWDFDEVICE_INIT pDeviceInit)
{
    NTSTATUS Status = STATUS_SUCCESS;
    WDF_PNPPOWER_EVENT_CALLBACKS PnpPowerCallbacks;

    UNREFERENCED_PARAMETER(Driver);

    // Register for power callbacks - in this sample only power-on is needed
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&PnpPowerCallbacks);
    PnpPowerCallbacks.EvtDeviceD0Entry = IddSampleDeviceD0Entry;
    WdfDeviceInitSetPnpPowerEventCallbacks(pDeviceInit, &PnpPowerCallbacks);

    IDD_CX_CLIENT_CONFIG IddConfig;
    IDD_CX_CLIENT_CONFIG_INIT(&IddConfig);

    // If the driver wishes to handle custom IoDeviceControl requests, it's necessary to use this callback since IddCx
    // redirects IoDeviceControl requests to an internal queue. This sample does not need this.
    // IddConfig.EvtIddCxDeviceIoControl = IddSampleIoDeviceControl;

    IddConfig.EvtIddCxAdapterInitFinished = IddSampleAdapterInitFinished;

    IddConfig.EvtIddCxParseMonitorDescription = IddSampleParseMonitorDescription;
    IddConfig.EvtIddCxMonitorGetDefaultDescriptionModes = IddSampleMonitorGetDefaultModes;
    IddConfig.EvtIddCxMonitorQueryTargetModes = IddSampleMonitorQueryModes;
    IddConfig.EvtIddCxAdapterCommitModes = IddSampleAdapterCommitModes;
    IddConfig.EvtIddCxMonitorAssignSwapChain = IddSampleMonitorAssignSwapChain;
    IddConfig.EvtIddCxMonitorUnassignSwapChain = IddSampleMonitorUnassignSwapChain;

    Status = IddCxDeviceInitConfig(pDeviceInit, &IddConfig);
    if (!NT_SUCCESS(Status))
    {
        return Status;
    }

    WDF_OBJECT_ATTRIBUTES Attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&Attr, IndirectDeviceContextWrapper);
    Attr.EvtCleanupCallback = [](WDFOBJECT Object)
    {
        // Automatically cleanup the context when the WDF object is about to be deleted
        auto* pContext = WdfObjectGet_IndirectDeviceContextWrapper(Object);
        if (pContext)
        {
            pContext->Cleanup();
        }
    };

    WDFDEVICE Device = nullptr;
    Status = WdfDeviceCreate(&pDeviceInit, &Attr, &Device);
    if (!NT_SUCCESS(Status))
    {
        return Status;
    }

    Status = IddCxDeviceInitialize(Device);

    // Create a new device context object and attach it to the WDF device object
    auto* pContext = WdfObjectGet_IndirectDeviceContextWrapper(Device);
    pContext->pContext = new IndirectDeviceContext(Device);

    return Status;
}

_Use_decl_annotations_
NTSTATUS IddSampleDeviceD0Entry(WDFDEVICE Device, WDF_POWER_DEVICE_STATE PreviousState)
{
    UNREFERENCED_PARAMETER(PreviousState);

    // This function is called by WDF to start the device in the fully-on power state.

    auto* pContext = WdfObjectGet_IndirectDeviceContextWrapper(Device);
    pContext->pContext->InitAdapter();

    return STATUS_SUCCESS;
}

#pragma region Direct3DDevice

Direct3DDevice::Direct3DDevice(LUID AdapterLuid) : AdapterLuid(AdapterLuid)
{

}

Direct3DDevice::Direct3DDevice()
{
    AdapterLuid = LUID{};
}

HRESULT Direct3DDevice::Init()
{
    // The DXGI factory could be cached, but if a new render adapter appears on the system, a new factory needs to be
    // created. If caching is desired, check DxgiFactory->IsCurrent() each time and recreate the factory if !IsCurrent.
    HRESULT hr = CreateDXGIFactory2(0, IID_PPV_ARGS(&DxgiFactory));
    if (FAILED(hr))
    {
        return hr;
    }

    // Find the specified render adapter
    hr = DxgiFactory->EnumAdapterByLuid(AdapterLuid, IID_PPV_ARGS(&Adapter));
    if (FAILED(hr))
    {
        return hr;
    }

    // Create a D3D device using the render adapter. BGRA support is required by the WHQL test suite.
    hr = D3D11CreateDevice(Adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &Device, nullptr, &DeviceContext);
    if (FAILED(hr))
    {
        // If creating the D3D device failed, it's possible the render GPU was lost (e.g. detachable GPU) or else the
        // system is in a transient state.
        return hr;
    }

    return S_OK;
}

#pragma endregion

#pragma region SwapChainProcessor

SwapChainProcessor::SwapChainProcessor(IDDCX_SWAPCHAIN hSwapChain, shared_ptr<Direct3DDevice> Device, HANDLE NewFrameEvent)
    : m_hSwapChain(hSwapChain), m_Device(Device), m_hAvailableBufferEvent(NewFrameEvent)
{
    m_hTerminateEvent.Attach(CreateEvent(nullptr, FALSE, FALSE, nullptr));

    // Immediately create and run the swap-chain processing thread, passing 'this' as the thread parameter
    m_hThread.Attach(CreateThread(nullptr, 0, RunThread, this, 0, nullptr));
}

SwapChainProcessor::~SwapChainProcessor()
{
    // Alert the swap-chain processing thread to terminate
    SetEvent(m_hTerminateEvent.Get());

    if (m_hThread.Get())
    {
        // Wait for the thread to terminate
        WaitForSingleObject(m_hThread.Get(), INFINITE);
    }
}

DWORD CALLBACK SwapChainProcessor::RunThread(LPVOID Argument)
{
    reinterpret_cast<SwapChainProcessor*>(Argument)->Run();
    return 0;
}

void SwapChainProcessor::Run()
{
    // For improved performance, make use of the Multimedia Class Scheduler Service, which will intelligently
    // prioritize this thread for improved throughput in high CPU-load scenarios.
    DWORD AvTask = 0;
    HANDLE AvTaskHandle = AvSetMmThreadCharacteristicsW(L"Distribution", &AvTask);

    RunCore();

    // Always delete the swap-chain object when swap-chain processing loop terminates in order to kick the system to
    // provide a new swap-chain if necessary.
    WdfObjectDelete((WDFOBJECT)m_hSwapChain);
    m_hSwapChain = nullptr;

    AvRevertMmThreadCharacteristics(AvTaskHandle);
}

void SwapChainProcessor::RunCore()
{
    // Get the DXGI device interface
    ComPtr<IDXGIDevice> DxgiDevice;
    HRESULT hr = m_Device->Device.As(&DxgiDevice);
    if (FAILED(hr))
    {
        return;
    }

    IDARG_IN_SWAPCHAINSETDEVICE SetDevice = {};
    SetDevice.pDevice = DxgiDevice.Get();

    hr = IddCxSwapChainSetDevice(m_hSwapChain, &SetDevice);
    if (FAILED(hr))
    {
        return;
    }

    // Acquire and release buffers in a loop
    for (;;)
    {
        ComPtr<IDXGIResource> AcquiredBuffer;

        // Ask for the next buffer from the producer
        IDARG_OUT_RELEASEANDACQUIREBUFFER Buffer = {};
        hr = IddCxSwapChainReleaseAndAcquireBuffer(m_hSwapChain, &Buffer);

        // AcquireBuffer immediately returns STATUS_PENDING if no buffer is yet available
        if (hr == E_PENDING)
        {
            // We must wait for a new buffer
            HANDLE WaitHandles [] =
            {
                m_hAvailableBufferEvent,
                m_hTerminateEvent.Get()
            };
            DWORD WaitResult = WaitForMultipleObjects(ARRAYSIZE(WaitHandles), WaitHandles, FALSE, 16);
            if (WaitResult == WAIT_OBJECT_0 || WaitResult == WAIT_TIMEOUT)
            {
                // We have a new buffer, so try the AcquireBuffer again
                continue;
            }
            else if (WaitResult == WAIT_OBJECT_0 + 1)
            {
                // We need to terminate
                break;
            }
            else
            {
                // The wait was cancelled or something unexpected happened
                hr = HRESULT_FROM_WIN32(WaitResult);
                break;
            }
        }
        else if (SUCCEEDED(hr))
        {
            // We have new frame to process, the surface has a reference on it that the driver has to release
            AcquiredBuffer.Attach(Buffer.MetaData.pSurface);

            // ==============================
            // TODO: Process the frame here
            //
            // This is the most performance-critical section of code in an IddCx driver. It's important that whatever
            // is done with the acquired surface be finished as quickly as possible. This operation could be:
            //  * a GPU copy to another buffer surface for later processing (such as a staging surface for mapping to CPU memory)
            //  * a GPU encode operation
            //  * a GPU VPBlt to another surface
            //  * a GPU custom compute shader encode operation
            // ==============================

            // We have finished processing this frame hence we release the reference on it.
            // If the driver forgets to release the reference to the surface, it will be leaked which results in the
            // surfaces being left around after swapchain is destroyed.
            // NOTE: Although in this sample we release reference to the surface here; the driver still
            // owns the Buffer.MetaData.pSurface surface until IddCxSwapChainReleaseAndAcquireBuffer returns
            // S_OK and gives us a new frame, a driver may want to use the surface in future to re-encode the desktop 
            // for better quality if there is no new frame for a while
            AcquiredBuffer.Reset();
            
            // Indicate to OS that we have finished inital processing of the frame, it is a hint that
            // OS could start preparing another frame
            hr = IddCxSwapChainFinishedProcessingFrame(m_hSwapChain);
            if (FAILED(hr))
            {
                break;
            }

            // ==============================
            // TODO: Report frame statistics once the asynchronous encode/send work is completed
            //
            // Drivers should report information about sub-frame timings, like encode time, send time, etc.
            // ==============================
            // IddCxSwapChainReportFrameStatistics(m_hSwapChain, ...);
        }
        else
        {
            // The swap-chain was likely abandoned (e.g. DXGI_ERROR_ACCESS_LOST), so exit the processing loop
            break;
        }
    }
}

#pragma endregion

#pragma region IndirectDeviceContext

IndirectDeviceContext::IndirectDeviceContext(_In_ WDFDEVICE WdfDevice) :
    m_WdfDevice(WdfDevice)
{
    m_Adapter = {};
}

IndirectDeviceContext::~IndirectDeviceContext()
{
}

void IndirectDeviceContext::InitAdapter()
{
    // ==============================
    // TODO: Update the below diagnostic information in accordance with the target hardware. The strings and version
    // numbers are used for telemetry and may be displayed to the user in some situations.
    //
    // This is also where static per-adapter capabilities are determined.
    // ==============================

    IDDCX_ADAPTER_CAPS AdapterCaps = {};
    AdapterCaps.Size = sizeof(AdapterCaps);

    // Declare basic feature support for the adapter (required)
    AdapterCaps.MaxMonitorsSupported = IDD_SAMPLE_MONITOR_COUNT;
    AdapterCaps.EndPointDiagnostics.Size = sizeof(AdapterCaps.EndPointDiagnostics);
    AdapterCaps.EndPointDiagnostics.GammaSupport = IDDCX_FEATURE_IMPLEMENTATION_NONE;
    AdapterCaps.EndPointDiagnostics.TransmissionType = IDDCX_TRANSMISSION_TYPE_WIRED_OTHER;

    // Declare your device strings for telemetry (required)
    AdapterCaps.EndPointDiagnostics.pEndPointFriendlyName = L"IddSample Device";
    AdapterCaps.EndPointDiagnostics.pEndPointManufacturerName = L"Microsoft";
    AdapterCaps.EndPointDiagnostics.pEndPointModelName = L"IddSample Model";

    // Declare your hardware and firmware versions (required)
    IDDCX_ENDPOINT_VERSION Version = {};
    Version.Size = sizeof(Version);
    Version.MajorVer = 1;
    AdapterCaps.EndPointDiagnostics.pFirmwareVersion = &Version;
    AdapterCaps.EndPointDiagnostics.pHardwareVersion = &Version;

    // Initialize a WDF context that can store a pointer to the device context object
    WDF_OBJECT_ATTRIBUTES Attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&Attr, IndirectDeviceContextWrapper);

    IDARG_IN_ADAPTER_INIT AdapterInit = {};
    AdapterInit.WdfDevice = m_WdfDevice;
    AdapterInit.pCaps = &AdapterCaps;
    AdapterInit.ObjectAttributes = &Attr;

    // Start the initialization of the adapter, which will trigger the AdapterFinishInit callback later
    IDARG_OUT_ADAPTER_INIT AdapterInitOut;
    NTSTATUS Status = IddCxAdapterInitAsync(&AdapterInit, &AdapterInitOut);

    if (NT_SUCCESS(Status))
    {
        // Store a reference to the WDF adapter handle
        m_Adapter = AdapterInitOut.AdapterObject;

        // Store the device context object into the WDF object context
        auto* pContext = WdfObjectGet_IndirectDeviceContextWrapper(AdapterInitOut.AdapterObject);
        pContext->pContext = this;
    }
}

void IndirectDeviceContext::FinishInit(UINT ConnectorIndex)
{
    // ==============================
    // TODO: In a real driver, the EDID should be retrieved dynamically from a connected physical monitor. The EDIDs
    // provided here are purely for demonstration.
    // Monitor manufacturers are required to correctly fill in physical monitor attributes in order to allow the OS
    // to optimize settings like viewing distance and scale factor. Manufacturers should also use a unique serial
    // number every single device to ensure the OS can tell the monitors apart.
    // ==============================

    WDF_OBJECT_ATTRIBUTES Attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&Attr, IndirectMonitorContextWrapper);

    // In the sample driver, we report a monitor right away but a real driver would do this when a monitor connection event occurs
    IDDCX_MONITOR_INFO MonitorInfo = {};
    MonitorInfo.Size = sizeof(MonitorInfo);
    MonitorInfo.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI;
    MonitorInfo.ConnectorIndex = ConnectorIndex;

    MonitorInfo.MonitorDescription.Size = sizeof(MonitorInfo.MonitorDescription);
    MonitorInfo.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_EDID;
    // Qubes D4v2: always report the stable-identity Qubes EDID (see s_QubesMonitor).
    // With an EDID present the OS derives monitor modes via
    // EvtIddCxParseMonitorDescription, NOT EvtIddCxMonitorGetDefaultDescriptionModes.
    MonitorInfo.MonitorDescription.DataSize = IndirectSampleMonitor::szEdidBlock;
    MonitorInfo.MonitorDescription.pData = const_cast<BYTE*>(s_QubesMonitor.pEdidBlock);

    // ==============================
    // TODO: The monitor's container ID should be distinct from "this" device's container ID if the monitor is not
    // permanently attached to the display adapter device object. The container ID is typically made unique for each
    // monitor and can be used to associate the monitor with other devices, like audio or input devices. In this
    // sample we generate a random container ID GUID, but it's best practice to choose a stable container ID for a
    // unique monitor or to use "this" device's container ID for a permanent/integrated monitor.
    // ==============================

    // Create a container ID
    CoCreateGuid(&MonitorInfo.MonitorContainerId);

    IDARG_IN_MONITORCREATE MonitorCreate = {};
    MonitorCreate.ObjectAttributes = &Attr;
    MonitorCreate.pMonitorInfo = &MonitorInfo;

    // Create a monitor object with the specified monitor descriptor
    IDARG_OUT_MONITORCREATE MonitorCreateOut;
    NTSTATUS Status = IddCxMonitorCreate(m_Adapter, &MonitorCreate, &MonitorCreateOut);
    if (NT_SUCCESS(Status))
    {
        // Create a new monitor context object and attach it to the Idd monitor object
        auto* pMonitorContextWrapper = WdfObjectGet_IndirectMonitorContextWrapper(MonitorCreateOut.MonitorObject);
        pMonitorContextWrapper->pContext = new IndirectMonitorContext(MonitorCreateOut.MonitorObject);

        // Tell the OS that the monitor has been plugged in
        IDARG_OUT_MONITORARRIVAL ArrivalOut;
        Status = IddCxMonitorArrival(MonitorCreateOut.MonitorObject, &ArrivalOut);
    }
}

IndirectMonitorContext::IndirectMonitorContext(_In_ IDDCX_MONITOR Monitor) :
    m_Monitor(Monitor)
{
}

IndirectMonitorContext::~IndirectMonitorContext()
{
    m_ProcessingThread.reset();
}

void IndirectMonitorContext::AssignSwapChain(IDDCX_SWAPCHAIN SwapChain, LUID RenderAdapter, HANDLE NewFrameEvent)
{
    m_ProcessingThread.reset();

    auto Device = make_shared<Direct3DDevice>(RenderAdapter);
    if (FAILED(Device->Init()))
    {
        // It's important to delete the swap-chain if D3D initialization fails, so that the OS knows to generate a new
        // swap-chain and try again.
        WdfObjectDelete(SwapChain);
    }
    else
    {
        // Create a new swap-chain processing thread
        m_ProcessingThread.reset(new SwapChainProcessor(SwapChain, Device, NewFrameEvent));
    }
}

void IndirectMonitorContext::UnassignSwapChain()
{
    // Stop processing the last swap-chain
    m_ProcessingThread.reset();
}

#pragma endregion

#pragma region DDI Callbacks

_Use_decl_annotations_
NTSTATUS IddSampleAdapterInitFinished(IDDCX_ADAPTER AdapterObject, const IDARG_IN_ADAPTER_INIT_FINISHED* pInArgs)
{
    // This is called when the OS has finished setting up the adapter for use by the IddCx driver. It's now possible
    // to report attached monitors.

    auto* pDeviceContextWrapper = WdfObjectGet_IndirectDeviceContextWrapper(AdapterObject);
    if (NT_SUCCESS(pInArgs->AdapterInitStatus))
    {
        for (DWORD i = 0; i < IDD_SAMPLE_MONITOR_COUNT; i++)
        {
            pDeviceContextWrapper->pContext->FinishInit(i);
        }
    }

    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddSampleAdapterCommitModes(IDDCX_ADAPTER AdapterObject, const IDARG_IN_COMMITMODES* pInArgs)
{
    UNREFERENCED_PARAMETER(AdapterObject);
    UNREFERENCED_PARAMETER(pInArgs);

    // For the sample, do nothing when modes are picked - the swap-chain is taken care of by IddCx

    // ==============================
    // TODO: In a real driver, this function would be used to reconfigure the device to commit the new modes. Loop
    // through pInArgs->pPaths and look for IDDCX_PATH_FLAGS_ACTIVE. Any path not active is inactive (e.g. the monitor
    // should be turned off).
    // ==============================

    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddSampleParseMonitorDescription(const IDARG_IN_PARSEMONITORDESCRIPTION* pInArgs, IDARG_OUT_PARSEMONITORDESCRIPTION* pOutArgs)
{
    // ==============================
    // TODO: In a real driver, this function would be called to generate monitor modes for an EDID by parsing it. In
    // this sample driver, we hard-code the EDID, so this function can generate known modes.
    // ==============================

    // ==============================
    // Qubes D4v2 fix (deployed build 8b1b003b never brought the monitor up):
    // This driver reports exactly ONE monitor with exactly ONE EDID (s_QubesMonitor), so
    // every invocation of this callback is necessarily about that monitor. The previous
    // revision kept the sample's dispatch-by-EDID-content: memcmp the incoming bytes
    // against known EDID blocks and return STATUS_INVALID_PARAMETER for anything else.
    // That structure turns ANY byte difference between the EDID we handed to
    // IddCxMonitorCreate and the copy IddCx hands back here into "no monitor modes", and
    // a ParseMonitorDescription failure drops the monitor entirely — exactly the
    // observed symptom (device runs, wmi_monitors=0, no IDD display device).
    // Therefore: never gate on the EDID content; always answer with our mode list.
    // All modes are reported with IDDCX_MONITOR_MODE_ORIGIN_MONITORDESCRIPTOR — the
    // canonical origin for this callback (the previous revision mixed in ORIGIN_DRIVER
    // for the registry modes, the other non-canonical delta versus the working D4 v1).
    // ==============================

    vector<IDDCX_MONITOR_MODE> MonitorModes;
    for (DWORD ModeIndex = 0; ModeIndex < IndirectSampleMonitor::szModeList; ModeIndex++)
    {
        MonitorModes.push_back(CreateIddCxMonitorMode(
            s_QubesMonitor.pModeList[ModeIndex].Width,
            s_QubesMonitor.pModeList[ModeIndex].Height,
            s_QubesMonitor.pModeList[ModeIndex].VSync,
            IDDCX_MONITOR_MODE_ORIGIN_MONITORDESCRIPTOR
        ));
    }

    // Registry modes at 60 Hz, deduplicated against the built-ins (same rules as the
    // D4 GetDefaultDescriptionModes path).
    for (const auto& RegMode : QubesReadRegistryModes())
    {
        bool bDuplicate = false;
        for (DWORD ModeIndex = 0; ModeIndex < IndirectSampleMonitor::szModeList; ModeIndex++)
        {
            if (s_QubesMonitor.pModeList[ModeIndex].Width == RegMode.Width &&
                s_QubesMonitor.pModeList[ModeIndex].Height == RegMode.Height &&
                s_QubesMonitor.pModeList[ModeIndex].VSync == QUBES_IDD_MODE_VSYNC)
            {
                bDuplicate = true;
                break;
            }
        }
        if (!bDuplicate)
        {
            MonitorModes.push_back(CreateIddCxMonitorMode(
                RegMode.Width, RegMode.Height, QUBES_IDD_MODE_VSYNC, IDDCX_MONITOR_MODE_ORIGIN_MONITORDESCRIPTOR));
        }
    }

    pOutArgs->MonitorModeBufferOutputCount = (UINT) MonitorModes.size();

    if (pInArgs->MonitorModeBufferInputCount == 0)
    {
        // The caller was only asking for a count of modes
        return STATUS_SUCCESS;
    }
    if (pInArgs->MonitorModeBufferInputCount < MonitorModes.size())
    {
        // Guard against the registry growing between the size call and the fill call
        return STATUS_BUFFER_TOO_SMALL;
    }

    copy(MonitorModes.begin(), MonitorModes.end(), pInArgs->pMonitorModes);
    pOutArgs->PreferredMonitorModeIdx = s_QubesMonitor.ulPreferredModeIdx;
    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddSampleMonitorGetDefaultModes(IDDCX_MONITOR MonitorObject, const IDARG_IN_GETDEFAULTDESCRIPTIONMODES* pInArgs, IDARG_OUT_GETDEFAULTDESCRIPTIONMODES* pOutArgs)
{
    UNREFERENCED_PARAMETER(MonitorObject);

    // ==============================
    // TODO: In a real driver, this function would be called to generate monitor modes for a monitor with no EDID.
    // Drivers should report modes that are guaranteed to be supported by the transport protocol and by nearly all
    // monitors (such 640x480, 800x600, or 1024x768). If the driver has access to monitor modes from a descriptor other
    // than an EDID, those modes would also be reported here.
    // ==============================

    // Qubes D4: built-in defaults plus the registry-declared modes (at 60 Hz),
    // deduplicated. The count is dynamic now, so build a vector instead of using the
    // fixed-arity array directly.
    vector<IDDCX_MONITOR_MODE> MonitorModes;
    for (DWORD ModeIndex = 0; ModeIndex < ARRAYSIZE(s_SampleDefaultModes); ModeIndex++)
    {
        MonitorModes.push_back(CreateIddCxMonitorMode(
            s_SampleDefaultModes[ModeIndex].Width,
            s_SampleDefaultModes[ModeIndex].Height,
            s_SampleDefaultModes[ModeIndex].VSync,
            IDDCX_MONITOR_MODE_ORIGIN_DRIVER
        ));
    }

    for (const auto& RegMode : QubesReadRegistryModes())
    {
        bool bDuplicate = false;
        for (DWORD ModeIndex = 0; ModeIndex < ARRAYSIZE(s_SampleDefaultModes); ModeIndex++)
        {
            if (s_SampleDefaultModes[ModeIndex].Width == RegMode.Width &&
                s_SampleDefaultModes[ModeIndex].Height == RegMode.Height &&
                s_SampleDefaultModes[ModeIndex].VSync == QUBES_IDD_MODE_VSYNC)
            {
                bDuplicate = true;
                break;
            }
        }
        if (!bDuplicate)
        {
            MonitorModes.push_back(CreateIddCxMonitorMode(
                RegMode.Width, RegMode.Height, QUBES_IDD_MODE_VSYNC, IDDCX_MONITOR_MODE_ORIGIN_DRIVER));
        }
    }

    if (pInArgs->DefaultMonitorModeBufferInputCount == 0)
    {
        pOutArgs->DefaultMonitorModeBufferOutputCount = (UINT) MonitorModes.size();
    }
    else
    {
        // Guard against the registry changing between the size call and the fill call.
        UINT ModesToCopy = (UINT) MonitorModes.size();
        if (ModesToCopy > pInArgs->DefaultMonitorModeBufferInputCount)
        {
            ModesToCopy = pInArgs->DefaultMonitorModeBufferInputCount;
        }
        copy(MonitorModes.begin(), MonitorModes.begin() + ModesToCopy, pInArgs->pDefaultMonitorModes);

        pOutArgs->DefaultMonitorModeBufferOutputCount = ModesToCopy;
        pOutArgs->PreferredMonitorModeIdx = 0;
    }

    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddSampleMonitorQueryModes(IDDCX_MONITOR MonitorObject, const IDARG_IN_QUERYTARGETMODES* pInArgs, IDARG_OUT_QUERYTARGETMODES* pOutArgs)
{
    UNREFERENCED_PARAMETER(MonitorObject);

    vector<IDDCX_TARGET_MODE> TargetModes;

    // Create a set of modes supported for frame processing and scan-out. These are typically not based on the
    // monitor's descriptor and instead are based on the static processing capability of the device. The OS will
    // report the available set of modes for a given output as the intersection of monitor modes with target modes.

    TargetModes.push_back(CreateIddCxTargetMode(3840, 2160, 60));
    TargetModes.push_back(CreateIddCxTargetMode(2560, 1440, 144));
    TargetModes.push_back(CreateIddCxTargetMode(2560, 1440, 90));
    TargetModes.push_back(CreateIddCxTargetMode(2560, 1440, 60));
    TargetModes.push_back(CreateIddCxTargetMode(1920, 1080, 144));
    TargetModes.push_back(CreateIddCxTargetMode(1920, 1080, 90));
    TargetModes.push_back(CreateIddCxTargetMode(1920, 1080, 60));
    TargetModes.push_back(CreateIddCxTargetMode(1600,  900, 60));
    TargetModes.push_back(CreateIddCxTargetMode(1024,  768, 75));
    TargetModes.push_back(CreateIddCxTargetMode(1024,  768, 60));

    // Qubes D4: append the registry-declared modes (at 60 Hz) to the target list too —
    // the OS offers the intersection of monitor and target modes, so a registry mode is
    // only reachable if it is in both. Dedup against the built-ins above.
    const size_t BuiltInCount = TargetModes.size();
    for (const auto& RegMode : QubesReadRegistryModes())
    {
        bool bDuplicate = false;
        for (size_t ModeIndex = 0; ModeIndex < BuiltInCount; ModeIndex++)
        {
            const auto& Existing = TargetModes[ModeIndex].TargetVideoSignalInfo.targetVideoSignalInfo;
            if (Existing.activeSize.cx == RegMode.Width &&
                Existing.activeSize.cy == RegMode.Height &&
                Existing.vSyncFreq.Numerator == QUBES_IDD_MODE_VSYNC)
            {
                bDuplicate = true;
                break;
            }
        }
        if (!bDuplicate)
        {
            TargetModes.push_back(CreateIddCxTargetMode(RegMode.Width, RegMode.Height, QUBES_IDD_MODE_VSYNC));
        }
    }

    pOutArgs->TargetModeBufferOutputCount = (UINT) TargetModes.size();

    if (pInArgs->TargetModeBufferInputCount >= TargetModes.size())
    {
        copy(TargetModes.begin(), TargetModes.end(), pInArgs->pTargetModes);
    }

    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddSampleMonitorAssignSwapChain(IDDCX_MONITOR MonitorObject, const IDARG_IN_SETSWAPCHAIN* pInArgs)
{
    auto* pMonitorContextWrapper = WdfObjectGet_IndirectMonitorContextWrapper(MonitorObject);
    pMonitorContextWrapper->pContext->AssignSwapChain(pInArgs->hSwapChain, pInArgs->RenderAdapterLuid, pInArgs->hNextSurfaceAvailable);
    return STATUS_SUCCESS;
}

_Use_decl_annotations_
NTSTATUS IddSampleMonitorUnassignSwapChain(IDDCX_MONITOR MonitorObject)
{
    auto* pMonitorContextWrapper = WdfObjectGet_IndirectMonitorContextWrapper(MonitorObject);
    pMonitorContextWrapper->pContext->UnassignSwapChain();
    return STATUS_SUCCESS;
}

#pragma endregion
