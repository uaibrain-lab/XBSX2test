// SPDX-License-Identifier: GPL-3.0-or-later
// UaiBrain Xbox: PCSX2 embedded in the SAME AppContainer as the Hub XAML shell.
// This file deliberately does not register an Application, CoreApplication::Run,
// a URI handler, or another APPX. It uses the existing XBSX2 CPU thread.
#include "pcsx2/PrecompiledHeader.h"
// Export declaration lives in the shared C ABI header (MSVC C2375 fix).
#define UAIBRAIN_PS2_CORE_PROVIDER_BUILD 1
#include "ps2_embedded_core_v2.h"
#include "UWPHost.h"
#include "HubSharedHome.h"
#include "pcsx2/VMManager.h"
#include "common/FileSystem.h"
#include <windows.h>
#include <winrt/Windows.UI.Core.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
// Embedded DLL has no SDL_main entrypoint. Match the standalone UWP host:
// prevent SDL3 from rewriting the app entrypoint, then initialize SDL manually.
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>
#include <atomic>
#include <string>
#include <memory>
#include <mutex>

namespace {
std::atomic<bool> s_attached{false};
std::atomic<bool> s_boot_queued{false};
std::atomic<bool> s_exit_after_boot{false};
// A failed C ABI callback must not unwind into the Hub's different runtime.
// Keep the VM unavailable until a fresh app launch can rebuild host state.
std::atomic<bool> s_bridge_faulted{false};
void bridge_fault(const char* operation) noexcept {
 s_bridge_faulted.store(true,std::memory_order_release);
 OutputDebugStringA(operation);
 OutputDebugStringA("\n");
}
std::mutex s_start_mutex;
bool s_window_bound = false;
extern "C" void uwp_redirect_file_apis_embedded(void);

// UTF-16 from the picker, UTF-8 for PCSX2's FileSystem/VMManager.
std::string utf8_path(const wchar_t* path) {
 if(!path) return {};
 int required=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,nullptr,0,nullptr,nullptr);
 if(required<=1||required>32768)return {};
 std::string bytes(static_cast<std::size_t>(required),'\0');
 if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,
                        bytes.data(),required,nullptr,nullptr))return {};
 bytes.pop_back();
 return bytes;
}

