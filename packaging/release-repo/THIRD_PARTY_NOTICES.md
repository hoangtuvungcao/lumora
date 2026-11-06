# Third-party notices - Lumora

> Generated on 2026-11-06 by `python3 -I packaging/release-repo/tools/gen_third_party_notices.py` (from `cargo metadata`, `flutter pub deps` and the hand-maintained lists inside the script). Do not edit by hand; edit the script and re-run it.

Lumora is proprietary freeware (see LICENSE.md). It is built with the open-source and third-party components listed below, which remain under their own licenses. Nothing in the Lumora license limits the rights those licenses give you for those components.

Scope: the Lumora desktop and mobile apps (Flutter UI + `lumora_ffi` Rust core with media features) and the `lumorad` command-line node, for targets: x86_64-unknown-linux-gnu, x86_64-pc-windows-msvc, aarch64-apple-darwin, x86_64-apple-darwin, aarch64-apple-ios, aarch64-linux-android, armv7-linux-androideabi, x86_64-linux-android. Rust crates per target: aarch64-apple-darwin=369, aarch64-apple-ios=363, aarch64-linux-android=365, armv7-linux-androideabi=363, x86_64-apple-darwin=370, x86_64-linux-android=366, x86_64-pc-windows-msvc=378, x86_64-unknown-linux-gnu=411.

## Summary

License under which each component is used (for "A OR B" choices the first option in the order MIT, Apache-2.0, BSD, ISC, Zlib, ... is elected).

| License | Rust crates | Dart packages | Other (SDK, native, assets) | Total |
|---|---:|---:|---:|---:|
| MIT | 425 | 38 | 4 | 467 |
| BSD-3-Clause | 9 | 60 | 5 | 74 |
| Apache-2.0 | 12 | 5 | 2 | 19 |
| Unicode-3.0 | 18 | 0 | 1 | 19 |
| ISC | 4 | 0 | 1 | 5 |
| MPL-2.0 | 2 | 1 | 0 | 3 |
| Zlib | 3 | 0 | 0 | 3 |
| Apache-2.0 AND ISC | 1 | 0 | 1 | 2 |
| CC-BY-4.0 | 0 | 0 | 2 | 2 |
| CC0-1.0 | 2 | 0 | 0 | 2 |
| CDLA-Permissive-2.0 | 2 | 0 | 0 | 2 |
| NOASSERTION | 0 | 0 | 2 | 2 |
| OFL-1.1 | 0 | 0 | 2 | 2 |
| Apache-2.0 AND BSD-3-Clause AND MIT | 0 | 1 | 0 | 1 |
| Apache-2.0 AND MIT | 0 | 1 | 0 | 1 |
| Apache-2.0 WITH LLVM-exception | 0 | 0 | 1 | 1 |
| BSD-3-Clause AND Apache-2.0 | 0 | 0 | 1 | 1 |
| BSD-3-Clause AND ISC | 0 | 1 | 0 | 1 |
| BSD-3-Clause AND MIT | 1 | 0 | 0 | 1 |
| BSD-3-Clause AND MIT AND WTFPL AND blessing | 1 | 0 | 0 | 1 |
| BSD-3-Clause AND MIT AND Zlib | 0 | 1 | 0 | 1 |
| BSD-3-Clause AND Zlib | 0 | 1 | 0 | 1 |
| BSD-3-Clause AND blessing | 0 | 0 | 1 | 1 |
| ISC AND MIT | 0 | 1 | 0 | 1 |
| LicenseRef-Google-Android-SDK | 0 | 0 | 1 | 1 |
| LicenseRef-InnoSetup | 0 | 0 | 1 | 1 |
| LicenseRef-Microsoft-VC-Redist | 0 | 0 | 1 | 1 |
| LicenseRef-WebM-Patent-Grant | 0 | 0 | 1 | 1 |
| MIT AND Unicode-3.0 | 1 | 0 | 0 | 1 |
| **Total** | **481** | **110** | **27** | **618** |

## Main components

| Component | License | Notes |
|---|---|---|
| Rust crates (481, the Lumora core) | mostly MIT / Apache-2.0 | see "Rust crates" below |
| Flutter framework 3.38.9 | BSD-3-Clause | Copyright 2014 The Flutter Authors |
| Flutter engine incl. Skia, Impeller, HarfBuzz, ICU, FreeType, BoringSSL, zlib, ... | BSD-3-Clause (Skia, Impeller, engine) + per-component licenses | 71 components; full texts in the app (Settings > About > Open-source licenses) |
| Dart SDK 3.10.8 | BSD-3-Clause | Copyright 2012 the Dart project authors |
| Noto Animated Emoji (about 120 Lottie animations, modified) | CC-BY-4.0 | all |
| Noto Color Emoji font (COLRv1) | OFL-1.1 | Windows, Linux |
| Be Vietnam Pro font | OFL-1.1 | all |
| Phosphor Icons (icon fonts via phosphor_flutter) | MIT | all |
| Material Icons font (Flutter SDK, tree-shaken) | CC-BY-4.0 | all |
| PDFium (prebuilt by pdfium-binaries / pdfium-xcframework, downloaded by pdfium_flutter at build time) chromium/7520 | BSD-3-Clause AND Apache-2.0 | all |
| Opus audio codec (Xiph.Org and contributors) (in crate audiopus_sys 0.2.2) | BSD-3-Clause | |
| SpeexDSP echo canceller (Xiph.Org and contributors) (in crate aec-rs-sys 1.0.0) | BSD-3-Clause | |
| libsecp256k1 (Bitcoin Core contributors) (in crate secp256k1-sys 0.10.1) | MIT | |
| OpenSSL 3.x libcrypto (used by SQLCipher) (in crate openssl-src 300.6.1+3.6.3) | Apache-2.0 | |
| SQLCipher (Zetetic LLC) with SQLite (public domain) and LibTomCrypt (in crate sqlcipher-src 419.0.6+sqlcipher-4.19.0-sqlite-3.53.4-libtomcrypt-1.18.2) | BSD-3-Clause AND blessing | |
| BoringSSL / OpenSSL-derived crypto code inside ring (in crate ring 0.17.14) | Apache-2.0 AND ISC | |
| rustls (TLS) 0.23.46 | Apache-2.0 OR ISC OR MIT | |
| quinn (QUIC) 0.11.12 | MIT OR Apache-2.0 | |
| vodozemac (Olm/Megolm crypto) 0.11.1 | Apache-2.0 | |
| tokio 1.54.1 | MIT | |
| mainline (BitTorrent DHT) 8.0.1 | MIT | |
| nnnoiseless (RNNoise port) 0.5.2 | BSD-3-Clause | |
| cpal (audio I/O) 0.18.2 | Apache-2.0 | |
| pdfrx 2.2.24 (Dart) | MIT | |
| flutter_map 8.3.2 (Dart) | BSD-3-Clause | |
| lottie 3.3.3 (Dart) | MIT | |
| just_audio 0.10.6 (Dart) | Apache-2.0 AND MIT | |
| record 6.2.1 (Dart) | BSD-3-Clause | |
| file_picker 13.3.2 (Dart) | MIT | |

## Copyleft and other attention items

| Ecosystem | Component | Elected license | Declared |
|---|---|---|---|
| Rust | attohttpc 0.30.1 | MPL-2.0 | MPL-2.0 |
| Rust | option-ext 0.2.0 | MPL-2.0 | MPL-2.0 |
| Dart | dbus 0.8.0 | MPL-2.0 | MPL-2.0 |

MPL-2.0 is file-level copyleft: the binary may be distributed under any terms, but recipients must be told where the MPL-covered source code can be obtained (the unmodified sources are on crates.io / pub.dev - the links in the tables satisfy this as long as Lumora does not modify those files) and the MPL notice must not be removed.

libdbus-sys is used with features `default, pkg-config`: it links the system libdbus dynamically (the `vendored` feature, which would statically link libdbus under AFL-2.1 OR GPL-2.0-or-later, must stay off).

See also "Notes" at the end (video codecs, proprietary runtime pieces).

## Rust crates

Grouped by the license expression declared in each crate's Cargo.toml. "Copyright" shows the copyright line(s) found in the crate's packaged license file (or its authors when the crate packages none). The full license texts follow in "License texts".

