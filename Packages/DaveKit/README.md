# DaveKit

DaveKit is SakuraCord's Swift wrapper around the vendored
[Discord Audio and Video End-to-End Encryption (DAVE)](https://github.com/discord/libdave)
and MLS implementations. `MediaPipeline` uses it for voice and video encryption;
the app target does not import DaveKit directly.

Run its package tests with:

```sh
./script/test.sh dave
```

The upstream libdave and MLS++ sources retain their own READMEs and license
files under `Sources/CLibdave` and `Sources/CMLS`.

## Vendored sources

- libdave: `v1.2.1/cpp` from `discord/libdave`.
- MLS++ (including HPKE, bytes, and TLS helpers):
  `fc724c3100ce3b5d8565dbd6d93648a440991a8c` from `cisco/mlspp`.

The SwiftPM integration keeps transient signing keys and the OpenSSL 3 / ML-KEM
adaptations. Preserve those choices when importing upstream source updates.

### Local divergences from libdave

Replay protection for repeated key ratchets adds these changes under
`Sources/CLibdave/libdave/cpp`. Reapply them when importing an upstream update.

- `includes/dave/dave_interfaces.h`: `IKeyRatchet::GetDomainIdentity()` lets
  the encryptor and decryptor recognise a reinstall of the same MLS key domain.
- `src/mls_key_ratchet.h` and `src/mls_key_ratchet.cpp`:
  `MlsKeyRatchet::domainIdentity_` keeps the base secret, which is derived per
  epoch and user, as that identity.
- `src/cryptor_manager.h`: `CryptorManager::GetDomainIdentity()` exposes its
  ratchet's identity to the decryptor.
- `src/decryptor.cpp`: `Decryptor::TransitionToKeyRatchet` ignores a ratchet
  whose domain already has a live cryptor manager, so processed frames do not
  get a fresh replay window and expiries are not extended.
- `src/encryptor.cpp`: `Encryptor::SetKeyRatchet` keeps the current ratchet and
  nonce sequence when the same domain is installed again during a protocol
  transition, so AES-GCM nonces are not reused.
