function post(url, dataObj, success) {
	// Create a FormData object
	const formData = new FormData();

	console.log(dataObj);
	if (dataObj !== undefined) {
		// Populate the FormData object with the object entries
		Object.entries(dataObj).forEach(([key, value]) => {
			formData.append(key, value);
		});
	}

	// Send the POST request with the FormData object
	fetch(url, {
		method: "POST",
		body: formData,
	})
		.then((response) => {
			/*
			if (!response.ok) {
				throw new Error("Network response was not ok");
			}
			*/
			return response.json(); // or .text() if the response is not in JSON format
		})
		.then((data) => {
			if (success !== undefined) {
				//const json_data = JSON.parse(data);
				success(data);
				//success(json_data);
			}
			//console.log("Success:", data);
		})
		.catch((error) => {
			console.error("Error:", error);
		});
}


function change_lang(x) {
	var y = document.getElementById("select_lang");
	post('/change_lang/' + y.value, {}, () => {
		window.location.reload();
	}	 )
}