### MIT OR Apache-2.0 (259)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| aead | 0.5.2 | https://github.com/RustCrypto/traits | Copyright (c) 2019 The RustCrypto Project Developers; Copyright (c) 2019 MobileCoin, LLC |
| aead | 0.6.1 | https://github.com/RustCrypto/traits | Copyright (c) 2019-2026 The RustCrypto Project Developers; Copyright (c) 2019 MobileCoin, LLC |
| aes | 0.8.4 | https://github.com/RustCrypto/block-ciphers | Copyright (c) 2018 Artyom Pavlov |
| aes | 0.9.4 | https://github.com/RustCrypto/block-ciphers | Copyright (c) 2018-2024 The RustCrypto Project Developers; Copyright (c) 2018 Artyom Pavlov |
| allocator-api2 | 0.2.21 | https://github.com/zakarumych/allocator-api2 | Authors: Zakarum <zaq.dev@icloud.com> |
| anstream | 1.0.0 | https://github.com/rust-cli/anstyle.git | Copyright (c) Individual contributors |
| anstyle | 1.0.14 | https://github.com/rust-cli/anstyle.git | Copyright (c) Individual contributors |
| anstyle-parse | 1.0.0 | https://github.com/rust-cli/anstyle.git | Copyright (c) Individual contributors |
| anstyle-query | 1.1.5 | https://github.com/rust-cli/anstyle.git | Copyright (c) Individual contributors |
| anstyle-wincon | 3.0.11 | https://github.com/rust-cli/anstyle.git | Copyright (c) Individual contributors |
| anyhow | 1.0.104 | https://github.com/dtolnay/anyhow | Authors: David Tolnay <dtolnay@gmail.com> |
| argon2 | 0.5.3 | https://github.com/RustCrypto/password-hashes/tree/master/argon2 | Copyright (c) 2021-2024 The RustCrypto Project Developers |
| array-init | 2.1.0 | https://github.com/Manishearth/array-init/ | Copyright 2017-2020 The array-init developers; Copyright (c) 2017-2020 The array-init developers |
| arrayvec | 0.7.8 | https://github.com/bluss/arrayvec | Copyright (c) Ulrik Sverdrup "bluss" 2015-2023 |
| asn1-rs | 0.7.2 | https://github.com/rusticata/asn1-rs.git | Copyright (c) 2017 Pierre Chifflier |
| asn1-rs-derive | 0.6.0 | https://github.com/rusticata/asn1-rs.git | Copyright (c) 2017 Pierre Chifflier |
| asn1-rs-impl | 0.2.0 | https://github.com/rusticata/asn1-rs.git | Authors: Pierre Chifflier <chifflier@wzdftpd.net> |
| async-broadcast | 0.7.2 | https://github.com/smol-rs/async-broadcast | Copyright 2020 Yoshua Wuyts; Copyright (c) 2020 Yoshua Wuyts |
| async-recursion | 1.2.0 | https://github.com/dcchut/async-recursion | Authors: Robert Usher <266585+dcchut@users.noreply.github.com> |
| async-trait | 0.1.92 | https://github.com/dtolnay/async-trait | Authors: David Tolnay <dtolnay@gmail.com> |
| base64 | 0.22.1 | https://github.com/marshallpierce/rust-base64 | Copyright (c) 2015 Alice Maz |
| base64 | 0.23.1 | https://github.com/marshallpierce/rust-base64 | Copyright (c) 2025 Alice Maz, Marshall Pierce |
| bitflags | 1.3.2 | https://github.com/bitflags/bitflags | Copyright (c) 2014 The Rust Project Developers |
| bitflags | 2.13.2 | https://github.com/bitflags/bitflags | Copyright (c) 2014 The Rust Project Developers |
| blake2 | 0.10.6 | https://github.com/RustCrypto/hashes | Copyright (c) 2015-2016 The blake2-rfc Developers, Cesar Barros; Copyright (c) 2017 Artyom Pavlov |
| block-buffer | 0.10.4 | https://github.com/RustCrypto/utils | Copyright (c) 2018-2019 The RustCrypto Project Developers |
| block-buffer | 0.12.1 | https://github.com/RustCrypto/utils | Copyright (c) 2018-2025 The RustCrypto Project Developers |
| block-padding | 0.3.3 | https://github.com/RustCrypto/utils | Copyright (c) 2018-2019 The RustCrypto Project Developers |
| block-padding | 0.4.2 | https://github.com/RustCrypto/utils | Copyright (c) 2018-2025 The RustCrypto Project Developers |
| cbc | 0.1.2 | https://github.com/RustCrypto/block-modes | Copyright (c) 2018-2022 RustCrypto Developers; Copyright (c) 2018 Artyom Pavlov |
| cbc | 0.2.1 | https://github.com/RustCrypto/block-modes | Copyright (c) 2018-2022 RustCrypto Developers; Copyright (c) 2018 Artyom Pavlov |
| cc | 1.11.0 | https://github.com/rust-lang/cc-rs | Copyright (c) 2014 Alex Crichton |
| cfg-if | 1.0.5 | https://github.com/rust-lang/cfg-if | Copyright (c) 2014 Alex Crichton |
| chacha20 | 0.10.2 | https://github.com/RustCrypto/stream-ciphers | Copyright (c) 2019-2026 The RustCrypto Project Developers |
| cipher | 0.4.4 | https://github.com/RustCrypto/traits | Copyright (c) 2016-2020 RustCrypto Developers |
| cipher | 0.5.2 | https://github.com/RustCrypto/traits | Copyright (c) 2016-2025 RustCrypto Developers |
| clap | 4.6.7 | https://github.com/clap-rs/clap | Copyright Individual contributors; Copyright (c) Individual contributors |
| clap_builder | 4.6.7 | https://github.com/clap-rs/clap | Copyright Individual contributors; Copyright (c) Individual contributors |
| clap_derive | 4.6.7 | https://github.com/clap-rs/clap | Copyright Individual contributors; Copyright (c) Individual contributors |
| clap_lex | 1.1.1 | https://github.com/clap-rs/clap | Copyright Individual contributors; Copyright (c) Individual contributors |
| colorchoice | 1.0.5 | https://github.com/rust-cli/anstyle.git | Copyright (c) Individual contributors |
| core-foundation | 0.10.1 | https://github.com/servo/core-foundation-rs | Copyright (c) 2012-2013 Mozilla Foundation |
| core-foundation | 0.9.4 | https://github.com/servo/core-foundation-rs | Copyright (c) 2012-2013 Mozilla Foundation |
| core-foundation-sys | 0.8.7 | https://github.com/servo/core-foundation-rs | Copyright (c) 2012-2013 Mozilla Foundation |
| core-graphics | 0.24.0 | https://github.com/servo/core-foundation-rs | Copyright (c) 2012-2013 Mozilla Foundation |
| core-graphics-types | 0.2.0 | https://github.com/servo/core-foundation-rs | Copyright (c) 2012-2013 Mozilla Foundation |
| coreaudio-rs | 0.14.2 | https://github.com/RustAudio/coreaudio-rs.git | Copyright (c) 2015 |
| cpubits | 0.1.1 | https://github.com/RustCrypto/utils | Copyright (c) 2023-2026 The RustCrypto Project Developers |
| cpufeatures | 0.2.17 | https://github.com/RustCrypto/utils | Copyright (c) 2020-2025 The RustCrypto Project Developers |
| cpufeatures | 0.3.1 | https://github.com/RustCrypto/utils | Copyright (c) 2020-2026 The RustCrypto Project Developers |
| crc | 3.4.0 | https://github.com/mrhooray/crc-rs.git | Copyright (c) 2017 crc-rs Developers |
| crc-catalog | 2.5.0 | https://github.com/akhilles/crc-catalog.git | Authors: Akhil Velagapudi <akhilvelagapudi@gmail.com> |
| crc32fast | 1.5.4 | https://github.com/srijs/rust-crc32fast | Copyright (c) 2018 Sam Rijs, Alex Crichton and contributors |
| crypto-common | 0.1.7 | https://github.com/RustCrypto/traits | Copyright (c) 2021 RustCrypto Developers |
| crypto-common | 0.2.2 | https://github.com/RustCrypto/traits | Copyright (c) 2021-2026 RustCrypto Developers |
| curve25519-dalek-derive | 0.1.1 | https://github.com/dalek-cryptography/curve25519-dalek | (no copyright line packaged; see repository) |
| dasp_sample | 0.11.0 | https://github.com/rustaudio/sample.git | Authors: mitchmindtree <mitchell.nordine@gmail.com> |
| dbus-secret-service | 4.1.0 | https://github.com/brotskydotcom/dbus-secret-service.git | Copyright (c) 2016 secret-service Developers |
| der-parser | 10.0.0 | https://github.com/rusticata/der-parser.git | Copyright (c) 2017 Pierre Chifflier |
| deranged | 0.5.9 | https://github.com/jhpratt/deranged | Copyright 2024 Jacob Pratt et al.; Copyright (c) 2024 Jacob Pratt et al. |
| digest | 0.10.7 | https://github.com/RustCrypto/traits | Copyright (c) 2017 Artyom Pavlov |
| digest | 0.11.3 | https://github.com/RustCrypto/traits | Copyright (c) 2017-2025 RustCrypto Developers; Copyright (c) 2017 Artyom Pavlov |
| dirs | 7.0.0 | https://codeberg.org/dirs/dirs-rs | Copyright (c) 2018-2019 dirs-rs contributors |
| dirs-sys | 0.5.0 | https://github.com/dirs-dev/dirs-sys-rs | Copyright (c) 2018-2019 dirs-rs contributors |
| displaydoc | 0.2.7 | https://github.com/yaahc/displaydoc | Authors: Jane Lusby <jlusby@yaah.dev> |
| document-features | 0.2.12 | https://github.com/slint-ui/document-features | Copyright (c) 2020 Olivier Goffart <ogoffart@sixtyfps.io> |
| dyn-clone | 1.0.20 | https://github.com/dtolnay/dyn-clone | Authors: David Tolnay <dtolnay@gmail.com> |
| easyfft | 0.4.2 | https://github.com/WalterSmuts/easyfft | Copyright (c) 2015 The RustFFT Developers |
| either | 1.19.0 | https://github.com/rayon-rs/either | Copyright (c) 2015 |
| enumflags2 | 0.7.12 | https://github.com/meithecatte/enumflags2 | Copyright 2017-2023 Maik Klein, Maja Kądziołka; Copyright (c) 2017-2023 Maik Klein, Maja Kądziołka |
| enumflags2_derive | 0.7.12 | https://github.com/meithecatte/enumflags2 | Copyright (c) 2017 Maik Klein |
| errno | 0.3.14 | https://github.com/lambda-fairy/rust-errno | Copyright (c) 2014 Chris Wong |
| fallible-iterator | 0.3.0 | https://github.com/sfackler/rust-fallible-iterator | Copyright (c) 2015 The rust-openssl-verify Developers |
| fallible-streaming-iterator | 0.1.9 | https://github.com/sfackler/fallible-streaming-iterator | Copyright (c) 2016 The fallible-streaming-iterator Developers |
| fdeflate | 0.3.7 | https://github.com/image-rs/fdeflate | Authors: The image-rs Developers |
| find-msvc-tools | 0.1.15 | https://github.com/rust-lang/cc-rs | Copyright (c) 2014 Alex Crichton |
| flate2 | 1.1.10 | https://github.com/rust-lang/flate2-rs | Copyright (c) 2014-2026 Alex Crichton |
| foreign-types | 0.5.0 | https://github.com/sfackler/foreign-types | Copyright (c) 2017 The foreign-types Developers |
| foreign-types-macros | 0.2.4 | https://github.com/sfackler/foreign-types | Copyright (c) 2017 The foreign-types Developers |
| foreign-types-shared | 0.3.1 | https://github.com/sfackler/foreign-types | Copyright (c) 2017 The foreign-types Developers |
| form_urlencoded | 1.2.2 | https://github.com/servo/rust-url | Copyright (c) 2013-2016 The rust-url developers |
| futures | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| futures-channel | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| futures-core | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| futures-executor | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| futures-io | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| futures-macro | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| futures-sink | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| futures-task | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| futures-util | 0.3.34 | https://github.com/rust-lang/futures-rs | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| generic_singleton | 0.5.3 | https://github.com/WalterSmuts/generic_singleton | Copyright (c) 2015 The RustFFT Developers |
| getrandom | 0.2.17 | https://github.com/rust-random/getrandom | Copyright (c) 2018-2024 The rust-random Project Developers; Copyright (c) 2014 The Rust Project Developers |
| getrandom | 0.3.4 | https://github.com/rust-random/getrandom | Copyright (c) 2018-2025 The rust-random Project Developers; Copyright (c) 2014 The Rust Project Developers |
| getrandom | 0.4.3 | https://github.com/rust-random/getrandom | Copyright (c) 2018-2026 The rust-random Project Developers; Copyright (c) 2014 The Rust Project Developers |
| gif | 0.14.2 | https://github.com/image-rs/image-gif | Copyright (c) 2015 nwin |
| hashbrown | 0.15.5 | https://github.com/rust-lang/hashbrown | Copyright (c) 2016 Amanieu d'Antras |
| hashbrown | 0.17.1 | https://github.com/rust-lang/hashbrown | Copyright (c) 2016 Amanieu d'Antras |
| hashlink | 0.12.2 | https://github.com/djc/hashlink | (no copyright line packaged; see repository) |
| heck | 0.5.0 | https://github.com/withoutboats/heck | Copyright (c) 2015 The Rust Project Developers |
| hex | 0.4.3 | https://github.com/KokaKiwi/rust-hex | Copyright (c) 2013-2014 The Rust Project Developers.; Copyright (c) 2015-2020 The rust-hex Developers |
| hkdf | 0.12.4 | https://github.com/RustCrypto/KDFs/ | Copyright (c) 2015-2018 Vlad Filippov; Copyright (c) 2018-2021 RustCrypto Developers |
| hkdf | 0.13.0 | https://github.com/RustCrypto/KDFs/ | Copyright (c) 2015-2018 Vlad Filippov; Copyright (c) 2018-2021 RustCrypto Developers |
| hmac | 0.12.1 | https://github.com/RustCrypto/MACs | Copyright (c) 2017 Artyom Pavlov |
| hmac | 0.13.0 | https://github.com/RustCrypto/MACs | Copyright (c) 2017 Artyom Pavlov |
| hpke | 0.14.1 | https://github.com/rozbb/rust-hpke | Copyright 2020 Michael Rosenberg; Copyright (c) 2020 Michael Rosenberg |
| http | 1.5.0 | https://github.com/hyperium/http | Copyright 2017 http-rs authors; Copyright (c) 2017 http-rs authors |
| httparse | 1.10.1 | https://github.com/seanmonstar/httparse | Copyright (c) 2015-2025 Sean McArthur |
| httpdate | 1.0.3 | https://github.com/pyfisch/httpdate | Copyright (c) 2016 Pyfisch |
| hybrid-array | 0.4.15 | https://github.com/RustCrypto/hybrid-array | Copyright (c) 2022-2026 The RustCrypto Project Developers |
| idna | 1.1.0 | https://github.com/servo/rust-url/ | Copyright (c) 2013-2025 The rust-url developers |
| image | 0.25.10 | https://github.com/image-rs/image | Authors: The image-rs Developers |
| image-webp | 0.2.4 | https://github.com/image-rs/image-webp | (no copyright line packaged; see repository) |
| inout | 0.1.4 | https://github.com/RustCrypto/utils | Copyright (c) 2022 The RustCrypto Project Developers; Copyright (c) 2022 Artyom Pavlov |
| inout | 0.2.5 | https://github.com/RustCrypto/utils | Copyright (c) 2022-2025 The RustCrypto Project Developers; Copyright (c) 2022 Artyom Pavlov |
| is_terminal_polyfill | 1.70.2 | https://github.com/polyfill-rs/is_terminal_polyfill | Copyright (c) Individual contributors |
| itertools | 0.13.0 | https://github.com/rust-itertools/itertools | Copyright (c) 2015 |
| itoa | 1.0.18 | https://github.com/dtolnay/itoa | Authors: David Tolnay <dtolnay@gmail.com> |
| jni | 0.22.4 | https://github.com/jni-rs/jni-rs | Authors: jni team |
| jni-macros | 0.22.4 | https://github.com/jni-rs/jni-rs | (no copyright line packaged; see repository) |
| jni-sys | 0.3.1 | https://github.com/jni-rs/jni-sys | Copyright (c) 2015 The rust-jni-sys Developers |
| jni-sys | 0.4.1 | https://github.com/jni-rs/jni-sys | Copyright (c) 2015 The rust-jni-sys Developers |
| jni-sys-macros | 0.4.1 | https://github.com/jni-rs/jni-sys | Authors: Robert Bragg <robert@sixbynine.org> |
| jobserver | 0.1.35 | https://github.com/rust-lang/jobserver-rs | Copyright (c) 2014 Alex Crichton |
| keyring | 3.6.3 | https://github.com/hwchen/keyring-rs.git | Copyright (c) 2016 keyring Developers |
| lazy_static | 1.5.1 | https://github.com/rust-lang-nursery/lazy-static.rs | Authors: Marvin Löbel <loebel.marvin@gmail.com> |
| libc | 0.2.191 | https://github.com/rust-lang/libc | Copyright (c) The Rust Project Developers |
| litrs | 1.0.1 | https://github.com/LukasKalbertodt/litrs | Copyright (c) 2020 Project Developers |
| lock_api | 0.4.14 | https://github.com/Amanieu/parking_lot | Copyright (c) 2016 The Rust Project Developers |
| log | 0.4.35 | https://github.com/rust-lang/log | Copyright (c) 2014 The Rust Project Developers |
| mime | 0.3.17 | https://github.com/hyperium/mime | Copyright (c) 2014 Sean McArthur |
| minimal-lexical | 0.2.1 | https://github.com/Alexhuszagh/minimal-lexical | Copyright (c) 2009 The Go Authors. All rights reserved. |
| ndk | 0.9.0 | https://github.com/rust-mobile/ndk | Authors: The Rust Mobile contributors |
| ndk-context | 0.1.1 | https://github.com/rust-windowing/android-ndk-rs | Authors: The Rust Windowing contributors |
| ndk-sys | 0.6.0+11769913 | https://github.com/rust-mobile/ndk | Authors: The Rust Windowing contributors |
| num | 0.4.3 | https://github.com/rust-num/num | Copyright (c) 2014 The Rust Project Developers |
| num-bigint | 0.4.8 | https://github.com/rust-num/num-bigint | Copyright (c) 2014 The Rust Project Developers |
| num-complex | 0.4.6 | https://github.com/rust-num/num-complex | Copyright (c) 2014 The Rust Project Developers |
| num-conv | 0.2.2 | https://github.com/jhpratt/num-conv | Copyright (c) Jacob Pratt |
| num-derive | 0.4.2 | https://github.com/rust-num/num-derive | Copyright (c) 2014 The Rust Project Developers |
| num-integer | 0.1.47 | https://github.com/rust-num/num-integer | Copyright (c) 2014 The Rust Project Developers |
| num-iter | 0.1.46 | https://github.com/rust-num/num-iter | Copyright (c) 2014 The Rust Project Developers |
| num-rational | 0.4.2 | https://github.com/rust-num/num-rational | Copyright (c) 2014 The Rust Project Developers |
| num-traits | 0.2.19 | https://github.com/rust-num/num-traits | Copyright (c) 2014 The Rust Project Developers |
| oid-registry | 0.8.1 | https://github.com/rusticata/oid-registry.git | Copyright (c) 2017 Pierre Chifflier |
| once_cell | 1.21.4 | https://github.com/matklad/once_cell | Authors: Aleksey Kladov <aleksey.kladov@gmail.com> |
| once_cell_polyfill | 1.70.2 | https://github.com/polyfill-rs/once_cell_polyfill | Copyright (c) Individual contributors |
| opaque-debug | 0.3.1 | https://github.com/RustCrypto/utils | Copyright (c) 2018-2024 The RustCrypto Project Developers |
| openssl-src | 300.6.1+3.6.3 | https://github.com/alexcrichton/openssl-src-rs | Copyright (c) 2014 Alex Crichton |
| opus | 0.3.1 | https://github.com/SpaceManiac/opus-rs | Copyright (c) 2016 Tad Hardesty |
| ordered-stream | 0.2.0 | https://github.com/danieldg/ordered-stream | Authors: Daniel De Graaf <code@danieldg.net>, Zeeshan Ali Khan <zeeshanak@gnome.org> |
| parking_lot | 0.12.5 | https://github.com/Amanieu/parking_lot | Copyright (c) 2016 The Rust Project Developers |
| parking_lot_core | 0.9.12 | https://github.com/Amanieu/parking_lot | Copyright (c) 2016 The Rust Project Developers |
| password-hash | 0.5.0 | https://github.com/RustCrypto/traits/tree/master/password-hash | Copyright (c) 2020-2023 RustCrypto Developers |
| percent-encoding | 2.3.2 | https://github.com/servo/rust-url/ | Copyright (c) 2013-2025 The rust-url developers |
| png | 0.18.1 | https://github.com/image-rs/image-png | Copyright (c) 2015 nwin |
| powerfmt | 0.2.1 | https://github.com/jhpratt/powerfmt | Copyright 2023 Jacob Pratt et al.; Copyright (c) 2023 Jacob Pratt et al. |
| ppv-lite86 | 0.2.21 | https://github.com/cryptocorrosion/cryptocorrosion | Copyright 2019 The CryptoCorrosion Contributors; Copyright (c) 2019 The CryptoCorrosion Contributors |
| primal-check | 0.3.4 | https://github.com/huonw/primal | Copyright (c) 2014 Huon Wilson |
| proc-macro-crate | 3.5.0 | https://github.com/bkchr/proc-macro-crate | Authors: Bastian Köcher <git@kchr.de> |
| proc-macro2 | 1.0.107 | https://github.com/dtolnay/proc-macro2 | Authors: David Tolnay <dtolnay@gmail.com>, Alex Crichton <alex@alexcrichton.com> |
| quick-error | 2.0.1 | http://github.com/tailhook/quick-error | Copyright (c) 2015 The quick-error Developers |
| quinn | 0.11.12 | https://github.com/quinn-rs/quinn | Copyright (c) 2018 The quinn Developers |
| quinn-proto | 0.11.19 | https://github.com/quinn-rs/quinn | Copyright (c) 2018 The quinn Developers |
| quinn-udp | 0.5.16 | https://github.com/quinn-rs/quinn | Copyright (c) 2018 The quinn Developers |
| quote | 1.0.47 | https://github.com/dtolnay/quote | Authors: David Tolnay <dtolnay@gmail.com> |
| rand | 0.10.3 | https://github.com/rust-random/rand | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand | 0.8.8 | https://github.com/rust-random/rand | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand | 0.9.5 | https://github.com/rust-random/rand | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand_chacha | 0.3.1 | https://github.com/rust-random/rand | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand_chacha | 0.9.0 | https://github.com/rust-random/rand | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand_core | 0.10.1 | https://github.com/rust-random/rand_core | Copyright (c) 2018-2026 The Rand Project Developers |
| rand_core | 0.6.4 | https://github.com/rust-random/rand | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand_core | 0.9.5 | https://github.com/rust-random/rand | Copyright 2018 Developers of the Rand project; Copyright (c) 2014 The Rust Project Developers |
| rand_pcg | 0.10.2 | https://github.com/rust-random/rngs | Copyright (c) 2014-2017 Melissa O'Neill and PCG Project contributors; Copyright 2018 Developers of the Rand project |
| rcgen | 0.14.10 | https://github.com/rustls/rcgen | Copyright (c) 2019-2026 est31 <MTest31@outlook.com> and contributors |
| regex-automata | 0.4.18 | https://github.com/rust-lang/regex | Copyright (c) 2014 The Rust Project Developers |
| regex-syntax | 0.8.11 | https://github.com/rust-lang/regex | Copyright (c) 2014 The Rust Project Developers |
| rustfft | 6.4.1 | https://github.com/ejmahler/RustFFT | Copyright (c) 2015 The RustFFT Developers |
| rusticata-macros | 4.1.0 | https://github.com/rusticata/rusticata-macros.git | Copyright (c) 2017 Pierre Chifflier |
| rustls-pki-types | 1.15.1 | https://github.com/rustls/pki-types | Copyright 2023 Dirkjan Ochtman; Copyright (c) 2023 Dirkjan Ochtman <dirkjan@ochtman.nl> |
| rustversion | 1.0.23 | https://github.com/dtolnay/rustversion | Authors: David Tolnay <dtolnay@gmail.com> |
| scopeguard | 1.2.0 | https://github.com/bluss/scopeguard | Copyright (c) 2016-2019 Ulrik Sverdrup "bluss" and scopeguard developers |
| secret-service | 4.0.0 | https://github.com/hwchen/secret-service-rs.git | Copyright (c) 2016 secret-service Developers |
| security-framework | 2.11.1 | https://github.com/kornelski/rust-security-framework | Copyright (c) 2015 Steven Fackler |
| security-framework | 3.7.0 | https://github.com/kornelski/rust-security-framework | Copyright (c) 2015 Steven Fackler |
| security-framework-sys | 2.17.0 | https://github.com/kornelski/rust-security-framework | Copyright (c) 2015 Steven Fackler |
| serde | 1.0.229 | https://github.com/serde-rs/serde | Authors: Erick Tryzelaar <erick.tryzelaar@gmail.com>, David Tolnay <dtolnay@gmail.com> |
| serde_bytes | 0.11.19 | https://github.com/serde-rs/bytes | Authors: David Tolnay <dtolnay@gmail.com> |
| serde_core | 1.0.229 | https://github.com/serde-rs/serde | Authors: Erick Tryzelaar <erick.tryzelaar@gmail.com>, David Tolnay <dtolnay@gmail.com> |
| serde_derive | 1.0.229 | https://github.com/serde-rs/serde | Authors: Erick Tryzelaar <erick.tryzelaar@gmail.com>, David Tolnay <dtolnay@gmail.com> |
| serde_json | 1.0.154 | https://github.com/serde-rs/json | (no copyright line packaged; see repository) |
| serde_path_to_error | 0.1.20 | https://github.com/dtolnay/path-to-error | Authors: David Tolnay <dtolnay@gmail.com> |
| serde_repr | 0.1.21 | https://github.com/dtolnay/serde-repr | Authors: David Tolnay <dtolnay@gmail.com> |
| sha1 | 0.10.7 | https://github.com/RustCrypto/hashes | Copyright (c) 2006-2009 Graydon Hoare; Copyright (c) 2009-2013 Mozilla Foundation; Copyright (c) 2016 Artyom Pavlov |
| sha1 | 0.11.0 | https://github.com/RustCrypto/hashes | Copyright (c) 2016-2026 The RustCrypto Project Developers; Copyright (c) 2016 Artyom Pavlov; Copyright (c) 2009-2013 Mozilla Foundation; Copyright (c) 2006-2009 Graydon Hoare |
| sha2 | 0.10.9 | https://github.com/RustCrypto/hashes | Copyright (c) 2006-2009 Graydon Hoare; Copyright (c) 2009-2013 Mozilla Foundation; Copyright (c) 2016 Artyom Pavlov |
| sha2 | 0.11.1 | https://github.com/RustCrypto/hashes | Copyright (c) 2016-2026 The RustCrypto Project Developers; Copyright (c) 2016 Artyom Pavlov; Copyright (c) 2009-2013 Mozilla Foundation; Copyright (c) 2006-2009 Graydon Hoare |
| shlex | 2.0.1 | https://github.com/comex/rust-shlex | Copyright 2015 Nicholas Allegra (comex).; Copyright (c) 2015 Nicholas Allegra (comex). |
| signal-hook-registry | 1.4.8 | https://github.com/vorner/signal-hook | Copyright (c) 2017 tokio-jsonrpc developers |
| simdutf8 | 0.1.5 | https://github.com/rusticstuff/simdutf8 | Authors: Hans Kratz <hans@appfour.com> |
| smallvec | 1.16.4 | https://github.com/servo/rust-smallvec | Copyright (c) 2018 The Servo Project Developers |
| socket2 | 0.6.5 | https://github.com/rust-lang/socket2 | Copyright (c) 2014 Alex Crichton |
| spake2 | 0.4.0 | https://github.com/RustCrypto/PAKEs/tree/master/spake2 | Copyright (c) 2017-2023 Brian Warner |
| stable_deref_trait | 1.2.1 | https://github.com/storyyeller/stable_deref_trait | Copyright (c) 2017 Robert Grosse |
| static_assertions | 1.1.0 | https://github.com/nvzqz/static-assertions-rs | Copyright (c) 2017 Nikolai Vazquez |
| strength_reduce | 0.2.4 | http://github.com/ejmahler/strength_reduce | Copyright (c) 2015 The RustFFT Developers |
| syn | 2.0.119 | https://github.com/dtolnay/syn | Authors: David Tolnay <dtolnay@gmail.com> |
| syn | 3.0.9 | https://github.com/dtolnay/syn | Authors: David Tolnay <dtolnay@gmail.com> |
| thiserror | 1.0.69 | https://github.com/dtolnay/thiserror | Authors: David Tolnay <dtolnay@gmail.com> |
| thiserror | 2.0.21 | https://github.com/dtolnay/thiserror | Authors: David Tolnay <dtolnay@gmail.com> |
| thiserror-impl | 1.0.69 | https://github.com/dtolnay/thiserror | Authors: David Tolnay <dtolnay@gmail.com> |
| thiserror-impl | 2.0.21 | https://github.com/dtolnay/thiserror | Authors: David Tolnay <dtolnay@gmail.com> |
| thread_local | 1.1.10 | https://github.com/Amanieu/thread_local-rs | Copyright (c) 2016 The Rust Project Developers |
| time | 0.3.55 | https://github.com/time-rs/time | Copyright (c) Jacob Pratt et al. |
| time-core | 0.1.9 | https://github.com/time-rs/time | Copyright (c) Jacob Pratt et al. |
| time-macros | 0.2.32 | https://github.com/time-rs/time | Copyright (c) Jacob Pratt et al. |
| tokio-rustls | 0.26.6 | https://github.com/rustls/tokio-rustls | Copyright 2017 quininer kel; Copyright (c) 2017 quininer kel |
| toml_datetime | 1.1.2+spec-1.1.0 | https://github.com/toml-rs/toml | Copyright Individual contributors; Copyright (c) Individual contributors |
| toml_edit | 0.25.18+spec-1.1.0 | https://github.com/toml-rs/toml | Copyright Individual contributors; Copyright (c) Individual contributors |
| toml_parser | 1.1.5+spec-1.1.0 | https://github.com/toml-rs/toml | Copyright Individual contributors; Copyright (c) Individual contributors |
| transpose | 0.2.3 | https://github.com/ejmahler/transpose | Copyright 2022 The transpose developers; Copyright (c) 2022 The transpose Developers |
| tungstenite | 0.29.0 | https://github.com/snapview/tungstenite-rs | Copyright (c) 2017 Alexey Galakhov; Copyright (c) 2016 Jason Housley |
| tungstenite | 0.30.0 | https://github.com/snapview/tungstenite-rs | Copyright (c) 2017 Alexey Galakhov; Copyright (c) 2016 Jason Housley |
| typenum | 1.20.1 | https://github.com/paholg/typenum | Copyright 2014 Paho Lurie-Gregg; Copyright (c) 2014 Paho Lurie-Gregg |
| universal-hash | 0.5.1 | https://github.com/RustCrypto/traits | Copyright (c) 2019-2020 RustCrypto Developers |
| universal-hash | 0.6.1 | https://github.com/RustCrypto/traits | Copyright (c) 2019-2025 RustCrypto Developers |
| url | 2.5.8 | https://github.com/servo/rust-url | Copyright (c) 2013-2025 The rust-url developers |
| weezl | 0.1.12 | https://github.com/image-rs/weezl | Copyright (c) HeroicKatora 2020 |
| windows | 0.61.3 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows | 0.62.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-collections | 0.2.0 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-collections | 0.3.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-core | 0.61.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-core | 0.62.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-future | 0.2.1 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-future | 0.3.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-implement | 0.60.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-interface | 0.59.3 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-link | 0.1.3 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-link | 0.2.1 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-numerics | 0.2.0 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-numerics | 0.3.1 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-result | 0.3.4 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-result | 0.4.1 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-strings | 0.4.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-strings | 0.5.1 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-sys | 0.59.0 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-sys | 0.60.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-sys | 0.61.2 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-targets | 0.52.6 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-targets | 0.53.5 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-threading | 0.1.0 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows-threading | 0.2.1 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows_x86_64_msvc | 0.52.6 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| windows_x86_64_msvc | 0.53.1 | https://github.com/microsoft/windows-rs | Copyright (c) Microsoft Corporation. |
| x11rb | 0.14.0 | https://github.com/psychon/x11rb | Copyright 2019 x11rb Contributers |
| x11rb-protocol | 0.14.0 | https://github.com/psychon/x11rb | Copyright 2019 x11rb Contributers |
| x509-parser | 0.18.1 | https://github.com/rusticata/x509-parser.git | Copyright (c) 2017 Pierre Chifflier |
| yasna | 0.6.0 | https://github.com/qnighy/yasna.rs | Copyright (c) 2016 Masaki Hara |

