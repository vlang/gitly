module main

import rand
import crypto.rand as crypto_rand
import encoding.base64

pub const max_safe_unsigned_integer = u32(4_294_967_295)

pub fn set_rand_crypto_safe_seed() {
	first_seed := generate_crypto_safe_int_u32()
	second_seed := generate_crypto_safe_int_u32()

	rand.seed([first_seed, second_seed])
}

pub fn generate_salt() string {
	return rand.i64().str()
}

// decode_basic_auth parses the `Authorization` header
// returns login and password
pub fn decode_basic_auth(encoded string) (string, string) {
	decoded := base64.decode_str(encoded)
	auth_parts := decoded.split(':')

	return auth_parts[0], auth_parts[1..].join(':')
}

fn generate_crypto_safe_int_u32() u32 {
	return u32(crypto_rand.int_u64(max_safe_unsigned_integer) or { 0 })
}
