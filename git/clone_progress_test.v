module git

fn test_clone_progress_received_bytes_parses_mib() {
	progress := 'Receiving objects:  31% (78861/251249), 54.49 MiB | 3.59 MiB/s'

	assert clone_progress_received_bytes(progress) == u64(54.49 * 1024.0 * 1024.0)
}

fn test_clone_progress_received_bytes_uses_largest_value() {
	progress := 'Receiving objects:  10% (10/100), 999.00 KiB | 1.00 MiB/s\rReceiving objects:  90% (90/100), 100.00 MiB | 4.00 MiB/s, done.'

	assert clone_progress_received_bytes(progress) == u64(100.0 * 1024.0 * 1024.0)
}
