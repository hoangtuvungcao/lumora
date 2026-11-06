#![no_main]
libfuzzer_sys::fuzz_target!(|data: &[u8]| lumora_fuzz::push_bridge(data));