### MIT (94)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| aec-rs | 1.0.0 | https://github.com/thewh1teagle/aec-rs | Authors: thewh1teagle |
| aec-rs-sys | 1.0.0 | https://github.com/thewh1teagle/aec-rs | Authors: thewh1teagle |
| alsa-sys | 0.4.0 | https://github.com/diwic/alsa-sys | Copyright (c) 2018 diwic |
| ashpd | 0.13.13 | https://github.com/bilelmoussaoui/ashpd | Copyright (c) 2020 Bilal Elmoussaoui |
| axum | 0.8.9 | https://github.com/tokio-rs/axum | Copyright (c) 2019 axum Contributors |
| axum-core | 0.5.6 | https://github.com/tokio-rs/axum | Copyright (c) 2019–2025 axum Contributors |
| bitvec | 1.1.1 | https://github.com/bitvecto-rs/bitvec | Copyright (c) 2018 myrrlyn (Alexander Payne) |
| block2 | 0.6.2 | https://github.com/madsmtm/objc2 | Authors: Mads Marquart <mads@marquart.dk> |
| bytes | 1.12.1 | https://github.com/tokio-rs/bytes | Copyright (c) 2018 Carl Lerche |
| color_quant | 1.1.0 | https://github.com/image-rs/color_quant.git | Copyright (c) 2016 PistonDevelopers |
| combine | 4.6.9 | https://github.com/Marwes/combine | Copyright (c) 2015 Markus Westerlind |
| cookie-factory | 0.3.3 | https://github.com/rust-bakery/cookie-factory | Authors: Geoffroy Couprie <geo.couprie@gmail.com>, Pierre Chifflier <chifflier@wzdftpd.net> |
| data-encoding | 2.11.1 | https://github.com/ia0/data-encoding | Copyright (c) 2015-2020 Julien Cretin; Copyright (c) 2017-2020 Google Inc. |
| endi | 1.1.1 | https://github.com/zeenix/endi | Authors: Zeeshan Ali Khan <zeenix@gmail.com> |
| funty | 2.0.0 | https://github.com/myrrlyn/funty | Copyright (c) 2020 myrrlyn (Alexander Payne) |
| generic-array | 0.14.7 | https://github.com/fizyk20/generic-array.git | Copyright (c) 2015 Bartłomiej Kamiński |
| h2 | 0.4.20 | https://github.com/hyperium/h2 | Copyright (c) 2017 h2 authors |
| http-body | 1.1.0 | https://github.com/hyperium/http-body | Copyright (c) 2019-2026 Sean McArthur & Hyper Contributors |
| http-body-util | 0.1.5 | https://github.com/hyperium/http-body | Copyright (c) 2019-2026 Sean McArthur & Hyper Contributors |
| hyper | 1.12.0 | https://github.com/hyperium/hyper | Copyright (c) 2014-2026 Sean McArthur |
| hyper-util | 0.1.21 | https://github.com/hyperium/hyper-util | Copyright (c) 2023-2025 Sean McArthur |
| igd-next | 0.18.0 | https://github.com/dariusc93/rust-igd | Copyright (c) 2015 Simon Bernier St-Pierre |
| libspa | 0.10.1 | https://gitlab.freedesktop.org/pipewire/pipewire-rs | Copyright The pipewire-rs Contributors. |
| libspa-sys | 0.10.1 | https://gitlab.freedesktop.org/pipewire/pipewire-rs | Copyright The pipewire-rs Contributors. |
| libsqlite3-sys | 0.39.1 | https://github.com/rusqlite/rusqlite | Copyright (c) 2014 The rusqlite developers |
| lru | 0.12.5 | https://github.com/jeromefroe/lru-rs.git | Copyright (c) 2016 Jerome Froelich |
| lru | 0.18.5 | https://github.com/jeromefroe/lru-rs.git | Copyright (c) 2016 Jerome Froelich |
| mainline | 8.0.1 | https://github.com/pubky/mainline | Copyright (c) 2021 raptorswing |
| matchers | 0.2.0 | https://github.com/hawkw/matchers | Copyright (c) 2019 Eliza Weisman |
| memoffset | 0.9.1 | https://github.com/Gilnaa/memoffset | Copyright (c) 2017 Gilad Naaman |
| mio | 1.2.4 | https://github.com/tokio-rs/mio | Copyright (c) 2014 Carl Lerche and other MIO contributors |
| nix | 0.29.0 | https://github.com/nix-rust/nix | Copyright (c) 2015 Carl Lerche + nix-rust Authors |
| nom | 7.1.3 | https://github.com/Geal/nom | Copyright (c) 2014-2019 Geoffroy Couprie |
| nom | 8.0.0 | https://github.com/rust-bakery/nom | Copyright (c) 2014-2019 Geoffroy Couprie |
| nu-ansi-term | 0.50.3 | https://github.com/nushell/nu-ansi-term | Copyright (c) 2014 Benjamin Sago; Copyright (c) 2021-2022 The Nushell Project Developers |
| objc2 | 0.6.5 | https://github.com/madsmtm/objc2 | Authors: Mads Marquart <mads@marquart.dk> |
| objc2-encode | 4.1.0 | https://github.com/madsmtm/objc2 | Authors: Mads Marquart <mads@marquart.dk> |
| objc2-foundation | 0.3.2 | https://github.com/madsmtm/objc2 | (no copyright line packaged; see repository) |
| openssl-sys | 0.9.118 | https://github.com/rust-openssl/rust-openssl | Copyright (c) 2014 Alex Crichton |
| pem | 4.0.0 | https://github.com/jcreekmore/pem-rs.git | Copyright (c) 2016 Jonathan Creekmore |
| pipewire | 0.10.1 | https://gitlab.freedesktop.org/pipewire/pipewire-rs | Copyright The pipewire-rs Contributors. |
| pipewire-sys | 0.10.1 | https://gitlab.freedesktop.org/pipewire/pipewire-rs | Copyright The pipewire-rs Contributors. |
| radium | 0.7.0 | https://github.com/bitvecto-rs/radium | Copyright (c) 2019 kneecaw (Nika Layzell) |
| realfft | 3.5.1 | https://github.com/HEnquist/realfft | Copyright (c) 2020 Henrik Enquist and RealFFT contributors |
| rmp | 0.8.15 | https://github.com/3Hren/msgpack-rust | Copyright (c) 2017 Evgeny Safronov |
| rmp-serde | 1.3.1 | https://github.com/3Hren/msgpack-rust | Copyright (c) 2017 Evgeny Safronov |
| rusqlite | 0.41.1 | https://github.com/rusqlite/rusqlite | Copyright (c) 2014 The rusqlite developers |
| serde_bencode | 0.2.4 | https://github.com/toby/serde-bencode | Copyright (c) 2014 Ty Overby |
| sharded-slab | 0.1.7 | https://github.com/hawkw/sharded-slab | Copyright (c) 2019 Eliza Weisman |
| simd-adler32 | 0.3.10 | https://github.com/mcountryman/simd-adler32 | Copyright (c) [2021] [Marvin Countryman] |
| slab | 0.4.12 | https://github.com/tokio-rs/slab | Copyright (c) 2019 Carl Lerche |
| socket-pktinfo | 0.4.1 | https://github.com/pixsper/socket-pktinfo | Copyright (c) 2025 Pixsper |
| spin | 0.9.9 | https://github.com/mvdnes/spin-rs.git | Copyright (c) 2014 Mathijs van de Nes |
| strsim | 0.11.1 | https://github.com/rapidfuzz/strsim-rs | Copyright (c) 2015 Danny Guo; Copyright (c) 2016 Titus Wormer <tituswormer@gmail.com>; Copyright (c) 2018 Akash Kurdekar |
| synstructure | 0.13.2 | https://github.com/mystor/synstructure | Copyright 2016 Nika Layzell |
| synstructure | 0.14.0 | https://github.com/mystor/synstructure | Copyright 2016 Nika Layzell |
| tap | 1.0.1 | https://github.com/myrrlyn/tap | Copyright (c) 2017 Elliot Linder <darfink@gmail.com> |
| tokio | 1.54.1 | https://github.com/tokio-rs/tokio | Copyright (c) Tokio Contributors |
| tokio-macros | 2.7.2 | https://github.com/tokio-rs/tokio | Copyright (c) 2019 Yoshua Wuyts; Copyright (c) Tokio Contributors |
| tokio-tungstenite | 0.29.0 | https://github.com/snapview/tokio-tungstenite | Copyright (c) 2017 Daniel Abramov; Copyright (c) 2017 Alexey Galakhov |
| tokio-tungstenite | 0.30.0 | https://github.com/snapview/tokio-tungstenite | Copyright (c) 2017 Daniel Abramov; Copyright (c) 2017 Alexey Galakhov |
| tokio-util | 0.7.20 | https://github.com/tokio-rs/tokio | Copyright (c) Tokio Contributors |
| tower | 0.5.3 | https://github.com/tower-rs/tower | Copyright (c) 2019 Tower Contributors |
| tower-layer | 0.3.3 | https://github.com/tower-rs/tower | Copyright (c) 2019 Tower Contributors |
| tower-service | 0.3.3 | https://github.com/tower-rs/tower | Copyright (c) 2019 Tower Contributors |
| tracing | 0.1.44 | https://github.com/tokio-rs/tracing | Copyright (c) 2019 Tokio Contributors |
| tracing-attributes | 0.1.31 | https://github.com/tokio-rs/tracing | Copyright (c) 2019 Tokio Contributors |
| tracing-core | 0.1.36 | https://github.com/tokio-rs/tracing | Copyright (c) 2019 Tokio Contributors |
| tracing-log | 0.2.0 | https://github.com/tokio-rs/tracing | Copyright (c) 2019 Tokio Contributors |
| tracing-serde | 0.2.0 | https://github.com/tokio-rs/tracing | Copyright (c) 2019 Tokio Contributors |
| tracing-subscriber | 0.3.23 | https://github.com/tokio-rs/tracing | Copyright (c) 2019 Tokio Contributors |
| try-lock | 0.2.5 | https://github.com/seanmonstar/try-lock | Copyright (c) 2018-2023 Sean McArthur; Copyright (c) 2016 Alex Crichton |
| v4l | 0.14.0 | https://github.com/raymanfx/libv4l-rs | Copyright (c) 2020 Christopher N. Hesse. |
| v4l2-sys-mit | 0.3.0 | https://crates.io/crates/v4l2-sys-mit | Authors: Christopher N. Hesse <raymanfx@gmail.com> |
| want | 0.3.2 | https://github.com/seanmonstar/want | Copyright (c) 2018-2019 Sean McArthur |
| winnow | 1.0.5 | https://github.com/winnow-rs/winnow | (no copyright line packaged; see repository) |
| wyz | 0.5.1 | https://github.com/myrrlyn/wyz | Copyright (c) 2018 myrrlyn (Alexander Payne) |
| xdg-home | 1.3.0 | https://github.com/zeenix/xdg-home | Authors: Zeeshan Ali Khan <zeeshanak@gnome.org> |
| xml-rs | 0.8.29 | https://github.com/kornelski/xml-rs | Copyright (c) 2014 Vladimir Matveev |
| xmltree | 0.10.3 | https://github.com/eminence/xmltree-rs | Copyright (c) 2015 Andrew Chin |
| zbus | 4.4.0 | https://github.com/dbus2/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zbus | 5.19.0 | https://github.com/z-galaxy/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zbus_macros | 4.4.0 | https://github.com/dbus2/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zbus_macros | 5.19.0 | https://github.com/z-galaxy/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zbus_names | 3.0.0 | https://github.com/dbus2/zbus/ | Authors: Zeeshan Ali Khan <zeeshanak@gnome.org> |
| zbus_names | 4.3.5 | https://github.com/z-galaxy/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zcheapstr | 1.2.0 | https://github.com/z-galaxy/zcheapstr/ | Copyright (c) 2026 Zeeshan Ali Khan & zcheapstr contributors |
| zmij | 1.0.23 | https://github.com/dtolnay/zmij | Authors: David Tolnay <dtolnay@gmail.com> |
| zvariant | 4.2.0 | https://github.com/dbus2/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zvariant | 5.15.1 | https://github.com/z-galaxy/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zvariant_derive | 4.2.0 | https://github.com/dbus2/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zvariant_derive | 5.15.1 | https://github.com/z-galaxy/zbus/ | Copyright (c) 2024 Zeeshan Ali Khan & zbus contributors |
| zvariant_utils | 2.1.0 | https://github.com/dbus2/zbus/ | Authors: Zeeshan Ali Khan <zeeshanak@gnome.org>, turbocooler <turbocooler@cocaine.ninja> |
| zvariant_utils | 4.2.0 | https://github.com/z-galaxy/zbus/ | Authors: Zeeshan Ali Khan <zeeshanak@gnome.org>, turbocooler <turbocooler@cocaine.ninja> |

### Apache-2.0 OR MIT (45)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| alsa | 0.11.0 | https://github.com/diwic/alsa-rs | Copyright (c) 2015-2021 David Henningsson, and other contributors. |
| atomic-waker | 1.1.2 | https://github.com/smol-rs/atomic-waker | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| base16ct | 1.0.0 | https://github.com/RustCrypto/formats | Copyright (c) 2014 Steve "Sc00bz" Thomas (steve at tobtu dot com); Copyright (c) 2022-2025 The RustCrypto Project Developers |
| base64ct | 1.8.3 | https://github.com/RustCrypto/formats | Copyright (c) 2014 Steve "Sc00bz" Thomas (steve at tobtu dot com); Copyright (c) 2021-2025 The RustCrypto Project Developers |
| bit-vec | 0.9.1 | https://github.com/contain-rs/bit-vec | Copyright (c) 2023 The Rust Project Developers |
| chacha20 | 0.9.1 | https://github.com/RustCrypto/stream-ciphers | Copyright (c) 2019-2023 The RustCrypto Project Developers |
| chacha20poly1305 | 0.10.1 | https://github.com/RustCrypto/AEADs/tree/master/chacha20poly1305 | Copyright (c) 2019 The RustCrypto Project Developers |
| chacha20poly1305 | 0.11.0 | https://github.com/RustCrypto/AEADs | Copyright (c) 2019-2026 The RustCrypto Project Developers |
| cmov | 0.5.4 | https://github.com/RustCrypto/utils | Copyright (c) 2022-2026 The RustCrypto Project Developers |
| const-oid | 0.10.2 | https://github.com/RustCrypto/formats | Copyright (c) 2020-2026 The RustCrypto Project Developers |
| const-oid | 0.9.6 | https://github.com/RustCrypto/formats/tree/master/const-oid | Copyright (c) 2020-2022 The RustCrypto Project Developers |
| ctutils | 0.4.8 | https://github.com/RustCrypto/utils | Copyright (c) 2025-2026 The RustCrypto Project Developers |
| dbus | 0.9.12 | https://github.com/diwic/dbus-rs | Copyright 2014-2018 David Henningsson <diwic@ubuntu.com> and other contributors; Copyright (c) 2014-2018 David Henningsson <diwic@ubuntu.com> and other contributors |
| der | 0.7.10 | https://github.com/RustCrypto/formats/tree/master/der | Copyright (c) 2020-2023 The RustCrypto Project Developers |
| ed25519 | 2.2.3 | https://github.com/RustCrypto/signatures/tree/master/ed25519 | Copyright 2018-2022 RustCrypto Developers; Copyright (c) 2018-2023 RustCrypto Developers |
| ed25519 | 3.0.0 | https://github.com/RustCrypto/signatures | Copyright 2018-2022 RustCrypto Developers; Copyright (c) 2018-2026 RustCrypto Developers |
| equivalent | 1.0.3 | https://github.com/indexmap-rs/equivalent | Copyright (c) 2016--2023 |
| evdev | 0.13.2 | https://github.com/cmr/evdev | Authors: Corey Richardson <corey@octayn.net> |
| event-listener | 5.4.2 | https://github.com/smol-rs/event-listener | Authors: Stjepan Glavina <stjepang@gmail.com>, John Nunley <dev@notgull.net> |
| event-listener-strategy | 0.5.4 | https://github.com/smol-rs/event-listener-strategy | Authors: John Nunley <dev@notgull.net> |
| fastrand | 2.5.0 | https://github.com/smol-rs/fastrand | Authors: Stjepan Glavina <stjepang@gmail.com> |
| flume | 0.12.0 | https://github.com/zesterer/flume | Authors: Joshua Barretto <joshua.s.barretto@gmail.com> |
| fnv | 1.0.7 | https://github.com/servo/rust-fnv | Copyright (c) 2017 Contributors |
| futures-lite | 2.6.1 | https://github.com/smol-rs/futures-lite | Copyright (c) 2016 Alex Crichton; Copyright (c) 2017 The Tokio Authors |
| idna_adapter | 1.2.2 | https://github.com/hsivonen/idna_adapter | Copyright (c) The rust-url developers |
| indexmap | 2.14.2 | https://github.com/indexmap-rs/indexmap | Copyright (c) 2016--2017 |
| libdbus-sys | 0.2.7 | https://github.com/diwic/dbus-rs | Copyright 2014-2018 David Henningsson <diwic@ubuntu.com> and other contributors; Copyright (c) 2014-2018 David Henningsson <diwic@ubuntu.com> and other contributors |
| mdns-sd | 0.21.7 | https://github.com/keepsimple1/mdns-sd | Copyright (c) 2021-2022, Han Xu, keepsimple@gmail.com |
| parking | 2.2.1 | https://github.com/smol-rs/parking | Copyright 2014-2020 The Rust Project Developers |
| pin-project-lite | 0.2.17 | https://github.com/taiki-e/pin-project-lite | (no copyright line packaged; see repository) |
| pkcs8 | 0.10.2 | https://github.com/RustCrypto/formats/tree/master/pkcs8 | Copyright (c) 2020-2023 The RustCrypto Project Developers |
| poly1305 | 0.8.0 | https://github.com/RustCrypto/universal-hashes | Copyright (c) 2015-2019 RustCrypto Developers |
| poly1305 | 0.9.1 | https://github.com/RustCrypto/universal-hashes | Copyright (c) 2015-2026 The RustCrypto Project Developers |
| rustc-hash | 2.1.3 | https://github.com/rust-lang/rustc-hash | Authors: The Rust Project Developers |
| serdect | 0.4.3 | https://github.com/RustCrypto/formats | Copyright (c) 2022-2025 The RustCrypto Project Developers |
| signature | 2.2.0 | https://github.com/RustCrypto/traits/tree/master/signature | Copyright (c) 2018-2023 RustCrypto Developers |
| signature | 3.0.0 | https://github.com/RustCrypto/traits | Copyright (c) 2018-2026 RustCrypto Developers |
| simd_cesu8 | 1.2.0 | https://github.com/seancroach/simd_cesu8 | Authors: Sean C. Roach <me@seancroach.dev> |
| spki | 0.7.3 | https://github.com/RustCrypto/formats/tree/master/spki | Copyright (c) 2021-2023 The RustCrypto Project Developers |
| utf8_iter | 1.1.0 | https://github.com/hsivonen/utf8_iter | Copyright Mozilla Foundation |
| utf8parse | 0.2.2 | https://github.com/alacritty/vte | Copyright (c) 2016 Joe Wilm |
| utf_types | 1.0.0 | https://github.com/hsivonen/utf_types | Copyright Mozilla Foundation |
| uuid | 1.29.0 | https://github.com/uuid-rs/uuid | Copyright (c) 2014 The Rust Project Developers; Copyright (c) 2018 Ashley Mannix, Christopher Armstrong, Dylan DPC, Hunar Roop Kahlon |
| zeroize | 1.9.1 | https://github.com/RustCrypto/utils | Copyright (c) 2018-2026 The RustCrypto Project Developers |
| zeroize_derive | 1.5.0 | https://github.com/RustCrypto/utils | Copyright (c) 2019-2026 The RustCrypto Project Developers |

### Unicode-3.0 (18)

Used under: Unicode-3.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| icu_collections | 2.4.0 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| icu_locale_core | 2.4.0 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| icu_normalizer | 2.4.0 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| icu_normalizer_data | 2.4.0 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| icu_properties | 2.4.0 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| icu_properties_data | 2.4.0 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| icu_provider | 2.4.0 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| litemap | 0.8.3 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| potential_utf | 0.1.6 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| tinystr | 0.8.5 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| writeable | 0.6.4 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| yoke | 0.8.4 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| yoke-derive | 0.8.4 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| zerofrom | 0.1.8 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| zerofrom-derive | 0.1.8 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| zerotrie | 0.2.5 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| zerovec | 0.11.9 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |
| zerovec-derive | 0.11.7 | https://github.com/unicode-org/icu4x | Copyright © 2020-2024 Unicode, Inc. |

### BSD-3-Clause (9)

