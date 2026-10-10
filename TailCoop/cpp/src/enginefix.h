// Fixes for crashes in Sifu itself (not caused by TailCoop) that two lab games loading at once make more likely.
#pragma once

#include <string>

namespace tc {

// Applies the fixes for this exact game build (exe timestamp + size, original bytes checked first).
// Returns a one-line summary for the log.
std::string ApplyEngineFixes();

}  // namespace tc
