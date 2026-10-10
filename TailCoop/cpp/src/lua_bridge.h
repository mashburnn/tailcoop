// Declarations of the Lua wrapper exported by UE4SS.dll (RC::LuaMadeSimple::Lua), so TailCoopNative can register
// Lua functions without UE4SS's source tree. Linked through UE4SS.lib, an import library generated from
// UE4SS.def (only the members below). Verified against UE4SS v3.0.1-1161 in Ghidra:
//   - the object holds the lua_State* first and is ~0xA8 bytes; the destructor only frees an internal vector;
//   - get_*(i) reads the value at stack index i and removes it, so arguments are read one by one from index 1;
//   - set_*() pushes a value (a result);
//   - register_function() sets a global C closure that calls fn with a wrapper for the calling state.
#pragma once

#include <string>
#include <string_view>

struct lua_State;

namespace RC::LuaMadeSimple {

class __declspec(dllimport) Lua {
public:
    explicit Lua(lua_State* state);
    ~Lua();

    int get_stack_size() const;
    bool is_nil(int index) const;
    bool is_string(int index) const;
    std::string_view get_string(int index) const;
    void discard_value(int index) const;

    void set_nil() const;
    void set_bool(bool value) const;
    void set_integer(long long value) const;
    void set_number(double value) const;
    void set_string(std::string_view value) const;

    void register_function(const std::string& name, int (*const& function)(const Lua&)) const;

private:
    alignas(16) unsigned char m_storage[512];  // real object is ~0xA8 bytes
};

}  // namespace RC::LuaMadeSimple
