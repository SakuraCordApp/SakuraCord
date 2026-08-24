# Third-party notices

## Discord client sound effects

SakuraCord includes the classic Discord client sound effects for message
notifications, incoming and outgoing calls, voice join and leave, disconnect,
mute and unmute, deafen and undeafen, camera on and off, and screen-share
start, end, viewer join, and viewer leave.

- Source: Discord's public first-party web-client asset bundle and
  `https://discord.com/assets/`
- Retrieved: 2026-07-29; screen-share assets re-resolved from the current
  first-party client on 2026-08-23
- Verification: the live web-client module names and content-addressed asset
  URLs were resolved directly. The classic assets' HTTP ETags match the
  full-length hashes in the independently archived 2019 asset list; the camera
  assets come from the current first-party client.

| File | SHA-256 |
| --- | --- |
| `call_calling.mp3` | `c3999dbbbea7fca113d6f396b81d6054dd2dd6df79f442b62dfb74afddd36934` |
| `call_ringing.mp3` | `a2365a04f839099538271d06889147475ceef0845f8cc010425618f5dc412880` |
| `camera_off.mp3` | `fe81a2ab7b0581736108c5fc79ab7884ab2e5211a50b69f56badde08d41e7bfb` |
| `camera_on.mp3` | `faeb721a072575c96d1e140aaecd469bf3f7278347596968dddf22fdb65005bf` |
| `deafen.mp3` | `dee4468bbafb321b159dcab42f52d1fbfb1d01358437e0a3088c3345979211b8` |
| `disconnect.mp3` | `c06c7e58099969eacc5f8eb925fb381f445250b9f37acf959b11df72aabb44ca` |
| `message1.mp3` | `31ad0482eee7770597b8aa723a80fd041ade0b076679b12293664f1f1777211b` |
| `mute.mp3` | `f6194168829b0701e8b40817d5173afed4b3b1e0b5074ab82ca31d97e4cb65c1` |
| `stream_ended.mp3` | `a724e183167405783122b997def6b3e6f53020957031224b27c434d6df8ef75f` |
| `stream_started.mp3` | `b5cb29d5d5cc0e8e22fa014bac4a1c2d601f6890ae6db1c18d4b6310283a3271` |
| `stream_user_joined.mp3` | `3b51208e7559fc5b16a297cd8d882648fa7534adf706dfbd529c39266d132213` |
| `stream_user_left.mp3` | `be2f1374b1ec8137eaa7e11357aafe12a3f3e09c0ed759b5d11043e723992061` |
| `undeafen.mp3` | `690b64977594baa41c7978d76259224f67799ba337df2d1045dce970ef82b243` |
| `unmute.mp3` | `1572881f90703c1e0cd138fe7486d2e53c0ac5d8509cade32029fb31650b9304` |
| `user_join.mp3` | `d30746caf3e4675ae0d822d51461a9ad24832afa1e20179c3c2fc7b50b911a26` |
| `user_leave.mp3` | `9fd71c2d8112c82a7fb316602bb1645bc65f5edfa260110bbaae80090fbe9df0` |

Discord has not published an open-source license for these recordings. They
remain the property of Discord and are included only to reproduce familiar
client interaction cues. Their inclusion does not imply Discord affiliation or
endorsement.

## GIF composer icon

The custom GIF composer symbol at
`App/Sources/SakuraCord/Resources/Assets.xcassets/gif.square.symbolset/gif.square.svg`
was created for SakuraCord by **roxleton** on Discord and contributed through
the SakuraCord Discord community.

## SocialSymbols

SakuraCord vendors only the GitHub and Discord symbol sets from SocialSymbols
version 2.0.1 for the external-link rows shown in Settings. The files are
unmodified copies of the upstream package assets.

- Project: <https://github.com/jeremieb/social-symbols>
- Source: `Sources/SocialSymbols/Resources/Assets.xcassets/symbols`
- Revision: `6da9cafdfdf53671e8fe2eaa7d1ed1e7b335400a` (tag `2.0.1`)
- License: `LICENSE` at that revision

