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

- libdave: `v1.3.0/cpp` from `discord/libdave`, unmodified apart from the
  trimming below.
- MLS++ (including HPKE, bytes, and TLS helpers):
  `fc724c3100ce3b5d8565dbd6d93648a440991a8c` from `cisco/mlspp`.

The SwiftPM integration keeps transient signing keys and the OpenSSL 3 / ML-KEM
adaptations. Preserve those choices when importing upstream source updates.

Each vendored tree keeps only the source and header directories `Package.swift`
builds from, plus upstream's `LICENSE` and `README.md` files. When importing an
update, drop everything else (build systems, CI, tests, fuzzing, tools,
bindings, and unused libraries) and delete files in the kept directories that
the integration does not build: libdave's BoringSSL cryptor, WASM bindings,
and every persisted key-pair store except `src/mls/persisted_key_pair_null.cpp`.

### Local divergences from MLS++

Apart from the trimming above, the vendored tree under `Sources/CMLS/mlspp`
changes only error text compared with upstream
`fc724c3100ce3b5d8565dbd6d93648a440991a8c`: each generic
`Unsupported algorithm` names what was unsupported, and some include the
rejected ID. These came with the initial import, which does not record why.

- `src/crypto.cpp`: signature and cipher-suite signature-scheme lookups.
- `src/credential.cpp`: credential signature lookup.
- `lib/hpke/src/aead_cipher.cpp`: AEAD key, nonce, tag, and cipher lookups.
- `lib/hpke/src/group.cpp`: EC curve names, prime curves, scalar masks, and raw
  curves.
- `lib/hpke/src/hkdf.cpp`: digest-to-HKDF lookup.
- `lib/hpke/src/hpke.cpp`: KEM, KDF, and AEAD ID lookups.
- `README.md`: links RFC 9420 instead of the draft.

`include/mls/crypto.h`, `src/state.cpp`, `src/treekem.cpp`, and
`lib/hpke/src/signature.cpp` match upstream; their changes in the last import
came from upstream itself.
