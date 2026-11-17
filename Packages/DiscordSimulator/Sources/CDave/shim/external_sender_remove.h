// The voice server's side of DAVE for Swift: libdave's test external sender
// C API (declared here because its upstream header includes <dave/dave.h>,
// which a Swift importer of this module can't resolve), plus Remove, which
// that wrapper lacks and a voice server needs when someone leaves.
#pragma once

#include "../libdave/cpp/includes/dave/dave.h"

#ifdef __cplusplus
extern "C" {
#endif

DAVE_DECLARE_OPAQUE_HANDLE(DAVEExternalSenderHandle);

DAVE_EXPORT DAVEExternalSenderHandle daveExternalSenderCreate(uint64_t groupId);
DAVE_EXPORT void daveExternalSenderDestroy(DAVEExternalSenderHandle externalSender);
DAVE_EXPORT void daveExternalSenderGetMarshalledExternalSender(DAVEExternalSenderHandle externalSender,
                                                               uint8_t** marshalledExternalSender,
                                                               size_t* length);
DAVE_EXPORT void daveExternalSenderProposeAdd(DAVEExternalSenderHandle externalSender,
                                              uint32_t epoch,
                                              uint8_t* keyPackage,
                                              size_t keyPackageLength,
                                              uint8_t** proposal,
                                              size_t* proposalLength);
DAVE_EXPORT void daveExternalSenderSplitCommitWelcome(DAVEExternalSenderHandle externalSender,
                                                      uint8_t* commitWelcome,
                                                      size_t commitWelcomeLength,
                                                      uint8_t** commit,
                                                      size_t* commitLength,
                                                      uint8_t** welcome,
                                                      size_t* welcomeLength);
DAVE_EXPORT void daveExternalSenderProposeRemove(DAVEExternalSenderHandle externalSender,
                                                 uint32_t epoch,
                                                 uint32_t leafIndex,
                                                 uint8_t** proposal,
                                                 size_t* proposalLength);

#ifdef __cplusplus
}
#endif