Apache License
Version 2.0, January 2004
<http://www.apache.org/licenses/>

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

   "License" shall mean the terms and conditions for use, reproduction,
   and distribution as defined by Sections 1 through 9 of this document.

   "Licensor" shall mean the copyright owner or entity authorized by
   the copyright owner that is granting the License.

   "Legal Entity" shall mean the union of the acting entity and all other
   entities that control, are controlled by, or are under common control
   with that entity. For the purposes of this definition, "control" means
   (i) the power, direct or indirect, to cause the direction or management
   of such entity, whether by contract or otherwise, or (ii) ownership of
   fifty percent (50%) or more of the outstanding shares, or (iii)
   beneficial ownership of such entity.

   "You" (or "Your") shall mean an individual or Legal Entity exercising
   permissions granted by this License.

   "Source" form shall mean the preferred form for making modifications,
   including but not limited to software source code, documentation source,
   and configuration files.

   "Object" form shall mean any form resulting from mechanical
   transformation or translation of a Source form, including but not
   limited to compiled object code, generated documentation, and
   conversions to other media types.

   "Work" shall mean the work of authorship, whether in Source or Object
   form, made available under the License, as indicated by a copyright
   notice that is included in or attached to the work.

   "Derivative Works" shall mean any work, whether in Source or Object
   form, that is based on (or derived from) the Work and for which the
   editorial revisions, annotations, elaborations, or other modifications
   represent, as a whole, an original work of authorship. For the purposes
   of this License, Derivative Works shall not include works that remain
   separable from, or merely link (or bind by name) to the interfaces of,
   the Work and Derivative Works thereof.

   "Contribution" shall mean any work of authorship, including the
   original version of the Work and any modifications or additions to that
   Work or Derivative Works thereof, that is intentionally submitted to
   Licensor for inclusion in the Work by the copyright owner or by an
   individual or Legal Entity authorized to submit on behalf of the
   copyright owner. For the purposes of this definition, "submitted" means
   any form of electronic, verbal, or written communication sent to the
   Licensor or its representatives, including but not limited to
   communication on electronic mailing lists, source code control systems,
   and issue tracking systems that are managed by, or on behalf of, the
   Licensor for the purpose of discussing and improving the Work, but
   excluding communication that is conspicuously marked or otherwise
   designated in writing by the copyright owner as "Not a Contribution."

   "Contributor" shall mean Licensor and any individual or Legal Entity on
   behalf of whom a Contribution has been received by Licensor and
   subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of this
   License, each Contributor hereby grants to You a perpetual, worldwide,
   non-exclusive, no-charge, royalty-free, irrevocable copyright license to
   reproduce, prepare Derivative Works of, publicly display, publicly
   perform, sublicense, and distribute the Work and such Derivative Works in
   Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of this
   License, each Contributor hereby grants to You a perpetual, worldwide,
   non-exclusive, no-charge, royalty-free, irrevocable (except as stated in
   this section) patent license to make, have made, use, offer to sell, sell,
   import, and otherwise transfer the Work, where such license applies only
   to those patent claims licensable by such Contributor that are necessarily
   infringed by their Contribution(s) alone or by combination of their
   Contribution(s) with the Work to which such Contribution(s) was
   submitted. If You institute patent litigation against any entity
   (including a cross-claim or counterclaim in a lawsuit) alleging that the
   Work or a Contribution incorporated within the Work constitutes direct or
   contributory patent infringement, then any patent licenses granted to You
   under this License for that Work shall terminate as of the date such
   litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the Work or
   Derivative Works thereof in any medium, with or without modifications, and
   in Source or Object form, provided that You meet the following conditions:

   (a) You must give any other recipients of the Work or Derivative Works a
   copy of this License; and

   (b) You must cause any modified files to carry prominent notices stating
   that You changed the files; and

   (c) You must retain, in the Source form of any Derivative Works that You
   distribute, all copyright, patent, trademark, and attribution notices from
   the Source form of the Work, excluding those notices that do not pertain to
   any part of the Derivative Works; and

   (d) If the Work includes a "NOTICE" text file as part of its distribution,
   then any Derivative Works that You distribute must include a readable copy
   of the attribution notices contained within such NOTICE file, excluding
   those notices that do not pertain to any part of the Derivative Works, in
   at least one of the following places: within a NOTICE text file distributed
   as part of the Derivative Works; within the Source form or documentation,
   if provided along with the Derivative Works; or, within a display generated
   by the Derivative Works, if and wherever such third-party notices normally
   appear. The contents of the NOTICE file are for informational purposes only
   and do not modify the License. You may add Your own attribution notices
   within Derivative Works that You distribute, alongside or as an addendum to
   the NOTICE text from the Work, provided that such additional attribution
   notices cannot be construed as modifying the License.

   You may add Your own copyright statement to Your modifications and may
   provide additional or different license terms and conditions for use,
   reproduction, or distribution of Your modifications, or for any such
   Derivative Works as a whole, provided Your use, reproduction, and
   distribution of the Work otherwise complies with the conditions stated in
   this License.

5. Submission of Contributions. Unless You explicitly state otherwise, any
   Contribution intentionally submitted for inclusion in the Work by You to
   the Licensor shall be under the terms and conditions of this License,
   without any additional terms or conditions. Notwithstanding the above,
   nothing herein shall supersede or modify the terms of any separate license
   agreement you may have executed with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade names,
   trademarks, service marks, or product names of the Licensor, except as
   required for reasonable and customary use in describing the origin of the
   Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or agreed to in
   writing, Licensor provides the Work (and each Contributor provides its
   Contributions) on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
   ANY KIND, either express or implied, including, without limitation, any
   warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or
   FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for
   determining the appropriateness of using or redistributing the Work and
   assume any risks associated with Your exercise of permissions under this
   License.

