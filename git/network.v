module git

import strings

pub fn flush_packet() string {
	return '0000'
}

pub fn write_packet(value string) string {
	packet_length := (value.len + 4).hex()

	return strings.repeat(`0`, 4 - packet_length.len) + packet_length + value
}
