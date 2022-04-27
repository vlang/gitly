module main

import rand
import crypto.rand as crypto_rand

pub const max_safe_unsigned_integer = 4_294_967_295

pub fn set_rand_crypto_safe_seed() {
	first_seed := generate_crypto_safe_int_u32()
	second_seed := generate_crypto_safe_int_u32()

	rand.seed([first_seed, second_seed])
}

pub fn generate_salt() string {
	return rand.i64().str()
}

fn generate_crypto_safe_int_u32() u32 {
	return u32(crypto_rand.int_u64(max_safe_unsigned_integer) or { 0 })
}