8. Limitation of Liability. In no event and under no legal theory, whether in
   tort (including negligence), contract, or otherwise, unless required by
   applicable law (such as deliberate and grossly negligent acts) or agreed to
   in writing, shall any Contributor be liable to You for damages, including
   any direct, indirect, special, incidental, or consequential damages of any
   character arising as a result of this License or out of the use or inability
   to use the Work (including but not limited to damages for loss of goodwill,
   work stoppage, computer failure or malfunction, or any and all other
   commercial damages or losses), even if such Contributor has been advised of
   the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing the Work
   or Derivative Works thereof, You may choose to offer, and charge a fee for,
   acceptance of support, warranty, indemnity, or other liability obligations
   and/or rights consistent with this License. However, in accepting such
   obligations, You may act only on Your own behalf and on Your sole
   responsibility, not on behalf of any other Contributor, and only if You
   agree to indemnify, defend, and hold each Contributor harmless for any
   liability incurred by, or claims asserted against, such Contributor by
   reason of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

## Sparkle

SakuraCord uses the official Sparkle 2 software update framework, pinned to
version 2.9.4.

- Project: <https://github.com/sparkle-project/Sparkle>
- License: `LICENSE` at tag `2.9.4`

Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### Sparkle external licenses

`bspatch.c` and `bsdiff.c`, from bsdiff 4.3
<http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE.

`sais.c` and `sais.h`, from sais-lite (2010/08/07)
<https://sites.google.com/site/yuta256/sais>:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Portable C implementation of Ed25519, from
<https://github.com/orlp/ed25519>:

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use
of this software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter it and redistribute it freely, subject to
the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a product,
   an acknowledgment in the product documentation would be appreciated but is
   not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

`SUSignatureVerifier.m`:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted providing that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE.

## Zstandard

SakuraCord uses Zstandard, pinned to version 1.5.7, for the Discord desktop
Gateway's `zstd-stream` compression.

- Project: <https://github.com/facebook/zstd>
- License: `LICENSE` at tag `v1.5.7`

BSD License

For Zstandard software

Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name Facebook, nor Meta, nor the names of its contributors may
  be used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Generated emoji catalog

`App/Sources/SakuraCord/Resources/emoji-catalog.json` is generated by
`script/generate_emoji_catalog.swift`. It combines the fully-qualified entries
from Unicode Emoji 17.0 with the complete matching alias arrays from the
Emojibase English JoyPixels shortcode dataset. Skin-tone variants inherit their
base emoji's aliases. The raw upstream files are not bundled or committed.

### Unicode Emoji data

- Project: <https://www.unicode.org/emoji/>
- Source: <https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt>
- Version: 17.0
- Retrieved: 2026-07-16

UNICODE LICENSE V3 COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY DOWNLOADING,
INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR SOFTWARE, YOU
UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE TERMS AND CONDITIONS
OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT DOWNLOAD, INSTALL, COPY,
DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a copy of
data files and any associated documentation (the "Data Files") or software and
any associated documentation (the "Software") to deal in the Data Files or
Software without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, and/or sell copies of the Data Files
or Software, and to permit persons to whom the Data Files or Software are
furnished to do so, provided that either (a) this copyright and permission
notice appear with all copies of the Data Files or Software, or (b) this
copyright and permission notice appear in associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF THIRD
PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE BE
LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES, OR ANY
DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not be
used in advertising or otherwise to promote the sale, use or other dealings in
these Data Files or Software without prior written authorization of the
copyright holder.

### Emojibase shortcode data

Emojibase maps its `discord` shortcode preset to `joypixels`; Discord does not
publish an authoritative shortcode dataset.

- Project: <https://github.com/milesj/emojibase>
- Revision: `a5fc630a91ca42cddf3f4a66492965600fd3bce8`
- Source path: `packages/data/en/shortcodes/joypixels.raw.json`
- Retrieved: 2026-07-16

MIT License

Copyright (c) 2017-2019 Miles Johnson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## HCaptcha Swift package

SakuraCord pins the Paicord fork at revision
`29de12bd290c5cc9c61b3e3c15fe9a9d21449465`.

The license text in both that fork and the upstream SDK says the SDK is made
available to Enterprise customers under the MIT license. Before publicly
distributing SakuraCord source or binaries with this dependency, confirm that
the project qualifies for that grant or replace the dependency with an
appropriately licensed implementation. Reproducing the notice below preserves
the attribution but does not resolve that eligibility question.

- Project: <https://github.com/llsc12/hcaptcha>
- Source license: `LICENSE` at the pinned revision

Copyright © 2025 Lakhan Lothiyi

Copyright © 2020 Intuition Machines, Inc. <support@hcaptcha.com>

Made available for use by our Enterprise customers under the MIT license.

Some portions Copyright © 2018 Flávio Caetano <flavio@vieiracaetano.com> and
integrated under the MIT license:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