int attach_panel(void* abi,uint32_t width,uint32_t height) {
 if(!abi||width<64||height<64||width>4096||height>4096)return 0;
 std::lock_guard<std::mutex> guard(s_start_mutex);
 if(s_bridge_faulted.load(std::memory_order_acquire))return 0;
 if(s_attached.load())return 1;
 try {
  const auto window=winrt::Windows::UI::Core::CoreWindow::GetForCurrentThread();
  if(!window)return 0;
  const char* error=nullptr;
  if(!VMManager::PerformEarlyHardwareChecks(&error))return 0;
  if(!s_window_bound){
   // In contrast to the standalone XBSX2 App, the XAML dispatcher is
   // already running. UWPHost must not try to own or pump it.
   UWPHost::SetWindow(window);
   s_window_bound=true;
  }
  if(!UWPHost::SetXamlSwapChainPanel(abi,width,height))return 0;
  // In the single-package build, PCSX2 is a DLL: its own import table
  // needs the FromApp USB bridge, not the Hub EXE's import table.
  uwp_redirect_file_apis_embedded();
  // SDL native pad and video services initialize in the existing PCSX2 host.
  SDL_SetMainReady();
  if(!UWPHost::InitializeConfig())return 0;
  if(!EmuThread::start())return 0;
  s_attached.store(true);
  return 1;
 } catch(...) {
  return 0;
 }
}
int ready(){
 if(s_bridge_faulted.load(std::memory_order_acquire))return 0;
 try {
  return s_attached.load() && g_emu_thread && g_emu_thread->isRunning();
 } catch(...) {
  bridge_fault("UAIBRAIN_PS2_CORE_READY_EXCEPTION");
  return 0;
 }
}
UaiBrainPs2BootResultV2 boot_disc(const wchar_t* game,
                                  const wchar_t* saves,int auto_resume) {
 try {
 if(!ready())return UAIBRAIN_PS2_V2_NO_CORE;
 const std::string game_file=utf8_path(game);
 const std::string save_root=utf8_path(saves);
 if(game_file.empty()||save_root.empty()||!FileSystem::FileExists(game_file.c_str()))
  return UAIBRAIN_PS2_V2_INVALID_GAME;
 // Same AppContainer: Hub's own LocalFolder is the preferred save root.
 // For optional user-controlled USB media, validate the restricted folder
 // before passing it to XBSX2's non-destructive home adapter.
 const auto local=winrt::to_string(
  winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path());
 const bool is_local=(save_root==local);
 if(!is_local&&!UaiBrainHubStorage::SafeHome(save_root))
  return UAIBRAIN_PS2_V2_INVALID_GAME;
 if(VMManager::GetState()!=VMState::Shutdown)
  return UAIBRAIN_PS2_V2_UNSUPPORTED; // Never overwrite an existing VM.
 // Configure before the CPU thread begins booting the game. Existing
 // memory cards are COPIED, never destroyed, by HubSharedHome::Configure.
 if(is_local) {
  // Never redirect the emulator to a second app's storage, and do not
  // require a USB drive for users who save in the one Hub AppContainer.
  UaiBrainHubStorage::Configure("");
 } else if(!UaiBrainHubStorage::Configure(save_root)) {
  return UAIBRAIN_PS2_V2_INTERNAL_ERROR;
 }
 VMBootParameters params;
 params.filename=game_file;
 params.fullscreen=true;
 if(auto_resume) {
  const std::string state=VMManager::GetSaveStateFileName(game_file.c_str(),-1);
  if(!state.empty() && FileSystem::FileExists(state.c_str()))
   params.save_state=state;
 }
 s_exit_after_boot.store(false,std::memory_order_release);
 s_boot_queued.store(true,std::memory_order_release);
 try {
  g_emu_thread->startVM(std::move(params));
 } catch(...) {
  s_boot_queued.store(false,std::memory_order_release);
  throw;
 }
 return UAIBRAIN_PS2_V2_BOOT_ACCEPTED;
 } catch(...) {
  bridge_fault("UAIBRAIN_PS2_CORE_BOOT_EXCEPTION");
  return UAIBRAIN_PS2_V2_INTERNAL_ERROR;
 }
}
void pump_ui(){
 if(!s_attached.load()||s_bridge_faulted.load(std::memory_order_acquire))return;
 try {
 UWPHost::ProcessPendingEvents();
 // The user may press B while the game is still being queued/initialized.
 // Honor that exit when the VM first becomes valid; do not leave the player
 // in the game after a visible "saving and returning" message.
 if(VMManager::HasValidVM()){
  s_boot_queued.store(false,std::memory_order_release);
  if(s_exit_after_boot.exchange(false,std::memory_order_acq_rel) &&
     g_emu_thread){
   g_emu_thread->shutdownVM(true);
  }
 }
 } catch(...) {
  bridge_fault("UAIBRAIN_PS2_CORE_POLL_EXCEPTION");
 }
}
int has_vm(){
 if(!s_attached.load()||s_bridge_faulted.load(std::memory_order_acquire))return -1;
 try {
  return VMManager::HasValidVM()?1:0;
 } catch(...) {
  bridge_fault("UAIBRAIN_PS2_CORE_VM_STATE_EXCEPTION");
  return -1;
 }
}
void request_exit(){
 if(!s_attached.load()||!g_emu_thread)return;
 try {
 if(VMManager::HasValidVM()){
  s_exit_after_boot.store(false,std::memory_order_release);
  g_emu_thread->shutdownVM(true); // Save memory card and normal resume state.
 }else if(s_boot_queued.load(std::memory_order_acquire)){
  s_exit_after_boot.store(true,std::memory_order_release);
 }
 } catch(...) {
  bridge_fault("UAIBRAIN_PS2_CORE_EXIT_EXCEPTION");
 }
}
const UaiBrainPs2CoreApiV2 s_api{
 UAIBRAIN_PS2_CORE_ABI_V2,sizeof(UaiBrainPs2CoreApiV2),
 attach_panel,ready,boot_disc,pump_ui,has_vm,request_exit
};
}
// The DLL export is linked/imported into the Hub executable; the only
// installed package is the Hub APPX. This is actual PCSX2 host code, not a stub.
// The preceding header declaration already supplies C linkage and dllexport.
// Repeating __declspec(dllexport) here triggers MSVC C2375.
const UaiBrainPs2CoreApiV2* uaibrain_ps2_core_api_v2(void){
 return &s_api;
}
