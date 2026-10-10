// Declarations of UE4SS's exported Unreal wrappers (UE4SS.dll, see UE4SS.def). The game's objects are used through
// these exactly as UE4SS does internally: a game pointer is cast to the wrapper type and the exported member called.
#pragma once

#include <cstdint>
#include <functional>
#include <string>

namespace RC::Unreal {

class UFunction;
class FOutputDevice;

class __declspec(dllimport) UObject {
public:
    std::wstring GetFullName(UObject* StopOuter = nullptr) const;
    void ProcessEvent(UFunction* Function, void* Params);
};

// Same memory as the engine's FName (comparison index + number).
class __declspec(dllimport) FName {
public:
    std::wstring ToString();

private:
    uint32_t comparisonIndex_;
    uint32_t number_;
};

class __declspec(dllimport) FField {
private:
    FField*& GetNext();  // private in UE4SS (the export's mangled name says so); reached through FieldWalker
    friend struct FieldWalker;
};

struct FieldWalker {
    static FField* Next(FField* field) { return field->GetNext(); }
};

class __declspec(dllimport) UStruct {
public:
    FField*& GetChildProperties();
    void InitializeStruct(void* Dest, int32_t ArrayDim = 1) const;
    void DestroyStruct(void* Dest, int32_t ArrayDim = 1) const;
};

class __declspec(dllimport) UFunction {
public:
    uint16_t& GetParmsSize();
};

class __declspec(dllimport) FString {
public:
    FString();
    ~FString();

    // Same memory as the engine's FString (a TArray<TCHAR>).
    const wchar_t* Data() const { return data_; }
    int32_t Num() const { return num_; }

private:
    wchar_t* data_;
    int32_t num_;
    int32_t max_;
};

class __declspec(dllimport) FProperty {
public:
    int32_t GetSize();
    int32_t& GetOffset_Internal();
    // FProperty virtuals: Sifu's FProperty vtable matches UE4SS's (unlike UObject/UStruct, shifted by one entry).
    void InitializeValue(void* Dest) const;
    void DestroyValue(void* Dest);
    void ExportTextItem(FString& ValueStr, const void* PropertyValue, const void* DefaultValue, UObject* Parent,
                        int32_t PortFlags, UObject* ExportRootScope);
    const wchar_t* ImportText(const wchar_t* Buffer, void* Data, int32_t PortFlags, UObject* OwnerObject,
                              FOutputDevice* ErrorText) const;
};

class __declspec(dllimport) FUObjectArray {
public:
    // The engine's GUObjectArray (UE 4.26 layout: TUObjectArray ObjObjects at +0x10 = FUObjectItem** chunks,
    // preallocated, int32 MaxElements, NumElements, MaxChunks, NumChunks; FUObjectItem = 0x18 bytes, 64K per chunk).
    static void* GetGUObjectArrayAddress();
};

namespace Hook {
// Called before every UObject::ProcessEvent (context object, function, parameter buffer), on the calling thread.
__declspec(dllimport) void RegisterProcessEventPreCallback(std::function<void(UObject*, UFunction*, void*)> callback);
// Called after it (the parameter buffer then holds the out parameters / return value, before the caller reads them).
__declspec(dllimport) void RegisterProcessEventPostCallback(std::function<void(UObject*, UFunction*, void*)> callback);
}  // namespace Hook

}  // namespace RC::Unreal
