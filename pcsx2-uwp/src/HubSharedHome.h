// SPDX-License-Identifier: GPL-3.0-or-later
// Original UaiBrain Hub adapter: opt-in external PS2 save storage.
// Independently implemented for the XBSX2 fork. Existing files are NEVER
// deleted, moved or overwritten; if migration is incomplete the emulator
// continues using its private folders, rather than silently losing saves.
#pragma once

#include "pcsx2/Host.h"
#include "pcsx2/VMManager.h"
#include "common/Console.h"
#include "common/FileSystem.h"
#include "common/Path.h"
#include <cctype>
#include <string>
#include <vector>

namespace UaiBrainHubStorage {

inline bool SafeHome(const std::string& home) {
    if (home.size() < 7 || home.size() > 240 ||
        home[1] != ':' || home[2] != '\\' ||
        !(std::isalpha(static_cast<unsigned char>(home[0]))))
        return false;
    const char drive = static_cast<char>(std::toupper(static_cast<unsigned char>(home[0])));
    if (drive == 'D') {
        if (home.rfind("D:\\DevelopmentFiles\\UaiBrainHub\\PS2", 0) != 0)
            return false;
    } else if (drive < 'E' || drive > 'Z') {
        return false;
    }
    for (size_t i=3; i<home.size(); ++i) {
        const unsigned char c=static_cast<unsigned char>(home[i]);
        if (c < 32 || c == 127 || c == ':' || c == '"' || c == '?' ||
            c == '*' || c == '<' || c == '>' || c == '|' || c == '/')
            return false;
    }
    if (home.find("\\..\\") != std::string::npos ||
        home.find("\\.\\") != std::string::npos ||
        home.find("\\\\") != std::string::npos ||
        home.back() == '.' || home.back() == '\\')
        return false;
    return true;
}

struct HomeFolder {
    const char* setting;
    const char* local_name;
    const char* shared_name;
};

inline constexpr HomeFolder kFolders[] = {
    {"Bios", "bios", "bios"},
    {"MemoryCards", "memcards", "memory cards"},
    {"Savestates", "sstates", "states"},
};

inline bool CopyOriginalFiles(const std::string& source, const std::string& destination) {
    if (!FileSystem::DirectoryExists(source.c_str()))
        return true;
    FileSystem::FindResultsArray files;
    if (!FileSystem::FindFiles(source.c_str(), "*",
          FILESYSTEM_FIND_FILES | FILESYSTEM_FIND_RECURSIVE |
          FILESYSTEM_FIND_RELATIVE_PATHS, &files))
        return false;
    for (const FILESYSTEM_FIND_DATA& file : files) {
        const std::string original=Path::Combine(source,file.FileName);
        const std::string copy=Path::Combine(destination,file.FileName);
        if (FileSystem::FileExists(copy.c_str()))
            continue; // Do not overwrite an existing memory card/state/BIOS.
        const std::string dir(Path::GetDirectory(copy));
        if (!FileSystem::CreateDirectoryPath(dir.c_str(),true) ||
            !FileSystem::CopyFilePath(original.c_str(),copy.c_str(),false)) {
            Console.ErrorFmt("UaiBrain Hub: save migration failed for {}; original untouched.", original);
            return false;
        }
    }
    return true;
}

// Call after UWPHost::InitializeConfig and before any VM boot.
// With no home, return to the original local settings and leave USB files alone.
inline bool Configure(const std::string& home) {
    if (VMManager::HasValidVM())
        return false;
    bool external=!home.empty() && SafeHome(home);
    if (external) {
        external=FileSystem::CreateDirectoryPath(home.c_str(),true);
        for (const HomeFolder& folder : kFolders) {
            if (!external)break;
            const std::string destination=Path::Combine(home,folder.shared_name);
            external=FileSystem::CreateDirectoryPath(destination.c_str(),true);
            if (!external)break;
            // The source always refers to the internal originals, never an
            // unrelated USB directory left in settings by another session.
            const std::string source=Path::Combine(EmuFolders::DataRoot,folder.local_name);
            external=CopyOriginalFiles(source,destination);
        }
    }
    if (!external && !home.empty())
        Console.Error("UaiBrain Hub: USB saves unavailable; preserving internal PS2 saves.");
    bool changed=false;
    {
        auto lock=Host::GetSettingsLock();
        SettingsInterface* settings=Host::Internal::GetBaseSettingsLayer();
        if (!settings)return false;
        const bool wasExternal=settings->GetBoolValue("UaiBrainHub","ExternalHome",false);
        if (external) {
            for (const HomeFolder& folder : kFolders) {
                const std::string path=Path::Combine(home,folder.shared_name);
                settings->SetStringValue("Folders",folder.setting,path.c_str());
            }
            settings->SetBoolValue("UaiBrainHub","ExternalHome",true);
            changed=true;
        } else if (wasExternal) {
            for (const HomeFolder& folder : kFolders)
                settings->SetStringValue("Folders",folder.setting,folder.local_name);
            settings->SetBoolValue("UaiBrainHub","ExternalHome",false);
            changed=true;
        }
    }
    if (changed) {
        Host::CommitBaseSettingChanges();
        VMManager::Internal::UpdateEmuFolders();
        Console.WriteLn(external?
            "UaiBrain Hub: PS2 external BIOS/memory cards/savestates configured.":
            "UaiBrain Hub: original internal PS2 folders restored.");
    }
    return external;
}

} // namespace UaiBrainHubStorage
