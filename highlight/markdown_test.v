module highlight

const markdown = '<script>  alert(true) </script> <!--  comment -->test'
const html = '<p>test</p>'

fn test_convert_markdown_to_html() {
	assert convert_markdown_to_html(markdown) == html
}
