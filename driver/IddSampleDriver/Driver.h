#pragma once

#define NOMINMAX
#include <windows.h>
#include <bugcodes.h>
#include <wudfwdm.h>
#include <wdf.h>
#include <iddcx.h>

#include <dxgi1_5.h>
#include <d3d11_2.h>
#include <avrt.h>
#include <wrl.h>

#include <memory>
#include <vector>

#ifndef CTL_CODE
#include <winioctl.h>
#endif

#include "Trace.h"

// ==============================
// Qubes D4v3: control interface shared with the session side (gui-agent).
// The agent (runs as SYSTEM) opens the device via this device-interface GUID
// (CM_Get_Device_Interface_ListW / CreateFileW on the interface path) and issues
// IOCTL_QIDD_RELOAD_MODES to make the driver replug its monitor WITHOUT a PnP device
// restart: the driver performs IddCxMonitorDeparture on the current monitor, re-reads
// the HKLM\SOFTWARE\QubesIDD 'Modes' registry list, and re-does the arrival with the
// same EDID-less identity. Default interface security (SYSTEM/Administrators) is
// sufficient. A full device restart (devcon restart) remains a working fallback reload
// path.
// Interface GUID: {C7817EB4-B2B6-4996-A48C-04EF247952AB}
// ==============================
static const GUID GUID_DEVINTERFACE_QIDD =
    { 0xC7817EB4, 0xB2B6, 0x4996, { 0xA4, 0x8C, 0x04, 0xEF, 0x24, 0x79, 0x52, 0xAB } };

// METHOD_BUFFERED, FILE_DEVICE_UNKNOWN (0x22), function 0x800, FILE_ANY_ACCESS
// -> IOCTL code value 0x00222000. No input or output buffer.
#define IOCTL_QIDD_RELOAD_MODES CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

namespace Microsoft
{
    namespace WRL
    {
        namespace Wrappers
        {
            // Adds a wrapper for thread handles to the existing set of WRL handle wrapper classes
            typedef HandleT<HandleTraits::HANDLENullTraits> Thread;
        }
    }
}

namespace Microsoft
{
    namespace IndirectDisp
    {
        /// <summary>
        /// Manages the creation and lifetime of a Direct3D render device.
        /// </summary>
        struct IndirectSampleMonitor
        {
            static constexpr size_t szEdidBlock = 128;
            static constexpr size_t szModeList = 3;

            const BYTE pEdidBlock[szEdidBlock];
            const struct SampleMonitorMode {
                DWORD Width;
                DWORD Height;
                DWORD VSync;
            } pModeList[szModeList];
            const DWORD ulPreferredModeIdx;
        };

        /// <summary>
        /// Manages the creation and lifetime of a Direct3D render device.
        /// </summary>
        struct Direct3DDevice
        {
            Direct3DDevice(LUID AdapterLuid);
            Direct3DDevice();
            HRESULT Init();

            LUID AdapterLuid;
            Microsoft::WRL::ComPtr<IDXGIFactory5> DxgiFactory;
            Microsoft::WRL::ComPtr<IDXGIAdapter1> Adapter;
            Microsoft::WRL::ComPtr<ID3D11Device> Device;
            Microsoft::WRL::ComPtr<ID3D11DeviceContext> DeviceContext;
        };

        /// <summary>
        /// Manages a thread that consumes buffers from an indirect display swap-chain object.
        /// </summary>
        class SwapChainProcessor
        {
        public:
            SwapChainProcessor(IDDCX_SWAPCHAIN hSwapChain, std::shared_ptr<Direct3DDevice> Device, HANDLE NewFrameEvent);
            ~SwapChainProcessor();

        private:
            static DWORD CALLBACK RunThread(LPVOID Argument);

            void Run();
            void RunCore();

            IDDCX_SWAPCHAIN m_hSwapChain;
            std::shared_ptr<Direct3DDevice> m_Device;
            HANDLE m_hAvailableBufferEvent;
            Microsoft::WRL::Wrappers::Thread m_hThread;
            Microsoft::WRL::Wrappers::Event m_hTerminateEvent;
        };

        /// <summary>
        /// Provides a sample implementation of an indirect display driver.
        /// </summary>
        class IndirectDeviceContext
        {
        public:
            IndirectDeviceContext(_In_ WDFDEVICE WdfDevice);
            virtual ~IndirectDeviceContext();

            void InitAdapter();
            NTSTATUS FinishInit(UINT ConnectorIndex);

            // Qubes D4v3: control-interface plumbing. InitDeviceControl registers the
            // device interface and creates the reload work item; QueueReloadModes is
            // called from EvtIddCxDeviceIoControl and completes the request from the
            // work item after ReloadModes (departure + re-arrival) has run.
            NTSTATUS InitDeviceControl();
            void QueueReloadModes(_In_ WDFREQUEST Request);
            NTSTATUS ReloadModes();

        protected:
            WDFDEVICE m_WdfDevice;
            IDDCX_ADAPTER m_Adapter;

            // Qubes D4v3 state
            IDDCX_MONITOR m_Monitor = nullptr;          // current monitor (nullptr after departure)
            WDFWORKITEM m_ReloadWorkItem = nullptr;
            WDFREQUEST m_PendingReloadRequest = nullptr; // owned by the in-flight work item
            volatile LONG m_ReloadPending = 0;
        };

        class IndirectMonitorContext
        {
        public:
            IndirectMonitorContext(_In_ IDDCX_MONITOR Monitor);
            virtual ~IndirectMonitorContext();

            void AssignSwapChain(IDDCX_SWAPCHAIN SwapChain, LUID RenderAdapter, HANDLE NewFrameEvent);
            void UnassignSwapChain();

        private:
            IDDCX_MONITOR m_Monitor;
            std::unique_ptr<SwapChainProcessor> m_ProcessingThread;
        } ;
    }
}
