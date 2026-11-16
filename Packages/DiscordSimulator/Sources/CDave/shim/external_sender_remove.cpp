#include "external_sender_remove.h"
#include "../libdave/cpp/test/capi/external_sender_wrapper.h"

#include <cstdlib>
#include <cstring>

#include "../libdave/cpp/test/external_sender.h"

void daveExternalSenderProposeRemove(DAVEExternalSenderHandle externalSenderHandle,
                                     uint32_t epoch,
                                     uint32_t leafIndex,
                                     uint8_t** proposal,
                                     size_t* proposalLength)
{
    auto externalSender = reinterpret_cast<discord::dave::test::ExternalSender*>(externalSenderHandle);
    auto bytes = externalSender->ProposeRemove(epoch, leafIndex);
    *proposal = static_cast<uint8_t*>(malloc(bytes.size()));
    memcpy(*proposal, bytes.data(), bytes.size());
    *proposalLength = bytes.size();
}
