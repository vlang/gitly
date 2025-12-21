import net.http

path := 'src/static/css/gitly.css'
if !exists(path) {
	ret := system('sassc src/static/css/gitly.scss > src/static/css/gitly.css')
	if ret != 0 {
		http.download_file('https://gitly.org/css/gitly.css', path)!
		println("No sassc detected on this system, gitly.css has been downloaded from gitly.org.")
	}
}

ret := system('v .')
if ret == 0 {
	println('Gitly has been successfully built, run it with ./gitly')
}
