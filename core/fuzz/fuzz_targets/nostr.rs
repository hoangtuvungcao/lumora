#![no_main]
libfuzzer_sys::fuzz_target!(|data: &[u8]| lumora_fuzz::nostr(data));