Used under: BSD-3-Clause

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| curve25519-dalek | 4.1.3 | https://github.com/dalek-cryptography/curve25519-dalek/tree/main/curve25519-dalek | Copyright (c) 2016-2021 isis agora lovecruft. All rights reserved.; Copyright (c) 2016-2021 Henry de Valence. All rights reserved.; Copyright (c) 2012 The Go Authors. All rights reserved. |
| curve25519-dalek | 5.0.0 | https://github.com/dalek-cryptography/curve25519-dalek/tree/main/curve25519-dalek | Copyright (c) 2016-2021 isis agora lovecruft. All rights reserved.; Copyright (c) 2016-2021 Henry de Valence. All rights reserved. |
| ed25519-dalek | 2.2.0 | https://github.com/dalek-cryptography/curve25519-dalek/tree/main/ed25519-dalek | Copyright (c) 2017-2019 isis agora lovecruft. All rights reserved. |
| ed25519-dalek | 3.0.0 | https://github.com/dalek-cryptography/curve25519-dalek/tree/main/ed25519-dalek | Copyright (c) 2017-2019 isis agora lovecruft. All rights reserved. |
| nnnoiseless | 0.5.2 | https://github.com/jneem/nnnoiseless | Copyright (c) 2020, Joe Neeman; Copyright (c) 2017, Mozilla; Copyright (c) 2007-2017, Jean-Marc Valin; Copyright (c) 2005-2017, Xiph.Org Foundation |
| sha1_smol | 1.0.1 | https://github.com/mitsuhiko/sha1-smol | Copyright (c) 2018, the respective contributors, as shown by the AUTHORS file.; Copyright (c) 2006-2009 Graydon Hoare; Copyright (c) 2009-2013 Mozilla Foundation |
| subtle | 2.6.1 | https://github.com/dalek-cryptography/subtle | Copyright (c) 2016-2017 Isis Agora Lovecruft, Henry de Valence. All rights reserved.; Copyright (c) 2016-2024 Isis Agora Lovecruft. All rights reserved. |
| x25519-dalek | 2.0.1 | https://github.com/dalek-cryptography/curve25519-dalek/tree/main/x25519-dalek | Copyright (c) 2017-2021 isis agora lovecruft. All rights reserved.; Copyright (c) 2019-2021 DebugSteven. All rights reserved. |
| x25519-dalek | 3.0.0 | https://github.com/dalek-cryptography/curve25519-dalek/tree/main/x25519-dalek | Copyright (c) 2017-2021 isis agora lovecruft. All rights reserved.; Copyright (c) 2019-2021 DebugSteven. All rights reserved. |

### Apache-2.0 (8)

Used under: Apache-2.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| cpal | 0.18.2 | https://github.com/RustAudio/cpal | (no copyright line packaged; see repository) |
| gethostname | 1.1.0 | https://codeberg.org/swsnr/gethostname.rs.git | Authors: Sebastian Wiesner <sebastian@swsnr.de> |
| matrix-pickle | 0.2.3 | https://github.com/matrix-org/matrix-pickle | (no copyright line packaged; see repository) |
| matrix-pickle-derive | 0.2.3 | https://github.com/matrix-org/matrix-pickle | (no copyright line packaged; see repository) |
| prost | 0.14.4 | https://github.com/tokio-rs/prost | Authors: Dan Burkert <dan@danburkert.com>, Lucio Franco <luciofranco14@gmail.com>, Casper Meijn <casper@meijn.net>, Tokio Contributors <team@tokio.rs> |
| prost-derive | 0.14.4 | https://github.com/tokio-rs/prost | Authors: Dan Burkert <dan@danburkert.com>, Lucio Franco <luciofranco14@gmail.com>, Casper Meijn <casper@meijn.net>, Tokio Contributors <team@tokio.rs> |
| sync_wrapper | 1.0.2 | https://github.com/Actyx/sync_wrapper | Authors: Actyx AG <developer@actyx.io> |
| vodozemac | 0.11.1 | https://github.com/matrix-org/vodozemac | Authors: Damir Jelić <poljar@termina.org.uk>, Denis Kasak <dkasak@termina.org.uk> |

### Zlib OR Apache-2.0 OR MIT (8)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| bytemuck | 1.25.2 | https://github.com/Lokathor/bytemuck | Copyright (c) 2019 Daniel "Lokathor" Gee. |
| dispatch2 | 0.3.1 | https://github.com/madsmtm/objc2 | Authors: Mads Marquart <mads@marquart.dk>, Mary <mary@mary.zone> |
| objc2-audio-toolbox | 0.3.2 | https://github.com/madsmtm/objc2 | (no copyright line packaged; see repository) |
| objc2-avf-audio | 0.3.2 | https://github.com/madsmtm/objc2 | (no copyright line packaged; see repository) |
| objc2-core-audio | 0.3.2 | https://github.com/madsmtm/objc2 | (no copyright line packaged; see repository) |
| objc2-core-audio-types | 0.3.2 | https://github.com/madsmtm/objc2 | (no copyright line packaged; see repository) |
| objc2-core-foundation | 0.3.2 | https://github.com/madsmtm/objc2 | (no copyright line packaged; see repository) |
| tinyvec | 1.13.3 | https://github.com/Lokathor/tinyvec | Copyright (c) 2019 Daniel "Lokathor" Gee. |

### ISC (4)

Used under: ISC

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| audiopus_sys | 0.2.2 | https://github.com/lakelezz/audiopus_sys.git | Copyright (c) 2019, Lakelezz |
| libloading | 0.8.9 | https://github.com/nagisa/rust_libloading/ | Copyright © 2015, Simonas Kazlauskas |
| rustls-webpki | 0.103.16 | https://github.com/rustls/webpki | Copyright 2015 Brian Smith. |
| untrusted | 0.9.0 | https://github.com/briansmith/untrusted | Copyright 2015-2016 Brian Smith. |

### Unlicense OR MIT (4)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| aho-corasick | 1.1.5 | https://github.com/BurntSushi/aho-corasick | Copyright (c) 2015 Andrew Gallant |
| byteorder | 1.5.0 | https://github.com/BurntSushi/byteorder | Copyright (c) 2015 Andrew Gallant |
| byteorder-lite | 0.1.0 | https://github.com/image-rs/byteorder-lite | Copyright (c) 2015 Andrew Gallant |
| memchr | 2.8.3 | https://github.com/BurntSushi/memchr | Copyright (c) 2015 Andrew Gallant |

### MIT OR Apache-2.0 OR Zlib (3)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| lru-slab | 0.1.3 | https://github.com/Ralith/lru-slab | Copyright (c) 2024 The lru-slab Developers |
| zune-core | 0.5.3 | https://github.com/etemesi254/zune-image | Copyright (c) zune-image developers |
| zune-jpeg | 0.5.15 | https://github.com/etemesi254/zune-image/tree/dev/crates/zune-jpeg | Copyright (c) zune-image developers |

### Zlib (3)

Used under: Zlib

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| foldhash | 0.1.5 | https://github.com/orlp/foldhash | Copyright (c) 2024 Orson Peters |
| foldhash | 0.2.0 | https://github.com/orlp/foldhash | Copyright (c) 2024 Orson Peters |
| zlib-rs | 0.6.8 | https://github.com/trifectatechfoundation/zlib-rs | (C) 2024 Trifecta Tech Foundation |

### Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT (2)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| linux-raw-sys | 0.12.1 | https://github.com/sunfishcode/linux-raw-sys | Authors: Dan Gohman <dev@sunfishcode.online> |
| rustix | 1.1.6 | https://github.com/bytecodealliance/rustix | Authors: Dan Gohman <dev@sunfishcode.online>, Jakub Konka <kubkon@jakubkonka.com> |

### BSD-3-Clause OR Apache-2.0 (2)

Used under: Apache-2.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| moxcms | 0.8.1 | https://github.com/awxkee/moxcms.git | Copyright 2024 Radzivon Bartoshyk; Copyright (c) Radzivon Bartoshyk. All rights reserved. |
| pxfm | 0.1.30 | https://github.com/awxkee/pxfm | Copyright 2024 Radzivon Bartoshyk; Copyright (c) Radzivon Bartoshyk. All rights reserved. |

### BSD-3-Clause OR MIT OR Apache-2.0 (2)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| num_enum | 0.7.6 | https://github.com/illicitonion/num_enum | Copyright (c) 2018, Daniel Wagner-Hall |
| num_enum_derive | 0.7.6 | https://github.com/illicitonion/num_enum | Copyright (c) 2018, Daniel Wagner-Hall |

### CC0-1.0 (2)

Used under: CC0-1.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| secp256k1 | 0.29.1 | https://github.com/rust-bitcoin/rust-secp256k1/ | Authors: Dawid Ciężarkiewicz <dpc@ucore.info>, Andrew Poelstra <apoelstra@wpsoftware.net> |
| secp256k1-sys | 0.10.1 | https://github.com/rust-bitcoin/rust-secp256k1/ | Authors: Dawid Ciężarkiewicz <dpc@ucore.info>, Andrew Poelstra <apoelstra@wpsoftware.net>, Steven Roose <steven@stevenroose.org> |

### CDLA-Permissive-2.0 (2)

Used under: CDLA-Permissive-2.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| webpki-roots | 0.26.11 | https://github.com/rustls/webpki-roots | (no copyright line packaged; see repository) |
| webpki-roots | 1.0.11 | https://github.com/rustls/webpki-roots | (no copyright line packaged; see repository) |

### MIT OR Zlib OR Apache-2.0 (2)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| miniz_oxide | 0.8.9 | https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide | Copyright 2013-2014 RAD Game Tools and Valve Software; Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC; Copyright (c) 2017 Frommi; Copyright (c) 2017-2024 oyvindln |
| miniz_oxide | 0.9.1 | https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide | Copyright 2013-2014 RAD Game Tools and Valve Software; Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC; Copyright (c) 2017 Frommi; Copyright (c) 2017-2024 oyvindln |

### MPL-2.0 (2)

Used under: MPL-2.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| attohttpc | 0.30.1 | https://github.com/sbstp/attohttpc | Authors: Simon Bernier St-Pierre <git.sbstp.ca@gmail.com> |
| option-ext | 0.2.0 | https://github.com/soc/option-ext.git | Authors: Simon Ochsenreither <simon@ochsenreither.de> |

### (MIT OR Apache-2.0) AND Unicode-3.0 (1)

Used under: MIT AND Unicode-3.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| unicode-ident | 1.0.27 | https://github.com/dtolnay/unicode-ident | Copyright © 1991-2023 Unicode, Inc. |

### 0BSD OR MIT OR Apache-2.0 (1)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| adler2 | 2.0.1 | https://github.com/oyvindln/adler2 | Copyright (C) Jonas Schievink <jonasschievink@gmail.com> |

### Apache-2.0 AND ISC (1)

Used under: Apache-2.0 AND ISC

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| ring | 0.17.14 | https://github.com/briansmith/ring | Copyright (c) 2009 The Go Authors. All rights reserved.; Copyright 2015 The Chromium Authors. All rights reserved.; Copyright 2015-2025 Brian Smith. |

### Apache-2.0 OR ISC OR MIT (1)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| rustls | 0.23.46 | https://github.com/rustls/rustls | Copyright (c) 2016, Joseph Birr-Pixton <jpixton@gmail.com>; Copyright (c) 2016 Joseph Birr-Pixton <jpixton@gmail.com> |

### BSD-2-Clause OR Apache-2.0 OR MIT (1)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| zerocopy | 0.8.63 | https://github.com/google/zerocopy | Copyright 2023 The Fuchsia Authors; Copyright 2019 The Fuchsia Authors. |

### BSD-2-Clause OR MIT OR Apache-2.0 (1)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| mach2 | 0.6.0 | https://github.com/JohnTitor/mach2 | Copyright (c) 2019 Nick Fitzgerald, 2021 Yuki Okushi |

### BlueOak-1.0.0 OR MIT OR Apache-2.0 (1)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| anymap3 | 1.1.0 | https://github.com/reivilibre/anymap3 | Copyright © 2014–2022 Chris Morgan |

### CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception (1)

Used under: Apache-2.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| blake3 | 1.8.7 | https://github.com/BLAKE3-team/BLAKE3 | Copyright 2019 Jack O'Connor and Samuel Neves |

### CC0-1.0 OR MIT-0 OR Apache-2.0 (1)

Used under: Apache-2.0

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| constant_time_eq | 0.4.2 | https://github.com/cesarb/constant_time_eq | Authors: Cesar Eduardo Barros <cesarb@cesarb.eti.br> |

### MIT AND BSD-3-Clause (1)

Used under: BSD-3-Clause AND MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| matchit | 0.8.4 | https://github.com/ibraheemdev/matchit | Copyright (c) 2022 Ibraheem Ahmed; Copyright (c) 2013, Julien Schmidt |

### MIT AND BSD-3-Clause AND blessing AND WTFPL (1)

Used under: BSD-3-Clause AND MIT AND WTFPL AND blessing

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| sqlcipher-src | 419.0.6+sqlcipher-4.19.0-sqlite-3.53.4-libtomcrypt-1.18.2 | https://github.com/LucaCappelletti94/sqlcipher-src | Copyright (c) 2026 Luca Cappelletti |

### MIT OR BSD-3-Clause (1)

Used under: MIT

| Crate | Version | Repository | Copyright |
|---|---|---|---|
| if-addrs | 0.15.0 | https://github.com/messense/if-addrs | Copyright 2018 MaidSafe.net limited.; Copyright 2020 messense |

### Native (C/C++) code compiled into the Rust core

#### Opus audio codec (Xiph.Org and contributors)

- Crate: `audiopus_sys` 0.2.2 - license: BSD-3-Clause
- Note: Bundled source is compiled in unless the build host provides a system libopus via pkg-config (then libopus is linked dynamically and is not shipped).

<details><summary>audiopus_sys/opus/COPYING</summary>

```text
Copyright 2001-2011 Xiph.Org, Skype Limited, Octasic,
                    Jean-Marc Valin, Timothy B. Terriberry,
                    CSIRO, Gregory Maxwell, Mark Borgerding,
                    Erik de Castro Lopo

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of Internet Society, IETF or IETF Trust, nor the
names of specific contributors, may be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Opus is subject to the royalty-free patent licenses which are
specified at:

Xiph.Org Foundation:
https://datatracker.ietf.org/ipr/1524/

Microsoft Corporation:
https://datatracker.ietf.org/ipr/1914/

Broadcom Corporation:
https://datatracker.ietf.org/ipr/1526/
```

</details>

<details><summary>audiopus_sys/opus/LICENSE_PLEASE_READ.txt</summary>

```text
Contributions to the collaboration shall not be considered confidential.

Each contributor represents and warrants that it has the right and
authority to license copyright in its contributions to the collaboration.

Each contributor agrees to license the copyright in the contributions
under the Modified (2-clause or 3-clause) BSD License or the Clear BSD License.

Please see the IPR statements submitted to the IETF for the complete
patent licensing details:

Xiph.Org Foundation:
https://datatracker.ietf.org/ipr/1524/

Microsoft Corporation:
https://datatracker.ietf.org/ipr/1914/

Skype Limited:
https://datatracker.ietf.org/ipr/1602/

Broadcom Corporation:
https://datatracker.ietf.org/ipr/1526/
```

</details>

#### SpeexDSP echo canceller (Xiph.Org and contributors)

- Crate: `aec-rs-sys` 1.0.0 - license: BSD-3-Clause
- Note: Compiled from the copy inside aec-rs-sys. The crate itself ships no license file.

<details><summary>aec-rs-sys/speexdsp/COPYING</summary>

```text
Copyright 2002-2008 	Xiph.org Foundation
Copyright 2002-2008 	Jean-Marc Valin
Copyright 2005-2007	Analog Devices Inc.
Copyright 2005-2008	Commonwealth Scientific and Industrial Research
                        Organisation (CSIRO)
Copyright 1993, 2002, 2006 David Rowe
Copyright 2003 		EpicGames
Copyright 1992-1994	Jutta Degener, Carsten Bormann

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

- Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

- Neither the name of the Xiph.org Foundation nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

</details>

#### libsecp256k1 (Bitcoin Core contributors)

- Crate: `secp256k1-sys` 0.10.1 - license: MIT

<details><summary>secp256k1-sys/depend/secp256k1/COPYING</summary>

```text
Copyright (c) 2013 Pieter Wuille

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

</details>

#### OpenSSL 3.x libcrypto (used by SQLCipher)

- Crate: `openssl-src` 300.6.1+3.6.3 - license: Apache-2.0
- Note: Vendored and statically linked via rusqlite feature bundled-sqlcipher-vendored-openssl.

<details><summary>openssl-src/openssl/LICENSE.txt</summary>

```text

                                 Apache License
                           Version 2.0, January 2004
                        https://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
```

</details>

#### SQLCipher (Zetetic LLC) with SQLite (public domain) and LibTomCrypt

- Crate: `sqlcipher-src` 419.0.6+sqlcipher-4.19.0-sqlite-3.53.4-libtomcrypt-1.18.2 - license: BSD-3-Clause AND blessing
- Note: SQLite itself is public domain (blessing). LibTomCrypt sources are present in the package (public domain / WTFPL dual license); with vendored OpenSSL it is not the selected crypto provider.

<details><summary>sqlcipher-src/sqlcipher/LICENSE-sqlcipher</summary>

```text
Copyright (c) 2025, ZETETIC LLC
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the ZETETIC LLC nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY ZETETIC LLC ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL ZETETIC LLC BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

</details>

<details><summary>sqlcipher-src/sqlcipher/LICENSE-libtomcrypt</summary>

```text
LibTomCrypt is licensed under DUAL licensing terms.

Choose and use the license of your needs.

