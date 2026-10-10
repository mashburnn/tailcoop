// Bone-exact pose sync. The owner of a character reads its whole pose each tick (SkeletalMeshComponent::SnapshotPose:
// the local transform of every bone) and sends it; the other game shows it on a copy through a PoseableMeshComponent
// (Sifu's PoseableMeshComponent::ApplyPoseFromSnapshot), interpolated on the same 100 ms timeline as positions.
//
// Wire format (unreliable, may be split into parts): 0x01 'Q' idLen id u32 clock u32 skeletonHash u16 total u8 flags
//   (1 = keyframe, 2 = has translations) u8 nTrans { u16 listedIndex, i16 x, i16 y, i16 z (0.05 cm) }* u16 start
//   u16 count mask[(count+7)/8] { u32 rotation }* (one per mask bit; all on keyframes). Only bones that changed are
//   sent, with a keyframe every 15 poses (~0.5 s) that repairs anything a lost packet left stale.
// Rotations are "smallest three" quaternions (2-bit index + 3 x 10 bits). Translations are sent only for bones that
// differ from the skeleton's reference pose (pelvis, weapons...). Bones listed: all but IK / camera / VFX helpers.
#pragma once

#include <cstdint>
#include <string>

namespace tc::pose {

constexpr char kMagic = 0x01;

// Function addresses: SkeletalMeshComponent:SnapshotPose, PoseableMeshComponent:ApplyPoseFromSnapshot,
// SkinnedMeshComponent:GetRefPosePosition.
bool Init(uintptr_t snapshotFn, uintptr_t applyFn, uintptr_t refPoseFn, std::string& error);

// Reads `mesh`'s pose and sends it (send = true) or stores it as if received (loopback, for tests).
// Returns the number of bytes encoded, 0 on error.
size_t Capture(uintptr_t mesh, const std::string& id, uint32_t clock, bool send, std::string& error);

// A pose message from the transport (payload starts with kMagic).
void Receive(const std::string& payload);

// Shows `id`'s pose at sender time renderClock on `poseable`; `templateMesh` is a skeletal mesh of the same
// skeleton (the copy's own mesh) that provides the bones the sender doesn't send. Returns a short status:
// "ok", "none" (nothing received), "mismatch" (different skeleton) or an error; ageMs = renderClock - newest pose.
std::string Apply(uintptr_t poseable, uintptr_t templateMesh, const std::string& id, uint32_t renderClock,
                  int* ageMs);

// Drops the cached state of a component that is going away.
void Forget(uintptr_t component);

std::string Stats();

}  // namespace tc::pose