[LICENSE #1]

LibTomCrypt is public domain.  As should all quality software be.

Tom St Denis

[/LICENSE #1]

[LICENSE #2]

            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
                    Version 2, December 2004

 Copyright (C) 2004 Sam Hocevar <sam@hocevar.net>

 Everyone is permitted to copy and distribute verbatim or modified
 copies of this license document, and changing it is allowed as long
 as the name is changed.

            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

  0. You just DO WHAT THE FUCK YOU WANT TO. 

[/LICENSE #2]
```

</details>

#### BoringSSL / OpenSSL-derived crypto code inside ring

- Crate: `ring` 0.17.14 - license: Apache-2.0 AND ISC

<details><summary>ring/LICENSE-BoringSSL</summary>

```text

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.


Licenses for support code
-------------------------

Parts of the TLS test suite are under the Go license. This code is not included
in BoringSSL (i.e. libcrypto and libssl) when compiled, however, so
distributing code linked against BoringSSL does not trigger this license:

Copyright (c) 2009 The Go Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


BoringSSL uses the Chromium test infrastructure to run a continuous build,
trybots etc. The scripts which manage this, and the script for generating build
metadata, are under the Chromium license. Distributing code linked against
BoringSSL does not trigger this license.

Copyright 2015 The Chromium Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

</details>

<details><summary>ring/LICENSE-other-bits</summary>

```text
Copyright 2015-2025 Brian Smith.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

</details>

## Flutter, Dart SDK and Dart packages

### Flutter SDK 3.38.9 and Dart SDK 3.10.8

- Flutter framework: BSD-3-Clause (text below).
- Dart SDK / runtime: BSD-3-Clause (text below).
- Flutter engine (compiled into `libflutter`/`flutter_windows.dll`/`Flutter.framework`, including `icudtl.dat`): Skia, Impeller and the engine are BSD-3-Clause; the engine also contains the components below under their own licenses (BSD, MIT, Apache-2.0, ICU/Unicode, FreeType FTL, zlib, libpng, MPL-2.0 root-certificate data, ...). Their complete texts are in `<flutter>/bin/cache/pkg/sky_engine/LICENSE` and every Lumora build displays them at runtime (Settings > About > Open-source licenses, Flutter's `showLicensePage`).

Engine components: abseil-cpp, accessibility, angle, boringssl, brotli, ceval, cpu_features, dart, dawn, devtools, double-conversion, equatable, etc1, etc_decoder, expat, fallback_root_certificates, ffx_spd, fiat, flatbuffers, flutter, freetype2, fuchsia_sdk, glfw, glslang, gtest-parallel, harfbuzz, icu, include, inja, io, json, khronos, libcxx, libcxxabi, libjpeg-turbo, libjxl, libpng, libtess2, libwebp, llvm_libc, lunarg-vulkantools, node_preamble, perfetto, process_runner, rapidjson, re2, shaderc, skia, spirv-cross, spirv-tools, spring_animation, sqlite, swiftshader, test_shaders, tonic, volk, vulkan, vulkan-deps, vulkan-headers, vulkan-tools, vulkan-utility-libraries, vulkan-validation-layers, vulkan_memory_allocator, web_locale_keymap, web_test_fonts, wuffs, wycheproof_testvectors, xxhash, yapf, yapf_diff, zlib

#### Flutter LICENSE

```text
Copyright 2014 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

#### Dart SDK LICENSE

```text
Copyright 2012, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Dart packages (110, non-dev, transitive)

| Package | Version | License (detected) | Repository | Copyright | Text |
|---|---|---|---|---|---|
| android_file_picker | 2.1.3 | MIT | https://github.com/vicajilau/flutter_file_picker/tree/main/packages/file_picker_android | Copyright (c) 2018 Miguel Ruivo | [D-04316b6b3fb4](#d-04316b6b3fb4) |
| archive | 4.6.0 | BSD-3-Clause AND MIT AND Zlib | https://github.com/brendan-duncan/archive | Copyright (c) 2013-2021 Brendan Duncan.; Copyright (c) 2012 imaya; Copyright (c) 2000-2011 ymnk, JCraft,Inc. All rights reserved. | [D-bb291e004096](#d-bb291e004096) |
| args | 2.7.0 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/args | Copyright 2013, the Dart project authors. | [D-df29899a60d1](#d-df29899a60d1) |
| async | 2.13.1 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/async | Copyright 2015, the Dart project authors. | [D-4f31d21986fa](#d-4f31d21986fa) |
| audio_session | 0.2.4 | MIT | https://github.com/ryanheise/audio_session | Copyright (c) 2020 Ryan Heise and the project contributors. | [D-209f7d1936dd](#d-209f7d1936dd) |
| characters | 1.4.0 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/characters | Copyright 2019, the Dart project authors. | [D-f7864e97fa91](#d-f7864e97fa91) |
| clock | 1.1.2 | Apache-2.0 | https://github.com/dart-lang/tools/tree/main/pkgs/clock | (see license text) | [D-0ffddef9e48f](#d-0ffddef9e48f) |
| collection | 1.19.1 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/collection | Copyright 2015, the Dart project authors. | [D-4f31d21986fa](#d-4f31d21986fa) |
| cross_file | 0.3.5+5 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/cross_file | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| crypto | 3.0.8 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/crypto | Copyright 2015, the Dart project authors. | [D-4f31d21986fa](#d-4f31d21986fa) |
| cupertino_icons | 1.0.9 | MIT | https://github.com/flutter/packages/tree/main/third_party/packages/cupertino_icons | Copyright (c) 2016 Vladimir Kharlampidi | [D-3f76a95433d6](#d-3f76a95433d6) |
| dart_earcut | 1.2.0 | ISC AND MIT | https://github.com/JaffaKetchup/dart_earcut | Copyright (c) 2025 Luka Stillingfleet (JaffaKetchup); Copyright (c) 2016, Mapbox | [D-77cc4d9e235d](#d-77cc4d9e235d) |
| dart_polylabel2 | 1.0.0 | BSD-3-Clause AND ISC | https://github.com/JaffaKetchup/dart_polylabel2 | Copyright (c) 2021 - 2025 André Sousa, 2025 Luka Stillingfleet (JaffaKetchup); Copyright (c) 2016 Mapbox | [D-df9df04a9d7c](#d-df9df04a9d7c) |
| dbus | 0.8.0 | MPL-2.0 | https://github.com/canonical/dbus.dart | (see license text) | [D-a7fae6cb34ec](#d-a7fae6cb34ec) |
| desktop_drop | 0.8.0 | Apache-2.0 | https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_drop | (see license text) | [D-853e2cb1291c](#d-853e2cb1291c) |
| ffi | 2.2.0 | BSD-3-Clause | https://github.com/dart-lang/native/tree/main/pkgs/ffi | Copyright 2019, the Dart project authors. | [D-f7864e97fa91](#d-f7864e97fa91) |
| ffi_leak_tracker | 0.1.2 | BSD-3-Clause | https://github.com/halildurmus/win32/tree/main/packages/ffi_leak_tracker | Copyright (c) 2026, Halil Durmus | [D-59801726fc33](#d-59801726fc33) |
| file_picker | 13.3.2 | MIT | https://github.com/vicajilau/flutter_file_picker/tree/main/packages/file_picker | Copyright (c) 2018 Miguel Ruivo | [D-04316b6b3fb4](#d-04316b6b3fb4) |
| file_picker_darwin | 2.4.2 | MIT | https://github.com/vicajilau/flutter_file_picker/tree/main/packages/file_picker_darwin | Copyright (c) 2018 Miguel Ruivo | [D-04316b6b3fb4](#d-04316b6b3fb4) |
| file_picker_linux | 2.0.3 | MIT | https://github.com/vicajilau/flutter_file_picker/tree/main/packages/file_picker_linux | Copyright (c) 2018 Miguel Ruivo | [D-04316b6b3fb4](#d-04316b6b3fb4) |
| file_picker_platform_interface | 4.2.0 | MIT | https://github.com/vicajilau/flutter_file_picker/tree/main/packages/file_picker_platform_interface | Copyright (c) 2018 Miguel Ruivo | [D-04316b6b3fb4](#d-04316b6b3fb4) |
| file_picker_web | 4.2.0 | MIT | https://github.com/vicajilau/flutter_file_picker/tree/main/packages/file_picker_web | Copyright (c) 2018 Miguel Ruivo | [D-04316b6b3fb4](#d-04316b6b3fb4) |
| fixnum | 1.1.1 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/fixnum | Copyright 2014, the Dart project authors. | [D-5f14aa861add](#d-5f14aa861add) |
| flutter_map | 8.3.2 | BSD-3-Clause | https://github.com/fleaflet/flutter_map | Copyright (c) 2018-2026, the 'flutter_map' authors and maintainers | [D-49ae8fe03230](#d-49ae8fe03230) |
| flutter_markdown_plus | 1.0.12 | BSD-3-Clause | https://github.com/foresightmobile/flutter_markdown_plus | Copyright 2013 The Flutter Authors. All rights reserved. | [D-b2dfea7ab005](#d-b2dfea7ab005) |
| flutter_svg | 2.3.0 | MIT | https://github.com/flutter/packages/tree/main/third_party/packages/flutter_svg | Copyright (c) 2018 Dan Field | [D-b132a5755049](#d-b132a5755049) |
| geolocator | 14.0.1 | MIT | https://github.com/baseflow/flutter-geolocator/tree/main/geolocator | Copyright (c) 2018 Baseflow | [D-5c3c8e81b7bb](#d-5c3c8e81b7bb) |
| geolocator_android | 5.2.1 | MIT | https://github.com/baseflow/flutter-geolocator/tree/main/geolocator_android | Copyright (c) 2018 Baseflow | [D-5c3c8e81b7bb](#d-5c3c8e81b7bb) |
| geolocator_apple | 2.4.3 | MIT | https://github.com/baseflow/flutter-geolocator/tree/main/geolocator_apple | Copyright (c) 2018 Baseflow | [D-5c3c8e81b7bb](#d-5c3c8e81b7bb) |
| geolocator_platform_interface | 4.4.1 | MIT | https://github.com/baseflow/flutter-geolocator/tree/main/geolocator_platform_interface | Copyright (c) 2018 Baseflow | [D-5c3c8e81b7bb](#d-5c3c8e81b7bb) |
| geolocator_web | 4.1.4 | MIT | https://github.com/baseflow/flutter-geolocator/tree/main/geolocator_web | Copyright (c) 2018 Baseflow | [D-5c3c8e81b7bb](#d-5c3c8e81b7bb) |
| geolocator_windows | 0.2.5 | MIT | https://github.com/baseflow/flutter-geolocators | Copyright (c) 2018 Baseflow | [D-5c3c8e81b7bb](#d-5c3c8e81b7bb) |
| http | 1.6.0 | BSD-3-Clause | https://github.com/dart-lang/http/tree/master/pkgs/http | Copyright 2014, the Dart project authors. | [D-5f14aa861add](#d-5f14aa861add) |
| http_parser | 4.1.2 | BSD-3-Clause | https://github.com/dart-lang/http/tree/master/pkgs/http_parser | Copyright 2014, the Dart project authors. | [D-5f14aa861add](#d-5f14aa861add) |
| image | 4.12.0 | Apache-2.0 AND BSD-3-Clause AND MIT | https://github.com/brendan-duncan/image | Copyright (c) 2013-2022 Brendan Duncan.; Copyright (C) 2011 notmasteryet; Copyright (c) 2010, Google Inc. All rights reserved. | [D-14e4b4a14aca](#d-14e4b4a14aca) |
| intl | 0.20.3 | BSD-3-Clause | https://github.com/dart-lang/i18n/tree/main/pkgs/intl | Copyright 2013, the Dart project authors. | [D-df29899a60d1](#d-df29899a60d1) |
| jni | 1.1.2 | BSD-3-Clause | https://github.com/dart-lang/native/tree/main/pkgs/jni | Copyright 2022, the Dart project authors. | [D-53664486029b](#d-53664486029b) |
| jni_flutter | 1.0.4+1 | BSD-3-Clause | https://github.com/dart-lang/native/tree/main/pkgs/jni_flutter | Copyright 2026, the Dart project authors. | [D-d6b499d3653f](#d-d6b499d3653f) |
| jni_util | 1.0.0 | BSD-3-Clause | https://github.com/dart-lang/native/tree/main/pkgs/jni_util | Copyright 2026, the Dart project authors. | [D-d6b499d3653f](#d-d6b499d3653f) |
| just_audio | 0.10.6 | Apache-2.0 AND MIT | https://github.com/ryanheise/just_audio/tree/minor/just_audio | Copyright (c) 2019-2020 Ryan Heise and the project contributors. | [D-7dd23b2a6a83](#d-7dd23b2a6a83) |
| just_audio_platform_interface | 4.6.0 | MIT | https://github.com/ryanheise/just_audio/tree/master/just_audio_platform_interface | Copyright (c) 2020 Ryan Heise and the project contributors. | [D-209f7d1936dd](#d-209f7d1936dd) |
| just_audio_web | 0.4.16 | MIT | https://github.com/ryanheise/just_audio/tree/master/just_audio_web | Copyright (c) 2020 Ryan Heise and the project contributors. | [D-209f7d1936dd](#d-209f7d1936dd) |
| latlong2 | 0.10.1 | Apache-2.0 | https://github.com/ThexXTURBOXx/dart-latlong | Copyright 2015 Michael Mitterer (office@mikemitterer.at), | [D-6d4a9df1048d](#d-6d4a9df1048d) |
| lottie | 3.3.3 | MIT | https://github.com/xvrh/lottie-flutter | (see license text) | [D-c6c34df041f5](#d-c6c34df041f5) |
| markdown | 7.3.1 | BSD-3-Clause | https://github.com/dart-lang/tools/tree/main/pkgs/markdown | Copyright 2012, the Dart project authors. | [D-f599e946e807](#d-f599e946e807) |
| material_color_utilities | 0.11.1 | Apache-2.0 | https://github.com/material-foundation/material-color-utilities/tree/main/dart | Copyright 2021 Google LLC | [D-33d0d686f379](#d-33d0d686f379) |
| meta | 1.17.0 | BSD-3-Clause | https://github.com/dart-lang/sdk/tree/main/pkg/meta | Copyright 2016, the Dart project authors. | [D-38dd2067d2d3](#d-38dd2067d2d3) |
| mgrs_dart | 3.0.0 | MIT | https://github.com/fegyi001/mgrs_dart | Copyright (c) 2020 Gergely Padányi-Gulyás | [D-f50cf33af148](#d-f50cf33af148) |
| mobile_scanner | 7.5.0 | BSD-3-Clause | https://github.com/juliansteenbakker/mobile_scanner | Copyright (c) 2022, Julian Steenbakker | [D-bff5bbac7f69](#d-bff5bbac7f69) |
| nested | 1.0.0 | MIT | https://github.com/rrousselGit/nested | Copyright (c) 2019 Remi Rousselet | [D-d34e63122955](#d-d34e63122955) |
| package_config | 2.2.0 | BSD-3-Clause | https://github.com/dart-lang/tools/tree/main/pkgs/package_config | Copyright 2019, the Dart project authors. | [D-f7864e97fa91](#d-f7864e97fa91) |
| path | 1.9.1 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/path | Copyright 2014, the Dart project authors. | [D-5f14aa861add](#d-5f14aa861add) |
| path_parsing | 1.1.0 | MIT | https://github.com/flutter/packages/tree/main/third_party/packages/path_parsing | Copyright (c) 2018 Dan Field | [D-b132a5755049](#d-b132a5755049) |
| path_provider | 2.1.6 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| path_provider_android | 2.3.1 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider_android | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| path_provider_foundation | 2.4.4 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider_foundation | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| path_provider_linux | 2.2.2 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider_linux | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| path_provider_platform_interface | 2.1.3 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider_platform_interface | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| path_provider_windows | 2.3.0 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/path_provider/path_provider_windows | Copyright 2013 The Flutter Authors. All rights reserved. | [D-b2dfea7ab005](#d-b2dfea7ab005) |
| pdfium_dart | 0.1.3 | MIT | https://github.com/espresso3389/pdfrx/tree/master/packages/pdfium_dart | Copyright (c) 2025 @espresso3389 (Takashi Kawasaki) | [D-ae9617969522](#d-ae9617969522) |
| pdfium_flutter | 0.1.9 | MIT | https://github.com/espresso3389/pdfrx/tree/master/packages/pdfium_flutter | Copyright (c) 2025 @espresso3389 (Takashi Kawasaki) | [D-ae9617969522](#d-ae9617969522) |
| pdfrx | 2.2.24 | MIT | https://github.com/espresso3389/pdfrx/tree/master/packages/pdfrx | Copyright (c) 2018 @espresso3389 (Takashi Kawasaki) | [D-8cece6d9380e](#d-8cece6d9380e) |
| pdfrx_engine | 0.3.9 | MIT | https://github.com/espresso3389/pdfrx/tree/master/packages/pdfrx_engine | Copyright (c) 2018 @espresso3389 (Takashi Kawasaki) | [D-8cece6d9380e](#d-8cece6d9380e) |
| petitparser | 7.0.2 | MIT | https://github.com/petitparser/dart-petitparser | Copyright (c) 2006-2024 Lukas Renggli. | [D-7abb159b5a7e](#d-7abb159b5a7e) |
| phosphor_flutter | 2.1.0 | MIT | https://github.com/phosphor-icons/phosphor-flutter | Copyright (c) 2020-2021 Phosphor Icons | [D-95a3f7c748be](#d-95a3f7c748be) |
| platform | 3.1.6 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/platform | Copyright 2017, the Dart project authors. All rights reserved. | [D-fdb0a6ccce25](#d-fdb0a6ccce25) |
| plugin_platform_interface | 2.1.8 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/plugin_platform_interface | Copyright 2013 The Flutter Authors. All rights reserved. | [D-b2dfea7ab005](#d-b2dfea7ab005) |
| posix | 6.5.4 | MIT | https://github.com/onepub-dev/dart_posix | Copyright (c) 2020 Brett Sutton | [D-7758ad1f6f77](#d-7758ad1f6f77) |
| proj4dart | 3.0.0 | MIT | https://github.com/maRci002/proj4dart | Copyright (c) 2020 maRci002, Gergely Padányi-Gulyás (fegyi001) | [D-8b2d593e28fc](#d-8b2d593e28fc) |
| provider | 6.1.5+1 | MIT | https://github.com/rrousselGit/provider | Copyright (c) 2019 Remi Rousselet | [D-d34e63122955](#d-d34e63122955) |
| qr | 3.0.3 | BSD-3-Clause | https://github.com/kevmoo/qr.dart | Copyright 2014, the Dart QR project authors. All rights reserved. | [D-51b17901817c](#d-51b17901817c) |
| qr_flutter | 4.1.0 | BSD-3-Clause | https://github.com/theyakka/qr.flutter | Copyright (c) 2020, Luke Freeman. | [D-0e131b55dadf](#d-0e131b55dadf) |
| re_highlight | 0.0.3 | MIT | https://github.com/reqable/re-highlight | Copyright (c) 2024 Reqable | [D-1ca45d4d1d0b](#d-1ca45d4d1d0b) |
| record | 6.2.1 | BSD-3-Clause | https://github.com/llfbandit/record/tree/master/record | Copyright 2022 openapi4j authors. All rights reserved. | [D-e2a2e91a609b](#d-e2a2e91a609b) |
| record_android | 1.5.2 | BSD-3-Clause | https://github.com/llfbandit/record/tree/master/record_android | Copyright 2022 openapi4j authors. All rights reserved. | [D-e2a2e91a609b](#d-e2a2e91a609b) |
| record_ios | 1.2.1 | BSD-3-Clause | https://github.com/llfbandit/record/tree/master/record_ios | Copyright 2022 openapi4j authors. All rights reserved. | [D-e2a2e91a609b](#d-e2a2e91a609b) |
| record_linux | 1.3.1 | BSD-3-Clause | https://github.com/llfbandit/record/tree/master/record_linux | Copyright 2022 openapi4j authors. All rights reserved. | [D-e2a2e91a609b](#d-e2a2e91a609b) |
| record_macos | 1.2.2 | BSD-3-Clause | https://github.com/llfbandit/record/tree/master/record_macos | Copyright 2022 openapi4j authors. All rights reserved. | [D-e2a2e91a609b](#d-e2a2e91a609b) |
| record_platform_interface | 1.6.0 | BSD-3-Clause | https://github.com/llfbandit/record/tree/master/record_platform_interface | Copyright 2022 openapi4j authors. All rights reserved. | [D-e2a2e91a609b](#d-e2a2e91a609b) |
| record_web | 1.3.0 | BSD-3-Clause | https://github.com/llfbandit/record/tree/master/record_web | Copyright 2022 openapi4j authors. All rights reserved. | [D-e2a2e91a609b](#d-e2a2e91a609b) |
| record_windows | 1.0.7 | BSD-3-Clause | https://github.com/llfbandit/record/tree/master/record_windows | Copyright 2022 openapi4j authors. All rights reserved. | [D-e2a2e91a609b](#d-e2a2e91a609b) |
| rxdart | 0.28.0 | Apache-2.0 | https://github.com/ReactiveX/rxdart | (see license text) | [D-0ffddef9e48f](#d-0ffddef9e48f) |
| simple_sparse_list | 0.1.4 | BSD-3-Clause | https://github.com/mezoni/simple_sparse_list | Copyright (c) 2024, Andrew Mezoni | [D-e3f71abe47ad](#d-e3f71abe47ad) |
| source_span | 1.10.2 | BSD-3-Clause | https://github.com/dart-lang/tools/tree/main/pkgs/source_span | Copyright 2014, the Dart project authors. | [D-5f14aa861add](#d-5f14aa861add) |
| string_scanner | 1.4.1 | BSD-3-Clause | https://github.com/dart-lang/tools/tree/main/pkgs/string_scanner | Copyright 2014, the Dart project authors. | [D-5f14aa861add](#d-5f14aa861add) |
| synchronized | 3.4.0 | MIT | https://github.com/tekartik/synchronized.dart/tree/master/synchronized | Copyright (c) 2016, Alexandre Roux Tekartik. | [D-dc238e7a9753](#d-dc238e7a9753) |
| term_glyph | 1.2.2 | BSD-3-Clause | https://github.com/dart-lang/tools/tree/main/pkgs/term_glyph | Copyright 2017, the Dart project authors. | [D-d17b393b9faa](#d-d17b393b9faa) |
| typed_data | 1.4.0 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/typed_data | Copyright 2015, the Dart project authors. | [D-4f31d21986fa](#d-4f31d21986fa) |
| unicode | 1.1.9 | BSD-3-Clause | https://github.com/mezoni/unicode | Copyright (c) 2014, Andrew Mezoni | [D-408284d54114](#d-408284d54114) |
| universal_platform | 1.1.0 | MIT | https://github.com/gskinnerTeam/flutter-universal-platform | Copyright (c) 2019 gskinner.com | [D-85ac4dc571b8](#d-85ac4dc571b8) |
| url_launcher | 6.3.2 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/url_launcher/url_launcher | Copyright 2013 The Flutter Authors. All rights reserved. | [D-b2dfea7ab005](#d-b2dfea7ab005) |
| url_launcher_android | 6.3.30 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/url_launcher/url_launcher_android | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| url_launcher_ios | 6.4.2 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/url_launcher/url_launcher_ios | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| url_launcher_linux | 3.2.3 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/url_launcher/url_launcher_linux | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| url_launcher_macos | 3.2.6 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/url_launcher/url_launcher_macos | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| url_launcher_platform_interface | 2.3.2 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/url_launcher/url_launcher_platform_interface | Copyright 2013 The Flutter Authors. All rights reserved. | [D-b2dfea7ab005](#d-b2dfea7ab005) |
| url_launcher_web | 2.4.3 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/url_launcher/url_launcher_web | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| url_launcher_windows | 3.1.6 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/url_launcher/url_launcher_windows | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| uuid | 4.6.0 | MIT | https://github.com/Daegalus/dart-uuid | Copyright (c) 2021 Yulian Kuncheff | [D-77c8bbf60d15](#d-77c8bbf60d15) |
| vector_graphics | 1.2.3 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/vector_graphics | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| vector_graphics_codec | 1.1.13 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/vector_graphics_codec | Copyright 2013 The Flutter Authors. All rights reserved. | [D-b2dfea7ab005](#d-b2dfea7ab005) |
| vector_graphics_compiler | 1.3.0 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/vector_graphics_compiler | Copyright 2013 The Flutter Authors | [D-1c16df050b1d](#d-1c16df050b1d) |
| vector_math | 2.2.0 | BSD-3-Clause AND Zlib | https://github.com/google/vector_math.dart | Copyright 2015, Google Inc. All rights reserved.; Copyright (C) 2013 Andrew Magill | [D-bc8b6422a461](#d-bc8b6422a461) |
| web | 1.1.1 | BSD-3-Clause | https://github.com/dart-lang/web | Copyright 2023, the Dart project authors. | [D-78c350049541](#d-78c350049541) |
| win32 | 6.4.0 | BSD-3-Clause | https://github.com/halildurmus/win32 | Copyright (c) 2024, Halil Durmus | [D-4b526277a9e2](#d-4b526277a9e2) |
| windows_file_picker | 2.0.1 | MIT | https://github.com/vicajilau/flutter_file_picker/tree/main/packages/file_picker_windows | Copyright (c) 2018 Miguel Ruivo | [D-04316b6b3fb4](#d-04316b6b3fb4) |
| wkt_parser | 2.0.0 | MIT | https://github.com/fegyi001/wkt-parser-dart | Copyright (c) 2020 Gergely Padányi-Gulyás | [D-f50cf33af148](#d-f50cf33af148) |
| xdg_directories | 1.1.0 | BSD-3-Clause | https://github.com/flutter/packages/tree/main/packages/xdg_directories | Copyright 2013 The Flutter Authors. All rights reserved. | [D-b2dfea7ab005](#d-b2dfea7ab005) |
| xml | 6.6.1 | MIT | https://github.com/renggli/dart-xml | Copyright (c) 2006-2025 Lukas Renggli. | [D-7a72e722dcaa](#d-7a72e722dcaa) |
| yaml | 3.1.4 | MIT | https://github.com/dart-lang/tools/tree/main/pkgs/yaml | Copyright (c) 2014, the Dart project authors.; Copyright (c) 2006, Kirill Simonov. | [D-3de266935886](#d-3de266935886) |

#### Dart package license texts (identical texts merged)

<a id="d-04316b6b3fb4"></a>

##### D-04316b6b3fb4 - MIT

Used by: android_file_picker 2.1.3, file_picker 13.3.2, file_picker_darwin 2.4.2, file_picker_linux 2.0.3, file_picker_platform_interface 4.2.0, file_picker_web 4.2.0, windows_file_picker 2.0.1

```text
MIT License

Copyright (c) 2018 Miguel Ruivo

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
FITNESS FOR A PARTICULAR PURPOSE AND NON INFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

<a id="d-bb291e004096"></a>

##### D-bb291e004096 - BSD-3-Clause AND MIT AND Zlib

Used by: archive 4.6.0

```text
The MIT License

Copyright (c) 2013-2021 Brendan Duncan.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

Some code has been derived from the following projects:

zlib/inflate:
JavaScript Zlib Library, https://github.com/imaya/zlib.js
The MIT License
Copyright (c) 2012 imaya

zlib/deflate:
Java JZLib Library, http://www.jcraft.com/jzlib/
Copyright (c) 2000-2011 ymnk, JCraft,Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice,
       this list of conditions and the following disclaimer.
  
    2. Redistributions in binary form must reproduce the above copyright 
       notice, this list of conditions and the following disclaimer in 
       the documentation and/or other materials provided with the distribution.
  
    3. The names of the authors may not be used to endorse or promote products
       derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESSED OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL JCRAFT,
INC. OR ANY CONTRIBUTORS TO THIS SOFTWARE BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

bzip2:
This program, "bzip2", the associated library "libbzip2", and all
documentation, are copyright (C) 1996-2010 Julian R Seward.  All
rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

2. The origin of this software must not be misrepresented; you must
   not claim that you wrote the original software.  If you use this
   software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

3. Altered source versions must be plainly marked as such, and must
   not be misrepresented as being the original software.

4. The name of the author may not be used to endorse or promote
   products derived from this software without specific prior written
   permission.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS
OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Julian Seward, jseward@bzip.org
bzip2/libbzip2 version 1.0.6 of 6 September 2010

crc32 (Chorba algorithm, https://arxiv.org/abs/2412.16398):
zlib-ng, https://github.com/zlib-ng/zlib-ng, crc32_chorba_c.c
(C) 1995-2024 Jean-loup Gailly and Mark Adler

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.

3. This notice may not be removed or altered from any source distribution.

zstd and xxh64:
Zstandard 1.5.7, https://github.com/facebook/zstd, including lib/common/xxhash.h
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
```

<a id="d-df29899a60d1"></a>

##### D-df29899a60d1 - BSD-3-Clause

Used by: args 2.7.0, intl 0.20.3

```text
Copyright 2013, the Dart project authors. 

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-4f31d21986fa"></a>

##### D-4f31d21986fa - BSD-3-Clause

Used by: async 2.13.1, collection 1.19.1, crypto 3.0.8, typed_data 1.4.0

```text
Copyright 2015, the Dart project authors. 

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-209f7d1936dd"></a>

##### D-209f7d1936dd - MIT

Used by: audio_session 0.2.4, just_audio_platform_interface 4.6.0, just_audio_web 0.4.16

```text
MIT License

Copyright (c) 2020 Ryan Heise and the project contributors.

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
```

<a id="d-f7864e97fa91"></a>

##### D-f7864e97fa91 - BSD-3-Clause

Used by: characters 1.4.0, ffi 2.2.0, package_config 2.2.0

```text
Copyright 2019, the Dart project authors. 

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-0ffddef9e48f"></a>

##### D-0ffddef9e48f - Apache-2.0

Used by: clock 1.1.2, rxdart 0.28.0

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

<a id="d-1c16df050b1d"></a>

##### D-1c16df050b1d - BSD-3-Clause

Used by: cross_file 0.3.5+5, path_provider 2.1.6, path_provider_android 2.3.1, path_provider_foundation 2.4.4, path_provider_linux 2.2.2, path_provider_platform_interface 2.1.3, url_launcher_android 6.3.30, url_launcher_ios 6.4.2, url_launcher_linux 3.2.3, url_launcher_macos 3.2.6, url_launcher_web 2.4.3, url_launcher_windows 3.1.6, vector_graphics 1.2.3, vector_graphics_compiler 1.3.0

```text
Copyright 2013 The Flutter Authors

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-3f76a95433d6"></a>

##### D-3f76a95433d6 - MIT

Used by: cupertino_icons 1.0.9

```text
The MIT License (MIT)

Copyright (c) 2016 Vladimir Kharlampidi

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
```

<a id="d-77cc4d9e235d"></a>

##### D-77cc4d9e235d - ISC AND MIT

Used by: dart_earcut 1.2.0

```text
MIT License

Copyright (c) 2025 Luka Stillingfleet (JaffaKetchup)

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

ISC License

Copyright (c) 2016, Mapbox

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```

<a id="d-df9df04a9d7c"></a>

##### D-df9df04a9d7c - BSD-3-Clause AND ISC

Used by: dart_polylabel2 1.0.0

```text
Copyright (c) 2021 - 2025 André Sousa, 2025 Luka Stillingfleet (JaffaKetchup)

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

ISC License
Copyright (c) 2016 Mapbox

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND ISC DISCLAIMS ALL WARRANTIES WITH REGARD TO
THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
IN NO EVENT SHALL ISC BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA
OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS
ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS
SOFTWARE.
```

<a id="d-a7fae6cb34ec"></a>

##### D-a7fae6cb34ec - MPL-2.0

Used by: dbus 0.8.0

```text
Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.
```

<a id="d-853e2cb1291c"></a>

##### D-853e2cb1291c - Apache-2.0

Used by: desktop_drop 0.8.0

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [2021] [Mixin]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

<a id="d-59801726fc33"></a>

##### D-59801726fc33 - BSD-3-Clause

Used by: ffi_leak_tracker 0.1.2

```text
BSD 3-Clause License

Copyright (c) 2026, Halil Durmus

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-5f14aa861add"></a>

##### D-5f14aa861add - BSD-3-Clause

Used by: fixnum 1.1.1, http 1.6.0, http_parser 4.1.2, path 1.9.1, source_span 1.10.2, string_scanner 1.4.1

```text
Copyright 2014, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-49ae8fe03230"></a>

##### D-49ae8fe03230 - BSD-3-Clause

Used by: flutter_map 8.3.2

```text
BSD 3-Clause License

Copyright (c) 2018-2026, the 'flutter_map' authors and maintainers

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-b2dfea7ab005"></a>

##### D-b2dfea7ab005 - BSD-3-Clause

Used by: flutter_markdown_plus 1.0.12, path_provider_windows 2.3.0, plugin_platform_interface 2.1.8, url_launcher 6.3.2, url_launcher_platform_interface 2.3.2, vector_graphics_codec 1.1.13, xdg_directories 1.1.0

```text
Copyright 2013 The Flutter Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-b132a5755049"></a>

##### D-b132a5755049 - MIT

Used by: flutter_svg 2.3.0, path_parsing 1.1.0

```text
Copyright (c) 2018 Dan Field

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
```

<a id="d-5c3c8e81b7bb"></a>

##### D-5c3c8e81b7bb - MIT

Used by: geolocator 14.0.1, geolocator_android 5.2.1, geolocator_apple 2.4.3, geolocator_platform_interface 4.4.1, geolocator_web 4.1.4, geolocator_windows 0.2.5

```text
MIT License

Copyright (c) 2018 Baseflow

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
```

<a id="d-14e4b4a14aca"></a>

##### D-14e4b4a14aca - Apache-2.0 AND BSD-3-Clause AND MIT

Used by: image 4.12.0

```text
The MIT License

Copyright (c) 2013-2022 Brendan Duncan.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

Parts of the Image library were ported from the following sources:

==============================================================================

The JPEG encoder/decoder code is derived from the following:
https://github.com/notmasteryet/jpgjs
Copyright (C) 2011 notmasteryet

Contributors: Yury Delendik <ydelendik@mozilla.com>
Brendan Dahl <bdahl@mozilla.com>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

==============================================================================

The WebP encoder/decoder code is derived from the following:
http://git.chromium.org/gitweb/?p=webm/libwebp.git
Copyright (c) 2010, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in
      the documentation and/or other materials provided with the
      distribution.

    * Neither the name of Google nor the names of its contributors may
      be used to endorse or promote products derived from this software
      without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  
==============================================================================

The TIFF decoder code is derived from the following:
Apache Batik
http://svn.apache.org/repos/asf/xmlgraphics/batik/trunk
Copyright 1999-2007 The Apache Software Foundation
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

==============================================================================

The OpenEXR decoder is derived in part from the OpenEXR library:

Copyright (c) 2002-2011, Industrial Light & Magic, a division of
Lucasfilm Entertainment Company Ltd. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:


Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.
Redistributions in binary form must reproduce the above copyright notice, this
list of conditions and the following disclaimer in the documentation and/or
other materials provided with the distribution.
Neither the name of Industrial Light & Magic nor the names of its contributors
may be used to endorse or promote products derived from this software without
specific prior written permission.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

===============================================================================

The PVRTC compression and decompression code is ported from Jeffrey Lim's
PvrTcCompressor:

https://bitbucket.org/jthlim/pvrtccompressor

Copyright © 2014, Jeffrey Lim. All Rights Reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. The name of the author may not be used to endorse or promote products
   derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR
BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

===============================================================================

The pvr container format decoder is derived from the QuickPVR project:
QuickPVR is Copyright (C) 2010 Limbic Software, Inc.
http://www.limbicsoftware.com/quickpvr.html

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
* Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.
* Neither the name of the Limbic Software, Inc. nor the
names of its contributors may be used to endorse or promote products
derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY LIMBIC SOFTWARE, INC. ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL LIMBIC SOFTWARE, INC. BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  
```

<a id="d-53664486029b"></a>

##### D-53664486029b - BSD-3-Clause

Used by: jni 1.1.2

```text
Copyright 2022, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-d6b499d3653f"></a>

##### D-d6b499d3653f - BSD-3-Clause

Used by: jni_flutter 1.0.4+1, jni_util 1.0.0

```text
Copyright 2026, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-7dd23b2a6a83"></a>

##### D-7dd23b2a6a83 - Apache-2.0 AND MIT

Used by: just_audio 0.10.6

```text
MIT License

Copyright (c) 2019-2020 Ryan Heise and the project contributors.

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

==============================================================================

This software includes the ExoPlayer library which is licensed under the Apache
License, Version 2.0.


                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

<a id="d-6d4a9df1048d"></a>

##### D-6d4a9df1048d - Apache-2.0

Used by: latlong2 0.10.1

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2015 Michael Mitterer (office@mikemitterer.at),
   IT-Consulting and Development Limited, Austrian Branch

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

<a id="d-c6c34df041f5"></a>

##### D-c6c34df041f5 - MIT

Used by: lottie 3.3.3

```text
MIT License

Copyright (c) [year] [fullname]

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
```

<a id="d-f599e946e807"></a>

##### D-f599e946e807 - BSD-3-Clause

Used by: markdown 7.3.1

```text
Copyright 2012, the Dart project authors. 

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-33d0d686f379"></a>

##### D-33d0d686f379 - Apache-2.0

Used by: material_color_utilities 0.11.1

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

   To apply the Apache License to your work, attach the following
   boilerplate notice, with the fields enclosed by brackets "[]"
   replaced with your own identifying information. (Don't include
   the brackets!)  The text should be enclosed in the appropriate
   comment syntax for the file format. We also recommend that a
   file or class name and description of purpose be included on the
   same "printed page" as the copyright notice for easier
   identification within third-party archives.

   Copyright 2021 Google LLC

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

<a id="d-38dd2067d2d3"></a>

##### D-38dd2067d2d3 - BSD-3-Clause

Used by: meta 1.17.0

```text
Copyright 2016, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-f50cf33af148"></a>

##### D-f50cf33af148 - MIT

Used by: mgrs_dart 3.0.0, wkt_parser 2.0.0

```text
MIT License

Copyright (c) 2020 Gergely Padányi-Gulyás

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
```

<a id="d-bff5bbac7f69"></a>

##### D-bff5bbac7f69 - BSD-3-Clause

Used by: mobile_scanner 7.5.0

```text
BSD 3-Clause License

Copyright (c) 2022, Julian Steenbakker
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-d34e63122955"></a>

##### D-d34e63122955 - MIT

Used by: nested 1.0.0, provider 6.1.5+1

```text
MIT License

Copyright (c) 2019 Remi Rousselet

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
```

<a id="d-ae9617969522"></a>

##### D-ae9617969522 - MIT

Used by: pdfium_dart 0.1.3, pdfium_flutter 0.1.9

```text
The MIT License (MIT)
===============

Copyright (c) 2025 @espresso3389 (Takashi Kawasaki)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

<a id="d-8cece6d9380e"></a>

##### D-8cece6d9380e - MIT

Used by: pdfrx 2.2.24, pdfrx_engine 0.3.9

```text
The MIT License (MIT)
===============

Copyright (c) 2018 @espresso3389 (Takashi Kawasaki)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

<a id="d-7abb159b5a7e"></a>

##### D-7abb159b5a7e - MIT

Used by: petitparser 7.0.2

```text
The MIT License

Copyright (c) 2006-2024 Lukas Renggli.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

<a id="d-95a3f7c748be"></a>

##### D-95a3f7c748be - MIT

Used by: phosphor_flutter 2.1.0

```text
MIT License

Copyright (c) 2020-2021 Phosphor Icons

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
```

<a id="d-fdb0a6ccce25"></a>

##### D-fdb0a6ccce25 - BSD-3-Clause

Used by: platform 3.1.6

```text
Copyright 2017, the Dart project authors. All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-7758ad1f6f77"></a>

##### D-7758ad1f6f77 - MIT

Used by: posix 6.5.4

```text
MIT License

Copyright (c) 2020 Brett Sutton

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
```

<a id="d-8b2d593e28fc"></a>

##### D-8b2d593e28fc - MIT

Used by: proj4dart 3.0.0

```text
MIT License

Copyright (c) 2020 maRci002, Gergely Padányi-Gulyás (fegyi001)

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
```

<a id="d-51b17901817c"></a>

##### D-51b17901817c - BSD-3-Clause

Used by: qr 3.0.3

```text
Copyright 2014, the Dart QR project authors. All rights reserved.
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google Inc. nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-0e131b55dadf"></a>

##### D-0e131b55dadf - BSD-3-Clause

Used by: qr_flutter 4.1.0

```text
BSD 3-Clause License

Copyright (c) 2020, Luke Freeman.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-1ca45d4d1d0b"></a>

##### D-1ca45d4d1d0b - MIT

Used by: re_highlight 0.0.3

```text
MIT License

Copyright (c) 2024 Reqable

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
```

<a id="d-e2a2e91a609b"></a>

##### D-e2a2e91a609b - BSD-3-Clause

Used by: record 6.2.1, record_android 1.5.2, record_ios 1.2.1, record_linux 1.3.1, record_macos 1.2.2, record_platform_interface 1.6.0, record_web 1.3.0, record_windows 1.0.7

```text
// Copyright 2022 openapi4j authors. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of openapi4j nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-e3f71abe47ad"></a>

##### D-e3f71abe47ad - BSD-3-Clause

Used by: simple_sparse_list 0.1.4

```text
Copyright (c) 2024, Andrew Mezoni
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the Andrew Mezoni nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-dc238e7a9753"></a>

##### D-dc238e7a9753 - MIT

Used by: synchronized 3.4.0

```text
MIT License

Copyright (c) 2016, Alexandre Roux Tekartik.

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
```

<a id="d-d17b393b9faa"></a>

##### D-d17b393b9faa - BSD-3-Clause

Used by: term_glyph 1.2.2

```text
Copyright 2017, the Dart project authors. 

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-408284d54114"></a>

##### D-408284d54114 - BSD-3-Clause

Used by: unicode 1.1.9

```text
Copyright (c) 2014, Andrew Mezoni
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the Andrew Mezoni nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-85ac4dc571b8"></a>

##### D-85ac4dc571b8 - MIT

Used by: universal_platform 1.1.0

```text
MIT License

Copyright (c) 2019 gskinner.com

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

<a id="d-77c8bbf60d15"></a>

##### D-77c8bbf60d15 - MIT

Used by: uuid 4.6.0

```text
Copyright (c) 2021 Yulian Kuncheff

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

<a id="d-bc8b6422a461"></a>

##### D-bc8b6422a461 - BSD-3-Clause AND Zlib

Used by: vector_math 2.2.0

```text
Copyright 2015, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.

   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Copyright (C) 2013 Andrew Magill

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

<a id="d-78c350049541"></a>

##### D-78c350049541 - BSD-3-Clause

Used by: web 1.1.1

```text
Copyright 2023, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-4b526277a9e2"></a>

##### D-4b526277a9e2 - BSD-3-Clause

Used by: win32 6.4.0

```text
BSD 3-Clause License

Copyright (c) 2024, Halil Durmus

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

<a id="d-7a72e722dcaa"></a>

##### D-7a72e722dcaa - MIT

Used by: xml 6.6.1

```text
The MIT License

Copyright (c) 2006-2025 Lukas Renggli.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

<a id="d-3de266935886"></a>

##### D-3de266935886 - MIT

Used by: yaml 3.1.4

```text
Copyright (c) 2014, the Dart project authors.
Copyright (c) 2006, Kirill Simonov.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Bundled assets, prebuilt libraries and tools

These are not described by cargo or pub; the list is maintained by hand in the generator script and each entry was checked against files in the repository at generation time.

### Bundled in the app

#### libvpx 1.17.0 - VP8/VP9 video codec (WebM Project), vendored in core/third_party/libvpx

- License: BSD-3-Clause
- Platforms: all
- Attribution: Copyright (c) 2010, The WebM Project authors. Compiled from source into the Lumora core (lumora-vpx-sys) for VP8/VP9 video calls and screen sharing. Google grants a royalty-free patent license for VP8/VP9 (core/third_party/libvpx/PATENTS, reproduced in the next entry).

<details><summary>License text</summary>

```text
Copyright (c) 2010, The WebM Project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google, nor the WebM Project, nor the names
    of its contributors may be used to endorse or promote products
    derived from this software without specific prior written
    permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

</details>

#### x86inc.asm (x264 project), part of the libvpx x86 assembly

- License: ISC
- Platforms: Windows, Linux, macOS (x86_64), Android (x86_64)
- Attribution: Copyright (C) 2005-2012 x264 project. Assembler macros used to build libvpx's x86 SIMD code (NASM).

<details><summary>License text</summary>

```text
Copyright (C) 2005-2012 x264 project

Authors: Loren Merritt <lorenm@u.washington.edu>
         Anton Mitrofanov <BugMaster@narod.ru>
         Jason Garrett-Glaser <darkshikari@gmail.com>
         Henrik Gramner <hengar-6@student.ltu.se>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

</details>

#### libvpx additional IP rights grant (patents)

- License: LicenseRef-WebM-Patent-Grant
- Platforms: all
- Attribution: Google's royalty-free patent license for its VP8/VP9 implementation (no attribution required; reproduced for completeness).

<details><summary>License text</summary>

```text
Additional IP Rights Grant (Patents)
------------------------------------

"These implementations" means the copyrightable works that implement the WebM
codecs distributed by Google as part of the WebM Project.

Google hereby grants to you a perpetual, worldwide, non-exclusive, no-charge,
royalty-free, irrevocable (except as stated in this section) patent license to
make, have made, use, offer to sell, sell, import, transfer, and otherwise
run, modify and propagate the contents of these implementations of WebM, where
such license applies only to those patent claims, both currently owned by
Google and acquired in the future, licensable by Google that are necessarily
infringed by these implementations of WebM. This grant does not include claims
that would be infringed only as a consequence of further modification of these
implementations. If you or your agent or exclusive licensee institute or order
or agree to the institution of patent litigation or any other patent
enforcement activity against any entity (including a cross-claim or
counterclaim in a lawsuit) alleging that any of these implementations of WebM
or any code incorporated within any of these implementations of WebM
constitute direct or contributory patent infringement, or inducement of
patent infringement, then any patent rights granted to you under this License
for these implementations of WebM shall terminate as of the date such
litigation is filed.
```

</details>

#### Noto Animated Emoji (about 120 Lottie animations, modified)

- License: CC-BY-4.0
- Platforms: all
- Attribution: Animated emoji: Noto Animated Emoji, copyright Google LLC. https://googlefonts.github.io/noto-emoji-animation/ - licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/legalcode). Changes: a selection of about 120 animations, re-encoded (numbers rounded to 3 decimals, minified, gzip-compressed). The same attribution is shown in the app (Settings > About > Open-source licenses).
- License text: see CC-BY-4.0 under "License texts".

#### Noto Color Emoji font (COLRv1)

- License: OFL-1.1
- Platforms: Windows, Linux
- Attribution: Copyright 2013 Google LLC. https://github.com/googlefonts/noto-emoji
- License text: see OFL-1.1 under "License texts".

#### Be Vietnam Pro font

- License: OFL-1.1
- Platforms: all
- Attribution: Copyright 2021 The Be Vietnam Pro Project Authors (https://github.com/bettergui/BeVietnamPro)

<details><summary>License text</summary>

```text
Copyright 2021 The Be Vietnam Pro Project Authors (https://github.com/bettergui/BeVietnamPro),

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

</details>

#### Phosphor Icons (icon fonts via phosphor_flutter)

- License: MIT
- Platforms: all
- Attribution: Copyright (c) 2020-2021 Phosphor Icons. https://phosphoricons.com

<details><summary>License text</summary>

```text
MIT License

Copyright (c) 2020-2021 Phosphor Icons

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
```

</details>

#### Material Icons font (Flutter SDK, tree-shaken)

- License: CC-BY-4.0
- Platforms: all
- Attribution: Material Icons, copyright Google LLC (license text as shipped in the Flutter SDK).
- License text: see CC-BY-4.0 under "License texts".

#### Unicode emoji data (emoji-test.txt, Emoji 15.1) and Unicode CLDR 45 annotations

- License: Unicode-3.0
- Platforms: all
- Attribution: Copyright (c) Unicode, Inc. Unicode License v3, https://www.unicode.org/license.txt
- License text: see Unicode-3.0 under "License texts".

#### emojibase-data 15.3 (English emoji keywords and shortcodes)

- License: MIT
- Platforms: all
- Attribution: Copyright (c) Miles Johnson. https://github.com/milesj/emojibase
- License text: see MIT under "License texts".

#### BIP-39 English word list (recovery phrase)

- License: NOASSERTION
- Platforms: all
- Attribution: From https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt
- **Review:** The BIP-39 document carries no explicit license header in the bitcoin/bips repository (a list of common English words is probably not copyrightable). Owner/lawyer to confirm; credit the source anyway.

#### Demo/mock assets (photos assets/mock/*.jpg, sample files assets/mock/files/*)

- License: NOASSERTION
- Platforms: all
- **Review:** These files are listed in pubspec.yaml and therefore ship inside every build. Their origin/license is not recorded in the repo. Either confirm they were created by the owner (or are licensed for redistribution), or drop them from release builds.

### Prebuilt runtime libraries shipped with the app

#### libva (VA-API, Intel) - system library loaded at run time on Linux if present

- License: MIT
- Platforms: Linux
- Attribution: Not shipped: libva.so.2 / libva-drm.so.2 of the user's system are opened with dlopen for hardware H.264 on Intel/AMD GPUs. The type definitions in vaapi_sys.rs are generated from the libva headers, Copyright (c) 2007-2018 Intel Corporation, MIT.
- License text: see MIT under "License texts".

#### PDFium (prebuilt by pdfium-binaries / pdfium-xcframework, downloaded by pdfium_flutter at build time) (chromium/7520)

- License: BSD-3-Clause AND Apache-2.0
- Platforms: all
- Attribution: Copyright 2014 The PDFium Authors. https://pdfium.googlesource.com/pdfium/ ; binaries from https://github.com/bblanchon/pdfium-binaries (Windows, Linux, Android) and https://github.com/espresso3389/pdfium-xcframework (Apple).
- **Review:** The PDFium binary also contains third-party libraries (for example FreeType, libjpeg-turbo, libpng, zlib, Little CMS, OpenJPEG) under their own licenses. The pdfium-binaries archive ships a LICENSE file / licenses folder with all of them: copy that text into the release (e.g. append it here) - this script cannot see it because the archive is only downloaded during `flutter build`. FreeType's FTL requires a credit line in the documentation. pdfrx's pdfium.wasm (web only) is removed in CI by `dart run pdfrx:remove_wasm_modules`.

#### LLVM libc++ (libc++_shared.so from the Android NDK)

- License: Apache-2.0 WITH LLVM-exception
- Platforms: Android
- Attribution: Copyright (c) LLVM Project contributors. https://llvm.org/LICENSE.txt

<details><summary>License text</summary>

```text
==============================================================================
The LLVM Project is under the Apache License v2.0 with LLVM Exceptions:
==============================================================================

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

    TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

    1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

    2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

    3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

    4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

    5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

    6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

    7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

    8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

    9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

    END OF TERMS AND CONDITIONS

    APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

    Copyright [yyyy] [name of copyright owner]

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.


---- LLVM Exceptions to the Apache 2.0 License ----

As an exception, if, as a result of your compiling your source code, portions
of this Software are embedded into an Object form of such source code, you
may redistribute such embedded portions in such Object form without complying
with the conditions of Sections 4(a), 4(b) and 4(d) of the License.

In addition, if you combine or link compiled forms of this Software with
software that is licensed under the GPLv2 ("Combined Software") and if a
court of competent jurisdiction determines that the patent provision (Section
3), the indemnity provision (Section 9) or other Section of the License
conflicts with the conditions of the GPLv2, you may retroactively and
prospectively choose to deem waived or otherwise exclude such Section(s) of
the License, but only in their entirety and only with respect to the Combined
Software.
```

</details>

#### AndroidX, Jetpack Media3 (ExoPlayer), Kotlin standard library (pulled in by Flutter plugins through Gradle)

- License: Apache-2.0
- Platforms: Android
- Attribution: Copyright The Android Open Source Project / JetBrains s.r.o. and contributors.
- License text: see Apache-2.0 under "License texts".

#### Google Play services Location (com.google.android.gms:play-services-location, via geolocator_android)

- License: LicenseRef-Google-Android-SDK
- Platforms: Android
- Attribution: Copyright Google LLC. Proprietary; distributed under the Android Software Development Kit License Agreement / Google APIs Terms of Service.
- **Review:** Proprietary Google component inside the APK (not open source). Allowed for apps, but its terms are Google's, and it is unavailable on de-Googled devices. Its own notices can be generated with the oss-licenses Gradle plugin.

#### Microsoft Visual C++ runtime DLLs (msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll)

- License: LicenseRef-Microsoft-VC-Redist
- Platforms: Windows
- Attribution: Copyright Microsoft Corporation. Redistributed as 'Distributable Code' under the Microsoft Visual Studio license terms.
- **Review:** App-local deployment is allowed only for holders of a Visual Studio license that grants distributable-code rights, and Microsoft asks that the files be taken from the Visual Studio redist folder (VC\Redist\MSVC\<ver>\x64\Microsoft.VC143.CRT), not copied from System32 as packaging/windows/README.md currently does.

### Installer tooling

#### Inno Setup (installer engine / setup stub inside the Windows installer .exe)

- License: LicenseRef-InnoSetup
- Platforms: Windows installer
- Attribution: Copyright (C) 1997-2025 Jordan Russell, Martijn Laan. https://jrsoftware.org/isinfo.php
- **Review:** The setup stub compiled into the installer is Inno Setup code. Check the CURRENT Inno Setup license (https://jrsoftware.org/files/is/license.txt): recent releases changed the terms for commercial use - confirm a freeware release qualifies or buy a commercial license; keep its copyright notice in the installer.

### Online services used at runtime (nothing bundled)

#### OpenStreetMap map tiles (location messages)

- License: ODbL-1.0 (data) / tile usage policy
- Platforms: all
- Attribution: (c) OpenStreetMap contributors - shown in the map widget. Tiles are fetched at runtime from tile.openstreetmap.org, nothing is bundled.
- **Review:** The OSM Foundation tile usage policy forbids heavy use without permission and requires a valid User-Agent; consider a commercial tile provider for a public release. Also mentioned in the EULA privacy section.

### Linked but not distributed

#### System libraries linked dynamically on Linux and NOT shipped: PipeWire (MIT), ALSA libasound (LGPL-2.1-or-later), libdbus (AFL-2.1 OR GPL-2.0-or-later), GTK 3 / GLib (LGPL-2.1-or-later, Flutter Linux embedder), X11/xcb libraries (MIT)

- License: various (not distributed)
- Platforms: Linux
- Attribution: Provided by the user's Linux distribution. If they are ever bundled (AppImage, Flatpak runtime excluded), the LGPL ones must stay dynamically linked and replaceable, with their license texts and source offer included.

## License texts

One copy of each license text. Copyright lines were removed from these canonical copies; each component's own copyright notice is listed in the tables above.

### Apache-2.0

```text
                              Apache License
                        Version 2.0, January 2004
                     http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

   "License" shall mean the terms and conditions for use, reproduction,
   and distribution as defined by Sections 1 through 9 of this document.

   "Licensor" shall mean the copyright owner or entity authorized by
   the copyright owner that is granting the License.

   "Legal Entity" shall mean the union of the acting entity and all
   other entities that control, are controlled by, or are under common
   control with that entity. For the purposes of this definition,
   "control" means (i) the power, direct or indirect, to cause the
   direction or management of such entity, whether by contract or
   otherwise, or (ii) ownership of fifty percent (50%) or more of the
   outstanding shares, or (iii) beneficial ownership of such entity.

   "You" (or "Your") shall mean an individual or Legal Entity
   exercising permissions granted by this License.

   "Source" form shall mean the preferred form for making modifications,
   including but not limited to software source code, documentation
   source, and configuration files.

   "Object" form shall mean any form resulting from mechanical
   transformation or translation of a Source form, including but
   not limited to compiled object code, generated documentation,
   and conversions to other media types.

   "Work" shall mean the work of authorship, whether in Source or
   Object form, made available under the License, as indicated by a
   copyright notice that is included in or attached to the work
   (an example is provided in the Appendix below).

   "Derivative Works" shall mean any work, whether in Source or Object
   form, that is based on (or derived from) the Work and for which the
   editorial revisions, annotations, elaborations, or other modifications
   represent, as a whole, an original work of authorship. For the purposes
   of this License, Derivative Works shall not include works that remain
   separable from, or merely link (or bind by name) to the interfaces of,
   the Work and Derivative Works thereof.

   "Contribution" shall mean any work of authorship, including
   the original version of the Work and any modifications or additions
   to that Work or Derivative Works thereof, that is intentionally
   submitted to Licensor for inclusion in the Work by the copyright owner
   or by an individual or Legal Entity authorized to submit on behalf of
   the copyright owner. For the purposes of this definition, "submitted"
   means any form of electronic, verbal, or written communication sent
   to the Licensor or its representatives, including but not limited to
   communication on electronic mailing lists, source code control systems,
   and issue tracking systems that are managed by, or on behalf of, the
   Licensor for the purpose of discussing and improving the Work, but
   excluding communication that is conspicuously marked or otherwise
   designated in writing by the copyright owner as "Not a Contribution."

   "Contributor" shall mean Licensor and any individual or Legal Entity
   on behalf of whom a Contribution has been received by Licensor and
   subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of
   this License, each Contributor hereby grants to You a perpetual,
   worldwide, non-exclusive, no-charge, royalty-free, irrevocable
   copyright license to reproduce, prepare Derivative Works of,
   publicly display, publicly perform, sublicense, and distribute the
   Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of
   this License, each Contributor hereby grants to You a perpetual,
   worldwide, non-exclusive, no-charge, royalty-free, irrevocable
   (except as stated in this section) patent license to make, have made,
   use, offer to sell, sell, import, and otherwise transfer the Work,
   where such license applies only to those patent claims licensable
   by such Contributor that are necessarily infringed by their
   Contribution(s) alone or by combination of their Contribution(s)
   with the Work to which such Contribution(s) was submitted. If You
   institute patent litigation against any entity (including a
   cross-claim or counterclaim in a lawsuit) alleging that the Work
   or a Contribution incorporated within the Work constitutes direct
   or contributory patent infringement, then any patent licenses
   granted to You under this License for that Work shall terminate
   as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the
   Work or Derivative Works thereof in any medium, with or without
   modifications, and in Source or Object form, provided that You
   meet the following conditions:

   (a) You must give any other recipients of the Work or
       Derivative Works a copy of this License; and

   (b) You must cause any modified files to carry prominent notices
       stating that You changed the files; and

       that You distribute, all copyright, patent, trademark, and
       attribution notices from the Source form of the Work,
       excluding those notices that do not pertain to any part of
       the Derivative Works; and

   (d) If the Work includes a "NOTICE" text file as part of its
       distribution, then any Derivative Works that You distribute must
       include a readable copy of the attribution notices contained
       within such NOTICE file, excluding those notices that do not
       pertain to any part of the Derivative Works, in at least one
       of the following places: within a NOTICE text file distributed
       as part of the Derivative Works; within the Source form or
       documentation, if provided along with the Derivative Works; or,
       within a display generated by the Derivative Works, if and
       wherever such third-party notices normally appear. The contents
       of the NOTICE file are for informational purposes only and
       do not modify the License. You may add Your own attribution
       notices within Derivative Works that You distribute, alongside
       or as an addendum to the NOTICE text from the Work, provided
       that such additional attribution notices cannot be construed
       as modifying the License.

   You may add Your own copyright statement to Your modifications and
   may provide additional or different license terms and conditions
   for use, reproduction, or distribution of Your modifications, or
   for any such Derivative Works as a whole, provided Your use,
   reproduction, and distribution of the Work otherwise complies with
   the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise,
   any Contribution intentionally submitted for inclusion in the Work
   by You to the Licensor shall be under the terms and conditions of
   this License, without any additional terms or conditions.
   Notwithstanding the above, nothing herein shall supersede or modify
   the terms of any separate license agreement you may have executed
   with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade
   names, trademarks, service marks, or product names of the Licensor,
   except as required for reasonable and customary use in describing the
   origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or
   agreed to in writing, Licensor provides the Work (and each
   Contributor provides its Contributions) on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied, including, without limitation, any warranties or conditions
   of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
   PARTICULAR PURPOSE. You are solely responsible for determining the
   appropriateness of using or redistributing the Work and assume any
   risks associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory,
   whether in tort (including negligence), contract, or otherwise,
   unless required by applicable law (such as deliberate and grossly
   negligent acts) or agreed to in writing, shall any Contributor be
   liable to You for damages, including any direct, indirect, special,
   incidental, or consequential damages of any character arising as a
   result of this License or out of the use or inability to use the
   Work (including but not limited to damages for loss of goodwill,
   work stoppage, computer failure or malfunction, or any and all
   other commercial damages or losses), even if such Contributor
   has been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing
   the Work or Derivative Works thereof, You may choose to offer,
   and charge a fee for, acceptance of support, warranty, indemnity,
   or other liability obligations and/or rights consistent with this
   License. However, in accepting such obligations, You may act only
   on Your own behalf and on Your sole responsibility, not on behalf
   of any other Contributor, and only if You agree to indemnify,
   defend, and hold each Contributor harmless for any liability
   incurred by, or claims asserted against, such Contributor by reason
   of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

APPENDIX: How to apply the Apache License to your work.

   To apply the Apache License to your work, attach the following
   boilerplate notice, with the fields enclosed by brackets "[]"
   replaced with your own identifying information. (Don't include
   the brackets!)  The text should be enclosed in the appropriate
   comment syntax for the file format. We also recommend that a
   file or class name and description of purpose be included on the
   same "printed page" as the copyright notice for easier
   identification within third-party archives.

Copyright [yyyy] [name of copyright owner]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

### BSD-2-Clause

```text
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### BSD-3-Clause

```text
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
```

### CC-BY-4.0

```text
Attribution 4.0 International

=======================================================================

Creative Commons Corporation ("Creative Commons") is not a law firm and
does not provide legal services or legal advice. Distribution of
Creative Commons public licenses does not create a lawyer-client or
other relationship. Creative Commons makes its licenses and related
information available on an "as-is" basis. Creative Commons gives no
warranties regarding its licenses, any material licensed under their
terms and conditions, or any related information. Creative Commons
disclaims all liability for damages resulting from their use to the
fullest extent possible.

Using Creative Commons Public Licenses

Creative Commons public licenses provide a standard set of terms and
conditions that creators and other rights holders may use to share
original works of authorship and other material subject to copyright
and certain other rights specified in the public license below. The
following considerations are for informational purposes only, are not
exhaustive, and do not form part of our licenses.

     Considerations for licensors: Our public licenses are
     intended for use by those authorized to give the public
     permission to use material in ways otherwise restricted by
     copyright and certain other rights. Our licenses are
     irrevocable. Licensors should read and understand the terms
     and conditions of the license they choose before applying it.
     Licensors should also secure all rights necessary before
     applying our licenses so that the public can reuse the
     material as expected. Licensors should clearly mark any
     material not subject to the license. This includes other CC-
     licensed material, or material used under an exception or
     limitation to copyright. More considerations for licensors:
     wiki.creativecommons.org/Considerations_for_licensors

     Considerations for the public: By using one of our public
     licenses, a licensor grants the public permission to use the
     licensed material under specified terms and conditions. If
     the licensor's permission is not necessary for any reason--for
     example, because of any applicable exception or limitation to
     copyright--then that use is not regulated by the license. Our
     licenses grant only permissions under copyright and certain
     other rights that a licensor has authority to grant. Use of
     the licensed material may still be restricted for other
     reasons, including because others have copyright or other
     rights in the material. A licensor may make special requests,
     such as asking that all changes be marked or described.
     Although not required by our licenses, you are encouraged to
     respect those requests where reasonable. More_considerations
     for the public:
     wiki.creativecommons.org/Considerations_for_licensees

=======================================================================

Creative Commons Attribution 4.0 International Public License

By exercising the Licensed Rights (defined below), You accept and agree
to be bound by the terms and conditions of this Creative Commons
Attribution 4.0 International Public License ("Public License"). To the
extent this Public License may be interpreted as a contract, You are
granted the Licensed Rights in consideration of Your acceptance of
these terms and conditions, and the Licensor grants You such rights in
consideration of benefits the Licensor receives from making the
Licensed Material available under these terms and conditions.


Section 1 -- Definitions.

  a. Adapted Material means material subject to Copyright and Similar
     Rights that is derived from or based upon the Licensed Material
     and in which the Licensed Material is translated, altered,
     arranged, transformed, or otherwise modified in a manner requiring
     permission under the Copyright and Similar Rights held by the
     Licensor. For purposes of this Public License, where the Licensed
     Material is a musical work, performance, or sound recording,
     Adapted Material is always produced where the Licensed Material is
     synched in timed relation with a moving image.

  b. Adapter's License means the license You apply to Your Copyright
     and Similar Rights in Your contributions to Adapted Material in
     accordance with the terms and conditions of this Public License.

  c. Copyright and Similar Rights means copyright and/or similar rights
     closely related to copyright including, without limitation,
     performance, broadcast, sound recording, and Sui Generis Database
     Rights, without regard to how the rights are labeled or
     categorized. For purposes of this Public License, the rights
     specified in Section 2(b)(1)-(2) are not Copyright and Similar
     Rights.

  d. Effective Technological Measures means those measures that, in the
     absence of proper authority, may not be circumvented under laws
     fulfilling obligations under Article 11 of the WIPO Copyright
     Treaty adopted on December 20, 1996, and/or similar international
     agreements.

  e. Exceptions and Limitations means fair use, fair dealing, and/or
     any other exception or limitation to Copyright and Similar Rights
     that applies to Your use of the Licensed Material.

  f. Licensed Material means the artistic or literary work, database,
     or other material to which the Licensor applied this Public
     License.

  g. Licensed Rights means the rights granted to You subject to the
     terms and conditions of this Public License, which are limited to
     all Copyright and Similar Rights that apply to Your use of the
     Licensed Material and that the Licensor has authority to license.

  h. Licensor means the individual(s) or entity(ies) granting rights
     under this Public License.

  i. Share means to provide material to the public by any means or
     process that requires permission under the Licensed Rights, such
     as reproduction, public display, public performance, distribution,
     dissemination, communication, or importation, and to make material
     available to the public including in ways that members of the
     public may access the material from a place and at a time
     individually chosen by them.

  j. Sui Generis Database Rights means rights other than copyright
     resulting from Directive 96/9/EC of the European Parliament and of
     the Council of 11 March 1996 on the legal protection of databases,
     as amended and/or succeeded, as well as other essentially
     equivalent rights anywhere in the world.

  k. You means the individual or entity exercising the Licensed Rights
     under this Public License. Your has a corresponding meaning.


Section 2 -- Scope.

  a. License grant.

       1. Subject to the terms and conditions of this Public License,
          the Licensor hereby grants You a worldwide, royalty-free,
          non-sublicensable, non-exclusive, irrevocable license to
          exercise the Licensed Rights in the Licensed Material to:

            a. reproduce and Share the Licensed Material, in whole or
               in part; and

            b. produce, reproduce, and Share Adapted Material.

       2. Exceptions and Limitations. For the avoidance of doubt, where
          Exceptions and Limitations apply to Your use, this Public
          License does not apply, and You do not need to comply with
          its terms and conditions.

       3. Term. The term of this Public License is specified in Section
          6(a).

       4. Media and formats; technical modifications allowed. The
          Licensor authorizes You to exercise the Licensed Rights in
          all media and formats whether now known or hereafter created,
          and to make technical modifications necessary to do so. The
          Licensor waives and/or agrees not to assert any right or
          authority to forbid You from making technical modifications
          necessary to exercise the Licensed Rights, including
          technical modifications necessary to circumvent Effective
          Technological Measures. For purposes of this Public License,
          simply making modifications authorized by this Section 2(a)
          (4) never produces Adapted Material.

       5. Downstream recipients.

            a. Offer from the Licensor -- Licensed Material. Every
               recipient of the Licensed Material automatically
               receives an offer from the Licensor to exercise the
               Licensed Rights under the terms and conditions of this
               Public License.

            b. No downstream restrictions. You may not offer or impose
               any additional or different terms or conditions on, or
               apply any Effective Technological Measures to, the
               Licensed Material if doing so restricts exercise of the
               Licensed Rights by any recipient of the Licensed
               Material.

       6. No endorsement. Nothing in this Public License constitutes or
          may be construed as permission to assert or imply that You
          are, or that Your use of the Licensed Material is, connected
          with, or sponsored, endorsed, or granted official status by,
          the Licensor or others designated to receive attribution as
          provided in Section 3(a)(1)(A)(i).

  b. Other rights.

       1. Moral rights, such as the right of integrity, are not
          licensed under this Public License, nor are publicity,
          privacy, and/or other similar personality rights; however, to
          the extent possible, the Licensor waives and/or agrees not to
          assert any such rights held by the Licensor to the limited
          extent necessary to allow You to exercise the Licensed
          Rights, but not otherwise.

       2. Patent and trademark rights are not licensed under this
          Public License.

       3. To the extent possible, the Licensor waives any right to
          collect royalties from You for the exercise of the Licensed
          Rights, whether directly or through a collecting society
          under any voluntary or waivable statutory or compulsory
          licensing scheme. In all other cases the Licensor expressly
          reserves any right to collect such royalties.


Section 3 -- License Conditions.

Your exercise of the Licensed Rights is expressly made subject to the
following conditions.

  a. Attribution.

       1. If You Share the Licensed Material (including in modified
          form), You must:

            a. retain the following if it is supplied by the Licensor
               with the Licensed Material:

                 i. identification of the creator(s) of the Licensed
                    Material and any others designated to receive
                    attribution, in any reasonable manner requested by
                    the Licensor (including by pseudonym if
                    designated);

                ii. a copyright notice;

               iii. a notice that refers to this Public License;

                iv. a notice that refers to the disclaimer of
                    warranties;

                 v. a URI or hyperlink to the Licensed Material to the
                    extent reasonably practicable;

            b. indicate if You modified the Licensed Material and
               retain an indication of any previous modifications; and

            c. indicate the Licensed Material is licensed under this
               Public License, and include the text of, or the URI or
               hyperlink to, this Public License.

       2. You may satisfy the conditions in Section 3(a)(1) in any
          reasonable manner based on the medium, means, and context in
          which You Share the Licensed Material. For example, it may be
          reasonable to satisfy the conditions by providing a URI or
          hyperlink to a resource that includes the required
          information.

       3. If requested by the Licensor, You must remove any of the
          information required by Section 3(a)(1)(A) to the extent
          reasonably practicable.

       4. If You Share Adapted Material You produce, the Adapter's
          License You apply must not prevent recipients of the Adapted
          Material from complying with this Public License.


Section 4 -- Sui Generis Database Rights.

Where the Licensed Rights include Sui Generis Database Rights that
apply to Your use of the Licensed Material:

  a. for the avoidance of doubt, Section 2(a)(1) grants You the right
     to extract, reuse, reproduce, and Share all or a substantial
     portion of the contents of the database;

  b. if You include all or a substantial portion of the database
     contents in a database in which You have Sui Generis Database
     Rights, then the database in which You have Sui Generis Database
     Rights (but not its individual contents) is Adapted Material; and

  c. You must comply with the conditions in Section 3(a) if You Share
     all or a substantial portion of the contents of the database.

For the avoidance of doubt, this Section 4 supplements and does not
replace Your obligations under this Public License where the Licensed
Rights include other Copyright and Similar Rights.


Section 5 -- Disclaimer of Warranties and Limitation of Liability.

  a. UNLESS OTHERWISE SEPARATELY UNDERTAKEN BY THE LICENSOR, TO THE
     EXTENT POSSIBLE, THE LICENSOR OFFERS THE LICENSED MATERIAL AS-IS
     AND AS-AVAILABLE, AND MAKES NO REPRESENTATIONS OR WARRANTIES OF
     ANY KIND CONCERNING THE LICENSED MATERIAL, WHETHER EXPRESS,
     IMPLIED, STATUTORY, OR OTHER. THIS INCLUDES, WITHOUT LIMITATION,
     WARRANTIES OF TITLE, MERCHANTABILITY, FITNESS FOR A PARTICULAR
     PURPOSE, NON-INFRINGEMENT, ABSENCE OF LATENT OR OTHER DEFECTS,
     ACCURACY, OR THE PRESENCE OR ABSENCE OF ERRORS, WHETHER OR NOT
     KNOWN OR DISCOVERABLE. WHERE DISCLAIMERS OF WARRANTIES ARE NOT
     ALLOWED IN FULL OR IN PART, THIS DISCLAIMER MAY NOT APPLY TO YOU.

  b. TO THE EXTENT POSSIBLE, IN NO EVENT WILL THE LICENSOR BE LIABLE
     TO YOU ON ANY LEGAL THEORY (INCLUDING, WITHOUT LIMITATION,
     NEGLIGENCE) OR OTHERWISE FOR ANY DIRECT, SPECIAL, INDIRECT,
     INCIDENTAL, CONSEQUENTIAL, PUNITIVE, EXEMPLARY, OR OTHER LOSSES,
     COSTS, EXPENSES, OR DAMAGES ARISING OUT OF THIS PUBLIC LICENSE OR
     USE OF THE LICENSED MATERIAL, EVEN IF THE LICENSOR HAS BEEN
     ADVISED OF THE POSSIBILITY OF SUCH LOSSES, COSTS, EXPENSES, OR
     DAMAGES. WHERE A LIMITATION OF LIABILITY IS NOT ALLOWED IN FULL OR
     IN PART, THIS LIMITATION MAY NOT APPLY TO YOU.

  c. The disclaimer of warranties and limitation of liability provided
     above shall be interpreted in a manner that, to the extent
     possible, most closely approximates an absolute disclaimer and
     waiver of all liability.


Section 6 -- Term and Termination.

  a. This Public License applies for the term of the Copyright and
     Similar Rights licensed here. However, if You fail to comply with
     this Public License, then Your rights under this Public License
     terminate automatically.

  b. Where Your right to use the Licensed Material has terminated under
     Section 6(a), it reinstates:

       1. automatically as of the date the violation is cured, provided
          it is cured within 30 days of Your discovery of the
          violation; or

       2. upon express reinstatement by the Licensor.

     For the avoidance of doubt, this Section 6(b) does not affect any
     right the Licensor may have to seek remedies for Your violations
     of this Public License.

  c. For the avoidance of doubt, the Licensor may also offer the
     Licensed Material under separate terms or conditions or stop
     distributing the Licensed Material at any time; however, doing so
     will not terminate this Public License.

  d. Sections 1, 5, 6, 7, and 8 survive termination of this Public
     License.


Section 7 -- Other Terms and Conditions.

  a. The Licensor shall not be bound by any additional or different
     terms or conditions communicated by You unless expressly agreed.

  b. Any arrangements, understandings, or agreements regarding the
     Licensed Material not stated herein are separate from and
     independent of the terms and conditions of this Public License.


Section 8 -- Interpretation.

  a. For the avoidance of doubt, this Public License does not, and
     shall not be interpreted to, reduce, limit, restrict, or impose
     conditions on any use of the Licensed Material that could lawfully
     be made without permission under this Public License.

  b. To the extent possible, if any provision of this Public License is
     deemed unenforceable, it shall be automatically reformed to the
     minimum extent necessary to make it enforceable. If the provision
     cannot be reformed, it shall be severed from this Public License
     without affecting the enforceability of the remaining terms and
     conditions.

  c. No term or condition of this Public License will be waived and no
     failure to comply consented to unless expressly agreed to by the
     Licensor.

  d. Nothing in this Public License constitutes or may be interpreted
     as a limitation upon, or waiver of, any privileges and immunities
     that apply to the Licensor or You, including from the legal
     processes of any jurisdiction or authority.


=======================================================================

Creative Commons is not a party to its public licenses.
Notwithstanding, Creative Commons may elect to apply one of its public
licenses to material it publishes and in those instances will be
considered the "Licensor." Except for the limited purpose of indicating
that material is shared under a Creative Commons public license or as
otherwise permitted by the Creative Commons policies published at
creativecommons.org/policies, Creative Commons does not authorize the
use of the trademark "Creative Commons" or any other trademark or logo
of Creative Commons without its prior written consent including,
without limitation, in connection with any unauthorized modifications
to any of its public licenses or any other arrangements,
understandings, or agreements concerning use of licensed material. For
the avoidance of doubt, this paragraph does not form part of the public
licenses.

Creative Commons may be contacted at creativecommons.org.
```

### CC0-1.0

```text
Creative Commons Legal Code

CC0 1.0 Universal

    CREATIVE COMMONS CORPORATION IS NOT A LAW FIRM AND DOES NOT PROVIDE
    LEGAL SERVICES. DISTRIBUTION OF THIS DOCUMENT DOES NOT CREATE AN
    ATTORNEY-CLIENT RELATIONSHIP. CREATIVE COMMONS PROVIDES THIS
    INFORMATION ON AN "AS-IS" BASIS. CREATIVE COMMONS MAKES NO WARRANTIES
    REGARDING THE USE OF THIS DOCUMENT OR THE INFORMATION OR WORKS
    PROVIDED HEREUNDER, AND DISCLAIMS LIABILITY FOR DAMAGES RESULTING FROM
    THE USE OF THIS DOCUMENT OR THE INFORMATION OR WORKS PROVIDED
    HEREUNDER.

Statement of Purpose

The laws of most jurisdictions throughout the world automatically confer
exclusive Copyright and Related Rights (defined below) upon the creator
and subsequent owner(s) (each and all, an "owner") of an original work of
authorship and/or a database (each, a "Work").

Certain owners wish to permanently relinquish those rights to a Work for
the purpose of contributing to a commons of creative, cultural and
scientific works ("Commons") that the public can reliably and without fear
of later claims of infringement build upon, modify, incorporate in other
works, reuse and redistribute as freely as possible in any form whatsoever
and for any purposes, including without limitation commercial purposes.
These owners may contribute to the Commons to promote the ideal of a free
culture and the further production of creative, cultural and scientific
works, or to gain reputation or greater distribution for their Work in
part through the use and efforts of others.

For these and/or other purposes and motivations, and without any
expectation of additional consideration or compensation, the person
associating CC0 with a Work (the "Affirmer"), to the extent that he or she
is an owner of Copyright and Related Rights in the Work, voluntarily
elects to apply CC0 to the Work and publicly distribute the Work under its
terms, with knowledge of his or her Copyright and Related Rights in the
Work and the meaning and intended legal effect of CC0 on those rights.

1. Copyright and Related Rights. A Work made available under CC0 may be
protected by copyright and related or neighboring rights ("Copyright and
Related Rights"). Copyright and Related Rights include, but are not
limited to, the following:

  i. the right to reproduce, adapt, distribute, perform, display,
     communicate, and translate a Work;
 ii. moral rights retained by the original author(s) and/or performer(s);
iii. publicity and privacy rights pertaining to a person's image or
     likeness depicted in a Work;
 iv. rights protecting against unfair competition in regards to a Work,
     subject to the limitations in paragraph 4(a), below;
  v. rights protecting the extraction, dissemination, use and reuse of data
     in a Work;
 vi. database rights (such as those arising under Directive 96/9/EC of the
     European Parliament and of the Council of 11 March 1996 on the legal
     protection of databases, and under any national implementation
     thereof, including any amended or successor version of such
     directive); and
vii. other similar, equivalent or corresponding rights throughout the
     world based on applicable law or treaty, and any national
     implementations thereof.

2. Waiver. To the greatest extent permitted by, but not in contravention
of, applicable law, Affirmer hereby overtly, fully, permanently,
irrevocably and unconditionally waives, abandons, and surrenders all of
Affirmer's Copyright and Related Rights and associated claims and causes
of action, whether now known or unknown (including existing as well as
future claims and causes of action), in the Work (i) in all territories
worldwide, (ii) for the maximum duration provided by applicable law or
treaty (including future time extensions), (iii) in any current or future
medium and for any number of copies, and (iv) for any purpose whatsoever,
including without limitation commercial, advertising or promotional
purposes (the "Waiver"). Affirmer makes the Waiver for the benefit of each
member of the public at large and to the detriment of Affirmer's heirs and
successors, fully intending that such Waiver shall not be subject to
revocation, rescission, cancellation, termination, or any other legal or
equitable action to disrupt the quiet enjoyment of the Work by the public
as contemplated by Affirmer's express Statement of Purpose.

3. Public License Fallback. Should any part of the Waiver for any reason
be judged legally invalid or ineffective under applicable law, then the
Waiver shall be preserved to the maximum extent permitted taking into
account Affirmer's express Statement of Purpose. In addition, to the
extent the Waiver is so judged Affirmer hereby grants to each affected
person a royalty-free, non transferable, non sublicensable, non exclusive,
irrevocable and unconditional license to exercise Affirmer's Copyright and
Related Rights in the Work (i) in all territories worldwide, (ii) for the
maximum duration provided by applicable law or treaty (including future
time extensions), (iii) in any current or future medium and for any number
of copies, and (iv) for any purpose whatsoever, including without
limitation commercial, advertising or promotional purposes (the
"License"). The License shall be deemed effective as of the date CC0 was
applied by Affirmer to the Work. Should any part of the License for any
reason be judged legally invalid or ineffective under applicable law, such
partial invalidity or ineffectiveness shall not invalidate the remainder
of the License, and in such case Affirmer hereby affirms that he or she
will not (i) exercise any of his or her remaining Copyright and Related
Rights in the Work or (ii) assert any associated claims and causes of
action with respect to the Work, in either case contrary to Affirmer's
express Statement of Purpose.

4. Limitations and Disclaimers.

 a. No trademark or patent rights held by Affirmer are waived, abandoned,
    surrendered, licensed or otherwise affected by this document.
 b. Affirmer offers the Work as-is and makes no representations or
    warranties of any kind concerning the Work, express, implied,
    statutory or otherwise, including without limitation warranties of
    title, merchantability, fitness for a particular purpose, non
    infringement, or the absence of latent or other defects, accuracy, or
    the present or absence of errors, whether or not discoverable, all to
    the greatest extent permissible under applicable law.
 c. Affirmer disclaims responsibility for clearing rights of other persons
    that may apply to the Work or any use thereof, including without
    limitation any person's Copyright and Related Rights in the Work.
    Further, Affirmer disclaims responsibility for obtaining any necessary
    consents, permissions or other rights required for any use of the
    Work.
 d. Affirmer understands and acknowledges that Creative Commons is not a
    party to this document and has no duty or obligation with respect to
    this CC0 or use of the Work.
```

### CDLA-Permissive-2.0

```text
# Community Data License Agreement - Permissive - Version 2.0

This is the Community Data License Agreement - Permissive, Version
2.0 (the "agreement"). Data Provider(s) and Data Recipient(s) agree
as follows:

## 1. Provision of the Data

1.1. A Data Recipient may use, modify, and share the Data made
available by Data Provider(s) under this agreement if that Data
Recipient follows the terms of this agreement.

1.2. This agreement does not impose any restriction on a Data
Recipient's use, modification, or sharing of any portions of the
Data that are in the public domain or that may be used, modified,
or shared under any other legal exception or limitation.

## 2. Conditions for Sharing Data

2.1. A Data Recipient may share Data, with or without modifications, so
long as the Data Recipient makes available the text of this agreement
with the shared Data.

## 3. No Restrictions on Results

3.1. This agreement does not impose any restriction or obligations
with respect to the use, modification, or sharing of Results.

## 4. No Warranty; Limitation of Liability

4.1. All Data Recipients receive the Data subject to the following
terms:

THE DATA IS PROVIDED ON AN "AS IS" BASIS, WITHOUT REPRESENTATIONS,
WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED
INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS OF TITLE,
NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.

NO DATA PROVIDER SHALL HAVE ANY LIABILITY FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING
WITHOUT LIMITATION LOST PROFITS), HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE DATA OR RESULTS,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.

## 5. Definitions

5.1. "Data" means the material received by a Data Recipient under
this agreement.

5.2. "Data Provider" means any person who is the source of Data
provided under this agreement and in reliance on a Data Recipient's
agreement to its terms.

5.3. "Data Recipient" means any person who receives Data directly
or indirectly from a Data Provider and agrees to the terms of this
agreement.

5.4. "Results" means any outcome obtained by computational analysis
of Data, including for example machine learning models and models'
insights.
```

### ISC

```text
Permission to use, copy, modify, and/or distribute this software for any purpose with or without
fee is hereby granted, provided that the above copyright notice and this permission notice appear
in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS
SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```

### MIT

```text
Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

### MPL-2.0

```text
Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
defined by the Mozilla Public License, v. 2.0.
```

### OFL-1.1

```text
Copyright 2013 Google LLC

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://scripts.sil.org/OFL


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

### Unicode-3.0

```text
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE


NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.

SPDX-License-Identifier: Unicode-3.0

—

Portions of ICU4X may have been adapted from ICU4C and/or ICU4J.
ICU 1.8.1 to ICU 57.1 © 1995-2016 International Business Machines Corporation and others.
```

### WTFPL

```text
            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
                    Version 2, December 2004

 Copyright (C) 2004 Sam Hocevar <sam@hocevar.net>

 Everyone is permitted to copy and distribute verbatim or modified
 copies of this license document, and changing it is allowed as long
 as the name is changed.

            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

  0. You just DO WHAT THE FUCK YOU WANT TO.
```

### Zlib

```text
This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use of
this software.

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
```

### blessing

```text
The author disclaims copyright to this source code.  In place of
a legal notice, here is a blessing:

   May you do good and not evil.
   May you find forgiveness for yourself and forgive others.
   May you share freely, never taking more than you give.
```

## Notes

- **Video codecs.** Lumora ships no H.264 implementation of its own and downloads nothing at run time. H.264 is used only through the operating system's codec (Android MediaCodec, Apple VideoToolbox, Windows Media Foundation, VA-API on Linux), whose patent licensing is the OS vendor's. The always-available codec is libvpx VP8/VP9 (BSD-3-Clause + Google's royalty-free patent grant). Release builds contain no OpenH264.
- **PDFium.** The prebuilt PDFium library also contains FreeType, libjpeg-turbo, libpng, zlib, Little CMS and OpenJPEG under their own permissive licenses.
- **Android.** The APK contains Google Play services Location (proprietary, Google's terms), used for sharing your location.
- **Maps.** Map tiles are loaded at run time from OpenStreetMap (data (c) OpenStreetMap contributors, ODbL-1.0); nothing is bundled.

Crates that publish no license file are listed under their declared license, with attribution taken from their Cargo.toml authors: `aec-rs 1.0.0`, `aec-rs-sys 1.0.0`, `asn1-rs-impl 0.2.0`, `block2 0.6.2`, `cookie-factory 0.3.3`, `crc-catalog 2.5.0`, `dasp_sample 0.11.0`, `dispatch2 0.3.1`, `jni 0.22.4`, `jni-macros 0.22.4`, `jni-sys-macros 0.4.1`, `matrix-pickle 0.2.3`, `matrix-pickle-derive 0.2.3`, `ndk 0.9.0`, `ndk-context 0.1.1`, `ndk-sys 0.6.0+11769913`, `objc2 0.6.5`, `objc2-audio-toolbox 0.3.2`, `objc2-avf-audio 0.3.2`, `objc2-core-audio 0.3.2`, `objc2-core-audio-types 0.3.2`, `objc2-core-foundation 0.3.2`, `objc2-encode 4.1.0`, `objc2-foundation 0.3.2`, `v4l2-sys-mit 0.3.0`.

